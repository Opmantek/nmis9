#
## $Id: notify.pm,v 8.4 2012/09/18 01:41:00 keiths Exp $
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
package notify;
our $VERSION = "1.1.0";

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use Exporter;
use Net::SMTPS;
use Net::SNPP;
use Sys::Syslog 0.28;						# older versions cannot set a custom syslog port
use Sys::Hostname;							# for sys::syslog
use File::Basename;
use version 0.77;
# use NMIS; # this makes circular use loops and causes lots of subroution redefined warnings
use func;												# for logmsg and dbg
use JSON::XS;

@ISA = qw(Exporter);

@EXPORT = qw(
		sendEmail
		sendSNPP
		sendSyslog
		eventToSyslog
		logJsonEvent
	);

@EXPORT_OK = qw(	);

# sendEmail: send input text or mime entity to any number of recipients
# 
# args: text or mime (=entity) or body+subject+from+to (old-style compat args)
# mailserver, sender, recipients (=list), hello (all required)
#
# optional serverport (default 25, you may want to use 587)
# optional ipproto ("ipv4" or "ipv6" or undef for auto-detection)
# optional usetls (default 1), 
# optional username and password (default no auth), 
# optional authmethod (default CRAM-MD5, use LOGIN if you have to)
# optional ssl_verify_mode (default not defined - set to SSL_VERIFY_NONE 
# when calling in Windows or on a system without workable certificate setup)
# 
# text has to be a complete email with headers and body, mime entity must be a toplevel 
# entity with appropriate headers
# 
# returns list of (status, last server code, last server message), 
# status 1 is all ok, 0 otherwise
# 
# last server code is last SMTP status code (eg. 250, 550 etc) of SMTP DATA
# on success, or the one that caused sendEmail to give up, or 999 if we didn't
# get anywhere (eg. dud arguments)
#
# last server message is either response of SMTP data (= queue id at target)
# or the server response that caused sendEmail to give up.
sub sendEmail 
{
	my (%arg)=@_;

	$arg{serverport} ||= 25;
	$arg{usetls} = 'starttls' 
			if ($arg{usetls} || !exists($arg{usetls})); # if 1 or not given
		
	# sanity checking first
	for my $mand (qw(mailserver serverport sender recipients hello))
	{
		return (0,999,"mandatory argument $mand is missing - giving up.")
				if (!$arg{$mand});		# autovivification is not a problem here, zero/blank not allowed anyway
	}

	return (0,999,"full text, or the body+specific args or mime entity must be given - giving up.")
			if (!$arg{text} && !$arg{body}&& ref($arg{mime}) ne "MIME::Entity");

	# backwards-compat creation of the mail on the go
	if (!$arg{text} && ref($arg{mime}) ne "MIME::Entity")
	{
		my $mailtext;

		my $priNum = 3;
		my $priWord = "Normal";
		if ( defined $arg{priority} && $arg{priority} =~ /^[a-z]+$/i ) 
		{
			$priWord = $arg{priority};
			$priNum = &setSMTPPriority($arg{priority});
		}
		elsif (defined $arg{priority} && $arg{priority} =~ /^\\d+$/ )
		{
			$priNum = $arg{priority};
			$priWord = &setSMTPPriority($arg{priority});
		}
		
		$mailtext = "X-Mailer: NMIS $NMIS::VERSION\nX-Priority: $priNum\nX-MSMail-Priority: $priWord\n"
				."Importance: $priWord\nPriority: $priWord\n";
		$mailtext .= "Subject: $arg{subject}\nFrom: $arg{from}\nTo: $arg{to}\n\n$arg{body}\n";
		$arg{text} = $mailtext;
	}

	# undef means autodetect.
	my $ipproto = $arg{ipproto} eq "ipv4"? AF_INET : $arg{ipproto} eq "ipv6"? AF_INET6: undef;

	# if dossl isn't on then this just opens a normal unauthed socket
	my @connargs=($arg{mailserver},
								Port => $arg{serverport},
								doSSL => $arg{usetls},
								"Hello" => $arg{hello},
								"Domain" => $ipproto,
								SSL_verify_mode => $arg{ssl_verify_mode});
	my $smtp = Net::SMTPS->new( @connargs );
		
	return (0,999,"connection to $arg{mailserver}, port $arg{serverport} failed: $!")
			if (!$smtp);

	# auth is done whenever both mail_user and mail_password are both set to non-blank
	if ($arg{username} && $arg{password})
	{
		return (0,$smtp->code, "auth failed: ".$smtp->message)
				if (!$smtp->auth($arg{username}, $arg{password}, $arg{authmethod}));
	}
	
	# send mail from 
	return (0, $smtp->code, "server rejected sender: ".$smtp->message)
			if (!$smtp->mail($arg{sender}));
	
	# send recipient to and bail out if any of them fail
	{
		for my $to (@{$arg{recipients}})
		{
			return (0, $smtp->code, "server rejected recipient $to: ".$smtp->message)
					if (!$smtp->to($to));
		}
	}
	
	# almost there, now send data and produce the content
	my $content = defined $arg{text}? $arg{text} : $arg{mime}->as_string;
	return (0, $smtp->code, "server rejected data: ".$smtp->message)
			if (!$smtp->data( $content ));
	
	# message actually returns list if in list context, not that any docs say so...
	my @ret = (1, $smtp->code, (join("",$smtp->message)));
	$smtp->quit; 								# no error handling required or useful

	return @ret;
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

# args: debug, server_string (comma-sep list of host:proto:port), facility, 
# time, event, level, details, node and nmis_host
# message (which is IGNORED if arg node and arg nmis_host are set!)
# 
sub sendSyslog 
{
	my %arg = @_;
	my $debug = $arg{debug};
	my $server_string = $arg{server_string};
	my $facility = $arg{facility};

	my $message = "NMIS_Event::$arg{nmis_host}::$arg{time},$arg{node},$arg{event},$arg{level},$arg{element},$arg{details}";
	if ( $arg{nmis_host} eq "" and $arg{node} eq "" and $arg{message} ne "" ) {
		$message = $arg{message};
	}
	return if (!$message);

	my $priority = eventToSyslog($arg{level});
	$priority = 'notice' if $priority eq "";
	
	my @servers = split(",",$server_string);
	foreach my $server (@servers) 
	{
		if ( $server =~ /([\w\.\-]+):(udp|tcp):(\d+)/ ) 
		{
			#server = localhost:udp:514
			my $server = $1;
			my $protocol = $2;
			my $port = $3;


			# don't bother waiting, especially not with udp

			# sys::syslog has a silly bug: host option is overwritten by "path" for udp and tcp :-/
			Sys::Syslog::setlogsock({type => $protocol, host => $server,

															 path => $server, 
															 port => $port, timeout => 0});
			# this creates an rfc3156-compliant hostname + command[pid]: header
			# note that sys::syslog doesn't fully support rfc5424, as it doesn't
			# create a version part.
			openlog(hostname." ".basename($0), "nofatal,pid", $facility);
			# the nofatal is for not bothering with send failures.

			syslog($priority, $message);
			closelog;
			Sys::Syslog::setlogsock([qw(native tcp udp unix pipe stream console)]); 			# reset to defaults

			dbg("syslog $message to $server:$port");
		}
		else 
		{
			logMsg("ERROR: syslog server \"$server\" not configured correctly, should be in the format 'localhost:udp:514'");
		}
	}
}

# convert event level to syslog priority
sub eventToSyslog {
	my $level = shift;
	my $priority;   	
	# sys::syslog insists on the output matching the syslog(3) levels, ie. either be "LOG_ALERT" or "alert" etc.
	# LOG_EMERG, LOG_ALERT, LOG_CRIT, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO, LOG_DEBUG

	if ( $level eq "Normal" ) { $priority = "notice"; }
	elsif ( $level eq "Warning" ) { $priority = "warning"; }
	elsif ( $level eq "Minor" ) { $priority = "err"; }
	elsif ( $level eq "Major" ) { $priority = "crit"; }
	elsif ( $level eq "Critical" ) { $priority = "alert"; }
	elsif ( $level eq "Fatal" ) { $priority = "emerg"; }
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
