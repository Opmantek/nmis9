#!/usr/bin/perl
#
## $Id: nodes_scratch.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

# load configuration table
my $C = loadConfTable(conf=>"",debug=>0);

print "This script will mess with NMIS8 nodes files, for testing and fixing problems.\n";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config files to compare
usage: $0 <NODES_1> <NODES_2>
eg: $0 /usr/local/nmis8/conf/Nodes.nmis /usr/local/nmis8/conf/Nodes.nmis.new

EO_TEXT
	exit 1;
}

print "The First NMIS nodes file is: $ARGV[0]\n";
print "The Second NMIS nodes file is: $ARGV[1]\n";

my %groups;
my @hosts = qw(192.168.1.2 192.168.1.16 192.168.1.250 192.168.1.251 192.168.1.253 192.168.1.254);

my %community;
$community{"192.168.1.2"} = "nmisGig8";
$community{"192.168.1.253"} = "OMKread";
$community{"192.168.1.254"} = "OMKread";


foreach my $c (keys %community) {
	print "c=$c community=$community{$c}\n";
}

my $skipgroups = qr/^BANCOP|^KUO/;

processNodes($ARGV[0],$ARGV[1]);

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

sub processNodes {
	my $nodes1 = shift;
	my $nodes2 = shift;
	my $NT1;
	my $NT2;
	
	if ( -f $nodes2 ) {
		print "ERROR: NMIS8 Nodes file already exists $nodes2\n";
		print "Not processing, please select a different target name.\n";
		exit 0;	
	}

	if ( -r $nodes1 ) {
		$NT1 = readFiletoHash(file=>$nodes1);
		print "Loaded $nodes1\n";
	}
	else {
		print "ERROR, could not find or read $nodes1\n";
		exit 0;
	}

	# Load the old CSV first for upgrading to NMIS8 format
	# copy what we need
	foreach my $node (sort keys %{$NT1}) {
		if ( $NT1->{$node}{group} !~ /$skipgroups/ ) {
					
			#A good place to fix UPPER and LOWER case things.
			my $node_lc = lc($NT1->{$node}{name});
	
			# Wanting to make the host a random thing in the lab for testing.
			my $collect = "true";
			my $calls = "false";
			my $cbqos = "none";
			my $host = getHost();
			
			$collect = "false" if ($community{$host} eq "");
			
			if ( $host eq "192.168.1.254" ) { $cbqos = "true" }
	
			my $active = $NT1->{$node}{active};
			if ( $active eq "true" and $NT1->{$node}{group} =~ /$skipgroups/ ) {
				$active = "false";
			}

			print "update node=$NT1->{$node}{name}, host=$host collect=$collect, active=$active\n";
			
			$NT2->{$node}{host} = $host;		
			$NT2->{$node}{name} = $node;
			$NT2->{$node}{active} = $active;
			$NT2->{$node}{collect} = $collect;
			$NT2->{$node}{group} = $NT1->{$node}{group};
			$NT2->{$node}{netType} = $NT1->{$node}{net} || $NT1->{$node}{netType};
			$NT2->{$node}{roleType} = $NT1->{$node}{role} || $NT1->{$node}{roleType};
			$NT2->{$node}{depend} = $NT1->{$node}{depend};
			$NT2->{$node}{threshold} = $NT1->{$node}{threshold} || 'false';
			$NT2->{$node}{ping} = $NT1->{$node}{ping} || 'true';
			$NT2->{$node}{community} = $community{$host};
			$NT2->{$node}{port} = $NT1->{$node}{port} || '161';
			$NT2->{$node}{cbqos} = $cbqos;
			$NT2->{$node}{calls} = $calls;
			$NT2->{$node}{rancid} = $NT1->{$node}{rancid} || 'false';
			$NT2->{$node}{services} = $NT1->{$node}{services} ;
		#	$NT2->{$node}{runupdate} = $NT1->{$node}{runupdate} ;
			$NT2->{$node}{webserver} = 'false' ;
			$NT2->{$node}{model} = $NT1->{$node}{model} || 'automatic';
			$NT2->{$node}{version} = $NT1->{$node}{version} || 'snmpv2c';
			$NT2->{$node}{timezone} = 0 ;
					
			++$groups{$NT1->{$node}{group}};
		}
	}
	writeHashtoFile(file => $nodes2, data => $NT2);
	print " NMIS Nodes file $nodes1 converted to $nodes2\n";	
}


sub getHost {
  my $range = @hosts;
  my $random_number = int(rand($range));
	#print "getHost, range=$range, random_number=$random_number\n"; 
	return $hosts[$random_number];
}