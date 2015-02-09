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

package Notify::critical;
our $VERSION = "1.1.0";

require 5;

use strict;
use notify;
use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use Data::Dumper;


@ISA = qw(Exporter);

@EXPORT = qw(
		critical
	);

@EXPORT_OK = qw(	);

sub sendNotification {
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $subject = "Critical Interface Notification";
	my $priority = $arg{priority};

	my $C = $arg{C};

	# add the time now to the event data.
	$event->{time} = time;
	$event->{email} = $contact->{Email};
	$event->{mobile} = $contact->{Mobile};
	
	print STDERR "Notify::critical checking event....\n" if $C->{debug};
	if ( $event->{event} =~ /Interface Down|Interface Up/ && $event->{details} =~ /CRITICAL/ ) 
	{
		print STDERR "Notify::critical Sending critical email to $contact->{Email}\n" if $C->{debug};

		my ($status, $code, $errmsg) = sendEmail(
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
			print STDERR "Notify::critical Sending Sending email to $contact->{Email} failed: $code $errmsg\n" 
					if $C->{debug};
		}
		else
		{
			print STDERR "Notify::critical Notification to $contact->{Email} sent successfully\n" if $C->{debug};
		}
	}
}


# Sample Contact
	#$contact = {
	#  'Contact' => 'keiths',
	#  'DutyTime' => '06:24:MonTueWedThuFri',
	#  'Email' => 'keiths@opmantek.com',
	#  'Location' => 'default',
	#  'Mobile' => '0433355840',
	#  'Pager' => '',
	#  'Phone' => '',
	#  'TimeZone' => 0
	#};
	
	# Sample Event
	#$event = {
	#  'ack' => 'false',
	#  'businessPriority' => undef,
	#  'businessService' => undef,
	#  'cmdbType' => undef,
	#  'current' => 'true',
	#  'customer' => 'PACK',
	#  'details' => 'SNMP error',
	#  'element' => '',
	#  'email' => 'keiths@opmantek.com',
	#  'escalate' => 0,
	#  'event' => 'SNMP Down',
	#  'geocode' => 'St Louis Misouri',
	#  'level' => 'Warning',
	#  'location' => 'Cloud',
	#  'mobile' => '0433355840',
	#  'nmis_server' => 'nmisdev64',
	#  'node' => 'branch1',
	#  'notify' => 'syslog:server,json:server,mylog:keiths,mylog:keith2',
	#  'serviceStatus' => 'Dev-Test',
	#  'startdate' => 1366603124,
	#  'statusPriority' => '3',
	#  'supportGroup' => undef,
	#  'time' => 1366603126,
	#  'uuid' => '59A29034-8D41-11E2-A990-F38D7588D2EB'
	#};

1;
