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
# find all duplicate catchall documents, remove both so a new one can be 
# created
use strict;
our $VERSION = "9.5.3";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
		print "version=$VERSION\n";
		exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;
use Mojo::File;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;
use Compat::Timing;

# Get setup
my $bn = basename($0);
my $usage = "Usage: $bn dryrun=0/1 (on by default)\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $dryrun = NMISNG::Util::getbool_cli("dryrun", $cmdline->{dryrun}, 1);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
																																										debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH"
																																 or !keys %$config);

# log to stderr
my $logfile = undef; #$config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one

# use debug or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																																 debug => $cmdline->{debug}) // $config->{log_level},
																														 path  => (defined $cmdline->{debug})? undef : $logfile);

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);

# do the work
$logger->info("Starting remove_catchall_duplicates dryrun=$dryrun");
my $result = remove_catchall_duplicates_using_cluster_id();
$logger->info("Finished, dryrun=$dryrun, removed records:".$result->{removed_records});
# done work


sub remove_catchall_duplicates_using_cluster_id {
	my $result;
	# find all catchalls, group them by node uuid, push information needed to remove duplicates, count matches
	# and only return where count > 1 (so there were duplicates)
	my ($entries, undef, $error) = NMISNG::DB::aggregate(
		collection => $nmisng->inventory_collection,
		pre_count_pipeline => [
			{ '$match' => { 'concept' => 'catchall' }},
						{ 
							'$group' => { '_id' => { 'node_uuid' => '$node_uuid'}, 
							'info' => { '$push' => { 'id' => '$_id', 'node_name' => '$node_name', 'cluster_id' => '$cluster_id' }},
							'count' => { '$sum' => 1 }}
						},
						{ '$match' => { 'count' => {'$gt' =>1 }}}
		 ],
		allowtempfiles => 1
	);
	die 'error:'.$error if($error);
	my $toret = { total => 0, duplicate_names => {}, duplicate_uuids => {}, removed_records => 0 };
	
	foreach my $entry (@$entries) {
		my $node_uuid = $entry->{_id}{node_uuid};
		my $nodeobj = $nmisng->node(uuid => $node_uuid);
		my $node_cluster_id = $nodeobj->cluster_id();
		$toret->{duplicate_uuids}->{$node_uuid}  = 1;

		# info here contains the nnode name, id and cluster id of hte matching catchall document
		# this list contains all catchalls for the node, just remove the ones that do not match
		# the cluster_id of the node
		foreach my $match (@{$entry->{info}}) {
			my $node_name = $match->{node_name};
			my $remove_id = $match->{id};
			$toret->{duplicate_names}->{$node_name}  = 1;
			if( $match->{cluster_id} ne $node_cluster_id) {
				$logger->info("Found Duplicate  - node:$node_name remove_id:$remove_id, bad cluster id $match->{cluster_id}");
			
				if( !$dryrun ) {
					my $object_id = NMISNG::DB::make_oid($remove_id);
					my $q = NMISNG::DB::get_query( and_part => {_id => $object_id}, no_regex => 1 );
					my $res = NMISNG::DB::remove( 
						collection => $nmisng->inventory_collection(),
						query      => $q,
					);
					$logger->error("Deleting of queue entry failed: $res->{error}") if ( !$res->{success} );
					$logger->error("Deletion failed: query did not match any records".Dumper($q)) if ( !$res->{removed_records} );
					$toret->{removed_records} += $res->{removed_records};
				} else {
					$logger->info("NOT deleting, dryrun is on");
					$toret->{removed_records}++;
				}
			}
		}	
	}	
	return $toret;
}

# this function is older, and a bit more brutal
# remove all catchall records for a node if it has duplicates
# the node will need an update to regenerate it completely
sub remove_catchall_duplicates {
	my ( $self, %args ) = @_;
	
	my $nodes_list = $nmisng->get_node_uuids();
	my %names;
	my $duplicates = 0;
	my $toret = { total => 0, duplicate_names => {}, duplicate_uuids => {}, removed_records => 0 };
	
	foreach my $uuid (@$nodes_list) {
		#print "Node $node \n";
		my $nodeobj = $nmisng->node(uuid => $uuid);
		my $ids = $nodeobj->get_inventory_ids( concept => 'catchall' );
		
		if (scalar(@$ids) > 1 ) {
			$logger->info("Node ".$nodeobj->name." has ".@$ids." catchalls which have ids: ".join(",", @$ids));
			$names{$nodeobj->name} = $uuid;
			$duplicates++;
			$toret->{duplicate_names}->{$nodeobj->name}  = 1;
			$toret->{duplicate_uuids}->{$uuid}  = 1;
			if( !$dryrun ) {
				$logger->info("Deleting duplicate catchalls (all)");
				my @object_ids = map { NMISNG::DB::make_oid($_) } @$ids;
				my $q = NMISNG::DB::get_query( and_part => {_id => \@object_ids}, no_regex => 1 );
				my $res = NMISNG::DB::remove( 
					collection => $nmisng->inventory_collection(),
					query      => $q,
				);
				$logger->error("Deleting of queue entry failed: $res->{error}") if ( !$res->{success} );
				$logger->error("Deletion failed: query did not match any records".Dumper($q)) if ( !$res->{removed_records} );
				$toret->{removed_records} += $res->{removed_records};
			} else {
				$logger->info("NOT deleting catchalls, dryrun is on");
				$toret->{removed_records} += scalar(@$ids);
			}
			# a new catchall is made by sys when update is run
		}
	}
	$toret->{total} = $duplicates;
	return $toret;
}
1;