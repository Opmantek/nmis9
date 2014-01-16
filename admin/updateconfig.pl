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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;


print <<EO_TEXT;
This script will update your running NMIS Config based on the NMIS install 
"template".  This will assist with code updates and patches.

The script will ONLY add items in the existing config which are NULL when 
compared to the NMIS Install template.

EO_TEXT

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config files to compare
usage: $0 <CONFIG_1> <CONFIG_2>
eg: $0 /usr/local/nmis8/install/Config.nmis /usr/local/nmis8/conf/Config.nmis

EO_TEXT
	exit 1;
}

print "The NMIS8 install config template is: $ARGV[0]\n";
print "The current NMIS8 config file: $ARGV[1]\n";

my $conf1;
my $conf2; 

# load configuration table
if ( -f $ARGV[0] ) {
	$conf1 = readFiletoHash(file=>$ARGV[0]);
}
else {
	print "ERROR: something wrong with config file 1: $ARGV[0]\n";
	exit 1;
}

if ( -f $ARGV[1] ) {
	$conf2 = readFiletoHash(file=>$ARGV[1]);
}
else {
	print "ERROR: something wrong with config file 2: $ARGV[1]\n";
	exit 1;
}

my %added;

my $confnew = updateConfig("Template","Current",$conf1,$conf2);

writeHashtoFile(file=>$ARGV[1],data=>$confnew);

print "Items Added to Current Config:\n";
foreach my $add (sort keys(%added)) {
	my ($section,$item) = split("--",$add);
	print "  $section/$item=$added{$add}\n";
}

sub updateConfig {
	my $which1 = shift;
	my $which2 = shift;
	my $thing1 = shift;
	my $thing2 = shift;
	
	#Recurse over the first Config Hash and compare results
	print "Using $which1 as the base for comparison\n";
	foreach my $section (sort keys %{$thing1}) {
		#print "  Working on Config Section: $section\n";
		foreach my $item (sort keys %{$thing1->{$section}}) {
			if ( not defined $thing2->{$section}{$item} ) { 
				print "  Null item found: $which1/$section/$item=$thing1->{$section}{$item}\n";
				print "  Adding config item to $which2\n";
				
				$thing2->{$section}{$item} =  $thing1->{$section}{$item};
				
				$added{"$section--$item"} = $thing1->{$section}{$item};
			}
		}
	}
	return($thing2);
}
