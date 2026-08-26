#!/usr/bin/perl
# OMK-12709: the detect-only default-password classifier.
use strict; use warnings;
use FindBin;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Test::More;

my $repo   = "$FindBin::Bin/..";
my $helper = "$FindBin::Bin/../installer_hooks/common_dbpassword.sh";
ok(-f $helper, "common_dbpassword.sh exists");

# Drive the shell functions through /bin/sh, the interpreter the installer uses.
sub sh_is_insecure {
	my ($pw) = @_;
	my $q = $pw; $q =~ s/'/'\\''/g;
	my $rc = system("/bin/sh", "-c", ". '$helper'; nmis_dbpassword_is_insecure '$q'");
	return $rc == 0 ? 1 : 0;   # function returns 0 (shell true) when insecure
}

ok(sh_is_insecure('op42flow42'),  "the shipped default op42flow42 is insecure");
ok(sh_is_insecure('example'),     "the docker default example is insecure");
ok(sh_is_insecure('password'),    "password is insecure");
ok(sh_is_insecure(''),            "empty is insecure");
ok(sh_is_insecure('CHANGE_ME_x'), "CHANGE_ME* is insecure");
ok(!sh_is_insecure('a-real-generated-9f3c2a1b'), "a generated value is not flagged");

# advice mentions the migration path and the username
my $advice = qx{/bin/sh -c ". '$helper'; nmis_dbpassword_advice 'opUserRW'"};
like($advice, qr/opUserRW/, "advice names the user");
like($advice, qr/setup_mongodb\.pl/, "advice points at the migration tool");
unlike($advice, qr/simply edit|just change/i, "advice does not tell them to just edit db_password");

# --- nmis_dbpassword_classify: the function the installer hook actually calls ---
# It reads the EFFECTIVE db_password (via loadConfTable, so NMIS_* env overrides
# are merged) from a throwaway install root and returns: 0 not-a-default,
# 1 default-and-from-env, 2 default-and-from-config, 3 read-failed. Build a temp
# root with the repo's lib and a seeded conf/Config.nmis, then drive the real
# shell function so this covers what the deny-predicate test above does not.
sub run_classify
{
	my ($conf_pw, $username, $env_pw) = @_;
	my $dir = tempdir("t_dbpw_classify_XXXXXX", TMPDIR => 1, CLEANUP => 1);
	mkdir("$dir/conf") or die "mkdir conf: $!";
	symlink("$repo/lib", "$dir/lib") or die "symlink lib: $!";
	copy("$repo/conf-default/Config.nmis", "$dir/conf/Config.nmis")
		or die "copy Config.nmis: $!";
	system($^X, "$repo/admin/patch_config.pl", "$dir/conf/Config.nmis",
		"/database/db_username=$username",
		"/database/db_password=$conf_pw") == 0
		or die "seed patch_config failed";

	# Run with the working directory inside the throwaway conf. classify's probe
	# is a `perl -e`, whose FindBin::RealBin is the CWD; loadConfTable makes a
	# secondary no-dir call that mkpaths "$FindBin::RealBin/../conf" before its
	# cache check. From here that resolves to this throwaway conf (which exists),
	# so the probe does not try to create a conf dir under the real install root
	# (which fails for a non-root CI user). The real classify runs as root against
	# a real install, where that path exists and is writable.
	my $outfile = "$dir/out";
	my $body = "cd '$dir/conf'; . '$helper'; nmis_dbpassword_classify '$dir'; "
		. "printf '%s\\n%s\\n%s\\n' \"\$?\" \"\$NMIS_DBPASSWORD_USER\" \"\$NMIS_DBPASSWORD_FROM_ENV\" > '$outfile'";

	# Scrub ALL NMIS_DB_* so an environment that sets them cannot override the
	# throwaway conf through loadConfTable's env layer. CI runs the suite with
	# NMIS_DB_AUTH_SOURCE / NMIS_DB_USERNAME / NMIS_DB_* set (the admin identity),
	# which otherwise makes classify report db_username=root instead of the seeded
	# value. Then set only the one variable under test. Mirrors the scrub in
	# t_setup_mongodb_scoped_user.t.
	local %ENV = %ENV;
	delete @ENV{ grep { /^NMIS_DB_/ } keys %ENV };
	$ENV{NMIS_DB_PASSWORD} = $env_pw if (defined $env_pw);
	system('/bin/sh', '-c', $body);

	open(my $fh, '<', $outfile) or return (undef, undef, undef);
	chomp(my @l = <$fh>);
	close($fh);
	return ($l[0], $l[1], $l[2]);   # (rc, user, from_env)
}

subtest 'classify: a shipped default in the config file' => sub {
	my ($rc, $user, $fromenv) = run_classify('op42flow42', 'opUserRW', undef);
	is($rc, 2, "returns 2 (default, from config)");
	is($user, 'opUserRW', "reports the effective db_username");
	isnt($fromenv, '1', "does not flag it as coming from the environment");
};

subtest 'classify: a default forced in via a NMIS_DB_PASSWORD env override' => sub {
	# the config value is safe, but the env override wins and is a default
	my ($rc, $user, $fromenv) = run_classify('a-strong-config-value-7c1d', 'nmis9RW', 'op42flow42');
	is($rc, 1, "returns 1 (default, from environment)");
	is($fromenv, '1', "flags that the value comes from the environment");
};

subtest 'classify: a safe (non-default) config value' => sub {
	my ($rc, $user, $fromenv) = run_classify('a-real-generated-9f3c2a1b', 'nmis9RW', undef);
	is($rc, 0, "returns 0 (nothing to warn about)");
	is($user, 'nmis9RW', "still reports the effective db_username");
};

subtest 'classify: an empty password is treated as a default' => sub {
	my ($rc, undef, undef) = run_classify('', 'nmis9RW', undef);
	is($rc, 2, "empty in the config returns 2 (default, from config)");
};

done_testing();
