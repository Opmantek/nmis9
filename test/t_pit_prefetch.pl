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

# --- read path: buffer hit returns SAME structure as a live find ---
{
  my $ruuid = "aaaa1111-0000-0000-0000-000000000001";
  my $node = $nmisng->node(uuid=>$ruuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_read");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();
  my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e0"}, path_keys=>["ifDescr"]);
  my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $inv->data({index=>1, ifIndex=>1, ifDescr=>"e0"}); $inv->save(node=>$node);
  # write one real latest_data reading via the normal pit path
  $inv->add_timed_data(data=>{ifInOctets=>100}, derived_data=>{ifInUtil=>10},
                       subconcept=>"interface", time=>1234, node=>$node);

  my $live = $inv->get_newest_timed_data();          # no buffer -> live find
  ok($live->{success}, "live read ok");
  is($live->{data}{interface}{ifInOctets}, 100, "live read has data");

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $ruuid);
  my $cached = $inv->get_newest_timed_data();        # buffer active -> served from buffer
  is_deeply($cached, $live, "buffer hit returns identical structure to live find");

  # mutating the returned cached structure must NOT corrupt the buffer (clone-on-read)
  $cached->{data}{interface}{ifInOctets} = -1;
  my $again = $inv->get_newest_timed_data();
  is($again->{data}{interface}{ifInOctets}, 100, "buffer entry unaffected by caller mutation (clone-on-read)");

  # from_timed bypasses the buffer (reads timed_<concept>)
  my $ft = $inv->get_newest_timed_data(from_timed => 1);
  ok($ft->{success}, "from_timed read still works (bypasses buffer)");
  undef $guard;
}

# --- write-through: read-after-write returns the NEW reading (thresholds case) ---
{
  my $wuuid = "bbbb2222-0000-0000-0000-000000000002";
  my $node = $nmisng->node(uuid=>$wuuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_write");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();
  my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e1"}, path_keys=>["ifDescr"]);
  my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $inv->data({index=>1, ifIndex=>1, ifDescr=>"e1"}); $inv->save(node=>$node);
  # add_timed_data API: singular subconcept scalar + data = that subconcept's metrics hash
  # (NOT a plural subconcepts array, NOT data keyed by subconcept), no flush for a direct write.
  $inv->add_timed_data(data=>{ifInOctets=>100}, derived_data=>{},
                       subconcept=>"interface", time=>1000, node=>$node);  # previous

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $wuuid);
  is($inv->get_newest_timed_data->{data}{interface}{ifInOctets}, 100, "buffer holds previous before write-through");

  # new reading this cycle -> write-through must update the buffer in memory
  $inv->add_timed_data(data=>{ifInOctets=>250}, derived_data=>{},
                       subconcept=>"interface", time=>2000, node=>$node);
  is($inv->get_newest_timed_data->{data}{interface}{ifInOctets}, 250, "buffer reflects new reading after write-through (read-after-write)");
  is($inv->get_newest_timed_data->{time}, 2000, "write-through updated the time too");
  undef $guard;
}

$nmisng->get_db()->drop();
done_testing;
