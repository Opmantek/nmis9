#!/usr/bin/perl
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;
use IntfTestHarness;

my $h = IntfTestHarness->new(nmisng => undef, rrd_dir => "/tmp/h_$$");
$h->install_capture();
$h->reset_capture();
# simulate a db write through the patched layer
eval { NMISNG::DB::update(collection => undef, query => {x=>1}, record => {data=>{ifDescr=>"e0"}, lastupdate=>123}); };
my $cap = $h->captured();
is(scalar @{$cap->{db}}, 1, "one db write captured");
my $norm = $h->normalise($cap);
ok(!exists $norm->{db}[0]{record}{lastupdate}, "lastupdate stripped by normalise");
is($norm->{db}[0]{record}{data}{ifDescr}, "e0", "content preserved");
done_testing;
