#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Setup;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Setup::runcgi($args);
