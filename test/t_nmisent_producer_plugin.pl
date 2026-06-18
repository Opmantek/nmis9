#!/usr/bin/perl
# The collect plugin raises nmisent Producer Stale for an engine whose last
# success is older than 2x its interval, and clears it when fresh.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
require "$FindBin::Bin/../conf-default/plugins/nmisentProducer.pm";

# pure helper: stale decision
my $stale = \&nmisentProducer::is_stale;
ok( $stale->(time - 300, 60, time), 'age 300 > 2x60 -> stale');
ok(!$stale->(time - 30,  60, time), 'age 30 <= 2x60 -> fresh');
ok(!$stale->(undef,      60, time), 'missing epoch -> not stale (indeterminate, handled elsewhere)');
ok(!$stale->(time,    undef, time), 'missing interval -> not stale');

done_testing();
