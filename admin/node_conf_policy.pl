#!/usr/bin/perl
#
## $Id: convertnodes.pl,v 8.3 2012/08/13 05:05:00 keiths Exp $
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
use NMIS;
use func;
use Data::Dumper;

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will update the nodeConf.nmis file with an overriding collection or other policy.
usage: $0 save=true
eg: $0 save=true debug=true

EO_TEXT
	exit 1;
}

my $modelPolicy = qr/(CiscoDSL)/;

my $interfacePolicy = qr/(^ATM0\/1$|^IMA0\/1$)/;

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $node = $arg{node};
my $debug = setDebug($arg{debug});

# load configuration table
my $C = loadConfTable(conf=>$arg{conf});

processNodes();

exit 0;

sub processNodes {
	my $LNT = loadLocalNodeTable();
	my $NCT = loadNodeConfTable();

	
	foreach my $node (sort keys %{$LNT}) {
		
		# Is the node active and are we doing stats on it.
		if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $NI = $S->ndinfo;
			
			if ( $NI->{system}{nodeModel} =~ /$modelPolicy/ ) {
				print "Processing $node: $NI->{system}{nodeModel}\n";
				my $IF = $S->ifinfo;
			
				for my $ifIndex (keys %{$IF}) {
					if ( $IF->{$ifIndex}{ifDescr} =~ /$interfacePolicy/) {
						my $ifDescr = $IF->{$ifIndex}{ifDescr};
						print "  MANAGE Interface: $IF->{$ifIndex}{ifIndex}\t$ifDescr\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}\n";
						
						$NCT->{$node}{$ifDescr}{ifDescr} = $ifDescr;
						$NCT->{$node}{$ifDescr}{collect} = "true";
						$NCT->{$node}{$ifDescr}{event} = "true";
						$NCT->{$node}{$ifDescr}{threshold} = "true";						
					}
				}
			}			
		}
	}

	if ( $arg{debug} eq "true" ) {
		print Dumper $NCT;
	}
	
	if ( $arg{save} eq "true" ) {
		writeTable(dir=>'conf',name=>'nodeConf',data=>$NCT);
	}
}
