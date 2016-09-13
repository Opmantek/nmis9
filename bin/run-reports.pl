#!/usr/bin/perl
#
## $Id: run-reports.pl,v 8.1 2013/01/03 07:42:50 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use Time::Local;

# first argument: when, one of day week month
my $date = lc $ARGV[0];
# second: report type or 'all'
my $report = lc $ARGV[1];
# third, optional NMIS Conf
my $conf = $ARGV[2];

my $usage = "Usage: $0 (day|week|month) (all|times|health|top10|outage|response|avail|port)\n\n";

if ($date !~ /^(day|week|month)$/) 
{
	die "Unknown date=$date selected\n$usage\n";
}

if ($report !~ /^(all|times|health|top10|outage|response|avail|port)$/) 
{
	
	die "Unknown report=$report selected\n$usage\n";
}

my $C = loadConfTable(conf=>$conf);
die "Failed to read configuration!\n" if (ref($C) ne "HASH" or !keys %$C);

my $reportdir = $C->{report_root};

my ($start, $end, $outfile);
my $time = time();

# attention: the file naming logic here must match purge_files() in cgi-bin/reports.pl,
# or unwanted ancient reports will be left behind!
if ($date eq 'day') 
{
	my ($s,$m,$h) = (localtime($time))[0..2];
	$end = $time-($s+($m*60)+($h*60*60));
	$start = $end - (60*60*24); # yesterday

	my ($d,$m,$y,$w) = (localtime($start))[3..6];
	my $wd = ('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$w];
	$outfile=sprintf("day-%02d-%02d-%04d-%s.html",$d,$m+1,$y+1900,$wd);

} elsif ($date eq 'week') {
	my ($s,$m,$h,$wd) = (localtime($time))[0..2,6];
	$end = $time-($s+($m*60)+($h*60*60)+($wd*60*60*24));
	$start = $end - (60*60*24*7); # last weekend
	my ($d,$m,$y,$w) = (localtime($start))[3..6];
	my $wd = ('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$w];
	$outfile=sprintf("week-%02d-%02d-%04d-%s.html",$d,$m+1,$y+1900,$wd);

} elsif ($date eq 'month') {
	my ($m,$y) = (localtime($time))[4,5];
	$end = timelocal(0,0,0,1,$m,$y);
	$m -= 1;
	if ($m < 0) {
		$m = 11; $y -= 1;
	}
	$start = timelocal(0,0,0,1,$m,$y);
	my ($d,$m,$y,$w) = (localtime($start))[3..6];
	$outfile=sprintf("month-%02d-%04d.html",$m+1,$y+1900);
} else {
	# unreachable
	exit 1;
}

my @todos = ($report eq "all"? (qw(times health top10 outage response avail port)) : $report);
for my $thisreport (@todos)
{
	my $file = "$reportdir/${thisreport}-${outfile}";

	my $status = system("$C->{'<nmis_cgi>'}/reports.pl", "conf=$conf", "report=$thisreport",
											"start=$start", "end=$end", "outfile=$file");
	logMsg("ERROR (report) generating report=$thisreport file=$file: $!") if ($status);
	setFileProt($file) if (-f $file);
}

exit 0;

