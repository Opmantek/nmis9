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

# This program should be run from Cron for the required alerting period, e.g. 5 minutes
#4-59/5 * * * * /usr/local/admin/interface_util_alerts.pl

# The average utilisation will be calculated for each interface for the last X minutes
use strict;
#use warnings;

# *****************************************************************************
my $debugLogging = 0;
my $debugLog = "/usr/local/nmis8/logs/cps6000.log";

my $syslog_facility = 'local3';
my $syslog_server = 'localhost:udp:514';

my $defaultLevel = "Major";

my $circuitAlerts = 1;

my $threshold_period = "-5 minutes";
my $thresholds = {
              'fatal' => '90',
              'critical' => '80',
              'major' => '60',
              'minor' => '20',
              'warning' => '10'
             };

# set this to 1 to include group in the message details, 0 to exclude.
my $includeGroup = 1;

# the seperator for the details field.
my $detailSep = "-- ";

# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";
 
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use Data::Dumper;
use rrdfunc;
use notify;

my %arg = getArguements(@ARGV);

if ( defined $arg{clean} and $arg{clean} eq "true" ) {
	print "Cleaning Events\n";
	cleanEvents();
	exit;
}

# Set debugging level.
my $debug = setDebug($arg{debug});

# Set debugging level.
my $info = setDebug($arg{info});

my $C = loadConfTable(conf=>$arg{conf},debug=>$debug);

if ( $arg{groups} and $arg{groups} eq "true" ) {
	updateCircuitGroups();
	exit 0;
}

processNodes();

exit 0;

#For the circuit groups which have worked, get them from the MIB
sub updateCircuitGroups {    
	my $CG = loadTable(dir=>'conf',name=>'CircuitGroups');

	my $LNT = loadLocalNodeTable();

	foreach my $node (sort keys %{$LNT}) {
		
		# Is the node active and are we doing stats on it.
		if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
			print "Processing $node\n" if $debug;

			my $S = Sys::->new;
			$S->init(name=>$node,snmp=>'false');
			my $NI = $S->ndinfo;

			if ( $NI->{system}{nodeModel} eq "GE-QS941" ) {
				if ( exists $NI->{cps6000Grp} ) {
					# seed some information back into the other model.
					foreach my $groupId ( keys %{$NI->{cps6000Groups}}) {
						if ( $NI->{cps6000Groups}{$groupId}{cpsGrpEntryDes} 
							and $NI->{cps6000Groups}{$groupId}{cpsGrpEntryIde} 
						) {
							$NI->{cps6000Grp}{$groupId}{index} = $NI->{cps6000Groups}{$groupId}{index};
							$NI->{cps6000Grp}{$groupId}{cpsGrpEntryIndex} = $NI->{cps6000Groups}{$groupId}{cpsGrpEntryIndex};
							$NI->{cps6000Grp}{$groupId}{cpsGrpEntryDes} = $NI->{cps6000Groups}{$groupId}{cpsGrpEntryDes};
							$NI->{cps6000Grp}{$groupId}{cpsGrpEntryIde} = $NI->{cps6000Groups}{$groupId}{cpsGrpEntryIde};
						}
					}

					foreach my $groupId ( keys %{$NI->{cps6000Grp}}) {
						if ( $NI->{cps6000Grp}{$groupId}{cpsGrpEntryIde} 
							and $NI->{cps6000Grp}{$groupId}{cpsGrpEntryIde} ne "GR000" 
							and $NI->{cps6000Grp}{$groupId}{cpsGrpEntryDes} 
							and $NI->{cps6000Grp}{$groupId}{cpsGrpEntryDes} !~ /FTTN DEFAULT GROUP|noSuchInstance/i 
						) {
							#push(@circuits,$NI->{cps6000Cct}{$_}{cpsCctEntryIde});
							my $circuitGroup = $NI->{cps6000Grp}{$groupId}{cpsGrpEntryDes};
							my $dslamNode = undef;
							if ( $circuitGroup ) {
								my @tmp = split(" ",$circuitGroup);
								$dslamNode = $tmp[0];
							}
							
							$dslamNode = $dslamNode ? $dslamNode : $CG->{$circuitGroup}{dslamNode};
							my $shelf = $CG->{$circuitGroup}{shelf} ? $CG->{$circuitGroup}{shelf} : undef;
							my $cable = $CG->{$circuitGroup}{cable} ? $CG->{$circuitGroup}{cable} : undef;
							my $cuenta = $CG->{$circuitGroup}{cuenta} ? $CG->{$circuitGroup}{cuenta} : undef;
							my $direccion = $CG->{$circuitGroup}{direccion} ? $CG->{$circuitGroup}{direccion} : undef;

							$CG->{$circuitGroup} = {
						    'circuitGroup' => $circuitGroup,
						    'circuits' => $NI->{cps6000Grp}{$groupId}{cpsGrpEntryCct},
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
					$S->writeNodeInfo; # save node info in file var/$NI->{name}-node	
				}
			}
		}
	}
	writeTable(dir=>'conf',name=>'CircuitGroups',data=>$CG);
}
#  'cps6000Grp' => {
#    '0' => {
#      'cpsGrpEntryAadc' => '0',
#      'cpsGrpEntryCap' => '7196',
#      'cpsGrpEntryCct' => 'K0232,K0231,K0230,K0229,K0228,K0227,K0226,K0225,K0224,K0223,K0222,K0221,K0205,K0206,K0207,K0208,K0209,K0210,K0211,K0212,K0213,K0214,K0215,K0216,K0217,K0218,K0219,K0220',
#      'cpsGrpEntryDes' => 'FTTN Default Group',
#      'cpsGrpEntryIde' => 'GR000',
#      'cpsGrpEntryIndex' => 0,
#      'cpsGrpEntryLrs' => '0',
#      'cpsGrpEntryOlcap' => '7196',
#      'cpsGrpEntryTadc' => '26',
#      'index' => '0'
#    },
#    '2' => {
#      'cpsGrpEntryAadc' => '66',
#      'cpsGrpEntryCap' => '4112',
#      'cpsGrpEntryCct' => 'K0101,K0102,K0103,K0104,K0105,K0106,K0107,K0108,K0109,K0110,K0111,K0112,K0113,K0114,K0115,K0116',
#      'cpsGrpEntryDes' => 'ACCG1 C01 1751-1800',
#      'cpsGrpEntryIde' => 'GR002',
#      'cpsGrpEntryIndex' => 2,
#      'cpsGrpEntryLrs' => '0',
#      'cpsGrpEntryOlcap' => '4112',
#      'cpsGrpEntryTadc' => '1064',
#      'index' => '2'
#    }

sub processNodes {
	my $LNT = loadLocalNodeTable();
		
	foreach my $node (sort keys %{$LNT}) {
		
		# Is the node active and are we doing stats on it.
		if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) and ( $arg{node} eq "" or $arg{node} eq $node) ) {
			print "Processing $node\n" if $debug;
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			$S->readNodeView;
	
			my $NI = $S->ndinfo;
			my $V = $S->view;
	
			if ( $NI->{system}{nodeModel} eq "GE-QS941" ) {
				print "Processing $node\n" if $info;
				
				# building a group index of the unreliable cps6000Grp MIB
				#if ( exists $NI->{cps6000Grp}) {
				#	
				#	#initialise the unknown group for the SNMP bug in QS941
				#	$groupList{"Unknown"}{desc} = "Unknown";
				#	$groupList{"Unknown"}{circuits} = 0;
				#	$groupList{"Unknown"}{faulty} = 0;
				#	
				#	for my $index (sort {$a <=> $b} keys %{$NI->{cps6000Grp}}) {
				#		my $groupId = $NI->{cps6000Grp}{$index}{cpsGrpEntryIde};
				#		$groupList{$groupId}{desc} = $NI->{cps6000Grp}{$index}{cpsGrpEntryDes};				
				#		$groupList{$groupId}{circuits} = 0;				
				#		$groupList{$groupId}{faulty} = 0;				
				#		my @circuits = split(",",$NI->{cps6000Grp}{$index}{cpsGrpEntryCct});
				#		foreach my $circuit (@circuits) {
				#			# get the index loaded
				#			$groupIdx{$circuit} = $index;
				#		}
				#		print "$node Group: $NI->{cps6000Grp}{$index}{cpsGrpEntryDes} Total Current=$NI->{cps6000Grp}{$index}{cpsGrpEntryTadc}: Average Current=$NI->{cps6000Grp}{$index}{cpsGrpEntryAadc}\n" if $info or $debug;
				#	}
				#}
				
				# using the custom table CircuitGroups to get the group name from.
				my $CG = loadTable(dir=>'conf',name=>'CircuitGroups');
				my %groupIdx;
				my %groupList;
				
				#initialise the unknown group for the SNMP bug in QS941
				$groupList{"$node Unknown"}{desc} = "$node Unknown";
				$groupList{"$node Unknown"}{circuits} = 0;
				$groupList{"$node Unknown"}{faulty} = 0;
				
				for my $cg (sort {$a cmp $b} keys %{$CG}) {
					# Only interested in Circuit Groups setup for the GE Node we are managing.
					if ( exists $CG->{$cg}{geNode} and $node eq $CG->{$cg}{geNode} ) {
						# if the group id came from a good place.
						my $groupId = $CG->{$cg}{groupId};
	
						$groupList{$cg}{desc} = $cg;				
						$groupList{$cg}{circuits} = 0;				
						$groupList{$cg}{faulty} = 0;				
						my @circuits = split(",",$CG->{$cg}{circuits});
						foreach my $circuit (@circuits) {
							# get the index loaded
							$groupIdx{$circuit} = $cg;
						}
						print "$node Group: $cg DSLAM=$CG->{$cg}{dslamNode}\n" if $info or $debug;
					}
				}
				print "DEBUG: groupList\n" if $debug > 2;
				print Dumper \%groupList if $debug > 2;

				print "DEBUG: groupIdx\n" if $debug > 2;
				print Dumper \%groupIdx if $debug > 2;
				
				if ( exists $NI->{cps6000Cct}) {
					my $circuitFaulty = 0;
					for my $index (sort {$a <=> $b} keys %{$NI->{cps6000Cct}}) {
						my $circuitId = $NI->{cps6000Cct}{$index}{cpsCctEntryIde};
	
						my $groupId = "$node Unknown";
						my $groupDesc = "$node Unknown";
						my $dslamNode = undef;
						my $infoForDetails = undef;
						#if ( defined $groupIdx{$circuitId} and $groupIdx{$circuitId} ne "" ) {
						#	$groupId = $NI->{cps6000Grp}{$groupIdx{$circuitId}}{cpsGrpEntryIde};
						#	$groupDesc = $NI->{cps6000Grp}{$groupIdx{$circuitId}}{cpsGrpEntryDes};
						#}
						#else {
						#	$groupIdx{$circuitId} = "Unknown";
						#}
						if ( exists $groupIdx{$circuitId} and $groupIdx{$circuitId} ne "" ) {
							$groupId = $CG->{$groupIdx{$circuitId}}{groupId};
							$groupDesc = $CG->{$groupIdx{$circuitId}}{circuitGroup};
							$dslamNode = $CG->{$groupIdx{$circuitId}}{dslamNode};				
						}
						else {
							$groupIdx{$circuitId} = "$node Unknown";
						}

						$groupId = "$node Unknown" if not $groupId;
						$groupDesc = "$node Unknown" if not $groupDesc;
						
						if ( $groupId and exists $groupList{$groupId}{circuits} ) {
							++$groupList{$groupId}{circuits};
						}
						else {
							$groupList{$groupId}{circuits} = 0;
						}
												
						$NI->{cps6000Cct}{$index}{cpsCctEntryGrp}	= $groupDesc;				
						$V->{cps6000Cct}{"${index}_cpsCctEntryGrp_value"} = $groupDesc;
						$V->{cps6000Cct}{"${index}_cpsCctEntryGrp_title"} = 'Circuit Group';
						
						if ( $dslamNode and exists $groupIdx{$circuitId} ) {
							$infoForDetails = "$dslamNode $CG->{$groupIdx{$circuitId}}{shelf} $CG->{$groupIdx{$circuitId}}{cable} $CG->{$groupIdx{$circuitId}}{cuenta} $CG->{$groupIdx{$circuitId}}{direccion}";
						}
						else {
							$infoForDetails = "No circuit details available";
						}
						
						print "$node Circuit: $NI->{cps6000Cct}{$index}{cpsCctEntryDes} $groupId $infoForDetails\n" if $info or $debug;
						logit("$node Circuit: $NI->{cps6000Cct}{$index}{cpsCctEntryDes} $groupId $infoForDetails") if $debugLogging;
						
						## detect condition
						my $element = "Circuit $NI->{cps6000Cct}{$index}{cpsCctEntryIde}";
						my $event = undef;
						my $level = undef;
						my $details = undef;
					
						#Circuitos Sin Comunicación - No Communication Circuits:
						#  if STT in ['MISSING','STANDBY(USER)']:
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryStt} ) {
							$event = "Alert: Circuitos Sin Comunicación";
							$details = "$infoForDetails: STT=$NI->{cps6000Cct}{$index}{cpsCctEntryStt}";
							$level = "Normal";
							# Does the condition exist now?
							if ( $NI->{cps6000Cct}{$index}{cpsCctEntryStt} =~ /80|20/ ) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
	
						#Circuitos Sin Comunicación (Falla desconocida) - No Communication Circuits (unknown failure):
						#  All Variables set to 0
						$event = "Alert: Circuitos Sin Comunicación (Falla desconocida)";
						$details = "$infoForDetails: STT=$NI->{cps6000Cct}{$index}{cpsCctEntryStt}";
						$level = "Normal";
						# Does the condition exist now?
						# can this ever happen?
						if ( 0 ) {						
							$level = $defaultLevel;
							++$circuitFaulty;
						}
						# set the event properties and process the condition (state)
						processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
	
						#Pares Abiertos - Open couple:
						#  if (ADC in range(1,5)) and (VDC>=370)
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} 
							and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc}
						) {
							$event = "Alert: Pares Abiertos";
							$details = "$infoForDetails: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc}";
							$level = "Normal";
							# Does the condition exist now?
							if ( 
								$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} >= 1
								and $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} <= 5
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} >= 370
							) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
	
						#Pares Averiados - couple damaged
						#  if ( (ADC in range(0,8)) or (VDC in range(30,300)) ) and ( (LDS==1) or (CFL==1) )
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} 
							and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc}
							and $NI->{cps6000Cct}{$index}{cpsCctEntryCfl}
							and $NI->{cps6000Cct}{$index}{cpsCctEntryLds}
						) {
							$event = "Alert: Pares Averiados";
							$details = "$infoForDetails: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} LDS=$NI->{cps6000Cct}{$index}{cpsCctEntryLds} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
							$level = "Normal";
							# Does the condition exist now?
							if (
								$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} >= 0
								and $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} <= 8
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} >= 30
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} <= 300
								and 
								( $NI->{cps6000Cct}{$index}{cpsCctEntryCfl} == 1
								or  $NI->{cps6000Cct}{$index}{cpsCctEntryLds} == 1 )
							) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
	
						#Tarjeta Desconectada - Card Offline
						#  if ((ADC in range(0,5)) and (VDC>=370)) and CFL==0:
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} 
							and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc}
							and $NI->{cps6000Cct}{$index}{cpsCctEntryCfl}
						) {							
							$event = "Alert: Tarjeta Desconectada";
							$details = "$infoForDetails: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
							$level = "Normal";
							# Does the condition exist now?
							if ( 
								$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} >= 0
								and $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} <= 5
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} >= 370
								and $NI->{cps6000Cct}{$index}{cpsCctEntryCfl} == 0
							) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
	
						#Carga en Descenso - Loading Up
						#  if ( (ADC in range(8,38)) and (VDC>=370) and (LDS==1) ):
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} 
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc}
								and $NI->{cps6000Cct}{$index}{cpsCctEntryLds}
						) {
							$event = "Alert: Carga en Descenso";
							$details = "$infoForDetails: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} LDS=$NI->{cps6000Cct}{$index}{cpsCctEntryLds}";
							$level = "Normal";
							# Does the condition exist now?
							if ( 
								$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} >= 8
								and $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} <= 38
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} >= 370
								and $NI->{cps6000Cct}{$index}{cpsCctEntryLds} == 1
							) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
	
						#Corto en Central - Short on Central
						#  if ( (ADC<=3) and (VDC<=30) and (CFL==1) ):
						if ( $NI->{cps6000Cct}{$index}{cpsCctEntryAdc} 
							and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc}
							and $NI->{cps6000Cct}{$index}{cpsCctEntryCfl}
						) {
							$event = "Alert: Corto en Central";
							$details = "$infoForDetails: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
							$level = "Normal";
							# Does the condition exist now?
							if ( 
								$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} <= 3
								and $NI->{cps6000Cct}{$index}{cpsCctEntryVdc} <= 30
								and $NI->{cps6000Cct}{$index}{cpsCctEntryCfl} == 1
							) {						
								$level = $defaultLevel;
								++$circuitFaulty;
							}
							processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;
						}
						
						# if any of the conditions apply the circuit is faulty, but only once.
						if ( $circuitFaulty ) {
							++$groupList{$groupId}{faulty};
						}
					}
				}
				
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
							$infoForDetails = "$CG->{$groupId}{dslamNode} $CG->{$groupId}{shelf} $CG->{$groupId}{cable} $CG->{$groupId}{cuenta} $CG->{$groupId}{direccion}";
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
						logit("node=$node, groupId=$groupId, infoForDetails=$infoForDetails, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level") if $debugLogging;
						processCondition($S,$node,$event,$element,$details,$level);
					}
					elsif (not $groupDesc) {
						print "WARNING node=$node, groupId=$groupId Group Description is empty in circuit group\n" if $info or $debug;						
					}
				}	

				$S->writeNodeView;  # save node view info in file var/$NI->{name}-view
				$S->writeNodeInfo; # save node info in file var/$NI->{name}-node	
			}
		}
	}
}


sub processCondition {
	my $S = shift;
	my $node = shift;
	my $event = shift;
	my $element = shift;
	my $details = shift;
	my $level = shift;

	my $condition = 0;

	logit("processCondition: $node, $event, $level, $element, $details") if $debugLogging;

	# Did the condition exist previously?
	my $eventExists = eventExist($node, $event, $element);

	if ( $eventExists and $level =~ /Normal/i) {
		# Proactive Closed.
		$condition = 1;
		checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>$element,details=>$details);
		$event = "$event Closed" if $event !~ /Closed/;
	}
	elsif ( not $eventExists and $level =~ /Normal/i) {
		$condition = 2;
		# Life is good, nothing to see here.
	}
	elsif ( not $eventExists and $level !~ /Normal/i) {
		$condition = 3;
		$event =~ s/ Closed//g;

		notify(sys=>$S,node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
		#eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
	}
	elsif ( $eventExists and $level !~ /Normal/i) {
		$condition = 4;
		# existing condition
	}
	
	print "node=$node, event=$event, level=$level, element=$element, details=$details\n" if $info or $debug;
}
									
		
sub deleteEvent {		
	my $node = shift;
	my $event = shift;
	my $element = shift;
	
	#print "DEBUG deleteEvent: $node,$event,$element\n";

	my $event_hash = eventHash($node,$event,$element);

	#print "DEBUG deleteEvent: $event_hash\n";

	my ($ET,$handle);
	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events');
	} else {
		($ET,$handle) = loadEventStateLock();
	}

	# remove this entry
	if ($C->{db_events_sql} eq 'true') {
		DBfunc::->delete(table=>'Events',index=>$event_hash);
	} else {
		if ( exists $ET->{$event_hash}{node} and $ET->{$event_hash}{node} ne "" ) {
			delete $ET->{$event_hash};
		}
		else {
			print STDERR "ERROR no event found for: $event_hash\n";
		}
	}

	if ($C->{db_events_sql} ne 'true') {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}

}

sub cleanEvents {		

	my ($ET,$handle);
	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events');
	} else {
		($ET,$handle) = loadEventStateLock();
	}
	
	foreach my $key (keys %$ET) {
		if ( $ET->{$key}{event} =~ /Closed/ ) {
			print "Cleaning event $ET->{$key}{node} $ET->{$key}{event}\n";
			delete($ET->{$key});
		}
		if ( not $circuitAlerts and $ET->{$key}{event} =~ /^Alert: Tarjeta|^Alert: Corto|^Alert: Pares|^Alert: Circuitos/ ) {
			print "Cleaning event $ET->{$key}{node} $ET->{$key}{event}\n";
			delete($ET->{$key});
		}

		if ( $ET->{$key}{element} eq "GR000" or $ET->{$key}{element} eq "Unknown" ) {
			print "Cleaning event $ET->{$key}{node} $ET->{$key}{event} $ET->{$key}{details}\n";
			delete($ET->{$key});
		}

		if ( $ET->{$key}{details} =~ /Unknown|^:/ ) {
			print "Cleaning event $ET->{$key}{node} $ET->{$key}{event} $ET->{$key}{details}\n";
			delete($ET->{$key});
		}
	}

	if ($C->{db_events_sql} ne 'true') {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}

}

# message with (class::)method names and line number
sub logit {
	my $msg = shift;
	my $handle;
	open($handle,">>$debugLog") or warn returnTime." log, Couldn't open log file $debugLog. $!\n";
	flock($handle, LOCK_EX)  or warn "log, can't lock $debugLog: $!";
	print $handle returnDateStamp().",$msg\n" or warn returnTime." log, can't write file $debugLog. $!\n";
	close $handle or warn "log, can't close $debugLog: $!";
}
