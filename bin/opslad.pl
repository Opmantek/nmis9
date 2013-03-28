#!/usr/bin/perl
#
## $Id: opslad.pl,v 1.8 2013/01/08 23:51:38 keiths Exp $
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND
# LICENSED BY OPMANTEK.  
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE,
# THIS AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU
# AND OPMANTEK LTD. 
# Opmantek is a passionate, committed open source software company - we
# really are.  This particular piece of code was taken from a commercial
# module and thus we can't legally supply under GPL. It is supplied in good
# faith as source code so you can get more out of NMIS.  According to the
# license agreement you can not modify or distribute this code, but please
# let us know if you want to and we will certainly help -  in most cases
# just by emailing you a different agreement that better suits what you want
# to do but covers Opmantek legally too. 
# 
# contact Opmantek by emailing code@opmantek.com
# 
# 
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
#  
# *****************************************************************************
#
# run this from the <nmis>/bin directory, normaly it will be start by nmis.pl
# turn on debug if you want detailed logging to the <nmis>/logs/ipsla.log file
# will fork and leave a status message so you know it is running.
#

require 5.008_000;

use FindBin;
use lib "$FindBin::Bin/../lib";
use strict;
use BER;
use SNMP_Session '1.08';
use SNMP_util;
use csv;
use func;
use NMIS;
use NMIS::IPSLA;
use POSIX;
use RRDs 1.000.490;
use rrdfunc;
use Net::hostent;
use Socket;
use Carp;
use Proc::ProcessTable; # from CPAN
use Proc::Queue ':all'; # from CPAN
use POSIX ":sys_wait_h"; # imports WNOHANG

use Data::Dumper; 
$Data::Dumper::Indent = 1;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

my $pid;
my $line;
my $time_to_die = 0;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($nvp{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

# store multithreading arguments from nvp
my $mthread	= 0;
my $maxThreads = 1;
my $mthreadDebug = 0;
my $dnscacheage = 3600;

$mthread = 1 if $C->{ipsla_mthread} eq "true";
$maxThreads = $C->{ipsla_maxthreads} if $C->{ipsla_maxthreads};
$mthreadDebug = 1 if $C->{ipsla_mthreaddebug} eq "true";
$dnscacheage = $C->{ipsla_dnscacheage} if $C->{ipsla_dnscacheage} ne "";

my $vardir = $nvp{vardir};
unless ( $vardir ) { $vardir = $C->{'<nmis_var>'} }

Proc::Queue::size($maxThreads); # changing limit of concurrent processes
Proc::Queue::trace(0); # trace mode on
Proc::Queue::debug(0); # debug is off
Proc::Queue::delay(0.02); # set 20 milliseconds as minimum delay between fork calls, reduce to speed collect times

# load mib
foreach my $file ( "CISCO-RTTMON-MIB.oid" ) {
	if ( ! -r "$C->{mib_root}/$file" ) { 
		 warn returnTime." opslad.pl, mib file $C->{mib_root}/$file not found.\n";
	}
	else {
		loadoids( "$C->{mib_root}/$file" );
		if ($debug) { print "\t Loaded mib $C->{mib_root}/$file\n"; }
		if ( $SNMP_Simple::errmsg ) {
			warn returnTime." opslad.pl, SNMP error. errmsg=$SNMP_Simple::errmsg\n";
			$SNMP_Simple::errmsg = "";
		}
	}
}
my %revOIDS = reverse %SNMP_util::OIDS; # the power of perl

# Initialize globals

my $restartcmd = "$0 '$vardir'";

### 2012-02-23 keiths, ipsla configuration options from the NMIS config.
# collect interval time in seconds
my $collect_time = $C->{ipsla_collect_time} ? $C->{ipsla_collect_time} : 60; 
# collect interval of buckets in seconds
my $bucket_interval =  $C->{ipsla_bucket_interval} ? $C->{ipsla_bucket_interval} : 180; 
# extra collect buckets for polling cycle
my $extra_buckets = $C->{ipsla_extra_buckets} ? $C->{ipsla_extra_buckets} : 5;


### 2013-03-28 keiths, changed the $host to be $hoststr and use the host entry from NMIS Nodes.nmis

my %RTTcache; # temp. cache

my $IPSLA = NMIS::IPSLA->new(C => $C);

$SNMP_Simple::suppress_warnings = 1;
$SNMP_Session::suppress_warnings = 1; # logging to log/ipsla.log

if ( $nvp{type} eq "update") {
	logIpsla("opSLAD: update request from opsla.pl received") if $debug;
	# show not mthread update!
	$mthread = 0;	runRTT(0);
	exit 0;
}
elsif ( $nvp{type} eq "alter") {
	logIpsla("opSLAD: alter the tables as required") if $debug;
	# show not mthread update!
	$IPSLA->alterProbeTable();
	exit 0;
}
elsif ( $nvp{type} eq "threads") {
	logIpsla("opSLAD: threads request from opslad.pl received") if $debug;
	runRTT(1);
	exit 0;
}

# See if another instance of ourself is running, if so kill the process
my $pidfile = $vardir."/ipslad.pid";

if (-f $pidfile) {
  open(F, "<$pidfile");
  $pid = <F>;
  close(F);
  chomp $pid;
  if ($pid != $$) {
    logIpsla("opSLAD: pidfile exists killing the pidfile process $pid");
    kill 9, $pid;
    unlink($pidfile);
    logIpsla("opSLAD: pidfile $pidfile deleted");
  }
}

# As we are paranoid and running as root, chroot to a safe directory:
# note: if we go anywhere else that will break the file paths.
#chroot("/") or die "Couldn't chroot to /: $!";


FORK: {
    if ($pid = fork_now) {
        # parent here
        # child process pid is available in $pid
		exit;	
    }
    elsif (defined $pid) { # $pid is zero here if defined
        # child here
        # parent process pid is available with getppid

		# dissociate from the controlling terminal
		POSIX::setsid() or die "Can't start new session: $!"; 
		# set our named so that rc scripts can figure out who we are.
		$0="NMIS opslad (ipslad+) debug=$debug";
		
		# Announce our presence via a PID file

		open(PID, ">$pidfile") || exit;
		print PID $$; close(PID);
		logIpsla("opSLAD: pidfile $pidfile created");

		# Perform a sanity check. If the current PID file is not the same as
		# our PID then we have become detached somehow, so just exit

		open(PID, "<$pidfile") || exit;
		$pid = <PID>; close(PID);
		chomp $pid;
		exit unless $pid == $$;

		# Record our (re)starting in the event log

		logIpsla("opSLAD: start: pidfile=$pidfile pid=$pid mthread=$mthread maxThreads=$maxThreads");

		# code body here.

		# setup a log file and trap any error messages as well.
		umask 0;
		open STDOUT, ">>$C->{ipsla_log}" or die "Can't write to $C->{ipsla_log}: $!";
		open STDERR, ">>$C->{ipsla_log}" or die "Can't write to $C->{ipsla_log}: $!";

		# setup a trap for fatal signals, setting a flag to indicate we need to gracefully exit.
		$SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&signal_handler;
		$SIG{'CHLD'} = 'IGNORE';		# autoreap zombies

		# print a short status message and flush any errors so far to the file.
		logIpsla("opSLAD: forked successfully debug=$debug\n");

		# 
		my $time1;
		my $time2;
		my $dnstime = time;
		while ($time_to_die == 0 ) { 
			$time1 = time();
			open(PID, '+<',"$pidfile"); print PID $$; close(PID); # signal client that we are running again
			#runRTT(1);
			my $lines = `$C->{'<nmis_bin>'}/opslad.pl type=threads debug=$debug`;
			
			$time2 = time(); 
			if ( ($time2 - $time1) > $collect_time ) { 
				logIpsla("opSLAD: runPD, runtime of collecting exceed collect interval time"); 
			}
			else {
				sleep( $collect_time - ($time2 % $collect_time) );
			}
			# Clean the DNS cache periodically!
			if ( $dnstime + $dnscacheage < time ) {
				$dnstime = time;
				$IPSLA->cleanDnsCache(cacheage => $dnscacheage);
			}
		} # end of while loop
	} # end of child
    elsif ($! == EAGAIN) {
        # EAGAIN is the supposedly recoverable fork error
        sleep 5;
        redo FORK;
    }
    else {
        # weird fork error
        die "OPSLAD: Can't fork: $!\n";
    }
}

sub signal_handler {
	my $signame = shift;
	our $time_to_die++;
	my $time = scalar localtime();
	die "OPSLAD: - I have died - Somebody sent me a SIG$signame!\n";
}

#========


sub runRTT {
	my $collect = shift;
	
	# Too verbose!
	#logIpsla("opSLAD: runRTT just requested debug=$debug\n");

	my $statusPDenable;
	my $runtime;

	if ($collect) {
		$runtime = time(); # start of collecting
	}

	delete $RTTcache{stats} ;
		
	logIpsla("opSLAD: runRTT Begin debug=$debug");
	my @keys = $IPSLA->getProbeKeys();
	my @pids;
	foreach my $nno (sort (@keys)) {

		if ($mthread) {
			my $pid = fork;
			if ( defined($pid) and $pid == 0) {
				# this will be run only by the child
				if ($mthreadDebug) {
					logIpsla("CHILD $$-> I am a CHILD with the PID $$ processing $nno");
				}
				# lets change our name, so a ps will report who we are
				$0 = "opslad.pl.$nno";

				logIpsla("opSLAD: runOneRTT PID=$$ nno=$nno debug=$debug") if $debug;		
				runOneRTT($nno,$runtime,$collect);
				logIpsla("opSLAD: runOneRTT PID=$$ END") if $debug;		

				# all the work in this thread is done now this child will die.

				if ($mthreadDebug) {
					logIpsla("CHILD $$-> $nno will now exit");
				}

				# killing child
				exit 0;
			} # end of child
			push @pids, $pid if defined $pid;
			my $rn = running_now();
			logIpsla("opSLAD: running_now=$rn") if $debug;		
			# Father is forced to wait here unless number of childs is less than maxthreads.

		} 
		# will be run if mthread is false (no multithreading)
		else {
			logIpsla("opSLAD: runOneRTT nno=$nno debug=$debug") if $debug;		
			runOneRTT($nno,$runtime,$collect);
			logIpsla("opSLAD: runOneRTT nno=$nno END") if $debug;		
		}
		
		if ($mthread) {
			1 while waitpid(-1, WNOHANG)>0; # reaps children
		}
	}

	# only do the cleanup if we have mthread enabled 
	if ($mthread) {
		# cleanup
		# wait this will block until childs done
		#1 while wait != -1;
		waitpids(@pids);
	}

	logIpsla("opSLAD: runRTT End debug=$debug");
	
	if (scalar(keys %{$RTTcache{stats}})) {
		# also collecting of statistics, hourly
		logIpsla("opSLAD: runRTTstats debug=$debug") if $debug;		
		runRTTstats();
	}

}

sub runOneRTT {
	my $nno = shift;
	my $runtime = shift;
	my $collect = shift;

	if ($IPSLA->existProbe(probe => $nno)) {		
		my $probe = $IPSLA->getProbe(probe => $nno);
		
		logIpsla("opSLAD: runOneRTT, key $nno, function ($probe->{func}), status ($probe->{status})") if $debug;
		if ($probe->{func} =~ /start|remove|stop/) {
			$IPSLA->updateMessage(probe => $nno, message => "NULL" );
			
			if ($probe->{func} eq "start") {
				if (runRTTstart($nno)) {
					$IPSLA->updateFunc(probe => $nno, func => "NULL");
				} # done
			} 
			elsif ($probe->{func} eq "stop" or $probe->{func} eq "remove") {
				if (runRTTstop($nno)) {
					runRTTmodify($nno);
				} # done
			}
		}
		
		if ($probe->{status} eq "error" and $probe->{message}  eq "" ) {
			logIpsla("opSLAD: runOneRTT, key $nno, probe status is $probe->{status} and probe message is NULL");		
			$IPSLA->updateProbe(probe => $nno, status => "running");
		}
		
		if ($probe->{status} eq "running" and $collect) {
			# optimize collect
			my $ptype = "";
			my $nexttime = 0;
			if ($RTTcache{$nno}{nexttime} <= $runtime) {
				if ($probe->{optype} =~ /stats/i ) {
					$ptype = "stats";
					push @{$RTTcache{stats}{node}{$probe->{pnode}}},$nno;
					$nexttime = 3600;
					$RTTcache{$nno}{nexttime} = $runtime + $nexttime; # hourly
				} else {
					# collect based on history buckets
					if (runRTTcollect($nno)) {
						$ptype = $probe->{optype};
						if ($probe->{optype} =~ /echo|tcpConnect|dhcp|dns/i) {
							$ptype = "buckets";
							$nexttime = ($probe->{frequence} > $bucket_interval) ? $probe->{frequence} : $bucket_interval;
							$RTTcache{$nno}{nexttime} = $runtime + $nexttime;
								
						}
					}
				}
				logIpsla("opSLAD: RTT, type=$ptype next collect after $nexttime seconds") if $debug;
			}
		}
	}
}

sub runRTTmodify {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);
	
	if ($probe->{status} eq "remove") {
		delete $RTTcache{dns}{$probe->{pnode}};
		delete $RTTcache{$nno};
		$IPSLA->deleteProbe(probe => $nno);
		$IPSLA->deleteDnsCache(lookup => $probe->{pnode});
		logIpsla("opSLAD: RTTmodify, removing probe $nno") if $debug;
	}
}

sub resolveDNS {
	my $dns = shift;
	my $addr;
	my $oct;
	my $h;
	
	# convert node name to oct ip address
	if ($dns ne "") {
		if ($dns !~ /^([0-9]|\.)+/) {
			if ($h = gethostbyname($dns)) {
				$addr = inet_ntoa($h->addr);
			}
			else {
				return undef;
			}
		} 
		else { 
			$addr = $dns; 
		}
		my @octets=split(/\./,$addr);
		$IPSLA->updateDnsCache(lookup => $dns, result => $addr);
		$RTTcache{dns}{$dns} = $addr;
		$oct= pack ("CCCC", @octets);
		return $oct;
	} 
	else {
		return undef;
	}
}


sub runRTTstart {
	my $nno = shift;
	my $state;
	my $roct;
	my $soct;
	my @params=();

	my $NT = loadLocalNodeTable();

	my $probe = $IPSLA->getProbe(probe => $nno);

	# convert responder/target node name to oct ip address
	if ($probe->{tnode} ne "") {
		$roct = resolveDNS($probe->{tnode});
		logIpsla("opSLAD: RTTstart, convert responder/nameserver node $probe->{tnode} to oct") if $debug;
	}

	# convert source to bin ip address
	if ( $probe->{saddr} ne "" ) {
		$soct = resolveDNS($probe->{saddr});
		if (not $soct) {
			my $message = "error convert probe source address to oct";
			logIpsla("opSLAD: RTTstart, $message") if $debug;
			$IPSLA->updateProbe(probe => $nno, message => $message);
			return undef;
		}
	}

	$probe->{frequence} = 60 if $probe->{frequence} eq "";

	# probe node
	my $community = $IPSLA->getCommunity(node => $probe->{pnode});
	my $node = $probe->{pnode} ;
	my $port = $NT->{$probe->{pnode}}{snmpport} ;
	my $host = $NT->{$probe->{pnode}}{host};
	my $hoststr = "$community"."@"."$host".":::::2";

	my %protocol = ( 
		'echo' => { 'type' => 1, 'prot' => 2 },			# ipIcmpEcho(2)
		'echo-stats' => { 'type' => 1, 'prot' => 2 },	# ipIcmpEcho(2)
		'pathEcho' => { 'type' => 2, 'prot' => 2 },		# ipIcmpEcho(2)
		'pathEcho-stats' => { 'type' => 2, 'prot' => 2 },		# ipIcmpEcho(2)
		'udpEcho' => { 'type' => 5, 'prot' => 3 },		# ipUdpEchoAppl(3)
		'udpEcho-stats' => { 'type' => 5, 'prot' => 3 },# ipUdpEchoAppl(3)
		'tcpConnect' => { 'type' => 6, 'prot' => 24 },	# ipTcpConn(24)
		'tcpConnect-stats' => { 'type' => 6, 'prot' => 24 },	# ipTcpConn(24)
		'http' => { 'type' => 7, 'prot' => 25 },		# httpAppl(25)
		'http-stats' => { 'type' => 7, 'prot' => 25 },	# httpAppl(25)
		'dns' => { 'type' => 8, 'prot' => 26 },			# dnsAppl(26)
		'dns-stats' => { 'type' => 8, 'prot' => 26 },	# dnsAppl(26)
		'jitter' => { 'type' => 9, 'prot' => 27 },		# jitterAppl(27)
		'jitter-stats' => { 'type' => 9, 'prot' => 27 },# jitterAppl(27)
		'jitter-voip' => { 'type' => 9, 'prot' => 27 },	# jitterAppl(27)
		'jitter-voip-stats' => { 'type' => 9, 'prot' => 27 },	# jitterAppl(27)
		'dhcp' => { 'type' => 11, 'prot' => 29 }, 		# dhcpAppl(29)
		'dhcp-stats' => { 'type' => 11, 'prot' => 29 }, # dhcpAppl(29)
		'voip' => { 'type' => 13, 'prot' => 32}			# voipAppl(32)
		);

	# responder active
	if (! runRTTresponder($nno)) { return undef; }

	# does this node support this type of protocol
	$state = snmpget($hoststr,"rttMonApplSupportedRttTypesValid.$protocol{$probe->{optype}}{type}");
	if ($state == 2) {
		my $message = "this type of probe is not available on node $probe->{pnode}";
		logIpsla("opSLAD: RTTstart, $message") if $debug;
		$IPSLA->updateProbe(probe => $nno, status => "error", message => $message);
		return undef;
	} 
	elsif ($state != 1) {
		my $message = "error probe node $probe->{pnode}, SNMP Error, errmsg=$SNMP_Session::errmsg";
		logIpsla("opSLAD: RTTstart, $message") if $debug;
		$IPSLA->updateProbe(probe => $nno, status => "error", message => $message);
		return undef;
	}

	# request state of probe
	$state = snmpget($hoststr,"rttMonCtrlOperState.$probe->{entry}") if ($probe->{entry} ne "");
	logIpsla("opSLAD: RTTstart, state of probe $nno, entry $probe->{entry}, is $state") if $debug;
	if ($state != 6) {
		# check if database already exists and if it was created with the same interval/frequence
		my $database = $probe->{database};
		if ( (-r $database and -w $database) ) { 
			logIpsla("opSLAD: RTTstart, database of this probe exists already") if $debug;
			my $info = RRDs::info($database);
			foreach my $key (keys %$info) {
				if ( $key =~ /^step/) { 
					my $frequence = $probe->{optype} =~ /stats/ ? 3600 : $probe->{frequence} ;
					if ($$info{$key} != $frequence) {
						my $message = "existing database was created with an interval of $$info{$key} sec.";
						logIpsla("opSLAD: RTTstart, $message") if $debug;
						$IPSLA->updateProbe(probe => $nno, message => $message, status => "error");
						return undef;
					} 
					else {
						last;
					}
				}
			}
		}

		# define entry number for this probe
		my $entry = $IPSLA->getEntry(node => $probe->{pnode});
		
		if ($entry eq "") {
			 $entry = 100; 
		} 
		else { 
			$entry++; 
		}
		$IPSLA->updateNode(node => $probe->{pnode}, entry => $entry);

		$probe->{entry} = $entry;
		
		
		# probe is not active, try to config and start probe
		if ($probe->{optype} =~ /echo|tcpConnect|dhcp|dns/i) {
			# create entry
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$probe->{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$probe->{optype}}{prot} ;
			push @params,"rttMonEchoAdminTargetAddress.$entry",'octetstring',$roct if $probe->{tas} eq "" ;
			push @params,"rttMonEchoAdminSourceAddress.$entry",'octetstring',$soct if $probe->{saddr} ne "" and $probe->{tas} eq "";
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$probe->{frequence} ;
			push @params,"rttMonCtrlAdminTimeout.$entry",'integer', $probe->{timeout}*1000 if $probe->{timeout} ne "" ;
			push @params,"rttMonEchoAdminTOS.$entry",'integer',$probe->{tos} if $probe->{tos} ne "";
			push @params,"rttMonEchoAdminVrfName.$entry",'string',$probe->{vrf} if $probe->{vrf} ne "";
			push @params,"rttMonCtrlAdminVerifyData.$entry",'integer',$probe->{verify} if $probe->{verify} ne "";
			push @params,"rttMonStatisticsAdminNumHops.$entry",'integer',$probe->{hops} if $probe->{hops} ne "" ;
			if ($probe->{optype} =~ /tcpConnect|udpEcho/) {
				push @params,"rttMonEchoAdminTargetPort.$entry",'integer',$probe->{dport} ;
				if ( $probe->{rnode} eq "other" and $C->{ipsla_control_enable_other} eq "false" ) {
					push @params,"rttMonEchoAdminControlEnable.$entry",'integer',2;
				}
				else {
					push @params,"rttMonEchoAdminControlEnable.$entry",'integer',1;
				}
			}
			push @params,"rttMonEchoAdminTargetAddressString.$entry",'string',$probe->{tas} if $probe->{tas} ne "";
			push @params,"rttMonEchoAdminNameServer.$entry",'octetstring',$roct if $probe->{tas} ne "";
			my $num_buckets = int($bucket_interval/$probe->{frequence}) + $extra_buckets;
			push @params,"rttMonHistoryAdminNumBuckets.$entry",'integer',$num_buckets if $probe->{optype} !~ /stats/;
			push @params,"rttMonHistoryAdminNumLives.$entry",'integer',1 if $probe->{optype} !~ /stats/;
			push @params,"rttMonHistoryAdminFilter.$entry",'integer',2 if $probe->{optype} !~ /stats/; # all
		}

		if ($probe->{optype} =~ /http/i) {
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$probe->{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$probe->{optype}}{prot} ;
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$probe->{frequence} ;
			push @params,"rttMonEchoAdminHTTPVersion.$entry",'string',"1.0";
			push @params,"rttMonEchoAdminURL.$entry",'string',$probe->{url};
			push @params,"rttMonEchoAdminCache.$entry",'integer',2 ; # bypass cache

		}

		if ($probe->{optype} =~ /jitter/i) {
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$probe->{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$probe->{optype}}{prot} ;
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$probe->{frequence} ;
			push @params,"rttMonEchoAdminTargetAddress.$entry",'octetstring',$roct ;
			push @params,"rttMonEchoAdminSourceAddress.$entry",'octetstring',$soct if $probe->{saddr} ne "";
			push @params,"rttMonEchoAdminTOS.$entry",'integer',$probe->{tos} if $probe->{tos} ne "";
			push @params,"rttMonEchoAdminVrfName.$entry",'string',$probe->{vrf} if $probe->{vrf} ne "";
			push @params,"rttMonEchoAdminTargetPort.$entry",'integer',$probe->{tport} ;
			
			if ($probe->{codec} and $probe->{codec} ne "") {
				push @params,"rttMonEchoAdminCodecType.$entry",'integer',$probe->{codec};
				push @params,"rttMonEchoAdminCodecInterval.$entry",'integer',$probe->{interval};
				push @params,"rttMonEchoAdminCodecPayload.$entry",'integer',$probe->{reqdatasize} if ($probe->{reqdatasize} and $probe->{reqdatasize} ne "");
				push @params,"rttMonEchoAdminCodecNumPackets.$entry",'integer',$probe->{numpkts} if ($probe->{numpkts} and $probe->{numpkts} ne "");
				push @params,"rttMonEchoAdminICPIFAdvFactor.$entry",'integer',$probe->{factor} if ($probe->{factor} and $probe->{factor} ne "");
			} else {
				push @params,"rttMonEchoAdminNumPackets.$entry",'integer',$probe->{numpkts};
				push @params,"rttMonEchoAdminInterval.$entry",'integer',$probe->{interval};
				push @params,"rttMonEchoAdminPktDataRequestSize.$entry",'integer',$probe->{reqdatasize} if ($probe->{reqdatasize} and $probe->{reqdatasize} ne "");

			}
		}

		if (! snmpset($hoststr, @params)) {
			$IPSLA->updateProbe(probe => $nno, status => "error", message => "Error snmpset attributes for probe $probe->{optype}");
			logIpsla("opSLAD: RTTstart, ERROR probe $nno: $hoststr: error=$SNMP_Session::errmsg params=@params");
 			return undef;
		}

		# start probe
		@params = ();
		push @params,"rttMonCtrlAdminOwner.$entry",'string',$C->{server_name} ; # 
		push @params,"rttMonScheduleAdminRttStartTime.$entry",'timeticks',1 ; # now
		push @params,"rttMonScheduleAdminRttLife.$entry",'integer',2147483647 ; # forever
		push @params,"rttMonCtrlAdminStatus.$entry",'integer',1 ;
		if (! snmpset($hoststr, @params)) {
			$IPSLA->updateProbe(probe => $nno, status => "error", message => "Error snmpset for start probe on node $probe->{pnode}");
			return undef;
		}
		$probe->{status} = "running";
		$probe->{starttime} = "probe started at ". returnDateStamp();
		logIpsla("opSLAD: RTTstart, probe $nno started on node $probe->{pnode}, entry $entry") if $debug;
		
		$IPSLA->updateProbe(
			probe => $nno, 
			message => $probe->{message}, 
			status => $probe->{status}, 
			starttime => $probe->{starttime}, 
			entry => $probe->{entry}, 
			frequence => $probe->{frequence}
		);
	}
	return 1; # done
}

sub runRTTstop {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);

	my $NT = loadLocalNodeTable();

	my @params = ();
	my $entry = $probe->{entry};

	logIpsla("opSLAD: RTTstop, probe $nno, flag delete db is $probe->{deldb}") if $debug;
 
	my $community = $IPSLA->getCommunity(node => $probe->{pnode});
	my $node = $probe->{pnode} ;
	my $port = $NT->{$probe->{pnode}}{snmpport} ;
	my $host = $NT->{$probe->{pnode}}{host} ;
	my $hoststr = "$community"."@"."$host".":::::2";

	push @params,"rttMonCtrlOperState.$entry",'integer',3 ;
	push @params,"rttMonCtrlAdminStatus.$entry",'integer',2 ;
	push @params,"rttMonCtrlAdminStatus.$entry",'integer',6 ;
	snmpset($hoststr, @params);

	unlink $probe->{database} if $probe->{deldb} eq "true"; # delete RRD

	$IPSLA->updateProbe(probe => $nno, status => "remove");
}

sub runRTTresponder {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);
	my $NT = loadLocalNodeTable();

	my $state;

	# responder activating
	if ($probe->{optype} =~ /tcpConnect|udpEcho|jitter/i and $probe->{rnode} ne "other") {
		my $community = $IPSLA->getCommunity(node => $probe->{rnode}); 
		my $node = $probe->{rnode};
		my $host = $NT->{$probe->{rnode}}{host};
		my $hoststr = "$community"."@"."$host".":::::2";
		# try reachability of system
		($state) = snmpget($hoststr,"sysUpTime");
		if (!$state) {
			my $message = "responder node $probe->{rnode} does not respond";
			logIpsla("opSLAD: runRTTresponder, $message") if $debug;
			$IPSLA->updateProbe(probe => $nno, message => $message);
			return undef;
		}
		$state = snmpget($hoststr,"rttMonApplResponder.0");
		logIpsla("opSLAD: runRTTresponder, state of responder $probe->{rnode} is $state") if $debug;
		if ($state != 1) { 
			if (!snmpset($hoststr,"rttMonApplResponder.0","integer",1)) {
				my $message = "error on activating responder on node $node" ;
				logIpsla("opSLAD:, runRTTresponder, $message") if $debug;
				$IPSLA->updateProbe(probe => $nno, message => $message, status => "error");
				return undef;
			} else {
				$probe->{responder} = "activated";
			}
		} else {
			$probe->{responder} = "active";
		}
	}
	$IPSLA->updateProbe(probe => $nno, responder => $probe->{responder});
	return 1;
}


sub loadoids {
    my($mibfile) = @_;
    if ( -f $mibfile) {
        open(MIBFILE, "<$mibfile");
        my($line);
        while(defined($line = <MIBFILE>)) {
            if (!($line =~ /^\#/)) {
                  my ($name, $oid) = ($line =~ /\"(.*)\".*\"(.*)\"/);
    		$SNMP_util::OIDS{$name} = $oid;
            }
        }
        close(MIBFILE);
    }
}

sub runRTTcollect {
	my $nno = shift;
	my @values;
	my $sysuptime;
	my $nmistime;
	my %values = ();
	my @options;
	my $lastupdate;
	my $probeTimeOffset;
	my $last;
	my $timeout_cnt = 0; # in case of responder probe

	my $probe = $IPSLA->getProbe(probe => $nno);

	my $entry = $probe->{entry};

	my $NT = loadLocalNodeTable();

	logIpsla("opSLAD: RTTcollect of probe $nno with entry $entry") if $debug;
 
	my $community = $IPSLA->getCommunity(node => $probe->{pnode});
	# resolve dns name 
	if ($RTTcache{dns}{$probe->{pnode}} eq "") { 
		resolveDNS($probe->{pnode});
	}
	my $node = $RTTcache{dns}{$probe->{pnode}};
	$node = $probe->{pnode} if $node eq "";
	my $port = $NT->{$probe->{pnode}}{snmpport} ;
	my $host = $NT->{$probe->{pnode}}{host};
	my $hoststr = "$community"."@"."$host".":::::2";

	# system uptime
	#($sysuptime) = snmpget($hoststr,"sysUpTime");
	### 2013-02-14 keiths, using snmpEngineTime as it is a better reflection of current processor uptime.
	($sysuptime) = snmpget($hoststr,"snmpEngineTime.0");

	if (!$sysuptime) {
		my $message = "node $probe->{pnode} does not respond";
		logIpsla("opSLAD: RTTcollect, $message");
		$IPSLA->updateMessage(probe => $nno, message => $message);
		return undef;
	}
	
	if ( $probe->{message} =~ /node $probe->{pnode} does not respon/ ) {
		$IPSLA->updateMessage(probe => $nno, message => "NULL" );
	}

	$sysuptime = convertUpTime($sysuptime) if ($sysuptime !~ /^\d+$/) ;

	$nmistime = time();

	# check if database exists
	my $database = $probe->{database};
	if ( not (-f $database and -r $database and -w $database) ) { 
		if ( not runRRDcreate($nno,$database)) { return;} 
		$last = $nmistime;
	} else {
		$last = RRDs::last($database);
	}
	
	### 2013-01-08 keiths, using the last collected time instead of the timestamp.
	# $probe->{lastupdate} could store the difference between the probe collect and NMIS uptime.
	$probeTimeOffset = $probe->{lastupdate}; 
	$lastupdate = ($last - $nmistime) + $sysuptime + 3; # +3 for time mismatch

	#Make the lastupdate the difference between the time and the probeTimeOffset.
	my $newlastupdate = $probe->{lastupdate};
	$lastupdate = $probe->{lastupdate};

	logIpsla("opSLAD: TIME $nno; lastupdate=$lastupdate, newlastupdate=$newlastupdate probeTimeOffset=$probeTimeOffset last=$last nmistime=$nmistime sysuptime=$sysuptime") if $debug;
	

	#if ( not $lastupdate ) {
	#	logIpsla("opSLAD: RTTcollect, using default lastupdate time.");
	#	$lastupdate = ($last - $nmistime) + $sysuptime + 3; # +3 for time mismatch
	#}
	logIpsla("opSLAD: RTTcollect, nmis $nmistime, sysup $sysuptime, rrdlast $last, lastupdate $lastupdate");
	# if $debug;

	my ($numrtts,$operstate) = snmpget($hoststr,"rttMonCtrlOperNumRtts.$entry","rttMonCtrlOperState.$entry");
	logIpsla("opSLAD: RTTcollect, $nno, numrtts $numrtts, operstate $operstate") if $debug;
	if (!$numrtts and !$operstate) { 
		logIpsla("opSLAD: RTTcollect, $nno, no answer, try to configure probe again");
		# configure probe node
		if (!runRTTstart($nno)) { 
			return undef; 
		}
		# new number from start
		$probe = $IPSLA->getProbe(probe => $nno);
		$entry = $probe->{entry}; 
		
		($numrtts,$operstate) = snmpget($hoststr,"rttMonCtrlOperNumRtts.$entry","rttMonCtrlOperState.$entry");
		if (!$numrtts and !$operstate) { 
			# Is SNMP working at all?  Check with system uptime.
			#($sysuptime) = snmpget($hoststr,"sysUpTime");
			### 2013-02-14 keiths, using snmpEngineTime as it is a better reflection of current processor uptime.
			($sysuptime) = snmpget($hoststr,"snmpEngineTime.0");			
			
			if ($sysuptime) {
				my $message = "error on reconfiguration of probe, entry=$entry";
				logIpsla("opSLAD: RTTcollect, $nno, $message");
				$IPSLA->updateProbe(probe => $nno, status => 'error', message => $message );
				return undef;
			}
			else {
				my $message = "node $probe->{pnode} does not respond";
				logIpsla("opSLAD: RTTcollect, $message");
				$IPSLA->updateMessage(probe => $nno, message => $message);
				return undef;
			}
		}
		else {
			logIpsla("opSLAD: RTTcollect, $nno, reconfigure successful, numrtts $numrtts, operstate $operstate");
		}
	}

	my $maxprobeupdate = 0;
	if ($probe->{optype} =~ /echo|tcpConnect|dns|dhcp/i) {
		# get history values from probe node
		if (!snmpmaptable($hoststr,
			sub () {
				my ($index, $time, $rtt, $sense, $addr) = @_;
				my $stime = convertUpTime($time);
				my ($a0,$a1,$a2,$a3) = unpack ("CCCC", $addr);
				my ($k0,$k1,$k2) = split /\./,$index,3;
				my $target = "$a0.$a1.$a2.$a3";

				logIpsla("opSLAD: RTTcollect, entry $entry, index $index, time $time ($stime), lastupdate $lastupdate, rtt $rtt, sense $sense, addr $target");
				#if $debug;
				if ( $stime > $maxprobeupdate ) {
					$maxprobeupdate = $stime;
				}
				
				if ($stime > $lastupdate) { 
					$values{$k1}{$k2}{index} = $index;
					#$values{$k1}{$k2}{delta} = $sysuptime - $stime;
					$values{$k1}{$k2}{stime} = $stime;
					$values{$k1}{$k2}{rtt} = $rtt;
					$values{$k1}{$k2}{addr} = $target;
					$values{$k1}{$k2}{sense} = $sense;
					# web page will display node names too
					if ( not $IPSLA->existDnsCache(lookup => $values{$k1}{$k2}{addr})) {
						my $nm = gethost($values{$k1}{$k2}{addr});
						if ($nm) {
							$IPSLA->updateDnsCache(lookup => $values{$k1}{$k2}{addr}, result => $nm->name)
						}
					}
				}
				else {
					if ($lastupdate - $stime >= 86400) { 
						logIpsla("opSLAD: RTTcollect, $nno, ERROR lastupdate is more than 1 day (86400 seconds) greater than the probe collect time, lastupdate=$lastupdate, stime=$stime.");
					}
				}
			},
			"rttMonHistoryCollectionSampleTime.$entry",
			"rttMonHistoryCollectionCompletionTime.$entry",
			"rttMonHistoryCollectionSense.$entry",
			"rttMonHistoryCollectionAddress.$entry"
			)) {

			my $message = "error get values from node $probe->{pnode}";
			logIpsla("opSLAD: RTTcollect, $message") if $debug;
			$IPSLA->updateProbe(probe => $nno, message => $message);
			return undef;
		}
		
		if ( $maxprobeupdate ) {
			# store the delta from the max probe update to the current time.
			my $newProbeTimeOffset = time() - $maxprobeupdate;
			logIpsla("opSLAD: TIME $nno; lastupdate=$lastupdate, maxprobeupdate=$maxprobeupdate newProbeTimeOffset=$newProbeTimeOffset.") if $debug;
			#$IPSLA->updateProbe(probe => $nno, lastupdate => $newProbeTimeOffset);
			$IPSLA->updateProbe(probe => $nno, lastupdate => $maxprobeupdate);
		}
		
		# store values in rrd
		foreach my $k1 (sort {$a <=> $b} keys %values) { # bucket number
			next if not exists $values{$k1}{'1'}{stime};
			# calculate time
			my $stime = $nmistime - $sysuptime + $values{$k1}{'1'}{stime}; # using timestamp of first bucket
			#my $stime = $nmistime - $values{$k1}{'1'}{delta} + $values{$k1}{'1'}{stime}; # using timestamp of first bucket
			my $val = "$stime:$values{$k1}{'1'}{sense}";
			my $tmp = "sense"; # dummy
			my $error = 0;
			$timeout_cnt++ if $values{$k1}{'1'}{sense} == 4 ; # timeout
			foreach my $k2 (sort {$a <=> $b} keys %{$values{$k1}}) { # index number
				$error++ if $values{$k1}{$k2}{sense} ne 1;
				next if $values{$k1}{$k2}{sense} == 0; # error
				my $a = $values{$k1}{$k2}{addr}; $a =~ s/\./_/g; # change dots
				$tmp .= ":1L1_${a}"; # template, L => RRD Line
				$val .= ":$values{$k1}{$k2}{rtt}"; # values
			}
			$tmp .= ":1P2_Error"; # P => RRD GPRINT
			$val .= ":$error";
			logIpsla("opSLAD: RTTcollect, Updating RRD, $nno, $tmp, $val") if $debug;
			runRRDupdate($nno,$tmp,$val);
		}
	}

	if ($probe->{optype} =~ /http/i) {
		my ($rtt, $dns, $tcp, $trans, $sense, $descr);
		if (($rtt, $dns, $tcp, $trans, $sense, $descr) = snmpget($hoststr,
				"rttMonLatestHTTPOperRTT.$entry",
				"rttMonLatestHTTPOperDNSRTT.$entry",
				"rttMonLatestHTTPOperTCPConnectRTT.$entry",
				"rttMonLatestHTTPOperTransactionRTT.$entry",
				"rttMonLatestHTTPOperSense.$entry",
				"rttMonLatestHTTPErrorSenseDescription.$entry")) {
			my $stime = time();
			my $tout=0;my $dnstout=0;my $tcptout=0;my $trantout=0;my $dnserr=0;my $httperr=0;my $error=0;
			if ($sense != 1 ) { 
				if ($sense == 11) { $dnstout = 1; }
				elsif ($sense == 12) { $tcptout = 1; }
				elsif ($sense == 13) { $trantout = 1; }
		##		elsif ($sense == 14) { $dnserr = 1; }
		##		elsif ($sense == 15) { $httperr = 1; }
				else { $error = 1; }
			}
			my $tmp = "sense:6L1_httpRTT:6L1_dnsRTT:6L1_tcpConnectRTT:6L1_transactionRTT:P2_dnsTimeout:P2_tcpConnTimeout:P2_transTimeout:P2_Error";
			my $val = "$stime:$sense:$rtt:$dns:$tcp:$trans:$dnstout:$tcptout:$trantout:$error";
			runRRDupdate($nno,$tmp,$val);

		} else {
			my $message = "error get values of node $probe->{pnode}, snmp - rttMonLatestHTTP";
			logIpsla("opSLAD: RTTcollect, $message") if $debug;
			$IPSLA->updateProbe(probe => $nno, message => $message);
			return undef;
		}

	} 
	if ($probe->{optype} =~ /jitter/i) {
		my ($posSD, $negSD, $posDS, $negDS, $lossSD, $lossDS, $OoS, $MIA, $late, $mos, $icpif, $sense);
		if (($posSD, $negSD, $posDS, $negDS, $lossSD, $lossDS, $OoS, $MIA, $late, $mos, $icpif, $sense) = snmpget($hoststr,
				"rttMonLatestJitterOperMaxOfPositivesSD.$entry",
				"rttMonLatestJitterOperMaxOfNegativesSD.$entry",
				"rttMonLatestJitterOperMaxOfPositivesDS.$entry",
				"rttMonLatestJitterOperMaxOfNegativesDS.$entry",
				"rttMonLatestJitterOperPacketLossSD.$entry",
				"rttMonLatestJitterOperPacketLossDS.$entry",
				"rttMonLatestJitterOperPacketOutOfSequence.$entry",
				"rttMonLatestJitterOperPacketMIA.$entry",
				"rttMonLatestJitterOperPacketLateArrival.$entry",
				"rttMonLatestJitterOperMOS.$entry",
				"rttMonLatestJitterOperICPIF.$entry",
				"rttMonLatestJitterOperSense.$entry")) {
			my $stime = time();
			my $pkterr = $lossSD + $lossDS + $OoS + $MIA + $late ;
			$timeout_cnt++ if $sense == 4; # timeout
			my $tmpcodec = $probe->{codec} ne "" ? ":3L2_mos:2L2_icpif" : "";
			my $valcodec = $probe->{codec} ne "" ? ":$mos:$icpif" : "";
			$negSD *= -1;
			$negDS *= -1;
			my $tmp = "sense:4L2_positivesSD:4L2_negativesSD:4L2_positivesDS:4L2_negativesDS".$tmpcodec.":0P2_packetLossSD:0P2_packetLossDS:0P2_packetError";
			my $val = "$stime:$sense:$posSD:$negSD:$posDS:$negDS".$valcodec.":$lossSD:$lossDS:$pkterr";
			runRRDupdate($nno,$tmp,$val);

		} else {
			my $message = "error get values from probe, snmp => rttMonLatestJitter";
			logIpsla("opSLAD: RTTcollect, $message") if $debug;
			$IPSLA->updateProbe(probe => $nno, message => $message,	status => "error", lastupdate => $lastupdate	);
			return undef;
		}
	}

	runRTTresponder($nno) if $timeout_cnt; # try to config responder again in case of timeout of probe

	return 1;

}

sub runRRDupdate {
	my $nno = shift; # cfg key
	my $tmp = shift; # template
	my $val = shift; # values

	my $probe = $IPSLA->getProbe(probe => $nno);

	# adjust items in cfg
	my @names = split /:/,$tmp ;
	my @dsnm = grep { $_ if $probe->{items} !~ /$_/ and $_ ne "sense" } @names ;
	if (@dsnm) {
		$probe->{items} = join(':',(split(/:/,$probe->{items}),@dsnm)); # append new items
		$IPSLA->updateProbe(probe => $nno, items => $probe->{items});
	}

	my @dsnames = map { /^\d+[A-Z]\d+_(.*)/ ? $1 : $_ ;} @names ; # remove leading info for web display
	my $dsnames = join':',@dsnames; # clean concatenated DS names

	logIpsla("opSLAD: rddupdate, $dsnames, $val") if $debug;

	my @options = ( "-t", $dsnames, $val);

	my $database = $probe->{database};
	if ( not (-f $database and -r $database and -w $database) ) { 
		runRRDcreate($nno,$database) or return undef;
	} 

	# update RRD
	RRDs::update($database,@options);
	my $Error = RRDs::error;
	if ($Error =~ /Template contains more DS|unknown DS name|tmplt contains more DS/i) {
		logIpsla("opSLAD: updateRRD: missing DataSource in $database, try to update") if $debug;
		# find the DS names in the existing database (format ds[name].* )
		my $info = RRDs::info($database);
		my $rrdnames = ":";
		foreach my $key (keys %$info) {
			if ( $key =~ /^ds\[([a-zA-Z0-9_]{1,19})\].+/) { $rrdnames .= "$1:";}
		}
		# find the missing DS name
		my @ds = ();
		my $frequence = ($probe->{optype} =~ /stats/) ? 3600 : $probe->{frequence} ;
		foreach my $dsnm (@dsnames) { 
			if ( $rrdnames !~ /:$dsnm:/ ) { 
				my $hb = $frequence * 3;
				push @ds,"DS:$dsnm:GAUGE:$hb:U:U";
			}
		}
		&addDStoRRD($database,@ds) if scalar @ds > 0 ;
		sleep(2);
		RRDs::update($database,@options);
		$Error = RRDs::error;
	}
	
	if ($Error eq "") {
		logIpsla("opSLAD: RRDupdate, database $database updated") if $debug;
		if ($probe->{message} ne "") { 
			$IPSLA->updateMessage(probe => $nno, message => "NULL" );
		}
	} 
	else {
		my $message = "error on update rrd database, $Error";
		logIpsla("opSLAD: RRDupdate, $message") if $debug;
		$IPSLA->updateProbe(probe => $nno, message => $message);
	}
}

sub runRRDcreate {
	my $nno = shift; # cfg key
	my $database = shift ; # name of database

	my $probe = $IPSLA->getProbe(probe => $nno);

	# if the directory doesn't exist create it
	my $dir = "$C->{database_root}/misc";
	if (not -d "$dir") {
		mkdir $dir, 0775 or die "Cannot mkdir $dir: $!\nstopped";
	}

	my $frequence = ($probe->{optype} =~ /stats/) ? 3600 : $probe->{frequence} ;

	# RRD sizing
	my $RRD_poll = $frequence ;
	my $RRD_hbeat = $RRD_poll * 3;
	my $RRA_step = 1;
	my $RRA_rows = ((86400/$frequence) * 7) * $probe->{history}; # calc. db size

	my $time  = time()-10;
	my @options;

	@options = ( "-b", $time, "-s", $RRD_poll );

	push @options, "DS:sense:GAUGE:$RRD_hbeat:U:U"; # must be one DS at least

	push @options, "RRA:AVERAGE:0.5:$RRA_step:$RRA_rows";
	push @options, "RRA:MAX:0:$RRA_step:$RRA_rows";

	RRDs::create("$database",@options);
	my $ERROR = RRDs::error;
	if ($ERROR) {
		my $message = "unable to create database $database, $ERROR";
		logIpsla("opSLAD: RRDcreate, $message");
		$IPSLA->updateProbe(probe => $nno, message => $message, status => "error");
		return undef;
	} else {
		logIpsla("opSLAD: RRDcreate, created database $database, freq. $frequence sec.") if $debug;
	}
	# set file owner and permission, default: nmis, 0775.
	setFileProt($database);

	return 1;
}

sub runRTTstats {

	my $NT = loadLocalNodeTable();

	foreach my $pnode (keys %{$RTTcache{stats}{node}}) {
		logIpsla("opSLAD: RTTstats, get statistics from probe node $pnode") if $debug;
		my %runStats = (
			echo => 0,
			jitter => 0,
			http => 0
		); 
		# resolve dns name 
		if ($RTTcache{dns}{$pnode} eq "") { 
			resolveDNS($pnode);
		}
		my $node = $RTTcache{dns}{$pnode} ;
		$node = $pnode if $node eq "";
		my $community = $IPSLA->getCommunity(node => $pnode);
		my $port = $NT->{$pnode}{snmpport} ;
		my $host = $NT->{$pnode}{host};
		my $hoststr = "$community"."@"."$host".":::::2";
		foreach my $nno (@{$RTTcache{stats}{node}{$pnode}}) {
			my $probe = $IPSLA->getProbe(probe => $nno);
			if ( $probe->{optype} =~ /echo|dhcp|dns|tcpConnect/i and not $runStats{echo} ) {
				$runStats{echo} = 1;
				runRTTecho_stats($hoststr,$pnode) ;
			}
			elsif ( $probe->{optype} =~ /jitter/i and not $runStats{jitter} ) {
				$runStats{jitter} = 1;
				runRTTjitter_stats($hoststr,$pnode) ;
			}
			elsif ( $probe->{optype} =~ /http/i and not $runStats{http} ) {
				$runStats{http} = 1;
				runRTThttp_stats($hoststr,$pnode) ;
			}
		}
	}
}

# Collect the statistics hourly.
# Operation pathEcho does not work correctly because sometimes different paths are found.

sub runRTTecho_stats {
	my $hoststr = shift;
	my $pnode = shift;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $hop;
	my $mibname;
	my @oid_values;
	my $stime = time();

	logIpsla("opSLAD: RTTecho_stats, get table rttMonStatsCollectTable") if $debug;
	@oid_values = snmpgetbulk2($hoststr,0,20,"rttMonStatsCollectTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  .1.3.6.1.4.1.9.9.42.1.3.2.1.type.entry.time.path.hop
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonStatsCollectTable},@oid_values ) {
	#		logIpsla("opSLAD: CollectTable => $oid_value") if $debug > 2;
			my ($oid,$value) = split ":",$oid_value;
			if ($oid =~ /^(.*)\.(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
				$entry = $2;
				$timevalue = $3;
				$mibname = $revOIDS{$1};
				$hop = $5;
				$RTTdata{$entry}{$mibname}{$hop}{$timevalue} = $value;
			}
		}
		@oid_values = ();
		logIpsla("opSLAD: RTTecho_stats, get table rttMonStatsCaptureTable") if $debug;
		@oid_values = snmpgetbulk2($hoststr,0,20,"rttMonStatsCaptureTable");
		if (@oid_values) {
			# add them into the hash.
			# push the multiple time value here as well, and iterate over it later
			# example result  .1.3.6.1.4.1.9.9.42.1.3.1.1.type.entry.Time.path.hop.dis
		    for my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonStatsCaptureTable},@oid_values ) {
			#	logIpsla("opSLAD: CaptureTable => $oid_value") if $debug;
				my ($oid,$value) = split ":",$oid_value;
				if ($oid =~ /^(.*)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
					$entry = $2;
					$timevalue = $3;
					$mibname = $revOIDS{$1};
					$hop = $5;
					$RTTdata{$entry}{$mibname}{$hop}{$timevalue} = $value;
				}
			}
			# now iterate over the hash, get the oldest value, and add to the data hash
			foreach $entry ( keys %RTTdata ) {
				for $mibname ( keys %{ $RTTdata{$entry} } ) {
					my $tval = "";
					my $val;
					for $hop ( keys %{$RTTdata{$entry}{$mibname} } ) {
						for $timevalue ( keys %{$RTTdata{$entry}{$mibname}{$hop} } ) {
							$tval ||= $timevalue;
							($timevalue gt $tval) || ($tval = $timevalue);
							$val = $RTTdata{$entry}{$mibname}{$hop}{$tval};		# save the value
						}
						$Rtr{$entry}{$hop}{$mibname} = $val;			# add the new record into the data hash
						push @entries, $entry if not grep /$entry/, @entries;
					}
				}
			}

			# store in RRD
			foreach $entry (@entries) {
				my $Error = 0;
				my $val = "$stime:0";
				my $tmp = "sense"; # dummy
				# search entry+node in config
				my @keys = $IPSLA->getProbeKeys();
				foreach my $nno (@keys) {
					my $probe = $IPSLA->getProbe(probe => $nno);
					if ($probe->{entry} eq $entry and $probe->{pnode} eq $pnode 
							and $probe->{optype} =~ /echo-stats|dhcp-stats|dns-stats|tcpConnect-stats|udpEcho-stats|pathEcho-stats/i) {
						logIpsla("opSLAD: RTTecho-stats, key found for entry $entry in IPSLA DB => $nno") if $debug;
						my $Trys = 0;
						foreach $hop (sort {$a <=> $b} keys %{$Rtr{$entry}}) {
							# avoid divide by zero errors
							my $Avg = 0;
							my $target = $probe->{ip}{$probe->{tnode}}; # ip address of target
							if ( $Rtr{$entry}{$hop}{rttMonStatsCaptureCompletions} ) {	
								$Avg= $Rtr{$entry}{$hop}{rttMonStatsCaptureSumCompletionTime} / $Rtr{$entry}{$hop}{rttMonStatsCaptureCompletions};
							}
							my $Max = $Rtr{$entry}{$hop}{rttMonStatsCaptureCompletionTimeMax};

							$Trys += $Rtr{$entry}{$hop}{rttMonStatsCaptureCompletions} + $Rtr{$entry}{$hop}{rttMonStatsCollectTimeouts} + $Rtr{$entry}{$hop}{rttMonStatsCollectDrops};
							$Error  += $Rtr{$entry}{$hop}{rttMonStatsCollectDrops} + $Rtr{$entry}{$hop}{rttMonStatsCollectTimeouts};

							if ($Rtr{$entry}{$hop}{rttMonStatsCollectAddress} ne "") {
								my ($a0,$a1,$a2,$a3) = unpack ("CCCC", $Rtr{$entry}{$hop}{rttMonStatsCollectAddress});
								$target = "${a0}.${a1}.${a2}.${a3}";
							}

							if ( not $IPSLA->existDnsCache(lookup => $target)) {
								my $nm = gethost($target);
								if ($nm) {
									$IPSLA->updateDnsCache(lookup => $target, result => $nm->name)
								}
							}

							$target =~ s/\./_/g; # change dots in underscores for DS names
							$tmp .= ":6L1_${target}:1M1_${target}_Max";
							$val .= ":$Avg:$Max";
						}
						$tmp .= ":0P2_Trys:0P2_Error";
						$val .= ":$Trys:$Error";
						runRRDupdate($nno,$tmp,$val);
						last;
					}
				}
			}
		} else {
			logIpsla("opSLAD: RTTget_stats, no values from snmpgetbulk of CaptureTable") if $debug;
		}
	} else {
		logIpsla("opSLAD: RTTget_stats, no values from snmpgetbulk of CollectTable") if $debug;
	}
	writeHashtoVar("ipsla-echo-data",\%RTTdata) if $debug > 1; # debug on disk
	writeHashtoVar("ipsla-echo-vals",\%Rtr) if $debug > 1; # debug on disk
}

sub runRTTjitter_stats {
	my $hoststr = shift;
	my $pnode = shift;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $mibname;
	my @oid_values;
	my $stime = time();

	logIpsla("opSLAD: RTTjitter_stats, get table rttMonJitterStatsTable") if $debug;
	@oid_values = snmpgetbulk2($hoststr,0,20,"rttMonJitterStatsTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  1.3.6.1.4.1.9.9.42.1.3.5.1.type.entry.TimeValue
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonJitterStatsTable},@oid_values ) {
	#		logIpsla("opSLAD: JitterTable => $oid_value") if $debug > 1;
			my ($oid,$value) = split ":",$oid_value;
			if ($oid =~ /^(.*)\.(\d+)\.(\d+)$/) {
				$entry = $2;
				$timevalue = $3;
				$mibname = $revOIDS{$1};
				$RTTdata{$entry}{$mibname}{$timevalue} = $value;
			}
		}
		# now iterate over the hash, get the oldest value, and add to the data hash
		foreach $entry ( keys %RTTdata ) {
			for $mibname ( keys %{ $RTTdata{$entry} } ) {
				my $tval = "";
				my $val;
				for $timevalue ( keys %{ $RTTdata{$entry}{$mibname} } ) {
					$tval ||= $timevalue;
				        ($timevalue gt $tval) || ($tval = $timevalue);
					$val = $RTTdata{$entry}{$mibname}{$tval};		# save the value
				      }
				$Rtr{$entry}{$mibname} = $val;				# add the new record into the data hash
				push @entries, $entry if not grep /$entry/, @entries;
			}
		}
		
		# store in RRD
		foreach $entry (@entries) {
			# search for entry+node in probe config
			my @keys = $IPSLA->getProbeKeys();
			foreach my $nno (@keys) {
				my $probe = $IPSLA->getProbe(probe => $nno);
				if ($probe->{entry} eq $entry and $probe->{pnode} eq $pnode and $probe->{optype} =~ /jitter-stats|jitter-voip-stats/) {
					logIpsla("opSLAD: RTTjitter-stats, key found for entry $entry in IPSLA DB => $nno") if $debug;

					my $PacketLossSD = $Rtr{$entry}{rttMonJitterStatsPacketLossSD};
					my $PacketLossDS = $Rtr{$entry}{rttMonJitterStatsPacketLossDS};
					my $pkterr;

					# avoid divide by zero erros
					my $perPacketLoss = 0;
					if ( $Rtr{$entry}{rttMonJitterStatsPacketLossSD} + $Rtr{$entry}{rttMonJitterStatsPacketLossDS} + $Rtr{$entry}{rttMonJitterStatsPacketMIA} + $Rtr{$entry}{rttMonJitterStatsNumOfRTT} ) {
						$perPacketLoss = ($Rtr{$entry}{rttMonJitterStatsPacketLossSD} + $Rtr{$entry}{rttMonJitterStatsPacketLossSD} + $Rtr{$entry}{rttMonJitterStatsPacketMIA}) /
							($Rtr{$entry}{rttMonJitterStatsPacketLossSD} + $Rtr{$entry}{rttMonJitterStatsPacketLossDS} + $Rtr{$entry}{rttMonJitterStatsPacketMIA} + $Rtr{$entry}{rttMonJitterStatsNumOfRTT});
					}
					else { $perPacketLoss = 0; }

					# avoid divide by zero errosr
					my $PositiveJitterSD = 0;
					my $NegativeJitterSD = 0;
					my $PositiveJitterDS = 0;
					my $NegativeJitterDS = 0;
	
					if ( $Rtr{$entry}{rttMonJitterStatsNumOfPositivesSD}
						and $Rtr{$entry}{rttMonJitterStatsNumOfNegativesSD}
						and $Rtr{$entry}{rttMonJitterStatsNumOfPositivesDS}
						and $Rtr{$entry}{rttMonJitterStatsNumOfNegativesDS} ) {
					$PositiveJitterSD = $Rtr{$entry}{rttMonJitterStatsSumOfPositivesSD} / $Rtr{$entry}{rttMonJitterStatsNumOfPositivesSD};
					$NegativeJitterSD = $Rtr{$entry}{rttMonJitterStatsSumOfNegativesSD} / $Rtr{$entry}{rttMonJitterStatsNumOfNegativesSD};
					$PositiveJitterDS = $Rtr{$entry}{rttMonJitterStatsSumOfPositivesDS} / $Rtr{$entry}{rttMonJitterStatsNumOfPositivesDS};
					$NegativeJitterDS = $Rtr{$entry}{rttMonJitterStatsSumOfNegativesDS} / $Rtr{$entry}{rttMonJitterStatsNumOfNegativesDS};
					}
	
					# avoid divide by zero errors
					my $avgRTT = 0;
					my $avgJitter = 0;
					if ( $Rtr{$entry}{rttMonJitterStatsNumOfRTT} ) {
						$avgRTT = $Rtr{$entry}{rttMonJitterStatsRTTSum} / $Rtr{$entry}{rttMonJitterStatsNumOfRTT};
						$avgJitter = ($Rtr{$entry}{rttMonJitterStatsSumOfPositivesSD} +
								 $Rtr{$entry}{rttMonJitterStatsSumOfNegativesSD} +
								 $Rtr{$entry}{rttMonJitterStatsSumOfPositivesDS} +
								 $Rtr{$entry}{rttMonJitterStatsSumOfNegativesDS} ) / ($Rtr{$entry}{rttMonJitterStatsNumOfRTT} * 2);
					}
					my $MinOfMos = $Rtr{$entry}{rttMonJitterStatsMinOfMOS};
					my $MaxOfMos = $Rtr{$entry}{rttMonJitterStatsMaxOfMOS};
					my $MinOfICPIF = $Rtr{$entry}{rttMonJitterStatsMinOfICPIF};
					my $MaxOfICPIF = $Rtr{$entry}{rttMonJitterStatsMaxOfICPIF};

					$NegativeJitterSD *= -1;
					$NegativeJitterDS *= -1;

					my $tmpcodec = $probe->{codec} ne "" ? ":9L0_MaxOfMos:9L0_MinOfMos:8L0_MaxOfICPIF:8L0_MinOfICPIF" : "";
					my $valcodec = $probe->{codec} ne "" ? ":$MaxOfMos:$MinOfMos:$MaxOfICPIF:$MinOfICPIF" : "";
					my $tmp = "sense:7L2_positivesSD:7L2_negativesSD:7L2_positivesDS:7L2_negativesDS:6L1_avgRTT:7L2_avgJitter".$tmpcodec.":0P2_packetLossSD:0P2_packetLossDS:0P2_packetError";
					my $val = "$stime:0:$PositiveJitterSD:$NegativeJitterSD:$PositiveJitterDS:$NegativeJitterDS:$avgRTT:$avgJitter".$valcodec.":$PacketLossSD:$PacketLossDS:$pkterr";
					runRRDupdate($nno,$tmp,$val);
					last;
				}
			}
		}
	} else {
		logIpsla("opSLAD: RTTget_stats, no values from snmpgetbulk of JitterTable") if $debug;
	}
}

sub runRTThttp_stats {
	my $hoststr = shift;
	my $pnode = shift;

	logIpsla("opSLAD: RTThttp_stats, get table rttMonHTTPStatsTable") if $debug;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $mibname;
	my @oid_values;
	my $stime = time();

	@oid_values = snmpgetbulk2($hoststr,0,20,"rttMonHTTPStatsTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  1.3.6.1.4.1.9.9.42.1.3.4.1.type.entry.TimeValue
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonHTTPStatsTable},@oid_values ) {
	#		logIpsla("opSLAD: HTTPTable => $oid_value") if $debug > 1;
			my ($oid,$value) = split ":",$oid_value;
			if ($oid =~ /^(.*)\.(\d+)\.(\d+)$/) {
				$entry = $2;
				$timevalue = $3;
				$mibname = $revOIDS{$1};
				$RTTdata{$entry}{$mibname}{$timevalue} = $value;
			}
		}
		# now iterate over the hash, get the oldest value, and add to the data hash
	    foreach $entry ( keys %RTTdata ) {
	        for $mibname ( keys %{ $RTTdata{$entry} } ) {
				my $tval = "";
				my $val;
				for $timevalue ( keys %{ $RTTdata{$entry}{$mibname} } ) {
					$tval ||= $timevalue;
	    	        ($timevalue gt $tval) || ($tval = $timevalue);
					$val = $RTTdata{$entry}{$mibname}{$tval};		# save the value
	            }
				$Rtr{$entry}{$mibname} = $val;				# add the new record into the data hash
				push @entries, $entry if not grep /$entry/, @entries;
	       	}
	   	}

		# store in RRD
		foreach $entry (@entries) {
			# search for entry+node in probe config
			my @keys = $IPSLA->getProbeKeys();
			foreach my $nno (@keys) {
				my $probe = $IPSLA->getProbe(probe => $nno);
				if ($probe->{entry} eq $entry and $probe->{pnode} eq $pnode and $probe->{optype} =~ /http-stats/) {
					logIpsla("opSLAD: RTThttp-stats, key found for entry $entry in IPSLA DB => $nno") if $debug;
					my $AvgRTT =0;
					my $AvgDNS = 0;
					my $AvgTCP = 0;
					my $AvgTran = 0;

					if ( $Rtr{$entry}{rttMonHTTPStatsCompletions} ) {
						$AvgRTT = $Rtr{$entry}{rttMonHTTPStatsRTTSum} / $Rtr{$entry}{rttMonHTTPStatsCompletions};
						$AvgDNS = $Rtr{$entry}{rttMonHTTPStatsDNSRTTSum} / $Rtr{$entry}{rttMonHTTPStatsCompletions};
						$AvgTCP = $Rtr{$entry}{rttMonHTTPStatsTCPConnectRTTSum} / $Rtr{$entry}{rttMonHTTPStatsCompletions};
						$AvgTran = $Rtr{$entry}{rttMonHTTPStatsTransactionRTTSum} / $Rtr{$entry}{rttMonHTTPStatsCompletions};
					}
					my $AvgMax = $Rtr{$entry}{rttMonHTTPStatsRTTMax};
					my $Trys = $Rtr{$entry}{rttMonHTTPStatsCompletions} + $Rtr{$entry}{rttMonHTTPStatsHTTPError} + $Rtr{$entry}{rttMonHTTPStatsTCPConnectTimeout} + $Rtr{$entry}{rttMonHTTPStatsDNSServerTimeout} + $Rtr{$entry}{rttMonHTTPStatsDNSQueryError} + $Rtr{$entry}{rttMonHTTPStatsError} + $Rtr{$entry}{rttMonHTTPStatsTransactionsTimeout};
					my $Over = $Rtr{$entry}{rttMonHTTPStatsOverThresholds};
					my $Error = $Rtr{$entry}{rttMonHTTPStatsHTTPError} 
								+ $Rtr{$entry}{rttMonHTTPStatsDNSQueryError}
								+ $Rtr{$entry}{rttMonHTTPStatsError}
								+ $Rtr{$entry}{rttMonHTTPStatsTCPConnectTimeout}
								+ $Rtr{$entry}{rttMonHTTPStatsDNSServerTimeout}
								+ $Rtr{$entry}{rttMonHTTPStatsTransactionsTimeout};
	
					my $tmp = "sense:6L1_httpRTT:6L1_dnsRTT:6L1_tcpConnectRTT:6L1_transactionRTT:0P2_Trys:0A0_OverThresholds:0P2_Error";
					my $val = "$stime:0:$AvgRTT:$AvgDNS:$AvgTCP:$AvgTran:$Trys:$Over:$Error";
					runRRDupdate($nno,$tmp,$val);
					last;
				}
			}
		}
	} else {
		logIpsla("opSLAD: RTThttp_stats, no values from snmpgetbulk of httpTable") if $debug;
	}
}



#=======

# modified version of SNMP_util
# now the (single) table will be completely read in

sub snmpgetbulk2 ($$$$) {
  my($hoststr, $nr, $mr, @vars) = @_;
  my(@enoid, $var, $response, $bindings, $binding);
  my($value, $upoid, $oid, @retvals);
  my($noid);
  my $session;

  $session = &SNMP_util::snmpopen($hoststr, 0, \@vars);
  if (!defined($session)) {
    carp "SNMPGETBULK Problem for $hoststr\n"
      unless ($SNMP_Session::suppress_warnings > 1);
    return undef;
  }

  @enoid = &SNMP_util::toOID(@vars);
  return undef unless defined $enoid[0];

  undef @vars;
  undef @retvals;
  foreach $noid (@enoid) {
    $upoid = pretty_print($noid);
    push(@vars, $upoid);
  }
  for my $var (@vars) {
    my $tempo = $var;
    while ($tempo =~ /^$var/) {
      if ($session->getbulk_request_response($nr, $mr, @enoid)) {
        $response = $session->pdu_buffer;
        ($bindings) = $session->decode_get_response($response);
        while ($bindings) {
          ($binding, $bindings) = decode_sequence($bindings);
          ($oid, $value) = decode_by_template($binding, "%O%@");
          $tempo = pretty_print($oid);
          my $tempv = pretty_print($value);
          push @retvals, "$tempo:$tempv";
        }
        $enoid[0] = &SNMP_util::encode_oid_with_errmsg($tempo);
      } else {
        $var = join(' ', @vars);
        carp "SNMPGETBULK Problem for $var on $hoststr\n"
          unless ($SNMP_Session::suppress_warnings > 1);
	    return undef;
      }
    }
  }
  return (@retvals);
}

sub writeHashtoVar {
	my $file = shift; # filename
	my $data = shift; # address of hash
	my $handle;

	my $datafile = "$C->{'<nmis_var>'}/$file.nmis";

	open DB, ">$datafile" or warn returnTime." writeHashtoVar: cannot open $datafile: $!\n";
	flock(DB, LOCK_EX) or warn returnTime." writeHashtoVar: can't lock file $datafile, $!\n";
	print DB Data::Dumper->Dump([$data], [qw(*hash)]);
	close DB;

	setFileProt($datafile);
	print returnTime." writeHashtoVar: wrote @{[ scalar keys %{$data} ]} records to $datafile\n" if $debug > 1;

}

sub readVartoHash {
	my $file = shift; # primairy part of filename to read
	my %hash;
	my $handle;
	my $line;

	my $datafile = "$C->{'<nmis_var>'}/$file.nmis";

	if ( -r $datafile ) {
		sysopen($handle, $datafile, O_RDONLY )
			or warn returnTime." readVartoHash: cannot open $datafile, $!\n";
		flock($handle, LOCK_SH) or warn returnTime." readVartoHash: can't lock file $datafile, $!\n";
		while (<$handle>) { $line .= $_; }
		close $handle;
		
		# convert data to hash
		%hash = eval $line;
	} else {
		print returnTime." readVartoHash: file $datafile does not exist\n" if $debug;
	}
	print returnTime."  readVartoHash: read @{[ scalar keys %hash ]} records from $datafile\n" if $debug > 1;

	return %hash;
}


#=====
