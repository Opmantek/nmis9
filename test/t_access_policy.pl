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
# Users/Access/Config/PrivMap/AuthLdapPrivs tables, and the code must
# enforce admin-only access to those rights even if a (stale or tampered)
# live Access table still grants them.
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

my @sensitive_rights = (qw(table_users_rw table_access_rw table_config_rw
													 table_authldapprivs_rw table_privmap_rw));

# part 1: shipped defaults in conf-default/Access.nmis are admin-only
my $defaults = NMISNG::Util::readFiletoHash(
	file => "$FindBin::Bin/../conf-default/Access.nmis");
isnt(ref($defaults), "", "conf-default/Access.nmis is loadable");

for my $right (@sensitive_rights)
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
		(@sensitive_rights, "table_contacts_rw");

my %fake_tables_registry = ( Users => {}, Contacts => {} );

no warnings 'redefine';
local *Compat::NMIS::loadGenericTable = sub {
	my ($name) = @_;
	return \%permissive_matrix if ($name eq "Access");
	return \%fake_tables_registry if ($name eq "Tables");
	return {};
};
use warnings 'redefine';

my $auth = NMISNG::Auth->new(conf => { auth_require => 1 });
$auth->{_require} = 1;
$auth->{user} = "testvictim";

for my $level (1, 2, 5)
{
	$auth->{privlevel} = $level;
	for my $right (@sensitive_rights)
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
for my $right (@sensitive_rights)
{
	ok($auth->CheckAccessCmd($right),
		 "CheckAccessCmd grants $right to administrator (privlevel 0)");
}

# the check must be case-insensitive like the rest of the access machinery
$auth->{privlevel} = 1;
ok(!$auth->CheckAccessCmd("Table_Users_rw"),
	 "CheckAccessCmd denies Table_Users_rw (mixed case) to privlevel 1");

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
