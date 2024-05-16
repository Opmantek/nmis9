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
# a small update plugin for converting the lldp index into interface name,
# for linkage in the nmis gui

package lldpTable;
our $VERSION = "2.0.1";

use strict;
use NMISNG::Util;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect lldp information?
	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => "lldp",
		filter => { historic => 0 });

	return (0,undef) if (!@$ids);
	my $changesweremade = 0;

	$NG->log->info("Working on $node LLDP Table");

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# we don't want to re-query multiple times for the same interface...
	my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
																										filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get interface inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	# ditto for lldpLocal
	 $result = $S->nmisng_node->get_inventory_model(concept => "lldpLocal",
																									filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get lldpLocal inventory: $error");
		return(0,undef);
	}
	my %lldplocaldata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	for my $lldpid (@$ids)
	{
		my $mustsave;

		my ($lldpinventory,$error) = $S->nmisng_node->inventory(_id => $lldpid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $lldpid: $error");
			next;
		}

		my $data = $lldpinventory->data; # r/o copy, must be saved back if changed

		# decode the hex strings to nice things.
		if ( $data->{lldpRemChassisIdSubtype} eq "macAddress" and $data->{lldpRemChassisId} =~ /^0x/ ) {
			$data->{lldpRemChassisId} = NMISNG::Util::beautify_physaddress($data->{lldpRemChassisId});
		}
		elsif ( $data->{lldpRemChassisIdSubtype} eq "networkAddress" and $data->{lldpRemChassisId} =~ /^0x/ ) {
			$data->{lldpRemChassisId} = join( '.', unpack( 'C4', $data->{lldpRemChassisId} ) );
		}

		if ( $data->{lldpRemPortIdSubtype} eq "macAddress" and $data->{lldpRemPortId} =~ /^0x/ ) {
			$data->{lldpRemPortId} = NMISNG::Util::beautify_physaddress($data->{lldpRemPortId});
		}
		elsif ( $data->{lldpRemPortIdSubtype} eq "interfaceName" and $data->{lldpRemPortId} =~ /^0x/ ) {
			$data->{lldpRemPortId} = pack( 'H*', $data->{lldpRemPortId} );
		}


		my $lldpNeighbour = $data->{lldpRemSysName};

		my @possibleNames = ($lldpNeighbour, lc($lldpNeighbour));
		# IOS with LLDP returns complete FQDN
		if ((my @fqdn = split(/\./,$lldpNeighbour)) > 1)
		{
			push @possibleNames, $fqdn[0], lc($fqdn[0]);
		}

		my $gotNeighbourName = 0;
		for my $maybe (@possibleNames)
		{
			# is there a managed node with the given neighbour name?
			my $managednode = $NG->node(name => $maybe);
			next if (ref($managednode) ne "NMISNG::Node");

			$NG->log->debug("$lldpNeighbour found $maybe for $node");

			$data->{lldpRemSysName_raw} = $data->{lldpRemSysName};
			$data->{lldpRemSysName} = $maybe;
			$data->{lldpRemSysName_url} = "$C->{network}?act=network_node_view&node=$maybe";
			$data->{lldpNeighbour_id} = "node_view_$maybe";
			# futureproofing so that opCharts can also use this linkage safely
			$data->{node_uuid} = $managednode->uuid;

			$changesweremade = $mustsave = $gotNeighbourName =1;
			last;
		}

		# nothing found? look harder - try to match by host property...
		# ...but remember the proper node name
		if ( not $gotNeighbourName )
		{
			for my $maybe (@possibleNames)
			{
				my $managednode = $NG->node(host => $maybe);
				next if (ref($managednode) ne "NMISNG::Node");

				my $propername = $managednode->name;
				$NG->log->debug("$lldpNeighbour found $propername (via host $maybe) for $node");

				$data->{lldpRemSysName_raw} = $data->{lldpRemSysName};
				$data->{lldpRemSysName} = $propername;
				$data->{lldpRemSysName_url} = "$C->{network}?act=network_node_view&node=$propername";
				$data->{lldpNeighbour_id} = "node_view_$propername";
				# futureproofing so that opCharts can also use this linkage safely
				$data->{node_uuid} = $managednode->uuid;

				$changesweremade = $mustsave = $gotNeighbourName =1;
				last;
			}
		}

		# deal with structured index N.M.O...
		if ((my @parts = split(/\./, $data->{index})) > 2)
		{
			$changesweremade = $mustsave = 1;

			# Ignore first, keep second and ...
			my $portnum = $data->{lldpLocPortNum} = $parts[1];
			# ... third.
			if ( @parts == 3 ) { # ... third.
				$data->{lldpDeviceIndex} = $parts[2];
			}
			# ... fourth.
			elsif ( @parts == 4 ) {
				$data->{lldpDeviceIndex} = $parts[3];
			}

			# is the lldpLocPortNum actually the ifIndex?  easy.
			if ( defined $ifdata{$data->{lldpLocPortNum}}{ifDescr} ) {
				$data->{ifDescr} = $ifdata{$portnum}{ifDescr};
				$data->{ifDescr_url} = "$C->{network}?&act=network_interface_view&intf=$portnum&node=$node";
				$data->{ifDescr_id} = "node_view_$node";
				$NG->log->debug("Found an ifDescr entry for $portnum: $data->{ifDescr}");
			}
			# can we find a lldpLocal entry with that portnumber?
			elsif (ref($lldplocaldata{$portnum}) eq "HASH")
			{
				# can we find an interface whose description matches
				# lldpLocPortDesc or lldpLocPortId?
				for my $lldpLocalInt (qw(lldpLocPortDesc lldpLocPortId))
				{
					my $ifDescr = $lldplocaldata{$portnum}->{$lldpLocalInt};
					# do we have an interface with that ifdescr?
					if (my @matches = grep($ifdata{$_}->{ifDescr} eq $ifDescr, keys %ifdata))
					{
						my $ifindex  = $matches[0]; # there should be at most one match
						$data->{lldpIfIndex} = $ifindex;
						$data->{ifDescr} = $ifdata{$ifindex}->{ifDescr};
						$data->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$ifindex&node=$node";
						$data->{ifDescr_id} = "node_view_$node";
						$NG->log->debug("Found an ifDescr entry for $portnum: $data->{ifDescr}");
						last;
					}
				}
			}
		}

		if ($mustsave)
		{
			$lldpinventory->data($data); # set changed info
			(undef,$error) = $lldpinventory->save; # and save to the db, update not required
			$NG->log->error("Failed to save inventory for $lldpid: $error")
					if ($error);
		}

	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
