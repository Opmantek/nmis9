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
#
# set this to select device types to collect and draw graphs for
# in both cgi/cplancgi.pl and bin/cplan.pl
my $qr_collect = qr/router|switch/i;
#
# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 
# 
# ****** Shouldn't be anything else to customise below here *******************
# best to customise in the nmis.conf file.
#
# updated 11 Mar 2009 - added switch interface to default regex collect
#						removed hardcoded config file directory path

require 5;

use Time::HiRes;
my $startTime = Time::HiRes::time();

use strict;
use csv;
use BER;
use SNMP_Session;
use SNMP_MIB;
use SNMP_Simple;
use SNMPv2c_Simple;
use SNMP_util;
use RRDs;
use NMIS;
use func;
use rrdfunc;
use ip;
use ping;
use notify;
use Data::Dumper;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Errno qw(EAGAIN);


# Variables for command line munging
my %nvp = getArguements(@ARGV);

# Allow program to use other configuration files
my $conf;
$conf = $nvp{file} ne "" ? $nvp{file} : "nmis.conf" ;
my $configfile = "$FindBin::Bin/../conf/$conf";
if ( -f $configfile ) { loadConfiguration($configfile); }
else { die "Can't access configuration file $configfile.\n"; }

# Set debugging level.
my $debug = setDebug($nvp{debug});
$NMIS::debug = $debug;

my $start= "-1w";		# start 1 week ago
my $dbtime = time();	# set the db timestamp
my $int;
my @ifIn;
my @ifOut;
my %plan;

# check that we have the right directories here.
# let check if the node directory exists, create if not.
if ( not -d "$NMIS::config{database_root}/cplan" ) {
	createDir("$NMIS::config{database_root}/cplan");
}

loadInterfaceInfo;
foreach $int ( keys %NMIS::interfaceInfo ) {
	if ( $NMIS::interfaceInfo{$int}{collect} eq "true" ) {

		# we need the nodeType for summary stats to get the right directory
		loadSystemFile($NMIS::interfaceInfo{$int}{node});
		# only for routers/switches
		if (  $NMIS::systemTable{nodeType} =~ /$qr_collect/ ) {

			# to keep code version independdant, use a direct filename here.
			my $extName = convertIfName($NMIS::interfaceInfo{$int}{ifDescr});
			my $database = "$NMIS::config{database_root}/interface/$NMIS::systemTable{nodeType}/$NMIS::interfaceInfo{$int}{node}/$NMIS::interfaceInfo{$int}{node}-$extName.rrd";
			if ( -r $database ) {
				# %s, @h
				# assume 300 base rrd poll time.
				my ($statval,$head) = &getRRDasHash(rrd => $database, type => "AVERAGE", start => $start, end => int($dbtime/300)*300);
			
				#print Dumper(\$statval);
				#print Dumper(\$head);

				# clear the arrays
				undef %plan;
				@ifIn = ();
				@ifOut = ();
				# push the values into a list
				foreach my $val ( sort keys %$statval ) {
					push @ifIn, ( $$statval{$val}{ifInOctets}); 
					push @ifOut, ( $$statval{$val}{ifOutOctets});
				}
				# now sort the list
				@ifIn = sort { $a <=> $b } @ifIn;
				@ifOut = sort { $a <=> $b } @ifOut;

				# the 95th value is the 95% list element
				$plan{$dbtime}{val95in} = $ifIn[int( 0.95 * scalar(@ifIn))];
				$plan{$dbtime}{val95out} = $ifOut[int( 0.95 * scalar(@ifOut))];
				$plan{$dbtime}{val90in} = $ifIn[int( 0.90 * scalar(@ifIn))];
				$plan{$dbtime}{val90out} = $ifOut[int( 0.90 * scalar(@ifOut))];
				$plan{$dbtime}{val85in} = $ifIn[int( 0.85 * scalar(@ifIn))];
				$plan{$dbtime}{val85out} = $ifOut[int( 0.85 * scalar(@ifOut))];

				# make this a % of ifSpeed, convert octects to bits and round to 0 decimal place.
				if ( $NMIS::interfaceInfo{$int}{ifSpeed} ) {
					$plan{$dbtime}{val95in} = int( ($plan{$dbtime}{val95in} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
					$plan{$dbtime}{val95out} = int( ($plan{$dbtime}{val95out} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
					$plan{$dbtime}{val90in} = int( ($plan{$dbtime}{val90in} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
					$plan{$dbtime}{val90out} = int( ($plan{$dbtime}{val90out} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
					$plan{$dbtime}{val85in} = int( ($plan{$dbtime}{val85in} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
					$plan{$dbtime}{val85out} = int( ($plan{$dbtime}{val85out} * 800 / $NMIS::interfaceInfo{$int}{ifSpeed}) + 0.5);
				}
				else {
					$plan{$dbtime}{val95in} = 0;
					$plan{$dbtime}{val95out} = 0;
					$plan{$dbtime}{val90in} = 0;
					$plan{$dbtime}{val90out} = 0;
					$plan{$dbtime}{val85in} = 0;
					$plan{$dbtime}{val85out} = 0;
				}
				if ( $debug ) {
					print "$NMIS::interfaceInfo{$int}{node} $NMIS::interfaceInfo{$int}{ifDescr}\n";
					print "ifSpeed is $NMIS::interfaceInfo{$int}{ifSpeed}\n";
					printf "95th in is %d %%\n",$plan{$dbtime}{val95in};
					printf "95th out is %d %%\n",$plan{$dbtime}{val95out};
				}
				# create a timestamp entry
				$plan{$dbtime}{dbtime} = $dbtime;

				# Check if the RRD Database Exists
				if ( createDBplan( node => $NMIS::interfaceInfo{$int}{node}, nodeType => $NMIS::systemTable{nodeType}, extName => $NMIS::interfaceInfo{$int}{ifDescr} ) ) { 
					updateDBplan(  node => $NMIS::interfaceInfo{$int}{node}, nodeType => $NMIS::systemTable{nodeType}, extName => $NMIS::interfaceInfo{$int}{ifDescr} );
				}
			}
		}
	}
}

# this returns true if DB exists.
sub createDBplan {

	my %arg = @_;
	# clean the ifDescr
	my $extName = &convertIfName($arg{extName});
	my $database = "$NMIS::config{database_root}/cplan/$arg{nodeType}/$arg{node}/$arg{node}-$extName.csv";

	# Does the database exist already?
	if ( -f $database and -r $database and -w $database ) { 
		# all ok
		return 1;
	}
	# Check if the Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	elsif ( -f $database and not -w $database ) { 
		print "ERROR: Database $database Exists but is readonly to you!\n";
	}
	# It doesn't so create it
	else {
		if ( not -d "$NMIS::config{database_root}/cplan/$arg{nodeType}" ) {
			createDir("$NMIS::config{database_root}/cplan/$arg{nodeType}");
		}
		if ( not -d "$NMIS::config{database_root}/cplan/$arg{nodeType}/$arg{node}" ) { 
			createDir("$NMIS::config{database_root}/cplan/$arg{nodeType}/$arg{node}");
		}
		# this will write the current record
		&writeCSV(%plan,"$database","\t");

		if ( -f $database and -r $database and -w $database ) { 
			# all ok
			if ($debug) { print returnTime." Created cplan $database at $dbtime\n"; }
			logMessage("createDBplan, $arg{node}, Created cplan $database at $dbtime");
		}
		else {
			if ($debug) { print returnTime." Could not create cplan $database at $dbtime\n"; }
			logMessage("createDBplan, $arg{node}, Could not create cplan $database at $dbtime");
		}
	}
return 0;
}

sub updateDBplan {

	my %arg = @_;
	my %data;
	# clean the ifDescr
	my $extName = &convertIfName($arg{extName});
	my $database = "$NMIS::config{database_root}/cplan/$arg{nodeType}/$arg{node}/$arg{node}-$extName.csv";

	# read in the previous data and append to the new values
	my %data = &loadCSV("$database","dbtime","\t");
	# concatenate the hash's
	%plan = ( %plan, %data );

	# lets discard all points over one year old - dont need any more history than that
	# what happens if epoch time rolls over ?? should I worry ??
	foreach ( keys %plan ) {
		if ( $plan{$_}{dbtime} < $dbtime - 31449600 ) {
			delete $plan{$_};			# delete the records 
		}
	}

	# and write out the new
	&writeCSV(%plan,"$database","\t");
	if ($debug) { print returnTime." Updated cplan $database at $dbtime.\n"; }

}

sub createDir {
	my $dir = shift;
	if ( not -d $dir ) { 
		logMessage("Creating directory $dir\n");
		mkdir($dir,0775) or warn "ERROR: cannot mkdir $dir: $!\n"; 
	}
}
