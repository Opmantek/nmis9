#!/usr/bin/perl
#
## $Id: check_nmis_code.pl,v 8.2 2012/05/24 13:24:37 keiths Exp $
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

# Fields in use
# HC-Division
# CombinedIP
# TYPE Group
# PCI SITE?
# CMDB Name
# Miguel Node Name
# Miguel LocationID
# Location Name
# Location Address
# Location City
# Location Country
# Service Level
# Device Type
# Ping only **NEW
# Node Status **NEW
# CMDB Company **NEW


# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use Data::Dumper;

my @ERROR;

my $basedir = "/root";
my $cmdbFile = "$basedir/MasterNetworkData.txt";
my $cmdbKey = "Sort number:CombinedIP";
my $nodesFile = "$basedir/Nodes.nmis";
my $locationsFile = "$basedir/Locations.nmis";

# 26 States EAST of Mississippi, PLUS DC and 2 misspelled from the spreadsheet
my $eastStates = qr/Alabama|Connecticut|Delaware|Florida|Georgia|Illinois|Indiana|Kentucky|Maine|Maryland|Massachusetts|Michigan|Mississippi|New Hampshire|New Jersey|New York|North Carolina|Ohio|Pennsylvania|Rhode Island|South Carolina|Tennessee|Vermont|Virginia|West Virginia|Wisconsin|DC|Pennsalvania|Virgina/; 

# 24 States WEST of Mississippi
my $westStates = qr/Alaska|Arizona|Arkansas|California|Colorado|Hawaii|Idaho|Iowa|Kansas|Louisiana|Minnesota|Missouri|Montana|Nebraska|Nevada|New Mexico|North Dakota|Oklahoma|Oregon|South Dakota|Texas|Utah|Washington|Wyoming/; 

my $monitorIt = qr/Network Core Infrastructure|Voice/;

my $locationsHouston = qr/Houston Chronicle/;
my $monitorCountry = qr/USA/;

my @serverList = qw(het001stropk002 het001sclopk002 het001houopk001 het044sloopk002 het044nmhopk001);

#het001stropk002 Virginia
#het001sclopk002 Santa Clara
#het001houopk001 Houston
#het044sloopk002 LD5 UK
#het044nmhopk001 Broadwick UK

makeNodes();

sub makeNodes {
	my $cmdb = loadCmdbData();

	print "ERRORS FOUND IN SOURCE DATA:\n";
	print Dumper \@ERROR;
	
	my $NODES;
	my $LOCATIONS;
	my $count;
	my $nodeCount = 0;
	my $dualPolled = 0;
	my $nodeSkipped = 0;
	
	foreach my $ci (sort keys %{$cmdb}) {
		#print "key=$ci ip=$cmdb->{$ci}{'CombinedIP'}\n";

		#which servers should manage this node?
		my @servers;
		
		my $community = '0d71d56ae6';		
		
		# clean the source data for bad things
		$cmdb->{$ci}{'HC-Division'} =~ s/Bussiness/Business/;
		$cmdb->{$ci}{'HC-Division'} =~ s/\&/and/;
		$cmdb->{$ci}{'Location State'} =~ s/Illionis/Illinois/;
		$cmdb->{$ci}{'Location State'} =~ s/Pennsalvania/Pennsylvania/;
		$cmdb->{$ci}{'Location State'} =~ s/Virgina/Virginia/;
		$cmdb->{$ci}{'CMDB Company'} =~ s/\&/and/;
		
		if ( $cmdb->{$ci}{'CombinedIP'} eq "" ) {
			print "ERROR: CombinedIP is blank key=$ci\n";
			++$nodeSkipped;
			next;
		}

		if ( $cmdb->{$ci}{'Node Status'} ne "alive"
			and $cmdb->{$ci}{'Node Status'} ne "in use"
		 ) {
			#print "INFO: Skipping key=$ci, CMDB Node Status is $cmdb->{$ci}{'Node Status'}\n";
			++$nodeSkipped;
			next;
		}


		if ( $cmdb->{$ci}{'TYPE Group'} !~ /$monitorIt/ ) {
			# skip devices which are not in the right type group.
			++$nodeSkipped;
			next;
		}
		#if ( $cmdb->{$ci}{'Location Country'} !~ /$monitorCountry/ ) {
			# skip devices which are not in these countries.
		#	next;
		#}
		if ( $cmdb->{$ci}{'PCI SITE?'} eq "" ) {
			print "ERROR: PCI SITE is blank key=$ci\n";
		}

		# get the name right.
		my $nodekey = $cmdb->{$ci}{'CMDB Name'};		
		if ( $cmdb->{$ci}{'CMDB Name'} eq "" and $cmdb->{$ci}{'Miguel Node Name'} ne "" ) {
			$nodekey = $cmdb->{$ci}{'Miguel Node Name'};
		}
		
		if ( $nodekey =~ /\./ and $nodekey !~ /^\d+\.\d+\.\d+\.\d+$/ ) {
			my @names = split(/\./,$nodekey);
			$nodekey = $names[0];
		}
		#print "$cmdb->{$ci}{'CMDB Name'} nodekey=$nodekey\n";
		
		# if the nodekey is blank, fall back to the IP address.
		if ( $nodekey eq "" ) {
			$nodekey = $cmdb->{$ci}{'CombinedIP'};
		}
		
		$nodekey =~ s/\/|\\|\?|\&/ /g;

		# replace crazy D0 long dash with -
		$nodekey =~ s/\xD0/-/g;
		$nodekey =~ s/\xCA//g;
		$nodekey =~ s/\s+$//g;
		$nodekey =~ s/^\s+//g;
		
		# get rid non-ascii characters
		#perl -pe 's/[^[:ascii:]]//g;'
		
		my $server;

  #'Cloud' => {
  #  'Address1' => '',
  #  'Address2' => '',
  #  'City' => '',
  #  'Country' => '',
  #  'Floor' => '',
  #  'Geocode' => 'St Louis, Misouri',
  #  'Latitude' => '38.612469',
  #  'Location' => 'Cloud',
  #  'Longitude' => '-90.198830',
  #  'Postcode' => '',
  #  'Room' => '',
  #  'State' => '',
  #  'Suburb' => ''
  #},

		# clean up the data!
		$cmdb->{$ci}{'Location Name'} =~ s/\xD0/-/g;
		$cmdb->{$ci}{'Location Address'} =~ s/\xD0/-/g;
		$cmdb->{$ci}{'Miguel LocationID'} = uc($cmdb->{$ci}{'Miguel LocationID'});

		my $location = "$cmdb->{$ci}{'Miguel LocationID'} $cmdb->{$ci}{'Location Name'}" || "Unknown";
		
		
		$LOCATIONS->{$location}{Location} = $location;
		$LOCATIONS->{$location}{Address1} = $cmdb->{$ci}{'Location Address'};
		$LOCATIONS->{$location}{City} = $cmdb->{$ci}{'Location City'};
		$LOCATIONS->{$location}{Country} = $cmdb->{$ci}{'Location Country'};
		$LOCATIONS->{$location}{Geocode} = "$cmdb->{$ci}{'Location Address'}, $cmdb->{$ci}{'Location City'}";
		
		
		my $roleType = "access";
		my $netType = "lan";

		if ( $cmdb->{$ci}{'Device Type'} =~ /Router|Wan Accelerator|MPLS Router/ ) {
			$netType = "wan";
		}

		if ( $cmdb->{$ci}{'Device Type'} =~ /Core|UCS|Data Storage/i ) {
			$roleType = "core";
		}
		elsif ( $cmdb->{$ci}{'Device Type'} =~ /MPLS Router|Netscaler|UCM/ ) {
			$roleType = "distribution";
		}

#het001stropk002 Virginia
#het001sclopk002 Santa Clara
#het001houopk001 Houston
#het044sloopk002 LD5 UK
#het044nmhopk001 Broadwick UK

		# if the device type includes CORE it is dual monitored.
		if ( $cmdb->{$ci}{'Location Country'} =~ /USA|CAN/ ) {
			if ( $cmdb->{$ci}{'Service Level'} eq "Gold"  ) {
				$roleType = "core";
				push(@servers,"het001stropk002");
				push(@servers,"het001sclopk002");
			}
			elsif ( $cmdb->{$ci}{'Location Name'} =~ /$locationsHouston/ ) {
				push(@servers,"het001houopk001");
				push(@servers,"het001sclopk002");
			}
			elsif ( $cmdb->{$ci}{'Location State'} =~ /$eastStates/ ) {
				$roleType = "access";
				push(@servers,"het001stropk002");
			}
			elsif ( $cmdb->{$ci}{'Location State'} =~ /$westStates/ ) {
				$roleType = "access";
				push(@servers,"het001sclopk002");
			}
			else {
				push(@servers,"het001stropk002");
				print "ERROR: USA no match: $nodekey $cmdb->{$ci}{'Location Name'} $cmdb->{$ci}{'Location State'}, managing with het001stropk002\n";
			}
		}
		elsif ( $cmdb->{$ci}{'Location Country'} =~ /GBR/ ) {
			$community = 'HearstUKpublic';
			
			if ( $nodekey =~ /hbmlonswcore|hbmexeswcore/ ) {
				$community = '0d71d56ae6';
			}
			
			if ( $cmdb->{$ci}{'Service Level'} eq "Gold"  ) {
				#$roleType = "core";
				push(@servers,"het044sloopk002");
				push(@servers,"het044nmhopk001");
			}
			elsif ( $cmdb->{$ci}{'Service Level'} eq "Silver"  ) {
				#$roleType = "core";
				push(@servers,"het044sloopk002");
				#push(@servers,"het044nmhopk001");
			}
		}
		if ( $cmdb->{$ci}{'SNMP String'} ne "" ) {
                         $community = $cmdb->{$ci}{'SNMP String'};
		}
	
		my $serverCount = 0;
		foreach my $server ( @servers ) {
			++$serverCount;
			#$netType = $newNodes{$node}{netType} if $newNodes{$node}{netType};
	
			#$NODES->{$server}{$nodekey}{customer} = $newNodes{$node}{group} || "NMIS8";
	
			#$NODES->{$server}{$nodekey}{businessService} = $newNodes{$node}{businessService} || "";
			#$NODES->{$server}{$nodekey}{serviceStatus} = $newNodes{$node}{serviceStatus} || "Production";
	
			#$NODES->{$server}{$nodekey}{rancid} = $newNodes{$node}{rancid} || 'false';
			
			if ( defined $NODES->{$server}{$nodekey} ) {
				print "WARNING: Duplicate node $nodekey $ci\n";
			}
	
			$NODES->{$server}{$nodekey}{roleType} = $roleType;
			$NODES->{$server}{$nodekey}{netType} = $netType;
			
			$NODES->{$server}{$nodekey}{name} = $nodekey;
			
			#$NODES->{$server}{$nodekey}{community} = 'H3T5nm9R3@d!';
			$NODES->{$server}{$nodekey}{community} = $community;
			$NODES->{$server}{$nodekey}{version} = 'snmpv2c';

			$NODES->{$server}{$nodekey}{active} = "true";
	
			# 10182015:MRH - Added support for the Ping only column, if 'x' don't collect
			if ( $cmdb->{$ci}{'Ping only'} eq "" ) {
				$NODES->{$server}{$nodekey}{collect} = 'true';
			}else{
				$NODES->{$server}{$nodekey}{collect} = 'false';
			}

			$NODES->{$server}{$nodekey}{host} = $cmdb->{$ci}{'CombinedIP'};
			$NODES->{$server}{$nodekey}{location} = $location || "default";
			$NODES->{$server}{$nodekey}{depend} = 'N/A';
			$NODES->{$server}{$nodekey}{services} = undef;
			$NODES->{$server}{$nodekey}{webserver} = 'false' ;
			$NODES->{$server}{$nodekey}{port} = '161';
			$NODES->{$server}{$nodekey}{ping} = 'true';
			$NODES->{$server}{$nodekey}{threshold} = 'true';
			$NODES->{$server}{$nodekey}{cbqos} = 'none';
			$NODES->{$server}{$nodekey}{calls} = 'false';
			$NODES->{$server}{$nodekey}{model} = 'automatic';
			$NODES->{$server}{$nodekey}{timezone} = 0 ;		

			# Hearst Data slotting.
			$NODES->{$server}{$nodekey}{customer} = $cmdb->{$ci}{'CMDB Company'} || "" ;								
			$NODES->{$server}{$nodekey}{group} = $cmdb->{$ci}{'HC-Division'} || "Unknown";
			$NODES->{$server}{$nodekey}{group} = "Unknown" if $NODES->{$server}{$nodekey}{group} eq "0";

			# Hearst Custom Fields should be included in Table-Nodes.nmis
			$NODES->{$server}{$nodekey}{serviceLevel} = $cmdb->{$ci}{'Service Level'} || "Unknown" ;		
			$NODES->{$server}{$nodekey}{deviceType} = $cmdb->{$ci}{'Device Type'} || "Unknown" ;		
			$NODES->{$server}{$nodekey}{nodeStatus} = $cmdb->{$ci}{'Node Status'} || "Unknown" ;		
			$NODES->{$server}{$nodekey}{typeGroup} = $cmdb->{$ci}{'TYPE Group'} || "Unknown" ;		
			if ( $cmdb->{$ci}{'PCI SITE?'} eq "y" ) {
				$NODES->{$server}{$nodekey}{pciSite} = "true"
			}
			elsif ( $cmdb->{$ci}{'PCI SITE?'} == 0 ) {
				$NODES->{$server}{$nodekey}{pciSite} = "false"
			}
			else {
				$NODES->{$server}{$nodekey}{pciSite} = "Unknown" ;		
			}

			if ( defined $count->{$server} ) {
				++$count->{$server};
			}
			else {
				$count->{$server} = 1;
			}
			
			if ( $serverCount > 1 ) {
				++$dualPolled;
			}
		} # foreach $server				
		++$nodeCount;
	}
	#print Dumper $LOCATIONS;
	writeHashtoFile(file=>"$locationsFile",data=>$LOCATIONS,handle=>undef);

	foreach my $server (@serverList) {
		my $file = "$nodesFile.$server";
		print "Saving $server nodes to $file\n";
		writeHashtoFile(file=>$file,data=>$NODES->{$server},handle=>undef);
	}
	
	print "Node Count : $nodeCount\n";
	print "Dual Polled: $dualPolled\n";
	print "Nodes Skipped: $nodeSkipped\n";
	#print Dumper $count;
	
}

sub loadCmdbData {
	my $cmdb = loadCSVR($cmdbFile,$cmdbKey,"\t");
	return $cmdb;
} 

sub loadCSVR {
	my $file = shift;
	my $key = shift;
	my $seperator = shift;
	my $reckey;
	my $line = 1;
	
	if ( ! defined $seperator ) { $seperator = "\t"; }

	my $passCounter = 0;

	my $i;
	my @rowElements;
	my @headers;
	my %headersHash;
	my @keylist;
	my $row;
	my $head;

	my %data;

	print "DEBUG: $file, $key, $seperator\n";

	open (DATAFILE, $file) or warn "Cannot open $file. $!";
	
	#my $DATA = <DATAFILE>;
	#my @LINES = split(/(\r|\n)/,$DATA);
	#foreach (@LINES) {
	local $/ = "\r";
	
	while (<DATAFILE>) {
		#chomp;
		#print "DEBUG: $passCounter $_\n\n";

		# If it is the first pass load the column headers into an array and a hash.
		if ( $_ !~ /^#|^;|^ / and $_ ne "" and $passCounter == 0 ) {
			++$passCounter;
			$_ =~ s/\"//g;
			@headers = split(/$seperator/, $_);
			for ( $i = 0; $i <= $#headers; ++$i ) {
				$headersHash{$headers[$i]} = $i;
			}
			#print Dumper @headers . "\n";
		}
		elsif ( $_ !~ /^#|^;|^ / and $_ ne "" and $passCounter > 0 ) {
			$_ =~ s/\"//g;
			@rowElements = split(/$seperator/, $_);
			if ( $key =~ /:/ ) {
				$reckey = "";
				@keylist = split(":",$key);
				for ($i = 0; $i <= $#keylist; ++$i) {
					#$reckey = $reckey.lc("$rowElements[$headersHash{$keylist[$i]}]");
					$reckey = $reckey.$rowElements[$headersHash{$keylist[$i]}];
					if ( $i < $#keylist )  { $reckey = $reckey."_" }
				}
			}
			else {
				#$reckey = lc("$rowElements[$headersHash{$key}]");
				$reckey = $rowElements[$headersHash{$key}];
			}
			
			if ( $#headers > 0 and $#headers != $#rowElements ) {
				$head = $#headers + 1;
				$row = $#rowElements + 1;
				push (@ERROR,"ERROR: $0 in csv.pm: Invalid CSV data file $file; line $line; record \"$reckey\"; $head elements in header; $row elements in data.\n");
			}
			#What if $reckey is blank could form an alternate key?
			if ( $reckey eq "" or $key eq "" ) {
				$reckey = join("-", @rowElements);
			}

			if ( defined $data{$reckey} ) {
				push (@ERROR,"ERROR: $0 in csv.pm: Duplicate Record in CSV data file $file; line $line; record \"$reckey\"\n");
			}
			for ($i = 0; $i <= $#rowElements; ++$i) {
				if ( $rowElements[$i] eq "null" ) { $rowElements[$i] = ""; }
				#if ( defined $data{$reckey}{$headers[$i]} ) {
				#	print STDERR "ERROR: $0 in csv.pm: Duplicate Record in CSV data file $file; line $line; record \"$reckey\"\n";
				#}
				$data{$reckey}{$headers[$i]} = $rowElements[$i];
			}
		}
		++$line;
	}
	close (DATAFILE);

	return \%data;
}

