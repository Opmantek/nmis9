#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
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
use Compat::Timing;
use NMIS::Connect;

my %nvp;

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>"true");

my $node = "meatball";

print $t->markTime(). " Create System $node\n";
my $S = NMISNG::Sys->new; # create system object
$S->init(name=>$node,snmp=>'false');
print "  done in ".$t->deltaTime() ."\n";	

print $t->elapTime(). " Load Some Data\n";
my $NI = $S->{info};

my $event = "Node Up";
my $level = "Minor";
print $t->elapTime(). " Try an Event: $event\n";
my ($level,$log,$syslog) = Compat::NMIS::getLevelLogEvent(sys=>$S,event=>$event,level=>$level);
print $t->elapTime(). " RESULT: event=$event, level=$level, log=$log, syslog=$syslog\n";

my $event = "Node Down";
my $level = "Minor";
print $t->elapTime(). " Try an Event: $event\n";
my ($level,$log,$syslog) = Compat::NMIS::getLevelLogEvent(sys=>$S,event=>$event,level=>$level);
print $t->elapTime(). " RESULT: event=$event, level=$level, log=$log, syslog=$syslog \n";

print $t->elapTime(). " End\n";
