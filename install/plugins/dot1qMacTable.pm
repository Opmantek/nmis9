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

package dot1qMacTable;
our $VERSION = "2.0.0";

use strict;

use NMISNG::Util;												# for beautify_physaddress

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? non-cisco only
	# that's r/o
	my $catchalldata = $S->inventory( concept => 'catchall' )->data();
	return (0,undef) if ($catchalldata->{nodeVendor} =~ /Cisco/);

	# does this node collect macTable information?
	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => "macTable",
		filter => { historic => 0 });
	return (0,undef) if (!@$ids);

	$NG->log->info("Working on $node macTable");
	my $changesweremade = 0;

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "interface",
		filter => { historic => 0 });
	
	if (!$result->{success})
	{
		$NG->log->error("Failed to get inventory: $result->{error}");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->{model_data}->data});

	for my $mactid (@$ids)
	{
		my $mustsave;

		my ($mactinventory,$error) = $S->nmisng_node->inventory(_id => $mactid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $mactid: $error");
			next;
		}

		my $macdata = $mactinventory->data; # r/o copy, must be saved back if changed
		my $ifIndex = $macdata->{dot1qTpFdbPort};

		# look for interface linkage
		if (ref($ifdata{$ifIndex}) eq "HASH")
		{
			if (defined $ifdata{$ifIndex}->{ifDescr})
			{
				$macdata->{ifDescr} = $ifdata{$ifIndex}->{ifDescr};
				$changesweremade = $mustsave = 1;
			}

			if ( defined $ifdata{$ifIndex}->{Description} )
			{
				$macdata->{ifAlias} = $ifdata{$ifIndex}->{Description};
				$changesweremade = $mustsave = 1;
			}
		}

		# check for N.M structured index first is vlan, rest is mac address
		if ((my @octets = split(/\./, $macdata->{index}, 2)) == 2)
		{
			$macdata->{vlan} = $octets[0];
			$macdata->{dot1qTpFdbAddress} = NMISNG::Util::beautify_physaddress($octets[1]);

			$changesweremade = $mustsave = 1;
		}

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
