#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Compat::NMIS;
use NMISCGI;
use NMISCGI::Snmp;
my $args = NMISCGI::authenticate() or exit;
$args->{nmisng} = Compat::NMIS::new_nmisng;
NMISCGI::Snmp::runcgi($args);
