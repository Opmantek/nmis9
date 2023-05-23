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
# An update plugin for discovering interfaces on Alcatel ASAM devices
# which requires custom snmp accesses
package AsamInterface;

our $VERSION = "2.0.0";

use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;				# for snmp-related access

my $node;
my $S;
my $C;
my $NG;
my $NI;
my $interestingInterfaces = qr/atm Interface/;


sub update_plugin
{
	my (%args) = @_;
	($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};
	$NI               = $S->nmisng_node;

	my $intfData             = undef;
	my $intfInfo             = undef;
	my $interface_max_number = $C->{interface_max_number} || 5000;
	my $changesweremade      = 0;
	my $rack_count           = 1;
	my $shelf_count          = 1;
	my $asamVersion41        = qr/OSWPAA41|L6GPAA41|OSWPAA37|L6GPAA37|OSWPRA41/;
	my $asamVersion42        = qr/OSWPAA42|L6GPAA42|OSWPAA46/;
	my $asamVersion43        = qr/OSWPRA43|OSWPAN43/;
	my $asamVersion62        = qr/OSWPAA62|OSWPAA55/;
	my $asamModel;
	my $snmpData;
	my $version;

	$NG->log->debug("Max Interfaces are: '$interface_max_number'");

	my $nodeobj    = $NG->node(name => $node);
	my $NC         = $nodeobj->configuration;
	my $catchall   = $S->inventory( concept => 'catchall' )->{_data};
	my %nodeconfig = %{$S->nmisng_node->configuration};


	# This plugin deals only with this specific device type, and only ones with snmp enabled and working
	# and finally only if the number of interfaces is greater than the limit, otherwise the normal
	# discovery will populate all interfaces normally.
	if ( $catchall->{nodeModel} !~ /AlcatelASAM/ or !NMISNG::Util::getbool($catchall->{collect}))
	{
		$NG->log->info("Max Interfaces are: '$interface_max_number'");
		$NG->log->info("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
		$NG->log->info("Node '$node', has $catchall->{ifNumber} interfaces.");
		$NG->log->info("Node '$node', Model '$catchall->{nodeModel}' does not qualify for this plugin.");
		return (0,undef);
	}
	else
	{
		$NG->log->info("Running Alcatel Asam Interface plugin for Node '$node', Model '$catchall->{nodeModel}'.");
	}

	$NG->log->debug9("\$node:        " . Dumper($node) . "\n\n\n");
	$NG->log->debug9("\$S:           " . Dumper($S) . "\n\n\n");
	$NG->log->debug9("\$C:           " . Dumper($C) . "\n\n\n");
	$NG->log->debug9("\$NG:          " . Dumper($NG) . "\n\n\n");
	$NG->log->debug9("\$NI:          " . Dumper($NI) . "\n\n\n");
	$NG->log->debug9("\$nodeconfig:  " . Dumper(%nodeconfig) . "\n\n\n");

	# we have been told index 17 of the eqptHolder is the ASAM Model	
	my $path_keys = ['index'];
	my %path_data = ('index' => 17);
	my $path = $nodeobj->inventory_path( concept => 'eqptHolderList', path_keys => $path_keys, data => \%path_data );
	my ($eqptHolderList, $error) =  $nodeobj->inventory(
		create => 0,				# if not present yet
		concept => "eqptHolderList",
		path_keys => $path_keys,
		data => \%path_data,
		path => $path );

	if(!$eqptHolderList or $error)
	{
		$NG->log->error("Failed to get inventory for interface index 17; Error: $error");
	}
	$NG->log->debug9("\$eqptHolderList: " . Dumper($eqptHolderList) . "\n\n\n");
	$asamModel = $eqptHolderList->{_data}->{eqptHolderPlannedType} || $catchall->{nodeModel};

	$NG->log->info("ASAM Model: '$asamModel'");

	#asamActiveSoftware1	standby
	#asamActiveSoftware2	active
	#asamSoftwareVersion1	/OSWP/OSWPAA37.432
	#asamSoftwareVersion2	OSWP/66.98.63.71/OSWPAA41.353/OSWPAA41.353
	
	#asamActiveSoftware1	standby
	#asamActiveSoftware2	active
	#asamSoftwareVersion1	OSWP/66.98.63.71/L6GPAA42.413/L6GPAA42.413
	#asamSoftwareVersion2	OSWP/66.98.63.71/OSWPAA42.413/OSWPAA42.413
	
	### 2013-08-09 New Version strings.
	#asamSoftwareVersion1 OSWP/66.98.63.71/OSWPAA41.363/OSWPAA41.363
	#asamSoftwareVersion2 OSWP/66.98.63.71/OSWPAA41.353/OSWPAA41.353
	
	### 2015-06-12 New Version strings.
	#asamSoftwareVersion1 OSWP/66.98.63.71/OSWPAA42.676/OSWPAA42.676
	#asamSoftwareVersion2 10.58.10.137/OSWP/OSWPAA46.588

	### 2015-06-17 New Version strings.
	#asamSoftwareVersion1 OSWP/OSWPAA43.322/OSWPRA43.322
	#asamSoftwareVersion2 OSWPRA41.353

	### 2021-09-22 New vesion strings for ASAM Nokia 6.2
	#asamSoftwareVersion1 OSWP/OSWPAA62.577",
	#asamSoftwareVersion2 OSWP/OSWPAA55.142",

	if ( $asamModel eq "NFXS-A" ) {
		$asamModel = "7302 ($asamModel)";
	}
	elsif ( $asamModel eq "NFXS-B" ) {
		$asamModel = "7330-FD ($asamModel)";
	}
	elsif ( $asamModel eq "ARAM-D" ) {
		$asamModel = "ARAM-D ($asamModel)";
	}
	elsif ( $asamModel eq "ARAM-E" ) {
		$asamModel = "ARAM-E ($asamModel)";
	}

	$catchall->{asamModel} = $asamModel;
	
#	$rack_count = $LNT->{$node}{rack_count} if $LNT->{$node}{rack_count} ne "";
#	$shelf_count = $LNT->{$node}{shelf_count} if $LNT->{$node}{shelf_count} ne "";
	
	$S->{info}{system}{rack_count} = $rack_count;
	$S->{info}{system}{shelf_count} = $shelf_count;
						
	my $asamSoftwareVersion = $catchall->{asamSoftwareVersion1};
	if ( $catchall->{asamActiveSoftware2} eq "active" ) 
	{
		$asamSoftwareVersion = $catchall->{asamSoftwareVersion2};
	}
	my @verParts = split("/",$asamSoftwareVersion);
	$asamSoftwareVersion = $verParts[$#verParts];
			
	#"Devices in release 4.1  (ARAM-D y ARAM-E)"
	if( $asamSoftwareVersion =~ /$asamVersion41/ ) {
		$version = 4.1;
	}
	#" release 4.2  ( ISAM FD y  ISAM-V) "
	elsif( $asamSoftwareVersion =~ /$asamVersion42/ )
	{
		$version = 4.2;
	}
	elsif( $asamSoftwareVersion =~ /$asamVersion43/ )
	{
		$version = 4.3;
	}
	elsif( $asamSoftwareVersion =~ /$asamVersion62/ )
	{
		$version = 6.2;
	}
	else {
		$NG->log->error("ERROR: Unknown ASAM Version '$node' asamSoftwareVersion: '$asamSoftwareVersion'");
		return (2, "Could not retrieve ASAM Version from node '$node'");
	}
	$NG->log->debug("DEBUG version='$version' asamSoftwareVersion='$asamSoftwareVersion'");
	

	# Load any nodeconf overrides for this node
	my $overrides = $nodeobj->overrides || {};

	# NMISNG::Snmp doesn't fall back to global config
	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};

	# Get the SNMP Session going.
	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		my $error = $snmp->error;
		undef $snmp;
		$NG->log->error("Could not open SNMP session to node '$node': ".$error);
		return (2, "Could not open SNMP session to node '$node': ".$error);
	}
	if (!$snmp->testsession)
	{
		my $error = $snmp->error;
		$snmp->close;
		$NG->log->warn("Could not retrieve SNMP vars from node '$node': ".$error);
		return (2, "Could not retrieve SNMP vars from node '$node': ".$error);
	}
	
	my @ifIndexNum  = ();
	my $intfTotal   = 0;
	my $intfCollect = 0; # reset counters

	# Build a table of Customer IDs
	my $customerIdTable;
	my $customerIds = $S->nmisng_node->get_inventory_ids(
		concept => "Customer_ID",
		filter => { historic => 0 });
	if (@$customerIds)
	{
		for my $customerId (@$customerIds)
		{
			my ($customerEntry, $error) = $S->nmisng_node->inventory(_id => $customerId);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for Customer ID: '$customerId'; Error: $error");
				next;
			}
			my $customerData   = $customerEntry->data();
			my $eachIfIndex    = $customerData->{index};
			my $eachCustomerId = $customerData->{asamIfExtCustomerId};
			$NG->log->debug5("Interface Index:        '$eachIfIndex'");
			$NG->log->debug5("Customer ID:            '$eachCustomerId'");
			$customerIdTable->{$eachIfIndex} = $eachCustomerId;
		}
	}

	$intfTotal = 0;
	$intfInfo->{index}         = "Index";
	$intfInfo->{interface}     = "Interface Name";
	$intfInfo->{ifIndex}       = "Interface Index";
	$intfInfo->{ifName}        = "Interface Internal Name";
	$intfInfo->{Description}   = "Interface Description";
	$intfInfo->{ifDesc}        = "Interface Internal Description";
	$intfInfo->{ifType}        = "Interface Type";
	$intfInfo->{ifSpeed}       = "Interface Speed";
	$intfInfo->{ifSpeedIn}     = "Interface Speed In";
	$intfInfo->{ifSpeedOut}    = "Interface Speed Out";
	$intfInfo->{ifAdminStatus} = "Interface Administrative State";
	$intfInfo->{ifOperStatus}  = "Interface Operational State";
	$intfInfo->{setlimits}     = "Interface Set Limnits";
	$intfInfo->{collect}       = "Interface Collection Status";
	$intfInfo->{event}         = "Interface Event Status";
	$intfInfo->{threshold}     = "Interface Threshold Status";

	my $ifTableData = $S->nmisng_node->get_inventory_ids(
		concept => "ifTable",
		filter => { historic => 0, "data.ifDescr" => "atm Interface" });
	if (@$ifTableData)
	{
		for my $ifTableId (@$ifTableData)
		{
			$intfTotal++;				
			my ($ifEntry, $error) = $S->nmisng_node->inventory(_id => $ifTableId);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for ID: '$ifTableId'; Error: $error");
				next;
			}
			my $ifData            = $ifEntry->data();
			my $eachIfIndex       = $ifData->{"index"};
			my $eachIfAdminStatus = $ifData->{"ifAdminStatus"};
			my $eachIfDescription = $ifData->{"ifDescr"};
			my $description       = getDescription(version => $version, ifIndex => $eachIfIndex);
			my $ifDescr           = getIfDescr(prefix => "ATM", version => $version, ifIndex => $eachIfIndex, asamModel => $asamModel);
			my $ifName            = NMISNG::Util::convertIfName($ifDescr);
			my $setlimits         = $NI->{interface}->{$eachIfIndex}->{setlimits} // "normal";
			my $xdslIndex         = $eachIfIndex;
			$intfData->{$eachIfIndex}->{Description}       = $description;
			$intfData->{$eachIfIndex}->{ifAdminStatus}     = $eachIfAdminStatus;
			$intfData->{$eachIfIndex}->{ifDescr}           = $ifDescr;
			$intfData->{$eachIfIndex}->{ifIndex}           = $eachIfIndex;
			$intfData->{$eachIfIndex}->{ifName}            = $ifName;
			$intfData->{$eachIfIndex}->{ifOperStatus}      = $ifData->{ifOperStatus};
			$intfData->{$eachIfIndex}->{ifType}            = $ifData->{ifType};
			$intfData->{$eachIfIndex}->{index}             = $eachIfIndex;
			$intfData->{$eachIfIndex}->{interface}         = NMISNG::Util::convertIfName($ifDescr);
			$intfData->{$eachIfIndex}->{setlimits}         = $setlimits;
			$intfData->{$eachIfIndex}->{ifSpeed}           = "Unknown";
			$intfData->{$eachIfIndex}->{collect}           = $eachIfAdminStatus eq "up" ? "true": "false";
			$intfData->{$eachIfIndex}->{event}             = $eachIfAdminStatus eq "up" ? "true": "false";
			$intfData->{$eachIfIndex}->{threshold}         = $eachIfAdminStatus eq "up" ? "true": "false";
			# check for duplicated ifDescr
			foreach my $i (@$ifTableData) {
				if ($eachIfIndex ne $i and $intfData->{$eachIfIndex}->{ifDescr} eq $intfData->{$i}->{ifDescr}) {
					$intfData->{$eachIfIndex}->{ifDescr} = "$eachIfDescription-$eachIfIndex"; # add index to this description.
					$intfData->{$i}->{ifDescr}           = "$eachIfDescription-$i";           # and the duplicte one.
					$NG->log->debug2("Index added to duplicate Interface Description '$eachIfDescription'");
				}
			}

			my $offset = 12288;
			if ( $version eq "4.2" )  {
				$offset = 6291456;
			}
			elsif ( $version eq "6.2" )  {
				$offset = 393216;
				$xdslIndex = $eachIfIndex - $offset;
			}
	
			my $offsetIndex = $eachIfIndex - $offset;
	
			my @atmVclVars = qw(
				asamIfExtCustomerId
				xdslLinkUpMaxBitrateUpstream
				xdslLinkUpMaxBitrateDownstream
			);
	
			my %atmOidSet = (
				asamIfExtCustomerId => "1.3.6.1.4.1.637.61.1.6.5.1.1.$offsetIndex",
				xdslLinkUpMaxBitrateUpstream =>	"1.3.6.1.4.1.637.61.1.39.12.1.1.11.$xdslIndex",
				xdslLinkUpMaxBitrateDownstream => "1.3.6.1.4.1.637.61.1.39.12.1.1.12.$xdslIndex",
			);
	
			# build an array combining the atmVclVars and atmOidSet into a single array
			my @oids = map {$atmOidSet{$_}} @atmVclVars;
	
			my $snmpdata = $snmp->get(@oids);
	
			if ( $snmp->error() ) {
				$NG->log->error("ERROR with SNMP on '$node'; Error: ". $snmp->error());
			}
	
			my $ifSpeedIn  = 0;
			my $ifSpeedOut = 0;
			if ( $snmpdata ) {
				# get the customer id
				my $oid = "1.3.6.1.4.1.637.61.1.6.5.1.1.$offsetIndex";
				if ( $snmpdata->{$oid} ne "" and $snmpdata->{$oid} !~ /SNMP ERROR/ ) {
					$intfData->{$eachIfIndex}->{Description} = $snmpdata->{$oid};
				}
				# get the speed out
				$oid = "1.3.6.1.4.1.637.61.1.39.12.1.1.12.$xdslIndex";
				if ( $snmpdata->{$oid} ne "" and $snmpdata->{$oid} !~ /SNMP ERROR/ ) {
					$ifSpeedOut = $snmpdata->{$oid} * 1000;
				}
				# get the speed in
				$oid = "1.3.6.1.4.1.637.61.1.39.12.1.1.11.$xdslIndex";
				if ( $snmpdata->{$oid} ne "" and $snmpdata->{$oid} !~ /SNMP ERROR/ ) {
					$ifSpeedIn = $snmpdata->{$oid} * 1000;
				}
	
				if ( defined $customerIdTable->{$eachIfIndex} ) {
					$description = $customerIdTable->{$eachIfIndex};
					$NG->log->info("Customer_ID $node $ifDescr $description");
				}
	
				$intfData->{$eachIfIndex}->{ifSpeed} = ($ifSpeedIn > $ifSpeedOut ? $ifSpeedIn : $ifSpeedOut) if ($ifSpeedIn > 0 && $ifSpeedOut > 0);
			}
	
			my $thisintfover = $overrides->{$ifDescr} || {};
	
			### add in anything we find from nodeConf - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			if ($thisintfover->{Description} ne '') {
				$intfData->{$eachIfIndex}->{nc_Description} = $intfData->{$eachIfIndex}->{Description}; # save
				$intfData->{$eachIfIndex}->{Description} = $thisintfover->{Description};
				$NG->log->info("Manual update of Description by nodeConf");
			}
			
			if ($thisintfover->{ifSpeed} ne '') {
				$intfData->{$eachIfIndex}->{nc_ifSpeed} = $intfData->{$eachIfIndex}->{ifSpeed}; # save
				$intfData->{$eachIfIndex}->{ifSpeed} = $thisintfover->{ifSpeed};
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$NG->log->info("Manual update of ifSpeed by nodeConf");
			}
		
			if ($thisintfover->{ifSpeedIn} ne '') {
				$intfData->{$eachIfIndex}->{nc_ifSpeedIn} = $intfData->{$eachIfIndex}->{ifSpeedIn}; # save
				$intfData->{$eachIfIndex}->{ifSpeedIn} = $thisintfover->{ifSpeedIn};
				
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$NG->log->info("Manual update of ifSpeedIn by nodeConf");
			}
		
			if ($thisintfover->{ifSpeedOut} ne '') {
				$intfData->{$eachIfIndex}->{nc_ifSpeedOut} = $intfData->{$eachIfIndex}->{ifSpeedOut}; # save
				$intfData->{$eachIfIndex}->{ifSpeedOut} = $thisintfover->{ifSpeedOut};
	
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$NG->log->info("Manual update of ifSpeedOut by nodeConf");
			}
			
			# convert interface name
			$intfData->{$eachIfIndex}->{interface} = NMISNG::Util::convertIfName($intfData->{$eachIfIndex}->{ifDescr});
			$intfData->{$eachIfIndex}->{ifIndex} = $eachIfIndex;
			
			### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
			# modify by node Config ?
			if ($thisintfover->{collect} ne '' and $thisintfover->{ifDescr} eq $intfData->{$eachIfIndex}->{ifDescr}) {
				$intfData->{$eachIfIndex}->{nc_collect} = $intfData->{$eachIfIndex}->{collect};
				$intfData->{$eachIfIndex}->{collect} = $thisintfover->{collect};
				$NG->log->debug("Manual update of Collect by nodeConf");
				if ($intfData->{$eachIfIndex}->{collect} eq 'false') {
					$intfData->{$eachIfIndex}->{nocollect} = "Manual update by nodeConf";
				}
			}
			if ($thisintfover->{event} ne '' and $thisintfover->{ifDescr} eq $intfData->{$eachIfIndex}->{ifDescr}) {
				$intfData->{$eachIfIndex}->{nc_event} = $intfData->{$eachIfIndex}->{event};
				$intfData->{$eachIfIndex}->{event} = $thisintfover->{event};
				$intfData->{$eachIfIndex}->{noevent} = "Manual update by nodeConf" if $intfData->{$eachIfIndex}{event} eq 'false'; # reason
				$NG->log->debug("Manual update of Event by nodeConf");
			}
			if ($thisintfover->{threshold} ne '' and $thisintfover->{ifDescr} eq $intfData->{$eachIfIndex}{ifDescr}) {
				$intfData->{$eachIfIndex}{nc_threshold} = $intfData->{$eachIfIndex}{threshold};
				$intfData->{$eachIfIndex}{threshold} = $thisintfover->{threshold};
				$intfData->{$eachIfIndex}{nothreshold} = "Manual update by nodeConf" if $intfData->{$eachIfIndex}{threshold} eq 'false'; # reason
				$NG->log->debug("Manual update of Threshold by nodeConf");
			}
			
			$intfData->{$eachIfIndex}{threshold} = $intfData->{$eachIfIndex}{collect};
			
			# number of interfaces collected with collect and event on
			$intfCollect++ if $intfData->{$eachIfIndex}{collect} eq 'true' && $intfData->{$eachIfIndex}{event} eq 'true';
			
			if ($intfData->{$eachIfIndex}{collect} eq "true") {
				$NG->log->debug("ifIndex $eachIfIndex, collect=true");
			} else {
				$NG->log->debug("ifIndex $eachIfIndex, collect=false, $intfData->{$eachIfIndex}->{nocollect}");
			}
		
			$NG->log->debug5("Interface Index:        '$intfData->{$eachIfIndex}->{index}'");
			$NG->log->debug5("Interface Name:         '$intfData->{$eachIfIndex}->{ifName}'");
			$NG->log->debug5("Interface Description:  '$intfData->{$eachIfIndex}->{ifDescr}'");
			$NG->log->debug5("Interface Speed:        '$intfData->{$eachIfIndex}->{ifSpeed}'");
			$NG->log->debug5("Interface Type:         '$intfData->{$eachIfIndex}->{ifType}'");
			$NG->log->debug5("Interface Admin Status: '$intfData->{$eachIfIndex}->{ifAdminStatus}'");
			$NG->log->debug5("Interface Oper Status:  '$intfData->{$eachIfIndex}->{ifOperStatus}'");
			$NG->log->debug5("Interface Limits:       '$intfData->{$eachIfIndex}->{setlimits}'");

			# interface now up or down, check and set or clear outstanding event.
			if ( $intfData->{$eachIfIndex}{collect} eq 'true'
					 and $intfData->{$eachIfIndex}{ifAdminStatus} =~ /up|ok/ 
					 and $intfData->{$eachIfIndex}{ifOperStatus} !~ /up|ok|dormant/ 
					) {
				if ($intfData->{$eachIfIndex}{event} eq 'true') {
					Compat::NMIS::notify(sys=>$S,event=>"Interface Down",element=>$intfData->{$eachIfIndex}{ifDescr},details=>$intfData->{$eachIfIndex}{Description});
				}
			} 
			else 
			{
				Compat::NMIS::checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$intfData->{$eachIfIndex}{ifDescr},details=>$intfData->{$eachIfIndex}{Description});
			}
		}
	}
	# save values only if all interfaces are updated
	$NI->{system}{intfTotal}   = $intfTotal;
	$NI->{system}{intfCollect} = $intfCollect;
		

	# Now we save eachInterface in our node. We do this as a separate 
	# step because the above might alter names because of duplication.
	my $intDump = Dumper $intfData;
	$NG->log->debug5("intfData = ".$intDump);
	foreach my $index (keys %{$intfData}) 
	{
		$NG->log->debug5("Saving Index: $index");
		# Now get-or-create an inventory object for this new concept
		#
		my $intfSubData = $intfData->{$index};
		next if (!keys %{$intfSubData});
		my $ifDescr     = $intfSubData->{ifDescr};
		$NG->log->debug5("intfSubData = " . Dumper($intfSubData) . "\n\n\n");
		my $path_keys =  ['index'];
		my $path = $nodeobj->inventory_path( concept => 'interface', path_keys => $path_keys, data => $intfSubData );
		my ($inventory, $error) =  $nodeobj->inventory(
			create => 1,				# if not present yet
			concept => "interface",
			data => $intfSubData,
			path_keys => $path_keys,
			path => $path );
	
		if(!$inventory or $error)
		{
			$NG->log->error("Failed to get inventory for interface index $index; Error: $error");
			next;								# not much we can do in this case...
		}
		$inventory->historic(0);
		if ($intfSubData->{collect} eq 'true')
		{
			$inventory->enabled(1);
		}
		else
		{
			$inventory->enabled(0);
		}
		$inventory->description( $intfSubData->{ifDescr} );
		$inventory->data( $intfSubData );

		# set which columns should be displayed
		$inventory->data_info(
			subconcept => "interface",
			enabled => 1,
			display_keys => $intfInfo
		);

		$NG->log->info("Interface description is '$intfSubData->{ifDescr}'");

		my $desiredlimit = $intfData->{$index}{setlimits};
		# $NG->log->info("Desiredlimit: $desiredlimit" );
		# $NG->log->info("ifSpeed: " . $intfData->{$index}{ifSpeed});
		# $NG->log->info("collect: " . $intfData->{$index}{collect});
		# no limit or dud limit or dud speed or non-collected interface?
		if ($desiredlimit && $desiredlimit =~ /^(normal|strict|off)$/
				&& $intfData->{$index}{ifSpeed}
				&& NMISNG::Util::getbool($intfData->{$index}{collect}))
		{
			$NG->log->debug2("performing rrd speed limit tuning for $ifDescr, limit enforcement: $desiredlimit, interface speed is ".NMISNG::Util::convertIfSpeed($intfData->{$index}{ifSpeed})." ($intfData->{$index}{ifSpeed})");

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
			my $maxbytes = 	$desiredlimit eq "off"? "U": $desiredlimit eq "normal"
				? int($intfData->{$index}{ifSpeed}/4)
				: int($intfData->{$index}{ifSpeed}/8);
			my $maxpkts = $maxbytes eq "U" # this is a dodgy heuristic
				? "U"
				: int($maxbytes/50);
			for (
				["interface", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)/],
				[   "pkts", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/ ],
				[   "pkts_hc", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/ ],
			)
			{
				my ( $datatype, $dsregex ) = @$_;
	
				# rrd file exists and readable?
				if ( -r ( my $rrdfile = $S->makeRRDname( graphtype => $datatype,
														 index => $index,
														 inventory => $inventory,
														 conf => $NC ) ) )
				{
					my $fileinfo = RRDs::info($rrdfile);
					for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
					{
						# only touch relevant and known datasets
						next if ( $matching !~ /($dsregex)/ );
						my $dsname = $1;
	
						my $curval = $fileinfo->{$matching};
						$curval = "U" if ( !defined $curval or $curval eq "" );
	
						# the pkts, discards, errors DS are packet based; the octets ones are bytes
						my $desiredval = $dsname =~ /octets/i ? $maxbytes : $maxpkts;
	
						if ( $curval ne $desiredval )
						{
							$NG->log->debug2( "rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit");
							RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
						}
						else
						{
							$NG->log->debug2("rrd section $datatype, ds $dsname, current limit $curval is correct");
						}
					}
				}
			}
		}

		# The above has added data to the inventory, that we now save.
		my ( $op, $subError ) = $inventory->save();
		$NG->log->debug2( "saved ".join(',', @$path)." op: $op");
		if ($subError)
		{
			$NG->log->error("Failed to save inventory for Interface '$intfSubData->{ifDescr}' (ID '$index'): $subError");
		}
		else
		{
			$NG->log->debug( "Saved Interface '$intfSubData->{ifDescr}' (ID '$index'); op: $op");
			$changesweremade = 1;
		}
	}
	if ($changesweremade)
	{
		$NG->log->info("$intfTotal Interfaces were added.");
	}
	else
	{
		$NG->log->info("No Interfaces were added.");
	}
	$snmp->close;

	return ($changesweremade,undef);			# happy
}

sub getIfDescr {
	my %args = @_;
	
	my $oid_value 		= $args{ifIndex};	
	my $prefix   		= $args{prefix};	
	my $asamModel 		= $args{asamModel};	
	
	if ( $args{version} eq "6.2" ) {
		my $slot_mask 		= 0x1FE00000;
		my $level_mask 		= 0x001E0000;	
		my $circuit_mask 	= 0x0001FE00;
			
		my $slot 	= ($oid_value & $slot_mask) 	>> 21;
		my $level 	= ($oid_value & $level_mask) 	>> 17;
		my $circuit = ($oid_value & $circuit_mask) 	>> 9;
		
		# Apparently this needs to be adjusted when going to decimal?
		if ( $slot > 1 ) {
			--$slot;
		}
		++$circuit;	
		
		$prefix = "XDSL" if $level == 16;
		
		my $slotCor = asamSlotCorrection($slot,$asamModel);

		$NG->log->debug2("ASAM getIfDescr: ifIndex='$args{ifIndex}'; Slot='$slot'; Slot Correction='$slotCor'; ASAMVersion='$args{version}'; ASAMModel='$asamModel'");

		return "$prefix-1-1-$slotCor-$circuit";	
	}
	elsif ( $args{version} eq "4.1" or $args{version} eq "4.3" ) {
		my $rack_mask 		= 0x70000000;
		my $shelf_mask 		= 0x07000000;
		my $slot_mask 		= 0x00FF0000;
		my $level_mask 		= 0x0000F000;
		my $circuit_mask 	= 0x00000FFF;
	
		my $rack 	= ($oid_value & $rack_mask) 		>> 28;
		my $shelf 	= ($oid_value & $shelf_mask) 		>> 24;
		my $slot 	= ($oid_value & $slot_mask) 		>> 16;
		my $level 	= ($oid_value & $level_mask) 		>> 12;
		my $circuit = ($oid_value & $circuit_mask);

		# Apparently this needs to be adjusted when going to decimal?
		$slot = $slot - 2;
		++$circuit;	
		
		my $slotCor = asamSlotCorrection($slot,$asamModel);

		$NG->log->debug2("ASAM getIfDescr: ifIndex='$args{ifIndex}'; Slot='$slot'; Slot Correction='$slotCor'; ASAMVersion='$args{version}'; ASAMModel='$asamModel'");

		return "$prefix-$rack-$shelf-$slotCor-$circuit";
	}
	else {
		my $slot_mask 		= 0x7E000000;
		my $level_mask 		= 0x01E00000;	
		my $circuit_mask 	= 0x001FE000;
			
		my $slot 	= ($oid_value & $slot_mask) 	>> 25;
		my $level 	= ($oid_value & $level_mask) 	>> 21;
		my $circuit = ($oid_value & $circuit_mask) 	>> 13;
		
		# Apparently this needs to be adjusted when going to decimal?
		if ( $slot > 1 ) {
			--$slot;
		}
		++$circuit;	
		
		$prefix = "XDSL" if $level == 16;
		
		my $slotCor = asamSlotCorrection($slot,$asamModel);

		$NG->log->debug2("ASAM getIfDescr: ifIndex='$args{ifIndex}'; Slot='$slot'; Slot Correction='$slotCor'; ASAMVersion='$args{version}'; ASAMModel='$asamModel'");

		return "$prefix-1-1-$slotCor-$circuit";		
	}
}

sub asamSlotCorrection {
	my $slot = shift;
	my $asamModel = shift;
	
	if ( $asamModel =~ /7302/ ) {
		if ( $slot == 17 or $slot == 18 ) {
			$slot = $slot - 7;
		} 
		elsif ( $slot >= 9 ) {
			$slot = $slot + 3;
		} 
	}
	elsif ( $asamModel =~ /ARAM-D/ ) {
		$slot = $slot + 3
	}
	elsif ( $asamModel =~ /ARAM-E/ ) {
		if ( $slot == 17 or $slot == 18 ) {
			$slot = $slot - 9;
		} 
		elsif ( $slot < 7 ) {
			$slot = $slot + 1
		}
		elsif ( $slot >= 7 ) {
			$slot = $slot + 5
		}
	}
	elsif ( $asamModel =~ /7330-FD/ ) {
		if ( $slot < 9 ) {
			$slot = $slot + 3
		}
		elsif ( $slot == 9 or $slot == 10 ) {
			$slot = $slot - 7
		}
	}

	return $slot;
} 

sub getDescription {
	my %args = @_;
	
	my $oid_value 		= $args{ifIndex};	
	
	if ( $args{version} eq "4.1" ) {
		my $rack_mask 		= 0x70000000;
		my $shelf_mask 		= 0x07000000;
		my $slot_mask 		= 0x00FF0000;
		my $level_mask 		= 0x0000F000;
		my $circuit_mask 	= 0x00000FFF;
	
		my $rack 		= ($oid_value & $rack_mask) 		>> 28;
		my $shelf 	= ($oid_value & $shelf_mask) 		>> 24;
		my $slot 		= ($oid_value & $slot_mask) 		>> 16;
		my $level 	= ($oid_value & $level_mask) 		>> 12;
		my $circuit = ($oid_value & $circuit_mask);
		
		# Apparently this needs to be adjusted when going to decimal?
		$slot = $slot - 2;
		++$circuit;	

		$NG->log->debug2("ASAM getDescription: Rack='$rack'; Shelf='$shelf'; Slot='$slot'; Circuit='$circuit'");
		return "Rack=$rack, Shelf=$shelf, Slot=$slot, Circuit=$circuit";
	}
	else {
		my $slot_mask 		= 0x7E000000;
		my $level_mask 		= 0x01E00000;	
		my $circuit_mask 	= 0x001FE000;
		
		my $slot 		= ($oid_value & $slot_mask) 		>> 25;
		my $level 	= ($oid_value & $level_mask) 		>> 21;
		my $circuit = ($oid_value & $circuit_mask) 	>> 13;

		if ( $slot > 1 ) {
			--$slot;
		}
		++$circuit;	

		$NG->log->debug2("ASAM getDescription: Rack='N/A'; Shelf='N/A'; Slot='$slot'; Circuit='$circuit'");
		return "Slot=$slot, Level=$level, Circuit=$circuit";		
	}
}

sub ifStatus {
	my $statusNumber = shift;
	
	return 'up' if $statusNumber == 1;
	return 'down' if $statusNumber == 2;
	return 'testing' if $statusNumber == 3;
	return 'dormant' if $statusNumber == 5;
	return 'notPresent' if $statusNumber == 6;
	return 'lowerLayerDown' if $statusNumber == 7;
	
	# 4 is unknown.
	return 'unknown';
}	

1;
