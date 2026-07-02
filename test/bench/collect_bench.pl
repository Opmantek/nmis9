#!/usr/bin/perl
# Measure one collect. Usage: collect_bench.pl --node NAME --mode live|mock --runs 5 [--capture PATH]
#
# Mock injection notes (confirmed against source, not assumed):
#  - NMISNG::Sys::open (lib/NMISNG/Sys.pm) is called as $S->open(...) from
#    Node::collect, but only when $S->status->{snmp_enabled} is true, which
#    just tests that $self->{snmp} is already a truthy object -- Sys::init
#    populates that with a real NMISNG::Snmp before open() ever runs, as
#    long as the node has snmp community/username configured (Task 3's
#    job). Our patched open() swaps that real object out for the Mock and
#    reports success, matching what the real open() does on the happy path
#    (assign $self->{snmp}, then test it).
#  - NMISNG::Snmp::Mock->new (test/lib/NMISNG/Snmp/Mock.pm) takes
#    nmisng/name/walk_data; walk_data is the confirmed key.
#  - Mock::isopen and Mock::get/gettable/getarray all gate purely on
#    $self->{session} being truthy, so setting {session}=1 directly (rather
#    than calling the real Mock::open) is sufficient to "open" it.
#  - Mock::testsession is NOT just a flag check: it calls $self->get() on
#    sysObjectID.0 (1.3.6.1.2.1.1.2.0) and requires that OID to be present
#    with a truthy value in walk_data. Confirmed present in the capture
#    fixture (value ".1.3.6.1.4.1.8072.3.2.10"), so testsession is
#    satisfied for real -- we don't need to stub testsession itself.
#  - The real Sys::open() also sets $catchall_data->{snmpVer} from
#    $self->{snmp}->version after a successful open. Confirmed by grep
#    across lib/NMISNG/*.pm that snmpVer is written there and nowhere else
#    read, so skipping it in the patched open is benign.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/../../lib";
use Getopt::Long; use JSON::XS; use Time::HiRes qw(time);
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;
# Node::collect() calls Compat::NMIS::checkEvent() fully-qualified without
# loading it itself; callers are expected to load it (node_admin.pl and
# dev-tools.pl both "use Compat::NMIS;"). Confirmed by running this script
# without it: "Undefined subroutine &Compat::NMIS::checkEvent" at Node.pm.
use Compat::NMIS;
my %o = (mode=>"live", runs=>5, capture=>"$FindBin::Bin/testdata/realnode_capture.json");
GetOptions(\%o, "node=s","mode=s","runs=i","capture=s") or die;
die "need --node\n" if (!$o{node});

# loadConfTable()'s default dir is $FindBin::RealBin/../conf; since this
# script lives in test/bench/, that default resolves to test/conf (does not
# exist), not the top-level conf/ that node_admin.pl/dev-tools.pl use. Pass
# the real path explicitly (Task 3 finding: this script had never actually
# been run end-to-end before, only perl -c'd, so this was undiscovered).
my $C = NMISNG::Util::loadConfTable(dir => "$FindBin::Bin/../../conf");
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
    $self->{snmp}->{session} = 1;    # mark open; Mock::isopen/get/gettable/getarray gate on this.
                                       # Mock::testsession separately re-checks sysObjectID.0 against
                                       # walk_data, confirmed present in the capture fixture.
    return 1;                         # mock session is always good
  };
}

my $node = $nmisng->node(name => $o{node}) or die "node $o{node} not found\n";
sub rss_kb { open my $s,"<","/proc/self/status" or return 0; while(<$s>){ return $1 if /^VmRSS:\s+(\d+)/ } 0 }
sub opcounters {
  # get_db() already returns a MongoDB::Database (confirmed: NMISNG::get_db's
  # doc comment and NMISNG::DB::connection_of_db both treat it as such); the
  # brief's "$db->_database->_client" assumed an extra client-wrapper layer
  # that doesn't exist -- MongoDB::Database->_client is the client directly
  # (confirmed via NMISNG::DB::connection_of_db, which does exactly this).
  my $db = $nmisng->get_db(); my $admin = $db->_client->get_database("admin");
  my $ss = $admin->run_command([serverStatus=>1]); my $o = $ss->{opcounters} || {};
  return { map { $_ => 0 + ($o->{$_}//0) } qw(query update insert delete getmore command) };
}

# warm-up (discarded)
$COUNTING=0; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1);

my (@wall, %ops_run, $rss_before, $rss_peak, %ocd);
$rss_before = rss_kb();
for my $i (1..$o{runs}) {
  %DBOPS=(); $COUNTING=1;
  # opcounters is a SERVER-INSTANCE-WIDE counter (serverStatus.opcounters is
  # not scoped to our db or connection), so on a shared MongoDB it also
  # counts other clients' ops in the same window -- it's a rough cross-check.
  # db_ops (in-process, per our collect) is the authoritative per-collect
  # metric. Sample it per-run (matching db_ops's single-run semantics) rather
  # than once around the whole loop, so opcounters_delta is comparable to
  # db_ops instead of being ~N times larger.
  my $oc_before = opcounters();
  my $t0=time; $node->collect(wantsnmp=>1, wantwmi=>0, force=>1); my $ms=(time-$t0)*1000;
  my $oc_after = opcounters();
  $COUNTING=0;
  push @wall, $ms;
  $rss_peak = rss_kb() if (!defined $rss_peak || rss_kb() > $rss_peak);
  # op counts and opcounters are deterministic on mock; keep the last run's counts
  %ops_run = %DBOPS;
  %ocd = map { $_ => $oc_after->{$_} - $oc_before->{$_} } keys %$oc_after;
}
my @s = sort { $a<=>$b } @wall;
print JSON::XS->new->canonical->encode({
  node=>$o{node}, mode=>$o{mode}, runs=>$o{runs},
  db_ops=>\%ops_run,
  wallclock_ms=>{ median=>$s[int(@s/2)], min=>$s[0], max=>$s[-1] },
  rss_kb=>{ before=>$rss_before, peak=>$rss_peak, delta=>$rss_peak-$rss_before },
  opcounters_delta=>\%ocd,
}), "\n";
