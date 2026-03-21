#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Compat::NMIS;
use NMISCGI;
use NMISCGI::Reports;
my $args = NMISCGI::authenticate(allow_cli => 1) or exit;
$args->{nmisng} = Compat::NMIS::new_nmisng;
NMISCGI::Reports::runcgi($args);
