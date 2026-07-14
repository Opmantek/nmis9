#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#  NMIS is free software: see the GNU General Public License for details.
#
# *****************************************************************************
#
# Integration test for NMISNG::Outage::check_outages selector + time-window
# classification, including the regex:/iregex: array-entry matching added in
# OMK-1113.
#
# What it does:
#  - spins up a throwaway MongoDB database (dropped at the end),
#  - creates one node ("group1") with a catchall inventory,
#  - writes an Outages table into a temp conf dir (the real conf/Outages.nmis is
#    NEVER touched: check_outages resolves the conf dir from the passed nmisng
#    config, so we redirect <nmis_conf> in memory only),
#  - asserts which outages check_outages() returns as current/future/past at a
#    given time, i.e. whether the node is "in outage" (true) or not (false)
#    inside vs outside the time window.
#
# Run: perl test/t_outage_check_outages.pl [debug=1]

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

use strict;
use warnings;
use Carp;
use Test::More;
use File::Temp qw(tempdir);
use Data::Dumper;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Outage;

my %nvp   = %{ NMISNG::Util::get_args_multi(@ARGV) };
my $debug = $nvp{debug};

# --- config + isolated database -------------------------------------------
my $confdir = "$FindBin::Bin/../conf";
my $C = NMISNG::Util::loadConfTable( dir => $confdir );
if (!$C or !keys %$C)
{
	plan skip_all => "cannot load config from $confdir";
	exit(0);
}
$C->{debug}   = $debug;
$C->{db_name} = "nmisng_outage_check_t_" . time;

my $logger = NMISNG::Log->new( level => $debug // "warn", path => undef );

my $nmisng = NMISNG->new( config => $C, log => $logger );
if (!$nmisng)
{
	plan skip_all => "cannot construct NMISNG (MongoDB unreachable?)";
	exit(0);
}
$C = $nmisng->config();

# make sure a failed run still drops the throwaway db
our $CLEANUP_DB = $nmisng;
END { eval { $CLEANUP_DB->get_db()->drop() } if ($CLEANUP_DB); }

# --- create one node with a catchall --------------------------------------
my $nodename = "outage_check_node";
my $groupval = "group1";
my $node_uuid = NMISNG::Util::getUUID();

my $node = $nmisng->node( uuid => $node_uuid, create => 1 );
$node->cluster_id( $C->{cluster_id} );
$node->name( $nodename );
$node->activated( { "NMIS" => 1 } );
$node->configuration({
	host      => "127.0.0.1",
	group     => $groupval,
	roleType  => "core",
	nodeType  => "router",
	netType   => "wan",
	collect   => "true",
	threshold => 1,
});
my ($ok, $err) = $node->save();
if ($ok < 0)
{
	plan skip_all => "cannot save test node (MongoDB unreachable?): $err";
	exit(0);
}
my ($catchall, $cerr) = $node->inventory(
	concept => "catchall", path_keys => [], create => 1,
	data => { name => $nodename, nodeType => "router" } );
BAIL_OUT("cannot create catchall: $cerr") if ($cerr);
$catchall->save( node => $node );

# re-fetch a clean node object so check_outages reads the catchall from the db
$node = $nmisng->node( uuid => $node_uuid );
BAIL_OUT("cannot re-fetch node") if (!$node);

# --- write an Outages table into a temp conf dir (real conf untouched) -----
my $tmpconf = tempdir( CLEANUP => 1 );
$C->{'<nmis_conf>'} = $tmpconf;   # in-memory redirect for this nmisng only

my $now = time;
my $HR  = 3600;

# ids are stable so assertions can name them
my %outages = (
	out_now_name => {
		id => "out_now_name", description => "exact name, active now",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { name => [ $nodename ] } },
	},
	out_now_iregex => {
		id => "out_now_iregex", description => "iregex group, active now",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "iregex:GROUP[0-9]" ] } },
	},
	out_now_regex_nomatch => {
		id => "out_now_regex_nomatch", description => "regex group, no match",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "regex:zzz_nomatch" ] } },
	},
	out_future => {
		id => "out_future", description => "exact name, starts later",
		frequency => "once", start => $now + $HR, end => $now + 2 * $HR,
		options => {}, selector => { node => { name => [ $nodename ] } },
	},
	out_past => {
		id => "out_past", description => "exact name, already ended",
		frequency => "once", start => $now - 2 * $HR, end => $now - $HR,
		options => {}, selector => { node => { name => [ $nodename ] } },
	},
);
NMISNG::Util::writeHashtoFile( file => "$tmpconf/Outages.nmis", data => \%outages );
ok( -e "$tmpconf/Outages.nmis", "temp Outages table written" );

# helper: set of outage ids present in a returned list
sub ids { return { map { $_->{id} => 1 } @{ $_[0] // [] } }; }

# --- check_outages at "now": inside the window ----------------------------
my $res = NMISNG::Outage::check_outages( nmisng => $nmisng, node => $node, time => $now );
is( $res->{success}, 1, "check_outages succeeded at now" )
	or diag( Dumper($res) );

my $cur = ids( $res->{current} );
my $fut = ids( $res->{future} );
my $pst = ids( $res->{past} );

ok( $cur->{out_now_name},        "exact-name outage is current (in window)" );
ok( $cur->{out_now_iregex},      "iregex outage is current (OMK-1113 match)" );
ok( !$cur->{out_now_regex_nomatch}, "non-matching regex outage is NOT current" );
ok( !$cur->{out_future},         "future outage is not current" );
ok( !$cur->{out_past},           "past outage is not current" );

ok( $fut->{out_future}, "future-windowed outage is in future list" );
ok( $pst->{out_past},   "past-windowed outage is in past list" );

# the non-matching selector must not leak into any bucket
ok( !$fut->{out_now_regex_nomatch} && !$pst->{out_now_regex_nomatch},
	"non-matching regex outage absent from every bucket" );

# --- same outage, time moved past its end: current -> false ---------------
my $later = $now + 2 * $HR + 1;   # after out_now_name's end ($now + $HR)
my $res2  = NMISNG::Outage::check_outages( nmisng => $nmisng, node => $node, time => $later );
is( $res2->{success}, 1, "check_outages succeeded at later time" );
my $cur2 = ids( $res2->{current} );
my $pst2 = ids( $res2->{past} );
ok( !$cur2->{out_now_name}, "exact-name outage no longer current after window end (true -> false)" );
ok( $pst2->{out_now_name},  "exact-name outage moved to past after window end" );

# --- cleanup ---------------------------------------------------------------
eval { $nmisng->get_db()->drop(); };
$CLEANUP_DB = undef;

done_testing();
