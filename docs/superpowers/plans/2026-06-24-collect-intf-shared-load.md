# collect_intf_data Shared-Load DB Optimisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the per-interface inventory reloads in `collect_intf_data` (phase 8) by reusing the objects loaded in phase 1, proven non-behaviour-changing by a new interface-collect test suite.

**Architecture:** Deliverable A builds a reusable mock-driven test harness and a data-driven coverage suite for `collect_intf_data`/`update_intf_info`, capturing each case's ordered DB write-stream, RRD payloads, events, and final inventory state as golden files on the current code. Deliverable B then changes phase 1 to load full fields and instantiate via the standard path, refreshes the object map for updated interfaces in phases 4/7, and reuses those objects in phase 8, with the golden suite gating that every case is byte-identical except the intended drop in interface `find` count.

**Tech Stack:** Perl 5.36, Test::More, Test::Deep, MongoDB (temp DB per run), `NMISNG::Snmp::Mock`, `Devel::Size` (not needed here), the docker dev stack (`omk12375-nmis`/`omk12375-mongo`) for running tests.

## Global Constraints

- No production behaviour change in Deliverable B; the only intended diff is interface `find` count dropping from ~1+N to ~1, verified via `NMISNG::DB::get_db_stats`.
- No `Co-Authored-By` trailer on any commit.
- Tests run inside the docker dev container against a temp Mongo DB named per-run; never touch a shared DB.
- Follow existing test patterns from `test/t_polling.pl`; do not restructure unrelated code.
- All new test files use `use lib "$FindBin::Bin/lib"` so package paths match.
- Run tests with: `docker exec omk12375-nmis perl /usr/local/nmis9/test/<file> ...` (repo is mounted at `/usr/local/nmis9`).

---

## File Structure

- Create: `test/lib/IntfTestHarness.pm` — reusable harness: temp DB, mock SNMP injection, DB/RRD/event capture, golden record/compare, walk generator, inventory seeding.
- Create: `test/t_intf_collect.pl` — data-driven coverage suite for the 13 cases.
- Create: `test/testdata/intf_collect_golden/` — golden files (one JSON per case), committed.
- Modify (Deliverable B only): `lib/NMISNG/Node.pm` — phase 1 (`~3888-3957`), phases 4/7 (`~4091`, `~4291`), phase 8 (`~4340-4341`).

---

## Deliverable A: test harness and coverage suite (no production change)

### Task A1: Reusable harness module with capture and golden plumbing

**Files:**
- Create: `test/lib/IntfTestHarness.pm`
- Test: `test/t_intf_harness_selftest.pl`

**Interfaces:**
- Produces:
  - `IntfTestHarness->new(nmisng => $nmisng, rrd_dir => $path)` returns a blessed harness.
  - `$h->install_capture()` monkey-patches `NMISNG::DB::update/insert/remove`, `NMISNG::Sys::create_update_rrd`, and `Compat::NMIS::notify` to append to ordered logs; idempotent.
  - `$h->reset_capture()` clears the logs.
  - `$h->captured()` returns `{ db => [...], rrd => [...], events => [...] }` (deep copies, ordered).
  - `$h->normalise($captured)` strips volatile fields (`lastupdate`, `lastupdate_utc`, `expire_at`, `_id`, `time`) recursively, returning a comparable structure.
  - `$h->golden_path($casename)` returns `"$FindBin::Bin/testdata/intf_collect_golden/$casename.json"`.
  - `$h->assert_golden($casename, $captured, $final_state)` in record mode (`$ENV{RECORD_GOLDEN}`) writes the golden; otherwise `is_deeply` against it.

- [ ] **Step 1: Write the failing self-test**

```perl
#!/usr/bin/perl
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;
use IntfTestHarness;

my $h = IntfTestHarness->new(nmisng => undef, rrd_dir => "/tmp/h_$$");
$h->install_capture();
$h->reset_capture();
# simulate a db write through the patched layer
NMISNG::DB::update(collection => undef, query => {x=>1}, record => {data=>{ifDescr=>"e0"}, lastupdate=>123});
my $cap = $h->captured();
is(scalar @{$cap->{db}}, 1, "one db write captured");
my $norm = $h->normalise($cap);
ok(!exists $norm->{db}[0]{record}{lastupdate}, "lastupdate stripped by normalise");
is($norm->{db}[0]{record}{data}{ifDescr}, "e0", "content preserved");
done_testing;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_harness_selftest.pl`
Expected: FAIL, `Can't locate IntfTestHarness.pm`.

- [ ] **Step 3: Implement the harness module**

```perl
package IntfTestHarness;
use strict; use warnings;
use Clone qw(clone);
use JSON::XS;
use File::Path qw(make_path);
use Test::More;

our (@DB, @RRD, @EVENTS);
my $installed = 0;

sub new {
    my ($class, %a) = @_;
    make_path($a{rrd_dir}) if ($a{rrd_dir} && !-d $a{rrd_dir});
    return bless { nmisng => $a{nmisng}, rrd_dir => $a{rrd_dir} }, $class;
}

sub install_capture {
    my ($self) = @_;
    return if $installed; $installed = 1;
    no warnings 'redefine';

    require NMISNG::DB;
    for my $op (qw(update insert remove)) {
        my $orig = \&{"NMISNG::DB::$op"};
        no strict 'refs';
        *{"NMISNG::DB::$op"} = sub {
            my %args = @_;
            push @DB, clone({ op => $op, query => $args{query}, record => $args{record},
                              upsert => $args{upsert}, multiple => $args{multiple},
                              just_one => $args{just_one} });
            return $orig->(@_);
        };
    }
    require NMISNG::Sys;
    *NMISNG::Sys::create_update_rrd = sub {
        my ($s, %args) = @_;
        push @RRD, clone({ node => $s->{name}, type => $args{type},
                           data => $args{data} });
        if (ref($args{inventory})) {
            $args{inventory}->set_subconcept_type_storage(
                subconcept => ($args{type}//'unknown'), type => 'rrd',
                data => "/nodes/$s->{name}/mock-".($args{type}//'unknown').".rrd");
        }
        return 1;
    };
    require Compat::NMIS;
    my $orig_notify = \&Compat::NMIS::notify;
    *Compat::NMIS::notify = sub {
        my %args = @_;
        push @EVENTS, clone({ event => $args{event}, element => $args{element},
                              level => $args{level}, details => $args{details} });
        return; # do not raise real events in tests
    };
}

sub reset_capture { @DB = (); @RRD = (); @EVENTS = (); }
sub captured { return { db => clone(\@DB), rrd => clone(\@RRD), events => clone(\@EVENTS) }; }

my %VOLATILE = map { $_ => 1 } qw(lastupdate lastupdate_utc expire_at _id time _ts);
sub _strip {
    my ($node) = @_;
    if (ref($node) eq 'HASH') {
        for my $k (keys %$node) {
            if ($VOLATILE{$k}) { delete $node->{$k}; next; }
            _strip($node->{$k});
        }
    } elsif (ref($node) eq 'ARRAY') { _strip($_) for @$node; }
    return $node;
}
sub normalise { my ($self, $cap) = @_; return _strip(clone($cap)); }

sub golden_path {
    my ($self, $case) = @_;
    return "$main::FindBin::Bin/testdata/intf_collect_golden/$case.json";
}

sub assert_golden {
    my ($self, $case, $captured, $final) = @_;
    my $payload = { captured => $self->normalise($captured),
                    final    => _strip(clone($final)) };
    my $path = $self->golden_path($case);
    if ($ENV{RECORD_GOLDEN}) {
        make_path("$main::FindBin::Bin/testdata/intf_collect_golden");
        open my $fh, ">", $path or die "cannot write golden $path: $!";
        print $fh JSON::XS->new->canonical(1)->pretty(1)->encode($payload);
        close $fh;
        pass("recorded golden for $case");
        return;
    }
    open my $fh, "<", $path or do { fail("golden missing for $case: $path"); return; };
    local $/; my $want = JSON::XS->new->decode(<$fh>); close $fh;
    is_deeply($payload, $want, "golden matches for $case");
}
1;
```

- [ ] **Step 4: Run the self-test to verify it passes**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_harness_selftest.pl`
Expected: PASS (3 assertions).

- [ ] **Step 5: Commit**

```bash
git add test/lib/IntfTestHarness.pm test/t_intf_harness_selftest.pl
git commit -m "OMK-12375. Add IntfTestHarness: DB/RRD/event capture + golden compare for interface-collect tests."
```

---

### Task A2: Synthetic interface-walk generator

**Files:**
- Modify: `test/lib/IntfTestHarness.pm`
- Test: `test/t_intf_harness_selftest.pl` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `IntfTestHarness::generate_interface_walk(count => N, admin => {idx=>1|2}, oper => {idx=>1|2})` returns a hashref keyed by numeric OID, with, per index i in 1..N: ifIndex `1.3.6.1.2.1.2.2.1.1.i`, ifDescr `.2.i`, ifType `.3.i` (6), ifSpeed `.5.i`, ifPhysAddress `.6.i`, ifAdminStatus `.7.i`, ifOperStatus `.8.i`, plus ifNumber `1.3.6.1.2.1.2.1.0 = N`. Admin/oper overrides default to 1 (up).

- [ ] **Step 1: Write the failing test (append to self-test)**

```perl
my $walk = IntfTestHarness::generate_interface_walk(count => 3, admin => {2 => 2});
is($walk->{'1.3.6.1.2.1.2.1.0'}, 3, "ifNumber = count");
is($walk->{'1.3.6.1.2.1.2.2.1.1.2'}, 2, "ifIndex 2 present");
is($walk->{'1.3.6.1.2.1.2.2.1.7.2'}, 2, "admin override applied to idx 2");
is($walk->{'1.3.6.1.2.1.2.2.1.7.1'}, 1, "admin default up for idx 1");
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_harness_selftest.pl`
Expected: FAIL, `Undefined subroutine &IntfTestHarness::generate_interface_walk`.

- [ ] **Step 3: Implement the generator**

```perl
sub generate_interface_walk {
    my (%a) = @_;
    my $n = $a{count} // 5;
    my %w = ('1.3.6.1.2.1.2.1.0' => $n);
    for my $i (1 .. $n) {
        $w{"1.3.6.1.2.1.2.2.1.1.$i"} = $i;
        $w{"1.3.6.1.2.1.2.2.1.2.$i"} = "GigabitEthernet0/$i";
        $w{"1.3.6.1.2.1.2.2.1.3.$i"} = 6;
        $w{"1.3.6.1.2.1.2.2.1.5.$i"} = 1000000000;
        $w{"1.3.6.1.2.1.2.2.1.6.$i"} = sprintf("00 11 22 %02x %02x %02x", ($i>>16)&255, ($i>>8)&255, $i&255);
        $w{"1.3.6.1.2.1.2.2.1.7.$i"} = ($a{admin} && defined $a{admin}{$i}) ? $a{admin}{$i} : 1;
        $w{"1.3.6.1.2.1.2.2.1.8.$i"} = ($a{oper}  && defined $a{oper}{$i})  ? $a{oper}{$i}  : 1;
    }
    return \%w;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_harness_selftest.pl`
Expected: PASS (7 assertions total).

- [ ] **Step 5: Commit**

```bash
git add test/lib/IntfTestHarness.pm test/t_intf_harness_selftest.pl
git commit -m "OMK-12375. Add synthetic interface-walk generator to IntfTestHarness."
```

---

### Task A3: Coverage-suite scaffold + case-runner + first case (steady state), record goldens

**Files:**
- Create: `test/t_intf_collect.pl`
- Create: `test/testdata/intf_collect_golden/` (via RECORD_GOLDEN)

**Interfaces:**
- Consumes: `IntfTestHarness` (A1), `generate_interface_walk` (A2).
- Produces: a `run_case(\%spec)` local sub that: builds a temp-DB node, seeds starting inventory from `$spec->{seed}`, sets the mock walk from `$spec->{walk}`, runs `collect_intf_data` (and `update` first if `$spec->{do_update}`), captures, and calls `$h->assert_golden($spec->{name}, ...)`.

The case spec shape (used by all later cases):
```perl
# { name => 'steady_state',
#   seed => [ { index=>1, ifDescr=>'GigabitEthernet0/1', ifAdminStatus=>'up',
#               ifOperStatus=>'up', collect=>'true', historic=>0, enabled=>1 }, ... ],
#   walk => { count=>2 },                 # passed to generate_interface_walk
#   do_update => 0 }
```

- [ ] **Step 1: Write the scaffold and the steady-state case**

```perl
#!/usr/bin/perl
# t_intf_collect.pl - branch coverage + golden baseline for collect_intf_data/update_intf_info
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use Clone qw(clone);
use NMISNG; use NMISNG::Sys; use NMISNG::Util; use NMISNG::Log;
use NMISNG::Snmp::Mock;
use IntfTestHarness;

my $C = NMISNG::Util::loadConfTable(dir => "/usr/local/nmis9/conf");
$C->{db_name} = "t_intf_collect-$$";
my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = NMISNG->new(config => $C, log => $logger);
my $h = IntfTestHarness->new(nmisng => $nmisng, rrd_dir => "/tmp/t_intf_rrd_$$");
$h->install_capture();

my $node_seq = 0;
sub make_node {
    my $uuid = sprintf("c0ffee00-0000-0000-0000-%012d", ++$node_seq);
    my $n = $nmisng->node(uuid => $uuid, create => 1);
    $n->cluster_id($C->{cluster_id}); $n->name("intftest$node_seq");
    $n->configuration({ host => "127.0.0.1", group => "NMIS9", active => 1, collect => 1, model => "Generic" });
    $n->save(); return $n;
}

sub seed_interface {
    my ($node, $rec) = @_;
    my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>$rec->{ifDescr}}, path_keys=>["ifDescr"], partial=>0);
    my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"],
                                 model_class=>"interface", create=>1);
    $inv->data($rec);
    $inv->data_info(subconcept=>"interface", enabled=>1);
    $inv->historic($rec->{historic} // 0);
    $inv->enabled($rec->{enabled} // 1);
    $inv->save(node=>$node);
    return $inv;
}

sub run_case {
    my ($spec) = @_;
    my $node = make_node();
    seed_interface($node, $_) for @{$spec->{seed} // []};

    my ($catchall) = $node->inventory(concept=>"catchall", model_class=>"system", create=>1);
    $catchall->data_live->{ifNumber} = $spec->{walk}{count} // scalar @{$spec->{seed}//[]};
    $catchall->save(node=>$node);

    my $S = NMISNG::Sys->new(nmisng=>$nmisng);
    $S->init(node=>$node, snmp=>1, wmi=>0,
             update => ($spec->{do_update}?'true':0), force=>($spec->{do_update}?1:0),
             catchall_inventory=>$catchall);
    $S->{snmp} = NMISNG::Snmp::Mock->new(nmisng=>$nmisng, name=>$node->name,
             walk_data => IntfTestHarness::generate_interface_walk(%{$spec->{walk}}));
    $S->{snmp}{session} = 1; # mock guard expects a session

    $h->reset_capture();
    $node->collect_intf_data(sys=>$S, catchall_inventory=>$catchall);

    # final state: all interface inventory docs for this node
    my $final = $nmisng->get_inventory_model(cluster_id=>$node->cluster_id,
                  node_uuid=>$node->uuid, concept=>"interface")->data;
    $h->assert_golden($spec->{name}, $h->captured(), $final);
}

run_case({ name => "steady_state",
           seed => [ { index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1",
                       ifAdminStatus=>"up", ifOperStatus=>"up", collect=>"true",
                       real=>"true", historic=>0, enabled=>1 } ],
           walk => { count => 1 } });

$nmisng->get_db()->drop();
done_testing;
```

- [ ] **Step 2: Run in compare mode to confirm it fails (no golden yet)**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: FAIL, "golden missing for steady_state".

- [ ] **Step 3: Record the golden on current code**

Run: `docker exec -e RECORD_GOLDEN=1 omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS ("recorded golden for steady_state"); file created.

- [ ] **Step 4: Re-run in compare mode**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS ("golden matches for steady_state").

- [ ] **Step 5: Commit**

```bash
git add test/t_intf_collect.pl test/testdata/intf_collect_golden/steady_state.json
git commit -m "OMK-12375. Add interface-collect coverage suite scaffold + steady-state golden."
```

---

### Task A4: Add the remaining 12 coverage cases (data-driven), record goldens

**Files:**
- Modify: `test/t_intf_collect.pl`
- Create: `test/testdata/intf_collect_golden/*.json` (one per case)

**Interfaces:**
- Consumes: `run_case` (A3).

Each case is one `run_case({...})` entry. The case table (add all twelve before the `done_testing`):

```perl
# 2. new interface present in walk but not seeded -> needs_update -> created
run_case({ name=>"new_interface", seed=>[], walk=>{count=>2}, do_update=>1 });

# 3. ifIndex change: seeded ifDescr e0/1 at index 1, walk moves it to index 5
run_case({ name=>"ifindex_change",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1, _reindex=>{1=>5}}, do_update=>1 });   # generator extension below

# 4. ifDescr change: seeded index1 ifDescr old, walk reports new descr
run_case({ name=>"ifdescr_change",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"OldName0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1}, do_update=>1 });

# 5. interface removed: seeded index2 not present in walk (count=1) -> historic
run_case({ name=>"interface_removed",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1},
         {index=>2, ifIndex=>2, ifDescr=>"GigabitEthernet0/2", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1} });

# 6. disabled interface: seeded enabled=0 -> not collected, not historic
run_case({ name=>"disabled_interface",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"false", historic=>0, enabled=>0}],
  walk=>{count=>1} });

# 7a. historic interface, attempt flag off (default): stays skipped
run_case({ name=>"historic_skip",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>1, enabled=>1}],
  walk=>{count=>1} });

# 8. clashing ifIndex: two seeded inventories with same ifIndex
run_case({ name=>"clashing_ifindex",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"A0/1", ifAdminStatus=>"up", ifOperStatus=>"up",
          collect=>"true", historic=>0, enabled=>1},
         {index=>1, ifIndex=>1, ifDescr=>"B0/1", ifAdminStatus=>"up", ifOperStatus=>"up",
          collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1} });

# 9. admin status transition up->down triggers update
run_case({ name=>"admin_transition",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1, admin=>{1=>2}}, do_update=>1 });

# 10. ifLastChange-based detection: requires model custom flag; see note in Step 1
run_case({ name=>"iflastchange_detect",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1, ifLastChangeSec=>0}],
  walk=>{count=>1}, custom_iflastchange=>1, do_update=>1 });

# 11. non-snmp node: snmp disabled -> early return, no writes
run_case({ name=>"non_snmp", seed=>[], walk=>{count=>1}, no_snmp=>1 });

# 12. bulk_save off (force per-interface save path)
run_case({ name=>"bulk_save_off",
  seed=>[{index=>1, ifIndex=>1, ifDescr=>"GigabitEthernet0/1", ifAdminStatus=>"up",
          ifOperStatus=>"up", collect=>"true", historic=>0, enabled=>1}],
  walk=>{count=>1}, bulk_save=>0 });

# 13. over-100 interfaces: exercises field cutback path
run_case({ name=>"over_cutback", seed=>[], walk=>{count=>150}, do_update=>1 });
```

- [ ] **Step 1: Extend `run_case` and the generator to honour the new spec keys**

In `generate_interface_walk`, support `_reindex` (map old index to new ifIndex value for the same ifDescr): after building, for each `($from,$to)` move the per-index OIDs from `.$from` to `.$to` and set the ifIndex value to `$to`.

In `run_case`, before init: if `$spec->{no_snmp}` set `$S->{snmp}{session}=0` and expect early return; if `$spec->{custom_iflastchange}` set `$S->{mdl}{custom}{interface}{ifLastChange}='true'`; if `$spec->{bulk_save}` is defined to 0, set `$C->{disable_bulk_inventory_save}=1` (confirm the exact knob during execution by reading `collect_intf_data` around the `BULK_TIMED_DATA` constant and `bulk_save` use at `Node.pm:4329-4514`; if there is no config knob, drive it by temporarily localising `*NMISNG::Node::BULK_TIMED_DATA`).

```perl
# add near top of run_case, after $S->init and mock injection:
$S->{snmp}{session} = 0 if $spec->{no_snmp};
$S->{mdl}{custom}{interface}{ifLastChange} = 'true' if $spec->{custom_iflastchange};
```

- [ ] **Step 2: Run in compare mode to confirm new cases fail (no goldens yet)**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: FAIL with "golden missing" for the new cases.

- [ ] **Step 3: Record goldens on current code, then verify compare passes**

Run: `docker exec -e RECORD_GOLDEN=1 omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Then: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: second run PASS for all 13 cases. Inspect each golden file briefly to confirm the write-stream looks sane (e.g. `interface_removed` shows a historic-marking update; `new_interface` shows an insert/upsert).

- [ ] **Step 4: Sanity-check the find count is what we expect to reduce**

Add to `run_case` (guarded by `$ENV{SHOW_DBSTATS}`): `NMISNG::DB::reset_db_stats()` before `collect_intf_data` and print `NMISNG::DB::get_db_stats()->{counts}{find}` after.
Run: `docker exec -e SHOW_DBSTATS=1 omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl 2>&1 | grep find`
Expected: `over_cutback` shows a find count scaling with interface count (the N+ pattern we will cut).

- [ ] **Step 5: Commit**

```bash
git add test/t_intf_collect.pl test/testdata/intf_collect_golden/
git commit -m "OMK-12375. Add 12 interface-collect coverage cases with golden baselines on current code."
```

---

## Deliverable B: phase-8 reuse (gated behind Deliverable A goldens)

### Task B1: Phase 1 loads full fields and builds reusable objects (no extra queries)

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`~3888-3957`)

**Interfaces:**
- Consumes: golden suite from A4.
- Produces: `%if_inventory_map` populated with fully-populated `NMISNG::Inventory` objects keyed by ifIndex, built from the single phase-1 result with no additional DB queries.

**Critical constraint:** phase 1 must issue exactly one interface `find` (the existing `get_inventory_model`). Do NOT add any per-interface `inventory(_id=>…)` or `get_inventory_model` call here — that would reintroduce the N-query pattern this whole change exists to remove, and it would survive B3. Objects must be built from the already-fetched phase-1 data.

- [ ] **Step 1: Confirm the golden baseline is green before changing code**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all 13.

- [ ] **Step 2: Replace the restricted field load with a full load**

Replace the `$which_fields` ternary block (`Node.pm:3888-3916`) so the query loads full records:

```perl
	# Load full interface records once: phase 8 reuses these objects instead of
	# reloading each interface by _id (OMK-12375). The previous field cutback only
	# trimmed this phase-1 read, which did not prevent the per-interface reloads.
	my $result = $self->get_inventory_model('concept' => 'interface');
```

(Delete the `$ifNumber`/`$max_interfaces_before_cutback`/`$which_fields` lines that fed the old call.)

- [ ] **Step 3: Keep the in-loop object build, now fed full fields (no extra query)**

The existing manual build at `Node.pm:3952-3956` already constructs the object from the in-hand row `$maybeevil` with no DB call:

```perl
		my $class = NMISNG::Inventory::get_inventory_class( "interface" );
		Module::Load::load $class;
		$maybeevil->{nmisng} = $self->nmisng;
		my $no_save_inventory = $class->new(%$maybeevil); # this doesn't report errors!
		$if_inventory_map{$thisindex} = $no_save_inventory;
```

With Step 2 removing the field restriction, `$maybeevil` is now the full record, so this build already yields a fully-populated object. Leave this block as-is (it is query-free and is exactly what phase 8 will reuse). The job of proving this reused object behaves identically to the old fresh `inventory(_id=>…)` reload belongs to the golden gate in B3, not to inspection here.

Contingency (only if the B3 golden gate shows a diff on an interface that did NOT go through `update_intf_info`, i.e. an instantiation-path difference): replace the `$class->new(%$maybeevil)` line with a query-free instantiation through `ModelData`, reading the standard-load object out of the same already-fetched result, e.g. capture `$result->objects` once after the loop and map its objects by `data->{ifIndex}` with first-wins semantics matching the clash handling. Still no per-interface DB query. Record which path was used in the task report.

- [ ] **Step 4: Run the golden suite**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all 13 (no behaviour change yet, only how phase-1 objects are built).

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm
git commit -m "OMK-12375. collect_intf_data phase 1: load full interface records, build reusable object map (no extra query)."
```

---

### Task B2: Phases 4/7 refresh the object map for updated interfaces

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`~4091`, and the second update loop near `~4291`)

**Interfaces:**
- Consumes: `%if_inventory_map` (B1), `$maybenew` from `update_intf_info`.
- Produces: `if_inventory_map{$index}` refreshed to the post-update object for every `_was_updated` interface.

- [ ] **Step 1: Refresh the map right after each `update_intf_info` call**

After the `if_data_map` update block that follows `my $maybenew = $self->update_intf_info(...)` (phase 4 at `Node.pm:4091`, and again in the phase-7 loop), add:

```perl
			# keep the reusable object map in step with the updated inventory so
			# phase 8 reuses the post-update object (recomputed tags + correct _id),
			# matching the old reload-by-id behaviour (OMK-12375).
			$if_inventory_map{$needsmust} = $maybenew if (ref($maybenew));
```

Place this inside the `if (!defined $thisif->{_id} or $maybenew->id ne ...)` / `else` handling so it runs for both the new-inventory and updated-in-place branches, after `if_data_map` is set.

- [ ] **Step 2: Run the golden suite**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all 13 (still reloading in phase 8, so behaviour unchanged; this only primes the map).

- [ ] **Step 3: Commit**

```bash
git add lib/NMISNG/Node.pm
git commit -m "OMK-12375. collect_intf_data phases 4/7: refresh interface object map after update_intf_info."
```

---

### Task B3: Phase 8 reuses the object map instead of reloading

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`~4340-4341`)

**Interfaces:**
- Consumes: `%if_inventory_map` (B1+B2).
- Produces: phase 8 with zero per-interface `find` calls.

- [ ] **Step 1: Replace the per-interface reload with a map reuse + fallback**

Replace `Node.pm:4340-4346`:

```perl
		# OLD:
		# my ($inventory, $error_message) = $self->inventory( _id => $thisif->{_id} );
		# if (!$inventory) { ...error; next; }
```

with:

```perl
		# reuse the object loaded in phase 1 / refreshed in phases 4-7 instead of
		# reloading each interface from the db (OMK-12375). fall back to a load only
		# if the map is unexpectedly missing this index, and log it so gaps are visible.
		my $inventory = $if_inventory_map{$index};
		if (!$inventory)
		{
			my $error_message;
			($inventory, $error_message) = $self->inventory( _id => $thisif->{_id} );
			$self->nmisng->log->warn("collect_intf_data phase 8: object map miss for index $index, fell back to reload"
				. ($error_message ? ": $error_message" : ""));
			if (!$inventory)
			{
				$self->nmisng->log->error("Failed to get interface inventory, _id: $thisif->{_id}: $error_message");
				next;
			}
		}
```

- [ ] **Step 2: Run the golden suite (the gate)**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all 13 with empty diffs. If any case diffs, the reuse changed behaviour; stop and investigate (most likely a `_was_updated` interface whose object was not refreshed, or a volatile field not normalised).

- [ ] **Step 3: Prove the find-count reduction**

Run: `docker exec -e SHOW_DBSTATS=1 omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl 2>&1 | grep find`
Expected: `over_cutback` interface `find` count drops from the N+ baseline (Task A4 Step 4) to a small constant.

- [ ] **Step 4: Run the broader regression suite**

Run:
```bash
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_polling.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_nmisng_node.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_nmisng_inventory.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_model_data.pl
```
Expected: PASS (or the same pre-existing skips/failures as on a clean `origin/nmis9_dev` checkout; confirm by comparing against baseline if any fail).

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm
git commit -m "OMK-12375. collect_intf_data phase 8: reuse loaded interface objects, eliminating per-interface reloads."
```

---

## Self-Review

**Spec coverage:**
- Write-stream capture (spec 1): Task A1 (DB/RRD/event patches, normalise).
- Harness architecture + walk generator (spec 2): A1, A2; `t_polling` refactor to share the helper is optional cleanup and intentionally not forced here to limit blast radius (note this deviation to the user).
- Coverage suite, all 13 cases (spec 3): A3 (case 1), A4 (cases 2-13).
- Phase-8 reuse mechanism + risk handling (spec 4): B1 (full load + query-free reusable object map), B2 (refresh `_was_updated`), B3 (reuse + fallback).
- Error handling (spec 5): B3 fallback + warning; existing error paths untouched.
- Success criteria: B3 Step 2 (empty diffs) and Step 3 (find-count drop).

**Deviation flagged:** the spec mentions refactoring `t_polling.pl` to use the shared helper. This plan builds the helper standalone and leaves `t_polling.pl` untouched to keep Deliverable A low-risk. Folding `t_polling` onto the helper can be a later cleanup. Raise with the user before execution if they want it in-scope.

**Placeholder scan:** the `bulk_save` knob in A4 Step 1 is specified as "confirm exact mechanism by reading `Node.pm:4329-4514` during execution" because the current code uses a `BULK_TIMED_DATA` constant; the executor must read those lines to pick the config knob vs localising the constant. This is a genuine read-then-decide, not a content placeholder. All code steps include real code.

**Type consistency:** `generate_interface_walk` keys, `run_case` spec keys, `assert_golden`/`normalise`/`captured` signatures are used consistently across A1-A4 and referenced (not redefined) in B. `%if_inventory_map` keyed by ifIndex is consistent across B1/B2/B3.
