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

package mplsVpn;
our $VERSION = "1.0.0";

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

	my $gotMpls = 0;
		
	$gotMpls = 1 if (ref($NI->{mplsVpnVrf}) eq "HASH");
	$gotMpls = 1 if (ref($NI->{mplsL3VpnVrf}) eq "HASH");

	return (0,undef) if not $gotMpls;
	
	my $changesweremade = 0;
	
	info("Working on $node mplsVpn");

   #"mplsVpnVrf" : {
   #   "4.105.78.69.84" : {
   #      "mplsVpnVrfAssociatedInterfaces" : 13,
   #      "mplsVpnVrfActiveInterfaces" : 9,
   #      "mplsVpnVrfName" : "iNET",
   #      "mplsVpnVrfCreationTime" : 2831,
   #      "index" : "4.105.78.69.84",
   #      "mplsVpnVrfConfStorageType" : "volatile",
   #      "mplsVpnVrfDescription" : "",
   #      "mplsVpnVrfOperStatus" : "up",
   #      "mplsVpnVrfRouteDistinguisher" : "65500:10001",
   #      "mplsVpnVrfConfRowStatus" : "active"
   #   },
   #"mplsVpnInterface" : {
   #   "4.105.78.69.84.39" : {
   #      "index" : "4.105.78.69.84.39",
   #      "mplsVpnInterfaceVpnClassification" : "enterprise",
   #      "mplsVpnInterfaceVpnRouteDistProtocol" : 2,
   #      "mplsVpnInterfaceConfStorageType" : "volatile",
   #      "mplsVpnInterfaceLabelEdgeType" : 1,
   #      "mplsVpnInterfaceConfRowStatus" : "active"
   #   },
      
	# lets get the VRF Name first.
	for my $key (keys %{$NI->{mplsVpnVrf}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsVpnVrf}->{$key};
		
		if ( $entry->{index} =~ /(\d+)\.(.+)$/ ) {
			my $indexThing = $1;
			my $name = $2;
			$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$name));
			$changesweremade = 1;
		}
	}

	# lets get the VRF Name first from the alternate MIB.
	for my $key (keys %{$NI->{mplsL3VpnVrf}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsL3VpnVrf}->{$key};
		
		if ( $entry->{index} =~ /(\d+)\.(.+)$/ ) {
			my $indexThing = $1;
			my $mplsL3VpnVrfName = $2;
			$entry->{mplsL3VpnVrfName} = join("", map { chr($_) } split(/\./,$mplsL3VpnVrfName));
			$changesweremade = 1;
		}
	}



	# lets get the VRF Name first.
	for my $key (keys %{$NI->{mplsL3VpnIfConf}})
	{
		my $entry = $NI->{mplsL3VpnIfConf}->{$key};
		
		if ( $entry->{index} =~ /(\d+)\.(.+)\.(\d+)$/ ) {
			my $indexThing = $1;
			my $mplsL3VpnVrfName = $2;
			my $mplsL3VpnIfConfIndex = $3;
			$entry->{mplsL3VpnVrfName} = join("", map { chr($_) } split(/\./,$mplsL3VpnVrfName));
			$entry->{mplsL3VpnIfConfIndex} = $mplsL3VpnIfConfIndex;

			if ( defined $IF->{$entry->{mplsL3VpnIfConfIndex}}{ifDescr} ) {
				$entry->{ifDescr} = $IF->{$entry->{mplsL3VpnIfConfIndex}}{ifDescr};
				$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{mplsL3VpnIfConfIndex}&node=$node";
				$entry->{ifDescr_id} = "node_view_$node";
			}
			
			$changesweremade = 1;
		}
	}

	# lets get the VRF Name first.
	for my $key (keys %{$NI->{mplsVpnInterface}})
	{
		my $entry = $NI->{mplsVpnInterface}->{$key};
		
		if ( $entry->{index} =~ /(\d+)\.(.+)\.(\d+)$/ ) {
			my $indexThing = $1;
			my $name = $2;
			my $ifIndex = $3;
			$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$name));
			$entry->{ifIndex} = $ifIndex;

			if ( defined $IF->{$entry->{ifIndex}}{ifDescr} ) {
				$entry->{ifDescr} = $IF->{$entry->{ifIndex}}{ifDescr};
				$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$entry->{ifIndex}&node=$node";
				$entry->{ifDescr_id} = "node_view_$node";
			}
			
			
			$changesweremade = 1;
		}
	}

  #"10.77.103.109.116.95.82.97.100.105.111.2.1" : {
  #   "mplsVpnVrfRouteTarget" : "65500:180803",
  #   "index" : "10.77.103.109.116.95.82.97.100.105.111.2.1",
  #   "mplsVpnVrfRouteTargetRowStatus" : "65500:180803",
  #   "mplsVpnVrfRouteTargetDescr" : "65500:180803"
  #},
  #"3.71.83.77.4.1" : {
  #   "mplsVpnVrfRouteTarget" : "65500:70100",
  #   "index" : "3.71.83.77.4.1",
  #   "mplsVpnVrfRouteTargetRowStatus" : "65500:70100",
  #   "mplsVpnVrfRouteTargetDescr" : "65500:70100"
  #},
              
	# lets get the VRF Name first.
	for my $key (keys %{$NI->{mplsL3VpnVrfRT}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsL3VpnVrfRT}->{$key};
		
		# there seems to be a crazy character in this MIB!
		if ( $entry->{index} =~ /\d+\.(.+)\.(\d+)\.(\d+)$/ ) {
			my $mplsL3VpnVrfName = $1;
			my $mplsL3VpnVrfRTIndex = $2;
			my $mplsL3VpnVrfRTType = $3;
			$entry->{mplsL3VpnVrfName} = join("", map { chr($_) } split(/\./,$mplsL3VpnVrfName));
			$entry->{mplsL3VpnVrfRTIndex} = $mplsL3VpnVrfRTIndex;
			$entry->{mplsL3VpnVrfRTType} = $mplsL3VpnVrfRTType;
			
			if ( $mplsL3VpnVrfRTType == 1 ) {
				$entry->{mplsL3VpnVrfRTType} = "import";
			}
			elsif ( $mplsL3VpnVrfRTType == 2 ) {
				$entry->{mplsL3VpnVrfRTType} = "export";
			}
			elsif ( $mplsL3VpnVrfRTType == 3 ) {
				$entry->{mplsL3VpnVrfRTType} = "both";
			}
			$changesweremade = 1;
		}
	}
      
	# lets get the VRF Name first.
	for my $key (keys %{$NI->{mplsVpnVrfRouteTarget}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsVpnVrfRouteTarget}->{$key};
		
		if ( $entry->{index} =~ /(.+)\.(\d+)\.(\d+)$/ ) {
			my $mplsVpnVrfName = $1;
			my $mplsVpnVrfRouteTargetIndex = $2;
			my $mplsVpnVrfRouteTargetType = $3;
			$entry->{mplsVpnVrfName} = join("", map { chr($_) } split(/\./,$mplsVpnVrfName));
			$entry->{mplsVpnVrfRouteTargetIndex} = $mplsVpnVrfRouteTargetIndex;
			$entry->{mplsVpnVrfRouteTargetType} = $mplsVpnVrfRouteTargetType;
			
			if ( $mplsVpnVrfRouteTargetType == 1 ) {
				$entry->{mplsVpnVrfRouteTargetType} = "import";
			}
			elsif ( $mplsVpnVrfRouteTargetType == 2 ) {
				$entry->{mplsVpnVrfRouteTargetType} = "export";
			}
			elsif ( $mplsVpnVrfRouteTargetType == 3 ) {
				$entry->{mplsVpnVrfRouteTargetType} = "both";
			}
			$changesweremade = 1;
		}
	}

	# lets get the mplsVpnLdpCisco details
	for my $key (keys %{$NI->{mplsLdpEntity}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsLdpEntity}->{$key};
		
		if ( $entry->{index} =~ /(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\.(\d+)$/ ) {
			my $mplsLdpEntityLdpId = $1;
			my $mplsLdpEntityIndex = $2;

			$entry->{mplsLdpEntityLdpId} = $mplsLdpEntityLdpId;
			$entry->{mplsLdpEntityIndex} = $mplsLdpEntityIndex;
			
			$changesweremade = 1;
		}
	}

	# lets get the mplsVpnLdpCisco details
	for my $key (keys %{$NI->{mplsVpnLdpCisco}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{mplsVpnLdpCisco}->{$key};
		
		if ( $entry->{index} =~ /(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\.(\d+)$/ ) {
			my $mplsLdpEntityLdpId = $1;
			my $mplsLdpEntityIndex = $2;

			$entry->{mplsLdpEntityLdpId} = $mplsLdpEntityLdpId;
			$entry->{mplsLdpEntityIndex} = $mplsLdpEntityIndex;
			
			$changesweremade = 1;
		}
	}


	return ($changesweremade,undef); # report if we changed anything
}

1;
