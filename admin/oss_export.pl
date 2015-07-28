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

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = qw(name uuid nodeType nodeVendor sysObjectName sysDescr softwareVersion tbd3 serialNum name2 name3 tbd4 group tbd5);

# Step 4: Define any CSV header aliases you want
my %nodeAlias = (
	name              		=> 'Dslam Name',
	uuid									=> 'Equipment ID',
	nodeType							=> 'Type',
	nodeVendor            => 'Name of the Vendor',
	sysObjectName         => 'Model',
	sysDescr							=> 'Description of the equipmet',
	softwareVersion				=> 'SW Version',
	tbd3									=> 'Status',
	serialNum      		    => 'SerialNumber',
	name2              		=> 'Name of the node in the Network',
	name3              		=> 'Name in NMS',
	tbd4									=> 'Relay Rack name',
	group             		=> 'Location',
	tbd5									=> 'UpLink',
	
	#host              		=> 'Host',
	#businessService   		=> 'Business Service',
	#serviceStatus     		=> 'Service Status',
	#services          		=> 'Services',
	#netType               => 'Network',
	#roleType              => 'Role',	
	#sysDescr      		    => 'Description'
);

      #"2" : {
      #   "ifOperStatus" : "up",
      #   "ifPhysAddress" : "0x588d09a4b008",
      #   "ifDescr" : "FastEthernet0",
      #   "threshold" : "true",
      #   "ifAdminStatus" : "up",
      #   "ifLastChange" : "0:00:46",
      #   "nocollect" : "Collecting: Collection Policy",
      #   "ifIndex" : "2",
      #   "collect" : "true",
      #   "interface" : "fastethernet0",
      #   "ifLastChangeSec" : "46",
      #   "real" : "true",
      #   "ifHighSpeed" : 100,
      #   "ifSpeed" : "100000000",
      #   "event" : "true",
      #   "index" : "2",
      #   "Description" : "",
      #   "ifType" : "ethernetCsmacd"
      #},

my @portHeaders = qw(name ifDescr ifType ifOperStatus parent tbd2);

my %portAlias = (
	name            			=> 'Name of the port in the network',
	ifDescr								=> 'Port ID',
	ifType								=> 'Type of port',
	ifOperStatus					=> 'Status',
	parent								=> 'parent ID /Card ID',
	tbd2									=> 'Duplex full/half',
);

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

# Step 6: Run the program!

# Step 7: Check the results

if ( not -f $arg{nodes} ) {
	createNodeUUID();
	exportNodes("$dir/oss-nodes.csv");
	exportPorts("$dir/oss-ports.csv");
}
else {
	print "ERROR: $arg{nodes} already exists, exiting\n";
	exit 1;
}

print $t->elapTime(). " Begin\n";


sub exportNodes {
	my $file = shift;

	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@nodeHeaders) {
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
		    
		  # clone the name!
	    $NODES->{$node}{name2} = $NODES->{$node}{name};
	    $NODES->{$node}{name3} = $NODES->{$node}{name};

			# get software version for Alcatel ASAM      
      if ( defined $NI->{system}{asamActiveSoftware1} and $NI->{system}{asamActiveSoftware1} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion1};
			}
      elsif ( defined $NI->{system}{asamActiveSoftware2} and $NI->{system}{asamActiveSoftware2} eq "active" ) {
      	$NI->{system}{softwareVersion} = $NI->{system}{asamSoftwareVersion2};
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
			my $row = join($sep,@columns);
	    print CSV "$row\n";
	  }
	}
	
	close CSV;
}

sub exportPorts {
	my $file = shift;
	
	print "Creating $file\n";

	my $C = loadConfTable();
		
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";
	
	# print a CSV header
	my @aliases;
	foreach my $header (@portHeaders) {
		my $alias = $header;
		$alias = $portAlias{$header} if $portAlias{$header};
		push(@aliases,$alias);
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;

			foreach my $ifIndex (sort keys %{$IF}) {
				if ( defined $IF->{$ifIndex}{ifIndex} and defined $IF->{$ifIndex}{ifDescr} ) {
					# create a name
			    $IF->{$ifIndex}{name} = "$node--$IF->{$ifIndex}{ifDescr}";
			    $IF->{$ifIndex}{parent} = $NODES->{$node}{uuid};
					
			    my @columns;
			    foreach my $header (@portHeaders) {
			    	my $data = undef;
			    	if ( defined $IF->{$ifIndex}{$header} ) {
			    		$data = $IF->{$ifIndex}{$header};
			    	}
			    	else {
			    		$data = "TBD";
			    	}
			    	$data = changeCellSep($data);
			    	push(@columns,$data);
			    }
					my $row = join($sep,@columns);
			    print CSV "$row\n";
		  	}
			}
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

sub usage {
	print <<EO_TEXT;
$0 will export nodes and ports from NMIS.
ERROR: need some files to work with
usage: $0 dir=<directory>
eg: $0 dir=/data debug=true separator=(comma|tab)

EO_TEXT
}