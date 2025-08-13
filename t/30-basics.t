#!/usr/bin/env perl

use strict;
use warnings;
use Test::Most tests => 15;

BEGIN { use_ok('DateTime::Format::Genealogy') }

# Create an instance
my $dtf = new_ok('DateTime::Format::Genealogy');

# Test valid date
my $date_str = '25 Dec 2022';
my $dt = $dtf->parse_datetime($date_str);
ok(defined $dt, "Parsed date: $date_str");
is($dt->year(), 2022, 'Year is correct');
is($dt->month(), 12, 'Month is correct');
is($dt->day(), 25, 'Day is correct');

# Test invalid date
my $invalid_date = '31 Nov 2022';
my $dt_invalid = $dtf->parse_datetime($invalid_date);
ok(!defined($dt_invalid), "Invalid date: $invalid_date");

# Test date range
my $range = '1 Jan 2022 - 31 Dec 2022';
my @range_dates = $dtf->parse_datetime({ date => $range });
ok(scalar(@range_dates) == 2, "Parsed range: $range");
is($range_dates[0]->day(), 1, 'Range start day');
is($range_dates[1]->day(), 31, 'Range end day');

# Test approximate date
my $approx_date = 'abt 2022';
my $dt_approx = $dtf->parse_datetime(date => $approx_date);
ok(!defined($dt_approx), "Approximate date: $approx_date");

# Test DJULIAN date
my $julian_date = '@#DJULIAN@ 15 Mar 1620';
my $dt_julian = $dtf->parse_datetime($julian_date);
ok(defined($dt_julian), "Parsed Julian date: $julian_date");

# Historical fact: In 1620, England was still using the Julian calendar.
# 15 Mar 1620 Julian = 25 Mar 1620 Gregorian
is($dt_julian->year(), 1620, 'Gregorian year is correct');
is($dt_julian->month(), 3, 'Gregorian month is correct');
is($dt_julian->day(), 25, 'Gregorian day is correct');
