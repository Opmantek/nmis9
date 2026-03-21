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
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

my $basedir = "$FindBin::Bin/..";
my $auth_args = "auth_username=nmis auth_password=nm1888";

my @tests = (
	{
		name => "no-auth: modules.pl",
		script => "modules.pl",
		args => "",
	},
	{
		name => "standard auth + skip_filter: events.pl",
		script => "events.pl",
		args => "$auth_args act=event_table_list",
	},
	{
		name => "allow_cli: node.pl",
		script => "node.pl",
		args => "$auth_args act=network_node_view",
	},
	{
		name => "allow_cli + set_user: config.pl",
		script => "config.pl",
		args => "$auth_args act=config_nmis",
	},
	{
		name => "allow_cli + set_user + nmisng: tables.pl",
		script => "tables.pl",
		args => "$auth_args act=config_table_list",
	},
);

for my $test (@tests) {
	my $cmd = "perl $basedir/cgi-bin/$test->{script} $test->{args} 2>&1";
	my $output = `$cmd`;
	my $exit_code = $? >> 8;

	is($exit_code, 0, "$test->{name}: exit code 0");
	unlike($output, qr/Can't locate|Undefined subroutine|compilation error|syntax error/i,
		"$test->{name}: no perl errors");
	like($output, qr/Content-Type/i,
		"$test->{name}: produces HTTP Content-Type header");
}

done_testing();
