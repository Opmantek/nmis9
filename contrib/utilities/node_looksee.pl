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
use Cwd 'abs_path';

use Data::Dumper;
use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use RRDs 1.000.490; # from Tobias

my $defaultConf = "$FindBin::Bin/../../conf";
$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n";

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

# get an NMIS config and create an NMISNG object ready for use.
if ( not defined $cmdline->{conf}) {
    $cmdline->{conf} = $defaultConf;
}
else {
    $cmdline->{conf} = abs_path($cmdline->{conf});
}

print "Configuration Directory = '$cmdline->{conf}'\n" if ($debug);
# load configuration table
our $config = NMISNG::Util::loadConfTable(dir=>$cmdline->{conf}, debug=>$debug);

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

			print "Configuration Data for $node:\n" . Dumper $configuration;

			my $catchall_data = $inventory->data();
			print "Catch All Data for $node:\n" . Dumper $catchall_data;

			my $GTT = $S->loadGraphTypeTable(index=>undef);
			print "Graph Type Table $node:\n" . Dumper $GTT;


			my $last_poll = $catchall_data->{last_poll};

			my $beginTimespan = "00";
			my $endTimespan   = "24";
			my $now = time();
			my $start = $now - 5 * 86400;
			my $end = $now;
			#my $beginTimespan = $last_poll;
			#my $endTimespan   = $last_poll;
			#my $now = time();
			#my $start = $last_poll;
			#my $end = $last_poll;
			my $graphtype = "nodehealth";
			my $db = $S->makeRRDname(graphtype => $graphtype, index=>undef, item=>undef);
			#my $nodehealth  = NMISNG::rrdfunc::getRRDasHash(database => $db, add_minmax => 1, mode => "LAST");
			my $nodehealth  = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>$graphtype, mode=>"LAST", start => $start, end => $end,
											hour_from => $beginTimespan, hour_to => $endTimespan, index=>undef, item=> undef, truncate => -1);
			print "nodehealth Output:\n";
			print "\$last_poll = $last_poll\n";
			print Dumper $nodehealth;

        }

		#print Dumper $nodeobj;
    }
}



