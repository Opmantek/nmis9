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
# OMK-12827 Slice B: behavioural coverage for the two password refusals
# cgi-bin/config.pl's doEditConfig gained (PR 73 review, Critical 3).
#
#   1. an empty password submission is refused ("password cannot be empty"),
#      and nothing is written;
#   2. a non-empty password that did not encrypt while encryption is enabled is
#      refused, naming the master key, and nothing is written. encrypt() fails
#      closed by returning its input unchanged, so without this refusal the
#      editor would happily persist a secret in plaintext while the operator
#      believed encryption was on;
#   3. the positive control: the same submission with a working master key is
#      accepted and the stored value is ciphertext.
#
# Case 3 is what makes cases 1 and 2 mean anything. Both refusals are rendered
# by the same generic "Error: ... failed to validate: ..." bar, and an aborted
# request, a failed login or a broken fixture would also leave the config
# unwritten - so "nothing was written" on its own proves nothing. The three
# cases share one fixture and one session, and only the refusal text and the
# master key's existence differ between them.
#
# Driven through the real CGI in-process via the NMISx Mojolicious app on a real
# authenticated session, per docs/CGI_TESTING.md; reading cgi-bin/config.pl as
# text is the documented anti-pattern. The edit form is fetched, parsed and
# posted back the way a browser would, so the act, the section/item addressing
# and the CSRF token all come from the page rather than being hand-built.
#
# Field under test: email / mail_password. doEditConfig applies the two refusals
# to exactly two items, database/db_password and email/mail_password. It has to
# be mail_password: db_password carries validate => { regex => qr/^.+$/ } in
# Table-Config.nmis, so an empty db_password is refused by the regex rule long
# before the emptiness check, and nothing in this test's environment reads
# mail_password, so writing it cannot break the run it is running in.
#
# Isolation. docs/CGI_TESTING.md prescribes the fixture mechanism: "Seed hostile
# or config values into the untracked conf/Config.nmis override ... Back up
# first and restore in an END block, so a hard kill can only leave an untracked
# file behind." That is what this test does, and it is not a matter of taste
# here: Mojolicious::Plugin::CGI forks and then EXECs the script
# (/usr/share/perl5/Mojolicious/Plugin/CGI.pm, sub _child: "exec
# $args->{script}"), so the CGI is a fresh interpreter. No amount of
# monkey-patching NMISNG::Util in the test process can reach doEditConfig, and a
# spy that recorded nothing would make cases 1 and 2 pass vacuously. The write
# is therefore observed where it really happens: on conf/Config.nmis, whose md5
# must be unchanged for the two refusals and changed for the positive control.
#
# The three settings that shape the run are ENV config overrides (loadConfTable
# layer 4), set before anything loads config and before the app boots, because
# Mojolicious::Plugin::CGI snapshots %ENV into %ORIGINAL_ENV when it is loaded
# and hands that snapshot to the exec'd child:
#
#   NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION - refusal 2 only exists when
#       encryption is enabled.
#   NMIS_MASTER_KEY_FILE - an isolated key path in a temp dir, so the shipped
#       /usr/local/etc/firstwave/master.key is never touched, moved or read.
#       _resolve_seed stats this path on every call and never creates a key at a
#       custom location, so the file's existence can be flipped mid-run: absent
#       for phase A (cases 1 and 2), present for phase B (case 3). The config
#       cache pins the path, not the file's state.
#   NMIS_DB_PASSWORD - see below.
#
# Being ENV-managed also keeps all three out of the file: writeConfData skips
# layer-4 keys whose value has not changed, so the temp key path and the
# encryption flag can never be persisted into conf/Config.nmis by the save under
# test.
#
# NMIS_DB_PASSWORD exists to keep the "nothing was written" assertions honest.
# With encryption enabled, every DB connect calls
# decrypt($C->{db_password}, 'database', 'db_password'), which re-encrypts a
# plaintext value and writeConfData's it straight back into conf/Config.nmis -
# in this process and in the forked CGI alike. Promoting db_password to a
# layer-4 override makes writeConfData refuse that particular write, so the only
# thing that can change conf/Config.nmis during the run is the save under test.
#
# Needs a reachable MongoDB and the NMISx app, i.e. the dev container; it skips
# cleanly elsewhere. In a MongoDB-configured environment the crypto modules are
# a prerequisite it fails loudly on rather than skipping over, because a skip
# there is a silent green over a security path that never ran. It seeds and
# restores a throwaway admin in conf/Users.nmis + conf/users.dat, backs up and
# restores conf/Config.nmis and conf/Config.nmis.bak, and removes its temp key.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp ();

my $KEYFILE;
BEGIN {
	# must be set before ANY config load and before the app boots. A temp dir,
	# never the shipped key location: this test must not be able to create,
	# replace or delete the real master key, and _resolve_seed refuses to create
	# a key at a non-default path, which is exactly the "absent" state phase A
	# needs.
	my $keydir = File::Temp::tempdir("omk12827-cfgpw-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	$KEYFILE = "$keydir/master.key";
	$ENV{NMIS_MASTER_KEY_FILE} = $KEYFILE;
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
}

use Test::More;
use File::Copy;
use Digest::MD5 ();
use Crypt::PasswdMD5 qw(apache_md5_crypt);

use NMISNG::Util;

# ---- seed a throwaway admin, so login never depends on nmis/nm1888 ----------
# The dev/CI entrypoint re-seeds the built-in "nmis" account's password from
# NMIS_ADMIN_PASSWORD (docker-dev/.env-dev), so nm1888 does not authenticate in
# the container. A failed login here would be near silent: the request would run
# unauthenticated, the edit form would render without the password fields and no
# save would happen, which surfaces as "no write" - i.e. as a PASS for cases 1
# and 2. Seed our own administrator into the UNTRACKED conf/Users.nmis and
# conf/users.dat instead, exactly as t_csrf_cgi.t and
# t_cgi_tables_secret_passthrough.t do, and restore both in END. Must run before
# the app boots so the forked CGI reads the seeded account.

my $TESTUSER = 't12827_cfgpw_admin';
my $TESTPASS = 't12827-cfgpw-' . $$;

my $CONFDIR  = "$FindBin::Bin/../conf";
my $USERSCFG = "$CONFDIR/Users.nmis";
my $USERSDAT = "$CONFDIR/users.dat";

my ($CFGBAK, $DATBAK);
if (-f $USERSCFG && -f $USERSDAT)
{
	$CFGBAK = "$USERSCFG.t12827cfgpwbak";
	$DATBAK = "$USERSDAT.t12827cfgpwbak";
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

# The three encryption modules are declared install dependencies (since 9.4.5)
# and ship in the dev/CI image. Reaching this line means MongoDB is configured,
# so we are in the container, where they MUST be present. A missing module here
# is a real regression, not a bare-host condition, so FAIL LOUDLY: encrypt()
# returns its input unchanged when they are absent, which would make phase B
# indistinguishable from phase A and quietly turn the positive control into a
# second copy of case 2.
my @missing = grep { !eval "require $_; 1" }
		qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure);
if (@missing)
{
	fail("encryption modules present in this MongoDB-configured environment");
	diag("missing: " . join(", ", @missing)
			 . " - install: apt-get install -y libcrypt-cbc-perl libcryptx-perl "
			 . "libmath-random-secure-perl. Without them the positive control cannot "
			 . "encrypt anything and this must go red rather than skip to a false green.");
	done_testing();
	exit;
}

# The env overrides are the test's own premise, so a miss is a failure, not a
# skip - a skip would hide that the refusal path never ran.
if (!NMISNG::Util::getbool($C->{global_enable_password_encryption}))
{
	fail("NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION env override did not enable encryption");
	diag("global_enable_password_encryption resolved to '"
			 . ($C->{global_enable_password_encryption} // 'undef')
			 . "'; the encrypt-failure refusal only exists when encryption is enabled");
	done_testing();
	exit;
}
if (($C->{master_key_file} // '') ne $KEYFILE)
{
	fail("NMIS_MASTER_KEY_FILE env override did not take effect");
	diag("master_key_file resolved to '" . ($C->{master_key_file} // 'undef')
			 . "', wanted '$KEYFILE'; without it this test would be operating on the "
			 . "shipped master key, which it must never touch");
	done_testing();
	exit;
}

# ---- keep the encryption-on DB connect from rewriting conf/Config.nmis ------
# See the header. Derive the value from the EFFECTIVE loaded config rather than
# a regex over the file, so a value inherited from conf-default or written in
# any quoting is covered. Only a plaintext value needs this; an already-'!!'
# value is not re-encrypted.
{
	my $src   = NMISNG::Util::getConfigSources(key => 'db_password');
	my $pw    = $C->{db_password};
	my $plain = (defined $pw && $pw ne '' && substr($pw, 0, 2) ne '!!');
	if ($plain && (!$src || ($src->{layer} // 0) != 4))
	{
		$ENV{NMIS_DB_PASSWORD} = $pw;               # inherited by the forked CGI
		$NMISNG::Util::_config_cache_invalid = 1;
		$C = NMISNG::Util::loadConfTable();         # reload: db_password now layer 4
		$src = NMISNG::Util::getConfigSources(key => 'db_password');
	}
	if ($plain && (!$src || ($src->{layer} // 0) != 4))
	{
		BAIL_OUT("could not force db_password to be ENV-managed; refusing to run "
				 . "because the encryption-on DB connect would rewrite conf/Config.nmis "
				 . "and every 'nothing was written' assertion below would be worthless");
	}
}

# ---- back up the config this test is allowed to write, per CGI_TESTING.md ---
# writeConfData copies the live file to <file>.bak before writing, so both must
# be captured and both restored, including the "was absent" case.
#
# Content is not enough. writeConfData replaces the file rather than rewriting
# it in place, so the new one carries the CGI's uid/gid and umask - and NMIS
# ships its config group-writable on purpose, so httpd (a member of the nmis
# group) can edit it. Restoring the bytes but leaving root:root 0644 behind
# would silently take the GUI's write access away. Capture mode and ownership
# and put them back too; the chown is best effort, since a non-root run cannot
# give a file away and does not need to (it never took the ownership away).

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

my $CONF_SAVED = save_file($CONF_FILE, ".t12827cfgpwbak");
my $BAK_SAVED  = save_file($CONF_BAK, ".t12827cfgpwbak");

END {
	restore_file($CONF_SAVED, $CONF_FILE);
	restore_file($BAK_SAVED, $CONF_BAK);
	# writeConfData creates the .bak; if there was none before us, leave none behind
	unlink $CONF_BAK if (!$BAK_SAVED && -f $CONF_BAK);
	unlink $KEYFILE  if ($KEYFILE && -f $KEYFILE);
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

# Parse a rendered CGI form into the parameters a browser would post back, so
# the act, the CSRF token and the section/item addressing come from the page.
sub harvest_form
{
	my ($dom) = @_;
	my %form;

	for my $i ($dom->find('input[name]')->each)
	{
		# buttons are only submitted when clicked, and these are onclick-driven
		next if (lc($i->attr('type') // 'text') =~ /^(button|submit|reset|image)$/);
		$form{$i->attr('name')} = $i->attr('value') // '';
	}
	for my $s ($dom->find('select[name]')->each)
	{
		my @sel = map { $_->attr('value') // $_->text } $s->find('option[selected]')->each;
		if (!@sel)
		{
			my $first = $s->find('option')->first;
			@sel = ($first ? ($first->attr('value') // $first->text) : '');
		}
		$form{$s->attr('name')} = $sel[0];
	}
	return \%form;
}

# note: Test::Mojo's *_ok request helpers hand every extra argument to build_tx,
# so they take no description of their own - the assertions carry it.
sub fetch_edit_form
{
	my ($desc) = @_;
	$t->get_ok('/cgi-nmis9/config.pl?conf=Config&act=config_nmis_edit'
						 . '&section=email&item=mail_password&widget=false');
	is($t->tx->res->code, 200, "$desc: edit form HTTP 200");
	my $form = harvest_form($t->tx->res->dom);

	# fixture sanity, not decoration. If the password branch of editConfig is not
	# the one that rendered (no rule found, access filtered, item renamed), the
	# generic branch renders a single "value" textfield with no "confirm", every
	# submission below fails on "passwords don't match", and both refusals under
	# test are never reached - while cases 1 and 2 still see no config write and
	# pass.
	ok(exists $form->{value} && exists $form->{confirm},
		 "$desc: the password editor rendered both a value and a confirm field")
			or diag("harvested fields: " . join(",", sort keys %$form));
	is($form->{act}, 'config_nmis_doedit', "$desc: the form submits the doedit act");
	is($form->{section}, 'email', "$desc: addressed at the email section");
	is($form->{item}, 'mail_password', "$desc: addressed at mail_password");
	ok($form->{csrf_token}, "$desc: the form carries a CSRF token");
	# OMK-12926: this is the form the password is typed into, and editConfig builds
	# it with the same start_form idiom displayConfig uses. Nothing secret is in
	# the GET that produced it, but a self_url action here would echo the whole
	# addressing query string back and is the same latent defect, so pin it too.
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', $desc);

	$form->{conf} = 'Config';   # as the GET carried it
	return $form;
}

sub submit
{
	my ($form, $value) = @_;
	$form->{value} = $form->{confirm} = $value;
	$t->post_ok('/cgi-nmis9/config.pl' => form => $form);
	return ($t->tx->res->code // 0, $t->tx->res->body // '');
}

# OMK-12926: a submitted secret must not come back in the rendered response.
#
# index(), never a regex. Test::More puts the pattern into the test name and the
# operand into unlike()'s diagnostics, so a regex-based version of this assertion
# would print the password into the test output and the CI log - which is the
# very disclosure it exists to catch. Nothing here ever names the needle.
#
# $marker is the anti-vacuity guard, and it is not decoration: index() < 0 is
# just as true of an empty body, a truncated one or an error page, so each caller
# names a string the response MUST contain before "the secret is not in it" means
# anything at all.
#
# The two fixture passwords are deliberately built from URL-unreserved characters
# only ([A-Za-z0-9-]), so they pass through CGI.pm's query escaping and its HTML
# escaping byte for byte. A plain substring search therefore cannot miss a
# reflection because of encoding - keep that property if either value is changed.
sub assert_no_reflection
{
	my ($body, $secret, $marker, $desc) = @_;

	ok(index($body, $marker) >= 0, "$desc: the response is the page it should be")
			or diag("marker '$marker' is missing from a " . length($body)
							. " byte body, so the reflection check below would be vacuous");
	ok(index($body, $secret) < 0,
		 "$desc: the submitted password appears nowhere in the response body")
			or diag("the submitted value is echoed back into the " . length($body)
							. " byte response; it is deliberately not reproduced here. The "
							. "form's action attribute is the place to look.");
}

# The same defect from the other side, asserted structurally. CGI.pm's start_form
# defaults the action to request_uri || self_url, and self_url reserialises EVERY
# parameter of the request - POSTed ones included - into that URL. Pinning "the
# form's action has no query string" catches the reflection of any parameter, not
# only the one this test happens to submit, and it stays meaningful if the
# fixture password ever changes.
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

# the two refusals, and the third thing neither of them is
my $EMPTY_REFUSAL  = qr/'mail_password' failed to validate: password cannot be empty/;
my $CRYPTO_REFUSAL = qr/'mail_password' failed to validate: password could not be encrypted/;
my $ANY_ABORT      = qr/failed to validate/;

# ---- authenticate through the real app --------------------------------------

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $TESTUSER, auth_password => $TESTPASS });
# a cookie alone proves nothing: an unauthenticated response still sets a session
# cookie, so assert the body is the app, not the login page.
unlike($t->tx->res->body // '', qr/Invalid username\/password/,
	   "authenticated session established as $TESTUSER");

# =============================================================================
# PHASE A - the master key does not exist, so encryption is enabled but broken
# =============================================================================

ok(!-e $KEYFILE, "phase A precondition: the master key file does not exist");

# Prove the broken state is real before asserting anything about it. encrypt
# fails closed by returning its input unchanged, and that is precisely the
# condition doEditConfig's second refusal exists to catch.
my $CRYPTO_PLAIN = 'BrokenKeyPass-OMK12827';
is(NMISNG::Util::encrypt($CRYPTO_PLAIN), $CRYPTO_PLAIN,
	 "phase A precondition: with no master key, encrypt fails closed and returns the plaintext");

my $BASE_CONF = file_cksum($CONF_FILE);
my $BASE_BAK  = file_cksum($CONF_BAK);
isnt($BASE_CONF, 'ABSENT', "baseline: conf/Config.nmis exists to be watched");

# ---- case 1: an empty password is refused, and nothing is written -----------

{
	my $form = fetch_edit_form("case 1 (empty)");
	my ($code, $body) = submit($form, '');

	is($code, 200, "case 1: the empty submission is answered, not refused by the CSRF guard");
	like($body, $EMPTY_REFUSAL, "case 1: an empty password is refused as empty");
	# the disambiguator: both refusals render through the same error bar, so a
	# case that fell through to the crypto branch would look identical without
	# this. It also pins WHICH check fired, so a future reordering that let the
	# crypto refusal swallow the empty case shows up here.
	unlike($body, $CRYPTO_REFUSAL,
		   "case 1: refused for emptiness specifically, not by the encrypt-failure check");

	# nothing secret was submitted here, but the mechanism is the same one, so the
	# structural half of the OMK-12926 check applies to this response too.
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "case 1");

	is(file_cksum($CONF_FILE), $BASE_CONF, "case 1: conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "case 1: conf/Config.nmis.bak was not written");
}

# ---- case 2: a password that cannot be encrypted is refused, nothing written -

{
	my $form = fetch_edit_form("case 2 (crypto broken)");
	my ($code, $body) = submit($form, $CRYPTO_PLAIN);

	is($code, 200, "case 2: the submission is answered, not refused by the CSRF guard");
	like($body, $CRYPTO_REFUSAL,
		 "case 2: a password that did not encrypt is refused");
	# the branch fingerprint: only this refusal names the master key and says the
	# value was not saved. Nothing else in the response can produce these.
	like($body, qr/master key \(config 'master_key_file'\)/,
		 "case 2: and the refusal names the master key, so it is that branch that fired");
	like($body, qr/The value was NOT saved/,
		 "case 2: and says the value was not saved");
	unlike($body, $EMPTY_REFUSAL,
		   "case 2: refused for the encryption failure, not for emptiness");

	# OMK-12926, found while writing this test and fixed on that ticket: the
	# submitted password used to come back in cleartext in the response, in the
	# form's action URL. displayConfig called start_form without an -action, so
	# CGI.pm defaulted it to request_uri || self_url; where the gateway leaves
	# REQUEST_URI unset - as Mojolicious::Plugin::CGI does, and as this test
	# therefore demonstrated - self_url wins, and CGI.pm's query_string()
	# reserialises every parameter of the request, POSTed ones included, into that
	# URL. It happened on the refusal responses and on the successful one alike.
	assert_no_reflection($body, $CRYPTO_PLAIN, 'failed to validate', "case 2");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "case 2");

	is(file_cksum($CONF_FILE), $BASE_CONF, "case 2: conf/Config.nmis was not written");
	is(file_cksum($CONF_BAK), $BASE_BAK, "case 2: conf/Config.nmis.bak was not written");
}

# =============================================================================
# PHASE B - provide a working master key; the same submission must now succeed
# =============================================================================
# _resolve_seed stats master_key_file on every call and the config cache pins
# only the path, so creating the file here flips encrypt's behaviour for the
# rest of this process and for every CGI forked from it. Mode 0400: _resolve_seed
# refuses a group- or world-writable key outright and warns about a
# world-readable one.

{
	my @cs   = ('A'..'Z', 'a'..'z', 0..9);
	my $seed = join '', map { $cs[int(Math::Random::Secure::rand(scalar @cs))] } (1..256);
	open(my $kh, '>', $KEYFILE)
			or BAIL_OUT("cannot create the isolated master key at $KEYFILE: $!");
	print $kh $seed;
	close $kh;
	chmod(0400, $KEYFILE);
}

ok(-f $KEYFILE, "phase B precondition: the master key file now exists");

my $GOOD_PLAIN = 'WorkingKeyPass-OMK12827';
{
	# the mirror image of the phase A probe: same process, same config cache,
	# only the file's existence changed.
	my $probe = NMISNG::Util::encrypt($GOOD_PLAIN);
	like($probe, qr/^!!/, "phase B precondition: encrypt now produces ciphertext");
	is(NMISNG::Util::decrypt($probe), $GOOD_PLAIN,
		 "phase B precondition: and it decrypts back with the same key");
}

# ---- case 3: the positive control -------------------------------------------

{
	my $form = fetch_edit_form("case 3 (positive control)");
	my ($code, $body) = submit($form, $GOOD_PLAIN);

	is($code, 200, "case 3: the submission is answered");
	unlike($body, $ANY_ABORT,
		   "case 3: the identical submission is accepted once the key works")
			or diag("response was: " . substr($body, 0, 800));

	# OMK-12926 on the success path. This is the response that matters most: the
	# save worked, the operator is looking at the config table, and the password
	# they just typed used to be sitting in the page's form action in cleartext.
	# The stored value is ciphertext and typeSect masks password rows, so the
	# action URL is the only way the plaintext can be here at all.
	assert_no_reflection($body, $GOOD_PLAIN, 'NMIS Configuration', "case 3");
	assert_clean_form_action($t->tx->res->dom, 'nmisconfig', 'config.pl', "case 3");

	isnt(file_cksum($CONF_FILE), $BASE_CONF,
		 "case 3: conf/Config.nmis WAS written - so the unchanged checksums above "
		 . "are a refusal, not an inert fixture");

	# and the write carries ciphertext, not the plaintext that was typed
	$NMISNG::Util::_config_cache_invalid = 1;
	my ($deep) = NMISNG::Util::getConfDeep(only_local => 1);
	my $stored = $deep->{email}->{mail_password};

	ok(defined($stored), "case 3: mail_password is now set in conf/Config.nmis");
	like($stored // '', qr/^!!/, "case 3: and it was stored as ciphertext");
	isnt($stored // '', $GOOD_PLAIN, "case 3: and not as the plaintext that was typed");
	is(NMISNG::Util::decrypt($stored // ''), $GOOD_PLAIN,
		 "case 3: and it decrypts back to what was submitted");
}

done_testing();
