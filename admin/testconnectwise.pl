#!/usr/bin/perl
#
## $Id: testconnectwise.pl,v 1.0 
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

use strict;
use NMISNG;
use NMISNG::Util;
use Notify::connectwiseconnector;
use Data::Dumper;

# Variables for command line munging
my %nvp = NMISNG::Util::get_args_multi(@ARGV);

my $debug = NMISNG::Util::getbool($nvp{debug});

# load configuration table
my $C = NMISNG::Util::loadConfTable(conf=>$nvp{conf}, debug=>$nvp{debug});
my $CT = NMISNG::Util::loadTable(dir=> "conf", name=>"Contacts", debug=>$nvp{debug});

my $contactKey = "contact1";

my $target = $CT->{$contactKey}{Email};

print "This script will send a connectwise $contactKey $target\n";
print "Using the configured server $C->{auth_cw_server}\n";

my $event = {
    event => "Test Event " . time,
    node_name => "asgard-local",
    context => {name => "Test ConnectWise Connector"},
    stateless => 0,
    };
my $message = "Connectwise test";
my $priority = 1;

# now get us an nmisng object, which has a database handle and all the goods
my $logfile = $C->{'<nmis_logs>'} . "/connectwiseConnector.log"; 
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
															debug => $debug),
															path  => $logfile);
my $nmisng = NMISNG->new(config => $C, log  => $logger);

my $result = Notify::connectwiseconnector::sendNotification(C => $C, nmisng => $nmisng, contact => $CT->{$contactKey}, event => $event, message => $message, priority => $priority);

if (!$result)
{
	print "Error: Connectwise test to $contactKey failed. Check $logfile for details\n";
}
else
{
	print "Connectwise test to $contactKey done $result\n";
}