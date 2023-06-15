#!/usr/bin/perl

# fixme: this test ist broken, it doesn't handle any errors whatsoever
# and crashes consequentially

use strict;
use Net::SNMP; 									# for the fixme removable local snmp session stuff
use Data::Dumper;

my $host = "192.168.1.254";
my $community = "OMKread";

my $host = "192.168.1.42";
my $community = "nmisGig8";

my $host = "192.168.1.1";
my $community = "myAniTonnor";

my $port = 161;
my $version = "2c";
my $timeout = 5;


my $host = "199.102.164.124";
my $community = "nmisGig8";
my $port = 61161;



#

my $session = mysnmpsession( $host, $community, $port, $version,  $timeout);
if (!$session)
{
	print("Could not open SNMP session to node $host");
}

my $oid1 = "1.3.6.1.2.1.1.1.0";
my $oid2 = "1.3.6.1.2.1.1.2.0";
my $oid3 = "1.3.6.1.2.1.1.3.0";

my $results = mysnmpget($session,[$oid1,$oid2,$oid3]) if defined $session;

print Dumper $results;

my @oids = [ $oid1,$oid2,$oid3 ];

my $results = mysnmpget($session,[$oid1,$oid2,$oid3]) if defined $session;

#if ( $results )

print Dumper $results;

my @columns = (
	"1.3.6.1.2.1.25.4.2.1.1",
	"1.3.6.1.2.1.25.4.2.1.2",
	"1.3.6.1.2.1.25.4.2.1.3",
	"1.3.6.1.2.1.25.4.2.1.4",
	"1.3.6.1.2.1.25.4.2.1.5",
);


my $results = $session->get_entries(
		-columns => \@columns,
	);

print "ERROR: ". $session->error() ."\n";

print Dumper $results;
#hrSWRunEntry 1.3.6.1.2.1.25.4.2.1
#hrSWRunIndex 1.3.6.1.2.1.25.4.2.1.1
#hrSWRunName 1.3.6.1.2.1.25.4.2.1.2
#hrSWRunID 1.3.6.1.2.1.25.4.2.1.3
#hrSWRunPath 1.3.6.1.2.1.25.4.2.1.4
#hrSWRunParameters 1.3.6.1.2.1.25.4.2.1.5
#

sub mysnmpsession {
	my $node = shift;
	my $community = shift;
	my $port = shift;
	my $version = shift;
	my $timeout = shift;

	my ($session, $error) = Net::SNMP->session(
		-hostname => $node,
		-community => $community,
		-timeout  => $timeout,
		-port => $port,
		-version => $version
	);

	if (!defined($session)) {
		logMsg("ERROR ($node) SNMP Session Error: $error");
		$session = undef;
	}

	# lets test the session!
	my $oid = "1.3.6.1.2.1.1.2.0";
	my $result = mysnmpget($session,[$oid]);
	if ( defined $result and $result->{error} =~ /^SNMP ERROR/ ) {
	#if ( $result->{$oid} =~ /^SNMP ERROR/ ) {
		print ("ERROR ($node) SNMP Session Error, bad host or community wrong\n");
		$session = undef;
	}

	return $session;
}

sub mysnmpget {
	my $session = shift;
	my $oid = shift;

	my %pdesc;

	my $response = $session->get_request(
		-varbindlist => $oid
	);

	print Dumper $response;
	if ( defined $response ) {
		%pdesc = %{$response};
		my $err = $session->error;

		if ($err){
			$pdesc{"error"} = "SNMP ERROR";
			$pdesc{"err"} = $err;
		}
	}
	else {
		$pdesc{"error"} = "SNMP ERROR: empty value @$oid";
	}

	return \%pdesc;
}
