#!/usr/bin/perl
#
# t_compat_nmis.pl - Smoke test for the Compat::NMIS + Sys init chain
# used by cgi-bin scripts (e.g. node.pl, snmp.pl) and bin/nmis-cli.
#
# This is NOT an exhaustive functional test; t_sys.pl already covers the
# loadInfo/getData machinery in depth. The purpose here is to lock in the
# public surface that ~50 external callers depend on:
#
#   * Compat::NMIS::new_nmisng(config => $C) returns a cached NMISNG
#   * NMISNG::Sys->new(nmisng => $nmisng) -> ->init(node=>..., snmp=>1, wmi=>0)
#   * Sys->mdl / ->nmisng_node / ->snmp / ->status accessors
#   * $S->nmisng_node->{configuration,inventory,get_inventory_ids}
#     (the three methods plugins and CGIs call most)
#   * loadInfo / getValues / getData all produce the expected shape
#
# If the refactor silently broke any of these, this test should fail.
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
use Compat::NMIS;

use NMISNG::Snmp::Mock;

# ============================================================
# Setup: bring NMISNG up via Compat::NMIS::new_nmisng (CGI pattern)
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

$C->{db_name} = "t_compat_nmis-" . time;

# Use nocache=>1 so a prior test's cached $_nmisng doesn't leak in with a
# different db_name. Also pass a pre-built logger to avoid the logfile
# permission-warning path inside new_nmisng (which fires when running as
# non-root on a shared /var/log).
my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = Compat::NMIS::new_nmisng(config => $C, log => $logger, nocache => 1);
ok(ref($nmisng) eq "NMISNG", "Compat::NMIS::new_nmisng returned NMISNG object");

sub cleanup { $nmisng->get_db()->drop(); }

# Calling new_nmisng twice without nocache returns the cached instance.
my $nmisng_again = Compat::NMIS::new_nmisng();
is(ref($nmisng_again), "NMISNG", "second new_nmisng call returned NMISNG object");
is($nmisng_again, $nmisng, "new_nmisng caches and returns same instance on re-call");

# ============================================================
# Load SNMP walk fixture and create a test node
# ============================================================
my $snmp_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
my %snmp_walk;
for my $k (keys %$snmp_walk_raw) {
	$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
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

my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$node->cluster_id($C->{cluster_id});
$node->name("test_compat_node");
$node->configuration({
	host      => "127.0.0.4",
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
ok(!$cerr, "catchall inventory created");

# ============================================================
# Test 1: Sys init chain (matches cgi-bin/node.pl, bin/nmis-cli pattern)
# ============================================================
diag("=== Test 1: Sys init chain ===");

my $S = NMISNG::Sys->new(nmisng => $nmisng);
ok($S, "NMISNG::Sys->new returned object");
isa_ok($S, 'NMISNG::Sys');

my $init_ok = $S->init(
	node => $node, snmp => 1, wmi => 0,
	update => 'true', force => 1,
	catchall_inventory => $catchall,
);
ok($init_ok, "Sys->init(node, snmp=>1, wmi=>0) succeeded");

# Install SNMP mock (real callers would have a live NMISNG::Snmp here)
$S->{snmp} = NMISNG::Snmp::Mock->new(
	nmisng => $nmisng, name => "test_compat_node", walk_data => \%snmp_walk,
);
ok($S->open(), "Sys->open() on mock succeeded");

# ============================================================
# Test 2: Sys public accessors used throughout Compat::NMIS callers
# ============================================================
diag("=== Test 2: Sys public accessors ===");

ok(ref($S->mdl) eq "HASH", "Sys->mdl returns model hashref");
is($S->mdl->{system}{nodeModel}, "TestSnmp", "Sys->mdl contains expected nodeModel");

is($S->nmisng_node, $node, "Sys->nmisng_node returns the node object passed to init");
ok(defined($S->snmp), "Sys->snmp accessor returns the SNMP transport");
is(ref($S->snmp), "NMISNG::Snmp::Mock", "Sys->snmp is the installed mock");
ok(!defined($S->wmi), "Sys->wmi accessor returns undef when wmi=>0");

my $status = $S->status;
ok(ref($status) eq "HASH", "Sys->status returns hashref");
is($status->{snmp_enabled}, 1, "status->snmp_enabled=1");
is($status->{wmi_enabled},  0, "status->wmi_enabled=0");

# enabled_sources reflects the one active engine.
is_deeply($S->enabled_sources, ["snmp"], "enabled_sources = ['snmp'] (SNMP-only init)");

# ============================================================
# Test 3: nmisng_node methods used by plugins and CGIs
# ============================================================
diag("=== Test 3: nmisng_node accessor contract ===");

my $cfg = $S->nmisng_node->configuration;
ok(ref($cfg) eq "HASH", "nmisng_node->configuration returns hashref");
is($cfg->{group}, "TestGroup",
	"nmisng_node->configuration->{group} (pattern used by cgi-bin/node.pl line 641)");
is($cfg->{host}, "127.0.0.4", "nmisng_node->configuration->{host} intact");
is($cfg->{model}, "TestSnmp", "nmisng_node->configuration->{model} intact");

# inventory() lookup by concept is the canonical plugin access pattern
my ($cat_inv, $ce) = $S->nmisng_node->inventory(concept => "catchall");
ok(!$ce, "nmisng_node->inventory(concept=>catchall) did not error");
ok(defined($cat_inv), "nmisng_node->inventory returned an inventory object");
isa_ok($cat_inv, 'NMISNG::Inventory');

# get_inventory_ids — used by inventory-heavy plugins after collect
my $ids = $S->nmisng_node->get_inventory_ids();
ok(ref($ids) eq "ARRAY", "nmisng_node->get_inventory_ids returned arrayref");
cmp_ok(scalar(@$ids), '>=', 1,
	"get_inventory_ids has at least one entry (catchall)");

# ============================================================
# Test 4: loadInfo returns expected sys fields (legacy CGI shape)
# ============================================================
diag("=== Test 4: loadInfo ===");

my %info;
my $li_rc = $S->loadInfo(class => 'system', target => \%info, inventory => $catchall);
ok($li_rc, "loadInfo returned truthy");
is($info{sysDescr},    $snmp_walk{'1.3.6.1.2.1.1.1.0'}, "loadInfo: sysDescr matches walk data");
is($info{sysName},     $snmp_walk{'1.3.6.1.2.1.1.5.0'}, "loadInfo: sysName matches walk data");
is($info{sysObjectID}, $snmp_walk{'1.3.6.1.2.1.1.2.0'}, "loadInfo: sysObjectID matches walk data");

# ============================================================
# Test 5: getValues direct call (the legacy entry Compat callers used pre-loadInfo)
# ============================================================
# getValues receives the section-dict (not the class name). This mirrors how
# loadInfo calls it internally and how some older Compat callers invoke it.
diag("=== Test 5: getValues direct call ===");

my ($gv_data, $gv_status) = $S->getValues(
	class   => $S->mdl->{system}{sys},    # section-dict of the 'system' class
	inventory => $catchall,
);
ok(ref($gv_data) eq "HASH", "getValues returned data hashref");
ok(ref($gv_status) eq "HASH", "getValues returned status hashref");
ok(exists $gv_data->{standard}, "getValues: 'standard' section present in result");
is($gv_data->{standard}{sysDescr}{value}, $snmp_walk{'1.3.6.1.2.1.1.1.0'},
	"getValues: standard.sysDescr matches walk data");
is($gv_data->{standard}{sysName}{value}, $snmp_walk{'1.3.6.1.2.1.1.5.0'},
	"getValues: standard.sysName matches walk data");
ok(!$gv_status->{error}, "getValues: no error in status");
ok(!$gv_status->{snmp_error}, "getValues: no snmp_error in status");

# ============================================================
# Test 6: getData returns rrd sections (legacy CGI shape)
# ============================================================
diag("=== Test 6: getData ===");

my $rrd = $S->getData(class => 'system', inventory => $catchall);
ok(ref($rrd) eq "HASH", "getData returned hashref");
ok(exists $rrd->{mib2ip}, "getData: mib2ip section present");
is($rrd->{mib2ip}{ipInReceives}{value}, $snmp_walk{'1.3.6.1.2.1.4.3.0'},
	"getData: mib2ip.ipInReceives matches walk data");

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
$S->close();
cleanup();
ok(1, "Cleanup complete");

done_testing();
