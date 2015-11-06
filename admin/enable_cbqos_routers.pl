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

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Load the current Nodes Table.
my $LNT = loadLocalNodeTable();

my @group_names = ('DataCenter','put_another_group_here_etc');

my %group_map = map { $_ => 1 } @group_names;

# Go through each of the nodes
foreach my $node (sort keys %{$LNT}) {
	# only work on nodes which are active and collect is true.
	if( $group_map{$LNT->{$node}{group}} == 1)
	{
		print "checking $node\n" if $debug;
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		
		# only update nodes that match a criteria
		if ($NI->{system}{nodeModel} =~ /CiscoRouter/ ) {		
			print "Found Node $node which is a $NI->{system}{nodeModel}\n";
			#Change something with the node
			$LNT->{$node}{cbqos} = "both";
		}
		
	}
}

# Save the results to a new file.
writeHashtoFile(file => "$C->{'<nmis_conf>'}/Nodes.nmis.new", data => $LNT);

print "Nodes table saved as $C->{'<nmis_conf>'}/Nodes.nmis.new\n";
print "Please move this into place to start using, e.g.\n";
print "cp $C->{'<nmis_conf>'}/Nodes.nmis $C->{'<nmis_conf>'}/Nodes.nmis.backup\n";
print "mv $C->{'<nmis_conf>'}/Nodes.nmis.new $C->{'<nmis_conf>'}/Nodes.nmis\n";
