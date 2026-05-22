#!/usr/bin/perl
#
# Test for NMISNG::DB statistics tracking (counts and times)
# Validates that _start_time_and_count increments counters and accumulates time,
# and that reset_db_stats clears everything.
#
# Usage: perl test/t_db_stats.pl
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Time::HiRes ();

use NMISNG::DB;

# --- Test 1: stats start empty after reset ---
NMISNG::DB::reset_db_stats();
my $stats = NMISNG::DB::get_db_stats();
is_deeply($stats->{counts}, {}, "counts empty after reset");
is_deeply($stats->{times}, {}, "times empty after reset");

# --- Test 2: _start_time_and_count increments count and records time ---
{
	# simulate what a DB function does: call _start_time_and_count,
	# do some work, then let the guard go out of scope
	my $_timer = NMISNG::DB::_start_time_and_count('test_func');
	Time::HiRes::usleep(50_000);  # sleep 50ms
}
# guard is now destroyed, time should be recorded

$stats = NMISNG::DB::get_db_stats();
is($stats->{counts}->{test_func}, 1, "count is 1 after one call");
ok(defined $stats->{times}->{test_func}, "time entry exists");
ok($stats->{times}->{test_func} > 0, "time is greater than zero");
ok($stats->{times}->{test_func} >= 0.04, "time is at least 40ms (slept 50ms)");

# --- Test 3: multiple calls accumulate ---
{
	my $_timer = NMISNG::DB::_start_time_and_count('test_func');
	Time::HiRes::usleep(20_000);  # sleep 20ms
}
$stats = NMISNG::DB::get_db_stats();
is($stats->{counts}->{test_func}, 2, "count is 2 after two calls");
ok($stats->{times}->{test_func} >= 0.06, "time accumulated across both calls");

# --- Test 4: different function names are tracked independently ---
{
	my $_timer = NMISNG::DB::_start_time_and_count('other_func');
	Time::HiRes::usleep(10_000);
}
$stats = NMISNG::DB::get_db_stats();
is($stats->{counts}->{other_func}, 1, "other_func counted separately");
ok($stats->{times}->{other_func} > 0, "other_func time tracked separately");
is($stats->{counts}->{test_func}, 2, "test_func count unchanged");

# --- Test 5: reset clears everything ---
NMISNG::DB::reset_db_stats();
$stats = NMISNG::DB::get_db_stats();
is_deeply($stats->{counts}, {}, "counts empty after second reset");
is_deeply($stats->{times}, {}, "times empty after second reset");

# --- Test 6: early scope exit still records time ---
{
	my $_timer = NMISNG::DB::_start_time_and_count('early_exit');
	Time::HiRes::usleep(10_000);
	# simulate early return - guard destroyed here
	goto AFTER_SCOPE if 1;
}
AFTER_SCOPE:
$stats = NMISNG::DB::get_db_stats();
is($stats->{counts}->{early_exit}, 1, "count recorded on early scope exit");
ok($stats->{times}->{early_exit} > 0, "time recorded on early scope exit");

done_testing();
