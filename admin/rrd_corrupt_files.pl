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
usage: $0 run=(true|false) remove=(true|false)
eg: $0 run=true (will run in test mode)
or: $0 run=true remove=true (will run in remove mode)

EO_TEXT
	exit 1;
}

if ( $arg{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}

if ( $arg{run} eq "true" and $arg{remove} ne "true" ) {
	print "$0 running in test mode, no changes will be made!\n";
}

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
		
		#Are there any interface RRDs?
		print "  ". $t->elapTime(). " Looking for RRD databases\n";
		if (defined $NI->{database}) {
			foreach my $section (keys %{$NI->{database}}) {
				
				if ( ref($NI->{database}{$section}) eq "HASH" ) {
					foreach my $index (keys %{$NI->{database}{$section}}) {
						
						if ( ref($NI->{database}{$section}{$index}) eq "HASH" ) {
							foreach my $name (keys %{$NI->{database}{$section}{$index}}) {
								
								if ( ref($NI->{database}{$section}{$index}{$name}) eq "HASH" ) {
									print "ERROR: You should never get this message, $section, $index, $name\n";
								}
								else {
									checkRRD($NI->{database}{$section}{$index}{$name});
								}
								
							}
						}
						else {
							checkRRD($NI->{database}{$section}{$index});
						}
						
					}
				}
				else {
					checkRRD($NI->{database}{$section});
				}
			}
		}

		print "  done in ".$t->deltaTime() ."\n";		
	}
	else {
		print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
	}
}

sub checkRRD {
	my $rrd = shift;

	print "    ". $t->elapTime(). " Found $rrd\n";
	
	++$sum->{count}{'total-rrd'};
	
	my $hash = RRDs::info($rrd);

	###ERROR RRD Info for /data/nmis8/database/health/router/router-health.rrd has an error: '/data/nmis8/database/health/router/router-health.rrd' is not an RRD file

	# Check for errors.
	my $ERROR = RRDs::error;
	if ($ERROR) {
		print STDERR "ERROR RRD Info for $rrd has an error: $ERROR\n";
		++$sum->{count}{'error-rrd'};
		if ( $arg{remove} eq "true" ) {
			removeRRD($rrd);
		}
	}
	else {
		# All GOOD!
		#print "      ". $t->elapTime(). " RRD File OK\n";
		++$sum->{count}{'good-rrd'};
	}
	
}

sub removeRRD {
	my $rrd = shift;

	print "    ". $t->elapTime(). " Removing $rrd\n";
	
	if ( -r $rrd ) {
		unlink($rrd);
		++$sum->{count}{'remove-rrd'};
	}
	else {
		print STDERR "ERROR RRD file permissions or file does not exist: $rrd\n";
	}
	
}
	
print qq|
$sum->{count}{node} nodes processed, $sum->{count}{active} nodes active

$sum->{count}{'total-rrd'}\ttotal RRDs
$sum->{count}{'good-rrd'}\tgood RRDs
$sum->{count}{'error-rrd'}\terrored RRDs

$sum->{count}{'remove-rrd'}\tRRDs removed

|;


sub initSummary {
	my $sum;

	$sum->{count}{node} = 0;
	$sum->{count}{'total-rrd'} = 0;
	$sum->{count}{'good-rrd'} = 0;
	$sum->{count}{'error-rrd'} = 0;
	$sum->{count}{'remove-rrd'} = 0;

	return $sum;
}

