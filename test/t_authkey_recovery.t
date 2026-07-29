#!/usr/bin/perl
# OMK-12687 regression test for the auth_web_key recovery hook.
#
# Runs the REAL installer_hooks/11-postcopy-authkey against a temp TARGETDIR from a
# cwd whose ../conf has no Config.nmis. That hostile cwd pins the original defect:
# the hook's key read must resolve conf from TARGETDIR, not from the process cwd
# (the installer chdirs to its own source dir before running hooks).
#
# The fixture is built from the real conf-default/Config.nmis with <nmis_base>
# retargeted, NOT from a hand-written stub. A stub lacking <nmis_base>, cluster_id
# and friends makes loadConfTable die inside its own cluster_id write-back path,
# so the test would fail on a loader crash and never reach the hook logic it is
# supposed to be checking.
#
# Covered:
#   - every insecure/default/absent key is regenerated to a fresh 64-hex key
#   - a unique site key is left untouched
#   - a FAILED read leaves the key untouched rather than regenerating over it
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp ();
use File::Path ();
use Cwd ();

# Scrub every NMIS_* variable from the environment before anything runs.
# loadConfTable merges NMIS_* into the config as layer 4, so a developer shell or
# CI runner exporting NMIS_AUTH_WEB_KEY would change what the hook sees and flip
# these results. A secure value makes every "insecure key is regenerated" case
# look like an already-unique key and the file is left alone, which fails 9 of the
# 12 assertions below for a reason that has nothing to do with the hook. The scrub
# is deliberately not limited to NMIS_AUTH_WEB_KEY, because any NMIS_* override
# (NMIS_DB_SERVER and friends) also reaches the loader the hook calls. Tests that
# want a specific override set it with `local` on top of this clean baseline.
delete @ENV{ grep { /^NMIS_/ } keys %ENV };

my $NMIS_HOME = "$FindBin::Bin/..";                 # test/ -> repo root
my $HOOK      = "$NMIS_HOME/installer_hooks/11-postcopy-authkey";
my $PATCH     = "$NMIS_HOME/admin/patch_config.pl";
my $LIB       = "$NMIS_HOME/lib";
my $DEFCONF   = "$NMIS_HOME/conf-default/Config.nmis";

plan skip_all => "hook not present"         unless -f $HOOK;
plan skip_all => "patch_config not present" unless -f $PATCH;
plan skip_all => "conf-default not present" unless -f $DEFCONF;

my $OLD_FALLBACK = '5nJv80DvEr3N/921tdKLk+fCjGzOS5F9IqMFhugxVHIguRC8PJKN4f2JJgcATkhv';

# read auth_web_key back with a plain regex (do NOT use readFiletoHash here: it has
# the very cwd dependency this test exists to catch).
sub read_key
{
	my ($file) = @_;
	open(my $fh, '<', $file) or return undef;
	local $/; my $data = <$fh>; close $fh;
	return ($data =~ /'auth_web_key'\s*=>\s*(['"])([^'"]*)\1/) ? $2 : undef;
}

# build a $td/lib that mirrors the real lib through symlinks, but replaces
# NMISNG::Util with a shim that dies ONLY on a dir-scoped loadConfTable.
#
# The blunt alternative, a Util.pm that dies at load, also breaks patch_config.pl
# (it does `use lib "$FindBin::Bin/../lib"`, which resolves to this same fixture
# lib). The key would then survive because the write failed, not because the hook
# declined to write, and the test would pass against the very bug it targets.
# Failing only the dir-scoped load fails the hook's read and nothing else.
sub make_shim_lib
{
	my ($td) = @_;
	my $real = Cwd::abs_path($LIB) or die "cannot resolve $LIB";

	File::Path::make_path("$td/lib/NMISNG");
	for my $pair ([$real, "$td/lib", 'NMISNG'], ["$real/NMISNG", "$td/lib/NMISNG", 'Util.pm'])
	{
		my ($from, $to, $skip) = @$pair;
		opendir(my $dh, $from) or die "opendir $from: $!";
		for my $entry (grep { $_ !~ /^\.\.?$/ && $_ ne $skip } readdir $dh)
		{
			symlink("$from/$entry", "$to/$entry") or die "symlink $entry: $!";
		}
		closedir $dh;
	}

	my $shim = <<'SHIM';
package NMISNG::Util;
# test shim: load the real module, then make only the dir-scoped load die.
require '__REALLIB__/NMISNG/Util.pm';
{
	no warnings 'redefine';
	my $orig = \&NMISNG::Util::loadConfTable;
	*NMISNG::Util::loadConfTable = sub {
		my %a = @_;
		die "simulated config loader failure\n" if (exists $a{dir});
		return $orig->(@_);
	};
}
1;
SHIM
	$shim =~ s/__REALLIB__/$real/g;
	open(my $fh, '>', "$td/lib/NMISNG/Util.pm") or die "write shim: $!";
	print $fh $shim;
	close $fh;
}

# build a temp TARGETDIR from the shipped default config, run the hook from a
# hostile cwd, and return (resulting auth_web_key, hook output).
# args: $initial => the auth_web_key to seed, undef to omit the line entirely
#       broken_read => 1 to make only the hook's config read die
#       env         => value for NMIS_AUTH_WEB_KEY, absent to leave it unset
#       cluster_id  => 1 to seed a cluster_id, i.e. a site that has run before.
#                      Without one, loadConfTable generates a cluster_id and
#                      rewrites Config.nmis through writeConfData as a side
#                      effect of the very first load. That rewrite drops keys
#                      whose effective value came from the environment, so with
#                      env => set the auth_web_key line disappears for reasons
#                      that have nothing to do with the hook.
sub run_hook_with_key
{
	my ($initial, %opt) = @_;

	my $target = File::Temp->newdir(CLEANUP => 1);
	my $td = "$target";
	File::Path::make_path("$td/conf", "$td/admin", "$td/var", "$td/logs");
	symlink($PATCH, "$td/admin/patch_config.pl") or die "symlink patch_config: $!";

	if ($opt{broken_read})
	{
		make_shim_lib($td);
	}
	else
	{
		symlink($LIB, "$td/lib") or die "symlink lib: $!";
	}

	# realistic config: the shipped default, pointed at the temp target so the
	# loader resolves <nmis_var> and friends inside the fixture
	open(my $src, '<', $DEFCONF) or die "read $DEFCONF: $!";
	open(my $dst, '>', "$td/conf/Config.nmis") or die "write config: $!";
	while (my $line = <$src>)
	{
		$line =~ s{'<nmis_base>'(\s*=>\s*)'[^']*'}{'<nmis_base>'$1'$td'};
		if ($line =~ /'auth_web_key'\s*=>/)
		{
			next if (!defined $initial);           # omit the key entirely
			$line =~ s{'auth_web_key'(\s*=>\s*)'[^']*'}{'auth_web_key'$1'$initial'};
			$line .= "\t'cluster_id' => 'fixed-uuid-for-test',\n" if ($opt{cluster_id});
		}
		print $dst $line;
	}
	close $src; close $dst;

	# hostile cwd: a fresh dir whose ../conf does not contain Config.nmis
	my $scratch = File::Temp->newdir(CLEANUP => 1);
	my $deep = "$scratch/a/b";
	File::Path::make_path($deep);
	my $prev = Cwd::getcwd();
	chdir($deep) or die "chdir: $!";
	local $ENV{TARGETDIR} = $td;
	delete local $ENV{SIMULATE};
	# exists() not defined(), so a caller can pass env => '' to pin the
	# empty-string case, which the deny-set treats as insecure
	local $ENV{NMIS_AUTH_WEB_KEY} = $opt{env} if exists $opt{env};
	my $out = qx{sh "$HOOK" 2>&1};
	chdir($prev) or die "chdir back: $!";

	return (read_key("$td/conf/Config.nmis"), $out // '');
}

# every insecure value must be regenerated to a fresh 64-hex key
my %insecure = (
	'empty'             => '',
	'placeholder'       => 'Please Change Me!',
	'old fallback'      => $OLD_FALLBACK,
	'omk default 1'     => 'My new Opmantek Secret',
	'omk default 2'     => '42 new Opmantek Secrets',
	'thisismysecretkey' => 'thisismysecretkey',
	'change_me pref'    => 'CHANGE_ME_abc123',
);
for my $label (sort keys %insecure)
{
	my ($result) = run_hook_with_key($insecure{$label});
	like($result // '', qr/^[0-9a-f]{64}$/,
		"insecure key regenerated to 64-hex from hostile cwd: $label");
}

# an entirely absent auth_web_key must also be regenerated to a fresh 64-hex key
{
	my ($result) = run_hook_with_key(undef);
	like($result // '', qr/^[0-9a-f]{64}$/,
		'absent auth_web_key regenerated to 64-hex from hostile cwd');
}

# a custom key must be left untouched
{
	my $custom = 'a-real-unique-per-site-secret-abc123';
	my ($result) = run_hook_with_key($custom);
	is($result, $custom, 'custom auth_web_key is preserved');
}

# --- NMIS_AUTH_WEB_KEY branches -------------------------------------------
# The hook reads the EFFECTIVE key through loadConfTable, so a NMIS_* override
# is merged in exactly as it will be at runtime. These two cases pin that. The
# earlier regex-over-Config.nmis implementation passed everything above and
# still got both of these wrong, because it never saw the environment at all.

# a secure key supplied by the environment means the site is already safe, so
# the hook must not mint one. cluster_id is seeded so the loader's first-load
# rewrite does not touch the file, leaving the hook as the only thing that could
# have changed it.
{
	my ($result, $out) = run_hook_with_key('Please Change Me!',
		env => 'a-secure-env-supplied-secret', cluster_id => 1);
	is($result, 'Please Change Me!',
		'secure NMIS_AUTH_WEB_KEY is honoured and the file key is left alone');
	unlike($out, qr/Generated a unique random auth_web_key/,
		'no key is generated when the environment already supplies a secure one');
	like($out, qr/already set to a unique value/,
		'the effective key is recognised as unique, not read as an unset file key');
}

# an insecure key supplied by the environment has to be fixed in the
# environment. Patching the file would not take effect (ENV wins) and would add
# a file-plus-ENV overlap, so the hook must report it and write nothing.
{
	my ($result, $out) = run_hook_with_key('Please Change Me!',
		env => 'Please Change Me!', cluster_id => 1);
	is($result, 'Please Change Me!',
		'insecure NMIS_AUTH_WEB_KEY does not cause the file to be patched');
	unlike($out, qr/Generated a unique random auth_web_key/,
		'no key is generated when the environment supplies an insecure one');
	like($out, qr/NMIS_AUTH_WEB_KEY is insecure or empty/,
		'insecure NMIS_AUTH_WEB_KEY is reported against the environment');
}

# a FAILED read must not be mistaken for "no key set". Regenerating on a guess
# would replace a good site secret and invalidate every live session.
{
	my $custom = 'a-real-unique-per-site-secret-abc123';
	my ($result, $out) = run_hook_with_key($custom, broken_read => 1);
	is($result, $custom, 'custom auth_web_key survives a failed config read');
	like($out, qr/could not read auth_web_key/,
		'failed config read is reported as an error');
	unlike($out, qr/Generated a unique random auth_web_key/,
		'hook does not claim to have generated a key after a failed read');
}

done_testing;
