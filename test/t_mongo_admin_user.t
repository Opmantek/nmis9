#!/usr/bin/perl
# OMK-12826: setup_mongodb.pl must not enable MongoDB authentication on a fresh
# no-auth server when the only user it created is the scoped nmis9RW (dbOwner on
# nmisng, no admin role). Doing so closes the localhost exception with no user
# able to administer auth, locking Mongo out until auth is disabled at the OS
# level. The guard rests on this pure predicate over a usersInfo result; unit
# tested here with synthetic user docs, no Mongo needed.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;

sub role { return { role => $_[0], db => $_[1] } }
sub user { my ($name, @roles) = @_; return { user => $name, db => 'admin', roles => [@roles] } }

# The finding's exact case: a fresh no-auth server where setup created only the
# scoped app user. No administrative user exists.
ok(!NMISNG::DB::has_admin_capable_user([
		user('nmis9RW', role('dbOwner', 'nmisng')) ]),
	"scoped nmis9RW alone is NOT an administrative user");

ok(!NMISNG::DB::has_admin_capable_user([]),
	"an empty user list has no administrative user");

ok(!NMISNG::DB::has_admin_capable_user(undef),
	"undef is treated as no administrative user (defensive)");

# Users who CAN recover/administer the deployment after auth is on.
ok(NMISNG::DB::has_admin_capable_user([ user('root', role('root', 'admin')) ]),
	"a root user counts as administrative");

ok(NMISNG::DB::has_admin_capable_user([ user('ua', role('userAdminAnyDatabase', 'admin')) ]),
	"userAdminAnyDatabase counts as administrative");

ok(NMISNG::DB::has_admin_capable_user([ user('ua', role('userAdmin', 'admin')) ]),
	"userAdmin on the admin db counts as administrative");

# userAdmin scoped to a non-admin db cannot administer the deployment's auth.
ok(!NMISNG::DB::has_admin_capable_user([ user('ua', role('userAdmin', 'nmisng')) ]),
	"userAdmin on a non-admin db does NOT count");

ok(!NMISNG::DB::has_admin_capable_user([ user('rw', role('readWrite', 'admin')) ]),
	"readWrite on admin does NOT count");

# A mixed deployment: the scoped user plus a real admin -> safe to enable auth.
ok(NMISNG::DB::has_admin_capable_user([
		user('nmis9RW', role('dbOwner', 'nmisng')),
		user('opUserRW', role('root', 'admin')) ]),
	"a real admin alongside the scoped user counts as administrative");

done_testing();
