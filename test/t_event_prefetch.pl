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
NMISNG::DB::insert(collection => $nmisng->events_collection,
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

# ---------------------------------------------------------------------------
# Task 5: serve eventExist from the buffer + write-through, with the golden gate.
# These exercise the REAL low-level write funnels (NMISNG::Event::save and
# NMISNG::Event::delete) that every in-cycle mutation path (notify/checkEvent/
# handle_down) passes through, rather than the eventAdd/eventDelete wrappers
# (which a real collect never calls). See task-5 brief parts A and B.
# ---------------------------------------------------------------------------

# Lightweight node stub: eventExist only ever calls $node->uuid (see
# NMISNG::Node::eventExist -> NMISNG::Events::eventExist($self,...)).
{ package T5::Node; sub new { bless { uuid => $_[1] }, $_[0] } sub uuid { $_[0]->{uuid} } }
my $TUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
my $tnode = T5::Node->new($TUUID);

# capture the real event-write stream by wrapping the low-level funnels.
# records event name, element, and the active/historic state AFTER the write,
# only for writes that actually persisted (the wrapped method returned no error).
my @STREAM;
my $cap_on = 0;
my $orig_save   = \&NMISNG::Event::save;
my $orig_delete = \&NMISNG::Event::delete;
{ no warnings 'redefine';
  *NMISNG::Event::save = sub {
    my ($self,%a) = @_;
    my $err = $orig_save->($self,%a);
    push @STREAM, sprintf("save\t%s\t%s\ta=%s\th=%s",
      $self->event//'', $self->element//'', $self->active//'', $self->historic//'')
      if ($cap_on && !$err);
    return $err;
  };
  *NMISNG::Event::delete = sub {
    my ($self,%a) = @_;
    my $err = $orig_delete->($self,%a);
    push @STREAM, sprintf("delete\t%s\t%s", $self->event//'', $self->element//'')
      if ($cap_on && !$err);
    return $err;
  };
}

# helper: run the identical deterministic event-bearing scenario and return the
# captured write stream. $with_buffer opens a real prefetch buffer for the node.
sub run_scenario {
  my ($uuid, $with_buffer) = @_;
  # clean slate for this node
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $uuid }, just_one => 0);
  @STREAM = ();
  my $guard;
  $guard = $nmisng->event_prefetch_begin(node_uuid => $uuid) if ($with_buffer);
  $cap_on = 1;
  # raise two events through the raise funnel (save), as notify does
  for my $e (["Interface Down","eth0"], ["Interface Down","eth1"]) {
    my $ev = $nmisng->events->event(node_uuid=>$uuid, node_name=>"t5", event=>$e->[0],
      element=>$e->[1], active=>1, level=>"Major", cluster_id=>$C->{cluster_id});
    $ev->save();
  }
  # clear one via the check-style rename+save funnel (what checkEvent/check does)
  { my $ev = $nmisng->events->event(node_uuid=>$uuid, event=>"Interface Down",
      element=>"eth0", cluster_id=>$C->{cluster_id});
    $ev->load();
    $ev->active(0); $ev->event("Interface Up"); $ev->save();
  }
  # clear the other via the delete funnel (what escalations/notify-cancel use)
  { my $ev = $nmisng->events->event(node_uuid=>$uuid, event=>"Interface Down",
      element=>"eth1", cluster_id=>$C->{cluster_id});
    $ev->delete();
  }
  $cap_on = 0;
  undef $guard;
  return [@STREAM];
}

# Assertion 1: golden equivalence — identical, non-empty write stream off vs on.
my $G1 = "11111111-0000-0000-0000-000000000001";
my $G2 = "11111111-0000-0000-0000-000000000002";
my $stream_off = run_scenario($G1, 0);
my $stream_on  = run_scenario($G2, 1);
ok(scalar(@$stream_off) > 0, "golden: write stream is non-empty (captured real writes)");
is_deeply($stream_on, $stream_off,
  "golden: event-write stream is identical buffer-OFF vs buffer-ON");

# Assertion 2: raise -> read within an active buffered cycle returns TRUE.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $TUUID }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $TUUID);
  is($nmisng->event_prefetch_active($TUUID), 1, "raise->read: buffer is active");
  is($nmisng->events->eventExist($tnode,"Interface Down","eth0"), 0,
    "raise->read: event absent before raise");
  my $ev = $nmisng->events->event(node_uuid=>$TUUID, node_name=>"t5", event=>"Interface Down",
    element=>"eth0", active=>1, level=>"Major", cluster_id=>$C->{cluster_id});
  $ev->save();
  my $buf = $nmisng->event_prefetch_lookup($TUUID,"Interface Down","eth0");
  is(($buf && $buf->{active}), 1, "raise->read: write-through populated the buffer row");
  is($nmisng->events->eventExist($tnode,"Interface Down","eth0"), 1,
    "raise->read: eventExist TRUE from buffer after in-cycle raise");
}
is($nmisng->event_prefetch_active($TUUID), 0, "raise->read: buffer torn down");

# Assertion 3: clear -> read within an active buffered cycle returns FALSE.
# (a) clear via the check-style rename+save funnel.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $TUUID }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $TUUID);
  my $ev = $nmisng->events->event(node_uuid=>$TUUID, node_name=>"t5", event=>"Interface Down",
    element=>"eth0", active=>1, level=>"Major", cluster_id=>$C->{cluster_id});
  $ev->save();
  is($nmisng->events->eventExist($tnode,"Interface Down","eth0"), 1, "clear->read(save): present after raise");
  # clear: deactivate + rename, as check() does
  my $cl = $nmisng->events->event(node_uuid=>$TUUID, event=>"Interface Down", element=>"eth0",
    cluster_id=>$C->{cluster_id});
  $cl->load(); $cl->active(0); $cl->event("Interface Up"); $cl->save();
  is($nmisng->events->eventExist($tnode,"Interface Down","eth0"), 0,
    "clear->read(rename+save): eventExist FALSE after in-cycle clear");
}
# (b) clear via the delete funnel.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $TUUID }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $TUUID);
  my $ev = $nmisng->events->event(node_uuid=>$TUUID, node_name=>"t5", event=>"Interface Down",
    element=>"eth2", active=>1, level=>"Major", cluster_id=>$C->{cluster_id});
  $ev->save();
  is($nmisng->events->eventExist($tnode,"Interface Down","eth2"), 1, "clear->read(delete): present after raise");
  my $cl = $nmisng->events->event(node_uuid=>$TUUID, event=>"Interface Down", element=>"eth2",
    cluster_id=>$C->{cluster_id});
  $cl->delete();
  is($nmisng->events->eventExist($tnode,"Interface Down","eth2"), 0,
    "clear->read(delete): eventExist FALSE after in-cycle delete");
}

# Assertion 4: an exempt event (Node Down) is read LIVE even when the buffer is
# active. Seed a buffer row that DISAGREES with the DB (buffer says active, DB
# says absent) and confirm the live DB answer wins for the exempt class, while a
# non-exempt event served from the same buffer trusts the buffer.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $TUUID }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $TUUID);
  # buffer claims both an exempt and a non-exempt event are active; DB has neither
  $nmisng->event_prefetch_store($TUUID,"Node Down","",
    {event=>"Node Down", element=>"", active=>1, historic=>0});
  $nmisng->event_prefetch_store($TUUID,"Interface Down","eth5",
    {event=>"Interface Down", element=>"eth5", active=>1, historic=>0});
  is($nmisng->events->eventExist($tnode,"Node Down",""), 0,
    "exempt: Node Down read LIVE (DB absent) despite buffer claiming active");
  is($nmisng->events->eventExist($tnode,"Interface Down","eth5"), 1,
    "exempt: non-exempt Interface Down trusts the buffer (control)");
}

# Assertion 5: stateless-match alignment — _event_exempt must use substring
# semantics (congruent with Compat::NMIS::notify) not exact comma-split eq.
# Set non_stateful_events to "Custom Power Alarm"; raise event "Power Alarm".
# notify treats "Power Alarm" as stateless (substring hit).
# _event_exempt must also treat it as exempt (substring hit), so eventExist
# reads LIVE and returns 0 (DB absent). Before the fix it returns 1 (buffer).
{
  my $saved_nse = $nmisng->config->{non_stateful_events};
  $nmisng->config->{non_stateful_events} = "Custom Power Alarm";
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $TUUID }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $TUUID);
  # seed a buffer row saying "Power Alarm" is active; DB has no such row
  $nmisng->event_prefetch_store($TUUID,"Power Alarm","",
    {event=>"Power Alarm", element=>"", active=>1, historic=>0});
  # expected: exempt -> read live -> DB absent -> 0
  is($nmisng->events->eventExist($tnode,"Power Alarm",""), 0,
    "stateless substring: Power Alarm exempt (substring of Custom Power Alarm) -> live read -> 0");
  $nmisng->config->{non_stateful_events} = $saved_nse;
}

# ---------------------------------------------------------------------------
# Task 6: Adversarial cross-process tests (OMK-12677).
# Each test simulates an out-of-cycle process by writing DIRECTLY to the
# events collection via NMISNG::DB primitives (bypassing the buffer and its
# write-through), then confirms eventExist returns the DOCUMENTED outcome.
#
# ensure_indexes primes the unique partial index on events
# (node_uuid,event,element where historic<=0). NMISNG->new does NOT call it;
# nmisd does. The per-PID test DB needs it primed explicitly for xp3.
$nmisng->ensure_indexes();

my $X1 = "cccccccc-0000-0000-0000-000000000001";  # uuid for cross-process tests
my $xnode = T5::Node->new($X1);

# Cross-process test 1: exempt class tracks the DB despite the buffer (M1/M2).
# External process raises Node Down directly into the DB while the buffer is
# active. eventExist must return 1 (exempt -> live read -> sees the external
# raise). Then the external process clears it (sets active=0); eventExist must
# return 0 (exempt -> live read -> sees the clear). The buffer is never
# consulted for this event class.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $X1 }, just_one => 0);
  my $g = $nmisng->event_prefetch_begin(node_uuid => $X1);
  is($nmisng->event_prefetch_active($X1), 1, "xp1: buffer active");

  # External raise: insert an active Node Down directly (no write-through).
  NMISNG::DB::insert(collection => $nmisng->events_collection,
    record => { node_uuid => $X1, event => "Node Down", element => "",
                active => 1, historic => 0, cluster_id => $C->{cluster_id} });
  # Buffer has no knowledge of this row; but exempt -> live read -> sees it.
  is($nmisng->events->eventExist($xnode, "Node Down", ""), 1,
    "xp1 M1/M2: exempt Node Down raised externally -> live read -> 1 (correct, not stale)");

  # External clear: update directly in the DB (active=0), still no write-through.
  NMISNG::DB::update(collection => $nmisng->events_collection,
    query => { node_uuid => $X1, event => "Node Down", element => "", historic => 0 },
    record => { active => 0 });
  # Exempt -> live read -> sees the clear immediately (not one-cycle-stale).
  is($nmisng->events->eventExist($xnode, "Node Down", ""), 0,
    "xp1 M1/M2: exempt Node Down cleared externally -> live read -> 0 (correct, not stale)");
}

# Cross-process test 2: accepted one-cycle-stale for a NON-exempt class (M11/M13, audit §7).
# Phase A: buffer shows Interface Down/eth0 active; external process clears it in
#           the DB mid-cycle. eventExist must STILL return 1 from the buffer
#           (documented one-cycle-stale residual, not a bug).
# Phase B: simulate the next cycle with a fresh event_prefetch_begin, which
#           reloads from the DB. eventExist must now return 0 (self-corrected).
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $X1 }, just_one => 0);

  # Seed an active Interface Down into the DB and open a buffer (it loads it).
  NMISNG::DB::insert(collection => $nmisng->events_collection,
    record => { node_uuid => $X1, event => "Interface Down", element => "eth0",
                active => 1, historic => 0, cluster_id => $C->{cluster_id} });
  {
    my $g = $nmisng->event_prefetch_begin(node_uuid => $X1);
    my $buf = $nmisng->event_prefetch_lookup($X1, "Interface Down", "eth0");
    is(($buf && $buf->{active}), 1, "xp2 phase-A: buffer loaded the active event at cycle start");

    # External clear mid-cycle: update directly, bypassing the buffer.
    NMISNG::DB::update(collection => $nmisng->events_collection,
      query => { node_uuid => $X1, event => "Interface Down", element => "eth0", historic => 0 },
      record => { active => 0, historic => 1 });

    # Non-exempt -> buffer is consulted -> returns the stale active answer.
    # This is the DOCUMENTED one-cycle-stale residual (audit §7, M11/M13): not a bug.
    is($nmisng->events->eventExist($xnode, "Interface Down", "eth0"), 1,
      "xp2 M11/M13 phase-A: non-exempt Interface Down cleared externally -> buffer returns stale 1 (documented residual)");
  } # guard drops: buffer cleared

  # Phase B: next cycle opens a fresh buffer. The DB now has historic=1 (cleared).
  {
    my $g2 = $nmisng->event_prefetch_begin(node_uuid => $X1);
    # Buffer reloaded from live DB; the cleared event is historic so not loaded.
    is($nmisng->events->eventExist($xnode, "Interface Down", "eth0"), 0,
      "xp2 M11/M13 phase-B: next cycle reloads -> self-corrected to 0");
  }
}

# Cross-process test 3: unique partial index prevents a duplicate active row (residual safety net).
# The unique partial index on (node_uuid, event, element) where historic<=0 means
# that even if a stale buffer led collect to re-raise an event the DB already has
# active, the second insert is rejected with a duplicate-key error.
# This proves the safety net the audit relies on for the residual-window rows.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $X1 }, just_one => 0);

  # Insert the first active row for (X1, Interface Down, eth0).
  my $r1 = NMISNG::DB::insert(collection => $nmisng->events_collection,
    record => { node_uuid => $X1, event => "Interface Down", element => "eth0",
                active => 1, historic => 0, cluster_id => $C->{cluster_id} });
  is($r1->{success}, 1, "xp3: first active row inserted successfully");

  # Attempt to insert a SECOND active row for the same (node_uuid, event, element).
  my $r2 = NMISNG::DB::insert(collection => $nmisng->events_collection,
    record => { node_uuid => $X1, event => "Interface Down", element => "eth0",
                active => 1, historic => 0, cluster_id => $C->{cluster_id} });
  is($r2->{success}, 0, "xp3 safety net: duplicate active row rejected by the unique partial index");
  like($r2->{error}, qr/E11000/,
    "xp3 safety net: rejection is a duplicate-key error (E11000)");

  # Confirm exactly ONE active row remains in the DB.
  my $md = $nmisng->events->get_events_model(
    filter => { node_uuid => $X1, event => "Interface Down", element => "eth0", historic => 0, active => 1 });
  is(scalar(@{ $md->data() // [] }), 1, "xp3: exactly one active row survives (index blocked the duplicate)");
}

# ---------------------------------------------------------------------------
# Task 9: pin the two structural invariants that make the documented residual
# (node-wide clean/rename racing a same-node collect, audit §7) verified-benign.
# See docs/superpowers/specs/2026-06-30-event-prefetch-audit.md, "Residual
# verification" subsection under §7, for the narrative this pins.
# ---------------------------------------------------------------------------

# PRIMARY — invariant (b): Event::check() re-reads live and is gated on the
# LIVE result, so a stale-PRESENT buffer answer for a non-exempt event can
# never cause a spurious clear/Up-event when the row has actually been
# cleared out-of-cycle (Event.pm:~309-316 buffer early-return only fires on
# buffer-ABSENT; Event.pm:319 self->exists() re-reads live; Event.pm:342
# "if ($exists && $self->active)" with no else gates the entire clear body on
# that live result). We call Event::check() directly (the same entry point
# Compat::NMIS::checkEvent uses, Compat/NMIS.pm:2208) rather than going through
# checkEvent/notify, because those require a full live Sys object this harness
# cannot build; Event::check's own no-op path never touches $args{sys} — sys is
# assigned to $S at Event.pm:298 but not dereferenced until inside the
# "if ($exists && $self->active)" body at Event.pm:342+, which this scenario
# never enters. So sys=>undef faithfully exercises the real decision code
# (the buffer peek, the live exists() re-read, and the gate) without needing a
# node/sys stub. If Event::check were changed to trust a stale-present buffer
# row instead of re-reading live, this test would go from PASS to FAIL: it
# would see $exists effectively short-circuited by the buffer and take the
# clear branch, producing an "Interface Up" write that this test asserts does
# NOT happen.
{
  NMISNG::DB::remove(collection => $nmisng->events_collection, query => { node_uuid => $X1 }, just_one => 0);

  # DB has NO active row for (X1, Interface Down, eth0) -- i.e. it has already
  # been cleared out-of-cycle (historic=1), simulating a node-wide
  # cleanNodeEvents/eventsClean race per the residual.
  NMISNG::DB::insert(collection => $nmisng->events_collection,
    record => { node_uuid => $X1, event => "Interface Down", element => "eth0",
                active => 0, historic => 1, cluster_id => $C->{cluster_id} });

  my $g = $nmisng->event_prefetch_begin(node_uuid => $X1);
  is($nmisng->event_prefetch_active($X1), 1, "pin(b): buffer active");

  # Force a stale-PRESENT buffer row for this NON-exempt event, disagreeing
  # with the DB (which has no active row -- see above). This is exactly the
  # documented residual shape: buffer says present, DB says cleared.
  $nmisng->event_prefetch_store($X1, "Interface Down", "eth0",
    { event => "Interface Down", element => "eth0", active => 1, historic => 0 });
  my $stale = $nmisng->event_prefetch_lookup($X1, "Interface Down", "eth0");
  is(($stale && $stale->{active}), 1, "pin(b): buffer holds the stale-PRESENT row");

  # Invoke the clear decision the way Node.pm:4495's guarded checkEvent call
  # does: build an Event for the down-event and call ->check directly.
  my $down_ev = $nmisng->events->event(
    node_uuid => $X1, node_name => "t9", event => "Interface Down",
    element => "eth0", cluster_id => $C->{cluster_id});

  $cap_on = 1;
  @STREAM = ();
  $down_ev->check(sys => undef, details => "pin(b) probe", level => "Normal");
  $cap_on = 0;

  is(scalar(@STREAM), 0,
    "pin(b): Event::check on stale-PRESENT/live-ABSENT is a NO-OP -- no save/delete write happened");
  ok(!(grep { /Interface Up/ } @STREAM),
    "pin(b): no spurious 'Interface Up' clear-event was written");

  # Confirm the DB itself is untouched: still exactly the one historic=1 row,
  # no new active=1/historic=0 row (which a spurious clear-then-save could add).
  my $after = $nmisng->events->get_events_model(
    filter => { node_uuid => $X1, event => "Interface Down", element => "eth0", historic => 0 });
  is(scalar(@{ $after->data() // [] }), 0,
    "pin(b): DB has no live (historic=0) row after check() -- confirms the no-op reached no write path");
}

# SECONDARY — invariant (a): raise decisions are decided from a LIVE
# $event_obj->load()/exists() (Compat/NMIS.pm:2272-2273), and Event::load /
# Event::exists (Event.pm:722-734, 743-859) have no buffer branch at all --
# grep confirms neither method references event_prefetch anywhere. So a
# raise can never be gated on/suppressed by a stale buffer answer.
#
# We cannot drive Compat::NMIS::notify itself here: notify requires a live Sys
# object (node model, mdl, config wiring for getLogLevel/outageCheck/etc) that
# this harness's minimal T5::Node stub does not provide, and building a real
# one is out of scope for a unit test. What we CAN and do assert, honestly:
# 1. Structural fact, mechanically checked: Event::load and Event::exists
#    contain no reference to event_prefetch_active/_lookup -- i.e. there is no
#    code path by which a raise's existence check could consult the buffer.
# 2. The existing golden test (assertions 1-2 above, "golden: event-write
#    stream is identical buffer-OFF vs buffer-ON") already demonstrates
#    end-to-end that the real save-funnel write stream -- which is what a raise
#    ultimately produces -- is byte-identical with the buffer on or off, i.e.
#    raises are not buffer-affected in practice, not just in theory.
# This is deliberately narrower than the primary pin: it is a structural
# regression guard (a future change wiring the buffer into load/exists would
# be caught here) plus a pointer to the existing behavioural evidence, not a
# new behavioural test of notify() itself. See report for this caveat in full.
{
  my $load_src   = do { local $@; local $/; open(my $fh, '<', "$FindBin::Bin/../lib/NMISNG/Event.pm") or die $!; <$fh> };
  # isolate just the load() and exists() sub bodies to avoid false negatives/positives from unrelated code.
  # Bound each sub by the START of the NEXT top-level "sub " line (not by the
  # first "\n}", which would wrongly stop at an inner block's closing brace,
  # e.g. exists()'s own nested "if (...) { ... }").
  my ($exists_body) = $load_src =~ /(^sub exists\b.*?)(?=^sub )/ms;
  my ($load_body)   = $load_src =~ /(^sub load\b.*?)(?=^sub )/ms;
  ok(defined($exists_body) && defined($load_body), "pin(a): located Event::exists and Event::load sub bodies");
  ok($exists_body !~ /event_prefetch/, "pin(a): Event::exists has no event_prefetch buffer branch (raise-decision path is live)");
  ok($load_body !~ /event_prefetch/, "pin(a): Event::load has no event_prefetch buffer branch (raise-decision path is live)");
}

$nmisng->get_db()->drop();
done_testing;
