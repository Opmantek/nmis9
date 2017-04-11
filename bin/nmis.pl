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
use strict;

# local modules live in <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use URI::Escape;
use Cwd qw();
use Time::HiRes;    # also needed by nmis::timing, but bsts
use Socket;
use Net::SNMP qw(oid_lex_sort);
use Proc::ProcessTable;
use Proc::Queue ':all';
use Data::Dumper;
use File::Find;
use File::Spec;
use Statistics::Lite qw(mean);
use POSIX qw(:sys_wait_h);

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMIS;
use NMIS::Connect;
use NMIS::Timing;
use NMIS::UUID;
use csv;
use rrdfunc;
use func;
use ip;
use sapi;
use ping;
use notify;
use Mib;
use Sys;
use DBfunc;

$Data::Dumper::Indent = 1;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table, memorize startup time
my $starttime = Time::HiRes::time;
my $C = loadConfTable( conf => $nvp{conf}, debug => $nvp{debug}, info => $nvp{info} );
die "nmis cannot operate without config!\n" if ( ref($C) ne "HASH" );

# and the status of the database dir, as reported by the selftest - 0 bad, 1 ok, undef unknown
# this is used by rrdfunc::createRRD(), so needs to be scoped suitably.
our $selftest_dbdir_status;
$selftest_dbdir_status = undef;

# check for global collection off or on
# useful for disabling nmis poll for server maintenance, nmis upgrades etc.
my $lockoutfile = $C->{'<nmis_conf>'} . "/NMIS_IS_LOCKED";

if ( -f $lockoutfile or getbool( $C->{global_collect}, "invert" ) )
{
	# if nmis is locked, run a quick nondelay selftest so that we have something for the GUI
	my $varsysdir = $C->{'<nmis_var>'} . "/nmis_system";
	if ( !-d $varsysdir )
	{
		createDir($varsysdir);
		setFileProt($varsysdir);
	}
	my $selftest_cache = "$varsysdir/selftest";

	my ( $allok, $tests ) = func::selftest(
		config                 => $C,
		delay_is_ok            => 'false',
		report_database_status => \$selftest_dbdir_status,
		perms                  => 'false'
	);
	writeHashtoFile(
		file => $selftest_cache,
		json => 1,
		data => {status => $allok, lastupdate => time, tests => $tests}
	);
	info( "Selftest completed (status " . ( $allok ? "ok" : "FAILED!" ) . "), cache file written" );
	if ( -f $lockoutfile )
	{
		my $installerpresence = "/tmp/nmis_install_running";

		# installer should not need to lock this box for more than a few minutes
		if ( -f $installerpresence && ( stat($installerpresence) )[9] > time - 3600 )
		{
			logMsg("INFO NMIS is currently disabled, installer is performing upgrade, exiting.");
			exit(0);
		}
		else
		{
			logMsg("WARNING NMIS is currently disabled! Remove the file $lockoutfile to re-enable.");
			die "Attention: NMIS is currently disabled!\nRemove the file $lockoutfile to re-enable.\n\n";
		}
	}
	else
	{
		die
			"Attention: NMIS is currently disabled!\nSet the configuration variable \"global_collect\" to \"true\" to re-enable.\n\n";
	}
}

# all arguments are now stored in nvp (name value pairs)
my $type     = lc $nvp{type};
my $node     = lc $nvp{node};
my $rmefile  = $nvp{rmefile};
my $runGroup = $nvp{group};
my $sleep    = $nvp{sleep};

### 2012-12-03 keiths, adding some model testing and debugging options.
my $model = getbool( $nvp{model} );

# multiprocessing: commandline overrides config
my $mthread    = ( exists $nvp{mthread}    ? $nvp{mthread}    : $C->{nmis_mthread} )    || 0;
my $maxThreads = ( exists $nvp{maxthreads} ? $nvp{maxthreads} : $C->{nmis_maxthreads} ) || 1;

my $mthreadDebug = $nvp{mthreaddebug};    # cmdline only for this debugging flag

# park the list of collect/update plugins globally
my @active_plugins;

Proc::Queue::size($maxThreads); # changing limit of concurrent processes
Proc::Queue::trace(0);          # trace mode on
Proc::Queue::debug(0);          # debug is off
Proc::Queue::delay(0.02);       # set 20 milliseconds as minimum delay between fork calls, reduce to speed collect times

# if no type given, just run the command line options
if ( $type eq "" )
{
	print "No runtime option type= on command line\n\n";
	checkArgs();
	exit(1);
}

print qq/
Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;
This is free software licensed under GNU GPL, and you are welcome to
redistribute it under certain conditions; see www.opmantek.com or email
contact\@opmantek.com

NMIS version $NMIS::VERSION

/ if $C->{debug} or $C->{info};

# the first thing we do is to upgrade up the event
# data structure - it's a nop if it was already done.
&NMIS::upgrade_events_structure;

# ditto for nodeconf
&NMIS::upgrade_nodeconf_structure;

if ( $type =~ /^(collect|update|services)$/ )
{
	runThreads( type => $type, node => $node, mthread => $mthread, mthreadDebug => $mthreadDebug );
}
elsif ( $type eq "escalate" ) { runEscalate(); printRunTime(); }    # included in type=collect
elsif ( $type eq "config" ) { checkConfig( change => "true" ); }
elsif ( $type eq "audit" ) { checkConfig( audit => "true", change => "false" ); }
elsif ( $type eq "links" )      { runLinks(); }                                            # included in type=update
elsif ( $type eq "apache" )     { printApache(); }
elsif ( $type eq "apache24" )   { printApache24(); }
elsif ( $type eq "crontab" )    { printCrontab(); }
elsif ( $type eq "summary" )    { nmisSummary(); printRunTime(); }                         # included in type=collect
elsif ( $type eq "rme" )        { loadRMENodes($rmefile); }
elsif ( $type eq "threshold" )  { runThreshold($node,1); printRunTime(); }                   # included in type=collect
elsif ( $type eq "master" )     { nmisMaster(); printRunTime(); }                          # included in type=collect
elsif ( $type eq "groupsync" )  { sync_groups(); }
elsif ( $type eq "purge" )      { my $error = purge_files(); die "$error\n" if $error; }
elsif ( $type eq 'list_nodes' ) { list_nodes() }
else                            { checkArgs(); }

exit;

#=========================================================================================
sub list_nodes
{
	my $lnt = NMIS::loadLocalNodeTable();
	print "Nodes:" . Dumper($lnt);
}

# run collection-type functions, possibly spread across multiple processes
sub runThreads
{
	my %args         = @_;
	my $type         = $args{type};
	my $node_select  = $args{'node'};
	my $mthread      = getbool( $args{mthread} );
	my $mthreadDebug = getbool( $args{mthreadDebug} );
	my $debug_watch;

	dbg("Starting, operation is $type");

	# first thing: do a selftest and cache the result. this takes about five seconds (for the process stats)
	# however, DON'T do one if nmis is run in handle-just-this-node mode, which is usually a debugging exercise
	# which shouldn't be delayed at all. ditto for (possibly VERY) frequent type=services
	if ( !$node_select and $type ne "services" )
	{
		info("Ensuring correct permissions on conf and model directories...");
		setFileProtDirectory( $C->{'<nmis_conf>'},   1 );    # do recurse
		setFileProtDirectory( $C->{'<nmis_models>'}, 0 );    # no recursion required

		info("Starting selftest (takes about 5 seconds)...");
		my $varsysdir = $C->{'<nmis_var>'} . "/nmis_system";
		if ( !-d $varsysdir )
		{
			createDir($varsysdir);
			setFileProt($varsysdir);
		}

		my $selftest_cache = "$varsysdir/selftest";

		# check the current state, to see if a perms check is due? once every 2 hours
		my $laststate = readFiletoHash( file => $selftest_cache, json => 1 );
		my $wantpermsnow = 1
			if ( ref($laststate) ne "HASH"
			|| !defined( $laststate->{lastupdate_perms} )
			|| $laststate->{lastupdate_perms} + 7200 < time );

		my ( $allok, $tests ) = func::selftest(
			config                 => $C,
			delay_is_ok            => 'true',
			perms                  => $wantpermsnow,
			report_database_status => \$selftest_dbdir_status
		);

		# keep the old permissions state if this test did not run a permissions test
		# hardcoded test name isn't great, though.
		if ( !$wantpermsnow )
		{
			$laststate ||= {tests => []};

			my ($oldstate) = grep( $_->[0] eq "Permissions", @{$laststate->{tests}} );    # there will at most one
			if ( defined $oldstate )
			{
				my ($targetidx) = grep( $tests->[$_]->[0] eq "Permissions", ( 0 .. $#{$tests} ) );
				if ( defined $targetidx )
				{
					$tests->[$targetidx] = $oldstate;
				}
				else
				{
					push @$tests, $oldstate;
				}
				$allok = 0 if ( $oldstate->[1] );                                         # not ok until that's cleared
			}
		}

		writeHashtoFile(
			file => $selftest_cache,
			json => 1,
			data => {
				status           => $allok,
				lastupdate       => time,
				lastupdate_perms => (
					  $wantpermsnow ? time
					: $laststate    ? $laststate->{lastupdate_perms}
					:                 undef
				),
				tests => $tests
			}
		);
		info( "Selftest completed (status " . ( $allok ? "ok" : "FAILED!" ) . "), cache file written" );
	}

	# load all the files we need here
	loadEnterpriseTable() if $type eq 'update';    # load in cache
	dbg( "table Enterprise loaded", 2 );

	my $NT = loadLocalNodeTable();                 # only local nodes
	dbg( "table Local Node loaded", 2 );

	# create uuids for all nodes that might still need them
	# this changes the local nodes table!
	if ( my $changed_nodes = createNodeUUID() )
	{
		$NT = loadLocalNodeTable();
		dbg( "table Local Node reloaded after uuid updates", 2 );
	}
	my $C = loadConfTable();    # config table from cache

	# check if the fping results look sensible
	# compare nr of pingable active nodes against the fping results
	if ( getbool( $C->{daemon_fping_active} ) )
	{
		my $pt = loadTable( dir => 'var', name => 'nmis-fping' );    # load fping table in cache
		my $cnt_pt = keys %{$pt};

		my $active_ping = grep( getbool( $_->{active} ) && getbool( $_->{ping} ), values %{$NT} );

		# missing more then 10 nodes that should have been pinged?
		if ( $cnt_pt + 10 < $active_ping )
		{
			logMsg("ERROR fping table missing too many entries, count fping=$cnt_pt count nodes=$active_ping");
			$C->{daemon_fping_failed} = 'true';                      # remember for runPing
		}
	}
	dbg("all relevant tables loaded");

	my $debug_global = $C->{debug};
	my $debug        = $C->{debug};
	my $PIDFILE;
	my $pid;

	# used for plotting major events on world map in 'Current Events' display
	$C->{netDNS} = 0;
	if ( getbool( $C->{DNSLoc} ) )
	{
		# decide if Net::DNS is available to us or not
		if ( eval "require Net::DNS" )
		{
			$C->{netDNS} = 1;
			require Net::DNS;
		}
		else
		{
			print "Perl Module Net::DNS not found, Can't use DNS LOC records for Geo info, will try sysLocation\n"
				if $debug;
		}
	}

	runDaemons();    # start daemon processes

	### test if we are still running, or zombied, and cron will email somebody if we are
	### collects should not run past 5mins - if they do we have a problem
	### updates can run past 5 mins, BUT no two updates should run at the same time
	### for potentially frequent type=services we don't do any of these.
	if ( $type eq 'collect' or $type eq "update" )
	{
		# unrelated but also for collect and update only
		@active_plugins = &load_plugins;

		# first find all other nmis collect processes
		my $others = func::find_nmis_processes( type => $type, config => $C );

		# if this is a collect and if told to ignore running processes (ignore_running=1/t),
		# then only warn about processes and don't shoot them.
		# the same should be done if this is an interactive run with info or debug
		if ((   $type eq "collect" and ( getbool( $nvp{ignore_running} )
					or $C->{debug}
					or $C->{info} )
			)
			or ( $type eq "update" and ( $C->{debug} or $C->{info} ) )
			)
		{
			for my $pid ( keys %{$others} )
			{
				logMsg(
					"INFO ignoring old process $pid that is still running: $type, $others->{$pid}->{node}, started at "
						. returnDateStamp( $others->{$pid}->{start} ) );
			}
		}
		else
		{
			my $eventconfig       = loadTable( dir => 'conf', name => 'Events' );
			my $event             = "NMIS runtime exceeded";
			my $thisevent_control = $eventconfig->{$event} || {Log => "true", Notify => "true", Status => "true"};

			# if not told otherwise, shoot the others politely
			for my $pid ( keys %{$others} )
			{
				print STDERR "Error: killing old NMIS $type process $pid which has not finished!\n";
				logMsg("ERROR killing old NMIS $type process $pid which has not finished!");

				kill( "TERM", $pid );

			   # and raise an event to inform the operator - unless told NOT to
			   # ie: either disable_nmis_process_events is set to true OR the event control Log property is set to false
				if ((      !defined $C->{disable_nmis_process_events}
						or !getbool( $C->{disable_nmis_process_events} ) and getbool( $thisevent_control->{Log} )
					)
					)
				{
					# logging this event as the node name so it shows up as a problem with the node
					logEvent(
						node    => $others->{$pid}->{node},
						event   => $event,
						level   => "Warning",
						element => $others->{$pid}->{node},
						details => "Killed process $pid, $type of $others->{$pid}->{node}, started at "
							. returnDateStamp( $others->{$pid}->{start} )
					);
				}
			}
			if ( keys %{$others} )    # for the others to shut down cleanly
			{
				my $grace = 5;
				logMsg("INFO sleeping for $grace seconds to let old NMIS processes clean up");
				sleep($grace);
			}
		}
	}

	# the signal handler handles termination more-or-less gracefully,
	# and knows about critical sections
	$SIG{INT}  = \&catch_zap;
	$SIG{TERM} = \&catch_zap;
	$SIG{HUP}  = \&catch_zap;
	$SIG{ALRM} = \&catch_zap;

	my $nodecount = 0;
	my $maxprocs  = 1;    # this one

	my $meth;
	if ( $type eq "update" )
	{
		$meth = \&doUpdate;
	}
	elsif ( $type eq "collect" )
	{
		$meth = \&doCollect;
	}
	elsif ( $type eq "services" )
	{
		$meth = \&doServices;
	}
	else
	{
		die "Unknown operation type=$type, terminating!\n";
	}
	logMsg("INFO start of $type process");

	# update the operation start/stop timestamp
	func::update_operations_stamp( type => $type, start => $starttime, stop => undef );
	my $maxruntime = defined( $C->{max_child_runtime} ) && $C->{max_child_runtime} > 0 ? $C->{max_child_runtime} : 0;

	# don't run longer than X seconds for the main process, only if in non-thread mode or specific node
	alarm($maxruntime) if ( $maxruntime && ( !$mthread or $node_select ) );

	my @list_of_handled_nodes;    # for any after_x_plugin() functions
	if ( $node_select eq "" )
	{
		# operate on all nodes, sort the nodes so we get consistent polling cycles
		# sort could be more sophisticated if we like, eg sort by core, dist, access or group
		foreach my $onenode ( sort keys %{$NT} )
		{
			# This will allow debugging to be turned on for a
			# specific node where there is a problem
			if ( $onenode eq "$debug_watch" )
			{
				$debug = "true";
			}
			else { $debug = $debug_global; }

			# KS 16 Mar 02, implementing David Gay's requirement for deactiving
			# a node, ie keep a node in nodes.csv but no collection done.
			# also if $runGroup set, only do the nodes for that group.
			if ( $runGroup eq "" or $NT->{$onenode}{group} eq $runGroup )
			{
				if ( getbool( $NT->{$onenode}{active} ) )
				{
					++$nodecount;
					push @list_of_handled_nodes, $onenode;

					# One process for each node until maxThreads is reached.
					# This loop is entered only if the commandlinevariable mthread=true is used!
					if ($mthread)
					{
						my $pid = fork;
						if ( defined($pid) and $pid == 0 )
						{

							# this will be run only by the child
							if ($mthreadDebug)
							{
								print "CHILD $$-> I am a CHILD with the PID $$ processing $onenode\n";
							}

							# don't run longer than X seconds
							alarm($maxruntime) if ($maxruntime);
							&$meth( name => $onenode );
							alarm(0) if ($maxruntime);

							# all the work in this thread is done now this child will die.
							if ($mthreadDebug)
							{
								print "CHILD $$-> $onenode will now exit\n";
							}

							# killing child
							exit 0;
						}    # end of child
						else
						{
							# parent
							my $others = func::find_nmis_processes( config => $C );
							my $procs_now = 1 + scalar keys %$others;    # the current process isn't returned
							$maxprocs = $procs_now if $procs_now > $maxprocs;
						}
					}
					else
					{
						# iterate over nodes in this process, if mthread is false
						&$meth( name => $onenode );
					}
				}    #if active
				else
				{
					dbg("Skipping as $onenode is marked 'inactive'");
				}
			}    #if runGroup
		}    # foreach $onenode

		# only do the child process cleanup if we have mthread enabled
		if ($mthread)
		{
			# cleanup
			# wait this will block until children are done
			1 while wait != -1;
		}
	}
	else
	{
		# specific node is given to work on, threading not relevant
		if ( ( my $node = checkNodeName($node_select) ) )
		{    # ignore lc & uc
			if ( getbool( $NT->{$node}{active} ) )
			{
				++$nodecount;
				push @list_of_handled_nodes, $node;
				&$meth( name => $node );
			}
			else
			{
				dbg("Skipping as $node_select is marked 'inactive'");
			}
		}
		else
		{
			print "\t Invalid node $node_select No node of that name!\n";
			return;
		}
	}
	alarm(0) if ( $maxruntime && ( !$mthread or $node_select ) );

	dbg("### continue normally ###");
	my $collecttime = Time::HiRes::time();

	my $S;

	# on update prime the interface summary
	if ( $type eq "update" )
	{
		### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
		getNodeAllInfo();    # store node info in <nmis_var>/nmis-nodeinfo.xxxx
		if ( !getbool( $C->{disable_interfaces_summary} ) )
		{
			getIntfAllInfo();    # concatencate all the interface info in <nmis_var>/nmis-interfaces.xxxx
			runLinks();
		}
	}

	# some collect post-processing, but only if running on all nodes
	elsif ( $type eq "collect" and $node_select eq "" )
	{
		$S = Sys->new;           # object nmis-system
		$S->init();

		my $NI = $S->ndinfo;
		delete $NI->{database};    # remove pre-8.5.0 key as it's not used anymore

		### 2011-12-29 keiths, adding a general purpose master control thing, run reliably every poll cycle.
		if ( getbool( $C->{'nmis_master_poll_cycle'} ) or !getbool( $C->{'nmis_master_poll_cycle'}, "invert" ) )
		{
			my $pollTimer = NMIS::Timing->new;

			dbg("Starting nmisMaster");
			nmisMaster() if getbool( $C->{server_master} );    # do some masterly type things.

			logMsg( "Poll Time: nmisMaster, " . $pollTimer->elapTime() )
				if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) );
		}
		else
		{
			dbg("Skipping nmisMaster with configuration 'nmis_master_poll_cycle' = $C->{'nmis_master_poll_cycle'}");
		}

		if ( getbool( $C->{'nmis_summary_poll_cycle'} ) or !getbool( $C->{'nmis_summary_poll_cycle'}, "invert" ) )
		{
			dbg("Starting nmisSummary");

			# NOTE!!! catchall needs to be written before this runs as it' loads the data
			# locally, it has no $S
			nmisSummary() if getbool( $C->{cache_summary_tables} );    # calculate and cache the summary stats
		}
		else
		{
			dbg("Skipping nmisSummary with configuration 'nmis_summary_poll_cycle' = $C->{'nmis_summary_poll_cycle'}");
		}

		dbg("Starting runMetrics");
		runMetrics( sys => $S );

		# thresholds can be run: independent (=t_p_n and t_p_c false), post-collect (=t_p_n false, t_p_c true),
		# or combined with collect (t_p_n true, t_p_c ignored)
		if ( !getbool( $C->{threshold_poll_node} ) )
		{
			# not false
			if ( !getbool( $C->{threshold_poll_cycle}, "invert" ) )
			{
				dbg("Starting runThreshold (for all selected nodes)");
				# the 0 here tells it that it's running in a collect cycle
				runThreshold($node_select,0);
			}
			else
			{
				dbg("Skipping runThreshold with configuration 'threshold_poll_cycle' = $C->{'threshold_poll_cycle'}");
			}
		}

		dbg("Starting runEscalate");
		runEscalate();

		# nmis collect runtime, process counts and save
		my $D;
		$D->{collect}{value}  = $collecttime - $starttime;
		$D->{collect}{option} = 'gauge,0:U';
		$D->{total}{value}    = Time::HiRes::time() - $starttime;
		$D->{total}{option}   = 'gauge,0:U';

		my $nr_processes = 1
			+ scalar %{&func::find_nmis_processes( config => $C )};  # current one isn't returned by find_nmis_processes
		$D->{nr_procs} = {
			option => "gauge,0:U",
			value  => $nr_processes
		};
		$D->{max_procs} = {
			option => "gauge,0:U",
			value  => $maxprocs
		};

		if ( ( my $db = $S->create_update_rrd( data => $D, type => "nmis" ) ) )
		{
			$NI->{graphtype}{nmis} = 'nmis';
			$NI->{graphtype}->{network}->{metrics} = 'metrics';
		}
		else
		{
			logMsg( "ERROR updateRRD failed: " . getRRDerror() );
		}
		$S->writeNodeInfo;    # var/nmis-system.xxxx, the base info system
	}

	if ( $type eq "collect" or $type eq "update" )
	{
		my $pollTimer = NMIS::Timing->new;

		# now run all after_{collect,update}_plugin() functions, regardless of whether
		# this was a one-node or all-nodes run
		for my $plugin (@active_plugins)
		{
			my $funcname = $plugin->can("after_${type}_plugin");
			next if ( !$funcname );

			# prime the global sys object, if this was an update run or a one-node collect
			if ( !$S )
			{
				$S = Sys->new;    # the nmis-system object
				$S->init();
			}

			dbg("Running after_$type plugin $plugin");
			logMsg("Running after_$type plugin $plugin");
			my ( $status, @errors );
			eval { ( $status, @errors ) = &$funcname( sys => $S, config => $C, nodes => \@list_of_handled_nodes ); };
			if ( $status >= 2 or $status < 0 or $@ )
			{
				logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
				for my $err (@errors)
				{
					logMsg("Error: Plugin $plugin: $err");
				}
			}
			elsif ( $status == 1 )    # changes were made, need to re-save info file
			{
				dbg("Plugin $plugin indicated success, updating nmis-system file");
				$S->writeNodeInfo;
			}
			elsif ( $status == 0 )
			{
				dbg("Plugin $plugin indicated no changes");
			}
		}
		logMsg( "Poll Time: After $type Plugins " . $pollTimer->elapTime() )
			if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) );
	}

	logMsg("INFO end of $type process");

	if ( $C->{info} or $debug or $mthreadDebug )
	{
		my $endTime = sprintf( "%.2f", Time::HiRes::time() - $starttime );
		my $stats = getUpdateStats();
		print "\n"
			. returnTime
			. " Number of Data Points: $stats->{datapoints}, Sum of Bytes: $stats->{databytes}, RRDs updated: $stats->{rrdcount}, Nodes with Updates: $stats->{nodecount}\n";
		print "\n" . returnTime . " End of $0 Processed $nodecount nodes ran for $endTime seconds.\n\n";
	}

	func::update_operations_stamp( type => $type, start => $starttime, stop => Time::HiRes::time() );

	dbg("Finished");
	return;
}

# generic signal handler, but with awareness of code in critical sections
# also handles SIGALARM, which we cop if the process has run out of time
sub catch_zap
{
	my $rs = $_[0];

	# if we've run out of our allocated run time, raise an event to inform the operator
	# unless told NOT to... fixme: we can't check the events control table here as that might block.
	if ($rs eq "ALRM"
		and (  !defined $C->{disable_nmis_process_events}
			or !getbool( $C->{disable_nmis_process_events} ) )
		)
	{
		logEvent(
			node    => $C->{server_name},
			event   => "NMIS runtime exceeded",
			level   => "Warning",
			element => undef,
			details => "Process $$, $0, has exceeded its max run time and is terminating"
		);
	}

	# do a graceful shutdown if in critical, and if this is the FIRST interrupt
	my $pending_ints = func::interrupt_pending;    # scalar ref
	if ( func::in_critical_section && !$$pending_ints )
	{
		# do NOT lock the logfile
		logMsg( "INFO process in critical section, marking as signal $rs pending", 1 );
		++$$pending_ints;
	}
	else
	{
		# do NOT lock the logfile
		logMsg( "INFO Process $$ ($0) was killed by signal $rs", 1 );
		die "Process $$ ($0) was killed by signal $rs\n";
	}
}

#====================================================================================

# perform update operation for ONE node
# args: name, required
# returns: nothing
#
# note: update must not (and does not) skip nodes with collect=false; function is not run if active=false.
sub doUpdate
{
	my %args = @_;
	my $name = $args{name};

	my $C = loadConfTable();

	my $updatetimer = NMIS::Timing->new;

	dbg("================================");
	dbg("Starting update, node $name");

	# Check for existing update LOCK
	if ( existsPollLock( type => "update", conf => $C->{conf}, node => $name ) )
	{
		print STDERR "Error: update lock exists for $name which has not finished!\n";
		logMsg("WARNING update lock exists for $name which has not finished!");
		return;
	}

	# create the update lock now.
	my $lockHandle = createPollLock( type => "update", conf => $C->{conf}, node => $name );

	# lets change our name, so a ps will report who we are - iff not debugging.
	$0 = "nmis-" . $C->{conf} . "-update-$name" if ( !$C->{debug} );

	my $S = Sys->new;    # create system object
	                     # loads old node info (unless force is active), and the DEFAULT(!) model (always!),
	                     # and primes the sys object for snmp/wmi ops


	if ( !$S->init( name => $name, update => 'true', force => $nvp{force} ) )
	{
		logMsg( "ERROR ($name) init failed: " . $S->status->{error} );    # fixme: why isn't this terminal?
	}

	# this is the first time catchall is accessed, handle error here, all others will assume it works
	my $catchall_inventory = $S->inventory(concept => 'catchall');
	$S->nmisng->log->fatal("Failed to load catchall inventory for node:$node") && return if(!$catchall_inventory);
	# catchall uses 'live' data which is a direct reference to the data because it's too easy to
	# end up with stale/wrong data with all the functions using it
	my $catchall_data = $catchall_inventory->data_live();

	dbg("node=$name "
			. join( " ",
			( map { "$_=" . $catchall_data->{$_} } (qw(group nodeType nodedown snmpdown wmidown)) ),
			( map { "$_=" . $S->status->{$_} } (qw(snmp_enabled wmi_enabled)) ) )
	);

	# this uses the node config loaded by init, and updates the node info table
	# (model and nodetype set only if missing)
	$S->copyModelCfgInfo( type => 'all' );

	my $NC = $S->ndcfg;

	if ( !getbool( $nvp{force} ) )
	{
		$S->readNodeView;    # from prev. run, but only if force isn't active
	}

	# prime default values, overridden if we can find anything better
	$catchall_data->{nodeModel} ||= 'Generic';
	$catchall_data->{nodeType}  ||= 'generic';

	# if reachable then we can update the model and get rid of the default we got from init above
	# fixme: not true unless node is ALSO marked as collect, or getnodeinfo will not do anything model-related
	if ( runPing( sys => $S ) )
	{
		# snmp-enabled node? then try to create a session obj
		# (but as snmp is still predominantly udp it won't connect yet!)
		$S->open(
			timeout      => $C->{snmp_timeout},
			retries      => $C->{snmp_retries},
			max_msg_size => $C->{snmp_max_msg_size},

			# how many oids/pdus per bulk request, or let net::snmp guess a value
			max_repetitions => $catchall_inventory->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

			# how many oids per simple get request (for getarray), or default (no guessing)
			oidpkt => $catchall_inventory->{max_repetitions} || $C->{snmp_max_repetitions} || 10
		) if ( $S->status->{snmp_enabled} );

		# failed already?
		if ( $S->status->{snmp_error} )
		{
			logMsg( "ERROR SNMP session open to $node failed: " . $S->status->{snmp_error} );
			$S->disable_source("snmp");
		}

		# this will try all enabled sources, 0 only if none worked
		# it also disables sys sources that don't work!
		if ( getNodeInfo( sys => $S ) )
		{
			# getnodeinfo has deleted the interface info, need to rebuild from scratch
			if ( getbool( $NC->{node}{collect} ) )
			{
				if ( getIntfInfo( sys => $S ) )
				{
					dbg("node=$S->{name} role=$catchall_data->{roleType} type=$catchall_data->{nodeType}");
					dbg("vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}"
					);

					if ($model)
					{
						print
							"MODEL $S->{name}: role=$catchall_data->{roleType} type=$catchall_data->{nodeType} sysObjectID=$catchall_data->{sysObjectID} sysObjectName=$catchall_data->{sysObjectName}\n";
						print "MODEL $S->{name}: sysDescr=$catchall_data->{sysDescr}\n";
						print
							"MODEL $S->{name}: vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}\n";
					}
				}

				# fixme: why no error handling for getintfinfo?

				getSystemHealthInfo( sys => $S ) if defined $S->{mdl}{systemHealth};
				getEnvInfo( sys => $S );
				getCBQoS( sys => $S );
				getCalls( sys => $S );

			}
			else
			{
				dbg("node is set to collect=false, not collecting any info");
			}
		}
		$S->close;    # close snmp session if one is open
		$catchall_inventory->{lastUpdatePoll} = time();
	}

	my $reachdata
		= runReach( sys => $S, delayupdate => 1 );    # don't let it make the rrd update, we want to add updatetime!
	$S->writeNodeView;                                # save node view info in file var/$NI->{name}-view.xxxx
	$S->writeNodeInfo;                                # save node info in file var/$NI->{name}-node.xxxx

	# done with the standard work, now run any plugins that offer update_plugin()
	for my $plugin (@active_plugins)
	{
		my $funcname = $plugin->can("update_plugin");
		next if ( !$funcname );

		dbg("Running update plugin $plugin with node $name");
		my ( $status, @errors );
		eval { ( $status, @errors ) = &$funcname( node => $name, sys => $S, config => $C ); };
		if ( $status >= 2 or $status < 0 or $@ )
		{
			logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				logMsg("Error: Plugin $plugin: $err");
			}
		}
		elsif ( $status == 1 )    # changes were made, need to re-save the view and info files
		{
			dbg("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
			$S->writeNodeInfo;
		}
		elsif ( $status == 0 )
		{
			dbg("Plugin $plugin indicated no changes");
		}
	}

	# fixme: deprecated, to be removed once all model-level custom plugins are converted to new plugin infrastructure
	# and when the remaining customers using this have upgraded
	runCustomPlugins( node => $name, sys => $S ) if ( defined $S->{mdl}{custom} );

	my $updatetime = $updatetimer->elapTime();
	info("updatetime for $name was $updatetime");
	$reachdata->{updatetime} = {value => $updatetime, option => "gauge,0:U," . ( 86400 * 3 )};

	# parrot the previous reading's poll time
	my $prevval = "U";
	if ( my $rrdfilename = $S->makeRRDname( graphtype => "health" ) )
	{
		my $infohash = RRDs::info($rrdfilename);
		$prevval = $infohash->{'ds[polltime].last_ds'} if ( defined $infohash->{'ds[polltime].last_ds'} );
	}
	$reachdata->{polltime} = {value => $prevval, option => "gauge,0:U,"};

	if ( !$S->create_update_rrd( data => $reachdata, type => "health" ) )
	{
		logMsg( "ERROR updateRRD failed: " . getRRDerror() );
	}
	$S->close;

	releasePollLock( handle => $lockHandle, type => "update", conf => $C->{conf}, node => $name );

	if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) )
	{

		logMsg("Poll Time: $name, $catchall_inventory->{nodeModel}, $updatetime");
	}

	$catchall_inventory->save();

	info("Finished");
	return;
}

#=========================================================================================

# a function to load the available code plugins,
# returns the list of package names that have working plugins
sub load_plugins
{
	my @activeplugins;

	# check for plugins enabled and the dir
	return () if ( !getbool( $C->{plugins_enabled} )
		or !$C->{plugin_root}
		or !-d $C->{plugin_root} );

	if ( !opendir( PD, $C->{plugin_root} ) )
	{
		logMsg("Error: cannot open plugin dir $C->{plugin_root}: $!");
		return ();
	}
	my @candidates = grep( /\.pm$/, readdir(PD) );
	closedir(PD);

	for my $candidate (@candidates)
	{
		my $packagename = $candidate;
		$packagename =~ s/\.pm$//;

		# read it and check that it has precisely one matching package line
		dbg("Checking candidate plugin $candidate");
		if ( !open( F, $C->{plugin_root} . "/$candidate" ) )
		{
			logMsg("Error: cannot open plugin file $candidate: $!");
			next;
		}
		my @plugindata = <F>;
		close F;
		my @packagelines = grep( /^\s*package\s+[a-zA-Z0-9_:-]+\s*;\s*$/, @plugindata );
		if ( @packagelines > 1 or $packagelines[0] !~ /^\s*package\s+$packagename\s*;\s*$/ )
		{
			logMsg("Plugin $candidate doesn't have correct \"package\" declaration. Ignoring.");
			next;
		}

		# do the actual load and eval
		eval { require $C->{plugin_root} . "/$candidate"; };
		if ($@)
		{
			logMsg("Ignoring plugin $candidate as it isn't valid perl: $@");
			next;
		}

		# we're interested if one or more of the supported plugin functions are provided
		push @activeplugins, $packagename
			if ( $packagename->can("update_plugin")
			or $packagename->can("collect_plugin")
			or $packagename->can("after_collect_plugin")
			or $packagename->can("after_update_plugin") );
	}

	return sort @activeplugins;
}

# this function runs ONLY NON-SNMP services!
# args: only name (node name)
# returns: nothing
sub doServices
{
	my (%args) = @_;
	my $name = $args{name};

	info("================================");
	info("Starting services, node $name");

	# lets change our name, so a ps will report who we are, iff not debugging
	$0 = "nmis-" . $C->{conf} . "-services-$name" if ( !$C->{debug} );

	my $S = Sys->new;
	$S->init( name => $name );
	dbg( "node=$name "
			. join( " ", map { "$_=" . $S->ndinfo->{system}->{$_} } (qw(group nodeType nodedown snmpdown wmidown)) ) );

	$S->readNodeView;    # init does not load the node view, but runservices updates view data!

	runServices( sys => $S, snmp => 'false' );

	# we also have to update the node info file, or newly added service status info will be lost/missed...
	# same argument for node view
	$S->writeNodeInfo;
	$S->writeNodeView;

	return;
}

sub doCollect
{
	my %args = @_;
	my $name = $args{name};

	my $pollTimer = NMIS::Timing->new;

	info("================================");
	info("Starting collect, node $name");

	# Check for both update and collect LOCKs
	if ( existsPollLock( type => "update", conf => $C->{conf}, node => $name ) )
	{
		print STDERR "Error: running collect but update lock exists for $name which has not finished!\n";
		logMsg("WARNING running collect but update lock exists for $name which has not finished!");
		return;
	}
	if ( existsPollLock( type => "collect", conf => $C->{conf}, node => $name ) )
	{
		print STDERR "Error: collect lock exists for $name which has not finished!\n";
		logMsg("WARNING collect lock exists for $name which has not finished!");
		return;
	}

	# create the poll lock now.
	my $lockHandle = createPollLock( type => "collect", conf => $C->{conf}, node => $name );

	# lets change our name, so a ps will report who we are - iff not debugging
	$0 = "nmis-" . $C->{conf} . "-collect-$name" if ( !$C->{debug} );

	my $S = Sys->new;    # create system object
	if ( !$S->init( name => $name ) )    # init will usually load node info data, model etc, returns 1 if _all_ is ok
	{
		dbg( "Sys init for $name failed: "
				. join( ", ", map { "$_=" . $S->status->{$_} } (qw(error snmp_error wmi_error)) ) );

		info("no info available of node $name, switching to update operation instead");
		doUpdate( name => $name );
		info("Finished update instead of collect");
		return;                          # collect has to wait until a next run
	}

	my $configuration = $S->nmisng_node->configuration();
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	dbg( "node=$name "
			. join( " ", map { "$_=" . $catchall_data->{$_} } (qw(group nodeType nodedown snmpdown wmidown)) ) );

	# update node info data, merge in the node's configuration (which was loaded by sys' init)
	
	$S->copyModelCfgInfo( type => 'all' );
	
	$S->readNodeView;    # s->init does NOT load that, but we need it as we're overwriting some view info

	# run an update if no update poll time is known
	if ( !exists( $catchall_data->{lastUpdatePoll} ) or !$catchall_data->{lastUpdatePoll} )
	{
		info("no cached node data available, running an update now");
		doUpdate( name => $name );
		info("update done, continue with collect");
	}

	info("node=$catchall_data->{name} role=$catchall_data->{roleType} type=$catchall_data->{nodeType}");
	info("vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}");

	# are we meant to and able to talk to the node?
	if ( runPing( sys => $S ) && getbool( $configuration->{collect} ) )
	{
	# snmp-enabled node? then try to create a session obj (but as snmp is still predominantly udp it won't connect yet!)
		$S->open(
			timeout      => $C->{snmp_timeout},
			retries      => $C->{snmp_retries},
			max_msg_size => $C->{snmp_max_msg_size},

			# how many oids/pdus per bulk request, or let net::snmp guess a value
			max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

			# how many oids per simple get request for getarray, or default (no guessing)
			oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10
		) if ( $S->status->{snmp_enabled} );

		# failed already?
		if ( $S->status->{snmp_error} )
		{
			logMsg( "ERROR SNMP session open to $node failed: " . $S->status->{snmp_error} );
			$S->disable_source("snmp");
		}

		# returns 1 if one or more sources have worked, also updates snmp/wmi down states in nodeinfo
		my $updatewasok = updateNodeInfo( sys => $S );
		my $curstate = $S->status;    # updatenodeinfo does NOT disable faulty sources!

	# was snmp ok? should we bail out? note that this is interpreted to apply to ALL sources being down simultaneously,
	# NOT just snmp. otherwise a wmi-only node would never be polled.
	# fixme: likely needs companion wmi_stop_polling_on_error, and both criteria would need to be satisfied for stopping
		if (    getbool( $C->{snmp_stop_polling_on_error} )
			and getbool( $catchall_data->{snmpdown} )
			and getbool( $catchall_data->{wmidown} ) )
		{
			logMsg(
				"Polling stopped for $catchall_data->{name} because SNMP and WMI had errors, snmpdown=$catchall_data->{snmpdown} wmidown=$catchall_data->{wmidown}"
			);
		}
		elsif ($updatewasok)    # at least some info was retrieved by wmi or snmp
		{
			if ( $model or $C->{info} )
			{
				print
					"MODEL $S->{name}: role=$catchall_data->{roleType} type=$catchall_data->{nodeType} sysObjectID=$catchall_data->{sysObjectID} sysObjectName=$catchall_data->{sysObjectName}\n";
				print "MODEL $S->{name}: sysDescr=$catchall_data->{sysDescr}\n";
				print
					"MODEL $S->{name}: vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}\n";
			}

			# at this point we need to tell sys that dead sources are to be ignored
			for my $source (qw(snmp wmi))
			{
				if ( $curstate->{"${source}_error"} )
				{
					$S->disable_source($source);
				}
			}

			# fixme: why no error handling for any of these?

			# get node data and store in rrd
			getNodeData( sys => $S );

			# get intf data and store in rrd
			my $ids = $S->nmisng_node->get_inventory_ids( concept => 'interface' );
			getIntfData( sys => $S ) if( @$ids > 0);
			getSystemHealthData( sys => $S );
			getEnvData( sys => $S );
			getCBQoS( sys => $S );
			getCalls( sys => $S );
			getPVC( sys => $S );

			runServer( sys => $S );

			# Custom Alerts
			runAlerts( sys => $S ) if defined $S->{mdl}{alerts};

			# remember when the collect poll last completed successfully
			$catchall_data->{lastCollectPoll} = time();
		}
		else
		{
			my $msg = "updateNodeInfo for $name failed: "
				. join( ", ", map { "$_=" . $S->status->{$_} } (qw(error snmp_error wmi_error)) );
			logMsg("ERROR $msg");
			info("Error: $msg");
		}
	}

	# Need to poll services under all circumstances, i.e. if no ping, or node down or set to no collect
	# but try snmp services only if snmp is actually ok
	runServices( sys => $S, snmp => getbool( $catchall_data->{snmpdown} ) ? 'false' : 'true' );

	runCheckValues( sys => $S );

	# don't let runreach perform the rrd update, we want to add the polltime to it!
	my $reachdata = runReach( sys => $S, delayupdate => 1 );

	# compute thresholds with the node, if configured to do so
	if ( getbool( $C->{threshold_poll_node} ) )
	{
		doThreshold( name => $S->{name}, sys => $S, table => {} );
	}

	$S->writeNodeView;
	$S->writeNodeInfo;

	# done with the standard work, now run any plugins that offer collect_plugin()
	for my $plugin (@active_plugins)
	{
		my $funcname = $plugin->can("collect_plugin");
		next if ( !$funcname );

		dbg("Running collect plugin $plugin with node $name");
		my ( $status, @errors );
		eval { ( $status, @errors ) = &$funcname( node => $name, sys => $S, config => $C ); };
		if ( $status >= 2 or $status < 0 or $@ )
		{
			logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				logMsg("Error: Plugin $plugin: $err");
			}
		}
		elsif ( $status == 1 )    # changes were made, need to re-save the view and info files
		{
			dbg("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
			$S->writeNodeInfo;
		}
		elsif ( $status == 0 )
		{
			dbg("Plugin $plugin indicated no changes");
		}
	}
	my $polltime = $pollTimer->elapTime();
	info("polltime for $name was $polltime");
	$reachdata->{polltime} = {value => $polltime, option => "gauge,0:U"};

	# parrot the previous reading's update time
	my $prevval = "U";
	if ( my $rrdfilename = $S->makeRRDname( graphtype => "health" ) )
	{
		my $infohash = RRDs::info($rrdfilename);
		$prevval = $infohash->{'ds[updatetime].last_ds'} if ( defined $infohash->{'ds[updatetime].last_ds'} );
	}
	$reachdata->{updatetime} = {value => $prevval, option => "gauge,0:U," . ( 86400 * 3 )};

	if ( !$S->create_update_rrd( data => $reachdata, type => "health" ) )
	{
		logMsg( "ERROR updateRRD failed: " . getRRDerror() );
	}
	$S->close;

	releasePollLock( handle => $lockHandle, type => "collect", conf => $C->{conf}, node => $name );

	if ( getbool( $C->{log_polling_time} ) )
	{
		logMsg("Poll Time: $name, $catchall_data->{nodeModel}, $polltime");
	}
	info("Finished");
	return;
}

# normaly a daemon fpingd.pl is running (if set in NMIS config) and stores the result in var/fping.xxxx
# if node info missing then ping.pm is used
# returns: 1 if pingable, 0 otherwise
sub runPing
{
	my %args = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;    # node info
	my $V    = $S->view;      # web view
	my $RI   = $S->reach;     # reach table
	my $NC   = $S->ndcfg;     # node config
	my $catchall_data = $S->inventory(concept => 'catchall')->data_live();

	my ( $ping_min, $ping_avg, $ping_max, $ping_loss, $pingresult );

	# setup log filter for getNodeInfo() - fixme why is that done here?
	$S->snmp->logFilterOut(qr/no response from/)
		if ( $S->snmp && getbool( $catchall_data->{snmpdown} ) );

	# preset view of node status
	$V->{system}{status_value} = 'unknown';
	$V->{system}{status_title} = 'Node Status';
	$V->{system}{status_color} = '#0F0';

	if ( getbool( $NC->{node}{ping} ) )
	{
		my $PT;

		# use fastping info if its meant to be available, and actually is
		if (   getbool( $C->{daemon_fping_active} )
			&& ( $PT = loadTable( dir => 'var', name => 'nmis-fping' ) )
			&& exists( $PT->{$NC->{node}{name}}{loss} ) )
		{
			# copy values
			$ping_avg   = $PT->{$NC->{node}{name}}{avg};
			$ping_loss  = $PT->{$NC->{node}{name}}{loss};
			$pingresult = ( $ping_loss < 100 ) ? 100 : 0;
			info("INFO ($S->{name}) PING min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
		}
		else
		{
			# fallback to OLD system
			logMsg("INFO ($S->{name}) using standard ping system, no ping info of daemon fpingd")
				if (getbool( $C->{daemon_fping_active} )
				and !getbool( $C->{daemon_fping_failed} )
				and !getbool( $S->{update} ) );    # fixme: unclean access to internal property

			my $retries = $C->{ping_retries} ? $C->{ping_retries} : 3;
			my $timeout = $C->{ping_timeout} ? $C->{ping_timeout} : 300;
			my $packet  = $C->{ping_packet}  ? $C->{ping_packet}  : 56;
			my $host = $NC->{node}{host};          # ip name/adress of node

			info("Starting $S->{name} ($host) with timeout=$timeout retries=$retries packet=$packet");

			# fixme: invalid condition, root is generally NOT required for ping anymore!
			if ($<)
			{
				# not root and update, assume called from www interface
				$pingresult = 100;
				dbg("SKIPPING Pinging as we are NOT running with root privileges");
			}
			else
			{
				( $ping_min, $ping_avg, $ping_max, $ping_loss ) = ext_ping( $host, $packet, $retries, $timeout );
				$pingresult = defined $ping_min ? 100 : 0;    # ping_min is undef if unreachable.
			}
		}

		# at this point ping_{min,avg,max,loss} and pingresult are all set

		# in the fpingd case all up/down events are handled by it
		if ( !getbool( $C->{daemon_fping_active} ) )
		{
			if ($pingresult)
			{
				# up
				# are the nodedown status and event db out of sync?
				if ( not getbool( $catchall_data->{nodedown} ) and eventExist( $catchall_data->{name}, "Node Down", "" ) )
				{
					my $result = checkEvent(
						sys     => $S,
						event   => "Node Down",
						level   => "Normal",
						element => "",
						details => "Ping failed"
					);
					info("Fixing Event DB error: $S->{name}, Event DB says Node Down but nodedown said not.");
				}
				else
				{
					# note: up event is handled regardless of snmpdown/pingonly/snmponly, which the
					# frontend nodeStatus() takes proper care of.
					info("$S->{name} is PINGABLE min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
					HandleNodeDown(
						sys     => $S,
						type    => "node",
						up      => 1,
						details => "Ping avg=$ping_avg loss=$ping_loss%"
					);
				}
			}
			else
			{
				# down - log if not already down
				logMsg("ERROR ($S->{name}) ping failed") if ( !getbool( $catchall_data->{nodedown} ) );
				HandleNodeDown( sys => $S, type => "node", details => "Ping failed" );
			}
		}

		$RI->{pingavg}    = $ping_avg;     # results for sub runReach
		$RI->{pingresult} = $pingresult;
		$RI->{pingloss}   = $ping_loss;

		# info for web page
		$V->{system}{lastUpdate_value} = returnDateStamp();
		$V->{system}{lastUpdate_title} = 'Last Update';
		$catchall_data->{lastUpdateSec}   = time();
	}
	else
	{
		info("$S->{name} ping not requested");
		$RI->{pingresult} = $pingresult = 100;    # results for sub runReach
		$RI->{pingavg}    = 0;
		$RI->{pingloss}   = 0;
	}

	if ($pingresult)
	{
		$V->{system}{status_value} = 'reachable' if ( getbool( $NC->{node}{ping} ) );
		$V->{system}{status_color} = '#0F0';
		$catchall_data->{nodedown}    = 'false';
	}
	else
	{
		$V->{system}{status_value} = 'unreachable';
		$V->{system}{status_color} = 'red';
		$catchall_data->{nodedown}    = 'true';

		# workaround for opCharts not using right data
		$catchall_data->{nodestatus} = 'unreachable';
	}

	info(     "Finished with exit="
			. ( $pingresult ? 1 : 0 )
			. ", nodedown=$catchall_data->{nodedown} nodestatus=$catchall_data->{nodestatus}" );

	return ( $pingresult ? 1 : 0 );
}

# gets node info by snmp/wmi, determines node's model if it can
# this is only run during update type ops (or if we switch to that type on the go)
#
# args: sys
# returns: 1 if _something_ worked, 0 if all a/v collection mechanisms failed
#
# attention: this deletes the interface info if other steps successful
# attention: this function disables all sys' sources that indicate any errors on loadnodeinfo()!
#
# fixme: this thing is an utter mess logic-wise and urgently needs a rewrite
sub getNodeInfo
{
	my (%args) = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;         # node info table
	my $RI   = $S->reach;          # reach table
	my $V    = $S->view;           # web view
	my $M    = $S->mdl;            # model table
	my $NC   = $S->ndcfg;          # node config
	my $SNMP = $S->snmp;           # snmp object
	my $C    = loadConfTable();    # system config

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $exit = 0;                  # assume failure by default
	$RI->{snmpresult} = $RI->{wmiresult} = 0;

	info("Starting");

	# fixme: unclean access to internal property,
	# fixme also fails if we've switched to updating this node on the go!
	if ( getbool( $S->{update} )
		and !getbool( $NC->{node}{collect} ) )    # rebuild
	{
		delete $V->{interface};
		delete $NI->{graphtype};
	}

	my $oldstate = $S->status;                    # what did we start with for snmp_enabled, wmi_enabled?
	my $curstate;

	# if collect is off, only nodeconf overrides are loaded
	if ( getbool( $NC->{node}{collect} ) )
	{
		# get basic node info by snmp or wmi: sysDescr, sysObjectID, sysUpTime etc. and store in $NI table

		# this is normally with the DEFAULT model from Model.nmis
		# fixme: not true if switched to update op on the go!
		my $firstloadok = $S->loadNodeInfo();

		# source that hasn't worked? disable immediately
		$curstate = $S->status;
		for my $source (qw(snmp wmi))
		{
			if ( $curstate->{"${source}_error"} )
			{
				$S->disable_source($source);

				# copy over the error so that we can figure out that this source is indeed down,
				# not just disabled from the get-go
				$oldstate->{"${source}_error"} = $curstate->{"${source}_error"};
			}
		}

		if ($firstloadok)
		{

			# snmp: continue processing if at least a couple of entries are valid.
			if ( $catchall_data->{sysDescr} and $catchall_data->{sysObjectID} )
			{
				my $enterpriseTable = loadEnterpriseTable();    # table is already cached

				# if the vendors product oid file is loaded, this will give product name.
				$catchall_data->{sysObjectName} = oid2name( $catchall_data->{sysObjectID} );

				info("sysObjectId=$catchall_data->{sysObjectID}, sysObjectName=$catchall_data->{sysObjectName}");
				info("sysDescr=$catchall_data->{sysDescr}");

				# Decide on vendor name.
				my @x = split( /\./, $catchall_data->{sysObjectID} );
				my $i = $x[6];

				# Special handling for devices with bad sysObjectID, e.g. Trango
				if ( not $i )
				{
					$i = $catchall_data->{sysObjectID};
				}

				if ( $enterpriseTable->{$i}{Enterprise} ne "" )
				{
					$catchall_data->{nodeVendor} = $enterpriseTable->{$i}{Enterprise};
				}
				else
				{
					$catchall_data->{nodeVendor} = "Universal";
				}
				dbg("oid index $i, Vendor is $catchall_data->{nodeVendor}");
			}

			# iff snmp is a dud, look at some wmi properties
			elsif ( $catchall_data->{winbuild} && $catchall_data->{winosname} && $catchall_data->{winversion} )
			{
				info("winosname=$catchall_data->{winosname} winversion=$catchall_data->{winversion}");

				# synthesize something compatible with what win boxes spit out via snmp:
				# i'm too lazy to also wmi-poll Manufacturer and strip off the 'corporation'
				$catchall_data->{nodeVendor} = "Microsoft";

				# the winosname is not the same/enough
				$catchall_data->{sysDescr}
					= $catchall_data->{winosname} . " Windows Version " . $catchall_data->{winversion};
				$catchall_data->{sysName} = $catchall_data->{winsysname};
			}

			# but if neither worked, do not continue processing anything model-related!
			if ( $catchall_data->{sysDescr} or !$catchall_data->{nodeVendor} )
			{
				# fixme: the auto-model decision should be made FIRST, before doing any loadinfo(),
				# this function's logic needs a complete rewrite
				if ( $NC->{node}{model} eq 'automatic' || $NC->{node}{model} eq "" )
				{
					# get nodeModel based on nodeVendor and sysDescr (real or synthetic)
					$catchall_data->{nodeModel} = $S->selectNodeModel();    # select and save name in node info table
					info("selectNodeModel returned model=$catchall_data->{nodeModel}");

					$catchall_data->{nodeModel} ||= 'Default';              # fixme why default and not generic?
				}
				else
				{
					$catchall_data->{nodeModel} = $NC->{node}{model};
					info("node model=$catchall_data->{nodeModel} set by node config");
				}

				dbg("about to loadModel model=$catchall_data->{nodeModel}");
				$S->loadModel( model => "Model-$catchall_data->{nodeModel}" );

				# now we know more about the host, nodetype and model have been positively determined,
				# so we'll force-overwrite those values
				$S->copyModelCfgInfo( type => 'overwrite' );

				# add web page info
				delete $V->{system} if getbool( $S->{update} );    # rebuild; fixme unclean access to internal property

				$V->{system}{status_value}  = 'reachable';
				$V->{system}{status_title}  = 'Node Status';
				$V->{system}{status_color}  = '#0F0';
				$V->{system}{sysName_value} = $catchall_data->{sysName};
				$V->{system}{sysName_title} = 'System Name';

				$V->{system}{sysObjectName_value}   = $catchall_data->{sysObjectName};
				$V->{system}{sysObjectName_title}   = 'Object Name';
				$V->{system}{nodeVendor_value}      = $catchall_data->{nodeVendor};
				$V->{system}{nodeVendor_title}      = 'Vendor';
				$V->{system}{group_value}           = $catchall_data->{group};
				$V->{system}{group_title}           = 'Group';
				$V->{system}{customer_value}        = $catchall_data->{customer};
				$V->{system}{customer_title}        = 'Customer';
				$V->{system}{location_value}        = $catchall_data->{location};
				$V->{system}{location_title}        = 'Location';
				$V->{system}{businessService_value} = $catchall_data->{businessService};
				$V->{system}{businessService_title} = 'Business Service';
				$V->{system}{serviceStatus_value}   = $catchall_data->{serviceStatus};
				$V->{system}{serviceStatus_title}   = 'Service Status';
				$V->{system}{notes_value}           = $catchall_data->{notes};
				$V->{system}{notes_title}           = 'Notes';

				# make sure any required data from network_viewNode_field_list gets added.
				my @viewNodeFields = split( ",", $C->{network_viewNode_field_list} );
				foreach my $field (@viewNodeFields)
				{
					if ( defined $catchall_data->{$field}
						and
						( not defined $V->{system}{"${field}_value"} or not defined $V->{system}{"${field}_title"} ) )
					{
						$V->{system}{"${field}_title"} = $field;
						$V->{system}{"${field}_value"} = $catchall_data->{$field};
					}
				}

				# update node info table a second time, but now with the actually desired model
				# fixme: see logic problem above, should not have to do both
				my $secondloadok = $S->loadNodeInfo();

				# source that hasn't worked? disable immediately
				$curstate = $S->status;
				for my $source (qw(snmp wmi))
				{
					$S->disable_source($source) if ( $curstate->{"${source}_error"} );
				}

				if ($secondloadok)
				{
					# sysuptime is only a/v if snmp, with wmi we have synthesize it as wintime-winboottime
					# it's also mangled on the go
					makesysuptime($S);
					$V->{system}{sysUpTime_value} = $catchall_data->{sysUpTime};

					$catchall_data->{server} = $C->{server_name};

					# pull / from VPN3002 system descr
					$catchall_data->{sysDescr} =~ s/\// /g;

					# collect DNS location info.
					getDNSloc( sys => $S );

					# PIX failover test
					checkPIX( sys => $S );

					$exit = 1;    # done
				}
				else
				{
					logMsg("ERROR loadNodeInfo with specific model failed!");
				}
			}
			else
			{
				info("ERROR could retrieve sysDescr or winosname, cannot determine model!");
			}
		}
		else                      # fixme unclear why this reaction to failed getnodeinfo?
		{
			# load the model prev found
			$S->loadModel( model => "Model-$catchall_data->{nodeModel}" ) if ( $catchall_data->{nodeModel} ne '' );
		}
	}
	else
	{
		dbg("node $S->{name} is marked collect is 'false'");
		$exit = 1;                # done
	}

	# get and apply any nodeconf override if such exists for this node
	my $nodename = $catchall_data->{name};
	my ( $errmsg, $override ) = get_nodeconf( node => $nodename )
		if ( has_nodeconf( node => $nodename ) );
	logMsg("ERROR $errmsg") if $errmsg;
	$override ||= {};

	if ( $override->{sysLocation} )
	{
		$catchall_data->{sysLocation} = $V->{system}{sysLocation_value} = $override->{sysLocation};
		info("Manual update of sysLocation by nodeConf");
	}

	if ( $override->{sysContact} )
	{
		$catchall_data->{sysContact} = $V->{system}{sysContact_value} = $override->{sysContact};
		dbg("Manual update of sysContact by nodeConf");
	}

	if ( $override->{nodeType} )
	{
		$catchall_data->{nodeType} = $override->{nodeType};
	}
	else
	{
		delete $catchall_data->{nodeType};
	}

	# process the overall results, set node states etc.
	for my $source (qw(snmp wmi))
	{
		# $curstate should be state as of last loadinfo() op

		# we can call a source ok iff we started with it enabled, still enabled,
		# and the (second) loadnodeinfo didn't turn up any trouble for this source
		if (   $oldstate->{"${source}_enabled"}
			&& $curstate->{"${source}_enabled"}
			&& !$curstate->{"${source}_error"} )
		{
			$RI->{"${source}result"} = 100;
			my $sourcename = uc($source);

			# happy, clear previous source down flag and event (if any)
			HandleNodeDown( sys => $S, type => $source, up => 1, details => "$sourcename ok" );
		}

		# or fire down event if it was enabled but didn't work
		# ie. if it's no longer enabled and has an error saved in oldstate or a new one
		elsif ($oldstate->{"${source}_enabled"}
			&& !$curstate->{"${source}_enabled"}
			&& ( $oldstate->{"${source}_error"} || $curstate->{"${source}_error"} ) )
		{
			HandleNodeDown(
				sys     => $S,
				type    => $source,
				details => $curstate->{"${source}_error"} || $oldstate->{"${source}_error"}
			);
		}
	}

	if ($exit)
	{
		# add web page info
		$V->{system}{timezone_value}  = $catchall_data->{timezone};
		$V->{system}{timezone_title}  = 'Time Zone';
		$V->{system}{nodeModel_value} = $catchall_data->{nodeModel};
		$V->{system}{nodeModel_title} = 'Model';
		$V->{system}{nodeType_value}  = $catchall_data->{nodeType};
		$V->{system}{nodeType_title}  = 'Type';
		$V->{system}{roleType_value}  = $catchall_data->{roleType};
		$V->{system}{roleType_title}  = 'Role';
		$V->{system}{netType_value}   = $catchall_data->{netType};
		$V->{system}{netType_title}   = 'Net';

		# get the current ip address if the host property was a name
		if ( ( my $addr = resolveDNStoAddr( $catchall_data->{host} ) ) )
		{
			$catchall_data->{host_addr}      = $addr;    # cache it
			$V->{system}{host_addr_value} = $addr;
			$V->{system}{host_addr_value} .= " ($catchall_data->{host})" if ( $addr ne $catchall_data->{host} );
			$V->{system}{host_addr_title} = 'IP Address';
		}
		else
		{
			$catchall_data->{host_addr}    = '';
			$V->{system}{host_addr_value} = "N/A";
			$V->{system}{host_addr_title} = 'IP Address';
		}
	}
	else
	{
		# node status info web page
		$V->{system}{status_title} = 'Node Status';
		if ( getbool( $NC->{node}{ping} ) )
		{
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		}
		else
		{
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	info( "Finished with exit=$exit "
			. join( " ", map { "$_=" . $catchall_data->{$_} } (qw(nodedown snmpdown wmidown)) ) );

	return $exit;
}

sub getDNSloc
{
	my %args = @_;
	my $S    = $args{sys};        # node object
	my $C    = loadConfTable();
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	dbg("Starting");

	# collect DNS location info. Update this info every update pass.
	$catchall_data->{loc_DNSloc} = "unknown";
	my $tmphostname = $catchall_data->{host};
	if ( getbool( $C->{loc_from_DNSloc} ) and $C->{netDNS} )
	{
		my ( $rr, $lat, $lon );
		my $res = Net::DNS::Resolver->new;
		if ( $tmphostname =~ /\d+\.\d+\.\d+\.\d+/ )
		{
			# find reverse lookup as this is an ip
			my $query = $res->query( "$tmphostname", "PTR" );
			if ($query)
			{
				foreach $rr ( $query->answer )
				{
					next unless $rr->type eq "PTR";
					$tmphostname = $rr->ptrdname;
					dbg("DNS Reverse query $tmphostname");
				}
			}
			else
			{
				dbg("ERROR, DNS Reverse query failed: $res->errorstring");
			}
		}

		#look up loc for hostname
		my $query = $res->query( "$tmphostname", "LOC" );
		if ($query)
		{
			foreach $rr ( $query->answer )
			{
				next unless $rr->type eq "LOC";
				( $lat, $lon ) = $rr->latlon;
				$catchall_data->{loc_DNSloc} = $lat . "," . $lon . "," . $rr->altitude;
				dbg("Location from DNS LOC query is $catchall_data->{loc_DNSloc}");
			}
		}
		else
		{
			dbg("ERROR, DNS Loc query failed: $res->errorstring");
		}
	}    # end DNSLoc
	     # if no DNS based location information found - look at sysLocation in router.....
	     # longitude,latitude,altitude,location-text
	if ( getbool( $C->{loc_from_sysLoc} ) and $catchall_data->{loc_DNSloc} eq "unknown" )
	{
		if ( $catchall_data->{sysLocation} =~ /$C->{loc_sysLoc_format}/ )
		{
			$catchall_data->{loc_DNSloc} = $catchall_data->{sysLocation};
			dbg("Location from device sysLocation is $catchall_data->{loc_DNSloc}");
		}
	}    # end sysLoc
	dbg("Finished");
	return 1;
}

# verifies a cisco ciscoEnvMonSupplyState-style power status,
# raises/clears event if required, updates view a little
sub checkPower
{
	my %args = @_;
	my $S    = $args{sys};
	my $V    = $S->view;
	my $M    = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	info("Starting");

	my $attr = $args{attr};

	info("Start with attribute=$attr");

	delete $V->{system}{"${attr}_value"};

	info("Power check attribute=$attr value=$catchall_data->{$attr}");
	if ( $catchall_data->{$attr} ne '' and $catchall_data->{$attr} !~ /noSuch/ )
	{
		$V->{system}{"${attr}_value"} = $catchall_data->{$attr};

		if ( $catchall_data->{$attr} =~ /normal|unknown|notPresent/ )
		{
			checkEvent(
				sys     => $S,
				event   => "RPS Fail",
				level   => "Normal",
				element => $attr,
				details => "RPS failed"
			);
			$V->{system}{"${attr}_color"} = '#0F0';
		}
		else
		{
			notify(
				sys     => $S,
				event   => "RPS Fail",
				element => $attr,
				details => "RPS failed",
				context => {type => "rps"}
			);
			$V->{system}{"${attr}_color"} = 'red';
		}
	}

	info("Finished");
	return;
}

# try to figure out if the config of a device has been saved or not,
# send node config change event if one detected, update the view a little
sub checkNodeConfiguration
{
	my %args = @_;
	my $S    = $args{sys};
	my $V    = $S->view;
	my $M    = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	info("Starting");

	my @updatePrevValues = qw ( configLastChanged configLastSaved bootConfigLastChanged );

	# create previous values if they don't exist
	for my $attr (@updatePrevValues)
	{
		if (   defined( $catchall_data->{$attr} )
			&& $catchall_data->{$attr} ne ''
			&& !defined( $catchall_data->{"${attr}_prev"} ) )
		{
			$catchall_data->{"${attr}_prev"} = $catchall_data->{$attr};
		}
	}

	my $configLastChanged = $catchall_data->{configLastChanged} if defined $catchall_data->{configLastChanged};
	my $configLastViewed  = $catchall_data->{configLastSaved}   if defined $catchall_data->{configLastSaved};
	my $bootConfigLastChanged = $catchall_data->{bootConfigLastChanged}
		if defined $catchall_data->{bootConfigLastChanged};
	my $configLastChanged_prev = $catchall_data->{configLastChanged_prev}
		if defined $catchall_data->{configLastChanged_prev};

	if ( defined $configLastViewed && defined $bootConfigLastChanged )
	{
		info(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastViewed=$configLastViewed, bootConfigLastChanged=$bootConfigLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}
	else
	{
		info(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}

	# check if config is saved:
	$V->{system}{configLastChanged_value} = convUpTime( $configLastChanged / 100 ) if defined $configLastChanged;
	$V->{system}{configLastSaved_value}   = convUpTime( $configLastViewed / 100 )  if defined $configLastViewed;
	$V->{system}{bootConfigLastChanged_value} = convUpTime( $bootConfigLastChanged / 100 )
		if defined $bootConfigLastChanged;

	### Cisco Node Configuration Change Only
	if ( defined $configLastChanged && defined $bootConfigLastChanged )
	{
		$V->{system}{configurationState_title} = 'Configuration State';

		### when the router reboots bootConfigLastChanged = 0 and configLastChanged
		# is about 2 seconds, which are the changes made by booting.
		if ( $configLastChanged > $bootConfigLastChanged and $configLastChanged > 5000 )
		{
			$V->{system}{"configurationState_value"} = "Config Not Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#FFDD00";                     #warning
			info("checkNodeConfiguration, config not saved, $configLastChanged > $bootConfigLastChanged");
		}
		elsif ( $bootConfigLastChanged == 0 and $configLastChanged <= 5000 )
		{
			$V->{system}{"configurationState_value"} = "Config Not Changed Since Boot";
			$V->{system}{"configurationState_color"} = "#00BB00";                         #normal
			info("checkNodeConfiguration, config not changed, $configLastChanged $bootConfigLastChanged");
		}
		else
		{
			$V->{system}{"configurationState_value"} = "Config Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#00BB00";                         #normal
		}
	}

	### If it is newer, someone changed it!
	if ( $configLastChanged > $configLastChanged_prev )
	{
		$catchall_data->{configChangeCount}++;
		$V->{system}{configChangeCount_value} = $catchall_data->{configChangeCount};
		$V->{system}{configChangeCount_title} = "Configuration change count";

		notify(
			sys     => $S,
			event   => "Node Configuration Change",
			element => "",
			details => "Changed at " . $V->{system}{configLastChanged_value},
			context => {type => "node"},
		);
		logMsg("checkNodeConfiguration configuration change detected on $S->{name}, creating event");
	}

	#update previous values to be out current values
	for my $attr (@updatePrevValues)
	{
		if ( defined $catchall_data->{$attr} ne '' && $catchall_data->{$attr} ne '' )
		{
			$catchall_data->{"${attr}_prev"} = $catchall_data->{$attr};
		}
	}

	info("Finished");
	return;

}

# Create the Interface configuration from SNMP Stuff
# except on collect it is always called with a blank interface info
#
# fixme: this function works ONLY if snmp is enabled for the node!
#
# returns: 1 if happy, 0 otherwise
sub getIntfInfo
{
	my %args     = @_;
	my $S        = $args{sys};      # object
	my $intf_one = $args{index};    # index for single interface update
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getIntfInfo for $S->{name}: SNMP not enabled for this node");
		return 0;                   # no interfaces collected, treat this as error
	}

	my $V    = $S->view;
	my $M    = $S->mdl;             # node model table
	my $SNMP = $S->snmp;
	my $NC   = $S->ndcfg;           # node config table
	my $graphtypes = $S->ndinfo->{graphtype};

	my $singleInterface = 0;
	if ( defined $intf_one and $intf_one ne "" )
	{
		$singleInterface = 1;
	}

	my $C        = loadConfTable();
	my $nodename = $catchall_data->{name};

	# create the node here for now, this should be passed in as a param in the future
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;

	my $interface_max_number = $C->{interface_max_number} ? $C->{interface_max_number} : 5000;
	my $nocollect_interface_down_days
		= $C->{global_nocollect_interface_down_days} ? $C->{global_nocollect_interface_down_days} : 30;

	my $target_table = {};

	# fixme: hardcoded section name 'standard'
	if ( defined $S->{mdl}{interface}{sys}{standard}
		and $catchall_data->{ifNumber} <= $interface_max_number )
	{
		# Check if the ifTableLastChange has changed.  If it has not changed, the
		# interface table has had no interfaces added or removed, no need to go any further.
		if (    not $singleInterface
			and getbool( $S->{mdl}{custom}{interface}{ifTableLastChange} )
			and my $result = $SNMP->get("ifTableLastChange.0") )
		{
			$result = $result->{"1.3.6.1.2.1.31.1.5.0"};
			if ( defined $result and not defined $catchall_data->{ifTableLastChange} )
			{
				info("$catchall_data->{name} using ifTableLastChange for interface updates");
				$catchall_data->{ifTableLastChange} = $result;
			}
			elsif ( $catchall_data->{ifTableLastChange} != $result )
			{
				info(
					"$catchall_data->{name} ifTableLastChange has changed old=$catchall_data->{ifTableLastChange} new=$result"
				);
				$catchall_data->{ifTableLastChange} = $result;
			}
			else
			{
				info("$catchall_data->{name} ifTableLastChange NO change, skipping ");

				# returning 1 as we can do the rest of the updates.
				return 1;
			}
		}

		# else node may not have this variable so keep on doing in the hard way.

		info("Starting");
		info("Get Interface Info of node $catchall_data->{name}, model $catchall_data->{nodeModel}");

		# lets delete what we have in memory and start from scratch.
		# BUT only if this is for all interfaces
		if ( not $singleInterface )
		{
			# delete $NI->{interface};
			NMISNG::Util::TODO("Need to mark interfaces as historic!");
			delete $S->ndinfo->{inteface}; # keep this for now so NI get's cleaned up
		}

		# load interface types (IANA). number => name
		my $IFT = loadifTypesTable();

		my ( $error, $override ) = ( undef, undef );
		( $error, $override ) = get_nodeconf( node => $nodename )
			if ( has_nodeconf( node => $nodename ) );
		logMsg("ERROR $error") if ($error);
		$override ||= {};

		# get interface Index table
		my @ifIndexNum;
		my $ifIndexTable;
		my $ifIndexMap = {};

		if ($singleInterface)
		{
			push( @ifIndexNum, $intf_one );
		}
		else
		{
			if ( $ifIndexTable = $SNMP->gettable('ifIndex') )
			{
				foreach my $oid ( oid_lex_sort( keys %{$ifIndexTable} ) )
				{
					# to handle stupid devices with ifIndexes which are 64 bit integers
					if ( $ifIndexTable->{$oid} < 0 )
					{
						$ifIndexTable->{$oid} = unpack( "I", pack( "i", $ifIndexTable->{$oid} ) );
					}
					push @ifIndexNum, $ifIndexTable->{$oid};
					$ifIndexMap->{$ifIndexTable->{$oid}} = 1;
				}
			}
			else
			{
				if ( $SNMP->error =~ /is empty or does not exist/ )
				{
					info( "SNMP Object Not Present ($S->{name}) on get interface index table: " . $SNMP->error );
				}

				# snmp failed
				else
				{
					logMsg( "ERROR ($S->{name}) on get interface index table: " . $SNMP->error );
					HandleNodeDown( sys => $S, type => "snmp", details => $SNMP->error );
				}

				info("Finished");
				return 0;
			}

			# remove unknown interfaces, found in previous runs, from table
			### possible vivification
			my $ids = $nmisng_node->get_inventory_ids( concept => 'interface' );
			foreach my $id (@$ids)
			{
				# we may want a faster way to do this, perhaps ask for the ids along with some data?
				my ( $inventory, $error_message ) = $nmisng_node->inventory( _id => $id );
				$nmisng->log->warn("Failed to get Inventory for interface:$id, error:$error_message") && next
					if(!$inventory);

				my $index = $inventory->data()->{index};

				if ( !defined( $ifIndexMap->{$index} ) )
				{
					$inventory->historic(1);
					$inventory->save();
					
					foreach my $graphtype (qw(interface pkts pkts_hc))
					{
						delete $graphtypes->{$index}{$graphtype} if ( defined $graphtypes->{$index}{$graphtype} );
					}
					dbg("Interface ifIndex=$index removed from table");
					logMsg("INFO ($S->{name}) Interface ifIndex=$index removed from table");    # test info
				}
			}
			delete $V->{interface};    # rebuild interface view table
		}

		# Loop to get interface information, will be stored in {ifinfo} table => $IF
		# keep the ifIndexs we care about.
		my @ifIndexNumManage;
		foreach my $index (@ifIndexNum)
		{
			next if ( $singleInterface and $intf_one ne $index );    # only one interface

			$target_table->{$index} = {};
			my $target = $target_table->{$index};
			if ($S->loadInfo(
					class  => 'interface',
					index  => $index,
					model  => $model,
					target => $target
				)
				)
			{
				# note: nodeconf overrides are NOT applied at this point!
				checkIntfInfo( sys => $S, index => $index, iftype => $IFT, target => $target );

				my $keepInterface = 1;
				if (    defined $S->{mdl}{custom}{interface}{skipIfType}
					and $S->{mdl}{custom}{interface}{skipIfType} ne ""
					and $target->{ifType} =~ /$S->{mdl}{custom}{interface}{skipIfType}/ )
				{
					$keepInterface = 0;
					info(
						"SKIP Interface ifType matched skipIfType ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}
				elsif ( defined $S->{mdl}{custom}{interface}{skipIfDescr}
					and $S->{mdl}{custom}{interface}{skipIfDescr} ne ""
					and $target->{ifDescr} =~ /$S->{mdl}{custom}{interface}{skipIfDescr}/ )
				{
					$keepInterface = 0;
					info(
						"SKIP Interface ifDescr matched skipIfDescr ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}

				if ( not $keepInterface )
				{
					# not easy.
					foreach my $key ( keys %$target )
					{
						if ( exists $V->{interface}{"${index}_${key}_title"} )
						{
							delete $V->{interface}{"${index}_${key}_title"};
						}
						if ( exists $V->{interface}{"${index}_${key}_value"} )
						{
							delete $V->{interface}{"${index}_${key}_value"};
						}
					}

					# easy!
					delete $target_table->{$index};
					NMISNG::Util::TODO("Should this info be kept but marked disabled?");
				}
				else
				{
					logMsg("INFO ($S->{name}) ifadminstatus is empty for index=$index")
						if $target->{ifAdminStatus} eq "";
					info(
						"ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType} ifAdminStatus=$target->{ifAdminStatus} ifOperStatus=$target->{ifOperStatus} ifSpeed=$target->{ifSpeed}"
					);
					push( @ifIndexNumManage, $index );
				}
			}
			else
			{
				# snmp failed
				HandleNodeDown( sys => $S, type => "snmp", details => $S->status->{snmp_error} );

				if ( getbool( $C->{snmp_stop_polling_on_error} ) )
				{
					info("Finished (stop polling on error)");
					return 0;
				}
			}
		}

		# copy the new list back.
		@ifIndexNum       = @ifIndexNumManage;
		@ifIndexNumManage = ();

		# port information optional
		if ( $M->{port} ne "" )
		{
			foreach my $index (@ifIndexNum)
			{
				next if ( $singleInterface and $intf_one ne $index );
				my $target = $target_table->{$index};

				# get the VLAN info: table is indexed by port.portnumber
				if ( $target->{ifDescr} =~ /\d{1,2}\/(\d{1,2})$/i )
				{    # FastEthernet0/1
					my $port = '1.' . $1;
					if ( $target->{ifDescr} =~ /(\d{1,2})\/\d{1,2}\/(\d{1,2})$/i )
					{    # FastEthernet1/0/0
						$port = $1 . '.' . $2;
					}
					if ($S->loadInfo(
							class  => 'port',
							index  => $index,
							port   => $port,
							table  => 'interface',
							model  => $model,
							target => $target
						)
						)
					{
						#
						last if $target->{vlanPortVlan} eq "";    # model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"}
							= convertIfSpeed( $target->{portAdminSpeed} );
						dbg("get VLAN details: index=$index, ifDescr=$target->{ifDescr}");
						dbg("portNumber: $port, VLan: $target->{vlanPortVlan}, AdminSpeed: $target->{portAdminSpeed}" );
					}
				}
				else
				{
					my $port;
					if ( $target->{ifDescr} =~ /(\d{1,2})\D(\d{1,2})$/ )
					{                                                 # 0-0 Catalyst
						$port = $1 . '.' . $2;
					}
					if ($S->loadInfo(
							class  => 'port',
							index  => $index,
							port   => $port,
							table  => 'interface',
							model  => $model,
							target => $target
						)
						)
					{
						#
						last if $target->{vlanPortVlan} eq "";    # model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"}
							= convertIfSpeed( $target->{portAdminSpeed} );
						dbg("get VLAN details: index=$index, ifDescr=$target->{ifDescr}");
						dbg("portNumber: $port, VLan: $target->{vlanPortVlan}, AdminSpeed: $target->{portAdminSpeed}" );
					}
				}
			}
		}

		if (    $singleInterface
			and defined $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle}
			and getbool( $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle} ) )
		{
			info("Skipping Device IP Address Table because skipIpAddressTableOnSingle is false");
		}
		else
		{
			my $ifAdEntTable;
			my $ifMaskTable;
			my %ifCnt;
			info("Getting Device IP Address Table");
			if ( $ifAdEntTable = $SNMP->getindex('ipAdEntIfIndex') )
			{
				if ( $ifMaskTable = $SNMP->getindex('ipAdEntNetMask') )
				{
					foreach my $addr ( keys %{$ifAdEntTable} )
					{
						my $index = $ifAdEntTable->{$addr};
						next if ( $singleInterface and $intf_one ne $index );
						$ifCnt{$index} += 1;
						my $target = $target_table->{$index};
						info("ifIndex=$ifAdEntTable->{$addr}, addr=$addr  mask=$ifMaskTable->{$addr}");
						$target->{"ipAdEntAddr$ifCnt{$index}"}    = $addr;
						$target->{"ipAdEntNetMask$ifCnt{$index}"} = $ifMaskTable->{$addr};

						# NOTE: inventory, breaks index convention here! not a big deal but it happens
						(   $target_table->{$ifAdEntTable->{$addr}}{"ipSubnet$ifCnt{$index}"},
							$target_table->{$ifAdEntTable->{$addr}}{"ipSubnetBits$ifCnt{$index}"}
						) = ipSubnet( address => $addr, mask => $ifMaskTable->{$addr} );
						$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_title"} = 'IP address / mask';
						$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_value"}
							= "$addr / $ifMaskTable->{$addr}";
					}
				}
				else
				{
					dbg("ERROR getting Device Ip Address table");
				}
			}
			else
			{
				dbg("ERROR getting Device Ip Address table");
			}
		}

		# pre compile regex
		my $qr_no_collect_ifDescr_gen      = qr/($S->{mdl}{interface}{nocollect}{ifDescr})/i;
		my $qr_no_collect_ifType_gen       = qr/($S->{mdl}{interface}{nocollect}{ifType})/i;
		my $qr_no_collect_ifAlias_gen      = qr/($S->{mdl}{interface}{nocollect}{Description})/i;
		my $qr_no_collect_ifOperStatus_gen = qr/($S->{mdl}{interface}{nocollect}{ifOperStatus})/i;

		### 2012-03-14 keiths, collecting override based on interface description.
		my $qr_collect_ifAlias_gen = 0;
		$qr_collect_ifAlias_gen = qr/($S->{mdl}{interface}{collect}{Description})/
			if $S->{mdl}{interface}{collect}{Description};
		my $qr_collect_ifDescr_gen = 0;    # undef would be a match-always regex!
		$qr_collect_ifDescr_gen = qr/($S->{mdl}->{interface}->{collect}->{ifDescr})/i
			if ( $S->{mdl}->{interface}->{collect}->{ifDescr} );

		my $qr_no_event_ifAlias_gen = qr/($S->{mdl}{interface}{noevent}{Description})/i;
		my $qr_no_event_ifDescr_gen = qr/($S->{mdl}{interface}{noevent}{ifDescr})/i;
		my $qr_no_event_ifType_gen  = qr/($S->{mdl}{interface}{noevent}{ifType})/i;

		my $noDescription = $M->{interface}{nocollect}{noDescription};

		### 2013-03-05 keiths, global collect policy override from Config!
		if ( defined $C->{global_nocollect_noDescription} and $C->{global_nocollect_noDescription} ne "" )
		{
			$noDescription = $C->{global_nocollect_noDescription};
			info("INFO Model overriden by Global Config for global_nocollect_noDescription");
		}

		if ( defined $C->{global_collect_Description} and $C->{global_collect_Description} ne "" )
		{
			$qr_collect_ifAlias_gen = qr/($C->{global_collect_Description})/i;
			info("INFO Model overriden by Global Config for global_collect_Description");
		}

		# is collection overridden globally, on or off? (on wins if both are set)
		if ( defined $C->{global_collect_ifDescr} and $C->{global_collect_ifDescr} ne '' )
		{
			$qr_collect_ifDescr_gen = qr/($C->{global_collect_ifDescr})/i;
			info("INFO Model overriden by Global Config for global_collect_ifDescr");
		}
		elsif ( defined $C->{global_nocollect_ifDescr} and $C->{global_nocollect_ifDescr} ne "" )
		{
			$qr_no_collect_ifDescr_gen = qr/($C->{global_nocollect_ifDescr})/i;
			info("INFO Model overriden by Global Config for global_nocollect_ifDescr");
		}

		if ( defined $C->{global_nocollect_Description} and $C->{global_nocollect_Description} ne "" )
		{
			$qr_no_collect_ifAlias_gen = qr/($C->{global_nocollect_Description})/i;
			info("INFO Model overriden by Global Config for global_nocollect_Description");
		}

		if ( defined $C->{global_nocollect_ifType} and $C->{global_nocollect_ifType} ne "" )
		{
			$qr_no_collect_ifType_gen = qr/($C->{global_nocollect_ifType})/i;
			info("INFO Model overriden by Global Config for global_nocollect_ifType");
		}

		if ( defined $C->{global_nocollect_ifOperStatus} and $C->{global_nocollect_ifOperStatus} ne "" )
		{
			$qr_no_collect_ifOperStatus_gen = qr/($C->{global_nocollect_ifOperStatus})/i;
			info("INFO Model overriden by Global Config for global_nocollect_ifOperStatus");
		}

		if ( defined $C->{global_noevent_ifDescr} and $C->{global_noevent_ifDescr} ne "" )
		{
			$qr_no_event_ifDescr_gen = qr/($C->{global_noevent_ifDescr})/i;
			info("INFO Model overriden by Global Config for global_noevent_ifDescr");
		}

		if ( defined $C->{global_noevent_Description} and $C->{global_noevent_Description} ne "" )
		{
			$qr_no_event_ifAlias_gen = qr/($C->{global_noevent_Description})/i;
			info("INFO Model overriden by Global Config for global_noevent_Description");
		}

		if ( defined $C->{global_noevent_ifType} and $C->{global_noevent_ifType} ne "" )
		{
			$qr_no_event_ifType_gen = qr/($C->{global_noevent_ifType})/i;
			info("INFO Model overriden by Global Config for global_noevent_ifType");
		}

		my $intfTotal   = 0;
		my $intfCollect = 0;    # reset counters

		info("Checking interfaces for duplicate ifDescr");
		my $ifDescrIndx;
		foreach my $i (@ifIndexNum)
		{
			my $target = $target_table->{$i};

			#foreach my $i (keys %{$IF}) {
			# ifDescr must always be filled
			$target->{ifDescr} ||= $i;

			if ( exists $ifDescrIndx->{$target->{ifDescr}} and $ifDescrIndx->{$target->{ifDescr}} ne "" )
			{
				# ifDescr is duplicated.
				$target->{ifDescr} = "$target->{ifDescr}-$i";                  # add index to string
				$V->{interface}{"${i}_ifDescr_value"} = $target->{ifDescr};    # update
				info("Interface ifDescr changed to $target->{ifDescr}");
			}
			else
			{
				$ifDescrIndx->{$target->{ifDescr}} = $i;
			}
		}
		info("Completed duplicate ifDescr processing");

		### 2012-10-08 keiths, updates to index node conf table by ifDescr instead of ifIndex.
		foreach my $index (@ifIndexNum)
		{
			next if ( $singleInterface and $intf_one ne $index );
			my $target = $target_table->{$index};

			my $ifDescr = $target->{ifDescr};
			$intfTotal++;

			# count total number of real interfaces
			if (    $target->{ifType} !~ /$qr_no_collect_ifType_gen/
				and $target->{ifDescr} !~ /$qr_no_collect_ifDescr_gen/ )
			{
				$target->{real} = 'true';
			}

			### add in anything we find from nodeConf - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			if ( ref( $override->{$ifDescr} ) eq "HASH" )
			{
				my $thisintfover = $override->{$ifDescr};

				if ( $thisintfover->{Description} )
				{
					$target->{nc_Description} = $target->{Description};                         # save
					$target->{Description}    = $V->{interface}{"${index}_Description_value"}
						= $thisintfover->{Description};
					info("Manual update of Description by nodeConf");
				}
				if ( $thisintfover->{display_name} )
				{
					$target->{display_name} = $V->{interface}->{"${index}_display_name_value"}
						= $thisintfover->{display_name};
					$V->{interface}->{"${index}_display_name_title"} = "Display Name";

					# no log/diag msg as  this comes ONLY from nodeconf, it's not overriding anything
				}

				for my $speedname (qw(ifSpeed ifSpeedIn ifSpeedOut))
				{
					if ( $thisintfover->{$speedname} )
					{
						$target->{"nc_$speedname"} = $target->{$speedname};    # save
						$target->{$speedname} = $thisintfover->{$speedname};

						### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
						$V->{interface}{"${index}_${speedname}_value"} = convertIfSpeed( $target->{$speedname} );
						info("Manual update of $speedname by nodeConf");
					}
				}

				if ( $thisintfover->{setlimits} && $thisintfover->{setlimits} =~ /^(normal|strict|off)$/ )
				{
					$target->{setlimits} = $thisintfover->{setlimits};
				}
			}

			# set default for the speed  limit enforcement
			$target->{setlimits} ||= 'normal';

			# set default for collect, event and threshold: on, possibly overridden later
			$target->{collect}   = "true";
			$target->{event}     = "true";
			$target->{threshold} = "true";
			$target->{nocollect} = "Collecting: Collection Policy";
		  #
		  #Decide if the interface is one that we can do stats on or not based on Description and ifType and AdminStatus
		  # If the interface is admin down no statistics
			### 2012-03-14 keiths, collecting override based on interface description.
			if (    $qr_collect_ifAlias_gen
				and $target->{Description} =~ /$qr_collect_ifAlias_gen/i )
			{
				$target->{collect}   = "true";
				$target->{nocollect} = "Collecting: found $1 in Description";    # reason
			}
			elsif ( $qr_collect_ifDescr_gen
				and $target->{ifDescr} =~ /$qr_collect_ifDescr_gen/i )
			{
				$target->{collect}   = "true";
				$target->{nocollect} = "Collecting: found $1 in ifDescr";
			}
			elsif ( $target->{ifAdminStatus} =~ /down|testing|null/ )
			{
				$target->{collect}   = "false";
				$target->{event}     = "false";
				$target->{nocollect} = "ifAdminStatus eq down|testing|null";     # reason
				$target->{noevent}   = "ifAdminStatus eq down|testing|null";     # reason
			}
			elsif ( $target->{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifDescr";    # reason
			}
			elsif ( $target->{ifType} =~ /$qr_no_collect_ifType_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifType";     # reason
			}
			elsif ( $target->{Description} =~ /$qr_no_collect_ifAlias_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in Description";    # reason
			}
			elsif ( $target->{Description} eq "" and $noDescription eq 'true' )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: no Description (ifAlias)";    # reason
			}
			elsif ( $target->{ifOperStatus} =~ /$qr_no_collect_ifOperStatus_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifOperStatus";    # reason
			}

			# if the interface has been down for too many days to be in use now.
			elsif ( $target->{ifAdminStatus} =~ /up/
				and $target->{ifOperStatus} =~ /down/
				and ( $catchall_data->{sysUpTimeSec} - $target->{ifLastChangeSec} ) / 86400
				> $nocollect_interface_down_days )
			{
				$target->{collect} = "false";
				$target->{nocollect}
					= "Not Collecting: interface down for more than $nocollect_interface_down_days days";    # reason
			}

			# send events ?
			if ( $target->{Description} =~ /$qr_no_event_ifAlias_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifAlias";                                                  # reason
			}
			elsif ( $target->{ifType} =~ /$qr_no_event_ifType_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifType";                                                   # reason
			}
			elsif ( $target->{ifDescr} =~ /$qr_no_event_ifDescr_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifDescr";                                                  # reason
			}

			# convert interface name
			$target->{interface} = convertIfName( $target->{ifDescr} );
			$target->{ifIndex}   = $index;

			# modify by node Config ?
			if ( ref( $override->{$ifDescr} ) eq "HASH" )
			{
				my $thisintfover = $override->{$ifDescr};

				if ( $thisintfover->{collect} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_collect} = $target->{collect};
					$target->{collect}    = $thisintfover->{collect};
					info("Manual update of Collect by nodeConf");

					### 2014-04-28 keiths, fixing info for GUI
					if ( getbool( $target->{collect}, "invert" ) )
					{
						$target->{nocollect} = "Not Collecting: Manual update by nodeConf";
					}
					else
					{
						$target->{nocollect} = "Collecting: Manual update by nodeConf";
					}
				}

				if ( $thisintfover->{event} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_event} = $target->{event};
					$target->{event}    = $thisintfover->{event};
					$target->{noevent}  = "Manual update by nodeConf"
						if ( getbool( $target->{event}, "invert" ) );    # reason
					info("Manual update of Event by nodeConf");
				}

				if ( $thisintfover->{threshold} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_threshold} = $target->{threshold};
					$target->{threshold}    = $thisintfover->{threshold};
					$target->{nothreshold}  = "Manual update by nodeConf"
						if ( getbool( $target->{threshold}, "invert" ) );    # reason
					info("Manual update of Threshold by nodeConf");
				}
			}

			# interface now up or down, check and set or clear outstanding event.
			if (    getbool( $target->{collect} )
				and $target->{ifAdminStatus} =~ /up|ok/
				and $target->{ifOperStatus} !~ /up|ok|dormant/ )
			{
				if ( getbool( $target->{event} ) )
				{
					notify(
						sys     => $S,
						event   => "Interface Down",
						element => $target->{ifDescr},
						details => $target->{Description},
						context => {type => "interface"},
					);
				}
			}
			else
			{
				checkEvent(
					sys     => $S,
					event   => "Interface Down",
					level   => "Normal",
					element => $target->{ifDescr},
					details => $target->{Description}
				);
			}

			if ( getbool( $target->{collect}, "invert" ) )
			{
				### 2014-10-21 keiths, get rid of bad interface graph types when ifIndexes get changed.
				my @types = qw(pkts pkts_hc interface);
				foreach my $type (@types)
				{
					if ( exists $graphtypes->{$index}{$type} )
					{
						logMsg("Interface not collecting, removing graphtype $type for interface $index");
						delete $graphtypes->{$index}{$type};
					}
				}
			}

			# number of interfaces collected with collect and event on
			$intfCollect++ if ( getbool( $target->{collect} )
				&& getbool( $target->{event} ) );

			# save values only if all interfaces are updated
			if ( $intf_one eq '' )
			{
				$catchall_data->{intfTotal}   = $intfTotal;
				$catchall_data->{intfCollect} = $intfCollect;
			}

			# prepare values for web page
			$V->{interface}{"${index}_event_value"} = $target->{event};
			$V->{interface}{"${index}_event_title"} = 'Event on';

			$V->{interface}{"${index}_threshold_value"}
				= !getbool( $NC->{node}{threshold} ) ? 'false' : $target->{threshold};
			$V->{interface}{"${index}_threshold_title"} = 'Threshold on';

			$V->{interface}{"${index}_collect_value"} = $target->{collect};
			$V->{interface}{"${index}_collect_title"} = 'Collect on';

			$V->{interface}{"${index}_nocollect_value"} = $target->{nocollect};
			$V->{interface}{"${index}_nocollect_title"} = 'Reason';

			# collect status
			if ( getbool( $target->{collect} ) )
			{
				info("$target->{ifDescr} ifIndex $index, collect=true");
			}
			else
			{
				info("$target->{ifDescr} ifIndex $index, collect=false, $target->{nocollect}");

				# if  collect is of then disable event and threshold (clearly not applicable)
				$target->{threshold} = $V->{interface}{"${index}_threshold_value"} = 'false';
				$target->{event}     = $V->{interface}{"${index}_event_value"}     = 'false';
			}

			# get color depending of state
			$V->{interface}{"${index}_ifAdminStatus_color"} = getAdminColor( sys => $S, index => $index );
			$V->{interface}{"${index}_ifOperStatus_color"} = getOperColor( sys => $S, index => $index );

			# index number of interface
			$V->{interface}{"${index}_ifIndex_value"} = $index;
			$V->{interface}{"${index}_ifIndex_title"} = 'ifIndex';

			# at this point every thing is ready for the rrd speed limit enforcement
			my $desiredlimit = $target->{setlimits};

			# write if inventory data now. the speed limit/checking code requires the entries to exist in order to correctly find them in parseString/etc


			# For now, create inventory at the very end
			# get the inventory object for this, path_keys required as we don't know what type it will be
			my $path_keys = ['index'];    # for now use this, loadInfo guarnatees it will exist
			my $path = $nmisng_node->inventory_path( concept => 'interface', data => $target, path_keys => $path_keys );			
			if( ref($path) eq 'ARRAY')
			{
				my ( $inventory, $error_message ) = $nmisng_node->inventory(
					concept   => 'interface',
					data      => $target,
					path      => $path,
					path_keys => $path_keys,
					create    => 1
				);
				$S->nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
				# regenerate the path, if this thing wasn't new the path may have changed, which is ok
				$inventory->path( recalculate => 1 );
				$inventory->historic(0);				
				my ( $op, $error ) = $inventory->save();
				info( "saved ".join(',', @$path)." op: $op");
				$nmisng->log->error( "Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
					if ($error);
			}
			else 
			{
				$nmisng->log->error("Failed to create path for inventory, error:$path");
			}

			# the following don't modify $target so no extra saving required

			# no limit or dud limit or dud speed or non-collected interface?
			if (   $desiredlimit
				&& $desiredlimit =~ /^(normal|strict|off)$/
				&& $target->{ifSpeed}
				&& getbool( $target->{collect} ) )
			{
				info(
					"performing rrd speed limit tuning for $ifDescr, limit enforcement: $desiredlimit, interface speed is "
						. convertIfSpeed( $target->{ifSpeed} )
						. " ($target->{ifSpeed})" );

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
				my $maxbytes
					= $desiredlimit eq "off"    ? "U"
					: $desiredlimit eq "normal" ? int( $target->{ifSpeed} / 4 )
					:                             int( $target->{ifSpeed} / 8 );
				my $maxpkts = $maxbytes eq "U" ? "U" : int( $maxbytes / 50 );    # this is a dodgy heuristic

				for (
					["interface", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)/],
					[   "pkts",
						qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/
					],
					[   "pkts_hc",
						qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/
					],
					)
				{
					my ( $datatype, $dsregex ) = @$_;

					# rrd file exists and readable?
					if ( -r ( my $rrdfile = $S->makeRRDname( graphtype => $datatype, index => $index ) ) )
					{
						my $fileinfo = RRDs::info($rrdfile);
						for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
						{
							# only touch relevant and known datasets
							next if ( $matching !~ /($dsregex)/ );
							my $dsname = $1;

							my $curval = $fileinfo->{$matching};
							$curval = "U" if ( !defined $curval or $curval eq "" );

							# the pkts, discards, errors DS are packet based; the octets ones are bytes
							my $desiredval = $dsname =~ /octets/i ? $maxbytes : $maxpkts;

							if ( $curval ne $desiredval )
							{
								info(
									"rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
								);
								RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
							}
							else
							{
								info("rrd section $datatype, ds $dsname, current limit $curval is correct");
							}
						}
					}
				}
			}

		}

		info("Finished");
	}
	elsif ( $catchall_data->{ifNumber} > $interface_max_number )
	{
		info("Skipping, interface count $catchall_data->{ifNumber} exceeds configured maximum $interface_max_number");
	}
	else
	{
		info("Skipping, interfaces not defined in Model");
	}

	return 1;
}    # end getIntfInfo

#=========================================================================================

# check and adjust/modify some values of interface
# args: sys object, index, iftype
# returns: nothing
sub checkIntfInfo
{
	my %args = @_;

	my $S          = $args{sys};
	my $index      = $args{index};
	my $ifTypeDefs = $args{iftype};

	my $target = $args{target};
	my $V      = $S->view;

	my $thisintf = $target;
	if ( $thisintf->{ifDescr} eq "" ) { $thisintf->{ifDescr} = "null"; }

	# remove bad chars from interface descriptions
	$thisintf->{ifDescr}     = rmBadChars( $thisintf->{ifDescr} );
	$thisintf->{Description} = rmBadChars( $thisintf->{Description} );

	# Try to set the ifType to be something meaningful!!!!
	if ( exists $ifTypeDefs->{$thisintf->{ifType}}{ifType} )
	{
		$thisintf->{ifType} = $ifTypeDefs->{$thisintf->{ifType}}{ifType};
	}

	# Just check if it is an Frame Relay sub-interface
	if ( ( $thisintf->{ifType} eq "frameRelay" and $thisintf->{ifDescr} =~ /\./ ) )
	{
		$thisintf->{ifType} = "frameRelay-subinterface";
	}
	$V->{interface}{"${index}_ifType_value"} = $thisintf->{ifType};

	# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
	# ditto if ifspeed is zero
	if ( $thisintf->{ifSpeed} == 4294967295 or $thisintf->{ifSpeed} == 0 )
	{
		$thisintf->{ifSpeed} = $thisintf->{ifHighSpeed};
		$thisintf->{ifSpeed} *= 1000000;
	}

	# final fallback in case SNMP agent is DODGY
	$thisintf->{ifSpeed} ||= 1000000000;

	$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed( $thisintf->{ifSpeed} );

	# convert time integer to time string
	$V->{interface}{"${index}_ifLastChange_value"} = $thisintf->{ifLastChange}
		= convUpTime( $thisintf->{ifLastChangeSec} = int( $thisintf->{ifLastChange} / 100 ) );

}    # end checkIntfInfo

# fixme: this function does not work for wmi-only nodes
sub checkPIX
{
	my %args = @_;
	my $S    = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing PIX Failover check for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $V    = $S->view;
	my $SNMP = $S->snmp;
	my $result;

	dbg("Starting");

	# PIX failover test
	# table has six values
	# [0] primary.cfwHardwareInformation, [1] secondary.cfwHardwareInformation
	# [2] primary.HardwareStatusValue, [3] secondary.HardwareStatusValue
	# [4] primary.HardwareStatusDetail, [5] secondary.HardwareStatusDetail
	# if HardwareStatusDetail is blank ( ne 'Failover Off' ) then
	# HardwareStatusValue will have 'active' or 'standby'

	if ( $catchall_data->{nodeModel} eq "CiscoPIX" )
	{
		dbg("checkPIX, Getting Cisco PIX Failover Status");
		if ($result = $SNMP->get(
				'cfwHardwareStatusValue.6',  'cfwHardwareStatusValue.7',
				'cfwHardwareStatusDetail.6', 'cfwHardwareStatusDetail.7'
			)
			)
		{
			$result = $SNMP->keys2name($result);    # convert oid in hash key to name

			if ( $result->{'cfwHardwareStatusDetail.6'} ne 'Failover Off' )
			{
				if ( $result->{'cfwHardwareStatusValue.6'} == 0 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Failover Off";
				}
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 3 ) { $result->{'cfwHardwareStatusValue.6'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 9 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Active";
				}
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 10 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Standby";
				}
				else { $result->{'cfwHardwareStatusValue.6'} = "Unknown"; }

				if ( $result->{'cfwHardwareStatusValue.7'} == 0 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Failover Off";
				}
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 3 ) { $result->{'cfwHardwareStatusValue.7'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 9 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Active";
				}
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 10 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Standby";
				}
				else { $result->{'cfwHardwareStatusValue.7'} = "Unknown"; }

				# fixme unclean access to internal structure
				# fixme also fails if we've switched to updating this node on the go!
				if ( !getbool( $S->{update} ) )
				{
					if (   $result->{'cfwHardwareStatusValue.6'} ne $catchall_data->{pixPrimary}
						or $result->{'cfwHardwareStatusValue.7'} ne $catchall_data->{pixSecondary} )
					{
						dbg("PIX failover occurred");

						# As this is not stateful, alarm not sent to state table in sub eventAdd
						notify(
							sys     => $S,
							event   => "Node Failover",
							element => 'PIX',
							details =>
								"Primary now: $catchall_data->{pixPrimary}  Secondary now: $catchall_data->{pixSecondary}"
						);
					}
				}
				$catchall_data->{pixPrimary}   = $result->{'cfwHardwareStatusValue.6'};    # remember
				$catchall_data->{pixSecondary} = $result->{'cfwHardwareStatusValue.7'};

				$V->{system}{firewall_title} = "Failover Status";
				$V->{system}{firewall_value} = "Pri: $catchall_data->{pixPrimary} Sec: $catchall_data->{pixSecondary}";
				if (    $catchall_data->{pixPrimary} =~ /Failover Off|Active/i
					and $catchall_data->{pixSecondary} =~ /Failover Off|Standby/i )
				{
					$V->{system}{firewall_color} = "#00BB00";                           #normal
				}
				else
				{
					$V->{system}{firewall_color} = "#FFDD00";                           #warning

				}
			}
			else
			{
				$V->{system}{firewall_title} = "Failover Status";
				$V->{system}{firewall_value} = "Failover off";
			}
		}
	}
	dbg("Finished");
	return 1;
}

# fixme: this function does not work for wmi-only nodes, or environment sections that use wmi
#
sub getEnvInfo
{
	my %args = @_;
	my $S    = $args{sys};    # object
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getEnvInfo for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $V    = $S->view;
	my $SNMP = $S->snmp;
	my $M    = $S->mdl;           # node model table
	my $C    = loadConfTable();

	dbg("Starting");
	dbg("Get Environment Info of node $catchall_data->{name}, model $catchall_data->{nodeModel}");

	if ( !exists( $M->{environment} ) )
	{
		dbg("No class 'environment' declared in Model");
		return 1;
	}

	# fixme hardcoded model names are bad
	my @wantsections = ('env_temp');

	if ( $catchall_data->{nodeModel} =~ /AKCP-Sensor/i )
	{
		@wantsections = ( 'akcp_temp', 'akcp_hum' );
	}
	elsif ( $catchall_data->{nodeModel} =~ /CiscoCSS/i )
	{
		@wantsections = ( 'cssgroup', 'csscontent' );
	}

	for my $section (@wantsections)
	{
		next if ( !exists( $M->{environment}{sys}{$section} ) );
		next if ( !defined( $M->{environment}->{sys}->{$section}->{snmp} ) );    # wmi doesn't work yet

		# get Index table
		my $index_var = $M->{environment}{sys}{$section}{indexed};

		my ( %envIndexNum, $envIndexTable );
		if ( $envIndexTable = $SNMP->gettable($index_var) )
		{
			foreach my $oid ( oid_lex_sort( keys %{$envIndexTable} ) )
			{
				my $index = $oid;
				if ( $section =~ /^akcp_(temp|hum)$/ )
				{
					# check for sensor online, value 1 is online, add only online sensors
					next if ( $oid !~ /\.1\.5.\d+$/ or !$envIndexTable->{$oid} );

					dbg("sensor section=$section index=$index is online");
				}
				elsif ( $section eq "cssgroup" )
				{
					$oid =~ s/1\.3\.6\.1\.4\.1\.9\.9\.368\.1\.17\.2\.1\.2\.//g;
				}
				elsif ( $section eq "csscontent" )
				{
					$oid =~ s/1\.3\.6\.1\.4\.1\.9\.9\.368\.1\.16\.4\.1\.3\.//g;
				}
				elsif ( $oid =~ /\.(\d+)$/ )
				{
					$index = $1;
				}
				$envIndexNum{$index} = $index;
			}
		}
		elsif ( $SNMP->error =~ /is empty or does not exist/ )
		{
			info( "SNMP Object Not Present ($S->{name}) on get environment index table: " . $SNMP->error );
		}
		else
		{
			logMsg( "ERROR ($S->{name}) on get environment index table: " . $SNMP->error );
			HandleNodeDown( sys => $S, type => "snmp", details => "get environment index table: " . $SNMP->error );
		}

		# fixme: this loadinfo run is only required for snmp
		# Loop to get information, will be stored in {info}{$section} table
		foreach my $index ( sort keys %envIndexNum )
		{
			my $target = {};
			if ($S->loadInfo(
					class   => 'environment',
					section => $section,
					index   => $index,
					table   => $section,
					model   => $model,
					target  => $target
				)
				)
			{
				dbg("sensor section=$section index=$index read and stored");
				my $data = { index => $index};
				my $path_keys = ['index'];
				my $path = $S->nmisng_node->inventory_path( concept => $section, data => $target, path_keys => $path_keys );
				my ( $inventory, $error_message ) = $S->nmisng_node->inventory(
					concept   => $section,
					data      => $target,
					path      => $path,
					path_keys => $path_keys,
					create    => 1
				);
				$S->nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );

				# regenerate the path, if this thing wasn't new the path may have changed, which is ok
				$inventory->path( recalculate => 1 );
				$inventory->historic(0);
				# the above will put data into inventory, so save
				my ( $op, $error ) = $inventory->save();
				info( "saved ".join(',', @$path)." op: $op");
				$S->nmisng->log->error(
					"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
					if ($error);
			}
			else
			{
				my $error = $S->status->{snmp_error};
				HandleNodeDown( sys => $S, type => "snmp", details => "get environment table index $index" );
			}
		}
		NMISNG::Util::TODO('# NEED TO DISABLE / CLEAN UP UNUSED HERE');
	}

	dbg("Finished");
	return 1;
}

sub getEnvData
{
	my %args = @_;
	my $S    = $args{sys};    # object

	my $NI = $S->ndinfo;      # node info table
	my $V  = $S->view;
	my $M  = $S->mdl;         # node model table
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = loadConfTable();

	dbg("Starting");
	dbg("Get Environment Data of node $catchall_data->{name}, model $catchall_data->{nodeModel}");

	if ( ref( $M->{environment} ) ne "HASH" or !keys %{$M->{environment}} )
	{
		dbg("No class 'environment' declared in Model");
		return 1;             # done
	}

	# fixme hardcoded model names are bad
	my @wantsections = ('env_temp');

	if ( $catchall_data->{nodeModel} =~ /AKCP-Sensor/i )
	{
		@wantsections = ( 'akcp_temp', 'akcp_hum' );
	}
	elsif ( $catchall_data->{nodeModel} =~ /CiscoCSS/i )
	{
		@wantsections = ( 'cssgroup', 'csscontent' );
	}

	for my $section (@wantsections)
	{
		next if ( !exists( $S->{info}->{$section} ) );    # no list of indices, nothing to do

		for my $index ( sort keys %{$S->{info}{$section}} )
		{
			my $rrdData = $S->getData(
				class   => 'environment',
				section => $section,
				index   => $index,
				model   => $model
			);
			my $howdiditgo = $S->status;
			my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

			# were there any errors?
			if ( !$anyerror )
			{
				processAlerts( S => $S );

				foreach my $sect ( keys %{$rrdData} )
				{
					my $D = $rrdData->{$sect}{$index};

					# RRD Database update and remember filename
					my $db = $S->create_update_rrd( data => $D, type => $sect, index => $index );
					if ( !$db )
					{
						logMsg( "ERROR updateRRD failed: " . getRRDerror() );
					}
				}
			}
			else
			{
				logMsg("ERROR ($catchall_data->{name}) on getEnvData, $anyerror");
				HandleNodeDown( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
					if ( $howdiditgo->{snmp_error} );
				HandleNodeDown( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
					if ( $howdiditgo->{wmi_error} );

				return 0;
			}
		}
	}
	dbg("Finished");
	return 1;
}

# retrieve system health index data from snmp, done during update
# args: sys (object)
# returns: 1 if all present sections worked, 0 otherwise
# note: raises xyz down events if snmp or wmi are down
sub getSystemHealthInfo
{
	my %args = @_;
	my $S    = $args{sys};    # object

	my $V    = $S->view;
	my $SNMP = $S->snmp;
	my $M    = $S->mdl;           # node model table
	my $C    = loadConfTable();
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	# create the node here for now, this should be passed in as a param in the future
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;

	info("Starting");
	info("Get systemHealth Info of node $catchall_data->{name}, model $catchall_data->{nodeModel}");

	if ( ref( $M->{systemHealth} ) ne "HASH" )
	{
		dbg("No class 'systemHealth' declared in Model.");
		return 0;
	}
	elsif ( !$S->status->{snmp_enabled} && !$S->status->{wmi_enabled} )
	{
		logMsg("ERROR: cannot get systemHealth info, neither SNMP nor WMI enabled!");
		return 0;
	}

	# get the default (sub)sections from config, model can override
	my @healthSections = split(
		",",
		(   defined( $M->{systemHealth}{sections} )
			? $M->{systemHealth}{sections}
			: $C->{model_health_sections}
		)
	);
	for my $section (@healthSections)
	{
		# TODO:
		NMISNG::Util::TODO("Does deleting all of the inventory for a section does not make sense, need to loop through and mark unused as historic!");
		# make sure NI is cleaned up
		delete $S->ndinfo->{$section};

		next
			if ( !exists( $M->{systemHealth}->{sys}->{$section} ) ); # if the config provides list but the model doesn't

		my $thissection = $M->{systemHealth}->{sys}->{$section};

		# all systemhealth sections must be indexed by something
		# this holds the name, snmp or wmi
		my $index_var;

		# or if you want to use a raw oid instead: use 'index_oid' => '1.3.6.1.4.1.2021.13.15.1.1.1',
		my $index_snmp;

		# and for obscure SNMP Indexes a more generous snmp index regex can be given:
		# in the systemHealth section of the model 'index_regex' => '\.(\d+\.\d+\.\d+)$',
		# attention: FIRST capture group must return the index part
		my $index_regex = '\.(\d+)$';

		$index_var = $index_snmp = $thissection->{indexed};
		$index_regex = $thissection->{index_regex} if ( exists( $thissection->{index_regex} ) );
		$index_snmp  = $thissection->{index_oid}   if ( exists( $thissection->{index_oid} ) );

		if ( !defined($index_var) or $index_var eq '' )
		{
			dbg("No index var found for $section, skipping");
			next;
		}

		# determine if this is an snmp- OR wmi-backed systemhealth section
		# combination of both cannot work, as there is only one index
		if ( exists( $thissection->{wmi} ) and exists( $thissection->{snmp} ) )
		{
			logMsg("ERROR, systemhealth: section=$section cannot have both sources WMI and SNMP enabled!");
			info("ERROR, systemhealth: section=$section cannot have both sources WMI and SNMP enabled!");
			next;    # fixme: or is this completely terminal for this model?
		}

		if ( exists( $thissection->{wmi} ) )
		{
			info("systemhealth: section=$section, source WMI, index_var=$index_var");

			my $wmiaccessor = $S->wmi;
			if ( !$wmiaccessor )
			{
				info("skipping section $section: source WMI but node $S->{name} not configured for WMI");
				next;
			}

			# model broken if it says 'indexed by X' but doesn't have a query section for 'X'
			if ( !exists( $thissection->{wmi}->{$index_var} ) )
			{
				logMsg("ERROR: Model section $section is missing declaration for index_var $index_var!");
				next;
			}

			my $wmisection   = $thissection->{wmi};          # the whole section, might contain more than just the index
			my $indexsection = $wmisection->{$index_var};    # the subsection for the index var

			# query can come from -common- or from the index var's own section
			my $query = (
				exists( $indexsection->{query} ) ? $indexsection->{query}
				: ( ref( $wmisection->{"-common-"} ) eq "HASH"
						&& exists( $wmisection->{"-common-"}->{query} ) ) ? $wmisection->{"-common-"}->{query}
				: undef
			);
			if ( !$query or !$indexsection->{field} )
			{
				logMsg("ERROR: Model section $section is missing query or field for WMI variable  $index_var!");
				next;
			}

			# wmi gettable could give us both the indices and the data, but here we want only the different index values
			my ( $error, $fields, $meta ) = $wmiaccessor->gettable(
				wql    => $query,
				index  => $index_var,
				fields => [$index_var]
			);

			if ($error)
			{
				logMsg("ERROR ($S->{name}) failed to get index table for systemHealth $section: $error");
				HandleNodeDown(
					sys     => $S,
					type    => "wmi",
					details => "failed to get index table for systemHealth $section: $error"
				);
				next;
			}

			# fixme: meta might tell us that the indexing didn't work with the given field, if so we should bail out
			for my $indexvalue ( keys %$fields )
			{
				dbg("section=$section index=$index_var, found value=$indexvalue");

				# save the seen index value
				my $target = {$index_var => $indexvalue};

				# $NI->{$section}->{$indexvalue}->{} = $indexvalue;

				# then get all data for this indexvalue
				# Inventory note: for now Sys will populate the nodeinfo section it cares about
				# afer successful load we'll delete it. in the future loadinfo should maybe be passed
				# the location we want the data to go
				if ($S->loadInfo(
						class   => 'systemHealth',
						section => $section,
						index   => $indexvalue,
						table   => $section,
						model   => $model,
						target  => $target
					)
					)
				{
					info("section=$section index=$indexvalue read and stored");

					# $index_var is correct but the loading side in S->inventory doesn't know what the key will be in data
					# so use 'index' for now.
					# loadInfo always sets {index}, sadly it doesn't always come out of loadInfo correct so do it again
					$target->{index} = $target->{$index_var};
					# my $path_keys = [$index_var];
					my $path_keys = ['index'];
					my $path = $nmisng_node->inventory_path( concept => $section, data => $target, path_keys => $path_keys );
					my ( $inventory, $error_message ) = $nmisng_node->inventory(
						concept   => $section,
						data      => $target,
						path      => $path,
						path_keys => $path_keys,
						create    => 1
					);
					$nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$inventory->path( recalculate => 1 );
					$inventory->historic(0);
					# the above will put data into inventory, so save
					my ( $op, $error ) = $inventory->save();
					info( "saved ".join(',', @$path)." op: $op");
					$nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{wmi_error};
					logMsg("ERROR ($S->{name}) failed to get table for systemHealth $section: $error");
					HandleNodeDown(
						sys     => $S,
						type    => "wmi",
						details => "failed to get table for systemHealth $section: $error"
					);
					next;
				}
			}
		}
		else
		{
			info("systemHealth: section=$section, source SNMP, index_var=$index_var, index_snmp=$index_snmp");
			my ( %healthIndexNum, $healthIndexTable );

			my $target = {};
			if ( $healthIndexTable = $SNMP->gettable($index_snmp) )
			{
				# dbg("systemHealth: table is ".Dumper($healthIndexTable) );
				foreach my $oid ( oid_lex_sort( keys %{$healthIndexTable} ) )
				{
					my $index = $oid;
					if ( $oid =~ /$index_regex/ )
					{
						$index = $1;
					}
					$healthIndexNum{$index} = $index;
					dbg("section=$section index=$index is found, value=$healthIndexTable->{$oid}");
					$target->{$index_var} = $healthIndexTable->{$oid};

					# $NI->{$section}->{$index}->{$index_var} = $healthIndexTable->{$oid};
				}
			}
			else
			{
				if ( $SNMP->error =~ /is empty or does not exist/ )
				{
					info( "SNMP Object Not Present ($S->{name}) on get systemHealth $section index table: "
							. $SNMP->error );
				}
				else
				{
					logMsg( "ERROR ($S->{name}) on get systemHealth $section index table: " . $SNMP->error );
					HandleNodeDown(
						sys     => $S,
						type    => "snmp",
						details => "get systemHealth $section index table: " . $SNMP->error
					);
				}
			}

			# Loop to get information, will be stored in {info}{$section} table
			foreach my $index ( sort keys %healthIndexNum )
			{
				# Inventory note: for now Sys will populate the nodeinfo section it cares about
				# afer successful load we'll delete it. in the future loadinfo should maybe be passed
				# the location we want the data to go
				if ($S->loadInfo(
						class   => 'systemHealth',
						section => $section,
						index   => $index,
						table   => $section,
						model   => $model,
						target  => $target
					)
					)
				{
					info("section=$section index=$index read and stored");

					# get the inventory object for this, path_keys required as we don't know what type it will be
					NMISNG::Util::TODO("Do we use index or the healthIndextTable value that the loop above grabbed?");
		
					# $index_var is correct but the loading side in S->inventory doesn't know what the key will be in data
					# so use 'index' for now.
					# loadInfo always sets {index}, sadly it doesn't always come out of loadInfo correct so do it again
					$target->{index} = $target->{$index_var};
					# my $path_keys = [$index_var];
					my $path_keys = ['index'];
					my $path = $nmisng_node->inventory_path( concept => $section, data => $target, path_keys => $path_keys );

					# NOTE: systemHealth requires {index} => $index to be set, it
					my ( $inventory, $error_message ) = $nmisng_node->inventory(
						concept   => $section,
						data      => $target,
						path      => $path,
						path_keys => $path_keys,
						create    => 1
					);
					$nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$inventory->path( recalculate => 1 );
					$inventory->historic(0);

					# the above will put data into inventory, so save
					my ( $op, $error ) = $inventory->save();
					info( "saved ".join(',', @$path)." op: $op");
					$nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{snmp_error};
					logMsg("ERROR ($S->{name}) on get systemHealth $section index $index: $error");
					HandleNodeDown(
						sys     => $S,
						type    => "snmp",
						details => "get systemHealth $section index $index: $error"
					);
				}
			}
		}
	}
	info("Finished");
	return 1;
}

# retrieves system health rrd data, and updates relevant rrd database files
# args: sys (object)
# returns: 1 if all ok, 0 otherwise
sub getSystemHealthData
{
	my %args = @_;
	my $S    = $args{sys};    # object

	my $NI = $S->ndinfo;      # node info table
	my $V  = $S->view;
	my $M  = $S->mdl;         # node model table

	my $C = loadConfTable();

	# create the node here for now, this should be passed in as a param in the future
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	info("Starting");
	info("Get systemHealth Data of node $catchall_data->{name}, model $catchall_data->{nodeModel}");

	if ( !exists( $M->{systemHealth} ) )
	{
		dbg("No class 'systemHealth' declared in Model");
		return 1;    # nothing there means all ok
	}

	# config sets default sections, model overrides
	my @healthSections = split( ",", defined( $M->{systemHealth}{sections} )
		? $M->{systemHealth}{sections}
		: $C->{model_health_sections} );

	for my $section (@healthSections)
	{
		my $ids = $nmisng_node->get_inventory_ids( concept => $section );

		# node doesn't have info for this section, so no indices so no fetch,
		# may be no update yet or unsupported section for this model anyway
		# OR only sys section but no rrd (e.g. addresstable)
		next
			if ( @$ids < 1
			or !exists( $M->{systemHealth}->{rrd} )
			or ref( $M->{systemHealth}->{rrd}->{$section} ) ne "HASH" );

		my $thissection = $M->{systemHealth}{sys}{$section};
		my $index_var   = $thissection->{indexed};

		# that's instance index value
		foreach my $id (@$ids)
		{
			my ( $inventory, $error ) = $nmisng_node->inventory( _id => $id );
			$nmisng_node->nmisng->log->error("Failed to get inventory with id:$id, error:$error") && next if ( !$inventory );

			my $data = $inventory->data();

			# sanity check the data
			if (   ref($data) ne "HASH"
				or !keys %$data
				or !exists( $data->{index} ) )
			{
				my $index = $data->{index} // 'noindex';
				logMsg(
					"ERROR invalid data for section $section and index $index, cannot collect systemHealth data for this index!"
				);
				info(
					"ERROR invalid data for section $section and index $index, cannot collect systemHealth data for this index!"
				);

				# clean it up as well, it's utterly broken as it is.
				$inventory->delete();
				next;
			}

			# value should be in $index_var, loadInfo also puts it in {index} so fall back to that
			my $index = $data->{$index_var} // $data->{index};

			my $rrdData = $S->getData( class => 'systemHealth', section => $section, index => $index, debug => $model );
			my $howdiditgo = $S->status;
			my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

			# were there any errors?
			if ( !$anyerror )
			{
				my $count = 0;
				foreach my $sect ( keys %{$rrdData} )
				{
					my $D = $rrdData->{$sect}->{$index};

					# update retrieved values in node info, too, not just the rrd database
					for my $item ( keys %$D )
					{
						++$count;
						dbg(      "updating node info $section $index $item: old "
								. $data->{$item}
								. " new $D->{$item}{value}" );
						$data->{$item} = $D->{$item}{value};
					}

					# RRD Database update and remember filename;
					# also feed in the section data for filename expansion
					my $db = $S->create_update_rrd( data   => $D,
																					type   => $sect,
																					index  => $index,
																					extras => $data );
					if ( !$db )
					{
						logMsg( "ERROR updateRRD failed: " . getRRDerror() );
					}
				}
				info("section=$section index=$index read and stored $count values");
				# technically the path shouldn't change during collect so for now don't recalculate path
				# put the new values into the inventory and save
				$inventory->data($data);
				$inventory->save();				
			}
			else
			{
				logMsg("ERROR ($catchall_data->{name}) on getSystemHealthData, $section, $index, $anyerror");
				info("ERROR ($catchall_data->{name}) on getSystemHealthData, $section, $index, $anyerror");
				HandleNodeDown( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
					if ( $howdiditgo->{snmp_error} );
				HandleNodeDown( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
					if ( $howdiditgo->{wmi_error} );

				return 0;
			}
		}
	}
	info("Finished");
	return 1;
}

# updates the node info and node view structures with all kinds of stuff
# this is run ONLY for collect type ops (and if runping succeeded, and if the node is marked for collect)
# fixme: what good is this as a function? details are lost, exit 1/0 is not really enough
#
# returns: 1 if node is up, and at least one source worked for retrieval; 0 if node is down/to be skipped etc.
sub updateNodeInfo
{
	my %args = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;
	my $V    = $S->view;
	my $RI   = $S->reach;
	my $NC   = $S->ndcfg;    # node config
	my $M    = $S->mdl;
	my $result;
	my $exit = 1;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	info("Starting Update Node Info, node $S->{name}");

	# clear the node reset indication from the last run
	$catchall_data->{node_was_reset} = 0;

	# save what we need now for check of this node
	my $sysObjectID  = $catchall_data->{sysObjectID};
	my $ifNumber     = $catchall_data->{ifNumber};
	my $sysUpTimeSec = $catchall_data->{sysUpTimeSec};
	my $sysUpTime    = $catchall_data->{sysUpTime};

	# this returns 0 iff none of the possible/configured sources worked, sets details
	my $loadsuccess = $S->loadInfo( class => 'system', model => $model, target => $catchall_data );

	# handle dead sources, raise appropriate events
	my $curstate = $S->status;
	for my $source (qw(snmp wmi))
	{
		# ok if enabled and no errors
		if ( $curstate->{"${source}_enabled"} && !$curstate->{"${source}_error"} )
		{
			my $sourcename = uc($source);
			$RI->{"${source}result"} = 100;
			HandleNodeDown( sys => $S, type => $source, up => 1, details => "$sourcename ok" );
		}

		# not ok if enabled and error
		elsif ( $curstate->{"${source}_enabled"} && $curstate->{"${source}_error"} )
		{
			HandleNodeDown( sys => $S, type => $source, details => $curstate->{"${source}_error"} );
			$RI->{"${source}result"} = 0;
		}

		# don't care about nonenabled sources, sys won't touch them nor set errors, RI stays whatever it was
	}

	if ($loadsuccess)
	{
		# do some checks, and perform only an update-type op if they don't work out
		# however, ensure this is not attempted if snmp wasn't configured or didn't work anyway
		if (   $S->status->{snmp_enabled}
			&& !$S->status->{snmp_error}
			&& $sysObjectID ne $catchall_data->{sysObjectID} )
		{
			# fixme: who not a complete doUpdate?
			logMsg("INFO ($catchall_data->{name}) Device type/model changed $sysObjectID now $catchall_data->{sysObjectID}");
			$exit = getNodeInfo( sys => $S );
			info("Finished with exit=$exit");
			return $exit;
		}

		# if ifNumber has changed, then likely an interface has been added or removed.

		# a new control to minimise when interfaces are added,
		# if disabled {custom}{interface}{ifNumber} eq "false" then don't run getIntfInfo when intf changes
		my $doIfNumberCheck = (
			exists( $S->{mdl}->{custom} ) && exists( $S->{mdl}->{custom}->{interface} )    # do not autovivify
				&& !getbool( $S->{mdl}->{custom}->{interface}->{ifNumber} )
		);

		if ( $doIfNumberCheck and $ifNumber != $catchall_data->{ifNumber} )
		{
			logMsg(
				"INFO ($catchall_data->{name}) Number of interfaces changed from $ifNumber now $catchall_data->{ifNumber}");
			getIntfInfo( sys => $S );                                                      # get new interface table
		}

		my $interface_max_number = $C->{interface_max_number} ? $C->{interface_max_number} : 5000;
		if ( $ifNumber > $interface_max_number )
		{
			info(
				"INFO ($catchall_data->{name}) has $ifNumber interfaces, no interface data will be collected, to collect interface data increase the configured interface_max_number $interface_max_number, we recommend to test thoroughly"
			);
		}

		# make a sysuptime from the newly loaded data for testing
		makesysuptime($S);

		if ( defined $catchall_data->{snmpUpTime} )
		{
			# add processing for SNMP Uptime- handle just like sysUpTime
			$catchall_data->{snmpUpTimeSec}   = int( $catchall_data->{snmpUpTime} / 100 );
			$catchall_data->{snmpUpTime}      = convUpTime( $catchall_data->{snmpUpTimeSec} );
			$V->{system}{snmpUpTime_value} = $catchall_data->{snmpUpTime};
			$V->{system}{snmpUpTime_title} = 'SNMP Uptime';
		}

		info("sysUpTime: Old=$sysUpTime New=$catchall_data->{sysUpTime}");
		if ( $catchall_data->{sysUpTimeSec} && $sysUpTimeSec > $catchall_data->{sysUpTimeSec} )
		{
			info("NODE RESET: Old sysUpTime=$sysUpTimeSec New sysUpTime=$catchall_data->{sysUpTimeSec}");
			notify(
				sys     => $S,
				event   => "Node Reset",
				element => "",
				details => "Old_sysUpTime=$sysUpTime New_sysUpTime=$catchall_data->{sysUpTime}",
				context => {type => "node"}
			);

			# now stash this info in the node info object, to ensure we insert one set of U's into the rrds
			# so that no spikes appear in the graphs
			$catchall_data->{node_was_reset} = 1;
		}

		$V->{system}{sysUpTime_value} = $catchall_data->{sysUpTime};
		$V->{system}{sysUpTime_title} = 'Uptime';

		$V->{system}{lastUpdate_value} = returnDateStamp();
		$V->{system}{lastUpdate_title} = 'Last Update';
		$catchall_data->{lastUpdateSec}   = time();

		# get and apply any nodeconf override if such exists for this node
		my $node = $catchall_data->{name};
		my ( $errmsg, $override ) = get_nodeconf( node => $node )
			if ( has_nodeconf( node => $node ) );
		logMsg("ERROR $errmsg") if $errmsg;
		$override ||= {};

		# anything to override?
		if ( $override->{sysLocation} )
		{
			$NI->{nodeconf}{sysLocation} = $catchall_data->{sysLocation};
			$catchall_data->{sysLocation} = $V->{system}{sysLocation_value} = $override->{sysLocation};
			info("Manual update of sysLocation by nodeConf");
		}
		if ( $override->{sysContact} )
		{
			$NI->{nodeconf}{sysContact} = $catchall_data->{sysContact};
			$catchall_data->{sysContact} = $V->{system}{sysContact_value} = $override->{sysContact};
			info("Manual update of sysContact by nodeConf");
		}

		if ( $override->{nodeType} )
		{
			$catchall_data->{nodeType} = $NI->{nodeconf}->{nodeType} = $override->{nodeType};
		}
		else
		{
			delete $NI->{nodeconf}->{nodeType};
		}

		checkPIX( sys => $S );    # check firewall if needed
		delete $NI->{database};   # no longer used at all

		$V->{system}{status_value} = 'reachable';    # sort-of, at least one source worked
		$V->{system}{status_color} = '#0F0';

		# conditional on model section to ensure backwards compatibility with different Juniper values.
		checkNodeConfiguration( sys => $S )
			if ( exists( $M->{system}{sys}{nodeConfiguration} )
			or exists( $M->{system}{sys}{juniperConfiguration} ) );
	}
	else
	{
		$exit = 0;

		if ( getbool( $NC->{node}{ping} ) )
		{
			# ping was ok but wmi and snmp were not
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		}
		else
		{
			# ping was disabled, so sources wmi/snmp are the only thing that tells us about reachability
			# note: ping disabled != runping failed
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	# some model testing and debugging options.
	if ($model)
	{
		print
			"MODEL $S->{name}: nodedown=$catchall_data->{nodedown} sysUpTime=$catchall_data->{sysUpTime} sysObjectID=$catchall_data->{sysObjectID}\n";
	}

	info("Finished with exit=$exit");
	return $exit;
}

# goes through the list of 'parked' alerts in sys, and creates up or down events where applicable
# sys::getvalues() populates the parked alerts section, this consumes them (but writes back
# into sys' info->status)
sub processAlerts
{
	my %args   = @_;
	my $S      = $args{S};
	my $alerts = $S->{alerts};
	my $info   = $S->ndinfo;

	foreach my $alert ( @{$alerts} )
	{
		info(
			"Processing alert: event=Alert: $alert->{event}, level=$alert->{level}, element=$alert->{ds}, details=Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}"
		) if $alert->{test_result};

		dbg( "Processing alert " . Dumper($alert), 4 );

		my $tresult      = $alert->{test_result} ? $alert->{level} : "Normal";
		my $statusResult = $tresult eq "Normal"  ? "ok"            : "error";

		my $details = "$alert->{type} evaluated with $alert->{value} $alert->{unit} as $tresult";
		if ( $alert->{test_result} )
		{
			notify(
				sys     => $S,
				event   => "Alert: " . $alert->{event},
				level   => $alert->{level},
				element => $alert->{ds},                  # vital part of context, too
				details => $details,
				context => {
					type    => "alert",
					source  => $alert->{source},
					section => $alert->{section},
					name    => $alert->{alert},
					index   => $alert->{index},
				}
			);
		}
		else
		{
			checkEvent(
				sys     => $S,
				event   => "Alert: " . $alert->{event},
				level   => $alert->{level},
				element => $alert->{ds},
				details => $details
			);
		}

		### save the Alert result into the Status thingy
		my $statusKey = "$alert->{event}--$alert->{ds}";
		$info->{status}->{$statusKey} = {
			method   => "Alert",
			type     => $alert->{type},
			property => $alert->{test},
			event    => $alert->{event},
			index    => undef,             #$args{index},
			level    => $tresult,
			status   => $statusResult,
			element  => $alert->{ds},
			value    => $alert->{value},
			updated  => time()
		};
	}
}

#=========================================================================================

# get node values by snmp and store in RRD and some values in reach table
#
sub getNodeData
{
	my %args = @_;
	my $S    = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();	

	info("Starting Node get data, node $S->{name}");

	my $rrdData    = $S->getData( class => 'system', model => $model );
	my $howdiditgo = $S->status;
	my $anyerror   = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

	if ( !$anyerror )
	{
		processAlerts( S => $S );
		foreach my $sect ( keys %{$rrdData} )
		{
			my $D = $rrdData->{$sect};
			checkNodeHealth( sys => $S, data => $D ) if $sect eq "nodehealth";

			foreach my $ds ( keys %{$D} )
			{
				dbg( "rrdData, section=$sect, ds=$ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}", 2 );
			}
			my $db = $S->create_update_rrd( data => $D, type => $sect );
			if ( !$db )
			{
				logMsg( "ERROR updateRRD failed: " . getRRDerror() );
			}
		}
	}
	else
	{
		logMsg("ERROR ($catchall_data->{name}) on getNodeData, $anyerror");
		HandleNodeDown( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
			if ( $howdiditgo->{snmp_error} );
		HandleNodeDown( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} ) if ( $howdiditgo->{wmi_error} );
		return 0;
	}

	info("Finished");
	return 1;
}

#=========================================================================================

# copy/modify some health values collected by getNodeData
# nmisdev 13Oct2012 - check if hash key is present before testing value, else key will 'auto vivify', and cause DS errors
sub checkNodeHealth
{
	my %args = @_;
	my $S    = $args{sys};
	my $D    = $args{data};
	my $RI   = $S->reach;

	info("Starting, node $S->{name}");

	# take care of negative values from 6509 MSCF
	if ( exists $D->{bufferElHit} and $D->{bufferElHit}{value} < 0 )
	{
		$D->{bufferElHit}{value} = sprintf( "%u", $D->{bufferElHit}{value} );
	}

	### 2012-12-13 keiths, fixed this so it would assign!
	### 2013-04-17 keiths, fixed an autovivification problem!
	if ( exists $D->{avgBusy5} or exists $D->{avgBusy1} )
	{
		$RI->{cpu} = ( $D->{avgBusy5}{value} ne "" ) ? $D->{avgBusy5}{value} : $D->{avgBusy1}{value};
	}
	if ( exists $D->{MemoryUsedPROC} )
	{
		$RI->{memused} = $D->{MemoryUsedPROC}{value};
	}
	if ( exists $D->{MemoryFreePROC} )
	{
		$RI->{memfree} = $D->{MemoryFreePROC}{value};
	}
	info("Finished");
	return 1;
}    # end checkHealth

#=========================================================================================

# fixme: this function currently does not work for wmi-only nodes!
sub getIntfData
{
	my %args = @_;
	my $S    = $args{sys};

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getIntfData for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $V    = $S->view;
	my $IF   = $S->ifinfo;    # interface info
	my $RI   = $S->reach;
	my $SNMP = $S->snmp;
	my $IFCACHE;

	my $C = loadConfTable();

	# get any nodeconf overrides if such exists for this node
	my $nodename = $S->{name};
	my ( $errmsg, $override ) = get_nodeconf( node => $nodename )
		if ( has_nodeconf( node => $nodename ) );
	logMsg("ERROR $errmsg") if $errmsg;
	$override ||= {};

	# load the node here for now, this should be passed in as a param in the future
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;

	my $createdone = "false";

	info("Starting Interface get data, node $S->{name}");

	$RI->{intfUp} = $RI->{intfColUp} = 0;    # reset counters of interface Up and interface collected Up

	# find all id's that are needed for the first section of searching
	my $model_data = $nmisng->get_inventory_model(
		'concept' => 'interface',
		'cluster_id' => $nmisng_node->cluster_id,
		'node_uuid' => $nmisng_node->uuid,
		fields_hash => {
			'_id' => 1,
			'data.collect' => 1,
			'data.ifAdminStatus' => 1,
			'data.ifDescr' => 1,
			'data.ifIndex' => 1,
			'data.ifLastChange' => 1,
		}
	);

	my $data = $model_data->data();
	# create a map by ifindex so we can look them up easily, flatten _id into data to make things easier
	my %if_data_map = map { $_->{data}{_id} = $_->{_id};$_->{data}{ifIndex} => $_->{data} } (@$data);

	# default for ifAdminStatus-based detection is ON. only off if explicitely set to false.
	if (ref( $S->{mdl}->{custom} ) ne "HASH"    # don't autovivify
		or ref( $S->{mdl}{custom}->{interface} ) ne "HASH"
		or !getbool( $S->{mdl}->{custom}->{interface}->{ifAdminStatus}, "invert" )
		)
	{
		# fixme: this cannot work for non-snmp nodes
		info("Using ifAdminStatus and ifOperStatus for Interface Change Detection");

		my ( $ifAdminTable, $ifOperTable );

		if ( $ifAdminTable = $SNMP->getindex('ifAdminStatus') )
		{
			$ifOperTable = $SNMP->getindex('ifOperStatus');
			for my $index ( keys %{$ifAdminTable} )
			{
				logMsg("INFO ($S->{name}) entry ifAdminStatus for index=$index not found in interface table")
					if( !exists $if_data_map{$index}->{ifAdminStatus} );

				if ( ( $ifAdminTable->{$index} == 1 and $if_data_map{$index}->{ifAdminStatus} ne 'up' )
					or ( $ifAdminTable->{$index} != 1 and $if_data_map{$index}->{ifAdminStatus} eq 'up' ) )
				{
					### logMsg("INFO ($S->{name}) ifIndex=$index, Admin was $IF->{$index}{ifAdminStatus} now $ifAdminTable->{$index} (1=up) rebuild");
					getIntfInfo( sys => $S, index => $index );    # update this interface
				}

				# total number of interfaces up
				$RI->{intfUp}++
					if $ifOperTable->{$index} == 1
					and getbool( $IF->{$index}{real} );
			}
		}
	}

	# so get the ifLastChange for each interface and see if it has changed, if it has then run an update.
	# if an interface is added this will find it to.
	# if it changes admin or oper state it will find it.
	# this can be enabled on a model by model basis is false by default.
	if (    ref( $S->{mdl}{custom} ) eq "HASH"
		and ref( $S->{mdl}{custom}{interface} ) eq "HASH"
		and getbool( $S->{mdl}{custom}{interface}{ifLastChange} ) )
	{
		# fixme: this cannot work for non-snmp node
		info("Using ifLastChange for Interface Change Detection");
		my $ifLastChangeTable;
		if ( $ifLastChangeTable = $SNMP->getindex('ifLastChange') )
		{
			for my $index ( sort { $a <=> $b } ( keys %{$ifLastChangeTable} ) )
			{
				my $ifLastChangeSec = int( $ifLastChangeTable->{$index} / 100 );
				if( exists($if_data_map{$index}) && $ifLastChangeSec == $if_data_map{$index}->{ifLastChange} )
				{
					info("$IF->{$index}{ifDescr}: NO Change ifIndex=$index ifLastChangeSec=$ifLastChangeSec");
				}
				else
				{
					info("New Interface: ifIndex=$index ifLastChangeSec=$ifLastChangeSec") if( !exists($if_data_map{$index}) );
					info("$IF->{$index}{ifDescr}: Changed ifLastChangeSec=$ifLastChangeSec, was=$IF->{$index}{ifLastChangeSec}")
						if($ifLastChangeSec != $if_data_map{$index}->{ifLastChangeSec}); # don't care about vivify here
					getIntfInfo( sys => $S, index => $index );    # add/update this interface
					# $IF->{$index}{ifLastChangeSec} = $ifLastChangeSec; # the update should do this automatically
				}
			}
		}
		# check for deleted interfaces
		foreach my $index ( sort { $a <=> $b } keys %if_data_map )
		{
			if ( not exists $ifLastChangeTable->{$index} )
			{
				my $data = $if_data_map{$index};
				info("$data->{ifDescr}: Interface Removed ifIndex=$index");
				my ($inventory,$error_message) = $nmisng_node->inventory(_id => $data->{_id});
			}
		}
	}

	info("Processing Interface Table");
	foreach my $index ( sort { $a <=> $b } keys %if_data_map )
	{
		# load up the full inventory object here because the data data may have been updated above
		# eventually this could be done only if it's updated
		my $_id = $if_data_map{$index}->{_id};
		my ($inventory,$error_message) = $nmisng_node->inventory( _id =>  $_id );
		$nmisng->log->error("Failed to get interface inventory, index $index, _id:$_id, error_message:$error_message") && next if(!$inventory);
		# replace minimal data with all data known
		my $inventory_data = $inventory->data();

		# only collect on interfaces that are defined, with collection turned on globally,
		# also don't bother with ones without ifdescr
		if ( !getbool( $inventory_data->{collect} )	or !defined( $inventory_data->{ifDescr} )	or $inventory_data->{ifDescr} eq "" )
		{
			dbg("NOT Collected: $IF->{$index}{ifDescr}: ifIndex=$IF->{$index}{ifIndex}, OperStatus=$IF->{$index}{ifOperStatus}, ifAdminStatus=$IF->{$index}{ifAdminStatus}, Interface Collect=$IF->{$index}{collect}"
			);
			next;
		}



		info(
			"$inventory_data->{ifDescr}: ifIndex=$inventory_data->{ifIndex}, was => OperStatus=$inventory_data->{ifOperStatus}, ifAdminStatus=$inventory_data->{ifAdminStatus}, Collect=$inventory_data->{collect}"
		);

		dbg("collect interface index=$index");

		# this is safe from using {info}{interface}, uses graphtype data a lot
		my $rrdData    = $S->getData( class => 'interface', index => $index, model => $model );
		my $howdiditgo = $S->status;
		my $anyerror   = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

		# were there any errors?
		if ( !$anyerror )
		{
			processAlerts( S => $S );

			foreach my $sect ( keys %{$rrdData} )
			{
				my $D = $rrdData->{$sect}{$index};

				# if HC exists then copy values
				if ( exists $D->{ifHCInOctets} )
				{
					dbg("processing HC counters");
					for ( ["ifHCInOctets", "ifInOctets"], ["ifHCOutOctets", "ifOutOctets"] )
					{
						my ( $source, $dest ) = @$_;

						if ( $D->{$source}->{value} =~ /^\d+$/ )
						{
							$D->{$dest}->{value}  = $D->{$source}->{value};
							$D->{$dest}->{option} = $D->{$source}->{option};
						}
						delete $D->{$source};
					}
				}

				# ...and copy these over as well
				if ( $sect eq 'pkts' or $sect eq 'pkts_hc' )
				{
					my $debugdone = 0;

					for (
						["ifHCInUcastPkts",  "ifInUcastPkts"],
						["ifHCOutUcastPkts", "ifOutUcastPkts"],
						["ifHCInMcastPkts",  "ifInMcastPkts"],
						["ifHCOutMcastPkts", "ifOutMcastPkts"],
						["ifHCInBcastPkts",  "ifInBcastPkts"],
						["ifHCOutBcastPkts", "ifOutBcastPkts"],
						)
					{
						my ( $source, $dest ) = @$_;

						if ( $D->{$source}->{value} =~ /^\d+$/ )
						{
							dbg("process HC counters of $sect") if ( !$debugdone++ );
							$D->{$dest}->{value}  = $D->{$source}->{value};
							$D->{$dest}->{option} = $D->{$source}->{option};
						}
						delete $D->{$source};
					}
				}

				if ( $sect eq 'interface' )
				{
					$D->{ifDescr}{value} = rmBadChars( $D->{ifDescr}{value} );

					# Cache any data for use later.
					$IFCACHE->{$index}{ifAdminStatus} = $D->{ifAdminStatus}{value};
					$IFCACHE->{$index}{ifOperStatus}  = $D->{ifOperStatus}{value};

					if ( $D->{ifInOctets}{value} ne "" and $D->{ifOutOctets}{value} ne "" )
					{
						if ( defined $S->{mdl}{custom}{interface}{ifAdminStatus}
							and not getbool( $S->{mdl}{custom}{interface}{ifAdminStatus} ) )
						{
							### 2014-03-14 keiths, special handling for manual interface discovery which does not use getIntfInfo.
							# interface now up or down, check and set or clear outstanding event.
							dbg("handling up/down admin=$D->{ifAdminStatus}{value}, oper=$D->{ifOperStatus}{value} was admin=$IF->{$index}{ifAdminStatus}, oper=$IF->{$index}{ifOperStatus}"
							);
							$inventory_data->{ifAdminStatus} = $D->{ifAdminStatus}{value};
							$inventory_data->{ifOperStatus}  = $D->{ifOperStatus}{value};

							# checking for collect here is pointless, we already know it's on or we wouldn't be here!
							if (    getbool( $inventory_data->{collect} )
								and $inventory_data->{ifAdminStatus} =~ /up|ok/
								and $inventory_data->{ifOperStatus} !~ /up|ok|dormant/ )
							{
								if ( getbool( $inventory_data->{event} ) )
								{
									notify(
										sys     => $S,
										event   => "Interface Down",
										element => $inventory_data->{ifDescr},
										details => $inventory_data->{Description},
										context => {type => "interface"}
									);
								}
							}
							else
							{
								checkEvent(
									sys     => $S,
									event   => "Interface Down",
									level   => "Normal",
									element => $inventory_data->{ifDescr},
									details => $inventory_data->{Description}
								);
							}
						}
						else
						{
							dbg("status now admin=$D->{ifAdminStatus}{value}, oper=$D->{ifOperStatus}{value} was admin=$IF->{$index}{ifAdminStatus}, oper=$IF->{$index}{ifOperStatus}"
							);
							if ( $D->{ifOperStatus}{value} eq 'down' )
							{
								if ( $inventory_data->{ifOperStatus} =~ /up|ok/ )
								{
									# going down
									getIntfInfo( sys => $S, index => $index );    # update this interface
								}
							}

							# must be up
							else
							{
								# Check if the status changed
								if ( $inventory_data->{ifOperStatus} !~ /up|ok|dormant/ )
								{
									# going up
									getIntfInfo( sys => $S, index => $index );    # update this interface
								}
							}
						}

						# If new ifDescr is different from old ifDescr rebuild interface info table
						# check if nodeConf modified this inteface
						my $node    = $S->{name};
						my $ifDescr = $inventory_data->{ifDescr};

						# nodeconf override for the ifDescr?
						my $have_overridden_ifdescr;
						$have_overridden_ifdescr = 1
							if ( ref( $override->{$ifDescr} ) eq "HASH"
							and $override->{$ifDescr}->{ifDescr} );

						if (   !$have_overridden_ifdescr
							and $D->{ifDescr}{value} ne ''
							and $D->{ifDescr}{value} ne $inventory_data->{ifDescr} )
						{
							# Reload the interface config won't get that one right but should get the next one right
							logMsg(
								"INFO ($S->{name}) ifIndex=$index - ifDescr has changed - old=$inventory_data->{ifDescr} new=$D->{ifDescr}{value} - updating Interface Table"
							);
							getIntfInfo( sys => $S, index => $index );    # update this interface
						}

						delete $D->{ifDescr};                             # dont store in rrd
						delete $D->{ifAdminStatus};

						if ( exists $D->{ifLastChange}{value} )
						{
							# convert time integer to time string
							$V->{interface}{"${index}_ifLastChange_value"} = $inventory_data->{ifLastChange}
								= convUpTime( $inventory_data->{ifLastChangeSec} = int( $D->{ifLastChange}{value} / 100 ) );
							dbg("last change time=$inventory_data->{ifLastChange}, timesec=$inventory_data->{ifLastChangeSec}");
						}
						delete $D->{ifLastChange};

						my $operStatus;

						# Calculate Operational Status
						$operStatus = ( $D->{ifOperStatus}{value} =~ /up|ok|dormant/ ) ? 100 : 0;
						$D->{ifOperStatus}{value} = $operStatus;    # store real value in rrd

						# While updating start calculating the total availability of the node, depends on events set
						my $opstatus = getbool( $inventory_data->{event} ) ? $operStatus : 100;
						$RI->{operStatus} = $RI->{operStatus} + $opstatus;
						$RI->{operCount}  = $RI->{operCount} + 1;

						# count total number of collected interfaces up ( if events are set on)
						$RI->{intfColUp} += $operStatus / 100
							if getbool( $inventory_data->{event} );
					}
					else
					{
						logMsg("ERROR ($S->{name}) ifIndex=$index, no values for ifInOctets and ifOutOctets received");
					}
				}

				if ( $C->{debug} )
				{
					foreach my $ds ( keys %{$D} )
					{
						dbg( "rrdData section $sect, ds $ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}", 2 );
					}
				}

				# RRD Database update and remember filename
				info( "updateRRD type$sect index=$index", 2 );
				my $db = $S->create_update_rrd( data => $D, type => $sect, index => $index );
				if ( !$db )
				{
					logMsg( "ERROR updateRRD failed: " . getRRDerror() );
				}
			}

			# calculate summary statistics of this interface only if intf up
			my $period = $C->{interface_util_period} || "-6 hours";    # bsts plus backwards compat
			my $util
				= getSummaryStats( sys => $S, type => "interface", start => $period, end => time, index => $index );
			$V->{interface}{"${index}_operAvail_value"} = $util->{$index}{availability};
			$V->{interface}{"${index}_totalUtil_value"} = $util->{$index}{totalUtil};
			$V->{interface}{"${index}_operAvail_color"} = colorHighGood( $util->{$index}{availability} );
			$V->{interface}{"${index}_totalUtil_color"} = colorLowGood( $util->{$index}{totalUtil} );

			if ( defined $S->{mdl}{custom}{interface}{ifAdminStatus}
				and getbool( $S->{mdl}{custom}{interface}{ifAdminStatus}, "invert" ) )
			{
				dbg("Updating view with ifAdminStatus=$IFCACHE->{$index}{ifAdminStatus} and ifOperStatus=$IFCACHE->{$index}{ifOperStatus}"
				);
				$V->{interface}{"${index}_ifAdminStatus_color"} = getAdminColor(
					collect       => $inventory_data->{collect},
					ifAdminStatus => $IFCACHE->{$index}{ifAdminStatus},
					ifOperStatus  => $IFCACHE->{$index}{ifOperStatus}
				);
				$V->{interface}{"${index}_ifOperStatus_color"} = getOperColor(
					collect       => $inventory_data->{collect},
					ifAdminStatus => $IFCACHE->{$index}{ifAdminStatus},
					ifOperStatus  => $IFCACHE->{$index}{ifOperStatus}
				);
				$V->{interface}{"${index}_ifAdminStatus_value"} = $IFCACHE->{$index}{ifAdminStatus};
				$V->{interface}{"${index}_ifOperStatus_value"}  = $IFCACHE->{$index}{ifOperStatus};
			}

			### 2012-08-14 keiths, logic here to verify an event exists and the interface is up.
			### this was causing events to be cleared when interfaces were collect true, oper=down, admin=up
			if ( eventExist( $node, "Interface Down", $inventory_data->{ifDescr} )
				and $inventory_data->{ifOperStatus} =~ /up|ok|dormant/ )
			{
				checkEvent(
					sys     => $S,
					event   => "Interface Down",
					level   => "Normal",
					element => $inventory_data->{ifDescr},
					details => $inventory_data->{Description}
				);
			}
		}
		else
		{
			logMsg("ERROR ($S->{name}) on getIntfData of interface=$index, $anyerror");

			$V->{interface}{"${index}_operAvail_value"} = 'N/A';
			$V->{interface}{"${index}_totalUtil_value"} = 'N/A';

			# interface problems but no usable data, don't make an event
			if ( getbool( $inventory_data->{event} ) )
			{
				logMsg(
					"ERROR: Interface SNMP Data: ifAdminStatus=$inventory_data->{ifAdminStatus} ifOperStatus=$inventory_data->{ifOperStatus} collect=$inventory_data->{collect}"
				);
			}
		}

		# header info of web page
		$V->{interface}{"${index}_operAvail_title"} = 'Intf. Avail.';
		$V->{interface}{"${index}_totalUtil_title"} = $C->{interface_util_label} || 'Util. 6hrs';    # backwards compat

		# check escalation if event is on
		if ( getbool( $inventory_data->{event} ) )
		{
			my $escalate = 'none';
			if ( my $event_exist = eventExist( $S->{node}, "Interface Down", $inventory_data->{ifDescr} ) )
			{
				my $erec = eventLoad( filename => $event_exist );
				$escalate = $erec->{escalate} if ( $erec and defined( $erec->{escalate} ) );
			}
			$V->{interface}{"${index}_escalate_title"} = 'Esc.';
			$V->{interface}{"${index}_escalate_value"} = $escalate;
		}
		# don't recalculate path, that should happen in update, any place where we find
		# the interface has changed enough runs update code anyway. I believe not doing this is correct
		$inventory->data( $inventory_data );
		$inventory->save();
	}
	info("Finished");
}

### Class Based Qos handling
sub getCBQoS
{
	my %args = @_;
	my $S    = $args{sys};
	my $NC   = $S->ndcfg;

	if ( $NC->{node}{cbqos} !~ /true|input|output|both/ )
	{
		info("no collecting ($NC->{node}{cbqos}) for node $S->{name}");
		return;
	}

	info("Starting for node $S->{name}");

	## oke,lets go
	if ( getbool( $S->{update} ) )    # fixme unclean access to internal property
	{
		getCBQoSwalk( sys => $S );    # get indexes
	}
	elsif ( !getCBQoSdata( sys => $S ) )
	{
		getCBQoSwalk( sys => $S );    # get indexes
		getCBQoSdata( sys => $S );    # get data
	}

	info("Finished");

	return 1;
}

# note that while this function could work with wmi,
# the priming/update function getCBQoSwalk doesn't.
sub getCBQoSdata
{
	my (%args)  = @_;
	my $S     = $args{sys};	
	
	foreach my $direction ( "in", "out" )
	{
		my $ids = $S->nmisng_node->get_inventory_ids(concept => "cbqos-$direction");
		return 1 if ( !$ids || @$ids < 1 ); #nothing to be done

		# oke, we have get now the PolicyIndex and ObjectsIndex directly
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $S->nmisng_node->inventory( _id => $id );
			$S->nmisng->log->error("Failed to get inventory for id:$id, concept:cbqos-$direction, error_message:$error_message") && next
				if(!$inventory);

			# note, this is not saved because it doesn't appear to be changed, 
			my $data = $inventory->data();
			# for now ifIndex is stored in the index attribute
			my $intf = $data->{index};
			my $CB = $data;

			next if ( !exists $CB->{'PolicyMap'}{'Name'} );

			# check if Policymap name contains no collect info
			if ( $CB->{'PolicyMap'}{'Name'} =~ /$S->{mdl}{system}{cbqos}{nocollect}/i )
			{
				dbg("no collect for interface $intf $direction ($CB->{'Interface'}{'Descr'}) by control ($S->{mdl}{system}{cbqos}{nocollect}) at Policymap $CB->{'PolicyMap'}{'Name'}"
				);
				next;
			}

			my $PIndex = $CB->{'PolicyMap'}{'Index'};
			foreach my $key ( keys %{$CB->{'ClassMap'}} )
			{
				my $CMName = $CB->{'ClassMap'}{$key}{'Name'};
				my $OIndex = $CB->{'ClassMap'}{$key}{'Index'};
				info("Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex");

				# get the number of bytes/packets transfered and dropped
				my $port = "$PIndex.$OIndex";

				my $rrdData
					= $S->getData( class => "cbqos-$direction", index => $intf, port => $port, model => $model );
				my $howdiditgo = $S->status;
				my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

				# were there any errors?
				if ( !$anyerror )
				{
					processAlerts( S => $S );
					my $D = $rrdData->{"cbqos-$direction"}{$intf};

					if ( $D->{'PrePolicyByte'} eq "noSuchInstance" )
					{
						logMsg("ERROR mismatch of indexes in getCBQoSdata, run walk");
						return;
					}

					# oke, store the data
					dbg("bytes transfered $D->{'PrePolicyByte'}{value}, bytes dropped $D->{'DropByte'}{value}");
					dbg("packets transfered $D->{'PrePolicyPkt'}{value}, packets dropped $D->{'DropPkt'}{value}");
					dbg("packets dropped no buffer $D->{'NoBufDropPkt'}{value}");
					#
					# update RRD
					my $db = $S->create_update_rrd( data  => $D,
																					type  => "cbqos-$direction",
																					index => $intf,
																					item  => $CMName );
					if ( !$db )
					{
						logMsg( "ERROR updateRRD failed: " . getRRDerror() );
					}
				}
				else
				{
					logMsg("ERROR ($S->{name}) on getCBQoSdata, $anyerror");
					HandleNodeDown( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
						if ( $howdiditgo->{snmp_error} );
					HandleNodeDown( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
						if ( $howdiditgo->{wmi_error} );

					return 0;
				}
			}
			# I don't believe anythign has changed data/CB so no saving for now
			# $inventory->data($data);
			# $inventory->save();	
		}
		
	}
	return 1;
}

# collect cbqos overview data from snmp, for update operation
# this is expected to run AFTER getintfinfo (because that's where overrides are transferred into NI)
# fixme: this function does not work for wmi-only nodes
# args: sys
# returns: 1 if ok
sub getCBQoSwalk
{
	my (%args) = @_;
	my $S    = $args{sys};

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getCBQoSwalk for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $NC   = $S->ndcfg;
	my $SNMP = $S->snmp;

	my $message;
	my %qosIntfTable;
	my @arrOID;
	my %cbQosTable;
	my $ifIndexTable;

	# get the qos interface indexes and objects from the snmp table

	info("start table scanning");

	# read qos interface table
	if ( $ifIndexTable = $SNMP->getindex('cbQosIfIndex') )
	{
		# grab all the interface data required to run this function
		# no writing back to the IF information is done so plain models
		# are good
		my $nmisng = $S->nmisng;
		my $nmisng_node = $S->nmisng_node;
		my $model_data = $nmisng->get_inventory_model(
			'concept' => 'interface',
			'cluster_id' => $nmisng_node->cluster_id,
			'node_uuid' => $nmisng_node->uuid,
			fields_hash => {
				'_id' => 1,
				'data.collect' => 1,
				'data.ifAdminStatus' => 1,
				'data.ifDescr' => 1,
				'data.ifIndex' => 1,
				'data.ifSpeed' => 1,
				'data.ifSpeedIn' => 1,
				'data.ifSpeedOut' => 1,
				'data.setlimits' => 1
			}
		);
		# create a map by ifindex so we can look them up easily, flatten _id into data to make things easier
		my $data = $model_data->data();
		my %if_data_map = map { $_->{data}{_id} = $_->{_id};$_->{data}{ifIndex} => $_->{data} } (@$data);

		foreach my $PIndex ( keys %{$ifIndexTable} )
		{
			my $intf = $ifIndexTable->{$PIndex};    # the interface number from the snmp qos table
			info("CBQoS, scan interface $intf");
			$nmisng->log->warn("CBQoS ifIndex $intf found which is not in inventory") && next
				if( !defined($if_data_map{$intf}) );
			my $if_data = $if_data_map{$intf};

			### 2014-03-27 keiths, skipping CBQoS if not collecting data
			if ( getbool( $if_data->{collect}, "invert" ) )
			{
				dbg("Skipping CBQoS, No collect on interface $if_data->{ifDescr} ifIndex=$intf");
				next;
			}

			# oke, go
			my $answer;
			my %CMValues;
			my $direction;

			# check direction of qos with node table
			( $answer->{'cbQosPolicyDirection'} ) = $SNMP->getarray("cbQosPolicyDirection.$PIndex");
			dbg("direction of policy is $answer->{'cbQosPolicyDirection'}, Node table $NC->{node}{cbqos}");

			if (   ( $answer->{'cbQosPolicyDirection'} == 1 and $NC->{node}{cbqos} =~ /input|both/ )
				or ( $answer->{'cbQosPolicyDirection'} == 2 and $NC->{node}{cbqos} =~ /output|true|both/ ) )
			{
				# interface found with QoS input or output configured

				$direction = ( $answer->{'cbQosPolicyDirection'} == 1 ) ? "in" : "out";
				info("Interface $intf found, direction $direction, PolicyIndex $PIndex");

				my $ifSpeedIn    = $if_data->{ifSpeedIn}  ? $if_data->{ifSpeedIn}  : $if_data->{ifSpeed};
				my $ifSpeedOut   = $if_data->{ifSpeedOut} ? $if_data->{ifSpeedOut} : $if_data->{ifSpeed};
				my $inoutIfSpeed = $direction eq "in"       ? $ifSpeedIn               : $ifSpeedOut;

				# get the policy config table for this interface
				my $qosIndexTable = $SNMP->getindex("cbQosConfigIndex.$PIndex");

				if ( $C->{debug} > 5 )
				{
					print Dumper ($qosIndexTable);
				}

				# the OID will be 1.3.6.1.4.1.9.9.166.1.5.1.1.2.$PIndex.$OIndex = Gauge
			BLOCK2:
				foreach my $OIndex ( keys %{$qosIndexTable} )
				{
					# look for the Object type for each
					( $answer->{'cbQosObjectsType'} ) = $SNMP->getarray("cbQosObjectsType.$PIndex.$OIndex");
					dbg("look for object at $PIndex.$OIndex, type $answer->{'cbQosObjectsType'}");
					if ( $answer->{'cbQosObjectsType'} eq 1 )
					{
						# it's a policy-map object, is it the primairy
						( $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray("cbQosParentObjectsIndex.$PIndex.$OIndex");
						if ( $answer->{'cbQosParentObjectsIndex'} eq 0 )
						{
							# this is the primairy policy-map object, get the name
							( $answer->{'cbQosPolicyMapName'} )
								= $SNMP->getarray("cbQosPolicyMapName.$qosIndexTable->{$OIndex}");
							dbg("policymap - name is $answer->{'cbQosPolicyMapName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
							);
						}
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 2 )
					{
						# it's a classmap, ask the name and the parent ID
						( $answer->{'cbQosCMName'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosCMName.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						dbg("classmap - name is $answer->{'cbQosCMName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);

						$answer->{'cbQosParentObjectsIndex2'} = $answer->{'cbQosParentObjectsIndex'};
						my $cnt = 0;

					  #KS 2011-10-27 Redundant model object not in use: getbool($M->{system}{cbqos}{collect_all_cm})
						while ( !getbool( $C->{'cbqos_cm_collect_all'}, "invert" )
							and $answer->{'cbQosParentObjectsIndex2'} ne 0
							and $answer->{'cbQosParentObjectsIndex2'} ne $PIndex
							and $cnt++ lt 5 )
						{
							( $answer->{'cbQosConfigIndex'} )
								= $SNMP->getarray("cbQosConfigIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
							if ( $C->{debug} > 5 )
							{
								print "Dumping cbQosConfigIndex\n";
								print Dumper ( $answer->{'cbQosConfigIndex'} );
							}

							# it is not the first level, get the parent names
							( $answer->{'cbQosObjectsType2'} )
								= $SNMP->getarray("cbQosObjectsType.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
							if ( $C->{debug} > 5 )
							{
								print "Dumping cbQosObjectsType2\n";
								print Dumper ( $answer->{'cbQosObjectsType2'} );
							}

							dbg("look for parent of ObjectsType $answer->{'cbQosObjectsType2'}");
							if ( $answer->{'cbQosObjectsType2'} eq 1 )
							{
								# it is a policymap name
								( $answer->{'cbQosName'}, $answer->{'cbQosParentObjectsIndex2'} )
									= $SNMP->getarray( "cbQosPolicyMapName.$answer->{'cbQosConfigIndex'}",
									"cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}" );
								dbg("parent policymap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
								);
								if ( $C->{debug} > 5 )
								{
									print "Dumping cbQosName\n";
									print Dumper ( $answer->{'cbQosName'} );
									print "Dumping cbQosParentObjectsIndex2\n";
									print Dumper ( $answer->{'cbQosParentObjectsIndex2'} );
								}

							}
							elsif ( $answer->{'cbQosObjectsType2'} eq 2 )
							{
								# it is a classmap name
								( $answer->{'cbQosName'}, $answer->{'cbQosParentObjectsIndex2'} )
									= $SNMP->getarray( "cbQosCMName.$answer->{'cbQosConfigIndex'}",
									"cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}" );
								dbg("parent classmap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
								);
								if ( $C->{debug} > 5 )
								{
									print "Dumping cbQosName\n";
									print Dumper ( $answer->{'cbQosName'} );
									print "Dumping cbQosParentObjectsIndex2\n";
									print Dumper ( $answer->{'cbQosParentObjectsIndex2'} );
								}
							}
							elsif ( $answer->{'cbQosObjectsType2'} eq 3 )
							{
								dbg("skip - this class-map is part of a match statement");
								next BLOCK2;    # skip this class-map, is part of a match statement
							}

							# concatenate names
							if ( $answer->{'cbQosParentObjectsIndex2'} ne 0 )
							{
								$answer->{'cbQosCMName'} = "$answer->{'cbQosName'}--$answer->{'cbQosCMName'}";
							}
						}

						# collect all levels of classmaps or only the first level
						# KS 2011-10-27: by default collect hierarchical QoS
						if ( !getbool( $C->{'cbqos_cm_collect_all'}, "invert" )
							or $answer->{'cbQosParentObjectsIndex'} eq $PIndex )
						{
							#
							$CMValues{"H" . $OIndex}{'CMName'}  = $answer->{'cbQosCMName'};
							$CMValues{"H" . $OIndex}{'CMIndex'} = $OIndex;
						}
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 4 )
					{
						my $CMRate;

						# it's a queueing object, look for the bandwidth
						(   $answer->{'cbQosQueueingCfgBandwidth'},
							$answer->{'cbQosQueueingCfgBandwidthUnits'},
							$answer->{'cbQosParentObjectsIndex'}
							)
							= $SNMP->getarray(
							"cbQosQueueingCfgBandwidth.$qosIndexTable->{$OIndex}",
							"cbQosQueueingCfgBandwidthUnits.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex"
							);
						if ( $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 1 )
						{
							$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * 1000;
						}
						elsif ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 2
							or $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 3 )
						{
							$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * $inoutIfSpeed / 100;
						}
						if ( $CMRate eq 0 ) { $CMRate = "undef"; }
						dbg("queueing - bandwidth $answer->{'cbQosQueueingCfgBandwidth'}, units $answer->{'cbQosQueueingCfgBandwidthUnits'},"
								. "rate $CMRate, parent ID $answer->{'cbQosParentObjectsIndex'}" );
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMCfgRate'} = $CMRate;
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 6 )
					{
						# traffic shaping
						( $answer->{'cbQosTSCfgRate'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosTSCfgRate.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						dbg("shaping - rate $answer->{'cbQosTSCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMTSCfgRate'}
							= $answer->{'cbQosPoliceCfgRate'};

					}
					elsif ( $answer->{'cbQosObjectsType'} eq 7 )
					{
						# police
						( $answer->{'cbQosPoliceCfgRate'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray(
							"cbQosPoliceCfgRate.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex"
							);
						dbg("police - rate $answer->{'cbQosPoliceCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMPoliceCfgRate'}
							= $answer->{'cbQosPoliceCfgRate'};
					}

					if ( $C->{debug} > 5 )
					{
						print Dumper ($answer);
					}

				}

				if ( $answer->{'cbQosPolicyMapName'} eq "" )
				{
					$answer->{'cbQosPolicyMapName'} = 'default';
					dbg("policymap - name is blank, so setting to default");
				}

				$cbQosTable{$intf}{$direction}{'Interface'}{'Descr'} = $if_data->{'ifDescr'};
				$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'}  = $answer->{'cbQosPolicyMapName'};
				$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Index'} = $PIndex;

				# combine CM name and bandwidth
				foreach my $index ( keys %CMValues )
				{
					# check if CM name does exist
					if ( exists $CMValues{$index}{'CMName'} )
					{

						$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Name'}  = $CMValues{$index}{'CMName'};
						$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Index'} = $CMValues{$index}{'CMIndex'};

						# lets print the just type
						if ( exists $CMValues{$index}{'CMCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMCfgRate'};
						}
						elsif ( exists $CMValues{$index}{'CMTSCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Traffic shaping";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMTSCfgRate'};
						}
						elsif ( exists $CMValues{$index}{'CMPoliceCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Police";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMPoliceCfgRate'};
						}
						else
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = "undef";
						}

					}
				}
			}
			else
			{
				dbg("No collect requested in Node table");
			}

		}
		
		if ( scalar( keys %{$ifIndexTable} ) )
		{
			# Finished with SNMP QoS, store object index values for the next run and CM names for WWW
			# cbqos info structure is a tad different from interfaces, but the rrds also need tuning

			# that's an ifindex
			for my $index ( keys %cbQosTable )
			{
				my $thisqosinfo = $cbQosTable{$index};
				# we rely on index to be there for the path key (right now)				

				my $if_data = $if_data_map{$index};
				next
					if ( ref( $if_data_map{$index} ) ne "HASH"
					or !$if_data->{ifSpeed}
					or $if_data->{setlimits} !~ /^(normal|strict|off)$/
					or !getbool( $if_data->{collect} ) )
					;    # don't care about interfaces w/o descr or no speed or uncollected or invalid limit config

				my $thisintf     = $if_data;
				my $desiredlimit = $thisintf->{setlimits};

				info(
					"performing rrd speed limit tuning for cbqos on $thisintf->{ifDescr}, limit enforcement: $desiredlimit, interface speed is "
						. convertIfSpeed( $thisintf->{ifSpeed} )
						. " ($thisintf->{ifSpeed})" );

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
				my $maxbytes
					= $desiredlimit eq "off"    ? "U"
					: $desiredlimit eq "normal" ? int( $thisintf->{ifSpeed} / 4 )
					:                             int( $thisintf->{ifSpeed} / 8 );
				my $maxpkts = $maxbytes eq "U" ? "U" : int( $maxbytes / 50 );    # this is a dodgy heuristic

				for my $direction (qw(in out))
				{


					# save the QoS Data, do it before tuning so inventory can be found when looking for name
					NMISNG::Util::TODO("Subclass Inventory for CBQoS");
					my $data = $thisqosinfo->{$direction};
					$data->{index} = $index;
					
					# create inventory entry, data is not changed below so do it here,
					# add index entry for now, may want to modify this later, or create a specialised Inventory class
					my $path_keys = ['index'];    # for now use this, loadInfo guarnatees it will exist
					my $path = $nmisng_node->inventory_path( concept => "cbqos-$direction", data => $data, path_keys => $path_keys );			
					if( ref($path) eq 'ARRAY')
					{
						my ( $inventory, $error_message ) = $nmisng_node->inventory(
							concept   => "cbqos-$direction",
							data      => $data,
							path      => $path,
							path_keys => $path_keys,
							create    => 1
						);
						$nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
						# regenerate the path, if this thing wasn't new the path may have changed, which is ok
						$inventory->path( recalculate => 1 );
						$inventory->historic(0);
						my ( $op, $error ) = $inventory->save();
						info( "saved ".join(',', @$path)." op: $op");
						$nmisng->log->error( "Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
							if ($error);
					}

					foreach my $class ( keys %{$data->{ClassMap}} )
					{
						# rrd file exists and readable?
						if (-r (my $rrdfile = $S->makeRRDname(
									graphtype => "cbqos-$direction",
									index     => $index,
									item      => $data->{ClassMap}->{$class}->{Name}
								)
							)
							)
						{
							my $fileinfo = RRDs::info($rrdfile);
							for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
							{
								next
									if ( $matching
									!~ /ds\[(PrePolicyByte|DropByte|PostPolicyByte|PrePolicyPkt|DropPkt|NoBufDropPkt)\]\.max/
									);
								my $dsname = $1;
								my $curval = $fileinfo->{$matching};

								# all DS but the byte ones are packet based
								my $desiredval = $dsname =~ /byte/i ? $maxbytes : $maxpkts;

								if ( $curval ne $desiredval )
								{
									info(
										"rrd cbqos-$direction-$class, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
									);
									RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
								}
								else
								{
									info("rrd cbqos-$direction-$class, ds $dsname, current limit $curval is correct");
								}
							}
						}
					}
				
				}
			}
		}
		else
		{
			dbg("no entries found in QoS table of node $S->{name}");
		}
	}
	return 1;
}

#=========================================================================================

sub getCalls
{
	my %args = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;
	my $M    = $S->mdl;
	my $NC   = $S->ndcfg;

	if ( !getbool( $NC->{node}{calls} ) )
	{
		dbg("no collecting for node $S->{name}");
		return;
	}

	dbg("Starting Calls for node $S->{name}");

	## oke,lets go
	if ( getbool( $S->{update} ) )    # fixme unclean access to internal property
	{
		getCallswalk( sys => $S );    # get indexes
	}
	elsif ( !getCallsdata( sys => $S ) )
	{
		getCallswalk( sys => $S );    # get indexes
		getCallsdata( sys => $S );    # get data
	}
	dbg("Finished");

	return;
}

sub getCallsdata
{
	my %args  = @_;
	my $S     = $args{sys};
	my $NI    = $S->ndinfo;
	my $IF    = $S->ifinfo;
	
	my %totalsTable;
	my $ids = $S->nmisng_node->get_inventory_ids( concept => 'calls' );
	return 1 if ( @$ids < 1 );

	# get the old index values
	# the layout of the record is: channel intf intfDescr intfindex parentintfDescr parentintfindex port slot
	foreach my $id ( @$ids )
	{
		my $inventory = $S->nmisng_node->inventory(_id => $id);
		next if(!$inventory);

		# NOTE: this is never saved back because it's not modified
		my $data = $inventory->data();
		my $port = $data->{intfoid};

		my $rrdData = $S->getData(
			class => 'calls',
			index => $data->{parentintfIndex},
			port  => $port,
			model => $model
		);
		my $howdiditgo = $S->status;
		my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

		# were there any errors?
		if ( !$anyerror )
		{
			processAlerts( S => $S );

			my $parentIndex = $data->{parentintfIndex};
			my $D           = $rrdData->{calls}{$parentIndex};

			# check indexes
			if ( $D->{'cpmDS0CallType'}{value} eq "noSuchInstance" )
			{
				logMsg("invalid index in getCallsdata, run walk");
				return 0;
			}

			if ( $D->{'cpmCallCount'}{value} eq "" ) { $D->{'cpmCallCount'}{value} = 0; }

			# calculate totals for physical interfaces and dump them into totalsTable hash
			if ( $D->{'cpmDS0CallType'}{value} != "" )
			{
#	$D->{'cpmAvailableCallCount'}{value} = 1;	# calculate individual available DS0 ports no matter what their current state
				$totalsTable{$parentIndex}{'TotalDS0'}
					+= 1;    # calculate total available DS0 ports no matter what their current state
			}
			$totalsTable{$parentIndex}{'TotalCallCount'} += $D->{'cpmCallCount'}{value};
			$totalsTable{$parentIndex}{'parentintfIndex'} = $parentIndex;
			$totalsTable{$parentIndex}{'parentintfDescr'} = $data->{'parentintfDescr'};

			# populate totals for DS0 call types
			# total idle ports
			if ( $D->{'cpmDS0CallType'}{value} eq "1" )
			{
				$totalsTable{$parentIndex}{'totalIdle'} += 1;
			}

			# total unknown ports
			if ( $D->{'cpmDS0CallType'}{value} eq "2" )
			{
				$totalsTable{$parentIndex}{'totalUnknown'} += 1;
			}

			# total analog ports
			if ( $D->{'cpmDS0CallType'}{value} eq "3" )
			{
				$totalsTable{$parentIndex}{'totalAnalog'} += 1;
			}

			# total digital ports
			if ( $D->{'cpmDS0CallType'}{value} eq "4" )
			{
				$totalsTable{$parentIndex}{'totalDigital'} += 1;
			}

			# total v110 ports
			if ( $D->{'cpmDS0CallType'}{value} eq "5" )
			{
				$totalsTable{$parentIndex}{'totalV110'} += 1;
			}

			# total v120 ports
			if ( $D->{'cpmDS0CallType'}{value} eq "6" )
			{
				$totalsTable{$parentIndex}{'totalV120'} += 1;
			}

			# total voice ports
			if ( $D->{'cpmDS0CallType'}{value} eq "7" )
			{
				$totalsTable{$parentIndex}{'totalVoice'} += 1;
			}
			if ( $D->{'cpmAvailableCallCount'}{value} eq "" ) { $D->{'cpmAvailableCallCount'} = 0; }
			if ( $D->{'cpmCallCount'} eq "" ) { $D->{'cpmCallCount'} = 0; }

			# add into rrd now instead of in a separate loop
			my $intfindex = $parentIndex;
			dbg("Total intf $intfindex, PortName $totalsTable{$intfindex}{'parentintfDescr'}");
			if ( $totalsTable{'TotalCallCount'} eq "" ) { $totalsTable{'TotalCallCount'} = 0; }

			dbg("Total idle DS0 ports  $totalsTable{$intfindex}{'totalIdle'}");
			dbg("Total unknown DS0 ports  $totalsTable{$intfindex}{'totalUnknown'}");
			dbg("Total analog DS0 ports  $totalsTable{$intfindex}{'totalAnalog'}");
			dbg("Total digital DS0 ports  $totalsTable{$intfindex}{'totalDigital'}");
			dbg("Total v110 DS0 ports  $totalsTable{$intfindex}{'totalV110'}");
			dbg("Total v120 DS0 ports  $totalsTable{$intfindex}{'totalV120'}");
			dbg("Total voice DS0 ports  $totalsTable{$intfindex}{'totalVoice'}");
			dbg("Total DS0 ports available  $totalsTable{$intfindex}{'TotalDS0'}");
			dbg("Total DS0 calls  $totalsTable{$intfindex}{'TotalCallCount'}");
			my %snmpVal;
			$snmpVal{'totalIdle'}{value}          = $totalsTable{$intfindex}{'totalIdle'};
			$snmpVal{'totalUnknown'}{value}       = $totalsTable{$intfindex}{'totalUnknown'};
			$snmpVal{'totalAnalog'}{value}        = $totalsTable{$intfindex}{'totalAnalog'};
			$snmpVal{'totalDigital'}{value}       = $totalsTable{$intfindex}{'totalDigital'};
			$snmpVal{'totalV110'}{value}          = $totalsTable{$intfindex}{'totalV110'};
			$snmpVal{'totalV120'}{value}          = $totalsTable{$intfindex}{'totalV120'};
			$snmpVal{'totalVoice'}{value}         = $totalsTable{$intfindex}{'totalVoice'};
			$snmpVal{'AvailableCallCount'}{value} = $totalsTable{$intfindex}{'TotalDS0'};
			$snmpVal{'CallCount'}{value}          = $totalsTable{$intfindex}{'TotalCallCount'};

			#
			# Store data
			my $db = $S->create_update_rrd( data => \%snmpVal, type => "calls", index => $intfindex );
			if ( !$db )
			{
				logMsg( "ERROR updateRRD failed: " . getRRDerror() );
			}

			# DISABLED because data is not modifed
			# $inventory->data($data);
			# $inventory->save();
		}
		else
		{
			logMsg("ERROR ($S->{name}) on getCallsdata, $anyerror");
			HandleNodeDown( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
				if ( $howdiditgo->{snmp_error} );
			HandleNodeDown( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
				if ( $howdiditgo->{wmi_error} );

			return 0;
		}
	}

	return 1;
}

# figure out the calls indices etc
# fixme: this function does not work for wmi-only nodes
# returns: 1 if ok, 0 otherwise
sub getCallswalk
{
	my %args = @_;
	my $S    = $args{sys};	
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getCallswalk for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $SNMP = $S->snmp;

	my ( %seen, %callsTable, %mappingTable, $intfindex, $parentintfIndex, $IntfIndexTable, $IntfStatusTable );

	dbg("Starting Calls ports collection");

	# get all the interfaces we know about
	# grab all the interface data required to run this function
	# no writing back to the IF information is done so plain models
	# are good
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;
	my $model_data = $nmisng->get_inventory_model(
		'concept' => 'interface',
		'cluster_id' => $nmisng_node->cluster_id,
		'node_uuid' => $nmisng_node->uuid,
		fields_hash => {
			'_id' => 1,
			'data.collect' => 1,
			'data.ifAdminStatus' => 1,
			'data.ifDescr' => 1,
			'data.ifIndex' => 1,
			'data.ifSpeed' => 1,
			'data.ifSpeedIn' => 1,
			'data.ifSpeedOut' => 1,
			'data.setlimits' => 1
		}
	);
	my $data = $model_data->data();
	# create a map by ifindex so we can look them up easily, flatten _id into data to make things easier
	my %if_data_map = map { $_->{data}{_id} = $_->{_id};$_->{data}{ifIndex} => $_->{data} } (@$data);

	# double check if any call interfaces on this node.
	# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
	# only collect on interfaces that are defined and that are Admin UP
	foreach my $ifIndex ( keys %if_data_map )
	{
		my $data = $if_data_map{$ifIndex};
		if ( $data->{ifAdminStatus} eq "up" )
		{
			$seen{$ifIndex} = $ifIndex;
		}
	}
	if ( !%seen )
	{
		dbg("$S->{name} does not have any call ports or no collect or port down - Call ports collection aborted"
		);
		return;    # fixme: is that an error or not? i think not, so return 1
	}

	# should now be good to go....
	# only use the Cisco private mib for cisco routers

	# add in the walk root for the cisco interface table entry for port to intf mapping
	add_mapping( "1.3.6.1.4.1.9.10.19.1.5.2.1.8", "cpmDS0InterfaceIndex", "" );
	add_mapping( "1.3.6.1.2.1.31.1.2.1.3",        "ifStackStatus",        "" );

	# getindex the cpmDS0InterfaceIndex oid to populate $callsTable hash with such as interface indexes, ports, slots
	if ( $IntfIndexTable = $SNMP->getindex("cpmDS0InterfaceIndex") )
	{
		foreach my $index ( keys %{$IntfIndexTable} )
		{
			$intfindex = $IntfIndexTable->{$index};
			my ( $slot, $port, $channel ) = split /\./, $index, 3;
			$callsTable{$intfindex}{'intfoid'}   = $index;
			$callsTable{$intfindex}{'intfindex'} = $intfindex;
			$callsTable{$intfindex}{'slot'}      = $slot;
			$callsTable{$intfindex}{'port'}      = $port;
			$callsTable{$intfindex}{'channel'}   = $channel;
		}
		if ( $IntfStatusTable = $SNMP->getindex("ifStackStatus") )
		{
			foreach my $index ( keys %{$IntfStatusTable} )
			{
				( $intfindex, $parentintfIndex ) = split /\./, $index, 2;
				$mappingTable{$intfindex}{'parentintfIndex'} = $parentintfIndex;
			}

			# traverse the callsTable and mappingTable hashes to match call ports with their physical parent ports
			foreach my $callsintf ( sort keys %callsTable )
			{
				foreach my $mapintf ( sort keys %mappingTable )
				{
					if ( $callsintf == $mapintf )
					{
						dbg("parent interface $mappingTable{$mapintf}{'parentintfIndex'} found for interface $callsintf",
							2
						);

						# if parent interface has been reached stop
						if ( $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'} eq "0" )
						{
							$callsTable{$callsintf}{'parentintfIndex'} = $mappingTable{$mapintf}{'parentintfIndex'};
						}

						# assume only one level of nesting in physical interfaces
						# (may need to increase for larger Cisco chassis)
						else
						{
							$callsTable{$callsintf}{'parentintfIndex'}
								= $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'};
						}
					}
				}

				# check if parent interface is also up
				if ( $if_data_map{$callsTable{$callsintf}{'parentintfIndex'}}->{ifAdminStatus} ne "up" )
				{
					##	print returnTime." Calls: parent interface $IF->{$callsTable{$callsintf}{'parentintfIndex'}}{ifDescr} is not up\n" if $debug;
					delete $callsTable{$callsintf};
				}
			}
		}
		# traverse the callsTable hash one last time and populate descriptive fields; also count total voice ports
		my $InstalledVoice;
		foreach my $callsintf ( keys %callsTable )
		{
			my $data = $callsTable{$callsintf};
			( $data->{'intfDescr'}, $data->{'parentintfDescr'} ) = $SNMP->getarray(
				'ifDescr' . ".$callsTable{$callsintf}{'intfindex'}",
				'ifDescr' . ".$callsTable{$callsintf}{'parentintfIndex'}",
			);
			$InstalledVoice++;

			# NOTE: for now we rely on the specail index key
			$data->{index} = $callsintf;
			# Create/find inventory 
			# get the inventory object for this, path_keys required as we don't know what type it will be
			my $path_keys = ['index'];    # for now use this, loadInfo guarnatees it will exist
			my $path = $nmisng_node->inventory_path( concept => 'calls', data => $data, path_keys => $path_keys );			
			if( ref($path) eq 'ARRAY')
			{
				my ( $inventory, $error_message ) = $nmisng_node->inventory(
					concept   => 'calls',
					data      => $data,
					path      => $path,
					path_keys => $path_keys,
					create    => 1
				);
				$nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
				# regenerate the path, if this thing wasn't new the path may have changed, which is ok
				$inventory->path( recalculate => 1 );
				$inventory->historic(0);
				my ( $op, $error ) = $inventory->save();
				info( "saved ".join(',', @$path)." op: $op");
				$nmisng->log->error( "Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
					if ($error);
			}

			$catchall_data->{InstalledVoice} = "$InstalledVoice";
		}
	}
	return 1;
}

# figure out frame relay interfaces, perform collection of pvc information
# note that this does everything from start to finish, there's no separate
# index getter function for type update ops.
#
# fixme: this function does not work for wmi-only nodes
#
# returns: 1 if ok, 0 otherwise
sub getPVC
{
	my %args = @_;

	my $S  = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $graphtypes = $S->ndinfo->{graphtype};
	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing getPVC for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $IF   = $S->ifinfo;
	my $SNMP = $S->snmp;
	my $PVC  = $S->pvcinfo;

	my %pvcTable;
	my $port;
	my $pvc;
	my $mibname;
	my %seen;
	my @ret;

	my %pvcStats;    # start this new every time
	my %snmpTable;

	dbg("Starting frame relay PVC collection");

	# double check if any frame relay interfaces on this node.
	# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
	# only collect on interfaces that are defined, with collection turned on globally
	# and for that interface and that are Admin UP
	foreach ( keys %{$IF} )
	{
		if (    $IF->{$_}{ifType} =~ /framerelay/i
			and $IF->{$_}{ifAdminStatus} eq "up"
			and getbool( $IF->{$_}{collect} ) )
		{
			$seen{$_} = $_;
		}
	}
	if ( !%seen )
	{    # nothing to do
		dbg("$S->{name} does not have any frame ports or no collect or port down");
		return;    # fixme error or not? i think not, return 1 instead
	}

	my $cnt = keys %seen;
	dbg("found $cnt framerelay channel(s)");

	# should now be good to go....
	# only use the Cisco private mib for cisco routers

	# add in the walk root for the cisco interface table entry for pvc to intf mapping
	add_mapping( "1.3.6.1.4.1.9.9.49.1.2.2.1.1", "cfrExtCircuitIfName", "" );

	my $frCircEntryTable;
	my $cfrExtCircIfNameTable;
	if ( $frCircEntryTable = $SNMP->getindex('frCircuitEntry') )
	{
		foreach my $index ( keys %{$frCircEntryTable} )
		{
			my ( $oid, $port, $pvc ) = split /\./, $index, 3;
			my $textoid = oid2name("1.3.6.1.2.1.10.32.2.1.$oid");
			$pvcStats{$port}{$pvc}{$textoid} = $frCircEntryTable->{$index};
			if ( $textoid =~ /ReceivedBECNs|ReceivedFECNs|ReceivedFrames|ReceivedOctets|SentFrames|SentOctets|State/ )
			{
				$snmpTable{$port}{$pvc}{$textoid}{value} = $frCircEntryTable->{$index};
			}
		}

		# fixme hardcoded model name is bad
		if ( $catchall_data->{nodeModel} =~ /CiscoRouter/ )
		{
			if ( $cfrExtCircIfNameTable = $SNMP->getindex('cfrExtCircuitIfName') )
			{
				foreach my $index ( keys %{$cfrExtCircIfNameTable} )
				{
					my ( $port, $pvc ) = split /\./, $index;
					$pvcStats{$port}{$pvc}{'cfrExtCircuitIfName'} = $cfrExtCircIfNameTable->{$index};
				}
			}
		}

		# we now have a hash of port:pvc:mibname=value - or an empty hash if no reply....
		# put away to a rrd.
		foreach $port ( keys %pvcStats )
		{
			# check if parent port was seen before and OK to collect on.
			if ( !exists $seen{$port} )
			{
				dbg("snmp frame port $port is not collected or down - skipping");
				next;
			}

			foreach $pvc ( keys %{$pvcStats{$port}} )
			{
				# massage some values
				# frCircuitState = 2 for active
				# could set an alarm here on PVC down ??
				if ( $pvcStats{$port}{$pvc}{'frCircuitState'} eq 2 )
				{
					$pvcStats{$port}{$pvc}{'frCircuitState'} = 100;
				}
				else
				{
					$pvcStats{$port}{$pvc}{'frCircuitState'} = 0;
				}

				# RRD options
				$snmpTable{$port}{$pvc}{ReceivedBECNs}{option}  = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedFECNs}{option}  = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedFrames}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedOctets}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{SentFrames}{option}     = "counter,0:U";
				$snmpTable{$port}{$pvc}{SentOctets}{option}     = "counter,0:U";
				$snmpTable{$port}{$pvc}{State}{option}          = "gauge,0:U";
				my $key = "${port}-${pvc}";

				if (my $db = $S->create_update_rrd( data => \%{$snmpTable{$port}{$pvc}},
																						type => "pvc",
																						item => $key ))
				{
					$graphtypes->{$key}{pvc} = 'pvc';
				}
				else
				{
					logMsg( "ERROR updateRRD failed: " . getRRDerror() );
				}
			}
		}

		# save a list of PVC numbers to an interface style file, with ifindex mappings, so we
		# can use this to read and graph the rrd via the web ui.
		# save the cisco interface ifDescr if we have it.
		foreach $port ( keys %pvcStats )
		{
			foreach $pvc ( keys %{$pvcStats{$port}} )
			{
				my $key = "${port}-${pvc}";
				$pvcTable{$key}{subifDescr}
					= rmBadChars( $pvcStats{$port}{$pvc}{cfrExtCircuitIfName} );    # if not cisco, will not exist.
				$pvcTable{$key}{pvc}  = $pvc;
				$pvcTable{$key}{port} = $port;    # should be ifIndex of parent frame relay interface
				$pvcTable{$key}{LastTimeChange} = $pvcStats{$port}{$pvc}{frCircuitLastTimeChange};
				$pvcTable{$key}{rrd} = $key;                                            # save this for filename lookups
				$pvcTable{$key}{CIR} = $pvcStats{$port}{$pvc}{frCircuitCommittedBurst};
				$pvcTable{$key}{EIR} = $pvcStats{$port}{$pvc}{frCircuitExcessBurst};
				$pvcTable{$key}{subifIndex}
					= $pvcStats{$port}{$pvc}{frCircuitLogicalIfIndex};    # non-cisco may support this - to be verified.
			}
		}
		if (%pvcTable)
		{
			# pvcTable has some values, so write it out
			$S->{info}{pvc} = \%pvcTable;
			dbg("pvc values stored");
		}
		else
		{
			delete $S->{info}{pvc};
		}
	}

	dbg("Finished");
}

# fixme: this function does not work for wmi-only nodes
sub runServer
{
	my %args = @_;
	my $S    = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $graphtypes = $S->ndinfo->{graphtype};

	if ( !$S->status->{snmp_enabled} )
	{
		info("Not performing server collection for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $M    = $S->mdl;
	my $SNMP = $S->snmp;

	my ( $result, %Val, %ValMeM, $hrCpuLoad, $op, $error );

	info("Starting server device/storage collection, node $S->{name}");

	# clean up node file
	NMISNG::Util::TODO("Need a cleanup/historic checker");
	delete $S->ndinfo->{device};

	# get cpu info
	if ( ref( $M->{device} ) eq "HASH" && keys %{$M->{device}} )
	{
		my $overall_target = {};
		my $deviceIndex = $SNMP->getindex('hrDeviceIndex');
		$S->loadInfo( class => 'device_global', model => $model, target => $overall_target );    # get cpu load without index

		my $path = $S->nmisng_node->inventory_path( concept => 'device_global', path_keys => [], data => $overall_target );
		my ($inventory,$error_message) = $S->nmisng_node->inventory( concept => 'device', path => $path, path_keys => [], data => $overall_target, create => 1 );
		$S->nmisng->log->error("Failed to get inventory for device 'no index', error_message:$error_message") if(!$inventory);	
		if($inventory) 
		{
			$inventory->historic(0);
			($op,$error) = $inventory->save();
			info( "saved ".join(',', @$path)." op: $op");
		}
		
		$S->nmisng->log->error("Failed to save inventory, error_message:$error") if($error);

		foreach my $index ( keys %{$deviceIndex} )
		{
			# create a new target for each index
			my $device_target = {};
			my $historic = 0;
			if ( $S->loadInfo( class => 'device', index => $index, model => $model, target => $device_target ) )
			{
				my $D = $device_target;
				info("device Descr=$D->{hrDeviceDescr}, Type=$D->{hrDeviceType}");
				if ( $D->{hrDeviceType} eq '1.3.6.1.2.1.25.3.1.3' )
				{                                                                       # hrDeviceProcessor
					( $hrCpuLoad, $D->{hrDeviceDescr} )
						= $SNMP->getarray( "hrProcessorLoad.${index}", "hrDeviceDescr.${index}" );
					dbg("CPU $index hrProcessorLoad=$hrCpuLoad hrDeviceDescr=$D->{hrDeviceDescr}");

					### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
					push( @{$S->{reach}{cpuList}}, $hrCpuLoad );

					$device_target->{hrCpuLoad}
						= ( $hrCpuLoad =~ /noSuch/i ) ? $overall_target->{hrCpuLoad} : $hrCpuLoad;
					info("cpu Load=$overall_target->{hrCpuLoad}, Descr=$D->{hrDeviceDescr}");
					undef %Val;
					$Val{hrCpuLoad}{value} = $device_target->{hrCpuLoad} || 0;
					if ( ( my $db = $S->create_update_rrd( data => \%Val, type => "hrsmpcpu", index => $index ) ) )
					{
						$graphtypes->{$index}{hrsmpcpu} = "hrsmpcpu";
					}
					else
					{
						logMsg( "ERROR updateRRD failed: " . getRRDerror() );
					}

					my $path = $S->nmisng_node->inventory_path( concept => 'device', path_keys => ['index'], data => $device_target );
					($inventory,$error_message) = $S->nmisng_node->inventory( concept => 'device', path => $path, path_keys => ['index'], data => $device_target, create => 1 );
					$S->nmisng->log->error("Failed to get inventory, error_message:$error_message") if(!$inventory);
					if($inventory)
					{
						$inventory->historic(0);
						($op,$error) = $inventory->save();
						info( "saved ".join(',', @$path)." op: $op");
					}
					
					$S->nmisng->log->error("Failed to save inventory, error_message:$error") if(!$error);
				}
				# else
				# {
				# 	delete $device_target->{$index};
				# }
			}
		}
		NMISNG::Util::TODO("Need to clean up device/devices here and mark unused historic");
	}
	else
	{
		dbg("Class=device not defined in model=$catchall_data->{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
	if ( ref( $S->{reach}{cpuList} ) and @{$S->{reach}{cpuList}} )
	{
		$S->{reach}{cpu} = mean( @{$S->{reach}{cpuList}} );
	}

	# # keep the old storage data around a bit longer, as fallback if loadinfo fails
	my $oldstorage = $S->ndinfo->{storage};
	# delete $NI->{storage};

	if ( $M->{storage} ne '' )
	{
		my $disk_cnt             = 1;
		my $storageIndex         = $SNMP->getindex('hrStorageIndex');
		my $hrFSMountPoint       = undef;
		my $hrFSRemoteMountPoint = undef;
		my $fileSystemTable      = undef;

		foreach my $index ( keys %{$storageIndex} )
		{
			# look for existing data for this as 'fallback'
			my $oldstorage;
			my $inventory = $S->nmisng_node->inventory( concept => 'storage', index => $index, nolog => 1);
			$oldstorage = $inventory->data() if($inventory);
			my $storage_target = {};
			my $historic = 0;

			# this saves any retrieved info under ni->{storage}
			my $wasloadable = $S->loadInfo(
				class  => 'storage',
				index  => $index,
				model  => $model,
				target => $storage_target
			);
			if ( $wasloadable )
			{
				my $D = $storage_target;                        # new data

				### 2017-02-13 keiths, handling larger disk sizes by converting to an unsigned integer
				$D->{hrStorageSize} = unpack( "I", pack( "i", $D->{hrStorageSize} ) );
				$D->{hrStorageUsed} = unpack( "I", pack( "i", $D->{hrStorageUsed} ) );

				info(
					"storage $D->{hrStorageDescr} Type=$D->{hrStorageType}, Size=$D->{hrStorageSize}, Used=$D->{hrStorageUsed}, Units=$D->{hrStorageUnits}"
				);

				# set not historic, further down it may be set
				$inventory->historic(1) if($inventory);
				if ((       $M->{storage}{nocollect}{Description} ne ''
						and $D->{hrStorageDescr} =~ /$M->{storage}{nocollect}{Description}/
					)
					or $D->{hrStorageSize} <= 0
					)
				{
					NMISNG::Util::TODO("Need an inventory object and mark it historic?");
					$inventory->historic(1) if($inventory);
				}
				else
				{
					if ($D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.4'        # hrStorageFixedDisk
						or $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.10'    # hrStorageNetworkDisk
						)
					{
						my %Val;
						my $hrStorageType = $D->{hrStorageType};
						$Val{hrDiskSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrDiskUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Disk to Health Calculations.
						my $diskUtil = $Val{hrDiskUsed}{value} / $Val{hrDiskSize}{value} * 100;
						dbg("Disk List updated with Util=$diskUtil Size=$Val{hrDiskSize}{value} Used=$Val{hrDiskUsed}{value}",
							1
						);
						push( @{$S->{reach}{diskList}}, $diskUtil );

						$D->{hrStorageDescr} =~ s/,/ /g;    # lose any commas.
						if ( ( my $db = $S->create_update_rrd( data => \%Val, type => "hrdisk", index => $index ) ) )
						{
							$graphtypes->{$index}{hrdisk} = "hrdisk";
							$D->{hrStorageType}              = 'Fixed Disk';
							$D->{hrStorageIndex}             = $index;
							$D->{hrStorageGraph}             = "hrdisk";
							$disk_cnt++;
						}
						else
						{
							logMsg( "ERROR updateRRD failed: " . getRRDerror() );
						}

						if ( $hrStorageType eq '1.3.6.1.2.1.25.2.1.10' )
						{
							# only get this snmp once if we need to, and created an named index.
							if ( not defined $fileSystemTable )
							{
								$hrFSMountPoint       = $SNMP->getindex('hrFSMountPoint');
								$hrFSRemoteMountPoint = $SNMP->getindex('hrFSRemoteMountPoint');
								foreach my $fsIndex ( keys %$hrFSMountPoint )
								{
									my $mp = $hrFSMountPoint->{$fsIndex};
									$fileSystemTable->{$mp} = $hrFSRemoteMountPoint->{$fsIndex};
								}
							}

							$D->{hrStorageType}        = 'Network Disk';
							$D->{hrFSRemoteMountPoint} = $fileSystemTable->{$D->{hrStorageDescr}};
						}

					}
					### 2014-08-28 keiths, fix for VMware Real Memory as HOST-RESOURCES-MIB::hrStorageType.7 = OID: HOST-RESOURCES-MIB::hrStorageTypes.20
					elsif ($D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.2'
						or $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.20' )
					{    # Memory
						my %Val;
						$Val{hrMemSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrMemUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Memory to Health Calculations.
						$S->{reach}{memfree} = $Val{hrMemSize}{value} - $Val{hrMemUsed}{value};
						$S->{reach}{memused} = $Val{hrMemUsed}{value};

						if ( ( my $db = $S->create_update_rrd( data => \%Val, type => "hrmem" ) ) )
						{
							$graphtypes->{hrmem} = "hrmem";
							$D->{hrStorageType}     = 'Memory';
							$D->{hrStorageGraph}    = "hrmem";
						}
						else
						{
							logMsg( "ERROR updateRRD failed: " . getRRDerror() );
						}
					}

					# in net-snmp, virtualmemory is used as type for both swap and 'virtual memory' (=phys + swap)
					elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.3' )
					{    # VirtualMemory
						my %Val;

						my ( $itemname, $typename )
							= ( $D->{hrStorageDescr} =~ /Swap/i ) ? (qw(hrSwapMem hrswapmem)) : (qw(hrVMem hrvmem));

						$Val{$itemname . "Size"}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{$itemname . "Used"}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2014-08-07 keiths, adding Other Memory to Health Calculations.
						$S->{reach}{$itemname . "Free"}
							= $Val{$itemname . "Size"}{value} - $Val{$itemname . "Used"}{value};
						$S->{reach}{$itemname . "Used"} = $Val{$itemname . "Used"}{value};

						#print Dumper $S->{reach};

						if ( my $db = $S->create_update_rrd( data => \%Val, type => $typename ) )
						{
							$graphtypes->{$typename} = $typename;
							$D->{hrStorageType}         = $D->{hrStorageDescr};    # i.e. virtual memory or swap space
							$D->{hrStorageGraph}        = $typename;
						}
						else
						{
							logMsg( "ERROR updateRRD failed: " . getRRDerror() );
						}
					}

					# also collect mem buffers and cached mem if present
					# these are marked as storagetype hrStorageOther but the descr is usable
					elsif (
						$D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.1'    # StorageOther
						and $D->{hrStorageDescr} =~ /^(Memory buffers|Cached memory)$/i
						)
					{
						my %Val;
						my ( $itemname, $typename )
							= ( $D->{hrStorageDescr} =~ /^Memory buffers$/i )
							? (qw(hrBufMem hrbufmem))
							: (qw(hrCacheMem hrcachemem));

						# for buffers the total size isn't overly useful (net-snmp reports total phsymem),
						# for cached mem net-snmp reports total size == used cache mem
						$Val{$itemname . "Size"}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{$itemname . "Used"}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						if ( my $db = $S->create_update_rrd( data => \%Val, type => $typename ) )
						{
							$graphtypes->{$typename} = $typename;
							$D->{hrStorageType}         = 'Other Memory';
							$D->{hrStorageGraph}        = $typename;
						}
						else
						{
							logMsg( "ERROR updateRRD failed: " . getRRDerror() );
						}
					}
					# storage type not recognized?
					else
					{
						$inventory->historic(1) if($inventory);
					}
				}
				if( !$inventory )
				{
					my $path = $S->nmisng_node->inventory_path( concept => 'storage', path_keys => ['index'], data => $storage_target );
					($inventory,$error) = $S->nmisng_node->inventory(
						concept => 'storage',
						data => $storage_target,
						path => $path,
						path_keys => ['index'],
						create => 1
					);
					$S->nmisng->log->error("Failed to get storage inventory, error_message:$error") if(!$inventory);
				}
				($op,$error) = $inventory->save() if($inventory);
				$S->nmisng->log->error("Failed to save storage inventory, op:$op, error_message:$error") if($error);
			}
			elsif( $oldstorage )
			{
				logMsg("ERROR failed to retrieve storage info for index=$index, continuing with OLD data!");
				# nothing needs to be done here, storage target is the data from last time so it's already in db
				# maybe mark it historic?
			}
		}
	}
	else
	{
		dbg("Class=storage not defined in Model=$catchall_data->{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server Disk Usage to Health Calculations.
	if ( defined $S->{reach}{diskList} and @{$S->{reach}{diskList}} )
	{
		#print Dumper $S->{reach}{diskList};
		$S->{reach}{disk} = mean( @{$S->{reach}{diskList}} );
	}

	info("Finished");
}    # end runServer

# converts date value to readable string
sub snmp2date
{
	my @tt = unpack( "C*", shift );
	return
		  ( ( $tt[0] * 256 ) + $tt[1] ) . "-"
		. $tt[2] . "-"
		. $tt[3] . ","
		. $tt[4] . ":"
		. $tt[5] . ":"
		. $tt[6] . "."
		. $tt[7];
}

#=========================================================================================

# this function runs all services that are directly associated with a given node
# args: live sys object for the node in question, and optional snmp (true/false) arg
#
# attention: when run with snmp false then snmp-based services are NOT checked!
# fixme: this function does not support service definitions from wmi!
sub runServices
{
	my %args = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;
	my $V    = $S->view;
	my $C    = loadConfTable();
	my $NT   = loadLocalNodeTable();
	my $SNMP = $S->snmp;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	# don't attempt anything silly if this is a wmi-only node
	my $snmp_allowed = getbool( $args{snmp} ) && $S->status->{snmp_enabled};

	my $node = $S->{name};

	info("Starting Services stats, node=$S->{name}, nodeType=$catchall_data->{nodeType}");

	my $cpu;
	my $memory;
	my $msg;
	my %services;    # hash to hold snmp gathered service status.
	my %status;      # hash to collect generic/non-snmp service status

	my $ST    = loadServicesTable();
	my $timer = NMIS::Timing->new;

	# do an snmp service poll first, regardless of whether any specific services being enabled or not
	my %snmpTable;
	my $timeout = 3;
	my ( $snmpcmd, @ret, $var, $i, $key );
	my $write = 0;

	# do we have snmp-based services and are we allowed to check them? ie node active and collect on
	if (    $snmp_allowed
		and getbool( $NT->{$node}{active} )
		and getbool( $NT->{$node}{collect} )
		and grep( exists( $ST->{$_} ) && $ST->{$_}->{Service_Type} eq "service",
			split( /,/, $NT->{$node}->{services} ) )
		)
	{
		info("node has SNMP services to check");

		dbg("get index of hrSWRunName by snmp, then get some data");
		my $hrIndextable;

		# get the process parameters by column, allowing efficient bulk requests
		# but possibly running into bad agents at times, which gettable/getindex
		# compensates for by backing off and retrying.
		for my $var (
			qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus
			hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem)
			)
		{
			if ( $hrIndextable = $SNMP->getindex($var) )
			{
				foreach my $inst ( keys %{$hrIndextable} )
				{
					my $value   = $hrIndextable->{$inst};
					my $textoid = oid2name( name2oid($var) . "." . $inst );
					$value = snmp2date($value) if ( $textoid =~ /date\./i );
					( $textoid, $inst ) = split /\./, $textoid, 2;
					$snmpTable{$textoid}{$inst} = $value;
					dbg( "Indextable=$inst textoid=$textoid value=$value", 2 );
				}
			}

			# SNMP failed, so mark SNMP down so code below handles results properly
			else
			{
				logMsg("$node SNMP failed while collecting SNMP Service Data");
				HandleNodeDown( sys => $S, type => "snmp", details => "get SNMP Service Data: " . $SNMP->error );
				$snmp_allowed = 0;
				last;
			}
		}

		# are we still good to continue?
		# don't do anything with the (incomplete and unusable) snmp data if snmp failed just now
		if ($snmp_allowed)
		{
			# prepare service list for all observed services
			foreach ( sort keys %{$snmpTable{hrSWRunName}} )
			{
				# key services by name_pid
				$key                               = $snmpTable{hrSWRunName}{$_} . ':' . $_;
				$services{$key}{hrSWRunName}       = $key;
				$services{$key}{hrSWRunPath}       = $snmpTable{hrSWRunPath}{$_};
				$services{$key}{hrSWRunParameters} = $snmpTable{hrSWRunParameters}{$_};
				$services{$key}{hrSWRunType}
					= ( '', 'unknown', 'operatingSystem', 'deviceDriver', 'application' )[$snmpTable{hrSWRunType}{$_}];
				$services{$key}{hrSWRunStatus}
					= ( '', 'running', 'runnable', 'notRunnable', 'invalid' )[$snmpTable{hrSWRunStatus}{$_}];
				$services{$key}{hrSWRunPerfCPU} = $snmpTable{hrSWRunPerfCPU}{$_};
				$services{$key}{hrSWRunPerfMem} = $snmpTable{hrSWRunPerfMem}{$_};

				dbg("$services{$key}{hrSWRunName} type=$services{$key}{hrSWRunType} status=$services{$key}{hrSWRunStatus} cpu=$services{$key}{hrSWRunPerfCPU} memory=$services{$key}{hrSWRunPerfMem}",
					2
				);
			}

			# keep all services for display (not rrd!)
			$NI->{services} = \%services;

			# now clear events that applied to processes that no longer exist
			my %nodeevents = loadAllEvents( node => $S->{name} );
			for my $eventkey ( keys %nodeevents )
			{
				my $thisevent = $nodeevents{$eventkey};

		  # fixme NMIS-73: this should be tied to both the element format and a to-be-added 'service' field of the event
		  # until then we trigger on the element format plus event name
				if (   $thisevent->{element} =~ /^\S+:\d+$/
					&& $thisevent->{event} =~ /process memory/i
					&& !exists $services{$thisevent->{element}} )
				{
					dbg(      "clearing event $thisevent->{event} for node $thisevent->{node} as process "
							. $thisevent->{element}
							. " no longer exists" );
					checkEvent(
						sys     => $S,
						event   => $thisevent->{event},
						level   => $thisevent->{level},
						element => $thisevent->{element},
						details => $thisevent->{details}
					);
				}
			}
		}
	}

	# specific services to be tested are saved in a list - these are rrd-collected, too.
	# note that this also covers the snmp-based services
	my $didRunServices = 0;
	for my $service ( split /,/, $NT->{$S->{name}}{services} )
	{
		# check for invalid service table data
		next if ( $service eq '' or $service =~ /n\/a/i or $ST->{$service}{Service_Type} =~ /n\/a/i );

		# are we supposed to run this service now?
		# load the service status and check the last run time
		my %previous = loadServiceStatus( node => $node, service => $service );

		my $lastrun
			= ( $previous{$C->{server_name}}->{$service} && $previous{$C->{server_name}}->{$service}->{$node} )
			? $previous{$C->{server_name}}->{$service}->{$node}->{last_run}
			: 0;

		my $serviceinterval = $ST->{$service}->{Poll_Interval} || 300;                       # 5min
		my $msg = "Service $service on $node (interval \"$serviceinterval\") last ran at "
			. returnDateStamp($lastrun) . ", ";
		if ( $serviceinterval =~ /^\s*(\d+(\.\d+)?)([mhd])$/ )
		{
			my ( $rawvalue, $unit ) = ( $1, $3 );
			$serviceinterval = $rawvalue * ( $unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : 86400 );
		}

		# we don't run the service exactly at the same time in the collect cycle,
		# so allow up to 10% underrun
		if ( $lastrun && ( ( time - $lastrun ) < $serviceinterval * 0.9 ) )
		{
			$msg .= "skipping this time.";
			if ( $C->{info} or $C->{debug} )
			{
				info($msg);
				logMsg("INFO: $msg");
			}
			next;
		}
		else
		{
			$msg .= "must be checked this time.";
			if ( $C->{info} or $C->{debug} )
			{
				info($msg);
				logMsg("INFO: $msg");
			}
		}

		# make sure that the rrd heartbeat is suitable for the service interval!
		my $serviceheartbeat = ( $serviceinterval * 3 ) || 300 * 3;

		$didRunServices = 1;

		# make sure this gets reinitialized for every service!
		my $gotMemCpu = 0;
		my %Val;

		info(
			"Checking service_type=$ST->{$service}{Service_Type} name=$ST->{$service}{Name} service_name=$ST->{$service}{Service_Name}"
		);

		# clear global hash each time around as this is used to pass results to rrd update
		my $ret      = 0;
		my $snmpdown = 0;

		# record the service response time, more precisely the time it takes us testing the service
		$timer->resetTime;
		my $responsetime;    # blank the responsetime

		# DNS: lookup whatever Service_name contains (fqdn or ip address),
		# nameserver being the host in question
		if ( $ST->{$service}{Service_Type} eq "dns" )
		{
			use Net::DNS;
			my $lookfor = $ST->{$service}{Service_Name};
			if ( !$lookfor )
			{
				dbg("Service_Name for $catchall_data->{host} must be a FQDN or IP address");
				logMsg(
					"ERROR, ($S->{name}) Service_name for service=$service must contain an FQDN or IP address"
				);
				next;
			}
			my $res = Net::DNS::Resolver->new;
			$res->nameserver( $catchall_data->{host} );
			$res->udp_timeout(10);    # don't waste more than 10s on dud dns
			$res->usevc(0);           # force to udp (default)
			$res->debug(1) if $C->{debug} > 3;    # set this to 1 for debug

			my $packet = $res->search($lookfor);  # resolver figures out what to look for
			if ( !defined $packet )
			{
				$ret = 0;
				dbg("ERROR Unable to lookup $lookfor on DNS server $catchall_data->{host}");
			}
			else
			{
				$ret = 1;
				dbg( "DNS data for $lookfor from $catchall_data->{host} was " . $packet->string );
			}
		}    # end DNS

		# now the 'port' service checks, which rely on nmap
		# - tcp would be easy enough to do with a plain connect, but udp accessible-or-closed needs extra smarts
		elsif ( $ST->{$service}{Service_Type} eq "port" )
		{
			$msg = '';
			my ( $scan, $port ) = split ':', $ST->{$service}{Port};

			my $nmap = (
				$scan =~ /^udp$/i
				? "nmap -sU --host_timeout 3000 -p $port -oG - $catchall_data->{host}"
				: "nmap -sT --host_timeout 3000 -p $port -oG - $catchall_data->{host}"
			);

			# fork and read from pipe
			my $pid = open( NMAP, "$nmap 2>&1 |" );
			if ( !defined $pid )
			{
				my $errmsg = "ERROR, Cannot fork to execute nmap: $!";
				logMsg($errmsg);
				info($errmsg);
			}
			while (<NMAP>)
			{
				$msg .= $_;    # this retains the newlines
			}
			close(NMAP);
			my $exitcode = $?;

			# if the pipe close doesn't wait until the child is gone (which it may do...)
			# then wait and collect explicitely
			if ( waitpid( $pid, 0 ) == $pid )
			{
				$exitcode = $?;
			}
			if ($exitcode)
			{
				logMsg( "ERROR, NMAP ($nmap) returned exitcode " . ( $exitcode >> 8 ) . " (raw $exitcode)" );
				info( "$nmap returned exitcode " .                 ( $exitcode >> 8 ) . " (raw $exitcode)" );
			}
			if ( $msg =~ /Ports: $port\/open/ )
			{
				$ret = 1;
				info("NMAP reported success for port $port: $msg");
				logMsg("INFO, NMAP reported success for port $port: $msg") if ( $C->{debug} or $C->{info} );
			}
			else
			{
				$ret = 0;
				info("NMAP reported failure for port $port: $msg");
				logMsg("INFO, NMAP reported failure for port $port: $msg") if ( $C->{debug} or $C->{info} );
			}
		}

		# now the snmp services - but only if snmp is on
		elsif ( $ST->{$service}{Service_Type} eq "service"
			and getbool( $NT->{$node}{collect} ) )
		{
			# only do the SNMP checking if and when you are supposed to!
			# snmp not allowed also includes the case of snmp having failed just now
			next if ( !$snmp_allowed );

			dbg("snmp_stop_polling_on_error=$C->{snmp_stop_polling_on_error} snmpdown=$catchall_data->{snmpdown} nodedown=$catchall_data->{nodedown}"
			);
			if (getbool( $C->{snmp_stop_polling_on_error}, "invert" )
				or (    getbool( $C->{snmp_stop_polling_on_error} )
					and !getbool( $catchall_data->{snmpdown} )
					and !getbool( $catchall_data->{nodedown} ) )
				)
			{
				my $wantedprocname = $ST->{$service}{Service_Name};
				my $parametercheck = $ST->{$service}{Service_Parameters};

				if ( !$wantedprocname and !$parametercheck )
				{
					dbg("ERROR, Both Service_Name and Service_Parameters are empty");
					logMsg(
						"ERROR, ($S->{name}) service=$service Service_Name and Service_Parameters are empty!");
					next;
				}

				# one of the two blank is ok
				$wantedprocname ||= ".*";
				$parametercheck ||= ".*";

				# lets check the service status from snmp for matching process(es)
				# it's common to have multiple processes with the same name on a system,
				# heuristic: one or more living processes -> service is ok,
				# no living ones -> down.
				# living in terms of host-resources mib = runnable or running;
				# interpretation of notrunnable is not clear.
				# invalid is for (short-lived) zombies, which should be ignored.

				# we check: the process name, against regex from Service_Name definition,
				# AND the process path + parameters, against regex from Service_Parameters
				# services list is keyed by "name:pid"
				my @matchingpids = grep( (
						/^$wantedprocname:\d+$/
							&& ( $services{$_}->{hrSWRunPath} . " " . $services{$_}->{hrSWRunParameters} )
							=~ /$parametercheck/
					),
					keys %services );

				my @livingpids = grep ( $services{$_}->{hrSWRunStatus} =~ /^(running|runnable)$/i, @matchingpids );

				dbg(      "runServices: found "
						. scalar(@matchingpids)
						. " total and "
						. scalar(@livingpids)
						. " live processes for process '$wantedprocname', parameters '$parametercheck', live processes: "
						. join( " ", map { /^$wantedprocname:(\d+)/ && $1 } (@livingpids) ) );

				if ( !@livingpids )
				{
					$ret       = 0;
					$cpu       = 0;
					$memory    = 0;
					$gotMemCpu = 1;
					logMsg(
						"INFO, service $ST->{$service}{Name} is down, "
							. (
							@matchingpids
							? "only non-running processes"
							: "no matching processes"
							)
					);
				}
				else
				{
					# return the average values for cpu and mem
					$ret       = 1;
					$gotMemCpu = 1;

					# cpu is in centiseconds, and a running counter. rrdtool wants integers for counters.
					# memory is in kb, and a gauge.
					$cpu = int( mean( map { $services{$_}->{hrSWRunPerfCPU} } (@livingpids) ) );
					$memory = mean( map { $services{$_}->{hrSWRunPerfMem} } (@livingpids) );

				  #					dbg("cpu: ".join(" + ",map { $services{$_}->{hrSWRunPerfCPU} } (@livingpids)) ." = $cpu");
				  #					dbg("memory: ".join(" + ",map { $services{$_}->{hrSWRunPerfMem} } (@livingpids)) ." = $memory");

					info(
						"INFO, service $ST->{$service}{Name} is up, " . scalar(@livingpids) . " running process(es)" );
				}
			}
			else
			{
				# is the service already down?
				$snmpdown = 1;
			}
		}

		# now the sapi 'scripts' (similar to expect scripts)
		elsif ( $ST->{$service}{Service_Type} eq "script" )
		{
			### lets do the user defined scripts
			my $scripttext;
			if ( !open( F, "$C->{script_root}/$service" ) )
			{
				dbg("ERROR, can't open script file for $service: $!");
			}
			else
			{
				$scripttext = join( "", <F> );
				close(F);

				my $timeout = ( $ST->{$service}->{Max_Runtime} > 0 ) ? $ST->{$service}->{Max_Runtime} : 3;

				( $ret, $msg ) = sapi( $catchall_data->{host}, $ST->{$service}{Port}, $scripttext, $timeout );
				dbg("Results of $service is $ret, msg is $msg");
			}
		}

		# 'real' scripts, or more precisely external programs
		# which also covers nagios plugins - https://nagios-plugins.org/doc/guidelines.html
		elsif ( $ST->{$service}{Service_Type} =~ /^(program|nagios-plugin)$/ )
		{
			$ret = 0;
			my $svc = $ST->{$service};
			if ( !$svc->{Program} or !-x $svc->{Program} )
			{
				info("ERROR, service $service defined with no working Program to run!");
				logMsg("ERROR service $service defined with no working Program to run!");
				next;
			}

			# exit codes and output handling differ
			my $flavour_nagios = ( $svc->{Service_Type} eq "nagios-plugin" );

			# check the arguments (if given), substitute node.XYZ values
			my $finalargs;
			if ( $svc->{Args} )
			{
				$finalargs = $svc->{Args};

				# don't touch anything AFTER a node.xyz, and only subst if node.xyz is the first/only thing,
				# or if there's a nonword char before node.xyz.
				$finalargs =~ s/(^|\W)(node\.([a-zA-Z0-9_-]+))/$1$catchall_data->{$3}/g;
				dbg("external program args were $svc->{Args}, now $finalargs");
			}

			my $programexit = 0;

			# save and restore any previously running alarm,
			# but don't bother subtracting the time spent here
			my $remaining = alarm(0);
			dbg("saving running alarm, $remaining seconds remaining");
			my $pid;
			eval {
				my @responses;
				my $svcruntime = defined( $svc->{Max_Runtime} ) && $svc->{Max_Runtime} > 0 ? $svc->{Max_Runtime} : 0;

				local $SIG{ALRM} = sub { die "alarm\n"; };
				alarm($svcruntime) if ($svcruntime);    # setup execution timeout

			# run given program with given arguments and possibly read from it
			# program is disconnected from stdin; stderr goes into a tmpfile and is collected separately for diagnostics
				my $stderrsink = POSIX::tmpnam();    # good enough, no atomic open required
				dbg(      "running external program '$svc->{Program} $finalargs', "
						. ( getbool( $svc->{Collect_Output} ) ? "collecting" : "ignoring" )
						. " output" );
				$pid = open( PRG, "$svc->{Program} $finalargs </dev/null 2>$stderrsink |" );
				if ( !$pid )
				{
					alarm(0) if ($svcruntime);       # cancel any timeout
					info("ERROR, cannot start service program $svc->{Program}: $!");
					logMsg("ERROR: cannot start service program $svc->{Program}: $!");
				}
				else
				{
					@responses = <PRG>;              # always check for output but discard it if not required
					close PRG;
					$programexit = $?;
					alarm(0) if ($svcruntime);       # cancel any timeout

					dbg( "service exit code is " . ( $programexit >> 8 ) );

					# consume and warn about any stderr-output
					if ( -f $stderrsink && -s $stderrsink )
					{
						open( UNWANTED, $stderrsink );
						my $badstuff = join( "", <UNWANTED> );
						chomp($badstuff);
						logMsg(
							"WARNING: Service program $svc->{Program} returned unexpected error output: \"$badstuff\"");
						info("Service program $svc->{Program} returned unexpected error output: \"$badstuff\"");
						close(UNWANTED);
					}
					unlink($stderrsink);

					if ( getbool( $svc->{Collect_Output} ) )
					{
						# nagios has two modes of output *sigh*, |-as-newline separator and real newlines
						# https://nagios-plugins.org/doc/guidelines.html#PLUGOUTPUT
						if ($flavour_nagios)
						{
							# ditch any whitespace around the |
							my @expandedresponses = map { split /\s*\|\s*/ } (@responses);

							@responses = ( $expandedresponses[0] );    # start with the first line, as is
							   # in addition to the | mode, any subsequent lines can carry any number of
							   # 'performance measurements', which are hard to parse out thanks to a fairly lousy format
							for my $perfline ( @expandedresponses[1 .. $#expandedresponses] )
							{
								while ( $perfline =~ /([^=]+=\S+)\s*/g )
								{
									push @responses, $1;
								}
							}
						}

						# now determine how to save the values in question
						for my $idx ( 0 .. $#responses )
						{
							my $response = $responses[$idx];
							chomp $response;

							# the first line is special; it sets the textual status
							if ( $idx == 0 )
							{
								dbg("service status text is \"$response\"");
								$status{$service}->{status_text} = $response;
								next;
							}

							# normal expectation: values reported are unit-less, ready for final use
							# expectation not guaranteed by nagios
							my ( $k, $v ) = split( /=/, $response, 2 );
							my $rescaledv;

							if ($flavour_nagios)
							{
								# some nagios plugins report multiple metrics, e.g. the check_disk one
								# but the format for passing performance data is pretty ugly
								# https://nagios-plugins.org/doc/guidelines.html#AEN200

								$k = $1 if ( $k =~ /^'(.+)'$/ );    # nagios wants single quotes if a key has spaces

								# a plugin can report levels for warning and crit thresholds
								# and also optionally report possible min and max values;
								my ( $value_with_unit, $lwarn, $lcrit, $lmin, $lmax ) = split( /;/, $v, 5 );

								# any of those could be set to zero
								if ( defined $lwarn or defined $lcrit or defined $lmin or defined $lmax )
								{
									$status{$service}->{limits}->{$k} = {
										warning  => $lwarn,
										critical => $lcrit,
										min      => $lmin,
										max      => $lmax
									};
								}

								# units: s,us,ms = seconds, % percentage, B,KB,MB,TB bytes, c a counter
								if ( $value_with_unit =~ /^([0-9\.]+)(s|ms|us|%|B|KB|MB|GB|TB|c)$/ )
								{
									my ( $numericval, $unit ) = ( $1, $2 );
									dbg("performance data for label '$k': raw value '$value_with_unit'");

									$status{$service}->{units}->{$k} = $unit;    # keep track of the input unit
									$v = $numericval;

									# massage the value into a number for rrd
									my %factors = (
										'ms' => 1e-3,
										'us' => 1e-6,
										'KB' => 1e3,
										'MB' => 1e6,
										'GB' => 1e9,
										'TB' => 1e12
									);                                           # decimal here
									$rescaledv = $v * $factors{$unit} if ( defined $factors{$unit} );
								}
							}
							dbg( "collected response '$k' value '$v'"
									. ( defined $rescaledv ? " rescaled '$rescaledv'" : "" ) );

							# for rrd storage, but only numeric values can be stored!
							# k needs sanitizing for rrd: only a-z0-9_ allowed
							my $rrdsafekey = $k;
							$rrdsafekey =~ s/[^a-zA-Z0-9_]/_/g;
							$rrdsafekey = substr( $rrdsafekey, 0, 19 );
							$Val{$rrdsafekey} = {
								value => defined($rescaledv) ? $rescaledv : $v,
								option => "GAUGE,U:U,$serviceheartbeat"
							};

							# record the relationship between extra readings and the DS names they're stored under
							$status{$service}->{ds}->{$k} = $rrdsafekey;

							if ( $k eq "responsetime" )    # response time is handled specially
							{
								$responsetime = $v;
							}
							else
							{
								$status{$service}->{extra}->{$k} = $v;
							}

						}
					}
				}
			};

			if ( $@ and $@ eq "alarm\n" )
			{
				kill($pid);    # get rid of the service tester, it ran over time...
				info(
					"ERROR, service program $svc->{Program} exceeded Max_Runtime of $svc->{Max_Runtime}s, terminated.");
				logMsg(
					"ERROR: service program $svc->{Program} exceeded Max_Runtime of $svc->{Max_Runtime}s, terminated.");
				$ret = 0;
				kill( "SIGKILL", $pid );
			}
			else
			{
				# now translate the exit code into a service value (0 dead .. 100 perfect)
				# if the external program died abnormally we treat this as 0=dead.
				if ( WIFEXITED($programexit) )
				{
					$programexit = WEXITSTATUS($programexit);
					dbg("external program terminated with exit code $programexit");

					# nagios knows four states: 0 ok, 1 warning, 2 critical, 3 unknown
					# we'll map those to 100, 50 and 0 for everything else.
					if ($flavour_nagios)
					{
						$ret = $programexit == 0 ? 100 : $programexit == 1 ? 50 : 0;
					}
					else
					{
						$ret = $programexit > 100 ? 100 : $programexit;
					}
				}
				else
				{
					logMsg("WARNING: service program $svc->{Program} terminated abnormally!");
					$ret = 0;
				}
			}
			alarm($remaining) if ($remaining);    # restore previously running alarm
			dbg("restored alarm, $remaining seconds remaining");
		}    # end of program/nagios-plugin service type
		else
		{
			# no service type found
			logMsg("ERROR: skipping service $service, invalid service type!");
			next;    # just do the next one - no alarms
		}

		# let external programs set the responsetime if so desired
		$responsetime = $timer->elapTime if ( !defined $responsetime );
		$status{$service}->{responsetime} = $responsetime;
		$status{$service}->{name}         = $ST->{$service}{Name};    # same as $service

		# external programs return 0..100 directly, rest has 0..1
		my $serviceValue = ( $ST->{$service}{Service_Type} =~ /^(program|nagios-plugin)$/ ) ? $ret : $ret * 100;
		$status{$service}->{status} = $serviceValue;

		#logMsg("Updating $node Service, $ST->{$service}{Name}, $ret, gotMemCpu=$gotMemCpu");
		$V->{system}{"${service}_title"} = "Service $ST->{$service}{Name}";
		$V->{system}{"${service}_value"} = $serviceValue == 100 ? 'running' : $serviceValue > 0 ? "degraded" : 'down';
		$V->{system}{"${service}_color"} = $serviceValue == 100 ? 'white' : $serviceValue > 0 ? "orange" : 'red';

		$V->{system}{"${service}_responsetime"} = $responsetime;
		$V->{system}{"${service}_cpumem"} = $gotMemCpu ? 'true' : 'false';

		# now points to the per-service detail view. note: no widget info a/v at this time!
		delete $V->{system}->{"${service}_gurl"};
		$V->{system}{"${service}_url"}
			= "$C->{'<cgi_url_base>'}/services.pl?conf=$C->{conf}&act=details&node="
			. uri_escape($node)
			. "&service="
			. uri_escape($service);

		# let's raise or clear service events based on the status
		if ($snmpdown)    # only set IFF this is an snmp-based service AND snmp is broken/down.
		{
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is not checked, snmp is down");
			$V->{system}{"${service}_value"} = 'unknown';
			$V->{system}{"${service}_color"} = 'gray';
			$serviceValue                    = '';
		}
		elsif ( $serviceValue == 100 )    # service is fully up
		{
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is available ($serviceValue)");

			# all perfect, so we need to clear both degraded and down events
			checkEvent(
				sys     => $S,
				event   => "Service Down",
				level   => "Normal",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" )
			);

			checkEvent(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" )
			);
		}
		elsif ( $serviceValue > 0 )    # service is up but degraded
		{
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is degraded ($serviceValue)");

			# is this change towards the better or the worse?
			# we clear the down (if one exists) as it's not totally dead anymore...
			checkEvent(
				sys     => $S,
				event   => "Service Down",
				level   => "Fatal",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" )
			);

			# ...and create a degraded
			notify(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" ),
				context => {type => "service"}
			);
		}
		else    # Service is down
		{
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is down");

			# clear the degraded event
			# but don't just eventDelete, so that no state engines downstream of nmis get confused!
			checkEvent(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" )
			);

			# and now create a down event
			notify(
				sys     => $S,
				event   => "Service Down",
				level   => "Fatal",
				element => $ST->{$service}{Name},
				details => ( $status{$service}->{status_text} || "" ),
				context => {type => "service"}
			);
		}

		# figure out which graphs to offer
		# every service has these; cpu+mem optional, and totally custom extra are possible, too.
		my @servicegraphs = (qw(service service-response));

		# save result for availability history - one rrd file per service per node
		$Val{service} = {
			value  => $serviceValue,
			option => "GAUGE,0:100,$serviceheartbeat"
		};

		$cpu = -$cpu if ( $cpu < 0 );
		$Val{responsetime} = {
			value  => $responsetime,                  # might be a NOP
			option => "GAUGE,0:U,$serviceheartbeat"
		};
		if ($gotMemCpu)
		{
			$Val{cpu} = {
				value  => $cpu,
				option => "COUNTER,U:U,$serviceheartbeat"
			};
			$Val{memory} = {
				value  => $memory,
				option => "GAUGE,U:U,$serviceheartbeat"
			};

			# cpu is a counter, need to get the delta(counters)/period from rrd
			$status{$service}->{memory} = $memory;

			# fixme: should we omit the responsetime graph for snmp-based services??
			# it doesn't say too much about the service itself...
			push @servicegraphs, (qw(service-mem service-cpu));
		}

		$status{$service}->{service} ||= $service;    # service and node are part of the fn, but possibly mangled...
		$status{$service}->{node} ||= $node;
		$status{$service}->{name} ||= $ST->{$service}->{Name};    # that can be all kinds of stuff, depending on the service type
		# save our server name with the service status, for distributed setups
		$status{$service}->{server} = $C->{server_name};

		# AND ensure the service has a uuid, a recreatable V5 one from config'd namespace+server+service+node's uuid
		$status{$service}->{uuid} = NMIS::UUID::getComponentUUID( $C->{server_name}, $service, 
																															$catchall_data->{uuid} );

		$status{$service}->{description} ||= $ST->{$service}->{Description};    # but that's free-form
		$status{$service}->{last_run} ||= time;

		# where does this go? get inventory, rrd information, then update accordingly
		my $nmisng = $S->nmisng;
		my $nmisng_node = $S->nmisng_node();

		my $data = {
			description => $status{$service}->{description},
			server      => $status{$service}->{server},
			service     => $status{$service}->{service},
			uuid        => $status{$service}->{uuid},
			node => $status{$service}->{node}, # not required but doesn't hurt
		};

		my ($inventory, $error) = $nmisng_node->inventory(
			concept => "service",
			data    => $data,
			create  => 1
				);
		die "failed to create or load inventory!\n" if (!$inventory);


		my $fullpath = $S->create_update_rrd( data => \%Val,
																					type => "service",
																					item => $service,
																					inventory => $inventory );
		logMsg( "ERROR updateRRD failed: " . getRRDerror() ) if (!$fullpath);

		# known/available graphs go into storage, as subconcept => rrd => fn
		# rrd file for this should now be present and a/v, we want relative path,
		# not $fullpath as returned by create_update_rrd...
		my $dbname = $inventory->find_subconcept_type_storage(subconcept => "service",
																													type => "rrd");

		# check what custom graphs exist for this service
		# file naming scheme: Graph-service-custom-<servicename>-<sometag>.nmis,
		# and servicename gets lowercased and reduced to [a-z0-9\._]
		# note: this schema is known here, and in cgi-bin/services.pl
		my $safeservice = lc($service);
		$safeservice =~ s/[^a-z0-9\._]//g;

		opendir( D, $C->{'<nmis_models>'} ) or die "cannot open models dir: $!\n";
		my @cands = grep( /^Graph-service-custom-$safeservice-[a-z0-9\._-]+\.nmis$/, readdir(D) );
		closedir(D);

		map { s/^Graph-(service-custom-[a-z0-9\._]+-[a-z0-9\._-]+)\.nmis$/$1/; } (@cands);
		dbg( "found custom graphs for service $service: " . join( " ", @cands ) ) if (@cands);

		$status{$service}->{customgraphs} = \@cands;
		push @servicegraphs, @cands;

		# now record the right storage subconcept-to-filename set in the inventory
		my $knownones = $inventory->storage; # there's at least the main subconcept 'service'
		for my $maybegone (keys %$knownones)
		{
			next if ($maybegone eq "service" # that must remain
							 or grep($_ eq $maybegone, @servicegraphs)); # or a known one
			# ditch
			$inventory->set_subconcept_type_storage(type => "rrd", subconcept => $maybegone, data => undef);
		}
		for my $maybenew (@servicegraphs)
		{
			# add or update
			$inventory->set_subconcept_type_storage(type => "rrd", subconcept => $maybenew, data => $dbname);
		}

		if ($gotMemCpu)
		{
			# pull the newest cpu value from rrd - as it's a counter we need somebody to compute the delta(counters)/period
			# rrd stores delta * (interval last update - aggregation time) as .value
			# http://serverfault.com/questions/476925/rrd-pdp-status-value
			my $infohash = RRDs::info($fullpath);
			if ( defined( my $cpuval = $infohash->{'ds[cpu].value'} ) )
			{
				my $stepsize   = $infohash->{step};
				my $lastupdate = $infohash->{last_update};

				$status{$service}->{cpu} = $cpuval / ( $lastupdate % $stepsize ) if ( $lastupdate % $stepsize );
			}
		}

		# now update the per-service status file
		my $error = saveServiceStatus( service => $status{$service} );
		# and update the inventory data
		if ($inventory)
		{
			my ( $op, $error ) = $inventory->save();
		}

		logMsg("ERROR: service status saving failed: $error") if ($error);
	}

	# we ran one or more (but not necessarily all!) services
	# so we must update, not overwrite the service_status node info...
	if ($didRunServices)
	{
		for my $newinfo ( keys %status )
		{
			$S->{info}{service_status}->{$newinfo} = $status{$newinfo};
		}
		$catchall_data->{lastServicesPoll} = time();
	}

	info("Finished");
}    # end runServices

#=========================================================================================

# fixme: the CVARn evaluation function should be integrated into and handled by sys::parseString
# fixme: this function works ONLY for indexed/systemhealth sections!
sub runAlerts
{
	my %args = @_;
	my $S    = $args{sys};
	my $M    = $S->mdl;
	my $CA   = $S->alerts;

	my $result;
	my %Val;
	my %ValMeM;
	my $hrCpuLoad;

	info("Running Custom Alerts for node $S->{name}");

	foreach my $sect ( keys %{$CA} )
	{
		# only use inventory that already exists
		my $ids = $S->nmisng_node->get_inventory_ids( concept => $sect );
		info("Custom Alerts for $sect");
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $S->nmisng_node->inventory( _id => $id );
			$S->nmisng->log->error("Failed to get inventory, concept:$sect, _id:$id, error_message:$error_message") && next
				if(!$inventory);
			my $data = $inventory->data();
			my $index = $data->{index};
			foreach my $alrt ( keys %{$CA->{$sect}} )
			{
				if ( defined( $CA->{$sect}{$alrt}{control} ) and $CA->{$sect}{$alrt}{control} ne '' )
				{
					my $control_result = $S->parseString(
						string => "($CA->{$sect}{$alrt}{control}) ? 1:0",
						index  => $index,
						type   => $sect,
						sect   => $sect,
						extras => $data, # <- this isn't really needed, it's going to look this up for cvars anyway
						eval => 1
					);
					dbg("control_result sect=$sect index=$index control_result=$control_result");
					next if not $control_result;
				}

				# perform CVARn substitution for these two types of ops
				NMISNG::Util::TODO("Why can't this run through parseString?");
				if ( $CA->{$sect}{$alrt}{type} =~ /^(test$|threshold)/ )
				{
					my ( $test, $value, $alert, $test_value, $test_result );

					# do this for test and value
					for my $thingie ( ['test', \$test_result], ['value', \$test_value] )
					{
						my ( $key, $target ) = @$thingie;

						my $origexpr = $CA->{$sect}{$alrt}{$key};
						my ( $rebuilt, @CVAR );

						# rip apart expression, rebuild it with var substitutions
						while ( $origexpr =~ s/^(.*?)(CVAR(\d)=(\w+);|\$CVAR(\d))// )
						{
							$rebuilt .= $1;    # the unmatched, non-cvar stuff at the begin
							my ( $varnum, $decl, $varuse ) = ( $3, $4, $5 );    # $2 is the whole |-group

							if ( defined $varnum )                              # cvar declaration
							{
								$CVAR[$varnum] = $data->{$decl};
								logMsg(   "ERROR: CVAR$varnum references unknown object \"$decl\" in \""
										. $CA->{$sect}{$alrt}{$key}
										. '"' )
									if ( !exists $data->{$decl} );
							}
							elsif ( defined $varuse )                           # cvar use
							{
								logMsg(   "ERROR: CVAR$varuse used but not defined in test \""
										. $CA->{$sect}{$alrt}{$key}
										. '"' )
									if ( !exists $CVAR[$varuse] );

								$rebuilt .= $CVAR[$varuse];                     # sub in the actual value
							}
							else                                                # shouldn't be reached, ever
							{
								logMsg( "ERROR: CVAR parsing failure for \"" . $CA->{$sect}{$alrt}{$key} . '"' );
								$rebuilt = $origexpr = '';
								last;
							}
						}
						$rebuilt .= $origexpr;    # and the non-CVAR-containing remainder.

						$$target = eval { eval $rebuilt; };
						dbg("substituted $key sect=$sect index=$index, orig=\""
								. $CA->{$sect}{$alrt}{$key}
								. "\", expr=\"$rebuilt\", result=$$target",
							2
						);
					}

					if ( $test_value =~ /^[\+-]?\d+\.\d+$/ )
					{
						$test_value = sprintf( "%.2f", $test_value );
					}

					my $level = $CA->{$sect}{$alrt}{level};

					# check the thresholds
					# fixed thresholds to fire at level not one off, and threshold falling was just wrong.
					if ( $CA->{$sect}{$alrt}{type} =~ /^threshold/ )
					{
						if ( $CA->{$sect}{$alrt}{type} eq "threshold-rising" )
						{
							if ( $test_value <= $CA->{$sect}{$alrt}{threshold}{Normal} )
							{
								$test_result = 0;
								$level       = "Normal";
							}
							else
							{
								my @levels = qw(Fatal Critical Major Minor Warning);
								foreach my $lvl (@levels)
								{
									if ( $test_value >= $CA->{$sect}{$alrt}{threshold}{$lvl} )
									{
										$test_result = 1;
										$level       = $lvl;
										last;
									}
								}
							}
						}
						elsif ( $CA->{$sect}{$alrt}{type} eq "threshold-falling" )
						{
							if ( $test_value >= $CA->{$sect}{$alrt}{threshold}{Normal} )
							{
								$test_result = 0;
								$level       = "Normal";
							}
							else
							{
								my @levels = qw(Warning Minor Major Critical Fatal);
								foreach my $lvl (@levels)
								{
									if ( $test_value <= $CA->{$sect}{$alrt}{threshold}{$lvl} )
									{
										$test_result = 1;
										$level       = $lvl;
										last;
									}
								}
							}
						}
						info(
							"alert result: Normal=$CA->{$sect}{$alrt}{threshold}{Normal} test_value=$test_value test_result=$test_result level=$level",
							2
						);
					}

				   # and now save the result, for both tests and thresholds (source of level is the only difference)
					$alert->{type}  = $CA->{$sect}{$alrt}{type};    # threshold or test or whatever
					$alert->{test}  = $CA->{$sect}{$alrt}{value};
					$alert->{name}  = $S->{name};                   # node name, not much good here
					$alert->{unit}  = $CA->{$sect}{$alrt}{unit};
					$alert->{event} = $CA->{$sect}{$alrt}{event};
					$alert->{level} = $level;
					$alert->{ds}          = $data->{ $CA->{$sect}{$alrt}{element} };
					$alert->{test_result} = $test_result;
					$alert->{value}       = $test_value;

					# also ensure that section, index and alertkey are known for the event context
					$alert->{section} = $sect;
					$alert->{alert}   = $alrt;                      # the key, good enough
					$alert->{index}   = $index;

					push( @{$S->{alerts}}, $alert );
				}
			}
		}

	}

	processAlerts( S => $S );

	info("Finished");
}    # end runAlerts

# check model sections (but only under sys!), look for 'check' properties,
# and if a known check type is seen, run the appropriate function
# args: sys
# returns: nothing
sub runCheckValues
{
	my %args = @_;
	my $S    = $args{sys};
	my $M    = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = loadConfTable();

	if ( getbool( $catchall_data->{nodedown} ) )    #  don't bother with dead nodes

		#			 and !getbool($NI->{system}{snmpdown}) # snmp not dead
		#			 and $S->status->{snmp_enabled} )			 # snmp still known to be enabled
	{
		dbg("Node $S->{name} is down, not looking for check values");
		return;
	}

	for my $sect ( keys %{$M->{system}->{sys}} )
	{
		if ( my $control = $M->{system}{sys}{$sect}{control} )    # check if skipped by control
		{
			dbg( "control=$control found for section=$sect", 2 );
			if ( !$S->parseString( string => "($control) ? 1:0", sect => $sect, eval => 1 ) )
			{
				dbg("checkvalues of section $sect skipped by control=$control");
				next;
			}
			my $thissection = $M->{system}->{sys}->{$sect};

			for my $source (qw(wmi snmp))
			{
				next if ( ref( $thissection->{$source} ) ne "HASH" );

				for my $attr ( keys %{$thissection->{$source}} )
				{
					my $thisattr = $thissection->{$source}->{$attr};
					if ( my $checktype = $thisattr->{check} )
					{
						if ( $checktype eq 'checkPower' )
						{
							checkPower( sys => $S, attr => $attr );
						}
						else
						{
							logMsg(
								"ERROR ($S->{name}) unknown check method=$checktype in section $sect, source $source");
						}
					}
				}
			}
		}
	}
	dbg("Finished");
}

# create event: node has <something> down, or clear said event (and state)
# args: sys, type (both required), details (optional),
# up (optional, set to clear event, default is create)
#
# currently understands snmp, wmi, node (=the whole node)
# also updates <something>down flag in node info
#
# returns: nothing
sub HandleNodeDown
{
	my %args = @_;
	my ( $S, $typeofdown, $details, $goingup ) = @args{"sys", "type", "details", "up"};
	return if ( ref($S) ne "Sys" or $typeofdown !~ /^(snmp|wmi|node)$/ );
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	$goingup = getbool($goingup);

	my %eventnames = (
		'snmp' => "SNMP Down",
		'wmi'  => "WMI Down",
		'node' => "Node Down"
	);
	my $eventname = $eventnames{$typeofdown};
	$details ||= "$typeofdown error";

	my $eventfunc = ( $goingup ? \&checkEvent : \&notify );
	&$eventfunc(
		sys     => $S,
		event   => $eventname,
		element => '',
		details => $details,
		level   => ( $goingup ? 'Normal' : undef ),
		context => {type => "node"}
	);

	$catchall_data->{"${typeofdown}down"} = $goingup ? 'false' : 'true';

	return;
}

# performs various node health status checks
# optionally! updates rrd
# args: sys, delayupdate (default: 0),
# if delayupdate is set, this DOES NOT update the
#type 'health' rrd (to be done later, with total polltime)
# returns: reachability data (hashref)
sub runReach
{
	my %args           = @_;
	my $S              = $args{sys};                      # system object
	my $donotupdaterrd = getbool( $args{delayupdate} );

	my $IF = $S->ifinfo;                                  # interface info
	my $RI = $S->reach;                                   # reach info
	my $C  = loadConfTable();
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $cpuWeight;
	my $diskWeight;
	my $memWeight;
	my $swapWeight = 0;
	my $responseWeight;
	my $interfaceWeight;
	my $intf;
	my $inputUtil;
	my $outputUtil;
	my $totalUtil;
	my $reportStats;
	my @tmparray;
	my @tmpsplit;
	my %util;
	my $intcount;
	my $intsummary;
	my $intWeight;
	my $index;

	my $reachabilityHealth = 0;
	my $availabilityHealth = 0;
	my $responseHealth     = 0;
	my $cpuHealth          = 0;

	my $memHealth  = 0;
	my $intHealth  = 0;
	my $swapHealth = 0;
	my $diskHealth = 0;

	my $reachabilityMax = 100 * $C->{weight_reachability};
	my $availabilityMax = 100 * $C->{weight_availability};
	my $responseMax     = 100 * $C->{weight_response};
	my $cpuMax          = 100 * $C->{weight_cpu};
	my $memMax          = 100 * $C->{weight_mem};
	my $intMax          = 100 * $C->{weight_int};

	my $swapMax = 0;
	my $diskMax = 0;

	my %reach;

	info("Starting node $S->{name}, type=$catchall_data->{nodeType}");

	# Math hackery to convert Foundry CPU memory usage into appropriate values
	$RI->{memused} = ( $RI->{memused} - $RI->{memfree} ) if $catchall_data->{nodeModel} =~ /FoundrySwitch/;

	if ( $catchall_data->{nodeModel} =~ /Riverstone/ )
	{
		# Math hackery to convert Riverstone CPU memory usage into appropriate values
		$RI->{memfree} = ( $RI->{memfree} - $RI->{memused} );
		$RI->{memused} = $RI->{memused} * 16;
		$RI->{memfree} = $RI->{memfree} * 16;
	}

	if ( $RI->{memfree} == 0 or $RI->{memused} == 0 )
	{
		$RI->{mem} = 100;
	}
	else
	{
		#'hrSwapMemFree' => 4074844160,
		#'hrSwapMemUsed' => 220114944,
		my $mainMemWeight = 1;
		my $extraMem      = 0;

		if (    defined $RI->{hrSwapMemFree}
			and defined $RI->{hrSwapMemUsed}
			and $RI->{hrSwapMemFree}
			and $RI->{hrSwapMemUsed} )
		{
			$RI->{swap} = ( $RI->{hrSwapMemFree} * 100 ) / ( $RI->{hrSwapMemUsed} + $RI->{hrSwapMemFree} );
		}
		else
		{
			$RI->{swap} = 0;
		}

		# calculate mem
		if ( $RI->{memfree} > 0 and $RI->{memused} > 0 )
		{
			$RI->{mem} = ( $RI->{memfree} * 100 ) / ( $RI->{memused} + $RI->{memfree} );
		}
		else
		{
			$RI->{mem} = "U";
		}
	}

	# copy stashed results (produced by runPing and getnodeinfo)
	my $pingresult = $RI->{pingresult};
	$reach{responsetime} = $RI->{pingavg};
	$reach{loss}         = $RI->{pingloss};

	my $snmpresult = $RI->{snmpresult};

	$reach{cpu} = $RI->{cpu};
	$reach{mem} = $RI->{mem};
	if ( $RI->{swap} )
	{
		$reach{swap} = $RI->{swap};
	}
	$reach{disk} = 0;
	if ( defined $RI->{disk} and $RI->{disk} > 0 )
	{
		$reach{disk} = $RI->{disk};
	}
	$reach{operStatus} = $RI->{operStatus};
	$reach{operCount}  = $RI->{operCount};

	# number of interfaces
	$reach{intfTotal}   = $catchall_data->{intfTotal} eq 0 ? 'U' : $catchall_data->{intfTotal};    # from run update
	$reach{intfCollect} = $catchall_data->{intfCollect};                                        # from run update
	$reach{intfUp}      = $RI->{intfUp} ne '' ? $RI->{intfUp} : 0;                           # from run collect
	$reach{intfColUp}   = $RI->{intfColUp};                                                  # from run collect

# new option to set the interface availability to 0 (zero) when node is Down, default is "U" config interface_availability_value_when_down
	my $intAvailValueWhenDown
		= defined $C->{interface_availability_value_when_down} ? $C->{interface_availability_value_when_down} : "U";
	dbg("availability using interface_availability_value_when_down=$C->{interface_availability_value_when_down} intAvailValueWhenDown=$intAvailValueWhenDown"
	);

	# Things which don't do collect get 100 for availability
	if ( $reach{availability} eq "" and !getbool( $catchall_data->{collect} ) )
	{
		$reach{availability} = "100";
	}
	elsif ( $reach{availability} eq "" ) { $reach{availability} = $intAvailValueWhenDown; }

	my ( $outage, undef ) = outageCheck( node => $S->{node}, time => time() );
	dbg("Outage for $S->{name} is $outage");

	# Health should actually reflect a combination of these values
	# ie if response time is high health should be decremented.
	if ( $pingresult == 100 and $snmpresult == 100 )
	{

		$reach{reachability} = 100;
		if ( $reach{operCount} > 0 )
		{
			$reach{availability} = sprintf( "%.2f", $reach{operStatus} / $reach{operCount} );
		}

		if ( $reach{reachability} > 100 ) { $reach{reachability} = 100; }
		( $reach{responsetime}, $responseWeight ) = weightResponseTime( $reach{responsetime} );

		if ( getbool( $catchall_data->{collect} ) and $reach{cpu} ne "" )
		{
			if    ( $reach{cpu} <= 10 )  { $cpuWeight = 100; }
			elsif ( $reach{cpu} <= 20 )  { $cpuWeight = 90; }
			elsif ( $reach{cpu} <= 30 )  { $cpuWeight = 80; }
			elsif ( $reach{cpu} <= 40 )  { $cpuWeight = 70; }
			elsif ( $reach{cpu} <= 50 )  { $cpuWeight = 60; }
			elsif ( $reach{cpu} <= 60 )  { $cpuWeight = 50; }
			elsif ( $reach{cpu} <= 70 )  { $cpuWeight = 35; }
			elsif ( $reach{cpu} <= 80 )  { $cpuWeight = 20; }
			elsif ( $reach{cpu} <= 90 )  { $cpuWeight = 10; }
			elsif ( $reach{cpu} <= 100 ) { $cpuWeight = 1; }

			if ( $reach{disk} )
			{
				if    ( $reach{disk} <= 10 )  { $diskWeight = 100; }
				elsif ( $reach{disk} <= 20 )  { $diskWeight = 90; }
				elsif ( $reach{disk} <= 30 )  { $diskWeight = 80; }
				elsif ( $reach{disk} <= 40 )  { $diskWeight = 70; }
				elsif ( $reach{disk} <= 50 )  { $diskWeight = 60; }
				elsif ( $reach{disk} <= 60 )  { $diskWeight = 50; }
				elsif ( $reach{disk} <= 70 )  { $diskWeight = 35; }
				elsif ( $reach{disk} <= 80 )  { $diskWeight = 20; }
				elsif ( $reach{disk} <= 90 )  { $diskWeight = 10; }
				elsif ( $reach{disk} <= 100 ) { $diskWeight = 1; }

				dbg("Reach for Disk disk=$reach{disk} diskWeight=$diskWeight");
			}

			# Very aggressive swap weighting, 11% swap is pretty healthy.
			if ( $reach{swap} )
			{
				if    ( $reach{swap} >= 95 ) { $swapWeight = 100; }
				elsif ( $reach{swap} >= 89 ) { $swapWeight = 95; }
				elsif ( $reach{swap} >= 70 ) { $swapWeight = 90; }
				elsif ( $reach{swap} >= 50 ) { $swapWeight = 70; }
				elsif ( $reach{swap} >= 30 ) { $swapWeight = 50; }
				elsif ( $reach{swap} >= 10 ) { $swapWeight = 30; }
				elsif ( $reach{swap} >= 0 )  { $swapWeight = 1; }

				dbg("Reach for Swap swap=$reach{swap} swapWeight=$swapWeight");
			}

			if    ( $reach{mem} >= 40 ) { $memWeight = 100; }
			elsif ( $reach{mem} >= 35 ) { $memWeight = 90; }
			elsif ( $reach{mem} >= 30 ) { $memWeight = 80; }
			elsif ( $reach{mem} >= 25 ) { $memWeight = 70; }
			elsif ( $reach{mem} >= 20 ) { $memWeight = 60; }
			elsif ( $reach{mem} >= 15 ) { $memWeight = 50; }
			elsif ( $reach{mem} >= 10 ) { $memWeight = 40; }
			elsif ( $reach{mem} >= 5 )  { $memWeight = 25; }
			elsif ( $reach{mem} >= 0 )  { $memWeight = 1; }
		}
		elsif ( getbool( $catchall_data->{collect} ) and $catchall_data->{nodeModel} eq "Generic" )
		{
			$cpuWeight = 100;
			$memWeight = 100;
			### ehg 16 sep 2002 also make interface aavilability 100% - I dont care about generic switches interface health !
			$reach{availability} = 100;
		}
		else
		{
			$cpuWeight = 100;
			$memWeight = 100;
			### 2012-12-13 keiths, removed this stoopid line as availability was allways 100%
			### $reach{availability} = 100;
		}

		# Added little fix for when no interfaces are collected.
		if ( $reach{availability} !~ /\d+/ )
		{
			$reach{availability} = "100";
		}

		# Makes 3Com memory health weighting always 100, and CPU, and Interface availibility
		if ( $catchall_data->{nodeModel} =~ /SSII 3Com/i )
		{
			$cpuWeight           = 100;
			$memWeight           = 100;
			$reach{availability} = 100;

		}

		# Makes CatalystIOS memory health weighting always 100.
		# Add Baystack and Accelar
		if ( $catchall_data->{nodeModel} =~ /CatalystIOS|Accelar|BayStack|Redback|FoundrySwitch|Riverstone/i )
		{
			$memWeight = 100;
		}

		info(
			"REACH Values: reachability=$reach{reachability} availability=$reach{availability} responsetime=$reach{responsetime}"
		);
		info("REACH Values: CPU reach=$reach{cpu} weight=$cpuWeight, MEM reach=$reach{mem} weight=$memWeight");

		if ( getbool( $catchall_data->{collect} ) and defined $S->{mdl}{interface}{nocollect}{ifDescr} )
		{
			dbg("Getting Interface Utilisation Health");
			$intcount   = 0;
			$intsummary = 0;

			# check if interface file exists - node may not be updated as yet....
			foreach my $index ( keys %{$IF} )
			{
				# Don't do any stats cause the interface is not one we collect
				if ( getbool( $IF->{$index}{collect} ) )
				{
					# Get the link availability from the local node!!!
					my $util = getSummaryStats(
						sys   => $S,
						type  => "interface",
						start => "-15 minutes",
						end   => time(),
						index => $index
					);
					if ( $util->{$index}{inputUtil} eq 'NaN' or $util->{$index}{outputUtil} eq 'NaN' )
					{
						dbg("SummaryStats for interface=$index of node $S->{name} skipped because value is NaN"
						);
						next;
					}

					# lets make the interface metric the largest of input or output
					my $intUtil = $util->{$index}{inputUtil};
					if ( $intUtil < $util->{$index}{outputUtil} )
					{
						$intUtil = $util->{$index}{outputUtil};
					}

					# only add interfaces with utilisation above metric_int_utilisation_above configuration option
					if ( $intUtil > $C->{'metric_int_utilisation_above'} or $C->{'metric_int_utilisation_above'} eq "" )
					{
						$intsummary = $intsummary + ( 100 - $intUtil );
						++$intcount;
						info(
							"Intf Summary util=$intUtil in=$util->{$index}{inputUtil} out=$util->{$index}{outputUtil} intsumm=$intsummary count=$intcount"
						);
					}
				}
			}    # FOR LOOP
			if ( $intsummary != 0 )
			{
				$intWeight = sprintf( "%.2f", $intsummary / $intcount );
			}
			else
			{
				$intWeight = "NaN";
			}
		}
		else
		{
			$intWeight = 100;
		}

		# if the interfaces are unhealthy and lost stats, whack a 100 in there
		if ( $intWeight eq "NaN" or $intWeight > 100 ) { $intWeight = 100; }

		# Would be cool to collect some interface utilisation bits here.
		# Maybe thresholds are the best way to handle that though.  That
		# would pickup the peaks better.

		# keeping the health values for storing in the RRD
		$reachabilityHealth = ( $reach{reachability} * $C->{weight_reachability} );
		$availabilityHealth = ( $reach{availability} * $C->{weight_availability} );
		$responseHealth     = ( $responseWeight * $C->{weight_response} );
		$cpuHealth          = ( $cpuWeight * $C->{weight_cpu} );
		$memHealth          = ( $memWeight * $C->{weight_mem} );
		$intHealth          = ( $intWeight * $C->{weight_int} );
		$swapHealth         = 0;
		$diskHealth         = 0;

		# the minimum value for health should always be 1
		$reachabilityHealth = 1 if $reachabilityHealth < 1;
		$availabilityHealth = 1 if $availabilityHealth < 1;
		$responseHealth     = 1 if $responseHealth < 1;
		$cpuHealth          = 1 if $cpuHealth < 1;

		# overload the int and mem with swap and disk
		if ( $reach{swap} )
		{
			$memHealth  = ( $memWeight * $C->{weight_mem} ) / 2;
			$swapHealth = ( $swapWeight * $C->{weight_mem} ) / 2;
			$memMax     = 100 * $C->{weight_mem} / 2;
			$swapMax    = 100 * $C->{weight_mem} / 2;

			# the minimum value for health should always be 1
			$memHealth  = 1 if $memHealth < 1;
			$swapHealth = 1 if $swapHealth < 1;
		}

		if ( $reach{disk} )
		{
			$intHealth  = ( $intWeight *  ( $C->{weight_int} / 2 ) );
			$diskHealth = ( $diskWeight * ( $C->{weight_int} / 2 ) );
			$intMax     = 100 * $C->{weight_int} / 2;
			$diskMax    = 100 * $C->{weight_int} / 2;

			# the minimum value for health should always be 1
			$intHealth  = 1 if $intHealth < 1;
			$diskHealth = 1 if $diskHealth < 1;
		}

		# Health is made up of a weighted values:
		### AS 16 Mar 02, implemented weights in nmis.conf
		$reach{health}
			= (   $reachabilityHealth
				+ $availabilityHealth
				+ $responseHealth
				+ $cpuHealth
				+ $memHealth
				+ $intHealth
				+ $diskHealth
				+ $swapHealth );

		info("Calculation of health=$reach{health}");
		if ( lc $reach{health} eq 'nan' )
		{
			dbg("Values Calc. reachability=$reach{reachability} * $C->{weight_reachability}");
			dbg("Values Calc. intWeight=$intWeight * $C->{weight_int}");
			dbg("Values Calc. responseWeight=$responseWeight * $C->{weight_response}");
			dbg("Values Calc. availability=$reach{availability} * $C->{weight_availability}");
			dbg("Values Calc. cpuWeight=$cpuWeight * $C->{weight_cpu}");
			dbg("Values Calc. memWeight=$memWeight * $C->{weight_mem}");
			dbg("Values Calc. swapWeight=$swapWeight * $C->{weight_mem}");
		}
	}

	# the node is collect=false and was pingable
	elsif ( !getbool( $catchall_data->{collect} ) and $pingresult == 100 )
	{
		$reach{reachability} = 100;
		$reach{availability} = 100;
		$reach{intfTotal}    = 'U';
		( $reach{responsetime}, $responseWeight ) = weightResponseTime( $reach{responsetime} );
		$reach{health} = ( $reach{reachability} * 0.9 ) + ( $responseWeight * 0.1 );
	}

	# there is a current outage for this node
	elsif ( ( $pingresult == 0 or $snmpresult == 0 ) and $outage eq 'current' )
	{
		$reach{reachability} = "U";
		$reach{availability} = "U";
		$reach{intfTotal}    = 'U';
		$reach{responsetime} = "U";
		$reach{health}       = "U";
		$reach{loss}         = "U";
	}

	# ping is working but SNMP is Down
	elsif ( $pingresult == 100 and $snmpresult == 0 )
	{
		$reach{reachability} = 80;                       # correct ? is up and degraded
		$reach{availability} = $intAvailValueWhenDown;
		$reach{intfTotal}    = 'U';
		$reach{health}       = "U";
	}

	# node is Down
	else
	{
		dbg("Node is Down using availability=$intAvailValueWhenDown");
		$reach{reachability} = 0;
		$reach{availability} = $intAvailValueWhenDown;
		$reach{responsetime} = "U";
		$reach{intfTotal}    = 'U';
		$reach{health}       = 0;
	}

	dbg("Reachability and Metric Stats Summary");
	dbg("collect=$catchall_data->{collect} (Node table)");
	dbg("ping=$pingresult (normalised)");
	dbg("cpuWeight=$cpuWeight (normalised)");
	dbg("memWeight=$memWeight (normalised)");
	dbg("swapWeight=$swapWeight (normalised)") if $swapWeight;
	dbg("intWeight=$intWeight (100 less the actual total interface utilisation)");
	dbg("diskWeight=$diskWeight");
	dbg("responseWeight=$responseWeight (normalised)");

	info("Reachability KPI=$reachabilityHealth/$reachabilityMax");
	info("Availability KPI=$availabilityHealth/$availabilityMax");
	info("Response KPI=$responseHealth/$responseMax");
	info("CPU KPI=$cpuHealth/$cpuMax");
	info("MEM KPI=$memHealth/$memMax");
	info("Int KPI=$intHealth/$intMax");
	info("Disk KPI=$diskHealth/$diskMax") if $diskHealth;
	info("SWAP KPI=$swapHealth/$swapMax") if $swapHealth;

	info("total number of interfaces=$reach{intfTotal}");
	info("total number of interfaces up=$reach{intfUp}");
	info("total number of interfaces collected=$reach{intfCollect}");
	info("total number of interfaces coll. up=$reach{intfColUp}");

	for $index ( sort keys %reach )
	{
		dbg("$index=$reach{$index}");
	}

	$reach{health} = ( $reach{health} > 100 ) ? 100 : $reach{health};
	my %reachVal;
	$reachVal{reachability}{value} = $reach{reachability};
	$reachVal{availability}{value} = $reach{availability};
	$reachVal{responsetime}{value} = $reach{responsetime};
	$reachVal{health}{value}       = $reach{health};

	$reachVal{reachabilityHealth}{value} = $reachabilityHealth;
	$reachVal{availabilityHealth}{value} = $availabilityHealth;
	$reachVal{responseHealth}{value}     = $responseHealth;
	$reachVal{cpuHealth}{value}          = $cpuHealth;
	$reachVal{memHealth}{value}          = $memHealth;
	$reachVal{intHealth}{value}          = $intHealth;
	$reachVal{diskHealth}{value}         = $diskHealth;
	$reachVal{swapHealth}{value}         = $swapHealth;

	$reachVal{loss}{value}          = $reach{loss};
	$reachVal{intfTotal}{value}     = $reach{intfTotal};
	$reachVal{intfUp}{value}        = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfUp};
	$reachVal{intfCollect}{value}   = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfCollect};
	$reachVal{intfColUp}{value}     = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfColUp};
	$reachVal{reachability}{option} = "gauge,0:100";
	$reachVal{availability}{option} = "gauge,0:100";
	### 2014-03-18 keiths, setting maximum responsetime to 30 seconds.
	$reachVal{responsetime}{option} = "gauge,0:30000";
	$reachVal{health}{option}       = "gauge,0:100";

	$reachVal{reachabilityHealth}{option} = "gauge,0:100";
	$reachVal{availabilityHealth}{option} = "gauge,0:100";
	$reachVal{responseHealth}{option}     = "gauge,0:100";
	$reachVal{cpuHealth}{option}          = "gauge,0:100";
	$reachVal{memHealth}{option}          = "gauge,0:100";
	$reachVal{intHealth}{option}          = "gauge,0:100";
	$reachVal{diskHealth}{option}         = "gauge,0:100";
	$reachVal{swapHealth}{option}         = "gauge,0:100";

	$reachVal{loss}{option}        = "gauge,0:100";
	$reachVal{intfTotal}{option}   = "gauge,0:U";
	$reachVal{intfUp}{option}      = "gauge,0:U";
	$reachVal{intfCollect}{option} = "gauge,0:U";
	$reachVal{intfColUp}{option}   = "gauge,0:U";

	# update the rrd or leave it to a caller?
	if ( !$donotupdaterrd )
	{
		my $db = $S->create_update_rrd( data => \%reachVal, type => "health" );    # database name is normally 'reach'
		if ( !$db )
		{
			logMsg( "ERROR updateRRD failed: " . getRRDerror() );
		}
	}
	if ( $catchall_data->{nodeModel} eq 'PingOnly' )
	{
		$S->ndinfo->{graphtype}{health} = "health-ping,response";
	}
	elsif ( $catchall_data->{nodeModel} eq 'ServiceOnly' )
	{
		$S->ndinfo->{graphtype}{health} = "";
	}
	else
	{
		$S->ndinfo->{graphtype}{health} = "health,kpi,response,numintf,polltime";
	}
	info("Finished");

	return \%reachVal;
}

#=========================================================================================

# this generates the data for nmis-interfaces.json,
# NOTE: this should not be required for NMISNG
sub getIntfAllInfo
{
	my $index;
	my $tmpDesc;
	my $intHash;
	my %interfaceInfo;

	### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
	if ( getbool( $C->{disable_interfaces_summary} ) )
	{
		logMsg("getIntfAllInfo disabled with disable_interfaces_summary=$C->{disable_interfaces_summary}");
		return;
	}

	dbg("Starting");

	dbg("Getting Interface Info from all nodes");

	my $nmisng = NMIS::new_nmisng();
	my $node_names = $nmisng->get_node_names();
	# Write a node entry for each node
	foreach my $node_name ( sort @$node_names )
	{
		my $nmisng_node = $nmisng->node( name => $node_name );
		my $configuration = $nmisng_node->configuration;
		if ( getbool( $configuration->{active} ) and getbool( $configuration->{collect} ) )
		{
			my $ids = $nmisng_node->get_inventory_ids(concept => 'interface');
			dbg( "ADD node=$node_name", 3 );
			logMsg("INFO empty interface info file of node $node_name") if(!$ids || @$ids < 1);
			foreach my $id ( @$ids )
			{
				my ($inventory,$error_message) = $nmisng_node->inventory( _id => $id );

				$nmisng->log->error("Failed to get inventory, error_message:$error_message") && next
					if(!$inventory);

				my $data = $inventory->data();
				$tmpDesc = &convertIfName( $data->{ifDescr} );

				$intHash = "$node_name-$tmpDesc";

				dbg( "$node_name $tmpDesc hash=$intHash $data->{ifDescr}", 3 );

				if ( $data->{ifDescr} ne "" )
				{
					dbg( "Add node=$node_name interface=$data->{ifDescr}", 2 );
					my $source = $data;
					my $dest = $interfaceInfo{$intHash} ||= {};

					$dest->{node} = $node_name;
					# TODO: revive this if we still need this function
					# $dest->{sysName} = $info->{system}->{sysName};

					for my $copyme (
						qw(ifIndex ifDescr collect real ifType ifSpeed ifAdminStatus
						ifOperStatus ifLastChange Description display_name portModuleIndex portIndex portDuplex portIfIndex
						portSpantreeFastStart vlanPortVlan portAdminSpeed)
						)
					{
						$dest->{$copyme} = $source->{$copyme};
					}

					my $cnt = 1;
					while ( defined( $source->{"ipAdEntAddr$cnt"} ) )
					{
						for my $copymeprefix (qw(ipAdEntAddr ipAdEntNetMask ipSubnet ipSubnetBits))
						{
							my $copyme = $copymeprefix . $cnt;
							$dest->{$copyme} = $source->{$copyme};
						}
						$cnt++;
					}
				}
			}

		}
	}    # foreach $linkname
	     # Write the interface table out.
	dbg("Writing Interface Info from all nodes");
	writeTable( dir => 'var', name => "nmis-interfaces", data => \%interfaceInfo );
	dbg("Finished");
}

#=========================================================================================

### create very rough outline hash of node information for caching
sub getNodeAllInfo
{
	my %Info;

	dbg("Starting");
	dbg("Getting Info from all nodes");

	my $NT = loadLocalNodeTable();

	# Write a node entry for each  node
	foreach my $node ( sort keys %{$NT} )
	{
		if ( getbool( $NT->{$node}{active} ) )
		{
			my $nodeInfo = loadNodeInfoTable($node);

			$Info{$node}{nodeVendor} = $nodeInfo->{system}{nodeVendor};
			$Info{$node}{nodeModel}  = $nodeInfo->{system}{nodeModel};
			$Info{$node}{nodeType}   = $nodeInfo->{system}{nodeType};
		}
	}

	# write to disk
	writeTable( dir => 'var', name => "nmis-nodeinfo", data => \%Info );
	dbg("Finished");
}

#=========================================================================================

# fixme: deprecated, will be removed once the last customers who're using models
# with this feature have upgraded to 8.5.6.
sub runCustomPlugins
{
	my %args = @_;
	my $S    = $args{sys};
	my $node = $args{node};

	dbg("Starting, node $node");
	foreach my $custom ( keys %{$S->{mdl}{custom}} )
	{
		if ( defined $S->{mdl}{custom}{$custom}{script} and $S->{mdl}{custom}{$custom}{script} ne "" )
		{
			dbg("Found Custom Script $S->{mdl}{custom}{$custom}{script}");

			#Only scripts in /usr/local/nmis8/admin can be run.
			my $exec = "$C->{'<nmis_base>'}/$S->{mdl}{custom}{$custom}{script} node=$node debug=$C->{debug}";
			my $out  = `$exec 2>&1`;
			if ( $out and $C->{debug} )
			{
				dbg($out);
			}
			elsif ($out)
			{
				logMsg($out);
			}
		}
	}
	dbg("Finished");
}

#=========================================================================================

sub weightResponseTime
{
	my $rt             = shift;
	my $responseWeight = 0;

	if ( $rt eq "" )
	{
		$rt             = "U";
		$responseWeight = 0;
	}
	elsif ( $rt !~ /^[0-9]/ )
	{
		$rt             = "U";
		$responseWeight = 0;
	}
	elsif ( $rt == 0 )
	{
		$rt             = 1;
		$responseWeight = 100;
	}
	elsif ( $rt >= 1500 ) { $responseWeight = 0; }
	elsif ( $rt >= 1000 ) { $responseWeight = 10; }
	elsif ( $rt >= 900 )  { $responseWeight = 20; }
	elsif ( $rt >= 800 )  { $responseWeight = 30; }
	elsif ( $rt >= 700 )  { $responseWeight = 40; }
	elsif ( $rt >= 600 )  { $responseWeight = 50; }
	elsif ( $rt >= 500 )  { $responseWeight = 60; }
	elsif ( $rt >= 400 )  { $responseWeight = 70; }
	elsif ( $rt >= 300 )  { $responseWeight = 80; }
	elsif ( $rt >= 200 )  { $responseWeight = 90; }
	elsif ( $rt >= 0 )    { $responseWeight = 100; }
	return ( $rt, $responseWeight );
}

#=========================================================================================

### 2011-12-29 keiths, centralising the copy of the remote files from slaves, so others can just load them.
sub nmisMaster
{
	my %args = @_;

	$C->{master_sleep} = 15 if $C->{master_sleep} eq "";

	if ( getbool( $C->{server_master} ) )
	{
		info("Running NMIS Master Functions");

		if ( $C->{master_sleep} or $sleep )
		{
			my $sleepNow = $C->{master_sleep};
			$sleepNow = $sleep if $sleep;
			info("Master is sleeping $sleepNow seconds (waiting for summary updates on slaves)");
			sleep $sleepNow;
		}

		my $ST = loadServersTable();
		for my $srv ( keys %{$ST} )
		{
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			info("Master, processing Slave Server $srv, $ST->{$srv}{host}");

			dbg("Get loadnodedetails from $srv");
			getFileFromRemote(
				server => $srv,
				func   => "loadnodedetails",
				group  => $ST->{$srv}{group},
				format => "text",
				file   => getFileName( file => "$C->{'<nmis_var>'}/nmis-${srv}-Nodes" )
			);

			dbg("Get sumnodetable from $srv");
			getFileFromRemote(
				server => $srv,
				func   => "sumnodetable",
				group  => $ST->{$srv}{group},
				format => "text",
				file   => getFileName( file => "$C->{'<nmis_var>'}/nmis-${srv}-nodesum" )
			);

			my @hours = qw(8 16);
			foreach my $hour (@hours)
			{
				my $function = "summary" . $hour . "h";
				dbg("get summary$hour from $srv");
				getFileFromRemote(
					server => $srv,
					func   => "summary$hour",
					group  => $ST->{$srv}{group},
					format => "text",
					file   => getFileName( file => "$C->{'<nmis_var>'}/nmis-$srv-$function" )
				);
			}
		}
	}
}

#=========================================================================================

# preload all summary stats - for metric update and dashboard display.
sub nmisSummary
{
	my %args = @_;

	my $pollTimer = NMIS::Timing->new;

	dbg("Calculating NMIS network stats for cgi cache");
	func::update_operations_stamp( type => "summary", start => $starttime, stop => undef )
		if ( $type eq "summary" );    # not if part of collect

	my $S = Sys->new;

	### 2014-08-28 keiths, configurable metric periods
	my $metricsFirstPeriod
		= defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod
		= defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

	summaryCache( sys => $S, file => 'nmis-summary8h', start => $metricsFirstPeriod, end => time() );
	my $k = summaryCache(
		sys   => $S,
		file  => 'nmis-summary16h',
		start => $metricsSecondPeriod,
		end   => $metricsFirstPeriod
	);

	my $NS = getNodeSummary( C => $C );
	my $file = "nmis-nodesum";
	writeTable( dir => 'var', name => $file, data => $NS );
	dbg("Finished calculating NMIS network stats for cgi cache - wrote $k nodes");
	func::update_operations_stamp( type => "summary", start => $starttime, stop => Time::HiRes::time() )
		if ( $type eq "summary" );    # not if part of collect

	if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) )
	{
		my $polltime = $pollTimer->elapTime();
		logMsg("Poll Time: $polltime");
	}
}

sub summaryCache
{
	my %args        = @_;
	my $S           = $args{sys};
	my $file        = $args{file};
	my $start       = $args{start};
	my $end         = $args{end};
	my %summaryHash = ();
	my $NT          = loadLocalNodeTable();


	foreach my $node ( keys %{$NT} )
	{
		if ( getbool( $NT->{$node}{active} ) )
		{
			$S->init( name => $node, snmp => 'false' );
			my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

			$summaryHash{$node}{reachable}   = 'NaN';
			$summaryHash{$node}{response}    = 'NaN';
			$summaryHash{$node}{loss}        = 'NaN';
			$summaryHash{$node}{health}      = 'NaN';
			$summaryHash{$node}{available}   = 'NaN';
			$summaryHash{$node}{intfCollect} = 0;
			$summaryHash{$node}{intfColUp}   = 0;
			my $stats;

			if ( $stats = getSummaryStats( sys => $S, type => "health", start => $start, end => $end, index => $node ) )
			{
				%summaryHash = ( %summaryHash, %{$stats} );
			}
			if ( getbool( $catchall_data->{nodedown} ) )
			{
				$summaryHash{$node}{nodedown} = 'true';
			}
			else
			{
				$summaryHash{$node}{nodedown} = 'false';
			}
		}
	}

	writeTable( dir => 'var', name => $file, data => \%summaryHash );

	return ( scalar keys %summaryHash );
}

#=========================================================================================

### Added escalate 0, to allow fast escalation and to implement
### consistent policies for notification.  This also helps to get rid of flapping
### things, ie if escalate0 = 5 then an interface goes down, no alert sent, next
### poll interface goes up and event cancelled!  Downside is a little longer before
### receiving first notification, so it depends on what the support SLA is.

### 11-Nov-11, keiths, update to this, changed the escalation so that through policy you can
### wait for 5 mins or just notify now, so Ecalation0 is 0 seconds, Escalation1 is 300 seconds
### then in Ecalations.xxxx, core devices might notify at Escalation0 while others at Escalation1
sub runEscalate
{
	my %args = @_;

	my $pollTimer = NMIS::Timing->new;

	my $C  = loadConfTable();
	my $NT = loadLocalNodeTable();

	my $nmisng = NMIS::new_nmisng();

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


	dbg("Starting");
	func::update_operations_stamp( type => "escalate", start => $starttime, stop => undef )
		if ( $type eq "escalate" );    # not if part of collect
	                                   # load Contacts table
	my $CT = loadContactsTable();

	# load the escalation policy table
	my $EST = loadEscalationsTable();

	### 2013-08-07 keiths, taking to long when MANY interfaces e.g. > 200,000
	# load the interface file to later check interface collect status.
	#my $II = loadInterfaceInfo();

	my $LocationsTable = loadLocationsTable();

	### keiths, work around for extra tables.
	my $ServiceStatusTable;
	my $useServiceStatusTable = 0;
	if ( tableExists('ServiceStatus') )
	{
		$ServiceStatusTable    = loadGenericTable('ServiceStatus');
		$useServiceStatusTable = 1;
	}

	my $BusinessServicesTable;
	my $useBusinessServicesTable = 0;
	if ( tableExists('BusinessServices') )
	{
		$BusinessServicesTable    = loadGenericTable('BusinessServices');
		$useBusinessServicesTable = 1;
	}

	# the events configuration table, controls active/notify/logging for each known event
	my $events_config = loadTable( dir => 'conf', name => 'Events' )
		;    # cannot use loadGenericTable as that checks and clashes with db_events_sql

	# add a full format time string for emails and message notifications
	# pull the system timezone and then the local time
	my $msgtime = get_localtime();

	# first load all non-historic events for all nodes
	my %allevents = loadAllEvents;

	# then send UP events to all those contacts to be notified as part of the escalation procedure
	# this loop skips ALL marked-as-current events!
	# current flag in event means: DO NOT TOUCH IN ESCALATE, STILL ALIVE AND ACTIVE
	# we might rename that transition t/f, and have this function handle only the ones with transition true.
	my @mustupnotify = grep( !getbool( $allevents{$_}->{current} ), keys %allevents );
	for my $eventkey (@mustupnotify)
	{
		my $thisevent = $allevents{$eventkey};

		# if the event is configured for no notify, do nothing
		my $thisevent_control = $events_config->{$thisevent->{event}}
			|| {Log => "true", Notify => "true", Status => "true"};

		# in case of Notify being off for this event, we don't have to check/walk/handle any notify fields at all
		# as we're deleting the record after the loop anyway.
		if ( getbool( $thisevent_control->{Notify} ) )
		{
			foreach my $field ( split( ',', $thisevent->{notify} ) )    # field = type:contact
			{
				$target = "";
				my @x    = split /:/, $field;
				my $type = shift @x;                                    # netsend, email, or pager ?
				dbg("Escalation type=$type contact=$contact");

				if ( $type =~ /email|ccopy|pager/ )
				{
					foreach $contact (@x)
					{
						if ( exists $CT->{$contact} )
						{
							if ( dutyTime( $CT, $contact ) )
							{                                           # do we have a valid dutytime ??
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
							dbg("Contact $contact not found in Contacts table");
						}
					}    #foreach

# no email targets found, and if default contact not found, assume we are not covering 24hr dutytime in this slot, so no mail.
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
						dbg("No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target"
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
									= "NMIS: UP Notify $thisevent->{node} Normal $thisevent->{event} $thisevent->{element}";
								$serial_ns++;
							}
							else
							{
								if ( $type eq "ccopy" )
								{
									$message  = "FOR INFORMATION ONLY\n";
									$priority = &eventToSMTPPri("Normal");
								}
								else
								{
									$priority = &eventToSMTPPri( $thisevent->{level} );
								}
								$event_age = convertSecsHours( time - $thisevent->{startdate} );

								$message
									.= "Node:\t$thisevent->{node}\nUP Event Notification\nEvent Elapsed Time:\t$event_age\nEvent:\t$thisevent->{event}\nElement:\t$thisevent->{element}\nDetails:\t$thisevent->{details}\n\n";

								if ( getbool( $C->{mail_combine} ) )
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
										= "$thisevent->{node} $thisevent->{event} - $thisevent->{element} - $thisevent->{details} at $msgtime";
									$msgTable{$type}{$trgt}{$serial}{message}  = $message;
									$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
									$msgTable{$type}{$trgt}{$serial}{count}    = 1;
									$serial++;
								}
							}
						}

						# log the meta event, ONLY if both Log (and Notify) are enabled
						logEvent(
							node    => $thisevent->{node},
							event   => "$type to $target UP Notify",
							level   => "Normal",
							element => $thisevent->{element},
							details => $thisevent->{details}
						) if ( getbool( $thisevent_control->{Log} ) );

						dbg("Escalation $type UP Notification node=$thisevent->{node} target=$target level=$thisevent->{level} event=$thisevent->{event} element=$thisevent->{element} details=$thisevent->{details} group=$NT->{$thisevent->{node}}{group}"
						);
					}
				}    # end email,ccopy,pager
				     # now the netsends
				elsif ( $type eq "netsend" )
				{
					my $message
						= "UP Event Notification $thisevent->{node} Normal $thisevent->{event} $thisevent->{element} $thisevent->{details} at $msgtime";
					foreach my $trgt (@x)
					{
						$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
						$serial_ns++;
						dbg("NetSend $message to $trgt");

						# log the meta event, ONLY if both Log (and Notify) are enabled
						logEvent(
							node    => $thisevent->{node},
							event   => "NetSend $message to $trgt UP Notify",
							level   => "Normal",
							element => $thisevent->{element},
							details => $thisevent->{details}
						) if ( getbool( $thisevent_control->{Log} ) );
					}    #foreach
				}    # end netsend
				elsif ( $type eq "syslog" )
				{
					if ( getbool( $C->{syslog_use_escalation} ) )    # syslog action
					{
						my $timenow = time();
						my $message
							= "NMIS_Event::$C->{server_name}::$timenow,$thisevent->{node},$thisevent->{event},$thisevent->{level},$thisevent->{element},$thisevent->{details}";
						my $priority = eventToSyslog( $thisevent->{level} );

						foreach my $trgt (@x)
						{
							$msgTable{$type}{$trgt}{$serial_ns}{message}  = $message;
							$msgTable{$type}{$trgt}{$serial_ns}{priority} = $priority;
							$serial_ns++;
							dbg("syslog $message");
						}    #foreach
					}
				}    # end syslog
				elsif ( $type eq "json" )
				{
					# log the event as json file, AND save those updated bits back into the
					# soon-to-be-deleted/archived event record.
					my $node = $NT->{$thisevent->{node}};
					$thisevent->{nmis_server} = $C->{server_name};
					$thisevent->{customer}    = $node->{customer};
					$thisevent->{location}    = $LocationsTable->{$node->{location}}{Location};
					$thisevent->{geocode}     = $LocationsTable->{$node->{location}}{Geocode};

					if ($useServiceStatusTable)
					{
						$thisevent->{serviceStatus}  = $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
						$thisevent->{statusPriority} = $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
					}

					if ($useBusinessServicesTable)
					{
						$thisevent->{businessService}
							= $BusinessServicesTable->{$node->{businessService}}{businessService};
						$thisevent->{businessPriority}
							= $BusinessServicesTable->{$node->{businessService}}{businessPriority};
					}

					# Copy the fields from nodes to the event
					my @nodeFields = split( ",", $C->{'json_node_fields'} );
					foreach my $field (@nodeFields)
					{
						$thisevent->{$field} = $node->{$field};
					}

					logJsonEvent( event => $thisevent, dir => $C->{'json_logs'} );

					# may sound silly to update-then-archive but i'd rather have the historic event record contain
					# the full story
					if ( my $err = eventUpdate( event => $thisevent ) )
					{
						logMsg("ERROR $err");
					}
				}    # end json
				     # any custom notification methods?
				else
				{
					if ( checkPerlLib("Notify::$type") )
					{
						dbg("Notify::$type $contact");

						my $timenow = time();
						my $datenow = returnDateStamp();
						my $message
							= "$datenow: $thisevent->{node}, $thisevent->{event}, $thisevent->{level}, $thisevent->{element}, $thisevent->{details}";
						foreach $contact (@x)
						{
							if ( exists $CT->{$contact} )
							{
								if ( dutyTime( $CT, $contact ) )
								{    # do we have a valid dutytime ??
									    # check if UpNotify is true, and save with this event
									    # and send all the up event notifies when the event is cleared.
									if ( getbool( $EST->{$esc_key}{UpNotify} )
										and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i )
									{
										my $ct = "$type:$contact";
										my @l = split( ',', $thisevent->{notify} );
										if ( not grep { $_ eq $ct } @l )
										{
											push @l, $ct;
											$thisevent->{notify}
												= join( ',', @l );   # note: updated only for msgtable below, NOT saved!
										}
									}

									#$serial
									$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
									$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
									$msgTable{$type}{$contact}{$serial_ns}{event}   = $thisevent;
									$serial_ns++;
								}
							}
							else
							{
								dbg("Contact $contact not found in Contacts table");
							}
						}
					}
					else
					{
						dbg("ERROR runEscalate problem with escalation target unknown at level$thisevent->{escalate} $level type=$type"
						);
					}
				}
			}
		}

		# now remove this event
		if ( my $err = eventDelete( event => $thisevent ) )
		{
			logMsg("ERROR $err");
		}
		delete $allevents{$eventkey};    # ditch the removed event in the in-mem snapshot, too.
	}

	#===========================================
	my $stateless_event_dampening = $C->{stateless_event_dampening} || 900;

	# now handle the actual escalations; only events marked-as-current are left now.
LABEL_ESC:
	for my $eventkey ( keys %allevents )
	{
		my $thisevent  = $allevents{$eventkey};
		my $mustupdate = undef;                   # live changes to thisevent are ok, but saved back ONLY if this is set
		dbg("processing event $eventkey");

		# checking if event is stateless and dampen time has passed.
		if ( getbool( $thisevent->{stateless} ) and time() > $thisevent->{startdate} + $stateless_event_dampening )
		{
			# yep, remove the event completely.
			dbg("stateless event $thisevent->{event} has exceeded dampening time of $stateless_event_dampening seconds."
			);
			eventDelete( event => $thisevent );
		}

		# set event control to policy or default=enabled.
		my $thisevent_control = $events_config->{$thisevent->{event}}
			|| {Log => "true", Notify => "true", Status => "true"};

		my $nd = $thisevent->{node};

		# lets start with checking that we have a valid node - the node may have been deleted.
		# note: loadAllEvents() doesn't return events for vanished nodes (but for inactive ones it does)
		if ( !$NT->{$nd} or getbool( $NT->{$nd}{active}, "invert" ) )
		{
			if (    getbool( $thisevent_control->{Log} )
				and getbool( $thisevent_control->{Notify} ) )    # meta-events are subject to both Notify and Log
			{
				logEvent(
					node    => $nd,
					event   => "Deleted Event: $thisevent->{event}",
					level   => $thisevent->{level},
					element => $thisevent->{element},
					details => $thisevent->{details}
				);

				my $timenow = time();
				my $message
					= "NMIS_Event::$C->{server_name}::$timenow,$thisevent->{node},Deleted Event: $thisevent->{event},$thisevent->{level},$thisevent->{element},$thisevent->{details}";
				my $priority = eventToSyslog( $thisevent->{level} );
				sendSyslog(
					server_string => $C->{syslog_server},
					facility      => $C->{syslog_facility},
					message       => $message,
					priority      => $priority
				);
			}

			logMsg("INFO ($nd) Node not active, deleted Event=$thisevent->{event} Element=$thisevent->{element}");
			eventDelete( event => $thisevent );

			next LABEL_ESC;
		}

		### 2013-08-07 keiths, taking too long when MANY interfaces e.g. > 200,000
		if (    $thisevent->{event} =~ /interface/i
			and $thisevent->{event} !~ /proactive/i )
		{
			### load the interface information and check the collect status.
			my $S = Sys->new;    # node object
			if ( ( $S->init( name => $nd, snmp => 'false' ) ) )
			{                    # get cached info of node only
				my $IFD = $S->ifDescrInfo();    # interface info indexed by ifDescr
				if ( !getbool( $IFD->{$thisevent->{element}}{collect} ) )
				{
					# meta events are subject to both Log and Notify controls
					if ( getbool( $thisevent_control->{Log} ) and getbool( $thisevent_control->{Notify} ) )
					{
						logEvent(
							node    => $thisevent->{node},
							event   => "Deleted Event: $thisevent->{event}",
							level   => $thisevent->{level},
							element => " no matching interface or no collect Element=$thisevent->{element}"
						);
					}
					logMsg(
						"INFO ($thisevent->{node}) Interface not active, deleted Event=$thisevent->{event} Element=$thisevent->{element}"
					);

					eventDelete( event => $thisevent );
					next LABEL_ESC;
				}
			}
		}

		# if an planned outage is in force, keep writing the start time of any unack event to the current start time
		# so when the outage expires, and the event is still current, we escalate as if the event had just occured
		my ( $outage, undef ) = outageCheck( node => $thisevent->{node}, time => time() );
		dbg("Outage for $thisevent->{node} is $outage");
		if ( $outage eq "current" and getbool( $thisevent->{ack}, "invert" ) )
		{
			$thisevent->{startdate} = time();
			if ( my $err = eventUpdate( event => $thisevent ) )
			{
				logMsg("ERROR $err");
			}
		}

		# set the current outage time
		$outage_time = time() - $thisevent->{startdate};

		# if we are to escalate, this event must not be part of a planned outage and un-ack.
		if ( $outage ne "current" and getbool( $thisevent->{ack}, "invert" ) )
		{
			# we have list of nodes that this node depends on in $NT->{$runnode}{depend}
			# if any of those have a current Node Down alarm, then lets just move on with a debug message
			# should we log that we have done this - maybe not....

			if ( $NT->{$thisevent->{node}}{depend} ne '' )
			{
				foreach my $node_depend ( split /,/, $NT->{$thisevent->{node}}{depend} )
				{
					next if $node_depend eq "N/A";                 # default setting
					next if $node_depend eq $thisevent->{node};    # remove the catch22 of self dependancy.
					                                               #only do dependancy if node is active.
					if ( defined $NT->{$node_depend}{active} and getbool( $NT->{$node_depend}{active} ) )
					{
						if ( my $event_exists = eventExist( $node_depend, "Node Down", undef ) )
						{
							my $erec = eventLoad( filename => $event_exists ) if ($event_exists);
							if ( ref($erec) eq "HASH" and $erec->{current} )
							{
								dbg("NOT escalating $thisevent->{node} $thisevent->{event} as dependant $node_depend is reported as down"
								);
								next LABEL_ESC;
							}
						}
					}
				}
			}

			undef %keyhash;    # clear this every loop
			$escalate = $thisevent->{escalate};    # save this as a flag

			# now depending on the event escalate the event up a level or so depending on how long it has been active
			# now would be the time to notify as to the event. node down every 15 minutes, interface down every 4 hours?
			# maybe a deccreasing run 15,30,60,2,4,etc
			# proactive events would be escalated daily
			# when escalation hits 10 they could auto delete?
			# core, distrib and access could escalate at different rates.

			# note - all sent to lowercase here to get a match
			# my $NI = loadNodeInfoTable( $thisevent->{node}, suppress_errors => 1 );

			my $nmisng_node = $nmisng->node( name => $thisevent->{node} );
			my ($catchall_inventory,$error_message) = $nmisng_node->inventory( concept => "catchall" );
			$nmisng->log->error("Failed to get catchall inventory for node:$thisevent->{node}, error_message:$error_message") && next
				if(!$catchall_inventory);
			# in this case we have no guarantee that we have catchall and if we don't creating it is pointless.
			my $catchall_data = $catchall_inventory->data_live();
			$group = lc( $catchall_data->{group} );
			$role  = lc( $catchall_data->{roleType} );
			$type  = lc( $catchall_data->{nodeType} );
			$event = lc( $thisevent->{event} );

			dbg("looking for Event to Escalation Table match for Event[ Node:$thisevent->{node} Event:$event Element:$thisevent->{element} ]"
			);
			dbg("and node values node=$thisevent->{node} group=$group role=$role type=$type");

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
					if (    $klst eq $esc_short
						and $thisevent->{node} =~ /$EST->{$esc}{Event_Node}/i
						and $thisevent->{element} =~ /$EST->{$esc}{Event_Element}/i )
					{
						$keyhash{$esc} = $klst;
						dbg("match found for escalation key=$esc");
					}
					else
					{
						#dbg("no match found for escalation key=$esc, esc_short=$esc_short");
					}
				}
			}

			my $cnt_hash = keys %keyhash;
			dbg("$cnt_hash match(es) found for $thisevent->{node}");

			foreach $esc_key ( keys %keyhash )
			{
				dbg("Matched Escalation Table Group:$EST->{$esc_key}{Group} Role:$EST->{$esc_key}{Role} Type:$EST->{$esc_key}{Type} Event:$EST->{$esc_key}{Event} Event_Node:$EST->{$esc_key}{Event_Node} Event_Element:$EST->{$esc_key}{Event_Element}"
				);
				dbg("Pre Escalation : $thisevent->{node} Event $thisevent->{event} is $outage_time seconds old escalation is $thisevent->{escalate}"
				);

				# default escalation for events
				# 28 apr 2003 moved times to nmis.conf
				for my $esclevel ( reverse( 0 .. 10 ) )
				{
					if ( $outage_time >= $C->{"escalate$esclevel"} )
					{
						$mustupdate = 1 if ( $thisevent->{escalate} != $esclevel );    # if level has changed
						$thisevent->{escalate} = $esclevel;
						last;
					}
				}

				dbg("Post Escalation: $thisevent->{node} Event $thisevent->{event} is $outage_time seconds old, escalation is $thisevent->{escalate}"
				);
				if ( $C->{debug} and $escalate == $thisevent->{escalate} )
				{
					my $level = "Level" . ( $thisevent->{escalate} + 1 );
					dbg("Next Notification Target would be $level");
					dbg( "Contact: " . $EST->{$esc_key}{$level} );
				}

				# send a new email message as the escalation again.
				# ehg 25oct02 added win32 netsend message type (requires SAMBA on this host)
				if ( $escalate != $thisevent->{escalate} )
				{
					$event_age = convertSecsHours( time - $thisevent->{startdate} );
					$time      = &returnDateStamp;

					# get the string of type email:contact1:contact2,netsend:contact1:contact2,\
					# pager:contact1:contact2,email:sysContact
					$level = lc( $EST->{$esc_key}{'Level' . $thisevent->{escalate}} );

					if ( $level ne "" )
					{
						# Now we have a string, check for multiple notify types
						foreach $field ( split ",", $level )
						{
							$target = "";
							@x      = split /:/, lc $field;
							$type   = shift @x;               # first entry is email, ccopy, netsend or pager

							dbg("Escalation type=$type");

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
											dbg("Using node $thisevent->{node} sysContact $catchall_data->{sysContact}");
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
										if (    getbool( $EST->{$esc_key}{UpNotify} )
											and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i
											and getbool( $thisevent_control->{Notify} ) )
										{
											my $ct = "$type:$contact";
											my @l = split( ',', $thisevent->{notify} );
											if ( not grep { $_ eq $ct } @l )
											{
												push @l, $ct;
												$thisevent->{notify} = join( ',', @l );
												$mustupdate = 1;
											}
										}
									}

									if ( exists $CT->{$contact} )
									{
										if ( dutyTime( $CT, $contact ) )
										{    # do we have a valid dutytime ??
											$contactDutyTime = 1;

											# Duty Time is OK check level match
											if ( $CT->{$contact}{Level} eq "" )
											{
												dbg("SEND Contact $contact no filtering by Level defined");
												$contactLevelSend = 1;
											}
											elsif ( $thisevent->{level} =~ /$CT->{$contact}{Level}/i )
											{
												dbg("SEND Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $thisevent->{level}"
												);
												$contactLevelSend = 1;
											}
											elsif ( $thisevent->{level} !~ /$CT->{$contact}{Level}/i )
											{
												dbg("STOP Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $thisevent->{level}"
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
											if (    getbool( $EST->{$esc_key}{UpNotify} )
												and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i
												and getbool( $thisevent_control->{Notify} ) )
											{
												my $ct = "$type:$contact";
												my @l = split( ',', $thisevent->{notify} );
												if ( not grep { $_ eq $ct } @l )
												{
													push @l, $ct;
													$thisevent->{notify} = join( ',', @l );
													$mustupdate = 1;
												}
											}
										}
										else
										{
											dbg("STOP Contact duty time: $contactDutyTime, contact level: $contactLevelSend"
											);
										}
									}
									else
									{
										dbg("Contact $contact not found in Contacts table");
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
									dbg("No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target"
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
											if ( getbool( $thisevent_control->{Notify} ) )
											{
												$msgTable{$type}{$trgt}{$serial_ns}{message}
													= "NMIS: Esc. $thisevent->{escalate} $event_age $thisevent->{node} $thisevent->{level} $thisevent->{event} $thisevent->{details}";
												$serial_ns++;
											}
										}
										else
										{
											if ( $type eq "ccopy" )
											{
												$message  = "FOR INFORMATION ONLY\n";
												$priority = &eventToSMTPPri("Normal");
											}
											else
											{
												$priority = &eventToSMTPPri( $thisevent->{level} );
											}

											###2013-10-08 arturom, keiths, Added link to interface name if interface event.
											$C->{nmis_host_protocol} = "http" if $C->{nmis_host_protocol} eq "";
											$message
												.= "Node:\t$thisevent->{node}\nNotification at Level$thisevent->{escalate}\nEvent Elapsed Time:\t$event_age\nSeverity:\t$thisevent->{level}\nEvent:\t$thisevent->{event}\nElement:\t$thisevent->{element}\nDetails:\t$thisevent->{details}\nLink to Node: $C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_node_view&widget=false&node=$thisevent->{node}\n";
											if ( $thisevent->{event} =~ /Interface/ )
											{
												my $ifIndex = undef;
												my $S       = Sys->new;    # node object
												if ( ( $S->init( name => $thisevent->{node}, snmp => 'false' ) ) )
												{                          # get cached info of node only
													my $IFD = $S->ifDescrInfo();    # interface info indexed by ifDescr
													if ( getbool( $IFD->{$thisevent->{element}}{collect} ) )
													{
														$ifIndex = $IFD->{$thisevent->{element}}{ifIndex};
														$message
															.= "Link to Interface:\t$C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_interface_view&widget=false&node=$thisevent->{node}&intf=$ifIndex\n";
													}
												}
											}
											$message .= "\n";

											if ( getbool( $thisevent_control->{Notify} ) )
											{
												if ( getbool( $C->{mail_combine} ) )
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
														= "$thisevent->{node} $thisevent->{event} - $thisevent->{element} - $thisevent->{details} at $msgtime";
													$msgTable{$type}{$trgt}{$serial}{message}  = $message;
													$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
													$msgTable{$type}{$trgt}{$serial}{count}    = 1;
													$serial++;
												}
											}
										}
									}

									# meta-events are subject to Notify and Log
									logEvent(
										node    => $thisevent->{node},
										event   => "$type to $target Esc$thisevent->{escalate} $thisevent->{event}",
										level   => $thisevent->{level},
										element => $thisevent->{element},
										details => $thisevent->{details}
										)
										if (getbool( $thisevent_control->{Notify} )
										and getbool( $thisevent_control->{Log} ) );

									dbg("Escalation $type Notification node=$thisevent->{node} target=$target level=$thisevent->{level} event=$thisevent->{event} element=$thisevent->{element} details=$thisevent->{details} group=$NT->{$thisevent->{node}}{group}"
									);
								}    # if $target
							}    # end email,ccopy,pager

							# now the netsends
							elsif ( $type eq "netsend" )
							{
								if ( getbool( $thisevent_control->{Notify} ) )
								{
									my $message
										= "Escalation $thisevent->{escalate} $thisevent->{node} $thisevent->{level} $thisevent->{event} $thisevent->{element} $thisevent->{details} at $msgtime";
									foreach my $trgt (@x)
									{
										$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
										$serial_ns++;
										dbg("NetSend $message to $trgt");

										# meta-events are subject to both
										logEvent(
											node    => $thisevent->{node},
											event   => "NetSend $message to $trgt $thisevent->{event}",
											level   => $thisevent->{level},
											element => $thisevent->{element},
											details => $thisevent->{details}
										) if ( getbool( $thisevent_control->{Log} ) );
									}    #foreach
								}
							}    # end netsend
							elsif ( $type eq "syslog" )
							{
								# check if UpNotify is true, and save with this event
								# and send all the up event notifies when the event is cleared.
								if (    getbool( $EST->{$esc_key}{UpNotify} )
									and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i
									and getbool( $thisevent_control->{Notify} ) )
								{
									my $ct = "$type:server";
									my @l = split( ',', $thisevent->{notify} );
									if ( not grep { $_ eq $ct } @l )
									{
										push @l, $ct;
										$thisevent->{notify} = join( ',', @l );
										$mustupdate = 1;
									}
								}

								if ( getbool( $thisevent_control->{Notify} ) )
								{
									my $timenow = time();
									my $message
										= "NMIS_Event::$C->{server_name}::$timenow,$thisevent->{node},$thisevent->{event},$thisevent->{level},$thisevent->{element},$thisevent->{details}";
									my $priority = eventToSyslog( $thisevent->{level} );
									if ( getbool( $C->{syslog_use_escalation} ) )
									{
										foreach my $trgt (@x)
										{
											$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
											$msgTable{$type}{$trgt}{$serial}{priority}   = $priority;
											$serial_ns++;
											dbg("syslog $message");
										}    #foreach
									}
								}
							}    # end syslog
							elsif ( $type eq "json" )
							{
								if (    getbool( $EST->{$esc_key}{UpNotify} )
									and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i
									and getbool( $thisevent_control->{Notify} ) )
								{
									my $ct = "$type:server";
									my @l = split( ',', $thisevent->{notify} );
									if ( not grep { $_ eq $ct } @l )
									{
										push @l, $ct;
										$thisevent->{notify} = join( ',', @l );
										$mustupdate = 1;
									}
								}

								# amend the event - attention: this changes the live event,
								# and will be saved back!
								$mustupdate = 1;
								my $node = $NT->{$thisevent->{node}};
								$thisevent->{nmis_server} = $C->{server_name};
								$thisevent->{customer}    = $node->{customer};
								$thisevent->{location}    = $LocationsTable->{$node->{location}}{Location};
								$thisevent->{geocode}     = $LocationsTable->{$node->{location}}{Geocode};

								if ($useServiceStatusTable)
								{
									$thisevent->{serviceStatus}
										= $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
									$thisevent->{statusPriority}
										= $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
								}

								if ($useBusinessServicesTable)
								{
									$thisevent->{businessService}
										= $BusinessServicesTable->{$node->{businessService}}{businessService};
									$thisevent->{businessPriority}
										= $BusinessServicesTable->{$node->{businessService}}{businessPriority};
								}

								# Copy the fields from nodes to the event
								my @nodeFields = split( ",", $C->{'json_node_fields'} );
								foreach my $field (@nodeFields)
								{
									$thisevent->{$field} = $node->{$field};
								}

								logJsonEvent( event => $thisevent, dir => $C->{'json_logs'} )
									if ( getbool( $thisevent_control->{Notify} ) );
							}    # end json
							elsif ( getbool( $thisevent_control->{Notify} ) )
							{
								if ( checkPerlLib("Notify::$type") )
								{
									dbg("Notify::$type $contact");
									my $timenow = time();
									my $datenow = returnDateStamp();
									my $message
										= "$datenow: $thisevent->{node}, $thisevent->{event}, $thisevent->{level}, $thisevent->{element}, $thisevent->{details}";
									foreach $contact (@x)
									{
										if ( exists $CT->{$contact} )
										{
											if ( dutyTime( $CT, $contact ) )
											{    # do we have a valid dutytime ??
												    # check if UpNotify is true, and save with this event
												    # and send all the up event notifies when the event is cleared.
												if ( getbool( $EST->{$esc_key}{UpNotify} )
													and $thisevent->{event} =~ /$C->{upnotify_stateful_events}/i )
												{
													my $ct = "$type:$contact";
													my @l = split( ',', $thisevent->{notify} );
													if ( not grep { $_ eq $ct } @l )
													{
														push @l, $ct;
														$thisevent->{notify} = join( ',', @l );    # fudged up
														$mustupdate = 1;
													}
												}

												#$serial
												$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
												$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
												$msgTable{$type}{$contact}{$serial_ns}{event}   = $thisevent;
												$serial_ns++;
											}
										}
										else
										{
											dbg("Contact $contact not found in Contacts table");
										}
									}
								}
								else
								{
									dbg("ERROR runEscalate problem with escalation target unknown at level$thisevent->{escalate} $level type=$type"
									);
								}
							}
						}    # foreach field
					}    # endif $level
				}    # if escalate
			}    # foreach esc_key
		}    # end of outage check

# now we're done with this event, let's update it if we have to - and if nobody has deleted the event since the start of this update run (as we're not locking this globally) - eventkey is the full filename
		if ( $mustupdate && -f $eventkey )
		{
			if ( my $err = eventUpdate( event => $thisevent ) )
			{
				logMsg("ERROR $err");
			}
		}
	}

	# Cologne, send the messages now
	sendMSG( data => \%msgTable );
	dbg("Finished");
	if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) )
	{
		my $polltime = $pollTimer->elapTime();
		logMsg("Poll Time: $polltime");
	}
	func::update_operations_stamp(
		type  => "escalate",
		start => $starttime,
		stop  => Time::HiRes::time()
	) if ( $type eq "escalate" );    # not if part of collect
}    # end runEscalate

#=========================================================================================

#
# structure of the hash:
# device name => email, ccopy, netsend, pager
#	target
#  		serial
#			subject
#			message
#			priority
# Cologne.

sub sendMSG
{
	my %args     = @_;
	my $msgTable = $args{data};
	my $C        = loadConfTable();    # get ref

	my $target;
	my $serial;
	dbg("Starting");

	foreach my $method ( keys %$msgTable )
	{
		dbg("Method $method");
		if ( $method eq "email" )
		{

			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach $target ( keys %{$msgTable->{$method}} )
			{
				foreach $serial ( keys %{$msgTable->{$method}{$target}} )
				{
					next if $C->{mail_server} eq '';

					my ( $status, $code, $errmsg ) = sendEmail(

						# params for connection and sending
						sender     => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello      => $C->{mail_domain},
						usetls     => $C->{mail_use_tls},
						ipproto    => $C->{mail_server_ipproto},

						username => $C->{mail_user},
						password => $C->{mail_password},

						# and params for making the message on the go
						to       => $target,
						from     => $C->{mail_from},
						subject  => $$msgTable{$method}{$target}{$serial}{subject},
						body     => $$msgTable{$method}{$target}{$serial}{message},
						priority => $$msgTable{$method}{$target}{$serial}{priority},
					);

					if ( !$status )
					{
						logMsg("Error: Sending email to $target failed: $code $errmsg");
					}
					else
					{
						dbg("Escalation Email Notification sent to $target");
					}
				}
			}
		}    # end email
		### Carbon copy notifications - no action required - FYI only.
		elsif ( $method eq "ccopy" )
		{
			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach $target ( keys %{$msgTable->{$method}} )
			{
				foreach $serial ( keys %{$msgTable->{$method}{$target}} )
				{
					next if $C->{mail_server} eq '';

					my ( $status, $code, $errmsg ) = sendEmail(

						# params for connection and sending
						sender     => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello      => $C->{mail_domain},
						usetls     => $C->{mail_use_tls},
						ipproto    => $C->{mail_server_ipproto},

						username => $C->{mail_user},
						password => $C->{mail_password},

						# and params for making the message on the go
						to       => $target,
						from     => $C->{mail_from},
						subject  => $$msgTable{$method}{$target}{$serial}{subject},
						body     => $$msgTable{$method}{$target}{$serial}{message},
						priority => $$msgTable{$method}{$target}{$serial}{priority},
					);

					if ( !$status )
					{
						logMsg("Error: Sending email to $target failed: $code $errmsg");
					}
					else
					{
						dbg("Escalation CC Email Notification sent to $target");
					}
				}
			}
		}    # end ccopy
		elsif ( $method eq "netsend" )
		{
			foreach $target ( keys %{$msgTable->{$method}} )
			{
				foreach $serial ( keys %{$msgTable->{$method}{$target}} )
				{
					dbg("netsend $$msgTable{$method}{$target}{$serial}{message} to $target");

					# read any stdout messages and throw them away
					if ( $^O =~ /win32/i )
					{
						# win32 platform
						my $dump = `net send $target $$msgTable{$method}{$target}{$serial}{message}`;
					}
					else
					{
						# Linux box
						my $dump = `echo $$msgTable{$method}{$target}{$serial}{message}|smbclient -M $target`;
					}
				}    # end netsend
			}
		}

		# now the syslog
		elsif ( $method eq "syslog" )
		{
			foreach $target ( keys %{$msgTable->{$method}} )
			{
				foreach $serial ( keys %{$msgTable->{$method}{$target}} )
				{
					dbg(" sendSyslog to $target");
					sendSyslog(
						server_string => $C->{syslog_server},
						facility      => $C->{syslog_facility},
						message       => $$msgTable{$method}{$target}{$serial}{message},
						priority      => $$msgTable{$method}{$target}{$serial}{priority}
					);
				}    # end syslog
			}
		}

		# now the pagers
		elsif ( $method eq "pager" )
		{
			foreach $target ( keys %{$msgTable->{$method}} )
			{
				foreach $serial ( keys %{$msgTable->{$method}{$target}} )
				{
					next if $C->{snpp_server} eq '';
					dbg(" SendSNPP to $target");
					sendSNPP(
						server  => $C->{snpp_server},
						pagerno => $target,
						message => $$msgTable{$method}{$target}{$serial}{message}
					);
				}
			}    # end pager
		}

		# now the extensible stuff.......
		else
		{

			my $class       = "Notify::$method";
			my $classMethod = $class . "::sendNotification";
			if ( checkPerlLib($class) )
			{
				eval "require $class";
				logMsg($@) if $@;
				dbg("Using $classMethod to send notification to $$msgTable{$method}{$target}{$serial}{contact}->{Contact}"
				);
				my $function = \&{$classMethod};
				foreach $target ( keys %{$msgTable->{$method}} )
				{
					foreach $serial ( keys %{$msgTable->{$method}{$target}} )
					{
						dbg( "Notify method=$method, target=$target, serial=$serial message="
								. $$msgTable{$method}{$target}{$serial}{message} );
						if ( $target and $$msgTable{$method}{$target}{$serial}{message} )
						{
							$function->(
								message  => $$msgTable{$method}{$target}{$serial}{message},
								event    => $$msgTable{$method}{$target}{$serial}{event},
								contact  => $$msgTable{$method}{$target}{$serial}{contact},
								priority => $$msgTable{$method}{$target}{$serial}{priority},
								C        => $C
							);
						}
					}
				}
			}
			else
			{
				dbg("ERROR unknown device $method");
			}
		}    # end sms
	}
	dbg("Finished");
}

#=========================================================================================

### Adding overall network metrics collection and updates
sub runMetrics
{
	my %args = @_;
	my $S    = $args{sys};
	my $NI   = $S->ndinfo;

	my $GT = loadGroupTable();

	my %groupSummary;
	my $data;
	my $group;
	my $status;

	my $pollTimer = NMIS::Timing->new;

	dbg("Starting");

	# Doing the whole network - this defaults to -8 hours span
	my $groupSummary = getGroupSummary();
	$status                      = overallNodeStatus;
	$status                      = statusNumber($status);
	$data->{reachability}{value} = $groupSummary->{average}{reachable};
	$data->{availability}{value} = $groupSummary->{average}{available};
	$data->{responsetime}{value} = $groupSummary->{average}{response};
	$data->{health}{value}       = $groupSummary->{average}{health};
	$data->{status}{value}       = $status;
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

	dbg("Doing Network Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}"
	);

	my $db = $S->create_update_rrd( data => $data, type => "metrics", item => 'network' );
	if ( !$db )
	{
		logMsg( "ERROR updateRRD failed: " . getRRDerror() );
	}

	foreach $group ( sort keys %{$GT} )
	{
		$groupSummary = getGroupSummary( group => $group );
		$status                      = overallNodeStatus( group => $group );
		$status                      = statusNumber($status);
		$data->{reachability}{value} = $groupSummary->{average}{reachable};
		$data->{availability}{value} = $groupSummary->{average}{available};
		$data->{responsetime}{value} = $groupSummary->{average}{response};
		$data->{health}{value}       = $groupSummary->{average}{health};
		$data->{status}{value}       = $status;
		$data->{intfCollect}{value}  = $groupSummary->{average}{intfCollect};
		$data->{intfColUp}{value}    = $groupSummary->{average}{intfColUp};
		$data->{intfAvail}{value}    = $groupSummary->{average}{intfAvail};

		dbg("Doing group=$group Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}"
		);
		#
		$db = $S->create_update_rrd( data => $data, type => "metrics", item => $group );
		if ( !$db )
		{
			logMsg( "ERROR updateRRD failed: " . getRRDerror() );
		}
	}
	dbg("Finished");

	logMsg( "Poll Time: " . $pollTimer->elapTime() )
		if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) );

}    # end runMetrics

#=========================================================================================

sub runLinks
{
	my %subnets;
	my $links;
	my $C = loadConfTable();
	my $II;
	my $ipAddr;
	my $subnet;
	my $cnt;

	### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
	if ( getbool( $C->{disable_interfaces_summary} ) )
	{
		logMsg("runLinks disabled with disable_interfaces_summary=$C->{disable_interfaces_summary}");
		return;
	}

	dbg("Start");

	if ( !( $II = loadInterfaceInfo() ) )
	{
		logMsg("ERROR reading all interface info");
		return;
	}

	if ( getbool( $C->{db_links_sql} ) )
	{
		$links = DBfunc::->select( table => 'Links' );
	}
	else
	{
		$links = loadTable( dir => 'conf', name => 'Links' );
	}

	my $link_ifTypes = $C->{link_ifTypes} ne '' ? $C->{link_ifTypes} : '.';
	my $qr_link_ifTypes = qr/$link_ifTypes/i;

	dbg("Auto Generating Links file");
	foreach my $intHash ( sort keys %{$II} )
	{
		$cnt = 1;
		while ( defined $II->{$intHash}{"ipSubnet$cnt"} )
		{
			$ipAddr = $II->{$intHash}{"ipAdEntAddr$cnt"};
			$subnet = $II->{$intHash}{"ipSubnet$cnt"};
			if (    $ipAddr ne ""
				and $ipAddr ne "0.0.0.0"
				and $ipAddr !~ /^127/
				and getbool( $II->{$intHash}{collect} )
				and $II->{$intHash}{ifType} =~ /$qr_link_ifTypes/ )
			{
				if ( !exists $subnets{$subnet}{subnet} )
				{
					my $NI = loadNodeInfoTable( $II->{$intHash}{node} );
					$subnets{$subnet}{subnet}      = $subnet;
					$subnets{$subnet}{address1}    = $ipAddr;
					$subnets{$subnet}{count}       = 1;
					$subnets{$subnet}{description} = $II->{$intHash}{Description};
					$subnets{$subnet}{mask}        = $II->{$intHash}{"ipAdEntNetMask$cnt"};
					$subnets{$subnet}{ifSpeed}     = $II->{$intHash}{ifSpeed};
					$subnets{$subnet}{ifType}      = $II->{$intHash}{ifType};
					$subnets{$subnet}{net1}        = $NI->{system}{netType};
					$subnets{$subnet}{role1}       = $NI->{system}{roleType};
					$subnets{$subnet}{node1}       = $II->{$intHash}{node};
					$subnets{$subnet}{ifDescr1}    = $II->{$intHash}{ifDescr};
					$subnets{$subnet}{ifIndex1}    = $II->{$intHash}{ifIndex};
				}
				else
				{
					++$subnets{$subnet}{count};
					if ( !defined $subnets{$subnet}{description} )
					{    # use node2 description if node1 description did not exist.
						$subnets{$subnet}{description} = $II->{$intHash}{Description};
					}
					my $NI = loadNodeInfoTable( $II->{$intHash}{node} );
					$subnets{$subnet}{net2}     = $NI->{system}{netType};
					$subnets{$subnet}{role2}    = $NI->{system}{roleType};
					$subnets{$subnet}{node2}    = $II->{$intHash}{node};
					$subnets{$subnet}{ifDescr2} = $II->{$intHash}{ifDescr};
					$subnets{$subnet}{ifIndex2} = $II->{$intHash}{ifIndex};

				}
			}
			if ( $C->{debug} > 2 )
			{
				for my $i ( keys %{$subnets{$subnet}} )
				{
					dbg("subnets $i=$subnets{$subnet}{$i}");
				}
			}
			$cnt++;
		}
	}    # foreach
	foreach my $subnet ( sort keys %subnets )
	{
		if ( $subnets{$subnet}{count} == 2 )
		{
			# skip subnet for same node-interface in link table
			next
				if grep {
				        $links->{$_}{node1} eq $subnets{$subnet}{node1}
					and $links->{$_}{ifIndex1} eq $subnets{$subnet}{ifIndex1}
				} keys %{$links};

			# insert entry in db if not exists
			if ( getbool( $C->{db_links_sql} ) )
			{
				if ( not exists $links->{$subnet}{subnet} )
				{
					DBfunc::->insert( table => 'Links', data => {index => $subnet} );
				}
			}

			# form a key - use subnet as the unique key, same as read in, so will update any links with new information
			if (    defined $subnets{$subnet}{description}
				and $subnets{$subnet}{description} ne 'noSuchObject'
				and $subnets{$subnet}{description} ne "" )
			{
				$links->{$subnet}{link} = $subnets{$subnet}{description};
			}
			else
			{
				# label the link as the subnet if no description
				$links->{$subnet}{link} = $subnet;
			}
			$links->{$subnet}{subnet}  = $subnets{$subnet}{subnet};
			$links->{$subnet}{mask}    = $subnets{$subnet}{mask};
			$links->{$subnet}{ifSpeed} = $subnets{$subnet}{ifSpeed};
			$links->{$subnet}{ifType}  = $subnets{$subnet}{ifType};

			# define direction based on wan-lan and core-distribution-access
			# selection weights cover the most well-known types
			# fixme: this is pretty ugly and doesn't use $C->{severity_by_roletype}
			my %netweight = ( wan => 1, lan => 2, _ => 3, );
			my %roleweight = ( core => 1, distribution => 2, _ => 3, access => 4 );

			my $netweight1
				= defined( $netweight{$subnets{$subnet}->{net1}} )
				? $netweight{$subnets{$subnet}->{net1}}
				: $netweight{"_"};
			my $netweight2
				= defined( $netweight{$subnets{$subnet}->{net2}} )
				? $netweight{$subnets{$subnet}->{net2}}
				: $netweight{"_"};

			my $roleweight1
				= defined( $roleweight{$subnets{$subnet}->{role1}} )
				? $roleweight{$subnets{$subnet}->{role1}}
				: $roleweight{"_"};
			my $roleweight2
				= defined( $roleweight{$subnets{$subnet}->{role2}} )
				? $roleweight{$subnets{$subnet}->{role2}}
				: $roleweight{"_"};

			my $k
				= ( ( $netweight1 == $netweight2 && $roleweight1 > $roleweight2 ) || $netweight1 > $netweight2 )
				? 2
				: 1;

			$links->{$subnet}{net}  = $subnets{$subnet}{"net$k"};
			$links->{$subnet}{role} = $subnets{$subnet}{"role$k"};

			$links->{$subnet}{node1}      = $subnets{$subnet}{"node$k"};
			$links->{$subnet}{interface1} = $subnets{$subnet}{"ifDescr$k"};
			$links->{$subnet}{ifIndex1}   = $subnets{$subnet}{"ifIndex$k"};

			$k = $k == 1 ? 2 : 1;
			$links->{$subnet}{node2}      = $subnets{$subnet}{"node$k"};
			$links->{$subnet}{interface2} = $subnets{$subnet}{"ifDescr$k"};
			$links->{$subnet}{ifIndex2}   = $subnets{$subnet}{"ifIndex$k"};

			# dont overwrite any manually configured dependancies.
			if ( !exists $links->{$subnet}{depend} ) { $links->{$subnet}{depend} = "N/A" }

			# reformat the name
			##	$links->{$subnet}{link} =~ s/ /_/g;

			if ( getbool( $C->{db_links_sql} ) )
			{
				if ( not exists $links->{$subnet}{subnet} )
				{
					DBfunc::->update( table => 'Links', data => $links->{$subnet}, index => $subnet );
				}
			}
			dbg("Adding link $links->{$subnet}{link} for $subnet to links");
		}
	}
	$links = {} if !$links;
	if ( !getbool( $C->{db_links_sql} ) )
	{
		writeTable( dir => 'conf', name => 'Links', data => $links );
	}
	logMsg("Check table Links and update link names and other entries");

	dbg("Finished");
}

#=========================================================================================

# starts up fpingd and/or opslad
sub runDaemons
{

	my $C = loadConfTable();

	dbg("Starting");

	# get process table of OS
	my @p_names;
	my $pt = new Proc::ProcessTable();
	my %pnames;
	foreach my $p ( @{$pt->table} )
	{
		$pnames{$p->fname} = 1;
	}

	# start fast ping daemon
	if ( getbool( $C->{daemon_fping_active} ) )
	{
		if ( !exists $pnames{$C->{daemon_fping_filename}} )
		{
			if ( -x "$C->{'<nmis_bin>'}/$C->{daemon_fping_filename}" )
			{
				system( "$C->{'<nmis_bin>'}/$C->{daemon_fping_filename}", "restart=true" );
				logMsg("INFO launched $C->{daemon_fping_filename} as daemon");
			}
			else
			{
				logMsg("ERROR cannot run daemon $C->{'<nmis_bin>'}/$C->{daemon_fping_filename},$!");
			}
		}
	}

	# start ipsla daemon
	if ( getbool( $C->{daemon_ipsla_active} ) )
	{
		if ( !exists $pnames{$C->{daemon_ipsla_filename}} )
		{
			if ( -x "$C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename}" )
			{
				system("$C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename}");
				logMsg("INFO launched $C->{daemon_ipsla_filename} as daemon");
			}
			else
			{
				logMsg("ERROR cannot run daemon $C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename},$!");
			}
		}
	}

	dbg("Finished");
}

#=========================================================================================

sub checkConfig
{
	my %args   = @_;
	my $change = $args{change};
	my $audit  = $args{audit};

	my $ext = getExtension( dir => 'conf' );

	# depending on our job, create dirs with correct perms
	# or just check and report them.
	if ( getbool($change) )
	{
		my $checkFunc = sub { my ($dirname) = @_; createDir($dirname); setFileProtDirectory( $dirname, 1 ); };
		my $checkType = "Checking and Fixing";

		# Do the var directories exist? if not make them and fix the perms!
		info("Config $checkType - Checking var directories, $C->{'<nmis_var>'}");
		if ( $C->{'<nmis_var>'} ne '' )
		{
			&$checkFunc("$C->{'<nmis_var>'}");
			&$checkFunc("$C->{'<nmis_var>'}/nmis_system");
			&$checkFunc("$C->{'<nmis_var>'}/nmis_system/timestamps");
		}

		# Do the log directories exist, if not make them?
		info("Config $checkType - Checking log directories, $C->{'<nmis_logs>'}");
		if ( $C->{'<nmis_logs>'} ne '' )
		{
			&$checkFunc("$C->{'<nmis_logs>'}");
			&$checkFunc("$C->{'json_logs'}");
			&$checkFunc("$C->{'config_logs'}");
		}

		# Do the conf directories exist if not make them?
		info("Config $checkType - Checking conf directories, $C->{'<nmis_conf>'}");
		if ( $C->{'<nmis_conf>'} ne '' )
		{
			&$checkFunc("$C->{'<nmis_conf>'}");
		}

		# Does the database directory exist? if not make it.
		info("Config $checkType - Checking database directories");
		if ( $C->{database_root} ne '' )
		{
			&$checkFunc("$C->{database_root}");
		}
		else
		{
			print "\n Cannot create directories because database_root is not defined in NMIS config\n";
		}

		# create files
		if ( not existFile( dir => 'logs', name => 'nmis.log' ) )
		{
			open( LOG, ">>$C->{'<nmis_logs>'}/nmis.log" );
			close LOG;
			setFileProt("$C->{'<nmis_logs>'}/nmis.log");
		}

		if ( not existFile( dir => 'logs', name => 'auth.log' ) )
		{
			open( LOG, ">>$C->{'<nmis_logs>'}/auth.log" );
			close LOG;
			setFileProt("$C->{'<nmis_logs>'}/auth.log");
		}

		if ( not existFile( dir => 'var', name => 'nmis-system' ) )
		{
			my ( $hsh, $handle ) = loadTable( dir => 'var', name => 'nmis-system' );
			$hsh->{startup} = time();
			writeTable( dir => 'var', name => 'nmis-system', data => $hsh );
		}

		# now perform exactly the same permission fixing operations as admin/fixperms.pl

		# single depth directories
		my %done;
		for my $location (
			$C->{'<nmis_data>'},    # commonly same as base
			$C->{'<nmis_base>'},
			$C->{'<nmis_admin>'}, $C->{'<nmis_bin>'}, $C->{'<nmis_cgi>'},
			$C->{'<nmis_models>'},
			$C->{'<nmis_logs>'},
			$C->{'log_root'},       # should be the same as nmis_logs
			$C->{'config_logs'},
			$C->{'json_logs'},
			$C->{'<menu_base>'},
			$C->{'report_root'},
			$C->{'script_root'},    # commonly under nmis_conf
			$C->{'plugin_root'},
			)                       # ditto
		{
			setFileProtDirectory( $location, "false" ) if ( !$done{$location} );
			$done{$location} = 1;
		}

		# deeper dirs with recursion
		%done = ();
		for my $location ( $C->{'<nmis_base>'} . "/lib",
			$C->{'<nmis_conf>'}, $C->{'<nmis_var>'}, $C->{'<nmis_menu>'}, $C->{'mib_root'}, $C->{'database_root'},
			$C->{'web_root'}, )
		{
			setFileProtDirectory( $location, "true" ) if ( !$done{$location} );
			$done{$location} = 1;
		}
	}

	if ( getbool($audit) )
	{
		my $overallstatus = 1;
		my @problems;

		# flat dirs first
		my %done;
		for my $location (
			$C->{'<nmis_data>'},    # commonly same as base
			$C->{'<nmis_base>'},
			$C->{'<nmis_admin>'}, $C->{'<nmis_bin>'}, $C->{'<nmis_cgi>'},
			$C->{'<nmis_models>'},
			$C->{'<nmis_logs>'},
			$C->{'log_root'},       # should be the same as nmis_logs
			$C->{'config_logs'},
			$C->{'json_logs'},
			$C->{'<menu_base>'},
			$C->{'report_root'},
			$C->{'script_root'},    # commonly under nmis_conf
			$C->{'plugin_root'},
			)                       # ditto
		{
			my $where = Cwd::abs_path($location);
			next if ( $done{$where} );

			my ( $result, @newmsgs ) = checkDirectoryFiles( $location, recurse => "false" );

			$overallstatus = 0 if ( !$result );
			push @problems, @newmsgs;

			$done{$where} = 1;
		}

		# deeper dirs with recursion
		%done = ();
		for my $location ( $C->{'<nmis_base>'} . "/lib",
			$C->{'<nmis_conf>'}, $C->{'<nmis_var>'}, $C->{'<nmis_menu>'}, $C->{'mib_root'}, $C->{'database_root'},
			$C->{'web_root'}, )
		{
			my $where = Cwd::abs_path($location);
			next if ( $done{$where} );

			my ( $result, @newmsgs ) = checkDirectoryFiles( $location, recurse => "true" );

			$overallstatus = 0 if ( !$result );
			push @problems, @newmsgs;

			$done{$where} = 1;
		}

		if ( @problems && $overallstatus )
		{
			print "Informational messages:\n", join( "\n", @problems ), "\n";
		}
		elsif (@problems)
		{
			print "Detected problems:\n", join( "\n", @problems ), "\n";
		}
	}

	# convert ancient config .csv to .xxxx (hash) file format
	convertConfFiles();

	info(" Continue with bin/nmis.pl type=apache for configuration rules of the Apache web server\n");
}

#=========================================================================================

# two modes: default, for the root user's personal crontab
# if system=true is given, then a crontab for /etc/cron.d/XXX is printed
# (= with the extra 'root' user column)
sub printCrontab
{
	my $C = loadConfTable();

	dbg( " Crontab Config for NMIS for config file=$nvp{conf}", 3 );

	my $usercol = getbool( $nvp{system} ) ? "\troot\t" : '';

	print qq|
# if you DON'T want any NMIS cron mails to go to root,
# uncomment and adjust the next line
# MAILTO=WhoeverYouAre\@yourdomain.tld

# some tools like fping reside outside the minimal path
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

######################################################
# NMIS8 Config
######################################################
# Run Full Statistics Collection
*/5 * * * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=collect mthread=true
# ######################################################
# Optionally run a more frequent Services-only Collection
# */3 * * * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=services mthread=true
######################################################
# Run Summary Update every 2 minutes
*/2 * * * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=summary
#####################################################
# Run the interfaces 4 times an hour with Thresholding on!!!
# if threshold_poll_cycle is set to false, then enable cron based thresholding
#*/5 * * * * $usercol nice $C->{'<nmis_base>'}/bin/nmis.pl type=threshold
######################################################
# Run the update once a day
30 20 * * * $usercol nice $C->{'<nmis_base>'}/bin/nmis.pl type=update mthread=true
######################################################
# Log Rotation is now handled with /etc/logrotate.d/nmis, which
# the installer offers to setup using install/logrotate*.conf
#
# backup configuration, models and crontabs once a day, and keep 30 backups
22 8 * * * $usercol $C->{'<nmis_base>'}/admin/config_backup.pl $C->{'<nmis_backups>'} 30
##################################################
# purge old files every few days
2 2 */3 * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=purge
########################################
# Save the Reports, Daily Monthly Weekly
9 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day all
9 1 * * 0  $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week all
9 2 1 * *  $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month all
|;
}

#=========================================================================================

# apache 2.4 needs a different configuration layout
sub printApache24
{
	my $C = loadConfTable;
	print qq|
# Apache configuration snippet for NMIS

# this should either be made part of your preferred VirtualHost,
# or saved in /etc/apache2/sites-enabled as <somefile>.conf

# Further documentation about Apache: http://httpd.apache.org/docs/2.4/

# NMIS Aliases for static files:
Alias $C->{'<url_base>'} "$C->{web_root}"
<Directory "$C->{web_root}">
  Options Indexes FollowSymLinks MultiViews
	AllowOverride None
  Require all granted
</Directory>

Alias $C->{'<menu_url_base>'}/ "$C->{'<nmis_menu>'}/"
<Directory "$C->{'<nmis_menu>'}">
  Options Indexes FollowSymLinks MultiViews
  AllowOverride None
  Require all granted
</Directory>

# Alias and Activation for the CGI scripts
ScriptAlias $C->{'<cgi_url_base>'}/ "$C->{'<nmis_cgi>'}/"
<Directory "$C->{'<nmis_cgi>'}">
  Options +ExecCGI
  Require all granted
</Directory>

# This is now optional, if using internal NMIS Authentication
<Location "$C->{'<url_base>'}/">
#  # For IP address based permissions
#  <RequireAny>
#  Require ip 10.0.0.0/8
#  Require ip 172.16.0.0/16
#  Require ip 192.168.1.1
#  Require host .opmantek.com
#  Require all denied
#</RequireAny>

#  # For Username based authentication
#  AuthType Basic
#  AuthName "NMIS8"
#  AuthUserFile $C->{'auth_htpasswd_file'}
#  Require valid-user
</Location>

<Location "$C->{'<cgi_url_base>'}/">
#  # For IP address based permissions
#  <RequireAny>
#  Require ip 10.0.0.0/8
#  Require ip 172.16.0.0/16
#  Require ip 192.168.1.1
#  Require host .opmantek.com
#  Require all denied
#</RequireAny>

#  # For Username based authentication
#  AuthType Basic
#  AuthName "NMIS8"
#  AuthUserFile $C->{'auth_htpasswd_file'}
#  Require valid-user
</Location>
|;

}

sub printApache
{

	my $C = loadConfTable();

	dbg( " Apache HTTPD Config for NMIS for config file=$nvp{conf}", 3 );

	print <<EO_TEXT;

## For more information on the listed Apache features read:
## Alias directive:        http://httpd.apache.org/docs/mod/mod_alias.html#alias
## ScriptAlias directive:  http://httpd.apache.org/docs/mod/mod_alias.html#scriptalias
## Order directive:        http://httpd.apache.org/docs/mod/mod_access.html#order
## Allow directive:        http://httpd.apache.org/docs/mod/mod_access.html#allow
## Deny directive:         http://httpd.apache.org/docs/mod/mod_access.html#deny
## AuthType directive:     http://httpd.apache.org/docs/mod/core.html#authtype
## AuthName directive:     http://httpd.apache.org/docs/mod/core.html#authname
## AuthUserFile directive: http://httpd.apache.org/docs/mod/mod_auth.html#authuserfile
## Require directive:      http://httpd.apache.org/docs/mod/core.html#require

# Usual Apache Config File!
#<apache_root>/conf/httpd.conf

# add a password to the users.dat file!
#<apache_root>/bin/htpasswd $C->{'<nmis_base>'}/conf/users.dat nmis

# restart the daemon!
#<apache_root>/bin/apachectl restart
#
# NOTE:
# <apache_root> is normally /usr/local/apache
# the "bin" directory might be "sbin"
# the "conf" directory might be "etc"
# the httpd.conf might be split across httpd.conf, access.conf and srm.conf

# NMIS Aliases

Alias $C->{'<url_base>'} "$C->{web_root}"
<Directory "$C->{web_root}">
		Options Indexes FollowSymLinks MultiViews
		AllowOverride None
		Order allow,deny
		Allow from all
</Directory>

Alias $C->{'<menu_url_base>'}/ "$C->{'<nmis_menu>'}/"
<Directory "$C->{'<nmis_menu>'}">
		Options Indexes FollowSymLinks MultiViews
		AllowOverride None
		Order allow,deny
		Allow from all
</Directory>

ScriptAlias $C->{'<cgi_url_base>'}/ "$C->{'<nmis_cgi>'}/"
<Directory "$C->{'<nmis_cgi>'}">
		Options +ExecCGI
		Order allow,deny
		Allow from all
</Directory>

# This is now optional if using internal NMIS Authentication
<Location "$C->{'<url_base>'}/">
				## For IP address based permissions
				#Order deny,allow
				#deny from all
				#allow from 10.0.0.0/8 172.16.0.0/16 192.168.1.1 .opmantek.com
				## For Username based authentication
				#AuthType Basic
				#AuthName "NMIS8"
				#AuthUserFile $C->{'auth_htpasswd_file'}
				#Require valid-user
</Location>

# This is now optional if using internal NMIS Authentication
<Location "$C->{'<cgi_url_base>'}/">
				## For IP address based permissions
				#Order deny,allow
				#deny from all
				#allow from 10.0.0.0/8 172.16.0.0/16 192.168.1.1 .opmantek.com
				## For Username based authentication
				#AuthType Basic
				#AuthName "NMIS8"
				#AuthUserFile $C->{'auth_htpasswd_file'}
				#Require valid-user
</Location>

#*** URL required in browser ***
#http://$C->{'nmis_host'}$C->{'<cgi_url_base>'}/nmiscgi.pl
#If host address is not correct change this in NMIS config.
#***

EO_TEXT
}

#=========================================================================================

sub checkArgs
{
	print qq!

NMIS Polling Engine - Network Management Information System

Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;
This is free software licensed under GNU GPL, and you are welcome to
redistribute it under certain conditions; see www.opmantek.com or email
contact\@opmantek.com

NMIS version $NMIS::VERSION

Usage: $0 <type=action> [option=value...]

command line options are:
  type=<option>
    Where <option> is one of the following:
      collect   NMIS will collect all statistics (incl. Services)
      update    Update all the dynamic NMIS configuration
      threshold Calculate thresholds
      services  Run Services data collection only
      master    Run NMIS Master Functions
      escalate  Run the escalation routine only ( debug use only)
      config    Validate the chosen configuration file
      audit     Audit the configuration without changes
      apache    Produce Apache 2.0/2.2 configuration for NMIS
      apache24  Produce Apache 2.4 configuration for NMIS
      crontab   Produce Crontab configuration for NMIS
                (add system=true for /etc/cron.d snippet)
      links     Generate the links.csv file.
      rme       Read and generate a node.csv file from a Ciscoworks RME file
      groupsync Check all nodes and add any missing groups to the configuration
      purge     Remove old files, or print them if simulate=true
  [conf=<file name>]     Optional alternate configuation file in conf directory
  [node=<node name>]     Run operations on a single node;
  [group=<group name>]   Run operations on all nodes in the named group;
  [force=true|false]     Makes an update operation run from scratch, without optimisations
  [debug=true|false|0-9] default=false - Show debugging information
  [rmefile=<file name>]  RME file to import.
  [mthread=true|false]   default=$C->{nmis_mthread} - Enable Multithreading or not;
  [mthreaddebug=true|false] default=false - Extra debug for Multithreading code;
  [maxthreads=<1..XX>]  default=$C->{nmis_maxthreads} - How many threads should nmis use, at most\n
!;
}

#=========================================================================================

# run threshold calculation operation on all or one node, in a single loop
# args: 
#   node - (optional), 
#   running_independently - set to 1 if not in collect/outer loop that will do saves
# returns: nothing
sub runThreshold
{
	my ($node,$running_independently) = @_;

	# check global_threshold not explicitely set to false
	if ( !getbool( $C->{global_threshold}, "invert" ) )
	{
		my $node_select;
		if ($node)
		{
			die "Invalid node=$node: No node of that name\n"
				if ( !( $node_select = checkNodeName($node) ) );
		}
		doThreshold( name => $node_select, table => doSummaryBuild( name => $node_select ), running_independently => $running_independently );		
	}
	else
	{
		dbg("Skipping runThreshold with configuration 'global_threshold' = $C->{'global_threshold'}");
	}
}

# collects (using getSummaryStats) and returns summary stats
# for one or all nodes, also writes two debug files.
#
# args: name (optional), sys (optional, only if name is given)
# returns: summary stats hash
sub doSummaryBuild
{
	my (%args) = @_;
	my $node = $args{name};
	my $S    = $node && $args{sys} ? $args{sys} : undef;    # use given sys object only with this node

	dbg("Start of Summary Build");

	my $NT = loadLocalNodeTable();
	my %stshlth;
	my %stats;
	my %stsintf;

	foreach my $nd ( sort keys %{$NT} )
	{
		next if $node ne "" and $node ne $nd;
		if ( getbool( $NT->{$nd}{active} ) and getbool( $NT->{$nd}{collect} ) )
		{
			if ( !$S )
			{
				# get cached info of node, iff required
				$S = Sys->new;
				next if ( !$S->init( name => $nd, snmp => 'false' ) );
			}

			my $M  = $S->mdl;       # model ref
			my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

			next if getbool( $catchall_data->{nodedown} );

			# oke, look for requests in summary of Model
			foreach my $tp ( keys %{$M->{summary}{statstype}} )
			{
				next if ( !exists $M->{system}->{rrd}->{$tp}->{threshold} );
				my $threshold_period = $C->{"threshold_period-default"} || "-15 minutes";

				if ( exists $C->{"threshold_period-$tp"} and $C->{"threshold_period-$tp"} ne "" )
				{
					$threshold_period = $C->{"threshold_period-$tp"};
					dbg("Found Configured Threshold for $tp, changing to \"$threshold_period\"");
				}

				# check whether this is an indexed section, ie. whether there are multiple instances with
				# their own indices
				# fixme: this is wrong, $tp should be either graphtype OR section
				my @instances = $S->getTypeInstances( graphtype => $tp, section => $tp );
				if (@instances)
				{
					foreach my $i (@instances)
					{
						my $sts = getSummaryStats(
							sys   => $S,
							type  => $tp,
							start => $threshold_period,
							end   => 'now',
							index => $i
						);

						# save all info from %sts for threshold run
						foreach ( keys %{$sts->{$i}} ) { $stats{$nd}{$tp}{$i}{$_} = $sts->{$i}{$_}; }

						foreach my $nm ( keys %{$M->{summary}{statstype}{$tp}{sumname}} )
						{
							$stshlth{ $catchall_data->{nodeType} }{$nd}{$nm}{$i}{Description}
								=  "WHAT GOES HERE? NI->label makes no sense";#$NI->{label}{$tp}{$i};    # descr
							    # check if threshold level available, thresholdname must be equal to type
							if ( exists $M->{threshold}{name}{$tp} )
							{
								( $stshlth{ $catchall_data->{nodeType} }{$nd}{$nm}{$i}{level}, undef, undef )
									= getThresholdLevel( sys => $S, thrname => $tp, stats => $sts, index => $i );
							}

							# save values
							foreach my $stsname ( @{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}} )
							{
								$stshlth{ $catchall_data->{nodeType} }{$nd}{$nm}{$i}{$stsname} = $sts->{$i}{$stsname};
								dbg("stored summary health node=$nd type=$tp name=$stsname index=$i value=$sts->{$i}{$stsname}"
								);
							}
						}
					}
				}

				# non-indexed
				else
				{
					my $dbname = $S->makeRRDname( graphtype => $tp );
					if ( $dbname && -r $dbname )
					{
						my $sts = getSummaryStats( sys => $S, type => $tp, start => $threshold_period, end => 'now' );

						# save all info from %sts for threshold run
						foreach ( keys %{$sts} ) { $stats{$nd}{$tp}{$_} = $sts->{$_}; }

						# check if threshold level available, thresholdname must be equal to type
						if ( exists $M->{threshold}{name}{$tp} )
						{
							( $stshlth{ $catchall_data->{nodeType} }{$nd}{"${tp}_level"}, undef, undef )
								= getThresholdLevel( sys => $S, thrname => $tp, stats => $sts, index => '' );
						}
						foreach my $nm ( keys %{$M->{summary}{statstype}{$tp}{sumname}} )
						{
							foreach my $stsname ( @{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}} )
							{
								$stshlth{ $catchall_data->{nodeType} }{$nd}{$stsname} = $sts->{$stsname};
								dbg("stored summary health node=$nd type=$tp name=$stsname value=$sts->{$stsname}");
							}
						}
					}
				}

				# reset the threshold period, may have been changed to threshold_period-<something>
				$threshold_period = $C->{"threshold_period-default"} || "-15 minutes";

				my $tp = "interface";
				if ( exists $C->{"threshold_period-$tp"} and $C->{"threshold_period-$tp"} ne "" )
				{
					$threshold_period = $C->{"threshold_period-$tp"};
					dbg("Found Configured Threshold for $tp, changing to \"$threshold_period\"");
				}

				# this could maybe use the model and get collect right away as that's
				# all it seems to be used for right now
				my $ids = $S->nmisng_node->get_inventory_ids( concept => 'interface' );
				# get all collected interfaces
				foreach my $id (@$ids)
				{
					my $data = $S->nmisng_node->inventory( _id => $id )->data();
					my $index = $data->{index};
					next unless getbool( $data->{collect} );
					my $sts = getSummaryStats(
						sys   => $S,
						type  => $tp,
						start => $threshold_period,
						end   => time(),
						index => $index
					);
					foreach ( keys %{$sts->{$index}} )
					{
						$stats{$nd}{interface}{$index}{$_} = $sts->{$index}{$_};
					}    # save for threshold

					# copy all stats into the stsintf info.
					foreach ( keys %{$sts->{$index}} ) { $stsintf{"${index}.$S->{name}"}{$_} = $sts->{$index}{$_}; }
				}
			}
		}

		# use a new sys object for every node
		undef $S;
	}

	# these two tables are produced ONLY for debugging, they're not used by nmis
	writeTable( dir => 'var', name => "nmis-summaryintf15m",   data => \%stsintf );
	writeTable( dir => 'var', name => "nmis-summaryhealth15m", data => \%stshlth );
	dbg("Finished");

	return \%stats;    # input for threshold process
}

# figures out which threshold alerts need to be run for one (or all) nodes, based on model
# delegates the evaluation work to runThrHld, then updates info structures.
#
# args: name (optional), table (required, must be hash ref but may be empty),
# sys (optional, only used if name is given)
#
# note: writes node info file if run as part of type=threshold
# returns: nothing
sub doThreshold
{
	my %args = @_;
	my $name = $args{name};
	my $sts  = $args{table};    # pointer to data built up by doSummaryBuild
	my $S    = $args{sys};
	my $running_independently = $args{running_independently};

	dbg("Starting");
	
	func::update_operations_stamp( type => "threshold", start => $starttime, stop => undef )
		if( $running_independently );

	my $pollTimer = NMIS::Timing->new;

	my $events_config = loadTable( dir => 'conf', name => 'Events' );
	my $NT = loadLocalNodeTable();

	my @cand = ( $name && $NT->{$name} ? $name : keys %$NT );

	for my $onenode (@cand)
	{
		next if ( !getbool( $NT->{$onenode}{active} ) or !getbool( $NT->{$onenode}{threshold} ) );

		if ( @cand > 1 || !$S )
		{
			$S = Sys->new;
			next if ( !$S->init( name => $onenode, snmp => 'false' ) );
		}

		# my $NI = $S->ndinfo;    # pointer to node info table
		my $M  = $S->mdl;       # pointer to Model table
		# my $IF = $S->ifinfo;
		my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
		my $status_table = $S->ndinfo->{status};

		# skip if node down
		if ( getbool( $catchall_data->{nodedown} ) )
		{
			info("Node down, skipping thresholding for $S->{name}");
			next;
		}
		info("Starting Thresholding node=$S->{name}");

		# first the standard thresholds
		my $thrname = 'response,reachable,available';
		runThrHld( sys => $S, table => $sts, type => 'health', thrname => $thrname );

		# search for threshold names in Model of this node
		foreach my $s ( keys %{$M} )    # section name
		{
			# thresholds live ONLY under rrd, other 'types of store' don't interest us here
			my $ts = 'rrd';
			foreach my $type ( keys %{$M->{$s}{$ts}} )    # name/type of subsection
			{
				my $thissection = $M->{$s}->{$ts}->{$type};
				dbg( "section $s, type $type " . ( $thissection->{threshold} ? "has a" : "has no" ) . " threshold" );
				next if ( !$thissection->{threshold} );    # nothing to do

				# attention: control expressions for indexed section must be run per instance,
				# and no more getbool possible (see below for reason)
				my $control = $thissection->{control};
				if ($control
					and (  !defined( $thissection->{indexed} )
						or $thissection->{indexed} eq ""
						or $thissection->{indexed} eq "false" )
					)
				{
					dbg( "control found:$control for section=$s type=$type, non-indexed", 1 );
					if ( !$S->parseString( string => "($control) ? 1:0", sect => $type, eval => 1 ) )
					{
						dbg("threshold of type $type skipped by control=$control");
						next;
					}
				}

				$thrname = $thissection->{threshold};    # get commasep string of threshold name(s)
				dbg("threshold=$thrname found in section=$s type=$type indexed=$thissection->{indexed}");

				# getbool of this is not valid anymore, for WMI indexed must be named,
				# so getbool 'indexed' => 'Name' evaluates to false. changing now to be not false.
				if (not(    $thissection->{indexed} ne ""
						and $thissection->{indexed} ne "false" )
					)    # if indexed then all instances must be checked individually
				{
					runThrHld( sys => $S, table => $sts, type => $type, thrname => $thrname );    # single
				}
				else
				{
			  # this can be misleading, b/c not everything updates the instance index -> graphtype association reliably,
					# so you could get an instance index that's long gone...
					# fixme: this is wrong, type should be either given as graphtype or as section
					my @instances = $S->getTypeInstances( graphtype => $type, section => $type );
					dbg( "threshold instances=" . ( join( ", ", @instances ) || "none" ) );

					for my $index (@instances)
					{
				  	# instances that don't have a valid nodeinfo section mustn't be touched
				  	# however logic only works in some cases: some model source sections don't have nodeinfo sections associated.

				  	# NOTE: getting interface data for cbqos here
				  	my $concept = $type;
				  	$concept = 'interface' if ( $type =~ /cbqos|interface|pkts/ );

		   			my $inventory = $S->inventory( concept => $type, index => $index );
		   			my $data = ($inventory) ? $inventory->data() : {};
						if ($s eq "systemHealth" && !$inventory)
							# and (  ref( $NI->{$type} ) ne "HASH" or ( !keys %{$NI->{$type}} )
							# 	or ref( $NI->{$type}->{$index} ) ne "HASH"
							# 	or $index ne $NI->{$type}->{$index}->{index} )							
						{
							logMsg(
								"ERROR invalid data for section $type and index $index, cannot run threshold for this index!"
							);
							info(
								"ERROR invalid data for section $type and index $index, cannot run threshold for this index!"
							);
							next;
						}

						# control must be checked individually, too!
						if ($control)
						{
							dbg( "control found:$control for s=$s type=$type, index=$index", 1 );
							if ( !$S->parseString( string => "($control) ? 1:0", sect => $type, index => $index, eval => 1 ) )
							{
								dbg("threshold of type $type, index $index skipped by control=$control");
								next;
							}
						}

						# thresholds can be selectively disabled for individual interfaces
						if ( $type =~ /interface|pkts/ )
						{
							# look for interfaces; pkts and pkts_hc are not contained in nodeinfo							
							if ( $data && $data->{threshold} )
							{
								if ( getbool( $data->{threshold} ) )
								{
									runThrHld(
										sys     => $S,
										table   => $sts,
										type    => $type,
										thrname => $thrname,
										index   => $index
									);
								}
								else
								{
									dbg("skipping disabled threshold type $type for index $index");
									next;
								}
							}
						}
						# this autovivifies but it does not matter
						elsif ( $type =~ /cbqos/ and defined $data->{threshold} eq 'true')
						{							
							my ( $cbqos, $direction ) = split( /\-/, $type );
							$inventory = $S->inventory( concept => "cbqos-$direction", index => $index );
							$data = $inventory->data();
							dbg("CBQOS cbqos=$cbqos direction=$direction index=$index");
							foreach my $class ( keys %{$data->{ClassMap}} )
							{
								dbg("  CBQOS class=$class $data->{ClassMap}{$class}{Name}");
								runThrHld(
									sys     => $S,
									table   => $sts,
									type    => $type,
									thrname => $thrname,
									index   => $index,
									item    => $data->{ClassMap}{$class}{Name},
									class   => $class
								);
							}
						}
						else
						{
							runThrHld( sys => $S, table => $sts, type => $type, thrname => $thrname, index => $index );
						}
					}
				}
			}
		}

		## process each status and have it decay the overall node status......
		#"High TCP Connection Count--tcpCurrEstab" : {
		#   "status" : "ok",
		#   "value" : "1",
		#   "event" : "High TCP Connection Count",
		#   "element" : "tcpCurrEstab",
		#   "index" : null,
		#   "level" : "Normal",
		#   "type" : "test",
		#   "updated" : 1423619108,
		#   "method" : "Alert",
		#   "property" : "$r > 250"
		#},
		my $count   = 0;
		my $countOk = 0;
		foreach my $statusKey ( sort keys %$status_table )
		{
			my $eventKey = $status_table->{$statusKey}{event};
			$eventKey = "Alert: $S->{info}{status}{$statusKey}{event}"
				if $status_table->{$statusKey}{method} eq "Alert";

			# event control is as configured or all true.
			my $thisevent_control = $events_config->{$eventKey} || {Log => "true", Notify => "true", Status => "true"};

			# if this is an alert and it is older than 1 full poll cycle, delete it from status.
			if ( $status_table->{$statusKey}{updated} < time - 500 )
			{
				delete $status_table->{$statusKey};
			}

			# in case of Status being off for this event, we don't have to include it in the calculations
			elsif ( not getbool( $thisevent_control->{Status} ) )
			{
				dbg("Status Summary Ignoring: event=$status_table->{$statusKey}{event}, Status=$thisevent_control->{Status}",
					1
				);
				$status_table->{$statusKey}{status} = "ignored";
				++$count;
				++$countOk;
			}
			else
			{
				++$count;
				if ( $status_table->{$statusKey}{status} eq "ok" )
				{
					++$countOk;
				}
			}
		}
		if ( $count and $countOk )
		{
			my $perOk = sprintf( "%.2f", $countOk / $count * 100 );
			info("Status Summary = $perOk, $count, $countOk\n");
			$catchall_data->{status_summary} = $perOk;
			$catchall_data->{status_updated} = time();

			# cache the current nodestatus for use in the dash
			my $nodestatus = nodeStatus( catchall_data => $catchall_data );
			$catchall_data->{nodestatus} = "reachable";
			if ( not $nodestatus )
			{
				$catchall_data->{nodestatus} = "unreachable";
			}
			elsif ( $nodestatus == -1 )
			{
				$catchall_data->{nodestatus} = "degraded";
			}			
		}

		# Save the new status results, but only if run standalone
		if( $running_independently )
		{
			$S->writeNodeInfo();
			$catchall_data->save();	
		}
		
	}

	dbg("Finished");
	if ( defined $C->{log_polling_time} and getbool( $C->{log_polling_time} ) )
	{
		my $polltime = $pollTimer->elapTime();
		if ($name)
		{
			logMsg("Poll Time: $name, $polltime");
		}
		else
		{
			logMsg("Poll Time: $polltime");
		}
	}
	func::update_operations_stamp( type => "threshold", start => $starttime, stop => Time::HiRes::time() )
		if( $running_independently );
}

# performs the threshold value checking and event raising for
# one or more threshold configurations
# args: sys, type, thrname, index, item, class (all required),
# table (required hashref but may be empty),
# returns: nothing but raises/clears events (via thresholdProcess) and updates table
sub runThrHld
{
	my %args = @_;

	my $S    = $args{sys};
	my $NI   = $S->ndinfo;
	my $M    = $S->mdl;
	my $IF   = $S->ifinfo;
	my $ET   = $S->{info}{env_temp};

	my $sts     = $args{table};
	my $type    = $args{type};
	my $thrname = $args{thrname};
	my $index   = $args{index};
	my $item    = $args{item};
	my $class   = $args{class};
	my $stats;
	my $element;

	dbg("WORKING ON Threshold for thrname=$thrname type=$type item=$item");

	my $threshold_period = "-15 minutes";
	if ( $C->{"threshold_period-default"} ne "" )
	{
		$threshold_period = $C->{"threshold_period-default"};
	}
	### 2013-09-16 keiths, User defined threshold periods.
	if ( exists $C->{"threshold_period-$type"} and $C->{"threshold_period-$type"} ne "" )
	{
		$threshold_period = $C->{"threshold_period-$type"};
		dbg("Found Configured Threshold for $type, changing to \"$threshold_period\"");
	}

	#	check if values are already in table (done by doSummaryBuild)
	if ( exists $sts->{$S->{name}}{$type} )
	{
		$stats = $sts->{$S->{name}}{$type};
	}
	else
	{
		$stats = getSummaryStats(
			sys   => $S,
			type  => $type,
			start => $threshold_period,
			end   => 'now',
			index => $index,
			item  => $item
		);
	}

	# get name of element
	my ($inventory,$data);

	if ( $index eq '' )
	{
		$element = '';
	}
	elsif ( $index ne '' and $thrname eq "env_temp" )
	{
		$element = $ET->{$index}{tempDescr};
	}
	elsif ( $index ne '' and $thrname =~ /^hrsmpcpu/ )
	{
		$element = "CPU $index";
	}
	elsif ( $index ne '' and $thrname =~ /^hrdisk/ )
	{		
		$inventory = $S->inventory( concept => 'storage', index => $index );
		$data = ( $inventory ) ? $inventory->data : {};
		$element = "$data->{hrStorageDescr}";
	}
	elsif ( $type =~ /cbqos|interface|pkts/ )
	{
		my $inventory = $S->inventory( concept => 'interface', index => $index );
		$data = ( $inventory ) ? $inventory->data : {};
		if( $data->{ifDescr} )
		{
			$element = $data->{ifDescr};
			$element = "$data->{ifDescr}: $item" if($type =~ /cbqos/);
		}		
	}	
	elsif ( defined $M->{systemHealth}{sys}{$type}{indexed}
		and $M->{systemHealth}{sys}{$type}{indexed} ne "true" )
	{
		NMISNG::Util::TODO("Inventory migration not complete here (and below)");
		my $elementVar = $M->{systemHealth}{sys}{$type}{indexed};
		$inventory = $S->inventory( concept => $type, index => $index );
		$data = ($inventory) ? $inventory->data() : {};
		$element = $data->{$elementVar} if ($data->{$elementVar} ne "" );		
	}
	if ( $element eq "" )
	{
		$element = $index;
	}

	# walk through threshold names
	$thrname = stripSpaces($thrname);
	my @nm_list = split( /,/, $thrname );
	foreach my $nm (@nm_list)
	{
		dbg("processing threshold $nm");

		# check for control_regex
		if (    defined $M->{threshold}{name}{$nm}
			and $M->{threshold}{name}{$nm}{control_regex} ne ""
			and $item ne "" )
		{
			if ( $item =~ /$M->{threshold}{name}{$nm}{control_regex}/ )
			{
				dbg("MATCHED threshold $nm control_regex MATCHED $item");
			}
			else
			{
				dbg("SKIPPING threshold $nm: $item did not match control_regex");
				next();
			}
		}

		my ( $level, $value, $thrvalue, $reset ) = getThresholdLevel(
			sys     => $S,
			thrname => $nm,
			stats   => $stats,
			index   => $index,
			item    => $item
		);

		# get 'Proactive ....' string of Model
		my $event = $S->parseString( string => $M->{threshold}{name}{$nm}{event}, index => $index, eval => 0 );

		my $details = "";
		my $spacer  = "";

		if ( $type =~ /interface|pkts/ &&  $data->{Description} ne "" )
		{
			$details = $data->{Description};
			$spacer  = " ";
		}

		### 2014-08-27 keiths, display human speed and handle ifSpeedIn and ifSpeedOut
		if (    getbool( $C->{global_events_bandwidth} )
			and $type =~ /interface|pkts/
			and $data->{ifSpeed} ne "" )
		{
			my $ifSpeed = $data->{ifSpeed};

			if ( $event =~ /Input/ and exists $data->{ifSpeedIn} and $data->{ifSpeedIn} )
			{
				$ifSpeed = $data->{ifSpeedIn};
			}
			elsif ( $event =~ /Output/ and exists $data->{ifSpeedOut} and $data->{ifSpeedOut} )
			{
				$ifSpeed = $data->{ifSpeedOut};
			}
			$details .= $spacer . "Bandwidth=" . convertIfSpeed($ifSpeed);
		}

		thresholdProcess(
			sys      => $S,
			type     => $type,       # crucial for event context
			event    => $event,
			level    => $level,
			element  => $element,    # crucial for context
			details  => $details,
			value    => $value,
			thrvalue => $thrvalue,
			reset    => $reset,
			thrname  => $nm,         # crucial for context
			index    => $index,      # crucial for context
			class    => $class
		);                           # crucial for context
	}
}

sub getThresholdLevel
{
	my %args = @_;
	my $S    = $args{sys};	
	my $M    = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $thrname = $args{thrname};
	my $stats   = $args{stats};      # value of items
	my $index   = $args{index};
	my $item    = $args{item};

	my $val;
	my $level;
	my $thrvalue;

	dbg("Start threshold=$thrname, index=$index item=$item");

	# find subsection with threshold values in Model
	my $T = $M->{threshold}{name}{$thrname}{select};
	foreach my $thr ( sort { $a <=> $b } keys %{$T} )
	{
		next if $thr eq 'default';    # skip now the default values
		if ( ( $S->parseString( string => "($T->{$thr}{control})?1:0", index => $index, item => $item, eval => 1 ) ) )
		{
			$val = $T->{$thr}{value};
			dbg("found threshold=$thrname entry=$thr");
			last;
		}
	}

	# if not found and there are default values available get this now
	if ( $val eq "" and $T->{default}{value} ne "" )
	{
		$val = $T->{default}{value};
		dbg("found threshold=$thrname entry=default");
	}
	if ( $val eq "" )
	{
		logMsg("ERROR, no threshold=$thrname entry found in Model=$catchall_data->{nodeModel}");
		return;
	}

	my $value;    # value of doSummary()
	my $reset = 0;

	# item is the attribute name of summary stats of Model
	$value = $stats->{$M->{threshold}{name}{$thrname}{item}}         if $index eq "";
	$value = $stats->{$index}{$M->{threshold}{name}{$thrname}{item}} if $index ne "";
	dbg("threshold=$thrname, item=$M->{threshold}{name}{$thrname}{item}, value=$value");

	# check unknow value
	if ( $value =~ /NaN/i )
	{
		dbg("INFO, illegal value $value, skipped");
		return ( "Normal", $value, $reset );
	}

	### all zeros policy to disable thresholding - match and return 'normal'
	if (    $val->{warning} == 0
		and $val->{minor} == 0
		and $val->{major} == 0
		and $val->{critical} == 0
		and $val->{fatal} == 0
		and defined $val->{warning}
		and defined $val->{minor}
		and defined $val->{major}
		and defined $val->{critical}
		and defined $val->{fatal} )
	{
		return ( "Normal", $value, $reset );
	}

	# Thresholds for higher being good and lower bad
	if (    $val->{warning} > $val->{fatal}
		and defined $val->{warning}
		and defined $val->{minor}
		and defined $val->{major}
		and defined $val->{critical}
		and defined $val->{fatal} )
	{
		if ( $value <= $val->{fatal} ) { $level = "Fatal"; $thrvalue = $val->{fatal}; }
		elsif ( $value <= $val->{critical} and $value > $val->{fatal} )
		{
			$level    = "Critical";
			$thrvalue = $val->{critical};
		}
		elsif ( $value <= $val->{major} and $value > $val->{critical} ) { $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value <= $val->{minor} and $value > $val->{major} )    { $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value <= $val->{warning} and $value > $val->{minor} )
		{
			$level    = "Warning";
			$thrvalue = $val->{warning};
		}
		elsif ( $value > $val->{warning} ) { $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
	}

	# Thresholds for lower being good and higher being bad
	elsif ( $val->{warning} < $val->{fatal}
		and defined $val->{warning}
		and defined $val->{minor}
		and defined $val->{major}
		and defined $val->{critical}
		and defined $val->{fatal} )
	{
		if ( $value < $val->{warning} ) { $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
		elsif ( $value >= $val->{warning} and $value < $val->{minor} )
		{
			$level    = "Warning";
			$thrvalue = $val->{warning};
		}
		elsif ( $value >= $val->{minor} and $value < $val->{major} )    { $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value >= $val->{major} and $value < $val->{critical} ) { $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value >= $val->{critical} and $value < $val->{fatal} )
		{
			$level    = "Critical";
			$thrvalue = $val->{critical};
		}
		elsif ( $value >= $val->{fatal} ) { $level = "Fatal"; $thrvalue = $val->{fatal}; }
	}
	if ( $level eq "" )
	{
		logMsg(
			"ERROR no policy found, threshold=$thrname, value=$value, node=$S->{name}, model=$catchall_data->{nodeModel} section threshold"
		);
		$level = "Normal";
	}
	dbg("result threshold=$thrname, level=$level, value=$value, thrvalue=$thrvalue, reset=$reset");
	return ( $level, $value, $thrvalue, $reset );
}

sub thresholdProcess
{
	my %args = @_;
	my $S    = $args{sys};

	# fixme why no error checking? what about negative or floating point values like 1.3e5?
	if ( $args{value} =~ /^\d+$|^\d+\.\d+$/ )
	{
		info("$args{event}, $args{level}, $args{element}, value=$args{value} reset=$args{reset}");

		my $details = "Value=$args{value} Threshold=$args{thrvalue}";
		if ( defined $args{details} and $args{details} ne "" )
		{
			$details = "$args{details}: Value=$args{value} Threshold=$args{thrvalue}";
		}
		my $statusResult = "ok";
		if ( $args{level} =~ /Normal/i )
		{
			checkEvent(
				sys     => $S,
				event   => $args{event},
				level   => $args{level},
				element => $args{element},
				details => $details,
				value   => $args{value},
				reset   => $args{reset}
			);
		}
		else
		{
			notify(
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
				}
			);
			$statusResult = "error";
		}
		my $index = $args{index};
		if ( $index eq "" )
		{
			$index = 0;
		}
		my $statusKey = "$args{thrname}--$index";

		$statusKey = "$args{thrname}--$index--$args{class}" if defined $args{class} and $args{class};

		$S->{info}{status}{$statusKey} = {
			method   => "Threshold",
			type     => $args{type},
			property => $args{thrname},
			event    => $args{event},
			index    => $args{index},
			level    => $args{level},
			status   => $statusResult,
			element  => $args{element},
			value    => $args{value},
			updated  => time()
		};
	}
}

sub printRunTime
{
	my $endTime = sprintf( "%.2f", Time::HiRes::time() - $starttime );
	info("End of $0, type=$type ran for $endTime seconds.\n");
}

# iterate over nodes and add any new groups to the configuration
# this is normally NOT automated, as groups are an administrative feature
# for maintenance (as nodes in unlisted groups are active but not
# shown in the gui)
# args: none
# returns: undef if ok, error message otherwise
sub sync_groups
{
	my $NT = loadLocalNodeTable();    # only local nodes
	dbg( "table Local Node loaded", 2 );

	# reread the config with a lock and unflattened
	my $fn = $C->{'<nmis_conf>'} . "/" . ( $nvp{conf} || "Config" ) . ".nmis";
	my ( $rawC, $fh ) = readFiletoHash( file => $fn, lock => 'true' );

	return "Error: failed to read config $fn!" if ( !$rawC or !keys %$rawC );

	my %oldgroups = map { $_ => 1 } ( split( /\s*,\s*/, $rawC->{system}->{group_list} ) );
	my %newgroups;
	for my $node ( keys %$NT )
	{
		my $thisgroup = $NT->{$node}->{group};
		next if ( $oldgroups{$thisgroup} );
		++$newgroups{$thisgroup};
	}

	print "Existing groups:\n\t", ( %oldgroups ? join( "\n\t", keys %oldgroups ) : "<None>" ),
		"\n\nNew groups to add:\n\t", ( %newgroups ? join( "\n\t", keys %newgroups ) : "<None>" ),
		"\n\n";

	if (%newgroups)
	{
		$rawC->{system}->{group_list} = join( ",", sort( keys %oldgroups, keys %newgroups ) );
		writeHashtoFile( file => $fn, handle => $fh, data => $rawC );
	}
	else
	{
		close $fh;
	}

	return;
}

# this is a maintenance command for removing old, broken or unwanted files,
# replaces and extends the old admin/nmis_file_cleanup.sh
#
# args: none, but checks nvp simulate (default: false, if true only prints
# what it would do)
# returns: undef if ok, error message otherwise
sub purge_files
{
	my %nukem;

	info("Starting to look for purgable files");

	# config option, extension, where to look...
	my @purgatory = (
		{   ext          => qr/\.rrd$/,
			minage       => $C->{purge_rrd_after} || 30 * 86400,
			location     => $C->{database_root},
			also_empties => 1,
			description  => "Old RRD files",
		},
		{   ext          => qr/\.(tgz|tar\.gz)$/,
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
		{   minage => $C->{purge_event_after} || 30 * 86400,
			path => qr!events/.+?/history/.+\.json$!,
			also_empties => 1,
			location     => $C->{'<nmis_var>'} . "/events",
			description  => "Old event history files",
		},
		{   minage => $C->{purge_jsonlog_after} || 30 * 86400,
			also_empties => 1,
			ext          => qr/\.json/,
			location     => $C->{json_logs},
			description  => "Old JSON log files",
		},
	);
	my $simulate = getbool( $nvp{simulate} );

	for my $rule (@purgatory)
	{
		my $olderthan = time - $rule->{minage};
		next if ( !$rule->{location} );
		info("checking dir $rule->{location} for $rule->{description}");

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
			print "purge: rule '$nukem{$fn}' matches $shortfn\n";
		}
		else
		{
			info("removing $shortfn (rule '$nukem{$fn}')");
			unlink($fn) or return "Failed to unlink $fn: $!";
		}
	}
	info("Purging complete");
	return;
}

# sysUpTime under nodeinfo is a mess: not only is nmis overwriting it with
# in nonreversible format on the go,
# it's also used by and scribbled over in various places, and needs synthesizing
# from two separate properties in case of a wmi-only node.
#
# this helper takes in a sys object and attempts to make sysUpTime and sysUpTimeSec
# from whatever sys' nodeinfo structure contains.
sub makesysuptime
{
	my ($sys) = @_;
	my $catchall_data = $sys->inventory( concept => 'catchall' )->data_live();

	return if ( !$catchall_data );

	# if this is wmi, we need to make a sysuptime first. these are seconds
	# who should own sysUpTime, this needs to only happen if SNMP not available OMK-3223
	#if ($catchall_data->{wintime} && $catchall_data->{winboottime})
	#{
	#	$catchall_data->{sysUpTime} = 100 * ($catchall_data->{wintime}-$catchall_data->{winboottime});
	#}

	# pre-mangling it's a number, maybe fractional, in 1/100s ticks
	# post-manging it is text, and we can't do a damn thing anymore
	if ( defined( $catchall_data->{sysUpTime} ) && $catchall_data->{sysUpTime} =~ /^\d+(\.\d*)?$/ )
	{
		$catchall_data->{sysUpTimeSec} = int( $catchall_data->{sysUpTime} / 100 );              # save away
		$catchall_data->{sysUpTime}    = func::convUpTime( $catchall_data->{sysUpTimeSec} );    # seconds into text
	}
	return;
}

# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
