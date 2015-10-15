#!/usr/bin/perl
#
## $Id: rrd_resize.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
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

# this script can be used to grow or shrink the RRD's, currently only used for growing.

my $FUNCTION = "GROW";
my $DAILY_TARGET = 9216;
my $WEEKLY_TARGET = 4608;
my $BACKUP_RRDS = 1;

# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use lib "/usr/local/rrdtool/lib/perl"; 
use RRDs 1.000.490; # from Tobias
use Data::Dumper;

# Variables for command line munging
my %ARG = getArguements(@ARGV);

my $C = loadConfTable(conf=>$ARG{conf},debug=>$ARG{debug});

my $debug = $C->{debug};

my $pass = 0;
my $dirpass = 1;
my $dirlevel = 0;
my $maxrecurse = 500;
my $maxlevel = 10;

my $bad_file;
my $bad_dir;
my $file_count;
my $extension = "rrd";

my $rrdtool = ($ARG{rrdtool} ne '') ? "$ARG{rrdtool}/rrdtool" : "rrdtool";
my $info = `$rrdtool`;
if ($info eq "") {
	$rrdtool = "/usr/local/rrdtool/bin/rrdtool"; # maybe this
	$info = `$rrdtool`;
	if ($info eq "") {
		print "ERROR, rrdtool not found\n";
		print " specify location of rrdtool with option rrdtool='dir_of_rrdtool'\n";
		exit;
	}
}

my $dir = $C->{database_root};

if ($ARG{dir} ne '') { $dir = $ARG{dir}; }

print " Resize all RRD files to desired size\n";

&processDir(dir => $dir);

print "Done.  Processed $file_count RRD files.\n";

exit 1;

# process a directory full of rrd files.
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
		
		dbg("Found $#dirlist entries");
		
		for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$dirlist[$index]");
			if ( -f "$dir/$dirlist[$index]"
				and $extension =~ /$filename[$#filename]/i 
				and $bad_file !~ /$dirlist[$index]/i
			) {
				dbg("\t$index file $dir/$dirlist[$index]");
				processRRDFile(dir => $dir, rrd => $dirlist[$index]);
			}
			elsif ( -d "$dir/$dirlist[$index]" 
				and $dirlist[$index] !~ /^\./ 
				and $bad_dir !~ /$dirlist[$index]/i
			) {
				#if (!$debug) { print "."; }
				processDir(dir => "$dir/$dirlist[$index]");
				--$dirlevel;
			}
		}	
	}
} # processDir

# process a single rrd file.
sub processRRDFile {
	my %args = @_;
	my $dir = $args{dir};
	my $rrd = $args{rrd};

	my $resrrd = "resize.rrd";
	
	chdir($dir);
	
	print "dir=$dir rrd=$rrd\n";

	++$file_count;
	my @lines;
	my $countlines=0 ;
	dbg("Processing $rrd");

	
	# is a backup of the original RRD required.
	my $backup = 1;
	if ( $BACKUP_RRDS ) {
		$backup = backupFile(file => $rrd, backup => "$rrd.bak");
		if ( $backup ) {
			dbg("$rrd backup'ed up to $rrd.bak");
		}
		else {
			print "SKIPPING: $rrd could not be backup'ed\n";
		}
	}
	else {
		print "$rrd will NOT be backedup.\n";
	}
	
	# start processing
	if ( ( $BACKUP_RRDS and $backup ) or not $BACKUP_RRDS ) {
		my $rra = getRraDetails($rrd);
		#print Dumper($rra);
					
		foreach my $r (sort keys %$rra) {
			my $target = 0;
			my $typetarg = undef;
			if ($rra->{$r}{type} eq "daily") {
				$target = $DAILY_TARGET - $rra->{$r}{rows};
				$typetarg = $DAILY_TARGET;
			}
			elsif ($rra->{$r}{type} eq "weekly") {
				$target = $WEEKLY_TARGET - $rra->{$r}{rows};
				$typetarg = $WEEKLY_TARGET;
			}
			
			# if there is something todo process the rrd
			if ( $target != 0 ) {
				#this is the command line which will be executed
				my $exec = "$rrdtool resize \"$rrd\" $r $FUNCTION $target";
				dbg("EXEC: $exec");
				my $out = `$exec`;
				# rename the resize.rrd file to the original file.
				rename($resrrd,$rrd);
			}
			else {
				print "SKIPPING $rrd, $rra->{$r}{type} rows $rra->{$r}{rows} already $typetarg\n";
			}
		}
		setFileProt($rrd); # set file owner/permission, default: nmis, 0775
	}
}

# this will use RRDs::info to extract information about the RRD from the file.  
# It will then extract some key days and return a subset of important information.
sub getRraDetails {
	my $rrd = shift;
	my $keys = shift;
	my $hash = RRDs::info($rrd);
	my %rranums;
	my %rra;
	my $rraNum;
	my $rraRows;
	my $rraPdp;
	foreach my $key (sort keys %$hash){
		if ( $key =~ /rra\[(\d+)]\.(cf|pdp_per_row|rows)/ ) {
			$rra{$1}{$2} = $$hash{$key};
		}
	}
	foreach my $key (sort keys %rra){
		if ( $rra{$key}{pdp_per_row} == 1 ) {
			$rranums{$key}{type} = "daily";
			$rranums{$key}{rows} = $rra{$key}{rows};
			$rranums{$key}{rra} = $key;
			$rranums{$key}{function} = $rra{$key}{cf};
		}
		elsif ( $rra{$key}{pdp_per_row} == 6 ) {
			$rranums{$key}{type} = "weekly";
			$rranums{$key}{rows} = $rra{$key}{rows};
			$rranums{$key}{function} = $rra{$key}{cf};
			$rranums{$key}{rra} = $key;
		}
	}
	return \%rranums;
}

sub backupFile {
	my %arg = @_;
	my $buff;
	if ( not -f $arg{backup} ) {			
		if ( -r $arg{file} ) {
			open(IN,$arg{file}) or warn ("ERROR: problem with file $arg{file}; $!");
			open(OUT,">$arg{backup}") or warn ("ERROR: problem with file $arg{backup}; $!");
			binmode(IN);
			binmode(OUT);
			while (read(IN, $buff, 8 * 2**10)) {
			    print OUT $buff;
			}
			close(IN);
			close(OUT);
			return 1;
		} else {
			print STDERR "ERROR: backupFile file $arg{file} not readable.\n";
			return 0;
		}
	}
	else {
		print STDERR "ERROR: backup target $arg{backup} already exists.\n";
		return 0;
	}
}

sub getRrdInfo {
	my $rrd = shift;
	my $hash = RRDs::info($rrd);
	foreach my $key (sort keys %$hash){
		print "$key = $$hash{$key}\n";
	}
	return $hash;
}

