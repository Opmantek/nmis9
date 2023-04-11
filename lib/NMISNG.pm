#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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

# Package giving access to nodes, etc.
# Two basic ways to grab info, via get*Model functions which return ModelData objects
# or directly via the object
package NMISNG;

our $VERSION = "9.4.2";

use strict;
use Data::Dumper;
use Tie::IxHash;
use File::Find;
use File::Spec;
use File::Temp;
use File::Path;
use File::Copy;
use List::Util 1.45;
use boolean;
use Fcntl qw(:DEFAULT :flock :mode);    # this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Errno qw(EAGAIN ESRCH EPERM);
use Mojo::File;                         # slurp and spurt
use JSON::XS;
use Archive::Zip 1.36;					# for dump()/undump()

use NMISNG::DB;
use NMISNG::Events;
use NMISNG::Status;
use NMISNG::Log;
use NMISNG::ModelData;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::NetworkStatus;
use NMISNG::SQoS;

use Compat::Timing;

# params:
#  config - hash containing object
#  log - NMISNG::Log object to log to, required.
#  db - mongodb database object, optional.
#  drop_unwanted_indices - optional, default is 0.
#
#  allow for instantiating a test collection in our $db for running tests
#  in a hashkey named 'tests' passed as arg to NMISNG->new()
#  by appending "_collection" to the subkey representing the NMISNG collection we want to test,
#    for example:
#	   NMISNG->new(tests => $args{tests});
sub new
{
	my ( $class, %args ) = @_;

	die "Config required" if ( ref( $args{config} ) ne "HASH" );
	die "Log required" if ( !$args{log} );

	my $self = bless(
		{   _config  => $args{config},
			_db      => $args{db},
			_log     => $args{log},
			_plugins => undef,           # sub plugins populates that on the go
		},
		$class
	);

	my $db = $args{db};
	if ( !$db )
	{
		# get the db setup ready, indices and all
		# nodes uses the SHARED COMMON database, NOT a module-specific one!
		my $conn = NMISNG::DB::get_db_connection( conf => $self->config );
		if ( !$conn )
		{
			my $errmsg = NMISNG::DB::get_error_string;
			$self->log->fatal("cannot connect to MongoDB: $errmsg");
			die "cannot connect to MongoDB: $errmsg\n";
		}
		$db = $conn->get_database( $self->config->{db_name} );
	}

	# park the db handle for future use, note: this is NOT the connection handle!
	$self->{_db} = $db;

	# allow for instantiating a test collection in our $db for running tests:
	my $tests = $args{tests};
	# load and prime the statically defined collections
	for my $default_collname (qw(nodes events inventory latest_data queue opstatus status remote ))
	{
		#  allow for instantiating a test collection in our $db for running tests:
		my $collname = $tests->{"${default_collname}_test_collection"};
		if (!$collname)
		{
			$collname = $default_collname;
		}
		my $collhandle = NMISNG::DB::get_collection( db => $db, name => $collname );
		if ( ref($collhandle) ne "MongoDB::Collection" )
		{
			my $msg = "Could not get collection $collname: " . NMISNG::DB::get_error_string;
			$self->log->fatal($msg);
			die "Failed to get Collection $collname, msg: $msg\n"
				;    # database errors on that level are not really recoverable
		}

		# tell mongodb to prefer numeric
		$collhandle = $collhandle->with_codec( prefer_numeric => 1 );

		# figure out if index dropping is allowed for a given collection (by name)
		# needs to be disabled for collections that are shared across products
		my $dropunwanted = $args{drop_unwanted_indices};
		$dropunwanted = 0
			if ($dropunwanted
			and ref( $self->{_config}->{db_never_remove_indices} ) eq "ARRAY"
			and grep( $_ eq $default_collname, @{$self->{_config}->{db_never_remove_indices}} ) );

		# now prime the indices and park the collection handles in self - the coll accessors do that
		my $setfunction = "${default_collname}_collection";
		$self->$setfunction( $collhandle, $dropunwanted );
	}

	return $self;
}

###########
# Private:
###########

# tiny helper that returns one of two threshold period configurations
# args: self, subconcept (both required)
# returns: rrd-style time period
sub _threshold_period
{
	my ( $self, %args ) = @_;

	for my $maybe ( $args{subconcept}, "default" )
	{
		return $self->config->{"threshold_period-$maybe"} if ( $self->config->{"threshold_period-$maybe"} );
	}
	return "-15 minutes";
}

###########
# Public:
###########

# fixme9: where should this function go? not ideal here, should become node method
#
# performs the threshold value checking and event raising for
# one or more threshold configurations
# uses latest_data to get derived_data(stats) which should hold the stats with the correct
# period calculated at the last poll cycle
# args: self, sys, type, thrname (arrayref), index, item, class, inventory (all required),
# table (required hashref but may be empty),
# type is subconcept
# returns: nothing but raises/clears events (via thresholdProcess) and updates table
#  formerly runThrhld
sub applyThresholdToInventory
{
	my ( $self, %args ) = @_;

	my $S         = $args{sys};
	my $inventory = $args{inventory};
	my $M         = $S->mdl;

	my $sts     = $args{table};
	my $type    = $args{type};
	my $thrname = $args{thrname};
	my $index   = $args{index};
	my $item    = $args{item};
	my $class   = $args{class};
	my $stats;
	my $element;
	die "cannot applyThresholdToInventory on something with no inventory, subconcept:$type,index:$index"
		if ( !$inventory );

	$self->log->debug2( "WORKING ON Threshold for thrname="
			. join( ",", @$thrname )
			. " type=$type index=$index item=$item, inventory_id:"
			. $inventory->id );

	my $data = $inventory->data();

	#	check if values are already in table - fixme9: doSummaryBuild is gone, table is never populated anymore
	if ( exists $sts->{$S->{name}}{$type} )
	{
		$stats = $sts->{$S->{name}}{$type};
	}
	else
	{
		# stats have already been calculated and stored in derived data, the threshold_period
		# should have been used on them then, so just look up the last value
		my $latest_data_ret = $inventory->get_newest_timed_data();
		if ( $latest_data_ret->{success} )
		{
			$stats = $latest_data_ret->{derived_data}{$type};
			$self->log->debug2("Using stats from newest timed data for subconcept=$type");
		}
		else
		{
			die "could not get latest_data for inventory: subconcept:$type, index:$index";
		}
	}

	if ( $index eq '' )
	{
		$element = '';
	}
	else
	{
		$element = $inventory->description;
	}

	NMISNG::Util::TODO("Inventory will require description to be accurate");
	NMISNG::Util::TODO("Inventory cbqos needs to be figured out after it's timed_data is complete");

	# elsif ( $index ne '' and $thrname =~ /^hrsmpcpu/ )
	# {
	# 	$element = "CPU $index";
	# }
	# elsif ( $index ne '' and $thrname =~ /^hrdisk/ )
	# {
	# 	$inventory = $S->inventory( concept => 'storage', index => $index );
	# 	$data = ( $inventory ) ? $inventory->data : {};
	# 	$element = "$data->{hrStorageDescr}";
	# }
	# elsif ( $type =~ /cbqos|interface|pkts/ )
	# {
	# 	#inventory keyed by index and ifDescr so we need partial
	# 	my $inventory = $S->inventory( concept => 'interface', index => $index, partial => 1 );
	# 	$data = ( $inventory ) ? $inventory->data : {};
	# 	if( $data->{ifDescr} )
	# 	{
	# 		$element = $data->{ifDescr};
	# 		$element = "$data->{ifDescr}: $item" if($type =~ /cbqos/);
	# 	}
	# }
	# elsif ( defined $M->{systemHealth}{sys}{$type}{indexed}
	# 	and $M->{systemHealth}{sys}{$type}{indexed} ne "true" )
	# {
	# 	NMISNG::Util::TODO("Inventory migration not complete here (and below)");
	# 	my $elementVar = $M->{systemHealth}{sys}{$type}{indexed};
	# 	$inventory = $S->inventory( concept => $type, index => $index );
	# 	$data = ($inventory) ? $inventory->data() : {};
	# 	$element = $data->{$elementVar} if ($data->{$elementVar} ne "" );
	# }
	if ( $element eq "" )
	{
		$element = $index;
	}

	# walk through threshold names
	foreach my $nm (@$thrname)
	{
		$self->log->debug2("processing threshold $nm");

		# check for control_regex
		if (    defined $M->{threshold}{name}{$nm}
			and $M->{threshold}{name}{$nm}{control_regex} ne ""
			and $item ne "" )
		{
			if ( $item =~ /$M->{threshold}{name}{$nm}{control_regex}/ )
			{
				$self->log->debug2("MATCHED threshold $nm control_regex MATCHED $item");
			}
			else
			{
				$self->log->debug2("SKIPPING threshold $nm: $item did not match control_regex");
				next();
			}
		}

		# fixme errors are ignored
		my $levelinfo = $S->translate_threshold_level(
			type => $type,
			thrname => $nm,
			stats   => $stats,
			index   => $index,
			item    => $item
		);

		# get 'Proactive ....' string of Model
		my $event = $S->parseString( string => $M->{threshold}{name}{$nm}{event}, index => $index, eval => 0 );

		my $details = "";
		my $spacer  = "";

		if ( $type =~ /interface|pkts/ && $data->{Description} ne "" )
		{
			$details = $data->{Description};
			$spacer  = " ";
		}

		### 2014-08-27 keiths, display human speed and handle ifSpeedIn and ifSpeedOut
		if (    NMISNG::Util::getbool( $self->config->{global_events_bandwidth} )
			and $type =~ /interface|pkts/
			and $inventory->ifSpeed ne "" )
		{
			my $ifSpeed = $inventory->ifSpeed();
			$ifSpeed = $inventory->ifSpeedIn  if ( $event =~ /Input/ );
			$ifSpeed = $inventory->ifSpeedOut if ( $event =~ /Output/ );
			$details .= $spacer . "Bandwidth=" . NMISNG::Util::convertIfSpeed($ifSpeed);
		}

		$self->thresholdProcess(
			sys          => $S,
			type         => $type,                           # crucial for event context
			event        => $event,
			level        => $levelinfo->{level},
			element      => $element,                        # crucial for context
			details      => $details,
			value        => $levelinfo->{level_value},
			thrvalue     => $levelinfo->{level_threshold},
			reset        => $levelinfo->{reset},
			thrname      => $nm,                             # crucial for context
			index        => $index,                          # crucial for context
			class        => $class,                          # crucial for context
			inventory_id => $inventory->id
		);
	}
}

# convenience-wrapper around compute_thresholds, used only in case threshold_poll_node
# is configured off. iterates over all active nodes and runs compute_thresholds on each.
#
# args: self
# returns: nothing
sub compute_all_thresholds
{
	my ( $self, %args ) = @_;

	# function should not be reached in these two cases
	if ( !NMISNG::Util::getbool( $self->config->{global_threshold} ) )
	{
		$self->log->error("Global thresholding is disabled, not computing any thresholds!");
		return;
	}
	elsif ( NMISNG::Util::getbool( $self->config->{threshold_poll_node} ) )
	{
		$self->log->warn("Thresholding is performed with nodes, not computing any thresholds now.");
		return;
	}

	my $activenodes = $self->get_nodes_model( filter => {"activated.NMIS" => 1} );
	if ( my $error = $activenodes->error )
	{
		$self->log->error("Failed to lookup active nodes: $error");
		return;
	}

	# anything to do?
	return if ( !$activenodes->count );

	my $gimme = $activenodes->objects;
	if ( !$gimme->{success} )
	{
		$self->log->error("Failed to instantiate nodes: $gimme->{error}");
		return;
	}

	for my $nodeobj ( @{$gimme->{objects}} )
	{
		my $S = NMISNG::Sys->new(nmisng => $self);
		if ( !$S->init( node => $nodeobj, snmp => 0 ) )
		{
			$self->log->error( "failed to instantiate Sys: " . $S->status->{error} );
			next;
		}
		$self->compute_thresholds( sys => $S, running_independently => 1 );
	}
	return;
}

# this function computes overall metrics for all nodes/groups
# args: self
# returns: hashref, keys success/error - fixme9 error handling incomplete
sub compute_metrics
{
	my ( $self, %args ) = @_;

	# this needs a sys object in 'global'/non-node/nmis-system mode
	my $S = NMISNG::Sys->new(nmisng => $self);
	$S->init;

	my $pollTimer = Compat::Timing->new;
	$self->log->debug2(&NMISNG::Log::trace()."Starting");
	
	my $network_status = NMISNG::NetworkStatus->new( nmisng => $self );
	my $overallStatus = $network_status->overallNodeStatus( );
	
	# Doing the whole network - this defaults to -8 hours span
	my $groupSummary = $network_status->getGroupSummary();
	my $status       = Compat::NMIS::statusNumber( $overallStatus );
	my $data         = {};

	$data->{status}{value}       = $status;
	$data->{reachability}{value} = $groupSummary->{average}{reachable};
	$data->{availability}{value} = $groupSummary->{average}{available};
	$data->{responsetime}{value} = $groupSummary->{average}{response};
	$data->{health}{value}       = $groupSummary->{average}{health};
	$data->{intfCollect}{value}  = $groupSummary->{average}{intfCollect};
	$data->{intfColUp}{value}    = $groupSummary->{average}{intfColUp};
	$data->{intfAvail}{value}    = $groupSummary->{average}{intfAvail};

	# RRD options
	$data->{reachability}{option} = "gauge,0:100";
	$data->{availability}{option} = "gauge,0:100";
	### 2014-03-18 keiths, setting maximum responsetime to 30 seconds.
	$data->{responsetime}{option} = "gauge,0:30000";
	$data->{health}{option}       = "gauge,0:100";
	$data->{status}{option}       = "gauge,0:100";
	$data->{intfCollect}{option}  = "gauge,0:U";
	$data->{intfColUp}{option}    = "gauge,0:U";
	$data->{intfAvail}{option}    = "gauge,0:U";

	$self->log->debug2(
		"Doing Network Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}"
	);

	$S->create_update_rrd( data => $data, type => "metrics", item => 'network' );
	for my $group (sort $self->get_group_names)
	{
		my $groupSummary = $network_status->getGroupSummary( group => $group );
		
		$overallStatus = $network_status->overallNodeStatus( group => $group  );
		my $status = Compat::NMIS::statusNumber( $overallStatus );

		my $data = {};
		$data->{reachability}{value} = $groupSummary->{average}{reachable};
		$data->{availability}{value} = $groupSummary->{average}{available};
		$data->{responsetime}{value} = $groupSummary->{average}{response};
		$data->{health}{value}       = $groupSummary->{average}{health};
		$data->{status}{value}       = $status;
		$data->{intfCollect}{value}  = $groupSummary->{average}{intfCollect};
		$data->{intfColUp}{value}    = $groupSummary->{average}{intfColUp};
		$data->{intfAvail}{value}    = $groupSummary->{average}{intfAvail};

		$self->log->debug2(
			"Doing group=$group Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}"
		);

		# logs any errors
		$S->create_update_rrd( data => $data, type => "metrics", item => $group);
	}
	$self->log->debug2(&NMISNG::Log::trace()."Finished");
	return {success => 1};
}

# returns config hash
sub config
{
	my ($self) = @_;
	return $self->{_config};
}

# maintenance function that captures and dumps relevant configuration data
# args: self
# returns: hashref with success/error, and file (=path to resulting file)
sub config_backup
{
	my ( $self, %args ) = @_;
	my $C = $self->config;

	$self->log->info("Starting Configuration Backup operation");
	my $backupdir = $C->{'<nmis_backups>'};
	if ( !-d $backupdir )
	{
		mkdir( $backupdir, 0700 ) or return {error => "Cannot create $backupdir: $!"};
	}

	return {error => "Cannot write to directory $backupdir, check permissions!"}
		if ( !-w $backupdir );
	return {error => "Cannot access directory $backupdir, check permissions!"}
		if ( !-r $backupdir or !-x $backupdir );

	# now let's take a new backup...
	my $backupprefix = "nmis-config-backup-";
	my $backupfilename = "$backupdir/$backupprefix" . POSIX::strftime( "%Y-%m-%d-%H%M", localtime ) . ".tar";

	# ...of a dump of all node configuration (from the database), which we stash temporarily in conf
	my $nodes        = $self->get_nodes_model();
	my $nodedumpfile = $C->{'<nmis_conf>'} . "/all_nodes.json";
	if ( !$nodes->error && @{$nodes->data} )
	{
		# ensure that the output is indeed valid json, utf-8 encoded
		Mojo::File->new($nodedumpfile)
			->spurt( JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode( $nodes->data ) );
	}

	# ...and of _custom_ models and configuration files (and the default ones for good measure)
	my @relativepaths
		= ( map { File::Spec->abs2rel( $_, $C->{'<nmis_base>'} ) }
			( $C->{'<nmis_models>'}, $C->{'<nmis_default_models>'}, $C->{'<nmis_conf>'}, $C->{'<nmis_conf_default>'} )
		);

	my $status = system( "tar", "-cf", $backupfilename, "-C", $C->{'<nmis_base>'}, @relativepaths );
	if ( $status == -1 )
	{
		return {error => "Failed to execute tar!"};
	}
	elsif ( $status & 127 )
	{
		return {error => "Backup failed, tar killed with signal " . ( $status & 127 )};
	}
	elsif ( $status >> 8 )
	{
		return {error => "Backup failed, tar exited with exit code " . ( $status >> 8 )};
	}

	# ...and the various cron files
	my $td = File::Temp::tempdir( CLEANUP => 1 );

	mkdir( "$td/cron", 0755 ) or return {error => "Cannot create $td/cron: $! "};
	system("cp -a /etc/cron* $td/cron/ 2>/dev/null");
	system("crontab -l -u root > $td/cron/root_crontab 2>/dev/null");
	system("crontab -l -u nmis > $td/cron/nmis_crontab 2>/dev/null");

	$status = system( "tar", "-C", $td, "-rf", $backupfilename, "cron" );
	if ( $status == -1 )
	{
		return {error => "Failed to execute tar!"};
	}
	elsif ( $status & 127 )
	{
		return {error => "Backup failed, tar killed with signal " . ( $status & 127 )};
	}
	elsif ( $status >> 8 )
	{
		return {error => "Backup failed, tar exited with exit code " . ( $status >> 8 )};
	}

	$status = system( "gzip", $backupfilename );
	if ( $status >> 8 )
	{
		return {error => "Backup failed, gzip exited with exit code " . ( $status >> 8 )};
	}
	unlink $nodedumpfile if ( -f $nodedumpfile );

	$self->log->info("Completed Configuration Backup operation, created $backupfilename.gz");
	return {success => 1, file => "$backupfilename.gz"};
}

# fixme9: where should this function go? this isn't a great spot...should become node method
#
# figures out which threshold alerts need to be run for one node, based on model
# delegates the evaluation work to applyThresholdToInventory, then updates info structures.
#
# args: self, sys (required), running_independently (optional, default 0)
# note: writes node info file and saves inventory if running_independently is 0
#
# returns: nothing
sub compute_thresholds
{
	my ( $self, %args ) = @_;

	my $S                     = $args{sys};
	my $running_independently = $args{running_independently};

	my $pollTimer     = Compat::Timing->new;
	my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events', conf => $self->config );
	my $sts           = {};

	my $M                  = $S->mdl;                                  # pointer to Model table
	my $catchall_inventory = $S->inventory( concept => 'catchall' );
	my $catchall_data      = $catchall_inventory->data_live();

	# skip if node down
	if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) )
	{
		$self->log->debug2("Node down, skipping thresholding for $S->{name}");
		return;
	}
	if ( !$S->nmisng_node->configuration->{threshold} )
	{
		$self->log->debug2("Node $S->{name} not enabled for thresholding, skipping.");
		return;
	}

	$self->log->debug("Starting Thresholding for node $S->{name}");

	# first the standard thresholds
	my $thrname = [qw(response reachable available)];
	$self->applyThresholdToInventory(
		sys       => $S,
		table     => $sts,
		type      => 'health',
		thrname   => $thrname,
		inventory => $catchall_inventory
	);

	# search for threshold names in Model of this node
	foreach my $s ( keys %{$M} )    # section name
	{
		# thresholds live ONLY under rrd, other 'types of store' don't interest us here
		my $ts = 'rrd';
		foreach my $type ( keys %{$M->{$s}{$ts}} )    # name/type of subsection
		{
			my $thissection = $M->{$s}->{$ts}->{$type};

			if ( !$thissection->{threshold} )
			{
				$self->log->debug2("section $s, type $type has no threshold");
				next;                                 # nothing to do
			}
			$self->log->debug2("section $s, type $type has a threshold");

			# get commasep string of threshold name(s), turn it into an array, unless it's already an array
			$thrname
				= ( ref( $thissection->{threshold} ) ne 'ARRAY' )
				? [split( /,/, NMISNG::Util::stripSpaces( $thissection->{threshold} ) )]
				: $thissection->{threshold};

			# attention: control expressions for indexed section must be run per instance,
			# and no more getbool possible (see below for reason)
			my $control = $thissection->{control};
			$self->log->debug2("control found:$control for section=$s type=$type") if ($control);

			# find all instances of this subconcept and try and run thresholding for them, doesn't matter if indexed
			# or not, this will run them all
			# cbqos stores subconcepts for classes, searching for subconcept here can't work, have to use concept
			my %callargs
				= ( $type =~ /cbqos/ )
				? ( concept => $type, filter => {enabled => 1, historic => 0} )
				: ( filter => {subconcepts => $type, enabled => 1, historic => 0} );

			# pass the modeldata object enough info to figure out what object to instantiate
			$callargs{nmisng} = $self;
			$callargs{class_name} = {"concept" => \&NMISNG::Inventory::get_inventory_class};

			my $inventory_model = $S->nmisng_node->get_inventory_model(%callargs);
			if ( my $error = $inventory_model->error )
			{
				$self->log->error("get inventory model failed: $error");
				return undef;
			}

			$self->log->debug2( "threshold="
					. join( ",", @$thrname )
					. " found in section=$s type=$type indexed=$thissection->{indexed}, count="
					. $inventory_model->count() );

			# turn the 'models' into objects so that parseString can use it if required
			my $objectresult = $inventory_model->objects;
			if ( !$objectresult->{success} )
			{
				$self->log->error("object access failed: $objectresult->{error}");
				return undef;
			}

			# these are now objects
			foreach my $inventory ( @{$objectresult->{objects}} )
			{
				my $data = $inventory->data;
				my $index = $data->{index} // undef;

				$self->log->debug4("threshold of type:$type, index:$index ".Dumper $inventory);

				if ($control
					&& !$S->parseString(
						string    => "($control) ? 1:0",
						sect      => $type,
						index     => $index,
						eval      => 1,
						inventory => $inventory
					)
					)
				{
					$self->log->debug2("threshold of type:$type, index:$index skipped by control=$control");
					next;
				}
				if ( $data->{threshold} && !NMISNG::Util::getbool( $data->{threshold} ) )
				{
					$self->log->debug2("skipping disabled threshold type:$type for index:$index");
					next;
				}
				$self->applyThresholdToInventory(
					sys       => $S,
					table     => $sts,
					type      => $type,
					thrname   => $thrname,
					index     => $index,
					inventory => $inventory
				);
			}
		}
	}

	my $count       = 0;
	my $countOk     = 0;
	my $status_md   = $S->nmisng_node->get_status_model();
	my $objects_ret = $status_md->objects();
	my $status_objs = $objects_ret->{objects} // [];
	if( !$objects_ret->{success} )
	{
		$self->log->error("Failed to get status data for node:".$S->nmisng_node->name." error:".$objects_ret->{error});
	}
	foreach my $status_obj (@$status_objs)
	{
		my $eventKey = $status_obj->event;
		$eventKey = "Alert: $eventKey"
			if ( $status_obj->is_alert );

		# event control is as configured or all true.
		my $thisevent_control = $events_config->{$eventKey} || {Log => "true", Notify => "true", Status => "true"};

		# if this is an alert and it is older than 1 full poll cycle, delete it from status.
		# fixme: this logic is broken for variable polling
		if ( $status_obj->lastupdate < time - 500 )
		{
			$status_obj->delete();
		}

		# in case of Status being off for this event, we don't have to include it in the calculations
		elsif ( not NMISNG::Util::getbool( $thisevent_control->{Status} ) )
		{
			$self->log->debug2(
				"Status Summary Ignoring: event=" . $status_obj->event
				. ", Status=$thisevent_control->{Status}");
			$status_obj->status("ignored");
			$status_obj->save();
			++$count;
			++$countOk;
		}
		else
		{
			++$count;
			if ( $status_obj->status eq "ok" )
			{
				++$countOk;
			}
		}
	}
	if ( $count and $countOk )
	{
		my $perOk = sprintf( "%.2f", $countOk / $count * 100 );
		$self->log->debug2("Status Summary = $perOk, $count, $countOk\n");
		$catchall_data->{status_summary} = $perOk;
		$catchall_data->{status_updated} = time();
	}

	# Save the new status results, but only if run standalone
	if ($running_independently)
	{
		$catchall_inventory->save();
	}

	$self->log->debug(&NMISNG::Log::trace()."Finished");
}

# this is a maintenance command for removing invalid database material
# (old stuff is automatically done via TTL index on expire_at)
#
# args: self,  simulate (default: false, if true only returns what it would do)
# returns: hashref, success/error and info (array ref)
sub dbcleanup
{
	my ( $self, %args ) = @_;

	my $simulate = NMISNG::Util::getbool( $args{simulate} );
	my $use_non_lookup_query;
	if (defined ($args{use_performance_query}))
	{
		$use_non_lookup_query = NMISNG::Util::getbool( $args{use_performance_query} );
	}
	else {
		$use_non_lookup_query = NMISNG::Util::getbool( $self->config->{use_performance_query});
	}
	# we want to remove:
	# all inventory entries whose node is gone,
	# all inventory entries whose node AND cluster is gone,
	# all events entries whose node AND cluster is gone,
	# all status entries whose node AND cluster is gone,
	# all latest_data entries whose node AND cluster is gone,
	# and all timed data whose inventory is gone.
	# note that for timed orphans we have no cluster_id;

	my @info;
	my $success = 1;
	my $nodes = $self->get_nodes_uuid_cluster_id({});
	push @info, "Starting Database cleanup";

	# ************************************
	# INVENTORY
	# ************************************
	push @info, "Looking for orphaned inventory records";
	my @ditchables;
	my @orfans;
	
	my $node_uuids = $self->get_node_uuids();

	my $q = NMISNG::DB::get_query( and_part => {'node_uuid' => {'$nin' => $node_uuids}} );
	my $invcoll = $self->inventory_collection;
	my $inventory = NMISNG::DB::find(
		collection  => $invcoll,
		query       => $q,
		fields_hash => {'_id' => 1}
	);

	my @all;
	while ( my $entry = $inventory->next )
	{
		push @all, $entry;
	}
	
	if ( defined $inventory )
	{
		@ditchables = map { $_->{_id} } (@all);
		push @info,
			"Cleanup would remove " . scalar(@ditchables) . " orphaned inventory records, in first instance.";
	}
	else 
	{
		push @info, "find failed: " . NMISNG::DB::get_error_string;
		$self->log->info("NMISNG dbcleanup find failed: ". NMISNG::DB::get_error_string);
		$success = 0;
	}
	
	# Now, find the inventory records which are linked to a node but the cluster_id is incorrect
	my ( $goners, undef, $error );
	if ($use_non_lookup_query)
	{
		$self->log->debug("NMISNG dbcleanup using non lookup query");
		( $goners, undef, $error ) = $self->get_cluster_orphans($invcoll, $nodes);
	} else {
		$self->log->debug("NMISNG dbcleanup using lookup query");
		( $goners, undef, $error )  = $self->get_cluster_orphans_with_lookup($invcoll);
	}
	
	if ($error)
	{
		push @info, "get_cluster_orphans for inventory failed: " . $error;
		$success = 0;
	}
	else
	{
		push @info,
			"Adding inventory records to remove " . scalar(@$goners);
		my %seen;
		@ditchables = grep( !$seen{$_}++, @ditchables, @$goners);
	}
	
	# second, remove those - possibly orphaning stuff that we should pick up
	if ( !@ditchables )
	{
		push @info, "No orphaned inventory records detected.";
	}
	elsif ($simulate)
	{
		push @info,
			"Cleanup would remove " . scalar(@ditchables) . " orphaned inventory records, but not in simulation mode.";
	}
	else
	{
		my $res = NMISNG::DB::remove(
			collection => $invcoll,
			query      => NMISNG::DB::get_query( and_part => {_id => \@ditchables}, no_regex => 1 )
		);
		if ( !$res->{success} )
		{
			push @info, "Failed to remove inventory instances: $res->{error}";
			$self->log->info("NMISNG dbcleanup Failed to remove inventory instances: $res->{error}");
			$success = 0;
		}
		push @info, "Removed $res->{removed_records} orphaned inventory records.";
		$self->log->info("Removed $res->{removed_records} orphaned inventory records.");
	}
	
	# ************************************
	# EVENTS
	# ************************************
	my $evcoll = $self->events_collection;
	if ($use_non_lookup_query)
	{
		( $goners, undef, $error ) = $self->get_cluster_orphans($evcoll, $nodes);
	} else {
		( $goners, undef, $error )  = $self->get_cluster_orphans_with_lookup($evcoll);
	}
	
	if ($error)
	{
		push @info, "get_cluster_orphans for events failed: " . $error;
		$success = 0;
	}
	else
	{
		if ( !$goners )
		{
			push @info, "No orphaned event records detected.";
		}
		elsif ($simulate)
		{
			push @info,
				"Cleanup would remove " . scalar(@$goners) . " orphaned event records, but not in simulation mode.";
		}
		else
		{
			my $res = NMISNG::DB::remove(
				collection => $evcoll,
				query      => NMISNG::DB::get_query( and_part => {_id => $goners}, no_regex => 1 )
			);
			if ( !$res->{success} )
			{
				push @info, "Failed to remove event instances: $res->{error}";
				$self->log->info("NMISNG dbcleanup Failed to remove event instances: $res->{error}");
				$success = 0;
			}
			push @info, "Removed $res->{removed_records} orphaned event records.";
			$self->log->info("Removed $res->{removed_records} orphaned event records.");
		}
	}
	
	# ************************************
	# STATUS
	# ************************************
	my $statuscoll = $self->status_collection;
	if ($use_non_lookup_query)
	{
		( $goners, undef, $error ) = $self->get_cluster_orphans($statuscoll, $nodes);
	} else {
		( $goners, undef, $error )  = $self->get_cluster_orphans_with_lookup($statuscoll);
	}
	
	if ($error)
	{
		push @info, "get_cluster_orphans for status failed: " . $error;
		$success = 0;
	}
	else
	{
		if ( !$goners )
		{
			push @info, "No orphaned status records detected.";
		}
		elsif ($simulate)
		{
			push @info,
				"Cleanup would remove " . scalar(@$goners) . " orphaned status records, but not in simulation mode.";
		}
		else
		{
			my $res = NMISNG::DB::remove(
				collection => $statuscoll,
				query      => NMISNG::DB::get_query( and_part => {_id => $goners}, no_regex => 1 )
			);
			if ( !$res->{success} )
			{
				push @info, "Failed to remove inventory instances: $res->{error}";
				$self->log->info("Failed to remove inventory instances: $res->{error}");
				$success = 0;
			}
			push @info, "Removed $res->{removed_records} orphaned status records.";
			$self->log->info("Removed $res->{removed_records} orphaned status records.");
		}
	}
	
	# ************************************
	# CONCEPTS
	# ************************************
	# third, determine what concepts exist, get their timed data collections
	# and verify those against the inventory - plus the latest_data look-aside-cache
	my $conceptnames = NMISNG::DB::distinct(
		collection => $self->inventory_collection,
		key        => "concept"
	);
	if ( ref($conceptnames) ne "ARRAY" )
	{
		return {
			error => "failed to determine distinct concepts!",
			info  => \@info
		};
	}
	for my $concept ( "latest_data", @$conceptnames )
	{
		my $timedcoll
			= $concept eq "latest_data"
			? $self->latest_data_collection
			: $self->timed_concept_collection( concept => $concept );
		next if ( !$timedcoll );    # timed_concept_collection already logs, ditto latest_data_collection

		my $collname = $timedcoll->name;

		push @info, "Looking for orphaned timed records for $concept";

		my ( $goners, undef, $error ) = NMISNG::DB::aggregate(
			collection          => $timedcoll,
			pre_count_pipeline  => undef,
			count               => undef,
			allowtempfiles      => 1,
			post_count_pipeline => [

				# link to inventory parent
				{   '$lookup' => {
						from         => $invcoll->name,
						localField   => "inventory_id",
						foreignField => "_id",
						as           => "parent"
					}
				},

				# then select the ones without parent
				{'$match' => {parent => {'$size' => 0}}},

				# then give me just the inventory ids
				{'$project' => {'_id' => 1}}
			]
		);
		if ($error)
		{
			push @info, "Failed to remove $concept docs: $error";
			$success = 0;
		}

		my @ditchables = map { $_->{_id} } (@$goners);
		# Get cluster_id orphans
		if ($concept eq "latest_data")
		{
			if ($use_non_lookup_query)
			{
				( $goners, undef, $error ) = $self->get_cluster_orphans($timedcoll, $nodes);
			} else {
				( $goners, undef, $error )  = $self->get_cluster_orphans_with_lookup($timedcoll);
			}
			if ($error)
			{
				push @info, "get_cluster_orphans for latest_data failed: " . $error;
				$success = 0;
			}
			else
			{
				push @info,
					  "cleanup would remove "
					. scalar(@$goners)
					. " orphaned timed $concept records in first instance.";
				my %latest_data_seen;
				@ditchables = grep( !$latest_data_seen{$_}++, @ditchables, @$goners);
			}
		}
		if ( !@ditchables )
		{
			push @info, "No orphaned $concept records detected.";
		}
		elsif ($simulate)
		{
			push @info,
				  "cleanup would remove "
				. scalar(@ditchables)
				. " orphaned timed $concept records, but not in simulation mode.";
		}
		else
		{
			my $res = NMISNG::DB::remove(
				collection => $timedcoll,
				query      => NMISNG::DB::get_query( and_part => {_id => \@ditchables}, no_regex => 1 )
			);
			if ( !$res->{success} )
			{
				push @info, "Failed to remove $concept instances: $res->{error}";
				$self->log->info("Failed to remove $concept instances: $res->{error}");
				$success = 0;
			}
			push @info, "removed $res->{removed_records} orphaned timed records for $concept.";
			$self->log->info("removed $res->{removed_records} orphaned timed records for $concept.");
		}
	}

	push @info, "Database cleanup complete";

	return {success => $success, info => \@info};
}

# Return an array of hashes including node_uuid and cluster_id
sub get_nodes_uuid_cluster_id
{
	my ( $self, $filter ) = @_;
	my $model_data = $self->get_nodes_model( $filter, fields_hash => {uuid => 1, cluster_id => 1} );
	my $data       = $model_data->data();
	my @uuids      = map { {uuid => $_->{uuid}, cluster_id => $_->{cluster_id}} } @$data;
	return \@uuids;
}

# Returns orphans that does not match node uuid and cluster id
sub get_cluster_orphans
{
	my ( $self, $collection, $nodes ) = @_;
	
	my @toRet 	   = ();
	$self->log->debug("NMISNG get_cluster_orphans: ". scalar(@$nodes) . " nodes");

# We cannot remove anything if we dont have nodes to compare
	if (scalar(@$nodes) > 0)
	{
		my $results = NMISNG::DB::find(
			collection  => $collection,
			query       => {},
			fields_hash => {'_id' => 1, 'node_uuid' => 1, 'cluster_id' => 1}
		);
		my @all;
		my $exist;
		my $processed;
		while ( my $entry = $results->next )
		{
			push @all, $entry;
		}
		if ( defined $results )
		{
			my $docs = $results->{result}->{_docs};
			$self->log->debug("NMISNG get_cluster_orphans: ". scalar(@all) . " documents");	
			foreach my $doc (@all)
			{
				# If this fields are not defined, we cannot add them
				next if (!defined $doc->{node_uuid} or !defined $doc->{cluster_id});
				
				$exist = 0;
				$processed = 0;
				
				foreach my $node (@$nodes)
				{
					# If some values are not defined, we cannot say, so cannot remove this record
					if (!defined $node->{uuid} or !defined $node->{cluster_id})
					{
						$processed++; # Make sure we compare at least one
						next;
					}

					if ($doc->{node_uuid} eq $node->{uuid} and $doc->{cluster_id} eq $node->{cluster_id})
					{
						$exist = 1;
						last;
					}
				}
				# Not found, so add it to remove
				if ($exist eq 0 and $processed < scalar(@$nodes))
				{
					push @toRet, $doc->{_id};
				}
			}
			$self->log->debug("NMISNG get_cluster_orphans: ". scalar(@toRet) . " documents to delete");
			# Make sure is not an error
			if (scalar(@toRet) eq scalar(@all))
			{
				$self->log->error("NMISNG get_cluster_orphans: Error in get docs for remove. Docs to remove same as all documents");
				return ((), undef, "Error in nodes record" );
			}
			return ( \@toRet, undef, undef );
		}
		else
		{
			$self->log->error("NMISNG get_cluster_orphans: Error getting documents " . NMISNG::DB::get_error_string);
			return ( \@toRet, undef, NMISNG::DB::get_error_string);
		}
	}
	$self->log->error("NMISNG get_cluster_orphans: Error. No nodes provided ");
	return ( \@toRet, undef, "Error getting nodes");
}

# Returns orphans that does not match node uuid and cluster id
# The aggregation fails when there are lots of documents
# That's why was rewrited above
sub get_cluster_orphans_with_lookup
{
	my ( $self, $collection ) = @_;
	my ( $goners, undef, $error ) = NMISNG::DB::aggregate(
		collection          => $collection,
		pre_count_pipeline  => undef,
		count               => undef,
		allowtempfiles      => 1,
		post_count_pipeline => [
			# link inventory to parent node
			{   '$lookup' => {
					from         => "nodes",
					localField   => "node_uuid",
					foreignField => "uuid",
					as           => "nodeData"
				}
			},
			{'$unwind' 	=> '$nodeData'},
			{'$project'	=> {
				'norfan'	=> {
					'$cond' => [ { '$eq' => [ '$cluster_id', '$nodeData.cluster_id' ] }, 1, 0 ]
					}
				}
			},
			# We want the ones than does not match
			{'$match' => {'norfan' => 0}},
			# then give me just the inventory ids
			{'$project' => {'_id' => 1}}
		]
	);
	my @ditchables = map { $_->{_id} } (@$goners);
	return ( \@ditchables, undef, $error );
}

# little helper that applies multiple node selection filters sequentially (ie. f1 OR f2)
# and returns the active nodes that match
#
# args: list of selectors, must be hashes
# returns: modeldata object with the matching nodes
sub expand_node_selection
{
	my ( $self, @selectors ) = @_;

	return $self->expand_node_selection_inactive_too(filter => \@selectors, onlyactive => 1);
}

# little helper that applies multiple node selection filters sequentially (ie. f1 OR f2)
# and returns the active nodes that match
#
# args: list of selectors, must be hashes
# returns: modeldata object with the matching nodes
sub expand_node_selection_inactive_too
{
	my ( $self, %args ) = @_;

	my ( $mdata, %lotsanodes );
	my $selectors = $args{filter};
	my $onlyactive = $args{onlyactive};
	
	for my $onefilter ( @$selectors ? @$selectors : {} )
	{
		return NMISNG::ModelData->new(
			nmisng => $self,
			error  => {"invalid filter structure, not a hash!"}
		) if ( ref($onefilter) ne "HASH" );

		$onefilter->{"activated.NMIS"} = 1 if ($onlyactive);    # never consider inactive nodes
		# Only locals!
		$onefilter->{"cluster_id"} = $self->config->{cluster_id};
	
		my $possibles = $self->get_nodes_model( filter => $onefilter );
		return NMISNG::ModelData->new(
			nmisng => $self,
			error  => {"node lookup failed: " . $possibles->error}
		) if ( $possibles->error );
		map { $lotsanodes{$_->{uuid}} //= $_ } ( @{$possibles->data} );

		# reuse the first one for the response
		$mdata //= $possibles;
	}

	$mdata->data( [values %lotsanodes] );
	return $mdata;
}

# ensure all indexes
sub ensure_indexes
{
	my ( $self, $drop_unwanted ) = @_;
	
	$self->log->info("NMISNG running ensure_indexes");
	
	# Event collection
	my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_events},
			drop_unwanted => $drop_unwanted,
			indices       => [

				# needed for joins
				[[node_uuid  => 1]],
				[{lastupdate => 1}, {unique => 0}],
				[[node_uuid  => 1, event => 1, element => 1, active => 1], {unique => 1, partialFilterExpression => {historic => { '$lte' => 0}}}],
				#[[node_uuid  => 1, event => 1, element => 1, historic => 1, startdate => 1], {unique => 1}],
				# [ [node_uuid=>1,event=>1,element=>1,active=>1], {unique => 1}],
				[{expire_at => 1}, {expireAfterSeconds => 0}],    # ttl index for auto-expiration
			]
	);
	$self->log->error("index setup failed for events: $err") if ($err);
	
	# Inventory collection
	NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

	$err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_inventory},
			drop_unwanted => $drop_unwanted,
			indices       => [

				# This did not scale, we had paths like .0 and .2 also .1 and .2 which would ommit the prefis .0
				# [["path.0" => 1, "path.1" => 1, "path.2" => 1, "path.3" => 1], {unique => 0}],
				# Via the MongoDB docs order matters!
				[["path.0" => 1]],
				[["path.1" => 1, "path.2" => 1, "path.3" => 1]],
				[["path.2" => 1, "path.3" => 1]],

				# needed for joins
				[[node_uuid => 1]],

				[[concept   => 1, enabled => 1, historic => 1], {unique => 0}],
				[{"lastupdate"           => 1}, {unique => 0}],
				[{"subconcepts"          => 1}, {unique => 0}],
				[["data_info.subconcept" => 1, enabled => 1, node_name => 1], {unique => 0}],
				

				# unfortunately we need a custom extra index for concept == interface, to find nodes by ip address
				[["data.ip.ipAdEntAddr" => 1], {unique             => 0}],
				[{expire_at             => 1}, {expireAfterSeconds => 0}],    # ttl index for auto-expiration
			]
	);
	
	$self->log->error("index setup failed for inventory: $err") if ($err);
	
	# Latest Data collection
	NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

	$err = NMISNG::DB::ensure_index(
		collection    => $self->{_db_latest_data},
		drop_unwanted => $drop_unwanted,
		indices       => [
				[{"inventory_id" => 1}, {unique             => 1}],
				[{expire_at      => 1}, {expireAfterSeconds => 0}],    # ttl index for auto-expiration
				[{"node_uuid"    => 1}, {unique => 0}],
				[{"configuration.group"    => 1}, {unique => 0}],
				[{"time"    => -1}, {unique => 0}]
			]
	);
	$self->log->error("index setup failed for inventory: $err") if ($err);
	
	# Nodes collection 
	$err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_nodes},
			drop_unwanted => $drop_unwanted,
			indices       => [[{"uuid" => 1}, {unique => 1}],
												[{"name" => 1}, {unique => 0}],
												# make sure activated.NMIS is indexed, as well
												# as aliases.alias and addresses.address
												# (for the semi-dynamic dns alias and address info)
												[ [ "aliases.alias" => 1 ] ],
												[ [ "addresses.address" => 1 ] ], ],
				);
	$self->log->error("index setup failed for nodes: $err") if ($err);	
	
	# opstatus collection 
	$err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_opstatus},
			drop_unwanted => $drop_unwanted,
			indices       => [

				# opstatus: searchable by when, by status (good/bad), by activity,
				# context (primarily node but also queue_id), and by type
				# not included: details and stats
				[{"time"              => -1}],
				#Keep an index of activity and compound that with time for sorting
				[["activity"          => 1, "time"          => -1]],
				[{"status"            => 1}],
				[{"context.node_uuid" => 1}],
				[{"context.queue_id"  => 1}],
				[{"type"              => 1}],
				[{"expire_at"         => 1}, {expireAfterSeconds => 0}],    # ttl index for auto-expiration
			]
	);
	$self->log->error("index setup failed for opstatus: $err") if ($err);
	
	# Remote collection	
	NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

	$err = NMISNG::DB::ensure_index(
		collection    => $self->{_db_remote},
		drop_unwanted => $drop_unwanted,
		indices       => [
			# needed for joins
			[[cluster_id => 1], {unique => 1}],
		]
	);
	$self->log->error("index setup failed for remotes: $err") if ($err);
	
	# queue collection
	$err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_queue},
			drop_unwanted => $drop_unwanted,
			indices       => [

				# need to search/sort by time, priority and in_progress, both type and tag,
				# and also args.uuid
				[["time"      => 1, "in_progress" => 1, "priority" => 1,]],
				[["time"      => 1, "in_progress" => 1, "tag"      => 1]],    # fixme: or separate for tag?
				[["time"      => 1, "in_progress" => 1, "type"     => 1]],    # fixme: or separate?
				[["args.uuid" => 1]],
			]
	);
	$self->log->error("index setup failed for queue: $err") if ($err);
	
	# status collection
	$err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_status},
			drop_unwanted => $drop_unwanted,
			indices       => [
				[[cluster_id => 1, node_uuid => 1, event => 1, element => 1], {unique => 0}],
				[[cluster_id => 1, method => 1, index => 1, class => 1], {unique => 0}],
				[{expire_at  => 1}, {expireAfterSeconds => 0}],    # ttl index for auto-expiration
			]
	);
	$self->log->error("index setup failed for nodes: $err") if ($err);
	
	$self->log->info("NMISNG end of ensure_indexes");
	return;
}

# return the events object
sub events
{
	my ($self) = @_;
	return NMISNG::Events->new( nmisng => $self );
}

# helper to get/set event collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub events_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_events} = $newvalue;
	}
	return $self->{_db_events};
}

# this function finds nodes that are due for a given operation;
# consults the various policies and previous node states,
# and looks up any relevant queued jobs (in_progress and overdue)
#
# args: self, type (=one of collect/update/services, required),
#  force (optional, default 0),
#  filters (optional, ARRAY of filter hashrefs to be applied independently)
#
# returns: hashref with error/success,
#  nodes => hash of uuid, value node data (same deep record as get_nodes_model returns!)
#  flavours => hash of uuid -> snmp/wmi -> 0/1 (only for collect),
#  services => hash of uuid -> array of service names (only for services)
#  in_progress => hash of uuid => queue id => queue record
#  overdue => hash of uuid => queue id => queue record
#  newnodes => hash of uuid => 1 (set for nodes that have been newly added)
sub find_due_nodes
{
	my ( $self, %args ) = @_;
	my $whichop = $args{type};
	my $force   = $args{force};

	return {error => "Unknown operation \"$whichop\"!"} if ( $whichop !~ /^(collect|update|services)$/ );
	return {error => "Filters must be list of filter expressions!"}
		if ( exists( $args{filters} ) && ref( $args{filters} ne "ARRAY" ) );

	my %cands;

	# what to work on? all active nodes or only the selected lists of nodes
	# multiple filters are applied independently, e.g. select by group and then extra nodes
	# default: blank unrestricted filter
	for my $onefilter ( ref( $args{filters} ) eq "ARRAY" && @{$args{filters}} ? @{$args{filters}} : ( {} ) )
	{
		$onefilter->{"activated.NMIS"} = 1;    # never consider inactive nodes
		my $possibles = $self->get_nodes_model( filter => $onefilter );
		return {error => $possibles->error} if ( $possibles->error );

		map { $cands{$_->{uuid}} = $_ } ( @{$possibles->data} );
	}

	# no filters returned anybody?
	return {success => 1, nodes => {}} if ( !keys %cands );

	# get the queued jobs that could be of relevance
	my $running = $self->get_queue_model(
		type        => $whichop,
		in_progress => {'$ne' => 0},
		"args.uuid" => [keys %cands]
	);
	$self->log->error( "failed to query job queue: " . $running->error )
		if ( $running->error );

	# want uuid =>  qid => queue record
	my %runningbynode = map { ( $_->{args}->{uuid} => {$_->{_id} => $_} ) } ( @{$running->data} );

	my $overdue = $self->get_queue_model(
		type        => $whichop,
		in_progress => 0,
		time        => {'$lt' => Time::HiRes::time},
		"args.uuid" => [keys %cands]
	);
	$self->log->error( "failed to query job queue: " . $overdue->error )
		if ( $overdue->error );
	my %overduebynode = map { ( $_->{args}->{uuid} => {$_->{_id} => $_} ) } ( @{$overdue->data} );

	# policy name => various times for collect/update
	# service name => period for services
	my %intervals;
	my $servicedefs;    # for tracking snmp-only services....

	if ( $whichop eq "collect" or $whichop eq "update" )
	{
		# collect and update? subject to policies
		# get the polling policies and translate into seconds (for rrd file options)
		my $policies = NMISNG::Util::loadTable(
			conf => $self->config,
			dir  => 'conf',
			name => "Polling-Policy"
		) || {};
		%intervals = ( default => {ping => 60, snmp => 300, wmi => 300, update => 86400} );

		# translate period specs X.Ys, A.Bm, etc. into seconds
		for my $polname ( keys %$policies )
		{
			next if ( ref( $policies->{$polname} ) ne "HASH" );
			for my $subtype (qw(snmp wmi ping update))
			{
				my $interval = $policies->{$polname}->{$subtype};
				if ( $interval =~ /^\s*(\d+(\.\d+)?)([smhd])$/ )
				{
					my ( $rawvalue, $unit ) = ( $1, $3 );
					$interval = $rawvalue * (
						  $unit eq 'm' ? 60
						: $unit eq 'h' ? 3600
						: $unit eq 'd' ? 86400
						:                1
					);
				}
				else
				{
					$self->log->error("Polling policy \"$polname\" has invalid interval \"$interval\" for $subtype! Ignoring.");
					$interval = $intervals{devault}->{$subtype};
				}
				$intervals{$polname}->{$subtype} = $interval;    # now in seconds
			}
		}
	}
	elsif ( $whichop eq "services" )
	{
		$servicedefs = NMISNG::Util::loadTable( dir => "conf", name => "Services", conf => $self->config ) || {};

		for my $servicekey ( keys %$servicedefs )
		{
			my $interval = $servicedefs->{$servicekey}->{Poll_Interval} || 300;
			if ( $interval =~ /^\s*(\d+(\.\d+)?)([smhd])$/ )
			{
				my ( $rawvalue, $unit ) = ( $1, $3 );
				$interval = $rawvalue * (
					  $unit eq 'm' ? 60
					: $unit eq 'h' ? 3600
					: $unit eq 'd' ? 86400
					:                1
				);
			}
			$intervals{$servicekey} = $interval;
		}
	}

	# find out what nodes are due as per polling policy or service status - also honor force
	# unfortunately we require each candidate node's nodeinfo/catchall data to make the
	# candidate-or-not decision...
	my $accessor = $self->get_inventory_model(
		concept    => "catchall",
		cluster_id => $self->config->{cluster_id},
		uuid       => [keys %cands]
	);
	if ( my $error = $accessor->error )
	{
		return {error => "Failed to load catchall inventories: $error"};
	}

	# dynamic node information, by node uuid
	my %node_info_ro = map { ( $_->{node_uuid} => $_->{data} ) } ( @{$accessor->data} );

	my $now = Time::HiRes::time;
	my ( %due, %flavours, %procs, %services, %newnodes );
	for my $maybe ( keys %cands )    # nodes by uuid
	{
		my $nodename   = $cands{$maybe}->{name};
		my $nodeconfig = $cands{$maybe}->{configuration};

		# that's the catchall dynamic info from previous collects/updates
		my $ninfo = $node_info_ro{$maybe} // {};

		# services? need to check the service inventories for when they ran last
		if ( $whichop eq "services" )
		{
			# get the previous service runs for all services for this node
			my $prevruns = $self->get_inventory_model(
				concept     => "service",
				cluster_id  => $self->config->{cluster_id},
				node_uuid   => $maybe,
				filter      => {historic => 0},
				fields_hash => {
					'data.service'  => 1,
					'data.last_run' => 1
				},
			);
			if ( my $error = $prevruns->error )
			{
				return {error => "Failed to load services inventory: $error"};
			}
			my %service_lastrun
				= ( map { ( $_->{data}->{service} => $_->{data}->{last_run} ) } ( @{$prevruns->data} ) );

			for my $maybesvc ( ref($nodeconfig->{services}) eq "ARRAY"? @{$nodeconfig->{services}}: () )
			{
				# listed for a node doesn't mean the service definition (still) exists
				if ( !exists $intervals{$maybesvc} )
				{
					$self->log->warn("Ignoring non-existent service \"$maybesvc\" for node $nodename");
					next;
				}

				# services of type 'service', ie. snmp, can only work if done during/after a collect
				if ( $servicedefs->{$maybesvc}->{Service_Type} eq "service" )
				{
					$self->log->debug(
						"Ignoring SNMP-based service \"$maybesvc\" for node $nodename (only checkable during collect)");
					next;
				}

				# when was this service checked last?
				my $lastrun = $service_lastrun{$maybesvc} // 0;
				my $serviceinterval = $intervals{$maybesvc} || 300;    # bsts fallback

				my $msg = "Service $maybesvc on $nodename, interval \"$serviceinterval\", ran last at "
					. NMISNG::Util::returnDateStamp($lastrun) . ", ";

				# we don't run the service exactly at the same time in the collect cycle,
				# so allow up to 10% underrun
				# note that force overrules the timing policy
				if ( !$args{force} && $lastrun && ( ( time - $lastrun ) < $serviceinterval * 0.9 ) )
				{
					$msg .= "skipping this time.";
					$self->log->debug($msg);
					next;
				}
				else
				{
					$msg .= "is due for checking at this time.";
					$self->log->debug($msg);

					$due{$maybe} = $cands{$maybe}; # we need the whole node record
					$services{$maybe} //= [];
					push @{$services{$maybe}}, $maybesvc;
				}
			}
		}
		elsif ( $whichop eq "collect" or $whichop eq "update" )
		{
			my $polname = $nodeconfig->{polling_policy} || "default";
			my $lastpolicy = $ninfo->{last_polling_policy};

			if ( ref( $intervals{$polname} ) ne "HASH" )
			{
				$self->log->warn(
					"Misconfigured node $nodename, polling policy \"$polname\" does not exist! Using default instead.");
				$polname = $lastpolicy = "default";    # let's NOT treat this broken situation as a policy change
			}
			else
			{
				$self->log->debug2("Node $nodename is using polling policy \"$polname\"");
			}

			my $lastsnmp = $ninfo->{last_poll_snmp_attempt};
			my $lastwmi  = $ninfo->{last_poll_wmi_attempt};

			# handle the case of a changed polling policy: move all rrd files
			# out of the way, and poll now
			# please note that this does NOT work with non-standard common-database structures
			# where rrd files aren't all under /nodes/nodename
			if ( defined($lastpolicy) && $lastpolicy ne $polname )
			{
				$self->log->info(
					"Node $nodename is changing polling policy, from \"$lastpolicy\" to \"$polname\", due for polling at $now"
						);
				# backwards-compatibility with legacy lowercased directories
				for my $maybedir ($nodename, lc($nodename))
				{
					my $curdir = $self->config->{'database_root'} . "/nodes/$maybedir";
					my $backupdir = "$curdir.policy-$lastpolicy." . time();

					if ( !-d $curdir )
					{
						$self->log->warn("Node $maybe doesn't have RRD files under $curdir!")
								if ($maybedir eq $nodename); # noise only for no data under the non-legacy structure
					}
					else
					{
					rename( $curdir, $backupdir )
						or $self->log->error("failed to rename directory $curdir for $maybe: $!");
					}
				}

				$due{$maybe} = $cands{$maybe};
				$flavours{$maybe}->{wmi} = $flavours{$maybe}->{snmp} = 1;    # and ignore the last-xyz markers
			}

			# logic for dead node demotion/rate-limiting
			# if demote_faulty_nodes config option is true, demote nodes that have not been pollable (or updatable) ever:
			# after 14 days of normal attempts change to try at most once daily
			elsif (
				!NMISNG::Util::getbool( $self->config->{demote_faulty_nodes}, "invert" )    # === ne false
				&& ( !$ninfo->{nodeModel} or $ninfo->{nodeModel} eq "Model" )
				)
			{
				# this property gets updated on every attempt
				my $lasttry = $ninfo->{ $whichop eq "collect" ? "last_poll_attempt" : "last_update_attempt" };
				my $graceperiod_start = $ninfo->{demote_grace};

				# none set? then set one and update the database!
				if ( !defined($graceperiod_start) )
				{
					# creating the catchall pretty much requires a live node object, unfortunately...
					# and we may need to if the node is new.
					my $nodeobj = $self->node(uuid => $maybe);
					my ($catchall, $error) = $nodeobj->inventory(
						concept => "catchall", path_keys => [],
						create => 1) if (ref($nodeobj) eq "NMISNG::Node");
					if ($error or !$nodeobj or !$catchall)
					{
						$self->log->error("Failed to retrieve or create catchall inventory: "
															. $error ? $error : "No node object");
					}
					else
					{
						my $shortlived = $catchall->data_live;
						$shortlived->{demote_grace} = $graceperiod_start = $ninfo->{demote_grace} = $now;
						# track newly added nodes, to prioritise type=update
						$newnodes{$maybe} = 1 if ($catchall->is_new);
						my ( $op, $error ) = $catchall->save;
						$self->log->error("Failed to update catchall inventory: $error") if ($error);
					}
				}

				# try only once a day if beyond the grace time, min of snmp/wmi/update policy otherwise;
				my $normalperiod
					= $whichop eq "collect"
					? Statistics::Lite::min( $intervals{$polname}->{snmp}, $intervals{$polname}->{wmi} )
					: $intervals{$polname}->{update};

				# but do make sure to try a newly added node NOW!
				my $fudgefactor = ($self->config->{polling_interval_factor} || 0.95);
				my $nexttry = defined $lasttry? $lasttry
						+ $fudgefactor * $normalperiod : $now;
				$newnodes{$maybe} = 1 if (!defined $lasttry);
				if ($now - $graceperiod_start > 14 * 86400)
				{
					$nexttry = ( $lasttry // $now) + 86400 * $fudgefactor;

					$self->log->debug( "Node $nodename has no valid nodeModel, never polled successfully, "
														 . "past demotion grace window (started at $graceperiod_start) so demoted to frequency once daily, last $whichop attempt $lasttry, next $nexttry");
				}

				$self->log->debug(
					"Node $nodename has no valid nodeModel, never polled successfully, demote_faulty_nodes is on, grace window started at $graceperiod_start, last $whichop attempt ".($lasttry // "never").", next $nexttry."
				);

				if ( $nexttry <= $now )
				{
					$due{$maybe} = $cands{$maybe};
					$flavours{$maybe}->{wmi} = $flavours{$maybe}->{snmp} = 1 if ( $whichop eq "collect" );
				}
			}

			# logic for update now or later:
			# due if no past successful update at all or if that was too long ago,
			# BUT no more than four attempts per update period
			# (without the latter an unpingable or uncollectable node would be retried every few seconds)
			elsif ( $whichop eq "update" )
			{
				my $lastupdate  = $ninfo->{last_update};
				my $lastattempt = $ninfo->{last_update_attempt};

				my $fudgefactor = ($self->config->{update_interval_factor} || 0.95);
				my $nextupdate  = ( $lastupdate  // 0 ) + $intervals{$polname}->{update} * $fudgefactor;
				my $nextattempt = ( $lastattempt // 0 ) + $intervals{$polname}->{update} * $fudgefactor / 4;

				if ( !defined($lastupdate) or $nextupdate <= $now )
				{
					if ( !defined($lastattempt) or $nextattempt <= $now )
					{
						$self->log->debug( "Node $nodename is due for update at $now, last update: "
								. ( $lastupdate ? sprintf( "%.1fs ago", $now - $lastupdate ) : "never" )
								. " last attempt: "
								. ( $lastattempt ? sprintf( "%.1fs ago", $now - $lastattempt ) : "never" ) );
						$due{$maybe} = $cands{$maybe};
					}
					else
					{
						$self->log->debug( "Node $nodename is NOT due for update at $now, last update: "
								. sprintf( "%.1fs ago", $now - $lastupdate )
								. " but last attempt: "
								. ( $lastattempt ? sprintf( "%.1fs ago", $now - $lastattempt ) : "never" ) );
					}
				}
				else
				{
					$self->log->debug( "Node $nodename is NOT due for update at $now, last update: "
							. sprintf( "%.1fs ago", $now - $lastupdate ) );
				}
			}

			# logic for collect now or later: candidate if no past successful collect whatsoever,
			# (subject to demotion rate-limiting for long-dead nodes),
			# or if either of snmp/wmi worked and was done long enough ago.
			#
			# if no history is known for a source, then disregard it for the now-or-later logic
			# but DO enable it for trying!
			# note that collect=false, i.e. ping-only nodes need to be excepted,
			elsif ( !defined($lastsnmp) && !defined($lastwmi) && $nodeconfig->{collect} )
			{
				$self->log->debug("Node $nodename has neither last_poll_snmp nor last_poll_wmi, due for poll at $now");
				$due{$maybe} = $cands{$maybe};
				$flavours{$maybe}->{wmi} = $flavours{$maybe}->{snmp} = 1;
			}
			else
			{
				# for collect false/pingonly nodes the single 'generic' collect run counts,
				# and the 'snmp' policy is applied
				if ( !$nodeconfig->{collect} )
				{
					# We don't care if the last poll was successful or not, so use _attempt. 
					# there is no last_wmi_attempt. And, for non collect nodes we don't really care
					$lastsnmp = $ninfo->{last_poll_attempt} // 0;
					$lastwmi = $ninfo->{last_poll_attempt} // 0;
					$self->log->debug(
						"Node $nodename is non-collecting, applying snmp policy to last check at $lastsnmp");
				}

				# accept delta-previous-now interval if it's at least 95% of the configured interval
				# strict 100% would mean that we might skip a full interval when polling takes longer
				my $fudgefactor = ($self->config->{polling_interval_factor} || 0.95);

				my $nextsnmp = ( $lastsnmp // 0 ) + $intervals{$polname}->{snmp} * $fudgefactor;
				my $nextwmi  = ( $lastwmi  // 0 ) + $intervals{$polname}->{wmi} * $fudgefactor;

				# only flavours which worked in the past contribute to the now-or-later logic
				if (   ( defined($lastsnmp) && $nextsnmp <= $now )
					|| ( defined($lastwmi) && $nextwmi <= $now ) )
				{
					$self->log->debug( "Node $nodename is due for poll at $now, last snmp: "
							. ( $lastsnmp // "never" )
							. ", last wmi: "
							. ( $lastwmi // "never" )
							. ", next snmp: "
							. ( $lastsnmp ? sprintf( "%.1fs ago", $now - $nextsnmp ) : "n/a" )
							. ", next wmi: "
							. ( $lastwmi ? sprintf( "%.1fs ago", $now - $nextwmi ) : "n/a" ) );
					$due{$maybe} = $cands{$maybe};

					# but if we've decided on polling, then DO try flavours that have not worked in the past!
					# nextwmi <= now also covers the case of undefined lastwmi...
					$flavours{$maybe}->{wmi}  = ( $nextwmi <= $now )  ? 1 : 0;
					$flavours{$maybe}->{snmp} = ( $nextsnmp <= $now ) ? 1 : 0;
				}
				else
				{
					$self->log->debug( "Node $nodename is NOT due for poll at $now, last snmp: "
							. ( $lastsnmp // "never" )
							. ", last wmi: "
							. ( $lastwmi // "never" )
							. ", next snmp: "
							. ( $lastsnmp ? $nextsnmp : "n/a" )
							. ", next wmi: "
							. ( $lastwmi ? $nextwmi : "n/a" ) );
				}
			}
		}
	}

	# ignore in-progress and overdue queued jobs for nodes not due
	map { delete $runningbynode{$_} if ( !exists $due{$_} ); } ( keys %runningbynode );
	map { delete $overduebynode{$_} if ( !exists $due{$_} ); } ( keys %overduebynode );

	return {
		success     => 1,
		nodes       => \%due,
		flavours    => \%flavours,
		services    => \%services,
		in_progress => \%runningbynode,
		overdue     => \%overduebynode,
		newnodes => \%newnodes,
	};
}

# returns mongodb db handle - note this is NOT the connection handle!
# (nmisng::db::connection_of_db() can provide the conn handle)
sub get_db
{
	my ($self) = @_;
	return $self->{_db};
}

# find all unique values for key from collection and filter provided
sub get_distinct_values
{
	my ( $self, %args ) = @_;
	my $collection = $args{collection};
	my $key        = $args{key};
	my $filter     = $args{filter};

	my $query = NMISNG::DB::get_query( and_part => $filter );
	my $values = NMISNG::DB::distinct(
		collection => $collection,
		key        => $key,
		query      => $query
	);
	return $values;
}

# find all unique concep/subconcept pairs for the given path/filter
# filtering for active things possible (eg, enabled => 1, historic => 0)
# NOTE: INCOMPLETE, can't be done in aggregation right now, map/reduce or
#  perl are an option
sub get_inventory_available_concepts
{
	my ( $self, %args ) = @_;
	my $path;

	# start with a plain query; with _id that'll be enough already
	my %queryinputs = ();
	if ( $args{filter} )
	{
		map { $queryinputs{$_} = $args{filter}->{$_}; } ( keys %{$args{filter}} );
	}
	my $q = NMISNG::DB::get_query( and_part => \%queryinputs );

	# translate the path components into the lookup path
	if ( $args{path} || $args{node_uuid} || $args{cluster_id} || $args{concept} )
	{
		$path = $args{path} // [];

		# fill in starting args if given
		my $index = 0;
		foreach my $arg_name (qw(cluster_id node_uuid))
		{
			if ( $args{$arg_name} )
			{
				# we still want to have regex and other options so run this through the query code
				my $part = NMISNG::DB::get_query_part( $arg_name, $args{$arg_name} );
				$path->[$index] = $part->{$arg_name};
				delete $args{$arg_name};
			}
			$index++;
		}
		map { $q->{"path.$_"} = NMISNG::Util::numify( $path->[$_] ) if ( defined( $path->[$_] ) ) } ( 0 .. $#$path );
	}
	my @pipeline = ();

	# 	{ '$match' => $q },
	# 	{ '$unwind' => 'subconcepts' },
	# 	{ '$group' => {
	# 		'_id' : { 'concept': '$concept', 'subconcept': '$subconcepts' }
	# 	},
	# 	{ '$group' => {
	# 		'_id' : '$_id.$concept',
	# 		'concept' => '$_id.$concept',
	# 		'subconcepts' => { '$addToSet': '$_id.subconcept' }
	# 	}
	# );

	my ( $entries, $count, $error ) = NMISNG::DB::aggregate(
		collection          => $self->inventory_collection,
		post_count_pipeline => \@pipeline,
	);

}

# note: should _id use args{id}? or _id?
# all arguments that are used in the beginning of the path will be put
# into the path for you, so specificying path[1,2] and cluster_id=>3 will chagne
# the path to path[3,2]
# arguments:
#.   path - array
#.   cluster_id,node_uuid,concept - will all be put into the path, overriding what is there
#. or _id, overriding all of the above
#
#. filter - hashref, will be added to the query
#.   [fields_hash] - which fields should be returned, if not provided the
#    whole record is returned
#.   sort/skip/limit - adjusts the query
#
# returns: model_data object (which may be empty - do check ->error)
sub get_inventory_model
{
	my ( $self, %args ) = @_;

	NMISNG::Util::TODO("Figure out search options for get_inventory_model");

	my $q = $self->get_inventory_model_query(%args);
	my $query_count;
	if ( $args{count} )
	{
		my $res = NMISNG::DB::count( collection => $self->inventory_collection, query => $q, verbose => 1 );
		return NMISNG::ModelData->new( error => "Count failed: $res->{error}" ) if ( !$res->{success} );

		$query_count = $res->{count};
	}

	# print "query:".Dumper($q);
	my $entries = NMISNG::DB::find(
		collection  => $self->inventory_collection,
		query       => $q,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip},
		fields_hash => $args{fields_hash},
	);

	return NMISNG::ModelData->new( error => "find failed: " . NMISNG::DB::get_error_string )
		if ( !defined $entries );

	my @all;
	while ( my $entry = $entries->next )
	{
		push @all, $entry;
	}

	# create modeldata object with instantiation info from caller
	# add in the fallback automagic function, if class_name isn't present
	$args{class_name} //= {"concept" => \&NMISNG::Inventory::get_inventory_class};
	my $model_data_object = NMISNG::ModelData->new(
		nmisng      => $self,
		class_name  => $args{class_name},
		data        => \@all,
		query_count => $query_count
	);
	return $model_data_object;
}

# this does not need to be a member function, could be 'static'
sub get_inventory_model_query
{
	my ( $self, %args ) = @_;

	# start with a plain query; with _id that'll be enough already
	my %queryinputs = ( '_id' => $args{_id} );    # this is a bit inconsistent
	my $q = NMISNG::DB::get_query( and_part => \%queryinputs );
	my $path;

	# there is no point in adding any other filters if _id is specified
	if ( !$args{_id} )
	{
		if ( $args{filter} )
		{
			map { $queryinputs{$_} = $args{filter}->{$_}; } ( keys %{$args{filter}} );
		}
		$q = NMISNG::DB::get_query( and_part => \%queryinputs );

		# translate the path components into the lookup path
		if ( $args{path} || $args{node_uuid} || $args{cluster_id} || $args{concept} )
		{
			$path = $args{path} // [];

			# fill in starting args if given
			my $index = 0;
			foreach my $arg_name (qw(cluster_id node_uuid concept))
			{
				if ( $args{$arg_name} )
				{
					# we still want to have regex and other options so run this through the query code
					my $part = NMISNG::DB::get_query_part( $arg_name, $args{$arg_name} );
					$path->[$index] = $part->{$arg_name};
					delete $args{$arg_name};
				}
				$index++;
			}
			map { $q->{"path.$_"} = NMISNG::Util::numify( $path->[$_] ) if ( defined( $path->[$_] ) ) }
				( 0 .. $#$path );
		}
	}
	return $q;
}

# retrieve latest data
# arg: filter - kvp's of filters to be applied,
# fields_hash, sort/skip/limit
# returns: modeldata object (which may be empty - do check ->error)
sub get_latest_data_model
{
	my ( $self, %args ) = @_;
	my $filter      = $args{filter};
	my $fields_hash = $args{fields_hash};

	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $entries = [];
	my $query_count;
	if ( $args{count} )
	{
		my $res = NMISNG::DB::count( collection => $self->latest_data_collection, query => $q, verbose => 1 );
		return NMISNG::ModelData->new( error => "Count failed: $res->{error}" ) if ( !$res->{success} );

		$query_count = $res->{count};
	}
	my $cursor = NMISNG::DB::find(
		collection  => $self->latest_data_collection,
		query       => $q,
		fields_hash => $fields_hash,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip}
	);

	return NMISNG::ModelData->new( error => "find failed: " . NMISNG::DB::get_error_string )
		if ( !defined $cursor );

	while ( my $entry = $cursor->next )
	{
		push @$entries, $entry;
	}
	my $model_data_object = NMISNG::ModelData->new(
		nmisng      => $self,
		data        => $entries,
		query_count => $query_count,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip}
	);
	return $model_data_object;
}

# returns selection of nodes
# args: id, name, host, group, and filter (=hash) for selection
#
# note: if id/name/host/group and filter are given, then
# the filter properties override id/name/host/group!
#
# ATTENTION: selection by name MAY require that you convert
# your arg with NMISNG::DB::make_string() yourself!
# this function fixes up single name equivalence checks and
# list of single name equivalences; more complex filters are left as-is.
#
# arg sort: mongo sort criteria
# arg limit: return only N records at the most
# arg skip: skip N records at the beginning. index N in the result set is at 0 in the response
# arg paginate: not supported, should be implemented at different level, sort/skip/limit does happen here
# arg count:
# arg filter: any other filters on the list of nodes required, hashref
# arg fields_hash: hash of fields that should be grabbed for each node record, whole thing for each if not provided
# arg restrict_groups: optional list of groups which the user is permitted to see
# return 'complete' result elements without limit! - a dummy element is inserted at the 'complete' end,
# but only 0..limit are populated
#
# returns: ModelData object
sub get_nodes_model
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	my $collection = $self->nodes_collection;

	# copy convenience/shortcut arguments iff the filter
	# hasn't already set them - the filter wins
	for my $shortie (qw(uuid name)) # db keeps these at the top level...
	{
		$filter->{$shortie} = $args{$shortie}
			if ( exists( $args{$shortie} ) and !exists( $filter->{$shortie} ) );
	}
	for my $confshortie (qw(host group)) # ...but these are kept as configuration.X
	{
		$filter->{"configuration.$confshortie"} = $args{$confshortie}
		if ( exists( $args{$confshortie} ) and !exists( $filter->{"configuration.$confshortie"} ) );
	}

	# fix the filter wrt numeric node names, which must be treated as strings
	# we can automatically handle: single plain name or list of plain names
	if (ref($filter->{name}) eq "ARRAY")
	{
		$filter->{name} = [ map { ref($_)? $_ : /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/? NMISNG::DB::make_string($_) : $_ } (@{$filter->{name}}) ];
	}
	elsif (defined($filter->{name})
				 && !ref($filter->{name})
				 && $filter->{name} =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/)
	{
		$filter->{name} = NMISNG::DB::make_string($filter->{name});
	}
	my $fields_hash = $args{fields_hash};
	# We have cases where users are restricted to groups but we still want the user to be able to search via group
	# Build up a and query to first restrict mongo to a list of groups then allow freeform filter on theose groups
	my $q = {
		'$and' => [
			NMISNG::DB::get_query( and_part => $filter )
	]};
	unshift ( @{$q->{'$and'}} , NMISNG::DB::get_query( and_part => {"configuration.group" => $args{restrict_groups}})) if($args{restrict_groups});


	my $model_data = [];
	my $query_count;

	if ( $args{count} )
	{
		my $res = NMISNG::DB::count(
			collection => $collection,
			query      => $q,
			verbose    => 1
		);
		return NMISNG::ModelData->new( nmisng => $self, error => "Count failed: $res->{error}" )
			if ( !$res->{success} );
		$query_count = $res->{count};
	}

	# if you want only a count but no data, set count to 1 and limit to 0
	if ( !( $args{count} && defined $args{limit} && $args{limit} == 0 ) )
	{
		my $cursor = NMISNG::DB::find(
			collection  => $collection,
			query       => $q,
			fields_hash => $fields_hash,
			sort        => $args{sort},
			limit       => $args{limit},
			skip        => $args{skip}
		);

		return NMISNG::ModelData->new(
			nmisng => $self,
			error  => "Find failed: " . NMISNG::DB::get_error_string
		) if ( !defined $cursor );
		@$model_data = $cursor->all;
	}

	my $model_data_object = NMISNG::ModelData->new(
				class_name  => "NMISNG::Node",
				nmisng      => $self,
				data        => $model_data,
				query_count => $query_count,
				sort        => $args{sort},
				limit       => $args{limit},
				skip        => $args{skip}
			);
	
	return $model_data_object;
}

sub get_node_names
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model( %args, fields_hash => {name => 1} );
	my $data       = $model_data->data();
	my @node_names = map { $_->{name} } @$data;
	return \@node_names;
}

sub get_node_uuids
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model( %args, fields_hash => {uuid => 1} );
	my $data       = $model_data->data();
	my @uuids      = map { $_->{uuid} } @$data;
	return \@uuids;
}

# returns list of non-hidden group names for some or all nodes
# args:
#  filter (optional hashref, default: active nodes
#   and for this cluster_id only),
#  include_hidden (optional, default: 0)
# returns: list of group names, may be empty (e.g. errors)
sub get_group_names
{
	my ($self, %args) = @_;
	my $includehidden = NMISNG::Util::getbool($args{include_hidden});

	# default: active nodes, and ours only
	my $filter = exists($args{filter})
		? $args{filter} # undef is ok
		: { "activated.NMIS" => 1, "configuration.active" => 1};

	my $model_data = $self->get_nodes_model( filter => $filter, fields_hash => {"configuration.group" => 1} );
	$self->log->debug7("Model Data " . Dumper($model_data) . "\n\n\n");
	return () if ($model_data->error);

	my @groupnames  = List::Util::uniq(map { $_->{configuration}->{group} } @{$model_data->data});

	# if someone deletes all the nodes, give them one group to get started.
	@groupnames = ("NMIS9") if !@groupnames;

	# nothing to hide?
	return @groupnames
			if ($includehidden
					or ref($self->{_config}->{hide_groups}) ne "ARRAY"
					or !@{$self->{_config}->{hide_groups}});

	# otherwise ditch hidden groups
	my %hideme = map { $_ => 1} (@{$self->{_config}->{hide_groups}});
	return map { $hideme{$_}? () : $_ } (@groupnames);
}

# looks up ops status log entries and returns modeldata object with matches
# args: id/time/activity/type/status/context.X/details for selecting material
#  (attention: details are NOT indexed)
#  sort/skip/limit/count for tuning the query (also all optional),
#   count=1 and limit=0 causes a count but no data retrieval
#
# returns: modeldata object (may be empty, check ->error)
sub get_opstatus_model
{
	my ( $self, %args ) = @_;

	my $q = NMISNG::DB::get_query(
		and_part => {
			'_id' => $args{id},
			map { ( $_ => $args{$_} ) }

				# flat
				(
				qw(time type activity status details),

				# dotted/deep
				grep( /^context\./, keys %args )
				)
		}
	);
	my ( @modeldata, $querycount );

	if ( $args{count} )    # for pagination
	{
		my $res = NMISNG::DB::count(
			collection => $self->opstatus_collection,
			query      => $q,
			verbose    => 1
		);
		return NMISNG::ModelData->new( nmisng => $self, error => "Count failed: $res->{error}" )
			if ( !$res->{success} );
		$querycount = $res->{count};
	}

	# if you want only a count but no data, set count to 1 and limit to 0
	if ( !( $args{count} && defined $args{limit} && $args{limit} == 0 ) )
	{
		# now perform the actual retrieval, with skip and limit passed in
		my $cursor = NMISNG::DB::find(
			collection => $self->opstatus_collection,
			query      => $q,
			sort       => $args{sort},
			limit      => $args{limit},
			skip       => $args{skip}
		);
		return NMISNG::ModelData->new(
			nmisng => $self,
			error  => "Find failed: " . NMISNG::DB::get_error_string
		) if ( !defined $cursor );
		@modeldata = $cursor->all;
	}

	# asking for nonexistent id is treated as failure - asking for 'id NOT matching X' is not
	return NMISNG::ModelData->new( nmisng => $self, error => "No matching opstatus entry!" )
		if ( !@modeldata && ref( $args{id} ) =~ /^(BSON|MongoDB)::OID$/ );

	return NMISNG::ModelData->new(
		nmisng      => $self,
		query_count => $querycount,
		data        => \@modeldata,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip}
	);
}


# retrieve/compute the timing stats for completed jobs from the opstatus collection
# args: filter (optional, hashref of mongo query, criteria added to type completed)
# returns: modeldata object (which may be empty - do check ->error)
#
# if unrestricted then stats for all of opstatus are computed, which may be slow
# a minimal filter => { time => { '$gt' => ...now minus a few minutes }} is recommended
sub get_job_stats_model
{
	my ($self, %args) = @_;

	my $selector = ref($args{filter}) eq "HASH"? $args{filter} : {};
	$selector->{type} = "completed"; # nothing else has time stats

	# match by selector, group by activity, sum and avg time, sum 1 for count,
	# rewrite to produce activity instead of _id
	my ($entries, undef, $error) = NMISNG::DB::aggregate(
		collection => $self->opstatus_collection,
		count => 0,
		pre_count_pipeline => [
			{ '$match' => $selector },
			{ '$group' => { '_id' => '$activity',
											totaltime => { '$sum' => '$stats.time' },
											avgtime => { '$avg' => '$stats.time' },
											totalcount => { '$sum' =>  1 }}},
			{ '$project' => { _id => 0,
												activity => '$_id',
												totaltime =>  1,
												avgtime => 1,
												totalcount => 1 }}]);
	return NMISNG::ModelData->new(error => "Aggregation failed: $error") if ($error);
	return NMISNG::ModelData->new(data => $entries);
}

# looks up queued jobs and returns modeldata object of the result
# args: id OR selection clauses (all optional)
# also sort/skip/limit/count - all optional
#  if count is given, then a pre-skip-limit query count is computed
#
# returns: modeldata object
sub get_queue_model
{
	my ( $self, %args ) = @_;

	my $wantedid = $args{id};
	delete $args{id};    # _id vs id
	my ( %extras, $querycount, @modeldata );
	map {
		if ( exists( $args{$_} ) ) { $extras{$_} = $args{$_}; delete $args{$_}; }
	} (qw(sort skip limit count));

	my $q = NMISNG::DB::get_query( and_part => {'_id' => $wantedid, %args} );
	if ( $extras{count} )
	{
		my $res = NMISNG::DB::count(
			collection => $self->queue_collection,
			query      => $q,
			verbose    => 1
		);
		return NMISNG::ModelData->new( nmisng => $self, error => "Count failed: $res->{error}" )
			if ( !$res->{success} );
		$querycount = $res->{count};
	}

	# if you want only a count but no data, set count to 1 and limit to 0
	if ( !( $extras{count} && defined $extras{limit} && $extras{limit} == 0 ) )
	{
		# now perform the actual retrieval, with skip, limit and sort passed in
		my $cursor = NMISNG::DB::find(
			collection => $self->queue_collection,
			query      => $q,
			sort       => $extras{sort},
			limit      => $extras{limit},
			skip       => $extras{skip}
		);

		return NMISNG::ModelData->new(
			nmisng => $self,
			error  => "Find failed: " . NMISNG::DB::get_error_string
		) if ( !defined $cursor );
		@modeldata = $cursor->all;
	}

	# asking for nonexistent id is treated as failure - asking for 'id NOT matching X' is not
	return NMISNG::ModelData->new( nmisng => $self, error => "No matching queue entry!" )
		if ( !@modeldata && ref($wantedid) =~ /^(BSON|MongoDB)::OID$/ );

	return NMISNG::ModelData->new(
		nmisng      => $self,
		query_count => $querycount,
		data        => \@modeldata,
		sort        => $extras{sort},
		limit       => $extras{limit},
		skip        => $extras{skip}
	);
}

sub get_status_model
{
	my ( $self, %args ) = @_;
	my $filter      = $args{filter};
	my $fields_hash = $args{fields_hash};

	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $entries = [];
	my $query_count;
	if ( $args{count} )
	{
		my $res = NMISNG::DB::count( collection => $self->status_collection, query => $q, verbose => 1 );
		return NMISNG::ModelData->new( error => "Count failed: $res->{error}" ) if ( !$res->{success} );

		$query_count = $res->{count};
	}

	my $cursor = NMISNG::DB::find(
		collection  => $self->status_collection,
		query       => $q,
		fields_hash => $fields_hash,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip}
	);

	return NMISNG::ModelData->new( error => "find failed: " . NMISNG::DB::get_error_string )
		if ( !defined $cursor );

	while ( my $entry = $cursor->next )
	{
		push @$entries, $entry;
	}
	my $model_data_object = NMISNG::ModelData->new(
		nmisng      => $self,
		class_name  => "NMISNG::Status",
		data        => $entries,
		query_count => $query_count,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip}
	);
	return $model_data_object;
}

# accessor for finding timed data for one (or more) inventory instances
# args: cluster_id, node_uuid, concept, path (to select one or more inventories)
#  optional historic and enabled (for filtering),
#  OR inventory_id (which overrules all of the above)
#  time, (for timed-data selection)
#  sort/skip/limit - FIXME sorts/skip/limit not supported if the selection spans more than one concept!
# returns: modeldata object (always, may be empty - check ->error)
sub get_timed_data_model
{
	my ( $self, %args ) = @_;

	# determine the inventory instances to look for
	my %concept2cand;

	# a particular single inventory? look it up, get its concept
	if ( $args{inventory_id} )
	{
		my $cursor = NMISNG::DB::find(
			collection => $self->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $args{inventory_id}}, no_regex => 1 ),
			fields_hash => {concept => 1}
		);
		if ( !$cursor )
		{
			return NMISNG::ModelData->new(
				error => "Failed to retrieve inventory $args{inventory_id}: " . NMISNG::DB::get_error_string );
		}
		my $inv = $cursor->next;
		if ( !defined $inv )
		{
			return NMISNG::ModelData->new( error => "inventory $args{inventory_id} does not exist!" );
		}

		$concept2cand{$inv->{concept}} = $args{inventory_id};
	}

	# any other selectors given? then find instances and create list of wanted ones per concept
	elsif ( grep( defined( $args{$_} ), (qw(cluster_id node_uuid concept path historic enabled)) ) )
	{
		# safe to copy undefs
		my %selectionargs = ( map { ( $_ => $args{$_} ) } (qw(cluster_id node_uuid concept path)) );

		# extra filters need to go under filter
		for my $maybe (qw(historic enabled))
		{
			$selectionargs{filter}->{$maybe} = $args{$maybe} if ( exists $args{$maybe} );
		}
		$selectionargs{fields_hash} = {_id => 1, concept => 1};    # don't need anything else

		my $lotsamaybes = $self->get_inventory_model(%selectionargs);
		return $lotsamaybes if ( $lotsamaybes->error );            # it's a modeldata object with error set

		# fixme: should nosuch inventory count as an error or not?
		return NMISNG::ModelData->new( data => [] ) if ( !$lotsamaybes->count );

		for my $oneinv ( @{$lotsamaybes->data} )
		{
			$concept2cand{$oneinv->{concept}} ||= [];
			push @{$concept2cand{$oneinv->{concept}}}, $oneinv->{_id};
		}
	}

	# nope, global; so just go over each known concept
	else
	{
		my $allconcepts = NMISNG::DB::distinct(
			db         => $self->get_db(),
			collection => $self->inventory_collection,
			key => "concept"
		);

		# fixme: no inventory at all counts as an error or not?
		return NMISNG::ModelData->new( data => [] ) if ( ref($allconcepts) ne "ARRAY" or !@$allconcepts );
		for my $thisone (@$allconcepts)
		{
			$concept2cand{$thisone} = undef;    # undef is not array ref and not string
		}
	}

	# more than one concept and thus collection? cannot sort/skip/limit
	# fixme: must report this as error, or at least ditch those args,
	# or possibly do sort+limit per concept and ditch skip?

	my @rawtimedata;

	# now figure out the appropriate collection for each of the concepts,
	# then query each of those for time data matching the candidate inventory instances
	for my $concept ( keys %concept2cand )
	{
		my $timedcoll = $self->timed_concept_collection( concept => $concept );

		#fixme handle  error

		my $cursor = NMISNG::DB::find(
			collection => $timedcoll,

			# undef will mean unrestricted, one value will do equality lookup,
			# array will cause an $in check
			query => NMISNG::DB::get_query( and_part => {inventory_id => $concept2cand{$concept}} ),
			sort  => $args{sort},
			skip  => $args{skip},
			limit => $args{limit}
		);
		return NMISNG::ModelData->new( error => "Find failed: " . &NMISNG::DB::getErrorString )
			if ( !$cursor );
		while ( my $tdata = $cursor->next )
		{
			push @rawtimedata, $tdata;
		}
	}

	# no object instantiation is expected or possible for timed data
	return NMISNG::ModelData->new( data => \@rawtimedata );
}

# group nodes by specified group, then summarise their reachability and health as well as get total count
# per group as well as nodedown and nodedegraded status
# args: group_by - the field, include_nodes - 1/0, if set return value changes to array with hash, one hash
#  entry for the grouped data and another for the nodes included in the groups, this is added for backwards
#  compat with how nmis group data worked in 8
#  ATTENTION: 'node_config' prefix in group_by is required to get access to the node config record.
#
# If no group_by is given all nodes will be used and put into a single group, this is required to get overall
# status
sub grouped_node_summary
{
	my ( $self, %args ) = @_;

	my $group_by      = $args{group_by}      // [];    #'data.group'
	my $include_nodes = $args{include_nodes} // 0;
	my $filters       = $args{filters};

	# can't have dots in the output group _id values, replace with _
	# also make a hash to project the group by values into the group stage
	my ( %groupby_hash, %groupproject_hash );
	if ( @$group_by > 0 )
	{
		foreach my $entry (@$group_by)
		{
			my $value = $entry;
			my $key   = $entry;
			$key =~ s/\./_/g;
			$groupby_hash{$key}        = '$' . $value;
			$groupproject_hash{$value} = 1;
		}
	}
	else
	{
		$groupby_hash{empty_group} = '$empty_group';
	}

	my $q = NMISNG::DB::get_query( and_part => $filters );
	my @pipe = (
		{'$match' => {'concept' => 'catchall'}},
		{   '$lookup' =>
				{'from' => 'nodes', 'localField' => 'node_uuid', 'foreignField' => 'uuid', 'as' => 'node_config'}
		},
		{'$unwind' => {'path'               => '$node_config', 'preserveNullAndEmptyArrays' => boolean::false}},
		{'$match'  => {'node_config.activated.NMIS' => 1}},
		{   '$lookup' => {
				'from'         => 'latest_data',
				'localField'   => '_id',
				'foreignField' => 'inventory_id',
				'as'           => 'latest_data'
			}
		},
		{'$unwind' => {'path' => '$latest_data',             'preserveNullAndEmptyArrays' => true}},
		{'$unwind' => {'path' => '$latest_data.subconcepts', 'preserveNullAndEmptyArrays' => boolean::true}},
		{'$match' => {'latest_data.subconcepts.subconcept' => 'health', %$q}}
	);
	my $node_project = {
		'$project' => {
			'_id'       => 1,
			'name'      => '$node_config.name',
			'uuid'      => '$node_config.uuid',
			'down'      => {'$cond' => {'if' => {'$eq' => ['$data.nodedown', 'true']}, 'then' => 1, 'else' => 0}},
			'degraded'  => {'$cond' => {'if' => {'$eq' => ['$data.nodestatus', 'degraded']}, 'then' => 1, 'else' => 0}},
			'reachable' => '$latest_data.subconcepts.data.reachability',
			'08_reachable' => '$latest_data.subconcepts.derived_data.08_reachable',
			'16_reachable' => '$latest_data.subconcepts.derived_data.16_reachable',
			'health'       => '$latest_data.subconcepts.data.health',
			'08_health'    => '$latest_data.subconcepts.derived_data.08_health',
			'16_health'    => '$latest_data.subconcepts.derived_data.16_health',
			'available'    => '$latest_data.subconcepts.data.availability',
			'08_available' => '$latest_data.subconcepts.derived_data.08_available',
			'16_available' => '$latest_data.subconcepts.derived_data.16_available',
			'08_response'  => '$latest_data.subconcepts.derived_data.08_response',
			'16_response'  => '$latest_data.subconcepts.derived_data.16_response',

			# add in all the things network.pl is expecting: half are CONFIGURATION half are dynamic catchall/latest
			'nodedown'    => '$data.nodedown',
			'nodestatus'  => '$data.nodestatus',
			'netType'     => '$node_config.configuration.netType',
			'nodeType'    => '$data.nodeType',
			'response'    => '$latest_data.subconcepts.data.responsetime',
			'roleType'    => '$node_config.configuration.roleType',
			'ping'        => '$node_config.configuration.ping',
			'sysLocation' => '$data.sysLocation',
			'last_update' => '$data.last_update',
			'last_poll' => '$data.last_poll',
			%groupproject_hash
		}
	};
	my $final_group = {
		'$group' => {
			'_id'              => \%groupby_hash,
			'count'            => {'$sum' => 1},
			'countdown'        => {'$sum' => '$down'},
			'countdegraded'    => {'$sum' => '$degraded'},
			'reachable_avg'    => {'$avg' => '$reachability'},
			'08_reachable_avg' => {'$avg' => '$08_reachable'},
			'16_reachable_avg' => {'$avg' => '$16_reachable'},
			'health_avg'       => {'$avg' => '$health'},
			'08_health_avg'    => {'$avg' => '$08_health'},
			'16_health_avg'    => {'$avg' => '$16_health'},
			'available_avg'    => {'$avg' => '$available'},
			'08_available_avg' => {'$avg' => '$08_available'},
			'16_available_avg' => {'$avg' => '$16_available'},
			'08_response_avg'  => {'$avg' => '$08_response'},
			'16_response_avg'  => {'$avg' => '$16_response'}
		}
	};
	if ($include_nodes)
	{
		push @pipe,
			{
			'$facet' => {
				node_data    => [$node_project],
				grouped_data => [$node_project, $final_group]
			}
			};
	}
	else
	{
		push @pipe, $node_project;
		push @pipe, $final_group;
	}

	# print "pipe:".Dumper(\@pipe);
	my ( $entries, $count, $error ) = NMISNG::DB::aggregate(
		collection         => $self->inventory_collection(),
		pre_count_pipeline => \@pipe,
		count              => 0,
	);
	$self->log->debug7("Entries: " . Dumper($entries) . "\n\n\n");
	$self->log->debug7("Count:   " . Dumper($count) . "\n\n\n");
	$self->log->debug7("Error:   " . Dumper($error) . "\n\n\n");
	return ( $entries, $count, $error );
}

# helper to get/set inventory collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub inventory_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_inventory} = $newvalue;

	}
	return $self->{_db_inventory};
}

# helper to get/set latest_derived_data collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub latest_data_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_latest_data} = $newvalue;
	}
	return $self->{_db_latest_data};
}

# getter/setter for this object's logger
# args: new logger, optional, must be nmisng::log instance if present
# returns: the current logger
sub log
{
	my ( $self, $newlogger ) = @_;

	$self->{_log} = $newlogger
		if ( ref($newlogger) eq "NMISNG::Log" );

	return $self->{_log};
}

# helper to get/set servers collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub remote_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	#$self->log->debug("index setup for remote");
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_remote} = $newvalue;
	}
	return $self->{_db_remote};
}

# get or create an NMISNG::Node object from the given arguments (that should make it unique)
# the local node found matching all arguments is provided (if >1 is found)
#
# args: create => 0/1, if 1 and node is not found a new one will be returned, it is
#   not persisted into the db until the object has it's save method called
# returns: node object or undef
sub node
{
	my ( $self, %args ) = @_;
	my $create = $args{create};
	delete $args{create};

	my $node;
	# we only need the uuid, and the name only for error handling
	my $modeldata = $self->get_nodes_model(%args, fields_hash => { name => 1, uuid => 1, cluster_id => 1});

	if ( $modeldata->count() > 1 )
	{
		my @names = map { $_->{name} } @{$modeldata->data()};
		$self->log->debug( "Node request returned more than one node, args" . Dumper( \%args ) );
		$self->log->warn( "Node request returned more than one node, names:" . join( ",", @names ) );

		# Try filter by cluster_id
		if (($args{name} || $args{filter}{name}) && !$args{filter}{cluster_id}  )
		{
			foreach (@{$modeldata->data()}) {
				if ( $_->{cluster_id} eq $self->config->{cluster_id} ) {
					$self->log->debug( "Getting local node " . $_->{uuid} );
					my $model = $_;
					$node = NMISNG::Node->new(
						_id    => $model->{_id},
						uuid   => $model->{uuid},
						nmisng => $self,
					);
					return $node;
				}
			}
			$self->log->warn( "Returning nothing, names: " . join( ",", @names ) );
			return;
		} else {
			$self->log->warn( "Returning nothing, names:" . join( ",", @names ) );
			return;
		}

	}
	elsif ( $modeldata->count() == 1 )
	{
		# fixme9: why not use md->object(0)?
		my $model = $modeldata->data()->[0];
		
		$node = NMISNG::Node->new(
			_id    => $model->{_id},
			uuid   => $model->{uuid},
			nmisng => $self
		);
	}
	elsif ($create)
	{
		$node = NMISNG::Node->new(
			uuid   => $args{uuid},
			nmisng => $self
		);
	}

	return $node;
}

# helper to get/set nodes collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# attention: this collection may carry extra indices unknown to NMIS that should not be dropped!
#
# returns: current collection handle
sub nodes_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_nodes} = $newvalue;

	}
	return $self->{_db_nodes};
}

# helper to get/set opstatus collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub opstatus_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_opstatus} = $newvalue;

	}
	return $self->{_db_opstatus};
}

# loads code plugins if necessary, returns the names
# args: none
# returns: list of package/class names
sub plugins
{
	my ( $self, %args ) = @_;

	if ( ref( $self->{_plugins} ) eq "ARRAY" )
	{
		return @{$self->{_plugins}};
	}

	my $C = $self->config;
	$self->{_plugins} = [];

	# check for plugins enabled and the two dirs, default and custom
	return ()
		if ( !NMISNG::Util::getbool( $C->{plugins_enabled} )
		or ( !$C->{plugin_root} and !$C->{plugin_root_default} )
		or ( !-d $C->{plugin_root} and !-d $C->{plugin_root_default} ) );

	# first check the custom plugin dir, then the default dir;
	# files in custom win over files in default
	my %candfiles;    # filename => fullpath
	for my $dir ( $C->{plugin_root}, $C->{plugin_root_default} )
	{
		next if ( !-d $dir );
		if ( !opendir( PD, $dir ) )
		{
			$self->log->error("Error: cannot open plugin dir $dir: $!");
			return ();
		}
		for my $cand ( grep( /\.pm$/, readdir(PD) ) )
		{
			$candfiles{$cand} //= "$dir/$cand";    #'"
		}
		closedir(PD);
	}

	for my $candidate ( keys %candfiles )
	{
		my $packagename = $candidate;
		$packagename =~ s/\.pm$//;
		my $pluginfile = $candfiles{$candidate};

		# read it and check that it has precisely one matching package line
		$self->log->debug("Checking candidate plugin $candidate ($pluginfile)");

		if ( !open( F, $pluginfile ) )
		{
			$self->log->error("Error: cannot open plugin file $pluginfile: $!");
			next;
		}
		my @plugindata = <F>;
		close F;
		my @packagelines = grep( /^\s*package\s+[a-zA-Z0-9_:-]+\s*;\s*$/, @plugindata );
		if ( @packagelines > 1 or $packagelines[0] !~ /^\s*package\s+$packagename\s*;\s*$/ )
		{
			$self->log->info("Plugin $candidate doesn't have correct \"package\" declaration. Ignoring.");
			next;
		}

		# do the actual load and eval
		eval { require "$pluginfile"; };
		if ($@)
		{
			$self->log->info("Ignoring plugin $candidate ($pluginfile) as it isn't valid perl: $@");
			next;
		}

		# we're interested if one or more of the supported plugin functions are provided
		push @{$self->{_plugins}}, $packagename
			if ( $packagename->can("update_plugin")
			or $packagename->can("collect_plugin")
			or $packagename->can("after_collect_plugin")
			or $packagename->can("after_update_plugin") );
	}

	return @{$self->{_plugins}};
}

# this function processes escalations and notifications
# args: self
# returns: nothing
sub process_escalations
{
	my ( $self, %args ) = @_;

	my $pollTimer = Compat::Timing->new;

	my $C = $self->config;

	my $outage_time;
	my $planned_outage;
	my $event_hash;
	my %location_data;
	my $time;
	my $escalate;
	my $event_age;
	my $esc_key;
	my $event;
	my $index;
	my $group;
	my $role;
	my $type;
	my $details;
	my @x;
	my $k;
	my $level;
	my $contact;
	my $target;
	my $field;
	my %keyhash;
	my $ifDescr;
	my %msgTable;
	my $serial    = 0;
	my $serial_ns = 0;
	my %seen;

	$self->log->debug2(&NMISNG::Log::trace()."Starting");
	my $CT = NMISNG::Util::loadTable( dir => "conf", name => "Contacts", conf => $C );

	# load the escalation policy table
	my $EST = NMISNG::Util::loadTable( dir => "conf", name => "Escalations", conf => $C );

	my $LocationsTable = NMISNG::Util::loadTable( dir => "conf", name => "Locations", conf => $C );

	### keiths, work around for extra tables.
	my $ServiceStatusTable;
	my $useServiceStatusTable = 0;
	if ( Compat::NMIS::tableExists('ServiceStatus', $C) )
	{
		$ServiceStatusTable = NMISNG::Util::loadTable( dir => "conf", name => 'ServiceStatus', conf => $C );
		$useServiceStatusTable = 1;
	}

	my $BusinessServicesTable;
	my $useBusinessServicesTable = 0;
	if ( Compat::NMIS::tableExists('BusinessServices', $C) )
	{
		$BusinessServicesTable = NMISNG::Util::loadTable( dir => "conf", name => 'BusinessServices', conf => $C );
		$useBusinessServicesTable = 1;
	}

	# the events configuration table, controls active/notify/logging for each known event
	my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events', conf => $C );

	# add a full format time string for emails and message notifications
	# pull the system timezone and then the local time
	my $msgtime = NMISNG::Util::get_localtime();

	# first load all non-historic events for all nodes for this cluster
	my $activemodel = $self->events->get_events_model( filter => {historic => 0, active => 1,
		cluster_id => $self->config->{cluster_id}} );
	if ( my $error = $activemodel->error )
	{
		$self->log->error("Failed to retrieve active events: $error");
	}
	my $inactivemodel = $self->events->get_events_model( filter => {historic => 0, active => 0,
		cluster_id => $self->config->{cluster_id}} );
	if ( my $error = $inactivemodel->error )
	{
		$self->log->error("Failed to retrieve inactive events: $error");
	}

	# then send UP events to all those contacts to be notified as part of the escalation procedure
	# this loop skips ALL marked-as-active events!
	# active flag in event means: DO NOT TOUCH IN ESCALATE, STILL ALIVE AND ACTIVE
	# we might rename that transition t/f, and have this function handle only the ones with transition true.

	for ( my $i = 0; $i < $inactivemodel->count; $i++ )
	{
		my $event_obj  = $inactivemodel->object($i);
		my $event_data = $event_obj->data();           # for easier string printing
		                                               # if the event is configured for no notify, do nothing
		my $thisevent_control = $events_config->{$event_obj->event}
			|| {Log => "true", Notify => "true", Status => "true"};

		# in case of Notify being off for this event, we don't have to check/walk/handle any notify fields at all
		# as we're deleting the record after the loop anyway.
		if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
		{
			foreach my $field ( split( ',', $event_obj->notify ) )    # field = type:contact
			{
				$target = "";
				my @x    = split /:/, $field;
				my $type = shift @x;                                  # netsend, email, or pager ?
				$self->log->debug2("Escalation type=$type contact=$contact");

				if ( $type =~ /email|ccopy|pager/ )
				{
					foreach $contact (@x)
					{
						if ( exists $CT->{$contact} )
						{
							if ( Compat::NMIS::dutyTime( $CT, $contact ) )
							{                                         # do we have a valid dutytime ??
								if ( $type eq "pager" )
								{
									$target = $target ? $target . "," . $CT->{$contact}{Pager} : $CT->{$contact}{Pager};
								}
								else
								{
									$target = $target ? $target . "," . $CT->{$contact}{Email} : $CT->{$contact}{Email};
								}
							}
						}
						else
						{
							$self->log->debug2("Contact $contact not found in Contacts table");
						}
					}

					# no email targets found, and if default contact not found, assume we are not covering
					# 24hr dutytime in this slot, so no mail.
					# maybe the next levelx escalation field will fill in the gap
					if ( !$target )
					{
						if ( $type eq "pager" )
						{
							$target = $CT->{default}{Pager};
						}
						else
						{
							$target = $CT->{default}{Email};
						}
						$self->log->debug2(
							"No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target"
						);
					}

					if ($target)
					{
						foreach my $trgt ( split /,/, $target )
						{
							my $message;
							my $priority;
							if ( $type eq "pager" )
							{
								$msgTable{$type}{$trgt}{$serial_ns}{message}
									= "NMIS: UP Notify $event_data->{node_name} Normal $event_data->{event} $event_data->{element}";
								$serial_ns++;
							}
							else
							{
								if ( $type eq "ccopy" )
								{
									$message  = "FOR INFORMATION ONLY\n";
									$priority = &Compat::NMIS::eventToSMTPPri("Normal");
								}
								else
								{
									$priority = &Compat::NMIS::eventToSMTPPri( $event_obj->level );
								}
								$event_age = NMISNG::Util::convertSecsHours( time - $event_obj->startdate );

								$message
									.= "Node:\t$event_data->{node_name}\nUP Event Notification\nEvent Elapsed Time:\t$event_age\nEvent:\t$event_data->{event}\nElement:\t$event_data->{element}\nDetails:\t$event_data->{details}\n\n";

								if ( NMISNG::Util::getbool( $C->{mail_combine} ) )
								{
									$msgTable{$type}{$trgt}{$serial}{count}++;
									$msgTable{$type}{$trgt}{$serial}{subject}
										= "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
									$msgTable{$type}{$trgt}{$serial}{message} .= $message;
									if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} )
									{
										$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
									}
								}
								else
								{
									$msgTable{$type}{$trgt}{$serial}{subject}
										= "$event_data->{node_name} $event_data->{event} - $event_data->{element} - $event_data->{details} at $msgtime";
									$msgTable{$type}{$trgt}{$serial}{message}  = $message;
									$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
									$msgTable{$type}{$trgt}{$serial}{count}    = 1;
									$serial++;
								}
							}
						}

						# log the meta event, ONLY if both Log (and Notify) are enabled
						$self->events->logEvent(
							node_name => $event_obj->node_name,
							event     => "$type to $target UP Notify",
							level     => "Normal",
							element   => $event_obj->element,
							details   => $event_obj->details
						) if ( NMISNG::Util::getbool( $thisevent_control->{Log} ) );

						$self->log->debug2(
							"Escalation $type UP Notification node=$event_data->{node_name} target=$target level=$event_data->{level} event=$event_data->{event} element=$event_data->{element} details=$event_data->{details}"
						);
					}
				}
				elsif ( $type eq "netsend" )
				{
					my $message
						= "UP Event Notification $event_data->{node_name} Normal $event_data->{event} $event_data->{element} $event_data->{details} at $msgtime";
					foreach my $trgt (@x)
					{
						$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
						$serial_ns++;
						$self->log->debug2("NetSend $message to $trgt");

						# log the meta event, ONLY if both Log (and Notify) are enabled
						$self->events->logEvent(
							node_name => $event_obj->node_name,
							event     => "NetSend $message to $trgt UP Notify",
							level     => "Normal",
							element   => $event_obj->element,
							details   => $event_obj->details
						) if ( NMISNG::Util::getbool( $thisevent_control->{Log} ) );
					}
				}
				elsif ( $type eq "syslog" )
				{
					if ( NMISNG::Util::getbool( $C->{syslog_use_escalation} ) )    # syslog action
					{
						my $timenow = time();
						my $message
							= "NMIS_Event::$C->{server_name}::$timenow,$event_data->{node_name},$event_data->{event},$event_data->{level},$event_data->{element},$event_data->{details}";
						my $priority = NMISNG::Notify::eventToSyslog( $event_obj->level );

						foreach my $trgt (@x)
						{
							$msgTable{$type}{$trgt}{$serial_ns}{message}  = $message;
							$msgTable{$type}{$trgt}{$serial_ns}{priority} = $priority;
							$serial_ns++;
							$self->log->debug2("syslog $message");
						}
					}
				}
				elsif ( $type eq "json" )
				{
					# log the event as json file, AND save those updated bits back into the
					# soon-to-be-deleted/archived event record.

					my $nmisng_node
						= $self->node( uuid => $event_obj->node_uuid );    # will be undef if the node was removed!
					my $node = $nmisng_node->configuration;

					# fixme9: nmis_server cannot work
					$event_obj->custom_data( 'nmis_server', $C->{server_name} );
					$event_obj->custom_data( 'customer',    $node->{customer} );
					$event_obj->custom_data( 'location',    $LocationsTable->{$node->{location}}{Location} );
					$event_obj->custom_data( 'geocode',     $LocationsTable->{$node->{location}}{Geocode} );

					if ($useServiceStatusTable)
					{
						$event_obj->custom_data( 'serviceStatus',
							$ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus} );
						$event_obj->custom_data( 'statusPriority',
							$ServiceStatusTable->{$node->{serviceStatus}}{statusPriority} );
					}

					if ($useBusinessServicesTable)
					{
						$event_obj->custom_data( 'businessService',
							$BusinessServicesTable->{$node->{businessService}}{businessService} );
						$event_obj->custom_data( 'businessPriority',
							$BusinessServicesTable->{$node->{businessService}}{businessPriority} );
					}

					# Copy the fields from nodes to the event
					my @nodeFields = split( ",", $C->{'json_node_fields'} );
					foreach my $field (@nodeFields)
					{
						# uuid, name, active/activated.NMIS, cluster_id, are NOT under configuration
						my $val = ($field =~ /^(uuid|name|cluster_id)$/)?
								$nmisng_node->$field
								: ($field eq "active" or $field eq "activated.NMIS")?
								$nmisng_node->activated->{NMIS} : $node->{$field};

						$event_obj->custom_data( $field, $val );
					}

					if (my $error = NMISNG::Notify::logJsonEvent( event => $event_data, dir => $C->{'json_logs'} ))
					{
						$self->log->error("logJsonEvent failed: $error");
					}

					# may sound silly to update-then-archive but i'd rather have the historic event record contain
					# the full story
					if ( my $err = $event_obj->save( update => 1 ) )
					{
						$self->log->error("failed to save event object for event $event_data->{event}, node $event_data->{node}:  $err");
					}
				}    # end json
				     # any custom notification methods?
				else
				{
					if ( NMISNG::Util::checkPerlLib("Notify::$type") )
					{
						$self->log->debug2("Notify::$type $contact");

						my $timenow = time();
						my $datenow = NMISNG::Util::returnDateStamp();
						my $message
							= "$datenow: $event_data->{node_name}, $event_data->{event}, $event_data->{level}, $event_data->{element}, $event_data->{details}";
						foreach $contact (@x)
						{
							if ( exists $CT->{$contact} )
							{
								if ( Compat::NMIS::dutyTime( $CT, $contact ) )
								{    # do we have a valid dutytime ??
									    # check if UpNotify is true, and save with this event
									    # and send all the up event notifies when the event is cleared.
									if ( NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
										and $event_obj->event =~ /$C->{upnotify_stateful_events}/i )
									{
										my $ct = "$type:$contact";
										my @l = split( ',', $event_obj->notify );
										if ( not grep { $_ eq $ct } @l )
										{
											push @l, $ct;
											$event_obj->notify( join( ',', @l ) )
												;    # note: updated only for msgtable below, NOT saved!
										}
									}

									#$serial
									$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
									$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
									$msgTable{$type}{$contact}{$serial_ns}{event}   = $event_data;
									$serial_ns++;
								}
							}
							else
							{
								$self->log->debug2("Contact $contact not found in Contacts table");
							}
						}
					}
					else
					{
						$self->log->debug2(
							"ERROR process_escalations problem with escalation target unknown at level$event_data->{escalate} $level type=$type"
						);
					}
				}
			}
		}

		# now remove this event
		if ( my $err = $event_obj->delete() )
		{
			$self->log->error("event deletion failed: $err");
		}
	}

	#===========================================
	my $stateless_event_dampening = $C->{stateless_event_dampening} || 900;

	# now handle the actual escalations; only events marked-as-current are left now.
LABEL_ESC:
	for ( my $i = 0; $i < $activemodel->count; $i++ )
	{
		my $event_obj = $activemodel->object($i);

		# we must tell the object it's already loaded or whenever load is called
		# (which save does call) will clober any changes made before it's called
		$event_obj->loaded(1);
		my $nmisng_node = $self->node( uuid => $event_obj->node_uuid );

		# get the data in the event as a hash so it's easier to print
		my $event_data = $event_obj->data();

		my $mustupdate = undef;    # live changes to thisevent are ok, but saved back ONLY if this is set

		$self->log->debug2("processing event $event_data->{event}");

		# checking if event is stateless and dampen time has passed.
		if ( $event_obj->stateless and time() > $event_obj->startdate + $stateless_event_dampening )
		{
			# yep, remove the event completely.
			$self->log->debug2(
				"stateless event $event_data->{event} has exceeded dampening time of $stateless_event_dampening seconds."
			);
			$event_obj->delete();
		}

		# set event control to policy or default=enabled.
		my $thisevent_control = $events_config->{$event_obj->event}
			|| {Log => "true", Notify => "true", Status => "true"};

		my $node_name = $event_obj->node_name;

		# lets start with checking that we have a valid node - the node may have been deleted.
		if ( !$nmisng_node or !$nmisng_node->configuration->{active} )
		{
			if (    NMISNG::Util::getbool( $thisevent_control->{Log} )
				and NMISNG::Util::getbool( $thisevent_control->{Notify} )
				)    # meta-events are subject to both Notify and Log
			{
				$self->events->logEvent(
					node_name => $node_name,
					node_uuid => ($nmisng_node? $nmisng_node->uuid : undef), # fixme9: not even used
					event     => "Deleted Event: " . $event_obj->event,
					level     => $event_obj->level,
					element   => $event_obj->element,
					details   => $event_obj->details
				);

				my $timenow = time();
				my $message
					= "NMIS_Event::$C->{server_name}::$timenow,$event_data->{node_name},Deleted Event: $event_data->{event},$event_data->{level},$event_data->{element},$event_data->{details}";
				my $priority = NMISNG::Notify::eventToSyslog( $event_obj->{level} );

				my $error = NMISNG::Notify::sendSyslog(
					server_string => $C->{syslog_server},
					facility      => $C->{syslog_facility},
					message       => $message,
					priority      => $priority
						);

				$self->log->error("sendSyslog to $C->{syslog_server} failed: $error") if ($error);
			}

			$self->log->debug("($node_name) Node not active, deleted Event=$event_data->{event} Element=$event_data->{element}");
			$event_obj->delete();

			next LABEL_ESC;
		}

		### 2013-08-07 keiths, taking too long when MANY interfaces e.g. > 200,000
		if ( $event_obj->event =~ /interface/i && !$event_obj->is_proactive )
		{
			### load the interface information and check the collect status.
			my $S = NMISNG::Sys->new(nmisng => $self);    # node object
			if ( $S->init( node => $nmisng_node, snmp => 'false' ) )
			{
				my $IFD = $S->ifDescrInfo();    # interface info indexed by ifDescr
				if ( !NMISNG::Util::getbool( $IFD->{$event_obj->element}{collect} ) )
				{
					# meta events are subject to both Log and Notify controls
					if (    NMISNG::Util::getbool( $thisevent_control->{Log} )
						and NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
					{
						$nmisng_node->eventLog(
							event   => "Deleted Event: $event_data->{event}",
							level   => $event_obj->level,
							element => " no matching interface or no collect Element=$event_data->{element}"
						);
					}
					$self->log->debug("($event_data->{node_name}) Interface not active, deleted Event=$event_data->{event} Element=$event_data->{element}");
					$event_obj->delete();
					next LABEL_ESC;
				}
			}
		}

		# if a planned outage is in force, keep writing the start time of any unack event to the current start time
		# so when the outage expires, and the event is still current, we escalate as if the event had just occured
		my ( $outage, undef ) = NMISNG::Outage::outageCheck( node => $nmisng_node, time => time() );
		$self->log->debug2( "Outage status for $event_data->{node_name} is " . ( $outage || "<none>" ) );
		if ( $outage eq "current" and !$event_obj->ack )
		{
			$event_obj->startdate( time() );
			if ( my $err = $event_obj->save( update => 1 ) )
			{
				$self->log->error("failed to save event object for event $event_data->{event}, node $event_data->{node}: $err");
			}
		}

		# set the current outage time
		$outage_time = time() - $event_obj->startdate;

		# if we are to escalate, this event must not be part of a planned outage and un-ack.
		if ( $outage ne "current" and !$event_obj->ack )
		{
			# we have list of nodes that this node depends on
			# if any of those have a current Node Down alarm, then lets just move on with a debug message
			# should we log that we have done this - maybe not....

			if (ref($nmisng_node->configuration->{depend}) eq "ARRAY")
			{
				for my $node_depend (@{$nmisng_node->configuration->{depend}})
				{
					next if $node_depend eq "N/A";                    # default setting
					next if $node_depend eq $event_obj->node_name;    # remove the catch22 of self dependancy.

					#only do dependancy if that dependency node is active.
					my $node_depend_obj = $self->node( name => $node_depend );

					if (ref($node_depend_obj) eq "NMISNG::Node" && $node_depend_obj->activated->{NMIS})
					{
						my ( $error, $erec ) = $self->events->eventLoad(
							node_uuid => $node_depend_obj->uuid,
							event     => "Node Down",
							active    => 1
						);
						if ( !$error && ref($erec) eq "HASH" )
						{
							$self->log->debug2(
								"NOT escalating $event_data->{node_name} $event_data->{event} as depending on $node_depend, which is reported as down"
							);
							next LABEL_ESC;
						}

					}
				}
			}

			undef %keyhash;    # clear this every loop
			$escalate = $event_obj->escalate;    # save this as a flag

			# now depending on the event escalate the event up a level or so depending on how long it has been active
			# now would be the time to notify as to the event. node down every 15 minutes, interface down every 4 hours?
			# maybe a deccreasing run 15,30,60,2,4,etc
			# proactive events would be escalated daily
			# when escalation hits 10 they could auto delete?
			# core, distrib and access could escalate at different rates.

			# fixme9: unreachable - vanished node already handled earlier...
			$self->log->error("Failed to get node for event, node:$event_data->{node_name}") && next
				if ( !$nmisng_node );
			my ( $catchall_inventory, $error_message ) = $nmisng_node->inventory( concept => "catchall" );
			$self->log->error(
				"Failed to get catchall inventory for node:$event_data->{node_name}, error_message:$error_message")
				&& next
				if ( !$catchall_inventory );

			# in this case we have no guarantee that we have catchall and if we don't creating it is pointless.
			my $catchall_data = $catchall_inventory->data_live();
			$group = lc( $catchall_data->{group} ); # fixme9 lowercasing these is a bad idea
			$role  = lc( $catchall_data->{roleType} );
			$type  = lc( $catchall_data->{nodeType} );
			$event = lc( $event_obj->event );

			$self->log->debug2(
				"looking for Event to Escalation Table match for Event[ Node:$event_data->{node_name} Event:$event Element:$event_data->{element} ]"
			);
			$self->log->debug2("and node values node=$event_data->{node_name} group=$group role=$role type=$type");

			# Escalation_Key=Group:Role:Type:Event
			my @keylist = (
				$group . "_" . $role . "_" . $type . "_" . $event,
				$group . "_" . $role . "_" . $type . "_" . "default",
				$group . "_" . $role . "_" . "default" . "_" . $event,
				$group . "_" . $role . "_" . "default" . "_" . "default",
				$group . "_" . "default" . "_" . $type . "_" . $event,
				$group . "_" . "default" . "_" . $type . "_" . "default",
				$group . "_" . "default" . "_" . "default" . "_" . $event,
				$group . "_" . "default" . "_" . "default" . "_" . "default",
				"default" . "_" . $role . "_" . $type . "_" . $event,
				"default" . "_" . $role . "_" . $type . "_" . "default",
				"default" . "_" . $role . "_" . "default" . "_" . $event,
				"default" . "_" . $role . "_" . "default" . "_" . "default",
				"default" . "_" . "default" . "_" . $type . "_" . $event,
				"default" . "_" . "default" . "_" . $type . "_" . "default",
				"default" . "_" . "default" . "_" . "default" . "_" . $event,
				"default" . "_" . "default" . "_" . "default" . "_" . "default"
			);

			# lets allow all possible keys to match !
			# so one event could match two or more escalation rules
			# can have specific notifies to one group, and a 'catch all' to manager for example.

			foreach my $klst (@keylist)
			{
				foreach my $esc ( keys %{$EST} )
				{
					my $esc_short = lc "$EST->{$esc}{Group}_$EST->{$esc}{Role}_$EST->{$esc}{Type}_$EST->{$esc}{Event}";

					$EST->{$esc}{Event_Node} = ( $EST->{$esc}{Event_Node} eq '' ) ? '.*' : $EST->{$esc}{Event_Node};
					$EST->{$esc}{Event_Element}
						= ( $EST->{$esc}{Event_Element} eq '' ) ? '.*' : $EST->{$esc}{Event_Element};
					$EST->{$esc}{Event_Node} =~ s;/;;g;
					$EST->{$esc}{Event_Element} =~ s;/;\\/;g;
					# to handle c:\\ as an element, the c:\\ gets converted to c:\ which is invalid so need to pad c:\\ to c:\\\\
					$EST->{$esc}{Event_Element} =~ s;^(\w)\:\\$;$1\\:\\\\;g;

					if (    $klst eq $esc_short
						and $event_obj->node_name =~ /$EST->{$esc}{Event_Node}/i
						and $event_obj->element =~ /$EST->{$esc}{Event_Element}/i )
					{
						$keyhash{$esc} = $klst;
						$self->log->debug2("match found for escalation key=$esc");
					}
				}
			}

			my $cnt_hash = keys %keyhash;
			$self->log->debug2("$cnt_hash match(es) found for $event_data->{node_name}");

			foreach $esc_key ( keys %keyhash )
			{
				$self->log->debug2(
					"Matched Escalation Table Group:$EST->{$esc_key}{Group} Role:$EST->{$esc_key}{Role} Type:$EST->{$esc_key}{Type} Event:$EST->{$esc_key}{Event} Event_Node:$EST->{$esc_key}{Event_Node} Event_Element:$EST->{$esc_key}{Event_Element}"
				);
				$self->log->debug2(
					"Pre Escalation : $event_data->{node_name} Event $event_data->{event} is $outage_time seconds old escalation is $event_data->{escalate}"
				);

				# default escalation for events
				# 28 apr 2003 moved times to nmis.conf
				for my $esclevel ( reverse( 0 .. 10 ) )
				{
					if ( $outage_time >= $C->{"escalate$esclevel"} )
					{
						$mustupdate = 1 if ( $event_obj->escalate != $esclevel );    # if level has changed
						$event_obj->escalate($esclevel);
						last;
					}
				}

				$self->log->debug2(
					"Post Escalation: $event_data->{node_name} Event $event_data->{event} is $outage_time seconds old, escalation is $event_data->{escalate}"
				);
				if ($escalate == $event_obj->escalate )
				{
					my $level = "Level" . ( $event_obj->escalate + 1 );
					$self->log->debug2("Next Notification Target would be $level, Contact: " . $EST->{$esc_key}{$level} );
				}

				# send a new email message as the escalation again.
				# ehg 25oct02 added win32 netsend message type (requires SAMBA on this host)
				if ( $escalate != $event_obj->escalate )
				{
					$event_age = NMISNG::Util::convertSecsHours( time - $event_obj->startdate );
					$time      = &NMISNG::Util::returnDateStamp;

					# get the string of type email:contact1:contact2,netsend:contact1:contact2,\
					# pager:contact1:contact2,email:sysContact
					$level = lc( $EST->{$esc_key}{'Level' . $event_obj->escalate} );

					if ( $level ne "" )
					{
						# Now we have a string, check for multiple notify types
						foreach $field ( split ",", $level )
						{
							$target = "";
							@x      = split /:/, lc $field;
							$type   = shift @x;               # first entry is email, ccopy, netsend or pager

							$self->log->debug2("Escalation type=$type");

							if ( $type =~ /email|ccopy|pager/ )
							{
								foreach $contact (@x)
								{
									my $contactLevelSend = 0;
									my $contactDutyTime  = 0;

									# if sysContact, use device syscontact as key into the contacts table hash
									if ( $contact eq "syscontact" )
									{
										if ( $catchall_data->{sysContact} ne '' )
										{
											$contact = lc $catchall_data->{sysContact};
											$self->log->debug2(
												"Using node $event_data->{node_name} sysContact $catchall_data->{sysContact}"
											);
										}
										else
										{
											$contact = 'default';
										}
									}

									### better handling of upnotify for certain notification types.
									if ( $type !~ /email|pager/ )
									{
										# check if UpNotify is true, and save with this event
										# and send all the up event notifies when the event is cleared.
										if (    NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
											and $event_obj->event =~ /$C->{upnotify_stateful_events}/i
											and NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
										{
											my $ct = "$type:$contact";
											my @l = split( ',', $event_obj->notify );
											if ( not grep { $_ eq $ct } @l )
											{
												push @l, $ct;
												$event_obj->notify( join( ',', @l ) );
												$mustupdate = 1;
											}
										}
									}

									if ( exists $CT->{$contact} )
									{
										if ( Compat::NMIS::dutyTime( $CT, $contact ) )
										{    # do we have a valid dutytime ??
											$contactDutyTime = 1;

											# Duty Time is OK check level match
											if ( $CT->{$contact}{Level} eq "" )
											{
												$self->log->debug2(
													"SEND Contact $contact no filtering by Level defined");
												$contactLevelSend = 1;
											}
											elsif ( $event_obj->level =~ /$CT->{$contact}{Level}/i )
											{
												$self->log->debug2(
													"SEND Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $event_data->{level}"
												);
												$contactLevelSend = 1;
											}
											elsif ( $event_obj->level !~ /$CT->{$contact}{Level}/i )
											{
												$self->log->debug2(
													"STOP Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $event_data->{level}"
												);
												$contactLevelSend = 0;
											}
										}

										if ( $contactDutyTime and $contactLevelSend )
										{
											if ( $type eq "pager" )
											{
												$target
													= $target
													? $target . "," . $CT->{$contact}{Pager}
													: $CT->{$contact}{Pager};
											}
											else
											{
												$target
													= $target
													? $target . "," . $CT->{$contact}{Email}
													: $CT->{$contact}{Email};
											}

											# check if UpNotify is true, and save with this event
											# and send all the up event notifies when the event is cleared.
											if (    NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
												and $event_obj->event =~ /$C->{upnotify_stateful_events}/i
												and NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
											{
												my $ct = "$type:$contact";
												my @l = split( ',', $event_obj->notify );
												if ( not grep { $_ eq $ct } @l )
												{
													push @l, $ct;
													$event_obj->notify( join( ',', @l ) );
													$mustupdate = 1;
												}
											}
										}
										else
										{
											$self->log->debug2(
												"STOP Contact duty time: $contactDutyTime, contact level: $contactLevelSend"
											);
										}
									}
									else
									{
										$self->log->debug2("Contact $contact not found in Contacts table");
									}
								}    #foreach

								# no email targets found, and if default contact not found, assume we are not
								# covering 24hr dutytime in this slot, so no mail.
								# maybe the next levelx escalation field will fill in the gap
								if ( !$target )
								{
									if ( $type eq "pager" )
									{
										$target = $CT->{default}{Pager};
									}
									else
									{
										$target = $CT->{default}{Email};
									}
									$self->log->debug2(
										"No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target"
									);
								}
								else    # have target
								{
									foreach my $trgt ( split /,/, $target )
									{
										my $message;
										my $priority;
										if ( $type eq "pager" )
										{
											if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
											{
												$msgTable{$type}{$trgt}{$serial_ns}{message}
													= "NMIS: Esc. $event_data->{escalate} $event_age $event_data->{node_name} $event_data->{level} $event_data->{event} $event_data->{details}";
												$serial_ns++;
											}
										}
										else
										{
											if ( $type eq "ccopy" )
											{
												$message  = "FOR INFORMATION ONLY\n";
												$priority = &Compat::NMIS::eventToSMTPPri("Normal");
											}
											else
											{
												$priority = &Compat::NMIS::eventToSMTPPri( $event_obj->level );
											}

											###2013-10-08 arturom, keiths, Added link to interface name if interface event.
											$C->{nmis_host_protocol} = "http" if $C->{nmis_host_protocol} eq "";
											$message
												.= "Node:\t$event_data->{node_name}\nNotification at Level$event_data->{escalate}\nEvent Elapsed Time:\t$event_age\nSeverity:\t$event_data->{level}\nEvent:\t$event_data->{event}\nElement:\t$event_data->{element}\nDetails:\t$event_data->{details}\nLink to Node: $C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_node_view&widget=false&node=$event_data->{node_name}\n";
											if ( $event_obj->event =~ /Interface/ )
											{
												my $ifIndex = undef;
												my $S       = NMISNG::Sys->new(nmisng => $self);    # sys accessor object
												if ( ( $S->init( name => $event_obj->node_name, snmp => 'false' ) ) )
												{                                  # get cached info of node only
													my $IFD = $S->ifDescrInfo();    # interface info indexed by ifDescr
													if ( NMISNG::Util::getbool( $IFD->{$event_obj->element}{collect} ) )
													{
														$ifIndex = $IFD->{$event_obj->element}{ifIndex};
														$message
															.= "Link to Interface:\t$C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_interface_view&widget=false&node=$event_data->{node_name}&intf=$ifIndex\n";
													}
												}
											}
											$message .= "\n";

											if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
											{
												if ( NMISNG::Util::getbool( $C->{mail_combine} ) )
												{
													$msgTable{$type}{$trgt}{$serial}{count}++;
													$msgTable{$type}{$trgt}{$serial}{subject}
														= "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
													$msgTable{$type}{$trgt}{$serial}{message} .= $message;
													if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} )
													{
														$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
													}
												}
												else
												{
													$msgTable{$type}{$trgt}{$serial}{subject}
														= "$event_data->{node_name} $event_data->{event} - $event_data->{element} - $event_data->{details} at $msgtime";
													$msgTable{$type}{$trgt}{$serial}{message}  = $message;
													$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
													$msgTable{$type}{$trgt}{$serial}{count}    = 1;
													$serial++;
												}
											}
										}
									}

									# meta-events are subject to Notify and Log
									$self->events->logEvent(
										node_name => $event_obj->node_name,
										event     => "$type to $target Esc$event_data->{escalate} $event_data->{event}",
										level     => $event_obj->level,
										element   => $event_obj->element,
										details   => $event_obj->details
										)
										if (NMISNG::Util::getbool( $thisevent_control->{Notify} )
										and NMISNG::Util::getbool( $thisevent_control->{Log} ) );

									$self->log->debug2(
										"Escalation $type Notification node=$event_data->{node_name} target=$target level=$event_data->{level} event=$event_data->{event} element=$event_data->{element} details=$event_data->{details} group="
											. $nmisng_node->configuration->{group} );
								}    # if $target
							}    # end email,ccopy,pager

							# now the netsends
							elsif ( $type eq "netsend" )
							{
								if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
								{
									my $message
										= "Escalation $event_data->{escalate} $event_data->{node_name} $event_data->{level} $event_data->{event} $event_data->{element} $event_data->{details} at $msgtime";
									foreach my $trgt (@x)
									{
										$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
										$serial_ns++;
										$self->log->debug2("NetSend $message to $trgt");

										# meta-events are subject to both
										$self->events->logEvent(
											node_name => $event_obj->node_name,
											event     => "NetSend $message to $trgt $event_data->{event}",
											level     => $event_obj->level,
											element   => $event_obj->element,
											details   => $event_obj->details
										) if ( NMISNG::Util::getbool( $thisevent_control->{Log} ) );
									}    #foreach
								}
							}    # end netsend
							elsif ( $type eq "syslog" )
							{
								# check if UpNotify is true, and save with this event
								# and send all the up event notifies when the event is cleared.
								if (    NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
									and $event_obj->event =~ /$C->{upnotify_stateful_events}/i
									and NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
								{
									my $ct = "$type:server";
									my @l = split( ',', $event_obj->notify );
									if ( not grep { $_ eq $ct } @l )
									{
										push @l, $ct;
										$event_obj->notify( join( ',', @l ) );
										$mustupdate = 1;
									}
								}

								if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
								{
									my $timenow = time();
									my $message
										= "NMIS_Event::$C->{server_name}::$timenow,$event_data->{node_name},$event_data->{event},$event_data->{level},$event_data->{element},$event_data->{details}";
									my $priority = NMISNG::Notify::eventToSyslog( $event_obj->level );
									if ( NMISNG::Util::getbool( $C->{syslog_use_escalation} ) )
									{
										foreach my $trgt (@x)
										{
											$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
											$msgTable{$type}{$trgt}{$serial}{priority}   = $priority;
											$serial_ns++;
											$self->log->debug2("syslog $message");
										}    #foreach
									}
								}
							}    # end syslog
							elsif ( $type eq "json" )
							{
								if (    NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
									and $event_obj->event =~ /$C->{upnotify_stateful_events}/i
									and NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
								{
									my $ct = "$type:server";
									my @l = split( ',', $event_obj->notify );
									if ( not grep { $_ eq $ct } @l )
									{
										push @l, $ct;
										$event_obj->notify( join( ',', @l ) );
										$mustupdate = 1;
									}
								}

								# amend the event - attention: this changes the live event,
								# and will be saved back!
								$mustupdate = 1;
								my $node = $nmisng_node->configuration;
								$event_obj->custom_data( 'nmis_server', $C->{server_name} );
								$event_obj->custom_data( 'customer',    $node->{customer} );
								$event_obj->custom_data( 'location', $LocationsTable->{$node->{location}}{Location} );
								$event_obj->custom_data( 'geocode',  $LocationsTable->{$node->{location}}{Geocode} );

								if ($useServiceStatusTable)
								{
									$event_obj->custom_data( 'serviceStatus',
										$ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus} );
									$event_obj->custom_data( 'statusPriority',
										$ServiceStatusTable->{$node->{serviceStatus}}{statusPriority} );
								}

								if ($useBusinessServicesTable)
								{
									$event_obj->custom_data( 'businessService',
										$BusinessServicesTable->{$node->{businessService}}{businessService} );
									$event_obj->custom_data( 'businessPriority',
										$BusinessServicesTable->{$node->{businessService}}{businessPriority} );
								}

								# Copy the fields from nodes to the event
								my @nodeFields = split( ",", $C->{'json_node_fields'} );
								foreach my $field (@nodeFields)
								{
									# uuid, name, active/activated.NMIS, cluster_id, are NOT under configuration
									my $val = ($field =~ /^(uuid|name|cluster_id)$/)?
											$nmisng_node->$field
											: ($field eq "active" or $field eq "activated.NMIS")?
											$nmisng_node->activated->{NMIS} : $node->{$field};

									$event_obj->custom_data( $field, $val );
								}

								NMISNG::Notify::logJsonEvent( event => $event_obj, dir => $C->{'json_logs'} )
									if ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) );
							}    # end json
							elsif ( NMISNG::Util::getbool( $thisevent_control->{Notify} ) )
							{
								if ( NMISNG::Util::checkPerlLib("Notify::$type") )
								{
									$self->log->debug2("Notify::$type $contact");
									my $timenow = time();
									my $datenow = NMISNG::Util::returnDateStamp();
									my $message
										= "$datenow: $event_data->{node_name}, $event_data->{event}, $event_data->{level}, $event_data->{element}, $event_data->{details}";
									foreach $contact (@x)
									{
										if ( exists $CT->{$contact} )
										{
											if ( Compat::NMIS::dutyTime( $CT, $contact ) )
											{    # do we have a valid dutytime ??
												    # check if UpNotify is true, and save with this event
												    # and send all the up event notifies when the event is cleared.
												if ( NMISNG::Util::getbool( $EST->{$esc_key}{UpNotify} )
													and $event_obj->event =~ /$C->{upnotify_stateful_events}/i )
												{
													my $ct = "$type:$contact";
													my @l = split( ',', $event_obj->notify );
													if ( not grep { $_ eq $ct } @l )
													{
														push @l, $ct;
														$event_obj->notify( join( ',', @l ) );    # fudged up
														$mustupdate = 1;
													}
												}

												#$serial
												$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
												$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
												$msgTable{$type}{$contact}{$serial_ns}{event}   = $event_data;
												$serial_ns++;
											}
										}
										else
										{
											$self->log->debug2("Contact $contact not found in Contacts table");
										}
									}
								}
								else
								{
									$self->log->debug2(
										"ERROR process_escalations problem with escalation target unknown at level$event_data->{escalate} $level type=$type"
									);
								}
							}
						}    # foreach field
					}    # endif $level
				}    # if escalate
			}    # foreach esc_key
		}    # end of outage check

		# now we're done with this event, let's update it if we have to
		if ($mustupdate)
		{
			if ( my $err = $event_obj->save( update => 1 ) )
			{
				$self->log->error("failed to save event data for event $event_data->{event}, node $event_data->{node}: $err");
			}
		}
	}

	# now send the messages that have accumulated in msgTable
	$self->log->debug2("Starting Message Sending");
	foreach my $method ( keys %msgTable )
	{
		$self->log->debug2("Method $method");
		if ( $method eq "email" )
		{
			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach my $target ( keys %{$msgTable{$method}} )
			{
				foreach my $serial ( keys %{$msgTable{$method}{$target}} )
				{
					next if $C->{mail_server} eq '';

					my ( $status, $code, $errmsg ) = NMISNG::Notify::sendEmail(

						# params for connection and sending
						sender     => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello      => $C->{mail_domain},
						usetls     => $C->{mail_use_tls},
						ipproto    => $C->{mail_server_ipproto},

						username => $C->{mail_user},
						password => NMISNG::Util::decrypt($C->{mail_password}, 'email', 'mail_password'),

						# and params for making the message on the go
						to       => $target,
						from     => $C->{mail_from},
						subject  => $msgTable{$method}{$target}{$serial}{subject},
						body     => $msgTable{$method}{$target}{$serial}{message},
						priority => $msgTable{$method}{$target}{$serial}{priority},
					);

					if ( !$status )
					{
						$self->log->error("Sending email to $target failed: $code $errmsg");
					}
					else
					{
						$self->log->debug2("Escalation Email Notification sent to $target");
					}
				}
			}
		}    # end email
		### Carbon copy notifications - no action required - FYI only.
		elsif ( $method eq "ccopy" )
		{
			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach my $target ( keys %{$msgTable{$method}} )
			{
				foreach my $serial ( keys %{$msgTable{$method}{$target}} )
				{
					next if $C->{mail_server} eq '';

					my ( $status, $code, $errmsg ) = NMISNG::Notify::sendEmail(

						# params for connection and sending
						sender     => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello      => $C->{mail_domain},
						usetls     => $C->{mail_use_tls},
						ipproto    => $C->{mail_server_ipproto},

						username => $C->{mail_user},
						password => NMISNG::Util::decrypt($C->{mail_password}, 'email', 'mail_password'),

						# and params for making the message on the go
						to       => $target,
						from     => $C->{mail_from},
						subject  => $msgTable{$method}{$target}{$serial}{subject},
						body     => $msgTable{$method}{$target}{$serial}{message},
						priority => $msgTable{$method}{$target}{$serial}{priority},
					);

					if ( !$status )
					{
						$self->log->error("Sending email to $target failed: $code $errmsg");
					}
					else
					{
						$self->log->debug2("Escalation CC Email Notification sent to $target");
					}
				}
			}
		}    # end ccopy
		elsif ( $method eq "netsend" )
		{
			foreach my $target ( keys %{$msgTable{$method}} )
			{
				foreach my $serial ( keys %{$msgTable{$method}{$target}} )
				{
					$self->log->debug2("netsend $msgTable{$method}{$target}{$serial}{message} to $target");

					# read any stdout messages and throw them away
					if ( $^O =~ /win32/i )
					{
						# win32 platform
						my $dump = `net send $target $msgTable{$method}{$target}{$serial}{message}`;
					}
					else
					{
						# Linux box
						my $dump = `echo $msgTable{$method}{$target}{$serial}{message}|smbclient -M $target`;
					}
				}    # end netsend
			}
		}

		# now the syslog
		elsif ( $method eq "syslog" )
		{
			foreach my $target ( keys %{$msgTable{$method}} )
			{
				foreach my $serial ( keys %{$msgTable{$method}{$target}} )
				{
					my $error = NMISNG::Notify::sendSyslog(
						server_string => $C->{syslog_server},
						facility      => $C->{syslog_facility},
						message       => $msgTable{$method}{$target}{$serial}{message},
						priority      => $msgTable{$method}{$target}{$serial}{priority}
							);
					$self->log->error("sendSyslog to $target failed: $error") if ($error);

				}
			}
		}

		# now the extensible stuff.......
		else
		{
			my $class       = "Notify::$method";
			my $classMethod = $class . "::sendNotification";
			if ( NMISNG::Util::checkPerlLib($class) )
			{
				eval "require $class";
				if (my $failure = $@)
				{
					$self->log->fatal("failed to load $class: $failure");
				}
				$self->log->debug2(
					"Using $classMethod to send notification to $msgTable{$method}{$target}{$serial}{contact}->{Contact}"
				);
				my $function = \&{$classMethod};
				foreach $target ( keys %{$msgTable{$method}} )
				{
					foreach $serial ( keys %{$msgTable{$method}{$target}} )
					{
						$self->log->debug2( "Notify method=$method, target=$target, serial=$serial message="
								. $msgTable{$method}{$target}{$serial}{message} );
						if ( $target and $msgTable{$method}{$target}{$serial}{message} )
						{
							$function->(
								message  => $msgTable{$method}{$target}{$serial}{message},
								event    => $msgTable{$method}{$target}{$serial}{event},
								contact  => $msgTable{$method}{$target}{$serial}{contact},
								priority => $msgTable{$method}{$target}{$serial}{priority},
								C        => $C,
								nmisng	 => $self
							);
						}
					}
				}
			}
			else
			{
				$self->log->debug2("ERROR unknown device $method");
			}
		}
	}

	$self->log->debug(&NMISNG::Log::trace()."Finished");
}

# this is a maintenance command for removing old,
# broken or unwanted files
#
# args: self, simulate (default: false, if true only reports what it would do)
# returns: hashref, success/error and info (info is array ref)
sub purge_old_files
{
	my ( $self, %args ) = @_;
	my %nukem;

	my $simulate = NMISNG::Util::getbool( $args{simulate} );
	my $C        = $self->config;
	my @info;

	push @info, "Starting to look for purgable files" . ( $simulate ? ", in simulation mode" : "" );

	# config option, extension, where to look...
	my @purgatory = (
		{
			ext => qr/\.png$/,
			minage => $C->{purge_graphcache_after} || 3600,
			location => "$C->{web_root}/cache",
			also_empties => 1,
			description => "Old Graph Images",
		},
		{
			ext          => qr/\.rrd$/,
			minage       => $C->{purge_rrd_after} || 30 * 86400,
			location     => $C->{database_root},
			also_empties => 1,
			description  => "Old RRD files",
		},
		{
			ext          => qr/\.(tgz|tar\.gz)$/,
			minage       => $C->{purge_backup_after} || 30 * 86400,
			location     => $C->{'<nmis_backups>'},
			also_empties => 1,
			description  => "Old Backup files",
		},
		{
			# old nmis state files - legacy .nmis under var
			minage => $C->{purge_state_after} || 30 * 86400,
			ext => qr/\.nmis$/,
			location     => $C->{'<nmis_var>'},
			also_empties => 1,
			description  => "Legacy .nmis files",
		},
		{
			# old nmis state files - json files but only directly in var,
			# or in network or in service_status
			minage => $C->{purge_state_after} || 30 * 86400,
			location     => $C->{'<nmis_var>'},
			path         => qr!^$C->{'<nmis_var>'}/*(network|service_status)?/*[^/]+\.json$!,
			also_empties => 1,
			description  => "Old JSON state files",
		},
		{
			# old nmis state files - json files under nmis_system,
			# except auth_failure files
			minage => $C->{purge_state_after} || 30 * 86400,
			location     => $C->{'<nmis_var>'} . "/nmis_system",
			notpath      => qr!^$C->{'<nmis_var>'}/nmis_system/auth_failures/!,
			ext          => qr/\.json$/,
			also_empties => 1,
			description  => "Old internal JSON state files",
		},
		{
			# broken empty json files - don't nuke them immediately, they may be tempfiles!
			minage       => 3600,                       # 60 minutes seems a safe upper limit for tempfiles
			ext          => qr/\.json$/,
			location     => $C->{'<nmis_var>'},
			only_empties => 1,
			description  => "Empty JSON state files",
		},
		{
			# cron job collect-performance-data files
			minage       => $C->{purge_performance_files_after} || 8 * 86400,                  
			ext          => qr/\.txt$/,
			location     => $C->{'<nmis_var>'},
			also_empties => 1,
			description  => "System performance data files",
		},
		{
			# cron job collect-top-data files
			minage       => $C->{purge_performance_top_files_after} || 8 * 86400,                  
			ext          => qr/\.csv$/,
			location     => $C->{'<nmis_var>'},
			also_empties => 1,
			description  => "System performance top data files",
		},
		{   minage => $C->{purge_jsonlog_after} || 30 * 86400,
			also_empties => 1,
			ext          => qr/\.json/,
			location     => $C->{json_logs},
			description  => "Old JSON log files",
		},

		{   minage => $C->{purge_jsonlog_after} || 30 * 86400,
			also_empties => 1,
			ext          => qr/\.json/,
			location     => $C->{config_logs},
			description  => "Old node configuration JSON log files",
		},

		{   minage => $C->{purge_reports_after} || 365 * 86400,
			also_empties => 0,
			ext          => qr/\.html$/,
			location     => $C->{report_root},
			description  => "Very old report files",
		},
		{   minage => $C->{purge_node_dumps_after} || 30 * 86400,
			also_empties => 0,
			ext          => qr/\.zip$/,
			location     => $C->{node_dumps_dir},
			description  => "Old node dumps from deleted nodes",
		},

	);

	for my $rule (@purgatory)
	{
		next if ( $rule->{minage} <= 0 );    # purging can be disabled by setting the minage to -1
		my $olderthan = time - $rule->{minage};
		next if ( !$rule->{location} );
		push @info, "checking dir $rule->{location} for $rule->{description}";

		File::Find::find(
			{   wanted => sub {
					my $localname = $_;

					# don't need it at the moment my $dir = $File::Find::dir;
					my $fn   = $File::Find::name;
					my @stat = stat($fn);

					next
						if (
						!S_ISREG( $stat[2] )    # not a file
						or ( $rule->{ext}     and $localname !~ $rule->{ext} )    # not a matching ext
						or ( $rule->{path}    and $fn !~ $rule->{path} )          # not a matching path
						or ( $rule->{notpath} and $fn =~ $rule->{notpath} )
						);                                                        # or an excluded path

					# also_empties: purge by age or empty, versus only_empties: only purge empties
					if ( $rule->{only_empties} )
					{
						next if ( $stat[7] );                                     # size
					}
					else
					{
						next
							if (
							( $stat[7] or !$rule->{also_empties} )                # zero size allowed if empties is off
							and ( $stat[9] >= $olderthan )
							);                                                    # younger than the cutoff?
					}
					$nukem{$fn} = $rule->{description};
				},
				follow => 1,
			},
			$rule->{location}
		);
	}

	for my $fn ( sort keys %nukem )
	{
		my $shortfn = File::Spec->abs2rel( $fn, $C->{'<nmis_base>'} );
		if ($simulate)
		{
			push @info, "purge: rule '$nukem{$fn}' matches $shortfn";
		}
		else
		{
			push @info, "removing $shortfn (rule '$nukem{$fn}')";
			unlink($fn) or return {error => "Failed to unlink $fn: $!", info => \@info};
		}
	}
	push @info, "Purging complete";
	return {success => 1, info => \@info};
}

# helper to get/set queue collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub queue_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_queue} = $newvalue;
	}
	return $self->{_db_queue};
}

# removes a given job queue entry
# args: id (required)
# returns: undef or error message
sub remove_queue
{
	my ( $self, %args ) = @_;
	my $id = $args{id};

	return "Cannot remove queue entry without id argument!" if ( !$id );

	my $res = NMISNG::DB::remove(
		collection => $self->queue_collection,
		query      => NMISNG::DB::get_query( and_part => {"_id" => $id},  no_regex => 1 )
	);
	return "Deleting of queue entry failed: $res->{error}"
		if ( !$res->{success} );
	return "Deletion failed: no matching queue entry found" if ( !$res->{removed_records} );

	return undef;
}

# records/updates the status of an operation
# args: id (optional but required for updating an existing record)
#  time (defaults to now),
#  activity (what succeeded/failed, freeform but required),
#  status (required, "ok", "info", "inprogress" or "error"),
#  type (event type, freeform error or status name),
#  details (optional, freeform, may be undef for delete on update),
#  stats (optional, structure, may be undef for delete on update),
#  context (what node/thing/job was involved, optional,
#   may be undef for delete on update.
#   SHOULD have context.node_uuid = singleton or array of involved nodes),
#
# returns (undef, record id) if ok, error message otherwise
sub save_opstatus
{
	my ( $self, %args ) = @_;

	my ( $when, $activity, $type, $status, $oldrec ) = @args{qw(time activity type status id)};
	return "status must be one of error, info, inprogress or ok!"
		if ( $status !~ /^(ok|info|inprogress|error)$/ );

	my $statusrec;
	if ($oldrec)
	{
		my $cursor = NMISNG::DB::find(
			collection => $self->opstatus_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $oldrec},  no_regex => 1)
		);
		$statusrec = $cursor->next if ($cursor);
		return "Cannot update nonexistent record $oldrec!" if ( !$cursor or !$statusrec );
	}

	$statusrec->{time} = $when || Time::HiRes::time;

	# activity must come in either as argument or from existing record
	$statusrec->{activity} = $activity if ( defined $activity );
	return "save_opstatus requires activity argument!\n"
		if ( !$statusrec->{activity} );

	$statusrec->{status}  = $status;
	$statusrec->{type}    = $type;
	$statusrec->{context} = $args{context} if ( exists $args{context} && defined($args{context}));    # undef is ok for deletion
	$statusrec->{details} = $args{details} if ( exists $args{details} );    # undef is ok for deletion
	$statusrec->{stats}   = $args{stats} if ( exists $args{stats} );      	# undef is ok for deletion
	delete $statusrec->{_id};                                               # must not be present for update

	my $expire_at = $statusrec->{time} + ( $self->config->{purge_opstatus_after} || 7 * 86400 );

	# to make the db ttl expiration work this must be
	# an acceptable date type for the driver version
	$statusrec->{expire_at} = Time::Moment->from_epoch($expire_at);

	my $result;
	if ($oldrec)
	{
		$result = NMISNG::DB::update(
			collection => $self->opstatus_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $oldrec}, no_regex => 1 ),
			record     => $statusrec
		);
	}
	else
	{
		$result = NMISNG::DB::insert(
			collection => $self->opstatus_collection,
			record     => $statusrec
		);
	}

	# update doesn't return the id
	return $result->{success} ? ( undef, $oldrec || $result->{id} ) : $result->{error};
}

# helper to get the status collection
sub status_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_status} = $newvalue;

	}
	return $self->{_db_status};

}

# helper to instantiate/get/update one of the dynamic collections
# for timed data, one per concept
# indices are set up on set or instantiate
#
# if no matching collection is cached, one is created and set up.
#
# args: concept (required), collection (optional new value), drop_unwanted (optional, ignored unless new value)
# returns: current collection for this concept, or undef on error (which is logged)
sub timed_concept_collection
{
	my ( $self, %args ) = @_;
	my ( $conceptname, $newhandle, $drop_unwanted ) = @args{"concept", "collection", "drop_unwanted"};

	if ( !$conceptname )
	{
		$self->log->error("cannot get concept collection without concept argument!");
		return undef;
	}
	my $collname = lc($conceptname);
	$collname =~ s/[^a-z0-9]+//g;
	$collname = "timed_" . substr( $collname, 0, 64 );    # bsts; 120 byte max database.collname
	my $stashname = "_db_$collname";

	my $mustcheckindex;

	# use and cache the given handle?
	if ( ref($newhandle) eq "MongoDB::Collection" )
	{
		$self->{$stashname} = $newhandle;
		$mustcheckindex = 1;
	}

	# or create a new one on the go?
	elsif ( !$self->{$stashname} )
	{
		$self->{$stashname} = NMISNG::DB::get_collection(
			db   => $self->get_db(),
			name => $collname
		);
		if ( ref( $self->{$stashname} ) ne "MongoDB::Collection" )
		{
			$self->log->fatal( "Could not get collection $collname: " . NMISNG::DB::get_error_string );
			return undef;
		}

		$mustcheckindex = 1;
	}

	if ($mustcheckindex)
	{
		# sole index is by time and inventory_id, compound
		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{$stashname},
			drop_unwanted => $drop_unwanted,
			indices       => [
				[Tie::IxHash->new( "time" => 1, "inventory_id" => 1 )]
				,    # for global 'find last X readings for all instances'
				[Tie::IxHash->new( "inventory_id" => 1, "time" => 1 )],   # for 'find last X readings for THIS instance'
				[{expire_at => 1}, {expireAfterSeconds => 0}],            # ttl index for auto-expiration
			]
		);
		$self->log->error("index setup failed for $collname: $err") if ($err);
	}

	return $self->{$stashname};
}

# fixme9: where should this function live? only called once, why even a function?
# args: self, sys
# returns: nothing
sub thresholdProcess
{
	my ( $self, %args ) = @_;
	my $S = $args{sys};

	# fixme why no error checking? what about negative or floating point values like 1.3e5?
	if ( $args{value} =~ /^\d+$|^\d+\.\d+$/ )
	{
		$self->log->debug2("thresholdProcess $args{event}, $args{level}, $args{element}, value=$args{value} reset=$args{reset}");

		my $details = "Value=$args{value} Threshold=$args{thrvalue}";
		if ( defined $args{details} and $args{details} ne "" )
		{
			$details = "$args{details}: Value=$args{value} Threshold=$args{thrvalue}";
		}
		my $statusResult = "ok";
		if ( $args{level} =~ /Normal/i )
		{
			Compat::NMIS::checkEvent(
				sys          => $S,
				event        => $args{event},
				level        => $args{level},
				element      => $args{element},
				details      => $details,
				value        => $args{value},
				reset        => $args{reset},
				inventory_id => $args{inventory_id}
			);
		}
		else
		{
			Compat::NMIS::notify(
				sys     => $S,
				event   => $args{event},     # this is cooked at this point and no good for context
				level   => $args{level},
				element => $args{element},
				details => $details,
				context => {
					type          => "threshold",
					source        => "snmp",           # fixme needs extension to support wmi as source
					name          => $args{thrname},
					thresholdtype => $args{type},
					index         => $args{index},
					class         => $args{class},
				},
				inventory_id => $args{inventory_id}
			);
			$statusResult = "error";
		}
		my ($cluster_id,$node_uuid) = ($S->nmisng_node) ? ($S->nmisng_node->cluster_id,$S->nmisng_node->uuid) :
			($self->config->{cluster_id}, undef);
		my $status_obj = NMISNG::Status->new(
			nmisng     => $self,
			cluster_id => $cluster_id,
			node_uuid  => $node_uuid,
			method     => "Threshold",
			type       => $args{type},
			property   => $args{thrname},
			event      => $args{event},
			index      => $args{index},
			level      => $args{level},
			status     => $statusResult,
			element    => $args{element},
			value      => $args{value},
			class      => $args{class},
			inventory_id => NMISNG::DB::make_oid( $args{inventory_id} )
		);
		my $save_error = $status_obj->save();
		if( $save_error )
		{
			$self->log->error("Failed to save status object, error:".$save_error);
		}
	}
	else
	{
		$self->log->debug2(
			"Skipped $args{thrname}, $args{event}, $args{level}, $args{element}, value=$args{value}, bad value");
	}
}

# fixme9: should be changed to use something smarter than loadInterfaceInfo!
# optional non-automatic action which updates the Links.nmis configuration(?) file
# args: self
# returns: nothing
sub update_links
{
	my ( $self, %args ) = @_;

	my $C = $self->config;

	my ( %subnets, $II, %catchall );

	$self->log->debug("update_links: Start");
	if ( !( $II = Compat::NMIS::loadInterfaceInfo() ) )
	{
		$self->log->fatal("update_links: Failed to load any interface info!");
		return;
	}

	my $links = NMISNG::Util::loadTable( dir => 'conf', name => 'Links' ) // {};

	my $link_ifTypes = $C->{link_ifTypes} || '.';
	my $qr_link_ifTypes = qr/$link_ifTypes/i;

	$self->log->debug2("update_links: Collecting Interface Linkage Information");
	foreach my $intHash ( sort keys %{$II} )
	{
		my $cnt      = 1;
		my $thisintf = $II->{$intHash};

		while ( defined( my $subnet = $thisintf->{"ipSubnet$cnt"} ) )
		{
			my $ipAddr = $thisintf->{"ipAdEntAddr$cnt"};

			if (    $ipAddr ne ""
				and $ipAddr ne "0.0.0.0"
				and $ipAddr !~ /^127/
				and NMISNG::Util::getbool( $thisintf->{collect} )
				and $thisintf->{ifType} =~ /$qr_link_ifTypes/ )
			{
				my $neednode = $thisintf->{node};
				if ( !$catchall{$neednode} )
				{
					my $nodeobj = $self->node( name => $neednode );
					die "No node named $neednode exists!\n" if ( !$nodeobj );    # fixme9: better option?

					my ( $inventory, $error ) = $nodeobj->inventory( concept => "catchall" );
					die "Failed to retrieve $neednode inventory: $error\n" if ($error);
					$catchall{$neednode} = ref($inventory) ? $inventory->data : {};
				}

				if ( !exists $subnets{$subnet}->{subnet} )
				{
					$subnets{$subnet}{subnet}      = $subnet;
					$subnets{$subnet}{address1}    = $ipAddr;
					$subnets{$subnet}{count}       = 1;
					$subnets{$subnet}{description} = $thisintf->{Description};
					$subnets{$subnet}{mask}        = $thisintf->{"ipAdEntNetMask$cnt"};
					$subnets{$subnet}{ifSpeed}     = $thisintf->{ifSpeed};
					$subnets{$subnet}{ifType}      = $thisintf->{ifType};
					$subnets{$subnet}{net1}        = $catchall{$neednode}->{netType};
					$subnets{$subnet}{role1}       = $catchall{$neednode}->{roleType};
					$subnets{$subnet}{node1}       = $thisintf->{node};
					$subnets{$subnet}{ifDescr1}    = $thisintf->{ifDescr};
					$subnets{$subnet}{ifIndex1}    = $thisintf->{ifIndex};
				}
				else
				{
					++$subnets{$subnet}{count};

					if ( !defined $subnets{$subnet}{description} )
					{    # use node2 description if node1 description did not exist.
						$subnets{$subnet}{description} = $thisintf->{Description};
					}
					$subnets{$subnet}{net2}     = $catchall{$neednode}->{netType};
					$subnets{$subnet}{role2}    = $catchall{$neednode}->{roleType};
					$subnets{$subnet}{node2}    = $thisintf->{node};
					$subnets{$subnet}{ifDescr2} = $thisintf->{ifDescr};
					$subnets{$subnet}{ifIndex2} = $thisintf->{ifIndex};
				}
			}
			$self->log->debug3( "update_links: found subnet: " . Data::Dumper->new( [$subnets{$subnet}] )->Terse(1)->Indent(0)->Pair("=")->Dump );
			$cnt++;
		}
	}

	$self->log->debug2("update_links: Generating Links datastructure");
	foreach my $subnet ( sort keys %subnets )
	{
		my $thisnet = $subnets{$subnet};
		next if ( $thisnet->{count} != 2 );    # ignore networks that are attached to only one node

		# skip subnet for same node-interface in link table
		next
			if (
			grep { $links->{$_}->{node1} eq $thisnet->{node1} and $links->{$_}->{ifIndex1} eq $thisnet->{ifIndex1} }
			( keys %{$links} ) );

		my $thislink = ( $links->{$subnet} //= {} );

		# form a key - use subnet as the unique key, same as read in, so will update any links with new information
		if (    defined $thisnet->{description}
			and $thisnet->{description} ne 'noSuchObject'
			and $thisnet->{description} ne "" )
		{
			$thislink->{link} = $thisnet->{description};
		}
		else
		{
			# label the link as the subnet if no description
			$thislink->{link} = $subnet;
		}
		$thislink->{subnet}  = $thisnet->{subnet};
		$thislink->{mask}    = $thisnet->{mask};
		$thislink->{ifSpeed} = $thisnet->{ifSpeed};
		$thislink->{ifType}  = $thisnet->{ifType};

		# define direction based on wan-lan and core-distribution-access
		# selection weights cover the most well-known types
		# fixme: this is pretty ugly and doesn't use $C->{severity_by_roletype}
		my %netweight = ( wan => 1, lan => 2, _ => 3, );
		my %roleweight = ( core => 1, distribution => 2, _ => 3, access => 4 );

		my $netweight1
			= defined( $netweight{$thisnet->{net1}} )
			? $netweight{$thisnet->{net1}}
			: $netweight{"_"};
		my $netweight2
			= defined( $netweight{$thisnet->{net2}} )
			? $netweight{$thisnet->{net2}}
			: $netweight{"_"};

		my $roleweight1
			= defined( $roleweight{$thisnet->{role1}} )
			? $roleweight{$thisnet->{role1}}
			: $roleweight{"_"};
		my $roleweight2
			= defined( $roleweight{$thisnet->{role2}} )
			? $roleweight{$thisnet->{role2}}
			: $roleweight{"_"};

		my $k
			= ( ( $netweight1 == $netweight2 && $roleweight1 > $roleweight2 ) || $netweight1 > $netweight2 )
			? 2
			: 1;

		$thislink->{net}  = $thisnet->{"net$k"};
		$thislink->{role} = $thisnet->{"role$k"};

		$thislink->{node1}      = $thisnet->{"node$k"};
		$thislink->{interface1} = $thisnet->{"ifDescr$k"};
		$thislink->{ifIndex1}   = $thisnet->{"ifIndex$k"};

		$k = $k == 1 ? 2 : 1;
		$thislink->{node2}      = $thisnet->{"node$k"};
		$thislink->{interface2} = $thisnet->{"ifDescr$k"};
		$thislink->{ifIndex2}   = $thisnet->{"ifIndex$k"};

		# dont overwrite any manually configured dependancies.
		if ( !exists $thislink->{depend} ) { $thislink->{depend} = "N/A" }

		$self->log->debug3("update_links: Adding link $thislink->{link} for $subnet to links");
	}

	NMISNG::Util::writeTable( dir => 'conf', name => 'Links', data => $links );
	$self->log->warn("update_links: Finished; check table Links and update link names and other entries");

	$self->log->debug("update_links: Finished");
}

# job queue handling functions follow
# queued jobs have time (=actual ts for when the work should be done),
# a type marker ("collect", "update", "threshold" etc),
# a priority between 0..1 incl.
# a hash of args (= anything required to handle the job),
# an in_progress marker (=ts when this job was started, 0 if not started yet)
# and an optional status subhash with info about the operation while being in_progress (e.g. pid)

# this function adds or updates a queued job entry
# if _id is present, the matching record is updated (but see atomic);
# otherwise a new record is created
#
# args: jobdata (= hash of all required queuing info, required),
# atomic (optional, hash of further clauses for selection)
#
# if atomic is present, then _id AND the atomic clauses are used as update query.
# atomic is not relevant for insertion of new records.
#
# returns: (undef,id) or error message
sub update_queue
{
	my ( $self, %args ) = @_;
	my ( $jobdata, $atomic ) = @args{"jobdata", "atomic"};

	return "Cannot update queue entry without valid jobdata argument!"
		if (
		   ref($jobdata) ne "HASH"
		or !keys %$jobdata
		or !$jobdata->{type}

		# 0 is ok, absence is not
		or !defined( $jobdata->{priority} )
		or !$jobdata->{time}

		# 0 is ok, absence is not
		or !defined( $jobdata->{in_progress} )
		);

	# verify that the type of activity is one of the schedulable ones
	return "Unrecognised job type \"$jobdata->{type}\"!"
		if ( $jobdata->{type}
		!~ /^(update_links|collect|update|services|thresholds|escalations|metrics|configbackup|purge|dbcleanup|selftest|permission_test|plugins|delete_nodes|update_nodes|create_nodes|set_nodes|unset_nodes)$/
		);

	return
		"Job type \"$jobdata->{type}\" not schedulable because of configuration global_threshold or threshold_poll_node"
		if (
		$jobdata->{type} eq "thresholds"
		&& (  !NMISNG::Util::getbool( $self->config->{global_threshold} )
			|| NMISNG::Util::getbool( $self->config->{threshold_poll_node} ) )
		);

	# perform minimal argument validation
	if ( $jobdata->{type} =~ /^(collect|update|services|plugins)$/ )
	{
		return "Invalid job data, missing or empty args property!"
			if ( ref( $jobdata->{args} ) ne "HASH" or !keys %{$jobdata->{args}} );
	}

	if ( $jobdata->{type} =~ /^(collect|update|services)$/
		and !$jobdata->{args}->{uuid} )
	{
		return "Invalid job data, args must contain uuid property!";
	}
	
	if ( $jobdata->{type} =~ /^(delete_nodes)$/
		and !$jobdata->{args}->{uuid} and !$jobdata->{args}->{node})
	{
		return "Invalid job data, args must contain uuid or names property!";
	}
	
	if ( $jobdata->{type} =~ /^(update_nodes|create_nodes|set_nodes|unset_nodes)$/
		and !$jobdata->{args}->{data} )
	{
		return "Invalid job data, args must contain data property for update_nodes and create_nodes!";
	}
	if ($jobdata->{type} eq "collect"
		and (  !defined( $jobdata->{args}->{wantsnmp} )
			or !defined( $jobdata->{args}->{wantwmi} ) )
		)
	{
		return "Invalid job data, args is missing wantsnmp or wantwmi properties!";
	}
	if ( $jobdata->{type} eq "plugins" )
	{
		return "Invalid job data, args has invalid or empty plugin phase property"
			if ( !defined( $jobdata->{args}->{phase} ) or $jobdata->{args}->{phase} !~ /^(update|collect)$/ );
		return "Invalid job data, args has no or empty uuid list property"
			if ( ref( $jobdata->{args}->{uuid} ) ne "ARRAY" or !@{$jobdata->{args}->{uuid}} );
	}

	my $jobid = $jobdata->{_id};
	delete $jobdata->{_id};
	my $isnew = !$jobid;
	if ( !$jobid )
	{
		my $res = NMISNG::DB::insert(
			collection => $self->queue_collection,
			record     => $jobdata
		);
		return "Insertion of queue entry failed: $res->{error}" if ( !$res->{success} );
		$jobdata->{_id} = $jobid = $res->{id};
	}
	else
	{
		# extend the query with atomic-operation enforcement clauses if any are given
		my %qargs = ( _id => $jobid );
		if ( ref($atomic) eq "HASH" && keys %$atomic )
		{
			map { $qargs{$_} = $atomic->{$_}; } ( keys %$atomic );
		}

		my $res = NMISNG::DB::update(
			collection => $self->queue_collection,
			query      => NMISNG::DB::get_query( and_part => \%qargs ),
			record     => $jobdata
		);
		$jobdata->{_id} = $jobid;    # put it back!
		return "Update of queue entry failed: $res->{error}" if ( !$res->{success} );
		return "No matching object!"                         if ( !$res->{updated_records} );
	}
	return ( undef, $jobid );
}

# export and encapsulate most of one node's data into a single zip file
# primarily meant for diagnostics on a different machine
#
# this function is likely to be quite memory-hungry,
# and temporary directories are NOT REMOVED until the process terminates!
#
# args: uuid (=node's uuid) or name (=node name),
#  target (=full path to final file),
#  options (optional, hash of extra things to include/skip)
#   historic_events => 0 (default) or 1, only include current events if 0
#   opstatus_limit => N or undef, default undef. include N most recent records or all
#   rrd => 0 (default) or 1 to include all rrd files of this node
#
# returns: hashref, success/error
sub dump_node
{
	my ($self, %args) = @_;
	my $targetfile = $args{target};

	my $uuid = $args{uuid};
	my $nodename = $args{name};		# much less preferrable
	my $override = $args{override}; # Override file if allready exists
	my $setperms = $args{setperms} // 1; # Update file permissions

	my $options = ref($args{options}) eq 'HASH'? $args{options} : {};

	return { error => "target argument missing!" } if (!$targetfile);
	return { error => "target \"$targetfile\" already exists, not overwriting!" } if (-e $targetfile && !$override);
	return { error => "uuid and name arguments missing!" }
	if (!$uuid && !$nodename);

	# node existence check gives us the node config data
	my $md = $self->get_nodes_model(uuid => $uuid, name => $nodename);
	if (my $error = $md->error)
	{
		return { error => "failed to lookup node: $error" };
	}
	elsif ($md->count != 1)
	{
		return { error => "invalid uuid, ".$md->count." matching nodes" };
	}
	my $noderec = $md->data->[0];
	$uuid //= $noderec->{uuid};
	$nodename //= $noderec->{name};

	# create temp dir first, subdirs for each of the involved db collections
	my $td = eval { File::Temp::tempdir("dump-$noderec->{uuid}-XXXXXXX",
																			TMPDIR => 1, CLEANUP => 1); }; # under /tmp and get rid of it later
	return { error => "could not create temp dir: $@" } if ($@ or !-d $td);

	for my $collname (qw(nodes events inventory latest_data opstatus status))
	{
		mkdir("$td/$collname") or return { error => "could not create dir $td/$collname: $!" };
	}

	# now collect the things in need of dumping
	# each dumped thing is named using its db id - for stuff from db, or the plain filename for rrd
	my @todump = ( { where => "nodes", what => $noderec } );
	my %dedup;										# rrd only

	# inventory items for this node, and latest_data for each
	# and optionally also the rrd files
	$md = $self->get_inventory_model(node_uuid => $uuid);
	if (my $error = $md->error)
	{
		return { error => "failed to lookup inventory records: $error" };
	}
	for my $oneinv (@{$md->data})
	{
		delete $oneinv->{expire_at};	# undesirable in the exported data
		push @todump, { where => "inventory", what => $oneinv };

		# the inventory's storage structure tracks the relevant rrd files,
		# but unfortunately not for all rrds (e.g health/health.rrd,
		# health/mib2ip.rrd and others),
		# and some may show up multiple times which causes weird duplication in the zip)
		if ($options->{rrd})
		{
			if (ref($oneinv->{storage}) eq "HASH")
			{
				for my $subconcept (keys %{$oneinv->{storage}})
				{
					my $thissubconcept = $oneinv->{storage}->{$subconcept};
					next if (ref($thissubconcept) ne "HASH"
									 or !defined $thissubconcept->{"rrd"});

					my $rrdrelpath = $thissubconcept->{"rrd"};
					next if ((!-f $self->config->{database_root} . $rrdrelpath)
									 or $dedup{$rrdrelpath});
					$dedup{$rrdrelpath} = 1;
					push @todump, { where => "rrd", what => { _id => $rrdrelpath }};
				}
			}
		}

		# last_data is reachable by inventory id
		my $lmd = $self->get_latest_data_model(filter => { inventory_id => $oneinv->{_id} });
		if (my $error = $lmd->error)
		{
			return { error => "failed to lookup latest_data records: $error" };
		}
		map {	delete $_->{expire_at}; push @todump, { where => "latest_data", what => $_ }; } (@{$lmd->data});
	}

	# fill in the unlinked/unmodelled rrd files via the filesystem :-/
	# this is messy as it cannot take a potential custom common_database scheme into account
	# (ie. rrds not under /nodes/$lowercasednode/)
	# but az doesn't know of any way to enumerate the non-inventory-backed oddball rrds
	if ($options->{rrd})
	{
		my $dbrootdir = $self->config->{database_root};
		my @whichdirs = 			$self->config->{database_root}."/nodes/$nodename";
		# we hates that legacy compat lowercase, we do...
		push @whichdirs, $self->config->{database_root}."/nodes/".lc($nodename)
				if ($nodename ne lc($nodename));

		eval {
			File::Find::find(
				{
					wanted => sub
					{
						my $fn = $File::Find::name;
						next if (!-f $fn);
						(my $semirelname = $fn) =~ s!^$dbrootdir!!;
						push @todump, { where => "rrd", what => { _id => $semirelname }}
						if (!$dedup{$semirelname});
					},
					follow => 1,
				},
				@whichdirs);
		};
	}

	# events, status, opstatus: bound to node uuid

	# events: both current and historic or only current?
	# get_events_model defaults to current only
	$md = $self->events->get_events_model(filter => { node_uuid => $uuid,
									historic => $options->{historic_events}? [0,1]: 0,
									cluster_id => $noderec->{cluster_id}
									});
	if (my $error = $md->error)
	{
		return { error => "failed to lookup event records: $error" };
	}
	map {	delete $_->{expire_at}; push @todump, { where => "events", what => $_ }; } (@{$md->data});

	$md = $self->get_status_model(filter => { node_uuid => $uuid});
	if (my $error = $md->error)
	{
		return { error => "failed to lookup event records: $error" };
	}
	map {	delete $_->{expire_at}; push @todump, { where => "status", what => $_ }; } (@{$md->data});

	# opstatus: selectable by node uuid within context;
	# sort and limit only required if opstatus_limit is set
	my @selectargs = ("context.node_uuid" => $uuid);
	my $nomorethan = $options->{opstatus_limit};
	if ($nomorethan && $nomorethan > 0)
	{
		push @selectargs, ("sort" => { time => -1 }, "limit" => $nomorethan );
	}

	$md = $self->get_opstatus_model(@selectargs);
	if (my $error = $md->error)
	{
		return { error => "failed to lookup opstatus records: $error" };
	}
	map {	delete $_->{expire_at}; push @todump, { where => "opstatus", what => $_ }; } (@{$md->data});

 	# ready, go forth, dump your zip and prosper...
	my $ziperr;
	Archive::Zip::setErrorHandler(sub { $ziperr = shift;}); # a::z croaks by default
	my $zip = Archive::Zip->new();
	for my $dumpme (sort { $a->{where} cmp $b->{where} } @todump)
	{
		my $is_rrd_file = ($dumpme->{where} eq "rrd");
		my ($fullpath,$zipname);

		if ($is_rrd_file)
		{
			my $relfile = $dumpme->{what}->{_id};
			$zipname = "$uuid/$dumpme->{where}$relfile"; # rrd path is relative but with leading /
			$fullpath = $self->config->{database_root} . $relfile;
		}
		else
		{
			my $relfile = "$dumpme->{where}/$dumpme->{what}->{_id}.json";
			$fullpath = "$td/$relfile";
			$zipname = "$uuid/$relfile";
			return { error => "file clash: \"$fullpath\" already exists!" } if (-e $fullpath);

			my $jsondata = eval { JSON::XS->new->convert_blessed(1)->utf8(1)->encode($dumpme->{what}); };
			if ($@)
			{
				print STDERR "unconvertable object: ".Dumper($dumpme->{what}); # shouldn't be reached so noise is ok
				return { error => "failed to convert object type $dumpme->{where}, id $dumpme->{what}->{_id}: $@"	};
			}
			Mojo::File->new($fullpath)->spurt($jsondata);
		}
		return { error => "could not add file $fullpath to zip!" }
		if (!$zip->addFile({filename => $fullpath, zipName => $zipname}));
	}

	my $res = $zip->writeToFileNamed($targetfile);
	if ($res != Archive::Zip::AZ_OK)
	{
		return { error => "zip creation failed: $ziperr\n" };
	}

	if ($setperms) {
		my $user = $self->config->{nmis_user};
		my $group = $self->config->{nmis_group};
		
		system("chown","-R", "$user:$group",
						 $targetfile);

		system("chmod","-R","g+rw", $targetfile);
	}
	
	return { success => 1};
}

# take a dumped zip file and restore the node IFF it doesn't already exist
# args: source (=full path to file), localise_ids
# returns: hashref, success/error, node (= node config record, if successful)
sub undump_node
{
	my ($self, %args) = @_;
	my $sourcefile = $args{source};
	my $localiseme = $args{localise_ids};

	return { error => "source argument missing!" } if (!$sourcefile);
	return { error => "source \"$sourcefile\" does not exist or is not readable!" } if (!-r $sourcefile);

	# let's get a tempdir for unpacking the zip file
	my $td = File::Temp::tempdir( "undump.XXXXXXX", CLEANUP => 1, TMPDIR => 1 );

	my $ziperr;
	Archive::Zip::setErrorHandler(sub { $ziperr = shift;}); # a::z croaks by default

	my $zip = Archive::Zip->new();
	if ($zip->read($sourcefile) != Archive::Zip::AZ_OK)
	{
		return { error => "failed to open \"$sourcefile\": $ziperr" };
	}

	# zip structure acceptable?
	my @filenames = $zip->memberNames;
	my @nodefiles = grep(m!^[a-f0-9-]+/nodes/[a-f0-9]+\.json$!, @filenames);
	return { error => "invalid structure: must contain exactly one node record!" } if (@nodefiles != 1);
	# if dumped with rrd=1, then such will also exist
	my @rrdfiles = grep(m!^[a-f0-9-]+/rrd/.+\.rrd$!, @filenames);

	return { error => "invalid structure: unexpected (extra) data present!" }
	if (grep(!m!^[a-f0-9-]+/(rrd|nodes|events|inventory|latest_data|opstatus|status)/!, @filenames));


	# a::z is very very slow on unpacking, let's look for unzip as first choice
	if (NMISNG::Util::type_which("unzip"))
	{
		my $res = system("unzip", "-q", "-d", $td, $sourcefile); # quiet and under that dir
		warn "unzip failed to unpack $sourcefile! \n" if ($res >> 8);
	}
	else
	{
		warn "unzipping ".(scalar @filenames)." files, please be patient...\n";
	}

	my $noderec = eval { decode_json($zip->contents($nodefiles[0])) };
	return { error => "invalid data: $nodefiles[0] unparsable: $@" }
	if ($@ or ref($noderec) ne "HASH" or !keys %$noderec  or !$noderec->{uuid});

	# localisation required? then figure out the old cluster_id and replace it everywhere
	my $foreign_cluster;
	my $this_cluster = $self->config->{cluster_id};
	if ($localiseme)
	{
		my $maybeforeign = $noderec->{cluster_id};
		if ($maybeforeign ne $this_cluster)
		{
			$foreign_cluster = $maybeforeign;
			$noderec->{cluster_id} = $this_cluster;
		}
	}
	# Set last update to now, it is new in the system.
	$noderec->{lastupdate} = time;
	
	return { error => "invalid structure: node uuid doesn't match file names" }
	if (grep(!m!^$noderec->{uuid}/!, @filenames));

	my $existing = $self->get_nodes_model(uuid => $noderec->{uuid}, limit => 1, fields_hash => { name => 1});
	return { error => "a clashing node named \""
							 .$existing->data->[0]->{name}."\" with uuid \"$noderec->{uuid}\" exists!" }
	if ($existing->count);

	# right, looks ok - lets collect first (abort if any are duds) then insert them all
	my @insertme = ({ where => "nodes", what => $noderec});
	for my $fn (@filenames)
	{
		next if ($fn eq $nodefiles[0] or $fn =~ /\.rrd$/);

		(undef, my $collection, undef) = split(m!/!,$fn); # uuid/collection/oid.json, and oid is embedded

		# extracting contents with a::z is  very slow, so prefer already undumped stuff
		if (!-f "$td/$fn")
		{
			my $res = $zip->extractMember($fn, "$td/$fn");
			return { error => "failed to unpack \"$fn\": $ziperr" }
			if ($res != Archive::Zip::AZ_OK);
		}

		my $rawdata = Mojo::File->new("$td/$fn")->slurp;
		$rawdata =~ s/"$foreign_cluster"/"$this_cluster"/g
				if ($foreign_cluster);

		my $entry = eval { decode_json($rawdata); };
		return { error => "invalid data: $fn unparsable: $@" }
		if ($@ or ref($entry) ne "HASH" or !keys %$entry or !$entry->{_id});
		push @insertme, { where => $collection, what => $entry};
	}

	for my $onething (@insertme)
	{
		
		my $collfunc = "$onething->{where}_collection";
		my $res = NMISNG::DB::insert(collection => $self->$collfunc,
																 record => $onething->{what},
																 constraints => 1); # constrain_record is vital for $oid, $binary...
		return { error => "failed to insert record into $onething->{where} collection: $res->{error}" }
		if (!$res->{success});
	}

	# and, if there are rrd files then unpack them as well
	my $dbdir = $self->config->{database_root};
	for my $zippedrrd (@rrdfiles)
	{
		( my $targetfn = $zippedrrd ) =~ s!^$noderec->{uuid}/rrd!$dbdir!;
		( my $targetdir = $targetfn ) =~  s!/[^/]+$!!;

		my $error;
		File::Path::make_path($targetdir,
													{ error => \$error,
														mode =>  0755 } ); # umask is applied to this :-/
		NMISNG::Util::setFileProtDiag(file => $targetdir);
		if (ref($error) eq "ARRAY" and @$error)
		{
			my @errors;
			for my $issue (@$error)
			{
				push @errors, join(": ", each %$issue);
			}
			return { error => "failed to create directory $targetdir: ".join(", ",@errors)  };
		}
		# again, already unzipped to be preferred
		if (-f "$td/$zippedrrd")
		{
			my $res = File::Copy::cp("$td/$zippedrrd", $targetfn);
			return { error => "could not copy $zippedrrd to $targetfn: $!" } if (!$res);
		}
		else
		{
			my $res = $zip->extractMember( $zippedrrd, $targetfn);
			return { error => "could not unpack $zippedrrd to $targetfn: $ziperr" } if ($res != Archive::Zip::AZ_OK);
		}
		NMISNG::Util::setFileProtDiag(file => $targetfn);
	}
	return { success => 1, node => $noderec };
}

# Returns all the information available from a poller (Remote)
# args: filter
sub get_remote
{
	my ($self, %args) = @_;
	my $filter = $args{filter};

	my $fields_hash = $args{fields_hash};
	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $model_data = [];
	my $query_count;
	my $res;

	if ( $args{count} )
	{
		$res = NMISNG::DB::count(
			collection => $self->remote_collection,
			query      => $q,
			verbose    => 1
		);

		$query_count = $res->{count};
	}

	# if you want only a count but no data, set count to 1 and limit to 0
	my $cursor = NMISNG::DB::find(
			collection  => $self->remote_collection,
			query       => $q,
			fields_hash => $fields_hash,
			sort        => $args{sort},
			limit       => $args{limit},
			skip        => $args{skip}
		);

	while ( my $entry = $cursor->next )
	{
		push @$res, $entry;
	}

	return $res;
}

# Returns the server name
# args: cluster_id
# Return server_name
sub get_server_name
{
	my ($self, %args) = @_;
	my $cluster_id = $args{cluster_id};

	return undef if (!$cluster_id);
	return $self->config->{server_name} if ($cluster_id eq $self->config->{cluster_id});

	my $model_data = [];
	my $query_count;
	my $res;

	# if you want only a count but no data, set count to 1 and limit to 0
	my $cursor = NMISNG::DB::find(
			collection  => $self->remote_collection,
			query       => {cluster_id => $cluster_id},
			fields_hash => {server_name => 1}
		);

	# Should only return one. 
	my $entry = $cursor->next;
	return $entry->{server_name};
}

# Returns the cluster_id
# args: server_name
# Return cluster_id
sub get_cluster_id
{
	my ($self, %args) = @_;
	my $server_name = $args{server_name};

	return undef if (!$server_name);
	return $self->config->{cluster_id} if ($server_name eq $self->config->{server_name});

	my $model_data = [];
	my $query_count;
	my $res;

	# if you want only a count but no data, set count to 1 and limit to 0
	my $cursor = NMISNG::DB::find(
			collection  => $self->remote_collection,
			query       => {server_name => $server_name},
			fields_hash => {cluster_id => 1}
		);

	# Should only return one. 
	my $entry = $cursor->next;
	return $entry->{cluster_id};
}

1;
