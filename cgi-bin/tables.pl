#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Compat::NMIS;
use NMISCGI;
use NMISCGI::Tables;
my $args = NMISCGI::authenticate(allow_cli => 1, set_user => "nmis") or exit;
$args->{nmisng} = Compat::NMIS::new_nmisng;
NMISCGI::Tables::runcgi($args);
