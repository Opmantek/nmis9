#!/usr/bin/perl
#
# t_model_overrides.pl - tests the scoped + global model override system in
# NMISNG::Sys::loadModel().
#
# Runs against isolated temporary models-default / models-custom / var directories
# so a running NMIS install on the same host is not affected.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Clone;
use Data::Dumper;
use Time::HiRes qw(sleep);

use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;

use JSON::XS;
use File::Slurp qw(read_file write_file);

# -----------------------------------------------------------------------------
# Minimal nmisng-like object: loadModel only needs ->log
# -----------------------------------------------------------------------------
{
	package T::FakeNmisng;
	sub new { my ($c, %a) = @_; bless { %a }, $c; }
	sub log { $_[0]->{log} }
	sub config { $_[0]->{config} }
}

# -----------------------------------------------------------------------------
# Test harness
# -----------------------------------------------------------------------------

# Build a config rooted at temp dirs. Cloned from the real config so all the
# other expansions and defaults are present, then path keys are replaced.
my $tmpbase = tempdir("nmis-override-test-XXXXXX", TMPDIR => 1, CLEANUP => 1);
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

# Logger that drops everything quietly so the test output stays clean.
my $logger = NMISNG::Log->new(level => 'fatal');
my $fake_nmisng = T::FakeNmisng->new(config => $C, log => $logger);

# Helpers ---------------------------------------------------------------------

sub write_nmis_file {
	my ($path, $data) = @_;
	# writeHashtoFile returns undef on success, error string on failure
	if (my $err = NMISNG::Util::writeHashtoFile(file => $path, data => $data,
												json => 0, conf => $C))
	{
		die "failed to write $path: $err";
	}
	# bump mtime so successive writes within the same wallclock second
	# are still detectable as changed
	my $now = time();
	utime($now, $now, $path) or die "utime $path: $!";
	return $path;
}

sub bump_mtime {
	my ($path) = @_;
	my $now = time() + 2;
	utime($now, $now, $path) or die "utime $path: $!";
}

sub make_sys {
	my $sys = NMISNG::Sys->new();
	$sys->{config}      = $C;
	$sys->{_nmisng}     = $fake_nmisng;
	$sys->{cache_models} = 1;
	return $sys;
}

sub clear_model_cache {
	# wipe model cache between scenarios so we always start clean
	my $cache_dir = "$var_dir/nmis_system/model_cache";
	if (opendir(my $dh, $cache_dir)) {
		while (my $f = readdir($dh)) {
			next if $f =~ /^\.\.?$/;
			unlink "$cache_dir/$f";
		}
		closedir($dh);
	}
	# also clear loadTable's in-memory cache so stale data doesn't survive
	# between scenarios that recreate the same path with different content
	# (we work around per-test by using fresh paths per scenario)
}

# -----------------------------------------------------------------------------
# Build test models. Each scenario uses a uniquely-named model so loadTable's
# internal mtime cache cannot hand back stale data from a previous scenario.
# -----------------------------------------------------------------------------

# Base Model + Common written into the default dir, used for almost every scenario.
sub install_base_model {
	my ($name, $cpu_feature) = @_;
	$cpu_feature //= "${name}Cpu";

	write_nmis_file("$defaults_dir/Model-$name.nmis", {
		system => {
			nodeVendor => 'BaseVendor',
			nodeType   => 'router',
		},
		'-common-' => {
			class => {
				cpu => { 'common-model' => $cpu_feature },
			},
		},
	});
	write_nmis_file("$defaults_dir/Common-$cpu_feature.nmis", {
		systemHealth => {
			rrd => {
				cpu => {
					graphtype => 'cpu',
					indexed   => 'true',
					threshold => 'cpu_load_base',
				},
			},
		},
	});
	return ($name, $cpu_feature);
}

# -----------------------------------------------------------------------------
# Scenario 1: scoped Model override changes a top-level value
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S1Router");

	# add scoped Override-Model that changes nodeVendor
	write_nmis_file("$custom_dir/Override-Model-$name.nmis", {
		system => { nodeVendor => 'OverriddenVendor' },
	});

	my $sys = make_sys();
	my $ok = $sys->loadModel(model => "Model-$name");
	ok($ok, "S1: loadModel succeeded");
	is($sys->{mdl}->{system}->{nodeVendor}, 'OverriddenVendor',
	   "S1: scoped Model override replaced nodeVendor");
	is($sys->{mdl}->{system}->{nodeType}, 'router',
	   "S1: non-overridden Model values are preserved");
}

# -----------------------------------------------------------------------------
# Scenario 2: scoped Common override changes a value contributed by Common-X
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name, $feat) = install_base_model("S2Router");

	write_nmis_file("$custom_dir/Override-Common-$feat.nmis", {
		systemHealth => {
			rrd => {
				cpu => { threshold => 'cpu_load_overridden' },
			},
		},
	});

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S2: loadModel succeeded");
	is($sys->{mdl}->{systemHealth}->{rrd}->{cpu}->{threshold},
	   'cpu_load_overridden',
	   "S2: scoped Common override replaced threshold");
	is($sys->{mdl}->{systemHealth}->{rrd}->{cpu}->{graphtype}, 'cpu',
	   "S2: non-overridden Common values are preserved");
}

# -----------------------------------------------------------------------------
# Scenario 3: auto-discovery — no global_model_overrides key, override is
# picked up purely by file presence in models-custom.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S3Router");

	# explicit assertion: config doesn't list this override anywhere
	ok(!exists $C->{global_model_overrides}
	   || !@{$C->{global_model_overrides} // []},
	   "S3: global_model_overrides config is empty");

	write_nmis_file("$custom_dir/Override-Model-$name.nmis", {
		system => { nodeVendor => 'AutoDiscovered' },
	});

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S3: loadModel succeeded");
	is($sys->{mdl}->{system}->{nodeVendor}, 'AutoDiscovered',
	   "S3: override picked up purely from filesystem");
}

# -----------------------------------------------------------------------------
# Scenario 4: cache invalidation when a scoped override is ADDED
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S4Router");

	# first load — no overrides anywhere — populates cache
	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S4: initial load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'BaseVendor',
		   "S4: baseline value before override");
	}

	# wait so the override file's mtime is strictly newer than the cache file
	sleep(1.2);

	# now drop in an override
	write_nmis_file("$custom_dir/Override-Model-$name.nmis", {
		system => { nodeVendor => 'AddedAfterCache' },
	});

	# second load — should detect the new override and re-load from source
	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S4: second load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'AddedAfterCache',
		   "S4: cache invalidated, override applied");
	}
}

# -----------------------------------------------------------------------------
# Scenario 5: cache invalidation when a scoped override is DELETED
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S5Router");

	# install override, load (caches with override applied)
	my $override_path = "$custom_dir/Override-Model-$name.nmis";
	write_nmis_file($override_path, {
		system => { nodeVendor => 'WillBeDeleted' },
	});

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S5: load with override ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'WillBeDeleted',
		   "S5: override applied initially");
	}

	# delete the override
	unlink($override_path) or die "unlink $override_path: $!";

	# next load must re-build from source (override gone) and revert
	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S5: post-delete load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'BaseVendor',
		   "S5: cache invalidated on delete, value reverted");
	}
}

# -----------------------------------------------------------------------------
# Scenario 6: cache invalidation when a scoped override is EDITED
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S6Router");

	my $override_path = "$custom_dir/Override-Model-$name.nmis";
	write_nmis_file($override_path, {
		system => { nodeVendor => 'V1' },
	});

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S6: initial load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'V1', "S6: V1 applied first");
	}

	sleep(1.2);

	# rewrite the override with new content; mtime now > cache mtime
	write_nmis_file($override_path, {
		system => { nodeVendor => 'V2' },
	});

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S6: post-edit load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'V2',
		   "S6: cache invalidated on edit, V2 applied");
	}
}

# -----------------------------------------------------------------------------
# Helpers for sidecar inspection
# -----------------------------------------------------------------------------
sub model_cache_file {
	my ($model) = @_;
	return "$var_dir/nmis_system/model_cache/$model.json";
}
sub sidecar_file {
	my ($model) = @_;
	return model_cache_file($model) . ".meta.json";
}
sub read_sidecar {
	my ($model) = @_;
	my $path = sidecar_file($model);
	return undef if (!-f $path);
	my $raw = read_file($path);
	my $data = eval { decode_json($raw) };
	return $@ ? undef : $data;
}

# -----------------------------------------------------------------------------
# Scenario 7: global + scoped together. Globals merge LAST so they win on
# any keys both touch.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S7Router");

	write_nmis_file("$custom_dir/Override-Model-$name.nmis", {
		system => { nodeVendor => 'ScopedWins' },
	});
	# global override file (lookup uses Override-<entry>.nmis under either
	# models dir; we put it in models-custom)
	write_nmis_file("$custom_dir/Override-globaltest.nmis", {
		system => { nodeVendor => 'GlobalWins' },
	});

	local $C->{global_model_overrides} = ['globaltest'];

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S7: load ok");
	is($sys->{mdl}->{system}->{nodeVendor}, 'GlobalWins',
	   "S7: global override applied last, beats scoped");

	# scoped Model override is recorded in the sidecar (not in $sys->{mdl})
	ok(!exists $sys->{mdl}->{'-applied-overrides-'},
	   "S7: \$sys->{mdl} does NOT contain -applied-overrides- (metadata is in sidecar)");
	my $meta = read_sidecar("Model-$name");
	is(ref($meta), 'HASH', "S7: sidecar parses as hash");
	is(ref($meta->{applied_overrides}), 'ARRAY',
	   "S7: sidecar.applied_overrides is an arrayref");
	my @paths = map { $_->{path} } @{$meta->{applied_overrides}};
	ok((grep { /Override-Model-S7Router\.nmis$/ } @paths),
	   "S7: scoped Model override recorded in sidecar");
}

# -----------------------------------------------------------------------------
# Scenario 8: regression — with no overrides, $sys->{mdl} contains exactly
# the merged Model + Common content with no metadata leak.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S8Router");

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S8: load ok");
	is($sys->{mdl}->{system}->{nodeVendor}, 'BaseVendor',
	   "S8: model value untouched without override");
	ok(!exists $sys->{mdl}->{'-applied-overrides-'},
	   "S8: \$sys->{mdl} stays a pure model hash");
	is($sys->{mdl}->{systemHealth}->{rrd}->{cpu}->{graphtype}, 'cpu',
	   "S8: Common content still merged in");

	# sidecar must still be written, even with no overrides — freshness check needs it
	my $meta = read_sidecar("Model-$name");
	is(ref($meta), 'HASH', "S8: sidecar exists even with no overrides");
	is(ref($meta->{applied_overrides}), 'ARRAY',
	   "S8: sidecar applied_overrides is an arrayref");
	is(scalar(@{$meta->{applied_overrides}}), 0,
	   "S8: applied_overrides is empty when none on disk");
}

# -----------------------------------------------------------------------------
# Scenario 9: walker safety — top-level model walkers must not see any
# non-hash junk after loadModel(). Exercises the same iteration patterns
# init() and getTitle() use.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S9Router");

	# apply both a Model override and a Common override so multiple sidecar
	# entries get recorded, maximising the chance of stray metadata leakage.
	write_nmis_file("$custom_dir/Override-Model-$name.nmis", {
		system => { nodeVendor => 'WalkSafe' },
	});
	write_nmis_file("$custom_dir/Override-Common-S9RouterCpu.nmis", {
		systemHealth => {
			rrd => { cpu => { threshold => 'cpu_walked' } },
		},
	});

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S9: load ok");

	# 9a: every top-level value of $sys->{mdl} must be a hashref. This is
	# the invariant that protects all walker patterns in Sys.pm and elsewhere.
	my @nonhash_keys = grep { ref($sys->{mdl}->{$_}) ne "HASH" }
						keys %{$sys->{mdl}};
	is(scalar(@nonhash_keys), 0,
	   "S9: every top-level key in \$sys->{mdl} is a hashref")
		or diag("non-hash top-level keys: " . join(", ", @nonhash_keys));

	# 9b: getTitle's iteration shape — must not throw
	my $title;
	eval { $title = $sys->getTitle(attr => "nodeVendor"); };
	ok(!$@, "S9: getTitle does not crash on overridden model")
		or diag("getTitle threw: $@");

	# 9c: init()'s policy-section iteration shape — replicate it directly
	# and confirm no exception (the bug it would trigger is "Not a HASH reference")
	my $crashed;
	eval {
		for my $topsect (keys %{$sys->{mdl}}) {
			# the original init() loop dereferences ->{rrd} unconditionally;
			# we replicate that exact dereference to prove our model is safe
			my $rrd = $sys->{mdl}->{$topsect}->{rrd};
			# touch it so perl actually evaluates the deref
			my $is_hash = ref($rrd) eq "HASH";
		}
	};
	$crashed = $@;
	ok(!$crashed, "S9: init()-style top-level walker does not throw")
		or diag("walker threw: $crashed");

	# 9d: data integrity — overrides actually applied
	is($sys->{mdl}->{system}->{nodeVendor}, 'WalkSafe',
	   "S9: Model override value present");
	is($sys->{mdl}->{systemHealth}->{rrd}->{cpu}->{threshold}, 'cpu_walked',
	   "S9: Common override value present");
}

# -----------------------------------------------------------------------------
# Scenario 10: sidecar visibility — file present, parses, has expected
# structure. (Most assertions already covered by S7/S8; this consolidates
# a focused check.)
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S10Router");

	write_nmis_file("$custom_dir/Override-Common-S10RouterCpu.nmis", {
		systemHealth => { rrd => { cpu => { threshold => 'cpu_visible' } } },
	});

	my $sys = make_sys();
	ok($sys->loadModel(model => "Model-$name"), "S10: load ok");

	ok(-f sidecar_file("Model-$name"), "S10: sidecar file exists on disk");
	my $meta = read_sidecar("Model-$name");
	is(ref($meta), 'HASH', "S10: sidecar is a JSON hash");
	is(ref($meta->{applied_overrides}), 'ARRAY',
	   "S10: applied_overrides is an arrayref");
	is(scalar(@{$meta->{applied_overrides}}), 1,
	   "S10: exactly one override recorded");
	my $entry = $meta->{applied_overrides}->[0];
	like($entry->{path}, qr/Override-Common-S10RouterCpu\.nmis$/,
		 "S10: recorded path matches the override file");
	ok(defined $entry->{mtime} && $entry->{mtime} > 0,
	   "S10: recorded mtime is set");
}

# -----------------------------------------------------------------------------
# Scenario 11: missing sidecar forces reload. Closes the
# silent-stale-data hole — without the sidecar we cannot trust the cache.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S11Router");

	# load once with an override → cache + sidecar populated
	my $override_path = "$custom_dir/Override-Model-$name.nmis";
	write_nmis_file($override_path, {
		system => { nodeVendor => 'BeforeSidecarGone' },
	});

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S11: initial load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'BeforeSidecarGone',
		   "S11: override applied initially");
	}

	# pathological case: user deletes BOTH the override file AND the sidecar
	# leaving only the (now stale) model JSON. Without the sidecar gate, the
	# cached model would be silently used and contain wrong data.
	unlink($override_path) or die "unlink override: $!";
	my $sidecar = sidecar_file("Model-$name");
	ok(-f $sidecar, "S11: sidecar exists before deletion");
	unlink($sidecar) or die "unlink sidecar: $!";
	ok(!-f $sidecar, "S11: sidecar deleted");

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S11: post-delete load ok");
		is($sys->{mdl}->{system}->{nodeVendor}, 'BaseVendor',
		   "S11: missing sidecar forced reload, value reverted");
		ok(-f $sidecar, "S11: sidecar regenerated by reload");
	}
}

# -----------------------------------------------------------------------------
# Scenario 12: corrupt sidecar forces reload.
# -----------------------------------------------------------------------------
{
	clear_model_cache();
	my ($name) = install_base_model("S12Router");

	my $override_path = "$custom_dir/Override-Model-$name.nmis";
	write_nmis_file($override_path, {
		system => { nodeVendor => 'V1WithSidecar' },
	});

	# initial load → populates cache and sidecar
	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"), "S12: initial load ok");
	}

	# corrupt sidecar three different ways across sub-cases. Each must
	# trigger a reload; the load itself should always succeed.
	my $sidecar = sidecar_file("Model-$name");

	for my $case (
		[ "garbage non-JSON",        "this is not json {{{}}" ],
		[ "JSON array (not hash)",   '[1,2,3]' ],
		[ "JSON hash w/o array key", '{"foo":"bar"}' ],
	) {
		my ($label, $content) = @$case;
		write_file($sidecar, $content);

		# write override with a different value to prove a reload happened
		# (i.e. the new value would only appear on reload-from-source)
		sleep(1.2);
		write_nmis_file($override_path, {
			system => { nodeVendor => "Reloaded-$label" },
		});

		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-$name"),
		   "S12 [$label]: load ok despite corrupt sidecar");
		is($sys->{mdl}->{system}->{nodeVendor}, "Reloaded-$label",
		   "S12 [$label]: corrupt sidecar forced reload, latest override applied");
		# sidecar must be regenerated cleanly
		my $meta = read_sidecar("Model-$name");
		is(ref($meta), 'HASH',
		   "S12 [$label]: sidecar rewritten as valid hash");
		is(ref($meta->{applied_overrides}), 'ARRAY',
		   "S12 [$label]: applied_overrides arrayref restored");
	}
}

done_testing();
