#!/usr/bin/perl
#
# t_collect_services.pl - OMK-12742
#
# Regression test for the false "Service Down" cascade: a service-type service
# must NOT be reported down when the hrSWRunTable process read failed or was
# incomplete this cycle (agent rebooting / too slow), only when the read
# succeeded and the process is genuinely absent.
#
# Uses NMISNG::Snmp::Mock injected into a Sys object (same pattern as
# t_polling.pl). Requires a MongoDB (creates a temporary database).
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use Data::Dumper;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Snmp::Mock;

# ------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);
$C->{db_name} = "t_collect_services-" . time;

my $nmisng = NMISNG->new(config => $C, log => NMISNG::Log->new(level => 'fatal'));
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

# ------------------------------------------------------------
# Test Services table, injected via loadTable override so we don't
# depend on / clobber the container's conf/Services.nmis.
# ------------------------------------------------------------
my %TEST_SERVICES = (
	TestProc => {
		Name               => 'TestProc',
		Service_Type       => 'service',
		Service_Name       => 'testprocd',
		Service_Parameters => '',
		Poll_Interval      => '0',
		Description        => 'OMK-12742 test service',
	},
	BadType => {
		Name               => 'BadType',
		Service_Type       => 'bogus',   # not a recognised handler -> config error
		Service_Name       => 'x',
		Service_Parameters => '',
		Poll_Interval      => '0',
		Description        => 'OMK-12742 invalid-type service',
	},
);
{
	no warnings 'redefine';
	my $orig_loadTable = \&NMISNG::Util::loadTable;
	*NMISNG::Util::loadTable = sub {
		my %a = @_;
		return { %TEST_SERVICES } if (($a{name} // '') eq 'Services');
		return $orig_loadTable->(@_);
	};
}

# Skip real RRD I/O (same approach as t_polling.pl)
{
	no warnings 'redefine';
	*NMISNG::Sys::create_update_rrd = sub { return 1; };
}

# ------------------------------------------------------------
# hrSWRunTable OID bases
# ------------------------------------------------------------
use constant {
	OID_sysObjectID   => '1.3.6.1.2.1.1.2.0',
	OID_hrSWRunName   => '1.3.6.1.2.1.25.4.2.1.2',
	OID_hrSWRunPath   => '1.3.6.1.2.1.25.4.2.1.4',
	OID_hrSWRunParam  => '1.3.6.1.2.1.25.4.2.1.5',
	OID_hrSWRunType   => '1.3.6.1.2.1.25.4.2.1.6',
	OID_hrSWRunStatus => '1.3.6.1.2.1.25.4.2.1.7',
	OID_hrSWRunPerfCPU=> '1.3.6.1.2.1.25.5.1.1.1',
	OID_hrSWRunPerfMem=> '1.3.6.1.2.1.25.5.1.1.2',
};

# Build a mock walk_data hash for a set of processes.
# procs: arrayref of { idx, name, status(int, default 2=runnable) }
# opt:   no_status => 1  (omit the status column entirely = partial read)
sub proc_walk
{
	my ($procs, %opt) = @_;
	my %w = ( OID_sysObjectID() => '1.3.6.1.4.1.8072.3.2.10' );
	for my $p (@$procs)
	{
		my $i = $p->{idx};
		$w{ OID_hrSWRunName()  . ".$i" } = $p->{name};
		$w{ OID_hrSWRunPath()  . ".$i" } = "/usr/sbin/" . $p->{name};
		$w{ OID_hrSWRunParam() . ".$i" } = '';
		$w{ OID_hrSWRunType()  . ".$i" } = 4;          # application
		$w{ OID_hrSWRunStatus(). ".$i" } = ($p->{status} // 2) unless $opt{no_status};
		$w{ OID_hrSWRunPerfCPU().".$i" } = 10;
		$w{ OID_hrSWRunPerfMem().".$i" } = 1000;
	}
	return \%w;
}

# ------------------------------------------------------------
# Run collect_services for one scenario on a fresh node.
# returns the node so the caller can inspect events.
# ------------------------------------------------------------
my $node_seq = 0;
sub run_case
{
	my (%args) = @_;
	my $walk = $args{walk};

	$node_seq++;
	my $name = "t_cs_node_$node_seq";
	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$node->cluster_id($C->{cluster_id});
	$node->name($name);
	$node->configuration({
		host      => "127.0.0.1",
		group     => "TestGroup",
		netType   => "default",
		roleType  => "default",
		model     => "TestSnmp",
		active    => "true",
		collect   => "true",
		ping      => "false",
		community => "public",
		version   => "snmpv2c",
		services  => [ "TestProc" ],
	});
	my ($op, $err) = $node->save();
	die "save failed for $name: $err" if ($err);

	my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system");
	die "catchall failed for $name: $cerr" if ($cerr);
	my $cd = $catchall->data_live();
	$cd->{host}     = "127.0.0.1";
	$cd->{nodeType} = "server";
	$cd->{name}     = $name;

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(
		node => $node, snmp => 1, wmi => 0, update => 0, force => 0,
		catchall_inventory => $catchall,
	);
	$S->{snmp} = NMISNG::Snmp::Mock->new(
		nmisng => $nmisng, name => $name, walk_data => $walk,
	);
	$S->open();
	# simulate an SNMP failure on the walk (e.g. agent timeout) if requested
	$S->{snmp}->force_error($args{snmp_error}) if (defined $args{snmp_error});
	# node legitimately has snmp configured; make sure the walk is allowed
	$S->status->{snmp_enabled} = 1;
	$S->status->{wmi_enabled}  = 0;

	$node->collect_services(
		sys => $S, snmp => 'true', wmi => 'false', force => 1,
		catchall_inventory => $catchall,
	);

	return $node;
}

# ------------------------------------------------------------
# Cases
# ------------------------------------------------------------
diag("=== OMK-12742 collect_services regression ===");

# 1. Full read, target process running -> service UP, no Service Down
{
	my $node = run_case(walk => proc_walk([ { idx => 1, name => 'testprocd', status => 2 } ]));
	ok(!$node->eventExist("Service Down", "TestProc"),
		"full read + process running: no Service Down");
}

# 2. Walk failed with an SNMP timeout -> must NOT assert down
{
	my $node = run_case(walk => proc_walk([]), snmp_error => "Connection timed out");
	ok(!$node->eventExist("Service Down", "TestProc"),
		"SNMP walk timeout: no Service Down (OMK-12742 mode A)");
}

# 3. Partial read (name returned, status column missing) -> must NOT assert down
{
	my $node = run_case(walk => proc_walk([ { idx => 1, name => 'testprocd' } ], no_status => 1));
	ok(!$node->eventExist("Service Down", "TestProc"),
		"partial process read (no status): no Service Down (OMK-12742 mode B)");
}

# 4. Full read, target process genuinely absent -> Service Down MUST be raised
{
	my $node = run_case(walk => proc_walk([ { idx => 1, name => 'systemd', status => 2 } ]));
	ok($node->eventExist("Service Down", "TestProc"),
		"full read + process absent: Service Down raised (true positive preserved)");
}

# 5. Service Configuration Error clears when the offending service is removed
#    from the node config (OMK-12742 item 2 - the historic-cleanup clear).
{
	my $name = "t_cs_cfgerr";
	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$node->cluster_id($C->{cluster_id});
	$node->name($name);
	$node->configuration({
		host => "127.0.0.1", group => "TestGroup", netType => "default",
		roleType => "default", model => "TestSnmp", active => "true",
		collect => "true", ping => "false", community => "public",
		version => "snmpv2c", services => [ "BadType" ],
	});
	my ($op, $err) = $node->save();
	die "save failed: $err" if ($err);

	my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system");
	die "catchall failed: $cerr" if ($cerr);
	my $cd = $catchall->data_live();
	$cd->{host} = "127.0.0.1"; $cd->{nodeType} = "server"; $cd->{name} = $name;

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(node => $node, snmp => 1, wmi => 0, update => 0, force => 0,
		catchall_inventory => $catchall);
	$S->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => $name,
		walk_data => proc_walk([]));
	$S->open();
	$S->status->{snmp_enabled} = 1;
	$S->status->{wmi_enabled}  = 0;

	# phase 1: invalid service type is configured -> config error raised
	$node->collect_services(sys => $S, snmp => 'true', wmi => 'false', force => 1,
		catchall_inventory => $catchall);
	ok($node->eventExist("Service Configuration Error", "BadType"),
		"invalid service type raises Service Configuration Error");

	# phase 2: remove the offending service from the node config -> error must clear
	my $cfg = $node->configuration();
	$cfg->{services} = [];
	$node->configuration($cfg);
	$node->save();

	$node->collect_services(sys => $S, snmp => 'true', wmi => 'false', force => 1,
		catchall_inventory => $catchall);
	ok(!$node->eventExist("Service Configuration Error", "BadType"),
		"Service Configuration Error cleared after service removed (OMK-12742 item 2)");
}

# 7. A service that did NOT exist in the Services table (config error raised)
#    and then "comes back" (added to the table) must have its config error
#    cleared. This is not handled by the removal scan (the service is still in
#    the node's list); it should be cleared by the existing valid-dispatch clear.
{
	delete $TEST_SERVICES{ComeBack};   # phase 1: absent from the Services table
	my $name = "t_cs_comeback";
	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$node->cluster_id($C->{cluster_id});
	$node->name($name);
	$node->configuration({
		host => "127.0.0.1", group => "TestGroup", netType => "default",
		roleType => "default", model => "TestSnmp", active => "true",
		collect => "true", ping => "false", community => "public",
		version => "snmpv2c", services => [ "ComeBack" ],
	});
	my ($op, $err) = $node->save();
	die "save failed: $err" if ($err);

	my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system");
	die "catchall failed: $cerr" if ($cerr);
	my $cd = $catchall->data_live();
	$cd->{host} = "127.0.0.1"; $cd->{nodeType} = "server"; $cd->{name} = $name;

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(node => $node, snmp => 1, wmi => 0, update => 0, force => 0,
		catchall_inventory => $catchall);
	$S->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => $name,
		walk_data => proc_walk([ { idx => 1, name => 'systemd', status => 2 } ]));
	$S->open();
	$S->status->{snmp_enabled} = 1;
	$S->status->{wmi_enabled}  = 0;

	# phase 1: service missing from the table -> config error raised
	$node->collect_services(sys => $S, snmp => 'true', wmi => 'false', force => 1,
		catchall_inventory => $catchall);
	ok($node->eventExist("Service Configuration Error", "ComeBack"),
		"missing service raises Service Configuration Error");

	# phase 2: service comes back into the table (valid) -> error must clear
	$TEST_SERVICES{ComeBack} = {
		Name => 'ComeBack', Service_Type => 'service', Service_Name => 'comebackd',
		Service_Parameters => '', Poll_Interval => '0', Description => 'returned service',
	};
	$node->collect_services(sys => $S, snmp => 'true', wmi => 'false', force => 1,
		catchall_inventory => $catchall);
	ok(!$node->eventExist("Service Configuration Error", "ComeBack"),
		"config error cleared after service returns to the table (OMK-12742)");
}

cleanup();
done_testing();
