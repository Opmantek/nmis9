#!/usr/bin/perl
#
## $Id: check_nmis_code.pl,v 8.2 2012/05/24 13:24:37 keiths Exp $
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

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use NMIS::Timing;

my $t = NMIS::Timing->new();

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $log = 0;
$log = 1 if $arg{log};


my $debug = 0;
$debug = 1 if $arg{debug};

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$debug);

print $t->elapTime(). " Processing NMIS Code Base and Verifying all the Code and Configuration Files\n" if $log;

my $sum;
$sum->{fail} = 0;
$sum->{pass} = 0;
my $extension = "pl,pm,nmis";
my $passQr = qr/syntax OK/;
my $failQr = qr/had compilation errors/;
my $allPass = 1;
my @failed;

my $events;

#Because Perl is a little fussy about paths, change to the lib then check.
chdir("$C->{'<nmis_base>'}/lib");
processDir("$C->{'<nmis_base>'}/models-install");
processDir("$C->{'<nmis_base>'}/models-dev");
processDir("$C->{'<nmis_base>'}/models");


sub processDir {
	my $dir = shift;

	my @filename;
	my @dirlist;
	my $hostname;
	my $i;

	if ( -d $dir ) {
		# File is a directory
		print "  ".$t->elapTime(). " Working on $dir\n" if $log;
		++$sum->{dir};
		
		opendir (DIR, "$dir");
		@dirlist = readdir DIR;
		closedir DIR;

		@dirlist = sort @dirlist;
		for ( $i = 0 ; $i <= $#dirlist ; ++$i ) {
			@filename = split(/\./,"$dirlist[$i]");
			if ( $extension =~ /$filename[$#filename]/i and ! -d "$dir/$dirlist[$i]" ) {
				print "." if $log and not $debug;

				if ( $dirlist[$i] !~ /^Table\-/ ) {
					print "    ". $t->markTime(). " Checking $dir/$dirlist[$i]\n" if $debug;
					
					my $result = &lookForEvents("$dir/$dirlist[$i]");
					
					print "     done in ".$t->deltaTime() ."\n" if $debug;
				}
				else {
					print "    ". $t->markTime(). " Skipping $dir/$dirlist[$i]\n" if $debug;
				}
			}
			elsif ( -d "$dir/$dirlist[$i]" and $dirlist[$i] !~ /^\.|CVS/ ) {
				&processDir("$dir/$dirlist[$i]");
			}
		}
		print "\n" if $log and not $debug;
	}
	else {
		print "ERROR: Nothing to see here, move along!\n";
	}

	my $EVENTS = loadGenericTable("Events");
	foreach my $event (sort @{$events}) {
		if ( exists $EVENTS->{$event}{Event} and $EVENTS->{$event}{Event} eq $event ) {
			print "FOUND in table: $event\n";						
		}
		else {
			print "ERROR NOT IN TABLE: $event\n";						
		}
	}

	foreach my $event (sort keys %{$EVENTS}) {
		if ( exists $EVENTS->{$event} and $event ne $EVENTS->{$event}{Event} ) {
			print "ERROR EVENT NAME AND KEY BAD: $event\n";									
		}

		if ( $event =~ /^Alert:|^Proactive/ and grep($_ eq $event, @$events) ) {
			print "FOUND in list: $event\n";						
		}
		elsif ( $event =~ /^Alert:|^Proactive/ ) {
			print "ERROR NOT IN LIST: $event\n";						
		}
	}

}

sub lookForEvents {
	my $file = shift;
	my $alerts = 0;

	my $model = readFiletoHash(file=>$file);
	
 #'threshold' => {
 #   'name' => {
 #     'util_out' => {
 #       'item' => 'outputUtil',
 #       'event' => 'Proactive Inte

	if ( exists $model->{threshold}{name} ) {
		foreach my $alert ( keys %{$model->{threshold}{name}} ) {
			if ( exists $model->{threshold}{name}{$alert}{event} ) {
				my $event = "$model->{threshold}{name}{$alert}{event}";
				if (!grep($_ eq $event, @$events)) {
					push (@$events, $event);
					$alerts = 1;
				}
				print "$file: $event\n";
			}
		}
	}
        
	if ( exists $model->{system}{sys}{alerts} ) {
		foreach my $alert ( sort keys %{$model->{system}{sys}{alerts}{snmp}} ) {
			if ( exists $model->{system}{sys}{alerts}{snmp}{$alert}{alert}{event} ) {
				my $event = "Alert: $model->{system}{sys}{alerts}{snmp}{$alert}{alert}{event}";
				if (!grep($_ eq $event, @$events)) {
					push (@$events, $event);
					$alerts = 1;
				}
				print "$file: $event\n";
			}
		}
	}

	if ( exists $model->{alerts} ) {
		foreach my $section ( sort keys %{$model->{alerts}} ) {
			foreach my $alert ( sort keys %{$model->{alerts}{$section}} ) {
				if ( exists $model->{alerts}{$section}{$alert}{event} ) {
					my $event = "Alert: $model->{alerts}{$section}{$alert}{event}";
					if (!grep($_ eq $event, @$events)) {
						push (@$events, $event);
						$alerts = 1;
					}
					print "$file: $event\n";
				}
			}
		}
	}
	
	if ( not $alerts ) {
		#print "No Alerts found in $file\n";
		#print Dumper $model;
	}

	#writeHashtoFile(file=>$ARGV[1],data=>$confnew);

	return $alerts;
}
