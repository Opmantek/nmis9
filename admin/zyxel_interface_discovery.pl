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
ERROR: need the node name to work with
usage: $0 node=nodename
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


sub processNode {
	my $LNT = loadLocalNodeTable();
	my $IFT = loadifTypesTable();
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

		my $intfCollect;
		my $intfTotal;
		
		# Get the SNMP Session going.
		my $port = $LNT->{$node}{port};
		$port = 161 if not $port;

		if ( $NI->{system}{sysDescr} =~ /IES|IOS/ and $NI->{system}{nodeVendor} =~ "ZyXEL Communications Corp.|Cisco" ) {
			dbg("Getting SNMP Session to $node");
			my $session = mysnmpsession($LNT->{$node}{host},$LNT->{$node}{community},$port);
									
			my $ifIndexOid = "1.3.6.1.2.1.2.2.1.1";
		  my $ifDescrOid = "1.3.6.1.2.1.2.2.1.2";
		  my $ifTypeOid = "1.3.6.1.2.1.2.2.1.3";
		  my $ifSpeedOid = "1.3.6.1.2.1.2.2.1.5";
		  my $ifAdminStatusOid = "1.3.6.1.2.1.2.2.1.7";
		  my $ifOperStatusOid = "1.3.6.1.2.1.2.2.1.8";
		  my $ifLastChangeOid = "1.3.6.1.2.1.2.2.1.9";
		  my $ifAliasOid = "1.3.6.1.2.1.31.1.1.1.18";
		  my $ifHighSpeedOid = "1.3.6.1.2.1.31.1.1.1.15";

			# get the ifIndexes
			my @ifIndexNum = getIndexList($session,$ifIndexOid);
			dbg("Got some ifIndexes: @ifIndexNum") if @ifIndexNum;
			
			# Get the special ZyXEL names and such.
			my $subrPortNameOid = "1.3.6.1.4.1.890.1.5.13.5.8.1.1.1";
			my $subrPortTelOid = "1.3.6.1.4.1.890.1.5.13.5.8.1.1.2";
			
			# The IES 1248 Appears to use the next MIB ID along.
			if ( $NI->{system}{sysDescr} =~ /1248/ ) {
				#"iesSeries"		"1.3.6.1.4.1.890.1.5.13"
				#ZYXEL-MIB::iesSeries.6.8.1.1.1.48 = STRING: "teresa-luisoni"
				#ZYXEL-MIB::iesSeries.6.8.1.1.2.1 = STRING: "8095380218"

				$subrPortNameOid = "1.3.6.1.4.1.890.1.5.13.6.8.1.1.1";
				$subrPortTelOid = "1.3.6.1.4.1.890.1.5.13.6.8.1.1.2";
			}
			
			my $subrPortName = getIndexData($session,$subrPortNameOid);
			my $subrPortTel = getIndexData($session,$subrPortTelOid);

			foreach my $index (@ifIndexNum) {
				dbg("Working on $index");
				# Declare the required VARS
				my @oids = (
					"$ifDescrOid.$index",
					"$ifTypeOid.$index",
					"$ifSpeedOid.$index",
					"$ifAdminStatusOid.$index",
					"$ifOperStatusOid.$index",
					"$ifLastChangeOid.$index",
					# These do not appear to be implemented consistently
					#"$ifAliasOid.$index",
					#"$ifHighSpeedOid.$index",
				);
				
				# Store them straight into the results
				my $snmpData = getData($session,@oids);
				
				my $ifDescr = $snmpData->{"$ifDescrOid.$index"};
				my $ifType = $IFT->{$snmpData->{"$ifTypeOid.$index"}}{ifType};
				my $ifSpeed = $snmpData->{"$ifSpeedOid.$index"};
				my $ifAdminStatus = ifStatus($snmpData->{"$ifAdminStatusOid.$index"});
				my $ifOperStatus = ifStatus($snmpData->{"$ifOperStatusOid.$index"});
				my $ifLastChange = $snmpData->{"$ifLastChangeOid.$index"};
				my $ifAlias = $snmpData->{"$ifAliasOid.$index"} || undef;
				my $ifHighSpeed = $snmpData->{"$ifHighSpeedOid.$index"} || undef;
								
				my $Description = $ifAlias;
				if ( $subrPortTel->{$index} ne "" and $subrPortName->{$index} ne "") {
					$Description = "$subrPortName->{$index}: $subrPortTel->{$index}";
				}
				elsif ( $subrPortName->{$index} ne "" ) {
					$Description = "$subrPortName->{$index}";
				}
				elsif ( $subrPortTel->{$index} ne "" ) {
					$Description = "$subrPortTel->{$index}";
				}

				dbg("SNMP $node $ifDescr $Description, index=$index, ifType=$ifType, ifSpeed=$ifSpeed, ifAdminStatus=$ifAdminStatus, ifOperStatus=$ifOperStatus, subrPortName=$subrPortName->{$index}, subrPortTel=$subrPortTel->{$index}");
				
				$S->{info}{interface}{$index} = {
		      'Description' => $Description,
		      'ifAdminStatus' => $ifAdminStatus,
		      'ifDescr' => $ifDescr,
		      'ifIndex' => $index,
		      'ifLastChange' => convUpTime($ifLastChange = int($ifLastChange/100)),
		      'ifLastChangeSec' => $ifLastChange,
		      'ifOperStatus' => $ifOperStatus,
		      'ifSpeed' => $ifSpeed,
		      'ifType' => $ifType,
		      'interface' => $ifDescr,
		      'real' => 'true',
		      'threshold' => 'true'
				};
				
				# preset collect,event to required setting, Node Configuration Will override.
				$S->{info}{interface}{$index}{collect} = "false";
				$S->{info}{interface}{$index}{event} = "false";
				$S->{info}{interface}{$index}{nocollect} = "Manual interface discovery policy";

				# collect the uplinks!
				if ( $ifType =~ "ethernetCsmacd" and $ifDescr !~ /virtual/ and $ifOperStatus eq "up" and $ifOperStatus eq "up" ) {
					$S->{info}{interface}{$index}{collect} = "true";
					$S->{info}{interface}{$index}{event} = "true";
					$S->{info}{interface}{$index}{nocollect} = "";
				}

				# ifDescr must always be filled
				if ($S->{info}{interface}{$index}{ifDescr} eq "") { $S->{info}{interface}{$index}{ifDescr} = $index; }
				# check for duplicated ifDescr
				foreach my $i (sort {$a <=> $b} keys %{$S->{info}{interface}}) {
					if ($index ne $i and $S->{info}{interface}{$index}{ifDescr} eq $S->{info}{interface}{$i}{ifDescr}) {
						$S->{info}{interface}{$index}{ifDescr} = "$S->{info}{interface}{$index}{ifDescr}-${index}"; # add index to string
						$V->{interface}{"${index}_ifDescr_value"} = $S->{info}{interface}{$index}{ifDescr}; # update
						dbg("Interface Description changed to $S->{info}{interface}{$index}{ifDescr}");
					}
				}
				### add in anything we find from nodeConf - allows manual updating of interface variables
				### warning - will overwrite what we got from the device - be warned !!!
				if ($NCT->{$S->{node}}{$ifDescr}{Description} ne '') {
					$S->{info}{interface}{$index}{nc_Description} = $S->{info}{interface}{$index}{Description}; # save
					$S->{info}{interface}{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $NCT->{$S->{node}}{$ifDescr}{Description};
					dbg("Manual update of Description by nodeConf");
				}
				else {
					$V->{interface}{"${index}_Description_value"} = $S->{info}{interface}{$index}{Description};
				}
				
				if ($NCT->{$S->{node}}{$ifDescr}{ifSpeed} ne '') {
					$S->{info}{interface}{$index}{nc_ifSpeed} = $S->{info}{interface}{$index}{ifSpeed}; # save
					$S->{info}{interface}{$index}{ifSpeed} = $NCT->{$S->{node}}{$ifDescr}{ifSpeed};
					dbg("Manual update of ifSpeed by nodeConf");
				}
				
				$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeed});
				
				# convert interface name
				$S->{info}{interface}{$index}{interface} = convertIfName($S->{info}{interface}{$index}{ifDescr});
				$S->{info}{interface}{$index}{ifIndex} = $index;
				
				### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
				# modify by node Config ?
				if ($NCT->{$S->{name}}{$ifDescr}{collect} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_collect} = $S->{info}{interface}{$index}{collect};
					$S->{info}{interface}{$index}{collect} = $NCT->{$S->{name}}{$ifDescr}{collect};
					dbg("Manual update of Collect by nodeConf");
					if ($S->{info}{interface}{$index}{collect} eq 'false') {
						$S->{info}{interface}{$index}{nocollect} = "Manual update by nodeConf";
					}
				}
				if ($NCT->{$S->{name}}{$ifDescr}{event} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_event} = $S->{info}{interface}{$index}{event};
					$S->{info}{interface}{$index}{event} = $NCT->{$S->{name}}{$ifDescr}{event};
					$S->{info}{interface}{$index}{noevent} = "Manual update by nodeConf" if $S->{info}{interface}{$index}{event} eq 'false'; # reason
					dbg("Manual update of Event by nodeConf");
				}
				if ($NCT->{$S->{name}}{$ifDescr}{threshold} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
					$S->{info}{interface}{$index}{nc_threshold} = $S->{info}{interface}{$index}{threshold};
					$S->{info}{interface}{$index}{threshold} = $NCT->{$S->{name}}{$ifDescr}{threshold};
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
				++$intfCollect if $S->{info}{interface}{$index}{collect} eq 'true' && $S->{info}{interface}{$index}{event} eq 'true';
		
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
			
			#print Dumper $S;

			$S->writeNodeView;  # save node view info in file var/$NI->{name}-view.nmis
			$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.nmis			
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
	else {
		dbg("SNMP WORKS: $result->{$oid}");
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

# get hash with key containing only indexes of oid
sub getIndexList {
	my $session = shift;
	my $oid = shift;
	
	my $msg;
	my @indexes;

	# get it
	my $result = $session->get_table( -baseoid => $oid );	

	if ( $session->error() ne "" ) {
		my $error = $session->error();
		dbg("SNMP ERROR: $error");
		return undef;
	}
	
	foreach my $key (sort {$result->{$a} <=> $result->{$b}} keys %{$result} ) {
		push(@indexes,$result->{$key});
	}
	return @indexes;
}

# get hash with key containing only indexes of oid
sub getIndexData {
	my $session = shift;
	my $oid = shift;
	
	my $msg;
	my $data;

	# get it
	my $result = $session->get_table( -baseoid => $oid );	

	if ( $session->error() ne "" ) {
		my $error = $session->error();
		dbg("SNMP ERROR: $error");
		return undef;
	}
	
	foreach my $key (sort {$result->{$a} <=> $result->{$b}} keys %{$result} ) {
		my $oidIndex = $key;
		$oidIndex =~ s/$oid.//i ;
		$data->{$oidIndex} = $result->{$key};
	}
	return $data;
}

sub getData {
	my($session, @oids) = @_;
		
	my $result = $session->get_request( -varbindlist => \@oids );

	if ( $session->error() ne "" ) {
		my $error = $session->error();
		dbg("SNMP ERROR: $error");
		return undef;
	}
				
	return $result;
}

sub ifStatus {
	my $statusNumber = shift;
	
	return 'up' if $statusNumber == 1;
	return 'down' if $statusNumber == 2;
	return 'testing' if $statusNumber == 3;
	return 'dormant' if $statusNumber == 5;
	return 'notPresent' if $statusNumber == 6;
	return 'lowerLayerDown' if $statusNumber == 7;
	
	# 4 is unknown.
	return 'unknown';
}	

