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
# a small update plugin for handling various Cisco features
# like CBQoS and Netflow; produces linkages for the gui

package Cisco_Features;
our $VERSION = "2.0.1";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $changesweremade = 0;

	# cpu_cpm needs to be checked and linked to entitymib items
	my $cpuids = $S->nmisng_node->get_inventory_ids(
		concept => "cpu_cpm",
		filter => { historic => 0 });
	if (@$cpuids)
	{
		$NG->log->info("Working on $node cpu_cpm");

		# for linkage lookup this needs the entitymib inventory as well, but
		# a non-object r/o copy of just the data (no meta) is enough
		my $result = $S->nmisng_node->get_inventory_model(
			concept => "entityMib",
			filter => { historic => 0 });
		if (my $error = $result->error)
		{
			$NG->log->error("Failed to get inventory: $error");
			return(0,undef);
		}

		my %emibdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

		for my $cpuid (@$cpuids)
		{
			my ($cpuinventory,$error) = $S->nmisng_node->inventory(_id => $cpuid);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $cpuid: $error");
				next;
			}

			my $cpudata = $cpuinventory->data; # r/o copy, must be saved back if changed
			my $entityIndex = $cpudata->{cpmCPUTotalPhysicalIndex};

			if (ref($emibdata{$entityIndex}) eq "HASH")
			{
				$cpudata->{entPhysicalName} =
						$emibdata{$entityIndex}->{entPhysicalName};
				$cpudata->{entPhysicalDescr} =
						$emibdata{$entityIndex}->{entPhysicalDescr};

				$changesweremade = 1;

				$cpuinventory->data($cpudata); # set changed info
				(undef,$error) = $cpuinventory->save; # and save to the db
				$NG->log->error("Failed to save inventory for $cpuid: $error")
						if ($error);
			}
			else
			{
				$NG->log->info("entityMib data not available for index $entityIndex");
			}
		}
	}

	# both qos and netflow magic needs this
	# for the interface linkage lookup this needs the interfaces inventory
	# as well, but a non-object r/o copy of just the data (no meta) is enough
	my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
																										filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	# cisco-cbqos items need to be linked to interfaces
	# does that node collect cisco-type qos information?
	my $qosids = $S->nmisng_node->get_inventory_ids(
		concept => "Cisco_CBQoS",
		filter => { historic => 0 });

	if (@$qosids)
	{
		$NG->log->info("Working on $node Cisco_CBQoS");

		for my $qosid (@$qosids)
		{
			my ($qosinventory,$error) = $S->nmisng_node->inventory(_id => $qosid);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $qosid: $error");
				next;
			}

			my $qosdata = $qosinventory->data; # r/o copy, must be saved back if changed
			my $index = $qosdata->{cbQosIfIndex};

			if ( ref($ifdata{$index}) eq "HASH"
					 and defined($ifdata{$index}->{ifDescr}))
			{
				$qosdata->{ifDescr} = $ifdata{$index}->{ifDescr};
				$qosdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$index&node=$node";
				$qosdata->{ifDescr_id} = "node_view_$node";
				$qosdata->{Description} = $ifdata{$index}->{Description};

				$changesweremade = 1;

				$qosinventory->data($qosdata); # set changed info
				(undef,$error) = $qosinventory->save; # and save to the db
				$NG->log->error("Failed to save inventory for $qosid: $error")
						if ($error);
			}
		}
	}

	# similar linking for  netflowinterfaces
	my $nfids = $S->nmisng_node->get_inventory_ids(
		concept => "NetFlowInterfaces",
		filter => { historic => 0 });

	if (@$nfids)
	{
		$NG->log->info("Working on $node NetFlowInterfaces");

		for my $nfid (@$nfids)
		{
			my ($nfinventory,$error) = $S->nmisng_node->inventory(_id => $nfid);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $nfid: $error");
				next;
			}

			my $nfdata = $nfinventory->data; # r/o copy, must be saved back if changed
			my $index = $nfdata->{index};

			if (ref($ifdata{$index}) eq "HASH"
					&& defined($ifdata{$index}->{ifDescr}))
			{

				$nfdata->{ifDescr} = $ifdata{$index}->{ifDescr};
				$nfdata->{ifDescr_url} = "$C->{network}?conf=$C->{conf}&act=network_interface_view&intf=$index&node=$node";
				$nfdata->{ifDescr_id} = "node_view_$node";
				$nfdata->{Description} = $ifdata{$index}->{Description};

				$changesweremade = 1;

				$nfinventory->data($nfdata); # set changed info
				(undef,$error) = $nfinventory->save; # and save to the db
				$NG->log->error("Failed to save inventory for $nfid: $error")
						if ($error);
			}
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
