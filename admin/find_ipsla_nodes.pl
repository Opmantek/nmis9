#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

use strict;
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use Data::Dumper;
use Net::SNMP; 

#print <<EO_TEXT;
#$0 will find nodes which are running IPSLA.
#
#EO_TEXT


# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $node = $arg{node};
my $debug = setDebug($arg{debug});

my $t = NMIS::Timing->new();
print $t->elapTime(). " Begin\n" if $debug;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();
my $rttTypes = rttTypes();
my $rttStatus = rttStatus();

foreach my $node (sort keys %$LNT) {	
	processNode($node);
}

print $t->elapTime(). " End\n" if $debug;


sub processNode {
	my $node = shift;
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
		my $gotaProbe = 0;
		
		# Get the SNMP Session going.
		my $port = $LNT->{$node}{port};
		$port = 161 if not $port;		

		if ( $NI->{system}{nodeVendor} =~ "Cisco" ) {
			print "Node $node, sysObjectName=$NI->{system}{sysObjectName} model=$NI->{system}{nodeModel}\n";
			print "$NI->{system}{sysDescr}\n";

			dbg("Getting SNMP Session to $node");
			my $session = mysnmpsession($LNT->{$node}{host},$LNT->{$node}{community},$port);
			
			if ( $session ) {
				my $rttMonApplVersionOid = "1.3.6.1.4.1.9.9.42.1.1.1";
			  my $rttMonApplResponderOid = "1.3.6.1.4.1.9.9.42.1.1.13";
	
				my @oids = (
					"$rttMonApplVersionOid.0",
					"$rttMonApplResponderOid.0",
				);
	
				my $snmpData = getData($session,@oids);
				
				my $responder = "NONE";
				$responder = "enabled" if $snmpData->{"$rttMonApplResponderOid.0"} == 1;
				$responder = "disabled" if $snmpData->{"$rttMonApplResponderOid.0"} == 2;
		
				print "  $node IPSLA version ". $snmpData->{"$rttMonApplVersionOid.0"}. "\n";
				print "  $node IPSLA responder $responder\n";
	
			  my $rttMonCtrlAdminOwnerOid = "1.3.6.1.4.1.9.9.42.1.2.1.1.2";
			  my $rttMonCtrlAdminRttTypeOid = "1.3.6.1.4.1.9.9.42.1.2.1.1.4";
			  my $rttMonCtrlAdminStatusOid = "1.3.6.1.4.1.9.9.42.1.2.1.1.9";
			  
				# get the ifIndexes
				my @rttMonCtrl = getIndexes($session,$rttMonCtrlAdminOwnerOid);

				dbg("Got some RTT Probes: @rttMonCtrl") if @rttMonCtrl;
				foreach my $index (@rttMonCtrl) {
					if ( defined $index ) {
						$gotaProbe = 1;
						# Declare the required VARS
						my @oids = (
							"$rttMonCtrlAdminOwnerOid.$index",
							"$rttMonCtrlAdminRttTypeOid.$index",
							"$rttMonCtrlAdminStatusOid.$index",
						);
						
						# Store them straight into the results
						my $snmpData = getData($session,@oids);
		
					  my $rttMonCtrlAdminOwner = $snmpData->{"$rttMonCtrlAdminOwnerOid.$index"};
					  my $rttMonCtrlAdminRttType = $snmpData->{"$rttMonCtrlAdminRttTypeOid.$index"};
					  my $rttMonCtrlAdminStatus = $snmpData->{"$rttMonCtrlAdminStatusOid.$index"};
						
						$rttMonCtrlAdminRttType = $rttTypes->{$rttMonCtrlAdminRttType};
						$rttMonCtrlAdminStatus = $rttStatus->{$rttMonCtrlAdminStatus};
						print "  $node IPSLA Probe $index Owner=$rttMonCtrlAdminOwner Type=$rttMonCtrlAdminRttType Status=$rttMonCtrlAdminStatus\n";
					}
				}
				if ( not $gotaProbe ) {
					print "  $node NO IPSLA Probes Found\n";
				}
			}
		}
	}
}

sub rttTypes {
  return {
    '1' => 'echo',
    '10' => 'dlsw',
    '11' => 'dhcp',
    '12' => 'ftp',
    '13' => 'voip',
    '14' => 'rtp',
    '15' => 'lspGroup',
    '16' => 'icmpjitter',
    '17' => 'lspPing',
    '18' => 'lspTrace',
    '19' => 'ethernetPing',
    '2' => 'pathEcho',
    '20' => 'ethernetJitter',
    '21' => 'lspPingPseudowire',
    '22' => 'video',
    '3' => 'fileIO',
    '4' => 'script',
    '5' => 'udpEcho',
    '6' => 'tcpConnect',
    '7' => 'http',
    '8' => 'dns',
    '9' => 'jitter'
  };
}

sub rttStatus {
  return {
		'1' => 'active',
		'2' => 'notInService',
		'3' => 'notReady',
		'4' => 'createAndGo',
		'5' => 'createAndWait',
		'6' => 'destroy'
  };
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
		print("ERROR ($node) SNMP Session Error: $error");
		$session = undef;
	}
	
	# lets test the session!
	my $oid = "1.3.6.1.2.1.1.2.0";	
	my $result = mysnmpget($session,$oid);
	if ( $result->{$oid} =~ /^SNMP ERROR/ ) {	
		print("ERROR ($node) SNMP Session Error, bad host or community wrong");
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
sub getIndexes {
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
		my $oidIndex = $key;
		$oidIndex =~ s/$oid.//i ;
		#print "DEBUG: $key = $result->{$key}\n";
		push(@indexes,$oidIndex) if $oidIndex;
	}
	return @indexes;
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

