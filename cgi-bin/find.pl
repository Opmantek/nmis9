#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Find;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Find::runcgi($args);
