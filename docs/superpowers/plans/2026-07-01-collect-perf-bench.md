# Cumulative collect-performance benchmark — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable, re-runnable system that measures how a stack of collect-performance branches affects NMIS, one merge at a time, against both a live net-snmp node and a deterministic mock node that replays a real capture, and records an appendable time-series of findings.

**Architecture:** A Perl measurement unit instruments `NMISNG::DB` operations, memory, and MongoDB server counters around a real `$node->collect()`; a shell orchestrator runs it for both nodes per layer and appends a row to a results table. Layers are produced by merging each optimization branch into a throwaway `perf-bench` branch, tagged per layer so any merge is undoable. The deterministic node replays a frozen snmpwalk capture of the real host through the in-tree `NMISNG::Snmp::Mock`.

**Tech Stack:** Perl 5, NMISNG (`NMISNG`, `NMISNG::Node`, `NMISNG::Sys`, `NMISNG::DB`, `NMISNG::Snmp::Mock`), MongoDB 7, net-snmp (`snmpwalk`), the dev docker stack, git worktrees.

## Global Constraints

- Worktree `/home/md/work/nmis9-perf-bench`, branch `perf-bench`, cut from `origin/nmis9_dev` at `158e2c34` (the `Plugin nodeobj param (#184)` commit — nodeobj is in the baseline).
- The `perf-bench` branch is NEVER merged into `nmis9_dev`. Each layer is a commit tagged `bench-L<n>-<branch>`; the base is tagged `bench-base`. Undo = reset to a tag or delete the branch.
- Benchmark container: image `crg.apkg.io/firstwavecloud/nmis-dev:latest`, name `perfbench-nmis`, docker network `omk12375_net`, mount the `perf-bench` worktree at `/usr/local/nmis9`, env `NMIS_DB_USERNAME=root NMIS_DB_PASSWORD=example NMIS_DB_PORT=27017 NMIS_DB_SERVER=mongo NMIS_DB_NAME=nmisng_perfbench NMIS_SERVER_NAME=nmis NMIS_CLUSTER_ID=b705cd87-9688-4d6f-bc84-b0c1444630b9 DEV_UID=1000 DEV_GID=1000`. Isolated db `nmisng_perfbench` on the shared `omk12375-mongo`. Stop the nmisd daemon after startup (`pkill -f '[n]misd'`).
- Real net-snmp host: `172.20.0.1:1161`, community `nmisGig8`, model net-snmp. Reachable from the container via the `omk12375_net` gateway.
- Metrics per node per layer: per-collection MongoDB op counts (find/insert/update/remove/count/aggregate); collect wall-clock median of N=5 plus min/max; process RSS peak and delta; `serverStatus.opcounters` delta.
- Run scripts inside the container: `docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl -Ilib <script>'` (add `-Ilib` for bare perl; `perl test/<file>` self-adds lib via FindBin).
- Commit messages: prefix `perf-bench:`. NO `Co-Authored-By` or other trailers on any commit.
- No change to `nmis9_dev` or any optimization branch. Measurement system only.

---

## Task 1: Benchmark container, real-host capture, and the capture unit

**Files:**
- Create: `test/bench/capture_host.pl`
- Create (generated fixture, committed): `test/bench/testdata/realnode_capture.json`

**Interfaces:**
- Produces: `realnode_capture.json`, a flat JSON object `{ "<numeric-oid>": "<value>", ... }` in the exact shape `NMISNG::Snmp::Mock` consumes (see `test/testdata/snmpwalk_test.json`), consumed by Task 2's mock mode and Task 3's mock node.

- [ ] **Step 1: Stand up the benchmark container.**

```bash
docker run -d --name perfbench-nmis --network omk12375_net \
  -e NMIS_CLUSTER_ID=b705cd87-9688-4d6f-bc84-b0c1444630b9 \
  -e NMIS_DB_USERNAME=root -e NMIS_DB_PASSWORD=example -e NMIS_DB_PORT=27017 \
  -e NMIS_DB_SERVER=mongo -e NMIS_DB_NAME=nmisng_perfbench -e NMIS_SERVER_NAME=nmis \
  -e DEV_UID=1000 -e DEV_GID=1000 \
  -v /home/md/work/nmis9-perf-bench:/usr/local/nmis9 \
  crg.apkg.io/firstwavecloud/nmis-dev:latest
sleep 20
docker exec perfbench-nmis bash -lc "pkill -f '[n]misd'; pkill -f '[m]orbo'; pkill -f '[n]misx'; true"
```
Verify: `docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl -Ilib -e "use NMISNG; print qq{ok\n}"'` prints `ok`, and the resolved db_name is `nmisng_perfbench`:
`docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl -Ilib -e "use NMISNG::Util; print NMISNG::Util::loadConfTable(dir=>q{/usr/local/nmis9/conf})->{db_name},qq{\n}"'`
Expected: `nmisng_perfbench`.

- [ ] **Step 2: Confirm the real host answers and note its scale.**

Run: `docker exec perfbench-nmis bash -lc 'snmpget -v2c -c nmisGig8 172.20.0.1:1161 .1.3.6.1.2.1.2.1.0'`
Expected: `iso.3.6.1.2.1.2.1.0 = INTEGER: <N>` where N is the interface count (roughly 20+). If it does not answer, STOP — the capture cannot proceed.

- [ ] **Step 3: Write the capture unit `test/bench/capture_host.pl`.**

```perl
#!/usr/bin/perl
# Capture a live net-snmp host into the flat OID->value JSON that
# NMISNG::Snmp::Mock consumes. Usage: capture_host.pl <host> <port> <community> <outfile>
use strict; use warnings;
use JSON::XS;
my ($host,$port,$comm,$out) = @ARGV;
die "usage: capture_host.pl host port community outfile\n" if (!$out);
die "refusing to overwrite existing capture $out\n" if (-e $out);   # frozen capture is stable
# Walk the subtrees the net-snmp model reads. -On = numeric OIDs, -Oe = no symbolic, -Ln = no logging.
my @roots = qw(1.3.6.1.2.1.1 1.3.6.1.2.1.2 1.3.6.1.2.1.4 1.3.6.1.2.1.31 1.3.6.1.2.1.25);
my %walk;
for my $root (@roots) {
  open(my $fh, "-|", "snmpwalk","-v2c","-c",$comm,"-On","-OQ","-Ln","$host:$port",".$root")
    or die "snmpwalk failed for $root: $!\n";
  while (my $line = <$fh>) {
    chomp $line;
    # numeric-OID lines look like: .1.3.6.1.2.1.1.1.0 = <value>   (with -OQ, no type prefix)
    next unless ($line =~ /^\.([\d.]+)\s+=\s+(.*)$/);
    my ($oid,$val) = ($1,$2);
    $val =~ s/^"(.*)"$/$1/;            # strip surrounding quotes
    $val =~ s/^\s+|\s+$//g;            # trim
    $walk{$oid} = $val;
  }
  close($fh);
}
die "capture is empty — snmpwalk returned nothing\n" if (!keys %walk);
open(my $o, ">", $out) or die "cannot write $out: $!\n";
print $o JSON::XS->new->canonical->pretty->encode(\%walk);
close($o);
printf "captured %d OIDs to %s\n", scalar(keys %walk), $out;
```

- [ ] **Step 4: Run the capture.**

Run: `docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/bench/capture_host.pl 172.20.0.1 1161 nmisGig8 test/bench/testdata/realnode_capture.json'`
Expected: `captured <N> OIDs to test/bench/testdata/realnode_capture.json`, N in the hundreds (system + full interface tables). If `-OQ` yields lines the regex misses (a type prefix still present, e.g. `Timeticks`, `Hex-STRING`), extend the parser to strip the `TYPE:` prefix and, for `Timeticks`, keep the parenthesised tick count; re-run. Record any OID whose value the parser cannot represent rather than dropping it.

- [ ] **Step 5: Sanity-check the capture has interface data.**

Run: `docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl -MJSON::XS -e "my \$h=JSON::XS->new->decode(do{local \$/;open my \$f,q{<},q{test/bench/testdata/realnode_capture.json};<\$f>}); my @if=grep {/^1\.3\.6\.1\.2\.1\.2\.2\.1\.2\./} keys %\$h; print scalar(@if),qq{ ifDescr entries\n}"'`
Expected: a count matching the interface count from Step 2 (the ifDescr column of ifTable).

- [ ] **Step 6: Commit.**

```bash
git add test/bench/capture_host.pl test/bench/testdata/realnode_capture.json
git commit -m "perf-bench: capture unit + frozen real-host snmp capture"
```

---

## Task 2: The measurement unit `collect_bench.pl`

**Files:**
- Create: `test/bench/collect_bench.pl`

**Interfaces:**
- Consumes: the capture from Task 1 (mock mode); a node created by Task 3.
- Produces: one JSON object on stdout: `{ node, mode, runs, db_ops:{<collection>:{find:N,update:N,...}}, wallclock_ms:{median,min,max}, rss_kb:{before,peak,delta}, opcounters_delta:{query,update,insert,delete,getmore,command} }`. Consumed by Task 3's `run_layer.sh`.

- [ ] **Step 1: Write `test/bench/collect_bench.pl`.**

```perl
#!/usr/bin/perl
# Measure one collect. Usage: collect_bench.pl --node NAME --mode live|mock --runs 5 [--capture PATH]
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/../../lib";
use Getopt::Long; use JSON::XS; use Time::HiRes qw(time);
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;
my %o = (mode=>"live", runs=>5, capture=>"$FindBin::Bin/testdata/realnode_capture.json");
GetOptions(\%o, "node=s","mode=s","runs=i","capture=s") or die;
die "need --node\n" if (!$o{node});

my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

# ---- DB op instrumentation: wrap each op, count by collection + op name ----
my %DBOPS; my $COUNTING = 0;
my $collname = sub { my %a=@_; my $c=$a{collection};
  return (ref($c) && $c->can("name")) ? $c->name : "$c"; };
for my $op (qw(find insert update remove count aggregate)) {
  no strict 'refs'; no warnings 'redefine';
  my $orig = \&{"NMISNG::DB::$op"};
  *{"NMISNG::DB::$op"} = sub {
    if ($COUNTING) { my $n = $collname->(@_); $n =~ s/^.*\.//; $DBOPS{$n}{$op}++; }
    return $orig->(@_);
  };
}

# ---- mock injection: in mock mode, make Sys::open install the mock walk ----
if ($o{mode} eq "mock") {
  require NMISNG::Snmp::Mock;
  my $walk = JSON::XS->new->decode(do { local $/; open my $f,"<",$o{capture} or die "no capture $o{capture}\n"; <$f> });
  # drop comment keys (leading underscore)
  delete $walk->{$_} for grep { /^_/ } keys %$walk;
  no warnings 'redefine';
  my $orig_open = \&NMISNG::Sys::open;
  *NMISNG::Sys::open = sub {
    my ($self, %a) = @_;
    $self->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $self->nmisng, walk_data => $walk);
    $self->{snmp}->{session} = 1;    # mark open; see Mock.pm isopen/testsession
    return 1;                         # mock session is always good
  };
}

my $node = $nmisng->node(name => $o{node}) or die "node $o{node} not found\n";
sub rss_kb { open my $s,"<","/proc/self/status" or return 0; while(<$s>){ return $1 if /^VmRSS:\s+(\d+)/ } 0 }
sub opcounters {
  my $db = $nmisng->get_db(); my $admin = $db->_database->_client->get_database("admin");
  my $ss = $admin->run_command([serverStatus=>1]); my $o = $ss->{opcounters} || {};
  return { map { $_ => 0 + ($o->{$_}//0) } qw(query update insert delete getmore command) };
}

# warm-up (discarded)
$COUNTING=0; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1);

my (@wall, %ops_run, $rss_before, $rss_peak); my $oc_before = opcounters();
$rss_before = rss_kb();
for my $i (1..$o{runs}) {
  %DBOPS=(); $COUNTING=1;
  my $t0=time; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); my $ms=(time-$t0)*1000;
  $COUNTING=0;
  push @wall, $ms;
  $rss_peak = rss_kb() if (!defined $rss_peak || rss_kb() > $rss_peak);
  # op counts are deterministic on mock; keep the last run's counts
  %ops_run = %DBOPS;
}
my $oc_after = opcounters();
my @s = sort { $a<=>$b } @wall;
my %ocd = map { $_ => $oc_after->{$_} - $oc_before->{$_} } keys %$oc_after;
print JSON::XS->new->canonical->encode({
  node=>$o{node}, mode=>$o{mode}, runs=>$o{runs},
  db_ops=>\%ops_run,
  wallclock_ms=>{ median=>$s[int(@s/2)], min=>$s[0], max=>$s[-1] },
  rss_kb=>{ before=>$rss_before, peak=>$rss_peak, delta=>$rss_peak-$rss_before },
  opcounters_delta=>\%ocd,
}), "\n";
```

- [ ] **Step 2: Confirm the mock-injection details against source.**

Read `test/lib/NMISNG/Snmp/Mock.pm` for the constructor arg name (the field holding the walk — the code uses `walk_data`; confirm and adjust the `new(...)` call if the key differs) and for `isopen`/`testsession`/`open` so the injected mock reports open. Read `NMISNG::Sys::open` to confirm no other side effect of the real open is needed by the collect path (e.g. `snmpVer`); if the collect path reads `$catchall_data->{snmpVer}`, set a benign value in the patched open. Adjust the patch minimally so a mock collect runs clean.

- [ ] **Step 3: Deferred until Task 3** (needs a node to exist). Validation happens in Task 4 Step 3.

- [ ] **Step 4: Commit.**

```bash
git add test/bench/collect_bench.pl
git commit -m "perf-bench: collect measurement unit (db ops, wall-clock, rss, opcounters; mock injection)"
```

---

## Task 3: Node setup, orchestration, and the results table

**Files:**
- Create: `test/bench/setup_nodes.pl`
- Create: `test/bench/run_layer.sh`
- Create: `test/bench/results.md`

**Interfaces:**
- Consumes: `collect_bench.pl` (Task 2), the capture (Task 1).
- Produces: two nodes (`realnode188` live, `mocknode` net-snmp); `run_layer.sh <label>` appends rows to `results.md`.

- [ ] **Step 1: Write `test/bench/setup_nodes.pl`.** It writes a node-def JSON for each node and creates it via the proven `admin/node_admin.pl act=create file=<json>` path (the event-prefetch spike used exactly this). Idempotent: skips a node that already exists. Both nodes carry the same live config (host `172.20.0.1:1161`, community `nmisGig8`, group NMIS9, model automatic); a real update picks the net-snmp model from sysDescr for both. The `mocknode` is identical on disk — its SNMP is swapped for the mock only at collect time by `collect_bench.pl --mode mock`.

```perl
#!/usr/bin/perl
# Create the two benchmark nodes via node_admin (proven path). Idempotent.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/../../lib";
use JSON::XS; use NMISNG; use NMISNG::Util; use NMISNG::Log;
my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
my $node_admin = "$FindBin::Bin/../../admin/node_admin.pl";
for my $name (qw(realnode188 mocknode)) {
  if ($nmisng->node(name=>$name)) { print "$name exists\n"; next; }
  my $def = { name=>$name, host=>"172.20.0.1", port=>1161, community=>"nmisGig8",
              group=>"NMIS9", version=>"snmpv2c", model=>"automatic",
              active=>"true", collect=>"true", ping=>"false", activated=>{ NMIS=>1 } };
  my $file = "/tmp/$name.json";
  open(my $fh, ">", $file) or die "cannot write $file: $!\n";
  print $fh JSON::XS->new->encode($def); close($fh);
  my $rc = system("perl", $node_admin, "act=create", "file=$file");
  die "node_admin create failed for $name (rc=$rc)\n" if ($rc != 0);
  print "created $name\n";
}
```
Confirm the exact node-def JSON keys `node_admin act=create` expects by reading `admin/node_admin.pl` around its create handler (the fields above match the event-prefetch spike's working `realnode188.json`; adjust key names only if that handler differs).

- [ ] **Step 2: Bring both nodes to steady state (update then collect), live and mock.**

```bash
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/bench/setup_nodes.pl'
# realnode188 real update+collect
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/dev-tools.pl act=update node=realnode188 && perl test/dev-tools.pl act=collect node=realnode188'
```
For `mocknode`, steady state is reached through the mock: run `collect_bench.pl --node mocknode --mode mock --runs 1` once (its warm-up run builds inventory). Expected: no crash.

- [ ] **Step 3: Write `test/bench/run_layer.sh`.**

```bash
#!/bin/bash
# Run both nodes for one layer and append rows to results.md. Usage: run_layer.sh <layer-label>
set -euo pipefail
LABEL="${1:?usage: run_layer.sh <layer-label>}"
WT=/home/md/work/nmis9-perf-bench
SHA="$(git -C "$WT" rev-parse --short HEAD)"
RESULTS="$WT/test/bench/results.md"

# collect_bench prints ONE JSON line on stdout (logs go to stderr). Reduce it to a table row.
REDUCER='
  my ($label,$sha)=@ARGV;
  my $j=JSON::XS->new->decode(do{local $/;<STDIN>});
  my ($finds,$tot)=(0,0);
  for my $c (values %{$j->{db_ops}}){ for my $op (keys %$c){ $tot+=$c->{$op}; $finds+=$c->{$op} if $op eq "find" } }
  printf "| %s | %s | %s | %s | %d | %d | %d | %d | %d | q=%d u=%d i=%d d=%d |\n",
    $label,$sha,$j->{node},$j->{mode},$finds,$tot,
    $j->{wallclock_ms}{median},$j->{rss_kb}{peak},$j->{rss_kb}{delta},
    @{$j->{opcounters_delta}}{qw(query update insert delete)};'

emit_row() { # mode node  -> one markdown row on stdout
  local mode="$1" node="$2" json
  json="$(docker exec perfbench-nmis bash -lc "cd /usr/local/nmis9 && perl test/bench/collect_bench.pl --node $node --mode $mode --runs 5" | tail -1)"
  printf '%s' "$json" | docker exec -i perfbench-nmis perl -MJSON::XS -e "$REDUCER" "$LABEL" "$SHA"
}

{ emit_row live realnode188
  emit_row mock mocknode
} >> "$RESULTS"
echo "appended rows for $LABEL"
```

- [ ] **Step 4: Create `test/bench/results.md` with the table header + narrative stub.**

```markdown
# Collect-performance benchmark results

Cumulative layers on `perf-bench` (baseline = origin/nmis9_dev @158e2c34, includes nodeobj).
Metrics per collect: events-find count is `finds`; `db_ops` is all MongoDB ops; wall-clock is
median of 5 runs (ms); RSS peak and delta in KB; opcounters delta (q=query/find, u=update,
i=insert, d=delete). Live = realnode188 (varies with host); mock = deterministic real capture.

| layer | sha | node | mode | finds | db_ops | wall_ms | rss_peak | rss_delta | opcounters |
|-------|-----|------|------|-------|--------|---------|----------|-----------|------------|

## Findings

(narrative added at the end)
```

- [ ] **Step 5: Commit.**

```bash
git add test/bench/setup_nodes.pl test/bench/run_layer.sh test/bench/results.md
git commit -m "perf-bench: node setup, layer orchestration, results table"
```

---

## Task 4: Base tag and L0 baseline measurement

**Files:** Modify `test/bench/results.md` (append L0 rows).

- [ ] **Step 1: Tag the base.**
```bash
git tag bench-base
```

- [ ] **Step 2: Validate the runner reproduces a known number (runner test).**

The event-prefetch spike measured, at the nmis9_dev baseline with the buffer off, a real-node collect around 37-78 events-collection finds (varies) and, crucially, the mock/synthetic reads scale with interface count. Run:
`docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/bench/collect_bench.pl --node mocknode --mode mock --runs 2'`
Expected: two runs with IDENTICAL `db_ops` (deterministic), a non-zero `events` find count, and a plausible interface-scaled total. If the two runs differ, the mock is not deterministic — STOP and fix (usually a non-frozen input leaking in). This is the gate that the runner is trustworthy.

- [ ] **Step 3: Measure L0.**
```bash
/home/md/work/nmis9-perf-bench/test/bench/run_layer.sh L0-baseline
```
Expected: two rows appended (realnode188 live, mocknode mock). Record them.

- [ ] **Step 4: Commit.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: L0 baseline measurement"
git tag bench-L0-baseline
```

---

## Task 5: L1 — merge OMK-12677 event-prefetch and measure

**Files:** Modify `test/bench/results.md`.

- [ ] **Step 1: Merge the branch.**
```bash
git merge --no-ff origin/OMK-12677-event-prefetch -m "perf-bench: merge L1 OMK-12677 event-prefetch"
```
If conflicts, resolve to keep BOTH the benchmark tooling (ours, under `test/bench/`) and the branch's changes (theirs, in `lib/`). The tooling and the optimization touch different files, so conflicts should be rare; a conflict in `docs/superpowers/` is resolved by keeping both docs. Record any resolution in the commit message.

- [ ] **Step 2: Steady state + measure.**
```bash
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/dev-tools.pl act=collect node=realnode188'
/home/md/work/nmis9-perf-bench/test/bench/run_layer.sh L1-omk12677
```
Expected: the mock node's `events` find count drops sharply versus L0 (the event buffer serves them). RSS may rise slightly (the buffer). Record.

- [ ] **Step 3: Commit + tag.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: L1 measurement (OMK-12677 event-prefetch)"
git tag bench-L1-omk12677
```

---

## Task 6: L2 — merge OMK-12668 latest-data-prefetch and measure

**Files:** Modify `test/bench/results.md`.

- [ ] **Step 1: Merge.**
```bash
git merge --no-ff origin/OMK-12668-latest-data-prefetch -m "perf-bench: merge L2 OMK-12668 latest-data-prefetch"
```
OMK-12668 predates nodeobj and touches `NMISNG.pm`/collect; expect possible conflicts with L1 in `NMISNG.pm` (both add prefetch primitives near `new`). Resolve to keep both prefetch mechanisms. Record the resolution.

- [ ] **Step 2: Steady state + measure.**
```bash
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/dev-tools.pl act=collect node=realnode188'
/home/md/work/nmis9-perf-bench/test/bench/run_layer.sh L2-omk12668
```
Expected: the mock node's `latest_data` find count drops versus L1. Record.

- [ ] **Step 3: Commit + tag.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: L2 measurement (OMK-12668 latest-data-prefetch)"
git tag bench-L2-omk12668
```

---

## Task 7: L3 — merge OMK-12669 collect-intf-shared-load and measure

**Files:** Modify `test/bench/results.md`.

- [ ] **Step 1: Merge.**
```bash
git merge --no-ff origin/OMK-12669-collect-intf-shared-load -m "perf-bench: merge L3 OMK-12669 collect-intf-shared-load"
```
Expect conflicts in the interface-collect code touched by L1/L2. Resolve to keep all optimizations. Record.

- [ ] **Step 2: Steady state + measure.**
```bash
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/dev-tools.pl act=collect node=realnode188'
/home/md/work/nmis9-perf-bench/test/bench/run_layer.sh L3-omk12669
```
Expected: the mock node's `inventory` find count drops versus L2. Record.

- [ ] **Step 3: Commit + tag.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: L3 measurement (OMK-12669 collect-intf-shared-load)"
git tag bench-L3-omk12669
```

---

## Task 8: L4 — OMK-12673 collect-services (only if it has code)

**Files:** Modify `test/bench/results.md`.

- [ ] **Step 1: Verify OMK-12673 carries code, not just a plan.**
```bash
git diff --stat origin/nmis9_dev...origin/OMK-12673-collect-services-optimisation -- lib bin
```
If the diff touches `lib`/`bin` with real changes, proceed to Step 2. If it only adds a `docs/` plan, SKIP: append a `results.md` note "L4 skipped: OMK-12673 is plan-only at <sha>", commit, and stop at Task 9.

- [ ] **Step 2: Merge + measure (if code exists).**
```bash
git merge --no-ff origin/OMK-12673-collect-services-optimisation -m "perf-bench: merge L4 OMK-12673 collect-services-optimisation"
docker exec perfbench-nmis bash -lc 'cd /usr/local/nmis9 && perl test/dev-tools.pl act=collect node=realnode188'
/home/md/work/nmis9-perf-bench/test/bench/run_layer.sh L4-omk12673
```
Expected: services-related op counts change versus L3. Record.

- [ ] **Step 3: Commit + tag.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: L4 measurement (OMK-12673 collect-services-optimisation)"
git tag bench-L4-omk12673
```

---

## Task 9: Combined findings

**Files:** Modify `test/bench/results.md` (the `## Findings` section).

- [ ] **Step 1: Write the narrative.** In the `## Findings` section, for each layer state which metric it moved and by how much (cite the table rows), the cumulative effect from L0 to the top layer, and any memory-versus-reads trade-off (RSS rising as reads fall). Note the live-node variability and that the mock node carries the controlled deltas. Note any layer whose conflict resolution altered the measured code.

- [ ] **Step 2: Commit.**
```bash
git add test/bench/results.md
git commit -m "perf-bench: combined findings across all layers"
git tag bench-final
```

---

## Notes for the implementer

- The mock node measures the deterministic, attributable deltas; the live node is the reality check and will vary. Trust the mock rows for per-layer attribution.
- If a merge conflict genuinely cannot be resolved to keep two optimizations working together, record it in the row and the commit and measure what actually built — a real interaction between branches is itself a finding.
- Undo any layer with `git reset --hard bench-L<n-1>-<...>`; discard everything by deleting the `perf-bench` branch and worktree. Never merge `perf-bench` into `nmis9_dev`.
- To add a future branch, cut from the current tip (or the relevant tag), merge it, run `run_layer.sh <label>`, append, commit, tag.
