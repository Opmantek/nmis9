# a small update plugin for discovering interfaces on netgear 108 and 723 devices
# which requires custom snmp accesses
package NetGearInterface;
our $VERSION = "1.0.0";
use strict;

use func;												# for the conf table extras
use NMIS;

use Net::SNMP;									# for the fixme removable local snmp session stuff

sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;

	# this plugin deals only with this specific device type, and only ones with snmp enabled and working
	return (0,undef) if ( $NI->{system}{nodeModel} ne "Netgear-Manual"
												or $NI->{system}{nodeVendor} ne "Netgear"
												or !getbool($NI->{system}->{collect}));

	my $NC = $S->ndcfg;
	my $V = $S->view;
	
	# load any nodeconf overrides for this node
	my ($errmsg, $override) = get_nodeconf(node => $node)
			if (has_nodeconf(node => $node));
	logMsg("ERROR $errmsg") if $errmsg;
	$override ||= {};

	
	# Get the SNMP Session going.
	# fixme: the local myXX functions should be replaced by $S->open, and $S->{snmp}->xx
	my $session = mysnmpsession( $NI->{system}->{host}, $NC->{node}->{community}, $NC->{node}->{port}, $C);
	if (!$session)
	{
		return (2,"Could not open SNMP session to node $node");
	}
	
	my @ifIndexNum = (1..24);
	my $intfTotal = 0;
	my $intfCollect = 0; # reset counters

	foreach my $index (@ifIndexNum) 
	{
		$intfTotal++;				
		my $ifDescr = "Port $index Gigabit Ethernet";
				
		my $prefix = "1.3.6.1.2.1.10.7.2.1.3";
		my $oid = "$prefix.$index";
		my $dot3PauseOperMode = mysnmpget($session,$oid);
				
		dbg("SNMP $node $ifDescr, dot3PauseOperMode=$dot3PauseOperMode->{$oid}");
		
		if ( $dot3PauseOperMode->{$oid} =~ /^SNMP ERROR/ ) 
		{
			logMsg("ERROR ($node) SNMP Error with $oid"); # fixme fatal?
		}
				
		$S->{info}{interface}{$index} = 
		{
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
		my $thisintfover = $override->{$ifDescr} || {};
		
		### add in anything we find from nodeConf - allows manual updating of interface variables
		### warning - will overwrite what we got from the device - be warned !!!
		if ($thisintfover->{Description} ne '') {
			$S->{info}{interface}{$index}{nc_Description} = $S->{info}{interface}{$index}{Description}; # save
			$S->{info}{interface}{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $thisintfover->{Description};
			dbg("Manual update of Description by nodeConf");
		}
		
		if ($thisintfover->{ifSpeed} ne '') {
			$S->{info}{interface}{$index}{nc_ifSpeed} = $S->{info}{interface}{$index}{ifSpeed}; # save
			$S->{info}{interface}{$index}{ifSpeed} = $V->{interface}{"${index}_ifSpeed_value"} = $thisintfover->{ifSpeed};
			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeed});
			info("Manual update of ifSpeed by nodeConf");
		}
	
		if ($thisintfover->{ifSpeedIn} ne '') {
			$S->{info}{interface}{$index}{nc_ifSpeedIn} = $S->{info}{interface}{$index}{ifSpeedIn}; # save
			$S->{info}{interface}{$index}{ifSpeedIn} = $thisintfover->{ifSpeedIn};
			
			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$V->{interface}{"${index}_ifSpeedIn_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeedIn});
			info("Manual update of ifSpeedIn by nodeConf");
		}
	
		if ($thisintfover->{ifSpeedOut} ne '') {
			$S->{info}{interface}{$index}{nc_ifSpeedOut} = $S->{info}{interface}{$index}{ifSpeedOut}; # save
			$S->{info}{interface}{$index}{ifSpeedOut} = $thisintfover->{ifSpeedOut};

			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$V->{interface}{"${index}_ifSpeedOut_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeedOut});
			info("Manual update of ifSpeedOut by nodeConf");
		}
		
		# convert interface name
		$S->{info}{interface}{$index}{interface} = convertIfName($S->{info}{interface}{$index}{ifDescr});
		$S->{info}{interface}{$index}{ifIndex} = $index;
		
		### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
		# modify by node Config ?
		if ($thisintfover->{collect} ne '' and $thisintfover->{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
			$S->{info}{interface}{$index}{nc_collect} = $S->{info}{interface}{$index}{collect};
			$S->{info}{interface}{$index}{collect} = $thisintfover->{collect};
			dbg("Manual update of Collect by nodeConf");
			if ($S->{info}{interface}{$index}{collect} eq 'false') {
				$S->{info}{interface}{$index}{nocollect} = "Manual update by nodeConf";
			}
		}
		if ($thisintfover->{event} ne '' and $thisintfover->{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
			$S->{info}{interface}{$index}{nc_event} = $S->{info}{interface}{$index}{event};
			$S->{info}{interface}{$index}{event} = $thisintfover->{event};
			$S->{info}{interface}{$index}{noevent} = "Manual update by nodeConf" if $S->{info}{interface}{$index}{event} eq 'false'; # reason
			dbg("Manual update of Event by nodeConf");
		}
		if ($thisintfover->{threshold} ne '' and $thisintfover->{ifDescr} eq $S->{info}{interface}{$index}{ifDescr}) {
			$S->{info}{interface}{$index}{nc_threshold} = $S->{info}{interface}{$index}{threshold};
			$S->{info}{interface}{$index}{threshold} = $thisintfover->{threshold};
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
		} 
		else 
		{
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

	return (1,undef);							# happy, and changes were made so save view and nodes file
}

sub mysnmpsession {
	my $node = shift;
	my $community = shift;
	my $port = shift;
	my $C = shift;

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
