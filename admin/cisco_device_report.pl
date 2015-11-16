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
use Data::Dumper;
use Excel::Writer::XLSX;

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

# Set Directory level.
my $xlsFile = "cisco_device_report.xlsx";
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

#      "serialNum" : "FHK1445735Q",
#      "chassisVer" : "1.0",
#      "configLastSaved" : "508612969",
#      "configLastChanged" : "508499202",
#      "bootConfigLastChanged" : "423056140",
#      "softwareImage" : "C880DATA-UNIVERSALK9-M",
#      "softwareVersion" : "15.1(1)T1",

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = qw(name host group location nodeVendor nodeModel serialNum configurationState softwareVersion softwareImage cbqosInput cbqosOutput ifNumber intfCollect chassisVer configLastSaved configLastChanged bootConfigLastChanged);

# Step 4: Define any CSV header aliases you want
my %nodeAlias = (
	name              		=> 'node',
	host									=> 'host',
	group									=> 'group',
	nodeVendor            => 'nodeVendor',
	nodeModel             => 'nodeModel',
	serialNum							=> 'serialNum',
	chassisVer						=> 'chassisVer',
	softwareVersion				=> 'softwareVersion',
	softwareImage					=> 'softwareImage',
	serialNum      		    => 'serialNum',
	configurationState		=> 'configurationState',
	configLastSaved       => 'configLastSaved',
	configLastChanged     => 'configLastChanged',
	cbqosInput            => 'cbqosInput',
	cbqosOutput           => 'cbqosOutput',
	bootConfigLastChanged => 'bootConfigLastChanged',
	location           		=> 'Location',
	ifNumber           		=> 'ifNumber',
	intfCollect           => 'intfCollect',
);

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	
	my $xls;
	if ($xlsFile) {
		$xls = start_xlsx(file => $xlsFile);
	}
	
	checkNodes($xls);

	end_xlsx(xls => $xls);
	print "XLS saved to $xlsFile\n";
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " Begin\n";


sub checkNodes {
	my $xls = shift;
	my $title = "Nodes";
	my $sheet;
	my $currow;

	print "Creating Excel Report\n";

	my $C = loadConfTable();

	my @aliases;
	foreach my $header (@nodeHeaders) {
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
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
	  if ( $NODES->{$node}{active} eq "true") {
	  	my @comments;
	  	my $comment;
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $V =  $S->view;
			
			# move on if this isn't a good one.
			next if $NI->{system}{nodeVendor} !~ /Cisco/;
			
			# check for data prerequisites
			if ( $NI->{system}{nodeVendor} =~ /Cisco/ and not defined $S->{info}{entityMib} ) {
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
				else {
					$NI->{system}{serialNum} = "TBD";
					$comment = "ERROR: $node no serial number not in chassisId entityMib or ciscoAsset";
					print "$comment\n";
					push(@comments,$comment);
				}				
			}			

	    if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
	    	$NODES->{$node}{location} = "No Location Configured";
	    }
	    
	    # this shoudl work!
	   	if ( defined $V->{system}{"configurationState_value"} and $V->{system}{"configurationState_value"} ne "" ) {
	    	$NI->{system}{"configurationState"} = $V->{system}{"configurationState_value"};
	    }

	    my $configLastChanged = $NI->{system}{configLastChanged};
	    my $bootConfigLastChanged = $NI->{system}{bootConfigLastChanged};
	    	    
			### Cisco Node Configuration Change Only
			if( defined $configLastChanged && defined $bootConfigLastChanged ) {
				
				### when the router reboots bootConfigLastChanged = 0 and configLastChanged is about 2 seconds, which are the changes made by booting.
				if( $configLastChanged > $bootConfigLastChanged and $configLastChanged > 5000 ) {
					$NI->{system}{"configurationState"} = "Config Not Saved in NVRAM";
				} 
				elsif( $bootConfigLastChanged == 0 and $configLastChanged <= 5000 ) {
					$NI->{system}{"configurationState"} = "Config Not Changed Since Boot";
				} 
				else {
					$NI->{system}{"configurationState"} = "Config Saved in NVRAM";
				}
			}

	    if ( defined $NI->{Cisco_CBQoS} ) {
	    	my @input;
	    	my @output;
	    	foreach my $cbqos (keys %{$NI->{Cisco_CBQoS}}) {
		    	push(@input,$NI->{Cisco_CBQoS}{$cbqos}{ifDescr}) if $NI->{Cisco_CBQoS}{$cbqos}{cbQosPolicyDirection} eq "input";
		    	push(@output,$NI->{Cisco_CBQoS}{$cbqos}{ifDescr}) if $NI->{Cisco_CBQoS}{$cbqos}{cbQosPolicyDirection} eq "output";	
	    	}
	    	push(@input,"None found") if not @input;
	    	push(@output,"None found") if not @output;	    	
	    	
	    	$NODES->{$node}{cbqosInput} = join("; ",@input);
	    	$NODES->{$node}{cbqosOutput} = join("; ",@output);
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

			if ($sheet) {
				$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
				++$currow;
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

sub usage {
	print <<EO_TEXT;
$0 will export nodes and ports from NMIS.
ERROR: need some files to work with
usage: $0 dir=<directory>
eg: $0 dir=/data debug=true separator=(comma|tab)

EO_TEXT
}


sub start_xlsx
{
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
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

