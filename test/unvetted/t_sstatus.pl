#!/usr/bin/perl
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;

use NMISNG::Util;
use Compat::NMIS;

my %nvp = getArguements(@ARGV);

my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

print "checking services for: node=$nvp{node}, service=$nvp{service}\n";
my %res = NMIS::loadServiceStatus(node => $nvp{node},
																	service => $nvp{service});
print Dumper(\%res);
exit 0;

						 

