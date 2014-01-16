#!/usr/bin/perl
#
## $Id: updateconfig.pl,v 1.6 2012/08/27 21:59:11 keiths Exp $
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


print <<EO_TEXT;
This script will update your running NMIS Config based on the required design 
policy.

EO_TEXT

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config file to update
usage: $0 <CONFIG_1>
eg: $0 /usr/local/nmis8/conf/Config.nmis

EO_TEXT
	exit 1;
}

print "Updating $ARGV[0] with policy\n";

my $conf;

# load configuration table
if ( -f $ARGV[0] ) {
	$conf = readFiletoHash(file=>$ARGV[0]);
}
else {
	print "ERROR: something wrong with config file 1: $ARGV[0]\n";
	exit 1;
}

$conf->{'system'}{'disable_interfaces_summary'} = "true";

writeHashtoFile(file=>$ARGV[0],data=>$conf);

