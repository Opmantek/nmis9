#!/usr/bin/perl
#
# t_threshold_traceability.pl - Tests for OMK-12375:
#   Section A: Status.pm known_attrs for new fields (no MongoDB)
#   Section B: loadModel() inline alert _source_file tagging (no MongoDB)
#   Section C: getValues() pushes _source_file + process_alerts() Status fields (MongoDB)
#   Section D: applyThresholdToInventory threshold_metric model fallback (MongoDB)
#   Section E: Common override _source_file tagging (no MongoDB)
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Clone;
use JSON::XS;
use File::Slurp qw(read_file);

use NMISNG::Status;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
# =============================================================================
# Fake NMISNG (Sections A and B — no MongoDB required)
# =============================================================================
{
	package T::FakeNmisng;
	sub new { my ($c, %a) = @_; bless { %a }, $c; }
	sub log    { $_[0]->{log} }
	sub config { $_[0]->{config} }
}

# =============================================================================
# Temp dir + config setup (Section B)
# =============================================================================
my $tmpbase      = tempdir("nmis-tr-test-XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $defaults_dir = "$tmpbase/models-default";
my $custom_dir   = "$tmpbase/models-custom";
my $var_dir      = "$tmpbase/var";
my $conf_dir     = "$tmpbase/conf";
make_path($defaults_dir, $custom_dir, $var_dir, $conf_dir,
		  "$var_dir/nmis_system/model_cache");

my $real_C = NMISNG::Util::loadConfTable();
die "cannot load real config\n" if (!$real_C || ref($real_C) ne "HASH");

my $C = Clone::clone($real_C);
$C->{'<nmis_default_models>'} = $defaults_dir;
$C->{'<nmis_models>'}         = $custom_dir;
$C->{'<nmis_var>'}            = $var_dir;
$C->{'<nmis_conf>'}           = $conf_dir;
$C->{'<nmis_conf_default>'}   = $conf_dir;
delete $C->{global_model_overrides};
$C->{use_json}        = 'false';
$C->{use_json_pretty} = 'false';

my $logger      = NMISNG::Log->new(level => 'fatal');
my $fake_nmisng = T::FakeNmisng->new(config => $C, log => $logger);

sub write_nmis_file {
	my ($path, $data) = @_;
	if (my $err = NMISNG::Util::writeHashtoFile(file => $path, data => $data,
												 json => 0, conf => $C)) {
		die "failed to write $path: $err";
	}
	my $now = time();
	utime($now, $now, $path);
	return $path;
}

sub clear_cache {
	my $cache_dir = "$var_dir/nmis_system/model_cache";
	opendir(my $dh, $cache_dir) or return;
	while (my $f = readdir($dh)) {
		next if $f =~ /^\.\.?$/;
		unlink "$cache_dir/$f";
	}
	closedir($dh);
}

# Creates a Sys pointing at the temp dirs; optionally override global_model_overrides.
sub make_sys {
	my (%args) = @_;
	my $sys = NMISNG::Sys->new();
	$sys->{config}       = $C;
	$sys->{_nmisng}      = $fake_nmisng;
	$sys->{cache_models} = 1;
	if (exists $args{global_overrides}) {
		$sys->{config} = Clone::clone($C);
		$sys->{config}{global_model_overrides} = $args{global_overrides};
	}
	return $sys;
}

# Returns a minimal model hash with one inline alert at
# $root_sect.rrd.testSection.snmp.$ds
sub inline_alert_model {
	my ($root_sect, $ds, $event) = @_;
	return {
		$root_sect => {
			rrd => {
				testSection => {
					snmp => {
						$ds => {
							oid    => $ds,
							option => 'gauge,0:U',
							alert  => {
								test  => '$r > 100',
								event => $event,
								level => 'Warning',
							},
						},
					},
				},
			},
		},
	};
}

# =============================================================================
# SECTION A: Status.pm known_attrs
# =============================================================================
diag("=== Section A: Status known_attrs ===");

for my $field (qw(threshold_source threshold_metric threshold_key threshold_unit model_subconcept threshold_select)) {
	ok(NMISNG::Status->can($field), "A: Status has getter/setter for $field");
}

# =============================================================================
# SECTION B: loadModel() inline alert _source_file tagging
# =============================================================================
diag("=== Section B: loadModel inline alert tagging ===");

# B1: Primary model inline alert tagged with model filename
{
	clear_cache();
	my $name = "TrB1";
	write_nmis_file("$defaults_dir/Model-$name.nmis",
		inline_alert_model("mySection", "myDs", "B1 Alert"));

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "B1: loadModel succeeded");
	is($sys->{mdl}{mySection}{rrd}{testSection}{snmp}{myDs}{alert}{_source_file},
	   "Model-$name",
	   "B1: primary model inline alert tagged with model filename");
}

# B2: Common model inline alert tagged with Common filename, primary retains its own
{
	clear_cache();
	my ($name, $feat) = ("TrB2", "TrB2Feature");
	write_nmis_file("$defaults_dir/Model-$name.nmis", {
		'-common-' => { class => { f => { 'common-model' => $feat } } },
		primarySection => {
			rrd => {
				testSection => {
					snmp => {
						primaryDs => {
							oid    => 'primaryDs',
							option => 'gauge,0:U',
							alert  => { test => '$r > 1', event => 'Primary Alert', level => 'Warning' },
						},
					},
				},
			},
		},
	});
	write_nmis_file("$defaults_dir/Common-$feat.nmis",
		inline_alert_model("commonSection", "commonDs", "B2 Common Alert"));

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "B2: loadModel succeeded");
	is($sys->{mdl}{commonSection}{rrd}{testSection}{snmp}{commonDs}{alert}{_source_file},
	   "Common-$feat",
	   "B2: Common model inline alert tagged with Common filename");
	is($sys->{mdl}{primarySection}{rrd}{testSection}{snmp}{primaryDs}{alert}{_source_file},
	   "Model-$name",
	   "B2: primary model inline alert retains its own filename");
}

# B3: Global override inline alert tagged with override filename
{
	clear_cache();
	my ($name, $override) = ("TrB3", "TrB3Ov");
	write_nmis_file("$defaults_dir/Model-$name.nmis",
		inline_alert_model("primarySection", "primaryDs", "B3 Primary"));
	write_nmis_file("$custom_dir/Override-$override.nmis",
		inline_alert_model("overrideSection", "overrideDs", "B3 Override"));

	my $sys = make_sys(global_overrides => [$override]);
	ok($sys->loadModel(model => "Model-$name"), "B3: loadModel succeeded");
	is($sys->{mdl}{overrideSection}{rrd}{testSection}{snmp}{overrideDs}{alert}{_source_file},
	   "Override-$override",
	   "B3: global override inline alert tagged with override filename");
	is($sys->{mdl}{primarySection}{rrd}{testSection}{snmp}{primaryDs}{alert}{_source_file},
	   "Model-$name",
	   "B3: primary model inline alert unchanged by global override");
}

# B4: Scoped Model override (PR #170) inline alert tagged with scoped override filename
{
	clear_cache();
	my $name = "TrB4";
	write_nmis_file("$defaults_dir/Model-$name.nmis",
		inline_alert_model("primarySection", "primaryDs", "B4 Primary"));
	write_nmis_file("$custom_dir/Override-Model-$name.nmis",
		inline_alert_model("scopedSection", "scopedDs", "B4 Scoped"));

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "B4: loadModel succeeded");
	is($sys->{mdl}{scopedSection}{rrd}{testSection}{snmp}{scopedDs}{alert}{_source_file},
	   "Override-Model-$name",
	   "B4: scoped Model override inline alert tagged with scoped override filename");
	is($sys->{mdl}{primarySection}{rrd}{testSection}{snmp}{primaryDs}{alert}{_source_file},
	   "Model-$name",
	   "B4: primary model inline alert unaffected by scoped Model override");
}

# B5: Scoped Common override inline alert tagged with scoped Common override filename
{
	clear_cache();
	my ($name, $feat) = ("TrB5", "TrB5Feature");
	write_nmis_file("$defaults_dir/Model-$name.nmis", {
		'-common-' => { class => { f => { 'common-model' => $feat } } },
	});
	write_nmis_file("$defaults_dir/Common-$feat.nmis",
		inline_alert_model("commonSection", "commonDs", "B5 Common"));
	write_nmis_file("$custom_dir/Override-Common-$feat.nmis",
		inline_alert_model("scopedCommonSection", "scopedCommonDs", "B5 Scoped Common"));

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "B5: loadModel succeeded");
	is($sys->{mdl}{scopedCommonSection}{rrd}{testSection}{snmp}{scopedCommonDs}{alert}{_source_file},
	   "Override-Common-$feat",
	   "B5: scoped Common override inline alert tagged with scoped Common override filename");
	is($sys->{mdl}{commonSection}{rrd}{testSection}{snmp}{commonDs}{alert}{_source_file},
	   "Common-$feat",
	   "B5: base Common inline alert not clobbered by scoped Common override");
}

# B6: Top-level sections (alerts, threshold) still tagged by existing loops;
#     _tag_inline_alert_sections skips them (no double-tagging or corruption)
{
	clear_cache();
	my $name = "TrB6";
	write_nmis_file("$defaults_dir/Model-$name.nmis", {
		alerts => {
			myAlertSect => {
				myAlert => { type => 'test', test => '$r > 1', event => 'Test Alert', level => 'Warning' },
			},
		},
		threshold => {
			name => {
				myThr => { item => 'myThr', event => 'Thr Event' },
			},
		},
		mySection => {
			rrd => {
				testSection => {
					snmp => {
						myDs => {
							oid    => 'myDs',
							option => 'gauge,0:U',
							alert  => { test => '$r > 1', event => 'Inline Alert', level => 'Warning' },
						},
					},
				},
			},
		},
	});

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "B6: loadModel succeeded");

	is($sys->{mdl}{mySection}{rrd}{testSection}{snmp}{myDs}{alert}{_source_file},
	   "Model-$name",
	   "B6: regular section inline alert tagged by _tag_inline_alert_sections");
	is($sys->{mdl}{alerts}{myAlertSect}{myAlert}{_source_file},
	   "Model-$name",
	   "B6: top-level alerts entry tagged by the existing alerts tagging loop");
	is($sys->{mdl}{threshold}{name}{myThr}{_source_file},
	   "Model-$name",
	   "B6: threshold entry tagged by the existing threshold tagging loop");
}

# B7: Shared cache not mutated — second load still produces correct tagging
{
	clear_cache();
	my ($name, $feat) = ("TrB7", "TrB7Feature");
	write_nmis_file("$defaults_dir/Model-$name.nmis", {
		'-common-' => { class => { f => { 'common-model' => $feat } } },
	});
	write_nmis_file("$defaults_dir/Common-$feat.nmis",
		inline_alert_model("commonSection", "commonDs", "B7 Common Alert"));

	for my $pass (1, 2) {
		clear_cache();
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "B7 pass $pass: loadModel succeeded");
		is($sys->{mdl}{commonSection}{rrd}{testSection}{snmp}{commonDs}{alert}{_source_file},
		   "Common-$feat",
		   "B7 pass $pass: inline alert tagged correctly (shared cache not mutated)");
	}
}


# =============================================================================
# SECTION C: Runtime integration — getValues + process_alerts (requires MongoDB)
# =============================================================================
diag("=== Section C: Runtime integration ===");

my $can_mongo = eval {
	require NMISNG;
	require NMISNG::Node;
	my $probe_C = NMISNG::Util::loadConfTable();
	my $n = NMISNG->new(
		config => { %$probe_C, db_name => "__probe__" . time },
		log    => NMISNG::Log->new(level => 'fatal'));
	$n->get_db();
	$n->get_db()->drop();
	1;
};

SKIP: {
	skip "MongoDB not available: $@", 18 unless $can_mongo;

	require NMISNG;
	require NMISNG::Node;
	require NMISNG::Snmp::Mock;
	NMISNG::Snmp::Mock->import();

	my $int_C = NMISNG::Util::loadConfTable();
	$int_C->{db_name} = "t_threshold-" . time;
	my $int_log = NMISNG::Log->new(level => 'info');
	my $nmisng  = NMISNG->new(config => $int_C, log => $int_log);

	# Monkey-patch RRD to skip actual I/O
	{
		no warnings 'redefine';
		*NMISNG::Sys::create_update_rrd = sub {
			my ($self, %args) = @_;
			if (ref($args{inventory})) {
				$args{inventory}->set_subconcept_type_storage(
					subconcept => ($args{type} || 'unknown'), type => 'rrd',
					data       => "/nodes/$self->{name}/mock.rrd");
			}
			return 1;
		};
	}

	my $snmp_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
	my %snmp_walk;
	for my $k (keys %$snmp_walk_raw) {
		$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
	}

	# Create test node backed by Model-TestSnmp (which has inline alerts)
	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$node->cluster_id($int_C->{cluster_id});
	$node->name("t_tr_snmp");
	$node->configuration({
		host      => "127.0.0.1",
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
	my (undef, $save_err) = $node->save();
	ok(!$save_err, "C: test node saved") or diag($save_err);

	my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system");
	ok(!$cerr, "C: catchall inventory created");

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(node => $node, snmp => 1, wmi => 0, update => 'true', force => 1,
			 catchall_inventory => $catchall);
	$S->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => "t_tr_snmp",
										  walk_data => \%snmp_walk);
	$S->open();
	$node->update_node_info(sys => $S, catchall_inventory => $catchall);
	$node->collect_systemhealth_info(sys => $S, catchall_inventory => $catchall);
	$catchall->save(node => $node);

	# C1-C2: inline alert entries in $sys->{mdl} have _source_file after loadModel
	ok(defined $S->mdl->{systemHealth}{rrd}{testSensor}{snmp}{testSensorValue}{alert}{_source_file},
	   "C1: testSensorValue inline alert _source_file defined after loadModel");
	is($S->mdl->{systemHealth}{rrd}{testSensor}{snmp}{testSensorValue}{alert}{_source_file},
	   'Model-TestSnmp',
	   "C2: testSensorValue inline alert _source_file = 'Model-TestSnmp'");

	# C3-C6: getValues forwards _source_file into $S->{alerts}
	$S->{alerts} = [];
	my $ts_all  = $node->get_inventory_model(concept => 'testSensor', filter => { historic => 0 });
	my %ts_by_index;
	for my $inv (@{$ts_all->objects->{objects} || []}) {
		$ts_by_index{$inv->data->{index}} = $inv;
	}
	$S->getData(class => 'systemHealth', section => 'testSensor',
				index => '1', inventory => $ts_by_index{1});
	$S->getData(class => 'systemHealth', section => 'testSensor',
				index => '2', inventory => $ts_by_index{2});

	my @sensor_alerts = grep { ($_->{event} // '') eq 'High Sensor Value' } @{$S->{alerts}};
	ok(scalar(@sensor_alerts) >= 1, "C3: getValues pushed inline alert records to \$S->{alerts}");

	my @with_source = grep { defined $_->{_source_file} } @sensor_alerts;
	is(scalar(@with_source), scalar(@sensor_alerts),
	   "C4: every inline alert record has _source_file set");
	is($sensor_alerts[0]{_source_file}, 'Model-TestSnmp',
	   "C5: _source_file forwarded correctly by getValues push");
	is($sensor_alerts[0]{ds},      'testSensorValue', "C6: alert ds = 'testSensorValue'");
	is($sensor_alerts[0]{section}, 'testSensor',      "C6b: alert section = 'testSensor'");

	# C7-C12: process_alerts saves new fields to the MongoDB status collection
	$node->process_alerts(sys => $S);

	require NMISNG::DB;
	my $status_cursor = NMISNG::DB::find(
		collection => $nmisng->status_collection(),
		query      => { event => 'High Sensor Value', node_uuid => $node->uuid },
	);
	my @status_docs = $status_cursor ? $status_cursor->all() : ();
	ok(scalar(@status_docs) >= 1,
	   "C7: status documents saved to MongoDB for inline sensor alert");

  SKIP: {
		skip "no status docs in MongoDB", 6 unless @status_docs;
		my $doc = $status_docs[0];
		is($doc->{threshold_source},  'Model-TestSnmp',  "C8:  threshold_source persisted to status collection");
		is($doc->{threshold_metric},  'testSensorValue', "C9:  threshold_metric persisted to status collection");
		is($doc->{model_subconcept},  'testSensor',      "C10: model_subconcept persisted to status collection");
		is($doc->{threshold_key},     'testSensorValue', "C11: threshold_key persisted to status collection");
		ok(!exists $doc->{threshold_source_file},        "C12: obsolete threshold_source_file not in status collection");
		ok(!defined $doc->{threshold_unit} || $doc->{threshold_unit} eq '',
		   "C13: threshold_unit absent/empty for inline alert (no unit field in inline alert model)");
	}

	$nmisng->get_db()->drop();
	ok(1, "C: cleanup complete");
}

# =============================================================================
# SECTION D: applyThresholdToInventory threshold_metric fallback (MongoDB)
#
# Verifies when compute_thresholds calls applyThresholdToInventory
# without an item= arg ($item is undef), threshold_metric in the saved status doc
# is populated from the threshold definition's own item field in the model.
#
# Uses a pre-populated stats table so no RRD I/O is required.
# =============================================================================
diag("=== Section D: threshold_metric model fallback (MongoDB) ===");

SKIP: {
	skip "MongoDB not available: $@", 9 unless $can_mongo;

	require NMISNG;
	require NMISNG::Node;
	require NMISNG::Snmp::Mock;
	NMISNG::Snmp::Mock->import();

	my $d_C = NMISNG::Util::loadConfTable();
	$d_C->{db_name} = "t_threshold-d-" . time;
	my $d_log    = NMISNG::Log->new(level => 'info');
	my $d_nmisng = NMISNG->new(config => $d_C, log => $d_log);

	{
		no warnings 'redefine';
		*NMISNG::Sys::create_update_rrd = sub {
			my ($self, %args) = @_;
			if (ref($args{inventory})) {
				$args{inventory}->set_subconcept_type_storage(
					subconcept => ($args{type} || 'unknown'), type => 'rrd',
					data       => "/nodes/$self->{name}/mock.rrd");
			}
			return 1;
		};
	}

	my $d_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
	my %d_walk;
	for my $k (keys %$d_walk_raw) {
		$d_walk{$k} = $d_walk_raw->{$k} unless $k =~ /^_/;
	}

	my $d_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $d_nmisng);
	$d_node->cluster_id($d_C->{cluster_id});
	$d_node->name("t_tr_thr");
	$d_node->configuration({
		host      => "127.0.0.1",
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
	my (undef, $d_save_err) = $d_node->save();
	ok(!$d_save_err, "D1: test node saved") or diag($d_save_err);

	my ($d_catchall, $d_cerr) = $d_node->inventory(concept => "catchall", model_class => "system");
	ok(!$d_cerr, "D2: catchall inventory created");

	my $d_S = NMISNG::Sys->new(nmisng => $d_nmisng);
	$d_S->init(node => $d_node, snmp => 1, wmi => 0, update => 'true', force => 1,
			   catchall_inventory => $d_catchall);
	$d_S->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $d_nmisng, name => "t_tr_thr",
											walk_data => \%d_walk);
	$d_S->open();
	$d_node->update_node_info(sys => $d_S, catchall_inventory => $d_catchall);
	$d_node->collect_systemhealth_info(sys => $d_S, catchall_inventory => $d_catchall);
	$d_catchall->save(node => $d_node);

	my $d_ts_all  = $d_node->get_inventory_model(concept => 'testSensor', filter => { historic => 0 });
	my $d_ts_objs = $d_ts_all->objects;
	my $d_ts_inv  = ($d_ts_objs->{success} && @{$d_ts_objs->{objects}})
	                ? $d_ts_objs->{objects}[0] : undef;
	ok(defined($d_ts_inv), "D3: testSensor inventory instance found in MongoDB");

	SKIP: {
		skip "no testSensor inventory for D4-D8", 5 unless defined($d_ts_inv);

		my $d_index = $d_ts_inv->data->{index} // '';

		# Call without item= to trigger the $item // model-item fallback (commit bb1f7921).
		# Pre-populate the stats table (keyed by node name then subconcept) so the function
		# uses these values directly without needing RRD-derived data.
		# testSensorUtil=85 exceeds the Warning threshold of 80, so thresholdProcess fires.
		$d_nmisng->applyThresholdToInventory(
			sys       => $d_S,
			table     => { 't_tr_thr' => { testSensor => { testSensorUtil => 85 } } },
			type      => 'testSensor',
			thrname   => ['testSensorUtil'],
			index     => $d_index,
			inventory => $d_ts_inv,
		);

		my $d_cursor = NMISNG::DB::find(
			collection => $d_nmisng->status_collection(),
			query      => { event => 'Proactive Sensor Utilisation', node_uuid => $d_node->uuid },
		);
		my @d_docs = $d_cursor ? $d_cursor->all() : ();
		ok(scalar(@d_docs) >= 1, "D4: status doc saved for testSensorUtil threshold breach");

		SKIP: {
			skip "no status docs in MongoDB for D5-D8", 4 unless @d_docs;
			my $d = $d_docs[0];
			is($d->{threshold_metric}, 'testSensorUtil',
			   "D5: threshold_metric populated from model item= when item arg is absent");
			is($d->{threshold_key},    'testSensorUtil', "D6: threshold_key = thrname");
			is($d->{model_subconcept}, 'testSensor',     "D7: model_subconcept = type");
			is($d->{threshold_unit},   '%',              "D8: threshold_unit = '%' from threshold definition");
		}
	}

	$d_nmisng->get_db()->drop();
	ok(1, "D: cleanup complete");
}

# =============================================================================
# SECTION E: Common override _source_file tagging (no MongoDB)
#
# Uses three fixture models (in test/testdata/) to verify:
#   E1-E3: without override, fanValue alert comes from Common-CiscoStatus-test
#   E4-E6: with Override-Common-CiscoStatus-test in models-custom, the
#           overriding file owns _source_file and its fields win (level=Critical)
# =============================================================================
diag("=== Section E: Common override _source_file tagging ===");

my %ios_test_model = (
	'-common-' => {
		'class' => {
			'status' => { 'common-model' => 'CiscoStatus-test' },
		},
	},
	'system' => { 'nodeModel' => 'IOS-test', 'nodeType' => 'router' },
);

my %cisco_status_common = (
	'alerts' => {
		'fanStatus' => {
			'fanValue' => {
				'element' => 'index',
				'event'   => 'FAN Status',
				'level'   => 'Warning',
				'test'    => 'CVAR1=fanValue;$CVAR1 < 80',
				'type'    => 'test',
				'title'   => 'Fan Status',
				'unit'    => '',
				'value'   => 'CVAR1=fanValue;int($CVAR1)',
			},
		},
	},
	'systemHealth' => {
		'rrd' => {
			'fanStatus' => {
				'graphtype' => 'fan-status',
				'indexed'   => 'true',
				'snmp'      => {
					'fanValue' => {
						'oid'     => 'ciscoEnvMonFanState',
						'replace' => { '1'=>'100','2'=>'75','3'=>'0','4'=>'80','5'=>'90','6'=>'50' },
					},
				},
			},
		},
		'sys' => {
			'fanStatus' => {
				'indexed' => 'ciscoEnvMonFanStatusDescr',
				'headers' => 'FanStatusDescr',
				'snmp'    => {
					'FanStatusDescr' => { 'oid' => 'ciscoEnvMonFanStatusDescr', 'title' => 'Fan Status Descr' },
					'fanValue'       => {
						'oid'     => 'ciscoEnvMonFanState',
						'replace' => { '1'=>'100','2'=>'75','3'=>'0','4'=>'80','5'=>'90','6'=>'50' },
					},
				},
			},
		},
	},
);

my %cisco_status_override = (
	'alerts' => {
		'fanStatus' => {
			'fanValue' => {
				'element' => 'index',
				'event'   => 'FAN Status',
				'level'   => 'Critical',
				'test'    => 'CVAR1=fanValue;$CVAR1 < 50',
				'type'    => 'test',
				'title'   => 'Fan Status',
				'unit'    => '',
				'value'   => 'CVAR1=fanValue;int($CVAR1)',
			},
		},
	},
);

# E1-E3: base common model, no override
{
	clear_cache();
	write_nmis_file("$defaults_dir/Model-IOS-test.nmis",         \%ios_test_model);
	write_nmis_file("$defaults_dir/Common-CiscoStatus-test.nmis", \%cisco_status_common);

	my $sys = make_sys();
	ok($sys->loadModel(model => 'Model-IOS-test'), "E1: loadModel(Model-IOS-test) without override succeeded");
	is($sys->{mdl}{alerts}{fanStatus}{fanValue}{_source_file},
	   'Common-CiscoStatus-test',
	   "E2: fanValue _source_file = 'Common-CiscoStatus-test' (no override)");
	is($sys->{mdl}{alerts}{fanStatus}{fanValue}{level},
	   'Warning',
	   "E3: fanValue level = 'Warning' from base Common-CiscoStatus-test");
}

# E4-E6: Override-Common-CiscoStatus-test in models-custom wins
{
	clear_cache();
	write_nmis_file("$defaults_dir/Model-IOS-test.nmis",          \%ios_test_model);
	write_nmis_file("$defaults_dir/Common-CiscoStatus-test.nmis",  \%cisco_status_common);
	write_nmis_file("$custom_dir/Override-Common-CiscoStatus-test.nmis", \%cisco_status_override);

	my $sys = make_sys();
	ok($sys->loadModel(model => 'Model-IOS-test'), "E4: loadModel(Model-IOS-test) with override succeeded");
	is($sys->{mdl}{alerts}{fanStatus}{fanValue}{_source_file},
	   'Override-Common-CiscoStatus-test',
	   "E5: fanValue _source_file = 'Override-Common-CiscoStatus-test' after override");
	is($sys->{mdl}{alerts}{fanStatus}{fanValue}{level},
	   'Critical',
	   "E6: fanValue level = 'Critical' (override wins over Warning from base Common)");

	# Clean up the override so it doesn't bleed into later tests
	unlink "$custom_dir/Override-Common-CiscoStatus-test.nmis";
}

done_testing();
