#!/usr/bin/perl
# OMK-12826: DB.pm authenticates against db_auth_source when set (authSource),
# and keeps the driver default (admin) when it is absent, so legacy installs are
# unchanged. Pure unit test of the arg-building helpers; no Mongo needed.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;

# --- 2.x driver path: authSource passed to the client constructor ------------
is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => 'nmisng' }) ],
	[ db_name => 'nmisng' ],
	"sets db_name => nmisng when db_auth_source is set");

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => '' }) ], [],
	"empty db_auth_source adds nothing (legacy: driver defaults to admin)");

is_deeply([ NMISNG::DB::_auth_source_args({}) ], [],
	"absent db_auth_source adds nothing (legacy)");

# --- legacy 1.x driver path: which db(s) the authenticate() loop runs against --
# The legacy driver authenticates at run time by looping authenticate($db,...).
# When db_auth_source is set the scoped user exists ONLY in that source, so the
# loop must target the source alone; the old ('admin', $db_name) pair would fail
# on 'admin' first and never reach the source. When it is unset the pre-OMK-12826
# ('admin', $db_name) behaviour must be preserved exactly.
is_deeply([ NMISNG::DB::_legacy_auth_dbs({ db_auth_source => 'nmisng' }, 'nmisng') ],
	[ 'nmisng' ],
	"legacy auth targets the auth source alone when db_auth_source is set");

is_deeply([ NMISNG::DB::_legacy_auth_dbs({ db_auth_source => 'admin' }, 'nmisng') ],
	[ 'admin' ],
	"legacy auth honours a non-default auth source verbatim");

is_deeply([ NMISNG::DB::_legacy_auth_dbs({ db_auth_source => '' }, 'nmisng') ],
	[ 'admin', 'nmisng' ],
	"legacy auth keeps ('admin', db_name) when db_auth_source is empty");

is_deeply([ NMISNG::DB::_legacy_auth_dbs({}, 'nmisng') ],
	[ 'admin', 'nmisng' ],
	"legacy auth keeps ('admin', db_name) when db_auth_source is absent");

done_testing();
