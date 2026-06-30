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

$nmisng->get_db()->drop();
done_testing;
