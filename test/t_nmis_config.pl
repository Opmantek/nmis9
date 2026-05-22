#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Test NMISNG config loading (layered config system)
# Uses a temp directory for all config writes to protect system config.
# The real conf-default/Config.nmis is symlinked as layer 1 defaults.
use strict;
our $VERSION = "4.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::Timing;
use File::Basename;
use File::Path qw( make_path );
use File::Copy;
use File::Temp qw( tempdir );
use Data::Dumper;

# --- Setup temp directory ---
# Structure: $tmpdir/conf/ (layer 2 + conf.d), $tmpdir/conf-default/ (symlink to real defaults)
my $tmpdir = tempdir("nmis_test_XXXX", TMPDIR => 1, CLEANUP => 1);
my $test_conf = "$tmpdir/conf";
my $test_conf_default = "$tmpdir/conf-default";
make_path($test_conf, "$test_conf/conf.d", $test_conf_default);
symlink("$FindBin::Bin/../conf-default/Config.nmis", "$test_conf_default/Config.nmis")
	or die "Cannot symlink defaults: $!";

# Redirect <nmis_var> to temp dir via conf.d override (persists across site config changes)
my $test_var = "$tmpdir/var";
make_path("$test_var/nmis_system");
{
	my $dir_override_file = "$test_conf/conf.d/00_test_dirs.nmis";
	open(my $fh, '>', $dir_override_file) or die "Cannot write dir overrides: $!";
	print $fh Data::Dumper->Dump([{ 'directories' => { '<nmis_base>' => $tmpdir, '<nmis_var>' => $test_var } }], [qw(*hash)]);
	close $fh;
}

# Helper: force config reload from disk
sub reload_config {
	$NMISNG::Util::_config_cache_invalid = 1;
	return NMISNG::Util::loadConfTable(dir => $test_conf);
}

# Helper: restore config from .bak file
sub restore_config {
	my $C = NMISNG::Util::loadConfTable(dir => $test_conf);
	my $bak = $C->{configfile} . ".bak";
	File::Copy::move($bak, $C->{configfile}) if -e $bak;
	reload_config();
}

my $test_file = "$test_conf/conf.d/TEST.nmis";

# --- Test 1: Basic config loading (defaults only, no site config) ---
my $C = NMISNG::Util::loadConfTable(dir => $test_conf);
is($C->{'auth_expire'}, "+30min", "Config file loaded from defaults");
ok(defined $C->{'db_server'}, "db_server is present");
ok(defined $C->{'<nmis_base>'}, "nmis_base directory macro is present");

# --- Test 2: Caching - second call returns same ref ---
my $C2 = NMISNG::Util::loadConfTable(dir => $test_conf);
is($C, $C2, "Second loadConfTable call returns cached ref");

# --- Test 3: Source tracking ---
my $sources = NMISNG::Util::getConfigSources();
ok(ref($sources) eq 'HASH', "getConfigSources returns hashref");
ok(scalar keys %$sources > 0, "getConfigSources has entries");

my $db_source = NMISNG::Util::getConfigSources(key => 'db_server');
ok(defined $db_source, "getConfigSources returns info for db_server");
ok($db_source->{layer} >= 1 && $db_source->{layer} <= 4, "db_server has valid layer");
ok(defined $db_source->{section}, "db_server has section info");
is($db_source->{section}, "database", "db_server section is 'database'");

# --- Test 4: Hardcoded values tracked ---
my $conf_source = NMISNG::Util::getConfigSources(key => 'conf');
ok(defined $conf_source, "getConfigSources returns info for hardcoded 'conf'");
is($conf_source->{source}, "hardcoded", "conf source is 'hardcoded'");

# --- Test 5: Macro replacement ---
is($C->{'syslog_log'}, $C->{'<nmis_logs>'} . "/cisco.log", "Replacing macros from master config OK");

# --- Test 6: cluster_id is generated when missing ---
ok(defined $C->{cluster_id} && $C->{cluster_id} ne '', "cluster_id is present and non-empty");

# --- Test 7: conf.d override of existing key ---
{
	open(my $fh, '>', $test_file) or die "Could not open $test_file: $!";
	print $fh "%hash = ('authentication'=>{'auth_expire'=>'+2min'});\n";
	close $fh;

	$C = reload_config();
	is($C->{auth_expire}, "+2min", "conf.d override of existing key works");
}

# --- Test 8: conf.d cannot add new keys (override-only) ---
{
	open(my $fh, '>', $test_file) or die "Could not open $test_file: $!";
	print $fh "%hash = ('authentication'=>{'auth_expire'=>'+2min', 'brand_new_key'=>'should_not_appear'});\n";
	close $fh;

	$C = reload_config();
	ok(!defined $C->{brand_new_key}, "conf.d cannot add new keys (override-only)");
}

# --- Test 9: conf.d override tracked as layer 3 ---
{
	my $s = NMISNG::Util::getConfigSources(key => "auth_expire");
	is($s->{layer}, 3, "conf.d override tracked as layer 3");
}

# Clean up conf.d
unlink $test_file;
$C = reload_config();

# --- Test 10: ENV override ---
{
	local $ENV{NMIS_DB_SERVER} = "testhost";
	$C = reload_config();
	is($C->{db_server}, "testhost", "ENV NMIS_DB_SERVER override works");
}

# --- Test 11: ENV override tracked as layer 4 ---
{
	local $ENV{NMIS_DB_SERVER} = "testhost";
	$C = reload_config();
	my $s = NMISNG::Util::getConfigSources(key => "db_server");
	is($s->{layer}, 4, "ENV override tracked as layer 4");
}
$C = reload_config();

# --- Test 12: ENV NMIS_URL_BASE maps to <url_base> ---
{
	local $ENV{NMIS_URL_BASE} = "/test-url";
	$C = reload_config();
	is($C->{'<url_base>'}, "/test-url", "ENV NMIS_URL_BASE maps to <url_base>");
}
$C = reload_config();

# --- Test 13: stripDefaults returns valid structure ---
{
	my ($stripped, $removals) = NMISNG::Util::stripDefaults();
	ok(ref($stripped) eq 'HASH', "stripDefaults returns hashref");
	ok(ref($removals) eq 'ARRAY', "stripDefaults returns arrayref of removals");
	my $has_sections = grep { ref($stripped->{$_}) eq 'HASH' } keys %$stripped;
	ok($has_sections || !keys %$stripped, "stripDefaults result has section keys or is empty");
	my $all_valid = 1;
	for my $r (@$removals) {
		$all_valid = 0 unless defined $r->{section} && defined $r->{key};
	}
	ok($all_valid, "stripDefaults removals all have section and key");
}

# --- Test 14: stripDefaults removals match defaults ---
{
	my $defaults = NMISNG::Util::getConfigDefaults();
	my ($stripped, $removals) = NMISNG::Util::stripDefaults();
	my $all_in_defaults = 1;
	for my $r (@$removals) {
		unless (ref($defaults->{$r->{section}}) eq 'HASH' && exists $defaults->{$r->{section}}{$r->{key}}) {
			$all_in_defaults = 0;
			last;
		}
	}
	ok($all_in_defaults, "stripDefaults removals all exist in defaults");
}

# --- Test 15: stripDefaults with site config ---
{
	# Write a site config with a non-default value
	my %site = ( "email" => { "mail_domain" => "custom.example.com" } );
	NMISNG::Util::writeHashtoFile(file => "$test_conf/Config.nmis", data => \%site);
	$C = reload_config();

	my ($stripped, $removals) = NMISNG::Util::stripDefaults();
	ok(ref($stripped->{email}) eq 'HASH' && $stripped->{email}{mail_domain} eq "custom.example.com",
		"stripDefaults keeps non-default site key");

	unlink "$test_conf/Config.nmis";
	$C = reload_config();
}

# --- Test 16: stripDefaults: no empty sections ---
{
	my ($stripped, $removals) = NMISNG::Util::stripDefaults();
	my $no_empty = 1;
	for my $section (keys %$stripped) {
		next unless ref($stripped->{$section}) eq 'HASH';
		$no_empty = 0 unless keys %{$stripped->{$section}};
	}
	ok($no_empty, "stripDefaults: no empty sections in result");
}

# --- Test 17: Exclusive property in conf.d ignored when already in local config ---
{
	# Write site config with cluster_id
	my %site = ( "id" => { "cluster_id" => "my-site-cluster-id" } );
	NMISNG::Util::writeHashtoFile(file => "$test_conf/Config.nmis", data => \%site);

	# Write conf.d with conflicting cluster_id
	open(my $fh, '>', $test_file) or die "Could not open $test_file: $!";
	print $fh "%hash = ('id'=>{'cluster_id'=>'FAIL_FROM_CONFD'});\n";
	close $fh;

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	$C = reload_config();

	is($C->{cluster_id}, "my-site-cluster-id", "Exclusive property cluster_id in conf.d ignored");
	ok(grep(/Exclusive property/, @warnings), "Warning emitted for duplicate exclusive property");
}

# --- Test 18: ENV cannot override exclusive property already claimed ---
{
	local $ENV{NMIS_CLUSTER_ID} = "ENV_OVERRIDE";
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	$C = reload_config();

	is($C->{cluster_id}, "my-site-cluster-id", "ENV exclusive property cluster_id ignored");
	ok(grep(/Exclusive property/, @warnings), "Warning emitted for ENV exclusive property override");
}

# Clean up
unlink $test_file;
unlink "$test_conf/Config.nmis";
$C = reload_config();

# --- Test 19: ENV can add new keys not in config ---
{
	local $ENV{NMIS_BRAND_NEW_TEST_KEY} = "hello";
	$C = reload_config();
	is($C->{brand_new_test_key}, "hello", "ENV can add new keys not in config");
}
$C = reload_config();

# --- Test 20: writeConfData returns error for modified ENV-sourced key ---
{
	local $ENV{NMIS_DB_SERVER} = "envhost";
	$C = reload_config();
	my ($rawdata, $fn) = NMISNG::Util::getConfDeep(only_local => 1);
	$rawdata->{database}{db_server} = "changed_host";
	my $error = NMISNG::Util::writeConfData(data => $rawdata);
	like($error, qr/db_server/, "writeConfData returns error for modified ENV-sourced key");
}
$C = reload_config();

# --- Test 21: writeConfData returns error for modified conf.d key ---
{
	open(my $fh, '>', $test_file) or die "Could not open $test_file: $!";
	print $fh "%hash = ('authentication'=>{'auth_expire'=>'+5min'});\n";
	close $fh;
	$C = reload_config();

	my ($rawdata, $fn) = NMISNG::Util::getConfDeep();
	$rawdata->{authentication}{auth_expire} = "+99min";
	my $error = NMISNG::Util::writeConfData(data => $rawdata);
	like($error, qr/auth_expire/, "writeConfData returns error for modified conf.d key");
}

# --- Test 22: writeConfData allows writing normal keys ---
{
	my ($rawdata, $fn) = NMISNG::Util::getConfDeep();
	$rawdata->{email}{mail_domain} = "test-changed.example.com";
	my $error = NMISNG::Util::writeConfData(data => $rawdata);
	ok(!$error, "writeConfData allows writing normal keys");

	$C = reload_config();
	is($C->{mail_domain}, "test-changed.example.com", "Written value is correct after reload");
	restore_config();
}

# --- Test 23: writeConfData skips unchanged conf.d keys without error ---
{
	my ($rawdata, $fn) = NMISNG::Util::getConfDeep();
	my $error = NMISNG::Util::writeConfData(data => $rawdata);
	ok(!$error, "writeConfData skips unchanged conf.d keys without error");
	restore_config();
}

# Clean up conf.d
unlink $test_file;
$C = reload_config();

# --- Test 24: configChanged returns false when no change has occurred ---
{
	ok(!NMISNG::Util::configChanged(conf => $C), "configChanged returns false when no change has occurred");
}

# --- Test 25: configChanged returns true after marker is updated ---
{
	sleep(1);
	my $marker = $C->{'<nmis_var>'} . "/nmis_system/config_changed";
	make_path(File::Basename::dirname($marker));
	open(my $fh, ">", $marker) or die "cannot write marker: $!";
	print $fh time() . "\n";
	close $fh;
	ok(NMISNG::Util::configChanged(conf => $C), "configChanged returns true after marker is updated");
}

# --- Test 26: writeConfData preserves site keys and adds new overrides without defaults ---
{
	my $configfile = "$test_conf/Config.nmis";

	# Write a known starting site config
	my %initial = (
		"email"  => { "mail_domain" => "mycompany.com", "mail_from" => 'test@mycompany.com' },
		"system" => { "nmis_user" => "testuser" },
	);
	NMISNG::Util::writeHashtoFile(file => $configfile, data => \%initial);
	$C = reload_config();

	# Get full effective config and modify two default values
	my ($full, undef) = NMISNG::Util::getConfDeep();
	$full->{system}{ping_timeout} = "9999";
	$full->{logging}{log_level} = "debug";

	my $error = NMISNG::Util::writeConfData(data => $full);
	ok(!$error, "writeConfData succeeds with mixed site + new overrides");

	# Read back the file
	my $written = NMISNG::Util::readFiletoHash(file => $configfile);

	# Existing site keys preserved
	is($written->{email}{mail_domain}, "mycompany.com", "Existing site key mail_domain preserved");
	is($written->{email}{mail_from}, 'test@mycompany.com', "Existing site key mail_from preserved");
	is($written->{system}{nmis_user}, "testuser", "Existing site key nmis_user preserved");

	# New overrides added
	is($written->{system}{ping_timeout}, "9999", "New override ping_timeout added");
	is($written->{logging}{log_level}, "debug", "New override log_level added");

	# Default values NOT in file
	ok(!exists $written->{database}{db_port}, "Default db_port not in written file");
	ok(!exists $written->{authentication}{auth_expire}, "Default auth_expire not in written file");

	restore_config();
}

# --- Test 27: getConfigDefaults returns layer 1 data ---
{
	my $defaults = NMISNG::Util::getConfigDefaults();
	ok(ref($defaults) eq 'HASH', "getConfigDefaults returns hashref");
	ok(ref($defaults->{database}) eq 'HASH', "getConfigDefaults has database section");
	ok(exists $defaults->{database}{db_server}, "getConfigDefaults has db_server in database");
}

done_testing();
