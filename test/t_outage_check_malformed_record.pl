#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify it under the
#  terms of the GNU General Public License as published by the Free Software
#  Foundation, either version 3 of the License, or (at your option) any later
#  version. See <http://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# Behavioural test for NMISNG::Outage::check_outages (OMK-12777 / defect BR-03).
#
# check_outages walks every record in the Outages table and sorts them into
# past/current/future. It returned an error from *inside* that per-record loop
# when a recurring record had an invalid start, end or frequency, so a single
# malformed record aborted the whole check. The caller (outageCheck) treats an
# error as "not in outage", so one bad record silently disabled planned-outage
# suppression for the whole node.
#
# This test drives the real check_outages against an Outages table holding one
# valid current outage plus three malformed recurring records (bad frequency,
# bad recurring start, bad recurring end - one per aborting return). It asserts
# the check still succeeds and still reports the valid current outage.
#
# It is hermetic: check_outages is called with an nmisng argument only (no
# node, so the node/DB selector path is skipped) and a config pointing at a
# throwaway conf dir. No MongoDB, no real node.
#
# RED before the fix: one malformed record makes check_outages return an error
# and lose the valid current outage. GREEN after: malformed records are skipped.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);

use NMISNG::Outage;
use NMISNG::Util;

# a no-op logger for the skip warnings the fix emits
{
	package t::SilentLog;
	sub new { return bless {}, shift }
	our $AUTOLOAD;
	sub AUTOLOAD { return }
	sub DESTROY  { return }
}

# ---------------------------------------------------------------------------
# An Outages table: one valid current outage, plus a malformed record for each
# of the three aborting returns in the record loop.
# ---------------------------------------------------------------------------
my $tmpconf = tempdir( CLEANUP => 1 );
my $when = time;
my ( $vstart, $vend ) = ( $when - 3600, $when + 3600 );

open my $fh, '>', "$tmpconf/Outages.nmis" or die "cannot write Outages.nmis: $!";
print $fh <<"NMIS";
%hash = (
  'valid_current' => { 'frequency' => 'once', 'start' => $vstart, 'end' => $vend, 'description' => 'valid current outage' },
  'bad_frequency' => { 'frequency' => 'banana', 'start' => '10:00', 'end' => '12:00', 'description' => 'bad frequency' },
  'bad_recurring_start' => { 'frequency' => 'weekly', 'start' => 'notaweekday 10:00', 'end' => 'tue 12:00', 'description' => 'bad start' },
  'bad_recurring_end' => { 'frequency' => 'weekly', 'start' => 'mon 10:00', 'end' => 'notaweekday 12:00', 'description' => 'bad end' },
);
NMIS
close $fh;

# check_outages requires ref($nmisng) eq "NMISNG" exactly (not a subclass), so
# bless a bare object into NMISNG and locally override the two methods it uses
# on the nmisng when no node is given: config (for the conf dir) and log.
my $config = { '<nmis_conf>' => $tmpconf };
my $nmisng = bless {}, 'NMISNG';

my $result;
{
	no warnings qw(redefine once);
	local *NMISNG::config = sub { return $config; };
	local *NMISNG::log    = sub { return t::SilentLog->new; };
	$result = NMISNG::Outage::check_outages( nmisng => $nmisng, time => $when );
}

ok( $result->{success}, "check_outages succeeds despite malformed outage records" )
	or diag( "returned error: " . ( $result->{error} // 'undef' ) );

my @current = @{ $result->{current} // [] };
is( scalar(@current), 1, "the one valid current outage is still returned" );
is( ( $current[0]->{description} // '' ), "valid current outage",
	"the surviving current outage is the valid one, not lost to a bad record" );

done_testing();
