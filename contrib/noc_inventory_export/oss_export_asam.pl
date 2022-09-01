#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::Sys;
use NMIS::UUID;
use Compat::Timing;
use Data::Dumper;
use Excel::Writer::XLSX;

if ( $ARGV[0] eq "" ) {
	usage();
	exit 1;
}

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set Directory level.
if ( not defined $arg{dir} ) {
	print "ERROR: tell me where to put the files please\n";
	usage();
	exit 1;
}
my $dir = $arg{dir};

# Set Directory level.
my $xlsFile = "oss_export.xlsx";
if ( defined $arg{xls} ) {
	$xlsFile = $arg{xls};
}
$xlsFile = "$arg{dir}/$xlsFile";

#if ( not defined $arg{export} ) {
#	print "ERROR: please tell me to export nodes or logical\n";
#	usage();
#	exit 1;
#}
my $export = $arg{export};

if ( defined $arg{export} and not defined $arg{xls} ) {
	$xlsFile = "oss_export_$export.xlsx";
}

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Step 1: define you prefered seperator
my $sep = "\t";
if ( $arg{separator} eq "tab" ) {
	$sep = "\t";
}
elsif ( $arg{separator} eq "comma" ) {
	$sep = ",";
}

# A cache of Card Indexes.
my $cardIndex;

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 relayRack location uplink);

# Step 4: Define any header aliases you want
my %nodeAlias = (
	name              		=> 'Dslam Name',
	uuid									=> 'Equipment ID',
	ossType								=> 'Type',
	nodeVendor            => 'Name of the Vendor',
	ossModel							=> 'Model',
	sysDescr							=> 'Description of the equipmet',
	softwareVersion				=> 'SW Version',
	ossStatus							=> 'Status',
	serialNum      		    => 'SerialNumber',
	name2              		=> 'Name of the node in the Network',
	name3              		=> 'Name in NMS',
	relayRack							=> 'Relay Rack name',
	location           		=> 'Location',
	uplink								=> 'UpLink',	
	comment								=> 'Comment',	
);

my @slotHeaders = qw(slotId nodeId position slotName slotNetName name1 name2 ossType);

my %slotAlias = (
	slotId								=> 'Slot ID',
	nodeId								=> 'Equipment ID',
	position							=> 'Position in the equipment',
	slotName            	=> 'Slot Name',
	slotNetName						=> 'Slot name in the network',
	name1									=> 'name of the parent equipment',
	name2									=> 'name of the parent eq in the network',
	ossType								=> 'Type of equipment',
);

#										

my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel cardType name1 name2 slotId);

my %cardAlias = (
	cardName							=> 'Card name',
	cardId								=> 'Card ID',
	cardNetName						=> 'name of the card in the network',
	cardDescr        			=> 'Card Description',
	cardSerial       			=> 'Card Serial',
	cardStatus						=> 'Status',
	cardVendor						=> 'Vendor',
	cardModel							=> 'model',
	cardType							=> 'Type',
	name1									=> 'name of the network where the card is installed',
	name2									=> 'name of the equipment where the card is installed',
	slotId								=> 'Parent ID/Slot ID where the card is installed',
);

my @portHeaders = qw(portName portId portType portStatus parent duplex);

my %portAlias = (
	portName         			=> 'Name of the port in the network',
	portId								=> 'Port ID',
	portType							=> 'Type of port',
	portStatus						=> 'Status',
	parent								=> 'parent ID /Card ID',
	duplex								=> 'Duplex full/half',
);

my @asamHeaders = qw(name type index eqptSlotPlannedType eqptSlotActualType eqptBoardAdminStatus eqptBoardOperStatus eqptBoardContainerId eqptBoardContainerOffset eqptBoardInventoryAlcatelCompanyId eqptBoardInventoryTypeName eqptBoardInventoryPBACode eqptBoardInventoryFPBACode eqptBoardInventoryICScode eqptBoardInventoryCLEICode eqptBoardInventorySerialNumber);

my %asamAlias = (
	name																=> 'name',
	type																=> 'type',
	index																=> 'index',
	eqptSlotPlannedType									=> 'Slot Planned Type',
	eqptSlotActualType									=> 'Slot Actual Type',
	eqptBoardAdminStatus								=> 'Board Admin Status',
	eqptBoardOperStatus									=> 'Board Oper Status',
	eqptBoardContainerId								=> 'Board Container ID',
	eqptBoardContainerOffset						=> 'Board Container Offset',
	eqptBoardInventoryAlcatelCompanyId	=> 'Company ID',
	eqptBoardInventoryTypeName					=> 'Type Name',
	eqptBoardInventoryPBACode						=> 'PBA Code',
	eqptBoardInventoryFPBACode					=> 'FPBA Code',
	eqptBoardInventoryICScode						=> 'ICS Code',
	eqptBoardInventoryCLEICode					=> 'CLEI Code',
	eqptBoardInventorySerialNumber			=> 'Serial Number',
);

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

#What vendors are we going to process
my $goodVendors = qr/Alcatel/;

#What models are we going to process
my $goodModels = qr/AlcatelASAM/;

#What cards are we going to ignore
my $badCardDescr = qr/A901-\w+-FT-D Motherboard|Motherboard with Built|Fixed Module 0|^CPU|^cpu|^host|^jacket|^plimasic|Compact Flash|CPUCtrl|DBCtrl|Line Card host|RSP Card host|BIOS|PHY\d|DIMM\d|SSD|SECtrl|PCIeSwitch|X86CPU\d|IOCtrlHub|IOHub/;

#What devices need to get Max message size updated
my $fixMaxMsgSize = qr/cat650.|ciscoWSC65..|cisco61|cisco62|cisco60|cisco76/;


# Step 6: Run the program!

# Step 7: Check the results

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	
	my $xls;
	if ($xlsFile) {
		$xls = start_xlsx(file => $xlsFile);
	}
	
	if ( $export eq "nodes" or $export eq "" ) {
		exportNodes($xls);
		exportSlots($xls);
		exportCards($xls);
		exportAsam($xls);
		exportPorts($xls);
	}
	
	if ( $export eq "logical" or $export eq "" ) {
		exportInventory(xls => $xls, title => "ifTable", section => "ifTable");
		#exportInventory(xls => $xls, title => "ifStack", section => "ifStack");
		exportInventory(xls => $xls, title => "atmVcl", section => "atmVcl");
		exportInventory(xls => $xls, title => "dot1qPvid", section => "dot1qPvid");
		exportInventory(xls => $xls, title => "dot1qVlan", section => "dot1qVlan");
	}

	end_xlsx(xls => $xls);
	print "XLS saved to $xlsFile\n";
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " End\n";


sub exportInventory {
	my (%args) = @_;

	my $xls = $args{xls};

	my $title = "SETME";
	$title = $args{title} if defined $args{title};
	
	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};
	
	print "Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n";
	
	my $sheet;
	my $currow;
	
	print "Creating $title sheet with section $section\n";
	
	my $C = loadConfTable();
				
	# declare some vars for filling in later.
	my $nodes = 0;
	my $records = 0;
	my @invHeaders;
	my %invAlias;
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $MDL = $S->mdl;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;

	  	++$nodes;

			# handling for this is device/model specific.
			my $INV;
						
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{$section} and ref($S->{info}{$section}) eq "HASH") {
					$INV = $S->{info}{$section};
				}
				else {
					print "ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
				if ( not @invHeaders ) {
					# create the aliases from the model data, a few static items are primed
					#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
					#print Dumper $MDL;
					@invHeaders = ('node','parent','location', split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers}));
					
					# set the aliases for the static items
					%invAlias = (
						node       						=> 'NODE_NAME',
						parent       					=> 'NODE_ID',
						location							=> 'LOCALIDAD',
					);
					
					# fill in the aliases for each of the items from the model	
					foreach my $heading (@invHeaders) {
						if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title} ) {
							$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title};
						}
						else {
							$invAlias{$heading} = $heading;
						}
					}

					# create a header
					my @aliases;
					foreach my $header (@invHeaders) {
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						push(@aliases,$alias);
					}

					if ($xls) {
						$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
						$currow = 1;								# header is row 0
					}
					else {
						die "ERROR need an xls to work on.\n";	
					}
				}				
				
				
				foreach my $idx (sort keys %{$INV}) {
					if ( defined $INV->{$idx} ) {						
						++$records;
						$INV->{$idx}{node} = $node;
						$INV->{$idx}{parent} = $NODES->{$node}{uuid};
						$INV->{$idx}{location} = $NODES->{$node}{location};

				    my @columns;
				    foreach my $header (@invHeaders) {
				    	my $data = undef;
				    	if ( defined $INV->{$idx}{$header} ) {
				    		$data = $INV->{$idx}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}

							$data = "N/A" if $data eq "noSuchInstance";
							
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
			  	}
				}
			}
	  }
	}
	print "Processed $nodes nodes with $records $section records\n";
}



sub exportNodes {
	my $xls = shift;
	my $title = "Nodes";
	my $sheet;
	my $currow;

	print "Creating Node Data\n";

	my $C = loadConfTable();
		
	my @aliases;
	foreach my $header (@nodeHeaders) {
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true") {
	  	my @comments;
	  	my $comment;
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/ or $NI->{system}{nodeVendor} !~ /$goodVendors/;
			
			# is there a decent serial number!
			
			# NOPE

			# get software version for Alcatel ASAM      
      if ( defined $NI->{system}{asamActiveSoftware1} and $NI->{system}{asamActiveSoftware1} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion1};
			}
      elsif ( defined $NI->{system}{asamActiveSoftware2} and $NI->{system}{asamActiveSoftware2} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion2};
			}
						
			# Get an uplink address, find any address and put it in a string
			my $IF = $S->ifinfo;
			my @ipAddresses;
			foreach my $ifIndex (sort keys %{$IF}) {
				my @addresses;
				if ( defined $IF->{$ifIndex} and defined $IF->{$ifIndex}{ipAdEntAddr1} ) {
					push(@ipAddresses,$IF->{$ifIndex}{ipAdEntAddr1});
				}			
				if ( defined $IF->{$ifIndex} and defined $IF->{$ifIndex}{ipAdEntAddr2} ) {
					push(@ipAddresses,$IF->{$ifIndex}{ipAdEntAddr2});
				}	
			}
			if ( @ipAddresses ) {
				my $joinChar = $sep eq "," ? " " : ",";
				$NODES->{$node}{uplink} = join($joinChar,@ipAddresses);
			}
			
			#my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 tbd4 group tbd5);
		    
		  # clone the name!
	    $NODES->{$node}{name2} = $NODES->{$node}{name};
	    $NODES->{$node}{name3} = $NODES->{$node}{name};
	    
	    # handling OSS values for these fields.
	    $NODES->{$node}{ossStatus} = $NI->{system}{nodestatus};
	    $NODES->{$node}{ossModel} = getModel($NI->{system}{sysObjectName});
	    $NODES->{$node}{ossType} = getType($NI->{system}{sysObjectName},$NI->{system}{nodeType});

	    #$NODES->{$node}{comment} = join($joinChar,@comments);

	    if ( not defined $NODES->{$node}{relayRack} or $NODES->{$node}{relayRack} eq "" ) {
	    	$NODES->{$node}{relayRack} = "No Relay Rack Configured";
	    }

	    if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
	    	$NODES->{$node}{location} = "No Location Configured";
	    }
	    		    
	    my @columns;
	    foreach my $header (@nodeHeaders) {
	    	my $data = undef;
	    	if ( defined $NODES->{$node}{$header} ) {
	    		$data = $NODES->{$node}{$header};
	    	}
	    	elsif ( defined $NI->{system}{$header} ) {
	    		$data = $NI->{system}{$header};	    		
	    	}
	    	else {
	    		$data = "TBD";
	    	}
	    	$data = changeCellSep($data);
	    	push(@columns,$data);
	    }
			my $row = join($sep,@columns);

			if ($sheet) {
				$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
				++$currow;
			}
	  }
	}
}

sub exportSlots {
	my $xls = shift;
	my $title = "Slots";
	my $sheet;
	my $currow;
	
	print "Creating Slots Data\n";

	my $C = loadConfTable();
			
	my @aliases;
	foreach my $header (@slotHeaders) {
		my $alias = $header;
		$alias = $slotAlias{$header} if $slotAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;

			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/ or $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $SLOTS;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{eqptHolder} and ref($S->{info}{eqptHolder}) eq "HASH") {
					$SLOTS = $S->{info}{eqptHolder};
				}
				else {
					print "ERROR: $node no eqptHolder MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				
				my $slotStatus = $S->{info}{eqptHolderStatus};

      #"16" : {
      #   "eqptHolderContainerId" : 1,
      #   "index" : "16",
      #   "eqptHolderActualType" : "ALTR-A",
      #   "eqptHolderIndex" : 1,
      #   "eqptHolderPlannedType" : "ALTR-A"
      #},
   #"eqptHolderStatus" : {
   #   "35" : {
   #      "eqptHolderContainerId" : 32,
   #      "eqptHolderOperStatus" : "disabled",
   #      "index" : "35",
   #      "eqptHolderActualType" : "EMPTY",
   #      "eqptHolderAdminStatus" : "unlock"
   #   },

				foreach my $slotIndex (sort keys %{$SLOTS}) {
					if ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{eqptHolderIndex} 
					) {
						# create a name
						
						# Slot ID's are a pain............
						# Option 1: the slot id is the parent relative position, not the index of the MIB
						# con: some chassis this creates duplicate slot id's
						#my $slotId = $SLOTS->{$slotIndex}{entPhysicalParentRelPos};
						
						# Option 2: the slot id is the entityMib Index, which creates completely Unique id's
						my $slotId = $SLOTS->{$slotIndex}{index};
						
						
						$SLOTS->{$slotIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
						$SLOTS->{$slotIndex}{nodeId} = $NODES->{$node}{uuid};
						$SLOTS->{$slotIndex}{position} = $slotIndex;
						
						# assign the default values here.
						my $slotName = $SLOTS->{$slotIndex}{eqptHolderActualType};
						my $slotNetName = $SLOTS->{$slotIndex}{eqptHolderActualType};
						
						# different models of Cisco use different methods.........
						# so if the slot name is empty or just a number make one up, 
						if ( $slotName eq "EMPTY" ) {
							$slotName = "$slotId";
						}
						
						$SLOTS->{$slotIndex}{slotName} = $slotName;
						$SLOTS->{$slotIndex}{slotNetName} = $slotNetName;
										    
				    # name for the parent node.
				    $SLOTS->{$slotIndex}{name1} = $NODES->{$node}{name};
				    $SLOTS->{$slotIndex}{name2} = $NODES->{$node}{name};
				    $SLOTS->{$slotIndex}{ossType} = getType($NI->{system}{sysObjectName},$NI->{system}{nodeType});
						
				    my @columns;
				    foreach my $header (@slotHeaders) {
				    	my $data = undef;
				    	if ( defined $SLOTS->{$slotIndex}{$header} ) {
				    		$data = $SLOTS->{$slotIndex}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
			  	}
				}
			}
	  }
	}	
}

sub exportCards {
	my $xls = shift;
	my $title = "Cards";
	my $sheet;
	my $currow;
	
	print "Creating Card Data\n";

	my $C = loadConfTable();
			
	my @aliases;
	foreach my $header (@cardHeaders) {
		my $alias = $header;
		$alias = $cardAlias{$header} if $cardAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	
	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/ or $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $SLOTS;
			my $BOARD;
			my $cardCount = 0;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{eqptHolderList} and ref($S->{info}{eqptHolderList}) eq "HASH") {
					$SLOTS = $S->{info}{eqptHolderList};
				}
				else {
					print "ERROR: $node no eqptHolderList MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				if ( defined $S->{info}{eqptBoard} and ref($S->{info}{eqptBoard}) eq "HASH") {
					$BOARD = $S->{info}{eqptBoard};
				}
				else {
					print "ERROR: $node no eqptBoard MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				
#   "eqptBoard" : {
#      "8448" : {
#         "eqptSlotPlannedType" : "SATU-A",
#         "eqptBoardOperStatus" : "enabled",
#         "eqptBoardContainerId" : 33,
#         "eqptBoardContainerOffset" : 0,
#         "index" : "8448",
#         "eqptBoardAdminStatus" : "unlock",
#         "eqptBoardInventoryTypeName" : "SATU-A",
#         "eqptSlotActualType" : "SATU-A",
#         "eqptBoardInventorySerialNumber" : "CB48J664"
#      },
      
				foreach my $boardIndex (sort keys %{$BOARD}) {
					if ( defined $BOARD->{$boardIndex} 
						and defined $BOARD->{$boardIndex}{eqptBoardInventoryTypeName} 
						and $BOARD->{$boardIndex}{eqptBoardInventoryTypeName} ne ""
					) {
						# create a name
						++$cardCount;
						#my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel       cardType name1 name2 slotId);

						my $cardId = "$NODES->{$node}{uuid}_C_$boardIndex";

						if ( defined $BOARD->{$boardIndex} 
							and $BOARD->{$boardIndex}{eqptBoardInventorySerialNumber} ne "" 
						) {
							$BOARD->{$boardIndex}{cardSerial} = $BOARD->{$boardIndex}{eqptBoardInventorySerialNumber};
						}
						elsif ( $BOARD->{$boardIndex}{eqptSlotPlannedType} !~ /(NOT_ALLOWED|NOT_PLANNED)/ ) {
							# its ok, don't bother me.
						}
						else {
							my $comment = "ERROR: $node no CARD serial number for id $boardIndex $BOARD->{$boardIndex}{eqptSlotPlannedType}";
							print "$comment\n";
						}				
						
						if ( $BOARD->{$boardIndex}{eqptBoardInventoryTypeName} ne "" and $BOARD->{$boardIndex}{eqptBoardInventoryTypeName} !~ /^d+$/ ) {
							$BOARD->{$boardIndex}{cardName} = $BOARD->{$boardIndex}{eqptBoardInventoryTypeName};
						}
						
						$BOARD->{$boardIndex}{cardId} = $cardId;
						
				    $BOARD->{$boardIndex}{cardNetName} = "CARD $boardIndex";

				    $BOARD->{$boardIndex}{cardDescr} = $BOARD->{$boardIndex}{eqptBoardInventoryTypeName};
				    
				    $BOARD->{$boardIndex}{cardStatus} = $BOARD->{$boardIndex}{eqptBoardOperStatus};
						$BOARD->{$boardIndex}{cardVendor} = $NI->{system}{nodeVendor};

						if ( defined $BOARD->{$boardIndex} and $BOARD->{$boardIndex}{eqptBoardInventoryTypeName} ne "" ) {
							$BOARD->{$boardIndex}{cardModel} = $BOARD->{$boardIndex}{eqptBoardInventoryTypeName};
						}

				    # name for the parent node.				    
				    $BOARD->{$boardIndex}{name1} = $NODES->{$node}{name};
				    $BOARD->{$boardIndex}{name2} = $NODES->{$node}{name};

				    my $slotId = $BOARD->{$boardIndex}{eqptBoardContainerId};
				    $BOARD->{$boardIndex}{cardType} = $SLOTS->{$slotId}{eqptHolderActualType};												
						$BOARD->{$boardIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
				    
				    # get the parent and then determine its ID and 
						
				    my @columns;
				    foreach my $header (@cardHeaders) {
				    	my $data = undef;
				    	if ( defined $BOARD->{$boardIndex}{$header} ) {
				    		$data = $BOARD->{$boardIndex}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}

			  	}
				}
			}
	  }
	}	
}

sub exportAsam {
	my $xls = shift;
	my $title = "ASAM";
	my $sheet;
	my $currow;
	
	print "Creating ASAM Data\n";

	my $C = loadConfTable();
		
	my @aliases;
	foreach my $header (@asamHeaders) {
		my $alias = $header;
		$alias = $asamAlias{$header} if $asamAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	
	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/ or $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $SLOTS;
			my $BOARD;
			my $cardCount = 0;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{eqptHolderList} and ref($S->{info}{eqptHolderList}) eq "HASH") {
					$SLOTS = $S->{info}{eqptHolderList};
				}
				else {
					print "ERROR: $node no eqptHolderList MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				if ( defined $S->{info}{eqptBoard} and ref($S->{info}{eqptBoard}) eq "HASH") {
					$BOARD = $S->{info}{eqptBoard};
				}
				else {
					print "ERROR: $node no eqptBoard MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $boardIndex (sort keys %{$BOARD}) {
					if ( defined $BOARD->{$boardIndex} 
						and defined $BOARD->{$boardIndex}{eqptSlotPlannedType} 
						and $BOARD->{$boardIndex}{eqptSlotPlannedType} ne ""
					) {
						++$cardCount;

						# get the node name
				    $BOARD->{$boardIndex}{name} = $NODES->{$node}{name};
				    
						# get the name of the container as the type.
				    my $slotId = $BOARD->{$boardIndex}{eqptBoardContainerId};
				    $BOARD->{$boardIndex}{type} = $SLOTS->{$slotId}{eqptHolderActualType};
				    
				    # get the parent and then determine its ID and 
						
				    my @columns;
				    foreach my $header (@asamHeaders) {
				    	my $data = undef;
				    	if ( defined $BOARD->{$boardIndex}{$header} ) {
				    		$data = $BOARD->{$boardIndex}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}

			  	}
				}
			}
	  }
	}	
}

sub exportPorts {
	my $xls = shift;
	my $title = "Ports";
	my $sheet;
	my $currow;
	
	print "Creating Ports Data\n";

	my $C = loadConfTable();
		
	my @aliases;
	foreach my $header (@portHeaders) {
		my $alias = $header;
		$alias = $portAlias{$header} if $portAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			
			next if $NI->{system}{nodeModel} !~ /$goodModels/ and $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $PORTS;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{eqptPortMapping} and ref($S->{info}{eqptPortMapping}) eq "HASH") {
					$PORTS = $S->{info}{eqptPortMapping};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $portIndex (sort keys %{$PORTS}) {
					if ( defined $PORTS->{$portIndex} 
						and defined $PORTS->{$portIndex}{eqptPortMappingPhyPortNbr} 
					) {
						my $portStatus = getStatus();
						my $portId = $portIndex;
						my $portName = "$PORTS->{$portIndex}{eqptPortMappingLogPortType}-$portIndex";

						# what is the parent ID?
						my $parentId;
						
						if ( $PORTS->{$portIndex}{eqptPortMappingPhyPortSlot} != 65535 ) {
							$parentId = $PORTS->{$portIndex}{eqptPortMappingPhyPortSlot};	
						}
						elsif ( $PORTS->{$portIndex}{eqptPortMappingLSMSlot} != 65535 ) {
							$parentId = $PORTS->{$portIndex}{eqptPortMappingLSMSlot};	
						}
						else {
							# it isn't logical or physical, it must not exist!
							next();
						}						
						my $cardId = "$NODES->{$node}{uuid}_C_$parentId";

						#my @portHeaders = qw(portName portId portType portStatus parent duplex);
						
						# Port ID is the Card ID and an index, relative position.
						$PORTS->{$portIndex}{portName} = $portName;
						$PORTS->{$portIndex}{portId} = "$NODES->{$node}{uuid}_P_$portId";
						$PORTS->{$portIndex}{portType} = $PORTS->{$portIndex}{eqptPortMappingLogPortType};
						$PORTS->{$portIndex}{portStatus} = $portStatus;
						$PORTS->{$portIndex}{parent} = $cardId;
						$PORTS->{$portIndex}{duplex} = "N/A";
						
				    my @columns;
				    foreach my $header (@portHeaders) {
				    	my $data = undef;
				    	if ( defined $PORTS->{$portIndex}{$header} ) {
				    		$data = $PORTS->{$portIndex}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
			  	}
				}
			}
	  }
	}	
}


sub changeCellSep {
	my $string = shift;
	$string =~ s/$sep/;/g;
	$string =~ s/\r\n/\\n/g;
	$string =~ s/\n/\\n/g;
	return $string;
}

sub getStatus {
	# no definitions found?
	return "Installed";		
}

sub getModel {
	my $sysObjectName = shift;
	
	$sysObjectName =~ s/cisco/Cisco /g;
	if ( $sysObjectName =~ /cat(\d+)/ ) {
		$sysObjectName = "Cisco Catalyst $1";	
	}
	
	return $sysObjectName;		
}

sub getType {
	my $sysObjectName = shift;
	my $nodeType = shift;
	my $type = "TBD";
	
	if ( $sysObjectName =~ /cisco61|cisco62|cisco60|asam/ ) {
		$type = "DSLAM";	
	}
	elsif ( $nodeType =~ /router/ ) {
		$type = "Router";	
	}
	elsif ( $nodeType =~ /switch/ ) {
		$type = "Switch";	
	}
	
	return $type;		
}

sub getPortDuplex {
	my $thing = shift;
	my $duplex = "TBD";
	
	if ( $thing =~ /SHDSL|ADSL/ ) {
		$duplex = "N/A";	
	}
	
	return $duplex;		
}

sub getCardName {
	my $model = shift;
	my $name;
	
	if ( $model =~ /^.TUC/ ) {
		$name = "xDSL Card";	
	}
	elsif ( $model =~ /^NI\-|C6... Network/ ) {
		$name = "Network Intfc  (WRK)";
	}
	elsif ( $model ne "" ) {
		$name = $model;
	}
	
	return $name;		
}

sub usage {
	print <<EO_TEXT;
$0 will export nodes and ports from NMIS.
ERROR: need some files to work with
usage: $0 dir=<directory>
eg: $0 dir=/data debug=true export=(nodes|logical)

EO_TEXT
}


sub start_xlsx
{
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
		$xls->set_optimization();
		die "Cannot create XLSX file ".$args{file}.": $!\n" if (!$xls);
	}
	else {
		die "ERROR need a file to work on.\n";	
	}
	return ($xls);
}

sub add_worksheet
{
	my (%args) = @_;
	
	my $xls = $args{xls};

	my $sheet;
	if ($xls)
	{
		my $shorttitle = $args{title};
		$shorttitle =~ s/[^a-zA-Z0-9 _\.-]+//g; # remove forbidden characters
		$shorttitle = substr($shorttitle, 0, 31); # xlsx cannot do sheet titles > 31 chars
		$sheet = $xls->add_worksheet($shorttitle);

		if (ref($args{columns}) eq "ARRAY")
		{
			my $format = $xls->add_format();
			$format->set_bold(); $format->set_color('blue');

			for my $col (0..$#{$args{columns}})
			{
				$sheet->write(0, $col, $args{columns}->[$col], $format);
			}
		}
	}
	return ($xls, $sheet);
}

# closes the spreadsheet, returns 1 if ok.
sub end_xlsx
{
	my (%args) = @_;

	my $xls = $args{xls};

	if ($xls)
	{
		return $xls->close;
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
	return 1;
}

