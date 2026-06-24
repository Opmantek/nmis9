#!/usr/bin/perl
# t_intf_collect.pl - branch coverage + golden baseline for collect_intf_data/update_intf_info
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use Clone qw(clone);
use NMISNG; use NMISNG::Sys; use NMISNG::Util; use NMISNG::Log;
use NMISNG::Snmp::Mock;
use IntfTestHarness;

my $C = NMISNG::Util::loadConfTable(dir => "/usr/local/nmis9/conf");
$C->{db_name} = "t_intf_collect-$$";
my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = NMISNG->new(config => $C, log => $logger);
my $h = IntfTestHarness->new(nmisng => $nmisng, rrd_dir => "/tmp/t_intf_rrd_$$");
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

    $h->reset_capture();
    $node->collect_intf_data(sys=>$S, catchall_inventory=>$catchall);

    # final state: all interface inventory docs for this node
    my $final = $nmisng->get_inventory_model(cluster_id=>$node->cluster_id,
                  node_uuid=>$node->uuid, concept=>"interface")->data;
    $h->assert_golden($spec->{name}, $h->captured(), $final);
}

run_case({ name => "steady_state",
           seed => [ { index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1",
                       ifAdminStatus=>"up", ifOperStatus=>"up", collect=>"true",
                       real=>"true", historic=>0, enabled=>1 } ],
           walk => { count => 1 } });

$nmisng->get_db()->drop();
done_testing;
