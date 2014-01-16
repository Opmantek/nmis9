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
use NMIS::IPSLA;
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
ERROR: $0 needs to know the probes to import
usage: $0 <IPSLA_CFG>
eg: $0 probes=~/nmis/newprobes.txt

EO_TEXT
	exit 1;
}

print $t->markTime(). " Creating IPSLA Object\n";
print "DEBUG: db_prefix=$C->{db_prefix} db_server=$C->{db_server}\n";

my $IPSLA = NMIS::IPSLA->new(C => $C);
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Initialise DB (this should already be done by nmis.pl, but ok to repeat!)\n";
$IPSLA->initialise();
print "  done in ".$t->deltaTime() ."\n";

my $file = $arg{probes};
open(FILE,$file) || die "ERROR: problem with the file $file. $!\n";

my $a = "_";
my $b = "::";

while(<FILE>) {
	next if (/^$/ || /^#/);      
	chop();                      
	my @line = split(/;/);        
	my $pnode = $line[0];
	my $operador = $line[1];
	my $responder = $line[2];
	my $community = $line[3];
	my $ToS = $line[4];

	my $dbnode = $pnode;
	$dbnode =~ s/_/-/g;

	#01421_C5_28_UMF14_PUEBLO_NUEVO_817_RT01-N000058-CI0000213657;jitter;192.168.21.69;telmex$01$rw;96
	my $probe = "$pnode$a$responder$a$operador$a$ToS";
	
	if ( $pnode and $community ) {
		if ( $IPSLA->existNode(node => $pnode) ) {
			print $t->elapTime(). " NODE UPDATE: $pnode, $community\n";
			$IPSLA->updateNode(node => $pnode, community => $community);
		}
		else {
			print $t->elapTime(). " NODE ADD: $pnode, $community\n";
			$IPSLA->addNode(node => $pnode, community => $community);			
		}
	}
	
	if ( $probe =~ /$pnode/ and $probe and $operador and $responder and $ToS ) {
		if ( $IPSLA->existProbe(probe => $probe) ) {
			print $t->elapTime(). " PROBE UPD: NOT UPDATING $probe, pnode=$pnode\n";
		}
		elsif ( $operador eq "echo" ) {
			print $t->elapTime(). " PROBE ADD: $probe, pnode=$pnode\n";
			$IPSLA->addProbe(
				probe => $probe, 
				pnode => $pnode, 
				status => 'start requested', 
				func => 'start', 
				optype => $operador, 
				database => "$C->{database_root}/misc/ipsla-$dbnode-$responder-$operador-$ToS.rrd", 
				frequence => '30', 
				select => "$pnode$b$responder$b$operador$b$ToS", 
				rnode => "other",
				raddr => $responder,
				timeout => 5, 
				numpkts => '0', 
				deldb => 'false',
				history => '8', 
				tnode => $responder,
				interval => '0', 
				tos => $ToS, 
				verify => 2, 
				tport => '16384'
			);
		}
		elsif ( $operador eq "udpEcho" ) {
			print $t->elapTime(). " PROBE ADD: $probe, pnode=$pnode\n";
			$IPSLA->addProbe(
				probe => $probe, 
				pnode => $pnode, 
				status => 'start requested', 
				func => 'start', 
				optype => $operador, 
				database => "$C->{database_root}/misc/ipsla-$dbnode-$responder-$operador-$ToS.rrd", 
				frequence => '30', 
				select => "$pnode$b$responder$b$operador$b$ToS", 
				rnode => "other",
				raddr => $responder,
				timeout => 5, 
				numpkts => '0', 
				deldb => 'false',
				history => '8', 
				tnode => $responder,
				interval => '0', 
				tos => $ToS, 
				verify => 2, 
				dport => '5000'
			);
		}
		elsif ( $operador eq "jitter" ) {
			print $t->elapTime(). " PROBE ADD: $probe, pnode=$pnode\n";
			$IPSLA->addProbe(
				probe => $probe, 
				pnode => $pnode, 
				status => 'start requested', 
				func => 'start', 
				optype => $operador, 
				database => "$C->{database_root}/misc/ipsla-$dbnode-$responder-$operador-$ToS.rrd", 
				frequence => '300', 
				select => "$pnode$b$responder$b$operador$b$ToS", 
				rnode => "other",
				raddr => $responder,
				timeout => 5, 
				numpkts => '100', 
				deldb => 'false',
				history => '8', 
				tnode => $responder,
				interval => '20', 
				tos => $ToS, 
				verify => 2, 
				tport => '16384'
			);
		}
		else {
			print $t->elapTime(). " PROBE ERR: Operator no good, $operador, pnode=$pnode\n";
		}
	}
	else {
		print "ERROR: Problem with $probe and $operador and $responder and $ToS\n";
	}
}

