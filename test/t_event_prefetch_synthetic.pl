#!/usr/bin/perl
# OMK-12677 Task 7 — Synthetic O(N) → O(1) scaling proof for the event-prefetch buffer.
#
# Seeds N distinct active "Interface Down" events for a throwaway node UUID in a
# per-PID test database, then counts events-collection DB::find calls while running
# eventExist once per seeded event — first with the buffer OFF, then with the buffer
# ON (event_prefetch_begin called first). Drops the test database when done.
#
# Usage:  perl test/t_event_prefetch_synthetic.pl [N1 [N2 ...]]
# Default N values: 50 150
#
# Expected:
#   OFF: N finds (one DB find per eventExist call).
#   ON:  1 find  (the single batch load by event_prefetch_begin) + 0 per eventExist.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;

my @SIZES = @ARGV ? @ARGV : (50, 150);

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_evtpf_synth_$$";   # per-PID throwaway database

# Count events-collection finds only while $COUNTING is true.
my $TOTAL    = 0;
my $COUNTING = 0;
my $orig_find = \&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub {
    my %a = @_;
    if ($COUNTING) {
      my $n = (ref($a{collection}) && $a{collection}->can("name"))
              ? $a{collection}->name : "$a{collection}";
      $TOTAL++ if $n =~ /(?:^|\.)events$/;
    }
    return $orig_find->(@_);
  };
}

sub make_nmisng {
  my (%extra) = @_;
  my %cfg = (%$C, %extra);
  return NMISNG->new(config => \%cfg, log => NMISNG::Log->new(level => 'error'));
}

# Lightweight node stub — eventExist only needs ->uuid.
{ package Syn::Node;
  sub new  { bless { uuid => $_[1] }, $_[0] }
  sub uuid { $_[0]->{uuid} }
}

for my $N (@SIZES) {
  my $uuid = do {
    require Data::UUID; Data::UUID->new->create_str();
  };

  # --- Buffer OFF ---
  {
    my $ng = make_nmisng(event_prefetch_enabled => 0);
    my $coll = $ng->events_collection;

    # Seed N active Interface Down events.
    for my $i (0 .. $N-1) {
      NMISNG::DB::insert(
        collection => $coll,
        record => {
          node_uuid  => $uuid,
          event      => "Interface Down",
          element    => "eth$i",
          active     => 1,
          historic   => 0,
          cluster_id => $C->{cluster_id},
          node_name  => "synthetic$$",
          level      => "Major",
          startdate  => time(),
          ack        => 0,
          escalate   => -1,
          notify     => "",
          stateless  => 0,
          logged     => 0,
        },
      );
    }

    my $snode = Syn::Node->new($uuid);
    $TOTAL    = 0;
    $COUNTING = 1;
    for my $i (0 .. $N-1) {
      $ng->events->eventExist($snode, "Interface Down", "eth$i");
    }
    $COUNTING = 0;
    my $off_count = $TOTAL;

    # --- Buffer ON (same data, same UUID) ---
    my $ng2 = make_nmisng(event_prefetch_enabled => 1);
    my $snode2 = Syn::Node->new($uuid);
    $TOTAL    = 0;
    $COUNTING = 1;
    {
      my $guard = $ng2->event_prefetch_begin(node_uuid => $uuid);
      for my $i (0 .. $N-1) {
        $ng2->events->eventExist($snode2, "Interface Down", "eth$i");
      }
    } # guard tears down
    $COUNTING = 0;
    my $on_count = $TOTAL;

    printf "N=%d  OFF=%d  ON=%d\n", $N, $off_count, $on_count;

    $ng->get_db()->drop();
  }
}
