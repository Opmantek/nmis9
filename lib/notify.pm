#
## $Id: notify.pm,v 8.4 2012/09/18 01:41:00 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

package notify;

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;
use Net::SMTP;
# use Net::SMTP::SSL;
use Net::SNPP;
use Net::Syslog;
use NMIS;
use func;
use JSON::XS;

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(
		sendEmail
		sendSNPP
		sendSyslog
		eventToSyslog
		logJsonEvent
	);

@EXPORT_OK = qw(	);

## KS 18/4/01 - Added new sendEmail routine for use elsewhere.
## EHG 28 Aug added message priority handling
sub sendEmail {
	my %arg = @_;
	my $debug = $arg{debug};
	if ( ! defined $debug ) { $debug = 0; }
	my $smtp_debug;
	my $string;
	my $help;
	my @addr;
	my $oneaddr;
	my $got_server = 0;
	my $server = 0;
	my $smtp;
	
	my $use_sasl = $arg{use_sasl} ? $arg{use_sasl} : "false";
	my $port;
	my $password;
	if( $use_sasl eq 'true' ) {
		$port = $arg{port};
		$password = $arg{password};
	}

	my $priNum = 3;
	my $priWord = "Normal";
	if ( defined $arg{priority} ) {
		if ( $arg{priority} =~ /^[a-z]+$/i ) {
			$priWord = $arg{priority};
			$priNum = &setSMTPPriority($arg{priority});
		}
		else {
			$priNum = $arg{priority};
			$priWord = &setSMTPPriority($arg{priority});
		}
	}
	else {
		print "Priority not set, priority=$arg{priority}\n";
	}

	if ($debug) { print returnTime." sendEmail to=$arg{to} subject=$arg{subject}\n"; }
	if  ( $arg{to} ne "" ) {
		# Allow multiple smtp servers!
		my @servers = split(",",$arg{server});
		while ( ! $got_server and $server <= $#servers ) {
			$smtp_debug = ( $debug > 2 ) ? 1 : 0;

			if( $use_sasl eq 'true' )
			{
				require Net::SMTP::SSL;
				if( $smtp = Net::SMTP::SSL->new($servers[$server], Port => $port, Debug => $smtp_debug)) {
					if( $smtp->auth($arg{user}, $arg{password}) ) {
						if ($debug) { print "SASL auth successfull"; }
					}
					else {
						undef $smtp;
						if ($debug) { print "SMTP::SSL auth NOT successfull"; }
					}											
				}
				else {
					undef $smtp;
					if ($debug) { print "SMTP::SSL connect NOT successfull"; }
				}
			}
			else {
				# don't use sasl
				$smtp = Net::SMTP->new($servers[$server], Debug => $smtp_debug );
				if( $arg{user} ne "" and $arg{password} ne "") {
					if( $smtp->auth($arg{user}, $arg{password}) ) {
						if ($debug) { print "SMTP auth successfull"; }
					}
				}
			}

			if ( defined $smtp ) {
				$got_server = 1;
				if ( $debug > 2 ) {
					# Use this to debug what mailers I can't use or support if needs be.
					print "sendEmail; BANNER: ", $smtp->banner(), "\n";
					print "sendEmail; SMTP HELP: ", $smtp->help(), "\n";
				}
	
				$smtp->mail($arg{from});
				@addr = split(",", $arg{to});
				foreach $oneaddr (@addr) {
					$smtp->to($oneaddr);
				}
	
				# Some servers might need this!
				#$smtp->hello($arg{mail_domain});
	
				$smtp->data();
				$smtp->datasend("X-Mailer: NMIS on Net::SMTP\n");
				$smtp->datasend("X-Priority: $priNum\n");
				$smtp->datasend("X-MSMail-Priority: $priWord\n");
				$smtp->datasend("Importance: $priWord\n");
				$smtp->datasend("Priority: $priWord\n");
				$smtp->datasend("Subject: $arg{subject}\n");
				$smtp->datasend("From: $arg{from}\n");
				$smtp->datasend("To: $arg{to}\n");
				$smtp->datasend("\n");
				$smtp->datasend("$arg{body}\n");
	
				$smtp->dataend();
	
				$smtp->quit;
			}
			++$server;
		}

		if ( ! $got_server ) {
				logMsg("sendMail, ERROR with sending email server=$arg{server} to=$arg{to} from=$arg{from} subject=$arg{subject}");
		}
	}
	else {
		print STDERR "sendEmail, ERROR: \"to\" is BLANK\n";
	}
}

sub setSMTPPriority {
	my $pri = shift;
	# if its a number
	if ( $pri =~ /^[0-9]$/ ) {
		if ( $pri == 3 ) { return "Normal"; }
		elsif ( $pri == 1 ) { return "High"; }
		elsif ( $pri == 5 ) { return "Low"; }
		else { return "ERROR"; }
	}
	# if its a word
	elsif ( $pri =~ /^[a-z]+$/i ) {
		if ( $pri =~ /Normal/i ) { return 3; }
		elsif ( $pri =~ /High/i ) { return 1; }
		elsif ( $pri =~ /Low/i ) { return 5; }
		else { return "ERROR"; }
	}
	else {
		return "ERROR";
	}
}

## KS - 31 Mar 02, implemented James Norris's code for SNPP
# use like sendSNPP(server => $NMIS::config{snpp_server}, pagerno => $contact_table{$contact}{Pager}, message => "Send a page baby");
sub sendSNPP {
	my %arg = @_;
	my $debug = $arg{debug};
	if ( defined $arg{server} and defined $arg{pagerno} and defined $arg{message} ) { 
		my $snpp = Net::SNPP->new($arg{server});
		$snpp->send( Pager   => $arg{pagerno},
		             Message => $arg{message},
		           ) || warn "sendSNPP, SNPP Error: ", $snpp->message, "\n";
		$snpp->quit;
	} else {
		print STDERR "sendSNPP, ERROR required info is not defined: host=$arg{server} pagerno=$arg{pagerno} message=$arg{message}\n";
	}
}

sub sendSyslog {
	my %arg = @_;
	my $debug = $arg{debug};
	my $server_string = $arg{server_string};
	my $facility = $arg{facility};

	my $message = "NMIS_Event::$arg{nmis_host}::$arg{time},$arg{node},$arg{event},$arg{level},$arg{element},$arg{details}";
	if ( $arg{nmis_host} eq "" and $arg{node} eq "" and $arg{message} ne "" ) {
		$message = $arg{message};
	}

	my $priority = eventToSyslog($arg{level});
	$priority = 'notice' if $priority eq "";
	
	my $s=Net::Syslog->new(Facility => $facility, Priority => $priority);
	my @servers = split(",",$server_string);
	foreach my $server (@servers) {
		if ( $server =~ /([\w\.\-]+):(udp|tcp):(\d+)/ ) {
			#server = localhost:udp:514
			my $server = $1;
			my $protocol = $2;
			my $port = $3;
			if ( $message ne "" ) {
				$s->send($message, SyslogHost => $server, SyslogPort => $port, Priority => $priority);
				dbg("syslog $message to $server:$port");
			}
		}
		else {
			logMsg("ERROR: syslog server not configured correctly, configured as $server, should be in the format 'localhost:udp:514'");
		}
	}
}

sub eventToSyslog {
	my $level = shift;
	my $priority;   	
	#emergency, alert, critical, error, warning, notice, informational, debug

	if ( $level eq "Normal" ) { $priority = "notice"; }
	elsif ( $level eq "Warning" ) { $priority = "warning"; }
	elsif ( $level eq "Minor" ) { $priority = "error"; }
	elsif ( $level eq "Major" ) { $priority = "critical"; }
	elsif ( $level eq "Critical" ) { $priority = "alert"; }
	elsif ( $level eq "Fatal" ) { $priority = "emergency"; }
	else { $priority = "info" }

	return $priority;
}


sub logJsonEvent {
	my %arg = @_;
	my $event = $arg{event};
	my $dir = $arg{dir};
	my $fcount = 1;
	
	# add the time now to the event data.
	$event->{time} = time;
	
	my $file ="$dir/$event->{startdate}-$fcount.json";
	while ( -f $file ) {
		++$fcount;
		$file ="$dir/$event->{startdate}-$fcount.json";
	}
	
	my $json_event = encode_json( $event ); #, { pretty => 1 } );
	open(JSON,">$file") or logMsg("ERROR, can not write to $file");
	print JSON $json_event;
	close JSON;
	setFileProt($file);
}


1;
