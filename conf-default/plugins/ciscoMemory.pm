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
# A small update plugin that copies ent phys descr from entitymib to cempmempool
# and a collection that chases down the utilization from Cisco's myriad of different mibs.
#
package ciscoMemory;
our $VERSION = "2.0.3";
use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;						# for snmp-related access


sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};
	my $changesweremade  = 0;

	# Node must have have data for both entityMib and cempMemPool to be relevant
	my $cempids = $S->nmisng_node->get_inventory_ids(
		concept => "cempMemPool",
		filter => { historic => 0 });
	if (!@$cempids)
	{
		$NG->log->debug("Node '$node', does not qualify for this plugin.");
		return (0,undef);
	}

	# For linkage lookup this needs the entitymib inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# but it's likely that an individual lookup, on-demand and later would be faster?
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "entityMib",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'entityMib' inventory for Node '$node'; Error: $error");
		return(0,"Failed to get 'entityMib' inventory for Node '$node'; Error: $error");
	}

	my %emibdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	return (0,undef) if (!keys %emibdata);
	$NG->log->debug("Running Cisco Memory/CPU update plugin for Node '$node'.");

	$NG->log->debug("Working on Node '$node' 'cempMemPool'");

	for my $cempid (@$cempids)
	{
		my ($cempinventory,$error) = $S->nmisng_node->inventory(_id => $cempid);
		if ($error)
		{
			$NG->log->warn("Failed to get 'cempMemPool' inventory for Node '$node'; ID $cempid; Error: $error");
			next;
		}

		my $cempdata = $cempinventory->data; # r/o copy, must be saved back if changed

		# note that split returns everything if no . is present...
		my ($entityIndex,undef) = split(/\./, $cempdata->{index});

		if (ref($emibdata{$entityIndex}) eq "HASH"
				&& defined($emibdata{$entityIndex}->{entPhysicalDescr}))
		{
			$cempdata->{entPhysicalDescr} = $emibdata{$entityIndex}->{entPhysicalDescr};
			$cempinventory->data($cempdata); # set changed info
			# set the inventory description to a nice string.
			$cempinventory->description( "$emibdata{$entityIndex}->{entPhysicalName} - $cempdata->{MemPoolName}");

			my ( $op, $error ) = $cempinventory->save( node => $node );
			$NG->log->debug2(sub { "saved op: $op"});
			if ($error)
			{
				$NG->log->error("Failed to save inventory for Node '$node'; Index; $cempid; Error: $error");
			}
			else
			{
				$changesweremade = 1;
			}
		}
	}

	if ($changesweremade)
	{
		$NG->log->info("CPU/Memory update was successful.");
	}
	else
	{
		$NG->log->info("No CPU/Memory updates were made.");
	}

	return ($changesweremade,undef); # report if we changed anything
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $intfData = undef;
	my $intfInfo = undef;

	my $NI       = $S->nmisng_node;
	my $nodeobj  = $NG->node(name => $node);
	my $NC       = $nodeobj->configuration;
	my $catchall = $S->inventory( concept => 'catchall' )->data_live();
	my %cpu1Avg;
	my %cpu5Avg;
	my %cpuFree;
	my %cpuUsed;
	my %memFree;
	my %memUsed;
	my $changesweremade = 0;
	my $cpuFreeAvg      = 0;
	my $cpuFreeCount    = 0;
	my $cpuFreeMax      = 0;
	my $cpuFreeTotal    = 0;
	my $cpuUsedAvg      = 0;
	my $cpuUsedCount    = 0;
	my $cpuUsedMax      = 0;
	my $cpuUsedTotal    = 0;
	my $foundTheOIDs    = 0;
	my $memFreeAvg      = 0;
	my $memFreeCount    = 0;
	my $memFreeMax      = 0;
	my $memFreeTotal    = 0;
	my $memUsedAvg      = 0;
	my $memUsedCount    = 0;
	my $memUsedMax      = 0;
	my $memUsedTotal    = 0;

	 # This plugin deals only with Cisco devices, and only ones with snmp enabled and working.
	if ( ($catchall->{nodeModel} !~ /Cisco/i and $catchall->{nodeModel} !~ /Catalyst/i) or $catchall->{nodeVendor} !~ /Cisco/i
			or !NMISNG::Util::getbool($catchall->{collect}))
	{
		$NG->log->debug("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
		$NG->log->debug("Node '$node', Node Model '$catchall->{nodeModel}'.");
		$NG->log->debug("Node '$node', Vendor '$catchall->{nodeVendor}'.");
		$NG->log->debug("Node '$node', does not qualify for this plugin.");
		return (0,undef);
	}
	else
	{
		$NG->log->debug("Running Cisco Memory/CPU collect plugin for Node '$node', Model '$catchall->{nodeModel}'.");
	}

	# Node must have have data for entityMib to be relevant
	# for linkage lookup this needs the entitymib inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# but it's likely that an individual lookup, on-demand and later would be faster?
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "entityMib",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get entityMib inventory for Node '$node'; Error: $error");
		return(0,"Failed to get entityMib inventory for Node '$node'; Error: $error");
	}


	my %emibData =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	if (!keys %emibData)
	{
		# this isn't an error, there may not be any
		$NG->log->debug("Failed to get 'entityMib' indices for Node '$node'!");
		return (0,"Failed to get 'entityMib' indices for Node '$node'!");
	}

	my $cempIds = $S->nmisng_node->get_inventory_ids(
		concept => "cempMemPool",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cempMemPool' inventory for Node '$node'; Error: $error");
	}

	if (@$cempIds)
	{
		$NG->log->debug("Working on Node '$node' 'cempMemPool'");
		for my $cempId (@$cempIds)
		{
			my ($cempInventory,$error) = $S->nmisng_node->inventory(_id => $cempId);
			if ($error)
			{
				$NG->log->error("Failed to get 'cempMemPool' inventory for Node '$node', Index: $cempId; Error: $error");
				next;
			}

			my $cempData = $cempInventory->data; # r/o copy, must be saved back if changed

			# note that split returns everything if no . is present...
			my ($entityIndex,undef) = split(/\./, $cempData->{index});

			if (ref($emibData{$entityIndex}) eq "HASH"
					&& defined($emibData{$entityIndex}->{entPhysicalDescr}))
			{
				$NG->log->debug9(sub {"Entity MIB Index:       $emibData{$entityIndex}->{index}"});
				$NG->log->debug9(sub {"Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}"});
				$NG->log->debug9(sub {"Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}"});
				$NG->log->debug9(sub {"Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}"});
				$NG->log->debug9(sub {"Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}"});
				if ($cempData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->debug("MemoryFree: $cempData->{MemPoolFree}");
					$NG->log->debug("MemoryUsed: $cempData->{MemPoolUsed}");
					$cpuFree{$entityIndex}  = $cempData->{MemPoolFree} if (exists($cempData->{MemPoolFree}) && $cempData->{MemPoolFree} !~ /^\s*$/ && $cempData->{MemPoolFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $cempData->{MemPoolUsed} if (exists($cempData->{MemPoolUsed}) && $cempData->{MemPoolUsed} !~ /^\s*$/ && $cempData->{MemPoolUsed} ne "noSuchInstance");
				}
				$foundTheOIDs = 1;
			}
		}
	}

	if (!$foundTheOIDs)
	{
		my $ciscoMemIds = $S->nmisng_node->get_inventory_ids(
			concept => "ciscoMemoryPool",
			filter => { historic => 0 });
		if (my $error = $result->error)
		{
			$NG->log->warn("Failed to get 'ciscoMemoryPool' inventory for Node '$node'; Error: $error");
		}
	
		if (@$ciscoMemIds)
		{
			$NG->log->debug("Working on Node '$node' 'ciscoMemoryPool'");
			for my $ciscoMemId (@$ciscoMemIds)
			{
				my ($ciscoMemInventory,$error) = $S->nmisng_node->inventory(_id => $ciscoMemId);
				if ($error)
				{
					$NG->log->error("Failed to get 'ciscoMemoryPool' inventory for Node '$node', Index: $ciscoMemId; Error: $error");
					next;
				}
	
				my $ciscoMemData = $ciscoMemInventory->data; # r/o copy, must be saved back if changed
	
				# note that split returns everything if no . is present...
				my $memIndex = split(/\./, $ciscoMemData->{index});

				# Cisco Memory Pool does not link to the Entity MIB data.
				if ($ciscoMemData->{MemPoolName} =~ /processor|cpu/i)
				{
					$NG->log->debug("MemoryFree $memIndex: $ciscoMemData->{MemPoolFree}");
					$NG->log->debug("MemoryUsed $memIndex: $ciscoMemData->{MemPoolUsed}");
					$cpuFree{$memIndex}  = $ciscoMemData->{MemPoolFree} if (!exists($cpuFree{$memIndex}) && exists($ciscoMemData->{MemPoolFree}) && $ciscoMemData->{MemPoolFree} !~ /^\s*$/ && $ciscoMemData->{MemoryFree} ne "noSuchInstance");
					$cpuUsed{$memIndex}  = $ciscoMemData->{MemPoolUsed} if (!exists($cpuUsed{$memIndex}) && exists($ciscoMemData->{MemPoolUsed}) && $ciscoMemData->{MemPoolUsed} !~ /^\s*$/ && $ciscoMemData->{MemoryUsed} ne "noSuchInstance");
					$foundTheOIDs = 1;
				}
			}
		}
	}

	if (!$foundTheOIDs)
	{
		my $cpmMemIds = $S->nmisng_node->get_inventory_ids(
			concept => "Memory-cpm",
			filter => { historic => 0 });
		if (my $error = $result->error)
		{
			$NG->log->warn("Failed to get 'Memory-cpm' inventory for Node '$node'; Error: $error");
		}
		if (@$cpmMemIds)
		{
			$NG->log->debug("Working on Node '$node' 'Memory-cpm'");
			for my $cpmMemId (@$cpmMemIds)
			{
				my ($cpmMemInventory,$error) = $S->nmisng_node->inventory(_id => $cpmMemId);
				if ($error)
				{
					$NG->log->error("Failed to get 'Memory-cpm' inventory for Node '$node', Index: $cpmMemId; Error: $error");
					next;
				}
	
				my $cpmMemData = $cpmMemInventory->data; # r/o copy, must be saved back if changed
	
				# note that split returns everything if no . is present...
				my ($entityIndex,undef) = split(/\./, $cpmMemData->{index});
	
				if (ref($emibData{$entityIndex}) eq "HASH")
				{
					$NG->log->debug9(sub {"Entity MIB Index:       $emibData{$entityIndex}->{index}"});
					$NG->log->debug9(sub {"Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}"});
					$NG->log->debug9(sub {"Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}"});
					$NG->log->debug9(sub {"Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}"});
					$NG->log->debug9(sub {"Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}"});
					if ($cpmMemData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
					{
						$NG->log->debug("MemoryFree: $cpmMemData->{MemoryFree}");
						$NG->log->debug("MemoryUsed: $cpmMemData->{MemoryUsed}");
						$cpuFree{$entityIndex}  = $cpmMemData->{MemoryFree} if (!exists($cpuFree{$entityIndex}) && exists($cpmMemData->{MemoryFree}) && $cpmMemData->{MemoryFree} !~ /^\s*$/ && $cpmMemData->{MemoryFree} ne "noSuchInstance");
						$cpuUsed{$entityIndex}  = $cpmMemData->{MemoryUsed} if (!exists($cpuUsed{$entityIndex}) && exists($cpmMemData->{MemoryUsed}) && $cpmMemData->{MemoryUsed} !~ /^\s*$/ && $cpmMemData->{MemoryUsed} ne "noSuchInstance");
						$foundTheOIDs = 1;
					}
				}
			}
		}
	}

	#
	#Collect the Average Busy numbers.
	#
	my $ciscoCPUCpmIds = $S->nmisng_node->get_inventory_ids(
		concept => "cpu_cpm",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cpu_cpm' inventory for Node '$node'; Error: $error");
	}

	if (@$ciscoCPUCpmIds)
	{
		$NG->log->debug("Working on Node '$node' 'cpu_cpm'");
		for my $ciscoCPUCpmId (@$ciscoCPUCpmIds)
		{
			my ($ciscoCPUCpmInventory,$error) = $S->nmisng_node->inventory(_id => $ciscoCPUCpmId);
			if ($error)
			{
				$NG->log->error("Failed to get 'cpu_cpm' inventory Index: $ciscoCPUCpmId; Error: $error");
				next;
			}

			my $ciscoCPUCpmData = $ciscoCPUCpmInventory->data; # r/o copy, must be saved back if changed

			# note that split returns everything if no . is present...
			my ($entityIndex,undef) = split(/\./, $ciscoCPUCpmData->{index});

			$NG->log->debug("avgBusy1:               $ciscoCPUCpmData->{cpmCPUTotal1min}");
			$NG->log->debug("avgBusy5:               $ciscoCPUCpmData->{cpmCPUTotal5min}");
			$cpu1Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal1min} if (exists($ciscoCPUCpmData->{cpmCPUTotal1min}) && $ciscoCPUCpmData->{cpmCPUTotal1min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal1min} ne "noSuchInstance");
			$cpu5Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal5min} if (exists($ciscoCPUCpmData->{cpmCPUTotal5min}) && $ciscoCPUCpmData->{cpmCPUTotal5min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal5min} ne "noSuchInstance");
			$foundTheOIDs = 1;
		}
	}

	$NG->log->debug("CPU Free:");
	foreach my $key (keys(%cpuFree))
	{
		my $thisFree = $cpuFree{$key};
		$cpuFreeTotal += $thisFree;
		$cpuFreeMax = $thisFree if ($thisFree > $cpuFreeMax);
		$NG->log->debug("CPU Free Index $key = $thisFree");
	}
	$cpuFreeCount = int(keys(%cpuFree));;
	$cpuFreeAvg   = (($cpuFreeCount == 0) ? 0 : $cpuFreeTotal/$cpuFreeCount);
	$NG->log->debug("CPU Total CPUs $cpuFreeCount");
	$NG->log->debug("CPU Max CPU $cpuFreeMax");
	$NG->log->debug("CPU Average CPU $cpuFreeAvg");
	$NG->log->debug("CPU Used");
	foreach my $key (keys(%cpuUsed))
	{
		my $thisUsed = $cpuUsed{$key};
		$cpuUsedTotal += $thisUsed;
		$cpuUsedMax = $thisUsed if ($thisUsed > $cpuUsedMax);
		$NG->log->debug("CPU Used Index $key = $thisUsed");
	}
	$cpuUsedCount = int(keys(%cpuUsed));;
	$cpuUsedAvg   = (($cpuUsedCount == 0) ? 0 : $cpuUsedTotal/$cpuUsedCount);
	$NG->log->debug("CPU Total CPUs $cpuUsedCount");
	$NG->log->debug("CPU Max CPU $cpuUsedMax");
	$NG->log->debug("CPU Average CPU $cpuUsedAvg");

	my $dataInfo = [
		{ TotalCPUs     => "Total Number of CPUs"},
		{ MemoryUsedMax => "Maximum Memory Utilization"},
		{ MemoryFreeMax => "Maximum Free memory"},
		{ MemoryFree    => "Current Free Memory"},
		{ MemoryUsed    => "Current Memory Utilization"}
	];
	
	my $data;
	$data->{index}         = 0;
	$data->{TotalCPUs}     = $cpuUsedCount;
	$data->{MemoryUsedMax} = $cpuUsedMax;
	$data->{MemoryFreeMax} = $cpuFreeMax;
	$data->{MemoryFree}    = $cpuFreeAvg;
	$data->{MemoryUsed}    = $cpuUsedAvg;
	my $path_keys =  ['index'];
	my $path = $nodeobj->inventory_path( concept => 'ciscoNormalizedCPUMem', path_keys => $path_keys, data => $data );
	my ($inventory, $error) =  $nodeobj->inventory( create => 1,                # if not present yet
													concept => "ciscoNormalizedCPUMem",
													data => $data,
													path_keys => $path_keys,
													path => $path );

	if(!$inventory or $error)
	{
		$NG->log->error("Failed to get inventory for 'ciscoNormalizedCPUMem'; Error: $error");
		next;                               # not much we can do in this case...
	}
	$inventory->historic(0);
	$inventory->data_info(
							subconcept => "ciscoNormalizedCPUMem",
							enabled => 1,
							display_keys => $dataInfo
							);
	my $rrdData;
	$rrdData->{MemoryFreePROC}{value} = $cpuFreeAvg;
	$rrdData->{MemoryUsedPROC}{value} = $cpuUsedAvg;
	# Update the RRD file.
	my $dbname = $S->create_update_rrd(graphtype => "nodehealth",
					inventory  => $inventory,
					type       => "nodehealth",
					index      => undef,
					data       => $rrdData,
					item       => undef);
	my ( $op, $error ) = $inventory->save( node => $node );
	$NG->log->debug2(sub {"saved inventory for Node '$node'; op: $op"});
	if ($error)
	{
		$NG->log->error("Failed to save inventory for Node '$node'; Error: $error");
	}
	else
	{
		$changesweremade = 1;
	}
	my $dbname = $S->create_update_rrd(graphtype => "ciscoNormalizedCPUMem",
					inventory  => $inventory,
					type       => "ciscoNormalizedCPUMem",
					index      => undef,
					data       => $rrdData,
					item       => undef);
	my ( $op, $error ) = $inventory->save( node => $node );
	$NG->log->debug( "saved op: $op");
	if ($error)
	{
		$NG->log->error("Failed to save inventory for Node '$node'; Error: $error");
	}
	else
	{
		$changesweremade = 1;
	}
	if ($changesweremade)
	{
		$NG->log->debug("CPU/Memory collection was successful.");
	}
	else
	{
		$NG->log->debug("No CPU/Memory collections were made.");
	}

	return ($changesweremade,undef);							# happy, and changes were made so save view and nodes file
}

1;
