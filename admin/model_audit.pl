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

# this script produces a csv document with a node overview in terms of
# modelling and enabled features; a similar overview is available in the GUI
# under system -> configuration check -> node admin summary

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;

my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();

print qq|"name","host","group","version","active","collect","last updated","icmp working","wmi working","snmp working","nodeModel","nodeVendor","nodeType","roleType","netType","sysObjectID","sysObjectName","sysDescr","intCount","intCollect"\n|;

foreach my $node (sort keys %{$LNT}) {

	my $intCollect = 0;
	my $intCount = 0;
	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		for my $ifIndex (keys %{$IF}) {
			++$intCount;
			if ( $IF->{$ifIndex}{collect} eq "true") {
				++$intCollect;
				#print "$IF->{$ifIndex}{ifIndex}\t$IF->{$ifIndex}{ifDescr}\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}\n";
			}
		}
	}
	my $sysDescr = $NI->{system}{sysDescr};
	$sysDescr =~ s/[\x0A\x0D]/\\n/g;

	my $lastUpdate = returnDateStamp($NI->{system}{lastUpdateSec});

	my $pingable = getbool($LNT->{$node}->{ping})? getbool($NI->{system}{nodedown})? "false": "true" : "N/A";
	my $snmpable = defined($NI->{system}->{snmpdown})? getbool($NI->{system}->{snmpdown})? "false" : "true" : "N/A";
	my $wmiworks = defined($NI->{system}->{wmidown})? getbool($NI->{system}->{wmidown})? "false" : "true" : "N/A";

	$lastUpdate = "unknown" if not defined $NI->{system}{lastUpdateSec};
	$pingable = "unknown" if not defined $NI->{system}{nodedown};
	$snmpable = "unknown" if not defined $NI->{system}{snmpdown};

	print qq|"$LNT->{$node}{name}","$LNT->{$node}{host}","$LNT->{$node}{group}","$LNT->{$node}{version}","$LNT->{$node}{active}","$LNT->{$node}{collect}","$lastUpdate","$pingable","$wmiworks","$snmpable","$NI->{system}{nodeModel}","$NI->{system}{nodeVendor}","$NI->{system}{nodeType}","$LNT->{$node}{roleType}","$LNT->{$node}{netType}","$NI->{system}{sysObjectID}","$NI->{system}{sysObjectName}","$sysDescr","$intCount","$intCollect"\n|;
}
