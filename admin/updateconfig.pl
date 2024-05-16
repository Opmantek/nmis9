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
our $VERSION = "9.4.7";
use strict;
use File::Basename;

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Util;
use Compat::NMIS;								# for nmisng::util::dbg, fixme9

my ($template, $live, $wantdebug) = @ARGV;
if (!$template or !-f $template or !$live)
{
	my $me = basename($0);

	die "Usage: $me <default template> <live config>
e.g. $me /usr/local/nmis9/conf-default/Config.nmis /usr/local/nmis9/conf/Config.nmis

This script updates your current NMIS Config with new config entries
based on the NMIS install \"template\". Only missing entries are added.\n\n";
}

# load the live config or the results will be messy wrt perms
my $current = NMISNG::Util::loadConfTable();

# template must be present, liveconf may be missing and autocreated
my $templateconf = NMISNG::Util::readFiletoHash(file => $template);
my $liveconf = (-f $live)? NMISNG::Util::readFiletoHash(file => $live) : {};

die "Invalid template config!\n" if (ref($templateconf) ne "HASH");
die "Invalid live config!\n" if (ref($liveconf) ne "HASH");

my $havechanges;
updateConfig($templateconf, $liveconf, "", 1, \$havechanges);
if ($havechanges)
{
	NMISNG::Util::writeHashtoFile(file=>$live, data=>$liveconf);
}
else
{
	print "No missing configuration items were detected.\n";
}
exit 0;

# recursively fill in _missing_ things from install into live
# args: install, live - hash ref, loc (textual), further recursion allowed yes/no
# returns: nothing
sub updateConfig
{
	my ($install, $live, $loc, $recurseok, $accum) = @_;

	die "invalid install structure: ".ref($install)."\n"
			if (ref($install) ne "HASH");
	die "invalid live structure: ".ref($live)."\n"
			if (ref($live) ne "HASH");
	die "cannot merge live ".ref($live)
			." and install ".ref($install)
			.", structure mismatch\n" if (ref($live) ne ref($install));

	for my $item (sort keys %$install)
	{
		if (exists($live->{$item}))
		{
			if (ref($install->{$item}) eq "HASH"
					&& ref($live->{$item}) eq "HASH"
					&& $recurseok)
			{
				print "recursing deeper into ${loc}/$item\n" if ($wantdebug);
				updateConfig($install->{$item}, $live->{$item}, "${loc}/$item", $recurseok, $accum);
			}
			else
			{
				print "NOT recursing into ${loc}/$item\n" if (ref($install->{$item}) && $wantdebug);
			}
		}
		else
		{
			print "Adding ${loc}/$item = ".(ref($install->{$item})? "<STRUCTURE>": $install->{$item})."\n";
			$live->{$item} = $install->{$item};
			++$$accum;
		}
	}
	return;
}
