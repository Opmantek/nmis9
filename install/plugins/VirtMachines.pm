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
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# does this node host virtual machines?
	my $vmitems = $S->nmisng_node->get_inventory_ids(
		concept => "VirtMachines",
		filter => { historic => 0 });
	
	return (0,undef) if (!@$vmitems);
	my $changesweremade = 0;

	$NG->log->info("Working on $node VirtMachines");

	for my $vmid (@$vmitems)
	{
		my ($vminventory,$error) = $S->nmisng_node->inventory(_id => $vmid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $vmid: $error");
			next;
		}
		
		my $vmdata = $vminventory->data;	# r/o copy, must be saved back if changed
		my $vmName = 	$vmdata->{vmwVmDisplayName};

		# is there a managed node with the given vmwVmDisplayName?
		my $managednode = $NG->node(name => $vmName);
		if (ref($managednode) eq "NMISNG::Node")
		{
			$changesweremade = 1;

			$NG->log->debug("Updating VM linkage for $vmName");
			# futureproofing so that opCharts can also use this linkage safely
			$vmdata->{node_uuid} = $managednode->uuid;

			# nmis systemhealth view
			$vmdata->{vmwVmDisplayName_url} 
			= "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_node_view&node=$vmName";
			$vmdata->{vmwVmDisplayName_id} = "node_view_$vmName";

			$vminventory->data($vmdata); # set changed info
			(undef,$error) = $vminventory->save;
			$NG->log->error("Failed to save inventory for $vmid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
