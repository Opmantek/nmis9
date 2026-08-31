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
# OMK-12928: decrypt() has a side effect nothing tested. When it is handed a
# section and a keyword - which means the value came out of conf/Config.nmis -
# it brings the STORED form of that field into line with the current encryption
# setting: encryption on and the field plaintext, write the ciphertext back;
# encryption off and the field '!!', write the plaintext back. Every existing
# crypto test either passes no section/keyword or replaces writeConfData with a
# spy, so the write itself - the thing that actually rewrites the operator's
# config - had no coverage at all.
#
# It stops being a corner case with OMK-12695. Encryption becomes the shipped
# default, and NMISNG::DB's connect calls
# decrypt($CONF->{db_password}, 'database', 'db_password'), so from then on the
# FIRST DATABASE CONNECT OF EVERY PROCESS - daemons, CLI runs, short-lived CGI
# children - attempts a config write.
#
# Cases (each reseeds conf/Config.nmis from a pristine copy):
#   U  up-migration:   encryption on, field stored plaintext ->
#                      decrypt returns the plaintext AND the file now holds
#                      '!!' ciphertext that decrypts back to it
#   D  down-migration: encryption off, field stored '!!' ->
#                      decrypt returns the plaintext AND the file now holds it
#   E  env-managed divergence: encryption on and the field owned by an
#                      environment variable -> decrypt returns the effective
#                      value, does not die, the file is byte-identical, and the
#                      refusal is LOGGED instead of vanishing
#
# Case E is the regression. writeConfData refuses to write a property that
# conf.d or the environment owns once the value it is handed differs from the
# effective one, and it refuses the WHOLE file at that point - the guard that
# bit t_cgi_config_protected_keys.t in CI, where the pipeline exports
# NMIS_DB_USERNAME, NMIS_DB_PASSWORD and NMIS_DB_AUTH_SOURCE. An ENV-managed
# db_password meets that guard on every single connect, because the ciphertext
# can never equal the plaintext the environment supplies.
#
# What that guard does is RETURN AN ERROR STRING, not croak - and decrypt threw
# the return value away, so the refusal was invisible: no log line, no
# migration, forever, on every connect. E pins all three halves of the correct
# behaviour: the decrypt result is unaffected (the fail-closed contract), the
# config is untouched, and the operator can find out why from the log.
#
# Isolation:
#   NMIS_MASTER_KEY_FILE - a key in a private temp dir, created here because
#       _resolve_seed never creates one at a non-default path. The shipped
#       /usr/local/etc/firstwave/master.key is never read, created or replaced.
#   NMIS_NMIS_LOGS - a temp log directory, so the assertions can read back what
#       was logged and nothing appends to the real nmis.log.
#   conf/Config.nmis is backed up with bytes, mode and ownership and restored
#       in END. These writes are the behaviour under test, so they cannot be
#       spied away.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use File::Copy qw(copy);
use Digest::MD5 ();
use Test::More;

my ($KEYDIR, $KEYFILE, $LOGDIR);
BEGIN {
	$KEYDIR  = File::Temp::tempdir("omk12928-migr-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	$KEYFILE = "$KEYDIR/master.key";
	$LOGDIR  = "$KEYDIR/logs";
	mkdir($LOGDIR);
	$ENV{NMIS_MASTER_KEY_FILE} = $KEYFILE;
	$ENV{NMIS_NMIS_LOGS}       = $LOGDIR;
	# the flag is an ENV override throughout, flipped per case. That keeps it
	# out of conf/Config.nmis (writeConfData skips a layer-4 key whose value
	# has not changed) and keeps every case meaning the same thing after
	# OMK-12695 flips the shipped default.
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'false';
}

BEGIN {
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
		eval "require $m; 1"
			or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG::Util;

{
	open(my $kh, '>', $KEYFILE) or BAIL_OUT("cannot create the test master key: $!");
	print $kh ("K" x 256) . "\n";
	close $kh;
	chmod(0400, $KEYFILE);
}

my $C         = NMISNG::Util::loadConfTable();
my $CONF_FILE = $C->{configfile};
my $CONF_BAK  = "$CONF_FILE.bak";
my $LOGFILE   = "$LOGDIR/nmis.log";

# the field under test. mail_password is a PasswordFields entry that nothing in
# this test's environment reads, so writing it cannot break the run it is
# running in - the same reasoning as t_cgi_config_password_refusals.t.
my $SECTION = 'email';
my $KEYWORD = 'mail_password';

# ---- backup / restore, bytes + mode + owner (docs/CGI_TESTING.md) -----------
sub save_file
{
	my ($orig, $suffix) = @_;
	return { absent => 1 } if (!-f $orig);
	my @st = CORE::stat($orig);
	my $to = "$orig$suffix";
	copy($orig, $to) or BAIL_OUT("cannot back up $orig: $!");
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
	chown($saved->{uid}, $saved->{gid}, $orig);   # best effort; a non-root run
	unlink $saved->{copy};                        # never took ownership away
}

my $CONF_SAVED = save_file($CONF_FILE, ".t12928migrbak");
my $BAK_SAVED  = save_file($CONF_BAK, ".t12928migrbak");

END {
	restore_file($CONF_SAVED, $CONF_FILE);
	restore_file($BAK_SAVED, $CONF_BAK);
}

# a pristine copy of the checkout's local config, taken before anything wrote
my $PRISTINE;
{
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	$PRISTINE = $local;
}

sub reload
{
	$NMISNG::Util::_config_cache_invalid = 1;
	my $cfg = NMISNG::Util::loadConfTable();
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	return ($cfg, $local);
}

# Writes conf/Config.nmis directly (not via writeConfData, whose filtering is
# part of what some cases observe) and reloads. $value undef leaves the field
# out of the file entirely.
sub seed_config
{
	my ($value) = @_;

	my %seed;
	for my $sect (keys %$PRISTINE)
	{
		next unless ref($PRISTINE->{$sect}) eq 'HASH';
		$seed{$sect}{$_} = $PRISTINE->{$sect}{$_} for (keys %{$PRISTINE->{$sect}});
	}
	# Drop every key conf.d (layer 3) or the environment (layer 4) currently
	# owns. only_local hands back whatever literal value the file happens to
	# hold for such a key, and that can be stale; writing it back would meet
	# writeConfData's "managed by ..." refusal and void the fixture. This is
	# the CI trap documented in t_cgi_config_protected_keys.t.
	my $sources = NMISNG::Util::getConfigSources();
	for my $key (keys %$sources)
	{
		my $layer = $sources->{$key}{layer};
		next unless (defined($layer) && ($layer == 3 || $layer == 4));
		my $section = $sources->{$key}{section};
		delete $seed{$section}{$key} if (defined($section) && ref($seed{$section}) eq 'HASH');
	}

	if (defined $value) { $seed{$SECTION}{$KEYWORD} = $value; }
	else                { delete $seed{$SECTION}{$KEYWORD}; }

	my $err = NMISNG::Util::writeHashtoFile(file => $CONF_FILE, data => \%seed);
	BAIL_OUT("cannot seed $CONF_FILE: $err") if ($err);
	return reload();
}

sub stored
{
	my ($local) = @_;
	return undef if (ref($local->{$SECTION}) ne 'HASH');
	return $local->{$SECTION}{$KEYWORD};
}

sub file_md5
{
	my ($f) = @_;
	return 'ABSENT' if (!-f $f);
	open(my $fh, '<', $f) or return "UNREADABLE:$!";
	my $d = Digest::MD5->new->addfile($fh)->hexdigest;
	close $fh;
	return $d;
}

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

my $PLAIN = 'migrateMe12928';

# ---- U: up-migration --------------------------------------------------------
{
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
	my ($cfg, $local) = seed_config($PLAIN);
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 1,
		"U fixture: encryption is enabled");
	is(stored($local), $PLAIN, "U fixture: the field is stored in plaintext");

	reset_log();
	my $got = NMISNG::Util::decrypt($PLAIN, $SECTION, $KEYWORD);
	is($got, $PLAIN, "decrypt returns the plaintext it was handed");

	(undef, $local) = reload();
	like(stored($local), qr/^!!/,
		"and the up-migration wrote ciphertext into conf/Config.nmis");
	is(NMISNG::Util::decrypt(stored($local)), $PLAIN,
		"which decrypts back to the same secret");
}

# ---- D: down-migration ------------------------------------------------------
{
	# the ciphertext is produced with encryption still on, then the flag is
	# flipped: that is the state disable-eos leaves a field in.
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
	reload();
	my $cipher = NMISNG::Util::encrypt($PLAIN);
	like($cipher, qr/^!!/, "D fixture: produced a ciphertext to migrate down");

	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'false';
	my ($cfg, $local) = seed_config($cipher);
	is(NMISNG::Util::getbool($cfg->{global_enable_password_encryption}), 0,
		"D fixture: encryption is disabled");
	is(stored($local), $cipher, "D fixture: the field is stored as ciphertext");

	reset_log();
	my $got = NMISNG::Util::decrypt($cipher, $SECTION, $KEYWORD);
	is($got, $PLAIN, "decrypt returns the plaintext");

	(undef, $local) = reload();
	is(stored($local), $PLAIN,
		"and the down-migration wrote the plaintext into conf/Config.nmis");
}

# ---- E: an ENV-managed field diverges --------------------------------------
# This is the shape NMISNG::DB hits on every connect once encryption is on by
# default and NMIS_DB_PASSWORD is exported, which CI does.
{
	my $ENVVAL = 'envOwnedSecret12928';
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
	$ENV{'NMIS_' . uc($KEYWORD)} = $ENVVAL;

	# seeded WITHOUT the field: the environment owns it, and seed_config drops
	# every layer-3/4 key anyway.
	my ($cfg, $local) = seed_config(undef);
	is($cfg->{$KEYWORD}, $ENVVAL, "E fixture: the effective value comes from the environment");
	my $src = NMISNG::Util::getConfigSources()->{$KEYWORD};
	is(($src && $src->{layer}), 4, "E fixture: and the key really is layer 4 (ENV-managed)")
		or BAIL_OUT("could not force $KEYWORD to be ENV-managed; without that this "
					. "case would be testing an ordinary write, not the refusal");

	my $md5_before = file_md5($CONF_FILE);
	reset_log();
	my $got = eval { NMISNG::Util::decrypt($ENVVAL, $SECTION, $KEYWORD) };
	my $died = $@;

	is($died, '', "decrypt does not die when the migration write is refused");
	is($got, $ENVVAL, "and still returns the value it was handed (fail-closed contract)");
	is(file_md5($CONF_FILE), $md5_before, "conf/Config.nmis is byte-identical");

	# The refusal must be VISIBLE but must not be an error. An ENV- or
	# conf.d-managed property is refused by design, and with encryption on by
	# default (OMK-12695) the shipped container meets this on every process's
	# first connect, forever - NMIS_DB_PASSWORD makes database/db_password a
	# layer-4 key. Logging that at error level would be permanent, unclearable
	# noise in a flagship deployment, so it is info, and it still names the
	# property and the source that owns it.
	my $log = read_log();
	like($log, qr/The stored secret for '\Q$SECTION\E\/\Q$KEYWORD\E' is managed by/,
		"the refusal is logged, naming the property and its owner");
	like($log, qr/\[info\].*is managed by/,
		"at info level, because a managed property is refused by design, not by failure");
	unlike($log, qr/\[error\].*\Q$SECTION\E\/\Q$KEYWORD\E/,
		"and NOT at error level (this line would otherwise repeat forever in the shipped container)");
	like($log, qr/ENV:NMIS_\U$KEYWORD/,
		"naming the environment variable that owns it (a name, never a value)");
	unlike($log, qr/\Q$ENVVAL\E/, "without echoing the secret");

	delete $ENV{'NMIS_' . uc($KEYWORD)};
}

done_testing();
