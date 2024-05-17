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

package combinedCPULoad;
our $VERSION = "2.0.0";

use strict;
use warnings;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;				# for snmp-related access

my $changesweremade = 0;

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# is the node down or is SNMP down?
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return (0, "combinedCPULoad: Failed to instantiate catchall inventory: $error") if ($error);

	my $catchall_data = $inventory->data();
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
		$NG->log->debug("combinedCPULoad: Skipping Host Resources plugin for node::$node, Node Down");
		return (0, "combinedCPULoad: Node Down, skipping Host Resources plugin");
	}
	elsif ( NMISNG::Util::getbool( $catchall_data->{snmpdown} ) ) {
		$NG->log->debug("combinedCPULoad: Skipping Host Resources plugin for node::$node, SNMP Down");
		return (0, "combinedCPULoad: SNMP Down, skipping Host Resources plugin");
	}
	else {
		$NG->log->debug("combinedCPULoad: Attempting Combined CPU Load plugin for node::$node");
	}

	my $host_ids = $S->nmisng_node->get_inventory_ids(
		concept => "device",
		filter => { historic => 0, "data.hrDeviceType" => "1.3.6.1.2.1.25.3.1.3" });
	
	if (@$host_ids)
	{
		$NG->log->debug("combinedCPULoad: Running Combined CPU Load plugin for node::$node");
		# for saving all the types of memory we want to use
		my $cpu_total   = 0;
		my $cpu_max     = 0;
		my $cpu_count   = 0;
		my $cpu_average = 0;

		my $rrddata = {};
        
		# look through each of the different types of memory for cache and buffer
		for my $host_id (@$host_ids)
		{
			my ($host_inventory,$error) = $S->nmisng_node->inventory(_id => $host_id);
			if ($error)
			{
				$NG->log->error("combinedCPULoad: Failed to get inventory $host_id: $error");
				next;
			}

			my $data = $host_inventory->data();

			$NG->log->debug("combinedCPULoad: Data: " . Dumper($data) . "'");
            
			# sanity check the data
			if ( ref($data) ne "HASH"
				or !keys %$data
				or !exists( $data->{index} ) )
			{
				my $index = $data->{index} // 'noindex';
				$NG->log->error("combinedCPULoad: Invalid data for index $index in model, cannot get data for this index!");
				next;
			}
			$changesweremade = 1;
			my $index = $data->{index};
            
			# Get each CPU
			$cpu_count++;
			$cpu_total += $data->{"hrCpuLoad"};
			$cpu_max    = $data->{"hrCpuLoad"} if ($data->{"hrCpuLoad"} > $cpu_max);

			$rrddata->{"cpu_$index"} = { "option" => "GAUGE,0:U", "value" => $data->{"hrCpuLoad"}},

        } # Foreach

		$cpu_average = $cpu_total / $cpu_count;
		$rrddata->{'cpu_total'} = { "option" => "GAUGE,0:U", "value" => $cpu_total};
		$rrddata->{'cpu_max'} = { "option" => "GAUGE,0:U", "value" => $cpu_max};
		$rrddata->{'cpu_average'} = { "option" => "GAUGE,0:U", "value" => $cpu_average};
		$rrddata->{'cpu_count'} = { "option" => "GAUGE,0:U", "value" => $cpu_count};

		# updateRRD subrutine is called from rrdfunc.pm module
	    my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, sys=>$S, type=>"combinedCPUload", index => undef);

		# check for RRD update errors
		if (!$updatedrrdfileref) { $NG->log->error("combinedCPULoad: Update RRD failed!") };
    }
	return (1,undef);
}

1;
