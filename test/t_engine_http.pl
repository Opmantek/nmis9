#!/usr/bin/perl
# Tests for NMISNG::Sys::Engine::HTTP using a forked Mojolicious fixture.
# The fixture runs in a child process; tests run in the parent so that
# Mojo::UserAgent's IOLoop is not contending with the server's IOLoop
# (sharing one IOLoop deadlocks under some Mojolicious versions).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use File::Temp qw(tempfile);
use POSIX ":sys_wait_h";

eval { require Mojolicious; require Mojo::Server::Daemon; 1 }
	or plan skip_all => "Mojolicious not available: $@";

# --- fixture: spawn a child process running the server -------------------
my ($fh, $portfile) = tempfile(UNLINK => 1);
close $fh;

my $child_pid = fork();
defined($child_pid) or BAIL_OUT("fork failed: $!");

if ($child_pid == 0)
{
	# Child: build a Mojolicious app programmatically (no Lite import sugar
	# so this works cleanly under fork), bind, write port, run loop.
	require Mojolicious;
	require Mojo::Server::Daemon;

	my $app = Mojolicious->new;
	$app->log->level('warn');
	my $r = $app->routes;

	$r->get('/metrics' => sub {
		my $c = shift;
		$c->res->headers->content_type('text/plain; version=0.0.4');
		$c->render(text => <<'EOM');
# HELP node_load1 1m load average
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_memory_MemFree_bytes Free memory in bytes
# TYPE node_memory_MemFree_bytes gauge
node_memory_MemFree_bytes 1.234e9
# HELP app_queue_depth queue depth
# TYPE app_queue_depth gauge
app_queue_depth{queue="orders"} 3
app_queue_depth{queue="payments"} 1
app_queue_depth{queue="email"} 7
app_queue_depth{queue="ignore_me"} 99
# HELP mock_collstats two-label metric for match_labels-at-discovery tests
# TYPE mock_collstats gauge
mock_collstats{collection="events",database="nmisng"} 60
mock_collstats{collection="orders",database="nmisng"} 5
mock_collstats{collection="events",database="opevents"} 163
mock_collstats{collection="eventqueue",database="opevents"} 3
# Two samples that both serialize to "a__b__c" under join("__", ...) —
# stresses the composite-index round-trip robustness tests.
mock_collstats{collection="b__c",database="a"} 99
mock_collstats{collection="c",database="a__b"} 88
EOM
	});

	$r->get('/status' => sub {
		my $c = shift;
		$c->render(json => { app => { uptime_seconds => 3600, state => 'running' } });
	});

	$r->get('/pool/:id/stats' => sub {
		my $c = shift;
		my $id = $c->stash('id');
		$c->render(json => { pool => $id, members => [
			{ name => "$id-a", value => 100 },
			{ name => "$id-b", value => 200 },
		]});
	});

	$r->get('/big_metrics' => sub {
		my $c = shift;
		$c->res->headers->content_type('text/plain; version=0.0.4');
		my @lines = ('# TYPE big_metric gauge');
		for my $i (1 .. 500)
		{
			push @lines, qq{big_metric{label_x="value_$i"} $i};
		}
		$c->render(text => join("\n", @lines) . "\n");
	});

	my $daemon = Mojo::Server::Daemon->new(
		app    => $app,
		listen => ['http://127.0.0.1:0'],
	);
	$daemon->silent(1);
	$daemon->start;
	my $port = $daemon->ports->[0];
	open my $pf, '>', $portfile or die "cannot write portfile: $!";
	print $pf $port;
	close $pf;
	$daemon->run;
	exit 0;
}

# Parent: wait for child to write the port
my $port;
for (1 .. 100)
{
	if (-s $portfile)
	{
		open my $pf, '<', $portfile or next;
		my $p = <$pf>;
		close $pf;
		chomp $p if defined $p;
		if (defined $p && $p =~ /^\d+$/)
		{
			$port = $p;
			last;
		}
	}
	select undef, undef, undef, 0.05;
}
END { kill 'TERM', $child_pid if $child_pid; waitpid $child_pid, 0 if $child_pid; }
$port or BAIL_OUT("fixture child did not write a port");
diag("fixture listening on port $port");

# --- now load the engine + the fake Sys (after fork to keep child slim) --
require NMISNG::Sys::Engine::HTTP;
NMISNG::Sys::Engine::HTTP->import;

# shared fakes (FakeSys carries the eval_string CVAR support this file needs)
require NMISNG::Test::Fakes;

# Helper: make engine + fake sys; caller must keep both alive (engine weak-refs sys).
sub make_engine
{
	my (%args) = @_;
	my $sys = NMISNG::Test::FakeSys->new(node_cfg => $args{node_cfg});
	my $eng = NMISNG::Sys::Engine::HTTP->new(sys => $sys);
	$eng->set_endpoints($args{endpoints});
	return ($eng, $sys);
}

# --- scalar Prometheus extraction ----------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $sec = {
		'-common-' => { endpoint => 'fix' },
		load1      => { metric => 'node_load1' },
		memfree    => { metric => 'node_memory_MemFree_bytes' },
	};
	my $bs = $eng->build_queries(
		section_name => 'cpu',
		section_key  => 'http_prom',
		section_hash => $sec,
		todos        => \%todos,
	);
	is($bs->{error}, undef, "scalar prom: build no error");
	$eng->execute_queries(todos => \%todos);
	is($todos{load1}{rawvalue},   0.42,    "load1 value");
	is($todos{load1}{done},       1,       "load1 done");
	is($todos{memfree}{rawvalue}, 1.234e9, "memfree value");
}

# --- scalar JSON extraction -----------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'app',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'fix', path => '/status' },
			uptime     => { jsonpath => '$.app.uptime_seconds' },
			state      => { jsonpath => '$.app.state' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{uptime}{rawvalue}, 3600,      "json: uptime");
	is($todos{state}{rawvalue},  'running', "json: state string");
}

# --- discover_indexes for label-as-index Prom section ---------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'queue',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				depth      => { metric => 'app_queue_depth' },
			},
		},
		index_var => 'queue',
	);
	is($err, undef, "discover_indexes: no error");
	is_deeply([sort @$idx], [sort qw(orders payments email ignore_me)],
		"discover_indexes: all four queue values");
}

# --- per-index extraction -------------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my $sec_hash = {
		'-common-' => { endpoint => 'fix' },
		depth      => { metric => 'app_queue_depth' },
	};
	my %values;
	for my $q (qw(orders payments email))
	{
		my %todos;
		$eng->build_queries(
			section_name    => 'AppQueues',
			section_key     => 'http_prom',
			section_hash    => $sec_hash,
			section_indexed => 'queue',
			index           => $q,
			todos           => \%todos,
		);
		$eng->execute_queries(todos => \%todos);
		$values{$q} = $todos{depth}{rawvalue};
	}
	is($values{orders},   3, "indexed: orders");
	is($values{payments}, 1, "indexed: payments");
	is($values{email},    7, "indexed: email");
}

# --- index-self pattern: metric-less item -> rawvalue = index value ------
# Models commonly declare an item whose role is to record the row's
# identifier (e.g. an interface name). With no metric/jsonpath/calculate_url,
# the engine fills rawvalue with the index value.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my $sec_hash = {
		'-common-' => { endpoint => 'fix' },
		queue      => { title => 'Queue name' },              # no metric -> index-self
		depth      => { metric => 'app_queue_depth' },
	};
	my %todos;
	$eng->build_queries(
		section_name    => 'AppQueues',
		section_key     => 'http_prom',
		section_hash    => $sec_hash,
		section_indexed => 'queue',
		index           => 'orders',
		todos           => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{queue}{rawvalue}, 'orders',
		"metric-less indexed item populated with index value");
	is($todos{queue}{done}, 1,
		"metric-less indexed item marked done so Sys::getValues stores it");
	is($todos{depth}{rawvalue}, 3, "sibling metric extraction still works");

	# Sanity: outside an indexed section, a metric-less item is still an error
	# (no fallback semantics make sense without an index).
	my %nope;
	my $bs = $eng->build_queries(
		section_name => 'scalar_oops',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			x          => { title => 'no metric here' },
		},
		todos => \%nope,
	);
	ok(defined $bs->{error}, "non-indexed item without metric is still an error");
}

# --- discover_indexes returns ALL candidates ----------------------------
# The engine deliberately does not filter rows here. Even if the section
# declares a `control` expression, every discovered label tuple becomes
# inventory; the canonical NMIS control evaluation (in Sys::getValues)
# decides which rows are actively polled. This matches SNMP/WMI and is
# verified end-to-end in t_sys.pl test 14b.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'queue',
			control   => 'CVAR=queue;$CVAR =~ /^(orders|payments)$/',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				depth      => { metric => 'app_queue_depth' },
			},
		},
		index_var => 'queue',
	);
	is($err, undef,
		"discover_indexes: no error even with control on section");
	is_deeply([sort @$idx], [sort qw(orders payments email ignore_me)],
		"discover_indexes returns ALL candidates; control filters at collection time");
}

# --- discover_indexes respects match_labels (no ghost rows) -------------
# When every item in a section declares the same match_labels constraint
# (e.g. database='nmisng' for MongoDB collstats), candidates whose only
# samples are in OTHER databases must NOT be returned. Otherwise the
# caller would create inventory rows for them and try to write RRDs that
# never get data, producing the "No such file or directory" render error
# the user hit on dockerhost-snmp-fast.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'collection',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats',
				                match_labels => { database => 'nmisng' } },
			},
		},
		index_var => 'collection',
	);
	is($err, undef, "match_labels-at-discovery: no error");
	# Fixture has events+orders in nmisng, events+eventqueue in opevents.
	# With match_labels filter, only nmisng's collection names qualify.
	is_deeply([sort @$idx], [sort qw(events orders)],
		"match_labels-at-discovery: only nmisng candidates returned");
	# Specifically: eventqueue is opevents-only and must NOT appear.
	ok(!(grep { $_ eq 'eventqueue' } @$idx),
		"match_labels-at-discovery: eventqueue (opevents-only) NOT in candidates");
}

# --- discover_indexes still accepts samples that satisfy ANY item ------
# If items disagree on match_labels (e.g. one wants mode=user, another
# mode=system on the same metric), the candidate is valid as long as
# SOME item's tuple matches. This is the existing CPU-modes pattern.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'collection',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				# Two items with different match_labels — index value is
				# valid if EITHER satisfies.
				nmisng_count => { metric => 'mock_collstats',
				                  match_labels => { database => 'nmisng' } },
				opevents_count => { metric => 'mock_collstats',
				                    match_labels => { database => 'opevents' } },
			},
		},
		index_var => 'collection',
	);
	is_deeply([sort @$idx], [sort qw(events orders eventqueue)],
		"discover_indexes: ANY-item-matches semantics works (union of constraints)");
}

# --- extract_label returns a label's value, not the metric value --------
# Lets a model surface a secondary label (e.g. `database` on a
# collection-indexed section) into inventory as a regular field so it
# shows up in the System Health table alongside the index value.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => 'collection',
		index           => 'orders',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			# Pull the matching sample's `database` label, not its value.
			db_name => { metric        => 'mock_collstats',
			             match_labels  => { database => 'nmisng' },
			             extract_label => 'database' },
			# Sibling that takes the value as usual, for comparison.
			cnt     => { metric        => 'mock_collstats',
			             match_labels  => { database => 'nmisng' } },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{db_name}{rawvalue}, 'nmisng',
		"extract_label: returned the matched sample's database label");
	is($todos{cnt}{rawvalue}, 5,
		"extract_label: sibling without extract_label still returns the value");
}

# --- composite indexing: indexed=['database','collection'] -----------
# Two-label composite — the engine joins per-row label values with `__`
# so collections with the same name in different databases don't
# collide on a single-label index.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => ['database', 'collection'],
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => ['database', 'collection'],
	);
	is($err, undef, "composite: discover_indexes succeeded");
	# Fixture has events+orders in nmisng, events+eventqueue in opevents.
	# Composite indexing keeps all four candidates distinct.
	# (Filter out the collision-fixture rows under db=a/db=a__b — they're
	# exercised in their own test below.)
	my @mongoish = sort grep { !/^a(__b)?__/ } @$idx;
	is_deeply(\@mongoish,
		[sort qw(nmisng__events nmisng__orders opevents__events opevents__eventqueue)],
		"composite: all four (db, coll) tuples returned distinctly");
	# In particular, the shared `events` name must appear under BOTH
	# database prefixes — no collision.
	ok((grep { $_ eq 'nmisng__events' }   @$idx), "composite: nmisng/events present");
	ok((grep { $_ eq 'opevents__events' } @$idx), "composite: opevents/events present");
}

# --- composite extraction round-trips through build_queries -----------
# The synthesized row index gets split back into per-label match
# constraints when build_queries runs, so each row extracts only its
# own (db, coll) sample even though the model declares no match_labels.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'opevents__events',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
			db         => { metric => 'mock_collstats',
			                extract_label => 'database' },
			coll       => { metric => 'mock_collstats',
			                extract_label => 'collection' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{cnt}{rawvalue},  163,        "composite: opevents/events count");
	is($todos{db}{rawvalue},   'opevents', "composite: extract_label database");
	is($todos{coll}{rawvalue}, 'events',   "composite: extract_label collection");

	# A different row in the same fixture — composite scoping picks
	# the right sample, not the first sibling with the same collection.
	my %todos2;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'nmisng__events',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
		},
		todos => \%todos2,
	);
	$eng->execute_queries(todos => \%todos2);
	is($todos2{cnt}{rawvalue}, 60,
		"composite: nmisng/events count (different DB, same collection name)");
}

# --- discover_indexes cache disambiguates by endpoint -------------------
# Same URL, different endpoint names — discovery must NOT share cached
# bodies (mirrors the execute_queries cache test). Two endpoints can
# resolve to the same URL but carry different auth.
{
	my ($eng, $sys) = make_engine(
		endpoints => [
			{ name => 'fixA', port => $port },
			{ name => 'fixB', port => $port },
		],
	);

	my %fetch_count;
	my $orig_fetch = \&NMISNG::Sys::Engine::HTTP::_fetch;
	no warnings 'redefine';
	local *NMISNG::Sys::Engine::HTTP::_fetch = sub {
		my ($self, $endpoint, $url) = @_;
		$fetch_count{$url}++;
		return $self->$orig_fetch($endpoint, $url);
	};
	use warnings 'redefine';

	my ($errA, $idxA) = $eng->discover_indexes(
		section_config => {
			indexed   => 'database',
			http_prom => {
				'-common-' => { endpoint => 'fixA' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => 'database',
	);
	my ($errB, $idxB) = $eng->discover_indexes(
		section_config => {
			indexed   => 'database',
			http_prom => {
				'-common-' => { endpoint => 'fixB' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => 'database',
	);
	is($errA, undef, "discover_indexes cache: fixA succeeded");
	is($errB, undef, "discover_indexes cache: fixB succeeded");
	my $total = 0; $total += $_ for values %fetch_count;
	is($total, 2,
		"discover_indexes: _fetch called twice (cache disambiguates by endpoint)");
	is(scalar(keys %{$eng->{response_cache}}), 2,
		"discover_indexes: response_cache holds two entries (one per endpoint)");
}

# --- composite index round-trip via component map ----------------------
# discover_indexes records the per-component label values into
# $eng->{_index_components}; build_queries reads from the map instead of
# re-splitting on `__`. With the map populated, round-trip is exact even
# for label values that contain the separator.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);

	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => ['database', 'collection'],
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => ['database', 'collection'],
	);
	is($err, undef, "component map: discover_indexes succeeded");
	is_deeply($eng->{_index_components}{'nmisng__events'},
		['nmisng', 'events'],
		"component map: nmisng/events components stashed");
	is_deeply($eng->{_index_components}{'opevents__eventqueue'},
		['opevents', 'eventqueue'],
		"component map: opevents/eventqueue components stashed");

	# Map drives extraction — clear the cache so build_queries can't lean
	# on previously-fetched bodies; component values must come from the
	# map. (We re-fetch — that's fine; the goal is to prove that the row
	# scoping uses the map, not the split fallback.)
	delete $eng->{response_cache};
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'opevents__eventqueue',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{cnt}{rawvalue}, 3,
		"component map: build_queries scoped row via stashed components");

	# Now wipe the map and re-run — the split fallback must still work
	# for unambiguous label values (no `__` in any component).
	delete $eng->{_index_components};
	delete $eng->{response_cache};
	my %todos2;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'opevents__eventqueue',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
		},
		todos => \%todos2,
	);
	$eng->execute_queries(todos => \%todos2);
	is($todos2{cnt}{rawvalue}, 3,
		"component map: split fallback still works when map is absent");
}

# --- composite index resists `__`-in-value collision -------------------
# The fixture deliberately includes two samples that both serialize to
# "a__b__c" under join("__", ...): (db=a, coll=b__c) and (db=a__b, coll=c).
# discover_indexes must surface BOTH via the component map (different
# arrays, even though the synthesized string collides). build_queries
# then routes by whichever map entry survived (last-wins via //=) — and
# warns when the split fallback would mis-decompose.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);

	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => ['database', 'collection'],
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => ['database', 'collection'],
	);
	is($err, undef, "collision: discover_indexes succeeded");

	# Both pathological rows synthesize to the same string — the index
	# list contains "a__b__c" exactly once (composite identifier set).
	my @collisions = grep { $_ eq 'a__b__c' } @$idx;
	is(scalar @collisions, 1,
		"collision: a__b__c appears once as composite identifier");

	# But the component map carries one of the two component arrays.
	# `//=` semantics mean first-write wins, so whichever sample the
	# Prom parser yielded first is the surviving binding. The point is
	# that the binding is exact, not the result of an ambiguous split.
	my $components = $eng->{_index_components}{'a__b__c'};
	ok(ref $components eq 'ARRAY' && @$components == 2,
		"collision: component map has a 2-element array for a__b__c");
	ok((($components->[0] eq 'a'    && $components->[1] eq 'b__c')
	 || ($components->[0] eq 'a__b' && $components->[1] eq 'c')),
		"collision: stored components match one of the two real rows");

	# build_queries with the map present — extraction targets the
	# component-map binding, regardless of how the string would split.
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'a__b__c',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
			db         => { metric => 'mock_collstats',
			                extract_label => 'database' },
			coll       => { metric => 'mock_collstats',
			                extract_label => 'collection' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	# Whichever row won the //= race, db/coll must match each other —
	# i.e. extraction is consistent with the map binding, not with a
	# naive split.
	is($todos{db}{rawvalue},   $components->[0],
		"collision: extracted database matches map binding");
	is($todos{coll}{rawvalue}, $components->[1],
		"collision: extracted collection matches map binding");
	# And the count belongs to that specific row (99 for b__c, 88 for c).
	my $expected = ($components->[1] eq 'b__c') ? 99 : 88;
	is($todos{cnt}{rawvalue}, $expected,
		"collision: count matches the row identified by the map");
}

# --- discover_indexes writes per-component fields into targets ----------
# discover_indexes returns a `targets` hash that Node.pm pipes through to
# $inventory->data(...). For composite-indexed sections, those targets
# now include each label component as its own data field, so that the
# values persist into inventory and survive across Sys lifetimes.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx, $targets) = $eng->discover_indexes(
		section_config => {
			indexed   => ['database', 'collection'],
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => ['database', 'collection'],
	);
	is($err, undef, "targets: discover succeeded");
	is($targets->{'nmisng__events'}{database},   'nmisng',
		"targets: nmisng__events has database='nmisng'");
	is($targets->{'nmisng__events'}{collection}, 'events',
		"targets: nmisng__events has collection='events'");
	is($targets->{'opevents__eventqueue'}{database},   'opevents',
		"targets: opevents__eventqueue has database='opevents'");
	is($targets->{'opevents__eventqueue'}{collection}, 'eventqueue',
		"targets: opevents__eventqueue has collection='eventqueue'");
	# Existing fields preserved.
	is_deeply($targets->{'nmisng__events'}{index_var},
		['database', 'collection'],
		"targets: index_var preserved as arrayref");
	is($targets->{'nmisng__events'}{index_value}, 'nmisng__events',
		"targets: index_value is the joined composite");
}

# --- single-label sections don't get spurious component fields ----------
# Backwards-compat guard: a non-composite section's target hash should
# carry only the existing index_var/index_value pair, no per-component
# noise.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx, $targets) = $eng->discover_indexes(
		section_config => {
			indexed   => 'database',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				count      => { metric => 'mock_collstats' },
			},
		},
		index_var => 'database',
	);
	is($err, undef, "single-label targets: discover succeeded");
	# Pick any candidate; targets should NOT carry an extra `database` key.
	my ($any) = keys %$targets;
	ok(defined $any, "single-label targets: at least one row returned");
	is_deeply([sort keys %{$targets->{$any}}],
		[sort qw(index_var index_value)],
		"single-label targets: only index_var and index_value present");
}

# --- build_queries reads per-component values from inventory.data -------
# Simulate a collect-only cycle: inventory was populated by a previous
# discover_indexes pass (and persisted), but the in-memory component
# map is empty (e.g. fresh Sys instance for this collect cycle).
# build_queries must scope row extraction by reading the structured
# fields straight off the inventory row.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	# Wipe the map so only the inventory path can satisfy the lookup.
	delete $eng->{_index_components};
	my $fake = NMISNG::Test::FakeInventory->new({
		index      => 'opevents__eventqueue',
		database   => 'opevents',
		collection => 'eventqueue',
	});
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'opevents__eventqueue',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
		},
		inventory => $fake,
		todos     => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{cnt}{rawvalue}, 3,
		"inventory-first: composite scope sourced from inventory.data");
}

# --- inventory beats split fallback for `__`-in-value labels ------------
# The pathological collision case the in-memory map could not fully
# resolve: same composite string `a__b__c`, two real rows (db=a__b,
# coll=c) and (db=a, coll=b__c). When inventory tells us which row
# this index represents, extraction is exact -- no `//=` race, no
# split ambiguity.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	delete $eng->{_index_components};

	# Inventory says: this row is (db=a__b, coll=c). The split fallback
	# would (mis-)decompose 'a__b__c' as (a, b__c) and pick the wrong
	# sample. The component map is wiped, so it can't help either.
	my $fake = NMISNG::Test::FakeInventory->new({
		index      => 'a__b__c',
		database   => 'a__b',
		collection => 'c',
	});
	my %todos;
	$eng->build_queries(
		section_name    => 'MongoDBCollections',
		section_key     => 'http_prom',
		section_indexed => ['database', 'collection'],
		index           => 'a__b__c',
		section_hash    => {
			'-common-' => { endpoint => 'fix' },
			cnt        => { metric => 'mock_collstats' },
			db         => { metric => 'mock_collstats',
			                extract_label => 'database' },
			coll       => { metric => 'mock_collstats',
			                extract_label => 'collection' },
		},
		inventory => $fake,
		todos     => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	# The (db=a__b, coll=c) row carries value 88 in the fixture.
	is($todos{cnt}{rawvalue},  88,
		"inventory-first: count comes from the (a__b, c) row, not (a, b__c)");
	is($todos{db}{rawvalue},   'a__b',
		"inventory-first: extract_label database returns 'a__b' verbatim");
	is($todos{coll}{rawvalue}, 'c',
		"inventory-first: extract_label collection returns 'c'");
}

# --- max_rows caps results -----------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'label_x',
			max_rows  => 50,
			http_prom => {
				'-common-' => { endpoint => 'fix', path => '/big_metrics' },
				val        => { metric => 'big_metric' },
			},
		},
		index_var => 'label_x',
	);
	is($err, undef, "max_rows: no error");
	is(scalar @$idx, 50, "max_rows: capped at 50");
}

# --- calculate_url for per-index URLs (F5BigIPAPI pattern) --------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'F5_Members',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			first_member_value => {
				calculate_url => 'CVAR1=statsPath; return "$CVAR1";',
				jsonpath      => '$.members[0].value',
			},
		},
		inventory => NMISNG::Test::FakeInventory->new({ statsPath => "/pool/abc/stats" }),
		index     => 'abc',
		todos     => \%todos,
	);
	is($bs->{error}, undef, "calculate_url: build no error");
	$eng->execute_queries(todos => \%todos);
	is($todos{first_member_value}{rawvalue}, 100,
		"calculate_url: per-index URL fetched and extracted");
}

# --- response cache: one URL fetched once across multiple items ---------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'cpu',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			a          => { metric => 'node_load1' },
			b          => { metric => 'node_memory_MemFree_bytes' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	my @cached_urls = keys %{$eng->{response_cache}};
	is(scalar @cached_urls, 1, "response_cache: a single key despite two items");
}

# --- response cache disambiguates by endpoint and format ----------------
# Two endpoints resolving to the same URL string must NOT share a cached
# body, because their auth (and their declared format) can differ.
{
	my ($eng, $sys) = make_engine(
		endpoints => [
			{ name => 'fixA', port => $port },   # same host:port, different name
			{ name => 'fixB', port => $port },
		],
	);

	# Wrap _fetch to count calls per URL.
	my %fetch_count;
	my $orig_fetch = \&NMISNG::Sys::Engine::HTTP::_fetch;
	no warnings 'redefine';
	local *NMISNG::Sys::Engine::HTTP::_fetch = sub {
		my ($self, $endpoint, $url) = @_;
		$fetch_count{$url}++;
		return $self->$orig_fetch($endpoint, $url);
	};
	use warnings 'redefine';

	my %todos;
	$eng->build_queries(
		section_name => 'two_endpoints',
		section_key  => 'http_prom',
		section_hash => {
			a => { endpoint => 'fixA', metric => 'node_load1' },
			b => { endpoint => 'fixB', metric => 'node_load1' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);

	# Both items point at /metrics on the same host:port — URL string
	# matches — but they go through different endpoints, so the cache
	# must store them separately.
	is($todos{a}{rawvalue}, 0.42, "fixA: extracted load1");
	is($todos{b}{rawvalue}, 0.42, "fixB: extracted load1");
	my @cached_keys = keys %{$eng->{response_cache}};
	is(scalar @cached_keys, 2,
		"response_cache: two cache entries (keyed by URL+endpoint+format), not one");
	# Confirm _fetch ran twice — one per endpoint, not coalesced.
	my $total_fetches = 0;
	$total_fetches += $_ for values %fetch_count;
	is($total_fetches, 2,
		"_fetch called once per endpoint (not coalesced when URL strings match)");
}

# --- response cache disambiguates by format -----------------------------
# The same URL declared as both http_prom and http_json should fetch
# twice and parse twice (parser is format-specific).
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);

	my %todos;
	# http_prom item — fetches /metrics, parses as Prometheus
	$eng->build_queries(
		section_name => 'as_prom',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			pval       => { metric => 'node_load1' },
		},
		todos => \%todos,
	);
	# http_json item — fetches /status, parses as JSON
	# (Different path, so URL also differs, but the test still confirms
	# format participates in the key by checking we get two cache entries.)
	$eng->build_queries(
		section_name => 'as_json',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'fix', path => '/status' },
			jval       => { jsonpath => '$.app.state' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{pval}{rawvalue}, 0.42,    "prom path: extracted via prom parser");
	is($todos{jval}{rawvalue}, 'running', "json path: extracted via json parser");
	is(scalar(keys %{$eng->{response_cache}}), 2,
		"response_cache: prom and json cached separately");
}

# --- error: section without endpoint -------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'oops',
		section_key  => 'http_prom',
		section_hash => { foo => { metric => 'node_load1' } },
		todos        => \%todos,
	);
	ok(defined $bs->{error}, "missing endpoint reported");
	like($bs->{error}, qr/no endpoint declared/, "error mentions endpoint");
}

# --- soft skip: endpoint not configured on node --------------------------
# Models commonly declare optional sections (e.g. an http_json app_status
# block that not every node has an endpoint configured for). The engine
# logs and skips rather than poisoning the polling cycle with http_error.
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'oops',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'wrong_name' },
			x          => { metric => 'node_load1' },
		},
		todos => \%todos,
	);
	ok(!defined $bs->{error}, "unknown endpoint: no error returned (soft skip)");
	is(scalar keys %todos, 0,  "unknown endpoint: no todos produced");

	# discover_indexes reports the error AND classifies it as not_present
	# so the caller (Node::collect_systemhealth_info) treats it as non-fatal.
	my ($d_err, $d_idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'foo',
			http_prom => { '-common-' => { endpoint => 'wrong_name' },
			               x          => { metric => 'whatever' } },
		},
		index_var => 'foo',
	);
	ok(defined $d_err, "discover_indexes still surfaces missing endpoint");
	like($d_err, qr/not configured/, "error mentions configuration");
	my $cls = $eng->classify_error;
	is(($cls && $cls->{type}), 'not_present',
		"classify_error reports not_present for missing endpoint");
}

done_testing();
