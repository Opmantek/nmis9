#!/usr/bin/perl
#
## $Id: rrd_tune_interfaces.pl,v 1.4 2012/09/21 04:56:33 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use NMIS::Timing;
use RRDs 1.000.490; # from Tobias

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will tune RRD database files with required changes.
usage: $0 run=(true|false) change=(true|false)
eg: $0 run=true (will run in test mode)
or: $0 run=true change=true (will run in change mode)

EO_TEXT
	exit 1;
}

if ( $arg{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}

if ( $arg{run} eq "true" and $arg{change} ne "true" ) {
	print "$0 running in test mode, no changes will be made!\n";
}

print $t->markTime(). " Loading the Device List\n";
my $LNT = loadLocalNodeTable();
print "  done in ".$t->deltaTime() ."\n";

my $sum = initSummary();

# Work through each node looking for interfaces, etc to tune.
foreach my $node (sort keys %{$LNT}) {
	++$sum->{count}{node};
	my $intcount = 0;
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		++$sum->{count}{active};
		print $t->markTime(). " Processing $node\n";

		# Initiase the system object and load a node.
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		#Are there any interface RRDs?
		#print "  ". $t->elapTime(). " Looking for interface databases\n";
		if (defined $NI->{database}{interface}) {
			foreach my $intf (keys %{$NI->{database}{interface}}) {
				++$sum->{count}{interface};
				++$intcount;
				my $rrd = $NI->{database}{interface}{$intf};
				#print "    ". $t->elapTime(). " Found $rrd\n";

				# Get the ifSpeed
				my $ifDescr = $NI->{interface}{$intf}{ifDescr};
				my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
				
				# only proceed if the ifSpeed is correct
				if ( $ifSpeed ) {	

					# Get the RRD info on the Interface
					my $hash = RRDs::info($rrd);
					
					if ( time() - $hash->{'last_update'} > 300 ) {
						print "    ". $t->elapTime(). " ERROR $hash->{'last_update'} was more than 300 seconds ago\n";
					}
							
					my $ifInOctetsLast = $hash->{'ds[ifInOctets].last_ds'};
					my $ifOutOctetsLast = $hash->{'ds[ifOutOctets].last_ds'};
					my $ifInOctetsValue = $hash->{'ds[ifInOctets].value'};
					my $ifOutOctetsValue = $hash->{'ds[ifOutOctets].value'};
					my $ifInUtil = sprintf("%.2f",($ifInOctetsValue * 8 * 100) / ( 300 * $ifSpeed));					
					my $ifOutUtil = sprintf( "%.2f",($ifOutOctetsValue * 8 * 100) / ( 300 * $ifSpeed));
					
					print "  ". $t->elapTime(). " $ifDescr $ifSpeed ifInOctets=$ifInOctetsLast ifOutOctets=$ifOutOctetsLast ifInOctetsValue=$ifInOctetsValue ifOutOctetsValue=$ifOutOctetsValue ifInUtil=$ifInUtil\% ifOutUtil=$ifOutUtil\%\n";
				}
				# no valid ifSpeed found.
				else {
					print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
				}
			}
		}

		#Are there any packet RRDs?
		#print "  ". $t->elapTime(). " Looking for pkts databases\n";
		#if (defined $NI->{database}{pkts}) {
		#	foreach my $intf (keys %{$NI->{database}{pkts}}) {
		#		++$sum->{count}{pkts};
		#		my $rrd = $NI->{database}{pkts}{$intf};
		#		print "    ". $t->elapTime(). " Found $rrd\n";
    #
		#		# Get the ifSpeed
		#		my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
		#		
		#		# only proceed if the ifSpeed is correct
		#		if ( $ifSpeed ) {
		#			my $ifMaxOctets = int($ifSpeed/8);
		#			my $maxBytes = int($ifSpeed/4);
		#			my $maxPackets = int($maxBytes/50);
	  #
		#			# Get the RRD info on the Interface
		#			my $hash = RRDs::info($rrd);
		#			
		#			# Recurse over the hash to see what you can find.
		#			foreach my $key (sort keys %$hash){
    #
		#				# Is this an RRD DS (data source)
		#				if ( $key =~ /^ds/ ) {
		#				
		#					# Is this the DS's we are intersted in?
		#					#PKTS, with ifInOctets, ifInUcastPkts, ifInNUcastPkts, ifInDiscards, ifInErrors and ifOutOctets, ifOutUcastPkts, ifOutNUcastPkts, ifOutDiscards, ifOutErrors
		#					if ( $key =~ /ds\[(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)\]\.(last_ds|value)/ ) {
		#						my $dsname = $1;
		#						my $property = $2;
		#						print "      ". $t->elapTime(). " Got $key, dsname=$dsname property=$property value = \"$hash->{$key}\"\n";
		#					
	  #
		#						my $maxValue = $maxPackets;
		#						my $maxType = "maxPackets";
		#						if ( $dsname =~ /ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets/ ) {
		#							$maxValue = $maxBytes;
		#							$maxType = "maxBytes";
		#						}
		#					}
		#				}
		#			}
		#		}
		#		# no valid ifSpeed found.
		#		else {
		#			print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
		#		}
		#	}
		#}
    #
		##Are there any CBQoS RRDs?
		#print "  ". $t->elapTime(). " Looking for CBQoS databases\n";
		#my @cbqosdb = qw(cbqos-in cbqos-out);
		#
		#foreach my $cbqos (@cbqosdb) {
		#	if (defined $NI->{database}{$cbqos}) {
		#		++$sum->{count}{$cbqos};
		#		foreach my $intf (keys %{$NI->{database}{$cbqos}}) {
		#			++$sum->{count}{"$cbqos-interface"};
    #
		#			# Get the ifSpeed
		#			my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
		#			
		#			# only proceed if the ifSpeed is correct
		#			if ( $ifSpeed ) {
		#				my $ifMaxOctets = int($ifSpeed/8);
		#				my $maxBytes = int($ifSpeed/4);
		#				my $maxPackets = int($maxBytes/50);
    #
		#				foreach my $class (keys %{$NI->{database}{$cbqos}{$intf}}) {
		#					++$sum->{count}{"$cbqos-classes"};
		#					my $rrd = $NI->{database}{$cbqos}{$intf}{$class};
		#					print "    ". $t->elapTime(). " Found $rrd\n";
		#
		#					# Get the RRD info on the Interface
		#					my $hash = RRDs::info($rrd);
		#					
		#					# Recurse over the hash to see what you can find.
		#					foreach my $key (sort keys %$hash){
		#
		#						# Is this an RRD DS (data source)
		#						if ( $key =~ /^ds/ ) {
		#						
		#							# Is this the DS's we are intersted in?
		#							#CBQoS, with PrePolicyByte, DropByte, PrePolicyPkt, DropPkt, NoBufDropPkt
		#							if ( $key =~ /ds\[(PrePolicyByte|DropByte|PrePolicyPkt|DropPkt|NoBufDropPkt)\]\.(last_ds|value)/ ) {
		#								my $dsname = $1;
		#								my $property = $2;
		#								print "      ". $t->elapTime(). " Got $key, dsname=$dsname property=$property value = \"$hash->{$key}\"\n";
		#	
		#								my $maxValue = $maxPackets;
		#								my $maxType = "maxPackets";
		#								if ( $dsname =~ /PrePolicyByte|DropByte/ ) {
		#									$maxValue = $maxBytes;
		#									$maxType = "maxBytes";
		#								}
		#							}
		#							else {
		#								#print "      ". $t->elapTime(). " IGN $key, value = \"$hash->{$key}\"\n";
		#							}
		#						}								
		#					}
		#				}							
		#			}
		#			# no valid ifSpeed found.
		#			else {
		#				print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
		#			}		
		#		}
		#	}
		#}

		print "  $node $intcount interface(s) done in ".$t->deltaTime() ."\n";		
	}
	else {
		print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
	}
}

my $complete = $t->elapTime();
my $intPerSec = sprintf("%.2f",$sum->{count}{interface} / $complete);

print "$complete Done\n";	
	
print qq|
$sum->{count}{node} nodes processed, $sum->{count}{active} nodes active
$sum->{count}{interface}\tinterface RRDs in $complete seconds
$intPerSec interfaces per second.

|;


sub initSummary {
	my $sum;

	$sum->{count}{node} = 0;
	$sum->{count}{interface} = 0;
	$sum->{count}{'tune-interface'} = 0;
	$sum->{count}{pkts} = 0;
	$sum->{count}{'tune-pkts'} = 0;
	$sum->{count}{'cbqos-in-interface'} = 0;
	$sum->{count}{'cbqos-out-interface'} = 0;
	$sum->{count}{'cbqos-in-classes'} = 0;
	$sum->{count}{'tune-cbqos-in-classes'} = 0;
	$sum->{count}{'cbqos-out-classes'} = 0;
	$sum->{count}{'tune-cbqos-out-classes'} = 0;

	return $sum;
}

