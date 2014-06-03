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
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use NMIS::Connect;
use Data::Dumper;

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $node = "wanedge1";

my $LNT = loadLocalNodeTable();

foreach my $node (sort keys %$LNT) {
	#print $t->markTime(). " Create System $node\n";
	#print "  done in ".$t->deltaTime() ."\n";	
	
	#print $t->markTime(). " Load Some Data\n";
	
	#foreach my $inf (sort keys %{$NI}) {
	#	print "NI $inf=$NI->{inf}\n";	
	#	if ($inf eq "system") {
	#		foreach my $sys (sort keys %{$NI->{$inf}}) {
	#			print "  $sys = $NI->{$inf}{$sys}\n";
	#		}
	#	}
	#}
	
	
	
	
	my $S = Sys::->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->{info};
	my $M = $S->mdl();

	my @instances = $S->getTypeInstances(section => "hrsmpcpu");
	if ( exists $M->{system}{rrd}{nodehealth}{snmp}{avgBusy5}{oid} ) {
		print "$node supports CPU Stats\n";
	}
	elsif ( @instances) {
		print "$node supports CPU Stats\n";
	}
	else {
		print "$node NO CPU Stats support\n";
	}

	if ( $node eq "nmisdev64" ) {
		#print Dumper $S;
	}

}

print "  done in ".$t->deltaTime() ."\n";	
