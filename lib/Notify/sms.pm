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
package Notify::sms;
use strict;
our $VERSION = "2.0.0";

use Data::Dumper;
use File::Path;
use Notify::wspSMS;
use Carp;

my $smslog = "/usr/local/nmis9/logs/sms.log";

my $debug = 1;

sub sendNotification
{
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};

	my $nmisng = $arg{nmisng};
	confess("NMISNG argument required!") if (ref($nmisng) ne "NMISNG");

	# is this critical.
	if ( $event->{level} =~ /Major|Critical|Fatal/ )
	{
		my $smstime = dateString($event->{startdate});

		my $msgstr = "$event->{node_name} $event->{level} $event->{event} $event->{element} $event->{details}";
		my $message = "$smstime: $msgstr";
		my $to = $contact->{Mobile};
		my $from = "NMIS";

		$from =~ s/\ $//g;
		$from =~ s/\ /+/g;

		$message =~ s/\ $//g;
		$message =~ s/\ /+/g;

		my $exec = "curl http://ntpappsweb0005/wspSMS/WebService.asmx/SendSMS?Message=$message\\&From=$from\\&to=$to";
		my $out = `$exec 2>/dev/null`;

		my $error = 0;
		if ( $out =~ /Bad Request/ ) {
			$error = 1;
		}

		open(LOG,">>$smslog") or $nmisng->log->error("Notify::sms can not write to $smslog: $!");
		print LOG qq|$smstime $to $msgstr\n|;
		print LOG qq|DEBUG: $exec\n| if $debug or $error;
		print LOG qq|DEBUG: $out\n| if $debug or $error;
		close LOG;
		# good to set permissions on file.....
	}
}


#Function which returns the time
sub dateString {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year $hour:$min:$sec";
}

1;
