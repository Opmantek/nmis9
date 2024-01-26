#!/usr/bin/perl

use strict;
use Data::Dumper;

print "First:\n";
print Dumper(\@INC) ."\n";


#read("");

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Util;
use rrdfunc;
my $C = loadConfTable();
rrdfunc::require_RRDs(config=>$C);

print "Second:\n";
print Dumper(\@INC) ."\n";


#push(@INC,"/usr/local/rrdtool/lib/perl");
print "I'm not sure this is correct\n";
use RRDs;


print "Hello World\n";
