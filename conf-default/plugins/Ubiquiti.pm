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
# a small update plugin that produces gui linkage between airmax interfaces
# and the actual interface

package Ubiquiti;
our $VERSION = "2.0.1";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# does this node have airmax information?
	my $amitems = $S->nmisng_node->get_inventory_ids(
		concept => "AirMax",
		filter => { historic => 0 });

	return (0,undef) if (!@$amitems);
	my $changesweremade = 0;

	$NG->log->info("Working on $node Ubquity AirMax");

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
																										filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	for my $amid (@$amitems)
	{
		my ($aminventory,$error) = $S->nmisng_node->inventory(_id => $amid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $amid: $error");
			next;
		}

		my $airmaxdata = $aminventory->data; # r/o copy, must be saved back if changed
		my $airmaxindex = $airmaxdata->{ubntAirMaxIfIndex};

		if (ref($ifdata{$airmaxindex}) eq "HASH"
				&& defined($ifdata{$airmaxindex}->{ifDescr}))
		{

			$airmaxdata->{ifDescr} = $ifdata{$airmaxindex}->{ifDescr};
			$airmaxdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$airmaxindex&node=$node";
			$airmaxdata->{ifDescr_id} = "node_view_$node";
			$changesweremade = 1;

			$aminventory->data($airmaxdata); # set changed info
			(undef,$error) = $aminventory->save; # update not required
			$NG->log->error("Failed to save inventory for $amid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
