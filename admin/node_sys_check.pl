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

if ( $ARGV[0] eq "" ) {
	usage();
	exit 1;
}

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

my $C = loadConfTable();

if ( not defined $arg{node} ) {
	print "ERROR: need a node to check\n";
	usage();
	exit 1;
}

my $node = $arg{node};

# Set debugging level.
my $debug = setDebug($arg{debug});

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

if ( $arg{node} eq "all" ) {
	print "Processing all nodes\n";
	checkNodes();
}
elsif ( $arg{node} ) {
	checkNode($node);
}
else {
	print "WHAT? node=$arg{node}\n";
}

print $t->elapTime(). " END\n";

sub checkNode {
	my $node = shift;
  if ( $NODES->{$node}{active} eq "true") {
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		my $V =  $S->view;
		my $MDL = $S->mdl;
		my $IFD = $S->ifDescrInfo(); # interface info indexed by ifDescr
				
		my $changes = 0;
		my @interfaceSections = qw(interface pkts pkts_hc);
		my @cpuSections = qw(hrsmpcpu);

		my @systemHealthSections = qw(
				hrdisk
				bgpPeer
				mtxrWlRtab
				mtxrWlAp
				mtxrWlStat
				WirelessAccessPoint
				WirelessRegistration
		);
		
		my %nodeevents = loadAllEvents(node => $node);
		
		# pattern for looking for events which exist.
		foreach my $eventkey (keys %nodeevents) {
			my $thisevent = $nodeevents{$eventkey};
			#print "eventDelete(node => $node, event => $thisevent->{event}, element => $thisevent->{element})\n";
			#print Dumper $thisevent;

			if ( $thisevent->{event} =~ /BGP/ ) {
				if ( defined $MDL->{systemHealth}{rrd}{bgpPeer} ) {
					print "INFO: $node found systemHealth/rrd/bgpPeer in the model\n" if $debug;							
				}
				else {
					print "FIXING: $node has BGP Peer Event and no BGP Peer modelling\n" if $debug;							
					eventDelete(event => $thisevent);
					$changes = 1;					
				}
			}
		}

		# how are the top level sections.
		foreach my $section (sort keys %{$NI}) {
			print "INFO: $node has $section defined\n" if $debug;
			if ( ref($NI->{$section}) eq "HASH" and not (keys %{$NI->{$section}}) ) {
				print "FIXING: $node empty section $section\n";
			}
		}
		
		# pattern for cleaning up stray systeamHealth sections
		foreach my $section (@systemHealthSections) {
			print "INFO: $node has $section defined\n" if $debug;
			if ( exists $NI->{$section} 
				and not defined $MDL->{systemHealth}{sys}{$section} 
			) {
				print "FIXING: $node has $section in data but no modelling\n";
				delete $NI->{$section};
				$changes = 1;	
			}
		}

		
		foreach my $indx (sort keys %{$NI->{graphtype}} ) {
			print "Processing $indx\n" if $debug;
			if ( ref($NI->{graphtype}{$indx}) eq "HASH" and keys %{$NI->{graphtype}{$indx}} ) {
				
				if ( defined $NI->{graphtype}{$indx}{LogicalDisk} and $NI->{graphtype}{$indx}{LogicalDisk} =~ /diskio-rwbytes/ ) {
					print "FIXING: $node LogicalDisk $indx has graphtype diskio things\n";
					$NI->{graphtype}{$indx}{LogicalDisk} = "WindowsDiskBytes,WindowsDisk";
					$changes = 1;
				}
				
				foreach my $section (@interfaceSections) {
					if ( defined $NI->{graphtype}{$indx}{$section} and defined $NI->{interface}{$indx} ) {
						# there should be an interface to check
						print "INFO: $node $indx for $section and found interface\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $NI->{interface}{$indx} ) {
						print "FIXING: $node $indx has graphtype $section but no interface\n";
						delete $NI->{graphtype}{$indx}{$section};
						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
					# does a model section exist?
					if ( defined $MDL->{interface}{rrd}{$section} ) {
						print "INFO: $node found interface/rrd/$section in the model\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $MDL->{interface}{rrd}{$section} ) {
						print "FIXING: $node NO interface/rrd/$section found in the model for $indx\n";
						delete $NI->{graphtype}{$indx}{$section};							
						$changes = 1;
					}

					# do the graphs exist in the model?
					if ( defined $NI->{graphtype}{$indx}{$section} ) {
						my @newGraphTypes;
						my $graphChanges = 0;
						my @graphs = split(",",$NI->{graphtype}{$indx}{$section});
						foreach my $graph (@graphs) {
							if ( $MDL->{interface}{rrd}{$section}{graphtype} =~ /$graph/ ) {
								print "  INFO: $node found $graph in interface/rrd/$section/graphtype in the model\n" if $debug;
								push (@newGraphTypes,$graph);
							}
							else {
								print "  FIXING: $node found $graph in interface/rrd/$section/graphtype in the model\n" if $debug;
								$graphChanges = 1;
							}
						}
						if ( $graphChanges ) {
							$changes = 1;
							$NI->{graphtype}{$indx}{$section} = join(",",@newGraphTypes);
						}
					}

				}

      	print "INFO: $node working on @cpuSections\n" if $debug;
				foreach my $section (@cpuSections) {
					if ( defined $NI->{graphtype}{$indx}{$section} and defined $NI->{device}{$indx} ) {
						# there should be an interface to check
						print "INFO: $node $indx for $section and found CPU device\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $NI->{device}{$indx} ) {
						print "FIXING: $node $indx has graphtype $section but no CPU device\n";
						delete $NI->{graphtype}{$indx}{$section};
						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
				}

				# fixing a modelling messup				
				#"NetFlowStats" : "netflowstats,frag,ip",
				if ( defined $NI->{graphtype}{NetFlowStats} and ( $NI->{graphtype}{NetFlowStats} eq "netflowstats,frag,ip" or $NI->{graphtype}{NetFlowStats} eq "netflowstats,ip,frag" ) ) {
					print "FIXING: $node NetFlowStats has graphtype set to \"netflowstats,frag,ip\"\n";
					$NI->{graphtype}{NetFlowStats} = "netflowstats";
					$changes = 1;
				}
					

   #"bgpPeer" : {
   #   "192.168.90.18" : {
   #      "bgpPeerRemoteAs" : 64512,
   #
   #"status" : {
   #   "BGP Peer Down--192.168.90.18" : {
   #      "status" : "ok",               
   #      "value" : "100",               
   #      "event" : "BGP Peer Down",     
   #
   #"graphtype" : {
   #   "10.216.8.33" : {
   #      "bgpPeer" : "bgpPeerStats,bgpPeer"
   #   },
      
			      	print "INFO: $node working on @systemHealthSections\n" if $debug;
				# clean up systemHealth Sections, BGP Peers initially
				foreach my $section (@systemHealthSections) {
				      	print "  looking for $section with index $indx in graphtype\n" if $debug;
					if ( defined $NI->{graphtype}{$indx}{$section} 
						and exists $NI->{$section}
						and (keys %{$NI->{$section}}) 
						and exists $NI->{$section}{$indx} 
					) {
						# there should be an section to check
						print "INFO: $node graphtype $indx for $section and found $section\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} 
						and not defined $NI->{$section}
					) {
						print "FIXING: $node $indx has graphtype $section but no nodeinfo section defined\n";
						delete $NI->{graphtype}{$indx}{$section};
						$changes = 1;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} 
						and defined $NI->{$section}
						and (keys %{$NI->{$section}}) 
						and not defined $NI->{$section}{$indx} 
					) {
						print "FIXING: $node $indx has graphtype $section but no nodeinfo section defined\n";
						
						delete $NI->{graphtype}{$indx}{$section};
						
						#Now check for any events existing.
						my $event = "Alert: BGP Peer Down";
						my $status = "BGP Peer Down";
						my $element = $indx;
						my $event_exists = eventExist($node, $event, $element);

						if ( -f $event_exists ) {
							print "FIXING: $node $indx has unrelated event $event $element\n";
							my $thisevent = eventLoad(node => $node, event => $event, element => $element);
							eventDelete(event => $thisevent);
						}

						if ( defined $NI->{status}{"$status--$element"} ) {
							print "FIXING: $node $indx has unrelated status $status--$element\n";
							delete $NI->{status}{"$status--$element"};
						}

						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
				}
			}
			
			
			if ( defined $NI->{graphtype}{radio} and  $NI->{graphtype}{radio} =~ /linkrate/ ) {
				print "FIXING: $node radio $indx has graphtype linkrate things\n";
				$NI->{graphtype}{radio} = "signal,power,env-temp";
				$changes = 1;
			}

			if ( ref($NI->{graphtype}{$indx}) eq "HASH" and not keys %{$NI->{graphtype}{$indx}} ) {
				print "FIXING: $node $indx graphtype has no keys\n";
				delete $NI->{graphtype}{$indx};
				$changes = 1;
			}
			elsif ( defined($NI->{graphtype}{$indx}) and $NI->{graphtype}{$indx} ne "" ) {
				print "INFO: $indx is a SCALAR\n" if $debug;
			}
			else {
				print "FIXING: $node $indx is unknown?\n";
				print Dumper $NI->{graphtype}{$indx};

			}
		}
		
		# lets look for redundant events.......
		if (my %nodeevents = loadAllEvents(node => $node)) {
			for my $eventkey (sort keys %nodeevents) {
				my $thisevent = $nodeevents{$eventkey};
				
				if ( defined $thisevent->{element} ) {
					my $element = $thisevent->{element};
					
					# simple match first.
					if ( ref($NI->{graphtype}{$element}) eq "HASH" and keys %{$NI->{graphtype}{$element}} ) {
						print "INFO: Found element $element for event $thisevent->{event}\n";
					}
					else {
						# lets try to match interfaces
						my $gotOne = 0;
						my @elements = split(":",$element);
						foreach my $ele (@elements) {
							if (defined $IFD->{$ele}{ifIndex} ) {
								print "INFO: got ifIndex $IFD->{$ele}{ifIndex} from $element\n";
								$element = $IFD->{$ele}{ifIndex};
								last;
							}
							#$entry->{lldpIfIndex} = $IFD->{$ifDescr}{ifIndex};
						}
	
						if ( ref($NI->{graphtype}{$element}) eq "HASH" and keys %{$NI->{graphtype}{$element}} ) {
							print "INFO: Found element $element for event $thisevent->{event}\n";
							$gotOne = 1;
						}
	
	
						if ( not $gotOne ) {
							print "ERROR: NO ELEMENT $element for event $thisevent->{event}\n";
							print Dumper $thisevent;
						}
					}
				}
			}
		}
		
		if ( $changes ) {
	
			my ($file,undef) = getFileName(dir => "var", file => lc("$node-node"));
			if ( $file !~ /^var/ ) {
				$file = "var/$file";
			}
			my $dataFile = "$C->{'<nmis_base>'}/$file";
			my $backupFile = "$C->{'<nmis_base>'}/$file.backup";
			my $backupCount = 0;
			while ( -f $backupFile ) {
				++$backupCount;
				$backupFile = "$C->{'<nmis_base>'}/$file.backup.$backupCount";
			}
			print "BACKUP $dataFile to $backupFile\n";
			#print Dumper $NI->{graphtype};
			
			my $backup = backupFile(file => $dataFile, backup => $backupFile);
			if ( $backup ) {
				print "$dataFile backup'ed up to $backupFile\n" if $debug;
				$S->writeNodeInfo();
			}
			else {
				print "SKIPPING: $dataFile could not be backup'ed\n";
			}
			
			#
		}
		
		if ( $arg{model} eq "dump" ) {
			print Dumper $MDL;
		}

  }
}

sub checkNodes {
	foreach my $node (sort keys %{$NODES}) {
		checkNode($node);
	}	
}



sub usage {
	print <<EO_TEXT;
$0 will export nodes and ports from NMIS.
ERROR: need some files to work with
usage: $0 dir=<directory>
eg: $0 node=nodename|all debug=true|false

EO_TEXT
}



sub backupFile {
	my %arg = @_;
	my $buff;
	if ( not -f $arg{backup} ) {			
		if ( -r $arg{file} ) {
			open(IN,$arg{file}) or warn ("ERROR: problem with file $arg{file}; $!");
			open(OUT,">$arg{backup}") or warn ("ERROR: problem with file $arg{backup}; $!");
			binmode(IN);
			binmode(OUT);
			while (read(IN, $buff, 8 * 2**10)) {
			    print OUT $buff;
			}
			close(IN);
			close(OUT);
			return 1;
		} else {
			print STDERR "ERROR: backupFile file $arg{file} not readable.\n";
			return 0;
		}
	}
	else {
		print STDERR "ERROR: backup target $arg{backup} already exists.\n";
		return 0;
	}
}
