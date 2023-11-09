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

package AlcatelASAM;
our $VERSION = "2.0.0";
use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;				# for snmp-related access

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(
	getIfDescr
);
my $node;
my $S;
my $C;
my $NG;

# *****************************************************************************
# Set this to disable collection on Interfaces set to 'available'.
# *****************************************************************************
my $ignoreAvaibleInterfaces = 1;
# *****************************************************************************


sub update_plugin
{
	my (%args) = @_;
	($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};
	my $NI            = $S->nmisng_node;

	my $intfData             = undef;
	my $intfInfo             = undef;
	my $intfTotal            = 0;
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

	my $nodeobj       = $NG->node(name => $node);
	my $NC            = $nodeobj->configuration;
	my $catchall_data = $S->inventory( concept => 'catchall' )->{_data};
	my $IF            = $nodeobj->ifinfo;
	my %nodeconfig    = %{$S->nmisng_node->configuration};

	# anything to do?
	# This plugin deals only with this specific device type, and only ones with snmp enabled and working
	# and finally only if the number of interfaces is greater than the limit, otherwise the normal
	# discovery will populate all interfaces normally.
	if ( $catchall_data->{nodeModel} !~ /AlcatelASAM/ or !NMISNG::Util::getbool($catchall_data->{collect}))
	{
		$NG->log->debug("Max Interfaces are: '$interface_max_number'");
		$NG->log->debug("Collection status is ".NMISNG::Util::getbool($catchall_data->{collect}));
		$NG->log->debug("Node '$node', has $catchall_data->{ifNumber} interfaces.");
		$NG->log->debug("Node '$node', Model '$catchall_data->{nodeModel}' does not qualify for this plugin.");
		return (0,undef);
	}
	else
	{
		$NG->log->info("Running Alcatel ASAM plugin for Node '$node', Model '$catchall_data->{nodeModel}'.");
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
	$asamModel = $eqptHolderList->{_data}->{eqptHolderPlannedType} || $catchall_data->{nodeModel};
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

	$catchall_data->{asamModel} = $asamModel;

	my $asamSoftwareVersion = $catchall_data->{asamSoftwareVersion1};
	if ( $catchall_data->{asamActiveSoftware2} eq "active" ) 
	{
		$asamSoftwareVersion = $catchall_data->{asamSoftwareVersion2};
	}
	my @verParts = split("/",$asamSoftwareVersion);
	$asamSoftwareVersion = $verParts[$#verParts];

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
		$NG->log->warn("ERROR: Unknown ASAM Version $node asamSoftwareVersion='$asamSoftwareVersion'");
		return (2, "Could not retrieve ASAM Version from node '$node'");
	}

	$catchall_data->{asamVersion} = $version;

	# NMISNG::Snmp doesn't fall back to global config
	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};

	# Get the SNMP Session going.
	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		my $error = $snmp->error;
		undef $snmp;
		$NG->log->error("Could not open SNMP session to node $node: ".$error);
		return (2, "Could not open SNMP session to node $node: ".$error);
	}
	if (!$snmp->testsession)
	{
		my $error = $snmp->error;
		$snmp->close;
		$NG->log->warn("Could not retrieve SNMP vars from node $node: ".$error);
		return (2, "Could not retrieve SNMP vars from node $node: ".$error);
	}

	$intfTotal = 0;
	$intfInfo = [
		{ index         => "Index" },
		{ interface     => "Interface Name" },
		{ ifIndex       => "Interface Index" },
		{ ifName        => "Interface Internal Name" },
		{ Description   => "Interface Description" },
		{ ifDesc        => "Interface Internal Description" },
		{ ifType        => "Interface Type" },
		{ ifSpeed       => "Interface Speed" },
		{ ifSpeedIn     => "Interface Speed In" },
		{ ifSpeedOut    => "Interface Speed Out" },
		{ ifAdminStatus => "Interface Administrative State" },
		{ ifOperStatus  => "Interface Operational State" },
		{ ifLastChange  => "Interface Last Change" },
		{ setlimits     => "Interface Set Limnits" },
		{ collect       => "Interface Collection Status" },
		{ event         => "Interface Event Status" },
		{ threshold     => "Interface Threshold Status" }
	];

	my $ifTableData = $S->nmisng_node->get_inventory_ids(
		concept => "ifTable",
		filter => { historic => 0 });
	if (@$ifTableData)
	{
		for my $ifTableId (@$ifTableData)
		{
			my ($ifEntry, $error) = $S->nmisng_node->inventory(_id => $ifTableId);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for Interface ID: '$ifTableId'; Error: $error");
				next;
			}
			my $ifData            = $ifEntry->data();
			my $eachIfIndex       = $ifData->{"index"};
			my $eachIfAdminStatus = $ifData->{"ifAdminStatus"};
			my $eachIfDescription = $ifData->{"ifDescr"};
			$intfData->{$eachIfIndex}->{index}             = $ifData->{index};
			$intfData->{$eachIfIndex}->{ifIndex}           = $ifData->{ifIndex};
			$intfData->{$eachIfIndex}->{interface}         = NMISNG::Util::convertIfName($ifData->{ifDescr});
			$intfData->{$eachIfIndex}->{ifName}            = $ifData->{ifName};
			$intfData->{$eachIfIndex}->{Description}       = '';
			$intfData->{$eachIfIndex}->{ifDescr}           = $ifData->{ifDescr};
			$intfData->{$eachIfIndex}->{ifType}            = $ifData->{ifType};
			$intfData->{$eachIfIndex}->{ifAdminStatus}     = $ifData->{ifAdminStatus};
			$intfData->{$eachIfIndex}->{ifOperStatus}      = $ifData->{ifOperStatus};
			$intfData->{$eachIfIndex}->{ifLastChange}      = $ifData->{ifLastChange};
			$intfData->{$eachIfIndex}->{setlimits}         = $NI->{interface}->{$eachIfIndex}->{setlimits} // "normal";
			$intfData->{$eachIfIndex}->{collect}           = $eachIfAdminStatus eq "up" ? "true" : "false";
			$intfData->{$eachIfIndex}->{event}             = $eachIfAdminStatus eq "up" ? "true" : "false";
			$intfData->{$eachIfIndex}->{threshold}         = $eachIfAdminStatus eq "up" ? "true" : "false";
			# check for duplicated ifDescr
			foreach my $i (@$ifTableData) {
				if ($eachIfIndex ne $i and $intfData->{$eachIfIndex}->{ifDescr} eq $intfData->{$i}->{ifDescr}) {
					$intfData->{$eachIfIndex}->{ifDescr} = "$eachIfDescription-$eachIfIndex"; # add index to this description.
					$intfData->{$i}->{ifDescr}           = "$eachIfDescription-$i";           # and the duplicte one.
					$NG->log->debug2("Index added to duplicate Interface Description '$eachIfDescription'");
				}
			}
			$NG->log->debug5("Interface Index:        '$eachIfIndex'");
			$NG->log->debug5("Interface Name:         '$ifData->{ifName}'");
			$NG->log->debug5("Interface Description:  '$ifData->{ifDescr}'");
			$NG->log->debug5("Interface Type:         '$ifData->{ifType}'");
			$NG->log->debug5("Admin Status:           '$ifData->{ifAdminStatus}'");
			$NG->log->debug5("Operator Status:        '$ifData->{ifOperStatus}'");
		}
	}


	$NG->log->info("Working on '$node' Customer_ID");
	my $customerData;
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
			$customerData      = $customerEntry->data();
			my $eachIfIndex    = $customerData->{index};
			my $eachCustomerId = $customerData->{asamIfExtCustomerId};
			$NG->log->debug5("Interface Index:        '$eachIfIndex'");
			$NG->log->debug5("Customer ID:            '$eachCustomerId'");
			if ( defined $intfData->{$eachIfIndex} ) {
				if ($ignoreAvaibleInterfaces)
				{
					$intfData->{$eachIfIndex}->{collect}       = ($intfData->{$eachIfIndex}->{ifAdminStatus} eq "up" && $eachCustomerId ne "available") ? "true" : "false";
				}
				$customerData->{ifDescr}       = $intfData->{$eachIfIndex}->{ifDescr};
				$customerData->{ifAdminStatus} = $intfData->{$eachIfIndex}->{ifAdminStatus};
				$customerData->{ifOperStatus}  = $intfData->{$eachIfIndex}->{ifOperStatus};
				$customerData->{ifType}        = $intfData->{$eachIfIndex}->{ifType};
				$NG->log->debug5("Interface Description:  '$customerData->{ifDescr}'");
				$NG->log->debug5("Admin Status:           '$customerData->{ifAdminStatus}'");
				$NG->log->debug5("Operator Status:        '$customerData->{ifOperStatus}'");
				$NG->log->debug5("Interface Type:         '$customerData->{ifType}'");
				# The above has added data to the inventory, that we now save.
				my $path_keys =  ['index'];
				my $path = $nodeobj->inventory_path( concept => 'Customer_ID', path_keys => $path_keys, data => $customerData );
				my ($inventory, $error) =  $nodeobj->inventory(
					create => 1,				# if not present yet
					concept => "Customer_ID",
					data => $customerData,
					path_keys => $path_keys,
					path => $path );

				if(!$inventory or $error)
				{
					$NG->log->error("Failed to get inventory for Customer ID: '$customerId'; Error: $error");
					next;								# not much we can do in this case...
				}
				# The above has added data to the inventory, that we now save.
				$inventory->data( $customerData );
				my ( $op, $subError ) = $inventory->save();
				$NG->log->debug2( "Saved ".join(',', @$path)."; op: $op");
				if ($subError)
				{
					$NG->log->error("Failed to save inventory for Customer ID: '$customerId'; Error: $subError");
				}
				else
				{
					$NG->log->debug( "Saved Customer ID: '$customerId'; op: $op");
					$changesweremade = 1;
				}
			}
		}
	}

	# Using the data we collect from the atmVcl we will fill in the details of the DSLAM Port.
	$NG->log->info("Working on '$node' atmVcl");

	my $offset = 12288;
	if ( $version eq "4.2" )  {
		$offset = 6291456;
	}
	elsif ( $version eq "6.2" )  {
		$offset = 393216;
	}

	# the ordered list of SNMP variables I want.
	my @atmVclVars = qw(
		asamIfExtCustomerId
		xdslLineServiceProfileNbr
		xdslLineSpectrumProfileNbr
	);

	my $atmVclIds = $S->nmisng_node->get_inventory_ids(
		concept => "atmVcl",
		filter => { historic => 0 });
	if (@$atmVclIds)
	{
		for my $atmVclId (@$atmVclIds)
		{
			my $ifIndex;
			my $atmVclVpi;
			my $atmVclVci;
			my ($atmVclEntry, $error) = $S->nmisng_node->inventory(_id => $atmVclId);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for ATM Virtual Channel Link ID: '$atmVclId'; Error: $error");
				next;
			}
			my $atmVclData     = $atmVclEntry->data();
			my $eachIfIndex    = $atmVclData->{index};
			if ( my @parts = split(/\./,$atmVclData->{index}) ) 
			{
				$ifIndex   = shift(@parts);
				$atmVclVpi = shift(@parts);
				$atmVclVci = shift(@parts);

				$atmVclData->{ifIndex}                    = $ifIndex;
				$atmVclData->{atmVclVpi}                  = $atmVclVpi;
				$atmVclData->{atmVclVci}                  = $atmVclVci;
	
				# the crazy magic of ASAM
				my $offsetIndex = $ifIndex - $offset;
	
				# the set of oids with dynamic index I want.
				my %atmOidSet = (
	 				asamIfExtCustomerId =>        "1.3.6.1.4.1.637.61.1.6.5.1.1.$offsetIndex",
					xdslLineServiceProfileNbr =>  "1.3.6.1.4.1.637.61.1.39.3.7.1.1.$offsetIndex",
					xdslLineSpectrumProfileNbr => "1.3.6.1.4.1.637.61.1.39.3.7.1.2.$offsetIndex",					
				);
	
				# build an array combining the atmVclVars and atmOidSet into a single array
				my @oids = map {$atmOidSet{$_}} @atmVclVars;
				#print Dumper \@oids;
	
				# get the snmp data from the thing
				$snmpData = $snmp->get(@oids);
				if ( $snmp->error() ) {
					$NG->log->debug("ERROR with SNMP on '$node'; Error: ". $snmp->error());
				}
	
				# save the data for the atmVcl					
				$atmVclData->{asamIfExtCustomerId}        = $customerData->{$ifIndex};
				$atmVclData->{xdslLineServiceProfileNbr}  = "N/A";
				$atmVclData->{xdslLineSpectrumProfileNbr} = "N/A";
	
				if ( $snmpData ) {
	
					foreach my $var (@atmVclVars) {
						my $dataKey = $atmOidSet{$var};
						if ( $snmpData->{$dataKey} ne "" and $snmpData->{$dataKey} !~ /SNMP ERROR/ ) {
							$atmVclData->{$var} = $snmpData->{$dataKey};
						}
						else {
							$NG->log->debug("ERROR with SNMP on '$node' var='$var': ".$snmpData->{$dataKey}) if ($snmpData->{$dataKey} =~ /SNMP ERROR/);
							$atmVclData->{$var} = "N/A";
						}
					}
	
					$NG->log->debug("atmVcl SNMP Results: ifIndex=$ifIndex atmVclVpi=$atmVclVpi atmVclVci=$atmVclVci asamIfExtCustomerId=$atmVclData->{asamIfExtCustomerId}");
	
					if ( defined $intfData->{$ifIndex}->{ifDescr} ) {
						$atmVclData->{ifDescr} = $intfData->{$ifIndex}{ifDescr};
						$atmVclData->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifIndex&node=$node";
						$atmVclData->{ifDescr_id} = "node_view_$node";
					}
					else {
						$atmVclData->{ifDescr} = getIfDescr(prefix => "ATM", version => $version, ifIndex => $ifIndex, asamModel => $asamModel);
					}
				}
			}
			if ( defined $intfData->{$ifIndex} ) {
				$atmVclData->{ifDescr}       = $intfData->{$ifIndex}->{ifDescr};
				$atmVclData->{ifAdminStatus} = $intfData->{$ifIndex}->{ifAdminStatus};
				$atmVclData->{ifOperStatus}  = $intfData->{$ifIndex}->{ifOperStatus};
				$atmVclData->{ifType}        = $intfData->{$ifIndex}->{ifType};
			}
			else
			{
				$atmVclData->{ifDescr}       = "N/A";
				$atmVclData->{ifAdminStatus} = "Unknown";
				$atmVclData->{ifOperStatus}  = "Unknown";
				$atmVclData->{ifType}        = "N/A";
			}
			$NG->log->debug5("Interface Index:         '$eachIfIndex'");
			$NG->log->debug5("Interface Description:   '$atmVclData->{ifDescr}'");
			$NG->log->debug5("Interface Admin Status:  '$atmVclData->{ifAdminStatus}'");
			$NG->log->debug5("Interface Oper Status :  '$atmVclData->{ifOperStatus}'");
			$NG->log->debug5("Interface Type:          '$atmVclData->{ifType}'");
			$NG->log->debug5("Customer ID:             '$atmVclData->{asamIfExtCustomerId}'");
			$NG->log->debug5("Connection Kind:         '$atmVclData->{atmVclConnKind}'");
			$NG->log->debug5("VCL Interface Index:     '$atmVclData->{atmVclIfIndex}'");
			$NG->log->debug5("VCL Path Index:          '$atmVclData->{atmVclVpi}'");
			$NG->log->debug5("VCL Channel Index:       '$atmVclData->{atmVclVci}'");
			$NG->log->debug5("VCL AAL Type:            '$atmVclData->{atmVccAalType}'");
			$NG->log->debug5("VCL Cast Type:           '$atmVclData->{atmVclCastType}'");
			$NG->log->debug5("VCL Row Status:          '$atmVclData->{atmVclRowStatus}'");
			$NG->log->debug5("VCL Admin Status:        '$atmVclData->{atmVclAdminStatus}'");
			$NG->log->debug5("VCL Oper Status:         '$atmVclData->{atmVclOperStatus}'");
			$NG->log->debug5("VCL Interface Index:     '$atmVclData->{ifIndex}'");
			$NG->log->debug5("Service Profile Number:  '$atmVclData->{xdslLineServiceProfileNbr}'");
			$NG->log->debug5("Spectrum Profile Number: '$atmVclData->{xdslLineSpectrumProfileNbr}'");
			# The above has added data to the inventory, that we now save.
			my $path_keys =  ['index'];
			my $path = $nodeobj->inventory_path( concept => 'atmVcl', path_keys => $path_keys, data => $atmVclData );
			my ($inventory, $error) =  $nodeobj->inventory(
				create => 1,				# if not present yet
				concept => "atmVcl",
				data => $atmVclData,
				path_keys => $path_keys,
				path => $path );

			if(!$inventory or $error)
			{
				$NG->log->error("Failed to get inventory for ATM Virtual Channel Link ID: '$atmVclId'; Error: $error");
				next;								# not much we can do in this case...
			}
			# The above has added data to the inventory, that we now save.
			$inventory->data( $atmVclData );
			my ( $op, $subError ) = $inventory->save();
			$NG->log->debug2( "Saved ".join(',', @$path)."; op: $op");
			if ($subError)
			{
				$NG->log->error("Failed to save inventory for ATM Virtual Channel Link ID: '$atmVclId'; Error: $subError");
			}
			else
			{
				$NG->log->debug( "Saved ATM Virtual Channel Link ID: '$atmVclId'; op: $op");
				$changesweremade = 1;
			}
		}
	}


	#"xdslLinkUp"                              "1.3.6.1.4.1.637.61.1.39.12"
	#"xdslLinkUpTable"                         "1.3.6.1.4.1.637.61.1.39.12.1"
	#"xdslLinkUpEntry"                         "1.3.6.1.4.1.637.61.1.39.12.1.1"
	#"xdslLinkUpTimestampDown"                 "1.3.6.1.4.1.637.61.1.39.12.1.1.1"
	#"xdslLinkUpTimestampUp"                   "1.3.6.1.4.1.637.61.1.39.12.1.1.2"
	#"xdslLinkUpThresholdBitrateUpstream"      "1.3.6.1.4.1.637.61.1.39.12.1.1.13"
	#"xdslLinkUpThresholdBitrateDownstream"    "1.3.6.1.4.1.637.61.1.39.12.1.1.14"
	#"xdslLinkUpMaxDelayUpstream"              "1.3.6.1.4.1.637.61.1.39.12.1.1.15"
	#"xdslLinkUpMaxDelayDownstream"            "1.3.6.1.4.1.637.61.1.39.12.1.1.16"
	#"xdslLinkUpTargetNoiseMarginUpstream"     "1.3.6.1.4.1.637.61.1.39.12.1.1.17"
	#"xdslLinkUpTargetNoiseMarginDownstream"   "1.3.6.1.4.1.637.61.1.39.12.1.1.18"
	#"xdslLinkUpTimestamp"                     "1.3.6.1.4.1.637.61.1.39.12.2"
	#"xdslLinkUpLineBitmapTable"               "1.3.6.1.4.1.637.61.1.39.12.3"
	#"xdslLinkUpLineBitmapEntry"               "1.3.6.1.4.1.637.61.1.39.12.3.1"
	#"xdslLinkUpLineBitmap"                    "1.3.6.1.4.1.637.61.1.39.12.3.1.1"    

	#"asamIfExtCustomerId"                     "1.3.6.1.4.1.637.61.1.6.5.1.1"
	#"xdslLineServiceProfileNbr"               "1.3.6.1.4.1.637.61.1.39.3.7.1.1"

	#"xdslLineOutputPowerDownstream"           "1.3.6.1.4.1.637.61.1.39.3.8.1.1.3"
	#"xdslLineLoopAttenuationUpstream"         "1.3.6.1.4.1.637.61.1.39.3.8.1.1.5"
	#"xdslFarEndLineOutputPowerUpstream"       "1.3.6.1.4.1.637.61.1.39.4.1.1.1.3"
	#"xdslFarEndLineLoopAttenuationDownstream" "1.3.6.1.4.1.637.61.1.39.4.1.1.1.5"

	#"xdslXturInvSystemSerialNumber"           "1.3.6.1.4.1.637.61.1.39.8.1.1.2"

	#"xdslLinkUpActualBitrateUpstream"         "1.3.6.1.4.1.637.61.1.39.12.1.1.3"
	#"xdslLinkUpActualBitrateDownstream"       "1.3.6.1.4.1.637.61.1.39.12.1.1.4"
	#"xdslLinkUpActualNoiseMarginUpstream"     "1.3.6.1.4.1.637.61.1.39.12.1.1.5"
	#"xdslLinkUpActualNoiseMarginDownstream"   "1.3.6.1.4.1.637.61.1.39.12.1.1.6"
	#"xdslLinkUpAttenuationUpstream"           "1.3.6.1.4.1.637.61.1.39.12.1.1.7"
	#"xdslLinkUpAttenuationDownstream"         "1.3.6.1.4.1.637.61.1.39.12.1.1.8"
	#"xdslLinkUpAttainableBitrateUpstream"     "1.3.6.1.4.1.637.61.1.39.12.1.1.9"
	#"xdslLinkUpAttainableBitrateDownstream"   "1.3.6.1.4.1.637.61.1.39.12.1.1.10"
	#"xdslLinkUpMaxBitrateUpstream"            "1.3.6.1.4.1.637.61.1.39.12.1.1.11"
	#"xdslLinkUpMaxBitrateDownstream"          "1.3.6.1.4.1.637.61.1.39.12.1.1.12"

	$NG->log->info("Working on '$node' ifTable for DSLAM Port Data");

	# the ordered list of SNMP variables I want.
	my @ifDslamVarList = qw(
		asamIfExtCustomerId
		xdslLineServiceProfileName
		xdslLineServiceProfileNbr
		xdslLineSpectrumProfileNbr
		xdslLineOutputPowerDownstream
		xdslLineLoopAttenuationUpstream
		xdslFarEndLineOutputPowerUpstream
		xdslFarEndLineLoopAttenuationDownstream
		xdslXturInvSystemSerialNumber
		xdslLinkUpActualBitrateUpstream
		xdslLinkUpActualBitrateDownstream
		xdslLinkUpActualNoiseMarginUpstream
		xdslLinkUpActualNoiseMarginDownstream
		xdslLinkUpAttenuationUpstream
		xdslLinkUpAttenuationDownstream
		xdslLinkUpAttainableBitrateUpstream
		xdslLinkUpAttainableBitrateDownstream
		xdslLinkUpMaxBitrateUpstream
		xdslLinkUpMaxBitrateDownstream
	);

	my $ifDslamData;
	my $ifDslamIds = $S->nmisng_node->get_inventory_ids(
		concept => "DSLAM_Ports",
		filter => { historic => 0 });
	if (@$ifDslamIds)
	{
		for my $ifDslamId (@$ifDslamIds)
		{
			my ($ifDslamEntry, $error) = $S->nmisng_node->inventory(_id => $ifDslamId);
			if ($error)
			{
				$NG->log->error("Failed to get inventory for DSLAM Port ID: '$ifDslamId'; Error: $error");
				next;
			}
			$ifDslamData       = $ifDslamEntry->data();
			my $eachIfIndex    = $ifDslamData->{index};
			my $eachCustomerId = $customerData->{$eachIfIndex};;
			$ifDslamData->{asamIfExtCustomerId} = $customerData->{$eachIfIndex};
			$NG->log->debug5("Interface Index:        '$eachIfIndex'");
			$NG->log->debug5("Customer ID:            '$eachCustomerId'");
			if ( defined $intfData->{$eachIfIndex} ) {
				$ifDslamData->{ifDescr}       = $intfData->{$eachIfIndex}->{ifDescr};
				$ifDslamData->{ifAdminStatus} = $intfData->{$eachIfIndex}->{ifAdminStatus};
				$ifDslamData->{ifOperStatus}  = $intfData->{$eachIfIndex}->{ifOperStatus};
				$ifDslamData->{ifType}        = $intfData->{$eachIfIndex}{ifType};
			}
			else
			{
				$ifDslamData->{ifDescr}       = "N/A";
				$ifDslamData->{ifAdminStatus} = "Unknown";
				$ifDslamData->{ifOperStatus}  = "Unknown";
				$ifDslamData->{ifType}        = "N/A";
			}
			$NG->log->debug5("Interface Index:         '$eachIfIndex'");
			$NG->log->debug5("Interface Description:   '$ifDslamData->{ifDescr}'");
			$NG->log->debug5("Interface Admin Status:  '$ifDslamData->{ifAdminStatus}'");
			$NG->log->debug5("Interface Oper Status:   '$ifDslamData->{ifOperStatus}'");
			$NG->log->debug5("Interface Type:          '$ifDslamData->{ifType}'");
			$NG->log->debug5("Customer ID:             '$ifDslamData->{asamIfExtCustomerId}'");
		}
	}

	for my $eachIfIndex (keys %{$intfData})
	{
		if ( $intfData->{$eachIfIndex}->{ifDescr} eq "XDSL Line" )
		{					
			# the crazy magic of ASAM
			my $atmOffsetIndex = $eachIfIndex + $offset;

			# the set of oids with dynamic index I want.
			my %ifDslamOidSet = (
				asamIfExtCustomerId =>                     "1.3.6.1.4.1.637.61.1.6.5.1.1.$eachIfIndex",
				xdslLineServiceProfileName =>              "1.3.6.1.4.1.637.61.1.39.3.3.1.1.2.$eachIfIndex",
				xdslLineServiceProfileNbr =>               "1.3.6.1.4.1.637.61.1.39.3.7.1.1.$eachIfIndex",
				xdslLineSpectrumProfileNbr =>              "1.3.6.1.4.1.637.61.1.39.3.7.1.2.$eachIfIndex",                    
				xdslLineOutputPowerDownstream =>           "1.3.6.1.4.1.637.61.1.39.3.8.1.1.3.$eachIfIndex",
				xdslLineLoopAttenuationUpstream =>         "1.3.6.1.4.1.637.61.1.39.3.8.1.1.5.$eachIfIndex",
				xdslFarEndLineOutputPowerUpstream =>       "1.3.6.1.4.1.637.61.1.39.4.1.1.1.3.$eachIfIndex",
				xdslFarEndLineLoopAttenuationDownstream => "1.3.6.1.4.1.637.61.1.39.4.1.1.1.5.$eachIfIndex",
				xdslXturInvSystemSerialNumber =>           "1.3.6.1.4.1.637.61.1.39.8.1.1.2.$eachIfIndex",
				xdslLinkUpActualBitrateUpstream =>         "1.3.6.1.4.1.637.61.1.39.12.1.1.3.$eachIfIndex",
				xdslLinkUpActualBitrateDownstream =>       "1.3.6.1.4.1.637.61.1.39.12.1.1.4.$eachIfIndex",
				xdslLinkUpActualNoiseMarginUpstream =>     "1.3.6.1.4.1.637.61.1.39.12.1.1.5.$eachIfIndex",
				xdslLinkUpActualNoiseMarginDownstream =>   "1.3.6.1.4.1.637.61.1.39.12.1.1.6.$eachIfIndex",
				xdslLinkUpAttenuationUpstream =>           "1.3.6.1.4.1.637.61.1.39.12.1.1.7.$eachIfIndex",
				xdslLinkUpAttenuationDownstream =>         "1.3.6.1.4.1.637.61.1.39.12.1.1.8.$eachIfIndex",
				xdslLinkUpAttainableBitrateUpstream =>     "1.3.6.1.4.1.637.61.1.39.12.1.1.9.$eachIfIndex",
				xdslLinkUpAttainableBitrateDownstream =>   "1.3.6.1.4.1.637.61.1.39.12.1.1.10.$eachIfIndex",
				xdslLinkUpMaxBitrateUpstream =>            "1.3.6.1.4.1.637.61.1.39.12.1.1.11.$eachIfIndex",
				xdslLinkUpMaxBitrateDownstream =>          "1.3.6.1.4.1.637.61.1.39.12.1.1.12.$eachIfIndex",
			);

			# build an array combining the ifDslamVarList and ifDslamOidSet into a single array
			my @oids = map {$ifDslamOidSet{$_}} @ifDslamVarList;
			#print Dumper \@oids;

			# get the snmp data from the thing
			$snmpData = $snmp->get(@oids);
			if ( $snmp->error() ) {
				$NG->log->debug("ERROR with SNMP on '$node'; Error: ". $snmp->error());
			}

			# save the data for the ifDslamPort					
			$ifDslamData->{index}      = $eachIfIndex;
			$ifDslamData->{ifIndex}    = $eachIfIndex;
			$ifDslamData->{atmIfIndex} = $atmOffsetIndex;

			if ( $snmpData )
			{
				# now get each of the required vars snmp data into the entry for saving.
				foreach my $var (@ifDslamVarList) {
					my $dataKey = $ifDslamOidSet{$var};
					if ( $snmpData->{$dataKey} ne "" and $snmpData->{$dataKey} !~ /SNMP ERROR/ ) {
						$ifDslamData->{$var} = $snmpData->{$dataKey};
					}
					else {
						$NG->log->debug("ERROR with SNMP on '$node var='$var': ".$snmpData->{$dataKey}) if ($snmpData->{$dataKey} =~ /SNMP ERROR/);
						$ifDslamData->{$var} = "N/A";
					}
					$NG->log->debug5(substr("$var:                                          ",1,41) . "'$ifDslamData->{$var}'");
				}

				$ifDslamData->{ifDescr} = getIfDescr(prefix => "ATM", version => $version, ifIndex => $atmOffsetIndex, asamModel => $asamModel);
				$NG->log->debug5("Interface Description:                   '$ifDslamData->{ifDescr}'");
				$NG->log->debug("DSLAM SNMP Results: ifIndex=$eachIfIndex ifDescr=$ifDslamData->{ifDescr} asamIfExtCustomerId=$ifDslamData->{asamIfExtCustomerId}");

				if ( $intfData->{$eachIfIndex}{ifLastChange} ) { 
					$ifDslamData->{ifLastChange} = NMISNG::Util::convUpTime(int($intfData->{$eachIfIndex}{ifLastChange}/100));
				}
				else {
					$ifDslamData->{ifLastChange} = '0:00:00',
				}
				$NG->log->debug5("Interface Last Change:                   '$ifDslamData->{ifLastChange}'");
				$ifDslamData->{ifOperStatus} = $intfData->{$eachIfIndex}{ifOperStatus} ? $intfData->{$eachIfIndex}{ifOperStatus} : "N/A";
				$ifDslamData->{ifAdminStatus} = $intfData->{$eachIfIndex}{ifAdminStatus} ? $intfData->{$eachIfIndex}{ifAdminStatus} : "N/A";
				$NG->log->debug5("Interface Admin Status:                  '$ifDslamData->{ifAdminStatus}'");
				$NG->log->debug5("Interface Oper Status:                   '$ifDslamData->{ifOperStatus}'");


				# get the Service Profile Name based on the xdslLineServiceProfileNbr
				if ( defined $NI->{xdslLineServiceProfile} and defined $ifDslamData->{xdslLineServiceProfileNbr} ) {
					my $profileNumber = $ifDslamData->{xdslLineServiceProfileNbr};
					$ifDslamData->{xdslLineServiceProfileName}  = $NI->{xdslLineServiceProfile}{$profileNumber}{xdslLineServiceProfileName} ? $NI->{xdslLineServiceProfile}{$profileNumber}{xdslLineServiceProfileName} : "N/A";						
				}
				my $path_keys =  ['index'];
				my $path = $nodeobj->inventory_path( concept => 'DSLAM_Ports', path_keys => $path_keys, data => $ifDslamData );
				my ($inventory, $error) =  $nodeobj->inventory(
					create => 1,				# if not present yet
					concept => "DSLAM_Ports",
					data => $ifDslamData,
					path_keys => $path_keys,
					path => $path );

				if(!$inventory or $error)
				{
					$NG->log->error("Failed to get inventory for DSLAM Port ID: '$eachIfIndex'; Error: $error");
					next;								# not much we can do in this case...
				}
				# The above has added data to the inventory, that we now save.
				$inventory->data( $ifDslamData );
				my ( $op, $subError ) = $inventory->save();
				$NG->log->debug2( "Saved ".join(',', @$path)."; op: $op");
				if ($subError)
				{
					$NG->log->error("Failed to save inventory for DSLAM Port ID: '$eachIfIndex'; Error: $subError");
				}
				else
				{
					$NG->log->debug( "Saved DSLAM Poer ID: '$eachIfIndex'; op: $op");
					$changesweremade = 1;
				}
			}
		}
		else {
			delete $NI->{DSLAM_Ports}->{$eachIfIndex};
		}
	}

#	$NG->log->info("Working on '$node' ifStack");
#
#	my $ifStackData;
#	my $ifStackIds = $S->nmisng_node->get_inventory_ids(
#		concept => "ifStack",
#		filter => { historic => 0 });
#	if (@$ifStackIds)
#	{
#		for my $ifStackId (@$ifStackIds)
#		{
#			my ($ifStackEntry, $error) = $S->nmisng_node->inventory(_id => $ifStackId);
#			if ($error)
#			{
#				$NG->log->error("Failed to get inventory for Interface Stack ID: '$ifStackId'; Error: $error");
#				next;
#			}
#			$ifStackData      = $ifStackEntry->data();
#			my $eachIfIndex      = $ifStackData->{index};
#			my $eachCustomerId   = $ifStackData->{asamIfExtCustomerId};
#			$NG->log->info("Interface Index:        '$eachIfIndex'");
#			$NG->log->info("Customer ID:            '$eachCustomerId'");
#			if (defined $ifStackData->{index} )
#			{
#				if ( my @parts = split(/\./,$ifStackData->{index}) ) {
#					my $ifStackHigherLayer = shift(@parts);
#					my $ifStackLowerLayer  = shift(@parts);
#					$ifStackData->{ifStackHigherLayer} = $ifStackHigherLayer;
#					$ifStackData->{ifStackLowerLayer}  = $ifStackLowerLayer;
#				}
#			}
#		}
#	}
#	for my $eachIfIndex (keys %{$intfData})
#	{
#		my $ifStackHigherLayer;
#		my $ifStackLowerLayer;
#		# get the snmp data from the thing
#		$snmpData = $snmp->gettable("1.3.6.1.2.1.31.1.2.1.3",$max_repetitions);
#		if ( $snmp->error() ) {
#			$NG->log->debug("ERROR with SNMP on '$node'; Error: ". $snmp->error());
#		}
#		foreach my $oid ( Net::SNMP::oid_lex_sort( keys %{$snmpData} ) )
#		{
#			$NG->log->info("OID:                    '$oid'");
#			$NG->log->info("Value:                  '$snmpData->{$oid}'");
#			$ifStackData->{index}         = $oid;
#			$ifStackData->{ifStackStatus} = ifStackStatus($snmpData->{"$oid"});
#			if ( my @parts = split(/\./,substr($oid,23))) {
#				$ifStackHigherLayer                = shift(@parts);
#				$ifStackLowerLayer                 = shift(@parts);
#				$ifStackData->{ifStackHigherLayer} = $ifStackHigherLayer;
#				$ifStackData->{ifStackLowerLayer}  = $ifStackLowerLayer;
#			}
#			if ( defined $intfData->{$ifStackHigherLayer}{ifDescr} ) {
#				$ifStackData->{ifDescrHigherLayer}     = $intfData->{$ifStackHigherLayer}{ifDescr};
#				$ifStackData->{ifDescrHigherLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackHigherLayer&node=$node";
#				$ifStackData->{ifDescrHigherLayer_id}  = "node_view_$node";
#			}
#
#			if ( defined $intfData->{$ifStackLowerLayer}{ifDescr} ) {
#				$ifStackData->{ifDescrLowerLayer}     = $intfData->{$ifStackLowerLayer}{ifDescr};
#				$ifStackData->{ifDescrLowerLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackLowerLayer&node=$node";
#				$ifStackData->{ifDescrLowerLayer_id}  = "node_view_$node";
#			}
#
#			$NG->log->debug("WHAT: ifDescr=$intfData->{$ifStackHigherLayer}{ifDescr} ifStackHigherLayer=$ifStackData->{ifStackHigherLayer} ifStackLowerLayer=$ifStackData->{ifStackLowerLayer} ");
#			my $path_keys =  ['index'];
#			my $path = $nodeobj->inventory_path( concept => 'ifStack', path_keys => $path_keys, data => $ifStackData );
#			my ($inventory, $error) =  $nodeobj->inventory(
#				create => 1,				# if not present yet
#				concept => "ifStack",
#				data => $ifStackData,
#				path_keys => $path_keys,
#				path => $path );
#
#			if(!$inventory or $error)
#			{
#				$NG->log->error("Failed to get inventory for Interface Stack ID: '$eachIfIndex'; Error: $error");
#				next;								# not much we can do in this case...
#			}
#			# The above has added data to the inventory, that we now save.
#			$inventory->data( $ifStackData );
#			my ( $op, $subError ) = $inventory->save();
#			$NG->log->debug2( "Saved ".join(',', @$path)."; op: $op");
#			if ($subError)
#			{
#				$NG->log->error("Failed to save inventory for Interface Stack ID: '$eachIfIndex'; Error: $subError");
#			}
#			else
#			{
#				$NG->log->info( "Saved Stack ID: '$eachIfIndex'; op: $op");
#				$changesweremade = 1;
#			}
#		}
#	}

	return ($changesweremade,undef); # report if we changed anything
}

sub getIfDescr {
	my %args = @_;

	my $oid_value 		= $args{ifIndex};	
	my $prefix			= $args{prefix};	
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

		$NG->log->debug("ASAM getIfDescr: ifIndex=$args{ifIndex} slot=$slot slotCor=$slotCor asamVersion=$args{version} asamModel=$asamModel");

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

		$NG->log->debug("ASAM getIfDescr: ifIndex=$args{ifIndex} slot=$slot $slotCor=$slotCor asamVersion=$args{version} asamModel=$asamModel");

		return "$prefix-$rack-$shelf-$slotCor-$circuit";
	}
	else {
		my $slot_mask 		= 0x7E000000;
		my $level_mask 		= 0x01E00000;	
		my $circuit_mask 	= 0x001FE000;

		my $slot 		= ($oid_value & $slot_mask) 		>> 25;
		my $level 	= ($oid_value & $level_mask) 		>> 21;
		my $circuit = ($oid_value & $circuit_mask) 	>> 13;

		# Apparently this needs to be adjusted when going to decimal?
		if ( $slot > 1 ) {
			--$slot;
		}
		++$circuit;	

		$prefix = "XDSL" if $level == 16;

		my $slotCor = asamSlotCorrection($slot,$asamModel);

		$NG->log->debug("ASAM getIfDescr: ifIndex=$args{ifIndex} slot=$slot slotCor=$slotCor asamVersion=$args{version} asamModel=$asamModel");

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
sub ifStackStatus {
	my $statusNumber = shift;
	
	return 'active' if $statusNumber == 1;
	return 'notInService' if $statusNumber == 2;
	return 'notReady' if $statusNumber == 3;
	return 'createAndGo' if $statusNumber == 4;
	return 'createAndWait' if $statusNumber == 5;
	return 'destroy' if $statusNumber == 6;
	
	# Unrecognized Stack Status
	return 'unknown';
}	

1;
