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
# OMK-12827 item 5: the table editor must not decrypt stored secrets.
#
# cgi-bin/tables.pl used to decrypt any password-flagged field whose submitted
# value still carried the "!!" ciphertext prefix, validate the plaintext, then
# re-encrypt it. A "!!" value arriving means the edit form round-tripped the
# stored value and the user never touched it, so that decrypt validated a value
# nobody typed - and it was the only reason the web tier had to be able to READ
# every secret in the tree, all six device SNMP/WMI credentials included.
#
# The observable property, and what this test asserts: after a no-op edit, every
# stored secret is byte-identical to what was stored before. NMISNG::Util::encrypt
# is randomised (Crypt::CBC picks a fresh IV per call), so a decrypt/re-encrypt
# round trip cannot reproduce the original ciphertext. Byte-identity is therefore
# a direct behavioural witness that no decrypt happened. Against the unfixed code
# this file fails on those assertions, with a different ciphertext stored.
#
# Driven through the real CGI in-process via the NMISx Mojolicious app on a real
# authenticated session, per docs/CGI_TESTING.md; source inspection is the
# documented anti-pattern. The form is not hand-built - it is fetched, parsed and
# posted back the way a browser would, which is what makes it a genuine round trip.
#
# Needs a reachable MongoDB and the NMISx app. In a MongoDB-configured environment
# the encryption modules and a master.key are prerequisites the test provides or
# fails loudly on, never skips over. It seeds and removes one node, seeds and
# restores a throwaway admin in conf/Users.nmis + conf/users.dat, and manages an
# isolated master.key, all restored or removed in END so the disk is left as it was
# found. It does NOT modify conf/Config.nmis: db_password is promoted to a layer-4
# ENV override (from the effective loaded value, just before the DB connect) so the
# encryption-on connect cannot re-encrypt it back into the file, in this process or
# the forked CGI - and a before/after checksum of conf/Config.nmis fails the run red
# if anything writes it anyway.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

# The path under test is reachable ONLY with password encryption enabled. With it
# disabled, NMISNG::Node::new (lib/NMISNG/Node.pm, the "else" migration branch)
# decrypts every stored secret and writes it back as plaintext, so no node ever
# holds a "!!" value for the form to round-trip. Enable it through the NMIS_*
# config env override (loadConfTable layer 4) rather than by editing conf/: nothing
# on disk changes, so a hard kill cannot leave the install reconfigured, and the
# CGI that Plugin::CGI forks inherits the setting. Must run before any config load.
BEGIN { $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true'; }

use Test::More;
use Test::Mojo;
use File::Copy;
use File::Path ();
use Digest::MD5 ();
use Crypt::PasswdMD5 qw(apache_md5_crypt);

use NMISNG;
use NMISNG::Log;
use NMISNG::Node;
use NMISNG::Util;

my $NODENAME = "t_12827_secret_node";

# ---- seed a throwaway admin, so login never depends on nmis/nm1888 ----------
# The dev/CI entrypoint re-seeds the built-in "nmis" account's password from
# NMIS_ADMIN_PASSWORD (docker-dev/.env-dev), so nm1888 does not authenticate in
# the container. A failed login is silent here: the request runs unauthenticated,
# the edit form renders without the secret fields and no save persists, which
# surfaces downstream as confusing "form rendered undef" and "edit not saved"
# failures rather than a login error. Seed our own administrator into the
# UNTRACKED conf/Users.nmis and conf/users.dat instead, exactly as t_csrf_cgi.t
# does, and restore both in END. Must run before the app boots so the forked CGI
# reads the seeded account.
my $TESTUSER = 't12827_secret_admin';
my $TESTPASS = 't12827-secret-' . $$;

my $CONFDIR  = "$FindBin::Bin/../conf";
my $USERSCFG = "$CONFDIR/Users.nmis";
my $USERSDAT = "$CONFDIR/users.dat";

my ($CFGBAK, $DATBAK);
if (-f $USERSCFG && -f $USERSDAT)
{
	$CFGBAK = "$USERSCFG.t12827bak";
	$DATBAK = "$USERSDAT.t12827bak";
	copy($USERSCFG, $CFGBAK);
	copy($USERSDAT, $DATBAK);

	open(my $in, '<', $USERSCFG) or die "cannot read $USERSCFG: $!";
	my $txt = do { local $/; <$in> };
	close $in;
	# a seeding miss must say so, rather than resurfacing later as a login failure
	# that reads like a product bug.
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

# One distinct plaintext per secret field, so a field mix-up cannot pass unnoticed.
# These are the six fields Table-Nodes.nmis marks display => 'password'.
my %SECRET = (
	community    => "Commun1ty-OMK12827",
	wmipassword  => "WmiPass-OMK12827",
	authpassword => "AuthPass-OMK12827",
	authkey      => "AuthKey-OMK12827",
	privpassword => "PrivPass-OMK12827",
	privkey      => "PrivKey-OMK12827",
);
my @SECRET_FIELDS = sort keys %SECRET;

# ---- guards: skip cleanly off the dev container, but never silently ----------

my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});
plan skip_all => "could not seed the test admin under conf/ (bare host?)" unless $CFGBAK;

# The three encryption modules are declared install dependencies (since 9.4.5) and
# now ship in the dev/CI image. Reaching this line means MongoDB is configured, so
# we are in the container, where they MUST be present. A missing module here is a
# real regression, not a bare-host condition, so FAIL LOUDLY rather than skip: a
# skip_all here is a silent green that hides the fact this security path never ran,
# which is exactly how the gap went unnoticed before. NMISNG::Util::encrypt returns
# its input unchanged when they are absent, so without them the fixture would be
# plaintext and every assertion below would pass vacuously.
my @missing = grep { !eval "require $_; 1" }
		qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure);
if (@missing)
{
	fail("encryption modules present in this MongoDB-configured environment");
	diag("missing: " . join(", ", @missing)
			 . " - install: apt-get install -y libcrypt-cbc-perl libcryptx-perl "
			 . "libmath-random-secure-perl. Without them this security path cannot run, "
			 . "and it must go red here rather than skip to a false green.");
	done_testing();
	exit;
}

# A failure here is not a missing dependency, it is the test's own premise breaking,
# so fail rather than skip - a skip would hide it.
if (!NMISNG::Util::getbool($C->{global_enable_password_encryption}))
{
	fail("NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION env override did not enable encryption");
	diag("global_enable_password_encryption resolved to '"
			 . ($C->{global_enable_password_encryption} // 'undef')
			 . "'; without it no node can hold a '!!' value and this test is meaningless");
	done_testing();
	exit;
}

# ---- ensure an isolated master.key exists, so encrypt/decrypt really run -------
# NMISNG::Util::encrypt/decrypt read /usr/local/etc/firstwave/master.key and, when
# it is absent, call _make_seed - which DIES for a non-root caller and, as root,
# creates a web-readable key and leaves it on disk. With encryption enabled the very
# next line (the DB connect) decrypts db_password and would trigger that, so this
# MUST run first. Leaning on the root side effect makes the test pass only by the
# accident of running as root, and mutates the host. Manage an isolated key instead:
# use an existing readable one untouched, else write a format-identical 256-char key
# (the read path takes the first line as the cipher key) and remove it in END so the
# disk is left as we found it. If no key exists and one cannot be created (non-root,
# unwritable dir), FAIL LOUDLY - never skip, a skip would hide that this did not run.
my $KEYFILE = '/usr/local/etc/firstwave/master.key';
my $KEYDIR  = '/usr/local/etc/firstwave';
my ($KEY_CREATED, $KEYDIR_CREATED);
if (!-r $KEYFILE)
{
	my $keydir_existed = -d $KEYDIR;
	File::Path::make_path($KEYDIR) unless $keydir_existed;   # recursive; parents too
	$KEYDIR_CREATED = 1 unless $keydir_existed;              # only remove what we made
	# 256 chars from [A-Za-z0-9], no trailing newline - identical shape to _make_seed.
	# Math::Random::Secure (required above) rather than core rand(), which OMK-12827
	# itself flags as an insecure seed source.
	my @cs   = ('A'..'Z', 'a'..'z', 0..9);
	my $seed = join '', map { $cs[int(Math::Random::Secure::rand(scalar @cs))] } (1..256);
	if (open(my $kh, '>', $KEYFILE))
	{
		print $kh $seed;
		close $kh;
		chmod(0644, $KEYFILE);
		$KEY_CREATED = 1;
	}
	else
	{
		BAIL_OUT("cannot create an isolated master.key at $KEYFILE ($!); this test "
				 . "needs a readable key - run it as root or in the dev container. It "
				 . "will not skip and report a false green.");
	}
}

END {
	unlink $KEYFILE if ($KEY_CREATED && -f $KEYFILE);
	rmdir  $KEYDIR  if ($KEYDIR_CREATED && -d $KEYDIR);
}

# ---- force db_password ENV-managed, then pin conf/Config.nmis against mutation ---
# With encryption on, the DB connect below decrypts db_password with section/keyword
# args, which re-encrypts a plaintext value and writeConfData's it back into
# conf/Config.nmis - in this process AND the forked CGI (pinned by NMISx to
# /usr/local/nmis9/conf, so it cannot be aimed elsewhere). Promote db_password to a
# layer-4 ENV override so writeConfData refuses the write in both. Derive the value
# from the EFFECTIVE loaded config, not a regex over the file, so a value inherited
# from conf-default's plaintext default or written in any quoting is covered. Only a
# plaintext value needs this (an already-'!!' value is not re-encrypted).
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
	# A plaintext db_password that is not provably ENV-managed would let the connect
	# rewrite conf/Config.nmis. Fail loud, never skip.
	if ($plain && (!$src || ($src->{layer} // 0) != 4))
	{
		BAIL_OUT("could not force db_password to be ENV-managed; refusing to run "
				 . "because the encryption-on DB connect would rewrite conf/Config.nmis");
	}
}

# Belt and braces: whatever the guard above does, conf/Config.nmis (and its .bak)
# must be byte-identical at the end. If it ever misses a config shape, this turns the
# run red rather than letting it go green while corrupting on-disk config.
my $CONF_FILE         = "$FindBin::Bin/../conf/Config.nmis";
my $CONF_BAK          = "$CONF_FILE.bak";
my $CONF_CKSUM_BEFORE = _file_cksum($CONF_FILE);
my $BAK_CKSUM_BEFORE  = _file_cksum($CONF_BAK);

my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = NMISNG->new(config => $C, log => $logger);
plan skip_all => "NMISNG object required" unless $nmisng;

my $t = eval { Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

# ---- helpers ----------------------------------------------------------------

# md5 of a file, or a distinct sentinel when absent, so "file created" is caught too.
sub _file_cksum
{
	my ($f) = @_;
	return 'ABSENT' unless -f $f;
	open(my $fh, '<', $f) or return "UNREADABLE:$!";
	local $/;
	my $data = <$fh>;
	close $fh;
	return Digest::MD5::md5_hex($data);
}

# Read the node straight out of the database. Deliberately NOT via
# NMISNG::Node->configuration: constructing a Node runs the encrypt/decrypt
# migration in Node::new, which would rewrite the very values under test.
sub stored_config
{
	my $md = $nmisng->get_nodes_model(filter => { name => $NODENAME });
	my $d  = $md->data();
	return undef if (!$d or !@$d);
	return $d->[0]->{configuration};
}

# Parse a rendered CGI form into the parameters a browser would post back.
sub harvest_form
{
	my ($dom) = @_;
	my %form;

	for my $i ($dom->find('input[name]')->each)
	{
		# buttons are only submitted when clicked, and these are onclick-driven
		next if (lc($i->attr('type') // 'text') =~ /^(button|submit|reset|image)$/);
		my $n = $i->attr('name');
		my $v = $i->attr('value') // '';
		$form{$n} = exists $form{$n}
				? [ (ref($form{$n}) eq 'ARRAY' ? @{$form{$n}} : $form{$n}), $v ]
				: $v;
	}
	for my $s ($dom->find('select[name]')->each)
	{
		my $n = $s->attr('name');
		my @sel = map { $_->attr('value') // $_->text } $s->find('option[selected]')->each;
		if (defined $s->attr('multiple'))
		{
			$form{$n} = (@sel > 1) ? [@sel] : (@sel ? $sel[0] : '');
		}
		else
		{
			# a browser submits the first option when the stored value is not in the
			# list and nothing is marked selected; several Table-Nodes popups validate
			# as onefromlist and would abort the save on an empty submission
			if (!@sel)
			{
				my $first = $s->find('option')->first;
				@sel = ($first ? ($first->attr('value') // $first->text) : '');
			}
			$form{$n} = $sel[0];
		}
	}
	for my $ta ($dom->find('textarea[name]')->each)
	{
		$form{$ta->attr('name')} = $ta->text // '';
	}
	return \%form;
}

# note: Test::Mojo's *_ok request helpers hand every extra argument to build_tx,
# so they take no description of their own - the assertions below carry it.
sub fetch_edit_form
{
	my ($desc) = @_;
	$t->get_ok("/cgi-nmis9/tables.pl?conf=Config&act=config_table_edit"
						 . "&table=Nodes&key=$NODENAME&widget=false");
	is($t->tx->res->code, 200, "$desc: edit form HTTP 200");
	return harvest_form($t->tx->res->dom);
}

sub submit_edit
{
	my ($form, $desc) = @_;
	$t->post_ok('/cgi-nmis9/tables.pl' => form => $form);
	is($t->tx->res->code, 200, "$desc: save HTTP 200");
	my $body = $t->tx->res->body // '';
	unlike($body, qr/class="error"/, "$desc: save reported no error")
			or diag("response was: " . substr($body, 0, 500));
}

# ---- seed a node holding real ciphertext in all six secret fields -----------

{
	my $old = $nmisng->node(name => $NODENAME);
	$old->delete(keep_rrd => 1) if ($old);
}

my %CIPHER = map { $_ => NMISNG::Util::encrypt($SECRET{$_}) } @SECRET_FIELDS;
for my $f (@SECRET_FIELDS)
{
	# fixture sanity: a real ciphertext that really decrypts back. If encrypt were
	# a no-op the pass-through assertions later would prove nothing.
	like($CIPHER{$f}, qr/^!!/, "fixture: $f seeded as ciphertext");
	isnt($CIPHER{$f}, $SECRET{$f}, "fixture: $f ciphertext differs from plaintext");
	is(NMISNG::Util::decrypt($CIPHER{$f}), $SECRET{$f}, "fixture: $f decrypts back to its plaintext");
}

my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$node->cluster_id($C->{cluster_id});
$node->name($NODENAME);
$node->configuration({
	host      => "127.0.0.1",
	group     => "NMIS8",
	netType   => "lan",
	roleType  => "access",
	model     => "automatic",
	# inactive on purpose: an active node gets an update job scheduled the moment it
	# appears, and that worker constructs an NMISNG::Node, whose migration branch
	# rewrites the stored secrets out from under this test
	active    => "false",
	collect   => "false",
	ping      => "false",
	threshold => "false",
	version   => "snmpv2c",
	notes     => "seeded",
	services  => [],
	depend    => [],
	%CIPHER,
});
my (undef, $saveerr) = $node->save();
BAIL_OUT("could not save seed node: $saveerr") if ($saveerr);

{
	my $seeded = stored_config();
	BAIL_OUT("seed node not readable from the database") if (!$seeded);
	is($seeded->{$_}, $CIPHER{$_}, "fixture: $_ stored as the seeded ciphertext")
			for (@SECRET_FIELDS);
}

# ---- authenticate through the real app --------------------------------------

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $TESTUSER, auth_password => $TESTPASS });
# a cookie alone proves nothing: an unauthenticated response still sets a session
# cookie, so assert the body is the app, not the login page. A silent login
# failure here is what made the real failure look like a form/save bug.
unlike($t->tx->res->body // '', qr/Invalid username\/password/,
	   "authenticated session established as $TESTUSER");

# ---- 1. the edit form really does hand the ciphertext back ------------------
# This is the precondition the fix relies on. If the form ever started rendering
# the plaintext instead, the pass-through assertions below would still pass while
# the secret leaked into the page, so assert it explicitly.

my $form = fetch_edit_form("round trip");
for my $f (@SECRET_FIELDS)
{
	is($form->{$f}, $CIPHER{$f}, "form: $f rendered as the stored ciphertext");
	isnt($form->{$f}, $SECRET{$f}, "form: $f not rendered as plaintext");
}

# ---- 2. a no-op edit stores every secret byte for byte ----------------------
# The only field changed is notes, which doubles as the positive control: if it
# comes back stored, the save really ran and an unchanged secret is not just the
# artefact of an aborted or no-op request.

$form->{act}   = 'config_table_doedit';
$form->{notes} = "edited-by-t12827";
submit_edit($form, "no-op secret edit");

my $after = stored_config();
BAIL_OUT("node vanished after the edit") if (!$after);

is($after->{notes}, "edited-by-t12827", "positive control: the edit was saved");

for my $f (@SECRET_FIELDS)
{
	# the assertion that fails against the unfixed code: it decrypts, re-encrypts,
	# and stores a different ciphertext for the same secret
	is($after->{$f}, $CIPHER{$f}, "$f survived a no-op edit byte for byte");
	isnt($after->{$f}, $SECRET{$f}, "$f was not written back as plaintext");
	like($after->{$f}, qr/^!!/, "$f is still ciphertext");
}

# ---- 3. a genuinely new secret is still encrypted on the way in -------------
# Guards against "fixing" the leak by making the field write-only or inert.

my $NEWPLAIN = "BrandNewCommunity-OMK12827";
my $form2 = fetch_edit_form("new secret");
$form2->{act}       = 'config_table_doedit';
$form2->{community} = $NEWPLAIN;
submit_edit($form2, "new secret edit");

my $after2 = stored_config();
BAIL_OUT("node vanished after the second edit") if (!$after2);

like($after2->{community}, qr/^!!/, "a newly typed community is stored encrypted");
isnt($after2->{community}, $NEWPLAIN, "a newly typed community is not stored as plaintext");
is(NMISNG::Util::decrypt($after2->{community}), $NEWPLAIN,
	 "the newly typed community decrypts back to what was typed");

# the untouched secrets must still be byte-identical after an edit that did change
# one of their siblings
for my $f (grep { $_ ne 'community' } @SECRET_FIELDS)
{
	is($after2->{$f}, $CIPHER{$f}, "$f untouched while a sibling secret was changed");
}

# ---- 4. the test must not have written conf/Config.nmis (round-4 review) -------
# Both the test process and the forked CGI decrypt db_password during their DB
# connects; with encryption on that path re-encrypts a plaintext value back into the
# file. The ENV promotion above blocks it, but this is the hard gate: any mutation
# of conf/Config.nmis or its .bak turns the run red rather than passing while
# silently corrupting on-disk config.
is(_file_cksum($CONF_FILE), $CONF_CKSUM_BEFORE,
	 "conf/Config.nmis was not modified by the test");
is(_file_cksum($CONF_BAK), $BAK_CKSUM_BEFORE,
	 "conf/Config.nmis.bak was not created or modified by the test");

# ---- cleanup ----------------------------------------------------------------

END {
	if ($node)
	{
		my $ok = eval { $node->delete(keep_rrd => 1); 1 };
		diag($ok ? "removed seed node" : "WARNING: could not remove seed node '$NODENAME'");
	}
}

done_testing();
