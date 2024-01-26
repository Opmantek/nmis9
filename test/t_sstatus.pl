#!/usr/bin/perl
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;

use NMISNG::Util;
use Compat::NMIS;

my %nvp =  %{ NMISNG::Util::get_args_multi(@ARGV) };

my $C = NMISNG::Util::loadConfTable(debug=>$nvp{debug});

print "checking services for: node=$nvp{node}, service=$nvp{service}\n";
my %res = Compat::NMIS::loadServiceStatus(node => $nvp{node},
																					service => $nvp{service});
print Dumper(\%res);
exit 0;
