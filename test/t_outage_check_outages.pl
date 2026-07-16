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
#  - unit-tests the pure selector-entry matcher first (no config or db needed,
#    so these assertions run even on a bare CI checkout),
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

# --- pure unit tests for the selector-entry matcher ------------------------
# these need neither config nor MongoDB, so they always run
{
	my $m = \&NMISNG::Outage::selector_entry_matches;

	ok( $m->("group1", "group1"),   "exact entry matches" );
	ok( !$m->("group1", "group2"),  "exact entry mismatch" );
	ok( !$m->(undef, "group1"),     "undef actual never matches" );

	ok( $m->("group1", "iregex:GROUP[0-9]"),  "iregex matches case-insensitively" );
	ok( !$m->("group1", "regex:GROUP[0-9]"),  "regex is case-sensitive: same pattern does not match" );
	ok( $m->("group1", "regex:^group[0-9]"),  "regex positive match" );
	ok( $m->("Group1", "iregex:roup"),        "patterns match unanchored" );

	ok( $m->("regex:", "regex:"),
			"bare 'regex:' with no pattern falls back to exact match" );

	my $res = eval { $m->("group1", "regex:[unclosed") };
	is( $@, '', "malformed pattern does not die" );
	ok( !$res, "malformed pattern is treated as no-match" );

	# write-time compile check used by update_outage
	my $v = \&NMISNG::Outage::invalid_selector_pattern;

	ok( !defined $v->("group1"),            "plain string passes validation" );
	ok( !defined $v->("regex:^group[0-9]"), "valid regex entry passes validation" );
	ok( !defined $v->("iregex:GROUP"),      "valid iregex entry passes validation" );
	ok( !defined $v->("/gr.up/i"),          "valid regex-string passes validation" );
	ok( !defined $v->(undef),               "undef passes validation (dropped elsewhere)" );

	like( $v->("regex:[unclosed"),  qr/Unmatched \[/, "malformed regex entry is rejected" );
	like( $v->("iregex:(unclosed"), qr/Unmatched \(/, "malformed iregex entry is rejected" );
	like( $v->("/[unclosed/"),      qr/Unmatched \[/, "malformed regex-string is rejected" );

	# length cap: compiling says nothing about execution cost, and these
	# patterns run inside polling, so oversized ones are rejected at write time.
	# the cap comes from config item max_outage_pattern_length, default 256
	ok( !defined $v->("regex:" . ("a" x 256)), "pattern at the 256-char cap passes validation" );
	like( $v->("regex:" . ("a" x 257)), qr/exceeds 256/, "pattern over the 256-char cap is rejected" );
	like( $v->("/" . ("a" x 257) . "/i"), qr/exceeds 256/, "regex-string over the cap is rejected" );
	like( $v->("regex:aaaa", 3), qr/exceeds 3/, "explicit max argument overrides the default cap" );
	ok( !defined $v->("regex:" . ("a" x 280), 300), "raised max argument admits a longer pattern" );
	like( $v->("regex:" . ("a" x 257), "bogus"), qr/exceeds 256/, "non-numeric max falls back to the default" );

	# the matcher enforces the same cap on stored patterns (hand-edited files
	# bypass write-time validation): oversized means logged no-match, not a stall
	ok( !$m->(("a" x 300), "regex:" . ("a" x 257)),
			"oversized stored pattern is refused at match time" );
	ok( $m->(("a" x 300), "regex:" . ("a" x 256)),
			"stored pattern at the cap still matches" );
}

# --- config + isolated database -------------------------------------------
# from here on we need config and MongoDB; assertions have already run,
# so on failure we finish early instead of skip_all
# only attempt the load if conf/ already exists (loadConfTable would create
# the directory as a side effect in a bare checkout), and never die on it
my $confdir = "$FindBin::Bin/../conf";
my $C = (-d $confdir)? eval { NMISNG::Util::loadConfTable( dir => $confdir ) } : undef;
if (!$C or !keys %$C)
{
	diag("skipping integration tests: cannot load config from $confdir");
	done_testing();
	exit(0);
}
$C->{debug}   = $debug;
$C->{db_name} = "nmisng_outage_check_t_" . time;

my $logger = NMISNG::Log->new( level => $debug // "warn", path => undef );

# NMISNG->new dies if MongoDB is unreachable, hence the eval
my $nmisng = eval { NMISNG->new( config => $C, log => $logger ) };
if (!$nmisng)
{
	diag("skipping integration tests: cannot construct NMISNG (MongoDB unreachable?): $@");
	done_testing();
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
	diag("skipping integration tests: cannot save test node (MongoDB unreachable?): $err");
	done_testing();
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
	out_now_regex_pos => {
		id => "out_now_regex_pos", description => "case-sensitive regex group, matches",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "regex:^group[0-9]" ] } },
	},
	out_now_regex_case => {
		id => "out_now_regex_case", description => "same pattern as the iregex outage but case-sensitive: no match",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "regex:GROUP[0-9]" ] } },
	},
	out_now_mixed => {
		id => "out_now_mixed", description => "mixed exact + regex entries, regex one matches",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "no_such_group", "iregex:GROUP[0-9]" ] } },
	},
	out_now_badregex => {
		id => "out_now_badregex", description => "malformed pattern must not crash check_outages",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => [ "regex:[unclosed" ] } },
	},
	# note: node->save() syncs the catchall data from the node configuration,
	# so only config-derived keys (group, netType, roleType, ...) exist in it
	out_now_catchall => {
		id => "out_now_catchall", description => "catchall.data property selector with pattern",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { "catchall.data.netType" => [ "iregex:^WAN\$" ] } },
	},
	# scalar (non-array) selector values: the prefix form must behave the same
	# as an array entry, and an oversized stored /.../ regex-string must be a
	# no-match instead of running uncapped
	out_now_scalar_regex => {
		id => "out_now_scalar_regex", description => "scalar regex: selector value, matches",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => "regex:^group[0-9]" } },
	},
	out_now_scalar_slash_long => {
		id => "out_now_scalar_slash_long", description => "oversized scalar /.../ regex-string, capped to no-match",
		frequency => "once", start => $now - $HR, end => $now + $HR,
		options => {}, selector => { node => { group => "/" . ("a" x 300) . "/" } },
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
# eval because the table contains a malformed pattern (out_now_badregex),
# which used to kill check_outages outright
my $res = eval { NMISNG::Outage::check_outages( nmisng => $nmisng, node => $node, time => $now ) };
is( $@, '', "check_outages does not die despite malformed selector pattern" );
is( $res->{success}, 1, "check_outages succeeded at now" )
	or diag( Dumper($res) );

my $cur = ids( $res->{current} );
my $fut = ids( $res->{future} );
my $pst = ids( $res->{past} );

ok( $cur->{out_now_name},        "exact-name outage is current (in window)" );
ok( $cur->{out_now_iregex},      "iregex outage is current (OMK-1113 match)" );
ok( !$cur->{out_now_regex_nomatch}, "non-matching regex outage is NOT current" );
ok( $cur->{out_now_regex_pos},   "case-sensitive regex outage is current" );
ok( !$cur->{out_now_regex_case}, "same pattern case-sensitive is NOT current (regex vs iregex)" );
ok( $cur->{out_now_mixed},       "mixed exact+regex selector is current (regex entry matched)" );
ok( !$cur->{out_now_badregex},   "malformed-pattern outage is NOT current" );
ok( $cur->{out_now_catchall},    "catchall.data property selector outage is current" );
ok( $cur->{out_now_scalar_regex}, "scalar regex: selector value is honoured as a pattern" );
ok( !$cur->{out_now_scalar_slash_long}, "oversized scalar regex-string is NOT current (capped)" );
ok( !$cur->{out_future},         "future outage is not current" );
ok( !$cur->{out_past},           "past outage is not current" );

ok( $fut->{out_future}, "future-windowed outage is in future list" );
ok( $pst->{out_past},   "past-windowed outage is in past list" );

# non-matching selectors must not leak into any bucket
for my $absent (qw(out_now_regex_nomatch out_now_regex_case out_now_badregex))
{
	ok( !$fut->{$absent} && !$pst->{$absent},
		"$absent absent from every bucket" );
}

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
