#!/usr/bin/perl

use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use func;
use NMIS;
use Data::Dumper;

my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;


my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();

foreach my $node (sort keys %{$LNT}) {
	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		print "Processing $node\n";
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		
		if ( $NI->{system}{sysDescr} =~ /12.4\(25f\)/ ) {
			print "MATCH $NI->{system}{name} is $NI->{system}{sysDescr}\n";
		}
		
		if ( $NI->{system}{sysDescr} =~ /IOS/ ) {
			print "IOS $NI->{system}{name} is Cisco IOS\n";
		}

		if ( $NI->{system}{sysDescr} =~ /Windows/ ) {
			print "Windows $NI->{system}{name} is Windows\n";
		}
		
		for my $ifIndex (keys %{$IF}) {
			if ( $IF->{$ifIndex}{collect} eq "true") {
				print "$IF->{$ifIndex}{ifIndex}\t$IF->{$ifIndex}{ifDescr}\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}\n";
			}
		}
	}
}

