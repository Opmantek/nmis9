#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Menu;
my $args = NMISCGI::authenticate() or exit;
NMISCGI::Menu::runcgi($args);
