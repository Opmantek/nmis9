#!/usr/bin/perl
#
## $Id: import_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will export nodes from NMIS.
ERROR: need some files to work with
usage: $0 <NODES_CSV_FILE>
eg: $0 /data/nodes.csv

EO_TEXT
	exit 1;
}

if ( not -f $ARGV[0] ) {
	exportNodes($ARGV[0]);
}
else {
	print "ERROR: $ARGV[0] already exists, exiting\n";
	exit 1;
}

sub exportNodes {
	my $file = shift;

	my $C = loadConfTable();
	
	# For loading all nodes on a Master
	my $NODES = loadNodeTable();
	
	# For loading only the local nodes on a Master or a Slave
	my $NODES = loadLocalNodeTable();
	
	my $sep = ",";
	
	my @headers = qw(node host group business_service status services type vendor serialnumber);
	
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my $header = join($sep,@headers);
	print CSV "$header\n";
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
	
	    my $S = Sys::->new; # get system object 
	    $S->init(name=>$node,snmp=>'false');
	    my $NI = $S->ndinfo;
	    
	    $NODES->{$node}{business_service} = "NMIS" if $NODES->{$node}{business_service} eq "";
	    $NODES->{$node}{status} = "Test" if $NODES->{$node}{status} eq "";
	
	    $NODES->{$node}{'services'} =~ s/$sep/;/g;
	
	    print CSV 
	     "$NODES->{$node}{name}".
	     "$sep$NODES->{$node}{host}".
	     "$sep$NODES->{$node}{group}".
	     "$sep$NODES->{$node}{business_service}".
	     "$sep$NODES->{$node}{status}".
	     "$sep$NODES->{$node}{services}".
	     "$sep$NI->{system}{nodeType}".
	     "$sep$NI->{system}{nodeVendor}".
	     "$sep$NI->{system}{serialNum}".
	     "\n";
	
	  }
	}
	
	close CSV;
}
