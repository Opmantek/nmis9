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

# Code Node
my $node_core = "bones";
my $node_dist = "meatball";
my $node_acc = "golden";

nodeDown($node_core);
nodeDown($node_dist);
intDown($node_dist);
nodeDown($node_acc);
runEscalate();

print "\n############ Sleep now\n\n";
sleep 20;
print "\n############ AWAKE\n\n";

nodeUp($node_core);
nodeUp($node_dist);
intUp($node_dist);
nodeUp($node_acc);
runEscalate();

print $t->elapTime(). " End\n";

sub nodeDown {
	my $node = shift;
		
	print $t->elapTime(). " nodeDown Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
	
	Compat::NMIS::notify(sys=>$S,event=>"Node Down",element=>"",details=>"Ping failed");
		
	print $t->elapTime(). " nodeDown done\n";
}

sub nodeUp {
	my $node = shift;
		
	print $t->elapTime(). " nodeUp Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
		
	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"Ping failed");
	print "checkEvent Result: $result\n"; 
		
	print $t->elapTime(). " nodeUp done\n";
}

sub intDown {
	my $node = shift;
		
	print $t->elapTime(). " intDown Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
	
	Compat::NMIS::notify(sys=>$S,event=>"Interface Down",element=>"Dialer1",details=>"Escape to the Cloud");
		
	print $t->elapTime(). " intDown done\n";
}

sub intUp {
	my $node = shift;
		
	print $t->elapTime(). " intUp Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
		
	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>"Dialer1",details=>"Escape to the Cloud");
	print "checkEvent Result: $result\n"; 
		
	print $t->elapTime(). " intUp done\n";
}

sub runEscalate {
	my $out = `/usr/local/nmis8/bin/nmis.pl type=escalate debug=true`;
	print "$out\n";	
}
