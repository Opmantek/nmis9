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
package Host_Resources;
our $VERSION = "1.0.0";

use strict;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use warnings;
use Data::Dumper;

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
		$NG->log->debug("Skipping Host Resources plugin for node::$node, Node Down");
		return ( error => "Node Down, skipping Host Resources plugin");
	}
	elsif ( NMISNG::Util::getbool( $catchall_data->{snmpdown} ) ) {
		$NG->log->debug("Skipping Host Resources plugin for node::$node, SNMP Down");
		return ( error => "SNMP Down, skipping Host Resources plugin");
	}
	else {
		$NG->log->debug("Running Host Resources plugin for node::$node");
	}

	#my $NI = $S->ndinfo;
	# $NI refers to *-node.json file. eg s2laba1mux1g1-node.json

	my $changesweremade = 0;

	my $host_ids = $S->nmisng_node->get_inventory_ids(
		concept => "Host_Storage",
		filter => { historic => 0 });
	
	if (@$host_ids)
	{
		$NG->log->debug("Working on $node Host Memory Calculations");
		# for saving all the types of memory we want to use
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
				$NG->log->debug("Host Memory Type = $data->{hrStorageDescr} interesting as $type");
			}
			else {
				$NG->log->debug2("Host Storage Type = $data->{hrStorageDescr} less interesting") if defined $data->{hrStorageDescr};
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
                (undef,$error) = $host_inventory->save( node => $node ); # and save to the db
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
			if (!$updatedrrdfileref) { $NG->log->debug("Update RRD failed!") };

			$NG->log->debug("Host_Memory total=$Host_Memory->{physical_total} physical=$Host_Memory->{physical_used} available=$Host_Memory->{available_used} cached=$Host_Memory->{cached_used} buffers=$Host_Memory->{buffers_used} to $updatedrrdfileref") if ($updatedrrdfileref);
			$NG->log->debug2(sub {"Host_Memory Object: ". Dumper($Host_Memory),1});
		}
        
    }

	return ($changesweremade,undef); # report if we changed anything
}

# Update Plugin
sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# anything to do?
	my $changesweremade = 0;
    my ($host_storage, $host_storage_id, $host_file_system, $host_partition);

	# if there is EntityMIB data then load map out the entPhysicalVendorType to the vendor type fields
	# store in the field called Type.
	my $mibs = undef;
    
    my $host_ids = $S->nmisng_node->get_inventory_ids(
		concept => "Host_Storage",
		filter => { historic => 0 });
	
	if (@$host_ids)
	{
		$NG->log->info("Working on $node Host_Storage");
		# for saving all the types of memory we want to use
		$mibs = loadMibs(config => $C, nmisng => $NG);
        
		# look through each of the different types of memory for cache and buffer
		for my $host_id (@$host_ids)
		{
			my ($host_inventory,$error) = $S->nmisng_node->inventory(_id => $host_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $host_id: $error");
				next;
			}
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
            
            # Save new structure
            $host_storage->{$data->{index}} = $data;
            $host_storage_id->{$data->{index}} = $host_id;
            
            if ( defined $data->{hrStorageType} and defined $mibs->{$data->{hrStorageType}} and $mibs->{$data->{hrStorageType}} ne "" ) {
				$data->{hrStorageTypeOid} = $data->{hrStorageType};
				$data->{hrStorageType} = $mibs->{$data->{hrStorageType}};
				$changesweremade = 1;
                # Save the data
                $host_inventory->data($data); # set changed info
                (undef,$error) = $host_inventory->save(node => $node); # and save to the db
                $NG->log->error("Failed to save inventory for ".$data->{index}. " : $error")
                        if ($error);
			}
			else {
				$NG->log->debug("Host_Storage no name found for $data->{hrStorageType}") if defined $data->{hrStorageType};
			}       
        }
    }

	#  hrFSTypeOid
    my $host_ids_fs = $S->nmisng_node->get_inventory_ids(
		concept => "Host_File_System",
		filter => { historic => 0 });
	
	if (@$host_ids)
	{
		$NG->log->debug("Working on $node Host_File_System");
		# for saving all the types of memory we want to use
		$mibs = loadMibs(config => $C, nmisng => $NG) if not defined $mibs;
        
		# look through each of the different types of memory for cache and buffer
		for my $host_id (@$host_ids_fs)
		{
			my ($host_inventory,$error) = $S->nmisng_node->inventory(_id => $host_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $host_id: $error");
				next;
			}
            my $data = $host_inventory->data();
            my $changed = 0;
            
            # sanity check the data
			if (   ref($data) ne "HASH"
				or !keys %$data
				or !exists( $data->{index} ) )
			{
				my $index = $data->{index} // 'noindex';
				$NG->log->error("invalid data forindex $index in model, cannot get data for this index!");
				next;
			}
            
            $host_file_system->{$data->{index}} = $data;
            
            if ( defined $data->{hrFSType} and defined $mibs->{$data->{hrFSType}} and $mibs->{$data->{hrFSType}} ne "" ) {
				$data->{hrFSTypeOid} = $data->{hrFSType};
				$data->{hrFSType} = $mibs->{$data->{hrFSType}};

				$changesweremade = 1;
                $changed = 1;
			}
			else {
				$NG->log->debug("Host_File_System no name found for $data->{hrFSType}",1);
			}
            
            # lets cross link the file system to the storage.
			if ( defined $host_storage->{$data->{hrFSStorageIndex}}->{hrStorageDescr} ) {
				$data->{hrStorageDescr} = $host_storage->{$data->{hrFSStorageIndex}}->{hrStorageDescr};
				$data->{hrStorageDescr_url} = "/cgi-nmis9/network.pl?conf=$C->{conf}&act=network_system_health_view&section=Host_Storage&node=$node";
				$data->{hrStorageDescr_id} = "node_view_$node";

				$changesweremade = 1;
                $changed = 1;
			}
            
            if ($changed) {
                $host_inventory->data($data); # set changed info
                (undef,$error) = $host_inventory->save(node => $node); # and save to the db, update not required
                $NG->log->error("Failed to save inventory for ".$data->{index}. " : $error")
                        if ($error);
            }
            
        }
    }
    
    my $host_ids_p = $S->nmisng_node->get_inventory_ids(
		concept => "Host_Partition",
		filter => { historic => 0 });
	
	if (@$host_ids)
	{
		$NG->log->debug("Working on $node Host_Partition");
		# for saving all the types of memory we want to use
        $mibs = loadMibs(config => $C, nmisng=> $NG) if not defined $mibs;
        
		# look through each of the different types of memory for cache and buffer
		for my $host_id (@$host_ids_p)
		{
			my ($host_inventory,$error) = $S->nmisng_node->inventory(_id => $host_id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $host_id: $error");
				next;
			}
            my $data = $host_inventory->data();
            
            if ( $data->{hrPartitionFSIndex} >= 0 and defined $host_file_system->{$data->{hrPartitionFSIndex}}->{hrFSIndex} ) {

				# this partition has the file system index of hrFSIndex
				my $hrFSIndex = $host_file_system->{$data->{hrPartitionFSIndex}}->{hrFSIndex};
				# that file syste, has the storage index of hrFSStorageIndex
				my $hrFSStorageIndex = $host_file_system->{$hrFSIndex}->{hrFSStorageIndex};

				$data->{hrStorageDescr} = $host_storage->{$hrFSStorageIndex}->{hrStorageDescr};
				$data->{hrStorageDescr_url} = "/cgi-nmis9/network.pl?conf=$C->{conf}&act=network_system_health_view&section=Host_Storage&node=$node";
				$data->{hrStorageDescr_id} = "node_view_$node";

				$changesweremade = 1;

                $host_inventory->data($data); # set changed info
                (undef,$error) = $host_inventory->save(node => $node); # and save to the db, update not required
                $NG->log->error("Failed to save inventory for ".$data->{index}. " : $error")
                        if ($error);
  
				# lets push some data into Host_Storage now
                my ($host_inventory_d,$error) = $S->nmisng_node->inventory(_id => $host_storage_id->{$hrFSStorageIndex});
                if ($error)
                {
                    $NG->log->error("Failed to get inventory ".$host_storage_id->{$hrFSStorageIndex}. ": $error");
                    next;
                }
                my $data_hs = $host_inventory_d->data();
                $data_hs->{hrPartitionLabel} = $data->{hrPartitionLabel};
                $host_inventory_d->data($data_hs); # set changed info
                (undef,$error) = $host_inventory_d->save(node => $node); # and save to the db, update not required
                $NG->log->error("Failed to save inventory for ".$data_hs->{$hrFSStorageIndex}. " : $error")
                        if ($error);
			}

        }
    }

	return ($changesweremade,undef); # report if we changed anything
}

##
# Load Mibs
sub loadMibs {

    my (%args) = @_;
	my ($C, $NG) = @args{qw(config nmisng)};
    
	my $oids = "$C->{mib_root}/nmis_mibs.oid";
	my $mibs;

    $NG->log->debug("Loading Vendor OIDs from $oids");

	open(OIDS,$oids) or $NG->log->warn("ERROR could not load $oids: $!\n");

	my $match = qr/\"([\w\-\.]+)\"\s+\"([\d+\.]+)\"/;

	while (<OIDS>) {
		if ( $_ =~ /$match/ ) {
			$mibs->{$2} = $1;
		}
		elsif ( $_ =~ /^#|^\s+#/ ) {
			#all good comment
		}
		elsif ( $_ =~ /^\n/ ) {
			#all good blank line
		}
		else {
			$NG->log->info("ERROR: no match $_");
		}
	}
	close(OIDS);

	return ($mibs);
}

1;
