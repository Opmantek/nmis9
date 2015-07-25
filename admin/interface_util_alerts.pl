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

my $threshold_period = "-5 minutes";
my $thresholds = {
              'fatal' => '90',
              'critical' => '80',
              'major' => '60',
              'minor' => '20',
              'warning' => '10'
             };

my $event = "Proactive Interface Utilisation";

# set this to 1 to include group in the message details, 0 to exclude.
my $includeGroup = 1;

# the seperator for the details field.
my $detailSep = "-- ";

my $extraLogging = 0;

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

# get syslog config from config file.
if (existFile(dir=>'conf',name=>'nocSyslog')) {
	my $syslogConfig = loadTable(dir=>'conf',name=>'nocSyslog');
	$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
	$syslog_server = $syslogConfig->{syslog}{syslog_server};
	$extraLogging = getbool($syslogConfig->{syslog}{extra_logging});
}

my $LNT = loadLocalNodeTable();

foreach my $node (sort keys %{$LNT}) {
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print "Processing $node\n" if $info;
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;

		for my $ifIndex (sort keys %{$IF}) {
			if ( exists $IF->{$ifIndex}{collect} and $IF->{$ifIndex}{collect} eq "true") {
				
				# get the summary stats
				my $stats = getSummaryStats(sys=>$S,type=>"interface",start=>$threshold_period,end=>'now',index=>$ifIndex);
				
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
				
				my $element = $IF->{$ifIndex}{ifDescr};

				# apply the thresholds
				if ( $util < $thresholds->{warning} ) { $level = "Normal"; $reset = $thresholds->{warning}; $thrvalue = $thresholds->{warning}; }
				elsif ( $util >= $thresholds->{warning} and $util < $thresholds->{minor} ) { $level = "Warning"; $thrvalue = $thresholds->{warning}; }
				elsif ( $util >= $thresholds->{minor} and $util < $thresholds->{major} ) { $level = "Minor"; $thrvalue = $thresholds->{minor}; }
				elsif ( $util >= $thresholds->{major} and $util < $thresholds->{critical} ) { $level = "Major"; $thrvalue = $thresholds->{major}; }
				elsif ( $util >= $thresholds->{critical} and $util < $thresholds->{fatal} ) { $level = "Critical"; $thrvalue = $thresholds->{critical}; }
				elsif ( $util >= $thresholds->{fatal} ) { $level = "Fatal"; $thrvalue = $thresholds->{fatal}; }
												
				# if the level is normal, make sure there isn't an existing event open
				my $eventExists = eventExist($NI->{system}{name}, $event, $element);
				my $sendSyslog = 0;
				my $condition = 0;

				my @detailBits;
									
				if ( $includeGroup ) {
					push(@detailBits,"$LNT->{$node}{group}");
				}
				
				if ( defined $IF->{$ifIndex}{Description} and $IF->{$ifIndex}{Description} ne "" ) {
					push(@detailBits,"$IF->{$ifIndex}{Description}");
				}

				if ($C->{global_events_bandwidth} eq 'true')
				{
						push(@detailBits,"Bandwidth=".$IF->{$ifIndex}->{ifSpeed});
				}

				push(@detailBits,"Value=$util Threshold=$thrvalue");

				my $details = join($detailSep,@detailBits);

				#remove dodgy quotes
				$details =~ s/[\"|\']//g;


				if ( $eventExists and $level =~ /Normal/i) {
					# Proactive Closed.
					$condition = 1;
					eventDelete(event => { node => $node, 
																 event => $event, 
																 element => $element });
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

					eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
					# new event send the syslog.
					$sendSyslog = 1;
				}
				elsif ( $eventExists and $level !~ /Normal/i) {
					$condition = 4;
					# existing condition
				}

				if ( $sendSyslog ) {
					my $success = sendSyslog(
						server_string => $syslog_server,
						facility => $syslog_facility,
						nmis_host => $C->{server_name},
						time => time(),
						node => $node,
						event => $event,
						level => $level,
						element => $element,
						details => $details
					);
					if ( $success ) {
						logMsg("INFO: syslog sent: $node $event $element $details") if $extraLogging;
					}
					else {
						logMsg("ERROR: syslog failed to $syslog_server:  $node $event $element $details");
					}
				}
				
				# This section will enable normal NMIS processing of the event in addition to the custom syslog above.
				#if ( $level =~ /Normal/i ) { 
				#	checkEvent(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details,value=>$util,reset=>$reset);
				#}
				#else {
				#	notify(sys=>$S,event=>$event,level=>$level,element=>$element,details=>$details);
				#}


				#\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}
				print "  $element: condition=$condition ifIndex=$IF->{$ifIndex}{ifIndex} util=$util level=$level thrvalue=$thrvalue\n" if $info;

			}
		}
	}
}
		

# globally removes all events called "something Closed"
sub cleanEvents 
{
	my %allevents = loadAllEvents;
	
	foreach my $key (keys %allevents)
	{
		my $thisevent = $allevents{$key};
		if ( $thisevent->{event} =~ /Closed/ ) 
		{
			print "Cleaning event $thisevent->{node} $thisevent->{event}\n";
			eventDelete(event => $thisevent);
		}
	}
}
