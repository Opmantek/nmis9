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
our $VERSION="1.0.0";
use strict;

use FindBin;
use lib "$FindBin::RealBin/../lib";

use Data::Dumper;
use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
my $debug = $cmdline->{debug};

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $cmdline->{debug}, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log  => $logger);

my $debug = 0;

if ( defined $cmdline->{node} ) {
	oneNode($cmdline->{node});
}
else {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $config->{cluster_id} });
	my %seen;
	my $totalNodes;
    
    # define the output heading and the print format
	my @heading = ("node", "ifIndex", "ifIndex", "ifDescr", "Description", "ifInDiscardsProc", "ifInErrorsProc", "ifOutDiscardsProc", "ifOutErrorsProc");
	printRow(\@heading);

	foreach my $node (sort @$nodes) {
		next if ($seen{$node});
		$seen{$node} = 1;
			
		my $nodeobj = $nmisng->node(name => $node);
		if ($nodeobj) {
            
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
				return ( error => "failed to instantiate catchall inventory: $error") if ($error);

				my $catchall_data = $inventory->data();
				#if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {

				my $result = $S->nmisng_node->get_inventory_model(concept => "interface", filter => { historic => 0 });
				if (my $error = $result->error)
				{
					$nmisng->log->error("Failed to get inventory: $error");
					return(0,undef);
				}
				my %interfaces = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

				foreach my $ifIndex (keys %interfaces) {
					my $type = "pkts_hc";
					if (-f (my $rrdfilename = $S->makeRRDname(type => $type, index => $ifIndex))) {
						print "Processing $node $ifIndex $interfaces{$ifIndex}->{ifDescr} $interfaces{$ifIndex}->{Description} $rrdfilename\n" if $debug;
						# do I need $item?
						#my $rrd = $S->getDBName(graphtype => "pkts_hc", index => $ifIndex);
						my $use_threshold_period = $config->{"threshold_period-default"} || "-15 minutes";
						my $now = time();
						my $endHuman = NMISNG::Util::returnDateStamp($now);
						my $currentStats = Compat::NMIS::getSummaryStats(sys=>$S,type=>$type,start=>$use_threshold_period,end=>$now,index=>$ifIndex);
						print Dumper $currentStats if $debug;


						my $ifOutDiscardsProc = $currentStats->{$ifIndex}{ifOutDiscardsProc};
						my $ifOutErrorsProc = $currentStats->{$ifIndex}{ifOutErrorsProc};
						my $ifInDiscardsProc = $currentStats->{$ifIndex}{ifInDiscardsProc};
						my $ifInErrorsProc = $currentStats->{$ifIndex}{ifInErrorsProc};

						if ( $ifOutDiscardsProc > 0 or $ifOutErrorsProc > 0 or $ifInDiscardsProc > 0 or $ifInErrorsProc > 0 ) {
							my @row = ($node,$ifIndex,$interfaces{$ifIndex}->{ifDescr},$interfaces{$ifIndex}->{Description},$ifInDiscardsProc,$ifInErrorsProc,$ifOutDiscardsProc,$ifOutErrorsProc);
							printRow(\@row);							
						}
					}
				}
            }
        }
	}
}


sub printRow {
	my $data = shift;
	my $output = join("\",\"",@$data);
	print "\"$output\"\n";
}