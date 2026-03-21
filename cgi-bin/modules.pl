#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Modules;
my $args = NMISCGI::authenticate(no_auth => 1) or exit;
NMISCGI::Modules::runcgi($args);
