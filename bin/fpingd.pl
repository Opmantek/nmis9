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
our $VERSION = "8.6.0G";

use FindBin qw($Bin);
use lib "$FindBin::Bin/../lib";
use strict;
use POSIX qw(setsid);
use Socket;
use NMIS;
use func;
use Data::Dumper;
use Fcntl qw(:DEFAULT :flock);
use File::Basename;
use Test::Deep::NoTest;


# Variables for command line munging
my (  $restart, $fpingexit, $debug) = ();
my %nvp = getArguements(@ARGV);
my %INFO;
my $qripaddr = qr/\d+\.\d+\.\d+\.\d+/;

if (!getbool($nvp{kill}) and !getbool($nvp{restart})
		or (@ARGV == 1 and $ARGV[0] =~ /^-{1,2}(h(elp)?|\?)$/ )) {
	my $ext = getExtension();
	my $base = basename($0);
	die "$base Version $VERSION

Usage: $base <restart|kill]=[true|false]> [debug=true|false] [logging=true|false] [conf=alt.config]

Command line options are:
 restart=true   - kill any running daemon(s) and restarts!
 debug=true     - print status to console and logfile
 kill=true      - kill any running daemon(s) and exit. Does not launch a new daemon!
 logging=true   - creates a log file 'fpingd.log' in the standard nmis log directory
 conf=*.$ext    - specify an alternative Conf.$ext file.

a new daemon is started ONLY with restart=true
default is no logging, no debug\n";
}

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

# check if nmis is locked, if so shut down immediately.
my $lockoutfile = $C->{'<nmis_conf>'}."/NMIS_IS_LOCKED";
if (-f $lockoutfile or getbool($C->{global_collect},"invert"))
{
	die ("Attention: NMIS is currently disabled, fpingd.pl is terminating!\n"
			 .(-f $lockoutfile? "Remove the file $lockoutfile to re-enable.\n\n" :
				 "Set the configuration variable \"global_collect\" to \"true\" to re-enable.\n\n"))
}

## setting debug levels
$debug =  setDebug($nvp{debug});
my $logfile     = $C->{'fpingd_log'};
my $runfile     = "/var/run/nmis-fpingd.pid";

#----------------------------------------
# check that fping is available!
my $fpingver = `fping -v`;
if ($? >> 8)
{
	&debug("fping binary executable not found, please install fping utility");
	logMsg("ERROR fping binary executable not found, please install fping utility");
	exit(1);
}
else
{
	$fpingver =~ s/^.*Version (\d+\.\d+).*$/$1/s;
	&debug("found fping version $fpingver");
}


#----------------------------------------

# Process Control
# check for a running fpingd
my $alreadyrunning;
if ( -f $runfile ) {
	open(F, "<$runfile");
	$alreadyrunning = <F>;
	chomp $alreadyrunning;
	close(F);
}
if ( $alreadyrunning and ( getbool($nvp{kill}) or getbool($nvp{restart}) ))
{
	killall($alreadyrunning);
}

if (defined $nvp{kill} and getbool($nvp{kill}))
{
	debug("Killed process $FindBin::Script, deleted $runfile");
	exit(0);
}


#----------------------------------------
# setup fping calling parameters

# sysadmin should restart us, if these changed
# set your fping cmd string here.
# values will be subsituted from nmis.conf, or defaults used
# this one for linux: http://fping.sourceforge.net/
# 'timeout' is subbed for '$timeout' later, etc..


my $fpingcmd;
# use 'C' [uppercase] for correct parsing of results.
# per-target statistics are displayed in a format designed for automated response-time statistics gathering.
# use this command for fping if script run as user root
if ( $< == 0 )  {
	# root user
	$fpingcmd = 'fping -t timeout -C count -i 1 -p 1 -q -r retries -b length' ;
} else {
	# use this command for fping if ruunning as non-root.
	# fping: You need i >= 10, p >= 20, r < 20, and t >= 50
	$fpingcmd = 'fping -t timeout -C count -i 10 -p 20 -q -r retries -b length';
}

# set fping defaults, equal to ping.pm
my $timeout = $C->{fastping_timeout} ? $C->{fastping_timeout} : 300 ;
my $length  = $C->{fastping_packet} ? $C->{fastping_packet} : 56 ;
my $retries = $C->{fastping_retries} ? $C->{fastping_retries} : 3;
my $count   = $C->{fastping_count} ? $C->{fastping_count} : 3;
my $sleep = $C->{fastping_sleep} ? $C->{fastping_sleep} : 60;
my $nodepoll = $C->{fastping_node_poll} ? $C->{fastping_node_poll} : 300;

# should we write a raw event log without stateful deduplication?
my $raweventlog = $C->{fastping_stateless_log} || '';

# fping requires a minimum of 24 byte packets
if ( $length < 24 ) { $length = 24 }

$fpingcmd =~ s/timeout/$timeout/;
$fpingcmd =~ s/length/$length/;
$fpingcmd =~ s/retries/$retries/;
$fpingcmd =~ s/count/$count/;

my $ext = getExtension(dir=>'var');

&debug( "logfile = $FindBin::Bin/../logs/fpingd.log") if defined $nvp{logging};
&debug( "logging not enabled - set cmdline option \'logging=true\' if logging required") if !defined $nvp{logging};
&debug( "pidfile = $runfile");
&debug( "ping result file = $FindBin::Bin/../var/fping.$ext");
&debug( "fping cmd: $fpingcmd");
#---------------------------------------
# process control

# setup a trap for fatal signals, setting a flag to indicate we need to gracefully exit.
$SIG{INT} =  \&catch_zap;
$SIG{TERM} =  \&catch_zap;
$SIG{HUP} = \&catch_zap;

# set ourselves as a daemon
#---------------------------------------------------------
POSIX::setsid() or die "Can't start new session: $!";
chdir('/') or die "Can't chdir to /: $!";


# for debugging, undocumented: argument foreground=true
if (!getbool($nvp{"foreground"}))
{
	# Reopen stdout, stdin with /dev/null; stderr to the fpingd logfile
	# if we dont reopen, the calling terminal will wait, and nmis.pl daemon control will hang
	open(STDIN, "<", "/dev/null") or die "cannot reopen stdin: $!\n";
	open(STDOUT, ">", "/dev/null") or die "cannot reopen stdout: $!\n";
	open(STDERR, ">>", $logfile) or die "cannot open stdout to $logfile: $!\n";
	setFileProtDiag(file => $logfile);

	if (!defined(my $pid = fork))
	{
		die "cannot fork: $!\n";
	}
	elsif ($pid)
	{
		# parent: exits
		exit (0);
	}
	# child continues with the actual work
}

# Announce our presence via a PID file
open(PID, ">$runfile") or warn "\t Could not create $runfile: $!\n";
print PID $$;
close PID;
&debug("daemon started, pidfile $runfile created with pid: $$");
logMsg("INFO daemon fpingd started, pidfile $runfile created with pid: $$");
umask 0;

if ( !getbool($C->{daemon_fping_dns_cache},"invert") ) {
        logMsg("INFO daemon fpingd will cache DNS for improved name resolution");
}
else {
        logMsg("WARNING daemon fpingd will not CACHE DNS, use under adult supervision");
}


# remember the original script location plus the parameter that we want to push through for restart
# old path might have been relative and doesn't work past chdir
my $origscript = $FindBin::RealBin."/".$FindBin::Script;
# we want to keep any params, except kill
my @restartparams = map { "$_=".$nvp{$_}; } (grep($_ ne "kill", keys %nvp));

# set our name so that rc scripts can figure out who we are.
$0 = $FindBin::Script;
$restart = 1;


# loop until a sighandler set $fpingexit
# normally fastping does NOT return anyway, so that while is pretty unnecessary
fastping() while (!$fpingexit);
exit 0;


# loop over nodes, ping them; wait a little then continue
sub fastping
{
	my $nodelist;
	my $read_cnt = 0;
	my $start_time;
	my $prevlnt;

	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $oldeventconfig = loadTable(dir => 'conf', name => 'Events');
	my $qr_parse_result = qr/^.*\s+:(?:(?: \d+\.\d+)|(?: -)){1,$count}$/;

	while(1)
	{
		$start_time = time();

		my $lnt = loadLocalNodeTable();
		if ($prevlnt && !eq_deeply($lnt, $prevlnt))
		{
			debug("Nodes list has changed, reloading after the next sleep");
			logMsg("INFO fpingd will reload the Nodes list as it has changed");
			$read_cnt = 1 if ($read_cnt > 1); # reload no later than after this run
		}
		$prevlnt = $lnt;

		if ($read_cnt-- <= 0) {
			# check every 10 runs for update of Node table - not on every cycle as it involves lots of dns!
			debug("Rereading Nodes list");
			$nodelist = readNodes();
			$read_cnt = 10;
		}

		my %ping_result = (); # clear hash

		foreach my $row (sort keys %{$nodelist})
		{
			my $nodes = $nodelist->{$row};
			&debug("\nfping $row about to ping :\t$nodes");
			if ( open(IN, "$fpingcmd  $nodes  2>&1 |") ) {

				while (<IN>) {
					chomp;

					my ( $flag, $hostname, $r, @rlist, $min, $max, $avg, $loss, $tot, $count);
					$flag = $loss = $count = $min = $max = $avg = $tot = 0;

					# possible results are:
					# host1 : - - -
					# host2 : 0.18 0.19 0.19
					# host3 : 0.22 - 0.33 		second ping timeout
					# or rubbbish
					&debug( "fping returned:\t$_") if $debug > 1;
					if (/$qr_parse_result/) {

						($hostname, $r) = split /:/, $_ ;		# split on : into name, list of results
						$hostname = trim($hostname);
						$r = trim($r);

						foreach my $s ( split / /, $r ) {
							$s = trim($s);
							if ( $s eq '-' ) {
								$loss++;
							} else {
								$min = $s if !$flag;			# seed $min on first pass
								$max = $s if !$flag;
								$flag++;

								# result - set min, max, and count for total

								$min = $s if $s < $min;
								$max = $s if $s > $max;
								$tot += $s;
							}
							$count++;
						}
						if ( $loss eq $count ) { 	# nothing...
							$min = $max= $avg = '';
							$loss = 100;
						} else {
							$avg = sprintf "%.2f",  $tot / $count;
							$loss = int( ($loss/$count) * 100 );
						}
					} else {
						logMsg("INFO fping returned=$_");
						### 2012-02-24 keiths, update from Till Dierkesmann to handle ICMP oddness
						my $pingedhost=$_;
						$pingedhost=~s/(.*)(\D)(\d+\.\d+\.\d+\.\d+)(.*)/$3/;
						if(!defined $hostname or $hostname eq "") {
							logMsg("INFO Hostname seems to be $pingedhost");
							$hostname=$pingedhost;
            }
					}


					&debug( localtime( time() ) . " $hostname : $min, $max, $avg, $loss");

					# get node name back from host
					if ( not exists $INFO{$hostname}{node} ) {
						## 2011-12-07 keiths, changing error to be more accurate.
						logMsg("ERROR hostname $hostname not found in FPING results");
					} else {
						# save only used info by nmis.pl
						$ping_result{$INFO{$hostname}{node}} = {
									'loss'     => $loss,
									'avg'      => $avg,
									'lastping' => "". localtime(time())
								};
						#Other possible items can be added from here.
						#$ping_result{$INFO{$hostname}{node}} = {
						#			'loss'     => $loss,
						#			'min'      => $min,
						#			'avg'      => $avg,
						#			'max'      => $max,
						#			'ip'       => $hostname,
						#			'lastping' => "" . localtime( time() )
						#		};
					}
				}
				close IN;

				### logMsg("INFO run time of fping is ".(time()-$start_time)." sec. pinged ".(scalar keys %ping_result)." nodes");
			}
			else
			{
				logMsg("ERROR could not open pipe to fping: $!");
				exit 1;
			}
		} # foreach row in nodelist

		# Loop over results and send out up or down events

		foreach my $nd ( keys %ping_result )
		{
			# write raw events if requested - regardless of state change or not!
			# note that this is a debugging aid only.
			if ($raweventlog ne '')
			{
				my @problems;
				if (!open(RF,">>$raweventlog"))
				{
					push @problems, "ERROR could not open $raweventlog: $!";
				}
				else
				{
					if (!flock(RF, LOCK_EX))
					{
						push @problems, "ERROR could not lock $raweventlog: $!";
					}
					else
					{
						my $down = $ping_result{$nd}{'loss'} == 100;
						my $event = "Node ".($down? "Down":"Up");
						my $level = $down? "Critical":"Normal"; # fixme this is not as precise as the stateful
						my $details = $down? "Ping failed" : "Ping succeeded, loss=$ping_result{$nd}{'loss'}%";

						print RF join(",", time, $nd, $event, $level, '', $details),"\n";
						close RF or push(@problems,"ERROR could now write to or close $raweventlog: $!");
					}
				}
				map { logMsg($_) } (@problems); # DO NOT run logMsg inside a critical section or while holding a lock!
			}

			# only submit changes in status to the event system, or submit all if restart
			if ( $ping_result{$nd}{'loss'} == 100 )
			{
				&debug( "[" . localtime( time() ) .
								"]\tPinging Failed $nd is NOT REACHABLE, returned loss=$ping_result{$nd}{'loss'}%");
				$INFO{$nd}{name} = ''; # maybe DNS changed

				# hold-off time is past?
				if ($INFO{$nd}{postpone_time} >= $INFO{$nd}{postpone})
				{
					if ( $restart )
					{
						fpingNotify($nd);
					}
					elsif ( not eventExist($nd, "Node Down", undef) )
					{
						# Device is DOWN, was up, as no entry in event database
						&debug("\t$nd is now DOWN, was UP, Updating event database");
						fpingNotify($nd);
					}
					else
					{
						# was down, and still is down...
						# uncomment this if you want to force an update each run - intensive !!!
						# fpingNotify($nd);
					}
				}
				else 										# still within the hold-off period
				{
					$ping_result{$nd}{'loss'} = 0; # simulate ok until postpone time elapsed
				}
				$INFO{$nd}{postpone_time} += 70; # add minute
			}
			else 											# not 100% loss
			{
				# node pingable
				$INFO{$nd}{postpone_time} = 0; # reset
				&debug( "[" . localtime( time() ) . "]\t$nd is PINGABLE: returned min/avg/max = $ping_result{$nd}{'min'}/$ping_result{$nd}{'avg'}/$ping_result{$nd}{'max'} ms loss=$ping_result{$nd}{'loss'}%");

				if ( $restart )
				{
					fpingCheckEvent($nd);
				}
				else
				{
					# check the event existence AND its currency!
					my $event_exists = eventExist($nd, "Node Down", undef);
					my $erec = eventLoad(filename => $event_exists) if ($event_exists);

					if ($event_exists and $erec and getbool($erec->{current}))
					{
						# Device was down is now UP!
						# Only post the status if the event database records as currently down
						&debug("\t$nd is now UP, was DOWN, Updating event database");
						fpingCheckEvent($nd);
					}
					elsif ( !$event_exists ) {
						# was up, and still is up...
						# uncomment this if you want to force an update each run - intensive !!!
						# fpingCheckEvent($nd);
					}
				}
			}
		}

		# At this point, %ping_result is a hash populated by ping results keyed by NMIS host names
		# Write the hash out to a file
		writeTable(dir=>'var',name=>"nmis-fping",data=>\%ping_result );

		# check if the config is still unchanged, if not restart (but only after firstrun)
		# ditto for the events config
		my $newconf = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});
		# re-check for nmis locked
		my $lockoutfile = $newconf->{'<nmis_conf>'}."/NMIS_IS_LOCKED";
		if (-f $lockoutfile or getbool($newconf->{global_collect},"invert"))
		{
			logMsg("WARN fping is terminating because NMIS is disabled!");
			die ("Attention: fping is terminating because NMIS is disabled!\n");
		}

		# cannot use loadGenericTable as that checks and clashes with db_events_sql
		my $eventconfig = loadTable(dir => 'conf', name => 'Events');

		my $whichchanged = !eq_deeply($oldeventconfig, $eventconfig) ?
				"Events List" : !eq_deeply($C,$newconf) ? "Config" : undef;
		if ($whichchanged)
		{
			debug("$whichchanged has changed, will restart after this sleep");
			logMsg("INFO fpingd will restart after this sleep, $whichchanged has changed");
			sleep(int(5-rand(10)) + $sleep); # standard interval +/- 5 sec
			logMsg("INFO fpingd is restarting now");
			exec($origscript,@restartparams);
			die "$0 couldn't restart itself: $!\n"; # shouldn't be reached
		}

		# sleep for a while
		$restart = 0; # first run done
		&debug("sleeping ...");
		# Generate random # from 1-10 + $C->{fastping_sleep}

		### 2013-02-14 keiths, run the NMIS escalation process for faster outage notifications.
		my $lines = `$C->{'<nmis_bin>'}/nmis.pl type=escalate debug=$debug`;

		sleep(int(5-rand(10)) + $sleep);

	}
}

# check-and-remove existing node down event
# args: node name
# returns: nothing
sub fpingCheckEvent
{
	my $node = shift;
	&debug("\tUpdating event database via sub checkEvent() host: $node event: Node Up");

	my $S = Sys::->new;
	$S->init(name => $node, snmp => 'false');
	my $NI = $S->ndinfo; # pointer to node info table

	checkEvent( sys		=> $S,
							event   => "Node Down",
							element => "",
							level   => "Normal",
							details => "Ping failed" );
}

# create a new node down event
# args: node name
# returns: nothing
sub fpingNotify
{
	my $node = shift;

	&debug("\tUpdating event database via sub notify() host: $node event: Node Down");

	my $S = Sys::->new;
	$S->init(name=>$node, snmp=>'false');

	notify(	sys		=> $S,
					event   => "Node Down",
					element => "",
					details => "Ping failed",
					context => { type => "node" });
}

sub trim {
	my $s = shift;
	return '' if ! $s;
	$s =~ s/^\s+//;
	$s =~ s/\s+$//;
	return $s;
}

sub debug {
	print STDOUT "\tfpinger: $_[0]\n" if $debug;
	if ( $nvp{logging} )
	{
		open LOG, ">>$logfile" or warn "Can't write to $logfile: $!";
		print LOG returnDateStamp(). " ". $_[0] ."\n";
		close LOG;
		setFileProtDiag(file => $logfile);
	}
}

sub catch_zap {
	$fpingexit++;
	&debug("I was killed by $_[0]");
	logMsg("INFO daemon fpingd killed by $_[0]",
				 do_not_lock => 1);
	unlink $runfile;
	die "I was killed by $_[0]: $!\n";
}

# kill all given processes except me..!
sub killall {
	my (@shootthem) = @_;

	foreach my $p (@shootthem)
	{
		next if !$p or $p eq $$;
		kill 9, $p;
		&debug("killed running process pid $p ");
	}
}

# read node info from file. maybe cached, or from db
# returns sorted list of ips to ping, chunked into rows
sub readNodes
{
	my @hosts;
	my $NT = loadLocalNodeTable(); # from (cached) file or db

	foreach my $nd (sort keys %{$NT} ) {
		if ( getbool($NT->{$nd}{active}) and getbool($NT->{$nd}{ping})) {
			if ( $INFO{$nd}{name} eq '' or $NT->{$nd}{host} ne $INFO{$nd}{org_host}) {
				# new entry or changed host address
				$INFO{$nd}{org_host} = $NT->{$nd}{host}; # remember original for changes
				$INFO{$nd}{name} = $nd; # remember name of node

					# Optionally Caching DNS, improved performance but makes development harder :-)
          if ( !getbool($C->{daemon_fping_dns_cache},"invert") ) {
						if ($NT->{$nd}{host} =~ /$qripaddr/) {
							$INFO{$NT->{$nd}{host}}{node} = $nd;
							$INFO{$nd}{host} = $NT->{$nd}{host};
						}
						# get ip address
						elsif ((my $addr = resolveDNStoAddr($NT->{$nd}{host}))) {
							$INFO{$addr}{node} = $nd; # for backwards search
							$INFO{$nd}{host} = $addr;
						} else {
							logMsg("ERROR cannot resolve host=$NT->{$nd}{host} from node $nd to IP address using OS (e.g. DNS or /etc/hosts)");
							next;
						}
					}
					else {
						#maintain cache for consistency
						$INFO{$NT->{$nd}{host}}{node} = $nd; # for backwards search
						$INFO{$nd}{host} = $NT->{$nd}{host};
					}
			}
			# feature
			# if node is not more pingeble then wait 'postpone' time (seconds) to generate event
			$INFO{$nd}{postpone} = 0;
			if ($NT->{$nd}{postpone} ne "") {
				if ($NT->{$nd}{postpone} =~ /d+/) {
					$INFO{$nd}{postpone} = $NT->{$nd}{postpone}; # in seconds
				} else {
					logMsg("ERROR ($nd) value of postpone in table Nodes must be numeric value (seconds)");
				}
			}
			push @hosts,$INFO{$nd}{host};
		}
		else {
			&debug("readNodes, skipping fping of $nd, $NT->{$nd}{host}");
		}
	}

	if ( ! @hosts ) {
		&debug("No nodes found to ping");
		logMsg("INFO no nodes found in Node table to ping, exit daemon");
		exit 1;
	} else {
		&debug("Read Nodelist, @hosts");
	}

	### 2012-02-22 keiths, fping $nodepoll nodes at time, exceeding command line of 4098 bytes
	my $nodelist;
	my $row = 0;
	my $hostcount = 0;
	my @shorthosts;
	for my $host (sort @hosts) {
		++$hostcount;
		if ( $hostcount < $nodepoll ) {
			push(@shorthosts,$host);
		}
		else {
			push(@shorthosts,$host);
			&debug("Splitting nodes into chunks of $nodepoll nodes: @shorthosts");
			$nodelist->{$row} = join(' ',@shorthosts); # string of hosts separated by space
			++$row;
			$hostcount = 0;
			@shorthosts = ();
		}
	}
	# put the left over nodes into nodelist!
	$nodelist->{$row} = join(' ',@shorthosts);

	return $nodelist;
}
