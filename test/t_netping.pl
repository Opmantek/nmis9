#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
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
use Data::UUID;

use NMIS;
use func;
use NMIS::UUID;

my %arg;
my $debug = 1;

use Net::Ping;

my $host = "meatball";
my @host_array = qw(meatball bones asgard);

my $p = Net::Ping->new();

print "$host is alive.\n" if $p->ping($host);
$p->close();

$p = Net::Ping->new("icmp");
#$p->bind($my_addr); # Specify source interface of pings
foreach my $host (@host_array)
{
    print "$host is ";
    print "NOT " unless $p->ping($host, 2);
    print "reachable.\n";
    sleep(1);
}
$p->close();

$p = Net::Ping->new("tcp", 2);
# Try connecting to the www port instead of the echo port
$p->port_number(scalar(getservbyname("http", "tcp")));
my $stop_time = time()-600;
while ($stop_time > time())
{
    print "$host not reachable ", scalar(localtime()), "\n"
        unless $p->ping($host);
    sleep(300);
}
undef($p);

# Like tcp protocol, but with many hosts
$p = Net::Ping->new("syn");
$p->port_number(getservbyname("http", "tcp"));
foreach $host (@host_array) {
	print "SYN PING $host\n";
  $p->ping($host);
}
while (my ($host,$rtt,$ip) = $p->ack) {
  print "HOST: $host [$ip] ACKed in $rtt seconds.\n";
}

# High precision syntax (requires Time::HiRes)
$p = Net::Ping->new();
$p->hires();
my ($ret, $duration, $ip) = $p->ping($host, 5.5);
printf("$host [ip: $ip] is alive (packet return time: %.2f ms)\n", 1000 * $duration)
  if $ret;
$p->close();

# For backward compatibility
print "$host is alive.\n" if pingecho($host);
