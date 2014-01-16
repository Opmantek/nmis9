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

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;
use JSON::XS;
use File::Path;

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(
		mylog
	);

@EXPORT_OK = qw(	);

my $dir = "/tmp/mylog";

sub sendNotification {
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	
	if ( not -d $dir ) {
		my $permission = "0770";

		my $umask = umask(0);
		mkpath($dir,{verbose => 0, mode => oct($permission)});
		umask($umask);
	}
	
	# add the time now to the event data.
	$event->{time} = time;

	$event->{email} = $contact->{Email};
	$event->{mobile} = $contact->{Mobile};
	
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
	
	open(LOG,">$file") or logMsg("ERROR, can not write to $file");
	print LOG JSON::XS->new->pretty(1)->encode($mylog);
	close LOG;
	# good to set permissions on file.....
}


1;
