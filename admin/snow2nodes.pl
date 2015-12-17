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

# For Use See: https://community.opmantek.com/display/opDev/Import+CMDB+Spreadsheet+to+NMIS%2C+opEvents+and+opConfig
#
# Fields in use
# HC-Division - 11/19 now mapping to Company (was used for Group) -> companies.u_hearst_business_unit
# MonitoringIP -> u_monitoring_ip
# TYPE Group -> device_types . u_category
# PCI SITE? Deprecated with move to CMDB
# CMDB Name -> name
# Miguel Node Name Deprecated with move to CMDB
# LocationID -> locations sys_id -> N/A not needed now.
# Location Name -> locations u_location_alias
# Location Address -> locations street
# Location City -> locations city
# Location State - Used to determine polling server in US -> locations state
# Location Country - Used to push UK devices to polling servers -> locations country
# Service Level - Gold dual polled, Silver single -> device_types.u_service_level
# Device Type -> device_type.u_name
# Ping only - Deprecated when we move to CMDB
# Node Status - Alive or In Use will be monitored install_status
# CMDB Company - 11/19 Deprecated with v32 of spreadsheet, replaced with HC-Division
# SNMP String - Used to override global defaults -> devices.u_snmp_string
# Division-Acronym - Concatenated with Location Name to create new Groups (i.e. HTV - WESH-TV)

# testing
# * dummy node should maintain its new NMIS properties, model and cbqos - PASS
# * when CMDB cache is updated dummy node should be detected as dummy and not included in Nodes.nmis files


# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
#use warnings;
use func;
use NMIS;
use NMIS::Timing;
use Data::Dumper;
use JSON::XS;
use HTTP::Tiny;
use Test::Deep::NoTest;
use Excel::Writer::XLSX;

my @ERROR;

# Variables for command line munging
my %arg = getArguements(@ARGV);

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will sync data from Service Now to this server.

usage: $0 run=(true|false) pull=(true|false) push=(true|false)
eg: $0 run=true (will only work off the cache)
or: $0 pull=true (will only pull the CMDB data to this server)
or: $0 push=true (will generate the data of the cache and push the Nodes.nmis out)
or: $0 pull=true push=true (will pull from CMDB and push the Nodes.nmis out)

EO_TEXT
	exit 1;
}

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $debug = setDebug($arg{debug});

# SNOW credentials
my $uname = "serviceaccountREST";
my $pword = "5erV%21ceN0w"; # escape the ! with %21
my $cmdb_server = "hearstet.service-now.com"; # "hearstetqa.service-now.com" "hearstmagstaging.service-now.com"

my $snowLog = "$C->{'<nmis_logs>'}/snow.log";

my $cmdbCache = "$C->{'<nmis_base>'}/database/cmdb";
my $xlsFile = "snow2nodes.xlsx";
my $xlsPath = "$cmdbCache/$xlsFile";

my $basedir = "$cmdbCache";
my $nodesFile = "$basedir/Nodes.nmis";
my $locationsFile = "$basedir/Locations.nmis";
my $customersFile = "$basedir/Customers.nmis";
my $devicesMetaFile = "$cmdbCache/devicesMeta.json";

my @cmdbTables = qw(locations devices companies device_types);

#mkdir /usr/local/nmis8/database/cmdb
#mkdir /usr/local/nmis8/database/cmdb/locations
#mkdir /usr/local/nmis8/database/cmdb/devices
#mkdir /usr/local/nmis8/database/cmdb/companies
#mkdir /usr/local/nmis8/database/cmdb/device_types
#mkdir /usr/local/nmis8/database/cmdb/servers

# 26 States EAST of Mississippi, PLUS DC and 2 misspelled from the spreadsheet
my $eastStates = qr/Alabama|AL|Connecticut|CT|Delaware|DE|Florida|FL|Georgia|GA|Illinois|IL|Indiana|IN|Kentucky|KY|Maine|ME|Maryland|MD|Massachusetts|MA|Michigan|MI|Mississippi|MS|New Hampshire|NH|New Jersey|NJ|New York|NY|North Carolina|NC|Ohio|OH|Pennsylvania|PA|Rhode Island|RI|South Carolina|SC|Tennessee|TN|Vermont|VT|Virginia|VA|West Virginia|WV|Wisconsin|WI|DC|Pennsalvania|Virgina/;

# 24 States WEST of Mississippi
my $westStates = qr/Alaska|AK|Arizona|AZ|Arkansas|AR|California|CA|Colorado|CO|Hawaii|HI|Idaho|ID|Iowa|IA|Kansas|KS|Louisiana|LA|Minnesota|MN|Missouri|MO|Montana|MT|Nebraska|NE|Nevada|NV|New Mexico|NM|North Dakota|ND|Oklahoma|OK|Oregon|OR|South Dakota|SD|Texas|TX|Utah|UT|Washington|WA|Wyoming|WY/;

# Only devices defined as these types are added for monitoring
my $monitorIt = qr/Network Core Infrastructure|Voice/;

# Only devices defined as these types are added for monitoring
my $stupidNodeNames = qr/^ic-204\./;

my $locationsHouston = qr/Houston Chronicle/;

#h et001stropk002 Virginia
# het001sclopk002 Santa Clara
# het001houopk001 Houston
# het044sloopk002 LD5 UK
# het044nmhopk001 Broadwick UK
my @serverList = qw(het001stropk002 het001sclopk002 het001houopk001 het044sloopk002);
my @masterList = qw(het001stropk001 het001sclopk001 het044sloopk001);

# Let's see how long this takes to process
my $t = NMIS::Timing->new();
print $t->elapTime(). " Begin Processing\n";

if ( $arg{pull} eq "true" ) {
	print $t->elapTime(). " RUN updateCmdbCache\n";
	updateCmdbCache();
	print $t->elapTime(). " DONE updateCmdbCache\n\n";
}
else {
	print "PULL not set to true. NOT PULLING CMDB DATA FROM Service Now\n";
}

print $t->elapTime(). " RUN updateCmdbIndex\n";
updateCmdbIndex();
print $t->elapTime(). " DONE updateCmdbIndex\n\n";

if ( $arg{pull} eq "true" ) {
	print $t->elapTime(). " RUN pullPollerNodeFiles\n";
	pullPollerNodeFiles();
	print $t->elapTime(). " DONE pullPollerNodeFiles\n\n";
}
else {
	print "PULL not set to true. NOT PULLING NODES FILE FROM POLLERS\n";
}

print $t->elapTime(). " RUN makeNodes\n";
makeNodes();
print $t->elapTime(). " DONE makeNodes\n\n";

if ( $arg{push} eq "true" ) {
	print $t->elapTime(). " RUN pushPollerNodeFiles\n";
	pushPollerNodeFiles();
	print $t->elapTime(). " DONE pushPollerNodeFiles\n\n";

	print $t->elapTime(). " RUN updateMasterServers\n";
	updateMasterServers();
	print $t->elapTime(). " DONE updateMasterServers\n\n";
}
else {
	print "PUSH not set to true. NOT PUSHING NODES FILE TO POLLERS\n";
}


print $t->elapTime(). " DONE!\n";

exit 1;


sub pullPollerNodeFiles {
	foreach my $server (@serverList) {
		print "Copy remote Nodes.nmis to $cmdbCache/servers/Nodes.nmis.$server\n";		
		my $out = `scp $server:/usr/local/nmis8/conf/Nodes.nmis $cmdbCache/servers/Nodes.nmis.$server`;
		print $out;
	}
}

sub pushPollerNodeFiles {
	foreach my $server (@serverList) {
		print "Backup the remote Nodes.nmis Customers.nmis and Locations.nmis file remotely\n";
		my $out = `ssh -t $server "cp -f /usr/local/nmis8/conf/Nodes.nmis /usr/local/nmis8/conf/Nodes.nmis.backup"`;
		print $out;
		my $out = `ssh -t $server "cp -f /usr/local/nmis8/conf/Customers.nmis /usr/local/nmis8/conf/Customers.nmis.backup"`;
		print $out;
		my $out = `ssh -t $server "cp -f /usr/local/nmis8/conf/Locations.nmis /usr/local/nmis8/conf/Locations.nmis.backup"`;
		print $out;

		print "Copy new Customers.nmis file to the remote server $server\n";		
		my $out = `scp $cmdbCache/Customers.nmis $server:/usr/local/nmis8/conf/Customers.nmis`;
		print $out;

		print "Copy new Locations.nmis file to the remote server $server\n";		
		my $out = `scp $cmdbCache/Locations.nmis $server:/usr/local/nmis8/conf/Locations.nmis`;
		print $out;

		print "Copy newly merged Nodes.nmis file to the remote server $server\n";		
		my $out = `scp $cmdbCache/Nodes.nmis.$server $server:/usr/local/nmis8/conf/Nodes.nmis`;
		print $out;

		print "Update the remote server group list with the needed groups from the local server\n";
		my $out = `ssh -t $server "/usr/local/nmis8/admin/grouplist.pl patch=true"`;
		print $out;
	}
}

sub updateMasterServers {
	foreach my $server (@masterList) {
		print "Update the master server group list with the needed groups from the local server\n";
		my $out = `ssh -t $server "/usr/local/nmis8/admin/grouplist.pl patch=true"`;
		print $out;
	}
}


########################################################
#
# LOCAL SUBROUTINES
#
########################################################

sub updateCmdbIndex {
	my $indexFile = "$cmdbCache/index.json";
	my $cmdbIndex;
	foreach my $table (@cmdbTables) {
		print "Updating index for table $table\n";
		my $dir = "$cmdbCache/$table";
		if ( -d $dir ) {
 			opendir (DIR, "$dir");
			my @dirlist = readdir DIR;
			closedir DIR;

			foreach my $file (@dirlist) {
				if ( $file =~ /\.json$/ ) {
					my $data = loadFile("$dir/$file");
					#print Dumper $data;
					my $sys_id = $data->{sys_id};
					my $name = undef;
					if ( defined($data->{name}) and $data->{name} ne "" ) {
						$name = $data->{name};
					}
					else {
						$name = $data->{u_name};
					}
					$name =~ s/[^[:ascii:]]//g;

					if ( not defined($name) or $name eq "" ) {
						my $exception = "ERROR";
						$exception = "WARNING" if $table eq "devices";
						logSnow("$exception: $table BLANK name sys_id=$sys_id file=$file");
					}
					else {
						if ( not defined $cmdbIndex->{$table}{name}{$name} ) {
							# new record
							$cmdbIndex->{$table}{name}{$name} = $sys_id;
							$cmdbIndex->{$table}{sys_id}{$sys_id} = $name;
						}
						else {
							# name duplicate!
							logSnow("WARNING: $table DUPLICATE name $name sys_id1=$cmdbIndex->{$table}{name}{$name} sys_id2=$sys_id");
						}
					}

					if ( $table eq "devices" ) {
						my $u_monitoring_ip = $data->{u_monitoring_ip};

						if ( $u_monitoring_ip eq "" ) {
							logSnow("ERROR: $table BLANK u_monitoring_ip sys_id=$sys_id file=$file");
						}
						else {
							if ( not defined $cmdbIndex->{$table}{u_monitoring_ip}{$u_monitoring_ip} ) {
								# new record
								$cmdbIndex->{$table}{u_monitoring_ip}{$u_monitoring_ip} = $sys_id;
							}
							else {
								# u_monitoring_ip duplicate!
								logSnow("ERROR: $table DUPLICATE u_monitoring_ip $u_monitoring_ip sys_id1=$cmdbIndex->{$table}{u_monitoring_ip}{$u_monitoring_ip} sys_id2=$sys_id");
							}
						}
					}
				}
			}
		}
	}
	print "Saving index to file $indexFile\n";
	saveFile($indexFile,$cmdbIndex,1);
}

sub updateCmdbCache {
	print "Getting locations\n";
	my $locations = getLocations(); # deviceList/location > locations/sys_id
	#print "Saving locations\n";
	#saveFile("$cmdbCache/locations.json",$locations);

	print "Getting companies\n";
	my $companies = getCompanies(); # deviceList/company > companies/sys_id
	#print "Saving companies\n";
	#saveFile("$cmdbCache/companies.json",$companies);

	print "Getting device_types\n";
	my $device_types = getDeviceTypes(); # deviceList/u_device_type > device_types/sys_id
	#print "Saving device_types\n";
	#saveFile("$cmdbCache/device_types.json",$device_types);

	print "Getting devices\n";
	my $deviceList = getDevices();
	#print "Saving devices\n";
	#saveFile("$cmdbCache/devicesList.json",$deviceList);
}

sub loadCmdbCache {
	my $indexFile = "$cmdbCache/index.json";
	my $cmdb;
	my $cmdbIndex;

	foreach my $table (@cmdbTables) {
		my $dir = "$cmdbCache/$table";
		if ( -d $dir ) {
 			opendir (DIR, "$dir");
			my @dirlist = readdir DIR;
			closedir DIR;

			foreach my $file (sort @dirlist) {
				if ( $file =~ /\.json$/ ) {
					my $data = loadFile("$dir/$file");
					#print Dumper $data;
					my $sys_id = $data->{sys_id};

					if ( not defined $cmdb->{$table}{$sys_id} ) {
						# new record
						$cmdb->{$table}{$sys_id} = $data;
					}
					else {
						# sys_id duplicate, this should never happen!
						logSnow("ERROR: $table DUPLICATE sys_id sys_id1=$cmdb->{$table}{$sys_id}{sys_id} sys_id2=$sys_id");
					}

				}
			}
		}
	}
	
	# load the devicesMeta and delete any nodes from the cache which are not active.
	
	return $cmdb;
}

sub loadAllNodes {
	my $NODES;

	foreach my $server (@serverList) {
		my $file = "$cmdbCache/servers/Nodes.nmis.$server";
		if ( -f $file ) {
			$NODES->{$server} = readFiletoHash(file => $file, json => 0);
		}
		else {
			print "ERROR: loadAllNodes problem loading $file\n";
		}
	}	
	return $NODES;
}

sub makeNodes {
	my $cmdb = loadCmdbCache();

	my $NODES = loadAllNodes();	
	
	my $devicesMeta;
	if ( -f $devicesMetaFile ) {
		$devicesMeta = loadFile($devicesMetaFile);
	}
	else {
		die "CATASTROPHIC ERROR: can not proceed without valid $devicesMetaFile data\n";
	}
		
	my $GROUPS;
	my $LOCATIONS;
	my $CUSTOMERS;
	my $count;
	my $nodeCount = 0;
	my $dualPolled = 0;
	my $nodeSkipped = 0;
	my $errorSkipped = 0;
	my $deleteNmis = 0;
	my $notInCmdb = 0;
	my $dataErrors = 0;

	print $t->markTime(). " Building Node Files\n";

	my $xls;
	if ($xlsPath) {
		$xls = start_xlsx(file => $xlsPath);
	}

	my @headings = qw(uuid name host community group customer serviceLevel deviceType typeGroup location address city state country server); #MRH
	my $sheet = add_worksheet(xls => $xls, title => "devices", columns => \@headings);
	my $currow = 1;

	foreach my $sys_id (sort keys %{$cmdb->{devices}}) {
		my $thisDevice = $cmdb->{devices}{$sys_id};

		my $locationOk = 1;
		my $locationSysid = $thisDevice->{'u_location_id'};
		if ( not defined $cmdb->{locations}{$locationSysid} ) {
			logSnow("ERROR: Device $sys_id MISSING location found for u_location_id $locationSysid");
			$locationOk = 0;
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		my $thisLocation = $cmdb->{locations}{$locationSysid};

		my $deviceTypeSysId = $thisDevice->{'u_device_type'};
		if ( not defined $cmdb->{device_types}{$deviceTypeSysId} ) {
			logSnow("ERROR: Device $sys_id MISSING device_types found for u_device_type $deviceTypeSysId");
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		my $thisType = $cmdb->{device_types}{$deviceTypeSysId};

		my $companySysid;
		my $thisCompany;

		if ( $thisDevice->{'company'} ) {
			$companySysid = $thisDevice->{'company'};
			if ( not defined $cmdb->{companies}{$companySysid} ) {
				logSnow("ERROR: Device $sys_id MISSING companies details for company $companySysid");
				++$dataErrors;
				++$errorSkipped;
				next;
			}
			$thisCompany = $cmdb->{companies}{$companySysid};
		}
		else {
			logSnow("ERROR: Device $sys_id MISSING company definition");
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		
		# what data do we rely on!
		if ( $locationOk and ( not defined $thisLocation->{'u_location_alias'} or $thisLocation->{'u_location_alias'} eq "" ) ) {
			logSnow("ERROR: $thisLocation->{sys_id} $thisLocation->{'name'} MISSING location name (u_location_alias)");
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		else {
			#print "DEBUG locationOk=$locationOk u_location_alias=$thisLocation->{'u_location_alias'}\n";		
		}

		if ( $locationOk and ( not defined $thisLocation->{'country'} or $thisLocation->{'country'} eq "" ) ) {
			logSnow("ERROR: $thisLocation->{sys_id} $thisLocation->{'u_location_alias'} MISSING location country");
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		else {
			#print "DEBUG locationOk=$locationOk country=$thisLocation->{'country'}\n";		
		}

		if ( $locationOk and $thisLocation->{'country'} ne "GBR" and ( not defined $thisLocation->{'state'} or $thisLocation->{'state'} eq "" ) ) {
			logSnow("ERROR: $thisLocation->{sys_id} $thisLocation->{'u_location_alias'} MISSING location state");
			++$dataErrors;
			++$errorSkipped;
			next;
		}
		else {
			#print "DEBUG locationOk=$locationOk state=$thisLocation->{'state'}\n";		
		}

		if ( $thisDevice->{'install_status'} != 1 ) {
			#print "INFO: Skipping key=$sys_id, CMDB install_status is $thisDevice->{'install_status'}\n";
			++$dataErrors;
		}

		#print "key=$sys_id ip=$thisDevice->{'u_monitoring_ip'}\n";

		#which servers should manage this node?
		my @servers;

		my $community = '0d71d56ae6';

		# clean the source data for bad things
		$thisCompany->{'u_hearst_business_unit'} =~ s/Bussiness/Business/;
		$thisCompany->{'u_hearst_business_unit'} =~ s/\&/and/;

		$thisLocation->{'state'} =~ s/Illionis/Illinois/;
		$thisLocation->{'state'} =~ s/Pennsalvania/Pennsylvania/;
		$thisLocation->{'state'} =~ s/Virgina/Virginia/;
		# $thisDevice->{'CMDB Company'} =~ s/\&/and/;

		if ( $thisDevice->{'u_monitoring_ip'} eq "" ) {
			logSnow("ERROR: u_monitoring_ip is blank sys_id=$sys_id");
			++$dataErrors;
		}

		if ( $thisType->{'u_category'} !~ /$monitorIt/ ) {
			# skip devices which are not in the right type group.
			++$nodeSkipped;
			next;
		}

		# get the name right.
		my $nodekey = getNodeName($thisDevice->{'name'},$thisDevice->{'u_monitoring_ip'});
		
		my $server;

		# clean up the data!
		$thisLocation->{'u_location_alias'} =~ s/\xD0/-/g;
		$thisLocation->{'u_location_alias'} =~ s/\x{7DD}/-/g;
		$thisLocation->{'u_location_alias'} =~ s/[^[:ascii:]]/-/g;
		
		$thisLocation->{'u_location_alias'} =~ s/,//g;
		$thisLocation->{'u_location_alias'} =~ s/\//-/g;
		$thisLocation->{'street'} =~ s/\xD0/-/g;
		
		#\x{2013}

		my $location = "$thisLocation->{'u_location_alias'}" || "Unknown";

		$LOCATIONS->{$location}{Location} = $location;
		$LOCATIONS->{$location}{Address1} = $thisLocation->{'street'};
		$LOCATIONS->{$location}{City} = $thisLocation->{'city'};
		$LOCATIONS->{$location}{State} = $thisLocation->{'state'}; #MRH 12112015
		$LOCATIONS->{$location}{Country} = $thisLocation->{'country'};
		$LOCATIONS->{$location}{Geocode} = "$thisLocation->{'street'}, $thisLocation->{'city'}";

		my $roleType = "access";
		my $netType = "lan";

		if ( $thisType->{'u_name'} =~ /Router|Wan Accelerator|MPLS Router/ ) {
			$netType = "wan";
		}

		if ( $thisType->{'u_name'} =~ /Core|UCS|Data Storage/i ) {
			$roleType = "core";
		}
		elsif ( $thisType->{'u_name'} =~ /MPLS Router|Netscaler|UCM/ ) {
			$roleType = "distribution";
		}

		#het001stropk002 Virginia
		#het001sclopk002 Santa Clara
		#het001houopk001 Houston
		#het044sloopk002 LD5 UK
		#het044nmhopk001 Broadwick UK

		# if the device type includes CORE it is dual monitored.
		if ( $thisLocation->{'country'} =~ /USA|CAN/ ) {
			if ( $thisType->{'u_service_level'} eq "Gold"  ) {
				# $roleType = "core";
				push(@servers,"het001stropk002");
				push(@servers,"het001sclopk002");
			}
			elsif ( $thisLocation->{'u_location_alias'} =~ /$locationsHouston/ ) {
				push(@servers,"het001houopk001");
				push(@servers,"het001sclopk002");
			}
			elsif ( $thisLocation->{'state'} =~ /$eastStates/ ) {
				# $roleType = "access";
				push(@servers,"het001stropk002");
			}
			elsif ( $thisLocation->{'state'} =~ /$westStates/ ) {
				# $roleType = "access";
				push(@servers,"het001sclopk002");
			}
			else {
				push(@servers,"het001stropk002");
				logSnow("ERROR: USA no match: $nodekey $thisLocation->{'u_location_alias'} $thisLocation->{'state'}, managing with het001stropk002");
			}
		}
		elsif ( $thisLocation->{'country'} =~ /GBR/ ) {
			$community = 'HearstUKpublic';

			if ( $nodekey =~ /hbmlonswcore|hbmexeswcore/ ) {
				$community = '0d71d56ae6';
			}

			if ( $thisType->{'u_service_level'} eq "Gold"  ) {
				#$roleType = "core";
				push(@servers,"het044sloopk002");
			}
			elsif ( $thisType->{'u_service_level'} eq "Silver"  ) {
				#$roleType = "core";
				push(@servers,"het044sloopk002");
			}
		}
		if ( $thisDevice->{'u_snmp_string'} ne "" ) {
			$community = $thisDevice->{'u_snmp_string'};
		}

		my $serverCount = 0;
		foreach my $server ( @servers ) {
			++$serverCount;
			my @columns;
			#$netType = $newNodes{$node}{netType} if $newNodes{$node}{netType};

			#$NODES->{$server}{$nodekey}{customer} = $newNodes{$node}{group} || "NMIS8";

			#$NODES->{$server}{$nodekey}{businessService} = $newNodes{$node}{businessService} || "";
			#$NODES->{$server}{$nodekey}{serviceStatus} = $newNodes{$node}{serviceStatus} || "Production";

			#$NODES->{$server}{$nodekey}{rancid} = $newNodes{$node}{rancid} || 'false';

			#if ( defined $NODES->{$server}{$nodekey} ) {
			#	print "WARNING: Duplicate node $nodekey $server $sys_id\n";
			#}
			
			$NODES->{$server}{$nodekey}{roleType} = $roleType;
			$NODES->{$server}{$nodekey}{netType} = $netType;

			$NODES->{$server}{$nodekey}{name} = $nodekey;

			#$NODES->{$server}{$nodekey}{community} = 'H3T5nm9R3@d!';
			$NODES->{$server}{$nodekey}{community} = $community;


			# this data is from the CMDB
			$NODES->{$server}{$nodekey}{uuid} = $thisDevice->{'sys_id'};
			$NODES->{$server}{$nodekey}{host} = $thisDevice->{'u_monitoring_ip'};
			$NODES->{$server}{$nodekey}{location} = $location || "default";
			$NODES->{$server}{$nodekey}{source} = "Service Now";
			# forcing active and collect to true for these nodes
			$NODES->{$server}{$nodekey}{active} = "true";
			$NODES->{$server}{$nodekey}{collect} = "true";

			# this data is preserved if already done in the nodes file
			$NODES->{$server}{$nodekey}{version} = $NODES->{$server}{$nodekey}{version} || 'snmpv2c';
			$NODES->{$server}{$nodekey}{depend} = $NODES->{$server}{$nodekey}{depend} || 'N/A';
			$NODES->{$server}{$nodekey}{services} = $NODES->{$server}{$nodekey}{services} || undef;
			$NODES->{$server}{$nodekey}{webserver} = $NODES->{$server}{$nodekey}{webserver} || 'false';
			$NODES->{$server}{$nodekey}{port} = $NODES->{$server}{$nodekey}{port} || '161';
			$NODES->{$server}{$nodekey}{ping} = $NODES->{$server}{$nodekey}{ping} || 'true';
			$NODES->{$server}{$nodekey}{threshold} = $NODES->{$server}{$nodekey}{threshold} || 'true';
			$NODES->{$server}{$nodekey}{cbqos} = $NODES->{$server}{$nodekey}{cbqos} || 'none';
			$NODES->{$server}{$nodekey}{calls} = $NODES->{$server}{$nodekey}{calls} || 'false';
			$NODES->{$server}{$nodekey}{model} = $NODES->{$server}{$nodekey}{model} || 'automatic';
			$NODES->{$server}{$nodekey}{timezone} = $NODES->{$server}{$nodekey}{timezone} || 0;

			# Hearst Data slotting.
			# MRH updated Company definition 11/19 per Jim Bazzano
			$NODES->{$server}{$nodekey}{customer} = $thisCompany->{'u_hearst_business_unit'} || "" ;

			my $shortName = getDivisionAcronym($thisCompany->{'u_hearst_business_unit'});

			# MRH updated Group definition 11/19 per Jim Bazzano
			if ( $shortName and $thisLocation->{'u_location_alias'} ) {
				$NODES->{$server}{$nodekey}{group} ="$shortName $thisLocation->{'u_location_alias'}";
			}
			elsif ( $thisLocation->{'u_location_alias'} ) {
				$NODES->{$server}{$nodekey}{group} = "$thisLocation->{'u_location_alias'}";
			}
			else {
				$NODES->{$server}{$nodekey}{group} = "Unknown";
			}

			$NODES->{$server}{$nodekey}{group} = "Unknown" if $NODES->{$server}{$nodekey}{group} eq "0";
			$GROUPS->{$NODES->{$server}{$nodekey}{group}} = $NODES->{$server}{$nodekey}{group};

			# Hearst Custom Fields should be included in Table-Nodes.nmis
			$NODES->{$server}{$nodekey}{serviceLevel} = $thisType->{'u_service_level'} || "Unknown" ;
			$NODES->{$server}{$nodekey}{deviceType} = $thisType->{'u_name'} || "Unknown" ;
			$NODES->{$server}{$nodekey}{nodeStatus} = $thisDevice->{'install_status'} || "Unknown" ;
			$NODES->{$server}{$nodekey}{typeGroup} = $thisType->{'u_category'} || "Unknown" ;

			push(@columns,$NODES->{$server}{$nodekey}{uuid});
			push(@columns,$NODES->{$server}{$nodekey}{name});
			push(@columns,$NODES->{$server}{$nodekey}{host});
			push(@columns,$NODES->{$server}{$nodekey}{community});
			push(@columns,$NODES->{$server}{$nodekey}{group});
			push(@columns,$NODES->{$server}{$nodekey}{customer});
			push(@columns,$NODES->{$server}{$nodekey}{serviceLevel});
			push(@columns,$NODES->{$server}{$nodekey}{deviceType});
			push(@columns,$NODES->{$server}{$nodekey}{typeGroup});

			push(@columns,$NODES->{$server}{$nodekey}{location});
			push(@columns,$LOCATIONS->{$location}{Address1});
			push(@columns,$LOCATIONS->{$location}{City});
			push(@columns,$LOCATIONS->{$location}{State}); #MRH
			push(@columns,$LOCATIONS->{$location}{Country});

			push(@columns,$server);

		  #'PACK' => {
		  #  'customer' => 'PACK',
		  #  'description' => undef,
		  #  'groups' => 'DataCenter,Sales,WAN,xAN',
		  #  'locations' => 'Cloud,DataCenter,HeadOffice'
		  #}
  		my $customer = $NODES->{$server}{$nodekey}{customer};
			if ( not exists $CUSTOMERS->{$customer} ) {
				# a new never seen before customer!  add them.
				$CUSTOMERS->{$customer}{customer} = $NODES->{$server}{$nodekey}{customer};
				$CUSTOMERS->{$customer}{groups} = $NODES->{$server}{$nodekey}{group};
				$CUSTOMERS->{$customer}{locations} = $NODES->{$server}{$nodekey}{location};
			}
			else {
				# a previously seen customer, append the group and location to the list of things
				if ( $CUSTOMERS->{$customer}{groups} !~ /$NODES->{$server}{$nodekey}{group}/ ) {
					$CUSTOMERS->{$customer}{groups} .= ",$NODES->{$server}{$nodekey}{group}";
				}
				if ( $CUSTOMERS->{$customer}{locations} !~ /$NODES->{$server}{$nodekey}{location}/ ) {
					$CUSTOMERS->{$customer}{locations} .= ",$NODES->{$server}{$nodekey}{location}";
				}
			}

			if ($sheet) {
				$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
				++$currow;
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

	# cross check the NMIS nodes files data and see if any nodes exist which are not in the devicesMeta
	foreach my $server (@serverList) {
		foreach my $node ( sort keys %{$NODES->{$server}} ) {			
			# According to NMIS I have a valid node, check the devicesMeta to see if it is active.
			if ( defined $devicesMeta->{name}{$node} and $devicesMeta->{name}{$node}{sys_id} ne "" ) {
				my $meta_sys_id = $devicesMeta->{name}{$node}{sys_id};
				if ( not $devicesMeta->{sys_id}{$meta_sys_id}{active} ) {
					print "INFO: $node $meta_sys_id is NOT ACTIVE, it will be expunged from the NMIS record.\n";
					# this node should be delete from NMIS.
					logSnow("INFO: $node $NODES->{$server}{$node}{uuid} being deleted from $server Nodes file");
					delete $NODES->{$server}{$node};
					++$deleteNmis;
				}
			}
			else {
				logSnow("INFO: $node $NODES->{$server}{$node}{uuid} not found in CMDB sync, must have been manually added.");
				++$notInCmdb;
			}
		}
	}

	#print Dumper $LOCATIONS;
	print "Saving locationsFile to $locationsFile\n";
	writeHashtoFile(file=>"$locationsFile",data=>$LOCATIONS,handle=>undef);

	print "Saving customersFile to $customersFile\n";
	writeHashtoFile(file=>"$customersFile",data=>$CUSTOMERS,handle=>undef);

	foreach my $server (@serverList) {
		my $file = "$nodesFile.$server";
		print "Saving $server nodes to $file\n";
		writeHashtoFile(file=>$file,data=>$NODES->{$server},handle=>undef);
	}

	end_xlsx(xls => $xls);

	# MRH - 11/20/2015, v32 spreadsheet Group definition change
	# Create a list of unique Groups as defined by the new file

	my @GROUPLIST;
		foreach my $GROUP (sort keys %{$GROUPS}) {
			push(@GROUPLIST,$GROUP);
		}
	my $group_list = join(",",@GROUPLIST);

	#print "The following is the list of groups for the NMIS Config file Config.nmis\n";
	#print "'group_list' => '$group_list',\n";

	print "Node Count : $nodeCount\n";
	print "Dual Polled: $dualPolled\n";
	print "Nodes Deleted from NMIS: $deleteNmis\n";
	print "Nodes Not in CMDB: $notInCmdb\n";
	print "Nodes Skipped with Error: $errorSkipped\n";
	print "Nodes Skipped: $nodeSkipped - u_category does not match $monitorIt\n";
	print "Data Errors: $dataErrors\n";
	print "Done in ".$t->deltaTime() ."\n";

	print "\nInfo, Errors, and exceptions logged to $snowLog\n";

	#print Dumper $count;

}

sub getNodeName {
	my $name = shift;
	my $u_monitoring_ip = shift;
	
	my $nodekey = $name;

	if ( $nodekey =~ /\./ and $nodekey !~ /^\d+\.\d+\.\d+\.\d+$/ and $nodekey !~ /$stupidNodeNames/ ) {
		my @names = split(/\./,$nodekey);
		$nodekey = $names[0];
	}

	# if the nodekey is blank, fall back to the IP address.
	if ( $nodekey eq "" ) {
		$nodekey = $u_monitoring_ip;
	}

	$nodekey =~ s/\/|\\|\?|\&/ /g;

	# replace crazy D0 long dash with -
	$nodekey =~ s/\xD0/-/g;
	$nodekey =~ s/\xCA//g;
	$nodekey =~ s/\s+$//g;
	$nodekey =~ s/^\s+//g;

	# get rid non-ascii characters
	$nodekey =~ s/[^[:ascii:]]//g;
	
	return $nodekey;
}

sub getDivisionAcronym {
	my $longName = shift;
	my $shortName;

	# MRH - Updated 12102015 from Master NW Data40.xlxs, Hearst Divisions tab
	if    ( $longName eq "Hearst Business Media" ) { $shortName = "HBM" }
	elsif ( $longName eq "Hearst Television" ) { $shortName = "HTV" }
	elsif ( $longName eq "Hearst Broadcasting" ) { $shortName = "HTV" }	 # This is a backup from Miguel's spreadsheet
	elsif ( $longName eq "Hearst Newspapers" ) { $shortName = "HNP" }
	elsif ( $longName eq "CDS Global" ) { $shortName = "CDS" } # This is not on the spreadsheet
	elsif ( $longName eq "Hearst Magazines Division" ) { $shortName = "HMD" }
	elsif ( $longName eq "Hearst Corporation" ) { $shortName = "HCD" }
	elsif ( $longName eq "Hearst Corporate Division" ) { $shortName = "HCD" }	 # This is a backup from Miguel's spreadsheet
	elsif ( $longName eq "Hearst Magazines International" ) { $shortName = "HMI" }
	elsif ( $longName eq "Hearst Service Center" ) { $shortName = "HSC" }
	elsif ( $longName eq "Hearst Entertainment Division" ) { $shortName = "HED" }
	elsif ( $longName eq "Hearst Real Estate" ) { $shortName = "HRE" }
	elsif ( $longName eq "The Hearst Foundation" ) { $shortName = "THF" }
	elsif ( $longName eq "Hearst Venture Division" ) { $shortName = "HVC" }

	return $shortName;
}

sub getLocations {
	# Retrieve Location table and store...

	#this is the default SNMO location table; Hearst is overriding
	# my $locUrl = "https://$uname:$pword\@hearstmagstaging.service-now.com/imp_location.do?JSONv2";
	print $t->markTime(). " Retrieving cmn_location table\n";
	my $locUrl = "https://$uname:$pword\@$cmdb_server/cmn_location.do?JSONv2";
	my $ht = HTTP::Tiny->new;
	my $response = $ht->request('GET', $locUrl);
	if ($response->{success}) {
		my $decoded_json = decode_json $response->{content};

		my @fields = qw(sys_id name street city state country);
		my $count = 0;
		my $onething;
		foreach my $record ( @{$decoded_json->{records}}) {
			# get a unique file name.
			my $recordFile = "$cmdbCache/locations/$record->{sys_id}.json";

			# does the record already exist?
			if ( -f $recordFile ) {
				# load it and compare to what you just got from CMDB
				my $cacheRecord = loadFile($recordFile);

				if (not eq_deeply($record, $cacheRecord)) {
				  logSnow("INFO: locations CHANGE detected with $record->{sys_id}");
				  saveFile($recordFile,$record);
				}
			}
			else {
				# it doesn't so create it!
				logSnow("INFO: locations CREATE new record $record->{sys_id}");
				saveFile($recordFile,$record);
			}

			my @data;
			++$count;
			foreach my $field (@fields) {
				push(@data,$record->{$field});
			}
			$onething = join("\t",@data);
			print "$count: $onething\n" if $debug > 1;

		}
		print "Total Locations returned: $count\n";
		print "Done in ".$t->deltaTime() ."\n";
		return $decoded_json->{records};

	} else {
		print "Connection Failed: $response->{status}\nReason: $response->{reason}";
	}

	return 0;
}

sub getCompanies {
	# Retrieve Company table and store...
	print $t->markTime(). " Retrieving core_company table\n";

	my $companyUrl = "https://$uname:$pword\@$cmdb_server/core_company.do?JSONv2&sysparm_query=active=true^u_hearst_business_unit%21=%22%22";
	my $ht = HTTP::Tiny->new;
	my $response = $ht->request('GET', $companyUrl);
	if ($response->{success}) {
		my $decoded_json = decode_json $response->{content};
		#print Dumper $decoded_json->{records}; # This works here; prints the entire hash

		my @fields = qw(sys_id u_hearst_business_unit name);
		my $count = 0;
		my $onething;
		foreach my $record ( @{$decoded_json->{records}}) {
			# get a unique file name.
			my $recordFile = "$cmdbCache/companies/$record->{sys_id}.json";

			# does the record already exist?
			if ( -f $recordFile ) {
				# load it and compare to what you just got from CMDB
				my $cacheRecord = loadFile($recordFile);

				if (not eq_deeply($record, $cacheRecord)) {
				  logSnow("INFO: companies CHANGE detected with $record->{sys_id}");
				  saveFile($recordFile,$record);
				}
			}
			else {
				# it doesn't so create it!
				logSnow("INFO: companies CREATE new record $record->{sys_id}");
				saveFile($recordFile,$record);
			}

			my @data;
			++$count;
			foreach my $field (@fields) {
				push(@data,$record->{$field});
			}
			$onething = join("\t",@data);
			print "$count: $onething\n" if $debug > 1;

		}
		print "Total Company companies returned: $count\n";
		print "Done in ".$t->deltaTime() ."\n";
		return $decoded_json->{records};

	} else {
		print "Connection Failed: $response->{status}\nReason: $response->{reason}";
	}

	return 0;
}

sub getDeviceTypes {
	# Retrieve device types table and store...

	print $t->markTime(). " Retrieving U_device_types table\n";
	my $typesUrl = "https://$uname:$pword\@$cmdb_server/u_device_types.do?JSONv2";
	my $ht = HTTP::Tiny->new;
	my $response = $ht->request('GET', $typesUrl);
	if ($response->{success}) {
		my $decoded_json = decode_json $response->{content};
		# print Dumper $decoded_json->{records}; # This works here; prints the entire hash

		my @fields = qw(sys_id u_name u_category u_service_level);
		my $count = 0;
		my $onething;

		foreach my $record ( @{$decoded_json->{records}}) {
			# get a unique file name.
			my $recordFile = "$cmdbCache/device_types/$record->{sys_id}.json";

			# does the record already exist?
			if ( -f $recordFile ) {
				# load it and compare to what you just got from CMDB
				my $cacheRecord = loadFile($recordFile);

				if (not eq_deeply($record, $cacheRecord)) {
				  logSnow("INFO: device_types CHANGE detected with $record->{sys_id}");
				  saveFile($recordFile,$record);
				}
			}
			else {
				# it doesn't so create it!
				logSnow("INFO: device_types CREATE new record $record->{sys_id}");
				saveFile($recordFile,$record);
			}

			my @data;
			++$count;
			foreach my $field (@fields) {
				push(@data,$record->{$field});
			}
			$onething = join("\t",@data);
			print "$count: $onething\n" if $debug > 1;

		}
		print "Total DeviceTypes returned: $count\n";
		print "Done in ".$t->deltaTime() ."\n";
		return $decoded_json->{records};

	} else {
		print "Connection Failed: $response->{status}\nReason: $response->{reason}";
	}

	return 0;
}

sub getDevices {
	
	# load my cache devices meta data indexy thing. if it doesn't exist it will be created.
	my $devicesMeta;
	if ( -f $devicesMetaFile ) {
		$devicesMeta = loadFile($devicesMetaFile);
		# reset the active flag on all records to 0, the code below will mark things from api as active = 1
		foreach my $sys_id ( keys %{$devicesMeta->{sys_id}} ) {
			$devicesMeta->{sys_id}{$sys_id}{active} = 0;
		}
	}
	
	# Sample URLS for testing,
	# "https://$uname:$pword\@$cmdb_server/cmdb_ci.do?JSONv2&sysparm_query=active=true^install_status=1"
	# "https://$uname:$pword\@$cmdb_server/cmdb_ci_ip_router.do?JSONv2&sysparm_query=active=true^name=217-c7206-1"
	# "https://$uname:$pword\@$cmdb_server/cmdb_ci.do?JSONv2&sysparm_display_value=true&sysparm_query=active=true^install_status=1^u_monitoring_ip%21=%22%22"

	# Retrieve all device entries where install_status=1 (in_use) and u_monitoring_ip != ""
	print $t->markTime(). " Retrieving Devices from cmdb_ci\n";
	#active eq true AND install_status=1 AND u_monitoring_ip ne ""
	#my $deviceUrl = "https://$uname:$pword\@$cmdb_server/cmdb_ci.do?JSONv2&sysparm_display_value=true&sysparm_query=active=true^install_status=1^u_monitoring_ip%21=%22%22";
	
	#u_device_type ne "" AND install_status=1 AND u_monitoring_ip ne ""
	my $deviceUrl = "https://$uname:$pword\@$cmdb_server/cmdb_ci.do?JSONv2&sysparm_display_value=true&sysparm_query=^u_device_type%21=%22%22^install_status=1^u_monitoring_ip%21=%22%22";
	
	#u_device_type ne ""
	#my $deviceUrl = "https://$uname:$pword\@$cmdb_server/cmdb_ci.do?JSONv2&sysparm_display_value=true&sysparm_query=u_device_type%21=%22%22";
	
	my $ht = HTTP::Tiny->new;
	my $response = $ht->request('GET', $deviceUrl);
	my $debugPrint = 0;
	if ($response->{success}) {
		# print Dumper $response->{content};

		my $decoded_json = decode_json $response->{content};
		# print Dumper $decoded_json->{records}; # This works here; prints the entire hash

		my @fields = qw(asset serial_number name u_monitoring_ip u_snmp_string location company u_device_type);
		# Step 2: Spool through the array (each record is an array of hashes)

		my $onething;
		my $count = 0;
		my $changeCount = 0;
		foreach my $record ( @{$decoded_json->{records}}) {
			# get a unique file name.
			my $recordFile = "$cmdbCache/devices/$record->{sys_id}.json";

			# does the record already exist?
			if ( -f $recordFile ) {
				# load it and compare to what you just got from CMDB
				my $cacheRecord = loadFile($recordFile);

				# this updates all the time;
				delete $record->{last_discovered};
				delete $record->{sys_updated_on};
				delete $record->{sys_updated_by};
				delete $record->{sys_mod_count};

				delete $cacheRecord->{last_discovered};
				delete $cacheRecord->{sys_updated_on};
				delete $cacheRecord->{sys_updated_by};
				delete $cacheRecord->{sys_mod_count};
				
				if (not eq_deeply($record, $cacheRecord)) {
					++$changeCount;
				  print "INFO $changeCount: devices CHANGE detected with $record->{sys_id}\n";
				  if ( $debugPrint ) {
				  	print JSON::XS->new->pretty(1)->encode($record);
				  	print JSON::XS->new->pretty(1)->encode($cacheRecord);
				  	--$debugPrint;
				  }
				  saveFile($recordFile,$record);
				}
			}
			else {
				# it doesn't so create it!
				logSnow("INFO: devices CREATE new record $record->{sys_id}");
				saveFile($recordFile,$record);
			}

			# create a meta entry for this one.
			my $name = getNodeName($record->{'name'},$record->{'u_monitoring_ip'});
			$devicesMeta->{sys_id}{$record->{sys_id}}{sys_id} = $record->{sys_id};
			$devicesMeta->{sys_id}{$record->{sys_id}}{name} = $name;
			if ( not defined $devicesMeta->{sys_id}{$record->{sys_id}}{created} ) {
				$devicesMeta->{sys_id}{$record->{sys_id}}{created} = time();
			}
			$devicesMeta->{sys_id}{$record->{sys_id}}{updated} = time();
			$devicesMeta->{sys_id}{$record->{sys_id}}{active} = 1;
			$devicesMeta->{name}{$name}{sys_id} = $record->{sys_id};

			my @data;
			++$count;
			foreach my $field (@fields) {
				push(@data,$record->{$field});
			}
			$onething = join("\t",@data);
			print "$count: $onething\n" if $debug > 1;
		}

		# now look in the devices directory and find any devices which:
		#  * have a file but not active in DevicesMeta
		#  * have a name change
		#  * before we write the NMIS file make sure there is an active record in the devicesMeta, just delete the node record.
		my $dir = "$cmdbCache/devices";
		if ( -d $dir ) {
 			opendir (DIR, "$dir");
			my @dirlist = readdir DIR;
			closedir DIR;

			foreach my $file (@dirlist) {
				if ( $file =~ /\.json$/ ) {
					my $data = loadFile("$dir/$file");
					my $sys_id = $data->{sys_id};
					my $name = $data->{name};
					
					my $updateMetaActiveFalse = 0;
					# lets check if there is a node in the devicesMeta
					if ( not defined $devicesMeta->{sys_id}{$sys_id} ) {
						# this is bad, there is a file in the JSON cache but nothing in the meta data.
						# move the file to the retired folder
						logSnow("INFO: device $name $file found but nothing in devicesMeta, moving to retired");
						print "INFO: device $name $file found but nothing in devicesMeta, moving to retired\n";
						rename("$cmdbCache/devices/$file","$cmdbCache/retired/$file");
						$updateMetaActiveFalse = 1;
					}
					# do we have JSON file and the active set to false (0) not in API call?
					elsif ( not $devicesMeta->{sys_id}{$sys_id}{active} ) {
						logSnow("INFO: device $name $file found but is NOT active, moving to retired");
						print "INFO: device $name $file found but is NOT active, moving to retired\n";
						rename("$cmdbCache/devices/$file","$cmdbCache/retired/$file");						
						$updateMetaActiveFalse = 1;
					}
					else {
						# great we have a json file and an active thing in the API
					}

					if ( $updateMetaActiveFalse ) {
						# create a meta entry for this one with active false so we have some history.
						$devicesMeta->{sys_id}{$sys_id}{sys_id} = $sys_id;
						$devicesMeta->{sys_id}{$sys_id}{name} = $name;
						if ( not defined $devicesMeta->{sys_id}{$sys_id}{created} ) {
							$devicesMeta->{sys_id}{$sys_id}{created} = time();
						}
						$devicesMeta->{sys_id}{$sys_id}{updated} = time();
						$devicesMeta->{sys_id}{$sys_id}{active} = 0;
						
						$devicesMeta->{name}{$name}{sys_id} = $sys_id;
					}
				}
			}
		}	
				
		saveFile($devicesMetaFile,$devicesMeta,1);
		print "Total devices returned: $count\n";
		print "Done in ".$t->deltaTime() ."\n";
		return $decoded_json->{records};

	} else {
		print "Connection Failed: $response->{status}\nReason: $response->{reason}";
	}

}

sub logSnow {
	my $message = shift;
	open(LOG, ">>$snowLog") or warn "Cannot open $snowLog. $!";
	print LOG returnDateStamp()." $message\n";

	close(LOG);	
}

sub saveFile {
	my $file = shift;
	my $data = shift;
	my $pretty = shift || 0;

	#print Dumper $data;

	open(FILE, ">$file") or warn "Cannot open $file. $!";
	if ( $pretty ) {
		print FILE JSON::XS->new->pretty(1)->encode($data);
	}
	else {
		print FILE JSON::XS->new->latin1->encode($data);
	}

	close(FILE);
}

sub loadFile {
	my $file = shift;
	my $data;

	open(FILE, $file) or warn "Cannot open $file. $!";
	local $/ = undef;
	my $JSON = <FILE>;

	#eval { $data = JSON::XS->new->utf8->decode($JSON); } ;
	eval { $data = JSON::XS->new->latin1->decode($JSON); } ;
	if ( $@ ) {
		print "ERROR convert $file to hash table, $@\n";
	}
	close(FILE);

	return $data;
}

sub start_xlsx {
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

sub add_worksheet {
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

sub end_xlsx {
	# closes the spreadsheet, returns 1 if ok.
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

# devices
#{
#   "u_monitoring_ip" : "10.149.1.2",
#   "name" : "ksbw-core-sw1",
#   "u_device_type" : "1ada23824f734600d12712918110c78a",
#   "first_discovered" : "2015-08-23 10:21:49",
#   "sys_updated_on" : "2015-12-06 11:24:16",
#   "last_discovered" : "2015-12-06 11:24:16",
#   "sys_created_on" : "2015-08-23 10:21:50",
#   "serial_number" : "SMG1112N535",
#   "department" : "",
#   "cost_cc" : "USD",
#   "u_service_owner_cell" : "",
#   "assignment_group" : "",
#   "category" : "Resource",
#   "sys_mod_count" : "27",
#   "asset" : "2063d34a2b164a002ac31c1c17da1531",
#   "due" : "",
#   "checked_out" : "",
#   "u_et_owned" : "false",
#   "schedule" : "",
#   "subcategory" : "IP",
#   "u_catalog_price" : "0",
#   "fqdn" : "",
#   "maintenance_schedule" : "",
#   "u_tech_owner_cell" : "",
#   "u_loaner" : "false",
#   "assigned" : "",
#   "change_control" : "",
#   "attributes" : "",
#   "due_in" : "",
#   "sys_updated_by" : "sncmid",
#   "dns_domain" : "",
#   "model_id" : "e5ababab2bd5f1082ac31c1c17da159b",
#   "install_date" : "",
#   "sys_id" : "0b1d4fe52bc60e402ac31c1c17da1564",
#   "sys_created_by" : "serviceaccountmid",
#   "delivery_date" : "",
#   "u_hearst_business_unit" : "",
#   "sys_class_name" : "cmdb_ci_ip_switch",
#   "u_location_id" : "ca7de3c24f734600d12712918110c78e",
#   "u_recovery_time_objective" : "",
#   "purchase_date" : "",
#   "lease_id" : "",
#   "manufacturer" : "b7e831bdc0a80169015ae101f3c4d6cd",
#   "u_compliance_requirements" : "",
#   "u_snmp_string" : "",
#   "po_number" : "",
#   "comments" : "",
#   "operational_status" : "1",
#   "supported_by" : "",
#   "assigned_to" : "",
#   "asset_tag" : "",
#   "owned_by" : "",
#   "support_group" : "6799e6cbe98d1d00b5035d54c0a279ac",
#   "cost" : "",
#   "skip_sync" : "false",
#   "location" : "55827be75c159100b5031bb409e73514",
#   "u_recovery_point_objective" : "",
#   "discovery_source" : "Service-now",
#   "sys_domain" : "global",
#   "short_description" : "Cisco Internetwork Operating System Software \r\nIOS (tm) s3223_rp Software (s3223_rp-ENTSERVICESK9_WAN-M), Version 12.2(18)SXF12a, RELEASE SOFTWARE (fc1)\r\nTechnical Support: http://www.cisco.com/techsupport\r\nCopyright (c) 1986-2008 by cisco Systems, Inc.\nCisco Systems Catalyst 6500 9-slot Chassis System\nSystem OID: 1.3.6.1.4.1.9.1.283",
#   "order_date" : "",
#   "sys_tags" : "",
#   "checked_in" : "",
#   "u_access_request_notify_only" : "false",
#   "unverified" : "false",
#   "monitor" : "false",
#   "u_support_group3" : "",
#   "__status" : "success",
#   "mac_address" : "",
#   "start_date" : "",
#   "ip_address" : "192.168.133.1",
#   "can_print" : "false",
#   "company" : "fc35b7515c5d1100b5031bb409e73570",
#   "fault_count" : "0",
#   "model_number" : "",
#   "managed_by" : "",
#   "u_access_method" : "",
#   "u_time_card_service" : "false",
#   "install_status" : "1",
#   "correlation_id" : "",
#   "u_enterprise_software" : "false",
#   "invoice_number" : "",
#   "warranty_expiration" : "",
#   "gl_account" : "",
#   "justification" : "",
#   "u_support_group2" : "",
#   "vendor" : ""
#}

# locations
#{
#   "sys_id" : "ca7de3c24f734600d12712918110c78e",
#   "name" : "USA1100",
#   "u_location_alias" : "ksbw-TV",
#   "sys_created_on" : "2015-11-20 01:50:03",
#   "sys_updated_on" : "2015-11-20 01:50:03",
#   "street" : "238 John Street",
#   "city" : "Salinas",
#   "state" : "California",
#   "country" : "USA",
#   "zip" : "",
#   "u_division" : "Broadcasting",
#   "u_procurement_support" : "",
#   "u_directory_services_support" : "",
#   "u_generic_email_ou" : "",
#   "u_non_employee_ou" : "",
#   "latitude" : "",
#   "u_email_support" : "",
#   "sys_mod_count" : "0",
#   "u_level_1_support" : "",
#   "parent" : "",
#   "longitude" : "",
#   "u_ci_monitoring_location" : "true",
#   "u_telecom_support" : "",
#   "phone_territory" : "",
#   "u_ad_only_ou" : "",
#   "lat_long_error" : "",
#   "sys_tags" : "",
#   "longitude_old" : "",
#   "u_it_support" : "",
#   "sys_updated_by" : "asurian@hearst.com",
#   "u_desktop_hw_support" : "",
#   "contact" : "",
#   "__status" : "success",
#   "u_engineering_support" : "",
#   "sys_created_by" : "asurian@hearst.com",
#   "stock_room" : "false",
#   "u_desktop_support" : "",
#   "u_server_support" : "",
#   "company" : "",
#   "sys_class_name" : "cmn_location",
#   "u_network_support" : "",
#   "u_facilities_support" : "",
#   "latitude_old" : "",
#   "u_employee_ou" : "",
#   "full_name" : "USA1100",
#   "phone" : "",
#   "u_service_catalog_location" : "false",
#   "time_zone" : "",
#   "fax_phone" : ""
#}

# device_types
#{
#   "sys_id" : "1ada23824f734600d12712918110c78a",
#   "u_category" : "Network Core Infrastructure",
#   "u_service_level" : "Gold",
#   "u_name" : "Core Switch",
#   "sys_created_on" : "2015-11-20 01:38:36",
#   "sys_updated_on" : "2015-11-20 01:38:36",
#   "sys_updated_by" : "asurian@hearst.com",
#   "__status" : "success",
#   "sys_created_by" : "asurian@hearst.com",
#   "sys_tags" : "",
#   "sys_mod_count" : "0"
#}

# companies
#{
#   "sys_id" : "fc35b7515c5d1100b5031bb409e73570",
#   "name" : "Ksbw-Tv",
#   "u_hearst_business_unit" : "Hearst Television",
#   "u_user_expiration" : "",
#   "u_directory_services_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "u_support_contact" : "",
#   "latitude" : "",
#   "sys_updated_on" : "2015-05-05 18:49:52",
#   "sys_mod_count" : "24",
#   "u_telecom_escalation" : "",
#   "u_level_1_support" : "d5b031f9b05fc500b5031fb8b2ec859a",
#   "banner_text" : "",
#   "longitude" : "",
#   "fiscal_year" : "",
#   "u_primary_vendor_contact" : "",
#   "publicly_traded" : "false",
#   "vendor_manager" : "",
#   "u_primary_contact_mobile__" : "",
#   "u_vendor_escalation_contact" : "",
#   "u_het_supplier" : "false",
#   "lat_long_error" : "",
#   "u_network_escalation" : "",
#   "u_escalation_contact_office__" : "",
#   "u_change_control_owners" : "",
#   "sys_updated_by" : "asurian@hearst.com",
#   "u_order_approver" : "",
#   "revenue_per_year" : "0",
#   "u_engineering_support" : "8182ed65d866bc44d4971c2bd4afb99a",
#   "sys_created_by" : "asurian@hearst.com",
#   "banner_image" : "",
#   "u_directory_services_escalatio" : "",
#   "u_hearst_business" : "true",
#   "u_network_support" : "6799e6cbe98d1d00b5035d54c0a279ac",
#   "country" : "USA",
#   "u_company_number" : "",
#   "latitude_old" : "",
#   "u_facilities_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "sso_source" : "",
#   "num_employees" : "",
#   "u_hr_group" : "",
#   "notes" : "",
#   "manufacturer" : "false",
#   "stock_price" : "",
#   "website" : "",
#   "u_procurement_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "street" : "",
#   "sys_created_on" : "2013-11-26 23:17:57",
#   "state" : "",
#   "u_email_support" : "9e07aa92187cd50065481503404a3ddd",
#   "u_server_escalation" : "",
#   "parent" : "",
#   "u_primary_contact_office__" : "",
#   "u_telecom_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "u_escalation_contact_mobile__" : "",
#   "discount" : "",
#   "zip" : "",
#   "u_email_escalation" : "",
#   "sys_tags" : "",
#   "market_cap" : "0",
#   "longitude_old" : "",
#   "vendor_type" : "",
#   "u_it_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "u_desktop_hw_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "u_secondary_contact_email" : "",
#   "primary" : "false",
#   "contact" : "cee34eac1861994065481503404a3d95",
#   "u_primary_contact_email" : "",
#   "u_secondary_contact_phone__" : "",
#   "__status" : "success",
#   "u_escalation_contact_email" : "",
#   "city" : "",
#   "u_desktop_support" : "c6004fcfd896b844d4971c2bd4afb981",
#   "apple_icon" : "",
#   "rank_tier" : "",
#   "u_server_support" : "8982ed65d866bc44d4971c2bd4afb99c",
#   "profits" : "0",
#   "phone" : "",
#   "u_escalation_support" : "",
#   "u_critical_notifications_group" : "62569a85d887b884d4971c2bd4afb9fe",
#   "stock_symbol" : "",
#   "u_secondary_vendor_contact" : "",
#   "customer" : "false",
#   "fax_phone" : "",
#   "vendor" : "false"
#}

