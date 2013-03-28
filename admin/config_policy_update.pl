#!/usr/bin/perl
#
## $Id: updateconfig.pl,v 1.6 2012/08/27 21:59:11 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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


print <<EO_TEXT;
This script will update your running NMIS Config based on the required design 
policy.

EO_TEXT

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config file to update
usage: $0 <CONFIG_1>
eg: $0 /usr/local/nmis8/conf/Config.nmis

EO_TEXT
	exit 1;
}

print "Updating $ARGV[0] with policy\n";

my $conf;

# load configuration table
if ( -f $ARGV[0] ) {
	$conf = readFiletoHash(file=>$ARGV[0]);
}
else {
	print "ERROR: something wrong with config file 1: $ARGV[0]\n";
	exit 1;
}

# Syslog Server for CNOC will be 172.27.130.31
# Syslog Server for IT will be 172.27.7.168

$conf->{'syslog'}{'syslog_events'} = "true";
$conf->{'syslog'}{'syslog_use_escalation'} = "false";
$conf->{'syslog'}{'syslog_server'} = "172.27.130.31:udp:514";
  
$conf->{'authentication'}{'auth_default_privilege'} = 'guest';
$conf->{'authentication'}{'auth_default_groups'} = 'all';
$conf->{'authentication'}{'auth_ms_ldap_server'} = '172.27.5.56';
$conf->{'authentication'}{'auth_ms_ldap_dn_acc'} = 'LDAPRead';
$conf->{'authentication'}{'auth_ms_ldap_dn_psw'} = 'Y1taBc*20';
$conf->{'authentication'}{'auth_ms_ldap_base'} = 'DC=corp,DC=codetel,DC=com,DC=do';
$conf->{'authentication'}{'auth_ms_ldap_attr'} = 'sAMAccountName';
$conf->{'authentication'}{'auth_ms_ldap_debug'} = 'false';
$conf->{'authentication'}{'auth_method_1'} = 'ms-ldap';
$conf->{'authentication'}{'auth_method_2'} = 'htpasswd';

$conf->{'email'}{'mail_server'} = 'localhost';
$conf->{'email'}{'mail_from'} = 'nmis1@claro.com.do';
$conf->{'email'}{'mail_domain'} = 'claro.com.do';
$conf->{'email'}{'mail_combine'} = 'true';

$conf->{'master_slave'}{'server_community'} = 'ClaroServerCommunity';
$conf->{'master_slave'}{'slave_community'} = 'ClaroServerCommunity';
$conf->{'master_slave'}{'server_master'} = 'false';

    
writeHashtoFile(file=>$ARGV[0],data=>$conf);
