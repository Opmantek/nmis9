#!/usr/bin/perl
#
## $Id: modelcheck.pl,v 1.1 2011/11/16 01:59:35 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;
use NMIS;
use JSON;

my $debug = 0;

# load configuration table
my $C = loadConfTable(conf=>undef,debug=>$debug);

my $pass = 0;
my $dirpass = 1;
my $dirlevel = 0;
my $maxrecurse = 200;
my $maxlevel = 10;

my $bad_file;
my $bad_dir;
my $file_count;
my $extension = "nmis";

my $indent = 0;
my @path;
my $rrdlen = 19;

print "This script will perform a check the models for a few things.\n";
print "Using configured model directory $C->{'<nmis_models>'}\n";
print "\nCurrent important test is RRD Variables greater than $rrdlen\n";

# Process
# 1. Stop NMIS Polling
# 2. Convert NMIS files to JSON files
# 3. Change config to use JSON
# 4. Start NMIS polling.

if ( $debug ) {
	&processDir(dir => "/tmp/models");
}
else {
	&updateNmisConfigBefore();
	&processDir(dir => $C->{'<nmis_var>'});
	&updateNmisConfigAfter();
}

print "Done.  Processed $file_count NMIS files.\n";

sub indent {
	for (1..$indent) {
		print " ";
	}
}

sub processDir {
	my %args = @_;
	# Starting point
	my $dir = $args{dir};
	my @dirlist;
	my $index;
	++$dirlevel;
	my @filename;
	my $key;

	if ( -d $dir ) {
		print "\nProcessing Directory $dir pass=$dirpass level=$dirlevel\n";
	}
	else {
		print "\n$dir is not a directory\n";
		exit -1;
	}

	#sleep 1;
	if ( $dirpass >= 1 and $dirpass < $maxrecurse and $dirlevel <= $maxlevel ) {
		++$dirpass;
		opendir (DIR, "$dir");
		@dirlist = readdir DIR;
		closedir DIR;
		my $pretty = 1;
		if( $dir eq $C->{'<nmis_var>'} ) { $pretty = 0; }
		if ($debug > 1) { print "\tFound $#dirlist entries\n"; }

		for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$dirlist[$index]");
			if ( -f "$dir/$dirlist[$index]"
				and $extension =~ /$filename[$#filename]/i
				and $bad_file !~ /$dirlist[$index]/i
			) {
				if ($debug>1) { print "\t\t$index file $dir/$dirlist[$index]\n"; }
				&processNmisFile(file => "$dir/$dirlist[$index]", pretty => $pretty)
			}
			elsif ( -d "$dir/$dirlist[$index]"
				and $dirlist[$index] !~ /^\.|CVS/
				and $bad_dir !~ /$dirlist[$index]/i
			) {
				#if (!$debug) { print "."; }
				&processDir(dir => "$dir/$dirlist[$index]");
				--$dirlevel;
			}
		}
	}
} # processDir

sub processNmisFile {
	my %args = @_;
	my $file = $args{file};
	my $pretty = $args{pretty};
	$indent = 2;
	++$file_count;

	my ($jsonfile,undef) = getFileName(file => $file, json => 1);
	
	if ( $jsonfile =~ /json/ ) {
		print &indent . "Converting $file to $jsonfile\n";
		my $data = readFiletoHash(file=>$file);
		writeHashtoFile(data=>$data,file=>$file, json => 1, pretty => $pretty);	
	}
}

sub updateNmisConfigBefore {
	my $configFile = "$C->{'<nmis_conf>'}/Config.nmis";
	my $conf;
	
	if ( -f $configFile ) {
		$conf = readFiletoHash(file=>$configFile);
	}
	else {
		print "ERROR: something wrong with config file 1: $configFile\n";
		exit 1;
	}
	$conf->{'system'}{'global_collect'} = "false";

	writeHashtoFile(file=>$configFile,data=>$conf);
}

sub updateNmisConfigAfter {
	my $configFile = "$C->{'<nmis_conf>'}/Config.nmis";
	my $conf;
		
	if ( -f $configFile ) {
		$conf = readFiletoHash(file=>$configFile);
	}
	else {
		print "ERROR: something wrong with config file 1: $configFile\n";
		exit 1;
	}
	
	if ( not exists $conf->{'system'}{'use_json'} ) { 
		$conf->{'system'}{'use_json'} = "true";
	}
	if ( not exists $conf->{'system'}{'use_json_pretty'} ) { 
		$conf->{'system'}{'use_json_pretty'} = "true";
	}
	$conf->{'system'}{'global_collect'} = "true";

	writeHashtoFile(file=>$configFile,data=>$conf);
}
