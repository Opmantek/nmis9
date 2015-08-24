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
use func;
use NMIS;
use Sys;
use NMIS::UUID;
use NMIS::Timing;

if ( $ARGV[0] eq "" ) {
	usage();
	exit 1;
}

my $t = NMIS::Timing->new();

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

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

#What models are we going to process
my $goodModels = qr/CiscoDSL/;

# Step 6: Run the program!

# Step 7: Check the results

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	exportNodes("$dir/oss-nodes.csv");
	exportSlots("$dir/oss-slots.csv");
	exportCards("$dir/oss-cards.csv");
	exportPorts("$dir/oss-ports.csv");
	#exportInterfaces("$dir/oss-interfaces.csv");
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " Begin\n";


sub exportNodes {
	my $file = shift;

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
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true") {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/;

			#my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 tbd4 group tbd5);
		    
		  # clone the name!
	    $NODES->{$node}{name2} = $NODES->{$node}{name};
	    $NODES->{$node}{name3} = $NODES->{$node}{name};
	    
	    # handling OSS values for these fields.
	    $NODES->{$node}{ossStatus} = $NI->{system}{nodestatus};
	    $NODES->{$node}{ossModel} = getModel($NI->{system}{sysObjectName});
	    $NODES->{$node}{ossType} = getType($NI->{system}{sysObjectName});

			# is there a decent serial number!
			if ( not defined $NI->{system}{serialNum} or $NI->{system}{serialNum} eq "" ) {
				my $ASSET;					
				if ( defined $S->{info}{ciscoAsset} and ref($S->{info}{ciscoAsset}) eq "HASH") {
					$ASSET = $S->{info}{ciscoAsset};
					
					if ( defined $ASSET->{1} and $ASSET->{1}{ceAssetSerialNumber} ne "" ) {
						$NI->{system}{serialNum} = $ASSET->{1}{ceAssetSerialNumber};
					}
					else {
						print "ERROR: $node no serial number, not in chassisId or ceAssetSerialNumber\n";						
					}
				}
				else {
					print "ERROR: $node no Cisco Entity Asset MIB Data available, check the model contains it and run an update on the node.\n";
				}
				
			}

	    
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
			my $joinChar = $sep eq "," ? " " : ",";
			$NODES->{$node}{uplink} = join($joinChar,@ipAddresses);
		    
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
	  }
	}
	
	close CSV;
}

sub exportSlots {
	my $file = shift;
	
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
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/;

			# handling for this is device/model specific.
			my $SLOTS;
			my $counter = 0;
			if ( $NI->{system}{nodeModel} eq "CiscoDSL" ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n";
					next;
				}

				foreach my $slotIndex (sort keys %{$SLOTS}) {
					if ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /container/
					) {
						# create a name
						++$counter;
						# the slot id is the parent relative position, not the index of the MIB
						my $slotId = $SLOTS->{$slotIndex}{entPhysicalParentRelPos};
						$SLOTS->{$slotIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
						$SLOTS->{$slotIndex}{nodeId} = $NODES->{$node}{uuid};
						$SLOTS->{$slotIndex}{position} = $SLOTS->{$slotIndex}{entPhysicalParentRelPos};
						$SLOTS->{$slotIndex}{slotName} = $SLOTS->{$slotIndex}{entPhysicalDescr};
						$SLOTS->{$slotIndex}{slotNetName} = "$SLOTS->{$slotIndex}{entPhysicalDescr} $slotId";
										    
				    # name for the parent node.
				    $SLOTS->{$slotIndex}{name1} = $NODES->{$node}{name};
				    $SLOTS->{$slotIndex}{name2} = $NODES->{$node}{name};
				    $SLOTS->{$slotIndex}{ossType} = getType($NI->{system}{sysObjectName});
						
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
			  	}
				}
			}
	  }
	}	
}

sub exportCards {
	my $file = shift;
	
	print "Creating $file\n";

	my $C = loadConfTable();
		
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
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/;

			# handling for this is device/model specific.
			my $SLOTS;
			my $ASSET;
			my $cardCount = 0;
			if ( $NI->{system}{nodeModel} eq "CiscoDSL" ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n";
					next;
				}
				
				if ( defined $S->{info}{ciscoAsset} and ref($S->{info}{ciscoAsset}) eq "HASH") {
					$ASSET = $S->{info}{ciscoAsset};
				}
				else {
					print "ERROR: $node no Cisco Entity Asset MIB Data available, check the model contains it and run an update on the node.\n";
				}

				foreach my $slotIndex (sort keys %{$SLOTS}) {
					if ( defined $SLOTS->{$slotIndex} 
						and defined $SLOTS->{$slotIndex}{entPhysicalClass} 
						and $SLOTS->{$slotIndex}{entPhysicalClass} =~ /module/
					) {
						# create a name
						++$cardCount;
						#my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel       cardType name1 name2 slotId);

						my $cardId = "$NODES->{$node}{uuid}_C_$slotIndex";

						$SLOTS->{$slotIndex}{cardName} = getCardName($SLOTS->{$slotIndex}{entPhysicalDescr});
						$SLOTS->{$slotIndex}{cardId} = $cardId;
						
				    $SLOTS->{$slotIndex}{cardNetName} = "CARD $slotIndex";

				    $SLOTS->{$slotIndex}{cardDescr} = $SLOTS->{$slotIndex}{entPhysicalDescr};
				    $SLOTS->{$slotIndex}{cardSerial} = $ASSET->{$slotIndex}{ceAssetSerialNumber};
				    
				    $SLOTS->{$slotIndex}{cardStatus} = getStatus();
						$SLOTS->{$slotIndex}{cardVendor} = $NI->{system}{nodeVendor};
						$SLOTS->{$slotIndex}{cardModel} = $SLOTS->{$slotIndex}{entPhysicalDescr};
										    
				    # name for the parent node.
				    $SLOTS->{$slotIndex}{cardType} = "CARD - ". getType($NI->{system}{sysObjectName});
				    $SLOTS->{$slotIndex}{name1} = $NODES->{$node}{name};
				    $SLOTS->{$slotIndex}{name2} = $NODES->{$node}{name};

						# what is the parent ID?
						# $parentId is the id of the slot the module is inserted into.
						my $parentId = $SLOTS->{$slotIndex}{entPhysicalContainedIn};
						
						# now we want the relative slot number the slot uses
						my $slotId = $SLOTS->{$parentId}{entPhysicalParentRelPos};
						
						# Cisco is using position -1 for the chassis???????
						if ( $slotId < 0 ) {
							$slotId = 0;
						}
												
						$SLOTS->{$slotIndex}{slotId} = "$NODES->{$node}{uuid}_S_$slotId";
				    
				    # get the parent and then determine its ID and 
						
				    my @columns;
				    foreach my $header (@cardHeaders) {
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
			  	}
				}
			}
	  }
	}	
}

sub exportPorts {
	my $file = shift;
	
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
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/;

			# handling for this is device/model specific.
			my $SLOTS;
			if ( $NI->{system}{nodeModel} eq "CiscoDSL" ) {
				if ( defined $S->{info}{entityMib} and ref($S->{info}{entityMib}) eq "HASH") {
					$SLOTS = $S->{info}{entityMib};
				}
				else {
					print "ERROR: $node no Entity MIB Data available, check the model contains it and run an update on the node.\n";
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
			  	}
				}
			}
	  }
	}	
}

sub exportInterfaces {
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
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;

			# move on if this isn't a good one.
			next if $NI->{system}{nodeModel} !~ /$goodModels/;

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
	
	$sysObjectName =~ s/cisco//g;	
	
	return $sysObjectName;		
}

sub getType {
	my $sysObjectName = shift;
	my $type = "TBD";
	
	if ( $sysObjectName =~ /cisco61|cisco62|cisco60|asam/ ) {
		$type = "DSLAM";	
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