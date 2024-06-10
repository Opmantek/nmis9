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
# a small update plugin for extracting node and interface
# info from cdp data for linkage in the nmis gui

package cdpTable;
our $VERSION = "2.0.2";

use strict;
use Data::Dumper;

sub or_terms_to_query_or {
	my ($or_terms) = @_;
	my $query_or = [];
	my $havesomething = 0;
	# take each of the thigns we are or'ing, if the array has > 1 value 
	# use $in, otherwise just match that thing
	foreach my $orrkey (keys %$or_terms) {
		my $size = @{$or_terms->{$orrkey}};
		if( $size > 1 ) {
			push @$query_or, { $orrkey => { '$in' => $or_terms->{$orrkey}}};
			$havesomething = 1;
		} elsif ($size == 1)  {
			push @$query_or, { $orrkey => $or_terms->{$orrkey}[0] };
			$havesomething = 1;
		}
	}
	return ($havesomething) ? $query_or : undef;
}

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	# anything to do? does this node collect cdp information?
	my $nmisng_node = $S->nmisng_node;
	my $cdpids = $nmisng_node->get_inventory_ids(
		concept => "cdp",
		filter => { historic => 0 });

	return (0,undef) if (!@$cdpids);
	my $changesweremade = 0;

	$NG->log->debug("Working on $node cdp");
	

	# for linkage lookup this needs the interfaces inventory as well, but
	# a non-object r/o copy of just the data (no meta) is enough
	# we don't want to re-query multiple times for the same interface...
	# my $result = $S->nmisng_node->get_inventory_model(concept => "interface", filter => { historic => 0 });
	# if (my $error = $result->error)
	# {
	# 	$NG->log->error("Failed to get inventory: $error");
	# 	return(0,undef);
	# }
	# my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

	for my $cdpid (@$cdpids)
	{
		my $mustsave;

		my ($cdpinventory,$error) = $nmisng_node->inventory(_id => $cdpid);
		if ($error)
		{
			$NG->log->error("Failed to get inventory $cdpid: $error");
			next;
		}

		my $cdpdata = $cdpinventory->data; # r/o copy, must be saved back if changed
		my $cdpNeighbour = $cdpdata->{cdpCacheDeviceId};

		# some cdp data includes Serial numbers and FQDN's		
		# map the names to remove duplicates
		my $possibleNames = {};
		$possibleNames->{$cdpNeighbour} = 1;
		$possibleNames->{lc($cdpNeighbour)} = 1;

		if ( $cdpNeighbour =~ /\(\w+\)$/ )
		{
			my $name = $cdpNeighbour;
			$name =~ s/\(\w+\)$//g;
			$possibleNames->{$name} = 1;
			$possibleNames->{lc($name)} = 1;			
		}
		if ((my @fqdn = split(/\./,$cdpNeighbour)) > 1)
		{
			$possibleNames->{$fqdn[0]} = 1;
			$possibleNames->{lc($fqdn[0])} = 1;			
		}		
		# search for possible names in 3 places
		# we also have cdpCacheAddress if cdpCacheAddress is "ip"
		my @possibleNamesArr = map {$_} (keys %$possibleNames);
		my %or_terms = (
			'node_name' => \@possibleNamesArr,
			'data.host' => \@possibleNamesArr,
			'data.sysName' => \@possibleNamesArr
		);
		$NG->log->debug2(sub{ "cdpTable looking for names:".join(',',@possibleNamesArr)});

		# if we have an ip address we can search for that too
		if( $cdpdata->{cdpCacheAddressType} eq 'ip' ) {
			push @{$or_terms{'data.host'}}, $cdpdata->{cdpCacheAddress};
			push @{$or_terms{'data.host_addr'}}, $cdpdata->{cdpCacheAddress};
			$NG->log->debug3(sub{ "cdpTable looking for host: $cdpdata->{cdpCacheAddress}"});
		}

		my $query_or = or_terms_to_query_or(\%or_terms);
		my $query = {'concept' => 'catchall','enabled' => 1,'historic' => 0,
			'$or' => $query_or
		 };
		
		$NG->log->debug3(sub{ "cdpTable query:".Dumper($query)});
		my $entries = NMISNG::DB::find(
			collection  => $NG->inventory_collection,
			query       => $query,
			fields_hash => { 'node_name' => 1,'node_uuid' => 1 }
		);
		
		# get them all, shouldn't be many, hopefully 1
		my @all = $entries->all;
		$NG->log->warn("cdpTable found more than one matching node for cdp, query:".Dumper($query)) if(@all > 1);		
		# loop through, take the first one, this could be improved to pick the best match
		# it's possible the same node is monitored more than once, single poller shouldn't have
		# overlapping ip's and this should be run on the poller
		foreach my $entry (@all) {			
			my ($node_name,$node_uuid) = ($entry->{node_name},$entry->{node_uuid});
			$NG->log->debug(sub{ "cdpTable matched $cdpdata->{cdpCacheIfIndex}:$cdpdata->{cdpCacheDevicePort} to node: $node_name"});
			$changesweremade = $mustsave = 1;
			$cdpdata->{cdpCacheDeviceId_raw} = $cdpdata->{cdpCacheDeviceId};
			$cdpdata->{cdpCacheDeviceId_id} = "node_view_$node_name";
			$cdpdata->{cdpCacheDeviceId_url} = "$C->{network}?&act=network_node_view&node=$node_name";
			$cdpdata->{cdpCacheDeviceId} = $node_name;
			# futureproofing so that opCharts can also use this linkage safely
			$cdpdata->{node_uuid} = $node_uuid;
			last;
		}

		# index N.M? split and link to interface
		my $cdpindex = $cdpdata->{index};
		if ((my @parts = split(/\./, $cdpindex)) > 1)
		{
			$changesweremade = $mustsave = 1;

			my $index = $cdpdata->{cdpCacheIfIndex} = $parts[0];
			$cdpdata->{cdpCacheDeviceIndex} = $parts[1];

			# large # of interfaces x large # of devices means it's better to query per interface
			# this query should hit index path.1 path.2, path.3 and should be really cheap
			# because we aren't filling the path in from 0 we need to tell it partial match is ok			
			my $path = $nmisng_node->inventory_path( concept => "interface", data => { index => $index }, path_keys => ['index'], partial => 1 );
			# remove the cluster_id so we hit the index we want. i'm not sure why 0,1,2,3 isn't an index
			$path->[0] = undef;
			my $result = $nmisng_node->get_inventory_model( path => $path, filter => { historic => 0 }, fields_hash => { 'data.ifDescr' => 1 } );
			if (my $error = $result->error)
			{
				$NG->log->error("Failed to get inventory: $error");
				return(0,undef);
			}
			my $data = $result->data();
			$NG->log->warn("cdpTable found more than one interface for index:$index, node:$node") if( @$data > 1);
			my $intf = $data->[0];
			if ($intf && $intf->{ifDescr} ne '')
			{
				$cdpdata->{ifDescr} = $intf->{ifDescr};
				$cdpdata->{ifDescr_url} = "$C->{network}?act=network_interface_view&intf=$index&node=$node";
				$cdpdata->{ifDescr_id} = "node_view_$node";
			}
		}

		if ($mustsave)
		{
			$cdpinventory->data($cdpdata); # set changed info
			(undef,$error) = $cdpinventory->save(node => $nmisng_node); # and save to the db, update not required, already existed
			$NG->log->error("Failed to save inventory for $cdpid: $error")
					if ($error);
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
