#!/usr/bin/perl
#
#  Copyright 1999-2017 Opmantek Limited (www.opmantek.com)
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
# Intentionally left distant from NMIS Code, as we want it to run
# really fast with minimal use statements.
#
our $VERSION="1.1.0";

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Socket;
use Getopt::Std;
use POSIX qw();

my %options;
getopts("nf:t:", \%options) or die "Usage: $0 [-n] [-f filterregex] [-t targetfile]\n-n: disable dns lookups\-f regex: suppress traps matching this regex\n-t targetfile: write to this file, defualt: ../logs/nmis8/trap.log\n\n";

my $filename = $options{t} || "$FindBin::RealBin/../logs/trap.log";
my $trapfilter = $options{f}? qr/$options{f}/ : undef;

# snmptrapd feeds us, one per line, this: the hostname and 'ip
# address' of the sending party, and the var bindings in the form of
# oid space value.
#
# note that: the ip address is not just the raw ip address, but a
# connection string of the form 'UDP: [1.2.3.4]:33608->[5.6.7.8]',
# where 1.2.3.4 is the other party and 5.6.7.8 is this box.
#
# newer snmptrapd versions (5.7 etc) provide a different connection string,
# with ports included: 'UDP: [192.168.88.253]:50177->[192.168.88.7]:162'
#
# note: with traplogd running with -n (no dns), BOTH hostname and ipaddress lines
# are of the connection string format!
#
# note also that the sending party may NOT be the originator if the
# trap was forwarded, but merely indicates the last hop. it is
# therefore necessary to check the variable
# SNMP-COMMUNITY-MIB::snmpTrapAddress.0 as well, which holds the
# originating agent's address.

my @buffer;
my $hostname = <STDIN>;
my $ipaddress = <STDIN>;

chomp ($hostname, $ipaddress);

# Traps received without DNS PTR can come in as hostname <UNKNOWN>
# 2015-04-11T09:32:13	<UNKNOWN>	UDP: [192.168.1.249]:57047->[192.168.1.7]	SNMPv2-MIB::sysUpTime.0=38:13:55:01.68	SNMPv2-MIB::snmpTrapOID.0=...
# furthermore, traps received with -n are coming in with both hostname
# and ipaddress set to the 'connection string'

if ( ($hostname eq "<UNKNOWN>" or $hostname =~ /^UDP:\s*/ )
		 and $ipaddress =~ /^UDP:\s*\[(\d+\.\d+\.\d+\.\d+)\]/ )
{
	my $addr = $hostname = $1;		# address is better than raw string
	my $newhostname = ($options{n}? undef : gethostbyaddr(inet_aton($addr),
																												AF_INET));
	if (defined $newhostname)
	{
		$hostname = $newhostname;
		$ipaddress = $addr;
	}
}

# the remainder is all variables
while (my $line = <STDIN>)
{
	chomp $line;
	$line = escapeHTML($line);

	my ($varname,$rest) = split(/\s+/,$line,2);
  # the one and only variable we're specially interested in: if the trap
	# originator address doesn't match what snmptrapd reported as address,
	# then we replace the address and the hostname with the trap originator's
	# hostname (if we can find one)
	if ($varname eq "SNMP-COMMUNITY-MIB::snmpTrapAddress.0"
			and $ipaddress !~ /^(UDP:\s*\[$rest\].+|$rest$)/)
	{
		my $addrbin = inet_aton($rest);
		$hostname = $rest;					# hostname being ip address is better than nothing
		my $newhostname = ($options{n}? undef : gethostbyaddr($addrbin, AF_INET));
		if (defined $newhostname)
		{
			$hostname = $newhostname;
			$ipaddress = $rest;
		}
	}
	push @buffer,"$varname=$rest";
}

$hostname = escapeHTML($hostname);
$ipaddress = escapeHTML($ipaddress);

my $out = join("\t",$hostname,$ipaddress,@buffer);

# save the output if it's not filtered
if ( !defined($trapfilter) || $out !~ $trapfilter )
{
	open (DATA, ">>$filename") || die "Cannot open the file $filename: $!\n";
	print DATA &returnDateStamp."\t$out\n";
	close(DATA);
}

exit 0;

# escape the problematic html meta chars in the input.
# note that this escapes FEWER chars than CGI's escapeHTML does,
# e.g. it does NOT replace " with the quot entity.
sub escapeHTML
{
	my ($input) = @_;

	return $input if !defined($input);
	$input =~ s{&}{&amp;}gso;
	$input =~ s{<}{&lt;}gso;
	$input =~ s{>}{&gt;}gso;

	return $input;
}

# Function which returns the time, iso8601-formatted, NON-locale-capable
sub returnDateStamp
{
	my $time = shift;
	$time ||= time;

	return POSIX::strftime("%Y-%m-%dT%H:%M:%S", localtime($time));
}


# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
