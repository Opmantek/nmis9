#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

use strict;
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use Data::Dumper;
use Net::SNMP; 

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will export nodes from NMIS.
ERROR: need some files to work with
usage: $0 <NODES_CSV_FILE>
eg: $0 node=nodename debug=true

EO_TEXT
	exit 1;
}

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $node = $arg{node};
my $debug = setDebug($arg{debug});

my $t = NMIS::Timing->new();
print $t->elapTime(). " Begin\n" if $debug;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

processNode($node);

print $t->elapTime(). " End\n" if $debug;

# Not loading the VIEW?

sub processNode {
	my $LNT = loadLocalNodeTable();
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print $t->markTime(). " Processing $node\n" if $debug;

		# Initiase the system object and load a node.
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		$S->readNodeView; # from doUpdate  
		my $NI = $S->ndinfo;
		my $NCT = loadNodeConfTable();
		my $NC = $S->ndcfg;
		my $V = $S->view;

		# Get the SNMP Session going.
		my $port = $LNT->{$node}{port};
		$port = 161 if not $port;
		my $session = mysnmpsession($LNT->{$node}{host},$LNT->{$node}{community},$port);

		if ( $NI->{system}{sysDescr} =~ /GS108T|GS724Tv3/ and $NI->{system}{nodeVendor} eq "Netgear" ) {			
			my @ifIndexNum = (1..24);

			my $intfTotal = 0;
			my $intfCollect = 0; # reset counters

			foreach my $index (@ifIndexNum) {
				$intfTotal++;				
				my $ifDescr = "Port $index Gigabit Ethernet";
				
				#$NCT->{$node}{$ifDescr}{ifDescr} = $ifDescr;
				
				#my $prefix = "1.3.6.1.2.1.10.7.10.1.2";
				my $prefix = "1.3.6.1.2.1.10.7.2.1.3";
				my $oid = "$prefix.$index";
				my $dot3PauseOperMode = mysnmpget($session,$oid) if defined $session;
				
				dbg("SNMP $node $ifDescr, dot3PauseOperMode=$dot3PauseOperMode->{$oid}");
				
				if ( $dot3PauseOperMode->{$oid} =~ /^SNMP ERROR/ ) {
					logMsg("ERROR ($node) SNMP Error with $oid");
				}
				
				$S->{info}{interface}{$index} = {
		      'Description' => '',
		      'ifAdminStatus' => 'unknown',
		      'ifDescr' => $ifDescr,
		      'ifIndex' => $index,
		      'ifLastChange' => '0:00:00',
		      'ifLastChangeSec' => 0,
		      'ifOperStatus' => 'unknown',
		      'ifSpeed' => 1000000000,
		      'ifType' => 'ethernetCsmacd',
		      'interface' => convertIfName($ifDescr),
		      'real' => 'true',
		      'dot3PauseOperMode' => $dot3PauseOperMode->{$oid},
				};
				
				# preset collect,event to required setting, Node Configuration Will override.
				$S->{info}{interface}{$index}{collect} = "false";
				$S->{info}{interface}{$index}{event} = "true";
				$S->{info}{interface}{$index}{threshold} = "false";
									
				# ifDescr must always be filled
				if ($S->{info}{interface}{$index}{ifDescr} eq "") { $S->{info}{interface}{$index}{ifDescr} = $index; }
				# check for duplicated ifDescr
				foreach my $i (keys %{$S->{info}{interface}}) {
					if ($index ne $i and $S->{info}{interface}{$index}{ifDescr} eq $S->{info}{interface}{$i}{ifDescr}) {
						$S->{info}{interface}{$index}{ifDescr} = "$S->{info}{interface}{$index}{ifDescr}-${index}"; # add index to string
						$V->{interface}{"${index}_ifDescr_value"} = $S->{info}{interface}{$index}{ifDescr}; # update
						dbg("Interface Description changed to $S->{info}{interface}{$index}{ifDescr}");
					}
				}
				### add in anything we find from nodeConf - allows manual updating of interface variables
				### warning - will overwrite what we got from the device - be warned !!!
				if ($NCT->{$node}{$ifDescr}{Description} ne '') {
					$S->{info}{interface}{$index}{nc_Description} = $S->{info}{interface}{$index}{Description}; # save
					$S->{info}{interface}{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $NCT->{$node}{$ifDescr}{Description};
					dbg("Manual update of Description by nodeConf");
				}
				
				if ($NCT->{$node}{$ifDescr}{ifSpeed} ne '') {
					$S->{info}{interface}{$index}{nc_ifSpeed} = $S->{info}{interface}{$index}{ifSpeed}; # save
					$S->{info}{interface}{$index}{ifSpeed} = $V->{interface}{"${index}_ifSpeed_value"} = $NCT->{$node}{$ifDescr}{ifSpeed};
					### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
					$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeed});
					info("Manual update of ifSpeed by nodeConf");
				}
	
				if ($NCT->{$node}{$ifDescr}{ifSpeedIn} ne '') {
					$S->{info}{interface}{$index}{nc_ifSpeedIn} = $S->{info}{interface}{$index}{ifSpeed}; # save
					$S->{info}{interface}{$index}{ifSpeedIn} = $NCT->{$node}{$ifDescr}{ifSpeedIn};
	
					$S->{info}{interface}{$index}{nc_ifSpeed} = $S->{info}{interface}{$index}{nc_ifSpeedIn};
					$S->{info}{interface}{$index}{ifSpeed} = $S->{info}{interface}{$index}{ifSpeedIn};
	
					### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
					$V->{interface}{"${index}_ifSpeedIn_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeedIn});
					info("Manual update of ifSpeedIn by nodeConf");
				}
	
				if ($NCT->{$node}{$ifDescr}{ifSpeedOut} ne '') {
					$S->{info}{interface}{$index}{nc_ifSpeedOut} = $S->{info}{interface}{$index}{ifSpeed}; # save
					$S->{info}{interface}{$index}{ifSpeedOut} = $NCT->{$node}{$ifDescr}{ifSpeedOut};
					### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
					$V->{interface}{"${index}_ifSpeedOut_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeedOut});
					info("Manual update of ifSpeedOut by nodeConf");
				}
				
				# convert interface name
				$S->{info}{interface}{$index}{interface} = convertIfName($S->{info}{interface}{$index}{ifDescr});
				$S->{info}{interface}{$index}{ifIndex} = $index;
				
				### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
				# modify by node Config ?
				if ($NCT->{$node}{$ifDescr}{collect} ne '' and $NCT->{$node}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_collect} = $S->{info}{interface}{$index}{collect};
					$S->{info}{interface}{$index}{collect} = $NCT->{$node}{$ifDescr}{collect};
					dbg("Manual update of Collect by nodeConf");
					if ($S->{info}{interface}{$index}{collect} eq 'false') {
						$S->{info}{interface}{$index}{nocollect} = "Manual update by nodeConf";
					}
				}
				if ($NCT->{$node}{$ifDescr}{event} ne '' and $NCT->{$node}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_event} = $S->{info}{interface}{$index}{event};
					$S->{info}{interface}{$index}{event} = $NCT->{$node}{$ifDescr}{event};
					$S->{info}{interface}{$index}{noevent} = "Manual update by nodeConf" if $S->{info}{interface}{$index}{event} eq 'false'; # reason
					dbg("Manual update of Event by nodeConf");
				}
				if ($NCT->{$node}{$ifDescr}{threshold} ne '' and $NCT->{$node}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_threshold} = $S->{info}{interface}{$index}{threshold};
					$S->{info}{interface}{$index}{threshold} = $NCT->{$node}{$ifDescr}{threshold};
					$S->{info}{interface}{$index}{nothreshold} = "Manual update by nodeConf" if $S->{info}{interface}{$index}{threshold} eq 'false'; # reason
					dbg("Manual update of Threshold by nodeConf");
				}
		
				# interface now up or down, check and set or clear outstanding event.
				if ( $S->{info}{interface}{$index}{collect} eq 'true'
						and $S->{info}{interface}{$index}{ifAdminStatus} =~ /up|ok/ 
						and $S->{info}{interface}{$index}{ifOperStatus} !~ /up|ok|dormant/ 
				) {
					if ($S->{info}{interface}{$index}{event} eq 'true') {
						notify(sys=>$S,event=>"Interface Down",element=>$S->{info}{interface}{$index}{ifDescr},details=>$S->{info}{interface}{$index}{Description});
					}
				} else {
					checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$S->{info}{interface}{$index}{ifDescr},details=>$S->{info}{interface}{$index}{Description});
				}
		
				$S->{info}{interface}{$index}{threshold} = $S->{info}{interface}{$index}{collect};
		
				# number of interfaces collected with collect and event on
				$intfCollect++ if $S->{info}{interface}{$index}{collect} eq 'true' && $S->{info}{interface}{$index}{event} eq 'true';
		
				# save values only if all interfaces are updated
				$NI->{system}{intfTotal} = $intfTotal;
				$NI->{system}{intfCollect} = $intfCollect;
		
				# prepare values for web page
				$V->{interface}{"${index}_ifDescr_value"} = $S->{info}{interface}{$index}{ifDescr};

				$V->{interface}{"${index}_event_value"} = $S->{info}{interface}{$index}{event};
				$V->{interface}{"${index}_event_title"} = 'Event on';
		
				$V->{interface}{"${index}_threshold_value"} = $NC->{node}{threshold} ne 'true' ? 'false': $S->{info}{interface}{$index}{threshold};
				$V->{interface}{"${index}_threshold_title"} = 'Threshold on';
		
				$V->{interface}{"${index}_collect_value"} = $S->{info}{interface}{$index}{collect};
				$V->{interface}{"${index}_collect_title"} = 'Collect on';
		
				# collect status
				delete $V->{interface}{"${index}_nocollect_title"};
				if ($S->{info}{interface}{$index}{collect} eq "true") {
					dbg("ifIndex $index, collect=true");
				} else {
					$V->{interface}{"${index}_nocollect_value"} = $S->{info}{interface}{$index}{nocollect};
					$V->{interface}{"${index}_nocollect_title"} = 'Reason';
					dbg("ifIndex $index, collect=false, $S->{info}{interface}{$index}{nocollect}");
					# no collect => no event, no threshold
					$S->{info}{interface}{$index}{threshold} = $V->{interface}{"${index}_threshold_value"} = 'false';
					$S->{info}{interface}{$index}{event} = $V->{interface}{"${index}_event_value"} = 'false';
				}
		
				# get color depending of state
				$V->{interface}{"${index}_ifAdminStatus_color"} = getAdminColor(sys=>$S,index=>$index);
				$V->{interface}{"${index}_ifOperStatus_color"} = getOperColor(sys=>$S,index=>$index);
				$V->{interface}{"${index}_ifAdminStatus_value"} = $S->{info}{interface}{$index}{ifAdminStatus};
				$V->{interface}{"${index}_ifOperStatus_value"} = $S->{info}{interface}{$index}{ifOperStatus};

				# Add the titles as they are missing from the model.
				$V->{interface}{"${index}_ifOperStatus_title"} = 'Oper Status';
				$V->{interface}{"${index}_ifDescr_title"} = 'Name';
				$V->{interface}{"${index}_ifSpeed_title"} = 'Bandwidth';
				$V->{interface}{"${index}_ifType_title"} = 'Type';
				$V->{interface}{"${index}_ifAdminStatus_title"} = 'Admin Status';
				$V->{interface}{"${index}_ifLastChange_title"} = 'Last Change';
				$V->{interface}{"${index}_Description_title"} = 'Description';
		
				# index number of interface
				$V->{interface}{"${index}_ifIndex_value"} = $index;
				$V->{interface}{"${index}_ifIndex_title"} = 'ifIndex';
			}
			
			# print Dumper $S;

			$S->writeNodeView;  # save node view info in file var/$NI->{name}-view.nmis
			$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.nmis
			writeTable(dir=>'conf',name=>'nodeConf',data=>$NCT);
		}
	}
}

sub mysnmpsession {
	my $node = shift;
	my $community = shift;
	my $port = shift;

	my ($session, $error) = Net::SNMP->session(                   
		-hostname => $node,                  
		-community => $community,                
		-timeout  => $C->{snmp_timeout},                  
		-port => $port
	);  

	if (!defined($session)) {       
		logMsg("ERROR ($node) SNMP Session Error: $error");
		$session = undef;
	}
	
	# lets test the session!
	my $oid = "1.3.6.1.2.1.1.2.0";	
	my $result = mysnmpget($session,$oid);
	if ( $result->{$oid} =~ /^SNMP ERROR/ ) {	
		logMsg("ERROR ($node) SNMP Session Error, bad host or community wrong");
		$session = undef;
	}
	
	return $session; 
}

sub mysnmpget {
	my $session = shift;
	my $oid = shift;
	
	my %pdesc;
		
	my $response = $session->get_request($oid); 
	if ( defined $response ) {
		%pdesc = %{$response};  
		my $err = $session->error; 
		
		if ($err){
			$pdesc{$oid} = "SNMP ERROR"; 
		} 
	}
	else {
		$pdesc{$oid} = "SNMP ERROR: empty value $oid"; 
	}
	
	return \%pdesc;
}
