#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::ModelReduce;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use NMISNG::Util;

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

# classify
is(NMISNG::ModelReduce::classify({set=>[],drop=>[],typeconflict=>[]}),
   "identical", "no differences -> identical");
is(NMISNG::ModelReduce::classify({set=>[{path=>["a"],value=>1}],drop=>[],typeconflict=>[]}),
   "reducible", "sets only -> reducible");
is(NMISNG::ModelReduce::classify({set=>[{path=>["a"],value=>1}],drop=>[{path=>["b"]}],typeconflict=>[]}),
   "drift", "any drop -> drift");
is(NMISNG::ModelReduce::classify({set=>[],drop=>[],typeconflict=>[{path=>["a"]}]}),
   "drift", "any type conflict -> drift");

# build_override
{
	my $diff = {set=>[
		{path=>['system','nodeVendor'], value=>'Acme'},
		{path=>['-common-','class','sdwan-omp'], value=>{'common-model'=>'sdwan-omp'}},
		{path=>['-common-','class','sdwan-bfd'], value=>{'common-model'=>'sdwan-bfd'}},
	], drop=>[{path=>['-common-','class','IP-FORWARD']}], typeconflict=>[]};
	my $ov = NMISNG::ModelReduce::build_override($diff);
	is_deeply($ov, {
		system => { nodeVendor => 'Acme' },
		'-common-' => { class => {
			'sdwan-omp' => {'common-model'=>'sdwan-omp'},
			'sdwan-bfd' => {'common-model'=>'sdwan-bfd'},
		}},
	}, "build_override rebuilds nested set paths and ignores drops");
}
{
	# values are cloned, not shared
	my $shared = {x=>1};
	my $ov = NMISNG::ModelReduce::build_override({set=>[{path=>['a'],value=>$shared}],drop=>[],typeconflict=>[]});
	$ov->{a}{x} = 99;
	is($shared->{x}, 1, "build_override clones values");
}

# compile_model: base + auto-discovered override merged by the real loader
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 3 if (ref($C) ne "HASH" || !%$C);

		my $base = tempdir("t-reduce-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		my $var = "$base/var";
		make_path($def, $cus, "$var/nmis_system/model_cache");

		NMISNG::Util::writeHashtoFile(file => "$def/Model-Foo.nmis", json => 0, conf => $C, data => {
			system => { nodeVendor => 'BaseVendor', nodeType => 'router' },
		});

		my $mdl = NMISNG::ModelReduce::compile_model(
			model => "Model-Foo", config => $C,
			default_dir => $def, custom_dir => $cus, var_dir => $var);
		is(ref($mdl), "HASH", "compile_model returns a hash");
		is($mdl->{system}{nodeVendor}, 'BaseVendor', "base value present");

		# add an auto-discovered Model override and recompile
		NMISNG::Util::writeHashtoFile(file => "$cus/Override-Model-Foo.nmis", json => 0, conf => $C, data => {
			system => { nodeVendor => 'OverriddenVendor' },
		});
		my $mdl2 = NMISNG::ModelReduce::compile_model(
			model => "Model-Foo", config => $C,
			default_dir => $def, custom_dir => $cus, var_dir => $var);
		is($mdl2->{system}{nodeVendor}, 'OverriddenVendor', "scoped override applied by real loader");
	}
}

# models_referencing_common
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 2 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-ref-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		make_path($def);
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Uses.nmis", json=>0, conf=>$C, data=>{
			'-common-'=>{class=>{cpu=>{'common-model'=>'WidgetCpu'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-AlsoUses.nmis", json=>0, conf=>$C, data=>{
			'-common-'=>{class=>{cpu=>{'common-model'=>'WidgetCpu'}, ip=>{'common-model'=>'Other'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Nope.nmis", json=>0, conf=>$C, data=>{
			'-common-'=>{class=>{ip=>{'common-model'=>'Other'}}}});

		my @refs = NMISNG::ModelReduce::models_referencing_common("WidgetCpu", $def);
		is_deeply(\@refs, ["Model-AlsoUses","Model-Uses"], "finds all referencing models, sorted");
		my @none = NMISNG::ModelReduce::models_referencing_common("Missing", $def);
		is_deeply(\@none, [], "no references -> empty list");
	}
}

# verify_reduction
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 3 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-verify-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		make_path($def, $cus);

		# default has vendor Base + nodeType; custom copy changes vendor only.
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Bar.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'Base', nodeType=>'router'}});
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Bar.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'Custom', nodeType=>'router'}});

		# correct override reproduces the copy: PASS
		my $good = NMISNG::ModelReduce::verify_reduction(
			basename=>"Model-Bar", custom_dir=>$cus, default_dir=>$def, config=>$C,
			override=>{system=>{nodeVendor=>'Custom'}});
		ok($good->{ok}, "correct override verifies identical");

		# wrong override does NOT reproduce the copy: FAIL
		my $bad = NMISNG::ModelReduce::verify_reduction(
			basename=>"Model-Bar", custom_dir=>$cus, default_dir=>$def, config=>$C,
			override=>{system=>{nodeVendor=>'WRONG'}});
		ok(!$bad->{ok}, "wrong override fails verification");

		# identical case: copy equals default, removal with no override verifies
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Bar.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'Base', nodeType=>'router'}});
		my $same = NMISNG::ModelReduce::verify_reduction(
			basename=>"Model-Bar", custom_dir=>$cus, default_dir=>$def, config=>$C,
			override=>undef);
		ok($same->{ok}, "identical copy removal verifies");
	}
}

# verify_reduction: Common target referenced by multiple models
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 3 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-common-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		make_path($def, $cus);

		# default: Common-Widget + two models referencing it
		NMISNG::Util::writeHashtoFile(file=>"$def/Common-Widget.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{w=>{graphtype=>'w', threshold=>'base'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-A.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'V'}, '-common-'=>{class=>{w=>{'common-model'=>'Widget'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-B.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'V'}, '-common-'=>{class=>{w=>{'common-model'=>'Widget'}}}});

		# custom copy of the Common changes the threshold leaf (reducible)
		NMISNG::Util::writeHashtoFile(file=>"$cus/Common-Widget.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{w=>{graphtype=>'w', threshold=>'tuned'}}}});

		my $good = NMISNG::ModelReduce::verify_reduction(
			basename=>"Common-Widget", custom_dir=>$cus, default_dir=>$def, config=>$C,
			override=>{systemHealth=>{rrd=>{w=>{threshold=>'tuned'}}}});
		ok($good->{ok}, "Common reduction verifies across referencing models");
		is_deeply([sort @{$good->{models}}], ["Model-A","Model-B"],
			"both referencing models were compiled");

		# a Common with no referencers -> nothing to compile -> not ok
		my $orphan = NMISNG::ModelReduce::verify_reduction(
			basename=>"Common-Orphan", custom_dir=>$cus, default_dir=>$def, config=>$C,
			override=>{x=>1});
		ok(!$orphan->{ok}, "Common with no referencers returns not-ok");
	}
}

# analyse
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 5 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-analyse-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		make_path($def, $cus);

		# default files
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Same.nmis", json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Red.nmis",  json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Drift.nmis",json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}, extra=>{keep=>1}});

		# custom copies
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Same.nmis", json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}});                 # identical
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Red.nmis",  json=>0, conf=>$C, data=>{system=>{nodeVendor=>'Custom'}});            # reducible
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Drift.nmis",json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}});                 # drops extra
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Own.nmis",  json=>0, conf=>$C, data=>{system=>{nodeVendor=>'X'}});                 # no default
		NMISNG::Util::writeHashtoFile(file=>"$cus/Override-Model-Same.nmis", json=>0, conf=>$C, data=>{system=>{x=>1}});                   # existing override
		NMISNG::Util::writeHashtoFile(file=>"$cus/Graph-cpu.nmis",  json=>0, conf=>$C, data=>{title=>'x'});                                # graph

		my $res = NMISNG::ModelReduce::analyse(custom_dir=>$cus, default_dir=>$def, config=>$C);
		my %by = map { $_->{basename} => $_ } @$res;

		is($by{"Model-Same"}{category},  "identical",       "identical detected");
		is($by{"Model-Red"}{category},   "reducible",       "reducible detected");
		ok($by{"Model-Red"}{verified},                      "reducible verified");
		is($by{"Model-Drift"}{category}, "drift",           "drift detected");
		is_deeply($by{"Model-Drift"}{drops}, ["extra"],     "drift lists the dropped top-level section");
		is($by{"Model-Own"}{category},   "skip-no-default", "genuine custom skipped");
		is($by{"Graph-cpu"}{category},   "skip-graph",      "graph skipped");
		is($by{"Override-Model-Same"}{category}, "skip-override", "existing override skipped");
	}
}

# analyse: error category (verify failure with clean diagnostic, and unparseable file)
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 4 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-err-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		make_path($def, $cus);

		# a reducible Common that NO model references -> verify has nothing to compile
		NMISNG::Util::writeHashtoFile(file=>"$def/Common-Lonely.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{x=>{threshold=>'base'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$cus/Common-Lonely.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{x=>{threshold=>'tuned'}}}});

		# an unparseable custom file with a valid default counterpart
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Bad.nmis", json=>0, conf=>$C, data=>{system=>{nodeVendor=>'V'}});
		open(my $fh, '>', "$cus/Model-Bad.nmis") or die $!;
		print $fh "%hash = (this is not valid perl\n";
		close($fh);

		my $res = NMISNG::ModelReduce::analyse(custom_dir=>$cus, default_dir=>$def, config=>$C);
		my %by = map { $_->{basename} => $_ } @$res;

		is($by{"Common-Lonely"}{category}, "error", "unreferenced reducible Common -> error");
		ok(!defined $by{"Common-Lonely"}{override}, "error row carries no override");
		like($by{"Common-Lonely"}{error}, qr/no models to compile/, "error message is the real reason");
		is($by{"Model-Bad"}{category}, "error", "unparseable custom file -> error");
	}
}

done_testing();
