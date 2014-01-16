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
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

#Turn on master anyway
$C->{server_master} = "true";
$C->{debug} = "true";

print $t->markTime(). " loadNodeTable\n";
my $NT = loadNodeTable(); # load global node table
print "  done in ".$t->deltaTime() ."\n";

my $servers;
foreach my $node (keys %{$NT}) {
	++$servers->{$NT->{$node}{server}};
}

foreach my $srv (sort keys %{$servers}) {
	print "Server $srv is managing $servers->{$srv} nodes\n";	
}

print $t->elapTime(). " loadServersTable\n";
my $ST = loadServersTable();
for my $srv (keys %{$ST}) {
	print $t->elapTime(). " server ${srv}\n";

	print $t->markTime(). " curlDataFromRemote sumnodetable\n";
	my $data = curlDataFromRemote(server => $srv, func => "sumnodetable", format => "text");
	print "  done in ".$t->deltaTime() ."\n";	
	
}

print $t->markTime(). " loadNodeSummary master=$C->{server_master}\n";
my $NS = loadNodeSummary(master => "true");
print "  done in ".$t->deltaTime() ."\n";	

my $summary;
foreach my $node (keys %{$NS}){
	++$summary->{roleType}{$NS->{$node}{roleType}};
	++$summary->{nodeType}{$NS->{$node}{nodeType}};
	++$summary->{group}{$NS->{$node}{group}};
}

print "\n";
foreach my $sum (sort keys %{$summary}) {
	foreach my $ele (sort keys %{$summary->{$sum}}) {
		print "Summary $sum $ele $summary->{$sum}{$ele}\n";
	}
}

print $t->elapTime(). " End\n";
