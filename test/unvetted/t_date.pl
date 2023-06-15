#!/usr/bin/perl

use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 

use Compat::NMIS;
use Compat::Timing;
use NMISNG::Util;
use NMISNG::Sys;
use RRDs;
use Data::Dumper; 
$Data::Dumper::Indent = 1;


# Variables for command line munging
use Time::ParseDate;

my %arg = getArguements(@ARGV);

my $time = time();

if ( $arg{date} ne "" ) {
	$time = $arg{date};
}

print "$time is ". getDayOfWeek($time) . "\n";

exit 0;

sub getDayOfWeek {
	my $convertTime = shift;
	
	if ( $convertTime !~ /^\d+$/ ) {
		$convertTime = parsedate($convertTime);
	}
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($convertTime);
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	return $wday;
}


