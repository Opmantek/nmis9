#!/usr/bin/perl
#
## $Id: fixperms.pl,v 8.3 2011/11/09 06:16:04 keiths Exp $
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

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

print "This script will fix the permissions for NMIS based on the configuration $C->{configfile}\n";
print "The directory to be processed is: $C->{'<nmis_base>'}\n";
print "The user will be set to: $C->{nmis_user}\n";
print "The group will be set to: $C->{nmis_group}\n";

if ( not $< == 0) { # NOT root
	print "\nWARNING: You are NOT the ROOT user, so this will likely not work well, but we will do our best\n\n";
}
else {	
	my $output = `chown -R $C->{nmis_user}:$C->{nmis_group} $C->{'<nmis_base>'}`;
	print $output;

	my $output = `chmod -R g+rw $C->{'<nmis_base>'}`;
	print $output;
	
	if ( $C->{'<nmis_base>'} ne $C->{'<nmis_data>'} ) {
		my $output = `chown -R $C->{nmis_user}:$C->{nmis_group} $C->{'<nmis_data>'}`;
		print $output;

		my $output = `chmod -R g+rw $C->{'<nmis_data>'}`;
		print $output;
	}
}

setFileProtDirectory($C->{'<nmis_admin>'});
setFileProtDirectory($C->{'<nmis_bin>'});
setFileProtDirectory($C->{'<nmis_cgi>'});
setFileProtDirectory($C->{'<nmis_conf>'});
setFileProtDirectory($C->{'<nmis_data>'});
setFileProtDirectory($C->{'<nmis_logs>'},"true");
setFileProtDirectory($C->{'<nmis_menu>'});
setFileProtDirectory($C->{'<nmis_models>'});
setFileProtDirectory($C->{'<nmis_var>'},"true");
setFileProtDirectory($C->{'config_logs'});
setFileProtDirectory($C->{'database_root'},"true");
setFileProtDirectory($C->{'json_logs'});
setFileProtDirectory($C->{'log_root'});
setFileProtDirectory($C->{'mib_root'});
setFileProtDirectory($C->{'report_root'});
setFileProtDirectory($C->{'script_root'});
setFileProtDirectory($C->{'web_root'});
