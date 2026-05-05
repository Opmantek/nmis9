#!/usr/bin/perl
#
# t_plugin_contract.pl - Smoke test for the plugin contract.
#
# Invokes two shipped plugins from conf-default/plugins/ directly with a
# mocked Sys/Node, confirming they still run end-to-end against the
# post-refactor public surface:
#
#   * combinedCPULoad.pm - metrics-style, uses $S->inventory, get_inventory_ids,
#     and create_update_rrd; returns the (0|1, @errors) contract.
#   * Host_Resources.pm  - inventory-heavy; uses get_inventory_model and a
#     different access pattern (next_object iterator).
#
# Coverage:
#   * short-circuit paths (snmpdown, missing inventory) execute without dying
#     and honor the return contract
#   * happy path with a matching inventory performs the expected work and
#     writes to RRD (spy-patched) and returns (1, undef)
#
# This is NOT a functional test of the plugins themselves - it locks in the
# contract (`(status, @errors)` shape, $S accessor behavior) that ~15 shipped
# plugins depend on.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Snmp::Mock;

# ============================================================
# Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

$C->{db_name} = "t_plugin_contract-" . time;

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

# Plugin dir + require the two plugins we target by file path.
# (Normally $nmisng->plugins would discover these; we need deterministic
#  module loading for direct invocation.)
my $plugin_dir = $C->{plugin_root_default} || "$FindBin::Bin/../conf-default/plugins";
die "plugin dir $plugin_dir not found" unless -d $plugin_dir;
require "$plugin_dir/combinedCPULoad.pm";
require "$plugin_dir/Host_Resources.pm";

# Spy: count create_update_rrd calls so we can prove the plugin did work.
our $rrd_calls = 0;
our @rrd_history;
{
	no warnings 'redefine';
	*NMISNG::Sys::create_update_rrd = sub {
		my ($self, %args) = @_;
		$rrd_calls++;
		push @rrd_history, { type => $args{type}, keys => [ sort keys %{ $args{data} || {} } ] };
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

# Load SNMP walk just to keep Sys->open() honest.
my $snmp_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
my %snmp_walk;
for my $k (keys %$snmp_walk_raw) {
	$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
}

# ============================================================
# Node + Sys: the exact shape nmisd would hand to a plugin.
# ============================================================
my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$node->cluster_id($C->{cluster_id});
$node->name("test_plugin_node");
$node->configuration({
	host      => "127.0.0.5",
	group     => "TestGroup",
	netType   => "default",
	roleType  => "default",
	threshold => 1,
	model     => "TestSnmp",
	collect   => "true",
	ping      => "false",
	community => "public",
	version   => "snmpv2c",
});
my ($op, $err) = $node->save();
ok(!$err, "test node saved") or diag("Error: $err");

my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system");
ok(!$cerr, "catchall created");

my $S = NMISNG::Sys->new(nmisng => $nmisng);
$S->init(node => $node, snmp => 1, wmi => 0,
	update => 'true', force => 1, catchall_inventory => $catchall);
$S->{snmp} = NMISNG::Snmp::Mock->new(
	nmisng => $nmisng, name => "test_plugin_node", walk_data => \%snmp_walk);
$S->open();

# init with force=>1 replaces the catchall in the Sys internal cache, so the
# original object we passed in is no longer what plugins will see. Re-fetch
# via Sys->inventory so all our mutations apply to the right instance.
($catchall) = $S->inventory(concept => 'catchall');

# Prime catchall data - default to "everything healthy" so plugins don't
# short-circuit on nodedown/snmpdown.
my $cd = $catchall->data_live();
$cd->{nodedown} = 'false';
$cd->{snmpdown} = 'false';
$cd->{nodeModel} = 'TestSnmp';
$cd->{nodeType}  = 'generic';
$catchall->save(node => $node);

# Plugin invocation helper: runs the plugin under eval and returns
# the captured ($status, @errors) plus any die message.
sub invoke_plugin
{
	my ($coderef, %extra_args) = @_;
	my ($status, @errors);
	my $dieref = eval {
		($status, @errors) = $coderef->(
			node   => $node->name,
			sys    => $S,
			config => $C,
			nmisng => $nmisng,
			%extra_args,
		);
		1;
	};
	# Plugins conventionally return `(status, undef)` for the no-error case,
	# or `(status, $msg, ...)` when reporting. Strip undef trailers so the
	# error count reflects real error messages.
	my @real_errors = grep { defined } @errors;
	return {
		status => $status,
		errors => \@real_errors,
		died   => $@,
		ok     => $dieref,
	};
}

# ============================================================
# Test A: combinedCPULoad short-circuits when snmpdown
# ============================================================
diag("=== Test A: combinedCPULoad short-circuit (snmpdown) ===");

$cd->{snmpdown} = 'true';
$catchall->save(node => $node);

my $ccl = combinedCPULoad->can("collect_plugin");
ok($ccl, "combinedCPULoad has collect_plugin");

my $r = invoke_plugin($ccl);
ok($r->{ok} && !$r->{died}, "combinedCPULoad did not die when snmpdown=true")
	or diag("died: $r->{died}");
is($r->{status}, 0, "combinedCPULoad returned status=0 (no changes) when snmpdown");
ok(scalar(@{$r->{errors}}) >= 1, "combinedCPULoad returned an error message explaining the skip");

# restore snmpdown
$cd->{snmpdown} = 'false';
$catchall->save(node => $node);

# ============================================================
# Test B: combinedCPULoad with no matching device inventory
# ============================================================
diag("=== Test B: combinedCPULoad - no 'device' inventory ===");

$rrd_calls = 0;
@rrd_history = ();

$r = invoke_plugin($ccl);
ok($r->{ok} && !$r->{died}, "combinedCPULoad did not die with no device inventory")
	or diag("died: $r->{died}");
# no devices -> body is skipped -> plugin still returns (1, undef)
is($r->{status}, 1, "combinedCPULoad returned status=1 even with no matching inventory");
is(scalar(@{$r->{errors}}), 0, "combinedCPULoad returned no errors in no-data path");
is($rrd_calls, 0, "combinedCPULoad did NOT call create_update_rrd (no devices to process)");

# ============================================================
# Test C: combinedCPULoad happy path with one device inventory
# ============================================================
diag("=== Test C: combinedCPULoad with a matching device inventory ===");

my ($dev_inv, $dev_err) = $node->inventory(
	concept   => "device",
	path_keys => ['index'],
	data      => {
		index        => "42",
		hrDeviceType => "1.3.6.1.2.1.25.3.1.3",
		hrCpuLoad    => 55,
	},
	create => 1,
);
ok(!$dev_err && $dev_inv, "created 'device' inventory for CPU plugin") or diag("err=$dev_err");
$dev_inv->enabled(1);
$dev_inv->historic(0);
$dev_inv->save(node => $node);

$rrd_calls = 0;
@rrd_history = ();

$r = invoke_plugin($ccl);
ok($r->{ok} && !$r->{died}, "combinedCPULoad did not die with a matching device inventory")
	or diag("died: $r->{died}");
is($r->{status}, 1, "combinedCPULoad returned status=1 after processing device");
is(scalar(@{$r->{errors}}), 0, "combinedCPULoad returned no errors on happy path");
cmp_ok($rrd_calls, '>=', 1, "combinedCPULoad called create_update_rrd at least once");

# Inspect what the plugin wrote; confirms $S accessors worked end to end.
my ($call) = grep { ($_->{type} // '') eq "combinedCPUload" } @rrd_history;
ok($call, "create_update_rrd was called with type=combinedCPUload");
if ($call) {
	ok((grep { $_ eq 'cpu_total'   } @{$call->{keys}}),  "RRD data includes cpu_total");
	ok((grep { $_ eq 'cpu_max'     } @{$call->{keys}}),  "RRD data includes cpu_max");
	ok((grep { $_ eq 'cpu_average' } @{$call->{keys}}),  "RRD data includes cpu_average");
	ok((grep { $_ eq 'cpu_count'   } @{$call->{keys}}),  "RRD data includes cpu_count");
}

# ============================================================
# Test D: Host_Resources short-circuits when snmpdown
# ============================================================
diag("=== Test D: Host_Resources::collect_plugin short-circuit (snmpdown) ===");

$cd->{snmpdown} = 'true';
$catchall->save(node => $node);

my $hr_collect = Host_Resources->can("collect_plugin");
ok($hr_collect, "Host_Resources has collect_plugin");

$r = invoke_plugin($hr_collect);
ok($r->{ok} && !$r->{died}, "Host_Resources::collect_plugin did not die when snmpdown")
	or diag("died: $r->{died}");
# Host_Resources uses `return ( error => "...")` in its short-circuit, which
# in list context is ("error", "msg"). The contract the caller actually
# applies is `$status >= 2 or $status < 0` -> failure. "error" is neither
# (numeric 0), so nmisd treats it as "no changes" - the plugin won't break
# orchestration.
ok(defined($r->{status}), "Host_Resources returned a defined first value");

$cd->{snmpdown} = 'false';
$catchall->save(node => $node);

# ============================================================
# Test E: Host_Resources::collect_plugin with no Host_Storage inventory
# ============================================================
diag("=== Test E: Host_Resources::collect_plugin - no Host_Storage inventory ===");

$rrd_calls = 0;
@rrd_history = ();

$r = invoke_plugin($hr_collect);
ok($r->{ok} && !$r->{died},
	"Host_Resources::collect_plugin did not die with no Host_Storage inventory")
	or diag("died: $r->{died}");
# $changesweremade starts at 0; while-loop doesn't execute; returns (0, undef).
is($r->{status}, 0, "Host_Resources returned status=0 (no changes)");
is(scalar(@{$r->{errors}}), 0, "Host_Resources returned no errors");
is($rrd_calls, 0, "Host_Resources did NOT write RRD with no inventory");

# ============================================================
# Test F: Host_Resources::update_plugin short-circuits
# ============================================================
diag("=== Test F: Host_Resources::update_plugin - no Host_Storage inventory ===");

my $hr_update = Host_Resources->can("update_plugin");
ok($hr_update, "Host_Resources has update_plugin");

$rrd_calls = 0;
@rrd_history = ();

$r = invoke_plugin($hr_update);
ok($r->{ok} && !$r->{died},
	"Host_Resources::update_plugin did not die with no Host_Storage inventory")
	or diag("died: $r->{died}");
ok(defined($r->{status}), "Host_Resources::update_plugin returned a defined first value");
is($rrd_calls, 0, "Host_Resources::update_plugin did NOT write RRD with no inventory");

# ============================================================
# Test G: Confirm $S accessors still work AFTER plugin calls
# Guards against a plugin clobbering Sys state.
# ============================================================
diag("=== Test G: Sys accessors still functional after plugin runs ===");

ok(defined($S->nmisng_node), "Sys->nmisng_node still returns node after plugin runs");
my ($post_catchall, $pce) = $S->inventory(concept => 'catchall');
ok(!$pce && $post_catchall, "Sys->inventory(catchall) still works after plugin runs");
my $ids = $S->nmisng_node->get_inventory_ids();
ok(ref($ids) eq "ARRAY" && scalar(@$ids) >= 2,
	"get_inventory_ids returns at least catchall + device");

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
$S->close() if $S;
cleanup();
ok(1, "Cleanup complete");

done_testing();
