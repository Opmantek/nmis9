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
# Align the live conf/Access.nmis with conf-default for the rights NMISNG::Auth
# forces admin-only (OMK-12707, OMK-12823). Reports by default, writes only with
# --apply. See --help.

use FindBin;
use lib "$FindBin::RealBin/../lib";

use strict;
use warnings;

use File::Basename;
use Getopt::Long qw(GetOptions);

use NMISNG::Util;
use NMISNG::Auth;

our $VERSION = "1.1.0";

# set once the live table has been aligned. Config.nmis is layered, so a value
# written at layer 2 (conf/) survives upgrades and a var/ rebuild.
my $RECORD_KEY  = "access_table_hardened";
my $RECORD_PATH = "/authentication/$RECORD_KEY";

my ($apply, $force, $wanthelp, $quiet);
my $badopts = !GetOptions("apply" => \$apply, "force" => \$force,
													"quiet" => \$quiet, "help" => \$wanthelp);

my $me = basename($0);
if ($wanthelp or $badopts)
{
	my $out = $badopts ? \*STDERR : \*STDOUT;
	print $out "Usage: $me [--apply] [--force] [--quiet]

Aligns conf/Access.nmis with conf-default/Access.nmis for the rights that
NMISNG::Auth treats as administrator-only. Reports and changes nothing unless
--apply is given.

  --apply   write the corrections (backs up to conf/Access.nmis.prepatch)
  --force   run again even when config $RECORD_KEY is already set
  --quiet   only report problems

Sets config $RECORD_KEY once the corrections are applied, and exits
early on every later run, so a deliberate operator re-grant survives. --force
runs it again regardless. A right added to the guard in a later release is
therefore NOT picked up automatically; clear the flag or use --force.

Does nothing when config auth_lock_sensitive_tables is set to an exact false
token: the operator has chosen matrix-driven behaviour and the live matrix is
then load-bearing.

Exit: 0 nothing to do or applied, 1 corrections pending (report mode),
      2 error.

From an installer hook, always pass --apply. Report mode exits 1 when there is
work to do, and execPrint treats non-zero as failure and retries six times.

  execPrint \$TARGETDIR/admin/harden_access_table.pl --apply

No CLEANSLATE guard is needed: a fresh install writes conf/Access.nmis from the
corrected conf-default, so there is nothing to correct and this exits 0.\n";
	exit($badopts ? 2 : 0);
}

# every fatal path exits 2, as the usage above promises
sub fail { print STDERR "$me: @_\n"; exit 2 }

# system() returns a wait status, not an exit code
sub rcinfo
{
	my $rc = shift;
	return "not executed: $!" if ($rc == -1);
	return "killed by signal ".($rc & 127) if ($rc & 127);
	return "exit ".($rc >> 8);
}

sub say_it { print @_ unless $quiet }

my $C = NMISNG::Util::loadConfTable();
fail("cannot load configuration") if (ref($C) ne "HASH");

my $confdir    = $C->{'<nmis_conf>'};
fail("<nmis_conf> is not set") if (!$confdir);
my $defaultdir = $C->{'<nmis_conf_default>'} || "$FindBin::RealBin/../conf-default";

my $livefile = "$confdir/Access.nmis";
my $deffile  = "$defaultdir/Access.nmis";
my $conffile = "$confdir/Config.nmis";

# one-shot. The flag is set once the corrections are applied, so a later
# deliberate operator re-grant is not undone. An older comma-separated value
# from a previous release also counts as set.
my $flag = $C->{$RECORD_KEY} // "";
if (!$force and $flag =~ /\S/ and $flag !~ /^\s*(false|no|0)\s*$/i)
{
	say_it "$me: config $RECORD_KEY is set, nothing to do. Use --force to run again.\n";
	exit 0;
}

# no live file means loadTable falls back to conf-default, which is correct
# already. Creating one here would freeze this install at today's defaults.
if (!-f $livefile)
{
	say_it "$me: no $livefile, this install reads conf-default directly. Nothing to do.\n";
	exit 0;
}
fail("cannot read $deffile") if (!-r $deffile);

# the operator deferred these rights to the matrix, so it is load-bearing. Call
# the guard's own predicate rather than re-implementing its token rules.
my $au = NMISNG::Auth->new(conf => $C);
if (!$au->lock_sensitive_tables)
{
	print "$me: auth_lock_sensitive_tables is off, the Access matrix is in force.\n"
			."       Leaving conf/Access.nmis untouched.\n";
	exit 0;
}

my $live = NMISNG::Util::readFiletoHash(file => $livefile, conf => {});
my $def  = NMISNG::Util::readFiletoHash(file => $deffile,  conf => {});
fail("$livefile did not parse as a hash") if (ref($live) ne "HASH");
fail("$deffile did not parse as a hash")  if (ref($def)  ne "HASH");

my (@patches, @report, @missing, @resolved);
for my $right (NMISNG::Auth::admin_only_rights())
{
	if (ref($def->{$right}) ne "HASH")
	{
		push @missing, "$right: not in $deffile, no target value to copy";
		next;
	}
	if (ref($live->{$right}) ne "HASH")
	{
		# absent from the live table reads as undef, i.e. denied. Adding it is
		# updateconfig.pl's job, not ours.
		push @missing, "$right: not in $livefile, denied by absence, left for updateconfig.pl";
		next;
	}
	push @resolved, $right;
	for my $level (0..5)
	{
		my $want = $def->{$right}->{"level$level"};
		my $have = $live->{$right}->{"level$level"};
		next if (!defined($want) or !defined($have) or $want eq $have);
		push @patches, "/$right/level$level=$want";
		push @report, sprintf("  %-24s level%s: %s -> %s", $right, $level, $have, $want);
	}
}

print "$me: $_\n" for @missing;

if (!@patches)
{
	say_it scalar(@resolved)
			? "$me: the ".scalar(@resolved)." right(s) checked already match conf-default.\n"
			: "$me: nothing checked, every guarded right is absent from the live table.\n";
	record_hardened() if ($apply);
	exit 0;
}

print "$me: ".scalar(@patches)." value(s) differ from conf-default:\n";
print "$_\n" for @report;

if (!$apply)
{
	print "\n$me: report only. Re-run with --apply to write these.\n";
	exit 1;
}

my $patcher = "$FindBin::RealBin/patch_config.pl";
fail("$patcher not found") if (!-x $patcher);

# execPrint retries a failing command, and -b would overwrite the pristine
# backup with an already patched file on the second attempt. Keep the first.
my @backup = (-e "$livefile.prepatch") ? () : ("-b");
print "$me: keeping the existing $livefile.prepatch, it predates this run\n"
		if (!@backup);

my $rc = system($patcher, @backup, $livefile, @patches);
fail("$patcher failed on $livefile (".rcinfo($rc).")") if ($rc != 0);

# verify rather than trust: re-read and confirm every target value landed
my $after = NMISNG::Util::readFiletoHash(file => $livefile, conf => {});
my @unlanded;
for my $p (@patches)
{
	my ($right, $level, $want) = $p =~ m{^/([^/]+)/level(\d)=(.*)$};
	my $now = $after->{$right}->{"level$level"};
	push @unlanded, $p if (!defined($now) or $now ne $want);
}
if (@unlanded)
{
	print "$me: FAILED, these did not land: ".join(", ", @unlanded)."\n";
	print "$me: the original is at $livefile.prepatch\n";
	exit 2;
}

print "$me: applied ".scalar(@patches)." correction(s). Backup: $livefile.prepatch\n";
print "$me: these rights are administrator-only from this release. Setting config\n"
		 ."       auth_lock_sensitive_tables to false defers them to the matrix again,\n"
		 ."       which reinstates the privilege escalation they close.\n";
record_hardened();
exit 0;

# mark the table hardened, so later runs exit early and a deliberate operator
# re-grant is not undone.
sub record_hardened
{
	# never create conf/Config.nmis. It is an overlay on the layered default, and
	# an install without one has no local config at all, so its Access table is
	# the shipped one and there is nothing for us to have corrected.
	if (!-f $conffile)
	{
		print "$me: no $conffile, config $RECORD_KEY was not set.\n"
				 ."       The Access corrections stand, but a later run will redo them.\n";
		return;
	}

	my $rc = system("$FindBin::RealBin/patch_config.pl", "-b", $conffile,
									"$RECORD_PATH=true");
	# verify rather than trust: re-read and confirm the flag landed
	my $written = NMISNG::Util::readFiletoHash(file => $conffile, conf => {});
	my $got = (ref($written) eq "HASH")
			? ($written->{authentication}->{$RECORD_KEY} // "") : "";
	if ($rc != 0 or $got ne "true")
	{
		print "$me: could not set config $RECORD_KEY in $conffile (".rcinfo($rc).").\n"
				 ."       The Access corrections stand, but a later run will redo them.\n";
		return;
	}
	say_it "$me: set config $RECORD_KEY, later runs will exit early\n";
}
