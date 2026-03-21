#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::CommunityRss;
my $args = NMISCGI::initialise() or exit;
NMISCGI::CommunityRss::runcgi($args);
