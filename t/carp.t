#!perl -wT

use strict;
use warnings;
use Test::Most;
use DateTime::Format::Genealogy;

CARP: {
	eval 'use Test::Carp';

	if($@) {
		plan(skip_all => 'Test::Carp needed to check error messages');
	} else {
		my $g = new_ok('DateTime::Format::Genealogy');
		does_croak_that_matches(sub { my $rc = $g->parse_datetime(); }, qr/^Usage:/);
		does_carp_that_matches(sub { my $rc = $g->parse_datetime('xyzzy'); }, qr/does not parse/);
		does_carp_that_matches(sub { my $rc = $g->parse_datetime(date => 'xyzzy'); }, qr/does not parse/);
		does_carp_that_matches(sub { my $rc = $g->parse_datetime({ date => 'xyzzy' }); }, qr/does not parse/);
		done_testing();
	}
}
