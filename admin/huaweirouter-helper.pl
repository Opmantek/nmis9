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

# This program adjusts the metadata for Huawei devices to support QoS statistics
# on these devices.
# This program should be run from Cron after every NMIS update operation to ensure
# the interface and QoS information is kept in synch.

our $VERSION="1.0.1";
if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
 
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use Data::Dumper;
use rrdfunc;
use notify;

if (@ARGV == 1 && $ARGV[0] =~ /^-?-[h?]/)
{
	die "Usage: $0 [debug=1][info=1] [nodes=nodeA,nodeB,...]\n
info: print diagnostics, debug: print extensive diagnostics
if nodes is set, only those nodes are processed, otherwise
all nodes are checked. note that only active and collecting 
nodes are handled.\n\n";
}

my %arg = getArguements(@ARGV);

# fixme print usage message, debug/info, should add nodes=

# Set debugging level and/or info 
my $debug = setDebug($arg{debug});
my $info = setDebug($arg{info});

my @onlythesenodes = split(/\s*,\s*/, $arg{nodes});
my $C = loadConfTable(conf=>$arg{conf},debug=>$debug);

my $problems;
updateHuaweiRouters();
exit $problems? 1 : 0;

sub updateHuaweiRouters
{
	my $LNT = loadLocalNodeTable();

	foreach my $node (sort keys %{$LNT}) 
	{
		# update all actve+collecting nodes OR just the nodes given explicitely
		next if (@onlythesenodes && !grep($node eq $_, @onlythesenodes));
		next if (!getbool($LNT->{$node}{active}) or !getbool($LNT->{$node}{collect}));
		
		print "Processing $node\n" if $debug or $info;

		my $S = Sys->new;
		$S->init(name=>$node,snmp=>'false');
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;

		if ( $NI->{system}{nodeModel} ne "HuaweiRouter" ) 
		{
			print "Skipping node $node as it is not a HuaweiRouter.\n" if ($debug or $info);
			next;
		}
		
		if (ref($NI->{QualityOfServiceStat}) eq "HASH") 
		{
			# extract direction and interface info from the QoS info
			foreach my $qosIndex ( keys %{$NI->{QualityOfServiceStat}}) 
			{
				my ($ifidx, $interface, $direction);
				#"15.0.1"
				if ( $qosIndex =~ /^(\d+)\.\d+\.(\d+)/ ) {
					($ifidx, $direction) = ($1,$2);
							
					if ( defined $IF->{$ifidx} and $IF->{$ifidx}{ifDescr} ) 
					{
						$interface = $IF->{$ifidx}{ifDescr};
					}
					else
					{
						print "ERROR: QoS index $qosIndex points to nonexistent interface $ifidx!\n";
						++$problems;
						next;
					}
					
					if ( $direction == 1 ) {
						$direction = "inbound"
					}
					elsif ( $direction == 2 ) {
						$direction = "outbound"
					}
					else
					{
						print "ERROR: QoS index $qosIndex has impossible direction value $direction!\n";
						++$problems;
						next;
					}
							
					print "DEBUG: $qosIndex: $direction on interface $ifidx = $interface\n" if $debug or $info;

					# save the metadata
					$NI->{QualityOfServiceStat}{$qosIndex}{Interface} = $interface;
					$NI->{QualityOfServiceStat}{$qosIndex}{ifIndex} = $ifidx;
					$NI->{QualityOfServiceStat}{$qosIndex}{Direction} = $direction; 

					# and add qos to the interface's graphtype
					# fixme is that needed?
					my $short = "cbqos-".($direction eq "inbound" ? "in":"out");
					$NI->{graphtype}->{$ifidx}->{$short} = $short;
				}
			}
				
			# fixme need to check deadlocks!!
			$S->writeNodeInfo; # save node info in file var/$NI->{name}-node	
		}
	}
}


