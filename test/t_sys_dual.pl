#!/usr/bin/perl
#
# t_sys_dual.pl - Dual-protocol (SNMP + WMI) polling test.
#
# Exercises a single Sys/Node configured with BOTH snmp=1 and wmi=1
# simultaneously. Verifies that engines() dispatches to both engines
# in one loadInfo/getData call, that failures in one engine do not
# poison the other, and that disable_source() operates on the right
# engine without disturbing the other.
#
# Complements t_sys.pl (SNMP-only and WMI-only) and t_polling.pl
# (separate SNMP and WMI nodes). This is the only test that currently
# exercises concurrent engines on the same Sys object.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Deep;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;

use NMISNG::Snmp::Mock;
use NMISNG::WMI::Mock;

# ============================================================
# Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

$C->{db_name} = "t_sys_dual-" . time;

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

# Load fixtures used by the Mock backends
my $snmp_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
my %snmp_walk;
for my $k (keys %$snmp_walk_raw) {
	$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
}

my $wmi_data_raw = decode_json(read_file("$FindBin::Bin/testdata/wmi_test.json"));
my %wmi_data;
for my $k (keys %$wmi_data_raw) {
	$wmi_data{$k} = $wmi_data_raw->{$k} unless $k =~ /^_/;
}

# Neutralise RRD writes
{
	no warnings 'redefine';
	*NMISNG::Sys::create_update_rrd = sub {
		my ($self, %args) = @_;
		if (ref($args{inventory})) {
			my $type = $args{type} || 'unknown';
			$args{inventory}->set_subconcept_type_storage(
				subconcept => $type, type => 'rrd',
				data => "/nodes/$self->{name}/mock-$type.rrd"
			);
		}
		return 1;
	};
}

# Create a dual-protocol test node
my $dual_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$dual_node->cluster_id($C->{cluster_id});
$dual_node->name("test_dual_node");
$dual_node->configuration({
	host        => "127.0.0.3",
	group       => "TestGroup",
	netType     => "default",
	roleType    => "default",
	threshold   => 1,
	model       => "TestDual",
	collect     => "true",
	ping        => "false",
	community   => "public",
	version     => "snmpv2c",
	wmiusername => "testuser",
	wmipassword => "testpass",
});
my ($op, $err) = $dual_node->save();
ok(!$err, "dual-protocol test node saved") or diag("Error: $err");

my ($dual_catchall, $cerr) = $dual_node->inventory(concept => "catchall", model_class => "system");
ok(!$cerr, "dual-protocol catchall created");

# Build a Sys with BOTH engines configured.
sub make_dual_sys
{
	my %args = @_;
	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(
		node => $dual_node, snmp => 1, wmi => 1,
		update => 'true', force => 1,
		catchall_inventory => $dual_catchall,
	);
	# Replace real transports with mocks so no network/WMI is touched.
	$S->{snmp} = NMISNG::Snmp::Mock->new(
		nmisng => $nmisng, name => "test_dual_node", walk_data => \%snmp_walk,
	);
	$S->{wmi} = NMISNG::WMI::Mock->new(
		wmi_data => \%wmi_data, host => '127.0.0.3', username => 'testuser',
	);
	$S->open() if $args{open};
	return $S;
}

# ============================================================
# Test A: engines/enabled_sources/engine accessors with both active
# ============================================================
diag("=== Test A: engine dispatch accessors ===");

my $S = make_dual_sys(open => 1);

my @engines = @{$S->engines};
is(scalar(@engines), 2, "engines() returns two engines when both SNMP and WMI configured");

# enabled_sources is derived from is_active, which reads $self->sys->{snmp}/{wmi}
my @sources = sort @{$S->enabled_sources};
is_deeply(\@sources, [qw(snmp wmi)],
	"enabled_sources returns ['snmp','wmi'] when both transports installed");

my $snmp_eng = $S->engine("snmp");
my $wmi_eng  = $S->engine("wmi");
ok($snmp_eng, "engine('snmp') returns an engine object");
ok($wmi_eng,  "engine('wmi') returns an engine object");
isa_ok($snmp_eng, 'NMISNG::Sys::Engine::SNMP');
isa_ok($wmi_eng,  'NMISNG::Sys::Engine::WMI');
is($snmp_eng->protocol_name, 'snmp', "SNMP engine protocol_name");
is($wmi_eng->protocol_name,  'wmi',  "WMI engine protocol_name");
is($snmp_eng->is_active, 1, "SNMP engine is_active when mock installed");
is($wmi_eng->is_active,  1, "WMI engine is_active when mock installed");

my $st = $S->status;
is($st->{snmp_enabled}, 1, "status: snmp_enabled = 1");
is($st->{wmi_enabled},  1, "status: wmi_enabled  = 1");
ok(!$st->{snmp_error}, "status: no snmp_error before any query");
ok(!$st->{wmi_error},  "status: no wmi_error before any query");

# known_sources is a hardcoded list; lock it in
is_deeply($S->known_sources, [qw(snmp wmi http)],
	"known_sources = ['snmp','wmi','http']");

# ============================================================
# Test B: loadInfo populates BOTH snmp- and wmi-sourced fields in one call
# ============================================================
diag("=== Test B: loadInfo dual-source ===");

my %target;
my $li_ok = $S->loadInfo(class => 'system', target => \%target, inventory => $dual_catchall);
ok($li_ok, "dual loadInfo returned success");

# SNMP-sourced fields come from snmpwalk_test.json
is($target{sysDescr},    $snmp_walk{'1.3.6.1.2.1.1.1.0'},  "loadInfo (snmp): sysDescr from walk data");
is($target{sysName},     $snmp_walk{'1.3.6.1.2.1.1.5.0'},  "loadInfo (snmp): sysName from walk data");
is($target{sysObjectID}, $snmp_walk{'1.3.6.1.2.1.1.2.0'},  "loadInfo (snmp): sysObjectID from walk data");

# WMI-sourced fields come from wmi_test.json
my $expected_caption = $wmi_data{"select Caption from Win32_OperatingSystem"}[0]{Caption};
my $expected_csname  = $wmi_data{"select CSName from Win32_OperatingSystem"}[0]{CSName};
is($target{winosname},  $expected_caption, "loadInfo (wmi): winosname from wmi_data");
is($target{winsysname}, $expected_csname,  "loadInfo (wmi): winsysname from wmi_data");

# ============================================================
# Test C: getData populates BOTH SNMP-only and WMI-only rrd sections
# ============================================================
diag("=== Test C: getData dual-source ===");

my $rrd = $S->getData(class => 'system', inventory => $dual_catchall);
ok(ref($rrd) eq "HASH", "dual getData returned hash");

# SNMP rrd section
ok(exists $rrd->{mib2ip}, "dual getData: mib2ip section present (snmp)");
is($rrd->{mib2ip}{ipInReceives}{value}, $snmp_walk{'1.3.6.1.2.1.4.3.0'},
	"mib2ip.ipInReceives matches snmp walk data");
is($rrd->{mib2ip}{ipOutRequests}{value}, $snmp_walk{'1.3.6.1.2.1.4.10.0'},
	"mib2ip.ipOutRequests matches snmp walk data");

# WMI rrd section
ok(exists $rrd->{wmiCpu}, "dual getData: wmiCpu section present (wmi)");
my $expected_cpu = $wmi_data{"select PercentProcessorTime from Win32_PerfFormattedData_PerfOS_Processor where Name='_Total'"}[0]{PercentProcessorTime};
is($rrd->{wmiCpu}{percentProcessor}{value}, $expected_cpu,
	"wmiCpu.percentProcessor matches wmi data");

# ============================================================
# Test D: partial failure - SNMP errors, WMI still succeeds
# ============================================================
# Use a fresh Sys so the prior test state doesn't leak.
diag("=== Test D: partial failure (SNMP errors, WMI works) ===");

my $S_fail = make_dual_sys(open => 1);

# Force SNMP transport to error on getarray; WMI mock stays healthy
$S_fail->{snmp}->force_error("transport timeout");

my %target_fail;
$S_fail->loadInfo(class => 'system', target => \%target_fail, inventory => $dual_catchall);

my $fst = $S_fail->status;
ok($fst->{snmp_error}, "partial fail: status->snmp_error set after SNMP transport failure: $fst->{snmp_error}");
ok(!$fst->{wmi_error}, "partial fail: status->wmi_error NOT set (WMI still healthy)");

# WMI data should still be populated despite SNMP failure
is($target_fail{winosname}, $expected_caption,
	"partial fail: WMI field winosname still populated");
is($target_fail{winsysname}, $expected_csname,
	"partial fail: WMI field winsysname still populated");

# SNMP fields should be missing or undefined
ok(!defined($target_fail{sysDescr}) || $target_fail{sysDescr} eq '',
	"partial fail: SNMP field sysDescr absent (SNMP errored)");

# Clear the forced error and confirm SNMP recovers on a subsequent call
$S_fail->{snmp}->force_error(undef);
my %target_recover;
$S_fail->loadInfo(class => 'system', target => \%target_recover, inventory => $dual_catchall);
is($target_recover{sysDescr}, $snmp_walk{'1.3.6.1.2.1.1.1.0'},
	"partial fail: SNMP recovers when forced error cleared");

# ============================================================
# Test E: disable_source on dual-protocol Sys
# ============================================================
# Starting from a fresh Sys with BOTH engines, disable one; verify the other
# is unaffected (engine list, session, is_active).
diag("=== Test E: disable_source operates on one engine only ===");

my $S_ds = make_dual_sys(open => 1);
my $snmp_mock_ds = $S_ds->{snmp};    # hold a ref so we can inspect after disable
my $wmi_mock_ds  = $S_ds->{wmi};

is(scalar(@{$S_ds->engines}), 2, "before disable: two engines");
ok($snmp_mock_ds->isopen, "before disable: SNMP mock session open");
is($S_ds->status->{snmp_enabled}, 1, "before disable: snmp_enabled=1");
is($S_ds->status->{wmi_enabled},  1, "before disable: wmi_enabled=1");

# Disable SNMP only
$S_ds->disable_source("snmp");

is($S_ds->status->{snmp_enabled}, 0, "after disable(snmp): snmp_enabled=0");
is($S_ds->status->{wmi_enabled},  1, "after disable(snmp): wmi_enabled still 1");
ok(!defined($S_ds->snmp), "after disable(snmp): Sys->snmp accessor returns undef");
ok( defined($S_ds->wmi),  "after disable(snmp): Sys->wmi accessor unchanged");
ok(!defined($S_ds->engine("snmp")), "after disable(snmp): engine('snmp') returns undef");
ok( defined($S_ds->engine("wmi")),  "after disable(snmp): engine('wmi') still returns an engine");
is(scalar(@{$S_ds->engines}), 1, "after disable(snmp): only one engine remains");
ok(!$snmp_mock_ds->isopen, "after disable(snmp): close_session was called on SNMP mock");

# WMI engine must still be is_active and callable
my $wmi_eng_remaining = $S_ds->engine("wmi");
is($wmi_eng_remaining->is_active, 1, "after disable(snmp): WMI engine is_active");

# loadInfo with only WMI should still populate WMI fields (SNMP items just skipped)
my %target_wmi_only;
$S_ds->loadInfo(class => 'system', target => \%target_wmi_only, inventory => $dual_catchall);
is($target_wmi_only{winosname}, $expected_caption,
	"after disable(snmp): WMI loadInfo still works on same Sys");
ok(!defined($target_wmi_only{sysDescr}) || $target_wmi_only{sysDescr} eq '',
	"after disable(snmp): SNMP fields no longer populated");

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
$S->close()     if $S;
$S_fail->close() if $S_fail;
$S_ds->close()  if $S_ds;
cleanup();
ok(1, "Cleanup complete");

done_testing();
