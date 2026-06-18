#!/usr/bin/perl
#
# t_node_lock_stale.pl — tests per-node lock cleanup.
#
# Part 2: NMISNG::clear_stale_node_locks() sweeps stale .lock files (removes
#         those whose recorded holder PID is dead, leaves live ones).
# Part 3: the production scenario — a worker killed mid-collect while a child
#         holds the inherited lock fd, and how the sweep recovers it. lock()
#         itself does NOT self-heal; orphaned workers are cleared at the process
#         layer (nmisd kills leftover workers at startup, systemd KillMode), and
#         the sweep tidies the lock files they leave behind.
#

use strict;
use warnings;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use POSIX ();

use NMISNG;
use NMISNG::Node;
use NMISNG::Util;
use NMISNG::Log;

# ============================================================
# Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

# Override <nmis_var> to a private temp dir so this test is fully isolated
# and never collides with real lock files in /usr/local/nmis9/var.
my $vardir = tempdir(CLEANUP => 1);
$C->{'<nmis_var>'} = $vardir;
$C->{db_name}      = "t_node_lock_stale-" . time;

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

sub make_node
{
	my ($name) = @_;
	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$node->cluster_id($C->{cluster_id});
	$node->name($name);
	$node->configuration({
		host      => "127.0.0.1",
		group     => "TestGroup",
		netType   => "default",
		roleType  => "default",
		threshold => 1,
		model     => "Default",
		collect   => "true",
		ping      => "false",
		community => "public",
	});
	my ($op, $err) = $node->save();
	die "saving $name failed: $err" if $err;
	return $node;
}

# Helper: write a hand-crafted lock file with a given PID + op string.
sub plant_lock
{
	my ($name, $pid, $op) = @_;
	my $path = "$vardir/$name.lock";
	open my $fh, '>', $path or die "cannot create $path: $!";
	print $fh "$pid $op\n";
	close $fh;
	return $path;
}

# Read just the holder PID out of an arbitrary file written by a forked helper.
sub _slurp_pid
{
	my ($f) = @_;
	open my $h, '<', $f or return undef;
	my $x = <$h>;
	close $h;
	chomp $x if defined $x;
	return $x;
}

# Child PIDs that hold an inherited lock fd; killed in END as a backstop so a
# failed assertion can't leave a 30s sleeper holding a lock.
my @orphan_children;
END { kill 9, $_ for grep { $_ } @orphan_children; }

# Build the production stuck-lock: a worker acquires the node lock, forks a
# child that inherits the lock fd (an external poller / wmic / plugin), then the
# worker dies WITHOUT unlocking (nmisd killed -9). The child stays alive holding
# the fd, so flock remains held while the recorded holder PID is dead — the only
# state in which a leftover .lock actually blocks the next collect.
# Returns ($node, $worker_pid_now_dead, $child_pid_still_alive).
sub make_orphan_stuck_lock
{
	my ($name) = @_;
	my $node = make_node($name);
	my $w = fork();
	die "fork failed: $!" if !defined $w;
	if ($w == 0)
	{
		my $r = $node->lock(type => "update");
		POSIX::_exit(1) if !$r->{handle};
		my $c = fork();
		if (defined $c && $c == 0)
		{
			open my $f, '>', "$vardir/${name}_c"; print $f $$; close $f;
			sleep 30;                 # keep the inherited fd open
			POSIX::_exit(0);
		}
		open my $f, '>', "$vardir/${name}_w"; print $f $$; close $f;
		POSIX::_exit(0);              # worker dies without unlock
	}
	waitpid($w, 0);
	my $t = 0;
	until (-e "$vardir/${name}_c") { select(undef,undef,undef,0.02); die "timeout setting up $name\n" if (($t += 0.02) > 15); }
	select(undef, undef, undef, 0.2);
	my $cpid = _slurp_pid("$vardir/${name}_c");
	push @orphan_children, $cpid if $cpid;
	return ($node, _slurp_pid("$vardir/${name}_w"), $cpid);
}

# Is the node's lock file currently blocking acquisition (someone holds flock)?
sub lock_blocked
{
	my ($name) = @_;
	my $fn = "$vardir/$name.lock";
	return 0 if !-f $fn;
	open my $fh, '+<', $fn or return 0;
	my $got = flock($fh, LOCK_EX | LOCK_NB);
	close $fh;                       # releases only our probe handle
	return $got ? 0 : 1;
}

# Pick a PID that is almost certainly dead. We use 999999 — even if it
# happens to exist, it's outside any normal range and a probe failure
# would be noise, not a real test failure.
my $DEAD_PID = 999999;

# ============================================================
# Part 2: clear_stale_node_locks() sweep
# ============================================================
diag("=== Part 2: NMISNG->clear_stale_node_locks() sweep ===");
{
	# Plant a mix: two dead, one live, plus a non-.lock file that should be ignored.
	plant_lock("sweep_dead_a", $DEAD_PID,     "update");
	plant_lock("sweep_dead_b", $DEAD_PID + 1, "collect");
	plant_lock("sweep_live",   $$,            "update");
	open my $fh, '>', "$vardir/not_a_lock.txt" or die;
	print $fh "irrelevant";
	close $fh;

	# Instance form
	my $cleaned = $nmisng->clear_stale_node_locks();
	is($cleaned, 2, "instance form: removed exactly 2 stale locks");
	ok(!-f "$vardir/sweep_dead_a.lock", "sweep_dead_a.lock removed");
	ok(!-f "$vardir/sweep_dead_b.lock", "sweep_dead_b.lock removed");
	ok(-f  "$vardir/sweep_live.lock",  "sweep_live.lock preserved");
	ok(-f  "$vardir/not_a_lock.txt",   "non-.lock file preserved");

	# Idempotent: a second sweep finds nothing more to do.
	is($nmisng->clear_stale_node_locks(), 0, "second sweep is a no-op");

	# Class-method form (used by nmisd act=stop/abort before NMISNG instance exists).
	plant_lock("sweep_class_form_dead", $DEAD_PID, "update");
	my $cleaned2 = NMISNG->clear_stale_node_locks(config => $C, log => $logger);
	is($cleaned2, 1, "class-method form: removed 1 stale lock");
	ok(!-f "$vardir/sweep_class_form_dead.lock", "class-method removed dead lock");

	# Cleanup the live one we left behind.
	unlink("$vardir/sweep_live.lock");
}

# ============================================================
# Part 3: orphaned-fd stuck lock — the real production scenario
# (nmisd/worker killed mid-collect while a child still holds the lock fd).
# This is the only case where a leftover .lock actually blocks polling;
# a plain death with no surviving fd releases flock and never sticks.
# ============================================================
diag("=== Part 3: orphaned-fd stuck lock (nmisd killed mid-collect) ===");
{
	# 3a: a child holds the inherited fd; recorded worker PID is dead.
	my ($node, $wpid, $cpid) = make_orphan_stuck_lock("orphan_stuck");
	ok(lock_blocked("orphan_stuck"), "3a: orphaned-fd lock blocks acquisition (collect would be skipped)");
	ok(!kill(0, $wpid),
		"3a: recorded holder PID ($wpid) is dead while child ($cpid) holds the fd");

	# 3b: the sweep clears it by dead recorded PID, even though flock is still held.
	#     (A flock-before-unlink sweep could NOT, because $cpid holds the lock.)
	my $cleaned = $nmisng->clear_stale_node_locks();
	ok($cleaned >= 1, "3b: sweep removed the stale lock despite the held flock");
	ok(!-f "$vardir/orphan_stuck.lock", "3b: lock file removed");
	my $r = $node->lock(type => "update");
	ok($r->{handle} && !$r->{conflict}, "3b: collect can acquire again after the sweep");
	$node->unlock(lock => $r) if $r->{handle};
	kill 9, $cpid if $cpid;
}
{
	# 3c: lock() does NOT steal a live-held lock — it reports the conflict.
	# With the self-heal removed, a held flock always yields a conflict rather
	# than an unlink+retry, so the live holder is left untouched.
	my ($node, $wpid, $cpid) = make_orphan_stuck_lock("orphan_conflict");
	my $r = $node->lock(type => "update");
	ok(!$r->{handle},  "3c: lock() did not acquire a live-held lock");
	ok($r->{conflict}, "3c: lock() reported the conflict instead of stealing it");
	kill 9, $cpid if $cpid;
}
{
	# 3d: boundary — if NO fd-holder survives the kill, the kernel releases flock
	# on death, so the leftover file does not block. This is the all-processes-
	# killed case: the startup sweep tidies the file, but it was never blocking.
	my $node = make_node("orphan_clean");
	my $w = fork();
	die "fork failed: $!" if !defined $w;
	if ($w == 0)
	{
		my $r = $node->lock(type => "update");
		POSIX::_exit(1) if !$r->{handle};
		open my $f, '>', "$vardir/orphan_clean_ready"; print $f $$; close $f;
		sleep 30; POSIX::_exit(0);
	}
	my $t = 0;
	until (-e "$vardir/orphan_clean_ready") { select(undef,undef,undef,0.02); last if (($t += 0.02) > 15); }
	kill 9, $w; waitpid($w, 0);
	select(undef, undef, undef, 0.2);
	ok(!lock_blocked("orphan_clean"),
		"3d: no surviving fd-holder -> leftover lock does NOT block (flock released on death)");
}

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
