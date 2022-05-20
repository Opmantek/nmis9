#!/bin/env perl
#
#  Copyright Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (NMIS).
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
# Trivial script to generate an event into NMIS for testing purposes, usefull especially opEvents pipelines.

use strict;

my $eventlog = "/usr/local/nmis8/logs/event.log";

eventlog($eventlog,"meatball","Node Up","Normal","","");
eventlog($eventlog,"ASGARD","Node Up","Normal","","");
eventlog($eventlog,"bnelab-rr1","SNMP Up","Major","","snmp ok Time=00:01:44");

sub eventlog {
	my $file = shift;
	my $node = shift;
	my $event = shift;
	my $level = shift;
	my $element = shift;
	my $details = shift;

	my $time = time();

	my $out =	"$time,$node,$event,$level,$element,$details";

	open(OUT, ">>$file" ) or die("$0: Couldn't open file $file for writing. $!");
	print OUT "$out\n";
	close(OUT) or warn("$0: Couldn't close file $file. $!");
}
