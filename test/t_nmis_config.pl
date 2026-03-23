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

# Test NMISNG config loading, external config, macro replacement,
# and atomic file writing safety.
use strict;
our $VERSION = "1.2.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::Timing;
use IO::File;
use File::Path qw(make_path rmtree);
use File::Temp qw(tempdir);
use Data::Dumper;

my $t = Compat::Timing->new();

# ============================================================================
# Config loading
# ============================================================================
my $time = $t->elapTime();
my $C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
diag("Config load time: ${time}s");

my $logger = NMISNG::Log->new(level => 'debug');

is($C->{'auth_expire'}, "+30min", "Config file loaded");

# Remember the original cluster_id so we can test it's not overwritten
my $original_cluster_id = $C->{'cluster_id'};
ok(defined $original_cluster_id && $original_cluster_id ne '',
	"cluster_id is set: $original_cluster_id");

# ============================================================================
# External config (conf.d) override
# ============================================================================
my $conf_d_dir = $C->{'<nmis_conf>'} . "/conf.d";
if (!-d $conf_d_dir) {
	make_path($conf_d_dir) or die "Failed to create path: $conf_d_dir";
}

my $ext_file = "$conf_d_dir/TEST.nmis";

# Write an external config that overrides auth_expire
_write_test_file($ext_file,
	"%hash = ('authentication'=>{'auth_expire'=>'+2min', 'test'=>2});");

$time = $t->elapTime();
$C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
diag("Config reload time with conf.d: ${time}s");

is($C->{'auth_expire'}, "+2min", "External config file overrides auth_expire");

# ============================================================================
# Non-modifiable properties (cluster_id cannot be overridden via conf.d)
# ============================================================================
_write_test_file($ext_file,
	"%hash = ('id'=>{'cluster_id'=>'FAIL'});");

$time = $t->elapTime();
$C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
diag("Config reload time with non-modifiable override: ${time}s");

is($C->{'cluster_id'}, $original_cluster_id,
	"cluster_id cannot be overridden via conf.d");

# ============================================================================
# Macro replacement in external config values
# ============================================================================
_write_test_file($ext_file,
	"%hash = ('authentication'=>{'auth_htpasswd_file'=>'<nmis_conf>/users.dat'});");

$C = NMISNG::Util::loadConfTable();

is($C->{'auth_htpasswd_file'}, $C->{'<nmis_conf>'} . "/users.dat",
	"Macros replaced in external conf.d values");

# Verify macros are also replaced in the master config
is($C->{'syslog_log'}, $C->{'<nmis_logs>'} . "/cisco.log",
	"Macros replaced in master config values");

# ============================================================================
# Atomic write: basic .nmis round-trip
# ============================================================================
my $test_dir = tempdir(CLEANUP => 1);
my $test_conf = {
	%$C,
	'<nmis_conf>' => $test_dir,
	'<nmis_var>'  => $test_dir,
};

my $test_file = "$test_dir/AtomicTest";
my $test_data = {
	system => { name => 'testnode', location => 'DC1' },
	id     => { cluster_id => 'abc-123' },
};

my $err = NMISNG::Util::writeHashtoFile(
	file => $test_file, data => $test_data, conf => $test_conf);
is($err, undef, "Atomic write: .nmis write succeeds");

my $written_file = "$test_file.nmis";
ok(-e $written_file, "Atomic write: output file exists");
ok(-s $written_file, "Atomic write: output file is not empty");

my $readback = NMISNG::Util::readFiletoHash(file => $test_file, conf => $test_conf);
ok(ref($readback) eq 'HASH', "Atomic write: read back returns a hash");
is($readback->{system}->{name}, 'testnode',
	"Atomic write: data round-trips correctly");

# ============================================================================
# Atomic write: JSON round-trip
# ============================================================================
my $json_file = "$test_dir/AtomicJson";
my $json_data = { server => 'localhost', port => 27017 };

$err = NMISNG::Util::writeHashtoFile(
	file => $json_file, data => $json_data,
	json => 'true', pretty => 'true', conf => $test_conf);
is($err, undef, "Atomic write: JSON write succeeds");

my $json_written = "$json_file.json";
ok(-e $json_written, "Atomic write: JSON file exists");
ok(-s $json_written, "Atomic write: JSON file is not empty");

my $json_readback = NMISNG::Util::readFiletoHash(
	file => $json_file, json => 'true', conf => $test_conf);
is($json_readback->{server}, 'localhost',
	"Atomic write: JSON data round-trips correctly");

# ============================================================================
# Atomic write: original file preserved when write fails
# ============================================================================
my $protected_dir = "$test_dir/protected";
make_path($protected_dir);

my $prot_file = "$protected_dir/Config";
my $original_data = { system => { name => 'original', important => 'do_not_lose' } };

$err = NMISNG::Util::writeHashtoFile(
	file => $prot_file, data => $original_data, conf => $test_conf);
is($err, undef, "Atomic write: initial write to protected dir succeeds");

my $prot_written = "$prot_file.nmis";
my $original_size = -s $prot_written;
ok($original_size > 0, "Atomic write: original file has content ($original_size bytes)");

# Make directory read-only so temp file creation fails
chmod 0555, $protected_dir;

my $bad_data = { system => { name => 'should_not_appear' } };
$err = NMISNG::Util::writeHashtoFile(
	file => $prot_file, data => $bad_data, conf => $test_conf);

ok(defined $err, "Atomic write: write to read-only dir returns error");

# Original file must be untouched
is(-s $prot_written, $original_size,
	"Atomic write: original file size unchanged after failed write");

# Restore permissions and verify content
chmod 0755, $protected_dir;
my $preserved = NMISNG::Util::readFiletoHash(file => $prot_file, conf => $test_conf);
is($preserved->{system}->{name}, 'original',
	"Atomic write: original data intact after failed write");
is($preserved->{system}->{important}, 'do_not_lose',
	"Atomic write: all original fields preserved after failed write");

# ============================================================================
# Atomic write: no temp files left behind (success case)
# ============================================================================
my $clean_dir = "$test_dir/clean";
make_path($clean_dir);

$err = NMISNG::Util::writeHashtoFile(
	file => "$clean_dir/Test", data => { x => 1 }, conf => $test_conf);
is($err, undef, "Atomic write: clean write succeeds");

my @leftover = glob("$clean_dir/.tmp.*");
is(scalar @leftover, 0,
	"Atomic write: no temp files left after successful write");

# ============================================================================
# Atomic write: no temp files left behind (failure case)
# ============================================================================
my $fail_dir = "$test_dir/failclean";
make_path($fail_dir);

# Write an initial file, then make dir read-only
NMISNG::Util::writeHashtoFile(
	file => "$fail_dir/Test", data => { x => 1 }, conf => $test_conf);
chmod 0555, $fail_dir;

NMISNG::Util::writeHashtoFile(
	file => "$fail_dir/Test", data => { x => 2 }, conf => $test_conf);

chmod 0755, $fail_dir;
my @leftover_fail = glob("$fail_dir/.tmp.*");
is(scalar @leftover_fail, 0,
	"Atomic write: no temp files left after failed write");

# ============================================================================
# Atomic write: sequential overwrites all succeed
# ============================================================================
my $seq_file = "$test_dir/SeqTest";
for my $i (1..10) {
	my $data = { system => { counter => $i, padding => 'x' x 1000 } };
	$err = NMISNG::Util::writeHashtoFile(
		file => $seq_file, data => $data, conf => $test_conf);
	is($err, undef, "Atomic write: sequential write $i succeeds");
}

my $seq_readback = NMISNG::Util::readFiletoHash(file => $seq_file, conf => $test_conf);
is($seq_readback->{system}->{counter}, 10,
	"Atomic write: final value correct after 10 sequential writes");
ok(-s "$seq_file.nmis" > 0,
	"Atomic write: file not empty after sequential writes");

# ============================================================================
# Cleanup
# ============================================================================
unlink $ext_file;
rmtree($test_dir);

done_testing();

# Helper to write a test file
sub _write_test_file {
	my ($path, $content) = @_;
	open(my $fh, '>', $path) or die "Could not open file '$path': $!";
	print $fh $content;
	close $fh;
}
