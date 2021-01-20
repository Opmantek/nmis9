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
package Notify::mylog;
use strict;

our $VERSION = "2.0.0";

use JSON::XS;
use File::Path;
use Carp;

my $dir = "/tmp/mylog";

sub sendNotification
{
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};

	my $nmisng = $arg{nmisng};
	my $C = $arg{C};

	#confess("NMISNG argument required!") if (ref($nmisng) ne "NMISNG");
	#my $C = $nmisng->config;

	if ( not -d $dir )
	{
		my $permission = "0770";

		my $umask = umask(0);
		mkpath($dir,{verbose => 0, mode => oct($permission)});
		umask($umask);
	}

	# add the time now to the event data.
	$event->{time} = time;

	$event->{email} = $contact->{Email};
	$event->{mobile} = $contact->{Mobile};


	my $fcount = 1;
	my $file ="$dir/$event->{startdate}-$fcount.json";
	while ( -f $file ) {
		++$fcount;
		$file ="$dir/$event->{startdate}-$fcount.json";
	}

	my $mylog;
	$mylog->{contact} = $contact;
	$mylog->{event} = $event;
	$mylog->{message} = $message;

	open(LOG,">$file") or $nmisng->log->error("Notify::mylog can not write to $file: $!");
	#print LOG JSON::XS->new->pretty(1)->utf8(1)->encode($mylog);
	#JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode
	print LOG JSON::XS->new->pretty(1)->allow_blessed(1)->convert_blessed(1)->utf8->encode($mylog);
	close LOG;
	# good to set permissions on file.....
}


1;
