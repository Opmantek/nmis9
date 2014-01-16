#!/usr/bin/perl
#
## $Id: modelcheck.pl,v 1.1 2011/11/16 01:59:35 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;
use NMIS;

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


if ( $debug ) {
	&processDir(dir => "/tmp/models");
}
else {
	&processDir(dir => $C->{'<nmis_models>'});
}

print "Done.  Processed $file_count NMIS Model files.\n";

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

		if ($debug > 1) { print "\tFound $#dirlist entries\n"; }

		for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$dirlist[$index]");
			if ( -f "$dir/$dirlist[$index]"
				and $extension =~ /$filename[$#filename]/i
				and $bad_file !~ /$dirlist[$index]/i
			) {
				if ($debug>1) { print "\t\t$index file $dir/$dirlist[$index]\n"; }
				&processModelFile(file => "$dir/$dirlist[$index]")
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

sub processModelFile {
	my %args = @_;
	my $file = $args{file};
	$indent = 2;
	++$file_count;

	print &indent . "Processing $file\n";
	my $model = readFiletoHash(file=>$file);

	#Recurse into structure, handing off anything which is a HASH to be handled?
	push(@path,"Model");
	processData($model,"Model");	
	pop(@path);
	
}

sub processData {
	my $data = shift;
	my $comment = shift;
	$indent += 2;
	
	if ( ref($data) eq "HASH" ) {
		foreach my $section (sort keys %{$data}) {
			my $curpath = join("/",@path);
			if ( ref($data->{$section}) =~ /HASH|ARRAY/ ) {
				print &indent . "$curpath -> $section\n" if $debug;
				#recurse baby!
				if ( $curpath =~ /rrd\/\w+\/snmp$/ ) {
					print indent."Found RRD Variable $section \@ $curpath\n" if $debug;
					checkRrdLength($section);
				}
					
				push(@path,$section);
				processData($data->{$section},"$section");
				pop(@path);
			}
			else {
				print &indent . "$curpath -> $section = $data->{$section}\n" if $debug;
			}
		}
	}
	elsif ( ref($data) eq "ARRAY" ) {
		foreach my $element (@{$data}) {
			my $curpath = join("/",@path);
			print indent."$curpath: $element\n" if $debug;
			#Is this an RRD DEF?
			if ( $element =~ /DEF:/ ) {
				my @DEF = split(":",$element);
				#DEF:avgBusy1=$database:avgBusy1:AVERAGE
				checkRrdLength($DEF[2]);
			}
		}
	}
	$indent -= 2;
}

sub checkRrdLength {
	my $string = shift;
	my $len = length($string);
	print indent."FOUND: $string is length $len\n" if $debug;
	if ($len > $rrdlen ) {
		print "    ERROR: RRD variable $string found longer than $rrdlen\n";
			
	}
}


