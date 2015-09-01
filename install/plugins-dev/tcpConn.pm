# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs 
# into a more human-friendly form
package tcpConn;
our $VERSION = "1.0.0";

use strict;

use func;												# for the conf table extras
use NMIS;
use Data::Dumper;

use Net::SNMP;									# for the fixme removable local snmp session stuff

sub update_plugin_monkey
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	return (0,undef) if (ref($NI->{tcpConn}) ne "HASH");
	my $NC = $S->ndcfg;
	
	info("Working on $node tcpConn");

	my $changesweremade = 0;

	for my $key (keys %{$NI->{dot1qTpFdb}})
	{
		my $entry = $NI->{dot1qTpFdb}->{$key};
		my $ifIndex = $entry->{dot1qTpFdbPort};
				
		if ( defined $IF->{$ifIndex}{ifDescr} ) {
			$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
			$changesweremade = 1;
		}
		
		my @octets;
		if ( @octets = split(/\./,$entry->{index}) ) {
			$entry->{vlan} = shift(@octets);
			$entry->{dot1qTpFdbAddress} = sprintf("%lx:%lx:%lx:%lx:%lx:%lx", @octets);
			$changesweremade = 1;
		}		
	}
	return ($changesweremade,undef); # report if we changed anything
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	my $changesweremade = 0;
	
	my $connState = {
		'1' => 'closed',
		'2' => 'listen',
		'3' => 'synSent',
		'4' => 'synReceived',
		'5' => 'established',
		'6' => 'finWait1',
		'7' => 'finWait2',
		'8' => 'closeWait',
		'9' => 'lastAck',
		'10' => 'closing',
		'11' => 'timeWait',
		'12' => 'deleteTCB'
	};

	my $addressType = {
		'0' => 'unknown',
		'1' => 'ipv4',
		'2' => 'ipv6',
		'3' => 'ipv4z',
		'4' => 'ipv6z',
		'16' => 'dns',
	};

	if (ref($NI->{tcpConn}) eq "HASH" or ref($NI->{tcpConnection}) eq "HASH") {
		
		if (ref($NI->{tcpConn}) eq "HASH" and $NI->{system}{nodedown} ne "true") {
			
			my $NC = $S->ndcfg;
			my $LNT = loadLocalNodeTable();
			
			dbg("SNMP tcpConnState for $node $LNT->{$node}{version}");
		
			my $session = mysnmpsession( $LNT->{$node}{host}, $LNT->{$node}{community}, $LNT->{$node}{version}, $LNT->{$node}{port}, $C);
			if (!$session)
			{
				return (2,"Could not open SNMP session to node $node");
			}           
		
			#tcpConnLocalAddress 
			#tcpConnLocalPort    
			#tcpConnRemAddress   
		  #tcpConnRemPort
		
		  #tcpConnState
	
	    #"192.168.1.42.3306.192.168.1.7.47883" : {
	    #   "tcpConnLocalAddress" : "192.168.1.42",
	    #   "tcpConnRemPort" : 47883,
	    #   "index" : "192.168.1.42.3306.192.168.1.7.47883",
	    #   "tcpConnLocalPort" : 3306,
	    #   "tcpConnState" : "established",
	    #   "tcpConnRemAddress" : "192.168.1.7"
	    #},
		
			my $oid = "1.3.6.1.2.1.6.13.1.1";
			
			if ( my $tcpConn = mygettable($session,$oid) ) {
			
				### OK we have data, lets get rid of the old one.
				delete $NI->{tcpConn};
				
				my $date = returnDateStamp();
				foreach my $key (keys %$tcpConn) {
					my $tcpKey = $key;
					$tcpKey =~ s/$oid\.//;
					$NI->{tcpConn}->{$tcpKey}{tcpConnState} = $connState->{$tcpConn->{$key}};
					if ( $tcpKey =~ /(\d+\.\d+\.\d+\.\d+)\.(\d+)\.(\d+\.\d+\.\d+\.\d+)\.(\d+)/ ) {
						$NI->{tcpConn}->{$tcpKey}{tcpConnLocalAddress} = $1;
						$NI->{tcpConn}->{$tcpKey}{tcpConnLocalPort} = $2;
						$NI->{tcpConn}->{$tcpKey}{tcpConnRemAddress} = $3;
						$NI->{tcpConn}->{$tcpKey}{tcpConnRemPort} = $4;
						$NI->{tcpConn}->{$tcpKey}{date} = $date;
					}	
					$changesweremade = 1;
				}
			}
		}
		
		if (ref($NI->{tcpConnection}) eq "HASH" and $NI->{system}{nodedown} ne "true") {
			my $NC = $S->ndcfg;
			my $LNT = loadLocalNodeTable();
			
			dbg("SNMP tcpConnState for $node $LNT->{$node}{version}");
		
			my $session = mysnmpsession( $LNT->{$node}{host}, $LNT->{$node}{community}, $LNT->{$node}{version}, $LNT->{$node}{port}, $C);
			if (!$session)
			{
				return (2,"Could not open SNMP session to node $node");
			}       
			
	    #  "1.4.192.168.1.42.3306.1.4.192.168.1.7.47883" : {
	    #     "tcpConnectionState" : "established",
	    #     "index" : "1.4.192.168.1.42.3306.1.4.192.168.1.7.47883"
	    #  },
      #"2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.80.2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.34089" : {
      #   "tcpConnectionState" : "timeWait",
      #   "index" : "2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.80.2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.34089"
      #},
			    
			my $oid = "1.3.6.1.2.1.6.19.1.7";
			
			if ( my $tcpConn = mygettable($session,$oid) ) {
			
				### OK we have data, lets get rid of the old one.
				delete $NI->{tcpConnection};
				
				my $date = returnDateStamp();
				foreach my $key (keys %$tcpConn) {
					my $tcpKey = $key;
					$tcpKey =~ s/$oid\.//;
					$NI->{tcpConnection}->{$tcpKey}{tcpConnectionState} = $connState->{$tcpConn->{$key}};
					if ( $tcpKey =~ /1\.4\.(\d+\.\d+\.\d+\.\d+)\.(\d+)\.1\.4\.(\d+\.\d+\.\d+\.\d+)\.(\d+)$/ ) {
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionLocalAddress} = $1;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionLocalPort} = $2;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionRemAddress} = $3;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionRemPort} = $4;
						$NI->{tcpConnection}->{$tcpKey}{date} = $date;
					}	
					elsif ( $tcpKey =~ /2\.16\.([\d+\.]+)\.(\d+)\.2\.16\.([\d+\.]+)\.(\d+)$/ ) {
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionLocalAddress} = $1;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionLocalPort} = $2;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionRemAddress} = $3;
						$NI->{tcpConnection}->{$tcpKey}{tcpConnectionRemPort} = $4;
						$NI->{tcpConnection}->{$tcpKey}{date} = $date;
					}	
					$changesweremade = 1;
				}
			}
		
		}
	}
	else {	
		return (0,undef) ;
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

	my $result = $session->get_table( -baseoid => $oid );                                         
                                                                                                       
	my $cnt = scalar keys %{$result};                                                                    
	dbg("result: $cnt values for table $oid",1);                                                        
	return $result;                                                                                      
}                                                                                                      

1;
