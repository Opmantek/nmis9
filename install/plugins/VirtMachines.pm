#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# a small update plugin for adding links to the vmware guests 
# if they're managed by nmis

package VirtMachines;
our $VERSION = "2.0.0";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	# does this node host virtual machines?
	my $vmitems = $S->nmisng_node->get_inventory_ids(
		concept => "VirtMachines",
		filter => { historic => 0 });
	
	return (0,undef) if (!@$vmitems);
	my $changesweremade = 0;

	$S->nmisng->log->info("Working on $node VirtMachines");

	for my $vmid (@$vmitems)
	{
		my ($vminventory,$error) = $S->nmisng_node->inventory(_id => $vmid);
		if ($error)
		{
			$S->nmisng->log->error("Failed to get inventory $vmid: $error");
			next;
		}
		
		my $vmdata = $vminventory->data;	# r/o copy, must be saved back if changed
		my $vmName = 	$vmdata->{vmwVmDisplayName};

		# is there a managed node with the given vmwVmDisplayName?
		if ( defined $S->nmisng->node(name => $vmName) )
		{
			$changesweremade = 1;

			$S->nmisng->log->debug("Updating VM linkage for $vmName");
			$vmdata->{vmwVmDisplayName_url} 
			= "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_node_view&node=$vmName";
			$vmdata->{vmwVmDisplayName_id} = "node_view_$vmName";

			$vminventory->data($vmdata); # set changed info
			(undef,$error) = $vminventory->save;
			$S->nmisng->log->error("failed to save inventory for $vmid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
