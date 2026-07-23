#!/usr/bin/perl
#
# t_config_load_perms.pl - security regression tests for OMK-12696 (H1).
#
# .nmis config/table/model files are loaded by eval'ing their contents as Perl,
# as root. A WORLD-writable .nmis is therefore root RCE by any local user.
#
# NMIS deliberately makes config GROUP-writable (fixperms does chmod -R g+rw so
# httpd, which the installer puts in the nmis group, can edit config via the
# GUI). So group-writable is the shipped, trusted state and must still load; the
# group-member/httpd -> root escalation is left to the architectural fix
# (privileged write path + root-owned config). This guard closes only the
# world-writable vector. JSON loading is unaffected.
#
# Runs standalone: NMISNG::Util::readFiletoHash / _load_and_flatten take a path.
#
use strict;
use warnings;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp ();

use NMISNG::Util;

my $dir = File::Temp->newdir();

sub write_nmis {
	my ($name, $mode, $body) = @_;
	my $path = "$dir/$name";
	open(my $fh, '>', $path) or die "cannot write $path: $!";
	print $fh $body;
	close $fh;
	chmod($mode, $path) or die "chmod failed: $!";
	return $path;
}

my $marker  = "$dir/PWNED";
my $payload = qq{system("touch $marker"); ( loaded => 1 )\n};
my $benign  = qq{( alpha => 1, beta => "two" )\n};

# ============================================================
# readFiletoHash (tables / models) — Util.pm eval sink
# ============================================================
{
	# WORLD-writable payload must NOT be evaluated
	unlink $marker;
	my $p = write_nmis("evil-world.nmis", 0666, $payload);
	my $res = NMISNG::Util::readFiletoHash(file => $p, json => 0);
	ok(!-e $marker, 'readFiletoHash: world-writable config is NOT evaluated');
	ok(!ref($res), 'readFiletoHash: world-writable config returns an error, not a hash');
}
{
	# GROUP-writable config is the shipped/trusted state and MUST still load
	my $p = write_nmis("group.nmis", 0664, $benign);
	my $res = NMISNG::Util::readFiletoHash(file => $p, json => 0);
	is(ref($res), 'HASH', 'readFiletoHash: group-writable config still loads (trusted design)');
	is($res->{alpha}, 1, 'readFiletoHash: group-writable content is correct');
}
{
	# owner-only-writable config still loads
	my $p = write_nmis("good.nmis", 0644, $benign);
	my $res = NMISNG::Util::readFiletoHash(file => $p, json => 0);
	is(ref($res), 'HASH', 'readFiletoHash: 0644 config still loads to a hash');
}

# ============================================================
# _load_and_flatten (Config.nmis) — Util.pm eval sink
# ============================================================
{
	unlink $marker;
	my $p = write_nmis("evil-world-conf.nmis", 0666,
		qq{system("touch $marker"); ( database => { db_name => "x" } )\n});
	my @r = NMISNG::Util::_load_and_flatten($p);
	ok(!-e $marker, '_load_and_flatten: world-writable config is NOT evaluated');
}
{
	my $p = write_nmis("group-conf.nmis", 0664, qq{( database => { db_name => "nmisng" } )\n});
	my ($flat) = NMISNG::Util::_load_and_flatten($p);
	is(ref($flat), 'HASH', '_load_and_flatten: group-writable config still loads (trusted design)');
	is($flat->{db_name}, 'nmisng', '_load_and_flatten: group-writable content is correct (flattened)');
}
{
	my $p = write_nmis("good-conf.nmis", 0644, qq{( database => { db_name => "nmisng" } )\n});
	my ($flat) = NMISNG::Util::_load_and_flatten($p);
	is(ref($flat), 'HASH', '_load_and_flatten: 0644 config still loads');
}

done_testing();
