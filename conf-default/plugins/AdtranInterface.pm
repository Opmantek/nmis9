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
# A small update plugin for discovering interfaces on Adtran-TA5000 devices
# which requires custom snmp accesses
package AdtranInterface;
our $VERSION = "2.0.0";
use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;						# for snmp-related access

my $interestingInterfaces = qr/ten-gigabit-ethernet|^muxponder-highspeed/;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

	my $intfData = undef;
	my $intfInfo = undef;
	my $interface_max_number = $C->{interface_max_number} || 5000;
	$NG->log->debug("Max Interfaces are: '$interface_max_number'");


	my $NI = $S->nmisng_node;
	my $nodeobj = $NG->node(name => $node);
	my $NC = $nodeobj->configuration;
	my $catchall = $S->inventory( concept => 'catchall' )->{_data};

	# This plugin deals only with this specific device type, and only ones with snmp enabled and working
	# and finally only if the number of interfaces is greater than the limit, otherwise the normal
	# discovery will populate all interfaces normally.
	if ( $catchall->{nodeModel} !~ /Adtran/ or !NMISNG::Util::getbool($catchall->{collect}))
	{
		$NG->log->info("Max Interfaces are: '$interface_max_number'");
		$NG->log->info("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
		$NG->log->info("Node '$node', has $catchall->{ifNumber} interfaces.");
		$NG->log->info("Node '$node', Model '$catchall->{nodeModel}' does not qualify for this plugin.");
		return (1,undef);
	}
	else
	{
		$NG->log->info("Running AdtranInterface plugin for Node '$node', Model '$catchall->{nodeModel}'.");
	}

	# load any nodeconf overrides for this node
	my $overrides = $nodeobj->overrides;

	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};

	# Get the SNMP Session going.
	my %nodeconfig = %{$S->nmisng_node->configuration};

	# nmisng::snmp doesn't fall back to global config
	my $max_repetitions = $nodeconfig{max_repetitions} || $C->{snmp_max_repetitions};

	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		$NG->log->error("Could not open SNMP session to node $node: ".$snmp->error);
		undef $snmp;
		return ( error => "Could not open SNMP session to node $node: ".$snmp->error);
	}
	if (!$snmp->testsession)
	{
		$NG->log->warn("Could not retrieve SNMP vars from node $node: ".$snmp->error);
		return ( error => "Could not retrieve SNMP vars from node $node: ".$snmp->error);
	}
	
	my @ifIndexNum = ();
	my $intfTotal = 0;
	my $intfCollect = 0; # reset counters

	# do a walk to get the indexes which we know are OK.
	#ifName 1.3.6.1.2.1.31.1.1.1.1
	my $ifDescr = "1.3.6.1.2.1.2.2.1.2";

	$NG->log->info("getting a list of names using ifDescr: $ifDescr");

	my $changesweremade = 0;

	my $IFT = NMISNG::Util::loadTable(dir => "conf", name => "ifTypes", conf => $C);

	my $names;
	if ( $names = $snmp->getindex($ifDescr,$max_repetitions) )
	{
		foreach my $key (keys %$names) 
		{
			if ( $names->{$key} =~ /$interestingInterfaces/ ) {
				push(@ifIndexNum,$key);
				$intfTotal++;				
			}
		}
		$NG->log->info("Retrieved $intfTotal interesting indices from SNMP.");
	}

	if ($snmp->error)
	{
		$NG->log->error("Could not retrieve SNMP indices from node '$node': ".$snmp->error);
		return ( error => "Could not retrieve SNMP indices from node '$node': ".$snmp->error);
	}

	my $nameDump = Dumper $names;
	$NG->log->debug($nameDump);

	my $ifTypeOid = "1.3.6.1.2.1.2.2.1.3";
	my $ifSpeedOid = "1.3.6.1.2.1.2.2.1.5";
	my $ifAdminStatusOid = "1.3.6.1.2.1.2.2.1.7";
	my $ifOperStatusOid = "1.3.6.1.2.1.2.2.1.8";

	$intfTotal = 0;
	$intfInfo->{index}         = "Index";
	$intfInfo->{interface}     = "Interface Name";
	$intfInfo->{ifIndex}       = "Interface Index";
	$intfInfo->{ifName}        = "Interface Internal Name";
	$intfInfo->{Description}   = "Interface Description";
	$intfInfo->{ifDesc}        = "Interface Internal Description";
	$intfInfo->{ifType}        = "Interface Type";
	$intfInfo->{ifSpeed}       = "Interface Speed";
	$intfInfo->{ifSpeedIn}     = "Interface Speed In";
	$intfInfo->{ifSpeedOut}    = "Interface Speed Out";
	$intfInfo->{ifAdminStatus} = "Interface Administrative State";
	$intfInfo->{ifOperStatus}  = "Interface Operational State";
	$intfInfo->{setlimits}     = "Interface Set Limnits";
	$intfInfo->{collect}       = "Interface Collection Status";
	$intfInfo->{event}         = "Interface Event Status";
	$intfInfo->{threshold}     = "Interface Threshold Status";

	# We build the data first to capture duplicate names and other issues
	# we need to compensate for along the way.
	foreach my $index (@ifIndexNum) 
	{
		$intfTotal++;				
		my @oids = (
			"$ifTypeOid.$index",
			"$ifSpeedOid.$index",
			"$ifAdminStatusOid.$index",
			"$ifOperStatusOid.$index",
		);
		
		# Store them straight into the results
		my $snmpData = $snmp->get(@oids);
		if ($snmp->error)
		{
			$NG->log->warn("Got an empty Interface, skipping.");
			next;
		}
		if (ref($snmpData) ne "HASH")
		{
			$NG->log->warn("Failed to retrieve SNMP variables for index $index.");
			next;
		}

		my $ifDescr           = $names->{$index};		
		my $ifName            = NMISNG::Util::convertIfName($ifDescr);
		my $ifType            = $IFT->{$snmpData->{"$ifTypeOid.$index"}}{ifType};
		my $ifSpeed           = $snmpData->{"$ifSpeedOid.$index"};
		my $ifAdminStatus     = ifStatus($snmpData->{"$ifAdminStatusOid.$index"});
		my $ifOperStatus      = ifStatus($snmpData->{"$ifOperStatusOid.$index"});
		my $setlimits         = $NI->{interface}->{$index}->{setlimits} // "normal";

		# ifDescr must always be filled
		$ifDescr = $index if ($ifDescr eq "");

		$ifSpeed = 10000000000 if ( $ifDescr =~ /ten-gigabit-ethernet/ );
		$ifSpeed = 10000000000 if ( $ifSpeed == 4294967295 );
				
		$NG->log->debug("SNMP processing '$node' Description: '$ifDescr' Interface Speed=$ifSpeed.");
				
		$NG->log->debug("Interface Name          = $ifName");
		$NG->log->debug("Interface Index         = $index");
		$NG->log->debug("Interface Description   = $ifDescr");
		$NG->log->debug("Interface Type          = $ifType");
		$NG->log->debug("Interface Speed         = $ifSpeed");
		$NG->log->debug("Interface Admin Status  = $ifAdminStatus");
		$NG->log->debug("Interface Oper Status   = $ifOperStatus");
		$NG->log->debug("Interface Limits        = $setlimits");
		$intfData->{$index}->{index}             = $index;
		$intfData->{$index}->{ifIndex}           = $index;
		$intfData->{$index}->{interface}         = NMISNG::Util::convertIfName($ifDescr);
		$intfData->{$index}->{ifName}            = $ifName;
		$intfData->{$index}->{Description}       = '';
		$intfData->{$index}->{ifDescr}           = $ifDescr;
		$intfData->{$index}->{ifType}            = $ifType;
		$intfData->{$index}->{ifSpeed}           = $ifSpeed;
		$intfData->{$index}->{ifSpeedIn}         = $ifSpeed;
		$intfData->{$index}->{ifSpeedOut}        = $ifSpeed;
		$intfData->{$index}->{ifAdminStatus}     = $ifAdminStatus;
		$intfData->{$index}->{ifOperStatus}      = $ifOperStatus;
		$intfData->{$index}->{setlimits}         = $setlimits;
		$intfData->{$index}->{collect}           = $ifAdminStatus eq "up" ? "true": "false";
		$intfData->{$index}->{event}             = $ifAdminStatus eq "up" ? "true": "false";
		$intfData->{$index}->{threshold}         = $ifAdminStatus eq "up" ? "true": "false";

		# check for duplicated ifDescr
		foreach my $i (keys %{$intfData}) {
			if ($index ne $i and $intfData->{$index}->{ifDescr} eq $intfData->{$i}->{ifDescr}) {
				$intfData->{$index}->{ifDescr} = "$ifDescr-$index"; # add index to this description.
				$intfData->{$i}->{ifDescr} = "$ifDescr-$i";         # and the duplicte one.
				$NG->log->debug("Index added to duplicate Interface Description '$ifDescr'");
			}
		}
		my $thisintfover = $overrides->{$ifDescr} || {};

		### add in anything we find from nodeConf - allows manual updating of interface variables
		### warning - will overwrite what we got from the device - be warned !!!
		if ($thisintfover->{Description} ne '') {
			$intfData->{$index}->{nc_Description} = $intfData->{$index}->{Description}; # save
			$intfData->{$index}->{Description} = $thisintfover->{Description};
			$NG->log->debug("Manual update of Description by nodeConf");
		}
		
		if ($thisintfover->{ifSpeed} ne '') {
			$intfData->{$index}->{nc_ifSpeed} = $intfData->{$index}->{ifSpeed}; # save
			$intfData->{$index}->{ifSpeed} = $thisintfover->{ifSpeed};
			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$NG->log->info("Manual update of ifSpeed by nodeConf");
		}
	
		if ($thisintfover->{ifSpeedIn} ne '') {
			$intfData->{$index}->{nc_ifSpeedIn} = $intfData->{$index}->{ifSpeedIn}; # save
			$intfData->{$index}->{ifSpeedIn} = $thisintfover->{ifSpeedIn};
			
			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$NG->log->info("Manual update of ifSpeedIn by nodeConf");
		}
	
		if ($thisintfover->{ifSpeedOut} ne '') {
			$intfData->{$index}->{nc_ifSpeedOut} = $intfData->{$index}->{ifSpeedOut}; # save
			$intfData->{$index}->{ifSpeedOut} = $thisintfover->{ifSpeedOut};

			### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
			$NG->log->info("Manual update of ifSpeedOut by nodeConf");
		}
		
		# convert interface name
		$intfData->{$index}->{interface} = NMISNG::Util::convertIfName($intfData->{$index}->{ifDescr});
		$intfData->{$index}->{ifIndex} = $index;
		
		### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
		# modify by node Config ?
		if ($thisintfover->{collect} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}->{ifDescr}) {
			$intfData->{$index}->{nc_collect} = $intfData->{$index}->{collect};
			$intfData->{$index}->{collect} = $thisintfover->{collect};
			$NG->log->debug("Manual update of Collect by nodeConf");
			if ($intfData->{$index}->{collect} eq 'false') {
				$intfData->{$index}->{nocollect} = "Manual update by nodeConf";
			}
		}
		if ($thisintfover->{event} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}->{ifDescr}) {
			$intfData->{$index}->{nc_event} = $intfData->{$index}->{event};
			$intfData->{$index}->{event} = $thisintfover->{event};
			$intfData->{$index}->{noevent} = "Manual update by nodeConf" if $intfData->{$index}{event} eq 'false'; # reason
			$NG->log->debug("Manual update of Event by nodeConf");
		}
		if ($thisintfover->{threshold} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}{ifDescr}) {
			$intfData->{$index}{nc_threshold} = $intfData->{$index}{threshold};
			$intfData->{$index}{threshold} = $thisintfover->{threshold};
			$intfData->{$index}{nothreshold} = "Manual update by nodeConf" if $intfData->{$index}{threshold} eq 'false'; # reason
			$NG->log->debug("Manual update of Threshold by nodeConf");
		}
		
		# interface now up or down, check and set or clear outstanding event.
		if ( $intfData->{$index}{collect} eq 'true'
				 and $intfData->{$index}{ifAdminStatus} =~ /up|ok/ 
				 and $intfData->{$index}{ifOperStatus} !~ /up|ok|dormant/ 
				) {
			if ($intfData->{$index}{event} eq 'true') {
				Compat::NMIS::notify(sys=>$S,event=>"Interface Down",element=>$intfData->{$index}{ifDescr},details=>$intfData->{$index}{Description});
			}
		} 
		else 
		{
			Compat::NMIS::checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$intfData->{$index}{ifDescr},details=>$intfData->{$index}{Description});
		}
		
		$intfData->{$index}{threshold} = $intfData->{$index}{collect};
		
		# number of interfaces collected with collect and event on
		$intfCollect++ if $intfData->{$index}{collect} eq 'true' && $intfData->{$index}{event} eq 'true';
		
		# save values only if all interfaces are updated
		$NI->{system}{intfTotal} = $intfTotal;
		$NI->{system}{intfCollect} = $intfCollect;
		
		if ($intfData->{$index}{collect} eq "true") {
			$NG->log->debug("ifIndex $index, collect=true");
		}
	}

	# Now we save eachInterface in our node. We do this as a separate 
	# step because the above might alter names because of duplication.
	my $intDump = Dumper $intfData;
	$NG->log->debug("intfData = ".$intDump);
	foreach my $index (keys(%$intfData))
	{
		$NG->log->debug("Index = ".$index);
		# Now get-or-create an inventory object for this new concept
		#
		my $intfSubData = $intfData->{$index};
		$intDump = Dumper $intfSubData;
		$NG->log->debug("intfSubData = ".$intDump);
		my $path_keys =  ['index'];
		my $path = $nodeobj->inventory_path( concept => 'interface', path_keys => $path_keys, data => $intfSubData );
		my ($inventory, $error) =  $nodeobj->inventory(
			create => 1,				# if not present yet
			concept => "interface",
			data => $intfSubData,
			path_keys => $path_keys,
			path => $path );
	
		if(!$inventory or $error)
		{
			$NG->log->error("Failed to get inventory for interface index $index; Error: $error");
			next;								# not much we can do in this case...
		}
		$inventory->historic(0);
		$inventory->enabled(1);
		$inventory->description( $intfSubData->{ifDescr} );

		# set which columns should be displayed
		$inventory->data_info(
			subconcept => "interface",
			enabled => 1,
			display_keys => $intfInfo
		);

		$NG->log->info("Interface description is '$intfSubData->{ifDescr}'");
		# Get the RRD file name to use for storage.
		my $dbname = $S->makeRRDname(graphtype => "interface",
									index      => $index,
									inventory  => $intfSubData,
									extras     => $intfSubData,
									relative   => 1);
		$NG->log->debug("Collect Adtran data info check storage interface, dbname '$dbname'.");
		
		# Set the storage name into the inventory model
		$inventory->set_subconcept_type_storage(type => "rrd",
												subconcept => "interface",
												data => $dbname) if ($dbname);
		my $desiredlimit = $intfData->{$index}{setlimits};
		# $NG->log->info("Desiredlimit: $desiredlimit" );
		# $NG->log->info("ifSpeed: " . $intfData->{$index}{ifSpeed});
		# $NG->log->info("collect: " . $intfData->{$index}{collect});
		# no limit or dud limit or dud speed or non-collected interface?
		if ($desiredlimit && $desiredlimit =~ /^(normal|strict|off)$/
				&& $intfData->{$index}{ifSpeed}
				&& NMISNG::Util::getbool($intfData->{$index}{collect}))
		{
			$NG->log->info("performing rrd speed limit tuning for $ifDescr, limit enforcement: $desiredlimit, interface speed is ".NMISNG::Util::convertIfSpeed($intfData->{$index}{ifSpeed})." ($intfData->{$index}{ifSpeed})");

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
			my $maxbytes = 	$desiredlimit eq "off"? "U": $desiredlimit eq "normal"
				? int($intfData->{$index}{ifSpeed}/4)
				: int($intfData->{$index}{ifSpeed}/8);
			my $maxpkts = $maxbytes eq "U" # this is a dodgy heuristic
				? "U"
				: int($maxbytes/50);
			for (
				["interface", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)/],
				[   "pkts", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/ ],
				[   "pkts_hc", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/ ],
			)
			{
				my ( $datatype, $dsregex ) = @$_;
	
				# rrd file exists and readable?
				if ( -r ( my $rrdfile = $S->makeRRDname( graphtype => $datatype,
														 index => $index,
														 inventory => $inventory,
														 conf => $NC ) ) )
				{
					my $fileinfo = RRDs::info($rrdfile);
					for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
					{
						# only touch relevant and known datasets
						next if ( $matching !~ /($dsregex)/ );
						my $dsname = $1;
	
						my $curval = $fileinfo->{$matching};
						$curval = "U" if ( !defined $curval or $curval eq "" );
	
						# the pkts, discards, errors DS are packet based; the octets ones are bytes
						my $desiredval = $dsname =~ /octets/i ? $maxbytes : $maxpkts;
	
						if ( $curval ne $desiredval )
						{
							$NG->log->debug2( "rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit");
							RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
						}
						else
						{
							$NG->log->debug2("rrd section $datatype, ds $dsname, current limit $curval is correct");
						}
					}
				}
			}
		}

		# The above has added data to the inventory, that we now save.
		my ( $op, $subError ) = $inventory->save();
		$NG->log->debug2( "saved ".join(',', @$path)." op: $op");
		if ($subError)
		{
			$NG->log->error("Failed to save inventory for Interface '$index': $subError");
		}
		else
		{
			$changesweremade = 1;
		}
	}
	if ($changesweremade)
	{
		$NG->log->info("$intfTotal Interfaces were added.");
	}
	else
	{
		$NG->log->info("No Interfaces were added.");
	}

	return ($changesweremade,undef);							# happy, and changes were made so save view and nodes file
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
