#!/usr/bin/perl
#
# t_compare_models_injection.t - OMK-12641: shell injection in
# admin/compare_models.pl (CWE-78)
#
# The old line 73 ran the difftool through backticks:
#
#     my @output = `$difftool $olddir/$fn $newdir/$fn`;
#
# so /bin/sh parsed a single interpolated string built from the two
# argv-supplied directories and the readdir-supplied filename. A model file
# whose *name* carried shell metacharacters, e.g. "x;touch PWNED;.nmis",
# executed as a command. The name has to exist in BOTH directories, otherwise
# the "old or new only" branch is taken and no subprocess runs at all.
#
# The fix replaces the backticks with a list-form piped open, which execs the
# difftool directly and never involves a shell.
#
# Coverage:
#   1. static  - backtick form gone, list-form open present
#   2. RED->GREEN behavioural - metacharacter filename does not execute
#   3. functional guards - exit-code contract preserved (0 == no differences,
#      1 == differences), and a directory path containing a space now works
#      (the unquoted string form split it into extra arguments)
#
# Self-contained: builds its own model fixtures under a File::Temp dir. The
# script writes a dated diff log into the shared nmis tmp dir and unlinks it,
# so any pre-existing log is renamed aside up front and restored on exit.
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

# ---------------------------------------------------------------------------
# minimal but genuinely parseable model file (readFiletoHash wants %hash = (..))
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# run the script in a child. No shell here either: exec gets a list, so the
# space-in-path subtest exercises the script rather than this harness.
# chdir matters - the injected payload can carry no '/' (it lives in a
# filename), so it lands in the child's cwd.
# ---------------------------------------------------------------------------
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
		open(STDOUT, '>', $arg{outfile} // '/dev/null') or POSIX::_exit(126);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
		exec($^X, "-I$LIBDIR", $SCRIPT, $arg{old}, $arg{new})
				or POSIX::_exit(127);
	}
	waitpid($pid, 0);
	return $? >> 8;
}

# ---------------------------------------------------------------------------
# protect the shared dated diff log: the script unlinks it on every run
# ---------------------------------------------------------------------------
my ($LOGFILE, $LOGSAVE, $LOG_OURS);
{
	my $tmp = eval {
		require NMISNG::Util;
		NMISNG::Util::getTmpDir();
	};
	if (defined $tmp && length $tmp)
	{
		$LOGFILE = POSIX::strftime("$tmp/model-diffs-%Y-%m-%d", localtime);
		if (-f $LOGFILE)
		{
			$LOGSAVE = "$LOGFILE.pretest.$$";
			$LOG_OURS = rename($LOGFILE, $LOGSAVE) ? 1 : 0;
			$LOGSAVE = undef if (!$LOG_OURS);
		}
		else
		{
			$LOG_OURS = 1;
		}
	}
}

END {
	# only remove the log if we know we are not stepping on a pre-existing one
	unlink($LOGFILE) if ($LOG_OURS && defined $LOGFILE && -f $LOGFILE);
	rename($LOGSAVE, $LOGFILE) if (defined $LOGSAVE && -f $LOGSAVE);
}

# ---------------------------------------------------------------------------
# smoke check: the script needs a loadable config for getTmpDir. If it cannot
# even run we skip rather than reporting misleading failures.
# ---------------------------------------------------------------------------
my $SMOKE = tempdir(CLEANUP => 1);
make_path("$SMOKE/a", "$SMOKE/b");
write_model("$SMOKE/a/Common-t.nmis", 'true');
write_model("$SMOKE/b/Common-t.nmis", 'true');
{
	my $out = "$SMOKE/smoke.out";
	my $rc = run_compare(old => "$SMOKE/a", new => "$SMOKE/b", outfile => $out);
	if ($rc != 0)
	{
		my $detail = '';
		if (open(my $fh, '<', $out)) { read($fh, $detail, 2048); close $fh; }
		plan skip_all => "compare_models.pl not runnable here (exit $rc): $detail";
	}
}

# ---------------------------------------------------------------------------
# 1. static: the shelling-out form is gone, the list form is present
# ---------------------------------------------------------------------------
subtest 'static: difftool is no longer invoked through a shell' => sub {
	open(my $fh, '<', $SCRIPT) or die "cannot read $SCRIPT: $!";
	my @lines = <$fh>;
	close $fh;

	my @backticks = grep { /`[^`]*\$difftool/ } @lines;
	is(scalar(@backticks), 0, 'no backtick invocation of $difftool remains');

	my @qx = grep { /\bqx[\{\(\/!]/ } @lines;
	is(scalar(@qx), 0, 'no qx// invocation introduced instead');

	my $src = join('', @lines);
	like($src, qr/open\s*\(\s*my\s+\$\w+\s*,\s*["']-\|["']\s*,\s*\$difftool\s*,/,
		 'list-form piped open on $difftool is present');
	like($src, qr/\$exitcode\s*=\s*\$\?\s*>>\s*8/,
		 'exit code is still derived from $? (contract unchanged)');
};

# ---------------------------------------------------------------------------
# 2. behavioural RED->GREEN: a metacharacter filename must not execute.
#
# Pre-fix the sh command line splits into
#   diffconfigs.pl <olddir>/x   ;   touch PWNED   ;   .nmis <newdir>/x   ...
# so the marker appears and the bogus diff makes the script exit 1.
# Post-fix the whole name is one argv element naming a real, identical file,
# so nothing executes and the run reports no differences.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3a. functional guard: identical directories still report no differences
# ---------------------------------------------------------------------------
subtest 'identical model directories exit 0' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/olddir", "$dir/newdir");
	write_model("$dir/olddir/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'true');

	is(run_compare(old => "$dir/olddir", new => "$dir/newdir"), 0,
	   'no differences reported for identical files');
};

# ---------------------------------------------------------------------------
# 3b. functional guard: a real difference is still detected and logged
# ---------------------------------------------------------------------------
subtest 'differing model directories exit 1 and capture the difftool output' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/olddir", "$dir/newdir");
	write_model("$dir/olddir/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'false');

	my $rc = run_compare(old => "$dir/olddir", new => "$dir/newdir");
	is($rc, 1, 'difference reported as exit 1');

	SKIP: {
		skip 'diff log path could not be determined', 1 if (!defined $LOGFILE);
		skip 'diff log not written', 1 if (!-f $LOGFILE);

		open(my $fh, '<', $LOGFILE) or die "cannot read $LOGFILE: $!";
		my $log = '';
		read($fh, $log, 65536);				# bounded: we only need the first diff
		close $fh;
		like($log, qr{/systemHealth/rrd/test_item/indexed},
			 'difftool output was captured and written to the diff log');
	}
};

# ---------------------------------------------------------------------------
# 3c. regression guard: a directory path containing a space.
#
# Pre-fix the unquoted string form split this into extra arguments, diffconfigs
# printed its usage, exited non-zero, and a difference was falsely reported.
# ---------------------------------------------------------------------------
subtest 'directory path containing a space is passed as one argument' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/dir with space", "$dir/newdir");
	write_model("$dir/dir with space/Common-Test.nmis", 'true');
	write_model("$dir/newdir/Common-Test.nmis", 'true');

	is(run_compare(old => "$dir/dir with space", new => "$dir/newdir"), 0,
	   'space in a directory path does not produce a spurious difference');
};

done_testing();
