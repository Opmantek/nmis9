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
# a small update plugin for extracting node and interface
# info from cdp data for linkage in the nmis gui

package cdpTable;
our $VERSION = "2.0.1";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect cdp information?
	my $cdpids = $S->nmisng_node->get_inventory_ids(
		concept => "cdp",
		filter => { historic => 0 });

	return (0,undef) if (!@$cdpids);
	my $changesweremade = 0;

	$NG->log->info("Working on $node cdp");

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# we don't want to re-query multiple times for the same interface...
	my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
																										filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	for my $cdpid (@$cdpids)
	{
		my $mustsave;

		my ($cdpinventory,$error) = $S->nmisng_node->inventory(_id => $cdpid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $cdpid: $error");
			next;
		}

		my $cdpdata = $cdpinventory->data; # r/o copy, must be saved back if changed
		my $cdpNeighbour = $cdpdata->{cdpCacheDeviceId};

		# some cdp data includes Serial numbers and FQDN's
		my @possibleNames = ($cdpNeighbour, lc($cdpNeighbour));

		if ( $cdpNeighbour =~ /\(\w+\)$/ )
		{
			my $name = $cdpNeighbour;
			$name =~ s/\(\w+\)$//g;

			push @possibleNames, $name, lc($name);
		}
		if ((my @fqdn = split(/\./,$cdpNeighbour)) > 1)
		{
			push @possibleNames,$fqdn[0], lc($fqdn[0]);
		}

		my $gotNeighbourName = 0;
		foreach my $maybe (@possibleNames)
		{
			# is there a managed node with the given neighbour name?
			my $managednode = $NG->node(name => $maybe);
			if (ref($managednode) eq "NMISNG::Node")
			{
				$changesweremade = $mustsave = 1;

				$cdpdata->{cdpCacheDeviceId_raw} = $cdpdata->{cdpCacheDeviceId};
				$cdpdata->{cdpCacheDeviceId_id} = "node_view_$maybe";
				$cdpdata->{cdpCacheDeviceId_url} = "$C->{network}?&act=network_node_view&node=$maybe";
				$cdpdata->{cdpCacheDeviceId} = $maybe;
				# futureproofing so that opCharts can also use this linkage safely
				$cdpdata->{node_uuid} = $managednode->uuid;

				$gotNeighbourName = 1;
				last;
			}
		}

		# nothing found? look harder - try to match by host property...
		# ...but remember the proper node name
		if ( not $gotNeighbourName )
		{
			for my $maybe (@possibleNames)
			{
				my $managednode = $NG->node(host => $maybe);
				if (ref($managednode) eq "NMISNG::Node")
				{
					$changesweremade = $mustsave = 1;

					my $propername = $managednode->name;
					$cdpdata->{cdpCacheDeviceId_raw} = $cdpdata->{cdpCacheDeviceId};
					$cdpdata->{cdpCacheDeviceId_id} = "node_view_$propername";
					$cdpdata->{cdpCacheDeviceId_url} = "$C->{network}?&act=network_node_view&node=$propername";
					$cdpdata->{cdpCacheDeviceId} = $propername;
					# futureproofing so that opCharts can also use this linkage safely
					$cdpdata->{node_uuid} = $managednode->uuid;

					last;
				}
			}
		}

		# index N.M? split and link to interface
		my $cdpindex = $cdpdata->{index};
		if ((my @parts = split(/\./, $cdpindex)) > 1)
		{
			$changesweremade = $mustsave = 1;

			my $index = $cdpdata->{cdpCacheIfIndex} = $parts[0];
			$cdpdata->{cdpCacheDeviceIndex} = $parts[1];

			if (ref($ifdata{$index}) eq "HASH"
					&& defined($ifdata{$index}->{ifDescr}))
			{
				$cdpdata->{ifDescr} = $ifdata{$index}->{ifDescr};
				$cdpdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$index&node=$node";
				$cdpdata->{ifDescr_id} = "node_view_$node";
			}
		}

		if ($mustsave)
		{
			$cdpinventory->data($cdpdata); # set changed info
			(undef,$error) = $cdpinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $cdpid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
