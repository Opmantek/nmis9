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

my $syslog_facility = 'local3';
my $syslog_server = 'localhost:udp:514';

my $extraLogging = 0;

# *****************************************************************************
package Notify::noc;
our $VERSION="1.0.1";

use strict;

use NMISNG::Util;
use NMISNG::Notify;

sub sendNotification 
{
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $C = $arg{C};

	# get syslog config from config file.
	if (NMISNG::Util::existFile(dir=>'conf',name=>'nocSyslog')) {
		# loadtable falls back to conf-default if conf doesn't have the file
		my $syslogConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'nocSyslog');
		$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
		$syslog_server = $syslogConfig->{syslog}{syslog_server};
		$extraLogging = NMISNG::Util::getbool($syslogConfig->{syslog}{extra_logging});
	}

	# get the blacklist from conf/ or conf-default/
	my $blackListFile = "$C->{'<nmis_conf>'}/nocBlackList.txt";
	$blackListFile = $C->{'<nmis_conf_default>'}."/nocBlackList.txt"
			if (!-r $blackListFile);
	
	my @blackList = loadBlackList($blackListFile);
	
	# is there a valid event coming in?
	if ( defined $event->{node_name} and $event->{node_name} ) {
		my $node_name = $event->{node_name};
		
		# is the node in the black list?
		if (not grep { $event->{event} =~ /$_/ } @blackList) { 			
			my $info = 1;
			
			# set this to 1 to include group in the message details, 0 to exclude.
			my $includeGroup = 1;
				
			# the seperator for the details field.
			my $detailSep = " -- ";
				
			NMISNG::Util::dbg("Processing $node_name $event->{event}");
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node_name, snmp=>'false');

			my @detailBits;
		
			if ( $includeGroup ) 
			{
				my $catchall_data = $S->inventory( concept => 'catchall' )->data;
				push(@detailBits, $catchall_data->{group});
			}
	
			push(@detailBits,$event->{details});
			
			my $details = join($detailSep,@detailBits);
		
			#remove dodgy quotes
			$details =~ s/[\"|\']//g;
			
			NMISNG::Util::dbg("sendSyslog $syslog_server $syslog_facility");
		
			my $success = sendSyslog(
				server_string => $syslog_server,
				facility => $syslog_facility,
				nmis_host => $C->{server_name},
				time => time(),
				node => $node_name,
				event => $event->{event},
				level => $event->{level},
				element => $event->{element},
				details => $details
			);
			if ( $success ) {
				NMISNG::Util::logMsg("INFO: syslog sent: $event->{node_name} $event->{event} $event->{element} $details") if $extraLogging;
			}
			else {
				NMISNG::Util::logMsg("ERROR: syslog failed to $syslog_server: $event->{node_name} $event->{event} $event->{element} $details");
			}			
		}
		else {
			NMISNG::Util::logMsg("INFO: event not sent as event in blacklist $event->{node_name} $event->{event} $event->{element}.") if $extraLogging;
		}
	}
	else {
		NMISNG::Util::logMsg("ERROR: no node defined in the event, possible blank event.");
	}
}

sub loadBlackList {
	my $file = shift;
	my @lines;
	if ( -r $file ) {
		open(IN,$file) or warn ("ERROR: problem with file $file; $!");		
		while (<IN>) {
			chomp();
			push(@lines,$_);
		}
		close(IN);
		
		NMISNG::Util::dbg("lines=@lines");
		
		return @lines;
	}
	else {
		NMISNG::Util::logMsg("ERROR: can not read black lits file $file.");
		return 0;
	}
}

1;
