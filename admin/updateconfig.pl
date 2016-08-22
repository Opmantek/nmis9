#!/usr/bin/perl
#
## $Id: updateconfig.pl,v 1.6 2012/08/27 21:59:11 keiths Exp $
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
our $VERSION="1.1.0";
use strict;
use File::Basename;

use FindBin;
use lib "$FindBin::Bin/../lib";

use func;

my ($template, $live) = @ARGV;
if (!$template or !-f $template or !$live or !-f $live)
{
	my $me = basename($0);
	
	die "Usage: $me <install template> <live config>
e.g. $me /usr/local/nmis8/install/Config.nmis /usr/local/nmis8/conf/Config.nmis

This script updates your current NMIS Config with new config entries
based on the NMIS install \"template\". Only missing entries are added.\n\n";
}

# load the live config or the results will be messy wrt perms
my $current = loadConfTable();

my $templateconf = readFiletoHash(file => $template);
my $liveconf = readFiletoHash(file => $live);

die "Invalid template config!\n" if (ref($templateconf) ne "HASH"
																						or !keys %$templateconf);

die "Invalid live config!\n" if (ref($liveconf) ne "HASH"
																 or !keys %$liveconf);

my @added;

# attention: this covers ONLY TWO LEVELS of indirection!
for my $section (sort keys %$templateconf)
{
	for my $item (sort keys %{$templateconf->{$section}})
	{
		next if (exists $liveconf->{$section}->{$item}); # undef is fine, only interested in MISSING
		print "Updating missing $section/$item\n";

		$liveconf->{$section}->{$item} =  $templateconf->{$section}->{$item};
		push @added, [ $section, $item];
	}
}
if (@added)
{
	writeHashtoFile(file=>$live, data=>$liveconf);
	
	print "\nItems added to Live Config:\n";
	for (@added)
	{
		my ($section, $item) = @$_;
		my $value = $liveconf->{$section}->{$item};
		
		print "  $section/$item=". (defined($value)?
																$value =~ /\s+/ || $value eq ""? "'$value'": 
																$value : "undef"). "\n";
	}
}
else
{
	print "Found no items to add to Live Config.\n";
}
exit 0;

