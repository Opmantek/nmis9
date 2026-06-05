#!/usr/bin/perl
# Tests for NMISNG::JSONPath (minimal subset).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;

use NMISNG::JSONPath;

sub ok_extract
{
	my ($data, $path, $expected, $label) = @_;
	my ($got, $err) = NMISNG::JSONPath::extract($data, $path);
	is($err, undef, "$label: no error") or diag "got error: $err";
	is_deeply($got, $expected, "$label: result") or diag explain $got;
}

sub err_extract
{
	my ($data, $path, $err_pattern, $label) = @_;
	my ($got, $err) = NMISNG::JSONPath::extract($data, $path);
	ok(defined $err, "$label: error reported") or diag "no error, got: " . explain($got);
	like($err, $err_pattern, "$label: error matches") if defined $err;
}

# --- root ---
ok_extract({a => 1}, '$', [{a => 1}], "root returns whole structure");

# --- simple dotted key ---
ok_extract({a => {b => {c => 42}}}, '$.a.b.c', [42], "dotted path");

# --- missing key returns empty ---
ok_extract({a => 1}, '$.b', [], "missing key gives empty result");

# --- bracket notation for keys with dots ---
ok_extract(
	{ 'status.availabilityState' => { description => 'available' } },
	'$["status.availabilityState"].description',
	['available'],
	"bracket notation for dotted key"
);

# --- bracket with single quotes ---
ok_extract(
	{ "weird-key" => 1 },
	"\$['weird-key']",
	[1],
	"single-quoted bracket key"
);

# --- array index ---
ok_extract({ list => [10, 20, 30] }, '$.list[0]', [10], "array index 0");
ok_extract({ list => [10, 20, 30] }, '$.list[2]', [30], "array index 2");
ok_extract({ list => [10, 20, 30] }, '$.list[5]', [], "out-of-range index empty");

# --- chained: index then key ---
ok_extract(
	{ items => [ { name => 'a' }, { name => 'b' } ] },
	'$.items[1].name',
	['b'],
	"index then key"
);

# --- wildcard on array ---
ok_extract(
	{ list => [1, 2, 3] },
	'$.list[*]',
	[1, 2, 3],
	"wildcard [*] on array"
);
ok_extract(
	{ list => [1, 2, 3] },
	'$.list.*',
	[1, 2, 3],
	"wildcard .* on array"
);

# --- wildcard on hash ---
{
	my ($got, $err) = NMISNG::JSONPath::extract(
		{ entries => { a => 1, b => 2, c => 3 } },
		'$.entries.*'
	);
	is($err, undef, "wildcard on hash: no error");
	is(scalar @$got, 3, "wildcard on hash: 3 values");
	is_deeply([sort { $a <=> $b } @$got], [1, 2, 3], "hash wildcard values");
}

# --- wildcard then key (the F5BigIPAPI pattern) ---
ok_extract(
	{ entries => {
		'http://.../v1' => { serverside => { bitsIn => { value => 100 } } },
		'http://.../v2' => { serverside => { bitsIn => { value => 200 } } },
	}},
	'$.entries.*.serverside.bitsIn.value',
	[100, 200],
	"hash wildcard then deep nested key (F5 pattern)"
);

# --- wildcard then key, missing in some elements ---
ok_extract(
	{ list => [
		{ name => 'a', value => 1 },
		{ name => 'b' },                    # no value
		{ name => 'c', value => 3 },
	]},
	'$.list[*].value',
	[1, 3],
	"missing keys silently dropped under wildcard"
);

# --- nested wildcards ---
ok_extract(
	{ groups => [
		{ items => [1, 2] },
		{ items => [3, 4] },
	]},
	'$.groups[*].items[*]',
	[1, 2, 3, 4],
	"nested wildcards flatten"
);

# --- realistic Netatmo-style dive ---
ok_extract(
	{ body => { devices => [
		{ station_name => 'home', dashboard_data => { Temperature => 21.5, Humidity => 45 } },
		{ station_name => 'office', dashboard_data => { Temperature => 19.0, Humidity => 50 } },
	]}},
	'$.body.devices[*].dashboard_data.Temperature',
	[21.5, 19.0],
	"Netatmo dive: all temperatures"
);

# --- traversal stops at scalar (no error, just empty) ---
ok_extract({ a => 5 }, '$.a.b.c', [], "key under scalar yields empty");

# --- error: missing leading $ ---
err_extract({}, 'a.b', qr/must start with/, "missing \$");

# --- error: lone trailing dot ---
err_extract({}, '$.', qr/unexpected end/, "trailing dot");

# --- error: filter expressions rejected with helpful message ---
err_extract({}, '$.list[?(@.x==1)]',
	qr/filter expressions/, "filter expressions rejected");

# --- error: slice rejected ---
err_extract({}, '$.list[1:3]', qr/slice expressions/, "slice rejected");

# --- error: negative index rejected ---
err_extract({}, '$.list[-1]', qr/negative array indices/, "negative index rejected");

# --- error: unterminated bracket ---
err_extract({}, '$.list[', qr/unexpected end/, "unterminated bracket");

# --- error: unterminated quoted key ---
err_extract({}, '$["unterm', qr/unterminated quoted key/, "unterminated quoted key");

# --- undef path ---
err_extract({}, undef, qr/path is undef/, "undef path");

done_testing();
