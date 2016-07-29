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

# single depth directories
my %done;
for my $location ($C->{'<nmis_data>'}, # commonly same as base
									$C->{'<nmis_base>'},
									$C->{'<nmis_admin>'}, $C->{'<nmis_bin>'}, $C->{'<nmis_cgi>'},
									$C->{'<nmis_models>'},
									$C->{'<nmis_logs>'},
									$C->{'log_root'}, # should be the same as nmis_logs
									$C->{'config_logs'},
									$C->{'json_logs'},
									$C->{'<menu_base>'},
									$C->{'report_root'},
									$C->{'script_root'}, # commonly under nmis_conf
									$C->{'plugin_root'}, ) # ditto
{
	setFileProtDirectory($location, "false") 	if (!$done{$location});
	$done{$location} = 1;
}

# deeper dirs with recursion
%done = ();
for my $location ($C->{'<nmis_base>'}."/lib",
									$C->{'<nmis_conf>'},
									$C->{'<nmis_var>'},
									$C->{'<nmis_menu>'},
									$C->{'mib_root'},
									$C->{'database_root'},
									$C->{'web_root'}, )
{
	setFileProtDirectory($location, "true") 	if (!$done{$location});
	$done{$location} = 1;
}

exit 0;
