#!/usr/bin/perl
#
# t_compare_models_injection.t - OMK-12641 (CWE-78): admin/compare_models.pl
# ran the difftool through backticks, so /bin/sh parsed the @ARGV-supplied dirs
# and the readdir-supplied filename. Fixed with a multi-argument list-form open.
# A metacharacter name must exist in BOTH dirs, else no subprocess runs at all.
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX qw();

my $LIBDIR = "$FindBin::Bin/../lib";
my $SCRIPT = "$FindBin::Bin/../admin/compare_models.pl";

plan skip_all => "compare_models.pl not found at $SCRIPT" if (!-f $SCRIPT);

# the script needs a loadable config for its own getTmpDir call, so ask the
# environment directly rather than inferring it from an exit code later
my $TMPDIR = eval {
	require NMISNG::Util;
	NMISNG::Util::getTmpDir();
};
plan skip_all => "no loadable nmis config, cannot run compare_models.pl"
		if (!defined $TMPDIR || !length $TMPDIR);

# parseable model file (readFiletoHash wants %hash = (..))
sub write_model
{
	my ($path, $indexed) = @_;
	open(my $fh, '>', $path) or die "cannot write $path: $!";
	print $fh "%hash = (\n  'systemHealth' => {\n    'rrd' => {\n"
			. "      'test_item' => {\n        'indexed' => '$indexed',\n"
			. "      },\n    },\n  },\n);\n";
	close $fh;
	return;
}

# exec gets a list, so no shell here either. cwd matters: the payload carries
# no '/', so it lands in the child's cwd.
sub run_compare
{
	my (%arg) = @_;

	my $pid = fork();
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		if (defined $arg{cwd})
		{
			chdir($arg{cwd}) or POSIX::_exit(126);
		}
		open(STDOUT, '>', '/dev/null') or POSIX::_exit(126);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
		exec($^X, "-I$LIBDIR", $SCRIPT, $arg{old}, $arg{new})
				or POSIX::_exit(127);
	}
	waitpid($pid, 0);
	return $? >> 8;
}

# protect the shared dated diff log: the script unlinks it on every run
my $LOGFILE = POSIX::strftime("$TMPDIR/model-diffs-%Y-%m-%d", localtime);
my $LOGSAVE;
my $LOG_OURS = 1;
if (-f $LOGFILE)
{
	$LOGSAVE = "$LOGFILE.pretest.$$";
	$LOG_OURS = rename($LOGFILE, $LOGSAVE) ? 1 : 0;
	$LOGSAVE = undef if (!$LOG_OURS);
}

END {
	# only remove the log if we know we are not stepping on a pre-existing one
	unlink($LOGFILE) if ($LOG_OURS && defined $LOGFILE && -f $LOGFILE);
	rename($LOGSAVE, $LOGFILE) if (defined $LOGSAVE && -f $LOGSAVE);
}

subtest 'static: difftool is no longer invoked through a shell' => sub {
	open(my $fh, '<', $SCRIPT) or die "cannot read $SCRIPT: $!";
	my $src = do { local $/; <$fh> };
	close $fh;

	unlike($src, qr/`[^`]*\$difftool/, 'no backtick invocation of $difftool remains');

	# load-bearing: perl only skips the shell when the list has >1 element, so
	# one interpolated string here would silently restore it
	like($src, qr/open\s*\(\s*my\s+\$\w+\s*,\s*["']-\|["']\s*,\s*\$difftool\s*,/,
		 'difftool gets separate argv elements, not one string');
	unlike($src, qr/open\s*\([^,]+,\s*["']-\|["']\s*,\s*["'][^"']*\$difftool/,
		   'no single-argument piped open (that would re-enter the shell)');
};

# pre-fix sh split "<olddir>/x ; touch PWNED ; .nmis <newdir>/x" and ran the
# marker, and the bogus diff made the script exit 1.
subtest 'injection: shell metacharacters in a model filename do not execute' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/olddir", "$dir/newdir");

	my $evil = 'x;touch PWNED;.nmis';
	write_model("$dir/olddir/$evil", 'true');
	write_model("$dir/newdir/$evil", 'true');

	ok(-f "$dir/olddir/$evil", 'metacharacter-named fixture created in old dir')
			or return;
	ok(-f "$dir/newdir/$evil", 'metacharacter-named fixture created in new dir')
			or return;
	ok(!-e "$dir/PWNED", 'marker absent before the run');

	my $rc = run_compare(old => "$dir/olddir", new => "$dir/newdir", cwd => $dir);

	ok(!-e "$dir/PWNED",
	   'filename metacharacters are not interpreted by a shell (no marker file)');
	is($rc, 0,
	   'metacharacter-named file is compared as a real path, reporting no differences');
};

# the @ARGV dirs are the other half of the sink: pre-fix sh split
# "<dir>/d;touch PWNED;d/Common-Test.nmis" and ran the marker.
subtest 'injection: shell metacharacters in a directory argument do not execute' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $evildir = "$dir/d;touch PWNED;d";
	make_path($evildir, "$dir/newdir");
	write_model("$evildir/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'true');

	ok(-d $evildir, 'metacharacter-named old directory created') or return;
	ok(!-e "$dir/PWNED", 'marker absent before the run');

	my $rc = run_compare(old => $evildir, new => "$dir/newdir", cwd => $dir);

	ok(!-e "$dir/PWNED",
	   'directory metacharacters are not interpreted by a shell (no marker file)');
	is($rc, 0, 'metacharacter-named directory is compared as a real path');
};

subtest 'identical model directories exit 0' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/olddir", "$dir/newdir");
	write_model("$dir/olddir/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'true');

	is(run_compare(old => "$dir/olddir", new => "$dir/newdir"), 0,
	   'no differences reported for identical files');
};

subtest 'differing model directories exit 1 and capture the difftool output' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/olddir", "$dir/newdir");
	write_model("$dir/olddir/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'false');

	is(run_compare(old => "$dir/olddir", new => "$dir/newdir"), 1,
	   'difference reported as exit 1');
	ok(-f $LOGFILE, 'diff log was written') or return;

	open(my $fh, '<', $LOGFILE) or die "cannot read $LOGFILE: $!";
	my $log = '';
	read($fh, $log, 65536);				# bounded: we only need the first diff
	close $fh;
	like($log, qr{/systemHealth/rrd/test_item/indexed},
		 'difftool output was captured and written to the diff log');
};

# pre-fix the unquoted string form split this into extra arguments, so
# diffconfigs printed usage and a difference was falsely reported.
subtest 'directory path containing a space is passed as one argument' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/dir with space", "$dir/newdir");
	write_model("$dir/dir with space/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'true');

	is(run_compare(old => "$dir/dir with space", new => "$dir/newdir"), 0,
	   'space in a directory path does not produce a spurious difference');
};

done_testing();
