#!/usr/bin/perl
# Throwaway acceptance measurement: count nodes-collection finds during a real collect.
# Run on this branch (fixed) and on an unmodified origin/nmis9_dev checkout (baseline)
# to show the node_obj change removes the redundant per-save node re-resolves.
# Usage: perl test/t_plugin_nodeobj_realnode.pl [nodename]
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB; use Compat::NMIS;

my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

my $TOTAL = 0; my $ON = 0; my $orig = \&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub { my %a=@_;
    my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}";
    $TOTAL++ if ($ON && $n =~ /(?:^|\.)nodes$/);
    return $orig->(@_); }; }

my $node = $nmisng->node(name => $ARGV[0] // "realnode188") or die "node not found\n";
$ON = 1; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); $ON = 0;
print "nodes-collection finds during collect: $TOTAL\n";
