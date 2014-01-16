#!/usr/bin/perl
#
## $Id: import_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use Sys;

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will create missing Authorisation records for a defined Table Name.
ERROR: needs to know what table to work on.
usage: $0 <TABLE NAME>
eg: $0 BusinessService

EO_TEXT
	exit 1;
}

if ( not -f $ARGV[0] ) {
	nmis_auth($ARGV[0]);
}
else {
	print "ERROR: $ARGV[0] already exists, exiting\n";
	exit 1;
}

sub nmis_auth {
	my $table = shift;
	print "Checking NMIS Authorisation for $table\n";
	# Load the NMIS Auth Table
	my $auth_rw_name = "Table_". $table ."_rw";
	my $auth_rw_key = lc($auth_rw_name);
	
	my $auth_view_name = "Table_". $table ."_view";
	my $auth_view_key = lc($auth_view_name);
	
	if( my $AC = loadAccessTable() ) {
		if ( $AC->{"$auth_rw_key"}{"name"} ne $auth_rw_name ) {
			print "INFO: Authorisation NOT defined for $table RW Access, ADDING IT NOW\n";	
		  $AC->{"$auth_rw_key"} = {
		    'level0' => '1',
		    'level1' => '1',
		    'level2' => '1',
		    'level3' => '0',
		    'level4' => '0',
		    'level5' => '0',
		    'group' => 'access',
		    'name' => $auth_rw_name,
		    'descr' => 'View access to table $table'
		  };
		}
		else {
			print "Authorisation defined for $table RW Access\n";	
		}

		if ( $AC->{"$auth_view_key"}{"name"} ne $auth_view_name ) {
			print "INFO: Authorisation NOT defined for $table View Access, ADDING IT NOW\n";	
		  $AC->{"$auth_view_key"} = {
		    'level0' => '1',
		    'level1' => '1',
		    'level2' => '1',
		    'level3' => '1',
		    'level4' => '0',
		    'level5' => '0',
		    'group' => 'access',
		    'name' => $auth_view_name,
		    'descr' => 'Read/write access to table $table'
		  };
		}
		else {
			print "Authorisation defined for $table View Access\n";	
		}

		writeTable(dir=>'conf',name=>"Access",data=>$AC);
	}
	else
	{
		print "ERROR: problem loading NMIS Access Table\n";
	}
}

