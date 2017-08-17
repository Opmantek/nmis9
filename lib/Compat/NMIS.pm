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
package Compat::NMIS;
use strict;

our $VERSION = "9.0.0A";

use Time::ParseDate;
use Time::Local;
use Net::hostent;
use Socket;
use URI::Escape;
use JSON::XS 2.01;
use File::Basename;
use feature 'state';						# for new_nmisng
use Carp;
use CGI qw();												# very ugly but createhrbuttons needs it :(

use Fcntl qw(:DEFAULT :flock);  # Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Data::Dumper;

$Data::Dumper::Indent = 1;			# fixme9: costs, should not be enabled

use Compat::IP;
use NMISNG::CSV;
use Compat::DBfunc;							# fixme9: should be removed

use NMISNG;
use NMISNG::Sys;
use NMISNG::rrdfunc;
use NMISNG::Notify;


# fixme9 thise need to go and/or become state vars!
my $NT_cache = undef; # node table (local + remote)
my $NT_modtime; # file modification time
my $LNT_cache = undef; # local node table
my $LNT_modtime;
my $GT_cache = undef; # group table
my $GT_modtime;
my $ST_cache = undef; # server table
my $ST_modtime;

# this is a compatibility helper to quickly gain access
# to ONE persistent/shared nmisng object
#
# args: nocache (optional, if set create new nmisng object)
# returns: ref to one nmisng object
sub new_nmisng
{
	my (%args) = @_;
	state ($_nmisng);

	if (ref($_nmisng) ne "NMISNG" or $args{nocache})
	{
		# Carp::cluck("creating new nmisng obj in $$");

		my $C = NMISNG::Util::loadConfTable();
		my $debug = NMISNG::Util::getDebug();
		die "Config required" if ( ref( $C ) ne "HASH" );

		# log level is controlled by debug (from commandline or config file),
		# output is stderr if debug came from command line, log file otherwise
		my $logfile = $C->{'<nmis_logs>'} . "/nmis.log";

		my $error = NMISNG::Util::setFileProtDiag(file => $logfile)
				if (-f $logfile);
		warn "failed to set permissions: $error\n" if ($error);

		my $logger = NMISNG::Log->new(
			level => $debug // $C->{log_level},
			path  =>  ($debug? undef : $logfile ),
				);

		$_nmisng = NMISNG->new(
			config => $C,
			log => $logger,
				);
	}
	return $_nmisng;
}

# load local node table and store also in cache
sub loadLocalNodeTable {
	my $nmisng = new_nmisng();
	# get all nodes
	my $modelData = $nmisng->get_nodes_model();
	my $data = $modelData->data();
	my %map = map { $_->{name} => $_ } @$data;
	return \%map;
}

sub loadNodeTable {

	my $reload = 'false';

	my $C = NMISNG::Util::loadConfTable();

	if (NMISNG::Util::getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $name = "nmis-${srv}-Nodes";
			if (! NMISNG::Util::loadTable(dir=>'var',name=>$name,check=>'true') ) {
				$reload = 'true';
			}
		}
	}

	if (not defined $NT_cache or ( NMISNG::Util::mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		$reload = 'true';
	}

	return $NT_cache if NMISNG::Util::getbool($reload,"invert");

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
		if ( NMISNG::Util::getbool($LNT->{$node}{active})) {
			$GT_cache->{$LNT->{$node}{group}} = $LNT->{$node}{group};
		}
	}
	$NT_modtime = NMISNG::Util::mtimeFile(dir=>'conf',name=>'Nodes');

	if (NMISNG::Util::getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();
		my $NT;
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# Relies on nmis.pl getting the file every 5 minutes.
			my $name = "nmis-${srv}-Nodes";
			my $server_priority = $ST->{$srv}{server_priority} || 5;

			if (($NT = NMISNG::Util::loadTable(dir=>'var',name=>$name)) ) {
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
						if ( NMISNG::Util::getbool($NT->{$node}{active})) {
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

	if( not defined $GT_cache or not defined $NT_cache or ( NMISNG::Util::mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		loadNodeTable();
	}

	return $GT_cache;
}

sub tableExists {
	my $table = shift;
	my $exists = 0;

	if (NMISNG::Util::existFile(dir=>"conf",name=>$table)) {
		$exists = 1;
	}

	return $exists;
}

sub loadFileOrDBTable {
	my $table = shift;
	my $ltable = lc $table;

	my $C = NMISNG::Util::loadConfTable();
	if (NMISNG::Util::getbool($C->{"db_${ltable}_sql"})) {
		return Compat::DBfunc::->select(table=>$table);
	} else {
		return NMISNG::Util::loadTable(dir=>'conf',name=>$table);
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
	return NMISNG::Util::loadTable(dir=>'conf',name=>'Links');
}

sub loadEscalationsTable {
	return loadFileOrDBTable('Escalations');
}

sub loadWindowStateTable
{
	my $C = NMISNG::Util::loadConfTable();

	return {} if (not -r NMISNG::Util::getFileName(file => "$C->{'<nmis_var>'}/nmis-windowstate"));
	return NMISNG::Util::loadTable(dir=>'var',name=>'nmis-windowstate');
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
		NMISNG::Util::logMsg("ERROR (nmis) node=$name does not exists in table Nodes");
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
			{ 'roletype_list' => { display => 'text', value => ['']}},
			{ 'nettype_list' => { display => 'text', value => ['']}},
			{ 'nodetype_list' => { display => 'text', value => ['']}},
			{ 'nmis_host' => { display => 'text', value => ['localhost']}},
				{ 'domain_name' => { display => 'text', value => ['']}},
				{ 'cache_summary_tables' => { display => 'popup', value => ["true", "false"]}},
				{ 'cache_var_tables' => { display => 'popup', value => ["true", "false"]}},
				{ 'page_refresh_time' => { display => 'text', value => ['60']}},
				{ 'os_posix' => { display => 'popup', value => ["true", "false"]}},
				{ 'os_cmd_read_file_reverse' => { display => 'text', value => ['tac']}},
				{ 'os_cmd_file_decompress' => { display => 'text', value => ['gzip -d -c']}},
				{ 'os_kernelname' => { display => 'text', value => ['']}},
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
				{ '<url_base>' => { display => 'text', value => ['/nmis9']}},
				{ '<cgi_url_base>' => { display => 'text', value => ['/cgi-nmis9']}},
				{ '<menu_url_base>' => { display => 'text', value => ['/menu9']}},
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

	my $C = NMISNG::Util::loadConfTable();

	my $ciscoHeader = "Cisco Systems NM";
	my @nodedetails;
	my @statsSplit;
	my $nodeType;

	if ( $file eq "" ) {
		print "\t the type=rme option requires a file arguement for source rme CSV file\ni.e. $0 type=rme rmefile=/data/file/rme.csv\n";
		return;
	}

	sysopen(DATAFILE, "$file", O_RDONLY) or warn NMISNG::Util::returnTime." loadRMENodes, Cannot open $file. $!\n";
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
				# Convert role c, d or a to core, distribution or access (or default)
				if ( $statsSplit[3] eq "c" ) { $nodeTable{$nodedetails[0]}{roleType} = "core"; }
				elsif ( $statsSplit[3] eq "d" ) { $nodeTable{$nodedetails[0]}{roleType} = "distribution"; }
				elsif ( $statsSplit[3] eq "a" ) { $nodeTable{$nodedetails[0]}{roleType} = "access"; }
				else
				{
					$nodeTable{$nodedetails[0]}{roleType} = "default";
				}
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
	return NMISNG::Util::loadTable(dir=>'conf',name=>'Servers');
}

### 2011-01-06 keiths, loading node summary from cached files!
sub loadNodeSummary {
	my %args = @_;
	my $group = $args{group};
	my $master = $args{master};

	my $C = NMISNG::Util::loadConfTable();
	my $SUM;

	my $nodesum = "nmis-nodesum";
	# I should now have an up to date file, if I don't log a message
	if (NMISNG::Util::existFile(dir=>'var',name=>$nodesum) ) {
		NMISNG::Util::dbg("Loading $nodesum");
		my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			if ( $group eq "" or $group eq $NS->{$node}{group} ) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}

	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if (NMISNG::Util::getbool($C->{server_master}) or NMISNG::Util::getbool($master)) {
		NMISNG::Util::dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $slavenodesum = "nmis-$srv-nodesum";
			NMISNG::Util::dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (NMISNG::Util::existFile(dir=>'var',name=>$slavenodesum) ) {
				my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$slavenodesum);
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




# this is the most official reporter of node status, and should be
# used instead of just looking at local system info nodedown
#
# reason for looking for events (instead of wmidown/snmpdown markers):
# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
# file cannot be guaranteed to be up to date if that happens.
sub nodeStatus {
	my %args = @_;
	my $catchall_data = $args{catchall_data};
	die "nodeStatus requires catchall_data" if (!$catchall_data);
	my $C = NMISNG::Util::loadConfTable();

	# 1 for reachable
	# 0 for unreachable
	# -1 for degraded
	my $status = 1;

	my $node_down = "Node Down";
	my $snmp_down = "SNMP Down";
	my $wmi_down_event = "WMI Down";

	# ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (NMISNG::Util::getbool($catchall_data->{ping},"invert")
			 and ( eventExist($catchall_data->{name}, $snmp_down, "")
						 or eventExist($catchall_data->{name}, $wmi_down_event, "")))
	{
		$status = 0;
	}
	# ping enabled, but unpingable -> down
	elsif ( eventExist($catchall_data->{name}, $node_down, "") ) {
		$status = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( NMISNG::Util::getbool($catchall_data->{collect}) and
					( eventExist($catchall_data->{name}, $snmp_down, "")
						or eventExist($catchall_data->{name}, $wmi_down_event, "")))
	{
		$status = -1;
	}
	# let NMIS use the status summary calculations
	elsif (
		defined $C->{node_status_uses_status_summary}
		and NMISNG::Util::getbool($C->{node_status_uses_status_summary})
		and defined $catchall_data->{status_summary}
		and defined $catchall_data->{status_updated}
		and $catchall_data->{status_summary} <= 99
		and $catchall_data->{status_updated} > time - 500
	) {
		$status = -1;
	}
	else {
		$status = 1;
	}

	return $status;
}

# this is a variation of nodeStatus, which doesn't say why a node is degraded
# args: system object (doesn't have to be init'd with snmp/wmi)
# returns: hash of error (if dud args), overall (-1,0,1), snmp_enabled (0,1), snmp_status (0,1,undef if unknown),
# ping_enabled and ping_status, wmi_enabled and wmi_status
sub PreciseNodeStatus
{
	my (%args) = @_;
	my $S = $args{system};
	return ( error => "Invalid arguments, no Sys object!" ) if (ref($S) ne "NMISNG::Sys");

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $C = NMISNG::Util::loadConfTable();

	my $nodename = $catchall_data->{name};

	# reason for looking for events (instead of wmidown/snmpdown markers):
	# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
	# file cannot be guaranteed to be up to date if that happens.

	# HOWEVER the markers snmpdown and wmidown are present iff the source was enabled at the last collect,
	# and if collect was true as well.
	my %precise = ( overall => 1, # 1 reachable, 0 unreachable, -1 degraded
									snmp_enabled =>  defined($catchall_data->{snmpdown})||0,
									wmi_enabled => defined($catchall_data->{wmidown})||0,
									ping_enabled => NMISNG::Util::getbool($catchall_data->{ping}),
									snmp_status => undef,
									wmi_status => undef,
									ping_status => undef );

	$precise{ping_status} = (eventExist($nodename, "Node Down")?0:1) if ($precise{ping_enabled}); # otherwise we don't care
	$precise{wmi_status} = (eventExist($nodename, "WMI Down")?0:1) if ($precise{wmi_enabled});
	$precise{snmp_status} = (eventExist($nodename, "SNMP Down")?0:1) if ($precise{snmp_enabled});

	# overall status: ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (!$precise{ping_enabled}
			and ( ($precise{wmi_enabled} and !$precise{wmi_status})
						or ($precise{snmp_enabled} and !$precise{snmp_status}) ))
	{
		$precise{overall} = 0;
	}
	# ping enabled, but unpingable -> unreachable
	elsif ($precise{ping_enabled} && !$precise{ping_status} )
	{
		$precise{overall} = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( ($precise{wmi_enabled} and !$precise{wmi_status})
					or ($precise{snmp_enabled} and !$precise{snmp_status}) )
	{
		$precise{overall} = -1;
	}
	# let NMIS use the status summary calculations, if recently updated
	elsif ( defined $C->{node_status_uses_status_summary}
					and NMISNG::Util::getbool($C->{node_status_uses_status_summary})
					and defined $catchall_data->{status_summary}
					and defined $catchall_data->{status_updated}
					and $catchall_data->{status_summary} <= 99
					and $catchall_data->{status_updated} > time - 500 )
	{
		$precise{overall} = -1;
	}
	else
	{
		$precise{overall} = 1;
	}
	return %precise;
}

sub logConfigEvent {
	my %args = @_;
	my $dir = $args{dir};
	delete $args{dir};

	NMISNG::Util::dbg("logConfigEvent logging Json event for event $args{event}");
	my $event_hash = \%args;
	$event_hash->{startdate} = time;
	logJsonEvent(event => $event_hash, dir => $dir);
}

sub getLevelLogEvent {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $event = $args{event};
	my $level = $args{level};

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $mdl_level;
	my $log = 'true';
	my $syslog = 'true';
	my $pol_event;

	my $role = $catchall_data->{roleType} || 'access' ;
	my $type = $catchall_data->{nodeType} || 'router' ;

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
			NMISNG::Util::logMsg("node=$catchall_data->{name}, event=$event, role=$role not found in class=event of model=$catchall_data->{nodeModel}");
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

sub getSummaryStats
{
	my %args = @_;
	my $type = $args{type};
	my $index = $args{index}; # optional
	my $item = $args{item};
	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $M  = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = NMISNG::Util::loadConfTable();
	NMISNG::rrdfunc::require_RRDs(config=>$C);
	if (NMISNG::Util::getbool($C->{server_master}) and $catchall_data->{server}
			and lc($catchall_data->{server}) ne lc($C->{server_name}))
	{
		# send request to remote server
		NMISNG::Util::dbg("serverConnect to $catchall_data->{server} for node=$S->{node}");
		#return serverConnect(server=>$catchall_data->{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index,item=>$item);
	}

	my $db;
	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats;

	NMISNG::Util::dbg("Start type=$type, index=$index, start=$start, end=$end");

	# check if type exist in nodeInfo
	# fixme this cannot work - must CHECK existence, not make path blindly
	if (!($db = $S->makeRRDname(graphtype=>$type, index=>$index, item=>$item)))
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		#NMISNG::Util::logMsg("ERROR ($S->{name}) no rrd name found for type $type, index $index, item $item");
		return;
	}

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$type} eq "") {
		NMISNG::Util::logMsg("ERROR ($S->{name}) type=$type not found in section stats of model=$catchall_data->{nodeModel}");
		return;
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the PreciseNodeStatus workaround
		# to figure out if the right source is enabled
		my %status = PreciseNodeStatus(system => $S);
		# fixme unclear how to find the model's rrd section for this thing?

		my $severity = "INFO";
		NMISNG::Util::logMsg("$severity ($S->{name}) database=$db does not exist, snmp is "
					 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
					 .($status{wmi_enabled}?"enabled":"disabled") );
		return;
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	# escape any : chars which might be in the database name, e.g handling C: in the RPN
	$db =~ s/:/\\:/g;
	if( $index )
	{
		no strict;
		$database = $db; # global
		#inventory keyed by index and ifDescr so we need partial
		my $intf_inventory = $S->inventory( concept => "interface", index => $index, partial => 1, nolog => 1);
		if( $intf_inventory )
		{
			my $data = $intf_inventory->data();
			$speed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeed} if $index ne "";
			$outSpeed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeedIn} if $index ne "" and $data->{ifSpeedIn};
			$outSpeed = $data->{ifSpeedOut} if $index ne "" and $data->{ifSpeedOut};
		}
		# read from Model and translate variable ($database etc.) rrd options
		foreach my $str (@{$M->{stats}{type}{$type}}) {
			my $s = $str;
			$s =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			if ($s =~ /ERROR/) {
				NMISNG::Util::logMsg("ERROR ($S->{name}) model=$catchall_data->{nodeModel} type=$type ($str) in expanding variables, $s");
				return; # error
			}
			push @option, $s;
		}
	}
	if (NMISNG::Util::getbool($C->{debug})) {
		foreach (@option) {
			NMISNG::Util::dbg("option=$_",2);
		}
	}

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error())) {
		NMISNG::Util::logMsg("ERROR ($S->{name}) RRD graph error database=$db: $ERROR");
	} else {
		##NMISNG::Util::logMsg("INFO result type=$type, node=$catchall_data->{name}, $catchall_data->{nodeType}, $catchall_data->{nodeModel}, @$graphret");
		if ( scalar(@$graphret) ) {
			# fixme9: this should NOT return nan, but undef - upstreams should check for undef, not string NaN;
			# fixme9: must also numify the values
			# fixme9:  see getsubconceptstats for implementation
			map { s/nan/NaN/g } @$graphret;			# make sure a NaN is returned !!
			foreach my $line ( @$graphret ) {
				my ($name,$value) = split "=", $line;
				if ($index ne "") {
					$summaryStats{$index}{$name} = $value; # use $index as primairy key
				} else {
					$summaryStats{$name} = $value;
				}
				NMISNG::Util::dbg("name=$name, index=$index, value=$value",2);
				##NMISNG::Util::logMsg("INFO name=$name, index=$index, value=$value");
			}
			return \%summaryStats;
		} else {
			NMISNG::Util::logMsg("INFO ($S->{name}) no info return from RRD for type=$type index=$index item=$item");
		}
	}
	return;
}

# compute stats via rrd for a given subconcept,
# returns: hashref with numeric values - or undef if infty or nan
# args: inventory,subconcept,start,end,sys, all required
#   subconcept is used to find the storage (db) and also the section in the stats
#   file.
#  stats_section - if provided this will be used to look up the location of the stats
#   instead of subconcept. this is required for concepts like cbqos where the subconcept
#   name is variable and based on class names which come from the device
#
# note: this does NOT return the string NaN, because json::xs utterly misencodes that
sub getSubconceptStats
{
	my %args = @_;
	my $inventory = $args{inventory};
	my $subconcept = $args{subconcept};
	my $stats_section = $args{stats_section} // $args{subconcept};

	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $M  = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = NMISNG::Util::loadConfTable();
	NMISNG::rrdfunc::require_RRDs(config=>$C);
	if (NMISNG::Util::getbool($C->{server_master}) and $catchall_data->{server}
			and lc($catchall_data->{server}) ne lc($C->{server_name}))
	{
		# send request to remote server
		NMISNG::Util::dbg("serverConnect to $catchall_data->{server} for node=$S->{node}");
		#return serverConnect(server=>$catchall_data->{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index);
	}

	my $db = $inventory->find_subconcept_type_storage( subconcept => $subconcept, type => 'rrd' );
	my $data = $inventory->data;
	my $index = $data->{index};

	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats; # return value

	NMISNG::Util::dbg("Start subconcept=$subconcept, index=$index, start=$start, end=$end");

	# check if storage exists
	if (!$db)
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		NMISNG::Util::logMsg("ERROR ($S->{name}) no rrd name found for subconcept $subconcept, index $index");
		return;
	}
	$db = $C->{database_root}.$db;

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$stats_section} eq "") {
		NMISNG::Util::dbg("($S->{name}) subconcept=$subconcept not found in section stats of model=$catchall_data->{nodeModel}, this may be expected");
		return;
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the PreciseNodeStatus workaround
		# to figure out if the right source is enabled
		my %status = PreciseNodeStatus(system => $S);
		# fixme unclear how to find the model's rrd section for this thing?

		my $severity = "INFO";
		NMISNG::Util::logMsg("$severity ($S->{name}) database=$db does not exist, snmp is "
					 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
					 .($status{wmi_enabled}?"enabled":"disabled") );
		return;
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	# escape any : chars which might be in the database name, e.g handling C: in the RPN
	$db =~ s/:/\\:/g;

	# NOTE: is there any reason we don't use parse string or some other generic function here?
	{
		no strict;
		$database = $db; # global

		if( $inventory->concept eq 'interface' )
		{
			my $data = $inventory->data();
			$speed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeed} if $index ne "";
			$outSpeed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeedIn} if $index ne "" and $data->{ifSpeedIn};
			$outSpeed = $data->{ifSpeedOut} if $index ne "" and $data->{ifSpeedOut};
		}
		# read from Model and translate variable ($database etc.) rrd options
		foreach my $str (@{$M->{stats}{type}{$stats_section}}) {
			my $s = $str;
			$s =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			if ($s =~ /ERROR/) {
				NMISNG::Util::logMsg("ERROR ($S->{name}) model=$catchall_data->{nodeModel} subconcept=$subconcept ($str) in expanding variables, $s");
				return; # error
			}
			push @option, $s;
		}
	}

	if (NMISNG::Util::getbool($C->{debug})) {
		foreach (@option) {
			NMISNG::Util::dbg("option=$_",2);
		}
	}

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error()))
	{
		NMISNG::Util::logMsg("ERROR ($S->{name}) RRD graph error database=$db: $ERROR");
	}
	else
	{
		##NMISNG::Util::logMsg("INFO result subconcept=$subconcept, node=$catchall_data->{name}, $catchall_data->{nodeType}, $catchall_data->{nodeModel}, @$graphret");
		if ( scalar(@$graphret) )
		{
			foreach my $line ( @$graphret )
			{
				my ($name,$value) = split "=", $line;

				# set value to undef if this is infty or NaN/nan...
				if ($value != $value) 	# standard nan test
				{
					$value = undef;
				}
				else
				{
					$value += 0.0;												# force to number
				}

				$summaryStats{$name} = $value;

				NMISNG::Util::dbg("name=$name, index=$index, value=$value",2);
			}
			return \%summaryStats;
		}
		else
		{
			NMISNG::Util::logMsg("INFO ($S->{name}) no info return from RRD for subconcept=$subconcept index=$index");
		}
	}
	return;
}

### 2011-12-29 keiths, added for consistent nodesummary generation
sub getNodeSummary {
	my %args = @_;
	my $C = $args{C};
	my $group = $args{group};

	my $NT = loadLocalNodeTable();
	my $OT = loadOutageTable();
	my %nt;
	my $nmisng = new_nmisng();

	### 2015-01-13 keiths, making the field list configurable, these are extra properties, there will be some mandatory ones.
	my $node_summary_field_list = "customer,businessService";
	if ( defined $C->{node_summary_field_list} and $C->{node_summary_field_list} ne "" ) {
		$node_summary_field_list = $C->{node_summary_field_list};
	}

	my @node_summary_properties = split(",",$node_summary_field_list);

	foreach my $nd (keys %{$NT}) {
		next if (!NMISNG::Util::getbool($NT->{$nd}{active}));
		next if $group ne '' and $NT->{$nd}{group} !~ /$group/;

		# could use name here I guess
		my $nmisng_node = $nmisng->node( uuid => $NT->{$nd}{uuid} );
		my ($inventory,$error) = $nmisng_node->inventory( concept => 'catchall' );
		$nmisng->log->error("Failed to get catchall inventory for node:$nd, error:$error") && next
			if(!$inventory);

		# we know the data here isn't changing so no need to use live data
		my $catchall_data = $inventory->data();

		$nt{$nd}{name} = $catchall_data->{name};
		$nt{$nd}{group} = $catchall_data->{group};
		$nt{$nd}{collect} = $catchall_data->{collect};
		$nt{$nd}{active} = $NT->{$nd}{active};
		$nt{$nd}{ping} = $NT->{$nd}{ping};
		$nt{$nd}{netType} = $catchall_data->{netType};
		$nt{$nd}{roleType} = $catchall_data->{roleType};
		$nt{$nd}{nodeType} = $catchall_data->{nodeType};
		$nt{$nd}{nodeModel} = $catchall_data->{nodeModel};
		$nt{$nd}{nodeVendor} = $catchall_data->{nodeVendor};
		$nt{$nd}{lastUpdateSec} = $catchall_data->{lastUpdateSec};
		$nt{$nd}{sysName} = $catchall_data->{sysName};
		$nt{$nd}{server} = $C->{'server_name'};

		foreach my $property (@node_summary_properties) {
			$nt{$nd}{$property} = $catchall_data->{$property};
		}

		$nt{$nd}{nodedown} = $catchall_data->{nodedown};
		# find out if a node down event exists, and if so store
		# its escalate setting
		my $curescalate = undef;
		if (my $eventexists = eventExist($nd, "Node Down", undef))
		{
			my $erec = eventLoad(filename => $eventexists);
			$curescalate = $erec->{escalate} if ($erec);
		}
		$nt{$nd}{escalate} = $curescalate;

		### adding node_status to the summary data
		# check status from event db
		my $nodestatus = nodeStatus(catchall_data => $catchall_data);
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

			my $outageText = "node=$OT->{$otgHash}{node}<br>start=".NMISNG::Util::returnDateStamp($OT->{$otgHash}{start})
			."<br>end=".NMISNG::Util::returnDateStamp($OT->{$otgHash}{end})."<br>change=$OT->{$otgHash}{change}";
		}
		$nt{$nd}{outage} = $otgStatus;
		$nt{$nd}{outageText} = $outageText;

		# If sysLocation is formatted for GeoStyle, then remove long, lat and alt to make display tidier
		my $sysLocation = $catchall_data->{sysLocation};
		if (($catchall_data->{sysLocation}  =~ /$C->{sysLoc_format}/ ) and $C->{sysLoc} eq "on") {
			# Node has sysLocation that is formatted for Geo Data
			( my $lat, my $long, my $alt, $sysLocation) = split(',',$catchall_data->{sysLocation});
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

	NMISNG::Util::dbg("Starting");

	my (@devicelist,$i,@nodedetails);
	# init the hash, so zero values display
	$nodecount{counttotal} = 0;
	$nodecount{countup} = 0;
	$nodecount{countdown} = 0;
	$nodecount{countdegraded} = 0;

	my $S = NMISNG::Sys->new;
	my $NT = loadNodeTable(); # local + nodes of remote servers
	my $C = NMISNG::Util::loadConfTable();

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
		if ( (($SUM,$mtime) = NMISNG::Util::loadTable(dir=>'var',name=>"nmis-$filename",mtime=>'true')) ) {
			if ($mtime < (time()-900)) {
				NMISNG::Util::logMsg("INFO (nmis) cache file var/nmis-$filename does not exist or is old; calculate summary");
			} else {
				$cache = 1;
			}
		}
	}	else {
		NMISNG::Util::logMsg("ERROR (nmis) missing summary file specification");
		return;
	}

	NMISNG::Util::dbg("Cache is $cache, filename=$filename");

	# this server
	unless ($cache) {
		$SUM = {};
		foreach my $node ( keys %{$NT} ) {
			next if ( !NMISNG::Util::getbool($NT->{$node}{active}) or exists $NT->{$node}{server});
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
			if ( eventExist($node, "Node Down", undef) ) {
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
	if (NMISNG::Util::existFile(dir=>'var',name=>$nodesum) ) {
		my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$nodesum);
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
	if (NMISNG::Util::getbool($C->{server_master})) {
		NMISNG::Util::dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $server_priority = $ST->{$srv}{server_priority} || 5;

			my $slavefile = "nmis-$srv-$filename";
			NMISNG::Util::dbg("Processing Slave $srv for $slavefile");

			# I should now have an up to date file, if I don't log a message
			if (NMISNG::Util::existFile(dir=>'var',name=>$slavefile) ) {
				my $H = NMISNG::Util::loadTable(dir=>'var',name=>$slavefile);
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
			NMISNG::Util::dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (NMISNG::Util::existFile(dir=>'var',name=>$slavenodesum) ) {

				my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$slavenodesum);
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
			if ( NMISNG::Util::getbool($NT->{$node}{active}) ) {
				++$nodecount{counttotal};
				my $outage = '';
				# check nodes
				# Carefull logic here, if nodedown is false then the node is up
				#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
				if (NMISNG::Util::getbool($summaryHash{$node}{nodedown})) {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$NT->{$node}{roleType});
					++$nodecount{countdown};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				}
				elsif (exists $C->{display_status_summary}
					and NMISNG::Util::getbool($C->{display_status_summary})
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
						$summaryHash{$node}{response_color} = NMISNG::Util::colorResponseTime($summaryHash{$node}{response});
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
		###			NMISNG::Util::logMsg("INFO Node=$node skipped OU=$outage");
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
	if (NMISNG::Util::getbool($C->{intf_av_modified})) {
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
		$summaryHash{average}{response_color} = NMISNG::Util::colorResponseTime($summaryHash{average}{response})
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
	NMISNG::Util::dbg("Finished");
	return \%summaryHash;
} # end getGroupSummary

#=========================================================================================

# if you think this function and the next look very similar you are correct
sub getAdminColor {
	my %args = @_;
	my ($S,$index) = @args{'sys','index'};
	my ($ifAdminStatus,$ifOperStatus,$collect,$data) = @args{'ifAdminStatus','ifOperStatus','collect','data'};
	my $adminColor;

	if( defined($S) && defined($index) && !$data )
	{
		#inventory keyed by index and ifDescr so we need partial
		my $inventory = $S->inventory( concept => 'interface', index => $index, partial => 1 );
		# if data not found use args
		$data = ($inventory) ? $inventory->data : \%args;
	}

	if( $data )
	{
		$ifAdminStatus = $data->{ifAdminStatus};
		$collect = $data->{collect};
	}
	elsif ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !NMISNG::Util::getbool($collect)) {
		$adminColor="#ffffff";
	} else {
		$adminColor="#00ff00";
	}
	return $adminColor;
}

#=========================================================================================

# get color stuff, determined from collect/{admin|oper}Status
# args:
#   S,index - if provided interface status info will be looked up from it
#   if S not provided then status/collect must be provided in arguments
sub getOperColor {
	my (%args) = @_;
	my ($S,$index) = @args{'sys','index'};
	my ($ifAdminStatus,$ifOperStatus,$collect,$data) = @args{'ifAdminStatus','ifOperStatus','collect','data'};

	my $operColor;

	if( defined($S) && defined($index) && !$data )
	{
		my $inventory = $S->inventory( concept => 'interface', index => $index, partial => 1 );
		# if data not found use args
		$data = ($inventory) ? $inventory->data : \%args;
	}
	if( $data )
	{
		$ifAdminStatus = $data->{ifAdminStatus};
		$ifOperStatus = $data->{ifOperStatus};
		$collect = $data->{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !NMISNG::Util::getbool($collect)) {
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
	my ($threshold) = @_;
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



# fixme: az looks like this function should be reworked with
# or ditched in favour of nodeStatus() and PreciseNodeStatus()
# fixme: this also doesn't understand wmidown (properly)
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

	my $C = NMISNG::Util::loadConfTable();
	my $NT = loadNodeTable();
	my $NS = loadNodeSummary();


	if ( $group eq "" and $customer eq "" and $business eq "" and $netType eq "" and $roleType eq "" ) {
		foreach $node (sort keys %{$NT} ) {
			if (NMISNG::Util::getbool($NT->{$node}{active})) {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} ) {
					### 2013-08-20 keiths, check for SNMP Down if ping eq false.
					my $down_event = "Node Down";
					$down_event = "SNMP Down" if NMISNG::Util::getbool($NT->{$node}{ping},"invert");
					$nodedown = eventExist($node, $down_event, undef)? 1:0; # returns the event filename

					($outage,undef) = outageCheck(node=>$node,time=>time());
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( NMISNG::Util::getbool($NS->{$node}{nodedown})) {
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
			if (NMISNG::Util::getbool($NT->{$node}{active})) {
				if ( $NT->{$node}{net} eq "$netType" && $NT->{$node}{role} eq "$roleType" ) {
					my $nodedown = 0;
					my $outage = "";
					if ( $NT->{$node}{server} eq $C->{server_name} )
					{
						### 2013-08-20 keiths, check for SNMP Down if ping eq false.
						my $down_event = "Node Down";
						$down_event = "SNMP Down" if NMISNG::Util::getbool($NT->{$node}{ping},"invert");
						$nodedown = eventExist($node, $down_event, undef)? 1 : 0;

						($outage,undef) = outageCheck(node=>$node,time=>time());
					}
					else {
						$outage = $NS->{$node}{outage};
						if ( NMISNG::Util::getbool($NS->{$node}{nodedown})) {
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
				NMISNG::Util::getbool($NT->{$node}{active})
				and ( ($group ne "" and $NT->{$node}{group} eq $group)
							or ($customer ne "" and $NT->{$node}{customer} eq $customer)
							or ($business ne "" and $NT->{$node}{businessService} =~ /$business/ )
						)
			) {
				my $nodedown = 0;
				my $outage = "";
				if ( $NT->{$node}{server} eq $C->{server_name} )
				{
					### 2013-08-20 keiths, check for SNMP Down if ping eq false.
					my $down_event = "Node Down";
					$down_event = "SNMP Down" if NMISNG::Util::getbool($NT->{$node}{ping},"invert");

					$nodedown = eventExist($node, $down_event, undef)? 1:0;
					($outage,undef) = outageCheck(node=>$node,time=>time());
				}
				else {
					$outage = $NS->{$node}{outage};
					if ( NMISNG::Util::getbool($NS->{$node}{nodedown})) {
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
				#print STDERR returnDateStamp()." overallNodeStatus: $node $group $event_status event=$statusHash{$event_status} count=$statusHash{count}\n";
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
			 and NMISNG::Util::getbool($C->{overall_node_status_coarse})) {
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

# fixme9: this  cannot work with nmis9. code is also unreachable.
# convert configuration files in dir conf to from 4  to NMIS8
sub convertConfFiles {

	my $C = NMISNG::Util::loadConfTable();

	my $ext = NMISNG::Util::getExtension(dir=>'conf');
	#==== check Nodes ====

	if (!NMISNG::Util::existFile(dir=>'conf',name=>'Nodes')) {
		my (%nodeTable, $NT, $error);
		# Load the old CSV first for upgrading to NMIS8 format
		if ( -r $C->{Nodes_Table} )
		{
			($error, %nodeTable) = NMISNG::CSV::loadCSV($C->{Nodes_Table},
																									$C->{Nodes_Key});
			if (!$error) {
				NMISNG::Util::dbg("Loaded $C->{Nodes_Table}");
				rename "$C->{Nodes_Table}","$C->{Nodes_Table}.old";
				# copy what we need
				foreach my $i (sort keys %nodeTable) {
					NMISNG::Util::dbg("update node=$nodeTable{$i}{node} to NMIS8 format");
					# new field 'name' and 'host' in NMIS8, update this field
					if ($nodeTable{$i}{node} =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
						$nodeTable{$i}{name} = sprintf("IP-%03d-%03d-%03d-%03d",${1},${2},${3},${4}); # default
						# it's an IP address, get the DNS name
						my $iaddr = inet_aton($nodeTable{$i}{node});
						if ((my $name  = gethostbyaddr($iaddr, AF_INET))) {
							$nodeTable{$i}{name} = $name; # oke
							NMISNG::Util::dbg("node=$nodeTable{$i}{node} converted to name=$name");
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
									NMISNG::Util::dbg("name=$name=$info{sysName} from sysName for node=$nodeTable{$i}{node}");
								}
							}
						}
					} else {
						$nodeTable{$i}{name} = $nodeTable{$i}{node}; # simple copy of DNS name
					}
					NMISNG::Util::dbg("result 1 update name=$nodeTable{$i}{name}");
					# only first part of (fqdn) name
					($nodeTable{$i}{name}) = split /\./,$nodeTable{$i}{name} ;
					NMISNG::Util::dbg("result update name=$nodeTable{$i}{name}");

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

					$NT->{$node}{rancid} = $nodeTable{$i}{rancid} || 'false';
					$NT->{$node}{services} = $nodeTable{$i}{services} ;
				#	$NT->{$node}{runupdate} = $nodeTable{$i}{runupdate} ;
					$NT->{$node}{webserver} = 'false' ;
					$NT->{$node}{model} = $nodeTable{$i}{model} || 'automatic';
					$NT->{$node}{version} = $nodeTable{$i}{version} || 'snmpv2c';
					$NT->{$node}{timezone} = 0 ;
				}
				NMISNG::Util::writeTable(dir=>'conf',name=>'Nodes',data=>$NT);
				print " csv file $C->{Nodes_Table} converted to conf/Nodes.$ext\n";
			} else {
				NMISNG::Util::dbg("ERROR, could not find or read $C->{Nodes_Table} or empty node file");
			}
		} else {
			NMISNG::Util::dbg("ERROR, could not find or read $C->{Nodes_Table}");
		}
	}


	#====================

	if (!NMISNG::Util::existFile(dir=>'conf',name=>'Escalations')) {
		if ( -r "$C->{'Escalation_Table'}")
		{
			my ($error, %table_data)  = NMISNG::CSV::loadCSV($C->{'Escalation_Table'},
																											 $C->{'Escalation_Key'});
			foreach my $k (keys %table_data) {
				if (not exists $table_data{$k}{Event_Element}) {
					$table_data{$k}{Event_Element} = $table_data{$k}{Event_Details} ;
					delete $table_data{$k}{Event_Details};
				}
			}
			NMISNG::Util::writeTable(dir=>'conf',name=>'Escalations',data=>\%table_data);
			print " csv file $C->{Escalation_Table} converted to conf/Escalation.$ext\n";
			rename "$C->{'Escalation_Table'}","$C->{'Escalation_Table'}.old";
		} else {
			NMISNG::Util::dbg("ERROR, could not find or read $C->{'Escalation_Table'}");
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
		my $C = NMISNG::Util::loadConfTable();
		if (!NMISNG::Util::existFile(dir=>'conf',name=>$name)) {
			if ( -r "$C->{\"${name}_Table\"}") {
				my ($error, %table_data) = NMISNG::CSV::loadCSV($C->{"${name}_Table"},
																												$C->{"${name}_Key"});

				NMISNG::Util::writeTable(dir=>'conf',name=>$name,data=>\%table_data);

				my $ext = NMISNG::Util::getExtension(dir=>'conf');
				print " csv file $C->{\"${name}_Table\"} converted to conf/${name}.$ext\n";
				rename "$C->{\"${name}_Table\"}","$C->{\"${name}_Table\"}.old";
			} else {
				NMISNG::Util::dbg("ERROR, could not find or read $C->{\"${name}_Table\"}");
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


# load the info of a node
# if optional arg suppress_errors is given, then no errors are logged
sub loadNodeInfoTable
{
	my $node = lc shift;
	my %args = @_;

	return NMISNG::Util::loadTable(dir=>'var', name=>"$node-node",  suppress_errors => $args{suppress_errors});
}

# load info of all interfaces
sub loadInterfaceInfo {

	return NMISNG::Util::loadTable(dir=>'var',name=>"nmis-interfaces"); # my $II = loadInterfaceInfo();
}

# load info of all interfaces
sub loadInterfaceInfoShort {

	return NMISNG::Util::loadTable(dir=>'var',name=>"nmis-interfaces-short"); # my $II = loadInterfaceInfoShort();
}

#
sub loadEnterpriseTable {
	return NMISNG::Util::loadTable(dir=>'conf',name=>'Enterprise');
}


sub loadOutageTable {
	my $OT = NMISNG::Util::loadTable(dir=>'conf',name=>'Outage'); # get in cache
}

#
# check outage of node
# return status,key where status is pending or current, key is hash key of event table
#
# args: node, time (required)
sub outageCheck
{
	my %args = @_;
	my $node = $args{node};
	my $time = $args{time};

	my $OT = loadOutageTable();

	# Get each of the nodes info in a HASH for playing with
	foreach my $key (sort keys %{$OT})
	{
		if (($time-300) > $OT->{$key}{end})
		{
			outageRemove(key=>$key); # past
		}
		else
		{
			if ( $node eq $OT->{$key}{node})
			{
				if ($time >= $OT->{$key}{start} and $time <= $OT->{$key}{end} )
				{
					return "current",$key;
				}
				elsif ($time < $OT->{$key}{start})
				{
					return "pending",$key;
				}
			}
		}
	}
	# check also dependency
	my $NT = loadNodeTable();
	foreach my $nd ( split(/,/,$NT->{$node}{depend}) )
	{
		foreach my $key (sort keys %{$OT}) {
			if ( $nd eq $OT->{$key}{node})
			{
				if ($time >= $OT->{$key}{start} and $time <= $OT->{$key}{end} )
				{
					# check if this other node is down
					my $S = NMISNG::Sys->new;
					$S->init( name => $nd, snmp => 'false' );
					my $status = PreciseNodeStatus(system => $S);
					if (!$status->{overall}) # node unreachable
					{
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

	my $C = NMISNG::Util::loadConfTable();
	my $time = time();
	my $string;

	my ($OT,$handle) = NMISNG::Util::loadTable(dir=>'conf',name=>'Outage',lock=>'true');

	# dont log pending
	if ($time > $OT->{$key}{start})  {
		$string = ", Node $OT->{$key}{node}, Start $OT->{$key}{start}, End $OT->{$key}{end}, "
							."Change $OT->{$key}{change}, Closed $time, User $OT->{$key}{user}";
	}

	delete $OT->{$key};

	NMISNG::Util::writeTable(dir=>'conf',name=>'Outage',data=>$OT,handle=>$handle);

	my @problems;

	if ($string ne '') {
		# fixme9: should use a sensible log mechanism
		# log this action but DON'T DEADLOCK - NMISNG::Util::logMsg locks, too!
		if ( open($handle,">>$C->{outage_log}") ) {
			if ( flock($handle, LOCK_EX) ) {
				if ( not print $handle NMISNG::Util::returnDateStamp()." $string\n" ) {
					push(@problems, "cannot write file $C->{outage_log}: $!");
				}
			} else {
				push(@problems, "cannot lock file $C->{outage_log}: $!");
			}
			close $handle;
			map { NMISNG::Util::logMsg("ERROR (nmis) $_") } (@problems);

			NMISNG::Util::setFileProtDiag(file =>$C->{outage_log});
		} else {
			NMISNG::Util::logMsg("ERROR (nmis) cannot open file $C->{outage_log}: $!");
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
		NMISNG::Util::dbg($out);

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				NMISNG::Util::dbg("returning success on dutytime test for $contact");
				return 1;
			}
			elsif ( $finish_time < $start_time ) {
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					NMISNG::Util::dbg("returning success on dutytime test for $contact");
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		NMISNG::Util::dbg("No dutytime defined - returning success assuming $contact is 24x7");
		return 1;
	}
	NMISNG::Util::dbg("returning fail on dutytime test for $contact");
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
	my $C = NMISNG::Util::loadConfTable();

	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $win_width = $C->{win_width}; # window size
	my $win_height = $C->{win_height};

	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);

	my $time = time();
	my $clickurl = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=$graphtype&group=$urlsafegroup&intf=$intf&server=$server&node=$urlsafenode";


	if( NMISNG::Util::getbool($C->{display_opcharts}) ) {
		my $graphLink = "$C->{'rrddraw'}?conf=$C->{conf}&act=draw_graph_view&group=$urlsafegroup&graphtype=$graphtype&node=$urlsafenode&intf=$intf&server=$server".
				"&start=&end=&width=$width&height=$height&time=$time";
		my $retval = qq|<div class="chartDiv" id="${id}DivId" data-chart-url="$graphLink" data-title-onclick='viewwndw("$target","$clickurl",$win_width,$win_height)' data-chart-height="$height" data-chart-width="$width"><div class="chartSpan" id="${id}SpanId"></div></div>|;
	}
	else {
		my $src = "$C->{'rrddraw'}?conf=$C->{conf}&act=draw_graph_view&group=$urlsafegroup&graphtype=$graphtype&node=$urlsafenode&intf=$intf&server=$server".
			"&start=&end=&width=$width&height=$height&time=$time";
		### 2012-03-28 keiths, changed graphs to come up in their own Window with the target of node, handy for comparing graphs.
		return 	qq|<a target="Graph-$target" onClick="viewwndw(\'$target\',\'$clickurl\',$win_width,$win_height)">
<img alt='Network Info' src="$src"></img></a>|;
	}
}

# args: user, node, system, refresh, widget, au (object),
# conf (=name of config for links)
# returns: html as array of lines
sub createHrButtons
{
	my %args = @_;
	my $user = $args{user};
	my $node = $args{node};
	my $S = $args{system};
	my $refresh = $args{refresh};
	my $widget = $args{widget};
	my $AU = $args{AU};
	my $confname = $args{conf};

	return "" if (!$node);
	$refresh = "false" if (!NMISNG::Util::getbool($refresh));

	my @out;

	# fixme9: still need this for status, which hasn't been switched to inventory just yet
	my $NI = loadNodeInfoTable($node);
	# note, not using live data beause this isn't used in collect/update
	my $catchall_data = $S->inventory( concept => 'catchall')->data();
	my $nmisng_node = $S->nmisng_node;

	my $C = NMISNG::Util::loadConfTable();

	return unless $AU->InGroup($catchall_data->{group});

	my $server = NMISNG::Util::getbool($C->{server_master}) ? '' : $catchall_data->{server};
	my $urlsafenode = uri_escape($node);

	push @out, "<table class='table'><tr>\n";

	# provide link back to the main dashboard if not in widget mode
	push @out, CGI::td({class=>"header litehead"}, CGI::a({class=>"wht", href=>$C->{'nmis'}."?conf=$confname"},
																												"NMIS $Compat::NMIS::VERSION"))
			if (!NMISNG::Util::getbool($widget));

	push @out, CGI::td({class=>'header litehead'},'Node ',
			CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_node_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},$node));

	if ($S->getTypeInstances(graphtype => 'service', section => 'service')) {
		push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"services"));
	}

	if (NMISNG::Util::getbool($catchall_data->{collect})) {
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_status_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"status"))
				if defined $NI->{status} and defined $C->{display_status_summary}
		and NMISNG::Util::getbool($C->{display_status_summary});
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_all&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"interfaces"))
				if (defined $S->{mdl}{interface});
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_act&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"active intf"))
				if defined $S->{mdl}{interface};

		# this should potentially be querying for active/not-historic
		my $ids = $S->nmisng_node->get_inventory_ids( concept => 'interface' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_port_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ports"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_storage_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"storage"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		# adding services list support, but hide the tab if the snmp service collection isn't working
		if ( @$ids > 0 )
		{
					push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"service list"));
		}
		if ($S->getTypeInstances(graphtype => "hrsmpcpu")) {
					push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_cpu_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"cpu list"));
		}

		# let's show the possibly many systemhealth items in a dropdown menu
		if ( defined $S->{mdl}{systemHealth}{sys} )
		{
    	my @systemHealth = split(",",$S->{mdl}{systemHealth}{sections});
			push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>System Health &#x25BE<ul>";
			foreach my $sysHealth (@systemHealth)
			{
				my $ids = $nmisng_node->get_inventory_ids( concept => $sysHealth );
				# don't show spurious blank entries
				if ( @$ids > 0 )
				{
					push @out, CGI::li(CGI::a({ class=>'wht',  href=>"network.pl?conf=$confname&act=network_system_health_view&section=$sysHealth&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"}, $sysHealth));
				}
			}
			push @out, "</ul></li></ul></td>";
		}
	}

	push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"events.pl?conf=$confname&act=event_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"events"));
	push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"outages.pl?conf=$confname&act=outage_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"outage"));


	# and let's combine these in a 'diagnostic' menu as well
	push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>Diagnostic &#x25BE<ul>";

	# drill-in for the node's collect/update time
	push @out, CGI::li(CGI::a({class=>"wht",
														 href=> "$C->{'<cgi_url_base>'}/node.pl?conf=$confname&act=network_graph_view&widget=false&node=$urlsafenode&graphtype=polltime",
																 target=>"_blank"},
														"Collect/Update Runtime"));

	push @out, CGI::li(CGI::a({class=>'wht',href=>"telnet://$catchall_data->{host}",target=>'_blank'},"telnet"))
			if (NMISNG::Util::getbool($C->{view_telnet}));

	if (NMISNG::Util::getbool($C->{view_ssh})) {
		my $ssh_url = $C->{ssh_url} ? $C->{ssh_url} : "ssh://";
		my $ssh_port = $C->{ssh_port} ? ":$C->{ssh_port}" : "";
		push @out, CGI::li(CGI::a({class=>'wht',href=>"$ssh_url$catchall_data->{host}$ssh_port",
										 target=>'_blank'},"ssh"));
	}

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_ping&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ping"))
			if NMISNG::Util::getbool($C->{view_ping});
	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_trace&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"trace"))
			if NMISNG::Util::getbool($C->{view_trace});
	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_mtr&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"mtr"))
			if NMISNG::Util::getbool($C->{view_mtr});

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_lft&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"lft"))
			if NMISNG::Util::getbool($C->{view_lft});

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"http://$catchall_data->{host}",target=>'_blank'},"http"))
			if NMISNG::Util::getbool($catchall_data->{webserver});
	# end of diagnostic menu
	push @out, "</ul></li></ul></td>";

	if ($catchall_data->{server} eq $C->{server_name}) {
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Contacts&key=".uri_escape($catchall_data->{sysContact})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"contact"))
					if $catchall_data->{sysContact} ne '';
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Locations&key=".uri_escape($catchall_data->{sysLocation})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"location"))
					if $catchall_data->{sysLocation} ne '';
	}

	push @out, "</tr></table>";

	return @out;
}

sub loadPortalCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C =	NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $portalCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Portal") ) {
		# portal menu of nodes or clients to link to.
		my $P = NMISNG::Util::loadTable(dir=>'conf',name=>"Portal");

		my $portalOption;

		foreach my $p ( sort {$a <=> $b} keys %{$P} ) {
			# If the link is part of NMIS, append the config
			my $selected;

			if ( $P->{$p}{Link} =~ /cgi-nmis9/ ) {
				$P->{$p}{Link} .= "?conf=$conf";
			}

			if ( $ENV{SCRIPT_NAME} =~ /nmiscgi/ and $P->{$p}{Link} =~ /nmiscgi/ and $P->{$p}{Name} =~ /NMIS9/ ) {
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
	my $C = NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $serverCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Servers") ) {
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
	my (%args) = @_;
	my $conf = $args{conf};
	my $C = NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $tenantCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Tenants") ) {
		# portal menu of nodes or clients to link to.
		my $MT = NMISNG::Util::loadTable(dir=>'conf',name=>"Tenants");

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

	my $C = NMISNG::Util::loadConfTable();

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

	my $C = NMISNG::Util::loadConfTable();

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

	my $C = NMISNG::Util::loadConfTable();

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
	print "</body></html>";
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
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	# this is still used by huaweiqos, nothing else should be using it
	# fixme9: this needs to  be reworked to use inventory for huwawei, too...
	my $NI = $S->compat_nodeinfo;

	my $M = $S->mdl;
	my $node = $catchall_data->{name};

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
		NMISNG::Util::TODO("Port huaweiqos in loadCBQos and in the plugin");
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
		my $inventory = $S->inventory( concept => "cbqos-$direction", index => $index );
		my $data = ($inventory) ? $inventory->data : {};
		$PMName = $data->{PolicyMap}{Name};

		foreach my $k (keys %{$data->{ClassMap}}) {
			my $CMName = $data->{ClassMap}{$k}{Name};
			push @CMNames , $CMName if $CMName ne "";

			$CBQosValues{$index.$CMName} = { CfgType => $data->{ClassMap}{$k}{'BW'}{'Descr'},
																			 CfgRate => $data->{ClassMap}{$k}{'BW'}{'Value'},
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


# all event handling routines follow below


# small helper that translates event data into a severity level
# args: event, role.
# returns: severity level, color
# fixme: only used for group status summary display! actual event priorities come from the model
sub eventLevel {
	my ($event, $role) = @_;

	my ($event_level, $event_color);

	my $C = NMISNG::Util::loadConfTable();			# cached, mostly nop

	# the config now has a structure for xlat between roletype and severities for node down/other events
	my $rt2sev = $C->{severity_by_roletype};
	$rt2sev = { default => [ "Major", "Minor" ] } if (ref($rt2sev) ne "HASH" or !keys %$rt2sev);

	if ( $event eq 'Node Down' )
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[0] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[0] : "Major";
	}
	elsif ( $event =~ /up/i )
	{
		$event_level = "Normal";
	}
	else
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[1] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[1] : "Major";
	}
	$event_level = "Major" if ($event_level !~ /^(fatal|critical|major|minor|warning|normal)$/i); 	# last-ditch fallback
	$event_color = NMISNG::Util::eventColor($event_level);

	return ($event_level,$event_color);
}

# this function checks if a particular event exists
# in the list of current event, NOT the history list!
#
# args: node, event(name), element (element may be missing)
# returns event file name if present, 0/undef otherwise
sub eventExist
{
	my ($node, $eventname, $element) = @_;

	my $efn = event_to_filename(event => { node => $node,
																				 event => $eventname,
																				 element => $element },
															category => "current" );
	return ($efn and -f $efn)? $efn : 0;
}

# returns the detailed event record for the given CURRENT event
# args: node, event(name), element OR filename
# returns event hash or undef
sub eventLoad
{
	my (%args) = @_;

	my $efn = $args{filename}
	|| event_to_filename( event => { node => $args{node},
																	 event => $args{event},
																	 element => $args{element} },
												category => "current" );
	return undef if (!$efn or !-f $efn);
	if (!open(F, "$efn"))
	{
		NMISNG::Util::logMsg("ERROR cannot open event file $efn: $!");
		return undef;
	}
	my $erec = eval { decode_json(join("", <F>)) };
	close(F);
	if (ref($erec) ne "HASH" or $@)
	{
		NMISNG::Util::logMsg("ERROR event file $efn has malformed data: $@");
		return undef;
	}

	return $erec;
}

# deletes ONE event, does NOT (event-)log anything
# args: event (=record suitably filled in to find the file)
# the event file is parked in the history subdir, iff possible and allowed to
# returns undef if ok, error message otherwise
sub eventDelete
{
	my (%args) = @_;

	my $C = NMISNG::Util::loadConfTable();

	return "Cannot remove unnamed event!" if (!$args{event});
	my $efn = event_to_filename( event => $args{event},
															 category => "current" );

	return "Cannot find event file for node=$args{event}->{node}, event=$args{event}->{event}, element=$args{event}->{element}" if (!$efn or !-f $efn);

	# be polite and robust, fix up any dir perm messes
	NMISNG::Util::setFileProtParents(dirname($efn), $C->{'<nmis_var>'});

	my $hfn = event_to_filename( event => $args{event},
															 category => "history" ); # file to dir is a bit of a hack
	my $historydirname = dirname($hfn) if ($hfn);
	NMISNG::Util::createDir($historydirname) if ($historydirname and !-d $historydirname);
	NMISNG::Util::setFileProtParents($historydirname, $C->{'<nmis_var>'}) if (-d $historydirname);

	# now move the event into the history section if we can,
	# and if we're allowed to
	if (!NMISNG::Util::getbool($C->{"keep_event_history"},"invert") # if not set to 'false'
			and $historydirname and -d $historydirname)
	{
		my $newfn = "$historydirname/".time."-".basename($efn);
			rename($efn, $newfn)
					or return"could not move event file $efn to history: $!";
	}
	else
	{
		unlink($efn)
				or return "could not remove event file $efn: $!";
	}
	return undef;
}

# replaces the event data for one given EXISTING event
# or CREATES a new event with option create_if_missing
#
# args: event (=full record, for finding AND updating)
# create_if_missing (default false)
#
# the node, event name and elements of an event CANNOT be changed,
# because they are part of the naming components!
#
# returns undef if ok, error message otherwise
sub eventUpdate
{
	my (%args) = @_;

	my $C = NMISNG::Util::loadConfTable();

	return "Cannot update unnamed event!" if (!$args{event});
	my $efn = event_to_filename( event => $args{event},
															 category => "current" );
	return "Cannot find event file for node=$args{event}->{node}, event=$args{event}->{event}, element=$args{event}->{element}" if (!$efn or (!-f $efn and !$args{create_if_missing}));

	my $dirname = dirname($efn);
	if (!-d $dirname)
	{
		NMISNG::Util::createDir($dirname);
		NMISNG::Util::setFileProtParents($dirname, $C->{'<nmis_var>'}); # which includes the parents up to nmis_base
	}

	my $filemode = (-f $efn)? "+<": ">"; # clobber if nonex

	my @problems;
	if (!open(F, $filemode, $efn))
	{
		return "Cannot open event file $efn ($filemode): $!";
	}
	flock(F, LOCK_EX)  or push(@problems, "Cannot lock file $efn: $!");
	&NMISNG::Util::enter_critical;
	seek(F, 0, 0);
	truncate(F, 0) or push(@problems, "Cannot truncate file $efn: $!");
	print F encode_json($args{event});
	close(F) or push(@problems, "Cannot close file $efn: $!");
	&NMISNG::Util::leave_critical;

	NMISNG::Util::setFileProtDiag(file =>$efn);
	if (@problems)
	{
		return join("\n", @problems);
	}
	return undef;
}

# loads one or more service statuses
#
# args: service, node, cluster_id, only_known (all optional)
# if service or node are given, only matching services are returned.
# cluster_id defaults to the local one, and is IGNORED unless only_known is 0.
#
# only_known is 1 by default, which ensures that only locally known, active services
# listed in Services.nmis and attached to active nodes are returned.
#
# if only_known is set to zero, then all services, remote or local,
# active or not are returned.
#
# returns: hash of cluster_id -> service -> node -> data; empty if invalid args
sub loadServiceStatus
{
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();			# generally cached anyway

	my $wantnode = $args{node};
	my $wantservice = $args{service};
	my $wantcluster = $args{cluster_id} || $C->{cluster_id};
	my $only_known = !(NMISNG::Util::getbool($args{only_known}, "invert")); # default is 1

	my $nmisng = new_nmisng();

	my %result;
	my @selectors = ( concept => "service", filter =>
										{ historic => 0,
											enabled => $only_known? 1 : undef, # don't care if not onlyknown
										} );
	if ($wantnode)
	{
		my $noderec = $nmisng->node(name => $wantnode);
		return %result if (!$noderec);

		push @selectors, ( "node_uuid" =>  $noderec->uuid,
											 "cluster_id" => $noderec->cluster_id,
											);
	}
	push @selectors, ("cluster_id" => $wantcluster) if ($wantcluster);
	push @selectors, ("data.service" => $wantservice ) if ($wantservice);


	# first find all inventory instances that match,
	# then get the newest timed data for them
	my $modeldata = $nmisng->get_inventory_model(@selectors);
	return %result if (!$modeldata->count);

	my $error = NMISNG::Inventory::instantiate(nmisng => $nmisng, modeldata => $modeldata);
	die "failed to instantiate inventory objects: $error\n" if ($error);

	my %nodeobjs;
	for my $maybe (@{$modeldata->data})
	{
		# we need to check each node for being disabled if only_known is set
		# reason: historic isn't set on service inventories if the node is disabled
		if ($only_known)
		{
			my $thisnode = $nodeobjs{$maybe->node_uuid} || $nmisng->node(uuid => $maybe->node_uuid);
			next if (ref($thisnode) ne "NMISNG::Node"); # ignore unexpectedly orphaned service info
			$nodeobjs{$maybe->node_uuid} ||= $thisnode;

			next if (!NMISNG::Util::getbool($thisnode->configuration->{active}) # disabled node
							 or ( !$maybe->enabled ) ); # service disabled (both count with only_known)
		}

		my $semistaticdata = $maybe->data;
		my $timeddata = $maybe->get_newest_timed_data();
		next if (!$timeddata->{success} or !$timeddata->{time}); # no readings, not interesting

		my $thisserver = $maybe->cluster_id;

		# timed data is structured by/under subconcept, one subconcept 'service' used for services now
		my %goodies = ( (map { ($_ => $timeddata->{data}->{service}->{$_}) } (keys %{$timeddata->{data}->{service}})),
										(map { ($_ => $semistaticdata->{$_}) } (keys %{$semistaticdata})),
										node_uuid => $maybe->node_uuid
				);

		$result{ $maybe->cluster_id }->{ $semistaticdata->{service} }->{ $semistaticdata->{node} } = \%goodies;
	}

	return %result;
}


# looks up all events (for one node or all),
# in current or history section
#
# args: node (optional, if not there all are loaded),
# category (optional: default is "current")
# returns hash of: event file name (=full path!) => the event's record
sub loadAllEvents
{
	my (%args) = @_;

	my $C = NMISNG::Util::loadConfTable();			# cached

	my @wantednodes = $args{node}? ($args{node}) : (keys %{loadLocalNodeTable()});
	my $category  = $args{category} || "current";
	my %results = ();

	for my $node (@wantednodes)
	{
		# find the relevant dir via a dummy event and suck them all in
		my $efn = event_to_filename( event => { node => $node,
																						event => "dummy",
																						element => "dummy" },
																 category => $category );
		my $dirname = dirname($efn) if ($efn);
		next if (!$dirname or !-d $dirname);

		opendir(D, $dirname) or NMISNG::Util::logMsg("ERROR could not opendir $dirname: $!");
		my @candidates = readdir(D);
		closedir(D);

		for my $efn (@candidates)
		{
			next if ($efn =~ /^\./ or $efn !~ /\.json$/);

			$efn = "$dirname/$efn";		# for loading and storage
			my $erec = eventLoad(filename => $efn);
			next if (ref($erec) ne "HASH"); # eventLoad already logs errors
			$results{$efn} = $erec;
		}
	}
	return %results;
}

# removes all current events for a node
# this is normally used after editing/deleting nodes to clean the slate and
# make sure there's no lingering phantom events
#
# note: logs if allowed to
# args: node, caller (for logging)
# return nothing
sub cleanEvent
{
	my ($node, $caller) = @_;

	my $C = NMISNG::Util::loadConfTable();

	# find the relevant dir via a dummy event and empty it
	my $efn = event_to_filename( event => { node => $node, event => "dummy", element => "dummy" },
															 category => "current" );
	my $dirname = dirname($efn) if ($efn);
	return if (!$dirname or !-d $dirname);
	NMISNG::Util::setFileProtParents($dirname, $C->{'<nmis_var>'});

	$efn = event_to_filename( event => { node => $node, event => "dummy", element => "dummy" },
														category => "history" );
	my $historydirname = dirname($efn) if $efn; # shouldn't fail but BSTS
	NMISNG::Util::createDir($historydirname)
			if ($historydirname and !-d $historydirname);
	NMISNG::Util::setFileProtParents($historydirname, $C->{'<nmis_var>'}) if (-d $historydirname);

	# get the event configuration which controls logging
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events');

	opendir(D, $dirname) or NMISNG::Util::logMsg("ERROR could not opendir $dirname: $!");
	my @candidates = readdir(D);
	closedir(D);

	for my $moriturus (@candidates)
	{
		next if ($moriturus =~ /^\./ or -d $moriturus or $moriturus !~ /\.json$/);

		# load it so that we can determine whether to log its deletion
		my $erec = eventLoad(filename => "$dirname/$moriturus");
		if (ref($erec) ne "HASH")
		{
			NMISNG::Util::logMsg("ERROR failed to load event file $dirname/$moriturus!");
		}
		my $eventname = $erec->{event} if $erec;

		# log the deletion meta-event iff the original event had logging enabled
		# event logging: true unless overridden by event_config
		if (!$eventname or ref($events_config->{$eventname}) ne "HASH"
				or !NMISNG::Util::getbool($events_config->{$eventname}->{Log}, "invert") )
		{
			logEvent( node => $node,
								event => "$caller: deleted event: $eventname",
								level => "Normal",
								element => $erec->{element}||'',
								details => $erec->{details}||'');
		}
		# now move the event into the history section if we can
		if ($historydirname and -d $historydirname)
		{
			my $newfn = "$historydirname/".time."-$moriturus";
			rename("$dirname/$moriturus", $newfn)
					or  NMISNG::Util::logMsg("ERROR could not move event file $dirname/$moriturus to history: $!");
		}
		else
		{
			unlink("$dirname/$moriturus")
					or NMISNG::Util::logMsg("ERROR could not remove event file $dirname/$moriturus: $!");
		}
	}
	return;
}

# write a record for a given event to the event log file
# args: node, event, element (may be missing), level, details (may be missing)
# logs errors
# returns: undef if ok, error message otherwise
sub logEvent
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	$details =~ s/,//g; # strip any commas

	if (!$node  or !$event or !$level)
	{
		NMISNG::Util::logMsg("ERROR logging event, required argument missing: node=$node, event=$event, level=$level");
		return "required argument missing: node=$node, event=$event, level=$level";
	}

	my $time = time();
	my $C = NMISNG::Util::loadConfTable();

	my @problems;

	# MUST NOT NMISNG::Util::logMsg while holding that lock, as logmsg locks, too!
	sysopen(DATAFILE, "$C->{event_log}", O_WRONLY | O_APPEND | O_CREAT)
			or push(@problems, "Cannot open $C->{event_log}: $!");
	flock(DATAFILE, LOCK_EX)
			or push(@problems,"Cannot lock $C->{event_log}: $!");
	&NMISNG::Util::enter_critical;
	# it's possible we shouldn't write if we can't lock it...
	print DATAFILE "$time,$node,$event,$level,$element,$details\n";
	close(DATAFILE) or push(@problems, "Cannot close $C->{event_log}: $!");
	&NMISNG::Util::leave_critical;
	NMISNG::Util::setFileProtDiag(file =>$C->{event_log}); # set file owner/permission, default: nmis, 0775

	if (@problems)
	{
		my $msg = join("\n", @problems);
		NMISNG::Util::logMsg("ERROR $msg");
		return $msg;
	}
	return undef;
}

# this function (un)acknowledges an existing event
# if configured to it also (event-)logs the activity
#
# args: node, event, element, level, details, ack, user;
# returns: undef if ok, error message otherwise
sub eventAck
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $ack = $args{ack};
	my $user = $args{user};

	my $C = NMISNG::Util::loadConfTable();
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events');

	# first, find the event
	my $erec = eventLoad(node => $node, event => $event, element => $element);
	if (ref($erec) ne "HASH")
	{
		NMISNG::Util::logMsg("ERROR cannot find event for node=$node, event=$event, element=$element");
		return "cannot find event for node=$node, event=$event, element=$element";
	}

	# event control for logging:  as configured or default true, ie. only off if explicitely configured off.
	my $wantlog = (!$events_config or !$events_config->{$event}
								 or !NMISNG::Util::getbool($events_config->{$event}->{Log}, "invert"))? 1 : 0;

	# events are only acknowledgeable while they are current (ie. not in the process of
	# being deleted)!
	return undef if (!NMISNG::Util::getbool($erec->{current}));

	### if a TRAP type event, then trash when ack. event record will be in event log if required
	if (NMISNG::Util::getbool($ack) and NMISNG::Util::getbool($erec->{ack},"invert") and $event eq "TRAP")
	{
		if (my $error = eventDelete(event => $erec))
		{
			NMISNG::Util::logMsg("ERROR: $error");
		}
		logEvent(node => $node, event => "deleted event: $event",
						 level => "Normal", element => $element) if ($wantlog);
	}
	else	# a 'normal' event
	{
		# nothing to do if requested ack and saved ack the same...
		if (NMISNG::Util::getbool($ack) != NMISNG::Util::getbool($erec->{ack}))
		{
			my $newack = NMISNG::Util::getbool($ack)? 'true' : 'false';

			$erec->{ack} = $newack;
			$erec->{user} = $user;
			if (my $error = eventUpdate(event => $erec))
			{
				NMISNG::Util::logMsg("ERROR: $error");
			}

			logEvent(node => $node, event => $event,
							 level => "Normal", element => $element,
							 details => "acknowledge=$newack ($user)")
					if $wantlog;
		}
	}
	return undef;
}

# this adds one new event OR updates an existing stateless event
# this is a HIGHLEVEL function, doing all kinds of nmis-related stuff!
# to JUST create an event record, use eventUpdate() w/create_if_missing
#
# args: node, event, element (may be missing), level,
# details (may be missing), stateless (optional, default false),
# context (optional, just passed through)
#
# returns: undef if ok, error message otherwise
sub eventAdd
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $stateless = $args{stateless} || "false";

	my $C = NMISNG::Util::loadConfTable();

	my $efn = event_to_filename( event => { node => $node,
																					event => $event,
																					element => $element },
															 category => "current" );
	return "Cannot create event with missing parameters, node=$node, event=$event, element=$element!"
			if (!$efn);

	# workaround for perl bug(?); the next if's misfire if
	# we do "my $existing = eventLoad() if (-f $efn);"...
	my $existing = undef;
	if (-f $efn)
	{
	    $existing = eventLoad(filename => $efn);
	}

	# is this an already EXISTING stateless event?
	# they will reset after the dampening time, default dampen of 15 minutes.
	if ( ref($existing) eq "HASH" && NMISNG::Util::getbool($existing->{stateless}) )
	{
		my $stateless_event_dampening =  $C->{stateless_event_dampening} || 900;

		# if the stateless time is greater than the dampening time, reset the escalate.
		if ( time() > $existing->{startdate} + $stateless_event_dampening )
		{
			$existing->{current} = 'true';
			$existing->{startdate} = time();
			$existing->{escalate} = -1;
			$existing->{ack} = 'false';
			$existing->{context} ||= $args{context};

			NMISNG::Util::dbg("event stateless, node=$node, event=$event, level=$level, element=$element, details=$details");
			if (my $error = eventUpdate(event => $existing))
			{
				NMISNG::Util::logMsg("ERROR $error");
				return $error;
			}
		}
	}
	# before we log, check the state if there is an event and if it's current
	elsif ( ref($existing) eq "HASH" && NMISNG::Util::getbool($existing->{current}) )
	{
	    NMISNG::Util::dbg("event exists, node=$node, event=$event, level=$level, element=$element, details=$details");
	    NMISNG::Util::logMsg("ERROR cannot add event=$event, node=$node: already exists, is current and not stateless!");
	    return "cannot add event: already exists, is current and not stateless!";
	}
	# doesn't exist or isn't current
	# fixme: existing but not current isn't cleanly handled here
	else
	{
		$existing ||= {};

		$existing->{current} = 'true';
		$existing->{startdate} = time();
		$existing->{node} = $node;
		$existing->{event} = $event;
		$existing->{level} = $level;
		$existing->{element} = $element;
		$existing->{details} = $details;
		$existing->{ack} = 'false';
		$existing->{escalate} = -1;
		$existing->{notify} = "";
		$existing->{stateless} = $stateless;
		$existing->{context} = $args{context};

		if (my $error = eventUpdate(event => $existing, create_if_missing => !(-f $efn)))
		{
			NMISNG::Util::logMsg("ERROR $error");
			return $error;
		}
		NMISNG::Util::dbg("event added, node=$node, event=$event, level=$level, element=$element, details=$details");
		##	NMISNG::Util::logMsg("INFO event added, node=$node, event=$event, level=$level, element=$element, details=$details");
	}

	return undef;
}

# Check event is called after determining that something is back up!
# Check event checks if the given event exists - args are the DOWN event!
# if it exists it deletes it from the event state table/log
#
# and then calls notify with a new Up event including the time of the outage
# args: a LIVE sys object for the node, event(name);
#  element, details and level are optional
#
# returns: nothing
sub checkEvent
{
	my %args = @_;

	my $S = $args{sys};
	my $node = $S->{node};
	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $log;
	my $syslog;

	my $C = NMISNG::Util::loadConfTable();

	# events.nmis controls which events are active/logging/notifying
	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events');
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

	# set defaults just in case any are blank.
	$C->{'non_stateful_events'} ||= 'Node Configuration Change, Node Reset';
	$C->{'threshold_falling_reset_dampening'} ||= 1.1;
	$C->{'threshold_rising_reset_dampening'} ||= 0.9;

	# check if the event exists and load its details
	my $event_exists = eventExist($node, $event, $element);
	my $erec = eventLoad(filename => $event_exists) if $event_exists;

	if ($event_exists
			and NMISNG::Util::getbool($erec->{current}))
	{
		# a down event exists, so log an UP and delete the original event

		# cmpute the event period for logging
		my $outage = NMISNG::Util::convertSecsHours(time() - $erec->{startdate});

		# Just log an up event now.
		if ( $event eq "Node Down" )
		{
			$event = "Node Up";
		}
		elsif ( $event eq "Interface Down" )
		{
			$event = "Interface Up";
		}
		elsif ( $event eq "RPS Fail" )
		{
			$event = "RPS Up";
		}
		elsif ( $event =~ /Proactive/ )
		{
			if ( defined(my $value = $args{value}) and defined(my $reset = $args{reset}) )
			{
				# but only if we have cleared the threshold by 10%
				# for thresholds where high = good (default 1.1)
				# for thresholds where low = good (default 0.9)
				my $cutoff = $reset * ($value >= $reset?
															 $C->{'threshold_falling_reset_dampening'}
															 : $C->{'threshold_rising_reset_dampening'});

				if ( $value >= $reset && $value <= $cutoff )
				{
					NMISNG::Util::info("Proactive Event value $value too low for dampening limit $cutoff. Not closing.");
					return;
				}
				elsif ($value < $reset && $value >= $cutoff)
				{
					NMISNG::Util::info("Proactive Event value $value too high for dampening limit $cutoff. Not closing.");
					return;
				}
			}
			$event = "$event Closed";
		}
		elsif ( $event =~ /^Alert/ )
		{
			# A custom alert is being cleared.
			$event = "$event Closed";
		}
		elsif ( $event =~ /down/i )
		{
			$event =~ s/down/Up/i;
		}

		# event was renamed/inverted/massaged, need to get the right control record
		# this is likely not needed
		$thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

		$details .= " Time=$outage";

		($level,$log,$syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>'Normal');

		my $OT = loadOutageTable();

		my ($otg,$key) = outageCheck(node=>$node,time=>time());
		if ($otg eq 'current') {
			$details .= " outage_current=true change=$OT->{$key}{change}";
		}

		# now we save the new up event, and move the old down event into history
		my $newevent = { %$erec };
		$newevent->{current} = 'false'; # next processing by escalation routine
		$newevent->{event} = $event;
		$newevent->{details} = $details;
		$newevent->{level} = $level;

		# make the new one FIRST
		if (my $error = eventUpdate(event => $newevent, create_if_missing => 1))
		{
			NMISNG::Util::logMsg("ERROR $error");
		}
		# then delete/move the old one, but only if all is well
		else
		{
			if ($error = eventDelete(event => $erec))
			{
				NMISNG::Util::logMsg("ERROR $error");
			}
		}

		NMISNG::Util::dbg("event node=$erec->{node}, event=$erec->{event}, element=$erec->{element} marked for UP notify and delete");
		if (NMISNG::Util::getbool($log) and NMISNG::Util::getbool($thisevent_control->{Log}))
		{
			logEvent( node=>$S->{name},
								event=>$event,
								level=>$level,
								element=>$element,
								details=>$details);
		}

		# Syslog must be explicitly enabled in the config and will escalation is not being used.
		if (NMISNG::Util::getbool($C->{syslog_events}) and NMISNG::Util::getbool($syslog)
				and NMISNG::Util::getbool($thisevent_control->{Log})
				and !NMISNG::Util::getbool($C->{syslog_use_escalation}))
		{
			NMISNG::Notify::sendSyslog(
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

# notify creates new events
# OR updates level changes for existing threshold/alert ones
# note that notify ignores any outage configuration.
#
# args: LIVE sys for this node, event(=name), element (optional),
# details, level (all optional), context (optional, deep structure)
# returns: nothing
sub notify
{
	my %args = @_;
	my $S = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $M = $S->mdl;
	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $node = $S->{name};
	my $log;
	my $syslog;

	my $C = NMISNG::Util::loadConfTable();

	NMISNG::Util::dbg("Start of Notify");

	# events.nmis controls which events are active/logging/notifying
	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events');
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};


	my $event_exists = eventExist($S->{name},$event,$element);
	my $erec = eventLoad(filename => $event_exists) if $event_exists;


	if ( $event_exists and NMISNG::Util::getbool($erec->{current}))
	{
		# event exists, maybe a level change of proactive threshold?
		if ($event =~ /Proactive|Alert\:/ )
		{
			if ($erec->{level} ne $level)
			{
				# change of level; must update the event record
				# note: 2014-08-27 keiths, update the details as well when changing the level
				$erec->{level} = $level;
				$erec->{details} = $details;
				$erec->{context} ||= $args{context};
				if (my $error = eventUpdate(event => $erec))
				{
					NMISNG::Util::logMsg("ERROR $error");
				}

				(undef, $log, $syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>$level);
				$details .= " Updated";
			}
		}
		else # not an proactive/alert event - no changes are supported
		{
			NMISNG::Util::dbg("Event node=$node event=$event element=$element already exists");
		}
	}
	else # event doesn't exist OR is set to non-current
	{
		# get level(if not defined) and log status from Model
		($level,$log,$syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>$level);

		my $is_stateless = ($C->{non_stateful_events} !~ /$event/
												or NMISNG::Util::getbool($thisevent_control->{Stateful}))? "false": "true";

		### 2016-04-30 ks adding outage tagging to event when opened.
		my $OT = loadOutageTable();

		my ($otg,$key) = outageCheck(node=>$node,time=>time());
		if ($otg eq 'current') {
			$details .= " outage_current=true change=$OT->{$key}{change}";
		}

		# Create and store this new event; record whether stateful or not
		# a stateless event should escalate to a level and then be automatically deleted.
		if (my $error = eventAdd( node=>$node, event=>$event, level=>$level,
															element=>$element, details=>$details,
															stateless => $is_stateless, context => $args{context}))
		{
			NMISNG::Util::logMsg("ERROR: $error");
		}

		if (NMISNG::Util::getbool($C->{log_node_configuration_events})
				and $C->{node_configuration_events} =~ /$event/
				and NMISNG::Util::getbool($thisevent_control->{Log}))
		{
			logConfigEvent(dir => $C->{config_logs}, node=>$node, event=>$event, level=>$level,
										 element=>$element, details=>$details, host => $catchall_data->{host},
										 nmis_server => $C->{nmis_host} );
		}
		$catchall_data->{nodedown} = "true";
	}

	# log events if allowed
	if ( NMISNG::Util::getbool($log) and NMISNG::Util::getbool($thisevent_control->{Log}))
	{
		logEvent(node=>$node, event=>$event, level=>$level, element=>$element, details=>$details);
	}

	# Syslog must be explicitly enabled in the config and
	# is used only if escalation isn't
	if (NMISNG::Util::getbool($C->{syslog_events})
			and NMISNG::Util::getbool($syslog)
			and NMISNG::Util::getbool($thisevent_control->{Log})
			and !NMISNG::Util::getbool($C->{syslog_use_escalation}))
	{
		NMISNG::Notify::sendSyslog(
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

	NMISNG::Util::dbg("Finished");
}

# translates a full event structure into a filename
# args: event (= hashref), category (optional, current or history;
# otherwise taken from event - event with current=false go into history)
#
# returns: file name or undef if inputs make no sense
sub event_to_filename
{
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();			# likely cached

	my $erec = $args{event};
	return undef if (!$erec or ref($erec) ne "HASH" or !$erec->{node}
									 or !$erec->{event}); # element is optional

	# note: just a few spots need to know anything about this structure (or its location):
	# here, in the upgrade_events_structure function (assumes under var),
	# eventDelete, eventUpdate and cleanEvent functions (assume under nmis_var)
	# and in nmis_file_cleanup.sh.
	#
	# structure: nmis_var/events/lcNODENAME/{current,history}/EVENTNAME.json
	my $eventbasedir = $C->{'<nmis_var>'}."/events";
	# make sure the event dir exists, ASAP.
	if (! -d $eventbasedir)
	{
		NMISNG::Util::createDir($eventbasedir);
		NMISNG::Util::setFileProtDiag(file =>$eventbasedir);
	}

	# overridden, or not current then history, or
	my $category = defined($args{category}) && $args{category} =~ /^(current|history)$/?
			$args{category} : NMISNG::Util::getbool($erec->{current})? "current" : "history";

	my $nodecomp = lc($erec->{node});
	$nodecomp =~ s![ :/]!_!g; # no slashes possible, no colons and spaces just for backwards compat

	my $eventcomp = lc($erec->{event}."-".($erec->{element}? $erec->{element} : ''));
	$eventcomp =~ s![ :/]!_!g;			#  backwards compat

	my $result = "$eventbasedir/$nodecomp/$category/$eventcomp.json";
	return $result;
}



# saves a given nodeconf data structure in the per-node nodeconf file
# args: node, data (required)
# data can be undef; in this case the nodeconf for this node is removed.
#
# returns: undef if ok, error message otherwise
sub update_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $data = $args{data};

	my $C = NMISNG::Util::loadConfTable();			# likely cached

	return "Cannot save nodeconf without nodename argument!"
			if (!$nodename);					# note: we don't check (yet) if the node is known

	return "Cannot save nodeconf for $nodename, data is missing!"
			if (!exists($args{data}));				# present but explicitely undef is ok

	my $nmisng = new_nmisng;

	my $node = $nmisng->node( name => $nodename );
	return if(!$node);

	# the deletion case
	if (!defined($data))
	{
		$node->overrides( {} );
		my $op = $node->save();
		return "Could not remove nodeconf for $nodename"
			if ($op < 1);
	}
	# we overwrite whatever may have been there
	else
	{
		delete $data->{name};
		$node->overrides( $data );
		my $op = $node->save();
		return "Error saving nodeconf for $nodename"
			if ($op < 1);
	}
	return;
}

# small helper that checks if a nodeconf record
# exists for the given node.
#
# args: node (required)
# returns: 1 if it has nodeconf, 0 if not, undef if the args are dud
sub has_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	return if (!$nodename);

	my $nmisng = new_nmisng;

	my $node = $nmisng->node( name => $nodename );
	return if(!$node);

	# overrides will always be a hashref
	my $overrides = $node->overrides();

	my @confkeys = keys %$overrides;
	return (@confkeys > 0) ? 1 : 0;
}

# returns the nodeconf record for one or all nodes
# args: node (optional)
# returns: (undef, hashref) or (errmsg, undef)
# if asked for a single node, then hashref is JUST the node's settings
# if asked for all nodes, then hashref is nodename => per-node-settings
sub get_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $nmisng = new_nmisng;

	if (exists($args{node}))
	{
		return "Cannot get nodeconf for unnamed node!" if (!$nodename);

		my $node = $nmisng->node( name => $nodename );
		my $overrides = $node->overrides();
		my @confkeys = keys %$overrides;
		return "No nodeconf exists for node $nodename!" if (@confkeys == 0);

		my $data = $overrides;
		return "Failed to read nodeconf for $nodename!"
				if (ref($data) ne "HASH");

		return (undef, $data );
	}
	else
	{
		my %allofthem;

		my $cands = $nmisng->get_node_uuids();
		for my $uuid (@$cands)
		{
			my $node = $nmisng->node( uuid => $uuid );
			my $overrides = $node->overrides();

			if (ref($overrides) ne "HASH" or !keys %$overrides )
			{
				NMISNG::Util::logMsg("ERROR nodeconf $uuid had invalid data! Skipping.");
				next;
			}

			# structure is real_nodename => data for this node
			$allofthem{$node->configuration()->{name}} = $overrides;
		}
		return (undef, \%allofthem);
	}
}


# this is now a backwards-compatibilty wrapper around get_nodeconf()
sub loadNodeConfTable
{
	my ($error, $data) = get_nodeconf;
	if ($error)
	{
		NMISNG::Util::logMsg("ERROR get_nodeconf failed: $error");
		return {};
	}
	return $data;
}

# this method renames a node, and all its files, too
# fixme9: this function cannot work with nmis9  yet!
#
# args: old, new,
# (optional) debug, (optional) info, (optional) originator
# originator is used for cleanEvent
# returns: (0,undef) if ok, (1, error message) if op failed
#
# note: prints progress info to stderr if debug or info are enabled!
sub rename_node
{
	my (%args) = @_;

	my ($old, $new) = @args{"old","new"};
	my $wantdiag = NMISNG::Util::setDebug($args{debug})
			|| NMISNG::Util::setDebug($args{info}); # don't care about the actual values

	return (1, "Cannot rename node without separate old and new names!")
			if (!$old or !$new or $old eq $new);

	my $C = NMISNG::Util::loadConfTable();

	my $nmisng = new_nmisng;
	# do the rename just baed on name
	my $node = $nmisng->node( name => $old );

	return (1, "Old node $old does not exist!") if (!$node);

	# fixme: less picky? spaces required?
	return(1, "Invalid node name \"$new\"")	if ($new =~ /[^a-zA-Z0-9_-]/);

	# merge the new name into the existing config
	my $configuration = $node->configuration();
	$configuration->{name} = $new;
	$node->configuration($configuration);

	# now write out the new nodes file, so that the new node becomes
	# workable (with sys etc)
	# fixme lowprio: if db_nodes_sql is enabled we need to use a
	#different write function
	print STDERR "Saving new name in Nodes table\n" if ($wantdiag);
	$node->save();

	# then hardlink the var files - do not delete anything yet!
	my @todelete;
	my $vardir = $C->{'<nmis_var>'};
	opendir(D, $vardir) or return(1, "cannot read dir $vardir: $!");
	for my $fn (readdir(D))
	{
		if ($fn =~ /^$old-(node|view)\.(\S+)$/i)
		{
			my ($component,$ext) = ($1,$2);
			my $newfn = lc("$new-$component.$ext");
			push @todelete, "$vardir/$fn";
			print STDERR "Renaming/linking var/$fn to $newfn\n" if ($wantdiag);
			link("$vardir/$fn", "$vardir/$newfn") or
					return(1,"cannot hardlink $fn to $newfn: $!");
		}
	}
	closedir(D);

	print STDERR "Priming Sys objects for finding RRDs\n" if ($wantdiag);
	# fixme9 doesn't work that way
	# now prime sys objs for both old and new nodes, so that we can find and translate rrd names
	my $oldsys = NMISNG::Sys->new; $oldsys->init(name => $old, snmp => "false");
	my $newsys = NMISNG::Sys->new; $newsys->init(name => $new, snmp => "false");

	# fixme9: this cannot work - must look for concepts and storagenames...
	my $oldinfo = $oldsys->compat_nodeinfo;
	my %seen;									 # state cache for renamerrd

	# find all rrds belonging to the old node
	for my $section (keys %{$oldinfo->{graphtype}})
	{
		if (ref($oldinfo->{graphtype}->{$section}) eq "HASH")
		{
			my $index = $section;
			for my $subsection (keys %{$oldinfo->{graphtype}->{$section}})
			{
				if ($subsection =~ /^cbqos-(in|out)$/)
				{
					my $dir = $1;
					# need to find the qos classes and hand them to the renamer as item
					for my $classid (keys %{$oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}})
					{
						my $item = $oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}->{$classid}->{Name};
						push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $subsection,
																			index => $index, item => $item, debug => $wantdiag,
																			seen => \%seen);
					}
				}
				else
				{
					push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $subsection,
																		index => $index, debug => $wantdiag, seen => \%seen);
				}
			}
		}
		else
		{
			push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $section,
																debug => $wantdiag, seen => \%seen);
		}
	}

	# then deal with the no longer wanted data: remove the old links
	for my $fn (@todelete)
	{
		next if (!defined $fn);
		my $relfn = File::Spec->abs2rel($fn, $C->{'<nmis_base>'});
		print STDERR "Deleting file $relfn, no longer required\n" if ($wantdiag);
		unlink($fn);
	}

	# now clear all events for old node
	print STDERR "Removing events for old node\n" if ($wantdiag);
	cleanEvent($old,$args{originator});

	print STDERR "Successfully renamed node $old to $new\n" if ($wantdiag);
	return (0,undef);
}

# fixme9: this function does not work for nmis9 yet!
# internal helper function for rename_node, LINKS one given rrd file to new name
# caller must take care of removing the old rrd file later.
#
# args: old and new (both sys objects), graphtype, seen (hash REF for state caching),
# index (optional), item (optional), info, debug (both optional),
# returns: old (now removable) file name, or undef if nothing done
#
# higher-level functionality/logic, so NOT a candidate for rrdfunc.pm.
#
# note: prints diags on stderr if info or debug are set!
sub renameRRD
{
	my (%args) = @_;

	my $C = NMISNG::Util::loadConfTable();

	my $oldfilename = $args{old}->makeRRDname(graphtype => $args{graphtype},
																						index => $args{index},
																						item => $args{item});
	# don't try to rename a file more than once...
	return undef if $args{seen}->{$oldfilename};
	$args{seen}->{$oldfilename}=1;

	my $wantdiag = NMISNG::Util::setDebug($args{debug})
			|| NMISNG::Util::setDebug($args{info}); # don't care about the actual values

	my $newfilename = $args{new}->makeRRDname(graphtype => $args{graphtype},
																						index => $args{index},
																						item => $args{item});
	return undef if ($newfilename eq $oldfilename);

	if (!$newfilename or !$oldfilename)
	{
		print STDERR "Warning: no RRD file name found for graphtype $args{graphtype} index $args{index} item $args{item}\n"
				if ($wantdiag);
		return undef;
	}

	my $oldrelname = File::Spec->abs2rel( $oldfilename, $C->{'<nmis_base>'} );
	my $newrelname = File::Spec->abs2rel( $newfilename, $C->{'<nmis_base>'} );

	if (!-f $oldfilename)
	{
		print STDERR "Warning: RRD file $oldrelname does not exist, cannot rename!\n" if ($wantdiag);
		return undef;
	}

	# ensure the target dir hierarchy exists
	my $dirname = dirname($newfilename);
	if (!-d $dirname)
	{
		print STDERR "Creating directory $dirname for RRD files\n" if ($wantdiag);
		my $curdir;
		for my $component (File::Spec->splitdir($dirname))
		{
			next if !$component;
			$curdir.="/$component";
			if (!-d $curdir)
			{
				if (!mkdir $curdir,0755)
				{
					print STDERR "cannot create directory $curdir: $!\n"  if ($wantdiag);
					return undef;
				}
				NMISNG::Util::setFileProtDiag(file =>$curdir);
			}
		}
	}

	print STDERR "Renaming/linking RRD file $oldrelname to $newrelname\n" if ($wantdiag);
	if (!link($oldfilename,$newfilename))
	{
		print STDERR "cannot link $oldrelname to $newrelname: $!\n"  if ($wantdiag);
		return undef;
	}

	return $oldfilename;
}

1;
