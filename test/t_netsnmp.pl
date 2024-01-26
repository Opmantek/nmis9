#!/usr/bin/perl

use strict;

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# Import external
use Net::SNMP qw(oid_lex_sort oid_lex_cmp);
use Compat::Timing;


use Data::Dumper;

my %args;

my $host = $args{host} || 'localhost';
my $domain = $args{udp} || 'udp';
my $version = $args{version} || 'snmpv2c';
my $community = $args{community} || 'nmisGig8';
my $port = $args{port} || 161;
my $timeout = $args{timeout} || 5;
my $retries = $args{retries} || 1;
my $max_msg_size = $args{max_msg_size} || 1472;

#set te default
my $max_reps = 0;
#$self->{oidpkt} = $args{oidpkt} || 10;

my @authopts = ();
if ($version eq 'snmpv1' or $version eq 'snmpv2c') {
	push(@authopts,
		-community	=> $community,
	);
}

my $t = Compat::Timing->new();

my ($session, $error) = Net::SNMP->session(
			-domain		=> $domain,
			-version	=> $version,
			-hostname	=> $host,
			-timeout	=> $timeout,
			-retries	=> $retries,
			-translate   => [-timeticks => 0x0,		# Turn off so sysUpTime is numeric
			-unsigned => 0x1,		# unsigned integers
			-octet_string => 0x1],   # Lets octal string
			-port		=> $port,
			-maxmsgsize => $max_msg_size,
			@authopts,
		);

	print Dumper $session;                  

if ( $session ) {
		
	print $t->markTime(). " Get Base Table\n";
	#hrSWInstalledIndex		
	my $oid = ".1.3.6.1.2.1.25.6.3.1.1";
	
	#ifDescr		
	#my $oid = "1.3.6.1.2.1.2.2.1.2";
	
	my $result = $session->get_table(
	                          #[-callback        => sub {},]     # non-blocking
	                          #[-delay           => $seconds,]   # non-blocking 
	                          -baseoid          => $oid,
	                          -maxrepetitions  => $max_reps  # v2c/v3
	                       );
	
	print "  done in ".$t->deltaTime() ."\n";
	print $result . "\n";
	
	#print Dumper $result;                  
	                       
	print $t->markTime(). " Get get_entries\n";
	
	my @columns = (
		"1.3.6.1.2.1.25.6.3.1.1",
		"1.3.6.1.2.1.25.6.3.1.2",
		"1.3.6.1.2.1.25.6.3.1.3"
	);            
	$result = $session->get_entries(
	        #[-callback        => sub {},]     # non-blocking
	        #[-delay           => $seconds,]   # non-blocking
	        -columns          => \@columns,
	        #[-startindex      => $start,]
	        #[-endindex        => $end,]
	        -maxrepetitions  => $max_reps,  # v2c/v3
	     );

	print "  done in ".$t->deltaTime() ."\n";
	     	
	#foreach my $oid ( sort {oid_lex_cmp($a,$b)} keys(%${result})) {
	#	print "$oid\n";
	#}
}
else {
	print "ERROR: $error\n";
}
