#!/usr/bin/perl

use FindBin;
use lib "$FindBin::Bin/../lib";

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use NMIS::IPSLA;
use NMIS::Timing;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($nvp{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $log = "$C->{'<nmis_base>'}/admin/ipsla+_fix_error_probes.log";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will change probes in error to running because you want them to go now.
usage: $0 run=(true|false)
eg: $0 run=true

EO_TEXT
	exit 1;
}

if ( $nvp{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}

print $t->markTime(). " Creating IPSLA Object\n";
my $IPSLA = NMIS::IPSLA->new(C => $C);
print "DEBUG: nmisdb=$C->{nmisdb} db_server=$C->{db_server} db_prefix=$C->{db_prefix}\n";
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Getting list of Probes\n";
my @nodeList = $IPSLA->getNodes();

my $community = "telmex\$01\$rw";

foreach my $n ( sort { $a->{node} cmp $b->{node} } @nodeList ) {
	if ( $n->{community} eq "" ) {
		print $t->elapTime(). " NODE UPD: $n->{node}\n";
		$IPSLA->updateNode(
			node => $n->{node}, 
			community => $community
		);
	}
	if ( $n->{node} =~ /_echo_|_jitter_/ ) {
		print $t->elapTime(). " NODE ERR: $n->{node}\n";
	}
}

# message with (class::)method names and line number
sub logit {
	my $msg = shift;
	my $handle;
	open($handle,">>$log") or warn returnTime." log, Couldn't open log file $log. $!\n";
	flock($handle, LOCK_EX)  or warn "log, can't lock filename: $!";
	print $handle returnDateStamp().",$msg\n" or warn returnTime." log, can't write file $log. $!\n";
	close $handle or warn "log, can't close filename: $!";
}
