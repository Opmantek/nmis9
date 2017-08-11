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
# a small update plugin for converting the hwmusaboard index into a board-frame-slot structure

package hwMusaBoard;
our $VERSION = "2.0.0";

use strict;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node have hwMusaBoard information?
	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => "hwMusaBoard",
		filter => { historic => 0 });

	return (0,undef) if (!@$ids);

	my $changesweremade = 0;
	$NG->log->info("Working on $node hwMusaBoard");

	for my $hmbid (@$ids)
	{
		my ($hmbinventory,$error) = $S->nmisng_node->inventory(_id => $hmbid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $hmbid: $error");
			next;
		}
		
		my $hmbdata = $hmbinventory->data; # r/o copy, must be saved back if changed

		if ( $hmbdata->{index} =~ /^(\d+)\.(.+)$/ ) 
		{
			my ($frame, $slot) = ($1,$2);
			$hmbdata->{BoardFrameSlot} = "$frame/$slot";
			$changesweremade = 1;

			$hmbinventory->data($hmbdata); # set changed info
			(undef,$error) = $hmbinventory->save; # and save to the db
			$NG->log->error("Failed to save inventory for $hmbid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
