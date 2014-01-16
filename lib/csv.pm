#
## $Id: csv.pm,v 8.2 2011/08/28 15:11:05 nmisdev Exp $
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
#
package csv;

use strict;
use func;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(	
		loadCSV
		writeCSV
		loadCSVHeaders
		writeCSVHeaders
		loadCSVarray
	);

@EXPORT_OK = qw( );

sub loadCSV {
	my $file = shift;
	my $key = shift;
	my $seperator = shift;
	my $reckey;
	my $line = 1;
	
	if ( $seperator eq "" ) { $seperator = "\t"; }

	my $passCounter = 0;

	my $i;
	my @rowElements;
	my @headers;
	my %headersHash;
	my @keylist;
	my $row;
	my $head;
	
	my %data;
	
	#open (DATAFILE, "$file")
	if (sysopen(DATAFILE, "$file", O_RDONLY)) {
		flock(DATAFILE, LOCK_SH) or warn "can't lock filename: $!";
	
		while (<DATAFILE>) {
			#$_ =~ s/\n$//g;
			# If it is the first pass load the column headers into an array and a hash.
			if ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter == 0 ) {
				++$passCounter;
				$_ =~ s/\"//g;
				@headers = split(/$seperator|\n/, $_);
				for ( $i = 0; $i <= $#headers; ++$i ) {
					$headersHash{$headers[$i]} = $i;
				}
			}
			elsif ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter > 0 ) {
				$_ =~ s/\"//g;
				@rowElements = split(/$seperator|\n/, $_);
				if ( $key =~ /:/ ) {
					$reckey = "";
					@keylist = split(":",$key);
					for ($i = 0; $i <= $#keylist; ++$i) {
						$reckey = $reckey.lc("$rowElements[$headersHash{$keylist[$i]}]");
						if ( $i < $#keylist )  { $reckey = $reckey."_" }
					}
				}
				else {
					$reckey = lc("$rowElements[$headersHash{$key}]");
				}
				if ( $#headers > 0 and $#headers != $#rowElements ) {
					$head = $#headers + 1;
					$row = $#rowElements + 1;
					print STDERR "ERROR: $0 in csv.pm: Invalid CSV data file $file; line $line; record \"$reckey\"; $head elements in header; $row elements in data.\n";
				}
				#What if $reckey is blank could form an alternate key?
				if ( $reckey eq "" or $key eq "" ) {
					$reckey = join("-", @rowElements);
				}
				
				for ($i = 0; $i <= $#rowElements; ++$i) {
					if ( $rowElements[$i] eq "null" ) { $rowElements[$i] = ""; }
					$data{$reckey}{$headers[$i]} = $rowElements[$i];
				}
			}
			++$line;
		}
		close (DATAFILE) or warn "can't close filename: $!";
	} else {
		logMsg("cannot open file $file, $!");
	}
	
	return (%data);
}

sub writeCSV (\%@) {
	# MUST BE CALLED WITH &writeCSV not writeCSV!!!!!!!!!
	my $seperator = pop;
	my $file = pop;
	my %csv = @_;
	my $key;
	my $head;
	my $gotheader = 0;
	my @line;
	my $string;
	my $i;

	if ( $seperator eq "" ) { $seperator = "\t"; }
	
	# change to secure sysopen with truncate after we got the lock
	sysopen(OUT, "$file", O_WRONLY | O_CREAT) or warn "Couldn't open file $file for writing. $!";
	flock(OUT, LOCK_EX) or warn "can't lock filename: $!";
	truncate(OUT, 0) or warn "can't truncate filename: $!";

	foreach $key (sort (keys %csv) ) {
		if ( not $gotheader) {
			$gotheader = 1;
			$i = 0;
			foreach $head (sort (keys %{$csv{$key}})) {
				$line[$i] = $head;
				++$i;
			}
			$string = join($seperator,@line);
			#Handy for debug
			#print "HEAD: $string\n";
			print OUT "# THE FIRST LINE NON COMMENT IS THE HEADER LINE AND REQUIRED\n";
			print OUT "$string\n";
		}
		
		$i = 0;
		foreach $head (sort (keys %{$csv{$key}})) {
			if ( $csv{$key}{$head} eq "" ) { $csv{$key}{$head} = "null"; }
			$line[$i] = $csv{$key}{$head};
			++$i;
		}
		$string = join($seperator,@line);
		#Handy for debug
		#print "DATA: $string\n";
		print OUT "$string\n";
	}
	close(OUT) or warn "can't close filename: $!";
	#
	NMIS::setFileProt($file); # set file owner/permission, default: nmis, 0775
}

sub loadCSVHeaders {
	my $file = shift;
	my $seperator = shift;
	
	if ( $seperator eq "" ) { $seperator = "\t"; }

	my $i;
	my @headers;

	sysopen(DATAFILE, "$file", O_RDONLY) or warn "Cannot open $file";
	flock(DATAFILE, LOCK_SH) or warn "can't lock filename: $!";
	LINE: while (<DATAFILE>) {
		chomp;
		# If it is the first pass load the column headers into an array
		if ( $_ !~ /^#|^;|^\n/ ) {
			$_ =~ s/\"//g;
			@headers = split(/$seperator/, $_);
			last LINE;
		}
	}
	close (DATAFILE) or warn "can't close filename: $!";
	return (@headers);
}

# just write the headers out - so the file can be added to later...
sub writeCSVHeaders {
	# MUST BE CALLED WITH &writeCSVHeaders
	my $seperator = pop;
	my $file = pop;
	my @line = @_;
	my $key;
	my $head;
	my $string;
	my $i;

	# change to secure sysopen with truncate after we got the lock
	sysopen(OUT, "$file", O_WRONLY | O_CREAT) or warn "Couldn't open file $file for writing. $!";
	flock(OUT, LOCK_EX) or warn "can't lock filename: $!";
	truncate(OUT, 0) or warn "can't truncate filename: $!";

	$string = join($seperator,@line);
	#Handy for debug
	#print "HEAD: $string\n";
	print OUT "# THE FIRST LINE NON COMMENT IS THE HEADER LINE AND REQUIRED\n";
	print OUT "$string\n";
	close(OUT) or warn "can't close filename: $!";
	#
	NMIS::setFileProt($file); # set file owner/permission, default: nmis, 0775
}

# this file loads the values into a hash of arrays
# used when the the key would load a set of possibly non-unique records
sub loadCSVarray {
	my $file = shift;
	my $key = shift;
	my $seperator = shift;
	my $reckey;
	my $line = 1;
	
	if ( $seperator eq "" ) { $seperator = "\t"; }

	my $passCounter = 0;

	my $i;
	my @rowElements;
	my @headers;
	my %headersHash;
	my @keylist;
	my $row;
	my $head;
	
	my %data;
	
	sysopen(DATAFILE, "$file", O_RDONLY) or warn "Cannot open $file";
	flock(DATAFILE, LOCK_SH) or warn "can't lock filename: $!";

	while (<DATAFILE>) {
		#$_ =~ s/\n$//g;
		# If it is the first pass load the column headers into an array and a hash.
		if ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter == 0 ) {
			++$passCounter;
			$_ =~ s/\"//g;
			@headers = split(/$seperator|\n/, $_);
			for ( $i = 0; $i <= $#headers; ++$i ) {
				$headersHash{$headers[$i]} = $i;
			}
		}
		elsif ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter > 0 ) {
			$_ =~ s/\"//g;
			@rowElements = split(/$seperator|\n/, $_);
			if ( $key =~ /:/ ) {
				$reckey = "";
				@keylist = split(":",$key);
				for ($i = 0; $i <= $#keylist; ++$i) {
					$reckey = $reckey.lc("$rowElements[$headersHash{$keylist[$i]}]");
					if ( $i < $#keylist )  { $reckey = $reckey."_" }
				}
			}
			else {
				$reckey = lc("$rowElements[$headersHash{$key}]");
			}
			if ( $#headers > 0 and $#headers != $#rowElements ) {
				$head = $#headers + 1;
				$row = $#rowElements + 1;
				print STDERR "ERROR: $0 in csv.pm: Invalid CSV data file $file; line $line; record \"$reckey\"; $head elements in header; $row elements in data.\n";
			}
			#What if $reckey is blank could form an alternate key?
			if ( $reckey eq "" or $key eq "" ) {
				$reckey = join("-", @rowElements);
			}
			
			for ($i = 0; $i <= $#rowElements; ++$i) {
				if ( $rowElements[$i] eq "null" ) { $rowElements[$i] = ""; }
				# push all values for a keyed list - or hash of arrays.
				push @{ $data{$reckey}{$headers[$i]} }, $rowElements[$i];
			}
		}
		++$line;
	}
	close (DATAFILE) or warn "can't close filename: $!";
	
	return (%data);
}

1;
