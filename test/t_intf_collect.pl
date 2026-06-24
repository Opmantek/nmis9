#!/usr/bin/perl
# t_intf_collect.pl - branch coverage + golden baseline for collect_intf_data/update_intf_info
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use Clone qw(clone);
use File::Path qw(remove_tree);
use NMISNG; use NMISNG::Sys; use NMISNG::Util; use NMISNG::Log;
use NMISNG::Snmp::Mock;
use NMISNG::DB;
use IntfTestHarness;

my $C = NMISNG::Util::loadConfTable();              # FindBin-relative: $Bin/../conf
$C = NMISNG::Util::loadConfTable(dir => "$FindBin::Bin/../conf")
    if (!$C || ref($C) ne "HASH" || !keys %$C);     # explicit portable fallback
die "Cannot load config" if (!$C || ref($C) ne "HASH" || !keys %$C);
$C->{db_name} = "t_intf_collect-$$";
my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = NMISNG->new(config => $C, log => $logger);
my $rrd_dir = "/tmp/t_intf_rrd_$$";
my $h = IntfTestHarness->new(nmisng => $nmisng, rrd_dir => $rrd_dir);
$h->install_capture();

my $node_seq = 0;
sub make_node {
    my $uuid = sprintf("c0ffee00-0000-0000-0000-%012d", ++$node_seq);
    my $n = $nmisng->node(uuid => $uuid, create => 1);
    $n->cluster_id($C->{cluster_id}); $n->name("intftest$node_seq");
    $n->configuration({ host => "127.0.0.1", group => "NMIS9", active => 1, collect => 1, model => "Generic" });
    $n->save(); return $n;
}

sub seed_interface {
    my ($node, $rec) = @_;
    my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>$rec->{ifDescr}}, path_keys=>["ifDescr"], partial=>0);
    my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"],
                                 model_class=>"interface", create=>1);
    $inv->data($rec);
    $inv->data_info(subconcept=>"interface", enabled=>1);
    $inv->historic($rec->{historic} // 0);
    $inv->enabled($rec->{enabled} // 1);
    $inv->save(node=>$node);
    return $inv;
}

sub run_case {
    my ($spec) = @_;
    my $node = make_node();
    seed_interface($node, $_) for @{$spec->{seed} // []};

    my $catchall_path = $node->inventory_path(concept=>"catchall", data=>{}, path_keys=>[]);
    my ($catchall) = $node->inventory(concept=>"catchall", model_class=>"system",
                                      path=>$catchall_path, path_keys=>[], create=>1);
    $catchall->data_live->{ifNumber} = $spec->{walk}{count} // scalar @{$spec->{seed}//[]};
    $catchall->save(node=>$node);

    my $S = NMISNG::Sys->new(nmisng=>$nmisng);
    $S->init(node=>$node, snmp=>1, wmi=>0,
             update => ($spec->{do_update}?'true':0), force=>($spec->{do_update}?1:0),
             catchall_inventory=>$catchall);
    $S->{snmp} = NMISNG::Snmp::Mock->new(nmisng=>$nmisng, name=>$node->name,
             walk_data => IntfTestHarness::generate_interface_walk(%{$spec->{walk}}));
    $S->{snmp}{session} = 1; # mock guard expects a session

    # new spec-key extensions
    if ($spec->{no_snmp}) {
        # collect_intf_data's guard is `if (!$S->status->{snmp_enabled})`, and
        # Sys::status (Sys.pm) computes snmp_enabled from `$S->{snmp}` being
        # truthy -- NOT from `$S->{snmp}{session}`. So to actually trigger the
        # early return we must make $S->{snmp} itself falsy.
        $S->{snmp} = 0;
    }
    if ($spec->{custom_iflastchange}) {
        $S->{mdl}{custom}{interface}{ifLastChange} = 'true';
    }

    $h->reset_capture();
    NMISNG::DB::reset_db_stats() if $ENV{SHOW_DBSTATS};
    $node->collect_intf_data(sys=>$S, catchall_inventory=>$catchall);
    if ($ENV{SHOW_DBSTATS}) {
        my $stats = NMISNG::DB::get_db_stats();
        diag("[$spec->{name}] find count: " . ($stats->{counts}{find} // 0));
    }

    # final state: all interface inventory docs for this node
    my $final = $nmisng->get_inventory_model(cluster_id=>$node->cluster_id,
                  node_uuid=>$node->uuid, concept=>"interface")->data;

    # optional white-box assertions run against the captured stream + persisted final
    # docs BEFORE the golden compare (so a focused invariant can be gated directly even
    # when it is invisible to / identical across the golden, e.g. db pollution checks).
    $spec->{post_check}->($node, $h->captured(), $final) if (ref($spec->{post_check}) eq 'CODE');

    $h->assert_golden($spec->{name}, $h->captured(), $final);
}

# 1. steady state: one seeded interface, walk matches -> no change needed
run_case({ name => "steady_state",
           seed => [ { index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1",
                       ifAdminStatus=>"up", ifOperStatus=>"up", collect=>"true",
                       real=>"true", historic=>0, enabled=>1 } ],
           walk => { count => 1 } });

# 2. new interface present in walk but not seeded -> needs_update -> created
run_case({ name=>"new_interface", seed=>[], walk=>{count=>2}, do_update=>1 });

# 3. ifIndex change: seeded ifDescr e0/1 at index 1, walk moves it to index 5
run_case({ name=>"ifindex_change",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1, _reindex=>{1=>5}}, do_update=>1 });

# 4. ifDescr change: seeded index1 ifDescr old, walk reports new descr
run_case({ name=>"ifdescr_change",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"OldName0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1}, do_update=>1 });

# 5. interface removed: seeded index2 not present in walk (count=1) -> historic
run_case({ name=>"interface_removed",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1},
         {index=>2, ifIndex=>2, ifDescr=>"GigabitEthernet0/2", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1} });

# 6. disabled interface: seeded enabled=0 -> not collected, not historic
run_case({ name=>"disabled_interface",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"false", historic=>0, enabled=>0}],
  walk=>{count=>1} });

# 7a. historic interface, attempt flag off (default): stays skipped
run_case({ name=>"historic_skip",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>1, enabled=>1}],
  walk=>{count=>1} });

# 8. clashing ifIndex: two seeded inventories with same ifIndex
run_case({ name=>"clashing_ifindex",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"A0/1", ifAdminStatus=>"up", ifOperStatus=>"up",
          collect=>"true", historic=>0, enabled=>1},
         {index=>1, ifIndex=>1, ifDescr=>"B0/1", ifAdminStatus=>"up", ifOperStatus=>"up",
          collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1} });

# 9. admin status transition up->down triggers update
run_case({ name=>"admin_transition",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1, admin=>{1=>2}}, do_update=>1 });

# 10. ifLastChange-based detection: requires model custom flag
run_case({ name=>"iflastchange_detect",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1, ifLastChangeSec=>0}],
  walk=>{count=>1}, custom_iflastchange=>1, do_update=>1 });

# 11. non-snmp node: snmp disabled -> early return, no writes
run_case({ name=>"non_snmp", seed=>[], walk=>{count=>1}, no_snmp=>1 });

# 12. bulk timed-data save path. do_update=>1 makes the interface collectable
# so phase 8 actually writes timed data; the golden records bulk_used=1 on the
# timed-data insert/upsert, i.e. the writes are batched via begin_bulk/end_bulk.
#
# NOTE on the non-bulk path: collect_intf_data gates batching on
# `if (BULK_TIMED_DATA == 1)` (Node.pm:4330) and BULK_TIMED_DATA is a
# `use constant ... => 1` (Node.pm:65) with no config knob. `use constant`
# is inlined at compile time, so the comparison is constant-folded to true
# when Node.pm is compiled; a runtime `local *NMISNG::Node::BULK_TIMED_DATA`
# override (as the brief suggested) has NO effect on the already-compiled
# code. Production therefore ALWAYS takes the bulk path -- the non-bulk
# branch is effectively dead code that cannot be driven from a test without
# modifying production. This case records the real (bulk) baseline; see the
# A4 report for the investigation. (coverage follow-up: the non-bulk
# timed-data branch needs a production-side knob to be testable.)
run_case({ name=>"bulk_timed_save",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1}, do_update=>1 });

# 13. over-100 interfaces: exercises field cutback path
run_case({ name=>"over_cutback", seed=>[], walk=>{count=>150}, do_update=>1 });

# 14. B1-object phase-8 dirty save (OMK-12375 reuse path gate).
# A SEEDED, collectable interface whose admin/ifDescr match the walk so it does NOT
# need update_intf_info -> phase 8 reuses the hand-built phase-1 ("B1") inventory
# object rather than the clean $maybenew from update_intf_info. The walk flips oper
# up->dormant (5): dormant is NOT a relevant transition (it stays within the
# up/ok/dormant set) so it does not trigger _needs_update, but phase 8 DOES write the
# new ifOperStatus -> a real per-interface inventory dirty save on the reused object.
# counters=>1 makes the interface genuinely collectable (real traffic values).
#
# This case is the gate for the phase-1 clone being taken BEFORE the _id/enabled/
# historic injection: a post-injection clone leaves a nested data._id on the reused
# object. The behavioural golden is recorded against PRE-REFACTOR code (commit
# 5180093e, whose phase 8 freshly reloads by _id) so it pins this path to the old
# reload behaviour; the white-box post_check directly asserts the persisted inventory
# data carries no _id (the pollution invariant, which the golden alone cannot see
# because save() dirty-tracking cancels a nested data._id either way).
run_case({ name=>"b1_object_dirty_save",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", real=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1, oper=>{1=>5}, counters=>1}, do_update=>1,
  post_check => sub {
      my ($node, $cap, $final) = @_;
      # (a) prove this case actually exercised a per-interface inventory dirty save on
      #     the reused object: there must be an op whose $set carries a data.* key
      #     (not just the phase-9 historic pair / timed-data inserts).
      my $saw_data_save = 0;
      for my $op (@{$cap->{db}}) {
          next unless (ref($op->{record}) eq 'HASH' && ref($op->{record}{'$set'}) eq 'HASH');
          $saw_data_save = 1 if (grep { /^data\./ } keys %{$op->{record}{'$set'}});
      }
      ok($saw_data_save, "b1_object_dirty_save: phase 8 did a per-interface inventory data save");
      # (b) the pollution invariant: persisted interface inventory data must have no _id
      #     (matches a fresh reload; would fail if a post-injection clone leaked data._id).
      my $clean = 1;
      for my $raw (@$final) {
          $clean = 0 if (ref($raw->{data}) eq 'HASH' && exists $raw->{data}{_id});
      }
      ok($clean, "b1_object_dirty_save: persisted inventory data has no nested _id");
  },
});

$nmisng->get_db()->drop();
remove_tree($rrd_dir) if -d $rrd_dir;
done_testing;
