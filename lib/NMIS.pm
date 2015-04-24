#
## $Id: NMIS.pm,v 8.43 2012/10/02 05:45:49 keiths Exp $
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

package NMIS;

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

use strict;
use RRDs;
use Time::ParseDate;
use Time::Local;
use Net::hostent;
use Socket;
use func;
use csv;
use notify;
use ip;
use Sys;
use DBfunc;
use URI::Escape;

# added for authentication
use CGI::Pretty qw(:standard *table *Tr *td *Select *form escape);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION );

use Exporter;

#! Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

$VERSION = "8.5.8G";

@ISA = qw(Exporter);

@EXPORT = qw(	
		loadLinkDetails
		loadNodeTable
		loadLocalNodeTable
		loadNodeSummary
		loadNodeInfoTable
		loadGroupTable
		loadGenericTable
		tableExists
		loadContactsTable
		loadLocationsTable
		loadEscalationsTable
		loadifTypesTable
		loadServicesTable
		loadUsersTable
		loadPrivMapTable
		loadAccessTable
		loadLinksTable
		loadRMENodes
		loadServersTable
		loadWindowStateTable
		
		loadInterfaceInfo
		loadInterfaceInfoShort
		loadEnterpriseTable
		loadNodeConfTable
		loadOutageTable
		loadInterfaceTypes
		loadCfgTable
		findCfgEntry

		checkNodeName

		loadEventStateNoLock
		loadEventStateLock
		writeEventStateLock
		runEventDebug

		eventLevel
		eventHash
		eventExist
		checkEvent
		logEvent
		eventAdd
		eventAck
		notify
		cleanEvent
		nodeStatus

		getSummaryStats
		getGroupSummary
		getNodeSummary
		getLevelLogEvent
		overallNodeStatus
		getOperColor
		getAdminColor
		colorHighGood
		colorPort
		colorLowGood
		colorResponseTimeStatic
		thresholdPolicy
		thresholdResponse
		thresholdLowPercent
		thresholdHighPercent
		thresholdHighPercentLoose
		thresholdMemory
		thresholdInterfaceUtil
		thresholdInterfaceAvail
		thresholdInterfaceNonUnicast

		convertConfFiles
		statusNumber
		logMessage
		outageCheck
		outageRemove
		sendTrap
		eventToSMTPPri
		dutyTime
		resolveDNStoAddr
		htmlGraph
		createHrButtons
		loadPortalCode
		loadServerCode
		loadTenantCode
		
		startNmisPage
		pageStart
		pageStartJscript
		getJavaScript
		pageEnd
		
		requestServer
	);

@EXPORT_OK = qw(	
			$version
		);

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Cache table pointers
my $NT_cache = undef; # node table (local + remote)
my $NT_modtime; # file modification time
my $LNT_cache = undef; # local node table
my $LNT_modtime;
my $GT_cache = undef; # group table
my $GT_modtime;
my $ST_cache = undef; # server table
my $ST_modtime;
my $ET_cache = undef; # event table
my $ET_modtime;
my $SUM8_cache = undef; # summary table
my $SUM8_modtime;
my $SUM16_cache = undef; # summary table
my $SUM16_modtime;
my $ENT_cache = undef; # enterprise table
my $ENT_modtime;
my $IFT_cache = undef; # ifTypes table
my $IFT_modtime;
my $SRC_cache = undef; # Services table
my $SRC_modtime;

# preset kernel name
my $kernel = $^O; 

sub loadLinkDetails {
	my $C = loadConfTable();
	my %linkTable = &loadCSV($C->{Links_Table},$C->{Links_Key},"\t");
	return \%linkTable;
} #sub loadLinkDetails

sub loadNodeConfTable {
	return loadTable(dir=>'conf',name=>'nodeConf');
}

# load local node table and store also in cache
sub loadLocalNodeTable {
	my $C = loadConfTable();
	if (getbool($C->{db_nodes_sql})) {
		return DBfunc::->select(table=>'Nodes');
	} else {
		return loadTable(dir=>'conf',name=>'Nodes');
	}
}

sub loadNodeTable {

	my $reload = 'false';

	my $C = loadConfTable();

	if (getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $name = "nmis-${srv}-Nodes";
			if (! loadTable(dir=>'var',name=>$name,check=>'true') ) {
				$reload = 'true';
			}
		}
	}

	if (not defined $NT_cache or ( mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		$reload = 'true';
	}

	return $NT_cache if getbool($reload,"invert");

	# rebuild tables
	$NT_cache = undef;
	$GT_cache = undef;

	my $LNT = loadLocalNodeTable();
	my $master_server_priority = $C->{master_server_priority} || 10;

	foreach my $node (keys %{$LNT}) {
		$NT_cache->{$node}{server} = $C->{server_name};
		### set the default server priority to 10 as local node
		$NT_cache->{$node}{server_priority} = $master_server_priority;
		foreach my $k (keys %{$LNT->{$node}} ) {
			$NT_cache->{$node}{$k} = $LNT->{$node}{$k};
		}
		if ( getbool($LNT->{$node}{active})) {
			$GT_cache->{$LNT->{$node}{group}} = $LNT->{$node}{group};
		}
	}
	$NT_modtime = mtimeFile(dir=>'conf',name=>'Nodes');

	if (getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();	
		my $NT;
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# Relies on nmis.pl getting the file every 5 minutes.
			my $name = "nmis-${srv}-Nodes";
			my $server_priority = $ST->{$srv}{server_priority} || 5;
	
			if (($NT = loadTable(dir=>'var',name=>$name)) ) {
				foreach my $node (keys %{$NT}) {
					$NT->{$node}{server} = $srv ;
					$NT->{$node}{server_priority} = $server_priority ;
					if ( 
						( not defined $NT_cache->{$node}{name} and $NT_cache->{$node}{name} eq "" )
						or 
						( defined $NT_cache->{$node}{name} and $NT_cache->{$node}{name} ne "" and $NT->{$node}{server_priority}  > $NT_cache->{$node}{server_priority} )
					) {
						foreach my $k (keys %{$NT->{$node}} ) {
							$NT_cache->{$node}{$k} = $NT->{$node}{$k};
						}
						if ( getbool($NT->{$node}{active})) {
							$GT_cache->{$NT->{$node}{group}} = $NT->{$node}{group};
						}
					}
				}
			}
		}
	}
	return $NT_cache;
}

sub loadGroupTable {

	if( not defined $GT_cache or not defined $NT_cache or ( mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		loadNodeTable();
	}
	
	return $GT_cache;
}

sub tableExists {
	my $table = shift;
	my $exists = 0;
	
	if (existFile(dir=>"conf",name=>$table)) {
		$exists = 1;
	}

	return $exists;
}

sub loadFileOrDBTable {
	my $table = shift;
	my $ltable = lc $table;

	my $C = loadConfTable();
	if (getbool($C->{"db_${ltable}_sql"})) {
		return DBfunc::->select(table=>$table);
	} else {
		return loadTable(dir=>'conf',name=>$table);
	}
}

sub loadGenericTable{
	return loadFileOrDBTable( shift ); 
}	

sub loadContactsTable {
	return loadFileOrDBTable('Contacts');
}

sub loadAccessTable {
	return loadFileOrDBTable('Access');
}

sub loadPrivMapTable {
	return loadFileOrDBTable('PrivMap');
}

sub loadUsersTable {
	return loadFileOrDBTable('Users');
}

sub loadLocationsTable {
	return loadFileOrDBTable('Locations');
}

sub loadifTypesTable {
	return loadFileOrDBTable('ifTypes');
}

sub loadServicesTable {
	return loadFileOrDBTable('Services');
}

sub loadLinksTable {
	return loadTable(dir=>'conf',name=>'Links');
}

sub loadEscalationsTable {
	return loadFileOrDBTable('Escalations');
}

sub loadWindowStateTable 
{
	my $C = loadConfTable();

	return {} if (not -r getFileName(file => "$C->{'<nmis_var>'}/nmis-windowstate"));
	return loadTable(dir=>'var',name=>'nmis-windowstate');
}

# check node name case insentive, return good one
sub checkNodeName {
	my $name = shift;
	my $NT;

	if ($NT = loadLocalNodeTable()) {
		foreach my $nm (keys %{$NT}) {
			if (lc $name eq lc $nm) {
				# found
				return $nm;
			}
		}
		logMsg("ERROR (nmis) node=$name does not exists in table Nodes");
	}
	return;
}

#==================================================================

# this small helper takes an optional section and a require config item name,
# and returns the structure info for that item from loadCfgTable
# returns: hashref (keys display, value etc.) or undef if not found
sub findCfgEntry
{
	my (%args) = @_;
	my ($section,$item) = @args{qw(section item)};
	
	my $meta = loadCfgTable();
	for my $maybesection (defined $section? ($section) : keys %$meta)
	{
		for my $entry (@{$meta->{$maybesection}})
		{
			if ($entry->{$item})
			{
				return $entry->{$item};
			}
		}
	}
	return undef;
}

# this returns an almost config-like structure that describes the well-known config keys,
# how to display them and what options they have
# args: none!
sub loadCfgTable {
	my %args = @_;

	my $table = $args{table}; # fixme ignored, has no function
	
	my %Cfg = ( 
  	'online' => [
				{ 'nmis_docs_online' => { display => 'text', value => ['https://community.opmantek.com/']}},
		],

  	'modules' => [
				{ '<opmantek_base>' => { display => 'text', value => ['/usr/local/opmantek']}},
				{ 'display_opmaps_widget' => { display => 'popup', value => ["true", "false"]}},
				{ 'display_opflow_widget' => { display => 'popup', value => ["true", "false"]}},
		],
  		  
  	'directories' => [
				{ '<nmis_base>' => { display => 'text', value => ['/usr/local/nmis']}},
				{ '<nmis_bin>' => { display => 'text', value => ['<nmis_base>/bin']}},
				{ '<nmis_cgi>' => { display => 'text', value => ['<nmis_base>/cgi-bin']}},
				{ '<nmis_conf>' => { display => 'text', value => ['<nmis_base>/conf']}},
				{ '<nmis_data>' => { display => 'text', value => ['<nmis_base>']}},
				{ '<nmis_logs>' => { display => 'text', value => ['<nmis_base>/logs']}},
				{ '<nmis_menu>' => { display => 'text', value => ['<nmis_base>/menu']}},
				{ '<nmis_models>' => { display => 'text', value => ['<nmis_base>/models']}},
				{ '<nmis_var>' => { display => 'text', value => ['<nmis_base>/var']}},
				{ '<menu_base>' => { display => 'text', value => ['<nmis_base>/menu']}},
				{ 'database_root' => { display => 'text', value => ['<nmis_data>/database']}},
				{ 'log_root' => { display => 'text', value => ['<nmis_logs>']}},
				{ 'mib_root' => { display => 'text', value => ['<nmis_base>/mibs']}},
				{ 'report_root' => { display => 'text', value => ['<nmis_data>/htdocs/reports']}},
				{ 'script_root' => { display => 'text', value => ['<nmis_conf>/scripts']}},
				{ 'web_root' => { display => 'text', value => ['<nmis_data>/htdocs']}}
		],

		'system' => [
				{ 'group_list' => { display => 'text', value => ['']}},
				{ 'nmis_host' => { display => 'text', value => ['localhost']}},
				{ 'domain_name' => { display => 'text', value => ['']}},
				{ 'cache_summary_tables' => { display => 'popup', value => ["true", "false"]}},
				{ 'cache_var_tables' => { display => 'popup', value => ["true", "false"]}},
				{ 'page_refresh_time' => { display => 'text', value => ['60']}},
				{ 'os_posix' => { display => 'popup', value => ["true", "false"]}},
				{ 'os_cmd_read_file_reverse' => { display => 'text', value => ['tac']}},
				{ 'os_cmd_file_decompress' => { display => 'text', value => ['gzip -d -c']}},
				{ 'os_kernelname' => { display => 'text', value => ['']}},
				{ 'os_username' => { display => 'text', value => ['nmis']}},
				{ 'os_fileperm' => { display => 'text', value => ['0775']}},
				{ 'report_files_max' => { display => 'text', value => ['60']}},
				{ 'loc_sysLoc_format' => { display => 'text', value => ['']}},
				{ 'loc_from_DNSloc' => { display => 'popup', value => ["true", "false"]}},
				{ 'loc_from_sysLoc' => { display => 'popup', value => ["true", "false"]}},
				{ 'cbqos_cm_collect_all' => { display => 'popup', value => ["true", "false"]}},
				{ 'buttons_in_logs' => { display => 'popup', value => ["true", "false"]}},
				{ 'node_button_in_logs' => { display => 'popup', value => ["true", "false"]}},
				{ 'page_bg_color_full' => { display => 'popup', value => ["true", "false"]}},
				{ 'http_req_timeout' => { display => 'text', value => ['30']}},
				{ 'ping_timeout' => { display => 'text', value => ['500']}},
				{ 'server_name' => { display => 'text', value => ['localhost']}},
				{ 'response_time_threshold' => { display => 'text', value => ['3']}},
				{ 'nmis_user' => { display => 'text', value => ['nmis']}},
				{ 'nmis_group' => { display => 'text', value => ['nmis']}},
				{ 'fastping_timeout' => { display => 'text', value => ['300']}},
				{ 'fastping_packet' => { display => 'text', value => ['56']}},
				{ 'fastping_retries' => { display => 'text', value => ['3']}},
				{ 'fastping_count' => { display => 'text', value => ['3']}},
				{ 'fastping_sleep' => { display => 'text', value => ['60']}},
				{ 'fastping_node_poll' => { display => 'text', value => ['300']}},
				{ 'ipsla_collect_time' => { display => 'text', value => ['60']}},
				{ 'ipsla_bucket_interval' => { display => 'text', value => ['180']}},
				{ 'ipsla_extra_buckets' => { display => 'text', value => ['5']}},
				{ 'ipsla_mthread' => { display => 'popup', value => ["true", "false"]}},
				{ 'ipsla_maxthreads' => { display => 'text', value => ['10']}},
				{ 'ipsla_mthreaddebug' => { display => 'popup', value => ["false", "true"]}},
				{ 'ipsla_dnscachetime' => { display => 'text', value => ['3600']}},
				{ 'ipsla_control_enable_other' => { display => 'popup', value => ["true", "false"]}},
				{ 'fastping_timeout' => { display => 'text', value => ['300']}},
				{ 'fastping_packet' => { display => 'text', value => ['56']}},
				{ 'fastping_retries' => { display => 'text', value => ['3']}},
				{ 'fastping_count' => { display => 'text', value => ['3']}},
				{ 'fastping_sleep' => { display => 'text', value => ['60']}},
				{ 'fastping_node_poll' => { display => 'text', value => ['300']}},
				{ 'default_graphtype' => { display => 'text', value => ['abits']}},
				{ 'ping_timeout' => { display => 'text', value => ['300']}},
				{ 'ping_packet' => { display => 'text', value => ['56']}},
				{ 'ping_retries' => { display => 'text', value => ['3']}},
				{ 'ping_count' => { display => 'text', value => ['3']}},
				{ 'global_collect' => { display => 'popup', value => ["true", "false"]}},
				{ 'wrap_node_names' => { display => 'popup', value => ["false", "true"]}},
				{ 'nmis_summary_poll_cycle' => { display => 'popup', value => ["true", "false"]}},
				{ 'snpp_server' => { display => 'text', value => ['<server_name>']}},
				{ 'snmp_timeout' => { display => 'text', value => ['5']}},
				{ 'snmp_retries' => { display => 'text', value => ['1']}},
				{ 'snmp_stop_polling_on_error' => { display => 'popup', value => ["false", "true"]}},
		],

  	'url' => [
				{ '<url_base>' => { display => 'text', value => ['/nmis8']}},
				{ '<cgi_url_base>' => { display => 'text', value => ['/cgi-nmis8']}},
				{ '<menu_url_base>' => { display => 'text', value => ['/menu8']}},
				{ 'web_report_root' => { display => 'text', value => ['<url_base>/reports']}}

		],
		
		'tools' => [
				{ 'view_ping' => { display => 'popup', value => ["true", "false"]}},
				{ 'view_trace' => { display => 'popup', value => ["true", "false"]}},
				{ 'view_telnet' => { display => 'popup', value => ["true", "false"]}},
				{ 'view_mtr' => { display => 'popup', value => ["true", "false"]}},
				{ 'view_lft' => { display => 'popup', value => ["true", "false"]}}
		],

		'files' => [
				{ 'styles' => { display => 'text', value => ['<url_base>/nmis.css']}},
				{ 'syslog_log' => { display => 'text', value => ['<nmis_logs>/cisco.log']}},
				{ 'event_log' => { display => 'text', value => ['<nmis_logs>/event.log']}},
				{ 'outage_log' => { display => 'text', value => ['<nmis_logs>/outage.log']}},
				{ 'help_file' => { display => 'text', value => ['<url_base>/help.pod.html']}},
				{ 'nmis' => { display => 'text', value => ['<cgi_url_base>/nmiscgi.pl']}},
				{ 'nmis_log' => { display => 'text', value => ['<nmis_logs>/nmis.log']}}
		],

		'email' => [
			{ 'mail_server' => { display => 'text', value => ['mail.domain.com']}},
			{ 'mail_domain' => { display => 'text', value => ['domain.com']}},
			{ 'mail_from' => { display => 'text', value => ['nmis@domain.com']}},
			{ 'mail_combine' => { display => 'popup', value => ['true','false']}},
			{ 'mail_from' => { display => "text", value => ['nmis@yourdomain.com']}},
			{	'mail_use_tls' => { display => 'popup', value => ['true','false']}},
			{ 'mail_server_port' => { display => "text", value => ['25']}},
			{ 'mail_server_ipproto' => { display => "popup", value => ['','ipv4','ipv6']}},
			{ 'mail_user' => { display => "text", value => ['your mail username']}},
			{ 'mail_password' => { display => "text", value => ['']}},
		],

		'menu' => [
				{ 'menu_title' => { display => 'text', value => ['NMIS']}},
				{ 'menu_types_active' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_types_full' => { display => 'popup', value => ["true", "false", "defer"]}},
				{ 'menu_types_foldout' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_groups_active' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_groups_full' => { display => 'popup', value => ["true", "false", "defer"]}},
				{ 'menu_groups_foldout' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_vendors_active' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_vendors_full' => { display => 'popup', value => ["true", "false", "defer"]}},
				{ 'menu_vendors_foldout' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_maxitems' => { display => 'text', value => ['30']}},
				{ 'menu_suspend_link' => { display => 'popup', value => ["true", "false"]}},
				{ 'menu_start_page_id' => { display => 'text', value => ['']}}
		],

		'icons' => [
				{ 'normal_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-green.gif']}},
				{ 'arrow_down_green' => { display => 'text', value => ['<menu_url_base>/img/arrow_down_green.gif']}},
				{ 'arrow_up_big' => { display => 'text', value => ['<menu_url_base>/img/bigup.gif']}},
				{ 'logs_icon' => { display => 'text', value => ['<menu_url_base>/img/logs.jpg']}},
				{ 'mtr_icon' => { display => 'text', value => ['<menu_url_base>/img/mtr.jpg']}},
				{ 'arrow_up' => { display => 'text', value => ['<menu_url_base>/img/arrow_up.gif']}},
				{ 'help_icon' => { display => 'text', value => ['<menu_url_base>/img/help.jpg']}},
				{ 'telnet_icon' => { display => 'text', value => ['<menu_url_base>/img/telnet.jpg']}},
				{ 'back_icon' => { display => 'text', value => ['<menu_url_base>/img/back.jpg']}},
				{ 'lft_icon' => { display => 'text', value => ['<menu_url_base>/img/lft.jpg']}},
				{ 'fatal_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-red.gif']}},
				{ 'trace_icon' => { display => 'text', value => ['<menu_url_base>/img/trace.jpg']}},
				{ 'nmis_icon' => { display => 'text', value => ['<menu_url_base>/img/nmis.jpg']}},
				{ 'summary_icon' => { display => 'text', value => ['<menu_url_base>/img/summary.jpg']}},
				{ 'banner_image' => { display => 'text', value => ['<menu_url_base>/img/NMIS_Logo.gif']}},
				{ 'map_icon' => { display => 'text', value => ['<menu_url_base>/img/australia-line.gif']}},
				{ 'minor_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-yellow.gif']}},
				{ 'arrow_down_big' => { display => 'text', value => ['<menu_url_base>/img/bigdown.gif']}},
				{ 'ping_icon' => { display => 'text', value => ['<menu_url_base>/img/ping.jpg']}},
				{ 'unknown_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-white.gif']}},
				{ 'doc_icon' => { display => 'text', value => ['<menu_url_base>/img/doc.jpg']}},
				{ 'arrow_down' => { display => 'text', value => ['<menu_url_base>/img/arrow_down.gif']}},
				{ 'arrow_up_red' => { display => 'text', value => ['<menu_url_base>/img/arrow_up_red.gif']}},
				{ 'major_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-amber.gif']}},
				{ 'critical_net_icon' => { display => 'text', value => ['<menu_url_base>/img/network-red.gif']}}
		],

		'authentication' => [
				{ 'auth_require' => { display => 'popup', value => ['true','false']}},
				{ 'auth_method_1' => { display => 'popup', value => ['apache','htpasswd','radius','tacacs','ldap','ldaps','ms-ldap']}},
				{ 'auth_method_2' => { display => 'popup', value => ['apache','htpasswd','radius','tacacs','ldap','ldaps','ms-ldap']}},
				{ 'auth_expire' => { display => 'text', value => ['+20min']}},
				{ 'auth_htpasswd_encrypt' => { display => 'popup', value => ['crypt','md5','plaintext']}},
				{ 'auth_htpasswd_file' => { display => 'text', value => ['<nmis_conf>/users.dat']}},
				{ 'auth_ldap_server' => { display => 'text', value => ['']}},
				{ 'auth_ldaps_server' => { display => 'text', value => ['']}},
				{ 'auth_ldap_attr' => { display => 'text', value => ['']}},
				{ 'auth_ldap_context' => { display => 'text', value => ['']}},
				{ 'auth_ms_ldap_server' => { display => 'text', value => ['']}},
				{ 'auth_ms_ldap_dn_acc' => { display => 'text', value => ['']}},
				{ 'auth_ms_ldap_dn_psw' => { display => 'text', value => ['']}},
				{ 'auth_ms_ldap_base' => { display => 'text', value => ['']}},
				{ 'auth_ms_ldap_attr' => { display => 'text', value => ['']}},
				{ 'auth_radius_server' => { display => 'text', value => ['']}},
				{ 'auth_radius_secret' => { display => 'text', value => ['secret']}},
				{ 'auth_tacacs_server' => { display => 'text', value => ['']}},
				{ 'auth_tacacs_secret' => { display => 'text', value => ['secret']}},
				{ 'auth_web_key' => { display => 'text', value => ['thisismysecretkey']}}
		],

		'escalation' => [
				{ 'escalate0' => { display => 'text', value => ['300']}},
				{ 'escalate1' => { display => 'text', value => ['900']}},
				{ 'escalate2' => { display => 'text', value => ['1800']}},
				{ 'escalate3' => { display => 'text', value => ['2400']}},
				{ 'escalate4' => { display => 'text', value => ['3000']}},
				{ 'escalate5' => { display => 'text', value => ['3600']}},
				{ 'escalate6' => { display => 'text', value => ['7200']}},
				{ 'escalate7' => { display => 'text', value => ['10800']}},
				{ 'escalate8' => { display => 'text', value => ['21600']}},
				{ 'escalate9' => { display => 'text', value => ['43200']}},
				{ 'escalate10' => { display => 'text', value => ['86400']}}
		],

		'daemons' => [
				{ 'daemon_ipsla_active' => { display => 'popup', value => ['true','false']}},
				{ 'daemon_ipsla_filename' => { display => 'text', value => ['ipslad.pl']}},
				{ 'daemon_fping_active' => { display => 'popup', value => ['true','false']}},
				{ 'daemon_fping_filename' => { display => 'text', value => ['fpingd.pl']}}
		],

		'metrics' => [
				{ 'weight_availability' => { display => 'text', value => ['0.1']}},
				{ 'weight_int' => { display => 'text', value => ['0.2']}},
				{ 'weight_mem' => { display => 'text', value => ['0.1']}},
				{ 'weight_cpu' => { display => 'text', value => ['0.1']}},
				{ 'weight_reachability' => { display => 'text', value => ['0.3']}},
				{ 'weight_response' => { display => 'text', value => ['0.2']}},
				{ 'metric_health' => { display => 'text', value => ['0.4']}},
				{ 'metric_availability' => { display => 'text', value => ['0.2']}},
				{ 'metric_reachability' => { display => 'text', value => ['0.4']}}
		],

		'graph' => [
				{ 'graph_amount' => { display => 'text', value => ['48']}},
				{ 'graph_unit' => { display => 'text', value => ['hours']}},
				{ 'graph_factor' => { display => 'text', value => ['2']}},
				{ 'graph_width' => { display => 'text', value => ['700']}},
				{ 'graph_height' => { display => 'text', value => ['250']}},
				{ 'graph_split' => { display => 'popup', value => ['true','false']}},
				{ 'win_width' => { display => 'text', value => ['835']}},
				{ 'win_height' => { display => 'text', value => ['570']}}
		],

		'tables NMIS4' => [
				{ 'Interface_Table' => { display => 'text', value => ['']}},
				{ 'Interface_Key' => { display => 'text', value => ['']}},
				{ 'Escalation_Table' => { display => 'text', value => ['']}},
				{ 'Escalation_Key' => { display => 'text', value => ['']}},
				{ 'Locations_Table' => { display => 'text', value => ['']}},
				{ 'Locations_Key' => { display => 'text', value => ['']}},
				{ 'Nodes_Table' => { display => 'text', value => ['']}},
				{ 'Nodes_Key' => { display => 'text', value => ['']}},
				{ 'Users_Table' => { display => 'text', value => ['']}},
				{ 'Users_Key' => { display => 'text', value => ['']}},
				{ 'Contacts_Table' => { display => 'text', value => ['']}},
				{ 'Contacts_Key' => { display => 'text', value => ['']}}
 			],

		'mibs' => [
				{ 'full_mib' => { display => 'text', value => ['nmis_mibs.oid']}}
		],
			
		'database' => [
				{ 'db_events_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_nodes_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_users_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_locations_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_contacts_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_privmap_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_escalations_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_services_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_iftypes_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_access_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_logs_sql' => { display => 'popup', value => ['true','false']}},
				{ 'db_links_sql' => { display => 'popup', value => ['true','false']}}
		]
	);

	return \%Cfg;
}

sub loadRMENodes {

	my $file = shift;

	my %nodeTable;

	my $C = loadConfTable();

	my $ciscoHeader = "Cisco Systems NM";
	my @nodedetails;
	my @statsSplit;
	my $nodeType;

	if ( $file eq "" ) {
		print "\t the type=rme option requires a file arguement for source rme CSV file\ni.e. $0 type=rme rmefile=/data/file/rme.csv\n";
		return;
	}

	sysopen(DATAFILE, "$file", O_RDONLY) or warn returnTime." loadRMENodes, Cannot open $file. $!\n";
	flock(DATAFILE, LOCK_SH) or warn "loadRMENodes, can't lock filename: $!";
	while (<DATAFILE>) {
	        chomp;
		# Don't want comments 
	        if ( $_ !~ /^\;|^$ciscoHeader/ ) {
			# whack all the splits into an array
			(@nodedetails) = split ",", $_;
		
			# check that the device is to be included in STATS
			$nodedetails[4] =~ s/ //g;
			@statsSplit = split(":",$nodedetails[4]);
			if ( $statsSplit[0] =~ /t/ ) {
				# sopme defaults
				$nodeTable{$nodedetails[0]}{depend} = "N/A";
				$nodeTable{$nodedetails[0]}{runupdate} = "false";
				$nodeTable{$nodedetails[0]}{snmpport} = "161";
				$nodeTable{$nodedetails[0]}{active} = "true";
				$nodeTable{$nodedetails[0]}{group} = "RME";

				$nodeTable{$nodedetails[0]}{host} = $nodedetails[0];
				$nodeTable{$nodedetails[0]}{community} = $nodedetails[1];
				$nodeTable{$nodedetails[0]}{netType} = $statsSplit[1];
				$nodeTable{$nodedetails[0]}{nodeType} = $statsSplit[2];
				# Convert role c, d or a to core, distribution or access
				if ( $statsSplit[3] eq "c" ) { $nodeTable{$nodedetails[0]}{roleType} = "core"; }
				elsif ( $statsSplit[3] eq "d" ) { $nodeTable{$nodedetails[0]}{roleType} = "distribution"; }
				elsif ( $statsSplit[3] eq "a" ) { $nodeTable{$nodedetails[0]}{roleType} = "access"; }
				# Convert collect t or f to  true or false
				if ( $statsSplit[4] eq "t" ) { $nodeTable{$nodedetails[0]}{collect} = "true"; }
				elsif ( $statsSplit[4] eq "f" ) { $nodeTable{$nodedetails[0]}{collect} = "false"; }
			}
		}
	}
	close(DATAFILE) or warn "loadRMENodes, can't close filename: $!";
	writeNodesFile("$C->{Nodes_Table}.new",\%nodeTable);
}

# load servers info table
sub loadServersTable {
	return loadTable(dir=>'conf',name=>'Servers');
}

# !! this sub intended for write on var/nmis-event.xxxx only with a previously open filehandle !!
# The lock on the open file must be maintained while the hash is being updated
# to prevent another thread from opening and writing some other changes before we write our thread's hash copy back
# we also need to make sure that we process the hash quickly, to avoid multithreading becoming singlethreading,
# because of the lock being maintained on nmis-event.xxxx

sub writeEventStateLock {
	my %args = @_;
	my $ET = $args{table};
	my $handle = $args{handle};

	writeTable(dir=>'var',name=>'nmis-event',data=>$ET,handle=>$handle);

#	$ET_cache = undef;

	return;
}

# improved locking on var/nmis-event.xxxx
# this sub intended for read on nmis-event.xxxx only

sub loadEventStateNoLock {
	my %args = @_;
	my $type = $args{type};
	
	my $table = defined $args{table} ? $args{table} : "nmis-event";

	my @eventdetails;
	my $node;
	my $event;
	my $level;
	my $details;
	my $event_hash;
	my %eventTable;
	my $modtime;

	my $C = loadConfTable();

	if (getbool($C->{db_events_sql})) {
		if ($type eq 'Node_Down') {	# used by fpingd
			return DBfunc::->select(table=>'Events',column=>'event,node,element',where=>'event=\'Node Down\'');
		} else {
			return DBfunc::->select(table=>'Events');	# full table
		}
	} else {
		# does the file exist
		if ( not -r getFileName(file => "$C->{'<nmis_var>'}/$table") ) {
			my %hash = ();
			writeTable(dir=>'var',name=>"$table",data=>\%hash); # create an empty file
		}
		my $ET = loadTable(dir=>'var',name=>"$table");
		return $ET;
	}
}

# !!!this sub intended for read and LOCK on nmis-event.xxxx only - MUST use writeEventStateLock to write the hash back from this call!!!
# need to maintain a lock on the file while the event hash is being processed by this thread
# must pass our filehandle back to writeEventStateLock
sub loadEventStateLock {

	my $C = loadConfTable();

	if (getbool($C->{db_events_sql})) {
		logMsg("ERROR (nmis) loadEventStateLock not supported by SQL active");
		return (undef,undef);
	} else {
		return loadTable(dir=>'var',name=>'nmis-event',lock=>'true');
	}
}

### 2011-01-06 keiths, loading node summary from cached files!
sub loadNodeSummary {
	my %args = @_;
	my $group = $args{group};
	my $master = $args{master};

	my $C = loadConfTable();
	my $SUM;
	
	my $nodesum = "nmis-nodesum";
	# I should now have an up to date file, if I don't log a message
	if (existFile(dir=>'var',name=>$nodesum) ) {
		my $NS = loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			if ( $group eq "" or $group eq $NS->{$node}{group} ) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}

	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if (getbool($C->{server_master}) or getbool($master)) {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";
			
			my $slavenodesum = "nmis-$srv-nodesum";
			dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavenodesum) ) {
				my $NS = loadTable(dir=>'var',name=>$slavenodesum);
				for my $node (keys %{$NS}) {
					if ( $group eq "" or $group eq $NS->{$node}{group} ) {
						for (keys %{$NS->{$node}}) {
							$SUM->{$node}{$_} = $NS->{$node}{$_};
						}
					}
				}
			}
		}
	}
	
	return $SUM;
}	
	
sub runEventDebug {
	my ($ET,$handle);
	($ET,$handle) = loadEventStateLock();
	writeEventStateLock(table=>$ET,handle=>$handle);
}

sub eventHash {
	# Calculate the event hash the same way everytime.
 	#build an event hash string
	my $node = shift;
	my $event = shift;
	my $element = shift;

	# MD - remove code that trimmed the event, it was causing issues and 
	# we have no idea why it was there in the first place
	#
	my $hash = lc "${node}-${event}-${element}";
	$hash =~ s#[ /:]#_#g;
	return $hash; 
}

sub eventExist {
	my $node = shift;
	my $event = shift;
	my $element = shift;

	my $C = loadConfTable();

	my $event_hash = eventHash($node,$event,$element);
	my $ET;

	if (getbool($C->{db_events_sql})) {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		$ET = loadEventStateNoLock();
	}

	if ( exists $ET->{$event_hash} and getbool($ET->{$event_hash}{current})) {
		return 1;
	}
	else {
		return 0; 
	} 
}

sub checkEvent {	
	# Check event is called after determining that something is up!
	# Check event sees if an event for this node/interface exists 
	# if it exists it deletes it from the event state table/log
	# and then calls notify with the Up event including the time of the outage
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $node = $S->{node};
	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $log;
	my $syslog;
	
	my $C = loadConfTable();

	# events.nmis controls which events are active/logging/notifying
	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};
	
	# just in case this is blank.
	if ( $C->{'non_stateful_events'} eq '' ) {
	 $C->{'non_stateful_events'} = 'Node Configuration Change, Node Reset';
	}

	if ( $C->{'threshold_falling_reset_dampening'} eq '' ) {
	 $C->{'threshold_falling_reset_dampening'} = 1.1;
	}

	if ( $C->{'threshold_rising_reset_dampening'} eq '' ) {
	 $C->{'threshold_rising_reset_dampening'} = 0.9;
	}

	my $event_hash = eventHash($node,$event,$element);

	# load the event State for reading only.
	my $ET;
	if ($S->{ET} ne '') {
		# event table already loaded in sys object
		$ET = $S->{ET};
	} else {
		if (getbool($C->{db_events_sql})) {
			$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
		} else {
			$ET = loadEventStateNoLock();
		}
	}
	

	my $outage;

	if (exists $ET->{$event_hash} 
			and getbool($ET->{$event_hash}{current})) {
		# The opposite of this event exists, so log an UP and delete the original event

		# save some stuff, as we cant rely on the hash after the write 
		my $escalate = $ET->{$event_hash}{escalate};
		# the event length for logging
		$outage = convertSecsHours(time() - $ET->{$event_hash}{startdate});

		# Just log an up event now.
		if ( $event eq "Node Down" ) {
			$event = "Node Up";
		}
		elsif ( $event eq "Interface Down" ) {
			$event = "Interface Up";
		}
		elsif ( $event eq "RPS Fail" ) {
			$event = "RPS Up";
		}
		elsif ( $event =~ /Proactive/ ) {
			# but only if we have cleared the threshold by 10%
			# for thresholds where high = good (default 1.1)
			if ( defined($args{value}) and defined($args{reset}) ) {
				if ( $args{value} >= $args{reset} ) {
					return unless $args{value} > $args{reset} * $C->{'threshold_falling_reset_dampening'};
				} else {
				# for thresholds where low = good (default 0.9)
					return unless $args{value} < $args{reset} * $C->{'threshold_rising_reset_dampening'};
				}
			}
			$event = "$event Closed";
		}
		elsif ( $event =~ /^Alert/ ) {
			# A custom alert is being cleared.
			$event = "$event Closed";
		}
		elsif ( $event =~ /down/i ) {
			$event =~ s/down/Up/i;
		}
		
		# event was renamed/inverted/massaged, need to get the right control record
		# this is likely not needed
		$thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

		$details = "$details Time=$outage";
		$ET->{$event_hash}{current} = 'false'; # next processing by escalation routine

		($level,$log,$syslog) = getLevelLogEvent(sys=>$S,event=>$event,level=>'Normal');

		my $OT = loadOutageTable();
		
		my ($otg,$key) = outageCheck(node=>$node,time=>time());
		if ($otg eq 'current') {
			$details = "$details change=$OT->{$key}{change}";
		}

		if (getbool($C->{db_events_sql})) {
			dbg("event $event_hash marked for UP notify and delete");
			DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
		} else {
			# re-open the file with a lock, as we to wish to update
			my ($ETL,$handle) = loadEventStateLock();
			# make sure we still have a valid event
			if ( getbool($ETL->{$event_hash}{current})) {
				dbg("event $event_hash marked for UP notify and delete");
				$ETL->{$event_hash}{current} = 'false';
				### 2013-02-07 keiths, fixed stateful event properties not clearing.
				$ETL->{$event_hash}{event} = $event;
				$ETL->{$event_hash}{details} = $details;
				$ETL->{$event_hash}{level} = $level;
			}
			writeEventStateLock(table=>$ETL,handle=>$handle);
		}

		if (getbool($log) and getbool($thisevent_control->{Log})) {
			logEvent(node=>$S->{name},event=>$event,level=>$level,element=>$element,details=>$details);
		}

		# Syslog must be explicitly enabled in the config and will escalation is not being used.
		if (getbool($C->{syslog_events}) and getbool($syslog)
				and getbool($thisevent_control->{Log})
				and !getbool($C->{syslog_use_escalation})) {
			sendSyslog(
				server_string => $C->{syslog_server},
				facility => $C->{syslog_facility},
				nmis_host => $C->{server_name},
				time => time(),
				node => $S->{name},
				event => $event,
				level => $level,
				element => $element,
				details => $details
			);
		}
	}
}

sub notify {
	### notify is write to current event state table !!!!! regardless of outage status
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $node = $S->{name};
	my $log;
	my $syslog;

	my $C = loadConfTable();

	dbg("Start of Notify");
	
	# events.nmis controls which events are active/logging/notifying
	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

	my $event_hash = eventHash($S->{name},$event,$element);
	my $ET;

	if ($S->{ET} ne '') {
		# event table already loaded in sys object
		$ET = $S->{ET};
	} else {
		if (getbool($C->{db_events_sql})) {
			$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
		} else {
			$ET = loadEventStateNoLock();
		}
	}

	### 2014-09-01 keiths, fixing up an autovification problem.
	if ( exists $ET->{$event_hash} and getbool($ET->{$event_hash}{current})) {
		# event exists, maybe a level change of proactive threshold
		if ($event =~ /Proactive|Alert\:/ ) {
			if ($ET->{$event_hash}{level} ne $level) {
				# change of level
				$ET->{$event_hash}{level} = $level; # update cache
				if (getbool($C->{db_events_sql})) {
					DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
				} else {
					my ($ETL,$handle) = loadEventStateLock();
					$ETL->{$event_hash}{level} = $level;
					### 2014-08-27 keiths, update the details as well when changing the level
					$ETL->{$event_hash}{details} = $details;
					writeEventStateLock(table=>$ETL,handle=>$handle);
				}
				my $tmplevel;
				($tmplevel,$log,$syslog) = getLevelLogEvent(sys=>$S,event=>$event,level=>$level);
				$details .= " Updated";
			}
		} else {
			dbg("Event node=$node event=$event element=$element already in Event table");
		}
	} else {
		# get level(if not defined) and log status from Model
		($level,$log,$syslog) = getLevelLogEvent(sys=>$S,event=>$event,level=>$level);

		if ($C->{non_stateful_events} !~ /$event/ or getbool($thisevent_control->{Stateful})) {
			# Push the event onto the event table if it is a stateful one
			eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
		}
		else {
			eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details,stateless=>"true");
			# a stateless event should escalate to a level and then be automatically deleted.
		}
		
		if (getbool($C->{log_node_configuration_events}) and $C->{node_configuration_events} =~ /$event/
				and getbool($thisevent_control->{Log})) 
		{
			logConfigEvent(dir => $C->{config_logs}, node=>$node, event=>$event, level=>$level,
										 element=>$element, details=>$details, host => $NI->{system}{host}, 
										 nmis_server => $C->{nmis_host} );			
		}
	}
	# log events
	if ( getbool($log) and getbool($thisevent_control->{Log})) {
		logEvent(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
	}

	# Syslog must be explicitly enabled in the config and will escalation is not being used.
	if (getbool($C->{syslog_events}) 
			and getbool($syslog)
			and getbool($thisevent_control->{Log})
			and !getbool($C->{syslog_use_escalation})) {
		sendSyslog(
			server_string => $C->{syslog_server},
			facility => $C->{syslog_facility},
			nmis_host => $C->{server_name},
			time => time(),
			node => $node,
			event => $event,
			level => $level,
			element => $element,
			details => $details
		);
	}

	dbg("Finished");
} # end notify

# this is the most official reporter of node status, and should be
# used instead of just looking at local system info nodedown
#
# reason: underlying events state can change asynchronously (eg. fpingd),
# and the per-node status from the node file cannot be guaranteed to
# be up to date if that happens.
#
# note: nodestatus DOES LOCK UP EVERYTHING HARD if used while
# an exclusive lock on the event state file is held!
# (ie. between loadEventStateLock and writeEventStateLock)
sub nodeStatus {
	my %args = @_;
	my $NI = $args{NI};

	my $C = loadConfTable();

	# 1 for reachable
	# 0 for unreachable
	# -1 for degraded
	my $status = 1;
	
	my $node_down = "Node Down";
	my $snmp_down = "SNMP Down";

	# ping disabled ->  snmp state is authoritative
	if ( getbool($NI->{system}{ping},"invert") and eventExist($NI->{system}{name}, $snmp_down, "") ) {
		$status = 0;
	}
	# ping enabled, but unpingable -> down
	elsif ( eventExist($NI->{system}{name}, $node_down, "") ) {
		$status = 0;
	}
	# ping enabled, pingable but dead snmp -> degraded
	elsif ( eventExist($NI->{system}{name}, $snmp_down, "") ) {
		$status = -1;
	}
	# let NMIS use the status summary calculations
	elsif (
		defined $C->{node_status_uses_status_summary}
		and getbool($C->{node_status_uses_status_summary})
		and defined $NI->{system}{status_summary} 
		and defined $NI->{system}{status_updated} 
		and $NI->{system}{status_summary} <= 99
		and $NI->{system}{status_updated} > time - 500
	) {
		$status = -1;
	}
	else {
		$status = 1;
	}
	
	return $status;
}

sub logConfigEvent {
	my %args = @_;
	my $dir = $args{dir};
	delete $args{dir};

	dbg("logConfigEvent logging Json event for event $args{event}");
	my $event_hash = \%args;
	$event_hash->{startdate} = time;
	logJsonEvent(event => $event_hash, dir => $dir);
}

sub getLevelLogEvent {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $event = $args{event};
	my $level = $args{level};

	my $mdl_level;
	my $log = 'true';
	my $syslog = 'true';
	my $pol_event;

	my $role = $NI->{system}{roleType} || 'access' ;
	my $type = $NI->{system}{nodeType} || 'router' ;

	# Get the event policy and the rest is easy.
	if ( $event !~ /^Proactive|^Alert/i ) {
		# proactive does already level defined
		if ( $event =~ /down/i and $event !~ /SNMP|Node|Interface|Service/i ) { 
			$pol_event = "Generic Down";
		}
		elsif ( $event =~ /up/i and $event !~ /SNMP|Node|Interface|Service/i ) { 
			$pol_event = "Generic Up";
		}
		else { $pol_event = $event; }

		# get the level and log from Model of this node
		if ($mdl_level = $M->{event}{event}{lc $pol_event}{lc $role}{level}) {
			$log = $M->{event}{event}{lc $pol_event}{lc $role}{logging};
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog} if ($M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "");
		} 
		elsif ($mdl_level = $M->{event}{event}{default}{lc $role}{level}) {
			$log = $M->{event}{event}{default}{lc $role}{logging};
			$syslog = $M->{event}{event}{default}{lc $role}{syslog} if ($M->{event}{event}{default}{lc $role}{syslog} ne "");
		} 
		else {
			$mdl_level = 'Major';
			# not found, use default
			logMsg("node=$NI->{system}{name}, event=$event, role=$role not found in class=event of model=$NI->{system}{nodeModel}"); 
		}
	}
	elsif ( $event =~ /^Alert/i ) {
		# Level set by custom!
		### 2013-03-08 keiths, adding policy based logging for Alerts.
		# We don't get the level but we can get the logging policy.
		$pol_event = "Alert";
		if ($log = $M->{event}{event}{lc $pol_event}{lc $role}{logging}) {
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog} if ($M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "");
		}
	}
	else {
		### 2012-03-02 keiths, adding policy based logging for Proactive.
		# We don't get the level but we can get the logging policy.
		$pol_event = "Proactive";
		if ($log = $M->{event}{event}{lc $pol_event}{lc $role}{logging}) {
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog} if ($M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "");
		} 		
	}
	# overwrite the level argument if it wasn't set AND if the models reported something useful
	if ($mdl_level && !defined $level) {
		$level = $mdl_level;
	}
	return ($level,$log,$syslog);
}

# Throw an Event to the event log
sub logEvent {	
	my %args = @_;
	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	$details =~ s/,//g; # strip any commas

	if ( $node eq "" or $event eq "" or $level eq "" ) {
		logMsg("ERROR with event, something is NULL node=$node, event=$event, level=$level"); 
	}

	my $time = time();
	my $C = loadConfTable();
	
	sysopen(DATAFILE, "$C->{event_log}", O_WRONLY | O_APPEND | O_CREAT)
		 or warn returnTime." logEvent, Couldn't open file $C->{event_log}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "logEvent, can't lock filename: $!";
	print DATAFILE "$time,$node,$event,$level,$element,$details\n";
	close(DATAFILE) or warn "logEvent, can't close filename: $!"; 
	#
	setFileProt($C->{event_log}); # set file owner/permission, default: nmis, 0775
}

sub eventAdd {
	my %args = @_;
	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $stateless = $args{stateless} || "false";

	my $C = loadConfTable();

	my $ET;
	my $handle;
	my $new_event = 0;
	my $event_hash = eventHash($node,$event,$element);

	if (getbool($C->{db_events_sql})) {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		($ET,$handle) = loadEventStateLock();
	}

	# is this a stateless event, they will reset after the dampening time, default dampen of 15 minutes.
	if ( exists $ET->{$event_hash} and getbool($ET->{$event_hash}{stateless}) ) {
		my $stateless_event_dampening =  $C->{stateless_event_dampening} || 900;
		# if the stateless time is greater than the dampening time, reset the escalate.
		if ( time() > $ET->{$event_hash}{startdate} + $stateless_event_dampening ) {
			$ET->{$event_hash}{current} = 'true';
			$ET->{$event_hash}{startdate} = time();
			$ET->{$event_hash}{escalate} = -1;
			$ET->{$event_hash}{ack} = 'false';			
			dbg("event stateless, node=$node, event=$event, level=$level, element=$element, details=$details");
		}
	}
	# before we log check the state table if there is currently an event outstanding.
	elsif ( exists $ET->{$event_hash} and getbool($ET->{$event_hash}{current})) {
		dbg("event exist, node=$node, event=$event, level=$level, element=$element, details=$details");
		##	logMsg("INFO event exist, node=$node, event=$event, level=$level, element=$element, details=$details");
	}
	else {
		$ET->{$event_hash}{current} = 'true';
		$ET->{$event_hash}{startdate} = time();
		$ET->{$event_hash}{node} = $node;
		$ET->{$event_hash}{event} = $event;
		$ET->{$event_hash}{level} = $level;
		$ET->{$event_hash}{element} = $element;
		$ET->{$event_hash}{details} = $details;
		$ET->{$event_hash}{ack} = 'false';
		$ET->{$event_hash}{escalate} = -1;
		$ET->{$event_hash}{notify} = "";
		$ET->{$event_hash}{stateless} = $stateless;
		$new_event = 1;
		dbg("event added, node=$node, event=$event, level=$level, element=$element, details=$details");
		##	logMsg("INFO event added, node=$node, event=$event, level=$level, element=$element, details=$details");
	}

	if (getbool($C->{db_events_sql})) {
		if ($new_event) {
			$ET->{$event_hash}{index} = $event_hash;
			DBfunc::->insert(table=>'Events',data=>$ET->{$event_hash}) ;
		}
	} else {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}
	return;
} # eventAdd

sub eventAck {
	my %args = @_;
	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $ack = $args{ack};
	my $user = $args{user};
	my $event_hash;

	my $C = loadConfTable();
	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql

	my $delete_event = 0;
	my ($ET,$handle);
	$event_hash = eventHash($node,$event,$element);

	# event control is as configured or all true.
	my $thisevent_control = $events_config->{$ET->{$event_hash}->{event}} || { Log => "true", Notify => "true", Status => "true"};

	if (getbool($C->{db_events_sql})) {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		($ET,$handle) = loadEventStateLock();
	}
	# make sure we still have a valid event
	if ( exists $ET->{$event_hash} and getbool($ET->{$event_hash}{current})) {
		if ( getbool($ack) and getbool($ET->{$event_hash}{ack},"invert")) {
			### if a TRAP type event, then trash when ack. event record will be in event log if required
			if ( $ET->{$event_hash}{event} eq "TRAP" ) {
				logEvent(node => $ET->{$event_hash}{node}, event => "deleted event: $ET->{$event_hash}{event}", 
								 level => "Normal", element => $ET->{$event_hash}{element})
						# log the deletion meta-event iff the original event had logging enabled
						if (getbool($thisevent_control->{Log}));

				delete $ET->{$event_hash};
				$delete_event = 1;
			}
			else {
				logEvent(node => $node, event => $event, level => "Normal", element => $element, details => "acknowledge=true ($user)")
						# log the ack meta-event iff the original event had logging enabled
						if (getbool($thisevent_control->{Log}));
				
				$ET->{$event_hash}{ack} = "true";
				$ET->{$event_hash}{user} = $user;
			}
		}
		elsif ( getbool($ack,"invert") and getbool($ET->{$event_hash}{ack})) {
			logEvent(node => $node, event => $event, level => $ET->{$event_hash}{level}, element => $element, details => "acknowledge=false ($user)")
					if (getbool($thisevent_control->{Log}));
			$ET->{$event_hash}{ack} = "false";
			$ET->{$event_hash}{user} = $user;
		}
	}
	if (getbool($C->{db_events_sql})) {
		if ($delete_event) {
			DBfunc::->delete(table=>'Events',index=>$event_hash);
		} else {
			DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
		}
	} else {
		writeEventStateLock(table=>$ET,handle=>$handle);
	}
} # eventAck


sub getSummaryStats{
	my %args = @_;
	my $type = $args{type};
	my $index = $args{index}; # optional
	my $item = $args{item};
	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $M  = $S->mdl;

	my $C = loadConfTable();
	if (getbool($C->{server_master}) and $NI->{system}{server} and lc($NI->{system}{server}) ne lc($C->{server_name})) {
		# send request to remote server
		dbg("serverConnect to $NI->{system}{server} for node=$S->{node}");
		#return serverConnect(server=>$NI->{system}{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index,item=>$item);
	}

	my $db;
	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats;

	dbg("Start type=$type, index=$index, start=$start, end=$end");

	# check if type exist in nodeInfo
	if (!($db = $S->getDBName(graphtype=>$type,index=>$index,item=>$item))) {
		return; # Error
	}

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$type} eq "") {
		logMsg("ERROR, ($S->{name}) type=$type not found in section stats of model=$NI->{system}{nodeModel}");
		return;
	}

	# check if rrd file exist
	if ( -r $db ) {
		push @option, ("--start", "$start", "--end", "$end") ;

		{
			no strict;
			$database = $db; # global
			$speed = $IF->{$index}{ifSpeed} if $index ne "";
			$inSpeed = $IF->{$index}{ifSpeed} if $index ne "";
			$outSpeed = $IF->{$index}{ifSpeed} if $index ne "";
			$inSpeed = $IF->{$index}{ifSpeedIn} if $index ne "" and $IF->{$index}{ifSpeedIn};
			$outSpeed = $IF->{$index}{ifSpeedOut} if $index ne "" and $IF->{$index}{ifSpeedOut};

			# read from Model and translate variable ($database etc.) rrd options
			foreach my $str (@{$M->{stats}{type}{$type}}) {
				my $s = $str;
				$s =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
				if ($s =~ /ERROR/) {
					logMsg("ERROR ($S->{name}) model=$NI->{system}{nodeModel} type=$type ($str) in expanding variables, $s");
					return; # error
				}
				push @option, $s;
			}
		}
		if (getbool($C->{debug})) {
			foreach (@option) {
				dbg("option=$_",2);
			}
		}

		($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
		if (($ERROR = RRDs::error)) { 
			logMsg("ERROR ($S->{name}) RRD graph error database=$db: $ERROR");
		} else {
			##logMsg("INFO result type=$type, node=$NI->{system}{name}, $NI->{system}{nodeType}, $NI->{system}{nodeModel}, @$graphret");   
			if ( scalar(@$graphret) ) {
				map { s/nan/NaN/g } @$graphret;			# make sure a NaN is returned !!
				foreach my $line ( @$graphret ) {
					my ($name,$value) = split "=", $line;
					if ($index ne "") {
						$summaryStats{$index}{$name} = $value; # use $index as primairy key
					} else {
						$summaryStats{$name} = $value;
					}
					dbg("name=$name, index=$index, value=$value",2);
					##logMsg("INFO name=$name, index=$index, value=$value");
				}
				return \%summaryStats;
			} else {
				logMsg("INFO ($S->{name}) no info return from RRD for type=$type index=$index item=$item");
			}
		}
	} else {
		logMsg("ERROR ($S->{name}) database=$db does not exists or is protected for read");
	}
	return;
}

### 2011-12-29 keiths, added for consistent nodesummary generation
sub getNodeSummary {
	my %args = @_;
	my $C = $args{C};
	my $group = $args{group};
	
	my $NT = loadLocalNodeTable();
	my $ET = loadEventStateNoLock();
	my $OT = loadOutageTable();
	my %nt;
	
	### 2015-01-13 keiths, making the field list configurable, these are extra properties, there will be some mandatory ones.
	my $node_summary_field_list = "customer,businessService";
	if ( defined $C->{node_summary_field_list} and $C->{node_summary_field_list} ne "" ) {
		$node_summary_field_list = $C->{node_summary_field_list};
	}
	
	my @node_summary_properties = split(",",$node_summary_field_list);
	
	foreach my $nd (keys %{$NT}) {
		next if (!getbool($NT->{$nd}{active}));
		next if $group ne '' and $NT->{$nd}{group} !~ /$group/;

		my $NI = loadNodeInfoTable($nd);

		$nt{$nd}{name} = $NI->{system}{name};
		$nt{$nd}{group} = $NI->{system}{group};
		$nt{$nd}{collect} = $NI->{system}{collect};
		$nt{$nd}{active} = $NT->{$nd}{active};
		$nt{$nd}{ping} = $NT->{$nd}{ping};
		$nt{$nd}{netType} = $NI->{system}{netType};
		$nt{$nd}{roleType} = $NI->{system}{roleType};
		$nt{$nd}{nodeType} = $NI->{system}{nodeType};
		$nt{$nd}{nodeModel} = $NI->{system}{nodeModel};
		$nt{$nd}{nodeVendor} = $NI->{system}{nodeVendor};
		$nt{$nd}{lastUpdateSec} = $NI->{system}{lastUpdateSec};
		$nt{$nd}{sysName} = $NI->{system}{sysName} ;
		$nt{$nd}{server} = $C->{'server_name'};

		foreach my $property (@node_summary_properties) {
			$nt{$nd}{$property} = $NI->{system}{$property};
		}
		
		#
		$nt{$nd}{nodedown} = $NI->{system}{nodedown};
		my $event_hash = eventHash($nd, "Node Down", "Node");
		$nt{$nd}{escalate} = $ET->{$event_hash}{escalate};

		### adding node_status to the summary data
		# check status from event db
		my $nodestatus = nodeStatus(NI => $NI);
		if ( not $nodestatus ) {
			$nt{$nd}{nodestatus} = "unreachable";
		}
		elsif ( $nodestatus == -1 ) {
			$nt{$nd}{nodestatus} = "degraded";
		}
		else {
			$nt{$nd}{nodestatus} = "reachable";
		}
		
		my ($otgStatus,$otgHash) = outageCheck(node=>$nd,time=>time());
		my $outageText;
		if ( $otgStatus eq "current" or $otgStatus eq "pending") {
			my $color = ( $otgStatus eq "current" ) ? "#00AA00" : "#FFFF00";
		
			my $outageText = "node=$OT->{$otgHash}{node}<br>start=".returnDateStamp($OT->{$otgHash}{start})
			."<br>end=".returnDateStamp($OT->{$otgHash}{end})."<br>change=$OT->{$otgHash}{change}";
		}
		$nt{$nd}{outage} = $otgStatus;
		$nt{$nd}{outageText} = $outageText;

		# If sysLocation is formatted for GeoStyle, then remove long, lat and alt to make display tidier
		my $sysLocation = $NI->{system}{sysLocation};
		if (($NI->{system}{sysLocation}  =~ /$C->{sysLoc_format}/ ) and $C->{sysLoc} eq "on") {  
			# Node has sysLocation that is formatted for Geo Data
			( my $lat, my $long, my $alt, $sysLocation) = split(',',$NI->{system}{sysLocation});
		}
		$nt{$nd}{sysLocation} = $sysLocation ;
	}
	return \%nt;
}

### AS 9/4/01 added getGroupSummary for doing the metric stuff centrally!
### AS 24/5/01 fixed so that colors show for things which aren't complete
### also reweighted the metric to be reachability = %40, availability = %20
### and health = %40
### AS 16 Mar 02, implementing David Gay's requirement for deactiving
### a node, ie keep a node in nodes.csv but no collection done.
### AS 16 Mar 02, implemented configurable reachability, availability, health
### AS 3 Jun 02, fixed up blank dash, insert N/A for nasty things
### ehg 17 sep 02 add nan to the trap for nasty things
### ehg 17 sep 02 counted actual nodes down for summary display
sub getGroupSummary {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $start_time = $args{start};
	my $end_time = $args{end};

	my @tmpsplit;
	my @tmparray;

	my $SUM = undef;
	my $reportStats;
	my %nodecount = ();
	my $node;
	my $index;
	my $cache = 0;
	my $filename;

	dbg("Starting");

	my (@devicelist,$i,@nodedetails);
	# init the hash, so zero values display
	$nodecount{counttotal} = 0;
	$nodecount{countup} = 0;
	$nodecount{countdown} = 0;
	$nodecount{countdegraded} = 0;

	my $S = Sys::->new;
	my $NT = loadNodeTable(); # local + nodes of remote servers
	my $C = loadConfTable();

	my $master_server_priority = $C->{master_server_priority} || 10;

	### 2014-08-28 keiths, configurable metric periods
	my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";
	
	if ( $start_time eq "" ) { $start_time = $metricsFirstPeriod; }
	if ( $end_time eq "" ) { $end_time = time; }

	if ( $start_time eq $metricsFirstPeriod ) {
		$filename = "summary8h";
	}
	if ( $start_time eq $metricsSecondPeriod ) {
		$filename = "summary16h";
	}

	# load table (from cache)
	if ($filename ne "") {
		my $mtime;
		if ( (($SUM,$mtime) = loadTable(dir=>'var',name=>"nmis-$filename",mtime=>'true')) ) {
			if ($mtime < (time()-900)) {
				logMsg("INFO (nmis) cache file var/nmis-$filename does not exist or is old; calculate summary");
			} else {
				$cache = 1;
			}
		}
	}	else {
		logMsg("ERROR (nmis) missing summary file specification");
		return;
	}

	dbg("Cache is $cache, filename=$filename"); 
	
	# this server
	unless ($cache) {
		$SUM = {};
		foreach my $node ( keys %{$NT} ) {
			next if ( !getbool($NT->{$node}{active}) or exists $NT->{$node}{server});
			$SUM->{$node}{server_priority} = $master_server_priority;
			$SUM->{$node}{reachable} = 'NaN';
			$SUM->{$node}{response} = 'NaN';
			$SUM->{$node}{loss} = 'NaN';
			$SUM->{$node}{health} = 'NaN';
			$SUM->{$node}{available} = 'NaN';
			$SUM->{$node}{intfCollect} = 0;
			$SUM->{$node}{intfColUp} = 0;
		
			my $stats;
			if (($stats = getSummaryStats(sys=>$S,type=>"health",start=>$start_time,end=>$end_time,index=>$node))) {
				foreach (keys %{$stats}) { $SUM->{$node}{$_} = $stats->{$_};  }
			}
			
			# The other way to get node status is to ask Event State DB. 
			if ( eventExist($node, "Node Down", "") ) {
				$SUM->{$node}{nodedown} = "true";
			}
			else {
				$SUM->{$node}{nodedown} = "false";
			}

		}
	}

	### 2011-12-30 keiths, loading node summary from cached file!
	my $nodesum = "nmis-nodesum";
	# I should now have an up to date file, if I don't log a message
	if (existFile(dir=>'var',name=>$nodesum) ) {
		my $NS = loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			#if ( $group eq "" or $group eq $NS->{$node}{group} ) {
			if ( 	($group eq "" and $customer eq "" and $business eq "") 
				 		or ($group ne "" and $NT->{$node}{group} eq $group)
						or ($customer ne "" and $NT->{$node}{customer} eq $customer)
						or ($business ne "" and $NT->{$node}{businessService} =~ /$business/ )
			) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}


	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if (getbool($C->{server_master})) {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $server_priority = $ST->{$srv}{server_priority} || 5;

			my $slavefile = "nmis-$srv-$filename";
			dbg("Processing Slave $srv for $slavefile");
			
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavefile) ) {
				my $H = loadTable(dir=>'var',name=>$slavefile);
				for my $node (keys %{$H}) {
					if ( not exists $SUM->{$node}
							or $SUM->{$node}{server} eq $srv		
							or ( exists $SUM->{$node}
								and $SUM->{$node}{server_priority}
								and $SUM->{$node}{server_priority} < $server_priority
								)
					) {
						for (keys %{$H->{$node}}) {
							$SUM->{$node}{$_} = $H->{$node}{$_};
						}
						$SUM->{$node}{server_priority} = $server_priority;
						$SUM->{$node}{server} = $srv;
					}
				}
			}

			my $slavenodesum = "nmis-$srv-nodesum";
			dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavenodesum) ) {
				
				my $NS = loadTable(dir=>'var',name=>$slavenodesum);
				for my $node (keys %{$NS}) {
					if ( 	($group eq "" and $customer eq "" and $business eq "") 
				 				or ($group ne "" and $NS->{$node}{group} eq $group)
								or ($customer ne "" and $NS->{$node}{customer} eq $customer)					
								or ($business ne "" and $NS->{$node}{businessService} =~ /$business/)
					) {
						if ( not exists $SUM->{$node}
								or $SUM->{$node}{server} eq $srv		
								or ( exists $SUM->{$node}
									and $SUM->{$node}{server_priority}
									and $SUM->{$node}{server_priority} < $server_priority
									)
						) {
							for (keys %{$NS->{$node}}) {
								$SUM->{$node}{$_} = $NS->{$node}{$_};
							}
							$SUM->{$node}{server_priority} = $server_priority;
							$SUM->{$node}{server} = $srv;
						}
					}
				}
			}
		}
	}
	
	# copy this hash for modification
	my %summaryHash = %{$SUM} if defined $SUM;
	
	# Insert some nice status info about the devices for the summary menu.
NODE:
	foreach $node (sort keys %{$NT} ) {
		# Only do the group - or everything if no group passed to us.
		if (	($group eq "" and $customer eq "" and $business eq "") 
				 	or ($group ne "" and $NT->{$node}{group} eq $group)
					or ($customer ne "" and $NT->{$node}{customer} eq $customer)		
					or ($business ne "" and $NT->{$node}{businessService} =~ /$business/)
		) {
			if ( getbool($NT->{$node}{active}) ) {
				++$nodecount{counttotal};
				my $outage = '';
				# check nodes
				# Carefull logic here, if nodedown is false then the node is up
				#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
				if (getbool($summaryHash{$node}{nodedown})) {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$NT->{$node}{roleType});
					++$nodecount{countdown};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				} 
				elsif (exists $C->{display_status_summary} 
					and getbool($C->{display_status_summary}) 
					and exists $summaryHash{$node}{nodestatus}
					and $summaryHash{$node}{nodestatus} eq "degraded"
				) {
					$summaryHash{$node}{event_status} = "Error";
					$summaryHash{$node}{event_color} = "#ffff00";
					++$nodecount{countdegraded};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				} 
				else {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Up",$NT->{$node}{roleType});
					++$nodecount{countup};
				}

				# dont if outage current with node down
				if ($outage ne 'current') {
					if ( $summaryHash{$node}{reachable} !~ /NaN/i	) {
						++$nodecount{reachable};
						$summaryHash{$node}{reachable_color} = colorHighGood($summaryHash{$node}{reachable});
						$summaryHash{total}{reachable} = $summaryHash{total}{reachable} + $summaryHash{$node}{reachable};
					} else { $summaryHash{$node}{reachable} = "NaN" }
	
					if ( $summaryHash{$node}{available} !~ /NaN/i ) {
						++$nodecount{available};
						$summaryHash{$node}{available_color} = colorHighGood($summaryHash{$node}{available});
						$summaryHash{total}{available} = $summaryHash{total}{available} + $summaryHash{$node}{available};
					} else { $summaryHash{$node}{available} = "NaN" }
	
					if ( $summaryHash{$node}{health} !~ /NaN/i ) {
						++$nodecount{health};
						$summaryHash{$node}{health_color} = colorHighGood($summaryHash{$node}{health});
						$summaryHash{total}{health} = $summaryHash{total}{health} + $summaryHash{$node}{health};
					} else { $summaryHash{$node}{health} = "NaN" }
	
					if ( $summaryHash{$node}{response} !~ /NaN/i ) {
						++$nodecount{response};
						$summaryHash{$node}{response_color} = colorResponseTime($summaryHash{$node}{response});
						$summaryHash{total}{response} = $summaryHash{total}{response} + $summaryHash{$node}{response};
					} else { $summaryHash{$node}{response} = "NaN" }
	
					if ( $summaryHash{$node}{intfCollect} !~ /NaN/i ) {
						++$nodecount{intfCollect};
						$summaryHash{total}{intfCollect} = $summaryHash{total}{intfCollect} + $summaryHash{$node}{intfCollect};
					} else { $summaryHash{$node}{intfCollect} = "NaN" }
	
					if ( $summaryHash{$node}{intfColUp} !~ /NaN/i ) {
						++$nodecount{intfColUp};
						$summaryHash{total}{intfColUp} = $summaryHash{total}{intfColUp} + $summaryHash{$node}{intfColUp};
					} else { $summaryHash{$node}{intfColUp} = "NaN" }
				} else {
		###			logMsg("INFO Node=$node skipped OU=$outage");
				}
				
			} else {
				# node not active
				$summaryHash{$node}{event_status} = "N/A";
				$summaryHash{$node}{reachable} = "N/A";
				$summaryHash{$node}{available} = "N/A";
				$summaryHash{$node}{health} = "N/A";				
				$summaryHash{$node}{response} = "N/A";
				$summaryHash{$node}{event_color} = "#aaaaaa";
				$summaryHash{$node}{reachable_color} = "#aaaaaa";
				$summaryHash{$node}{available_color} = "#aaaaaa";
				$summaryHash{$node}{health_color} = "#aaaaaa";				
				$summaryHash{$node}{response_color} = "#aaaaaa";
			}
		}
	}

	if ( $summaryHash{total}{reachable} > 0 ) {
		$summaryHash{average}{reachable} = sprintf("%.3f",$summaryHash{total}{reachable} / $nodecount{reachable} );
	}
	if ( $summaryHash{total}{available} > 0 ) {
		$summaryHash{average}{available} = sprintf("%.3f",$summaryHash{total}{available} / $nodecount{available} );
	}
	if ( $summaryHash{total}{health} > 0 ) {
		$summaryHash{average}{health} = sprintf("%.3f",$summaryHash{total}{health} / $nodecount{health} );
	}
	if ( $summaryHash{total}{response} > 0 ) {
		# Changing default precision to 1 decimal, as changing to 3 might mess up many screens.
		$summaryHash{average}{response} = sprintf("%.1f",$summaryHash{total}{response} / $nodecount{response} );
	}
	
	if ( $summaryHash{total}{reachable} > 0 and $summaryHash{total}{available} > 0 and $summaryHash{total}{health} > 0 ) {
		# new weighting for metric
		$summaryHash{average}{metric} = sprintf("%.3f",( 
			( $summaryHash{average}{reachable} * $C->{metric_reachability} ) +
			( $summaryHash{average}{available} * $C->{metric_availability} ) +
			( $summaryHash{average}{health} ) * $C->{metric_health} )
		);
	}

	# interface availability calculation NEW
	if ($nodecount{intfColUp} > 0 and $nodecount{intfCollect} > 0 and 
			$summaryHash{total}{intfColUp} > 0 and $summaryHash{total}{intfCollect} > 0) {
		$summaryHash{average}{intfAvail} = (($summaryHash{total}{intfColUp} / $nodecount{intfColUp}) / 
										($summaryHash{total}{intfCollect} / $nodecount{intfCollect})) * 100;
	} else {
		$summaryHash{average}{intfAvail} = 100;
	}

	$summaryHash{average}{intfColUp} = $summaryHash{total}{intfColUp} eq '' ? 0 : $summaryHash{total}{intfColUp};
	$summaryHash{average}{intfCollect} = $summaryHash{total}{intfCollect} eq '' ? 0 : $summaryHash{total}{intfCollect};

	$summaryHash{average}{countdown} = $nodecount{countdown};
	$summaryHash{average}{countdegraded} = $nodecount{countdegraded};
	### 2012-12-17 keiths, fixed divide by zero error when doing group status summaries
	if ( $nodecount{countdown} > 0 and $nodecount{counttotal} > 0 ) {
		$summaryHash{average}{countdowncolor} = ($nodecount{countdown}/$nodecount{counttotal})*100;
	}
	else {
		$summaryHash{average}{countdowncolor} = 0;
	}
	
	$summaryHash{average}{counttotal} = $nodecount{counttotal};
	$summaryHash{average}{countup} = $nodecount{countup};

	# Now the summaryHash is full, calc some colors and check for empty results.
	if ( $summaryHash{average}{reachable} ne "" ) {
		$summaryHash{average}{reachable} = 100 if $summaryHash{average}{reachable} > 100 ;
		$summaryHash{average}{reachable_color} = colorHighGood($summaryHash{average}{reachable})
	} 
	else { 
		$summaryHash{average}{reachable_color} = "#aaaaaa";
		$summaryHash{average}{reachable} = "N/A";
	}

	# modification of interface available calculation
	if (getbool($C->{intf_av_modified})) {
		$summaryHash{average}{available} = 
				sprintf("%.3f",($summaryHash{total}{intfColUp} / $summaryHash{total}{intfCollect}) * 100 );
	}

	if ( $summaryHash{average}{available} ne "" ) {
		$summaryHash{average}{available} = 100 if $summaryHash{average}{available} > 100 ;
		$summaryHash{average}{available_color} = colorHighGood($summaryHash{average}{available});
	}
	else { 
		$summaryHash{average}{available_color} = "#aaaaaa";
		$summaryHash{average}{available} = "N/A";
	}

	if ( $summaryHash{average}{health} ne "" ) {
		$summaryHash{average}{health} = 100 if $summaryHash{average}{health} > 100 ;
		$summaryHash{average}{health_color} = colorHighGood($summaryHash{average}{health});
	}
	else { 
		$summaryHash{average}{health_color} = "#aaaaaa";
		$summaryHash{average}{health} = "N/A";
	}

	if ( $summaryHash{average}{response} ne "" ) {
		$summaryHash{average}{response_color} = colorResponseTime($summaryHash{average}{response})
	}
	else { 
		$summaryHash{average}{response_color} = "#aaaaaa";
		$summaryHash{average}{response} = "N/A";
	}

	if ( $summaryHash{average}{metric} ne "" ) {
		$summaryHash{average}{metric} = 100 if $summaryHash{average}{metric} > 100 ;
		$summaryHash{average}{metric_color} = colorHighGood($summaryHash{average}{metric})
	}
	else { 
		$summaryHash{average}{metric_color} = "#aaaaaa";
		$summaryHash{average}{metric} = "N/A";
	}
	dbg("Finished");
	return \%summaryHash;
} # end getGroupSummary

#=========================================================================================

sub getAdminColor {
	my %args = @_;
	my ($S,$index,$IF);
	if ( exists $args{sys} ) {
		$S = $args{sys};
		$index = $args{index};
		$IF = $S->ifinfo;
	}
	my $adminColor;
	
	my $ifAdminStatus = $IF->{$index}{ifAdminStatus};
	my $collect = $IF->{$index}{collect};
	
	if ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !getbool($collect)) {
		$adminColor="#ffffff";
	} else {
		$adminColor="#00ff00";
	}
	return $adminColor;
}

#=========================================================================================

sub getOperColor {
	my %args = @_;
	my ($S,$NI,$index,$IF);
	if ( exists $args{sys} ) {
		$S = $args{sys};
		$index = $args{index};
		$IF = $S->ifinfo;
	}	
	my $operColor;
	
	my $ifAdminStatus = $IF->{$index}{ifAdminStatus};
	my $ifOperStatus = $IF->{$index}{ifOperStatus};
	my $collect = $IF->{$index}{collect};
	
	if ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$ifOperStatus = $args{ifOperStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !getbool($collect)) {
		$operColor="#ffffff"; # white
	} else {
		if ($ifOperStatus eq 'down') {
			# red for down
			$operColor = "#ff0000";
		} elsif ($ifOperStatus eq 'dormant') {
			# yellow for dormant
			$operColor = "#ffff00";
		} else { $operColor = "#00ff00"; } # green
	}
	return $operColor;
}

sub colorHighGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold eq "N/A" )  { $color = "#FFFFFF"; }
	elsif ( $threshold >= 100 ) { $color = "#00FF00"; }
	elsif ( $threshold >= 95 ) { $color = "#00EE00"; }
	elsif ( $threshold >= 90 ) { $color = "#00DD00"; }
	elsif ( $threshold >= 85 ) { $color = "#00CC00"; }
	elsif ( $threshold >= 80 ) { $color = "#00BB00"; }
	elsif ( $threshold >= 75 ) { $color = "#00AA00"; }
	elsif ( $threshold >= 70 ) { $color = "#009900"; }
	elsif ( $threshold >= 65 ) { $color = "#008800"; }
	elsif ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold >= 55 ) { $color = "#FFEE00"; }
	elsif ( $threshold >= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold >= 45 ) { $color = "#FFCC00"; }
	elsif ( $threshold >= 40 ) { $color = "#FFBB00"; }
	elsif ( $threshold >= 35 ) { $color = "#FFAA00"; }
	elsif ( $threshold >= 30 ) { $color = "#FF9900"; }
	elsif ( $threshold >= 25 ) { $color = "#FF8800"; }
	elsif ( $threshold >= 20 ) { $color = "#FF7700"; }
	elsif ( $threshold >= 15 ) { $color = "#FF6600"; }
	elsif ( $threshold >= 10 ) { $color = "#FF5500"; }
	elsif ( $threshold >= 5 )  { $color = "#FF3300"; }
	elsif ( $threshold > 0 )   { $color = "#FF1100"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }

	return $color;
}

sub colorPort {
	my $threshold = shift;
	my $color = "";

	if ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold < 60 ) { $color = "#00FF00"; }

	return $color;
}

sub colorLowGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold == 0 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 5 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 10 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 15 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 20 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 25 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 30 ) { $color = "#009900"; }
	elsif ( $threshold <= 35 ) { $color = "#008800"; }
	elsif ( $threshold <= 40 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 45 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 55 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 60 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 65 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 70 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 75 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 80 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 85 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 90 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 95 ) { $color = "#FF4400"; }
	elsif ( $threshold < 100 ) { $color = "#FF3300"; }
	elsif ( $threshold == 100 )  { $color = "#FF1100"; }
	elsif ( $threshold <= 110 )  { $color = "#FF0055"; }
	elsif ( $threshold <= 120 )  { $color = "#FF0066"; }
	elsif ( $threshold <= 130 )  { $color = "#FF0077"; }
	elsif ( $threshold <= 140 )  { $color = "#FF0088"; }
	elsif ( $threshold <= 150 )  { $color = "#FF0099"; }
	elsif ( $threshold <= 160 )  { $color = "#FF00AA"; }
	elsif ( $threshold <= 170 )  { $color = "#FF00BB"; }
	elsif ( $threshold <= 180 )  { $color = "#FF00CC"; }
	elsif ( $threshold <= 190 )  { $color = "#FF00DD"; }
	elsif ( $threshold <= 200 )  { $color = "#FF00EE"; }
	elsif ( $threshold > 200 )  { $color = "#FF00FF"; }

	return $color;
}

sub colorResponseTimeStatic {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold <= 1 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 20 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 50 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 100 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 200 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 250 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 300 ) { $color = "#009900"; }
	elsif ( $threshold <= 350 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 400 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 450 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 500 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 550 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 600 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 650 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 700 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 750 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 800 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 850 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 900 ) { $color = "#FF4400"; }
	elsif ( $threshold <= 950 )  { $color = "#FF3300"; }
	elsif ( $threshold < 1000 )   { $color = "#FF1100"; }
	elsif ( $threshold > 1000 )  { $color = "#FF0000"; }

	return $color;
}
	
sub eventLevel {
	my $event = shift;
	my $role = shift;

	my $event_level;
	my $event_color;

	if ( $event eq 'Node Down' ) {
	 	if ( $role eq "core" ) { $event_level = "Critical"; }
	 	elsif ( $role eq "distribution" ) { $event_level = "Major"; }
	 	elsif ( $role eq "access" ) { $event_level = "Minor"; }
	}
	elsif ( $event =~ /up/i ) {
		$event_level = "Normal";
	}
	# colour all other events the same, based on role, to get some consistency across the network
	else {
	 	if ( $role eq "core" ) { $event_level = "Major"; }
	 	elsif ( $role eq "distribution" ) { $event_level = "Minor"; }
	 	elsif ( $role eq "access" ) { $event_level = "Warning";	}
	}
	$event_color = eventColor($event_level);
	return ($event_level,$event_color);
} # eventLevel

# clean all events for a node - used if editing or deleting nodes via Config
sub cleanEvent {
	my $node=shift;
	my $caller=shift;

	my $events_config = loadTable(dir => 'conf', name => 'Events'); # cannot use loadGenericTable as that checks and clashes with db_events_sql
	my ($ET,$handle) = loadEventStateLock();

	foreach my $event_hash ( sort keys %{$ET})  
	{
		if ( exists $ET->{$event_hash} and $ET->{$event_hash}{node} eq "$node" )
		{
			# event control is as configured or all true.
			my $thisevent_control = $events_config->{$ET->{$event_hash}->{event}} || { Log => "true", Notify => "true", Status => "true"};
			# log the deletion meta-event iff the original event had logging enabled
			if (getbool($thisevent_control->{Log}))
			{
				logEvent(node => "$ET->{$event_hash}{node}", event => "$caller: deleted event: $ET->{$event_hash}{event}", level => "Normal", element => "$ET->{$event_hash}{element}", details => "$ET->{$event_hash}{details}");
			}
			delete $ET->{$event_hash};
		}
	}
	writeEventStateLock(table=>$ET,handle=>$handle);
}

sub overallNodeStatus {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $netType = $args{netType};
	my $roleType = $args{roleType};

	if (scalar(@_) == 1) {
		$group = shift;
	}
	
	my $node;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $status;

	my %statusHash;

	my $C = loadConfTable();
	my $NT = loadNodeTable();
	my $ET = loadEventStateNoLock();
	my $NS = loadNodeSummary();

	#print STDERR &returnDateStamp." overallNodeStatus: netType=$netType roleType=$roleType\n";

	if ( $group eq "" and $customer eq "" and $business eq "" and $netType eq "" and $roleType eq "" ) {
		foreach $node (sort keys %{$NT} ) {
			if (getbool($NT->{$node}{active})) {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} ) {
					### 2013-08-20 keiths, check for SNMP Down if ping eq false.
					my $down_event = "Node Down";
					$down_event = "SNMP Down" if getbool($NT->{$node}{ping},"invert");
					my $event_hash = eventHash($node,$down_event,"");
					($outage,undef) = outageCheck(node=>$node,time=>time());
					$nodedown = exists $ET->{$event_hash}{node};
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( getbool($NS->{$node}{nodedown})) {
						$nodedown = 1;
					}
				}
				
				if ( $nodedown and $outage ne 'current' ) {
					($event_status) = eventLevel("Node Down",$NT->{$node}{roleType});
				}
				else {
					($event_status) = eventLevel("Node Up",$NT->{$node}{roleType});
				}
				
				++$statusHash{$event_status};
				++$statusHash{count};
			}
		}	
	}
	elsif ( $netType ne "" and $roleType ne "" ) {
		foreach $node (sort keys %{$NT} ) {
			if (getbool($NT->{$node}{active})) {
				if ( $NT->{$node}{net} eq "$netType" && $NT->{$node}{role} eq "$roleType" ) {
					my $nodedown = 0;
					my $outage = "";
					if ( $NT->{$node}{server} eq $C->{server_name} ) {
						### 2013-08-20 keiths, check for SNMP Down if ping eq false.
						my $down_event = "Node Down";
						$down_event = "SNMP Down" if getbool($NT->{$node}{ping},"invert");
						my $event_hash = eventHash($node,$down_event,"");
						($outage,undef) = outageCheck(node=>$node,time=>time());
						$nodedown = exists $ET->{$event_hash}{node};
					}
					else {
						$outage = $NS->{$node}{outage};
						if ( getbool($NS->{$node}{nodedown})) {
							$nodedown = 1;
						}
					}
					
					if ( $nodedown and $outage ne 'current' ) {
						($event_status) = eventLevel("Node Down",$NT->{$node}{roleType});
					}
					else {
						($event_status) = eventLevel("Node Up",$NT->{$node}{roleType});
					}
					
					++$statusHash{$event_status};
					++$statusHash{count};
				}
			}
		}
	}
	elsif ( $group ne "" or $customer ne "" or $business ne "" ) {
		foreach $node (sort keys %{$NT} ) {
			if ( 
				getbool($NT->{$node}{active})
				and ( ($group ne "" and $NT->{$node}{group} eq $group)
							or ($customer ne "" and $NT->{$node}{customer} eq $customer)
							or ($business ne "" and $NT->{$node}{businessService} =~ /$business/ )
						)
			) {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} ) {
					### 2013-08-20 keiths, check for SNMP Down if ping eq false.
					my $down_event = "Node Down";
					$down_event = "SNMP Down" if getbool($NT->{$node}{ping},"invert");
					my $event_hash = eventHash($node,$down_event,"");
					($outage,undef) = outageCheck(node=>$node,time=>time());
					$nodedown = exists $ET->{$event_hash}{node};
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( getbool($NS->{$node}{nodedown})) {
						$nodedown = 1;
					}
				}
				
				if ( $nodedown and $outage ne 'current' ) {
					($event_status) = eventLevel("Node Down",$NT->{$node}{roleType});
				}
				else {
					($event_status) = eventLevel("Node Up",$NT->{$node}{roleType});
				}

				++$statusHash{$event_status};
				++$statusHash{count};
				#print STDERR &returnDateStamp." overallNodeStatus: $node $group $event_status event=$statusHash{$event_status} count=$statusHash{count}\n";
			}
		}
	}

	$status_number = 100 * $statusHash{Normal};
	$status_number = $status_number + ( 90 * $statusHash{Warning} );
	$status_number = $status_number + ( 75 * $statusHash{Minor} );
	$status_number = $status_number + ( 60 * $statusHash{Major} );
	$status_number = $status_number + ( 50 * $statusHash{Critical} );
	$status_number = $status_number + ( 40 * $statusHash{Fatal} );
	if ( $status_number != 0 and $statusHash{count} != 0 ) {
		$status_number = $status_number / $statusHash{count};
	}
	#print STDERR "New CALC: status_number=$status_number count=$statusHash{count}\n";

	### 2014-08-27 keiths, adding a more coarse any nodes down is red
	if ( defined $C->{overall_node_status_coarse} 
			 and getbool($C->{overall_node_status_coarse})) {
		$C->{overall_node_status_level} = "Critical" if not defined $C->{overall_node_status_level};
		if ( $status_number == 100 ) { $overall_status = "Normal"; }
		else { $overall_status = $C->{overall_node_status_level}; }
	}
	else {	
		### AS 11/4/01 - Fixed up status for single node groups.
		# if the node count is one we do not require weighting.
		if ( $statusHash{count} == 1 ) {
			delete ($statusHash{count});
			foreach $status (keys %statusHash) {
				if ( $statusHash{$status} ne "" and $statusHash{$status} ne "count" ) {
					$overall_status = $status;
					#print STDERR returnDateStamp." overallNodeStatus netType=$netType status=$status hash=$statusHash{$status}\n";
				}
			}
		}
		elsif ( $status_number != 0  ) {
			if ( $status_number == 100 ) { $overall_status = "Normal"; }
			elsif ( $status_number >= 95 ) { $overall_status = "Warning"; }
			elsif ( $status_number >= 90 ) { $overall_status = "Minor"; }
			elsif ( $status_number >= 70 ) { $overall_status = "Major"; }
			elsif ( $status_number >= 50 ) { $overall_status = "Critical"; }
			elsif ( $status_number <= 40 ) { $overall_status = "Fatal"; }
			elsif ( $status_number >= 30 ) { $overall_status = "Disaster"; }
			elsif ( $status_number < 30 ) { $overall_status = "Catastrophic"; }
		}
		else {
			$overall_status = "Unknown";
		}
	}
	return $overall_status;
} # end overallNodeStatus

# convert configuration files in dir conf to NMIS8

sub convertConfFiles {

	my $C = loadConfTable();

	my $ext = getExtension(dir=>'conf');
	#==== check Nodes ====

	if (!existFile(dir=>'conf',name=>'Nodes')) {
		my %nodeTable;
		my $NT;
		# Load the old CSV first for upgrading to NMIS8 format
		if ( -r $C->{Nodes_Table} ) {
			if ( (%nodeTable = &loadCSV($C->{Nodes_Table},$C->{Nodes_Key},"\t")) ) {
				dbg("Loaded $C->{Nodes_Table}");
				rename "$C->{Nodes_Table}","$C->{Nodes_Table}.old";		
				# copy what we need
				foreach my $i (sort keys %nodeTable) {
					dbg("update node=$nodeTable{$i}{node} to NMIS8 format");
					# new field 'name' and 'host' in NMIS8, update this field
					if ($nodeTable{$i}{node} =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
						$nodeTable{$i}{name} = sprintf("IP-%03d-%03d-%03d-%03d",${1},${2},${3},${4}); # default
						# it's an IP address, get the DNS name
						my $iaddr = inet_aton($nodeTable{$i}{node});
						if ((my $name  = gethostbyaddr($iaddr, AF_INET))) {
							$nodeTable{$i}{name} = $name; # oke
							dbg("node=$nodeTable{$i}{node} converted to name=$name");
						} else {
							# look for sysName of nmis4
							if ( -f "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat" ) {
								my (%info,$name,$value);
								sysopen(DATAFILE, "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat", O_RDONLY);
								while (<DATAFILE>) {
									chomp;
									if ( $_ !~ /^#/ ) {
										($name,$value) = split "=", $_;
										$info{$name} = $value;
									}
								}
								close(DATAFILE);
								if ($info{sysName} ne "") {
									$nodeTable{$i}{name} = $info{sysName};
									dbg("name=$name=$info{sysName} from sysName for node=$nodeTable{$i}{node}");
								}
							}
						}
					} else {
						$nodeTable{$i}{name} = $nodeTable{$i}{node}; # simple copy of DNS name
					}
					dbg("result 1 update name=$nodeTable{$i}{name}");
					# only first part of (fqdn) name
					($nodeTable{$i}{name}) = split /\./,$nodeTable{$i}{name} ;
					dbg("result update name=$nodeTable{$i}{name}");
		
					my $node = $nodeTable{$i}{name};
					$NT->{$node}{name} = $nodeTable{$i}{name};
					$NT->{$node}{host} = $nodeTable{$i}{host} || $nodeTable{$i}{node};
					$NT->{$node}{active} = $nodeTable{$i}{active};
					$NT->{$node}{collect} = $nodeTable{$i}{collect};
					$NT->{$node}{group} = $nodeTable{$i}{group};
					$NT->{$node}{netType} = $nodeTable{$i}{net} || $nodeTable{$i}{netType};
					$NT->{$node}{roleType} = $nodeTable{$i}{role} || $nodeTable{$i}{roleType};
					$NT->{$node}{depend} = $nodeTable{$i}{depend};
					$NT->{$node}{threshold} = $nodeTable{$i}{threshold} || 'false';
					$NT->{$node}{ping} = $nodeTable{$i}{ping} || 'true';
					$NT->{$node}{community} = $nodeTable{$i}{community};
					$NT->{$node}{port} = $nodeTable{$i}{port} || '161';
					$NT->{$node}{cbqos} = $nodeTable{$i}{cbqos} || 'none';
					$NT->{$node}{calls} = $nodeTable{$i}{calls} || 'false';
					$NT->{$node}{rancid} = $nodeTable{$i}{rancid} || 'false';
					$NT->{$node}{services} = $nodeTable{$i}{services} ;
				#	$NT->{$node}{runupdate} = $nodeTable{$i}{runupdate} ;
					$NT->{$node}{webserver} = 'false' ;
					$NT->{$node}{model} = $nodeTable{$i}{model} || 'automatic';
					$NT->{$node}{version} = $nodeTable{$i}{version} || 'snmpv2c';
					$NT->{$node}{timezone} = 0 ;
				}
				writeTable(dir=>'conf',name=>'Nodes',data=>$NT);
				print " csv file $C->{Nodes_Table} converted to conf/Nodes.$ext\n";
			} else {
				dbg("ERROR, could not find or read $C->{Nodes_Table} or empty node file");
			}
		} else {
			dbg("ERROR, could not find or read $C->{Nodes_Table}");
		}
	}


	#====================

	if (!existFile(dir=>'conf',name=>'Escalations')) {
		if ( -r "$C->{'Escalation_Table'}") {
			my %table_data = loadCSV($C->{'Escalation_Table'},$C->{'Escalation_Key'});
			foreach my $k (keys %table_data) { 
				if (not exists $table_data{$k}{Event_Element}) {
					$table_data{$k}{Event_Element} = $table_data{$k}{Event_Details} ;
					delete $table_data{$k}{Event_Details};
				}
			}
			writeTable(dir=>'conf',name=>'Escalations',data=>\%table_data);
			print " csv file $C->{Escalation_Table} converted to conf/Escalation.$ext\n";
			rename "$C->{'Escalation_Table'}","$C->{'Escalation_Table'}.old";
		} else {
			dbg("ERROR, could not find or read $C->{'Escalation_Table'}");
		}
	}
	#====================

	convertFile('Contacts');

	convertFile('Locations');

	convertFile('Services');

	convertFile('Users');

	#====================

	sub convertFile {
		my $name = shift;
		my $C = loadConfTable();
		if (!existFile(dir=>'conf',name=>$name)) {
			if ( -r "$C->{\"${name}_Table\"}") {
				my %table_data = loadCSV($C->{"${name}_Table"},$C->{"${name}_Key"});
				writeTable(dir=>'conf',name=>$name,data=>\%table_data);
	
				my $ext = getExtension(dir=>'conf');
				print " csv file $C->{\"${name}_Table\"} converted to conf/${name}.$ext\n";
				rename "$C->{\"${name}_Table\"}","$C->{\"${name}_Table\"}.old";
			} else {
				dbg("ERROR, could not find or read $C->{\"${name}_Table\"}");
			}
		}
	}
}


### AS 8 June 2002 - Converts status level to a number for metrics
sub statusNumber {
	my $status = shift;
	my $level;
	if ( $status eq "Normal" ) { $level = 100 }
	elsif ( $status eq "Warning" ) { $level = 95 }
	elsif ( $status eq "Minor" ) { $level = 90 }
	elsif ( $status eq "Major" ) { $level = 80 }
	elsif ( $status eq "Critical" ) { $level = 60 }
	elsif ( $status eq "Fatal" ) { $level = 40 }
	elsif ( $status eq "Disaster" ) { $level = 20 }
	elsif ( $status eq "Catastrophic" ) { $level = 0 }
	elsif ( $status eq "Unknown" ) { $level = "U" }
	return $level;
}

# 24 Feb 2002 - A suggestion from someone? to remove \n from $string.
# this also prints the message if debug, remove concurrent debug prints in code...

sub logMessage {
	my $string = shift;
	my $C = loadConfTable();

	$string =~ s/\n+/ /g;      #remove all embedded newlines
	sysopen(DATAFILE, "$C->{nmis_log}", O_WRONLY | O_APPEND | O_CREAT)
		 or warn returnTime." logMessage, Couldn't open log file $C->{nmis_log}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "logMessage, can't lock filename: $!";
	print DATAFILE &returnDateStamp.",$string\n";
	close(DATAFILE) or warn "logMessage, can't close filename: $!";
} # end logMessage

# load the info of a node
# if optional arg suppress_errors is given, then no errors are logged
sub loadNodeInfoTable 
{
	my $node = lc shift;
	my %args = @_;
	
	return loadTable(dir=>'var', name=>"$node-node",  suppress_errors => $args{suppress_errors});
}

# load info of all interfaces
sub loadInterfaceInfo {

	return loadTable(dir=>'var',name=>"nmis-interfaces"); # my $II = loadInterfaceInfo();
}

# load info of all interfaces
sub loadInterfaceInfoShort {

	return loadTable(dir=>'var',name=>"nmis-interfaces-short"); # my $II = loadInterfaceInfoShort();
}

#
sub loadEnterpriseTable {
	return loadTable(dir=>'conf',name=>'Enterprise');
}


sub loadOutageTable {
	my $OT = loadTable(dir=>'conf',name=>'Outage'); # get in cache
}

#
# check outage of node
# return status,key where status is pending or current, key is hash key of event table
#
sub outageCheck {
	my %args = @_;
	my $node = $args{node};
	my $time = $args{time};

	my $OT = loadOutageTable();

	# Get each of the nodes info in a HASH for playing with
	foreach my $key (sort keys %{$OT}) {
		if (($time-300) > $OT->{$key}{end}) {
			outageRemove(key=>$key); # passed
		} else {
			if ( $node eq $OT->{$key}{node}) {
				if ($time >= $OT->{$key}{start} and $time <= $OT->{$key}{end} ) {
					return "current",$key;
				}
				elsif ($time < $OT->{$key}{start}) {
					return "pending",$key;
				}
			}
		}
	}
	# check also dependency
	my $NT = loadNodeTable();
	foreach my $nd ( split(/,/,$NT->{$node}{depend}) ) {
		foreach my $key (sort keys %{$OT}) {
			if ( $nd eq $OT->{$key}{node}) {
				if ($time >= $OT->{$key}{start} and $time <= $OT->{$key}{end} ) {
					# check if this node is down
					my $NI = loadNodeInfoTable($nd);
					if (getbool($NI->{system}{nodedown})) {
						return "current",$key;
					}
				}
			}
		}
	}
}

sub outageRemove {
	my %args = @_;
	my $key = $args{key};

	my $C = loadConfTable();
	my $time = time();
	my $string;

	my ($OT,$handle) = loadTable(dir=>'conf',name=>'Outage',lock=>'true');

	# dont log pending
	if ($time > $OT->{$key}{start})  {
		$string = ", Node $OT->{$key}{node}, Start $OT->{$key}{start}, End $OT->{$key}{end}, "
							."Change $OT->{$key}{change}, Closed $time, User $OT->{$key}{user}";
	}

	delete $OT->{$key};

	writeTable(dir=>'conf',name=>'Outage',data=>$OT,handle=>$handle);

	if ($string ne '') {
		# log this action
		if ( open($handle,">>$C->{outage_log}") ) {
			if ( flock($handle, LOCK_EX) ) { 
				if ( not print $handle returnDateStamp()." $string\n" ) {
					logMsg("ERROR (nmis) cannot write file $C->{outage_log}: $!");
				}
			} else {
				logMsg("ERROR (nmis) cannot lock file $C->{outage_log}: $!");
			}
			close $handle;
			setFileProt($C->{outage_log});
		} else {
			logMsg("ERROR (nmis) cannot open file $C->{outage_log}: $!");
		}
	}
}

### HIGHLY EXPERIMENTAL!
#sub sendTrap {
#	my %arg = @_;
#	use SNMP_util;
#	my @servers = split(",",$arg{server});
#	foreach my $server (@servers) {
#		print "Sending trap to $server\n";
#		#my($host, $ent, $agent, $gen, $spec, @vars) = @_;
#		snmptrap(
#			$server, 
#			".1.3.6.1.4.1.4818", 
#			"127.0.0.1", 
#			6, 
#			1000, 
#	        ".1.3.6.1.4.1.4818.1.1000", 
#	        "int",
#	        "2448816"
#	    );
#    }
#}




# small translator from event level to priority: header for email
sub eventToSMTPPri {
	my $level = shift;
	# More granularity might be possible there are 5 numbers but
	# can only find word to number mappings for L, N, H
	if ( $level eq "Normal" ) { return "Normal" }
	elsif ( $level eq "Warning" ) { return "Normal" }
	elsif ( $level eq "Minor" ) { return "Normal" }
	elsif ( $level eq "Major" ) { return "High" }
	elsif ( $level eq "Critical" ) { return "High" }
	elsif ( $level eq "Fatal" ) { return "High" }
	elsif ( $level eq "Disaster" ) { return "High" }
	elsif ( $level eq "Catastrophic" ) { return "High" }
	elsif ( $level eq "Unknown" ) { return "Low" }
	else
	{
		return "Normal";
	}
}

# test the dutytime of the given contact.
# return true if OK to notify
# expect a reference to %contact_table, and a contact name to lookup
sub dutyTime {
	my ($table , $contact) = @_;
	my $today;
	my $days;
	my $start_time;
	my $finish_time;

	if ( $$table{$contact}{DutyTime} ) {
	    # dutytime has some values, so assume TZ offset to localtime has as well
		my @ltime = localtime( time() + ($$table{$contact}{TimeZone}*60*60));
		my $out = sprintf("Using corrected time %s for Contact:$contact, localtime:%s, offset:$$table{$contact}{TimeZone}", scalar localtime(time()+($$table{$contact}{TimeZone}*60*60)), scalar localtime());
		dbg($out);

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				dbg("returning success on dutytime test for $contact");
				return 1;
			}
			elsif ( $finish_time < $start_time ) { 
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					dbg("returning success on dutytime test for $contact");
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		dbg("No dutytime defined - returning success assuming $contact is 24x7");
		return 1;
	}
	dbg("returning fail on dutytime test for $contact");
	return 0;		# dutytime was valid, but no timezone match, return false.
}


sub resolveDNStoAddr {
	my $dns = shift;
	my $addr;
	my $oct;

	# convert node name to octal ip address
	if ($dns ne "" ) {
		if ($dns !~ /\d+\.\d+\.\d+\.\d+/) {
			my $h = gethostbyname($dns); 
			return if not $h;
			$addr = inet_ntoa($h->addr) ;
		} else { $addr = $dns; }
		return $addr if $addr =~ /\d+\.\d+\.\d+\.\d+/;
	} 
	return;
}


# create http for a clickable graph
sub htmlGraph {
	my %args = @_;
	my $graphtype = $args{graphtype};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $server = $args{server};
	
	my $target = $node;
	if ($node eq "" and $group ne "") {
		$target = $group;
	}

	my $id = "$target-$intf-$graphtype";
	my $C = loadConfTable();

	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $win_width = $C->{win_width}; # window size
	my $win_height = $C->{win_height};

	my $urlsafenode = uri_escape($node);

	my $time = time();
	my $clickurl = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=$graphtype&group=$group&intf=$intf&server=$server&node=$urlsafenode";
	

	if( getbool($C->{display_opcharts}) ) {
		my $graphLink = "$C->{'rrddraw'}?conf=$C->{conf}&act=draw_graph_view&group=$group&graphtype=$graphtype&node=$urlsafenode&intf=$intf&server=$server".
				"&start=&end=&width=$width&height=$height&time=$time";
		my $retval = qq|<div class="chartDiv" id="${id}DivId" data-chart-url="$graphLink" data-title-onclick='viewwndw("$target","$clickurl",$win_width,$win_height)' data-chart-height="$height" data-chart-width="$width"><div class="chartSpan" id="${id}SpanId"></div></div>|;		
	}
	else {
		my $src = "$C->{'rrddraw'}?conf=$C->{conf}&act=draw_graph_view&group=$group&graphtype=$graphtype&node=$urlsafenode&intf=$intf&server=$server".
			"&start=&end=&width=$width&height=$height&time=$time";
		### 2012-03-28 keiths, changed graphs to come up in their own Window with the target of node, handy for comparing graphs.
		return a({target=>"Graph-$target",onClick=>"viewwndw(\'$target\',\'$clickurl\',$win_width,$win_height)"},img({alt=>'Network Info',src=>"$src"}));
	}	
}

sub createHrButtons {
	my %args = @_;
	my $user = $args{user};
	my $node = $args{node};
	my $S = $args{system};
	my $refresh = $args{refresh};
	my $widget = $args{widget};
	
	$refresh = "false" if $refresh eq "";

	my $Q = $main::Q;
	my $AU = $main::AU;

	my @out;

	return "" if $node eq '';

	my $NI = loadNodeInfoTable($node);
	my $C = loadConfTable();

	return unless $AU->InGroup($NI->{system}{group});

	my $server = getbool($C->{server_master}) ? '' : $NI->{system}{server};
	my $urlsafenode = uri_escape($node);

	push @out, start_table({class=>'table'}),start_Tr;
	
	# provide link back to the main dashboard if not in widget mode
	push @out, td({class=>"header litehead"}, a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION"))
			if (!getbool($widget));

	push @out, td({class=>'header litehead'},'Node ',
			a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},$NI->{system}{name}));

	if (scalar keys %{$NI->{module}}) {
		push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_module_view&node=$urlsafenode&server=$server"},"modules"));
	}

	if (getbool($NI->{system}{collect})) {
		push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_status_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"status"))
				if defined $NI->{status} and defined $C->{display_status_summary} 
		and getbool($C->{display_status_summary});
		push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_interface_view_all&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"interfaces"))
				if defined $S->{mdl}{interface};
		push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_interface_view_act&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"active intf"))
				if defined $S->{mdl}{interface};
		if ($NI->{system}{nodeType} =~ /router|switch/) {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_port_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ports"));
		}
		if ($NI->{system}{nodeType} =~ /server/) {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_storage_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"storage"));
		}

		if ($S->getTypeInstances(graphtype => 'service', section => 'service')) {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_service_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"services"));
		}
		# adding services list support, but hide the tab if the snmp service collection isn't working
		if (defined $NI->{services} && keys %{$NI->{services}}) {
					push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_service_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"service list"));
		}	

		### 2013-03-06 keiths, adding systemHealth support
		if ( defined $S->{mdl}{systemHealth}{sys} ) {
			my @systemHealth;
			foreach (sort keys %{$S->{mdl}{systemHealth}{sys}}) { push @systemHealth, $_; }
			
			foreach my $sysHealth (@systemHealth) {	
				if ($NI->{$sysHealth} ne '' or $NI->{$sysHealth} ne '') {
					push @out, td({class=>'header litehead'},
						a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_system_health_view&section=$sysHealth&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"$sysHealth"));
				}
			}
		}

		### 2012-12-13 keiths, adding generic temp support
		if ($NI->{env_temp} ne '' or $NI->{env_temp} ne '') {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_environment_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{akcp_temp} ne '' or $NI->{akcp_hum} ne '') {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_environment_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{cssgroup} ne '') {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_cssgroup_view&node=$urlsafenode&refresh=false&server=$server"},"Group"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
 		if ($NI->{csscontent} ne '') {
			push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"network.pl?conf=$Q->{conf}&act=network_csscontent_view&node=$urlsafenode&refresh=false&server=$server"},"Content"));
		}
	}

	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"events.pl?conf=$Q->{conf}&act=event_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"events"));
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"outages.pl?conf=$Q->{conf}&act=outage_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"outage"));
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"telnet://$NI->{system}{host}",target=>'_blank'},"telnet")) 
			if (getbool($C->{view_telnet}));
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"tools.pl?conf=$Q->{conf}&act=tool_system_ping&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ping")) 
			if getbool($C->{view_ping});
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"tools.pl?conf=$Q->{conf}&act=tool_system_trace&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"trace")) 
				if getbool($C->{view_trace});
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"tools.pl?conf=$Q->{conf}&act=tool_system_mtr&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"mtr")) 
			if getbool($C->{view_mtr});
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"tools.pl?conf=$Q->{conf}&act=tool_system_lft&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"lft")) 
				if getbool($C->{view_lft});
	push @out, td({class=>'header litehead'},
			a({class=>'wht',href=>"http://$NI->{system}{host}",target=>'_blank'},"http")) 
				if getbool($NI->{system}{webserver});

	if ($NI->{system}{server} eq $C->{server_name}) {
		push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"tables.pl?conf=$Q->{conf}&act=config_table_show&table=Contacts&key=".uri_escape($NI->{system}{sysContact})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"contact"))
					if $NI->{system}{sysContact} ne '';
		push @out, td({class=>'header litehead'},
				a({class=>'wht',href=>"tables.pl?conf=$Q->{conf}&act=config_table_show&table=Locations&key=".uri_escape($NI->{system}{sysLocation})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"location"))
					if $NI->{system}{sysLocation} ne '';
	}


	push @out, end_Tr,end_table;

	return @out;
}

sub loadPortalCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C = $main::C;
	
	$conf = $C->{'conf'} if not $conf;
	
	my $portalCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Portal") ) {
		# portal menu of nodes or clients to link to.
		my $P = loadTable(dir=>'conf',name=>"Portal");
		
		my $portalOption;
		
		foreach my $p ( sort {$a <=> $b} keys %{$P} ) {
			# If the link is part of NMIS, append the config
			my $selected;
			
			if ( $P->{$p}{Link} =~ /cgi-nmis8/ ) {
				$P->{$p}{Link} .= "?conf=$conf";
			}
			
			if ( $ENV{SCRIPT_NAME} =~ /nmiscgi/ and $P->{$p}{Link} =~ /nmiscgi/ and $P->{$p}{Name} =~ /NMIS8/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /maps/ and $P->{$p}{Name} =~ /Map/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /ipsla/ and $P->{$p}{Name} eq "IPSLA" ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			$portalOption .= qq|<option value="$P->{$p}{Link}"$selected>$P->{$p}{Name}</option>\n|;
		}
		
		
		$portalCode = qq|
				<div class="left"> 
					<form id="viewpoint">
						<select name="viewselect" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$portalOption
						</select>
					</form>
				</div>|;
		
	}
	return $portalCode;
}

sub loadServerCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C = $main::C;
	
	$conf = $C->{'conf'} if not $conf;
	
	my $serverCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Servers") ) {
		# portal menu of nodes or clients to link to.
		my $ST = loadServersTable();
		
		my $serverOption;
		
		$serverOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Servers">NMIS Servers</option>\n|;
		
		foreach my $srv ( sort {$ST->{$a}{name} cmp $ST->{$b}{name}} keys %{$ST} ) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# If the link is part of NMIS, append the config
			$serverOption .= qq|<option value="$ST->{$srv}{portal_protocol}://$ST->{$srv}{portal_host}:$ST->{$srv}{portal_port}$ST->{$srv}{cgi_url_base}/nmiscgi.pl?conf=$ST->{$srv}{config}">$ST->{$srv}{name}</option>\n|;
		}
		
		
		$serverCode = qq|
				<div class="left"> 
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$serverOption
						</select>
					</form>
				</div>|;
		
	}
	return $serverCode;
}

sub loadTenantCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C = $main::C;
	
	$conf = $C->{'conf'} if not $conf;
	
	my $tenantCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Tenants") ) {
		# portal menu of nodes or clients to link to.
		my $MT = loadTable(dir=>'conf',name=>"Tenants");
		
		my $tenantOption;
		
		$tenantOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Tenants">NMIS Tenants</option>\n|;
		
		foreach my $t ( sort {$MT->{$a}{Name} cmp $MT->{$b}{Name}} keys %{$MT} ) {
			# If the link is part of NMIS, append the config
			
			$tenantOption .= qq|<option value="?conf=$MT->{$t}{Config}">$MT->{$t}{Name}</option>\n|;
		}
		
		
		$tenantCode = qq|
				<div class="left"> 
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$tenantOption
						</select>
					</form>
				</div>|;
		
	}
	return $tenantCode;
}

sub startNmisPage {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>$title</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />    
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>    
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
    <script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>        
    <script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
    <script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
    <script src="$C->{'calendar'}" type="text/javascript"></script>
    <script src="$C->{'calendar_setup'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>    
    <script src="$C->{'nmis_common'}" type="text/javascript"></script>
    <script src="$C->{'highstock'}" type="text/javascript"></script>
		<script src="$C->{'chart'}" type="text/javascript"></script>
  </head>
  <body>
|;
	return 1;
}

sub pageStart {
	my %args = @_;
	my $refresh = $args{refresh};
	my $title = $args{title};
	my $jscript = $args{jscript};
	$jscript = getJavaScript() if ($jscript eq "");
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 300 if ($refresh eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>$title</title>
    <meta http-equiv="refresh" content="$refresh" />
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />    
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>    
    <script src="$C->{'highstock'}" type="text/javascript"></script>
		<script src="$C->{'chart'}" type="text/javascript"></script>
    <script>
$jscript
</script>
  </head>
  <body>
|;
}


sub pageStartJscript {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>$title</title>
    <meta http-equiv="refresh" content="$refresh" />
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />    
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>    
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
    <script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>        
    <script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
    <script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
    <script src="$C->{'calendar'}" type="text/javascript"></script>
    <script src="$C->{'calendar_setup'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>    
    <script src="$C->{'nmis_common'}" type="text/javascript"></script>
    <script src="$C->{'highstock'}" type="text/javascript"></script>
		<script src="$C->{'chart'}" type="text/javascript"></script>
  </head>
  <body>
|;
	return 1;
}

sub pageEnd {
	print end_html;	
}


sub getJavaScript {	
	my $jscript = <<JS_END;
function viewwndw(wndw,url,width,height)
{
	var attrib = "scrollbars=yes,resizable=yes,width=" + width + ",height=" + height;
	ViewWindow = window.open(url,wndw,attrib);
	ViewWindow.focus();
};
JS_END

	return $jscript;
}

### 2012-03-09 keiths, summary sub to avoid changing much other code
sub requestServer {
	return 0;
}

# Load and organize the CBQoS meta-data, used by both rrddraw.pl and node.pl
# inputs: a sys object, an index and a graphtype
# returns ref to sorted list of names, ref to hash of description/bandwidth/color/index/section
# this function is not exported on purpose, to reduce namespace clashes.
sub loadCBQoS 
{
	my %args = @_;
	my $S = $args{sys};
	my $index = $args{index};
	my $graphtype = $args{graphtype};

	my $NI = $S->ndinfo;
	my $CB = $S->cbinfo;
	my $M = $S->mdl;
	my $node = $NI->{name};

	my ($PMName,  @CMNames, %CBQosValues , @CBQosNames);

	# define line/area colors of the graph
	my @colors = ("3300ff", "33cc33", "ff9900", "660099",
								"ff66ff", "ff3333", "660000", "0099CC", 
								"0033cc", "4B0082","00FF00", "FF4500",
								"008080","BA55D3","1E90FF",  "cc00cc");

	my $direction = $graphtype eq "cbqos-in" ? "in" : "out" ;

	# in the cisco case we have the classmap as basis;
	# for huawei this info comes from the QualityOfServiceStat section
	# which is indexed (and collected+saved) per qos stat entry, NOT interface!
	if (exists $NI->{QualityOfServiceStat})
	{
		my $huaweiqos = $NI->{QualityOfServiceStat};
		for my $k (keys %{$huaweiqos})
		{
			next if ($huaweiqos->{$k}->{ifIndex} != $index or $huaweiqos->{$k}->{Direction} !~ /^$direction/);
			my $CMName = $huaweiqos->{$k}->{ClassifierName};
			push @CMNames, $CMName;
			$PMName = $huaweiqos->{$k}->{Direction}; # there are no policy map names in huawei's qos

			# huawei devices don't expose descriptions or (easily accessible) bw limits
			$CBQosValues{$index.$CMName} = { CfgType => "Bandwidth", CfgRate => undef,
																			 CfgIndex => $k, CfgItem =>  undef,
																			 CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => "QualityOfServiceStat",
																			 # ds names: bytes for in, out, and drop (aka prepolicy postpolicy drop in cisco parlance),
																			 # then packets and nobufdroppkt (which huawei doesn't have)
																			 CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets),undef],
			};
		}
	}
	else													# the cisco case
	{
		$PMName = $CB->{$index}{$direction}{PolicyMap}{Name};
		
		foreach my $k (keys %{$CB->{$index}{$direction}{ClassMap}}) {
			my $CMName = $CB->{$index}{$direction}{ClassMap}{$k}{Name};
			push @CMNames , $CMName if $CMName ne "";

			$CBQosValues{$index.$CMName} = { CfgType => $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Descr'},
																			 CfgRate => $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Value'},
																			 CfgIndex => $index, CfgItem => undef,
																			 CfgUnique => $k,  # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => $graphtype,
																			 CfgDSNames => [qw(PrePolicyByte PostPolicyByte DropByte PrePolicyPkt),
																											undef,"DropPkt", "NoBufDropPkt"]};
		}
	}

	# order the buttons of the classmap names for the Web page
	@CMNames = sort {uc($a) cmp uc($b)} @CMNames;

	my @qNames;
	my @confNames = split(',', $M->{node}{cbqos}{order_CM_buttons});
	foreach my $Name (@confNames) {
		for (my $i=0; $i<=$#CMNames; $i++) {
			if ($Name eq $CMNames[$i] ) {
				push @qNames, $CMNames[$i] ; # move entry
				splice (@CMNames,$i,1);
				last;
			}
		}
	}

	@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
	if ($#CBQosNames) { 
		# colors of the graph in the same order
		for my $i (1..$#CBQosNames) {
			if ($i < $#colors ) {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = $colors[$i-1];
			} else {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = "000000";
			}
		}
	}

	return \(@CBQosNames,%CBQosValues);
} # end loadCBQos





1;
