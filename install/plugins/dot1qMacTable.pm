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
# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs 
# into a more human-friendly form
package dot1qMacTable;
our $VERSION = "1.0.0";

use strict;

use func;												# for the conf table extras, and beautify_physaddress
use NMIS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	return (0,undef) if (ref($NI->{macTable}) ne "HASH" or $NI->{system}{nodeVendor} =~ "Cisco");
	
	info("Working on $node dot1qMacTable");

	my $changesweremade = 0;

	for my $key (keys %{$NI->{macTable}})
	{
		my $entry = $NI->{macTable}->{$key};
		my $ifIndex = $entry->{dot1qTpFdbPort};
				
		if ( defined $IF->{$ifIndex}{ifDescr} ) {
			$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
			$changesweremade = 1;
		}
		
		if ( defined $IF->{$ifIndex}{Description} ) {
			$entry->{ifAlias} = $IF->{$ifIndex}{Description};
			$changesweremade = 1;
		}

		my @octets;
		if ( @octets = split(/\./,$entry->{index}) ) {
			$entry->{vlan} = shift(@octets);
			my $macstring = join("",@octets);
			@octets = unpack("C*", pack("H*", $macstring));

			my $template = join(":", ("%02x") x @octets);
			$entry->{dot1qTpFdbAddress} = sprintf($template, @octets);
			
			$changesweremade = 1;
		}		
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
