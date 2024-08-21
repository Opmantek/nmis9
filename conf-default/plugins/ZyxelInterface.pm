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
# a small update plugin for discovering interfaces on zyxel devices
# which requires custom snmp accesses
package ZyxelInterface;

our $VERSION = "2.0.0";

use strict;

use Compat::NMIS;
use NMISNG;						# get_nodeconf
use NMISNG::Util;				# for the conf table extras
use NMISNG::rrdfunc;
use Data::Dumper;
use NMISNG::Snmp;				# for snmp-related access

my $changesweremade = 0;

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
	my $catchall = $S->inventory( concept => 'catchall' )->data_live();
	my $IFT = NMISNG::Util::loadTable(dir => "conf", name => "ifTypes", conf => $C);


	my (%args) = @_;
	my ($node, $S, $C) = @args{qw(node sys config)};

	my $NI = $S->nmisng_node;

	# This plugin deals only with ZyXEL devices, and only ones with snmp enabled and working.
	if ( $catchall->{sysDescr} !~ /IES/ or $catchall->{nodeVendor} ne "ZyXEL Communications Corp."
		   	or !NMISNG::Util::getbool($catchall->{collect}))
	{
		$NG->log->debug("Max Interfaces are: '$interface_max_number'");
		$NG->log->debug("Collection status is ".NMISNG::Util::getbool($catchall->{collect}));
		$NG->log->debug("Node '$node', has $catchall->{ifNumber} interfaces.");
		$NG->log->debug("Node '$node', System Description '$catchall->{sysDescr}'.");
		$NG->log->debug("Node '$node', Vendor '$catchall->{nodeVendor}'.");
		$NG->log->debug("Node '$node', does not qualify for this plugin.");
		return (0,undef);
	}
	else
	{
		$NG->log->debug("Running ZyxelInterface plugin for Node '$node', Model '$catchall->{nodeModel}'.");
	}


	# Load any nodeconf overrides for this node
	my $overrides = $nodeobj->overrides;

	# nmisng::snmp doesn't fall back to global config
	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};

	# Get the SNMP Session going.
	my %nodeconfig = %{$S->nmisng_node->configuration};

	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		my $error = $snmp->error;
		undef $snmp;
		$NG->log->error("Could not open SNMP session to node $node: ".$error);
		return (2, "Could not open SNMP session to node $node: ".$error);
	}
	if (!$snmp->testsession)
	{
		my $error = $snmp->error;
		$snmp->close;
		$NG->log->warn("Could not retrieve SNMP vars from node $node: ".$error);
		return (2, "Could not retrieve SNMP vars from node $node: ".$error);
	}
	
	my @ifIndexNum       = ();
	my $indexTotal       = 0;
	my $intfTotal        = 0;
	my $intfCollect      = 0; # reset counters
	my $Description      = "N/A";
	my $ifDescr          = undef;
	my $ifName           = undef;
	my $ifType           = undef;
	my $ifSpeed          = undef;
	my $ifAdminStatus    = undef;
	my $ifOperStatus     = undef;
	my $ifLastChange     = undef;
	my $ifAlias          = undef;
	my $ifHighSpeed      = undef;
	my $setlimits        = undef;

	my $ifIndexOid       = "1.3.6.1.2.1.2.2.1.1";
	my $ifDescrOid       = "1.3.6.1.2.1.2.2.1.2";
	my $ifTypeOid        = "1.3.6.1.2.1.2.2.1.3";
	my $ifSpeedOid       = "1.3.6.1.2.1.2.2.1.5";
	my $ifAdminStatusOid = "1.3.6.1.2.1.2.2.1.7";
	my $ifOperStatusOid  = "1.3.6.1.2.1.2.2.1.8";
	my $ifLastChangeOid  = "1.3.6.1.2.1.2.2.1.9";
	my $ifAliasOid       = "1.3.6.1.2.1.31.1.1.1.18";
	my $ifHighSpeedOid   = "1.3.6.1.2.1.31.1.1.1.15";

	# Get the special ZyXEL names and such.
	my $subrPortNameOid = "1.3.6.1.4.1.890.1.5.13.5.8.1.1.1";
	my $subrPortTelOid  = "1.3.6.1.4.1.890.1.5.13.5.8.1.1.2";
	
	# The IES 1248 Appears to use the next MIB ID along.
	if ( $catchall->{sysDescr} =~ /1248/ )
   	{
		#"iesSeries"		"1.3.6.1.4.1.890.1.5.13"
		#ZYXEL-MIB::iesSeries.6.8.1.1.1.48 = STRING: "teresa-luisoni"
		#ZYXEL-MIB::iesSeries.6.8.1.1.2.1 = STRING: "8095380218"
		
		$subrPortNameOid = "1.3.6.1.4.1.890.1.5.13.6.8.1.1.1";
		$subrPortTelOid  = "1.3.6.1.4.1.890.1.5.13.6.8.1.1.2";
	}
	$intfInfo = {
		{index         => "Index"},
		{interface     => "Interface Name"},
		{ifIndex       => "Interface Index"},
		{ifName        => "Interface Internal Name"},
		{Description   => "Interface Description"},
		{ifDesc        => "Interface Internal Description"},
		{ifType        => "Interface Type"},
		{ifSpeed       => "Interface Speed"},
		{ifSpeedIn     => "Interface Speed In"},
		{ifSpeedOut    => "Interface Speed Out"},
		{ifAdminStatus => "Interface Administrative State"},
		{ifOperStatus  => "Interface Operational State"},
		{setlimits     => "Interface Set Limnits"},
		{collect       => "Interface Collection Status"},
		{event         => "Interface Event Status"},
		{threshold     => "Interface Threshold Status"}
	};

	# get the ifIndexes
	my $intftable = $snmp->getindex($ifIndexOid,$max_repetitions);
	if ($snmp->error or ref($intftable) ne "HASH" or !keys %$intftable)
	{
		my $error = $snmp->error;
		$snmp->close;
		return (2, "ERROR: Failed to retrieve SNMP ifindexes: ".$error);
	}
	my @ifIndexNum = sort { $a <=> $b } keys %$intftable;
	$indexTotal = @ifIndexNum;

	$NG->log->debug("Got indexTotal indices.") if @ifIndexNum;
			
	my $subrPortName = $snmp->getindex($subrPortNameOid,$max_repetitions);
	if ($snmp->error or ref($subrPortName) ne "HASH")
	{
		my $error = $snmp->error;
		$snmp->close;
		return  (2, "ERROR: Failed to retrieve subrPortName: ".$error);
	}
	
	my $subrPortTel = $snmp->getindex($subrPortTelOid,$max_repetitions);
	if ($snmp->error or ref($subrPortName) ne "HASH")
	{
		my $error = $snmp->error;
		$snmp->close;
		return  (2, "ERROR: Failed to retrieve subrPortTel: ".$error);
	}
		
	# We build the data first to capture duplicate names and other issues
	# we need to compensate for along the way.
	foreach my $index (@ifIndexNum) 
	{
		$NG->log->debug("Working on $index");
		# Declare the required VARS
		my @oids = (
			"$ifDescrOid.$index",
			"$ifTypeOid.$index",
			"$ifSpeedOid.$index",
			"$ifAdminStatusOid.$index",
			"$ifOperStatusOid.$index",
			"$ifLastChangeOid.$index",
			# These do not appear to be implemented consistently
			"$ifAliasOid.$index",
			#"$ifHighSpeedOid.$index",
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

		$Description   = $subrPortTel->{$index};
		$ifDescr       = $snmpData->{"$ifDescrOid.$index"};
		$ifName        = NMISNG::Util::convertIfName($ifDescr);
		$ifType        = $IFT->{$snmpData->{"$ifTypeOid.$index"}}{ifType};
		$ifSpeed       = $snmpData->{"$ifSpeedOid.$index"};
		$ifAdminStatus = ifStatus($snmpData->{"$ifAdminStatusOid.$index"});
		$ifOperStatus  = ifStatus($snmpData->{"$ifOperStatusOid.$index"});
		$ifLastChange  = $snmpData->{"$ifLastChangeOid.$index"};
		$ifAlias       = $snmpData->{"$ifAliasOid.$index"} || undef;
		$ifHighSpeed   = $snmpData->{"$ifHighSpeedOid.$index"} || undef;
		$setlimits     = $NI->{interface}->{$index}->{setlimits} // "normal";

		# ifDescr must always be filled
		$ifDescr = $index if ($ifDescr eq "");

		if ($ifAlias ne "" && $ifAlias ne "0")
	   	{
			$Description   = "Alias: '$ifAlias'";
		}
		$NG->log->debug("Description             = '$Description'");
		if ( $subrPortTel->{$index} ne "" and $subrPortName->{$index} ne "" && $subrPortName->{$index} ne "0")
	   	{
			$NG->log->debug("Found both 'subrPortTel' and 'subrPortName'");
			$Description  = "Name: '$subrPortName->{$index}'; Telephone: '$subrPortTel->{$index}'";
		}
		elsif ( $subrPortName->{$index} ne "" && $subrPortName->{$index} ne "0" )
	   	{
			$NG->log->debug("Found 'subrPortName'");
			$Description  = "Name: '$subrPortName->{$index}'";
		}
		elsif ( $subrPortTel->{$index} ne "" )
	   	{
			$NG->log->debug("Found 'subrPortTel'");
			$Description  = "Telephone: '$subrPortTel->{$index}'";
		}
		$NG->log->debug("Description             = '$Description'");
		
		$NG->log->debug("SNMP $node $ifDescr $Description, index=$index, ifType=$ifType, ifSpeed=$ifSpeed, ifAdminStatus=$ifAdminStatus, ifOperStatus=$ifOperStatus, subrPortName=$subrPortName->{$index}, subrPortTel=$subrPortTel->{$index}");
		
#		$ifSpeed = 10000000000 if ( $ifDescr =~ /ten-gigabit-ethernet/ );
#		$ifSpeed = 10000000000 if ( $ifSpeed == 4294967295 );
				
		$NG->log->debug("SNMP processing '$node' Description: '$ifDescr' Interface Speed=$ifSpeed.");
				
		$NG->log->debug("Interface Name          = '$ifName'");
		$NG->log->debug("Interface Alias         = '$ifAlias'");
		$NG->log->debug("Interface Index         = '$index'");
		$NG->log->debug("Interface Description   = '$ifDescr'");
		$NG->log->debug("Description             = '$Description'");
		$NG->log->debug("Interface Type          = '$ifType'");
		$NG->log->debug("Interface Speed         = '$ifSpeed'");
		$NG->log->debug("Interface Admin Status  = '$ifAdminStatus'");
		$NG->log->debug("Interface Oper Status   = '$ifOperStatus'");
		$NG->log->debug("Interface Limits        = '$setlimits'");
		$intfData->{$index}->{index}             = $index;
		$intfData->{$index}->{ifIndex}           = $index;
		$intfData->{$index}->{interface}         = NMISNG::Util::convertIfName($ifDescr);
		$intfData->{$index}->{ifName}            = $ifName;
		$intfData->{$index}->{Description}       = $Description // "N/A";
		$intfData->{$index}->{ifDescr}           = $ifDescr;
		$intfData->{$index}->{ifType}            = $ifType;
		$intfData->{$index}->{ifSpeed}           = $ifSpeed;
		$intfData->{$index}->{ifSpeedIn}         = $ifSpeed;
		$intfData->{$index}->{ifSpeedOut}        = $ifSpeed;
		$intfData->{$index}->{ifAdminStatus}     = $ifAdminStatus;
		$intfData->{$index}->{ifOperStatus}      = $ifOperStatus;
		$intfData->{$index}->{setlimits}         = $setlimits;
		$intfData->{$index}->{ifLastChange}      = NMISNG::Util::convUpTime($ifLastChange = int($ifLastChange/100));
		$intfData->{$index}->{ifLastChangeSec}   = $ifLastChange;
		$intfData->{$index}->{real}              = 'true';

		# collect the uplinks!
		if ( $ifType =~ "ethernetCsmacd" and $ifDescr !~ /virtual/ and $ifAdminStatus eq "up")
		{
			$intfData->{$index}->{collect}           = "true";
			$intfData->{$index}->{event}             = "true";
			$intfData->{$index}->{threshold}         = "true";
		}
		else
		{
			$intfData->{$index}->{collect}           = "false";
			$intfData->{$index}->{event}             = "false";
			$intfData->{$index}->{threshold}         = "false";
		}
		
		# check for duplicated ifDescr
		foreach my $i (keys %{$intfData})
	   	{
			if ($index ne $i and $intfData->{$index}->{ifDescr} eq $intfData->{$i}->{ifDescr})
		   	{
				$intfData->{$index}->{ifDescr} = "$ifDescr-$index"; # add index to this description.
				$intfData->{$i}->{ifDescr}     = "$ifDescr-$i";         # and the duplicte one.
				$NG->log->debug("Index added to duplicate Interface Description '$ifDescr'");
			}
		}
		my $thisintfover = $overrides->{$ifDescr} || {};
		$NG->log->debug("Overrides = ". Dumper($thisintfover) . "\n\n\n");

		### Add in anything we find from nodeConf - allows manual updating of interface variables
		### warning - will overwrite what we got from the device - be warned !!!
		if ($thisintfover->{Description} ne '')
		{
			$intfData->{$index}->{nc_Description} = $intfData->{$index}->{Description}; # save
			$intfData->{$index}->{Description}    = $thisintfover->{Description};
			$NG->log->debug("Manual update of Description by nodeConf; New Description = '$Description'");
		}
		
		if ($thisintfover->{ifSpeed} ne '')
	   	{
			$intfData->{$index}->{nc_ifSpeed} = $intfData->{$index}->{ifSpeed}; # save
			$intfData->{$index}->{ifSpeed} = $thisintfover->{ifSpeed};
			$NG->log->debug("Manual update of ifSpeed by nodeConf");
		}
		
		# convert interface name
		$intfData->{$index}->{interface} = NMISNG::Util::convertIfName($intfData->{$index}->{ifDescr});
		$intfData->{$index}->{ifIndex} = $index;
		
		### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
		# modify by node Config ?
		if ($thisintfover->{collect} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}->{ifDescr})
		{
			$intfData->{$index}->{nc_collect} = $intfData->{$index}->{collect};
			$intfData->{$index}->{collect} = $thisintfover->{collect};
			$NG->log->debug("Manual update of Collect by nodeConf");
			if ($intfData->{$index}->{collect} eq 'false')
		   	{
				$intfData->{$index}->{nocollect} = "Manual update by nodeConf";
			}
		}
		if ($thisintfover->{event} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}->{ifDescr})
	   	{
			$intfData->{$index}->{nc_event} = $intfData->{$index}->{event};
			$intfData->{$index}->{event} = $thisintfover->{event};
			$intfData->{$index}->{noevent} = "Manual update by nodeConf" if $intfData->{$index}->{event} eq 'false'; # reason
			$NG->log->debug("Manual update of Event by nodeConf");
		}
		if ($thisintfover->{threshold} ne '' and $thisintfover->{ifDescr} eq $intfData->{$index}->{ifDescr})
	   	{
			$intfData->{$index}->{nc_threshold} = $intfData->{$index}->{threshold};
			$intfData->{$index}->{threshold} = $thisintfover->{threshold};
			$intfData->{$index}->{nothreshold} = "Manual update by nodeConf" if $intfData->{$index}->{threshold} eq 'false'; # reason
			$NG->log->debug("Manual update of Threshold by nodeConf");
		}
		
		# interface now up or down, check and set or clear outstanding event.
		if ( $intfData->{$index}->{collect} eq 'true' and $intfData->{$index}->{ifAdminStatus} =~ /up|ok/ and $intfData->{$index}->{ifOperStatus} !~ /up|ok|dormant/ )
		{
			if ($intfData->{$index}->{event} eq 'true')
		   	{
				Compat::NMIS::notify(sys=>$S,event=>"Interface Down",element=>$intfData->{$index}->{ifDescr},details=>$intfData->{$index}->{Description});
			}
		}
		else
	   	{
			Compat::NMIS::checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$intfData->{$index}->{ifDescr},details=>$intfData->{$index}->{Description});
		}
		
		$intfData->{$index}->{threshold} = $intfData->{$index}->{collect};
		
		# number of interfaces collected with collect and event on
		++$intfCollect if $intfData->{$index}->{collect} eq 'true' && $intfData->{$index}->{event} eq 'true';
		
		# save values only if all interfaces are updated
		$NI->{system}{intfTotal} = $intfTotal;
		$NI->{system}{intfCollect} = $intfCollect;
		
		if ($intfData->{$index}->{collect} eq "true")
	   	{
			$NG->log->debug("ifIndex $index, collect=true");
		}
	   	else
	   	{
			$NG->log->debug("ifIndex $index, collect=false, $intfData->{$index}->{nocollect}");
		}
		
	}

	# Now we save eachInterface in our node. We do this as a separate 
	# step because the above might alter names because of duplication.
	$NG->log->debug2(sub {"intfData = ". Dumper($intfData) . "\n\n\n"});
	foreach my $index (keys(%$intfData))
	{
		$NG->log->debug("Index = ".$index);
		# Now get-or-create an inventory object for this new concept
		#
		my $intfSubData = $intfData->{$index};
		$NG->log->debug3(sub {"intfSubData = ". Dumper($intfSubData) . "\n\n\n"});
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
		if ($intfSubData->{collect} eq 'true')
		{
			$inventory->enabled(1);
		}
		else
		{
			$inventory->enabled(0);
		}
		$inventory->description( $intfSubData->{ifDescr} );
		$inventory->data( $intfSubData );

		# set which columns should be displayed
		$inventory->data_info(
			subconcept => "interface",
			enabled => 1,
			display_keys => $intfInfo
		);
		$NG->log->debug9(sub {"Inventory = ". Dumper($inventory) . "\n\n\n"});

		$NG->log->debug("Interface description is '$intfSubData->{ifDescr}'");
		# Get the RRD file name to use for storage.
		my $dbname = $S->makeRRDname(graphtype => "interface",
									index      => $index,
									inventory  => $intfSubData,
									extras     => $intfSubData,
									relative   => 1);
		$NG->log->debug("Collect Zyxel data info check storage interface, dbname '$dbname'.");
		
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
							$NG->log->debug2(sub { "rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"});
							RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
						}
						else
						{
							$NG->log->debug2(sub {"rrd section $datatype, ds $dsname, current limit $curval is correct"});
						}
					}
				}
			}
		}

		# The above has added data to the inventory, that we now save.
		my ( $op, $subError ) = $inventory->save( node => $node, update => 1 );
		$NG->log->debug2(sub { "saved ".join(',', @$path)." op: $op"});
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
	$snmp->close;

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

