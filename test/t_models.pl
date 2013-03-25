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
use Data::Dumper;
use Sys;

my $node = "cisco_router";

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

print $t->markTime(). " loadNodeTable\n";
my $NT = loadNodeTable(); # load global node table
print "  done in ".$t->deltaTime() ."\n";

print $t->elapTime(). " Sys::->new\n";
my $S = Sys::->new; # create system object
my $result = $S->init(name=>$node);

print "From System: sysName=$S->{info}{system}{sysName}\n";

print $t->elapTime(). " S->ndinfo\n";
my $NI = $S->ndinfo;

print "From NI: sysName=$NI->{system}{sysName}\n";

print Dumper($NI);

print $t->elapTime(). " S->ifinfo\n";
my $II = $S->ifinfo;

foreach my $indx (sort keys %{$II}) {
	print "ifIndex=$II->{$indx}{ifIndex} ifDescr=$II->{$indx}{ifDescr} ipAdEntAddr1=$II->{$indx}{ipAdEntAddr1} ipAdEntNetMask1=$II->{$indx}{ipAdEntNetMask1}\n";
}

#print Dumper($II);

foreach my $node (sort keys %{$NT}) {
	print "node=$node\n";
	my $result = $S->init(name=>$node);
	my $II = $S->ifinfo;
	foreach my $indx (sort keys %{$II}) {
		print "  ifIndex=$II->{$indx}{ifIndex} ifDescr=$II->{$indx}{ifDescr} ipAdEntAddr1=$II->{$indx}{ipAdEntAddr1} ipAdEntNetMask1=$II->{$indx}{ipAdEntNetMask1}\n";
	}
}

print $t->elapTime(). " End\n";

