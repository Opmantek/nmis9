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
# Intentionally left distant from NMIS Code, as we want it to run 
# really fast with minimal use statements.
#
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Socket;

my $trapfilter = qr/foobardiddly/;

# allow a logfile to be explicitely specified as first/only argument, 
# but fall back to the 'usual' location
my $filename = $ARGV[0] || "$FindBin::Bin/../logs/trap.log";

# snmptrapd feeds us, one per line, this: the hostname and 'ip
# address' of the sending party, and the var bindings in the form of
# oid space value.
# 
# note that: the ip address is not just the raw ip address, but a
# connection string of the form 'UDP: [1.2.3.4]:33608->[5.6.7.8]',
# where 1.2.3.4 is the other party and 5.6.7.8 is this box.
#
# note also that the sending party may NOT be the originator if the
# trap was forwarded, but merely indicates the last hop. it is
# therefore necessary to check the variable
# SNMP-COMMUNITY-MIB::snmpTrapAddress.0 as well, which holds the
# originating agent's address.
# 
my @buffer;
my $hostname = <STDIN>;
my $ipaddress = <STDIN>;

chomp ($hostname, $ipaddress);

# Traps received without DNS PTR are coming as hostname <UNKNOWN>
#2015-04-11T09:32:13	<UNKNOWN>	UDP: [192.168.1.249]:57047->[192.168.1.7]	SNMPv2-MIB::sysUpTime.0=38:13:55:01.68	SNMPv2-MIB::snmpTrapOID.0=CISCO-CONFIG-MAN-MIB::ciscoConfigManEvent	.......
if ( $hostname eq "<UNKNOWN>" and $ipaddress =~ /\[(\d+\.\d+\.\d+\.\d+)\]/ ) {
	$hostname = $1;
}

$hostname = escapeHTML($hostname);
$ipaddress = escapeHTML($ipaddress);

# the remainder is all variables 
while (my $line = <STDIN>) 
{
	chomp $line;
	$line = escapeHTML($line);

	my ($varname,$rest) = split(/\s+/,$line,2); 
  # the one and only variable we're specially interested in: if the trap
	# originator doesn't match what snmptrapd reports, then we replace 
	# the hostname with the trap originator's hostname (if we can find one)
	if ($varname eq "SNMP-COMMUNITY-MIB::snmpTrapAddress.0"
			and $ipaddress !~ /^UDP:\s*\[$rest\]/)
	{
			my $addrbin = inet_aton($rest);
			my $newhostname = gethostbyaddr($addrbin, AF_INET);
			if (defined $newhostname)
			{
					$hostname = $newhostname;
					$ipaddress = $rest;
			}
	}
	push @buffer,"$varname=$rest";
}

my $out = join("\t",$hostname,$ipaddress,@buffer);

if ( $out !~ /$trapfilter/ ) {
		# Open output file for sending stuff to
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

#Function which returns the time
sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my $SEP = "T";
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	# A Y2.07K problem
	if ($year > 70) { $year=$year+1900; }
	else { $year=$year+2000; }
	#Increment Month!
	++$mon;
	if ($mon<10) {$mon = "0$mon";}
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}

	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];

	return "$year-$mon-$mday$SEP$hour:$min:$sec";
}


# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************

