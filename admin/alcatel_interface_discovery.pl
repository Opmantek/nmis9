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

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will export nodes from NMIS.
ERROR: need some files to work with
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


		############################################################################################################
		#
		## THe following code contains psuedo-code inside it.  Just the first and second if statements
		#
		############################################################################################################
		if ( $NI->{system}{sysDescr} =~ /ASAM|ARAM|ISAM/ and $NI->{system}{nodeVendor} eq "Alcatel Data Network" ) {
			#asamActiveSoftware1	standby
			#asamActiveSoftware2	active
			#asamSoftwareVersion1	/OSWP/OSWPAA37.432
			#asamSoftwareVersion2	OSWP/66.98.63.71/OSWPAA41.353/OSWPAA41.353
			
			#asamActiveSoftware1	standby
			#asamActiveSoftware2	active
			#asamSoftwareVersion1	OSWP/66.98.63.71/L6GPAA42.413/L6GPAA42.413
			#asamSoftwareVersion2	OSWP/66.98.63.71/OSWPAA42.413/OSWPAA42.413

			my $asamVersion41 = "OSWPAA37.432";
			my $asamVersion41 = "OSWPAA41.353";
			my $asamVersion42 = "OSWPAA41.363";
			my $asamVersion42 = "OSWPAA42.413";
			
			my $rack_count = 1;
			my $shelf_count = 1;

			$rack_count = $LNT->{$node}{rack_count} if $LNT->{$node}{rack_count} ne "";
			$shelf_count = $LNT->{$node}{shelf_count} if $LNT->{$node}{shelf_count} ne "";
			
			my $asamSoftwareVersion = $S->{info}{system}{asamSoftwareVersion1};
			if ( $S->{info}{system}{asamActiveSoftware2} eq "active" ) {
				$asamSoftwareVersion = $S->{info}{system}{asamSoftwareVersion2};
			}
			my @verParts = split("/",$asamSoftwareVersion);
			$asamSoftwareVersion = $verParts[$#verParts];
			
			my @ifIndexNum = ();
			#"Devices in release 4.1  (ARAM-D y ARAM-E)"
			if( $asamSoftwareVersion eq $asamVersion41 ) {
				# How to identify it is an ARAM-D?
				#"For ARAM-D with extensions "
				if( 0 ) {
					my $indexes = build_41_interface_indexes( shelf_count => $shelf_count, rack_count => $rack_count );
					@ifIndexNum = @{$indexes};
				}
				else {
					my $indexes = build_41_interface_indexes( shelf_count => $shelf_count, rack_count => $rack_count );
					@ifIndexNum = @{$indexes};
				}
				
			}
			#" release 4.2  ( ISAM FD y  ISAM-V) "
			elsif( $asamSoftwareVersion eq $asamVersion42 )
			{
				my $indexes = build_42_interface_indexes( shelf_count => $shelf_count, rack_count => $rack_count );
				@ifIndexNum = @{$indexes};
			}
			else {
				print STDERR "WHAT!  asamSoftwareVersion=$asamSoftwareVersion\n";
			}

		
			my $intfTotal = 0;
			my $intfCollect = 0; # reset counters

			foreach my $index (@ifIndexNum) {
				$intfTotal++;				
				my $ifDescr = "ATM $index";
				$S->{info}{interface}{$index} = {
		      'Description' => '',
		      'ifAdminStatus' => 'unknown',
		      'ifDescr' => $ifDescr,
		      'ifIndex' => $index,
		      'ifLastChange' => '0:00:00',
		      'ifLastChangeSec' => 0,
		      'ifOperStatus' => 'unknown',
		      'ifSpeed' => 1000000000,
		      'ifType' => 'atm',
		      'interface' => "atm-$index",
		      'real' => 'true',
		      'threshold' => 'true'
				
				};
				
				# preset collect,event to required setting, Node Configuration Will override.
				$S->{info}{interface}{$index}{collect} = "false";
				$S->{info}{interface}{$index}{event} = "false";
									
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
				if ($NCT->{$S->{node}}{$ifDescr}{Description} ne '') {
					$S->{info}{interface}{$index}{nc_Description} = $S->{info}{interface}{$index}{Description}; # save
					$S->{info}{interface}{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $NCT->{$S->{node}}{$ifDescr}{Description};
					dbg("Manual update of Description by nodeConf");
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
			
			#print Dumper $S;

			$S->writeNodeView;  # save node view info in file var/$NI->{name}-view.nmis
			$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.nmis			
		}
	}
}

sub build_41_interface_indexes {
	my %args = @_;
	my $rack_count = 1;
	my $shelf_count = 1;

	# For ARAM-D with extensions the shelf value changes to 2 for the first extension (shelf = 010) , 3 for the second (shelf = 11) … and so on, 
	# such that the first port of the first card of the first extension would be:
	if( defined( $args{rack_count} ) ) {
		$rack_count = $args{rack_count};
	}

	if( defined( $args{shelf_count} ) ) {
		$shelf_count = $args{shelf_count};
	}

	my $level = 3;

	my @racks = (1..$rack_count);
	my @shelves = (1..$shelf_count);
	my @slots = (3..19);
	my @circuits = (0..47);
	
	my @interfaces = ();

	foreach my $rack (@racks) {
		foreach my $shelf (@shelves) {
			foreach my $slot (@slots) {
				foreach my $circuit (@circuits) {
					my $index = generate_interface_index_41 ( rack => $rack, shelf => $shelf, slot => $slot, level => $level, circuit => $circuit);
					push( @interfaces, $index );
				}		
			}
		}
	}
	return \@interfaces;
}

sub build_42_interface_indexes {
	my %args = @_;

	my $rack_count = 1;
	my $shelf_count = 1;

	if( defined( $args{rack_count} ) ) {
		$rack_count = $args{rack_count};
	}

	if( defined( $args{shelf_count} ) ) {
		$shelf_count = $args{shelf_count};
	}

	my $level = 3;
	
	my @racks = (1..$rack_count);
	my @shelves = (1..$shelf_count);
	my @slots = (2..16);
	my @circuits = (0..47);

	my @interfaces = ();

	foreach my $rack (@racks) {
		foreach my $shelf (@shelves) {
			foreach my $slot (@slots) {
				foreach my $circuit (@circuits) {
					my $index = generate_interface_index_42 ( rack => $rack, shelf => $shelf, slot => $slot, level => $level, circuit => $circuit);
					push( @interfaces, $index );
				}		
				#  generate extra indexes at level 16, these are the XDSL channel ones
				if( $slot == 16 ) {
					$level = 16;
					foreach my $circuit (@circuits) {
						my $index = generate_interface_index_42 ( rack => $rack, shelf => $shelf, slot => $slot, level => $level, circuit => $circuit);
						push( @interfaces, $index );
					}			
				}
			}
		}
	}
	return \@interfaces;
}

sub generate_interface_index_41 {
	my %args = @_;
	my $rack = $args{rack};
	my $shelf = $args{shelf};
	my $slot = $args{slot};
	my $level = $args{level};
	my $circuit = $args{circuit};

	my $index = 0;
	$index = ($rack << 28) | ($shelf << 24) | ($slot << 16) | ($level << 12) | ($circuit);
	return $index;
}

sub generate_interface_index_42 {
	my %args = @_;
	my $rack = $args{rack};
	my $shelf = $args{shelf};
	my $slot = $args{slot};
	my $level = $args{level};
	my $circuit = $args{circuit};

	my $index = 0;
	$index = ($slot << 25) | ($level << 21) | ($circuit << 13);
	return $index;
}

###############################################
#
# 4.1
#
# •	Level = 
# •	0000b for XDSL line, SHDSL Line, Ethernet Line, VoiceFXS Line or IsdnU Line 
# •	0001b for XDSL Channel  

###############################################
sub decode_interface_index_41 {
	my %args = @_;

	my $oid_value 		= 285409280;	
	if( defined $args{oid_value} ) {
		$oid_value = $args{oid_value};
	}
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

	print "4.1 Oid value=$oid_value\n";
	printf( "\t rack=0x%x, %d\n", $rack, $rack);
	printf( "\t shelf=0x%x, %d\n", $shelf, $shelf);
	printf( "\t slot=0x%x, %d\n", $slot, $slot);
	printf( "\t level=0x%x, %d\n", $level, $level);
	printf( "\t circuit=0x%x, %d\n", $circuit, $circuit);
	
	if( $level == 0xb ) {
		print "XDSL Line\n";
	}
	if( $level == 0x1b ) {
		print "XDSL Channel\n";
	}

}
###############################################
#
# 4.2
#	XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface
# •	Level=0000b….0100b, see Table 1
###############################################
sub decode_interface_index_42 {
	my %args = @_;
	my $oid_value 		= 67108864;
	if( $args{oid_value} ne '' ) {
		$oid_value = $args{oid_value};
	}
	
	my $slot_mask 		= 0xFC000000;
	my $level_mask 		= 0x03C00000;	
	my $circuit_mask 	= 0x001FE000;
	

	my $slot 		= ($oid_value & $slot_mask) 		>> 25;
	my $level 	= ($oid_value & $level_mask) 		>> 21;
	my $circuit = ($oid_value & $circuit_mask) 	>> 13;

	printf("4.2 Oid value=%d, 0x%x, %b\n", $oid_value, $oid_value, $oid_value);
	printf( "\t slot=0x%x, %d\n", $slot, $slot);
	printf( "\t level/card=0x%x, %d\n", $level, $level);
	printf( "\t circuit/port=0x%x, %d\n", $circuit, $circuit);
	if( $level >= 0xB && $level <= 0x100B) {
		print "XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface\n";
	}
}
