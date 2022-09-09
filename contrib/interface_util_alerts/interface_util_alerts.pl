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

################
# INSTALLATION #
################
# A good option to install is to create a util folder e.g. /usr/local/nmis9/util and then create a symbolic link so the file will run with the correct paths.

# This program should be run from Cron for the required alerting period, e.g. 5 minutes
#4-59/5 * * * * /usr/local/nmis9/util/interface_util_alerts.pl

# check all the needed files are in place, if not, yell loudly and stop.

# The average utilisation will be calculated for each interface for the last X minutes

our $VERSION="2.0.0";
use strict;
#use warnings;

# *****************************************************************************
# add the following to /etc/rsyslog.conf for testing and restart syslogd
# local3.*                /usr/local/nmis9/logs/noc.log
my $syslog_facility = 'local3';
my $syslog_server = 'localhost:udp:514';

my $nmisEventProcessing = 0;

my $threshold_period = "-5 minutes";

# A set of regular thresholds, uncomment these and comment out the next section to use these
#my $thresholds = {
#              'fatal' => 90,
#              'critical' => 80,
#              'major' => 60,
#              'minor' => 20,
#              'warning' => 10,
#              'normal' => 10,
#             };

# to only use fatal, change normal and fatal to be the same, and all others to 0
# convienently this can be done using the fatalThreshold variable
my $fatalThreshold = 50;
my $thresholds = {
              'fatal' => $fatalThreshold,
              'critical' => 0,
              'major' => 0,
              'minor' => 0,
              'warning' => 0,
              'normal' => $fatalThreshold,
             };

my $eventName = "Proactive Interface Utilisation";

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

### setup the NMIS9 API and environment and handy utils
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

# Set info level.
my $info = NMISNG::Util::getbool( $cmdline->{info} ) if defined $cmdline->{info};

my $nmisConfig = NMISNG::Util::loadConfTable( dir => "$FindBin::Bin/../conf", debug => $debug, info => undef);

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logfile = $nmisConfig->{'<nmis_logs>'} . "/nmis.log";
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => $logfile );

my $nmisng = NMISNG->new(config => $nmisConfig, log => $logger);

# get syslog config from config file, trivial format
#%hash = (
#  'syslog' => {
#    'syslog_facility' => 'local3',
#    'syslog_server' => 'IP_ADDRESS_OR_FQDN:tcp:514',
#    'extra_logging' => 1,
#  }
#);

if (NMISNG::Util::existFile(dir=>'conf',name=>'nocSyslog')) {
	my $syslogConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'nocSyslog');
	$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
	$syslog_server = $syslogConfig->{syslog}{syslog_server};
	$extraLogging = NMISNG::Util::getbool($syslogConfig->{syslog}{extra_logging});
}

print "interface_util_alert.pl: syslog_server=$syslog_server syslog_facility=$syslog_facility extraLogging=$extraLogging\n" if $info;

if ( defined $cmdline->{clean} and NMISNG::Util::getbool($cmdline->{clean}) ) {
	print "Cleaning Events\n";
	#cleanEvents();
	exit;
}
elsif ( defined $cmdline->{node} and $cmdline->{node} ne "" ) {
	processNode($nmisng,$cmdline->{node});
}
else {
	processAllNodes();
}

sub processAllNodes {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $nmisConfig->{cluster_id} });
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

	print "Processing $node\n" if $info;

	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {

        # is the node active?
		my ($nmisConfiguration,$error) = $nodeobj->configuration();
		my $active = $nmisConfiguration->{active};
		my $collect = $nmisConfiguration->{collect};
		my $group = $nmisConfiguration->{group};
		my $cluster_id = $nodeobj->cluster_id;

		# Only locals and active nodes
		if ($active and $nodeobj->cluster_id eq $nmisConfig->{cluster_id} ) {
			print " $node is active and local\n" if $info;

			my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			eval {
				$S->init(name=>$node);
			}; if ($@) # load node info and Model if name exists
			{
				print "Error init for $node";
				next;
			}

			# lets look at interfaces
			my $ids = $S->nmisng_node->get_inventory_ids(
				concept => "interface",
				filter => { historic => 0 }
			);

			for my $interfaceId (@$ids)
			{
				my ($interface, $error) = $S->nmisng_node->inventory(_id => $interfaceId);
				if ($error)
				{
					print "Failed to get inventory $interfaceId: $error\n";
					next;
				}
				my $thisIntf = $interface->data();
				processInterface($nodeobj,$S,$thisIntf,$group);
			}
		}
		else {
			print " $node active=$active $cluster_id $nmisConfig->{cluster_id}\n" if $info;
		}
	}
}

sub processInterface {
	my $nodeobj = shift;
	my $S = shift;
	my $thisIntf = shift;
	my $group = shift;

	my $node = $nodeobj->name();

	my $ifIndex = $thisIntf->{ifIndex};
	my $ifDescr = $thisIntf->{ifDescr};

	if ( exists $thisIntf->{collect} and NMISNG::Util::getbool($thisIntf->{collect}) ) {
		
		my $event = $eventName;
		
		# get the summary stats
		my $stats = Compat::NMIS::getSummaryStats(sys=>$S,type=>"interface",start=>$threshold_period,end=>'now',index=>$ifIndex, item=>$ifDescr);
		
		# skip if bad data
		next if not defined $stats->{$ifIndex}{inputUtil};
		next if not defined $stats->{$ifIndex}{outputUtil};

		next if $stats->{$ifIndex}{inputUtil} =~ /NaN/;
		next if $stats->{$ifIndex}{outputUtil} =~ /NaN/;

		# get the max if in/out utilisation
		my $util = 0;
		$util = $stats->{$ifIndex}{inputUtil} if $stats->{$ifIndex}{inputUtil} > $util;
		$util = $stats->{$ifIndex}{outputUtil} if $stats->{$ifIndex}{outputUtil} > $util;
	
		my $level = undef;
		my $reset = undef;
		my $thrvalue = undef;
		
		my $element = $thisIntf->{ifDescr};

		# apply the thresholds
		if ( $util < $thresholds->{normal} ) { $level = "Normal"; $reset = $thresholds->{normal}; $thrvalue = $thresholds->{normal}; }
		elsif ( $thresholds->{warning} > 0 and $util >= $thresholds->{warning} and $util < $thresholds->{minor} ) { $level = "Warning"; $thrvalue = $thresholds->{warning}; }
		elsif ( $thresholds->{minor} > 0 and $util >= $thresholds->{minor} and $util < $thresholds->{major} ) { $level = "Minor"; $thrvalue = $thresholds->{minor}; }
		elsif ( $thresholds->{major} > 0 and $util >= $thresholds->{major} and $util < $thresholds->{critical} ) { $level = "Major"; $thrvalue = $thresholds->{major}; }
		elsif ( $thresholds->{critical} > 0 and $util >= $thresholds->{critical} and $util < $thresholds->{fatal} ) { $level = "Critical"; $thrvalue = $thresholds->{critical}; }
		elsif ( $util >= $thresholds->{fatal} ) { $level = "Fatal"; $thrvalue = $thresholds->{fatal}; }
										
		# if the level is normal, make sure there isn't an existing event open
		my $eventExists = $nodeobj->eventExist($event, $element);
		my $sendSyslog = 0;
		my $condition = 0;

		my @detailBits;
							
		if ( $includeGroup ) {
			push(@detailBits,"$group");
		}
		
		if ( defined $thisIntf->{Description} and $thisIntf->{Description} ne "" ) {
			push(@detailBits,"$thisIntf->{Description}");
		}

		if ($nmisConfig->{global_events_bandwidth} eq 'true')
		{
			push(@detailBits,"Bandwidth=".$thisIntf->{ifSpeed});
		}

		push(@detailBits,"Value=$util Threshold=$thrvalue");

		my $details = join($detailSep,@detailBits);

		#remove dodgy quotes
		$details =~ s/[\"|\']//g;

		if ( $eventExists and $level =~ /Normal/i) {
			# Proactive Closed.
			$condition = 1;

			if ( NMISNG::Util::getbool($nmisEventProcessing) ) {
				Compat::NMIS::checkEvent(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details,value=>$util,reset=>$reset);
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
			# new event send the syslog.
			$sendSyslog = 1;

			if ( NMISNG::Util::getbool($nmisEventProcessing) ) {
				Compat::NMIS::notify(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details);
			}
			else {
				$nodeobj->eventAdd(event=>$event,level=>$level,element=>$element,details=>$details);	
			}
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
		
		#\t$thisIntf->{collect}\t$thisIntf->{Description}
		print "  $element: $event condition=$condition ifIndex=$thisIntf->{ifIndex} util=$util level=$level thrvalue=$thrvalue\n" if $info;
	}
}
