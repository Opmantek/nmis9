#!/usr/bin/perl
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
use warnings;
use func;
use NMIS;
use Data::Dumper;
use rrdfunc;

my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;


my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();

my $Q;

#http://nmis8/cgi-nmis8/node.pl?conf=Config.nmis&node=localhost&group=&start=1358863926&end=1359036726&intf=2&item=&act=network_export&graphtype=bits

$Q->{graphtype} = "bits";
$Q->{start} = "-2 days";
$Q->{end} = "now";
$Q->{item} = "";



foreach my $node (sort keys %{$LNT}) {
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print "Processing $node\n";
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;


		for my $ifIndex (keys %{$IF}) {
			if ( $IF->{$ifIndex}{collect} eq "true") {
				print "$IF->{$ifIndex}{ifIndex}\t$IF->{$ifIndex}{ifDescr}\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}\n";
				typeExport($S,$IF->{$ifIndex}{ifIndex});
			}
		}
	}
}
		
		#my $graphObj = getNodeGraphObjects($S);
    #
		#print "  Available Graphs for $node:\n";
    #
		#foreach my $graph (keys %$graphObj) {
		#	print "    $graphObj->{$graph}{name}\n";
		#}
		#
		#print Dumper $graphObj;
		#
		
		#
		


sub getNodeGraphObjects {
	my $S = shift;
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $graphObj;
		
	for my $object (keys %{$NI->{graphtype}}) {
		if ( $object !~ /nmis|metrics/ ) {
			if ( ref($NI->{graphtype}{$object}) eq "HASH" ) {
				for my $grph (keys %{$NI->{graphtype}{$object}}) {
					#print "DEBUG 1: $grph\n";
					if ( $grph =~ /interface/ ) {
						$graphObj->{interface}{name} = "Interface";
						$graphObj->{interface}{$object}{ifDescr} = $IF->{$object}{ifDescr};
						$graphObj->{interface}{$object}{Description} = $IF->{$object}{Description};

						my @graphs = split(",",$NI->{graphtype}{$object}{$grph});
						foreach my $g (@graphs) {
							push(@{$graphObj->{interface}{graphtypes}{$object}},"$g");
						}
					}
					elsif ( $grph =~ /cbqos/ ) {
						$graphObj->{cbqos}{name} = "CBQoS";
						$graphObj->{cbqos}{$object}{ifDescr} = $IF->{$object}{ifDescr};
						$graphObj->{cbqos}{$object}{Description} = $IF->{$object}{Description};
						push(@{$graphObj->{cbqos}{graphtypes}{$object}},"$grph");
					}
					elsif ( $grph =~ /pkts/ ) {
						$graphObj->{interface}{name} = "Interface";
						$graphObj->{interface}{$object}{ifDescr} = $IF->{$object}{ifDescr};
						$graphObj->{interface}{$object}{Description} = $IF->{$object}{Description};
						push(@{$graphObj->{interface}{graphtypes}{$object}},"$grph");
					}
					elsif ( $grph =~ /service/ ) {
						$graphObj->{service}{name} = "Services";
						push(@{$graphObj->{service}{graphtypes}{$object}},"$grph");
					}
					elsif ( $grph =~ /hrdisk/ ) {
						$graphObj->{storage}{name} = "Storage";
						$graphObj->{storage}{$object}{Description} = $NI->{storage}{$object}{hrStorageDescr};
						$graphObj->{storage}{$object}{Type} = $NI->{storage}{$object}{hrStorageType};
    				push(@{$graphObj->{storage}{graphtypes}{$object}},"$grph");
					}
					elsif ( $grph =~ /cpu/ ) {
						$graphObj->{cpu}{name} = "CPU";
						push(@{$graphObj->{cpu}{graphtypes}{$object}},"$grph");
					}
					else {
						print "    DEBUG 1 Graph $grph $object: $NI->{graphtype}{$object}{$grph}\n";
					}
				}
			}
			else {
				#Graph health: health,response,numintf
				#Graph nodehealth: topo,cpu,mem-router,mem-io,buffer,mem-proc
				#Graph mib2ip: frag,ip				
				my @graphs = split(",",$NI->{graphtype}{$object});
				
				foreach my $grph (@graphs) {
					#print "DEBUG 2: $grph\n";
					if ( $grph =~ /cpu/ ) {
						$graphObj->{cpu}{name} = "CPU";
						push(@{$graphObj->{cpu}{graphtypes}{1}},$grph);
					}
					elsif ( $grph =~ /buffer/ ) {
						$graphObj->{buffer}{name} = "Buffer";
						push(@{$graphObj->{buffer}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /health/ ) {
						$graphObj->{health}{name} = "Health";
						push(@{$graphObj->{health}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /numintf/ ) {
						$graphObj->{numintf}{name} = "Interface Count";
						push(@{$graphObj->{numintf}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /frag|ip/ ) {
						$graphObj->{ip}{name} = "IP Forwarding";
						push(@{$graphObj->{ip}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /response/ ) {
						$graphObj->{response}{name} = "Response";
						push(@{$graphObj->{response}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /mem\-|hrmem|hrvmem/ ) {
						$graphObj->{memory}{name} = "Memory";
						push(@{$graphObj->{memory}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /hrwin/ ) {
						$graphObj->{windows}{name} = "Windows";
						push(@{$graphObj->{windows}{graphtypes}},$grph);
					}
					elsif ( $grph =~ /topo/ ) {
						$graphObj->{spanningtree}{name} = "SpanningTree";
						push(@{$graphObj->{spanningtree}{graphtypes}},$grph);
					}
					else {
						print "    DEBUG 2 Graph $object: $NI->{graphtype}{$object}\n";
					}
				}
			}
		}
	}
	
	return($graphObj);
}

sub typeExport {
	my $S = shift;
	my $ifIndex = shift;

	my $f = 1;
	my @line;
	my $row;
	my $content;

	# verify that user is authorized to view the node within the user's group list
	#
	
	my ($statval,$head) = getRRDasHash(sys=>$S,graphtype=>$Q->{graphtype},mode=>"AVERAGE",start=>$Q->{start},end=>$Q->{end},index=>$ifIndex,item=>$Q->{item});
	my $filename = "$S->{name}"."-"."$Q->{graphtype}";
	if ( $S->{name} eq "" ) { $filename = "$Q->{group}-$Q->{graphtype}" }

	foreach my $m (sort keys %{$statval}) {
		if ($f) {
			$f = 0;
			foreach my $h (@$head) {
				push(@line,$h);
				#print STDERR "@line\n";
			}
			#print STDERR "@line\n";
			$row = join("\t",@line);
			print "$row\n";
			@line = ();
		}
		$content = 0;
		foreach my $h (@$head) {
			if ( defined $statval->{$m}{$h}) {
				$content = 1;
			}
			push(@line,$statval->{$m}{$h});
		}
		if ( $content ) {
			$row = join("\t",@line);
			print "$row\n";
		}
		@line = ();
	}
}

