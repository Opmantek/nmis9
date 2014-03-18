#!/usr/bin/perl
#
## $Id: rrd_tune_interfaces.pl,v 1.4 2012/09/21 04:56:33 keiths Exp $
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
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		++$sum->{count}{active};
		print $t->markTime(). " Processing $node\n";

		# Initiase the system object and load a node.
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		#Are there any interface RRDs?
		print "  ". $t->elapTime(). " Looking for interface databases\n";
		if (defined $NI->{database}{interface}) {
			foreach my $intf (keys %{$NI->{database}{interface}}) {
				++$sum->{count}{interface};
				my $rrd = $NI->{database}{interface}{$intf};
				print "    ". $t->elapTime(). " Found $rrd\n";

				# Get the ifSpeed
				my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
				
				# only proceed if the ifSpeed is correct
				if ( $ifSpeed ) {
					my $ifMaxOctets = int($ifSpeed/8);
					my $maxBytes = int($ifSpeed/4);
					my $maxPackets = int($maxBytes/50);
	
					# Get the RRD info on the Interface
					my $hash = RRDs::info($rrd);
					
					# Recurse over the hash to see what you can find.
					foreach my $key (sort keys %$hash){

						# Is this an RRD DS (data source)
						if ( $key =~ /^ds/ ) {
						
							# Is this the DS's we are intersted in?
							if ( $key =~ /ds\[(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)\]\.max/ ) {
								my $dsname = $1;
								print "      ". $t->elapTime(). " Got $key, dsname=$dsname value = \"$hash->{$key}\"\n";
							
								# Is the value blank (which means in RRD U, unbounded).
								if ( $hash->{$key} eq "" or $hash->{$key} == $ifSpeed or $hash->{$key} == $ifMaxOctets) {
									# We need to tune this RRD
									print "      ". $t->elapTime(). " RRD Tune Required for $dsname\n";
																
									# Got everything we need
									#print qq|RRDs::tune($rrd, "--maximum", "$dsname:$maxBytes")\n| if $debug;
									
									# Only make the change if change is set to true
									if ($arg{change} eq "true" ) {
										print "      ". $t->elapTime(). " Tuning RRD, updating maximum for $dsname, ifIndex $intf to maxBytes=$maxBytes\n";
										#Execute the RRDs::tune API.
										RRDs::tune($rrd, "--maximum", "$dsname:$maxBytes");
										
										# Check for errors.
										my $ERROR = RRDs::error;
										if ($ERROR) {
											print STDERR "ERROR RRD Tune for $rrd has an error: $ERROR\n";
										}
										else {
											# All GOOD!
											print "      ". $t->elapTime(). " RRD Tune Successful\n";
											++$sum->{count}{'tune-interface'};
										}
									}
									else {
										print "      ". $t->elapTime(). " RRD Will be Tuned, maximum for $dsname, ifIndex $intf to maxBytes=$maxBytes\n";
									}
								}
								# MAX is already set to something
								else {
									print "      ". $t->elapTime(). " RRD Tune NOT Required, $key=$hash->{$key}\n";
								}
							}
						}
					}
				}
				# no valid ifSpeed found.
				else {
					print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
				}
			}
		}

		#Are there any packet RRDs?
		print "  ". $t->elapTime(). " Looking for pkts databases\n";
		if (defined $NI->{database}{pkts}) {
			foreach my $intf (keys %{$NI->{database}{pkts}}) {
				++$sum->{count}{pkts};
				my $rrd = $NI->{database}{pkts}{$intf};
				print "    ". $t->elapTime(). " Found $rrd\n";

				# Get the ifSpeed
				my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
				
				# only proceed if the ifSpeed is correct
				if ( $ifSpeed ) {
					my $ifMaxOctets = int($ifSpeed/8);
					my $maxBytes = int($ifSpeed/4);
					my $maxPackets = int($maxBytes/50);
	
					# Get the RRD info on the Interface
					my $hash = RRDs::info($rrd);
					
					# Recurse over the hash to see what you can find.
					foreach my $key (sort keys %$hash){

						# Is this an RRD DS (data source)
						if ( $key =~ /^ds/ ) {
						
							# Is this the DS's we are intersted in?
							#PKTS, with ifInOctets, ifInUcastPkts, ifInNUcastPkts, ifInDiscards, ifInErrors and ifOutOctets, ifOutUcastPkts, ifOutNUcastPkts, ifOutDiscards, ifOutErrors
							if ( $key =~ /ds\[(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)\]\.max/ ) {
								my $dsname = $1;
								print "      ". $t->elapTime(). " Got $key, dsname=$dsname value = \"$hash->{$key}\"\n";
	
								my $maxValue = $maxPackets;
								my $maxType = "maxPackets";
								if ( $dsname =~ /ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets/ ) {
									$maxValue = $maxBytes;
									$maxType = "maxBytes";
								}
							
								# Is the value blank (which means in RRD U, unbounded).
								if ( $hash->{$key} eq "" or $hash->{$key} != $maxValue) {
									# We need to tune this RRD
									print "      ". $t->elapTime(). " RRD Tune Required for $dsname\n";
																
									# Got everything we need
									#print qq|RRDs::tune($rrd, "--maximum", "$dsname:$maxValue")\n| if $debug;
									
									# Only make the change if change is set to true
									if ($arg{change} eq "true" ) {
										print "      ". $t->elapTime(). " Tuning RRD, updating maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
										#Execute the RRDs::tune API.
										RRDs::tune($rrd, "--maximum", "$dsname:$maxValue");
										
										# Check for errors.
										my $ERROR = RRDs::error;
										if ($ERROR) {
											print STDERR "ERROR RRD Tune for $rrd has an error: $ERROR\n";
										}
										else {
											# All GOOD!
											print "      ". $t->elapTime(). " RRD Tune Successful\n";
											++$sum->{count}{'tune-pkts'};
										}
									}
									else {
										print "      ". $t->elapTime(). " RRD Will be Tuned, maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
									}
								}
								# MAX is already set to something
								else {
									print "      ". $t->elapTime(). " RRD Tune NOT Required, $key=$hash->{$key}\n";
								}
							}
						}
					}
				}
				# no valid ifSpeed found.
				else {
					print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
				}
			}
		}

		#Are there any CBQoS RRDs?
		print "  ". $t->elapTime(). " Looking for CBQoS databases\n";
		my @cbqosdb = qw(cbqos-in cbqos-out);
		
		foreach my $cbqos (@cbqosdb) {
			if (defined $NI->{database}{$cbqos}) {
				++$sum->{count}{$cbqos};
				foreach my $intf (keys %{$NI->{database}{$cbqos}}) {
					++$sum->{count}{"$cbqos-interface"};

					# Get the ifSpeed
					my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
					
					# only proceed if the ifSpeed is correct
					if ( $ifSpeed ) {
						my $ifMaxOctets = int($ifSpeed/8);
						my $maxBytes = int($ifSpeed/4);
						my $maxPackets = int($maxBytes/50);

						foreach my $class (keys %{$NI->{database}{$cbqos}{$intf}}) {
							++$sum->{count}{"$cbqos-classes"};
							my $rrd = $NI->{database}{$cbqos}{$intf}{$class};
							print "    ". $t->elapTime(). " Found $rrd\n";
		
							# Get the RRD info on the Interface
							my $hash = RRDs::info($rrd);
							
							# Recurse over the hash to see what you can find.
							foreach my $key (sort keys %$hash){
		
								# Is this an RRD DS (data source)
								if ( $key =~ /^ds/ ) {
								
									# Is this the DS's we are intersted in?
									#CBQoS, with PrePolicyByte, DropByte, PrePolicyPkt, DropPkt, NoBufDropPkt
									if ( $key =~ /ds\[(PrePolicyByte|DropByte|PostPolicyByte|PrePolicyPkt|DropPkt|NoBufDropPkt)\]\.max/ ) {
										my $dsname = $1;
										print "      ". $t->elapTime(). " Got $key, dsname=$dsname value = \"$hash->{$key}\"\n";
			
										my $maxValue = $maxPackets;
										my $maxType = "maxPackets";
										if ( $dsname =~ /PrePolicyByte|DropByte/ ) {
											$maxValue = $maxBytes;
											$maxType = "maxBytes";
										}
									
										# Is the value blank (which means in RRD U, unbounded).
										if ( $hash->{$key} eq "" or $hash->{$key} != $maxValue) {
											# We need to tune this RRD
											print "      ". $t->elapTime(). " RRD Tune Required for $dsname\n";
																		
											# Got everything we need
											#print qq|RRDs::tune($rrd, "--maximum", "$dsname:$maxValue")\n| if $debug;
											
											# Only make the change if change is set to true
											if ($arg{change} eq "true" ) {
												print "      ". $t->elapTime(). " Tuning RRD, updating maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
												#Execute the RRDs::tune API.
												RRDs::tune($rrd, "--maximum", "$dsname:$maxValue");
												
												# Check for errors.
												my $ERROR = RRDs::error;
												if ($ERROR) {
													print STDERR "ERROR RRD Tune for $rrd has an error: $ERROR\n";
												}
												else {
													# All GOOD!
													print "      ". $t->elapTime(). " RRD Tune Successful\n";
													++$sum->{count}{"tune-$cbqos-classes"};
												}
											}
											else {
												print "      ". $t->elapTime(). " RRD Will be Tuned, maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
											}
										}
										# MAX is already set to something
										else {
											print "      ". $t->elapTime(). " RRD Tune NOT Required, $key=$hash->{$key}\n";
										}
									}
									else {
										#print "      ". $t->elapTime(). " IGN $key, value = \"$hash->{$key}\"\n";
									}
								}								
							}
						}							
					}
					# no valid ifSpeed found.
					else {
						print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
					}		
				}
			}
		}

		print "  done in ".$t->deltaTime() ."\n";		
	}
	else {
		print $t->elapTime(). " Skipping node $node active=$LNT->{$node}{active} and collect=$LNT->{$node}{collect}\n";	
	}
}
	
print qq|
$sum->{count}{node} nodes processed, $sum->{count}{active} nodes active
$sum->{count}{interface}\tinterface RRDs
$sum->{count}{'tune-interface'}\tinterface RRDs tuned
$sum->{count}{pkts}\tpkts RRDs
$sum->{count}{'tune-pkts'}\tpkts RRDs tuned
$sum->{count}{'cbqos-in-interface'}\tcbqos-in interfaces
$sum->{count}{'cbqos-out-interface'}\tcbqos-out interfaces
$sum->{count}{'cbqos-in-classes'}\tcbqos-in RRD classes
$sum->{count}{'tune-cbqos-in-classes'}\tcbqos-in RRD classes tuned
$sum->{count}{'cbqos-out-classes'}\tcbqos-out RRD classes
$sum->{count}{'tune-cbqos-out-classes'}\tcbqos-out RRD classes tuned
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

