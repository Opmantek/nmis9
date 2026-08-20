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
# OMK-12775 / DEFECT_REGISTER BR-01
#
# nmisd startup calls NMISNG::clear_active_queue to remove the jobs left flagged
# as active (in_progress) by a previous run whose workers died with it. Pending,
# postponed and future-dated jobs (in_progress == 0) must be left untouched.
#
# in_progress is a marker: 0 when the job has not started, else the Time::HiRes
# timestamp of when a worker claimed it (see NMISNG.pm "in_progress marker").
# So an "active" job is in_progress != 0, matching the sibling running-jobs
# query in get_upcoming_jobs (in_progress => {'$ne' => 0}).
#
# The defect: clear_active_queue called get_queue_model({ in_progress => 1 }) --
# a bare HASHREF into a sub whose signature is ($self, %args). The hashref
# flattens to a single stringified-ref key with an undef value, get_query drops
# the undef filter, the Mongo filter collapses to {} (match everything), and the
# loop then removes EVERY queued document on each restart.
#
# This test drives the real chain:
#     clear_active_queue -> get_queue_model -> NMISNG::DB::get_query
# and intercepts the query handed to NMISNG::DB::find. It asserts the built
# filter restricts removal to active jobs (in_progress != 0) and is not the
# empty match-everything filter.
#
# RED before the fix (captured filter == {}), GREEN after
# (captured filter == { in_progress => { '$ne' => 0 } }). Needs no live MongoDB.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;

use NMISNG;
use NMISNG::DB;
use NMISNG::ModelData;

# ---------------------------------------------------------------------------
# Minimal test doubles so we can exercise the real clear_active_queue and
# get_queue_model without a NMISNG instance or a MongoDB connection.
# ---------------------------------------------------------------------------
{
	# a logger whose every method is a no-op
	package t::SilentLog;
	our $AUTOLOAD;
	sub new { return bless {}, shift }
	sub AUTOLOAD { return }
	sub DESTROY  { return }
}
{
	# a NMISNG subclass that keeps the real queue logic but stubs the two
	# instance methods that would otherwise need a live object / database
	package t::QueueNMISNG;
	our @ISA = ('NMISNG');
	sub log              { return t::SilentLog->new }
	sub queue_collection { return 't_fake_queue_collection' }
}
{
	# a cursor that yields no documents, so the removal loop never runs
	package t::EmptyCursor;
	sub new { return bless {}, shift }
	sub all { return () }
}

# Capture the query that get_queue_model builds and hands to DB::find,
# and stop the call before it touches MongoDB. get_query itself runs for real.
my $captured_query;
my $find_called = 0;
{
	no warnings 'redefine';
	local *NMISNG::DB::find = sub {
		my (%args) = @_;
		$captured_query = $args{query};
		$find_called++;
		return t::EmptyCursor->new;
	};

	my $fake = bless {}, 't::QueueNMISNG';
	$fake->clear_active_queue;
}

ok( $find_called, "clear_active_queue reached the queue query (DB::find called)" )
	or diag("DB::find was never called - the chain did not run as expected");

ok( defined $captured_query && ref($captured_query) eq 'HASH',
	"a query filter was built and captured" )
	or diag("captured filter: " . (defined $captured_query ? $captured_query : 'undef'));

my $filter_size = ref($captured_query) eq 'HASH' ? scalar(keys %$captured_query) : 0;
ok( $filter_size > 0,
	"queue filter is NOT the empty match-everything filter {}" )
	or diag("filter collapsed to {} -> clear_active_queue would wipe the entire job queue");

is_deeply( $captured_query, { in_progress => { '$ne' => 0 } },
	"queue filter restricts removal to active jobs (in_progress != 0) only" )
	or diag("built filter was: " . explain($captured_query));

done_testing();
