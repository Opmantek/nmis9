#!/usr/bin/perl
#
# t_node_lock_stale.pl — tests the self-healing stale-lock fix.
#
# Part 1: Node::lock() detects a dead holder PID and recovers automatically.
# Part 2: NMISNG::clear_stale_node_locks() sweeps stale .lock files.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);

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

sub read_lock
{
	my ($name) = @_;
	my $path = "$vardir/$name.lock";
	return undef unless -f $path;
	open my $fh, '<', $path or return undef;
	my $line = <$fh>;
	close $fh;
	chomp $line if defined $line;
	return $line;
}

# Pick a PID that is almost certainly dead. We use 999999 — even if it
# happens to exist, it's outside any normal range and a probe failure
# would be noise, not a real test failure.
my $DEAD_PID = 999999;

# ============================================================
# Part 1a: dead PID -> stale, lock acquired
# ============================================================
diag("=== Part 1a: dead holder PID -> self-heal ===");
{
	my $node = make_node("test_lock_dead");
	plant_lock("test_lock_dead", $DEAD_PID, "update");

	my $r = $node->lock(type => "update");
	ok(!$r->{error},    "no error on stale-lock acquisition") or diag("err: $r->{error}");
	ok(!$r->{conflict}, "no conflict reported (was treated as stale)");
	ok($r->{handle},    "got a live file handle");

	# After acquisition, the file should record our PID.
	my $line = read_lock("test_lock_dead");
	like($line, qr/^$$ update/, "lock file now records our own PID + op");

	$node->unlock(lock => $r);
	ok(!-f "$vardir/test_lock_dead.lock", "lock file removed by unlock");
}

# ============================================================
# Part 1b: _is_pid_stale helper directly
# (Testing live conflict end-to-end through lock() requires a second
# process holding flock; the helper is the core liveness logic and is
# what lock() actually consults. Direct testing covers all the edge
# cases without needing fork.)
# ============================================================
diag("=== Part 1b: Node::_is_pid_stale liveness check ===");
{
	# Live PID — this very test process — must NOT be flagged stale.
	ok(!NMISNG::Node::_is_pid_stale($$),  "self PID (live) -> not stale");

	# Dead PID — almost certainly nothing at PID 999999.
	ok(NMISNG::Node::_is_pid_stale($DEAD_PID), "dead PID -> stale");

	# Malformed / sentinel values must all be stale.
	ok(NMISNG::Node::_is_pid_stale(undef),     "undef -> stale");
	ok(NMISNG::Node::_is_pid_stale(""),        "empty string -> stale");
	ok(NMISNG::Node::_is_pid_stale(0),         "zero -> stale");
	ok(NMISNG::Node::_is_pid_stale(-1),        "negative -> stale");
	ok(NMISNG::Node::_is_pid_stale("garbage"), "non-numeric -> stale");

	# Init PID 1 is essentially always alive on a Linux host.
	# (If somehow not, that's a system-level oddity, not a fix issue.)
	ok(!NMISNG::Node::_is_pid_stale(1), "PID 1 (init) -> not stale");
}

# ============================================================
# Part 1c: non-numeric / -1 / 0 holder -> stale
# ============================================================
diag("=== Part 1c: malformed holder -> treated as stale ===");
{
	for my $bad ("-1", "0", "garbage") {
		my $name = "test_lock_bad_$bad";
		$name =~ s/[^a-zA-Z0-9_]/_/g;     # filename-safe
		my $node = make_node($name);
		plant_lock($name, $bad, "update");

		my $r = $node->lock(type => "update");
		ok(!$r->{conflict}, "[$bad holder] no conflict, treated as stale")
			or diag("got conflict=$r->{conflict}");
		ok($r->{handle}, "[$bad holder] acquired live handle");
		$node->unlock(lock => $r) if $r->{handle};
	}
}

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
# Cleanup
# ============================================================
diag("=== Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
