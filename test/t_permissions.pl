#!/usr/bin/perl

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;

my $exec = `touch foo`;
my $mode = "0770"; chmod oct($mode), "foo"; # this is better
#my $mode = 0644;   chmod $mode, "foo";  


my $exec = `ls -l foo`;
print $exec;

setFileProt("foo");

