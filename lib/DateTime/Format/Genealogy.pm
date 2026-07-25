package DateTime::Format::Genealogy;

# Author Nigel Horne: njh@bandsman.co.uk
# Copyright (C) 2018-2026, Nigel Horne

# Usage is subject to licence terms.
# The licence terms of this software are as follows:
# Personal single user, single computer use: GPL2
# All other users (including Commercial, Charity, Educational, Government)
#	must apply in writing for a licence for use from Nigel Horne at the
#	above e-mail.

use strict;
use warnings;
use autodie qw(:all);
use 5.006_001;

# Sub::Private in 'enforce' mode makes calling private subs from outside the
# package a runtime error.  HARNESS_ACTIVE (set by prove/make test) or
# $Sub::Private::BYPASS suppress enforcement so white-box tests can still
# reach private helpers directly.
BEGIN { $Sub::Private::config{mode} = 'enforce' }
use Sub::Private;
use Sub::Protected;

use namespace::clean;
use Carp;
use DateTime::Format::Natural;
use Genealogy::Gedcom::Date 2.01;
use Object::Configure 0.19;
use Params::Get 0.13;
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Readonly::Values::Months 0.02 qw(@short_month_names);
use Scalar::Util;

# ---------------------------------------------------------------------------
# Compile-time constants
# ---------------------------------------------------------------------------

# Map non-standard (long, abbreviated, or French/German) month names to the
# 3-letter GEDCOM abbreviation.  Not exported; callers must use parse_datetime.
Readonly my %MONTH_ALIAS => (
	'January'   => 'Jan',
	'February'  => 'Feb',
	'March'     => 'Mar',
	'April'     => 'Apr',
	'June'      => 'Jun',
	'July'      => 'Jul',
	'August'    => 'Aug',
	'September' => 'Sep',
	'October'   => 'Oct',
	'November'  => 'Nov',
	'December'  => 'Dec',
	# Common non-standard abbreviations for September
	'Sept'      => 'Sep',
	# French and German month variants found in real genealogical trees.
	# 'Janv' = French abbreviation for janvier (January).
	# 'Juli' = German July / occasional French variant.
	# 'Mai'  = French for May (3 letters, handled here to avoid a separate branch).
	'Janv'      => 'Jan',
	'Juli'      => 'Jul',
	'Mai'       => 'May',
);

# Julian-to-Gregorian day offset tiers.  Each pair is [boundary_year, offset].
# The gap widened by 1 day at each century mark after 1582:
#   10 days: 5 Oct 1582 to 28 Feb 1700
#   11 days: 1 Mar 1700 to 28 Feb 1800
#   12 days: 1 Mar 1800 to 28 Feb 1900
#   13 days: 1 Mar 1900 onwards (catch-all, coded as literal 13 in the helper)
Readonly my @JULIAN_OFFSET_TIERS => ([1700, 10], [1800, 11], [1900, 12]);

# Accepted parameter schema for parse_datetime, used by Params::Validate::Strict
# to reject unknown keys (typos, stale callers) at runtime.
Readonly my %PARSE_DATETIME_SCHEMA => (
	date   => { type => 'scalar', optional => 1 },
	quiet  => { type => 'scalar', optional => 1 },
	strict => { type => 'scalar', optional => 1 },
);

=head1 NAME

DateTime::Format::Genealogy - Create a DateTime object from a genealogy date string

=head1 VERSION

Version 0.12

=cut

our $VERSION = '0.12';

=head1 SYNOPSIS

C<DateTime::Format::Genealogy> is a Perl module designed to parse genealogy-style
date strings (primarily GEDCOM format) and convert them into L<DateTime> objects.
It wraps L<Genealogy::Gedcom::Date> and L<DateTime::Format::Natural>, adds GEDCOM
calendar-escape handling, and accepts common non-standard month names found in
exported genealogical trees.

    use DateTime::Format::Genealogy;
    my $dtg = DateTime::Format::Genealogy->new();
    my $dt  = $dtg->parse_datetime('25 Dec 2022');
    print $dt->dmy;  # 25-12-2022

=head1 SUBROUTINES/METHODS

=head2 new

Creates or clones a C<DateTime::Format::Genealogy> object.

=head3 EXAMPLE

    # Bare construction
    my $dtg = DateTime::Format::Genealogy->new();

    # Construction with flags stored on the object
    my $dtg_quiet = DateTime::Format::Genealogy->new(quiet => 1, strict => 1);

    # Clone with an override (inherits quiet => 1, overrides strict)
    my $clone = $dtg_quiet->new(strict => 0);

=head3 API SPECIFICATION

    # Input (hash or hashref, all keys optional):
    {
        quiet  => $bool,  # suppress carp in internal helpers
        strict => $bool,  # enforce 3-letter GEDCOM month abbreviations
        # Any extra keys from Object::Configure are also accepted.
    }

    # Output: blessed DateTime::Format::Genealogy object

=head3 MESSAGES

This method does not emit any diagnostics directly.

=head3 PSEUDOCODE

    FUNCTION new(class, *args):
      params = get_params(undef, args)
      IF class is not defined:
        class = __PACKAGE__
      ELSE IF class is already an object (blessed):
        RETURN bless( merge(class.attrs, params), ref(class) )
      params = configure(class, params)   # merge any config-file settings
      RETURN bless(params, class)
    END FUNCTION

=cut

sub new
{
	my $class = shift;

	my $params = Params::Get::get_params(undef, \@_);

	if(!defined($class)) {
		# Called as DateTime::Format::Genealogy::new() with no invocant;
		# default to the package name so bless still works.
		$class = __PACKAGE__;
	} elsif(Scalar::Util::blessed($class)) {
		# Invocant is an existing object: clone it and overlay any new params.
		return bless { %{$class}, ($params ? %{$params} : ()) }, ref($class);
	}

	$params = Object::Configure::configure($class, $params);
	return bless $params, $class;
}

=head2 parse_datetime

Parses a genealogy-style date string and returns a L<DateTime> object.

Recognises GEDCOM calendar escapes (C<@#DJULIAN@>, C<@#DHEBREW@>,
C<@#DFRENCH R@>) and converts them via the appropriate calendar module when
available.

Can be called as a class method, an object method, or a bare function.

Returns:

=over 4

=item *

A single L<DateTime> object for exact, parseable dates.

=item *

A two-element list of L<DateTime> objects in I<list> context when the date
string is a range (C<bet X and Y> / C<from X to Y>).

=item *

C<undef> (scalar) or the empty list (list context) when the date cannot be
parsed, is a year-only string, is prefixed with an approximation keyword
(C<bef>, C<aft>, C<abt>), or represents a date before AD 100.

=back

Mandatory argument:

=over 4

=item * C<date>

The date string to parse.

=back

Optional arguments (may be set at construction time and/or overridden
per-call; per-call values take precedence):

=over 4

=item * C<quiet>

Suppress L<Carp> warnings on unparseable or approximate dates.

=item * C<strict>

Enforce the GEDCOM standard: only 3-letter month abbreviations (C<Jan>,
C<Feb>, ...) are accepted.  Long English names and French/German variants
are rejected.

=back

=head3 EXAMPLE

    my $dtg = DateTime::Format::Genealogy->new();

    # Simple exact date
    my $dt = $dtg->parse_datetime('25 Dec 2022');
    print $dt->dmy;  # 25-12-2022

    # Date range (list context)
    my ($start, $end) = $dtg->parse_datetime('bet 1 Sep 1939 and 2 Sep 1945');

    # GEDCOM calendar escape
    my $julian = $dtg->parse_datetime('@#DJULIAN@ 15 Mar 1620');

    # Class-method form (no constructor required)
    my $dt2 = DateTime::Format::Genealogy->parse_datetime('1 Jan 2000');

    # Long month name (non-strict only)
    my $dt3 = $dtg->parse_datetime('12 June 2020');

    # French month variant (non-strict only)
    my $dt4 = $dtg->parse_datetime('21 Mai 1681');

=head3 API SPECIFICATION

    # Input (hash or hashref):
    {
        date   => $string,         # required (non-ref, non-empty)
        quiet  => $bool,           # optional; falls back to $self->{'quiet'}
        strict => $bool,           # optional; falls back to $self->{'strict'}
    }

    # Return values:
    #   DateTime                   exact parseable date
    #   (DateTime, DateTime)       date range (list context only)
    #   undef / ()                 unparseable, approximate, or year-only

=head3 MESSAGES

=over 4

=item C<< Usage: DateTime::Format::Genealogy::parse_datetime(date => $date) >>

Thrown (croak) when no arguments are supplied or when the C<date> value is
undef or a reference.

=item C<< Invalid parse_datetime parameters: ... >>

Thrown (croak) when an unknown parameter key is passed (e.g. a typo).

=item C<< $date is invalid, need an exact date to create a DateTime >>

Warned (carp) when the date begins with an approximation prefix (C<bef>,
C<aft>, C<abt>).  Silenced by C<quiet>.

=item C<< $date is invalid, there are only 30 days in November >>

Warned (carp) for the impossible date C<31 Nov>.  Always emitted; not
silenced by C<quiet>.

=item C<< Changing date '$original' to '$new' >>

Warned (carp) when a date is automatically rewritten (ISO dash format or
dash-separated range).  Silenced by C<quiet>.

=item C<< Unparseable date $date - often because the month name isn't 3 letters >>

Warned (carp) in strict mode for non-3-letter months, or in non-strict mode
for unrecognised long month names.  Silenced by C<quiet>.

=item C<< $dfn_error_string >>

Warned (carp) when L<DateTime::Format::Natural> rejects the date string.
Silenced by C<quiet>.

=item C<< Hebrew calendar conversion failed: ... >>

Warned (carp) when L<DateTime::Calendar::Hebrew> is unavailable or throws.
Silenced by C<quiet>.

=item C<< French Republican calendar conversion failed: ... >>

Warned (carp) when L<DateTime::Calendar::FrenchRevolutionary> is unavailable
or throws.  Silenced by C<quiet>.

=item C<< Calendar type $type not supported >>

Warned (carp) for GEDCOM calendar escapes other than GREGORIAN, JULIAN,
HEBREW, and FRENCH R.  Silenced by C<quiet>.

=back

=head3 PSEUDOCODE

    FUNCTION parse_datetime(self, *args):
      -- Dispatch class/function/hash-invocant calls to an object instance
      IF self is not a reference:
        RETURN new()->parse_datetime(args or self)
      IF ref(self) == 'HASH':
        RETURN new()->parse_datetime(self)

      ABORT unless args non-empty
      params = get_params('date', args)
      ABORT on unknown keys (validate_strict)

      date   = params.date
      quiet  = params.quiet  // self.quiet
      strict = params.strict // self.strict

      ABORT unless date is defined, non-empty, and not a reference

      -- Strip GEDCOM calendar escape if present
      IF date =~ s/^@#D([A-Z ]+?)@\s*//: calendar_type = 'D' + uc(match)

      -- Reject approximate/relative dates
      IF date =~ /^(bef|aft|abt)\s/i: CARP and RETURN undef

      -- Reject calendar impossibilities
      IF date =~ /^31\s+Nov/: CARP and RETURN undef

      -- Rewrite dash-separated ranges and ISO dates
      IF date =~ /X - Y/:
        IF date =~ /YYYY-MM-DD/: REFORMAT to "DD Mon YYYY" (carp)
        ELSE: REFORMAT to "bet X and Y" (carp)

      -- Dispatch ranges to recursive calls
      IF date =~ /^bet X and Y/i:
        RETURN (parse_datetime(X), parse_datetime(Y)) IF wantarray
        RETURN undef

      IF !strict AND date =~ /^from X to Y/i:
        RETURN (parse_datetime(X), parse_datetime(Y)) IF wantarray
        RETURN undef

      -- Normalise non-standard month names (non-strict mode only)
      IF !strict:
        IF date =~ DD + Aout + YYYY (French non-ASCII August):
          REWRITE month to 'Aug'
        ELSE IF date =~ /DD LONG_OR_VARIANT YYYY/:
          lookup = MONTH_ALIAS{ucfirst(lc(month))}
          IF lookup: REWRITE month to lookup
          ELSE IF month is more than 3 letters: CARP and RETURN undef
          -- 3-letter unknown months fall through unchanged to the parser

      -- Parse with Genealogy::Gedcom::Date (cached) then DateTime::Format::Natural
      IF date starts with digit:
        d = _date_parser_cached(date)
        IF d defined:
          RETURN undef if date ends with year-only (< AD100 guard)
          rc = DateTime::Format::Natural->parse_datetime(d.canonical)
          IF calendar_type != DGREGORIAN:
            rc = _convert_calendar(rc, calendar_type, quiet)
          RETURN rc

      -- Fallback: try DateTime::Format::Natural directly on the raw string
      IF date not ~= /^(Abt|ca?)/i AND date =~ /^[\w\s,]+$/:
        rc = DateTime::Format::Natural->parse_datetime(date)
        IF rc AND success: RETURN rc
        ELSE: CARP error

      RETURN undef
    END FUNCTION

=cut

sub parse_datetime
{
	my $self = shift;

	# Normalise class-method and bare-function call styles into an object call.
	if(!ref($self)) {
		if(scalar(@_)) {
			return(__PACKAGE__->new()->parse_datetime(@_));
		}
		return(__PACKAGE__->new()->parse_datetime($self));
	} elsif(ref($self) eq 'HASH') {
		return(__PACKAGE__->new()->parse_datetime($self));
	}

	# Guard before Params::Get so *our* croak message is what Test::Carp sees.
	Carp::croak('Usage: ', __PACKAGE__, '::parse_datetime(date => $date)') unless scalar(@_);

	my $params = Params::Get::get_params('date', @_);

	# Catch unknown parameter keys early so callers get a clear error rather
	# than silent misbehaviour from a typo like 'quet' instead of 'quiet'.
	# validate_strict uses a compile-time-imported croak, so we wrap in eval
	# and re-throw via Carp::croak (which IS interceptable by Test::Carp).
	eval { validate_strict(schema => \%PARSE_DATETIME_SCHEMA, input => $params) };
	Carp::croak("Invalid parse_datetime parameters: $@") if $@;

	if((!ref($params->{'date'})) && (my $date = $params->{'date'})) {
		# Per-call flags shadow object-level defaults, enabling per-call overrides
		# without losing the convenience of constructor-level configuration.
		my $quiet  = $params->{'quiet'}  // $self->{'quiet'};
		my $strict = $params->{'strict'} // $self->{'strict'};

		# Detect and strip any GEDCOM calendar escape at the front of the string.
		my $calendar_type = 'DGREGORIAN';
		if($date =~ s/^@#D([A-Z ]+?)@\s*//) {
			$calendar_type = 'D' . uc($1);
		}

		# Approximate-date prefixes (bef/aft/abt) signal "no exact date known",
		# so a DateTime object would be misleading.
		if(($date =~ /^bef\s/i) || ($date =~ /^aft\s/i) || ($date =~ /^abt\s/i)) {
			Carp::carp("$date is invalid, need an exact date to create a DateTime")
				unless($quiet);
			return;
		}

		# 31 November does not exist; catch it before any parser attempt.
		if($date =~ /^31\s+Nov/) {
			Carp::carp("$date is invalid, there are only 30 days in November");
			return;
		}

		# Rewrite dash-separated constructs.  ISO "YYYY-MM-DD" is reformatted to
		# "DD Mon YYYY".  Any other "X - Y" is treated as a date range.
		if($date =~ /^\s*(.+\d\d)\s*\-\s*(.+\d\d)\s*$/) {
			if($date =~ /^(\d{4})\-(\d{2})\-(\d{2})$/) {
				my $month = ucfirst($short_month_names[$2 - 1]);
				Carp::carp("Changing date '$date' to '$3 $month $1'") unless($quiet);
				$date = "$3 $month $1";
			} else {
				Carp::carp("Changing date '$date' to 'bet $1 and $2'") unless($quiet);
				$date = "bet $1 and $2";
			}
		}

		# Date ranges return two DateTimes in list context; undef in scalar.
		if($date =~ /^bet (.+) and (.+)/i) {
			if(wantarray) {
				return $self->parse_datetime($1), $self->parse_datetime($2);
			}
			return;
		}

		if((!$strict) && ($date =~ /^from (.+) to (.+)/i)) {
			if(wantarray) {
				return $self->parse_datetime($1), $self->parse_datetime($2);
			}
			return;
		}

		if($date !~ /^\d{3,4}$/) {
			# Strict mode: only 3-letter GEDCOM abbreviations are valid.
			if($strict) {
				if($date !~ /^(\d{1,2})\s+([A-Z]{3})\s+(\d{3,4})$/i) {
					Carp::carp("Unparseable date $date - often because the month name isn't 3 letters") unless($quiet);
					return;
				}
			} else {
				# Aout with circumflex-u (Ao\x{FB}t) must be matched explicitly
				# because the standard \w character class is ASCII-only and will
				# not match the non-ASCII 'u with circumflex'.
				if($date =~ /^(\d{1,2})\s+Ao\x{FB}t\s+(\d{3,4})$/i) {
					$date = "$1 Aug $2";
				} elsif($date =~ /^(\d{1,2})\s+([A-Z]{3,}+)\.?\s+(\d{3,4})$/i) {
					# Look up the month in the alias table.
					# Unknown 3-letter tokens are passed through unchanged so that
					# standard GEDCOM abbreviations (Sep, Dec, ...) that did not
					# trigger the earlier cache path still reach the parser.
					if(my $abbrev = $MONTH_ALIAS{ucfirst(lc($2))}) {
						$date = "$1 $abbrev $3";
					} elsif(length($2) > 3) {
						# Longer-than-3-letter names not in the alias table are
						# truly unrecognised; there is nothing useful we can do.
						Carp::carp("Unparseable date $date - often because the month name isn't 3 letters") unless($quiet);
						return;
					}
				} elsif($date =~ /^(\d{1,2})\-([A-Z]{3})\-(\d{3,4})$/i) {
					# Accept the 29-Aug-1938 dash-separated single-date format.
					$date = "$1 $2 $3";
				}
			}

			# Lazily initialise DateTime::Format::Natural on first use.
			my $dfn = $self->{'dfn'} //= DateTime::Format::Natural->new();

			if(($date =~ /^\d/) && (my $d = $self->_date_parser_cached($date))) {
				# DateTime::Format::Natural cannot handle dates before AD 100;
				# a date ending in a 1-or-2-digit year is that old.
				return if($date =~ /\s\d{1,2}$/);

				# Guard against a malformed GGD result with an undef canonical
				# field; passing undef to DFN causes a Params::Validate croak.
				return unless defined $d->{'canonical'};

				my $rc = $dfn->parse_datetime($d->{'canonical'});

				# DFN silently returns today's date when it cannot parse the
				# canonical string (e.g. 3-digit years 100-999, very large
				# years).  We must check success() here just as we do in the
				# DFN fallback path below, otherwise the caller receives a
				# completely wrong DateTime.
				unless($dfn->success) {
					Carp::carp($dfn->error) unless $quiet;
					return;
				}

				if($rc && $calendar_type ne 'DGREGORIAN') {
					return _convert_calendar($rc, $calendar_type, $quiet);
				}

				return $rc;
			}

			# Last resort: try DateTime::Format::Natural on the raw string.
			# Approximate-prefix forms are excluded here because they already
			# returned undef above; the pattern here guards against 'Abt'/'ca'
			# leaking through when quiet is enabled (e.g. "Abt1Jan2000" has no
			# space so it was not caught by the /^abt\s/i check above).
			if(($date !~ /^(Abt|ca?)/i) && ($date =~ /^[\w\s,]+$/)) {
				if(my $rc = $dfn->parse_datetime($date)) {
					if($dfn->success()) {
						return $rc;
					}
					Carp::carp($dfn->error()) unless($quiet);
				}
				# NOTE: DateTime::Format::Natural->parse_datetime always returns
				# a DateTime object (today's date on failure), never undef.  The
				# else branch that would carp "Can't parse date" is therefore
				# dead code and has been removed.  If a future DFN version can
				# return undef, this else must be reinstated:
				#   else { Carp::carp("Can't parse date '$date'") unless $quiet }
			}
		}
		return;
	}

	Carp::croak('Usage: ', __PACKAGE__, '::parse_datetime(date => $date)');
}

# ---------------------------------------------------------------------------
# _date_parser_cached
#
# Purpose:      Wrap Genealogy::Gedcom::Date->parse() with a per-object
#               memoisation layer to avoid re-parsing identical strings.
# Entry:        $self  - blessed object (must carry ->{'date_parser'} slot)
#               date   - non-empty, non-undef date string
# Exit:         Hashref on success ({canonical, day, month, year, ...}),
#               undef on parse failure or error.
# Side Effects: Populates $self->{'all_dates'}{$date} on first successful
#               parse.  Carps on parser error unless $self->{'quiet'} is set.
# ---------------------------------------------------------------------------

sub _date_parser_cached :Protected
{
	my $self = shift;

	my $params = Params::Get::get_params('date', @_);
	my $date = $params->{'date'};

	Carp::croak('Usage: _date_parser_cached(date => $date)') unless defined $date;

	# Short-circuit if we have already parsed this string in this session.
	return $self->{'all_dates'}{$date} if exists $self->{'all_dates'}{$date};

	my $date_parser = $self->{'date_parser'} //= Genealogy::Gedcom::Date->new();

	my $parsed_date;
	eval {
		$parsed_date = $date_parser->parse(date => $date);
	};

	if(my $error = $date_parser->error()) {
		Carp::carp("$date: '$error'") unless $self->{'quiet'};
		return;
	}

	if((ref($parsed_date) eq 'ARRAY') && @{$parsed_date}) {
		return $self->{'all_dates'}{$date} = $parsed_date->[0];
	}

	return;
}

# ---------------------------------------------------------------------------
# _convert_calendar
#
# Purpose:      Convert a Gregorian DateTime produced by
#               Genealogy::Gedcom::Date/DateTime::Format::Natural to the
#               calendar indicated by the GEDCOM escape that preceded the date.
# Entry:        $dt            - DateTime object in Gregorian coordinates
#               $calendar_type - normalised escape string (e.g. 'DJULIAN')
#               $quiet         - truthy to suppress carp on failure
# Exit:         Converted DateTime, or the original $dt for unknown types.
# Side Effects: May carp on conversion failure (unless $quiet).
# ---------------------------------------------------------------------------

sub _convert_calendar :Private
{
	my ($dt, $calendar_type, $quiet) = @_;

	if($calendar_type eq 'DJULIAN') {
		# Add the historical Julian-to-Gregorian day offset.
		my $offset_days = _julian_to_gregorian_offset($dt->year);
		return $dt->clone->add(days => $offset_days);
	} elsif($calendar_type eq 'DHEBREW') {
		# "return" inside eval{} exits the eval block, NOT the enclosing sub,
		# so we capture the result in $result and return it afterwards.
		my $result;
		eval {
			require DateTime::Calendar::Hebrew;
			my $h = DateTime::Calendar::Hebrew->new(
				year  => $dt->year,
				month => $dt->month,
				day   => $dt->day
			);
			$result = DateTime->from_object(object => $h);
		};
		Carp::carp("Hebrew calendar conversion failed: $@") if $@ && !$quiet;
		# Return the converted DateTime on success, undef on failure.
		# The POD (LIMITATIONS) documents that undef is returned when the
		# optional module is unavailable rather than passing back the
		# unconverted Gregorian DateTime.
		return $result;
	} elsif($calendar_type =~ /FRENCH R/) {
		my $result;
		eval {
			require DateTime::Calendar::FrenchRevolutionary;
			my $f = DateTime::Calendar::FrenchRevolutionary->new(
				year  => $dt->year,
				month => $dt->month,
				day   => $dt->day
			);
			$result = DateTime->from_object(object => $f);
		};
		Carp::carp("French Republican calendar conversion failed: $@") if $@ && !$quiet;
		return $result;
	} else {
		# DROMAN and any other future escape types are not yet supported.
		Carp::carp("Calendar type $calendar_type not supported") unless $quiet;
	}

	return $dt;
}

# ---------------------------------------------------------------------------
# _julian_to_gregorian_offset
#
# Purpose:      Return the number of days to add to a Julian date to obtain
#               the Gregorian equivalent, based on the year.
# Entry:        $year - integer calendar year
# Exit:         Integer day offset (10, 11, 12, or 13)
# Side Effects: None
# ---------------------------------------------------------------------------

sub _julian_to_gregorian_offset :Private
{
	my ($year) = @_;

	# Select the offset for the first tier whose boundary exceeds the year.
	# The final catch-all (1900 onwards = 13 days) is coded as the fallback.
	my ($pair) = grep { $year < $_->[0] } @JULIAN_OFFSET_TIERS;
	return $pair ? $pair->[1] : 13;
}

1;

=head1 LIMITATIONS

=over 4

=item *

Dates before AD 100 are rejected because L<DateTime::Format::Natural> cannot
parse them reliably (it returns today's date instead of an error).

=item *

The C<Aout> (French August with circumflex-u) entry in the month-alias table
uses a non-ASCII Unicode escape (C<\x{FB}>).  The module file must be read as
UTF-8; this is satisfied by the standard C<perl -Ilib> invocation but may
require C<use utf8> or C<open ':encoding(UTF-8)'> in unusual environments.

=item *

Hebrew and French Republican calendar conversions require
L<DateTime::Calendar::Hebrew> and L<DateTime::Calendar::FrenchRevolutionary>
respectively.  These are optional and not listed as hard dependencies.  When
absent, the GEDCOM escape is silently discarded and undef is returned unless
the C<quiet> flag is off, in which case a carp is emitted.

=item *

L<Genealogy::Gedcom::Date> cannot parse native Hebrew or French Revolutionary
month names (e.g. C<Tishri>, C<Vendemiaire>).  Only dates written in
Gregorian form with the C<@#DHEBREW@> escape are converted.

=item *

The C<quiet> and C<strict> flags may be set at construction time
(C<< ->new(quiet => 1) >>) and will be respected by all subsequent calls to
C<parse_datetime> unless overridden on a per-call basis.  The per-call value
always takes precedence.

=back

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 BUGS

Please report any bugs or feature requests to the author.
This module is provided as-is without any warranty.

=head1 SEE ALSO

=over 4

=item * L<Genealogy::Gedcom::Date>

=item * L<DateTime>

=item * L<DateTime::Format::Natural>

=item * L<Configure an Object at Runtime|Object::Configure>

=item * L<Test Dashboard|https://nigelhorne.github.io/DateTime-Format-Genealogy/coverage/>

=back

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc DateTime::Format::Genealogy

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=DateTime-Format-Genealogy>

=item * GitHub Issues

L<https://github.com/nigelhorne/DateTime-Format-Genealogy/issues>

=back

=head1 FORMAL SPECIFICATION

=head2 new

    State S ::= [ attrs : Name -> Value ]

    new(class, params) = bless(params U configure(class))   when !blessed(class)
    new(obj,   params) = bless(obj.attrs (+) params)         when  blessed(obj)

    where (+) denotes right-biased union (params values take precedence).

=head2 parse_datetime

Let D be the set of genealogical date strings and DT the co-domain of
L<DateTime> objects.

    parse_datetime : D -> DT | bot | (DT x DT)

    YearOnly ::= { s in D | s ~ /^\d{3,4}$/ }
    Approx   ::= { s in D | s ~ /^(bef|aft|abt)\s/i }
    Ranges   ::= { s in D | s ~ /^bet\s.+\sand\s.+/i
                           | s ~ /^from\s.+\sto\s.+/i }

    Pre:  date != bot

    Post:
      date in YearOnly              => result = bot
      date in Approx                => result = bot  (carp unless quiet)
      date in Ranges /\ wantarray   => result in DT x DT
      date in Ranges /\ !wantarray  => result = bot
      date in Parseable \
        (YearOnly u Approx u Ranges) => result in DT
      date not in Parseable         => result = bot  (carp unless quiet)

=head1 LICENSE AND COPYRIGHT

Copyright 2018-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut

1;
