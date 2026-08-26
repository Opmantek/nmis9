#!/usr/bin/perl
# OMK-12826: patch_config.pl --value-stdin reads a (secret) value from STDIN
# rather than argv, so the value never lands in /proc/<pid>/cmdline. Proves the
# value is written verbatim (trailing newline stripped), round-trips, and that
# the key-only argv form is what makes the mode work (an argv 'key=value' form
# is NOT used).
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Copy;
use IPC::Open3;
use Symbol qw(gensym);

my $repo_root = "$FindBin::Bin/..";
my $patch     = "$repo_root/admin/patch_config.pl";
ok(-f $patch, "patch_config.pl exists");

my $tmp = tempdir("t_patch_config_stdin_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $cfg = "$tmp/Config.nmis";
copy("$repo_root/conf-default/Config.nmis", $cfg)
	or BAIL_OUT("copy conf-default/Config.nmis: $!");

# run patch_config feeding $stdin to the child; return ($rc,$stdout,$stderr)
sub run_stdin
{
	my ($stdin, @cmd) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @cmd);
	print $in $stdin if (defined $stdin);
	close($in);
	my $o = do { local $/; <$out> } // '';
	my $e = do { local $/; <$err> } // '';
	waitpid($pid, 0);
	return ($?, $o, $e);
}

# read a scalar key back out with patch_config -r
sub read_key
{
	my ($key) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $patch, "-r", $cfg, $key);
	close($in);
	my $v = do { local $/; <$out> } // '';
	waitpid($pid, 0);
	# patch_config prints an "Operating on config file:" header first; the value
	# is the last non-empty line for a scalar key.
	my @lines = grep { length } split(/\n/, $v);
	return @lines ? $lines[-1] : '';
}

# a value that also contains '=' and '+', to prove it round-trips untouched
my $secret = "abc=def+ghi_" . ("0123456789abcdef" x 4);   # >64 chars

# feed the secret on STDIN with a trailing newline (as echo/heredoc would)
my ($rc, $o, $e) = run_stdin("$secret\n",
	$^X, $patch, $cfg, "--value-stdin", "/database/db_password");
is($rc, 0, "patch_config --value-stdin exits 0")
	or diag("stdout:\n$o\nstderr:\n$e");

is(read_key("/database/db_password"), $secret,
	"value from STDIN written verbatim (one trailing newline stripped, '='/'+' preserved)");

# the key argument carried NO '=value', so this only works because the value is
# read from STDIN; an argv-parsing path would reject a key with no '='.
unlike($e, qr/cannot parse/, "key-only argv form is accepted in --value-stdin mode");

# guard: mode requires exactly one key and refuses -r
my ($rc2, undef, $e2) = run_stdin("x\n",
	$^X, $patch, $cfg, "--value-stdin", "-r", "/database/db_password");
isnt($rc2, 0, "--value-stdin combined with -r is rejected");

done_testing();
