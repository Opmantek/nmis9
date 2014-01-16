#!/usr/bin/perl
#
## $Id: opsla_migration.pl,v 1.2 2012/05/16 05:23:45 keiths Exp $
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
my %nvp = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($nvp{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $qrip = qr/^\d+\.\d+\.\d+\.\d+$/;
my $qrnotdns = qr/select|tnode|saddr|raddr|pnode/;

my $ipslacfg_file = "$C->{'<nmis_var>'}/ipslacfg.nmis";
if ( $nvp{ipslacfg} ) {
	$ipslacfg_file = $nvp{ipslacfg};
}

print $t->markTime(). " Loading IPSLA CFG $ipslacfg_file\n";
my $RTTcfg = &readFiletoHash(file => $ipslacfg_file); # global hash
print "  done in ". $t->deltaTime() ."\n";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the IPSLA config file to migrate to DB
usage: $0 <IPSLA_CFG>
eg: $0 ipslacfg=/usr/local/nmis8/var/ipslacfg.nmis

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

foreach my $index (sort keys %{$RTTcfg}) {
	my $entry;
	my $node;
	my $community;
	my $probe;
	
	# a full node record
	if ( $RTTcfg->{$index}{'entry'} ne "" and $RTTcfg->{$index}{'community'} ne "" and $RTTcfg->{$index}{'pnode'} eq "") {
		$node = $index;
		$entry = $RTTcfg->{$index}{'entry'};
		$community = $RTTcfg->{$index}{'community'};
	}

	# a partial node record
	if ( $RTTcfg->{$index}{'community'} ne "" ) {
		$node = $index;
		$community = $RTTcfg->{$index}{'community'};
	}

	# a partial node record
	if ( $RTTcfg->{$index}{'entry'} ne "" and $RTTcfg->{$index}{'pnode'} eq "") {
		$node = $index;
		$entry = $RTTcfg->{$index}{'entry'};
	}
	
	if ( $node and ($entry or $community) ) {
		if ( $IPSLA->existNode(node => $node) ) {
			print $t->elapTime(). " NODE UPDATE: $node, $entry, $community\n";
			$IPSLA->updateNode(node => $node, entry => $entry, community => $community);
		}
		else {
			print $t->elapTime(). " NODE ADD: $node, $entry, $community\n";
			$IPSLA->addNode(node => $node, entry => $entry, community => $community);			
		}
	}
	elsif ( $RTTcfg->{$index}{'pnode'} ne "" and $RTTcfg->{$index}{'select'} ne "" and $RTTcfg->{$index}{'frequence'} ne ""  ) {
		$probe = $index;
		if ( $IPSLA->existProbe(probe => $probe) ) {
			print $t->elapTime(). " PROBE UPD: $probe, entry=$RTTcfg->{$index}{'entry'} status=$RTTcfg->{$index}{'status'}\n";
			$IPSLA->updateProbe(
				probe => $probe, 
				entry => $RTTcfg->{$index}{'entry'}, 
				pnode => $RTTcfg->{$index}{'pnode'}, 
				status => $RTTcfg->{$index}{'status'}, 
				func => $RTTcfg->{$index}{'func'}, 
				optype => $RTTcfg->{$index}{'optype'}, 
				database => $RTTcfg->{$index}{'database'}, 
				frequence => $RTTcfg->{$index}{'frequence'}, 
				message => $RTTcfg->{$index}{'message'}, 
				select => $RTTcfg->{$index}{'select'}, 
				rnode => $RTTcfg->{$index}{'rnode'}, 
				codec => $RTTcfg->{$index}{'codec'}, 
				raddr => $RTTcfg->{$index}{'raddr'}, 
				timeout => $RTTcfg->{$index}{'timeout'}, 
				numpkts => $RTTcfg->{$index}{'numpkts'}, 
				deldb => $RTTcfg->{$index}{'deldb'}, 
				history => $RTTcfg->{$index}{'history'}, 
				saddr => $RTTcfg->{$index}{'saddr'}, 
				tnode => $RTTcfg->{$index}{'tnode'}, 
				responder => $RTTcfg->{$index}{'responder'},
				starttime => $RTTcfg->{$index}{'starttime'}, 
				interval => $RTTcfg->{$index}{'interval'}, 
				tos => $RTTcfg->{$index}{'tos'}, 
				verify => $RTTcfg->{$index}{'verify'}, 
				tport => $RTTcfg->{$index}{'tport'}, 
				url => $RTTcfg->{$index}{'url'}, 
				items => $RTTcfg->{$index}{'items'}
			);
		}
		else {
			print $t->elapTime(). " PROBE ADD: $probe entry=$RTTcfg->{$index}{'entry'} status=$RTTcfg->{$index}{'status'}\n";
			$IPSLA->addProbe(
				probe => $probe, 
				entry => $RTTcfg->{$index}{'entry'}, 
				pnode => $RTTcfg->{$index}{'pnode'}, 
				status => $RTTcfg->{$index}{'status'}, 
				func => $RTTcfg->{$index}{'func'}, 
				optype => $RTTcfg->{$index}{'optype'}, 
				database => $RTTcfg->{$index}{'database'}, 
				frequence => $RTTcfg->{$index}{'frequence'}, 
				message => $RTTcfg->{$index}{'message'}, 
				select => $RTTcfg->{$index}{'select'}, 
				rnode => $RTTcfg->{$index}{'rnode'}, 
				codec => $RTTcfg->{$index}{'codec'}, 
				raddr => $RTTcfg->{$index}{'raddr'}, 
				timeout => $RTTcfg->{$index}{'timeout'}, 
				numpkts => $RTTcfg->{$index}{'numpkts'}, 
				deldb => $RTTcfg->{$index}{'deldb'}, 
				history => $RTTcfg->{$index}{'history'}, 
				saddr => $RTTcfg->{$index}{'saddr'}, 
				tnode => $RTTcfg->{$index}{'tnode'}, 
				responder => $RTTcfg->{$index}{'responder'},
				starttime => $RTTcfg->{$index}{'starttime'}, 
				interval => $RTTcfg->{$index}{'interval'}, 
				tos => $RTTcfg->{$index}{'tos'}, 
				verify => $RTTcfg->{$index}{'verify'}, 
				tport => $RTTcfg->{$index}{'tport'}, 
				url => $RTTcfg->{$index}{'url'}, 
				items => $RTTcfg->{$index}{'items'}
			);
		}
		# Check for DNS Cache entries
		foreach my $value ( %{$RTTcfg->{$index}} ) {
			if ( $value =~ /$qrip/ and $RTTcfg->{$index}{$value} ne "") {
				print $t->elapTime(). " DNS1 MAT $index: $value, $RTTcfg->{$index}{$value}\n" if $debug; 
				if ( $IPSLA->existDnsCache(lookup => $value) ) {
					print $t->elapTime(). " DNS1 UPD: lookup=$value result=$RTTcfg->{$index}{$value}\n";
					$IPSLA->updateDnsCache(lookup => $value, result => $RTTcfg->{$index}{$value});
				}
				else {
					print $t->elapTime(). " DNS1 ADD: lookup=$value result=$RTTcfg->{$index}{$value}\n";
					$IPSLA->addDnsCache(lookup => $value, result => $RTTcfg->{$index}{$value});			
				}
			}
			elsif ( $RTTcfg->{$index}{$value} =~ /$qrip/ and $value !~ /$qrnotdns/) {
				print $t->elapTime(). " DNS2 MAT $index: $value, $RTTcfg->{$index}{$value}\n" if $debug; 
				if ( $IPSLA->existDnsCache(lookup => $value) ) {
					print $t->elapTime(). " DNS2 UPD: lookup=$value result=$RTTcfg->{$index}{$value}\n";
					$IPSLA->updateDnsCache(lookup => $value, result => $RTTcfg->{$index}{$value});
				}
				else {
					print $t->elapTime(). " DNS2 ADD: lookup=$value result=$RTTcfg->{$index}{$value}\n";
					$IPSLA->addDnsCache(lookup => $value, result => $RTTcfg->{$index}{$value});			
				}
			}
			else {
				#print "DEBUG: $value is not an IP address\n";
			}
		}
	}
	else {
		print "ERROR: There seems to be a problem with record $index\n";
	}
}

