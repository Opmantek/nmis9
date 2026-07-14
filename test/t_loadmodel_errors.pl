#!/usr/bin/perl
#
# t_loadmodel_errors.pl - tests NMISNG::Sys::loadModel() failure handling (OMK-12755).
#
# Covers: every failure path returns 0 and reports ALL failures (concatenated)
# in $sys->{error}; exactly one error line is logged per failed load; a corrupt
# cache with a good source recovers and returns 1; a successful reload on the
# same sys object clears a stale error; and the model_load_strict config gate
# controls whether partially loaded models are cached and whether a missing
# dependency file makes the cache stale.
#
# Runs against isolated temporary directories and a private config copy,
# needs no MongoDB and does not touch the repository or a live install.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Clone;

use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;

use File::Slurp qw(read_file write_file);

# -----------------------------------------------------------------------------
# Minimal nmisng-like object: loadModel only needs ->log (and ->config)
# -----------------------------------------------------------------------------
{
	package T::FakeNmisng;
	sub new { my ($c, %a) = @_; bless { %a }, $c; }
	sub log { $_[0]->{log} }
	sub config { $_[0]->{config} }
}

# -----------------------------------------------------------------------------
# Isolated environment
# -----------------------------------------------------------------------------
my $tmpbase      = tempdir("nmis-loadmodel-test-XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $defaults_dir = "$tmpbase/models-default";
my $custom_dir   = "$tmpbase/models-custom";
my $var_dir      = "$tmpbase/var";
my $conf_dir     = "$tmpbase/conf";
my $log_file     = "$tmpbase/test.log";
make_path($defaults_dir, $custom_dir, $conf_dir, "$var_dir/nmis_system/model_cache");

# private copy of the shipped config: loadConfTable persists things (cluster_id)
# back into its conf dir, which must never hit the repository copy. The copy is
# re-owned to the current user so persistence works quietly as non-root.
my $me = getpwuid($<);
{
	my $conf_raw = read_file("$FindBin::Bin/../conf-default/Config.nmis");
	$conf_raw =~ s/'nmis_user'\s*=>\s*'[^']*'/'nmis_user' => '$me'/;
	write_file("$conf_dir/Config.nmis", $conf_raw);
}
my $real_C = NMISNG::Util::loadConfTable(dir => $conf_dir);
die "cannot load config\n" if (ref($real_C) ne "HASH" or !keys %$real_C);

my $C = Clone::clone($real_C);
$C->{'<nmis_default_models>'} = $defaults_dir;
$C->{'<nmis_models>'}         = $custom_dir;
$C->{'<nmis_var>'}            = $var_dir;
$C->{'<nmis_conf>'}           = $conf_dir;
$C->{'<nmis_conf_default>'}   = $conf_dir;
delete $C->{global_model_overrides};
delete $C->{model_load_strict};
$C->{use_json}        = 'false';
$C->{use_json_pretty} = 'false';

# file ownership must work as the current, unprivileged user on any box
$C->{nmis_user}  = $me;
my ($gid)        = split(' ', $();
$C->{nmis_group} = getgrgid($gid);

# error-level logger writing to a file so tests can count logged errors
my $logger      = NMISNG::Log->new(level => 'error', path => $log_file);
my $fake_nmisng = T::FakeNmisng->new(config => $C, log => $logger);

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
sub write_nmis_file {
	my ($path, $data) = @_;
	if (my $err = NMISNG::Util::writeHashtoFile(file => $path, data => $data,
												json => 0, conf => $C))
	{
		die "failed to write $path: $err";
	}
	my $now = time();
	utime($now, $now, $path) or die "utime $path: $!";
	return $path;
}

sub make_sys {
	my (%opts) = @_;
	my $sys = NMISNG::Sys->new();
	$sys->{config}       = $C;
	$sys->{_nmisng}      = $fake_nmisng;
	$sys->{cache_models} = $opts{cache_models} // 1;
	return $sys;
}

sub clear_model_cache {
	my $cache_dir = "$var_dir/nmis_system/model_cache";
	if (opendir(my $dh, $cache_dir)) {
		while (my $f = readdir($dh)) {
			next if $f =~ /^\.\.?$/;
			unlink "$cache_dir/$f";
		}
		closedir($dh);
	}
}

sub model_cache_file {
	my ($model) = @_;
	return "$var_dir/nmis_system/model_cache/$model.json";
}

sub reset_log { write_file($log_file, ""); }

sub error_log_count {
	return 0 if (!-f $log_file);
	my @lines = grep { /\[error\]/ } read_file($log_file);
	return scalar(@lines);
}

# a model referencing a set of commons: class => feature name
sub install_model {
	my ($name, %opts) = @_;
	my $commons = $opts{commons} // {};
	my $mdl = {
		system => { nodeVendor => 'TestVendor', nodeType => 'router' },
		'-common-' => {
			class => { map { ($_ => { 'common-model' => $commons->{$_} }) } keys %$commons },
		},
	};
	if (my $extra = $opts{extra}) {
		# shallow top-level merge; extra wins
		$mdl->{$_} = $extra->{$_} for keys %$extra;
	}
	write_nmis_file("$defaults_dir/Model-$name.nmis", $mdl);
	return $name;
}

sub install_common {
	my ($feature, $content) = @_;
	$content //= { systemHealth => { rrd => { $feature => { graphtype => $feature } } } };
	write_nmis_file("$defaults_dir/Common-$feature.nmis", $content);
}

# -----------------------------------------------------------------------------
# S1: missing main model file
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();

	my $sys = make_sys();
	my $ok  = $sys->loadModel(model => "Model-E1NoSuch");

	ok(!$ok, "S1: missing main model file returns 0");
	like($sys->{error}, qr/Model-E1NoSuch/, "S1: error names the missing model");
	is(error_log_count(), 1, "S1: exactly one error line logged");
}

# -----------------------------------------------------------------------------
# S2: one missing common out of two - partial model, error names the file
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_common("E2Good");
	install_model("E2Router", commons => { good => 'E2Good', missing => 'E2Missing' });

	my $sys = make_sys();
	my $ok  = $sys->loadModel(model => "Model-E2Router");

	ok(!$ok, "S2: missing common returns 0");
	like($sys->{error}, qr/Common-E2Missing/, "S2: error names the missing common");
	is($sys->{mdl}{systemHealth}{rrd}{E2Good}{graphtype}, 'E2Good',
	   "S2: content from the good common is still merged");
	is(error_log_count(), 1, "S2: exactly one error line logged");
}

# -----------------------------------------------------------------------------
# S3: two missing commons - error must report BOTH, still one log line
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_model("E3Router", commons => { m1 => 'E3MissA', m2 => 'E3MissB' });

	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-E3Router"), "S3: returns 0");
	like($sys->{error}, qr/Common-E3MissA/, "S3: error reports first missing common");
	like($sys->{error}, qr/Common-E3MissB/, "S3: error reports second missing common");
	is(error_log_count(), 1, "S3: still exactly one error line logged");
}

# -----------------------------------------------------------------------------
# S4: missing global override file
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_model("E4Router");

	local $C->{global_model_overrides} = ['e4nosuch'];

	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-E4Router"), "S4: missing global override returns 0");
	like($sys->{error}, qr/Override-e4nosuch/, "S4: error names the missing override");
	is(error_log_count(), 1, "S4: exactly one error line logged");
}

# -----------------------------------------------------------------------------
# S5: unmergeable common - error must name the file that failed to merge
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	# model provides a hash at system/clashkey, common provides a scalar there:
	# _mergeHash refuses (dest is HASH, source is not)
	install_common("E5Clash", { system => { clashkey => 'scalar-value' } });
	install_model("E5Router",
		commons => { clash => 'E5Clash' },
		extra   => { system => { nodeVendor => 'TestVendor', nodeType => 'router',
								 clashkey   => { nested => 1 } } });

	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-E5Router"), "S5: unmergeable common returns 0");
	like($sys->{error}, qr/Common-E5Clash/, "S5: error names the unmergeable common");
	like($sys->{error}, qr/cannot merge/, "S5: error carries the merge detail");
	is(error_log_count(), 1, "S5: exactly one error line logged");
}

# -----------------------------------------------------------------------------
# S6: corrupt cache file with a good source must recover and return 1
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_common("E6Cpu");
	install_model("E6Router", commons => { cpu => 'E6Cpu' });

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-E6Router"), "S6: initial load ok");
	}
	my $cf = model_cache_file("Model-E6Router");
	ok(-f $cf, "S6: cache file was written");
	write_file($cf, "{{{ this is not json");

	my $sys = make_sys();
	my $ok  = $sys->loadModel(model => "Model-E6Router");
	ok($ok, "S6: corrupt cache with good source returns 1");
	ok(!$sys->{error}, "S6: no error left on sys after recovery")
		or diag("leftover error: $sys->{error}");
	is($sys->{mdl}{system}{nodeVendor}, 'TestVendor', "S6: model content correct after recovery");
	is(error_log_count(), 0, "S6: a self-healed cache is not an error");
}

# -----------------------------------------------------------------------------
# S7: recovery on the SAME sys object - fix the model, returns 1, error cleared
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_model("E7Router", commons => { cpu => 'E7Cpu' });    # Common-E7Cpu missing

	my $sys = make_sys(cache_models => 0);
	ok(!$sys->loadModel(model => "Model-E7Router"), "S7: fails while common is missing");
	like($sys->{error}, qr/Common-E7Cpu/, "S7: error names the missing common");

	install_common("E7Cpu");

	my $ok = $sys->loadModel(model => "Model-E7Router");
	ok($ok, "S7: same sys returns 1 once the model is fixed");
	ok(!$sys->{error}, "S7: stale error cleared by successful reload")
		or diag("leftover error: $sys->{error}");
	ok(!$sys->status->{error}, "S7: status() no longer reports an error");
}

# -----------------------------------------------------------------------------
# S8: lenient default - partially loaded model is still cached (current
# behaviour, preserved for upgrades)
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_model("E8Router", commons => { miss => 'E8Miss' });

	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-E8Router"), "S8: load fails");
	ok(-f model_cache_file("Model-E8Router"),
	   "S8: lenient default still caches the partially loaded model");
}

# -----------------------------------------------------------------------------
# S9: strict gate - partially loaded model must NOT be cached
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_model("E9Router", commons => { miss => 'E9Miss' });

	local $C->{model_load_strict} = 'true';

	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-E9Router"), "S9: load fails");
	ok(!-f model_cache_file("Model-E9Router"),
	   "S9: strict mode does not cache a partially loaded model");
}

# -----------------------------------------------------------------------------
# S10: strict gate - a missing dependency file makes the cache stale
# -----------------------------------------------------------------------------
{
	reset_log(); clear_model_cache();
	install_common("EACpu");
	install_model("EARouter", commons => { cpu => 'EACpu' });

	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-EARouter"), "S10: initial load ok");
	}

	unlink("$defaults_dir/Common-EACpu.nmis") or die "unlink: $!";

	# lenient: existing cache keeps being trusted (current behaviour)
	{
		my $sys = make_sys();
		ok($sys->loadModel(model => "Model-EARouter"),
		   "S10: lenient keeps using the cache when a dependency vanishes");
	}

	# strict: stale, reload from source, fail loudly naming the file
	local $C->{model_load_strict} = 'true';
	my $sys = make_sys();
	ok(!$sys->loadModel(model => "Model-EARouter"),
	   "S10: strict treats a missing dependency as stale and fails loudly");
	like($sys->{error}, qr/Common-EACpu/, "S10: error names the vanished common");
}

done_testing();
