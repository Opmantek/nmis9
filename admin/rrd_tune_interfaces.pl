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
our $VERSION = "1.2.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 

use strict;
use Fcntl qw(:DEFAULT :flock);
use File::Basename;
use func;
use NMIS;
use NMIS::Timing;
use RRDs 1.000.490; # from Tobias

my $me = basename($0);
print "$me Version $VERSION\n\n";

my $t = NMIS::Timing->new();


# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if (@ARGV == 1 && $ARGV[0] =~ /^(help|--?h(elp)?|--?\?)$/)
{
	print STDERR <<EO_TEXT;

$me will tune RRD database files with safe maximum values where required.

usage: $me strict=(true|false) change=(true|false) [nodes=nodeA,nodeB...]

change: (default: false) modifications are made ONLY if change=true.
strict: (default: false) if strict=true, then the interface maximum is 
set to the interface speed. if strict=false, then the maximum is set to
two times interface speed.

if a list of nodes  is given, then only these will be worked on; otherwise
all (active+collect) nodes are checked.

EO_TEXT
		exit 1;
}

if (!getbool($arg{change})) {
	print "$me running in test mode, no changes will be made!\n";
}

print $t->elapTime(). " Begin\n";

print $t->markTime(). " Loading the Device List\n";
my $LNT = loadLocalNodeTable();
print "  done in ".$t->deltaTime() ."\n";

my @onlythesenodes = split(/\s*,\s*/, $arg{nodes});


my $sum = initSummary();

# Work through each node looking for interfaces, etc to tune.
foreach my $node (sort keys %{$LNT}) 
{
	if (@onlythesenodes && !grep($_ eq $node, @onlythesenodes))
	{
		print $t->elapTime(). " Skipping node $node, not in list of requested nodes\n";	
		next;
	}
	++$sum->{count}{node};
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) 
	{
		++$sum->{count}{active};
		print $t->markTime(). " Processing $node\n";

		# Initiase the system object and load a node.
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		#Are there any interface RRDs?
		print "  ". $t->elapTime(). " Looking for interface databases\n";

		# backwards-compatibility: nmis before 8.5 uses NI section for rrds
		my @instances = $S->can("getTypeInstances") ? $S->getTypeInstances(section => "interface") 
					: keys %{$NI->{database}{interface}};

		foreach my $intf (@instances) 
		{
			++$sum->{count}{interface};
			my $rrd = $S->can("getTypeInstances")? $S->getDBName(graphtype => "interface" , index => $intf) :
					$NI->{database}{interface}{$intf};

			print "    ". $t->elapTime(). " Found $rrd\n";
			
			# Get the ifSpeed
			my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
			print "    ". $t->elapTime(). " Interface speed is set to ".convertIfSpeed($ifSpeed)." ($ifSpeed)\n";
			
			# only proceed if the ifSpeed is correct
			if ( $ifSpeed ) 
			{
				# correct conversion would be bits/8, take double as safety factor for burstable interfaces
				# in strict mode there is no safety factor
				my $ifMaxOctets = getbool($arg{strict})? int($ifSpeed/8) : int($ifSpeed/4);
				
				# Get the RRD info on the Interface
				my $hash = RRDs::info($rrd);
				foreach my $key (sort keys %$hash)
				{
					# Is this an RRD DS (data source)
					if ( $key =~ /ds\[(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)\]\.max/ ) 
					{
						my $dsname = $1;
						print "      ". $t->elapTime(). " Got $key, dsname=$dsname value = \"$hash->{$key}\"\n";
						
						# bad: value blank (which means in RRD U, unbounded), or ifspeed (which is in bits, but the ds is bytes=octets),
						# good: only if its precisely speed-in-bytes
						if ($hash->{$key} != $ifMaxOctets)
						{
							# We need to tune this RRD
							print "      ". $t->elapTime(). " RRD Tune Required for $dsname\n";
							
							# Only make the change if change is set to true
							if ($arg{change} eq "true" )
							{
								print "      ". $t->elapTime(). " Tuning RRD, updating maximum for $dsname, ifIndex $intf to ifMaxOctets=$ifMaxOctets\n";
								#Execute the RRDs::tune API.
								RRDs::tune($rrd, "--maximum", "$dsname:$ifMaxOctets");
								
								# Check for errors.
								if (my $ERROR = RRDs::error) {
									print STDERR "ERROR RRD Tune for $rrd has an error: $ERROR\n";
								}
								else {
									# All GOOD!
									print "      ". $t->elapTime(). " RRD Tune Successful\n";
									++$sum->{count}{'tune-interface'};
								}
							}
							else {
								print "      ". $t->elapTime(). " RRD SHOULD be tuned with change=true, maximum for $dsname, ifIndex $intf to ifMaxOctets=$ifMaxOctets\n";
							}
						}
						# MAX is already set to appropriate value
						else 
						{
							print "      ". $t->elapTime(). " RRD Tune NOT Required, $key=$hash->{$key}\n";
						}
					}
				}
			}
			# no valid ifSpeed found.
			else {
				print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
			}
		}
		
		#Are there any packet RRDs?
		# check both pkts and pkts_hc!
		for my $datatype ("pkts","pkts_hc")
		{
			print "  ". $t->elapTime(). " Looking for $datatype databases\n";
			my @pktinstances = $S->can("getTypeInstances")? $S->getTypeInstances(section => $datatype) 
					: keys %{$NI->{database}{$datatype}};
			
			foreach my $intf (@pktinstances) 
			{
				++$sum->{count}{pkts};
				my $rrd = $S->can("getTypeInstances") ? $S->getDBName(graphtype => $datatype, index => $intf) :
						$NI->{database}{$datatype}{$intf};
				print "    ". $t->elapTime(). " Found $rrd\n";
				
				# Get the ifSpeed
				my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
				
				# only proceed if the ifSpeed is present
				if ( $ifSpeed ) 
				{
					my $maxBytes = getbool($arg{strict})? int($ifSpeed/8) : int($ifSpeed/4);
					my $maxPackets = int($maxBytes/50);
					
					# Get the RRD info on the Interface
					my $hash = RRDs::info($rrd);
					
					# Recurse over the hash to see what you can find.
					foreach my $key (sort keys %$hash)
					{
						
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
										print "      ". $t->elapTime(). " RRD SHOULD be tuned with change=true, maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
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
				else 
				{
					print STDERR "ERROR $node, a valid ifSpeed not found for interface index $intf $NI->{interface}{$intf}{ifDescr} ifSpeed=\"$ifSpeed\"\n";
				}
			}
		}
		
		#Are there any CBQoS RRDs?
		print "  ". $t->elapTime(). " Looking for CBQoS databases\n";
		my @cbqosdb = qw(cbqos-in cbqos-out);
		
		foreach my $cbqos (@cbqosdb) 
		{
			my @instances = $S->can("getTypeInstances") ? $S->getTypeInstances(graphtype => $cbqos) 
					: keys %{$NI->{database}{$cbqos}};
			if (@instances) 
			{
				++$sum->{count}{$cbqos};
				foreach my $intf (@instances) 
				{
					++$sum->{count}{"$cbqos-interface"};
					
					# Get the ifSpeed
					my $ifSpeed = $NI->{interface}{$intf}{ifSpeed};
					
					# only proceed if the ifSpeed is present
					if ( $ifSpeed ) 
					{
						my $maxBytes = getbool($arg{strict})? int($ifSpeed/8) : int($ifSpeed/4);
						my $maxPackets = int($maxBytes/50);
						
						my $dir = ($cbqos eq 'cbqos-in' ? 'in' : 'out');
						foreach my $class (keys %{$NI->{cbqos}{$intf}{$dir}{ClassMap}}) {
							++$sum->{count}{"$cbqos-classes"};
							my $rrd = $S->can("getTypeInstances")? 
									$S->getDBName(graphtype => $cbqos, 
																index => $intf, 
																item => $NI->{cbqos}{$intf}{$dir}{ClassMap}{$class}{Name}) 
									: $NI->{database}{$cbqos}{$intf}{$class};
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
												print "      ". $t->elapTime(). " RRD SHOULD be tuned with change=true, maximum for $dsname, ifIndex $intf to maxType=$maxType, maxValue=$maxValue\n";
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
$sum->{count}{'tune-interface'}\tinterface RRD DataSets tuned
$sum->{count}{pkts}\tpkts RRDs
$sum->{count}{'tune-pkts'}\tpkts RRD DataSets tuned
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

