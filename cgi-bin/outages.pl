#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Compat::NMIS;
use NMISCGI;
use NMISCGI::Outages;
my $args = NMISCGI::authenticate() or exit;
$args->{nmisng} = Compat::NMIS::new_nmisng;
NMISCGI::Outages::runcgi($args);
