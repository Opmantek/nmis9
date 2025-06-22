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
# a small update plugin for finding nodes that correspond
# to Route Next Hop 
#

package ipCidrRoute;
our $VERSION = "1.0.0";

use strict;
use NMISNG::Util;								# for beautify_physaddress
use Data::Dumper;
use Socket;

sub subnet_mask_to_bits {
    my ($subnet_mask) = @_;

    # Convert the subnet mask to a 32-bit integer
    my $mask_int = unpack("N", inet_aton($subnet_mask));

    # Count the number of 1 bits in the binary representation
    my $bits = 0;
    while ($mask_int) {
        $bits += $mask_int & 1;
        $mask_int >>= 1;
    }

    return $bits;
}

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect addresstable items?
	my $atitems = $S->nmisng_node->get_inventory_ids(
		concept => "ipCidrRoute",
		filter => { historic => 0, "data.ipCidrRouteNextHop" => { '$ne' => '0.0.0.0' } });

	return (0,undef) if (!@$atitems);
	my $changesweremade = 0;

	$NG->log->info("Working on $node ipCidrRoute");

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	my $result = $S->nmisng_node->get_inventory_model(
		concept => "interface",
		filter => { historic => 0 });

	if (my $error = $result->error)
	{
		$NG->log->error("Failed to get inventory: $error");
		return(0,undef);
	}

	my %ifdata =  map { ($_->{data}->{index} => $_) } (@{$result->data});

	for my $atid (@$atitems)
	{
		my $mustsave;
		my ($atinventory,$error) = $S->nmisng_node->inventory(_id => $atid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $atid: $error");
			next;
		}

		my $atdata = $atinventory->data; # r/o copy, must be saved back if changed

		# search for interface
		my $query = {
			'concept' => 'interface','enabled' => 1,'historic' => 0, node_uuid => { '$ne' => $S->nmisng_node->uuid }, 
			"data.ip.ipAdEntAddr" => $atdata->{ipCidrRouteNextHop}
		};
		
		$NG->log->debug4(sub{ "ipCidrRoute query:".Dumper($query)});
		my $entries = NMISNG::DB::find(
			collection  => $NG->inventory_collection,
			query       => $query,
			fields_hash => { 'node_name' => 1 ,'node_uuid' => 1, "path" => 1 }
		);

		my @all = ();
		if ( !defined $entries ) {			
			$NG->log->error("ipCidrRoute Error searching for interface: ". NMISNG::DB::get_error_string);
		} else {
			@all = $entries->all;	
		}

		$NG->log->warn("ipCidrRoute found more than one matching node for ipCidrRouteNextHop, query:".Dumper($query)) if(@all > 1);
		$NG->log->debug3(sub {"ipCidrRoute found matching node for ipCidrRouteNextHop, query:".Dumper(\@all)});

		if( @all == 0 ) {
			my $query = {'concept' => 'catchall','enabled' => 1,'historic' => 0,
				'$or' => [{'data.host' => $atdata->{ipCidrRouteNextHop}}, {'data.host_addr' => $atdata->{ipCidrRouteNextHop}} ]
			};
			my $entries = NMISNG::DB::find(
				collection  => $NG->inventory_collection,
				query       => $query,
				fields_hash => { 'node_name' => 1 ,'node_uuid' => 1, "path" => 1 }
			);
			
			if ( !defined $entries ) {			
				$NG->log->error("ipCidrRoute Error searching for catchall: ". NMISNG::DB::get_error_string);
			} else {
				@all = $entries->all;	
			}
		}
		
		foreach my $entry (@all) {
			my ($node_name,$node_uuid) = ($entry->{node_name},$entry->{node_uuid});
			$NG->log->debug(sub{ "ipCidrRoute matched $atdata->{ipCidrRouteNextHop} to node: $node_name"});			

			$atdata->{remote_node_uuid} = $node_uuid;
			$atdata->{remote_inventory_id} = $entry->{_id}->hex();
			$atdata->{remote_inventory_path} = $entry->{path};

			$changesweremade = $mustsave = 1;
			last;
		}
		

		my $atindex = $atdata->{ipCidrRouteIfIndex};
		# is there an interface with a matching ifindex?
		if ( ref($ifdata{$atindex}) eq "HASH"
				 && defined $ifdata{$atindex}->{data}{ifDescr})
		{
			$atdata->{ifDescr} = $ifdata{$atindex}->{data}{ifDescr};
			$atdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$atindex&node=$node";
			$atdata->{ifDescr_id} = "node_view_$node";
			
			$atdata->{local_inventory_id} = $ifdata{$atindex}->{_id}->hex();
			$atdata->{local_inventory_path} = $ifdata{$atindex}->{path};

			$atdata->{Description} = $ifdata{$atindex}->{data}{Description};
		}
		
		# add in mask bits to make sorting routes easier
		if(  $atdata->{ipCidrRouteMask} ne '0.0.0.0' ) {
			$atdata->{ipCidrRouteMaskBits} = subnet_mask_to_bits( $atdata->{ipCidrRouteMask});
			$changesweremade = $mustsave = 1;
		}

		if ($mustsave)
		{
			$NG->log->debug8(sub{"Saving data".Dumper($atdata)});
			$atinventory->data($atdata); # set changed info
			(undef,$error) = $atinventory->save( node => $S->nmisng_node ); # and save to the db, update not required
			$NG->log->error("Failed to save inventory for $atid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
