#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
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
use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Spec;
use Data::Dumper;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;
use Notify::connectwiseconnector;
use Data::Dumper;
use RRDs;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Outage;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use NMISNG::Notify;

use Compat::NMIS;

if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$NMISNG::VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage       = "Usage: $thisprogram [option=value...] <act=command>

 * act=graphs - Will show loadGraphTypeTable
 * act=inventory - Will show node inventory
 * act=collect - Collect node (add stats=1 for per-component timing and DB op counts)
 * act=update - Update node (add stats=1 for per-component timing and DB op counts)
 * act=plugin - Run plugin ( node= op= plugin=)
 * act=model - Show model
 * act=escalations - Run escalations
 * act=thresholds - Run thresholds for a node (node= force=)
 * act=services - Run services for a node (node= force=)
 * act=gettable - Get data from a node (node= oid= query=)
 * act=get_tagged_datasets - The function returns different results based on the objective variable: If tagged is passed, it returns the datasets of a given subconcept that are tagged. If rrd_path is passed, it returns the RRD paths for the given subconcept.
 * act=adjust-to-new-cluster-id - Update cluster_id in all collections to match the current system cluster_id
 * act=recover-cluster-id - Detect the correct cluster_id from DB and write it back to config (dryrun=1 to preview)
\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);

my $wantverbose = (NMISNG::Util::getbool($Q->{verbose}));
my $wantquiet  = NMISNG::Util::getbool($Q->{quiet});

my $customconfdir = $Q->{dir}? $Q->{dir}."/conf" : undef;
my $C      = NMISNG::Util::loadConfTable(dir => $customconfdir,
										 debug => $Q->{debug});
die "no config available!\n" if (ref($C) ne "HASH" or !keys %$C);

# log to stderr if debug is given
my $logfile = $C->{'<nmis_logs>'} . "/cli.log";
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
										 debug => $Q->{debug} ) // $C->{log_level},
										 path  => (defined $Q->{debug})? undef : $logfile);

# this opens a database connection
my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
		);

# for audit logging
my ($thislogin) = getpwuid($<); # only first field is of interest

# show the daemon status
if ($Q->{act} =~ /^graph/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $result = testgraph(node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^inventory/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $result = testinventory(node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^get_tagged_datasets/)
{
	my $node = $Q->{node};
	my $datasets_tags = $Q->{datasets_tags};
	my $objective = $Q->{objective};
    die "Need a node to run " if (!$node);
	my $result = get_tagged_datasets(node => $node, datasets_tags => $datasets_tags, objective => $objective);
	exit 0;
}

elsif ($Q->{act} =~ /^model/)
{
	my $node = $Q->{node};
	die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node); 
	if ($nodeobj) {
		my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object		

		if( !$S->init(name=>$node) )
		{
		   print " Error init for $node\n, status:".Dumper($S->status);
       die;
		}
		my $mdl = $S->mdl();
		print Dumper($mdl);
	} else {
		 print " Could not find node $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^collect/)
{
	my $node = $Q->{node};

    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		my $wantstats = NMISNG::Util::getbool($Q->{stats});
		NMISNG::DB::reset_db_stats() if ($wantstats);

		my $pollTimer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 0;
		my $result = eval { $nodeobj->collect( wantsnmp => $wantsnmp, wantwmi => $wantwmi, force => $Q->{force} ) };
		if ($@) {
			print "Collect died: $@\n";
		} elsif (ref($result) eq "HASH" && $result->{error}) {
			print "Collect error: $result->{error}\n";
		}
		my $polltime = $pollTimer->elapTime();
		print "Collect finished in $polltime \n";

		print_benchmark_stats(nodeobj => $nodeobj, op => "collect") if ($wantstats);
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^update/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		my $wantstats = NMISNG::Util::getbool($Q->{stats});
		NMISNG::DB::reset_db_stats() if ($wantstats);

		my $updateTimer = Compat::Timing->new;
		my $result = eval { $nodeobj->update(force=> 1) };
		if ($@) {
			print "Update died: $@\n";
		} elsif (ref($result) eq "HASH" && $result->{error}) {
			print "Update error: $result->{error}\n";
		}
		my $updatetime = $updateTimer->elapTime();
		print "Update finished in $updatetime \n";

		print_benchmark_stats(nodeobj => $nodeobj, op => "update") if ($wantstats);
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^adjust-to-new-cluster-id/)
{
	my $new_cluster_id = $C->{cluster_id};
	die "No cluster_id found in config!\n" if (!$new_cluster_id);
	print "Adjusting all cluster_id values to: $new_cluster_id\n\n";

	my $total_matched = 0;
	my $total_modified = 0;

	# helper: update a collection and print results
	my $update_collection = sub {
		my (%args) = @_;
		my $name = $args{name};
		my $coll = $args{collection};
		my $set_fields = $args{set_fields};

		my $result = NMISNG::DB::update(
			collection => $coll,
			query      => {},
			record     => { '$set' => $set_fields },
			multiple   => 1,
			freeform   => 1,
		);
		if ($result->{success}) {
			printf("  %-20s matched: %d, modified: %d\n",
				$name, $result->{matched_records}, $result->{updated_records});
			$total_matched  += $result->{matched_records};
			$total_modified += $result->{updated_records};
		} else {
			print "  $name ERROR: $result->{error}\n";
		}
	};

	# fixed collections with a simple cluster_id field
	$update_collection->(
		name       => "nodes",
		collection => $nmisng->nodes_collection,
		set_fields => { cluster_id => $new_cluster_id },
	);

	# inventory has both cluster_id and path.0
	$update_collection->(
		name       => "inventory",
		collection => $nmisng->inventory_collection,
		set_fields => { cluster_id => $new_cluster_id, 'path.0' => NMISNG::Util::numify($new_cluster_id) },
	);

	$update_collection->(
		name       => "events",
		collection => $nmisng->events_collection,
		set_fields => { cluster_id => $new_cluster_id },
	);

	$update_collection->(
		name       => "status",
		collection => $nmisng->status_collection,
		set_fields => { cluster_id => $new_cluster_id },
	);

	$update_collection->(
		name       => "latest_data",
		collection => $nmisng->latest_data_collection,
		set_fields => { cluster_id => $new_cluster_id },
	);

	# enumerate and update all timed_* collections
	my $db = $nmisng->get_db();
	my $coll_cursor = NMISNG::DB::list_collections(db => $db);
	if ($coll_cursor) {
		while (my $coll_info = $coll_cursor->next) {
			my $coll_name = $coll_info->{name};
			next unless ($coll_name =~ /^timed_/);
			my $coll_handle = NMISNG::DB::get_collection(db => $db, name => $coll_name);
			if ($coll_handle) {
				$update_collection->(
					name       => $coll_name,
					collection => $coll_handle,
					set_fields => { cluster_id => $new_cluster_id },
				);
			} else {
				print "  $coll_name ERROR: could not get collection handle\n";
			}
		}
	} else {
		print "  WARNING: could not list collections to find timed_* tables\n";
	}

	print "\nTotal: matched $total_matched, modified $total_modified\n";
	exit 0;
}
elsif ($Q->{act} =~ /^recover-cluster-id/)
{
	my $dryrun = NMISNG::Util::getbool($Q->{dryrun});
	my $current_cluster_id = $C->{cluster_id};
	print "Current config cluster_id: $current_cluster_id\n\n";

	# count cluster_id occurrences in nodes and inventory
	my %node_counts;
	my %inv_counts;

	my $node_cids = NMISNG::DB::distinct(collection => $nmisng->nodes_collection, key => "cluster_id");
	if (ref($node_cids) eq "ARRAY") {
		for my $cid (@$node_cids) {
			$node_counts{$cid} = NMISNG::DB::count(
				collection => $nmisng->nodes_collection,
				query      => { cluster_id => $cid },
			) // 0;
		}
	}

	my $inv_cids = NMISNG::DB::distinct(collection => $nmisng->inventory_collection, key => "cluster_id");
	if (ref($inv_cids) eq "ARRAY") {
		for my $cid (@$inv_cids) {
			$inv_counts{$cid} = NMISNG::DB::count(
				collection => $nmisng->inventory_collection,
				query      => { cluster_id => $cid },
			) // 0;
		}
	}

	print "Cluster ID distribution in nodes:\n";
	for my $cid (sort { $node_counts{$b} <=> $node_counts{$a} } keys %node_counts) {
		printf("  %-40s %d nodes\n", $cid, $node_counts{$cid});
	}
	print "  (no nodes found)\n" if (!keys %node_counts);

	print "\nCluster ID distribution in inventory:\n";
	for my $cid (sort { $inv_counts{$b} <=> $inv_counts{$a} } keys %inv_counts) {
		printf("  %-40s %d items\n", $cid, $inv_counts{$cid});
	}
	print "  (no inventory found)\n" if (!keys %inv_counts);

	# pick the most common cluster_id: prefer nodes, fall back to inventory
	my ($recovered_id) = sort { $node_counts{$b} <=> $node_counts{$a} } keys %node_counts;
	if (!$recovered_id) {
		($recovered_id) = sort { $inv_counts{$b} <=> $inv_counts{$a} } keys %inv_counts;
	}

	if (!$recovered_id) {
		print "\nNo cluster_id found in nodes or inventory, nothing to recover.\n";
		exit 1;
	}

	print "\nRecovered cluster_id: $recovered_id\n";

	if ($recovered_id eq $current_cluster_id) {
		print "Config already matches the most common cluster_id. No changes needed.\n";
		exit 0;
	}

	if ($dryrun) {
		print "Dry run: would update config cluster_id from $current_cluster_id to $recovered_id\n";
		exit 0;
	}

	# write the recovered cluster_id back to config using the standard pipeline
	my ($deep, undef) = NMISNG::Util::getConfDeep();
	$deep->{id}{cluster_id} = $recovered_id;
	my $error = NMISNG::Util::writeConfData(data => $deep);
	if ($error) {
		print "ERROR writing config: $error\n";
		exit 1;
	}

	print "Updated config cluster_id from $current_cluster_id to $recovered_id\n";
	exit 0;
}
elsif ($Q->{act} =~ /^escalations/)
{
	$nmisng->process_escalations;
	exit 0;
}
elsif ($Q->{act} =~ /^thresholds/) 
{
	my $node = $Q->{node};
	die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {	
		my $S = NMISNG::Sys->new(nmisng => $nmisng);
		if ( $S->init( node => $nodeobj, snmp => 0 ) )
		{
			$nmisng->compute_thresholds( sys => $S, running_independently => 1, force => $Q->{force} );
		} else {
			print "failed to instantiate Sys: " . $S->status->{error}."\n";
		}
	} else {
		print "no node object found for $node\n";
	}
}
elsif ($Q->{act} =~ /^plugin/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $op = $Q->{op} ? $Q->{op} . "_plugin" : "collect_plugin"; # collect or update
	my $which_plugin = $Q->{plugin} ? $Q->{plugin} : "ALL";
	
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		my $S = NMISNG::Sys->new(nmisng => $nmisng);
		$S->init(name=>$node);
		my ($status, @errors);
		my $ran_something = 0;
		for my $plugin ($nmisng->plugins)
		{
			if ($which_plugin =~ /ALL/ or $which_plugin =~ /$plugin/) {
				print "Plugin: $plugin \n";
				my $funcname = $plugin->can($op);
				next if ( !$funcname );
				$ran_something = 1;
				eval { ( $status, @errors ) = &$funcname( node => $node,
										sys => $S,
										config => $C,
										nmisng => $nmisng, ); };
				if ( $@ ) {
					print "Plugin eval failed: ".Dumper($@);
				}										
				print "Status $status \n";
				print "Errors ".Dumper(@errors)." \n";
			}
			
		}
		print "probably can't find plugin (or maybe it had errors), didn't run anything (turn on debug to see more info)\n" if(!$ran_something);
		
	} else {
		print "no node object\n";
	}
	exit 0;
}
# This is for reproduce OMK-8682		
elsif ($Q->{act} =~ /^dump-node/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	#use Cube;
	#my $cube = Cube->new("1", "2");
	if ($nodeobj) {
		my @a = (1..9);
		my $test = "'test";
		for (@a) {
			print Dumper($nodeobj);
			#print $_;
			#$nmisng->log->info(Dumper($cube));
		}

	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^services/)
{
	my $node = $Q->{node};
								
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);

	if ($nodeobj) {

		my $timer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 1;

		my $S = NMISNG::Sys->new(nmisng => $nodeobj->nmisng);
		if( !$S->init( node => $nodeobj,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $nodeobj->configuration->{polling_policy},
		)) {
			die "failed to init S\n";
		}
		my $catchall_inventory = $S->inventory( concept => 'catchall' );
		my $catchall_data = $catchall_inventory->data_live();

		# snmp needs it's session opened
		if ($nodeobj->configuration->{collect} && $S->status->{snmp_enabled} )
		{
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request for getarray, or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10, );
		}
		
		$nodeobj->collect_services( sys => $S,
														 snmp => NMISNG::Util::getbool( $catchall_data->{snmpdown} ) ? 'false' : 'true',
													 wmi => NMISNG::Util::getbool( $catchall_data->{wmidown} ) ? 'false' : 'true',
													 force => $Q->{force} // 0,
													 catchall_inventory => $catchall_inventory );		
		my $totaltime = $timer->elapTime();
		print "services finished in $totaltime \n";
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
	
}
elsif ($Q->{act} =~ /^gettable/)
{

	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);

	my $oid = $Q->{oid};
	my $query = $Q->{query};
	my $index = $Q->{index};

	if ($nodeobj) {

		my $timer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 1;

		my $S = NMISNG::Sys->new(nmisng => $nodeobj->nmisng);
		if( !$S->init( node => $nodeobj,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $nodeobj->configuration->{polling_policy},
		)) {
			die "failed to init S\n";
		}
		my $catchall_inventory = $S->inventory( concept => 'catchall' );
		my $catchall_data = $catchall_inventory->data_live();

		# snmp needs it's session opened
		if( $wantsnmp && $S->status->{snmp_enabled} && $oid )
		{
			my $SNMP = $S->snmp;
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request for getarray, or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10, );
			if ( my $table = $SNMP->getindex($oid) ) 
			{
				print Dumper($table);
			}
			else
			{
				if (my $error = $SNMP->error ) {
					print "SNMP Error: $error\n";				
				}
			}
		}elsif( $wantsnmp && $oid ) {
			print "wmi not enabled: ".Dumper($S->status);
		}
		if( $wantwmi && $S->status->{wmi_enabled} && $query ) {
			my ( $error, $data, $meta ) = $S->{wmi}->gettable(
				wql   => $query,
				index => $index
			);
			if( $error ) {
				print "WMI Error: $error\n";
				} else {
					print "meta:".Dumper($meta);
					print "data:".Dumper($data);
				}
		} elsif( $wantwmi && $query ) {
			print "wmi not enabled: ".Dumper($S->status);
		}
	} else {
		print "Can't find node $node\n";
	}

}
# Test snmp
sub testgraph
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test graph      ==========\n";
    print "==============================================\n";
 
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $args{node} ) {
        my $node = $args{node};
        my $nodeobj = $nmisng->node(name => $node);
         if ($nodeobj) {
			 my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			 eval {
                    $S->init(name=>$node);
            }; if ($@) # load node info and Model if name exists
			 {
                    print " Error init for $node\n";
                    die;
                }
			my $graphs = $S->loadGraphTypeTable();
			print Dumper($graphs);
		 }
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
}

sub testinventory
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test Inventory  ==========\n";
    print "==============================================\n";
 
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $args{node} ) {
        my $node = $args{node};
        my $nodeobj = $nmisng->node(name => $node);
         if ($nodeobj) {
			 my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			 eval {
                    $S->init(name=>$node);
            }; if ($@) # load node info and Model if name exists
			 {
                    print " Error init for $node\n";
                    die;
                }
			
			
			my $result = $nmisng->get_inventory_model(cluster_id => $nodeobj->cluster_id,
										node_uuid => $nodeobj->uuid );
			if (my $error = $result->error)
			{
				$nmisng->log->error("get inventory model failed: $error");
			}
			else 
			{
				for my $entry (@{$result->data})
				{
					print $entry->{concept} . " - " . $entry->{description} . "\n";
                    print $entry->{data}->{index} . "\n";
					print Dumper($entry->{subconcepts}) . "\n";
					#print Dumper($entry) . "\n";
				}
			}
		
		 }
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
}

sub get_tagged_datasets
{
	my %args = @_;
	my $node = $args{node};
	my $datasets_tags = $args{datasets_tags};
	my $debug = $args{debug};
	my $objective = $args{objective};

	# Parse datasets_tags array
	my @datasets_tags = split /,/, $args{datasets_tags};
	
	die "No datasets_tags provided\n"  unless @datasets_tags;
	print "==============   get_tagged_datasets ==========\n";
	##usuage ./dev-tools.pl act="get_tagged_datasets" node=Switch-2  datasets_tags="mem-free"  objective="tagged" debug=3
	my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $node ) {
		my $nodeobj = $nmisng->node(name => $node);
		my $node_uuid = $nodeobj->uuid;
		print "====================\$node =$node --- \@datasets_tags =".Dumper(@datasets_tags)."==========================\n";
		
		if (defined $node){
			my $result = $nodeobj->tagged_datasets_for_subconcept( datasets_tags => \@datasets_tags, objective => $objective);
			print "result=".Dumper($result);
		}

    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }

}

# Prints a benchmark report after a collect or update operation.
# Pulls:
#  - per-component times stored on catchall_data by Node::collect
#    (collect_node_data_time, collect_intf_data_time,
#    collect_systemhealth_data_time, collect_server_data_time,
#    handle_custom_alerts_time, collect_services_time)
#  - MongoDB call counts/times from NMISNG::DB stats
#  - inventory item counts per concept for context on the workload
# args: nodeobj (NMISNG::Node), op ("collect" or "update")
sub print_benchmark_stats
{
	my (%args) = @_;
	my $nodeobj = $args{nodeobj};
	my $op = $args{op} // "operation";

	print "\n=== Benchmark stats ($op on ".$nodeobj->name.") ===\n";

	# per-component timings are stashed on catchall inventory during collect
	my ($catchall_inventory, $cerror) = $nodeobj->inventory(concept => "catchall");
	if (!$cerror && $catchall_inventory)
	{
		my $cd = $catchall_inventory->data();
		my %timing_fields_by_op = (
			collect => [qw(
				collect_node_info_time
				collect_node_data_time
				collect_intf_data_time
				collect_systemhealth_data_time
				collect_cbqos_time
				collect_server_data_time
				handle_custom_alerts_time
				collect_services_time
				compute_reachability_time
				compute_thresholds_time
				collect_plugins_time
			)],
			update => [qw(
				update_node_info_time
				update_intf_info_time
				collect_systemhealth_info_time
				update_concepts_time
				update_cbqos_time
				update_plugins_time
			)],
		);
		my @timing_fields = @{$timing_fields_by_op{$op} // []};
		my $any = 0;
		print "\n-- Per-component times (seconds) --\n";
		for my $f (@timing_fields)
		{
			next if (!defined $cd->{$f});
			printf("  %-40s %.4f\n", $f, $cd->{$f});
			$any = 1;
		}
		print "  (no per-component timing recorded)\n" if (!$any);
	}
	else
	{
		print "\n(could not load catchall inventory for per-component times: "
			.($cerror // "no inventory").")\n";
	}

	# inventory counts per concept give context for the workload size
	print "\n-- Inventory counts by concept --\n";
	my ($concepts) = $nodeobj->inventory_concepts();
	if (ref($concepts) eq "ARRAY")
	{
		for my $concept (sort @$concepts)
		{
			my $ids = $nodeobj->get_inventory_ids(concept => $concept);
			my $count = ref($ids) eq "ARRAY" ? scalar(@$ids) : 0;
			printf("  %-40s %d\n", $concept, $count);
		}
	}

	# MongoDB operation counts and cumulative times from DB::_start_time_and_count
	# note: these include the inventory_concepts/get_inventory_ids calls above,
	# but those are small and consistent across runs so still useful for A/B diffs.
	my $stats = NMISNG::DB::get_db_stats();
	print "\n-- MongoDB operations --\n";
	printf("  %-20s %10s %12s\n", "function", "count", "total_sec");
	my %allfns = map { $_ => 1 } (keys %{$stats->{counts}}, keys %{$stats->{times}});
	my $total_count = 0;
	my $total_time  = 0;
	for my $fn (sort keys %allfns)
	{
		my $c = $stats->{counts}{$fn} // 0;
		my $t = $stats->{times}{$fn}  // 0;
		$total_count += $c;
		$total_time  += $t;
		printf("  %-20s %10d %12.4f\n", $fn, $c, $t);
	}
	printf("  %-20s %10d %12.4f\n", "TOTAL", $total_count, $total_time);

	print "\n=== End benchmark stats ===\n";
}

