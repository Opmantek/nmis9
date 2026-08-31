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
# OMK-12827 Slice B: cgi-bin/config.pl hides a small set of keys from the
# rendered config table, and every write route must refuse them too (PR 73
# re-review, Important 2).
#
# The hole this pins shut: displayConfig/typeSect skipped the row, so the GUI
# offered no edit/delete link for master_key_file - but doEditConfig,
# doDeleteConfig and doAddConfig never re-checked that exclusion. A user holding
# Table_Config_rw and a valid CSRF token could still repoint the crypto master
# key by posting straight at the endpoint, at which point every '!!' secret
# already in the config becomes undecryptable until the key is pointed back.
# Hiding a control in the HTML is not an authorisation decision; the handler has
# to make it.
#
# Cases, all driven as a browser-less direct POST (which is the threat, so it is
# also the test):
#
#   N1 doedit   system/master_key_file          -> refused, nothing written
#   N2 dodelete system/master_key_file          -> refused, nothing written
#   N3 doadd    system/master_key_file          -> refused, nothing written
#   N4 doadd    database/master_key_file        -> refused, nothing written
#   P1 doedit   system/<probe>                  -> accepted, value changed
#   P2 dodelete system/<probe>                  -> accepted, key removed
#   P3 doadd    system/<probe>                  -> accepted, key added
#   D  the config table still does not render the key at all
#
# N3 and N4 need saying out loud. doAddConfig does not check whether the key it
# is asked to add already exists - it assigns straight into the section - so
# "add" on an existing protected key is really a silent overwrite, and it is a
# genuine second route to the same outcome rather than a contrived one. N4 then
# covers the bypass a section-scoped deny list would leave open: config is a FLAT
# namespace at the point of use (_load_and_flatten collapses every section into
# one hash, and _resolve_seed reads $config->{master_key_file} with no section
# involved), so adding the very same key name under 'database' repoints the key
# just as effectively as adding it under 'system'. A deny list keyed by
# section+item would pass N3 and still fail N4.
#
# P1..P3 are what make N1..N4 mean anything. All four refusals render through the
# same generic "Error: ..." bar that displayConfig prints for any aborted write,
# and an unauthenticated session, a rejected CSRF token or a broken fixture would
# also leave the config unwritten - so "nothing was written" on its own proves
# nothing. Each write route therefore gets a positive control on an unprotected
# key through the identical flow, same session, same token mechanism, same POST
# shape; only the key name differs.
#
# Driven through the real CGI in-process via the NMISx Mojolicious app on a real
# authenticated session, per docs/CGI_TESTING.md; reading cgi-bin/config.pl as
# text is the documented anti-pattern. Mojolicious::Plugin::CGI forks and execs
# the script, so the CGI is a fresh interpreter and no in-process monkey-patching
# can reach the handlers - the write is observed where it really happens, on
# conf/Config.nmis (md5 and effective value).
#
# Fixture. The test seeds three keys into the UNTRACKED conf/Config.nmis before
# the app boots, and restores the file (bytes, mode and ownership) in END:
#
#   system/master_key_file = a sentinel path in a private temp dir. It has to be
#       a LOCAL override and not the shipped default, because writeConfData skips
#       any key whose value equals its default - so a delete of a default-valued
#       master_key_file would change nothing on disk even when it succeeds, and
#       case N2 could not tell a refusal from a no-op. The sentinel path is never
#       read: only encrypt/decrypt resolve the master key, and encryption is off
#       by default (conf-default: global_enable_password_encryption => 'false').
#       A real key file is created there anyway, mode 0400, so that even an
#       unexpected read succeeds and the shipped /usr/local/etc/firstwave/master.key
#       is neither touched, moved nor read by this test.
#   system/t12827_prot_probe_edit, .../t12827_prot_probe_delete = throwaway
#       unprotected keys for P1 and P2. Nothing reads them, and they carry no
#       entry in Table-Config.nmis, so no validation rule and (for P2)
#       doDeleteConfig's "required by validation rule" refusal cannot fire.
#
# Needs a reachable MongoDB and the NMISx app, i.e. the dev container; it skips
# cleanly elsewhere. It seeds and restores a throwaway admin in conf/Users.nmis +
# conf/users.dat, and backs up and restores conf/Config.nmis and
# conf/Config.nmis.bak.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Copy;
use File::Temp ();
use Digest::MD5 ();
use Crypt::PasswdMD5 qw(apache_md5_crypt);

use NMISNG::Util;

# ---- seed a throwaway admin, so login never depends on nmis/nm1888 ----------
# The dev/CI entrypoint re-seeds the built-in "nmis" account's password from
# NMIS_ADMIN_PASSWORD (docker-dev/.env-dev), so nm1888 does not authenticate in
# the container. A failed login here would be near silent: every write would run
# unauthenticated and be refused, which surfaces as "no write" - i.e. as a PASS
# for all four negative cases. Seed our own administrator into the UNTRACKED
# conf/Users.nmis and conf/users.dat instead, exactly as t_csrf_cgi.t and
# t_cgi_config_password_refusals.t do, and restore both in END. Must run before
# the app boots so the forked CGI reads the seeded account.

my $TESTUSER = 't12827_prot_admin';
my $TESTPASS = 't12827-prot-' . $$;

my $CONFDIR  = "$FindBin::Bin/../conf";
my $USERSCFG = "$CONFDIR/Users.nmis";
my $USERSDAT = "$CONFDIR/users.dat";

my ($CFGBAK, $DATBAK);
if (-f $USERSCFG && -f $USERSDAT)
{
	$CFGBAK = "$USERSCFG.t12827protbak";
	$DATBAK = "$USERSDAT.t12827protbak";
	copy($USERSCFG, $CFGBAK);
	copy($USERSDAT, $DATBAK);

	open(my $in, '<', $USERSCFG) or die "cannot read $USERSCFG: $!";
	my $txt = do { local $/; <$in> };
	close $in;
	# a seeding miss must say so, rather than resurfacing later as a login
	# failure that reads like a product bug.
	my $seeded = ($txt =~ s{(\%hash\s*=\s*\()}{$1
  '$TESTUSER' => {
    '_id' => '$TESTUSER',
    'groups' => 'all',
    'privilege' => 'administrator',
    'user' => '$TESTUSER'
  },});
	die "cannot seed $TESTUSER into $USERSCFG: no '%hash = (' found, the file format changed\n"
		if (!$seeded);

	open(my $out, '>', $USERSCFG) or die "cannot write $USERSCFG: $!";
	print $out $txt;
	close $out;

	open(my $pw, '>>', $USERSDAT) or die "cannot append to $USERSDAT: $!";
	print $pw $TESTUSER . ":" . apache_md5_crypt($TESTPASS) . "\n";
	close $pw;
}

END {
	if ($CFGBAK && -f $CFGBAK) { copy($CFGBAK, $USERSCFG); unlink $CFGBAK; }
	if ($DATBAK && -f $DATBAK) { copy($DATBAK, $USERSDAT); unlink $DATBAK; }
}

# ---- guards: skip cleanly off the dev container, but never silently ---------

my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});
plan skip_all => "could not seed the test admin under conf/ (bare host?)" unless $CFGBAK;

# ---- back up the config this test is allowed to write, per CGI_TESTING.md ---
# writeConfData copies the live file to <file>.bak before writing, so both must
# be captured and both restored, including the "was absent" case.
#
# Content is not enough. writeConfData replaces the file rather than rewriting it
# in place, so the new one carries the CGI's uid/gid and umask - and NMIS ships
# its config group-writable on purpose, so httpd (a member of the nmis group) can
# edit it. Restoring the bytes but leaving root:root 0644 behind would silently
# take the GUI's write access away. Capture mode and ownership and put them back
# too; the chown is best effort, since a non-root run cannot give a file away and
# does not need to (it never took the ownership away).

my $CONF_FILE = $C->{configfile};
my $CONF_BAK  = "$CONF_FILE.bak";

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
	copy($saved->{copy}, $orig);
	chmod($saved->{mode}, $orig);
	chown($saved->{uid}, $saved->{gid}, $orig);   # best effort, see above
	unlink $saved->{copy};
}

my $CONF_SAVED = save_file($CONF_FILE, ".t12827protbak");
my $BAK_SAVED  = save_file($CONF_BAK, ".t12827protbak");

END {
	restore_file($CONF_SAVED, $CONF_FILE);
	restore_file($BAK_SAVED, $CONF_BAK);
	# writeConfData creates the .bak; if there was none before us, leave none behind
	unlink $CONF_BAK if (!$BAK_SAVED && -f $CONF_BAK);
}

# ---- seed the fixture into conf/Config.nmis, before the app boots ------------

my $KEYDIR    = File::Temp::tempdir("omk12827-protkeys-XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $SENTINEL  = "$KEYDIR/sentinel-master.key";
my $ATTACKER  = "$KEYDIR/attacker-master.key";

# a real file at the sentinel path, so that even an unexpected master-key read
# succeeds rather than warning; see the header for why it is never reached.
{
	my @cs = ('A'..'Z', 'a'..'z', 0..9);
	open(my $kh, '>', $SENTINEL) or BAIL_OUT("cannot create the sentinel key $SENTINEL: $!");
	print $kh join('', map { $cs[int(rand(scalar @cs))] } (1..256));
	close $kh;
	chmod(0400, $SENTINEL);
}

my $PROBE_EDIT   = 't12827_prot_probe_edit';
my $PROBE_DELETE = 't12827_prot_probe_delete';
my $PROBE_ADD    = 't12827_prot_probe_add';

{
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	$local->{system}{master_key_file} = $SENTINEL;
	$local->{system}{$PROBE_EDIT}     = 'before';
	$local->{system}{$PROBE_DELETE}   = 'before';
	delete $local->{system}{$PROBE_ADD};              # P3 must create it
	my $err = NMISNG::Util::writeConfData(data => $local);
	BAIL_OUT("cannot seed the fixture into $CONF_FILE: $err") if ($err);
	$NMISNG::Util::_config_cache_invalid = 1;
	$C = NMISNG::Util::loadConfTable();
}

# the premise of every case below, so a miss is a failure and not a skip
if (($C->{master_key_file} // '') ne $SENTINEL)
{
	fail("fixture: master_key_file is a local override pointing at the sentinel");
	diag("master_key_file resolved to '" . ($C->{master_key_file} // 'undef')
			 . "', wanted '$SENTINEL'; without it this test would be operating on the "
			 . "shipped master key, which it must never touch");
	done_testing();
	exit;
}

my $t = eval { require Test::Mojo; Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

# ---- helpers ----------------------------------------------------------------

# md5 of a file, or a distinct sentinel when absent, so "file created" and
# "file removed" are caught too, not just "file edited".
sub file_cksum
{
	my ($f) = @_;
	return 'ABSENT' unless -f $f;
	open(my $fh, '<', $f) or return "UNREADABLE:$!";
	local $/;
	my $data = <$fh>;
	close $fh;
	return Digest::MD5::md5_hex($data);
}

# re-read conf/Config.nmis from disk. The CGI is a separate process, so this
# process's config cache knows nothing about what it did.
sub reload
{
	$NMISNG::Util::_config_cache_invalid = 1;
	my $flat = NMISNG::Util::loadConfTable();
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);
	return ($flat, $local);
}

# a fresh CSRF token, harvested from the rendered config table the way a browser
# would get one. config_nmis_menu is classed 'read', so the GET needs no token of
# its own.
sub fresh_csrf
{
	$t->get_ok('/cgi-nmis9/config.pl?conf=Config&act=config_nmis_menu&section=system&widget=false');
	my $tok = $t->tx->res->dom->at('input[name="csrf_token"]');
	$tok = $tok && $tok->attr('value');
	BAIL_OUT("could not harvest a CSRF token from the config table; the session is "
			 . "not authenticated, so no write below would prove anything") if (!$tok);
	return $tok;
}

# the direct POST an attacker would make: no form was ever rendered for these
# keys, the parameters are built by hand, only the token comes from the app.
sub post_write
{
	my (%p) = @_;
	my $form = { conf => 'Config', widget => 'false', csrf_token => fresh_csrf(), %p };
	$t->post_ok('/cgi-nmis9/config.pl' => form => $form);
	return ($t->tx->res->code // 0, $t->tx->res->body // '');
}

# the one refusal phrase all three handlers share
my $PROTECTED = qr/not editable through the GUI \(protected key\)/;
# displayConfig's generic error bar, for the positive controls
my $ANY_ERROR = qr/class="Fatal"/;

# ---- authenticate through the real app --------------------------------------

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $TESTUSER, auth_password => $TESTPASS });
# a cookie alone proves nothing: an unauthenticated response still sets a session
# cookie, so assert the body is the app, not the login page.
unlike($t->tx->res->body // '', qr/Invalid username\/password/,
	   "authenticated session established as $TESTUSER");

my $BASE_CONF = file_cksum($CONF_FILE);
my $BASE_BAK  = file_cksum($CONF_BAK);
isnt($BASE_CONF, 'ABSENT', "baseline: conf/Config.nmis exists to be watched");

# ---- D: the display side still hides the key --------------------------------
# Cheap anti-drift guard. The whole point of the shared deny list is that display
# and writes cannot disagree; if a future edit drops the key from the list, this
# goes red next to the four write cases rather than leaving the hiding silently
# reversed. Asserted on a clean GET, because a refusal response echoes the posted
# parameters back into the form's self_url action.

{
	$t->get_ok('/cgi-nmis9/config.pl?conf=Config&act=config_nmis_menu&section=system&widget=false');
	my $body = $t->tx->res->body // '';
	is($t->tx->res->code, 200, "display: the system section renders");
	like($body, qr/\Q$PROBE_EDIT\E/,
		 "display: an ordinary system key IS rendered, so the table really drew")
			or diag("response was: " . substr($body, 0, 800));
	unlike($body, qr/master_key_file/,
		   "display: master_key_file is not rendered in the config table");
}

# =============================================================================
# NEGATIVE CASES - every write route refuses the protected key
# =============================================================================

# ---- N1: direct POST edit of system/master_key_file -------------------------

{
	my ($code, $body) = post_write(act => 'config_nmis_doedit', section => 'system',
								   item => 'master_key_file', value => $ATTACKER);

	is($code, 200, "N1 (edit): the submission is answered, not refused by the CSRF guard");
	like($body, $PROTECTED, "N1 (edit): master_key_file is refused as a protected key");

	my ($flat, $local) = reload();
	is($flat->{master_key_file}, $SENTINEL, "N1 (edit): the effective master key is unchanged");
	is($local->{system}{master_key_file}, $SENTINEL,
	   "N1 (edit): and conf/Config.nmis still names the sentinel");
	is(file_cksum($CONF_FILE), $BASE_CONF, "N1 (edit): conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "N1 (edit): conf/Config.nmis.bak was not written");
}

# ---- N2: direct POST delete of system/master_key_file -----------------------

{
	my ($code, $body) = post_write(act => 'config_nmis_dodelete', section => 'system',
								   item => 'master_key_file');

	is($code, 200, "N2 (delete): the submission is answered, not refused by the CSRF guard");
	like($body, $PROTECTED, "N2 (delete): master_key_file is refused as a protected key");

	my ($flat, $local) = reload();
	is($flat->{master_key_file}, $SENTINEL, "N2 (delete): the effective master key is unchanged");
	ok(exists $local->{system}{master_key_file},
	   "N2 (delete): the local override was not removed from conf/Config.nmis");
	is(file_cksum($CONF_FILE), $BASE_CONF, "N2 (delete): conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "N2 (delete): conf/Config.nmis.bak was not written");
}

# ---- N3: direct POST add of system/master_key_file --------------------------
# doAddConfig assigns into the section without checking whether the key is
# already there, so "add" on an existing key is a silent overwrite - the same
# outcome as N1 by a different route.

{
	my ($code, $body) = post_write(act => 'config_nmis_doadd', section => 'system',
								   id => 'master_key_file', value => $ATTACKER);

	is($code, 200, "N3 (add): the submission is answered, not refused by the CSRF guard");
	like($body, $PROTECTED, "N3 (add): master_key_file is refused as a protected key");

	my ($flat, $local) = reload();
	is($flat->{master_key_file}, $SENTINEL, "N3 (add): the effective master key is unchanged");
	is($local->{system}{master_key_file}, $SENTINEL,
	   "N3 (add): and conf/Config.nmis still names the sentinel");
	is(file_cksum($CONF_FILE), $BASE_CONF, "N3 (add): conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "N3 (add): conf/Config.nmis.bak was not written");
}

# ---- N4: the cross-section bypass -------------------------------------------
# Config is flat at the point of use, so the section a key is filed under is
# bookkeeping. A deny list keyed by section+item would let this through and the
# master key would still be repointed. The value assertion here is on the file,
# not on the flat effective value: with the same key name present in two sections
# of one file, which one wins the flatten is hash order, so only "it never got
# written" is a deterministic statement.

{
	my ($code, $body) = post_write(act => 'config_nmis_doadd', section => 'database',
								   id => 'master_key_file', value => $ATTACKER);

	is($code, 200, "N4 (cross-section add): the submission is answered");
	like($body, $PROTECTED,
		 "N4 (cross-section add): master_key_file is refused under 'database' too");

	my (undef, $local) = reload();
	ok(!exists $local->{database}{master_key_file},
	   "N4 (cross-section add): no master_key_file was filed under the database section");
	is(file_cksum($CONF_FILE), $BASE_CONF, "N4 (cross-section add): conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "N4 (cross-section add): conf/Config.nmis.bak was not written");
}

# =============================================================================
# POSITIVE CONTROLS - the same three routes, an unprotected key, all succeed
# =============================================================================
# Without these, all four cases above would pass just as happily against a broken
# session, a rejected token or a CGI that died before reaching any handler.

# ---- P1: edit an ordinary key ------------------------------------------------

{
	my ($code, $body) = post_write(act => 'config_nmis_doedit', section => 'system',
								   item => $PROBE_EDIT, value => 'after');

	is($code, 200, "P1 (edit control): the submission is answered");
	unlike($body, $PROTECTED, "P1 (edit control): an unprotected key is not refused")
			or diag("response was: " . substr($body, 0, 800));
	unlike($body, $ANY_ERROR, "P1 (edit control): and no error bar was rendered at all");

	my (undef, $local) = reload();
	is($local->{system}{$PROBE_EDIT}, 'after',
	   "P1 (edit control): the value WAS written - so the four refusals above are "
	   . "refusals, not an inert fixture");
	isnt(file_cksum($CONF_FILE), $BASE_CONF, "P1 (edit control): conf/Config.nmis WAS written");
}

# rebaseline: the successful control above legitimately changed the file
$BASE_CONF = file_cksum($CONF_FILE);
$BASE_BAK  = file_cksum($CONF_BAK);

# ---- P2: delete an ordinary key ---------------------------------------------

{
	my ($code, $body) = post_write(act => 'config_nmis_dodelete', section => 'system',
								   item => $PROBE_DELETE);

	is($code, 200, "P2 (delete control): the submission is answered");
	unlike($body, $PROTECTED, "P2 (delete control): an unprotected key is not refused");

	my (undef, $local) = reload();
	ok(!exists $local->{system}{$PROBE_DELETE},
	   "P2 (delete control): the key WAS deleted - the delete route is live");
	isnt(file_cksum($CONF_FILE), $BASE_CONF, "P2 (delete control): conf/Config.nmis WAS written");
}

$BASE_CONF = file_cksum($CONF_FILE);
$BASE_BAK  = file_cksum($CONF_BAK);

# ---- P3: add an ordinary key -------------------------------------------------

{
	my ($code, $body) = post_write(act => 'config_nmis_doadd', section => 'system',
								   id => $PROBE_ADD, value => 'added');

	is($code, 200, "P3 (add control): the submission is answered");
	unlike($body, $PROTECTED, "P3 (add control): an unprotected key is not refused");

	my (undef, $local) = reload();
	is($local->{system}{$PROBE_ADD}, 'added',
	   "P3 (add control): the key WAS added - the add route is live");
	isnt(file_cksum($CONF_FILE), $BASE_CONF, "P3 (add control): conf/Config.nmis WAS written");
}

done_testing();
