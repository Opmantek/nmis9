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
# a small update plugin for linking radwin hbs objects to managed nodes in the nmis gui

package RadwinWireless;
our $VERSION = "2.0.0";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# does this devices collect HBS information?
	my $hbsids = $S->nmisng_node->get_inventory_ids(
		concept => "HBS",
		filter => { historic => 0 });
	
	return (0,undef) if (!@$hbsids);
	my $changesweremade = 0;

	$NG->log->info("Working on $node HBS");

	for my $hbsid (@$hbsids)
	{
		my ($hbsinventory,$error) = $S->nmisng_node->inventory(_id => $hbsid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $hbsid: $error");
			next;
		}

		my $hbsdata = $hbsinventory->data; # r/o copy, must be saved back if changed
		my $name = $hbsdata->{hsuName};

		# is there a managed node with the given hsuName?
		my $managednode = $NG->node(name => $name);
		if (ref($managednode) eq "NMISNG::Node")
		{
			$changesweremade = 1;
			
			$hbsdata->{hsuName_url} = "$C->{network}?act=network_node_view&node=$name";
			$hbsdata->{hsuName_id} = "node_view_$name";
			# futureproofing so that opCharts can also use this linkage safely
			$hbsdata->{node_uuid} = $managednode->uuid;

			$hbsinventory->data($hbsdata); # set changed info
			(undef,$error) = $hbsinventory->save; # and save it to db
			$NG->log->error("Failed to save inventory for $hbsid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
