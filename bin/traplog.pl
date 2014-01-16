#!/usr/bin/perl
#
#
## $Id: traplog.pl,v 8.2 2011/08/28 15:10:52 nmisdev Exp $
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
# Intentionally left distant from NMIS Code, as we want it to run 
# really fast with minimal use statements.
#
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";

my $trapfilter = qr/foobardiddly/;

my $filename = "$FindBin::Bin/../logs/trap.log";
# Open STDIN for reading
open(IN,"<&STDIN") || die "Cannot open the file STDIN";

# Start Loop for processing IN file
my @buffer;
while (<IN>) {
	chomp;
	my @spaceParts = split(/\s+/,$_);
	my $pdu;
	if ( $#spaceParts > 1 ) {
		#$_ =~ s/(\s+)/=/g;
		my $p1 = shift(@spaceParts);
		my $p2 = shift(@spaceParts);
		$pdu = "$p1=$p2 @spaceParts";
	}
	else {
		$_ =~ s/\s+/=/g;
		$pdu = $_;
	}
	push(@buffer,$pdu);
}

my $out = join("\t",@buffer);
# Open output file for sending stuff to
open (DATA, ">>$filename") || die "Cannot open the file $ARGV[0]";

if ( $out !~ /$trapfilter/ ) {
	my $out = join("\t",@buffer);
	print DATA &returnDateStamp."\t$out\n";
}
close(DATA);

#Function which returns the time
sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my $SEP = "T";
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	# A Y2.07K problem
	if ($year > 70) { $year=$year+1900; }
	else { $year=$year+2000; }
	#Increment Month!
	++$mon;
	if ($mon<10) {$mon = "0$mon";}
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];

	return "$year-$mon-$mday$SEP$hour:$min:$sec";
}

exit;

# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
