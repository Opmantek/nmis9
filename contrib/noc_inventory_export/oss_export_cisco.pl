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
my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 relayRack location uplink comment);

# Step 4: Define any CSV header aliases you want
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

my @intHeaders = qw(name ifDescr ifType ifOperStatus parent);

my %intAlias = (
	name            			=> 'Name of the port in the network',
	ifDescr								=> 'Port ID',
	ifType								=> 'Type of port',
	ifOperStatus					=> 'Status',
	parent								=> 'parent ID /Card ID',
);

##### SYSTEM INTENTIONALLY NOT SHOWING TRANSCEIVER DETAILS!

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

#What vendors are we going to process
my $goodVendors = qr/Cisco/;

#What models are we going to process
my $goodModels = qr/CiscoDSL/;

#What slots do we want to ignore
my $badSlotDescr = qr/port container|Port Container|Ethernet.+Container|CE container|CFP container|SFP container|CFP Container|SFP Container|Port Slot|Transceiver|transceiver|Clock FRU|Container of Clock|Container of VTT|VTT-E FRU|VTT FRU|SFP Container|Flash Card/;
#Gigabit Port Container, SFP port container, GBIC port container

#What cards are we going to ignore
my $badCardDescr = qr/Gi SFP|^SFP$|^XFP$|ZX SFP|LX SFP|GE LX|GE ZX|GE T|Transceiver|transceiver|Clock FRU|VTT FRU|VTT\-E FRU|A901-\w+-FT-D Motherboard|Motherboard with Built|Fixed Module 0|^CPU|^cpu|^host|^jacket|^plimasic|Compact Flash|Flash Card|CPUCtrl|DBCtrl|Line Card host|RSP Card host|BIOS|PHY\d|DIMM\d|SSD|SECtrl|PCIeSwitch|X86CPU\d|IOCtrlHub|IOHub|Timing over Packet [mM]odule|Cisco MWR-2941-DC Motherboard|Modular Linecard Daughter board|Gigabit Ethernet Daughter board|BITS Interface Module|GBIC TYPE \w+|1000BaseLX/;
my $badCardModel = qr/7600\-ES\+|SPA\-1CHOC3\-CE\-ATM|SFP\-OC3\-.R|SFP\-GE\-.|SFP\-10G\-.R|SFP\-1000BX\-10\-|XFP\-10G.R\-OC192.R|XFP\-10G.R\-192.R|XFP10G.R\-192.R\-L|SFP\-OC..-IR|SFP\-OC..\-SR|CFP\-100G\-.R|GLC\-BX\-.|GLC\-LX\-.|GBIC TYPE .X/;
my $badCardPhysName = qr/subslot.+transceiver|fan-tray|fan \d+/;
#XFP-10GLR-OC192SR   XFP-10GER-OC192IR   XFP-10GZR-OC192LR   XFP-10GER-192IR+    XFP10GLR-192SR-L  


#What devices need to get Max message size updated
my $fixMaxMsgSize = qr/cat650.|ciscoWSC65..|cisco61|cisco62|cisco60|cisco76/;

# Step 6: Run the program!

# Step 7: Check the results

my $SLOT_INDEX;

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	
	nodeCheck();

	my $xls;
	if ($xlsFile) {
		$xls = start_xlsx(file => $xlsFile);
	}
	
	exportNodes($xls,"$dir/oss-nodes.csv");
	exportInventory(xls => $xls, title => "EntityData", section => "entityMib");
	exportSlots($xls,"$dir/oss-slots.csv");
	exportCards($xls,"$dir/oss-cards.csv");
	exportPorts($xls,"$dir/oss-ports.csv");
	#exportInterfaces($xls,"$dir/oss-interfaces.csv");

	end_xlsx(xls => $xls);
	print "XLS saved to $xlsFile\n";
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " End\n";


sub exportNodes {
	my $xls = shift;
	my $file = shift;
	my $title = "Nodes";
	my $sheet;
	my $currow;

	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@nodeHeaders) {
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

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

	    my $nodestatus = $NI->{system}{nodestatus};
	    $nodestatus = "unreachable" if $NI->{system}{nodedown} eq "true";
			
			# move on if this isn't a good one.
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;
			
			# check for data prerequisites
			if ( $NI->{system}{nodeVendor} =~ /Cisco/ and not defined $S->{info}{entityMib} and $nodestatus eq "reachable" ) {
				$comment = "ERROR: $node is Cisco and entityMib data missing";
				print "$comment\n";
				push(@comments,$comment);
			}

			# is there a decent serial number!
			if ( not defined $NI->{system}{serialNum} or $NI->{system}{serialNum} eq "" or $NI->{system}{serialNum} eq "noSuchObject" ) {
				my $SLOTS = undef;					
				my $ASSET = undef;

				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}

				if ( defined $S->{info}{ciscoAsset} and ref($S->{info}{ciscoAsset}) eq "HASH") {
					$ASSET = $S->{info}{ciscoAsset};
				}
				
				# lets just see if we can find one!
				# this logic works well for Nexus devices which are 149
				foreach my $slotIndex (sort keys %{$SLOTS}) {
					if ( defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /chassis/
						and $SLOTS->{$slotIndex}{entPhysicalSerialNum} ne ""
					) {
						$NI->{system}{serialNum} = $SLOTS->{$slotIndex}{entPhysicalSerialNum};
						print "INFO: Found a Serial Number at EntityMIB index $slotIndex: $NODES->{$node}{name}\n" if $debug;
					}
				}				
				
				# just use the specific index thing for serial number.
				if ( defined $SLOTS->{1} and $SLOTS->{1}{entPhysicalSerialNum} ne "" ) {
					$NI->{system}{serialNum} = $SLOTS->{1}{entPhysicalSerialNum};
				}
				# this works for ME3800
				elsif ( defined $SLOTS->{1001} and $SLOTS->{1001}{entPhysicalSerialNum} ne "" ) {
					$NI->{system}{serialNum} = $SLOTS->{1001}{entPhysicalSerialNum};
				}
				# this works for IOSXR, CRS, ASR9K
				elsif ( defined $SLOTS->{24555730} and $SLOTS->{24555730}{entPhysicalSerialNum} ne "" ) {
					$NI->{system}{serialNum} = $SLOTS->{24555730}{entPhysicalSerialNum};
				}
				# Cisco 61xx DSLAM's
				elsif ( defined $ASSET->{1} and $ASSET->{1}{ceAssetSerialNumber} ne "" ) {
					$NI->{system}{serialNum} = $ASSET->{1}{ceAssetSerialNumber};
				}
				
				if ( $NI->{system}{serialNum} eq "" ) {
					$NI->{system}{serialNum} = "TBD";
					$comment = "ERROR: $node no serial number not in chassisId entityMib or ciscoAsset";
					print "$comment\n";
					push(@comments,$comment);
				}
				
				## quadruple enrichment!

				# is this a CRS with two rack chassis stuff.
				if ( defined $SLOTS->{24555730} and $SLOTS->{24555730}{entPhysicalSerialNum} ne "" 
					and defined $SLOTS->{141995845} and $SLOTS->{141995845}{entPhysicalSerialNum} ne "" 
				) {
					my $chassis1Name = $SLOTS->{24555730}{entPhysicalName};
					my $chassis1Serial = $SLOTS->{24555730}{entPhysicalSerialNum};
					my $chassis2Name = $SLOTS->{141995845}{entPhysicalName};
					my $chassis2Serial = $SLOTS->{141995845}{entPhysicalSerialNum};
					
					$NI->{system}{serialNum} = "$chassis1Name $chassis1Serial; $chassis2Name $chassis2Serial";
				}	
					# is this a CRS with ONE rack chassis stuff.
				elsif ( defined $SLOTS->{24555730} 
					and $SLOTS->{24555730}{entPhysicalSerialNum} ne "" 
					and $SLOTS->{24555730}{entPhysicalName} =~ /Rack/
				) {
					my $chassis1Name = $SLOTS->{24555730}{entPhysicalName};
					my $chassis1Serial = $SLOTS->{24555730}{entPhysicalSerialNum};
					
					$NI->{system}{serialNum} = "$chassis1Name $chassis1Serial";
				}	
			}

			# get software version for Alcatel ASAM      
      if ( defined $NI->{system}{asamActiveSoftware1} and $NI->{system}{asamActiveSoftware1} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion1};
			}
      elsif ( defined $NI->{system}{asamActiveSoftware2} and $NI->{system}{asamActiveSoftware2} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion2};
			}

			# not got anything useful, try and parse it out of the sysDescr.
			if ( not defined $NI->{system}{softwareVersion} or $NI->{system}{softwareVersion} eq "" ) {
				$NI->{system}{softwareVersion} = getVersion($NI->{system}{sysDescr});
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
			my $joinChar = $sep eq "," ? " " : ",";
			$NODES->{$node}{uplink} = join($joinChar,@ipAddresses);

			#my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 tbd4 group tbd5);
		    
		  # clone the name!
	    $NODES->{$node}{name2} = $NODES->{$node}{name};
	    $NODES->{$node}{name3} = $NODES->{$node}{name};
	    
	    # handling OSS values for these fields.
	    $NODES->{$node}{ossStatus} = $nodestatus;
	    $NODES->{$node}{ossModel} = getModel($NI->{system}{sysObjectName});
	    $NODES->{$node}{ossType} = getType($NI->{system}{sysObjectName},$NI->{system}{nodeType});

	    $NODES->{$node}{comment} = join($joinChar,@comments);

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
	    print CSV "$row\n";

			if ($sheet) {
				$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
				++$currow;
			}
	  }
	}
	
	close CSV;
}


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
	my @invHeaders;
	my %invAlias;
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $MDL = $S->mdl;

			# handling for this is device/model specific.
			my $INV;
						
			if ( defined $S->{info}{$section} and ref($S->{info}{$section}) eq "HASH") {
				$INV = $S->{info}{$section};
			}
			else {
				print "ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n" if $debug;
				next;
			}

			# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
			if ( not @invHeaders ) {
				# create the aliases from the model data, a few static items are primed
				#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
				#print Dumper $MDL;
				@invHeaders = ('node','parent','location', split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers}));
				
				if ( not exists $MDL->{$model_section_top}{sys}{$model_section}{headers} or $MDL->{$model_section_top}{sys}{$model_section}{headers} eq "" ) {
					print "ERROR: $node no header defined in the model data for $section\n";				
				}
				
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
					$INV->{$idx}{node} = $node;
					$INV->{$idx}{parent} = $NODES->{$node}{uuid};
					$INV->{$idx}{location} = $NODES->{$node}{location};
					
					if ( $section eq "entityMib" and $INV->{$idx}{entPhysicalClass} eq "sensor" ) {
						next;
					}

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


sub exportSlots {
	my $xls = shift;
	my $file = shift;
	my $title = "Slots";
	my $sheet;
	my $currow;
	
	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@slotHeaders) {
		my $alias = $header;
		$alias = $slotAlias{$header} if $slotAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

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
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $SLOTS;
			my $counter = 0;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $slotIndex (sort keys %{$SLOTS}) {
					
					my $thisIsASlot = 0;
					if ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /container/
						and $SLOTS->{$slotIndex}{entPhysicalDescr} !~ /$badSlotDescr/i
					) {
						$thisIsASlot = 1;
					}
					# special case for 7200VXR Chassis which is also a slot......
					elsif ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /chassis/
						and $SLOTS->{$slotIndex}{entPhysicalDescr} =~ /7204VXR chassis|7206VXR chassis/i
					) {
						$thisIsASlot = 1;
					}
					
					if ( $thisIsASlot ) {
						# create a name
						++$counter;
						
						# Slot ID's are a pain............
						# Option 1: the slot id is the parent relative position, not the index of the MIB
						# con: some chassis this creates duplicate slot id's
						#my $slotId = $SLOTS->{$slotIndex}{entPhysicalParentRelPos};
						
						# Option 2: the slot id is the entityMib Index, which creates completely Unique id's
						my $slotId = $SLOTS->{$slotIndex}{index};
						
						
						$SLOTS->{$slotIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
						$SLOTS->{$slotIndex}{nodeId} = $NODES->{$node}{uuid};
						$SLOTS->{$slotIndex}{position} = $SLOTS->{$slotIndex}{entPhysicalParentRelPos};
						
						# create an entry in the SLOT_INDEX
						if ( not defined $SLOT_INDEX->{$SLOTS->{$slotIndex}{slotId}} ) {
							$SLOT_INDEX->{$SLOTS->{$slotIndex}{slotId}} = $NODES->{$node}{name};
						}
						else {
							print "ERROR: Duplicate SLOT ID: $SLOTS->{$slotIndex}{slotId}\n";
						}
						
						# assign the default values here.
						my $slotName = $SLOTS->{$slotIndex}{entPhysicalName};
						my $slotNetName = $SLOTS->{$slotIndex}{entPhysicalDescr};
						
						# different models of Cisco use different methods.........
						# so if the slot name is empty or just a number make one up, 
						if ( $SLOTS->{$slotIndex}{entPhysicalName} eq "" or $SLOTS->{$slotIndex}{entPhysicalName} =~ /^\d+$/ ) {
							$slotName = "$SLOTS->{$slotIndex}{entPhysicalDescr} $slotId";
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
				    print CSV "$row\n";

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
	my $file = shift;
	my $title = "Cards";
	my $sheet;
	my $currow;
	
	print "Creating $file\n";

	my $C = loadConfTable();

	my $vendorOids = loadVendorOids();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@cardHeaders) {
		my $alias = $header;
		$alias = $cardAlias{$header} if $cardAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	
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
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $CARDS;
			my $ASSET;
			my $cardCount = 0;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$CARDS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				
				if ( defined $S->{info}{ciscoAsset} and ref($S->{info}{ciscoAsset}) eq "HASH") {
					$ASSET = $S->{info}{ciscoAsset};
				}

				foreach my $cardIndex (sort keys %{$CARDS}) {
					# what is the parent ID?
					# $parentId is the id of the slot the module is inserted into.
					my $parentId = $CARDS->{$cardIndex}{entPhysicalContainedIn};

					if ( $CARDS->{$parentId}{entPhysicalClass} =~ /module/ ) {
						print "INFO: Card Parent is Module: $NODES->{$node}{name} $cardIndex $CARDS->{$cardIndex}{entPhysicalDescr} parent $parentId\n" if $debug > 2;
					}
						
					if ( defined $CARDS->{$cardIndex} 
						and defined $CARDS->{$cardIndex}{entPhysicalClass} 
						and $CARDS->{$cardIndex}{entPhysicalClass} =~ /module/
						and $CARDS->{$cardIndex}{entPhysicalDescr} !~ /$badCardDescr/
						and $CARDS->{$cardIndex}{entPhysicalModelName} !~ /$badCardModel/
						and $CARDS->{$cardIndex}{entPhysicalName} !~ /$badCardPhysName/
						and $CARDS->{$cardIndex}{entPhysicalDescr} ne ""
						# the module must be a sub module not an actuall card
						and $CARDS->{$parentId}{entPhysicalClass} !~ /module/						
					) {
						
						# create a name
						++$cardCount;
						#my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel       cardType name1 name2 slotId);
						
						# is the modules parent another module, then we probably don't want it
						my $cardId = "$NODES->{$node}{uuid}_C_$cardIndex";

						if ( defined $CARDS->{$cardIndex} and $CARDS->{$cardIndex}{entPhysicalSerialNum} ne "" ) {
							$CARDS->{$cardIndex}{cardSerial} = $CARDS->{$cardIndex}{entPhysicalSerialNum};
						}
						elsif ( defined $ASSET->{$cardIndex} and $ASSET->{$cardIndex}{ceAssetSerialNumber} ne "" ) {
							$CARDS->{$cardIndex}{cardSerial} = $ASSET->{$cardIndex}{ceAssetSerialNumber};
						}
						else {
							my $comment = "ERROR: $node no CARD serial number for id $cardIndex $CARDS->{$cardIndex}{entPhysicalDescr}";
							print "$comment\n";
						}				
						
						$CARDS->{$cardIndex}{cardId} = $cardId;
						
				    $CARDS->{$cardIndex}{cardNetName} = "CARD $cardIndex";

				    $CARDS->{$cardIndex}{cardDescr} = $CARDS->{$cardIndex}{entPhysicalDescr};
				    
				    $CARDS->{$cardIndex}{cardStatus} = getStatus();
						$CARDS->{$cardIndex}{cardVendor} = $NI->{system}{nodeVendor};

						if ( defined $ASSET->{$cardIndex} and $ASSET->{$cardIndex}{ceAssetOrderablePartNumber} ne "" ) {
							$CARDS->{$cardIndex}{cardModel} = $ASSET->{$cardIndex}{ceAssetOrderablePartNumber};
						}
						elsif ( defined $CARDS->{$cardIndex} and $CARDS->{$cardIndex}{entPhysicalModelName} ne "" ) {
							$CARDS->{$cardIndex}{cardModel} = $CARDS->{$cardIndex}{entPhysicalModelName};
						}
						else {
							$CARDS->{$cardIndex}{cardModel} = $CARDS->{$cardIndex}{entPhysicalDescr};
						}
										    
						if ( defined $CARDS->{$cardIndex}{entPhysicalVendorType} and $vendorOids->{$CARDS->{$cardIndex}{entPhysicalVendorType}} ne "" ) {
							$CARDS->{$cardIndex}{cardType} = $vendorOids->{$CARDS->{$cardIndex}{entPhysicalVendorType}};
							$CARDS->{$cardIndex}{cardType} =~ s/^cev//;
						}
						else {
				    	$CARDS->{$cardIndex}{cardType} = "CARD - ". getType($NI->{system}{sysObjectName},$NI->{system}{nodeType});
				    }
				    
				    # clean up trailing spaces from cardModel.
				    $CARDS->{$cardIndex}{cardModel} =~ s/\s+$//;
				    $CARDS->{$cardIndex}{cardSerial} =~ s/\s+$//;
						
				    # name for the parent node.				    
				    $CARDS->{$cardIndex}{name1} = $NODES->{$node}{name};
				    $CARDS->{$cardIndex}{name2} = $NODES->{$node}{name};
						
						# now we want the relative slot number the slot uses

						# Option 1: the slot id is the parent relative position, not the index of the MIB
						# con: some chassis this creates duplicate slot id's
						#my $slotId = $CARDS->{$parentId}{entPhysicalParentRelPos};
						
						# Option 2: the slot id is the entityMib Index, which creates completely Unique id's
						my $slotId = $CARDS->{$parentId}{index};
						
						# Cisco is using position -1 for the chassis???????
						if ( $slotId < 0 ) {
							$slotId = 0;
						}
												
						$CARDS->{$cardIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
						
						if ( not defined $SLOT_INDEX->{$CARDS->{$cardIndex}{slotId}} ) {
							print "ERROR NO SLOT FOR CARD: $NODES->{$node}{name} $cardIndex $CARDS->{$cardIndex}{cardId}\n";
						}

				    #As card name we need model number, serial number and its parent slot ID for all other devices.						
						$CARDS->{$cardIndex}{cardName} = "$CARDS->{$cardIndex}{cardModel} $CARDS->{$cardIndex}{cardSerial} $CARDS->{$cardIndex}{slotId}";
				    						
				    my @columns;
				    foreach my $header (@cardHeaders) {
				    	my $data = undef;
				    	if ( defined $CARDS->{$cardIndex}{$header} ) {
				    		$data = $CARDS->{$cardIndex}{$header};
				    	}
				    	else {
				    		$data = "TBD";
				    	}
				    	$data = changeCellSep($data);
				    	push(@columns,$data);
				    }
						my $row = join($sep,@columns);
				    print CSV "$row\n";

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
	my $file = shift;
	my $title = "Ports";
	my $sheet;
	my $currow;
	
	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@portHeaders) {
		my $alias = $header;
		$alias = $portAlias{$header} if $portAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

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
			
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;

			# handling for this is device/model specific.
			my $SLOTS;
			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $slotIndex (sort keys %{$SLOTS}) {
					if ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /port/
					) {
						# what is the parent ID?
						my $parentId = $SLOTS->{$slotIndex}{entPhysicalContainedIn};
						my $cardId = "$NODES->{$node}{uuid}_C_$parentId";

						#my @portHeaders = qw(portName portId portType portStatus parent duplex);
						
						# Port ID is the Card ID and an index, relative position.
						$SLOTS->{$slotIndex}{portName} = $SLOTS->{$slotIndex}{entPhysicalName};
						$SLOTS->{$slotIndex}{portId} = "$NODES->{$node}{uuid}_P_$slotIndex";
						$SLOTS->{$slotIndex}{portType} = $SLOTS->{$slotIndex}{entPhysicalDescr};
						$SLOTS->{$slotIndex}{portStatus} = getStatus();
						$SLOTS->{$slotIndex}{parent} = $cardId;
						$SLOTS->{$slotIndex}{duplex} = getPortDuplex($SLOTS->{$slotIndex}{entPhysicalDescr});
						
				    my @columns;
				    foreach my $header (@portHeaders) {
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
				    print CSV "$row\n";

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

sub exportInterfaces {
	my $xls = shift;
	my $file = shift;
	
	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@intHeaders) {
		my $alias = $header;
		$alias = $intAlias{$header} if $intAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;

			# move on if this isn't a good one.
			next if $NI->{system}{nodeVendor} !~ /$goodVendors/;

			foreach my $ifIndex (sort keys %{$IF}) {
				if ( defined $IF->{$ifIndex} and defined $IF->{$ifIndex}{ifDescr} ) {
					# create a name
			    $IF->{$ifIndex}{name} = "$node--$IF->{$ifIndex}{ifDescr}";
			    $IF->{$ifIndex}{parent} = $NODES->{$node}{uuid};
					
			    my @columns;
			    foreach my $header (@intHeaders) {
			    	my $data = undef;
			    	if ( defined $IF->{$ifIndex}{$header} ) {
			    		$data = $IF->{$ifIndex}{$header};
			    	}
			    	else {
			    		$data = "TBD";
			    	}
			    	$data = changeCellSep($data);
			    	push(@columns,$data);
			    }
					my $row = join($sep,@columns);
			    print CSV "$row\n";
		  	}
			}
	  }
	}
	
	close CSV;
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
eg: $0 dir=/data debug=true separator=(comma|tab)

EO_TEXT
}

sub loadVendorOids {
	my $oids = "$C->{mib_root}/CISCO-ENTITY-VENDORTYPE-OID-MIB.oid";
	my $vendorOids;
	
	print "Loading Vendor OIDs from $oids\n";
	
	open(OIDS,$oids) or warn "ERROR could not load $oids: $!\n";
	
	my $match = qr/\"(\w+)\"\s+\"([\d+\.]+)\"/;
	
	while (<OIDS>) {
		if ( $_ =~ /$match/ ) {
			$vendorOids->{$2} = $1;
		}
		elsif ( $_ =~ /^#|^\s+#/ ) {
			#all good comment
		}
		else {
			print "ERROR: no match $_\n";
		}
	}
	close(OIDS);
	
	return ($vendorOids);
}

#Cisco IOS XR Software (Cisco CRS-8/S) Version 5.1.3[Default] Copyright (c) 2014 by Cisco Systems Inc.	
sub getVersion {
	my $sysDescr = shift;
	my $version;
	
	if ( $sysDescr =~ /Version ([\d\.\[\]\w]+)/ ) {
		$version = $1;
	}
	
	return $version;
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

sub nodeCheck {
	
	my $LNT = Compat::NMIS::loadLocalNodeTable();
	print "Running nodeCheck for nodes, model use, snmp max_msg_size and update\n";
	my %updateList;

	foreach my $node (sort keys %{$LNT}) {
		#print "Processing $node\n";
		if ( $LNT->{$node}{active} eq "true" ) {			
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			
			if ( $NI->{system}{lastUpdatePoll} < time() - 86400 ) {
				$updateList{$node} = $NI->{system}{lastUpdatePoll};
			}
			
			
			if ( $LNT->{$node}{model} ne "automatic" ) {
				print "WARNING: $node model not automatic; $LNT->{$node}{model} $NI->{system}{sysDescr}\n";
			}

			#print "updateMaxSnmpMsgSize $node $NI->{system}{sysObjectName}\n";

			
			if ( $NI->{system}{sysObjectName} =~ /$fixMaxMsgSize/ and $LNT->{$node}{max_msg_size} != 2800) {
				print "$node Updating Max SNMP Message Size\n";
				$LNT->{$node}{max_msg_size} = 2800;
			}
		}
	}
	
	print "Nodes requiring update:\n";
	foreach my $node (sort keys %updateList) {
		print "$node ". returnDateStamp($updateList{$node}) ."\n";
	}

	writeTable(dir => 'conf', name => "Nodes", data => $LNT);
}


