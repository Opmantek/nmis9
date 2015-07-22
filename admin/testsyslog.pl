#!/usr/bin/perl
#
## $Id: testemail.pl,v 1.3 2012/09/18 01:40:59 keiths Exp $
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
use NMIS;
use func;
use notify;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $timenow = time();
my $message = "NMIS_Event::$C->{server_name}::$timenow,$C->{server_name},Test Event,Normal,,";
my $priority = "info";

my $success = sendSyslog(
	server_string => $C->{syslog_server},
	facility => $C->{syslog_facility},
	message => $message,
	priority => $priority
);

if ( $success ) {
	print "SUCCESS: syslog message appears to have been sent (udp is not reliable)\n";
}
else {
	print "ERROR: sending syslog message to $C->{syslog_server}\n";
}

