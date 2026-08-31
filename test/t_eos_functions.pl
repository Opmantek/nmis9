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
# OMK-12927 / OMK-12695: function-level coverage for the pair the restored CLI
# dispatch now reaches - NMISNG::Util::enableEOS and disableEOS - and for the
# two verifyNMISEncryption warts that only become reachable once operators can
# call them.
#
# Phases:
#   1  round trip: enableEOS encrypts every plaintext PasswordFields entry in
#      the config and turns the flag on; disableEOS puts both back.
#   2  wart A: disableEOS over a '!!' value it cannot decrypt must report
#      failure. decrypt fails closed by returning the stored value UNCHANGED
#      (OMK-12827 Slice B), so an undecryptable field survives the pass still
#      carrying '!!' - and before this fix nothing looked at that, so
#      verifyNMISEncryption returned "no changes needed" and disableEOS
#      announced "Encryption was successfully disabled" over ciphertext it had
#      just proved it could not read.
#   3  wart B: with encryption ON, a field that does NOT encrypt must not count
#      as a change. encrypt also fails closed by returning its input unchanged,
#      and the old code set $changed regardless - so a crypto failure rewrote
#      the config with the same bytes AND dropped a plaintext NMIS-<epoch>
#      backup of every secret into /usr/local/etc/firstwave, protecting nothing
#      while creating a second copy of the cleartext.
#
# Root-gated, following the t_masterkey_provision.t precedent: enableEOS and
# disableEOS refuse a non-root caller outright, so a non-root run asserts that
# refusal instead of skipping.
#
# Isolation. Three things keep this test off the real installation:
#   NMIS_MASTER_KEY_FILE - a key in a private temp dir. _resolve_seed never
#       CREATES a key at a non-default path, so the file is written here first.
#       The shipped /usr/local/etc/firstwave/master.key is never read, created
#       or replaced.
#   NMIS_NMIS_LOGS - a temp log directory, so nothing here appends to the real
#       nmis.log (and so phase 2 and 3 can read back what was logged).
#   conf/Config.nmis is backed up with its bytes, mode and ownership and
#       restored in END, per docs/CGI_TESTING.md. enableEOS/disableEOS rewrite
#       that file for real; that is the behaviour under test, so it cannot be
#       spied away.
#
# Every phase reseeds the config from a pristine copy taken before anything
# ran, with two deliberate removals:
#   - every PasswordFields.nmis entry, so each phase controls exactly which
#     secrets are in play and an unrelated field left over from the checkout
#     cannot decide $changed for it;
#   - every key currently sourced from conf.d (layer 3) or the environment
#     (layer 4). writeConfData refuses to write such a key when the value it
#     is handed differs from the effective one, and refuses the WHOLE file at
#     that point - which is the CI-only trap documented in
#     t_cgi_config_protected_keys.t (the pipeline exports NMIS_DB_USERNAME,
#     NMIS_DB_PASSWORD and NMIS_DB_AUTH_SOURCE). Left in, enableEOS's own
#     config write would silently do nothing there and every assertion below
#     would be measuring the wrong thing.
#
# Note on asserting the flag: writeConfData does not persist a key whose value
# equals the shipped default, so after disableEOS the file carries no
# global_enable_password_encryption line at all - it falls back to the default.
# The assertions are therefore on the EFFECTIVE value from a reloaded config,
# which stays correct after OMK-12695 flips that default to 'true'.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use File::Copy qw(copy);
use Test::More;

my ($KEYDIR, $KEYFILE, $LOGDIR);
BEGIN {
	$KEYDIR  = File::Temp::tempdir("omk12927-eosfn-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	$KEYFILE = "$KEYDIR/master.key";
	$LOGDIR  = "$KEYDIR/logs";
	mkdir($LOGDIR);
	$ENV{NMIS_MASTER_KEY_FILE} = $KEYFILE;
	$ENV{NMIS_NMIS_LOGS}       = $LOGDIR;
}

BEGIN {
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
		eval "require $m; 1"
			or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG::Util;
use NMISNG::Log;

{
	open(my $kh, '>', $KEYFILE) or BAIL_OUT("cannot create the test master key: $!");
	print $kh ("K" x 256) . "\n";
	close $kh;
	chmod(0400, $KEYFILE);
}

my $C         = NMISNG::Util::loadConfTable();
my $CONF_FILE = $C->{configfile};
my $CONF_BAK  = "$CONF_FILE.bak";

# verifyNMISEncryption writes its plaintext backup to this hardcoded directory
# (root-only, 0400) regardless of master_key_file. Phase 3 asserts that no such
# file appears, which is only meaningful if the directory exists; create it if
# it does not, and take it away again if we were the ones who made it. Declared
# up here so the END block below can never see it undefined, whatever exits
# first.
my $SEEDDIR = '/usr/local/etc/firstwave';
my $MADE_SEEDDIR = 0;
my %SEEDDIR_PREEXISTING;

# ---- backup / restore, bytes + mode + owner ---------------------------------
# writeConfData copies the live file to <file>.bak before every write, so both
# have to be captured and both restored, including the "was absent" case. Mode
# and ownership matter as much as content: NMIS ships its config group-writable
# on purpose so httpd (a member of the nmis group) can edit it through the GUI,
# and a rewrite by this root process would otherwise leave root:root 0644 behind.
sub save_file
{
	my ($orig, $suffix) = @_;
	return { absent => 1 } if (!-f $orig);
	my @st = CORE::stat($orig);
	my $to = "$orig$suffix";
	if (!copy($orig, $to))
	{
		# A non-root run cannot write into conf/ at all - which is also why it
		# cannot damage the config, so there is nothing to protect and the run
		# continues to its one assertion. As root a failed backup is fatal: the
		# phases below rewrite this file. Plain undef here (as opposed to the
		# {absent=>1} case above) means the file DID exist but could not be
		# copied, so restore_file must never delete it.
		BAIL_OUT("cannot back up $orig: $!") if ($> == 0);
		diag("no backup of $orig taken: $! (running as uid $>, which cannot write it either)");
		return undef;
	}
	return { copy => $to, mode => ($st[2] & 07777), uid => $st[4], gid => $st[5] };
}

sub restore_file
{
	my ($saved, $orig) = @_;
	return if (!$saved);
	if ($saved->{absent})
	{
		# nothing existed before this run - remove whatever the test created,
		# so a test-only conf/Config.nmis (or its .bak) is never left behind.
		unlink $orig if (-f $orig);
		return;
	}
	return if (!-f $saved->{copy});
	# a failed restore leaves the operator's config as this test rewrote it, so
	# it must never be silent, even in END where nothing can be asserted
	copy($saved->{copy}, $orig)
		or diag("RESTORE FAILED: could not copy $saved->{copy} back to $orig: $!");
	chmod($saved->{mode}, $orig);
	chown($saved->{uid}, $saved->{gid}, $orig);
	unlink $saved->{copy};
}

# Taken BEFORE the non-root branch below: enableEOS's first act is its root
# check, but nothing in this file may depend on that ordering to keep the
# operator's config safe.
my $CONF_SAVED = save_file($CONF_FILE, ".t12927eosbak");
my $BAK_SAVED  = save_file($CONF_BAK, ".t12927eosbak");

if (!-d $SEEDDIR)
{
	$MADE_SEEDDIR = mkdir($SEEDDIR, 0700) ? 1 : 0;
}
%SEEDDIR_PREEXISTING = map { $_ => 1 } glob("$SEEDDIR/NMIS-*");

# Every NMIS-<epoch> dump this run has made so far. Phase 1's enableEOS writes
# one legitimately, so a phase-3 measurement has to start from a clean slate
# rather than from the state at process start.
sub our_dumps { return grep { !$SEEDDIR_PREEXISTING{$_} } glob("$SEEDDIR/NMIS-*"); }
sub clear_dumps { unlink(our_dumps()); }

END {
	restore_file($CONF_SAVED, $CONF_FILE);
	restore_file($BAK_SAVED, $CONF_BAK);
	# restore_file's {absent=>1} branch above already covers the ordinary
	# "there was no .bak before us" case. This is only for the rarer path
	# where save_file's backup copy itself failed (undef, non-root) - it never
	# fires for a real pre-existing .bak, per the reasoning in save_file.
	unlink $CONF_BAK if (!$BAK_SAVED && -f $CONF_BAK);
	# never leave a plaintext secrets dump behind, whichever phase made it
	unlink(grep { !$SEEDDIR_PREEXISTING{$_} } glob("$SEEDDIR/NMIS-*"));
	rmdir($SEEDDIR) if ($MADE_SEEDDIR);
}

# ---- non-root: assert the refusal, do not skip ------------------------------
# Placed after the backup and the END block, so a non-root run that somehow
# does write leaves nothing behind.
if ($> != 0)
{
	# disableEOS returns 1 ("already disabled") before it ever reaches its root
	# check when the flag is off, so only enableEOS can be asserted here without
	# first writing to the config - which a non-root run may not be able to do.
	#
	# enableEOS has the mirror-image early return: it answers 1 ("already
	# enabled") before ITS root check when the flag is already on. Since
	# OMK-12695 made encryption the shipped default, that is what a stock
	# config now gives, and this assertion would invert on every non-root run.
	# The flag is therefore pinned OFF here explicitly. This branch is about
	# the root refusal, not about the default.
	local $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'false';
	$NMISNG::Util::_config_cache_invalid = 1;
	my $cfg = NMISNG::Util::loadConfTable();
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 0,
		"non-root fixture: the flag is pinned off, so enableEOS reaches its root check");
	my $rc = NMISNG::Util::enableEOS();
	is($rc, 0, "enableEOS refuses a non-root caller");
	diag("running as uid $>; the enable/disable behaviour itself is root-only "
			 . "(it stops and starts every NMIS and OMK daemon)");
	done_testing();
	exit 0;
}

# ---- fixture helpers --------------------------------------------------------

# the PasswordFields rows, as (section, keyword) pairs. Only the two-part rows
# can appear in Config.nmis' two-level hash; the deeper rows exist for OMK
# products and never match here.
sub password_fields
{
	my $file = $C->{'<nmis_base>'} . "/conf-default/PasswordFields.nmis";
	open(my $fh, '<', $file) or BAIL_OUT("cannot read $file: $!");
	my @rows;
	while (my $line = <$fh>)
	{
		chomp $line;
		next if ($line eq '');
		my @parts = split(/:/, $line);
		push @rows, \@parts if (scalar(@parts) == 2);
	}
	close $fh;
	return @rows;
}

my @PWFIELDS = password_fields();
cmp_ok(scalar(@PWFIELDS), '>=', 5, "PasswordFields.nmis lists the config-level secret fields");

# a pristine copy of the checkout's local config, taken before anything wrote
my $PRISTINE;
{
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	$PRISTINE = $local;
}

# Writes conf/Config.nmis directly (NOT through writeConfData, which would
# apply the very filtering some phases need to observe) and reloads.
# %fields: 'section:keyword' => value, plus 'flag' => true/false.
sub seed_config
{
	my (%fields) = @_;
	my $flag = delete $fields{flag} // 'false';

	my %seed;
	for my $sect (keys %$PRISTINE)
	{
		next unless ref($PRISTINE->{$sect}) eq 'HASH';
		$seed{$sect}{$_} = $PRISTINE->{$sect}{$_} for (keys %{$PRISTINE->{$sect}});
	}
	# no leftover secrets: each phase states exactly which fields are in play
	delete $seed{$_->[0]}{$_->[1]} for (@PWFIELDS);
	# no key that conf.d or the environment currently owns; see the header
	my $sources = NMISNG::Util::getConfigSources();
	for my $key (keys %$sources)
	{
		my $layer = $sources->{$key}{layer};
		next unless (defined($layer) && ($layer == 3 || $layer == 4));
		my $section = $sources->{$key}{section};
		delete $seed{$section}{$key} if (defined($section) && ref($seed{$section}) eq 'HASH');
	}

	$seed{globals}{global_enable_password_encryption} = $flag;
	for my $spec (keys %fields)
	{
		my ($sect, $key) = split(/:/, $spec, 2);
		$seed{$sect}{$key} = $fields{$spec};
	}

	my $err = NMISNG::Util::writeHashtoFile(file => $CONF_FILE, data => \%seed);
	BAIL_OUT("cannot seed $CONF_FILE: $err") if ($err);
	return reload();
}

sub reload
{
	$NMISNG::Util::_config_cache_invalid = 1;
	my $cfg = NMISNG::Util::loadConfTable();
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	return ($cfg, $local);
}

sub stored
{
	my ($local, $spec) = @_;
	my ($sect, $key) = split(/:/, $spec, 2);
	return undef if (ref($local->{$sect}) ne 'HASH');
	return $local->{$sect}{$key};
}

# enableEOS/disableEOS stop and start every NMIS and OMK daemon on the box.
# Neither is what this test is about, and doing it for real would take the
# machine down, so both become no-op successes.
{
	no warnings 'redefine';
	*NMISNG::Util::shutdownAllDaemons = sub { return 1; };
	*NMISNG::Util::startAllDaemons    = sub { return 1; };
}

my $LOGFILE = "$LOGDIR/nmis.log";
sub read_log
{
	return '' if (!-f $LOGFILE);
	open(my $fh, '<', $LOGFILE) or return '';
	local $/;
	my $t = <$fh>;
	close $fh;
	return $t // '';
}
sub reset_log { unlink($LOGFILE) if (-f $LOGFILE); }

# ---- phase 1: the round trip ------------------------------------------------
my $MAILPW = 'eosRoundTripMail1';
my $ROPW   = 'eosRoundTripComm2';

{
	my ($cfg, $local) = seed_config(flag => 'false',
		'email:mail_password'      => $MAILPW,
		'system:default_communityRO' => $ROPW);
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 0,
		"phase 1 fixture: encryption starts disabled");
	is(stored($local, 'email:mail_password'), $MAILPW,
		"phase 1 fixture: mail_password is stored in plaintext");

	reset_log();
	my $rc = NMISNG::Util::enableEOS();
	is($rc, 1, "enableEOS reports success");

	($cfg, $local) = reload();
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 1,
		"the flag is on afterwards");
	for my $spec ('email:mail_password', 'system:default_communityRO')
	{
		like(stored($local, $spec), qr/^!!/, "$spec is ciphertext at rest");
	}
	is(NMISNG::Util::decrypt(stored($local, 'email:mail_password')), $MAILPW,
		"and the stored mail_password still decrypts to what went in");
	is(NMISNG::Util::decrypt(stored($local, 'system:default_communityRO')), $ROPW,
		"and so does default_communityRO");

	reset_log();
	$rc = NMISNG::Util::disableEOS();
	is($rc, 1, "disableEOS reports success");

	($cfg, $local) = reload();
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 0,
		"the flag is off afterwards");
	is(stored($local, 'email:mail_password'), $MAILPW,
		"mail_password is plaintext again, byte for byte");
	is(stored($local, 'system:default_communityRO'), $ROPW,
		"and so is default_communityRO");
}

# ---- phase 2 (wart A): an undecryptable survivor is a failure ---------------
# A '!!' value that cannot be decrypted with the current master key is exactly
# what an operator hits after a key loss or a key swap, which is also the
# moment they are most likely to reach for disable-eos.
{
	my $SURVIVOR = '!!' . ('deadbeef' x 8);
	my ($cfg, $local) = seed_config(flag => 'true',
		'email:mail_password' => $SURVIVOR);
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 1,
		"phase 2 fixture: encryption starts enabled");
	is(NMISNG::Util::decrypt($SURVIVOR), $SURVIVOR,
		"phase 2 fixture: the seeded value really is undecryptable "
		. "(decrypt fails closed and hands it back unchanged)");

	reset_log();
	my $rc = NMISNG::Util::disableEOS();
	is($rc, 0, "disableEOS reports FAILURE when a '!!' field could not be decrypted");
	my $phase2log = read_log();
	like($phase2log, qr/could not be decrypted|still encrypted|undecryptable/i,
		"and the log says so");
	# by NAME, not just by count: an operator reading this line has to know
	# which secret to re-enter, and a bare count does not tell them
	like($phase2log, qr/\bmail_password\b/,
		"naming the field that survived");
	unlike($phase2log, qr/\Q$SURVIVOR\E/,
		"without echoing the stored value");

	(undef, $local) = reload();
	is(stored($local, 'email:mail_password'), $SURVIVOR,
		"the undecryptable value is left exactly as it was, not mangled");
}

# ---- phase 2b (PR 76 Critical): a refused config write is not success -------
# The shipped container's steady state: compose sets NMIS_DB_PASSWORD, so
# database/db_password is layer 4 and its stored form diverges from the
# effective (environment) value. writeConfData refuses the WHOLE file in that
# state, which drops the 'false' flag write disableEOS makes. Before this fix
# the write return was discarded: verifyNMISEncryption re-read a still-'true'
# config, found nothing to change on the enabled pass, returned 0, and
# disableEOS announced "successfully disabled" over a flag that never moved. It
# must now report FAILURE, surface the refusal, and leave the flag on.
#
# NMIS_DB_PASSWORD is set for the duration of this phase only, then removed.
# disableEOS never opens a database connection, so a value that would not
# authenticate is harmless here.
{
	local $ENV{NMIS_DB_PASSWORD} = 'phase2b-env-value-differs';
	$NMISNG::Util::_config_cache_invalid = 1;

	# db_password is a PasswordFields entry and, with the env var set, layer 4,
	# so seed_config drops it; it is re-added explicitly AFTER that drop with a
	# stored value that differs from the environment's - the divergence
	# writeConfData refuses on.
	my ($cfg, $local) = seed_config(flag => 'true',
		'database:db_password' => 'phase2b-stored-value-differs');
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 1,
		"phase 2b fixture: encryption starts enabled");
	my $src = NMISNG::Util::getConfigSources()->{db_password};
	is((ref($src) eq 'HASH' ? $src->{layer} : undef), 4,
		"phase 2b fixture: db_password is environment-managed (layer 4)");
	isnt(stored($local, 'database:db_password'), $cfg->{db_password},
		"phase 2b fixture: the stored db_password diverges from the effective value");

	reset_log();
	my $rc = NMISNG::Util::disableEOS();
	is($rc, 0, "disableEOS reports FAILURE when the config write is refused");

	my $log = read_log();
	like($log, qr/refused|managed by|could not be disabled/i,
		"and the refusal is surfaced in the log");
	unlike($log, qr/successfully disabled/i,
		"disableEOS does NOT claim success on a refused write");
	unlike($log, qr/\Qphase2b-stored-value-differs\E|\Qphase2b-env-value-differs\E/,
		"and no secret value is echoed to the log");

	(my $cfg2, $local) = reload();
	is(NMISNG::Util::getbool($cfg2->{global_enable_password_encryption}), 1,
		"the encryption flag is unchanged (still enabled) after the refused write");
	is(stored($local, 'database:db_password'), 'phase2b-stored-value-differs',
		"and the stored db_password is untouched");
}
$NMISNG::Util::_config_cache_invalid = 1;

# ---- phase 3 (wart B): a field that will not encrypt is not a change --------
# encrypt() refuses a value longer than 999 characters (the three-digit length
# prefix cannot describe it) and fails closed by returning it unchanged. That
# is a real, reachable encrypt failure that survives testEncryption's self-test
# passing, so it drives the wart without stubbing the crypto out.
{
	my $LONGPW = 'x' x 1000;
	my ($cfg) = seed_config(flag => 'true', 'email:mail_password' => $LONGPW);
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 1,
		"phase 3 fixture: encryption is enabled");
	is(NMISNG::Util::encrypt($LONGPW), $LONGPW,
		"phase 3 fixture: this value really does fail to encrypt, unchanged");

	my $logger = NMISNG::Log->new(level => 'debug', path => $LOGFILE);

	my @writes;
	my $real_write = \&NMISNG::Util::writeConfData;
	{
		no warnings 'redefine';
		*NMISNG::Util::writeConfData = sub { push @writes, 1; return; };
	}

	reset_log();
	clear_dumps();          # phase 1's enableEOS legitimately wrote one
	@writes = ();
	my $rc = NMISNG::Util::verifyNMISEncryption(log => $logger);
	is($rc, 0, "verifyNMISEncryption still returns 0 (it ran; nothing to change)");
	is(scalar(@writes), 0,
		"a field that did not encrypt triggers NO config rewrite");
	is(scalar(our_dumps()), 0,
		"and NO plaintext NMIS-<epoch> backup of the secrets is written");

	# positive control: without it, "no write happened" would also pass if the
	# enabled branch had simply stopped working.
	seed_config(flag => 'true', 'email:mail_password' => 'eosShortEnough3');
	reset_log();
	clear_dumps();
	@writes = ();
	$rc = NMISNG::Util::verifyNMISEncryption(log => $logger);
	is($rc, 0, "positive control: verifyNMISEncryption returns 0");
	is(scalar(@writes), 1,
		"a field that DID encrypt triggers exactly one config rewrite");
	is(scalar(our_dumps()), 1,
		"and one plaintext backup of the protected fields is written");
	clear_dumps();

	{
		no warnings 'redefine';
		*NMISNG::Util::writeConfData = $real_write;
	}
}

done_testing();
