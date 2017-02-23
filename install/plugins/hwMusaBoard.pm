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

package hwMusaBoard;
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

	my $hwMusaBoard = 0;
		
	$hwMusaBoard = 1 if (ref($NI->{hwMusaBoard}) eq "HASH");

	return (0,undef) if not $hwMusaBoard;
	
	my $changesweremade = 0;
	
	info("Working on $node hwMusaBoard");
      
	#BoardFrameSlot
	for my $key (keys %{$NI->{hwMusaBoard}})
	{
		# lets get the VRF Name first.
		my $entry = $NI->{hwMusaBoard}->{$key};
		
		if ( $entry->{index} =~ /(\d+)\.(.+)$/ ) {
			my $frame = $1;
			my $slot = $2;
			$entry->{BoardFrameSlot} = "$frame/$slot";
			$changesweremade = 1;
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
