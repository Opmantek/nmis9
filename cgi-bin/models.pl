#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Models;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Models::runcgi($args);
