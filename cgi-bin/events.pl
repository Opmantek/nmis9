#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Compat::NMIS;
use NMISCGI;
use NMISCGI::Events;
my $args = NMISCGI::authenticate(skip_filter => 1) or exit;
$args->{nmisng} = Compat::NMIS::new_nmisng;
NMISCGI::Events::runcgi($args);
