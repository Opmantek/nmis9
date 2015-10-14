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
# a small update plugin for adding links to the vmware guests if they're managed by nmis

package ciscoMemory;
our $VERSION = "1.0.1";

use strict;
use func;												# for the conf table extras
use NMIS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	# anything to do?
	return (0,undef) if (ref($NI->{cempMemPool}) ne "HASH" and ref($NI->{entityMib}) ne "HASH");
	my $changesweremade = 0;

	info("Working on $node cempMemPool");
	
	for my $index (keys %{$NI->{cempMemPool}})
	{
		my $entry = $NI->{cempMemPool}{$index};
		my ($entityIndex,$monkey) = split(/\./,$index);
		if ( defined $NI->{entityMib}{$entityIndex}{entPhysicalDescr} ) {
			$entry->{entPhysicalDescr} = $NI->{entityMib}{$entityIndex}{entPhysicalDescr};
			$changesweremade = 1;
		}
		else {
			info("WARNING entPhysicalDescr not available for index $index");
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
