#!/usr/bin/perl
#
# Test: _populate_event_status_in_dashnode adds Backup Host Down and
# Node Polling Failover events to the dashnode JSON status section.
#
# Usage:
#   Phase 1 - method exists check (run BEFORE implementation):
#     perl test/test_dashnode_event_status.pl
#
#   Phase 2 - events appear after inject + collect:
#     /usr/local/nmis9/bin/nmis-cli act=notify event="Node Polling Failover" node=localhost level=Major details="Test switchover"
#     /usr/local/nmis9/bin/nmis-cli act=notify event="Backup Host Down" node=localhost level=Critical details="Test backup down"
#     /usr/local/nmis9/bin/nmis-cli act=schedule job.type=collect job.node=localhost
#     # wait for collect to finish, then:
#     perl test/test_dashnode_event_status.pl --check-events
#
#   Phase 3 - events cleared after resolve:
#     # acknowledge/close the events, run another collect, then:
#     perl test/test_dashnode_event_status.pl --check-cleared

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd 'abs_path';
use Test::More;

my $base          = abs_path("$FindBin::Bin/..");
my $check_events  = grep { $_ eq '--check-events'  } @ARGV;
my $check_cleared = grep { $_ eq '--check-cleared' } @ARGV;

# ---------------------------------------------------------------------------
# Test 1: method exists on NMISNG::Node
# ---------------------------------------------------------------------------
require NMISNG::Node;
ok( NMISNG::Node->can('_populate_event_status_in_dashnode'),
    '_populate_event_status_in_dashnode method exists on NMISNG::Node' );

# ---------------------------------------------------------------------------
# Test 2: dashnode file exists for localhost (skipped if enable_dashnode_file
# is not configured — the file won't exist in environments where it is off)
# ---------------------------------------------------------------------------
my $dashnode_file = "$base/var/localhost-node.json";
SKIP: {
    skip "dashnode file not present (enable_dashnode_file may not be set)", 1
        unless -r $dashnode_file;
    ok( 1, "dashnode file exists at $dashnode_file" );
}

if ( ($check_events || $check_cleared) && -r $dashnode_file ) {
    require NMISNG::Util;
    my $data = NMISNG::Util::readFiletoHash(file => $dashnode_file);
    ok( ref($data) eq 'HASH', 'dashnode file parses as a hash' );

    my $status = $data->{status} // {};
    diag("Status entry count: " . scalar(keys %$status));

    if ($check_events) {
        # -------------------------------------------------------------------
        # Tests 4-7: Backup Host Down present (host_backup must be set to an
        # unreachable IP on the test node, e.g. 192.0.2.1)
        # -------------------------------------------------------------------
        my $key = 'Backup Host Down--';
        ok( exists $status->{$key},
            "'$key' is present in status section" );
        if (exists $status->{$key}) {
            ok( defined $status->{$key}{event},   "'$key' has event field" );
            ok( defined $status->{$key}{level},   "'$key' has level field" );
            ok( defined $status->{$key}{details}, "'$key' has details field" );
            diag("  event:   " . ($status->{$key}{event}   // '(undef)'));
            diag("  level:   " . ($status->{$key}{level}   // '(undef)'));
            diag("  details: " . ($status->{$key}{details} // '(undef)'));
        }

        # -------------------------------------------------------------------
        # Note: 'Node Polling Failover--' only appears when the PRIMARY host
        # is unreachable and NMIS9 switches to the backup address.
        # This cannot be simulated on localhost (primary always responds).
        # Test this in the Telmex environment on a node with an active failover.
        # -------------------------------------------------------------------
        $key = 'Node Polling Failover--';
        if (exists $status->{$key}) {
            ok( 1, "'$key' is present in status section (primary was down)" );
            ok( defined $status->{$key}{event},   "'$key' has event field" );
            ok( defined $status->{$key}{level},   "'$key' has level field" );
            ok( defined $status->{$key}{details}, "'$key' has details field" );
            diag("  event:   " . ($status->{$key}{event}   // '(undef)'));
            diag("  level:   " . ($status->{$key}{level}   // '(undef)'));
            diag("  details: " . ($status->{$key}{details} // '(undef)'));
        } else {
            diag("'$key' absent — primary host is up, no failover active (expected on localhost)");
        }
    }

    if ($check_cleared) {
        # -------------------------------------------------------------------
        # Tests 4-5: event keys absent after events resolved
        # -------------------------------------------------------------------
        for my $event_name ('Node Polling Failover', 'Backup Host Down') {
            my $key = "$event_name--";
            ok( !exists $status->{$key},
                "'$key' absent from status after event resolved" );
        }
    }
}

done_testing();
