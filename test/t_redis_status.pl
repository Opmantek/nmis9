#!/usr/bin/perl
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::Sys::Engine::Redis::Status;

my $c = \&NMISNG::Sys::Engine::Redis::Status::canonical;

is($c->('meraki','online'),   'up',       'meraki online -> up');
is($c->('meraki','offline'),  'down',     'meraki offline -> down');
is($c->('meraki','alerting'), 'degraded', 'meraki alerting -> degraded');
is($c->('meraki','dormant'),  'degraded', 'meraki dormant -> degraded');
is($c->('hpe_greenlake','ONLINE'),  'up',   'greenlake ONLINE -> up');
is($c->('hpe_greenlake','UP'),      'up',   'greenlake/aruba UP -> up (union)');
is($c->('hpe_greenlake','OFFLINE'), 'down', 'greenlake OFFLINE -> down');
is($c->('MERAKI','Online'),  'up',      'engine and value are case-insensitive');
is($c->('meraki','wedged'),  'unknown', 'unrecognised value -> unknown');
is($c->('newvendor','online'),'unknown','unknown engine -> unknown');
is($c->('meraki',undef),     'unknown', 'undef raw -> unknown');
is($c->(undef,'online'),     'unknown', 'undef engine -> unknown');

done_testing();
