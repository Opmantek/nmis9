#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

# The average utilisation will be calculated for each interface for the last X minutes
use strict;
use warnings;

# *****************************************************************************

my $syslog_facility = 'local3';
my $syslog_server = 'localhost:udp:514';

my $nmisEventProcessing = 0;

my $defaultLevel = "Major";

my $circuitAlerts = 1;


my $extraLogging = 0;
# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";
						
use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Notify;
use NMISNG::rrdfunc;
use Compat::NMIS;
use Data::Dumper;

### setup the NMIS9 env
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $node = $cmdline->{node};
my $groups = $cmdline->{groups};

my $debug = defined $cmdline->{debug} ? $cmdline->{debug} : 1;


my $info = defined $cmdline->{info} 
    ? NMISNG::Util::getbool($cmdline->{info}) 
    : 1;

my $nmisConfig = NMISNG::Util::loadConfTable( dir => "$FindBin::Bin/../conf", debug => $debug, info => undef);

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logfile = $nmisConfig->{'<nmis_logs>'} . "/cps6000.log";
#print "logfile = $logfile\n";
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => $logfile );
#print "logger = ". Dumper($logger)."\n";
print "***************************Script cps6000_alerts started***************************\n";
$logger->info("Starting cps6000_alerts script\n");

my $nmisng = NMISNG->new(config => $nmisConfig, log => $logger);


if (NMISNG::Util::existFile(dir=>'conf',name=>'nocSyslog')) {
	my $syslogConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'nocSyslog');
	$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
	$syslog_server = $syslogConfig->{syslog}{syslog_server};
	$extraLogging = NMISNG::Util::getbool($syslogConfig->{syslog}{extra_logging});
}

print "cps6000_alerts.pl: syslog_server=$syslog_server syslog_facility=$syslog_facility extraLogging=$extraLogging\n" if $info;


if ($node) {
	processAllNodes($node,$nmisng);
}
else {
	processAllNodes(undef, $nmisng);
}

#For the circuit groups which have worked, get them from the MIB
sub updateCircuitGroups
{    
	my $nmisng = shift;
	my $node = shift;
	my $CG_New;

	print "updateCircuitGroups: $node\n" if $node;
	my $nodeobj = $nmisng->node(name => $node);
	
	my $S = NMISNG::Sys->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	
	my $CG = NMISNG::Util::loadTable(dir=>'conf',name=>'CircuitGroups');
	$logger->info("updateCircuitGroups CG at start: ".Dumper($CG));
	#print "CG at start ".Dumper($CG);

	my $cps6000Groups_result = $nmisng->get_inventory_model(node_uuid => $nodeobj->uuid, concept => "cps6000Groups", filter => { historic => 0 });
	#$logger->info("updateCircuitGroups cps6000Groups_result: ".Dumper($cps6000Groups_result));
	#print "updateCircuitGroups cps6000Groups_result: ".Dumper($cps6000Groups_result)."\n";
	if (my $error = $cps6000Groups_result->error)
	{
		print "failed to lookup inventory records for cps6000Grp: $error \n";
		$logger->error("ERROR: failed to lookup inventory records for cps6000Grp: $error");
		return;
	}
	my %data_cps6000Groups = map { ($_->{data}->{index} => $_->{data}) } (@{$cps6000Groups_result->data});
	$logger->info("updateCircuitGroups ifdata: ".Dumper(\%data_cps6000Groups));
	#print "updateCircuitGroups ifdata: ".Dumper(\%data_cps6000Groups)."\n";
	
	my $cps6000Grp = $nmisng->get_inventory_model(node_uuid => $nodeobj->uuid, concept => "cps6000Grp", filter => { historic => 0 });
	#$logger->info("updateCircuitGroups cps6000Grp: ".Dumper($cps6000Grp));
	#print "updateCircuitGroups cps6000Grp: ".Dumper($cps6000Grp)."\n";
	if (my $error = $cps6000Grp->error)
	{
		print "failed to lookup inventory records for cps6000Grp: $error \n";
		$logger->error("ERROR: failed to lookup inventory records for cps6000Grp: $error");
		return;
	}
	my %cps6000Grp_data = map { ($_->{data}->{index} => $_->{data}) } (@{$cps6000Grp->data});
	$logger->info("updateCircuitGroups cps6000Grp_data: ".Dumper(\%cps6000Grp_data));
	#print "updateCircuitGroups cps6000Grp_data ifdata: ".Dumper(\%cps6000Grp_data)."\n";

	

	foreach my $groupId ( keys %cps6000Grp_data) {
		if ( $cps6000Grp_data{$groupId}{cpsGrpEntryIde} 
			and $cps6000Grp_data{$groupId}{cpsGrpEntryIde} ne "GR000" 
			and $cps6000Grp_data{$groupId}{cpsGrpEntryDes} 
			and $cps6000Grp_data{$groupId}{cpsGrpEntryDes} !~ /FTTN DEFAULT GROUP|noSuchInstance/i 
		) 
		{
			my $circuitGroup = $cps6000Grp_data{$groupId}{cpsGrpEntryDes};
			#print "updateCircuitGroups circuitGroup: ".Dumper($circuitGroup)."\n";
			$logger->info("updateCircuitGroups circuitGroup: ".Dumper($circuitGroup));
			my $dslamNode = undef;
			if ( $circuitGroup ) {
				my @tmp = split(" ",$circuitGroup);
				$dslamNode = $tmp[0];
			}
			
			$dslamNode = $dslamNode ? $dslamNode : $CG->{$circuitGroup}{dslamNode};
			#print "updateCircuitGroups dslamNode: ".Dumper($dslamNode)."\n";
			$logger->info("updateCircuitGroups dslamNode: ".Dumper($dslamNode) );
			my $shelf = $CG->{$circuitGroup}{shelf} ? $CG->{$circuitGroup}{shelf} : "undef";
			#print "updateCircuitGroups shelf: ".Dumper($shelf)."\n";
			$logger->info("updateCircuitGroups shelf: ".Dumper($shelf) );
			my $cable = $CG->{$circuitGroup}{cable} ? $CG->{$circuitGroup}{cable} : "undef";
			$logger->info("updateCircuitGroups cable: ".Dumper($cable) );
			#print "updateCircuitGroups cable: ".Dumper($cable)."\n";
			my $cuenta = $CG->{$circuitGroup}{cuenta} ? $CG->{$circuitGroup}{cuenta} : "undef";
			$logger->info("updateCircuitGroups cuenta: ".Dumper($cuenta) );
			#print "updateCircuitGroups cuenta: ".Dumper($cuenta)."\n";
			my $direccion = $CG->{$circuitGroup}{direccion} ? $CG->{$circuitGroup}{direccion} : "undef";
			$logger->info("updateCircuitGroups direccion: ".Dumper($direccion) );
			#print "updateCircuitGroups direccion: ".Dumper($direccion)."\n";

			$CG->{$circuitGroup} = {
				'circuitGroup' => $circuitGroup,
				'circuits' => $cps6000Grp_data{$groupId}{cpsGrpEntryCct},
				'geNode' => $node,
				'dslamNode' => $dslamNode,
				'groupId' => $groupId,
				'shelf' => $shelf,
				'cable' => $cable,
				'cuenta' => $cuenta,
				'direccion' => $direccion,
			};
		}
	}

	foreach my $key (keys %$CG) {
		delete $CG->{$key} if ref($CG->{$key}) eq 'HASH' && !%{ $CG->{$key} };
	}
	#print "updateCircuitGroups CG After : ".Dumper($CG)."\n";
	$logger->info("updateCircuitGroups CG After: ".Dumper($CG));
	NMISNG::Util::writeTable(dir=>'conf',name=>'CircuitGroups',data=>$CG);
	# my $count = scalar keys %{$CG};
	# print "Number of keys in CG: $count\n";
	

}

sub processAllNodes {

	my ($node, $nmisng) = @_;
	my $nodes;
	my $cluster_id;
	my $active;

	my $cfgdir = "$FindBin::RealBin/../conf";
	my $conf = NMISNG::Util::loadConfTable(dir => $cfgdir, debug => $debug);
	my $filename = "$conf/CircuitGroups.nmis";
	
	if (! -e $filename) 
	{
		#print "File does not exist.\n";
		my $CircuitGroups = ();
		# create empty file
		NMISNG::Util::writeTable(dir=>'conf',name=>'CircuitGroups',data=>$CircuitGroups);
	}

	if (defined $node) {
		$nodes = [ $node ];
	} else {
		$nodes = $nmisng->get_node_names(filter => { cluster_id => $nmisConfig->{cluster_id} });
	}

	
	#print "processAllNodes nodes = ".Dumper ($nodes)."\n";
    
	foreach my $node (sort @$nodes) {
		
		my $S = NMISNG::Sys->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

		my $nodeobj = $nmisng->node(name => $node);
		
		#print "nodeobj = ".Dumper ($nodeobj);
		if ( !$nodeobj)  {
			$logger->fatal("Node $node failed to get the $nodeobj");
			die "Node $node failed to get the $nodeobj .\n";
		}
		if ($nodeobj) {
			# is the node active?
			my ($nmisConfiguration,$error) = $nodeobj->configuration();
			#print "processNode:nmisConfiguration ". Dumper($nmisConfiguration)."\n" if $nmisConfiguration;
			$active = $nmisConfiguration->{active};
			my $collect = $nmisConfiguration->{collect};
			my $group = $nmisConfiguration->{group};
			my $host = $nmisConfiguration->{host};
			$cluster_id = $nodeobj->cluster_id;
			my $model = $nmisConfiguration->{model};
			# print "processNode:model $model\n" if $model;
			# print "processNode:active $active\n" if $active;
			# print "processNode:collect $collect\n" if $collect;

			my $sys;

			# Only locals and active nodes
			if (defined $active && defined $collect && $active && $collect) {

				#print "$node is active and local\n";
				 if (defined $model && $model eq "GE-QS941") {
					print "***************************processAllNodes:Processing $node ***************************\n" if $info;
					updateCircuitGroups($nmisng,$node);
					processNode($nmisng, $node, $model, $S, $nodeobj);
				}
			}
		}	
		else {
			#print " $node active=$active $cluster_id $nmisConfig->{cluster_id}\n";
			$logger->info("$node active=$active $cluster_id $nmisConfig->{cluster_id}\n");
		}
		
	}
	$logger->info("Script cps6000_alerts has concluded\n");
	print "***************************Script cps6000_alerts has concluded.***************************\n";
}

sub processNode {
	my $nmisng = shift;
	my $node = shift;
	my $model = shift;
	my $S = shift;
	my $nodeobj = shift;
	
	if ($node) {
		print "***************************In processNode processing node $node which has model $model***************************\n" if $info or $debug;
		$logger->info("In processNode processing node $node which has model $model\n");
		
		# using the custom table CircuitGroups to get the group name from.
		my $CG = NMISNG::Util::loadTable(dir=>'conf',name=>'CircuitGroups');
		my %groupIdx;
		my %groupList;
		#initialise the unknown group for the SNMP bug in QS941
		$groupList{"$node Unknown"}{desc} = "$node Unknown";
		$groupList{"$node Unknown"}{circuits} = 0;
		$groupList{"$node Unknown"}{faulty} = 0;
		#print "CG = \n".Dumper($CG);

		for my $cg (sort {$a cmp $b} keys %{$CG}) {
			#print "cg = $cg\n";
			# Only interested in Circuit Groups setup for the GE Node we are managing.
			if ( exists $CG->{$cg}{geNode} and $node eq $CG->{$cg}{geNode} ) {
				# if the group id came from a good place.
				my $groupId = $CG->{$cg}{groupId};

				$groupList{$cg}{desc} = $cg;				
				$groupList{$cg}{circuits} = 0;				
				$groupList{$cg}{faulty} = 0;				
				my @circuits = split(",",$CG->{$cg}{circuits});
				
				if (@circuits){
					# print "DEBUG: circuits\n";
					# print Dumper \@circuits;
					foreach my $circuit (@circuits) {
						# get the index loaded
						$groupIdx{$circuit} = $cg;
					}
				}
				print "$node Group: '$cg' DSLAM=$CG->{$cg}{dslamNode}\n" if $info or $debug;
			}
		}
		# print "DEBUG: groupList for $node \n";
		# print Dumper \%groupList;

		# print "DEBUG: groupIdx for $node \n";
		# print Dumper \%groupIdx;
		
		my $cps6000Cct = $nmisng->get_inventory_model(concept => "cps6000Cct", filter => { historic => 0 });
		#print "updateCircuitGroups cps6000Cct: ".Dumper($cps6000Cct)."\n";
		if (my $error = $cps6000Cct->error)
		{
			print "failed to lookup inventory records for cps6000Cct: $error \n";
			$logger->error("ERROR: failed to lookup inventory records for cps6000Cct: $error");
			return;
		}

		my $cps6000Cct_inventory_data = $cps6000Cct->data; # r/o copy, must be saved back if changed
		#print "updateCircuitGroups cps6000Cct_inventory_data : ".Dumper(\$cps6000Cct_inventory_data)."\n";

		my %cps6000Cct_data = map { ($_->{data}->{index} => $_->{data}) } (@{$cps6000Cct->data});
		#print "updateCircuitGroups cps6000Cct_data : ".Dumper(\%cps6000Cct_data)."\n";

		if ( %cps6000Cct_data) {
			my $circuitFaulty = 0;
			# Loop through top-level keys
			foreach my $circuitIndex (sort keys %cps6000Cct_data) {
				#print "circuitIndex: $circuitIndex\n";
				my $entry = $cps6000Cct_data{$circuitIndex};
				my $circuitId = $cps6000Cct_data{$circuitIndex}->{cpsCctEntryIde};
				#print "circuitId: $circuitId\n";

				my $groupId = "$node Unknown";
				my $groupDesc = "$node Unknown";
				my $dslamNode = undef;
				my $infoForDetails = undef;
				if ( exists $groupIdx{$circuitId} and $groupIdx{$circuitId} ne "" ) {
					$groupId = $CG->{$groupIdx{$circuitId}}{groupId};
					#print "groupId: $groupId\n";
					$groupDesc = $CG->{$groupIdx{$circuitId}}{circuitGroup};
					$dslamNode = $CG->{$groupIdx{$circuitId}}{dslamNode};				
				}
				else {
					$groupIdx{$circuitId} = "$node Unknown";
				}

				$groupId = "$node Unknown" if not $groupId;
				$groupDesc = "$node Unknown" if not $groupDesc;
				
				#  $groupId is defined and the key $groupList{$groupId}{circuits} already exists it increments the circuit count for that group by 1
				if ( $groupId and exists $groupList{$groupId}{circuits} ) {
					++$groupList{$groupId}{circuits};
				}
				else {
					$groupList{$groupId}{circuits} = 1;
				}

				$cps6000Cct_data{$circuitIndex}{cpsCctEntryGrp} = $groupDesc;
				$cps6000Cct_data{$circuitIndex}{cpsCctEntryGrp_title} = 'Circuit Group';
				#$cps6000Cct_inventory_data->[$circuitIndex]{'data'}{'cpsCctEntryGrp'} = $groupDesc;
				# $cps6000Cct_inventory_data->[$circuitIndex]{'data'}{'cpsCctEntryGrp_title'} = 'Circuit Group';

				if ( $dslamNode and exists $groupIdx{$circuitId} ) {
					
					$infoForDetails = "$dslamNode $CG->{$groupIdx{$circuitId}}{shelf} $CG->{$groupIdx{$circuitId}}{cable} $CG->{$groupIdx{$circuitId}}{cuenta} $CG->{$groupIdx{$circuitId}}{direccion}";
					
					#$infoForDetails = "No info details available in CircuitGroups.nmis";
					
				}
				else {
					$infoForDetails = "No circuit details available";
				}
				print "$node Circuit: $cps6000Cct_data{$circuitIndex}{cpsCctEntryDes} $groupId $infoForDetails\n" if $info or $debug;
				$logger->debug("$node Circuit: $cps6000Cct_data{$circuitIndex}{cpsCctEntryDes} $groupId $infoForDetails");

				## detect condition
				my $element = "Circuit $cps6000Cct_data{$circuitIndex}{cpsCctEntryIde}";
				my $event = undef;
				my $level = undef;
				my $details = undef;
				#print  "cpsCctEntryStt = $cps6000Cct_data{$circuitIndex}{cpsCctEntryStt} \n";
				# Circuitos Sin Comunicación - No Communication Circuits:
				#"Circuitos Sin Comunicación" translates to "Circuits Without Communication", and it refers to circuits that are not sending data or have lost communication with the central monitoring system.
				#  if STT in ['MISSING','STANDBY(USER)']:
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryStt} ) {
					$event = "Alert: Circuitos Sin Comunicación";
					$details = "$infoForDetails: STT=$cps6000Cct_data{$circuitIndex}{cpsCctEntryStt}";
					$level = "Normal";
					# Does the condition exist now?
					if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryStt} =~ /80|20/ ) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}

				# Circuitos Sin Comunicación (Falla desconocida) - No Communication Circuits (unknown failure):
				#  All Variables set to 0
				$event = "Alert: Circuitos Sin Comunicación (Falla desconocida)";
				$details = "$infoForDetails: STT=$cps6000Cct_data{$circuitIndex}{cpsCctEntryStt}";
				$level = "Normal";
				# Does the condition exist now?
				# can this ever happen?
				if ( 0 ) {						
					$level = $defaultLevel;
					++$circuitFaulty;
				}
				# set the event properties and process the condition (state)
				processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;

				# Pares Abiertos - Open couple:
				#"Pares Abiertos" in English translates to "Open Pairs".
				# Open Pairs typically refers to twisted pair wires (like in telecom or networking) that are:
				# Not connected at one or both ends
				# Unused or left open, often causing signal loss or communication failure
				#  if (ADC in range(1,5)) and (VDC>=370)
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} 
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}
				) {
					$event = "Alert: Pares Abiertos";
					$details = "$infoForDetails: ADC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} VDC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}";
					$level = "Normal";
					# Does the condition exist now?
					if ( 
						$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} >= 1
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} <= 5
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} >= 370
					) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}

				# Pares Averiados - couple damaged
				# "Pares Averiados" translates to "Faulty Pairs" or "Damaged Pairs" in English.
				# In systems using twisted-pair wiring (like telecom, networking, or power distribution), "pares averiados" refers to:
				# Wire pairs that are physically damaged, shorted, cut, or experiencing interference
				# Pairs that fail continuity or signal integrity tests
				#  if ( (ADC in range(0,8)) or (VDC in range(30,300)) ) and ( (LDS==1) or (CFL==1) )
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} 
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryLds}
				) {
					$event = "Alert: Pares Averiados";
					$details = "$infoForDetails: ADC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} VDC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} LDS=$cps6000Cct_data{$circuitIndex}{cpsCctEntryLds} CFL=$cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}";
					$level = "Normal";
					# Does the condition exist now?
					if (
						$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} >= 0
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} <= 8
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} >= 30
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} <= 300
						and 
						( $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl} == 1
						or  $cps6000Cct_data{$circuitIndex}{cpsCctEntryLds} == 1 )
					) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}

				# Tarjeta Desconectada - Card Offline
				# "Tarjeta Desconectada" translates to "Card Disconnected" in English.
				# Refers to a hardware card (e.g., power supply unit, controller card, communication module) that is:
				# Physically removed
				# Unplugged
				# Not detected by the system
				#  if ((ADC in range(0,5)) and (VDC>=370)) and CFL==0:
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} 
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}
				) {							
					$event = "Alert: Tarjeta Desconectada";
					$details = "$infoForDetails: ADC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} VDC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} CFL=$cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}";
					$level = "Normal";
					# Does the condition exist now?
					if ( 
						$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} >= 0
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} <= 5
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} >= 370
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl} == 0
					) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}

				# Carga en Descenso - Loading Up
				# "Carga en Descenso" translates to "Load Decreasing" or "Decreasing Load" in English.
				# Indicates that the electrical load or power consumption on a system or circuit is going down
				# Could be due to:
				# Devices being turned off
				# Reduced demand
				# Automatic load shedding 
				# System adjustments or failures
				#  if ( (ADC in range(8,38)) and (VDC>=370) and (LDS==1) ):
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} 
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryLds}
				) {
					$event = "Alert: Carga en Descenso";
					$details = "$infoForDetails: ADC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} VDC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} LDS=$cps6000Cct_data{$circuitIndex}{cpsCctEntryLds}";
					$level = "Normal";
					# Does the condition exist now?
					if ( 
						$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} >= 8
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} <= 38
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} >= 370
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryLds} == 1
					) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}

				# Corto en Central - Short on Central
				# "Corto en Central" translates to "Short in Central" or more clearly, "Short Circuit in Central Office" 
				#  if ( (ADC<=3) and (VDC<=30) and (CFL==1) ):
				if ( $cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} 
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc}
					and $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}
				) {
					$event = "Alert: Corto en Central";
					$details = "$infoForDetails: ADC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} VDC=$cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} CFL=$cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl}";
					$level = "Normal";
					# Does the condition exist now?
					if ( 
						$cps6000Cct_data{$circuitIndex}{cpsCctEntryAdc} <= 3
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryVdc} <= 30
						and $cps6000Cct_data{$circuitIndex}{cpsCctEntryCfl} == 1
					) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S, $node, $nodeobj, $event, $element, $details, $level) if $circuitAlerts;
				}
				
				# if any of the conditions apply the circuit is faulty, but only once.
				if ( $circuitFaulty ) {
					++$groupList{$groupId}{faulty};
				}
				
			} # End of for loop

			# print "DEBUG: groupList faulty for $node \n";
			# print Dumper \%groupList;
		}

		#print "updateCircuitGroups After modfiy cps6000Cct_data : ".Dumper(\%cps6000Cct_data)."\n";
		# 10 circuits, 1 faulty circuit = 10% power loss, fault/circuits * 100
		foreach my $groupId ( keys %groupList ) {
			## do not create alerts on the default group
			my $groupDesc = $groupList{$groupId}{desc};
			if ( $groupId 
				and $groupId ne "GR000" 
				and $groupDesc 
				and $groupDesc !~ /FTTN DEFAULT GROUP|noSuchInstance/i 
				and exists $CG->{$groupId}{circuits}
				and $CG->{$groupId}{circuits} ne ""
			) {
				my $potency = $groupList{$groupId}{circuits} * 65;
				my $potencyLoss = $groupList{$groupId}{faulty} * 65;
				my $powerLoss = "0";
				if ( $potencyLoss > 0 and $potency > 0 ) {
					$powerLoss = sprintf("%.2f",($potencyLoss / $potency) * 100);
				}
				
				my $infoForDetails = undef;
				if ( exists $CG->{$groupId}{dslamNode} ) {
					#TODO remove this later now developing gives unwanted noise
					$infoForDetails = "$CG->{$groupId}{dslamNode} $CG->{$groupId}{shelf} $CG->{$groupId}{cable} $CG->{$groupId}{cuenta} $CG->{$groupId}{direccion}";
					# $infoForDetails = "No info details available in CircuitGroups.nmis";
				}
				else {
					$infoForDetails = "No circuit group details available";
				}

				#NORMAL, 0%
				my $level = "Normal";
				
				#FATAL, Power Lost > 90%
				if ( $powerLoss > 90 ) {
					$level = "Fatal";
				}
				#CRITICAL, Power lost > 50 %
				elsif ( $powerLoss > 50 ) {
					$level = "Critical";
				}
				#MAJOR, Power Lost = > 30 % & < = 50 %
				elsif ( $powerLoss >= 30 and $powerLoss <= 50) {
					$level = "Major";
				}
				#MINOR, Power Lost <30 %
				elsif ( $powerLoss < 30 and $powerLoss > 0  ) {
					$level = "Minor";
				}

				my $event = "Alert: DSLAM Power Loss";
				my $element = $groupId;
				my $details = "$infoForDetails: potency=$potency potencyLoss=$potencyLoss powerLoss=$powerLoss";
				print "node=$node, groupId=$groupId, infoForDetails=$infoForDetails, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level\n" if $info or $debug;
				$logger->info("node=$node, groupId=$groupId, infoForDetails=$infoForDetails, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level");
				processCondition($S, $node, $nodeobj, $event, $element, $details, $level);
			}
			elsif (not $groupDesc) {
				print "WARNING node=$node, groupId=$groupId Group Description is empty in circuit group\n"  if $info or $debug;						
			}
		}
		
		
	}
	

}  # end of processNode

sub processCondition {
	my $S = shift;
	my $node = shift;
	my $nodeobj = shift;
	my $event = shift;
	#my $event = "Fatal"; ## to test if event is generated or not.
	my $element = shift;
	my $details = shift;
	my $level = shift;
	my $sendSyslog = 0;

	my $condition = 0;

	$logger->info("processCondition: $node, $event, $level, $element, $details") if $extraLogging;

	# # Did the condition exist previously?
	my $eventExists = $nodeobj->eventExist($node, $event, $element);
	#print "processCondition:eventExists $eventExists\n";

	if ( $eventExists and $level =~ /Normal/i) {
	 	# Proactive Closed.
	 	$condition = 1;
		Compat::NMIS::checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>$element,details=>$details);
	 	$event = "$event Closed" if $event !~ /Closed/;
		if ( NMISNG::Util::getbool($nmisEventProcessing) ) {
			Compat::NMIS::checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>$element,details=>$details);
		}
		else {						
			$nodeobj->eventDelete(
				event => {
					event => $event, 
					element => $element 
				});
		}
		$event = "$event Closed" if $event !~ /Closed/;
		$sendSyslog = 1;
	}
	elsif ( not $eventExists and $level =~ /Normal/i) {
		$condition = 2;
		# Life is good, nothing to see here.
	}
	elsif ( not $eventExists and $level !~ /Normal/i) {
		$condition = 3;
		$event =~ s/ Closed//g;
		#print "processCondition:event=>$event,level=>$level,element=>$element,details=>$details\n";

		Compat::NMIS::notify(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details);
		$nodeobj->eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
	}
	elsif ( $eventExists and $level !~ /Normal/i) {
		$condition = 4;
		# existing condition
	}
	if ( $sendSyslog ) {
		my $error = NMISNG::Notify::sendSyslog(
			server_string => $syslog_server,
			facility => $syslog_facility,
			nmis_host => $nmisConfig->{server_name},
			time => time(),
			node => $node,
			event => $event,
			level => $level,
			element => $element,
			details => $details
		);
		if ( $error ) {
			$logger->error("ERROR: syslog failed to $syslog_server: $node $event $element $details: $error");
		}
		else {
			my $message = "INFO: syslog sent to $syslog_server: $node $event $element $details";
			print "$message\n" if $info;
			$logger->info($message) if $extraLogging;
		}
	}
	print "node=$node, event=$event, level=$level, element=$element, details=$details\n" if $info or $debug;
	
}
