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
package NMISNG::Notify::critical;
our $VERSION = "2.0.0";

use strict;

use Data::Dumper;
use Carp;
use NMISNG::Notify;

sub sendNotification
{
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $subject = "Critical Interface Notification";
	my $priority = $arg{priority};

	my $nmisng = $arg{nmisng};
	confess("NMISNG argument required!") if (ref($nmisng) ne "NMISNG");
	my $C = $nmisng->config;

	# add the time now to the event data.
	$event->{time} = time;
	$event->{email} = $contact->{Email};
	$event->{mobile} = $contact->{Mobile};

	$nmisng->log->debug2("Notify::critical checking event....");
	if ( $event->{event} =~ /Interface Down|Interface Up/ && $event->{details} =~ /CRITICAL/ )
	{
		$nmisng->log->debug("Notify::critical Sending critical email to $contact->{Email}");

		my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
			# params for connection and sending
			sender => $C->{mail_from},
			recipients => [$contact->{Email}],

			mailserver => $C->{mail_server},
			serverport => $C->{mail_server_port},
			hello => $C->{mail_domain},
			usetls => $C->{mail_use_tls},

			username => $C->{mail_user},
			password => $C->{mail_password},

			# and params for making the message on the go
			to => $contact->{Email},
			from => $C->{mail_from},
			subject => $subject,
			body => $message,
			priority => $priority,
				);

		if (!$status)
		{
			$nmisng->log->error("Notify::critical Sending Sending email to $contact->{Email} failed: $code $errmsg");
		}
		else
		{
			$nmisng->log->debug("Notify::critical Notification to $contact->{Email} sent successfully");
		}
	}
}

1;
