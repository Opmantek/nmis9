#!/usr/bin/perl
#
#  Copyright 1999-2015 Opmantek Limited (www.opmantek.com)
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
# *****************************************************************************
# this small helper enforces DS minima and maxima by dumping and restoring 
# rrd files if the data contains spikes that exceed the set limits
# meant primarily for interface counters, but should work for any RRD.

our $VERSION = "1.1.1";
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use File::Basename;
use File::Find;
use Data::Dumper;
use Cwd;

use func;
use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";
use RRDs 1.000.490;

die "Usage: ".basename($0). " [examine=N] [dir=/some/dir] [change=false] [precise=true] [match=regex]\n
examine: check last N days for values outside of min/max. default 30.
dir: dir to cover (incl. subdirs). default is NMIS database dir.
change: no changes are made if change isn't 'true'.
precise: update RRDs only if values outside of min/max are found (default true)
 if set to false, ALL RRD files will be updated.
match: regex to select only particular RRD files, e.g. match=pkts_hc
or match=interface/\n\n"
		if (@ARGV == 1 && $ARGV[0] =~ /^(help|--?h(elp)?|--?\?)$/);

print basename($0)." $VERSION starting up.\n\n";

# arguments: directory (limit to there and below),
# match: regex of file names to cover
# change: true/false, only check and print files to deal with if change is off
# examine: how many days of data to examine for finding min/max, defaults to 30
# and the usual conf and debug
my %ARG = getArguements(@ARGV);
my $C = loadConfTable(conf=>$ARG{conf}, debug=>$ARG{debug});

my $onlythese = $ARG{match}? qr/$ARG{match}/ : qr/.*/;
my $dochange = getbool($ARG{change});

my $examine = $ARG{examine} || 30;
$examine *= 86400;
$examine = int($examine);

my $dir = $ARG{dir}? Cwd::abs_path($ARG{dir}) : $C->{database_root};
die "cannot operate on $dir, not a directory or not readable!\n" if (!-d $dir 
																																		 or !-x $dir 
																																		 or !-r $dir);
my @candidates;
find({ follow => 1, wanted => sub 
			 { 
				 my ($full,$relative) = ($File::Find::name, $_);
				 push (@candidates, $full)
						 if (-f $full and $full =~ $onlythese and $relative =~ /\.rrd$/i);
			 }
		 }, $dir);


for my $fn (@candidates)
{
	my $relname = $fn;
	$relname =~ s/^$dir//;
	print "checking RRD $relname\n";

	# get the info, check if min and max are set
	my $rrdinfo = RRDs::info($fn);
	
	my (%ds, $needsrework);
	for my $key (keys %$rrdinfo)
	{
		if ($key =~ /^ds\[(.+)\]\.(min|max)$/)
		{
			my ($dsname, $limittype) = ($1,$2);
			if ($rrdinfo->{$key}) 					# a limit is set; blank is for U/unlimited/NaN
			{
				$ds{$dsname}->{$limittype} = $rrdinfo->{$key};
			}
		}
	}
	
	if (!keys %ds)
	{
		print "RRD has no min/max settings at all, skipping.\n\n";
		next;
	}

	my $rrdstep = $rrdinfo->{step};
	$rrdstep ||= 300;
	my $precise = $ARG{precise}? getbool($ARG{precise}): 1;

	if ($precise)
	{
		my $now = time;
		$now = $now - ($now % $rrdstep);
		my ($begin,$step,$names,$data) = RRDs::fetch($fn, "AVERAGE", "--start" => $now-$examine, "--end" => $now);
		print "Warning: RRD has step $rrdstep, but fetch returned step $step.\n" if ($step != $rrdstep);
		
		
	ROWS:
		for my $row (@$data)
		{
			for my $idx (0..$#{$row})
			{
				my $thisdsname = $names->[$idx];
				my $value = sprintf("%f", $row->[$idx]);
				
				if (defined($ds{$thisdsname}->{max}) and $value > $ds{$thisdsname}->{max})
				{
					print "$thisdsname has value above max ($value > ".$ds{$thisdsname}->{max}."), needs rework\n";
					$needsrework = 1;
					last ROWS;
				}
				if (defined($ds{$thisdsname}->{min}) and $value < $ds{$thisdsname}->{min})
				{
					print "$thisdsname has value below min ($value < ".$ds{$thisdsname}->{min}."), needs rework\n";
					$needsrework = 1;
					last ROWS;
				}
			}
		}
	}
	else
	{
		$needsrework = 1;
	}

	if ($needsrework)
	{
		if (!$dochange)
		{
			print "File $relname needs updating, but in simulation mode! Rerun with change=true!\n\n";
		}
		else
		{
			print "Reworking file $relname\n";

			my $xmlfile = "$fn.xml";
			unlink ($xmlfile) if (-f $xmlfile);
			RRDs::dump($fn, $xmlfile);
			if (my $ERROR = RRDs::error) 
			{
				print "Error: cannot dump $fn to $xmlfile: $ERROR\n\n";
				next;
			}

			die "Error: cannot move $fn to $fn.bak: $!\n"
					if (!rename($fn, $fn.".bak"));

			RRDs::restore("--range-check", $xmlfile, $fn);
			if (my $ERROR = RRDs::error) 
			{
				print "Error: restoring with range check failed: $ERROR\n\n";
				rename("$fn.bak",$fn);	# revert to the old file
				next;										# don't remove the xml file!
			}
			setFileProt($fn);
			unlink($xmlfile, "$fn.bak");

			print "Done with file $relname\n\n";
		}
	}
	else
	{
		print "RRD is ok, has no values outside min/max.\n\n";
	}
}



