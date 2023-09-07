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
# An update plugin for Juniper Class of Service Support.

package jnxCoStable;
our $VERSION = "2.1.1";

use strict;
use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;						# for snmp-related access
use File::Copy qw(move);

# *****************************************************************************
# Set ths to delete the Class of Service data for Unmanaged Interfaces!
# *****************************************************************************
my $deleteCOSForUnmanagedInterfaces = 1;
# *****************************************************************************


sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $NI              = $S->nmisng_node;
	my $nodeobj         = $NG->node(name => $node);
	my $NC              = $nodeobj->configuration;
	my $catchall        = $S->inventory( concept => 'catchall' )->{_data};
	my $unmanagedMsg;
	my $changesweremade = 0;

	# This plugin deals only with this specific device type, and only ones with snmp enabled and working
	# and finally only if the number of interfaces is greater than the limit, otherwise the normal
	# discovery will populate all interfaces normally.
	if ( $catchall->{nodeModel} !~ /Juniper/ or !NMISNG::Util::getbool($catchall->{collect}))
	{
		$NG->log->debug("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
		$NG->log->debug("Node '$node', Model '$catchall->{nodeModel}' does not qualify for this plugin.");
		return (0,undef);
	}

	my $juniperCoSIds = $S->nmisng_node->get_inventory_ids(
		concept => "Juniper_CoS",
		filter => { historic => 0 });
	if (!@$juniperCoSIds)
	{
		$NG->log->debug("Prerequisite Juniper_CoS not found in node '$node'");
		$NG->log->debug("Node '$node', does not qualify for this plugin.");
		return (0,undef);
	}

	$NG->log->info("Running Juniper Class of Service plugin for Node '$node', Model '$catchall->{nodeModel}'.");

	# Do not Set the Header data. , let NMIS work it out using the model
	# my $juniperCoSInfo = [
	# 	{ index                      => "Index"},
	# 	{ jnxCosIfqQedPkts           => "Total packets queued at the output"},
	# 	{ jnxCosIfqTxedBytes         => "Total bytes transmitted"},
	# 	{ jnxCosIfqTotalRedDropBytes => "Total bytes RED-dropped at the output"},
	# 	{ jnxCosIfqTotalRedDropPkts  => "Total packets RED-dropped at the output"},
	# 	{ jnxCosFcName               => "Name of the forwarding class"},
	# 	{ jnxCosIfqQedBytes          => "Number of bytes queued at the output"},
	# 	{ jnxCosIfqTailDropPkts      => "Total packets dropped due to tail dropping at the output"},
	# 	{ QedPkts                    => "Total packets queued at the output"},
	# 	{ Queued                     => "Number of bytes queued at the output"},
	# 	{ RedDropBytes               => "Total bytes dropped due to RED (Random Early Detection) at the output"},
	# 	{ RedDropPkts                => "Total packets dropped due to RED (Random Early Detection) at the output"},
	# 	{ TailDropPkts               => "Total packets dropped due to tail dropping"},
	# 	{ Txed                       => "Total bytes transmitted"}
	# ];

	# Based on each of the Juniper Class of Service entries, we supliment the data.
	for my $juniperCoSId (@$juniperCoSIds)
	{
		my ($inventory,$error) = $S->nmisng_node->inventory(_id => $juniperCoSId);
		if ($error)
		{
		    $NG->log->warn("Failed to get 'Juniper_CoS' inventory for Node '$node'; ID $juniperCoSId; Error: $error");
		    next;
		}

		# for linkage lookup this needs the interfaces inventory as well, but
		# a non-object r/o copy of just the data (no meta) is enough
		# we don't want to re-query multiple times for the same interface...
		my $result = $S->nmisng_node->get_inventory_model(concept => "interface",
														filter => { historic => 0 });
		if (my $error = $result->error)
		{
			$NG->log->error("Failed to get interface inventory: $error");
			return(2,"Failed to get interface inventory: $error");
		}
		my %ifdata =  map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

		my $juniperCoSData = $inventory->data; # r/o copy, must be saved back if changed
        my $index          = $juniperCoSData->{index};

		if ($index =~ /(\d+)\.\d+\.(.+)$/ )
		{
			my $intIndex   = $1;
			my $FCcodename = $2;
			$NG->log->debug("jnxCoStable: update_plugin: intIndex=$intIndex");

			# only display active interfaces - delete the keys of inactive interfaces:
			if ( defined $ifdata{$intIndex}{collect} && !NMISNG::Util::getbool($ifdata{$intIndex}{collect}))
			{
				if ($deleteCOSForUnmanagedInterfaces) {
					$NG->log->info("Interfce '$intIndex';  is not managed, deleting the Class of Service Data.") if (!defined($unmanagedMsg->{$intIndex}));
					my ($ok, $deleteError) = $inventory->delete();
					if ($deleteError)
					{
						$NG->log->error("Failed to delete Class of Service data for Interface '$intIndex'; ; Error: $deleteError");
					}
				} else {
					$NG->log->info("Interface '$intIndex'; is unmanaged, removing Class of Service Data from display.") if (!defined($unmanagedMsg->{$intIndex}));
					$inventory->data_info(
						subconcept => "Juniper_CoS",
						enabled => 0
					);
					my ( $op, $subError ) = $inventory->save();
					if ($subError)
					{
						$NG->log->error("Failed to unmanage inventory for Class of Service Index '$index': $subError");
					}
				}
				$unmanagedMsg->{$intIndex} = 1;
				$changesweremade = 1;
				next;
			}

			# Do not Set which columns should be displayed
			# Do not Set the Header data. , let NMIS work it out using the model
			# $inventory->data_info(
			# 	subconcept => "Juniper_CoS",
			# 	enabled => 1,
			# 	display_keys => $juniperCoSInfo
			# );

			# Set the data
			my $FCname                        = join("", map { chr($_) } split(/\./,$FCcodename));
			$juniperCoSData->{jnxCosFcName}   = $FCname . ' Class' ;
			$juniperCoSData->{ifIndex}        = $intIndex;
			$juniperCoSData->{IntName}        = $ifdata{$intIndex}{ifDescr};
			$juniperCoSData->{cosDescription} = $juniperCoSData->{IntName} . '-' . $FCname . '-Class';
			# description is pulled from first entry in headers section, that is cosDescription for this model
			# we are updating cosDescription so we need to update the description as well
			$inventory->description($juniperCoSData->{cosDescription});
			$inventory->data($juniperCoSData);
			$NG->log->debug2("jnxCoStable: FCcodename     = '$FCcodename'");
			$NG->log->debug2("jnxCoStable: jnxCosFcName   = '$juniperCoSData->{jnxCosFcName}'");
			$NG->log->debug2("jnxCoStable: ifIndex        = '$juniperCoSData->{ifIndex}'");
			$NG->log->debug2("jnxCoStable: IntName        = '$juniperCoSData->{IntName}'");
			$NG->log->debug2("jnxCoStable: cosDescription = '$juniperCoSData->{cosDescription}'");
			$NG->log->debug("jnxCoStable: update_plugin: Found COS Entry with interface '$juniperCoSData->{IntName}' and '$juniperCoSData->{jnxCosFcName}'.");
			# The above has added data to the inventory, that we now save.
			my ( $op, $subError ) = $inventory->save();
			if ($subError)
			{
				$NG->log->error("Failed to save inventory for Class of Service Index '$index': $subError");
			}
			else
			{
				$NG->log->debug( "Saved Class of Service '$juniperCoSData->{jnxCosFcName}' for interface '$juniperCoSData->{IntName}'; op: $op");
				$changesweremade = 1;
			}
		}
		else
		{
			$NG->log->debug("jnxCoStable: update_plugin: skipping index=$index as doesn't match regex.");
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
