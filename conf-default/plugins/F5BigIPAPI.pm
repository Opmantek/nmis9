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

	$NG->log->info("Working on '$node'");
	my ($errmsg, $f5Data) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR with $node: $errmsg");
		return (1,undef);
	}

	if (!defined $f5Data) {
		$NG->log->error("ERROR with $node: Got no data!");
		return (1,undef);
	}
	$changesweremade = 1;

	# Process what we got.
	for my $name (keys(%$f5Data))
	{
		$NG->log->debug("Name: '$name'");
		my $f5SubData = %$f5Data{$name};
		$NG->log->debug(Dumper($f5SubData));
		for my $key (keys(%$f5SubData))
		{
			$NG->log->debug("$key: '" . (defined($f5SubData->{$key}) ? $f5SubData->{$key} : "") . "'");
		}

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
			'ltmVsStatAvailState' => { "option" => "counter,0:U", "value" => $statusAvailabilityState }
		};

		my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>"VirtualServTable");
		# check for RRD update errors
		if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed!") };

		#save to Inventory

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
	my ($errmsg, $f5Data) = getF5Data(deviceName => $node, NG => $NG, C => $C, nodeObj => $nodeobj);
	if (defined $errmsg) {
		$NG->log->error("ERROR with $node: $errmsg");
		return (1,undef);
	}

	if (!defined $f5Data) {
		$NG->log->error("ERROR with $node: Got no data!");
		return (1,undef);
	}
	$changesweremade = 1;

	# Process what we got.
	for my $name (keys(%$f5Data))
	{
		$NG->log->debug("Name: '$name'");
		my $f5SubData   = %$f5Data{$name};
		$NG->log->debug(Dumper($f5SubData));
		for my $key (keys(%$f5SubData))
		{
			$NG->log->debug("$key: '" . (defined($f5SubData->{$key}) ? $f5SubData->{$key} : "") . "'");
		}
	}
	# cpu_cpm needs to be checked and linked to entitymib items
	my $cpuids = $S->nmisng_node->get_inventory_ids(
		concept => "cpu_cpm",
		filter => { historic => 0 });
	if (@$cpuids)
	{
		$NG->log->info("Working on $node cpu_cpm");

		# for linkage lookup this needs the entitymib inventory as well, but
		# a non-object r/o copy of just the data (no meta) is enough
		my $result = $S->nmisng_node->get_inventory_model(
			concept => "entityMib",
			filter => { historic => 0 });
		if (my $error = $result->error)
		{
			$NG->log->error("Failed to get inventory: $error");
			return(0,undef);
		}

		my %emibdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

		for my $cpuid (@$cpuids)
		{
			my ($cpuinventory,$error) = $S->nmisng_node->inventory(_id => $cpuid);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $cpuid: $error");
				next;
			}

			my $cpudata = $cpuinventory->data; # r/o copy, must be saved back if changed
			my $entityIndex = $cpudata->{cpmCPUTotalPhysicalIndex};

			if (ref($emibdata{$entityIndex}) eq "HASH")
			{
				$cpudata->{entPhysicalName} =
						$emibdata{$entityIndex}->{entPhysicalName};
				$cpudata->{entPhysicalDescr} =
						$emibdata{$entityIndex}->{entPhysicalDescr};

				$changesweremade = 1;

				$cpuinventory->data($cpudata); # set changed info
				(undef,$error) = $cpuinventory->save; # and save to the db
				$NG->log->error("Failed to save inventory for $cpuid: $error")
						if ($error);
			}
			else
			{
				$NG->log->info("entityMib data not available for index $entityIndex");
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
	my $databaseDir    = "";
	my $historySeconds = "";
	my $f5Data         = undef;
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
	# 		$NG->log->debug( Dumper($body). "\n\n\n");
			my $items = $body->{items};
			foreach (@$items) {
				#$NG->log->debug( Dumper($_) . "\n");
				my $resourceId      = $_->{fullPath};
				$resourceId         =~ s!/!~!g;
				my @destination     = split('[/:]', $_->{destination});
				my $name            = $_->{name};
#				my $status          = $_->{status};
				my $address         = $destination[2];
				my $port            = $destination[3];
				my $ipProtocol      = $_->{ipProtocol};
				my $connectionLimit = $_->{connectionLimit};
				my $pool            = $_->{pool};
				$NG->log->debug("Name                      = $name");
				$NG->log->debug("ResourceID                = $resourceId");
#				$NG->log->debug("Status                    = $status");
				$NG->log->debug("Address                   = $address");
				$NG->log->debug("Port                      = $port");
				$NG->log->debug("IPProtocol                = $ipProtocol");
				$NG->log->debug("ConnectionLimit           = $connectionLimit");
				$NG->log->debug("Pool                      = $pool");
				$f5Data->{$name}->{ResourceID}      = $resourceId;
#				$f5Data->{$name}->{Status}          = $status;
				$f5Data->{$name}->{Address}         = $address;
				$f5Data->{$name}->{Port}            = $port;
				$f5Data->{$name}->{IPProtocol}      = $ipProtocol;
				$f5Data->{$name}->{ConnectionLimit} = $connectionLimit;
				$f5Data->{$name}->{Pool}            = $pool;
			    $url     = Mojo::URL->new('https://'.$host.':'.$apiPort.'/mgmt/tm/ltm/virtual/'.$resourceId.'/stats');
			    $res     = $client->get($url => $headers)->result;
			    $body    = decode_json($res->body);
				#$NG->log->debug( Dumper($body). "\n\n\n");
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
	return ($errMsg,$f5Data);
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
