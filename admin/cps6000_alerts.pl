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
use warnings;

# *****************************************************************************

my $syslog_facility = 'local3';
my $syslog_server = 'localhost:udp:514';

my $defaultLevel = "Major";

my $circuitAlerts = 0;

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

my $LNT = loadLocalNodeTable();

my %groupIdx;
my %groupList;

foreach my $node (sort keys %{$LNT}) {
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print "Processing $node\n" if $debug;
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

		my $NI = $S->ndinfo;
		my $V = $S->view;

		if ( $NI->{system}{nodeModel} eq "GE-QS941" ) {
			print "Processing $node\n" if $info;
			if ( exists $NI->{cps6000Grp}) {
				
				#initialise the unknown group for the SNMP bug in QS941
				$groupList{"Unknown"}{desc} = "Unknown";
				$groupList{"Unknown"}{circuits} = 0;
				$groupList{"Unknown"}{faulty} = 0;
				
				for my $index (sort {$a <=> $b} keys %{$NI->{cps6000Grp}}) {
					my $groupId = $NI->{cps6000Grp}{$index}{cpsGrpEntryIde};
					$groupList{$groupId}{desc} = $NI->{cps6000Grp}{$index}{cpsGrpEntryDes};				
					$groupList{$groupId}{circuits} = 0;				
					$groupList{$groupId}{faulty} = 0;				
					my @circuits = split(",",$NI->{cps6000Grp}{$index}{cpsGrpEntryCct});
					foreach my $circuit (@circuits) {
						# get the index loaded
						$groupIdx{$circuit} = $index;
					}
					print "$node Group: $NI->{cps6000Grp}{$index}{cpsGrpEntryDes} Total Current=$NI->{cps6000Grp}{$index}{cpsGrpEntryTadc}: Average Current=$NI->{cps6000Grp}{$index}{cpsGrpEntryAadc}\n" if $info or $debug;
				}
			}
			
			if ( exists $NI->{cps6000Cct}) {
				my $circuitFaulty = 0;
				for my $index (sort {$a <=> $b} keys %{$NI->{cps6000Cct}}) {
					my $circuitId = $NI->{cps6000Cct}{$index}{cpsCctEntryIde};

					my $groupId = "Unknown";
					my $groupDesc = "Unknown";
					if ( defined $groupIdx{$circuitId} and $groupIdx{$circuitId} ne "" ) {
						$groupId = $NI->{cps6000Grp}{$groupIdx{$circuitId}}{cpsGrpEntryIde};
						$groupDesc = $NI->{cps6000Grp}{$groupIdx{$circuitId}}{cpsGrpEntryDes};
					}
					else {
						$groupIdx{$circuitId} = "Unknown";
					}
					
					++$groupList{$groupId}{circuits};
					
					$NI->{cps6000Cct}{$index}{cpsCctEntryGrp}	= $groupDesc;				
					$V->{cps6000Cct}{"${index}_cpsCctEntryGrp_value"} = $groupDesc;
					$V->{cps6000Cct}{"${index}_cpsCctEntryGrp_title"} = 'Circuit Group';

					print "$node Circuit: $NI->{cps6000Cct}{$index}{cpsCctEntryDes} $groupId $groupDesc Volts=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc}: Current=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc}\n" if $info or $debug;
					
					## detect condition
					my $element = "Circuit $NI->{cps6000Cct}{$index}{cpsCctEntryIde}";
					my $event = undef;
					my $level = undef;
					my $details = undef;

										
					#Circuitos Sin Comunicación - No Communication Circuits:
					#  if STT in ['MISSING','STANDBY(USER)']:
					$event = "Alert: Circuitos Sin Comunicación";
					$details = "$groupDesc: STT=$NI->{cps6000Cct}{$index}{cpsCctEntryStt}";
					$level = "Normal";
					# Does the condition exist now?
					if ( $NI->{cps6000Cct}{$index}{cpsCctEntryStt} =~ /80|20/ ) {						
						$level = $defaultLevel;
						++$circuitFaulty;
					}
					processCondition($S,$node,$event,$element,$details,$level) if $circuitAlerts;

					#Circuitos Sin Comunicación (Falla desconocida) - No Communication Circuits (unknown failure):
					#  All Variables set to 0
					$event = "Alert: Circuitos Sin Comunicación (Falla desconocida)";
					$details = "$groupDesc: STT=$NI->{cps6000Cct}{$index}{cpsCctEntryStt}";
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
					$event = "Alert: Pares Abiertos";
					$details = "$groupDesc: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc}";
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

					#Pares Averiados - couple damaged
					#  if ( (ADC in range(0,8)) or (VDC in range(30,300)) ) and ( (LDS==1) or (CFL==1) )
					$event = "Alert: Pares Averiados";
					$details = "$groupDesc: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} LDS=$NI->{cps6000Cct}{$index}{cpsCctEntryLds} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
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

					#Tarjeta Desconectada - Card Offline
					#  if ((ADC in range(0,5)) and (VDC>=370)) and CFL==0:
					$event = "Alert: Tarjeta Desconectada";
					$details = "$groupDesc: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
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

					#Carga en Descenso - Loading Up
					#  if ( (ADC in range(8,38)) and (VDC>=370) and (LDS==1) ):
					$event = "Alert: Tarjeta Desconectada";
					$details = "$groupDesc: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} LDS=$NI->{cps6000Cct}{$index}{cpsCctEntryLds}";
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

					#Corto en Central - Short on Central
					#  if ( (ADC<=3) and (VDC<=30) and (CFL==1) ):
					$event = "Alert: Corto en Central";
					$details = "$groupDesc: ADC=$NI->{cps6000Cct}{$index}{cpsCctEntryAdc} VDC=$NI->{cps6000Cct}{$index}{cpsCctEntryVdc} CFL=$NI->{cps6000Cct}{$index}{cpsCctEntryCfl}";
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
					
					# if any of the conditions apply the circuit is faulty, but only once.
					if ( $circuitFaulty ) {
						++$groupList{$groupId}{faulty};
					}
				}
			}
			
			# 10 circuits, 1 faulty circuit = 10% power loss, fault/circuits * 100
			foreach my $groupId ( keys %groupList ) {				
				my $potency = $groupList{$groupId}{circuits} * 65;
				my $potencyLoss = $groupList{$groupId}{faulty} * 65;
				my $powerLoss = sprintf("%.2f",($potencyLoss / $potency) * 100);

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

				my $groupDesc = $groupList{$groupId}{desc};
				my $event = "Alert: DSLAM Power Loss";
				my $element = $groupId;
				my $details = "$groupDesc: potency=$potency potencyLoss=$potencyLoss powerLoss=$powerLoss";
				
				print "node=$node, groupId=$groupId, groupDesc=$groupDesc, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level\n" if $info or $debug;
				processCondition($S,$node,$event,$element,$details,$level);
			}	
			
			$S->writeNodeView;  # save node view info in file var/$NI->{name}-view
			$S->writeNodeInfo; # save node info in file var/$NI->{name}-node	
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
	}

	if ($C->{db_events_sql} ne 'true') {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}

}