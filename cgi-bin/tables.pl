#!/usr/bin/perl
#
## $Id: tables.pl,v 8.12 2012/09/18 01:40:59 keiths Exp $
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
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMIS;
use func;
use csv;
use Net::hostent;
use Socket;

use DBfunc;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

my $formid = $Q->{table} ? "nmis$Q->{table}" : "nmisTable";

my $widget = "true";
if ($Q->{widget} eq 'false' ) {	
	$widget = "false"; 
}

#======================================================================

# select function

if ($Q->{act} eq 'config_table_menu') { 			menuTable();
} elsif ($Q->{act} eq 'config_table_add') { 		editTable();
} elsif ($Q->{act} eq 'config_table_view') { 		viewTable();
} elsif ($Q->{act} eq 'config_table_show') { 		showTable();
} elsif ($Q->{act} eq 'config_table_edit') { 		editTable();
} elsif ($Q->{act} eq 'config_table_delete') { 		viewTable();
} elsif ($Q->{act} eq 'config_table_doadd') { 		if (doeditTable()) { menuTable(); }
} elsif ($Q->{act} eq 'config_table_doedit') { 		if (doeditTable()) { menuTable(); }
} elsif ($Q->{act} eq 'config_table_dodelete') { 	dodeleteTable(); menuTable(); 
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Tables: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit;

#==================================================================
#

sub loadReqTable {
	my %args = @_;
	my $table = $args{table};
	my $msg = $args{msg};

	my $T;

	my $db = "db_".lc($table)."_sql";
	if ($C->{$db} eq 'true' ) {
		$T = DBfunc::->select(table=>$table); # full table
	} else { 
		$T = loadTable(dir=>'conf',name=>$table);
	}
			
	if (!$T and $msg ne 'false') {
		print Tr(td({class=>'error'},"Error on loading table $table"));
		return;
	} 
	return $T;
}

sub loadCfgTable {
	my %args = @_;
	my $table = $args{table};

	# load node table to filter on group access list
	my @groups = ();
	my @nodes = ();
	my @privs = ();
	my @models = ();
	my @serviceStatus = ();
	my @businessServices = ();
	my @locations = ();

	my $LNT = loadLocalNodeTable(); # load from file or db
	my $GT = loadGroupTable();
	my $ServiceStatusTable = loadServiceStatusTable();
	my $BusinessServicesTable = loadBusinessServicesTable();
	my $LocationsTable = loadLocationsTable();
	
	foreach (sort split(',',$C->{group_list})) { push @groups, $_ if $AU->InGroup($_); }
	foreach (sort {lc($a) cmp lc($b)} keys %{$LNT}) { push @nodes, $_ if $AU->InGroup($LNT->{$_}{group}); }
	foreach (sort keys %{$ServiceStatusTable}) { push @serviceStatus, $_; }
	foreach (sort keys %{$BusinessServicesTable}) { push @businessServices, $_; }
	foreach (sort keys %{$LocationsTable}) { push @locations, $_; }

	if ($table eq "Nodes") {
		if ( opendir(MDL,$C->{'<nmis_models>'}) ) {
			@models = ('automatic',sort {uc($a) cmp uc($b)} (grep(s/^Model-(.*)\.nmis$/$1/,readdir MDL)));
		} else {
			print Tr(td({class=>'error'},"Error on loading models names from directory $C->{'<nmis_models>'}"));
		}
		closedir(MDL);
	}
	
	my $PM = loadTable(dir=>'conf',name=>'PrivMap');
	# I assume a natural order: administrator = 0 (highest priv) and guest = 6 (lowest priv)
	foreach (sorthash( $PM,['level'],'fwd')) { push @privs,$_ ;} 

	my %Cfg = ( 
		Nodes => [ # using an array for fixed order of fields
			{ name => { header => 'Name',display => 'key,header,text',value => [""] }},
			{ host => { header => 'Name/IP Address',display => 'header,text',value => [""] }},
			{ group => { header => 'Group',display => 'header,popup',value => [ @groups] }},
			{ location => { header => 'Location',display => 'header,popup',value => [ @locations] }},
			{ businessService => { header => 'Business Service',display => 'header,pop',value => [ @businessServices ] }},
			{ status => { header => 'Status',display => 'header,popup',value => [ @serviceStatus ] }},
			{ model => { header => 'Model',display => 'header,popup',value => [@models] }},
			{ active => { header => 'Active',display => 'header,popup',value => ["true", "false"] }},
			{ ping => { header => 'Ping', display => 'header,popup',value => ["true", "false"] }},
			{ collect => { header => 'Collect',display => 'header,popup',value => ["true", "false"] }},
			{ cbqos => { header => 'CBQoS',display => 'header,popup',value => ["none", "input", "output", "both"] }},
			{ calls=> {  header => 'Modem Calls', display => 'popup',value => ["false", "true"] }},
			{ threshold => { header => 'Threshold', display => 'popup',value => ["true", "false"] }},
			{ rancid => { header => 'Rancid', display => 'popup',value => ["false", "true"] }},
			{ webserver => { header => 'Web Server', display => 'popup',value => ["false", "true"] }},
			{ netType => { header => 'Net Type', display => 'popup',value => ["wan", "lan"] }},
			{ roleType => { header => 'Role Type', display => 'popup',value => ["core", "distribution", "access"] }},
			{ depend =>{ header => 'Depend', display => 'header,scrolling',value => [ "N/A", @nodes ] }},
			{ services => { header => 'Services', display => 'header,scrolling',value => ["", sort keys %{loadServicesTable()}] }},
			{ timezone => { header => 'Time Zone',display => 'text',value => ["0"] }},
			{ version => { header => 'SNMP Version',display => 'header,popup',value => ["snmpv2c","snmpv1","snmpv3"] }},
			{ community => { header => 'SNMP Community',display => 'text',value => ["$C->{default_communityRO}"] }},
			{ port => { header => 'SNMP Port', display => 'text',value => ["161"] }},
			{ username => { header => 'SNMP Username',display => 'text',value => ["$C->{default_username}"] }},
			{ authpassword => { header => 'SNMP Auth Password',display => 'text',value => ["$C->{default_authpassword}"] }},
			{ authkey => { header => 'SNMP Auth Key',display => 'text',value => ["$C->{default_authkey}"] }},
			{ authprotocol => { header => 'SNMP Auth Proto',display => 'popup',value => ['md5','sha'] }},
			{ privpassword => { header => 'SNMP Priv Password',display => 'text',value => ["$C->{default_privpassword}"] }},
			{ privkey => { header => 'SNMP Priv Key',display => 'text',value => ["$C->{default_privkey}"] }},
			{ privprotocol => { header => 'SNMP Priv Proto',display => 'popup',value => ['des','aes','3des'] }},
			{ status => { header => 'Select Status',display => 'header,pop',value => [ @status ] }},
			{ businessService => { header => 'Select Business Service',display => 'header,pop',value => [ @businessServices ] }},

			],

		Events => [
			{ Event => { header => 'Event',display => 'text', value => ["Generic Down", "Generic Up", "Interface Down", "Interface Up",
						"Node Down", "Node Reset", "Node Up", "Node Failover", "Proactive", "Proactive Closed",
						"RPS Fail", "TRAP", "SNMP Down", "SNMP Up","Service Down", "Service Up",] }},
			{ Role => { header => 'Role',display => 'text', value => ["core", "distribution", "access"] }},
			{ Type => { header => 'Type',display => 'text', value => ["router", "switch", "server", "generic"] }},
			{ Level => { header => 'Level',display => 'text', value => ["Normal", "Warning", "Major", "Critical", "Fatal"] }},
			{ Log => { header => 'Log',display => 'text', value => ["true", "false"] }},
			{ Mail => { header => 'Mail',display => 'text', value => ["true", "false" ] }},
			{ Notify => { header => 'Notify',display => 'text', value => ["true", "false" ] }},
			{ Pager => { header => 'Pager',display => 'text', value => ["true", "false" ] }}
			],

		Escalations => [
			{ Group => { header => 'Group',display => 'key,header,popup', value => ["default",@groups] }},
			{ Role => { header => 'Role',display => 'key,header,popup', value => ["default", "core", "distribution", "access"] }},
			{ Type => { header => 'Type',display => 'key,header,popup', value => ["default", "router", "switch", "server", "firewall","generic"] }},
			{ Event => { header => 'Event',display => 'key,header,popup', value => ["default", "Generic Down", "Generic Up", "Interface Down", "Interface Up",
						"Node Down", "Node Reset", "Node Failover", "Node Up",
						"RPS Fail", "TRAP", "SNMP Down", "SNMP Up",
						"Service Down", "Service Up",
						"Proactive Response Time",
						"Proactive Reachability",
						"Proactive CPU",
						"Proactive Memory",
						"Proactive Interface Availability",
						"Proactive Interface Input Utilisation",
						"Proactive Interface Output Utilisation",
						"Proactive Availability Threshold Interface",
						"Proactive Interface Input NonUnicast",
						"Proactive Interface Output NonUnicast"] }},
			{ 'Event_Node' => { header => 'Event Node',display => 'key,header,text', value => [""] }},
			{ 'Event_Element' => { header => 'Event Element',display => 'key,header,text', value => [""] }},
			{ Level0 => { header => 'Level 0',display => 'header,text', value => ["netsend:WKS1:WKS2,email:Contact1"] }},
			{ Level1 => { header => 'Level 1',display => 'header,text', value => ["pager:sysContact,email:Contact2"] }},
			{ Level2 => { header => 'Level 2',display => 'header,text', value => [""] }},
			{ Level3 => { header => 'Level 3',display => 'header,text', value => ["email:Contact3:Contact4"] }},
			{ Level4 => { header => 'Level 4',display => 'text', value => [""] }},
			{ Level5 => { header => 'Level 5',display => 'text', value => [""] }},
			{ Level6 => { header => 'Level 6',display => 'text', value => [""] }},
			{ Level7 => { header => 'Level 7',display => 'text', value => [""] }},
			{ Level8 => { header => 'Level 8',display => 'text', value => [""] }},
			{ Level9 => { header => 'Level 9',display => 'text', value => [""] }},
			{ Level10 => { header => 'Level 10',display => 'text', value => [""] }},
			{ UpNotify => { header => 'UpNotify',display => 'header,popup', value => ["false", "true" ] }}
			],

		Locations => [
			{ Location => { header => 'Location',display => 'key,header,text', value => [""] }},
			{ Geocode => { header => 'Geocode',display => 'header,text', value => [""] }},
			{ Address1 => { header => 'Address1',display => 'header,text', value => [""] }},
			{ Address2 => { header => 'Address2',display => 'header,text', value => [""] }},
			{ City => { header => 'City',display => 'header,text', value => [""] }},
			{ Country => { header => 'Country',display => 'header,text', value => [""] }},
			{ Floor => { header => 'Floor',display => 'header,text', value => [""] }},
			{ Latitude => { header => 'Latitude',display => 'text', value => ["36 51 S"] }},
			{ Longitude => { header => 'Longitude',display => 'text', value => ["174 46 E"] }},
			{ Postcode => { header => 'Postcode',display => 'header,text', value => [""] }},
			{ Room => { header => 'Room Number',display => 'text', value => [""] }},
			{ State => { header => 'State',display => 'header,text', value => [""] }},
			{ Suburb => { header => 'Suburb',display => 'text', value => [""] }}
			],

		Contacts => [
			{ Contact => { header => 'Contact',display => 'key,header,text', value => ["Contact1"] }},
			{ DutyTime => { header => 'DutyTime',display => 'header,text', value => ["00:24:MonTueWedThuFriSatSun"] }},
			{ Email => { header => 'Email',display => 'header,text', value => ["contact1\@$C->{domain_name}"] }},
			{ Location => { header => 'Location',display => 'header,text', value => ["default"] }},
			{ Mobile => { header => 'Mobile',display => 'header,text', value => [""] }},
			{ Pager => { header => 'Pager',display => 'header,text', value => [""] }},
			{ Phone => { header => 'Phone',display => 'header,text', value => [""] }},
			{ TimeZone  => { header => 'TimeZone',display => 'text', value => ["0"] }}
			],

		Services => [
			{ 'Name' => { header => 'Name',display => 'key,header,text', value => [ '' ] }},
			{ 'Service_Name' => { header => 'Service Name',display => 'header,text', value => [ '' ] }},
			{ 'Service_Type' => { header => 'Service Type',display => 'header,popup', value => [ 'service', "port", "dns", 'script', 'wmi' ] }},
			{ 'Port' => { header => 'Port',display => 'header,text', value => [ '' ] }},
			{ 'Poll_Interval' => { header => 'Poll Interval',display => 'header,popup', value => [ "5m", "1h", "1d" ] }}
			],

		Users => [
			{ user => { header => 'User',display => 'key,header,text', value => ["specify"] }},
			{ config => { header => 'Config file',display => 'header,text', value => ["Config"] }},
			{ privilege => { header => 'Privilege',display => 'header,popup', value => [ @privs ] }},
			{ admission => { header => 'Admission',display => 'header,popup', value => ["true","false","bypass"] }},
			{ groups => { header => 'Group',display => 'header,scrolling', value => ["none", "all", "network", (@groups) ] }}
			],

		Portal => [
			{ Order => { header => 'Order',display => 'key,header,text', value => ["default"] }},
			{ Name => { header => 'Name',display => 'header,text', value => [""] }},
			{ Link => { header => 'Link',display => 'header,text', value => [""] }}
			],

		PrivMap => [
			{ privilege => { header => 'Privilege',display => 'key,header,text', value => ["default"] }},
			{ level => { header => 'Level',display => 'header,text', value => [ "" ] }}
			],

		ifTypes => [
			{ index => { header => 'Index',display => 'key,header,text', value => [""] }},
			{ ifType => { header => 'ifType',display => 'header,text', value => [ "" ] }}
			],

		Toolset => [
			{ button => { header => 'Name',display => 'key,header,text', value => [""] }},
			{ bgroup => { header => 'Type',display => 'header,popup', value => ["tool"] }},
			{ display => { header => 'Display',display => 'header,text', value => [""] }},
			{ level0 => { header => $privs[0],display => 'header,popup', value => ["1","0"] }},
			{ level1 => { header => $privs[1],display => 'header,popup', value => ["0","1"] }},
			{ level2 => { header => $privs[2],display => 'header,popup', value => ["0","1"] }},
			{ level3 => { header => $privs[3],display => 'header,popup', value => ["0","1"] }},
			{ level4 => { header => $privs[4],display => 'header,popup', value => ["0","1"] }},
			{ level5 => { header => $privs[5],display => 'header,popup', value => ["0","1"] }},
			{ urlbase => { header => 'UrlBase',display => 'text', value => [""] }},
			{ urlscript => { header => 'UrlScript',display => 'text', value => [""] }},
			{ useconfig => { header => 'UseConfig',display => 'text', value => [""] }},
			{ needconfig => { header => 'NeedConfig',display => 'popup', value => ["no","yes"] }},
			{ urlquery => { header => 'UrlQuery',display => 'text', value => [""] }},
			{ usetarget => { header => 'UseTarget',display => 'text', value => [""] }}
			],

		Access => [
			{ name => { header => 'Name',display => 'key,header,text', value => [""] }},
			{ group => { header => 'Group',display => 'header,popup', value => ["access","button","tool"] }},
			{ descr => { header => 'Description',display => 'header,text', value => [""] }},
			{ level0 => { header => $privs[0],display => 'header,popup', value => ["1","0"] }},
			{ level1 => { header => $privs[1],display => 'header,popup', value => ["0","1"] }},
			{ level2 => { header => $privs[2],display => 'header,popup', value => ["0","1"] }},
			{ level3 => { header => $privs[3],display => 'header,popup', value => ["0","1"] }},
			{ level4 => { header => $privs[4],display => 'header,popup', value => ["0","1"] }},
			{ level5 => { header => $privs[5],display => 'header,popup', value => ["0","1"] }}
			],

		Links => [
			{ subnet => { header => 'Subnet',display => 'key,header,text', value => [""] }},
			{ mask => { header => 'Mask',display => 'header,text', value => [""] }},
			{ node1 => { header => 'Node',display => 'header,popup', value => ["",sort keys %{$LNT}] }},
			{ interface1 => { header => 'Interface',display => 'header,text', value => [""] }},
			{ ifIndex1 => { header => 'Index',display => 'text', value => [""] }},
			{ node2 => { header => 'Node',display => 'header,popup', value => ["",sort keys %{$LNT}] }},
			{ interface2 => { header => 'Interface',display => 'header,text', value => [""] }},
			{ ifIndex2 => { header => 'Index',display => 'text', value => [""] }},
			{ ifType => { header => 'Type',display => 'text', value => [""] }},
			{ ifSpeed => { header => 'Speed',display => 'text', value => [""] }},
			{ link => { header => 'Link',display => 'header,text', value => [""] }},
			{ depend => { header => 'Depend',display => 'text', value => [""] }},
			{ role => { header => 'Role Type',display => 'popup', value => ["core", "distribution", "access"] }},
			{ net => { header => 'Net Type',display => 'popup', value => ["wan","lan"] }}
			],

		Logs => [
			{ logOrder => { header => 'Order',display => 'key,header,text', value => [""] }},
			{ logName => { header => 'Name',display => 'header,text', value => [""] }},
			{ logDescr => { header => 'Description',display => 'header,text', value => [""] }},
			{ logFileName => { header => 'File',display => 'header,text', value => [""] }}
			],
			
		ServiceStatus => [
			{ serviceStatus => { header => 'Service Status',display => 'key,header,text', value => [""] }},
			{ statusPriority => { header => 'Service Priority',display => 'header,popup', value => [10,9,8,7,6,5,4,3,2,1,0] }}
			],
			
		BusinessServices => [
			{ businessService => { header => 'Business Service',display => 'key,header,text', value => [""] }},
			{ businessPriority => { header => 'Business Priority',display => 'header,popup', value => [10,9,8,7,6,5,4,3,2,1,0] }},
			{ serviceType => { header => 'Service Type',display => 'header,text', value => [""] }},
			{ businessUnit => { header => 'Business Unit',display => 'header,text', value => [""] }},
			]
	);

	if (!($Cfg{$table})) {
		print Tr(td({class=>'error'},"Configuration of table $table does not exists"));
		return;
	} 

	return $Cfg{$table};
}

#
sub menuTable{

	my $table = $Q->{table};
	#start of page
	print header($headeropts);
	pageStartJscript(title => "View Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");

	print <<EOF;
<script>
clearInterval();
</script>
EOF

	my $bt;
	my $T;
	$T = loadReqTable(table=>$table); # load requested table

	my $CT;
	return if (!($CT = loadCfgTable(table=>$table))); # load configuration of table

	print start_table;

	my $url = url(-absolute=>1)."?%conf=$Q->{conf}&table=$table";

	# print short info
	#print header
	print Tr( eval { my $line; my $colspan = 1;
			for my $ref ( @{$CT}) { # trick for order of header items
				for my $item (keys %{$ref}) {
					if ($ref->{$item}{display} =~ /header/ ) {
						$line .= td({class=>'header',align=>'center'},$ref->{$item}{header});
						$colspan++;
					}
				}
			}
			$line .= td({class=>'header',align=>'center'},'Action',
					eval {
						if ($AU->CheckAccess("Table_${table}_rw","check")) {
							return ' > '.a({href=>"$url&act=config_table_add"},'add'),
						} else { return ''; }
					}
				);
			return Tr(th({class=>'title',colspan=>$colspan},"Table $table")).$line;
		});
	# print data
	for my $k (sort {lc($a) cmp lc($b)} keys %{$T}) {
		print start_Tr;
		for my $ref ( @{$CT}) { # trick for order of header items
			for my $item (keys %{$ref}) {
				if ($ref->{$item}{display} =~ /header/ ) {
					print td({class=>'info Plain'},$T->{$k}{$item});
				}
			}
		}
		
		if ($AU->CheckAccess("Table_${table}_rw","check")) {
			$bt = a({href=>"$url&act=config_table_edit&key=$k"},'&nbsp;edit').
					a({href=>"$url&act=config_table_delete&key=$k"},'&nbsp;delete');
		} else {
			$bt = '';
		}
		print td({class=>'info Plain'},a({href=>"$url&act=config_table_view&key=$k"},'view'),$bt);
		print end_Tr;
	}

	print end_table;

	pageEnd() if ($widget eq "false");

}

sub viewTable {

	my $table = $Q->{table};
	my $key = $Q->{key};

	#start of page
	print header($headeropts);
	pageStartJscript(title => "View Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration

	if ($Q->{act} =~ /delete/) {
		 print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$C->{conf}&act=config_table_dodelete&table=$table&key=$key");
		}
	if ($Q->{act} =~ /view/) {
			 print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$C->{conf}&act=config_table_menu&table=$table&key=$key");
	}
		
	print start_table;
	print Tr(td({class=>'header',colspan=>'2'},"Table $table"));

	# print items of table
	for my $ref ( @{$CT}) { # trick for order of header items
		for my $item (keys %{$ref}) {
			print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
				td({class=>'info Plain'},$T->{$key}{$item}));
		}
	}

	if ($Q->{act} =~ /delete/) {
		print Tr(td('&nbsp;'),td(	
				button(-name=>"button",onclick=>"get('".$formid."');",-value=>"Delete"),"Are you sure",
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Cancel")));
	}
	if ($Q->{act} =~ /view/) {
		print Tr(td('&nbsp;'),td(	
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Ok"))); # bypass
	}

	print end_table;
	print end_form;
	pageEnd() if ($widget eq "false");
}

sub showTable {

	my $table = $Q->{table};
	my $key = $Q->{key};
	my $node = $Q->{node};
	my $found = 0;

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Show Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration

	print createHrButtons(node=>$node, refresh=>$Q->{refresh}, widget=>$widget);

	print start_table;
	print Tr(th({class=>'title',colspan=>'2'},"Table $table"));

	# try to find a match
	my $pos = length($key)+1;
	my $k = lc $key;
	$k =~ tr/+,./ /; # remove

	while ($pos > 0 && $found == 0) {
		my $s = substr($k,0,$pos);
		for my $t (keys %{$T}) {
			if ($s eq lc($t)) {
				$found = 1;
				# print items of table
				for my $ref ( @{$CT}) { # trick for order of header items
					for my $item (keys %{$ref}) {
						print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
							td({class=>'info Plain'},$T->{$t}{$item}));
					}
				}
				last;
			}
		}
		$pos = rindex($k," ",($pos - 1));
	}
	if (!$found) {
		print Tr(td({class=>'error'},"\'$key\' does not exist in table $table"));
	}

	print end_table;
	print end_form;
	pageEnd() if ($widget eq "false");
}

sub editTable {

	my $table = $Q->{table};
	my $key = $Q->{key};

	my @hash; # items of key

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Edit Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_rw");

	my $T;
	return if (!($T = loadReqTable(table=>$table,msg=>'false')) and $Q->{act} =~ /edit/); # load requested table

	my $CT = loadCfgTable(table=>$table);

	my $func = ($Q->{act} eq 'config_table_add') ? 'doadd' : 'doedit';
	my $button = ($Q->{act} eq 'config_table_add') ? 'Add' : 'Edit';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=config_table_${func}&table=${table}";

	# start of form
	print start_form(-name=>"$formid",-id=>"$formid",-href=>"$url");

	print start_table;
	print Tr(th({class=>'title',colspan=>'2'},"Table $table"));

	for my $ref ( @{$CT}) { # trick for order of header items
		for my $item (keys %{$ref}) {
			print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
				eval { my $line;
					if ($ref->{$item}{display} =~ /key/) {
						push @hash,$item;
					}
					if ($func eq 'doedit' and $ref->{$item}{display} =~ /key/) {
						$line .= td({class=>'header'},$T->{$key}{$item});
						$line .= hidden(-name=>$item, -default=>$T->{$key}{$item},-override=>'1'); 
					} elsif ($ref->{$item}{display} =~ /text/) {
						my $value = ($T->{$key}{$item} or $func eq 'doedit') ? $T->{$key}{$item} : $ref->{$item}{value}[0];
						$line .= td(textfield(-name=>"$item",size=>'35',value=>$value));
					} elsif ($ref->{$item}{display} =~ /pop/) {
						$line .= td(popup_menu(-name=>"$item", -style=>'width:100%;',
								-values=>$ref->{$item}{value},
								-default=>$T->{$key}{$item}));
					} elsif ($ref->{$item}{display} =~ /scrol/) {
						my @items = split(/,/,$T->{$key}{$item});
						$line.= td(scrolling_list(-name=>"$item", -multiple=>'true',
								-style=>'width:100%;',
								-size=>'6',
								-values=>$ref->{$item}{value},
								-default=>\@items));
					} 
					return $line;
				});
		}
	}

	print hidden(-name=>'hash', -default=>join(',',@hash),-override=>'1');
	print Tr(td('&nbsp;'),
				td( eval {
					if ($table eq 'Nodes') {
						return button(-name=>"button",onclick=>"javascript:get('".$formid."','update');", -value=>"$button and Update Node");
					} else { return "&nbsp;"; }
				},
				button(-name=>"button",onclick=>"get('".$formid."');", -value=>$button),
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Cancel")));

	print end_table;
	print end_form;
	pageEnd() if ($widget eq "false");
}

sub doeditTable {
	my $table = $Q->{table};
	my $hash = $Q->{hash};

	return 1 if $Q->{cancel} eq 'true';

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table,msg=>'false');

	my $CT = loadCfgTable(table=>$table);

	# combine key from values, values separated by underscrore
	my $key = join('_', map { $Q->{$_} } split /,/,$hash );
	$key = lc($key) if $table !~ /Nodes|BusinessServices|ServiceStatus|Locations/; # let key of table Nodes equal to name

	# test on existing key
	if ($Q->{act} =~ /doadd/) {
		if (exists $T->{$key}) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,"Key $key already exists in table"));
			return 0;
		}
		if ($key eq '') {
			print header($headeropts);
			print Tr(td({class=>'error'} ,"Field \'$hash\' must be filled in table $table"));
			return 0;
		}
	}

	my $V;
	# store new values in table
	for my $ref ( @{$CT}) {
		for my $item (keys %{$ref}) {
			$T->{$key}{$item} = stripSpaces($Q->{$item});
			$V->{$item} = stripSpaces($Q->{$item});
		}
	}

	my $db = "db_".lc($table)."_sql";
	if ($C->{$db} eq 'true' ) {
		my $stat;
		$V->{index} = $key; # add this column
		if ($Q->{act} =~ /doadd/) {
			$stat = DBfunc::->insert(table=>$table,data=>$V);
		} else {
			$stat = DBfunc::->update(table=>$table,data=>$V,index=>$key);
		}
		if (!$stat) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,DBfunc::->error()));
			return 0;
		}
	} else {
		writeTable(dir=>'conf',name=>$table,data=>$T);
	}

	# do update node with new values
	if ($table eq 'Nodes') {
		# check host address
		if ($T->{$key}{host} eq '') {
			print header($headeropts);
			print Tr(td({class=>'error'} ,"Field \'host\' must be filled in table $table"));
			return 0;
		}
		### test the DNS for DNS names, if no IP returned, error exit
		if ( $T->{$key}{host} !~ /\d+\.\d+\.\d+\.\d+/ ) {
			my $address = resolveDNStoAddr($T->{$key}{host});
			if ( $address !~ /\d+\.\d+\.\d+\.\d+/ or !$address ) {
				print header($headeropts);
				print Tr(td({class=>'error'} ,"ERROR, cannot resolve IP address \'$T->{$key}{host}\'<br>".
									"Please correct this item in table $table"));
				return 0;
			}
		}
		print STDERR "DEBUG: doeditTable->cleanEvent key=$key\n";
		cleanEvent($key,"tables.pl.editNodeTable");
		if ($Q->{update} eq 'true') {
			doNodeUpdate(node=>$key);
			return 0;
		}
	}

	return 1;
}

sub dodeleteTable {
	my $table = $Q->{table};
	my $key = $Q->{key};

	return 1 if $Q->{cancel} eq 'true';

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table);
	my $db = "db_".lc($table)."_sql";
	if ($C->{$db} eq 'true' ) {
		if (!(DBfunc::->delete(table=>$table,index=>$key))) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,DBfunc::->error()));
			return 0;
		}
	} else {
		# remote key
		my $TT;
		foreach (keys %{$T}) {
			if ($_ ne $key) { $TT->{$_} = $T->{$_}; }
		}
	
		writeTable(dir=>'conf',name=>$table,data=>$TT);
	}
}

sub doNodeUpdate {
	my %args = @_;
	my $node = $args{node};

	# note that this will force nmis.pl to skip the pingtest as we are a non-root user !!
	# for now - just pipe the output of a debug run, so the user can see what is going on !
	
	# now run the update and display 
	print header($headeropts);
	pageStartJscript(title => "Run update on $node") if ($widget eq "false");
	
	print "<pre>\n";
	print "Running update on node $node\n\n\n";
	
	open(PIPE, "$C->{'<nmis_bin>'}/nmis.pl type=update node=$node debug=1 2>&1 |"); 
	select((select(PIPE), $| = 1)[0]);			# unbuffer pipe
	select((select(STDOUT), $| = 1)[0]);			# unbuffer pipe

	while ( <PIPE> ) {
		print ;
	}
	close(PIPE);
	print "\n</pre>\n";

	print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_table_menu&table=$Q->{table}");

	print table(Tr(td({class=>'header'},"Completed web user initiated update of $node"),
				td(button(-name=>'button',-onclick=>"get('".$formid."')",-value=>'Ok'))));
	print end_form;
	pageEnd() if ($widget eq "false");
}

