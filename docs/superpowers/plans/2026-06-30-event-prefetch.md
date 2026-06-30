# Event prefetch (OMK-12677) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce per-cycle `events`-collection reads during collect/update by prefetching a node's events once and serving the existence/state checks from memory — but only ship it if a feasibility spike proves it cuts load, preserves event correctness exactly, and stays a small contained change.

**Architecture:** Mirror the latest_data per-node prefetch (OMK-12668). A per-node in-memory buffer on the `NMISNG` object, populated by one `get_events_model(node_uuid, historic => 0)` at cycle start, served for `eventExist`/`checkEvent` reads, write-through on `eventAdd`/`eventDelete`/`eventUpdate` (including the delete case), `NMISNG::Guard` teardown, and a `getbool` kill switch. The work is phased: Phase 1 is a feasibility spike ending in a hard go/no-go gate; Phase 2 productionizes only if the gate passes.

**Tech Stack:** Perl 5, NMISNG (`NMISNG`, `NMISNG::Events`, `NMISNG::Node`, `Compat::NMIS`, `NMISNG::DB`, `NMISNG::Guard`), MongoDB, Test::More, the dev docker stack.

## Global Constraints

- Branch `OMK-12677-event-prefetch` is already created from `origin/nmis9_dev` (base `158e2c34`), worktree at `/home/md/work/nmis9-event-prefetch`.
- The kill switch is `event_prefetch_enabled`, read with `NMISNG::Util::getbool`. It defaults **OFF** for the whole spike (Phase 1) so the prototype cannot affect anything until proven; the final Phase 2 task flips the default to ON.
- Additive and behaviour-preserving with the switch off: counts and behaviour must be identical to today when `event_prefetch_enabled` is false.
- Write-through updates the buffer only **after** the underlying DB write reports success (the lesson from the OMK-12668 review).
- The four go/no-go gate criteria (the spike must satisfy all to proceed): (1) measured load reduction on `realnode188` and a synthetic node; (2) byte-identical event-write-stream with the buffer on vs off across collect and update, including in-cycle raise→read and clear→read; (3) a complete external-mutation inventory + state-transition matrix + lock analysis, with any residual window documented and accepted; (4) contained change — reuses the OMK-12668 Guard/kill-switch pattern, no new locking primitives, reviewable in one sitting.
- If NMISNG.pm already carries the OMK-12668 `pit_prefetch_*` primitives (if that PR merged to nmis9_dev), place these event primitives alongside them and match their conventions. The code below is written to stand alone if it has not merged.
- Tests run in the dev container: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && perl test/<file>'`.
- Commit messages use the `OMK-12677.` prefix.

---

## PHASE 1 — FEASIBILITY SPIKE (ends at the gate, Task 8)

### Task 0: Environment

**Files:** none (setup only).

- [ ] **Step 1: Confirm the worktree and a test container.**

The worktree exists at `/home/md/work/nmis9-event-prefetch` on `OMK-12677-event-prefetch`. Stand up a dev container that mounts THIS worktree at `/usr/local/nmis9`, on the same docker network as a MongoDB, with a fresh `db_name` (do not reuse another branch's db). Clone the configuration of an existing dev container (image, network, `NMIS_DB_*` env) but change the `-v` mount to this worktree. Confirm:

Run: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && perl -e "use NMISNG; print qq{ok\n}"'`
Expected: `ok`.

- [ ] **Step 2: Commit nothing.** This task produces no repo changes.

---

### Task 1: External-mutation audit and lock matrix (the linchpin — do this first)

**Files:**
- Create: `docs/superpowers/specs/2026-06-30-event-prefetch-audit.md`

**Interfaces:**
- Produces: the complete list of event-mutation sites outside collect/update, the filled state-transition matrix, the per-writer lock finding, and the **exemption list** (event names/classes that must be served live). Tasks 5 and 9 consume the exemption list.

- [ ] **Step 1: Enumerate every event-mutation call site.**

Run, and read each hit:
```bash
grep -rnE 'eventAdd|eventDelete|eventUpdate|cleanNodeEvents|eventsClean|->event\(|Compat::NMIS::(checkEvent|notify)|events_collection' \
  lib bin cgi-bin htdocs admin install 2>/dev/null
```
For each call site, record: the file:line, which process runs it (collect/update worker, the nmisd daemon, `process_escalations`, the GUI, an admin tool), and what it changes (raise, clear, ack, escalate-update, node-wide purge).

- [ ] **Step 2: Resolve the node-wide purge.**

Read `Node.pm:862` (`eventsClean`), `Events.pm:71` (`cleanNodeEvents`), the direct remove at `Node.pm:759`, and the two `eventsClean` call sites `Node.pm:748` and `Node.pm:1549`. Record exactly which operations trigger a purge and whether they run inside or outside a held node lock.

- [ ] **Step 3: Determine lock-holding per external writer.**

The collect/update node lock is a `flock LOCK_EX` on `<nmis_var>/<node>.lock` (`Node.pm:9304`+; `lock(type => ...)` at `Node.pm:7198`, and the `1697` "collect lock?" comment). For each writer found in Step 1 that runs OUTSIDE collect/update, determine whether it takes that same lock before mutating events. A writer that takes the lock cannot overlap a buffered cycle.

- [ ] **Step 4: Fill the matrix and name the exemptions.**

In `docs/superpowers/specs/2026-06-30-event-prefetch-audit.md`, fill this matrix from the findings (one row per real external writer):

```
| External writer (file:line, process) | change made | buffer state at change time | effect if collect reads stale | lock serialises it? | exempt? |
```

Effect column uses the documented outcomes: correct / duplicate-notification / missed-notification / dup-key-rejected-raise / one-cycle-stale-then-self-corrects. Conclude with the **exemption list**: the event names or classes that must be read live (not buffered) because a non-lock-holding external writer can change them mid-cycle with a real alert-flipping effect. If the list is empty (all external writers hold the lock), say so explicitly.

- [ ] **Step 5: Commit.**
```bash
git add docs/superpowers/specs/2026-06-30-event-prefetch-audit.md
git commit -m "OMK-12677. Spike: external event-mutation audit + lock matrix + exemption list"
```

---

### Task 2: Baseline load measurement

**Files:**
- Create: `test/t_event_prefetch_realnode.pl`

**Interfaces:**
- Produces: the baseline `events`-find count per collect and update on `realnode188` (expected ~52 for collect), recorded in the audit doc.

- [ ] **Step 1: Recreate `realnode188`.** Add the node (node_admin create with `host => 172.20.0.1`, `port => 1161`, `community` per the dev secret, `model => automatic`), run a dev-tools `act=update` (so it picks the net-snmp model), then `act=collect` to reach steady state.

- [ ] **Step 2: Write the measurement script.**

`test/t_event_prefetch_realnode.pl`:
```perl
#!/usr/bin/perl
# Count events-collection finds during a real collect, attributing by caller.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use NMISNG; use NMISNG::Util; use NMISNG::Log; use Compat::NMIS;
my $C = NMISNG::Util::loadConfTable();
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
my $TOTAL=0; my $ON=0; my $orig=\&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub { my %a=@_;
    my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}";
    $TOTAL++ if ($ON && $n =~ /(?:^|\.)events$/); return $orig->(@_); }; }
my $node = $nmisng->node(name => $ARGV[0] // "realnode188") or die "node not found\n";
$ON=1; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); $ON=0;
print "events-collection finds during collect: $TOTAL\n";
```

- [ ] **Step 3: Run it (buffer off — this is the baseline).**
Run: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && perl test/t_event_prefetch_realnode.pl 2>&1 | tail -1'`
Expected: a number around 52. Record it in the audit doc as the baseline.

- [ ] **Step 4: Commit.**
```bash
git add test/t_event_prefetch_realnode.pl
git commit -m "OMK-12677. Spike: real-node events-find baseline measurement"
```

---

### Task 3: Event buffer primitives + unit tests

**Files:**
- Modify: `lib/NMISNG.pm` (add buffer field to `new`, `use NMISNG::Guard`, add the four primitives)
- Create: `test/t_event_prefetch.pl`

**Interfaces:**
- Produces:
  - `$nmisng->event_prefetch_begin(node_uuid => $u)` → `NMISNG::Guard` or `undef` (undef when disabled or no uuid).
  - `$nmisng->event_prefetch_active($node_uuid)` → 1 if a buffer is loaded for the node, else 0.
  - `$nmisng->event_prefetch_lookup($node_uuid, $event, $element)` → the buffered event row hashref, or `undef` on a miss.
  - `$nmisng->event_prefetch_store($node_uuid, $event, $element, $row_or_undef)` → store a raised/updated row, or remove it when `$row_or_undef` is `undef` (the clear case). No-op when no buffer is active.

- [ ] **Step 1: Write the failing unit tests.**

`test/t_event_prefetch.pl`:
```perl
#!/usr/bin/perl
# Tests for the per-node event prefetch buffer (OMK-12677).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;
my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_evtpf-$$";
$C->{event_prefetch_enabled} = 1;   # tests opt in explicitly
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
my $U = "11111111-2222-3333-4444-555555555555";

# no buffer active -> lookup undef, store is a no-op, not active
is($nmisng->event_prefetch_active($U), 0, "no buffer -> not active");
is($nmisng->event_prefetch_lookup($U,"Node Down",""), undef, "no buffer -> lookup undef");
$nmisng->event_prefetch_store($U,"Node Down","",{event=>"Node Down",active=>1});  # no-op
is($nmisng->event_prefetch_active($U), 0, "store without buffer stays inactive");

# open a buffer manually and exercise store/lookup/delete
$nmisng->{_event_prefetch}{$U} = {};
$nmisng->event_prefetch_store($U,"Interface Down","eth0",{event=>"Interface Down",element=>"eth0",active=>1,historic=>0});
my $r = $nmisng->event_prefetch_lookup($U,"Interface Down","eth0");
is($r->{active}, 1, "stored row is found and active");
is($nmisng->event_prefetch_lookup($U,"Interface Down","eth9"), undef, "miss -> undef");
$nmisng->event_prefetch_store($U,"Interface Down","eth0",undef);   # clear/delete
is($nmisng->event_prefetch_lookup($U,"Interface Down","eth0"), undef, "store(undef) removes the row");
delete $nmisng->{_event_prefetch}{$U};

# begin loads current events in one find and returns a guard that tears down
NMISNG::DB::insert(collection => $nmisng->events->events_collection // $nmisng->get_collection(name=>"events"),
  record => { node_uuid=>$U, event=>"Node Down", element=>"", active=>1, historic=>0, cluster_id=>$C->{cluster_id} });
{
  my $g = $nmisng->event_prefetch_begin(node_uuid => $U);
  isa_ok($g, "NMISNG::Guard", "begin returns a guard");
  is($nmisng->event_prefetch_active($U), 1, "buffer active after begin");
  my $nd = $nmisng->event_prefetch_lookup($U,"Node Down","");
  is(($nd && $nd->{active}), 1, "begin loaded the seeded active event");
}
is($nmisng->event_prefetch_active($U), 0, "guard teardown cleared the buffer");

# kill switch parsed as NMIS boolean
for my $off (0,"0","false","no","") { $nmisng->config->{event_prefetch_enabled}=$off;
  is($nmisng->event_prefetch_begin(node_uuid=>$U), undef, "disabled when flag='$off'"); }
$nmisng->config->{event_prefetch_enabled}=1;
$nmisng->get_db()->drop();
done_testing;
```
(If `events_collection` is not directly exposed, use the accessor the codebase uses — confirm via `grep -n 'events_collection\|sub events' lib/NMISNG.pm lib/NMISNG/Events.pm`.)

- [ ] **Step 2: Run it, watch it fail.**
Run: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && perl test/t_event_prefetch.pl'`
Expected: FAIL (`event_prefetch_active`/`begin`/etc. not defined).

- [ ] **Step 3: Implement the primitives in `lib/NMISNG.pm`.**

Add `_event_prefetch => {}` to the hash built in `new`, add `use NMISNG::Guard;` near the other use lines if absent, and add:
```perl
sub _event_key { my ($event,$element)=@_; return ($event // '')."\x00".($element // ''); }

sub event_prefetch_begin {
    my ($self, %args) = @_;
    my $node_uuid = $args{node_uuid};
    return undef if (!$node_uuid);
    return undef if (!NMISNG::Util::getbool($self->config->{event_prefetch_enabled} // 0));  # default OFF in the spike
    my $md = $self->events->get_events_model(filter => { node_uuid => $node_uuid, historic => 0 });
    my %bykey;
    if (!$md->error) {
        for my $row (@{ $md->data() // [] }) {
            $bykey{ _event_key($row->{event}, $row->{element}) } = $row;
        }
    }
    $self->{_event_prefetch}{$node_uuid} = \%bykey;
    return NMISNG::Guard->new(sub { delete $self->{_event_prefetch}{$node_uuid}; });
}

sub event_prefetch_active { my ($self,$u)=@_; return (exists $self->{_event_prefetch}{$u}) ? 1 : 0; }

sub event_prefetch_lookup {
    my ($self,$u,$event,$element)=@_;
    my $buf = $self->{_event_prefetch}{$u};
    return undef if (!$buf);
    return $buf->{ _event_key($event,$element) };
}

sub event_prefetch_store {
    my ($self,$u,$event,$element,$row)=@_;
    my $buf = $self->{_event_prefetch}{$u};
    return if (!$buf);
    my $k = _event_key($event,$element);
    if (defined $row) { $buf->{$k} = $row; } else { delete $buf->{$k}; }
}
```

- [ ] **Step 4: Run it, all green.** Same command. Expected: all assertions PASS.

- [ ] **Step 5: Commit.**
```bash
git add lib/NMISNG.pm test/t_event_prefetch.pl
git commit -m "OMK-12677. Spike: per-node event prefetch buffer primitives + unit tests"
```

---

### Task 4: Trigger the buffer in collect/update (behind the flag)

**Files:**
- Modify: `lib/NMISNG/Node.pm` (the `collect` and `update` methods — add the lexical guard near the existing lock acquisition, the same site as the OMK-12668 latest_data trigger)

**Interfaces:**
- Consumes: `event_prefetch_begin` (Task 3).
- Produces: an active event buffer for the node during a real collect/update, freed on return and on exception.

- [ ] **Step 1: Add the trigger.** In `collect` and in `update`, immediately after the node lock is acquired, add:
```perl
    my $event_prefetch_guard = $self->nmisng->event_prefetch_begin(node_uuid => $self->uuid);
```
Keep it a top-level lexical in the method so it lives for the whole cycle and DESTROY runs on normal return and on die. Locate the site with `grep -nE 'lock\(type => |my \$lock' lib/NMISNG/Node.pm`.

- [ ] **Step 2: Verify a real collect still succeeds with the flag on.**
Run: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && NMIS_EVENT_PREFETCH_ENABLED=1 perl test/t_event_prefetch_realnode.pl 2>&1 | tail -1'`
Expected: still completes (the buffer is populated but not yet serving reads, so the count is unchanged for now plus one batch find). No crash.

- [ ] **Step 3: Commit.**
```bash
git add lib/NMISNG/Node.pm
git commit -m "OMK-12677. Spike: trigger event prefetch buffer in collect/update with guard teardown"
```

---

### Task 5: Serve reads from the buffer + write-through, with the golden gate

**Files:**
- Modify: `lib/NMISNG/Events.pm` (`eventExist` reads from buffer; `eventAdd`/`eventDelete`/`eventUpdate` write through after the DB write succeeds)
- Modify: `lib/Compat/NMIS.pm` (`checkEvent` reads from buffer; its conditional clear writes through)
- Modify: `test/t_event_prefetch.pl` (add the golden + in-cycle tests)
- Consumes: the exemption list from Task 1.

- [ ] **Step 1: Write the failing golden + in-cycle tests.** Append to `test/t_event_prefetch.pl` a block that, for a Generic-model node with a couple of interfaces, runs the event-bearing collect path with the buffer OFF capturing every `eventAdd`/`eventDelete`/`eventUpdate` call and args, then again with the buffer ON, and asserts the two capture lists are identical. Add explicit cases: raise an event then `eventExist` it in the same cycle returns true (raise→read); clear an event then `eventExist` returns false (clear→read). Use the same `NMISNG::DB` monkey-patch capture style as `t_event_prefetch_realnode.pl`, but capture the event-write API instead. (Full capture harness code: model it on the OMK-12668 golden write-stream test if present, else capture by wrapping `NMISNG::Events::eventAdd`/`eventDelete`/`eventUpdate`.)

- [ ] **Step 2: Run, watch the in-cycle cases fail** (reads still hit the DB, write-through absent so raise→read/clear→read see stale buffer or bypass it). Record which fail.

- [ ] **Step 3: Implement read-serving in `eventExist`.** In `NMISNG::Events::eventExist`, when the node is NOT in the exemption list and a buffer is active, answer from the buffer with no DB hit:
```perl
    my $u = ref($node) ? $node->uuid : $node;
    if (!_event_exempt($event) && $self->nmisng->event_prefetch_active($u)) {
        my $row = $self->nmisng->event_prefetch_lookup($u, $event, $element);
        return ($row && $row->{active} && (($row->{historic}//0) <= 0)) ? 1 : 0;
    }
    # else existing live path
```
Add a small `_event_exempt($event)` helper that returns true for the exemption list from Task 1 (hard-code the audited list; if empty, the helper always returns false).

- [ ] **Step 4: Implement write-through** in `eventAdd`/`eventDelete`/`eventUpdate` (and the clear inside `Compat::NMIS::checkEvent`): after the existing DB write returns success, call `event_prefetch_store($u,$event,$element,$row)` for a raise/update or `event_prefetch_store($u,$event,$element,undef)` for a clear. Only on success. Do not write through for exempt events.

- [ ] **Step 5: Run, all green** (golden identical off vs on; raise→read true; clear→read false).

- [ ] **Step 6: Commit.**
```bash
git add lib/NMISNG/Events.pm lib/Compat/NMIS.pm test/t_event_prefetch.pl
git commit -m "OMK-12677. Spike: serve eventExist/checkEvent from buffer + write-through; golden + in-cycle gate"
```

---

### Task 6: Adversarial cross-process tests

**Files:**
- Modify: `test/t_event_prefetch.pl`
- Consumes: the matrix and exemption list from Task 1.

- [ ] **Step 1: Write the tests.** For each row of the Task 1 matrix that leaves a residual window (non-lock-holding writer), write a test that: opens the buffer, then writes directly to the events collection (simulating the other process, bypassing the buffer), then runs the relevant check and asserts the documented outcome — for an exempted class, the read must be live and therefore correct; for an accepted-residual class, assert the documented one-cycle-stale behaviour and that the unique partial index still prevents a duplicate active row.

- [ ] **Step 2: Run, all green.**

- [ ] **Step 3: Commit.**
```bash
git add test/t_event_prefetch.pl
git commit -m "OMK-12677. Spike: adversarial cross-process tests matching the audit matrix"
```

---

### Task 7: Measure with the buffer on; record the contained-change evidence

**Files:** none (measurement + notes into the audit doc).

- [ ] **Step 1: Re-measure the real node with the buffer on.**
Run: `docker exec <container> bash -lc 'cd /usr/local/nmis9 && NMIS_EVENT_PREFETCH_ENABLED=1 perl test/t_event_prefetch_realnode.pl 2>&1 | tail -1'`
Expected: the events-find count drops from ~52 to a small constant (one batch find plus any exempted live reads). Record before/after in the audit doc.

- [ ] **Step 2: Synthetic scaling.** Add a synthetic node with N interfaces each carrying an active event, measure events finds with the buffer off vs on, confirm the per-event reads collapse to ~1 batch find regardless of N. Record the N = 50/150 numbers.

- [ ] **Step 3: Contained-change evidence.** Record `git diff --stat origin/nmis9_dev...HEAD` for the lib changes: files touched and line counts. Confirm no new locking primitives were added and the buffer reuses the OMK-12668 Guard/getbool pattern.

- [ ] **Step 4: Commit the recorded evidence.**
```bash
git add docs/superpowers/specs/2026-06-30-event-prefetch-audit.md
git commit -m "OMK-12677. Spike: load reduction evidence (real + synthetic) and contained-change record"
```

---

### Task 8: THE GATE (go/no-go)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-30-event-prefetch-audit.md` (a final "Gate decision" section).

- [ ] **Step 1: Evaluate all four criteria against the artifacts:**
1. Load reduction shown on real + synthetic (Task 7)?
2. Golden event-write-stream byte-identical off vs on, in-cycle cases pass (Task 5)?
3. Matrix complete, residual documented and acceptable, exemptions applied (Tasks 1, 6)?
4. Contained change confirmed (Task 7 Step 3)?

- [ ] **Step 2: Record the decision.** Write "GO" or "NO-GO" with the evidence for each criterion. If NO-GO, STOP here — do not start Phase 2. The branch stands as the documented investigation. If GO, proceed.

- [ ] **Step 3: Commit and surface the decision to the human partner before Phase 2.**
```bash
git add docs/superpowers/specs/2026-06-30-event-prefetch-audit.md
git commit -m "OMK-12677. Spike: go/no-go gate decision"
```

---

## PHASE 2 — IMPLEMENTATION (only if Task 8 = GO)

### Task 9: Finalise exemptions and harden

**Files:**
- Modify: `lib/NMISNG/Events.pm` (the `_event_exempt` list), `lib/Compat/NMIS.pm` if needed.

- [ ] **Step 1:** Make `_event_exempt` reflect the final audited exemption list verbatim, with a comment citing the audit doc. If the list is empty, leave the helper returning false with a comment saying the audit found all external writers lock-serialised.
- [ ] **Step 2:** Re-run `test/t_event_prefetch.pl` and `test/t_event_prefetch_realnode.pl` (buffer on). Expected: all green, load still reduced.
- [ ] **Step 3: Commit.**
```bash
git add lib/NMISNG/Events.pm lib/Compat/NMIS.pm
git commit -m "OMK-12677. Apply audited event-class exemptions"
```

### Task 10: Default-on, docs, final review

**Files:**
- Modify: `lib/NMISNG.pm` (flip the kill-switch default to ON), the events plugin/config docs.

- [ ] **Step 1:** Change `event_prefetch_begin`'s flag read from `// 0` to `// 1` so the buffer is default-on, matching the OMK-12668 pattern. Add a test case to `t_event_prefetch.pl` asserting `begin` returns a guard when the flag is unset (default on) and `undef` when explicitly `false`.
- [ ] **Step 2:** Document `event_prefetch_enabled` and the buffer behaviour where the other collect tunables are documented, and link the audit matrix.
- [ ] **Step 3:** Run the full suite (`t_event_prefetch.pl`, the interface-collect golden suite if present, the real-node measurement). Expected: all green, load reduced, behaviour unchanged.
- [ ] **Step 4: Commit.**
```bash
git add lib/NMISNG.pm test/t_event_prefetch.pl conf-default/
git commit -m "OMK-12677. Enable event prefetch by default; document the buffer and the audit"
```

---

## Notes for the implementer

- Phase 1 is the product if the gate is NO-GO: the audit, the matrix, the measurement, and the prototype-with-tests all stand as the documented reason. Do not treat NO-GO as failure to hide.
- The single most likely bug is the clear case: a clear must remove the buffer row (`event_prefetch_store(..., undef)`), or a later in-cycle `eventExist` will wrongly report the event still active. Task 5's clear→read test is the guard for this.
- `eventExist` loads by `node_uuid+event+element+historic` and checks `active` in Perl ("active is ignored by event::load"), so the buffered row must carry both `active` and `historic` for the in-Perl check to match the live path.
- Respect the unique partial index on `(node_uuid,event,element,active)` with `historic <= 0`: the buffer must never let two active rows for one key exist in memory, mirroring what the DB enforces.
