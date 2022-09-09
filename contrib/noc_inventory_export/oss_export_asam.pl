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

our $VERSION = "2.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Path;
use NMISNG::Util;
use Getopt::Long;
use Compat::NMIS;
use NMISNG::Sys;
use Compat::Timing;
use Data::Dumper;
use Excel::Writer::XLSX;
use Term::ReadKey;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

my $PROGNAME    = basename($0);
my $debugsw     = 0;
my $helpsw      = 0;
my $interfacesw = 0;
my $usagesw     = 0;
my $versionsw   = 0;
my $defaultConf = "$FindBin::Bin/../conf";
my $xlsFile     = "oss_export.xlsx";

 die unless (GetOptions('debug:i'    => \$debugsw,
                        'help'       => \$helpsw,
                        'interfaces' => \$interfacesw,
                        'usage'      => \$usagesw,
                        'version'    => \$versionsw));

# For the Version mode, just print it and exit.
if (${versionsw}) {
	print "$PROGNAME version=$NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ($usagesw) {
   usage();
   exit(0);
}

# Set debugging level.
my $debug   = $debugsw;
$debug      = NMISNG::Util::getdebug_cli($arg->{debug}) if (exists($arg->{debug}));   # Backwards compatibility
print "Debug = '$debug'\n" if ($debug);

my $t = Compat::Timing->new();

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

# Set Directory level.
if ( not defined $arg->{dir} ) {
	print "ERROR: The directory argument is required!\n";
	help();
	exit 255;
}
my $dir = abs_path($arg->{dir});

if (! -d $dir) {
	if (-f $dir) {
		print "ERROR: The directory argument '$dir' points to a file, it must refer to a writable directory!\n";
		help();
		exit 255;
	}
	else {
		my ${key};
		my $IN;
		my $OUT;
		if ($^O =~ /Win32/i)
		{
			sysopen($IN,'CONIN$',O_RDWR);
			sysopen($OUT,'CONOUT$',O_RDWR);
		} else
		{
			open($IN,"</dev/tty");
			open($OUT,">/dev/tty");
		}
		print "Would you like me to create it? (y/n)  ";
		ReadMode 4, $IN;
		${key} = ReadKey 0, $IN;
		ReadMode 0, $IN;
		print("\r                                \r");
		if (${key} =~ /y/i)
		{
			eval {
				local $SIG{'__DIE__'};  # ignore user-defined die handlers
				mkpath($dir);
			};
			if ($@) {
			    print "FATAL: Error creating dir: $@\n";
				exit 255;
			}
			if (!-d $dir) {
				print "FATAL: Unable to create directory '$dir'.\n";
				exit 255;
			}
			if (-d $dir) {
				print "Directory '$dir' created successfully.\n";
			}
		}
		else {
			print "FATAL: Specify an existing directory with write permission.\n";
			exit 0;
		}
	}
}
if (! -w $dir) {
	print "FATAL: Unable to write to directory '$dir'.\n";
	exit 255;
}

print $t->elapTime(). " Begin\n";

# Set Directory level.
if ( defined $arg->{xls} ) {
	$xlsFile = $arg->{xls};
}
$xlsFile = "$dir/$xlsFile";

if (-f $xlsFile) {
	my ${key};
	my $IN;
	my $OUT;
	if ($^O =~ /Win32/i)
	{
		sysopen($IN,'CONIN$',O_RDWR);
		sysopen($OUT,'CONOUT$',O_RDWR);
	} else
	{
		open($IN,"</dev/tty");
		open($OUT,">/dev/tty");
	}
	print "The Excel file '$xlsFile' already exists!\n\n";
	print "Would you like me to overwrite it and all corresponding CSV files? (y/n) y\b";
	ReadMode 4, $IN;
	${key} = ReadKey 0, $IN;
	ReadMode 0, $IN;
	print("\r                                                                            \r");
	if ((${key} !~ /y/i) && (${key} !~ /\r/) && (${key} !~ /\n/))
	{
		print "FATAL: Not overwriting files.\n";
		exit 255;
	}
}

if ( not defined $arg->{conf}) {
	$arg->{conf} = $defaultConf;
}
else {
	$arg->{conf} = abs_path($arg->{conf});
}

print "Configuration Directory = '$arg->{conf}'\n" if ($debug);
# load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$arg->{conf}, debug=>$debug);
our $nmisng = Compat::NMIS::new_nmisng();

# Step 1: define your prefered seperator
my $sep = "\t";
if ( $arg->{separator} eq "tab" ) {
	$sep = "\t";
}
elsif ( $arg->{separator} eq "comma" ) {
	$sep = ",";
}
elsif (exists($arg->{separator})) {
	$sep = $arg->{separator};
}

# A cache of Card Indexes.
my $cardIndex;

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 relayRack location uplink);

# Step 4: Define any header aliases you want
my %nodeAlias = (
	name								=> 'Dslam Name',
	uuid								=> 'Equipment ID',
	ossType								=> 'Type',
	nodeVendor							=> 'Name of the Vendor',
	ossModel							=> 'Model',
	sysDescr							=> 'Description of the equipment',
	softwareVersion						=> 'SW Version',
	ossStatus							=> 'Status',
	serialNum							=> 'SerialNumber',
	name2								=> 'Name of the node in the Network',
	name3								=> 'Name in NMS',
	relayRack							=> 'Relay Rack name',
	location							=> 'Location',
	uplink								=> 'UpLink',
	comment								=> 'Comment',
);

my @slotHeaders = qw(slotId nodeId position slotName slotNetName name1 name2 ossType);

my %slotAlias = (
	slotId								=> 'Slot ID',
	nodeId								=> 'Equipment ID',
	position							=> 'Position in the equipment',
	slotName							=> 'Slot Name',
	slotNetName							=> 'Slot name in the network',
	name1								=> 'Name of the parent equipment',
	name2								=> 'Name of the parent eq in the network',
	ossType								=> 'Type of equipment',
);

#

my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel cardType name1 name2 slotId);

my %cardAlias = (
	cardName							=> 'Card name',
	cardId								=> 'Card ID',
	cardNetName							=> 'Name of the card in the network',
	cardDescr							=> 'Card Description',
	cardSerial							=> 'Card Serial',
	cardStatus							=> 'Status',
	cardVendor							=> 'Vendor',
	cardModel							=> 'Model',
	cardType							=> 'Type',
	name1								=> 'Name of the network where the card is installed',
	name2								=> 'Name of the equipment where the card is installed',
	slotId								=> 'Parent ID/Slot ID where the card is installed',
);

my @portHeaders = qw(portName portId portType portStatus parent duplex);

my %portAlias = (
	portName         					=> 'Name of the port in the network',
	portId								=> 'Port ID',
	portType							=> 'Type of port',
	portStatus							=> 'Status',
	parent								=> 'Parent ID/Card ID',
	duplex								=> 'Duplex full/half',
);

my @asamHeaders = qw(name type index eqptSlotPlannedType eqptSlotActualType eqptBoardAdminStatus eqptBoardOperStatus eqptBoardContainerId eqptBoardContainerOffset eqptBoardInventoryAlcatelCompanyId eqptBoardInventoryTypeName eqptBoardInventoryPBACode eqptBoardInventoryFPBACode eqptBoardInventoryICScode eqptBoardInventoryCLEICode eqptBoardInventorySerialNumber);

my %asamAlias = (
	name								=> 'Name',
	type								=> 'Type',
	index								=> 'Index',
	eqptSlotPlannedType					=> 'Slot Planned Type',
	eqptSlotActualType					=> 'Slot Actual Type',
	eqptBoardAdminStatus				=> 'Board Admin Status',
	eqptBoardOperStatus					=> 'Board Oper Status',
	eqptBoardContainerId				=> 'Board Container ID',
	eqptBoardContainerOffset			=> 'Board Container Offset',
	eqptBoardInventoryAlcatelCompanyId	=> 'Company ID',
	eqptBoardInventoryTypeName			=> 'Type Name',
	eqptBoardInventoryPBACode			=> 'PBA Code',
	eqptBoardInventoryFPBACode			=> 'FPBA Code',
	eqptBoardInventoryICScode			=> 'ICS Code',
	eqptBoardInventoryCLEICode			=> 'CLEI Code',
	eqptBoardInventorySerialNumber		=> 'Serial Number',
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

my $xls;
if ($xlsFile) {
	$xls = start_xlsx(file => $xlsFile);
}
unless ($xls) {
		die "ERROR: Excel file creation error..\n";
}

if ( $export eq "nodes" or $export eq "" ) {
	exportNodes($xls,"$dir/oss-nodes.csv");
	exportSlots($xls,"$dir/oss-slots.csv");
	exportCards($xls,"$dir/oss-cards.csv");
	exportAsam($xls,"$dir/oss-asam.csv");
	exportPorts($xls,"$dir/oss-ports.csv");
}

if ( $export eq "logical" or $export eq "" ) {
	exportInventory(xls => $xls, file => "$dir/oss-iftable-data.csv", title => "ifTable", section => "ifTable");
	exportInventory(xls => $xls, file => "$dir/oss-ifstack-data.csv", title => "ifStack", section => "ifStack") if ($interfacesw);
	exportInventory(xls => $xls, file => "$dir/oss-atmvcl-data.csv", title => "atmVcl", section => "atmVcl");
	exportInventory(xls => $xls, file => "$dir/oss-dot1qpvid-data.csv", title => "dot1qPvid", section => "dot1qPvid");
	exportInventory(xls => $xls, file => "$dir/oss-dot1qvlan-data.csv", title => "dot1qVlan", section => "dot1qVlan");
}

end_xlsx(xls => $xls);
print "XLS saved to $xlsFile\n";

print $t->elapTime(). " End\n";


sub exportNodes {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Nodes";
	my $sheet;
	my $currow;
	my @colsize;

	print "Creating Node Data\n";

	print "Creating $file\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	my @aliases;
	my $currcol=0;
	foreach my $header (@nodeHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($nodeAlias{$header}));
		my $alias  = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
		print "DEBUG: '$NODES->{$node}{name}' Active Status is $NODES->{$node}{active}.\n" if ($debug > 1);
		if ( $NODES->{$node}{active} ) {
			my @comments;
			my $comment;
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $IF            = $nodeobj->ifinfo;
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			print "DEBUG: System Object: " . Dumper($S) . "\n\n\n" if ($debug > 8);
			print "DEBUG: '$NODES->{$node}{name}' Node Down Status is $catchall_data->{nodedown}.\n" if ($debug);

			my $nodestatus = $catchall_data->{nodestatus};
			$nodestatus = "unreachable" if $catchall_data->{nodedown} eq "true";

			print "DEBUG: '$NODES->{$node}{name}' vendor is '$catchall_data->{nodeVendor}'.\n" if ($debug > 1);

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			# There doesn't seem to be good serial numbers

			# get software version for Alcatel ASAM      
			if ( defined $catchall_data->{asamActiveSoftware1} and $catchall_data->{asamActiveSoftware1} eq "active" ) {
				$catchall_data->{softwareVersion} = $catchall_data->{asamSoftwareVersion1};
				print "DEBUG '$NODES->{$node}{name}' Found Software Version '$catchall_data->{softwareVersion}'.\n" if ($debug);
			}
			elsif ( defined $catchall_data->{asamActiveSoftware2} and $catchall_data->{asamActiveSoftware2} eq "active" ) {
				$catchall_data->{softwareVersion} = $catchall_data->{asamSoftwareVersion2};
				print "DEBUG '$NODES->{$node}{name}' Found Software Version '$catchall_data->{softwareVersion}'.\n" if ($debug);
			}

			# Get an uplink address, find any address and put it in a string
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
			$NODES->{$node}{ossStatus} = $catchall_data->{nodestatus};
			$NODES->{$node}{ossModel}  = getModel($catchall_data->{sysObjectName});
			$NODES->{$node}{ossType}   = getType($catchall_data->{sysObjectName},$catchall_data->{nodeType});

			#$NODES->{$node}{comment} = join($joinChar,@comments);

			if ( not defined $NODES->{$node}{relayRack} or $NODES->{$node}{relayRack} eq "" ) {
				$NODES->{$node}{relayRack} = "No Relay Rack Configured";
			}

			if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
				$NODES->{$node}{location} = "No Location Configured";
			}

			my @columns;
			my $currcol=0;
			foreach my $header (@nodeHeaders) {
				my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($nodeAlias{$header}));
				my $data   = undef;
				if ( defined $NODES->{$node}{$header} ) {
					$data = $NODES->{$node}{$header};
				}
				elsif ( defined $catchall_data->{$header} ) {
					$data = $catchall_data->{$header};	    
				}
				else {
					$data = "TBD";
				}
				$colLen = ((length($data) > 253 || length($nodeAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
				$data   = changeCellSep($data);
				$colsize[$currcol] = $colLen;
				push(@columns,$data);
				$currcol++;
			}
			my $row = join($sep,@columns);
			print CSV "$row\n";

			if ($sheet) {
				$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
				++$currow;
			}
		}
	}
	my $i=0;
	foreach my $header (@nodeHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
}

sub exportSlots {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Slots";
	my $sheet;
	my $currow;
	my @colsize;

	print "Creating Slots Data\n";

	print "Creating $file\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	my @aliases;
	my $currcol=0;
	foreach my $header (@slotHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($slotAlias{$header}));
		my $alias  = $header;
		$alias = $slotAlias{$header} if $slotAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %slots = undef;
			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{eqptHolder} and ref($MDL->{systemHealth}{sys}{eqptHolder}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptHolder", filter => { historic => 0 });
					if (!$result->error)
					{
						%slots = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no eqptHolder MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				my $slotStatus = $MDL->{systemHealth}{sys}{eqptHolderStatus};

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

				foreach my $slotIndex (sort keys %slots) {
					if ( defined $slots{$slotIndex} and defined $slots{$slotIndex}{eqptHolderIndex} ) {
						# create a name

						# Slot ID's are a pain............
						# Option 1: the slot id is the parent relative position, not the index of the MIB
						# con: some chassis this creates duplicate slot id's
						#my $slotId = $slots{$slotIndex}{entPhysicalParentRelPos};

						# Option 2: the slot id is the entityMib Index, which creates completely Unique id's
						my $slotId = $slots{$slotIndex}{index};

						$slots{$slotIndex}{slotId}   = "$NODES->{$node}{uuid}_S_$slotId";
						$slots{$slotIndex}{nodeId}   = $NODES->{$node}{uuid};
						$slots{$slotIndex}{position} = $slotIndex;

						# assign the default values here.
						my $slotName = $slots{$slotIndex}{eqptHolderActualType};
						my $slotNetName = $slots{$slotIndex}{eqptHolderActualType};

						# different models of Cisco use different methods.........
						# so if the slot name is empty or just a number make one up, 
						if ( $slotName eq "EMPTY" ) {
							$slotName = "$slotId";
						}

						$slots{$slotIndex}{slotName}    = $slotName;
						$slots{$slotIndex}{slotNetName} = $slotNetName;
										    
						# name for the parent node.
						$slots{$slotIndex}{name1}   = $NODES->{$node}{name};
						$slots{$slotIndex}{name2}   = $NODES->{$node}{name};
						$slots{$slotIndex}{ossType} = getType($catchall_data->{sysObjectName},$catchall_data->{nodeType});

						my @columns;
						my $currcol=0;
						foreach my $header (@slotHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($slotAlias{$header}));
							my $data   = undef;
							if ( defined $slots{$slotIndex}{$header} ) {
								$data = $slots{$slotIndex}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($slotAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
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
	my $i=0;
	foreach my $header (@slotHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
}

sub exportCards {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Cards";
	my $sheet;
	my $currow;
	my @colsize;

	print "Creating Card Data\n";

	print "Creating $file\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	my @aliases;
	my $currcol=0;
	foreach my $header (@cardHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($cardAlias{$header}));
		my $alias  = $header;
		$alias = $cardAlias{$header} if $cardAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %slots     = undef;
			my %boards    = undef;
			my $cardCount = 0;
			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{eqptHolderList} and ref($MDL->{systemHealth}{sys}{eqptHolderList}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptHolderList", filter => { historic => 0 });
					if (!$result->error)
					{
						%slots = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no eqptHolderList MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				if ( defined $MDL->{systemHealth}{sys}{eqptBoard} and ref($MDL->{systemHealth}{sys}{eqptBoard}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptBoard", filter => { historic => 0 });
					if (!$result->error)
					{
						%boards = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
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
      
				foreach my $boardIndex (sort keys %boards) {
					if ( defined $boards{$boardIndex} and defined $boards{$boardIndex}{eqptBoardInventoryTypeName} and $boards{$boardIndex}{eqptBoardInventoryTypeName} ne "") {
						# create a name
						++$cardCount;
						#my @cardHeaders = qw(cardName cardId cardNetName cardDescr cardSerial cardStatus cardVendor cardModel       cardType name1 name2 slotId);

						my $cardId = "$NODES->{$node}{uuid}_C_$boardIndex";

						if ( defined $boards{$boardIndex} and $boards{$boardIndex}{eqptBoardInventorySerialNumber} ne "" ) {
							$boards{$boardIndex}{cardSerial} = $boards{$boardIndex}{eqptBoardInventorySerialNumber};
						}
						elsif ( $boards{$boardIndex}{eqptSlotPlannedType} !~ /(NOT_ALLOWED|NOT_PLANNED)/ ) {
							# its ok, don't bother me.
						}
						else {
							my $comment = "ERROR: $node no CARD serial number for id $boardIndex $boards{$boardIndex}{eqptSlotPlannedType}";
							print "$comment\n";
						}

						if ( $boards{$boardIndex}{eqptBoardInventoryTypeName} ne "" and $boards{$boardIndex}{eqptBoardInventoryTypeName} !~ /^d+$/ ) {
							$boards{$boardIndex}{cardName} = $boards{$boardIndex}{eqptBoardInventoryTypeName};
						}
						$boards{$boardIndex}{cardId}      = $cardId;
						$boards{$boardIndex}{cardNetName} = "CARD $boardIndex";
						$boards{$boardIndex}{cardDescr}   = $boards{$boardIndex}{eqptBoardInventoryTypeName};
						$boards{$boardIndex}{cardStatus}  = $boards{$boardIndex}{eqptBoardOperStatus};
						$boards{$boardIndex}{cardVendor}  = $catchall_data->{nodeVendor};

						if ( defined $boards{$boardIndex} and $boards{$boardIndex}{eqptBoardInventoryTypeName} ne "" ) {
							$boards{$boardIndex}{cardModel} = $boards{$boardIndex}{eqptBoardInventoryTypeName};
						}

						# name for the parent node.				    
						$boards{$boardIndex}{name1} = $NODES->{$node}{name};
						$boards{$boardIndex}{name2} = $NODES->{$node}{name};

						my $slotId = $boards{$boardIndex}{eqptBoardContainerId};
						$boards{$boardIndex}{cardType} = $slots{$slotId}{eqptHolderActualType};
						$boards{$boardIndex}{slotId}   = "$NODES->{$node}{uuid}_S_$slotId";

						# get the parent and then determine its ID and 

						my @columns;
						my $currcol=0;
						foreach my $header (@cardHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($cardAlias{$header}));
							my $data   = undef;
							if ( defined $boards{$boardIndex}{$header} ) {
								$data = $boards{$boardIndex}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($cardAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
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
	my $i=0;
	foreach my $header (@cardHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
}

sub exportAsam {
	my $xls   = shift;
	my $file  = shift;
	my $title = "ASAM";
	my $sheet;
	my $currow;
	my @colsize;

	print "Creating ASAM Data\n";

	print "Creating $file\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	my @aliases;
	my $currcol=0;
	foreach my $header (@asamHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($asamAlias{$header}));
		my $alias  = $header;
		$alias = $asamAlias{$header} if $asamAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %slots     = undef;;
			my %boards    = undef;;
			my $cardCount = 0;
			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{eqptHolderList} and ref($MDL->{systemHealth}{sys}{eqptHolderList}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptHolderList", filter => { historic => 0 });
					if (!$result->error)
					{
						%slots = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no eqptHolderList MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				if ( defined $MDL->{systemHealth}{sys}{eqptBoard} and ref($MDL->{systemHealth}{sys}{eqptBoard}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptBoard", filter => { historic => 0 });
					if (!$result->error)
					{
						%boards = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no eqptBoard MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $boardIndex (sort keys %boards) {
					if ( defined $boards{$boardIndex} and defined $boards{$boardIndex}{eqptSlotPlannedType} and $boards{$boardIndex}{eqptSlotPlannedType} ne "") {
						++$cardCount;

						# get the node name
						$boards{$boardIndex}{name} = $NODES->{$node}{name};

						# get the name of the container as the type.
						my $slotId = $boards{$boardIndex}{eqptBoardContainerId};
						$boards{$boardIndex}{type} = $slots{$slotId}{eqptHolderActualType};

						# get the parent and then determine its ID and 

						my @columns;
						my $currcol=0;
						foreach my $header (@asamHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($asamAlias{$header}));
							my $data   = undef;
							if ( defined $boards{$boardIndex}{$header} ) {
								$data = $boards{$boardIndex}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($asamAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
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
	my $i=0;
	foreach my $header (@asamHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
}

sub exportPorts {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Ports";
	my $sheet;
	my $currow;
	my @colsize;

	print "Creating Ports Data\n";

	print "Creating $file\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	my @aliases;
	my $currcol=0;
	foreach my $header (@portHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($portAlias{$header}));
		my $alias = $header;
		$alias = $portAlias{$header} if $portAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: need an xls to work on.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %ports = undef;
			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{eqptPortMapping} and ref($MDL->{systemHealth}{sys}{eqptPortMapping}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "eqptPortMapping", filter => { historic => 0 });
					if (!$result->error)
					{
						%ports = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no eqptPortMapping MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $portIndex (sort keys %ports) {
					if ( defined $ports{$portIndex} and defined $ports{$portIndex}{eqptPortMappingPhyPortNbr} ) {
						my $portStatus = getStatus();
						my $portId = $portIndex;
						my $portName = "$ports{$portIndex}{eqptPortMappingLogPortType}-$portIndex";

						# what is the parent ID?
						my $parentId;

						if ( $ports{$portIndex}{eqptPortMappingPhyPortSlot} != 65535 ) {
							$parentId = $ports{$portIndex}{eqptPortMappingPhyPortSlot};
						}
						elsif ( $ports{$portIndex}{eqptPortMappingLSMSlot} != 65535 ) {
							$parentId = $ports{$portIndex}{eqptPortMappingLSMSlot};
						}
						else {
							# it isn't logical or physical, it must not exist!
							next();
						}
						my $cardId = "$NODES->{$node}{uuid}_C_$parentId";

						#my @portHeaders = qw(portName portId portType portStatus parent duplex);

						# Port ID is the Card ID and an index, relative position.
						$ports{$portIndex}{portName}   = $portName;
						$ports{$portIndex}{portId}     = "$NODES->{$node}{uuid}_P_$portId";
						$ports{$portIndex}{portType}   = $ports{$portIndex}{eqptPortMappingLogPortType};
						$ports{$portIndex}{portStatus} = $portStatus;
						$ports{$portIndex}{parent}     = $cardId;
						$ports{$portIndex}{duplex}     = "N/A";

						my @columns;
						my $currcol=0;
						foreach my $header (@portHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($portAlias{$header}));
							my $data   = undef;
							if ( defined $ports{$portIndex}{$header} ) {
								$data = $ports{$portIndex}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($portAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
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
	my $i=0;
	foreach my $header (@portHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
}


sub exportInventory {
	my (%args)  = @_;
	my $xls     = $args{xls};
	my $file    = $args{file};
	my $title   = $args{section};
	my $section = $args{section};
	my $sheet;
	my $currow;
	my @colsize;

	$title = $args{title} if defined $args{title};

	die "I must know which section!" if not defined $args{section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print "Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n";

	print "Creating '$title' sheet with section $section\n";

	# declare some vars for filling in later.
	my $nodes = 0;
	my $records = 0;
	my @invHeaders;
	my %invAlias;

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeModel} !~ /$goodModels/ or $catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as either vendor '$catchall_data->{nodeVendor}' or model '$catchall_data->{nodeModel}' does not qualify.\n" if ($debug);
				next;
			}

			++$nodes;

			# handling for this is device/model specific.
			my %concept = undef;;

			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{$section} and ref($MDL->{systemHealth}{sys}{$section}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "$section", filter => { historic => 0 });
					if (!$result->error)
					{
						%concept = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
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
						node				=> 'Node Name',
						parent				=> 'Parent',
						location			=> 'Location'
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
					my $currcol=0;
					foreach my $header (@invHeaders) {
						my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						$colsize[$currcol] = $colLen;
						push(@aliases,ucfirst($alias));
						$currcol++;
					}

					if ($file) {
						print "Creating $file\n";
						open(CSV,">$file") or die "Error with CSV File $file: $!\n";
						# print a CSV header
						my $header = join($sep,@aliases);
						print CSV "$header\n";
					}
					if ($xls) {
						$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
						$currow = 1;								# header is row 0
					}
					else {
						die "ERROR: Internal error, xls is no longer defined.\n";
					}
				}

				foreach my $idx (sort keys %concept) {
					if ( defined $concept{$idx} ) {
						++$records;
						$concept{$idx}{node}     = $node;
						$concept{$idx}{parent}   = $NODES->{$node}{uuid};
						$concept{$idx}{location} = $NODES->{$node}{location};

						my @columns;
						my $currcol=0;
						foreach my $header (@invHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
							my $data   = undef;
							if ( defined $concept{$idx}{$header} ) {
								$data = $concept{$idx}{$header};
							}
							else {
								$data = "TBD";
							}
							$data = "N/A" if $data eq "noSuchInstance";
							$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
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
	my $i=0;
	foreach my $header (@invHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}
	close CSV;

	print "Processed $nodes nodes with $records $section records\n";
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
Usage: $PROGNAME -d[=[0-9]] -h -i -u -v dir=<directory> [option=value...]

$PROGNAME will export nodes and ports from NMIS.

Arguments:
 conf=<Configuration file> (default: '$defaultConf');
 dir=<Drectory where files should be saved>
 separator=<Comma separated  value (CSV) separator character (default: tab)
 xls=<Excel filename> (default: '$xlsFile')

Enter $PROGNAME -h for compleate details.

eg: $PROGNAME dir=/data separator=(comma|tab)
\n
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
		die "ERROR: Internal error, xls is no longer defined.\n";
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
		die "ERROR: Internal error, xls is no longer defined.\n";
	}
	return 1;
}


###########################################################################
#  Help Function
###########################################################################
sub help
{
   my(${currRow}) = @_;
   my @{lines};
   my ${workLine};
   my ${line};
   my ${key};
   my ${cols};
   my ${rows};
   my ${pixW};
   my ${pixH};
   my ${i};
   my $IN;
   my $OUT;

   if ((-t STDERR) && (-t STDOUT)) {
      if (${currRow} == "")
      {
         ${currRow} = 0;
      }
      if ($^O =~ /Win32/i)
      {
         sysopen($IN,'CONIN$',O_RDWR);
         sysopen($OUT,'CONOUT$',O_RDWR);
      } else
      {
         open($IN,"</dev/tty");
         open($OUT,">/dev/tty");
      }
      ($cols, $rows, $pixW, $pixH) = Term::ReadKey::GetTerminalSize $OUT;
   }
   STDOUT->autoflush(1);
   STDERR->autoflush(1);

   push(@lines, "\n\033[1mNAME\033[0m\n");
   push(@lines, "       $PROGNAME -  Exports nodes and ports from NMIS into an Excel spredsheet.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] dir=<directory> [option=value] ...\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program Exports NMIS nodes into an Excel spreadsheet in\n");
   push(@lines, "       the specified directory with the required 'dir' parameter. The command\n" );
   push(@lines, "       also creates Comma Separated Value (CSV) files in the same directory.\n");
   push(@lines, "       If the '--interfaces' option is specified, Interfaces will be\n");
   push(@lines, "       exported as well.  They are not included by default because there may\n");
   push(@lines, "       thousands of them on some devices.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --debug=[1-9]            - global option to print detailed messages\n");
   push(@lines, " --help                   - display command line usage\n");
   push(@lines, " --interfaces             - include interfaces in the export\n");
   push(@lines, " --usage                  - display a brief overview of command syntax\n");
   push(@lines, " --version                - print a version message and exit\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     dir=<directory>         - The directory where the files should be stored.\n");
   push(@lines, "                                Both the Excel spreadsheet and the CSV files\n");
   push(@lines, "                                will be stored in this directory. The\n");
   push(@lines, "                                directory should exist and be writable.\n");
   push(@lines, "     [conf=<filename>]       - The location of an alternate configuration file.\n");
   push(@lines, "                                (default: '$defaultConf')\n");
   push(@lines, "     [debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9>]\n");
   push(@lines, "                             - Set the debug level.\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                 CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                 understood. Other characters will be taken\n");
   push(@lines, "                                 literally. (default: 'tab')\n");
   push(@lines, "     [xls=<filename>]        - The name of the XLS file to be created in the\n");
   push(@lines, "                                 directory specified using the 'dir' parameter'.\n");
   push(@lines, "                                 (default: '$xlsFile')\n");
   push(@lines, "\n");
   push(@lines, "\033[1mEXIT STATUS\033[0m\n");
   push(@lines, "     The following exit values are returned:\n");
   push(@lines, "     0 Success\n");
   push(@lines, "     215 Failure\n\n");
   push(@lines, "\033[1mEXAMPLE\033[0m\n");
   push(@lines, "   $PROGNAME dir=/tmp separator=comma\n");
   push(@lines, "\n");
   push(@lines, "\n");
   print(STDERR "                       $PROGNAME - ${VERSION}\n");
   print(STDERR "\n");
   ${currRow} += 2;
   foreach (@lines)
   {
      if ((-t STDERR) && (-t STDOUT)) {
         ${i} = tr/\n//;  # Count the newlines in this string
         ${currRow} += ${i};
         if (${currRow} >= ${rows})
         {
            print(STDERR "Press any key to continue.");
            ReadMode 4, $IN;
            ${key} = ReadKey 0, $IN;
            ReadMode 0, $IN;
            print(STDERR "\r                          \r");
            if (${key} =~ /q/i)
            {
               print(STDERR "Exiting per user request. \n");
               return;
            }
            if ((${key} =~ /\r/) || (${key} =~ /\n/))
            {
               ${currRow}--;
            } else
            {
               ${currRow} = 1;
            }
         }
      }
      print(STDERR "$_");
   }
}
