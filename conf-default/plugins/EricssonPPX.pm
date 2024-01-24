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

package EricssonPPX;
our $VERSION = "2.0.0";

use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;				# for snmp-related access

# *****************************************************************************
# Set ths to delete the empty Cards instead of suppressing their display!
# *****************************************************************************
my $deleteEmptyCards = 0;
# *****************************************************************************

my $changesweremade = 0;

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $intfData = undef;
	my $intfInfo = undef;

	my $nodeobj    = $NG->node(name => $node);
	my %nodeconfig = %{$S->nmisng_node->configuration};
	my $NC         = $nodeobj->configuration;
	my $catchall   = $S->inventory( concept => 'catchall' )->{_data};
	my $cardTotal  = 0;
	my $snmpData;

	$NG->log->debug9(sub {"\$node:        " . Dumper($node) . "\n\n\n"});
	$NG->log->debug9(sub {"\$S:           " . Dumper($S) . "\n\n\n"});
	$NG->log->debug9(sub {"\$C:           " . Dumper($C) . "\n\n\n"});
	$NG->log->debug9(sub {"\$NG:          " . Dumper($NG) . "\n\n\n"});
	$NG->log->debug9(sub {"\$nodeconfig:  " . Dumper(%nodeconfig) . "\n\n\n"});

	my $ppxCardMemIds = $S->nmisng_node->get_inventory_ids(
		concept => "ppxCardMEM",
		filter => { historic => 0 });
	if (!@$ppxCardMemIds)
	{
		$NG->log->debug("Prerequisite ppxCardMEM not found in node '$node'");
		$NG->log->debug("Node '$node', does not qualify for this plugin.");
		return (0,undef);
	}


	$NG->log->info("Working on node '$node' 'ppxCardMEM'");

	# nmisng::snmp doesn't fall back to global config
	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};

	# Get the SNMP Session going.

	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		my $error = $snmp->error;
		undef $snmp;
		$NG->log->error("Could not open SNMP session to node '$node': ".$error);
		return (2, "Could not open SNMP session to node '$node': ".$error);
	}
	if (!$snmp->testsession)
	{
		my $error = $snmp->error;
		$snmp->close;
		$NG->log->warn("Could not retrieve SNMP vars from node '$node': ".$error);
		return (2, "Could not retrieve SNMP vars from node '$node': ".$error);
	}
	
	my $changesweremade = 0;

	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.fastRam = Gauge32: 0
	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.normalRam = Gauge32: 65536
	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.sharedRam = Gauge32: 2048
	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.fastRam = Gauge32: 0
	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.normalRam = Gauge32: 37316
	#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.sharedRam = Gauge32: 2048  

	#"mscShelfCardMemoryCapacityValue"		"1.3.6.1.4.1.562.36.2.1.13.2.244.1.2"
	#"mscShelfCardMemoryUsageValue"			"1.3.6.1.4.1.562.36.2.1.13.2.245.1.2"
	#"mscShelfCardMemoryUsageAvgValue"		"1.3.6.1.4.1.562.36.2.1.13.2.276.1.2"
	#"mscShelfCardMemoryUsageAvgMinValue"	"1.3.6.1.4.1.562.36.2.1.13.2.277.1.2"
	#"mscShelfCardMemoryUsageAvgMaxValue"	"1.3.6.1.4.1.562.36.2.1.13.2.278.1.2"

	my $memCapacityOid = ".1.3.6.1.4.1.562.36.2.1.13.2.244.1.2";
	my $memUsageOid    = ".1.3.6.1.4.1.562.36.2.1.13.2.245.1.2";
	my $memUsageAvgOid = ".1.3.6.1.4.1.562.36.2.1.13.2.276.1.2";
	my $memUsageMinOid = ".1.3.6.1.4.1.562.36.2.1.13.2.277.1.2";
	my $memUsageMaxOid = ".1.3.6.1.4.1.562.36.2.1.13.2.278.1.2";

	my $fastRam   = "0";
	my $normalRam = "1";
	my $sharedRam = "2";

	# Based on each of the cards we know about from CPU, we are going to look for each of the memory value.
	for my $ppxCardMemId (@$ppxCardMemIds)
	{
		my ($inventory,$error) = $S->nmisng_node->inventory(_id => $ppxCardMemId);
		if ($error)
		{
		    $NG->log->warn("Failed to get 'cempMemPool' inventory for Node '$node'; ID $ppxCardMemId; Error: $error");
		    next;
		}

		my $ppxCardMemData = $inventory->data; # r/o copy, must be saved back if changed
        my $name           = $ppxCardMemData->{mscShelfCardComponentName};
        my $index          = $ppxCardMemData->{index};

		$NG->log->info("inventory for Node '$node', Card '$index'; Name: '$name'.");

		# Declare the required VARS
		my @oids = (
				"$memCapacityOid.$index.$fastRam",
				"$memCapacityOid.$index.$normalRam",
				"$memCapacityOid.$index.$sharedRam",
				"$memUsageOid.$index.$fastRam",
				"$memUsageOid.$index.$normalRam",
				"$memUsageOid.$index.$sharedRam",
				"$memUsageAvgOid.$index.$fastRam",
				"$memUsageAvgOid.$index.$normalRam",
				"$memUsageAvgOid.$index.$sharedRam",
				"$memUsageMinOid.$index.$fastRam",
				"$memUsageMinOid.$index.$normalRam",
				"$memUsageMinOid.$index.$sharedRam",
				"$memUsageMaxOid.$index.$fastRam",
				"$memUsageMaxOid.$index.$normalRam",
				"$memUsageMaxOid.$index.$sharedRam",
			);
		
		# Get the snmp data from the thing
		$snmpData = $snmp->get(@oids);
		if ( $snmp->error() ) {
			$NG->log->debug("ERROR with SNMP on '$node'; Error: ". $snmp->error());
		}

		if ( $snmpData ) {
			$NG->log->debug("SNMP data: ". $snmpData);

			if ( ($snmpData->{"$memCapacityOid.$index.$fastRam"} == 0 or $snmpData->{"$memCapacityOid.$index.$fastRam"} eq "noSuchInstance")
				and ($snmpData->{"$memCapacityOid.$index.$normalRam"} == 0 or $snmpData->{"$memCapacityOid.$index.$normalRam"} eq "noSuchInstance")
				and ($snmpData->{"$memCapacityOid.$index.$sharedRam"} == 0 or $snmpData->{"$memCapacityOid.$index.$sharedRam"} eq "noSuchInstance")
			) {
                if ($deleteEmptyCards) {
					$NG->log->info("Card '$index'; Name: '$name' has no memory information, deleting the card.");
					my ($ok, $deleteError) = $inventory->delete();
					if ($deleteError)
					{
						$NG->log->error("Failed to delete inventory for Card '$index'; Name: '$name': $deleteError");
					}
				} else {
					$NG->log->info("Card '$index'; Name: '$name' has no memory information, removing from display.");
					$inventory->data_info(
						subconcept => "ppxCardMEM",
						enabled => 0
					);
				}
			}

			my $data = { 
				'memCapFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memCapacityOid.$index.$fastRam"} },
				'memCapNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memCapacityOid.$index.$normalRam"} },					
				'memCapSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memCapacityOid.$index.$sharedRam"} },

				'memUsageFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageOid.$index.$fastRam"} },
				'memUsageNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageOid.$index.$normalRam"} },					
				'memUsageSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageOid.$index.$sharedRam"} },

				'memAvgFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageAvgOid.$index.$fastRam"} },
				'memAvgNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageAvgOid.$index.$normalRam"} },					
				'memAvgSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageAvgOid.$index.$sharedRam"} },

				'memMinFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMinOid.$index.$fastRam"} },
				'memMinNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMinOid.$index.$normalRam"} },					
				'memMinSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMinOid.$index.$sharedRam"} },

				'memMaxFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMaxOid.$index.$fastRam"} },
				'memMaxNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMaxOid.$index.$normalRam"} },					
				'memMaxSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpData->{"$memUsageMaxOid.$index.$sharedRam"} },
			};

			# Save the results to the concept..
			$ppxCardMemData->{'memCapFastRam'}   = $snmpData->{"$memCapacityOid.$index.$fastRam"};
			$ppxCardMemData->{'memCapNormalRam'} = $snmpData->{"$memCapacityOid.$index.$normalRam"};
			$ppxCardMemData->{'memCapSharedRam'} = $snmpData->{"$memCapacityOid.$index.$sharedRam"};
			$inventory->data( $ppxCardMemData );

			my $filename = $S->create_update_rrd(data=>$data, sys=>$S, type=>"ppxCardMEM", index => $index);
			if (!$filename)
			{
				$NG->log->error("Failed to Update RRD inventory for Card '$index'; Name: '$name'.");
			}		

			# The above has added data to the inventory, that we now save.
			my ( $op, $saveError ) = $inventory->save( node => $node );
			$NG->log->debug2(sub { "saved op: $op"});
			if ($saveError)
			{
				$NG->log->error("Failed to save inventory for Card '$index'; Name: '$name': $saveError");
			}
			else
			{
				$changesweremade = 1;
				$cardTotal++;
			}
		}
		else {
			$NG->log->error("Problem with SNMP session to $node: ".$snmp->error());
		}
	}
	if ($changesweremade)
	{
		$NG->log->info("$cardTotal Cards were updated.");
	}
	else
	{
		$NG->log->info("No Cards were updated.");
	}
	$snmp->close;

	return ($changesweremade,undef); # report if we changed anything
}

1;
