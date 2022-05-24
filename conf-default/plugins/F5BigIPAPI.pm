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
#	"databaseDir":"/usr/local/nmis9/var/f5",
#	"historySeconds":300
#}

# TODO, do we need the databaseDir?

package F5BigIPAPI;
our $VERSION = "1.0.0";

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Data::Dumper;
use JSON::XS;
use Mojo::Base;
use Mojo::UserAgent;

use NMISNG;
use NMISNG::rrdfunc;

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# is the node down or is SNMP down?
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return ( error => "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall_data = $inventory->data();
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
		$NG->log->info("Skipping F5BigIP plugin for node::$node, Node Down");
		return ( error => "Node Down, skipping F5BigIP plugin");
	}
	else {
		$NG->log->info("Running F5BigIP Collect plugin for node::$node");
	}

	my $changesweremade = 0;

	my $nodeobj = $NG->node(name => $node);

	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	
	return (1,undef) if ( $catchall->{nodeModel} ne "F5-BigIP-API" or !NMISNG::Util::getbool($catchall->{collect}));

	$NG->log->info("Working on '$node' getting API data now");
	my ($errmsg, $f5Data, $f5Info) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR with $node: $errmsg");
		return (1,undef);
	}

	if (!defined $f5Data || ref($f5Data) ne "HASH") {
		$NG->log->error("ERROR with $node: Got no data!");
		return (1,undef);
	}
	my %f5DataHash = $f5Data;

	# this is the concept/section we are working on
	my $section = "VirtualServTable";

	# get a list of virtual servers, which are indexed the same as the API data
	my $VirtualServs = $S->nmisng_node->get_inventory_ids(
		concept => $section,
		filter => { historic => 0 });
	
	# do we have some inventory?
	if (@$VirtualServs)
	{
		$NG->log->debug("Virtual Serv: ". Dumper($VirtualServs));
		# process each inventory thing, matching it to the API data using the index/name
		foreach my $serv_id (@$VirtualServs)
		{
			$NG->log->debug("Virtual Serv: serv_id=$serv_id ". Dumper($serv_id));
			# get the inventory object for this specific item.
			my ($serv_inventory,$error) = $S->nmisng_node->inventory(_id => $serv_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $serv_id: $error");
				next;
			}
			# tell the plugin to save stuff.
			$changesweremade = 1;

			# get a handy pointer to the data
			my $data = $serv_inventory->data();

			# get the name of the thing to use.
			my $name = $data->{index};

			$NG->log->debug("Virtual Serv Name: $name, $serv_id");

			# get the F5 data out.
			if (!defined($f5DataHash{$name}) || ref($f5DataHash{$name}) ne "HASH")
			{
				$NG->log->error("Failed to get inventory for $serv_id");
				next;
			}
			my $f5SubData = $f5DataHash{$name};
			$NG->log->debug2(Dumper($f5SubData));

			# TODO what possible values are they 100 is good, less than 100 is bad.
			#default value is assumed to be "available"
			my $statusAvailabilityState = 100;
			if ( $f5SubData->{statusAvailabilityState} eq "available" ) {
				$statusAvailabilityState = 100 
			}
			elsif ( $f5SubData->{statusAvailabilityState} eq "offline" ) {
				$statusAvailabilityState = 50 
			}
			else {
				$statusAvailabilityState = 10 	
			}

			#save to integers to RRD
			my $rrddata = {
				'ltmStatClientCurCon' => { "option" => "gauge,0:U", "value" => $f5SubData->{clientsideCurConns} },
				'ltmVsStatAvailState' => { "option" => "gauge,0:100", "value" => $statusAvailabilityState }
			};

			# ensure the RRD file is using the inventory record so it will use the correct RRD file.
			my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>$section, index=>$name, inventory=>$serv_inventory);

			# check for RRD update errors
			if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed!") };

			# update the data for the GUI
			$data->{statusAvailabilityState} = $f5SubData->{statusAvailabilityState};
			$data->{ltmVsStatusAvailStateText} = $f5SubData->{statusAvailabilityState};
			$data->{ltmStatClientCurCon} = $f5SubData->{clientsideCurConns};
			$data->{ltmVsStatAvailState} = $statusAvailabilityState;

			# alerts in NMIS model won't fire after this has run.
			# TODO Raise an alert if the Virtual Server is down.

            # Save the data so it appears in the GUI
            $serv_inventory->data($data); # set changed info
            (undef,$error) = $serv_inventory->save; # and save to the db
            $NG->log->error("Failed to save inventory for ".$name. " : $error") if ($error);
		}
	}
	else {
		return ( error => "no inventory for $section")
	}


	return ($changesweremade,undef); # report if we changed anything
}

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# is the node down or is SNMP down?
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return ( error => "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall_data = $inventory->data();
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
		$NG->log->info("Skipping F5BigIP plugin for node::$node, Node Down");
		return ( error => "Node Down, skipping F5BigIP plugin");
	}
	else {
		$NG->log->info("Running F5BigIP Update plugin for node::$node");
	}

	my $changesweremade = 0;
	my $nodeobj         = $NG->node(name => $node);
	my $catchall        = $S->inventory( concept => 'catchall' )->{_data};
	
	return (1,undef) if ( $catchall->{nodeModel} ne "F5-BigIP-API");

	$NG->log->info("Working on '$node'");
	my ($errmsg, $f5Data, $f5Info) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR with $node: $errmsg");
		return (1,undef);
	}

	if (!defined $f5Data || ref($f5Data) ne "HASH") {
		$NG->log->error("ERROR with $node: Got no data!");
		return (1,undef);
	}
	my %f5DataHash = $f5Data;

	$changesweremade = 1;

	my $section = "VirtualServTable";

	# Archive historic records (I think?)
	my $VirtualServs = $S->nmisng_node->get_inventory_ids(
		concept => $section,
		filter => { historic => 0 });
	if (@$VirtualServs)
	{
		my $result = $nodeobj->bulk_update_inventory_historic(active_indices => $VirtualServs, concept => $section );
		$NG->log->error("bulk update historic failed: $result->{error}") if ($result->{error});
	}

	# Process what we got.
	foreach my $name (keys(%$f5Data))
	{
		$NG->log->debug("Processing $section Index: '$name'");
		# get the F5 data out.
		if (!defined($f5DataHash{$name}) || ref($f5DataHash{$name}) ne "HASH")
		{
			$NG->log->error("Failed to get inventory for $name");
			next;
		}
		my $f5SubData = $f5DataHash{$name};
		$NG->log->debug4(Dumper($f5SubData));

		$NG->log->debug2("section=$section index=$name read and stored");
		my $path_keys =  ['index'];
		my $path = $nodeobj->inventory_path( concept => $section, path_keys => $path_keys, data => $f5SubData );
		$NG->log->debug4( "$section path ".join(',', @$path));

		# now get-or-create an inventory object for this new concept
		my ( $subInventory, $error_message ) = $nodeobj->inventory(
			create    => 1,
			concept   => $section,
			data      => $f5SubData,
			path_keys => $path_keys,
			path      => $path
		);
		$NG->log->error("Failed to create inventory, error:$error_message") && next if ( !$subInventory );
		
		# regenerate the path, if this thing wasn't new the path may have changed, which is ok
		$subInventory->path( recalculate => 1 );
		$subInventory->data($f5SubData);
		$subInventory->historic(0);
		$subInventory->enabled(1);

		# set which columns should be displayed
		$subInventory->data_info(
			subconcept => $section,
			enabled => 1,
			display_keys => $f5Info
		);

		$subInventory->description( $name );

		# get the RRD file name to use for storage.
		my $dbname = $S->makeRRDname(graphtype => $section,
									index      => $name,
									inventory  => $subInventory,
									relative   => 1);
		$NG->log->debug("Collect F5 API data info check storage $section, dbname $dbname");

		# set the storage name into the inventory model
		$subInventory->set_subconcept_type_storage(type => "rrd",
														subconcept => $section,
														data => $dbname) if ($dbname);

		# the above will put data into inventory, so save
		my ( $op, $subError ) = $subInventory->save();
		$NG->log->debug2( "saved ".join(',', @$path)." op: $op");
		if ($subError)
		{
			$NG->log->error("Failed to save inventory for Virtual Server '$name': $subError");
		}
		else
		{
			$changesweremade = 1;
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
	my $databaseDir    = "";
	my $historySeconds = "";
	my $f5Data         = undef;
	my $f5Info         = undef;
	my $errMsg         = undef;
	my $name;
	
	my ($errmsg, $f5Config) = loadJsonFile($C->{'<nmis_conf>'} . "/F5BigIP.json");
	unless (defined($errmsg)) {
		$apiUser           = $f5Config->{apiUser};
		$apiPass           = $f5Config->{apiPass};
		$apiPort           = $f5Config->{apiPort};
		$databaseDir       = $f5Config->{databaseDir};
		$historySeconds    = $f5Config->{historySeconds};

		if (!defined($apiUser) || $apiUser eq '' || !defined($apiPass) || $apiPass eq '') {
			$errmsg = "ERROR API Username or Password not supplied";
		}
		if (!defined($apiPort) || $apiPort !~ /^\d+\z/) {
			$errmsg = "ERROR API Port value is not defined, or is not an integer.";
		}
		#if (!defined($databaseDir) || !-d $databaseDir || !-w $databaseDir) {
		#	$errmsg = "ERROR Database '$databaseDir' does not exist or is not writable.";
		#}
		if (!defined($historySeconds) || $historySeconds !~ /^\d+\z/) {
			$errmsg = "ERROR Historic value is not defined, or is not an integer.";
		}
		unless (defined($errmsg)) {
			$f5Info->{index}                   = "Index";
			$f5Info->{ltmVirtualServName}      = "Server Name";
			$f5Info->{ltmVirtualServAddr}      = "IP Address";
			$f5Info->{ltmVirtualServPort}      = "Port";
			$f5Info->{ltmVirtualServIpProto}   = "IP Proto";
			$f5Info->{ltmVirtualServConnLimit} = "ConnLimit";
			$f5Info->{ltmVsStatusAvailState}   = "VS Status";
			$f5Info->{ltmVsStatusAvailStateText} = "Virtual Server State";
			#$f5Info->{Pool}                    = "Pool";
			#$f5Info->{ResourceID}              = "Resource ID";
			#$f5Info->{Status}                  = "Status";
			#$f5Info->{statusEnabledState}      = "Status Enabled State";
			#$f5Info->{statusStatusReason}      = "Status Status Reason";
			#$f5Info->{clientsideBitsIn}        = "Clientside Bits In";
			#$f5Info->{clientsideBitsOut}       = "Clientside Bits Out";
			#$f5Info->{clientsideCurConns}      = "Clientside Current Connections";
			#$f5Info->{clientsideMaxConns}      = "Clientside Max Connections";
			#$f5Info->{clientsidePktsIn}        = "Clientside Pkts In";
			#$f5Info->{clientsidePktsOut}       = "Clientside Pkts Out";
			#$f5Info->{clientsideTotConns}      = "Clientside Total Connections";
			$NG->log->debug("apiUser        = $apiUser");
			$NG->log->debug("apiPass        = $apiPass");
			$NG->log->debug("apiPort        = $apiPort");
			$NG->log->debug("databaseDir    = $databaseDir");
			$NG->log->debug("historySeconds = $historySeconds");
			my $type;
			my $request_body;
			my $res;
			my $headers = {"Content-type" => 'application/json', Accept => 'application/json'};
			my $client  = Mojo::UserAgent->new();
			my $url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/shared/authn/login')->userinfo("'".$apiUser.":".$apiPass."'");
			$client->insecure(1);
			$res = $client->post($url => $headers => "{'username': 'oper', 'password':'apiadmin1', 'loginProviderName':'tmos'}")->result;
			my $body     = decode_json($res->body);
			my $token    = $body->{token};
			my $tokenKey = $token->{token};
			$NG->log->debug( "\nTokenKey: $tokenKey");
			$headers = {"Content-type" => 'application/json', Accept => 'application/json', "X-F5-Auth-Token" => $tokenKey};
			$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/virtual/');
			$res     = $client->get($url => $headers)->result;
			$body    = decode_json($res->body);
	 		$NG->log->debug("Main Query: ". Dumper($body). "\n\n\n");
			my $items = $body->{items};
			foreach (@$items) {
				#$NG->log->debug( Dumper($_) . "\n");
				my $resourceId      = $_->{fullPath};
				$resourceId         =~ s!/!~!g;
				my @destination     = split('[/:]', $_->{destination});
				my $name            = $_->{fullPath};
				my $address         = $destination[2];
				my $port            = $destination[3];
				my $ipProtocol      = $_->{ipProtocol};
				my $connectionLimit = $_->{connectionLimit};
				my $pool            = $_->{pool};

				$NG->log->debug("ltmVirtualServName        = $name");
				$NG->log->debug("ResourceID                = $resourceId");
				$NG->log->debug("ltmVirtualServAddr        = $address");
				$NG->log->debug("ltmVirtualServPort        = $port");
				$NG->log->debug("ltmVirtualServIpProto     = $ipProtocol");
				$NG->log->debug("ltmVirtualServConnLimit   = $connectionLimit");
				$NG->log->debug("Pool                      = $pool");

				# make the index as a named thing as normal
				$f5Data->{$name}->{index}                  = $name;
				$f5Data->{$name}->{ltmVirtualServName}     = $name;
				$f5Data->{$name}->{ltmVirtualServAddr}     = $address;
				$f5Data->{$name}->{ltmVirtualServPort}     = $port;
				$f5Data->{$name}->{ltmVirtualServIpProto}  = $ipProtocol;
				$f5Data->{$name}->{ltmVirtualServConnLimit} = $connectionLimit;
				$f5Data->{$name}->{ResourceID}             = $resourceId;
				$f5Data->{$name}->{Pool}                   = $pool;

				$url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/virtual/'.$resourceId.'/stats');
				$res     = $client->get($url => $headers)->result;
				$body    = decode_json($res->body);
				$NG->log->debug("Resource Query: ". Dumper($body). "\n\n\n");
				my $entries = $body->{entries};
				foreach my $entry (keys %$entries) {
					my $urlEntry                     = $$entries{$entry};
					my $nestedStats                  = $$urlEntry{nestedStats};
					my $subEntries                   = $$nestedStats{entries};
					my $statusAvailabilityState      = $$subEntries{'status.availabilityState'}->{description};
					my $statusEnabledState           = $$subEntries{'status.enabledState'}->{description};
					my $statusStatusReason           = $$subEntries{'status.statusReason'}->{description};
					my $clientsideBitsIn             = $$subEntries{'clientside.bitsIn'}->{value};
					my $clientsideBitsOut            = $$subEntries{'clientside.bitsOut'}->{value}; 
					my $clientsideCurConns           = $$subEntries{'clientside.curConns'}->{value}; 
					my $clientsideMaxConns           = $$subEntries{'clientside.maxConns'}->{value}; 
					my $clientsidePktsIn             = $$subEntries{'clientside.pktsIn'}->{value}; 
					my $clientsidePktsOut            = $$subEntries{'clientside.pktsOut'}->{value}; 
					my $clientsideTotConns           = $$subEntries{'clientside.totConns'}->{value}; 
					$NG->log->debug("Status Availability State = $statusAvailabilityState");
					$NG->log->debug("Status Enabled State      = $statusEnabledState");
					$NG->log->debug("Status Status Reason      = $statusStatusReason");
					$NG->log->debug("Clientside Bits In        = $clientsideBitsIn");
					$NG->log->debug("Clientside Bits Out       = $clientsideBitsOut");
					$NG->log->debug("Clientside Cur Conns      = $clientsideCurConns");
					$NG->log->debug("Clientside Max Conns      = $clientsideMaxConns");
					$NG->log->debug("Clientside Pkts In        = $clientsidePktsIn");
					$NG->log->debug("Clientside Pkts Out       = $clientsidePktsOut");
					$NG->log->debug("Clientside Total Conns    = $clientsideTotConns");
					$f5Data->{$name}->{statusAvailabilityState} = $statusAvailabilityState;
					$f5Data->{$name}->{statusEnabledState}      = $statusEnabledState;
					$f5Data->{$name}->{statusStatusReason}      = $statusStatusReason;
					$f5Data->{$name}->{clientsideBitsIn}        = $clientsideBitsIn;
					$f5Data->{$name}->{clientsideBitsOut}       = $clientsideBitsOut;
					$f5Data->{$name}->{clientsideCurConns}      = $clientsideCurConns;
					$f5Data->{$name}->{clientsideMaxConns}      = $clientsideMaxConns;
					$f5Data->{$name}->{clientsidePktsIn}        = $clientsidePktsIn;
					$f5Data->{$name}->{clientsidePktsOut}       = $clientsidePktsOut;
					$f5Data->{$name}->{clientsideTotConns}      = $clientsideTotConns;
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
