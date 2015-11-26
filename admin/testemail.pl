#!/usr/bin/perl
#
## $Id: testemail.pl,v 1.3 2012/09/18 01:40:59 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMIS;
use func;
use notify;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

my $debug = getbool($nvp{debug});

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});
my $CT = loadContactsTable();

my $contactKey = "contact1";

my $target = $CT->{$contactKey}{Email};

print "This script will send a test email to the contact $contactKey $target\n";
print "Using the configured email server $C->{mail_server}\n";

my ($status, $code, $errmsg) = sendEmail(
	# params for connection and sending 
	sender => $C->{mail_from},
	recipients => [$target],

	mailserver => $C->{mail_server},
	serverport => $C->{mail_server_port},
	hello => $C->{mail_domain},
	usetls => $C->{mail_use_tls},
	ipproto =>  $C->{mail_server_ipproto},
						
	username => $C->{mail_user},
	password => $C->{mail_password},

	# and params for making the message on the go
	to => $target,
	from => $C->{mail_from},

	subject => "Normal Priority Test Email from NMIS8\@$C->{server_name}",
	body => "This is a Normal Priority Test Email from NMIS8\@$C->{server_name}",
	priority => "Normal",

	debug => $C->{debug}

		);

if (!$status)
{
	print "Error: Sending email to $target failed: $code $errmsg\n";
}
else
{
	print "Test Email to $target sent successfully\n";
}

($status, $code, $errmsg) = sendEmail(
	# params for connection and sending 
	sender => $C->{mail_from},
	recipients => [$target],

	mailserver => $C->{mail_server},
	serverport => $C->{mail_server_port},
	hello => $C->{mail_domain},
	usetls => $C->{mail_use_tls},
	ipproto =>  $C->{mail_server_ipproto},
						
	username => $C->{mail_user},
	password => $C->{mail_password},

	# and params for making the message on the go
	to => $target,
	from => $C->{mail_from},

	subject => "High Priority Test Email from NMIS8\@$C->{server_name}",
	body => "This is a High Priority Test Email from NMIS8\@$C->{server_name}",
	priority => "High",

	debug => $C->{debug}
		);

if (!$status)
{
	print "Error: Sending email to $target failed: $code $errmsg\n";
}
else
{
	print "Test Email to $target sent successfully\n";
}
