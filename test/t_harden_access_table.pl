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
# *****************************************************************************
#
# admin/harden_access_table.pl aligns a live conf/Access.nmis with conf-default
# for the rights NMISNG::Auth forces admin-only (OMK-12707, OMK-12823).
# Isolated temp tree, no database, no live conf/.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use Test::More;
use File::Copy;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use NMISNG::Util;
use NMISNG::Auth;

local $ENV{CONTAINER} = "1";		# skip ownership/permission enforcement
my $conf = { use_json => 'false', use_json_pretty => 'false',
						 nmis_user => 'nmis', nmis_group => 'nmis' };

my @rights = NMISNG::Auth::admin_only_rights();
ok(scalar(@rights), "NMISNG::Auth exposes the guarded rights") or done_testing, exit;

# the script resolves its own paths from $FindBin, so run a COPY from inside the
# tempdir. A direct call would read and write the real conf/ (t_updateconfig.pl).
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/admin", "$dir/conf", "$dir/conf-default", "$dir/var/nmis_system");
for my $s (qw(harden_access_table.pl patch_config.pl))
{
	copy("$FindBin::RealBin/../admin/$s", "$dir/admin/$s") or die "copy $s: $!";
	chmod 0755, "$dir/admin/$s";
}
my $harden = "$dir/admin/harden_access_table.pl";
ok(-x $harden, "isolated copy of harden_access_table.pl is executable") or die;
local $ENV{PERL5LIB} = join(":", "$FindBin::RealBin/../lib", ($ENV{PERL5LIB} // ()));

# conf-default/Config.nmis with <nmis_base> repointed at the tempdir, so
# <nmis_conf>, <nmis_conf_default> and <nmis_var> all land inside it.
my $cfg = NMISNG::Util::readFiletoHash(
	file => "$FindBin::RealBin/../conf-default/Config.nmis", conf => $conf);
$cfg->{directories}{'<nmis_base>'} = $dir;
NMISNG::Util::writeHashtoFile(file => "$dir/conf-default/Config.nmis",
															data => $cfg, conf => $conf);

# the shipped default table is the source of truth for the target values
my $defaults = NMISNG::Util::readFiletoHash(
	file => "$FindBin::RealBin/../conf-default/Access.nmis", conf => $conf);
is(ref($defaults), "HASH", "conf-default/Access.nmis is loadable") or die;
copy("$FindBin::RealBin/../conf-default/Access.nmis", "$dir/conf-default/Access.nmis")
		or die "copy Access.nmis: $!";

my $livefile = "$dir/conf/Access.nmis";
my $localcfg = "$dir/conf/Config.nmis";		# layer 2, where the record is written

# a pre-fix live table, round-tripped through the real writer rather than
# hand-written, so a format change cannot leave this passing against dead bytes.
sub seed_live
{
	my $live = NMISNG::Util::readFiletoHash(
		file => "$FindBin::RealBin/../conf-default/Access.nmis", conf => $conf);
	# the pre-OMK-12707 grant at every non-admin level. A level1-only seed
	# leaves the engineer (level2) grant on access/config/tables unpinned.
	for my $r (@rights)
	{
		$live->{$r}->{"level$_"} = "1" for (1..5);
	}
	# the unguarded control, drifted at every level so "only guarded rights are
	# touched" is asserted across the whole record.
	if (ref($live->{table_nodes_rw}) eq "HASH")
	{
		$live->{table_nodes_rw}->{"level$_"} = "1" for (0..5);
	}
	NMISNG::Util::writeHashtoFile(file => $livefile, data => $live, conf => $conf);
	# a layer-2 overlay with no record in it. The script refuses to create one,
	# and loadConfTable only makes it as a side effect of persisting a cluster_id.
	NMISNG::Util::writeHashtoFile(file => $localcfg, conf => $conf,
															data => { id => { cluster_id => "test-cluster-id" } });
}

# what the script has recorded, read from the layer it writes to
sub recorded
{
	return "" if (!-e $localcfg);
	my $h = NMISNG::Util::readFiletoHash(file => $localcfg, conf => $conf);
	return $h->{authentication}->{access_table_hardened} // "";
}
sub live_val { my ($r,$l) = @_;
	my $h = NMISNG::Util::readFiletoHash(file => $livefile, conf => $conf);
	return $h->{$r}->{"level$l"} }
sub run { return system("$harden @_ >/dev/null 2>&1") >> 8 }

# --- report mode changes nothing and signals that work is pending ---------
seed_live();
# without this the --apply assertions below could pass against a table that
# never needed correcting at the engineer level.
isnt($defaults->{$rights[0]}->{level2}, "1",
	 "fixture: conf-default denies level2, so the seeded level2 is real drift");
is(run(), 1, "report mode exits 1 when corrections are pending");
is(live_val($rights[0], 1), "1", "report mode left the live value alone");
is(live_val($rights[0], 2), "1", "report mode left the engineer level alone");
is(recorded(), "", "report mode did not set the flag");

# --- apply corrects every guarded right, and only those -------------------
is(run("--apply"), 0, "--apply exits 0");
for my $r (@rights)
{
	for my $l (0..5)
	{
		is(live_val($r, $l), $defaults->{$r}->{"level$l"},
			 "$r level$l now matches conf-default");
	}
}
for my $l (0..5)
{
	is(live_val("table_nodes_rw", $l), "1",
		 "an unguarded right was left at its live level$l value");
}
ok(-e "$livefile.prepatch", "--apply wrote a .prepatch backup");
is(recorded(), "true", "--apply set the flag in config");

# --- second run is a no-op ------------------------------------------------
is(run(), 0, "a second run reports nothing to do");

# --- the flag makes a deliberate operator re-grant survive later runs -----
NMISNG::Util::writeHashtoFile(file => $livefile, conf => $conf, data => do {
	my $h = NMISNG::Util::readFiletoHash(file => $livefile, conf => $conf);
	$h->{$rights[0]}->{level1} = "1"; $h });
is(run(), 0, "run after an operator re-grant exits 0");
is(live_val($rights[0], 1), "1",
	 "a re-grant is not corrected again while the flag is set");

# --- --force overrides the flag ------------------------------------------
is(run("--force", "--apply"), 0, "--force --apply exits 0");
is(live_val($rights[0], 1), $defaults->{$rights[0]}->{level1},
	 "--force corrects a right again despite the flag");
is(recorded(), "true", "--force leaves the flag set");

# --- a record written by the previous release counts as set ---------------
# that release stored a comma-separated list of corrected rights, not a token.
{
	seed_live();
	NMISNG::Util::writeHashtoFile(file => $localcfg, conf => $conf, data => {
		id => { cluster_id => "test-cluster-id" },
		authentication => { access_table_hardened => join(",", @rights) } });
	is(run("--apply"), 0, "--apply exits 0 with an old-style record present");
	is(live_val($rights[0], 1), "1",
		 "an old-style record counts as set, so the live table is untouched");
}

# --- a re-run must not clobber the pristine backup ------------------------
# the installer's execPrint retries a failing command six times, and -b would
# overwrite .prepatch with an already patched file on the second attempt.
{
	seed_live();
	my $pre = "$livefile.prepatch";
	unlink $pre;
	is(run("--apply"), 0, "first --apply exits 0");
	ok(-e $pre, "the first --apply wrote a .prepatch");
	my $original = NMISNG::Util::readFiletoHash(file => $pre, conf => $conf);
	is($original->{$rights[0]}->{level1}, "1", "the backup holds the pre-fix value");

	# put the wrong value back and run again, as a retry or a later run would
	my $h = NMISNG::Util::readFiletoHash(file => $livefile, conf => $conf);
	$h->{$rights[0]}->{level1} = "1";
	NMISNG::Util::writeHashtoFile(file => $livefile, data => $h, conf => $conf);
	is(run("--force", "--apply"), 0, "a second --apply exits 0");
	my $after = NMISNG::Util::readFiletoHash(file => $pre, conf => $conf);
	is($after->{$rights[0]}->{level1}, "1",
		 "the pristine .prepatch survived the second run");
}

# --- exit codes match what --help promises --------------------------------
is(run("--help"), 0, "--help exits 0");
is(run("--nosuchoption"), 2, "an unknown option exits 2");

# --- with no conf/Config.nmis overlay, correct but do not create one ------
# the overlay only appears as a side effect of loadConfTable persisting a
# cluster_id, which can fail, so the record must not depend on it existing.
seed_live();
unlink $localcfg;
is(run("--apply"), 0, "--apply exits 0 with no conf/Config.nmis overlay");
is(live_val($rights[0], 1), $defaults->{$rights[0]}->{level1},
	 "the Access corrections still land with no overlay");

# --- the opt-out flag means the matrix is load-bearing, so hands off ------
seed_live();
$cfg->{authentication}{auth_lock_sensitive_tables} = "false";
NMISNG::Util::writeHashtoFile(file => "$dir/conf-default/Config.nmis",
															data => $cfg, conf => $conf);
is(run("--apply"), 0, "exits 0 when auth_lock_sensitive_tables is false");
is(live_val($rights[0], 1), "1",
	 "the live matrix is untouched when the operator has opted out");
$cfg->{authentication}{auth_lock_sensitive_tables} = "true";
NMISNG::Util::writeHashtoFile(file => "$dir/conf-default/Config.nmis",
															data => $cfg, conf => $conf);

# --- no live file means the install already reads conf-default ------------
unlink $livefile;
is(run("--apply"), 0, "exits 0 when there is no live conf/Access.nmis");
ok(!-e $livefile, "no live conf/Access.nmis was created");

done_testing;
