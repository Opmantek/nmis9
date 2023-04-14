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
# a small update plugin that copies ent phys descr from entitymib to cempmempool

package ciscoMemory;
our $VERSION = "2.0.1";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# node must have have data for both entityMib and cempMemPool to be relevant
	my $cempids = $S->nmisng_node->get_inventory_ids(
		concept => "cempMemPool",
		filter => { historic => 0 });
	return (0,undef) if (!@$cempids);

	# for linkage lookup this needs the entitymib inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# but it's likely  that an individual lookup, on-demand and later would be faster?
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "entityMib",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}

	my %emibdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	return (0,undef) if (!keys %emibdata);
	my $changesweremade = 0;

	$NG->log->info("Working on $node cempMemPool");

	for my $cempid (@$cempids)
	{
		my ($cempinventory,$error) = $S->nmisng_node->inventory(_id => $cempid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $cempid: $error");
			next;
		}

		my $cempdata = $cempinventory->data; # r/o copy, must be saved back if changed

		# note that split returns everything if no . is present...
		my ($entityIndex,undef) = split(/\./, $cempdata->{index});

		if (ref($emibdata{$entityIndex}) eq "HASH"
				&& defined($emibdata{$entityIndex}->{entPhysicalDescr}))
		{
			$cempdata->{entPhysicalDescr} = $emibdata{$entityIndex}->{entPhysicalDescr};
			$changesweremade = 1;

			$cempinventory->data($cempdata); # set changed info
			# set the inventory description to a nice string.
			$cempinventory->description( "$emibdata{$entityIndex}->{entPhysicalName} - $cempdata->{MemPoolName}");

			(undef,$error) = $cempinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $cempid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
