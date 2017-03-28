#!/usr/bin/perl
# this wants a commandline argument, 
#the desired debug level 'info', 'error', 'debug', 1..9, t(rue), y(es) 
# and  verbose
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Log;

print "setting up logger  with level \"$ARGV[0]\"\n";
my $logger = NMISNG::Log->new(level => $ARGV[0]);


$logger->debug("debug one");
$logger->debug2("two!");
$logger->debug3("three");
$logger->debug4("fourtytwo");
$logger->debug5("five");
$logger->debug6("six");
$logger->debug7("seven");
$logger->debug8("eight");
$logger->debug9("ninetynine bottles");


$logger->info("just info");

$logger->fatal("fatal fatal");

for my $x ('debug', 'info','warn',"error", 'fatal', 1..9)
{
	print "will level $x print? ".($logger->is_level($x)?"yes":"no")."\n";
}

