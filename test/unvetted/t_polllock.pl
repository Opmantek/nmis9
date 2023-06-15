#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;

use Compat::NMIS;
use NMISNG::Util;

my %arg = getArguements(@ARGV); 
my $debug = 1;

my $sleep = $arg{sleep};

my $node = "testing";

my $pid;

print "Create the Lock\n";
my $lockHandle = createPollLock(type => "update", node => $node);

print "Check Lock 1\n";
#Check for update LOCK
if ( existsPollLock(type => "update", node => $node) ) {
	print STDERR "Error: update lock exists for $node process $pid which has not finished!\n";
}
else {
	print "FILE IS AVAILABLE FOR LOCKING\n";
}

if ( $sleep ) {
	print "GOING TO SLEEP FOR $sleep\n";
	sleep $sleep;
}

print "Release the Lock\n";
if ( releasePollLock(handle => $lockHandle, type => "update", node => $node) ) {
	print "Lock released successfully\n";
}
else {
	print "ERROR releasing LOCK\n";
}
	
print "\n\nCheck Lock 2\n";
#Check for update LOCK
if ( existsPollLock(type => "update", node => $node) ) {
	print STDERR "Error: update lock exists for $node process $pid which has not finished!\n";
}
else {
	print "FILE IS AVAILABLE FOR LOCKING\n";
}
