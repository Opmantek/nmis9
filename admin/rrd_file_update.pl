#!/usr/bin/perl
#
#	Copyright 2008 (C) Network Management Information Systems Ltd
#	<www.nmis.co.nz/contact>, hereafter referred to as 'NMIS'.
#	PO Box 42149, Christchurch 8042, New Zealand.
#	Contributed by Eric Greenwood <eric_at_nmis.co.nz>, Jan van Keulen
#	<jan_at_nmis.co.nz> and Keith Sinclair <keith_at_nmis.co.nz>
#
#	This file, rrd_file_update.pl, is part of NMIS. NMIS is free software: you can
#	redistribute it and/or modify it under the terms of the GNU General
#	Public License as published by the Free Software Foundation, either
#	version 3 of the License, or (at your option) any later version. NMIS is
#	distributed in the hope that it will be useful, but WITHOUT ANY
#	WARRANTY; without even the implied warranty of MERCHANTABILITY or
#	FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
#	more details. You should have received a copy of the GNU General Public
#	License along with NMIS. If not, see <http://www.gnu.org/licenses/>.
#
# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use lib "/usr/local/rrdtool/lib/perl"; 
use RRDs 1.000.490; # from Tobias

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

# version of rrdtool
my $version;
if ($info =~ /.*RRDtool\s+(\d+)\.(\d+)\.(\d+).*/) {
	$version = "$1.$2.$3";
	dbg("RRDtool version is $1.$2.$3");
}

#my $onerrd = "/usr/local/nmis8/database/health/router/meatball-reach.rrd";
#processRRDFile(file => $onerrd);
#exit 0;

my $dir = $C->{database_root};

if ($ARG{dir} ne '') { $dir = $ARG{dir}; }

print " Upgrade all RRD files to last RRD version, this takes some time\n";

&processDir(dir => $dir);

print "Done.  Processed $file_count RRD files.\n";

exit 1;

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
				processRRDFile(file => "$dir/$dirlist[$index]");
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

sub processRRDFile {
	my %args = @_;
	my $rrd = $args{file};

	print "File=$rrd\n";

	++$file_count;
	my @lines;
	my $countlines=0 ;
	dbg("Processing $rrd");

	# Get XML Output
	my $xml = `$rrdtool dump $rrd`;
	if ( $xml =~ /Round Robin Archives/ ) {
		if ( -w $rrd ) {
 			# Move the old source
			if (rename($rrd,$rrd.".bak")) {
				dbg("$rrd moved to $rrd.bak");
				if ( -e "$rrd.xml" ) {
					# from previous action
					unlink $rrd.".xml";
					dbg("$rrd.xml deleted (previous action)");
				}
				# write output
				if (open(OUTF, ">$rrd.xml")) {
					print OUTF $xml;
					close (OUTF);
					dbg("xml written to $rrd.xml");
					# Re-import
					RRDs::restore("--range-check",$rrd.".xml",$rrd);
					if (my $ERROR = RRDs::error) {
						print "update ERROR database=$rrd: $ERROR\n";
					} else {
						dbg("$rrd created");
						setFileProt($rrd); # set file owner/permission, default: nmis, 0775
						#`chown nmis:nmis $rrd` ; # set owner
						# Delete
						unlink $rrd.".xml";
						dbg("$rrd.xml deleted");
						unlink $rrd.".bak";
						dbg("$rrd.bak deleted");
						return 1;
					}
				} else {
					print "ERROR, could not open $rrd.xml for writing, $!\n";
					rename($rrd.".bak",$rrd); # backup
				}
			} else {
				print "ERROR, cannot rename $rrd, $!\n" ;
				exit;
			}
		} else {
			print "ERROR, no write permission for $rrd, $!\n" ;
			exit;
		}
	} else {
		print "ERROR, could not dump (maybe rrdtool missing): $!\n";
		exit;
	}
}

