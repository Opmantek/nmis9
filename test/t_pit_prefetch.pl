#!/usr/bin/perl
# Tests for the per-node latest_data prefetch buffer (OMK-12668).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;
use NMISNG::Sys; use NMISNG::Snmp::Mock;

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_pitpf-$$";
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

# Self-contained interface SNMP walk for the integration block below. Inlined (was
# IntfTestHarness::generate_interface_walk) so this prefetch test does not depend on the
# collect-intf branch's harness, letting OMK-12668 stand alone on nmis9_dev.
sub _iface_walk {
  my $n = shift;
  my %w = ('1.3.6.1.2.1.2.1.0' => $n);
  for my $i (1..$n) {
    $w{"1.3.6.1.2.1.2.2.1.1.$i"} = $i;
    $w{"1.3.6.1.2.1.2.2.1.2.$i"} = "GigabitEthernet0/$i";
    $w{"1.3.6.1.2.1.2.2.1.3.$i"} = 6;
    $w{"1.3.6.1.2.1.2.2.1.5.$i"} = 1000000000;
    $w{"1.3.6.1.2.1.2.2.1.6.$i"} = sprintf("00 11 22 %02x %02x %02x", ($i>>16)&255, ($i>>8)&255, $i&255);
    $w{"1.3.6.1.2.1.2.2.1.7.$i"} = 1;
    $w{"1.3.6.1.2.1.2.2.1.8.$i"} = 1;
    $w{"1.3.6.1.2.1.2.2.1.9.$i"} = 500;
  }
  return \%w;
}

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

# --- kill switch: parsed as an NMIS boolean (getbool), not raw Perl truthiness ---
# the string "false" is TRUTHY in Perl, so a raw `// 1` check would leave it enabled.
for my $off (0, "0", "false", "no", "f", "") {
  $nmisng->config->{pit_prefetch_enabled} = $off;
  is($nmisng->pit_prefetch_begin(node_uuid => $node_uuid), undef,
     "begin disabled when pit_prefetch_enabled='$off'");
  ok(!exists $nmisng->{_pit_prefetch}{$node_uuid}, "no buffer created when disabled ('$off')");
}
for my $on (1, "1", "true", "yes", "t") {
  $nmisng->config->{pit_prefetch_enabled} = $on;
  my $g = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
  isa_ok($g, "NMISNG::Guard", "begin enabled when pit_prefetch_enabled='$on'");
  undef $g;
}
delete $nmisng->config->{pit_prefetch_enabled};
my $gdef = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
isa_ok($gdef, "NMISNG::Guard", "begin defaults ON when pit_prefetch_enabled unset");
undef $gdef;
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

# --- write-through must NOT update the buffer when the DB write fails (store runs post-commit) ---
{
  my $fuuid = "eeee5555-0000-0000-0000-000000000005";
  my $node = $nmisng->node(uuid=>$fuuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_failwrite");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();
  my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e2"}, path_keys=>["ifDescr"]);
  my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $inv->data({index=>1, ifIndex=>1, ifDescr=>"e2"}); $inv->save(node=>$node);
  $inv->add_timed_data(data=>{ifInOctets=>100}, derived_data=>{},
                       subconcept=>"interface", time=>1000, node=>$node);  # committed previous

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $fuuid);
  is($inv->get_newest_timed_data->{data}{interface}{ifInOctets}, 100, "buffer holds committed reading before the failing write");

  # force the latest_data upsert to fail; with the store placed post-commit it must NOT run
  my $orig = \&NMISNG::DB::update;
  my $err;
  { no warnings 'redefine';
    *NMISNG::DB::update = sub { return { success => 0, error => "boom" }; };
    $err = $inv->add_timed_data(data=>{ifInOctets=>999}, derived_data=>{},
                                subconcept=>"interface", time=>2000, node=>$node);
    *NMISNG::DB::update = $orig;   # restore: don't leak the failing stub
  }
  ok($err, "add_timed_data returns an error when the latest_data write fails (got: ".($err//'undef').")");
  my $after = $inv->get_newest_timed_data;
  is($after->{data}{interface}{ifInOctets}, 100, "buffer NOT updated after failed write (stays at committed reading)");
  is($after->{time}, 1000, "buffer time NOT advanced after failed write");
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
  $S->{snmp}=NMISNG::Snmp::Mock->new(nmisng=>$nmisng,name=>$node->name,walk_data=>_iface_walk($N));
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

# --- ping bypass: ping is written out-of-process by fastping, so it must NOT be served
#     from the buffer (would be stale); other concepts in the same buffer still serve. ---
{
  my $puuid = "dddd4444-0000-0000-0000-000000000004";
  my $node = $nmisng->node(uuid=>$puuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_ping");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();

  # a ping inventory + an interface inventory, both for this node (so both land in the buffer)
  my $pp = $node->inventory_path(concept=>"ping", data=>{}, path_keys=>[]);
  my ($pinginv) = $node->inventory(concept=>"ping", path=>$pp, path_keys=>[], create=>1);
  $pinginv->data({}); $pinginv->save(node=>$node);
  $pinginv->add_timed_data(data=>{loss=>0, avg=>5}, derived_data=>{},
                           subconcept=>"ping", time=>1000, node=>$node);   # value A (buffered)

  my $ip = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e0"}, path_keys=>["ifDescr"]);
  my ($intf) = $node->inventory(concept=>"interface", path=>$ip, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $intf->data({index=>1, ifIndex=>1, ifDescr=>"e0"}); $intf->save(node=>$node);
  $intf->add_timed_data(data=>{ifInOctets=>100}, derived_data=>{},
                        subconcept=>"interface", time=>1000, node=>$node);

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $puuid);   # buffer holds ping=A, interface=100
  is($pinginv->get_newest_timed_data->{data}{ping}{avg}, 5, "buffer seeded ping value A");

  # simulate the out-of-band fastping update: write a NEWER reading straight to latest_data,
  # bypassing add_timed_data so there is NO write-through to the in-memory buffer.
  my $upd = NMISNG::DB::update(
    collection => $nmisng->latest_data_collection,
    query      => { inventory_id => $pinginv->id },
    record     => { inventory_id => $pinginv->id, node_uuid => $puuid, time => 2000,
                    subconcepts => [{subconcept=>"ping", data=>{loss=>50, avg=>99}, derived_data=>{}}] },
    upsert     => 1 );
  ok($upd->{success}, "out-of-band fastping write to latest_data ok");

  # ping must bypass the buffer and return the LIVE value B (99), not the buffered A (5)
  my $pr = $pinginv->get_newest_timed_data;
  is($pr->{data}{ping}{avg}, 99, "ping read bypasses buffer, returns live fastping value B");
  is($pr->{time}, 2000, "ping read returns the newer live time, not the buffered time");

  # the interface in the SAME buffer is still served from the buffer (bypass is ping-specific)
  is($intf->get_newest_timed_data->{data}{interface}{ifInOctets}, 100, "interface still served from buffer (ping bypass is not a blanket disable)");
  undef $guard;
}

$nmisng->get_db()->drop();
done_testing;
