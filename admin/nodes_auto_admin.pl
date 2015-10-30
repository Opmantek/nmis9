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


my $skipgroups = qr/^BANCOP|^KUO/;

processNodes($ARGV[0],$ARGV[1]);


exit 0;

sub processNodes {
	my $nodes1 = shift;
	my $nodes2 = shift;
	my $LNT;
	
	if ( -f $nodes2 ) {
		print "ERROR: NMIS8 Nodes file already exists $nodes2\n";
		print "Not processing, please select a different target name.\n";
		exit 0;	
	}

	if ( -r $nodes1 ) {
		$LNT = readFiletoHash(file=>$nodes1);
		print "Loaded $nodes1\n";
	}
	else {
		print "ERROR, could not find or read $nodes1\n";
		exit 0;
	}

	# Load the old CSV first for upgrading to NMIS8 format
	# copy what we need
	my @updates;
	my @snmpBad;
	my @badNodes;
	my @nameCorrections;
	foreach my $node (sort keys %{$LNT}) {
		if ( $LNT->{$node}{group} !~ /$skipgroups/ ) {
			
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;

			if ( $NI->{system}{snmpdown} eq "true" and $NI->{system}{sysDescr} eq "" and $LNT->{$node}{collect} eq "true") {
				push(@snmpBad,"$node,$LNT->{$node}{host}");
				$LNT->{$node}{collect} = "false";
				# clear any SNMP Down events attached to the node.
				my $result = checkEvent(sys=>$S,event=>"SNMP Down",level=>"Normal",element=>"",details=>"");
			}
			
			my @nodebits = split(/\./,$NI->{system}{sysName});
			my $sysName = $nodebits[0];
			
			# is the node an IP address and we have a good sysName.
			if ( $node =~ /^\d+\.\d+\.\d+\.\d+$/ and $NI->{system}{sysName} ne "" ) {
				push(@nameCorrections,"$node,$LNT->{$node}{host},$NI->{system}{sysName}");
			}
			elsif ( $node =~ / / and $NI->{system}{sysName} ne "" ) {
				push(@nameCorrections,"$node,$LNT->{$node}{host},$NI->{system}{sysName}");
			}
			elsif ( lc($node) ne lc($sysName) and $NI->{system}{sysName}  ne "" ) {
				push(@nameCorrections,"$node,$LNT->{$node}{host},$NI->{system}{sysName}");
			}

			if ( $NI->{system}{nodedown} eq "true" and $NI->{system}{lastUpdateSec} eq "" ) {
				# run an update.
				#print "$node has never been polled\n";
				push(@badNodes,"$node,$LNT->{$node}{host}");
				delete $LNT->{$node};
			}

			if ( $NI->{system}{sysDescr} =~ /IOS Software, s2t54|Cisco IOS Software, s720|IOS \(tm\) s72033_rp|IOS \(tm\) s3223_rp|IOS \(tm\) s222_rp Software|IOS \(tm\) c6sup2_rp|Cisco IOS Software, Catalyst 4500|Cisco IOS Software, Catalyst 4000|Cisco IOS Software, Catalyst L3 Switch/ and $NI->{system}{nodeModel} eq "CiscoRouter") {
				# run an update.
				print "$node is wrong model, run an update.\n";
				push(@updates,$node);
			}
			if ( $NI->{system}{sysDescr} =~ /IOS-XE Software, Catalyst/ and $NI->{system}{nodeModel} eq "CiscoIOSXE") {
				# run an update.
				print "$node is wrong model, run an update.\n";
				push(@updates,$node);
			}
		}
	}

	print "\n\n";
	print "Nodes needing Update:\n";
	my $nodesUpdate = join("\n",@updates);
	print $nodesUpdate;
	foreach my $node (@updates) {
		print "nmis \"$node\" update\n";
	}

	print "\n\n";

	print "SNMP Not Working, collect has been set to false:\n";
	my $snmpNodes = join("\n",@snmpBad);
	print $snmpNodes;

	print "\n\n";

	print "Possible Node Name Corrections:\n";
	my $newnames = join("\n",@nameCorrections);
	print $newnames;

	print "\n\n";
	
	print "Nodes NOT Responding to POLLS EVER:\n";
	my $badnoderising = join("\n",@badNodes);
	print $badnoderising;

	print "\n\n";
	
	writeHashtoFile(file => $nodes2, data => $LNT);
	print " NMIS Nodes file $nodes1 converted to $nodes2\n";	
}

