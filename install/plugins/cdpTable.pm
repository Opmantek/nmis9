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

package cdpTable;
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

	return (0,undef) if (ref($NI->{cdp}) ne "HASH");
	my $changesweremade = 0;
	
	info("Working on $node cdpTable");

	my $LNT = loadLocalNodeTable();

	for my $key (keys %{$NI->{cdp}})
	{
		my $entry = $NI->{cdp}->{$key};
		my @parts;

#    '1.11' => {
#      'cdpCacheAddress' => '192.168.88.253',
#      'cdpCacheAddressType' => 'ip',
#      'cdpCacheDeviceId' => 'midgard',
#      'cdpCacheDeviceIndex' => '11',
#      'cdpCacheDevicePort' => 'GigabitEthernet1/0/23',
#      'cdpCacheIfIndex' => '1',
#      'cdpCachePlatform' => 'cisco WS-C3750G-24T',
#      'cdpCacheVersion' => 'Cisco IOS Software, C3750 Software (C3750-IPBASEK9-M), Version 12.2(53)SE2, RELEASE SOFTWARE (fc3)
#Technical Support: http://www.cisco.com/techsupport
#Copyright (c) 1986-2010 by Cisco Systems, Inc.
#Compiled Wed 21-Apr-10 04:49 by prod_rel_team',
#      'ifDescr' => 'FastEthernet0/0',
#      'index' => '1.11'
#    },
		
		my $cdpNeighbour = $entry->{cdpCacheDeviceId};

		# some cdp data includes Serial numbers and FQDN's
		my @possibleNames;
		push(@possibleNames,$cdpNeighbour);
		push(@possibleNames,lc($cdpNeighbour));
		if ( $cdpNeighbour =~ /\(\w+\)$/ ) {
			my $name = $cdpNeighbour;
			$name =~ s/\(\w+\)$//g;
			push(@possibleNames,$name);
			push(@possibleNames,lc($name));
		}
		if ( $cdpNeighbour =~ /\./ ) {
			my @fqdn = split(/\./,$cdpNeighbour);
			push(@possibleNames,$fqdn[0]);
			push(@possibleNames,lc($fqdn[0]));
		}
		
		foreach my $cdpNeighbour (@possibleNames) {
			if ( defined $LNT->{$cdpNeighbour} and defined $LNT->{$cdpNeighbour}{name} and $LNT->{$cdpNeighbour}{name} eq $cdpNeighbour ) {
				$changesweremade = 1;
				$entry->{cdpCacheDeviceId_raw} = $entry->{cdpCacheDeviceId};
				$entry->{cdpCacheDeviceId} = $cdpNeighbour;
				$entry->{cdpCacheDeviceId_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_node_view&node=$cdpNeighbour";
				$entry->{cdpCacheDeviceId_id} = "node_view_$cdpNeighbour";
				last;
			}
		}
		
		if ( @parts = split(/\./,$entry->{index}) ) {
			$entry->{cdpCacheIfIndex} = shift(@parts);
			$entry->{cdpCacheDeviceIndex} = shift(@parts);
			if ( defined $IF->{$entry->{cdpCacheIfIndex}}{ifDescr} ) {
				$entry->{ifDescr} = $IF->{$entry->{cdpCacheIfIndex}}{ifDescr};
				$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{cdpCacheIfIndex}&node=$node";
				$entry->{ifDescr_id} = "node_view_$node";
			}
			$changesweremade = 1;
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
