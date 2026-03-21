#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Access;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Access::runcgi($args);
