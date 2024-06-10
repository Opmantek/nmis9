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
our $VERSION = "3.0.1";

use strict;
use warnings;
use Data::Dumper;
use NMISNG::Util;

sub or_terms_to_query_or {
	my ($or_terms) = @_;
	my $query_or = [];
	my $havesomething = 0;
	# take each of the thigns we are or'ing, if the array has > 1 value 
	# use $in, otherwise just match that thing
	foreach my $orrkey (keys %$or_terms) {
		my $size = @{$or_terms->{$orrkey}};
		if( $size > 1 ) {
			push @$query_or, { $orrkey => { '$in' => $or_terms->{$orrkey}}};
			$havesomething = 1;
		} elsif ($size == 1)  {
			push @$query_or, { $orrkey => $or_terms->{$orrkey}[0] };
			$havesomething = 1;
		}
	}
	return ($havesomething) ? $query_or : undef;
}

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

	$NG->log->debug("Working on $node LLDP Table");
	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# we don't want to re-query multiple times for the same interface...
	my $result = $S->nmisng_node->get_inventory_model(concept => "interface", filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get interface inventory: $error");
		return(0,undef);
	}
	my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	my $lldpMD = $S->nmisng_node->get_inventory_model(concept => "lldp", filter => { historic => 0 });
	if (my $error = $lldpMD->error)
	{
		$NG->log->error("Failed to get lldpLocal inventory: $error");
		return(0,undef);
	}
	my $lldpCount = $lldpMD->count();

	# ditto for lldpLocal
	$result = $S->nmisng_node->get_inventory_model(concept => "lldpLocal", filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get lldpLocal inventory: $error");
		return(0,undef);
	}
	my %lldplocaldata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
	
	for(my $i = 0; $i < $lldpCount; $i++)
	{
		my $mustsave = 0;
		my $gotNeighbourName = 0;
		my $lldpinventory = $lldpMD->object($i);
		my $data = $lldpinventory->data; # r/o copy, must be saved back if changed
		
		# decode the hex strings to nice things.		
		if ( $data->{lldpRemChassisIdSubtype} eq "macAddress" and $data->{lldpRemChassisId} =~ /^0x/ ) {
			$data->{lldpRemChassisId_raw} = $data->{lldpRemChassisId};
			$data->{lldpRemChassisId} = NMISNG::Util::beautify_physaddress($data->{lldpRemChassisId});
		}
		elsif ( $data->{lldpRemChassisIdSubtype} eq "networkAddress" and $data->{lldpRemChassisId} =~ /^0x/ ) {
			$data->{lldpRemChassisId_raw} = $data->{lldpRemChassisId};
			$data->{lldpRemChassisId} = join( '.', unpack( 'C4', $data->{lldpRemChassisId} ) );
		}

		if ( $data->{lldpRemPortIdSubtype} eq "macAddress" and $data->{lldpRemPortId} =~ /^0x/ ) {
			$data->{lldpRemPortId_raw} = $data->{lldpRemPortId};
			$data->{lldpRemPortId} = NMISNG::Util::beautify_physaddress($data->{lldpRemPortId});
		}
		elsif ( $data->{lldpRemPortIdSubtype} eq "interfaceName" and $data->{lldpRemPortId} =~ /^0x/ ) {
			$data->{lldpRemPortId_raw} = $data->{lldpRemPortId};
			$data->{lldpRemPortId} = pack( 'H*', $data->{lldpRemPortId} );
		}
		$NG->log->debug4(sub{"lldp data".Dumper($data)});
		# we'll potentially need to look in places, first to see if we can find the name / host/ip in the catchall
		# after that we'll try finding the mac address in the interface inventory


		# first look using lldpRemSysName
		my $lldpNeighbour = $data->{lldpRemSysName};
		# map the names to remove duplicates
		my $possibleNames = {};
		if( $lldpNeighbour ne "" ) {
			$possibleNames->{$lldpNeighbour} = 1;
			$possibleNames->{lc($lldpNeighbour)} = 1;

			# IOS with LLDP returns complete FQDN
			if ((my @fqdn = split(/\./,$lldpNeighbour)) > 1)
			{
				$possibleNames->{$fqdn[0]} = 1;
				$possibleNames->{lc($fqdn[0])} = 1;
			}
		}
		my @possibleNamesArr = map {$_} (keys %$possibleNames);
		my %or_terms = (
			'node_name' => \@possibleNamesArr,
			'data.host' => \@possibleNamesArr,
			'data.sysName' => \@possibleNamesArr
		);
				
		# if the lldpRemChassisIdSubtype is networkAddress we have an IP address that we can look for in host/host_addr
		if ( $data->{lldpRemChassisIdSubtype} eq "networkAddress" ) {
			push @{$or_terms{'data.host'}}, $data->{lldpRemChassisId};
			push @{$or_terms{'data.host_addr'}}, $data->{lldpRemChassisId};
		}
		# if we have an mac address we can search for that too, it will have to go in a different search on interfaces
		my $query_or = or_terms_to_query_or(\%or_terms);
		
		# query_or only returns as structure if we have anything to query
		if( $query_or ) {
			my $query = {'concept' => 'catchall','enabled' => 1,'historic' => 0,
				'$or' => $query_or
			};
			$NG->log->debug2(sub{ "lldpTable looking for names:".join(',',@possibleNamesArr)});
			$NG->log->debug4(sub{ "lldpTable query:".Dumper($query)});
			my $entries = NMISNG::DB::find(
				collection  => $NG->inventory_collection,
				query       => $query,
				fields_hash => { 'node_name' => 1 ,'node_uuid' => 1 }
			);
			
			# get them all, shouldn't be many, hopefully 1
			my @all = $entries->all;
			$NG->log->warn("lldpTable found more than one matching node for lldp, query:".Dumper($query)) if(@all > 1);
			$NG->log->debug4(sub {"lldpTable found matching node for lldp, query:".Dumper(\@all)});
			
			foreach my $entry (@all) {			
				my ($node_name,$node_uuid) = ($entry->{node_name},$entry->{node_uuid});
				$NG->log->debug(sub{ "lldpTable matched $data->{lldpRemSysName}:$data->{lldpRemChassisId} to node: $node_name"});			

				$data->{lldpRemSysName_raw} = $data->{lldpRemSysName};
				$data->{lldpRemSysName} = $node_name;
				$data->{lldpRemSysName_url} = "$C->{network}?act=network_node_view&node=$node_name";
				$data->{lldpNeighbour_id} = "node_view_$node_name";
				# futureproofing so that opCharts can also use this linkage safely
				$data->{node_uuid} = $node_uuid;

				$changesweremade = $mustsave = $gotNeighbourName = 1;
				last;
			}
		}
		# this likely does not make sense, the info is for the chassis and not the port
		# still worth a shot, best chance here is probably 
		if( !$gotNeighbourName ) {
			my %or_terms = ();
			if ( $data->{lldpRemChassisIdSubtype} eq "networkAddress" ) {
				push @{$or_terms{'data.ip.ipAdEntAddr'}}, $data->{lldpRemChassisId};			
				# 'data.host' => \@possibleNamesArr,
				# 'data.sysName' => \@possibleNamesArr
			} elsif( $data->{lldpRemChassisIdSubtype} eq "macAddress" ) {
				push @{$or_terms{'data.ifPhysAddress'}}, $data->{lldpRemChassisId_raw};
			}
			if ( $data->{lldpRemPortIdSubtype} eq "macAddress" ) { # && ($data->{lldpRemPortId_raw} ne $data->{lldpRemChassisId_raw}) ) {
				push @{$or_terms{'data.ifPhysAddress'}}, $data->{lldpRemPortId_raw};
			}
			my $query_or = or_terms_to_query_or(\%or_terms);
			if( $query_or ) {
				my $query = {'concept' => 'interface','enabled' => 1,'historic' => 0, node_uuid => { '$ne' => $S->nmisng_node->uuid },
					'$or' => $query_or
				};
			
				$NG->log->debug4(sub{ "lldpTable query:".Dumper($query)});
				my $entries = NMISNG::DB::find(
					collection  => $NG->inventory_collection,
					query       => $query,
					fields_hash => { 'node_name' => 1 ,'node_uuid' => 1 }
				);
				
				# get them all, shouldn't be many, hopefully 1
				my @all = $entries->all;
				$NG->log->warn("lldpTable found more than one matching node for lldp, query:".Dumper($query)) if(@all > 1);
				$NG->log->debug3(sub {"lldpTable found matching node for lldp, query:".Dumper(\@all)});
				
				foreach my $entry (@all) {			
					my ($node_name,$node_uuid) = ($entry->{node_name},$entry->{node_uuid});
					$NG->log->debug(sub{ "lldpTable matched $data->{lldpRemSysName}:$data->{lldpRemChassisId} to node: $node_name"});			

					$data->{lldpRemSysName_raw} = $data->{lldpRemSysName};
					$data->{lldpRemSysName} = $node_name;
					$data->{lldpRemSysName_url} = "$C->{network}?act=network_node_view&node=$node_name";
					$data->{lldpNeighbour_id} = "node_view_$node_name";
					# futureproofing so that opCharts can also use this linkage safely
					$data->{node_uuid} = $node_uuid;					

					$changesweremade = $mustsave = $gotNeighbourName = 1;
					last;
				}
			}
		}
		
		# now link up the local port info
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
				$NG->log->debug2("Found an ifDescr entry for $portnum: $data->{ifDescr}");
			}
			# can we find a lldpLocal entry with that portnumber?
			elsif (ref($lldplocaldata{$portnum}) eq "HASH" && ref($lldplocaldata{$portnum}->{data}) eq "HASH")
			{
				# can we find an interface whose description matches
				# lldpLocPortDesc or lldpLocPortId?
				for my $lldpLocalInt (qw(lldpLocPortDesc lldpLocPortId))
				{
					my $ifDescr = $lldplocaldata{$portnum}->{data}{$lldpLocalInt};
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
			my (undef,$error) = $lldpinventory->save( node => $node ); # and save to the db, update not required because it wasn't made here
			$NG->log->error("Failed to save inventory for $lldpinventory->{_id}: $error")
					if ($error);
		}

	}

	return ($changesweremade,undef); # report if we changed anything
}

1;





		# nothing found? look harder - look for the mac address on interfaces
		# that we know about		
		# if ( not $gotNeighbourName )
		# {
		# 	# we have 
		# 	if ( $data->{lldpRemChassisIdSubtype} eq "macAddress" ) {
		# 		$data->{lldpRemChassisId_raw}
		# 	}

		# 			# this search will have to use int
		# # if( $cdpdata->{lldpRemChassisIdSubtype} eq 'macAddress' ) {
		# # 	push @{$query->{'$or'}}, { 'data.host' => $cdpdata->{lldpRemChassisId} };
		# # 	push @{$query->{'$or'}}, { 'data.host_addr' => $cdpdata->{lldpRemChassisId} };
		# # 	$NG->log->debug(sub{ "cdpTable looking for macAddress: $cdpdata->{lldpRemChassisId}"});
		# # }


		# # 	# this search will have to use interface table to look up the mac address
		# # 	if( $cdpdata->{lldpRemChassisIdSubtype} eq 'macAddress' ) {
		# # 		push @{$query->{'$or'}}, { 'data.host' => $cdpdata->{lldpRemChassisId} };
		# # 		push @{$query->{'$or'}}, { 'data.host_addr' => $cdpdata->{lldpRemChassisId} };
		# # 		$NG->log->debug(sub{ "cdpTable looking for macAddress: $cdpdata->{lldpRemChassisId}"});
		# # 	}
			
		# 	for my $maybe (@possibleNames)
		# 	{
		# 		my $managednode = $NG->node(host => $maybe);
		# 		next if (ref($managednode) ne "NMISNG::Node");

		# 		my $propername = $managednode->name;
		# 		$NG->log->debug("$lldpNeighbour found $propername (via host $maybe) for $node");

		# 		$data->{lldpRemSysName_raw} = $data->{lldpRemSysName};
		# 		$data->{lldpRemSysName} = $propername;
		# 		$data->{lldpRemSysName_url} = "$C->{network}?act=network_node_view&node=$propername";
		# 		$data->{lldpNeighbour_id} = "node_view_$propername";
		# 		# futureproofing so that opCharts can also use this linkage safely
		# 		$data->{node_uuid} = $managednode->uuid;

		# 		$changesweremade = $mustsave = $gotNeighbourName =1;
		# 		last;
		# 	}
		# }
