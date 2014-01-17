#!/usr/bin/perl
#
## $Id: check_nmis_code.pl,v 8.2 2012/05/24 13:24:37 keiths Exp $
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

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use NMIS::Timing;

my $t = NMIS::Timing->new();

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $log = 0;
$log = 1 if $arg{log};


my $debug = 0;
$debug = 1 if $arg{debug};

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$debug);

print $t->elapTime(). " Processing NMIS Code Base and Verifying all the Code and Configuration Files\n" if $log;

my $sum;
$sum->{fail} = 0;
$sum->{pass} = 0;
my $extension = "pl,pm,nmis";
my $passQr = qr/syntax OK/;
my $failQr = qr/had compilation errors/;
my $allPass = 1;
my @failed;

processDir("$C->{'<nmis_base>'}/admin");
processDir("$C->{'<nmis_base>'}/bin");
processDir("$C->{'<nmis_base>'}/conf");
processDir("$C->{'<nmis_base>'}/install");
#Because Perl is a little fussy about paths, change to the lib then check.
chdir("$C->{'<nmis_base>'}/lib");
processDir("$C->{'<nmis_base>'}/lib");
processDir("$C->{'<nmis_base>'}/models-install");
processDir("$C->{'<nmis_base>'}/models");

#
#my $LNT = loadLocalNodeTable();

if ( $log ) {
	print qq|
$sum->{pass} files passed check
$sum->{fail} files FAILED check
$sum->{file} files total
$sum->{dir} directories total
|;
}

if ( $allPass ) {
	exit 0;
}
else {
	print "Failed Files\n";
	foreach my $file (@failed) {
		print "$file\n";
	}
	exit 1;	
}

sub processDir {
	my $dir = shift;

	my @filename;
	my @dirlist;
	my $hostname;
	my $i;

	if ( -d $dir ) {
		# File is a directory
		print "  ".$t->elapTime(). " Working on $dir\n" if $log;
		++$sum->{dir};
		
		opendir (DIR, "$dir");
		@dirlist = readdir DIR;
		closedir DIR;

		@dirlist = sort @dirlist;
		for ( $i = 0 ; $i <= $#dirlist ; ++$i ) {
			@filename = split(/\./,"$dirlist[$i]");
			if ( $extension =~ /$filename[$#filename]/i and ! -d "$dir/$dirlist[$i]" ) {
				print "." if $log and not $debug;

				if ( $dirlist[$i] !~ /^Table\-/ ) {
					print "    ". $t->markTime(). " Checking $dir/$dirlist[$i]\n" if $debug;
					my $codePass = &checkCode("$dir/$dirlist[$i]");
					print "     done in ".$t->deltaTime() ."\n" if $debug;

					if ( $codePass ) {
						++$sum->{pass};	
					}
					else {
						++$sum->{fail};
						push(@failed,"$dir/$dirlist[$i]");
					}

					if ( $allPass and not $codePass ) {
						$allPass = 0;	
					}
				}
				else {
					print "    ". $t->markTime(). " Skipping $dir/$dirlist[$i]\n" if $debug;
				}
			}
			elsif ( -d "$dir/$dirlist[$i]" and $dirlist[$i] !~ /^\.|CVS/ ) {
				&processDir("$dir/$dirlist[$i]");
			}
		}
		print "\n" if $log and not $debug;
	}
	else {
		print "ERROR: Nothing to see here, move along!\n";
	}
}


sub checkCode {
	my $file = shift;
	my $pass = 0;

	++$sum->{file};

	my $cmd = "perl -c $file";

	my $pid = open(PH, "$cmd 2>&1 |");              # or with an open pipe
	my $out;
	while (<PH>) { 
		$out .= $_;
		if ( $_ =~ /$passQr/ ) {
			$pass = 1;
		}
		elsif ( $_ =~ /$failQr/ ) {
			$pass = 0;
		}
	} 
	if ( not $pass ) {
		print "ERROR compiling $file\n";
		print $out . "\n";	
	}
	close(PH);

	return $pass;
}
