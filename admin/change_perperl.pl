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

use strict;

# Variables for command line munging
my %ARG = getArguements(@ARGV);

if ( ! defined $ARG{dir} ) {
	$ARG{dir} = "/usr/local/nmis/cgi-bin";
} 

if ( ! defined $ARG{perl} ) {
	$ARG{perl} = "/usr/bin/perl";
} 

if ( ! defined $ARG{perperl} ) {
	print "change_perperl, command line option is perperl=true|false\n";
	print " for update of *.pl files in directory $ARG{dir}\n\n";
	exit 1;
} elsif ($ARG{perperl} eq 'true' ) {
	if ( eval {require PersistentPerl} ) {
		my $line = `which perperl`;
		chomp $line;
		if ($line =~ /which/) {
			$ARG{perl} = "/usr/bin/perperl"; # not found, default
		} else {
			$ARG{perl} = "$line";
		}
	} else {
		print "ERROR, PersistentPerl not installed\n";
		print "INFO, this tool can be installed from CPAN\n";
	}
} 

my $debug = &setDebug($ARG{debug});

my $pass = 0;
my $dirpass = 1;
my $dirlevel = 0;
my $maxrecurse = 200;
my $maxlevel = 10;

my $bad_file;
my $bad_dir;
my $file_count;
my $extension = "pl";

print "Changing all Perl \#! line to $ARG{perl}.\n";

&processDir(dir => $ARG{dir});

print "Done.  Processed $file_count perl files.\n";

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
		
		if ($debug > 1) { print "\tFound $#dirlist entries\n"; }
		
		for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$dirlist[$index]");
			if ( -f "$dir/$dirlist[$index]"
				and $extension =~ /$filename[$#filename]/i 
				and $bad_file !~ /$dirlist[$index]/i
			) {
				if ($debug>1) { print "\t\t$index file $dir/$dirlist[$index]\n"; }
				backupFile(file => "$dir/$dirlist[$index]", backup => "$dir/$dirlist[$index].bak" );
				processPerlFile(file => "$dir/$dirlist[$index]", perl => $ARG{perl} );
				unlink "$dir/$dirlist[$index].bak";
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

sub processPerlFile {
	my %args = @_;
	++$file_count;
	my @lines;
	my $countlines=0 ;
	if ($debug) { print "Processing $args{file}\n"; }
	open(IN, $args{file}) or die "ERROR with $args{file}. $!\n";
	while (<IN>) {
		push (@lines,$_);		
	} # while IN
	close(IN);

	open(OUT, ">$args{file}") or die "ERROR with $args{file}. $!\n";
	foreach (@lines) {
		$countlines++ ;
		$_ = rmTrailingBits($_);
		if ($countlines==1) {
			if ( $_ =~ /^\#!/ ) {
				$_ =~ s/\n//;
				print "$args{file} changing $_ to $args{perl}\n";
				print OUT "\#!$args{perl}\n";
			}
		} 
		else {
			print OUT $_;
		}
	} # while IN
	close(OUT);
}

sub getArguements {
	my @argue = @_;
	my (%nvp, $name, $value, $line, $i);
	for ($i=0; $i <= $#argue; ++$i) {
	        if ($argue[$i] =~ /.+=/) {
	                ($name,$value) = split("=",$argue[$i]);
	                $nvp{$name} = $value;
	        } 
	        else { print "Invalid command argument: $argue[$i]\n"; }
	}
	return %nvp;
}

sub setDebug {
	my $string = shift;
	my $debug = 0;
	if ( $string eq "true" ) { $debug = 1; }	
	elsif (  $string eq "verbose" ) { $debug = 9; }	
	elsif ( $string =~ /\d+/ ) { $debug = $string; }	
	else { $debug = 0; }	
	return $debug;
}

sub rmTrailingBits {
	my $string = shift;
	while ( $string =~ /\r/ ) {
		$string =~ s/\r//g;
	}
	return $string;
}

sub backupFile {
	my %arg = @_;
	my $buff;
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
		print STDERR "ERROR, backupFile file $arg{file} not readable.\n";
		return 0;
	}
}
