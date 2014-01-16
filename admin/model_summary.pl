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
use Data::Dumper;

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

my $curModel;
my $models;
my $vendors;
my $modLevel;
my @topSections;
my @oidList;

print "Summarise the Models\n";

&processDir(dir => $C->{'<nmis_models>'});

print "Done.  Processed $file_count NMIS Model files.\n";

#print Dumper($models);

@oidList = sort @oidList;
my $out = join(",",@oidList);
print "OIDS:$out\n";

my %summary;
foreach my $model (keys %$models) {
	foreach my $section (@{$models->{$model}{sections}}) {
		$summary{$model}{$section} = "YES";
		if ( not grep {$section eq $_} @topSections ) {
			print "ADDING $section to TopSections\n";
			push(@topSections,$section);
		}
	}
}

@topSections = sort @topSections;
my $out = join(",",@topSections);
print "Model,$out\n";

foreach my $model (sort keys %summary) {
	my @line;
	push(@line,$model);
	foreach my $section (@topSections) {
		if ( $summary{$model}{$section} eq "YES" ) {
			push(@line,$summary{$model}{$section});
		}
		else {
			push(@line,"NO");
		}
	}
	my $out = join(",",@line);
	print "$out\n";
}

#print Dumper(\%summary);

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
				&processModelFile(dir => $dir, file => $dirlist[$index])
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
	my $dir = $args{dir};
	my $file = $args{file};
	$indent = 2;
	++$file_count;
	
	if ( $file !~ /^Graph|^Common|^Model.nmis$/ ) {
		$curModel = $file;
		$curModel =~ s/Model\-|\.nmis//g;
	
		print &indent . "Processing $curModel: $file\n";
		my $model = readFiletoHash(file=>"$dir/$file");		
		#Recurse into structure, handing off anything which is a HASH to be handled?
		push(@path,"Model");
		$modLevel = 0;
		processData($model,"Model");	
		pop(@path);
	}	
}

sub processData {
	my $data = shift;
	my $comment = shift;
	$indent += 2;
	++$modLevel;
	
	if ( ref($data) eq "HASH" ) {
		foreach my $section (sort keys %{$data}) {
			my $curpath = join("/",@path);
			if ( ref($data->{$section}) =~ /HASH|ARRAY/ ) {
				print &indent . "$curpath -> $section\n" if $debug;
				#recurse baby!
				if ( $curpath =~ /rrd\/\w+\/snmp$/ ) {
					#print indent."Found RRD Variable $section \@ $curpath\n" if $debug;
					#checkRrdLength($section);
				}
									
				push(@path,$section);
				if ( $modLevel <= 1 and $section !~ /-common-|class/ ) {
					push(@{$models->{$curModel}{sections}},$section);
					if ( not grep {$section eq $_} @path ) {
						push(@topSections,$section);
					}
				}
				elsif ( grep {"-common-" eq $_} @path and $section !~ /-common-|class/ ) {
					push(@{$models->{$curModel}{sections}},"Common-$section");
					if ( not grep {$section eq $_} @path ) {
						push(@topSections,$section);
					}				
				}

				processData($data->{$section},"$section");
				
				pop(@path);
			}
			else {
				if ( $section eq "oid" ) {
					print "    $curpath/$section: $data->{$section}\n";
					
					if ( not grep {$data->{$section} eq $_} @oidList ) {
						print "ADDING $data->{$section} to oidList\n" if $debug;
						push(@oidList,$data->{$section});
					}
				}
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
	--$modLevel;
}

sub checkRrdLength {
	my $string = shift;
	my $len = length($string);
	print indent."FOUND: $string is length $len\n" if $debug;
	if ($len > $rrdlen ) {
		print "    ERROR: RRD variable $string found longer than $rrdlen\n";
			
	}
}


