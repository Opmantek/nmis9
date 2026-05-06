#!/usr/bin/perl
# Tests for NMISNG::GrafanaDashboardImporter. Drives parse + translate
# against hand-crafted fixture JSON; round-trips emitted Common files
# via `do FILE` to confirm they parse.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use NMISNG::GrafanaDashboardImporter;

my $FIXTURE_DIR = "$FindBin::Bin/fixtures/grafana";

sub _slurp
{
	my ($p) = @_;
	open(my $fh, '<', $p) or die "$p: $!";
	local $/;
	my $body = <$fh>;
	close $fh;
	return $body;
}

sub _load_nmis
{
	my ($path) = @_;
	our %hash;
	local %hash;
	my $rv = do $path;
	die "load $path failed: $@" if $@;
	die "load $path returned undef and \$\@ is empty"
		unless defined $rv || keys %hash;
	return {%hash};
}

# --- Test 1: simple_promql.json -- everything translates ----------
{
	my $body = _slurp("$FIXTURE_DIR/simple_promql.json");
	my $imp  = NMISNG::GrafanaDashboardImporter->new(name => 'TestSimple');
	my $r    = $imp->build($body);

	# Three sections, all scalar (no legendFormat with {{label}}).
	is(scalar(keys %{$r->{common}{system}{rrd}}), 3,
		"simple: 3 sections under system.rrd");
	is(scalar(keys %{$r->{graphs}}), 3,
		"simple: 3 graph files emitted");

	# Counter inferred for the rate-wrapped target; gauge for the rest.
	my $rrd = $r->{common}{system}{rrd};
	my $rate_topic;
	for my $topic (keys %$rrd)
	{
		my $hp = $rrd->{$topic}{http_prom};
		for my $ds (grep { $_ ne '-common-' } keys %$hp)
		{
			$rate_topic = $topic if $hp->{$ds}{option} =~ /^counter,/;
		}
	}
	ok(defined $rate_topic, "simple: at least one counter DS (the rate-wrapped panel)");

	# match_labels carried through for the filtered panel.
	my $filtered;
	for my $topic (keys %$rrd)
	{
		my $hp = $rrd->{$topic}{http_prom};
		for my $ds (grep { $_ ne '-common-' } keys %$hp)
		{
			$filtered = $hp->{$ds} if ref $hp->{$ds}{match_labels} eq 'HASH';
		}
	}
	ok($filtered, "simple: a DS carries match_labels (the filtered panel)");
	is($filtered->{match_labels}{state}, 'active',
		"simple: state=active match_labels preserved");

	# No translation TODOs (boilerplate notes-style entries are in
	# notes, not todos).
	my @translation_todos = grep { /could not translate|preserved verbatim|non-Prometheus/ }
		@{$r->{todos}};
	is(scalar @translation_todos, 0,
		"simple: no translation-failure TODOs");

	# Round-trip.
	my $td = tempdir(CLEANUP => 1);
	$imp->emit_files(out_dir => $td, result => $r);
	ok(-e "$td/Common-Linux-HTTP-TestSimple.nmis", "simple: Common file written");
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestSimple.nmis");
	is(scalar(keys %{$loaded->{system}{rrd}}), 3,
		"simple: round-tripped Common parses with 3 sections");
}

# --- Test 2: mixed_complexity.json -- translates 2/5 -------------
{
	my $body = _slurp("$FIXTURE_DIR/mixed_complexity.json");
	my $imp  = NMISNG::GrafanaDashboardImporter->new(name => 'TestMixed');
	my $r    = $imp->build($body);

	# Translatable: panel 1 (Simple Up), panel 2 (Rate Wrapped).
	# Skipped: panel 3 (sum by), panel 4 (histogram_quantile),
	#          panel 5 (arithmetic).
	is(scalar(keys %{$r->{graphs}}), 2,
		"mixed: only 2 graph files (2 panels translated)");

	my @failed = grep { /could not translate|preserved verbatim/ }
		@{$r->{todos}};
	is(scalar @failed, 3,
		"mixed: 3 TODO entries for the unsupported expressions");

	# The original exprs are preserved in the TODO text.
	ok((grep { /sum by/ } @failed),
		"mixed: TODO mentions sum-by expression");
	ok((grep { /histogram_quantile/ } @failed),
		"mixed: TODO mentions histogram_quantile expression");
	ok((grep { /myapp_a \/ myapp_b/ } @failed),
		"mixed: TODO mentions arithmetic expression");

	my $td = tempdir(CLEANUP => 1);
	$imp->emit_files(out_dir => $td, result => $r);
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestMixed.nmis");
	is(scalar(keys %{$loaded->{system}{rrd}}), 2,
		"mixed: round-tripped Common parses with 2 sections");
}

# --- Test 3: multi_datasource.json -- translates only Prom panels --
{
	my $body = _slurp("$FIXTURE_DIR/multi_datasource.json");
	my $imp  = NMISNG::GrafanaDashboardImporter->new(name => 'TestMulti');
	my $r    = $imp->build($body);

	is(scalar(keys %{$r->{graphs}}), 2,
		"multi: 2 sections from the 2 Prometheus panels");

	my @ds_skips = grep { /non-Prometheus/ } @{$r->{todos}};
	is(scalar @ds_skips, 2,
		"multi: 2 TODO entries for the non-Prom datasources");
	ok((grep { /mysql/ }    @ds_skips), "multi: TODO names mysql");
	ok((grep { /influxdb/ } @ds_skips), "multi: TODO names influxdb");

	my $td = tempdir(CLEANUP => 1);
	$imp->emit_files(out_dir => $td, result => $r);
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestMulti.nmis");
	is(scalar(keys %{$loaded->{system}{rrd}}), 2,
		"multi: round-tripped Common parses with 2 sections");
}

# --- Test 4: legacy_v8.json -- legacy rows[].panels[] shape -------
# Same content as simple_promql but in the older shape -- shape
# normaliser must produce equivalent output.
{
	my $body = _slurp("$FIXTURE_DIR/legacy_v8.json");
	my $imp  = NMISNG::GrafanaDashboardImporter->new(name => 'TestLegacy');
	my $r    = $imp->build($body);

	is(scalar(keys %{$r->{graphs}}), 3,
		"legacy: 3 sections recovered from rows[].panels[]");

	# At least one rate-wrapped (counter), at least one filtered.
	my $rrd = $r->{common}{system}{rrd};
	my $has_counter = 0;
	my $has_match_labels = 0;
	for my $topic (keys %$rrd)
	{
		my $hp = $rrd->{$topic}{http_prom};
		for my $ds (grep { $_ ne '-common-' } keys %$hp)
		{
			$has_counter        = 1 if $hp->{$ds}{option} =~ /^counter,/;
			$has_match_labels   = 1 if ref $hp->{$ds}{match_labels} eq 'HASH';
		}
	}
	ok($has_counter,      "legacy: at least one counter DS");
	ok($has_match_labels, "legacy: at least one match_labels");

	my $td = tempdir(CLEANUP => 1);
	$imp->emit_files(out_dir => $td, result => $r);
	my $loaded = _load_nmis("$td/Common-Linux-HTTP-TestLegacy.nmis");
	is(scalar(keys %{$loaded->{system}{rrd}}), 3,
		"legacy: round-tripped Common parses with 3 sections");
}

# --- Test 5: legendFormat with {{label}} triggers indexed section --
{
	my $body = <<'EOM';
{
  "title": "Indexed by legend",
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Per-Code Requests",
      "datasource": { "type": "prometheus", "uid": "abc" },
      "targets": [
        {
          "refId": "A",
          "expr": "myapp_requests_total",
          "legendFormat": "{{code}}"
        }
      ]
    }
  ]
}
EOM
	my $imp = NMISNG::GrafanaDashboardImporter->new(name => 'TestIndexed');
	my $r   = $imp->build($body);

	ok(exists $r->{common}{systemHealth}{sys},
		"indexed: legendFormat label triggers indexed section");
	my ($section) = keys %{$r->{common}{systemHealth}{sys}};
	is($r->{common}{systemHealth}{sys}{$section}{indexed}, 'code',
		"indexed: 'code' picked up from legendFormat");
}

# --- Test 6: instance="$node" filter is dropped (implicit) -------
{
	my $body = <<'EOM';
{
  "title": "Implicit node filter",
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Up With Instance Filter",
      "datasource": { "type": "prometheus", "uid": "abc" },
      "targets": [
        { "refId": "A", "expr": "myapp_up{instance=\"$node\"}" }
      ]
    }
  ]
}
EOM
	my $imp = NMISNG::GrafanaDashboardImporter->new(name => 'TestNode');
	my $r   = $imp->build($body);

	my ($topic) = keys %{$r->{common}{system}{rrd}};
	my $hp = $r->{common}{system}{rrd}{$topic}{http_prom};
	my ($ds) = grep { $_ ne '-common-' } keys %$hp;
	# Should NOT carry match_labels for `instance` (engine scopes by node).
	ok(!exists $hp->{$ds}{match_labels},
		"implicit: instance=\$node is dropped from match_labels");
}

done_testing();
