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

my $nmisEventProcessing = 0;

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
my $cleanEvents = $cmdline->{clean};
my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

if ( $cleanEvents) {
	print "Cleaning Events\n";
	cleanEvents();
	exit;
}

#my $info = NMISNG::Util::getbool( $cmdline->{info} ) if defined $cmdline->{info};

my $nmisConfig = NMISNG::Util::loadConfTable( dir => "$FindBin::Bin/../conf", debug => $debug, info => undef);

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logfile = $nmisConfig->{'<nmis_logs>'} . "/cps6000.log";
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => $logfile );

my $nmisng = NMISNG->new(config => $nmisConfig, log => $logger);


# if (NMISNG::Util::existFile(dir=>'conf',name=>'nocSyslog')) {
# 	my $syslogConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'nocSyslog');
# 	$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
# 	$syslog_server = $syslogConfig->{syslog}{syslog_server};
# 	$extraLogging = NMISNG::Util::getbool($syslogConfig->{syslog}{extra_logging});
# }

#print "cps6000_alerts.pl: syslog_server=$syslog_server syslog_facility=$syslog_facility extraLogging=$extraLogging\n" if $info;

if ($groups) {
	updateCircuitGroups($nmisng,$node);
	#exit 0;
}

if ($node) {
	processNode($nmisng,$node);
}
else {
	processAllNodes();
}

#exit 0;

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

	my $result_cps6000Groups = $nmisng->get_inventory_model(concept => "cps6000Groups", filter => { historic => 0 });
	#print "updateCircuitGroups result: ".Dumper($result)."\n";
	if (my $error = $result_cps6000Groups->error)
	{
		print "failed to lookup inventory records for cps6000Grp: $error \n";
		$logger->error("ERROR: failed to lookup inventory records for cps6000Grp: $error");
		return;
	}
	my %data_cps6000Groups = map { ($_->{data}->{index} => $_->{data}) } (@{$result_cps6000Groups->data});
	#print "updateCircuitGroups ifdata: ".Dumper(\%data_cps6000Groups)."\n";
	
	my $cps6000Grp = $nmisng->get_inventory_model(concept => "cps6000Grp", filter => { historic => 0 });
	#print "updateCircuitGroups cps6000Grp: ".Dumper($cps6000Grp)."\n";
	if (my $error = $cps6000Grp->error)
	{
		print "failed to lookup inventory records for cps6000Grp: $error \n";
		$logger->error("ERROR: failed to lookup inventory records for cps6000Grp: $error");
		return;
	}
	my %data_cps6000Grp = map { ($_->{data}->{index} => $_->{data}) } (@{$cps6000Grp->data});
	print "updateCircuitGroups ifdata: ".Dumper(\%data_cps6000Grp)."\n";

	# WORK WITH FAKE DATA FOR NOW AS NMIS INVENTORY IS NOT SHOWING CORRECT/CONCRETE DATA
	my %data_cps6000Grp =(
		'0' => {
			'cpsGrpEntryAadc' => '0',
			'cpsGrpEntryCap' => '7196',
			'cpsGrpEntryCct' => 'K0232,K0231,K0230,K0229,K0228,K0227,K0226,K0225,K0224,K0223,K0222,K0221,K0205,K0206,K0207,K0208,K0209,K0210,	K0211,K0212,K0213,K0214,K0215,K0216,K0217,K0218,K0219,K0220',
			'cpsGrpEntryDes' => 'FTTN Default Group',
			'cpsGrpEntryIde' => 'GR000',
			'cpsGrpEntryIndex' => 0,
			'cpsGrpEntryLrs' => '0',
			'cpsGrpEntryOlcap' => '7196',
			'cpsGrpEntryTadc' => '26',
			'index' => '0'
			},
		'1' => {
		'cpsGrpEntryAadc' => '65',
		'cpsGrpEntryCap' => '4113',
		'cpsGrpEntryCct' => 'K0201,K0202,K0203,K0204,K0205,K0206,K0207,K0208,K0209,K0120,K0111,K0112,K0113,K0114,K0115,K0116',
		'cpsGrpEntryDes' => 'DSLAM ACAILUB CBL AILU2 201-25',
		'cpsGrpEntryIde' => 'GR001',
		'cpsGrpEntryIndex' => 1,
		'cpsGrpEntryLrs' => '0',
		'cpsGrpEntryOlcap' => '4113',
		'cpsGrpEntryTadc' => '1065',
		'index' => '1'
		},
		'2' => {
		'cpsGrpEntryAadc' => '66',
		'cpsGrpEntryCap' => '4112',
		'cpsGrpEntryCct' => 'K0101,K0102,K0103,K0104,K0105,K0106,K0107,K0108,K0109,K0110,K0111,K0112,K0113,K0114,K0115,K0116',
		'cpsGrpEntryDes' => 'DSLAM ACMLLC1 C3 1-50',
		'cpsGrpEntryIde' => 'GR002',
		'cpsGrpEntryIndex' => 2,
		'cpsGrpEntryLrs' => '0',
		'cpsGrpEntryOlcap' => '4112',
		'cpsGrpEntryTadc' => '1064',
		'index' => '2'
		},
		'3' => {
		'cpsGrpEntryAadc' => '67',
		'cpsGrpEntryCap' => '4114',
		'cpsGrpEntryCct' => 'K0401,K0402,K0403,K0404,K0405,K0406,K0407,K0408,K0409,K0140,K0111,K0112,K0113,K0114,K0115,K0116',
		'cpsGrpEntryDes' => 'DSLAM ACAILUA1 CBL AILU2 251-3',
		'cpsGrpEntryIde' => 'GR003',
		'cpsGrpEntryIndex' => 3,
		'cpsGrpEntryLrs' => '0',
		'cpsGrpEntryOlcap' => '4114',
		'cpsGrpEntryTadc' => '1065',
		'index' => '3'
		}
	
	);
 	#print "updateCircuitGroups ifdata: ".Dumper(\%data_cps6000Grp)."\n";
	


	foreach my $groupId ( keys %data_cps6000Grp) {
		if ( $data_cps6000Grp{$groupId}{cpsGrpEntryIde} 
			and $data_cps6000Grp{$groupId}{cpsGrpEntryIde} ne "GR000" 
			and $data_cps6000Grp{$groupId}{cpsGrpEntryDes} 
			and $data_cps6000Grp{$groupId}{cpsGrpEntryDes} !~ /FTTN DEFAULT GROUP|noSuchInstance/i 
		) 
		{
			my $circuitGroup = $data_cps6000Grp{$groupId}{cpsGrpEntryDes};
			#print "updateCircuitGroups circuitGroup: ".Dumper($circuitGroup)."\n";
			my $dslamNode = undef;
			if ( $circuitGroup ) {
				my @tmp = split(" ",$circuitGroup);
				$dslamNode = $tmp[0];
			}
			
			$dslamNode = $dslamNode ? $dslamNode : $CG->{$circuitGroup}{dslamNode};
			#print "updateCircuitGroups dslamNode: ".Dumper($dslamNode)."\n";
			my $shelf = $CG->{$circuitGroup}{shelf} ? $CG->{$circuitGroup}{shelf} : undef;
			#print "updateCircuitGroups shelf: ".Dumper($shelf)."\n";
			my $cable = $CG->{$circuitGroup}{cable} ? $CG->{$circuitGroup}{cable} : undef;
			#print "updateCircuitGroups cable: ".Dumper($cable)."\n";
			my $cuenta = $CG->{$circuitGroup}{cuenta} ? $CG->{$circuitGroup}{cuenta} : undef;
			#print "updateCircuitGroups cuenta: ".Dumper($cuenta)."\n";
			my $direccion = $CG->{$circuitGroup}{direccion} ? $CG->{$circuitGroup}{direccion} : undef;
			#print "updateCircuitGroups direccion: ".Dumper($direccion)."\n";

			$CG->{$circuitGroup} = {
			'circuitGroup' => $circuitGroup,
			'circuits' => $data_cps6000Grp{$groupId}{cpsGrpEntryCct},
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
	
	#print "updateCircuitGroups CG After : ".Dumper($CG)."\n";
	NMISNG::Util::writeTable(dir=>'conf',name=>'CircuitGroups',data=>$CG);
}



sub processAllNodes {

	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $nmisConfig->{cluster_id} });
	print "processAllNodes nodes=$nodes\n";
	my %seen;
    
	foreach my $node (sort @$nodes) {
		next if ($seen{$node});
		$seen{$node} = 1;
		processNode($nmisng,$node);
	}
}

sub processNode {
	my $nmisng = shift;
	my $node = shift;

	#print "processNode:Processing $node\n" if $node;
	my $S = NMISNG::Sys->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	my $nodeobj = $nmisng->node(name => $node);
	#print "nodeobj".Dumper ($nodeobj);
	if ( !$nodeobj)  {
		$logger->fatal("Node $node failed to get the $nodeobj");
		die "Node $node failed to get the $nodeobj .\n";
	}
	
	if ($nodeobj) {

        # is the node active?
		my ($nmisConfiguration,$error) = $nodeobj->configuration();
		#print "processNode:nmisConfiguration ". Dumper($nmisConfiguration)."\n" if $nmisConfiguration;
		my $active = $nmisConfiguration->{active};
		my $collect = $nmisConfiguration->{collect};
		my $group = $nmisConfiguration->{group};
		my $host = $nmisConfiguration->{host};
		my $cluster_id = $nodeobj->cluster_id;
		my $model = $nmisConfiguration->{model};
		#print "processNode:model $model\n" if $model;
		
		my $sys;

		# Only locals and active nodes
		if ($active and $collect) {
			print "$node is active and local\n";
			if ( $model eq "GE-QS941" ) {
				# using the custom table CircuitGroups to get the group name from.
				my $CG = NMISNG::Util::loadTable(dir=>'conf',name=>'CircuitGroups');
				my %groupIdx;
				my %groupList;
				#initialise the unknown group for the SNMP bug in QS941
				$groupList{"$node Unknown"}{desc} = "$node Unknown";
				$groupList{"$node Unknown"}{circuits} = 0;
				$groupList{"$node Unknown"}{faulty} = 0;
				#print "CG".Dumper($CG);

				for my $cg (sort {$a cmp $b} keys %{$CG}) {
					print "cg = $cg\n";
					# Only interested in Circuit Groups setup for the GE Node we are managing.
					if ( exists $CG->{$cg}{geNode} and $node eq $CG->{$cg}{geNode} ) {
						# if the group id came from a good place.
						my $groupId = $CG->{$cg}{groupId};
	
						$groupList{$cg}{desc} = $cg;				
						$groupList{$cg}{circuits} = 0;				
						$groupList{$cg}{faulty} = 0;				
						my @circuits = split(",",$CG->{$cg}{circuits});
						# print "DEBUG: circuits\n";
						# print Dumper \@circuits;
						foreach my $circuit (@circuits) {
							# get the index loaded
							$groupIdx{$circuit} = $cg;
						}
						print "$node Group: $cg DSLAM=$CG->{$cg}{dslamNode}\n" if $info or $debug;
					}
				}
				print "DEBUG: groupList\n";
				print Dumper \%groupList;

				print "DEBUG: groupIdx\n";
				print Dumper \%groupIdx;

				# if ( exists $NI->{cps6000Cct}) {
				# }

				# # 10 circuits, 1 faulty circuit = 10% power loss, fault/circuits * 100
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
						print "processNode:potency $potency\n";
						print "processNode:potencyLoss $potencyLoss\n";
						if ( $potencyLoss > 0 and $potency > 0 ) {
							$powerLoss = sprintf("%.2f",($potencyLoss / $potency) * 100);
							print "processNode:powerLoss $powerLoss\n";
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
						
						print "node=$node, groupId=$groupId, infoForDetails=$infoForDetails, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level\n";
						$logger->info("node=$node, groupId=$groupId, infoForDetails=$infoForDetails, potency=$potency, potencyLoss=$potencyLoss, powerLoss=$powerLoss level=$level") if $extraLogging;
						#processCondition($S,$node,$nodeobj,$event,$element,$details,$level);
					}
					elsif (not $groupDesc) {
						print "WARNING node=$node, groupId=$groupId Group Description is empty in circuit group\n";						
					}
				}
			}
		}	
		else {
			print " $node active=$active $cluster_id $nmisConfig->{cluster_id}\n";
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

	my $condition = 0;

	$logger->info("processCondition: $node, $event, $level, $element, $details") if $extraLogging;

	# # Did the condition exist previously?
	my $eventExists = $nodeobj->eventExist($node, $event, $element);
	print "processCondition:eventExists $eventExists\n";

	if ( $eventExists and $level =~ /Normal/i) {
	 	# Proactive Closed.
	 	# $condition = 1;
		# Compat::NMIS::checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>$element,details=>$details);
	 	# $event = "$event Closed" if $event !~ /Closed/;
		if ( NMISNG::Util::getbool($nmisEventProcessing) ) {
				Compat::NMIS::checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>$element,details=>$details);
			}
			# else {						
			# 	$nodeobj->eventDelete(
			# 		event => {
			# 			event => $event, 
			# 			element => $element 
			# 		});
			# }
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
		#print "processCondition:HERE I M\n";

		Compat::NMIS::notify(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details);
		$nodeobj->eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
	}
	elsif ( $eventExists and $level !~ /Normal/i) {
		$condition = 4;
		# existing condition
	}
	print "node=$node, event=$event, level=$level, element=$element, details=$details\n";
	
	#print "node=$node, event=$event, level=$level, element=$element, details=$details\n" if $info or $debug;
}



#cleanEvents();
#eventDelete