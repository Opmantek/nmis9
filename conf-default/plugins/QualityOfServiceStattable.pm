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
# a small update plugin for getting the QualityOfServiceStat index and direction

package QualityOfServiceStattable;
our $VERSION = "1.0.4";

use strict;
use warnings;
###use diagnostics;

use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	$NG->log->info("QualityOfServiceStattable.pm:update: Running for node $node");

	# anything to do?
	# this plugin deals only with QualityOfServiceStat
	return (0,undef) if (ref($S->{mdl}{systemHealth}{sys}{QualityOfServiceStat}) ne "HASH");

	$NG->log->debug9("\$node: ".Dumper \$node);
	$NG->log->debug9("\$S: ".Dumper \$S);
	$NG->log->debug9("\$C: ".Dumper \$C);
	$NG->log->debug9("\$NG: ".Dumper \$NG);

	my $changesweremade = 0;

	my $concept = 'QualityOfServiceStat';
	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => $concept,
		filter => { historic => 0 });

	if (@$ids)
	{
		$NG->log->debug9("QualityOfServiceStattable.pm:update: \$ids: ".Dumper $ids);
		$NG->log->debug9("QualityOfServiceStattable.pm:update: \$S->{mdl}{systemHealth}{sys}{QualityOfServiceStat}: ".Dumper \%{$S->{mdl}{systemHealth}{sys}{QualityOfServiceStat}});

        # for linkage lookup this needs the interfaces inventory as well, but
        # a non-object r/o copy of just the data (no meta) is enough
        # we don't want to re-query multiple times for the same interface...
        my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
                                                          filter => { historic => 0 });
        if (my $error = $result->error)
        {
                $NG->log->error("QualityOfServiceStattable.pm:update: Failed to get inventory: $error");
                return(0,undef);
        }
        my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
		$NG->log->debug9("QualityOfServiceStattable.pm:update: \%ifdata: ".Dumper \%ifdata);

		for my $id (@$ids)
		{
			my $changed = 0;
			$NG->log->info("Working on $node 'concept=$concept' id $id");

			my ($inventory,$error) = $S->nmisng_node->inventory(_id => $id);
			if ($error)
			{
				$NG->log->error("Failed to get inventory $id: $error");
				next;
			}
			my $inventory_data = $inventory->data();

			$NG->log->debug("id '$id' \$inventory_data:\n".Dumper($inventory_data));

			# |  +--hwCBQoSPolicyStatisticsClassifierEntry(1)
			# |     |	hwCBQoSIfApplyPolicyIfIndex ($ifindex) ,
			#		 	hwCBQoSIfVlanApplyPolicyVlanid1 (undef),
			#			hwCBQoSIfApplyPolicyDirection ($third),
			#			hwCBQoSPolicyStatClassifierName ($k is the index that derives from this property)
			# $k is a QualityOfServiceStat index provided by hwCBQoSPolicyStatClassifierName
			#	and is a dot delimited string of integers (OID):
			my ($ifindex,undef,$third) = split(/\./,$inventory_data->{index});
			if ( defined($ifindex) or defined ($third) )
			{
				$changed = 1;

				$NG->log->debug("defined \$ifindex = '$ifindex'.");
				$NG->log->debug("defined \$third = '$third'.");

				# hwCBQoSIfApplyPolicyDirection: 1=in; 2=out; strict implementation
				my $direction = ($third == 1? 'in': ($third == 2? 'out': undef));

				$NG->log->debug("\$direction = '$direction'.");

				$inventory_data->{ifIndex} = $ifindex;
				$inventory_data->{Direction} = $direction;

				$NG->log->info("Found QoS Entry with interface $inventory_data->{ifIndex}. 'ifIndex' = '$inventory_data->{ifIndex}'.");
				$NG->log->info("Found QoS Entry with interface $inventory_data->{Direction}. 'ifIndex' = '$inventory_data->{Direction}'.");

				$NG->log->debug("QualityOfServiceStattable.pm:update: Node $node updating node info QualityOfServiceStat $inventory_data->{index} ifIndex: new '$inventory_data->{ifIndex}'");
				$NG->log->debug("QualityOfServiceStattable.pm:update: Node $node updating node info QualityOfServiceStat $inventory_data->{index} Direction: new '$inventory_data->{Direction}'");

				# Get the devices ifDescr.
				if ( defined $ifdata{$ifindex}{ifDescr} )
				{
					$inventory_data->{ifDescr} = $ifdata{$ifindex}{ifDescr};

					$NG->log->info("Found QoS Entry with interface $inventory_data->{ifIndex}. 'ifDescr' = '$inventory_data->{ifDescr}'.");
					$NG->log->debug("QualityOfServiceStattable.pm:update: Node $node updating node info QualityOfServiceStat $inventory_data->{index}: new '$inventory_data->{ifDescr}'");
				}
				else
				{
					$NG->log->info("\$ifdata{$ifindex}{ifDescr} not defined. 'ifDescr' could not be determined for ifIndex '$ifindex'.");
				}
			}

			if ($changed)
			{
				$inventory->data($inventory_data); # set changed info
				(undef,$error) = $inventory->save; # and save to the db
				if ($error)
				{
					$NG->log->error("Failed to save inventory for $concept index ".$inventory_data->{index}. " : $error");
				}
				else
				{
					$changesweremade = 1;
				}
			}
		}
	}
	else
	{
		$NG->log->debug("QualityOfServiceStattable.pm:update: 'if(\@\$ids)' returned false");
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
