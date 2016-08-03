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
ERROR: $0 will total up the size of all RRD database files in use.
usage: $0 run=(true|false)
eg: $0 run=true (will run in test mode)

EO_TEXT
	exit 1;
}

if ( $arg{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}

#--data-source-type|-d ds-name:DST

print $t->markTime(). " Loading the Device List\n";
my $LNT = loadLocalNodeTable();
print "  done in ".$t->deltaTime() ."\n";

my $sum = initSummary();

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
		for my $section (keys %{$NI->{graphtype}})
		{
			next if ($section eq "metrics");
			if (ref($NI->{graphtype}->{$section}) eq "HASH")
			{
				my $index = $section;
				for my $subsection (keys %{$NI->{graphtype}->{$section}})
				{
					next if ($subsection eq "metrics");
					if ($subsection =~ /^cbqos-(in|out)$/)
					{
						my $dir = $1;
						# need to find the qos classes and hand them to getdbname as item
						for my $classid (keys %{$NI->{cbqos}->{$index}->{$dir}->{ClassMap}})
						{
							my $item = $NI->{cbqos}->{$index}->{$dir}->{ClassMap}->{$classid}->{Name};

							checkRRD(db => $S->getDBName(graphtype => $subsection,
																					 index => $index,
																					 item => $item),
											 node => $node, type => $subsection);
						}
					}
					else
					{
						checkRRD(db => $S->getDBName(graphtype => $subsection, index => $index),
										 node => $node, type => $subsection);
					}
				}
			}
			else
			{
				checkRRD(db => $S->getDBName(graphtype => $section),
						node => $node, type => $section);
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

print qq|\nA Summary of Node RRD Size\n|;
foreach my $node (sort keys %{$sum->{node}}) {
	print "Size of $node (bytes): $sum->{node}{$node}{size}\n";
}

print qq|\nA Summary of Counts\n|;
foreach my $count (sort keys %{$sum->{count}}) {
	print "Count of $count: $sum->{count}{$count}\n";
}

print qq|\nA Summary of Types and Bytes\n|;
foreach my $type (sort keys %{$sum->{type}}) {
	print "Size of $type (bytes): $sum->{type}{$type}{size}\n";
}


sub initSummary {
	my $sum;

	$sum->{count}{node} = 0;

	return $sum;
}


sub checkRRD
{
	my (%args) = @_;

	my $size = -s $args{db};
	++$sum->{count}{$args{type}};
	$sum->{type}{$args{type}}{size} += $size;
	$sum->{node}{$args{node}}{size} += $size;
	$sum->{total}{size} += $size;
	print "    ". $t->elapTime(). " Found $args{db}, $size bytes\n";
}

