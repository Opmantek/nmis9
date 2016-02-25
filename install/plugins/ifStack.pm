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

package ifStack;
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

	return (0,undef) if (ref($NI->{ifStack}) ne "HASH");
	my $changesweremade = 0;
	
	info("Working on $node ifStack");

	my $LNT = loadLocalNodeTable();

	for my $key (keys %{$NI->{ifStack}})
	{
		my $entry = $NI->{ifStack}->{$key};
          
		if ( my @parts = split(/\./,$entry->{index}) ) {
			my $ifStackHigherLayer = shift(@parts);
			my $ifStackLowerLayer = shift(@parts);
			
			$entry->{ifStackHigherLayer} = $ifStackHigherLayer;
			$entry->{ifStackLowerLayer} = $ifStackLowerLayer;

			if ( defined $IF->{$ifStackHigherLayer}{ifDescr} ) {
				$entry->{ifDescrHigherLayer} = $IF->{$ifStackHigherLayer}{ifDescr};
				$entry->{ifDescrHigherLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackHigherLayer&node=$node";
				$entry->{ifDescrHigherLayer_id} = "node_view_$node";
			}

			if ( defined $IF->{$ifStackLowerLayer}{ifDescr} ) {
				$entry->{ifDescrLowerLayer} = $IF->{$ifStackLowerLayer}{ifDescr};
				$entry->{ifDescrLowerLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackLowerLayer&node=$node";
				$entry->{ifDescrLowerLayer_id} = "node_view_$node";
			}

			$changesweremade = 1;
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
