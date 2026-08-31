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
# OMK-12695 (SEC-1) / OMK-12713 (SEC-2): secrets are encrypted at rest by
# DEFAULT. Every other crypto test in the suite pins the flag with an explicit
# NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION override, deliberately, so that its
# subject keeps meaning the same thing whichever way the shipped default points.
# This file is the one that must NOT do that: the default is its subject.
#
# It therefore sets only NMIS_MASTER_KEY_FILE (a private, ephemeral key, so no
# root and no shipped key are needed) and explicitly DELETES the flag override
# from the environment before anything loads the config.
#
# Four things are asserted, in this order:
#
#   1. text     - both shipped configs carry 'true':
#                 conf-default/Config.nmis and conf-default/docker/Config.nmis.docker
#   2. honesty  - which layer actually supplies the effective value in THIS
#                 environment, so the layering assertion below cannot pass for
#                 the wrong reason (see the note on conf/Config.nmis).
#   3. layering - a config context with no local override resolves to ENABLED
#   4. at rest  - and that default alone, with no flag env anywhere, is enough:
#                 SEC-2  a config secret up-migrates to '!!' in conf/Config.nmis
#                 SEC-1  a node's device secret is '!!' in mongo and round-trips
#
# A note on conf/Config.nmis and what test 2 is for. `conf/` is gitignored, so
# what sits there depends on how the checkout was brought up:
#   - a bare/dev worktree may have a hand-made minimal conf/Config.nmis that
#     never mentions the key, in which case the shipped conf-default value
#     (layer 1) decides;
#   - the dev container's entrypoint copies conf-default/docker/Config.nmis.docker
#     to conf/Config.nmis on first boot when it is absent (CI does exactly
#     this), so the site config CAN carry the key - but only ever as a verbatim
#     copy of the OTHER shipped default.
# Both are the shipped default. Neither is a site decision. Test 2 establishes
# which of the two is in play and refuses a site value that is anything but
# 'true', so "resolves to enabled" is never satisfied by an override this test
# did not account for.
#
# Isolation:
#   NMIS_MASTER_KEY_FILE - a key in a private temp dir, created here because
#       _resolve_seed never creates one at a non-default path. The shipped
#       /usr/local/etc/firstwave/master.key is never read, created or replaced.
#   NMIS_NMIS_LOGS - a temp log directory, so nothing appends to the real
#       nmis.log.
#   conf/Config.nmis is backed up with bytes, mode and ownership and restored in
#       END. The SEC-2 write is the behaviour under test, so it cannot be spied
#       away; the SEC-1 phase runs afterwards with writeConfData neutralised.
#   mongo - a throwaway t_encdefault-<timestamp> database, dropped at the end.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use File::Copy qw(copy);
use Test::More;

# MUST run before the master key is substituted below. The checkout's stored
# db_password may already be '!!' ciphertext under the INSTALLATION's master
# key - which is this change working as intended. This test then swaps in an
# ephemeral key that cannot read it, and the mongo phase's every connect would
# fail authentication. Resolve the effective value while the ambient key is
# still in force and hand it to the rest of the process as a layer-4 ENV
# override - which also puts db_password beyond writeConfData's reach, so
# nothing here can migrate the checkout's config. decrypt is called with no
# section and no keyword on purpose: that is the form with no migration write.
# The value is never printed. A pre-set NMIS_DB_PASSWORD (CI supplies one) wins.
BEGIN {
	require NMISNG::Util;
	my $ambient = NMISNG::Util::loadConfTable();
	if (!defined($ENV{NMIS_DB_PASSWORD})
		&& defined($ambient->{db_password}) && $ambient->{db_password} ne '')
	{
		my $plain = eval { NMISNG::Util::decrypt($ambient->{db_password}) };
		$ENV{NMIS_DB_PASSWORD} = $plain if (defined($plain) && $plain ne '');
	}
	$NMISNG::Util::_config_cache_invalid = 1;
}

my ($KEYDIR, $KEYFILE, $LOGDIR);
BEGIN {
	$KEYDIR  = File::Temp::tempdir("omk12695-default-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	$KEYFILE = "$KEYDIR/master.key";
	$LOGDIR  = "$KEYDIR/logs";
	mkdir($LOGDIR);
	$ENV{NMIS_MASTER_KEY_FILE} = $KEYFILE;
	$ENV{NMIS_NMIS_LOGS}       = $LOGDIR;
	# THE POINT OF THIS FILE. Everything below must be reached by the shipped
	# default, so the override every other crypto test relies on is removed.
	delete $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION};
}

BEGIN {
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure))
	{
		eval "require $m; 1"
			or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG;
use NMISNG::Node;
use NMISNG::Log;
use NMISNG::Util;

{
	open(my $kh, '>', $KEYFILE) or BAIL_OUT("cannot create the test master key: $!");
	print $kh ("K" x 256) . "\n";
	close $kh;
	chmod(0400, $KEYFILE);
}

my $FLAG      = 'global_enable_password_encryption';
my $SHIPPED   = "$FindBin::Bin/../conf-default/Config.nmis";
my $SHIPPED_D = "$FindBin::Bin/../conf-default/docker/Config.nmis.docker";

sub slurp
{
	my ($f) = @_;
	return undef if (!-f $f);
	open(my $fh, '<', $f) or return undef;
	local $/;
	my $t = <$fh>;
	close $fh;
	return $t;
}

# ---- 1. both shipped configs carry 'true' -----------------------------------
for my $pair ([$SHIPPED, 'conf-default/Config.nmis'],
			  [$SHIPPED_D, 'conf-default/docker/Config.nmis.docker'])
{
	my ($path, $label) = @$pair;
	my $text = slurp($path);
	ok(defined($text), "$label is readable")
		or next;
	like($text, qr/'\Q$FLAG\E'\s*=>\s*'true'/,
		"$label ships $FLAG => 'true'");
	unlike($text, qr/'\Q$FLAG\E'\s*=>\s*'false'/,
		"... and carries no leftover 'false' for it");
}

# ---- 2. honesty: what supplies the effective value here ---------------------
ok(!defined($ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION}),
	"no NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION override is in this process's environment");

my $C         = NMISNG::Util::loadConfTable();
my $CONF_FILE = $C->{configfile};
my $CONF_BAK  = "$CONF_FILE.bak";

my $site_text = slurp($CONF_FILE);
my ($site_flag) = defined($site_text)
	? ($site_text =~ /'\Q$FLAG\E'\s*=>\s*'([^']*)'/)
	: (undef);

my $src = NMISNG::Util::getConfigSources()->{$FLAG};
ok(ref($src) eq 'HASH', "the config layering knows where $FLAG comes from")
	or BAIL_OUT("no source recorded for $FLAG; the layering assertion below would be meaningless");

if (defined($site_flag))
{
	# only a copy of conf-default/docker/Config.nmis.docker gets here (the dev
	# container entrypoint's first-boot copy). Anything else is a site decision
	# and this test is not measuring the shipped default any more.
	is($site_flag, 'true',
		"the site config's copy of $FLAG carries the shipped 'true' (not a site override)");
	is($src->{layer}, 2, "and layer 2 (the site config) supplies the effective value here");
	diag("conf/Config.nmis carries $FLAG => '$site_flag' (a first-boot copy of Config.nmis.docker)");
}
else
{
	pass("the site config carries no $FLAG entry, so the shipped default alone decides");
	is($src->{layer}, 1, "and layer 1 (conf-default) supplies the effective value here");
	like($src->{source}, qr{conf-default/Config\.nmis$},
		"named as the shipped conf-default/Config.nmis");
}

# ---- 3. the resolved default is ENABLED -------------------------------------
is(NMISNG::Util::getbool($C->{$FLAG}), 1,
	"a config context with no local override resolves to encryption ENABLED");

# ---- backup / restore, bytes + mode + owner (docs/CGI_TESTING.md) -----------
sub save_file
{
	my ($orig, $suffix) = @_;
	return undef if (!-f $orig);
	my @st = CORE::stat($orig);
	my $to = "$orig$suffix";
	copy($orig, $to) or BAIL_OUT("cannot back up $orig: $!");
	return { copy => $to, mode => ($st[2] & 07777), uid => $st[4], gid => $st[5] };
}

sub restore_file
{
	my ($saved, $orig) = @_;
	return if (!$saved || !-f $saved->{copy});
	# a failed restore leaves the operator's config as this test rewrote it, so
	# it must never be silent, even in END where nothing can be asserted
	copy($saved->{copy}, $orig)
		or diag("RESTORE FAILED: could not copy $saved->{copy} back to $orig: $!");
	chmod($saved->{mode}, $orig);
	chown($saved->{uid}, $saved->{gid}, $orig);   # best effort; a non-root run
	unlink $saved->{copy};                        # never took ownership away
}

my $CONF_SAVED = save_file($CONF_FILE, ".t12695defbak");
my $BAK_SAVED  = save_file($CONF_BAK, ".t12695defbak");

END {
	restore_file($CONF_SAVED, $CONF_FILE);
	restore_file($BAK_SAVED, $CONF_BAK);
	unlink $CONF_BAK if (!$BAK_SAVED && -f $CONF_BAK);
}

sub reload
{
	$NMISNG::Util::_config_cache_invalid = 1;
	my $cfg = NMISNG::Util::loadConfTable();
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	return ($cfg, $local);
}

# ---- 4a. SEC-2: a config secret encrypts at rest, on the default alone ------
# decrypt()'s section/keyword migration is what brings a stored config secret
# into line with the encryption setting. With the default now ON, handing it a
# plaintext PasswordFields entry must write the ciphertext back.
#
# This phase runs BEFORE the node phase because it needs the REAL writeConfData
# and the node phase must not have one (see 4b).
{
	my $SECTION = 'email';
	my $KEYWORD = 'mail_password';
	my $PLAIN   = 'defaultOnSecret12695';

	# seed conf/Config.nmis directly from its own layer-2 content plus the field
	# under test. Every key that conf.d (layer 3) or the environment (layer 4)
	# owns is dropped first: only_local hands back whatever literal the file
	# holds for such a key, which can be stale, and writing it back would meet
	# writeConfData's "managed by ..." refusal and void the fixture. That is the
	# CI trap documented in t_cgi_config_protected_keys.t.
	my ($pristine) = NMISNG::Util::getConfDeep(only_local => 1);
	my %seed;
	for my $sect (keys %$pristine)
	{
		next unless ref($pristine->{$sect}) eq 'HASH';
		$seed{$sect}{$_} = $pristine->{$sect}{$_} for (keys %{$pristine->{$sect}});
	}
	my $sources = NMISNG::Util::getConfigSources();
	for my $key (keys %$sources)
	{
		my $layer = $sources->{$key}{layer};
		next unless (defined($layer) && ($layer == 3 || $layer == 4));
		my $section = $sources->{$key}{section};
		delete $seed{$section}{$key} if (defined($section) && ref($seed{$section}) eq 'HASH');
	}
	$seed{$SECTION}{$KEYWORD} = $PLAIN;

	my $err = NMISNG::Util::writeHashtoFile(file => $CONF_FILE, data => \%seed);
	BAIL_OUT("cannot seed $CONF_FILE: $err") if ($err);

	my ($cfg, $local) = reload();
	is(NMISNG::Util::getbool($cfg->{$FLAG}), 1,
		"SEC-2 fixture: encryption is still on after reseeding the config");
	is($local->{$SECTION}{$KEYWORD}, $PLAIN,
		"SEC-2 fixture: $SECTION/$KEYWORD is stored in plaintext");

	my $got = NMISNG::Util::decrypt($PLAIN, $SECTION, $KEYWORD);
	is($got, $PLAIN, "decrypt returns the plaintext it was handed");

	(undef, $local) = reload();
	like($local->{$SECTION}{$KEYWORD}, qr/^!!/,
		"SEC-2: the shipped default alone up-migrated $SECTION/$KEYWORD to ciphertext at rest");
	is(NMISNG::Util::decrypt($local->{$SECTION}{$KEYWORD}), $PLAIN,
		"which decrypts back to the same secret");
}

# put the operator's own config back before anything touches mongo
restore_file($CONF_SAVED, $CONF_FILE);
$CONF_SAVED = save_file($CONF_FILE, ".t12695defbak");
reload();

# ---- 4b. SEC-1: a device secret encrypts at rest, on the default alone ------
# From here on no config write may happen. NMISNG::DB's connect calls
# decrypt($CONF->{db_password}, 'database', 'db_password'), and with encryption
# on that would re-encrypt the checkout's real db_password with THIS test's
# ephemeral key - unreadable to every later run. Node saves go through the nodes
# collection, not writeConfData, so neutralising it costs this phase nothing.
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { return; };
}

$C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_encdefault-" . time;

my $logger = NMISNG::Log->new(level => 'warn');
my $nmisng = NMISNG->new(config => $C, log => $logger);
BAIL_OUT("NMISNG object required") if (!$nmisng);

my $uuid = NMISNG::Util::getUUID();
my $PLAINCOMM = 'defaultOnCommunity12695';
my $node = NMISNG::Node->new(nmisng => $nmisng, uuid => $uuid);
$node->name("encdefaultnode1");
$node->cluster_id($nmisng->config->{cluster_id});
$node->configuration({host => "127.0.0.1", group => "test", netType => "lan",
	roleType => "access", community => $PLAINCOMM, threshold => 1});
my ($op, $saveerr) = $node->save();
ok($op > 0, "SEC-1 fixture: test node saved") or diag("save error: " . ($saveerr // ''));

my $coll = $nmisng->nodes_collection;
sub raw_community
{
	my $doc = $coll->find_one({uuid => $uuid});
	return $doc ? $doc->{configuration}->{community} : undef;
}

is(raw_community(), $PLAINCOMM,
	"SEC-1 fixture: the community is stored in plaintext before any migration");

my $reload = $nmisng->node(uuid => $uuid);
ok($reload, "the node reloads");
like(raw_community(), qr/^!!/,
	"SEC-1: the shipped default alone migrated the device secret to ciphertext at rest");
is(NMISNG::Util::decrypt(raw_community()), $PLAINCOMM,
	"and the ciphertext round-trips back to the original secret");
# the node object carries the STORED form, not the plaintext: NMIS decrypts at
# point of use (NMISNG::Snmp passes every credential through decrypt when it
# builds the session). Pinned here because it is the contract that makes
# encryption-at-rest work, and it is now the default path for every install.
is($reload->configuration->{community}, raw_community(),
	"the node object carries the stored ciphertext; consumers decrypt at point of use");

$nmisng->get_db()->drop();

done_testing();
