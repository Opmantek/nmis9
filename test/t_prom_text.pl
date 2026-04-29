#!/usr/bin/perl
# Tests for NMISNG::PromText (Prometheus text-exposition parser).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;

use NMISNG::PromText;

# helper: parse and assert no errors
sub parse_clean
{
	my ($body, $label) = @_;
	my ($samples, $errors) = NMISNG::PromText::parse_metrics($body);
	is_deeply($errors, [], "$label: no parse errors") or diag explain $errors;
	return $samples;
}

# helper: find sample by name + matching label subset
sub find_sample
{
	my ($samples, $name, $labels) = @_;
	$labels //= {};
	for my $s (@$samples)
	{
		next if $s->{name} ne $name;
		my $match = 1;
		for my $k (keys %$labels)
		{
			if (!exists $s->{labels}{$k} || $s->{labels}{$k} ne $labels->{$k})
			{
				$match = 0;
				last;
			}
		}
		return $s if $match;
	}
	return undef;
}

# --- basic gauge / counter ---
{
	my $body = <<'EOM';
# HELP node_load1 1m load average
# TYPE node_load1 gauge
node_load1 0.42
# HELP http_requests_total Total HTTP requests.
# TYPE http_requests_total counter
http_requests_total 12345
EOM
	my $s = parse_clean($body, "basic gauge+counter");
	is(scalar @$s, 2, "two samples parsed");

	my $load = find_sample($s, 'node_load1');
	is($load->{value}, 0.42, "node_load1 value");
	is($load->{type},  'gauge', "node_load1 type from TYPE comment");
	is($load->{help},  '1m load average', "node_load1 help from HELP comment");
	is_deeply($load->{labels}, {}, "node_load1 has no labels");

	my $req = find_sample($s, 'http_requests_total');
	is($req->{value}, 12345, "http_requests_total value");
	is($req->{type},  'counter', "http_requests_total type");
}

# --- labels: simple, multiple, with whitespace ---
{
	my $body = <<'EOM';
http_requests_total{method="GET",code="200"} 100
http_requests_total{method="POST", code="500"} 5
EOM
	my $s = parse_clean($body, "labels");
	is(scalar @$s, 2, "two labelled samples");

	my $get = find_sample($s, 'http_requests_total', { method => 'GET' });
	ok($get, "found GET sample");
	is($get->{value}, 100, "GET value");
	is($get->{labels}{code}, '200', "GET code label");

	my $post = find_sample($s, 'http_requests_total', { method => 'POST' });
	ok($post, "found POST sample (whitespace after comma)");
	is($post->{labels}{code}, '500', "POST code label");
}

# --- label values with embedded special chars ---
{
	# Label values may contain commas, quotes (escaped), backslashes (escaped),
	# and newlines (escaped). These exercise the label-set splitter and
	# value unescaper together.
	my $body = q{weird{a="comma, in value",b="quote\"here",c="back\\slash",d="line\nbreak"} 1};
	my $s = parse_clean($body, "escaped label values");
	is(scalar @$s, 1, "one sample");
	my $w = $s->[0];
	is($w->{labels}{a}, 'comma, in value', "comma inside label value");
	is($w->{labels}{b}, 'quote"here',      "escaped double-quote");
	is($w->{labels}{c}, 'back\\slash',     "escaped backslash");
	is($w->{labels}{d}, "line\nbreak",     "escaped newline");
}

# --- empty label set { } ---
{
	my $body = "metric{} 7\n";
	my $s = parse_clean($body, "empty label set");
	is(scalar @$s, 1, "one sample");
	is($s->[0]{value}, 7, "value");
	is_deeply($s->[0]{labels}, {}, "no labels");
}

# --- special values: NaN, +Inf, -Inf, integers, floats, exponents ---
{
	my $body = <<'EOM';
m_nan NaN
m_posinf +Inf
m_neginf -Inf
m_int 42
m_float 3.14
m_exp 1.5e10
m_neg -0.5
m_zero 0
EOM
	my $s = parse_clean($body, "value formats");
	is(find_sample($s, 'm_nan')->{value},    'NaN', "NaN as string");
	is(find_sample($s, 'm_posinf')->{value}, '+Inf', "+Inf as string");
	is(find_sample($s, 'm_neginf')->{value}, '-Inf', "-Inf as string");
	is(find_sample($s, 'm_int')->{value},    42, "integer");
	is(find_sample($s, 'm_float')->{value},  3.14, "float");
	is(find_sample($s, 'm_exp')->{value},    1.5e10, "exponent");
	is(find_sample($s, 'm_neg')->{value},    -0.5, "negative");
	is(find_sample($s, 'm_zero')->{value},   0, "zero");
}

# --- optional trailing timestamp ---
{
	my $body = "metric 42 1620000000000\n";
	my $s = parse_clean($body, "trailing timestamp");
	is($s->[0]{timestamp}, 1620000000000, "timestamp parsed");
	is($s->[0]{value},     42, "value preserved");
}

# --- no HELP/TYPE present: still parses values ---
{
	my $body = "lonely_metric 99\n";
	my $s = parse_clean($body, "no HELP/TYPE");
	is(scalar @$s, 1, "one sample");
	is($s->[0]{value}, 99, "value");
	ok(!exists $s->[0]{type}, "type absent");
	ok(!exists $s->[0]{help}, "help absent");
}

# --- blank lines + plain comments are skipped ---
{
	my $body = <<'EOM';

# this is a plain comment, not HELP/TYPE
metric 1

# another comment
metric_two 2

EOM
	my $s = parse_clean($body, "blank + plain comments");
	is(scalar @$s, 2, "two samples through blanks/comments");
}

# --- HELP with escape sequences ---
{
	my $body = <<'EOM';
# HELP my_metric line one\nline two with \\backslash
# TYPE my_metric gauge
my_metric 1
EOM
	my $s = parse_clean($body, "HELP escapes");
	is($s->[0]{help}, "line one\nline two with \\backslash",
	   "HELP \\n -> newline, \\\\ -> backslash");
}

# --- malformed line is skipped, reported as error, others continue ---
{
	my $body = <<'EOM';
good_one 1
{this is not a metric} 2
good_two 3
EOM
	my ($s, $errors) = NMISNG::PromText::parse_metrics($body);
	is(scalar @$s, 2, "two good samples kept");
	ok(scalar @$errors >= 1, "at least one error reported");
	like($errors->[0], qr/^line 2:/, "error references line number");
}

# --- CRLF line endings tolerated ---
{
	my $body = "metric 1\r\nmetric_two 2\r\n";
	my $s = parse_clean($body, "CRLF endings");
	is(scalar @$s, 2, "both samples parsed despite CRLF");
}

# --- undef body is non-fatal ---
{
	my ($s, $errors) = NMISNG::PromText::parse_metrics(undef);
	is_deeply($s, [], "undef body returns empty samples");
	ok(scalar @$errors >= 1, "undef body returns an error");
}

# --- empty body is non-fatal, no samples, no errors ---
{
	my ($s, $errors) = NMISNG::PromText::parse_metrics("");
	is_deeply($s, [], "empty body: no samples");
	is_deeply($errors, [], "empty body: no errors");
}

# --- realistic node_exporter snippet ---
{
	my $body = <<'EOM';
# HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
# TYPE node_filesystem_avail_bytes gauge
node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 1.234e9
node_filesystem_avail_bytes{device="/dev/sda2",fstype="ext4",mountpoint="/var"} 5.678e8
# HELP node_load1 1m load average.
# TYPE node_load1 gauge
node_load1 0.27
EOM
	my $s = parse_clean($body, "node_exporter snippet");
	is(scalar @$s, 3, "three samples");

	my $root = find_sample($s, 'node_filesystem_avail_bytes', { mountpoint => '/' });
	is($root->{value}, 1.234e9, "/ filesystem value");
	is($root->{labels}{device}, '/dev/sda1', "/ filesystem device label");

	my $var = find_sample($s, 'node_filesystem_avail_bytes', { mountpoint => '/var' });
	is($var->{value}, 5.678e8, "/var filesystem value");
}

done_testing();
