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
# this update plugin provides modelling for the cisco macTable
# concept, based on post-processing of vtpVlan information
# fixme9: half of this plugin duplicates the vtpVlan plugin!

package ciscoMacTable;
our $VERSION = "2.0.1";

use strict;

use NMISNG::Util;								# for beautify_physaddress
use NMISNG::Snmp;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# does this node need macTable processing as per its model?
	# let's not auto-vivify anything...
	return (0,undef) if (ref($S->{mdl}) ne "HASH"
											 or ref($S->{mdl}->{systemHealth}) ne "HASH"
											 or ref($S->{mdl}->{systemHealth}->{sys}) ne "HASH"
											 or ref($S->{mdl}->{systemHealth}->{sys}->{macTable}) ne "HASH");

	# does this node collect vtp information?
	my $vtpids = $S->nmisng_node->get_inventory_ids(
		concept => "vtpVlan",
		filter => { historic => 0 });

	return (0,undef) if (!@$vtpids);

	my $status = {
		'1' => 'other',
		'2' => 'invalid',
		'3' => 'learned',
		'4' => 'self',
		'5' => 'mgmt',
	};

	my $changesweremade = 0;
	$NG->log->info("Working on $node CiscoMacTable");

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

	my @knownindices; # for marking as non/historic
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
		if ((my @parts = split(/\./, $vtpdata->{index})) > 1)
		{
			# first component is irrelevant, second we keep
			$vtpdata->{vtpVlanIndex} = $parts[1]; # note vtpvlanindex, not vtpvlanifindex
			$changesweremade = $mustsave = 1;
		}

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

		# done with the vtp data - save it back
		if ($mustsave)
		{
			$vtpinventory->data($vtpdata); # set changed info
			(undef,$error) = $vtpinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $vtpid: $error")
					if ($error);
		}

		# now continue with collecting vlan data
		# Get the connected devices if the VLAN is operational
		# note that this requires a new session with a
		# different dynamic community for each vlan!
		if ($vtpdata->{vtpVlanState} eq "operational")
		{
			my %nodeconfig = %{$S->nmisng_node->configuration};

			# community string: <normal>@<vlanindex>
			# https://www.cisco.com/c/en/us/support/docs/ip/simple-network-management-protocol-snmp/40367-camsnmp40367.html
			my $magic = $nodeconfig{community}.'@'.$vtpdata->{vtpVlanIndex};
			$nodeconfig{community} = $magic;

			# nmisng::snmp doesn't fall back to global config
			my $max_repetitions = $nodeconfig{max_repetitions} || $C->{snmp_max_repetitions};

			my $snmp = NMISNG::Snmp->new(name => $node);
			# configuration now contains  all snmp needs to know
			if (!$snmp->open(config => \%nodeconfig))
			{
				$NG->log->error("Could not open SNMP session to node $node: ".$snmp->error);
				undef $snmp;
					next;
			}
			if (!$snmp->testsession)
			{
				$NG->log->error("Could not retrieve SNMP vars from node $node: ".$snmp->error);
				next;
			}

			my $dot1dBasePortIfIndex = "1.3.6.1.2.1.17.1.4.1.2"; #dot1dTpFdbStatus
			my $baseIndex = $snmp->getindex($dot1dBasePortIfIndex,$max_repetitions);

			my $dot1dTpFdbAddress = "1.3.6.1.2.1.17.4.3.1.1"; #dot1dTpFdbAddress
			my $addresses = $snmp->gettable($dot1dTpFdbAddress,$max_repetitions);

			my $dot1dTpFdbPort = "1.3.6.1.2.1.17.4.3.1.2"; #dot1dTpFdbPort
			my $ports = $snmp->gettable($dot1dTpFdbPort,$max_repetitions);

			my $dot1dTpFdbStatus = "1.3.6.1.2.1.17.4.3.1.3"; #dot1dTpFdbStatus
			my $addressStatus = $snmp->gettable($dot1dTpFdbStatus,$max_repetitions);

			$snmp->close; # new community and new session for the next vlan

			if ( ref($ports) eq "HASH" && ref($addresses) eq "HASH")
			{
				$changesweremade = 1;

				foreach my $key (keys %$addresses)
				{
					my $macAddress = NMISNG::Util::beautify_physaddress($addresses->{$key});

					# got to use a different OID for the different queries.
					my $portKey = my $statusKey = $key;
					$portKey =~ s/17.4.3.1.1/17.4.3.1.2/;
					$statusKey =~ s/17.4.3.1.1/17.4.3.1.3/;

					my %newdata = (
						index => $macAddress,
						dot1dTpFdbAddress => $macAddress,
						dot1dTpFdbPort => $ports->{$portKey},
						dot1dTpFdbStatus => $status->{ $addressStatus->{$statusKey} },
						vlan => $vtpdata->{vtpVlanIndex}, );

					if ( defined $ports->{$portKey} )
					{
						my $addressIfIndex = $baseIndex->{ $ports->{$portKey} };

						$newdata{ifDescr} = $ifdata{$addressIfIndex}->{ifDescr};
						$newdata{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$addressIfIndex&node=$node";
						$newdata{ifDescr_id} = "node_view_$node";
					}

					push @knownindices, $newdata{index}; # for marking unwanted remnants as historic

					# now get-or-create an inventory object for this new concept
					#
					my ($inventory, $error) = $S->nmisng_node->inventory(
						create => 1,				# if not present yet
						concept => "macTable",
						data => \%newdata,
						path_keys => ['index'],
						path => $S->nmisng_node->inventory_path( concept => 'macTable',
																										 path_keys => ['index'],
																										 data => \%newdata ) );
					if(!$inventory or $error)
					{
						$NG->log->error("Failed to get inventory for macTable $macAddress: $error");
						next;								# not much we can do in this case...
					}
					$inventory->historic(0);
					$inventory->enabled(1);

					(my $operation, $error) = $inventory->save;
					$NG->log->error("Failed to save inventory for macTable $macAddress: $error") if($error);
				}
			}
		}
	}

	# mark as historic anything unwanted
	$S->nmisng_node->bulk_update_inventory_historic( active_indices => \@knownindices,
																									 concept => "macTable" );
	return ($changesweremade,undef); # report if we changed anything
}

1;
