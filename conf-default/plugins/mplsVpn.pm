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
# a small update plugin for converting the cdp index into interface name.

package mplsVpn;
our $VERSION = "2.0.0";

use strict;

use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $nodeobj = $NG->node(name => $node);
	my $IF = $nodeobj->ifinfo;

	my $changesweremade = 0;

	$NG->log->info("Working on mplsVPN for node '$node'");

   #"mplsVpnVrf" : {
   #   "4.105.78.69.84" : {
   #      "mplsVpnVrfAssociatedInterfaces" : 13,
   #      "mplsVpnVrfActiveInterfaces" : 9,
   #      "mplsVpnVrfName" : "iNET",
   #      "mplsVpnVrfCreationTime" : 2831,
   #      "index" : "4.105.78.69.84",
   #      "mplsVpnVrfConfStorageType" : "volatile",
   #      "mplsVpnVrfDescription" : "",
   #      "mplsVpnVrfOperStatus" : "up",
   #      "mplsVpnVrfRouteDistinguisher" : "65500:10001",
   #      "mplsVpnVrfConfRowStatus" : "active"
   #   },
   #"mplsVpnInterface" : {
   #   "4.105.78.69.84.39" : {
   #      "index" : "4.105.78.69.84.39",
   #      "mplsVpnInterfaceVpnClassification" : "enterprise",
   #      "mplsVpnInterfaceVpnRouteDistProtocol" : 2,
   #      "mplsVpnInterfaceConfStorageType" : "volatile",
   #      "mplsVpnInterfaceLabelEdgeType" : 1,
   #      "mplsVpnInterfaceConfRowStatus" : "active"
   #   },

	# Get the VRF Names from the inventory system.
	my $mplsVpnVrfItems = $S->nmisng_node->get_inventory_ids( concept => "mplsVpnVrf", historic => 0 );

	# Do I have any items?
	if (@$mplsVpnVrfItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsVpnVrfItems) . " Concept 'mplsVpnVrf' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsVpnVrfId (@$mplsVpnVrfItems)
		{
			$i++;
			# Get a single record.
			my ($mplsVpnVrf, $error) = $S->nmisng_node->inventory(_id => $mplsVpnVrfId);
			if ($error)
			{
				$NG->log->error("Failed to get 'mplsVpnVrf' inventory for ID $mplsVpnVrfId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsVpnVrf->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnVrf' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+)\.(.+)$/ ) {
				my $indexThing = $1;
				my $name       = $2;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrf' entry $i Index: .....  '$indexThing'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrf' entry $i mplsVpnVrfId  '$mplsVpnVrfId'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrf' entry $i Name: ......  '$name'."});
				$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$name));
				$entry->{mplsVpnVrfId}   = $mplsVpnVrfId;
				$NG->log->debug5(sub {"Node '$node' 'mplsVpnVrf' entry $i After " . Dumper($entry)});
				# Save the results in the database.
				$mplsVpnVrf->data($entry);
				my ( $op, $saveError ) = $mplsVpnVrf->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsVpnVrf' inventory for ID '$mplsVpnVrfId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsVpnVrf'; inventory for ID '$mplsVpnVrfId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsVpnVrf' inventory.");
	}

	# Get the alternate MIB VRF Names from the inventory system.
	my $mplsL3VpnVrfItems = $S->nmisng_node->get_inventory_ids( concept => "mplsL3VpnVrf", historic => 0 );

	# Do I have any items?
	if (@$mplsL3VpnVrfItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsL3VpnVrfItems) . " Concept 'mplsL3VpnVrf' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsL3VpnVrfId (@$mplsL3VpnVrfItems)
		{
			$i++;
			# Get a single record.
			my ($mplsL3VpnVrf, $error) = $S->nmisng_node->inventory(_id => $mplsL3VpnVrfId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsL3VpnVrf' inventory for ID $mplsL3VpnVrfId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsL3VpnVrf->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnVrf' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+)\.(.+)$/ ) {
				my $indexThing = $1;
				my $name       = $2;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrf' entry $i Index: .......  '$indexThing'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrf' entry $i mplsL3VpnVrfId  '$mplsL3VpnVrfId'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrf' entry $i Name: ........  '$name'."});
				$entry->{mplsL3VpnVrfName}  = join("", map { chr($_) } split(/\./,$name));
				$entry->{mplsL3VpnVrfVpnId} = $mplsL3VpnVrfId;
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnVrf' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsL3VpnVrf->data($entry);
				my ( $op, $saveError ) = $mplsL3VpnVrf->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsL3VpnVrf' inventory for ID '$mplsL3VpnVrfId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsL3VpnVrf'; inventory for ID '$mplsL3VpnVrfId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsL3VpnVrf' inventory.");
	}

	# Get the L3 VPN Interface Configuration from the inventory system.
	my $mplsL3VpnIfConfItems = $S->nmisng_node->get_inventory_ids( concept => "mplsL3VpnIfConf", historic => 0 );

	# Do I have any items?
	if (@$mplsL3VpnIfConfItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsL3VpnIfConfItems) . " Concept 'mplsL3VpnIfConf' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsL3VpnIfConfId (@$mplsL3VpnIfConfItems)
		{
			$i++;
			# Get a single record.
			my ($mplsL3VpnIfConf, $error) = $S->nmisng_node->inventory(_id => $mplsL3VpnIfConfId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsL3VpnIfConf' inventory for ID $mplsL3VpnIfConfId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsL3VpnIfConf->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnIfConf' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+)\.(.+)\.(\d+)$/ ) {
				my $indexThing           = $1;
				my $mplsL3VpnVrfName     = $2;
				my $mplsL3VpnIfConfIndex = $3;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnIfConf' entry $i Index: .............. '$indexThing'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnIfConf' entry $i mplsL3VpnVrfName: ... '$mplsL3VpnVrfName'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnIfConf' entry $i mplsL3VpnIfConfIndex: '$mplsL3VpnIfConfIndex'."});
				$entry->{mplsL3VpnVrfName} = join("", map { chr($_) } split(/\./,$mplsL3VpnVrfName));
				$entry->{mplsL3VpnIfConfIndex} = $mplsL3VpnIfConfIndex;
				if ( defined $IF->{$entry->{mplsL3VpnIfConfIndex}}{ifDescr} ) {
					$entry->{ifDescr} = $IF->{$entry->{mplsL3VpnIfConfIndex}}{ifDescr};
					$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{mplsL3VpnIfConfIndex}&node=$node";
					$entry->{ifDescr_id} = "node_view_$node";
					$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnIfConf' entry $i After " . Dumper($entry)});
				}
				# Save the results back to the database.
				$mplsL3VpnIfConf->data($entry);
				my ( $op, $saveError ) = $mplsL3VpnIfConf->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsL3VpnIfConf' inventory for ID '$mplsL3VpnIfConfId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsL3VpnIfConf'; inventory for ID '$mplsL3VpnIfConfId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsL3VpnIfConf' inventory.");
	}

	# Get the VPN Interfaces from the inventory system.
	my $mplsVpnInterfaceItems = $S->nmisng_node->get_inventory_ids( concept => "mplsVpnInterface", historic => 0 );

	# Do I have any items?
	if (@$mplsVpnInterfaceItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsVpnInterfaceItems) . " Concept 'mplsVpnInterface' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsVpnInterfaceId (@$mplsVpnInterfaceItems)
		{
			$i++;
			# Get a single record.
			my ($mplsVpnInterface, $error) = $S->nmisng_node->inventory(_id => $mplsVpnInterfaceId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsVpnInterface' inventory for ID $mplsVpnInterfaceId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsVpnInterface->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnInterface' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+)\.(.+)\.(\d+)$/ ) {
				my $indexThing = $1;
				my $name       = $2;
				my $ifIndex    = $3;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnInterface' entry $i Index: . '$indexThing'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnInterface' entry $i Name: .. '$name'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnInterface' entry $i ifIndex: '$ifIndex'."});
				$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$name));
				$entry->{ifIndex} = $ifIndex;
				if ( defined $IF->{$entry->{ifIndex}}{ifDescr} ) {
					$entry->{ifDescr} = $IF->{$entry->{ifIndex}}{ifDescr};
					$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{ifIndex}&node=$node";
					$entry->{ifDescr_id} = "node_view_$node";
				}
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnInterface' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsVpnInterface->data($entry);
				my ( $op, $saveError ) = $mplsVpnInterface->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsVpnInterface' inventory for ID '$mplsVpnInterfaceId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsVpnInterface'; inventory for ID '$mplsVpnInterfaceId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsVpnInterface' inventory.");
	}

  #"10.77.103.109.116.95.82.97.100.105.111.2.1" : {
  #   "mplsVpnVrfRouteTarget" : "65500:180803",
  #   "index" : "10.77.103.109.116.95.82.97.100.105.111.2.1",
  #   "mplsVpnVrfRouteTargetRowStatus" : "65500:180803",
  #   "mplsVpnVrfRouteTargetDescr" : "65500:180803"
  #},
  #"3.71.83.77.4.1" : {
  #   "mplsVpnVrfRouteTarget" : "65500:70100",
  #   "index" : "3.71.83.77.4.1",
  #   "mplsVpnVrfRouteTargetRowStatus" : "65500:70100",
  #   "mplsVpnVrfRouteTargetDescr" : "65500:70100"
  #},

	# Get the alternate MIB VRF route from the inventory system.
	my $mplsL3VpnVrfRTItems = $S->nmisng_node->get_inventory_ids( concept => "mplsL3VpnVrfRT", historic => 0 );

	# Do I have any items?
	if (@$mplsL3VpnVrfRTItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsL3VpnVrfRTItems) . " Concept 'mplsL3VpnVrfRT' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsL3VpnVrfRTId (@$mplsL3VpnVrfRTItems)
		{
			$i++;
			# Get a single record.
			my ($mplsL3VpnVrfRT, $error) = $S->nmisng_node->inventory(_id => $mplsL3VpnVrfRTId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsL3VpnVrfRT' inventory for ID $mplsL3VpnVrfRTId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsL3VpnVrfRT->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnVrfRT' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			# There seems to be a crazy character in this MIB!
			if ( $entry->{index} =~ /\d+\.(.+)\.(\d+)\.(\d+)$/ ) {
				my $mplsL3VpnVrfName    = $1;
				my $mplsL3VpnVrfRTIndex = $2;
				my $mplsL3VpnVrfRTType  = $3;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrfRT' entry $i mplsL3VpnVrfName: .. '$mplsL3VpnVrfName'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrfRT' entry $i mplsL3VpnVrfRTIndex: '$mplsL3VpnVrfRTIndex'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsL3VpnVrfRT' entry $i mplsL3VpnVrfRTType:  '$mplsL3VpnVrfRTType'."});
				$entry->{mplsL3VpnVrfName} = join("", map { chr($_) } split(/\./,$mplsL3VpnVrfName));
					$entry->{mplsL3VpnVrfRTIndex} = $mplsL3VpnVrfRTIndex;
				$entry->{mplsL3VpnVrfRTType} = $mplsL3VpnVrfRTType;
				if ( $mplsL3VpnVrfRTType == 1 ) {
					$entry->{mplsL3VpnVrfRTType} = "import";
				}
				elsif ( $mplsL3VpnVrfRTType == 2 ) {
					$entry->{mplsL3VpnVrfRTType} = "export";
				}
				elsif ( $mplsL3VpnVrfRTType == 3 ) {
					$entry->{mplsL3VpnVrfRTType} = "both";
				}
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsL3VpnVrfRT' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsL3VpnVrfRT->data($entry);
				my ( $op, $saveError ) = $mplsL3VpnVrfRT->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsL3VpnVrfRT' inventory for ID '$mplsL3VpnVrfRTId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsL3VpnVrfRT'; inventory for ID '$mplsL3VpnVrfRTId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsL3VpnVrfRT' inventory.");
	}

	# Get the VRF route target from the inventory system.
	my $mplsVpnVrfRouteTargetItems = $S->nmisng_node->get_inventory_ids( concept => "mplsVpnVrfRouteTarget", historic => 0 );

	# Do I have any items?
	if (@$mplsVpnVrfRouteTargetItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsVpnVrfRouteTargetItems) . " Concept 'mplsVpnVrfRouteTarget' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsVpnVrfRouteTargetId (@$mplsVpnVrfRouteTargetItems)
		{
			$i++;
			# Get a single record.
			my ($mplsVpnVrfRouteTarget, $error) = $S->nmisng_node->inventory(_id => $mplsVpnVrfRouteTargetId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsVpnVrfRouteTarget' inventory for ID $mplsVpnVrfRouteTargetId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsVpnVrfRouteTarget->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnVrfRouteTarget' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(.+)\.(\d+)\.(\d+)$/ ) {
				my $mplsVpnVrfName             = $1;
				my $mplsVpnVrfRouteTargetIndex = $2;
				my $mplsVpnVrfRouteTargetType  = $3;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrfRouteTarget' entry $i mplsVpnVrfName: ........... '$mplsVpnVrfName'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrfRouteTarget' entry $i mplsVpnVrfRouteTargetIndex: '$mplsVpnVrfRouteTargetIndex'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnVrfRouteTarget' entry $i mplsVpnVrfRouteTargetType:  '$mplsVpnVrfRouteTargetType'."});
				$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$mplsVpnVrfName));
				$entry->{mplsVpnVrfRouteTargetIndex} = $mplsVpnVrfRouteTargetIndex;
				$entry->{mplsVpnVrfRouteTargetType} = $mplsVpnVrfRouteTargetType;
				if ( $mplsVpnVrfRouteTargetType == 1 ) {
					$entry->{mplsVpnVrfRouteTargetType} = "import";
				}
				elsif ( $mplsVpnVrfRouteTargetType == 2 ) {
					$entry->{mplsVpnVrfRouteTargetType} = "export";
				}
				elsif ( $mplsVpnVrfRouteTargetType == 3 ) {
					$entry->{mplsVpnVrfRouteTargetType} = "both";
				}
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnVrfRouteTarget' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsVpnVrfRouteTarget->data($entry);
				my ( $op, $saveError ) = $mplsVpnVrfRouteTarget->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsVpnVrfRouteTarget' inventory for ID '$mplsVpnVrfRouteTargetId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsVpnVrfRouteTarget'; inventory for ID '$mplsVpnVrfRouteTargetId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsVpnVrfRouteTarget' inventory.");
	}

	# Get the mplsVpnLdpCisco details from the inventory system.
	my $mplsLdpEntityItems = $S->nmisng_node->get_inventory_ids( concept => "mplsLdpEntity", historic => 0 );

	# Do I have any items?
	if (@$mplsLdpEntityItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsLdpEntityItems) . " Concept 'mplsLdpEntity' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsLdpEntityId (@$mplsLdpEntityItems)
		{
			$i++;
			# Get a single record.
			my ($mplsLdpEntity, $error) = $S->nmisng_node->inventory(_id => $mplsLdpEntityId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsLdpEntity' inventory for ID $mplsLdpEntityId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsLdpEntity->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsLdpEntity' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\.(\d+)$/ ) {
				my $mplsLdpEntityLdpId = $1;
				my $mplsLdpEntityIndex = $2;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsLdpEntity' entry $i mplsLdpEntityLdpId: '$mplsLdpEntityLdpId'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsLdpEntity' entry $i mplsLdpEntityIndex: '$mplsLdpEntityIndex'."});
				$entry->{mplsLdpEntityLdpId} = $mplsLdpEntityLdpId;
				$entry->{mplsLdpEntityIndex} = $mplsLdpEntityIndex;
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsLdpEntity' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsLdpEntity->data($entry);
				my ( $op, $saveError ) = $mplsLdpEntity->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsLdpEntity' inventory for ID '$mplsLdpEntityId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsLdpEntity'; inventory for ID '$mplsLdpEntityId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsLdpEntity' inventory.");
	}

	# Get the mplsVpnLdpCisco details from the inventory system.
	my $mplsVpnLdpCiscoItems = $S->nmisng_node->get_inventory_ids( concept => "mplsVpnLdpCisco", historic => 0 );

	# Do I have any items?
	if (@$mplsVpnLdpCiscoItems)
	{
		my $i = 0;
		$NG->log->debug("Processing " . scalar(@$mplsVpnLdpCiscoItems) . " Concept 'mplsVpnLdpCisco' inventory items for Node '$node'.");
		# Recurse the list of items.
		for my $mplsVpnLdpCiscoId (@$mplsVpnLdpCiscoItems)
		{
			$i++;
			# Get a single record.
			my ($mplsVpnLdpCisco, $error) = $S->nmisng_node->inventory(_id => $mplsVpnLdpCiscoId);
			if ($error)
			{
				$NG->log->error("Failed to get Concept 'mplsVpnLdpCisco' inventory for ID $mplsVpnLdpCiscoId: $error");
				next;
			}
			# Get the data you want to play with.
			my $entry = $mplsVpnLdpCisco->data();
			$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnLdpCisco' entry $i Before: " . Dumper($entry)});
			# Transform, etc.
			if ( $entry->{index} =~ /(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\.(\d+)$/ ) {
				my $mplsLdpEntityLdpId = $1;
				my $mplsLdpEntityIndex = $2;
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnLdpCisco' entry $i mplsLdpEntityLdpId: '$mplsLdpEntityLdpId'."});
				$NG->log->debug2(sub {" Node '$node' Concept 'mplsVpnLdpCisco' entry $i mplsLdpEntityIndex: '$mplsLdpEntityIndex'."});
				$entry->{mplsLdpEntityLdpId} = $mplsLdpEntityLdpId;
				$entry->{mplsLdpEntityIndex} = $mplsLdpEntityIndex;
				$NG->log->debug5(sub {"Node '$node' Concept 'mplsVpnLdpCisco' entry $i After " . Dumper($entry)});
				# Save the results back to the database.
				$mplsVpnLdpCisco->data($entry);
				my ( $op, $saveError ) = $mplsVpnLdpCisco->save( node => $node );
				if ($saveError)
				{
					$NG->log->error("Failed to save Concept 'mplsVpnLdpCisco' inventory for ID '$mplsVpnLdpCiscoId' in Node '$node'; Error: $saveError");
				}
				else
				{
					$NG->log->debug( "Saved Concept: 'mplsVpnLdpCisco'; inventory for ID '$mplsVpnLdpCiscoId' in Node '$node'.");
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("Node '$node' has no Concept 'mplsVpnLdpCisco' inventory.");
	}

	return ($changesweremade,undef); # Report if we changed anything
}

1;
