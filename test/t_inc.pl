#!/usr/bin/perl

use strict;
use Data::Dumper;

print "First:\n";
print Dumper(\@INC) ."\n";


#read("");

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

print "Second:\n";
print Dumper(\@INC) ."\n";


#push(@INC,"/usr/local/rrdtool/lib/perl");

use RRDs;


print "Hello World\n";
