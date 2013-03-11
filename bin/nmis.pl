#!/usr/bin/perl
#
## $Id: nmis.pl,v 8.52 2012/12/03 07:47:26 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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
require 5.008_000;

use Time::HiRes;
use strict;
use csv;				# local
use rrdfunc; 			# createRRD, updateRRD etc.
use NMIS;				# local
use NMIS::Connect;
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

Data::Dumper->import();
$Data::Dumper::Indent = 1;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Errno qw(EAGAIN ESRCH EPERM);

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

# check for global collection off or on 
# useful for disabling nmis poll for server maintenance
if ($C->{global_collect} eq "false") { print "\n!!Global Collect set to false !!\n"; exit(0); }

# all arguments are now stored in nvp (name value pairs)
my $type		= lc $nvp{type};
my $node		= lc $nvp{node};
my $rmefile		= $nvp{rmefile};
my $runGroup	= $nvp{group};

### 2012-12-03 keiths, adding some model testing and debugging options.
my $model		= lc $nvp{model};
if ( $model =~ /true|1/ ) {
	$model = 1;
}

# store multithreading arguments in nvp
my $mthread		=$nvp{mthread};
my $mthreadDebug=$nvp{mthreaddebug};
my $maxThreads	=$nvp{maxthreads}||1;

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
NMIS Copyright (C) 1999-2011 Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;
This is free software licensed under GNU GPL, and you are welcome to 
redistribute it under certain conditions; see www.opmantek.com or email
contact\@opmantek.com

NMIS version $NMIS::VERSION

/ if $C->{debug};


if ($type =~ /collect|update/) {
	runThreads(type=>$type,node=>$node,mthread=>$mthread,mthreadDebug=>$mthreadDebug);
}
elsif ( $type eq "escalate") { runEscalate(); } # included in type=collect
elsif ( $type eq "config" ) { checkConfig(); }
elsif ( $type eq "links" ) { runLinks(); } # included in type=update
elsif ( $type eq "apache" ) { printApache(); }
elsif ( $type eq "crontab" ) { printCrontab(); }
elsif ( $type eq "summary" ) { nmisSummary(); } # included in type=collect
elsif ( $type eq "rme" ) { loadRMENodes($rmefile); }
elsif ( $type eq "threshold" ) { runThreshold($node); } # included in type=collect
elsif ( $type eq "master" ) { nmisMaster(); } # included in type=collect
else { checkArgs(); }

exit;

#=========================================================================================

sub	runThreads {
	my %args = @_;
	my $type = $args{type};
	my $node_select = $args{'node'};
	my $mthread = getbool($args{mthread});
	my $mthreadDebug = getbool($args{mthreadDebug});
	my $debug_watch;

	dbg("Starting");

	# load all the files we need here
	loadEnterpriseTable() if $type eq 'update'; # load in cache
	dbg("table Enterprise loaded",2);

	loadNodeConfTable(); # load in cache
	dbg("table Node Config loaded",2);

	if ($C->{db_events_sql} ne 'true') {
		loadEventStateNoLock(); # load in cache
		dbg("table Event loaded",2);
	}

	my $NT = loadLocalNodeTable(); 	# only local nodes
	dbg("table Local Node loaded",2);

	my $C = loadConfTable();		# config table from cache

	if ($C->{daemon_fping_active} eq 'true') {
		my $pt = loadTable(dir=>'var',name=>'nmis-fping'); # load fping table in cache
		my $nt = loadNodeConfTable();
		my $cnt_pt = keys %{$pt};
		my $cnt_nt = keys %{$nt};
		# missing more then 10 entries ?
		if ($cnt_pt+10 < $cnt_nt) {
			logMsg("ERROR fping table missing to many entries, count fping=$cnt_pt count nodes=$cnt_nt");
			$C->{deamon_fping_failed} = 'true'; # remember for runPing
		}
	}

	dbg("tables loaded");

	my $debug_global = $C->{debug};
	my $debug = $C->{debug};
	my $PIDFILE;
	my $pid;

	# used for plotting major events on world map in 'Current Events' display
	$C->{netDNS} = 0;
	if ( $C->{DNSLoc} eq "true" ) {
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
	### not for updates - they can run past 5 mins
	### collects should not run past 5mins - if they do we have a problem
	###

	if ( $type eq 'collect' and !$debug and !$mthreadDebug ) {
		
		$PIDFILE = getPidFileName();
				
		if (-f $PIDFILE) {
			open(F, "<",$PIDFILE);
			$pid = <F>;
			close(F);
			chomp $pid;
			if ($pid != $$) {
				print "Error: nmis.pl, previous pidfile exists, killing the process $pid check your process run-time\n";
				logMsg("ERROR previous pidfile exists, killing the process $pid check your process run-time");
				kill 15, $pid;
				unlink($PIDFILE);
				dbg("pidfile $PIDFILE deleted");
			}
		}
		# Announce our presence via a PID file
		open(PID, ">",$PIDFILE) or warn "\t Could not create $PIDFILE: $!\n";
		print PID $$ or warn "\t Could not write: $!\n"; close(PID);
		print "\t pidfile $PIDFILE created\n" if $debug;
	
		# Perform a sanity check. If the current PID file is not the same as
		# our PID then we have become detached somehow, so just exit
		open(PID, "<$PIDFILE") or warn "\t Could not open $PIDFILE: $!\n";
		$pid = <PID>; close(PID);
		chomp $pid;
		if ( $pid != $$ ) {
			print "\t pid $pid != $$, we have detached somehow - exiting\n";
			goto END_runThreads;
		}
	}

	# setup a trap for fatal signals.
	$SIG{INT} =  \&catch_zap;
	$SIG{TERM} =  \&catch_zap;
	$SIG{HUP} = \&catch_zap;

	my $nodecount = 0;

	# select the method we will run
	local *meth;
	if ($type eq "update") {
		*meth = \&doUpdate;
		logMsg("INFO start of update process");
	} else {
		*meth = \&doCollect;
	}

	if ($node_select eq "") {
		# multithreading
		# sorting the nodes so we get consistent polling cycles
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
				if ( $NT->{$onenode}{active} eq 'true') {
					++$nodecount;
					# One thread for each node until maxThreads is reached.
					# This loop is entered only if the commandlinevariable mthread=true is used!
					if ($mthread) {
						my $pid=fork;
						if ( defined ($pid) and $pid==0) {
		
							# this will be run only by the child
							if ($mthreadDebug) {
								print "CHILD $$-> I am a CHILD with the PID $$ processing $onenode\n";
							}
							# lets change our name, so a ps will report who we are
							$0 = "nmis.pl.$type.$onenode";
		
							meth(name=>$onenode);
		
							# all the work in this thread is done now this child will die.
		
							if ($mthreadDebug) {
								print "CHILD $$-> $onenode will now exit\n";
							}
		
							# killing child
							exit 0;
						} # end of child
		
						# Father is forced to wait here unless number of childs is less than maxthreads.

					# will be run if mthread is false (no multithreading)
					} else {
						meth(name=>$onenode); 
					}
				} #if active
				else {
					 dbg("Skipping as $onenode is marked 'inactive'");
				}
			} #if runGroup
		} # foreach $onenode

		# only do the cleanup if we have mthread enabled 
		if ($mthread) {
			# cleanup
			# wait this will block until childs done
			1 while wait != -1;
		}
	} else {
		if ( (my $node = checkNodeName($node_select))) { # ignore lc & uc
			if ( $NT->{$node}{active} eq 'true') {
				++$nodecount;
				meth(name=>$node);
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

	dbg("### continue normally ###");

	if ($C->{debug} == 1) {
		dbg("=== debug output suppressed with debug=1 ===");
		$C->{debug} = 0;
	}

	$C->{collecttime} = time();

	# if an update, 
	if ( $type eq "update" ) { 
		getIntfAllInfo(); # concatencate all the interface info in <nmis_var>/nmis-interfaces.nmis
		getNodeAllInfo(); # store node info in <nmis_var>/nmis-nodeinfo.nmis
		runLinks();
	}

	# Couple of post processing things.
	### 2012-04-25 keiths, skipping extra processing if running onenode!
	if ( $type eq "collect" and $node_select eq "" ) {
		my $S = Sys::->new; # object nmis-system
		$S->init();
		my $NI = $S->ndinfo;
		delete $NI->{graphtype}; # rebuild at node nmis-system
		delete $NI->{database};
		
		### 2011-12-29 keiths, adding a general purpose master control thing, run reliably every poll cycle.
		dbg("Starting nmisMaster");
		nmisMaster() if getbool($C->{server_master});	# do some masterly type things.

		if ( $C->{'nmis_summary_poll_cycle'} eq "true" or $C->{'nmis_summary_poll_cycle'} ne "false" ) {
			dbg("Starting nmisSummary");
			nmisSummary() if getbool($C->{cache_summary_tables});	# calculate and cache the summary stats
		}
		else {
			dbg("Skipping nmisSummary with configuration 'nmis_summary_poll_cycle' = $C->{'nmis_summary_poll_cycle'}");
		}

		dbg("Starting runMetrics");
		runMetrics(sys=>$S); 

		### 2013-02-22 keiths, disable thresholding on the poll cycle only.
		if ( $C->{threshold_poll_cycle} eq "true" or $C->{threshold_poll_cycle} ne "false" ) {
			dbg("Starting runThreshold");
			runThreshold($node_select);
		}
		else {
			dbg("Skipping runThreshold with configuration 'threshold_poll_cycle' = $C->{'threshold_poll_cycle'}");
		}

		dbg("Starting runEscalate");
		runEscalate();
		
		# optional post processing routines
		if ( -r "$C->{'<nmis_base>'}/bin/nmis_post_proc.pl") {
			require "$C->{'<nmis_base>'}/bin/nmis_post_proc.pl";
			dbg("start of post processing package");
			if (!pp::doPP()) {
				logMsg("ERROR running post processing routine");
			}
		}
		# nmis collect runtime and save
		my $D;
		$D->{collect}{value} = $C->{collecttime} - $C->{starttime};
		$D->{collect}{option} = 'gauge,0:1200';
		$D->{total}{value} = time() - $C->{starttime};
		$D->{total}{option} = 'gauge,0:1200';
		if (( my $db = updateRRD(data=>$D,sys=>$S,type=>"nmis"))) {
			$NI->{database}{nmis} = $db;
			$NI->{graphtype}{nmis} = 'nmis';
		}
		$S->writeNodeInfo; # var/nmis-system.nmis, the base info system
		#
	}

	if ( $type eq "update" ) {
		logMsg("INFO end of update process");
	}

	if ($debug or $mthreadDebug) {
		my $endTime = time() - $C->{starttime};
		print "\n".returnTime ." End of $0 Processed $nodecount nodes ran for $endTime seconds.\n\n";
	}

END_runThreads:
	if ( $type eq 'collect' and !$debug and !$mthreadDebug) {
		unlink($PIDFILE);
		dbg("pidfile $PIDFILE deleted");
	}
	dbg("Finished");
	return;
}

#==============

sub catch_zap {
	my $rs = $_[0];
	my $PIDFILE = getPidFileName();
	logMsg("INFO I (nmis.pl conf=$C->{conf}) was killed by $rs");
	unlink $PIDFILE if (-f $PIDFILE);
	die "I (nmis.pl conf=$C->{conf}) was killed by $rs\n";
}



#====================================================================================

sub doUpdate {
	my %args = @_;
	my $name = $args{name};
	my $C = loadConfTable();

	dbg("================================");
	dbg("Starting, node $name");

	my $S = Sys::->new; # create system object
	$S->init(name=>$name,update=>'true'); # load old node info
	# nmisdev Apr2011 Copy all to catch problem with nodeType coming through blank
	$S->copyModelCfgInfo(type=>'all');					# copy standard/running model info in node info table
	my $NI = $S->ndinfo;
	my $NC = $S->ndcfg;
	$S->{doupdate} = 'true'; # flag what is running
	$S->readNodeView; # from prev. run  
	if (runPing(sys=>$S)) {
		if ($S->open(timeout => $C->{snmp_timeout}, retries => $C->{snmp_retries}, max_msg_size => $C->{snmp_max_msg_size})) {
			if (getNodeInfo(sys=>$S)) {
				if ( $NC->{node}{collect} eq 'true') {
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
		}
	} else {		# no ping, no snmp, no type
		$NI->{system}{nodeModel} = 'Generic' if $NI->{system}{nodeModel} eq "";		# nmisdev Dec2010 first time model seen, collect, but no snmp answer
		$NI->{system}{nodeType} = 'generic' if $NI->{system}{nodeType} eq "";
	}
	#print Dumper($S)."\n";
	runReach(sys=>$S);
	$S->writeNodeView;  # save node view info in file var/$NI->{name}-view.nmis
	$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.nmis
	dbg("Finished");
	return;
} # end runUpdate

#=========================================================================================

sub doCollect {
	my %args = @_;
	my $name = $args{name};

	dbg("================================");
	dbg("Starting, node $name");

	my $S = Sys::->new; # create system object
	### 2013-02-25 keiths, fixing down node refreshing......
	#if (! $S->init(name=>$name) || $S->{info}{system}{nodedown} eq 'true') {
	#dbg("no info available of node $name or node was down, nodedown=$S->{info}{system}{nodedown}, refresh it");
	if (! $S->init(name=>$name) ) {
		dbg("no info available of node $name, refresh it");
		doUpdate(name=>$name);
		dbg("Finished");
		return; # next run to collect
	}

	my $NI = $S->ndinfo;
	my $NC = $S->ndcfg;
	$S->{docollect} = 'true'; # flag what is running
	$S->readNodeView; # from prev. run
	# print what we are
	dbg("node=$NI->{system}{name} role=$NI->{system}{roleType} type=$NI->{system}{nodeType}");
	dbg("vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}");

	if (runPing(sys=>$S)) {
		if ($S->open(timeout => $C->{snmp_timeout}, retries => $C->{snmp_retries}, max_msg_size => $C->{snmp_max_msg_size})) {
			# oke, node reachable
			if ( $NC->{node}{collect} eq 'true') {
				if (updateNodeInfo(sys=>$S)) {
					# snmp oke
					if ( $C->{snmp_stop_polling_on_error} eq "" ) {
						$C->{snmp_stop_polling_on_error} = "false";
					}
					### 2012-03-28 keiths, improving handling of transient SNMP sessions on bad links
					if ( $C->{snmp_stop_polling_on_error} eq "true" and $NI->{system}{snmpdown} eq "true") {
						logMsg("SNMP Polling stopped for $NI->{system}{name} because SNMP had errors, snmpdown=$NI->{system}{snmpdown} snmp_stop_polling_on_error=$C->{snmp_stop_polling_on_error}");	
					}
					else {
						
						### 2012-12-03 keiths, adding some model testing and debugging options.
						if ( $model ) {
							print "MODEL $S->{name}: role=$NI->{system}{roleType} type=$NI->{system}{nodeType} sysObjectID=$NI->{system}{sysObjectID} sysObjectName=$NI->{system}{sysObjectName}\n";
							print "MODEL $S->{name}: sysDescr=$NI->{system}{sysDescr}\n";
							print "MODEL $S->{name}: vendor=$NI->{system}{nodeVendor} model=$NI->{system}{nodeModel} interfaces=$NI->{system}{ifNumber}\n";
						}

						# get node data and store in rrd					
						getNodeData(sys=>$S);
						
						# get intf data and store in rrd
						getIntfData(sys=>$S) if defined $S->{info}{interface};
		
						getEnvData(sys=>$S);
	
						getCBQoS(sys=>$S);
	
						getCalls(sys=>$S);
	
						getPVC(sys=>$S);
						
						### server collection
						runServer(sys=>$S);
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
	$S->writeNodeInfo; # save node info in file var/$NI->{name}-node.nmis
	$S->close; 
	dbg("Finished");
	return;
} # end runCollect

#=========================================================================================

#
# normaly a daemon fpingd.pl is running (if set in NMIS config) and stores the result in var/fping.nmis
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

	if ($NC->{node}{ping} eq 'true') {
		# use fastping info if available
		if ($C->{daemon_fping_active} eq 'true') {
			$PT = loadTable(dir=>'var',name=>'nmis-fping'); # load ping results (from cache) from daemon fpingd
		}
		if ($C->{daemon_fping_active} eq 'true' and exists $PT->{$NC->{node}{name}}{loss}) {
			# copy values
			$ping_avg = $PT->{$NC->{node}{name}}{avg};
			$ping_loss = $PT->{$NC->{node}{name}}{loss};
			dbg("INFO ($S->{name}) PING min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
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
					if $C->{daemon_fping_active} eq 'true' and $C->{deamon_fping_failed} ne 'true' and $S->{doupdate} ne 'true';
			my $retries = $C->{ping_retries} ? $C->{ping_retries} : 3;
			my $timeout = $C->{ping_timeout} ? $C->{ping_timeout} : 300 ;
			my $packet = $C->{ping_packet} ? $C->{ping_packet} : 56 ;
			my $host = $NC->{node}{host};			# ip name/adress of node

			dbg("Starting $S->{name} ($host) with timeout=$timeout retries=$retries packet=$packet");

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
				dbg("Pinging Failed $S->{name} is NOT REACHABLE");
				logMsg("ERROR ($S->{name}) ping failed") if $NI->{system}{nodedown} ne 'true';

				notify(sys=>$S,event=>"Node Down",element=>"",details=>"Ping failed");
			} else {
				# Node is UP!
				$RI->{pingavg} = $ping_avg; # results for sub runReach
				$RI->{pingresult} = $pingresult;
				$RI->{pingloss} = $ping_loss;
				dbg("$S->{name} is PINGABLE min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
	
				# reset event only if snmp was not the reason of down
				if ($NI->{system}{snmpdown} ne 'true' ) {
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
		dbg("$S->{name} ping not requested");
		$RI->{pingresult} = 100; # results for sub runReach
		$RI->{pingavg} = 0;
		$RI->{pingloss} = 0;
		$exit = 1;
	}
	if ($exit) {
		$V->{system}{status_value} = 'reachable' if $NC->{node}{ping} eq 'true';
		$V->{system}{status_color} = '#0F0';
		$NI->{system}{nodedown} =  'false';
	} else {
		$V->{system}{status_value} = 'unreachable';
		$V->{system}{status_color} = 'red';
		$NI->{system}{nodedown} = 'true';
	}

	dbg("Finished with exit=$exit, nodedown=$NI->{system}{nodedown}");
	return $exit;
} # end runPing

#=========================================================================================
#
# get node info by snmp, define Model of node
#
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

	dbg("Starting");

	# cleanups
	delete $V->{interface}  if $S->{doupdate} eq 'true' and $NC->{node}{collect} ne 'true'; # rebuild small
	delete $NI->{graphtype} if $S->{doupdate} eq 'true' and $NC->{node}{collect} ne 'true'; # rebuild small

	########################
	# nmisdev 16Sep2011
	# update nodeConf with manual overides regardless of collect or snmp status
	# code copied here for test
	
	my $NCT = loadNodeConfTable();

		
	if ($NC->{node}{collect} eq 'true') {

		# if node already down then no snmp logging of node down
		$SNMP->logFilterOut("no response from") if $S->{snmpdown_org} eq 'true';
	
		# get node info by snmp: sysDescr, sysObjectID, sysUpTime etc. and store in $NI table
		if ($S->loadNodeInfo()) {

			my $enterpriseTable = loadEnterpriseTable(); # table is already cached
	
			# Only continue processing if at least a couple of entries are valid.
			if ($NI->{system}{sysDescr} ne "" and $NI->{system}{sysObjectID} ne "" ) {
	
				# if the vendors product oid file is loaded, this will give product name.
				$NI->{system}{sysObjectName} = oid2name($NI->{system}{sysObjectID});
	
				dbg("sysObjectId=$NI->{system}{sysObjectID}, sysObjectName=$NI->{system}{sysObjectName}");
				dbg("sysDescr=$NI->{system}{sysDescr}");
		
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
					dbg("selectNodeModel result model=$NI->{system}{nodeModel}");
					$NI->{system}{nodeModel} = 'Default' if $NI->{system}{nodeModel} eq "";
				} else {
					$NI->{system}{nodeModel} = $NC->{node}{model};
					dbg("node model=$NI->{system}{nodeModel} set by node config");
				}
				dbg("about to loadModel model=$NI->{system}{nodeModel}");
				$S->loadModel(model=>"Model-$NI->{system}{nodeModel}");

				$S->copyModelCfgInfo(type=>'all');							# copy model info in node info table

				###
				delete $V->{system} if $S->{doupdate} eq 'true'; # rebuild

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
				$V->{system}{location_value} = $NI->{system}{location};
				$V->{system}{location_title} = 'Location';
				$V->{system}{businessService_value} = $NI->{system}{businessService};
				$V->{system}{businessService_title} = 'Business Service';
				$V->{system}{serviceStatus_value} = $NI->{system}{serviceStatus};
				$V->{system}{serviceStatus_title} = 'Service Status';
	
				# update node info table with this new model
				if ($S->loadNodeInfo()) { 
		
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
				dbg("ERROR values of sysDescr and/or sysObjectID are empty");
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
	if ($NCT->{$S->{node}}{sysLocation} ne '') {
		$NI->{system}{sysLocation} = $V->{system}{sysLocation_value} = $NCT->{$NI->{system}{name}}{sysLocation};
		$NI->{nodeconf}{sysLocation} = $NI->{system}{sysLocation};
		dbg("Manual update of sysLocation by nodeConf");
	} else {
		$NI->{system}{sysLocation} = $NI->{system}{sysLocation};
	}
	if ($NCT->{$S->{node}}{sysContact} ne '') {
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
		$NI->{system}{noderesetcnt} = 0; # counter to skip rrd heartbeat
		
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
		if ( $NC->{node}{ping} eq 'true') {
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		} else {
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	$NI->{system}{nodedown} = $NI->{system}{snmpdown} = $exit ? 'false' : 'true';

	dbg("Finished with exit=$exit nodedown=$NI->{system}{nodedown}");
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
	if ( $C->{loc_from_DNSloc} eq "true" and $C->{netDNS} == 1 ) {
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
	if ( $C->{loc_from_sysLoc} eq "true" and $NI->{system}{loc_DNSloc} eq "unknown"  ) {
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
	dbg("Starting");

	my $attr = $args{attr};

	dbg("Start with attribute=$attr");

	delete $V->{system}{"${attr}_value"};

	dbg("Power check attribute=$attr value=$NI->{system}{$attr}");
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

	dbg("Finished");
	return;

} # end checkPower

#=========================================================================================
sub checkNodeConfiguration {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $V =  $S->view;
	my $M = $S->mdl;
	dbg("Starting");

	dbg("Start checkNodeConfiguration ");

	my @updatePrevValues = qw ( configLastChanged configLastSaved bootConfigLastChanged );
	# create previous values if they don't exist
	for my $attr (@updatePrevValues) {
		if ($NI->{system}{$attr} ne '' && !defined($NI->{system}{"${attr}_prev"}) ) {
			$NI->{system}{"${attr}_prev"} = $NI->{system}{$attr};
		}
	}

	my $configLastChanged = $NI->{system}{configLastChanged};
	my $configLastSaved = $NI->{system}{configLastSaved};
	my $bootConfigLastChanged = $NI->{system}{bootConfigLastChanged};
	my $configLastChanged_prev = $NI->{system}{configLastChanged_prev};

	dbg("checkNodeConfiguration configLastChanged=$configLastChanged, configLastSaved=$configLastSaved, bootConfigLastChanged=$bootConfigLastChanged, configLastChanged_prev=$configLastChanged_prev");
	# check if config is saved:
	$V->{system}{configLastChanged_value} = convUpTime( $configLastChanged/100 );
	$V->{system}{configLastSaved_value} = convUpTime( $configLastSaved/100 );
	$V->{system}{bootConfigLastChanged_value} = convUpTime( $bootConfigLastChanged/100 );
	$V->{system}{configurationState_title} = 'Configuration State';
	if( $configLastChanged > $bootConfigLastChanged ) {
		$V->{system}{"configurationState_value"} = "Config Not Saved";
		$V->{system}{"configurationState_color"} = "#FFDD00";	#warning
		dbg("checkNodeConfiguration, config not saved, $configLastChanged > $bootConfigLastChanged");
	} else {
		$V->{system}{"configurationState_value"} = "Config Saved";
		$V->{system}{"configurationState_color"} = "#00BB00";	#normal	
	}

	if( $configLastChanged > $configLastChanged_prev ) {
		$V->{system}{configChangeCount_value}++;
		$V->{system}{configChangeCount_title} = "Configuration change count";

		notify(sys=>$S,event=>"Node Configuration Change",element=>"",details=>"Changed at ".$V->{system}{configLastChanged_value} );
		logMsg("checkNodeConfiguration configuration change detected on $NI->{system}{name}, creating event");
	}
	
	#update previous values to be out current values
	for my $attr (@updatePrevValues) {
		if ($NI->{system}{$attr} ne '') {
			$NI->{system}{"${attr}_prev"} = $NI->{system}{$attr};
		}
	}

	dbg("Finished");
	return;

} # end checkNodeConfiguration

#=========================================================================================


# Create the Interface configuration from SNMP Stuff!!!!!
sub getIntfInfo {
	my %args = @_;
	my $S = $args{sys}; # object
	my $intf_one = $args{index}; # index for single interface update

	my $NI = $S->ndinfo; # node info table
	my $V =  $S->view;
	my $M = $S->mdl;	# node model table
	my $SNMP =$S->snmp;
	my $IF = $S->ifinfo; # interface info table
	my $NC = $S->ndcfg; # node config table

	my $C = loadConfTable();

	if ( defined $S->{mdl}{interface}{nocollect}{ifDescr} and $S->{mdl}{interface}{nocollect}{ifDescr} ne "" ) {
		dbg("Starting");
		dbg("Get Interface Info of node $NI->{system}{name}, model $NI->{system}{nodeModel}");
	
		# load interface types (IANA). number => name
		my $IFT = loadifTypesTable();
	
		my $NCT = loadNodeConfTable();
	
		# get interface Index table
		my @ifIndexNum;
		my $ifIndexTable;
		if (($ifIndexTable = $SNMP->gettable('ifIndex'))) {
			foreach my $oid ( oid_lex_sort(keys %{$ifIndexTable})) {
				push @ifIndexNum,$ifIndexTable->{$oid};
			}
		} else {
			logMsg("ERROR ($S->{name}) on get interface index table");
			# failed by snmp
			snmpNodeDown(sys=>$S);
			dbg("Finished");
			return 0;
		}
		
		if ($intf_one eq "") {
			# remove unknown interfaces, found in previous runs, from table
			for my $i (keys %{$IF}) {
				if (not grep { $i eq $_ } @ifIndexNum ) { 
					delete $IF->{$i};
					delete $NI->{graphtype}{$i};
					delete $NI->{database}{interface}{$i};
					delete $NI->{database}{pkts}{$i} if $NI->{database}{pkts}{$i} ne '';
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
				dbg("ifIndex=$index ifDescr=$IF->{$index}{ifDescr} ifType=$IF->{$index}{ifType} ifAdminStatus=$IF->{$index}{ifAdminStatus} ifOperStatus=$IF->{$index}{ifOperStatus} ifSpeed=$IF->{$index}{ifSpeed}");
			} else {
				# failed by snmp
				snmpNodeDown(sys=>$S);
				dbg("Finished");
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
		dbg("Getting Device IP Address Table"); 
		if ( $ifAdEntTable = $SNMP->getindex('ipAdEntIfIndex')) {
			if ( $ifMaskTable = $SNMP->getindex('ipAdEntNetMask')) {
				foreach my $addr (keys %{$ifAdEntTable}) {
					my $index = $ifAdEntTable->{$addr};
					next if ($intf_one ne '' and $intf_one ne $index);
					$ifCnt{$index} += 1;
					dbg("ifIndex=$ifAdEntTable->{$addr}, addr=$addr  mask=$ifMaskTable->{$addr}");	
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
		$qr_collect_ifAlias_gen = qr/($S->{mdl}{interface}{collect}{Description})/ if $S->{mdl}{interface}{collect}{Description};
		
		my $qr_no_event_ifAlias_gen = qr/($S->{mdl}{interface}{noevent}{Description})/i;
		my $qr_no_event_ifDescr_gen = qr/($S->{mdl}{interface}{noevent}{ifDescr})/i;
		my $qr_no_event_ifType_gen = qr/($S->{mdl}{interface}{noevent}{ifType})/i;

		my $noDescription = $M->{interface}{nocollect}{noDescription};
				
		### 2013-03-05 keiths, global collect policy override from Config!
    if ( defined $C->{global_nocollect_noDescription} and $C->{global_nocollect_noDescription} ne "" ) {
    	$noDescription = $C->{global_nocollect_noDescription};
    	dbg("INFO Model overriden by Global Config for global_nocollect_noDescription");
    }

    if ( defined $C->{global_collect_Description} and $C->{global_collect_Description} ne "" ) {
    	$qr_collect_ifAlias_gen = qr/($C->{global_collect_Description})/i;
    	dbg("INFO Model overriden by Global Config for global_collect_Description");
    }
    	
    if ( defined $C->{global_nocollect_ifDescr} and $C->{global_nocollect_ifDescr} ne "" ) {
    	$qr_no_collect_ifDescr_gen = qr/($C->{global_nocollect_ifDescr})/i;
    	dbg("INFO Model overriden by Global Config for global_nocollect_ifDescr");
    }

    if ( defined $C->{global_nocollect_Description} and $C->{global_nocollect_Description} ne "" ) {
    	$qr_no_collect_ifAlias_gen = qr/($C->{global_nocollect_Description})/i;
    	dbg("INFO Model overriden by Global Config for global_nocollect_Description");
    }

    if ( defined $C->{global_nocollect_ifType} and $C->{global_nocollect_ifType} ne "" ) {
    	$qr_no_collect_ifType_gen = qr/($C->{global_nocollect_ifType})/i;
    	dbg("INFO Model overriden by Global Config for global_nocollect_ifType");
    }

    if ( defined $C->{global_nocollect_ifOperStatus} and $C->{global_nocollect_ifOperStatus} ne "" ) {
    	$qr_no_collect_ifOperStatus_gen = qr/($C->{global_nocollect_ifOperStatus})/i;
    	dbg("INFO Model overriden by Global Config for global_nocollect_ifOperStatus");
    }

    if ( defined $C->{global_noevent_ifDescr} and $C->{global_noevent_ifDescr} ne "" ) {
    	$qr_no_event_ifDescr_gen = qr/($C->{global_noevent_ifDescr})/i;
    	dbg("INFO Model overriden by Global Config for global_noevent_ifDescr");
    }

    if ( defined $C->{global_noevent_Description} and $C->{global_noevent_Description} ne "" ) {
    	$qr_no_event_ifAlias_gen = qr/($C->{global_noevent_Description})/i;
    	dbg("INFO Model overriden by Global Config for global_noevent_Description");
    }

    if ( defined $C->{global_noevent_ifType} and $C->{global_noevent_ifType} ne "" ) {
    	$qr_no_event_ifType_gen = qr/($C->{global_noevent_ifType})/i;
    	dbg("INFO Model overriden by Global Config for global_noevent_ifType");
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
					dbg("Interface Description changed to $IF->{$index}{ifDescr}");
				}
			}
			### add in anything we find from nodeConf - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			if ($NCT->{$S->{node}}{$ifDescr}{Description} ne '') {
				$IF->{$index}{nc_Description} = $IF->{$index}{Description}; # save
				$IF->{$index}{Description} = $V->{interface}{"${index}_Description_value"} = $NCT->{$S->{node}}{$ifDescr}{Description};
				dbg("Manual update of Description by nodeConf");
			}
			if ($NCT->{$S->{node}}{$ifDescr}{ifSpeed} ne '') {
				$IF->{$index}{nc_ifSpeed} = $IF->{$index}{ifSpeed}; # save
				$IF->{$index}{ifSpeed} = $V->{interface}{"${index}_ifSpeed_value"} = $NCT->{$S->{node}}{$ifDescr}{ifSpeed};
				### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
				$V->{interface}{"${index}_ifSpeed_value"} = convertIfSpeed($IF->{$index}{ifSpeed});
				dbg("Manual update of ifSpeed by nodeConf");
			}
	
			#
			# preset collect,event on true
			$IF->{$index}{collect} = "true";
			$IF->{$index}{event} = "true";
			#
			#Decide if the interface is one that we can do stats on or not based on Description and ifType and AdminStatus
			# If the interface is admin down no statistics
			### 2012-03-14 keiths, collecting override based on interface description.
			if ($qr_collect_ifAlias_gen and $IF->{$index}{Description} =~ /$qr_collect_ifAlias_gen/i ) {
				$IF->{$index}{collect} = "true";
				$IF->{$index}{nocollect} = "Collecting: found $1 in Description"; # reason
			}
			elsif ($IF->{$index}{ifAdminStatus} =~ /down|testing|null/ ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{event} = "false";
				$IF->{$index}{nocollect} = "ifAdminStatus eq down|testing|null"; # reason
				$IF->{$index}{noevent} = "ifAdminStatus eq down|testing|null"; # reason
			} 
			elsif ($IF->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "found $1 in ifDescr"; # reason
			} 
			elsif ($IF->{$index}{ifType} =~ /$qr_no_collect_ifType_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "found $1 in ifType"; # reason
			} 
			elsif ($IF->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "found $1 in Description"; # reason
			} 
			elsif ($IF->{$index}{Description} eq "" and $noDescription eq 'true') {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "no Description (ifAlias)"; # reason
			} 
			elsif ($IF->{$index}{ifOperStatus} =~ /$qr_no_collect_ifOperStatus_gen/i ) {
				$IF->{$index}{collect} = "false";
				$IF->{$index}{nocollect} = "found $1 in ifOperStatus"; # reason
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
				dbg("Manual update of Collect by nodeConf");
				if ($IF->{$index}{collect} eq 'false') {
					$IF->{$index}{nocollect} = "Manual update by nodeConf";
				}
			}
			if ($NCT->{$S->{name}}{$ifDescr}{event} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $IF->{$index}{ifDescr}) {
				$IF->{$index}{nc_event} = $IF->{$index}{event};
				$IF->{$index}{event} = $NCT->{$S->{name}}{$ifDescr}{event};
				$IF->{$index}{noevent} = "Manual update by nodeConf" if $IF->{$index}{event} eq 'false'; # reason
				dbg("Manual update of Event by nodeConf");
			}
			if ($NCT->{$S->{name}}{$ifDescr}{threshold} ne '' and $NCT->{$S->{name}}{$ifDescr}{ifDescr} eq $IF->{$index}{ifDescr}) {
				$IF->{$index}{nc_threshold} = $IF->{$index}{threshold};
				$IF->{$index}{threshold} = $NCT->{$S->{name}}{$ifDescr}{threshold};
				$IF->{$index}{nothreshold} = "Manual update by nodeConf" if $IF->{$index}{threshold} eq 'false'; # reason
				dbg("Manual update of Threshold by nodeConf");
			}
	
			# interface now up or down, check and set or clear outstanding event.
			if ( $IF->{$index}{collect} eq 'true'
					and $IF->{$index}{ifAdminStatus} =~ /up|ok/ 
					and $IF->{$index}{ifOperStatus} !~ /up|ok|dormant/ 
			) {
				if ($IF->{$index}{event} eq 'true') {
					notify(sys=>$S,event=>"Interface Down",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
				}
			} else {
				checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
			}
	
			$IF->{$index}{threshold} = $IF->{$index}{collect};
	
			# number of interfaces collected with collect and event on
			$intfCollect++ if $IF->{$index}{collect} eq 'true' && $IF->{$index}{event} eq 'true';
	
			# save values only if all interfaces are updated
			if ($intf_one eq '') {
				$NI->{system}{intfTotal} = $intfTotal;
				$NI->{system}{intfCollect} = $intfCollect;
			}
	
			# prepare values for web page
			$V->{interface}{"${index}_event_value"} = $IF->{$index}{event};
			$V->{interface}{"${index}_event_title"} = 'Event on';
	
			$V->{interface}{"${index}_threshold_value"} = $NC->{node}{threshold} ne 'true' ? 'false': $IF->{$index}{threshold};
			$V->{interface}{"${index}_threshold_title"} = 'Threshold on';
	
			$V->{interface}{"${index}_collect_value"} = $IF->{$index}{collect};
			$V->{interface}{"${index}_collect_title"} = 'Collect on';
	
			# collect status
			delete $V->{interface}{"${index}_nocollect_title"};
			if ($IF->{$index}{collect} eq "true") {
				dbg("ifIndex $index, collect=true");
			} else {
				$V->{interface}{"${index}_nocollect_value"} = $IF->{$index}{nocollect};
				$V->{interface}{"${index}_nocollect_title"} = 'Reason';
				dbg("ifIndex $index, collect=false, $IF->{$index}{nocollect}");
				# no collect => no event, no threshold
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
	
		dbg("Finished");
	}
	else {
		dbg("Skipping, interfaces not defined in Model");		
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
	my $SNMP = $S->{snmp};
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
	
				if ($S->{docollect} eq 'true') {
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
					if (($envIndexTable = $SNMP->gettable($index_var))) {
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
						logMsg("ERROR ($S->{name}) on get environment $section index table");
						# failed by snmp
						snmpNodeDown(sys=>$S);
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
					if (($envIndexTable = $SNMP->gettable($index_var))) {
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
					if (($envIndexTable = $SNMP->gettable($index_var))) {
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
						logMsg("ERROR ($S->{name}) on get environment $section index table");
						# failed by snmp
						snmpNodeDown(sys=>$S);
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
								if ((my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index)) ne "") {
									$NI->{database}{$sect}{$index} = $db;
								}
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
								if ((my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index)) ne "") {
									$NI->{database}{$sect}{$index} = $db;
								}
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
								if ((my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index)) ne "") {
									$NI->{database}{$sect}{$index} = $db;
								}
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

		dbg("Starting Update Node Info, node $S->{name}");

	# check node reset count
	if ($NI->{system}{noderesetcnt} > 0) {
		dbg("noderesetcnt=$NI->{system}{noderesetcnt} skip collecting");
		$NI->{system}{noderesetcnt}--;
		$NI->{system}{noderesetcnt} = 4 if $NI->{system}{noderesetcnt} > 4; # limit
		delete $NI->{system}{noderesetcnt} if $NI->{system}{noderesetcnt} <= 0; # failure
		$exit= 0;
		goto END_updateNodeInfo;
	}

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

		if ($ifNumber != $NI->{system}{ifNumber}) {
			logMsg("INFO ($NI->{system}{name}) Number of interfaces changed from $ifNumber now $NI->{system}{ifNumber}");
			getIntfInfo(sys=>$S); # get new interface table
		}

			# Read the uptime from the node info file from the last time it was polled
		$NI->{system}{sysUpTimeSec} = int($NI->{system}{sysUpTime}/100); # seconds	

		$NI->{system}{sysUpTime} = convUpTime($NI->{system}{sysUpTimeSec});
		dbg("sysUpTime: Old=$sysUpTime New=$NI->{system}{sysUpTime}");
		### 2012-08-18 keiths, Special debug for Node Reset false positives
		#logMsg("DEBUG Node Reset: Node=$S->{name} Old=$sysUpTime New=$NI->{system}{sysUpTime} OldSec=$sysUpTimeSec NewSec=$NI->{system}{sysUpTimeSec}");
		#if ( $NI->{system}{sysUpTime} ) {
		#	
		#}
		if ($sysUpTimeSec > $NI->{system}{sysUpTimeSec} and $NI->{system}{sysUpTimeSec} ne '') {
			dbg("NODE RESET: Old sysUpTime=$sysUpTimeSec New sysUpTime=$NI->{system}{sysUpTimeSec}");
			notify(sys=>$S, event=>"Node Reset",element=>"",details=>"Old_sysUpTime=$sysUpTime New_sysUpTime=$NI->{system}{sysUpTime}");
			# calculate time of node no collecting to overlap heartbeat
			my $cnt = 4 - ((time() - $NI->{system}{lastUpdateSec})/300);
#			if ($cnt > 0) {
#				$NI->{system}{noderesetcnt} = int($cnt);
#				$exit= 0;
#				goto END_updateNodeInfo;
#			}
		}

		$V->{system}{sysUpTime_value} = $NI->{system}{sysUpTime};
		$V->{system}{sysUpTime_title} = 'Uptime';

		$V->{system}{lastUpdate_value} = returnDateStamp();
		$V->{system}{lastUpdate_title} = 'Last Update';
		$NI->{system}{lastUpdateSec} = time();

		# modify by nodeConf ?
		if ($NCT->{$S->{node}}{sysLocation} ne '') {
			$NI->{nodeconf}{sysLocation} = $NI->{system}{sysLocation};
			$NI->{system}{sysLocation} = $V->{system}{sysLocation_value} = $NCT->{$S->{node}}{sysLocation};
			dbg("Manual update of sysLocation by nodeConf");
		}
		if ($NCT->{$S->{node}}{sysContact} ne '') {
			$NI->{nodeconf}{sysContact} = $NI->{system}{sysContact};
			$NI->{system}{sysContact} = $V->{system}{sysContact_value} = $NCT->{$S->{node}}{sysContact};
			dbg("Manual update of sysContact by nodeConf");
		}

		# ok we are running snmp
		checkEvent(sys=>$S,event=>'SNMP Down',level=>"Normal",element=>'',details=>"SNMP error");

		checkPIX(sys=>$S); # check firewall if needed

		###
		delete $NI->{graphtype}; # let new build of graphtype list
		delete $NI->{database};

		$RI->{snmpresult} = 100; # oke, health info

		# view on page
		$V->{system}{status_value} = 'reachable';
		$V->{system}{status_color} = '#0F0';
		
		checkNodeConfiguration(sys=>$S) if exists $M->{system}{sys}{nodeConfiguration};

	} else {
		$exit = snmpNodeDown(sys=>$S);
		# view on page
		if ( $NC->{node}{ping} eq 'true') {
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
	dbg("Finished with exit=$exit");
	return $exit;
} # end updateNodeInfo

sub processAlerts {
	my %args = @_;
	my $S = $args{S};
	my $alerts = $S->{alerts};
	for( my $i = 0; $i < @{$alerts}; $i++)
	{
		my $alert = shift @{$alerts};
		dbg("Processing alert: event=Alert: $alert->{event}, level=$alert->{level}, element=$alert->{ds}, details=Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}");
		dbg("Processing alert ".Dumper($alert),2);
		if( $alert->{test_result} ) {
			notify(sys=>$S, event=>"Alert: ".$alert->{event}, level=>$alert->{level}, element=>$alert->{ds}, details=>"Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}");
		} else {
			checkEvent(sys=>$S, event=>"Alert: ".$alert->{event}, level=>$alert->{level}, element=>$alert->{ds}, details=>"Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}");
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

	dbg("Starting Node get data, node $S->{name}");

	if (($rrdData = $S->getData(class=>'system', model => $model))) {
		processAlerts( S => $S );
		if ( $rrdData->{error} eq "" ) {
			foreach my $sect (keys %{$rrdData}) {
				my $D = $rrdData->{$sect};
			
				checkNodeHealth(sys=>$S,data=>$D) if $sect eq "nodehealth";
				
				foreach my $ds (keys %{$D}) {
					dbg("rrdData, section=$sect, ds=$ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}",2);
				}
				if ((my $db = updateRRD(sys=>$S,data=>$D,type=>$sect)) ne "") {
					$NI->{database}{$sect}= $db;
				}
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
	
	dbg("Finished");
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

	# take care of negative values from 6509 MSCF
	if ( exists $D->{bufferElHit} and $D->{bufferElHit}{value} < 0) { $D->{bufferElHit}{value} = sprintf("%u",$D->{bufferElHit}{value}); }
	
	### 2012-12-13 keiths, fixed this so it would assign!
	$RI->{cpu} = ($D->{avgBusy5}{value} ne "") ? $D->{avgBusy5}{value} : $D->{avgBusy1}{value};
	$RI->{memused} = $D->{MemoryUsedPROC}{value};
	$RI->{memfree} = $D->{MemoryFreePROC}{value};
	
	dbg("Finished");
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

	my $C = loadConfTable();
	my $ET = loadEventStateNoLock();

	$S->{ET} = $ET; # save in object for speeding up checkevent

	my $NCT = loadNodeConfTable();

	my $createdone = "false";
	
	dbg("Starting Interface get data, node $S->{name}");

	$RI->{intfUp} = $RI->{intfColUp} = 0; # reset counters of interface Up and interface collected Up

	# check first if admin status of interfaces changed
	my $ifAdminTable;
	my $ifOperTable;
	if ( ($ifAdminTable = $S->{snmp}->getindex('ifAdminStatus')) ) {
		$ifOperTable = $S->{snmp}->getindex('ifOperStatus');
		for my $index (keys %{$ifAdminTable}) {
			logMsg("INFO ($S->{name}) entry ifAdminStatus for index=$index not found in interface table") if not exists $IF->{$index}{ifAdminStatus};
			if (($ifAdminTable->{$index} == 1 and $IF->{$index}{ifAdminStatus} ne 'up')
				or ($ifAdminTable->{$index} != 1 and $IF->{$index}{ifAdminStatus} eq 'up') ) {
				### logMsg("INFO ($S->{name}) ifIndex=$index, Admin was $IF->{$index}{ifAdminStatus} now $ifAdminTable->{$index} (1=up) rebuild");
				getIntfInfo(sys=>$S,index=>$index); # update this interface
			}
			# total number of interfaces up
			$RI->{intfUp}++ if $ifOperTable->{$index} == 1 and $IF->{$index}{real} eq 'true';
		}
	}

	# Start a loop which go through the interface table

	foreach my $index ( sort {$a <=> $b} keys %{$IF} ) {
		dbg("$IF->{$index}{ifDescr}: ifIndex=$IF->{$index}{ifIndex}, was => OperStatus=$IF->{$index}{ifOperStatus}, ifAdminStatus=$IF->{$index}{ifAdminStatus}, Collect=$IF->{$index}{collect}");

		# only collect on interfaces that are defined, with collection turned on globally
		if ( $IF->{$index}{collect} eq 'true') {
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
				
							if ( $D->{ifInOctets}{value} ne "" and $D->{ifOutOctets}{value} ne "" ) {
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
								
								# If new ifDescr is different from old ifDescr rebuild interface info table
								# check if nodeConf modified this inteface
								
								my $ifDescr = $IF->{$index}{ifDescr};
								if ($NI->{system}{nodeType} =~ /router|switch/ and $NCT->{$S->{node}}{$ifDescr}{Description} eq '' and
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
								my $opstatus = $IF->{$index}{event} eq 'true' ? $operStatus : 100;
								$RI->{operStatus} = $RI->{operStatus} + $opstatus;
								$RI->{operCount} = $RI->{operCount} + 1;
	
								# count total number of collected interfaces up ( if events are set on)
								$RI->{intfColUp} += $operStatus/100 if $IF->{$index}{event} eq 'true'; 
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
						dbg("updateRRD type$sect index=$index",2);
						if ((my $db = updateRRD(sys=>$S,data=>$D,type=>$sect,index=>$index)) ne "") {
							$NI->{database}{$sect}{$index} = $db;
						}
					}
					# calculate summary statistics of this interface only if intf up
					my $util = getSummaryStats(sys=>$S,type=>"interface",start=>"-6 hours",end=>time,index=>$index);
					$V->{interface}{"${index}_operAvail_value"} = $util->{$index}{availability};
					$V->{interface}{"${index}_totalUtil_value"} = $util->{$index}{totalUtil};
					$V->{interface}{"${index}_operAvail_color"} = colorHighGood($util->{$index}{availability});
					$V->{interface}{"${index}_totalUtil_color"} = colorLowGood($util->{$index}{totalUtil});
	
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
				if ($IF->{$index}{event} eq 'true') {
					dbg("Interface Status 20: ifAdminStatus=$IF->{$index}{ifAdminStatus} ifOperStatus=$IF->{$index}{ifOperStatus} collect=$IF->{$index}{collect}");
					notify(sys=>$S,event=>"Interface Down",element=>$IF->{$index}{ifDescr},details=>$IF->{$index}{Description});
				}
			}

			# header info of web page
			$V->{interface}{"${index}_operAvail_title"} = 'Intf. Avail.';
			$V->{interface}{"${index}_totalUtil_title"} = 'Util. 6hrs';

			# check escalation if event is on
			if ($IF->{$index}{event} eq 'true') {
				my $event_hash = eventHash($S->{node}, "Interface Down", $IF->{$index}{ifDescr});
				my $escalate = exists $ET->{$event_hash}{escalate} ? $ET->{$event_hash}{escalate} : 'none';
				$V->{interface}{"${index}_escalate_title"} = 'Esc.';
				$V->{interface}{"${index}_escalate_value"} = $escalate;
			}

		} else {
			dbg("NOT Collected: $IF->{$index}{ifDescr}: ifIndex=$IF->{$index}{ifIndex}, OperStatus=$IF->{$index}{ifOperStatus}, ifAdminStatus=$IF->{$index}{ifAdminStatus}, Interface Collect=$IF->{$index}{collect}");
		}
	} # FOR LOOP

	$S->{ET} = '';
	dbg("Finished");
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
		dbg("no collecting ($NC->{node}{cbqos}) for node $NI->{system}{name}");
		delete $NI->{database}{cbqos}; # cleanup
		return;
	}

	dbg("Starting for node $S->{name}");

	## oke,lets go
	if ($S->{doupdate} eq 'true') {
		getCBQoSwalk(sys=>$S); 	# get indexes
	} elsif (!getCBQoSdata(sys=>$S)) {
		getCBQoSwalk(sys=>$S); 	# get indexes
		getCBQoSdata(sys=>$S); 	# get data
	}

	dbg("Finished"); 

	return;

#===
	sub getCBQoSdata {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $SNMP = $S->{snmp};
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
								dbg("Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex");

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
										dbg("bytes transfered  $D->{'PrePolicyByte'}{value}, bytes dropped  $D->{'DropByte'}{value}");
										dbg("packets transfered  $D->{'PrePolicyPkt'}{value}, packets dropped $D->{'DropPkt'}{value}");
										dbg("packets dropped no buffer $D->{'NoBufDropPkt'}{value}");
										#
										# update RRD
										if ((my $db = updateRRD(sys=>$S,data=>$D,type=>"cbqos-$direction",index=>$intf,item=>$CMName))) {
											$NI->{database}{"cbqos-$direction"}{$intf}{$CMName} = $db;
										}
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
		my $SNMP = $S->{snmp};

		my $message;
		my %qosIntfTable;
		my @arrOID;
		my %cbQosTable;
		my $ifIndexTable;

		# get the interface indexes and objects from the snmp table

		dbg("start table scanning");

		# read qos interface table
		if ( $ifIndexTable = $SNMP->getindex('cbQosIfIndex')) {
			foreach my $PIndex (keys %{$ifIndexTable}) {
				my $intf = $ifIndexTable->{$PIndex}; # the interface number from de snmp qos table
				dbg("CBQoS, scan interface $intf");
				# is this an active interface 
				if ( exists $IF->{$intf}) {
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
						dbg("Interface $intf found, direction $direction, PolicyIndex $PIndex");

						# get the policy config table for this interface
						my $qosIndexTable = $SNMP->getindex("cbQosConfigIndex.$PIndex");

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
								while ($C->{'cbqos_cm_collect_all'} ne "false" and $answer->{'cbQosParentObjectsIndex2'} ne 0 and $answer->{'cbQosParentObjectsIndex2'} ne $PIndex and $cnt++ lt 5) {
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
								if (($C->{'cbqos_cm_collect_all'} ne "false" or $answer->{'cbQosParentObjectsIndex'} eq $PIndex)) {
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
									$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * $IF->{$intf}{'ifSpeed'}/100;
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
					dbg("Interface $intf does not exitst");
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

	if ($NC->{node}{calls} ne 'true') {
		dbg("no collecting for node $NI->{system}{name}");
		delete $NI->{database}{calls}; # cleanup
		return;
	}

	dbg("Starting Calls for node $NI->{system}{name}");

	## oke,lets go
	if ($S->{doupdate} eq 'true') {
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
				if (( my $db = updateRRD(data=>\%snmpVal,sys=>$S,type=>"calls",index=>$intfindex)) ne "") {
					$NI->{database}{calls}{$intfindex} = $db;
				}
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
		my $SNMP = $S->{snmp};

		my %seen;
		my %callsTable;
		my %mappingTable;
		my ($intfindex,$parentintfIndex);

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
		if ($IntfIndexTable = $SNMP->getindex("cpmDS0InterfaceIndex")) {
			foreach my $index (keys %{$IntfIndexTable}) {
				$intfindex = $IntfIndexTable->{$index};
				my ($slot,$port,$channel) = split /\./,$index,3;
				$callsTable{$intfindex}{'intfoid'} = $index;
				$callsTable{$intfindex}{'intfindex'} = $intfindex;
				$callsTable{$intfindex}{'slot'} = $slot;
				$callsTable{$intfindex}{'port'} = $port;
				$callsTable{$intfindex}{'channel'} = $channel;
			}
			if ($IntfStatusTable = $SNMP->getindex("ifStackStatus")) {
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
			
				# create $nodes-calls.nmis file which contains interface mapping and descirption data	
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

	dbg("Starting frame relay PVC collection");

	# double check if any frame relay interfaces on this node.
	# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
	# only collect on interfaces that are defined, with collection turned on globally
	# and for that interface and that are Admin UP
	foreach ( keys %{$IF} ) {
		if ( $IF->{$_}{ifType} =~ /framerelay/i
			and $IF->{$_}{ifAdminStatus} eq "up" and 
			$IF->{$_}{collect} eq "true"
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
	if ( $frCircEntryTable = $SNMP->getindex('frCircuitEntry')) {
		foreach my $index (keys %{$frCircEntryTable}) { 
			my ($oid,$port,$pvc) = split /\./,$index,3;
			my $textoid = oid2name("1.3.6.1.2.1.10.32.2.1.$oid"); 
			$pvcStats{$port}{$pvc}{$textoid} = $frCircEntryTable->{$index};
			if ($textoid =~ /ReceivedBECNs|ReceivedFECNs|ReceivedFrames|ReceivedOctets|SentFrames|SentOctets|State/) {
				$snmpTable{$port}{$pvc}{$textoid}{value} = $frCircEntryTable->{$index};
			}
		}
		if ( $NI->{system}{nodeModel} =~ /CiscoRouter/ ) {
			if ( $cfrExtCircIfNameTable = $SNMP->getindex('cfrExtCircuitIfName')) {
				foreach my $index (keys %{$cfrExtCircIfNameTable}) { 
					my ($port,$pvc) = split /\./,$index;
					$pvcStats{$port}{$pvc}{'cfrExtCircuitIfName'} = $cfrExtCircIfNameTable->{$index};
				}
			}
		}

		# we now have a hash of port:pvc:mibname=value - or an empty hash if no reply....
		# put away to a rrd.
		delete 	$NI->{database}{pvc}; # cleanup first
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
					$NI->{database}{pvc}{$key} = $db;
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

	dbg("Starting server device/storage collection, node $NI->{system}{name}");

	# get cpu info
	delete $NI->{device};
	if ($M->{device} ne '') {
		my $deviceIndex = $SNMP->getindex('hrDeviceIndex');
		$S->loadInfo(class=>'device',model=>$model); # get cpu load without index
		foreach my $index (keys %{$deviceIndex}) {
			if ($S->loadInfo(class=>'device',index=>$index,model=>$model)) {
				my $D = $NI->{device}{$index};
				dbg("device Descr=$D->{hrDeviceDescr}, Type=$D->{hrDeviceType}");
				if ($D->{hrDeviceType} eq '1.3.6.1.2.1.25.3.1.3') { # hrDeviceProcessor
					($hrCpuLoad,$D->{hrDeviceDescr}) = $SNMP->getarray("hrProcessorLoad.${index}","hrDeviceDescr.${index}");
					
					### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
					push(@{$S->{reach}{cpuList}},$hrCpuLoad);
					
					$NI->{device}{$index}{hrCpuLoad} = ($hrCpuLoad =~ /noSuch/i) ? $NI->{device}{hrCpuLoad} : $hrCpuLoad ;
					dbg("cpu Load=$NI->{device}{hrCpuLoad}, Descr=$D->{hrDeviceDescr}");
					undef %Val;
					$Val{hrCpuLoad}{value} = $NI->{device}{$index}{hrCpuLoad} || 0;
					if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrsmpcpu",index=>$index))) {
						$NI->{database}{hrsmpcpu}{$index} = $db;
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
		my $storageIndex = $SNMP->getindex('hrStorageIndex');
		foreach my $index (keys %{$storageIndex}) {
			if ($S->loadInfo(class=>'storage',index=>$index,model=>$model)) {
				my $D = $NI->{storage}{$index};
				dbg("storage Type=$D->{hrStorageType}, Size=$D->{hrStorageSize}, Used=$D->{hrStorageUsed}, Units=$D->{hrStorageUnits}");
				if (($M->{storage}{nocollect}{Description} ne '' and $D->{hrStorageDescr} =~ /$M->{storage}{nocollect}{Description}/ ) 
							or $D->{hrStorageSize} <= 0) {
					delete $NI->{storage}{$index};
				} else {
					if ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.4') { # hrStorageFixedDisk
						undef %Val;
						$Val{hrDiskSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrDiskUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Memory to Health Calculations.
						push(@{$S->{reach}{diskList}},($Val{hrDiskSize}{value} - $Val{hrDiskUsed}{value}) / $Val{hrDiskSize}{value} * 100);

						$D->{hrStorageDescr} =~ s/,/ /g;	# lose any commas.
						if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrdisk",index=>$index))) {
							$NI->{database}{hrdisk}{$index} = $db;
							$NI->{graphtype}{$index}{hrdisk} = "hrdisk";
							$D->{hrStorageType} = 'Fixed Disk';
							$D->{hrStorageIndex} = $index;
							$D->{hrStorageGraph} = "hrdisk";
							$disk_cnt++;
						}
					} elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.2') { # Memory
						undef %Val;
						$Val{hrMemSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrMemUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};
						
						### 2012-12-20 keiths, adding Server Memory to Health Calculations.
						$S->{reach}{memfree} = $Val{hrMemSize}{value} - $Val{hrMemUsed}{value};
						$S->{reach}{memused} = $Val{hrMemUsed}{value};
						
						if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrmem"))) {
							$NI->{database}{hrmem} = $db;
							$NI->{graphtype}{hrmem} = "hrmem";
							$D->{hrStorageType} = 'Memory';
							$D->{hrStorageGraph} = "hrmem";
						}
					} elsif ( $D->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.3') { # VirtualMemory
						undef %Val;
						$Val{hrVMemSize}{value} = $D->{hrStorageUnits} * $D->{hrStorageSize};
						$Val{hrVMemUsed}{value} = $D->{hrStorageUnits} * $D->{hrStorageUsed};
						if ((my $db = updateRRD(sys=>$S,data=>\%Val,type=>"hrvmem"))) {
							$NI->{database}{hrvmem} = $db;
							$NI->{graphtype}{hrvmem} = "hrvmem";
							$D->{hrStorageType} = 'Virtual Memory';
							$D->{hrStorageGraph} = "hrvmem";
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
		$S->{reach}{disk} = mean(@{$S->{reach}{diskList}});
	}

	# convert date value to readable string
	sub snmp2date {
		my @tt = unpack("C*", shift );
		return eval(($tt[0] *256) + $tt[1])."-".$tt[2]."-".$tt[3].",".$tt[4].":".$tt[5].":".$tt[6].".".$tt[7];
	}
	dbg("Finished");
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

	dbg("Starting Services stats, node=$NI->{system}{name}, nodeType=$NI->{system}{nodeType}");

	### 2012-09-11 keiths, running services even if node down.
	#if ($NI->{system}{nodedown} eq 'true') {
	#	dbg("node down - skip");
	#	goto END_runServices;
	#}

	my %snmpTable;
	my %Val;
	my $service;
	my $ret;
	my $cpu;
	my $memory;
	my $gotMemCpu = 0;
	my $msg;
	my $servicePoll = 0;
	my %services;		# hash to hold snmp gathered service status.

	my $ST = loadServicesTable();

	# services to be polled are saved in a list
	foreach $service ( split /,/ , lc($NT->{$NI->{system}{name}}{services}) ) {
		# check for invalid service table
		next if $service =~ /n\/a/i;
		next if $ST->{$service}{Service_Type} =~ /n\/a/i;
		next if $service eq '';
		dbg("Checking service_type=$ST->{$service}{Service_Type} name=$ST->{$service}{Name} service_name=$ST->{$service}{Service_Name}");

		# clear global hash each time around as this is used to pass results to rrd update
		undef %snmpTable;
		$ret = 0;

		# DNS gets treated simply ! just lookup our own domain name.
		if ( $ST->{$service}{Service_Type} eq "dns" ) {
			if ($NI->{system}{host} =~ /^\d+.\d+.\d+.\d+$/) {
				dbg("host $NI->{system}{host} must be a fqdn");
				logMsg("ERROR, ($NI->{system}{name}) service=$service must contain a fqdn");
				next;
			}
			my $res;
			my $packet;
			my $rr;

			# resolve $node to an IP address first so Net::DNS points at the remote server
			if ( my $packed_ip = inet_aton($NI->{system}{host})) {
				my $ip = inet_ntoa($packed_ip);

				use Net::DNS;
				$res = Net::DNS::Resolver->new;
					$res->nameservers($ip);
					$res->recurse(0);
					$res->retry(2);
					$res->usevc(0);			# force to udp (default)
					$res->debug(1) if $C->{debug} >3;			# set this to 1 for debug

				if ( !$@ ) {
					$packet = $res->query($NI->{system}{host});		# lookup its own nodename on itself, should always work..?
					if (!$packet) {
						$ret = 0;
						dbg("ERROR Unable to lookup data for $node from $ip\[$NI->{system}{host}\]");
					}
					else {
						# stores the last RR we receive
						foreach $rr ($packet->answer) {
							$ret = 1;
							my $tmp = $rr->address;
							dbg("RR data for $node from $ip\[$NI->{system}{host}\] was $tmp");
						}
					}
				}
				else {
					dbg("ERROR Net::DNS error $@");
					$ret = 0;
				}
			} else { dbg("ERROR Could not resolve $NI->{system}{host} to ip"); }
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
		elsif ( $ST->{$service}{Service_Type} eq "service" and $NI->{system}{nodeType} eq 'server') {
			# only do the SNMP checking if you are supposed to!
			dbg("snmp_stop_polling_on_error=$C->{snmp_stop_polling_on_error} snmpdown=$NI->{system}{snmpdown} nodedown=$NI->{system}{nodedown}");
			if ( $C->{snmp_stop_polling_on_error} eq "false" or ( $C->{snmp_stop_polling_on_error} eq "true" and $NI->{system}{snmpdown} ne "true" and $NI->{system}{nodedown} ne "true") ) {
				if ($ST->{$service}{Service_Name} eq '') {
					dbg("ERROR, service_name is empty");
					logMsg("ERROR, ($NI->{system}{name}) service=$service service_name is empty");
					next;
				}
				if ( ! $servicePoll ) {
					dbg("get index of hrSWRunName hrSWRunStatus by snmp");
					my $timeout = 3;
					my $snmpcmd;
					my @ret;
					my $var;
					my $i;
					my $key;
					my $write=0;
	
					$servicePoll = 1;	# set flag so snmpwalk happens only once.
	
					my @snmpvars = qw( hrSWRunName hrSWRunStatus hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem);
					my $hrIndextable;
					foreach my $var ( @snmpvars ) {
						if ( $hrIndextable = $SNMP->getindex($var)) {
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
	
					foreach (sort keys %{$snmpTable{hrSWRunName}} ) {
						# key services by name_pid
						$key = $snmpTable{hrSWRunName}{$_}.':'.$_;
						$services{$key}{hrSWRunName} = $key;
						$services{$key}{hrSWRunType} = ( '', 'unknown', 'operatingSystem', 'deviceDriver', 'application' )[$snmpTable{hrSWRunType}{$_}];
						$services{$key}{hrSWRunStatus} = ( '', 'running', 'runnable', 'notRunnable', 'invalid' )[$snmpTable{hrSWRunStatus}{$_}];
						$services{$key}{hrSWRunPerfCPU} = $snmpTable{hrSWRunPerfCPU}{$_};
						$services{$key}{hrSWRunPerfMem} = $snmpTable{hrSWRunPerfMem}{$_};
	
						dbg("$services{$key}{hrSWRunName} type=$services{$key}{hrSWRunType} status=$services{$key}{hrSWRunStatus} cpu=$services{$key}{hrSWRunPerfCPU} memory=$services{$key}{hrSWRunPerfMem}");
					}
	
				} #servicePoll
				
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
							dbg("INFO, service $ST->{$service}{Name} is up, status is $services{$_}{hrSWRunStatus}");
						}
						else {
							$ret = 0;
							$cpu = $services{$_}{hrSWRunPerfCPU};
							$memory = $services{$_}{hrSWRunPerfMem};
							$gotMemCpu = 1;
							dbg("INFO, service $ST->{$service}{Name} is down, status is $services{$_}{hrSWRunStatus}");
							last;
						}
					}					
				}
				
				### 2012-12-20 keiths, keep the services for display later.
				$NI->{services} = \%services;
			}	
		}
		# now the scripts !
		elsif ( $ST->{$service}{Service_Type} eq "script" ) {

			### lets do the user defined scripts
			### ($ret,$msg) = sapi($ip,$port,$script,$ScriptTimeout);

			($ret,$msg) = sapi($NI->{system}{host},$ST->{$service}{Port},"$C->{script_root}/$service",3);
			dbg("Results of $service is $ret, msg is $msg");
		}
		else {
			# no service type found
			dbg("ERROR, service handling not found");
			$ret = 0;
			$msg = '';
			next;			# just do the next one - no alarms
		}

		$V->{system}{"${service}_title"} = "Service $ST->{$service}{Name}";
		$V->{system}{"${service}_value"} = $ret ? 'running' : 'down';
		$V->{system}{"${service}_color"} =  $ret ? 'white' : 'red';
		$V->{system}{"${service}_cpumem"} = $gotMemCpu ? 'true' : 'false';
		$V->{system}{"${service}_gurl"} = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=service&node=$NI->{system}{name}&intf=$service";

		# lets raise or clear an event 
		if ( $ret ) {
			# Service is UP!
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is available");
			checkEvent(sys=>$S,event=>"Service Down",level=>"Normal",element=>$ST->{$service}{Name},details=>"" );
		} else {
			# Service is down
			dbg("$ST->{$service}{Service_Type} $ST->{$service}{Name} is unavailable");
			notify(sys=>$S,event=>"Service Down",element=>$ST->{$service}{Name},details=>"" );
		}

		# save result for availability history - one file per service per node
		$Val{service}{value} = $ret*100;
		if ( $cpu < 0 ) {
			$cpu = $cpu * -1;
		}
		if ($gotMemCpu) {	
			$Val{cpu}{value} = $cpu;
			$Val{cpu}{option} = "COUNTER,U:U";
			$Val{memory}{value} = $memory;
			$Val{memory}{option} = "GAUGE,U:U";
		}
		if (( my $db = updateRRD(data=>\%Val,sys=>$S,type=>"service",item=>$service))) {
			$NI->{database}{service}{$service} = $db;
			$NI->{graphtype}{$service}{service} = 'service';
			if ($gotMemCpu) {	
				$NI->{graphtype}{$service}{service} = 'service,service-cpumem';
			}
		}
	} # foreach
END_runServices:
	dbg("Finished");
} # end runServices

#=========================================================================================

sub runCheckValues {
	my %args = @_;
	my $S = $args{sys};	# system object
	my $NI = $S->ndinfo;
	my $M = $S->mdl;	# Model table of node
	my $C = loadConfTable();

	if ($NI->{system}{nodedown} ne 'true' and $NI->{system}{snmpdown} ne 'true') {
		for my $sect ( keys %{$M->{system}{sys}} ) {
			my $control = $M->{system}{sys}{$sect}{control}; 	# check if skipped by control
			if ($control ne "") {
				dbg("control=$control found for section=$sect",2);
				if ($S->parseString(string=>"($control) ? 1:0") ne "1") {
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
	
	dbg("Starting node $NI->{system}{name}, type=$NI->{system}{nodeType}");

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
		# calculate mem
		if ( $RI->{memfree} > 0 and $RI->{memused} > 0 ) {
			$RI->{mem} = ( $RI->{memfree} * 100 ) / ($RI->{memused} + $RI->{memfree}) ;
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
	if ( $reach{availability} eq "" and $NI->{system}{collect} ne 'true' ) { 
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
			$reach{availability} = $reach{operStatus} / $reach{operCount}; 
		}

		if ($reach{reachability} > 100) { $reach{reachability} = 100; }
		($reach{responsetime},$responseWeight) = weightResponseTime($reach{responsetime});
		
		if ( $NI->{system}{collect} eq 'true' and $reach{cpu} ne "" ) {
			if    ( $reach{cpu} <= 10 ) { $cpuWeight = 100; }
			elsif ( $reach{cpu} <= 20 ) { $cpuWeight = 90; }
			elsif ( $reach{cpu} <= 30 ) { $cpuWeight = 80; }
			elsif ( $reach{cpu} <= 40 ) { $cpuWeight = 70; }
			elsif ( $reach{cpu} <= 50 ) { $cpuWeight = 60; }
			elsif ( $reach{cpu} <= 60 ) { $cpuWeight = 50; }
			elsif ( $reach{cpu} <= 70 ) { $cpuWeight = 40; }
			elsif ( $reach{cpu} <= 80 ) { $cpuWeight = 30; }
			elsif ( $reach{cpu} <= 90 ) { $cpuWeight = 20; }
			elsif ( $reach{cpu} <= 100 ) { $cpuWeight = 10; }

			if ( $reach{disk} ) {
				if    ( $reach{disk} <= 10 ) { $diskWeight = 100; }
				elsif ( $reach{disk} <= 20 ) { $diskWeight = 90; }
				elsif ( $reach{disk} <= 30 ) { $diskWeight = 80; }
				elsif ( $reach{disk} <= 40 ) { $diskWeight = 70; }
				elsif ( $reach{disk} <= 50 ) { $diskWeight = 60; }
				elsif ( $reach{disk} <= 60 ) { $diskWeight = 50; }
				elsif ( $reach{disk} <= 70 ) { $diskWeight = 40; }
				elsif ( $reach{disk} <= 80 ) { $diskWeight = 30; }
				elsif ( $reach{disk} <= 90 ) { $diskWeight = 20; }
				elsif ( $reach{disk} <= 100 ) { $diskWeight = 10; }
				
				dbg("Reach for Disk disk=$reach{disk} diskWeight=$diskWeight");
			}
			
			if    ( $reach{mem} >= 40 ) { $memWeight = 100; }
			elsif ( $reach{mem} >= 35 ) { $memWeight = 90; }
			elsif ( $reach{mem} >= 30 ) { $memWeight = 80; }
			elsif ( $reach{mem} >= 25 ) { $memWeight = 70; }
			elsif ( $reach{mem} >= 20 ) { $memWeight = 60; }
			elsif ( $reach{mem} >= 15 ) { $memWeight = 50; }
			elsif ( $reach{mem} >= 10 ) { $memWeight = 40; }
			elsif ( $reach{mem} >= 5 )  { $memWeight = 25; }
			elsif ( $reach{mem} >= 0 )  { $memWeight = 0; }
		}
		elsif ( $NI->{system}{collect} eq 'true' and $NI->{system}{nodeModel} eq "Generic" ) {
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

		if ( $NI->{system}{collect} eq 'true' and defined $S->{mdl}{interface}{nocollect}{ifDescr} ) {
			dbg("Getting Interface Utilisation Health");
			$intcount = 0;
			$intsummary = 0;
			# check if interface file exists - node may not be updated as yet....
			foreach my $index (keys %{$IF}) {
				# Don't do any stats cause the interface is not one we collect
				if ( $IF->{$index}{collect} eq 'true' ) { 
					# Get the link availability from the local node!!!
					my $util = getSummaryStats(sys=>$S,type=>"interface",start=>"-15 minutes",end=>time(),index=>$index);
					if ($util->{$index}{inputUtil} eq 'NaN' or $util->{$index}{outputUtil} eq 'NaN') {
						dbg("SummaryStats for interface=$index of node $NI->{system}{name} skipped because value is NaN");
						next;
					}
					$intsummary = $intsummary + ( 100 - $util->{$index}{inputUtil} ) + ( 100 - $util->{$index}{outputUtil} );
					++$intcount;
					dbg("Intf Summary in=$util->{$index}{inputUtil} out=$util->{$index}{outputUtil} intsumm=$intsummary count=$intcount");
				}
			} # FOR LOOP
			if ( $intsummary != 0 ) {
				$intWeight = sprintf( "%.2f", $intsummary / ( $intcount * 2 ));
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
		
		# Health is made up of a weighted values:
		### AS 16 Mar 02, implemented weights in nmis.conf
		if ( $reach{disk} ) {
			# use half of the weight allocation for interfaces
			$reach{health} = 	($reach{reachability} * $C->{weight_reachability}) + 
							($intWeight * ($C->{weight_int} / 2)) +
							($diskWeight * ($C->{weight_int} / 2)) +
							($responseWeight * $C->{weight_response}) + 
							($reach{availability} * $C->{weight_availability}) + 
							($cpuWeight * $C->{weight_cpu}) + 
							($memWeight * $C->{weight_mem})
							;
		}
		else {
			$reach{health} = 	($reach{reachability} * $C->{weight_reachability}) + 
							($intWeight * $C->{weight_int}) +
							($responseWeight * $C->{weight_response}) + 
							($reach{availability} * $C->{weight_availability}) + 
							($cpuWeight * $C->{weight_cpu}) + 
							($memWeight * $C->{weight_mem})
							;
		}
		dbg("Calculation of health=$reach{health}");
		if (lc $reach{health} eq 'nan') {
			dbg("Values Calc. reachability=$reach{reachability} * $C->{weight_reachability}");
			dbg("Values Calc. intWeight=$intWeight * $C->{weight_int}");
			dbg("Values Calc. responseWeight=$responseWeight * $C->{weight_response}");
			dbg("Values Calc. availability=$reach{availability} * $C->{weight_availability}");
			dbg("Values Calc. cpuWeight=$cpuWeight * $C->{weight_cpu}");
			dbg("Values Calc. memWeight=$memWeight * $C->{weight_mem}");
		}
	}
	elsif ( $NI->{system}{collect} ne 'true' and $pingresult == 100 ) {
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
	dbg("intWeight=$intWeight (100 less the actual total interface utilisation)");
	dbg("responseWeight=$responseWeight (normalised)");
	dbg("total number of interfaces=$reach{intfTotal}");
	dbg("total number of interfaces up=$reach{intfUp}");
	dbg("total number of interfaces collected=$reach{intfCollect}");
	dbg("total number of interfaces coll. up=$reach{intfColUp}");

	for $index ( sort keys %reach ) {
		dbg("$index=$reach{$index}");
	}

	$reach{health} = ($reach{health} > 100) ? 100 : $reach{health};
	my %reachVal;
	$reachVal{reachability}{value} = $reach{reachability};
	$reachVal{availability}{value} = $reach{availability};
	$reachVal{responsetime}{value} = $reach{responsetime};
	$reachVal{health}{value} = $reach{health};
	$reachVal{loss}{value} = $reach{loss};
	$reachVal{intfTotal}{value} = $reach{intfTotal};
	$reachVal{intfUp}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfUp};
	$reachVal{intfCollect}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfCollect};
	$reachVal{intfColUp}{value} = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfColUp};
	$reachVal{reachability}{option} = "gauge,0:100";
	$reachVal{availability}{option} = "gauge,0:100";
	$reachVal{responsetime}{option} = "gauge,0:U";
	$reachVal{health}{option} = "gauge,0:100";
	$reachVal{loss}{option} = "gauge,0:100";
	$reachVal{intfTotal}{option} = "gauge,0:U";
	$reachVal{intfUp}{option} = "gauge,0:U";
	$reachVal{intfCollect}{option} = "gauge,0:U";
	$reachVal{intfColUp}{option} = "gauge,0:U";

	if ((my $db = updateRRD(sys=>$S,data=>\%reachVal,type=>"health"))) {	# database name is 'reach'
		$NI->{database}{health} = $db;
	}
	$NI->{graphtype}{health} = $NI->{system}{nodeModel} eq 'PingOnly' ? "health-ping,response" : "health,response,numintf";

END_runReach:
	dbg("Finished");
} # end runHealth

#=========================================================================================

sub getIntfAllInfo {
	my $index;
	my $tmpDesc;
	my $intHash;
	my %interfaceInfo;

	dbg("Starting");

	dbg("Getting Interface Info from all nodes");

	my $NT = loadLocalNodeTable();

	# Write a node entry for each node
	foreach my $node (sort keys %{$NT}) {
		if ($NT->{$node}{active} eq 'true' and $NT->{$node}{collect} eq 'true') {
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
		if ($NT->{$node}{active} eq 'true') {
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

	if ($C->{server_master} eq "true") {
		dbg("Running NMIS Master Functions");
	
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			dbg("Master, processing Slave Server $srv");
			
			dbg("Get loadnodedetails from $srv");
			getFileFromRemote(server => $srv, func => "loadnodedetails", format => "text", file => "$C->{'<nmis_var>'}/nmis-${srv}-Nodes.nmis");

			dbg("Get sumnodetable from $srv");
			getFileFromRemote(server => $srv, func => "sumnodetable", format => "text", file => "$C->{'<nmis_var>'}/nmis-${srv}-nodesum.nmis");
						
			my @hours = qw(8 16);
			foreach my $hour (@hours) {
				my $function = "summary". $hour ."h";
				dbg("get summary$hour from $srv");
				getFileFromRemote(server => $srv, func => "summary$hour", format => "text", file => "$C->{'<nmis_var>'}/nmis-$srv-$function.nmis");
			}
		}
	}
}
		

#=========================================================================================

# preload all summary stats - for metric update and dashboard display.
sub nmisSummary {
	my %args = @_;

	dbg("Calculating NMIS network stats for cgi cache");

	my $S = Sys::->new;

	summaryCache(sys=>$S,file=>'nmis-summary8h',start=>'-8 hours',end=>time() );
	my $k = summaryCache(sys=>$S,file=>'nmis-summary16h', start=>'-16 hours', end=>'-8 hours' );
	
	my $NS = getNodeSummary(C => $C);
	my $file = "nmis-nodesum.nmis";
	writeTable(dir=>'var',name=>$file,data=>$NS);
	dbg("Finished calculating NMIS network stats for cgi cache - wrote $k nodes");
	
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
			if ( $NT->{$node}{active} eq 'true' ) {
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
				if ($NI->{system}{nodedown} eq 'true') {
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
### then in Ecalations.nmis, core devices might notify at Escalation0 while others at Escalation1
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

	# load Contacts table
	my $CT = loadContactsTable();

	# load the escalation policy table
	my $EST = loadEscalationsTable();

	# load the interface file to later check interface collect status.
	my $II = loadInterfaceInfo();

	my $LocationsTable = loadLocationsTable();
	my $ServiceStatusTable = loadGenericTable('ServiceStatus');
	my $BusinessServicesTable = loadGenericTable('BusinessServices');

	# Load the event table into the hash
	# have to maintain a lock over all of this
	# we are out of threading code now, so no great problem with holding the lock.
	my ($ET,$handle);
	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events');
	} else {
		($ET,$handle) = loadEventStateLock();
	}

	# add a full format time string for emails and message notifications
	# pull the system timezone and then the local time
	my $msgtime = get_localtime();

	# send UP events to all those contacts notified as part of the escalation procedure
	foreach $event_hash ( sort keys %{$ET} )  {
		next if $ET->{$event_hash}{current} eq 'true';

		foreach my $field ( split(',',$ET->{$event_hash}{notify}) ) { # field = type:contact
			$target = "";
			my @x = split /:/ , $field;
			my $type = shift @x;			# netsend, email, or pager ?
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
				if ( $target ) {
					foreach my $trgt ( split /,/, $target ) {
						my $message;
						my $priority;
						if ( $type eq "pager" ) {
							$msgTable{$type}{$trgt}{$serial_ns}{message} = "NMIS: UP Notify $ET->{$event_hash}{node} Normal $ET->{$event_hash}{event} $ET->{$event_hash}{element}";
							$serial_ns++ ;
						} else {
							if ($type eq "ccopy") { 
								$message = "FOR INFORMATION ONLY\n";
								$priority = &eventToSMTPPri("Normal");
							} else {
								$priority = &eventToSMTPPri($ET->{$event_hash}{level}) ;
							}
							$event_age = convertSecsHours(time - $ET->{$event_hash}{startdate});
							
							$message .= "Node:\t$ET->{$event_hash}{node}\nUP Event Notification\nEvent Elapsed Time:\t$event_age\nEvent:\t$ET->{$event_hash}{event}\nElement:\t$ET->{$event_hash}{element}\nDetails:\t$ET->{$event_hash}{details}\n";
							if ($C->{mail_combine} eq "true" ) {
								$msgTable{$type}{$trgt}{$serial}{count}++;
								$msgTable{$type}{$trgt}{$serial}{subject} = "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
								$msgTable{$type}{$trgt}{$serial}{message} .= $message ;
								if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} ) {
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
					logEvent(node => $ET->{$event_hash}{node}, event => "$type to $target UP Notify", level => "Normal", element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});
					dbg("Escalation $type UP Notification node=$ET->{$event_hash}{node} target=$target level=$ET->{$event_hash}{level} event=$ET->{$event_hash}{event} element=$ET->{$event_hash}{element} details=$ET->{$event_hash}{details} group=$NT->{$ET->{$event_hash}{node}}{group}");
				}
			} # end email,ccopy,pager
			# now the netsends
			elsif ( $type eq "netsend" ) {
				my $message = "UP Event Notification $ET->{$event_hash}{node} Normal $ET->{$event_hash}{event} $ET->{$event_hash}{element} $ET->{$event_hash}{details} at $msgtime";
				foreach my $trgt ( @x ) {
					$msgTable{$type}{$trgt}{$serial_ns}{message} = $message ;
					$serial_ns++;
					dbg("NetSend $message to $trgt");
					logEvent(node => $ET->{$event_hash}{node}, event => "NetSend $message to $trgt UP Notify", level => "Normal", element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});
				} #foreach
			} # end netsend
			elsif ( $type eq "syslog" ) {
				my $timenow = time();
				my $message = "NMIS_Event::$C->{nmis_host}::$timenow,$ET->{$event_hash}{node},$ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
				my $priority = eventToSyslog($ET->{$event_hash}{level});
				if ( $C->{syslog_use_escalation} eq "true" ) {
					foreach my $trgt ( @x ) {
						$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
						$msgTable{$type}{$trgt}{$serial_ns}{priority} = $priority;
						$serial_ns++;
						dbg("syslog $message");
					} #foreach
				}
			} # end syslog
			elsif ( $type eq "json" ) {
				# make it an up event.
				my $event = $ET->{$event_hash};
				my $node = $NT->{$event->{node}};
				$event->{nmis_server} = $C->{nmis_host};				
				$event->{location} = $LocationsTable->{$node->{location}}{Location};
				$event->{geocode} = $LocationsTable->{$node->{location}}{Geocode};
				$event->{serviceStatus} = $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
				$event->{statusPriority} = $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
				$event->{businessService} = $BusinessServicesTable->{$node->{businessService}}{businessService};
				$event->{businessPriority} = $BusinessServicesTable->{$node->{businessService}}{businessPriority};
				logJsonEvent(event => $event, dir => $C->{'json_logs'});
			} # end json
			else {
				dbg("ERROR runEscalate problem with escalation target unknown at level$ET->{$event_hash}{escalate} $level type=$type");
			}
		}
	
		# remove this entry
		if ($C->{db_events_sql} eq 'true') {
			DBfunc::->delete(table=>'Events',index=>$event_hash);
		} else {
			delete $ET->{$event_hash};
		}
		dbg("event entry $event_hash deleted");
	}

	#===========================================

	# now handle escalations
LABEL_ESC:
	foreach $event_hash ( keys %{$ET} )  {
		dbg("process event with event_hash=$event_hash");
		my $nd = $ET->{$event_hash}{node};
		# lets start with checking that we have a valid node -the node may have been deleted.
		if ( $ET->{$event_hash}{current} eq 'true' and $NT->{$nd}{active} eq 'false') {
			logEvent(node => $nd, event => "Deleted Event: $ET->{$event_hash}{event}", level => $ET->{$event_hash}{level}, element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});
			logMsg("INFO ($nd) Node not active, deleted Event=$ET->{$event_hash}{event} Element=$ET->{$event_hash}{element}");

			my $timenow = time();
			my $message = "NMIS_Event::$C->{nmis_host}::$timenow,$ET->{$event_hash}{node},Deleted Event: $ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
			my $priority = eventToSyslog($ET->{$event_hash}{level});
			sendSyslog(
				server_string => $C->{syslog_server},
				facility => $C->{syslog_facility},
				message => $message,
				priority => $priority
			);
			
			delete $ET->{$event_hash};
			if ($C->{db_events_sql} eq 'true') {
				DBfunc::->delete(table=>'Events',index=>$event_hash);
			}
			
			my $message = "event_hash=$event_hash nd=$nd node=$ET->{$event_hash}{node} active=$NT->{$nd}{active}";
			dbg($message);			

			next LABEL_ESC;
		}

		my $tmpDesc = convertIfName($ET->{$event_hash}{element});
		if ( $ET->{$event_hash}{event} =~ /interface/i 
			and $ET->{$event_hash}{event} !~ /proactive/i 
			and $II->{"$ET->{$event_hash}{node}-$tmpDesc"}{collect} ne 'true' 
		) {
			logEvent(node => $ET->{$event_hash}{node}, event => "Deleted Event: $ET->{$event_hash}{event}", level => $ET->{$event_hash}{level}, element => " no matching interface or no collect Element=$ET->{$event_hash}{element}");
			logMsg("INFO ($ET->{$event_hash}{node}) Interface not active, deleted Event=$ET->{$event_hash}{event} Element=$ET->{$event_hash}{element}");
			delete $ET->{$event_hash};
			if ($C->{db_events_sql} eq 'true') {
				DBfunc::->delete(table=>'Events',index=>$event_hash);
			}
			next LABEL_ESC;
		}

		# if an planned outage is in force, keep writing the start time of any unack event to the current start time
		# so when the outage expires, and the event is still current, we escalate as if the event had just occured
		my ($outage,undef) = outageCheck(node=>$ET->{$event_hash}{node},time=>time());
		dbg("Outage for $ET->{$event_hash}{node} is $outage");
		if ( $outage eq "current" and $ET->{$event_hash}{ack} eq "false" ) {
			$ET->{$event_hash}{startdate} = time();
			if ($C->{db_events_sql} eq 'true') {
				DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
			}
		}
		# set the current outage time
		$outage_time = time() - $ET->{$event_hash}{startdate};

		# if we are to escalate, this event must not be part of a planned outage and un-ack.
		if ( $outage ne "current" and $ET->{$event_hash}{ack} eq "false") {
		# we have list of nodes that this node depends on in $NT->{$runnode}{depend}
		# if any of those have a current Node Down alarm, then lets just move on with a debug message
		# should we log that we have done this - maybe not....
	
		if ( $NT->{$ET->{$event_hash}{node}}{depend} ne '') {
			foreach my $node_depend ( split /,/ , $NT->{$ET->{$event_hash}{node}}{depend} ) {
				next if $node_depend eq "N/A" ;		# default setting
				next if $node_depend eq $ET->{$event_hash}{node};	# remove the catch22 of self dependancy.
				my $eh = eventHash($node_depend,"Node Down","");
				if ( exists $ET->{$eh}{current} ) {
					dbg("NOT escalating $ET->{$event_hash}{node} $ET->{$event_hash}{event} as dependant $node_depend is reported as down");
					next LABEL_ESC;
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
		my $NI = loadNodeInfoTable($ET->{$event_hash}{node});
		$group = lc($NI->{system}{group});
		$role = lc($NI->{system}{roleType});
		$type = lc($NI->{system}{nodeType});

		# trim the (proactive) event down to the first 4 keywords or less.
		$event = "";
		my $i = 0;
		foreach $index ( split /( )/ , lc($ET->{$event_hash}{event}) ) {		# the () will pull the spaces as well into the list, handy !
			$event .= $index;
			last if $i++ == 6;				# max of 4 splits, with no trailing space.
		}
	
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
				$EST->{$esc}{Event_Element} =~ s;/;;g;
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

			foreach $esc_key ( keys %keyhash ) {
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

					if ( $level ne "" ) {
						# Now we have a string, check for multiple notify types
						foreach $field ( split "," , $level ) {
							$target = "";
							@x = split /:/ , lc $field;
							$type = shift @x;			# first entry is email, ccopy, netsend or pager
							if ( $type =~ /email|ccopy|pager/ ) {
								foreach $contact (@x) {
									# if sysContact, use device syscontact as key into the contacts table hash
									if ( $contact eq "syscontact") {
										if ($NI->{sysContact} ne '') {
											$contact = lc $NI->{sysContact};
											dbg("Using node $ET->{$event_hash}{node} sysContact $NI->{sysContact}");
										} else {
											$contact = 'default';
										}
									}

									# check if UpNotify is true, and save with this event
									# and send all the up event notifies when the event is cleared.
									if ( $EST->{$esc_key}{UpNotify} eq "true" and $ET->{$event_hash}{event} =~ /down|proactive/i) {
										my $ct = "$type:$contact";
										my @l = split(',',$ET->{$event_hash}{notify});
										if (not grep { $_ eq $ct } @l ) {
											push @l, $ct;
											$ET->{$event_hash}{notify} = join(',',@l);
										}
									}

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
								if ( $target ) {
									foreach my $trgt ( split /,/, $target ) {
										my $message;
										my $priority;
										if ( $type eq "pager" ) {
											$msgTable{$type}{$trgt}{$serial_ns}{message} = "NMIS: Esc. $ET->{$event_hash}{escalate} $event_age $ET->{$event_hash}{node} $ET->{$event_hash}{level} $ET->{$event_hash}{event} $ET->{$event_hash}{details}";
											$serial_ns++ ;
										} else {
											if ($type eq "ccopy") { 
												$message = "FOR INFORMATION ONLY\n";
												$priority = &eventToSMTPPri("Normal");
											} else {
												$priority = &eventToSMTPPri($ET->{$event_hash}{level}) ;
											}
											
											$C->{nmis_host_protocol} = "http" if $C->{nmis_host_protocol} eq "";
											$message .= "Node:\t$ET->{$event_hash}{node}\nNotification at Level$ET->{$event_hash}{escalate}\nEvent Elapsed Time:\t$event_age\nSeverity:\t$ET->{$event_hash}{level}\nEvent:\t$ET->{$event_hash}{event}\nElement:\t$ET->{$event_hash}{element}\nDetails:\t$ET->{$event_hash}{details}\n$C->{nmis_host_protocol}://$C->{nmis_host}$C->{network}?act=network_node_view&widget=false&node=$ET->{$event_hash}{node}\n\n";
											if ($C->{mail_combine} eq "true" ) {
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
									logEvent(node => $ET->{$event_hash}{node}, event => "$type to $target Esc$ET->{$event_hash}{escalate} $ET->{$event_hash}{event}", level => $ET->{$event_hash}{level}, element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});
									dbg("Escalation $type Notification node=$ET->{$event_hash}{node} target=$target level=$ET->{$event_hash}{level} event=$ET->{$event_hash}{event} element=$ET->{$event_hash}{element} details=$ET->{$event_hash}{details} group=$NT->{$ET->{$event_hash}{node}}{group}");
								} # if $target
							} # end email,ccopy,pager
							# now the netsends
							elsif ( $type eq "netsend" ) {
								my $message = "Escalation $ET->{$event_hash}{escalate} $ET->{$event_hash}{node} $ET->{$event_hash}{level} $ET->{$event_hash}{event} $ET->{$event_hash}{element} $ET->{$event_hash}{details} at $msgtime";
								foreach my $trgt ( @x ) {
									$msgTable{$type}{$trgt}{$serial_ns}{message} = $message ;
									$serial_ns++;
									dbg("NetSend $message to $trgt");
									logEvent(node => $ET->{$event_hash}{node}, event => "NetSend $message to $trgt $ET->{$event_hash}{event}", level => $ET->{$event_hash}{level}, element => $ET->{$event_hash}{element}, details => $ET->{$event_hash}{details});
								} #foreach
							} # end netsend
							elsif ( $type eq "syslog" ) {
								# check if UpNotify is true, and save with this event
								# and send all the up event notifies when the event is cleared.
								if ( $EST->{$esc_key}{UpNotify} eq "true" and $ET->{$event_hash}{event} =~ /down|proactive/i) {
									my $ct = "$type:server";
									my @l = split(',',$ET->{$event_hash}{notify});
									if (not grep { $_ eq $ct } @l ) {
										push @l, $ct;
										$ET->{$event_hash}{notify} = join(',',@l);
									}
								}
								my $timenow = time();
								my $message = "NMIS_Event::$C->{nmis_host}::$timenow,$ET->{$event_hash}{node},$ET->{$event_hash}{event},$ET->{$event_hash}{level},$ET->{$event_hash}{element},$ET->{$event_hash}{details}";
								my $priority = eventToSyslog($ET->{$event_hash}{level});
								if ( $C->{syslog_use_escalation} eq "true" ) {
									foreach my $trgt ( @x ) {
										$msgTable{$type}{$trgt}{$serial_ns}{message} = $message;
										$msgTable{$type}{$trgt}{$serial}{priority} = $priority;
										$serial_ns++;
										dbg("syslog $message");
									} #foreach
								}
							} # end syslog
							elsif ( $type eq "json" ) {
								if ( $EST->{$esc_key}{UpNotify} eq "true" and $ET->{$event_hash}{event} =~ /down|proactive/i) {
									my $ct = "$type:server";
									my @l = split(',',$ET->{$event_hash}{notify});
									if (not grep { $_ eq $ct } @l ) {
										push @l, $ct;
										$ET->{$event_hash}{notify} = join(',',@l);
									}
								}
								# copy the event
								my $event = $ET->{$event_hash};
								my $node = $NT->{$event->{node}};
								$event->{nmis_server} = $C->{nmis_host};
								$event->{location} = $LocationsTable->{$node->{location}}{Location};
								$event->{geocode} = $LocationsTable->{$node->{location}}{Geocode};
								$event->{serviceStatus} = $ServiceStatusTable->{$node->{serviceStatus}}{serviceStatus};
								$event->{statusPriority} = $ServiceStatusTable->{$node->{serviceStatus}}{statusPriority};
								$event->{businessService} = $BusinessServicesTable->{$node->{businessService}}{businessService};
								$event->{businessPriority} = $BusinessServicesTable->{$node->{businessService}}{businessPriority};
								logJsonEvent(event => $event, dir => $C->{'json_logs'});
							} # end json
							else {
								dbg("ERROR runEscalate problem with escalation target unknown at level$ET->{$event_hash}{escalate} $level type=$type");
							}
						} # foreach field
					} # endif $level
				} # if escalate
			} # foreach esc_key
		} # end of outage check
		if ($C->{db_events_sql} eq 'true') {
			DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
		}
	} # foreach $event_hash
	# now write the hash back and release the lock
	if ($C->{db_events_sql} ne 'true') {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}
	# Cologne, send the messages now
	sendMSG(data=>\%msgTable);
	dbg("Finished");
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
		if ($method eq "email") {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					next if $C->{mail_server} eq '';
					sendEmail(
						to => $target, 
						subject => $$msgTable{$method}{$target}{$serial}{subject},
						body => $$msgTable{$method}{$target}{$serial}{message},
						from => $C->{mail_from}, 
						server => $C->{mail_server}, 
						domain => $C->{mail_domain},
						use_sasl => $C->{mail_use_sasl},
						port => $C->{mail_server_port},
						user => $C->{mail_user},						
						password => $C->{mail_password},						
						priority => $$msgTable{$method}{$target}{$serial}{priority},
						debug => $C->{debug}
					);
					dbg("Escalation Email Notification sent to $target");
				}
			}
		} # end email
		### Carbon copy notifications - no action required - FYI only.
		elsif ( $method eq "ccopy" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					next if $C->{mail_server} eq '';
					sendEmail(
						to => $target, 
						subject => $$msgTable{$method}{$target}{$serial}{subject}, 
						body => $$msgTable{$method}{$target}{$serial}{message},
						from => $C->{mail_from}, 
						server => $C->{mail_server}, 
						domain => $C->{mail_domain},
						use_sasl => $C->{mail_use_sasl},
						port => $C->{mail_server_port},
						user => $C->{mail_user},						
						password => $C->{mail_password},						
						priority => $$msgTable{$method}{$target}{$serial}{priority},
						debug => $C->{debug}
					);
					dbg("Escalation CC Email Notification sent to $target");
				}
			}
		} # end ccopy
		# now the netsends
		elsif ( $method eq "netsend" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					# read any stdout messages and throw them away
					if ($^O =~ /win32/i) {
						# win32 platform
						my $dump=`net send $target $$msgTable{$method}{$target}{$serial}{message}`;
					}
					else {
						# Linux box
						my $dump=`echo $$msgTable{$method}{$target}{$serial}{message}|smbclient -M $target`;
					}
					dbg("netsend $$msgTable{$method}{$target}{$serial}{message} to $target");
				} # end netsend
			}
		}
		# now the syslog
		elsif ( $method eq "syslog" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
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
		elsif ( $type eq "pager" ) {
			foreach $target (keys %{$msgTable->{$method}}) {
				foreach $serial (keys %{$msgTable->{$method}{$target}}) {
					next if $C->{snpp_server} eq '';
					sendSNPP(
						server => $C->{snpp_server},
						pagerno => $target,
						message => $$msgTable{$method}{$target}{$serial}{message}
					);
					dbg(" SendSNPP to $target");
				}
			} # end pager
		}
		else {
			dbg("ERROR unknown device $method");
		}
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
	$data->{responsetime}{option} = "gauge,0:U";
	$data->{health}{option} = "gauge,0:100";
	$data->{status}{option} = "gauge,0:100";
	$data->{intfCollect}{option} = "gauge,0:U";
	$data->{intfColUp}{option} = "gauge,0:U";
	$data->{intfAvail}{option} = "gauge,0:U";

	dbg("Doing Network Metrics database reach=$data->{reachability}{value} avail=$data->{availability}{value} resp=$data->{responsetime}{value} health=$data->{health}{value} status=$data->{status}{value}");
	#
	if ((my $db = updateRRD(data=>$data,sys=>$S,type=>"metrics",item=>'network'))) {
		$NI->{database}{metrics}{network} = $db;
		$NI->{graphtype}{metrics} = "metrics";
	}
	#
	foreach $group (sort keys %{$GT}) {
		$groupSummary = getGroupSummary(group=>$group);
		$status = overallNodeStatus($group);
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
		if (( my $db = updateRRD(data=>$data,sys=>$S,type=>"metrics",item=>$group))) {
			$NI->{database}{metrics}{$group} = $db;
			$NI->{graphtype}{metrics} = "metrics";
		}
		#
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

	dbg("Start");

	if (!($II = loadInterfaceInfo())) {
		logMsg("ERROR reading all interface info");
		goto END_runLinks;
	}

	if ($C->{db_links_sql} eq 'true') {
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
					 $II->{$intHash}{collect} eq "true" and $II->{$intHash}{ifType} =~ /$qr_link_ifTypes/) {
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
			if ($C->{db_links_sql} eq 'true') {
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

			if ($C->{db_links_sql} eq 'true') {
				if (not exists $links->{$subnet}{subnet}) {
					DBfunc::->update(table=>'Links',data=>$links->{$subnet},index=>$subnet);
				}
			}
			dbg("Adding link $links->{$subnet}{link} for $subnet to links");
		}
	}
	$links = {} if !$links;
	if ($C->{db_links_sql} ne 'true') {
		writeTable(dir=>'conf',name=>'Links',data=>$links);
	}
	logMsg("Check table Links and update link names and other entries");

END_runLinks:
	dbg("Finished");
}


#=========================================================================================

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
	if ( $C->{daemon_fping_active} eq 'true' ) {
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
	if ( $C->{daemon_ipsla_active} eq 'true' ) {
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

	# check if nmis_base already oke
	if (!(-e "$C->{'<nmis_base>'}/bin/nmis.pl")) {
	
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
and verify that $nmis_base/conf/Config.nmis reflects 
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
		print "\n Root directory of NMIS is $C->{'<nmis_base>'}\n\n";
	}
	
	# Do the var directories exist if not make them?
	dbg("Config Checking - Checking var directories, $C->{'<nmis_var>'}");
	if ($C->{'<nmis_var>'} ne '') {
		createDir("$C->{'<nmis_var>'}");
	}

	# Do the log directories exist if not make them?
	dbg("Config Checking - Checking log directories, $C->{'<nmis_logs>'}");
	if ($C->{'<nmis_logs>'} ne '') {
		createDir("$C->{'<nmis_logs>'}");
		createDir("$C->{'json_logs'}");
		createDir("$C->{'config_logs'}");
	}

	# Do the conf directories exist if not make them?
	dbg("Config Checking - Checking conf directories, $C->{'<nmis_conf>'}");
	if ($C->{'<nmis_conf>'} ne '') {
		createDir("$C->{'<nmis_conf>'}");
	}
		
	# Do the database directories exist if not make them?
	dbg("Config Checking - Checking database directories");
	if ($C->{database_root} ne '') {
		createDir("$C->{database_root}");
		createDir("$C->{database_root}/health");
		createDir("$C->{database_root}/metrics");
		createDir("$C->{database_root}/misc");
		createDir("$C->{database_root}/ipsla");
		createDir("$C->{database_root}/health/generic");
		createDir("$C->{database_root}/health/router");
		createDir("$C->{database_root}/health/switch");
		createDir("$C->{database_root}/health/server");
		createDir("$C->{database_root}/health/firewall");
		createDir("$C->{database_root}/interface");
		createDir("$C->{database_root}/interface/generic");
		createDir("$C->{database_root}/interface/router");
		createDir("$C->{database_root}/interface/switch");
		createDir("$C->{database_root}/interface/server"); 
		createDir("$C->{database_root}/interface/firewall"); 
	} else {
		print "\n Cannot create directories because database_root is not defined in NMIS config\n";
	}

	# create files
	if ( not existFile(dir=>'logs',name=>'nmis.log')) { 
		open(LOG,">>$C->{'<nmis_logs>'}/nmis.log");
		close LOG;
		setFileProt("$C->{'<nmis_logs>'}/nmis.log");
	}
	if ( not existFile(dir=>'var',name=>'nmis-event')) {
		my ($hsh,$handle) = loadTable(dir=>'var',name=>'nmis-event');
		writeTable(dir=>'var',name=>'nmis-event',data=>$hsh);
	}
	if ( not existFile(dir=>'var',name=>'nmis-system')) {
		my ($hsh,$handle) = loadTable(dir=>'var',name=>'nmis-system');
		$hsh->{startup} = time();
		writeTable(dir=>'var',name=>'nmis-system',data=>$hsh);
	}

	#== convert config .csv to .nmis (hash) file format ==
	convertConfFiles();
	#==
	
	print " Continue with bin/nmis.pl type=apache for configuration rules of the Apache web server\n\n";
}


#=========================================================================================

sub printCrontab {

	my $C = loadConfTable();

	dbg(" Crontab Config for NMIS for config file=$nvp{conf}",3);

	print <<EO_TEXT;
MAILTO=WhoeverYouAre\@yourdomain.tld 
######################################################
# NMIS8 Config
######################################################
# Run Statistics Collection
*/5 * * * * $C->{'<nmis_base>'}/bin/nmis.pl type=collect mthread=true maxthreads=10
######################################################
# Run Summary Update every 2 minutes
*/2 * * * * /usr/local/nmis8/bin/nmis.pl type=summary
#####################################################
# Run the interfaces 4 times an hour with Thresholding on!!!
# if threshold_poll_cycle is set to false, then enable cron based thresholding
#*/15 * * * * nice $C->{'<nmis_base>'}/bin/nmis.pl type=threshold mthread=true maxthreads=10
######################################################
# Run the update once a day 
30 20 * * * nice $C->{'<nmis_base>'}/bin/nmis.pl type=update mthread=true maxthreads=10
######################################################
# Check to rotate the logs 4am every day UTC
5 20 * * * /usr/sbin/logrotate $C->{'<nmis_base>'}/conf/logrotate.conf
##################################################
# save this crontab every day
0 8 * * * crontab -l > $C->{'<nmis_base>'}/conf/crontab.root
########################################
# Run the Reports Weekly Monthly Daily
# daily
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day health
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day top10
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day outage
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day response
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day avail
0 0 * * * /usr/local/nmis8/bin/run-reports.pl day port
# weekly
0 0 * * 0 /usr/local/nmis8/bin/run-reports.pl week health
0 0 * * 0 /usr/local/nmis8/bin/run-reports.pl week top10
0 0 * * 0 /usr/local/nmis8/bin/run-reports.pl week outage
0 0 * * 0 /usr/local/nmis8/bin/run-reports.pl week response
0 0 * * 0 /usr/local/nmis8/bin/run-reports.pl week avail
# monthly
0 0 1 * * /usr/local/nmis8/bin/run-reports.pl month health
0 0 1 * * /usr/local/nmis8/bin/run-reports.pl month top10
0 0 1 * * /usr/local/nmis8/bin/run-reports.pl month outage
0 0 1 * * /usr/local/nmis8/bin/run-reports.pl month response
0 0 1 * * /usr/local/nmis8/bin/run-reports.pl month avail
###########################################
EO_TEXT
}

#=========================================================================================

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
<Directory "$C->{view_root}">
		Options Indexes FollowSymLinks MultiViews
		AllowOverride None
		Order allow,deny
		Allow from all
</Directory>

Alias $C->{'<menu_url_base>'}/ "$C->{'<nmis_menu>'}/"
<Directory "$C->{'<menu_url_base>'}">
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
$0 NMIS Polling Engine - Network Management Information System
Copyright (C) 2007 NMIS Development Team
Version $NMIS::VERSION

command line options are:
	type=<option>          Where <option> is one of the following:
													 collect   NMIS will collect all statistics;
													 update    Update all the dynamic NMIS configuration
													 threshold Calculate thresholds
													 master    Run NMIS Master Functions
													 escalate  Run the escalation routine only ( debug use only)
													 config    Validate the chosen configuration file
													 apache    Produce Apache configuration for NMIS
													 crontab   Produce Crontab configuration for NMIS
													 links     Generate the links.csv file.
													 rme       Read and generate a node.csv file from a Ciscoworks RME file
	[conf=<file name>]     Optional alternate configuation file in directory /conf;
	[node=<node name>]     Run operations on a single node;
	[group=<group name>]   Run operations on all nodes in the names group;
	[debug=true|false|0-9] default=false - Show debuging information, handy;
	[rmefile=<file name>]  RME file to import.
	[mthread=true|false]   default=false - Enable Multithreading or not;
	[mthreaddebug=true|false] default=false - Enable Multithreading debug or not;
	[maxthreads=<1..XX>]  default=2 - How many threads should nmis create;

EO_TEXT
}

#=========================================================================================

sub getAdminColor {
	my %args = @_;
	my $S = $args{sys};
	my $index = $args{index};
	my $IF = $S->ifinfo;
	my $adminColor;
	if ( $IF->{$index}{ifAdminStatus} =~ /down|testing|null/ or $IF->{$index}{collect} ne "true" ) {
		$adminColor="#ffffff";
	} else {
		$adminColor="#00ff00";
	}
	return $adminColor;
}

#=========================================================================================

sub getOperColor {
	my %args = @_;
	my $S = $args{sys};		# object
	my $index = $args{index}; # index
	my $NI = $S->ndinfo;	# node info
	my $IF = $S->ifinfo;	# interface info
	my $node = $S->{node};	# node name lc
	my $operColor;

	if ( $IF->{$index}{ifAdminStatus} =~ /down|testing|null/ or $IF->{$index}{collect} ne "true") {
		$operColor="#ffffff"; # white
	} else {
		if ($IF->{$index}{ifOperStatus} eq 'down') {
			# red for down
			$operColor = "#ff0000";
		} elsif ($IF->{$index}{ifOperStatus} eq 'dormant') {
			# yellow for dormant
			$operColor = "#ffff00";
		} else { $operColor = "#00ff00"; } # green
	}
	return $operColor;
}

#=========================================================================================

sub runThreshold {
	my $node = shift;

	if ( $C->{global_threshold} eq "true" or $C->{global_threshold} ne "false" ) {
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
		if ($NT->{$nd}{active} eq 'true' and $NT->{$nd}{collect} eq 'true') {
			if (($S->init(name=>$nd,snmp=>'false'))) { # get all info of node
				$M = $S->mdl; # model ref
				$NI = $S->ndinfo; # node info
				$IF = $S->ifinfo; # interface info

				next if $NI->{system}{nodedown} eq 'true';

				foreach my $tp (keys %{$M->{summary}{statstype}}) { # oke, look for requests in summary of Model 
					# check for indexed
					if (ref $NI->{database}{$tp} eq "HASH") {
						foreach my $i (keys %{$NI->{database}{$tp}}) {
							my $sts = getSummaryStats(sys=>$S,type=>$tp,start=>"-15 minutes",end=>'now',index=>$i);
							# save all info in %sts for threshold run
							foreach (keys %{$sts->{$i}}) { $stats{$nd}{$tp}{$i}{$_} = $sts->{$i}{$_}; }
							# 
							foreach my $nm (keys %{$M->{summary}{statstype}{$tp}{sumname}}) {
								$stshlth{$M->{node}{nodeType}}{$nd}{$nm}{$i}{Description} = $NI->{label}{$tp}{$i}; # descr
								# check if threshold level available, thresholdname must be equal to type
								if (exists $M->{threshold}{name}{$tp}) {
									($stshlth{$M->{node}{nodeType}}{$nd}{$nm}{$i}{level},undef,undef) = 
										getThresholdLevel(sys=>$S,thrname=>$tp,stats=>$sts,index=>$i);
								}
								# save values
								foreach my $stsname (@{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}}) {
									$stshlth{$M->{node}{nodeType}}{$nd}{$nm}{$i}{$stsname} = $sts->{$i}{$stsname};
									dbg("stored summary health node=$nd type=$tp name=$stsname index=$i value=$sts->{$i}{$stsname}");
								}
							}
						}
					} else {
						if (exists $NI->{database}{$tp}) {
							my $sts = getSummaryStats(sys=>$S,type=>$tp,start=>"-15 minutes",end=>'now');							
							# save all info in %sts for threshold run
							foreach (keys %{$sts}) { $stats{$nd}{$tp}{$_} = $sts->{$_}; }
							# check if threshold level available, thresholdname must be equal to type
							if (exists $M->{threshold}{name}{$tp}) {
								($stshlth{$M->{node}{nodeType}}{$nd}{"${tp}_level"},undef,undef) = 
									getThresholdLevel(sys=>$S,thrname=>$tp,stats=>$sts,index=>'');
							}
							foreach my $nm (keys %{$M->{summary}{statstype}{$tp}{sumname}}) {
								foreach my $stsname (@{$M->{summary}{statstype}{$tp}{sumname}{$nm}{stsname}}) {
									$stshlth{$M->{node}{nodeType}}{$nd}{$stsname} = $sts->{$stsname};
									dbg("stored summary health node=$nd type=$tp name=$stsname value=$sts->{$stsname}");
								}
							}
						}
					}
				}
				# get all collected interfaces
				foreach my $index (keys %{$IF}) {
					next unless $IF->{$index}{collect} eq 'true';
					my $sts = getSummaryStats(sys=>$S,type=>'interface',start=>'-15 minutes',end=>time(),index=>$index);
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

	my $NT = loadLocalNodeTable();

	my $S = Sys::->new; # create system object

	$S->{ET} = loadEventStateNoLock(); # for speeding up, from file or DB

	foreach my $nd (sort keys %{$NT}) {
		next if $node ne "" and $node ne lc($nd); # check for single node thresholds
		### 2012-09-03 keiths, changing as pingonly nodes not being thresholded, found by Lenir Santiago
		#if ($NT->{$nd}{active} eq 'true' and $NT->{$nd}{collect} eq 'true' and $NT->{$nd}{threshold} eq 'true') {
		if ($NT->{$nd}{active} eq 'true' and $NT->{$nd}{threshold} eq 'true') {
			if (($S->init(name=>$nd,snmp=>'false'))) { # get all info of node
				my $NI = $S->ndinfo; # pointer to node info table
				my $M  = $S->mdl;	# pointer to Model table

				# skip if node down
				if ( $NI->{system}{nodedown} eq 'true') {
					dbg("Node down, skipping thresholding for $S->{name}");
					next;
				} 

				dbg("Starting Thresholding node=$S->{name}");
			
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
									dbg("control=$control found for type=$type",2);
									if ($S->parseString(string=>"($control) ? 1:0") ne "1") {
										dbg("threshold of type $type skipped by control=$control");
										next;
									}
								}
								if ($M->{$s}{$ts}{$type}{threshold} ne "") {
									$thrname = $M->{$s}{$ts}{$type}{threshold};	# get string of threshold names
									dbg("threshold=$thrname found in type=$type");
									# thresholds found in this section
									if ($M->{$s}{$ts}{$type}{indexed} eq 'true') {	# if indexed then all checked
										foreach my $index (keys %{$NI->{database}{$type}}) { # there must be a rrd file
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
			}
		}
	}
	$S->{ET} = ''; # done
	dbg("Finished");
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

	#	check if values are already in table (done by doSummaryBuild)
	if (exists $sts->{$S->{name}}{$type}) {
		$stats = $sts->{$S->{name}}{$type};
	} else {
		$stats = getSummaryStats(sys=>$S,type=>$type,start=>"-15 minutes",end=>'now',index=>$index);
	}

	# get name of element
	if ($index eq '') {
		$element = '';
	} 
	elsif ($index ne '' and $thrname eq "env_temp" ) {
		$element = $ET->{$index}{tempDescr};
	}	
	else {
		$element = $IF->{$index}{ifDescr};
	}

	# walk through threshold names
	### 2012-04-25 keiths, fixing loop as not processing correctly.
	$thrname = stripSpaces($thrname);
	my @nm_list = split(/,/,$thrname);
	foreach my $nm (@nm_list) {
		dbg("processing threshold $nm");
		my ($level,$value,$thrvalue,$reset) = getThresholdLevel(sys=>$S,thrname=>$nm,stats=>$stats,index=>$index);
		# get 'Proactive ....' string of Model
		my $event = $S->parseString(string=>$M->{threshold}{name}{$nm}{event},index=>$index);
		thresholdProcess(sys=>$S,event=>$event,level=>$level,element=>$element,value=>$value,thrvalue=>$thrvalue,reset=>$reset);
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
		dbg("event=$args{event}, level=$args{level}, element=$args{element}, value=$args{value}, reset=$args{reset}");
	###	logMsg("INFO ($S->{node}) event=$args{event}, level=$args{level}, element=$args{element}, value=$args{value}, reset=$args{reset}");
		if ( $args{value} !~ /NaN/i ) {
			if ( $args{level} =~ /Normal/i ) { 
				checkEvent(sys=>$S,event=>$args{event},level=>$args{level},element=>$args{element},
						details=>"Value=$args{value}, Threshold=$args{thrvalue}",value=>$args{value},reset=>$args{reset});
			}
			else {
				notify(sys=>$S,event=>$args{event},level=>$args{level},element=>$args{element},details=>"Value=$args{value}, Threshold=$args{thrvalue}");
			}
		}
	}
}

sub getPidFileName {
	my $PIDFILE = "$C->{'<nmis_var>'}/nmis.pid";
	if ($C->{conf} ne "") {
		$PIDFILE = "$C->{'<nmis_var>'}/nmis-$C->{conf}.pid";
	}
	return $PIDFILE;	
}

# *****************************************************************************
# NMIS Copyright (C) 1999-2011 Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************

