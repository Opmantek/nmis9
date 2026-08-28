#!/usr/bin/perl
# OMK-12826: unit tests for the pure NMISNG::DB helpers added for the scoped-user
# work. No Mongo needed - each calls the function and asserts on its return.
#   - _auth_source_args: the authSource the 2.x driver authenticates against,
#     derived from db_auth_source (empty/absent keeps the driver default, admin).
#   - has_admin_capable_user: whether a usersInfo result contains a user that can
#     still administer auth (used to gate enabling auth in setup_mongodb.pl).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;

# --- 2.x driver: authSource passed to the client constructor -----------------
is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => 'nmisng' }) ],
	[ db_name => 'nmisng' ],
	"sets db_name => nmisng when db_auth_source is set");

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => '' }) ], [],
	"empty db_auth_source adds nothing (driver defaults to admin)");

is_deeply([ NMISNG::DB::_auth_source_args({}) ], [],
	"absent db_auth_source adds nothing (driver defaults to admin)");

# --- has_admin_capable_user: does a usersInfo result still hold an admin? -------
# setup_mongodb.pl uses this to refuse to enable auth on a fresh no-auth server
# when the only user is the scoped nmis9RW (dbOwner on nmisng, no admin role),
# which would close the localhost exception with nobody able to manage users.
sub _role { return { role => $_[0], db => $_[1] } }
sub _user { my ($name, @roles) = @_; return { user => $name, db => 'admin', roles => [@roles] } }

ok(!NMISNG::DB::has_admin_capable_user([ _user('nmis9RW', _role('dbOwner', 'nmisng')) ]),
	"scoped nmis9RW alone is NOT an administrative user");
ok(!NMISNG::DB::has_admin_capable_user([]),
	"an empty user list has no administrative user");
ok(!NMISNG::DB::has_admin_capable_user(undef),
	"undef is treated as no administrative user (defensive)");
ok(NMISNG::DB::has_admin_capable_user([ _user('root', _role('root', 'admin')) ]),
	"a root user counts as administrative");
ok(NMISNG::DB::has_admin_capable_user([ _user('ua', _role('userAdminAnyDatabase', 'admin')) ]),
	"userAdminAnyDatabase counts as administrative");
ok(NMISNG::DB::has_admin_capable_user([ _user('ua', _role('userAdmin', 'admin')) ]),
	"userAdmin on the admin db counts as administrative");
ok(!NMISNG::DB::has_admin_capable_user([ _user('ua', _role('userAdmin', 'nmisng')) ]),
	"userAdmin on a non-admin db does NOT count");
ok(!NMISNG::DB::has_admin_capable_user([ _user('rw', _role('readWrite', 'admin')) ]),
	"readWrite on admin does NOT count");
ok(NMISNG::DB::has_admin_capable_user([
		_user('nmis9RW', _role('dbOwner', 'nmisng')),
		_user('opUserRW', _role('root', 'admin')) ]),
	"a real admin alongside the scoped user counts as administrative");

done_testing();
