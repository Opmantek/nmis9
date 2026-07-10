# Model reduce-to-override tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an admin tool that replaces full custom model copies with small `Override-*.nmis` files whenever it can prove the compiled model is unchanged, and reports the copies it cannot safely reduce.

**Architecture:** A pure-logic module (`lib/NMISNG/ModelReduce.pm`) does the semantic diff, classification, override construction, and loader-based verification. A thin CLI (`admin/reduce_model.pl`) resolves directories from config, orchestrates, reports, and performs the guarded apply step. Verification drives the real `NMISNG::Sys::loadModel` in temporary directories, so it needs no git, MongoDB, or SNMP.

**Tech Stack:** Perl 5, `NMISNG::Util` (`readFiletoHash`, `writeHashtoFile`, `get_args_multi`, `getDir`, `loadConfTable`), `NMISNG::Sys` (`loadModel`, `_mergeHash`), `Clone`, `Test::More`, `Test::Deep`, `File::Temp`, `File::Path`, `Data::Dumper`.

## Global Constraints

- Boolean values use the `boolean` CPAN module. Do NOT use the `-truth` flag.
- All scripts find `lib/` via `use FindBin; use lib "$FindBin::Bin/../lib";`.
- `.nmis` files are Perl `%hash = ( ... );` text. Read with `NMISNG::Util::readFiletoHash(file => ...)` (returns a hashref, or an error string on failure). Write with `NMISNG::Util::writeHashtoFile(file => ..., data => ..., json => 0)`.
- The override merge (`NMISNG::Sys::_mergeHash`) only adds keys or overwrites values, replaces arrays wholesale, has no delete verb, and fails if a base hash key is overwritten by a non-hash. The tool must never rely on deleting a base key.
- Override discovery covers only `Override-Model-<name>.nmis` and `Override-Common-<feature>.nmis`. Graph files have no override path.
- The tool runs on customer servers with no git. No git, ancestor recovery, or rebasing.
- Dry run is the default. Nothing under the target directory changes without `apply=1`. Never remove a file without a successful backup first.
- Argument style is `key=value`, parsed with `NMISNG::Util::get_args_multi(@ARGV)`.
- Do not commit the dev-server sample. Tests build synthetic fixtures in temp dirs.

---

### Task 1: Module skeleton and deep-equal helper

**Files:**
- Create: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Produces: `NMISNG::ModelReduce::deep_equal($a, $b)` returns 1 if two Perl structures are deeply equal (handles scalars, arrayrefs, hashrefs, and undef), else 0.

- [ ] **Step 1: Write the failing test**

Create `test/t_reduce_model.pl`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Can't locate NMISNG/ModelReduce.pm`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/NMISNG/ModelReduce.pm`:

```perl
package NMISNG::ModelReduce;
#
#  Reduce full custom model copies to Override-*.nmis files when the compiled
#  model is provably unchanged. Pure logic plus a loader-based verifier.
#
use strict;
use warnings;

our $VERSION = "9.6.5";

# deep_equal($a, $b): true if two Perl structures are deeply equal.
sub deep_equal
{
	my ($a, $b) = @_;

	return 1 if (!defined $a && !defined $b);
	return 0 if (!defined $a || !defined $b);

	my $ta = ref($a);
	my $tb = ref($b);
	return 0 if ($ta ne $tb);

	if ($ta eq "")
	{
		return ($a eq $b) ? 1 : 0;
	}
	elsif ($ta eq "ARRAY")
	{
		return 0 if (scalar(@$a) != scalar(@$b));
		for my $i (0 .. $#$a)
		{
			return 0 if (!deep_equal($a->[$i], $b->[$i]));
		}
		return 1;
	}
	elsif ($ta eq "HASH")
	{
		return 0 if (scalar(keys %$a) != scalar(keys %$b));
		for my $k (keys %$a)
		{
			return 0 if (!exists $b->{$k});
			return 0 if (!deep_equal($a->{$k}, $b->{$k}));
		}
		return 1;
	}
	# any other ref type (Regexp, code, etc): compare stringified
	return ("$a" eq "$b") ? 1 : 0;
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS, all deep_equal assertions ok.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add ModelReduce module with deep_equal helper"
```

---

### Task 2: Semantic diff

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: `deep_equal`.
- Produces: `NMISNG::ModelReduce::semantic_diff($default, $custom)` returns a hashref
  `{ set => [ {path=>[k,...], value=>$v}, ... ], drop => [ {path=>[k,...]}, ... ], typeconflict => [ {path=>[k,...]}, ... ] }`.
  - `set`: key present in custom with a value the default lacks or differs from, and representable by the merge (custom is not blocked by a base-hash conflict). Value is the whole custom value at that key.
  - `drop`: key present in the default but absent in custom (blocks byte-identical reduction).
  - `typeconflict`: key present in both where the default value is a hash and the custom value is not (the merge would fail).

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::semantic_diff`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/NMISNG/ModelReduce.pm` before the final `1;`:

```perl
# semantic_diff($default, $custom): classify differences. See interface doc.
sub semantic_diff
{
	my ($default, $custom) = @_;
	my $result = { set => [], drop => [], typeconflict => [] };
	_diff_walk($default, $custom, [], $result);
	return $result;
}

sub _diff_walk
{
	my ($default, $custom, $path, $result) = @_;

	# both hashes: recurse over the union of keys
	if (ref($default) eq "HASH" && ref($custom) eq "HASH")
	{
		my %allkeys = map { $_ => 1 } (keys %$default, keys %$custom);
		for my $k (sort keys %allkeys)
		{
			my $subpath = [@$path, $k];
			my $in_def = exists $default->{$k};
			my $in_cus = exists $custom->{$k};

			if ($in_def && !$in_cus)
			{
				push @{$result->{drop}}, { path => $subpath };
			}
			elsif (!$in_def && $in_cus)
			{
				push @{$result->{set}}, { path => $subpath, value => $custom->{$k} };
			}
			else
			{
				_diff_walk($default->{$k}, $custom->{$k}, $subpath, $result);
			}
		}
		return;
	}

	# base is a hash but custom is not: merge would fail
	if (ref($default) eq "HASH" && ref($custom) ne "HASH")
	{
		push @{$result->{typeconflict}}, { path => $path };
		return;
	}

	# leaf, array, or custom-hash-over-base-non-hash: representable, set whole value
	if (!deep_equal($default, $custom))
	{
		push @{$result->{set}}, { path => $path, value => $custom };
	}
	return;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS, all semantic_diff assertions ok.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add semantic_diff"
```

---

### Task 3: Classify

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: the diff hashref from `semantic_diff`.
- Produces: `NMISNG::ModelReduce::classify($diff)` returns one of `identical`, `reducible`, `drift`.
  - `identical`: no set, drop, or typeconflict.
  - `reducible`: at least one set, and no drop and no typeconflict.
  - `drift`: at least one drop or typeconflict.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
# classify
is(NMISNG::ModelReduce::classify({set=>[],drop=>[],typeconflict=>[]}),
   "identical", "no differences -> identical");
is(NMISNG::ModelReduce::classify({set=>[{path=>["a"],value=>1}],drop=>[],typeconflict=>[]}),
   "reducible", "sets only -> reducible");
is(NMISNG::ModelReduce::classify({set=>[{path=>["a"],value=>1}],drop=>[{path=>["b"]}],typeconflict=>[]}),
   "drift", "any drop -> drift");
is(NMISNG::ModelReduce::classify({set=>[],drop=>[],typeconflict=>[{path=>["a"]}]}),
   "drift", "any type conflict -> drift");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::classify`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/NMISNG/ModelReduce.pm` before the final `1;`:

```perl
# classify($diff): identical | reducible | drift
sub classify
{
	my ($diff) = @_;
	return "drift" if (@{$diff->{drop}} || @{$diff->{typeconflict}});
	return "reducible" if (@{$diff->{set}});
	return "identical";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add classify"
```

---

### Task 4: Build override

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: the diff hashref from `semantic_diff`.
- Produces: `NMISNG::ModelReduce::build_override($diff)` returns a hashref reconstructed from the `set` entries only (adds and changes). Nested paths are rebuilt. Values are cloned so the result shares no references with the inputs. `drop` and `typeconflict` entries are ignored (they are not representable). Used both for the real override of a reducible file and for the manual-start override of a drift file.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::build_override`.

- [ ] **Step 3: Write minimal implementation**

Add `use Clone;` near the top of `lib/NMISNG/ModelReduce.pm` (after `use warnings;`), then add before the final `1;`:

```perl
# build_override($diff): rebuild a hashref from the diff's set entries only.
sub build_override
{
	my ($diff) = @_;
	my $override = {};
	for my $entry (@{$diff->{set}})
	{
		_set_path($override, $entry->{path}, Clone::clone($entry->{value}));
	}
	return $override;
}

# _set_path($hash, \@path, $value): set a nested value, creating intermediate hashes.
sub _set_path
{
	my ($hash, $path, $value) = @_;
	my $node = $hash;
	for my $i (0 .. $#$path - 1)
	{
		my $k = $path->[$i];
		$node->{$k} = {} if (ref($node->{$k}) ne "HASH");
		$node = $node->{$k};
	}
	$node->{$path->[-1]} = $value;
	return;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add build_override"
```

---

### Task 5: Compile a model in given directories (loader driver)

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Produces: `NMISNG::ModelReduce::compile_model(%args)` where args are `model` (for example `Model-Foo`), `config` (a real config hashref to clone), `default_dir`, `custom_dir`, `var_dir`. It clones the config, repoints `<nmis_default_models>`, `<nmis_models>`, `<nmis_var>` at the given dirs, disables model caching, drives the real `NMISNG::Sys::loadModel`, and returns the merged model hashref (`$sys->{mdl}`), or `undef` on load failure.

This reuses the setup proven in `test/t_model_overrides.pl`.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl`. First add these `use` lines near the top of the file (after the existing `use` lines):

```perl
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use NMISNG::Util;
```

Then append before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::compile_model`.

- [ ] **Step 3: Write minimal implementation**

Add `use Clone;` is already present. Add a small fake-nmisng package and the sub. Add near the top of `lib/NMISNG/ModelReduce.pm` (after the `use` lines):

```perl
use NMISNG::Sys;
use NMISNG::Log;

# Minimal nmisng-like object: loadModel only needs ->log and ->config.
{
	package NMISNG::ModelReduce::FakeNmisng;
	sub new { my ($c, %a) = @_; bless { %a }, $c; }
	sub log { $_[0]->{log} }
	sub config { $_[0]->{config} }
}
```

Add before the final `1;`:

```perl
# compile_model(%args): drive the real loader against isolated dirs.
sub compile_model
{
	my (%args) = @_;

	my $C = Clone::clone($args{config});
	$C->{'<nmis_default_models>'} = $args{default_dir};
	$C->{'<nmis_models>'}         = $args{custom_dir};
	$C->{'<nmis_var>'}            = $args{var_dir};
	delete $C->{global_model_overrides};

	my $logger = NMISNG::Log->new(level => 'fatal');
	my $fake = NMISNG::ModelReduce::FakeNmisng->new(config => $C, log => $logger);

	my $sys = NMISNG::Sys->new();
	$sys->{config}       = $C;
	$sys->{_nmisng}      = $fake;
	$sys->{cache_models} = 0;

	my $ok = $sys->loadModel(model => $args{model});
	return undef if (!$ok);
	return $sys->{mdl};
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS. A warning about changing file owner to user "nmis" may print; it is harmless.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add compile_model loader driver"
```

---

### Task 6: Find models referencing a Common feature

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Produces: `NMISNG::ModelReduce::models_referencing_common($feature, @dirs)` returns a sorted, de-duplicated list of model names (for example `Model-Foo`) whose `-common-/class/*/common-model` equals `$feature`, scanning every `Model-*.nmis` found in the given directories. A file that appears in more than one dir is read once (custom shadows default by directory order).

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::models_referencing_common`.

- [ ] **Step 3: Write minimal implementation**

Add before the final `1;` in `lib/NMISNG/ModelReduce.pm`:

```perl
# models_referencing_common($feature, @dirs): model names that pull in Common-$feature.
sub models_referencing_common
{
	my ($feature, @dirs) = @_;
	my %seen_file;
	my %matches;
	for my $dir (@dirs)
	{
		next if (!defined $dir || !-d $dir);
		opendir(my $dh, $dir) or next;
		my @files = grep { /^Model-.+\.nmis$/ } readdir($dh);
		closedir($dh);
		for my $f (sort @files)
		{
			next if ($seen_file{$f}++);    # first dir wins (custom before default)
			my $data = NMISNG::Util::readFiletoHash(file => "$dir/$f");
			next if (ref($data) ne "HASH");
			my $class = $data->{'-common-'}{class};
			next if (ref($class) ne "HASH");
			for my $c (keys %$class)
			{
				if (($class->{$c}{'common-model'} // '') eq $feature)
				{
					my $name = $f; $name =~ s/\.nmis$//;
					$matches{$name} = 1;
					last;
				}
			}
		}
	}
	return sort keys %matches;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add models_referencing_common"
```

---

### Task 7: Verify a proposed reduction end to end

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: `compile_model`, `models_referencing_common`, `deep_equal`, `build_override`.
- Produces: `NMISNG::ModelReduce::verify_reduction(%args)` where args are `basename` (for example `Model-Foo` or `Common-Bar`), `custom_dir`, `default_dir`, `config`, and `override` (a hashref, or `undef` for the identical case where the copy is simply removed). It builds two isolated states, `before` (the real custom_dir copied as-is) and `after` (same, but with the target file removed and, when `override` is given, `Override-<basename>.nmis` written), compiles every affected model in both states, and returns `{ ok => 1|0, models => [...], mismatch => $model_or_undef }`. Affected models are the file itself when it is a `Model-`, or `models_referencing_common(feature, custom_dir, default_dir)` when it is a `Common-`.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::verify_reduction`.

- [ ] **Step 3: Write minimal implementation**

Add `use File::Temp qw(tempdir);`, `use File::Path qw(make_path);`, and `use File::Copy qw(copy);` near the top of `lib/NMISNG/ModelReduce.pm`, then add before the final `1;`:

```perl
# _copy_dir_files($src, $dst): copy every *.nmis file from src into dst (flat).
sub _copy_dir_files
{
	my ($src, $dst) = @_;
	make_path($dst) if (!-d $dst);
	return if (!-d $src);
	opendir(my $dh, $src) or return;
	for my $f (grep { /\.nmis$/ } readdir($dh))
	{
		File::Copy::copy("$src/$f", "$dst/$f");
	}
	closedir($dh);
	return;
}

# verify_reduction(%args): compile affected models before/after and compare.
sub verify_reduction
{
	my (%args) = @_;
	my $basename    = $args{basename};
	my $custom_dir  = $args{custom_dir};
	my $default_dir = $args{default_dir};
	my $config      = $args{config};
	my $override    = $args{override};

	my $tmp = tempdir("model-reduce-verify-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $before_cus = "$tmp/before-custom";
	my $after_cus  = "$tmp/after-custom";
	my $var_before = "$tmp/var-before";
	my $var_after  = "$tmp/var-after";
	make_path("$var_before/nmis_system/model_cache", "$var_after/nmis_system/model_cache");

	# before: exact copy of the real custom dir
	_copy_dir_files($custom_dir, $before_cus);
	# after: same, minus the target file, plus the override when given
	_copy_dir_files($custom_dir, $after_cus);
	unlink("$after_cus/$basename.nmis");
	if (defined $override)
	{
		NMISNG::Util::writeHashtoFile(
			file => "$after_cus/Override-$basename.nmis",
			data => $override, json => 0, conf => $config);
	}

	# which models to compile
	my @models;
	if ($basename =~ /^Model-/)
	{
		push @models, $basename;
	}
	else # Common-<feature>
	{
		my $feature = $basename; $feature =~ s/^Common-//;
		# scan the after custom dir plus the default dir for referencing models
		@models = models_referencing_common($feature, $after_cus, $default_dir);
	}

	return { ok => 0, models => [], mismatch => undef, error => "no models to compile" }
		if (!@models);

	for my $m (@models)
	{
		my $before = compile_model(model => $m, config => $config,
			default_dir => $default_dir, custom_dir => $before_cus, var_dir => $var_before);
		my $after  = compile_model(model => $m, config => $config,
			default_dir => $default_dir, custom_dir => $after_cus, var_dir => $var_after);
		if (!defined $before || !defined $after || !deep_equal($before, $after))
		{
			return { ok => 0, models => \@models, mismatch => $m };
		}
	}
	return { ok => 1, models => \@models, mismatch => undef };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add verify_reduction end-to-end check"
```

---

### Task 8: analyse() — enumerate, classify, verify, and plan actions

**Files:**
- Modify: `lib/NMISNG/ModelReduce.pm`
- Test: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: `semantic_diff`, `classify`, `build_override`, `verify_reduction`.
- Produces: `NMISNG::ModelReduce::analyse(%args)` where args are `custom_dir`, `default_dir`, `config`, and optional `only` (a single basename to limit to). Returns an arrayref of per-file result hashrefs, each `{ basename, category, verified, override, drops, error }` where:
  - `category` is one of `identical`, `reducible`, `drift`, `skip-graph`, `skip-no-default`, `skip-override`, `error`.
  - `verified` is 1 when a loader check passed (identical and reducible only).
  - `override` is the hashref to write (reducible) or the manual-start hashref (drift), else undef.
  - `drops` is an arrayref of `/`-joined drop paths for drift files, else undef.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_reduce_model.pl`
Expected: FAIL, `Undefined subroutine &NMISNG::ModelReduce::analyse`.

- [ ] **Step 3: Write minimal implementation**

Add before the final `1;` in `lib/NMISNG/ModelReduce.pm`:

```perl
# analyse(%args): full per-file classification with verification.
sub analyse
{
	my (%args) = @_;
	my $custom_dir  = $args{custom_dir};
	my $default_dir = $args{default_dir};
	my $config      = $args{config};
	my $only        = $args{only};

	my @results;
	opendir(my $dh, $custom_dir) or die "cannot read $custom_dir: $!\n";
	my @files = sort grep { /\.nmis$/ } readdir($dh);
	closedir($dh);

	for my $f (@files)
	{
		my $basename = $f; $basename =~ s/\.nmis$//;
		next if (defined $only && $basename ne $only);

		if ($basename =~ /^Override-/)
		{
			push @results, { basename=>$basename, category=>"skip-override" };
			next;
		}
		if ($basename =~ /^Graph-/)
		{
			push @results, { basename=>$basename, category=>"skip-graph" };
			next;
		}
		if ($basename !~ /^(Model|Common)-/)
		{
			push @results, { basename=>$basename, category=>"skip-override" };
			next;
		}
		if (!-e "$default_dir/$f")
		{
			push @results, { basename=>$basename, category=>"skip-no-default" };
			next;
		}

		my $custom  = NMISNG::Util::readFiletoHash(file => "$custom_dir/$f");
		my $default = NMISNG::Util::readFiletoHash(file => "$default_dir/$f");
		if (ref($custom) ne "HASH" || ref($default) ne "HASH")
		{
			push @results, { basename=>$basename, category=>"error",
				error => "unparseable: " . (ref($custom) ne "HASH" ? $custom : $default) };
			next;
		}

		my $diff = semantic_diff($default, $custom);
		my $cat  = classify($diff);

		if ($cat eq "identical")
		{
			my $v = verify_reduction(basename=>$basename, custom_dir=>$custom_dir,
				default_dir=>$default_dir, config=>$config, override=>undef);
			push @results, { basename=>$basename, category=>"identical",
				verified=>($v->{ok}?1:0), override=>undef };
		}
		elsif ($cat eq "reducible")
		{
			my $override = build_override($diff);
			my $v = verify_reduction(basename=>$basename, custom_dir=>$custom_dir,
				default_dir=>$default_dir, config=>$config, override=>$override);
			# if the loader disagrees, keep the copy and report it as drift-like
			push @results, {
				basename => $basename,
				category => ($v->{ok} ? "reducible" : "error"),
				verified => ($v->{ok}?1:0),
				override => $override,
				error    => ($v->{ok} ? undef : "verification mismatch on $v->{mismatch}"),
			};
		}
		else # drift
		{
			my @drops = map { join("/", @{$_->{path}}) } @{$diff->{drop}};
			push @drops, map { join("/", @{$_->{path}})." (type conflict)" } @{$diff->{typeconflict}};
			push @results, {
				basename => $basename,
				category => "drift",
				verified => 0,
				override => build_override($diff),   # manual-start (adds/changes only)
				drops    => \@drops,
			};
		}
	}
	return \@results;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/ModelReduce.pm test/t_reduce_model.pl
git commit -m "feat(model-reduce): add analyse orchestration"
```

---

### Task 9: CLI script — report (dry run)

**Files:**
- Create: `admin/reduce_model.pl`
- Test: manual run described below.

**Interfaces:**
- Consumes: `NMISNG::ModelReduce::analyse`, `NMISNG::Util::get_args_multi`, `NMISNG::Util::getDir`, `NMISNG::Util::loadConfTable`, `NMISNG::Util::writeHashtoFile`.
- Produces: the executable `admin/reduce_model.pl`. In dry run it prints a per-file report and writes proposed overrides (reducible) and manual-start overrides (drift) to the scratch dir.

- [ ] **Step 1: Write the script**

Create `admin/reduce_model.pl`:

```perl
#!/usr/bin/perl
#
#  reduce_model.pl - replace full custom model copies with Override-*.nmis files
#  when the compiled model is provably unchanged. Dry run by default.
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#  NMIS is free software: licensed under the GNU General Public License v3+.
#
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use Data::Dumper;
use File::Path qw(make_path);
use File::Copy qw(copy);

use NMISNG::Util;
use NMISNG::ModelReduce;

my $arg = NMISNG::Util::get_args_multi(@ARGV);

if (NMISNG::Util::getbool($arg->{help}) || (defined $arg->{help}))
{
	usage();
	exit 0;
}

my $C = NMISNG::Util::loadConfTable();
die "cannot load NMIS config\n" if (ref($C) ne "HASH" || !%$C);

my $custom_dir  = $arg->{dir}         // NMISNG::Util::getDir(dir => "models",        conf => $C);
my $default_dir = $arg->{default_dir} // NMISNG::Util::getDir(dir => "default_models", conf => $C);
my $apply       = NMISNG::Util::getbool($arg->{apply});
my $verbose     = NMISNG::Util::getbool($arg->{verbose});
my $scratch     = $arg->{scratch} // (($ENV{TMPDIR} || "/tmp") . "/model-reduce-$$");

die "custom dir not found: $custom_dir\n"  if (!-d $custom_dir);
die "default dir not found: $default_dir\n" if (!-d $default_dir);
make_path($scratch) if (!-d $scratch);

print "Custom  dir: $custom_dir\n";
print "Default dir: $default_dir\n";
print "Scratch dir: $scratch\n";
print "Mode       : " . ($apply ? "APPLY" : "dry run (no changes)") . "\n\n";

my $results = NMISNG::ModelReduce::analyse(
	custom_dir => $custom_dir, default_dir => $default_dir,
	config => $C, only => $arg->{model});

report($results);

# write proposed + manual-start overrides into scratch for inspection
for my $r (@$results)
{
	next if (!defined $r->{override});
	my $tag = ($r->{category} eq "drift") ? "manual-start" : "proposed";
	my $out = "$scratch/Override-$r->{basename}.$tag.nmis";
	local $Data::Dumper::Sortkeys = 1;
	NMISNG::Util::writeHashtoFile(file => $out, data => $r->{override}, json => 0, conf => $C);
}
print "\nProposed override files written under $scratch\n";

if ($apply)
{
	apply_changes($results, $custom_dir, $C);
}
else
{
	my @todo = grep { $_->{verified} && ($_->{category} eq "identical" || $_->{category} eq "reducible") } @$results;
	print "\n" . scalar(@todo) . " file(s) would be changed. Re-run with apply=1 to apply.\n";
}

sub report
{
	my ($results) = @_;
	printf("%-34s %-16s %s\n", "FILE", "OUTCOME", "DETAIL");
	printf("%-34s %-16s %s\n", "----", "-------", "------");
	for my $r (sort { $a->{basename} cmp $b->{basename} } @$results)
	{
		my $detail = "";
		if ($r->{category} eq "reducible") { $detail = "override + remove copy (verified)"; }
		elsif ($r->{category} eq "identical") { $detail = "remove copy, no override (verified)"; }
		elsif ($r->{category} eq "drift")
		{
			$detail = "kept; default adds: " . join(", ", @{$r->{drops} // []});
		}
		elsif ($r->{category} eq "error") { $detail = $r->{error} // "error"; }
		printf("%-34s %-16s %s\n", $r->{basename}, $r->{category}, $detail);
	}
}

sub usage
{
	print <<EOF;
Usage: $0 [dir=<models-custom>] [default_dir=<models-default>] [model=<Name>]
          [scratch=<dir>] [apply=1] [verbose=1]

Dry run by default. Replaces full custom model copies with Override-*.nmis
files when the compiled model is provably unchanged. Removes copies that are
already identical to the default. Reports copies that drifted from a newer
default without changing them.
EOF
	return;
}
```

- [ ] **Step 2: Make it executable and run against the synthetic fixture from Task 8**

Build a quick fixture and run:

```bash
chmod +x admin/reduce_model.pl
perl admin/reduce_model.pl dir=/nonexistent 2>&1 | head
```

Expected: prints `custom dir not found: /nonexistent`.

- [ ] **Step 3: Run against the dev-server sample (ad hoc, read-only)**

Extract the sample to a scratch dir and point the tool at it:

```bash
perl admin/reduce_model.pl dir=/path/to/extracted/models-custom
```

Expected: a report with identical, reducible, drift, skip-graph, and skip-no-default rows, and proposed override files under the scratch dir. No changes to the sample.

- [ ] **Step 4: Commit**

```bash
git add admin/reduce_model.pl
git commit -m "feat(model-reduce): add reduce_model.pl CLI with dry-run report"
```

---

### Task 10: CLI apply path with backup, write, remove, and post-apply guard

**Files:**
- Modify: `admin/reduce_model.pl`
- Test: manual run described below.

**Interfaces:**
- Consumes: `NMISNG::ModelReduce::compile_model` (for the post-apply snapshot compare), `NMISNG::Util::writeHashtoFile`.
- Produces: `apply_changes($results, $custom_dir, $config)` in `admin/reduce_model.pl`. Backs up then removes verified identical and reducible copies, writes overrides for reducible files, clears affected model cache entries, and recompiles affected models to confirm they match a pre-apply snapshot.

- [ ] **Step 1: Add the apply subroutine**

Add to `admin/reduce_model.pl` (after the `report` sub):

```perl
sub apply_changes
{
	my ($results, $custom_dir, $C) = @_;

	my @todo = grep { $_->{verified}
			&& ($_->{category} eq "identical" || $_->{category} eq "reducible") } @$results;
	if (!@todo)
	{
		print "\nNothing to apply.\n";
		return;
	}

	# snapshot compiled models BEFORE any change (real dirs, isolated var)
	my $default_dir = $arg->{default_dir} // NMISNG::Util::getDir(dir => "default_models", conf => $C);
	my $snap_var = "$scratch/snap-before"; make_path("$snap_var/nmis_system/model_cache");
	my %before;
	for my $r (@todo)
	{
		for my $m (affected_models($r, $custom_dir, $default_dir))
		{
			$before{$m} //= NMISNG::ModelReduce::compile_model(model=>$m, config=>$C,
				default_dir=>$default_dir, custom_dir=>$custom_dir, var_dir=>$snap_var);
		}
	}

	print "\nAbout to change " . scalar(@todo) . " file(s) in $custom_dir\n";
	print "A backup of each removed copy is written first.\n";
	print "Type 'yes' to proceed: ";
	my $answer = <STDIN>; chomp($answer // "");
	if (lc($answer) ne "yes") { print "Aborted, no changes made.\n"; return; }

	my $ts = _timestamp();
	my $backup = "$custom_dir/.reduce-backup-$ts";
	make_path($backup);

	for my $r (@todo)
	{
		my $file = "$custom_dir/$r->{basename}.nmis";
		if (!copy($file, "$backup/$r->{basename}.nmis"))
		{
			warn "backup failed for $file: $! - skipping\n";
			next;
		}
		if ($r->{category} eq "reducible")
		{
			local $Data::Dumper::Sortkeys = 1;
			NMISNG::Util::writeHashtoFile(file => "$custom_dir/Override-$r->{basename}.nmis",
				data => $r->{override}, json => 0, conf => $C);
		}
		unlink($file) or warn "could not remove $file: $!\n";
		print "changed: $r->{basename} ($r->{category})\n";
	}

	# clear affected model cache entries
	my $cachedir = $C->{'<nmis_var>'} . "/nmis_system/model_cache";
	for my $r (@todo)
	{
		for my $m (affected_models($r, $custom_dir, $default_dir))
		{
			unlink("$cachedir/$m.json");
			unlink("$cachedir/$m.json.meta.json");
		}
	}

	# post-apply guard: recompile and compare against the snapshot
	my $snap_var2 = "$scratch/snap-after"; make_path("$snap_var2/nmis_system/model_cache");
	my $failed = 0;
	for my $m (sort keys %before)
	{
		my $after = NMISNG::ModelReduce::compile_model(model=>$m, config=>$C,
			default_dir=>$default_dir, custom_dir=>$custom_dir, var_dir=>$snap_var2);
		if (!NMISNG::ModelReduce::deep_equal($before{$m}, $after))
		{
			warn "POST-APPLY MISMATCH on $m - restore from $backup\n";
			$failed++;
		}
	}
	if ($failed) { print "\nWARNING: $failed model(s) mismatched after apply. Backup: $backup\n"; }
	else { print "\nDone. All affected models compile identically. Backup: $backup\n"; }
	return;
}

sub affected_models
{
	my ($r, $custom_dir, $default_dir) = @_;
	return ($r->{basename}) if ($r->{basename} =~ /^Model-/);
	my $feature = $r->{basename}; $feature =~ s/^Common-//;
	return NMISNG::ModelReduce::models_referencing_common($feature, $custom_dir, $default_dir);
}

sub _timestamp
{
	my @t = localtime();
	return sprintf("%04d%02d%02d-%02d%02d%02d",
		$t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}
```

- [ ] **Step 2: Run apply against a disposable copy of the sample**

```bash
cp -r /path/to/extracted/models-custom /tmp/mc-applytest
perl admin/reduce_model.pl dir=/tmp/mc-applytest apply=1
# answer: yes
```

Expected: identical and reducible copies removed, `Override-*.nmis` written for reducible ones, drift files untouched, a `.reduce-backup-<ts>` dir created, and the closing line "All affected models compile identically."

- [ ] **Step 3: Verify the reduced dir still compiles the same models**

```bash
perl admin/reduce_model.pl dir=/tmp/mc-applytest
```

Expected: the previously reducible files no longer appear as copies; drift files still listed as drift.

- [ ] **Step 4: Commit**

```bash
git add admin/reduce_model.pl
git commit -m "feat(model-reduce): add guarded apply path with backup and post-apply check"
```

---

### Task 11: Integration test for the full analyse-to-apply outcome mix

**Files:**
- Modify: `test/t_reduce_model.pl`

**Interfaces:**
- Consumes: `analyse`.
- Produces: a synthetic scenario covering every outcome, asserting the category counts, so a regression in classification or verification is caught without the customer sample.

- [ ] **Step 1: Write the failing test**

Append to `test/t_reduce_model.pl` before `done_testing();`:

```perl
# integration: full outcome mix on synthetic fixtures
{
	my $C = NMISNG::Util::loadConfTable();
	SKIP: {
		skip "no usable config", 4 if (ref($C) ne "HASH" || !%$C);
		my $base = tempdir("t-reduce-int-XXXXXX", TMPDIR => 1, CLEANUP => 1);
		my $def = "$base/models-default";
		my $cus = "$base/models-custom";
		make_path($def, $cus);

		# a Common referenced by a model, reducible via override
		NMISNG::Util::writeHashtoFile(file=>"$def/Common-Feat.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{cpu=>{graphtype=>'cpu', threshold=>'base'}}}});
		NMISNG::Util::writeHashtoFile(file=>"$def/Model-Host.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'V'}, '-common-'=>{class=>{cpu=>{'common-model'=>'Feat'}}}});

		# custom Common changes a threshold only (reducible)
		NMISNG::Util::writeHashtoFile(file=>"$cus/Common-Feat.nmis", json=>0, conf=>$C, data=>{
			systemHealth=>{rrd=>{cpu=>{graphtype=>'cpu', threshold=>'tuned'}}}});
		# identical model copy
		NMISNG::Util::writeHashtoFile(file=>"$cus/Model-Host.nmis", json=>0, conf=>$C, data=>{
			system=>{nodeVendor=>'V'}, '-common-'=>{class=>{cpu=>{'common-model'=>'Feat'}}}});

		my $res = NMISNG::ModelReduce::analyse(custom_dir=>$cus, default_dir=>$def, config=>$C);
		my %cat;
		$cat{$_->{category}}++ for @$res;

		is($cat{identical}, 1, "one identical (Model-Host copy)");
		is($cat{reducible}, 1, "one reducible (Common-Feat)");
		my ($common) = grep { $_->{basename} eq "Common-Feat" } @$res;
		ok($common->{verified}, "Common reduction verified via referencing model");
		is_deeply($common->{override},
			{systemHealth=>{rrd=>{cpu=>{threshold=>'tuned'}}}},
			"Common override carries only the changed leaf");
	}
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `perl test/t_reduce_model.pl`
Expected: PASS if Tasks 1-8 are complete (this exercises them together). If it fails, fix the relevant task's code, not the test.

- [ ] **Step 3: Commit**

```bash
git add test/t_reduce_model.pl
git commit -m "test(model-reduce): integration test for full outcome mix"
```

---

### Task 12: Update documentation

**Files:**
- Modify: `docs/model-loading.md`

**Interfaces:** none.

Note: `CLAUDE.md` and `docs/CLI_TOOLS.md` are local untracked files, not part of `nmis9_dev`, so they are out of scope for this branch. Update them in the working checkout separately if wanted.

- [ ] **Step 1: Find the manual-process section**

Run: `grep -n "compare_models\|Override-\|manual" docs/model-loading.md`
Expected: a section describing the manual `compare_models.pl` then hand-write workflow.

- [ ] **Step 2: Add a pointer to the tool**

Add a short subsection to `docs/model-loading.md` near that section:

```markdown
### Automating the reduction

`admin/reduce_model.pl` automates converting full custom copies into
`Override-*.nmis` files. It runs read-only by default, classifies each custom
Model or Common file as identical, reducible, or drifted, and verifies every
proposed change by compiling the model both ways with the real loader. Pass
`apply=1` to write the overrides and remove the reduced copies (each copy is
backed up first). Graph files and files with no default counterpart are
reported and left alone. See the header of the script for full arguments.
```

- [ ] **Step 3: Run the full test suite once more**

Run: `perl test/t_reduce_model.pl`
Expected: PASS (all tasks).

- [ ] **Step 4: Commit**

```bash
git add docs/model-loading.md
git commit -m "docs(model-reduce): document reduce_model.pl in model-loading.md"
```

---

## Self-review notes

- Spec coverage: scope (Task 8 categorisation), diff rules (Task 2), verification incl. Common-by-referencing-model and post-apply guard (Tasks 5-7, 10), apply safety with backup and confirm (Task 10), report + manual-start overrides (Tasks 8-9), testing (Tasks 1-11), docs (Task 12). The "identical -> remove" outcome is covered by Tasks 7-10.
- Type consistency: `semantic_diff` returns `{set,drop,typeconflict}` used unchanged by `classify`, `build_override`, and `analyse`. `verify_reduction` returns `{ok,models,mismatch}` consumed by `analyse`. `analyse` result fields `{basename,category,verified,override,drops,error}` are consumed by the CLI `report`/`apply_changes`.
- Placeholder scan: every code step contains complete code. Manual-run tasks (9, 10) give exact commands and expected output rather than automated asserts, because they exercise a CLI with a confirmation prompt.
