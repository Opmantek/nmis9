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
use lib "$FindBin::RealBin/../lib";

use Data::Dumper;
use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use RRDs 1.000.490; # from Tobias

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);

my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log => $logger);

my $simulate = 1;
$simulate =  NMISNG::Util::getbool( $cmdline->{simulate} ) if defined $cmdline->{simulate};

my $run = 0;
$run =  NMISNG::Util::getbool( $cmdline->{run} ) if defined $cmdline->{run};

my $hardLimit = 1250000000;

# set the hard limit to be used by default.
my $hard = 1;
$hard =  NMISNG::Util::getbool( $cmdline->{hard} ) if defined $cmdline->{hard};


my $qrDown = qr/ds\[(FlowFluxDownBytes)\]\.max/;
my $qrUp = qr/ds\[(FlowFluxUpBytes)\]\.max/;
my $section = "GponUserTraffic";
my $totalNodes;

if ( not $run ) {
	usage();
}

sub usage {
	print qq{
Usage: $0 run=(true|false) hard=(true|false) simulate=(true|false) node=NODENAME debug=(1|2|3|4)

  run=true to make me run, otherwise you keep getting help.
  hard is true by default, so system will use the $hardLimit value for speed limiting.
  node=NODENAME, to only process a single node.
  simulate is false by default, so system will not change until told to.
  debug, if you don't know what it means don't use it.

};
	exit 1;
}

if ( defined $cmdline->{node} ) {
	processNode($nmisng,$cmdline->{node});
}
else {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $config->{cluster_id} });
	my %seen;
    
	foreach my $node (sort @$nodes) {
		next if ($seen{$node});
		$seen{$node} = 1;
		processNode($nmisng,$node);
	}
}

sub processNode {
	my $nmisng = shift;
	my $node = shift;

	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {

        # is the node active?
		my ($configuration,$error) = $nodeobj->configuration();
		my $active = $configuration->{active};
		
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

			# Skip if this is NOT a Huawei MA5600?
			if ( $catchall_data->{nodeModel} !~ /Huawei-MA5600/ ) {
				print "Skipping $node, not a Huawei-MA5600\n" if $debug > 2;
				next;
			}

			if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
				print "node $node is down\n" if $debug;
				next;
			}

			# OK, get the GPON's and check their RRD's
			my $gponids = $S->nmisng_node->get_inventory_ids(
				concept => $section,
				filter => { historic => 0 });

			if (@$gponids) {
				print "Working on $node $section\n" if $debug;

				for my $gponid (@$gponids)
				{
					my ($gponinventory,$error) = $S->nmisng_node->inventory(_id => $gponid);
					if ($error)
					{
						print STDERR "Failed to get inventory $gponid: $error\n";
						next;
					}
					my $gpondata = $gponinventory->data; # r/o copy, must be saved back if changed
					processRrdFile($S,$section,$gpondata->{index},$gpondata->{InbTrafficTableN},$gpondata->{OutbTrafficTableN});
				}
			}
			else {
				print STDERR "Error, no inventory data found for $section\n";	
			}

        }
    }
}

#ds[FlowFluxDownBytes].index = 0
#ds[FlowFluxDownBytes].type = "COUNTER"
#ds[FlowFluxDownBytes].minimal_heartbeat = 1800
#ds[FlowFluxDownBytes].min = 0.0000000000e+00
#ds[FlowFluxDownBytes].max = NaN
#ds[FlowFluxDownBytes].last_ds = "2001164930177"
#ds[FlowFluxDownBytes].value = 0.0000000000e+00
#ds[FlowFluxDownBytes].unknown_sec = 0
#ds[FlowFluxUpBytes].index = 1
#ds[FlowFluxUpBytes].type = "COUNTER"
#ds[FlowFluxUpBytes].minimal_heartbeat = 1800
#ds[FlowFluxUpBytes].min = 0.0000000000e+00
#ds[FlowFluxUpBytes].max = NaN
#ds[FlowFluxUpBytes].last_ds = "460121440877"
#ds[FlowFluxUpBytes].value = 0.0000000000e+00
#ds[FlowFluxUpBytes].unknown_sec = 0
#ds[InbTrafficTableN].index = 2
#ds[InbTrafficTableN].type = "GAUGE"
#ds[InbTrafficTableN].minimal_heartbeat = 1800
#ds[InbTrafficTableN].min = NaN
#ds[InbTrafficTableN].max = NaN
#ds[InbTrafficTableN].last_ds = "5000000"
#ds[InbTrafficTableN].value = 1.9896826400e+09
#ds[InbTrafficTableN].unknown_sec = 0
#ds[OutbTrafficTableN].index = 3
#ds[OutbTrafficTableN].type = "GAUGE"
#ds[OutbTrafficTableN].minimal_heartbeat = 1800
#ds[OutbTrafficTableN].min = NaN
#ds[OutbTrafficTableN].max = NaN
#ds[OutbTrafficTableN].last_ds = "40000000"
#ds[OutbTrafficTableN].value = 1.5917461120e+10
#ds[OutbTrafficTableN].unknown_sec = 0

#ds[InbTrafficTableN].last_ds = "5000000"
#ds[OutbTrafficTableN].last_ds = "40000000"

sub processRrdFile {
	my $S = shift;
	my $section = shift;
	my $index = shift;
	my $InbTrafficTableN = shift;
	my $OutbTrafficTableN = shift;

	# get the RRD file name to use for storage.
	my $dbname = $S->makeRRDname( graphtype => $section, index => $index );

	if ( -f $dbname ) {
		my $hash = RRDs::info($dbname);

		print "  section=$section index=$index dbname=$dbname\n" if $debug > 1;
									
		# Recurse over the hash to see what you can find.
		foreach my $key (sort keys %$hash){
			# Is this an RRD DS (data source)
			if ( $key =~ /^ds/ ) {
				# Is this the DS's we are intersted in?
				if ( $key =~ /$qrDown/ ) {
					print "$key = $hash->{$key}\n" if $debug > 2;

					my $desiredDownMax = int($InbTrafficTableN/4);
					if ( $hard ) {
						$desiredDownMax = $hardLimit;	
					}
					tuneRrd($dbname,"FlowFluxDownBytes",$index,$hash->{$key},$desiredDownMax);
				}
				elsif ( $key =~ /$qrUp/ ) {
					print "$key = $hash->{$key}\n" if $debug > 2;

					my $desiredUpMax = int($OutbTrafficTableN/4);
					if ( $hard ) {
						$desiredUpMax = $hardLimit;	
					}
					tuneRrd($dbname,"FlowFluxUpBytes",$index,$hash->{$key},$desiredUpMax);
				}
			}
		}			
	}
	else {

	}
}

sub tuneRrd {
	my $dbname = shift;
	my $thing = shift;
	my $index = shift;
	my $current = shift;
	my $desired = shift;

	my $pre = "";
	$pre = "Simulate " if $simulate;

	if ( $current != $desired ) {
		print "  $pre Tuning $thing required of $index from $current to $desired\n" if $debug or $simulate;
		if ( not $simulate ) {
			RRDs::tune($dbname, "--maximum", "$thing:$desired");
		}
	}
	else {
		print "  NO Tuning $thing required of $index from $current to $desired\n" if $debug;
	}

}

