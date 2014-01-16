#!/usr/bin/perl
#
## $Id: unixtime.pl,v 1.5 2012/08/16 07:26:00 keiths Exp $
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

# 
use strict;
use func;
use Time::ParseDate;

if ( $ARGV[0] eq "" or $ARGV[1] ne "") {
	print <<EO_TEXT;
ERROR: $0 needs to know the Unix Time 
usage: $0 <UNIX TIME> || <HUMAN TIME>
eg: $0 1332890864
eg: $0 "30 May 2012 3:45"

EO_TEXT
	exit 1;
}

if ( $ARGV[0] =~ /now/i ) {
	my $time = time;
	my $date = returnDateStamp();
	print "Time now: $date, $time\n";
}
elsif ( $ARGV[0] =~ /^\d+$/ ) {
	print "$ARGV[0]: ". returnDateStamp($ARGV[0]) . "\n";
}
else {
	print "$ARGV[0]: ". parsedate($ARGV[0]) . "\n";
}
