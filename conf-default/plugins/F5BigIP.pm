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
package F5BigIP;
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
		$NG->log->info("Skipping Host Resources plugin for node::$node, Node Down");
		return ( error => "Node Down, skipping Host Resources plugin");
	}
	else {
		$NG->log->info("Running plugin for node::$node");
	}

	my $changesweremade = 0;

	my $nodeobj = $NG->node(name => $node);
	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	
	return (1,undef) if ( $catchall->{nodeModel} ne "F5-BigIP" or !NMISNG::Util::getbool($catchall->{collect}));

	my $f5Data = getF5Data(name => $node, NG => $NG, C => $C);
	
	my $host_ids = $S->nmisng_node->get_inventory_ids(
		concept => "Host_Storage",
		filter => { historic => 0 });
	
	if (@$host_ids)
	{
		$NG->log->info("Working on '$node'");
		my $f5Data = getF5Data(name => $node, NG => $NG, C => $C);
		if ( defined $f5Data->{error} ) {
			$NG->log->error("ERROR with $node: $f5Data->{error}");
		}
	
		my $Host_Memory;
        
		# look through each of the different types of memory for cache and buffer
		for my $host_id (@$host_ids)
		{
			my ($host_inventory,$error) = $S->nmisng_node->inventory(_id => $host_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $host_id: $error");
				next;
			}

			$changesweremade = 1;
			my $data = $host_inventory->data();
            
			# sanity check the data
			if (   ref($data) ne "HASH"
				or !keys %$data
				or !exists( $data->{index} ) )
			{
				my $index = $data->{index} // 'noindex';
				$NG->log->error("invalid data forindex $index in model, cannot get data for this index!");
				next;
			}
            
			my $type = undef;
			my $typeName = undef;
        
			# is this the physical memory?
			if ( defined $data->{hrStorageDescr} ) {
				if ( $data->{hrStorageDescr} =~ /(Physical memory|RAM)/ ) {
					$typeName = "Memory";
					$type = "physical";
				}
				elsif ( $data->{hrStorageDescr} =~ /(Cached memory|RAM \(Cache\))/ ) {
					$typeName = "Memory";
					$type = "cached";
				}
				elsif ( $data->{hrStorageDescr} =~ /(Memory buffers|RAM \(Buffers\))/ ) {
					$typeName = "Memory";
					$type = "buffers";
				}
				elsif ( $data->{hrStorageDescr} =~ /Virtual memory/ ) {
					$typeName = "Memory";
					$type = "virtual";
				}
				elsif ( $data->{hrStorageDescr} =~ /Swap space/ ) {
					$typeName = "Memory";
					$type = "swap";
				}
				elsif ( $data->{hrStorageType} =~ /FixedDisk/ ) {
					$typeName = "Fixed Disk";
					$type = "disk";
				}
				elsif ( $data->{hrStorageType} =~ /NetworkDisk/ ) {
					$typeName = "Network Disk";
					$type = "disk";
				}
				elsif ( $data->{hrStorageType} =~ /RemovableDisk/ ) {
					$typeName = "Removable Disk";
					$type = "disk";
				}
				elsif ( $data->{hrStorageType} =~ /Disk/ ) {
					$typeName = "Other Disk";
					$type = "disk";
				}
				elsif ( $data->{hrStorageType} =~ /FlashMemory/ ) {
					$typeName = "Flash Memory";
					$type = "disk";
				}
				else {
					$typeName = $data->{hrStorageType};
					$type = "other";
				}
			}
			else {
				$typeName = "Unknown";
				$type = "other";
			}
            
			if ( $typeName eq "Memory" ) {
				$NG->log->info("Host Memory Type = $data->{hrStorageDescr} interesting as $type");
			}
			else {
				$NG->log->info("Host Storage Type = $data->{hrStorageDescr} less interesting") if defined $data->{hrStorageDescr};
			}

			# do we have a type of memory to process?
			if ( defined $type ) {
				$Host_Memory->{$type ."_total"} = $data->{hrStorageSize};
				$Host_Memory->{$type ."_used"} = $data->{hrStorageUsed};
				$Host_Memory->{$type ."_units"} = $data->{hrStorageAllocationUnits};
			}
            
			if ( defined $data->{hrStorageUnits} and defined $data->{hrStorageSize} and defined $data->{hrStorageUsed} ) {
				# must guard against 'noSuchInstance', which surivies first check b/c non-empty
				my $sizeisnumber = ( $data->{hrStorageSize}
										 # int or float
										 && $data->{hrStorageSize} =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );

				$data->{hrStorageUtil} = sprintf("%.1f", $data->{hrStorageUsed} / $data->{hrStorageSize} * 100)
						if (defined $sizeisnumber && $sizeisnumber && $data->{hrStorageSize} != 0);

				$data->{hrStorageTotal} = NMISNG::Util::getDiskBytes($data->{hrStorageUnits} * $data->{hrStorageSize})
						if (defined $sizeisnumber && $sizeisnumber && $data->{hrStorageUnits});

				my $usedisnumber = ($data->{hrStorageUsed}
										&& $data->{hrStorageUsed} =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );
				$data->{hrStorageUsage} = NMISNG::Util::getDiskBytes($data->{hrStorageUnits} * $data->{hrStorageUsed})
						if (defined $usedisnumber && $usedisnumber && $data->{hrStorageUnits});

				$data->{hrStorageTypeName} = $typeName;

				my @summary;
				push(@summary,"Size: $data->{hrStorageTotal}<br/>") if ($sizeisnumber);
				push(@summary,"Used: $data->{hrStorageUsage} ($data->{hrStorageUtil}%)<br/>") if ($usedisnumber);
				push(@summary,"Partition: $data->{hrPartitionLabel}<br/>") if defined $data->{hrPartitionLabel};

				$data->{hrStorageSummary} = join(" ",@summary);
                
                # Save the data
                $host_inventory->data($data); # set changed info
                (undef,$error) = $host_inventory->save; # and save to the db, update not required
                $NG->log->error("Failed to save inventory for ".$data->{hrStorageTypeName}. " : $error")
                        if ($error);
			}
        } # Foreach
        if ( ref($Host_Memory) eq "HASH" ) {
			# lets calculate the available memory
			# https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/5/html/tuning_and_optimizing_red_hat_enterprise_linux_for_oracle_9i_and_10g_databases/chap-oracle_9i_and_10g_tuning_guide-memory_usage_and_page_cache
			# So available total is the physical memory total
			$Host_Memory->{available_total} = $Host_Memory->{physical_total};
			$Host_Memory->{available_units} = $Host_Memory->{physical_units};

			# available used is the physical used but subtract the cached and buffer memory which is available for use.
			$Host_Memory->{available_used} = $Host_Memory->{physical_used} - $Host_Memory->{cached_used} - $Host_Memory->{buffers_used};
			# we don't need total for cache, buffers and available as it is really physical
			# the units all appear to be the same so just keeping physical
			my $rrddata = {
				'physical_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_total}},
				'physical_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_used}},
				'physical_units' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_units}},
				'available_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{available_used}},
				'cached_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{cached_used}},
				'buffers_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{buffers_used}},
				'virtual_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{virtual_total}},
				'virtual_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{virtual_used}},
				'swap_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{swap_total}},
				'swap_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{swap_used}},

				#'buffers_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{buffers_total}},
				#'cached_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{cached_total}},
			};

            my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>"Host_Memory");
			# check for RRD update errors
			if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed!") };

			$NG->log->info("Host_Memory total=$Host_Memory->{physical_total} physical=$Host_Memory->{physical_used} available=$Host_Memory->{available_used} cached=$Host_Memory->{cached_used} buffers=$Host_Memory->{buffers_used} to $updatedrrdfileref") if ($updatedrrdfileref);
			$NG->log->debug("Host_Memory Object: ". Dumper($Host_Memory),1);
		}
        
    }

	return ($changesweremade,undef); # report if we changed anything
}


sub getF5Data {
	my %args = @_;
	my $deviceName = $args{name};
	my $NG = $args{NG};
	my $C = $args{C};
	
	my $error          = 0;
	my $apiUser        = "";
	my $apiPass        = "";
	my $apiPort        = "";
	my $databaseDir    = "";
	my $historySeconds = "";
	my $f5Data;
	my $name;
	my $f5State;
	
	my ($errmsg, $f5Config) = loadJsonFile($C->{'plugin_root_default'} . "/F5BigIP.json");
	if (defined($errmsg)) {
		$NG->log->error("$errmsg");
		$error = 1;
	} else {
		$apiUser           = $f5Config->{apiUser};
		$apiPass           = $f5Config->{apiPass};
		$apiPort           = $f5Config->{apiPort};
		$databaseDir       = $f5Config->{databaseDir};
		$historySeconds    = $f5Config->{historySeconds};

		if (!defined($apiUser) || $apiUser eq '' || !defined($apiPass) || $apiPass eq '') {
			$NG->log->error("ERROR API Username or Password not supplied");
			$error = 1;
		}
		if (!defined($apiPort) || $apiPort !~ /^\d+\z/) {
			$NG->log->error("ERROR API Port value is not defined, or is not an integer.");
			$error = 1;
		}
		#if (!defined($databaseDir) || !-d $databaseDir || !-w $databaseDir) {
		#	$NG->log->error("ERROR Database '$databaseDir' does not exist or is not writable.");
		#	$error = 1;
		#}
		if (!defined($historySeconds) || $historySeconds !~ /^\d+\z/) {
			$NG->log->error("ERROR Historic value is not defined, or is not an integer.");
			$error = 1;
		}
		unless ($error) {
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
			my $url     = Mojo::URL->new('https://'.$name.':'.$apiPort.'/mgmt/shared/authn/login')->userinfo("'".$apiUser.":".$apiPass."'");
			$client->insecure(1);
			$res = $client->post($url => $headers => "{'username': 'oper', 'password':'apiadmin1', 'loginProviderName':'tmos'}")->result;
			my $body     = decode_json($res->body);
			my $token    = $body->{token};
			my $tokenKey = $token->{token};
			$NG->log->debug( "\n$tokenKey");
			$headers = {"Content-type" => 'application/json', Accept => 'application/json', "X-F5-Auth-Token" => $tokenKey};
			$url     = Mojo::URL->new('https://'.$name.':'.$apiPort.'/mgmt/tm/ltm/virtual/');
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
				my $status          = $_->{status};
				my $address         = $destination[2];
				my $port            = $destination[3];
				my $ipProtocol      = $_->{ipProtocol};
				my $connectionLimit = $_->{connectionLimit};
				my $pool            = $_->{pool};
				$NG->log->debug( "Name                      = $name");
				$NG->log->debug( "ResourceID                = $resourceId");
				$NG->log->debug( "Status                    = $status");
				$NG->log->debug( "Address                   = $address");
				$NG->log->debug( "Port                      = $port");
				$NG->log->debug( "IPProtocol                = $ipProtocol");
				$NG->log->debug( "ConnectionLimit           = $connectionLimit");
				$NG->log->debug( "Pool                      = $pool");
				$f5State->{name}                    = $name;
				$f5State->{name}->{ResourceID}      = $resourceId;
				$f5State->{name}->{Status}          = $status;
				$f5State->{name}->{Address}         = $address;
				$f5State->{name}->{Port}            = $port;
				$f5State->{name}->{IPProtocol}      = $ipProtocol;
				$f5State->{name}->{ConnectionLimit} = $connectionLimit;
				$f5State->{name}->{Pool}            = $pool;
			    $url     = Mojo::URL->new('https://'.$name.':'.$apiPort.'/mgmt/tm/ltm/virtual/'.$resourceId.'/stats');
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
					$NG->log->debug( "Status Availability State = $statusAvailabilityState");
					$NG->log->debug( "Status Enabled State      = $statusEnabledState");
					$NG->log->debug( "Status Status Reason      = $statusStatusReason");
					$NG->log->debug( "Clientside Bits In        = $clientsideBitsIn");
					$NG->log->debug( "Clientside Bits Out       = $clientsideBitsOut");
					$NG->log->debug( "Clientside Cur Conns      = $clientsideCurConns");
					$NG->log->debug( "Clientside Max Conns      = $clientsideMaxConns");
					$NG->log->debug( "Clientside Pkts In        = $clientsidePktsIn");
					$NG->log->debug( "Clientside Pkts Out       = $clientsidePktsOut");
					$NG->log->debug( "Clientside Total Conns    = $clientsideTotConns");
				    $f5State->{name}->{statusAvailabilityState} = $statusAvailabilityState;
				    $f5State->{name}->{statusEnabledState}      = $statusEnabledState;
				    $f5State->{name}->{statusStatusReason}      = $statusStatusReason;
				    $f5State->{name}->{clientsideBitsIn}        = $clientsideBitsIn;
				    $f5State->{name}->{clientsideBitsOut}       = $clientsideBitsOut;
				    $f5State->{name}->{clientsideCurConns}      = $clientsideCurConns;
				    $f5State->{name}->{clientsideMaxConns}      = $clientsideMaxConns;
				    $f5State->{name}->{clientsidePktsIn}        = $clientsidePktsIn;
				    $f5State->{name}->{clientsidePktsOut}       = $clientsidePktsOut;
				    $f5State->{name}->{clientsideTotConns}      = $clientsideTotConns;
				}
			}
		}
	}

	# send back the results.
	return $f5Data;
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
            $errMsg= "ERROR Unable to convert '$file' to hash table (neither utf-8 nor latin-1), $@\n";
        }
        close(FILE);
    }

    return ($errMsg,$data);
}


1;
