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
use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Spec;
use Data::Dumper;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;
use Data::Dumper;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Outage;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use NMISNG::Notify;

use Compat::NMIS;

if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$NMISNG::VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage       = "Usage: $thisprogram [option=value...] <act=command>

 * act=check-daemons start=1 notify=email\@domain.com
	
   where:
	* start=1 restart daemon if stopped
        * notify= email for notifications
        * quiet=1 no print messages
        * verbose=1 trying to get debug info
 
\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);

my $wantverbose = (NMISNG::Util::getbool($Q->{verbose}));
my $wantquiet  = NMISNG::Util::getbool($Q->{quiet});

my $customconfdir = $Q->{dir}? $Q->{dir}."/conf" : undef;
my $C      = NMISNG::Util::loadConfTable(dir => $customconfdir,
											 debug => $Q->{debug});
die "no config available!\n" if (ref($C) ne "HASH" or !keys %$C);


# show the daemon status
if ($Q->{act} =~ /^check[-_]daemons/)
{
	my $start = $Q->{start};
	my $notify = $Q->{notify};
	
	my $result = 1;
	my $body = "";
	
	for my $service (qw(mongod nmis9d)) {
		my $status = (`if which systemctl 2>/dev/null; then systemctl status $service;else service $service status;fi;`);
		my $exitcode = $?;
		if ($exitcode or $exitcode >> 8)
		{
			print "Failed to get service $service status: exit code=$exitcode\n";
		}
		print $status if (!$wantquiet);
		if ($status and $status !~ '(not running|inactive|failed)') {
		   # All good
		   print "Status $service looks ok \n" if (!$wantquiet);
		}
		else {
            print "Failed service status $service: exit code=$exitcode\n";
            $result = 0;
            $body = $body . "\n +++++++++++++++++++++++++++++++++++++++ \n";
		    $body = $body . "Service $service was stopped \n";
            $body = $body . " +++++++++++++++++++++++++++++++++++++++ \n\n";
           
            if ($wantverbose) {
                $body = $body . "$status \n";
                if ($service =~ /mongod/) {
                   my $lines = `tail -n 100 /var/log/mongodb/mongod.log`;
                   $body = $body . "$lines \n";
                } elsif ($service =~ /nmis9d/) {
                   my $lines = `tail -n 100 /usr/local/nmis9/logs/nmis.log`;
                   $body = $body . "$lines \n";
                }
           }
            
		   if ($start) {
			
				print "Trying to start service $service \n";
				my $status = (`service $service start`);
				
				print $status if (!$wantquiet);
		   }
           
		}
	}
	
	my $C = NMISNG::Util::loadConfTable();
	
	if ($result == 0 && $notify) {
		my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
			# params for connection and sending 
			sender => $C->{mail_from},
			recipients => [$notify],
		
			mailserver => $C->{mail_server},
			serverport => $C->{mail_server_port},
			hello => $C->{mail_domain},
			usetls => $C->{mail_use_tls},
			ipproto =>  $C->{mail_server_ipproto},
								
			username => $C->{mail_user},
			password => $C->{mail_password},
		
			# and params for making the message on the go
			to => $notify,
			from => $C->{mail_from},
		
			subject => "Service down",
			body => $body,
			priority => "Normal",
		
			debug => $C->{debug}
		
		);
		
		if (!$status)
		{
			print "Error: Sending email to $notify failed: $code $errmsg\n" if (!$wantquiet);
		}
		else
		{
			print "Test Email to $notify sent successfully\n" if (!$wantquiet);
		}
	}

	exit 0;
} else {
    die $usage;
}