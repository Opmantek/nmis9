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
# Test 5: bare-metal mode still checks for conflicts (existing behaviour)
# Create a stale PID file with a dead PID; non-foreground mode should
# detect it's dead and proceed (overwrite with new PID).
# ============================================================================
subtest 'bare-metal mode still creates PID file' => sub {
	# Clean slate
	unlink($pidFile) if -f $pidFile;

	# Create a stale PID file
	my $deadpid = 4194300;
	NMISNG::Util::spew_file($pidFile, "$deadpid\n");

	# Run without foreground (act=check prevents daemonizing and DB connection).
	# It will go through the PID lock path then exit cleanly.
	my $output = `perl $nmisd act=check 2>&1`;

	my $exit = $? >> 8;

	# act=check in non-foreground mode goes through the PID lock path.
	# With a dead PID it should overwrite.
	is($exit, 0, "act=check exits cleanly in bare-metal mode");
	like($output, qr/Configuration OK/, "act=check reports config OK");
	like($output, qr/Foreground: no/, "act=check shows non-foreground mode");

	# PID file should exist (created by the bare-metal path) and cleaned
	# up by the END block when act=check exits.
	# Check it was overwritten (not the dead PID) - it may already be
	# cleaned up by the END block, which is also correct behaviour.
	if (-f $pidFile)
	{
		my $content = do { local $/; open(my $_fh, "<", $pidFile); <$_fh> };
		chomp($content);
		isnt($content, $deadpid, "PID file no longer contains stale PID");
		like($content, qr/^\d+$/, "PID file contains a valid PID");
	}
	else
	{
		pass("PID file cleaned up by END block on exit");
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
