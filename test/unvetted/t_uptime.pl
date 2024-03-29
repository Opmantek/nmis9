#!/usr/bin/perl
#
## $Id: t_system.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::Sys;
use Compat::Timing;
use NMIS::Connect;
use Data::Dumper;

my %nvp;

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $LNT = Compat::NMIS::loadLocalNodeTable();

my $maxUpTime = 0;
my $maxUpTimeNode = undef;

foreach my $node (sort keys %$LNT) {

	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->{info};

	if ( $NI->{system}{sysUpTimeSec} > $maxUpTime and $NI->{system}{nodedown} eq "false" and $NI->{system}{active} eq "true" ) {
		$maxUpTime = $NI->{system}{sysUpTimeSec};
	
		print "$node has highest uptime $NI->{system}{sysUpTimeSec}\n";
		$maxUpTimeNode = $node;

	}

}
my $timeThingToPrintForHumans = convUpTime($maxUpTime);

print "$maxUpTimeNode has the max uptime of $timeThingToPrintForHumans!\n";


print "  done in ".$t->elapTime() ."\n";	
