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
# a small update plugin for converting the cdp index into interface name.

package AlcatelASAM;
our $VERSION = "1.1.0";

use strict;
use NMIS;												# lnt
use func;												# for the conf table extras
use snmp 1.1.0;									# for snmp-related access

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $LNT = loadLocalNodeTable(); # fixme required? are rack_count and shelf_count kept in the node's ndinfo section?
	my $NC = $S->ndcfg;
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	# anything to do?
	return (0,undef) if ( $NI->{system}{nodeModel} !~ "AlcatelASAM" 
												or !getbool($NI->{system}->{collect}));
	
	my $asamVersion41 = qr/OSWPAA41|L6GPAA41|OSWPAA37|L6GPAA37|OSWPRA41/;
	my $asamVersion42 = qr/OSWPAA42|L6GPAA42|OSWPAA46/;
	my $asamVersion43 = qr/OSWPRA43|OSWPAN43/;

	my $asamSoftwareVersion = $NI->{system}{asamSoftwareVersion1};
	if ( $NI->{system}{asamActiveSoftware2} eq "active" ) 
	{
		$asamSoftwareVersion = $NI->{system}{asamSoftwareVersion2};
	}
	my @verParts = split("/",$asamSoftwareVersion);
	$asamSoftwareVersion = $verParts[$#verParts];
			
	my $version;
	if( $asamSoftwareVersion =~ /$asamVersion41/ ) {
		$version = 4.1;		
	}
	#" release 4.2  ( ISAM FD y  ISAM-V) "
	elsif( $asamSoftwareVersion =~ /$asamVersion42/ )
	{
		$version = 4.2;
	}
	elsif( $asamSoftwareVersion =~ /$asamVersion43/ )
	{
		$version = 4.3;
	}
	else {
		logMsg("ERROR: Unknown ASAM Version $node asamSoftwareVersion=$asamSoftwareVersion");
	}

	# Get the SNMP Session going.
	my $snmp = snmp->new(name => $node);
	return (2,"Could not open SNMP session to node $node: ".$snmp->error)
			if (!$snmp->open(config => $NC->{node}, host_addr => $NI->{system}->{host_addr}));
	return (2, "Could not retrieve SNMP vars from node $node: ".$snmp->error)
			if (!$snmp->testsession);
	my $changesweremade = 0;
	
	info("Working on $node atmVcl");

	my $offset = 12288;
	if ( $version eq "4.2" )  {
		$offset = 6291456;
	}
	
	for my $key (keys %{$NI->{atmVcl}})
	{
		my $entry = $NI->{atmVcl}->{$key};
                    
		if ( my @parts = split(/\./,$entry->{index}) ) 
		{
			my $ifIndex = shift(@parts);
			my $atmVclVpi = shift(@parts);
			my $atmVclVci = shift(@parts);

			my $offsetIndex = $ifIndex - $offset;
	
			my $asamIfExtCustomerId = "1.3.6.1.4.1.637.61.1.6.5.1.1.$offsetIndex";
			my $xdslLineServiceProfileNbr = "1.3.6.1.4.1.637.61.1.39.3.7.1.1.$offsetIndex";
			my $xdslLineSpectrumProfileNbr = "1.3.6.1.4.1.637.61.1.39.3.7.1.2.$offsetIndex";
	
			my @oids = [
				"$asamIfExtCustomerId",
				"$xdslLineServiceProfileNbr",
				"$xdslLineSpectrumProfileNbr",
			];
		
			my $snmpdata = $snmp->get(@oids);
						
			$entry->{ifIndex} = $ifIndex;
			$entry->{atmVclVpi} = $atmVclVpi;
			$entry->{atmVclVci} = $atmVclVci;
			$entry->{asamIfExtCustomerId} = "N/A";
			$entry->{xdslLineServiceProfileNbr} = "N/A";
			$entry->{xdslLineSpectrumProfileNbr} = "N/A";

			if ( $snmpdata->{$asamIfExtCustomerId} ne "" and $snmpdata->{$asamIfExtCustomerId} !~ /SNMP ERROR/ ) {
				$entry->{asamIfExtCustomerId} = $snmpdata->{$asamIfExtCustomerId};
			}

			if ( $snmpdata->{$xdslLineServiceProfileNbr} ne "" and $snmpdata->{$xdslLineServiceProfileNbr} !~ /SNMP ERROR/ ) {
				$entry->{xdslLineServiceProfileNbr} = $snmpdata->{$xdslLineServiceProfileNbr};
			}

			if ( $snmpdata->{$xdslLineSpectrumProfileNbr} ne "" and $snmpdata->{$xdslLineSpectrumProfileNbr} !~ /SNMP ERROR/ ) {
				$entry->{xdslLineSpectrumProfileNbr} = $snmpdata->{$xdslLineSpectrumProfileNbr};
			}

			dbg("ASAM SNMP Results: ifIndex=$ifIndex atmVclVpi=$atmVclVpi atmVclVci=$atmVclVci asamIfExtCustomerId=$entry->{asamIfExtCustomerId}");

			if ( defined $IF->{$ifIndex}{ifDescr} ) {
				$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
				$entry->{ifDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifIndex&node=$node";
				$entry->{ifDescr_id} = "node_view_$node";
			}
			else {
				$entry->{ifDescr} = getIfDescr(prefix => "ATM", version => $version, ifIndex => $ifIndex);
			}

			$changesweremade = 1;
		}
	}

	info("Working on $node ifStack");

	for my $key (keys %{$NI->{ifStack}})
	{
		my $entry = $NI->{ifStack}->{$key};
          
		if ( my @parts = split(/\./,$entry->{index}) ) {
			my $ifStackHigherLayer = shift(@parts);
			my $ifStackLowerLayer = shift(@parts);
			
			$entry->{ifStackHigherLayer} = $ifStackHigherLayer;
			$entry->{ifStackLowerLayer} = $ifStackLowerLayer;

			if ( defined $IF->{$ifStackHigherLayer}{ifDescr} ) {
				$entry->{ifDescrHigherLayer} = $IF->{$ifStackHigherLayer}{ifDescr};
				$entry->{ifDescrHigherLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackHigherLayer&node=$node";
				$entry->{ifDescrHigherLayer_id} = "node_view_$node";
			}

			if ( defined $IF->{$ifStackLowerLayer}{ifDescr} ) {
				$entry->{ifDescrLowerLayer} = $IF->{$ifStackLowerLayer}{ifDescr};
				$entry->{ifDescrLowerLayer_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_interface_view&intf=$ifStackLowerLayer&node=$node";
				$entry->{ifDescrLowerLayer_id} = "node_view_$node";
			}

			dbg("WHAT: ifDescr=$IF->{$ifStackHigherLayer}{ifDescr} ifStackHigherLayer=$entry->{ifStackHigherLayer} ifStackLowerLayer=$entry->{ifStackLowerLayer} ");

			$changesweremade = 1;
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

sub getIfDescr {
	my %args = @_;
	
	my $oid_value 		= $args{ifIndex};	
	my $prefix 		= $args{prefix};	
	
	if ( $args{version} eq "4.1" or $args{version} eq "4.3" ) {
		my $rack_mask 		= 0x70000000;
		my $shelf_mask 		= 0x07000000;
		my $slot_mask 		= 0x00FF0000;
		my $level_mask 		= 0x0000F000;
		my $circuit_mask 	= 0x00000FFF;
	
		my $rack 		= ($oid_value & $rack_mask) 		>> 28;
		my $shelf 	= ($oid_value & $shelf_mask) 		>> 24;
		my $slot 		= ($oid_value & $slot_mask) 		>> 16;
		my $level 	= ($oid_value & $level_mask) 		>> 12;
		my $circuit = ($oid_value & $circuit_mask);

		# Apparently this needs to be adjusted when going to decimal?
		$slot = $slot - 2;
		++$circuit;	
		
		return "$prefix-$rack-$shelf-$slot-$circuit";
	}
	else {
		my $slot_mask 		= 0x7E000000;
		my $level_mask 		= 0x01E00000;	
		my $circuit_mask 	= 0x001FE000;
			
		my $slot 		= ($oid_value & $slot_mask) 		>> 25;
		my $level 	= ($oid_value & $level_mask) 		>> 21;
		my $circuit = ($oid_value & $circuit_mask) 	>> 13;
		
		# Apparently this needs to be adjusted when going to decimal?
		if ( $slot > 1 ) {
			--$slot;
		}
		++$circuit;	
		
		$prefix = "XDSL" if $level == 16;

		return "$prefix-1-1-$slot-$circuit";		
	}
}



1;
