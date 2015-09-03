#!/usr/bin/perl
#
## $Id: menu.pl,v 8.23 2012/08/13 05:05:00 keiths Exp $
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

package main;
#use CGI::Debug( report => 'everything', on => 'anything' );

use FindBin;
use lib "$FindBin::Bin/../lib";
use Data::Dumper;

use NMIS;
use func;
use Sys;
use NMIS::Modules;

use JSON::XS;

# Prefer to use CGI::Pretty for html processing
# use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div *ul *li);
#use CGI qw(:standard *table *Tr *td *form *Select *div *ul *li);

use CGI qw(:standard *table *Tr *td *form *Select *div *form escape *ul *li);

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST

$Q = $q->Vars; # values in hash

# load NMIS configuration table
$C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});
$Q->{conf} = (exists $Q->{conf} and $Q->{conf} ) ?  $Q->{conf} : $C->{conf};

# set some defaults
my $widget_refresh = $C->{widget_refresh_time} ? $C->{widget_refresh_time} : 180 ;

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
	$user = $AU->{user};
}

# dispatch the request
if ($Q->{act} eq 'menu_bar_site') {			menu_bar_site(); # vertical parent menu
} elsif ($Q->{act} eq 'menu_bar_portal') {	menu_bar_portal(); # hr portal select
} elsif ($Q->{act} eq 'menu_panel_node') {	menu_panel_node();
} elsif ($Q->{act} eq 'menu_about_view') {	menu_about_view();
} elsif ( exists ($Q->{POSTDATA}) ) {	save_window_state();
} else { notfound(); }

sub notfound {
	print header({-type=>"text/html",-expires=>'now'});
	print "Menu; ERROR, act=$Q->{act}<br> \n";
	print "Request not found\n";
}

#============================================================================


# print the menu in boring HTML <ul><li>
# CGI ::Pretty would not format this  so I hardcoded the ident and recurse level to verify correct operation
# remove for production .
# this is a recursive function
# needs a tidyup..TBD
sub print_array_list {
	my $aref = shift;
	my $level = shift;
	my $arrow = shift;				# flag to print the directional arrow
	my $a = [];

	my $ident;
	foreach ( 0 .. $level) { $ident.='  '};


	while ( defined ( $a = shift @{$aref}) ) {
		if ( not ref $a ) {
			# current is a  header or item string
			# add the onclick handler if a href (ie) dont jquery it later, ccheaper and easier to cleanup here
			# ignore any links that have a 'target' attribute
			if ( $a =~ /href=/i and $a !~ /target/i ) {
				substr($a, index($a, '<a '), 3) = qq|<a onClick="clickMenu(this);return false" |;
			}
			# lookahead and test if the next arg is a string or ref
			# if a ref, dont add end_li tag, else wrap this in <li>xx</li>
			if ( not scalar @{$aref} ) {
				# finished the list
				print "$ident<li>$a</li>\n";
			}
			elsif ( not ref $aref->[0] ) {					# look ahead to the next item on the list
				# next is a list item
				print "$ident<li>$a</li>\n";
			}
			else {
				# next is a ref, so dont complete </li>
				# so we recurse and come back shortly
				print "$ident<li>$a";
			}
		}
		else {							# we have a reference, so recurse to it
			my $id = $level;
			$id++;
			my $id2;
			foreach ( 0 .. $id) { $id2.='  '};
			# print  the directional arrow first.
			if ( $arrow) { print qq|<img style="vertical-align:middle;" src="$C->{'<menu_url_base>'}/img/arrow_right_black.gif">|; }
			print "\n<ul>\n";		# and wrap it in a <ul>...</ul> tags
			print_array_list( $a, $id+1, 1 );					# recursive - pass the aref to ourslves
			print "</ul>\n$ident</li>\n";			#  arrow is printed on al sub menus
		}
	}
}


# VERTICAL SIDEBAR menu
# I have set these up as 'push @x, list of arrays
# format is
# menu[0] = ref to anon list( 'header string', ref to submenu items  );
# menu[1] = ref to anon list( 'header string', ref to submenu items  );
# a nested menu
# menu[2] = ref to anon list( 'header string', ( ref to anon list( 'header string', ref to submenu items  ));
#
# These are hardcoded here as a development exercise
# in reality the menu arrays should be generated by the user auth modules
# as that will provide a list of menu buttons, based on user rights

sub menu_bar_site {

	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu"});
	print_array_list( menu_site(), 1 , 0 );
	print $q->end_ul();

	
	sub menu_site {
		my $M = NMIS::Modules->new(module_base=>$C->{'<opmantek_base>'});
		my $modules = $M->getModules();

		my @menu_site = [];

		my @netstatus;		 
		push @netstatus, qq|<a id='ntw_metrics' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_metrics">Metrics</a>|;
		push @netstatus, qq|<a id='ntw_graph' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_metrics_graph">Network Metric Graphs</a>|;
		push @netstatus, qq|<a id='ntw_view' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_view">Network Metrics and Health</a>|;
		push @netstatus, qq|<a id='ntw_health' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_health">Network Status and Health</a>|;
		push @netstatus, qq|<a id='ntw_summary' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_large">Network Status and Health by Group</a>|;
		push @netstatus, qq|<a id='ntw_services' href="services.pl?conf=$Q->{conf}">Monitored Services</a>|;
		push @netstatus, qq|<a id='src_events' href="events.pl?conf=$Q->{conf}&amp;act=event_table_list">Current Events</a>|
				if ($AU->CheckAccess("tls_event_db","check"));

		push @netstatus, qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view&amp;lines=50">Network Events</a>|
						if ($AU->CheckAccess("Event_Log","check"));

		push @netstatus, qq|<a id='ntw_customer' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_customer">Customer Status and Health</a>| if tableExists('Customers');
		push @netstatus, qq|<a id='ntw_business' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_business">Business Services Status and Health</a>| if tableExists('BusinessServices');
		push @netstatus, qq|<a id='ntw_map' href="$modules->{opMaps}{link}?widget=true">Network Maps</a>| if $M->moduleInstalled(module => "opMaps");
		push @netstatus, qq|<a id='selectNode_open' onclick="selectNodeOpen();return false;">Quick Search</a>|;
		push @netstatus, qq|<a id='ntw_rss' href="community_rss.pl?widget=true">NMIS Community</a>|;
		
		push @menu_site,(qq|Network Status|,[ @netstatus ]);		


		my @netperf;		 
		push @netperf, qq|<a target='ntw_ipsla' href="$C->{ipsla}?conf=$Q->{conf}">IPSLA Monitor</a>|
				if ($AU->CheckAccess("ipsla_menu","check"));
		push @netperf, qq|<a id='ntw_overview' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_allgroups">All Groups</a>|;
		push @netperf, qq|<a id='ntw_overview' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_interface_overview">OverView</a>|;
		push @netperf, qq|<a id='ntw_top10' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_top10_view">Top 10</a>|;

		push @netperf, qq|<a id='ntw_links' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Links">Link List</a>|
								if ($AU->CheckAccess("Table_Links_view","check"));
		
		### 2012-11-26 keiths, Optional opFlow Widgets if opFlow Installed.
		if ($M->moduleInstalled(module => "opFlow") ) {
			push @netperf, qq|--------|;
			push @netperf, qq|<a id='ntw_flowSummary' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetflowSummary">Application Flows</a>|;
			push @netperf, qq|<a id='ntw_topnApps' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnApps">TopN Applications</a>|;
			push @netperf, qq|<a id='ntw_topnAppSrc' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnAppSrc">TopN Application Sources</a>|;
			push @netperf, qq|<a id='ntw_topnEndpoints' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnTalkers">TopN Talkers</a>|;
			push @netperf, qq|<a id='ntw_topnEndpoints' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnListeners">TopN Listeners</a>|;
		}
		push @menu_site,(qq|Network Performance|,[ @netperf ]);		

				
		#Handling optional items in the menu, depending on the config.
		my @nettools;		 
		push @nettools, qq|<a id='tools_ping' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_ping">Ping</a>|;
		push @nettools, qq|<a id='tools_trace' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_trace">Traceroute</a>|;
		push @nettools, qq|<a id='tools_lft' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_lft">LFT</a>| if (getbool($C->{view_lft})); 
		push @nettools, qq|<a id='tools_mtr' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_mtr">MTR</a>| if (getbool($C->{view_mtr}));
		push @nettools, qq|<a id='tls_snmp' href="snmp.pl?conf=$Q->{conf}&amp;act=snmp_var_menu">SNMP Tool</a>|;
													

		my @netitems;
		push @netitems, qq|<a id='tls_ip' href="ip.pl?conf=$Q->{conf}&amp;act=tool_ip_menu">IP Calc</a>|,
		qq|<a id='tls_dns_host' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=host">IP host</a>|,
		qq|<a id='tls_dns_dns' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=dns">IP dns</a>|,
		qq|<a id='tls_dns_arpa' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=arpa">IP arpa</a>|,
		qq|<a id='tls_dns_loc' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=loc">IP loc</a>| 
				if ($AU->CheckAccess("tls_dns","check"));

		push @nettools,	qq|IP Tools|, \@netitems if (@netitems);

		push @menu_site,(qq|Network Tools|,[ @nettools ]);		

		# Potential Future Capabilities
		#push @menu_site,	( qq|Business Dashboard|);
		#push @menu_site,	( qq|Applications Dashboard|);
		
		my @reports;
		#push @reports, qq|<a id='opReports' href="$modules->{opReports}{link}?widget=true">opReports</a>| if $M->moduleInstalled(module => "opReports");

		my @flavours=(qw(Current dynamic dyn History stored strd));
		while (@flavours)
		{
				my $long = shift @flavours;
				my $short = shift @flavours;
				my $accesskey = shift @flavours;
				
				my @details=("avail","Availability","available",
										 "health","Health","health",
										 "response","Response Time","response",
										 "top10","Top 10","top10",
										 "outage","Outage","outage",
										 "port","Port Counts","port");
				my @localrep;
				while (@details)
				{
						my $repkey = shift @details;
						my $replabel = shift @details;
						my $accesssub = shift @details;
						
						push @localrep, qq|<a id='${short}_$repkey' href="reports.pl?conf=$Q->{conf}&amp;act=report_${short}_${repkey}">$replabel</a>|
								if ($AU->CheckAccess("${accesskey}_${accesssub}","check"));
				}
				
				push @reports, $long, \@localrep if (@localrep);
		}
				
		push @menu_site,(qq|Reports|,[ @reports ]) if (@reports);
										
		# Potential Future Capabilities
		#push @menu_site,	( qq|Traffic Monitor|,
		#										[
		#											qq|<a id='tm_netflow' href="#">NetFlow</a>|
		#										]
		#									);
		
		my @stuff; 
		push @stuff, qq|<a id='src_events' href="events.pl?conf=$Q->{conf}&amp;act=event_table_list">Events</a>| 
				if ($AU->CheckAccess("tls_event_db","check"));
		push @stuff, qq|<a id='src_outages' href="outages.pl?conf=$Q->{conf}&amp;act=outage_table_view">Outages</a>|;
		push @stuff, qq|<a id='src_links' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Links">Links</a>|
								if ($AU->CheckAccess("Table_Links_view","check"));

		my @logstuff;
		push @logstuff, qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view&amp;logname=NMIS_Log">NMIS Log</a>|
				if ($AU->CheckAccess("NMIS_Log","check"));
		push @logstuff, qq|<a id='eventlogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view">Event Log</a>|
				if ($AU->CheckAccess("Event_Log","check"));
		push @logstuff, qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_list_view">Log List</a>|
				if ($AU->CheckAccess("log_list","check"));

		my @sdeskstuff;
		push @sdeskstuff, qq|Alerts|, \@stuff if (@stuff);
		push @sdeskstuff, qq|Find|, 
		[	
				qq|<a id='find_node' href="find.pl?conf=$Q->{conf}&amp;act=find_node_menu">Node</a>|,
				qq|<a id='find_interface' href="find.pl?conf=$Q->{conf}&amp;act=find_interface_menu">Interface</a>|
		];
		push @sdeskstuff, qq|Logs|, \@logstuff if (@logstuff);
		push @sdeskstuff, qq|<a id='ntw_services' href="services.pl?conf=$Q->{conf}">Monitored Services</a>|;
								
		push @menu_site, qq|Service Desk|, \@sdeskstuff;

		my $Tables = loadGenericTable('Tables');

		my @tableMenu;		 
			
		push @tableMenu, qq|<a id='cfg_nodes' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Nodes">NMIS Nodes (devices)</a>|
				if ($AU->CheckAccess("Table_Nodes_view","check"));

		push @tableMenu, qq|<a id='cfg_nmis' href="config.pl?conf=$Q->{conf}&amp;act=config_nmis_menu">NMIS Configuration</a>|
				if ($AU->CheckAccess("table_config_view","check"));

		push @tableMenu, qq|<a id='cfg_models' href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu">NMIS Models</a>|
				if ($AU->CheckAccess("table_models_view","check"));

		push @tableMenu, qq|<a id='cfg_nodecfg' href="nodeconf.pl?conf=$Q->{conf}&amp;act=config_nodeconf_view">Node Configuration</a>|
				if ($AU->CheckAccess("table_nodeconf_view","check"));

		push @tableMenu, qq|------| if (@tableMenu); # no separator if there's nothing to separate...

		foreach my $table (sort {$Tables->{$a}{DisplayName} cmp $Tables->{$b}{DisplayName} } keys %{$Tables}) { 
			push @tableMenu, qq|<a id="cfg_$table" href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=$table">$Tables->{$table}{DisplayName}</a>| if ($table ne "Nodes" and $AU->CheckAccess("Table_${table}_view","check"));
		}

		my (@systemitems, @setupitems);


		#if ($AU->CheckAccess("table_config_view","check"))
		#{
		#	push @systemitems,	qq|<a id='cfg_groups' href="config.pl?conf=$Q->{conf}&amp;act=config_nmis_edit&amp;section=system&amp;item=group_list">Add/Edit Groups</a>|;
		#}
    #
		#push @systemitems, qq|<a id='cfg_nodes' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_add&amp;table=Nodes">Add/Edit Nodes and Devices</a>|
		#		if ($AU->CheckAccess("Table_Nodes_view","check"));
    #
		#push @systemitems, qq|<a id='cfg_nodecfg' href="nodeconf.pl?conf=$Q->{conf}&amp;act=config_nodeconf_view">Node Customisation</a>|
		#		if ($AU->CheckAccess("table_nodeconf_view","check"));
    #
		#push @systemitems, qq|<a id='cfg_nmis' href="config.pl?conf=$Q->{conf}&amp;act=config_nmis_menu&amp;section=system">System Configuration</a>|
		#		if ($AU->CheckAccess("table_config_view","check"));
    #
		#push @systemitems, qq|<a id="cfg_Escalations" href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Escalations">Emails, Notifications and Escalations</a>| 
		#		if ($AU->CheckAccess("Table_Escalations_view","check"));
		#		
		#push @systemitems, qq|<a id="cfg_models" href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu&amp;model=Default&amp;section=threshold">Thresholding Alerts</a>| 
		#		if ($AU->CheckAccess("table_models_view","check"));				
    #
		#push @systemitems, qq|<a id="cfg_models" href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu&amp;model=Default&amp;section=event">Event Logging and Syslog</a>| 
		#		if ($AU->CheckAccess("table_models_view","check"));				
    #
		#push @systemitems, qq|------| if (@tableMenu); # no separator if there's nothing to separate...

		push @systemitems, qq|System Configuration|, \@tableMenu if (@tableMenu);

		if ($AU->CheckAccess("tls_event_flow","check")
				or $AU->CheckAccess("Table_Nodes_view","check"))
		{
			my @submenu;
			
			push @submenu, qq|<a id='cfg_setup' href="network.pl?conf=$Q->{conf}&amp;act=node_admin_summary">Node Admin Summary</a>| if ($AU->CheckAccess("Table_Nodes_view","check"));
			
			push @submenu, 	qq|<a id='tls_event_flow' href="view-event.pl?conf=$Q->{conf}&amp;act=event_flow_view">Check Event Flow</a>|,
			qq|<a id='tls_event_db' href="view-event.pl?conf=$Q->{conf}&amp;act=event_database_list">Check Event DB</a>| if ($AU->CheckAccess("tls_event_flow","check"));

			push @systemitems, qq|Configuration Check|, \@submenu;
		}

		my @hostdiags;
		if ($AU->CheckAccess("tls_nmis_runtime", "check"))
		{
			push @hostdiags, qq|<a id='nmis_selftest' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=nmis_selftest_view">NMIS Selftest</a>|,
			qq|<a id='nmis_poll' href="network.pl?conf=$Q->{conf}&amp;act=nmis_polling_summary">NMIS Polling Summary</a>|,
			qq|<a id='nmis_run' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=nmis_runtime_view">NMIS Runtime Graph</a>|;
		};
		push @hostdiags, qq|<a id='tls_host_info' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_hostinfo">NMIS Host Info</a>|;

		for my $cmd (qw(date df ps iostat vmstat who))
		{
				push @hostdiags, qq|<a id='tls_$cmd' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_$cmd">$cmd</a>|
						if ($AU->CheckAccess("tls_$cmd","check"));
		}		
		push @systemitems, qq|Host Diagnostics|, \@hostdiags if (@hostdiags);

		push @setupitems, qq|<a id='cfg_setup' href="setup.pl?conf=$Q->{conf}&amp;act=setup_menu">Basic Setup</a>|
				if ($AU->CheckAccess("table_config_view","check"));

		# no separator if there's nothing to separate...
		push @setupitems, qq|           | if (@setupitems);

		push @setupitems, qq|--- Advanced Setup ---| if (@setupitems); # no separator if there's nothing to separate...
		
		push @setupitems,	qq|<a id='cfg_groups' href="config.pl?conf=$Q->{conf}&amp;act=config_nmis_edit&amp;section=system&amp;item=group_list">Add/Edit Groups</a>|
				if ($AU->CheckAccess("table_config_view","check"));

		push @setupitems, qq|<a id='cfg_nodes' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_add&amp;table=Nodes">Add/Edit Nodes and Devices</a>|
				if ($AU->CheckAccess("Table_Nodes_view","check"));

		push @setupitems, qq|<a id='cfg_nodecfg' href="nodeconf.pl?conf=$Q->{conf}&amp;act=config_nodeconf_view">Node Customisation</a>|
				if ($AU->CheckAccess("table_nodeconf_view","check"));

		push @setupitems, qq|<a id="cfg_Contacts" href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Contacts">Contact Setup</a>| 
				if ($AU->CheckAccess("Table_Escalations_view","check"));
				
		push @setupitems, qq|<a id="cfg_Escalations" href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Escalations">Emails, Notifications and Escalations</a>| 
				if ($AU->CheckAccess("Table_Escalations_view","check"));
				
		push @setupitems, qq|<a id="cfg_Events" href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Events">Event Configuration</a>| 
				if ($AU->CheckAccess("Table_Events_view","check"));
				
		push @setupitems, qq|<a id="cfg_models" href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu&amp;model=Default&amp;section=threshold">Thresholding Alert Tuning</a>| 
				if ($AU->CheckAccess("table_models_view","check"));				

		#push @setupitems, qq|<a id="cfg_models" href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu&amp;model=Default&amp;section=event">Event Logging and Syslog</a>| 
		#		if ($AU->CheckAccess("table_models_view","check"));				

		push @menu_site, qq|Setup|, \@setupitems if (@setupitems);

		push @menu_site, qq|System|, \@systemitems if (@systemitems);

		# Moved Quick Search to network status and do not need NMIS Server anymore.
		#push @menu_site,( qq|Quick Select|,
		#										[	qq|<a id='selectServer_open' onclick="selectServerDisplay();return false;">NMIS Server</a>|,
		#											qq|<a id='selectNode_open' onclick="selectNodeOpen();return false;">Quick Search</a>|
		#										]
		#								);

		push @menu_site,( qq|Windows|,
												[	qq|<a id='saveWindow_open' onclick="saveWindowState();return false;">Save Windows and Positions</a>|,
													qq|<a id='clearWindow_open' onclick="clearWindowState();return false;">Clear Windows and Positions</a>|
												]
										);

		push @menu_site,( qq|Help|,
												[	qq|<a id='hlp_help' target='_blank' href="http://www.opmantek.com">NMIS</a>|,
													qq|<a id='hlp_apache' target='_blank' href="http://www.apache.org" id='apache'>Apache</a>|,
													qq|<a id='hlp_about' href="menu.pl?conf=$Q->{conf}&amp;act=menu_about_view">About</a>|
												]
										);
		return \@menu_site;
	}
}
	#==============================

# HORIZANTAL Menu - home and client tags

sub menu_bar_portal {
	
	# take this to config.xxxx.!
	# portal menu of nodes or clients to link to.
	
	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu"});
	print_array_list( menu_portal(), 1 , 0 );
	print $q->end_ul();


	sub menu_portal {
		my @menu_portal = [];
				push @menu_portal,	( qq|<a href="nmiscgi.pl?conf=$Q->{conf}" target='_self'>NMIS8 Home</a>|);
				push @menu_portal,	( qq|Client Views|,
												[
												 qq|<a href="http://master.domain.com/cgi-master/nmiscgi.pl" target='_blank'>NMIS4 Demo Master/Slave</a>|,
												  qq|<a href="#" >Customer A</a>|,
												   qq|<a href="#" >Customer B</a>|
												   
												]);
				
		return [ @menu_portal ];
	}
}

# ADD Node panel on request

sub menu_panel_node {
	# popup the next panels, include the 'nodename' and submenu of that.
	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu jd_menu_vertical"});
	print_array_list( [( $Q->{node} , menu_node_panel(node=>$Q->{node}) )], 1, 1 );
	print $q->end_ul();
}

#==============================

# CREATE Node panel (for nodeselect links)
# this is a <ul><li> .... </li></ul>

sub menu_node_panel {
	my %args = @_;
	my $node = $args{node};
	my $if;
	my $tooltip;

	my $NI = loadNodeInfoTable($node);
	my @menuInt;
	my @tmp;
	push @menuInt,	( qq|<a id="panel" name="Node" href="network.pl?conf=$Q->{conf}&amp;act=network_node_view&amp;node=$node&amp;server=$C->{server}">Node</a>| );
	# added check for no interfaces, node is down or never collected due to snmp fault..
	if ( getbool($NI->{system}{collect}) and keys %{$NI->{interface}} ) {
		#$menu_site[1][0] = qq|<a Interfaces</a>|;
		# check for interface up and collect is true
		# create temporal table
		foreach my $intf (keys %{$NI->{interface}}) {
			# get all interface where oper is up and collecting
			if ($NI->{interface}{$intf}{ifAdminStatus} eq 'up' 
					and getbool($NI->{interface}{$intf}{collect})) {
				$if->{$intf}{ifDescr} = $NI->{interface}{$intf}{ifDescr};
				$if->{$intf}{Description} = $NI->{interface}{$intf}{Description};
			}
		}
		@tmp=();
		# create the sorted interface list
		# but only if interface info available
		foreach my $intf (sorthash($if,['ifDescr'],'fwd')) {

			#TBD - nmisdev - replace with jquery popup ??

			$tooltip = '';
			#	$tooltip = ($if->{$intf}{Description} ne '' and $if->{$intf}{Description} ne 'noSuchObject') ? $if->{$intf}{Description} : '';
			#	$tooltip =~ s{[&<>/"']}{}g;  # needs work - fails ?
	
			if ($tooltip ne '') {
				push @tmp, (
						qq|<a id="panel" name="$if->{$intf}{ifDescr}" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$if->{$intf}{ifDescr}</a>|,
					,
					[ qq|<a id="panel" name="$if->{$intf}{ifDescr}_tp" title="$tooltip" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$tooltip</a>|
					]);
			} else {
				push @tmp, (  qq|<a id="panel" name="$if->{$intf}{ifDescr}" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$if->{$intf}{ifDescr}</a>| );
			}
		} # end int by int
		push @menuInt, ( 'Interfaces', [@tmp] );
		push  @menuInt, (  qq|<a id="panel" name="All Interfaces" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view_all&amp;node=$node">All interfaces</a>|);
		push  @menuInt, (  qq|<a id="panel" name="Active Interfaces" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view_act&amp;node=$node&amp;server=$C->{server}">Active Interfaces</a>|);
		if ($NI->{system}{nodeType} =~ /router|switch/ ) {
			push  @menuInt, (  qq|<a id="panel" name="Port Stats" href="network.pl?conf=$Q->{conf}&amp;act=network_port_view&amp;node=$node&amp;server=$C->{server}">Port Stats</a>|);
		}
		if ($NI->{system}{nodeType} =~ /server/ ) {
			push  @menuInt, ( qq|<a id="panel" name="Storage" href="network.pl?conf=$Q->{conf}&amp;act=network_storage_view&amp;node=$node&amp;server=$C->{server}">Storage</a>|);
		}
	}

	push  @menuInt, (  qq|<a id="panel" name="Events" href="events.pl?conf=$Q->{conf}&amp;act=event_table_view&amp;node=$node&amp;server=$C->{server}">Events</a>|);
	push  @menuInt, (  qq|<a id="panel" name="Outage" href="outages.pl?conf=$Q->{conf}&amp;act=outage_table_view&amp;node=$node&amp;server=$C->{server}">Outage</a>|);
	push  @menuInt, (  qq|Tools|,
							[
	 							qq|<a id="panel" name="Telnet" href="telnet://$NI->{system}{host}">Telnet</a>|,
								qq|<a id="panel" name="Ping" href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_ping&amp;node=$node&amp;server=$C->{server}">Ping</a>|,
								qq|<a id="panel" name="Trace" href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_trace&amp;node=$node&amp;server=$C->{server}">Trace</a>|
							]);
	return [ @menuInt ];			# return all
	
}


#==============================

sub menu_about_view {
	print header({-type=>"text/html",-expires=>'now'});
	print table(Tr(td({class=>'info'},<<EO_TEXT)));
<br/>
Network Management Information System<br/>
NMIS Version $NMIS::VERSION<br/>
Copyright (C) <a href="http://www.opmantek.com">Opmantek Limited (www.opmantek.com)</a><br/>
This program comes with ABSOLUTELY NO WARRANTY;<br/>
This is free software licensed under GNU GPL, and you are welcome to<br/>
redistribute it under certain conditions; see <a href="http://www.opmantek.com">www.opmantek.com</a> or email<br/>
 <a href="mailto:contact\@opmantek.com">contact\@opmantek.com<br/>

EO_TEXT

}

# read table of window states, update this user's entry, then write it 
# out again
sub save_window_state {
	my $data = $Q->{POSTDATA};	
	my $windowData = decode_json($data);
	my ($allWindowData, $handle) = loadTable(dir => 'var', 
																					 name => "nmis-windowstate",
																					 lock =>  'true');
	$allWindowData->{$user} = $windowData->{windowData};
		
	writeTable(dir=>'var', name=>"nmis-windowstate", data=>$allWindowData,
			handle => $handle);

	print header({-type=>"text/html",-expires=>'now'});
	print table(Tr(td({class=>'info'},<<EO_TEXT)));
<br/>
Success
EO_TEXT
	return;
}
# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
