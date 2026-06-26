#!/usr/bin/perl
# Throwaway acceptance measurement: count nodes-collection finds during a real collect,
# to show the node_obj change removes the redundant per-save node re-resolves.
#
# OPT-IN ONLY. This performs a real SNMP collect against a live node, so it is skipped
# by default and stays inert under broad runs such as `prove test/t_*.pl`. To run it,
# name the node via the NMIS_REALNODE env var:
#   NMIS_REALNODE=realnode188 perl test/t_plugin_nodeobj_realnode.pl
# Compare the printed count against the same node on an unmodified origin/nmis9_dev checkout.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;

my $nodename = $ENV{NMIS_REALNODE};
plan skip_all => "real-node acceptance measurement; set NMIS_REALNODE=<nodename> to run"
	unless $nodename;

use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB; use Compat::NMIS;

my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

my $TOTAL = 0; my $ON = 0; my $orig = \&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub { my %a=@_;
    my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}";
    $TOTAL++ if ($ON && $n =~ /(?:^|\.)nodes$/);
    return $orig->(@_); }; }

my $node = $nmisng->node(name => $nodename) or BAIL_OUT("node $nodename not found");
$ON = 1; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); $ON = 0;
diag("nodes-collection finds during collect: $TOTAL");
ok(1, "collect completed for $nodename ($TOTAL nodes-collection finds)");
done_testing;
