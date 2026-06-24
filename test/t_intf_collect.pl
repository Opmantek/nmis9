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
        $S->{snmp}{session} = 0;
    }
    if ($spec->{custom_iflastchange}) {
        $S->{mdl}{custom}{interface}{ifLastChange} = 'true';
    }
    # bulk_save=0: force per-interface save path by localising the constant to 0.
    # BULK_TIMED_DATA is a compile-time constant (use constant BULK_TIMED_DATA => 1)
    # with no config knob, so we override the symbol table entry for this call only.
    if (defined $spec->{bulk_save} && $spec->{bulk_save} == 0) {
        no warnings 'redefine';
        local *NMISNG::Node::BULK_TIMED_DATA = sub () { 0 };
        $h->reset_capture();
        NMISNG::DB::reset_db_stats() if $ENV{SHOW_DBSTATS};
        $node->collect_intf_data(sys=>$S, catchall_inventory=>$catchall);
        if ($ENV{SHOW_DBSTATS}) {
            my $stats = NMISNG::DB::get_db_stats();
            diag("[$spec->{name}] find count: " . ($stats->{counts}{find} // 0));
        }
        my $final = $nmisng->get_inventory_model(cluster_id=>$node->cluster_id,
                      node_uuid=>$node->uuid, concept=>"interface")->data;
        $h->assert_golden($spec->{name}, $h->captured(), $final);
        return;
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

# 12. bulk_save off (force per-interface save path)
run_case({ name=>"bulk_save_off",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1}, bulk_save=>0 });

# 13. over-100 interfaces: exercises field cutback path
run_case({ name=>"over_cutback", seed=>[], walk=>{count=>150}, do_update=>1 });

$nmisng->get_db()->drop();
remove_tree($rrd_dir) if -d $rrd_dir;
done_testing;
