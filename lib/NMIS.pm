#
## $Id: NMIS.pm,v 8.43 2012/10/02 05:45:49 keiths Exp $
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

# added for authentication
use CGI::Pretty qw(:standard *table *Tr *td *Select *form escape);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION );

use Exporter;

#! Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

$VERSION = "8.3.16G";

@ISA = qw(Exporter);

@EXPORT = qw(	
		loadLinkDetails
		loadNodeTable
		loadLocalNodeTable
		loadNodeSummary
		loadNodeInfoTable
		loadGroupTable
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
		loadServiceStatusTable
		loadBusinessServicesTable
		loadWindowStateTable
		loadInterfaceInfo
		loadInterfaceInfoShort
		loadEnterpriseTable
		loadNodeConfTable
		loadOutageTable
		loadInterfaceTypes
		loadCfgTable

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

		getSummaryStats
		getGroupSummary
		getNodeSummary
		getLevelLogEvent
		overallNodeStatus
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
	if ($C->{db_nodes_sql} eq 'true') {
		return DBfunc::->select(table=>'Nodes');
	} else {
		return loadTable(dir=>'conf',name=>'Nodes');
	}
}

sub loadNodeTable {

	my $reload = 'false';

	my $C = loadConfTable();

	if ($C->{server_master} eq 'true') {
		# check modify of remote node tables
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			my $name = "nmis-${srv}-Nodes";
			if (! loadTable(dir=>'var',name=>$name,check=>'true') ) {
				$reload = 'true';
			}
		}
	}

	if (not defined $NT_cache or ( mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		$reload = 'true';
	}

	return $NT_cache if $reload eq 'false';

	# rebuild tables
	$NT_cache = undef;
	$GT_cache = undef;

	my $LNT = loadLocalNodeTable();

	foreach my $node (keys %{$LNT}) {
		$NT_cache->{$node}{server} = $C->{server_name};
		foreach my $k (keys %{$LNT->{$node}} ) {
			$NT_cache->{$node}{$k} = $LNT->{$node}{$k};
		}
		if ( getbool($LNT->{$node}{active})) {
			$GT_cache->{$LNT->{$node}{group}} = $LNT->{$node}{group};
		}
	}
	$NT_modtime = mtimeFile(dir=>'conf',name=>'Nodes');

	if ($C->{server_master} eq 'true') {
		# check modify of remote node tables
		my $ST = loadServersTable();	
		my $NT;
		for my $srv (keys %{$ST}) {
			# Relies on nmis.pl getting the file every 5 minutes.
			my $name = "nmis-${srv}-Nodes";
	
			if (($NT = loadTable(dir=>'var',name=>$name)) ) {
				foreach my $node (keys %{$NT}) {
					$NT_cache->{$node}{server} = $srv ;
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
	return $NT_cache;
}

sub loadGroupTable {

	return $GT_cache if defined ;

	loadNodeTable();

	return $GT_cache;
}

sub loadFileOrDBTable {
	my $table = shift;
	my $ltable = lc $table;

	my $C = loadConfTable();
	if ($C->{"db_${ltable}_sql"} eq 'true') {
		return DBfunc::->select(table=>$table);
	} else {
		return loadTable(dir=>'conf',name=>$table);
	}
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
sub loadServiceStatusTable {
	return loadFileOrDBTable('ServiceStatus');
}
sub loadBusinessServicesTable {
	return loadFileOrDBTable('BusinessServices');
}
sub loadWindowStateTable {
	return loadFileOrDBTable('WindowState');
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

sub loadCfgTable {
	my %args = @_;
	my $table = $args{table};
	
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
				{ 'mail_combine' => { display => 'popup', value => ['true','false']}}
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

# !! this sub intended for write on var/nmis-event.nmis only with a previously open filehandle !!
# The lock on the open file must be maintained while the hash is being updated
# to prevent another thread from opening and writing some other changes before we write our thread's hash copy back
# we also need to make sure that we process the hash quickly, to avoid multithreading becoming singlethreading,
# because of the lock being maintained on nmis-event.nmis

sub writeEventStateLock {
	my %args = @_;
	my $ET = $args{table};
	my $handle = $args{handle};

	writeTable(dir=>'var',name=>'nmis-event',data=>$ET,handle=>$handle);

#	$ET_cache = undef;

	return;
}

# improved locking on var/nmis-event.nmis
# this sub intended for read on nmis-event.nmis only

sub loadEventStateNoLock {
	my %args = @_;
	my $type = $args{type};

	my @eventdetails;
	my $node;
	my $event;
	my $level;
	my $details;
	my $event_hash;
	my %eventTable;
	my $modtime;

	my $C = loadConfTable();

	if ($C->{db_events_sql} eq 'true') {
		if ($type eq 'Node_Down') {	# used by fpingd
			return DBfunc::->select(table=>'Events',column=>'event,node,element',where=>'event=\'Node Down\'');
		} else {
			return DBfunc::->select(table=>'Events');	# full table
		}
	} else {
		# does the file exist
		if ( not -r "$C->{'<nmis_var>'}/nmis-event.nmis") {
			my %hash = ();
			writeTable(dir=>'var',name=>"nmis-event",data=>\%hash); # create an empty file
		}
		my $ET = loadTable(dir=>'var',name=>'nmis-event');
		return $ET;
	}
}

# !!!this sub intended for read and LOCK on nmis-event.nmis only - MUST use writeEventStateLock to write the hash back from this call!!!
# need to maintain a lock on the file while the event hash is being processed by this thread
# must pass our filehandle back to writeEventStateLock
sub loadEventStateLock {

	my $C = loadConfTable();

	if ($C->{db_events_sql} eq 'true') {
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
	if ($C->{server_master} eq "true" or $master eq "true") {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
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
	
	if ( $event =~ /Proactive/ ) {
		my $i = 0;
		my $ev = '';
		foreach my $index ( split /( )/ , $event ) {	# limit length
			$ev .= $index;
			last if $i++ >= 6 or $index eq '';				# max of 4 splits, with no trailing space.
		}
		$event = $ev;
	}

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

	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		$ET = loadEventStateNoLock();
	}

	if ( exists $ET->{$event_hash}{node} ) {
		return 1;
	}
	else {
		return; 
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

	my $C = loadConfTable();

	my $event_hash = eventHash($node,$event,$element);

	# load the event State for reading only.
	my $ET;
	if ($S->{ET} ne '') {
		# event table already loaded in sys object
		$ET = $S->{ET};
	} else {
		if ($C->{db_events_sql} eq 'true') {
			$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
		} else {
			$ET = loadEventStateNoLock();
		}
	}

	my $outage;

	if (exists $ET->{$event_hash}{current} and $ET->{$event_hash}{current} eq 'true') {
		# The opposite of this event exists log an UP and delete the event

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
			# for thresholds where high = good
			if ( $args{value} >= $args{reset} ) {
				return unless $args{value} > $args{reset} * 1.1;
			} else {
			# for thresholds where low = good
				return unless $args{value} < $args{reset} * 0.9;
			}
			$event = "$event Closed";
		}
		elsif ( $event =~ /down/i ) {
			$event =~ s/down/Up/i;
		}

		$details = "$details Time=$outage";
		$ET->{$event_hash}{current} = 'false'; # next processing by escalation routine

		($level,$log) = getLevelLogEvent(sys=>$S,event=>$event,level=>'Normal');

		my $OT = loadOutageTable();
		
		my ($otg,$key) = outageCheck(node=>$node,time=>time());
		if ($otg eq 'current') {
			$details = "$details change=$OT->{$key}{change}";
		}

		if ($C->{db_events_sql} eq 'true') {
			dbg("event $event_hash marked for UP notify and delete");
			DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
		} else {
			# re-open the file with a lock, as we to wish to update
			my ($ETL,$handle) = loadEventStateLock();
			# make sure we still have a valid event
			if ( $ETL->{$event_hash}{current} eq 'true' ) {
				dbg("event $event_hash marked for UP notify and delete");
				$ETL->{$event_hash}{current} = 'false';
				### 2013-02-07 keiths, fixed stateful event properties not clearing.
				$ETL->{$event_hash}{event} = $event;
				$ETL->{$event_hash}{details} = $details;
				$ETL->{$event_hash}{level} = $level;
			}
			writeEventStateLock(table=>$ETL,handle=>$handle);
		}

		if ($log eq 'true') {
			logEvent(node=>$S->{name},event=>$event,level=>$level,element=>$element,details=>$details);
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

	my $C = loadConfTable();

	dbg("Start of Notify");

	my $event_hash = eventHash($S->{name},$event,$element);
	my $ET;

	if ($S->{ET} ne '') {
		# event table already loaded in sys object
		$ET = $S->{ET};
	} else {
		if ($C->{db_events_sql} eq 'true') {
			$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
		} else {
			$ET = loadEventStateNoLock();
		}
	}

	if ( not exists $ET->{$event_hash}{current} ) {
		# get level(if not defined) and log status from Model
		($level,$log) = getLevelLogEvent(sys=>$S,event=>$event,level=>$level);

		if ($event ne 'Node Reset') {
			# Push the event onto the event table.
			eventAdd(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
		}
	} else {
		# event exists, maybe a level change of proactive threshold
		if ($event =~ /Proactive/ ) {
			if ($ET->{$event_hash}{level} ne $level) {
				# change of level
				$ET->{$event_hash}{level} = $level; # update cache
				if ($C->{db_events_sql} eq 'true') {
					DBfunc::->update(table=>'Events',data=>$ET->{$event_hash},index=>$event_hash);
				} else {
					my ($ETL,$handle) = loadEventStateLock();
					$ETL->{$event_hash}{level} = $level;
					writeEventStateLock(table=>$ETL,handle=>$handle);
				}
			$log = 'true';
			$details .= " Updated";
			}
		} else {
			dbg("Event node=$node event=$event element=$element already in Event table");
		}
	}
	# log events
	if ( $log eq 'true' ) {
		logEvent(node=>$node,event=>$event,level=>$level,element=>$element,details=>$details);
	}

	dbg("Finished");
} # end notify

sub getLevelLogEvent {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $event = $args{event};
	my $level = $args{level};

	my $mdl_level;
	my $log = 'true';
	my $pol_event;

	my $role = $NI->{system}{roleType} || 'access' ;
	my $type = $NI->{system}{nodeType} || 'router' ;

	# Get the event policy and the rest is easy.
	if ( $event !~ /Proactive/i ) {
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
		} elsif ($mdl_level = $M->{event}{event}{default}{lc $role}{level}) {
			$log = $M->{event}{event}{default}{lc $role}{logging};
		} else {
			$mdl_level = 'Major';
			# not found, use default
			logMsg("node=$NI->{system}{name}, event=$event, role=$role not found in class=event of model=$NI->{system}{nodeModel}"); 
		}
	}

	### 2012-03-11 keiths, this was the code causing Node Up to be Oozosl instead of Normal.
	#$level |= $mdl_level;
	if ($mdl_level) {
		$level = $mdl_level;
	}
	return $level,$log;
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

	my $C = loadConfTable();

	my $ET;
	my $handle;
	my $new_event = 0;
	my $event_hash = eventHash($node,$event,$element);

	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		($ET,$handle) = loadEventStateLock();
	}

	# before we log check the state table if there is currently an event outstanding.
	if (not exists $ET->{$event_hash}{current}) {
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
		$new_event = 1;
		dbg("event added, node=$node, event=$event, level=$level, element=$element, details=$details");
	##	logMsg("INFO event added, node=$node, event=$event, level=$level, element=$element, details=$details");
	} else {
		dbg("event exist, node=$node, event=$event, level=$level, element=$element, details=$details");
	##	logMsg("INFO event exist, node=$node, event=$event, level=$level, element=$element, details=$details");
	}

	if ($C->{db_events_sql} eq 'true') {
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

	my $delete_event = 0;
	my ($ET,$handle);
	$event_hash = eventHash($node,$event,$element);

	if ($C->{db_events_sql} eq 'true') {
		$ET = DBfunc::->select(table=>'Events',index=>$event_hash);
	} else {
		($ET,$handle) = loadEventStateLock();
	}
	# make sure we still have a valid event
	if ( exists $ET->{$event_hash}{current} ) {
		if ( $ack eq "true" and $ET->{$event_hash}{ack} eq "false"  ) {
			### if a TRAP type event, then trash when ack. event record will be in event log if required
			if ( $ET->{$event_hash}{event} eq "TRAP" ) {
				logEvent(node => $ET->{$event_hash}{node}, event => "deleted event: $ET->{$event_hash}{event}", level => "Normal", element => $ET->{$event_hash}{element});
				delete $ET->{$event_hash};
				$delete_event = 1;
			}
			else {
				logEvent(node => $node, event => $event, level => "Normal", element => $element, details => "acknowledge=true ($user)");
				$ET->{$event_hash}{ack} = "true";
				$ET->{$event_hash}{user} = $user;
			}
		}
		elsif ( $ack eq "false" and $ET->{$event_hash}{ack} eq "true"  ) {
			logEvent(node => $node, event => $event, level => $ET->{$event_hash}{level}, element => $element, details => "acknowledge=false ($user)");
			$ET->{$event_hash}{ack} = "false";
			$ET->{$event_hash}{user} = $user;
		}
	}
	if ($C->{db_events_sql} eq 'true') {
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
	if ($C->{server_master} eq 'true' and $NI->{system}{server} and lc($NI->{system}{server}) ne lc($C->{server_name})) {
		# send request to remote server
		dbg("serverConnect to $NI->{system}{server} for node=$S->{node}");
		return serverConnect(server=>$NI->{system}{server},type=>'send',func=>'summary',node=>$S->{node},
				gtype=>$type,start=>$start,end=>$end,index=>$index,item=>$item);
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
	
	my $NT = loadLocalNodeTable();
	my $ET = loadEventStateNoLock();
	my $OT = loadOutageTable();
	my %nt;
	
	foreach my $nd (keys %{$NT}) {
		next if $NT->{$nd}{active} ne 'true';
		my $NI = loadNodeInfoTable($nd);

		$nt{$nd}{name} = $NI->{system}{name};
		$nt{$nd}{netType} = $NI->{system}{netType};
		$nt{$nd}{group} = $NI->{system}{group};
		$nt{$nd}{roleType} = $NI->{system}{roleType};
		$nt{$nd}{active} = $NT->{$nd}{active};
		$nt{$nd}{ping} = $NT->{$nd}{ping};
		$nt{$nd}{nodeType} = $NI->{system}{nodeType};
		$nt{$nd}{nodeModel} = $NI->{system}{nodeModel};
		$nt{$nd}{nodeVendor} = $NI->{system}{nodeVendor};
		$nt{$nd}{collect} = $NI->{system}{collect};
		$nt{$nd}{lastUpdateSec} = $NI->{system}{lastUpdateSec};
		$nt{$nd}{server} = $C->{'server_name'};
		#
		$nt{$nd}{nodedown} = $NI->{system}{nodedown};
		my $event_hash = eventHash($nd, "Node Down", "Node");
		$nt{$nd}{escalate} = $ET->{$event_hash}{escalate};
		
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
		$nt{$nd}{sysName} = $NI->{system}{sysName} ;
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

	my $S = Sys::->new;
	my $NT = loadNodeTable(); # local + nodes of remote servers
	my $C = loadConfTable();
	
	if ( $start_time eq "" ) { $start_time = "-8 hours"; }
	if ( $end_time eq "" ) { $end_time = time; }

	if ( $start_time eq '-8 hours' ) {
		$filename = "summary8h";
	}
	if ( $start_time eq '-16 hours' ) {
		$filename = "summary16h";
	}

	# load table (from cache)
	if ($filename ne "") {
		my $mtime;
		if ( (($SUM,$mtime) = loadTable(dir=>'var',name=>"nmis-$filename",mtime=>'true')) ) {
			if ($mtime < (time()-900)) {
				logMsg("INFO (nmis) cache file var/nmis-$filename.nmis does not exist or is old; calculate summary");
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
			next if ($NT->{$node}{active} ne 'true' or exists $NT->{$node}{server});
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
			
			#print STDERR "DEBUG: node=$node NI-nodedown=$NI->{system}{nodedown} SUM-nodedown=$SUM->{$node}{nodedown}\n";

			# One way to get node status is to ask Node Info. 
			#$S->init(name=>$node,snmp=>'false'); # need this node info for summary
			#my $NI = $S->ndinfo;
			#if ($NI->{system}{nodedown} eq 'true') {
			#	$SUM->{$node}{nodedown} = 'true';
			#}
			#else {
			#	$SUM->{$node}{nodedown} = 'false';
			#}

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
			if ( $group eq "" or $group eq $NS->{$node}{group} ) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}


	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if ($C->{server_master} eq "true") {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			my $slavefile = "nmis-$srv-$filename";
			dbg("Processing Slave $srv for $slavefile");
			
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavefile) ) {
				my $H = loadTable(dir=>'var',name=>$slavefile);
				for my $node (keys %{$H}) {
					for (keys %{$H->{$node}}) {
						$SUM->{$node}{$_} = $H->{$node}{$_};
					}
				}
			}

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
	
	
	
	
	# copy this hash for modification
	my %summaryHash = %{$SUM} if defined $SUM;
	
	# Insert some nice status info about the devices for the summary menu.
NODE:
	foreach $node (sort keys %{$NT} ) {
		# Only do the group - or everything if no group passed to us.
		if ( $group eq $NT->{$node}{group} or $group eq "") {
			if ( $NT->{$node}{active} eq 'true' ) {
				++$nodecount{counttotal};
				my $outage = '';
				# check nodes
				# Carefull logic here, if nodedown is false then the node is up
				#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
				if (getbool($summaryHash{$node}{nodedown})) {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$NT->{$node}{roleType});
					++$nodecount{countdown};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				} else {
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
	if ($C->{intf_av_modified} eq 'true') {
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

	my ($ET,$handle) = loadEventStateLock();

	foreach my $event_hash ( sort keys %{$ET})  {
		if ( $ET->{$event_hash}{node} eq "$node" ) {
			logEvent(node => "$ET->{$event_hash}{node}", event => "$caller: deleted event: $ET->{$event_hash}{event}", level => "Normal", element => "$ET->{$event_hash}{element}", details => "$ET->{$event_hash}{details}");
			delete $ET->{$event_hash};
		}
	}
	writeEventStateLock(table=>$ET,handle=>$handle);
}

sub overallNodeStatus {
	my $netType = shift;
	my $roleType = shift;
	
	my $node;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $group;
	my $status;

	my %statusHash;

	my $C = loadConfTable();
	my $NT = loadNodeTable();
	my $ET = loadEventStateNoLock();
	my $NS = loadNodeSummary();

	#print STDERR &returnDateStamp." overallNodeStatus: netType=$netType roleType=$roleType\n";

	if ( $netType eq "" and $roleType eq "" ) {
		foreach $node (sort keys %{$NT} ) {
			if ($NT->{$node}{active} eq 'true') {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} ) {
					my $event_hash = eventHash($node,"Node Down","");
					($outage,undef) = outageCheck(node=>$node,time=>time());
					$nodedown = exists $ET->{$event_hash}{node};
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( $NS->{$node}{nodedown} eq "true" ) {
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
			if ($NT->{$node}{active} eq 'true') {
				if ( $NT->{$node}{net} eq "$netType" && $NT->{$node}{role} eq "$roleType" ) {
					my $nodedown = 0;
					my $outage = "";
					if ( $NT->{$node}{server} eq $C->{server_name} ) {
						my $event_hash = eventHash($node,"Node Down","");
						($outage,undef) = outageCheck(node=>$node,time=>time());
						$nodedown = exists $ET->{$event_hash}{node};
					}
					else {
						$outage = $NS->{$node}{outage};
						if ( $NS->{$node}{nodedown} eq "true" ) {
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
	elsif ( $netType ne "" and $roleType eq "" ) {
		$group = $netType; # <<<
		foreach $node (sort keys %{$NT} ) {
			if ( $NT->{$node}{group} eq $group and $NT->{$node}{active} eq 'true') {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} ) {
					my $event_hash = eventHash($node,"Node Down","");
					($outage,undef) = outageCheck(node=>$node,time=>time());
					$nodedown = exists $ET->{$event_hash}{node};
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( $NS->{$node}{nodedown} eq "true" ) {
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

	return $overall_status;
} # end overallNodeStatus

# convert configuration files in dir conf to NMIS8

sub convertConfFiles {

	my $C = loadConfTable();

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
				print " csv file $C->{Nodes_Table} converted to conf/Nodes.nmis\n";
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
			print " csv file $C->{Escalation_Table} converted to conf/Escalation.nmis\n";
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
				print " csv file $C->{\"${name}_Table\"} converted to conf/${name}.nmis\n";
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
sub loadNodeInfoTable {
	my $node = lc shift;
	my $C = loadConfTable();
	if (getbool($C->{cache_var_files})) {
		return loadTable(dir=>'var',name=>"$node-node"); # cached
	} else {
		return loadTable(dir=>'var',name=>"$node-node");
	}
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
					if ($NI->{system}{nodedown} eq 'true') {
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




## EHG 28 Aug for Net::SMTP priority setting on email
##
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
		if ($NMIS::debug) { printf "\tUsing corrected time %s for Contact:$contact, localtime:%s, offset:$$table{$contact}{TimeZone}\n", scalar localtime(time()+($$table{$contact}{TimeZone}*60*60)), scalar localtime();}

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				if ($NMIS::debug) { print "\treturning success on dutytime test for $contact\n";}
				return 1;
			}
			elsif ( $finish_time < $start_time ) { 
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					if ($NMIS::debug) { print "\treturning success on dutytime test for $contact\n";}
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		if ($NMIS::debug) { print "\tNo dutytime defined - returning success assuming $contact is 24x7\n";}
		return 1;
	}
	if ($NMIS::debug) { print "\treturning fail on dutytime test for $contact\n";}
	return;		# dutytime was valid, but no timezone match, return false.
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

	my $C = loadConfTable();

	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $win_width = $C->{win_width}; # window size
	my $win_height = $C->{win_height};

	my $time = time();
	my $clickurl = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=$graphtype&group=$group&node=$node&intf=$intf&server=$server";

	my $src = "$C->{'rrddraw'}?conf=$C->{conf}&act=draw_graph_view&group=$group&graphtype=$graphtype&node=$node&intf=$intf&server=$server".
				"&start=&end=&width=$width&height=$height&time=$time";
	
	### 2012-03-28 keiths, changed graphs to come up in their own Window with the target of node, handy for comparing graphs.
	return a({target=>"Graph-$target",onClick=>"viewwndw(\'$target\',\'$clickurl\',$win_width,$win_height)"},img({alt=>'Network Info',src=>"$src"}));
					
	#return a({href=>"$clickurl",target=>'ViewWindow',onClick=>"viewdoc(\'$clickurl\',$win_width,$win_height)"},img({alt=>'Network Info',src=>"$src"}));
}

sub createHrButtons {
	my %args = @_;
	my $user = $args{user};
	my $node = $args{node};
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

	my $server = ($C->{server_master} eq 'true') ? '' : $NI->{system}{server};

	push @out, start_table({class=>'table'}),start_Tr;
	push @out, td({class=>'header'},'Node ',
			a({href=>"network.pl?%conf=$Q->{conf}&act=network_node_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},$NI->{system}{name}));

	if (scalar keys %{$NI->{module}}) {
		push @out, td({class=>'header'},
			a({href=>"network.pl?%conf=$Q->{conf}&act=network_module_view&node=$node&server=$server"},"modules"));
	}

	if ($NI->{system}{collect} eq 'true') {
		push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_interface_view_all&node=$node&refresh=$refresh&widget=$widget&server=$server"},"interfaces"));
		push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_interface_view_act&node=$node&refresh=$refresh&widget=$widget&server=$server"},"active intf"));
		if ($NI->{system}{nodeType} =~ /router|switch/) {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_port_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"ports"));
		}
		if ($NI->{system}{nodeType} =~ /server/) {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_storage_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"storage"));
		}
		if (defined $NI->{database}{service}) {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_service_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"services"));
		}
		### 2012-12-20 keiths, adding services list support
		if (defined $NI->{services}) {
					push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_service_list&node=$node&refresh=$refresh&widget=$widget&server=$server"},"service list"));
		}	
		### 2012-12-13 keiths, adding generic temp support
		if ($NI->{env_temp} ne '' or $NI->{env_temp} ne '') {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_environment_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{akcp_temp} ne '' or $NI->{akcp_hum} ne '') {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_environment_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{cssgroup} ne '') {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_cssgroup_view&node=$node&refresh=false&server=$server"},"Group"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
 		if ($NI->{csscontent} ne '') {
			push @out, td({class=>'header'},
				a({href=>"network.pl?%conf=$Q->{conf}&act=network_csscontent_view&node=$node&refresh=false&server=$server"},"Content"));
		}
	}

	push @out, td({class=>'header'},
			a({href=>"events.pl?%conf=$Q->{conf}&act=event_table_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"events"));
	push @out, td({class=>'header'},
			a({href=>"outages.pl?%conf=$Q->{conf}&act=outage_table_view&node=$node&refresh=$refresh&widget=$widget&server=$server"},"outage"));
	push @out, td({class=>'header'},
			a({href=>"telnet://$NI->{system}{host}",target=>'_blank'},"telnet")) 
				if $C->{view_telnet} eq 'true';
	push @out, td({class=>'header'},
			a({href=>"tools.pl?%conf=$Q->{conf}&act=tool_system_ping&node=$node&refresh=$refresh&widget=$widget&server=$server"},"ping")) 
				if $C->{view_ping} eq 'true';
	push @out, td({class=>'header'},
			a({href=>"tools.pl?%conf=$Q->{conf}&act=tool_system_trace&node=$node&refresh=$refresh&widget=$widget&server=$server"},"trace")) 
				if $C->{view_trace} eq 'true';
	push @out, td({class=>'header'},
			a({href=>"tools.pl?%conf=$Q->{conf}&act=tool_system_mtr&node=$node&refresh=$refresh&widget=$widget&server=$server"},"mtr")) 
				if $C->{view_mtr} eq 'true';
	push @out, td({class=>'header'},
			a({href=>"tools.pl?%conf=$Q->{conf}&act=tool_system_lft&node=$node&refresh=$refresh&widget=$widget&server=$server"},"lft")) 
				if $C->{view_lft} eq 'true';
	push @out, td({class=>'header'},
			a({href=>"http://$NI->{system}{host}",target=>'_blank'},"http")) 
				if $NI->{system}{webserver} eq 'true';

	if ($NI->{system}{server} eq $C->{server_name}) {
		push @out, td({class=>'header'},
				a({href=>"tables.pl?%conf=$Q->{conf}&act=config_table_show&table=Contacts&key=$NI->{system}{sysContact}&node=$node&refresh=$refresh&widget=$widget&server=$server"},"contact"))
					if $NI->{system}{sysContact} ne '';
		push @out, td({class=>'header'},
				a({href=>"tables.pl?%conf=$Q->{conf}&act=config_table_show&table=Locations&key=$NI->{system}{sysLocation}&node=$node&refresh=$refresh&widget=$widget&server=$server"},"location"))
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
	if  ( -f "$C->{'<nmis_conf>'}/Portal.nmis" ) {
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
	if  ( -f "$C->{'<nmis_conf>'}/Servers.nmis" ) {
		# portal menu of nodes or clients to link to.
		my $ST = loadTable(dir=>'conf',name=>"Servers");
		
		my $serverOption;
		
		$serverOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Servers">NMIS Servers</option>\n|;
		
		foreach my $s ( sort {$ST->{$a}{name} cmp $ST->{$b}{name}} keys %{$ST} ) {
			# If the link is part of NMIS, append the config
			
			$serverOption .= qq|<option value="$ST->{$s}{portal_protocol}://$ST->{$s}{portal_host}:$ST->{$s}{portal_port}$ST->{$s}{cgi_url_base}/nmiscgi.pl">$ST->{$s}{name}</option>\n|;
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

sub startNmisPage {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE html>
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
|<!DOCTYPE html>
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
|<!DOCTYPE html>
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


1;
