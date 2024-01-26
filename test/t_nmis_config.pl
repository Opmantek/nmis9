#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Test NMISNG fuctions
# creates (and removes) a mongo database called t_nmisg-<timestamp>
#  in whatever mongodb is configured in ../conf/
use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::Timing;
use IO::File;
use File::Path qw( make_path );
use Data::Dumper;

my $t = Compat::Timing->new();
my $time = $t->elapTime();
my $C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
print $time. " time load config \n";

# log to stdout
my $logger = NMISNG::Log->new( level => 'debug' );

is($C->{'auth_expire'}, "+30min", "Config file loaded" );

my $conf_d_dir = $C->{'<nmis_conf>'} . "/conf.d";
if ( !-d $conf_d_dir ) {
    make_path $conf_d_dir or die "Failed to create path: $conf_d_dir";
}

my $file = "$conf_d_dir/TEST.nmis";

my $content = "%hash = (\'authentication\'=>{\'auth_expire\'=>\'+2min\',
\'test\'=>2});";

my $fn;
open($fn, '>', $file) or die "Could not open file '$file' $!";

print $fn $content;
close $fn;

sub cleanup_db
{
    unlink $file;
	# Remove conf file
}

$time = $t->elapTime();
$C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
print $time. " time load new config \n";

is($C->{'auth_expire'}, "+2min", "External config file loaded" );

# Try to edit not editable configs
$content = "%hash = (\'id\'=>{\'cluster_id\'=>\'FAIL\'});";
#my $fn;
open($fn, '>', $file) or die "Could not open file '$file' $!";

print $fn $content;
close $fn;
$time = $t->elapTime();
$C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
print $time. " time load new config \n";

is($C->{'cluster_id'}, "a5159999-0d11-4bcb-a402-39a460012345", "Non modificable properties OK" );

# Test for replacing macros in the file
open($fn, '>', $file) or die "Could not open file '$file' $!";

$content = "%hash = (\'authentication\'=>{\'auth_htpasswd_file\'=>\'<nmis_conf>/users.dat\'});";
close $fn;
$time = $t->elapTime();
$C = NMISNG::Util::loadConfTable();
$time = $t->elapTime() - $time;
print $time. " time load new config \n";
# Check values
#print Dumper($C);

# We need to add here the real values as we need to know if the values are correctly replaced
is($C->{'auth_htpasswd_file'}, "/usr/local/nmis9_josunec/conf/users.dat", "Replacing Macros from external conf OK" );
is($C->{'auth_htpasswd_file'}, $C->{'<nmis_conf>'}."/users.dat", "Replacing Macros from external conf OK" );
is($C->{'syslog_log'}, "/usr/local/nmis9_josunec/logs/cisco.log", "Replacing Macros from master config OK" );
is($C->{'syslog_log'}, $C->{'<nmis_logs>'}."/cisco.log", "Replacing Macros from master config OK" );
# Read again to see if it is loading the cache
#my $C = NMISNG::Util::loadConfTable();

cleanup_db();
done_testing();