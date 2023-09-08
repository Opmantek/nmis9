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
# Trivial script to generate an event into syslog for testing purposes, usefull especially opEvents pipelines.

use strict;

my $debug = 0;

my $traplog = "/usr/local/nmis9/logs/trap.log";

trap_logit($traplog,"omk-rr1	UDP: [10.117.45.5]:49919-&gt;[10.117.3.154]:162	SNMPv2-MIB::sysUpTime.0=112:6:56:50.30	SNMPv2-MIB::snmpTrapOID.0=IF-MIB::linkDown	IF-MIB::ifIndex.566=566	IF-MIB::ifAdminStatus.566=down	IF-MIB::ifOperStatus.566=down	IF-MIB::ifName.566=xe-0/1/2");

# this creates a CISCO! style syslog entry, DOES NOT WORK for normal syslog!
sub trap_logit {
	my $traplog = shift;
	my $trap = shift;

	my $time = returnTrapTime();
	my $out = "$time $trap";

 	print "$out\n" if $debug;

	if ( not $debug ) {
			open(OUT, ">>$traplog" ) or exception("$0: Couldn't open file $traplog for writing. $!","die");
			print OUT "$out\n";
			close(OUT) or exception("$0: Couldn't close file $traplog. $!","warn");
	}
}

sub returnTrapTime {
	my $time = shift;
	if ( ! defined $time ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	#need to add 1 to month
	++$mon;
	#$year contains the number of years since 1900. To get the full year write:
	$year += 1900;
	if ($mon<10) {$mon = "0$mon";}
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	#Apr  6 12:41:35
	#2023-09-07T16:23:25
	return "$year-$mon-$mday". "T". "$hour:$min:$sec";
}
