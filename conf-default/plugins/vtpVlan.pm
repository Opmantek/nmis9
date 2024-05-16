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
# small update plugin to provide vtpVlan linkage for the nmis gui

package vtpVlan;
our $VERSION = "2.0.2";

use strict;
use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect vtp information?
	my $vtpids = $S->nmisng_node->get_inventory_ids(
		concept => "vtpVlan",
		filter => { historic => 0 });

	return (0,undef) if (!@$vtpids);
	my $changesweremade = 0;

	$NG->log->info("Working on $node vtpVlan");

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

	for my $vtpid (@$vtpids)
	{
		my $mustsave;

		my ($vtpinventory,$error) = $S->nmisng_node->inventory(_id => $vtpid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $vtpid: $error");
			next;
		}

		my $vtpdata = $vtpinventory->data; # r/o copy, must be saved back if changed

		# get the VLAN ID Number from the index
		my @parts = split(/\./, $vtpdata->{index});
		if (@parts)
		{
			# first component is irrelevant, second we keep
			$vtpdata->{vtpVlanIndex} = $parts[1]; # note vtpvlanindex, not vtpvlanifindex
			$changesweremade = $mustsave = 1;
		}
		else {
			$NG->log->error("Failed to get vlan id from vtp index: $vtpdata->{index} @parts");
		}

		$NG->log->debug4(sub {"vtpVlan Data: ". Dumper $vtpdata});

		# get the interface's ifDescr and add linkage
		my $ifIndex = $vtpdata->{vtpVlanIfIndex};

		if (ref($ifdata{$ifIndex}) eq "HASH"
				&& defined $ifdata{$ifIndex}->{ifDescr})
		{
			$vtpdata->{ifDescr} = $ifdata{$ifIndex}->{ifDescr};
			$vtpdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$ifIndex&node=$node";
			$vtpdata->{ifDescr_id} = "node_view_$node";

			$changesweremade = $mustsave = 1;
		}
		else {
			$vtpdata->{ifDescr} = "Not supported by SNMP agent";
			$changesweremade = $mustsave = 1;
		}

		if ($mustsave)
		{
			$vtpinventory->data($vtpdata); # set changed info
			(undef,$error) = $vtpinventory->save; # and save to the db # update not required
			$NG->log->error("Failed to save inventory for $vtpid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
