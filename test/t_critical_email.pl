#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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
my $interface_index = -1;
my $critical_text = "CRITICAL";
my %nvp = getArguements(@ARGV);
my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>"true");

# Code Node
my $node_core = ( defined($nvp{node}) ) ? $nvp{node} : "asgard";
# my $node_dist = "meatball";
# my $node_acc = "golden";

interfaceDown($node_core, $critical_text);

print "\n############ RUN ESCALATE\n\n";
runEscalate();

print "\n############\n\n";

interfaceUp($node_core, $critical_text);
print "\n############ RUN ESCALATE\n\n";
runEscalate();

print $t->elapTime(). " End\n";

sub interfaceDown {
	my $node = shift;
	my $critical_text = shift;
		
	print $t->markTime(). " interfaceDown Create System $node\n";
	my $S = Sys::->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	
	my $IF = $S->ifinfo;
	my @indexes = keys(%{$IF});
	foreach my $index (@indexes) {		
		if( $IF->{$index}{collect} eq "true" ) {
			print "using interface".$IF->{$index}{ifDescr}."\n";
			$interface_index = $index;
			last;
		}	
	}
	print "\t\t Interface is: ".$IF->{$interface_index}{ifDescr}."\n";
	print "  done in ".$t->deltaTime() ."\n";	
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
	notify(sys=>$S,event=>"Interface Down",element=>$IF->{$interface_index}{ifDescr},details=>$IF->{$interface_index}{Description}." $critical_text");
		
	print $t->elapTime(). " interfaceDown done\n";
}

sub interfaceUp {
	my $node = shift;
	my $critical_text = shift;

	print $t->markTime(). " interfaceUp Create System $node\n";
	my $S = Sys::->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	my $IF = $S->ifinfo;
	print "  done in ".$t->deltaTime() ."\n";	
	
	print $t->elapTime(). " Load Some Data\n";
	my $NI = $S->{info};
		
	checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$IF->{$interface_index}{ifDescr},details=>$IF->{$interface_index}{Description}." $critical_text");
			
	print $t->elapTime(). " interfaceUp done\n";
}

sub runEscalate {
	my $out = `../bin/nmis.pl type=escalate debug=true`;
	print "$out\n";	
}
