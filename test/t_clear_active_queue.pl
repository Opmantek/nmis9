#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify it under the
#  terms of the GNU General Public License as published by the Free Software
#  Foundation, either version 3 of the License, or (at your option) any later
#  version. See <http://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# Behavioural test for NMISNG::clear_active_queue (OMK-12775 / defect BR-01).
#
# nmisd calls clear_active_queue at startup to remove the jobs a previous run
# left flagged active (in_progress != 0) by workers that died with it. Pending,
# overdue and future-dated jobs (in_progress == 0) must be left untouched, or
# every restart silently discards scheduled work.
#
# The original defect: clear_active_queue passed a bare HASHREF into
# get_queue_model's ($self, %args) signature, the filter collapsed to {}
# (match everything), and the loop removed EVERY queued document on each
# restart.
#
# This test seeds a real queue collection with a mix of pending and
# stale-active jobs, runs the real clear_active_queue, and asserts the pending
# jobs survive and only the active jobs are removed. It does not care how the
# filter is built, so it catches both the original wipe-everything bug and a
# no-op regression, and tolerates a refactor of the filter itself.
#
# Needs a reachable MongoDB (as the rest of ci/scripts/perl_tests.sh does).
# It skips cleanly when none is available, so it is safe on a bare host.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::DB;
use NMISNG::Log;
use NMISNG::Util;

# ---------------------------------------------------------------------------
# Bootstrap a real NMISNG against a throwaway per-run database, or skip if no
# MongoDB is reachable (keeps the test safe to run on a bare host).
# ---------------------------------------------------------------------------
my $nmisng;
END { eval { $nmisng->get_db()->drop() } if ($nmisng); }

my $C = eval { NMISNG::Util::loadConfTable() };
my $cfg_err = $@;
plan skip_all => "no NMIS config available (needs conf/): $cfg_err"
	if ( $cfg_err or ref($C) ne "HASH" or !%$C );
$C->{db_name} = "t_clear_active_queue-$$-" . time;

my $logger = NMISNG::Log->new( level => 'error' );

$nmisng = eval { NMISNG->new( config => $C, log => $logger ) };
plan skip_all => "NMISNG/MongoDB not available: " . ($@ || "constructor returned undef")
	if ( !$nmisng );

my $probe = NMISNG::DB::count(
	collection => $nmisng->queue_collection,
	query      => {},
	verbose    => 1
);
plan skip_all => "MongoDB not reachable: " . ($probe->{error} // "unknown")
	if ( !$probe->{success} );

# ---------------------------------------------------------------------------
# Seed the queue: two pending jobs (in_progress == 0) that must survive, and
# two stale-active jobs (in_progress == a start timestamp) that must be cleared.
# ---------------------------------------------------------------------------
my $now = time;

my $queue_job = sub {
	my (%over) = @_;
	my $jobdata = {
		type        => 'configbackup',    # schedulable type that needs no args
		priority    => 0.5,
		time        => $now,
		in_progress => 0,
		%over,
	};
	my ( $error, $id ) = $nmisng->update_queue( jobdata => $jobdata );
	die "failed to queue job: $error\n" if ($error);
	return $id;
};

my $job_exists = sub {
	my ($id) = @_;
	my $res = NMISNG::DB::count(
		collection => $nmisng->queue_collection,
		query      => NMISNG::DB::get_query( and_part => { _id => $id } ),
		verbose    => 1
	);
	return $res->{count};
};

my $pending_future  = $queue_job->( in_progress => 0, time => $now + 3600 );  # scheduled, not started
my $pending_overdue = $queue_job->( in_progress => 0, time => $now - 3600 );  # overdue, not started
my $active_recent   = $queue_job->( in_progress => $now - 5 );                # claimed 5s ago by a now-dead worker
my $active_older    = $queue_job->( in_progress => $now - 120 );              # claimed 2m ago by a now-dead worker

my $before = NMISNG::DB::count( collection => $nmisng->queue_collection, query => {}, verbose => 1 );
is( $before->{count}, 4, "four jobs are queued before clear_active_queue" );

# ---------------------------------------------------------------------------
# Run the real thing.
# ---------------------------------------------------------------------------
$nmisng->clear_active_queue;

# ---------------------------------------------------------------------------
# The pending jobs must survive; only the active jobs may be removed.
# ---------------------------------------------------------------------------
ok(  $job_exists->($pending_future),  "pending future-dated job survives the restart sweep" );
ok(  $job_exists->($pending_overdue), "pending overdue job survives the restart sweep" );
ok( !$job_exists->($active_recent),   "stale active job (5s) is cleared" );
ok( !$job_exists->($active_older),    "stale active job (2m) is cleared" );

my $after = NMISNG::DB::count( collection => $nmisng->queue_collection, query => {}, verbose => 1 );
is( $after->{count}, 2, "exactly the two pending jobs remain after clear_active_queue" );

done_testing();
