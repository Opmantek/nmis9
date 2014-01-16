#!/usr/bin/perl
#
## $Id: convertnodes.pl,v 8.3 2012/08/13 05:05:00 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMIS;
use func;
use csv;
use Net::hostent;

# load configuration table
my $C = loadConfTable(conf=>"",debug=>0);

print "This script will convert an NMIS4 Nodes file to an NMIS8 Nodes file.\n";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS files to convert
usage: $0 <NODES_1> <NODES_2>
eg: $0 /usr/local/nmis4/conf/nodes.csv /usr/local/nmis8/conf/Nodes.nmis.new

EO_TEXT
	exit 1;
}

print "The NMIS4 nodes file is: $ARGV[0]\n";
print "The NMIS8 nodes file is: $ARGV[1]\n";

my %groups;

convertNodes($ARGV[0],$ARGV[1]);

printGroupList();

exit 0;

sub printGroupList {
	my @group_list;
	#'group_list' => 'DataCenter,Sales,xAN,WAN',
	foreach my $g (sort keys %groups) {
		print "Group $g has $groups{$g} nodes\n";
		push (@group_list,$g);

	}
	my $grplist = join(",",@group_list);
	print "The following is the list of groups for the NMIS Config file Config.nmis\n";
	print "'group_list' => '$grplist'\n";
}

sub convertNodes {
	my $nmis4_nodes = shift;
	my $nmis8_nodes = shift;
	
	if ( not -f $nmis8_nodes ) {
		my %nodeTable;
		my $NT;
		# Load the old CSV first for upgrading to NMIS8 format
		if ( -r $nmis4_nodes ) {
			if ( (%nodeTable = &loadCSV($nmis4_nodes,$C->{Nodes_Key},"\t")) ) {
				print "Loaded $nmis4_nodes\n";
				# copy what we need
				foreach my $i (sort keys %nodeTable) {
					print "update node=$nodeTable{$i}{node} to NMIS8 format\n";
					# new field 'name' and 'host' in NMIS8, update this field
					if ($nodeTable{$i}{node} =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
						$nodeTable{$i}{name} = sprintf("IP-%03d-%03d-%03d-%03d",${1},${2},${3},${4}); # default
						# it's an IP address, get the DNS name
						#my $iaddr = inet_aton($nodeTable{$i}{node});
						
						## This may not work for everyone, so leaving out this resolution, can be added back if people need it.
						##
						
						#if ((my $name  = gethostbyaddr($iaddr, AF_INET))) {
						#	$nodeTable{$i}{name} = $name; # oke
						#	dbg("node=$nodeTable{$i}{node} converted to name=$name");
						#} 
						#else {
							# look for sysName of nmis4
						#	if ( -f "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat" ) {
						#		my (%info,$name,$value);
						#		sysopen(DATAFILE, "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat", O_RDONLY);
						#		while (<DATAFILE>) {
						#			chomp;
						#			if ( $_ !~ /^#/ ) {
						#				($name,$value) = split "=", $_;
						#				$info{$name} = $value;
						#			}
						#		}
						#		close(DATAFILE);
						#		if ($info{sysName} ne "") {
						#			$nodeTable{$i}{name} = $info{sysName};
						#			dbg("name=$name=$info{sysName} from sysName for node=$nodeTable{$i}{node}");
						#		}
						#	}
						#}
					} 
					else {
						$nodeTable{$i}{name} = $nodeTable{$i}{node}; # simple copy of DNS name
					}
					print "result 1 update name=$nodeTable{$i}{name}\n";
					# only first part of (fqdn) name
					($nodeTable{$i}{name}) = split /\./,$nodeTable{$i}{name} ;
					print "result update name=$nodeTable{$i}{name}\n";
		
					#Using Lower Case Name for everything.
					my $node = $nodeTable{$i}{name};
					$NT->{$node}{name} = $node;
					$NT->{$node}{host} = $nodeTable{$i}{host} || $nodeTable{$i}{node};
					$NT->{$node}{active} = $nodeTable{$i}{active};
					$NT->{$node}{collect} = $nodeTable{$i}{collect};
					$NT->{$node}{group} = $nodeTable{$i}{group};
					$NT->{$node}{netType} = $nodeTable{$i}{net} || $nodeTable{$i}{netType};
					$NT->{$node}{roleType} = $nodeTable{$i}{role} || $nodeTable{$i}{roleType};
					$NT->{$node}{depend} = $nodeTable{$i}{depend};
					$NT->{$node}{threshold} = $nodeTable{$i}{threshold} || 'false';
					$NT->{$node}{ping} = $nodeTable{$i}{ping} || 'true';
					$NT->{$node}{community} = $nodeTable{$i}{community};
					$NT->{$node}{port} = $nodeTable{$i}{port} || '161';
					$NT->{$node}{cbqos} = $nodeTable{$i}{cbqos} || 'none';
					$NT->{$node}{calls} = $nodeTable{$i}{calls} || 'false';
					$NT->{$node}{rancid} = $nodeTable{$i}{rancid} || 'false';
					$NT->{$node}{services} = $nodeTable{$i}{services} ;
				#	$NT->{$node}{runupdate} = $nodeTable{$i}{runupdate} ;
					$NT->{$node}{webserver} = 'false' ;
					$NT->{$node}{model} = $nodeTable{$i}{model} || 'automatic';
					$NT->{$node}{version} = $nodeTable{$i}{version} || 'snmpv2c';
					$NT->{$node}{timezone} = 0 ;
										
					++$groups{$NT->{$node}{group}};
				}
				writeHashtoFile(file => $nmis8_nodes, data => $NT);
				print " csv file $nmis4_nodes converted to $nmis8_nodes\n";
			} else {
				print "ERROR, could not find or read $nmis4_nodes or empty node file\n";
			}
		} else {
			print "ERROR, could not find or read $nmis4_nodes\n";
		}
	}
	else {
		print "ERROR: NMIS8 Nodes file already exists $nmis8_nodes\n";
		print "Not processing, please select a different target name.\n";
	}
	
}
