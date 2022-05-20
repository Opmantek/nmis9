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

#Jan 10 17:06:48 10.23.1.2 56783: Jan 10 17:06:47.668: %BGP-5-ADJCHANGE: neighbor 10.10.211.81 vpn vrf Artel_Keystone Down BGP Notification sent
my $seq = 0;
my $debug = 0;

my $eventlog = "/usr/local/nmis8/logs/cisco.log";

cisco_logit($eventlog,"10.23.1.2","%BGP-5-ADJCHANGE", "neighbor 10.10.211.81 vpn vrf Artel_Keystone Down BGP Notification sent");

# creates a cisco_syslog entry for named test
# args: testname hostname, cisco magic, long message
sub cisco_logit {
	my ($syslog,$host,$blit,$message)=@_;

	return logit($syslog,$host,$blit,$message);
}

# this creates a CISCO! style syslog entry, DOES NOT WORK for normal syslog!
sub logit {
	my $syslog = shift;
	my $host = shift;
	my $blit = shift;
	my $message = shift;

	++$seq;

	my $time = returnSyslogTime();
	my $time2;
	my $s;
	my $space = " ";
	if ( $host !~ /SWITCHER/ ) {
		$s = " $seq:";
		$time2 = returnRouterTime();
	}
	else {
		$time2 = returnSwitchTime();
		$space = "";
	}
	my $out =	"$time $host$s $time2: $blit:$space$message";

	$out = "$time $host$s $blit" if not $message;

 	print "$out\n" if $debug;

	if ( not $debug ) {
			#sysopen(OUT, "$syslog", O_WRONLY|O_APPEND|O_CREAT ) or exception("$0: Couldn't open file $syslog for writing. $!","die");
			#flock(OUT, LOCK_EX) or exception("$0: Couldn't lock file $syslog. $!","warn");

			open(OUT, ">>$syslog" ) or exception("$0: Couldn't open file $syslog for writing. $!","die");
			print OUT "$out\n";
			close(OUT) or exception("$0: Couldn't close file $syslog. $!","warn");
	}
}

sub returnRouterTime {
	my $time = shift;
	if ( ! defined $time ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	if ($year > 70) { $year=$year+1900; }
	else { $year=$year+2000; }
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	#2005 Apr 06 12:41:35 AEST +10:00
	return "$mon $mday $hour:$min:$sec";
}

sub returnSwitchTime {
	my $time = shift;
	if ( ! defined $time ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	if ($year > 70) { $year=$year+1900; }
	else { $year=$year+2000; }
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	#2005 Apr 06 12:41:35 AEST +10:00
	return "$year $mon $mday $hour:$min:$sec AEST +10:00";
}

sub returnSyslogTime {
	my $time = shift;
	if ( ! defined $time ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	if ($mday<10) {$mday = " $mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	#Apr  6 12:41:35
	return "$mon $mday $hour:$min:$sec";
}
