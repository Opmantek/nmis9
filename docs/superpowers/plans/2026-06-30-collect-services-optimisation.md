# collect_services optimisation (trinary process-detail level) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This plan is to be executed in a separate session** (not the one that wrote it).

**Goal:** Add a per-node-overridable `collect_services_process_detail` config (`full`/`noperf`/`minimal`) that reduces the SNMP `hrSWRunTable` walk in `collect_services` to only the columns a node needs, defaulting to today's behaviour.

**Architecture:** Two small private helpers on `NMISNG::Node` (`_service_walk_columns`, `_service_process_detail`) decide the column set and resolve the level; `collect_services` consumes them and gates the `snmp_services` save and the per-service cpu/mem computation by level. The option is registered as a default in `Config.nmis` and as editor fields in `Table-Config.nmis` (global) and `Table-Nodes.nmis` (per-node).

**Tech Stack:** Perl 5, NMISNG (`NMISNG::Node`, `NMISNG::Sys`, `NMISNG::Util`), MongoDB, Test::More. SNMP via `$S->snmp->getindex`.

**Spec:** `docs/superpowers/specs/2026-06-30-collect-services-optimisation-design.md`

## Global Constraints

- Branch `collect-services-optimisation`, rooted from `origin/nmis9_dev` (`158e2c34`).
- Config key: `collect_services_process_detail`; values `full` (default) | `noperf` | `minimal`.
- `full` must be byte-for-byte today's behaviour: same column set/order, `snmp_services` saved, per-service cpu/mem produced.
- Resolution: per-node `configuration` value if set and non-empty, else global `Config.nmis`, else built-in `full`; an unrecognised value falls back to `full` with a logged warning.
- Scope is the `service`-type SNMP walk only. Do NOT change the `port`/`dns`/`script`/`program` paths, per-service up/down logic, Service Down/Degraded events, or the `service`/`responsetime` RRD.
- TDD, frequent commits. Tests run with `perl test/<file>` (inside the dev container if a MongoDB connection is needed; the helper unit tests in Tasks 1-2 need no DB).
- Line numbers below are against `lib/NMISNG/Node.pm` at base `158e2c34`; if they have shifted, locate by the quoted code.

---

## File Structure

- `lib/NMISNG/Node.pm` — add two private subs (`_service_walk_columns`, `_service_process_detail`) just above `sub collect_services` (~`8206`); wire them into `collect_services` and gate two blocks. No other file in `lib/` changes.
- `conf-default/Config.nmis` — global default value.
- `conf-default/Table-Config.nmis` — global Config-editor dropdown.
- `conf-default/Table-Nodes.nmis` — per-node override field.
- `test/t_collect_services.pl` — new test file, grown across tasks (helper unit tests, then the integration test, then the config-registration checks).

---

## Task 1: `_service_walk_columns` helper + unit tests

**Files:**
- Modify: `lib/NMISNG/Node.pm` (add one sub above `sub collect_services`, ~line 8206)
- Create: `test/t_collect_services.pl`

**Interfaces:**
- Produces: `NMISNG::Node::_service_walk_columns($detail, $need_params)` — a plain package sub (no `$self`). Returns the list of `hrSWRunTable` column names to walk. `$detail` is one of `full`/`noperf`/`minimal`; `$need_params` is a boolean.

- [ ] **Step 1: Write the failing test**

Create `test/t_collect_services.pl`:

```perl
#!/usr/bin/perl
# Tests for collect_services trinary process-detail level (collect_services_process_detail).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::Node;

# --- _service_walk_columns: the column set per detail level ---
is_deeply([ NMISNG::Node::_service_walk_columns('full', 0) ],
  [qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem)],
  "full walks all 7 columns in today's order");
is_deeply([ NMISNG::Node::_service_walk_columns('noperf', 0) ],
  [qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus hrSWRunType)],
  "noperf drops the two Perf columns, keeps the process-table columns");
is_deeply([ NMISNG::Node::_service_walk_columns('minimal', 0) ],
  [qw(hrSWRunName hrSWRunStatus)],
  "minimal without param-matching = name + status only");
is_deeply([ NMISNG::Node::_service_walk_columns('minimal', 1) ],
  [qw(hrSWRunName hrSWRunStatus hrSWRunPath hrSWRunParameters)],
  "minimal with a param-matching service adds path + parameters");

done_testing;
```

- [ ] **Step 2: Run it, verify it fails**

Run: `perl test/t_collect_services.pl`
Expected: FAIL — `Undefined subroutine &NMISNG::Node::_service_walk_columns`.

- [ ] **Step 3: Implement the sub**

In `lib/NMISNG/Node.pm`, immediately before `sub collect_services` (~line 8206), add:

```perl
# Returns the hrSWRunTable columns to walk for a given service-detail level.
#   full    - today's full set (process table + cpu/mem perf columns)
#   noperf  - process table without the slow cpu/mem perf columns
#   minimal - service up/down only, plus path/parameters when a service matches on them
# $need_params is true iff some configured service-type service uses Service_Parameters.
sub _service_walk_columns
{
	my ($detail, $need_params) = @_;
	return (qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus
			   hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem))  if ($detail eq 'full');
	return (qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus hrSWRunType))
															  if ($detail eq 'noperf');
	my @cols = ('hrSWRunName', 'hrSWRunStatus');             # minimal
	push @cols, ('hrSWRunPath', 'hrSWRunParameters') if ($need_params);
	return @cols;
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `perl test/t_collect_services.pl`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm test/t_collect_services.pl
git commit -m "collect_services: add _service_walk_columns helper (trinary column set)"
```

---

## Task 2: `_service_process_detail` resolution helper + unit tests

**Files:**
- Modify: `lib/NMISNG/Node.pm` (add one sub above `sub collect_services`)
- Modify: `test/t_collect_services.pl` (add a resolution-tests block)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `$node->_service_process_detail()` — instance method. Returns `full`/`noperf`/`minimal`, resolving per-node `configuration->{collect_services_process_detail}` (if set and non-empty), else `$self->nmisng->config->{collect_services_process_detail}`, else `full`; unknown values log a warning and return `full`.

- [ ] **Step 1: Write the failing test**

Append to `test/t_collect_services.pl`, before `done_testing;`. Add the extra `use` lines to the top of the file as well (`use NMISNG; use NMISNG::Util; use NMISNG::Log;`):

```perl
# --- _service_process_detail: per-node override // global // default ---
{
  my $C = NMISNG::Util::loadConfTable();
  $C->{db_name} = "t_collsvc-$$";
  my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
  my $node = $nmisng->node(uuid=>"5e4f1ce0-0000-0000-0000-000000000001", create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("svc_detail");
  $node->configuration({host=>"127.0.0.1", group=>"NMIS9", active=>1, collect=>1}); $node->save();

  delete $nmisng->config->{collect_services_process_detail};
  is($node->_service_process_detail, 'full', "defaults to full when nothing set");

  $nmisng->config->{collect_services_process_detail} = 'noperf';
  is($node->_service_process_detail, 'noperf', "inherits the global value");

  $node->configuration->{collect_services_process_detail} = 'minimal';
  is($node->_service_process_detail, 'minimal', "per-node value overrides global");

  $node->configuration->{collect_services_process_detail} = '';
  is($node->_service_process_detail, 'noperf', "empty per-node value falls through to global");

  $node->configuration->{collect_services_process_detail} = 'bogus';
  is($node->_service_process_detail, 'full', "unrecognised value falls back to full");

  $nmisng->get_db()->drop();
}
```

- [ ] **Step 2: Run it, verify it fails**

Run (in the dev container, this block needs a MongoDB connection): `perl test/t_collect_services.pl`
Expected: FAIL — `Can't locate object method "_service_process_detail"`.

- [ ] **Step 3: Implement the sub**

In `lib/NMISNG/Node.pm`, just below `_service_walk_columns`, add:

```perl
# Resolves the service-detail level for this node: per-node configuration override
# (if set and non-empty), else the global config value, else the built-in default 'full'.
# Unknown values log a warning and fall back to 'full'.
sub _service_process_detail
{
	my ($self) = @_;
	my $v = $self->configuration->{collect_services_process_detail};
	$v = $self->nmisng->config->{collect_services_process_detail}
		if (!defined($v) || $v eq '');
	$v = 'full' if (!defined($v) || $v eq '');
	if ($v ne 'full' and $v ne 'noperf' and $v ne 'minimal')
	{
		$self->nmisng->log->warn("unknown collect_services_process_detail '$v' for node "
								 . $self->name . ", using 'full'");
		$v = 'full';
	}
	return $v;
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `perl test/t_collect_services.pl`
Expected: PASS, 9 tests total.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm test/t_collect_services.pl
git commit -m "collect_services: add _service_process_detail resolution (per-node // global // full)"
```

---

## Task 3: Wire the helpers into collect_services and gate the level-dependent blocks

**Files:**
- Modify: `lib/NMISNG/Node.pm` `sub collect_services` (4 edits, all by the line refs/quoted code below)
- Modify: `test/t_collect_services.pl` (add the integration block)

**Interfaces:**
- Consumes: `_service_walk_columns`, `_service_process_detail` from Tasks 1-2.
- Produces: `collect_services` honours the resolved level — walks only the needed columns, skips the `snmp_services` save for `minimal`, and computes per-service cpu/mem only for `full`.

- [ ] **Step 1: Write the failing integration test**

Append to `test/t_collect_services.pl` before `done_testing;`. It drives `collect_services` with a fake SNMP object and a fixture Services table, at each level. Add `use NMISNG::Sys;` to the top of the file.

```perl
# --- integration: collect_services honours the detail level ---
{
  # a fake SNMP object: records which columns get_index is asked for, returns fixture columns
  package FakeSnmp;
  our @REQUESTED;
  my %FIX = (
    hrSWRunName       => { 100 => 'sshd', 200 => 'bash' },
    hrSWRunStatus     => { 100 => 1,      200 => 1 },           # 1 => running
    hrSWRunType       => { 100 => 4,      200 => 4 },           # 4 => application
    hrSWRunPath       => { 100 => '/usr/sbin/sshd', 200 => '/bin/bash' },
    hrSWRunParameters => { 100 => '-D',   200 => '' },
    hrSWRunPerfCPU    => { 100 => 1234,   200 => 50 },
    hrSWRunPerfMem    => { 100 => 4096,   200 => 1024 },
  );
  sub new      { bless {}, shift }
  sub getindex { my ($s,$var) = @_; push @REQUESTED, $var; return $FIX{$var}; }
  sub error    { return ""; }
  package main;

  # fixture Services table; patch loadTable so collect_services sees only these
  my %SVC = (
    'SSH'    => { Name=>'SSH',    Service_Name=>'sshd', Service_Type=>'service',
                  Service_Parameters=>'', Poll_Interval=>'5m' },
    'Tomcat' => { Name=>'Tomcat', Service_Name=>'java', Service_Type=>'service',
                  Service_Parameters=>'tomcat', Poll_Interval=>'5m' },
  );
  my $orig_loadtable = \&NMISNG::Util::loadTable;
  no warnings 'redefine';
  local *NMISNG::Util::loadTable = sub {
    my %a = @_; return { %SVC } if (($a{name}//'') eq 'Services'); return $orig_loadtable->(@_);
  };
  use warnings 'redefine';

  my $C = NMISNG::Util::loadConfTable();
  $C->{db_name} = "t_collsvc-int-$$";
  my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

  # helper: run one collect_services at a given level, return (\@columns, $serviceupok, $hasprocesstable, $hascpumem)
  my $RUN = 0;
  my $run = sub {
    my ($detail, @services) = @_;
    my $uuid = sprintf("5e4f1ce0-0000-0000-0000-%012d", ++$RUN);   # unique per run
    my $node = $nmisng->node(uuid=>$uuid, create=>1);
    $node->cluster_id($C->{cluster_id}); $node->name("svc_${detail}_$RUN");
    $node->configuration({ host=>"127.0.0.1", group=>"NMIS9", active=>1, collect=>1,
                           services=>[@services],
                           collect_services_process_detail=>$detail });
    $node->save();

    # catchall inventory + a Sys with the fake SNMP
    my $cp = $node->inventory_path(concept=>"catchall", data=>{}, path_keys=>[]);
    my ($ca) = $node->inventory(concept=>"catchall", model_class=>"system", path=>$cp, path_keys=>[], create=>1);
    $ca->data_live->{nodeType} = "server"; $ca->save(node=>$node);

    my $S = NMISNG::Sys->new(nmisng=>$nmisng);
    $S->init(node=>$node, snmp=>0, wmi=>0, catchall_inventory=>$ca);
    $S->{snmp} = FakeSnmp->new;
    $S->status->{snmp_enabled} = 1;

    @FakeSnmp::REQUESTED = ();
    $node->collect_services(sys=>$S, snmp=>'true', wmi=>'false', force=>1, catchall_inventory=>$ca);

    my @cols = @FakeSnmp::REQUESTED;
    # service up/down: SSH service inventory's newest timed data status (100 == up)
    my $sp = $node->inventory_path(concept=>"service", data=>{service=>"SSH"}, path_keys=>["service"]);
    my ($si) = $node->inventory(concept=>"service", path=>$sp, path_keys=>["service"], create=>0);
    my $sd = $si ? $si->get_newest_timed_data() : {};
    my $svcup = ($sd->{success} && ($sd->{data}{service}{status} // 0) == 100) ? 1 : 0;
    my $hascpumem = ($sd->{success} && defined($sd->{data}{service}{memory})) ? 1 : 0;
    # process table: snmp_services inventory has timed data?
    my ($pi) = $node->inventory(concept=>"snmp_services", path_keys=>[], create=>0);
    my $pd = $pi ? $pi->get_newest_timed_data() : {};
    my $hasproc = ($pd->{success} && ref($pd->{data}{snmp_services}) eq "HASH") ? 1 : 0;
    return (\@cols, $svcup, $hasproc, $hascpumem);
  };

  my ($c_full, $up_full, $proc_full, $cm_full)         = $run->('full', 'SSH');
  is_deeply([sort @$c_full],
    [sort qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem)],
    "full walks all 7 columns");
  ok($up_full,   "full: SSH resolves up");
  ok($proc_full, "full: snmp_services process table saved");
  ok($cm_full,   "full: per-service cpu/mem present");

  my ($c_np, $up_np, $proc_np, $cm_np)                 = $run->('noperf', 'SSH');
  is_deeply([sort @$c_np],
    [sort qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus hrSWRunType)],
    "noperf does NOT walk the Perf columns");
  ok($up_np,    "noperf: SSH resolves up");
  ok($proc_np,  "noperf: snmp_services process table still saved");
  ok(!$cm_np,   "noperf: no per-service cpu/mem");

  my ($c_min, $up_min, $proc_min)                      = $run->('minimal', 'SSH');
  is_deeply([sort @$c_min], [sort qw(hrSWRunName hrSWRunStatus)],
    "minimal walks only name+status (no param-matching service)");
  ok($up_min,    "minimal: SSH resolves up");
  ok(!$proc_min, "minimal: snmp_services process table NOT saved");

  my ($c_minp) = $run->('minimal', 'SSH', 'Tomcat');   # Tomcat uses Service_Parameters
  is_deeply([sort @$c_minp], [sort qw(hrSWRunName hrSWRunStatus hrSWRunPath hrSWRunParameters)],
    "minimal with a param-matching service also walks path+parameters");

  $nmisng->get_db()->drop();
}
```

NOTE for the implementer: this block drives the real `collect_services`, so run it and adjust mock details to the live API as needed (TDD). `create_update_rrd` may log an RRD error in the test environment — that is fine; the assertions read inventory/timed data, not RRD files. If `$S->init` needs a writable `var`/database dir, run inside the dev container.

- [ ] **Step 2: Run it, verify the new assertions fail**

Run (dev container): `perl test/t_collect_services.pl`
Expected: the `noperf`/`minimal` assertions FAIL — current code always walks all 7 columns and always saves `snmp_services`. (`full` assertions pass.)

- [ ] **Step 3: Resolve the level and column set in collect_services**

In `lib/NMISNG/Node.pm` `sub collect_services`, just after `my $C = $self->nmisng->config;` (~line 8220), add:

```perl
	my $detail = $self->_service_process_detail();
```

Then just after the Services table is loaded — `my $ST = NMISNG::Util::loadTable(dir => "conf", name => "Services", conf => $C);` (~line 8226) — add:

```perl
	# path/parameters columns are only needed (for matching) if some configured
	# service-type service uses Service_Parameters
	my $need_params = grep {
		my $s = $ST->{$_};
		$s && ($s->{Service_Type} // '') eq 'service'
			&& defined($s->{Service_Parameters}) && $s->{Service_Parameters} ne '';
	} @{ $self->configuration->{services} // [] };
```

- [ ] **Step 4: Replace the fixed column list with the helper**

Find the walk loop (~line 8251):

```perl
		for my $var (
			qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus
			hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem)
			)
		{
```

Replace the `qw(...)` list with the helper:

```perl
		for my $var ( _service_walk_columns($detail, $need_params) )
		{
```

- [ ] **Step 5: Gate the snmp_services save for `minimal`**

Find (~line 8403): `if( keys %services > 0 )` and change it to:

```perl
	if( keys %services > 0 && $detail ne 'minimal' )
```

(This skips the entire `snmp_services` inventory save + stale-process-event clearing, `8403-8455`, for `minimal`. `%services` is still built from name/status for the up/down match.)

- [ ] **Step 6: Gate per-service cpu/mem to `full`**

Find the living-process branch (~lines 8739-8761) and gate only the cpu/mem parts, leaving `$ret` always set:

```perl
				if ( !@livingprocs )
				{
					$ret       = 0;
					if ($detail eq 'full') { $cpu = 0; $memory = 0; $gotMemCpu = 1; }
					$status{status_text} = "Service $name is down,". ( @matchingprocs? "only non-running processes" : "no matching processes" );
					$self->nmisng->log->info("service $name is down, "
													 . ( @matchingprocs? "only non-running processes" : "no matching processes" ));
				}
				else
				{
					$ret       = 1;
					if ($detail eq 'full')
					{
						$gotMemCpu = 1;
						# cpu is in centiseconds, a running counter; memory is kb, a gauge
						$cpu    = int( Statistics::Lite::mean( map { $_->{hrSWRunPerfCPU} } (@livingprocs) ) );
						$memory =      Statistics::Lite::mean( map { $_->{hrSWRunPerfMem} } (@livingprocs) );
					}
					$status{status_text} = "Service $name is up, " . scalar(@livingprocs) . " running process(es)";
					$self->nmisng->log->info("service $name is up, " . scalar(@livingprocs) . " running process(es)");
				}
```

- [ ] **Step 7: Run the full test, verify it passes**

Run (dev container): `perl test/t_collect_services.pl`
Expected: PASS, all tasks' tests green (helper units + resolution + integration).

- [ ] **Step 8: Sanity-compile**

Run: `perl -c lib/NMISNG/Node.pm`
Expected: `lib/NMISNG/Node.pm syntax OK`.

- [ ] **Step 9: Commit**

```bash
git add lib/NMISNG/Node.pm test/t_collect_services.pl
git commit -m "collect_services: walk only the columns the detail level needs; gate snmp_services + cpu/mem"
```

---

## Task 4: Register the option (default value + GUI editors)

**Files:**
- Modify: `conf-default/Config.nmis`
- Modify: `conf-default/Table-Config.nmis`
- Modify: `conf-default/Table-Nodes.nmis`
- Modify: `test/t_collect_services.pl` (add registration checks)

**Interfaces:**
- Consumes: the config key name from the Global Constraints.
- Produces: a default value of `full` and GUI editor entries for the option.

- [ ] **Step 1: Write the failing checks**

Append to `test/t_collect_services.pl` before `done_testing;`:

```perl
# --- registration: default value + GUI editor entries present ---
{
  my $C = NMISNG::Util::loadConfTable();
  is($C->{collect_services_process_detail} // 'full', 'full', "global default resolves to full");

  my $base = "$FindBin::Bin/..";
  for my $f ("conf-default/Table-Config.nmis", "conf-default/Table-Nodes.nmis") {
    local $/; open my $fh, "<", "$base/$f" or die "open $f: $!"; my $src = <$fh>; close $fh;
    like($src, qr/collect_services_process_detail/, "$f declares the option");
    like($src, qr/"full".*"noperf".*"minimal"|'full'.*'noperf'.*'minimal'/s,
         "$f offers the three values");
  }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `perl test/t_collect_services.pl`
Expected: FAIL — the option is not yet in the table files (and possibly the default check, depending on environment).

- [ ] **Step 3: Add the global default to `conf-default/Config.nmis`**

In the `system` section of the `%hash` (alongside other `collect`/services-related keys), add:

```perl
    'collect_services_process_detail' => 'full',
```

- [ ] **Step 4: Add the Config-editor dropdown to `conf-default/Table-Config.nmis`**

In `Config` -> `system`, near `cbqos_cm_collect_all`, add an array entry:

```perl
			{ 'collect_services_process_detail' => { display => 'popup', value => ["full", "noperf", "minimal"] }},
```

- [ ] **Step 5: Add the per-node field to `conf-default/Table-Nodes.nmis`**

In the `Nodes` array, near the `services` field (~line 134), add an entry. The empty first value means "inherit the global default":

```perl
	 { collect_services_process_detail => { header => 'Service Process Detail',
				display => 'popup', value => ["", "full", "noperf", "minimal"] }},
```

- [ ] **Step 6: Syntax-check the table files and run the test**

Run:
```bash
perl -c conf-default/Table-Config.nmis
perl -c conf-default/Table-Nodes.nmis
perl test/t_collect_services.pl
```
Expected: both `syntax OK`; test PASS (all checks green).

- [ ] **Step 7: Commit**

```bash
git add conf-default/Config.nmis conf-default/Table-Config.nmis conf-default/Table-Nodes.nmis test/t_collect_services.pl
git commit -m "collect_services: register collect_services_process_detail (default + config/node editors)"
```

---

## Final verification (before handing back)

- [ ] Run the whole test file once more: `perl test/t_collect_services.pl` — all green.
- [ ] `perl -c lib/NMISNG/Node.pm` and the two table files — all `syntax OK`.
- [ ] Confirm `full` is unchanged: with no config set, a collect walks all 7 columns and still produces the `snmp_services` table and per-service cpu/mem (the `full` integration assertions cover this).
- [ ] Optional real-node check: set a slow net-snmp node to `noperf` (then `minimal`) and confirm `collect_services_time` drops, using the per-column `snmpbulkwalk` timing in the spec's Diagnostics section to pick the level.

## Out of scope (do not implement here)

- Walk-frequency gating (only walk when a service is due) — deferred follow-up in the spec.
- Any change to `port`/`dns`/`script`/`program` service types.
