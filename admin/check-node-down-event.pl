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
use func;
use NMIS;
use NMIS::Timing;
use NMIS::Connect;

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>"false");

#my $node = "ACBH7A2";
#checkNodeDown($node);


my $LNT = loadLocalNodeTable();
foreach my $node (sort keys %{$LNT}) {
	if ( getbool($LNT->{$node}{active}) ) {
		checkNodeDown($node);
	}
}

print $t->elapTime(). " End\n";

sub checkNodeDown {
	my $node = shift;
	my $event = "Node Down";

	my $S = Sys::->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	my $NI = $S->{info};

	my $result = eventExist($NI->{system}{name}, $event, "") ;
	my $nodeDownEvent = $result ? "true" : "false";

	if ( $nodeDownEvent ne $NI->{system}{nodedown} ) {
		print $t->elapTime(). " checkEvent $node $event=$nodeDownEvent nodedown=$NI->{system}{nodedown} snmpdown=$NI->{system}{snmpdown}\n";
		my $result = checkEvent(sys=>$S,event=>$event,level=>"Normal",element=>"",details=>"Ping failed");

	}
}
