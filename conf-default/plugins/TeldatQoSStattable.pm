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
# a small update plugin for manipulating TeldatQoSStat

package TeldatQoSStattable;
our $VERSION = "2.0.0";

use strict;
use warnings;
###use diagnostics;

use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	my $sub = 'update';
	my $plugin = 'TeldatQoSStattable.pm';
	my $concept = 'TeldatQoSStat';
	my $inventory_data_key = 'index';

	$NG->log->info("$plugin:$sub: Running for node $node");

	# anything to do?
	# this plugin deals only with $concept
	# let's not auto-vivify anything...
	return (0,undef) if (ref($S->{mdl}) ne "HASH"
				or ref($S->{mdl}->{systemHealth}) ne "HASH"
				or ref($S->{mdl}->{systemHealth}->{sys}) ne "HASH"
				or ref($S->{mdl}{systemHealth}{sys}{$concept}) ne "HASH");

	$NG->log->debug9(sub {"\$node: ".Dumper \$node});
	$NG->log->debug9(sub {"\$S: ".Dumper \$S});
	$NG->log->debug9(sub {"\$C: ".Dumper \$C});
	$NG->log->debug9(sub {"\$NG: ".Dumper \$NG});

	my $changesweremade = 0;

	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => $concept,
		filter => { historic => 0 });

	if (@$ids)
	{
		$NG->log->debug9(sub {"$plugin:$sub: \$ids: ".Dumper $ids});
		$NG->log->debug9(sub {"$plugin:$sub: \$S->{mdl}{systemHealth}{sys}{$concept}: ".Dumper \%{$S->{mdl}{systemHealth}{sys}{$concept}}});

		# for linkage lookup this needs the interfaces inventory as well, but
		# a non-object r/o copy of just the data (no meta) is enough
		# we don't want to re-query multiple times for the same interface...
		my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
		                                                  filter => { historic => 0 });
		if (my $error = $result->error)
		{
		        $NG->log->error("$plugin:$sub: Failed to get inventory: $error");
		        return(0,undef);
		}
		my %ifdata =  map { ($_->{data}->{$inventory_data_key} => $_->{data}) } (@{$result->data});
		$NG->log->debug9(sub {"$plugin:$sub: \%ifdata: ".Dumper \%ifdata});

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

			if ( defined($inventory_data->{$inventory_data_key}) )
			{
				# Get ifIndex which, for TeldatQoSStat, is available at $inventory_data->{ifIndex}:
				my $ifindex = $inventory_data->{ifIndex};

				$NG->log->debug("defined \$ifindex = '$ifindex'.");

				# Get the devices ifDescr from $ifdata:
				if ( defined $ifdata{$ifindex}{ifDescr} )
				{
					$changed = 1;

					$inventory_data->{ifDescr} = $ifdata{$ifindex}{ifDescr};
					$inventory_data->{ifDescr_ClassifierName} = "$inventory_data->{ifDescr}:$inventory_data->{ClassifierName}";

					$NG->log->info("$plugin:$sub: Found $concept entry with $inventory_data_key '$inventory_data->{$inventory_data_key}': 'ifDescr' = '$inventory_data->{ifDescr}'.");
					$NG->log->debug("$plugin:$sub: Node $node updating node info $concept $inventory_data_key '$inventory_data->{$inventory_data_key}': new '$inventory_data->{ifDescr}'");
				}
				else
				{
					$NG->log->info("$plugin:$sub: \$ifdata{$ifindex}{ifDescr} not defined. 'ifDescr' could not be determined for $concept entry with $inventory_data_key '$inventory_data->{$inventory_data_key}'.");
				}
			}
			else
			{
				$NG->log->info("$plugin:$sub: \$inventory_data->{$inventory_data_key} not defined. 'ifDescr' could not be determined for '$inventory_data->{$inventory_data_key}'");
			}

			if ($changed)
			{
				$inventory->data($inventory_data); # set changed info
				(undef,$error) = $inventory->save; # and save to the db # update not required
				if ($error)
				{
					$NG->log->error("$plugin:$sub: Failed to save inventory for $concept $inventory_data_key ".$inventory_data->{$inventory_data_key}. " : $error");
				}
				else
				{
					$changesweremade = 1;
					$NG->log->debug("id '$id' updated \$inventory_data:\n".Dumper($inventory_data));
				}
			}
		}
	}
	else
	{
		$NG->log->debug("$plugin:$sub: 'if(\@\$ids)' returned false");
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
