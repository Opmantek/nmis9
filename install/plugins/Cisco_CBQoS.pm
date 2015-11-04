#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# a small update plugin for converting the cdp index into interface name.

package Cisco_CBQoS;
our $VERSION = "1.0.1";

use strict;

use func;												# for the conf table extras
use NMIS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	return (0,undef) if (ref($NI->{Cisco_CBQoS}) ne "HASH");
	my $changesweremade = 0;
	
	info("Working on $node Cisco_CBQoS");

	my $LNT = loadLocalNodeTable();

	for my $key (keys %{$NI->{Cisco_CBQoS}})
	{
		my $entry = $NI->{Cisco_CBQoS}->{$key};
		my @parts;

#   "Cisco_CBQoS" : {
#      "354" : {
#         "cbQosPolicyDirection" : "output",
#         "index" : "354",
#         "cbQosIfType" : "mainInterface",
#         "cbQosIfIndex" : 22
#      },

				
		if ( defined $IF->{$entry->{cbQosIfIndex}}{ifDescr} ) {
			$entry->{ifDescr} = $IF->{$entry->{cbQosIfIndex}}{ifDescr};
			$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{cbQosIfIndex}&node=$node";
			$entry->{ifDescr_id} = "node_view_$node";
			$entry->{Description} = $IF->{$entry->{cbQosIfIndex}}{Description};
			$changesweremade = 1;
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
