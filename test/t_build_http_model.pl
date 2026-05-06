#!/usr/bin/perl
# Tests for NMISNG::HTTPModelBuilder. Drives parse + group + emit
# pipeline via library calls; no live HTTP fetch.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use NMISNG::HTTPModelBuilder;

# loadTable wants config, which wants Mongo. We don't need any of that
# for round-trip parse validation -- a simple `do FILE` works because
# the .nmis files are pure Perl. Use that instead of loadTable to keep
# the test offline-safe.
sub _load_nmis
{
	my ($path) = @_;
	our %hash;
	local %hash;
	my $rv = do $path;
	die "load $path failed: $@" if $@;
	die "load $path returned undef and \$\@ is empty (file missing or eval-empty)"
		unless defined $rv || keys %hash;
	return {%hash};
}

# --- Test 1: scalar grouping ----------------------------------------
{
	my $body = <<'EOM';
# HELP mongodb_connections_current Number of currently open client connections
# TYPE mongodb_connections_current gauge
mongodb_connections_current 42
# HELP mongodb_connections_active Active client connections
# TYPE mongodb_connections_active gauge
mongodb_connections_active 8
# HELP mongodb_connections_available Available connections
# TYPE mongodb_connections_available gauge
mongodb_connections_available 99
EOM

	my $b = NMISNG::HTTPModelBuilder->new(name => 'TestScalar');
	my $r = $b->build($body);

	ok(exists $r->{common}{system}{rrd}, "scalar: system.rrd present");
	my @topics = keys %{$r->{common}{system}{rrd}};
	is(scalar @topics, 1, "scalar: one topic in system.rrd");

	my ($topic) = @topics;
	my $http_prom = $r->{common}{system}{rrd}{$topic}{http_prom};
	ok(exists $http_prom->{'-common-'}, "scalar: -common- present");
	is($http_prom->{'-common-'}{endpoint}, 'testscalar_exporter',
		"scalar: endpoint name derived from model name");

	# Three DS items + -common-.
	is(scalar(grep { $_ ne '-common-' } keys %$http_prom), 3,
		"scalar: three DS items recorded");

	# Every DS marked gauge.
	for my $ds (grep { $_ ne '-common-' } keys %$http_prom)
	{
		like($http_prom->{$ds}{option}, qr/^gauge,/,
			"scalar: $ds is gauge,...");
	}

	# database/type wires the topic to an RRD path.
	ok(exists $r->{common}{database}{type}{$topic},
		"scalar: database/type entry present for topic");

	# Round-trip via tempdir.
	my $td = tempdir(CLEANUP => 1);
	$b->emit_files(out_dir => $td, result => $r);
	ok(-e "$td/Common-Linux-HTTP-TestScalar.nmis", "scalar: Common file written");
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestScalar.nmis");
	ok(exists $loaded->{system}{rrd}{$topic}, "scalar: round-tripped Common parses");

	# Graph file emitted and parses.
	my ($graph_file) = glob("$td/Graph-*.nmis");
	ok($graph_file, "scalar: at least one graph file written");
	my $g = _load_nmis($graph_file);
	ok(exists $g->{option}{standard}, "scalar: graph has option.standard");
	ok((grep { /^DEF:/ } @{$g->{option}{standard}}), "scalar: graph has DEFs");
}

# --- Test 2: indexed grouping ---------------------------------------
{
	my $body = <<'EOM';
# HELP mock_collstats two-label metric
# TYPE mock_collstats gauge
mock_collstats{collection="events",database="nmisng"} 60
mock_collstats{collection="orders",database="nmisng"} 5
mock_collstats{collection="events",database="opevents"} 163
mock_collstats{collection="eventqueue",database="opevents"} 3
EOM

	my $b = NMISNG::HTTPModelBuilder->new(name => 'TestIndexed');
	my $r = $b->build($body);

	ok(exists $r->{common}{systemHealth}{sys},
		"indexed: systemHealth.sys present");
	ok(exists $r->{common}{systemHealth}{rrd},
		"indexed: systemHealth.rrd present");

	my ($section) = keys %{$r->{common}{systemHealth}{sys}};
	ok(defined $section, "indexed: at least one section");

	# `collection` has 4 distinct values, `database` has 2 -- tool
	# should pick `collection`.
	is($r->{common}{systemHealth}{sys}{$section}{indexed}, 'collection',
		"indexed: highest-cardinality label picked as 'indexed'");

	# Composite-index TODO must be present (collection=4, database=2;
	# database>=2 so it's a runner-up).
	ok((grep { /composite indexing/ } @{$r->{todos}}),
		"indexed: composite-indexing TODO emitted (database is runner-up)");

	# RRD path includes \$index for indexed sections.
	ok((grep { /\$index/ } values %{$r->{common}{database}{type}}),
		"indexed: database/type path includes \$index");

	# Round-trip.
	my $td = tempdir(CLEANUP => 1);
	$b->emit_files(out_dir => $td, result => $r);
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestIndexed.nmis");
	ok(exists $loaded->{systemHealth}{sys}{$section},
		"indexed: round-tripped Common parses with section");
	is($loaded->{systemHealth}{sys}{$section}{indexed}, 'collection',
		"indexed: round-tripped indexed value preserved");
}

# --- Test 3: histogram triplet --------------------------------------
{
	my $body = <<'EOM';
# HELP http_request_duration_seconds Request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 100
http_request_duration_seconds_bucket{le="0.5"} 250
http_request_duration_seconds_bucket{le="+Inf"} 300
http_request_duration_seconds_sum 12.5
http_request_duration_seconds_count 300
EOM

	my $b = NMISNG::HTTPModelBuilder->new(name => 'TestHist');
	my $r = $b->build($body);

	# Tool should produce at least one section keyed by the base name.
	# Histograms land under system.rrd in this scaffold (no per-row
	# index for the bare scalar shape).
	ok(exists $r->{common}{system}{rrd},
		"histogram: scaffold landed in system.rrd");

	# A TODO that explicitly mentions 'histogram' must be present.
	ok((grep { /histogram/i } @{$r->{todos}}),
		"histogram: TODO mentions histogram explicitly");

	# All triplet members got counter,0:U (cumulative semantics).
	my ($topic) = keys %{$r->{common}{system}{rrd}};
	my $http_prom = $r->{common}{system}{rrd}{$topic}{http_prom};
	for my $ds (grep { $_ ne '-common-' } keys %$http_prom)
	{
		is($http_prom->{$ds}{option}, 'counter,0:U',
			"histogram: $ds is counter,0:U");
	}

	# Round-trip.
	my $td = tempdir(CLEANUP => 1);
	$b->emit_files(out_dir => $td, result => $r);
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestHist.nmis");
	ok(exists $loaded->{system}{rrd}{$topic},
		"histogram: round-tripped Common parses");
}

# --- Test 4: DS name truncation -------------------------------------
{
	my $body = <<'EOM';
# HELP myapp_extremely_long_metric_name_for_testing test
# TYPE myapp_extremely_long_metric_name_for_testing gauge
myapp_extremely_long_metric_name_for_testing 1
EOM

	my $b = NMISNG::HTTPModelBuilder->new(name => 'TestTrunc');
	my $r = $b->build($body);

	# DS name length is bound by 19 chars (rrdtool limit).
	my ($topic) = keys %{$r->{common}{system}{rrd}};
	my $http_prom = $r->{common}{system}{rrd}{$topic}{http_prom};
	for my $ds (grep { $_ ne '-common-' } keys %$http_prom)
	{
		ok(length($ds) <= 19, "trunc: DS '$ds' within 19 chars");
	}

	# Truncation triggers a TODO.
	ok((grep { /truncated/ } @{$r->{todos}}),
		"trunc: TODO records the truncation");
}

done_testing();
