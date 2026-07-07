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

# semantic_diff
{
	my $d = NMISNG::ModelReduce::semantic_diff({a=>1}, {a=>1});
	is_deeply($d, {set=>[],drop=>[],typeconflict=>[]}, "identical -> empty diff");
}
{
	# added key (custom only)
	my $d = NMISNG::ModelReduce::semantic_diff({a=>1}, {a=>1, b=>2});
	is_deeply($d->{set}, [{path=>["b"], value=>2}], "added key -> set");
	is_deeply($d->{drop}, [], "added key -> no drop");
}
{
	# changed leaf
	my $d = NMISNG::ModelReduce::semantic_diff({a=>1}, {a=>5});
	is_deeply($d->{set}, [{path=>["a"], value=>5}], "changed leaf -> set custom value");
}
{
	# dropped key (default only)
	my $d = NMISNG::ModelReduce::semantic_diff({a=>1, b=>2}, {a=>1});
	is_deeply($d->{drop}, [{path=>["b"]}], "default-only key -> drop");
	is_deeply($d->{set}, [], "dropped key -> no set");
}
{
	# array replaced wholesale (any difference -> whole array as set)
	my $d = NMISNG::ModelReduce::semantic_diff({a=>[1,2,3]}, {a=>[1,2]});
	is_deeply($d->{set}, [{path=>["a"], value=>[1,2]}], "array diff -> whole custom array");
}
{
	# nested add under a shared hash
	my $d = NMISNG::ModelReduce::semantic_diff(
		{'-common-'=>{class=>{a=>{'common-model'=>'a'}}}},
		{'-common-'=>{class=>{a=>{'common-model'=>'a'}, b=>{'common-model'=>'b'}}}});
	is_deeply($d->{set}, [{path=>['-common-','class','b'], value=>{'common-model'=>'b'}}],
		"nested add -> single set at the new key");
}
{
	# type conflict: base hash, custom scalar
	my $d = NMISNG::ModelReduce::semantic_diff({a=>{x=>1}}, {a=>5});
	is_deeply($d->{typeconflict}, [{path=>["a"]}], "hash-over-scalar -> typeconflict");
	is_deeply($d->{set}, [], "type conflict -> no set");
}
{
	# custom hash over base scalar is representable (set)
	my $d = NMISNG::ModelReduce::semantic_diff({a=>5}, {a=>{x=>1}});
	is_deeply($d->{set}, [{path=>["a"], value=>{x=>1}}], "custom hash over scalar -> set");
}

done_testing();
