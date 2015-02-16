#!/usr/bin/perl
#
## $Id: nmis.pl,v 8.52 2012/12/03 07:47:26 keiths Exp $
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
package main;

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
#
# ****** Shouldn't be anything else to customise below here *******************
# best to customise in the nmis.conf file.
#
require 5.008_001;

use strict;
use csv;				# local
use rrdfunc; 			# createRRD, updateRRD etc.
use NMIS;				# local
use NMIS::Connect;
use NMIS::Timing;
use func;				# local
use ip;					# local
use sapi;				# local
use ping;				# local
use Socket;
use notify;
use Net::SNMP qw(oid_lex_sort);
use Mib;				# local
use Sys;				# local
use Proc::ProcessTable; # from CPAN
use Proc::Queue ':all'; # from CPAN
use Data::Dumper;
use DBfunc;				# local
use Statistics::Lite qw(mean);
use POSIX qw(:sys_wait_h);

Data::Dumper->import();
$Data::Dumper::Indent = 1;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Errno qw(EAGAIN ESRCH EPERM);

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug},info=>$nvp{info});

# and the status of the database dir, as reported by the selftest - 0 bad, 1 ok, undef unknown
# this is used by rrdfunc::createRRD(), so needs to be scoped suitably.
our $selftest_dbdir_status;
$selftest_dbdir_status = undef;

# check for global collection off or on
# useful for disabling nmis poll for server maintenance, nmis upgrades etc.
my $lockoutfile = $C->{'<nmis_conf>'}."/NMIS_IS_LOCKED";

if (-f $lockoutfile or getbool($C->{global_collect},"invert"))
{
	# if nmis is locked, run a quick nondelay selftest so that we have something for the GUI
	my $varsysdir = $C->{'<nmis_var>'}."/nmis_system";
	if (!-d $varsysdir)
	{
		createDir($varsysdir); 
		setFileProt($varsysdir);
	}
	my $selftest_cache = "$varsysdir/selftest";

	my ($allok, $tests) = func::selftest(config => $C, delay_is_ok => 'false', 
																			 report_database_status => \$selftest_dbdir_status);
	writeHashtoFile(file => $selftest_cache, json => 1,
									data => { status => $allok, lastupdate => time, tests => $tests });
	info("Selftest completed (status ".($allok?"ok":"FAILED!")."), cache file written");
	if (-f $lockoutfile)
	{
		die "Attention: NMIS is currently disabled!\nRemove the file $lockoutfile to re-enable.\n\n";
	}
	else
	{ 
		die "Attention: NMIS is currently disabled!\nSet the configuration variable \"global_collect\" to \"true\" to re-enable.\n\n";
	}
}

# all arguments are now stored in nvp (name value pairs)
my $type		= lc $nvp{type};
my $node		= lc $nvp{node};
my $rmefile		= $nvp{rmefile};
my $runGroup	= $nvp{group};
my $sleep	= $nvp{sleep};

### 2012-12-03 keiths, adding some model testing and debugging options.
my $model		= getbool($nvp{model});

# store multithreading arguments in nvp
my $mthread		=$nvp{mthread};
my $mthreadDebug=$nvp{mthreaddebug};
my $maxThreads	=$nvp{maxthreads}||1;

# park the list of collect/update plugins globally
my @active_plugins;

Proc::Queue::size($maxThreads); # changing limit of concurrent processes
Proc::Queue::trace(0); # trace mode on
Proc::Queue::debug(0); # debug is off
Proc::Queue::delay(0.02); # set 20 milliseconds as minimum delay between fork calls, reduce to speed collect times

# if no type given, just run the command line options
if ( $type eq "" ) {
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


if ($type =~ /^(collect|update|services)$/) {
	runThreads(type=>$type,node=>$node,mthread=>$mthread,mthreadDebug=>$mthreadDebug);
}
elsif ( $type eq "escalate") { runEscalate(); printRunTime(); } # included in type=collect
elsif ( $type eq "config" ) { checkConfig(change => "true"); }
elsif ( $type eq "audit" ) { checkConfig(audit => "true", change => "false"); }
elsif ( $type eq "links" ) { runLinks(); } # included in type=update
elsif ( $type eq "apache" ) { printApache(); }
elsif ( $type eq "apache24" ) { printApache24(); }
elsif ( $type eq "crontab" ) { printCrontab(); }
elsif ( $type eq "summary" ) { nmisSummary(); printRunTime(); } # included in type=collect
elsif ( $type eq "rme" ) { loadRMENodes($rmefile); }
elsif ( $type eq "threshold" ) { runThreshold($node); printRunTime(); } # included in type=collect
elsif ( $type eq "master" ) { nmisMaster(); printRunTime(); } # included in type=collect
elsif ( $type eq "groupsync" ) { sync_groups(); }
else { checkArgs(); }

exit;

#=========================================================================================

# run collection-type functions, possibly spread across multiple processes
sub	runThreads 
{
	my %args = @_;
	my $type = $args{type};
	my $node_select = $args{'node'};
	my $mthread = getbool($args{mthread});
	my $mthreadDebug = getbool($args{mthreadDebug});
	my $debug_watch;

	dbg("Starting, operation is $type");

	# first thing: do a selftest and cache the result. this takes about five seconds (for the process stats)
	# however, DON'T do one if nmis is run in handle-just-this-node mode, which is usually a debugging exercise
	# which shouldn't be delayed at all. ditto for (possibly VERY) frequent type=services
	if (!$node_select and $type ne "services")
	{
		info("Starting selftest (takes about 5 seconds)...");
		my $varsysdir = $C->{'<nmis_var>'}."/nmis_system";
		if (!-d $varsysdir)
		{
			createDir($varsysdir); 
			setFileProt($varsysdir);
		}
		
		my $selftest_cache = "$varsysdir/selftest";
		my ($allok, $tests) = func::selftest(config => $C, delay_is_ok => 'true',
																				 report_database_status => \$selftest_dbdir_status);
		writeHashtoFile(file => $selftest_cache, json => 1,
									data => { status => $allok, lastupdate => time, tests => $tests });
		info("Selftest completed (status ".($allok?"ok":"FAILED!")."), cache file written");
	}

	# load all the files we need here
	loadEnterpriseTable() if $type eq 'update'; # load in cache
	dbg("table Enterprise loaded",2);

	loadNodeConfTable(); # load in cache
	dbg("table Node Config loaded",2);

	if (!getbool($C->{db_events_sql})) {
		loadEventStateNoLock(); # load in cache
		dbg("table Event loaded",2);
	}

	my $NT = loadLocalNodeTable(); 	# only local nodes
	dbg("table Local Node loaded",2);

	my $C = loadConfTable();		# config table from cache

	if (getbool($C->{daemon_fping_active})) {
		my $pt = loadTable(dir=>'var',name=>'nmis-fping'); # load fping table in cache
		my $nt = loadNodeConfTable();
		my $cnt_pt = keys %{$pt};
		my $cnt_nt = keys %{$nt};
		# missing more then 10 entries ?
		if ($cnt_pt+10 < $cnt_nt) {
			logMsg("ERROR fping table missing to many entries, count fping=$cnt_pt count nodes=$cnt_nt");
			$C->{daemon_fping_failed} = 'true'; # remember for runPing
		}
	}
	dbg("all relevant tables loaded");

	my $debug_global = $C->{debug};
	my $debug = $C->{debug};
	my $PIDFILE;
	my $pid;

	# used for plotting major events on world map in 'Current Events' display
	$C->{netDNS} = 0;
	if ( getbool($C->{DNSLoc}) ) {
		# decide if Net::DNS is available to us or not
		if ( eval "require Net::DNS") {
					$C->{netDNS} = 1;
					require Net::DNS;
		}
		else {
			print "Perl Module Net::DNS not found, Can't use DNS LOC records for Geo info, will try sysLocation\n" if $debug;
		}
	}

	# Find kernel name
	my $kernel;
	if (defined $C->{os_kernelname} and $C->{os_kernelname} ne "") {
		$kernel = $C->{os_kernelname};
	} elsif ($^O !~ /linux/i) {
		$kernel = $^O;
	} else {
		chomp($kernel = lc `uname -s`);
	}
	$C->{kernel} = $kernel; # global
	dbg("Kernel name of NMIS server is $kernel");

	runDaemons(); # start daemon processes


	#==============================================

	### test if we are still running, or zombied, and cron will email somebody if we are
	### collects should not run past 5mins - if they do we have a problem
	### updates can run past 5 mins, BUT no two updates should run at the same time
	### for potentially frequent type=services we don't do any of these.
	if ( $type eq 'collect' or $type eq "update")
	{
		# unrelated but also for collect and update only
		@active_plugins = &load_plugins;

		# first find all other nmis collect processes
		my $others = func::find_nmis_processes(type => $type, config => $C);

		# if this is a collect and if told to ignore running processes (ignore_running=1/t), 
		# then only warn about processes and don't shoot them.
		# the same should be done if this is an interactive run with info or debug
		if (($type eq "collect" and ( getbool($nvp{ignore_running})
																	or $C->{debug} or $C->{info} ))
				or ($type eq "update" and ($C->{debug} or $C->{info})))
		{
			for my $pid (keys %{$others})
			{
				logMsg("INFO ignoring old process $pid that is still running: $type, $others->{$pid}->{node}, started at ".returnDateStamp($others->{$pid}->{start}));
			}
		}
		else
		{
			my $eventconfig = loadTable(dir => 'conf', name => 'Events');
			my $event = "NMIS runtime exceeded";
			my $thisevent_control = $eventconfig->{$event} || { Log => "true", Notify => "true", Status => "true"};

			# if not told otherwise, shoot the others politely
			for my $pid (keys %{$others})
			{
				print STDERR "Error: killing old NMIS $type process $pid which has not finished!\n";
				logMsg("ERROR killing old NMIS $type process $pid which has not finished!");
				
				kill("TERM",$pid);
				
				# and raise an event to inform the operator - unless told NOT to
				# ie: either disable_nmis_process_events is set to true OR the event control Log property is set to false
				if ((!defined $C->{disable_nmis_process_events} or !getbool($C->{disable_nmis_process_events})
						 and getbool($thisevent_control->{Log})))
				{
					logEvent(node => $C->{server_name},
									 event => $event,
									 level => "Warning",
									 element => $others->{$pid}->{node},
									 details => "Killed process $pid, $type of $others->{$pid}->{node}, started at "
									 .returnDateStamp($others->{$pid}->{start}));
				}
			}
			if (keys %{$others}) # for the others to shut down cleanly
			{
				my $grace = 5;
				logMsg("INFO sleeping for $grace seconds to let old NMIS processes clean up");
				sleep($grace);
			}
		}
	}

	# the signal handler handles termination more-or-less gracefully, 
	# and knows about critical sections
	$SIG{INT} =  \&catch_zap;
	$SIG{TERM} =  \&catch_zap;
	$SIG{HUP} = \&catch_zap;
	$SIG{ALRM} = \&catch_zap;

	my $nodecount = 0;
	my $maxprocs = 1;							# this one

	my $meth;
	if ($type eq "update") {
		$meth = \&doUpdate;
		logMsg("INFO start of update process");
	} 
	elsif ($type eq "collect")
	{
		logMsg("INFO start of collect process");
		$meth = \&doCollect;
	}
	elsif ($type eq "services")
	{
		$meth = \&doServices;
	}
	else
	{
		die "Unknown operation type=$type, terminating!\n";
	}

	# update the operation start/stop timestamp
	func::update_operations_stamp(type => $type, start => $C->{starttime}, stop => undef);

	# don't run longer than X seconds for the main process, only if in non-thread mode or specific node
	alarm($C->{max_child_runtime}) if (defined $C->{max_child_runtime} && (!$mthread or $node_select));
	
	my @list_of_handled_nodes;		# for any after_x_plugin() functions
	if ($node_select eq "")
	{
		# operate on all nodes, sort the nodes so we get consistent polling cycles
		# sort could be more sophisticated if we like, eg sort by core, dist, access or group
		foreach my $onenode (sort keys %{$NT}) {
			# This will allow debugging to be turned on for a
			# specific node where there is a problem
			if ( $onenode eq "$debug_watch" ) {
				$debug = "true";
			} else { $debug = $debug_global; }

			# KS 16 Mar 02, implementing David Gay's requirement for deactiving
			# a node, ie keep a node in nodes.csv but no collection done.
			# also if $runGroup set, only do the nodes for that group.
			if ( $runGroup eq "" or $NT->{$onenode}{group} eq $runGroup ) {
				if ( getbool($NT->{$onenode}{active}) ) {
					++$nodecount;
					push @list_of_handled_nodes, $onenode;
					
					# One process for each node until maxThreads is reached.
					# This loop is entered only if the commandlinevariable mthread=true is used!
					if ($mthread)
					{
						my $pid=fork;
						if ( defined ($pid) and $pid==0) {

							# this will be run only by the child
							if ($mthreadDebug) {
								print "CHILD $$-> I am a CHILD with the PID $$ processing $onenode\n";
							}
							
							# don't run longer than X seconds
							alarm($C->{max_child_runtime})
									if (defined $C->{max_child_runtime});
							&$meth(name=>$onenode);
							alarm(0) if (defined $C->{max_child_runtime});

							# all the work in this thread is done now this child will die.
							if ($mthreadDebug) {
								print "CHILD $$-> $onenode will now exit\n";
							}

							# killing child
							exit 0;
						} # end of child
						else
						{
							# parent
							my $others = func::find_nmis_processes(config => $C);
							my $procs_now = 1 + scalar keys %$others; # the current process isn't returned
							$maxprocs = $procs_now if $procs_now > $maxprocs;
						}
					}
					else 
					{
						# iterate over nodes in this process, if mthread is false
						&$meth(name=>$onenode);
					}
				} #if active
				else {
					 dbg("Skipping as $onenode is marked 'inactive'");
				}
			} #if runGroup
		} # foreach $onenode

		# only do the child process cleanup if we have mthread enabled
		if ($mthread) {
			# cleanup
			# wait this will block until children are done
			1 while wait != -1;
		}
	} else {
		# specific node is given to work on, threading not relevant
		if ( (my $node = checkNodeName($node_select))) { # ignore lc & uc
			if ( getbool($NT->{$node}{active}) ) {
				++$nodecount;
				push @list_of_handled_nodes, $node;
				&$meth(name=>$node);
			}
			else {
				 dbg("Skipping as $node_select is marked 'inactive'");
			}
		}
		else {
			print "\t Invalid node $node_select No node of that name!\n";
			return;
		}
	}

	alarm(0) if (defined $C->{max_child_runtime} && (!$mthread or $node_select));

	dbg("### continue normally ###");
	$C->{collecttime} = time();

	my $S;
	# on update prime the interface summary
	if ( $type eq "update" )
	{
		### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
		getNodeAllInfo(); # store node info in <nmis_var>/nmis-nodeinfo.xxxx
		if ( !getbool($C->{disable_interfaces_summary}) ) {
			getIntfAllInfo(); # concatencate all the interface info in <nmis_var>/nmis-interfaces.xxxx
			runLinks();
		}
	}
	# some collect post-processing, but only if running on all nodes
	elsif ( $type eq "collect" and $node_select eq "" ) 
	{
		$S = Sys->new; # object nmis-system
		$S->init();
		my $NI = $S->ndinfo;
		delete $NI->{database};	 # remove pre-8.5.0 key as it's not used anymore

		### 2011-12-29 keiths, adding a general purpose master control thing, run reliably every poll cycle.
		if ( getbool($C->{'nmis_master_poll_cycle'}) or !getbool($C->{'nmis_master_poll_cycle'},"invert") ) {
			dbg("Starting nmisMaster");
			nmisMaster() if getbool($C->{server_master});	# do some masterly type things.
		}		else {
			dbg("Skipping nmisMaster with configuration 'nmis_master_poll_cycle' = $C->{'nmis_master_poll_cycle'}");
		}

		if ( getbool($C->{'nmis_summary_poll_cycle'}) or !getbool($C->{'nmis_summary_poll_cycle'},"invert") ) {
			dbg("Starting nmisSummary");
			nmisSummary() if getbool($C->{cache_summary_tables});	# calculate and cache the summary stats
		}
		else {
			dbg("Skipping nmisSummary with configuration 'nmis_summary_poll_cycle' = $C->{'nmis_summary_poll_cycle'}");
		}

		dbg("Starting runMetrics");
		runMetrics(sys=>$S);

		### 2013-02-22 keiths, disable thresholding on the poll cycle only.
		if ( getbool($C->{threshold_poll_cycle}) or !getbool($C->{threshold_poll_cycle},"invert") ) {
			dbg("Starting runThreshold");
			runThreshold($node_select);
		}
		else {
			dbg("Skipping runThreshold with configuration 'threshold_poll_cycle' = $C->{'threshold_poll_cycle'}");
		}

		dbg("Starting runEscalate");
		runEscalate();

		# nmis collect runtime, process counts and save
		my $D;
		$D->{collect}{value} = $C->{collecttime} - $C->{starttime};
		$D->{collect}{option} = 'gauge,0:U';
		$D->{total}{value} = time() - $C->{starttime};
		$D->{total}{option} = 'gauge,0:U';

		my $nr_processes = 1+ scalar %{&func::find_nmis_processes(config => $C)}; # current one isn't returned by find_nmis_processes
		$D->{nr_procs} = { option => "gauge,0:U",
											 value => $nr_processes };
		$D->{max_procs} = { option => "gauge,0:U",
												value => $maxprocs };
		
		if (( my $db = updateRRD(data=>$D, sys=>$S, type=>"nmis"))) {
			$NI->{graphtype}{nmis} = 'nmis';
		}
		$S->writeNodeInfo; # var/nmis-system.xxxx, the base info system
	}

	if ($type eq "collect" or $type eq "update")
	{
		# now run all after_{collect,update}_plugin() functions, regardless of whether 
		# this was a one-node or all-nodes run
		for my $plugin (@active_plugins)
		{
			my $funcname = $plugin->can("after_${type}_plugin");
			next if (!$funcname);
			
			# prime the global sys object, if this was an update run or a one-node collect
			if (!$S)
			{
				$S = Sys->new;					# the nmis-system object
				$S->init();
			}

			dbg("Running after_$type plugin $plugin");
			logMsg("Running after_$type plugin $plugin");
			my ($status, @errors);
			eval { ($status, @errors) = &$funcname(sys => $S, config => $C, nodes => \@list_of_handled_nodes); };
			if ($status >=2 or $status < 0 or $@)
			{
				logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
				for my $err (@errors)
				{
					logMsg("Error: Plugin $plugin: $err");
				}
			}
			elsif ($status == 1)						# changes were made, need to re-save info file
			{
				dbg("Plugin $plugin indicated success, updating nmis-system file");
				$S->writeNodeInfo;
			}
			elsif ($status == 0)
			{
				dbg("Plugin $plugin indicated no changes");
			}
		}
	}
	
	logMsg("INFO end of $type process");

	if ($C->{info} or $debug or $mthreadDebug) {
		my $endTime = time() - $C->{starttime};
		my $stats = getUpdateStats();
		print "\n".returnTime ." Number of Data Points: $stats->{datapoints}, Sum of Bytes: $stats->{databytes}, RRDs updated: $stats->{rrdcount}, Nodes with Updates: $stats->{nodecount}\n";
		print "\n".returnTime ." End of $0 Processed $nodecount nodes ran for $endTime seconds.\n\n";
	}

	func::update_operations_stamp(type => $type, start => $C->{starttime}, stop => time());

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
	if ($rs eq "ALRM" and (!defined $C->{disable_nmis_process_events} 
												 or !getbool($C->{disable_nmis_process_events})))
	{
		logEvent(node => $C->{server_name},
						 event => "NMIS runtime exceeded",
						 level => "Warning",
						 element => undef,
						 details => "Process $$, $0, has exceeded its max run time and is terminating");
	}

	# do a graceful shutdown if in critical, and if this is the FIRST interrupt
	my $pending_ints = func::interrupt_pending; # scalar ref
	if (func::in_critical_section && !$$pending_ints)
	{
		logMsg("INFO process in critical section, marking as signal $rs pending");
		++$$pending_ints;
	}
	else
	{
		logMsg("INFO Process $$ ($0) was killed by signal $rs");
		die "Process $$ ($0) was killed by signal $rs\n";
	}
}

#====================================================================================

sub doUpdate {
	my %args = @_;
	my $name = $args{name};
	my $C = loadConfTable();

	dbg("================================");
	dbg("Starting update, node $name");

	# lets change our name, so a ps will report who we are
	$0 = "nmis-".$C->{conf}."-update-$name";


	my $S = Sys::->new; # create system object
	$S->init(name=>$name,update=>'true'); # loads old node info, and the DEFAULT(!) model (always)
	# loads the node config, and updates model and type in node info table but only if missing
	$S->copyModelCfgInfo(type=>'all');

	my $NI = $S->ndinfo;
	my $NC = $S->ndcfg;
	$S->{doupdate} = 'true'; # flag what is running
	$S->readNodeView; # from prev. run
	# if reachable then we can update the model and get rid of the default we got from init above
	if (runPing(sys=>$S)) {
		if ($S->open(timeout => $C->{snmp_timeout}, retries => $C->{snmp_retries}, max_msg_size => $C->{snmp_max_msg_size})) {
			if (getNodeInfo(sys=>$S)) {
				# getnodeinfo has deleted the interface info, need to rebuild from scratch
				if ( getbool($NC->{node}{collect}) ) {
					if (getIntfInfo(sys=>$S)) {
						#print Dumper($S)."\n";
						# print what we are
						dbg("node=$S->{name} role=$NI->{system}{roleType} type=$NI->{system}{nodeType}");
						dbg("vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}");

						### 2012-12-03 keiths, adding some model testing and debugging options.
						if ( $model ) {
							print "MODEL $S->{name}: role=$NI->{system}{roleType} type=$NI->{system}{nodeType} sysObjectID=$NI->{system}{sysObjectID} sysObjectName=$NI->{system}{sysObjectName}\n";
							print "MODEL $S->{name}: sysDescr=$NI->{system}{sysDescr}\n";
							print "MODEL $S->{name}: vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}\n";
						}
						getSystemHealthInfo(sys=>$S) if defined $S->{mdl}{systemHealth};
						getEnvInfo(sys=>$S);
						getCBQoS(sys=>$S); # do walk
						getCalls(sys=>$S); # do walk
					}
				} else {
					dbg("no node info collected");
				}
			}
			else {
				### 2012-10-24 keiths, fixing nodes loosing config when down during an update
				$NI->{system}{nodeModel} = 'Generic' if $NI->{system}{nodeModel} eq "";	# nmisdev Dec2010 first time model seen, collect, but no snmp answer
				$NI->{system}{nodeType} = 'generic' if $NI->{system}{nodeType} eq "";
			}
			$S->close; # close snmp session
			### 2014-12-16 keiths, when did the update poll last complete properly.
			$NI->{system}{lastUpdatePoll} = time();
		}
	} else {		# no ping, no snmp, no type
		$NI->{system}{nodeModel} = 'Generic' if $NI->{system}{nodeModel} eq "";		# nmisdev Dec2010 first time model seen, collect, but no snmp answer
		$NI->{system}{nodeType} = 'generic' if $NI->{system}{nodeType} eq "";
	}
	#print Dumper($S)."\n";
	runReach(sys=>$S);
	$S->writeNodeView;  # save node view info in file var/$NI->{name}-view.xxxx
	$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.xxxx

	# done with the standard work, now run any plugins that offer update_plugin()
	for my $plugin (@active_plugins)
	{
		my $funcname = $plugin->can("update_plugin");
		next if (!$funcname);

		dbg("Running update plugin $plugin with node $name");
		my ($status, @errors);
		eval { ($status, @errors) = &$funcname(node => $name, sys => $S, config => $C); };
		if ($status >=2 or $status < 0 or $@)
		{
			logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				logMsg("Error: Plugin $plugin: $err");
			}
		}
		elsif ($status == 1)						# changes were made, need to re-save the view and info files
		{
			dbg("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
			$S->writeNodeInfo;
		}
		elsif ($status == 0)
		{
			dbg("Plugin $plugin indicated no changes");
		}
	}

	### 2013-03-19 keiths, NMIS Plugins!
	# fixme: deprecated, to be removed once all model-level custom plugins are converted to new plugin infrastructure
	# and when the remaining customers using this have upgraded
	runCustomPlugins(node => $name, sys=>$S) if (defined $S->{mdl}{custom});

	dbg("Finished");
	return;
} # end runUpdate

#=========================================================================================

# a function to load the available code plugins,
# returns the list of package names that have working plugins
sub load_plugins
{
	my @activeplugins;
	
	# check for plugins enabled and the dir
	return () if (!getbool($C->{plugins_enabled})
								or !$C->{plugin_root} or !-d $C->{plugin_root});

	if (!opendir(PD, $C->{plugin_root}))
	{
		logMsg("Error: cannot open plugin dir $C->{plugin_root}: $!");
		return ();
	}
	my @candidates = grep(/\.pm$/, readdir(PD));
	closedir(PD);

	for my $candidate (@candidates)
	{
		my $packagename = $candidate; 
		$packagename =~ s/\.pm$//;

		# read it and check that it has precisely one matching package line
		dbg("Checking candidate plugin $candidate");
		if (!open(F,$C->{plugin_root}."/$candidate"))
		{
			logMsg("Error: cannot open plugin file $candidate: $!");
			next;
		}
		my @plugindata = <F>;
		close F;
		my @packagelines = grep(/^\s*package\s+[a-zA-Z0-9_:-]+\s*;\s*$/, @plugindata);
		if (@packagelines > 1 or $packagelines[0] !~ /^\s*package\s+$packagename\s*;\s*$/)
		{
			logMsg("Plugin $candidate doesn't have correct \"package\" declaration. Ignoring.");
			next;
		}

		# do the actual load and eval
		eval { require $C->{plugin_root}."/$candidate"; };
		if ($@)
		{
			logMsg("Ignoring plugin $candidate as it isn't valid perl: $@");
			next;
		}

		# we're interested if one or more of the supported plugin functions are provided
		push @activeplugins, $packagename 
				if ($packagename->can("update_plugin") 
						or $packagename->can("collect_plugin")
						or $packagename->can("after_collect_plugin")
						or $packagename->can("after_update_plugin") );
	}

	return sort @activeplugins;
}


# args: only name (node name)
# returns: nothing
sub doServices
{
	my (%args) = @_;
	my $name = $args{name};

	info("================================");
	info("Starting services, node $name");

	# lets change our name, so a ps will report who we are
	$0 = "nmis-".$C->{conf}."-services-$name";

	my $S = Sys->new;
	$S->init(name => $name);
	runServices(sys=>$S);
	
	return;
}


sub doCollect {
	my %args = @_;
	my $name = $args{name};

	info("================================");
	info("Starting collect, node $name");

	# lets change our name, so a ps will report who we are
	$0 = "nmis-".$C->{conf}."-collect-$name";

	my $S = Sys::->new; # create system object
	### 2013-02-25 keiths, fixing down node refreshing......
	#if (! $S->init(name=>$name) || $S->{info}{system}{nodedown} eq 'true') {
	#dbg("no info available of node $name or node was down, nodedown=$S->{info}{system}{nodedown}, refresh it");
	if (! $S->init(name=>$name) ) {
		info("no info available of node $name, refresh it");
		doUpdate(name=>$name);
		info("Finished");
		return; # next run to collect
	}

	my $NI = $S->ndinfo;
	my $NC = $S->ndcfg;

	### 2014-12-16 keiths, run an update if no update poll has been run.
	if ( not exists $NI->{system}{lastUpdatePoll} or (exists $NI->{system}{lastUpdatePoll} and not $NI->{system}{lastUpdatePoll}) ) {
		info("no cached node data available, running an update now");
		doUpdate(name=>$name);
		info("update done, continue with collect");
	}

	$S->{docollect} = 'true'; # flag what is running
	$S->readNodeView; # from prev. run
	# print what we are
	info("node=$NI->{system}{name} role=$NI->{system}{roleType} type=$NI->{system}{nodeType}");
	info("vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}");

	if (runPing(sys=>$S)) {
		if ($S->open(timeout => $C->{snmp_timeout}, retries => $C->{snmp_retries}, max_msg_size => $C->{snmp_max_msg_size})) {
			# oke, node reachable
			if ( getbool($NC->{node}{collect}) ) {
				if (updateNodeInfo(sys=>$S)) {
					# snmp oke
					if ( $C->{snmp_stop_polling_on_error} eq "" ) {
						$C->{snmp_stop_polling_on_error} = "false";
					}
					### 2012-03-28 keiths, improving handling of transient SNMP sessions on bad links
					if ( getbool($C->{snmp_stop_polling_on_error}) and getbool($NI->{system}{snmpdown}) ) {
						logMsg("SNMP Polling stopped for $NI->{system}{name} because SNMP had errors, snmpdown=$NI->{system}{snmpdown} snmp_stop_polling_on_error=$C->{snmp_stop_polling_on_error}");
					}
					else {

						### 2012-12-03 keiths, adding some model testing and debugging options.
						if ( $model or $C->{info}) {
							print "MODEL $S->{name}: role=$NI->{system}{roleType} type=$NI->{system}{nodeType} sysObjectID=$NI->{system}{sysObjectID} sysObjectName=$NI->{system}{sysObjectName}\n";
							print "MODEL $S->{name}: sysDescr=$NI->{system}{sysDescr}\n";
							print "MODEL $S->{name}: vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}\n";
						}

						# get node data and store in rrd
						getNodeData(sys=>$S);

						# get intf data and store in rrd
						getIntfData(sys=>$S) if defined $S->{info}{interface};

						getSystemHealthData(sys=>$S);

						getEnvData(sys=>$S);

						getCBQoS(sys=>$S);

						getCalls(sys=>$S);

						getPVC(sys=>$S);

						### server collection
						runServer(sys=>$S);

						# Custom Alerts
						runAlerts(sys=>$S) if defined $S->{mdl}{alerts};
						
						### 2014-12-16 keiths, when did the collect poll last complete properly.
						$NI->{system}{lastCollectPoll} = time();
					}
				}
			}
		}
	}

	### 2012-09-11 keiths, running services even if node down.
	# Need to poll services even if no ping!
	# run service avail even if no collect
	runServices(sys=>$S);

	runCheckValues(sys=>$S);
	runReach(sys=>$S);

	$S->writeNodeView;
	$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.xxxx

	# done with the standard work, now run any plugins that offer collect_plugin()
	for my $plugin (@active_plugins)
	{
		my $funcname = $plugin->can("collect_plugin");
		next if (!$funcname);

		dbg("Running collect plugin $plugin with node $name");
		my ($status, @errors);
		eval { ($status, @errors) = &$funcname(node => $name, sys => $S, config => $C); };
		if ($status >=2 or $status < 0 or $@)
		{
			logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				logMsg("Error: Plugin $plugin: $err");
			}
		}
		elsif ($status == 1)						# changes were made, need to re-save the view and info files
		{
			dbg("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
			$S->writeNodeInfo;
		}
		elsif ($status == 0)
		{
			dbg("Plugin $plugin indicated no changes");
		}
	}

	$S->close;
	info("Finished");
	return;
} # end runCollect

#=========================================================================================

#
# normaly a daemon fpingd.pl is running (if set in NMIS config) and stores the result in var/fping.xxxx
# if node info missing then ping.pm is used
#
sub runPing {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;	# node info
	my $V =  $S->view;		# web view
	my $RI = $S->reach;		# reach table
	my $M = $S->mdl;		# model table
	my $NC = $S->ndcfg;		# node config
	my ($ping_min,$ping_avg,$ping_max,$ping_loss,$pingresult);
	my $exit = 0; # preset failure
	my $PT;

	$S->{snmpdown_org} = $NI->{system}{snmpdown}; # remember state for log filter in getNodeInfo

	# preset view of node status
	$V->{system}{status_value} = 'unknown';
	$V->{system}{status_title} = 'Node Status';
	$V->{system}{status_color} = '#0F0';

	if (getbool($NC->{node}{ping})) {
		# use fastping info if available
		if (getbool($C->{daemon_fping_active})) {
			$PT = loadTable(dir=>'var',name=>'nmis-fping'); # load ping results (from cache) from daemon fpingd
		}
		if (getbool($C->{daemon_fping_active}) and exists $PT->{$NC->{node}{name}}{loss}) {
			# copy values
			$ping_avg = $PT->{$NC->{node}{name}}{avg};
			$ping_loss = $PT->{$NC->{node}{name}}{loss};
			info("INFO ($S->{name}) PING min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
			#
			# notify and checkevent are handled by fpingd
			if ($ping_loss < 100) {
				# up
				$RI->{pingavg} = $ping_avg; # results for sub runReach
				$RI->{pingresult} = 100;
				$RI->{pingloss} = $ping_loss;
				$exit = 1;	# ok
				# info for web page
				$V->{system}{lastUpdate_value} = returnDateStamp();
				$V->{system}{lastUpdate_title} = 'Last Update';
				$NI->{system}{lastUpdateSec} = time();
			} else {
				# down
				$RI->{pingloss} = $ping_loss;
				$RI->{pingresult} = 0;
			}
		} else {
			# fallback to OLD system
			logMsg("INFO ($S->{name}) standard ping system using, no ping info of daemon fpingd")
					if (getbool($C->{daemon_fping_active}) 
							and !getbool($C->{daemon_fping_failed}) 
							and !getbool($S->{doupdate}));
			my $retries = $C->{ping_retries} ? $C->{ping_retries} : 3;
			my $timeout = $C->{ping_timeout} ? $C->{ping_timeout} : 300 ;
			my $packet = $C->{ping_packet} ? $C->{ping_packet} : 56 ;
			my $host = $NC->{node}{host};			# ip name/adress of node

			info("Starting $S->{name} ($host) with timeout=$timeout retries=$retries packet=$packet");

			if ( $< and getKernelName() !~ /linux/i ) { # not root and update, assume called from www interface
				$pingresult = 100;
				dbg("SKIPPING Pinging as we are NOT running with root priviliges");
			} else {
				( $ping_min, $ping_avg, $ping_max, $ping_loss) = ext_ping($host, $packet, $retries, $timeout );
				$pingresult = defined $ping_min ? 100 : 0;		# ping_min is undef if unreachable.
			}

			if ( $pingresult != 100 ) {
				# Node is down
				$RI->{pingloss} = 100;
				$RI->{pingresult} = $pingresult;
				info("Pinging Failed $S->{name} is NOT REACHABLE");
				logMsg("ERROR ($S->{name}) ping failed") if (!getbool($NI->{system}{nodedown}));

				notify(sys=>$S,event=>"Node Down",element=>"",details=>"Ping failed");
			} else {
				# Node is UP!
				$RI->{pingavg} = $ping_avg; # results for sub runReach
				$RI->{pingresult} = $pingresult;
				$RI->{pingloss} = $ping_loss;
				info("$S->{name} is PINGABLE min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");

				# reset event only if snmp was not the reason of down
				if (!getbool($NI->{system}{snmpdown})) {
					checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"Ping failed");
				}
				$exit = 1;
				# info for web page
				$V->{system}{lastUpdate_value} = returnDateStamp();
				$V->{system}{lastUpdate_title} = 'Last Update';
				$NI->{system}{lastUpdateSec} = time();
			}
		}
	} else {
		info("$S->{name} ping not requested");
		$RI->{pingresult} = 100; # results for sub runReach
		$RI->{pingavg} = 0;
		$RI->{pingloss} = 0;
		$exit = 1;
	}
	if ($exit) {
		$V->{system}{status_value} = 'reachable' if (getbool($NC->{node}{ping}));
		$V->{system}{status_color} = '#0F0';
		$NI->{system}{nodedown} =  'false';
	} else {
		$V->{system}{status_value} = 'unreachable';
		$V->{system}{status_color} = 'red';
		$NI->{system}{nodedown} = 'true';
	}

	info("Finished with exit=$exit, nodedown=$NI->{system}{nodedown}");
	return $exit;
} # end runPing

#=========================================================================================
#
# get node info by snmp, define Model of node
# attention: this deletes the interface info if other steps successful
sub getNodeInfo {
	my %args = @_;
	my $S = $args{sys}; 	# node object
	my $NI = $S->ndinfo;	# node info table
	my $RI = $S->reach;	# reach table
	my $V =  $S->view;	# web view
	my $M  = $S->mdl;	# model table
	my $NC = $S->ndcfg;		# node config
	my $SNMP = $S->snmp;	# snmp object
	my $C = loadConfTable();	# system config

	my $exit = 0; # preset failure
	$RI->{snmpresult} = 0; # preset failure

	info("Starting");

	# cleanups
	if (getbool($S->{doupdate}) and !getbool($NC->{node}{collect}))  # rebuild small
	{
		delete $V->{interface};
		delete $NI->{graphtype};
	}

	########################
	# nmisdev 16Sep2011
	# update nodeConf with manual overides regardless of collect or snmp status
	# code copied here for test

	my $NCT = loadNodeConfTable();


	if (getbool($NC->{node}{collect})) {

		# if node already down then no snmp logging of node down
		$SNMP->logFilterOut("no response from") if (getbool($S->{snmpdown_org}));

		# get node info by snmp: sysDescr, sysObjectID, sysUpTime etc. and store in $NI table
		if ($S->loadNodeInfo(config=>$C)) {

			my $enterpriseTable = loadEnterpriseTable(); # table is already cached

			# Only continue processing if at least a couple of entries are valid.
			if ($NI->{system}{sysDescr} ne "" and $NI->{system}{sysObjectID} ne "" ) {

				# if the vendors product oid file is loaded, this will give product name.
				$NI->{system}{sysObjectName} = oid2name($NI->{system}{sysObjectID});

				info("sysObjectId=$NI->{system}{sysObjectID}, sysObjectName=$NI->{system}{sysObjectName}");
				info("sysDescr=$NI->{system}{sysDescr}");

				# Decide on vendor name.
				my @x = split(/\./,$NI->{system}{sysObjectID});
				my $i = $x[6];
				if ( $enterpriseTable->{$i}{Enterprise} ne "" ) {
					$NI->{system}{nodeVendor} = $enterpriseTable->{$i}{Enterprise};
				} else { $NI->{system}{nodeVendor} =  "Universal"; }
				dbg("oid index $i, Vendor is $NI->{system}{nodeVendor}");

				if ($NC->{node}{model} eq 'automatic' || $NC->{node}{model} eq "") {
					# get nodeModel based on nodeVendor and sysDescr
					$NI->{system}{nodeModel} = $S->selectNodeModel(); # select and save name in node info table
					info("selectNodeModel result model=$NI->{system}{nodeModel}");
					$NI->{system}{nodeModel} = 'Default' if $NI->{system}{nodeModel} eq "";
				} else {
					$NI->{system}{nodeModel} = $NC->{node}{model};
					info("node model=$NI->{system}{nodeModel} set by node config");
				}
				dbg("about to loadModel model=$NI->{system}{nodeModel}");
				$S->loadModel(model=>"Model-$NI->{system}{nodeModel}");

				# now we know more about the host, nodetype and model have been positively determined,
				# so we'll force-overwrite those values
				$S->copyModelCfgInfo(type=>'overwrite');

				###
				delete $V->{system} if getbool($S->{doupdate}); # rebuild

				# add web page info
				$V->{system}{status_value} = 'reachable';
				$V->{system}{status_title} = 'Node Status';
				$V->{system}{status_color} = '#0F0';
				$V->{system}{sysObjectName_value} = $NI->{system}{sysObjectName};
				$V->{system}{sysObjectName_title} = 'Object Name';
				$V->{system}{nodeVendor_value} = $NI->{system}{nodeVendor};
				$V->{system}{nodeVendor_title} = 'Vendor';
				$V->{system}{group_value} = $NI->{system}{group};
				$V->{system}{group_title} = 'Group';
				$V->{system}{customer_value} = $NI->{system}{customer};
				$V->{system}{customer_title} = 'Customer';
				$V->{system}{location_value} = $NI->{system}{location};
				$V->{system}{location_title} = 'Location';
				$V->{system}{businessService_value} = $NI->{system}{businessService};
				$V->{system}{businessService_title} = 'Business Service';
				$V->{system}{serviceStatus_value} = $NI->{system}{serviceStatus};
				$V->{system}{serviceStatus_title} = 'Service Status';
				$V->{system}{notes_value} = $NI->{system}{notes};
				$V->{system}{notes_title} = 'Notes';

				# update node info table with this new model
				if ($S->loadNodeInfo(config=>$C)) {

					$NI->{system}{sysUpTime} = convUpTime($NI->{system}{sysUpTimeSec} = (int($NI->{system}{sysUpTime}/100)));
					$V->{system}{sysUpTime_value} = $NI->{system}{sysUpTime};

					$NI->{system}{server} = $C->{server_name};

					# pull / from VPN3002 system descr
					$NI->{system}{sysDescr} =~ s/\// /g;

					# collect DNS location info.
					getDNSloc(sys=>$S);

					# PIX failover test
					checkPIX(sys=>$S);

					$RI->{snmpresult} = 100; # ok

					$exit = 1; # done
				} else { logMsg("INFO loadNodeInfo failed"); }
			}
			else {
				info("ERROR values of sysDescr and/or sysObjectID are empty");
			}
		} else {
			#  # load this model prev found
			$S->loadModel(model=>"Model-$NI->{system}{nodeModel}") if $NI->{system}{nodeModel} ne '';
		}
	} else {
		dbg("node $S->{name} is marked collect is 'false'");
		$exit = 1; # done
	}
	# modify results by nodeConf ?
	my $node = $NI->{system}{name};
	if ($NCT->{$node}{sysLocation} ne '') {
		$NI->{system}{sysLocation} = $V->{system}{sysLocation_value} = $NCT->{$NI->{system}{name}}{sysLocation};
		$NI->{nodeconf}{sysLocation} = $NI->{system}{sysLocation};
		info("Manual update of sysLocation by nodeConf");
	} else {
		$NI->{system}{sysLocation} = $NI->{system}{sysLocation};
	}
	if ($NCT->{$node}{sysContact} ne '') {
		$NI->{system}{sysContact} = $V->{system}{sysContact_value} = $NCT->{$NI->{system}{name}}{sysContact};
		$NI->{nodeconf}{sysContact} = $NI->{system}{sysContact};
		dbg("Manual update of sysContact by nodeConf");
	} else {
		$NI->{system}{sysContact} = $NI->{system}{sysContact};
	}

	#####################

	# process status
	if ($exit) {
		delete $NI->{interface}; # reset intf info

		### 2012-03-28 keiths, changing to reflect correct event type.
		checkEvent(sys=>$S,event=>"SNMP Down",level=>"Normal",element=>"",details=>"SNMP error");

		# add web page info
		$V->{system}{timezone_value} = $NI->{system}{timezone};
		$V->{system}{timezone_title} = 'Time Zone';
		$V->{system}{nodeModel_value} = $NI->{system}{nodeModel};
		$V->{system}{nodeModel_title} = 'Model';
		$V->{system}{nodeType_value} = $NI->{system}{nodeType};
		$V->{system}{nodeType_title} = 'Type';
		$V->{system}{roleType_value} = $NI->{system}{roleType};
		$V->{system}{roleType_title} = 'Role';
		$V->{system}{netType_value} = $NI->{system}{netType};
		$V->{system}{netType_title} = 'Net';
		# get ip address
		if ((my $addr = resolveDNStoAddr($NI->{system}{host}))) {
			$NI->{system}{host_addr} = $addr; # cache
			if ($addr eq $NI->{system}{host}) {
				$V->{system}{host_addr_value} = $addr;
			} else {
				$V->{system}{host_addr_value} = "$addr ($NI->{system}{host})";
			}
			$V->{system}{host_addr_title} = 'IP Address';
		}
	} else {
		# failed by snmp
		$exit = snmpNodeDown(sys=>$S);

		# node status info web page
		$V->{system}{status_title} = 'Node Status';
		if ( getbool($NC->{node}{ping}) ) {
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		} else {
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	$NI->{system}{nodedown} = $NI->{system}{snmpdown} = $exit ? 'false' : 'true';

	info("Finished with exit=$exit nodedown=$NI->{system}{nodedown}");
	return $exit;
} # end getNodeInfo

#=========================================================================================

sub getDNSloc {
	my %args = @_;
	my $S = $args{sys}; # node object
	my $NI = $S->ndinfo; # node info
	my $C = loadConfTable();

	dbg("Starting");

	# collect DNS location info. Update this info every update pass.
	$NI->{system}{loc_DNSloc} = "unknown";
	my $tmphostname = $NI->{system}{host};
	if ( getbool($C->{loc_from_DNSloc}) and $C->{netDNS} ) {
		my ($rr, $lat, $lon);
		my $res   = Net::DNS::Resolver->new;
		if ($tmphostname =~ /\d+\.\d+\.\d+\.\d+/) {
			# find reverse lookup as this is an ip
			my $query = $res->query("$tmphostname","PTR");
			if ($query) {
				foreach $rr ($query->answer) {
					next unless $rr->type eq "PTR";
					$tmphostname = $rr->ptrdname;
					dbg("DNS Reverse query $tmphostname");
				}
			} else {
				dbg("ERROR, DNS Reverse query failed: $res->errorstring");
			}
		}
		#look up loc for hostname
		my $query = $res->query("$tmphostname","LOC");
		if ($query) {
			foreach $rr ($query->answer) {
				next unless $rr->type eq "LOC";
				($lat, $lon) = $rr->latlon;
				$NI->{system}{loc_DNSloc} = $lat . ",". $lon . ",". $rr->altitude;
				dbg("Location from DNS LOC query is $NI->{system}{loc_DNSloc}");
			}
		} else {
			dbg("ERROR, DNS Loc query failed: $res->errorstring");
		}
	} # end DNSLoc
	# if no DNS based location information found - look at sysLocation in router.....
	# longitude,latitude,altitude,location-text
	if ( getbool($C->{loc_from_sysLoc}) and $NI->{system}{loc_DNSloc} eq "unknown"  ) {
		if ($NI->{system}{sysLocation} =~ /$C->{loc_sysLoc_format}/ ) {
			$NI->{system}{loc_DNSloc} = $NI->{system}{sysLocation};
			dbg("Location from device sysLocation is $NI->{system}{loc_DNSloc}");
		}
	} # end sysLoc
	dbg("Finished");
	return 1;
} # end getDNSloc


#=========================================================================================

sub checkPower {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $V =  $S->view;
	my $M = $S->mdl;
	info("Starting");

	my $attr = $args{attr};

	info("Start with attribute=$attr");

	delete $V->{system}{"${attr}_value"};

	info("Power check attribute=$attr value=$NI->{system}{$attr}");
	if ($NI->{system}{$attr} ne '') {
		if ($NI->{system}{$attr} !~ /noSuch/) {
			$V->{system}{"${attr}_value"} = $NI->{system}{$attr};
			if ( $NI->{system}{$attr} =~ /normal|unknown|notPresent/ ) {
				checkEvent(sys=>$S,event=>"RPS Fail",level=>"Normal",element=>$attr,details=>"RPS failed");
				$V->{system}{"${attr}_color"} = '#0F0';
			} else {
				notify(sys=>$S,event=>"RPS Fail",element=>$attr,details=>"RPS failed");
				$V->{system}{"${attr}_color"} = 'red';
			}
		}
	}

	info("Finished");
	return;

} # end checkPower

#=========================================================================================
sub checkNodeConfiguration {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $V =  $S->view;
	my $M = $S->mdl;
	info("Starting");

	my @updatePrevValues = qw ( configLastChanged configLastSaved bootConfigLastChanged );
	# create previous values if they don't exist
	for my $attr (@updatePrevValues) {
		if (defined $NI->{system}{$attr} ne '' && $NI->{system}{$attr} ne '' && !defined($NI->{system}{"${attr}_prev"}) ) {
			$NI->{system}{"${attr}_prev"} = $NI->{system}{$attr};
		}
	}

	my $configLastChanged = $NI->{system}{configLastChanged} if defined $NI->{system}{configLastChanged};
	my $configLastViewed = $NI->{system}{configLastSaved} if defined $NI->{system}{configLastSaved};
	my $bootConfigLastChanged = $NI->{system}{bootConfigLastChanged} if defined $NI->{system}{bootConfigLastChanged};
	my $configLastChanged_prev = $NI->{system}{configLastChanged_prev} if defined $NI->{system}{configLastChanged_prev};

	if ( defined $configLastViewed && defined $bootConfigLastChanged ) {
		info("checkNodeConfiguration configLastChanged=$configLastChanged, configLastViewed=$configLastViewed, bootConfigLastChanged=$bootConfigLastChanged, configLastChanged_prev=$configLastChanged_prev");
	}
	else {
		info("checkNodeConfiguration configLastChanged=$configLastChanged, configLastChanged_prev=$configLastChanged_prev");		
	}
	
	# check if config is saved:
	$V->{system}{configLastChanged_value} = convUpTime( $configLastChanged/100 ) if defined $configLastChanged;
	$V->{system}{configLastSaved_value} = convUpTime( $configLastViewed/100 ) if defined $configLastViewed;
	$V->{system}{bootConfigLastChanged_value} = convUpTime( $bootConfigLastChanged/100 ) if defined $bootConfigLastChanged;

	### Cisco Node Configuration Change Only
	if( defined $configLastChanged && defined $bootConfigLastChanged ) {
		$V->{system}{configurationState_title} = 'Configuration State';
		
		### when the router reboots bootConfigLastChanged = 0 and configLastChanged is about 2 seconds, which are the changes made by booting.
		if( $configLastChanged > $bootConfigLastChanged and $configLastChanged > 5000 ) {
			$V->{system}{"configurationState_value"} = "Config Not Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#FFDD00";	#warning
			info("checkNodeConfiguration, config not saved, $configLastChanged > $bootConfigLastChanged");
		} 
		elsif( $bootConfigLastChanged == 0 and $configLastChanged <= 5000 ) {
			$V->{system}{"configurationState_value"} = "Config Not Changed Since Boot";
			$V->{system}{"configurationState_color"} = "#00BB00";	#normal
			info("checkNodeConfiguration, config not changed, $configLastChanged $bootConfigLastChanged");
		} 
		else {
			$V->{system}{"configurationState_value"} = "Config Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#00BB00";	#normal
		}
	}

	### If it is newer, someone changed it!
	if( $configLastChanged > $configLastChanged_prev ) {
		$V->{system}{configChangeCount_value}++;
		$V->{system}{configChangeCount_title} = "Configuration change count";

		notify(sys=>$S,event=>"Node Configuration Change",element=>"",details=>"Changed at ".$V->{system}{configLastChanged_value} );
		logMsg("checkNodeConfiguration configuration change detected on $NI->{system}{name}, creating event");
	}

	#update previous values to be out current values
	for my $attr (@updatePrevValues) {
		if (defined $NI->{system}{$attr} ne '' && $NI->{system}{$attr} ne '') {
			$NI->{system}{"${attr}_prev"} = $NI->{system}{$attr};
		}
	}

	info("Finished");
	return;

} # end checkNodeConfiguration

#=========================================================================================


# Create the Interface configuration from SNMP Stuff!!!!!
# except on collect it is always called with a blank interface info
sub getIntfInfo {
	my %args = @_;
	my $S = $args{sys}; # object
	my $intf_one = $args{index}; # index for single interface update

	my $NI = $S->ndinfo; # node info table
	my $V =  $S->view;
	my $M = $S->mdl;	# node model table
	my $SNMP = $S->snmp;
	my $IF = $S->ifinfo; # interface info table
	my $NC = $S->ndcfg; # node config table

	#print "DEBUG: max_repetitions=$max_repetitions system_max_repetitions=$NI->{system}{max_repetitions}\n";
	
	my $C = loadConfTable();

	### handling the default value for max-repetitions, this controls how many OID's will be in a single request.

	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;


	if ( defined $S->{mdl}{interface}{sys}{standard} ) {
		info("Starting");
		info("Get Interface Info of node $NI->{system}{name}, model $NI->{system}{nodeModel}");

		# load interface types (IANA). number => name
		my $IFT = loadifTypesTable();

		my $NCT = loadNodeConfTable();

		# get interface Index table
		my @ifIndexNum;
		my $ifIndexTable;
		if (($ifIndexTable = $SNMP->gettable('ifIndex',$max_repetitions))) {
			foreach my $oid ( oid_lex_sort(keys %{$ifIndexTable})) {
				push @ifIndexNum,$ifIndexTable->{$oid};
			}
		} else {
			if ( $SNMP->{error} =~ /is empty or does not exist/ ) {
				info("SNMP Object Not Present ($S->{name}) on get interface index table: $SNMP->{error}");						
			}
			# failed by snmp
			else {
				logMsg("ERROR ($S->{name}) on get interface index table: $SNMP->{error}");
				snmpNodeDown(sys=>$S);
			}

			info("Finished");
			return 0;
		}

		if ($intf_one eq "") {
			# remove unknown interfaces, found in previous runs, from table
			### possible vivification
			for my $i (keys %{$IF}) {
				if ( (not grep { $i eq $_ } @ifIndexNum) ) {
					delete $IF->{$i};
					delete $NI->{graphtype}{$i};
					dbg("Interface ifIndex=$i removed from table");
					logMsg("INFO ($S->{name}) Interface ifIndex=$i removed from table"); # test info
				}
			}
			delete $V->{interface}; # rebuild interface view table
		}

		# Loop to get interface information, will be stored in {ifinfo} table => $IF
		foreach my $index (@ifIndexNum) {
			next if ($intf_one ne '' and $intf_one ne $index); # only one interface
			if ($S->loadInfo(class=>'interface',index=>$index,model=>$model)) {
				checkIntfInfo(sys=>$S,index=>$index,iftype=>$IFT);
				$IF = $S->ifinfo; # renew pointer
				logMsg("INFO ($S->{name}) Joeps an empty field of index=$index admin=$IF->{$index}{ifAdminStatus}") if $IF->{$index}{ifAdminStatus} eq "";
				info("ifIndex=$index ifDescr=$IF->{$index}{ifDescr} ifType=$IF->{$index}{ifType} ifAdminStatus=$IF->{$index}{ifAdminStatus} ifOperStatus=$IF->{$index}{ifOperStatus} ifSpeed=$IF->{$index}{ifSpeed}");
			} else {
				# failed by snmp
				snmpNodeDown(sys=>$S);
				info("Finished");
				return 0;
			}
		}

		# port information optional
		if ($M->{port} ne "") {
			foreach my $index (@ifIndexNum) {
				next if ($intf_one ne '' and $intf_one ne $index);
				# get the VLAN info: table is indexed by port.portnumber
				if ( $IF->{$index}{ifDescr} =~ /\d{1,2}\/(\d{1,2})$/i ) { # FastEthernet0/1
					my $port = '1.' . $1;
					if ( $IF->{$index}{ifDescr} =~ /(\d{1,2})\/\d{1,2}\/(\d{1,2})$/i ) { # FastEthernet1/0/0
						$port = $1. '.' . $2;
					}
					if ($S->loadInfo(class=>'port',index=>$index,port=>$port,table=>'interface',model=>$model)) {
						#
						last if $IF->{$index}{vlanPortVlan} eq "";	# model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"} = convertIfSpeed($IF->{$index}{portAdminSpeed});
						dbg("get VLAN details: index=$index, ifDescr=$IF->{$index}{ifDescr}");
						dbg("portNumber: $port, VLan: $IF->{$index}{vlanPortVlan}, AdminSpeed: $IF->{$index}{portAdminSpeed}");
					}
				} else {
					my $port;
					if ( $IF->{$index}{ifDescr} =~ /(\d{1,2})\D(\d{1,2})$/ ) { # 0-0 Catalyst
						$port = $1. '.' . $2;
					}
					if ($S->loadInfo(class=>'port',index=>$index,port=>$port,table=>'interface',model=>$model)) {
						#
						last if $IF->{$index}{vlanPortVlan} eq "";	# model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"} = convertIfSpeed($IF->{$index}{portAdminSpeed});
						dbg("get VLAN details: index=$index, ifDescr=$IF->{$index}{ifDescr}");
						dbg("portNumber: $port, VLan: $IF->{$index}{vlanPortVlan}, AdminSpeed: $IF->{$index}{portAdminSpeed}");
					}
				}
			}
		}


		my $ifAdEntTable;
		my $ifMaskTable;
		my %ifCnt;
		info("Getting Device IP Address Table");
		if ( $ifAdEntTable = $SNMP->getindex('ipAdEntIfIndex',$max_repetitions)) {
			if ( $ifMaskTable = $SNMP->getindex('ipAdEntNetMask',$max_repetitions)) {
				foreach my $addr (keys %{$ifAdEntTable}) {
					my $index = $ifAdEntTable->{$addr};
					next if ($intf_one ne '' and $intf_one ne $index);
					$ifCnt{$index} += 1;
					info("ifIndex=$ifAdEntTable->{$addr}, addr=$addr  mask=$ifMaskTable->{$addr}");
					$IF->{$index}{"ipAdEntAddr$ifCnt{$index}"} = $addr;
					$IF->{$index}{"ipAdEntNetMask$ifCnt{$index}"} = $ifMaskTable->{$addr};
					($IF->{$ifAdEntTable->{$addr}}{"ipSubnet$ifCnt{$index}"},
						$IF->{$ifAdEntTable->{$addr}}{"ipSubnetBits$ifCnt{$index}"}) = ipSubnet(address=>$addr, mask=>$ifMaskTable->{$addr});
					$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_title"} = 'IP address / mask';
					$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_value"} = "$addr / $ifMaskTable->{$addr}";
				}
			} else {
				dbg("ERROR getting Device Ip Address table");
			}
		} else {
			dbg("ERROR getting Device Ip Address table");
		}

		# pre compile regex
		my $qr_no_collect_ifDescr_gen = qr/($S->{mdl}{interface}{nocollect}{ifDescr})/i;
		my $qr_no_collect_ifType_gen = qr/($S->{mdl}{interface}{nocollect}{ifType})/i;
		my $qr_no_collect_ifAlias_gen = qr/($S->{mdl}{interface}{nocollect}{Description})/i;
		my $qr_no_collect_ifOperStatus_gen = qr/($S->{mdl}{interface}{nocollect}{ifOperStatus})/i;

		### 2012-03-14 keiths, collecting override based on interface description.
		my $qr_collect_ifAlias_gen = 0;
		$qr_collect_ifAlias_gen = qr/($S->{mdl}{interface}{collect}{Description})/
				if $S->{mdl}{interface}{collect}{Description};
		my $qr_collect_ifDescr_gen = 0; # undef would be a match-always regex!
		$qr_collect_ifDescr_gen = qr/($S->{mdl}->{interface}->{collect}->{ifDescr})/i
				if ($S->{mdl}->{interface}->{collect}->{ifDescr});

		my $qr_no_event_ifAlias_gen = qr/($S->{mdl}{interface}{noevent}{Description})/i;
		my $qr_no_event_ifDescr_gen = qr/($S->{mdl}{interface}{noevent}{ifDescr})/i;
		my $qr_no_event_ifType_gen = qr/($S->{mdl}{interface}{noevent}{ifType})/i;

		my $noDescription = $M->{interface}{nocollect}{noDescription};

		### 2013-03-05 keiths, global collect policy override from Config!
    if ( defined $C->{global_nocollect_noDescription} and $C->{global_nocollect_noDescription} ne "" ) {
    	$noDescription = $C->{global_nocollect_noDescription};
    	info("INFO Model overriden by Global Config for global_nocollect_noDescription");
    }

    if ( defined $C->{global_collect_Description} and $C->{global_collect_Description} ne "" ) {
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

    if ( defined $C->{global_nocollect_Description} and $C->{global_nocollect_Description} ne "" ) {
    	$qr_no_collect_ifAlias_gen = qr/($C->{global_nocollect_Description})/i;
    	info("INFO Model overriden by Global Config for global_nocollect_Description");
    }

    if ( defined $C->{global_nocollect_ifType} and $C->{global_nocollect_ifType} ne "" ) {
    	$qr_no_collect_ifType_gen = qr/($C->{global_nocollect_ifType})/i;
    	info("INFO Model overriden by Global Config for global_nocollect_ifType");
    }

    if ( defined $C->{global_nocollect_ifOperStatus} and $C->{global_nocollect_ifOperStatus} ne "" ) {
    	$qr_no_collect_ifOperStatus_gen = qr/($C->{global_nocollect_ifOperStatus})/i;
    	info("INFO Model overriden by Global Config for global_nocollect_ifOperStatus");
    }

    if ( defined $C->{global_noevent_ifDescr} and $C->{global_noevent_ifDescr} ne "" ) {
    	$qr_no_event_ifDescr_gen = qr/($C->{global_noevent_ifDescr})/i;
    	info("INFO Model overriden by Global Config for global_noevent_ifDescr");
    }

    if ( defined $C->{global_noevent_Description} and $C->{global_noevent_Description} ne "" ) {
    	$qr_no_event_ifAlias_gen = qr/($C->{global_noevent_Description})/i;
    	info("INFO Model overriden by Global Config for global_noevent_Description");
    }

    if ( defined $C->{global_noevent_ifType} and $C->{global_noevent_ifType} ne "" ) {
    	$qr_no_event_ifType_gen = qr/($C->{global_noevent_ifType})/i;
    	info("INFO Model overriden by Global Config for global_noevent_ifType");
    }

		my $intfTotal = 0;
		my $intfCollect = 0; # reset counters

		### 2012-10-08 keiths, updates to index node conf table by ifDescr instead of ifIndex.
		foreach my $index (@ifIndexNum) {
			next if ($intf_one ne '' and $intf_one ne $index);

			my $ifDescr = $IF->{$index}{ifDescr};
				$intfTotal++;
			# count total number of real interfaces
			if ($IF->{$index}{ifType} !~ /$qr_no_collect_ifType_gen/ and $IF->{$index}{ifType} !~ /$qr_no_collect_ifDescr_gen/) {
				$IF->{$index}{real} = 'true';
			}

			# ifDescr must always be filled
			if ($IF->{$index}{ifDescr} eq "") { $IF->{$index}{ifDescr} = $index; }
			# check for duplicated ifDescr
			foreach my $i (keys %{$IF}) {
				if ($index ne $i and $IF->{$index}{ifDescr} eq $IF->{$i}{ifDescr}) {
					$IF->{$index}{ifDescr} = "$IF->{$index}{ifDescr}-${index}"; # add index to string
					$V->{interface}{"${index}_ifDescr_value"} = $IF->{$index}{ifDescr}; # update
					info("Interface Description changed to $IF->{$index}{ifDescr}");
				}
			}
			### add in anything we find from nodeConf - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			### 2013-09-26 keiths, fix for nodes with Capital Letters!
			my $node = $NI->{system}{name};
			if ($NCT->{$node}{$ifDescr}{Description} ne '') {
				$IF->{$index}{nc_Description} = $IF->{$index}{Description}; # save
				$IF->{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $NCT->{$node}{$ifDescr}{Description};
				info("Manual update of Description by nodeConf");
			}
			if ($NCT->{$node}{$ifDescr}{ifSpeed} ne '') {
				$IF->{$index}{nc_ifSpeed} = $IF->{$index}{ifSpeed}; # save
				$IF->{$index}{ifSpeed} = $V->{interface}{"${index}_ifSpeed_value"} = $NCT->{$node}{$ifDescr}{ifSpeed};
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($IF->{$index}{ifSpeed});
				info("Manual update of ifSpeed by nodeConf");
			}

			if ($NCT->{$node}{$ifDescr}{ifSpeedIn} ne '') {
				$IF->{$index}{nc_ifSpeedIn} = $IF->{$index}{ifSpeed}; # save
				$IF->{$index}{ifSpeedIn} = $NCT->{$node}{$ifDescr}{ifSpeedIn};

				$IF->{$index}{nc_ifSpeed} = $IF->{$index}{nc_ifSpeedIn};
				$IF->{$index}{ifSpeed} = $IF->{$index}{ifSpeedIn};

				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$V->{interface}{"${index}_ifSpeedIn_value"} = convertIfSpeed($IF->{$index}{ifSpeedIn});
				info("Manual update of ifSpeedIn by nodeConf");
			}

			if ($NCT->{$node}{$ifDescr}{ifSpeedOut} ne '') {
				$IF->{$index}{nc_ifSpeedOut} = $IF->{$index}{ifSpeed}; # save
				$IF->{$index}{ifSpeedOut} = $NCT->{$node}{$ifDescr}{ifSpeedOut};
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$V->{interface}{"${index}_ifSpeedOut_value"} = convertIfSpeed($IF->{$index}{ifSpeedOut});
				info("Manual update of ifSpeedOut by nodeConf");
			}

			# set default for collect, event and threshold: on, possibly overridden later
			$IF->{$index}{collect} = "true";
			$IF->{$index}{event} = "true";
			$IF->{$index}{threshold} = "true";
			$IF->{$index}{nocollect} = "Collecting: Collection Policy";
			#
			#Decide if the interface is one that we can do stats on or not based on Description and ifType and AdminStatus
			# If the interface is admin down no statistics
			### 2012-03-14 keiths, collecting override based on interface description.
			if ($qr_collect_ifAlias_gen
					and $IF->{$index}{Description} =~ /$qr_collect_ifAlias_gen/i )
			{
				$IF->{$index}{collect} = "true";
				$IF->{$index}{nocollect} = "Collecting: found $1 in Description"; # reason
			}
			elsif ($qr_collect_ifDescr_gen
					and $IF->{$index}{ifDescr} =~ /$qr_collect_ifDescr_gen/i )
			{
					$IF->{$index}{collect} = "true";
					$IF->{$index}{nocollect} = "Collecting: found $1 in ifDescr";
			}
			elsif ($IF->{$index}{ifAdminStatus} =~ /down|testing|null/ ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{event} = "false";
				$IF->{$index}{nocollect} = "ifAdminStatus eq down|testing|null"; # reason
				$IF->{$index}{noevent} = "ifAdminStatus eq down|testing|null"; # reason
			}
			elsif ($IF->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "Not Collecting: found $1 in ifDescr"; # reason
			}
			elsif ($IF->{$index}{ifType} =~ /$qr_no_collect_ifType_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "Not Collecting: found $1 in ifType"; # reason
			}
			elsif ($IF->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "Not Collecting: found $1 in Description"; # reason
			}
			elsif ($IF->{$index}{Description} eq "" and $noDescription eq 'true') {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "Not Collecting: no Description (ifAlias)"; # reason
			}
			elsif ($IF->{$index}{ifOperStatus} =~ /$qr_no_collect_ifOperStatus_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "Not Collecting: found $1 in ifOperStatus"; # reason
			}

			# send events ?
			if ($IF->{$index}{Description} =~ /$qr_no_event_ifAlias_gen/i ) {
				$IF->{$index}{event} = "false";
				$IF->{$index}{noevent} = "found $1 in ifAlias"; # reason
			}
			elsif ($IF->{$index}{ifType} =~ /$qr_no_event_ifType_gen/i ) {
				$IF->{$index}{event} = "false";
				$IF->{$index}{noevent} = "found $1 in ifType"; # reason
			}
			elsif ($IF->{$index}{ifDescr} =~ /$qr_no_event_ifDescr_gen/i ) {
				$IF->{$index}{event} = "false";
				$IF->{$index}{noevent} = "found $1 in ifDescr"; # reason
			}

			# convert interface name
			$IF->{$index}{interface} = convertIfName($IF->{$index}{ifDescr});
			$IF->{$index}{ifIndex} = $index;

			### 2012-11-20 keiths, updates to index node conf table by ifDescr instead of ifIndex.
			# modify by node Config ?
			if ($NCT->{$S->{name}}{$ifDescr}{collect} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $IF->{$index}{ifDescr}) {
				$IF->{$index}{nc_collect} = $IF->{$index}{collect};
				$IF->{$index}{collect} = $NCT->{$S->{name}}{$ifDescr}{collect};
				info("Manual update of Collect by nodeConf");
				### 2014-04-28 keiths, fixing info for GUI
				if (getbool($IF->{$index}{collect},"invert")) {
					$IF->{$index}{nocollect} = "Not Collecting: Manual update by nodeConf";
				}
				else {
					$IF->{$index}{nocollect} = "Collecting: Manual update by nodeConf";
				}
			}
			if ($NCT->{$S->{name}}{$ifDescr}{event} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $IF->{$index}{ifDescr}) {
				$IF->{$index}{nc_event} = $IF->{$index}{event};
				$IF->{$index}{event} = $NCT->{$S->{name}}{$ifDescr}{event};
				$IF->{$index}{noevent} = "Manual update by nodeConf" 
						if (getbool($IF->{$index}{event},"invert")); # reason
				info("Manual update of Event by nodeConf");
			}
			if ($NCT->{$S->{name}}{$ifDescr}{threshold} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $IF->{$index}{ifDescr}) {
				$IF->{$index}{nc_threshold} = $IF->{$index}{threshold};
				$IF->{$index}{threshold} = $NCT->{$S->{name}}{$ifDescr}{threshold};
				$IF->{$index}{nothreshold} = "Manual update by nodeConf" 
						if (getbool($IF->{$index}{threshold},"invert")); # reason
				info("Manual update of Threshold by nodeConf");
			}

			# interface now up or down, check and set or clear outstanding event.
			if ( getbool($IF->{$index}{collect})
					and $IF->{$index}{ifAdminStatus} =~ /up|ok/
					and $IF->{$index}{ifOperStatus} !~ /up|ok|dormant/
			) {
				if (getbool($IF->{$index}{event})) {
					notify(sys=>$S,event=>"Interface Down",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
				}
			} else {
				checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
			}

			if ( getbool($IF->{$index}{collect},"invert") ) {
				### 2014-10-21 keiths, get rid of bad interface graph types when ifIndexes get changed.
				my @types = qw(pkts pkts_hc interface);
				foreach my $type (@types) {
					if ( exists $NI->{graphtype}{$index}{$type} ) {
						logMsg("Interface not collecting, removing graphtype $type for interface $index");
						delete $NI->{graphtype}{$index}{$type};
					}
				}
			}				

			# number of interfaces collected with collect and event on
			$intfCollect++ if (getbool($IF->{$index}{collect}) 
												 && getbool($IF->{$index}{event}));

			# save values only if all interfaces are updated
			if ($intf_one eq '') {
				$NI->{system}{intfTotal} = $intfTotal;
				$NI->{system}{intfCollect} = $intfCollect;
			}

			# prepare values for web page
			$V->{interface}{"${index}_event_value"} = $IF->{$index}{event};
			$V->{interface}{"${index}_event_title"} = 'Event on';

			$V->{interface}{"${index}_threshold_value"} = !getbool($NC->{node}{threshold}) ? 'false': $IF->{$index}{threshold};
			$V->{interface}{"${index}_threshold_title"} = 'Threshold on';

			$V->{interface}{"${index}_collect_value"} = $IF->{$index}{collect};
			$V->{interface}{"${index}_collect_title"} = 'Collect on';

			$V->{interface}{"${index}_nocollect_value"} = $IF->{$index}{nocollect};
			$V->{interface}{"${index}_nocollect_title"} = 'Reason';

			# collect status
			if ( getbool($IF->{$index}{collect}) ) {
				info("$IF->{$index}{ifDescr} ifIndex $index, collect=true");
			} else {
				info("$IF->{$index}{ifDescr} ifIndex $index, collect=false, $IF->{$index}{nocollect}");
				# if  collect is of then disable event and threshold (clearly not applicable)
				$IF->{$index}{threshold} = $V->{interface}{"${index}_threshold_value"} = 'false';
				$IF->{$index}{event} = $V->{interface}{"${index}_event_value"} = 'false';
			}

			# get color depending of state
			$V->{interface}{"${index}_ifAdminStatus_color"} = getAdminColor(sys=>$S,index=>$index);
			$V->{interface}{"${index}_ifOperStatus_color"} = getOperColor(sys=>$S,index=>$index);

			# index number of interface
			$V->{interface}{"${index}_ifIndex_value"} = $index;
			$V->{interface}{"${index}_ifIndex_title"} = 'ifIndex';
		}

		info("Finished");
	}
	else {
		info("Skipping, interfaces not defined in Model");
	}
	return 1;
} # end getIntfInfo

#=========================================================================================

# check and modify some values of interface
sub checkIntfInfo {
	my %args = @_;
	my $S = $args{sys};
	my $index = $args{index};
	my $ifTypeDefs = $args{iftype};
	my $IF = $S->ifinfo;
	my $NI = $S->ndinfo;
	my $V =  $S->view;

	if ( $IF->{$index}{ifDescr} eq "" ) { $IF->{$index}{ifDescr} = "null"; }

	# remove bad chars from interface descriptions
	$IF->{$index}{ifDescr} = rmBadChars($IF->{$index}{ifDescr});
	$IF->{$index}{Description} = rmBadChars($IF->{$index}{Description});

	# Try to set the ifType to be something meaningful!!!!
	if (exists $ifTypeDefs->{$IF->{$index}{ifType}}{ifType}) {
		$IF->{$index}{ifType} = $ifTypeDefs->{$IF->{$index}{ifType}}{ifType};
	}

	# Just check if it is an Frame Relay sub-interface
	if ( ( $IF->{$index}{ifType} eq "frameRelay" and $IF->{$index}{ifDescr} =~ /\./ ) ) {
		$IF->{$index}{ifType} = "frameRelay-subinterface";
	}
	$V->{interface}{"${index}_ifType_value"} = $IF->{$index}{ifType};
	# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
	if ( $IF->{$index}{ifSpeed} == 4294967295 ) {
		$IF->{$index}{ifSpeed} = $IF->{$index}{ifHighSpeed};
		$IF->{$index}{ifSpeed} *= 1000000;
	}
	### 2012-08-14 keiths, use ifHighSpeed if 0
	elsif ( $IF->{$index}{ifSpeed} == 0 ) {
		$IF->{$index}{ifSpeed} = $IF->{$index}{ifHighSpeed};
		$IF->{$index}{ifSpeed} *= 1000000;
	}

	### 2012-08-14 keiths, triple check in case SNMP agent is DODGY
	if ( $IF->{$index}{ifSpeed} == 0 ) {
		$IF->{$index}{ifSpeed} = 1000000000;
	}

	$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($IF->{$index}{ifSpeed});
	# convert time integer to time string
	$V->{interface}{"${index}_ifLastChange_value"} =
		$IF->{$index}{ifLastChange} =
			convUpTime($IF->{$index}{ifLastChangeSec} = int($IF->{$index}{ifLastChange}/100));

} # end checkIntfInfo

#=========================================================================================

sub checkPIX {
	my %args = @_;
	my $S = $args{sys};

	my $NI = $S->ndinfo;
	my $V =  $S->view;
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

	if ( $NI->{system}{nodeModel} eq "CiscoPIX" ) {
		dbg("checkPIX, Getting Cisco PIX Failover Status");
		if ($result = $SNMP->get(
					'cfwHardwareStatusValue.6',
					'cfwHardwareStatusValue.7',
					'cfwHardwareStatusDetail.6',
					'cfwHardwareStatusDetail.7'
			)) {
			$result = $SNMP->keys2name($result); # convert oid in hash key to name

			if ($result->{'cfwHardwareStatusDetail.6'} ne 'Failover Off') {
				if ( $result->{'cfwHardwareStatusValue.6'} == 0 ) { $result->{'cfwHardwareStatusValue.6'} = "Failover Off"; }
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 3 ) { $result->{'cfwHardwareStatusValue.6'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 9 ) { $result->{'cfwHardwareStatusValue.6'} = "Active"; }
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 10 ) { $result->{'cfwHardwareStatusValue.6'} = "Standby"; }
				else { $result->{'cfwHardwareStatusValue.6'} = "Unknown"; }

				if ( $result->{'cfwHardwareStatusValue.7'} == 0 ) { $result->{'cfwHardwareStatusValue.7'} = "Failover Off"; }
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 3 ) { $result->{'cfwHardwareStatusValue.7'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 9 ) { $result->{'cfwHardwareStatusValue.7'} = "Active"; }
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 10 ) { $result->{'cfwHardwareStatusValue.7'} = "Standby"; }
				else { $result->{'cfwHardwareStatusValue.7'} = "Unknown"; }

				if (getbool($S->{docollect})) {
					if ( $result->{'cfwHardwareStatusValue.6'} ne $NI->{system}{pixPrimary} or $result->{'cfwHardwareStatusValue.7'} ne $NI->{system}{pixSecondary} )
						{
						dbg("PIX failover occurred");
						# As this is not stateful, alarm not sent to state table in sub eventAdd
						notify(sys=>$S,event=>"Node Failover",element=>'PIX',details=>"Primary now: $NI->{system}{pixPrimary}  Secondary now: $NI->{system}{pixSecondary}");
					}
				}
				$NI->{system}{pixPrimary} = $result->{'cfwHardwareStatusValue.6'}; # remember
				$NI->{system}{pixSecondary} = $result->{'cfwHardwareStatusValue.7'};

				$V->{system}{firewall_title} =  "Failover Status" ;
				$V->{system}{firewall_value} = "Pri: $NI->{system}{pixPrimary} Sec: $NI->{system}{pixSecondary}";
				if ( $NI->{system}{pixPrimary} =~ /Failover Off|Active/i and
						$NI->{system}{pixSecondary} =~ /Failover Off|Standby/i ) {
					$V->{system}{firewall_color} = "#00BB00";	#normal
				} else {
					$V->{system}{firewall_color} = "#FFDD00";	#warning

				}
			} else {
				$V->{system}{firewall_title} =  "Failover Status" ;
				$V->{system}{firewall_value} = "Failover off";
			}
		}
	}
	dbg("Finished");
	return 1;
} # end checkPIX

#=========================================================================================

#
sub getEnvInfo {
	my %args = @_;
	my $S = $args{sys}; # object

	my $NI = $S->ndinfo; # node info table
	my $V =  $S->view;
	my $SNMP = $S->snmp;
	my $M = $S->mdl;	# node model table
	my $C = loadConfTable();

	# handling the default value for max-repetitions, this controls how many OID's will be in a single request.
	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	dbg("Starting");
	dbg("Get Environment Info of node $NI->{system}{name}, model $NI->{system}{nodeModel}");

	if ($M->{environment} eq '') {
		dbg("No class 'environment' declared in Model");
	}
	else {
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ( $NI->{system}{nodeModel} =~ /AKCP-Sensor/i ) {
			for my $section ('akcp_temp','akcp_hum') {
				delete $NI->{$section};
				# get Index table
				my $index_var = $M->{environment}{sys}{$section}{indexed};
				if ($index_var ne '') {
					my %envIndexNum;
					my $envIndexTable;
					if (($envIndexTable = $SNMP->gettable($index_var,$max_repetitions))) {
						foreach my $oid ( oid_lex_sort(keys %{$envIndexTable})) {
							$oid =~ /\.(\d+)$/;
							my $index= $oid;
							# check for online of sensor, value 1 is online
							if ($oid =~ /\.1\.5.\d+$/ and $envIndexTable->{$oid} == 1) {
								dbg("sensor section=$section index=$index is online");
								$envIndexNum{$index}=$index;
							}
						}
					} else {
						if ( $SNMP->{error} =~ /is empty or does not exist/ ) {
							info("SNMP Object Not Present ($S->{name}) on get environment index table: $SNMP->{error}");						
						}
						# failed by snmp
						else {
							logMsg("ERROR ($S->{name}) on get environment index table: $SNMP->{error}");
							snmpNodeDown(sys=>$S);
						}
					}
					# Loop to get information, will be stored in {info}{$section} table
					foreach my $index (sort keys %envIndexNum) {
						if ($S->loadInfo(class=>'environment',section=>$section,index=>$index,table=>$section,model=>$model)) {
							dbg("sensor section=$section index=$index read and stored");
						} else {
							# failed by snmp
							snmpNodeDown(sys=>$S);
						}
					}
				}
			}
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		elsif ( $NI->{system}{nodeModel} =~ /CiscoCSS/i ) {
			for my $section ('cssgroup','csscontent') {
				delete $NI->{$section};
				# get Index table
				my $index_var = $M->{environment}{sys}{$section}{indexed};
				if ($index_var ne '') {
					my %envIndexNum;
					my $envIndexTable;
					if (($envIndexTable = $SNMP->gettable($index_var,$max_repetitions))) {
						foreach my $oid ( oid_lex_sort(keys %{$envIndexTable})) {
							if ($section eq "cssgroup") {
								$oid =~ s/1.3.6.1.4.1.9.9.368.1.17.2.1.2.//g;
							} elsif ($section eq  "csscontent") {
								$oid =~ s/1.3.6.1.4.1.9.9.368.1.16.4.1.3.//g;
							} else {
								$oid =~ /\.(\d+)$/;
							}
							my $index= $oid;
							$envIndexNum{$index}=$index;
						}
					} else {
						logMsg("ERROR ($S->{name}) on get environment $section index table");
					}
					# Loop to get information, will be stored in {info}{$section} table
					foreach my $index (sort keys %envIndexNum) {
						if ($S->loadInfo(class=>'environment',section=>$section,index=>$index,table=>$section,model=>$model)) {
							dbg("sensor section=$section index=$index read and stored");
						}
					}
				}
			}
		}
		###2012-12-13 keiths, adding generic Environment support
		else {
			for my $section ('env_temp') {
				delete $NI->{$section};
				# get Index table
				my $index_var = $M->{environment}{sys}{$section}{indexed};
				if ($index_var ne '') {
					my %envIndexNum;
					my $envIndexTable;
					if (($envIndexTable = $SNMP->gettable($index_var,$max_repetitions))) {
						foreach my $oid ( oid_lex_sort(keys %{$envIndexTable})) {
							my $index = $oid;
							if ( $oid =~ /\.(\d+)$/ ) {
								$index = $1;
							}
							$envIndexNum{$index}=$index;
							# check for online of sensor, value 1 is online
							dbg("environment section=$section index=$index is found");
						}
					} else {
						if ( $SNMP->{error} =~ /is empty or does not exist/ ) {
							info("SNMP Object Not Present ($S->{name}) on get environment index table: $SNMP->{error}");						
						}
						# failed by snmp
						else {
							logMsg("ERROR ($S->{name}) on get environment index table: $SNMP->{error}");
							snmpNodeDown(sys=>$S);
						}
					}
					# Loop to get information, will be stored in {info}{$section} table
					foreach my $index (sort keys %envIndexNum) {
						if ($S->loadInfo(class=>'environment',section=>$section,index=>$index,table=>$section,model=>$model)) {
							dbg("environment section=$section index=$index read and stored");
						} else {
							# failed by snmp
							snmpNodeDown(sys=>$S);
						}
					}
				}
			}
		}
	}
	dbg("Finished");
	return 1;
}
#=========================================================================================
#
sub getEnvData {
	my %args = @_;
	my $S = $args{sys}; # object

	my $NI = $S->ndinfo; # node info table
	my $SNMP = $S->snmp;
	my $V =  $S->view;
	my $M = $S->mdl;	# node model table

	my $C = loadConfTable();

	dbg("Starting");
	dbg("Get Environment Data of node $NI->{system}{name}, model $NI->{system}{nodeModel}");

	if ($M->{environment} eq '') {
		dbg("No class 'environment' declared in Model");
	}
	else {
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ( $NI->{system}{nodeModel} =~ /AKCP-Sensor/i ) {
			for my $section ('akcp_temp','akcp_hum') {
				for my $index (sort keys %{$S->{info}{$section}}) {
					my $rrdData;
					if (($rrdData = $S->getData(class=>'environment',section=>$section,index=>$index,model=>$model))) {
						processAlerts( S => $S );
						if ( $rrdData->{error} eq "" ) {
							foreach my $sect (keys %{$rrdData}) {
								my $D = $rrdData->{$sect}{$index};

								# RRD Database update and remember filename
								my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index);
							}
						}
						else {
							### 2012-03-29 keiths, SNMP is OK, some other error happened.
							dbg("ERROR ($NI->{system}{name}) on getEnvData, $rrdData->{error}");
						}
					}
					### 2012-03-28 keiths, handling SNMP Down during poll cycles.
					else {
						logMsg("ERROR ($NI->{system}{name}) on getEnvData, SNMP problem");
						# failed by snmp
						snmpNodeDown(sys=>$S);
						dbg("ERROR, getting data");
						return 0;
					}
				}
			}
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		elsif ( $NI->{system}{nodeModel} =~ /CiscoCSS/i ) {
			for my $section ('cssgroup','csscontent') {
				for my $index (sort keys %{$S->{info}{$section}}) {
					my $rrdData;
					if (($rrdData = $S->getData(class=>'environment',section=>$section,index=>$index,model=>$model))) {
						processAlerts( S => $S );
						if ( $rrdData->{error} eq "" ) {
							foreach my $sect (keys %{$rrdData}) {
								my $D = $rrdData->{$sect}{$index};


								# RRD Database update and remember filename
								my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index);
							}
						}
						else {
							### 2012-03-29 keiths, SNMP is OK, some other error happened.
							dbg("ERROR ($NI->{system}{name}) on getEnvData, $rrdData->{error}");
						}
					}
					### 2012-03-28 keiths, handling SNMP Down during poll cycles.
					else {
						logMsg("ERROR ($NI->{system}{name}) on getEnvData, SNMP problem");
						# failed by snmp
						snmpNodeDown(sys=>$S);
						dbg("ERROR, getting data");
						return 0;
					}
				}
			}
		}
		###2012-12-13 keiths, adding generic Environment support
		else {
			for my $section ('env_temp') {
				for my $index (sort keys %{$S->{info}{$section}}) {
					my $rrdData;
					if (($rrdData = $S->getData(class=>'environment',section=>$section,index=>$index,model=>$model))) {
						processAlerts( S => $S );
						if ( $rrdData->{error} eq "" ) {
							foreach my $sect (keys %{$rrdData}) {
								my $D = $rrdData->{$sect}{$index};

								# RRD Database update and remember filename
								my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index);
							}
						}
						else {
							dbg("ERROR ($NI->{system}{name}) on getEnvData, $rrdData->{error}");
						}
					}
					else {
						logMsg("ERROR ($NI->{system}{name}) on getEnvData, SNMP problem");
						# failed by snmp
						snmpNodeDown(sys=>$S);
						dbg("ERROR, getting data");
						return 0;
					}
				}
			}
		}
	}
	dbg("Finished");
	return 1;
}
#=========================================================================================

# retrieve system health data from snmp, done during update
sub getSystemHealthInfo {
	my %args = @_;
	my $S = $args{sys}; # object

	my $NI = $S->ndinfo; # node info table
	my $V =  $S->view;
	my $SNMP = $S->snmp;
	my $M = $S->mdl;	# node model table
	my $C = loadConfTable();
	
	# handling the default value for max-repetitions, this controls how many OID's will be in a single request.
	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	info("Starting");
	info("Get systemHealth Info of node $NI->{system}{name}, model $NI->{system}{nodeModel}");

	if ($M->{systemHealth} eq '') {
		dbg("No class 'systemHealth' declared in Model");
	}
	else {
		my @healthSections = split(",",$C->{model_health_sections});
		if ( exists $M->{systemHealth}{sections} and $M->{systemHealth}{sections} ne "" ) {
			@healthSections = split(",",$M->{systemHealth}{sections});
		}
		for my $section (@healthSections) {
			delete $NI->{$section};
			# get Index table
			my $index_var = '';

			### 2013-10-11 keiths, adding support for obscure SNMP Indexes....
			# in the systemHealth section of the model 'index_regex' => '\.(\d+\.\d+\.\d+)$',
			my $index_regex = '\.(\d+)$';

			### 2013-10-14 keiths, adding support for using OID for index_var....
			# in the systemHealth section of the model 'index_oid' => '1.3.6.1.4.1.2021.13.15.1.1.1',
			my $index_snmp = undef;

			if( exists($M->{systemHealth}{sys}{$section}) ) {
				$index_var = $M->{systemHealth}{sys}{$section}{indexed};
				$index_snmp = $M->{systemHealth}{sys}{$section}{indexed};
				if( exists($M->{systemHealth}{sys}{$section}{index_regex}) ) {
					$index_regex = $M->{systemHealth}{sys}{$section}{index_regex};
				}
				if( exists($M->{systemHealth}{sys}{$section}{index_oid}) ) {
					$index_snmp = $M->{systemHealth}{sys}{$section}{index_oid};
				}
			}
			if ($index_var ne '') {
				info("systemHealth: index_var=$index_var, index_snmp=$index_snmp");
				my %healthIndexNum;
				my $healthIndexTable;
				if ($healthIndexTable = $SNMP->gettable($index_snmp,$max_repetitions)) {
					# dbg("systemHealth: table is ".Dumper($healthIndexTable) );
					foreach my $oid ( oid_lex_sort(keys %{$healthIndexTable})) {
						my $index = $oid;
						if ( $oid =~ /$index_regex/ ) {
							$index = $1;
						}
						$healthIndexNum{$index}=$index;
						# check for online of sensor, value 1 is online
						dbg("section=$section index=$index is found");
					}
				} else {
					if ( $SNMP->{error} =~ /is empty or does not exist/ ) {
						info("SNMP Object Not Present ($S->{name}) on get systemHealth $section index table: $SNMP->{error}");						
					}
					# failed by snmp
					else {
						logMsg("ERROR ($S->{name}) on get systemHealth $section index table: $SNMP->{error}");
						snmpNodeDown(sys=>$S);
					}
				}
				# Loop to get information, will be stored in {info}{$section} table
				foreach my $index (sort keys %healthIndexNum) {
					if ($S->loadInfo(class=>'systemHealth',section=>$section,index=>$index,table=>$section,model=>$model)) {
						info("section=$section index=$index read and stored");
					} else {
						# failed by snmp
						snmpNodeDown(sys=>$S);
					}
				}
			}
			else {
				dbg("No indexvar found in $section");
			}
		}
	}
	info("Finished");
	return 1;
}
#=========================================================================================

sub getSystemHealthData {
	my %args = @_;
	my $S = $args{sys}; # object

	my $NI = $S->ndinfo; # node info table
	my $SNMP = $S->snmp;
	my $V =  $S->view;
	my $M = $S->mdl;	# node model table

	my $C = loadConfTable();

	info("Starting");
	info("Get systemHealth Data of node $NI->{system}{name}, model $NI->{system}{nodeModel}");

	if ($M->{systemHealth} eq '') {
		dbg("No class 'systemHealth' declared in Model");
	}
	else {
		my @healthSections = split(",",$C->{model_health_sections});
		if ( exists $M->{systemHealth}{sections} and $M->{systemHealth}{sections} ne "" ) {
			@healthSections = split(",",$M->{systemHealth}{sections});
		}
		for my $section (@healthSections) {
			if( exists($S->{info}{$section}) ) {
				for my $index (sort keys %{$S->{info}{$section}}) {
					my $rrdData;
					if (($rrdData = $S->getData(class=>'systemHealth',section=>$section,index=>$index,model=>$model))) {
						if ( $rrdData->{error} eq "" ) {
							foreach my $sect (keys %{$rrdData}) {
								my $D = $rrdData->{$sect}{$index};

								# update retrieved values in node info, too, not just the rrd database
								for my $item (keys %$D)
								{
										dbg("updating node info $section $index $item: old ".$S->{info}{$section}{$index}{$item}
												." new $D->{$item}{value}");
										$S->{info}{$section}{$index}{$item}=$D->{$item}{value};
								}

								# RRD Database update and remember filename
								my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index);
							}
						}
						elsif ($rrdData->{skipped})
						{
								dbg("($NI->{system}{name}) skipped data collection");
						}
						else {
								dbg("ERROR ($NI->{system}{name}) on getSystemHealthData, $rrdData->{error}");
						}
					}
					else {
						logMsg("ERROR ($NI->{system}{name}) on getSystemHealthData, SNMP problem");
						# failed by snmp
						snmpNodeDown(sys=>$S);
						dbg("ERROR, getting data");
						return 0;
					}
				}
			}

		}
	}
	info("Finished");
	return 1;
}
#=========================================================================================

# updates the node info and node view structures with all kinds of stuff
# returns: 1 if node is up, and all ops worked; 0 if node is down/to be skipped etc.
sub updateNodeInfo {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $V =  $S->view;
	my $RI = $S->reach;
	my $NC = $S->ndcfg;		# node config
	my $M = $S->mdl;
	my $result;
	my $exit = 1;

	info("Starting Update Node Info, node $S->{name}");
	# clear the node reset indication from the last run
	$NI->{system}->{node_was_reset}=0;
	my $NCT = loadNodeConfTable();

	# save what we need now for check of this node
	my $sysObjectID = $NI->{system}{sysObjectID};
	my $ifNumber = $NI->{system}{ifNumber};
	my $sysUpTimeSec = $NI->{system}{sysUpTimeSec};
	my $sysUpTime = $NI->{system}{sysUpTime};

	if (($S->loadInfo(class=>'system',model=>$model))) {
		# do some checks
		if ($sysObjectID ne $NI->{system}{sysObjectID}) {
			logMsg("INFO ($NI->{system}{name}) Device type/model changed $sysObjectID now $NI->{system}{sysObjectID}");
			$exit = getNodeInfo(sys=>$S);
			goto END_updateNodeInfo; # ready with new info
		}
		# nodeinfo will have deleted the interface section, need to recreate from scratch
		if ($ifNumber != $NI->{system}{ifNumber}) {
			logMsg("INFO ($NI->{system}{name}) Number of interfaces changed from $ifNumber now $NI->{system}{ifNumber}");
			getIntfInfo(sys=>$S); # get new interface table
		}

			# Read the uptime from the node info file from the last time it was polled
		$NI->{system}{sysUpTimeSec} = int($NI->{system}{sysUpTime}/100); # seconds
		$NI->{system}{sysUpTime} = convUpTime($NI->{system}{sysUpTimeSec});

		### 2014-01-08 keiths, adding update from Scott Cubic
		if ( defined $NI->{system}{snmpUpTime} ) {
			# SRC - add processing for SNMP Uptime- handle just like sysUpTime
			$NI->{system}{snmpUpTimeSec} = int($NI->{system}{snmpUpTime}/100);
			$NI->{system}{snmpUpTime} = convUpTime($NI->{system}{snmpUpTimeSec});		
			$V->{system}{snmpUpTime_value} = $NI->{system}{snmpUpTime};
			$V->{system}{snmpUpTime_title} = 'SNMP Uptime';
		}
		
		info("sysUpTime: Old=$sysUpTime New=$NI->{system}{sysUpTime}");
		if ($sysUpTimeSec > $NI->{system}{sysUpTimeSec} and $NI->{system}{sysUpTimeSec} ne '') {
			info("NODE RESET: Old sysUpTime=$sysUpTimeSec New sysUpTime=$NI->{system}{sysUpTimeSec}");
			notify(sys=>$S, event=>"Node Reset",element=>"",
						 details => "Old_sysUpTime=$sysUpTime New_sysUpTime=$NI->{system}{sysUpTime}");

			# now stash this info in the node info object, to ensure we insert one set of U's into the rrds
			# so that no spikes appear in the graphs
			$NI->{system}{node_was_reset}=1;
		}

		$V->{system}{sysUpTime_value} = $NI->{system}{sysUpTime};
		$V->{system}{sysUpTime_title} = 'Uptime';

		$V->{system}{lastUpdate_value} = returnDateStamp();
		$V->{system}{lastUpdate_title} = 'Last Update';
		$NI->{system}{lastUpdateSec} = time();

		# modify by nodeConf ?
		my $node = $NI->{system}{name};
		if ($NCT->{$node}{sysLocation} ne '') {
			$NI->{nodeconf}{sysLocation} = $NI->{system}{sysLocation};
			$NI->{system}{sysLocation} = $V->{system}{sysLocation_value} = $NCT->{$node}{sysLocation};
			info("Manual update of sysLocation by nodeConf");
		}
		if ($NCT->{$node}{sysContact} ne '') {
			$NI->{nodeconf}{sysContact} = $NI->{system}{sysContact};
			$NI->{system}{sysContact} = $V->{system}{sysContact_value} = $NCT->{$node}{sysContact};
			info("Manual update of sysContact by nodeConf");
		}

		# ok we are running snmp
		checkEvent(sys=>$S,event=>'SNMP Down',level=>"Normal",element=>'',details=>"SNMP error");

		checkPIX(sys=>$S); # check firewall if needed

		delete $NI->{database};	 # no longer used at all
		$RI->{snmpresult} = 100; # oke, health info

		# view on page
		$V->{system}{status_value} = 'reachable';
		$V->{system}{status_color} = '#0F0';

		checkNodeConfiguration(sys=>$S) if exists $M->{system}{sys}{nodeConfiguration};
	
		### conditional on model section to ensure backwards compatibility with different Juniper values.
		checkNodeConfiguration(sys=>$S) if exists $M->{system}{sys}{juniperConfiguration};

	} else {
		$exit = snmpNodeDown(sys=>$S);
		# view on page
		if ( getbool($NC->{node}{ping}) ) {
			# ping was ok but snmp not
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		} else {
			# ping was disabled
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
		$RI->{snmpresult} = 0;
	}

	$NI->{system}{nodedown} = $NI->{system}{snmpdown} = $exit ? 'false' : 'true';

	### 2012-12-03 keiths, adding some model testing and debugging options.
	if ( $model ) {
		print "MODEL $S->{name}: nodedown=$NI->{system}{nodedown} sysUpTime=$NI->{system}{sysUpTime} sysObjectID=$NI->{system}{sysObjectID}\n";
	}

END_updateNodeInfo:
	info("Finished with exit=$exit");
	return $exit;
} # end updateNodeInfo

sub processAlerts {
	my %args = @_;
	my $S = $args{S};
	my $alerts = $S->{alerts};

	#print Dumper $S->{alerts} if $C->{debug};

	foreach my $alert (@{$alerts})
	{
		info("Processing alert: event=Alert: $alert->{event}, level=$alert->{level}, element=$alert->{ds}, details=Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}") if $alert->{test_result};
		dbg("Processing alert ".Dumper($alert),2);
		#$VAR1 = {
		#  'ds' => '192.168.1.249',
		#  'event' => 'BGP Peer Down',
		#  'level' => 'Warning',
		#  'name' => 'meatball',
		#  'test' => 'CVAR1=bgpPeerState;$CVAR1 * 1',
		#  'test_result' => 1,
		#  'type' => 'test',
		#  'unit' => '',
		#  'value' => 100
		#};

		my $tresult = "Normal";
		$tresult = $alert->{level} if $alert->{test_result};

		my $statusResult = "ok";
		$statusResult = "error" if $tresult ne "Normal";

		#$alert->{test}
		my $details = "$alert->{type} evaluated with $alert->{value} $alert->{unit} as $tresult";
		if( $alert->{test_result} ) {
			notify(sys=>$S, event=>"Alert: ".$alert->{event}, level=>$alert->{level}, element=>$alert->{ds}, details=>$details);
		} else {
			checkEvent(sys=>$S, event=>"Alert: ".$alert->{event}, level=>$alert->{level}, element=>$alert->{ds}, details=>$details);
		}

		### save the Alert result into the Status thingy
		my $statusKey = "$alert->{event}--$alert->{ds}";
		$S->{info}{status}{$statusKey} = {
			method => "Alert",
			type => $alert->{type},
			property => $alert->{test},
			event => $alert->{event},
			index => undef, #$args{index},
			level => $tresult,
			status => $statusResult,
			element => $alert->{ds},
			value => $alert->{value},
			updated => time()
		}

	}
}

#=========================================================================================

# get node values by snmp and store in RRD and some values in reach table
#
sub getNodeData {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;

	my $rrdData;

	info("Starting Node get data, node $S->{name}");

	if (($rrdData = $S->getData(class=>'system', model => $model))) {
		processAlerts( S => $S );
		if ( $rrdData->{error} eq "" ) {
			foreach my $sect (keys %{$rrdData}) {
				my $D = $rrdData->{$sect};

				checkNodeHealth(sys=>$S,data=>$D) if $sect eq "nodehealth";

				foreach my $ds (keys %{$D}) {
					dbg("rrdData, section=$sect, ds=$ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}",2);
				}
				my $db = updateRRD(sys=>$S,data=>$D,type=>$sect);
			}
		}
		else {
			### 2012-03-29 keiths, SNMP is OK, some other error happened.
			dbg("ERROR ($NI->{system}{name}) on getNodeData, $rrdData->{error}");
		}
	}
	### 2012-03-28 keiths, handling SNMP Down during poll cycles.
	else {
		logMsg("ERROR ($NI->{system}{name}) on getNodeData, SNMP problem");
		# failed by snmp
		snmpNodeDown(sys=>$S);
		dbg("ERROR, getting data");
		return 0;
	}

	info("Finished");
	return 1;
} # end getNodeData


#=========================================================================================

# copy/modify some health values collected by getNodeData
# nmisdev 13Oct2012 - check if hash key is present before testing value, else key will 'auto vivify', and cause DS errors
sub checkNodeHealth {
	my %args = @_;
	my $S = $args{sys};
	my $D = $args{data};
	my $NI = $S->ndinfo;
	my $RI = $S->reach;

	info("Starting, node $S->{name}");

	# take care of negative values from 6509 MSCF
	if ( exists $D->{bufferElHit} and $D->{bufferElHit}{value} < 0) { $D->{bufferElHit}{value} = sprintf("%u",$D->{bufferElHit}{value}); }

	### 2012-12-13 keiths, fixed this so it would assign!
	### 2013-04-17 keiths, fixed an autovivification problem!
	if ( exists $D->{avgBusy5} or exists $D->{avgBusy1} ) {
		$RI->{cpu} = ($D->{avgBusy5}{value} ne "") ? $D->{avgBusy5}{value} : $D->{avgBusy1}{value};
	}
	if ( exists $D->{MemoryUsedPROC} ) {
		$RI->{memused} = $D->{MemoryUsedPROC}{value};
	}
	if ( exists $D->{MemoryFreePROC} ) {
		$RI->{memfree} = $D->{MemoryFreePROC}{value};
	}
	info("Finished");
	return 1;
} # end checkHealth

#=========================================================================================

sub getIntfData {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo; # node info
	my $V =  $S->view;
	my $IF = $S->ifinfo; # interface info
	my $RI = $S->reach;
	my $SNMP = $S->snmp;
	my $IFCACHE;

	my $C = loadConfTable();
	my $ET = loadEventStateNoLock();

	$S->{ET} = $ET; # save in object for speeding up checkevent

	my $NCT = loadNodeConfTable();

	my $createdone = "false";

	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	info("Starting Interface get data, node $S->{name}");

	$RI->{intfUp} = $RI->{intfColUp} = 0; # reset counters of interface Up and interface collected Up

	# check first if admin status of interfaces changed
	if ( not defined $S->{mdl}{custom}{interface}{ifAdminStatus} 
			 or ( defined $S->{mdl}{custom}{interface}{ifAdminStatus} 
						and !getbool($S->{mdl}{custom}{interface}{ifAdminStatus},"invert")) ) {
		my $ifAdminTable;
		my $ifOperTable;
		if ( ($ifAdminTable = $SNMP->getindex('ifAdminStatus',$max_repetitions)) ) {
			$ifOperTable = $SNMP->getindex('ifOperStatus',$max_repetitions);
			for my $index (keys %{$ifAdminTable}) {
				logMsg("INFO ($S->{name}) entry ifAdminStatus for index=$index not found in interface table") if not exists $IF->{$index}{ifAdminStatus};
				if (($ifAdminTable->{$index} == 1 and $IF->{$index}{ifAdminStatus} ne 'up')
					or ($ifAdminTable->{$index} != 1 and $IF->{$index}{ifAdminStatus} eq 'up') ) {
					### logMsg("INFO ($S->{name}) ifIndex=$index, Admin was $IF->{$index}{ifAdminStatus} now $ifAdminTable->{$index} (1=up) rebuild");
					getIntfInfo(sys=>$S,index=>$index); # update this interface
				}
				# total number of interfaces up
				$RI->{intfUp}++ if $ifOperTable->{$index} == 1 
						and getbool($IF->{$index}{real});
			}
		}
	}
	# Start a loop which go through the interface table

	foreach my $index ( sort {$a <=> $b} keys %{$IF} ) {
		if ( defined $IF->{$index}{ifDescr} and $IF->{$index}{ifDescr} ne "" ) {
			info("$IF->{$index}{ifDescr}: ifIndex=$IF->{$index}{ifIndex}, was => OperStatus=$IF->{$index}{ifOperStatus}, ifAdminStatus=$IF->{$index}{ifAdminStatus}, Collect=$IF->{$index}{collect}");

			# only collect on interfaces that are defined, with collection turned on globally
			if ( getbool($IF->{$index}{collect}) ) {
				dbg("collect interface index=$index");

				my $rrdData;
				if (($rrdData = $S->getData(class=>'interface',index=>$index,model=>$model))) {
					processAlerts( S => $S );
					if ( $rrdData->{error} eq "" ) {
						foreach my $sect (keys %{$rrdData}) {

							my $D = $rrdData->{$sect}{$index};

							# if HC exists then copy values
							if (exists $D->{ifHCInOctets}) {
								dbg("process HC counters");
								#copy HC counters if exists
								if ($D->{ifHCInOctets}{value} =~ /\d+/) {
									$D->{ifInOctets}{value} = $D->{ifHCInOctets}{value};
									$D->{ifInOctets}{option} = $D->{ifHCInOctets}{option};
								}
								delete $D->{ifHCInOctets};
								if ($D->{ifHCOutOctets}{value} =~ /\d+/) {
									$D->{ifOutOctets}{value} = $D->{ifHCOutOctets}{value};
									$D->{ifOutOctets}{option} = $D->{ifHCOutOctets}{option};
								}
								delete $D->{ifHCOutOctets};
							}

							### 2012-08-14 keiths, added additional HC mappings
							if ($sect eq 'pkts' or $sect eq 'pkts_hc') {
								dbg("process HC counters of $sect");
								if ($D->{ifHCInUcastPkts}{value} =~ /\d+/) {
									$D->{ifInUcastPkts}{value} = $D->{ifHCInUcastPkts}{value};
									$D->{ifInUcastPkts}{option} = $D->{ifHCInUcastPkts}{option};
								}
								delete $D->{ifHCInUcastPkts};
								if ($D->{ifHCOutUcastPkts}{value} =~ /\d+/) {
									$D->{ifOutUcastPkts}{value} = $D->{ifHCOutUcastPkts}{value};
									$D->{ifOutUcastPkts}{option} = $D->{ifHCOutUcastPkts}{option};
								}
								delete $D->{ifHCOutUcastPkts};

								if ($D->{ifHCInMcastPkts}{value} =~ /\d+/) {
									$D->{ifInMcastPkts}{value} = $D->{ifHCInMcastPkts}{value};
									$D->{ifInMcastPkts}{option} = $D->{ifHCInMcastPkts}{option};
								}
								delete $D->{ifHCInMcastPkts};
								if ($D->{ifHCOutMcastPkts}{value} =~ /\d+/) {
									$D->{ifOutMcastPkts}{value} = $D->{ifHCOutMcastPkts}{value};
									$D->{ifOutMcastPkts}{option} = $D->{ifHCOutMcastPkts}{option};
								}
								delete $D->{ifHCOutMcastPkts};

								if ($D->{ifHCInBcastPkts}{value} =~ /\d+/) {
									$D->{ifInBcastPkts}{value} = $D->{ifHCInBcastPkts}{value};
									$D->{ifInBcastPkts}{option} = $D->{ifHCInBcastPkts}{option};
								}
								delete $D->{ifHCInBcastPkts};
								if ($D->{ifHCOutBcastPkts}{value} =~ /\d+/) {
									$D->{ifOutBcastPkts}{value} = $D->{ifHCOutBcastPkts}{value};
									$D->{ifOutBcastPkts}{option} = $D->{ifHCOutBcastPkts}{option};
								}
								delete $D->{ifHCOutBcastPkts};

							}

							if ($sect eq 'interface') {
								$D->{ifDescr}{value} = rmBadChars($D->{ifDescr}{value});
								# Cache any data for use later.
								$IFCACHE->{$index}{ifAdminStatus} = $D->{ifAdminStatus}{value};
								$IFCACHE->{$index}{ifOperStatus} = $D->{ifOperStatus}{value};

								if ( $D->{ifInOctets}{value} ne "" and $D->{ifOutOctets}{value} ne "" ) {
									if ( not defined $S->{mdl}{custom}{interface}{ifAdminStatus} ) {
										dbg("status now admin=$D->{ifAdminStatus}{value}, oper=$D->{ifOperStatus}{value} was admin=$IF->{$index}{ifAdminStatus}, oper=$IF->{$index}{ifOperStatus}");
										if ($D->{ifOperStatus}{value} eq 'down') {
											if ($IF->{$index}{ifOperStatus} =~ /up|ok/) {
												# going down
												getIntfInfo(sys=>$S,index=>$index); # update this interface
											}
										}
										# must be up
										else {
											# Check if the status changed
											if ($IF->{$index}{ifOperStatus} !~ /up|ok|dormant/) {
												# going up
												getIntfInfo(sys=>$S,index=>$index); # update this interface
											}
										}
									}
									else {
										### 2014-03-14 keiths, special handling for manual interface discovery which does not use getIntfInfo.
										# interface now up or down, check and set or clear outstanding event.
										dbg("handling up/down admin=$D->{ifAdminStatus}{value}, oper=$D->{ifOperStatus}{value} was admin=$IF->{$index}{ifAdminStatus}, oper=$IF->{$index}{ifOperStatus}");
										$IF->{$index}{ifAdminStatus} = $D->{ifAdminStatus}{value};
										$IF->{$index}{ifOperStatus} = $D->{ifOperStatus}{value};

										if ( getbool($IF->{$index}{collect} )
												and $IF->{$index}{ifAdminStatus} =~ /up|ok/
												and $IF->{$index}{ifOperStatus} !~ /up|ok|dormant/
										) {
											if (getbool($IF->{$index}{event})) {
												notify(sys=>$S,event=>"Interface Down",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
											}
										} else {
											checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
										}
									}

									# If new ifDescr is different from old ifDescr rebuild interface info table
									# check if nodeConf modified this inteface
									my $node = $NI->{system}{name};
									my $ifDescr = $IF->{$index}{ifDescr};
									if ($NI->{system}{nodeType} =~ /router|switch/ and $NCT->{$node}{$ifDescr}{ifDescr} eq '' and
										$D->{ifDescr}{value} ne '' and $D->{ifDescr}{value} ne $IF->{$index}{ifDescr} ) {
										# Reload the interface config won't get that one right but should get the next one right
										logMsg("INFO ($S->{name}) ifIndex=$index - ifDescr has changed - old=$IF->{$index}{ifDescr} new=$D->{ifDescr}{value} - updating Interface Table");
										getIntfInfo(sys=>$S,index=>$index); # update this interface
									}

									delete $D->{ifDescr}; # dont store in rrd
									delete $D->{ifAdminStatus};

									if (exists $D->{ifLastChange}{value}){
										# convert time integer to time string
										$V->{interface}{"${index}_ifLastChange_value"} =
											$IF->{$index}{ifLastChange} =
												convUpTime($IF->{$index}{ifLastChangeSec} = int($D->{ifLastChange}{value}/100));
										dbg("last change time=$IF->{$index}{ifLastChange}, timesec=$IF->{$index}{ifLastChangeSec}");
									}
									delete $D->{ifLastChange};

									my $operStatus;
									# Calculate Operational Status
									$operStatus =  ($D->{ifOperStatus}{value} =~ /up|ok|dormant/ ) ? 100 : 0;
									$D->{ifOperStatus}{value} = $operStatus; # store real value in rrd

									# While updating start calculating the total availability of the node, depends on events set
									my $opstatus = getbool($IF->{$index}{event}) ? $operStatus : 100;
									$RI->{operStatus} = $RI->{operStatus} + $opstatus;
									$RI->{operCount} = $RI->{operCount} + 1;

									# count total number of collected interfaces up ( if events are set on)
									$RI->{intfColUp} += $operStatus/100 
											if getbool($IF->{$index}{event});
								} else{
									logMsg("ERROR ($S->{name}) ifIndex=$index, no values for ifInOctets and ifOutOctets received");
								}
							}

							if ($C->{debug}) {
								foreach my $ds (keys %{$D}) {
									dbg("rrdData section $sect, ds $ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}",2);
								}
							}

							# RRD Database update and remember filename
							info("updateRRD type$sect index=$index",2);
							my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index);
						}
						# calculate summary statistics of this interface only if intf up
						my $period = $C->{interface_util_period} || "-6 hours"; # bsts plus backwards compat
						my $util = getSummaryStats(sys=>$S,type=>"interface",start=> $period, end=>time,index=>$index);
						$V->{interface}{"${index}_operAvail_value"} = $util->{$index}{availability};
						$V->{interface}{"${index}_totalUtil_value"} = $util->{$index}{totalUtil};
						$V->{interface}{"${index}_operAvail_color"} = colorHighGood($util->{$index}{availability});
						$V->{interface}{"${index}_totalUtil_color"} = colorLowGood($util->{$index}{totalUtil});

						if ( defined $S->{mdl}{custom}{interface}{ifAdminStatus} 
								 and getbool($S->{mdl}{custom}{interface}{ifAdminStatus},"invert") ) {
							dbg("Updating view with ifAdminStatus=$IFCACHE->{$index}{ifAdminStatus} and ifOperStatus=$IFCACHE->{$index}{ifOperStatus}");
							$V->{interface}{"${index}_ifAdminStatus_color"} = getAdminColor(collect => $IF->{$index}{collect}, ifAdminStatus => $IFCACHE->{$index}{ifAdminStatus}, ifOperStatus => $IFCACHE->{$index}{ifOperStatus});
							$V->{interface}{"${index}_ifOperStatus_color"} = getOperColor(collect => $IF->{$index}{collect}, ifAdminStatus => $IFCACHE->{$index}{ifAdminStatus}, ifOperStatus => $IFCACHE->{$index}{ifOperStatus});
							$V->{interface}{"${index}_ifAdminStatus_value"} = $IFCACHE->{$index}{ifAdminStatus};
							$V->{interface}{"${index}_ifOperStatus_value"} = $IFCACHE->{$index}{ifOperStatus};
						}

						### 2012-08-14 keiths, logic here to verify an event exists and the interface is up.
						### this was causing events to be cleared when interfaces were collect true, oper=down, admin=up
						if ( eventExist($node, "Interface Down", $IF->{$index}{ifDescr}) and $IF->{$index}{ifOperStatus} =~ /up|ok|dormant/ ) {
							checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
						}
					}
					else {
						### 2012-03-29 keiths, SNMP is OK, some other error happened.
						dbg("ERROR ($NI->{system}{name}) on getIntfData, $rrdData->{error}");
					}

				} else {
					dbg("ERROR ($S->{name}) on getting data of interface=$index");
					$V->{interface}{"${index}_operAvail_value"} = 'N/A';
					$V->{interface}{"${index}_totalUtil_value"} = 'N/A';
					# inerface problems
					### 2013-11-06 keiths: this Interface Down does not appear to be valid, no data means we don't know commenting out the notify and changing to logMsg
					if (getbool($IF->{$index}{event})) {
						logMsg("ERROR: Interface SNMP Data: ifAdminStatus=$IF->{$index}{ifAdminStatus} ifOperStatus=$IF->{$index}{ifOperStatus} collect=$IF->{$index}{collect}");
						###notify(sys=>$S,event=>"Interface Down",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
					}
				}

				# header info of web page
				$V->{interface}{"${index}_operAvail_title"} = 'Intf. Avail.';
				$V->{interface}{"${index}_totalUtil_title"} = $C->{interface_util_label} || 'Util. 6hrs'; # backwards compat

				# check escalation if event is on
				if (getbool($IF->{$index}{event})) {
					my $event_hash = eventHash($S->{node}, "Interface Down", $IF->{$index}{ifDescr});
					my $escalate = exists $ET->{$event_hash}{escalate} ? $ET->{$event_hash}{escalate} : 'none';
					$V->{interface}{"${index}_escalate_title"} = 'Esc.';
					$V->{interface}{"${index}_escalate_value"} = $escalate;
				}

			} else {
				dbg("NOT Collected: $IF->{$index}{ifDescr}: ifIndex=$IF->{$index}{ifIndex}, OperStatus=$IF->{$index}{ifOperStatus}, ifAdminStatus=$IF->{$index}{ifAdminStatus}, Interface Collect=$IF->{$index}{collect}");
			}
		}
	} # FOR LOOP

	$S->{ET} = '';
	info("Finished");
} # getIntfData


#=========================================================================================

###
### Class Based Qos handling
### written by Cologne
###
sub getCBQoS {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $NC = $S->ndcfg;

	if ($NC->{node}{cbqos} !~ /true|input|output|both/) {
		info("no collecting ($NC->{node}{cbqos}) for node $NI->{system}{name}");
		return;
	}

	info("Starting for node $S->{name}");

	## oke,lets go
	if (getbool($S->{doupdate})) {
		getCBQoSwalk(sys=>$S); 	# get indexes
	} elsif (!getCBQoSdata(sys=>$S)) {
		getCBQoSwalk(sys=>$S); 	# get indexes
		getCBQoSdata(sys=>$S); 	# get data
	}

	info("Finished");

	return;

#===
	sub getCBQoSdata {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $SNMP = $S->snmp;
		my $CBQOS = $S->cbinfo;

		my %qosIntfTable;
		my @arrOID;
		my %cbQosTable;
		if (scalar keys %{$CBQOS}) {
			# oke, we have get now the PolicyIndex and ObjectsIndex directly
			foreach my $intf (keys %{$CBQOS}) {
				my $CB = $CBQOS->{$intf};
				foreach my $direction ("in","out") {
					if (exists $CB->{$direction}{'PolicyMap'}{'Name'}) {
						# check if Policymap name contains no collect info
						if ($CB->{$direction}{'PolicyMap'}{'Name'} =~ /$S->{mdl}{system}{cbqos}{nocollect}/i) {
							dbg("no collect for interface $intf $direction ($CB->{$direction}{'Interface'}{'Descr'}) by control ($S->{mdl}{system}{cbqos}{nocollect}) at Policymap $CB->{$direction}{'PolicyMap'}{'Name'}");
						} else {
							my $PIndex = $CB->{$direction}{'PolicyMap'}{'Index'};
							foreach my $key (keys %{$CB->{$direction}{'ClassMap'}}) {
								my $CMName = $CB->{$direction}{'ClassMap'}{$key}{'Name'};
								my $OIndex = $CB->{$direction}{'ClassMap'}{$key}{'Index'};
								info("Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex");

								# get the number of bytes/packets transfered and dropped
								my $port = "$PIndex.$OIndex";
								my $rrdData;
								if (($rrdData = $S->getData(class=>"cbqos-$direction", index=>$intf, port=>$port,model=>$model))) {
									processAlerts( S => $S );
									if ( $rrdData->{error} eq "" ) {
										my $D = $rrdData->{"cbqos-$direction"}{$intf};

										if ($D->{'PrePolicyByte'} eq "noSuchInstance") {
											dbg("mismatch of indexes, run walk");
											return undef;
										}
										# oke, store the data
										dbg("bytes transfered $D->{'PrePolicyByte'}{value}, bytes dropped $D->{'DropByte'}{value}");
										dbg("packets transfered $D->{'PrePolicyPkt'}{value}, packets dropped $D->{'DropPkt'}{value}");
										dbg("packets dropped no buffer $D->{'NoBufDropPkt'}{value}");
										#
										# update RRD
										my $db = updateRRD(sys=>$S,data=>$D,type=>"cbqos-$direction",index=>$intf,item=>$CMName);
									}
									else {
										### 2012-03-29 keiths, SNMP is OK, some other error happened.
										dbg("ERROR ($NI->{system}{name}) on getCBQoSdata, $rrdData->{error}");
									}
								}
								### 2012-03-28 keiths, handling SNMP Down during poll cycles.
								else {
									logMsg("ERROR ($NI->{system}{name}) on getCBQoSdata, SNMP problem");
									# failed by snmp
									snmpNodeDown(sys=>$S);
									dbg("ERROR, getting data");
									return 0;
								}
							}
						}
					}
				}
			}
		} else {
			return;
		}
	return 1;
	}

#====
	sub getCBQoSwalk {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $NC = $S->ndcfg;
		my $SNMP = $S->snmp;


		my $message;
		my %qosIntfTable;
		my @arrOID;
		my %cbQosTable;
		my $ifIndexTable;

		# get the interface indexes and objects from the snmp table

		# the default-default is no value whatsoever, for letting the snmp module do its thing
		my $max_repetitions = $NI->{system}{max_repetitions} || 0;

		info("start table scanning");

		# read qos interface table
		if ( $ifIndexTable = $SNMP->getindex('cbQosIfIndex',$max_repetitions)) {
			foreach my $PIndex (keys %{$ifIndexTable}) {
				my $intf = $ifIndexTable->{$PIndex}; # the interface number from de snmp qos table
				info("CBQoS, scan interface $intf");
				# is this an active interface
				if ( exists $IF->{$intf}) {

					### 2014-03-27 keiths, skipping CBQoS if not collecting data
					if ( getbool($IF->{$intf}{collect},"invert")) {
						dbg("Skipping CBQoS, No collect on interface $IF->{$intf}{ifDescr} ifIndex=$intf");
						next;
					}

					# oke, go
					my $answer;
					my %CMValues;
					my $direction;
					# check direction of qos with node table
					($answer->{'cbQosPolicyDirection'}) = $SNMP->getarray("cbQosPolicyDirection.$PIndex") ;
					dbg("direction of policy is $answer->{'cbQosPolicyDirection'}, Node table $NC->{node}{cbqos}");
					if( ($answer->{'cbQosPolicyDirection'} == 1 and $NC->{node}{cbqos} =~ /input|both/) or
							($answer->{'cbQosPolicyDirection'} == 2 and $NC->{node}{cbqos} =~ /output|true|both/) ) {
						# interface found with QoS input or output configured

						$direction = ($answer->{'cbQosPolicyDirection'} == 1) ? "in" : "out";
						info("Interface $intf found, direction $direction, PolicyIndex $PIndex");

						my $ifSpeedIn = $IF->{$intf}{ifSpeedIn} ? $IF->{$intf}{ifSpeedIn} : $IF->{$intf}{ifSpeed};
						my $ifSpeedOut = $IF->{$intf}{ifSpeedOut} ? $IF->{$intf}{ifSpeedOut} : $IF->{$intf}{ifSpeed};
						my $inoutIfSpeed = $direction eq "in" ? $ifSpeedIn : $ifSpeedOut;

						# get the policy config table for this interface
						my $qosIndexTable = $SNMP->getindex("cbQosConfigIndex.$PIndex",$max_repetitions);

						if ( $C->{debug} > 5 ) {
							print Dumper ( $qosIndexTable );
						}

						# the OID will be 1.3.6.1.4.1.9.9.166.1.5.1.1.2.$PIndex.$OIndex = Gauge
						BLOCK2:
						foreach my $OIndex (keys %{$qosIndexTable}) {
							# look for the Object type for each
							($answer->{'cbQosObjectsType'}) = $SNMP->getarray("cbQosObjectsType.$PIndex.$OIndex");
							dbg("look for object at $PIndex.$OIndex, type $answer->{'cbQosObjectsType'}");
							if($answer->{'cbQosObjectsType'} eq 1) {
								# it's a policy-map object, is it the primairy
								($answer->{'cbQosParentObjectsIndex'}) =
									$SNMP->getarray("cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($answer->{'cbQosParentObjectsIndex'} eq 0){
									# this is the primairy policy-map object, get the name
									($answer->{'cbQosPolicyMapName'}) =
										$SNMP->getarray("cbQosPolicyMapName.$qosIndexTable->{$OIndex}");
									dbg("policymap - name is $answer->{'cbQosPolicyMapName'}, parent ID $answer->{'cbQosParentObjectsIndex'}");
								}
							} elsif ($answer->{'cbQosObjectsType'} eq 2) {
								# it's a classmap, ask the name and the parent ID
								($answer->{'cbQosCMName'},$answer->{'cbQosParentObjectsIndex'}) =
									$SNMP->getarray("cbQosCMName.$qosIndexTable->{$OIndex}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								dbg("classmap - name is $answer->{'cbQosCMName'}, parent ID $answer->{'cbQosParentObjectsIndex'}");

								$answer->{'cbQosParentObjectsIndex2'} = $answer->{'cbQosParentObjectsIndex'} ;
								my $cnt = 0;

								#KS 2011-10-27 Redundant model object not in use: getbool($M->{system}{cbqos}{collect_all_cm})
								while ( !getbool($C->{'cbqos_cm_collect_all'},"invert")
											 and $answer->{'cbQosParentObjectsIndex2'} ne 0 
											 and $answer->{'cbQosParentObjectsIndex2'} ne $PIndex 
											 and $cnt++ lt 5) {
									($answer->{'cbQosConfigIndex'}) = $SNMP->getarray("cbQosConfigIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
									if ( $C->{debug} > 5 ) {
										print "Dumping cbQosConfigIndex\n";
										print Dumper ( $answer->{'cbQosConfigIndex'} );
									}

									# it is not the first level, get the parent names
									($answer->{'cbQosObjectsType2'}) = $SNMP->getarray("cbQosObjectsType.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
									if ( $C->{debug} > 5 ) {
										print "Dumping cbQosObjectsType2\n";
										print Dumper ( $answer->{'cbQosObjectsType2'} );
									}

									dbg("look for parent of ObjectsType $answer->{'cbQosObjectsType2'}");
									if ($answer->{'cbQosObjectsType2'} eq 1) {
										# it is a policymap name
										($answer->{'cbQosName'},$answer->{'cbQosParentObjectsIndex2'}) =
											$SNMP->getarray("cbQosPolicyMapName.$answer->{'cbQosConfigIndex'}","cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
										dbg("parent policymap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}");
										if ( $C->{debug} > 5 ) {
											print "Dumping cbQosName\n";
											print Dumper ( $answer->{'cbQosName'} );
											print "Dumping cbQosParentObjectsIndex2\n";
											print Dumper ( $answer->{'cbQosParentObjectsIndex2'} );
										}

									} elsif ($answer->{'cbQosObjectsType2'} eq 2) {
										# it is a classmap name
										($answer->{'cbQosName'},$answer->{'cbQosParentObjectsIndex2'}) =
											$SNMP->getarray("cbQosCMName.$answer->{'cbQosConfigIndex'}","cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
										dbg("parent classmap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}");
										if ( $C->{debug} > 5 ) {
											print "Dumping cbQosName\n";
											print Dumper ( $answer->{'cbQosName'} );
											print "Dumping cbQosParentObjectsIndex2\n";
											print Dumper ( $answer->{'cbQosParentObjectsIndex2'} );
										}
									} elsif ($answer->{'cbQosObjectsType2'} eq 3) {
										dbg("skip - this class-map is part of a match statement");
										next BLOCK2; # skip this class-map, is part of a match statement
									}
									# concatenate names
									if ($answer->{'cbQosParentObjectsIndex2'} ne 0) {
										$answer->{'cbQosCMName'} = "$answer->{'cbQosName'}--$answer->{'cbQosCMName'}";
									}
								}

								# collect all levels of classmaps or only the first level
								# KS 2011-10-27: by default collect hierarchical QoS
								if ( !getbool($C->{'cbqos_cm_collect_all'},"invert") 
										 or $answer->{'cbQosParentObjectsIndex'} eq $PIndex) 
								{
									#
									$CMValues{"H".$OIndex}{'CMName'} = $answer->{'cbQosCMName'} ;
									$CMValues{"H".$OIndex}{'CMIndex'} = $OIndex ;
								}
							} elsif ($answer->{'cbQosObjectsType'} eq 4) {
								my $CMRate;
								# it's a queueing object, look for the bandwidth
								($answer->{'cbQosQueueingCfgBandwidth'},$answer->{'cbQosQueueingCfgBandwidthUnits'},$answer->{'cbQosParentObjectsIndex'})
									= $SNMP->getarray("cbQosQueueingCfgBandwidth.$qosIndexTable->{$OIndex}","cbQosQueueingCfgBandwidthUnits.$qosIndexTable->{$OIndex}",
										"cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 1) {
									$CMRate = $answer->{'cbQosQueueingCfgBandwidth'}*1000;
								} elsif ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 2 or $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 3 ) {
									$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * $inoutIfSpeed/100;
								}
								if ($CMRate eq 0) { $CMRate = "undef"; }
								dbg("queueing - bandwidth $answer->{'cbQosQueueingCfgBandwidth'}, units $answer->{'cbQosQueueingCfgBandwidthUnits'},".
									"rate $CMRate, parent ID $answer->{'cbQosParentObjectsIndex'}");
								$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMCfgRate'} = $CMRate ;
							} elsif ($answer->{'cbQosObjectsType'} eq 6) {
								# traffic shaping
								($answer->{'cbQosTSCfgRate'},$answer->{'cbQosParentObjectsIndex'})
									= $SNMP->getarray("cbQosTSCfgRate.$qosIndexTable->{$OIndex}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								dbg("shaping - rate $answer->{'cbQosTSCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}");
									$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMTSCfgRate'} = $answer->{'cbQosPoliceCfgRate'};

							} elsif ($answer->{'cbQosObjectsType'} eq 7) {
								# police
								($answer->{'cbQosPoliceCfgRate'},$answer->{'cbQosParentObjectsIndex'})
									= $SNMP->getarray("cbQosPoliceCfgRate.$qosIndexTable->{$OIndex}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								dbg("police - rate $answer->{'cbQosPoliceCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}");
								$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMPoliceCfgRate'} = $answer->{'cbQosPoliceCfgRate'};
							}

							if ( $C->{debug} > 5 ) {
								print Dumper ( $answer );
							}

						}

						if ( $answer->{'cbQosPolicyMapName'} eq "" ) {
							$answer->{'cbQosPolicyMapName'} = 'default';
							dbg("policymap - name is blank, so setting to default");
						}

						$cbQosTable{$intf}{$direction}{'Interface'}{'Descr'} = $IF->{$intf}{'ifDescr'} ;
						$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'} = $answer->{'cbQosPolicyMapName'} ;
						$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Index'} = $PIndex ;

						# combine CM name and bandwidth
						foreach my $index (keys %CMValues ) {
							# check if CM name does exist
							if (exists $CMValues{$index}{'CMName'}) {

								$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Name'} = $CMValues{$index}{'CMName'};
								$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Index'} = $CMValues{$index}{'CMIndex'};

								# lets print the just type
								if (exists $CMValues{$index}{'CMCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMCfgRate'} ;
								} elsif (exists $CMValues{$index}{'CMTSCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Traffic shaping" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMTSCfgRate'} ;
								} elsif (exists $CMValues{$index}{'CMPoliceCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Police" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMPoliceCfgRate'} ;
								} else {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = "undef" ;
								}

							}
						}
					} else {
						dbg("No collect requested in Node table");
					}
				} else {
					dbg("Interface $intf does not exist");
				}
			}
			delete $S->{info}{cbqos}; # remove old info
			if (scalar (keys %{$ifIndexTable}) ) {
				# Finished with SNMP QoS, store object index values for the next run and CM names for WWW
				$S->{info}{cbqos} = \%cbQosTable;
			} else {
				dbg("no entries found in QoS table of node $NI->{name}");
			}
		}
	}
	return 1;
} # end getCBQoS

#=========================================================================================

sub getCalls {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $NC = $S->ndcfg;

	if (!getbool($NC->{node}{calls})) {
		dbg("no collecting for node $NI->{system}{name}");
		return;
	}

	dbg("Starting Calls for node $NI->{system}{name}");

	## oke,lets go
	if (getbool($S->{doupdate})) {
		getCallswalk(sys=>$S); # get indexes
	} elsif (!getCallsdata(sys=>$S)) {
		getCallswalk(sys=>$S); # get indexes
		getCallsdata(sys=>$S); # get data
	}
	dbg("Finished");

	return;

#===
	sub getCallsdata {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $CALLS = $S->callsinfo;

		my %totalsTable;
		my $rrdData;

		# get the old index values
		# the layout of the record is: channel intf intfDescr intfindex parentintfDescr parentintfindex port slot
		if (scalar keys %{$CALLS}) {
			BLOCK1:
			foreach my $index (keys %{$CALLS}) {
				my $port = $CALLS->{$index}{intfoid};
				if ($rrdData = $S->getData(class=>'calls',index=>$CALLS->{$index}{parentintfIndex},port=>$port,model=>$model)) {
					processAlerts( S => $S );
					if ( $rrdData->{error} eq "" ) {
						my $parentIndex = $CALLS->{$index}{parentintfIndex};
						my $D = $rrdData->{calls}{$parentIndex};
						# check indexen
						if ($D->{'cpmDS0CallType'}{value} eq "noSuchInstance") {
							dbg("invalid index, run walk");
							return; # no
						}
						#
						if ( $D->{'cpmCallCount'}{value} eq "" ) { $D->{'cpmCallCount'}{value} = 0 ;}
						# calculate totals for physical interfaces and dump them into totalsTable hash
						if ( $D->{'cpmDS0CallType'}{value} != "" ) {
		#					$D->{'cpmAvailableCallCount'}{value} = 1;	# calculate individual available DS0 ports no matter what their current state
							$totalsTable{$parentIndex}{'TotalDS0'} += 1 ;	# calculate total available DS0 ports no matter what their current state
						}
						$totalsTable{$parentIndex}{'TotalCallCount'} += $D->{'cpmCallCount'}{value};
						$totalsTable{$parentIndex}{'parentintfIndex'} = $parentIndex;
						$totalsTable{$parentIndex}{'parentintfDescr'} = $CALLS->{$index}{'parentintfDescr'};
						# populate totals for DS0 call types
						# total idle ports
						if ( $D->{'cpmDS0CallType'}{value} eq "1" ) {
							$totalsTable{$parentIndex}{'totalIdle'} += 1 ;
						}
						# total unknown ports
						if ( $D->{'cpmDS0CallType'}{value} eq "2" ) {
								$totalsTable{$parentIndex}{'totalUnknown'} += 1;
						}
						# total analog ports
						if ( $D->{'cpmDS0CallType'}{value} eq "3" ) {
							$totalsTable{$parentIndex}{'totalAnalog'} += 1 ;
						}
						# total digital ports
						if ( $D->{'cpmDS0CallType'}{value} eq "4" ) {
							$totalsTable{$parentIndex}{'totalDigital'} += 1 ;
						}
						# total v110 ports
						if ( $D->{'cpmDS0CallType'}{value} eq "5" ) {
							$totalsTable{$parentIndex}{'totalV110'} += 1 ;
						}
						# total v120 ports
						if ( $D->{'cpmDS0CallType'}{value} eq "6" ) {
							$totalsTable{$parentIndex}{'totalV120'} += 1 ;
						}
						# total voice ports
						if ( $D->{'cpmDS0CallType'}{value} eq "7" ) {
							$totalsTable{$parentIndex}{'totalVoice'} += 1 ;
						}
						if ( $D->{'cpmAvailableCallCount'}{value} eq "" ) { $D->{'cpmAvailableCallCount'} = 0 ;}
						if ( $D->{'cpmCallCount'} eq "" ) { $D->{'cpmCallCount'} = 0 ;}
					}
					else {
						### 2012-03-29 keiths, SNMP is OK, some other error happened.
						dbg("ERROR ($NI->{system}{name}) on getCallsdata, $rrdData->{error}");
					}
				}
				### 2012-03-28 keiths, handling SNMP Down during poll cycles.
				else {
					logMsg("ERROR ($NI->{system}{name}) on getCallsdata, SNMP problem");
					# failed by snmp
					snmpNodeDown(sys=>$S);
					dbg("ERROR, getting data");
					return 0;
				}
			}
			#
			# Second loop to populate RRD tables for totals
			BLOCK2:
			foreach my $intfindex (keys %totalsTable) {

				dbg("Total intf $intfindex, PortName $totalsTable{$intfindex}{'parentintfDescr'}");
				if ( $totalsTable{'TotalCallCount'} eq "" ) { $totalsTable{'TotalCallCount'} = 0 ;}

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
				$snmpVal{'totalIdle'}{value} = $totalsTable{$intfindex}{'totalIdle'};
				$snmpVal{'totalUnknown'}{value} = $totalsTable{$intfindex}{'totalUnknown'};
				$snmpVal{'totalAnalog'}{value} = $totalsTable{$intfindex}{'totalAnalog'};
				$snmpVal{'totalDigital'}{value} = $totalsTable{$intfindex}{'totalDigital'};
				$snmpVal{'totalV110'}{value} = $totalsTable{$intfindex}{'totalV110'};
				$snmpVal{'totalV120'}{value} = $totalsTable{$intfindex}{'totalV120'};
				$snmpVal{'totalVoice'}{value} = $totalsTable{$intfindex}{'totalVoice'};
				$snmpVal{'AvailableCallCount'}{value} = $totalsTable{$intfindex}{'TotalDS0'};
				$snmpVal{'CallCount'}{value} = $totalsTable{$intfindex}{'TotalCallCount'};

				#
				# Store data
				my $db = updateRRD(data=>\%snmpVal,sys=>$S,type=>"calls",index=>$intfindex);
			}
		return 1;
		}
	}

#====
	sub getCallswalk {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $SNMP = $S->snmp;


		my %seen;
		my %callsTable;
		my %mappingTable;
		my ($intfindex,$parentintfIndex);

		# the default-default is no value whatsoever, for letting the snmp module do its thing
		my $max_repetitions = $NI->{system}{max_repetitions} || 0;

		dbg("Starting Calls ports collection");

		# double check if any call interfaces on this node.
		# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
		# only collect on interfaces that are defined and that are Admin UP
		foreach ( keys %{$IF} ) {
			if ( $IF->{$_}{ifAdminStatus} eq "up"	) {
				$seen{$_} = $_;
			}
		}
		if ( ! %seen ) {	# empty hash
			dbg("$NI->{system}{name} does not have any call ports or no collect or port down - Call ports collection aborted");
			return;
		}

		# should now be good to go....
		# only use the Cisco private mib for cisco routers

		# add in the walk root for the cisco interface table entry for port to intf mapping
		add_mapping("1.3.6.1.4.1.9.10.19.1.5.2.1.8","cpmDS0InterfaceIndex","");
		add_mapping("1.3.6.1.2.1.31.1.2.1.3","ifStackStatus","");

		# getindex the cpmDS0InterfaceIndex oid to populate $callsTable hash with such as interface indexes, ports, slots
		my $IntfIndexTable;
		my $IntfStatusTable;
		if ($IntfIndexTable = $SNMP->getindex("cpmDS0InterfaceIndex",$max_repetitions)) {
			foreach my $index (keys %{$IntfIndexTable}) {
				$intfindex = $IntfIndexTable->{$index};
				my ($slot,$port,$channel) = split /\./,$index,3;
				$callsTable{$intfindex}{'intfoid'} = $index;
				$callsTable{$intfindex}{'intfindex'} = $intfindex;
				$callsTable{$intfindex}{'slot'} = $slot;
				$callsTable{$intfindex}{'port'} = $port;
				$callsTable{$intfindex}{'channel'} = $channel;
			}
			if ($IntfStatusTable = $SNMP->getindex("ifStackStatus",$max_repetitions)) {
				foreach my $index (keys %{$IntfStatusTable}) {
					($intfindex,$parentintfIndex) = split /\./,$index,2;
					$mappingTable{$intfindex}{'parentintfIndex'} = $parentintfIndex;
				}
				# traverse the callsTable and mappingTable hashes to match call ports with their physical parent ports
				foreach my $callsintf (sort keys %callsTable ) {
					foreach my $mapintf (sort keys %mappingTable ) {
						if ( $callsintf == $mapintf ) {
						dbg("parent interface $mappingTable{$mapintf}{'parentintfIndex'} found for interface $callsintf",2);
						# if parent interface has been reached stop
							if ( $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'} eq "0" ) {
								$callsTable{$callsintf}{'parentintfIndex'} = $mappingTable{$mapintf}{'parentintfIndex'};
							} # endif
							# assume only one level of nesting in physical interfaces
							# (may need to increase for larger Cisco chassis)
							else {
								$callsTable{$callsintf}{'parentintfIndex'} = $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'};
							} #end else
						} #end if
					} #end foreach
					# check if parent interface is also up
					if ( $IF->{$callsTable{$callsintf}{'parentintfIndex'}}{ifAdminStatus} ne "up" ) {
					##	print returnTime." Calls: parent interface $IF->{$callsTable{$callsintf}{'parentintfIndex'}}{ifDescr} is not up\n" if $debug;
						delete $callsTable{$callsintf} ;
					}
				} #end foreach
				# traverse the callsTable hash one last time and populate descriptive fields; also count total voice ports
				my $InstalledVoice;
				foreach my $callsintf ( keys %callsTable ) {
					(      $callsTable{$callsintf}{'intfDescr'},
														$callsTable{$callsintf}{'parentintfDescr'},
									) = $SNMP->getarray(
													'ifDescr'.".$callsTable{$callsintf}{'intfindex'}",
													'ifDescr'.".$callsTable{$callsintf}{'parentintfIndex'}",
									);
					$InstalledVoice++;
				} #end foreach

				# create $nodes-calls.xxxx file which contains interface mapping and descirption data
				delete $S->{info}{calls};
				if ( %callsTable) {
					# callsTable has some values, so write it out
					$S->{info}{calls} = \%callsTable;
					$NI->{system}{InstalledVoice} = "$InstalledVoice";
				}
			}
		}
	}
} # end getCalls

#=========================================================================================

sub getPVC {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $SNMP = $S->snmp;
	my $PVC = $S->pvcinfo;

	# quick exit if not a device supporting frame type interfaces !
	if ( $NI->{nodeType} ne "router" ) { return; }

	my %pvcTable;
	my $port;
	my $pvc;
	my $mibname;
	my %seen;
	my @ret;

	my %pvcStats;		# start this new every time
	my %snmpTable;

	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	dbg("Starting frame relay PVC collection");

	# double check if any frame relay interfaces on this node.
	# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
	# only collect on interfaces that are defined, with collection turned on globally
	# and for that interface and that are Admin UP
	foreach ( keys %{$IF} ) {
		if ( $IF->{$_}{ifType} =~ /framerelay/i
			and $IF->{$_}{ifAdminStatus} eq "up" and
			getbool($IF->{$_}{collect})
		) {
			$seen{$_} = $_;
		}
	}
	if ( ! %seen ) {	# empty hash
		dbg("$NI->{system}{name} does not have any frame ports or no collect or port down");
		goto END_getPVC;
	}

	my $cnt = keys %seen;
	dbg("found $cnt framerelay channel(s)");

	# should now be good to go....
	# only use the Cisco private mib for cisco routers

	# add in the walk root for the cisco interface table entry for pvc to intf mapping
	add_mapping("1.3.6.1.4.1.9.9.49.1.2.2.1.1","cfrExtCircuitIfName","");

	my $frCircEntryTable;
	my $cfrExtCircIfNameTable;
	if ( $frCircEntryTable = $SNMP->getindex('frCircuitEntry',$max_repetitions)) {
		foreach my $index (keys %{$frCircEntryTable}) {
			my ($oid,$port,$pvc) = split /\./,$index,3;
			my $textoid = oid2name("1.3.6.1.2.1.10.32.2.1.$oid");
			$pvcStats{$port}{$pvc}{$textoid} = $frCircEntryTable->{$index};
			if ($textoid =~ /ReceivedBECNs|ReceivedFECNs|ReceivedFrames|ReceivedOctets|SentFrames|SentOctets|State/) {
				$snmpTable{$port}{$pvc}{$textoid}{value} = $frCircEntryTable->{$index};
			}
		}
		if ( $NI->{system}{nodeModel} =~ /CiscoRouter/ ) {
			if ( $cfrExtCircIfNameTable = $SNMP->getindex('cfrExtCircuitIfName',$max_repetitions)) {
				foreach my $index (keys %{$cfrExtCircIfNameTable}) {
					my ($port,$pvc) = split /\./,$index;
					$pvcStats{$port}{$pvc}{'cfrExtCircuitIfName'} = $cfrExtCircIfNameTable->{$index};
				}
			}
		}

		# we now have a hash of port:pvc:mibname=value - or an empty hash if no reply....
		# put away to a rrd.
		foreach $port ( keys %pvcStats ) {

			# check if parent port was seen before and OK to collect on.
			if ( !exists $seen{$port} ) {
				dbg("snmp frame port $port is not collected or down - skipping");
				next;
			}

			foreach $pvc ( keys %{$pvcStats{$port}} ) {
				# massage some values
				# frCircuitState = 2 for active
				# could set an alarm here on PVC down ??
				if ( $pvcStats{$port}{$pvc}{'frCircuitState'} eq 2 ) {
					$pvcStats{$port}{$pvc}{'frCircuitState'} = 100;
				}
				else {
					$pvcStats{$port}{$pvc}{'frCircuitState'} = 0;
				}
				# RRD options
				$snmpTable{$port}{$pvc}{ReceivedBECNs}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedFECNs}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedFrames}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{ReceivedOctets}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{SentFrames}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{SentOctets}{option} = "counter,0:U";
				$snmpTable{$port}{$pvc}{State}{option} = "gauge,0:U";
				my $key = "${port}-${pvc}";
				if ((my $db = updateRRD(data=>\%{$snmpTable{$port}{$pvc}},sys=>$S,type=>"pvc",item=>$key)) ne "") {
					$NI->{graphtype}{$key}{pvc} = 'pvc';
				}
			}
		}

		# save a list of PVC numbers to an interface style dat file, with ifindex mappings, so we can use this to read and graph the rrd via the web ui.
		# save the cisco interface ifDescr if we have it.
		foreach $port ( keys %pvcStats ) {
			foreach $pvc (keys %{$pvcStats{$port}}) {
				my $key = "${port}-${pvc}";
				$pvcTable{$key}{subifDescr} = rmBadChars($pvcStats{$port}{$pvc}{cfrExtCircuitIfName});		# if not cisco, will not exist.
				$pvcTable{$key}{pvc} = $pvc;
				$pvcTable{$key}{port} = $port;			# should be ifIndex of parent frame relay interface
				$pvcTable{$key}{LastTimeChange} = $pvcStats{$port}{$pvc}{frCircuitLastTimeChange};
				$pvcTable{$key}{rrd} = $key;		# save this for filename lookups
				$pvcTable{$key}{CIR} = $pvcStats{$port}{$pvc}{frCircuitCommittedBurst};
				$pvcTable{$key}{EIR} = $pvcStats{$port}{$pvc}{frCircuitExcessBurst};
				$pvcTable{$key}{subifIndex} = $pvcStats{$port}{$pvc}{frCircuitLogicalIfIndex}; # non-cisco may support this - to be verified.
			}
		}
		if ( %pvcTable) {
			# pvcTable has some values, so write it out
			$S->{info}{pvc} = \%pvcTable;
			dbg("pvc values stored");
		} else {
			delete $S->{info}{pvc};
		}
	}
END_getPVC:
	dbg("Finished");
} # end getPVC


#=========================================================================================

sub runServer {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $SNMP = $S->snmp;

	my $result;
	my %Val;
	my %ValMeM;
	my $hrCpuLoad;

	if ($NI->{system}{nodeType} ne 'server') { return;}

	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	info("Starting server device/storage collection, node $NI->{system}{name}");

	# get cpu info
	delete $NI->{device};
	if ($M->{device} ne '') {
		my $deviceIndex = $SNMP->getindex('hrDeviceIndex',$max_repetitions);
		$S->loadInfo(class=>'device',model=>$model); # get cpu load without index
		foreach my $index (keys %{$deviceIndex}) {
			if ($S->loadInfo(class=>'device',index=>$index,model=>$model)) {
				my $D = $NI->{device}{$index};
				info("device Descr=$D->{hrDeviceDescr}, Type=$D->{hrDeviceType}");
				if ($D->{hrDeviceType} eq '1.3.6.1.2.1.25.3.1.3') { # hrDeviceProcessor
					($hrCpuLoad,$D->{hrDeviceDescr}) = $SNMP->getarray("hrProcessorLoad.${index}","hrDeviceDescr.${index}");
					dbg("CPU $index hrProcessorLoad=$hrCpuLoad hrDeviceDescr=$D->{hrDeviceDescr}");

					### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
					push(@{$S->{reach}{cpuList}},$hrCpuLoad);

					$NI->{device}{$index}{hrCpuLoad} = ($hrCpuLoad =~ /noSuch/i) ? $NI->{device}{hrCpuLoad} : $hrCpuLoad ;
					info("cpu Load=$NI->{device}{hrCpuLoad}, Descr=$D->{hrDeviceDescr}");
					undef %Val;
					$Val{hrCpuLoad}{value} = $NI->{device}{$index}{hrCpuLoad} || 0;
					if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrsmpcpu",index=>$index))) {
						$NI->{graphtype}{$index}{hrsmpcpu} = "hrsmpcpu";
					}
				} else {
					delete $NI->{device}{$index};
				}
			}
		}
	} else {
		dbg("Class=device not defined in model=$NI->{system}{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
	if ( ref($S->{reach}{cpuList}) and @{$S->{reach}{cpuList}} ) {
		$S->{reach}{cpu} = mean(@{$S->{reach}{cpuList}});
	}

	delete $NI->{storage};
	if ($M->{storage} ne '') {
		# get storage info
		my $disk_cnt = 1;
		my $storageIndex = $SNMP->getindex('hrStorageIndex',$max_repetitions);
		foreach my $index (keys %{$storageIndex}) {
			if ($S->loadInfo(class=>'storage',index=>$index,model=>$model)) {
				my $D = $NI->{storage}{$index};
				info("storage $D->{hrStorageDescr} Type=$D->{hrStorageType}, Size=$D->{hrStorageSize}, Used=$D->{hrStorageUsed}, Units=$D->{hrStorageUnits}");
				if (($M->{storage}{nocollect}{Description} ne '' and $D->{hrStorageDescr} =~ /$M->{storage}{nocollect}{Description}/ )
							or $D->{hrStorageSize} <= 0) {
					delete $NI->{storage}{$index};
				} else {
					if ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.4') { # hrStorageFixedDisk
						undef %Val;
						$Val{hrDiskSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrDiskUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Disk to Health Calculations.
						my $diskUtil = $Val{hrDiskUsed}{value} / $Val{hrDiskSize}{value} * 100;
						dbg("Disk List updated with Util=$diskUtil Size=$Val{hrDiskSize}{value} Used=$Val{hrDiskUsed}{value}",1);
						push(@{$S->{reach}{diskList}},$diskUtil);

						$D->{hrStorageDescr} =~ s/,/ /g;	# lose any commas.
						if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrdisk",index=>$index))) {
							$NI->{graphtype}{$index}{hrdisk} = "hrdisk";
							$D->{hrStorageType} = 'Fixed Disk';
							$D->{hrStorageIndex} = $index;
							$D->{hrStorageGraph} = "hrdisk";
							$disk_cnt++;
						}
					}
					### 2014-08-28 keiths, fix for VMware Real Memory as HOST-RESOURCES-MIB::hrStorageType.7 = OID: HOST-RESOURCES-MIB::hrStorageTypes.20 
					elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.2' or $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.20') { # Memory
						undef %Val;
						$Val{hrMemSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrMemUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Memory to Health Calculations.
						$S->{reach}{memfree} = $Val{hrMemSize}{value} - $Val{hrMemUsed}{value};
						$S->{reach}{memused} = $Val{hrMemUsed}{value};

						if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrmem"))) {
							$NI->{graphtype}{hrmem} = "hrmem";
							$D->{hrStorageType} = 'Memory';
							$D->{hrStorageGraph} = "hrmem";
						}
					}
					# in net-snmp, virtualmemory is used as type for both swap and 'virtual memory' (=phys + swap)
					elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.3') { # VirtualMemory
						undef %Val;

						my ($itemname,$typename)= ($D->{hrStorageDescr} =~ /Swap/i)?
								(qw(hrSwapMem hrswapmem)):(qw(hrVMem hrvmem));

						$Val{$itemname."Size"}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{$itemname."Used"}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2014-08-07 keiths, adding Other Memory to Health Calculations.
						$S->{reach}{$itemname."Free"} = $Val{$itemname."Size"}{value} - $Val{$itemname."Used"}{value};
						$S->{reach}{$itemname."Used"} = $Val{$itemname."Used"}{value};
						
						#print Dumper $S->{reach};

						if (my $db = updateRRD(sys=>$S, data=>\%Val, type=>$typename))
						{
							$NI->{graphtype}{$typename} = $typename;
							$D->{hrStorageType} = $D->{hrStorageDescr}; # i.e. virtual memory or swap space
							$D->{hrStorageGraph} = $typename;
						}
					}
					# also collect mem buffers and cached mem if present
					# these are marked as storagetype hrStorageOther but the descr is usable
					elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.1'  # StorageOther
									and $D->{hrStorageDescr} =~ /^(Memory buffers|Cached memory)$/i)
					{
							undef %Val;
							my ($itemname,$typename) = ($D->{hrStorageDescr} =~ /^Memory buffers$/i)?
									(qw(hrBufMem hrbufmem)) : (qw(hrCacheMem hrcachemem));

							# for buffers the total size isn't overly useful (net-snmp reports total phsymem),
							# for cached mem net-snmp reports total size == used cache mem
							$Val{$itemname."Size"}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
							$Val{$itemname."Used"}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

							if (my $db = updateRRD(sys=>$S, data=>\%Val, type=>$typename))
							{
									$NI->{graphtype}{$typename} = $typename;
									$D->{hrStorageType} = 'Other Memory';
									$D->{hrStorageGraph} = $typename;
							}
					} else {
						delete $NI->{storage}{$index};
					}
				}
			}
		}
	} else {
		dbg("Class=storage not defined in Model=$NI->{system}{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server Disk Usage to Health Calculations.
	if ( defined $S->{reach}{diskList} and @{$S->{reach}{diskList}} ) {
		#print Dumper $S->{reach}{diskList};
		$S->{reach}{disk} = mean(@{$S->{reach}{diskList}});
	}

	# convert date value to readable string
	sub snmp2date {
		my @tt = unpack("C*", shift );
		return eval(($tt[0] *256) + $tt[1])."-".$tt[2]."-".$tt[3].",".$tt[4].":".$tt[5].":".$tt[6].".".$tt[7];
	}
	info("Finished");
} # end runServer


#=========================================================================================

sub runServices {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $V =  $S->view;
	my $C = loadConfTable();
	my $NT = loadLocalNodeTable();
	my $SNMP = $S->snmp;

	my $node = $NI->{system}{name};

	info("Starting Services stats, node=$NI->{system}{name}, nodeType=$NI->{system}{nodeType}");
	#logMsg("Starting Services stats, node=$NI->{system}{name}, nodeType=$NI->{system}{nodeType}");

	# the default-default is no value whatsoever, for letting the snmp module do its thing
	my $max_repetitions = $NI->{system}{max_repetitions} || 0;

	my $service;
	my $cpu;
	my $memory;
	my $msg;
	my %services;		# hash to hold snmp gathered service status.
	my %status;			# hash to hold generic/non-snmp service status

	my $ST = loadServicesTable();
	my $timer = NMIS::Timing->new;

	# do an snmp service poll first, regardless of specific services being enabled or not
	my %snmpTable;
	my $timeout = 3;
	my ($snmpcmd,@ret, $var, $i, $key);
	my $write=0;
	
	my $nodeCheckSnmpServices = 0;
	foreach $service ( split /,/ , lc($NT->{$NI->{system}{name}}{services}) ) {
		if ( $ST->{$service}{Service_Type} eq "service" and $NI->{system}{nodeType} eq 'server' ) {		
			info("node has SNMP services to check");
			$nodeCheckSnmpServices = 1;
		}
	}

	# Only do SNMP servics if collect is true
	if ($nodeCheckSnmpServices 
			and getbool($NT->{$node}{active}) and getbool($NT->{$node}{collect})) {
		dbg("get index of hrSWRunName hrSWRunStatus by snmp");
		#logMsg("get index of hrSWRunName hrSWRunStatus by snmp");
		my @snmpvars = qw( hrSWRunName hrSWRunStatus hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem);
		my $hrIndextable;
		foreach my $var ( @snmpvars ) {
			if ( $hrIndextable = $SNMP->getindex($var,$max_repetitions)) {
				foreach my $inst (keys %{$hrIndextable}) {
					my $value = $hrIndextable->{$inst};
					my $textoid = oid2name(name2oid($var).".".$inst);
					if ( $textoid =~ /date\./i ) { $value = snmp2date($value) }
					( $textoid, $inst ) = split /\./, $textoid, 2;
					$snmpTable{$textoid}{$inst} = $value;
					dbg("Indextable=$inst textoid=$textoid value=$value",2);
				}
			}
		}
		
		# prepare service list for all observed services
		foreach (sort keys %{$snmpTable{hrSWRunName}} ) {
			# key services by name_pid
			$key = $snmpTable{hrSWRunName}{$_}.':'.$_;
			$services{$key}{hrSWRunName} = $key;
			$services{$key}{hrSWRunType} = ( '', 'unknown', 'operatingSystem', 'deviceDriver', 'application' )[$snmpTable{hrSWRunType}{$_}];
			$services{$key}{hrSWRunStatus} = ( '', 'running', 'runnable', 'notRunnable', 'invalid' )[$snmpTable{hrSWRunStatus}{$_}];
			$services{$key}{hrSWRunPerfCPU} = $snmpTable{hrSWRunPerfCPU}{$_};
			$services{$key}{hrSWRunPerfMem} = $snmpTable{hrSWRunPerfMem}{$_};
			
			dbg("$services{$key}{hrSWRunName} type=$services{$key}{hrSWRunType} status=$services{$key}{hrSWRunStatus} cpu=$services{$key}{hrSWRunPerfCPU} memory=$services{$key}{hrSWRunPerfMem}",2);
		}
		# keep all services for display (not rrd!)
		$NI->{services} = \%services;
	
		# now clear events that applied to processes that no longer exist
		$S->{ET} ||= loadEventStateNoLock();
		for my $eventkey (keys %{$S->{ET}})
		{
			my $event = $S->{ET}->{$eventkey};
			next if ($event->{node} ne $NI->{system}{name});
			# fixme NMIS-73: this should be tied to both the element format and a to-be-added 'service' field of the event
			# until then we trigger on the element format plus event name
			if ($event->{element} =~ /^\S+:\d+$/ 
					&& $event->{event} =~ /process memory/i
					&& !exists $services{$event->{element}})
			{
				dbg("clearing event $eventkey as process ".$event->{element}." no longer exists");
				checkEvent(sys => $S, event => $event->{event}, level => $event->{level}, 
									 element=>$event->{element}, details=>$event->{details});		
			}
		}
	}

	# specific services to be tested are saved in a list - these are rrd-collected, too.
	my $didRunServices = 0;
	foreach $service ( split /,/ , lc($NT->{$NI->{system}{name}}{services}) ) {
		$didRunServices = 1;
		
		# make sure this gets reinitialized for every service!	
  	my $gotMemCpu = 0;
		my %Val;

		# check for invalid service table
		next if $service =~ /n\/a/i;
		next if $ST->{$service}{Service_Type} =~ /n\/a/i;
		next if $service eq '';
		info("Checking service_type=$ST->{$service}{Service_Type} name=$ST->{$service}{Name} service_name=$ST->{$service}{Service_Name}");

		# clear global hash each time around as this is used to pass results to rrd update
		my $ret = 0;
		my $snmpdown = 0;

		# record the service response time, more precisely the time it takes us testing the service
		$timer->resetTime;
		my $responsetime;						# blank the responsetime

		# DNS: lookup whatever Service_name contains (fqdn or ip address), nameserver being the host in question
		if ( $ST->{$service}{Service_Type} eq "dns" ) {
			use Net::DNS;
			my $lookfor = $ST->{$service}{Service_Name};
			if (!$lookfor) {
				dbg("Service_Name for $NI->{system}{host} must be a FQDN or IP address");
				logMsg("ERROR, ($NI->{system}{name}) Service_name for service=$service must contain an FQDN or IP address");
				next;
			}
			my $res = Net::DNS::Resolver->new;
			$res->nameserver($NI->{system}{host});
			$res->udp_timeout(10);						# don't waste more than 10s on dud dns
			$res->usevc(0);										# force to udp (default)
			$res->debug(1) if $C->{debug} >3;	# set this to 1 for debug

			my $packet = $res->search($lookfor); # resolver figures out what to look for
			if (!defined $packet)
			{
					$ret = 0;
					dbg("ERROR Unable to lookup $lookfor on DNS server $NI->{system}{host}");
			}
			else
			{
					$ret = 1;
					dbg("DNS data for $lookfor from $NI->{system}{host} was ".$packet->string);
			}
		} # end DNS

		# now the 'port'
		elsif ( $ST->{$service}{Service_Type} eq "port" ) {
			$msg = '';
			my $nmap;

			my ( $scan, $port) = split ':' , $ST->{$service}{Port};

			if ( $scan =~ /udp/ ) {
				$nmap = "nmap -sU --host_timeout 3000 -p $port -oG - $NI->{system}{host}";
			}
			else {
				$nmap = "nmap -sT --host_timeout 3000 -p $port -oG - $NI->{system}{host}";
			}
			# now run it, need to use the open() syntax here, else we may not get the response in a multithread env.
			unless ( open(NMAP, "$nmap 2>&1 |")) {
				dbg("FATAL: Can't open nmap: $!");
			}
			while (<NMAP>) {
				$msg .= $_;
			}
			close(NMAP);

			if ( $msg =~ /Ports: $port\/open/ ) {
				$ret = 1;
				dbg("Success: $msg");
			}
			else {
				$ret = 0;
				dbg("Failed: $msg");
			}
		}
		# now the services !
		elsif ( $ST->{$service}{Service_Type} eq "service" 
						and $NI->{system}{nodeType} eq 'server' 
						and getbool($NT->{$node}{collect})) {
			# only do the SNMP checking if you are supposed to!
			dbg("snmp_stop_polling_on_error=$C->{snmp_stop_polling_on_error} snmpdown=$NI->{system}{snmpdown} nodedown=$NI->{system}{nodedown}");
			if ( getbool($C->{snmp_stop_polling_on_error},"invert") 
					 or ( getbool($C->{snmp_stop_polling_on_error}) and !getbool($NI->{system}{snmpdown}) 
								and !getbool($NI->{system}{nodedown}) ) ) 
			{
				if ($ST->{$service}{Service_Name} eq '') {
					dbg("ERROR, service_name is empty");
					logMsg("ERROR, ($NI->{system}{name}) service=$service service_name is empty");
					next;
				}


				# lets check the service status
				# NB - may have multiple services with same name on box.
				# so keep looking if up, last if one down
				# look for an exact match here on service name as read from snmp poll

				foreach ( sort keys %services ) {
					my ($svc) = split ':', $services{$_}{hrSWRunName};
					if ( $svc eq $ST->{$service}{Service_Name} ) {
						if ( $services{$_}{hrSWRunStatus} =~ /running|runnable/i ) {
							$ret = 1;
							$cpu = $services{$_}{hrSWRunPerfCPU};
							$memory = $services{$_}{hrSWRunPerfMem};
							$gotMemCpu = 1;
							info("INFO, service $ST->{$service}{Name} is up, status is $services{$_}{hrSWRunStatus}");
						}
						else {
							$ret = 0;
							$cpu = $services{$_}{hrSWRunPerfCPU};
							$memory = $services{$_}{hrSWRunPerfMem};
							$gotMemCpu = 1;
							info("INFO, service $ST->{$service}{Name} is down, status is $services{$_}{hrSWRunStatus}");
							last;
						}
					}
				}
			}
			else {
				# is the service already down?
				$snmpdown = 1;
			}
		}
		# now the sapi 'scripts' (similar to expect scripts)
		elsif ( $ST->{$service}{Service_Type} eq "script" )
		{
				### lets do the user defined scripts
				my $scripttext;
				if (!open(F, "$C->{script_root}/$service"))
				{
						dbg("ERROR, can't open script file for $service: $!");
				}
				else
				{
						$scripttext=join("",<F>);
						close(F);
						($ret,$msg) = sapi($NI->{system}{host},
															 $ST->{$service}{Port},
															 $scripttext,
															 3);
						dbg("Results of $service is $ret, msg is $msg");
				}
		}
		# 'real' scripts, or more precisely external programs
		elsif ( $ST->{$service}{Service_Type} eq "program" )
		{
				$ret = 0;
				my $svc = $ST->{$service};
				if (!$svc->{Program} or !-x $svc->{Program})
				{
						info("ERROR, service $service defined with no working Program to run!");
						logMsg("ERROR service $service defined with no working Program to run!");
						next;
				}
				# check the arguments (if given), substitute node.XYZ values
				my $finalargs;
				if ($svc->{Args})
				{
						$finalargs = $svc->{Args};
						$finalargs =~ s/(node\.(\S+))/$NI->{system}{$2}/g;

						dbg("external program args were $svc->{Args}, now $finalargs");
				}

				my $programexit = 0;
				eval
				{
						my @responses;

						local $SIG{ALRM} = sub { die "alarm\n"; };
						alarm($svc->{Max_Runtime}) if ($svc->{Max_Runtime} > 0); # setup execution timeout

						# run given program with given arguments and possibly read from it
						dbg("running external program '$svc->{Program} $finalargs', "
								.(getbool($svc->{Collect_Output})? "collecting":"ignoring")." output");
						if (!open(PRG,"$svc->{Program} $finalargs|"))
						{
								info("ERROR, cannot start service program $svc->{Program}: $!");
						}
						else
						{
								@responses = <PRG>; # always check for output but discard it if not required
								close PRG;
								$programexit = $?;

								if (getbool($svc->{Collect_Output}))
								{
										# now determine how to save the values in question
										for my $response (@responses)
										{
												chomp $response;
												my ($k,$v) = split(/=/,$response,2);
												dbg("collected response $k value $v");

												$Val{$k} = {value => $v};
												if ($k eq "responsetime") # response time is handled specially
												{
														$responsetime = $v;
												}
												else
												{
														$status{$svc->{Service_Name}}->{extra}->{$k} = $v;
												}

										}
								}
						}
						alarm(0) if ($svc->{Max_Runtime} > 0); # cancel any timeout
				};

				if ($@ and $@ eq "alarm\n")
				{
						info("ERROR, service program $svc->{Program} exceeded Max_Runtime of $svc->{Max_Runtime}s, terminated.");
						$ret=0;
				}
				else
				{
						# if the external program died abnormally we treat this as 0=dead.
						$programexit = WIFEXITED($programexit)? WEXITSTATUS($programexit) : 0;
						dbg("external program terminated with exit code $programexit");
						$ret = $programexit > 100? 100: $programexit;
				};
		}
		else {
			# no service type found
			dbg("ERROR, service handling not found");
			$ret = 0;
			$msg = '';
			next;			# just do the next one - no alarms
		}

		# let external programs set the responsetime if so desired
		$responsetime = $timer->elapTime if (!defined $responsetime);
		$status{$ST->{$service}{Service_Name}}->{responsetime} = $responsetime;
		$status{$ST->{$service}{Service_Name}}->{name} = $ST->{$service}{Service_Name};

		#logMsg("Updating $node Service, $ST->{$service}{Name}, $ret, gotMemCpu=$gotMemCpu");
		$V->{system}{"${service}_title"} = "Service $ST->{$service}{Name}";
		$V->{system}{"${service}_value"} = $ret ? 'running' : 'down';
		$V->{system}{"${service}_responsetime"} = $responsetime;
		$V->{system}{"${service}_color"} =  $ret ? 'white' : 'red';
		$V->{system}{"${service}_cpumem"} = $gotMemCpu ? 'true' : 'false';
		$V->{system}{"${service}_gurl"} = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=service&node=$NI->{system}{name}&intf=$service";

		# external programs return 0..100 directly
		my $serviceValue = ( $ST->{$service}{Service_Type} eq "program" )? $ret : $ret*100;
		$status{$ST->{$service}{Service_Name}}->{status} = $serviceValue;

		# lets raise or clear an event
		if ( $snmpdown ) {
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is not checked, snmp is down");
			$V->{system}{"${service}_value"} = 'unknown';
			$V->{system}{"${service}_color"} = 'gray';
			$serviceValue = '';
		}
		elsif ( $ret ) {
			# Service is UP!
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is available");
			checkEvent(sys=>$S,event=>"Service Down",level=>"Normal",element=>$ST->{$service}{Name},details=>"" );
		} else {
			# Service is down
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is unavailable");
			notify(sys=>$S,event=>"Service Down",element=>$ST->{$service}{Name},details=>"" );
		}

		# save result for availability history - one file per service per node
		$Val{service}{value} = $serviceValue;
		if ( $cpu < 0 ) {
			$cpu = $cpu * -1;
		}
		$Val{responsetime}{value} = $responsetime; # might be a NOP
		$Val{responsetime}{option} = "GAUGE,0:U";

		if ($gotMemCpu) {
			$Val{cpu}{value} = $cpu;
			$Val{cpu}{option} = "COUNTER,U:U";
			$Val{memory}{value} = $memory;
			$Val{memory}{option} = "GAUGE,U:U";
		}

		if (( my $db = updateRRD(data=>\%Val,sys=>$S,type=>"service",item=>$service))) {
			$NI->{graphtype}{$service}{service} = 'service,service-response';
			if ($gotMemCpu) {
				$NI->{graphtype}{$service}{service} = 'service,service-response,service-mem,service-cpu';
			}
		}
	} # foreach

	if ( $didRunServices ) {
		# save the service_status node info
		$S->{info}{service_status} = \%status;
		### 2014-12-16 keiths, when did the services poll last complete properly.
		$NI->{system}{lastServicesPoll} = time();
	}
END_runServices:
	info("Finished");
} # end runServices

#=========================================================================================


# fixme: the CVARn evaluation function should be integrated into and handled by sys::parseString
sub runAlerts {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $CA = $S->alerts;

	my $result;
	my %Val;
	my %ValMeM;
	my $hrCpuLoad;

	info("Running Custom Alerts for node $NI->{system}{name}");

	foreach my $sect (keys %{$CA}) {
		info("Custom Alerts for $sect");
		foreach my $index ( keys %{$NI->{$sect}} ) {
			foreach my $alrt ( keys %{$CA->{$sect}} ) {
				if ( defined($CA->{$sect}{$alrt}{control}) and $CA->{$sect}{$alrt}{control} ne '' ) {
					my $control_result = $S->parseString(string=>"($CA->{$sect}{$alrt}{control}) ? 1:0",sys=>$S,index=>$index,type=>$sect,sect=>$sect);
					dbg("control_result sect=$sect index=$index control_result=$control_result");
					next if not $control_result;
				}

				# perform CVARn substitution for these two types of ops
				if ( $CA->{$sect}{$alrt}{type} =~ /^(test$|threshold)/ )
				{
						my ($test, $value, $alert, $test_value, $test_result);

						# do this for test and value
						for my $thingie (['test',\$test_result],['value',\$test_value])
						{
								my ($key, $target) = @$thingie;

								my $origexpr = $CA->{$sect}{$alrt}{$key};
								my ($rebuilt,@CVAR);
								# rip apart expression, rebuild it with var substitutions
								while ($origexpr =~ s/^(.*?)(CVAR(\d)=(\w+);|\$CVAR(\d))//)
								{
										$rebuilt.=$1;					 # the unmatched, non-cvar stuff at the begin
										my ($varnum,$decl,$varuse)=($3,$4,$5); # $2 is the whole |-group

										if (defined $varnum) # cvar declaration
										{
												$CVAR[$varnum] = $NI->{$sect}->{$index}->{$decl};
												logMsg("ERROR: CVAR$varnum references unknown object \"$decl\" in \""
															 .$CA->{$sect}{$alrt}{$key}.'"')
														if (!exists $NI->{$sect}->{$index}->{$decl});
										}
										elsif (defined $varuse) # cvar use
										{
												logMsg("ERROR: CVAR$varuse used but not defined in test \""
															 .$CA->{$sect}{$alrt}{$key}.'"')
														if (!exists $CVAR[$varuse]);

												$rebuilt .= $CVAR[$varuse]; # sub in the actual value
										}
										else 						# shouldn't be reached, ever
										{
												logMsg("ERROR: CVAR parsing failure for \"".$CA->{$sect}{$alrt}{$key}.'"');
												$rebuilt=$origexpr='';
												last;
										}
								}
								$rebuilt.=$origexpr; # and the non-CVAR-containing remainder.

								$$target = eval { eval $rebuilt; };
								dbg("substituted $key sect=$sect index=$index, orig=\"".$CA->{$sect}{$alrt}{$key}
										."\", expr=\"$rebuilt\", result=$$target",2);
						}

						if ( $test_value =~ /^[\+-]?\d+\.\d+$/ ) {
								$test_value = sprintf("%.2f",$test_value);
						}

						my $level=$CA->{$sect}{$alrt}{level};

						# check the thresholds
						if ( $CA->{$sect}{$alrt}{type} =~ /^threshold/ )
						{
								if ( $CA->{$sect}{$alrt}{type} eq "threshold-rising" ) {
										if ( $test_value <= $CA->{$sect}{$alrt}{threshold}{Normal} ) {
												$test_result = 0;
												$level = "Normal";
										}
										else {
												my @levels = qw(Warning Minor Major Critical Fatal);
												foreach my $lvl (@levels) {
														if ( $test_value <= $CA->{$sect}{$alrt}{threshold}{$lvl} ) {
																$test_result = 1;
																$level = $lvl;
																last;
														}
												}
										}
								}
								elsif ( $CA->{$sect}{$alrt}{type} eq "threshold-falling" ) {
										if ( $test_value >= $CA->{$sect}{$alrt}{threshold}{Normal} ) {
												$test_result = 0;
												$level = "Normal";
										}
										else {
												my @levels = qw(Warning Minor Major Critical Fatal);
												foreach my $lvl (@levels) {
														if ( $test_value >= $CA->{$sect}{$alrt}{threshold}{$lvl} ) {
																$test_result = 1;
																$level = $lvl;
																last;
														}
												}
										}
								}
								info("alert result: test_result=$test_result level=$level",2);
						}

						# and now save the result, for both tests and thresholds (source of level is the only difference)
						$alert->{type} = $CA->{$sect}{$alrt}{type};
						$alert->{test} = $CA->{$sect}{$alrt}{value};
						$alert->{name} = $S->{name};
						$alert->{unit} = $CA->{$sect}{$alrt}{unit};
						$alert->{event} = $CA->{$sect}{$alrt}{event};
						$alert->{level} = $level;
						$alert->{ds} = $NI->{$sect}{$index}{$CA->{$sect}{$alrt}{element}};
						$alert->{test_result} = $test_result;
						$alert->{value} = $test_value;
						push( @{$S->{alerts}}, $alert );
				}
			}
		}
	}

	processAlerts( S => $S );

	info("Finished");
} # end runAlerts

#=========================================================================================

sub runCheckValues {
	my %args = @_;
	my $S = $args{sys};	# system object
	my $NI = $S->ndinfo;
	my $M = $S->mdl;	# Model table of node
	my $C = loadConfTable();

	if ( !getbool($NI->{system}{nodedown}) and !getbool($NI->{system}{snmpdown}) ) {
		for my $sect ( keys %{$M->{system}{sys}} ) {
			my $control = $M->{system}{sys}{$sect}{control}; 	# check if skipped by control
			if ($control ne "") {
				dbg("control=$control found for section=$sect",2);
				if ($S->parseString(string=>"($control) ? 1:0", sect => $sect) ne "1") {
					dbg("threshold of section $sect skipped by control=$control");
					next;
				}
				#								}
				for my $attr (keys %{$M->{system}{sys}{$sect}{snmp}} ) {

					if (exists $M->{system}{sys}{$sect}{snmp}{$attr}{check}) {
					# select the method we will run
						my $check = $M->{system}{sys}{$sect}{snmp}{$attr}{check};
						if ($check eq 'checkPower') {
							checkPower(sys=>$S,attr=>$attr);
						# }
						# elsif ($check eq 'checkNodeConfiguration') {
						# 	checkNodeConfiguration(sys=>$S,attr=>$attr);
						} else {
							logMsg("ERROR ($S->{name}) unknown method=$check in Model=$NI->{system}{nodeModel}");
						}
					}
				}
			}
		}
	}

END_runCheckValues:
	dbg("Finished");
} # end runCheckValues

#=========================================================================================
#
# send event of node down by snmp
#
sub snmpNodeDown {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;	# node info
	# failed by snmp
	notify(sys=>$S,event=>"SNMP Down",element=>'',details=>"SNMP error");
	$NI->{system}{snmpdown} = 'true';
	return 0;
}
#=========================================================================================

sub runReach {
	my %args = @_;
	my $S = $args{sys};	# system object
	my $check = $args{check} || 0;
	my $NI = $S->ndinfo;	# node info
	my $IF = $S->ifinfo;	# interface info
	my $RI = $S->reach;	# reach info
	my $C = loadConfTable();

	#print Dumper($S);

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
	my $responseHealth = 0;
	my $cpuHealth = 0;

	my $memHealth = 0;
	my $intHealth = 0;
	my $swapHealth = 0;
	my $diskHealth = 0;

	my $reachabilityMax = 100 * $C->{weight_reachability};
	my $availabilityMax = 100 * $C->{weight_availability};
	my $responseMax = 100 * $C->{weight_response};
	my $cpuMax = 100 * $C->{weight_cpu};
	my $memMax = 100 * $C->{weight_mem};
	my $intMax = 100 * $C->{weight_int};
	
	my $swapMax = 0;
	my $diskMax = 0;

	info("Starting node $NI->{system}{name}, type=$NI->{system}{nodeType}");

	# Math hackery to convert Foundry CPU memory usage into appropriate values
	$RI->{memused} = ($RI->{memused} - $RI->{memfree}) if $NI->{nodeModel} =~ /FoundrySwitch/;

	if ( $NI->{nodeModel} =~ /Riverstone/ ) {
		# Math hackery to convert Riverstone CPU memory usage into appropriate values
		$RI->{memfree} = ($RI->{memfree} - $RI->{memused});
		$RI->{memused} = $RI->{memused} * 16;
		$RI->{memfree} = $RI->{memfree} * 16;
	}

	if ( $RI->{memfree} == 0 or $RI->{memused} == 0 ) {
		$RI->{mem} = 100;
	} else {
		#'hrSwapMemFree' => 4074844160,
  	#'hrSwapMemUsed' => 220114944,
  	my $mainMemWeight = 1;
  	my $extraMem = 0;
  	
  	if ( defined $RI->{hrSwapMemFree} and defined $RI->{hrSwapMemUsed} and $RI->{hrSwapMemFree} and $RI->{hrSwapMemUsed} ) {
			$RI->{swap} = ( $RI->{hrSwapMemFree} * 100 ) / ($RI->{hrSwapMemUsed} + $RI->{hrSwapMemFree});  		
  	}
		else {
			$RI->{swap} = 0;
		}

		# calculate mem
		if ( $RI->{memfree} > 0 and $RI->{memused} > 0 ) {
			$RI->{mem} = ( $RI->{memfree} * 100 ) / ($RI->{memused} + $RI->{memfree});
		}
		else {
			$RI->{mem} = "U";
		}
	}

	# copy results from object
	my $pingresult = $RI->{pingresult};
	my $snmpresult = $RI->{snmpresult};

	my %reach;		# copy in local table
	$reach{cpu} = $RI->{cpu};
	$reach{mem} = $RI->{mem};
	if ( $RI->{swap} ) {
		$reach{swap} = $RI->{swap};
	}
	$reach{disk} = 0;
	if ( defined $RI->{disk} and $RI->{disk} > 0 ) {
		$reach{disk} = $RI->{disk};
	}
	$reach{responsetime} = $RI->{pingavg};
	$reach{loss} = $RI->{pingloss};
	$reach{operStatus} = $RI->{operStatus};
	$reach{operCount} = $RI->{operCount};

	# number of interfaces
	$reach{intfTotal} = $NI->{system}{intfTotal} eq 0 ? 'U' : $NI->{system}{intfTotal}; # from run update
	$reach{intfCollect} = $NI->{system}{intfCollect}; # from run update
	$reach{intfUp} = $RI->{intfUp} ne '' ? $RI->{intfUp} : 0; # from run collect
	$reach{intfColUp} = $RI->{intfColUp}; # from run collect

	# Things which don't do collect get 100 for availability
	if ( $reach{availability} eq "" and !getbool($NI->{system}{collect}) ) {
		$reach{availability} = "100";
	}
	elsif ( $reach{availability} eq "" ) { $reach{availability} = "U"; }

	my ($outage,undef) = outageCheck(node=>$S->{node},time=>time());
	dbg("Outage for $S->{name} is $outage");
	# Health should actually reflect a combination of these values
	# ie if response time is high health should be decremented.
	if ( $pingresult == 100 and $snmpresult == 100 ) {

		$reach{reachability} = 100;
		if ( $reach{operCount} > 0 ) {
			$reach{availability} =  sprintf("%.2f", $reach{operStatus} / $reach{operCount});
		}

		if ($reach{reachability} > 100) { $reach{reachability} = 100; }
		($reach{responsetime},$responseWeight) = weightResponseTime($reach{responsetime});

		if ( getbool($NI->{system}{collect}) and $reach{cpu} ne "" ) {
			if    ( $reach{cpu} <= 10 ) { $cpuWeight = 100; }
			elsif ( $reach{cpu} <= 20 ) { $cpuWeight = 90; }
			elsif ( $reach{cpu} <= 30 ) { $cpuWeight = 80; }
			elsif ( $reach{cpu} <= 40 ) { $cpuWeight = 70; }
			elsif ( $reach{cpu} <= 50 ) { $cpuWeight = 60; }
			elsif ( $reach{cpu} <= 60 ) { $cpuWeight = 50; }
			elsif ( $reach{cpu} <= 70 ) { $cpuWeight = 35; }
			elsif ( $reach{cpu} <= 80 ) { $cpuWeight = 20; }
			elsif ( $reach{cpu} <= 90 ) { $cpuWeight = 10; }
			elsif ( $reach{cpu} <= 100 ) { $cpuWeight = 1; }

			if ( $reach{disk} ) {
				if    ( $reach{disk} <= 10 ) { $diskWeight = 100; }
				elsif ( $reach{disk} <= 20 ) { $diskWeight = 90; }
				elsif ( $reach{disk} <= 30 ) { $diskWeight = 80; }
				elsif ( $reach{disk} <= 40 ) { $diskWeight = 70; }
				elsif ( $reach{disk} <= 50 ) { $diskWeight = 60; }
				elsif ( $reach{disk} <= 60 ) { $diskWeight = 50; }
				elsif ( $reach{disk} <= 70 ) { $diskWeight = 35; }
				elsif ( $reach{disk} <= 80 ) { $diskWeight = 20; }
				elsif ( $reach{disk} <= 90 ) { $diskWeight = 10; }
				elsif ( $reach{disk} <= 100 ) { $diskWeight = 1; }

				dbg("Reach for Disk disk=$reach{disk} diskWeight=$diskWeight");
			}

			# Very aggressive swap weighting, 11% swap is pretty healthy.
			if ( $reach{swap} ) {
				if    ( $reach{swap} >= 95 ) { $swapWeight = 100; }
				elsif ( $reach{swap} >= 89 ) { $swapWeight = 95; }
				elsif ( $reach{swap} >= 70 ) { $swapWeight = 90; }
				elsif ( $reach{swap} >= 50 ) { $swapWeight = 70; }
				elsif ( $reach{swap} >= 30 ) { $swapWeight = 50; }
				elsif ( $reach{swap} >= 10 ) { $swapWeight = 30; }
				elsif ( $reach{swap} >= 0 ) { $swapWeight = 1; }

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
		elsif ( getbool($NI->{system}{collect}) and $NI->{system}{nodeModel} eq "Generic" ) {
			$cpuWeight = 100;
			$memWeight = 100;
			### ehg 16 sep 2002 also make interface aavilability 100% - I dont care about generic switches interface health !
			$reach{availability} = 100;
		}
		else {
			$cpuWeight = 100;
			$memWeight = 100;
			### 2012-12-13 keiths, removed this stoopid line as availability was allways 100%
			### $reach{availability} = 100;
		}

		# Added little fix for when no interfaces are collected.
		if ( $reach{availability} !~ /\d+/ ) {
			$reach{availability} = "100";
		}

		# Makes 3Com memory health weighting always 100, and CPU, and Interface availibility
		if ( $NI->{system}{nodeModel} =~ /SSII 3Com/i ) {
			$cpuWeight = 100;
			$memWeight = 100;
			$reach{availability} = 100;

		}

		# Makes CatalystIOS memory health weighting always 100.
		# Add Baystack and Accelar
		if ( $NI->{system}{nodeModel} =~ /CatalystIOS|Accelar|BayStack|Redback|FoundrySwitch|Riverstone/i ) {
			$memWeight = 100;
		}

		info("REACH Values: reachability=$reach{reachability} availability=$reach{availability} responsetime=$reach{responsetime}");
		info("REACH Values: CPU reach=$reach{cpu} weight=$cpuWeight, MEM reach=$reach{mem} weight=$memWeight");	

		if ( getbool($NI->{system}{collect}) and defined $S->{mdl}{interface}{nocollect}{ifDescr} ) {
			dbg("Getting Interface Utilisation Health");
			$intcount = 0;
			$intsummary = 0;
			# check if interface file exists - node may not be updated as yet....
			foreach my $index (keys %{$IF}) {
				# Don't do any stats cause the interface is not one we collect
				if ( getbool($IF->{$index}{collect}) ) {
					# Get the link availability from the local node!!!
					my $util = getSummaryStats(sys=>$S,type=>"interface",start=>"-15 minutes",end=>time(),index=>$index);
					if ($util->{$index}{inputUtil} eq 'NaN' or $util->{$index}{outputUtil} eq 'NaN') {
						dbg("SummaryStats for interface=$index of node $NI->{system}{name} skipped because value is NaN");
						next;
					}
					
					# lets make the interface metric the largest of input or output
					my $intUtil = $util->{$index}{inputUtil};
					if ( $intUtil < $util->{$index}{outputUtil} ) {
						$intUtil = $util->{$index}{outputUtil};
					}
					
					# only add interfaces with utilisation above metric_int_utilisation_above configuration option
					if ( $intUtil > $C->{'metric_int_utilisation_above'} or $C->{'metric_int_utilisation_above'} eq "" ) {
						$intsummary = $intsummary + ( 100 - $intUtil );
						++$intcount;
						info("Intf Summary util=$intUtil in=$util->{$index}{inputUtil} out=$util->{$index}{outputUtil} intsumm=$intsummary count=$intcount");
					}
				}
			} # FOR LOOP
			if ( $intsummary != 0 ) {
				$intWeight = sprintf( "%.2f", $intsummary / $intcount);
			} else {
				$intWeight = "NaN"
			}
		}
		else {
			$intWeight = 100;
		}

		# if the interfaces are unhealthy and lost stats, whack a 100 in there
		if ( $intWeight eq "NaN" or $intWeight > 100 ) { $intWeight = 100; }

		# Would be cool to collect some interface utilisation bits here.
		# Maybe thresholds are the best way to handle that though.  That
		# would pickup the peaks better.

		# keeping the health values for storing in the RRD		
		$reachabilityHealth = ($reach{reachability} * $C->{weight_reachability});
		$availabilityHealth = ($reach{availability} * $C->{weight_availability});
		$responseHealth = ($responseWeight * $C->{weight_response});
		$cpuHealth = ($cpuWeight * $C->{weight_cpu});
		$memHealth = ($memWeight * $C->{weight_mem});
		$intHealth = ($intWeight * $C->{weight_int});
		$swapHealth = 0;
		$diskHealth = 0;
		
		# the minimum value for health should always be 1
		$reachabilityHealth = 1 if $reachabilityHealth < 1;
		$availabilityHealth = 1 if $availabilityHealth < 1;
		$responseHealth = 1 if $responseHealth < 1;
		$cpuHealth = 1 if $cpuHealth < 1;

		# overload the int and mem with swap and disk 
		if ( $reach{swap} ) {
			$memHealth = ($memWeight * $C->{weight_mem}) / 2;
			$swapHealth =  ($swapWeight * $C->{weight_mem}) / 2;
			$memMax = 100 * $C->{weight_mem} / 2;
			$swapMax = 100 * $C->{weight_mem} / 2;;

			# the minimum value for health should always be 1
			$memHealth = 1 if $memHealth < 1;
			$swapHealth = 1 if $swapHealth < 1;
		}

		if ( $reach{disk} ) {
			$intHealth = ($intWeight * ($C->{weight_int} / 2));
			$diskHealth = ($diskWeight * ($C->{weight_int} / 2));
			$intMax = 100 * $C->{weight_int} / 2;	
			$diskMax = 100 * $C->{weight_int} / 2;
			
			# the minimum value for health should always be 1
			$intHealth = 1 if $intHealth < 1;
			$diskHealth = 1 if $diskHealth < 1;
		}

		# Health is made up of a weighted values:
		### AS 16 Mar 02, implemented weights in nmis.conf
		$reach{health} = 	(
						$reachabilityHealth +
						$availabilityHealth + 
						$responseHealth +
						$cpuHealth +
						$memHealth +
						$intHealth +
						$diskHealth +
						$swapHealth
					);
		
		info("Calculation of health=$reach{health}");
		if (lc $reach{health} eq 'nan') {
			dbg("Values Calc. reachability=$reach{reachability} * $C->{weight_reachability}");
			dbg("Values Calc. intWeight=$intWeight * $C->{weight_int}");
			dbg("Values Calc. responseWeight=$responseWeight * $C->{weight_response}");
			dbg("Values Calc. availability=$reach{availability} * $C->{weight_availability}");
			dbg("Values Calc. cpuWeight=$cpuWeight * $C->{weight_cpu}");
			dbg("Values Calc. memWeight=$memWeight * $C->{weight_mem}");
			dbg("Values Calc. swapWeight=$swapWeight * $C->{weight_mem}");
		}
	}
	elsif ( !getbool($NI->{system}{collect}) and $pingresult == 100 ) {
		$reach{reachability} = 100;
		$reach{availability} = 100;
		$reach{intfTotal} = 'U';
		($reach{responsetime},$responseWeight) = weightResponseTime($reach{responsetime});
		$reach{health} = ($reach{reachability} * 0.9) + ( $responseWeight * 0.1);
	}
	elsif ( ($pingresult == 0 or $snmpresult == 0) and $outage eq 'current') {
		$reach{reachability} = "U";
		$reach{availability} = "U";
		$reach{intfTotal} = 'U';
		$reach{responsetime} = "U";
		$reach{health} = "U";
		$reach{loss} = "U";
	}
	elsif ( $pingresult == 100 and $snmpresult == 0 ) {
		$reach{reachability} = 80; # correct ? is up and degraded
		$reach{availability} = "U";
		$reach{intfTotal} = 'U';
		$reach{health} = "U";
	}
	else {
		$reach{reachability} = 0;
		$reach{availability} = "U";
		$reach{responsetime} = "U";
		$reach{intfTotal} = 'U';
		$reach{health} = 0;
	}

	dbg("Reachability and Metric Stats Summary");
	dbg("collect=$NI->{system}{collect} (Node table)");
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

	for $index ( sort keys %reach ) {
		dbg("$index=$reach{$index}");
	}

	$reach{health} = ($reach{health} > 100) ? 100 : $reach{health};
	my %reachVal;
	$reachVal{reachability}{value} = $reach{reachability};
	$reachVal{availability}{value} = $reach{availability};
	$reachVal{responsetime}{value} = $reach{responsetime};
	$reachVal{health}{value} = $reach{health};

	$reachVal{reachabilityHealth}{value} = $reachabilityHealth;
	$reachVal{availabilityHealth}{value} = $availabilityHealth;
	$reachVal{responseHealth}{value} = $responseHealth;
	$reachVal{cpuHealth}{value} = $cpuHealth;
	$reachVal{memHealth}{value} = $memHealth;
	$reachVal{intHealth}{value} = $intHealth;
	$reachVal{diskHealth}{value} = $diskHealth;
	$reachVal{swapHealth}{value} = $swapHealth;

	$reachVal{loss}{value} = $reach{loss};
	$reachVal{intfTotal}{value} = $reach{intfTotal};
	$reachVal{intfUp}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfUp};
	$reachVal{intfCollect}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfCollect};
	$reachVal{intfColUp}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfColUp};
	$reachVal{reachability}{option} = "gauge,0:100";
	$reachVal{availability}{option} = "gauge,0:100";
	### 2014-03-18 keiths, setting maximum responsetime to 30 seconds.
	$reachVal{responsetime}{option} = "gauge,0:30000";
	$reachVal{health}{option} = "gauge,0:100";

	$reachVal{reachabilityHealth}{option} = "gauge,0:100";
	$reachVal{availabilityHealth}{option} = "gauge,0:100";
	$reachVal{responseHealth}{option} = "gauge,0:100";
	$reachVal{cpuHealth}{option} = "gauge,0:100";
	$reachVal{memHealth}{option} = "gauge,0:100";
	$reachVal{intHealth}{option} = "gauge,0:100";
	$reachVal{diskHealth}{option} = "gauge,0:100";
	$reachVal{swapHealth}{option} = "gauge,0:100";

	$reachVal{loss}{option} = "gauge,0:100";
	$reachVal{intfTotal}{option} = "gauge,0:U";
	$reachVal{intfUp}{option} = "gauge,0:U";
	$reachVal{intfCollect}{option} = "gauge,0:U";
	$reachVal{intfColUp}{option} = "gauge,0:U";

	my $db = updateRRD(sys=>$S,data=>\%reachVal,type=>"health"); # database name is 'reach'
	$NI->{graphtype}{health} = $NI->{system}{nodeModel} eq 'PingOnly' ? "health-ping,response" : "health,kpi,response,numintf";

END_runReach:
	info("Finished");
} # end runHealth

#=========================================================================================

sub getIntfAllInfo {
	my $index;
	my $tmpDesc;
	my $intHash;
	my %interfaceInfo;

	### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
	if ( getbool($C->{disable_interfaces_summary}) ) {
		logMsg("getIntfAllInfo disabled with disable_interfaces_summary=$C->{disable_interfaces_summary}");
		return;
	}

	dbg("Starting");

	dbg("Getting Interface Info from all nodes");

	my $NT = loadLocalNodeTable();

	# Write a node entry for each node
	foreach my $node (sort keys %{$NT}) {
		if ( getbool($NT->{$node}{active}) and getbool($NT->{$node}{collect})) {
			my $info = loadNodeInfoTable($node);
			dbg("ADD node=$node",3);
			if (exists $info->{interface}) {
				foreach my $intf (keys %{$info->{interface}}) {

					$tmpDesc = &convertIfName($info->{interface}{$intf}{ifDescr});

					$intHash = "$node-$tmpDesc";

					dbg("$node $tmpDesc hash=$intHash $info->{$intf}{ifDescr}",3);

					if ( $info->{interface}{$intf}{ifDescr} ne "" ) {
						dbg("Add node=$node interface=$info->{interface}{$intf}{ifDescr}",2);
						$interfaceInfo{$intHash}{node} = $node;
						$interfaceInfo{$intHash}{sysName} = $info->{system}{sysName};
						$interfaceInfo{$intHash}{ifIndex} = $info->{interface}{$intf}{ifIndex};
						$interfaceInfo{$intHash}{ifDescr} = $info->{interface}{$intf}{ifDescr};
						$interfaceInfo{$intHash}{collect} = $info->{interface}{$intf}{collect};
						$interfaceInfo{$intHash}{real} = $info->{interface}{$intf}{real};
						$interfaceInfo{$intHash}{ifType} = $info->{interface}{$intf}{ifType};
						$interfaceInfo{$intHash}{ifSpeed} = $info->{interface}{$intf}{ifSpeed};
						$interfaceInfo{$intHash}{ifAdminStatus} = $info->{interface}{$intf}{ifAdminStatus};
						$interfaceInfo{$intHash}{ifOperStatus} = $info->{interface}{$intf}{ifOperStatus};
						$interfaceInfo{$intHash}{ifLastChange} = $info->{interface}{$intf}{ifLastChange};
						$interfaceInfo{$intHash}{Description} = $info->{interface}{$intf}{Description};
						$interfaceInfo{$intHash}{portModuleIndex} = $info->{interface}{$intf}{portModuleIndex};
						$interfaceInfo{$intHash}{portIndex} = $info->{interface}{$intf}{portIndex};
						$interfaceInfo{$intHash}{portDuplex} = $info->{interface}{$intf}{portDuplex};
						$interfaceInfo{$intHash}{portIfIndex} = $info->{interface}{$intf}{portIfIndex};
						$interfaceInfo{$intHash}{portSpantreeFastStart} = $info->{interface}{$intf}{portSpantreeFastStart};
						$interfaceInfo{$intHash}{vlanPortVlan} = $info->{interface}{$intf}{vlanPortVlan};
						$interfaceInfo{$intHash}{portAdminSpeed} = $info->{interface}{$intf}{portAdminSpeed};
						my $cnt = 1;
						while ($info->{interface}{$intf}{"ipAdEntAddr$cnt"} ne '') {
							$interfaceInfo{$intHash}{"ipAdEntAddr$cnt"} = $info->{interface}{$intf}{"ipAdEntAddr$cnt"};
							$interfaceInfo{$intHash}{"ipAdEntNetMask$cnt"} = $info->{interface}{$intf}{"ipAdEntNetMask$cnt"};
							$interfaceInfo{$intHash}{"ipSubnet$cnt"} = $info->{interface}{$intf}{"ipSubnet$cnt"};
							$interfaceInfo{$intHash}{"ipSubnetBits$cnt"} = $info->{interface}{$intf}{"ipSubnetBits$cnt"};
							$cnt++;
						}
					}
				}
			} else {
				logMsg("INFO empty interface info file of node $node");
			}
		}
	} # foreach $linkname
	# Write the interface table out.
	dbg("Writing Interface Info from all nodes");
	writeTable(dir=>'var',name=>"nmis-interfaces",data=>\%interfaceInfo);
	dbg("Finished");
}

#=========================================================================================

### create hash  write to /var for speeding up
### Cologne 2005
###
sub getNodeAllInfo {

	my %Info;

	dbg("Starting");
	dbg("Getting Info from all nodes");

	my $NT = loadLocalNodeTable();

	# Write a node entry for each  node
	foreach my $node (sort keys %{$NT}) {
		if ( getbool($NT->{$node}{active}) ) {
			my $nodeInfo = loadNodeInfoTable($node);
			# using this info
			$Info{$node}{nodeVendor} = $nodeInfo->{system}{nodeVendor};
			$Info{$node}{nodeModel} = $nodeInfo->{system}{nodeModel};
			$Info{$node}{nodeType} = $nodeInfo->{system}{nodeType};
		}
	}
	# write to disk
	writeTable(dir=>'var',name=>"nmis-nodeinfo",data=>\%Info) ;
	dbg("Finished");
}

#=========================================================================================

# fixme: deprecated, will be removed once the last customers who're using models
# with this feature have upgraded to 8.5.6.
sub runCustomPlugins {
	my %args = @_;
	my $S = $args{sys};
	my $node = $args{node};

	dbg("Starting, node $node");
	foreach my $custom ( keys %{$S->{mdl}{custom}} ) {
		if ( defined $S->{mdl}{custom}{$custom}{script} and $S->{mdl}{custom}{$custom}{script} ne "" ) {
			dbg("Found Custom Script $S->{mdl}{custom}{$custom}{script}");
			#Only scripts in /usr/local/nmis8/admin can be run.
			my $exec = "$C->{'<nmis_base>'}/$S->{mdl}{custom}{$custom}{script} node=$node debug=$C->{debug}";
			my $out = `$exec 2>&1`;
			if ( $out and $C->{debug} ) {
				dbg($out);
			}
			elsif ( $out ) {
				logMsg($out);
			}
		}
	}
	dbg("Finished");
}

#=========================================================================================

sub weightResponseTime {
	my $rt = shift;
	my $responseWeight = 0;

	if ( $rt eq "" ) {
		$rt = "U";
		$responseWeight = 0;
	}
	elsif ( $rt !~ /^[0-9]/ ) {
		$rt = "U";
		$responseWeight = 0;
	}
	elsif ( $rt == 0 ) {
		$rt = 1;
		$responseWeight = 100;
	}
	elsif ( $rt >= 1500 ) { $responseWeight = 0; }
	elsif ( $rt >= 1000 ) { $responseWeight = 10; }
	elsif ( $rt >= 900 ) { $responseWeight = 20; }
	elsif ( $rt >= 800 ) { $responseWeight = 30; }
	elsif ( $rt >= 700 ) { $responseWeight = 40; }
	elsif ( $rt >= 600 ) { $responseWeight = 50; }
	elsif ( $rt >= 500 ) { $responseWeight = 60; }
	elsif ( $rt >= 400 ) { $responseWeight = 70; }
	elsif ( $rt >= 300 ) { $responseWeight = 80; }
	elsif ( $rt >= 200 ) { $responseWeight = 90; }
	elsif ( $rt >= 0 ) { $responseWeight = 100; }
	return ($rt,$responseWeight);
}


#=========================================================================================

### 2011-12-29 keiths, centralising the copy of the remote files from slaves, so others can just load them.
sub nmisMaster {
	my %args = @_;

	$C->{master_sleep} = 15 if $C->{master_sleep} eq "";

	if (getbool($C->{server_master})) {
		info("Running NMIS Master Functions");

		if ( $C->{master_sleep} or $sleep ) {
			my $sleepNow = $C->{master_sleep};
			$sleepNow = $sleep if $sleep;
			info("Master is sleeping $sleepNow seconds (waiting for summary updates on slaves)");
			sleep $sleepNow;
		}

		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";
			
			info("Master, processing Slave Server $srv, $ST->{$srv}{host}");

			dbg("Get loadnodedetails from $srv");
			getFileFromRemote(server => $srv, func => "loadnodedetails", group => $ST->{$srv}{group}, format => "text", file => getFileName(file => "$C->{'<nmis_var>'}/nmis-${srv}-Nodes"));

			dbg("Get sumnodetable from $srv");
			getFileFromRemote(server => $srv, func => "sumnodetable", group => $ST->{$srv}{group}, format => "text", file => getFileName(file => "$C->{'<nmis_var>'}/nmis-${srv}-nodesum"));

			my @hours = qw(8 16);
			foreach my $hour (@hours) {
				my $function = "summary". $hour ."h";
				dbg("get summary$hour from $srv");
				getFileFromRemote(server => $srv, func => "summary$hour", group => $ST->{$srv}{group}, format => "text", file => getFileName(file => "$C->{'<nmis_var>'}/nmis-$srv-$function"));
			}
		}
	}
}


#=========================================================================================

# preload all summary stats - for metric update and dashboard display.
sub nmisSummary {
	my %args = @_;

	dbg("Calculating NMIS network stats for cgi cache");
	func::update_operations_stamp(type => "summary", start => $C->{starttime}, stop => undef)
			if ($type eq "summary");	# not if part of collect

	my $S = Sys::->new;

	### 2014-08-28 keiths, configurable metric periods
	my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

	summaryCache(sys=>$S,file=>'nmis-summary8h',start=>$metricsFirstPeriod,end=>time() );
	my $k = summaryCache(sys=>$S,file=>'nmis-summary16h', start=>$metricsSecondPeriod, end=>$metricsFirstPeriod );

	my $NS = getNodeSummary(C => $C);
	my $file = "nmis-nodesum";
	writeTable(dir=>'var',name=>$file,data=>$NS);
	dbg("Finished calculating NMIS network stats for cgi cache - wrote $k nodes");
	func::update_operations_stamp(type => "summary", start => $C->{starttime}, stop => time())
			if ($type eq "summary");	# not if part of collect

	sub summaryCache {
		my %args = @_;
		my $S = $args{sys};
		my $file = $args{file};
		my $start = $args{start};
		my $end = $args{end};
		my %summaryHash = ();
		my $NT = loadLocalNodeTable();
		my $NI;

		foreach my $node ( keys %{$NT}) {
			if ( getbool($NT->{$node}{active}) ) {
				$S->init(name=>$node,snmp=>'false');
				$NI = $S->ndinfo;
				#
				$summaryHash{$node}{reachable} = 'NaN';
				$summaryHash{$node}{response} = 'NaN';
				$summaryHash{$node}{loss} = 'NaN';
				$summaryHash{$node}{health} = 'NaN';
				$summaryHash{$node}{available} = 'NaN';
				$summaryHash{$node}{intfCollect} = 0;
				$summaryHash{$node}{intfColUp} = 0;
				my $stats;
				if (($stats = getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$node))) {
					%summaryHash = (%summaryHash,%{$stats});
				}
				if ( getbool($NI->{system}{nodedown}) ) {
					$summaryHash{$node}{nodedown} = 'true';
				}
				else {
					$summaryHash{$node}{nodedown} = 'false';
				}
			}
		}

		writeTable(dir=>'var',name=>$file,data=>\%summaryHash );
		return (scalar keys %summaryHash);
	}
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
sub runEscalate {
	my %args = @_;

	my $C = loadConfTable();
	my $NT = loadLocalNodeTable();

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
	my $serial = 0;
	my $serial_ns = 0;
	my %seen;

	dbg("Starting");
	func::update_operations_stamp(type => "escalate", start => $C->{starttime}, stop => undef)
			if ($type eq "escalate");	# not if part of collect
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
	if ( tableExists('ServiceStatus') ) {
		$ServiceStatusTable = loadGenericTable('ServiceStatus');
		$useServiceStatusTable = 1;
	}

	my $BusinessServicesTable;
	my $useBusinessServicesTable = 0;
	if ( tableExists('BusinessServices') ) {
		$BusinessServicesTable = loadGenericTable('BusinessServices');
		$useBusinessServicesTable = 1;
	}

	# the events configuration table, controls active/notify/logging for each known event
	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql


	# Load the event table into the hash
	# have to maintain a lock over all of this
	# we are out of threading code now, so no great problem with holding the lock.
	my ($ET,$handle);
	if ( getbool($C->{db_events_sql}) ) {
		$ET = DBfunc::->select(table=>'Events');
	} else {
		($ET,$handle) = loadEventStateLock();
	}

	# add a full format time string for emails and message notifications
	# pull the system timezone and then the local time
	my $msgtime = get_localtime();

	# send UP events to all those contacts notified as part of the escalation procedure
	foreach $event_hash ( sort keys %{$ET} )  {
		next if getbool($ET->{$event_hash}{current});

		# if the event is configured for no notify, do nothing

		# event control is as configured or all true.
		my $thisevent_control = $events_config->{$ET->{$event_hash}->{event}} || { Log => "true", Notify => "true", Status => "true"};
		# in case of Notify being off for this event, we don't have to check/walk/handle any notify fields at all
		# as we're deleting the record after the loop anyway.
		if (getbool($thisevent_control->{Notify}))
		{
			foreach my $field ( split(',',$ET->{$event_hash}{notify}) ) # field = type:contact
			{ 
				$target = "";
				my @x = split /:/ , $field;
				my $type = shift @x;			# netsend, email, or pager ?
				dbg("Escalation type=$type contact=$contact");
				
				if ( $type =~ /email|ccopy|pager/ ) {
					foreach $contact (@x) {
						if ( exists $CT->{$contact} ) {
							if ( dutyTime($CT, $contact) ) {	# do we have a valid dutytime ??
								if ($type eq "pager") {
									$target = $target ? $target.",".$CT->{$contact}{Pager} : $CT->{$contact}{Pager};
								} else {
									$target = $target ? $target.",".$CT->{$contact}{Email} : $CT->{$contact}{Email};
								}
							}
						}
						else {
							dbg("Contact $contact not found in Contacts table");
						}
					} #foreach
					
					# no email targets found, and if default contact not found, assume we are not covering 24hr dutytime in this slot, so no mail.
					# maybe the next levelx escalation field will fill in the gap
					if ( !$target ) {
						if ( $type eq "pager" ) {
							$target = $CT->{default}{Pager};
						} else {
							$target = $CT->{default}{Email};
						}
						dbg("No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target");
					}
					
					if ( $target)
					{
						foreach my $trgt ( split /,/, $target ) {
							my $message;
							my $priority;
							if ( $type eq "pager" ) 
							{
								$msgTable{$type}{$trgt}{$serial_ns}{message} = "NMIS: UP Notify $ET->{$event_hash}{node} Normal $ET->{$event_hash}{event} $ET->{$event_hash}{element}";
								$serial_ns++ ;
							} 
							else 
							{
								if ($type eq "ccopy") {
									$message = "FOR INFORMATION ONLY\n";
									$priority = &eventToSMTPPri("Normal");
								} else {
									$priority = &eventToSMTPPri($ET->{$event_hash}{level}) ;
								}
								$event_age = convertSecsHours(time - $ET->{$event_hash}{startdate});
								
								$message .= "Node:\t$ET->{$event_hash}{node}\nUP Event Notification\nEvent Elapsed Time:\t$event_age\nEvent:\t$ET->{$event_hash}{event}\nElement:\t$ET->{$event_hash}{element}\nDetails:\t$ET->{$event_hash}{details}\n\n";
								
								if ( getbool($C->{mail_combine}) ) 
								{
									$msgTable{$type}{$trgt}{$serial}{count}++;
									$msgTable{$type}{$trgt}{$serial}{subject} = "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
									$msgTable{$type}{$trgt}{$serial}{message} .= $message ;
									if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} ) {
										$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
									}
								}
								else 
								{
									$msgTable{$type}{$trgt}{$serial}{subject} = "$ET->{$event_hash}{node} $ET->{$event_hash}{event} - $ET->{$event_hash}{element} - $ET->{$event_hash}{details} at $msgtime" ;
									$msgTable{$type}{$trgt}{$serial}{message} = $message ;
									$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
									$msgTable{$type}{$trgt}{$serial}{count} = 1;
									$serial++;
								}
							}
						}
						# log the meta event, ONLY if both Log (and Notify) are enabled
						logEvent(node => $ET->{$event_hash}{node}, event => "$type to $target UP Notify", 
										 level => "Normal", element => $ET->{$event_hash}{element}, 
										 details => $ET->{$event_hash}{details})
								if (getbool($thisevent_control->{Log}));
								
						
						dbg("Escalation $type UP Notification node=$ET->{$event_hash}{node} target=$target level=$ET->{$event_hash}{level} event=$ET->{$event_hash}{event} element=$ET->{$event_hash}{element} details=$ET->{$event_hash}{details} group=$NT->{$ET->{$event_hash}{node}}{group}");
					}
				} # end email,ccopy,pager
				# now the netsends
				elsif ( $type eq "netsend" ) 
				{
					my $message = "UP Event Notification $ET->{$event_hash}{node} Normal $ET->{$event_hash}{event} $ET->{$event_hash}{element} $ET->{$event_hash}{details} at $msgtime";
					foreach my $trgt ( @x ) 
					{
						$msgTable{$type}{$trgt}{$serial_ns}{message} = $message ;
						$serial_ns++;
						dbg("NetSend $message to $trgt");
						# log the meta event, ONLY if both Log (and Notify) are enabled
						logEvent(node => $ET->{$event_hash}{node}, event => "NetSend $message to $trgt UP Notify", level => "Normal", element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details})
								if (getbool($thisevent_control->{Log}));
					} #foreach
				} # end netsend
				elsif ( $type eq "syslog" )
				{
					if (getbool($C->{syslog_use_escalation})) # syslog action 
					{
						my $timenow = time();
						my $message = "NMIS_Event::$C->{server_name}::$timenow,$ET->{$event_hash}{node},$ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
						my $priority = eventToSyslog($ET->{$event_hash}{level});
						
						foreach my $trgt ( @x ) {
							$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
							$msgTable{$type}{$trgt}{$serial_ns}{priority} = $priority;
							$serial_ns++;
							dbg("syslog $message");
						} #foreach
					}
				} # end syslog
				elsif ( $type eq "json" ) 
				{
					# make it an up event
					my $event = $ET->{$event_hash};
					my $node = $NT->{$event->{node}};
					$event->{nmis_server} = $C->{server_name};
					$event->{customer} = $node->{customer};
					$event->{location} = $LocationsTable->{$node->{location}}{Location};
					$event->{geocode} = $LocationsTable->{$node->{location}}{Geocode};
					
					if ( $useServiceStatusTable ) {
						$event->{serviceStatus} = $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
						$event->{statusPriority} = $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
					}
					
					if ( $useBusinessServicesTable ) {
						$event->{businessService} = $BusinessServicesTable->{$node->{businessService}}{businessService};
						$event->{businessPriority} = $BusinessServicesTable->{$node->{businessService}}{businessPriority};
					}
					
					# Copy the fields from nodes to the event
					my @nodeFields = split(",",$C->{'json_node_fields'});
					foreach my $field (@nodeFields) {
						$event->{$field} = $node->{$field};
					}
				
					logJsonEvent(event => $event, dir => $C->{'json_logs'});
				} # end json
				# any custom notification methods?
				else
				{
					if ( checkPerlLib("Notify::$type") ) 
					{
						dbg("Notify::$type $contact");
						
						my $timenow = time();
						my $datenow = returnDateStamp();
						my $message = "$datenow: $ET->{$event_hash}{node}, $ET->{$event_hash}{event}, $ET->{$event_hash}{level}, $ET->{$event_hash}{element}, $ET->{$event_hash}{details}";
						foreach $contact (@x) {
							if ( exists $CT->{$contact} ) {
								if ( dutyTime($CT, $contact) ) {	# do we have a valid dutytime ??
									# check if UpNotify is true, and save with this event
									# and send all the up event notifies when the event is cleared.
									if ( getbool($EST->{$esc_key}{UpNotify}) 
											 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
										) {
										my $ct = "$type:$contact";
										my @l = split(',',$ET->{$event_hash}{notify});
										if (not grep { $_ eq $ct } @l ) {
											push @l, $ct;
											$ET->{$event_hash}{notify} = join(',',@l);
										}
									}
									#$serial
									$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
									$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
									$msgTable{$type}{$contact}{$serial_ns}{event} = $ET->{$event_hash};
									$serial_ns++;
								}
							}
							else {
								dbg("Contact $contact not found in Contacts table");
							}
						}
					}
					else {
						dbg("ERROR runEscalate problem with escalation target unknown at level$ET->{$event_hash}{escalate} $level type=$type");
					}
				}
			}
		}
		# remove this entry
		if ( getbool($C->{db_events_sql}) ) {
			DBfunc::->delete(table=>'Events',index=>$event_hash);
		} else {
			delete $ET->{$event_hash};
		}
		dbg("event entry $event_hash deleted");
	}

	#===========================================

	# now handle escalations
LABEL_ESC:
	foreach $event_hash ( keys %{$ET} )  
	{
		dbg("process event with event_hash=$event_hash");
		# set event control to policy or default of enabled.
		my $thisevent_control = $events_config->{$ET->{$event_hash}->{event}} || { Log => "true", Notify => "true", Status => "true"};

		my $nd = $ET->{$event_hash}{node};
		# lets start with checking that we have a valid node -the node may have been deleted.
		if ( getbool($ET->{$event_hash}{current}) and ( !$NT->{$nd} or getbool($NT->{$nd}{active},"invert")) ) 
		{
			if (getbool($thisevent_control->{Log}) and getbool($thisevent_control->{Notify})) # meta-events are subject to both Notify and Log
			{
				logEvent(node => $nd, event => "Deleted Event: $ET->{$event_hash}{event}", level => $ET->{$event_hash}{level}, 
								 element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});

				my $timenow = time();
				my $message = "NMIS_Event::$C->{server_name}::$timenow,$ET->{$event_hash}{node},Deleted Event: $ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
				my $priority = eventToSyslog($ET->{$event_hash}{level});
				sendSyslog(
					server_string => $C->{syslog_server},
					facility => $C->{syslog_facility},
					message => $message,
					priority => $priority
						);
			}

			logMsg("INFO ($nd) Node not active, deleted Event=$ET->{$event_hash}{event} Element=$ET->{$event_hash}{element}");

			delete $ET->{$event_hash};
			if ( getbool($C->{db_events_sql}) ) {
				DBfunc::->delete(table=>'Events',index=>$event_hash);
			}

			my $dbgmsg = "event_hash=$event_hash nd=$nd node=$ET->{$event_hash}{node} active=$NT->{$nd}{active}";
			dbg($dbgmsg);

			next LABEL_ESC;
		}

		### 2013-08-07 keiths, taking to long when MANY interfaces e.g. > 200,000
		if ( $ET->{$event_hash}{event} =~ /interface/i
				 and $ET->{$event_hash}{event} !~ /proactive/i )
		{
			### load the interface information and check the collect status.
			my $S = Sys::->new; # node object
			if (($S->init(name=>$nd,snmp=>'false'))) { # get all info of node
				my $IFD = $S->ifDescrInfo(); # interface info indexed by ifDescr
				if ( !getbool($IFD->{$ET->{$event_hash}{element}}{collect}) ) 
				{
					# meta events are subject to both Log and Notify controls
					if (getbool($thisevent_control->{Log}) and getbool($thisevent_control->{Notify}))
					{
						logEvent(node => $ET->{$event_hash}{node}, event => "Deleted Event: $ET->{$event_hash}{event}", 
										 level => $ET->{$event_hash}{level}, 
										 element => " no matching interface or no collect Element=$ET->{$event_hash}{element}");
					}
					logMsg("INFO ($ET->{$event_hash}{node}) Interface not active, deleted Event=$ET->{$event_hash}{event} Element=$ET->{$event_hash}{element}");
					delete $ET->{$event_hash};
					if ( getbool($C->{db_events_sql}) ) {
						DBfunc::->delete(table=>'Events',index=>$event_hash);
					}
					next LABEL_ESC;
				}
			}
		}

		# if an planned outage is in force, keep writing the start time of any unack event to the current start time
		# so when the outage expires, and the event is still current, we escalate as if the event had just occured
		my ($outage,undef) = outageCheck(node=>$ET->{$event_hash}{node},time=>time());
		dbg("Outage for $ET->{$event_hash}{node} is $outage");
		if ( $outage eq "current" and getbool($ET->{$event_hash}{ack},"invert") ) {
			$ET->{$event_hash}{startdate} = time();
			if ( getbool($C->{db_events_sql}) ) {
				DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
			}
		}
		# set the current outage time
		$outage_time = time() - $ET->{$event_hash}{startdate};

		# if we are to escalate, this event must not be part of a planned outage and un-ack.
		if ( $outage ne "current" and getbool($ET->{$event_hash}{ack},"invert")) 
		{
			# we have list of nodes that this node depends on in $NT->{$runnode}{depend}
			# if any of those have a current Node Down alarm, then lets just move on with a debug message
			# should we log that we have done this - maybe not....
			
			if ( $NT->{$ET->{$event_hash}{node}}{depend} ne '') {
				foreach my $node_depend ( split /,/ , $NT->{$ET->{$event_hash}{node}}{depend} ) {
					next if $node_depend eq "N/A" ;		# default setting
					next if $node_depend eq $ET->{$event_hash}{node};	# remove the catch22 of self dependancy.
					#only do dependancy if node is active.
					if (defined $NT->{$node_depend}{active} and getbool($NT->{$node_depend}{active})) {
						my $eh = eventHash($node_depend,"Node Down","");
						if ( exists $ET->{$eh}{current} ) {
							dbg("NOT escalating $ET->{$event_hash}{node} $ET->{$event_hash}{event} as dependant $node_depend is reported as down");
							next LABEL_ESC;
						}
					}
				}
			}

			undef %keyhash;		# clear this every loop
			$escalate = $ET->{$event_hash}{escalate};	# save this as a flag

			# now depending on the event escalate the event up a level or so depending on how long it has been active
			# now would be the time to notify as to the event. node down every 15 minutes, interface down every 4 hours?
			# maybe a deccreasing run 15,30,60,2,4,etc
			# proactive events would be escalated daily
			# when escalation hits 10 they could auto delete?
			# core, distrib and access could escalate at different rates.

			# note - all sent to lowercase here to get a match
			my $NI = loadNodeInfoTable($ET->{$event_hash}{node}, suppress_errors => 1);
			$group = lc($NI->{system}{group});
			$role = lc($NI->{system}{roleType});
			$type = lc($NI->{system}{nodeType});

			# NO LONGER trim the (proactive) event down to the first 4 keywords or less.
			# see NMIS::eventHash 
			$event = lc($ET->{$event_hash}{event}); 

			dbg("looking for Event to Escalation Table match for Event[ Node:$ET->{$event_hash}{node} Event:$event Element:$ET->{$event_hash}{element} ]");
			dbg("and node values node=$NI->{system}{name} group=$group role=$role type=$type");
			# Escalation_Key=Group:Role:Type:Event
			my @keylist = (
				$group."_".$role."_".$type."_".$event ,
				$group."_".$role."_".$type."_"."default",
				$group."_".$role."_"."default"."_".$event ,
				$group."_".$role."_"."default"."_"."default",
				$group."_"."default"."_".$type."_".$event ,
				$group."_"."default"."_".$type."_"."default",
				$group."_"."default"."_"."default"."_".$event ,
				$group."_"."default"."_"."default"."_"."default",
				"default"."_".$role."_".$type."_".$event ,
				"default"."_".$role."_".$type."_"."default",
				"default"."_".$role."_"."default"."_".$event ,
				"default"."_".$role."_"."default"."_"."default",
				"default"."_"."default"."_".$type."_".$event ,
				"default"."_"."default"."_".$type."_"."default",
				"default"."_"."default"."_"."default"."_".$event ,
				"default"."_"."default"."_"."default"."_"."default"
					);

			# lets allow all possible keys to match !
			# so one event could match two or more escalation rules
			# can have specific notifies to one group, and a 'catch all' to manager for example.
			
			foreach my $klst( @keylist ) {
				foreach my $esc (keys %{$EST}) {
					my $esc_short = lc "$EST->{$esc}{Group}_$EST->{$esc}{Role}_$EST->{$esc}{Type}_$EST->{$esc}{Event}";
					
					$EST->{$esc}{Event_Node} = ($EST->{$esc}{Event_Node} eq '') ? '.*' : $EST->{$esc}{Event_Node};
					$EST->{$esc}{Event_Element} = ($EST->{$esc}{Event_Element} eq '') ? '.*' : $EST->{$esc}{Event_Element};
					$EST->{$esc}{Event_Node} =~ s;/;;g;
					$EST->{$esc}{Event_Element} =~ s;/;\\/;g;
					if ($klst eq $esc_short
							and $ET->{$event_hash}{node} =~ /$EST->{$esc}{Event_Node}/i
							and $ET->{$event_hash}{element} =~ /$EST->{$esc}{Event_Element}/i
							) {
						$keyhash{$esc} = $klst;
						dbg("match found for escalation key=$esc");
					}
					else {
						#dbg("no match found for escalation key=$esc, esc_short=$esc_short");
					}
				}
			}

			my $cnt_hash = keys %keyhash;
			dbg("$cnt_hash match(es) found for $ET->{$event_hash}{node}");

			foreach $esc_key ( keys %keyhash ) 
			{
				dbg("Matched Escalation Table Group:$EST->{$esc_key}{Group} Role:$EST->{$esc_key}{Role} Type:$EST->{$esc_key}{Type} Event:$EST->{$esc_key}{Event} Event_Node:$EST->{$esc_key}{Event_Node} Event_Element:$EST->{$esc_key}{Event_Element}");
				dbg("Pre Escalation : $ET->{$event_hash}{node} Event $ET->{$event_hash}{event} is $outage_time seconds old escalation is $ET->{$event_hash}{escalate}");

				# default escalation for events
				# 28 apr 2003 moved times to nmis.conf
				if (    $outage_time >= $C->{escalate10} ) { $ET->{$event_hash}{escalate} = 10; }
				elsif ( $outage_time >= $C->{escalate9} ) { $ET->{$event_hash}{escalate} = 9; }
				elsif ( $outage_time >= $C->{escalate8} ) { $ET->{$event_hash}{escalate} = 8; }
				elsif ( $outage_time >= $C->{escalate7} ) { $ET->{$event_hash}{escalate} = 7; }
				elsif ( $outage_time >= $C->{escalate6} ) { $ET->{$event_hash}{escalate} = 6; }
				elsif ( $outage_time >= $C->{escalate5} ) { $ET->{$event_hash}{escalate} = 5; }
				elsif ( $outage_time >= $C->{escalate4} ) { $ET->{$event_hash}{escalate} = 4; }
				elsif ( $outage_time >= $C->{escalate3} ) { $ET->{$event_hash}{escalate} = 3; }
				elsif ( $outage_time >= $C->{escalate2} ) { $ET->{$event_hash}{escalate} = 2; }
				elsif ( $outage_time >= $C->{escalate1} ) { $ET->{$event_hash}{escalate} = 1; }
				elsif ( $outage_time >= $C->{escalate0} ) { $ET->{$event_hash}{escalate} = 0; }
				
				dbg("Post Escalation: $ET->{$event_hash}{node} Event $ET->{$event_hash}{event} is $outage_time seconds old escalation is $ET->{$event_hash}{escalate}");
				if ($C->{debug} and $escalate == $ET->{$event_hash}{escalate}) {
					my $level= "Level".($ET->{$event_hash}{escalate} + 1);
					dbg("Next Notification Target would be $level");
					dbg("Contact: ".$EST->{$esc_key}{$level});
				}
				# send a new email message as the escalation again.
				# ehg 25oct02 added win32 netsend message type (requires SAMBA on this host)
				if ( $escalate != $ET->{$event_hash}{escalate} ) {
					$event_age = convertSecsHours(time - $ET->{$event_hash}{startdate});
					$time = &returnDateStamp;

					# get the string of type email:contact1:contact2,netsend:contact1:contact2,pager:contact1:contact2,email:sysContact
					$level = lc($EST->{$esc_key}{'Level'.$ET->{$event_hash}{escalate}});

					if ( $level ne "")
					{
						# Now we have a string, check for multiple notify types
						foreach $field ( split "," , $level ) {
							$target = "";
							@x = split /:/ , lc $field;
							$type = shift @x;			# first entry is email, ccopy, netsend or pager
							
							dbg("Escalation type=$type");

							if ( $type =~ /email|ccopy|pager/ ) 
							{
								foreach $contact (@x) {
									my $contactLevelSend = 0;
									my $contactDutyTime = 0;
									# if sysContact, use device syscontact as key into the contacts table hash
									if ( $contact eq "syscontact") {
										if ($NI->{sysContact} ne '') {
											$contact = lc $NI->{sysContact};
											dbg("Using node $ET->{$event_hash}{node} sysContact $NI->{sysContact}");
										} else {
											$contact = 'default';
										}
									}

									### better handling of upnotify for certain notification types.
									if ( $type !~ /email|pager/ ) {
										# check if UpNotify is true, and save with this event
										# and send all the up event notifies when the event is cleared.
										if ( getbool($EST->{$esc_key}{UpNotify}) 
												 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
												 and getbool($thisevent_control->{Notify})
										 ) {
											my $ct = "$type:$contact";
											my @l = split(',',$ET->{$event_hash}{notify});
											if (not grep { $_ eq $ct } @l ) {
												push @l, $ct;
												$ET->{$event_hash}{notify} = join(',',@l);
											}
										}
									}

									if ( exists $CT->{$contact} ) {
										if ( dutyTime($CT, $contact) ) {	# do we have a valid dutytime ??
											$contactDutyTime = 1;

											# Duty Time is OK check level match
											if ( $CT->{$contact}{Level} eq "" ) {
												dbg("SEND Contact $contact no filtering by Level defined");
												$contactLevelSend = 1;
											}
											elsif ( $ET->{$event_hash}{level} =~ /$CT->{$contact}{Level}/i ) {
												dbg("SEND Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $ET->{$event_hash}{level}");
												$contactLevelSend = 1;
											}
											elsif ( $ET->{$event_hash}{level} !~ /$CT->{$contact}{Level}/i ) {
												dbg("STOP Contact $contact filtering by Level: $CT->{$contact}{Level}, event level is $ET->{$event_hash}{level}");
												$contactLevelSend = 0;
											}
										}

										if ( $contactDutyTime and $contactLevelSend ) {
											if ($type eq "pager") {
												$target = $target ? $target.",".$CT->{$contact}{Pager} : $CT->{$contact}{Pager};
											} else {
												$target = $target ? $target.",".$CT->{$contact}{Email} : $CT->{$contact}{Email};
											}

											# check if UpNotify is true, and save with this event
											# and send all the up event notifies when the event is cleared.
											if ( getbool($EST->{$esc_key}{UpNotify}) 
													 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
													 and getbool($thisevent_control->{Notify})
												) {
												my $ct = "$type:$contact";
												my @l = split(',',$ET->{$event_hash}{notify});
												if (not grep { $_ eq $ct } @l ) {
													push @l, $ct;
													$ET->{$event_hash}{notify} = join(',',@l);
												}
											}

										}
										else {
											dbg("STOP Contact duty time: $contactDutyTime, contact level: $contactLevelSend");
										}
									}
									else {
										dbg("Contact $contact not found in Contacts table");
									}
								} #foreach

								# no email targets found, and if default contact not found, assume we are not covering 24hr dutytime in this slot, so no mail.
								# maybe the next levelx escalation field will fill in the gap
								if ( !$target ) {
									if ( $type eq "pager" ) {
										$target = $CT->{default}{Pager};
									} else {
										$target = $CT->{default}{Email};
									}
									dbg("No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target");
								}

								if ( $target ) 
								{
									foreach my $trgt ( split /,/, $target ) {
										my $message;
										my $priority;
										if ( $type eq "pager" ) 
										{
											if (getbool($thisevent_control->{Notify}))
											{
												$msgTable{$type}{$trgt}{$serial_ns}{message} = "NMIS: Esc. $ET->{$event_hash}{escalate} $event_age $ET->{$event_hash}{node} $ET->{$event_hash}{level} $ET->{$event_hash}{event} $ET->{$event_hash}{details}";
												$serial_ns++ ;
											}
										} 
										else 
										{
											if ($type eq "ccopy") {
												$message = "FOR INFORMATION ONLY\n";
												$priority = &eventToSMTPPri("Normal");
											} else {
												$priority = &eventToSMTPPri($ET->{$event_hash}{level}) ;
											}

											###2013-10-08 arturom, keiths, Added link to interface name if interface event.
											$C->{nmis_host_protocol} = "http" if $C->{nmis_host_protocol} eq "";
											$message .= "Node:\t$ET->{$event_hash}{node}\nNotification at Level$ET->{$event_hash}{escalate}\nEvent Elapsed Time:\t$event_age\nSeverity:\t$ET->{$event_hash}{level}\nEvent:\t$ET->{$event_hash}{event}\nElement:\t$ET->{$event_hash}{element}\nDetails:\t$ET->{$event_hash}{details}\nLink to Node: $C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_node_view&widget=false&node=$ET->{$event_hash}{node}\n";
											if ( $ET->{$event_hash}{event} =~ /Interface/ ) {
												my $ifIndex = undef;
												my $S = Sys::->new; # node object
												if (($S->init(name=>$ET->{$event_hash}{node},snmp=>'false'))) { # get all info of node
													my $IFD = $S->ifDescrInfo(); # interface info indexed by ifDescr
													if ( getbool($IFD->{$ET->{$event_hash}{element}}{collect}) ) {
														$ifIndex = $IFD->{$ET->{$event_hash}{element}}{ifIndex};
														$message .= "Link to Interface:\t$C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_interface_view&widget=false&node=$ET->{$event_hash}{node}&intf=$ifIndex\n";
													}
												}
											}
											$message .= "\n";

											if (getbool($thisevent_control->{Notify}))
											{
												if ( getbool($C->{mail_combine}) ) {
													$msgTable{$type}{$trgt}{$serial}{count}++;
													$msgTable{$type}{$trgt}{$serial}{subject} = "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
													$msgTable{$type}{$trgt}{$serial}{message} .= $message ;
													if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} ){
														$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
													}
												} else {
													$msgTable{$type}{$trgt}{$serial}{subject} = "$ET->{$event_hash}{node} $ET->{$event_hash}{event} - $ET->{$event_hash}{element} - $ET->{$event_hash}{details} at $msgtime" ;
													$msgTable{$type}{$trgt}{$serial}{message} = $message ;
													$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
													$msgTable{$type}{$trgt}{$serial}{count} = 1;
													$serial++;
												}
											}
										}
									}

									# meta-events are subject to Notify and Log
									logEvent(node => $ET->{$event_hash}{node}, 
													 event => "$type to $target Esc$ET->{$event_hash}{escalate} $ET->{$event_hash}{event}", 
													 level => $ET->{$event_hash}{level}, element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details})
											if (getbool($thisevent_control->{Notify}) and getbool($thisevent_control->{Log}));
										
										dbg("Escalation $type Notification node=$ET->{$event_hash}{node} target=$target level=$ET->{$event_hash}{level} event=$ET->{$event_hash}{event} element=$ET->{$event_hash}{element} details=$ET->{$event_hash}{details} group=$NT->{$ET->{$event_hash}{node}}{group}");
								} # if $target
							} # end email,ccopy,pager

							# now the netsends
							elsif ( $type eq "netsend" ) 
							{
								if (getbool($thisevent_control->{Notify}))
								{
									my $message = "Escalation $ET->{$event_hash}{escalate} $ET->{$event_hash}{node} $ET->{$event_hash}{level} $ET->{$event_hash}{event} $ET->{$event_hash}{element} $ET->{$event_hash}{details} at $msgtime";
									foreach my $trgt ( @x ) {
										$msgTable{$type}{$trgt}{$serial_ns}{message} = $message ;
										$serial_ns++;
										dbg("NetSend $message to $trgt");

										# meta-events are subject to both
										logEvent(node => $ET->{$event_hash}{node}, 
														 event => "NetSend $message to $trgt $ET->{$event_hash}{event}", 
														 level => $ET->{$event_hash}{level}, element => $ET->{$event_hash}{element}, 
														 details => $ET->{$event_hash}{details})
												if (getbool($thisevent_control->{Log}));
									} #foreach
								}
							} # end netsend
							elsif ( $type eq "syslog" ) 
							{
								# check if UpNotify is true, and save with this event
								# and send all the up event notifies when the event is cleared.
								if ( getbool($EST->{$esc_key}{UpNotify}) 
										 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
										 and getbool($thisevent_control->{Notify})
								 ) {
									my $ct = "$type:server";
									my @l = split(',',$ET->{$event_hash}{notify});
									if (not grep { $_ eq $ct } @l ) {
										push @l, $ct;
										$ET->{$event_hash}{notify} = join(',',@l);
									}
								}
								
								if (getbool($thisevent_control->{Notify}))
								{
									my $timenow = time();
									my $message = "NMIS_Event::$C->{server_name}::$timenow,$ET->{$event_hash}{node},$ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
									my $priority = eventToSyslog($ET->{$event_hash}{level});
									if ( getbool($C->{syslog_use_escalation}) ) {
										foreach my $trgt ( @x ) {
											$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
											$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
											$serial_ns++;
											dbg("syslog $message");
										} #foreach
									}
								}
							} # end syslog
							elsif ( $type eq "json" ) 
							{
								if ( getbool($EST->{$esc_key}{UpNotify}) 
										 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
										 and getbool($thisevent_control->{Notify})
								 ) {
									my $ct = "$type:server";
									my @l = split(',',$ET->{$event_hash}{notify});
									if (not grep { $_ eq $ct } @l ) {
										push @l, $ct;
										$ET->{$event_hash}{notify} = join(',',@l);
									}
								}
								# amend the event - attention: this changes the live $ET!
								my $event = $ET->{$event_hash};
								my $node = $NT->{$event->{node}};
								$event->{nmis_server} = $C->{server_name};
								$event->{customer} = $node->{customer};
								$event->{location} = $LocationsTable->{$node->{location}}{Location};
								$event->{geocode} = $LocationsTable->{$node->{location}}{Geocode};

								if ( $useServiceStatusTable ) {
									$event->{serviceStatus} = $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
									$event->{statusPriority} = $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
								}

								if ( $useBusinessServicesTable ) {
									$event->{businessService} = $BusinessServicesTable->{$node->{businessService}}{businessService};
									$event->{businessPriority} = $BusinessServicesTable->{$node->{businessService}}{businessPriority};
								}

								# Copy the fields from nodes to the event
								my @nodeFields = split(",",$C->{'json_node_fields'});
								foreach my $field (@nodeFields) {
									$event->{$field} = $node->{$field};
								}
								
								logJsonEvent(event => $event, dir => $C->{'json_logs'})
										if (getbool($thisevent_control->{Notify}));
							} # end json
							elsif (getbool($thisevent_control->{Notify})) 
							{
								if ( checkPerlLib("Notify::$type") ) {
									dbg("Notify::$type $contact");
									my $timenow = time();
									my $datenow = returnDateStamp();
									my $message = "$datenow: $ET->{$event_hash}{node}, $ET->{$event_hash}{event}, $ET->{$event_hash}{level}, $ET->{$event_hash}{element}, $ET->{$event_hash}{details}";
									foreach $contact (@x) {
										if ( exists $CT->{$contact} ) {
											if ( dutyTime($CT, $contact) ) {	# do we have a valid dutytime ??
												# check if UpNotify is true, and save with this event
												# and send all the up event notifies when the event is cleared.
												if ( getbool($EST->{$esc_key}{UpNotify})
														 and $ET->{$event_hash}{event} =~ /$C->{upnotify_stateful_events}/i
												 ) {
													my $ct = "$type:$contact";
													my @l = split(',',$ET->{$event_hash}{notify});
													if (not grep { $_ eq $ct } @l ) {
														push @l, $ct;
														$ET->{$event_hash}{notify} = join(',',@l);
													}
												}
												#$serial
												$msgTable{$type}{$contact}{$serial_ns}{message} = $message;
												$msgTable{$type}{$contact}{$serial_ns}{contact} = $CT->{$contact};
												$msgTable{$type}{$contact}{$serial_ns}{event} = $ET->{$event_hash};
												$serial_ns++;
											}
										}
										else {
											dbg("Contact $contact not found in Contacts table");
										}
									}
								}
								else {
									dbg("ERROR runEscalate problem with escalation target unknown at level$ET->{$event_hash}{escalate} $level type=$type");
								}
							}
						} # foreach field
					} # endif $level
				} # if escalate
			} # foreach esc_key
		} # end of outage check

		if ( getbool($C->{db_events_sql}) ) {
			DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
		}
	} # foreach $event_hash
	# now write the hash back and release the lock
	if ( !getbool($C->{db_events_sql}) ) {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}
	# Cologne, send the messages now
	sendMSG(data=>\%msgTable);
	dbg("Finished");
	func::update_operations_stamp(type => "escalate", start => $C->{starttime}, stop => time())
			if ($type eq "escalate");	# not if part of collect
} # end runEscalate

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

sub sendMSG {
	my %args = @_;
	my $msgTable = $args{data};
	my $C = loadConfTable(); # get ref

	my $target;
	my $serial;
	dbg("Starting");

	foreach my $method (keys %$msgTable) {
		dbg("Method $method");
		if ($method eq "email") {

			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) 
				{
					next if $C->{mail_server} eq '';

					my ($status, $code, $errmsg) = sendEmail(
					  # params for connection and sending 
						sender => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello => $C->{mail_domain},
						usetls => $C->{mail_use_tls},
						ipproto => $C->{mail_server_ipproto},
						
						username => $C->{mail_user},
						password => $C->{mail_password},

						# and params for making the message on the go
						to => $target,
						from => $C->{mail_from},
						subject => $$msgTable{$method}{$target}{$serial}{subject},
						body => $$msgTable{$method}{$target}{$serial}{message},
						priority => $$msgTable{$method}{$target}{$serial}{priority},
							);

					if (!$status)
					{
						logMsg("Error: Sending email to $target failed: $code $errmsg");
					}
					else
					{
						dbg("Escalation Email Notification sent to $target");
					}
				}
			}
		} # end email
		### Carbon copy notifications - no action required - FYI only.
		elsif ( $method eq "ccopy" ) {
			# fixme: this is slightly inefficient as the new sendEmail can send to multiple targets in one go
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					next if $C->{mail_server} eq '';

					my ($status, $code, $errmsg) = sendEmail(
					  # params for connection and sending 
						sender => $C->{mail_from},
						recipients => [$target],

						mailserver => $C->{mail_server},
						serverport => $C->{mail_server_port},
						hello => $C->{mail_domain},
						usetls => $C->{mail_use_tls},
						ipproto => $C->{mail_server_ipproto},
						
						username => $C->{mail_user},
						password => $C->{mail_password},

						# and params for making the message on the go
						to => $target,
						from => $C->{mail_from},
						subject => $$msgTable{$method}{$target}{$serial}{subject},
						body => $$msgTable{$method}{$target}{$serial}{message},
						priority => $$msgTable{$method}{$target}{$serial}{priority},
							);

					if (!$status)
					{
						logMsg("Error: Sending email to $target failed: $code $errmsg");
					}
					else
					{
						dbg("Escalation CC Email Notification sent to $target");
					}
				}
			}
		} # end ccopy
		elsif ( $method eq "netsend" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					dbg("netsend $$msgTable{$method}{$target}{$serial}{message} to $target");
					# read any stdout messages and throw them away
					if ($^O =~ /win32/i) {
						# win32 platform
						my $dump=`net send $target $$msgTable{$method}{$target}{$serial}{message}`;
					}
					else {
						# Linux box
						my $dump=`echo $$msgTable{$method}{$target}{$serial}{message}|smbclient -M $target`;
					}
				} # end netsend
			}
		}

		# now the syslog
		elsif ( $method eq "syslog" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					dbg(" sendSyslog to $target");
					sendSyslog(
						server_string => $C->{syslog_server},
						facility => $C->{syslog_facility},
						message => $$msgTable{$method}{$target}{$serial}{message},
						priority => $$msgTable{$method}{$target}{$serial}{priority}
					);
				} # end syslog
			}
		}
		# now the pagers
		elsif ( $method eq "pager" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					next if $C->{snpp_server} eq '';
					dbg(" SendSNPP to $target");
					sendSNPP(
						server => $C->{snpp_server},
						pagerno => $target,
						message => $$msgTable{$method}{$target}{$serial}{message}
					);
				}
			} # end pager
		}
		# now the extensible stuff.......
		else {

			my $class = "Notify::$method";
			my $classMethod = $class."::sendNotification";
			if ( checkPerlLib($class) ) {
				eval "require $class";
				logMsg($@) if $@;
				dbg("Using $classMethod to send notification to $$msgTable{$method}{$target}{$serial}{contact}->{Contact}");
				my $function = \&{$classMethod};
				foreach $target (keys %{$msgTable->{$method}}) {
					foreach $serial (keys %{$msgTable->{$method}{$target}}) {
						dbg("Notify method=$method, target=$target, serial=$serial message=". $$msgTable{$method}{$target}{$serial}{message});
						if ( $target and $$msgTable{$method}{$target}{$serial}{message} ) {
							$function->(
								message => $$msgTable{$method}{$target}{$serial}{message},
								event => $$msgTable{$method}{$target}{$serial}{event},
								contact => $$msgTable{$method}{$target}{$serial}{contact},
								priority => $$msgTable{$method}{$target}{$serial}{priority},
								C => $C
							);
						}
					}
				}
			}
			else {
				dbg("ERROR unknown device $method");
			}
		} # end sms
	}
	dbg("Finished");
}

#=========================================================================================

### Adding overall network metrics collection and updates
sub runMetrics {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;

	my $GT = loadGroupTable();

	my %groupSummary;
	my $data;
	my $group;
	my $status;

	dbg("Starting");

	# Doing the whole network - this defaults to -8 hours span
	my $groupSummary = getGroupSummary();
	$status = overallNodeStatus;
	$status = statusNumber($status);
	$data->{reachability}{value} = $groupSummary->{average}{reachable};
	$data->{availability}{value} = $groupSummary->{average}{available};
	$data->{responsetime}{value} = $groupSummary->{average}{response};
	$data->{health}{value} = $groupSummary->{average}{health};
	$data->{status}{value} = $status;
	$data->{intfCollect}{value} = $groupSummary->{average}{intfCollect};
	$data->{intfColUp}{value} = $groupSummary->{average}{intfColUp};
	$data->{intfAvail}{value} = $groupSummary->{average}{intfAvail};

	# RRD options
	$data->{reachability}{option} = "gauge,0:100";
	$data->{availability}{option} = "gauge,0:100";
	### 2014-03-18 keiths, setting maximum responsetime to 30 seconds.
	$data->{responsetime}{option} = "gauge,0:30000";
	$data->{health}{option} = "gauge,0:100";
	$data->{status}{option} = "gauge,0:100";
	$data->{intfCollect}{option} = "gauge,0:U";
	$data->{intfColUp}{option} = "gauge,0:U";
	$data->{intfAvail}{option} = "gauge,0:U";

	dbg("Doing Network Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}");
	
	my $db = updateRRD(data=>$data,sys=>$S,type=>"metrics",item=>'network');

	foreach $group (sort keys %{$GT}) {
		$groupSummary = getGroupSummary(group=>$group);
		$status = overallNodeStatus(group=>$group);
		$status = statusNumber($status);
		$data->{reachability}{value} = $groupSummary->{average}{reachable};
		$data->{availability}{value} = $groupSummary->{average}{available};
		$data->{responsetime}{value} = $groupSummary->{average}{response};
		$data->{health}{value} = $groupSummary->{average}{health};
		$data->{status}{value} = $status;
		$data->{intfCollect}{value} = $groupSummary->{average}{intfCollect};
		$data->{intfColUp}{value} = $groupSummary->{average}{intfColUp};
		$data->{intfAvail}{value} = $groupSummary->{average}{intfAvail};

		dbg("Doing group=$group Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}");
		#
		$db = updateRRD(data=>$data,sys=>$S,type=>"metrics",item=>$group);
	}
	dbg("Finished");
} # end runMetrics


#=========================================================================================

sub runLinks {
	my %subnets;
	my $links;
	my $C = loadConfTable();
	my $II;
	my $ipAddr;
	my $subnet;
	my $cnt;

	### 2013-08-30 keiths, restructured to avoid creating and loading large Interface summaries
	if ( getbool($C->{disable_interfaces_summary}) ) {
		logMsg("runLinks disabled with disable_interfaces_summary=$C->{disable_interfaces_summary}");
		return;
	}

	dbg("Start");

	if (!($II = loadInterfaceInfo())) {
		logMsg("ERROR reading all interface info");
		goto END_runLinks;
	}

	if ( getbool($C->{db_links_sql}) ) {
		$links = DBfunc::->select(table=>'Links');
	} else {
		$links = loadTable(dir=>'conf',name=>'Links');
	}

	my $link_ifTypes = $C->{link_ifTypes} ne '' ? $C->{link_ifTypes} : '.';
	my $qr_link_ifTypes = qr/$link_ifTypes/i;

	dbg("Auto Generating Links file");
	foreach my $intHash (sort keys %{$II}) {
		$cnt = 1;
		while (defined $II->{$intHash}{"ipSubnet$cnt"}) {
			$ipAddr = $II->{$intHash}{"ipAdEntAddr$cnt"};
			$subnet = $II->{$intHash}{"ipSubnet$cnt"};
			if ( $ipAddr ne "" and $ipAddr ne "0.0.0.0" and	$ipAddr !~ /^127/ and
					 getbool($II->{$intHash}{collect}) and $II->{$intHash}{ifType} =~ /$qr_link_ifTypes/) {
				if ( ! exists $subnets{$subnet}{subnet} ) {
					my $NI = loadNodeInfoTable($II->{$intHash}{node});
					$subnets{$subnet}{subnet} = $subnet;
					$subnets{$subnet}{address1} = $ipAddr;
					$subnets{$subnet}{count} = 1;
					$subnets{$subnet}{description} = $II->{$intHash}{Description};
					$subnets{$subnet}{mask} = $II->{$intHash}{"ipAdEntNetMask$cnt"};
					$subnets{$subnet}{ifSpeed} = $II->{$intHash}{ifSpeed};
					$subnets{$subnet}{ifType} = $II->{$intHash}{ifType};
					$subnets{$subnet}{net1} = $NI->{system}{netType};
					$subnets{$subnet}{role1} = $NI->{system}{roleType};
					$subnets{$subnet}{node1} = $II->{$intHash}{node};
					$subnets{$subnet}{ifDescr1} = $II->{$intHash}{ifDescr};
					$subnets{$subnet}{ifIndex1} = $II->{$intHash}{ifIndex};
				} else {
					++$subnets{$subnet}{count};
					if ( ! defined $subnets{$subnet}{description} ) {	# use node2 description if node1 description did not exist.
						$subnets{$subnet}{description} = $II->{$intHash}{Description};
					}
					my $NI = loadNodeInfoTable($II->{$intHash}{node});
					$subnets{$subnet}{net2} = $NI->{system}{netType};
					$subnets{$subnet}{role2} = $NI->{system}{roleType};
					$subnets{$subnet}{node2} = $II->{$intHash}{node};
					$subnets{$subnet}{ifDescr2} = $II->{$intHash}{ifDescr};
					$subnets{$subnet}{ifIndex2} = $II->{$intHash}{ifIndex};

				}
			}
			if ( $C->{debug}>2 ) {
				for my $i ( keys %{ $subnets{$subnet} } ) {
					dbg("subnets $i=$subnets{$subnet}{$i}");
				}
			}
			$cnt++;
		}
	} # foreach
	foreach my $subnet (sort keys %subnets ) {
		if ( $subnets{$subnet}{count} == 2 ) {
			# skip subnet for same node-interface in link table
			next if grep { $links->{$_}{node1} eq $subnets{$subnet}{node1} and
							$links->{$_}{ifIndex1} eq $subnets{$subnet}{ifIndex1} } keys %{$links};

			# insert entry in db if not exists
			if ( getbool($C->{db_links_sql}) ) {
				if (not exists $links->{$subnet}{subnet}) {
					DBfunc::->insert(table=>'Links',data=>{index=>$subnet});
				}
			}
			# form a key - use subnet as the unique key, same as read in, so will update any links with new information
			if ( defined $subnets{$subnet}{description} and  $subnets{$subnet}{description} ne 'noSuchObject'
				and $subnets{$subnet}{description} ne ""
				) {
				$links->{$subnet}{link} = $subnets{$subnet}{description};
			} else {
				# label the link as the subnet if no description
				$links->{$subnet}{link} = $subnet;
			}
			$links->{$subnet}{subnet} = $subnets{$subnet}{subnet};
			$links->{$subnet}{mask} = $subnets{$subnet}{mask};
			$links->{$subnet}{ifSpeed} = $subnets{$subnet}{ifSpeed};
			$links->{$subnet}{ifType} = $subnets{$subnet}{ifType};

			# define direction based on wan-lan and core-distribution-access
			my $n1 = $subnets{$subnet}{net1};
			$n1 = $n1 eq 'wan' ? 1 : $n1 eq 'lan' ? 2 : 3;
			my $n2 = $subnets{$subnet}{net2};
			$n2 = $n2 eq 'wan' ? 1 : $n2 eq 'lan' ? 2 : 3;
			my $r1 = $subnets{$subnet}{role1};
			$r1 = $r1 eq 'core' ? 1 : $r1 eq 'distribution' ? 2 : $r1 eq 'access' ? 3 :  4;
			my $r2 = $subnets{$subnet}{role2};
			$r2 = $r2 eq 'core' ? 1 : $r2 eq 'distribution' ? 2 : $r2 eq 'access' ? 3 :  4;
			my $k = 1;
			if (($n1 == $n2 and $r1 > $r2) or $n1 > $n2) { $k = 2; }

			$links->{$subnet}{net} = $subnets{$subnet}{"net$k"};
			$links->{$subnet}{role} = $subnets{$subnet}{"role$k"};

			$links->{$subnet}{node1} = $subnets{$subnet}{"node$k"};
			$links->{$subnet}{interface1} = $subnets{$subnet}{"ifDescr$k"};
			$links->{$subnet}{ifIndex1} = $subnets{$subnet}{"ifIndex$k"};
			$k = $k == 1 ? 2 : 1;
			$links->{$subnet}{node2} = $subnets{$subnet}{"node$k"};
			$links->{$subnet}{interface2} = $subnets{$subnet}{"ifDescr$k"};
			$links->{$subnet}{ifIndex2} = $subnets{$subnet}{"ifIndex$k"};
			# dont overwrite any manually configured dependancies.
			if ( !exists $links->{$subnet}{depend} ) { $links->{$subnet}{depend} = "N/A" }

			# reformat the name
		##	$links->{$subnet}{link} =~ s/ /_/g;

			if ( getbool($C->{db_links_sql}) ) {
				if (not exists $links->{$subnet}{subnet}) {
					DBfunc::->update(table=>'Links',data=>$links->{$subnet},index=>$subnet);
				}
			}
			dbg("Adding link $links->{$subnet}{link} for $subnet to links");
		}
	}
	$links = {} if !$links;
	if ( !getbool($C->{db_links_sql}) ) {
		writeTable(dir=>'conf',name=>'Links',data=>$links);
	}
	logMsg("Check table Links and update link names and other entries");

END_runLinks:
	dbg("Finished");
}


#=========================================================================================

# starts up fpingd and/or opslad
sub runDaemons {

	my $C = loadConfTable();

	dbg("Starting");

	# get process table of OS
	my @p_names;
	my $pt = new Proc::ProcessTable();
	my %pnames;
	foreach my $p (@{$pt->table}) {
		$pnames{$p->fname} = 1;
	}

	# start fast ping daemon
	if ( getbool($C->{daemon_fping_active}) ) {
		if ( ! exists $pnames{$C->{daemon_fping_filename}}) {
			if ( -x "$C->{'<nmis_bin>'}/$C->{daemon_fping_filename}" ) {
				`$C->{'<nmis_bin>'}/$C->{daemon_fping_filename} restart=true`;
				logMsg("INFO launched $C->{daemon_fping_filename} as daemon");
			} else {
				logMsg("ERROR cannot run daemon $C->{'<nmis_bin>'}/$C->{daemon_fping_filename},$!");
			}
		}
	}

	# start ipsla daemon
	if ( getbool($C->{daemon_ipsla_active}) ) {
		if ( ! exists $pnames{$C->{daemon_ipsla_filename}}) {
			if ( -x "$C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename}" ) {
				`$C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename}`;
				logMsg("INFO launched $C->{daemon_ipsla_filename} as daemon");
			} else {
				logMsg("ERROR cannot run daemon $C->{'<nmis_bin>'}/$C->{daemon_ipsla_filename},$!");
			}
		}
	}

	dbg("Finished");
}


#=========================================================================================

sub checkConfig {
	my %args = @_;
	my $change = $args{change};
	my $audit = $args{audit};

	my $ext = getExtension(dir=>'conf');

	my $checkFunc;
	my $checkType;

	# depending on our job, create dir and fix the perms! 
	# or just check and report them.
	if (getbool($change)) 
	{
		$checkFunc = sub { my ($dirname) = @_; createDir($dirname); setFileProtDirectory($dirname, 1); };
		$checkType = "Checking and Fixing";
	}
	else {
		$checkFunc = \&checkDir;
		$checkType = "Auditing and Reporting"
	}

	# check if nmis_base already oke
	if (!(-e "$C->{'<nmis_base>'}/bin/nmis.pl")) 
	{

		my $nmis_bin_dir = $FindBin::Bin; # dir of this program

		my $nmis_base = $nmis_bin_dir;
		$nmis_base =~ s/\/bin$//; # strip /bin

		my $check = 1;
		while ($check) {
			print " What is the root directory of NMIS [$nmis_base] ? ";
			my $line = <STDIN>;
			chomp $line;
			if ($line eq '') { $line = $nmis_base; }

			# check this input
			if (-e "$line/bin/nmis.pl") {
				$nmis_base = $line;
				$check = 0;
				print <<EO_TEXT;
ERROR:  It appears that the NMIS install is not complete or not in the
default location.  Check the installation guide at Opmantek.com.

What will probably fix it is if you copy the config file samples from
$nmis_base/install to $nmis_base/conf
and verify that $nmis_base/conf/Config.$ext reflects
the correct file paths.
EO_TEXT
				exit 0;
			} else {
				print " Directory $line does not exist\n";
			}
		}

		# store nmis_base in NMIS config
		my ($CC,undef) = readConfData(conf=>$nvp{conf},debug=>$nvp{debug});

		$CC->{directories}{'<nmis_base>'} = $nmis_base;

		writeConfData(data=>$CC);

		$C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug}); # reload

		print " NMIS config file $C->{configfile} updated\n\n";

	} else {
		info("\n Root directory of NMIS is $C->{'<nmis_base>'}\n");
	}

	# Do the var directories exist? if not make them and fix the perms!
	info("Config $checkType - Checking var directories, $C->{'<nmis_var>'}");
	if ($C->{'<nmis_var>'} ne '') {
		&$checkFunc("$C->{'<nmis_var>'}");
		&$checkFunc("$C->{'<nmis_var>'}/nmis_system");
		&$checkFunc("$C->{'<nmis_var>'}/nmis_system/timestamps");
	}

	# Do the log directories exist, if not make them?
	info("Config $checkType - Checking log directories, $C->{'<nmis_logs>'}");
	if ($C->{'<nmis_logs>'} ne '') {
		&$checkFunc("$C->{'<nmis_logs>'}");
		&$checkFunc("$C->{'json_logs'}");
		&$checkFunc("$C->{'config_logs'}");
	}

	# Do the conf directories exist if not make them?
	info("Config $checkType - Checking conf directories, $C->{'<nmis_conf>'}");
	if ($C->{'<nmis_conf>'} ne '') {
		&$checkFunc("$C->{'<nmis_conf>'}");
	}

	# Does the database directory exist? if not make it.
	info("Config $checkType - Checking database directories");
	if ($C->{database_root} ne '') 
	{
		&$checkFunc("$C->{database_root}");
	} else {
		print "\n Cannot create directories because database_root is not defined in NMIS config\n";
	}

	# create files
	if ( not existFile(dir=>'logs',name=>'nmis.log')) {
		open(LOG,">>$C->{'<nmis_logs>'}/nmis.log");
		close LOG;
		setFileProt("$C->{'<nmis_logs>'}/nmis.log");
	}
	else {
		checkFile("$C->{'<nmis_logs>'}/nmis.log");
	}

	if ( not existFile(dir=>'logs',name=>'auth.log')) {
		open(LOG,">>$C->{'<nmis_logs>'}/auth.log");
		close LOG;
		setFileProt("$C->{'<nmis_logs>'}/auth.log");
	}
	else {
		checkFile("$C->{'<nmis_logs>'}/auth.log");
	}

	if ( not existFile(dir=>'var',name=>'nmis-event')) {
		my ($hsh,$handle) = loadTable(dir=>'var',name=>'nmis-event');
		writeTable(dir=>'var',name=>'nmis-event',data=>$hsh);
	}
	else {
		checkFile(getFileName(file => "$C->{'<nmis_var>'}/nmis-event"));
	}

	if ( not existFile(dir=>'var',name=>'nmis-system')) {
		my ($hsh,$handle) = loadTable(dir=>'var',name=>'nmis-system');
		$hsh->{startup} = time();
		writeTable(dir=>'var',name=>'nmis-system',data=>$hsh);
	}
	else {
		checkFile(getFileName(file => "$C->{'<nmis_var>'}/nmis-system"));
	}

	if ( getbool($change) ) {
		setFileProtDirectory("$FindBin::Bin/../lib");
		setFileProtDirectory("$FindBin::Bin/../lib/NMIS");
		setFileProtDirectory($C->{'<nmis_admin>'});
		setFileProtDirectory($C->{'<nmis_bin>'});
		setFileProtDirectory($C->{'<nmis_cgi>'});
		setFileProtDirectory($C->{'<nmis_conf>'});
		setFileProtDirectory($C->{'<nmis_data>'});
		setFileProtDirectory($C->{'<nmis_logs>'});
		setFileProtDirectory($C->{'<nmis_menu>'});
		setFileProtDirectory($C->{'<nmis_models>'});
		setFileProtDirectory($C->{'<nmis_var>'});
		setFileProtDirectory($C->{'config_logs'});
		setFileProtDirectory($C->{'database_root'},"true");
		setFileProtDirectory($C->{'json_logs'});
		setFileProtDirectory($C->{'log_root'});
		setFileProtDirectory($C->{'mib_root'});
		setFileProtDirectory($C->{'report_root'});
		setFileProtDirectory($C->{'script_root'});
		setFileProtDirectory($C->{'web_root'});
	}

	if ( getbool($audit) ) {
		checkDirectoryFiles("$FindBin::Bin/../lib");
		checkDirectoryFiles("$FindBin::Bin/../lib/NMIS");
		checkDirectoryFiles($C->{'<nmis_admin>'});
		checkDirectoryFiles($C->{'<nmis_bin>'});
		checkDirectoryFiles($C->{'<nmis_cgi>'});
		checkDirectoryFiles($C->{'<nmis_conf>'});
		checkDirectoryFiles($C->{'<nmis_data>'});
		checkDirectoryFiles($C->{'<nmis_logs>'});
		checkDirectoryFiles($C->{'<nmis_menu>'});
		checkDirectoryFiles($C->{'<nmis_models>'});
		checkDirectoryFiles($C->{'<nmis_var>'});
		checkDirectoryFiles($C->{'config_logs'});
		checkDirectoryFiles($C->{'database_root'});
		checkDirectoryFiles($C->{'json_logs'});
		checkDirectoryFiles($C->{'log_root'});
		checkDirectoryFiles($C->{'mib_root'});
		checkDirectoryFiles($C->{'report_root'});
		checkDirectoryFiles($C->{'script_root'});
		checkDirectoryFiles($C->{'web_root'});
	}

	#== convert config .csv to .xxxx (hash) file format ==
	convertConfFiles();
	#==

	info(" Continue with bin/nmis.pl type=apache for configuration rules of the Apache web server\n");
}


#=========================================================================================

# two modes: default, for the root user's personal crontab
# if system=true is given, then a crontab for /etc/cron.d/XXX is printed 
# (= with the extra 'root' user column)
sub printCrontab 
{
	my $C = loadConfTable();

	dbg(" Crontab Config for NMIS for config file=$nvp{conf}",3);

	my $usercol = getbool($nvp{system})? "\troot\t" : '';

	print <<EO_TEXT;
# if you DON'T want any NMIS cron mails to go to root, 
# uncomment and adjust the next line
# MAILTO=WhoeverYouAre\@yourdomain.tld

######################################################
# NMIS8 Config
######################################################
# Run Full Statistics Collection
*/5 * * * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=collect mthread=true maxthreads=10
# ######################################################
# Optionally run a more frequent Services-only Collection
# */3 * * * * $usercol $C->{'<nmis_base>'}/bin/nmis.pl type=services mthread=true maxthreads=10
######################################################
# Run Summary Update every 2 minutes
*/2 * * * * $usercol /usr/local/nmis8/bin/nmis.pl type=summary
#####################################################
# Run the interfaces 4 times an hour with Thresholding on!!!
# if threshold_poll_cycle is set to false, then enable cron based thresholding
#*/5 * * * * $usercol nice $C->{'<nmis_base>'}/bin/nmis.pl type=threshold mthread=true maxthreads=10
######################################################
# Run the update once a day
30 20 * * * $usercol nice $C->{'<nmis_base>'}/bin/nmis.pl type=update mthread=true maxthreads=10
######################################################
# Log Rotation is now handled with /etc/logrotate.d/nmis, which 
# the installer offers to setup using install/logrotate*.conf
#
# backup configuration, models and crontabs once a day, and keep 30 backups
22 8 * * * $usercol $C->{'<nmis_base>'}/admin/config_backup.pl $C->{'<nmis_data>'}/backups 30
##################################################
# purge old files every week
0 2 * * 0 $usercol $C->{'<nmis_base>'}/admin/nmis_file_cleanup.sh $C->{'<nmis_base>'} 30
########################################
# Run the Reports Weekly Monthly Daily
# daily
0 0 * * *  $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day health
10 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day top10
30 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day outage
40 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day response
45 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day avail
50 0 * * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl day port
# weekly
0 1 * * 0  $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week health
10 1 * * 0 $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week top10
30 1 * * 0 $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week outage
40 1 * * 0 $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week response
50 1 * * 0 $usercol $C->{'<nmis_base>'}/bin/run-reports.pl week avail
# monthly
0 2 1 * *  $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month health
10 2 1 * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month top10
30 2 1 * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month outage
40 2 1 * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month response
50 2 1 * * $usercol $C->{'<nmis_base>'}/bin/run-reports.pl month avail
###########################################
EO_TEXT
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
Alias $C->{'<url_base>'}/ "$C->{web_root}/"
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

sub printApache {

	my $C = loadConfTable();

	dbg(" Apache HTTPD Config for NMIS for config file=$nvp{conf}",3);

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

Alias $C->{'<url_base>'}/ "$C->{web_root}/"
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

sub checkArgs {
	print <<EO_TEXT;
$0
NMIS Polling Engine - Network Management Information System

Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;
This is free software licensed under GNU GPL, and you are welcome to
redistribute it under certain conditions; see www.opmantek.com or email
contact\@opmantek.com

NMIS version $NMIS::VERSION

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
  [conf=<file name>]     Optional alternate configuation file in conf directory
  [node=<node name>]     Run operations on a single node;
  [group=<group name>]   Run operations on all nodes in the named group;
  [debug=true|false|0-9] default=false - Show debuging information, handy;
  [rmefile=<file name>]  RME file to import.
  [mthread=true|false]   default=false - Enable Multithreading or not;
  [mthreaddebug=true|false] default=false - Enable Multithreading debug or not;
  [maxthreads=<1..XX>]  default=2 - How many threads should nmis create;

EO_TEXT
}

#=========================================================================================

sub runThreshold {
	my $node = shift;

	# fixme: logic here, depends only on global_threshold being not equal false, so first clause should go away
	if ( getbool($C->{global_threshold}) or !getbool($C->{global_threshold},"invert") ) {
		my $node_select;
		if ($node ne "") {
			if (!($node_select = checkNodeName($node))) {
				print "\t Invalid node=$node No node of that name\n";
				exit 0;
			}
		}

		doThreshold(name=>$node_select,table=>doSummaryBuild(name=>$node_select));
	}
	else {
		dbg("Skipping runThreshold with configuration 'global_threshold' = $C->{'global_threshold'}");
	}

}

#=================================================================
#
# Build first Summary table of all nodes, we need this info for Threshold too
#
sub doSummaryBuild {
	my %args = @_;
	my $node = $args{name};

	dbg("Start of Summary Build");

	my $S = Sys::->new; # node object
	my $NT = loadLocalNodeTable();
	my $NI;
	my $IF;
	my $M;
	my %stshlth;
	my %stats;
	my %stsintf;

	foreach my $nd (sort keys %{$NT}) {
		next if $node ne "" and $node ne $nd;
		if ( getbool($NT->{$nd}{active}) and getbool($NT->{$nd}{collect})) {
			if (($S->init(name=>$nd,snmp=>'false'))) { # get all info of node
				$M = $S->mdl; # model ref
				$NI = $S->ndinfo; # node info
				$IF = $S->ifinfo; # interface info

				next if getbool($NI->{system}{nodedown});

				foreach my $tp (keys %{$M->{summary}{statstype}}) { # oke, look for requests in summary of Model
					### 2013-09-16 keiths, User defined threshold periods.
					
					next if (!exists $M->{system}->{rrd}->{$tp}->{threshold});
					
					my $threshold_period = "-15 minutes";
					if ( $C->{"threshold_period-default"} ne "" ) {
						$threshold_period = $C->{"threshold_period-default"};
					}

					if ( exists $C->{"threshold_period-$tp"} and $C->{"threshold_period-$tp"} ne "" ) {
						$threshold_period = $C->{"threshold_period-$tp"};
						dbg("Found Configured Threshold for $tp, changing to \"$threshold_period\"");
					}
					# check whether this is an indexed section, ie. whether there are multiple instances with
					# their own indices
					my @instances = $S->getTypeInstances(graphtype => $tp, section => $tp);
					if (@instances)
					{
						foreach my $i (@instances) {
							my $sts = getSummaryStats(sys=>$S,type=>$tp,start=>$threshold_period,end=>'now',index=>$i);
							# save all info in %sts for threshold run
							foreach (keys %{$sts->{$i}}) { $stats{$nd}{$tp}{$i}{$_} = $sts->{$i}{$_}; }
							#
							foreach my $nm (keys %{$M->{summary}{statstype}{$tp}{sumname}}) {
								$stshlth{$NI->{system}{nodeType}}{$nd}{$nm}{$i}{Description} = $NI->{label}{$tp}{$i}; # descr
								# check if threshold level available, thresholdname must be equal to type
								if (exists $M->{threshold}{name}{$tp}) {
									($stshlth{$NI->{system}{nodeType}}{$nd}{$nm}{$i}{level},undef,undef) =
										getThresholdLevel(sys=>$S,thrname=>$tp,stats=>$sts,index=>$i);
								}
								# save values
								foreach my $stsname (@{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}}) {
									$stshlth{$NI->{system}{nodeType}}{$nd}{$nm}{$i}{$stsname} = $sts->{$i}{$stsname};
									dbg("stored summary health node=$nd type=$tp name=$stsname index=$i value=$sts->{$i}{$stsname}");
								}
							}
						}
					} 
					else 
					{
						my $dbname = $S->getDBName(graphtype => $tp);
						if ($dbname && -r $dbname)
						{
							my $sts = getSummaryStats(sys=>$S,type=>$tp,start=>$threshold_period,end=>'now');
							# save all info in %sts for threshold run
							foreach (keys %{$sts}) { $stats{$nd}{$tp}{$_} = $sts->{$_}; }
							# check if threshold level available, thresholdname must be equal to type
							if (exists $M->{threshold}{name}{$tp}) {
								($stshlth{$NI->{system}{nodeType}}{$nd}{"${tp}_level"},undef,undef) =
									getThresholdLevel(sys=>$S,thrname=>$tp,stats=>$sts,index=>'');
							}
							foreach my $nm (keys %{$M->{summary}{statstype}{$tp}{sumname}}) {
								foreach my $stsname (@{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}}) {
									$stshlth{$NI->{system}{nodeType}}{$nd}{$stsname} = $sts->{$stsname};
									dbg("stored summary health node=$nd type=$tp name=$stsname value=$sts->{$stsname}");
								}
							}
						}
					}
				}
				### 2013-09-16 keiths, User defined threshold periods.
				my $threshold_period = "-15 minutes";
				if ( $C->{"threshold_period-default"} ne "" ) {
					$threshold_period = $C->{"threshold_period-default"};
				}

				my $tp = "interface";
				if ( exists $C->{"threshold_period-$tp"} and $C->{"threshold_period-$tp"} ne "" ) {
					$threshold_period = $C->{"threshold_period-$tp"};
					dbg("Found Configured Threshold for $tp, changing to \"$threshold_period\"");
				}

				# get all collected interfaces
				foreach my $index (keys %{$IF}) {
					next unless getbool($IF->{$index}{collect});
					my $sts = getSummaryStats(sys=>$S,type=>$tp,start=>$threshold_period,end=>time(),index=>$index);
					foreach (keys %{$sts->{$index}}) { $stats{$nd}{interface}{$index}{$_} = $sts->{$index}{$_}; } # save for threshold
					foreach (keys %{$sts->{$index}}) {
						$stsintf{"${index}.$S->{name}"}{inputUtil} = $sts->{$index}{inputUtil};
						$stsintf{"${index}.$S->{name}"}{outputUtil} = $sts->{$index}{outputUtil};
						$stsintf{"${index}.$S->{name}"}{availability} = $sts->{$index}{availability};
						$stsintf{"${index}.$S->{name}"}{totalUtil} = $sts->{$index}{totalUtil};
						$stsintf{"${index}.$S->{name}"}{Description} = $IF->{$index}{Description};
					}
				}
			}
		}
	}
	writeTable(dir=>'var',name=>"nmis-summaryintf15m",data=>\%stsintf);
	writeTable(dir=>'var',name=>"nmis-summaryhealth15m",data=>\%stshlth);
	writeTable(dir=>'var',name=>"nmis-summarystats15m",data=>\%stats) if $C->{debug};
	dbg("Finished");
	return \%stats; # input for threshold process
}

#============================================================================
#
sub doThreshold {
	my %args = @_;
	my $name = $args{name};
	my $sts = $args{table}; # pointer to data build by doSummaryBuild

	dbg("Starting");
	func::update_operations_stamp(type => "threshold", start => $C->{starttime}, stop => undef)
			if ($type eq "threshold");	# not if part of collect

	my $NT = loadLocalNodeTable();
	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql

	my $S = Sys::->new; # create system object

	$S->{ET} = loadEventStateNoLock(); # for speeding up, from file or DB

	foreach my $nd (sort keys %{$NT}) {
		next if $node ne "" and $node ne lc($nd); # check for single node thresholds
		### 2012-09-03 keiths, changing as pingonly nodes not being thresholded, found by Lenir Santiago
		#if ($NT->{$nd}{active} eq 'true' and $NT->{$nd}{collect} eq 'true' and $NT->{$nd}{threshold} eq 'true') {
		if ( getbool($NT->{$nd}{active}) and getbool($NT->{$nd}{threshold}) ) {
			if (($S->init(name=>$nd,snmp=>'false'))) { # get all info of node
				my $NI = $S->ndinfo; # pointer to node info table
				my $M  = $S->mdl;	# pointer to Model table
				my $IF = $S->ifinfo;


				# skip if node down
				if ( getbool($NI->{system}{nodedown}) ) {
					info("Node down, skipping thresholding for $S->{name}");
					next;
				}

				info("Starting Thresholding node=$S->{name}");

				# first the standard thresholds
				my $thrname = 'response,reachable,available';
				runThrHld(sys=>$S,table=>$sts,type=>'health',thrname=>$thrname);

				# search for threshold names in Model of this node
				foreach my $s (keys %{$M}) { # section name
					foreach my $ts (keys %{$M->{$s}}) { # type of store
						if ($ts eq 'rrd') { 									# thresholds only in RRD subsection
							foreach my $type (keys %{$M->{$s}{$ts}}) { 			# name/type of subsection
								my $control = $M->{$s}{$ts}{$type}{control}; 	# check if skipped by control
								if ($control ne "") {
									dbg("control found:$control for s=$s ts=$ts type=$type",1);
									if ($S->parseString(string=>"($control) ? 1:0", sect => $ts, index => ) ne "1") {
										dbg("threshold of type $type skipped by control=$control");
										next;
									}
								}
								if ($M->{$s}{$ts}{$type}{threshold} ne "") {
									$thrname = $M->{$s}{$ts}{$type}{threshold};	# get string of threshold names
									dbg("threshold=$thrname found in type=$type");
									# thresholds found in this section
									if ( getbool($M->{$s}{$ts}{$type}{indexed}) ) {	# if indexed then all checked

										my @instances = $S->getTypeInstances(graphtype => $type, section => $type);
										for my $index (@instances) {
											# thresholds can be selectively disabled for individual interfaces
											if (defined $NI->{$type} and defined $NI->{$type}{$index}
													and defined $NI->{$type}{$index}{threshold}
													and getbool($NI->{$type}{$index}{threshold},"invert"))
											{
													dbg("skipping disabled threshold type $type for index $index");
													next;
											}
											runThrHld(sys=>$S,table=>$sts,type=>$type,thrname=>$thrname,index=>$index);
										}
									} else {
										runThrHld(sys=>$S,table=>$sts,type=>$type,thrname=>$thrname); # single
									}
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
				my $count = 0;
				my $countOk = 0;
				foreach my $statusKey (sort keys %{$S->{info}{status}}) {			
					my $eventKey = $S->{info}{status}{$statusKey}{event}; 
					$eventKey = "Alert: $S->{info}{status}{$statusKey}{event}" if $S->{info}{status}{$statusKey}{method} eq "Alert";
					
					# event control is as configured or all true.
					my $thisevent_control = $events_config->{$eventKey} || { Log => "true", Notify => "true", Status => "true"};

					# if this is an alert and it is older than 1 full poll cycle, delete it from status.
					if ( $S->{info}{status}{$statusKey}{updated} < time - 500) {
						delete $S->{info}{status}{$statusKey};
					}
					# in case of Status being off for this event, we don't have to include it in the calculations
					elsif (not getbool($thisevent_control->{Status}) ) {
						dbg("Status Summary Ignoring: event=$S->{info}{status}{$statusKey}{event}, Status=$thisevent_control->{Status}",1);
						$S->{info}{status}{$statusKey}{status} = "ignored";
						++$count;
						++$countOk;
					}
					else {	
						++$count;
						if ( $S->{info}{status}{$statusKey}{status} eq "ok" ) {
							++$countOk;
						}
					}
				}
				if ( $count and $countOk ) {
					my $perOk = sprintf("%.2f",$countOk/$count * 100);
					info("Status Summary = $perOk, $count, $countOk\n");
					$NI->{system}{status_summary} = $perOk;
					$NI->{system}{status_updated} = time();

					# cache the current nodestatus for use in the dash
					my $nodestatus = nodeStatus(NI => $NI);
					if ( not $nodestatus ) {
						$NI->{system}{nodestatus} = "unreachable";
					}
					elsif ( $nodestatus == -1 ) {
						$NI->{system}{nodestatus} = "degraded";
					}
					else {
						$NI->{system}{nodestatus} = "reachable";
					}
				}

				#print Dumper $S;
				# Save the new status results
				$S->writeNodeInfo();

			}
		}
	}
	$S->{ET} = ''; # done
	dbg("Finished");
	func::update_operations_stamp(type => "threshold", start => $C->{starttime}, stop => time())
			if ($type eq "threshold");	# not if part of collect
}

sub runThrHld {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $IF = $S->ifinfo;
	my $ET = $S->{info}{env_temp};

	my $sts = $args{table};
	my $type = $args{type};
	my $thrname = $args{thrname};
	my $index = $args{index};
	my $stats;
	my $element;

	my $threshold_period = "-15 minutes";
	if ( $C->{"threshold_period-default"} ne "" ) {
		$threshold_period = $C->{"threshold_period-default"};
	}
	### 2013-09-16 keiths, User defined threshold periods.
	if ( exists $C->{"threshold_period-$type"} and $C->{"threshold_period-$type"} ne "" ) {
		$threshold_period = $C->{"threshold_period-$type"};
		dbg("Found Configured Threshold for $type, changing to \"$threshold_period\"");
	}

	#	check if values are already in table (done by doSummaryBuild)
	if (exists $sts->{$S->{name}}{$type}) {
		$stats = $sts->{$S->{name}}{$type};
	} else {
		$stats = getSummaryStats(sys=>$S,type=>$type,start=>$threshold_period,end=>'now',index=>$index);
	}

	# get name of element
	if ($index eq '') {
		$element = '';
	}
	elsif ($index ne '' and $thrname eq "env_temp" ) {
		$element = $ET->{$index}{tempDescr};
	}
	elsif ( defined $IF->{$index}{ifDescr} and $IF->{$index}{ifDescr} ne "" ) {
		$element = $IF->{$index}{ifDescr};
	}
	#else {
	#	$element = $IF->{$index}{ifDescr};
	#}

	# walk through threshold names
	### 2012-04-25 keiths, fixing loop as not processing correctly.
	$thrname = stripSpaces($thrname);
	my @nm_list = split(/,/,$thrname);
	foreach my $nm (@nm_list) {
		dbg("processing threshold $nm");
		my ($level,$value,$thrvalue,$reset) = getThresholdLevel(sys=>$S,thrname=>$nm,stats=>$stats,index=>$index);
		# get 'Proactive ....' string of Model
		my $event = $S->parseString(string=>$M->{threshold}{name}{$nm}{event},index=>$index);

		my $details = "";
		my $spacer = "";
		
		if ( $type =~ /interface|pkts/ and $IF->{$index}{Description} ne "" )
		{
			$details = $IF->{$index}{Description};
			$spacer = " ";
		}
				
		### 2014-08-27 keiths, display human speed and handle ifSpeedIn and ifSpeedOut
		if ( getbool($C->{global_events_bandwidth}) and $type =~ /interface|pkts/ and $IF->{$index}{ifSpeed} ne "")
		{
			my $ifSpeed = $IF->{$index}->{ifSpeed};
																			
			if ( $event =~ /Input/ and exists $IF->{$index}{ifSpeedIn} and $IF->{$index}{ifSpeedIn} ) {
				$ifSpeed = $IF->{$index}->{ifSpeedIn};
			}
			elsif ( $event =~ /Output/ and exists $IF->{$index}{ifSpeedOut} and $IF->{$index}{ifSpeedOut} ) {
				$ifSpeed = $IF->{$index}->{ifSpeedOut};
			}			
			$details .= $spacer."Bandwidth=".convertIfSpeed($ifSpeed);
		}
		
		thresholdProcess(sys=>$S,type=>$type,event=>$event,level=>$level,element=>$element,details=>$details,value=>$value,thrvalue=>$thrvalue,reset=>$reset,thrname=>$nm,index=>$index);
	}

}

sub getThresholdLevel {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M  = $S->mdl;

	my $thrname = $args{thrname};
	my $stats = $args{stats}; # value of items
	my $index = $args{index};

	my $val;
	my $level;
	my $thrvalue;

	dbg("Start theshold=$thrname, index=$index");

	# find subsection with threshold values in Model
	my $T = $M->{threshold}{name}{$thrname}{select};
	foreach my $thr (keys %{$T}) {
		next if $thr eq 'default'; # skip now the default values
		if (($S->parseString(string=>"($T->{$thr}{control})?1:0",index=>$index))){
			$val = $T->{$thr}{value};
			dbg("found threshold=$thrname entry=$thr");
			last;
		}
	}
	# if not found and there are default values available get this now
	if ($val eq "" and $T->{default}{value} ne "") {
		$val = $T->{default}{value};
			dbg("found threshold=$thrname entry=default");
	}
	if ($val eq "") {
		logMsg("ERROR, no threshold=$thrname entry found in Model=$NI->{system}{nodeModel}");
		return;
	}

	my $value; # value of doSummary()
	my $reset = 0;
	# item is the attribute name of summary stats of Model
	$value = $stats->{$M->{threshold}{name}{$thrname}{item}} if $index eq "";
	$value = $stats->{$index}{$M->{threshold}{name}{$thrname}{item}} if $index ne "";
	dbg("threshold=$thrname, item=$M->{threshold}{name}{$thrname}{item}, value=$value");

	# check unknow value
	if ($value =~ /NaN/i) {
		dbg("INFO, illegal value $value, skipped");
		return ("Normal",$value,$reset);
	}

	### all zeros policy to disable thresholding - match and return 'normal'
	if ( $val->{warning} == 0
			and $val->{minor} == 0
			and $val->{major} == 0
			and $val->{critical} == 0
			and $val->{fatal} == 0
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal}) {
		return ("Normal",$value,$reset);
	}

	# Thresholds for higher being good and lower bad
	if ( $val->{warning} > $val->{fatal}
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal} ) {
		if ( $value <= $val->{fatal} ) { $level = "Fatal"; $thrvalue = $val->{fatal};}
		elsif ( $value <= $val->{critical} and $value > $val->{fatal} ) { $level = "Critical"; $thrvalue = $val->{critical};}
		elsif ( $value <= $val->{major} and $value > $val->{critical} ) { $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value <= $val->{minor} and $value > $val->{major} ) { $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value <= $val->{warning} and $value > $val->{minor} ) { $level = "Warning"; $thrvalue = $val->{warning}; }
		elsif ( $value > $val->{warning} ) { $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
	}
	# Thresholds for lower being good and higher being bad
	elsif ( $val->{warning} < $val->{fatal}
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal} ) {
		if ( $value < $val->{warning} ) { $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
		elsif ( $value >= $val->{warning} and $value < $val->{minor} ) { $level = "Warning"; $thrvalue = $val->{warning}; }
		elsif ( $value >= $val->{minor} and $value < $val->{major} ) { $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value >= $val->{major} and $value < $val->{critical} ) { $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value >= $val->{critical} and $value < $val->{fatal} ) { $level = "Critical"; $thrvalue = $val->{critical}; }
		elsif ( $value >= $val->{fatal} ) { $level = "Fatal"; $thrvalue = $val->{fatal}; }
	}
	if ( $level eq "") {
		logMsg("ERROR no policy found, threshold=$thrname, value=$value, node=$S->{name}, model=$NI->{system}{nodeModel} section threshold");
		$level = "Normal";
	}
	dbg("result threshold=$thrname, level=$level, value=$value, thrvalue=$thrvalue, reset=$reset");
	return ($level,$value,$thrvalue,$reset);
}

sub thresholdProcess {
	my %args = @_;
	my $S = $args{sys};

	if ( $args{value} =~ /^\d+$|^\d+\.\d+$/ ) {
		info("$args{event}, $args{level}, $args{element}, value=$args{value} reset=$args{reset}");
	###	logMsg("INFO ($S->{node}) event=$args{event}, level=$args{level}, element=$args{element}, value=$args{value}, reset=$args{reset}");
		if ( $args{value} !~ /NaN/i ) {
			my $details = "Value=$args{value} Threshold=$args{thrvalue}";
			if ( defined $args{details} and $args{details} ne "" ) {
				$details = "$args{details}: Value=$args{value} Threshold=$args{thrvalue}";
			}
			my $statusResult = "ok";
			if ( $args{level} =~ /Normal/i ) {
				checkEvent(sys=>$S,event=>$args{event},level=>$args{level},element=>$args{element},details=>$details,value=>$args{value},reset=>$args{reset});
			}
			else {
				notify(sys=>$S,event=>$args{event},level=>$args{level},element=>$args{element},details=>$details);
				$statusResult = "error";
			}
			my $index = $args{index};
			if ( $index eq "" ) {
				$index = 0;
			}
			my $statusKey = "$args{thrname}--$index";
			$S->{info}{status}{$statusKey} = {
				method => "Threshold",
				type => $args{type},
				property => $args{thrname},
				event => $args{event},
				index => $args{index},
				level => $args{level},
				status => $statusResult,
				element => $args{element},
				value => $args{value},
				updated => time()
			}
		}
	}
}

# az [2014-11-17 Mon 15:23]: this can be removed as we now use the process table
# to keep track of our processes
sub getPidFileName {
	my $PIDFILE = "$C->{'<nmis_var>'}/nmis.pid";
	if ($C->{conf} ne "") {
		$PIDFILE = "$C->{'<nmis_var>'}/nmis-$C->{conf}.pid";
	}
	return $PIDFILE;
}


sub printRunTime {
	my $endTime = time() - $C->{starttime};
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
	my $NT = loadLocalNodeTable(); 	# only local nodes
	dbg("table Local Node loaded",2);

	# reread the config with a lock and unflattened
	my $fn = $C->{'<nmis_conf>'}."/".($nvp{conf}||"Config").".nmis";
	my ($rawC,$fh) = readFiletoHash(file => $fn, lock => 'true');
	
	return "Error: failed to read config $fn!" if (!$rawC or !keys %$rawC);

	my %oldgroups = map { $_ => 1 } (split(/\s*,\s*/, $rawC->{system}->{group_list}));
	my %newgroups;
	for my $node (keys %$NT)
	{
		my $thisgroup = $NT->{$node}->{group};
		next if ($oldgroups{$thisgroup});
		++$newgroups{$thisgroup};
	}

	print "Existing groups:\n\t", (%oldgroups? join("\n\t",keys %oldgroups) : "<None>"),
	"\n\nNew groups to add:\n\t", (%newgroups? join("\n\t", keys %newgroups) : "<None>"),
	"\n\n";

	if (%newgroups)
	{
		$rawC->{system}->{group_list} = join(",", sort(keys %oldgroups, keys %newgroups));
		writeHashtoFile(file => $fn, handle => $fh, data => $rawC);
	}
	else
	{
		close $fh;
	}
	
	return undef;
}


# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************

