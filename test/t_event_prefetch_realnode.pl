#!/usr/bin/perl
# Count events-collection finds during a real collect, attributing by caller.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use NMISNG; use NMISNG::Util; use NMISNG::Log; use Compat::NMIS;
my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
my $TOTAL=0; my $ON=0; my $orig=\&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub { my %a=@_;
    my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}";
    $TOTAL++ if ($ON && $n =~ /(?:^|\.)events$/); return $orig->(@_); }; }
my $node = $nmisng->node(name => $ARGV[0] // "realnode188") or die "node not found\n";
$ON=1; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); $ON=0;
print "events-collection finds during collect: $TOTAL\n";
