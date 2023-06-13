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
# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs
# into a more human-friendly form, plus interface linkage - for non-cisco devices!

# Cisco NXOS also uses the dot1q MAC Table.
# you get the list of VLAN's from vtpVlan
# you get the bridge port mapping to ifIndex from dot1dBasePort
# you get the list of MAC addresses in dotted decimal form
# you can then link the port to the ifIndex and get the interface the MAC address is on.

package dot1qMacTable;
our $VERSION = "3.0.0";

use strict;

use NMISNG::Util;												# for beautify_physaddress
use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $changesweremade = 0;
	# anything to do? non-cisco only
	# that's r/o
	# Cisco supports dot1QMacTable now!
	#my $catchalldata = $S->inventory( concept => 'catchall' )->data();
	#return (0,undef) if ($catchalldata->{nodeVendor} =~ /Cisco/);

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "interface",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	$NG->log->debug6("ifdata: ". Dumper \%ifdata);

	# get a lookup of base mapping port to ifIndex
	my $dot1dBasePortIndex;
	my $baseids = $S->nmisng_node->get_inventory_ids(
		concept => "dot1dBasePort",
		filter => { historic => 0 });

	if (@$baseids) {
		$NG->log->info("Working on $node dot1dBasePort");

		for my $baseid (@$baseids)
		{
			my $mustsave = 0;

			my ($baseinventory,$error) = $S->nmisng_node->inventory(_id => $baseid);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $baseid: $error");
				next;
			}
			my $basedata = $baseinventory->data; # r/o copy, must be saved back if changed
			$dot1dBasePortIndex->{$basedata->{cieIfDot1dBaseMappingPort}} = $basedata->{index};
		}
	}
	else {
		$NG->log->error("Error, no inventory data found for dot1dBasePort");	
	}
	
	
	# does this node collect macTable information?
	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => "macTable",
		filter => { historic => 0 });
	return (0,undef) if (!@$ids);

	$NG->log->info("Working on $node macTable");

	for my $mactid (@$ids)
	{
		my $mustsave = 0;

		my ($mactinventory,$error) = $S->nmisng_node->inventory(_id => $mactid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $mactid: $error");
			next;
		}

		my $macdata = $mactinventory->data; # r/o copy, must be saved back if changed

		# look for interface linkage
		my $ifIndex = $macdata->{dot1qTpFdbPort};
		my $gotIfIndex = 0;
		if (ref($ifdata{$ifIndex}) eq "HASH")
		{
			# simple data model like a NetGear
			$gotIfIndex = 1;
		}
		# that didn't work, how about using the dot1dTpFdbPort as the cieIfDot1dBaseMappingPort
		elsif (ref($ifdata{ $dot1dBasePortIndex->{$macdata->{dot1qTpFdbPort}} }) eq "HASH") {
			$ifIndex = $dot1dBasePortIndex->{$macdata->{dot1qTpFdbPort}};
			$gotIfIndex = 1;
		}

		if ($gotIfIndex)
		{
			if (defined $ifdata{$ifIndex}->{ifDescr})
			{
				$macdata->{ifDescr} = $ifdata{$ifIndex}->{ifDescr};
				$macdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$ifIndex&node=$node";
				$macdata->{ifDescr_id} = "node_view_$node";
				$changesweremade = $mustsave = 1;
			}

			if ( defined $ifdata{$ifIndex}->{Description} )
			{
				$macdata->{Description} = $ifdata{$ifIndex}->{Description};
				$changesweremade = $mustsave = 1;
			}
		}

		# check for N.M structured index first is vlan, rest is mac address
		if ((my @octets = split(/\./, $macdata->{index}, 2)) == 2)
		{
			$macdata->{vlan} = $octets[0];
			# is this a numeric encoded MAC address or a 
			if ( $octets[1] =~ /\d+\.\d+\.\d+\.\d+\.\d+\.\d+/ ) {
				my @nibbles = split(/\./, $octets[1]);
				my @hexBits;
				foreach my $nibble (@nibbles) {
					push(@hexBits, sprintf("%02x", $nibble) );
				}
				$macdata->{dot1qTpFdbAddress} = join(":", @hexBits);

			}
			#Q-BRIDGE-MIB::dot1qTpFdbStatus.1.'..?5?c'
			else {
				$macdata->{dot1qTpFdbAddress} = NMISNG::Util::beautify_physaddress($octets[1]);	
			}
			

			$changesweremade = $mustsave = 1;
		}

		$NG->log->debug4("macDaddy: ". Dumper $macdata);

		if ($mustsave)
		{
			$mactinventory->data($macdata); # set changed info
			(undef,$error) = $mactinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $mactid: $error")
					if ($error);
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
