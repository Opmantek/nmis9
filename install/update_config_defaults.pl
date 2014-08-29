#!/usr/bin/perl
#
## $Id: updateconfig.pl,v 1.6 2012/08/27 21:59:11 keiths Exp $
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
use func;

my $confFile = "/usr/local/nmis8/conf/Config.nmis";

print <<EO_TEXT;
This script will update your running NMIS Config with the latest defaults, especially JQuery.

EO_TEXT

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config file to update
usage: $0 <CONFIG_1>
eg: $0 $confFile

EO_TEXT
	exit 1;
}
else {
	$confFile = $ARGV[0];
}

print "Updating $ARGV[0] with new defaults\n";

my $conf;

# load configuration table
if ( -f $ARGV[0] ) {
	$conf = readFiletoHash(file=>$ARGV[0]);
}
else {
	print "ERROR: something wrong with config file: $ARGV[0]\n";
	exit 1;
}

backupFile(file => $ARGV[0], backup => "$ARGV[0].backup");

$conf->{'authentication'}{'auth_user_name_regex'} = "[\\w \\-\\.\\@\\`\\']+";

$conf->{'system'}{'threshold_period-default'} = "-15 minutes";
$conf->{'system'}{'threshold_period-health'} = "-4 hours";
$conf->{'system'}{'threshold_period-pkts'} = "-5 minutes";
$conf->{'system'}{'threshold_period-pkts_hc'} = "-5 minutes";
$conf->{'system'}{'threshold_period-interface'} = "-5 minutes";

$conf->{'system'}{'log_node_configuration_events'} = "false";

$conf->{'system'}{'os_execperm'} = "0770";
$conf->{'system'}{'os_fileperm'} = "0660";

delete $conf->{'system'}{'snmp_max_repetitions'};

$conf->{'javascript'}{'chart'} = "";
$conf->{'javascript'}{'highcharts'} = "";
$conf->{'javascript'}{'highstock'} = "";
$conf->{'javascript'}{'jquery'} = "<menu_url_base>/js/jquery-1.8.3.min.js";
$conf->{'javascript'}{'jquery_ui'} = "<menu_url_base>/js/jquery-ui-1.9.2.custom.js";
    
$conf->{'css'}{'jquery_ui_css'} = "<menu_url_base>/css/smoothness/jquery-ui-1.9.2.custom.css";

$conf->{'metrics'}{'weight_availability'} = "0.1";
$conf->{'metrics'}{'weight_cpu'} = "0.2";
$conf->{'metrics'}{'weight_int'} = "0.3";
$conf->{'metrics'}{'weight_mem'} = "0.1";
$conf->{'metrics'}{'weight_reachability'} = "0.1";
$conf->{'metrics'}{'weight_response'} = "0.2";

if ( $conf->{'authentication'}{'auth_method_1'} eq "apache" ) {
	print "You are using Apache Authentication, please update your system to use htpasswd or other authentication\n";
	print "Details @ https://community.opmantek.com/display/NMIS/Configuring+NMIS+to+use+Internal+Authentication\n";
	
}

writeHashtoFile(file=>$ARGV[0],data=>$conf);

print "Done updating $ARGV[0]\n";
