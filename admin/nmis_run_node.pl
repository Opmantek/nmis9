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
#

use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use File::Basename;
use func;
use NMIS;
use Data::Dumper;

my $bn = basename($0);
my $usage = "Usage: $bn [type=(which type)] field=[what field] match=[regex]

\t$bn type=(what NMIS type to run, e.g collect, update, threshold, etc.)
\t$bn field=(which field in Node Info System)
\t$bn match=(a regex pattern to match)
\t$bn update=(seconds since last update run.)

Some fields in Node Info System:
- group
- nodeVendor
- sysDescr
- nodeModel
- sysObjectName

e.g. $bn field=sysObjectName match=catalyst37xxStack

\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));
my %arg = getArguements(@ARGV);

$arg{type} = "update" if $arg{type} eq "";

if ( $arg{field} eq "" or $arg{match} eq "" ) {
	die $usage;	
}

my $update = $arg{update} ? $arg{update} : 0;

my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $LNT = loadLocalNodeTable();

foreach my $node (sort keys %{$LNT}) {	
	# Is the node active and are we doing stats on it.
	if ( getbool($LNT->{$node}{active}) ) {
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		my $recentUpdate = 0;
		# has an update been run in the last 24 hours?
		if ( $NI->{system}{lastUpdatePoll} > time() - $update ) {
			$recentUpdate = 1;
		}
		
		my $runIt = 0;
		if ( defined $NI->{system}{$arg{field}} and $NI->{system}{$arg{field}} =~ /$arg{match}/ ) {
			print "MATCH $NI->{system}{name}: $arg{field}=$NI->{system}{$arg{field}}\n";
			
			if ( $arg{type} ne "update" or not $update ) {
				$runIt = 1;
			}
			elsif ( $update and $arg{type} eq "update" and not $recentUpdate ) {
				$runIt = 1;
			}
			
			open (NMIS, "$FindBin::Bin/../bin/nmis.pl node=$NI->{system}{name} type=$arg{type} debug=true |") if $runIt;
			
			while(<NMIS>) {
      	print "$_";
			}
		}
		if ( defined $NI->{system}{$arg{field}} and $NI->{system}{$arg{field}} !~ /$arg{match}/ ) {
			print "SKIP No Match: $NI->{system}{name}: $arg{field}=$NI->{system}{$arg{field}}\n";
		}
		if ( not $runIt and $recentUpdate ) {
			print "SKIP Update: $NI->{system}{name}: lastUpdatePoll=$NI->{system}{lastUpdatePoll}\n";
		}
	}
}

