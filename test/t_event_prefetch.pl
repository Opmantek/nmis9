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
$nmisng->get_db()->drop();
done_testing;
