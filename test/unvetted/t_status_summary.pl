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

my $node = "wanedge1";

my $LNT = Compat::NMIS::loadLocalNodeTable();

my %cpu;

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
	
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->{info};
	my $M = $S->mdl();

	my $nodeStatus = Compat::NMIS::nodeStatus( node => $S->nmisng_node );
	
	print "$NI->{system}{name} status_summary=$NI->{system}{status_summary} status_updated=$NI->{system}{status_updated} nodeStatus=$nodeStatus\n";

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

  #    "cpu--0" : {
  #       "value" : "11.68",
  #       "status" : "ok",
  #       "event" : "Proactive CPU",
  #       "element" : "",
  #       "index" : null,
  #       "level" : "Normal",
  #       "updated" : 1415948422,
  #       "method" : "Threshold",
  #       "type" : "nodehealth",
  #       "property" : "cpu"
  #    },

	foreach my $status (keys %{$NI->{status}}) {
		if ( $NI->{status}{$status}{method} eq "Threshold" and $NI->{status}{$status}{property} eq "cpu" ) {
			my $index = $NI->{status}{$status}{index} ? $NI->{status}{$status}{index} : 0;
			my $key = "$node--$index"; 
			$cpu{$key}{node} = $node; 
			$cpu{$key}{value} = $NI->{status}{$status}{value};
		}
		elsif ( $NI->{status}{$status}{method} eq "Threshold" and $NI->{status}{$status}{property} eq "ssCpuRawUser" ) {
			my $index = $NI->{status}{$status}{index} ? $NI->{status}{$status}{index} : 0;
			my $key = "$node--$index"; 
			$cpu{$key}{node} = $node; 
			$cpu{$key}{value} = $NI->{status}{$status}{value};
		}
		elsif ( $NI->{status}{$status}{method} eq "Threshold" and $NI->{status}{$status}{property} eq "ssCpuRawSystem" ) {
			my $index = $NI->{status}{$status}{index} ? $NI->{status}{$status}{index} : 0;
			++$index;
			my $key = "$node--$index"; 
			$cpu{$key}{node} = $node; 
			$cpu{$key}{value} = $NI->{status}{$status}{value};
		}
		elsif ( $NI->{status}{$status}{method} eq "Threshold" and $NI->{status}{$status}{property} eq "ssCpuRawIdle" ) {
			my $index = $NI->{status}{$status}{index} ? $NI->{status}{$status}{index} : 0;
			++$index;
			++$index;
			my $key = "$node--$index"; 
			$cpu{$key}{node} = $node; 
			$cpu{$key}{value} = 100 - $NI->{status}{$status}{value};
		}



	}
}

print Dumper \%cpu;

print "  done in ".$t->deltaTime() ."\n";	
