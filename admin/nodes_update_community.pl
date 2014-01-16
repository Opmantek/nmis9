#!/usr/bin/perl
#
## $Id: nodes_update_community.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
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

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;

# Get some command line arguements.
my %arg = getArguements(@ARGV);

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Load the current Nodes Table.
my $LNT = loadLocalNodeTable();

# Go through each of the nodes
foreach my $node (sort keys %{$LNT}) {
	# only work on nodes which are active and collect is true.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		
		# only update nodes that match a criteria
		if ($LNT->{$node}{name} =~ /MATCHES SOME CRITERIA/ ) {
			#Change something with the node
			$LNT->{$node}{community} = "NEWCOMMUNITY";
		}
		
	}
}

# To insert a new node, something like below with each property complete
#my $node = "router1";
#$LNT->{$node}{community} = "NEWCOMMUNITY";
#$LNT->{$node}{field1} = "value1";
#$LNT->{$node}{field2} = "value2";
#$LNT->{$node}{field3} = "value3";
#$LNT->{$node}{field4} = "value4";
#$LNT->{$node}{field5} = "value5";

# Save the results to a new file.
writeHashtoFile(file => "$C->{'<nmis_conf>'}/Nodes.nmis.new", data => $LNT);


