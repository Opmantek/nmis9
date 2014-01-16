#!/usr/bin/perl
#
## $Id: opsla_add_probes.pl,v 1.4 2013/01/08 23:51:38 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use func;
use NMIS;
use NMIS::Timing;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the MIB to process
usage: $0 mib=<MIB_FILE>
eg: $0 mib=/usr/local/nmis8/mibs/CISCO-PRODUCTS-MIB.my

EO_TEXT
	exit 1;
}

print $t->elapTime(). " BEGIN\n";

my $oids = "$C->{'<nmis_base>'}/mibs/nmis_mibs.oid";
my %oidIndex;

open(OIDS,$oids) || die "ERROR: problem with the OIDS file $oids. $!\n";
while(<OIDS>) {
	$_ =~ s/\"//g;
	my ($sysObjectName,$sysObjectID) = split(/\s+/,$_);
	
	if ( not exists $oidIndex{$sysObjectName} and $oidIndex{$sysObjectName} eq "" ) {
		$oidIndex{$sysObjectName} = $sysObjectID;
	}
	else {
		print "ERROR: Duplicate OID Entry -- New: $sysObjectName, $sysObjectID and Existing: $oidIndex{$sysObjectName}: $_\n";
	}
}
close(OIDS);

my $ciscoProducts = "1.3.6.1.4.1.9.1";
my $qrParseMib = qr/^([\w\-]+)\s+OBJECT IDENTIFIER.+\{\s+ciscoProducts\s+(\d+)\s+\}/;

my $mib = $arg{mib};
my $count = 0;

open(OIDS,">>$oids") || die "ERROR: problem with the OIDS file $oids. $!\n";

open(FILE,$mib) || die "ERROR: problem with the MIB file $mib. $!\n";
while(<FILE>) {
	#ciscoWsCbs3110xS                OBJECT IDENTIFIER ::= { ciscoProducts 911 } -- Cisco Catalyst Stackable Blade Switch for IBM Enterprise Chassis with 1 10Gigabit Uplink port
	if ( $_ =~ /$qrParseMib/ ) {
		my $sysObjectName = $1;
		my $productId = $2;
		
		if ( not exists $oidIndex{$sysObjectName} and $oidIndex{$sysObjectName} eq "" ) {
			print qq|ADDING: "$sysObjectName"\t"$ciscoProducts.$productId"\n|;
			print OIDS qq|"$sysObjectName"\t"$ciscoProducts.$productId"\n|;
			++$count;
		}
	}
	else {
		if ( $_ =~ /OBJECT IDENTIFIER/ ) {
			print "ERROR: problem parsing: $_\n";
		}
	}
}
close(FILE);
close(OIDS);

print "Found $count new Cisco Products\n";
print $t->elapTime(). " END\n";
