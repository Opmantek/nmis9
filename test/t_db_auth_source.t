#!/usr/bin/perl
# OMK-12826: DB.pm authenticates against db_auth_source when set (authSource),
# and keeps the driver default (admin) when it is absent, so legacy installs are
# unchanged. Pure unit test of the arg-building helper; no Mongo needed.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => 'nmisng' }) ],
	[ db_name => 'nmisng' ],
	"sets db_name => nmisng when db_auth_source is set");

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => '' }) ], [],
	"empty db_auth_source adds nothing (legacy: driver defaults to admin)");

is_deeply([ NMISNG::DB::_auth_source_args({}) ], [],
	"absent db_auth_source adds nothing (legacy)");

done_testing();
