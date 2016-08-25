#!/usr/bin/perl
#
## $Id: nodes_scratch.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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


# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use File::Basename;
use NMIS;
use func;
use Data::Dumper;

my $bn = basename($0);
my $usage = "Usage: $bn act=(which action to take)

\t$bn act=(run|monkey|banana)
\t$bn simulate=(true|false)
\t$bn opevents=(true|false) will enable or disable the node in opevents
\t$bn omkbin=(path to omk binaries if not /usr/local/omk/bin)

\t$bn debug=(true|false)

e.g. $bn act=run

\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));
my %arg = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>"",debug=>0);

my $debug = $arg{debug} ? $arg{debug} : 0;
my $simulate = $arg{simulate} ? getbool($arg{simulate}) : 0;
my $opevents = $arg{opevents} ? getbool($arg{opevents}) : 0;
my $omkbin = $arg{omkbin} || "/usr/local/omk/bin";

my $opnodeadmin = "$omkbin/opnode_admin.pl";

if ( $opevents and not -x $opnodeadmin ) {
	print "ERROR, opEvents required but $opnodeadmin not found or not executable\n";
	die;
}

print "This script will load the NMIS Nodes file and validate the nodes being managed.\n";
print "  opEvents update is set to $opevents (0 = disabled, 1 = enabled)\n";

my $nodesFile = "$C->{'<nmis_conf>'}/Nodes.nmis";


my %nodeIndex;

processNodes($nodesFile);

exit 0;

sub processNodes {
	my $nodesFile = shift;
	my $LNT;
	
	my $omkNodes;
	
	if ( $opevents ) {
		$omkNodes = getNodeList();
	}
	
	if ( -r $nodesFile ) {
		$LNT = readFiletoHash(file=>$nodesFile);
		print "Loaded $nodesFile\n";
	}
	else {
		print "ERROR, could not find or read $nodesFile\n";
		exit 0;
	}
	
	# make a node index
	foreach my $node (sort keys %{$LNT}) {
		my $lcnode = lc($node);
		#print "adding $lcnode to index\n";
		if ( $nodeIndex{$lcnode} ne "" ) {
			print "DUPLICATE NODE: node $node with $node exists as $nodeIndex{$lcnode}\n";
		}
		else {
			$nodeIndex{$lcnode} = $node;
		}
	}

	# Load the old CSV first for upgrading to NMIS8 format
	# copy what we need
	my @pingBad;
	my @snmpBad;

	my @updates;
	my @nameCorrections;

	foreach my $node (sort keys %{$LNT}) {	
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		print "Processing $node active=$LNT->{$node}{active} ping=$LNT->{$node}{ping} collect=$LNT->{$node}{collect}\n" if $debug;
		
		my $pingDesired = getbool($LNT->{$node}{ping});
		my $snmpDesired = getbool($LNT->{$node}{collect});
		
		my $nodePingable = 1;
		my $nodeSnmp = 1;

		if ( $LNT->{$node}{active} eq "true" ) {
			# Node has never responded to PING!
			if ( $pingDesired and $NI->{system}{nodedown} eq "true" and not exists($NI->{system}{lastCollectPoll}) ) {
				$LNT->{$node}{active} = "false";
				push(@pingBad,"$node,$LNT->{$node}{host}");
				$nodePingable = 0;
				# clear any Node Down events attached to the node.
				my $result = checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"");
			}
	
			# Node has never responded to SNMP!
			if ( $snmpDesired and $NI->{system}{snmpdown} eq "true" and $NI->{system}{sysDescr} eq "" ) {
				push(@snmpBad,"$node,$LNT->{$node}{host}");
				$LNT->{$node}{collect} = "false";
				$nodeSnmp = 0;
				# clear any SNMP Down events attached to the node.
				my $result = checkEvent(sys=>$S,event=>"SNMP Down",level=>"Normal",element=>"",details=>"");
			}
		}
		
		# update opEvents if desired
		if ( $opevents ) {
			my $details;
			
			my $nodeInOpNodes = 0;
			if ( grep { $_ eq $node } (@{$omkNodes} ) ) {
				$nodeInOpNodes = 1;
			}
			
			# is the node in opevents at all?
			if ( $LNT->{$node}{active} eq "true" and not $nodeInOpNodes ) {
				importNodeFromNmis($node);
			}
			
			# what is the current state of this thing.
			$details = getNodeDetails($node) if $nodeInOpNodes;
			
			# is the node NOT active and enabled for opEvents!
			if ( $LNT->{$node}{active} ne "true" and $nodeInOpNodes and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 1 ) ) {
				# yes, so disable the node in opEvents
				print "DISABLE node in opEvents: $node\n" if $debug;
				opEventsXable($node,0);
			}
			elsif ( $pingDesired and $nodePingable and $LNT->{$node}{active} eq "true" and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 0 ) ) {
				# yes, so enable the node in opEvents
				print "ENABLE node in opEvents: $node\n" if $debug;
				opEventsXable($node,1);
			}
			elsif ( $snmpDesired and $nodeSnmp and $LNT->{$node}{active} eq "true" and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 0 ) ) {
				# yes, so enable the node in opEvents
				print "ENABLE node in opEvents: $node\n" if $debug;
				opEventsXable($node,1);
			}
		}
	}

	print "\n\n";

	print "There are ". @pingBad . " nodes NOT Responding to POLLS EVER:\n";
	print "Active has been set to false:\n" if not $simulate;
	my $badnoderising = join("\n",@pingBad);
	print $badnoderising;

	print "\n\n";

	print "There are ". @snmpBad . " nodes with SNMP Not Working\n";
	print "Collect has been set to false:\n" if not $simulate;
	my $snmpNodes = join("\n",@snmpBad);
	print $snmpNodes;

	print "\n\n";

	if ( not $simulate ) {
		backupNodesFile($nodesFile);
		
		writeHashtoFile(file => $nodesFile, data => $LNT);
		print "NMIS Nodes file $nodesFile saved\n";	
	}
}


sub backupNodesFile {
	my $file = shift;
	my $NODES = readFiletoHash(file=>$file);
	my $backupFile = $file . time();
	print "Backing up nmis Nodes file to $backupFile\n";
	writeHashtoFile(file => $backupFile, data => $NODES);	
}


sub opEventsXable {
	my $node = shift;
	my $desired = shift;
	
	if ( $simulate ) {
		print "SIMULATE: opEventsXable node=$node disable/enable=$desired\n";
	}
	else {
		my $result = `$opnodeadmin act=set entry.activated.opEvents=$desired node=$node 2>&1`;
		print "opEventsXable: $result" if $debug;
		if ( $result =~ /Success/ ) {
			return 1;
		}
		else {
			return 0;
		}
	}
}

sub importNodeFromNmis {
	my $node = shift;
	
	my $command = "$omkbin/opeventsd.pl act=import_from_nmis overwrite=1 nodes=$node";
	print "importNodeFromNmis: $command\n" if $debug;
	if ( $simulate ) {
		print "SIMULATE: importNodeFromNmis nodes=$node\n";
	}
	else {
		my $result = `$command 2>&1`;
		print "importNodeFromNmis $node: $result\n" if $debug;
		if ( $result =~ /Success/ ) {
			return 1;
		}
		else {
			return 0;
		}
	}
}

# ask opnode_admin for a list of known nodes
# returns plain list of node names
sub getNodeList
{
	my @nodes;

	open(P, "$opnodeadmin act=list 2>&1 |")
			or die "cannot run opnode_admin.pl: $!\n";
	for my $line (<P>)
	{
		chomp $line;

		if ( $line !~ /^(Node Names:|=+)$/ )
		{
			push(@nodes,$line);
		}
	}
	close(P);
	die "opnode_admin failed: $!" if ($? >> 8);
	return \@nodes;
}

sub getNodeDetails
{
	my ($node) = @_;

	if (!$node)
	{
		print "ERROR cannot get node details without node!\n";
		return undef;
	}

	# stuff from stderr won't be valid json, ever.
	my $data = `$opnodeadmin act=export node=\"$node\"`;
	if (my $res = $? >> 8)
	{
		print "ERROR cannot get node $node details: $data\n";
		return undef;
	}

	return JSON::XS->new->decode($data);
}
