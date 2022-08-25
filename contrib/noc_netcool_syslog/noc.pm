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

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;
use func;
use notify;

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(
		noc
	);

@EXPORT_OK = qw(	);


sub sendNotification {
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $C = $arg{C};

	# get syslog config from config file.
	if (existFile(dir=>'conf',name=>'nocSyslog')) {
		my $syslogConfig = loadTable(dir=>'conf',name=>'nocSyslog');
		$syslog_facility = $syslogConfig->{syslog}{syslog_facility};
		$syslog_server = $syslogConfig->{syslog}{syslog_server};
		$extraLogging = getbool($syslogConfig->{syslog}{extra_logging});
	}

	my $blackListFile = "$C->{'<nmis_conf>'}/nocBlackList.txt";
	my @blackList = loadBlackList($blackListFile);
	
	# is there a valid event coming in?
	if ( defined $event->{node} and $event->{node} ) {
		my $node = $event->{node};
		
		# is the node in the black list?
		if (not grep { $event->{event} =~ /$_/ } @blackList) { 			
			my $info = 1;
			
			# set this to 1 to include group in the message details, 0 to exclude.
			my $includeGroup = 1;
				
			# the seperator for the details field.
			my $detailSep = " -- ";
				
			dbg("Processing $node $event->{event}");
			my $S = Sys::->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		
			my $NI = $S->ndinfo;
							
			my @detailBits;
		
			if ( $includeGroup ) {
				push(@detailBits,$NI->{system}{group});
			}
	
			# does the event have any interface details.
			#if ( defined $event->{element} and $event->{element} ) {
			#	my $IFD = $S->ifDescrInfo(); # interface info indexed by ifDescr
			#	if ( $IFD->{$event->{element}}{collect} eq "true" ) {
		  #
			#	if ( defined $IF->{$ifIndex}{Description} and $IF->{$ifIndex}{Description} ne "" ) {
			#		push(@detailBits,"$IF->{$ifIndex}{Description}");
			#	}
		  #
			#		if ($C->{global_events_bandwidth} eq 'true')
			#		{
			#				push(@detailBits,"Bandwidth=".$IFD->{$event->{element}}{ifSpeed});
			#		}
			#	}
			#}
		
			push(@detailBits,$event->{details});
			
			my $details = join($detailSep,@detailBits);
		
			#remove dodgy quotes
			$details =~ s/[\"|\']//g;
			
			dbg("sendSyslog $syslog_server $syslog_facility");
		
			my $success = sendSyslog(
				server_string => $syslog_server,
				facility => $syslog_facility,
				nmis_host => $C->{server_name},
				time => time(),
				node => $node,
				event => $event->{event},
				level => $event->{level},
				element => $event->{element},
				details => $details
			);
			if ( $success ) {
				logMsg("INFO: syslog sent: $event->{node} $event->{event} $event->{element} $details") if $extraLogging;
			}
			else {
				logMsg("ERROR: syslog failed to $syslog_server: $event->{node} $event->{event} $event->{element} $details");
			}			
		}
		else {
			logMsg("INFO: event not sent as event in blacklist $event->{node} $event->{event} $event->{element}.") if $extraLogging;
		}
	}
	else {
		logMsg("ERROR: no node defined in the event, possible blank event.");
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
		
		dbg("lines=@lines");
		
		return @lines;
	}
	else {
		logMsg("ERROR: can not read black lits file $file.");
		return 0;
	}
}

1;
