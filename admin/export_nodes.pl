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
	print <<EO_TEXT;
$0 will export nodes from NMIS.
ERROR: need some files to work with
usage: $0 <NODES_CSV_FILE>
eg: $0 nodes=/data/nodes.csv debug=true separator=(comma|tab)

EO_TEXT
	exit 1;
}

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Step 1: define you prefered seperator
my $sep = ",";
if ( $arg{separator} eq "tab" ) {
	$sep = "\t";
}

# Step 2: Define the elements you want from the NMIS Nodes.nmis file.
my @nodesHeaders = qw(name uuid host group businessService serviceStatus services netType roleType);

# Step 3: Defined the elements you want from the var/name-nodes.nmis file for each node, these are the node details.
my @nodeFields = qw(sysName nodeModel nodeVendor serialNum sysDescr);

# Step 4: Define any CSV header aliases you want
my %headAlias = (
	name              		=> 'Node',
	host              		=> 'Host',
	group             		=> 'Group',
	businessService   		=> 'Business Service',
	serviceStatus     		=> 'Service Status',
	services          		=> 'Services',
	netType               => 'Network',
	roleType              => 'Role',
	
	nodeModel             => 'Model',
	nodeVendor            => 'Vendor',
	serialNum      		    => 'SerialNumber',
	sysDescr      		    => 'Description'
);

# Step 5: pick the Master Node table, or the local node table.

# Step 5A: For loading all nodes on a Master
# this will need to use these files for the details var/nmis-SlaveName-nodesum.nmis
#my $NODES = loadNodeTable();

# Step 5B: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

# Step 6: Run the program!

# Step 7: Check the results

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	exportNodes($arg{nodes});
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " Begin\n";


sub exportNodes {
	my $file = shift;

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @headers = (@nodesHeaders,@nodeFields);
	my @aliases;
	foreach my $header (@headers) {
		my $alias = $header;
		$alias = $headAlias{$header} if $headAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
		    
	    $NODES->{$node}{businessService} = "NMIS" if $NODES->{$node}{businessService} eq "";
	    $NODES->{$node}{serviceStatus} = "Test" if $NODES->{$node}{serviceStatus} eq "";
		    
	    my @columns;
	    foreach my $header (@nodesHeaders) {
	    	$NODES->{$node}{$header} = changeCellSep($NODES->{$node}{$header});
	    	push(@columns,$NODES->{$node}{$header});
			}
	    foreach my $header (@nodeFields) {
	    	$NI->{system}{$header} = changeCellSep($NI->{system}{$header});
	    	push(@columns,$NI->{system}{$header});
			}
			my $row = join($sep,@columns);
	    print CSV "$row\n";
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