#!/usr/bin/perl
# Tests for the per-node latest_data prefetch buffer (OMK-12375).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_pitpf-$$";
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

# --- _pit_oid_str consistency ---
{
  package FakeHexOid; sub new { bless {h=>$_[1]}, $_[0] } sub hex { $_[0]{h} } sub can { $_[1] eq 'hex' ? \&hex : undef }
}
is(NMISNG::_pit_oid_str(undef), '', "_pit_oid_str undef -> ''");
is(NMISNG::_pit_oid_str("abc"), "abc", "_pit_oid_str scalar -> itself");
is(NMISNG::_pit_oid_str(FakeHexOid->new("deadbeef")), "deadbeef", "_pit_oid_str uses ->hex when available");

# --- store / lookup roundtrip; no-buffer returns undef ---
is($nmisng->pit_prefetch_lookup("nodeA","oid1"), undef, "lookup with no buffer -> undef");
$nmisng->pit_prefetch_store("nodeA","oid1",{time=>10, subconcepts=>[]});  # no-op, no buffer yet
is($nmisng->pit_prefetch_lookup("nodeA","oid1"), undef, "store is a no-op when no buffer active");

# manually open a buffer to test store/lookup primitives
$nmisng->{_pit_prefetch}{"nodeA"} = {};
$nmisng->pit_prefetch_store("nodeA","oid1",{time=>10, subconcepts=>[{subconcept=>"interface",data=>{x=>1}}]});
my $got = $nmisng->pit_prefetch_lookup("nodeA","oid1");
is($got->{time}, 10, "lookup returns stored doc");
is($nmisng->pit_prefetch_lookup("nodeA","missing"), undef, "lookup miss -> undef");
is($nmisng->pit_prefetch_lookup("nodeB","oid1"), undef, "cross-node lookup -> undef");
delete $nmisng->{_pit_prefetch}{"nodeA"};

# --- begin loads from latest_data, guard tears down ---
my $node_uuid = "11111111-2222-3333-4444-555555555555";
my $oid = NMISNG::DB::make_oid();   # a real OID of the driver's type
NMISNG::DB::insert(collection => $nmisng->latest_data_collection,
  record => { inventory_id => $oid, node_uuid => $node_uuid, time => 99,
              subconcepts => [{subconcept=>"interface", data=>{ifInOctets=>5}, derived_data=>{}}] });
{
  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
  isa_ok($guard, "NMISNG::Guard", "begin returns a guard");
  ok(exists $nmisng->{_pit_prefetch}{$node_uuid}, "buffer populated for node");
  my $hit = $nmisng->pit_prefetch_lookup($node_uuid, $oid);
  is($hit->{time}, 99, "begin loaded the seeded latest_data reading");
}
ok(!exists $nmisng->{_pit_prefetch}{$node_uuid}, "guard teardown removed the node buffer");

# --- kill switch: flag off => undef, no buffer ---
$nmisng->config->{pit_prefetch_enabled} = 0;
my $g2 = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
is($g2, undef, "begin returns undef when pit_prefetch_enabled is false");
ok(!exists $nmisng->{_pit_prefetch}{$node_uuid}, "no buffer created when disabled");
$nmisng->config->{pit_prefetch_enabled} = 1;

$nmisng->get_db()->drop();
done_testing;
