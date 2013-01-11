#!/usr/bin/perl
#
## $Id: nmis_post_proc.pl,v 8.1 2011/12/19 04:13:32 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
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
package pp;

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 

require 5;

use strict;
use CGI::Pretty qw(:standard);
use NMIS;
use func;

use Data::Dumper;
$Data::Dumper::Ident=1;
$Data::Dumper::SortKeys=1;

sub doPP {

	my $exit;

	$exit = getNetworkSummary();

return $exit;

}

# get network summary page, remove links en store in htdocs for non priv view
sub getNetworkSummary {

	my $fd;
	my $ns;
	my $C = loadConfTable();

	my $filename = "$C->{'<nmis_base>'}/htdocs/network_summary.html";

	# get page, bypass authorization
	my $ns = `$C->{'<nmis_base>'}/cgi-bin/network.pl http=true act=network_summary_small`;

	# control if page loaded
	if ($ns =~ /NMIS Network Summary/) {

		$ns =~ s/\<a target.*(\<img alt.*\/\>)\<\/a\>/$1/; # remove anchor + onclick of image
		$ns =~ s/\<a href.*"\>(.*)\<\/a\>/$1/g; # remove anchor of group names

		# add time
		my $tm = "&nbsp;updated ".returnDateStamp()."\n";
		$ns =~ s/(\<\/body\>)/$tm$1/;

		if (open($fd,'>',$filename)) {
			print $fd $ns;
			close $fd;
			setFileProt($filename);
		} else {
			logMsg("ERROR cannot open for write file=$filename,$!");
			return;
		}
	} else {
		logMsg("ERROR page loading failure, $ns");
		return;
	}
	
	return 1;
}

1;

# *****************************************************************************
# NMIS Copyright (C) 1999-2011 Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
