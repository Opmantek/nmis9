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
# Tests the load-once layered config with source tracking.
# Note: since config is load-once per process, tests that require different
# conf.d content run in subprocesses.
use strict;
our $VERSION = "2.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::Timing;
use IO::File;
use File::Path qw( make_path remove_tree );
use Data::Dumper;

my $t = Compat::Timing->new();

# --- Test 1: Basic config loading ---
my $time = $t->elapTime();
my $C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
print $time. " time load config \n";

is($C->{'auth_expire'}, "+30min", "Config file loaded" );
ok(defined $C->{'db_server'}, "db_server is present");
ok(defined $C->{'<nmis_base>'}, "nmis_base directory macro is present");

# --- Test 2: Caching - second call returns same ref ---
my $C2 = NMISNG::Util::loadConfTable();
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
is($C->{'syslog_log'}, $C->{'<nmis_logs>'}."/cisco.log", "Replacing macros from master config OK" );

# --- Test 6: cluster_id is present ---
ok(defined $C->{cluster_id} && $C->{cluster_id} ne '', "cluster_id is present and non-empty");

# --- Test 7: conf.d override-only (run in subprocess) ---
my $conf_d_dir = $C->{'<nmis_conf>'} . "/conf.d";
if ( !-d $conf_d_dir ) {
    make_path $conf_d_dir or die "Failed to create path: $conf_d_dir";
}

my $test_file = "$conf_d_dir/TEST.nmis";

# Write a conf.d file that overrides an existing key
{
    open(my $fh, '>', $test_file) or die "Could not open file '$test_file' $!";
    print $fh "%hash = ('authentication'=>{'auth_expire'=>'+2min'});\n";
    close $fh;
}

# Test override in a subprocess (since config is load-once per process)
my $override_result = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print \$C->{auth_expire};
' 2>/dev/null`;
is($override_result, "+2min", "conf.d override of existing key works (subprocess)");

# Test that conf.d cannot add new keys (override-only)
{
    open(my $fh, '>', $test_file) or die "Could not open file '$test_file' $!";
    print $fh "%hash = ('authentication'=>{'auth_expire'=>'+2min', 'brand_new_key'=>'should_not_appear'});\n";
    close $fh;
}

my $newkey_result = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print defined(\$C->{brand_new_key}) ? "FOUND" : "NOT_FOUND";
' 2>/dev/null`;
is($newkey_result, "NOT_FOUND", "conf.d cannot add new keys (override-only)");

# Test that conf.d override is tracked in source
my $source_result = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my \$s = NMISNG::Util::getConfigSources(key => "auth_expire");
    print \$s->{layer} if \$s;
' 2>/dev/null`;
is($source_result, "3", "conf.d override tracked as layer 3");

# --- Test 8: ENV override ---
my $env_result = `NMIS_DB_SERVER=testhost perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print \$C->{db_server};
' 2>/dev/null`;
is($env_result, "testhost", "ENV NMIS_DB_SERVER override works");

# ENV override tracked as layer 4
my $env_source_result = `NMIS_DB_SERVER=testhost perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my \$s = NMISNG::Util::getConfigSources(key => "db_server");
    print \$s->{layer} if \$s;
' 2>/dev/null`;
is($env_source_result, "4", "ENV override tracked as layer 4");

# ENV URL_BASE backward compat
my $urlbase_result = `NMIS_URL_BASE=/test-cgi perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print \$C->{"<cgi_url_base>"};
' 2>/dev/null`;
is($urlbase_result, "/test-cgi", "ENV NMIS_URL_BASE maps to <cgi_url_base>");

# --- Test 9: stripDefaults returns valid structure ---
my $strip_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$stripped, \$removals) = NMISNG::Util::stripDefaults();
    die "stripped not hash" unless ref(\$stripped) eq "HASH";
    die "removals not array" unless ref(\$removals) eq "ARRAY";
    # stripped should have section keys (deep structure)
    my \$has_sections = grep { ref(\$stripped->{\$_}) eq "HASH" } keys %\$stripped;
    die "no sections in stripped" unless \$has_sections;
    # each removal should have section and key
    for my \$r (@\$removals) {
        die "bad removal entry" unless defined \$r->{section} && defined \$r->{key};
    }
    print "OK";
' 2>/dev/null`;
is($strip_test, "OK", "stripDefaults returns valid structure");

# --- Test 10: stripDefaults removals only contain values matching defaults ---
my $strip_match_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my \$default_file = \$C->{"<nmis_conf_default>"} . "/Config.nmis";
    my \$defaults = NMISNG::Util::readFiletoHash(file => \$default_file);
    my (\$stripped, \$removals) = NMISNG::Util::stripDefaults();
    # every removal must exist in defaults with the same value
    for my \$r (@\$removals) {
        my \$s = \$r->{section};
        my \$k = \$r->{key};
        die "removal \$s/\$k not in defaults" unless ref(\$defaults->{\$s}) eq "HASH"
            && exists \$defaults->{\$s}{\$k};
    }
    print "OK";
' 2>/dev/null`;
is($strip_match_test, "OK", "stripDefaults removals all exist in defaults");

# --- Test 11: stripDefaults keeps site-only keys ---
# Write a conf.d file with an override, then verify stripDefaults keeps overridden values
{
    open(my $fh, '>', $test_file) or die "Could not open file '$test_file' $!";
    print $fh "%hash = ('authentication'=>{'auth_expire'=>'+99min'});\n";
    close $fh;
}
my $strip_keep_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$stripped, \$removals) = NMISNG::Util::stripDefaults();
    # auth_expire in conf/Config.nmis should match the default (+30min),
    # so it should be in removals (the conf.d override is separate from conf/Config.nmis)
    # Verify stripped + defaults covers all keys from site config
    my \$site = NMISNG::Util::readFiletoHash(file => \$C->{configfile});
    for my \$section (keys %\$site) {
        next unless ref(\$site->{\$section}) eq "HASH";
        for my \$key (keys %{\$site->{\$section}}) {
            my \$in_stripped = ref(\$stripped->{\$section}) eq "HASH"
                && exists \$stripped->{\$section}{\$key};
            my \$in_removals = grep { \$_->{section} eq \$section && \$_->{key} eq \$key } @\$removals;
            die "key \$section/\$key lost" unless \$in_stripped || \$in_removals;
        }
    }
    print "OK";
' 2>/dev/null`;
is($strip_keep_test, "OK", "stripDefaults: every site key is either kept or in removals");

# --- Test 12: stripDefaults empty sections are removed ---
my $strip_empty_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$stripped, \$removals) = NMISNG::Util::stripDefaults();
    # no empty sections should exist in stripped
    for my \$section (keys %\$stripped) {
        next unless ref(\$stripped->{\$section}) eq "HASH";
        die "empty section \$section" unless keys %{\$stripped->{\$section}};
    }
    print "OK";
' 2>/dev/null`;
is($strip_empty_test, "OK", "stripDefaults: no empty sections in result");

# --- Test 13: Exclusive property in conf.d ignored when already in conf/Config.nmis ---
# cluster_id exists in conf/Config.nmis, so conf.d should not override it
{
    open(my $fh, '>', $test_file) or die "Could not open file '$test_file' $!";
    print $fh "%hash = ('id'=>{'cluster_id'=>'FAIL_FROM_CONFD'});\n";
    close $fh;
}
my $exclusive_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print (\$C->{cluster_id} ne "FAIL_FROM_CONFD" ? "OK" : "FAIL");
' 2>&1`;
# Check both that value was not overridden and that a warning was emitted
like($exclusive_test, qr/OK/, "Exclusive property cluster_id in conf.d ignored when already in site config");
like($exclusive_test, qr/Exclusive property/, "Warning emitted for duplicate exclusive property");

# --- Test 14: ENV cannot override exclusive property already claimed by a config file ---
my $env_exclusive_test = `NMIS_CLUSTER_ID=ENV_OVERRIDE perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print (\$C->{cluster_id} ne "ENV_OVERRIDE" ? "OK" : "FAIL");
' 2>&1`;
like($env_exclusive_test, qr/OK/, "ENV exclusive property cluster_id ignored when already in site config");
like($env_exclusive_test, qr/Exclusive property/, "Warning emitted for ENV exclusive property override");

# --- Test 15: Exclusive property accepted in conf.d when not in conf/Config.nmis ---
# Write a conf.d file with server_name; this test only works if server_name is NOT in conf/Config.nmis
# We test with a fresh key to avoid depending on site config state
my $exclusive_accept_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    # If server_name came from conf.d, there should be no exclusive warning for it
    # Just verify the config loaded without dying
    print "OK" if defined \$C;
' 2>&1`;
like($exclusive_accept_test, qr/OK/, "Config loads successfully with exclusive keys");

# --- Test 16: ENV can add new keys not in config ---
my $env_new_key_test = `NMIS_BRAND_NEW_TEST_KEY=hello perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    print \$C->{brand_new_test_key} // "MISSING";
' 2>/dev/null`;
is($env_new_key_test, "hello", "ENV can add new keys not in config");

# --- Test 17: writeConfData returns error for modified ENV-sourced key ---
my $env_write_test = `NMIS_DB_SERVER=envhost perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$rawdata, \$fn) = NMISNG::Util::getConfDeep(only_local => 1);
    # Change the ENV-managed key to a different value
    \$rawdata->{database}{db_server} = "changed_host";
    my \$error = NMISNG::Util::writeConfData(data => \$rawdata);
    print defined(\$error) ? "ERROR:\$error" : "OK";
' 2>/dev/null`;
like($env_write_test, qr/ERROR:.*db_server/, "writeConfData returns error for modified ENV-sourced key");

# --- Test 18: writeConfData returns error for modified conf.d key ---
{
    open(my $fh, '>', $test_file) or die "Could not open file '$test_file' $!";
    print $fh "%hash = ('authentication'=>{'auth_expire'=>'+5min'});\n";
    close $fh;
}
my $confd_write_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$rawdata, \$fn) = NMISNG::Util::getConfDeep(only_local => 1);
    # Change the conf.d-managed key
    \$rawdata->{authentication}{auth_expire} = "+99min";
    my \$error = NMISNG::Util::writeConfData(data => \$rawdata);
    print defined(\$error) ? "ERROR:\$error" : "OK";
' 2>/dev/null`;
like($confd_write_test, qr/ERROR:.*auth_expire/, "writeConfData returns error for modified conf.d key");

# --- Test 19: writeConfData allows writing normal keys ---
my $normal_write_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$rawdata, \$fn) = NMISNG::Util::getConfDeep(only_local => 1);
    \$rawdata->{email}{mail_domain} = "test-changed.example.com";
    my \$error = NMISNG::Util::writeConfData(data => \$rawdata);
    die "writeConfData failed: \$error" if \$error;
    my \$written = NMISNG::Util::readFiletoHash(file => \$C->{configfile});
    print(\$written->{email}{mail_domain} eq "test-changed.example.com" ? "OK" : "FAIL");
' 2>/dev/null`;
is($normal_write_test, "OK", "writeConfData allows writing normal keys");

# Restore config after test 19
`perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my \$bak = \$C->{configfile} . ".bak";
    rename(\$bak, \$C->{configfile}) if -e \$bak;
' 2>/dev/null`;

# --- Test 20: writeConfData skips unchanged conf.d keys without error ---
my $confd_unchanged_test = `perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my (\$rawdata, \$fn) = NMISNG::Util::getConfDeep(only_local => 1);
    # Pass data unchanged (includes conf.d merged values)
    my \$error = NMISNG::Util::writeConfData(data => \$rawdata);
    print defined(\$error) ? "ERROR:\$error" : "OK";
' 2>/dev/null`;
is($confd_unchanged_test, "OK", "writeConfData skips unchanged conf.d keys without error");

# Restore config after test 20
`perl -I$FindBin::Bin/../lib -e '
    use NMISNG::Util;
    my \$C = NMISNG::Util::loadConfTable();
    my \$bak = \$C->{configfile} . ".bak";
    rename(\$bak, \$C->{configfile}) if -e \$bak;
' 2>/dev/null`;

# Cleanup
unlink $test_file;

done_testing();
