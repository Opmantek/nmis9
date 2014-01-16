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
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use NMIS;
use func;
use File::Basename;
use POSIX;
use Data::Dumper;

# arguments: node=name or group=name, start=hhmm, end=hhmm, comment=text, 
# verbose=0/1
my %a = getArguements(@ARGV);

my $outages = loadTable(dir => "conf", name => "Outage");
my $nodes = loadNodeTable;

die "usage: ".basename($0)
		." {node|group}=name start=HH:MM end=HH:MM [options]
  comment=text: sets comment text for outage
  verbose={0|1}: verbose output\n\n" 
		if (!$a{start} || !$a{end}
				|| !( $a{group} xor $a{node} )
		|| $a{start} !~ /^\d+:\d+$/ || $a{end} !~ /^\d+:\d+$/ );

die "unknown node \"$a{node}\" given, aborting.\n"
		if ($a{node} && !$nodes->{$a{node}});

my @now = localtime;
my @hm = split(/:/, $a{start});

die "start time \"$a{start}\" unparseable\n" 
		if ($hm[0]>=24 || $hm[1]>=60);

my $begtime = POSIX::mktime(0,$hm[1],$hm[0],@now[3..5]);
@hm = split(/:/, $a{end});

die "start time \"$a{start}\" unparseable\n" 
		if ($hm[0]>=24 || $hm[1]>=60);

my $endtime = POSIX::mktime(0,$hm[1],$hm[0],@now[3..5]);

# if the endtime is earlier than the begin, add one day to end
if ( $endtime < $begtime )
{
		$endtime += 86400;
}
# if the time specified is earlier than now, add one day
if ( $begtime < time )
{
		$begtime += 86400;
		$endtime += 86400;
}

my @candidates = $a{node}? ($a{node}) 
		: (grep { $nodes->{$_}->{group} eq $a{group} } keys %{$nodes});

die "group \"$a{group}\" has no members, aborting.\n" if (!@candidates);


print "Outage window is from ".localtime($begtime)." to ".
		localtime($endtime)."\n" if ($a{verbose});

for my $node (@candidates)
{
		$outages->{ join("-",$node,$begtime,$endtime) } = {
		node => $node,
		start => $begtime,
		end => $endtime,
		change => $a{comment} };

		print "Applying to node $node\n" 
				if ($a{verbose});
}

writeTable(dir=> "conf", name => "Outage", data => $outages);
exit 0;

