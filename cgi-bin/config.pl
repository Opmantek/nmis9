#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Config;
my $args = NMISCGI::authenticate(skip_filter => 1, allow_cli => 1, set_user => "nmis") or exit;
NMISCGI::Config::runcgi($args);
