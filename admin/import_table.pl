#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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
# a command-line table data import/update tool for NMIS 9
use strict;
use warnings;

our $VERSION = "9.6.6";
if (@ARGV == 1 && $ARGV[0] eq "--version")
{
    print "version=$VERSION\n";
    exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use Text::CSV qw(csv);
use Data::Dumper;

use NMISNG::Util;
use NMISNG::Log;
use Compat::NMIS;

my $bn = basename($0);
my $usage = "Usage: $bn csv=[csv file path] table=[NMIS Table type]

$bn will import NMIS Table data in csv format
usage: $bn csv=csvfile table=tabletype

NOTE: for now, CSV columns must match table keys (can be found in Table-tabletype.nmis)

eg. $bn csv=/tmp/new_and_updated_locations.csv table=Locations
";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir, debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH" or !keys %$config);

# for now put everything in the terminal
# my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(debug => $cmdline->{debug}) // $config->{log_level}, path  => undef); #(defined $cmdline->{debug})? undef : $logfile);

my $csv = $cmdline->{csv};
die 'csv= required' if(!$csv);
my $table = $cmdline->{table};
die 'table= required' if(!$table);

# Load the table definitinon
my $CT = Compat::NMIS::loadCfgTable(user => "cli", table=>$table);
die 'Invalid table:'.$CT if(ref($CT) !~ /HASH|ARRAY/);
$CT = [$CT] if (ref($CT) eq 'HASH'); # can be hash or array, array is funky with hashes inside the array

my $key_name;
my $mandatory = {};
# search for key and manditory fields
foreach my $hashtable (@$CT) {
    foreach my $entry_key_name (keys %$hashtable ) {
        my $entry = $hashtable->{$entry_key_name};
        if( $entry->{display} =~ /key/ )  {
            $key_name = $entry_key_name;
            $logger->info("Found table key $key_name");
        }
        if( NMISNG::Util::getbool($entry->{mandatory}) ) {
            $mandatory->{$entry_key_name} = 1;
            $logger->info("Found table madatory key: $entry_key_name");
        }
        
    }
}

# Load the table data
my $T = NMISNG::Util::loadTable(dir=>'conf',name=>$table);
die 'Failed to load table data:'.$T if(ref($T) !~ /HASH/);

# Load the csv data
my $lines = csv (in => $csv, headers => "auto", encoding => "UTF-8"); 

# map from table data to csv headers, NOTE: not used at this time
my %mapping = ();
my $mapped_key_name = $mapping{$key_name} // $key_name;
# map from csv headers to table data
my %rev_mapping = map { $mapping{$_} => $_ } (keys %mapping);

# Process the lines
foreach my $line (@{$lines}) {    
    $logger->debug("line dump ".Dumper($line));
    # make sure the key value exists
    if( $key_name && !$line->{$mapped_key_name} ) {
        $logger->error("Skipping line, missing key($key_name):$mapped_key_name,".join(",",values %$line));
        next;
    }
    my $key = $line->{$mapped_key_name}; # the hash key that the entry will be stored in the table under
    $logger->info("Processing $key");

    foreach my $mandatory_key (keys %$mandatory) {
        my $mapped_mandatory_key = $mapping{$mandatory_key} // $mandatory_key;
        if( !$line->{$mapped_mandatory_key} ) {
            $logger->error("Skipping line, missing mandatory value for($mandatory_key):$mapped_mandatory_key,".join(",",values %$line));
        }
        next;
    }

    # find the existing entry to update or make a new hash
    my $entry = {};
    my $op = "added";
    if( defined($T->{$key}) ) {
        $op = "updated";
        $entry = $T->{$key};
    }    
    foreach my $header (keys %$line) {
        my $mapped_header = $rev_mapping{$header} // $header;
        $entry->{$mapped_header} = $line->{$header};
    }
    $T->{$key} = $entry;
    $logger->info("$op $key");
}

if( my $error = NMISNG::Util::writeTable(dir=>'conf',name=>$table, data=>$T) ) {
    $logger->error("failed to write table data: $error");
}

1;



