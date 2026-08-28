#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
# *****************************************************************************
#
# OMK-12707: the default Access policy must not let non-admins write the
# Users/Access/Config/PrivMap/AuthLdapPrivs/Tables/Logs tables, and the code
# must enforce admin-only access to those rights even if a (stale or
# tampered) live Access table still grants them. The enforcement is gated
# by config auth_lock_sensitive_tables (default on) so an admin can
# consciously opt back into matrix-driven behaviour.
#
# This test needs no database and no live conf/.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use Test::More;

use NMISNG::Util;
use NMISNG::Auth;
use Compat::NMIS;

# rights the code guard forces admin-only regardless of the Access matrix.
# Derived from NMISNG::Auth so a right added to the guard cannot be missed here.
my @guard_rights = NMISNG::Auth::admin_only_rights();
ok(scalar(@guard_rights), "admin_only_rights() returns a non-empty guard list");

# the guard list minus named exemptions, so a right added to the guard is
# checked against the shipped defaults too.
my %default_exempt = (
	# default grant owned by PR #11; OMK-12707 only adds it to the code guard
	table_services_rw => 1,
);
my @default_admin_rights = grep { !$default_exempt{$_} } @guard_rights;

# part 1: shipped defaults in conf-default/Access.nmis are admin-only.
# pass an explicit empty conf so readFiletoHash does not fall back to
# loadConfTable (which would read and create live conf/) - the test must
# not depend on or mutate a live install.
my $defaults = NMISNG::Util::readFiletoHash(
	file => "$FindBin::Bin/../conf-default/Access.nmis", conf => {});
isnt(ref($defaults), "", "conf-default/Access.nmis is loadable");

for my $right (@default_admin_rights)
{
	ok(ref($defaults->{$right}) eq "HASH", "$right exists in default Access table");
	is($defaults->{$right}->{level0}, 1, "$right granted to administrator (level0)");
	for my $level (1..5)
	{
		is($defaults->{$right}->{"level$level"}, 0,
			 "$right denied to level$level in shipped defaults");
	}
}

# part 2: CheckAccessCmd and CheckButton must deny the sensitive rights to
# non-admins even when the Access matrix grants them - that is the case on
# upgraded installs whose live conf/Access.nmis predates this fix.
my %permissive_matrix = map { $_ => { map { ("level$_" => 1) } (0..5) } }
		(@guard_rights, "table_contacts_rw");

my %fake_tables_registry = ( Users => {}, Contacts => {} );

no warnings 'redefine';
local *Compat::NMIS::loadGenericTable = sub {
	my ($name) = @_;
	return \%permissive_matrix if ($name eq "Access");
	return \%fake_tables_registry if ($name eq "Tables");
	return {};
};
# logAuth() loads live config and opens the auth log; an allowed CheckButton
# reaches it. Stub it so the test stays free of the filesystem and live conf/.
local *NMISNG::Util::logAuth = sub { return; };
use warnings 'redefine';

my $auth = NMISNG::Auth->new(conf => { auth_require => 1 });
$auth->{_require} = 1;
$auth->{user} = "testvictim";

for my $level (1, 2, 5)
{
	$auth->{privlevel} = $level;
	for my $right (@guard_rights)
	{
		ok(!$auth->CheckAccessCmd($right),
			 "CheckAccessCmd denies $right to privlevel $level despite permissive matrix");
		ok(!$auth->CheckButton($right),
			 "CheckButton denies $right to privlevel $level despite permissive matrix");
	}
	# non-sensitive rights must still follow the matrix
	ok($auth->CheckAccessCmd("table_contacts_rw"),
		 "CheckAccessCmd still grants table_contacts_rw to privlevel $level per matrix");
}

$auth->{privlevel} = 0;
for my $right (@guard_rights)
{
	ok($auth->CheckAccessCmd($right),
		 "CheckAccessCmd grants $right to administrator (privlevel 0)");
}

# the check must be case-insensitive like the rest of the access machinery
$auth->{privlevel} = 1;
ok(!$auth->CheckAccessCmd("Table_Users_rw"),
	 "CheckAccessCmd denies Table_Users_rw (mixed case) to privlevel 1");

# part 4: the code guard is gated by config auth_lock_sensitive_tables.
# Absent, or any value that is not an explicit boolean-false, => enforce
# (fail-secure). An explicit false value => defer to the Access matrix,
# restoring the pre-fix behaviour for admins who consciously opt out.
$auth->{privlevel} = 1;						# manager, matrix (permissive) grants

# absent key => enforced despite the permissive matrix
delete $auth->{config}->{auth_lock_sensitive_tables};
ok(!$auth->CheckAccessCmd("table_users_rw"),
	 "guard enforced when auth_lock_sensitive_tables absent (default on)");

# explicit true => enforced
$auth->{config}->{auth_lock_sensitive_tables} = "true";
ok(!$auth->CheckAccessCmd("table_users_rw"),
	 "guard enforced when auth_lock_sensitive_tables=true");

# only an exact, documented false token disables the guard. Anything else -
# including junk that merely starts with n/f/0 - must keep it enforced, so a
# malformed value fails secure rather than silently unlocking.
for my $val ("", "on", "1", "enabled", "off", "disabled",
						 "none", "null", "nil", "nope", "0x0", "false-ish", "fanciful")
{
	$auth->{config}->{auth_lock_sensitive_tables} = $val;
	ok(!$auth->CheckAccessCmd("table_users_rw"),
		 "guard stays enforced for non-false value '$val' (fail-secure)");
}

# an exact false token (any case, surrounding space ok) => defer to matrix
for my $val ("false", "no", "0", "FALSE", "No", "  false  ")
{
	$auth->{config}->{auth_lock_sensitive_tables} = $val;
	ok($auth->CheckAccessCmd("table_users_rw"),
		 "guard defers to matrix for explicit false token '$val' (old behaviour)");
}
$auth->{config}->{auth_lock_sensitive_tables} = "false";
ok($auth->CheckButton("table_users_rw"),
	 "CheckButton also defers when auth_lock_sensitive_tables=false");

# with the guard disabled, an unmapped (matrix-denied) right is still denied
ok(!$auth->CheckAccessCmd("table_bogus_rw"),
	 "guard-disabled still denies a right the matrix does not grant");

# an administrator is unaffected by the flag
$auth->{privlevel} = 0;
ok($auth->CheckAccessCmd("table_users_rw"),
	 "administrator allowed regardless of auth_lock_sensitive_tables");
delete $auth->{config}->{auth_lock_sensitive_tables};
$auth->{privlevel} = 1;

# part 3: deny-by-default allowlist - only tables present in the Tables
# registry are acceptable write targets for the table editor.
can_ok("NMISNG::Auth", "TableRegistered");

ok($auth->TableRegistered("Users"), "TableRegistered accepts registered table Users");
ok($auth->TableRegistered("Contacts"), "TableRegistered accepts registered table Contacts");
ok(!$auth->TableRegistered("Bogus"), "TableRegistered rejects unknown table");
ok(!$auth->TableRegistered("users"), "TableRegistered is case-sensitive (users ne Users)");
ok(!$auth->TableRegistered(""), "TableRegistered rejects empty table name");
ok(!$auth->TableRegistered(undef), "TableRegistered rejects undef table name");
ok(!$auth->TableRegistered("../../etc/passwd"), "TableRegistered rejects path traversal");

done_testing();
