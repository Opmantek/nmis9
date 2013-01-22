#
## $Id: uselib.pm,v 1.1 2012/05/03 21:54:34 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

package NMIS::uselib;

my $VERSION = "1.00";
use RRDs;
use RRDp;

require 5;

require Exporter;

@EXPORT_OK = qw($rrdtool_lib rrdtool_lib_s);

my $default_rrd = "/usr/local/rrdtool/lib/perl";

# Modify this line to suit your RRD Setup, if not in the above location.
my $alternate_rrd = "/usr/rrdtool/lib/perl";
if( -d $default_rrd )
{
	$rrdtool_lib = $default_rrd;
}
elsif( -d $alternate_rrd )
{
	$rrdtool_lib = $alternate_rrd;	
}
else
{
	$rrdtool_lib = `locate RRDp.pm`;
}

my $rrdtool_lib_s = `locate RRDs.pm`;

# print STDERR "rrdtool_lib is $rrdtool_lib";
# print STDERR "rrdtool_lib_s is $rrdtool_lib_s";

if ( $rrdtool_lib eq "" ) {
	print STDERR "NMIS::uselib was unable to locate RRDTool at $default_rrd or $alternate_rrd\n";	
}

1;
