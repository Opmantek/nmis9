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
our $VERSION="1.1.0";
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Data::Dumper;
use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use RRDs 1.000.490; # from Tobias

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

my $config = NMISNG::Util::loadConfTable( dir => "$FindBin::Bin/../conf", debug => $debug, info => undef);

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log => $logger);

my $simulate = 1;
$simulate =  NMISNG::Util::getbool( $cmdline->{simulate} ) if defined $cmdline->{simulate};

my $run = 0;
$run =  NMISNG::Util::getbool( $cmdline->{run} ) if defined $cmdline->{run};

my $totalNodes;

if ( not $run ) {
	usage();
}

sub usage {
	print qq{
Usage: $0 run=(true|false) node=NODENAME debug=(1|2|3|4)

  run=true to make me run, otherwise you keep getting help.
  node=NODENAME, to only process a single node.
  debug, if you don't know what it means don't use it.

  This will set the overrides (Node Configuration) for the selected node to:
  * interfaces starting with the word tunnel will be set to 1.25 Gbps
  * HundredGigabit Sub-Interfaces containing the keywork CSM will be set to 1.00 Gbps

  Run an update on the node at the end.

};
	exit 1;
}

if ( defined $cmdline->{node} ) {
	processNode($nmisng,$cmdline->{node});
	print "Run an update on the nodes for the speeds to change e.g. to schedule for all nodes:\n";
	print "/usr/local/nmis9/bin/nmis-cli act=schedule job.type=update job.node=$cmdline->{node}\n";
}
else {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $config->{cluster_id} });
	my %seen;
    
	foreach my $node (sort @$nodes) {
		next if ($seen{$node});
		$seen{$node} = 1;
		processNode($nmisng,$node);
	}	
	print "Run an update on the nodes for the speeds to change e.g. to schedule for all nodes:\n";
	print "/usr/local/nmis9/bin/nmis-cli act=schedule job.type=update\n";
}

sub processNode {
	my $nmisng = shift;
	my $node = shift;

	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {

        # is the node active?
		my ($configuration,$error) = $nodeobj->configuration();
		my $active = $configuration->{active};

		my ($overrides,$error) = $nodeobj->overrides();
		
		#print Dumper $configuration if $debug;

		# Only locals and active nodes
		if ($active and $nodeobj->cluster_id eq $config->{cluster_id} ) {

			++$totalNodes;

			my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			eval {
				$S->init(name=>$node);
			}; if ($@) # load node info and Model if name exists
			{
				print "Error init for $node";
				next;
			}

			my ($inventory,$error) = $S->inventory(concept => 'catchall');
			if ($error) {
				print STDERR "failed to instantiate catchall inventory: $error\n";
				next;
			}

			my $catchall_data = $inventory->data();
			#print "Catch All Data for $node:\n" . Dumper $catchall_data if $debug;
			#print "$node sysLocation: $catchall_data->{sysLocation}\n";

			# lets look at interfaces
			my $ids = $S->nmisng_node->get_inventory_ids(
				concept => "interface",
				filter => { historic => 0 });

			if (@$ids)
			{				
				for my $interfaceId (@$ids)
				{
						my ($interface, $error) = $S->nmisng_node->inventory(_id => $interfaceId);
						if ($error)
						{
							print "Failed to get inventory $interfaceId: $error\n";
							next;
						}
						my $data = $interface->data();

						my $ifDescr = $data->{ifDescr};
						my $Description = $data->{Description};

						print "Processing $node ifDescr=$ifDescr Description=$Description\n";
						
						#set speeds here
						if ( $node eq "asgard_AT_OPTESTS" and $ifDescr =~ /^Tunnel1$/ ) {
							$overrides->{$ifDescr}{ifSpeed} = 1250000;
							$overrides->{$ifDescr}{ifSpeedIn} = 1250000;
							$overrides->{$ifDescr}{ifSpeedOut} = 1250000;
						}
						elsif ( $ifDescr =~ /^tunnel/ ) {
							$overrides->{$ifDescr}{ifSpeed} = 1250000000;
							$overrides->{$ifDescr}{ifSpeedIn} = 1250000000;
							$overrides->{$ifDescr}{ifSpeedOut} = 1250000000;
						}
						# is this a HundredGig sub-interface and does it have the keyword in the name.
						elsif ( $ifDescr =~ /Hundred.+\.\d+/ and $Description =~ /CSM/ ) {
							$overrides->{$ifDescr}{ifSpeed} = 1000000000;
							$overrides->{$ifDescr}{ifSpeedIn} = 1000000000;
							$overrides->{$ifDescr}{ifSpeedOut} = 1000000000;
						}

						print Dumper $data if $debug;
				}
			}

			print Dumper $overrides if $debug;
			$nodeobj->overrides($overrides);

			#my $meta = {
			#		what => "Set node",
			#		who => $me,
			#		where => $nodes,
			#		how => "node_admin",
			#		details => "Set node(s) " . $nodes
			#};
			#(my $op, $error) = $nodeobj->save(meta => $meta);

			(my $op, $error) = $nodeobj->save();
			die "Failed to save $node: $error\n" if ($op <= 0); # zero is no saving needed	
			
			print STDERR "Successfully updated node $node.\n"
				if (-t \*STDERR);								# if terminal

        } # if active

    } # if nodeobj
}
		
		



