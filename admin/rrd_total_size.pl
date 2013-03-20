#!/usr/bin/perl
#
## $Id: rrd_tune_interfaces.pl,v 1.4 2012/09/21 04:56:33 keiths Exp $
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
use lib "/usr/local/rrdtool/lib/perl"; 

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use func;
use File::stat;
use NMIS;
use NMIS::Timing;
use RRDs 1.000.490; # from Tobias

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will tune RRD database files with required changes.
usage: $0 run=(true|false) change=(true|false)
eg: $0 run=true (will run in test mode)
or: $0 run=true change=true (will run in change mode)

EO_TEXT
	exit 1;
}

if ( $arg{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}
if ( $arg{run} eq "true" and $arg{change} ne "true" ) {
	print "$0 running in test mode, no changes will be made!\n";
}

#--data-source-type|-d ds-name:DST

print $t->markTime(). " Loading the Device List\n";
my $LNT = loadLocalNodeTable();
print "  done in ".$t->deltaTime() ."\n";

my $sum = initSummary();

my $qrdst = qr/ds\[(ipForwDatagrams|ipFragCreates|ipFragFails|ipFragOKs|ipInAddrErrors|ipInDelivers|ipInDiscards|ipInHdrErrors|ipInReceives|ipInUnknownProtos|ipOutDiscards|ipOutNoRoutes|ipOutRequests|ipReasmFails|ipReasmOKs|ipReasmReqds)\]\.type/;

# Work through each node looking for interfaces, etc to tune.
foreach my $node (sort keys %{$LNT}) {
	++$sum->{count}{node};
		
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		++$sum->{count}{active};
		print $t->markTime(). " Processing $node\n";

		# Initiase the system object and load a node.
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		# Recurse over the hash to see what you can find.
		foreach my $type (sort keys %{$NI->{database}}){
		#Are there any interface RRDs?
			if ( ref($NI->{database}{$type}) eq "HASH" ) {
				foreach my $index (sort keys %{$NI->{database}{$type}}){
					if ( ref($NI->{database}{$type}{$index}) eq "HASH" ) {
						foreach my $key (sort keys %{$NI->{database}{$type}{$index}}){
							my $rrd = $NI->{database}{$type}{$index}{$key};
							if ( $type !~ /metrics/ ) {
								my $size = fileSize($rrd);
								++$sum->{count}{$type};
								$sum->{type}{$type}{size} += $size;
								$sum->{node}{$node}{size} += $size;
								$sum->{total}{size} += $size;
								print "    ". $t->elapTime(). " Found $rrd is $size\n";			
							}							
						}
					}
					else {
						my $rrd = $NI->{database}{$type}{$index};
						if ( $type !~ /metrics/ ) {
							my $size = fileSize($rrd);
							++$sum->{count}{$type};
							$sum->{type}{$type}{size} += $size;
							$sum->{node}{$node}{size} += $size;
							$sum->{total}{size} += $size;
							print "    ". $t->elapTime(). " Found $rrd is $size\n";			
						}
					}
				}
			}
			else {
				my $rrd = $NI->{database}{$type};
				if ( $type !~ /metrics/ ) {
					my $size = fileSize($rrd);
					++$sum->{count}{$type};
					$sum->{type}{$type}{size} += $size;
					$sum->{node}{$node}{size} += $size;
					$sum->{total}{size} += $size;
					print "    ". $t->elapTime(). " Found $rrd is $size\n";
				}
			}
		}
		print "  done in ".$t->deltaTime() ."\n";		

	}
	else {
		print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
	}
}
	
print qq|
Total RRD Size is $sum->{total}{size} bytes.

|;

print qq|A Summary of Counts\n|;
foreach my $node (sort keys %{$sum->{node}}) {
	print "Size of $node: $sum->{node}{$node}{size} bytes\n";
}

print qq|A Summary of Node RRD Size\n|;
foreach my $count (sort keys %{$sum->{count}}) {
	print "Count of $count: $sum->{count}{$count}\n";

	
}

print qq|A Summary of Types and Bytes:\n|;
foreach my $type (sort keys %{$sum->{type}}) {
	print "Size of $type $sum->{type}{$type}{size} bytes\n";
}


sub initSummary {
	my $sum;

	$sum->{count}{node} = 0;
	$sum->{count}{'tune-mib2ip'} = 0;

	return $sum;
}

sub fileSize {
	my $file = shift;
	if ( -r $file ) {
		my $fstat = stat($file);
		return $fstat->size;
	}
	else {
		return 0;
	}
}