#!/usr/bin/perl
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
use lib "/usr/local/rrdtool/lib/perl"; 

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use NMIS::Timing;
use Data::Dumper;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

my @sections = qw(system interface diskIOTable services storage);

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will tune RRD database files with required changes.
usage: $0 run=(true|false) change=(true|false)
eg: $0 run=true (will run in test mode)

EO_TEXT
	exit 1;
}

if ( $arg{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}


my $sum = initSummary();

my %nmisdb;
my %nmisdbMeta;
my %schema;

processNodeInfo();
printNmisDB();

#print Dumper \%nmisdb;

#print Dumper \%nmisdbMeta;



sub printNmisDB {
	print "section\ttype\tname\tdatatype\tlength\tsample\n";
	foreach my $section (sort keys %{$nmisdb{"meta"}}) {

		foreach my $field (sort keys %{$nmisdb{$section}}) {
			print qq|$section\t$nmisdb{'meta'}{$section}\t$field\t$nmisdbMeta{$section}{$field}{type}\t$nmisdbMeta{$section}{$field}{length}\t"$nmisdb{$section}{$field}"\n|;
		
		}
		
	}
}

sub dataType {
	my $section = shift;
	my $field = shift;
	my $data = shift;

	$nmisdbMeta{$section}{$field}{type} = "string";	
	
	if ( length $data > $nmisdbMeta{$section}{$field}{length} ) {
		$nmisdbMeta{$section}{$field}{length} = length $data;
	}
	 
	if ( $data =~ /true|false/ ) {
		$nmisdbMeta{$section}{$field}{type} = "boolean";
	}
	elsif ( $data =~ /^\d+\%$/ ) {
		$nmisdbMeta{$section}{$field}{type} = "gauge";
	}
	elsif ( $data =~ /^\d+\.\d+$/ ) {
		$nmisdbMeta{$section}{$field}{type} = "real";
	}
	elsif ( $data =~ /^\d+\.\d+.\d+.\d+$/ ) {
		$nmisdbMeta{$section}{$field}{type} = "ipaddress";
	}
	elsif ( $data =~ /^\d+$/ ) {
		$nmisdbMeta{$section}{$field}{type} = "integer";
	}
	elsif ( $data =~ /^[a-zA-Z0-9\W]+$/ ) {
		$nmisdbMeta{$section}{$field}{type} = "varchar";
	}

	if ( $nmisdbMeta{$section}{$field}{type} eq "integer" and $nmisdbMeta{$section}{$field}{length} == 10 ) {
		$nmisdbMeta{$section}{$field}{type} = "unixtime";
	}
}

sub processNodeInfo {
	# Work through each node looking for interfaces, etc to tune.

	print $t->markTime(). " Loading the Device List\n";
	my $LNT = loadLocalNodeTable();
	print "  done in ".$t->deltaTime() ."\n";
	
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
			
			#Are there any interface RRDs?
			foreach my $section (@sections) {
				print "$node: Section = $section\n";
				if ( ref($NI->{$section}) eq "HASH" ) {
					foreach my $index (sort keys %{$NI->{$section}}) {
	
						if ( ref($NI->{$section}{$index}) eq "HASH" ) {
							print "  Index = $index\n";
							foreach my $name (sort keys %{$NI->{$section}{$index}}) {
								print "    $name = $NI->{$section}{$index}{$name}\n";
								$nmisdb{"meta"}{$section} = "Indexed";
								$nmisdb{$section}{$name} = $NI->{$section}{$index}{$name} if $NI->{$section}{$index}{$name} ne "";
								dataType($section,$name,$NI->{$section}{$index}{$name});
							}
						}
						else {
							print "  $index = $NI->{$section}{$index}\n";
							$nmisdb{"meta"}{$section} = "Flat";
							$nmisdb{$section}{$index} = $NI->{$section}{$index} if $NI->{$section}{$index} ne "";
							dataType($section,$index,$NI->{$section}{$index});
						}
					}
				}
				else {
					foreach my $name (sort keys %{$NI->{$section}}) {
						print "  $name = $NI->{$section}{$name}\n";				
						
					}
				}
			}
			print "  done in ".$t->deltaTime() ."\n";		
		}
		else {
			print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
		}
	}
}

sub initSummary {
	my $sum;

	$sum->{count}{node} = 0;
	$sum->{count}{interface} = 0;
	$sum->{count}{'tune-interface'} = 0;
	$sum->{count}{pkts} = 0;
	$sum->{count}{'tune-pkts'} = 0;
	$sum->{count}{'cbqos-in-interface'} = 0;
	$sum->{count}{'cbqos-out-interface'} = 0;
	$sum->{count}{'cbqos-in-classes'} = 0;
	$sum->{count}{'tune-cbqos-in-classes'} = 0;
	$sum->{count}{'cbqos-out-classes'} = 0;
	$sum->{count}{'tune-cbqos-out-classes'} = 0;

	return $sum;
}

