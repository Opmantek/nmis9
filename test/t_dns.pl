#!/usr/bin/perl

use strict;
use Socket;

my $res;
my $packet;
my $rr;

# 'weth.dev.opmantek.com' does not exist:
my $host = "magni.opmantek.com";
my $node = "magni";
my $ret;

# resolve $node to an IP address first so Net::DNS points at the remote server
if ( my $packed_ip = inet_aton($host)) {
	my $ip = inet_ntoa($packed_ip);

	print STDERR "DEBUG: host=$host ip=$ip\n";

	use Net::DNS;
	$res = Net::DNS::Resolver->new;
	$res->nameservers($ip);
	$res->recurse(0);
	$res->retry(2);
	$res->usevc(0);			# force to udp (default)
	$res->debug(1); 

	if ( !$@ ) {
		$packet = $res->query($host);		# lookup its own nodename on itself, should always work..?
		if (!$packet) {
			$ret = 0;
			print STDERR ("ERROR Unable to lookup data for $node from $ip\[$host\]\n");
		}
		else {
			# stores the last RR we receive
			foreach $rr ($packet->answer) {
				$ret = 1;
				my $tmp = $rr->address;
				print STDERR ("RR data for $node from $ip\[$host\] was $tmp\n");
			}
		}
	}
	else {
		print STDERR ("ERROR Net::DNS error $@\n");
		$ret = 0;
	}
}
else {
	print STDERR "ITS ALL GONE BADLY\n";
}
