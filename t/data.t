#!perl -wT

use strict;
use warnings;
use Test::Most tests => 11;
use Test::NoWarnings;
use Test::Exception;

BEGIN {
	use_ok('DateTime::Format::Genealogy');
}

DATA: {
	my $f = new_ok('DateTime::Format::Genealogy');

	my $dt = $f->parse_datetime('29 Sep 1939');

	ok(defined($dt));
	isa($dt, 'DateTime');
	ok($dt->dmy() eq '29-09-1939');

	$dt = $f->parse_datetime(date => 'bet 28 Jul 1914 and 11 Nov 1919');

	ok(!defined($dt));

	my @dts = $f->parse_datetime({ date => 'bet 28 Jul 1914 and 11 Nov 1918' });

	ok(scalar(@dts) == 2);
	isa($dts[0], 'DateTime');
	ok($dts[0]->dmy() eq '28-07-1914');
	isa($dts[1], 'DateTime');
	ok($dts[1]->dmy() eq '11-11-1918');

	throws_ok { $f->parse_datetime(['29 Sep 1939']) } qr/^Usage: parse_datetime/, 'verify invalid parameter';
	throws_ok { $f->parse_datetime('29 SepX 1939') } qr/^invalid date received/, 'verify invalid date';
}
