#!/usr/bin/perl

use FindBin;
use lib "$FindBin::Bin/../lib";

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use func;
use NMIS;
use NMIS::IPSLA;
use NMIS::Timing;
use Net::hostent;
use Socket;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($nvp{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the IPSLA config file to migrate to DB
usage: $0 <IPSLA_CFG> <NEW_IPSLA_DB>
eg: $0 ipslacfg=/usr/local/nmis8/var/ipslacfg.nmis ipsla_db=/usr/local/nmis8/database/ipsla/ipsla.db

EO_TEXT
	exit 1;
}

resolveDNSTest("bobke.packnet");
resolveDNSTest("monkey.kong.connor");
resolveDNSTest("www.cisco.com");

print $t->markTime(). " Creating IPSLA Object\n";
my $IPSLA = NMIS::IPSLA->new(C => $C);
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Initialise DB\n";
$IPSLA->initialise();
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Get Node List\n";
my @nodes = $IPSLA->getNodes();
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Get Probe List\n";
my @probes = $IPSLA->getProbes();
foreach my $p (@probes) {
	print "probe=$p ". ref($p) ." $p->{select} $p->{status}\n";
}
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " deleteDnsCache\n";
$IPSLA->setDebug(debug => 1);
$IPSLA->cleanDnsCache(cacheage => 60);
$IPSLA->setDebug(debug => 0);
print "  done in ".$t->deltaTime() ."\n";


my $nno = "wanedge1_192.168.1.9_echo_0";
print $t->markTime(). " Get Probe List\n";
my $probe = $IPSLA->getProbe(probe => $nno);
print "nno=$nno pnode=$probe->{pnode}\n";
print "  done in ".$t->deltaTime() ."\n";

my $nno = "wanedge1_192.168.1.250_echo_0";
print $t->markTime(). " Get Probe List\n";
my $probe = $IPSLA->getProbe(probe => $nno);
print "nno=$nno pnode=$probe->{pnode}\n";
print "  done in ".$t->deltaTime() ."\n";

my $node = "wanedge1";
print $t->markTime(). " Get Community\n";
my $comm = $IPSLA->getCommunity(node => $node);
print "node=$node comm=$comm\n";
print "  done in ".$t->deltaTime() ."\n";


my @update;
my @delete;
#my @delete = qw(wanedge1_www.sins.com.au_pathEcho wanedge1_www.opmantek.com_http wanedge1_www.cisco.com_http wanedge1_community.opmantek.com_http);
my @update = qw(wanedge1_192.168.1.250_echo_0);
#my @delete = qw(wanedge1_192.168.1.250_echo_0);

foreach my $upd (@update) {
	print $t->markTime(). " Update Probe! $upd\n";
	$IPSLA->updateProbe(probe => $upd, message => " ");
	print "  done in ".$t->deltaTime() ."\n";
}

foreach my $del (@delete) {
	print $t->markTime(). " Delete Probe! $del\n";
	$IPSLA->deleteProbe(probe => $del);
	print "  done in ".$t->deltaTime() ."\n";
}

#wanedge1_192.168.1.251_echo_3

my @array = qw(k1 k2 k3 k4);

my %hash = (
	k1 => "apple",
	k2 => "orange",
	k3 => "apple",
	k4 => "banana"
);

if ( map { ($hash{$_} =~ /apple/) } @array ) {
	print "MAP: $hash{$_}\n";
}
else {
	print "NOT: $hash{$_}\n";	
}

foreach my $k (@array) {
	print "$k=$hash{$k}\n";	
}
#if ( map { ($RTTcfg{$_}{optype} =~ /echo|dhcp|dns|tcpConnect/i) } @{$RTTcache{stats}{node}{$pnode}} ) {
#	runRTTecho_stats($host,$pnode) ;
#}



sub resolveDNSTest {
	my $dns = shift;
	my $addr;
	my $oct;
	my $h;
	
	# convert node name to oct ip address
	if ($dns ne "") {
		if ($dns !~ /^([0-9]|\.)+/) {
			if ($h = gethostbyname($dns)) {
				$addr = inet_ntoa($h->addr)
			}
			else {
				return undef;
			}
		} else { $addr = $dns; }
		my @octets=split(/\./,$addr);
		print "DNS RESULT: addr=$addr\n";
		$oct = pack ("CCCC", @octets);
		print "DNS RESULT: oct=$oct\n";
		return $oct;
	} 
	else {
		return undef;
	}
}
