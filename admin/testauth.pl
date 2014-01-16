#!/usr/bin/perl
#
## $Id: testemail.pl,v 1.3 2012/09/18 01:40:59 keiths Exp $
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
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMIS;
use func;
use Auth;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});
my $CT = loadContactsTable();

my $username = "nmis";
my $password = "opmantek";
#my $password = "nm1888";

# NMIS Authentication module
use Auth;
my $logoutButton;
my $privlevel = 5;
my $user;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS configuration

if($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") {
	print "ERROR: This test will not validate APACHE based authentication\n";
}

my $testauth = $AU->loginout(type=>"",username=>$username,password=>$password,headeropts=>$headeropts);

if ( $testauth ) {
	my $cookie = join(",",@{$AU->{cookie}});
	print "AUTH SUCCESS: user=$AU->{user}, level=$AU->{privlevel} cookie=$cookie\n";
}
else {
	print "AUTH FAILURE\n";
}
