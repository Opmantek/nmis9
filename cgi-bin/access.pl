#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMISCGI;
use NMISCGI::Access;
my $args = NMISCGI::initialise() or exit;
NMISCGI::authenticate($args,
	auth_type     => $args->{Q}{auth_type},
	auth_username => $args->{Q}{auth_username},
	auth_password => $args->{Q}{auth_password},
	cluster_id    => $args->{Q}{cluster_id},
) or exit;
NMISCGI::Access::runcgi($args);
