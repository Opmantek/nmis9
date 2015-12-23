#!/usr/bin/perl
#
## $Id: grouplist.pl,v 1.2 2012/08/24 05:35:22 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;
use NMIS;

# Variables for command line munging
my %arg = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable();

my @groups = getGroupList();

if ( $arg{patch} ) {
	patchGroupList(\@groups);
}
else {	
	foreach my $group (sort @groups) {
		print "$group\n";
	}
	print "\n";
	
	printGroupList(\@groups);
}

sub patchGroupList {
	my $group_list = shift;
	my $configFile = "/usr/local/nmis8/conf/Config.nmis";
	
	my $CONFIG = readFiletoHash(file => $configFile);
	my $grplist = join(",",@$group_list);

	$CONFIG->{'system'}{'group_list'} = $grplist;
	
	writeHashtoFile(file => $configFile, data => $CONFIG);
}

sub printGroupList {
	my $group_list = shift;
	my $grplist = join(",",@$group_list);
	print "The following is the list of groups for the NMIS Config file Config.nmis\n";
	print "'group_list' => '$grplist',\n";
}

sub getGroupList {
	my @groups;
	my $nodes = loadNodeTable();

	foreach my $node (keys %$nodes) {
		my $group = $nodes->{$node}{group};
		if ( not grep {$group eq $_} @groups ) { 
			push(@groups,$group); 
		}
	}

	return @groups;
}

