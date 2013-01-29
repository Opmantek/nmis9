#!/usr/bin/perl

use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use func;
use NMIS;
use Data::Dumper;

my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;


my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();

foreach my $node (sort keys %{$LNT}) {
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print "Processing $node\n";
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		
		my $graphObj = getNodeGraphObjects($S);

		print "  Available Graphs for $node:\n";

		foreach my $graph (keys %$graphObj) {
			print "    $graphObj->{$graph}{name}\n";
		}
		
		print Dumper $graphObj;
		
		
		#
		
	}
}



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
