#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::ModelPolicy;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::ModelPolicy::runcgi($args);
