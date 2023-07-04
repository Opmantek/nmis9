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
# A small update plugin for discovering interfaces on Adtran-TA5000 devices
# which requires custom snmp accesses
package ciscoMemory;
our $VERSION = "2.0.0";
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

	my $intfData = undef;
	my $intfInfo = undef;

	my $NI       = $S->nmisng_node;
	my $nodeobj  = $NG->node(name => $node);
	my $NC       = $nodeobj->configuration;
	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	my %cpu1Avg;
	my %cpu5Avg;
	my %cpuFree;
	my %cpuUsed;
	my %memFree;
	my %memUsed;
	my $cpuAvg1      = 0;
	my $cpu1AvgAvg   = 0;
	my $cpu1AvgCount = 0;
	my $cpu1AvgMax   = 0;
	my $cpu1AvgTotal = 0;
	my $cpuAvg5      = 0;
	my $cpu5AvgAvg   = 0;
	my $cpu5AvgCount = 0;
	my $cpu5AvgMax   = 0;
	my $cpu5AvgTotal = 0;
	my $cpuFreeAvg   = 0;
	my $cpuFreeCount = 0;
	my $cpuFreeMax   = 0;
	my $cpuFreeTotal = 0;
	my $cpuUsedAvg   = 0;
	my $cpuUsedCount = 0;
	my $cpuUsedMax   = 0;
	my $cpuUsedTotal = 0;
	my $memAvgAvg    = 0;
	my $memAvgCount  = 0;
	my $memAvgMax    = 0;
	my $memAvgTotal  = 0;
	my $memFreeAvg   = 0;
	my $memFreeCount = 0;
	my $memFreeMax   = 0;
	my $memFreeTotal = 0;
	my $memUsedAvg   = 0;
	my $memUsedCount = 0;
	my $memUsedMax   = 0;


	 # This plugin deals only with ZyXEL devices, and only ones with snmp enabled and working.
    if ( $catchall->{nodeModel} !~ /Cisco/i or $catchall->{nodeVendor} !~ /Cisco/i
            or !NMISNG::Util::getbool($catchall->{collect}))
    {
        $NG->log->info("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
        $NG->log->info("Node '$node', Node Model '$catchall->{nodeModel}'.");
        $NG->log->info("Node '$node', Vendor '$catchall->{nodeVendor}'.");
        $NG->log->info("Node '$node', does not qualify for this plugin.");
        return (0,undef);
    }
    else
    {
	$NG->log->info("Running Cisco Memory/CPU plugin for Node '$node', Model '$catchall->{nodeModel}'.");
    }

	# node must have have data for entityMib to be relevant
	# for linkage lookup this needs the entitymib inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# but it's likely  that an individual lookup, on-demand and later would be faster?
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "entityMib",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get entityMib inventory for Node '$node': $error");
		return(0,undef);
	}


	my %emibData =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	if (!keys %emibData)
	{
		$NG->log->error("Failed to get 'entityMib' indices for Node '$node'!");
		return (0,undef);
	}
	my $changesweremade = 0;

	my $cempIds = $S->nmisng_node->get_inventory_ids(
		concept => "cempMemPool",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cempMemPool' inventory for Node '$node': $error");
	}

	if (@$cempIds)
	{
		$NG->log->info("Working on Node '$node' 'cempMemPool'");
		for my $cempId (@$cempIds)
		{
			my ($cempInventory,$error) = $S->nmisng_node->inventory(_id => $cempId);
			if ($error)
			{
				$NG->log->error("Failed to get 'cempMemPool' inventory Index: $cempId; Error: $error");
				next;
			}

			my $cempData = $cempInventory->data; # r/o copy, must be saved back if changed

			# note that split returns everything if no . is present...
			my ($entityIndex,undef) = split(/\./, $cempData->{index});

			if (ref($emibData{$entityIndex}) eq "HASH"
					&& defined($emibData{$entityIndex}->{entPhysicalDescr}))
			{
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				$cempData->{entPhysicalDescr} = $emibData{$entityIndex}->{entPhysicalDescr};
				if ($cempData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $cempData->{MemPoolFree}");
					$NG->log->info("MemoryUsed: $cempData->{MemPoolUsed}");
					$cpuFree{$entityIndex}  = $cempData->{MemPoolFree} if (exists($cempData->{MemPoolFree}) && $cempData->{MemPoolFree} !~ /^\s*$/ && $cempData->{MemPoolFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $cempData->{MemPoolUsed} if (exists($cempData->{MemPoolUsed}) && $cempData->{MemPoolUsed} !~ /^\s*$/ && $cempData->{MemPoolUsed} ne "noSuchInstance");
				}
				$changesweremade = 1;

				$cempInventory->data($cempData); # set changed info
				# set the inventory description to a nice string.
				$cempInventory->description( "$emibData{$entityIndex}->{entPhysicalName} - $cempData->{MemPoolName}");

				(undef,$error) = $cempInventory->save; # and save to the db
				$NG->log->error("Failed to save inventory for Node '$node' Index: $cempId; Error:: $error") if ($error);
			}
		}
	}

	my $ciscoMemIds = $S->nmisng_node->get_inventory_ids(
		concept => "ciscoMemoryPool",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'ciscoMemoryPool' inventory for Node '$node': $error");
	}

	if (@$ciscoMemIds)
	{
		$NG->log->info("Working on Node '$node' 'ciscoMemoryPool'");
		for my $ciscoMemId (@$ciscoMemIds)
		{
			my ($ciscoMemInventory,$error) = $S->nmisng_node->inventory(_id => $ciscoMemId);
			if ($error)
			{
				$NG->log->error("Failed to get 'ciscoMemoryPool' inventory Index: $ciscoMemId; Error: $error");
				next;
			}

			my $ciscoMemData = $ciscoMemInventory->data; # r/o copy, must be saved back if changed

			# note that split returns everything if no . is present...
			my ($entityIndex,undef) = split(/\./, $ciscoMemData->{index});

			if (ref($emibData{$entityIndex}) eq "HASH")
			{
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				if ($ciscoMemData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $ciscoMemData->{MemPoolFree}");
					$NG->log->info("MemoryUsed: $ciscoMemData->{MemPoolUsed}");
					$cpuFree{$entityIndex}  = $ciscoMemData->{MemPoolFree} if (!exists($cpuFree{$entityIndex}) && exists($ciscoMemData->{MemPoolFree}) && $ciscoMemData->{MemPoolFree} !~ /^\s*$/ && $ciscoMemData->{MemoryFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $ciscoMemData->{MemPoolUsed} if (!exists($cpuUsed{$entityIndex}) && exists($ciscoMemData->{MemPoolUsed}) && $ciscoMemData->{MemPoolUsed} !~ /^\s*$/ && $ciscoMemData->{MemoryUsed} ne "noSuchInstance");
					$changesweremade = 1;
				}
			}
		}
	}

	my $cpmMemIds = $S->nmisng_node->get_inventory_ids(
		concept => "Memory-cpm",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'Memory-cpm' inventory for Node '$node': $error");
	}
	if (@$cpmMemIds)
	{
		$NG->log->info("Working on Node '$node' 'Memory-cpm'");
		for my $cpmMemId (@$cpmMemIds)
		{
			my ($cpmMemInventory,$error) = $S->nmisng_node->inventory(_id => $cpmMemId);
			if ($error)
			{
				$NG->log->error("Failed to get 'Memory-cpm' inventory Index: $cpmMemId; Error: $error");
				next;
			}

			my $cpmMemData = $cpmMemInventory->data; # r/o copy, must be saved back if changed

			# note that split returns everything if no . is present...
			my ($entityIndex,undef) = split(/\./, $cpmMemData->{index});

			if (ref($emibData{$entityIndex}) eq "HASH")
			{
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				if ($cpmMemData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $cpmMemData->{MemoryFree}");
					$NG->log->info("MemoryUsed: $cpmMemData->{MemoryUsed}");
					$cpuFree{$entityIndex}  = $cpmMemData->{MemoryFree} if (!exists($cpuFree{$entityIndex}) && exists($cpmMemData->{MemoryFree}) && $cpmMemData->{MemoryFree} !~ /^\s*$/ && $cpmMemData->{MemoryFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $cpmMemData->{MemoryUsed} if (!exists($cpuUsed{$entityIndex}) && exists($cpmMemData->{MemoryUsed}) && $cpmMemData->{MemoryUsed} !~ /^\s*$/ && $cpmMemData->{MemoryUsed} ne "noSuchInstance");
					$changesweremade = 1;
				}
			}
		}
	}

	my $ciscoCPUCpmIds = $S->nmisng_node->get_inventory_ids(
		concept => "cpu_cpm",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cpu_cpm' inventory for Node '$node': $error");
	}

	if (@$ciscoCPUCpmIds)
	{
		$NG->log->info("Working on Node '$node' 'cpu_cpm'");
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

			if (ref($emibData{$entityIndex}) eq "HASH")
			{
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				$NG->log->info("avgBusy1: $ciscoCPUCpmData->{cpmCPUTotal1min}");
				$NG->log->info("avgBusy5: $ciscoCPUCpmData->{cpmCPUTotal5min}");
				$cpu1Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal1min} if (exists($ciscoCPUCpmData->{cpmCPUTotal1min}) && $ciscoCPUCpmData->{cpmCPUTotal1min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal1min} ne "noSuchInstance");
				$cpu5Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal5min} if (exists($ciscoCPUCpmData->{cpmCPUTotal5min}) && $ciscoCPUCpmData->{cpmCPUTotal5min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal5min} ne "noSuchInstance");
				$changesweremade = 1;
			}
		}
	}

	$NG->log->info("Memory Free:");
	foreach my $key (keys(%cpuFree))
	{
		my $thisFree   = $cpuFree{$key};
		$cpuFreeTotal += $thisFree;
		$cpuFreeMax    = $thisFree if ($thisFree > $cpuFreeMax);
		$NG->log->info("Memory Free Index $key = $thisFree");
	}
	$cpuFreeCount = int(keys(%cpuFree));;
	$cpuFreeAvg   = (($cpuFreeCount == 0) ? 0 : $cpuFreeTotal/$cpuFreeCount);
	$NG->log->info("Memory Free Total CPUs $cpuFreeCount");
	$NG->log->info("Memory Free Max CPU $cpuFreeMax");
	$NG->log->info("Memory Free Average CPU $cpuFreeAvg");

	$NG->log->info("Memory Used");
	foreach my $key (keys(%cpuUsed))
	{
		my $thisUsed   = $cpuUsed{$key};
		$cpuUsedTotal += $thisUsed;
		$cpuUsedMax    = $thisUsed if ($thisUsed > $cpuUsedMax);
		$NG->log->info("Memory Used Index $key = $thisUsed");
	}
	$cpuUsedCount = int(keys(%cpuUsed));;
	$cpuUsedAvg   = (($cpuUsedCount == 0) ? 0 : $cpuUsedTotal/$cpuUsedCount);
	$NG->log->info("Memory Used Total CPUs $cpuUsedCount");
	$NG->log->info("Memory Used Max CPU $cpuUsedMax");
	$NG->log->info("Memory Used Average CPU $cpuUsedAvg");

	$NG->log->info("CPU Average Busy 1min");
	foreach my $key (keys(%cpu1Avg))
	{
		my $thisAvg   = $cpu1Avg{$key};
		$cpu1AvgTotal += $thisAvg;
		$cpu1AvgMax    = $thisAvg if ($thisAvg > $cpu1AvgMax);
		$NG->log->info("CPU Average 1min Index $key = $thisAvg");
	}
	$cpu1AvgCount = int(keys(%cpu1Avg));;
	$cpuAvg1     = (($cpu1AvgCount == 0) ? 0 : $cpu1AvgTotal/$cpu1AvgCount);
	$NG->log->info("CPU Total CPUs $cpu1AvgCount");
	$NG->log->info("CPU Max CPU $cpu1AvgMax");
	$NG->log->info("CPU Average 1min CPU $cpuAvg1");

	$NG->log->info("CPU Average Busy 5min");
	foreach my $key (keys(%cpu5Avg))
	{
		my $thisAvg   = $cpu5Avg{$key};
		$cpu5AvgTotal += $thisAvg;
		$cpu5AvgMax    = $thisAvg if ($thisAvg > $cpu5AvgMax);
		$NG->log->info("CPU Average 5min Index $key = $thisAvg");
	}
	$cpu5AvgCount = int(keys(%cpu5Avg));;
	$cpuAvg5     = (($cpu5AvgCount == 0) ? 0 : $cpu5AvgTotal/$cpu5AvgCount);
	$NG->log->info("CPU Total CPUs $cpu5AvgCount");
	$NG->log->info("CPU Max CPU $cpu5AvgMax");
	$NG->log->info("CPU Average 5min CPU $cpuAvg5");

	my $inventory = $S->inventory( concept => 'catchall' );
	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get 'catchall' inventory for Node '$node': $error");
		return(0,undef);
	}
	my $inventory = $S->inventory( concept => 'catchall' );
	my $data;
	$data->{MemoryFreePROC}{value} = $cpuFreeAvg;
	$data->{MemoryUsedPROC}{value} = $cpuUsedAvg;
	$data->{avgBusy1}{value}       = $cpu1AvgMax;
	$data->{avgBusy5}{value}       = $cpu5AvgMax;
	# Update the RRD file.
	my $dbname = $S->create_update_rrd(graphtype => "nodehealth",
					inventory  => $inventory,
					type       => "nodehealth",
					index      => undef,
					data       => $data,
					item       => undef);
	my ( $op, $error ) = $inventory->save();
	$NG->log->debug2( "saved op: $op");
	if ($error)
	{
		$NG->log->error("Failed to save inventory for Node '$node': $error");
	}
	else
	{
		$changesweremade = 1;
	}
	if ($changesweremade)
	{
		$NG->log->info("CPU/Memory update was successful.");
	}
	else
	{
		$NG->log->info("No CPU/Memory updates were made.");
	}

	return ($changesweremade,undef);							# happy, and changes were made so save view and nodes file
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
	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	my %cpu1Avg;
	my %cpu5Avg;
	my %cpuFree;
	my %cpuUsed;
	my %memFree;
	my %memUsed;
	my $cpuFreeAvg   = 0;
	my $cpuUsedAvg   = 0;
	my $memFreeAvg   = 0;
	my $memUsedAvg   = 0;
	my $cpuFreeCount = 0;
	my $cpuUsedCount = 0;
	my $memFreeCount = 0;
	my $memUsedCount = 0;
	my $cpuFreeMax   = 0;
	my $cpuUsedMax   = 0;
	my $memFreeMax   = 0;
	my $memUsedMax   = 0;
	my $cpuFreeTotal = 0;
	my $cpuUsedTotal = 0;
	my $memFreeTotal = 0;
	my $memUsedTotal = 0;

	 # This plugin deals only with ZyXEL devices, and only ones with snmp enabled and working.
    if ( $catchall->{nodeModel} !~ /Cisco/i or $catchall->{nodeVendor} !~ /Cisco/i
            or !NMISNG::Util::getbool($catchall->{collect}))
    {
        $NG->log->info("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
        $NG->log->info("Node '$node', Node Model '$catchall->{nodeModel}'.");
        $NG->log->info("Node '$node', Vendor '$catchall->{nodeVendor}'.");
        $NG->log->info("Node '$node', does not qualify for this plugin.");
        return (0,undef);
    }
    else
    {
	$NG->log->info("Running Cisco Memory/CPU plugin for Node '$node', Model '$catchall->{nodeModel}'.");
    }

	# node must have have data for entityMib to be relevant
	# for linkage lookup this needs the entitymib inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# but it's likely  that an individual lookup, on-demand and later would be faster?
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "entityMib",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get entityMib inventory for Node '$node': $error");
		return(0,undef);
	}


	my %emibData =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	if (!keys %emibData)
	{
		$NG->log->error("Failed to get 'entityMib' indices for Node '$node'!");
		return (0,undef);
	}
	my $changesweremade = 0;

	my $cempIds = $S->nmisng_node->get_inventory_ids(
		concept => "cempMemPool",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cempMemPool' inventory for Node '$node': $error");
	}

	if (@$cempIds)
	{
		$NG->log->info("Working on Node '$node' 'cempMemPool'");
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
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				if ($cempData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $cempData->{MemPoolFree}");
					$NG->log->info("MemoryUsed: $cempData->{MemPoolUsed}");
					$cpuFree{$entityIndex}  = $cempData->{MemPoolFree} if (exists($cempData->{MemPoolFree}) && $cempData->{MemPoolFree} !~ /^\s*$/ && $cempData->{MemPoolFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $cempData->{MemPoolUsed} if (exists($cempData->{MemPoolUsed}) && $cempData->{MemPoolUsed} !~ /^\s*$/ && $cempData->{MemPoolUsed} ne "noSuchInstance");
				}
				$changesweremade = 1;
			}
		}
	}

	my $ciscoMemIds = $S->nmisng_node->get_inventory_ids(
		concept => "ciscoMemoryPool",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'ciscoMemoryPool' inventory for Node '$node': $error");
	}

	if (@$ciscoMemIds)
	{
		$NG->log->info("Working on Node '$node' 'ciscoMemoryPool'");
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
			my ($entityIndex,undef) = split(/\./, $ciscoMemData->{index});

			if (ref($emibData{$entityIndex}) eq "HASH")
			{
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				if ($ciscoMemData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $ciscoMemData->{MemPoolFree}");
					$NG->log->info("MemoryUsed: $ciscoMemData->{MemPoolUsed}");
					$cpuFree{$entityIndex}  = $ciscoMemData->{MemPoolFree} if (!exists($cpuFree{$entityIndex}) && exists($ciscoMemData->{MemPoolFree}) && $ciscoMemData->{MemPoolFree} !~ /^\s*$/ && $ciscoMemData->{MemoryFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $ciscoMemData->{MemPoolUsed} if (!exists($cpuUsed{$entityIndex}) && exists($ciscoMemData->{MemPoolUsed}) && $ciscoMemData->{MemPoolUsed} !~ /^\s*$/ && $ciscoMemData->{MemoryUsed} ne "noSuchInstance");
					$changesweremade = 1;
				}
			}
		}
	}

	my $cpmMemIds = $S->nmisng_node->get_inventory_ids(
		concept => "Memory-cpm",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'Memory-cpm' inventory for Node '$node': $error");
	}
	if (@$cpmMemIds)
	{
		$NG->log->info("Working on Node '$node' 'Memory-cpm'");
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
				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				if ($cpmMemData->{MemPoolName} =~ /processor|cpu/i && $emibData{$entityIndex}->{entPhysicalClass} =~ /module|cpu/)
				{
					$NG->log->info("MemoryFree: $cpmMemData->{MemoryFree}");
					$NG->log->info("MemoryUsed: $cpmMemData->{MemoryUsed}");
					$cpuFree{$entityIndex}  = $cpmMemData->{MemoryFree} if (!exists($cpuFree{$entityIndex}) && exists($cpmMemData->{MemoryFree}) && $cpmMemData->{MemoryFree} !~ /^\s*$/ && $cpmMemData->{MemoryFree} ne "noSuchInstance");
					$cpuUsed{$entityIndex}  = $cpmMemData->{MemoryUsed} if (!exists($cpuUsed{$entityIndex}) && exists($cpmMemData->{MemoryUsed}) && $cpmMemData->{MemoryUsed} !~ /^\s*$/ && $cpmMemData->{MemoryUsed} ne "noSuchInstance");
					$changesweremade = 1;
				}
			}
		}
	}

	my $ciscoCPUCpmIds = $S->nmisng_node->get_inventory_ids(
		concept => "cpu_cpm",
		filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$NG->log->warn("Failed to get 'cpu_cpm' inventory for Node '$node': $error");
	}

	if (@$ciscoCPUCpmIds)
	{
		$NG->log->info("Working on Node '$node' 'cpu_cpm'");
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

#			if (ref($emibData{$entityIndex}) eq "HASH")
#			{
#				$NG->log->info("Entity MIB Index:       $emibData{$entityIndex}->{index}");
#				$NG->log->info("Entity MIB Class:       $emibData{$entityIndex}->{entPhysicalClass}");
#				$NG->log->info("Entity MIB Name:        $emibData{$entityIndex}->{entPhysicalName}");
#				$NG->log->info("Entity MIB Description: $emibData{$entityIndex}->{entPhysicalDescr}");
#				$NG->log->info("Entity MIB Model:       $emibData{$entityIndex}->{entPhysicalModelName}");
				$NG->log->info("avgBusy1:               $ciscoCPUCpmData->{cpmCPUTotal1min}");
				$NG->log->info("avgBusy5:               $ciscoCPUCpmData->{cpmCPUTotal5min}");
				$cpu1Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal1min} if (exists($ciscoCPUCpmData->{cpmCPUTotal1min}) && $ciscoCPUCpmData->{cpmCPUTotal1min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal1min} ne "noSuchInstance");
				$cpu5Avg{$entityIndex}  = $ciscoCPUCpmData->{cpmCPUTotal5min} if (exists($ciscoCPUCpmData->{cpmCPUTotal5min}) && $ciscoCPUCpmData->{cpmCPUTotal5min} !~ /^\s*$/ && $ciscoCPUCpmData->{cpmCPUTotal5min} ne "noSuchInstance");
				$changesweremade = 1;
#			}
		}
	}

	$NG->log->info("CPU Free:");
	foreach my $key (keys(%cpuFree))
	{
		my $thisFree = $cpuFree{$key};
		$cpuFreeTotal += $thisFree;
		$cpuFreeMax = $thisFree if ($thisFree > $cpuFreeMax);
		$NG->log->info("CPU Free Index $key = $thisFree");
	}
	$cpuFreeCount = int(keys(%cpuFree));;
	$cpuFreeAvg   = $cpuFreeTotal/$cpuFreeCount;
	$NG->log->info("CPU Total CPUs $cpuFreeCount");
	$NG->log->info("CPU Max CPU $cpuFreeMax");
	$NG->log->info("CPU Average CPU $cpuFreeAvg");
	$NG->log->info("CPU Used");
	foreach my $key (keys(%cpuUsed))
	{
		my $thisUsed = $cpuUsed{$key};
		$cpuUsedTotal += $thisUsed;
		$cpuUsedMax = $thisUsed if ($thisUsed > $cpuUsedMax);
		$NG->log->info("CPU Used Index $key = $thisUsed");
	}
	$cpuUsedCount = int(keys(%cpuUsed));;
	$cpuUsedAvg   = $cpuUsedTotal/$cpuUsedCount;
	$NG->log->info("CPU Total CPUs $cpuUsedCount");
	$NG->log->info("CPU Max CPU $cpuUsedMax");
	$NG->log->info("CPU Average CPU $cpuUsedAvg");

	my $inventory = $S->inventory( concept => 'catchall' );
	my $data;
	$data->{MemoryFreePROC}{value} = $cpuFreeAvg;
	$data->{MemoryUsedPROC}{value} = $cpuUsedAvg;
	# Update the RRD file.
	my $dbname = $S->create_update_rrd(graphtype => "nodehealth",
					inventory  => $inventory,
					type       => "nodehealth",
					index      => undef,
					data       => $data,
					item       => undef);
	my ( $op, $error ) = $inventory->save();
	$NG->log->debug2( "saved op: $op");
	if ($error)
	{
		$NG->log->error("Failed to save inventory for Node '$node': $error");
	}
	else
	{
		$changesweremade = 1;
	}
	if ($changesweremade)
	{
		$NG->log->info("CPU/Memory update was successful.");
	}
	else
	{
		$NG->log->info("No CPU/Memory updates were made.");
	}

	return ($changesweremade,undef);							# happy, and changes were made so save view and nodes file
}

1;
