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
# OMK-12827 Slice B: the config GUI hides a small set of keys from the rendered
# config table, and every write route must refuse them too (PR 73 re-review,
# Important 2, extended by the re-review of that fix set).
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
# config.pl is not the only handler. cgi-bin/setup.pl's edit_config is a FOURTH
# write route into the same file, behind the same two rights (table_config_view
# for the page, Table_Config_rw for the write) and the same CSRF guard: it loops
# over every posted parameter named option/<section>/<item> and assigns it into
# the raw config, so option/system/master_key_file repoints the key just as
# effectively as config_nmis_doedit does. The setup panel renders controls for a
# fixed dozen properties and none of them is protected, which is exactly why the
# loop had nothing stopping a hand-built parameter. Hence the S cases, and hence
# the deny list living in NMISNG::Util rather than in either script.
#
# Cases, all driven as a browser-less direct POST (which is the threat, so it is
# also the test):
#
#   N1 config.pl doedit   system/master_key_file      -> refused, nothing written
#   N2 config.pl dodelete system/master_key_file      -> refused, nothing written
#   N3 config.pl doadd    system/master_key_file      -> refused, nothing written
#   N4 config.pl doadd    database/master_key_file    -> refused, nothing written
#   P1 config.pl doedit   system/<probe>              -> accepted, value changed
#   P2 config.pl dodelete system/<probe>              -> accepted, key removed
#   P3 config.pl doadd    system/<probe>              -> accepted, key added
#   D  the config table still does not render the key at all
#
#   S1 setup.pl option/system/master_key_file         -> refused, nothing written
#   S2 setup.pl option/system/<probe>                 -> accepted, value changed
#   S3 setup.pl both of the above in ONE submission   -> probe applied, key refused
#
# S3 is the case that says what "refused" has to mean on this route. setup.pl
# submits its whole panel in one POST, so refusing the request wholesale would
# make one hand-built parameter a denial-of-service on every other setting the
# operator just typed. The refusal is per item: the protected assignment is
# skipped, everything else in the same submission is written, and the operator is
# told which item was dropped. A silent skip would be worse than either, so S1
# and S3 both assert the refusal is visible in the rendered page and not merely
# absent from the file.
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
# One authenticated session covers both scripts. setup.pl gates its page on
# table_config_view and its write on Table_Config_rw, the same two rights
# config.pl uses, so the seeded administrator below needs nothing extra; and CSRF
# tokens are minted per user rather than per script. Each S case still harvests
# its token from setup.pl's own panel, because that is what a browser does and it
# doubles as proof the panel renders for this user at all.
#
# Fixture. The test seeds five keys into the UNTRACKED conf/Config.nmis before
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
#   system/t12827_prot_probe_edit, .../t12827_prot_probe_delete,
#       .../t12827_prot_probe_setup, .../t12827_prot_probe_setupmix = throwaway
#       unprotected keys for P1, P2, S2 and S3. Nothing reads them, and they carry
#       no entry in Table-Config.nmis, so no validation rule and (for P2)
#       doDeleteConfig's "required by validation rule" refusal cannot fire. The
#       two setup.pl probes must live under 'system' and that section must already
#       exist in the local file, because setup.pl's edit_config refuses any
#       option/<section>/... whose section is absent from conf/Config.nmis.
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

# OMK-12926 needles. $ATTACKER is an absolute path, and CGI.pm percent-encodes
# the '/' when it serialises a parameter into a URL, so searching a response for
# the whole path would silently find nothing even when the value IS reflected -
# a vacuous assertion of exactly the kind this file already had to fix once. The
# basename is made of URL-unreserved characters only ([A-Za-z0-9.-]), so it comes
# through CGI.pm's query escaping and its HTML escaping byte for byte. Keep that
# property if either name is changed.
my $ATTACKER_NEEDLE = 'attacker-master.key';
# and a distinctive applied value for the setup.pl positive controls, for the
# same reason: 'after' would be indistinguishable from ordinary page prose.
my $PROBE_APPLIED   = 't12827-prot-applied';

# a real file at the sentinel path, so that even an unexpected master-key read
# succeeds rather than warning; see the header for why it is never reached.
{
	my @cs = ('A'..'Z', 'a'..'z', 0..9);
	open(my $kh, '>', $SENTINEL) or BAIL_OUT("cannot create the sentinel key $SENTINEL: $!");
	print $kh join('', map { $cs[int(rand(scalar @cs))] } (1..256));
	close $kh;
	chmod(0400, $SENTINEL);
}

my $PROBE_EDIT     = 't12827_prot_probe_edit';
my $PROBE_DELETE   = 't12827_prot_probe_delete';
my $PROBE_ADD      = 't12827_prot_probe_add';
my $PROBE_SETUP    = 't12827_prot_probe_setup';
my $PROBE_SETUPMIX = 't12827_prot_probe_setupmix';

{
	my ($local) = NMISNG::Util::getConfDeep(only_local => 1);

	# Drop any key that is CURRENTLY sourced from conf.d (layer 3) or ENV
	# (layer 4) before round-tripping this hash through writeConfData.
	# only_local still returns whatever literal value conf/Config.nmis
	# happens to hold on disk for such a key - e.g. db_auth_source, written by
	# setup_mongodb.pl's scoped-user migration - and that stored value can be
	# stale once conf.d or an env var takes over. writeConfData refuses to
	# write an ENV/conf.d-sourced key whose submitted value differs from the
	# current effective one (NMISNG::Util.pm's "Cannot modify property ...  -
	# it is managed by ..." guard), which is exactly the CI-only bailout this
	# avoids: CI's Test NMIS step runs the suite with NMIS_DB_USERNAME,
	# NMIS_DB_PASSWORD and NMIS_DB_AUTH_SOURCE exported (bitbucket-pipelines.yml),
	# promoting those keys to layer 4 with values that no longer match whatever
	# setup_mongodb.pl last wrote to the file. Layer 3/4 always win over the raw
	# file at load time regardless of what the file contains, so omitting them
	# here changes nothing at runtime, and END below restores the original
	# bytes untouched either way.
	my $sources = NMISNG::Util::getConfigSources();
	for my $key (keys %$sources)
	{
		my $layer = $sources->{$key}{layer};
		next unless (defined($layer) && ($layer == 3 || $layer == 4));
		my $section = $sources->{$key}{section};
		delete $local->{$section}{$key}
				if (defined($section) && ref($local->{$section}) eq 'HASH');
	}

	$local->{system}{master_key_file} = $SENTINEL;
	$local->{system}{$PROBE_EDIT}     = 'before';
	$local->{system}{$PROBE_DELETE}   = 'before';
	$local->{system}{$PROBE_SETUP}    = 'before';
	$local->{system}{$PROBE_SETUPMIX} = 'before';
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

# the same, for setup.pl. setup_menu is classed 'read', so this GET needs no
# token of its own. Harvested from setup.pl's own panel rather than reused from
# config.pl: tokens are per user, not per script, but a browser gets the token
# from the form it is about to submit, and a panel that failed to render for this
# user would show up here rather than as a puzzling 403 further down.
sub fresh_setup_csrf
{
	$t->get_ok('/cgi-nmis9/setup.pl?conf=Config&act=setup_menu&widget=false');
	my $tok = $t->tx->res->dom->at('input[name="csrf_token"]');
	$tok = $tok && $tok->attr('value');
	BAIL_OUT("could not harvest a CSRF token from the setup panel; the session is "
			 . "not authenticated or setup.pl did not render, so no S case below "
			 . "would prove anything") if (!$tok);
	return $tok;
}

# a setup.pl submission. The real panel posts a fixed set of option/<section>/
# <item> parameters and renders a control for none of the protected keys, so any
# protected parameter here is hand-built - which is the whole point.
sub post_setup
{
	my (%p) = @_;
	my $form = { conf => 'Config', widget => 'false', act => 'setup_doedit',
				 csrf_token => fresh_setup_csrf(), %p };
	$t->post_ok('/cgi-nmis9/setup.pl' => form => $form);
	return ($t->tx->res->code // 0, $t->tx->res->body // '');
}

# OMK-12926: a value that was posted must not come back in the rendered response.
#
# index(), never a regex: Test::More puts the pattern into the test name and the
# operand into unlike()'s diagnostics, so a regex-based version would print the
# submitted value straight into the CI log. On this test the value is only an
# attacker-chosen path, but the same handlers render submitted passwords (see
# t_cgi_config_password_refusals.t), so the assertion is written to the same
# discipline and never names the needle.
#
# $marker is the anti-vacuity guard. index() < 0 is just as true of an empty
# body, a truncated one or an error page, so every caller names a string the
# response MUST contain before "the value is not in it" proves anything.
sub assert_no_reflection
{
	my ($body, $needle, $marker, $desc) = @_;

	ok(index($body, $marker) >= 0, "$desc: the response is the page it should be")
			or diag("marker '$marker' is missing from a " . length($body)
							. " byte body, so the reflection check below would be vacuous");
	ok(index($body, $needle) < 0,
		 "$desc: the submitted value appears nowhere in the response body")
			or diag("the submitted value is echoed back into the " . length($body)
							. " byte response; it is deliberately not reproduced here. The "
							. "form's action attribute is the place to look.");
}

# The same defect from the other side, asserted structurally. CGI.pm's start_form
# defaults the action to request_uri || self_url, and self_url reserialises EVERY
# parameter of the request - POSTed ones included - into that URL. Pinning "the
# form's action has no query string" catches the reflection of any parameter, not
# only the ones these cases happen to submit.
sub assert_clean_form_action
{
	my ($dom, $formid, $script, $desc) = @_;

	my $form = $dom->at("form#$formid");
	if (!$form)
	{
		fail("$desc: the response carries the $formid form");
		return;
	}
	my $action = $form->attr('action') // '';
	# the diagnostics print the path only - everything after the '?' is exactly
	# the material that must not be echoed anywhere, this test's output included.
	my ($path) = split(/\?/, $action, 2);
	ok(index($action, '?') < 0, "$desc: the $formid form action carries no query string")
			or diag("action path is '$path', followed by a "
							. (length($action) - length($path) - 1)
							. " byte query string that is not printed here");
	like($path, qr{/\Q$script\E$}, "$desc: and the action still points at $script");
}

# the one refusal phrase every handler shares, in config.pl and setup.pl alike
my $PROTECTED = qr/not editable through the GUI \(protected key\)/;
# markers for assert_no_reflection: strings each page always renders
my $CFG_MARKER   = 'NMIS Configuration';
my $SETUP_MARKER = 'Welcome to the NMIS Setup interface!';
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
# reversed. Asserted on a clean GET: until OMK-12926 that was a necessity, because
# a refusal response echoed the posted parameters back into the form's self_url
# action and the key name would have been "found" in the page for the wrong
# reason. The echo is gone, but a GET is still the honest way to ask what the
# table renders, so this stays where it is.

{
	$t->get_ok('/cgi-nmis9/config.pl?conf=Config&act=config_nmis_menu&section=system&widget=false');
	my $body = $t->tx->res->body // '';
	is($t->tx->res->code, 200, "display: the system section renders");
	like($body, qr/\Q$PROBE_EDIT\E/,
		 "display: an ordinary system key IS rendered, so the table really drew")
			or diag("response was: " . substr($body, 0, 800));
	unlike($body, qr/master_key_file/,
		   "display: master_key_file is not rendered in the config table");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "display");
}

# ---- D2: the other three config.pl forms carry clean actions too -------------
# OMK-12926 changed four start_form calls in config.pl. displayConfig's is proved
# by every case below, but editConfig's, addConfig's and deleteConfig's would
# otherwise be shipped untested. All three are GET-rendered read views that need
# no CSRF token of their own, so this costs three requests. They are the forms
# the write parameters are typed into, so a self_url action on any of them is the
# same latent echo, one submission earlier in the flow.

{
	my @forms = (["config_nmis_edit&section=system&item=$PROBE_EDIT", "editConfig"],
							 ["config_nmis_add&section=system", "addConfig"],
							 ["config_nmis_delete&section=system&item=$PROBE_DELETE", "deleteConfig"]);
	for my $f (@forms)
	{
		my ($query, $desc) = @$f;
		$t->get_ok("/cgi-nmis9/config.pl?conf=Config&act=$query&widget=false");
		is($t->tx->res->code, 200, "D2 ($desc): the form renders");
		assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "D2 ($desc)");
	}
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
	assert_no_reflection($body, $ATTACKER_NEEDLE, $CFG_MARKER, "N1 (edit)");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "N1 (edit)");

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
	assert_no_reflection($body, $ATTACKER_NEEDLE, $CFG_MARKER, "N3 (add)");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "N3 (add)");

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
	assert_no_reflection($body, $ATTACKER_NEEDLE, $CFG_MARKER, "N4 (cross-section add)");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "N4 (cross-section add)");

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

# =============================================================================
# SETUP.PL - the fourth write route into the same file
# =============================================================================
# setup.pl's edit_config takes every posted option/<section>/<item> parameter and
# assigns it into the raw config before writeConfData. Same file, same two rights,
# same CSRF guard, different script - so a deny list that only config.pl consults
# leaves this route wide open.

$BASE_CONF = file_cksum($CONF_FILE);
$BASE_BAK  = file_cksum($CONF_BAK);

# ---- S1: setup.pl asked to repoint the master key, on its own ----------------

{
	my ($code, $body) = post_setup("option/system/master_key_file" => $ATTACKER);

	is($code, 200, "S1 (setup): the submission is answered, not refused by the CSRF guard");
	like($body, $PROTECTED, "S1 (setup): master_key_file is refused as a protected key")
			or diag("response was: " . substr($body, 0, 800));
	assert_no_reflection($body, $ATTACKER_NEEDLE, $SETUP_MARKER, "S1 (setup)");
	assert_clean_form_action($t->tx->res->dom, 'nmissetup', 'setup.pl', "S1 (setup)");

	my ($flat, $local) = reload();
	is($flat->{master_key_file}, $SENTINEL, "S1 (setup): the effective master key is unchanged");
	is($local->{system}{master_key_file}, $SENTINEL,
	   "S1 (setup): and conf/Config.nmis still names the sentinel");
	is(file_cksum($CONF_FILE), $BASE_CONF, "S1 (setup): conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "S1 (setup): conf/Config.nmis.bak was not written");
}

# ---- S2: the same route, an unprotected key ----------------------------------
# The positive control for S1: without it, a 403, a dead route or a typo in the
# parameter name would produce "nothing was written" and read as a pass.

{
	my ($code, $body) = post_setup("option/system/$PROBE_SETUP" => $PROBE_APPLIED);

	is($code, 200, "S2 (setup control): the submission is answered");
	unlike($body, $PROTECTED, "S2 (setup control): an unprotected key is not refused")
			or diag("response was: " . substr($body, 0, 800));
	unlike($body, $ANY_ERROR, "S2 (setup control): and no error bar was rendered at all");
	# OMK-12926 on a SUCCESS response, which is the harder half: the panel renders
	# controls for a fixed dozen properties and this probe is not one of them, so
	# the only way the submitted value can be in this page at all is the form's
	# action URL.
	assert_no_reflection($body, $PROBE_APPLIED, $SETUP_MARKER, "S2 (setup control)");
	assert_clean_form_action($t->tx->res->dom, 'nmissetup', 'setup.pl', "S2 (setup control)");

	my (undef, $local) = reload();
	is($local->{system}{$PROBE_SETUP}, $PROBE_APPLIED,
	   "S2 (setup control): the value WAS written - so S1's refusal is a refusal, "
	   . "not an inert route");
	isnt(file_cksum($CONF_FILE), $BASE_CONF, "S2 (setup control): conf/Config.nmis WAS written");
}

$BASE_CONF = file_cksum($CONF_FILE);
$BASE_BAK  = file_cksum($CONF_BAK);

# ---- S3: one submission carrying both ----------------------------------------
# The real shape of this route: the panel posts everything at once. Refusing the
# whole request would let one hand-built parameter discard every other setting
# the operator just typed, so the refusal has to be per item - and it still has
# to be visible, or the operator walks away believing the protected item took.

{
	my ($code, $body) = post_setup("option/system/master_key_file" => $ATTACKER,
								   "option/system/$PROBE_SETUPMIX"  => $PROBE_APPLIED);

	is($code, 200, "S3 (mixed): the submission is answered");
	like($body, $PROTECTED, "S3 (mixed): the refusal is reported to the operator")
			or diag("response was: " . substr($body, 0, 800));
	# inside the error bar specifically, and it stays that way. Until OMK-12926
	# this anchoring was load-bearing - display_setup re-rendered the form with the
	# posted parameters echoed into its self-referencing action URL, so a bare
	# /master_key_file/ over the whole body passed on nothing at all. The echo is
	# gone now (the two assertions below pin that), but the anchored form is the
	# stronger statement either way, so it stays.
	like($body, qr/class="Fatal"[^>]*>Error:[^<]*master_key_file/,
		 "S3 (mixed): and the error bar names the item that was dropped");
	assert_no_reflection($body, $ATTACKER_NEEDLE, $SETUP_MARKER, "S3 (mixed, refused item)");
	assert_no_reflection($body, $PROBE_APPLIED, $SETUP_MARKER, "S3 (mixed, applied item)");
	assert_clean_form_action($t->tx->res->dom, 'nmissetup', 'setup.pl', "S3 (mixed)");

	my ($flat, $local) = reload();
	is($flat->{master_key_file}, $SENTINEL, "S3 (mixed): the master key is unchanged");
	is($local->{system}{master_key_file}, $SENTINEL,
	   "S3 (mixed): and conf/Config.nmis still names the sentinel");
	is($local->{system}{$PROBE_SETUPMIX}, $PROBE_APPLIED,
	   "S3 (mixed): the unprotected item in the SAME submission was still applied");
}

done_testing();
