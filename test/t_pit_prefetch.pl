#!/usr/bin/perl
# Tests for the per-node latest_data prefetch buffer (OMK-12375).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;
use NMISNG::Sys; use NMISNG::Snmp::Mock; use IntfTestHarness;

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

# --- integration: find-count drop, teardown, teardown-on-exception ---
{
  my $iuuid = "cccc3333-0000-0000-0000-000000000003";
  my $node = $nmisng->node(uuid=>$iuuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_int");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1,model=>"Generic"}); $node->save();
  my $N = 20;
  for my $i (1..$N) {
    my $p=$node->inventory_path(concept=>"interface",data=>{ifDescr=>"if$i"},path_keys=>["ifDescr"]);
    my ($inv)=$node->inventory(concept=>"interface",path=>$p,path_keys=>["ifDescr"],model_class=>"interface",create=>1);
    $inv->data({index=>$i,ifIndex=>$i,ifDescr=>"if$i",collect=>"true",real=>"true"});
    $inv->data_info(subconcept=>"interface",enabled=>1); $inv->enabled(1); $inv->historic(0); $inv->save(node=>$node);
    # seed a previous latest_data reading per interface (steady-state)
    # add_timed_data API: singular subconcept scalar + data = metrics hash, no flush.
    $inv->add_timed_data(data=>{ifInOctets=>$i}, derived_data=>{},
                         subconcept=>"interface", time=>1, node=>$node);
  }
  my $cp=$node->inventory_path(concept=>"catchall",data=>{},path_keys=>[]);
  my ($ca)=$node->inventory(concept=>"catchall",model_class=>"system",path=>$cp,path_keys=>[],create=>1);
  $ca->data_live->{ifNumber}=$N; $ca->save(node=>$node);

  # count latest_data finds during collect_intf_data, prefetch ON
  my @lf; my $orig=\&NMISNG::DB::find;
  { no warnings 'redefine';
    *NMISNG::DB::find = sub { my %a=@_; my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}"; push @lf,1 if $n=~/latest_data/; return $orig->(@_); }; }
  my $S=NMISNG::Sys->new(nmisng=>$nmisng);
  $S->init(node=>$node,snmp=>1,wmi=>0,catchall_inventory=>$ca);
  $S->{snmp}=NMISNG::Snmp::Mock->new(nmisng=>$nmisng,name=>$node->name,walk_data=>IntfTestHarness::generate_interface_walk(count=>$N));
  $S->{snmp}{session}=1;
  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $iuuid);   # 1 latest_data find here
  @lf=();
  $node->collect_intf_data(sys=>$S, catchall_inventory=>$ca);
  { no warnings 'redefine'; *NMISNG::DB::find = $orig; }   # restore: don't leak the counting wrapper
  ok(scalar(@lf) <= 1, "with prefetch, collect_intf_data issues <=1 latest_data find for $N interfaces (got ".scalar(@lf).")");
  undef $guard;
  ok(!exists $nmisng->{_pit_prefetch}{$iuuid}, "buffer torn down after cycle");

  # teardown on exception
  eval { my $g = $nmisng->pit_prefetch_begin(node_uuid => $iuuid); die "boom\n"; };
  ok(!exists $nmisng->{_pit_prefetch}{$iuuid}, "buffer torn down even when scope exits via die");
}
$nmisng->get_db()->drop();
done_testing;
