#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
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
use strict;
use func;
use File::Basename;
use Getopt::Std;

my $usage="Usage: ".basename($0)." [-q] <CONFIG_1> <CONFIG_2 or dir>
eg: ".basename($0)." /usr/local/nmis8/install/Config.nmis /usr/local/nmis8/conf/

This script compares two NMIS Config files and reports the differences.

If the second argument is a directory, then the relative file name 
from CONFIG_1 will be used inside the CONFIG_2 directory.

Exit code 0: no differences, exit code 1: differences were found, other exit codes: internal failure\n\n";

my %opts;
getopts("q",\%opts) or die $usage;

die($usage) if (@ARGV != 2 or !-f $ARGV[0] or (!-f $ARGV[1] 
																							 and !-d $ARGV[1]));
my ($cf1,$cf2)=@ARGV;

$cf2 .= "/".basename($cf1) if (-d $cf2);
die $usage if (!-f $cf2);

my $c1 = readFiletoHash(file=>$cf1);
die "Error: could not read $cf1: $!\n" if (!$c1);

my $c2 = readFiletoHash(file=>$cf2);
die "Error: could not read $cf2: $!\n" if (!$c2);

print "\nComparing $cf1 to $cf2\n";
print "Output format:\n\n\"Config Key Path:\n-\tStatus in $cf1\n+\tStatus in $cf2\"\n\n" if (!$opts{q});
compare($c1,$c2,"");

my @diffsummary;

# compare deep structures first and second and print differences 
# is called recursive, curpath identifies the location
sub compare
{
		my ($first,$second,$curpath)=@_;

		# either one not defined/missing?
		if (defined $first ^ defined $second)
		{
				my $flabel=defined($first)? ref($first)?"<DEEP STRUCTURE>": $first : "<NOT PRESENT>";
				my $slabel=defined($second)? ref($second)?"<DEEP STRUCTURE>": $second : "<NOT PRESENT>";

				print "$curpath:\n-\t$flabel\n+\t$slabel\n\n";
				push @diffsummary,$curpath;
				return;
		}

		# are the structures of the same type?
		my $ftype=ref($first);
		my $stype=ref($second);

		if ($ftype ne $stype)
		{
				my $flabel = $ftype? "<DEEP STRUCTURE, TYPE $ftype>" : $first;
				my $slabel = $stype? "<DEEP STRUCTURE, TYPE $stype>" : $second;

				print "$curpath:\n-\t$flabel\n+\t$slabel\n\n";
				push @diffsummary,$curpath;
				return;
		}

		# scalars or qr// regexps? compare directly
		if (!$ftype or $ftype eq "Regexp")
		{
				if ($first ne $second)
				{
						print "$curpath:\n-\t$first\n+\t$second\n\n";
						push @diffsummary,$curpath;
						return;
				}
		}
		# array? recursively compare in the same order
		elsif ($ftype eq "ARRAY")
		{
				for my $index (0..($#$first>$#$second?$#$first:$#$second))
				{
						compare($first->[$index],$second->[$index],"$curpath\[$index\]");
				}
		}
		# hash? compare, ignore order
		elsif ($ftype eq "HASH")
		{
				my %allkeys;
				map { $allkeys{$_}=1; } (keys %$first);
				map { $allkeys{$_}=1; } (keys %$second);

				for my $key (keys %allkeys)
				{
						compare($first->{$key},$second->{$key},"$curpath/$key");
				}
		}
		else
		{
				die "Error: unknown data structure at $curpath: first $ftype, second $stype\n\n";
		}
}

if (@diffsummary)
{
		print "Difference Summary:\n\t".join("\n\t",sort @diffsummary)."\n\n";
		exit 1;
}
else
{
		print "No differences found.\n";
		exit 0;
}

