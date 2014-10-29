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

updateHuaweiRouters();
exit 0;

#For the circuit groups which have worked, get them from the MIB
sub updateHuaweiRouters {    
	my $LNT = loadLocalNodeTable();

	foreach my $node (sort keys %{$LNT}) {
		
		# Is the node active and are we doing stats on it.
		if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
			print "Processing $node\n" if $debug;

			my $S = Sys::->new;
			$S->init(name=>$node,snmp=>'false');
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;

			if ( $NI->{system}{nodeModel} eq "HuaweiRouter" ) {
				if ( exists $NI->{QualityOfServiceStat} ) {
					# seed some information back into the other model.
					foreach my $qosIndex ( keys %{$NI->{QualityOfServiceStat}}) {
						my $interface = undef;
						my $direction = undef;
						#"15.0.1"
						if ( $qosIndex =~ /^(\d+)\.\d+\.(\d+)/ ) {
							$interface = $1;
							$direction = $2;
							
							if ( defined $IF->{$interface} and $IF->{$interface}{ifDescr} ) {
								$interface = $IF->{$interface}{ifDescr};
							}
							
							if ( $direction == 1 ) {
								$direction = "inbound"
							}
							elsif ( $direction == 2 ) {
								$direction = "outbound"
							}
							
						}
						print "DEBUG: $qosIndex, $interface, $direction\n" if $debug;
						$NI->{QualityOfServiceStat}{$qosIndex}{Interface} = $interface; 
						$NI->{QualityOfServiceStat}{$qosIndex}{Direction} = $direction; 

					}

					$S->writeNodeInfo; # save node info in file var/$NI->{name}-node	
				}
			}
		}
	}
}


