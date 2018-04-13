#!perl -wT

use strict;
use warnings;
use Test::Most tests => 6;
use DateTime::Format::Genealogy;

eval 'use Test::Carp';

ERROR: {
	if($@) {
		plan skip_all => 'Test::Carp needed to check error messages';
	} else {
		my $f = new_ok('DateTime::Format::Genealogy');
		does_carp_that_matches(sub { $f->parse_datetime('29 SepX 1939') }, qr/^29 SepX 1939/);
		does_carp_that_matches(sub { $f->parse_datetime('31 Nov 1939') }, qr/^31 Nov 1939/);
		does_croak_that_matches(sub { $f->parse_datetime(['29 Sep 1939']) }, qr/^Usage:/);
		does_croak_that_matches(sub { $f->parse_datetime({ datex => '30 Sep 1939' }) }, qr/^Usage:/);
		does_croak_that_matches(sub { $f->parse_datetime() }, qr/^Usage:/);
	}
}
