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

use FindBin;
use lib "$FindBin::Bin/../lib";

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use NMISNG::Util;
use rrdfunc;
use Compat::NMIS;
use Compat::Timing;

my $t = Compat::Timing->new();

my $perfDir = "/usr/local/omk/var/perf";


print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});
rrdfunc::require_RRDs(config=>$C);

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
my $LNT = Compat::NMIS::loadLocalNodeTable();
print "  done in ".$t->deltaTime() ."\n";

my $sum = initSummary();
my $objtotal = 0;

# Work through each node looking for interfaces, etc to tune.
foreach my $node (sort keys %{$LNT}) {
	++$sum->{count}{node};
	my $objcount = 0;
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		my $time = time();
		my $perf;
		
		++$sum->{count}{active};
		print $t->markTime(). " Processing $node\n";

		# Initiase the system object and load a node.
		my $S = NMISNG::Sys->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;

		my $availability = undef;
		my $reachability = undef;
		my $responsetime = undef;
		my $MemoryFreePROC = undef;
		my $MemoryUsedPROC = undef;

		my $PerMemoryFreePROC = undef;
		my $PerMemoryUsedPROC = undef;

		my $MemoryTotalPROC = undef;
		my $MemoryFreeIO = undef;
		my $MemoryUsedIO = undef;
		my $MemoryTotalIO = undef;
		my $avgBusy5 = undef;
		my $bufferElFree = undef;
		my $bufferElHit = undef;
		my $bufferFail = undef;

		print "  ". $t->elapTime(). " Looking for health data\n";
		if (defined $NI->{database}{health}) {
			my $rrd = $NI->{database}{health};
			my $hash = RRDs::info($rrd);
			++$objcount;

			$availability = $hash->{'ds[availability].last_ds'};
			$reachability = $hash->{'ds[reachability].last_ds'};
			$responsetime = $hash->{'ds[responsetime].last_ds'};
			#$responsetimeValue = $hash->{'ds[responsetime].value'};
		}
		
		$perf->{node} = $node;
		$perf->{time} = $time;
		$perf->{system}{Availability} = $availability;
		$perf->{system}{Reachability} = $reachability;
		$perf->{system}{NRT} = $responsetime;

		if ( $NI->{system}{nodeModel} eq "CiscoRouter" ) {
			print "  ". $t->elapTime(). " Looking for nodehealth data\n";
			if (defined $NI->{database}{nodehealth}) {
				my $rrd = $NI->{database}{nodehealth};
				my $hash = RRDs::info($rrd);
				++$objcount;
	
				$MemoryFreePROC = $hash->{'ds[MemoryFreePROC].last_ds'};
				#$MemoryFreePROCValue = $hash->{'ds[MemoryFreePROC].value'};
	
				$MemoryUsedPROC = $hash->{'ds[MemoryUsedPROC].last_ds'};
				#$MemoryUsedPROCValue = $hash->{'ds[MemoryUsedPROC].value'};
	
				$MemoryFreeIO = $hash->{'ds[MemoryFreeIO].last_ds'};
				#$MemoryFreeIOValue = $hash->{'ds[MemoryFreeIO].value'};
	
				$MemoryUsedIO = $hash->{'ds[MemoryUsedIO].last_ds'};
				#$MemoryUsedIOValue = $hash->{'ds[MemoryUsedIO].value'};
	
				$avgBusy5 = $hash->{'ds[avgBusy5].last_ds'};
				#$avgBusy5Value = $hash->{'ds[avgBusy5].value'};
	
				$bufferElFree = $hash->{'ds[bufferElFree].last_ds'};
				#$bufferElFreeValue = $hash->{'ds[bufferElFree].value'};
	
				$bufferElHit = $hash->{'ds[bufferElHit].last_ds'};
				#$bufferElHitValue = $hash->{'ds[bufferElHit].value'};
	
				$bufferFail = $hash->{'ds[bufferFail].last_ds'};
				#$bufferFailValue = $hash->{'ds[bufferFail].value'};		
	
				if ( defined $MemoryUsedPROC and defined $MemoryFreePROC ) {
					$MemoryTotalPROC = $MemoryUsedPROC + $MemoryFreePROC;
					$PerMemoryFreePROC = sprintf("%.2f",$MemoryFreePROC / $MemoryTotalPROC * 100);
					$PerMemoryUsedPROC = sprintf("%.2f",$MemoryUsedPROC / $MemoryTotalPROC * 100);
	
				}
				
				if ( defined $MemoryUsedIO and defined $MemoryFreeIO ) {
					$MemoryTotalIO = $MemoryUsedIO + $MemoryFreeIO;
				}
			}
				
			$perf->{system}{MFreeProc} = $MemoryFreePROC;
			$perf->{system}{MUsedProc} = $MemoryUsedPROC;
			$perf->{system}{MFreeIO} = $MemoryFreeIO;
			$perf->{system}{MUsedIO} = $MemoryUsedIO;
			$perf->{system}{TotMem} = $MemoryTotalPROC;
			$perf->{system}{Per_MFree} = $PerMemoryFreePROC;
			$perf->{system}{Per_MUsed} = $PerMemoryUsedPROC;
			$perf->{system}{Per_CPU} = $avgBusy5;
			$perf->{system}{BufferElFree} = $bufferElFree;
			$perf->{system}{BufferElHit} = $bufferElHit;
			$perf->{system}{BufferFail} = $bufferFail; 
			
			$perf->{system}{ExcpCpu} = $NI->{status}{'cpu--0'}{level};
			$perf->{system}{Per_CPU} = $NI->{status}{'cpu--0'}{value};

			$perf->{system}{ExcpMem} = $NI->{status}{'mem-proc--0'}{level};
		}
        		
		print qq|$node reachability=$reachability availability=$availability responsetime=$responsetime|;
		if ( $NI->{system}{nodeModel} eq "CiscoRouter" ) {
			print qq|avgBusy5=$avgBusy5
    		PerMemoryFreePROC=$PerMemoryFreePROC PerMemoryUsedPROC=$PerMemoryUsedPROC
    		bufferElFree=$bufferElFree bufferElHit=$bufferElHit bufferFail=$bufferFail
|;

		}
		else {
			print "\n";
		}
		
		#Are there any interface RRDs?
		print "  ". $t->elapTime(). " Looking for interface databases\n";
		if (defined $NI->{database}{interface}) {
			foreach my $intf (keys %{$NI->{database}{interface}}) {
				++$sum->{count}{interface};
				my $rrd = $NI->{database}{interface}{$intf};
				#print "    ". $t->elapTime(). " Found $rrd\n";

				# Get the ifSpeed
				my $ifDescr = $NI->{interface}{$intf}{ifDescr};
				my $ifIndex = $NI->{interface}{$intf}{ifIndex};
				my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
				
				# only proceed if the ifSpeed is correct
				if ( $ifSpeed ) {	

					# Get the RRD info on the Interface
					my $hash = RRDs::info($rrd);
					++$objcount;

					if ( time() - $hash->{'last_update'} > 300 ) {
						print "    ". $t->elapTime(). " ERROR $hash->{'last_update'} was more than 300 seconds ago\n";
					}
							
					my $ifInOctetsLast = $hash->{'ds[ifInOctets].last_ds'};
					my $ifOutOctetsLast = $hash->{'ds[ifOutOctets].last_ds'};
					my $ifInOctetsValue = $hash->{'ds[ifInOctets].value'};
					my $ifOutOctetsValue = $hash->{'ds[ifOutOctets].value'};
					my $TOTIFOCTETS = $ifInOctetsLast + $ifOutOctetsLast;
					
					my $PERIFOUTOCTETS = undef;	
					my $PERIFINOCTETS = undef;	
					    
					if ( defined $TOTIFOCTETS and $TOTIFOCTETS > 0 ) {
						$PERIFOUTOCTETS = sprintf("%.2f",($ifInOctetsLast * 100) / $TOTIFOCTETS);	
						$PERIFINOCTETS = sprintf("%.2f",($ifOutOctetsLast * 100) / $TOTIFOCTETS);	
					}
					
					my $ifInUtil = sprintf("%.2f",($ifInOctetsValue * 8 * 100) / ( 300 * $ifSpeed));					
					my $ifOutUtil = sprintf( "%.2f",($ifOutOctetsValue * 8 * 100) / ( 300 * $ifSpeed));

					$perf->{interfaces}{$ifDescr} = {
						INTERFACE => $ifDescr,
						ifIndex => $ifIndex,
						BW => $ifSpeed,
						IFINOCTECTS => $ifInOctetsLast,
						IFOUTOCTETS => $ifOutOctetsLast,
						PERIFINOCTECTS => $PERIFINOCTETS,
						PERIFOUTOCTETS => $PERIFOUTOCTETS,
						
						EXCPIN => $NI->{status}{"util_in--$ifIndex"}{level},
						IfInU => $NI->{status}{"util_in--$ifIndex"}{value},
						IfInDiscards => undef,
						IfInErrors => undef,

						EXCPOUT => $NI->{status}{"util_out--$ifIndex"}{level},
						IfOutU => $NI->{status}{"util_out--$ifIndex"}{value},
						IfOutDiscards => undef,
						IfOutErrors => undef,

						ExcpErrIn => $NI->{status}{"pkt_errors_in--$ifIndex"}{level},
						PerIfInErrors => $NI->{status}{"pkt_errors_in--$ifIndex"}{value},

						ExcpErrOut => $NI->{status}{"pkt_errors_out--$ifIndex"}{level},
						PerIfOutErrors => $NI->{status}{"pkt_errors_out--$ifIndex"}{value},

						ExcpDisIn => $NI->{status}{"pkt_discards_in--$ifIndex"}{level},
						PerIfInDiscards => $NI->{status}{"pkt_discards_in--$ifIndex"}{value},

						ExcpDisOut => $NI->{status}{"pkt_discards_out--$ifIndex"}{level},
						PerIfOutDiscards => $NI->{status}{"pkt_discards_out--$ifIndex"}{value},
					};
						   					
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
    
		##Are there any CBQoS RRDs?
		if ( $NI->{system}{nodeModel} eq "CiscoRouter" ) {		
			print "  ". $t->elapTime(). " Looking for CBQoS databases\n";
			my @cbqosdb = qw(cbqos-in cbqos-out);
			
			foreach my $cbqos (@cbqosdb) {
				if (defined $NI->{database}{$cbqos}) {
					++$sum->{count}{$cbqos};
					foreach my $intf (keys %{$NI->{database}{$cbqos}}) {
						++$sum->{count}{"$cbqos-interface"};
	    
						# Get the ifSpeed
						my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
						my $ifDescr = $NI->{interface}{$intf}{ifDescr};
						
						# only proceed if the ifSpeed is correct
						if ( $ifSpeed ) {    
							foreach my $class (keys %{$NI->{database}{$cbqos}{$intf}}) {
								++$sum->{count}{"$cbqos-classes"};
								my $rrd = $NI->{database}{$cbqos}{$intf}{$class};
								print "    ". $t->elapTime(). " Found $rrd\n";
			
								# Get the RRD info on the Interface
								my $hash = RRDs::info($rrd);
								++$objcount;
								
								my ($nuf,$direction) = split("-",$cbqos);
								
								my $PolicyBandwidth = undef;
								foreach my $classidx (keys %{$NI->{cbqos}{$intf}{$direction}{ClassMap}}) {
									if ( $NI->{cbqos}{$intf}{$direction}{ClassMap}{$classidx}{Name} eq $class ) {
										if ( defined $NI->{cbqos}{$intf}{$direction}{ClassMap}{$classidx}{BW}{Value} ) {
											$PolicyBandwidth = $NI->{cbqos}{$intf}{$direction}{ClassMap}{$classidx}{BW}{Value};
										}
									}
								}
	
								my $PrePolicyByteLast = $hash->{'ds[PrePolicyByte].last_ds'};
								my $PrePolicyPktLast = $hash->{'ds[PrePolicyPkt].last_ds'};
								my $DropByteLast = $hash->{'ds[DropByte].last_ds'};
								my $DropPktLast = $hash->{'ds[DropPkt].last_ds'};
								my $NoBufDropPktLast = $hash->{'ds[NoBufDropPkt].last_ds'};
	
								my $PrePolicyByteValue = $hash->{'ds[PrePolicyByte].value'};
								my $DropByteValue = $hash->{'ds[DropByte].value'};
								my $PrePolicyPktValue = $hash->{'ds[PrePolicyPkt].value'};
								my $DropPktValue = $hash->{'ds[DropPkt].value'};
								my $NoBufDropPktValue = $hash->{'ds[NoBufDropPkt].value'};
								
								my $PostPolicyByteLast = $PrePolicyByteLast + $DropByteLast;
								
								print "  ". $t->elapTime(). " $ifDescr $class $ifSpeed PrePolicyByteLast=$PrePolicyByteLast DropByteLast=$DropByteLast PostPolicyByteLast=$PostPolicyByteLast PolicyBandwidth=$PolicyBandwidth\n";
								
							}							
						}
						# no valid ifSpeed found.
						else {
							print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
						}		
					}
				}
			}
		}
		my $perfFile = "$perfDir/$node.nmis";
		writeHashtoFile(file => $perfFile, data => $perf);
		
		$objtotal += $objcount;

		print "  $node $objcount rrd objects(s) done in ".$t->deltaTime() ."\n";		
	}
	else {
		print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
	}
}

my $complete = $t->elapTime();
my $intPerSec = sprintf("%.2f",$objtotal / $complete);

print "$complete Done\n";	
	
print qq|
$sum->{count}{node} nodes processed, $sum->{count}{active} nodes active
$objtotal\tRRD Objects in $complete seconds
$intPerSec RRD objects per second.

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

