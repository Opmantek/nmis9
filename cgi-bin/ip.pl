#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Ip;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Ip::runcgi($args);
