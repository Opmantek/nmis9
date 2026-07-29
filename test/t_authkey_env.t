#!/usr/bin/perl
# OMK-12687 regression test for the ENV-aware auth_web_key logic.
#
# The bug this pins: the installer hook and both Docker entrypoints used to
# decide whether auth_web_key was safe by running a regex over Config.nmis. That
# never sees NMIS_AUTH_WEB_KEY, so a container configured entirely through the
# environment looked like it had no key, and the startup code generated one and
# patched it into the conf volume. The effective key is now read through
# NMISNG::Util::loadConfTable, the same loader NMIS uses at runtime, which merges
# NMIS_* as layer 4.
#
# What this file exercises: installer_hooks/common_authkey.sh, the single shared
# implementation that installer_hooks/11-postcopy-authkey, docker-entrypoint.sh
# and docker-dev/docker-entrypoint-dev.sh all source. That is where the deny-set,
# the effective-key read and the key generation live.
#
# What it deliberately does not exercise: the entrypoints end in `run "$@"`,
# which starts mongod and the daemons, so they cannot be executed here. The last
# section instead asserts structurally that both of them delegate to the shared
# helper and have not grown a private copy of the logic back. End-to-end coverage
# of a real caller acting on these classifications is in t_authkey_recovery.t,
# which runs the installer hook for real.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp ();
use File::Path ();

# NMIS_* variables are merged into the config as layer 4, so an exported
# NMIS_AUTH_WEB_KEY on the developer or CI machine would decide the answer to
# every case below. Start from a known-empty baseline; each case sets what it
# needs. Same reasoning as the scrub at the top of t_authkey_recovery.t.
delete @ENV{ grep { /^NMIS_/ } keys %ENV };

my $NMIS_HOME = "$FindBin::Bin/..";                 # test/ -> repo root
my $HELPER    = "$NMIS_HOME/installer_hooks/common_authkey.sh";
my $DEFCONF   = "$NMIS_HOME/conf-default/Config.nmis";
my $ENTRY     = "$NMIS_HOME/docker-entrypoint.sh";
my $ENTRY_DEV = "$NMIS_HOME/docker-dev/docker-entrypoint-dev.sh";

plan skip_all => "shared authkey helper not present" unless -f $HELPER;
plan skip_all => "conf-default not present"          unless -f $DEFCONF;

my $OLD_FALLBACK = '5nJv80DvEr3N/921tdKLk+fCjGzOS5F9IqMFhugxVHIguRC8PJKN4f2JJgcATkhv';

# classification codes, as documented in common_authkey.sh
my $SECURE       = 0;
my $INSECURE_ENV = 1;
my $INSECURE_FILE= 2;
my $READ_FAILED  = 3;

# Build a temp install root holding conf/ and lib/, seeded with $filekey.
#
# The config is the real conf-default/Config.nmis with <nmis_base> retargeted,
# not a hand-written stub: a stub missing <nmis_base> and friends makes
# loadConfTable die inside its own cluster_id write-back and every case would
# report a read failure. A fixed cluster_id is injected for the same reason,
# without it the loader rewrites Config.nmis as a side effect of the first load,
# which moves the file out from under the assertion.
#
# broken_lib => 1 installs a lib/NMISNG/Util.pm that dies on load, so the
# helper's read fails while everything else is untouched.
sub fixture
{
	my ($filekey, %opt) = @_;

	my $keep = File::Temp->newdir(CLEANUP => 1);
	my $td   = "$keep";
	File::Path::make_path("$td/conf", "$td/var", "$td/logs");

	if ($opt{broken_lib})
	{
		File::Path::make_path("$td/lib/NMISNG");
		open(my $fh, '>', "$td/lib/NMISNG/Util.pm") or die "write broken lib: $!";
		print $fh qq{package NMISNG::Util;\ndie "simulated loader failure\\n";\n1;\n};
		close $fh;
	}
	else
	{
		symlink("$NMIS_HOME/lib", "$td/lib") or die "symlink lib: $!";
	}

	open(my $src, '<', $DEFCONF)               or die "read $DEFCONF: $!";
	open(my $dst, '>', "$td/conf/Config.nmis") or die "write config: $!";
	while (my $line = <$src>)
	{
		$line =~ s{'<nmis_base>'(\s*=>\s*)'[^']*'}{'<nmis_base>'$1'$td'};
		if ($line =~ /'auth_web_key'\s*=>/)
		{
			next if (!defined $filekey);       # omit the key entirely
			$line =~ s{'auth_web_key'(\s*=>\s*)'[^']*'}{'auth_web_key'$1'$filekey'};
			$line .= "\t'cluster_id' => 'fixed-uuid-for-test',\n";
		}
		print $dst $line;
	}
	close $src; close $dst;

	return ($keep, $td);
}

# read auth_web_key straight out of the file, so "was the file written?" is
# answered by the file and not by the loader that the helper itself uses
sub file_key
{
	my ($td) = @_;
	open(my $fh, '<', "$td/conf/Config.nmis") or return undef;
	local $/; my $data = <$fh>; close $fh;
	return ($data =~ /'auth_web_key'\s*=>\s*(['"])([^'"]*)\1/) ? $2 : undef;
}

# source the shared helper and classify $td, returning the code it reports
sub classify
{
	my ($td, %opt) = @_;
	my $env = exists $opt{env}
		? "NMIS_AUTH_WEB_KEY=" . shell_quote($opt{env}) . " "
		: "";
	my $script = qq{. "$HELPER"; nmis_authkey_classify "$td" && echo 0 || echo \$?};
	my $out = qx{${env}sh -c '$script' 2>/dev/null};
	chomp $out;
	return $out;
}

sub shell_quote { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

# --- the four cases the code has to get right -----------------------------

# 1. a secure key from the environment: the site is already safe, and the file
#    must not be touched. This is the case the old regex implementation failed.
{
	my ($keep, $td) = fixture('Please Change Me!');
	my $class = classify($td, env => 'a-secure-env-supplied-secret');
	is($class, $SECURE, 'secure NMIS_AUTH_WEB_KEY classifies as already secure');
	is(file_key($td), 'Please Change Me!', 'secure env key leaves the config file untouched');
}

# 2. an insecure key from the environment: writing the file would not take
#    effect, so this must be distinguishable from "fix the file"
{
	my ($keep, $td) = fixture('Please Change Me!');
	my $class = classify($td, env => 'Please Change Me!');
	is($class, $INSECURE_ENV, 'insecure NMIS_AUTH_WEB_KEY classifies as an environment problem');
	is(file_key($td), 'Please Change Me!', 'insecure env key does not cause a config write');
}

# 3. no environment override and a default key in the file: the file is the
#    thing to fix
{
	my ($keep, $td) = fixture('Please Change Me!');
	is(classify($td), $INSECURE_FILE, 'default key with no env override classifies as fixable in the file');
}

# 4. a real per-site key already in the file must be left alone
{
	my ($keep, $td) = fixture('a-real-unique-per-site-secret-abc123');
	is(classify($td), $SECURE, 'a unique key already in the file classifies as secure');
}

# --- the read must fail closed --------------------------------------------

# a dead loader is not "no key set". Conflating them regenerates over a good
# secret, which is the more damaging of the two mistakes.
{
	my ($keep, $td) = fixture('a-real-unique-per-site-secret-abc123', broken_lib => 1);
	is(classify($td), $READ_FAILED, 'a failed config read is reported as its own outcome');
}

# --- the deny-set --------------------------------------------------------

# must mirror NMISNG::Auth @INSECURE_WEB_KEYS plus the ^CHANGE_ME prefix. If it
# drifts, a key Auth.pm rejects is left in place and login stays broken with no
# remediation and nothing said about it.
my @insecure = ('', 'Please Change Me!', $OLD_FALLBACK, 'My new Opmantek Secret',
	'42 new Opmantek Secrets', 'thisismysecretkey', 'CHANGE_ME_abc123');
# the candidate goes in through the environment rather than being interpolated
# into the sh -c string: several of these keys contain spaces, and embedding a
# quoted value inside an already single-quoted script nests quotes and mangles it
sub is_insecure
{
	my ($key) = @_;
	my $q  = shell_quote($key);
	my $rc = qx{KEY=$q sh -c '. "$HELPER"; nmis_authkey_is_insecure "\$KEY" && echo yes || echo no' 2>/dev/null};
	chomp $rc;
	return $rc;
}

for my $key (@insecure)
{
	is(is_insecure($key), 'yes',
		"deny-set rejects: " . ($key eq '' ? '(empty string)' : $key));
}
is(is_insecure('a-real-unique-per-site-secret'), 'no', 'deny-set accepts a unique key');
is(is_insecure('CHANGE_ME'),                     'yes', 'deny-set rejects the bare CHANGE_ME prefix');

# --- generation ----------------------------------------------------------

{
	my $key = qx{sh -c '. "$HELPER"; nmis_authkey_generate' 2>/dev/null};
	like($key, qr/^[0-9a-f]{64}$/, 'nmis_authkey_generate produces a 64 hex character key');

	my $second = qx{sh -c '. "$HELPER"; nmis_authkey_generate' 2>/dev/null};
	isnt($key, $second, 'successive generated keys differ');
}

# --- the Docker entrypoints must keep delegating --------------------------

# They cannot be run here, so pin the structure instead. Both previously carried
# their own copy of this logic, and the copies drifted: only the installer hook
# captured the read status, so a loader failure in a container rotated a good
# key. These assertions fail if either grows a private implementation again.
for my $pair ([$ENTRY, 'docker-entrypoint.sh'], [$ENTRY_DEV, 'docker-entrypoint-dev.sh'])
{
	my ($path, $name) = @$pair;
	SKIP: {
		skip "$name not present", 3 unless -f $path;
		open(my $fh, '<', $path) or die "read $path: $!";
		local $/; my $body = <$fh>; close $fh;

		like($body, qr/common_authkey\.sh/,
			"$name sources the shared helper");
		like($body, qr/nmis_authkey_classify/,
			"$name classifies through the shared helper");
		unlike($body, qr/thisismysecretkey/,
			"$name has no private copy of the deny-set");
	}
}

done_testing;
