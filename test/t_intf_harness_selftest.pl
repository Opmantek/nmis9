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

my $walk = IntfTestHarness::generate_interface_walk(count => 3, admin => {2 => 2});
is($walk->{'1.3.6.1.2.1.2.1.0'}, 3, "ifNumber = count");
is($walk->{'1.3.6.1.2.1.2.2.1.1.2'}, 2, "ifIndex 2 present");
is($walk->{'1.3.6.1.2.1.2.2.1.7.2'}, 2, "admin override applied to idx 2");
is($walk->{'1.3.6.1.2.1.2.2.1.7.1'}, 1, "admin default up for idx 1");
done_testing;
