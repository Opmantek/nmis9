#!/usr/bin/perl
# OMK-12688: the seed decision. nmis-cli recognises the shipped
# '*NMIS-UNSEEDED*' marker on its own, so there is no seed= flag and no shell
# derivation left. What still has to hold is the marker invariant that makes
# that possible, plus the reveal= derivation in the installer hook. The hook
# cannot be run here, so its derivation is extracted and run on its own.
use strict;
use warnings;
use Test::More;
use FindBin;

# an exported UNATTENDED would answer every reveal case for us
delete $ENV{UNATTENDED};

my $NMIS_HOME = "$FindBin::Bin/..";                 # test/ -> repo root
my $SHIPPED   = "$NMIS_HOME/conf-default/users.dat";
my $HOOK      = "$NMIS_HOME/installer_hooks/05-postcopy-configfiles";
my $ENTRY     = "$NMIS_HOME/docker-entrypoint.sh";
my $ENTRY_DEV = "$NMIS_HOME/docker-dev/docker-entrypoint-dev.sh";

plan skip_all => "conf-default/users.dat not present" unless -f $SHIPPED;

sub slurp { my ($p) = @_; open(my $f, '<', $p) or die "read $p: $!"; local $/; my $c = <$f>; close $f; return $c }
sub shq   { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

my $SHIPPED_CONTENT = slurp($SHIPPED);

# --- the marker invariant -------------------------------------------------

# Everything below rests on this. Reverting conf-default/users.dat to a bare
# lock makes an operator's own nmis:* indistinguishable from a fresh install,
# and the next install or container restart replaces their lock with a working
# password (the old H16 gap). bin/nmis-cli::_is_shipped_seed holds the same
# string, so these two must be changed together.
my ($shipped_hash) = $SHIPPED_CONTENT =~ /^nmis:(.*)$/m;
ok(defined($shipped_hash), 'the shipped store has an nmis line');
is($shipped_hash, '*NMIS-UNSEEDED*',
	'the shipped nmis entry is the unseeded marker nmis-cli looks for');
unlike($shipped_hash, qr/^[*!]\s*$/,
	'the shipped store is not a bare lock marker an operator could reproduce');

{
	my $cli = slurp("$NMIS_HOME/bin/nmis-cli");
	like($cli, qr/\Q'*NMIS-UNSEEDED*'\E/,
		'nmis-cli holds the same marker string as conf-default/users.dat');
}

# --- reveal, run out of the hook itself -----------------------------------

# the hook needs $TARGETDIR and a real install tree, so lift just the REVEAL
# block out of it and run that. Extracting rather than restating it means a
# change to the hook is measured here instead of silently diverging.
SKIP: {
	skip "05-postcopy-configfiles not present", 4 unless -f $HOOK;
	my $body = slurp($HOOK);
	my ($block) = $body =~ /^(if \[ -n "\$\{UNATTENDED:-\}" \].*?^fi$)/ms;

	ok(defined($block), 'the hook has a REVEAL derivation to extract')
		or skip "no REVEAL block found in the hook", 3;

	my $reveal = sub {
		my (%opt) = @_;
		my $cmd = "BLOCK=" . shq($block);
		$cmd .= " UNATTENDED=" . shq($opt{unattended}) if (exists $opt{unattended});
		$cmd .= ' sh -c ' . shq('eval "$BLOCK"; echo "$REVEAL"') . " 2>/dev/null";
		my $out = qx{$cmd};
		chomp $out;
		return $out;
	};

	is($reveal->(),                  'show', 'reveal defaults to show on an interactive console');
	is($reveal->(unattended => '1'), 'none', 'UNATTENDED forces reveal=none');
	is($reveal->(unattended => ''),  'show', 'an empty UNATTENDED is not unattended');
}

# --- no caller may resurrect a private seed decision ----------------------

# all three previously derived seed= in shell. The comparison against
# conf-default/users.dat was the fragile part, and a private copy of it coming
# back is what these guard against.
for my $pair ([$ENTRY, 'docker-entrypoint.sh'], [$ENTRY_DEV, 'docker-entrypoint-dev.sh'],
	[$HOOK, '05-postcopy-configfiles'])
{
	my ($path, $name) = @$pair;
	SKIP: {
		skip "$name not present", 2 unless -f $path;
		my $body = slurp($path);
		like($body, qr/act=seed-htpasswd-password/,
			"$name still seeds the nmis password");
		unlike($body, qr/\bseed=/,
			"$name passes no seed= argument");
	}
}

# the entrypoints only: the hook legitimately names conf-default/users.dat in
# its noclobber cp, so this narrower check cannot include it.
for my $pair ([$ENTRY, 'docker-entrypoint.sh'], [$ENTRY_DEV, 'docker-entrypoint-dev.sh'])
{
	my ($path, $name) = @$pair;
	SKIP: {
		skip "$name not present", 1 unless -f $path;
		unlike(slurp($path), qr{conf-default/users\.dat},
			"$name has no private copy of the shipped-store comparison");
	}
}

# --- the shared helper is gone --------------------------------------------

# it existed to stop three copies of the seed decision drifting. With the
# decision inside nmis-cli, the hook is the only caller of anything it held, so
# reveal= was inlined there and the file removed.
ok(!-e "$NMIS_HOME/installer_hooks/common_seedpw.sh",
	'installer_hooks/common_seedpw.sh is gone');

SKIP: {
	skip "05-postcopy-configfiles not present", 2 unless -f $HOOK;
	my $body = slurp($HOOK);
	unlike($body, qr/common_seedpw/, 'the hook no longer sources the removed helper');
	like($body, qr/reveal=\$REVEAL/, 'the hook passes its own derived reveal=');
}

done_testing;
