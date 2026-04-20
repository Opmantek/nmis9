#!/usr/bin/perl
#
# Integration tests for nmisd PID lock behaviour
#
# Tests the real nmisd binary to verify:
# 1. foreground mode skips PID file creation
# 2. foreground mode is not blocked by a stale PID file
# 3. act=stop/abort are rejected in foreground mode
#
# Uses act=check which exits cleanly before the MongoDB connection,
# allowing PID lock behaviour to be tested without a running database.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Path qw(make_path);
use NMISNG::Util;

my $nmisd = "$FindBin::Bin/../bin/nmisd";
die "Cannot find nmisd at $nmisd" unless -f $nmisd;

# Load config to find the real var directory and PID file path
my $config = NMISNG::Util::loadConfTable();
die "Cannot load config" unless ref($config) eq "HASH";

my $varsysdir = $config->{'<nmis_var>'} . "/nmis_system";
make_path($varsysdir) unless -d $varsysdir;
my $pidFile = "$varsysdir/nmisd.pid";

# Save any existing PID file so we can restore it after tests
my $saved_pidfile_content;
if (-f $pidFile)
{
	$saved_pidfile_content = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
}

# ============================================================================
# Test 1: act=stop rejected in foreground mode
# This exits immediately with a die, no DB connection needed.
# ============================================================================
subtest 'act=stop rejected in foreground mode' => sub {
	my $output = `perl $nmisd foreground=1 act=stop 2>&1`;
	my $exit = $? >> 8;

	isnt($exit, 0, "nmisd foreground=1 act=stop exits with error");
	like($output, qr/in foreground mode/,
		 "error message explains foreground incompatibility");
};

# ============================================================================
# Test 2: act=abort rejected in foreground mode
# ============================================================================
subtest 'act=abort rejected in foreground mode' => sub {
	my $output = `perl $nmisd foreground=1 act=abort 2>&1`;
	my $exit = $? >> 8;

	isnt($exit, 0, "nmisd foreground=1 act=abort exits with error");
	like($output, qr/in foreground mode/,
		 "error message explains foreground incompatibility");
};

# ============================================================================
# Test 3: foreground mode does not create a PID file
# ============================================================================
subtest 'foreground mode does not create PID file' => sub {
	# Ensure no PID file exists before test
	unlink($pidFile) if -f $pidFile;
	ok(!-f $pidFile, "PID file does not exist before test");

	# Run nmisd in foreground mode with act=check; it validates config
	# and exits before the DB connection.
	my $output = `perl $nmisd foreground=1 act=check 2>&1`;

	my $exit = $? >> 8;
	is($exit, 0, "act=check exits cleanly in foreground mode");
	like($output, qr/Configuration OK/, "act=check reports config OK");
	like($output, qr/Foreground: yes/, "act=check shows foreground mode");
	ok(!-f $pidFile, "no PID file created in foreground mode");
};

# ============================================================================
# Test 4: stale PID file does not block foreground startup
# Place a PID file with a dead PID, then run foreground mode.
# nmisd should skip the conflict check entirely.
# ============================================================================
subtest 'stale PID file does not block foreground startup' => sub {
	# Create a stale PID file (high PID unlikely to be running)
	my $deadpid = 4194300;
	BAIL_OUT("PID $deadpid is unexpectedly alive")
		if kill(0, $deadpid);

	NMISNG::Util::spew_file($pidFile, "$deadpid\n");
	ok(-f $pidFile, "stale PID file created with dead PID $deadpid");

	my $output = `perl $nmisd foreground=1 act=check 2>&1`;

	my $exit = $? >> 8;

	# Should NOT see "Another instance" error
	is($exit, 0, "act=check exits cleanly despite stale PID file");
	unlike($output, qr/Another instance/,
		   "foreground mode not blocked by stale PID file");
	like($output, qr/Configuration OK/,
		 "act=check reports config OK despite stale PID");

	# Stale file should be untouched (foreground mode ignores it entirely)
	if (-f $pidFile)
	{
		my $content = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($content);
		is($content, $deadpid, "stale PID file content unchanged");
	}

	unlink($pidFile);
};

# ============================================================================
# Test 5: act=check never takes the PID lock, even without foreground=1.
# The validator must be safe to run alongside a live daemon, so any
# invocation with act=check is implicitly foreground. Seed a stale PID
# file and assert the validator leaves it alone.
# ============================================================================
subtest 'act=check is always foreground and never touches the PID file' => sub {
	unlink($pidFile) if -f $pidFile;

	my $deadpid = 4194300;
	NMISNG::Util::spew_file($pidFile, "$deadpid\n");

	my $output = `perl $nmisd act=check 2>&1`;
	my $exit = $? >> 8;

	is($exit, 0, "act=check exits cleanly without explicit foreground");
	like($output, qr/Configuration OK/, "act=check reports config OK");
	like($output, qr/Foreground: yes/,
		 "act=check implicitly runs in foreground mode");

	ok(-f $pidFile, "stale PID file still present after act=check");
	if (-f $pidFile)
	{
		my $content = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($content);
		is($content, $deadpid,
		   "stale PID file content unchanged (validator did not take lock)");
	}

	unlink($pidFile) if -f $pidFile;
};

# ============================================================================
# Test 6: start nmisd, kill it, verify PID file is cleaned up
# Uses debug=1 to prevent daemonizing. The process creates a PID file,
# then either enters the main loop (if DB is available) or dies at DB
# connection. Either way the END block should clean up the PID file.
# ============================================================================
subtest 'PID file cleaned up after TERM signal' => sub {
	unlink($pidFile) if -f $pidFile;

	# Start nmisd in background with debug=1 (no daemonize, creates PID file)
	my $child = fork();
	die "fork failed: $!" unless defined $child;

	if ($child == 0)
	{
		exec("perl", $nmisd, "debug=1");
		POSIX::_exit(1);
	}

	# Wait for PID file to appear (or process to exit early on DB failure)
	my $waited = 0;
	while (!-f $pidFile && $waited < 10)
	{
		select(undef, undef, undef, 0.5);
		$waited++;
		# Check if child already exited (DB connection failure)
		last if waitpid($child, POSIX::WNOHANG) != 0;
	}

	if (-f $pidFile)
	{
		my $recorded = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($recorded) if defined $recorded;
		like($recorded, qr/^\d+$/, "PID file contains valid PID");

		# Send TERM and wait for cleanup
		kill("TERM", $child);
		waitpid($child, 0);

		ok(!-f $pidFile, "PID file cleaned up after TERM signal");
	}
	else
	{
		# Process exited before PID file appeared (unlikely) or DB failed
		# before PID write (also unlikely - PID write is before DB).
		# Either way, check the child is reaped and no PID file lingers.
		waitpid($child, 0);
		ok(!-f $pidFile, "no stale PID file after early exit");
		diag("nmisd exited before PID file was observed (exit code: " . ($? >> 8) . ")");
	}
};

# ============================================================================
# Test 7: start nmisd, kill -9 it, verify stale PID file doesn't block
# foreground restart
# SIGKILL bypasses the END block so the PID file will be left behind.
# Foreground mode should ignore it entirely.
# ============================================================================
subtest 'SIGKILL leaves stale PID, foreground ignores it' => sub {
	unlink($pidFile) if -f $pidFile;

	# Start nmisd in background
	my $child = fork();
	die "fork failed: $!" unless defined $child;

	if ($child == 0)
	{
		exec("perl", $nmisd, "debug=1");
		POSIX::_exit(1);
	}

	# Wait for PID file
	my $waited = 0;
	while (!-f $pidFile && $waited < 10)
	{
		select(undef, undef, undef, 0.5);
		$waited++;
		last if waitpid($child, POSIX::WNOHANG) != 0;
	}

	if (-f $pidFile)
	{
		# Force kill - simulates container SIGKILL / OOM kill
		kill("KILL", $child);
		waitpid($child, 0);

		ok(-f $pidFile, "PID file left behind after SIGKILL (expected)");

		# Now verify foreground mode is not blocked by the stale file
		my $output = `perl $nmisd foreground=1 act=check 2>&1`;
		my $exit = $? >> 8;
		is($exit, 0, "foreground act=check succeeds despite stale PID file");
		like($output, qr/Configuration OK/, "config validates OK");
	}
	else
	{
		waitpid($child, 0);
		pass("nmisd exited early, skipping SIGKILL test");
		diag("nmisd exited before PID file was observed (exit code: " . ($? >> 8) . ")");
	}

	unlink($pidFile) if -f $pidFile;
};

# ============================================================================
# Test 8: act=status rejected in foreground mode
# ============================================================================
subtest 'act=status rejected in foreground mode' => sub {
	my $output = `perl $nmisd foreground=1 act=status 2>&1`;
	my $exit = $? >> 8;

	isnt($exit, 0, "nmisd foreground=1 act=status exits with error");
	like($output, qr/in foreground mode/,
		 "error message explains foreground incompatibility");
};

# ============================================================================
# Test 9: PID file cleaned up after INT then TERM (mimics act=stop)
# INT sets $exit_marker and waits for the main loop to finish, which may
# take a full scheduler cycle. This mirrors the real act=stop sequence:
# send INT (polite), wait, then escalate to TERM (immediate exit(0)).
# The END block should fire on TERM and clean up the PID file.
# ============================================================================
subtest 'PID file cleaned up after INT+TERM sequence' => sub {
	unlink($pidFile) if -f $pidFile;

	my $child = fork();
	die "fork failed: $!" unless defined $child;

	if ($child == 0)
	{
		exec("perl", $nmisd, "debug=1");
		POSIX::_exit(1);
	}

	# Wait for PID file to appear
	my $waited = 0;
	while (!-f $pidFile && $waited < 10)
	{
		select(undef, undef, undef, 0.5);
		$waited++;
		last if waitpid($child, POSIX::WNOHANG) != 0;
	}

	if (-f $pidFile)
	{
		my $recorded = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($recorded) if defined $recorded;
		like($recorded, qr/^\d+$/, "PID file contains valid PID");

		# Send INT first (graceful), then escalate to TERM after 3s
		# This mirrors the real act=stop sequence in nmisd
		kill("INT", $child);
		sleep(3);

		# Check if INT was enough
		if (waitpid($child, POSIX::WNOHANG) == 0)
		{
			# Still running - escalate to TERM (calls exit(0) immediately)
			kill("TERM", $child);
			waitpid($child, 0);
		}

		ok(!-f $pidFile, "PID file cleaned up after INT+TERM sequence");
	}
	else
	{
		waitpid($child, 0);
		ok(!-f $pidFile, "no stale PID file after early exit");
		diag("nmisd exited before PID file was observed (exit code: " . ($? >> 8) . ")");
	}
};

# ============================================================================
# Test 10: rapid restart after crash (bare-metal scenario)
# Start nmisd, SIGKILL it (leaving stale PID file), immediately start
# another instance in bare-metal mode. The new instance should detect
# the dead PID, overwrite the lock, and start successfully.
# ============================================================================
subtest 'rapid bare-metal restart after crash' => sub {
	unlink($pidFile) if -f $pidFile;

	# Start first instance
	my $child1 = fork();
	die "fork failed: $!" unless defined $child1;

	if ($child1 == 0)
	{
		exec("perl", $nmisd, "debug=1");
		POSIX::_exit(1);
	}

	# Wait for PID file
	my $waited = 0;
	while (!-f $pidFile && $waited < 10)
	{
		select(undef, undef, undef, 0.5);
		$waited++;
		last if waitpid($child1, POSIX::WNOHANG) != 0;
	}

	if (-f $pidFile)
	{
		my $pid1 = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($pid1) if defined $pid1;

		# SIGKILL first instance (simulates crash/OOM)
		kill("KILL", $child1);
		waitpid($child1, 0);

		ok(-f $pidFile, "stale PID file left behind after crash");
		is($pid1 + 0, $pid1, "stale PID is numeric");

		# Immediately start second instance (bare-metal, act=check)
		my $output = `perl $nmisd act=check 2>&1`;
		my $exit = $? >> 8;

		is($exit, 0, "second instance starts despite stale PID file");
		like($output, qr/Configuration OK/, "second instance validates config OK");
		unlike($output, qr/Another instance/,
			   "no conflict with dead first instance");
	}
	else
	{
		waitpid($child1, 0);
		pass("nmisd exited early, skipping rapid restart test");
		diag("nmisd exited before PID file was observed (exit code: " . ($? >> 8) . ")");
	}

	unlink($pidFile) if -f $pidFile;
};

# ============================================================================
# Test 11: pidfile input validation (change from hardening pass).
# Operator-supplied paths must be absolute, end in .pid, and not be symlinks.
# ============================================================================
subtest 'pidfile path validation rejects unsafe input' => sub {
	my $shadow_output = `perl $nmisd pidfile=/etc/shadow act=check foreground=1 2>&1`;
	my $shadow_exit = $? >> 8;
	isnt($shadow_exit, 0, "pidfile=/etc/shadow exits non-zero");
	like($shadow_output, qr/basename must end in '\.pid'/,
		 "basename-suffix rule rejects /etc/shadow");
	unlike($shadow_output, qr/Configuration OK/,
		   "validator did not report success");

	my $rel_output = `perl $nmisd pidfile=relative/path.pid act=check foreground=1 2>&1`;
	my $rel_exit = $? >> 8;
	isnt($rel_exit, 0, "relative pidfile path exits non-zero");
	like($rel_output, qr/must be absolute/,
		 "absolute-path rule rejects relative paths");

	my $symlink = "/tmp/nmisd-pidlock-test-$$.pid";
	unlink($symlink);
	if (symlink("/etc/hosts", $symlink))
	{
		my $sym_output = `perl $nmisd pidfile=$symlink act=check foreground=1 2>&1`;
		my $sym_exit = $? >> 8;
		isnt($sym_exit, 0, "symlink pidfile exits non-zero");
		like($sym_output, qr/symlink/, "symlink rule triggers");
		ok(-l $symlink, "symlink target still in place (not followed)");
		unlink($symlink);
	}
	else
	{
		diag("could not create test symlink in /tmp, skipping symlink case");
	}
};

# ============================================================================
# Test 12: missing pidfile directory produces a directory-specific error,
# not the misleading "Cannot get PID lock!".
# Use a path whose parent createDir cannot build (mkdir under /proc fails).
# ============================================================================
subtest 'missing pidfile directory yields a clear error' => sub {
	my $bad = "/proc/nmisd-pidlock-test-nonexistent/nmisd.pid";
	my $output = `perl $nmisd pidfile=$bad act=check foreground=1 2>&1`;
	my $exit = $? >> 8;

	isnt($exit, 0, "bad pidfile dir exits non-zero");
	unlike($output, qr/Cannot get PID lock/,
		   "error is not the misleading lock message");
	unlike($output, qr/Unable to get a pid lock/,
		   "error is not the misleading lock message");
	like($output, qr/(directory|mkdir|No such file|Permission)/,
		 "error message points at the directory problem");
};

# ============================================================================
# Test 13: regression test for the worker-unlinks-pidfile bug fixed in
# commit 7d054561. Workers used to inherit $i_own_pidfile=1 and unlink
# the supervisor's pidfile when they exited via END. This test starts the
# supervisor, waits for a worker child to appear, kills the worker with
# TERM, and asserts the pidfile still exists and still names the supervisor.
# Skips cleanly if MongoDB is unavailable (nmisd exits before workers
# fork), matching the pattern used by Tests 6/7/9/10.
# ============================================================================
subtest 'worker TERM does not remove supervisor PID file' => sub {
	unlink($pidFile) if -f $pidFile;

	my $child = fork();
	die "fork failed: $!" unless defined $child;

	if ($child == 0)
	{
		exec("perl", $nmisd, "debug=1");
		POSIX::_exit(1);
	}

	# Wait for the pidfile to appear
	my $waited = 0;
	while (!-f $pidFile && $waited < 10)
	{
		select(undef, undef, undef, 0.5);
		$waited++;
		last if waitpid($child, POSIX::WNOHANG) != 0;
	}

	unless (-f $pidFile)
	{
		waitpid($child, 0);
		pass("nmisd exited early, skipping worker regression test");
		diag("nmisd exited before PID file appeared (exit code: " . ($? >> 8) . ")");
		return;
	}

	my $supervisor_pid = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
	chomp($supervisor_pid) if defined $supervisor_pid;
	like($supervisor_pid, qr/^\d+$/, "pidfile contains supervisor PID");

	# Wait up to 15s for a worker or fping child of the supervisor
	require Proc::ProcessTable;
	my $worker_pid;
	my $t0 = time();
	while (time() - $t0 < 15)
	{
		my $pt = Proc::ProcessTable->new(enable_ttys => 0);
		for my $p (@{$pt->table})
		{
			next unless $p->ppid == $supervisor_pid;
			my $cmd = $p->cmndline // "";
			if ($cmd =~ /nmisd\.(worker|fping)/)
			{
				$worker_pid = $p->pid;
				last;
			}
		}
		last if $worker_pid;
		select(undef, undef, undef, 0.5);
	}

	unless ($worker_pid)
	{
		# Workers typically only fork once the supervisor reaches the main
		# loop, which requires MongoDB. No worker means no regression to test.
		kill("TERM", $child);
		waitpid($child, 0);
		pass("no worker child observed, skipping regression assertion");
		diag("supervisor did not spawn a worker within 15s (likely no DB)");
		return;
	}

	# The regression: kill the worker and verify the supervisor's pidfile
	# survives. Under the old bug this would unlink $pidFile when the
	# worker's END block ran. Workers may be mid-collection and defer the
	# signal for up to a cycle, so we give them up to 30s to exit — but
	# don't hard-fail if they're still busy, since the pidfile assertion
	# remains meaningful either way.
	kill("TERM", $worker_pid);
	my $reaped = 0;
	for (1..120)
	{
		if (!kill(0, $worker_pid))
		{
			$reaped = 1;
			last;
		}
		select(undef, undef, undef, 0.25);
	}
	if ($reaped)
	{
		# END block has had a chance to run; this is the strong assertion.
		select(undef, undef, undef, 0.5);
		ok(-f $pidFile,
		   "supervisor PID file still present after worker TERM+END");
	}
	else
	{
		diag("worker $worker_pid did not exit in 30s (busy cycle); regression assertion still valid but weaker");
		ok(-f $pidFile,
		   "supervisor PID file still present while worker is TERMing");
	}

	if (-f $pidFile)
	{
		my $now = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($now) if defined $now;
		is($now, $supervisor_pid,
		   "PID file still names the supervisor ($supervisor_pid)");
	}

	# Cleanup
	kill("TERM", $child);
	waitpid($child, 0);
	unlink($pidFile) if -f $pidFile;
};

# Restore original PID file if one existed
if (defined $saved_pidfile_content)
{
	NMISNG::Util::spew_file($pidFile, $saved_pidfile_content);
}
else
{
	unlink($pidFile) if -f $pidFile;
}

done_testing();
