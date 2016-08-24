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
package sapi;
our $VERSION = "1.1.0";

use strict;
use vars qw(@ISA @EXPORT);
use Exporter;
use Socket;

use NMIS;

@ISA = qw(Exporter);
@EXPORT = qw(sapi);

sub sapi_connect
{
	my $remote_host    = shift;
	my $remote_port    = shift;
	my $script         = shift;
	my $timeout        = shift;
	my $SH;

	socket($SH, PF_INET, SOCK_STREAM, getprotobyname('tcp')) or return 0,$!;

	my $iaddr = inet_aton($remote_host) or return 0,$!;
	my $paddr = sockaddr_in($remote_port, $iaddr) or return 0,$!;
	connect($SH, $paddr) or return 0,$!;
	# The above three lines could have been combined into one line.
	# They are separated for debuging purposes. Here is the single line:
	# connect($SH, sockaddr_in($remote_port,inet_aton($remote_host))) or return 0,$!

	return 1,$SH;
}

sub sapi_close
{
	my $SH = shift;
	close($SH) or return 0,$!;
	return 1;
}

sub sapi_send
{
	my $SH = shift;
	my $msg = shift;
	my $nonewline = shift;

	defined send($SH,$msg,0) or return 0,$!;
	return 1,undef;
}

sub sapi_recv
{
	my $SH = shift;
	my $timeout = shift || 5;
	my $maxlen = 1048576;  # 1MB
	my($buffer,$recv_code);

	# save and restore any previously set alarm,
	# but don't bother subtracting the time spent here
	my $remaining = alarm(0);
	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };

		alarm($timeout);
		$recv_code = recv($SH, $buffer, $maxlen, 0);
		alarm(0);
	};
	alarm($remaining) if ($remaining);

	if ($@ && $@ eq "timeout")
	{
		return -1,$buffer;
	}
	elsif ($@)
	{
		return 0,"Unexpected sapi_recv exception: $@";
	}

	return 0,$! unless defined $recv_code;
	return -2,undef unless length($buffer);
	return 1,$buffer;
}

sub sapi
{
	my $remote_host    = shift || return 0,"Invalid blank host name";
	my $remote_port    = shift || 23;
	my $script         = shift || return 0,"Invalid script";
	my $timeout        = shift || 5;

	my($ok,$SH) = sapi_connect($remote_host,$remote_port,$script,$timeout);
	return 0,$SH unless $ok;

	my ($result,$msg,$line,$type,$str,$found,$done,$errmsg,$eof);

	$errmsg = "Nothing in script";
	foreach $line (split(/\n/,$script)) {
		next unless $line;
		$errmsg = "";
		($type,$str) = $line =~ /^\s*((?:send|expect))\s*:\s*(.*)$/;

		unless (($type eq "send") or ($type eq "expect")) {
			$msg ="Invalid script command: $line" ;
			last;
		}

		if ($type eq "send") {                                # Send a string
			($ok,$errmsg) = sapi_send($SH,$str."\n");

		} elsif ($str eq "EOF") {                             # Receive data until EOF
			$eof = 0;
			while (!$eof and !$errmsg) {
				($ok,$msg) = sapi_recv($SH,$timeout);
				if ($ok == -2) {                                  # No data received (assume eof)
					$eof = 1;
				} elsif ($ok == -1) {                             # Timeout error
					$errmsg = $msg || 'timeout';
				} elsif ($ok == 1) {                              # Received some data
					$result .= $msg;
				} else {                                          # Other error
					$errmsg = $msg;
				}
			}

		} elsif ($str) {                                      # Receive data until it matches $str or error
			while (!$errmsg and !($result =~ /$str/)) {
				($ok,$msg) = sapi_recv($SH,$timeout);
				if ($ok == 1) {                                   # Received some data
					$result .= $msg;
				} elsif ($ok == -1) {                             # Timeout error
					$errmsg = $msg || 'timeout';
				} elsif ($ok == -2) {                             # No data received (assume error)
					$errmsg = "unexpected EOF";
				} else {                                          # Other error
					$errmsg = $msg;
				}
			}
			$errmsg = "Did not get expected message: ($str) ($ok) $errmsg" unless $result =~ /$str/;

		} else {                                              # Just get some data
			($ok,$msg) = sapi_recv($SH,$timeout);
			if ($ok) {
				$result .= $msg;                                  # All is well
			} else {
				$errmsg = $msg;                                   # Report error
				last;
			}
		}
		last if $errmsg;                                      # Stop on error
	}

	sapi_close($SH);
	return 0,$errmsg . "Partial results (if any):$result" if $errmsg;
	return 1,$result;
}

1;

__END__

Calling API for sapi

 ($ret,$msg) = &sapi($ip,$port,$script,$ScriptTimeout);
 print "Script ",($ret?"Succeeded":"Failed"),"!\n";
 print "Results: ",$msg,"\n";

     ret     = 1 The script executed successfully
             = 0 The script failed (error message in $msg)

     msg     = a string resulting from the script or the error message

     ip      = numeric IP address of the remote host to connect to

     port    = the port number to connect to on the remote host

     script  = the send/expect script to execute (see below)

     timeout = value in seconds to wait until a connection timeout
               error occurs the default value is 5 seconds

Scripts are in the form

  send:   data_to_send
  expect: string_to_match
  send:   more_data_to_send
  expect: another_string_to_match

For example, to see if a HTTP server is responding you might use
the following script:

  send: HEAD / HTTP/1.0
  send:
  expect: 200 OK

All expect values are case-insensitive with the exception of a
special value: EOF which means to wait until an EOF condition occurs.
For example, to query a HTTP server for all header information you
might use the following script:

  send: HEAD / HTTP/1.0
  send:
  expect: EOF

(Note to send a blank line "\n" as in the above example, do not give
send: any value)
