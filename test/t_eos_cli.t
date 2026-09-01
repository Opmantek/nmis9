#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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
#
# OMK-12927: the four Encryption-of-Secrets actions were commented out of
# bin/nmis-cli (dispatch, --usage list and --help text) while the Util helpers
# behind them stayed live. OMK-12695 makes encryption the shipped default, and
# an existing site's only supported way in or out of that state is
# 'nmis-cli act=enable-eos' / 'act=disable-eos' - so the dispatch has to be
# reachable, and something has to fail when it is not.
#
# Reachability is proved by DRIVING THE REAL bin/nmis-cli, never by reading it
# as text. With the dispatch commented out every act= below falls through the
# whole chain to the "Unrecognized action!" branch at the very end of the file,
# which is what makes each case red today.
#
# Cases:
#   A1  act=enable-eos  as a NON-root user -> the root-required refusal
#   A2  act=disable-eos as a NON-root user -> the root-required refusal
#   B   --help  lists all four acts
#   C   --usage lists all four acts
#   D1  act=check-eos with encryption off -> "Encryption is disabled.", rc 0
#   D2  act=check-eos with encryption on  -> "Encryption is enabled.",  rc 1
#   E   act=is-eos-available reaches the checker rather than the fall-through
#   F   the whole run left conf/Config.nmis byte-identical
#
# A1/A2 are run as a non-root user on purpose. enable-eos and disable-eos are
# dispatched ABOVE the database connection (deliberately: enableEOS stops the
# daemons, and it must not need mongo to do it), and the first thing each does
# is refuse a non-root caller. That refusal is therefore the cheapest proof the
# dispatch is live, it needs no mongo, and it cannot be reached accidentally -
# no other branch of nmis-cli prints it. Running them as ROOT is not an option
# for a test: they would stop every NMIS and OMK daemon on the box and rewrite
# the live config. The root path is covered at function level by
# test/t_eos_functions.pl instead.
#
# D1/D2 pin the outcome to an explicit NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION
# override rather than to the shipped default, so these two cases keep meaning
# the same thing after OMK-12695 flips that default to 'true'. check-eos and
# is-eos-available are dispatched BELOW the database connection, so unlike
# A1/A2 they need a reachable mongo - the same requirement the rest of the
# suite already has.
#
# Two more env overrides exist only to keep case F honest:
#   NMIS_MASTER_KEY_FILE - a key in a private temp dir, so no invocation here
#       can create, read or replace the shipped /usr/local/etc/firstwave key.
#   NMIS_DB_PASSWORD - with encryption enabled (D2), every database connect
#       calls decrypt($C->{db_password}, 'database', 'db_password'), whose
#       up-migration writes the ciphertext straight back into conf/Config.nmis.
#       Promoting db_password to a layer-4 ENV override makes writeConfData
#       refuse that write (its "managed by ENV:..." guard), so the child
#       processes cannot mutate the checkout's config. The value is the
#       effective one, read out of the loaded config and never printed.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Digest::MD5 ();
use Test::More;

use NMISNG::Util;

my $CLI = "$FindBin::Bin/../bin/nmis-cli";
ok(-f $CLI, "bin/nmis-cli exists") or BAIL_OUT("$CLI missing");

my $C = NMISNG::Util::loadConfTable();

# a private master key, created here: _resolve_seed refuses to CREATE a key at
# a non-default path, so it has to exist before the first crypto call.
my $keydir = File::Temp::tempdir("omk12927-eoscli-XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $KEYFILE = "$keydir/master.key";
{
	open(my $kh, '>', $KEYFILE) or BAIL_OUT("cannot create the test master key: $!");
	print $kh ("K" x 256) . "\n";
	close $kh;
	chmod(0400, $KEYFILE);
}

# The effective database password, resolved HERE, while the ambient master key
# is still in force. Since OMK-12695 made encryption the shipped default, the
# stored db_password may already be '!!' ciphertext under the installation's
# key, and every child below runs with the EPHEMERAL key above, which cannot
# read it - handing the children the raw stored value would fail authentication
# on every act dispatched below the database connection. decrypt is called with
# no section and no keyword on purpose: that is the form that performs no
# migration write. Never printed, never asserted on.
my $DB_PASSWORD = (defined($C->{db_password}) && $C->{db_password} ne '')
	? NMISNG::Util::decrypt($C->{db_password}) : undef;

my $CONF_FILE = $C->{configfile};
my $conf_md5_before = file_md5($CONF_FILE);

sub file_md5
{
	my ($f) = @_;
	return 'ABSENT' if (!-f $f);
	open(my $fh, '<', $f) or return "UNREADABLE:$!";
	my $d = Digest::MD5->new->addfile($fh)->hexdigest;
	close $fh;
	return $d;
}

# the non-root identity for A1/A2. When the test itself is not root (a bare
# host run) there is nothing to drop to and the invocation is already non-root.
my $DROP_TO;
if ($> == 0)
{
	for my $cand (qw(nmis nobody))
	{
		if (defined(getpwnam($cand))) { $DROP_TO = $cand; last; }
	}
	BAIL_OUT("running as root but neither 'nmis' nor 'nobody' exists to drop to; "
			 . "cases A1/A2 must not run enable-eos/disable-eos as root")
			if (!defined $DROP_TO);
}

# Runs the real CLI and returns (combined output, exit code). %opt:
#   nonroot => 1   drop to $DROP_TO (no-op when already non-root)
#   flag    => ... value for NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION
sub run_cli
{
	my ($args, %opt) = @_;

	local $ENV{NMIS_MASTER_KEY_FILE} = $KEYFILE;
	# never printed, never asserted on; see the header
	local $ENV{NMIS_DB_PASSWORD} = $DB_PASSWORD if (defined $DB_PASSWORD);
	local $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = $opt{flag} if (defined $opt{flag});

	my $cmd = "perl '$CLI' $args";
	if ($opt{nonroot} && defined $DROP_TO)
	{
		# -p preserves the environment, which is how the overrides above reach
		# the dropped-to shell; su without it would discard every one of them.
		$cmd = "su -p -s /bin/sh $DROP_TO -c \"$cmd\"";
	}
	my $out = `$cmd 2>&1`;
	return ($out // '', $? >> 8);
}

my @ACTS = qw(check-eos disable-eos enable-eos is-eos-available);

# ---- A1/A2: the root-gated dispatches are reachable ------------------------
for my $act (qw(enable-eos disable-eos))
{
	my ($out, $rc) = run_cli("act=$act", nonroot => 1);
	like($out, qr/requires root privilege/i,
		"act=$act as a non-root user refuses with the root-required message");
	unlike($out, qr/Unrecognized action/,
		"act=$act is dispatched, not swallowed by the fall-through branch");
}

# ---- B: --help lists the acts ----------------------------------------------
{
	my ($out, $rc) = run_cli("--help");
	like($out, qr/ENCRYPTION OF SECRETS ACTIONS/,
		"--help renders the Encryption of Secrets section");
	like($out, qr/\bact=\Q$_\E\b/, "--help documents act=$_") for (@ACTS);
}

# ---- C: --usage lists the acts ---------------------------------------------
{
	my ($out, $rc) = run_cli("--usage");
	like($out, qr/\bact=\Q$_\E\b/, "--usage lists act=$_") for (@ACTS);
}

# ---- D1/D2: check-eos reports the configured state, either way -------------
{
	my ($out, $rc) = run_cli("act=check-eos", flag => 'false');
	like($out, qr/Encryption is disabled\./, "act=check-eos reports disabled when the flag is off");
	is($rc, 0, "and exits 0");
}
{
	my ($out, $rc) = run_cli("act=check-eos", flag => 'true');
	like($out, qr/Encryption is enabled\./, "act=check-eos reports enabled when the flag is on");
	is($rc, 1, "and exits 1");
}

# ---- E: is-eos-available reaches the checker -------------------------------
# Its verdict depends on which OMK products are installed beside NMIS, so the
# assertion is reachability (it ran, and it evaluated the NMIS version row),
# not the verdict.
{
	my ($out, $rc) = run_cli("act=is-eos-available", flag => 'false');
	unlike($out, qr/Unrecognized action/, "act=is-eos-available is dispatched");
	like($out, qr/Checking \.\.\./, "and runs the availability checker");
	# deliberately NOT asserting the 9.5.0 minimum-version row: that number is
	# a property of the compatibility table, not of the dispatch this case is
	# about, and pinning it here would make an unrelated table edit fail a CLI
	# reachability test.
}

# ---- F: nothing above was allowed to rewrite the checkout's config ---------
is(file_md5($CONF_FILE), $conf_md5_before,
	"conf/Config.nmis is byte-identical after every invocation");

done_testing();
