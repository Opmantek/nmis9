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
# a small update plugin for converting the mac addresses 
# in ciscorouter addresstables into a more human-friendly form,
# and produces linkage for the nmis gui
#
package addressTable;
our $VERSION = "2.0.0";

use strict;
use NMISNG::Util;								# for beautify_physaddress

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect addresstable items?
	my $atitems = $S->nmisng_node->get_inventory_ids(
		concept => "addressTable",
		filter => { historic => 0 });
	
	return (0,undef) if (!@$atitems);
	my $changesweremade = 0;

	$NG->log->info("Working on $node addressTable");

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	my $ifmodeldata = $S->nmisng_node->get_inventory_model(concept => "interface",
																												 filter => { historic => 0 });
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$ifmodeldata->data});

	for my $atid (@$atitems)
	{
		my ($atinventory,$error) = $S->nmisng_node->inventory(_id => $atid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $atid: $error");
			next;
		}

		my $atdata = $atinventory->data; # r/o copy, must be saved back if changed

		my $macaddress = 	$atdata->{ipNetToMediaPhysAddress};
		my $nice = NMISNG::Util::beautify_physaddress($macaddress);
		
		if ($nice ne $macaddress)
		{
			$atdata->{ipNetToMediaPhysAddress} = $nice;
			$changesweremade = 1;
		}

		my $atindex = $atdata->{ipNetToMediaIfIndex};
		# is there an interface with a matching ifindex?
		if ( ref($ifdata{$atindex}) eq "HASH"
				 && defined $ifdata{$atindex}->{ifDescr})
		{
			$atdata->{ifDescr} = $ifdata{$atindex}->{ifDescr};
			$atdata->{ifDescr_url} = "/cgi-nmis8/network.pl?act=network_interface_view&intf=$atindex&node=$node";
			$atdata->{ifDescr_id} = "node_view_$node";
			$changesweremade = 1;
		}

		if ($changesweremade)
		{
			$atinventory->data($atdata); # set changed info
			(undef,$error) = $atinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $atid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
