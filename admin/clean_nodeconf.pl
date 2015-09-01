#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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
use NMIS;
use Sys;
use NMIS::Timing;
use Data::Dumper;
use Net::SNMP; 

# Variables for command line munging
my %arg = getArguements(@ARGV);

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will load nodeConf data and remove bad Node entries.

usage: $0 run=(true|false) clean=(true|false)
eg: $0 run=true (will run in test mode)
or: $0 run=true clean=true (will run in clean mode)

EO_TEXT
	exit 1;
}


my $debug = setDebug($arg{debug});

my $t = NMIS::Timing->new();
print $t->elapTime(). " Begin\n" if $debug;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $arg{run} eq "true" ) {
	cleanNodeConf();
}

print $t->elapTime(). " End\n" if $debug;


sub cleanNodeConf 
{
	my $LNT = loadLocalNodeTable();
	my ($errmsg, $overrides) = get_nodeconf();
	print "Error: $errmsg\n" if ($errmsg);
	$overrides ||= {};
	
	foreach my $node (keys %{$overrides}) 
	{
		if ( not defined $LNT->{$node}{name} ) 
		{
			print "NodeConf entry found for $node, but nothing in Local Node Table\n";
			if ( $arg{clean} eq "true" ) 
			{
				$errmsg = update_nodeconf(node => $node, data => undef);
				print "Error: $errmsg\n" if ($errmsg);
			}
		}
		# check interface entries.
		else 
		{
			my $mustupdate;
					
			foreach my $ifDescr (keys %{$overrides->{$node}}) 
			{
				next if (ref($overrides->{$node}->{$ifDescr}) ne "HASH"); # the various plain entries

				my $thisintfover = $overrides->{$node}->{$ifDescr};

				my $noDescr = 1;
				my $noSpeedIn = 1;
				my $noSpeedOut = 1;
				my $noCollect = 1;
				my $noEvent = 1;
				
				if ( $thisintfover->{ifDescr} ne "" and $thisintfover->{Description} ne "" ) {
					$noDescr = 0;
				}
	
				if ( $thisintfover->{ifDescr} ne "" and $thisintfover->{collect} ne "" ) {
					$noCollect = 0;
				}
				
				if ( $thisintfover->{ifDescr} ne "" and $thisintfover->{event} ne "" ) {
					$noEvent = 0;
				}
	
				if ( $thisintfover->{ifDescr} ne "" and $thisintfover->{ifSpeedIn} ne "" ) {
					$noSpeedIn = 0;
				}
	
				if ( $thisintfover->{ifDescr} ne "" and $thisintfover->{ifSpeedOut} ne "" ) {
					$noSpeedOut = 0;
				}
	
				# if this interface has no other properties, then get rid of it.
				if ( $noDescr and $noCollect and $noEvent and $noSpeedIn and $noSpeedOut ) 
				{
					print "Deleting redundant entry for $thisintfover->{ifDescr}\n";
					delete $overrides->{$node}->{$ifDescr};
					$mustupdate = 1;
				}
			}

			# now save/update/delete the nodeconf entry
			if (getbool($arg{clean}) and $mustupdate)
			{
				print "Saving nodeconf for $node\n";
				my $errmsg = update_nodeconf(node => $node, data => $overrides->{$node});
				print "ERROR $errmsg\n" if ($errmsg);
			}
		}
	}
}

