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

my $seq = 0;
my $debug = 0;

#our log file
my $eventlog = "/usr/local/nmis9/logs/cisco.log";
#our node
my $host = "asgard";

logit($eventlog,$host,"RP/0/RSP0/CPU0",'isis[1010]: %ROUTING-ISIS-5-ADJCHANGE : Adjacency to MONKEY-TEST (TenGigE0/1/0/3.931) (L2) Up, Restarted');


# args: testname hostname, cisco magic, long message
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
    my $out =    "$time $host$s $time2: $blit:$space$message";

    $out = "$time $host$s $blit" if not $message;

     print "$out\n" if $debug;

    open(OUT, ">>$syslog" ) or exception("$0: Couldn't open file $syslog for writing. $!","die");
    print OUT "$out\n";
    close(OUT) or exception("$0: Couldn't close file $syslog. $!","warn");
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
