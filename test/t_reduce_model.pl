#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::ModelReduce;

# deep_equal
ok(NMISNG::ModelReduce::deep_equal(1, 1), "scalars equal");
ok(!NMISNG::ModelReduce::deep_equal(1, 2), "scalars differ");
ok(NMISNG::ModelReduce::deep_equal("a", "a"), "strings equal");
ok(NMISNG::ModelReduce::deep_equal([1,2,3], [1,2,3]), "arrays equal");
ok(!NMISNG::ModelReduce::deep_equal([1,2], [1,2,3]), "arrays differ by length");
ok(!NMISNG::ModelReduce::deep_equal([1,2,3], [1,9,3]), "arrays differ by element");
ok(NMISNG::ModelReduce::deep_equal({a=>1,b=>{c=>2}}, {b=>{c=>2},a=>1}),
   "nested hashes equal regardless of key order");
ok(!NMISNG::ModelReduce::deep_equal({a=>1}, {a=>1,b=>2}), "hashes differ by key");
ok(NMISNG::ModelReduce::deep_equal(undef, undef), "both undef equal");
ok(!NMISNG::ModelReduce::deep_equal(undef, 1), "undef vs value differ");
ok(!NMISNG::ModelReduce::deep_equal({a=>1}, [1]), "hash vs array differ");

done_testing();
