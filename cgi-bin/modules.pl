#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Modules;
my $args = NMISCGI::initialise() or exit;
NMISCGI::Modules::runcgi($args);
