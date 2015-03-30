#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# To make sense of Cisco VLAN Bridge information.

package ciscoMacTable;
our $VERSION = "1.0.0";

use strict;

use func;												# for the conf table extras
use NMIS;
use Data::Dumper;

use Net::SNMP;									# for the fixme removable local snmp session stuff

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $LNT = loadLocalNodeTable();
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	my $status = {
		'1' => 'other',
		'2' => 'invalid',
		'3' => 'learned',
		'4' => 'self',
		'5' => 'mgmt',
	};

	return (0,undef) if (ref($NI->{vtpVlan}) ne "HASH");
	
	#dot1dBase
	#vtpVlan
	
	info("Working on $node ciscoMacTable");

	my $changesweremade = 0;

	my $max_repetitions = $LNT->{$node}{max_repetitions} || $C->{snmp_max_repetitions};
	
	
	for my $key (keys %{$NI->{vtpVlan}})
	{
		my $entry = $NI->{vtpVlan}->{$key};
	
		# get the VLAN ID Number from the index
		if ( my @parts = split(/\./,$entry->{index}) ) {
			shift(@parts); # dummy
			$entry->{vtpVlanIndex} = shift(@parts);
			$changesweremade = 1;
		}
				
		# Get the devices ifDescr and give it a link.
		my $ifIndex = $entry->{vtpVlanIfIndex};				
		if ( defined $IF->{$ifIndex}{ifDescr} ) {
			$changesweremade = 1;
			$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
			$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifIndex&node=$node";
			$entry->{ifDescr_id} = "node_view_$node";
		}
		
		# Get the connected devices if the VLAN is operational
		if ( $entry->{vtpVlanState} eq "operational" ) {
			#The community string is 
			my $community = "$LNT->{$node}{community}\@$entry->{vtpVlanIndex}";
			my $session = mysnmpsession( $LNT->{$node}{host}, $community, $LNT->{$node}{version}, $LNT->{$node}{port}, $C);

			my $basePort = 0;
			my $baseIndex;
			my $snmpBaseIndex;
			my $dot1dBasePortIfIndex = "1.3.6.1.2.1.17.1.4.1.2"; #dot1dTpFdbStatus
			if ( $snmpBaseIndex = mygettable($session,$dot1dBasePortIfIndex,$max_repetitions) ) {
				$basePort = 1;
				foreach my $key (keys %$snmpBaseIndex ) {
					my $baseKey = $key;
					$baseKey =~ s/1.3.6.1.2.1.17.1.4.1.2\.//;
					$baseIndex->{$baseKey} = $snmpBaseIndex->{$key};
				}
				#print Dumper $baseIndex;
			}
			
			my $addresses;
			my $ports;
			my $addressStatus;

			my $gotAddresses = 0;
			my $dot1dTpFdbAddress = "1.3.6.1.2.1.17.4.3.1.1"; #dot1dTpFdbAddress
			if ( $addresses = mygettable($session,$dot1dTpFdbAddress,$max_repetitions) ) {
				$gotAddresses = 1;
			}

			my $gotPorts = 0;
			my $dot1dTpFdbPort = "1.3.6.1.2.1.17.4.3.1.2"; #dot1dTpFdbPort
			if ( $ports = mygettable($session,$dot1dTpFdbPort,$max_repetitions) ) {
				$gotPorts = 1;
			}
			
			my $gotStatus = 0;
			my $dot1dTpFdbStatus = "1.3.6.1.2.1.17.4.3.1.3"; #dot1dTpFdbStatus
			if ( $addressStatus = mygettable($session,$dot1dTpFdbStatus,$max_repetitions) ) {
				$gotStatus = 1;
			}			

			
			if ( $gotAddresses and $gotPorts ) {
				$changesweremade = 1;
				#print Dumper $addresses;
				
				#print Dumper $ports;

				#print Dumper $addressStatus;
				
				foreach my $key (keys %$addresses) {
					#;
					#my $macAddress = $key;					
					#$macAddress =~ s/1\.3\.6\.1\.2\.1\.17\.4\.3\.1\.1\.//;
					my $macAddress = beautify_physaddress($addresses->{$key});
										
					# got to use a different OID for the different queries.
					my $portKey = $key;
					my $statusKey = $key;
					$portKey =~ s/17.4.3.1.1/17.4.3.1.2/;
					$statusKey =~ s/17.4.3.1.1/17.4.3.1.3/;

					$NI->{macTable}->{$macAddress}{dot1dTpFdbAddress} = $macAddress;					
					$NI->{macTable}->{$macAddress}{dot1dTpFdbPort} = $ports->{$portKey};
					$NI->{macTable}->{$macAddress}{dot1dTpFdbStatus} = $status->{$addressStatus->{$statusKey}};
					$NI->{macTable}->{$macAddress}{vlan} = $entry->{vtpVlanIndex};
					$NI->{macTable}->{$macAddress}{updated} = time();
					$NI->{macTable}->{$macAddress}{updateDate} = returnDateStamp();
					
					if ( exists $ports->{$portKey} ) {
						#my $addressIfIndex = $NI->{dot1dBase}->{$ports->{$portKey}}{dot1dBasePortIfIndex};
						my $addressIfIndex = $baseIndex->{$ports->{$portKey}};
						$NI->{macTable}->{$macAddress}{ifDescr} = $IF->{$addressIfIndex}{ifDescr};
						$NI->{macTable}->{$macAddress}{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$addressIfIndex&node=$node";
						$NI->{macTable}->{$macAddress}{ifDescr_id} = "node_view_$node";
					}
				
					#dot1dTpFdbAddress
					#dot1dTpFdbPort
					#dot1dTpFdbStatus
					#vlan
					#status					
					
				}
			}			
		}

	}
	return ($changesweremade,undef); # report if we changed anything
}

sub mysnmpsession {
	my $node = shift;
	my $community = shift;
	my $version = shift;
	my $port = shift;
	my $C = shift;

	my ($session, $error) = Net::SNMP->session(                   
		-hostname => $node,                  
		-community => $community,                
		-version	=> $version,
		-timeout  => $C->{snmp_timeout},                  
		-port => $port
	);  

	if (!defined($session)) {       
		logMsg("ERROR ($node) SNMP Session Error: $error");
		$session = undef;
	}
	
	if ( $session ) {
		# lets test the session!
		my $oid = "1.3.6.1.2.1.1.2.0";	
		my $result = mysnmpget($session,$oid);
		if ( $result->{$oid} =~ /^SNMP ERROR/ ) {	
			logMsg("ERROR ($node) SNMP Session Error, bad host or community wrong");
			$session = undef;
		}
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

sub mygettable {                                                                                         
	my $session = shift;
	my $oid = shift;
	my $max_repetitions = shift;		

	my $result;
	if ( $max_repetitions ) {
		$result = $session->get_table( -baseoid => $oid, -maxrepetitions => $max_repetitions );
	}
	else {
		$result = $session->get_table( -baseoid => $oid );
	}
                                                                                                       
	my $cnt = scalar keys %{$result};                                                                    
	dbg("result: $cnt values for table $oid",2);                                                        
	return $result;                                                                                      
}                                                                                                      

1;