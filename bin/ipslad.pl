#!/usr/bin/perl
#
## $Id: ipslad.pl,v 8.5 2012/03/26 06:26:19 keiths Exp $
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
use POSIX;
use RRDs 1.000.490;
use rrdfunc;
use Net::hostent;
use Socket;
use Carp;

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
my $vardir = $nvp{vardir};

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

unless ( $vardir ) { $vardir = $C->{'<nmis_var>'} }

# load mib
foreach my $file ( "CISCO-RTTMON-MIB.oid" ) {
	if ( ! -r "$C->{mib_root}/$file" ) { 
		 warn returnTime." ipslad.pl, mib file $C->{mib_root}/$file not found.\n";
	}
	else {
		loadoids( "$C->{mib_root}/$file" );
		if ($debug) { print "\t Loaded mib $C->{mib_root}/$file\n"; }
		if ( $SNMP_Simple::errmsg ) {
			warn returnTime." ipslad.pl, SNMP error. errmsg=$SNMP_Simple::errmsg\n";
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


my %RTTcfg; # global, configuration values
my %RTTcache; # temp. cache

$SNMP_Simple::suppress_warnings = 1;
$SNMP_Session::suppress_warnings = 1; # logging to log/ipsla.log

if ( $nvp{type} eq "update") {
	logIpsla("IPSLAD: update request from ipsla.pl received") if $debug;
	runRTT(0);
	exit 0;
}

# See if another instance of ourself is running, if so kill the process
my $pidfile = "/var/run/ipslad.pid";

if (-f $pidfile) {
  open(F, "<$pidfile");
  $pid = <F>;
  close(F);
  chomp $pid;
  if ($pid != $$) {
    logIpsla("IPSLAD: pidfile exists killing the pidfile process $pid");
    kill 9, $pid;
    unlink($pidfile);
    logIpsla("IPSLAD: pidfile $pidfile deleted");
  }
}

# As we are paranoid and running as root, chroot to a safe directory:
# note: if we go anywhere else that will break the file paths.
#chroot("/") or die "Couldn't chroot to /: $!";


FORK: {
    if ($pid = fork) {
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
		$0="NMIS ipslad debug=$debug";
		
		# Announce our presence via a PID file

		open(PID, ">$pidfile") || exit;
		print PID $$; close(PID);
		logIpsla("IPSLAD: pidfile $pidfile created");

		# Perform a sanity check. If the current PID file is not the same as
		# our PID then we have become detached somehow, so just exit

		open(PID, "<$pidfile") || exit;
		$pid = <PID>; close(PID);
		chomp $pid;
		exit unless $pid == $$;

		# Record our (re)starting in the event log

		logIpsla("IPSLAD: start: pidfile=$pidfile pid=$pid");

		# code body here.

		# setup a log file and trap any error messages as well.
		umask 0;
		open STDOUT, ">>$C->{log_root}/ipsla.log" or die "Can't write to $C->{log_root}/ipsla.log: $!";
		open STDERR, ">>$C->{log_root}/ipsla.log" or die "Can't write to $C->{log_root}/ipsla.log: $!";

		# setup a trap for fatal signals, setting a flag to indicate we need to gracefully exit.
		$SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&signal_handler;
		$SIG{'CHLD'} = 'IGNORE';		# autoreap zombies

		# print a short status message and flush any errors so far to the file.
		logIpsla("IPSLAD: forked successfully debug=$debug\n");

		# 
		my $time1;
		my $time2;
		while ($time_to_die == 0 ) { 
			$time1 = time();
			open(PID, '+<',"$pidfile"); print PID $$; close(PID); # signal client that we are running again
			runRTT(1);
			$time2 = time(); 
			if ( ($time2 - $time1) > $collect_time ) { logIpsla("IPSLAD: runPD, runtime of collecting exceed collect interval time\n"); }
			sleep( $collect_time - ($time2 % $collect_time) );
		} # end of while loop
	} # end of child
    elsif ($! == EAGAIN) {
        # EAGAIN is the supposedly recoverable fork error
        sleep 5;
        redo FORK;
    }
    else {
        # weird fork error
        die "IPSLAD: Can't fork: $!\n";
    }
}

sub signal_handler {
	my $signame = shift;
	our $time_to_die++;
	my $time = scalar localtime();
	die "IPSLAD: - I have died - Somebody sent me a SIG$signame!\n";
}

#========


sub runRTT {
	my $collect = shift;
	
	# Too verbose!
	#logIpsla("IPSLAD: runRTT just requested debug=$debug\n");

	my $statusPDenable;
	my $runtime;

	if ($collect) {
		$runtime = time(); # start of collecting
	}

	# read config
	%RTTcfg = &readVartoHash("ipslacfg"); # global hash

	delete $RTTcache{stats} ;
	
	if ( $debug ) {
		print "DUMPER\n";
		Dumper(%RTTcfg);		
	}

	my @keys = keys %RTTcfg;
	
	logIpsla("IPSLAD: runRTT Begin debug=$debug\n") if $debug;
	foreach my $nno (@keys) {
		logIpsla("IPSLAD: runRTT nno=$nno debug=$debug\n") if $debug;
		if (exists $RTTcfg{$nno}{pnode} and $RTTcfg{$nno}{pnode} ne ""){
			logIpsla("IPSLAD: RTT, key $nno, function ($RTTcfg{$nno}{func}), status ($RTTcfg{$nno}{status})\n") if $debug;
			if ($RTTcfg{$nno}{func} =~ /start|remove|stop/) {
				$RTTcfg{$nno}{message} = "";
				if ($RTTcfg{$nno}{func} eq "start") {
					if (runRTTstart($nno)) {$RTTcfg{$nno}{func} = "";} # done
				} elsif ($RTTcfg{$nno}{func} eq "stop" or $RTTcfg{$nno}{func} eq "remove") {
					if (runRTTstop($nno)) {$RTTcfg{$nno}{func} = "";} # done
				}
				runRTTmodify($nno); # store modified config
			}
			if ($RTTcfg{$nno}{status} eq "running" and $collect) {
				# optimize collect
				if ($RTTcache{$nno}{nexttime} <= $runtime) {
					if ($RTTcfg{$nno}{optype} =~ /stats/i ) {
						push @{$RTTcache{stats}{node}{$RTTcfg{$nno}{pnode}}},$nno;
						$RTTcache{$nno}{nexttime} = $runtime + 3600; # hourly
					} else {
						# collect based on history buckets
						if (runRTTcollect($nno)) {
							if ($RTTcfg{$nno}{optype} =~ /echo|tcpConnect|dhcp|dns/i) {
								$RTTcache{$nno}{nexttime} = $runtime + 
									($RTTcfg{$nno}{frequence} > $bucket_interval) ? $RTTcfg{$nno}{frequence} : $bucket_interval;
							}
						}
					}
					logIpsla("IPSLAD: RTT, next collect after ".($RTTcache{$nno}{nexttime}-$runtime)." seconds") if $debug;
				}
			}
		}
	}
	logIpsla("IPSLAD: runRTT End debug=$debug\n") if $debug;
	
	if (scalar(keys %{$RTTcache{stats}})) {
		# also collecting of statistics, hourly
		runRTTstats();
	}

}

sub runRTTmodify {
	my $nno = shift;

	# get RTTcfg from /var
	my %cfg = &readVartoHash("ipslacfg"); # config database of probes
	my $status = $RTTcfg{$nno}{status};

	if ($RTTcfg{$nno}{status} eq "remove") {
		delete $RTTcache{dns}{$RTTcfg{$nno}{pnode}};
		delete $RTTcache{$nno};
		delete $RTTcfg{$nno};
		delete $cfg{$nno};
	} else {
		# store modified values in hash
		foreach my $k (keys %{$RTTcfg{$nno}}) {
			$cfg{$nno}{$k} = $RTTcfg{$nno}{$k};
		}
		$cfg{$RTTcfg{$nno}{pnode}}{entry} = $RTTcfg{$RTTcfg{$nno}{pnode}}{entry};
	}
	writeHashtoVar("ipslacfg",\%cfg); # on disk
	logIpsla("IPSLAD: RTTmodify, write modified config of $nno with status $status to /var\n") if $debug;
}

sub resolveDNS {
	my $nno = shift;
	my $dns = shift;
	my $addr;
	my $oct;

	# convert node name to oct ip address
	if ($dns ne "") {
		if ($dns !~ /^([0-9]|\.)+/) {
			my $h = gethostbyname($dns);
			$addr = inet_ntoa($h->addr) ;
		} else { $addr = $dns; }
		my @octets=split(/\./,$addr);
		$RTTcfg{$nno}{$dns} = $addr if $nno;
		$RTTcache{dns}{$dns} = $addr;
		$oct= pack ("CCCC", @octets);
		return $oct;
	} else {
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

	# convert responder/target node name to oct ip address
	if ($RTTcfg{$nno}{tnode} ne "") {
		$roct = resolveDNS($nno,$RTTcfg{$nno}{tnode});
		logIpsla("IPSLAD: RTTstart, convert responder/nameserver node $RTTcfg{$nno}{tnode} to oct") if $debug;
	}

	# convert source to bin ip address
	if ( $RTTcfg{$nno}{saddr} ne "" ) {
		$soct = resolveDNS(undef,$RTTcfg{$nno}{saddr});
		if (not $soct) {
			$RTTcfg{$nno}{message} = "error convert probe source address to oct";
			logIpsla("IPSLAD: RTTstart, $RTTcfg{$nno}{message}") if $debug;
			return undef;
		}
	}

	$RTTcfg{$nno}{frequence} = 60 if $RTTcfg{$nno}{frequence} eq "";

	# probe node
	my $community = $RTTcfg{$RTTcfg{$nno}{pnode}}{community} ;
	my $node = $RTTcfg{$nno}{pnode} ;
	my $port = $NT->{$RTTcfg{$nno}{pnode}}{snmpport} ;
	my $host = "$community"."@"."$node".":::::2";

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
	$state = snmpget($host,"rttMonApplSupportedRttTypesValid.$protocol{$RTTcfg{$nno}{optype}}{type}");
	if ($state == 2) {
		$RTTcfg{$nno}{status} = "error";
		$RTTcfg{$nno}{message} = "this type of probe is not available on node $RTTcfg{$nno}{pnode}";
		logIpsla("IPSLAD: RTTstart, $RTTcfg{$nno}{message}") if $debug;
		return undef;
	} elsif ($state != 1) {
		$RTTcfg{$nno}{status} = "error";
		$RTTcfg{$nno}{message} = "error probe node $RTTcfg{$nno}{pnode}, $SNMP_Session::errmsg";
		logIpsla("IPSLAD: RTTstart, $RTTcfg{$nno}{message}") if $debug;
		return undef;
	}


	# request state of probe
	$state = snmpget($host,"rttMonCtrlOperState.$RTTcfg{$nno}{entry}") if ($RTTcfg{$nno}{entry} ne "");
	logIpsla("IPSLAD: RTTstart, state of probe $nno, entry $RTTcfg{$nno}{entry}, is $state") if $debug;
	if ($state != 6) {
		# check if database already exists and if it was created with the same interval/frequence
		my $database = $RTTcfg{$nno}{database};
		if ( (-r $database and -w $database) ) { 
			logIpsla("IPSLAD: RTTstart, database of this probe exists already") if $debug;
			my $info = RRDs::info($database);
			foreach my $key (keys %$info) {
				if ( $key =~ /^step/) { 
					my $frequence = $RTTcfg{$nno}{optype} =~ /stats/ ? 3600 : $RTTcfg{$nno}{frequence} ;
					if ($$info{$key} != $frequence) {
						$RTTcfg{$nno}{message} = "existing database was created with an interval of $$info{$key} sec.";
						logIpsla("IPSLAD: RTTstart, $RTTcfg{$nno}{message}") if $debug;
						$RTTcfg{$nno}{status} = "error";
						runRTTmodify($nno);
						return undef;
					} else {last;}
				}
			}
		}


		# define entry number for this probe
		if ($RTTcfg{$RTTcfg{$nno}{pnode}}{entry} eq "") {
			 $RTTcfg{$RTTcfg{$nno}{pnode}}{entry} = 100; } else { $RTTcfg{$RTTcfg{$nno}{pnode}}{entry}++; }
		my $entry = $RTTcfg{$nno}{entry} = $RTTcfg{$RTTcfg{$nno}{pnode}}{entry};

		# probe is not active, try to config and start probe
		if ($RTTcfg{$nno}{optype} =~ /echo|tcpConnect|dhcp|dns/i) {
			# create entry
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{prot} ;
			push @params,"rttMonEchoAdminTargetAddress.$entry",'octetstring',$roct if $RTTcfg{$nno}{tas} eq "" ;
			push @params,"rttMonEchoAdminSourceAddress.$entry",'octetstring',$soct if $RTTcfg{$nno}{saddr} ne "" and $RTTcfg{$nno}{tas} eq "";
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$RTTcfg{$nno}{frequence} ;
			push @params,"rttMonCtrlAdminTimeout.$entry",'integer', $RTTcfg{$nno}{tout}*1000 if $RTTcfg{$nno}{tout} ne "" ;
			push @params,"rttMonEchoAdminTOS.$entry",'integer',$RTTcfg{$nno}{tos} if $RTTcfg{$nno}{tos} ne "";
			push @params,"rttMonEchoAdminVrfName.$entry",'string',$RTTcfg{$nno}{vrf} if $RTTcfg{$nno}{vrf} ne "";
			push @params,"rttMonCtrlAdminVerifyData.$entry",'integer',$RTTcfg{$nno}{vrfy} if $RTTcfg{$nno}{vrfy} ne "";
			push @params,"rttMonStatisticsAdminNumHops.$entry",'integer',$RTTcfg{$nno}{hops} if $RTTcfg{$nno}{hops} ne "" ;
			if ($RTTcfg{$nno}{optype} =~ /tcpConnect|udpEcho/) {
				push @params,"rttMonEchoAdminTargetPort.$entry",'integer',$RTTcfg{$nno}{dport} ;
				push @params,"rttMonEchoAdminControlEnable.$entry",'integer',2 if $RTTcfg{$nno}{rnode} eq "other" ;
			}
			push @params,"rttMonEchoAdminTargetAddressString.$entry",'string',$RTTcfg{$nno}{tas} if $RTTcfg{$nno}{tas} ne "";
			push @params,"rttMonEchoAdminNameServer.$entry",'octetstring',$roct if $RTTcfg{$nno}{tas} ne "";
			my $num_buckets = int($bucket_interval/$RTTcfg{$nno}{frequence}) + $extra_buckets;
			push @params,"rttMonHistoryAdminNumBuckets.$entry",'integer',$num_buckets if $RTTcfg{$nno}{optype} !~ /stats/;
			push @params,"rttMonHistoryAdminNumLives.$entry",'integer',1 if $RTTcfg{$nno}{optype} !~ /stats/;
			push @params,"rttMonHistoryAdminFilter.$entry",'integer',2 if $RTTcfg{$nno}{optype} !~ /stats/; # all
		}

		if ($RTTcfg{$nno}{optype} =~ /http/i) {
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{prot} ;
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$RTTcfg{$nno}{frequence} ;
			push @params,"rttMonEchoAdminHTTPVersion.$entry",'string',"1.0";
			push @params,"rttMonEchoAdminURL.$entry",'string',$RTTcfg{$nno}{url};
			push @params,"rttMonEchoAdminCache.$entry",'integer',2 ; # bypass cache

		}

		if ($RTTcfg{$nno}{optype} =~ /jitter/i) {
			push @params,"rttMonCtrlAdminStatus.$entry",'integer',5;
			push @params,"rttMonCtrlAdminRttType.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{type} ;
			push @params,"rttMonEchoAdminProtocol.$entry",'integer',$protocol{$RTTcfg{$nno}{optype}}{prot} ;
			push @params,"rttMonCtrlAdminFrequency.$entry",'integer',$RTTcfg{$nno}{frequence} ;
			push @params,"rttMonEchoAdminTargetAddress.$entry",'octetstring',$roct ;
			push @params,"rttMonEchoAdminSourceAddress.$entry",'octetstring',$soct if $RTTcfg{$nno}{saddr} ne "";
			push @params,"rttMonEchoAdminTOS.$entry",'integer',$RTTcfg{$nno}{tos} if $RTTcfg{$nno}{tos} ne "";
			push @params,"rttMonEchoAdminVrfName.$entry",'string',$RTTcfg{$nno}{vrf} if $RTTcfg{$nno}{vrf} ne "";
			push @params,"rttMonEchoAdminTargetPort.$entry",'integer',$RTTcfg{$nno}{tport} ;
			
			if ($RTTcfg{$nno}{codec} ne "") {
				push @params,"rttMonEchoAdminCodecType.$entry",'integer',$RTTcfg{$nno}{codec};
				push @params,"rttMonEchoAdminCodecInterval.$entry",'integer',$RTTcfg{$nno}{interval};
				push @params,"rttMonEchoAdminCodecPayload.$entry",'integer',$RTTcfg{$nno}{dsize} if $RTTcfg{$nno}{dsize} ne "";
				push @params,"rttMonEchoAdminCodecNumPackets.$entry",'integer',$RTTcfg{$nno}{numpkts} if $RTTcfg{$nno}{numpkts} ne "";
				push @params,"rttMonEchoAdminICPIFAdvFactor.$entry",'integer',$RTTcfg{$nno}{factor} if $RTTcfg{$nno}{factor} ne "";
			} else {
				push @params,"rttMonEchoAdminNumPackets.$entry",'integer',$RTTcfg{$nno}{numpkts};
				push @params,"rttMonEchoAdminInterval.$entry",'integer',$RTTcfg{$nno}{interval};
				push @params,"rttMonEchoAdminPktDataRequestSize.$entry",'integer',$RTTcfg{$nno}{dsize} if $RTTcfg{$nno}{dsize} ne "";

			}
		}

		if (! snmpset($host, @params)) {
			$RTTcfg{$nno}{message} = "Error snmpset attributes for probe $RTTcfg{$nno}{optype}";
			$RTTcfg{$nno}{status} = "error";
			return undef;
		}

		# start probe
		@params = ();
		push @params,"rttMonCtrlAdminOwner.$entry",'string','nmis' ; # 
		push @params,"rttMonScheduleAdminRttStartTime.$entry",'timeticks',1 ; # now
		push @params,"rttMonScheduleAdminRttLife.$entry",'integer',2147483647 ; # forever
		push @params,"rttMonCtrlAdminStatus.$entry",'integer',1 ;
		if (! snmpset($host, @params)) {
			$RTTcfg{$nno}{message} = "Error snmpset for start probe on node $RTTcfg{$nno}{pnode}";
			$RTTcfg{$nno}{status} = "error";
			return undef;
		}
		$RTTcfg{$nno}{status} = "running";
		$RTTcfg{$nno}{starttime} = "probe started at ". returnDateStamp();
		logIpsla("IPSLAD: RTTstart, probe $nno started on node $RTTcfg{$nno}{pnode}, entry $entry") if $debug;
		runRTTmodify($nno);
	}
	return 1; # done
}

sub runRTTstop {
	my $nno = shift;

	my $NT = loadLocalNodeTable();

	my @params = ();
	my $entry = $RTTcfg{$nno}{entry};

	logIpsla("IPSLAD: RTTstop, probe $nno, flag delete db is $RTTcfg{$nno}{deldb}") if $debug;
 
	my $community = $RTTcfg{$RTTcfg{$nno}{pnode}}{community} ;
	my $node = $RTTcfg{$nno}{pnode} ;
	my $port = $NT->{$RTTcfg{$nno}{pnode}}{snmpport} ;
	my $host = "$community"."@"."$node".":::::2";

	push @params,"rttMonCtrlOperState.$entry",'integer',3 ;
	push @params,"rttMonCtrlAdminStatus.$entry",'integer',2 ;
	push @params,"rttMonCtrlAdminStatus.$entry",'integer',6 ;
	snmpset($host, @params);

	unlink $RTTcfg{$nno}{database} 
	if (getbool($RTTcfg{$nno}{deldb})); # delete RRD

	$RTTcfg{$nno}{status} = "remove";

}

sub runRTTresponder {
	my $nno = shift;
	my $state;

	# responder activating
	if ($RTTcfg{$nno}{optype} =~ /tcpConnect|udpEcho|jitter/i and $RTTcfg{$nno}{rnode} ne "other") {
		my $community = $RTTcfg{$RTTcfg{$nno}{rnode}}{community} ;
		my $node = $RTTcfg{$nno}{rnode} ;
		my $host = "$community"."@"."$node".":::::2";
		# try reachability of system
		($state) = snmpget($host,"sysUpTime");
		if (!$state) {
			$RTTcfg{$nno}{message} = "responder node $RTTcfg{$nno}{rnode} does not response";
			logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}") if $debug;
			return undef;
		}
		$state = snmpget($host,"rttMonApplResponder.0");
		logIpsla("IPSLAD: RTTcollect, state of responder $RTTcfg{$nno}{rnode} is $state") if $debug;
		if ($state != 1) { 
			if (!snmpset($host,"rttMonApplResponder.0","integer",1)) {
				$RTTcfg{$nno}{message} = "error on activating responder on node $node" ;
				logIpsla("IPSLAD:, RTTstart, $RTTcfg{$nno}{message}") if $debug;
				$RTTcfg{$nno}{status} = "error";
				runRTTmodify($nno);
				return undef;
			} else {
				$RTTcfg{$nno}{responder} = "activated";
			}
		} else {
			$RTTcfg{$nno}{responder} = "active";
		}
	}
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
	my $sysuptime;
	my $nmistime;
	my %values = ();
	my @options;
	my $lastupdate;
	my $last;
	my $entry = $RTTcfg{$nno}{entry};
	my $timeout_cnt = 0; # in case of responder probe

	my $NT = loadLocalNodeTable();

	logIpsla("IPSLAD: RTTcollect of probe $nno with entry $entry") if $debug;
 
	my $community = $RTTcfg{$RTTcfg{$nno}{pnode}}{community} ;
	# resolve dns name 
	if ($RTTcache{dns}{$RTTcfg{$nno}{pnode}} eq "") { 
		resolveDNS($nno,$RTTcfg{$nno}{pnode});
	}
	my $node = $RTTcache{dns}{$RTTcfg{$nno}{pnode}} ;
	my $port = $NT->{$RTTcfg{$nno}{pnode}}{snmpport} ;
	my $host = "$community"."@"."$node".":::::2";

	# system uptime
	($sysuptime) = snmpget($host,"sysUpTime");
	if (!$sysuptime) {
		$RTTcfg{$nno}{message} = "node $RTTcfg{$nno}{pnode} does not response";
		logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}") if $debug;
		return undef;
	}

	$sysuptime = convertUpTime($sysuptime);
	$nmistime = time();

	# check if database exists
	my $database = $RTTcfg{$nno}{database};
	if ( not (-f $database and -r $database and -w $database) ) { 
		if ( not runRRDcreate($nno,$database)) { return;} 
		$last = $nmistime;
	} else {
		$last = RRDs::last($database);
	}

	$lastupdate = ($last - $nmistime) + $sysuptime + 3; # +3 for time mismatch
	logIpsla("IPSLAD: RTTcollect, nmis $nmistime, sysup $sysuptime, rrdlast $last, lastupdate $lastupdate") if $debug;

	my $numrtts = snmpget($host,"rttMonCtrlOperNumRtts.$entry");
	logIpsla("IPSLAD: RTTcollect, numrtts $numrtts") if $debug;
	if (! $numrtts) {
		logIpsla("IPSLAD: RTTcollect, no answer, try to configure probe again") if $debug;
		if (!runRTTstart($nno)) { return undef; } # configure probe node
		$entry = $RTTcfg{$nno}{entry}; # new number from start
		$numrtts = snmpget($host,"rttMonCtrlOperNumRtts.$entry") ;
		if (!$numrtts) { 
			$RTTcfg{$nno}{message} = "error on reconfiguration of probe on node $RTTcfg{$nno}{pnode}";
			logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}");
			$RTTcfg{$nno}{status} = "error";
			runRTTmodify($nno);
			return undef;
		}
	}


	if ($RTTcfg{$nno}{optype} =~ /echo|tcpConnect|dns|dhcp/i) {
		# get history values from probe node
		if (!snmpmaptable($host,
			sub () {
				my ($index, $time, $rtt, $sense, $addr) = @_;
				my $stime = convertUpTime($time) ;
				my ($a0,$a1,$a2,$a3) = unpack ("CCCC", $addr);
				my ($k0,$k1,$k2) = split /\./,$index,3;
				my $target = "$a0.$a1.$a2.$a3";

				logIpsla("IPSLAD: RTTcollect, entry $entry, index $index, time $time ($stime), rtt $rtt, sense $sense, addr $target") if $debug;
				if ($stime > $lastupdate) { 
					$values{$k1}{$k2}{index} = $index;
					$values{$k1}{$k2}{stime} = $stime;
					$values{$k1}{$k2}{rtt} = $rtt;
					$values{$k1}{$k2}{addr} = $target;
					$values{$k1}{$k2}{sense} = $sense;
					# web page will display node names too
					if ( ! exists $RTTcfg{$nno}{$values{$k1}{$k2}{addr}} ) {
						my $nm = gethost($values{$k1}{$k2}{addr});
					    if ($nm) {
							$RTTcfg{$nno}{$values{$k1}{$k2}{addr}} = $nm->name;
							runRTTmodify($nno);
						}
					}
				}
			},
			"rttMonHistoryCollectionSampleTime.$entry",
			"rttMonHistoryCollectionCompletionTime.$entry",
			"rttMonHistoryCollectionSense.$entry",
			"rttMonHistoryCollectionAddress.$entry"
			)) {

			$RTTcfg{$nno}{message} = "error get values from node $RTTcfg{$nno}{pnode}";
			logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}") if $debug;
			return undef;
		}
		# store values in rrd
		foreach my $k1 (sort {$a <=> $b} keys %values) { # bucket number
			next if not exists $values{$k1}{'1'}{stime};
			# calculate time
			my $stime = $nmistime - $sysuptime + $values{$k1}{'1'}{stime}; # using timestamp of first bucket
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
			runRRDupdate($nno,$tmp,$val);
		}
	}

	if ($RTTcfg{$nno}{optype} =~ /http/i) {
		my ($rtt, $dns, $tcp, $trans, $sense, $descr);
		if (($rtt, $dns, $tcp, $trans, $sense, $descr) = snmpget($host,
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
			$RTTcfg{$nno}{message} = "error get values of node $RTTcfg{$nno}{pnode}, snmp - rttMonLatestHTTP";
			logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}") if $debug;
			return undef;
		}

	} 
	if ($RTTcfg{$nno}{optype} =~ /jitter/i) {
		my ($posSD, $negSD, $posDS, $negDS, $lossSD, $lossDS, $OoS, $MIA, $late, $mos, $icpif, $sense);
		if (($posSD, $negSD, $posDS, $negDS, $lossSD, $lossDS, $OoS, $MIA, $late, $mos, $icpif, $sense) = snmpget($host,
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
			my $tmpcodec = $RTTcfg{$nno}{codec} ne "" ? ":3L2_mos:2L2_icpif" : "";
			my $valcodec = $RTTcfg{$nno}{codec} ne "" ? ":$mos:$icpif" : "";
			$negSD *= -1;
			$negDS *= -1;
			my $tmp = "sense:4L2_positivesSD:4L2_negativesSD:4L2_positivesDS:4L2_negativesDS".$tmpcodec.":0P2_packetLossSD:0P2_packetLossDS:0P2_packetError";
			my $val = "$stime:$sense:$posSD:$negSD:$posDS:$negDS".$valcodec.":$lossSD:$lossDS:$pkterr";
			runRRDupdate($nno,$tmp,$val);

		} else {
			$RTTcfg{$nno}{message} = "error get values from probe, snmp => rttMonLatestJitter";
			logIpsla("IPSLAD: RTTcollect, $RTTcfg{$nno}{message}") if $debug;
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

	# adjust items in cfg
	my @names = split /:/,$tmp ;
	my @dsnm = grep { $_ if $RTTcfg{$nno}{items} !~ /$_/ and $_ ne "sense" } @names ;
	if (@dsnm) {
		$RTTcfg{$nno}{items} = join(':',(split(/:/,$RTTcfg{$nno}{items}),@dsnm)); # append new items
		runRTTmodify($nno);
	}

	my @dsnames = map { /^\d+[A-Z]\d+_(.*)/ ? $1 : $_ ;} @names ; # remove leading info for web display
	my $dsnames = join':',@dsnames; # clean concatenated DS names

	logIpsla("IPSLAD: rddupdate, $dsnames, $val") if $debug;

	my @options = ( "-t", $dsnames, $val);

	my $database = $RTTcfg{$nno}{database};
	if ( not (-f $database and -r $database and -w $database) ) { 
		runRRDcreate($nno,$database) or return undef;
	} 

	# update RRD
	RRDs::update($database,@options);
	my $Error = RRDs::error;
	if ($Error =~ /Template contains more DS|unknown DS name|tmplt contains more DS/i) {
		logIpsla("IPSLAD: updateRRD: missing DataSource in $database, try to update") if $debug;
		# find the DS names in the existing database (format ds[name].* )
		my $info = RRDs::info($database);
		my $rrdnames = ":";
		foreach my $key (keys %$info) {
			if ( $key =~ /^ds\[([a-zA-Z0-9_]{1,19})\].+/) { $rrdnames .= "$1:";}
		}
		# find the missing DS name
		my @ds = ();
		my $frequence = ($RTTcfg{$nno}{optype} =~ /stats/) ? 3600 : $RTTcfg{$nno}{frequence} ;
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
		logIpsla("IPSLAD: RRDupdate, database $database updated\n") if $debug;
		if ($RTTcfg{$nno}{message} ne "") { $RTTcfg{$nno}{message} = ""; runRTTmodify($nno); }
	} else {
		$RTTcfg{$nno}{status} = "error" ;
		$RTTcfg{$nno}{message} = "error on update rrd database, $Error";
		logIpsla("IPSLAD: RRDupdate, $RTTcfg{$nno}{message}\n") if $debug;
		runRTTmodify($nno);
	}
}

sub runRRDcreate {
	my $nno = shift; # cfg key
	my $database = shift ; # name of database

	# if the directory doesn't exist create it
	my $dir = "$C->{database_root}/misc";
	if (not -d "$dir") {
		mkdir $dir, 0775 or die "Cannot mkdir $dir: $!\nstopped";
	}

	my $frequence = ($RTTcfg{$nno}{optype} =~ /stats/) ? 3600 : $RTTcfg{$nno}{frequence} ;

	# RRD sizing
	my $RRD_poll = $frequence ;
	my $RRD_hbeat = $RRD_poll * 3;
	my $RRA_step = 1;
	my $RRA_rows = ((86400/$frequence) * 7) * $RTTcfg{$nno}{history}; # calc. db size

	my $time  = time()-10;
	my @options;

	@options = ( "-b", $time, "-s", $RRD_poll );

	push @options, "DS:sense:GAUGE:$RRD_hbeat:U:U"; # must be one DS at least

	push @options, "RRA:AVERAGE:0.5:$RRA_step:$RRA_rows";
	push @options, "RRA:MAX:0:$RRA_step:$RRA_rows";

	RRDs::create("$database",@options);
	my $ERROR = RRDs::error;
	if ($ERROR) {
		$RTTcfg{$nno}{status} = "error" ;
		$RTTcfg{$nno}{message} = "unable to create database $database, $ERROR";
		logIpsla("IPSLAD: RRDcreate, $RTTcfg{$nno}{message}");
		runRTTmodify($nno); # update config file
		return undef;
	} else {
		logIpsla("IPSLAD: RRDcreate, created database $database, freq. $frequence sec.") if $debug;
	}
	# set file owner and permission, default: nmis, 0775.
	setFileProt($database);

	return 1;
}

sub runRTTstats {

	my $NT = loadLocalNodeTable();

	foreach my $pnode (keys %{$RTTcache{stats}{node}}) {
		logIpsla("IPSLAD: RTTstats, get statistics from probe node $pnode") if $debug;
		# resolve dns name 
		if ($RTTcache{dns}{$pnode} eq "") { 
			resolveDNS(undef,$pnode);
		}
		my $node = $RTTcache{dns}{$pnode} ;
		my $community = $RTTcfg{$pnode}{community} ;
		my $port = $NT->{$pnode}{snmpport} ;
		my $host = "$community"."@"."$node".":::::2";
		if ( map { ($RTTcfg{$_}{optype} =~ /echo|dhcp|dns|tcpConnect/i) } @{$RTTcache{stats}{node}{$pnode}} ) {
			runRTTecho_stats($host,$pnode) ;
		}
		if ( map { ($RTTcfg{$_}{optype} =~ /jitter/i) } @{$RTTcache{stats}{node}{$pnode}} ) {
			runRTTjitter_stats($host,$pnode) ;
		}
		if ( map { ($RTTcfg{$_}{optype} =~ /http/i) } @{$RTTcache{stats}{node}{$pnode}} ) {
			runRTThttp_stats($host,$pnode) ;
		}
	}
}

# Collect the statistics hourly.
# Operation pathEcho does not work correctly because sometimes different paths are found.

sub runRTTecho_stats {
	my $host = shift;
	my $pnode = shift;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $hop;
	my $mibname;
	my @oid_values;
	my $nno;
	my $stime = time();

	logIpsla("IPSLAD: RTTecho_stats, get table rttMonStatsCollectTable") if $debug;
	@oid_values = snmpgetbulk2($host,0,20,"rttMonStatsCollectTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  .1.3.6.1.4.1.9.9.42.1.3.2.1.type.entry.time.path.hop
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonStatsCollectTable},@oid_values ) {
	#		logIpsla("IPSLAD: CollectTable => $oid_value") if $debug > 2;
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
		logIpsla("IPSLAD: RTTecho_stats, get table rttMonStatsCaptureTable") if $debug;
		@oid_values = snmpgetbulk2($host,0,20,"rttMonStatsCaptureTable");
		if (@oid_values) {
			# add them into the hash.
			# push the multiple time value here as well, and iterate over it later
			# example result  .1.3.6.1.4.1.9.9.42.1.3.1.1.type.entry.Time.path.hop.dis
		    for my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonStatsCaptureTable},@oid_values ) {
		#		logIpsla("IPSLAD: CaptureTable => $oid_value") if $debug;
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
				foreach $nno (keys %RTTcfg) {
					if ($RTTcfg{$nno}{entry} eq $entry and $RTTcfg{$nno}{pnode} eq $pnode 
							and $RTTcfg{$nno}{optype} =~ /echo-stats|dhcp-stats|dns-stats|tcpConnect-stats|udpEcho-stats|pathEcho-stats/i) {
						logIpsla("IPSLAD: RTTecho-stats, key found for entry $entry in RTTcfg => $nno") if $debug;
						my $Trys = 0;
						foreach $hop (sort {$a <=> $b} keys %{$Rtr{$entry}}) {
							# avoid divide by zero errors
							my $Avg = 0;
							my $target = $RTTcfg{$nno}{ip}{$RTTcfg{$nno}{tnode}}; # ip address of target
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
							if ( ! exists $RTTcfg{$nno}{$target} ) {
								my $nm = gethost($target);
								if ($nm) {
									$RTTcfg{$nno}{$target} = $nm->name; # dns name for web page
									runRTTmodify($nno); # store
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
			logIpsla("IPSLAD: RTTget_stats, no values from snmpgetbulk of CaptureTable") if $debug;
		}
	} else {
		logIpsla("IPSLAD: RTTget_stats, no values from snmpgetbulk of CollectTable") if $debug;
	}
	writeHashtoVar("rttmon-echo-data",\%RTTdata) if $debug > 1; # debug on disk
	writeHashtoVar("rttmon-echo-vals",\%Rtr) if $debug > 1; # debug on disk
}

sub runRTTjitter_stats {
	my $host = shift;
	my $pnode = shift;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $mibname;
	my @oid_values;
	my $nno;
	my $stime = time();

	logIpsla("IPSLAD: RTTjitter_stats, get table rttMonJitterStatsTable") if $debug;
	@oid_values = snmpgetbulk2($host,0,20,"rttMonJitterStatsTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  1.3.6.1.4.1.9.9.42.1.3.5.1.type.entry.TimeValue
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonJitterStatsTable},@oid_values ) {
	#		logIpsla("IPSLAD: JitterTable => $oid_value") if $debug > 1;
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
			foreach $nno (keys %RTTcfg) {
				if ($RTTcfg{$nno}{entry} eq $entry and $RTTcfg{$nno}{pnode} eq $pnode and $RTTcfg{$nno}{optype} =~ /jitter-stats|jitter-voip-stats/) {
					logIpsla("IPSLAD: RTTjitter-stats, key found for entry $entry in RTTcfg => $nno") if $debug;

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

					my $tmpcodec = $RTTcfg{$nno}{codec} ne "" ? ":9L0_MaxOfMos:9L0_MinOfMos:8L0_MaxOfICPIF:8L0_MinOfICPIF" : "";
					my $valcodec = $RTTcfg{$nno}{codec} ne "" ? ":$MaxOfMos:$MinOfMos:$MaxOfICPIF:$MinOfICPIF" : "";
					my $tmp = "sense:7L2_positivesSD:7L2_negativesSD:7L2_positivesDS:7L2_negativesDS:6L1_avgRTT:7L2_avgJitter".$tmpcodec.":0P2_packetLossSD:0P2_packetLossDS:0P2_packetError";
					my $val = "$stime:0:$PositiveJitterSD:$NegativeJitterSD:$PositiveJitterDS:$NegativeJitterDS:$avgRTT:$avgJitter".$valcodec.":$PacketLossSD:$PacketLossDS:$pkterr";
					runRRDupdate($nno,$tmp,$val);
					last;
				}
			}
		}
	} else {
		logIpsla("IPSLAD: RTTget_stats, no values from snmpgetbulk of JitterTable") if $debug;
	}
}

sub runRTThttp_stats {
	my $host = shift;
	my $pnode = shift;

	logIpsla("IPSLAD: RTThttp_stats, get table rttMonHTTPStatsTable") if $debug;

	my %RTTdata;
	my %Rtr;
	my $entry;
	my @entries;
	my $timevalue;
	my $mibname;
	my @oid_values;
	my $nno;
	my $stime = time();

	@oid_values = snmpgetbulk2($host,0,20,"rttMonHTTPStatsTable");
	if (@oid_values) {
		# add them into the hash.
		# push the multiple time value here as well, and iterate over it later
		# example result  1.3.6.1.4.1.9.9.42.1.3.4.1.type.entry.TimeValue
	    foreach my $oid_value ( grep $_ =~ $SNMP_util::OIDS{rttMonHTTPStatsTable},@oid_values ) {
	#		logIpsla("IPSLAD: HTTPTable => $oid_value") if $debug > 1;
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
			foreach $nno (keys %RTTcfg) {
				if ($RTTcfg{$nno}{entry} eq $entry and $RTTcfg{$nno}{pnode} eq $pnode and $RTTcfg{$nno}{optype} =~ /http-stats/) {
					logIpsla("IPSLAD: RTThttp-stats, key found for entry $entry in RTTcfg => $nno") if $debug;
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
		logIpsla("IPSLAD: RTThttp_stats, no values from snmpgetbulk of httpTable") if $debug;
	}
}



#=======

# modified version of SNMP_util
# now the (single) table will be completely read in

sub snmpgetbulk2 ($$$$) {
  my($host, $nr, $mr, @vars) = @_;
  my(@enoid, $var, $response, $bindings, $binding);
  my($value, $upoid, $oid, @retvals);
  my($noid);
  my $session;

  $session = &SNMP_util::snmpopen($host, 0, \@vars);
  if (!defined($session)) {
    carp "SNMPGETBULK Problem for $host\n"
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
        carp "SNMPGETBULK Problem for $var on $host\n"
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
