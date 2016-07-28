# a small update plugin for discovering interfaces on FutureSoftware devices
# which requires custom snmp accesses
package FutureSoftware;
our $VERSION = "1.1.0";

use strict;

use func;												# for loading extra tables
use NMIS;												# iftypestable
use snmp 1.1.0;									# for snmp-related access

sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;

	# this plugin deals only with Future Software devices, and only ones with snmp enabled and working
	return (0,undef) if ( $NI->{system}{nodeModel} ne "FutureSoftware"
												or !getbool($NI->{system}->{collect}));

	my $IFT = loadifTypesTable();
	my $NC = $S->ndcfg;
	my $V = $S->view;

	my $intfCollect;
	my $intfTotal;

	# load any nodeconf overrides
	my ($errmsg, $override) = get_nodeconf(node => $node)
			if (has_nodeconf(node => $node));
	logMsg("ERROR $errmsg") if $errmsg;
	$override ||= {};

	# Get the SNMP Session going.
	my $snmp = snmp->new(name => $node);
	return (2,"Could not open SNMP session to node $node: ".$snmp->error)
			if (!$snmp->open(config => $NC->{node}, host_addr => $NI->{system}->{host_addr}));
	
	return (2, "Could not retrieve SNMP vars from node $node: ".$snmp->error)
			if (!$snmp->testsession);
	
	my $ifIndexOid = "1.3.6.1.2.1.2.2.1.1";
	my $ifDescrOid = "1.3.6.1.2.1.2.2.1.2";
	my $ifTypeOid = "1.3.6.1.2.1.2.2.1.3";
	my $ifSpeedOid = "1.3.6.1.2.1.2.2.1.5";
	my $ifAdminStatusOid = "1.3.6.1.2.1.2.2.1.7";
	my $ifOperStatusOid = "1.3.6.1.2.1.2.2.1.8";
	my $ifLastChangeOid = "1.3.6.1.2.1.2.2.1.9";
	my $ifAliasOid = "1.3.6.1.2.1.31.1.1.1.18";
	my $ifHighSpeedOid = "1.3.6.1.2.1.31.1.1.1.15";
	
	# get the ifIndexes - Futuresoftware does NOT expose ifindex, so this has to go via ifdescr
	my $intftable = $snmp->getindex($ifDescrOid, 
																	$NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions});
	return (2, "Failed to retrieve SNMP ifindexes: ".$snmp->error) 
			if (ref($intftable) ne "HASH" or !keys %$intftable);
	
	my @ifIndexNum = sort { $a <=> $b } keys %$intftable;
	dbg("Got some ifIndexes: @ifIndexNum") if @ifIndexNum;
				
	foreach my $index (@ifIndexNum) 
	{
		dbg("Working on $index");
		# Declare the required VARS
		my @oids = (
			"$ifDescrOid.$index",
			"$ifTypeOid.$index",
			"$ifSpeedOid.$index",
			"$ifAdminStatusOid.$index",
			"$ifOperStatusOid.$index",
			"$ifLastChangeOid.$index",

			"$ifAliasOid.$index",
			"$ifHighSpeedOid.$index",
		);
		
		# Store them straight into the results
		my $snmpData = $snmp->get(@oids);
		return (2, "Failed to retrieve SNMP variables: ".$snmp->error) 
				if (ref($snmpData) ne "HASH");

		my $ifDescr = $snmpData->{"$ifDescrOid.$index"};
		my $ifType = $IFT->{$snmpData->{"$ifTypeOid.$index"}}{ifType};
		my $ifSpeed = $snmpData->{"$ifSpeedOid.$index"};
		my $ifAdminStatus = ifStatus($snmpData->{"$ifAdminStatusOid.$index"});
		my $ifOperStatus = ifStatus($snmpData->{"$ifOperStatusOid.$index"});
		my $ifLastChange = $snmpData->{"$ifLastChangeOid.$index"};
		my $ifAlias = $snmpData->{"$ifAliasOid.$index"} || undef;
		my $ifHighSpeed = $snmpData->{"$ifHighSpeedOid.$index"} || undef;
		
		my $Description = $ifAlias;
		
		dbg("SNMP $node $ifDescr $Description, index=$index, ifType=$ifType, ifSpeed=$ifSpeed, ifAdminStatus=$ifAdminStatus, ifOperStatus=$ifOperStatus");
		
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
		my $thisintfover = $override->{$ifDescr} || {};
		
		### add in anything we find from nodeConf - allows manual updating of interface variables
		### warning - will overwrite what we got from the device - be warned !!!
		if ($thisintfover->{Description} ne '') {
			$S->{info}{interface}{$index}{nc_Description} = $S->{info}{interface}{$index}{Description}; # save
			$S->{info}{interface}{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $thisintfover->{Description};
			dbg("Manual update of Description by nodeConf");
		}
		else {
			$V->{interface}{"${index}_Description_value"} = $S->{info}{interface}{$index}{Description};
		}
		
		if ($thisintfover->{ifSpeed} ne '') {
			$S->{info}{interface}{$index}{nc_ifSpeed} = $S->{info}{interface}{$index}{ifSpeed}; # save
			$S->{info}{interface}{$index}{ifSpeed} = $thisintfover->{ifSpeed};
			dbg("Manual update of ifSpeed by nodeConf");
		}
		
		$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($S->{info}{interface}{$index}{ifSpeed});
		
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

	$snmp->close;
	return (1,undef);							# happy, changes were made so save view and nodes files
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

1;
