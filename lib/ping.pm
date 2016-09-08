#
## $Id: ping.pm,v 8.2 2011/08/28 15:11:05 nmisdev Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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
package ping;
our $VERSION = "1.2.0";

use strict;
use POSIX ':signal_h';

use vars qw(@ISA @EXPORT);
use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(ext_ping);

use NMIS;
use func;

# ping host retrieve and return min, avg, max round trip time
# relying on finding a standard ping in PATH.
# Try to not be platform specific if at all possible.
#
sub ext_ping
{
	my($host, $length, $count, $timeout) = @_;
	my(%ping, $ping_output, $redirect_stderr, $pid, %pt);
	my($alarm_exists);

	my $C = loadConfTable(); # load config from cache

	$timeout ||= 3;
	$count ||= 3;
	$length ||= 56;

	# List of known ping programs, key is lc(os)
	%ping = (
		'mswin32' =>	"ping -l $length -n $count -w $timeout $host",
		'aix'	=>	"/etc/ping $host $length $count",
		'bsdos'	=>	"/bin/ping -s $length -c $count $host",
		'darwin' =>	"/sbin/ping -s $length -c $count $host",
		'freebsd' =>	"/sbin/ping -s $length -c $count $host",
		'hpux'	=>	"/etc/ping $host $length $count",
		'irix'	=>	"/usr/etc/ping -c $count -s $length $host",
		'linux'	=>	"/bin/ping -c $count -s $length $host",
		'suse'	=>	"/bin/ping -c $count -s $length -w $timeout $host",
		'netbsd' =>	"/sbin/ping -s $length -c $count $host",
		'openbsd' =>	"/sbin/ping -s $length -c $count $host",
		'os2' =>	"ping $host $length $count",
		'os/2' =>	"ping $host $length $count",
		'dec_osf'=>	"/sbin/ping -s $length -c $count $host",
		'solaris' =>	"/usr/sbin/ping -s $host $length $count",
		'sunos'	=>	"/usr/etc/ping -s $host $length $count",
			);

	# get kernel name for finding the appropriate ping cmd
	my $kernel = lc($C->{os_kernelname} || $^O);

	unless (defined($ping{$kernel}))
	{
		logMsg("FATAL: Not yet configured for >$kernel<");
		exit(1);										# fixme: should this really kill nmis?
	}

	# windows 95/98 does not support stderr redirection...
	# also OS/2 users reported problems with stderr redirection...
	$redirect_stderr = $kernel =~ /^(MSWin32|os2|OS\/2)$/i ? "" : "2>&1";

	# initialize return values
	$pt{loss} = 100;
	$pt{min} = $pt{avg} = $pt{max} = undef;
	dbg("ext_ping: $ping{$kernel}",4);

	# save and restore any previously set alarm,
	# but don't bother subtracting the time spent here
	my $remaining = alarm(0);
	eval
	{
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm ($timeout*$count);		# make sure alarm timer is ping count * ping timeout - assuming default ping wait is 1 sec.!

		# read and timeout ping() if it takes too long...
		unless ($pid = open(PING, "$ping{$kernel} $redirect_stderr |"))
		{
			die("\t ext_ping: FATAL: Can't open $ping{$kernel}: $!\n");
		}
		while (<PING>)
		{
			$ping_output .= $_;
		}
		alarm 0;
	};

	if ($@)
	{
		die unless $@ eq "alarm\n";	# propagate unexpected errors
		# timed out: kill child
		kill $pid;
		close(PING);

		# ... and set return values to dead values
		if ($C->{debug}>2) {
			$_ = $ping_output;
			s/\n/\n\t\t/g;
			dbg("ERROR: external ping hit timeout $timeout, assuming target $host is unreachable");
			if ($C->{debug}>3) {
				dbg("INFO: The output of the ping command $ping{$^O} was:");
				dbg("\t$_");
			}
		}
		return($pt{min}, $pt{avg}, $pt{max}, $pt{loss});
	}
	# didn't time out, analyse ping output.
	close(PING);

	# restore previously running alarm
	alarm($remaining) if ($remaining);

	if ($C->{debug}>2)
	{
		$_ = $ping_output;
		s/\n/\n\t\t/g;
		dbg("\t$_");
	}

	# try to find round trip times
	if ($ping_output =~ m@(?:round-trip|rtt)(?:\s+\(ms\))?\s+min/avg/max(?:/(?:m|std)-?dev)?\s+=\s+(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)@m) {
		$pt{min} = $1; $pt{avg} = $2; $pt{max} = $3;
		}
	elsif ($ping_output =~ m@^\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms\s+$@m) {
		# this should catch most windows locales
		$pt{min} = $1; $pt{avg} = $3; $pt{max} = $2;
		}
	else {
		if ($C->{debug}>2) {
			$_ = $ping_output;
			s/\n/\n\t\t/g;
			dbg("ERROR: Could not find ping summary for $host");
			dbg("INFO: The output of the ping command $ping{$^O} was:");
			dbg("\t$_");
			}
		}

	# try to find packet loss
	if ($ping_output =~ m@(\d+)% packet loss$@m) {
		# Unix
		$pt{loss} = $1;
		}
		elsif ($ping_output =~ m@(\d+)% (?:packet )?loss,@m) {
		# RH9 and RH9 ES - ugh !
		$pt{loss} = $1;
		}
	elsif ($ping_output =~ m@\(perte\s+(\d+)%\),\s+$@m) {
		# Windows french locale
		$pt{loss} = $1;
		}
	elsif ($ping_output =~ m@\((\d+)%\s+(?:loss|perdidos)\),\s+$@m) {
		# Windows portugesee, spanish locale
		$pt{loss} = $1;
		}
	else {
		if ($C->{debug}>2) {
			$_ = $ping_output;
			s/\n/\n\t\t/g;
			dbg("ERROR: Could not find packet loss summary for $host");;
			dbg("INFO: The output of the ping command $ping{$^O} was:");
			dbg("\t$_");
			}
		}

	dbg("result returning min=$pt{min}, avg=$pt{avg}, max=$pt{max}, loss=$pt{loss}",3);

	return($pt{min}, $pt{avg}, $pt{max}, $pt{loss});
}

1;
