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
# This plugin is intended to use with the Model-F5-BigIP-API.nmis model, this 
# is to replace the use of SNMP for collecting LARGE numbers of Virtual Services.
#
# To use the plugin, get the F5BigIP.json file and copy to /usr/local/nmis9/conf
# Update the details, sample:
#{
#	"apiUser":"YYYY",
#	"apiPass":"XXXXXXX",
#	"apiPort":8443,
#}


package F5BigIPAPI;
our $VERSION = "2.0.0";

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Data::Dumper;
use JSON::XS;
use Mojo::Base;
use Mojo::UserAgent;
#use URI::Escape;

use NMISNG;
use NMISNG::rrdfunc;

# These are the concepts/sections we are working on.
our $virtSvrConcept = "VirtualServTable";
our $poolConcept    = "F5_Pools";

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# is the node down or is SNMP down?
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return (2, "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	
	return (1,undef) if ( $catchall->{nodeModel} ne "F5-BigIP-API" or !NMISNG::Util::getbool($catchall->{collect}));

	my $catchall_data = $inventory->data();
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
		$NG->log->info("Skipping F5BigIP plugin for node::$node, Node Down");
		return (2, "Node Down, skipping F5BigIP plugin");
	}
	else {
		$NG->log->info("Running F5BigIP Collect plugin for node::$node");
	}

	my $changesweremade = 0;

	my $nodeobj = $NG->node(name => $node);

	$NG->log->info("Working on '$node' getting API data now");
	my ($errmsg, $f5Data, $f5Info) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR getting data for node '$node'; Error: $errmsg");
		return (2,$errmsg);
	}

	if (!defined $f5Data || ref($f5Data) ne "HASH") {
		$NG->log->error("ERROR collecting for node '$node': Got no data!");
		return (2, "ERROR collecting for node '$node': Got no data!");
	}


	# get a list of virtual servers, which are indexed the same as the API data
	my $VirtualServs = $S->nmisng_node->get_inventory_ids(
		concept => $virtSvrConcept,
		filter => { historic => 0 });
	
	# do we have some inventory?
	if (@$VirtualServs)
	{
		$NG->log->debug3("Virtual Servers: " . Dumper($VirtualServs) . "\n\n\n");
		# process each inventory thing, matching it to the API data using the index/name
		foreach my $serv_id (@$VirtualServs)
		{
			$NG->log->debug2("Processing Virtual Server: serv_id='$serv_id'.");
			# get the inventory object for this specific item.
			my ($serv_inventory,$error) = $S->nmisng_node->inventory(_id => $serv_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for Virtual Server '$serv_id'; Error:: $error");
				next;
			}

			# get a handy pointer to the data
			my $data = $serv_inventory->data();

			# get the name of the thing to use.
			my $name = $data->{index};
			$NG->log->debug("Virtual Server ID: '$serv_id',  Name: '$name'.");

			# get the F5 data out.
			if (!defined($f5Data->{$name}) || ref($f5Data->{$name}) ne "HASH")
			{
				$NG->log->error("Failed to get inventory for Virtual Server '$serv_id'.");
				next;
			}
			my $f5PoolData    = ();
			my $processPool   = 0;
			my $f5SubData     = $f5Data->{$name};
			$NG->log->debug3("HashMap for Virtual Server '$name': " . Dumper($f5SubData) . "\n\n\n");
			# Pull this Virtual Server's Pool data into a variable.
			if (defined($f5SubData->{Pool}) && ref($f5SubData->{Pool}) eq "HASH")
			{
				$f5PoolData = $f5SubData->{Pool}; # Pull this out to a separate HashMap.
				$f5SubData->{Pool} = undef;       # ...and don't store it in with the VirtualServer Concept
				$NG->log->debug3("HashMap for Virtual Server Pool '$name': " . Dumper($f5PoolData));
				$processPool = 1;
			}

			# TODO what possible values are they 100 is good, less than 100 is bad.
			#default value is assumed to be "available"
			my $statusAvailibilityState = 100;
			if ( $f5SubData->{statusAvailState} eq "available" ) {
				$statusAvailibilityState = 100 
			}
			elsif ( $f5SubData->{statusAvailState} eq "offline" ) {
				$statusAvailibilityState = 50 
			}
			else {
				$statusAvailibilityState = 10 	
			}

			#save to integers to RRD
			my $rrddata = {
				'ltmStatClientCurCon' => { "option" => "gauge,0:U", "value" => $f5SubData->{clientsideCurConns} },
				'ltmVsStatAvailState' => { "option" => "gauge,0:100", "value" => $statusAvailibilityState }
			};

			# ensure the RRD file is using the inventory record so it will use the correct RRD file.
			my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>$virtSvrConcept, index=>$name, inventory=>$serv_inventory);

			# check for RRD update errors
			if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed for VirtualServer '$name'!") };

			# update the data for the GUI
			$data->{statusAvailState}        = $f5SubData->{statusAvailState};
			$data->{vsStatusAvlTxt}          = $f5SubData->{statusAvailState};
			$data->{ltmStatClientCurCon}     = $f5SubData->{clientsideCurConns};
			$data->{ltmVsStatAvailState}     = $statusAvailibilityState;

			# alerts in NMIS model won't fire after this has run.
			# TODO Raise an alert if the Virtual Server is down.

            # Save the data so it appears in the GUI
            $serv_inventory->data($data); # set changed info
			my ( $op, $subError ) = $serv_inventory->save();
			if ($subError)
			{
				$NG->log->error("Failed to save inventory for Virtual Server '$name'; Error: $subError");
			}
			else
			{
				$NG->log->debug( "Saved Concept: '$virtSvrConcept'; '$name' op: $op");
				$changesweremade = 1;
			}
			if ($processPool) {
				# get a list of virtual servers, which are indexed the same as the API data
				my $Pools = $S->nmisng_node->get_inventory_ids(
					concept => $poolConcept,
					filter => { historic => 0 });
				# do we have some inventory?
				if (@$Pools)
				{
					$NG->log->debug3("Pools: " . Dumper($Pools) . "\n\n\n");
					# process each inventory thing, matching it to the API data using the index/name
					foreach my $pool_id (@$Pools)
					{
						$NG->log->debug2("Processing Pool pool_id='$pool_id'.");
						# get the inventory object for this specific item.
						my ($pool_inventory,$error) = $S->nmisng_node->inventory(_id => $pool_id);
						if ($error)
						{
							$NG->log->error("Failed to get inventory for Concept '$poolConcept'; Pool '$pool_id'; Error: $error");
							next;
						}
						# get a handy pointer to the pool data
						$data = $pool_inventory->data();
					    $NG->log->debug3("Inventory Data: " . Dumper($data) . "\n\n\n");

						# get the name of the thing to use.
						my $poolName   = $data->{poolMbrPoolName};
						my $memberName = $data->{poolMbrNodeName};
						$NG->log->debug("Pool ID: '$pool_id',  Name: '$memberName'.");

						# Verify that this Virtual Server has Pool data.
						if (!defined($f5PoolData->{"${poolName}_Pool"}->{Member}->{$memberName}) || ref($f5PoolData->{"${poolName}_Pool"}->{Member}->{$memberName}) ne "HASH")
						{
							$NG->log->error("Failed to get inventory for Concept '$poolConcept';  Pool '$poolName'; Name '$memberName'.");
							next;
						}
						# Pull this Virtual Server's Pool data into a variable.
						$f5SubData       = $f5PoolData->{"${poolName}_Pool"}->{Member}->{$memberName};
						$NG->log->debug3("HashMap for Virtual Server '$name' Pool '$poolName'; Member '$memberName': " . Dumper($f5SubData));
						$NG->log->debug("Processing Concept '$poolConcept'; Pool '$poolName'; Name '$memberName'.");
						#Save to integers to RRD
						my $rrddata = {
							'curConns' => { "option" => "gauge,0:U", "value" => $f5SubData->{curConns} },
							'bitsIn' => { "option" => "gauge,0:U", "value" => $f5SubData->{bitsIn} },
							'bitsOut' => { "option" => "gauge,0:U", "value" => $f5SubData->{bitsOut} },
							'pktsIn' => { "option" => "gauge,0:U", "value" => $f5SubData->{pktsIn} },
							'pktsOut' => { "option" => "gauge,0:U", "value" => $f5SubData->{pktsOut} }
						};

						# ensure the RRD file is using the inventory record so it will use the correct RRD file.
						my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>$poolConcept, index=>$f5SubData->{index}, inventory=>$pool_inventory);

						# check for RRD update errors
						if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed for Pool '$memberName'!") };

						$data->{poolMbrAvailState}          = $f5SubData->{poolMbrAvailState};
						$data->{statusReason}               = $f5SubData->{statusReason};
						$data->{state}                      = $f5SubData->{state};
						$data->{Enabled}                    = $f5SubData->{Enabled};
						$data->{connLimit}                  = $f5SubData->{connLimit};
						$data->{totConns}                   = $f5SubData->{totConns};
						$data->{maxConns}                   = $f5SubData->{maxConns};
						$data->{curConns}                   = $f5SubData->{curConns};
						$data->{bitsIn}                     = $f5SubData->{bitsIn};
						$data->{bitsOut}                    = $f5SubData->{bitsOut};
						$data->{pktsIn}                     = $f5SubData->{pktsIn};
						$data->{pktsOut}                    = $f5SubData->{pktsOut};
						$pool_inventory->data($data); # set changed info
						# the above will put data into inventory, so save
						my ( $op, $subError ) = $pool_inventory->save();
						$NG->log->debug( "saved '$poolName' op: $op");
						if ($subError)
						{
							$NG->log->error("Failed to save '$poolConcept' inventory for Virtual Server Pool '$poolName'; Member '$memberName'; Error: $subError");
						}
						else
						{
							$NG->log->debug( "Saved Concept: '$poolConcept'; '$poolName/$memberName' op: $op");
							$changesweremade = 1;
						}
					}
				}
			}
		}
	}
	else {
		return (2, "There is no inventory for concept '$virtSvrConcept'")
	}


	return ($changesweremade,undef); # report if we changed anything
}

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# is the node down or is SNMP down?
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return (2, "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall        = $S->inventory( concept => 'catchall' )->{_data};

	return (1,undef) if ( $catchall->{nodeModel} ne "F5-BigIP-API");

	my $catchall_data = $inventory->data();
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
		$NG->log->info("Skipping F5BigIP plugin for node::$node, Node Down");
		return (2, "Node Down, skipping F5BigIP plugin");
	}
	else {
		$NG->log->info("Running F5BigIP Update plugin for node::$node");
	}

	my $changesweremade = 0;
	my $nodeobj         = $NG->node(name => $node);
	
	$NG->log->info("Working on '$node'");
	my ($errmsg, $f5Data, $f5Info) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR getting data for node '$node'; Error: $errmsg");
		return (2,$errmsg);
	}

	if (!defined $f5Data || ref($f5Data) ne "HASH") {
		$NG->log->error("ERROR collecting for node '$node': Got no data!");
		return (2, "ERROR collecting for node '$node': Got no data!");
	}

	my $f5ServerInfo     = $f5Info->{Server};
	my $f5PoolInfo       = $f5Info->{Pool};

	# Archive historic records.
	my $VirtualServs = $S->nmisng_node->get_inventory_ids(
		concept => $virtSvrConcept,
		filter => { historic => 0 });
	if (@$VirtualServs)
	{
		my $result = $nodeobj->bulk_update_inventory_historic(active_indices => $VirtualServs, concept => $virtSvrConcept );
		$NG->log->error("Bulk update historic failed for Concept '$virtSvrConcept': $result->{error}") if ($result->{error});
	}
	my $Pools = $S->nmisng_node->get_inventory_ids(
		concept => $poolConcept,
		filter => { historic => 0 });
	if (@$Pools)
	{
		my $result = $nodeobj->bulk_update_inventory_historic(active_indices => $Pools, concept => $poolConcept );
		$NG->log->error("Bulk update historic failed for Concept '$poolConcept': $result->{error}") if ($result->{error});
	}

	# Process what we got.
	foreach my $name (keys(%$f5Data))
	{
		$NG->log->debug("Processing $virtSvrConcept Name '$name'.");
		# Verify that this Virtual Server has data.
		if (!defined($f5Data->{$name}) || ref($f5Data->{$name}) ne "HASH")
		{
			$NG->log->error("Failed to get inventory for '$virtSvrConcept' '$name'.");
			next;
		}
		my $f5PoolData    = ();
		my $processPool   = 0;
		# Pull this Virtual Server data into a variable.
		my $f5SubData     = $f5Data->{$name};
		$NG->log->debug3("HashMap for Virtual Server '$name': " . Dumper($f5SubData) . "\n\n\n");

		# Pull this Virtual Server's Pool data into a variable.
		if (defined($f5SubData->{Pool}) && ref($f5SubData->{Pool}) eq "HASH")
		{
			$f5PoolData = $f5SubData->{Pool}; # Pull this out to a separate HashMap.
			$f5SubData->{Pool} = undef;       # ...and don't store it in with the VirtualServer Concept
			$NG->log->debug3("HashMap for Virtual Server Pool '$name': " . Dumper($f5PoolData));
			$processPool = 1;
		}
		my $path_keys = ['index'];
		my $path      = $nodeobj->inventory_path( concept => $virtSvrConcept, path_keys => $path_keys, data => $f5SubData );
		$NG->log->debug3( "$virtSvrConcept path ".join(',', @$path));

		# now get-or-create an inventory object for this new concept
		my ( $subInventory, $error_message ) = $nodeobj->inventory(
			create    => 1,
			concept   => $virtSvrConcept,
			data      => $f5SubData,
			path_keys => $path_keys,
			path      => $path
		);
		if ( !$subInventory )
		{
			$NG->log->error("Failed to create Concept '$virtSvrConcept' inventory for Virtual Server '$name', error: $error_message");
			next;
		}
		
		# regenerate the path, if this thing wasn't new the path may have changed, which is ok
		$subInventory->path( recalculate => 1 );
		$subInventory->historic(0);
		$subInventory->enabled(1);
		$subInventory->data( $f5SubData );

		# set which columns should be displayed
		$subInventory->data_info(
			subconcept => $virtSvrConcept,
			enabled => 1,
			display_keys => $f5ServerInfo
		);

		$subInventory->description( $name );

		# get the RRD file name to use for storage.
		my $dbname = $S->makeRRDname(graphtype => $virtSvrConcept,
									index      => $name,
									inventory  => $subInventory,
									relative   => 1);
		$NG->log->debug("Collect F5 API for '$virtSvrConcept' data into dbname '$dbname'.");

		# set the storage name into the inventory model
		$subInventory->set_subconcept_type_storage(type => "rrd",
													subconcept => $virtSvrConcept,
													data => $dbname) if ($dbname);

		# the above will put data into inventory, so save
		my ( $op, $subError ) = $subInventory->save();
		if ($subError)
		{
			$NG->log->error("Failed to save Concept '$virtSvrConcept' inventory for Virtual Server '$name': $subError");
		}
		else
		{
			$NG->log->debug( "Saved Concept: '$virtSvrConcept'; '$name' op: $op");
			$changesweremade = 1;
		}
		if ($processPool)
	   	{
			foreach my $poolName (keys(%$f5PoolData))
			{
				$NG->log->debug("Processing '$poolConcept' Name '$poolName'.");
				# Verify that this Virtual Server has Pool data.
				if (!defined($f5PoolData->{$poolName}) || ref($f5PoolData->{$poolName}) ne "HASH")
				{
					$NG->log->error("Failed to get inventory for Concept '$poolConcept'; Name '$poolName'.");
					next;
				}
				my $f5MemberData = ();
				# Pull this Virtual Server's Pool data into a variable.
				$f5SubData       = $f5PoolData->{$poolName};
				$NG->log->debug3("HashMap for Virtual Server '$name' Pool '$poolName': " . Dumper($f5SubData));
				if (defined($f5SubData->{Member}) && ref($f5SubData->{Member}) eq "HASH")
				{
					$f5MemberData = $f5SubData->{Member};
					$NG->log->debug3("HashMap for Virtual Server '$name'; Pool '$poolName'; Members: " . Dumper($f5MemberData) . "\n\n\n");
				}
				foreach my $memberName (keys(%$f5MemberData))
				{
					$NG->log->debug("Processing '$poolConcept' Pool '$poolName'; Name '$memberName'.");
					# Verify that this Virtual Server Pool has Member data.
					if (!defined($f5MemberData->{$memberName}) || ref($f5MemberData->{$memberName}) ne "HASH")
					{
						$NG->log->error("Failed to get inventory for Concept '$poolConcept'; Pool '$poolName'; Member '$memberName'.");
						next;
					}
					# Pull this Virtual Server Pool Member data into a variable.
					my $f5MemberSubData     = $f5MemberData->{$memberName};
					$NG->log->debug3("HashMap for Virtual Server '$name' Pool '$poolName'; Member '$memberName': " . Dumper($f5MemberSubData));
					$path_keys = ['index'];
					$path      = $nodeobj->inventory_path( concept => $poolConcept, path_keys => $path_keys, data => $f5MemberSubData );
					$NG->log->debug3( "$poolConcept path ".join(',', @$path));
			
					# now get-or-create an inventory object for this new concept
					my ( $subMemberInventory, $error_message ) = $nodeobj->inventory(
						create    => 1,
						concept   => $poolConcept,
						data      => $f5MemberSubData,
						path_keys => $path_keys,
						path      => $path
					);
					if ( !$subMemberInventory )
					{
						$NG->log->error("Failed to create Concept '$poolConcept'; Pool '$poolName'; inventory for '$memberName', error: $error_message");
						next;
					}
					
					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$subMemberInventory->path( recalculate => 1 );
					$subMemberInventory->historic(0);
					$subMemberInventory->enabled(1);
			
					# set which columns should be displayed
					$subMemberInventory->data_info(
						subconcept => $poolConcept,
						enabled => 1,
						display_keys => $f5PoolInfo
					);
			
					$subMemberInventory->description( $memberName );
			
					# get the RRD file name to use for storage.
					my $dbname = $S->makeRRDname(graphtype => $poolConcept,
												index      => $subMemberInventory->{index},
												inventory  => $subMemberInventory,
												extras     => $subMemberInventory,
												relative   => 1);
					$NG->log->debug("Collect F5 API for '$poolConcept' data into dbname '$dbname'.");
			
					# set the storage name into the inventory model
					$subMemberInventory->set_subconcept_type_storage(type => "rrd",
																	subconcept => $poolConcept,
																	data => $dbname) if ($dbname);
					# the above will put data into inventory, so save
					my ( $op, $subError ) = $subMemberInventory->save();
					if ($subError)
					{
						$NG->log->error("Failed to save '$poolConcept' inventory for Virtual Server Pool '$poolName'; Member '$memberName'; Error: $subError");
					}
					else
					{
						$NG->log->debug( "Saved Concept: '$poolConcept'; '$poolName/$memberName' op: $op");
						$changesweremade = 1;
					}
				}
			}
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

sub getF5Data {
	my %args           = @_;
	my $deviceName     = $args{deviceName};
	my $NG             = $args{NG};
	my $C              = $args{C};
	my $nodeObj        = $args{nodeObj};

	my $NC = $nodeObj->configuration;
	my $host      = $NC->{host};
	
	my $apiUser        = "";
	my $apiPass        = "";
	my $apiPort        = "";
	my $f5Data         = undef;
	my $f5Info         = undef;
	my $errMsg         = undef;
	my $name;
	
	my ($errmsg, $f5Config) = loadJsonFile($C->{'<nmis_conf>'} . "/F5BigIP.json");
	unless (defined($errmsg)) {
		$apiUser           = $f5Config->{apiUser};
		$apiPass           = $f5Config->{apiPass};
		$apiPort           = $f5Config->{apiPort};

		if (!defined($apiUser) || $apiUser eq '' || !defined($apiPass) || $apiPass eq '') {
			$errmsg = "ERROR API Username or Password not supplied";
		}
		if (!defined($apiPort) || $apiPort !~ /^\d+\z/) {
			$errmsg = "ERROR API Port value is not defined, or is not an integer.";
		}
		unless (defined($errmsg)) {
			$f5Info = {};
			$f5Info->{Server} = {
				{index                      => "Index"},
				{ltmVirtualServName         => "Server Name"},
				{ltmVirtualServAddr         => "IP Address"},
				{ltmVirtualServPort         => "Port"},
				{virtualServIpProto         => "IP Proto"},
				{virtServConnLimit          => "ConnLimit"},
				{vsStatusAvailState         => "VS Status"},
				{vsStatusAvlTxt             => "Virtual Server State"},
				{Pool                       => "Pool Name"},
				{ResourceID                 => "Resource ID"},
				{Status                     => "Status"},
				{statusEnabledState         => "Status Enabled State"},
				{statusStatusReason         => "Status Status Reason"},
				{clientsideBitsIn           => "Clientside Bits In"},
				{clientsideBitsOut          => "Clientside Bits Out"},
				{clientsideCurConns         => "Clientside Current Connections"},
				{clientsideMaxConns         => "Clientside Max Connections"},
				{clientsidePktsIn           => "Clientside Pkts In"},
				{clientsidePktsOut          => "Clientside Pkts Out"},
				{clientsideTotConns         => "Clientside Total Connections"}
			};
			$f5Info->{Pool} = {
				{index                        => "Index"},
				{poolMbrPoolName              => "Pool Name"},
				{poolMbrNodeName              => "Pool Member Name"},
				{poolMbrAddr                  => "IP Address"},
				{poolMbrPort                  => "Port"},
				{poolMbrAvailState            => "Member Status"},
				{Enabled                      => "Member Enabled Flag"},
				{statusReason                 => "Status Reason Text"},
				{bitsIn                       => "Bits Inbound"},
				{bitsOut                      => "Bits Outbound"},
				{curConns                     => "Current Conections"},
				{maxConns                     => "Maximum Connections"},
				{pktsIn                       => "Packets Inbound"},
				{pktsOut                      => "Packets Outbound"},
				{totConns                     => "Total Conections"},
				{connLimit                    => "Connection Limit"}
			};

			$NG->log->debug9("apiUser        = $apiUser");
			$NG->log->debug9("apiPass        = $apiPass");
			$NG->log->debug9("apiPort        = $apiPort");
			my $type;
			my $request_body;
			my $res;
			my $headers = {"Content-type" => 'application/json', Accept => 'application/json'};
			my $client  = Mojo::UserAgent->new();
			#my $encPass = uri_escape("$apiPass");
			my $url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/shared/authn/login')->userinfo("'".$apiUser.":".$apiPass."'");
			$client->insecure(1);
			$res = $client->post($url => $headers => "{'username': '$apiUser', 'password':'$apiPass', 'loginProviderName':'tmos'}")->result;
			return ("failed to get a result from login attempt.") if (!$res);
			my $body     = decode_json($res->body);
			return ("failed to get a result from login attempt.") if (!$body);
			$NG->log->debug3( "\nBody: " . Dumper($body) . "\n");
			my $token    = $body->{token};
			if (!$token) {
				return ("failed to get a token from login attempt; Error: $body->{message}");
			}
			$NG->log->debug( "\nToken: $token");
			my $tokenKey = $token->{token};
			return ("failed to extract the token key from login attempt.") if (!$tokenKey);
			$NG->log->debug( "\nTokenKey: $tokenKey");
			$headers = {"Content-type" => 'application/json', Accept => 'application/json', "X-F5-Auth-Token" => $tokenKey};
			$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/virtual/');
			$res     = $client->get($url => $headers)->result;
			$body    = decode_json($res->body);
	 		$NG->log->debug3("Main Query: ". Dumper($body). "\n\n\n");
			my $items = $body->{items};
			foreach my $item (@$items) {
				$NG->log->debug8( Dumper($item) . "\n");
				my $resourceId      = $item->{fullPath};
				my @destination     = split('[/:]', $item->{destination});
				my $name            = $item->{fullPath};
				my $address         = $destination[2];
				my $port            = $destination[3];
				my $ipProtocol      = $item->{ipProtocol};
				my $connectionLimit = $item->{connectionLimit};
				my $pool            = $item->{pool};
				my $poolId          = $pool;
				$resourceId         =~ s!/!~!g;
				$poolId             =~ s!/!~!g;

				$NG->log->debug("Virtual Server Name               = $name");
				$NG->log->debug("Resource ID                       = $resourceId");
				$NG->log->debug("Virtual Server Address            = $address");
				$NG->log->debug("Virtual Server Port               = $port");
				$NG->log->debug("Virtual Server IP Protocol        = $ipProtocol");
				$NG->log->debug("Virtual Server Connnnection Limit = $connectionLimit");
				$NG->log->debug("Pool                              = $pool");

				# make the index as a named thing as normal
				$f5Data->{$name}->{index}                          = $name;
				$f5Data->{$name}->{ifIndex}                        = $name;
				$f5Data->{$name}->{ifDesc}                         = $name;
				$f5Data->{$name}->{ltmVirtualServName}             = $name;
				$f5Data->{$name}->{ltmVirtualServAddr}             = $address;
				$f5Data->{$name}->{ltmVirtualServPort}             = $port;
				$f5Data->{$name}->{virtualServIpProto}             = $ipProtocol;
				$f5Data->{$name}->{poolMbrPoolName}                = $pool;
				$f5Data->{$name}->{ResourceID}                     = $resourceId;
				$f5Data->{$name}->{Pool}->{$pool}->{name}          = $pool;
				$f5Data->{$name}->{Pool}->{$pool}->{poolID}        = $poolId;

				$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/virtual/'.$resourceId.'/stats');
				$res     = $client->get($url => $headers)->result;
				$body    = decode_json($res->body);
				$NG->log->debug3("Resource Query: ". Dumper($body). "\n\n\n");
				my $entries = $body->{entries};
				foreach my $entry (keys %$entries) {
					my $urlEntry                                   = $$entries{$entry};
					my $nestedStats                                = $$urlEntry{nestedStats};
					my $subEntries                                 = $$nestedStats{entries};
					my $statusAvailState                           = $$subEntries{'status.availabilityState'}->{description};
					my $statusEnabledState                         = $$subEntries{'status.enabledState'}->{description};
					my $statusStatusReason                         = $$subEntries{'status.statusReason'}->{description};
					my $clientsideBitsIn                           = $$subEntries{'clientside.bitsIn'}->{value};
					my $clientsideBitsOut                          = $$subEntries{'clientside.bitsOut'}->{value}; 
					my $clientsideCurConns                         = $$subEntries{'clientside.curConns'}->{value}; 
					my $clientsideMaxConns                         = $$subEntries{'clientside.maxConns'}->{value}; 
					my $clientsidePktsIn                           = $$subEntries{'clientside.pktsIn'}->{value}; 
					my $clientsidePktsOut                          = $$subEntries{'clientside.pktsOut'}->{value}; 
					my $clientsideTotConns                         = $$subEntries{'clientside.totConns'}->{value}; 
					$NG->log->debug("Availability State            = $statusAvailState");
					$NG->log->debug("Enabled State                 = $statusEnabledState");
					$NG->log->debug("Status Reason                 = $statusStatusReason");
					$NG->log->debug("Clientside Bits In            = $clientsideBitsIn");
					$NG->log->debug("Clientside Bits Out           = $clientsideBitsOut");
					$NG->log->debug("Clientside Cur Connections    = $clientsideCurConns");
					$NG->log->debug("Clientside Max Connections    = $clientsideMaxConns");
					$NG->log->debug("Clientside Pkts In            = $clientsidePktsIn");
					$NG->log->debug("Clientside Pkts Out           = $clientsidePktsOut");
					$NG->log->debug("Clientside Total Connections  = $clientsideTotConns");
					$f5Data->{$name}->{statusAvailState}           = $statusAvailState;
					$f5Data->{$name}->{statusEnabledState}         = $statusEnabledState;
					$f5Data->{$name}->{statusStatusReason}         = $statusStatusReason;
					$f5Data->{$name}->{clientsideBitsIn}           = $clientsideBitsIn;
					$f5Data->{$name}->{clientsideBitsOut}          = $clientsideBitsOut;
					$f5Data->{$name}->{clientsideCurConns}         = $clientsideCurConns;
					$f5Data->{$name}->{clientsideMaxConns}         = $clientsideMaxConns;
					$f5Data->{$name}->{clientsidePktsIn}           = $clientsidePktsIn;
					$f5Data->{$name}->{clientsidePktsOut}          = $clientsidePktsOut;
					$f5Data->{$name}->{clientsideTotConns}         = $clientsideTotConns;
				}
				$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/pool/'.$poolId.'/members');
				$res     = $client->get($url => $headers)->result;
				$body    = decode_json($res->body);
				$NG->log->debug3("Member Query: ". Dumper($body). "\n\n\n");
				my $members = $body->{items};
				foreach my $member (@$members) {
					$NG->log->debug8("Member: " .  Dumper($member) . "\n");
					my $memberId        = $member->{fullPath};
					$memberId           =~ s!/!~!g;
					my $memberName      = $member->{fullPath};
					my $connectionLimit = $member->{connectionLimit};
					my $state           = $member->{state};
	
					$NG->log->debug("Member Index            = ${name}${memberName}");
					$NG->log->debug("Member Name             = $memberName");
					$NG->log->debug("Member ID               = $memberId");
					$NG->log->debug("Member Conn Limit       = $connectionLimit");
					$NG->log->debug("Member State            = $state");
	
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{index}                    = "${name}${memberName}";
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{ifIndex}                  = "${name}${memberName}";
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{name}                     = $memberName;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{ifDesc}                   = $memberName;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{poolMbrPoolName}          = $name;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{poolMbrNodeName}          = $memberName;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{connLimit}                = $connectionLimit;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{memberID}                 = $memberId;
					$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{state}                    = $state;
					$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/pool/'.$poolId.'/members/'.$memberId.'/stats/');
					$res     = $client->get($url => $headers)->result;
					$body    = decode_json($res->body);
					$NG->log->debug3("Member Stats Query: ". Dumper($body). "\n\n\n");
					my $entries = $body->{entries};
					foreach my $entry (keys %$entries) {
						my $urlEntry                                = $$entries{$entry};
						my $nestedStats                             = $$urlEntry{nestedStats};
						my $subEntries                              = $$nestedStats{entries};
						my $address                                 = $$subEntries{'addr'}->{description};
						my $port                                    = $$subEntries{'port'}->{value}; 
						my $statusAvailState                        = $$subEntries{'status.availabilityState'}->{description};
						my $statusEnabledState                      = $$subEntries{'status.enabledState'}->{description};
						my $statusStatusReason                      = $$subEntries{'status.statusReason'}->{description};
						my $serversideBitsIn                        = $$subEntries{'serverside.bitsIn'}->{value};
						my $serversideBitsOut                       = $$subEntries{'serverside.bitsOut'}->{value}; 
						my $serversideCurConns                      = $$subEntries{'serverside.curConns'}->{value}; 
						my $serversideMaxConns                      = $$subEntries{'serverside.maxConns'}->{value}; 
						my $serversidePktsIn                        = $$subEntries{'serverside.pktsIn'}->{value}; 
						my $serversidePktsOut                       = $$subEntries{'serverside.pktsOut'}->{value}; 
						my $serversideTotConns                      = $$subEntries{'serverside.totConns'}->{value}; 
						$NG->log->debug("MemberAddress              = $address");
						$NG->log->debug("MemberPort                 = $port");
						$NG->log->debug("Member Availability        = $statusAvailState");
						$NG->log->debug("Member Enabled             = $statusEnabledState");
						$NG->log->debug("Member Status Reason       = $statusStatusReason");
						$NG->log->debug("Member Bits In             = $serversideBitsIn");
						$NG->log->debug("Member Bits Out            = $serversideBitsOut");
						$NG->log->debug("Member Current Connections = $serversideCurConns");
						$NG->log->debug("Member Max Connections     = $serversideMaxConns");
						$NG->log->debug("Member Pkts In             = $serversidePktsIn");
						$NG->log->debug("Member Pkts Out            = $serversidePktsOut");
						$NG->log->debug("Member Total Connections   = $serversideTotConns");
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{poolMbrAddr}                 = $address;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{poolMbrPort}                 = $port;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{poolMbrAvailState}           = $statusAvailState;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{Enabled}                     = $statusEnabledState;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{statusReason}                = $statusStatusReason;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{bitsIn}                      = $serversideBitsIn;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{bitsOut}                     = $serversideBitsOut;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{curConns}                    = $serversideCurConns;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{maxConns}                    = $serversideMaxConns;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{pktsIn}                      = $serversidePktsIn;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{pktsOut}                     = $serversidePktsOut;
						$f5Data->{$name}->{Pool}->{$pool}->{Member}->{$memberName}->{totConns}                    = $serversideTotConns;
					}
				}
			}
		}
	}

	# send back the results.
	return ($errMsg,$f5Data,$f5Info);
}

sub loadJsonFile {
	my $file = shift;
	my $data = undef;
	my $errMsg;

	open(FILE, $file) or $errMsg = "ERROR File '$file': $!";
	if ( not $errMsg ) {
		local $/ = undef;
		my $JSON = <FILE>;

		# fallback between utf8 (correct) or latin1 (incorrect but not totally uncommon)
		$data = eval { decode_json($JSON); };
		$data = eval { JSON::XS->new->latin1(1)->decode($JSON); } if ($@);
		if ( $@ ) {
			$errMsg = "ERROR Unable to convert '$file' to hash table (neither utf-8 nor latin-1), $@\n";
		}
		close(FILE);
	}

	return ($errMsg,$data);
}

1;
