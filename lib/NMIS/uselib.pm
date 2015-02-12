#
## $Id: uselib.pm,v 1.1 2012/05/03 21:54:34 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

# this module provides a custom rrdtool path, based on checking some common locations
package NMIS::uselib;
use strict;
use base qw(Exporter);

our $VERSION = "1.1.0";
our $rrdtool_lib;
our @EXPORT_OK = qw($rrdtool_lib);

for my $knownloc (qw(/usr/local/rrdtool/lib/perl /usr/rrdtool/lib/perl))
{
	# but do NOT add any lib dirs that are already in INC, because use lib 
	# adds to the FRONT of  INC, which makes it impossible to find a 
	# cpan'd newer version of a module if the system perl came with an 
	# older version...
	if (-d $knownloc and !grep($_ eq $knownloc, @INC))
	{
		$rrdtool_lib = $knownloc;
		last;
	}
}

# so, if nothing matched and to silence the compile warning,
# duplicate the first element of INC...
$rrdtool_lib ||= $INC[0];

1;
