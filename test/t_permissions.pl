#!/usr/bin/perl

use strict;
use File::Path;

my $dir = "/tmp/testing9";

my $permissions = "0770";

my $umask = umask(0);
mkdir($dir,oct($permissions));

mkpath("$dir/test/it/well",{verbose => 0, mode => oct($permissions)});

print "umask=$umask\n";

umask($umask);



# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use func;
my $dir = "/tmp/testing10";
my $file = "$dir/test.txt";

createDir($dir);
my $exec = `touch $file`;
setFileProt($file);
mkpath("$dir/test/it/well");
setFileProt($dir);
setFileProtDirectory($dir,"true");
