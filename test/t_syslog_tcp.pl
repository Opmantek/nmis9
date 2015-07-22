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
use func;
use NMIS;
use NMIS::Timing;
use NMIS::Connect;
use Sys::Syslog 0.33;						# older versions have problems with custom ports and tcp
use Sys::Hostname;							# for sys::syslog
use File::Basename;

#server = localhost:udp:514
my $server = "192.168.1.41";
my $protocol = "tcp";
my $port = 514;
my $facility = "local1";
my $priority = 'notice';
my $message = "This is testing TCP SYSLOG";

# don't bother waiting, especially not with udp
# sys::syslog has a silly bug: host option is overwritten by "path" for udp and tcp :-/
Sys::Syslog::setlogsock({type => $protocol, host => $server,
												 path => $server, 
												 port => $port, timeout => 0});
# this creates an rfc3156-compliant hostname + command[pid]: header
# note that sys::syslog doesn't fully support rfc5424, as it doesn't
# create a version part.
# the nofatal option would be for not bothering with send failures, but doesn't quite work :-(
eval { openlog(hostname." ".basename($0), "ndelay,pid", $facility); };
if (!$@)
{
	eval { syslog($priority, $message); };
	if ($@)
	{
		print("ERROR: could not send message to syslog server \"$server\", $protocol port $port!\n");
	}
	else {
		print("SUCCESS: connected to server and sent \"$message\" to $server:$port\n");
	}
	closelog;
}
else
{
	print("ERROR: could not connect to syslog server \"$server\", $protocol port $port!\n");
}
# reset to defaults, for future use
Sys::Syslog::setlogsock([qw(native tcp udp unix pipe stream console)]); 			
