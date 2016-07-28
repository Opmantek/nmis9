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
# To make sense of Cisco VLAN Bridge information.

package vtpVlan;
our $VERSION = "1.1.0";

use strict;
use func;												# for logging, info

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	return (0,undef) if (ref($NI->{vtpVlan}) ne "HASH");
	
	info("Working on $node vtpVlan");

	my $changesweremade = 0;
		
	for my $key (keys %{$NI->{vtpVlan}})
	{
		my $entry = $NI->{vtpVlan}->{$key};
	
		# get the VLAN ID Number from the index
		if ( my @parts = split(/\./,$entry->{index}) ) {
			shift(@parts); # dummy
			$entry->{vtpVlanIndex} = shift(@parts);
			$changesweremade = 1;
		}
				
		# Get the devices ifDescr and give it a link.
		my $ifIndex = $entry->{vtpVlanIfIndex};				
		if ( defined $IF->{$ifIndex}{ifDescr} ) {
			$changesweremade = 1;
			$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
			$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifIndex&node=$node";
			$entry->{ifDescr_id} = "node_view_$node";
		}
		
	}
	return ($changesweremade,undef); # report if we changed anything
}


1;
