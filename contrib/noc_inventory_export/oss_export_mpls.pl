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
my $xlsFile = "oss_export_mpls.xlsx";
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


my @portHeaders = qw(portName portId portType portStatus parent duplex);

my %portAlias = (
	portName         			=> 'Name of the port in the network',
	portId								=> 'Port ID',
	portType							=> 'Type of port',
	portStatus						=> 'Status',
	parent								=> 'parent ID /Card ID',
	duplex								=> 'Duplex full/half',
);

my @vlanHeaders = qw(node parent vtpVlanIndex vtpVlanName vtpVlanType location);

my %vlanAlias = (
	node       						=> 'NODE_NAME',
	parent       					=> 'NODE_ID',
	vtpVlanIndex       		=> 'VLAN_ID',
	vtpVlanName						=> 'VLAN_NAME',
	vtpVlanType						=> 'VLAN_TYPE',
	location	            => 'LOCALIDAD',
);


my @vrfHeaders = qw(node parent vrfLrType mplsVpnVrfName location vrfRoleInVpn ifDescr vrfRefVpnName);

my %vrfAlias = (
	node       						=> 'NODE_NAME',
	parent       					=> 'NODE_ID',
	vrfLrType							=> 'LR_TYPE',
	mplsVpnVrfName				=> 'VRF_NAME',
	location							=> 'LOCALIDAD',
	vrfRoleInVpn					=> 'ROLE_IN_VPN',
	#mplsVpnVrfDescription => 'VRF_DESCRIPTION',
	ifDescr	            	=> 'REF_ASSIGNED_INTERFACE',
	vrfRefVpnName					=> 'REF_VPN_NAME',
);


# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

#What vendors are we going to process
my $goodVendors = qr/Cisco/;

#What models are we going to process
my $goodModels = qr/CiscoDSL/;

#What devices need to get Max message size updated
my $fixMaxMsgSize = qr/cat650.|ciscoWSC65..|cisco61|cisco62|cisco60|cisco76/;

# Step 6: Run the program!

# Step 7: Check the results

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	
	nodeCheck();

	my $xls;
	if ($xlsFile) {
		$xls = start_xlsx(file => $xlsFile);
	}
	
	exportVrf($xls);
	exportVlan($xls);

	exportInventory(xls => $xls, title => "Interfaces", section => "interface", model_section => "standard", model_section_top => "interface");
	exportInventory(xls => $xls, title => "mplsL3VpnVrf", section => "mplsL3VpnVrf");
	exportInventory(xls => $xls, title => "mplsL3VpnIfConf", section => "mplsL3VpnIfConf");
	exportInventory(xls => $xls, title => "mplsL3VpnVrfRT", section => "mplsL3VpnVrfRT");
	exportInventory(xls => $xls, title => "mplsLdpEntity", section => "mplsLdpEntity");
	exportInventory(xls => $xls, title => "CiscoPseudowireVC", section => "CiscoPseudowireVC");
	
	#exportInventory(xls => $xls, title => "Cisco_CBQoS", section => "Cisco_CBQoS");
	#exportInventory(xls => $xls, title => "mplsVpnVrf", section => "mplsVpnVrf");
	#exportInventory(xls => $xls, title => "mplsVpnInterface", section => "mplsVpnInterface");
	#exportInventory(xls => $xls, title => "mplsVpnVrfRouteTarget", section => "mplsVpnVrfRouteTarget");
	#exportInventory(xls => $xls, title => "mplsVpnLdpCisco", section => "mplsVpnLdpCisco");
	
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
}

sub exportVrf {
	my $xls = shift;

	my $title = "VRF";
	my $sheet;
	my $currow;
	
	print "Creating $title sheet\n";

	my $C = loadConfTable();
	
	# print a CSV header
	my @aliases;
	foreach my $header (@vrfHeaders) {
		my $alias = $header;
		$alias = $vrfAlias{$header} if $vrfAlias{$header};
		push(@aliases,$alias);
	}
	
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
			my $VRF;

			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{mplsVpnInterface} and ref($S->{info}{mplsVpnInterface}) eq "HASH") {
					$VRF = $S->{info}{mplsVpnInterface};
				}
				else {
					print "ERROR: $node no mplsVpnInterface MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				
				foreach my $idx (sort keys %{$VRF}) {
					if ( defined $VRF->{$idx} ) {						
						$VRF->{$idx}{node} = $node;
						$VRF->{$idx}{parent} = $NODES->{$node}{uuid};
						$VRF->{$idx}{location} = $NODES->{$node}{location};
						$VRF->{$idx}{vrfLrType} = "VRF";
						$VRF->{$idx}{vrfRoleInVpn} = "";
						$VRF->{$idx}{vrfRefVpnName} = $VRF->{$idx}{mplsVpnVrfName};

				    my @columns;
				    foreach my $header (@vrfHeaders) {
				    	my $data = undef;
				    	if ( defined $VRF->{$idx}{$header} ) {
				    		$data = $VRF->{$idx}{$header};
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

sub exportVlan {
	my $xls = shift;

	my $title = "VLAN";
	my $sheet;
	my $currow;
	
	print "Creating $title sheet\n";

	my $C = loadConfTable();
	
	# print a CSV header
	my @aliases;
	foreach my $header (@vlanHeaders) {
		my $alias = $header;
		$alias = $vlanAlias{$header} if $vlanAlias{$header};
		push(@aliases,$alias);
	}
	
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
			my $VLAN;

			if ( $NI->{system}{nodeModel} =~ /$goodModels/ or $NI->{system}{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $S->{info}{vtpVlan} and ref($S->{info}{vtpVlan}) eq "HASH") {
					$VLAN = $S->{info}{vtpVlan};
				}
				else {
					print "ERROR: $node no mplsVpnInterface MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				
				foreach my $idx (sort keys %{$VLAN}) {
					if ( defined $VLAN->{$idx} ) {						
						$VLAN->{$idx}{node} = $node;
						$VLAN->{$idx}{parent} = $NODES->{$node}{uuid};
						$VLAN->{$idx}{location} = $NODES->{$node}{location};

				    my @columns;
				    foreach my $header (@vlanHeaders) {
				    	my $data = undef;
				    	if ( defined $VLAN->{$idx}{$header} ) {
				    		$data = $VLAN->{$idx}{$header};
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
eg: $0 dir=/data debug=true separator=(comma|tab)

EO_TEXT
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


