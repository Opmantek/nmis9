#!/usr/bin/perl
#
## $Id: network.pl,v 8.33 2012/09/18 07:27:12 keiths Exp $
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

#===================
# nmisdev - 14 AUg 2011 - moved if/else to subs, and a parent sub,
# so that a more logical coding approach can be taken
# ===================
	
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

#use CGI::Debug( report=> [ 'errors', 'empty_body', 'time', 'params', 'cookies', 'environment'], header => 'control' );

use strict;
use NMIS;
use func;
use NMIS::Timing;

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *th *form *Select *div *hr);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span );

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# if options, then called from command line
if ( $#ARGV > 0 ) { $C->{auth_require} = 0; } # bypass auth

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {}; #{type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
	password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

#======================================================================

my $widget = "true";
if ($Q->{widget} eq 'false' ) {	
	$widget = "false"; 
	$Q->{expand} = "true";
}

### 2013-11-23 keiths adding some timing debug
my $t = NMIS::Timing->new();
my $timing = 0;
$timing = 1 if $Q->{timing} eq 'true';

if ( $Q->{refresh} eq "" and $widget eq "true" ) { 
	$Q->{refresh} = $C->{widget_refresh_time};
}
elsif ( $Q->{refresh} eq "" and $widget eq "false" ) { 
	$Q->{refresh} = $C->{page_refresh_time};
}

my $nodewrap = "nowrap";
$nodewrap = "wrap" if $C->{'wrap_node_names'} eq "true";

my $smallGraphHeight = 50;
my $smallGraphWidth = 400;

$smallGraphHeight = $C->{'small_graph_height'} if $C->{'small_graph_height'} ne "";
$smallGraphWidth = $C->{'small_graph_width'} if $C->{'small_graph_width'} ne "";

logMsg("TIMING: ".$t->elapTime()." Begin act=$Q->{act}") if $timing;

# select function
my $select;

if ($Q->{act} eq 'network_summary_health') {	$select = 'health'; 
} elsif ($Q->{act} eq 'network_summary_small') {	$select = 'small'; 
} elsif ($Q->{act} eq 'network_summary_large') {	$select = 'large';
} elsif ($Q->{act} eq 'network_summary_allgroups') {	$select = 'allgroups';
} elsif ($Q->{act} eq 'network_summary_group') {	$select = 'group';
} elsif ($Q->{act} eq 'network_summary_customer') {	$select = 'customer';
} elsif ($Q->{act} eq 'network_summary_business') {	$select = 'business';
} elsif ($Q->{act} eq 'network_summary_metrics') {	$select = 'metrics';
} elsif ($Q->{act} eq 'network_metrics_graph') {	viewMetrics(); exit;
} elsif ($Q->{act} eq 'network_top10_view') {	viewTop10(); exit;
} elsif ($Q->{act} eq 'network_node_view') {	viewNode(); exit;
} elsif ($Q->{act} eq 'network_storage_view') {	viewStorage(); exit;
} elsif ($Q->{act} eq 'network_service_view') {	viewService(); exit;
} elsif ($Q->{act} eq 'network_service_list') {	viewServiceList(); exit;
} elsif ($Q->{act} eq 'network_environment_view') {	viewEnvironment(); exit;
} elsif ($Q->{act} eq 'network_system_health_view') {	viewSystemHealth($Q->{section}); exit;
} elsif ($Q->{act} eq 'network_cssgroup_view') {	viewCSSGroup(); exit;
} elsif ($Q->{act} eq 'network_csscontent_view') {	viewCSSContent(); exit;
} elsif ($Q->{act} eq 'network_port_view') {	viewActivePort(); exit;
} elsif ($Q->{act} eq 'network_interface_view') {	viewInterface(); exit;
} elsif ($Q->{act} eq 'network_interface_view_all') {	viewAllIntf(); exit;
} elsif ($Q->{act} eq 'network_interface_view_act') {	viewActiveIntf(); exit;
} elsif ($Q->{act} eq 'network_interface_overview') {	viewOverviewIntf(); exit;
} elsif ($Q->{act} eq 'nmis_runtime_view') {	viewRunTime(); exit;
} elsif ($Q->{act} eq 'nmis_polling_summary') {	viewPollingSummary(); exit;
} else { notfound(); exit }

sub notfound {
	print header($headeropts);
	print "Network: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf} <br>\n";
	print "Request not found\n";
}

logMsg("TIMING: ".$t->elapTime()." Select Subs") if $timing;

# option to generate html to file
if ($Q->{http} eq 'true') {
	print start_html(
		-title=>'NMIS Network Summary',-style=>{'src'=>"$C->{'styles'}"},
		-meta=>{ 'CacheControl' => "no-cache",'Pragma' => "no-cache",'Expires' => -1 },
		-head => [
			Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'jquery_jdmenu_css'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"})
		]
	);
} else {
	print header($headeropts);
}

pageStart(title => "NMIS Network Status", refresh => $Q->{refresh}) if ($widget eq "false");

logMsg("TIMING: ".$t->elapTime()." Load Nodes and Groups") if $timing;

my $NT = loadNodeTable();
my $GT = loadGroupTable();
#my $ET = loadEventStateNoLock; # load by file or db

# graph request
my $ntwrk = ($select eq 'large') ? 'network' : ($Q->{group} eq '') ? 'network' : $Q->{group} ;

my $overallStatus;
my $overallColor;
my %icon;
my $group = $Q->{group};
my $customer = $Q->{customer};
my $business = $Q->{business};
my @groups = grep { $AU->InGroup($_) } sort keys %{$GT};

# define global stats, and default stats period.
my $groupSummary;
my $oldGroupSummary;
my $start = '-16 hours';
my $end = '-8 hours';

#===============================
# All global hash, metrics, icons, etc, are now populated
# Call each of the base  network display subs.
#======================================

logMsg("TIMING: ".$t->elapTime()." typeSummary") if $timing;

print "<!-- typeSummary select=$select start -->\n";

if ( $select eq 'metrics' ) { selectMetrics(); }
elsif ( $select eq 'health' ) { selectNetworkHealth(); }
elsif ( $select eq 'small' ) { selectSmall(); }
elsif ( $select eq 'large' ) { selectLarge(); }
elsif ( $select eq 'group' ) { selectLarge(group => $group); }
elsif ( $select eq 'customer' and $customer eq "" ) { selectNetworkHealth(type => "customer"); }
elsif ( $select eq 'customer' and $customer ne "" ) { selectLarge(customer => $customer); }
elsif ( $select eq 'business' and $business eq "" ) { selectNetworkHealth(type => "business"); }
elsif ( $select eq 'business' and $business ne "" ) { selectLarge(business => $business); }
#elsif ( $select eq 'group' ) { selectGroup($group); }
elsif ( $select eq 'allgroups' ) { selectAllGroups();}

print "<!-- typeSummary select=$select end-->\n";
pageEnd() if ($widget eq "false");

logMsg("TIMING: ".$t->elapTime()." END $Q->{act}") if $timing;

exit();
 # end main()

sub getSummaryStatsbyGroup {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};

	logMsg("TIMING: ".$t->elapTime()." getSummaryStatsbyGroup begin: $group$customer$business") if $timing;

	$groupSummary = getGroupSummary(group => $group, customer => $customer, business => $business, start => "-8 hours", end => "now");
	$oldGroupSummary = getGroupSummary(group => $group, customer => $customer, business => $business, start => "-16 hours", end => "-8 hours");

	$overallStatus = overallNodeStatus(group => $group, customer => $customer, business => $business);
	$overallColor = eventColor($overallStatus);

	# valid hash keys are metric reachable available health response

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h) {
		# defaults
		#$icon{${t}} = 'arrow_down_black';
		if ( $t eq "response" ) {
			if ( $oldGroupSummary->{average}{$t} <= ($groupSummary->{average}{$t} + $C->{average_diff}) ) {
				$icon{${t}} = 'arrow_up_red';
			}
			else {
				$icon{${t}} = 'arrow_down_green';
			}
		}
		else {
			if ( $oldGroupSummary->{average}{$t} <= ($groupSummary->{average}{$t} + $C->{average_diff}) ) {
				$icon{${t}} = 'arrow_up';
			}
			else {
				$icon{${t}} = 'arrow_down';
			}
		}
	}

	# metric difference
	my $metric = sprintf("%2.0u", $groupSummary->{average}{metric} - $oldGroupSummary->{average}{metric} );

	my $metric_color;
	if ($metric <= -1) { $metric_color = colorPercentHi($metric); $icon{metric_icon} = 'arrow_down_big';
		} elsif ($metric <   0) { $metric_color = colorPercentHi($metric); $icon{metric_icon} = 'arrow_down';
		} elsif ($metric <   1) { $metric_color = colorPercentHi($metric); $icon{metric_icon} = 'arrow_up';
	} elsif ($metric >=  1) { $metric_color = colorPercentHi($metric); $icon{metric_icon} = 'arrow_up_big'; }


	## ehg 17 sep 02 add node down counter with colour
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$percentDown = sprintf("%2.0u",$groupSummary->{average}{countdown}/$groupSummary->{average}{counttotal}) * 100;
	}
	$groupSummary->{average}{countdowncolor} = colorPercentLo($percentDown);
	#if ( $groupSummary->{average}{countdown} > 0) { $groupSummary->{average}{countdowncolor} = colorPercentLo(0); }
	#else { $groupSummary->{average}{countdowncolor} = "$overallColor"; }

	logMsg("TIMING: ".$t->elapTime()." getSummaryStatsbyGroup end") if $timing;

} # end sub get SummaryStatsby group

#============================
# Desc: network health metrics presented as a bar chart
# Menu: Network Performance -> Network Metrics
# url: network_summary_metrics -> select=metrics
# Title: Network Metrics
# Metric
# Reachability
# InterfaceAvaill
# Health
# ResponseTime
#============================

sub selectMetrics {

	if ($AU->InGroup("network") or $AU->InGroup($group)) {
		
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);

		my @h = qw/Metric Reachablility InterfaceAvail Health ResponseTime/;
		my @k = qw/metric reachable available health response/;
		my @item = qw/status reachability intfAvail health responsetime/;
		my $time = time;
		my $cp;

		print
		start_table({class=>"noborder", width => "100%"}),
		Tr(th({class=>"subtitle"},"8Hr Summary"));

		foreach my $t (0..4) {

			$groupSummary->{average}{$k[$t]} = int( $groupSummary->{average}{$k[$t]} );
			$cp = colorPercentHi( $groupSummary->{average}{$k[$t]});
			$cp = colorPercentLo( $groupSummary->{average}{$k[$t]}) if $t == 4;
			my $img_width = $groupSummary->{average}{$k[$t]};
			$img_width = 100 - $groupSummary->{average}{$k[$t]} if $t == 4;
			$img_width = 15 if $img_width < 10;						# set min width so value always has bg image color
			$img_width.='%';
			my $units = $t == 4 ? 'ms' : '%' ;
			print
			Tr(
				td({class=>'metrics', style=>"width:186px;"},
					span({style=>'float:left;'},
						img({src=>"$C->{$icon{$k[$t]}}"}),
						$h[$t]
					),
					span({style=>'float:right;'},
						"$groupSummary->{average}{$k[$t]}$units"
					),br,
					span({ style=>"display:inline-block;position:relative; width:100%; height:16px;border:1px solid;"},
						span({ style=>"display:inline-block;position:relative;background-color:$cp; width:$img_width;height:16px;"},
						span({ class=>"smallbold", style=>"float:right; height:16px;"},
							"$groupSummary->{average}{$k[$t]}$units"
						))),

					
					#div({style=>"width:100%; height:16px; color:black; background-color:D4D0F8; border:1px #000000 solid;"},
					#	div({style=>"width:$img_width; height:16px; overflow:hidden; border-right:1px 000000 solid; background-color:$cp;"},
					#		div({style=>"float:right; height:16px;", class=>'smallbold'},
					#			"$groupSummary->{average}{$k[$t]}%"
					#		)
					#	)
					#)
				)	#td
			);	#tr
				
			# old code
			#				Tr(td(
			#					#td({class=>'image'},htmlGraph(graphtype=>"metrics",group=>$ntwrk, item=>'health') ));
			#					img({src=>"rrddraw.pl?act=draw_graph_view&group=network&graphtype=metrics&item=$item[0]"})
			#					)));
			
		}	#foreach
	print	end_table;
	}	# endif AU
	else {
		print
		start_table({class=>"dash", width => "100%"}),
		Tr(th({class=>"subtitle"},"You are not authorized for this request"));
		print	end_table;
	}
} # end sub selectMetrics

#============================
# Desc: network status summarised to one line, with all groups summarised underneath
# Menu: Small Network Status and Health
# url: network_summary_health -> select=health
# Title: Current Network Status
# subtitle: All Groups Status
#============================

sub selectNetworkHealth {
	my %args = @_;
	my $type = $args{type};
	my $customer = $args{customer};
	my $business = $args{business};
	
	my @h=qw(Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime);
	my $healthTitle = "All Groups Status";
	my $healthType = "group";
	
	if ( $type eq "customer" and tableExists('Customers') ) { 
		@h=qw(Customer Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime);
		$healthTitle = "All Nodes Status";
		$healthType = "customer";
	}
	elsif ( $type eq "business" and tableExists('BusinessServices') ) { 
		@h=qw(Business Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime);
		$healthTitle = "All Nodes Status";
		$healthType = "business";
	}
	elsif ( $C->{network_health_view} eq "Customer" and tableExists('Customers') ) { 
		@h=qw(Customer Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime);
		$healthTitle = "All Nodes Status";
		$healthType = "customer";
	}
	elsif ( $C->{network_health_view} eq "Business" and tableExists('BusinessServices') ) { 
		@h=qw(Business Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime);
		$healthTitle = "All Nodes Status";
		$healthType = "business";
	}

	logMsg("TIMING: ".$t->elapTime()." selectNetworkHealth healthTitle=$healthTitle healthType=$healthType") if $timing;

	print
	start_table( {class=>"noborder" }),
	#Tr(th({class=>"title",colspan=>'10'},"Current Network Status")),
	# Use a subtitle when using multiple servers
	#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
	Tr(th({class=>"header"},\@h));

	if ($AU->InGroup("network") and $group eq ''){
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
			$percentDown = int( ($groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		print
		start_Tr,
		td(
			{class=>'infolft Plain'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_allgroups"},$healthTitle),
		),
		td({class=>"info $overallStatus"},"$overallStatus"),
		td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
		td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
		td({class=>'info Plain',style=>"background-color:".colorPercentLo($percentDown)},"$groupSummary->{average}{countdown}");
		#td({class=>'info Plain',style=>"background-color:".colorPercentLo($groupSummary->{average}{countdown})},"$groupSummary->{average}{countdown}");

		my @h = qw/metric reachable available health response/;
		foreach my $t (@h) {
			my $units = $t eq 'response' ? 'ms' : '%' ;
			my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf("%.1f",$groupSummary->{average}{$t});
			if ( $value == 100 ) { $value = 100 }
			my $bg = "background-color:" . colorPercentHi($groupSummary->{average}{$t});
			$bg = "background-color:" . colorResponseTime($groupSummary->{average}{$t},$C->{response_time_threshold}) if $t eq 'response';
			print
			start_td({class=>'info Plain',style=>"$bg"}),
			img({src=>$C->{$icon{${t}}}}),
			$value,
			"$units",
			end_td;
		}
		print end_Tr;
		
	}
	
	if ( $healthType eq "customer" ) {
		my $CT = loadGenericTable('Customers');
		foreach my $customer (sort keys %{$CT} ) {
			getSummaryStatsbyGroup(customer => $customer);
			printHealth(customer => $customer);
		}	# end foreach
	}
	elsif ( $healthType eq "business" ) {
		my $BS = loadGenericTable('BusinessServices');
		foreach my $business (sort keys %{$BS} ) {
			getSummaryStatsbyGroup(business => $business);
			printHealth(business => $business);
		}	# end foreach
	}
	else {
		foreach $group (sort keys %{$GT} ) {
			next unless $AU->InGroup($group);
			# get all the stats and stuff the hashs
			getSummaryStatsbyGroup(group => $group);
			printGroup($group);
		}	# end foreach
	}
	print end_table;

} # end sub selectNetworkHealth

#============================
# Desc: network status summarised to one line
# Menu: Small Network Status and Health
# url: network_summary_small -> select=small
# Title: Current Network Status
# subtitle: All Groups Status
#============================

sub selectSmall {

	my @h=qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	print
	start_table( {class=>"dash" }),
	Tr(th({class=>"title",colspan=>'10'},"Current Network Status")),
	# Use a subtitle when using multiple servers
	#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
	Tr(th({class=>"header"},\@h));

	if ($AU->InGroup("network") and $group eq ''){
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
			$percentDown = int( ($groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		print
		start_Tr,
		th(
			{class=>'info Plain'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_allgroups"},"All Groups Status"),
		),
		td({class=>"info $overallStatus"},"$overallStatus"),
		td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
		td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
		td({class=>'info Plain',style=>"background-color:".colorPercentLo($percentDown)},"$groupSummary->{average}{countdown}");
		#td({class=>'info Plain',style=>"background-color:".colorPercentLo($groupSummary->{average}{countdown})},"$groupSummary->{average}{countdown}");

		my @h = qw/metric reachable available health response/;
		foreach my $t (@h) {
			my $units = $t eq 'response' ? 'ms' : '%' ;
			my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf("%.1f",$groupSummary->{average}{$t});
			my $bg = "background-color:" . colorPercentHi($groupSummary->{average}{$t});
			$bg = "background-color:" . colorPercentLo($groupSummary->{average}{$t}) if $t eq 'response';
			print
			start_td({class=>'info Plain',style=>"$bg"}),
			img({src=>$C->{$icon{${t}}}}),
			$value,
			"$units",
			end_td;
		}
		print end_Tr,end_table;
	}
} # end sub selectSmall

#============================
# Desc: network status by group, each group summarised to one line
# menu: All Groups
# url: network_summary_group -> select=allgroups
# Title: Network Status by Group
# subtitle: All Groups Status
#============================

sub selectAllGroups {

	print
	start_table( {class=>"dash" }),
	Tr(th({class=>"title",colspan=>'10'},"All Group Status"));
	# Use a subtitle when using multiple servers
	#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),

	my @h=qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;
	print Tr(th({class=>"header"},\@h));

	foreach $group (sort keys %{$GT} ) {
		next unless $AU->InGroup($group);
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);
		printGroup($group);
	}	# end foreach
	print end_table;
	
} # end sub selectAllGroups

#====================================================
#
# network_summary_group & group=xxxxx

sub selectGroup {

	my $group = shift;

	# should we write a msg that this user is not authorised to this group ?
	return unless $AU->InGroup($group);
	
	my @h=qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	print
		start_table( {class=>"dash" }),
		Tr(th({class=>"title",colspan=>'10'},"$group Status")),
		# Use a subtitle when using multiple servers
		#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
		Tr(th({class=>"header"},\@h));
	# get all the stats and stuff the hashs
	getSummaryStatsbyGroup(group => $group);
	printGroup($group);
	print end_table;
	
	
} # end sub selectGroup


#==============================================



sub printGroup {

	my $group = shift;
	my $icon;

	print
	start_Tr,
	start_td({class=>'infolft Plain'});

	if ($AU->InGroup($group)) {
	# force a new window if clicked
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_group&refresh=$Q->{refresh}&widget=$widget&group=$group", id=>"network_summary_$group"},"$group");
	}
	else {
		print "$group";
	}
	print end_td;
	# calc node down cell color as a % of node total
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$percentDown = int( ($groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
	}
	print
	td({class=>"info $overallStatus"},$overallStatus),
	td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
	td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
	td({class=>'info Plain',style=>"background-color:".colorPercentLo($percentDown)},"$groupSummary->{average}{countdown}");

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h) {

		my $units = $t eq 'response' ? 'ms' : '%' ;
		my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf("%.1f",$groupSummary->{average}{$t});
		#my $value = sprintf("%.1f",$groupSummary->{average}{$t});
		if ( $value == 100 ) { $value = 100 }
		my $bg = "background-color:".colorPercentHi($groupSummary->{average}{$t}).';';
		$bg = "background-color:".colorResponseTime($groupSummary->{average}{$t},$C->{response_time_threshold}).';' if $t eq 'response';

		$groupSummary->{average}{$t} = int($groupSummary->{average}{$t});
		print
		start_td({class=>'info Plain',style=>"$bg"}),
		img({src=>$C->{$icon{${t}}}}),
		$value,
		"$units".
		end_td;
	}
	print end_Tr;
}	# end sub printGroup

sub printHealth {
	my %args = @_;
	my $customer = $args{customer};
	my $business = $args{business};

	my $icon;

	print
	start_Tr,
	start_td({class=>'infolft Plain'});

	#if ($AU->InGroup($group)) {
	# force a new window if clicked
	if ( $customer ne "" ) {
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_customer&refresh=$Q->{refresh}&widget=$widget&customer=$customer", id=>"network_summary_$customer"},"$customer");
	}
	elsif ( $business ne "" ) {
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_business&refresh=$Q->{refresh}&widget=$widget&business=$business", id=>"network_summary_$business"},"$business");
	}
	#}
	#else {
	#	print "$customer";
	#}
	
	print end_td;
	# calc node down cell color as a % of node total
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$percentDown = int( ($groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
	}
	print
	td({class=>"info $overallStatus"},$overallStatus),
	td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
	td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
	td({class=>'info Plain',style=>"background-color:".colorPercentLo($percentDown)},"$groupSummary->{average}{countdown}");

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h) {

		my $units = $t eq 'response' ? 'ms' : '%' ;
		my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf("%.1f",$groupSummary->{average}{$t});
		#my $value = sprintf("%.1f",$groupSummary->{average}{$t});
		if ( $value == 100 ) { $value = 100 }
		my $bg = "background-color:".colorPercentHi($groupSummary->{average}{$t}).';';
		$bg = "background-color:".colorResponseTime($groupSummary->{average}{$t},$C->{response_time_threshold}).';' if $t eq 'response';

		$groupSummary->{average}{$t} = int($groupSummary->{average}{$t});
		print
		start_td({class=>'info Plain',style=>"$bg"}),
		img({src=>$C->{$icon{${t}}}}),
		$value,
		"$units".
		end_td;
	}
	print end_Tr;
}	# end sub printCustomer





#============================
# Desc: network status by node, nodes listed by group,
# Menu: Large Network Status and Health
# url: network_summary_large -> select=large
# Title: Large Network Status and Health
# subtitle: {Group} Node list and Status
#============================'

sub selectLarge {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};

	getSummaryStatsbyGroup();
	my @headers = ('Node','Location','Type','Net','Role','Status','Health',
	'Reach','Intf. Avail.','Resp. Time','Outage','Esc.','Last Update');
	
	my $ST;
	if ($C->{server_master} eq "true") {	
		$ST = loadServersTable();
	}
	
	my $CT;
	if ($C->{network_health_view} eq "Customer" or $customer ne "") {	
		$CT = loadGenericTable('Customers');
	}
	
	my $groupcount = 0;
	#print start_table,start_Tr,start_td({class=>'table',colspan=>'2',width=>'100%'});
	#print br if $select eq "large";
	print start_table({class=>'dash', width=>'100%'});
	
	print Tr(th({class=>'toptitle',colspan=>'15'},"Customer $customer Groups")) if $customer ne "";
	print Tr(th({class=>'toptitle',colspan=>'15'},"Business Service $business Groups")) if $business ne "";

	foreach my $group (sort keys %{$GT} ) {	
		# test if caller wanted stats for a particular group
		if ( $select eq "customer" ) {
			next if $CT->{$customer}{groups} !~ /$group/;
		}
		elsif ( $select eq "group" ) {
			next if $group ne $Q->{group};
		}
		
		++$groupcount;
				
		my $printGroupHeader = 1;
		foreach my $node (sort {uc($a) cmp uc($b)} keys %{$NT}) {
			next if (not $AU->InGroup($group));
			if ( $group ne "" and $customer eq "" and $business eq "" ) {
				next unless $NT->{$node}{group} eq $group;
			}
			elsif ( $customer ne "" ) {
				next unless $NT->{$node}{customer} eq $customer and $NT->{$node}{group} eq $group;
			}
			elsif ( $business ne "" ) {
				next unless $NT->{$node}{businessService} =~ /$business/ and $NT->{$node}{group} eq $group;
			}
			next unless $NT->{$node}{active} eq 'true'; # optional skip
			
			if ( $printGroupHeader ) {
				$printGroupHeader = 0;
				print Tr(th({class=>'title',colspan=>'15'},"$group Node List and Status"));
				print Tr( eval {
					my $line;
					foreach my $h (@headers) {
						$line .= td({class=>'header',align=>'center'},$h);
					} return $line;
				} );
			}
			#
			#my $NI = loadNodeInfoTable($node);
			my $color;
			if ( $NT->{$node}{active} eq "true" ) {
				if ($NT->{$node}{ping} ne 'true' and $NT->{$node}{collect} ne 'true') {
					$color = "#C8C8C8"; # grey
					$groupSummary->{$node}{health_color} = $color;
					$groupSummary->{$node}{reachable_color} = $color;
					$groupSummary->{$node}{available_color} = $color;
					$groupSummary->{$node}{event_color} = $color;
					$groupSummary->{$node}{health} = '';
					$groupSummary->{$node}{reachable} = '';
					$groupSummary->{$node}{available} = '';
				}
				else {
					##$color = "#ffffff"; # white color
					$color = $groupSummary->{$node}{event_color};
				}
			}
			else {
				$color = "#aaaaaa";
			}
		
			# outage
			my $outage = td({class=>'info Plain'},""); # preset
			if ( $groupSummary->{$node}{outage} eq "current" or $groupSummary->{$node}{outage} eq "pending") {
				my $color = ( $groupSummary->{$node}{outage} eq "current" ) ? "#00AA00" : "#FFFF00";
						
				#	$outage = td({class=>'info Plain',onmouseover=>"Tooltip.show(\"$groupSummary->{$node}{outageText}\",event);",onmouseout=>"Tooltip.hide();",style=>getBGColor($color)},
				$outage = td({class=>'info Plain'},
					a({href=>"outages.pl?conf=$Q->{conf}&act=outage_table_view&node=$groupSummary->{$node}{name}"},$groupSummary->{$node}{outage}));
			}
		
			# escalate
			my $escalate = exists $groupSummary->{$node}{escalate} ? $groupSummary->{$node}{escalate} : '&nbsp;';
			
			# check lastupdate
			my $lastUpdate = "";
			my $colorlast = $color;
			my $time = $groupSummary->{$node}{lastUpdateSec};
			if ( $time ne "") {
				$lastUpdate = returnDateStamp($time);
				if ($time < (time - 60*15)) {
					$colorlast = "#ffcc00"; # to late
				}
			}
			
			#Figure out the icons for each nodes metrics.
			my @h = qw/metric reachable available health response/;
			foreach my $t (@h) {
				# defaults
				#$icon{${t}} = 'arrow_down_black';
				if ( $t eq "response" ) {
					if ( $oldGroupSummary->{$node}{$t} <= ($groupSummary->{$node}{$t} + $C->{average_diff}) ) {
						$groupSummary->{$node}{"$t-icon"} = 'arrow_up_red';
					}
					else {
						$groupSummary->{$node}{"$t-icon"} = 'arrow_down_green';
					}
				}
				else {
					if ( $oldGroupSummary->{$node}{$t} <= ($groupSummary->{$node}{$t} + $C->{average_diff}) ) {
						$groupSummary->{$node}{"$t-icon"} = 'arrow_up';
					}
					else {
						$groupSummary->{$node}{"$t-icon"} = 'arrow_down';
					}
					#Get some consistent formatting of the variable to be printed.
					$groupSummary->{$node}{$t} = sprintf("%.1f",$groupSummary->{$node}{$t});
					#Drop the .0 from 100.0
					if ( $groupSummary->{$node}{$t} == 100 ) { $groupSummary->{$node}{$t} = 100; }
					$groupSummary->{$node}{"$t-bg"} = "background-color:" . colorPercentHi($groupSummary->{$node}{$t});
				}		
			}
				
			# response time
			my $responsetime;
			if ($groupSummary->{$node}{ping} eq 'true') {
				my $ms = ($groupSummary->{$node}{response} ne '' and $groupSummary->{$node}{response} ne 'NaN') ? 'ms' : '' ;
				my $bg = "background-color:" . colorResponseTime($groupSummary->{$node}{response},$C->{response_time_threshold});
				$responsetime = td({class=>'info Plain',align=>'right',style=>$bg},
				img({src=>$C->{$groupSummary->{$node}{'response-icon'}}}),
				"" . sprintf("%.1f",$groupSummary->{$node}{response}). "$ms");
			} else {
				$responsetime = td({class=>'info Plain',align=>'right',style=>getBGColor($color)},"disabled");
			}
			my $nodelink;
			if ( $NT->{$node}{server} eq $C->{server_name} ) {
				$nodelink = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&refresh=$Q->{refresh}&widget=$widget&node=$node", id=>"node_view_$node"},$NT->{$node}{name});
			}
			else {
				my $server = $NT->{$node}{server};
				my $url = "$ST->{$server}{portal_protocol}://$ST->{$server}{portal_host}:$ST->{$server}{portal_port}$ST->{$server}{cgi_url_base}/network.pl?conf=$Q->{conf}&act=network_node_view&refresh=$Q->{refresh}&widget=false&node=$node";
				$nodelink = a({href=>"$url", target=>"Graph-$node", onclick=>"viewwndw(\'$node\',\'$url\',$C->{win_width},$C->{win_height})"},$NT->{$node}{name}) ." ". img({src=>"$C->{'nmis_slave'}",alt=>"NMIS Server $server"});
			}

			print Tr(
				td({class=>"infolft Plain $nodewrap"},$nodelink),
				td({class=>'info Plain'},$groupSummary->{$node}{sysLocation}),
				td({class=>'info Plain'},$groupSummary->{$node}{nodeType}),
				td({class=>'info Plain'},$groupSummary->{$node}{netType}),
				td({class=>'info Plain'},$groupSummary->{$node}{roleType}),
				td({class=>"info $groupSummary->{$node}{event_status}"},$groupSummary->{$node}{event_status}),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'health-bg'}},img({src=>$C->{$groupSummary->{$node}{'health-icon'}}}),$groupSummary->{$node}{health},"%"),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'reachable-bg'}},img({src=>$C->{$groupSummary->{$node}{'reachable-icon'}}}),$groupSummary->{$node}{reachable},"%"),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'available-bg'}},img({src=>$C->{$groupSummary->{$node}{'available-icon'}}}),$groupSummary->{$node}{available},"%"),
				$responsetime,
				$outage,
				td({class=>'info Plain'},$escalate),
				td({class=>'info Plain nowrap'},"$lastUpdate")
			);
		}	# end foreach node
	}	# end foreach group
	if ( not $groupcount ) {
		print Tr(th({class=>'Error',colspan=>'15'},"You are not authorised for any groups"));
	}
	print end_table;
}  # end sub selectLarge

sub viewRunTime {

	# $AU->CheckAccess, will send header and display message denying access if fails.
	$AU->CheckAccess("tls_nmis_runtime","header");
	
	print header($headeropts);
	pageStart(title => "NMIS Run Time") if ($widget eq "false");
	print start_table({class=>'dash'});
	print Tr(th({class=>'title'},"NMIS Runtime Graph"));
	print Tr(td({class=>'image'},htmlGraph(graphtype=>"nmis", node=>"", intf=>"", width=>"600", height=>"150") ));	
	print end_table;

} # viewRunTime

### 2012-01-11 keiths, adding some polling information
sub viewPollingSummary {

	# $AU->CheckAccess, will send header and display message denying access if fails.
	# using the same auth type as the nmis runtime graph
	$AU->CheckAccess("tls_nmis_runtime","header");
	
	my $sum;
	my $qossum;
	my $LNT = loadLocalNodeTable();
	foreach my $node (keys %{$LNT}) {
		++$sum->{count}{node};
		if ( getbool($LNT->{$node}{active}) ) {
			++$sum->{count}{active};
			
			my $NI = loadNodeInfoTable($node);
			++$sum->{group}{$NI->{system}{group}};
			++$sum->{nodeType}{$NI->{system}{nodeType}};
			++$sum->{netType}{$NI->{system}{netType}};
			++$sum->{roleType}{$NI->{system}{roleType}};
			++$sum->{nodeModel}{$NI->{system}{nodeModel}};
			
			my @cbqosdb = qw(cbqos-in cbqos-out);
			foreach my $cbqos (@cbqosdb) {
				if (defined $NI->{database}{$cbqos}) {
					++$sum->{count}{$cbqos};
					foreach my $idx (keys %{$NI->{database}{$cbqos}}) {
						++$qossum->{$cbqos}{interface};
						foreach my $db (keys %{$NI->{database}{$cbqos}{$idx}}) {
							++$qossum->{$cbqos}{classes};
						}
					}
				}
			}
			### 2013-08-07 keiths, taking to long when MANY interfaces e.g. > 200,000
			my $S = Sys::->new;
			if ($S->init(name=>$node,snmp=>'false')) { 
				my $IF = $S->ifinfo;
				foreach my $int (keys %{$IF}) {
					++$sum->{count}{interface};
					++$sum->{ifType}{$IF->{$int}{ifType}};		
					if ( getbool($IF->{$int}{collect}) ) {
						++$sum->{count}{interface_collect};
					}
				}
			}		
		}
		if ( getbool($LNT->{$node}{collect}) ) {
			++$sum->{count}{collect};
		}
		if ( getbool($LNT->{$node}{ping}) ) {
			++$sum->{count}{ping};
		}
	}
		
	print header($headeropts);
	pageStart(title => "NMIS Polling Summary") if ($widget eq "false");
	print start_table({class=>'dash'});
	print Tr(th({class=>'title',colspan=>'2'},"NMIS Polling Summary"));
	print Tr(td({class=>'heading3'},"Node Count"),td({class=>'rht Plain'},$sum->{count}{node}));	
	print Tr(td({class=>'heading3'},"active Count"),td({class=>'rht Plain'},$sum->{count}{active}));	
	print Tr(td({class=>'heading3'},"collect Count"),td({class=>'rht Plain'},$sum->{count}{collect}));	
	print Tr(td({class=>'heading3'},"ping Count"),td({class=>'rht Plain'},$sum->{count}{ping}));	
	print Tr(td({class=>'heading3'},"interface Count"),td({class=>'rht Plain'},$sum->{count}{interface}));	
	print Tr(td({class=>'heading3'},"interface collect Count"),td({class=>'rht Plain'},$sum->{count}{interface_collect}));	
	print Tr(td({class=>'heading3'},"cbqos-in Count"),td({class=>'rht Plain'},$sum->{count}{'cbqos-in'}));	
	print Tr(td({class=>'heading3'},"cbqos-out Count"),td({class=>'rht Plain'},$sum->{count}{'cbqos-out'}));	
	
	my @sumhead = qw(group nodeType netType roleType nodeModel ifType);
	foreach my $sh (@sumhead) {
		print Tr(td({class=>'heading',colspan=>'2'},"Summary of $sh"));		
		foreach my $item (keys %{$sum->{$sh}}) {
			print Tr(td({class=>'heading3'},"$item Count"),td({class=>'rht Plain'},$sum->{$sh}{$item}));	
		}
	}
	
	my @cbqosdb;
	push(@cbqosdb,"cbqos-in") if $sum->{count}{'cbqos-in'};
	push(@cbqosdb,"cbqos-out") if $sum->{count}{'cbqos-out'};
	foreach my $cbqos (@cbqosdb) {
		print Tr(td({class=>'heading',colspan=>'2'},"QoS Summary for $cbqos"));
		print Tr(td({class=>'heading3'},"$cbqos Interface Count"),td({class=>'rht Plain'},$qossum->{$cbqos}{interface}));	
		print Tr(td({class=>'heading3'},"$cbqos Class Count"),td({class=>'rht Plain'},$qossum->{$cbqos}{classes}));	
	}
	
	print end_table;

} # viewPollingSummary

sub viewMetrics {

	my $group = $Q->{group};
	if ($group eq "") {
		$group = "network";
	}

	print header($headeropts);
	pageStart(title => $group, refresh => $Q->{refresh}) if ($widget eq "false");
	
	if (!$AU->InGroup($group)) {
		print 'You are not authorized for this request';
		return;
	}
	
	#prepend the network group!
	#my @grouplist = split(",","network,$C->{group_list}");
	my $GT = loadGroupTable;
	my @grouplist = values %{$GT};
	my @groups = grep { $AU->InGroup($_) } sort (@grouplist);

	my $groupCode;		
	my $groupOption;
	
	if ( $AU->InGroup("network") ) {
		my $selected;
		if ( $group eq "network" ) {
			$selected = " selected=\"$group\"";
		}
		$groupOption .= qq|<option value="network"$selected>Network</option>\n|;		
	}

	foreach my $g (sort (@groups) ) {
		my $selected;
		if ( $Q->{group} eq $g ) {
			$selected = " selected=\"$g\"";
		}
		$groupOption .= qq|<option value="$g"$selected>$g</option>\n|;
	}

	my $startform = start_form({ action=>"javascript:get('ntw_graph_form');", -id=>'ntw_graph_form', -href=>"$C->{'<cgi_url_base>'}/network.pl?"});
	my $submit = submit(-name=>'ntw_graph_form', -value=>'Go', onClick=>"javascript:get('ntw_graph_form'); return false;");
	if ( $widget eq "false" ) {
		$startform = start_form({ method=>"get", -id=>'ntw_graph_form', action=>"$C->{'<cgi_url_base>'}/network.pl"});
		$submit = submit(-name=>'ntw_graph_form', -value=>'Go');
	}
	
	$groupCode = qq|			
				  Metrics for 
					<select name="group" size="1">
						$groupOption
					</select>
					<input type="hidden" name="act" value="network_metrics_graph"/>
					<input type="hidden" name="refresh" value="$Q->{refresh}"/>
					<input type="hidden" name="widget" value="$widget"/>
					$submit|;

	print "$startform\n";
	print start_table({class=>'dash'});	
	print Tr(td({class=>'heading'},$groupCode));
	
	#foreach my $g (@groups){
	#	print a({href=>url(-absolute=>1)."", id=>"ntw_graph"},"$g");
	#}
	
	print Tr(td({class=>'image'},htmlGraph(graphtype=>"metrics", group=>"$group", node=>"", intf=>"", width=>"600", height=>"150") ));
	print end_table;
	print "</form>\n";
} # viewMetrics

sub viewNode {

	# all info is generated by bin/nmis.pl
	my $node = $Q->{node};
	my $NT = loadNodeTable();
	
	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");
	
	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $time = time;

	if (!$AU->InGroup($NT->{$node}{group})) {
		print "You are not authorized for this request group=$NT->{$node}{group}";
		return;
	}

	### 2012-01-05 keiths, check if node is managed by slave server
	if ( $NT->{$node}{server} ne $C->{server_name} ) {	
		my $ST = loadServersTable();
				
		my $server = $NT->{$node}{server};
		my $url = "$ST->{$server}{portal_protocol}://$ST->{$server}{portal_host}:$ST->{$server}{portal_port}$ST->{$server}{cgi_url_base}/network.pl?conf=$ST->{$server}{config}&act=network_node_view&refresh=$C->{page_refresh_time}&widget=false&node=$node";
		my $nodelink = a({target=>"NodeDetails-$node", onclick=>"viewwndw(\'$node\',\'$url\',800,600)"},$NT->{$node}{name});
		print "$nodelink is managed by server $NT->{$node}{server}";
		print <<EO_HTML;
	<script>
		viewwndw('$node','$url',800,600);
		//var attrib = "scrollbars=yes,resizable=yes,width=" + 800 + ",height=" + 600;
		//ViewWindow = window.open('$url','$node',attrib);
		//ViewWindow.focus();
		\$('div#node_view_$node').hide().remove();
	</script>
EO_HTML
  	return;
	}
	
	my $ET = loadEventStateNoLock();
	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read node view table
	
	# fallback/default order and set of propertiess for displaying all information
	my @order = (
		'status'
		,'sysName'
		,'host_addr'
		,'group'
		,'customer'
		,'location'
		,'businessService'
		,'serviceStatus'
		,'notes'
		,'nodeType'
		,'nodeModel'
		,'sysUpTime'
		,'ifNumber'
		,'sysLocation'
		,'sysContact'
		,'sysDescr'
		,'lastUpdate'
		,'nodeVendor'
		,'sysObjectName'
		,'roleType'
		,'netType'
	);
	
  # the fallback is overruled and the list can be extended with custom properties
  # given in network_viewNode_field_list
	if ( exists $C->{network_viewNode_field_list} and $C->{network_viewNode_field_list} ne "" ) {
		@order = split(",",$C->{network_viewNode_field_list});
	}
	
	my @keys = grep { $_ =~ /value$/ } sort keys %{$V->{system}};
	map { $_ =~ s/_value$// } @keys;
	my @items;
	foreach my $i (@order) { # create array with order
		for (my $ii=0;$ii<=$#keys;$ii++) {
			if (lc $i eq lc $keys[$ii]) { push @items,$i; splice(@keys,$ii,1); last;}
		}
	}
	@items = (@items,@keys);
	
	### 2013-03-13 Keiths, adding an edit node button.
	my $editnode;
	if ( $AU->CheckAccessCmd("Table_Nodes_rw") ) {
		my $url = "$C->{'<cgi_url_base>'}/tables.pl?conf=$Q->{conf}&act=config_table_edit&table=Nodes&widget=$widget&key=$NI->{system}{name}";
		$editnode = qq| <a href="$url" id="cfg_nodes" style="color:white;">Edit Node</a>|;
	}

	my $editconf;
	if ( $AU->CheckAccessCmd("table_nodeconf_view") ) {
		my $url = "$C->{'<cgi_url_base>'}/nodeconf.pl?conf=$Q->{conf}&act=config_nodeconf_view&widget=$widget&node=$NI->{system}{name}";
		$editconf = qq| <a href="$url" id="cfg_nodecfg" style="color:white;">Node Configuration</a>|;
	}
	#http://nmisdev64.dev.opmantek.com/cgi-nmis8/nodeconf.pl?conf=Config.nmis&act=
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'dash'});
	
	print Tr(th({class=>'title', colspan=>'2'},"Node Details - $NI->{system}{name} - $editnode - $editconf"));
	print start_Tr;
	# first column
	print td({valign=>'top'},table({class=>'dash'},
	# list of values
		eval { 
			my @out;
			foreach my $k (@items){
				my $title = $V->{system}{"${k}_title"} || $S->getTitle(attr=>$k,section=>'system');
				if ($title ne '') {
					my $color = $V->{system}{"${k}_color"} || '#FFF';
					my $gurl = $V->{system}{"${k}_gurl"}; # create new window
					my $url = $V->{system}{"${k}_url"}; # existing window
					my $value = $V->{system}{"${k}_value"}; # value
					
					$color = colorPercentHi(100) if $V->{system}{"${k}_value"} eq "running";
					$color = colorPercentHi(0) if $color eq "red";

		
					if ($k eq 'lastUpdate') {
						# check lastupdate
						my $time = $NI->{system}{lastUpdateSec};
						if ( $time ne "" ) {
							if ($time < (time - 60*15)) {
								$color = "#ffcc00"; # to late
							}
						}
					}
					
					### 2012-02-21 keiths, fixed popup window not opening correctly.
					my $content = $value;
					if ($gurl) {
						$content = a({target=>"Graph-$node", onClick=>"viewwndw(\'$node\',\'$gurl\',$C->{win_width},$C->{win_height})"},"$value");
					} 
					elsif ($url) {
						$content = a({href=>$url},$value);
					} 
					
					my $printData = 1;
					$printData = 0 if $k eq "customer" and not tableExists('Customers');
					$printData = 0 if $k eq "businessService" and not tableExists('BusinessServices');
					$printData = 0 if $k eq "serviceStatus" and not tableExists('serviceStatus');
					$printData = 0 if $k eq "location" and not tableExists('Locations');
					
					if ( $printData ) {
						push @out,Tr(td({class=>'info Plain'},$title),
						td({class=>'info Plain',style=>getBGColor($color)},$content));
					}
				}
			}
			# display events
			if ( grep { $ET->{$_}{node} eq $node } keys %{$ET}) {
				push @out,Tr(td({class=>'header',colspan=>'2'},'Events'));
				for (sort keys %{$ET}) {
					if ($ET->{$_}{node} eq $node) {
						my $state = $ET->{$_}{ack} eq 'false' ? 'active' : 'inactive';
						my $details = $ET->{$_}{details};
						$details = "$ET->{$_}{element} $details" if $ET->{$_}{event} =~ /Proactive/ ;
						$details = $ET->{$_}{element} if $details eq "";
						push @out,Tr(td({class=>'info Plain'},'Event'),
						td({class=>'info Plain'},"$ET->{$_}{event} - $details, Escalate $ET->{$_}{escalate}, $state"));
					}
				}
			}
		
			return @out; 
		},
	));

	# second column
	print start_td({valign=>'top'}),start_table;

	if ($NI->{system}{collect} eq 'true' or $NI->{system}{ping} eq 'true') {
		my $GTT = $S->loadGraphTypeTable(); # translate graphtype to type
		my $cnt = 0;
		my @graphs = split /,/,$M->{system}{nodegraph};
	
		foreach my $graph (@graphs) {
			my @pr;
			# check if database rule exists
			next unless $GTT->{$graph} ne '';
			next if $graph eq 'response' and $NI->{system}{ping} eq 'false'; # no ping done
			# first two or all graphs
			if ($cnt == 2 and $Q->{expand} ne 'true' and $NI->{system}{collect} eq 'true') {
				if ($#graphs > 1) {
					# signal there are more graphs
					print Tr(td({class=>'info Plain'},a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&node=$node&expand=true"},"More graphs")));
				}
				last;
			}
			$cnt++;
			# proces multi graphs
			if ($graph eq 'hrsmpcpu') {
				foreach my $index ( keys %{$NI->{database}{hrsmpcpu}}) {
					push @pr, [ "Server CPU $index ($NI->{device}{$index}{hrDeviceDescr})", "hrsmpcpu", "$index" ];
				}
			} else {
				push @pr, [ $M->{heading}{graphtype}{$graph}, $graph ];
			}
			#### now print it
			foreach ( @pr ) {
				print Tr(td({class=>'header'},$_->[0])),
				Tr(td({class=>'image'},htmlGraph(graphtype=>$_->[1],node=>$node,intf=>$_->[2], width=>$smallGraphWidth,height=>$smallGraphHeight) ));
			}
		} # end for
	} else {
		print Tr(td({class=>'info Plain'},'no Graph info'));
	}
	print end_table,end_td;

	print end_Tr,end_table;

	pageEnd() if ($widget eq "false");
}


sub viewInterface {

	my $intf = $Q->{intf};

	my $node = $Q->{node};
	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");


	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read interface view table

	# order of items
	my @order = ('ifAdminStatus','ifOperStatus','ifDescr','ifType','Description','operAvail','totalUtil',
	'ifSpeed','ipAdEntAddr','ipSubnet','ifLastChange','collect','nocollect');
	
	# format key is ${index}_item_value
	my @keys = grep { $_ =~ /^(\d+).*_value$/ and $1 == $intf} sort keys %{$V->{interface}};
	
	map { $_ =~ s/^\d+_// } @keys;
	map { $_ =~ s/_value$// } @keys; # get only item
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table;
	
	print Tr(td({class=>'error'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	
	print start_Tr;
	# first column
	print td({valign=>'top',width=>'50%'},table(
		Tr(th({class=>'title', colspan=>'2',width=>'50%'},"Interface Details - $NI->{system}{name}::$V->{interface}{\"${intf}_ifDescr_value\"}")),
		eval { my (@out,@res);
			foreach my $i (@order) { # create array with order of items
				for (my $ii=0;$ii<=$#keys;$ii++) {
					if (lc $i eq lc $keys[$ii]) { push @res,$i; splice(@keys,$ii,1); last;}
				}
			}
			@res = (@res,@keys); # add rest
			foreach my $k (@res){
				my $title = $V->{interface}{"${intf}_${k}_title"} || $S->getTitle(attr=>$k);
				if ($title ne '') {
					my $color = $V->{interface}{"${intf}_${k}_color"} || '#FFF';
					my $value = $V->{interface}{"${intf}_${k}_value"};
					if ( $k eq "ifSpeed" and $V->{interface}{"${intf}_ifSpeedIn_value"} ne "" and $V->{interface}{"${intf}_ifSpeedOut_value"} ne "" ) {
						$value = qq|IN: $V->{interface}{"${intf}_ifSpeedIn_value"} OUT: $V->{interface}{"${intf}_ifSpeedOut_value"}|;
					}
					push @out,Tr(td({class=>'info Plain'},$title),
					td({class=>'info Plain',style=>getBGColor($color)},$value));
				}
			}
		return @out; },
		)
	);

	# second column
	print start_td({valign=>'top',width=>'500px'}),start_table;
	
	if ($V->{interface}{"${intf}_collect_value"} eq 'true') {
		print	Tr(td({class=>'header'},"Utilization")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>"autil",node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) )),
		Tr(td({class=>'header'},"Bits per second")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>"abits",node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
		;
	if (exists $NI->{database}{'pkts_hc'}{$intf}) {
		print Tr(td({class=>'header'},"Packets per second")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>'pkts_hc',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
		;
	}
	if (exists $NI->{database}{'cbqos-in'}{$intf}) {
		print Tr(td({class=>'header'},"CBQoS in")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>'cbqos-in',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
		;
	}
	if (exists $NI->{database}{'cbqos-out'}{$intf} ) {
		print Tr(td({class=>'header'},"CBQoS out")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>'cbqos-out',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
		;
	}
	
	} else {
		print Tr(td({class=>'info Plain'},'No graph info'));
	}
	print end_table,end_td;
	
	print end_Tr,end_table;
	
	pageEnd() if ($widget eq "false");

}

sub viewAllIntf {
	my %args = @_;
	my $active = $Q->{active}; # flag for only active interfaces to display

	my $node = $Q->{node};
	my $sort = $Q->{sort} || 'ifDescr';
	my $dir;
	if ($Q->{dir} eq '' or $Q->{dir} eq 'rev'){$dir='fwd';}else{$dir='rev';} # direction of sort

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read interface view table
	
	# order of header
	my @header = ('ifDescr','Description','ipAdEntAddr1','ifAdminStatus','ifOperStatus','operAvail','totalUtil',
	'ifSpeed','ifSpeedIn','ifSpeedOut','ifLastChange','collect','ifIndex','portDuplex','portSpantreeFastStart','vlanPortVlan','escalate');
	
	# create hash from loaded view table
	my %view;
	my %titles;
	my %items;
	for my $k (keys %{$V->{interface}}) {
		if ( $k =~ /^(\d+)_(.+)_(.+)$/ ) {
			my ($a,$b,$c) = ($1,$2,$3);		# $a=index, $b=item/header, $c=value|color
			$view{$a}{$b}{$c} = $V->{interface}{$k};	# value
			if ($c eq 'title' and $b ne "ipAdEntAddr1") { $titles{$b} = $V->{interface}{$k}; }
			$items{$b} = 1;
			if ($titles{$b} eq '') { $titles{$b} = $S->getTitle(attr=>$b); } # get title from Model if available
		}
	}
	
	# select available items in view table
	my @hd;
	for (@header) {
		next if $active eq 'true' and $_ eq 'collect'; # not interesting for active interfaces
		if ($items{$_} and $titles{$_} ne '' ) { push @hd,$_; } # available item
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table;
	
	print Tr(td({class=>'error'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	
	print Tr(th({class=>'title',width=>'100%'},"Interface Table of node $node"));
	
	print start_Tr,start_td,start_table;
	# print header
	print Tr(
	eval { my @out;
		foreach my $k (@hd){
			my @hdr = split(/\(/,$titles{$k}); # strip added info
			push @out,td({class=>'header',align=>'center'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view_all&node=$node&refresh=$Q->{refresh}&widget=$widget&sort=$k&dir=$dir&active=$Q->{active}"},
			$hdr[0]));
		}
		return @out;
	});
	
	# print data
	foreach my $intf ( sorthash(\%view,[${sort},"value"], $dir)) {
		next if $active eq 'true' and $view{$intf}{collect}{value} ne 'true';
		print Tr(
		eval { my @out;
			foreach my $k (@hd){
				my $color = ($view{$intf}{$k}{color} ne "") ? $view{$intf}{$k}{color} : '#FFF';
				push @out,td({class=>'info Plain',style=>getBGColor($color)},
				eval { my $line;
					$view{$intf}{$k}{value} = ($view{$intf}{$k}{value} =~ /noSuch|unknow/i) ? '' : $view{$intf}{$k}{value};
					if ($k eq 'ifDescr') {
						$line = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&refresh=$Q->{refresh}&widget=$widget&node=$node&intf=$intf"},$view{$intf}{$k}{value});
					} 
					elsif ($k eq 'Description' and $view{$intf}{ipAdEntAddr1}{value} ne "") {
						$line = "$view{$intf}{Description}{value}<br/>$view{$intf}{ipAdEntAddr1}{value}";
					}
					elsif ($k eq 'ifSpeed' and $view{$intf}{ifSpeedIn}{value} ne "" and $view{$intf}{ifSpeedOut}{value} ne "") {
						$line = "IN:$view{$intf}{ifSpeedIn}{value}<br/>OUT:$view{$intf}{ifSpeedOut}{value}";
					}

					elsif ($k eq 'ifSpeedIn' or $k eq 'ifSpeedOut' or $k eq 'ipAdEntAddr1') {
						#just skip display!
					}
					else {
						$line = $view{$intf}{$k}{value};
					}
					return $line;
				});
			}
		return @out; },
		);
	}
	print end_table,end_td,end_Tr;
	
	print end_table;

	pageEnd() if ($widget eq "false");

}

sub viewActiveIntf {

	$Q->{active} = 'true';
	viewAllIntf();

}

sub viewActivePort {
	my %args = @_;

	my $active = 'true'; # flag for only active interfaces to display

	my $node = $Q->{node};
	my $sort = $Q->{sort} || 'ifDescr';
	my $dir;
	if ($Q->{dir} eq '' or $Q->{dir} eq 'rev'){$dir='fwd';}else{$dir='rev';} # direction of sort

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read interface view table

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	# order of header
	my @header = ('ifDescr','Description','ifAdminStatus','ifOperStatus','operAvail','totalUtil');
	
	# create hash from view table
	my %view;
	my %titles;
	my %items;
	for my $k (keys %{$V->{interface}}) {
		if ( $k =~ /^(\d+)_(.+)_(.+)$/ ) {
			my ($a,$b,$c) = ($1,$2,$3);
			$view{$a}{$b}{$c} = $V->{interface}{$k};
			if ($c eq 'title') { $titles{$b} = $V->{interface}{$k}; }
			$items{$b} = 1;
			if ($titles{$b} eq '' ) { $titles{$b} = $S->getTitle(attr=>$b,section=>'interface'); }
		}
	}
	# select available items in view table
	my @hd;
	for (@header) {
		if ($items{$_} and $titles{$_} ne '') { push @hd,$_; } # available item
	}
	
	my $url = "network.pl?conf=$Q->{conf}&act=network_port_view&node=$node";
	
	# start of form
	print start_form(-id=>"nmis",-href=>"$url");
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table;
	
	print Tr(td({class=>'error'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	
	print Tr(th({class=>'title',width=>'100%'},"Interface Table of node $NI->{system}{name}"));
	
	my $graphtype = ($Q->{graphtype} eq '') ? $C->{default_graphtype} : $Q->{graphtype};
	my @graphtypes = ('','autil','util','abits','bits','pkts','pkts_hc','errpkts');
	my $colspan=2;
	
	print start_Tr,start_td,start_table;
	# print header
	print Tr(
	eval { my @out;
		foreach my $k (@hd){
			my @hdr = split(/\(/,$titles{$k}); # strip added info
			push @out,td({class=>'header',align=>'center'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_port_view&node=$node&sort=$k&dir=$dir&graphtype=$graphtype"},
			$hdr[0]));
		}
		push @out,td({class=>'header',align=>'center'},'Graph');
	if ($NI->{database}{'cbqos-in'} ne '') {
		push @out,td({class=>'header',align=>'center'},
		a({href=>"network.pl?conf=$Q->{conf}&act=network_port_view&node=$node&graphtype=cbqos-in"},'CBQoS in'));
		$colspan++;
	}
	if ($NI->{database}{'cbqos-out'} ne '') {
		push @out,td({class=>'header',align=>'center'},
		a({href=>"network.pl?conf=$Q->{conf}&act=network_port_view&node=$node&graphtype=cbqos-out"},'CBQoS out'));
		$colspan++;
	}
	push @out,td({class=>'header',align=>'center'}),popup_menu(-name=>"graphtype",
	-values=>\@graphtypes,-default=>$graphtype,onchange=>"get('nmis');");
	return @out;
	});
	
	# print data
	foreach my $intf ( sorthash(\%view,[${sort},"value"], $dir)) {
		next if $active eq 'true' and $view{$intf}{collect}{value} ne 'true';
		next if $graphtype =~ /cbqos/ and $NI->{database}{$graphtype}{$intf} eq '';
		print Tr(
		eval { my @out;
			foreach my $k (@hd){
				my $if = $view{$intf}{$k};
				my $color = ($if->{color} ne "") ? $if->{color} : '#FFF';
				push @out,td({class=>'info Plain',style=>getBGColor($color)},
				eval { my $line;
					$if->{value} = ($if->{value} =~ /noSuch|unknow/i) ? '' : $if->{value};
					if ($k eq 'ifDescr') {
						$line = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&node=$node&refresh=$Q->{refresh}&widget=$widget&intf=$intf"},$if->{value});
					} else {
						$line = $if->{value};
					}
					return $line;
				});
			}
			if ( ($S->getDBName(graphtype=>$graphtype,index=>$intf,check=>'true') or $graphtype =~ /cbqos/)) {
				push @out,td({class=>'image',colspan=>$colspan},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight));
			} else {
				push @out,'no data available';
			}
		return @out; },
		);
	}
	print end_table,end_td,end_Tr;
	
	print end_table,end_form;

	pageEnd() if ($widget eq "false");
}

sub viewStorage {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node), refresh => $Q->{refresh} if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'table'});
	
	print Tr(td({class=>'error',colspan=>'3'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	
	print Tr(th({class=>'title',colspan=>'3'},"Storage of node $NI->{system}{name}"));
	
	foreach my $st (sort keys %{$NI->{storage}} ) {
		my $D = $NI->{storage}{$st};
		my $graphtype = $D->{hrStorageGraph};
		my $index = $D->{hrStorageIndex};
		print start_Tr;
		print Tr(td({class=>'header'},'Type'),td({class=>'info Plain',width=>'40%'},$D->{hrStorageType}),
		td({class=>'header'},$D->{hrStorageDescr}));
		print Tr(td({class=>'header'},'Units'),td({class=>'info Plain'},$D->{hrStorageUnits}),
		td({class=>'image',rowspan=>'5'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print Tr(td({class=>'header'},'Size'),td({class=>'info Plain'},$D->{hrStorageSize}));
		print Tr(td({class=>'header'},'Total'),td({class=>'info Plain'},getBits($D->{hrStorageUnits} * $D->{hrStorageSize})));
		print Tr(td({class=>'header'},'Used'),td({class=>'info Plain'},getBits($D->{hrStorageUnits} * $D->{hrStorageUsed})));
		print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hrStorageDescr}));
		print end_Tr;
	}
	print end_table;
	pageEnd() if ($widget eq "false");
}

sub viewService {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);
	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read node view table

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'table'});
	
	print Tr(td({class=>'error',colspan=>'3'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';

	print Tr(th({class=>'title',colspan=>'3'},"Monitored services on node $NI->{system}{name}"));
	
	if (defined $NI->{database}{service}) {
		print Tr(
			td({class=>'header'},"Service"),
			td({class=>'header'},"Status"),
			td({class=>'header'},"History")
		);	
		foreach my $service (sort keys %{$NI->{database}{service}} ) {
			my $color = $V->{system}{"${service}_color"};
			$color = colorPercentHi(100) if $V->{system}{"${service}_value"} eq "running";
			$color = colorPercentHi(0) if $color eq "red";
			
			my $serviceGraphs = htmlGraph(graphtype=>"service",node=>$node,intf=>$service,width=>$smallGraphWidth,height=>$smallGraphHeight);
			if ( $V->{system}{"${service}_cpumem"} eq "true" ) {
				$serviceGraphs .= htmlGraph(graphtype=>"service-cpumem",node=>$node,intf=>$service,width=>$smallGraphWidth,height=>$smallGraphHeight);
			}
			print Tr(
				td({class=>'info Plain'},$service),
				td({class=>'info Plain',style=>"background-color:".$color},$V->{system}{"${service}_value"}),
				td({class=>'image'},$serviceGraphs)
			);	
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>'3'},"No Services defined for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if ($widget eq "false");
}

sub viewServiceList {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);
	my $V = loadTable(dir=>'var',name=>lc("${node}-view")); # read node view table

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'table'});
	
	print Tr(td({class=>'error',colspan=>'6'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';

	print Tr(th({class=>'title',colspan=>'6'},"List of Services on node $NI->{system}{name}"));
	
    #'AppleMobileDeviceService.exe:1756' => {
    #  'hrSWRunStatus' => 'running',
    #  'hrSWRunPerfMem' => 2584,
    #  'hrSWRunType' => '',
    #  'hrSWRunPerfCPU' => 7301,
    #  'hrSWRunName' => 'AppleMobileDeviceService.exe:1756'
    #},
    
	if (defined $NI->{services}) {
		print Tr(
			td({class=>'header'},"Service"),
			td({class=>'header'},"Type"),
			td({class=>'header'},"Status"),
			td({class=>'header'},"PID"),
			td({class=>'header'},"CPU"),
			td({class=>'header'},"Memory")
		);	
		foreach my $service (sort keys %{$NI->{services}} ) {
			my $color;
			$color = colorPercentHi(100) if $NI->{services}{$service}{hrSWRunStatus} =~ /running|runnable/;
			$color = colorPercentHi(0) if $color eq "red";
			my ($prog,$pid) = split(":",$NI->{services}{$service}{hrSWRunName});
			
			print Tr(
				td({class=>'info Plain'},$prog),
				td({class=>'info Plain'},$NI->{services}{$service}{hrSWRunType}),
				td({class=>'info Plain',style=>"background-color:".$color},$NI->{services}{$service}{hrSWRunStatus}),
				td({class=>'info Plain'},$pid),
				td({class=>'info Plain'},$NI->{services}{$service}{hrSWRunPerfCPU}),
				td({class=>'info Plain'},$NI->{services}{$service}{hrSWRunPerfMem} . " KBytes")
			);	
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>'6'},"No Services found for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if ($widget eq "false");
}

sub viewEnvironment {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'table'});
	
	print Tr(td({class=>'error',colspan=>'3'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	
	print Tr(th({class=>'title',colspan=>'3'},"Environment of node $NI->{system}{name}"));
	
	foreach my $index (sort keys %{$NI->{env_temp}} ) {
		my $graphtype = $NI->{graphtype}{$index}{env_temp};
		my $D = $NI->{env_temp}{$index};
		print start_Tr;
		print Tr(td({class=>'header'},'Sensor'),td({class=>'info Plain',width=>'40%'},($index+1)),
		td({class=>'header'},$D->{tempDescr}));
		print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{tempDescr}),
		td({class=>'image',rowspan=>'2'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print Tr(td({class=>'header'},'Temp. Type'),td({class=>'info Plain'},$D->{tempType}));
		print end_Tr;
	}
	foreach my $index (sort keys %{$NI->{akcp_temp}} ) {
		my $graphtype = $NI->{graphtype}{$index}{akcp_temp};
		my $D = $NI->{akcp_temp}{$index};
		print start_Tr;
		print Tr(td({class=>'header'},'Sensor'),td({class=>'info Plain',width=>'40%'},($index+1)),
		td({class=>'header'},$D->{hhmsSensorTempDescr}));
		print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hhmsSensorTempDescr}),
		td({class=>'image',rowspan=>'2'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print Tr(td({class=>'header'},'Temp. Type'),td({class=>'info Plain'},$D->{hhmsSensorTempType}));
		print end_Tr;
	}
	foreach my $index (sort keys %{$NI->{akcp_hum}} ) {
		my $graphtype = $NI->{graphtype}{$index}{akcp_hum};
		my $D = $NI->{akcp_hum}{$index};
		print start_Tr;
		print Tr(td({class=>'header'},'Sensor'),td({class=>'info Plain',width=>'40%'},($index+1)),
		td({class=>'header'},$D->{hhmsSensorHumDescr}));
		print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hhmsSensorHumDescr}),
		td({class=>'image',rowspan=>'1'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print end_Tr;
	}
	print end_table;
	pageEnd() if ($widget eq "false");
}

sub viewSystemHealth {
	my $section = shift;

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}
	
	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	
	print start_table({class=>'table'});
	
	my $gotHeaders = 0;
	my $headerDone = 0;
	my $colspan = 0;
	my @headers;
	if ( $M->{systemHealth}{sys}{$section}{headers} ) {
		@headers = split(",",$M->{systemHealth}{sys}{$section}{headers});
		$gotHeaders = 1;
	}
	
	foreach my $index (sort {$a <=> $b} keys %{$NI->{$section}} ) {
		if( exists( $M->{systemHealth}{rrd}{$section}{control} ) && 
				$S->parseString(string=>"($M->{systemHealth}{rrd}{$section}{control}) ? 1:0",sys=>$S,index=>$index,sect=>$section) ne "1") {
			next;
		}

		my $graphtype = $NI->{graphtype}{$index}{$section};
		my $D = $NI->{$section}{$index};

		# get the header from the node informaiton first.
		if ( not $headerDone ) {
			if ( not $gotHeaders ) {
				foreach my $head (keys %{$NI->{$section}{$index}}) {
					push(@headers,$head);
				}
			}
			my @cells;
			my $cell;
			foreach my $head (@headers) {
				if ( $M->{systemHealth}{sys}{$section}{snmp}{$head}{title} ) {
					$cell = td({class=>'header'},$M->{systemHealth}{sys}{$section}{snmp}{$head}{title});
				}
				else {
					$cell = td({class=>'header'},$head);					
				}
				push(@cells,$cell);
				++$colspan;
			}
			push(@cells,td({class=>'header'},"History")) if $graphtype;
			++$colspan;
			
			print Tr(td({class=>'error',colspan=>$colspan},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
			print Tr(th({class=>'title',colspan=>$colspan},"$section of node $NI->{system}{name}"));

			my $row = join(" ",@cells);			
			print Tr($row);
			$headerDone = 1;
		}
		
		# now make each cell!
		my @cells;
		my $cell;
		foreach my $head (@headers) {
			$cell = td({class=>'info Plain'},$D->{$head});
			push(@cells,$cell);
		}

		if ( $graphtype ) {
			split /,/, $M->{system}{nodegraph};
			my @graphtypes = split /,/, $graphtype;
	
			push(@cells, start_td);
			foreach my $GT (@graphtypes) {
				push(@cells,htmlGraph(graphtype=>$GT,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)) if $GT;
			}
			push(@cells, end_td);
		}

		# push(@cells,td({class=>'image',rowspan=>'1'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight))) if $graphtype;
		my $row = join(" ",@cells);			
		print Tr($row);

		#print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hhmsSensorHumDescr}),
		#td({class=>'image',rowspan=>'1'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
	}
	print end_table;
	pageEnd() if ($widget eq "false");
}

#2011-11-11 Integrating changes from Kai-Uwe Poenisch
sub viewCSSGroup {
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);
	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	print start_table({class=>'table'});
	print Tr(td({class=>'error',colspan=>'3'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	print Tr(td({class=>'tabletitle',colspan=>'3'},"Groups of node $NI->{system}{name}"));

	foreach my $index (sort keys %{$NI->{cssgroup}} ) {
		my $graphtype = $NI->{graphtype}{$index}{cssgroup};
		my $D = $NI->{cssgroup}{$index};
		print start_Tr;
		print Tr(td({class=>'header'},  $D->{CSSGroupDesc}),
				td({class=>'image',rowspan=>'1'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print end_Tr;
	}

	print end_table;
	pageEnd() if ($widget eq "false");
}
 
#2011-11-11 Integrating changes from Kai-Uwe Poenisch
sub viewCSSContent {
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NI = loadNodeInfoTable($node);
	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget);
	print start_table({class=>'table'});
	print Tr(td({class=>'error',colspan=>'3'},'Node unreachable')) if $NI->{system}{nodedown} eq 'true';
	print Tr(td({class=>'tabletitle',colspan=>'3'},"Content of node $NI->{system}{name}"));

	foreach my $index (sort keys %{$NI->{csscontent}} ) {
		my $graphtype = $NI->{graphtype}{$index}{csscontent};
		my $D = $NI->{csscontent}{$index};
		print start_Tr;
		print Tr(td({class=>'header'},  $D->{CSSContentDesc}),
				td({class=>'image',rowspan=>'1'},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print end_Tr;
	}

	print end_table;
	pageEnd() if ($widget eq "false");
}

sub viewOverviewIntf {

	my $node;
	#	my @out;
	my $icon;
	my $cnt;
	my $text;

	print header($headeropts);
	pageStart(title => $node, refresh => $Q->{refresh}) if ($widget eq "false");

	my $NT = loadNodeTable();
	my $II = loadInterfaceInfo();
	my $GT = loadGroupTable();
	my $ii_cnt = keys %{$II};

	my $gr_menu = "";

	# start of form
	print start_form(-id=>"ntw_int_overview",-href=>url(-absolute=>1)."?conf=$C->{conf}&act=network_interface_overview");

	if ($ii_cnt > 1000) {
		my $GT = loadGroupTable();
		my @groups = ('',sort keys %{$GT});
		$gr_menu =  td({class=>'header', colspan=>'1'},
		"Select group ".
		popup_menu(-name=>'group', -override=>'1',
		-values=>\@groups,
		-default=>$Q->{group},
		-onChange=>"javascript:get('ntw_int_overview');"));
	}

	if ($ii_cnt > 50000) {
		print table(Tr(th({class=>'title'},'Too many interfaces to run report.')));
		return;
	}

	print table(Tr(th({class=>'title'},'Overview of status of Interfaces'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/arrow_up_green.png",border=>'0', width=>'11', height=>'10'}),'Up'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/arrow_down_red.png",border=>'0', width=>'11', height=>'10'}),'Down'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/arrow_up_yellow.png",border=>'0', width=>'11', height=>'10'}),'Dormant'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/arrow_up_purple.png",border=>'0', width=>'11', height=>'10'}),'Up no collect'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/block_grey.png",border=>'0', width=>'11', height=>'10'}),'Admin down'),
	td({class=>'info Plain'},img({src=>"$C->{'<menu_url_base>'}/img/block_purple.png",border=>'0', width=>'11', height=>'10'}),'No collect'),
	$gr_menu
	));

	print end_form;

	if ($gr_menu ne '' and $Q->{group} eq '') { goto END_viewOverviewIntf; }

	print start_table;

	print Tr(td({class=>'info Plain',colspan=>'5'},'The information is updated daily'));

	foreach my $key ( sortall2($II,'node','ifDescr','fwd')) {
		next if $Q->{group} ne '' and $NT->{$II->{$key}{node}}{group} ne $Q->{group};
		next unless $AU->InGroup($NT->{$II->{$key}{node}}{group});
	if ($II->{$key}{node} ne $node) {
		print end_Tr if $node ne '';
		$node = $II->{$key}{node};
		$cnt = 0;
		print start_Tr,td({class=>'info Plain'},
		a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&node=$node"},$NT->{$node}{name}));
	}
	if ($II->{$key}{ifAdminStatus} ne 'up') {
		$icon = 'block_grey.png';
	} elsif ($II->{$key}{ifOperStatus} eq 'up') {
		$icon = ($II->{$key}{collect} eq 'true') ? 'arrow_up_green.png' : 'arrow_up_purple.png';
	} elsif ($II->{$key}{ifOperStatus} eq 'dormant') {
		$icon = ($II->{$key}{collect} eq 'true') ? 'arrow_up_yellow.png' : 'arrow_up_purple.png';
	} else {
		$icon = ($II->{$key}{collect} eq 'true') ? 'arrow_down_red.png' : 'block_purple.png';
	}
	if ($cnt++ >= 32) {
		print end_Tr,start_Tr,td({class=>'info Plain'},'&nbsp;');
		$cnt = 1;
	}
	$text = "name=$II->{$key}{ifDescr}<br>adminStatus=$II->{$key}{ifAdminStatus}<br>operStatus=$II->{$key}{ifOperStatus}<br>".
	"description=$II->{$key}{Description}<br>collect=$II->{$key}{collect}";
	print td({class=>'info Plain'},
	a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&node=$node&intf=$II->{$key}{ifIndex}&refresh=$Q->{refresh}&widget=$widget",
	},
	img({src=>"$C->{'<menu_url_base>'}/img/$icon",border=>'0', width=>'11', height=>'10'})));
	}
	print end_Tr if $node ne '';
	print end_table;
	
	END_viewOverviewIntf:
	pageEnd() if ($widget eq "false");
}


sub viewTop10 {

	print header($headeropts);
	pageStart(title => "Top 10", refresh => $Q->{refresh}) if ($widget eq "false");

	print '<!-- Top10 report start -->';

	my $NT = loadNodeTable();
	my $GT = loadGroupTable();
	my $S = Sys::->new;

	my $start = time()-(15*60);
	my $end = time();
	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	my $header = "Network Top10 from $datestamp_start to $datestamp_end";

	# Get each of the nodes info in a HASH for playing with
	my %reportTable;
	my %cpuTable;
	my %linkTable;

	foreach my $reportnode ( keys %{$NT} ) {
		next unless $AU->InGroup($NT->{$reportnode}{group});
		if ( $NT->{$reportnode}{active} eq 'true') {
			$S->init(name=>$reportnode,snmp=>'false');
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;
			# reachable, available, health, response
			%reportTable = (%reportTable,%{getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode)});
			# cpu only for routers, switch cpu and memory in practice not an indicator of performance.
			# avgBusy1min, avgBusy5min, ProcMemUsed, ProcMemFree, IOMemUsed, IOMemFree
			if ($NI->{graphtype}{nodehealth} =~ /cpu/ and $NI->{system}{collect} eq 'true') {
				%cpuTable = (%cpuTable,%{getSummaryStats(sys=>$S,type=>"nodehealth",start=>$start,end=>$end,index=>$reportnode)});
				print STDERR "Result: ". Dumper \%cpuTable;
			}

			foreach my $int (keys %{$IF} ) {
				if ( $IF->{$int}{collect} eq "true" ) {
					# availability, inputUtil, outputUtil, totalUtil
					my $intf = $IF->{$int}{ifIndex};
													
					# Availability, inputBits, outputBits
					my $hash = getSummaryStats(sys=>$S,type=>"interface",start=>$start,end=>$end,index=>$intf);
					foreach my $k (keys %{$hash->{$intf}}) {
						$linkTable{$int}{$k} = $hash->{$intf}{$k};
						$linkTable{$int}{$k} =~ s/NaN/0/ ;
						$linkTable{$int}{$k} ||= 0 ;
					}
					$linkTable{$int}{node} = $reportnode;
					$linkTable{$int}{intf} = $intf ;
					$linkTable{$int}{ifDescr} = $IF->{$int}{ifDescr} ;
					$linkTable{$int}{Description} = $IF->{$int}{Description} ;
					
					$linkTable{$int}{totalBits} = ($linkTable{$int}{inputBits} + $linkTable{$int}{outputBits} ) / 2 ;
				}
			}			
		} # end $reportnode loop
	}
	
	foreach my $k (keys %cpuTable) {
		foreach my $l (keys %{$cpuTable{$k}}) {
			$cpuTable{$k}{$l} =~ s/NaN/0/ ;
			$cpuTable{$k}{$l} ||= 0 ;
		}
	}
		
	my @out_resp;
	my @out_cpu;
	my $i;
	print start_table({class=>'dash'});
	#class=>'table'
	#print start_table({width=>'500px'});
	# header with time info
	print Tr(th({class=>'header lrg',align=>'center',colspan=>'4'},$header));
	
	print Tr(
		th({class=>'header lrg',align=>'center',colspan=>'2',width=>'50%'},'Average Response Time'),
		th({class=>'header lrg',align=>'center',colspan=>'2',width=>'50%'},'Nodes by CPU Load')
	);
	# header and data summary
	print Tr(
		td({class=>'header',align=>'center'},'Node'),
		td({class=>'header',align=>'center'},'Time (msec)'),
		td({class=>'header',align=>'center'},'Node'),
		td({class=>'header',align=>'center'},'Load')
	);

	$i=10;
	for my $reportnode ( sortall(\%reportTable,'response','rev')) {
		push @out_resp,
		td({class=>"info Plain $nodewrap"},
		a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$reportnode"},$reportnode)).
		td({class=>'info Plain',align=>'center'},$reportTable{$reportnode}{response});
		# loop control
		last if --$i == 0;
	}
	$i=10;
	for my $reportnode ( sortall(\%cpuTable,'avgBusy5min','rev')) {
		$cpuTable{$reportnode}{avgBusy5min} =~ /(^\d+)/;
		push @out_cpu,
		td({class=>"info Plain $nodewrap"},
		a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$reportnode"},$reportnode)).
		td({class=>'info Plain',align=>'center'},$cpuTable{$reportnode}{avgBusy5min});
		# loop control
		last if --$i == 0;
	}

	$i=10;
	my $empty = td({class=>'info Plain'},'&nbsp;');
	while ($i) {
		if (@out_resp or @out_cpu) {
			print start_Tr;
			if (@out_resp) { print shift @out_resp;} else { print $empty.$empty; }
			if (scalar @out_cpu) { print shift @out_cpu; } else { print $empty.$empty; }
			print end_Tr;
			$i--;
		} else {
			$i=0; # ready
		}
	}

	print Tr(th({class=>'title',align=>'center',colspan=>'4'},'Interfaces by Percent Utilization'));
	print Tr(
		td({class=>'header',align=>'center'},'Node'),
		td({class=>'header',align=>'center'},'Interface'),
		td({class=>'header',align=>'center'},'Receive'),
		td({class=>'header',align=>'center'},'Transmit')
	);

	$i=10;
	for my $reportlink ( sortall(\%linkTable,'totalUtil','rev')) {
		last if $linkTable{$reportlink}{inputUtil} and $linkTable{$reportlink}{outputUtil} == 0;
		my $reportnode = $linkTable{$reportlink}{node} ;
		my $intf = $linkTable{$reportlink}{intf} ;
		$linkTable{$reportlink}{inputUtil} =~ /(^\d+)/;
		my $input = $1;
		$linkTable{$reportlink}{outputUtil} =~ /(^\d+)/;
		my $output = $1;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$reportnode"},$reportnode)),
			td({class=>'info Plain'},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&node=$reportnode&intf=$intf&refresh=$Q->{refresh}&widget=$widget"},$linkTable{$reportlink}{ifDescr})),
			td({class=>'info Plain',align=>'right'},"$linkTable{$reportlink}{inputUtil} %"),
			td({class=>'info Plain',align=>'right'},"$linkTable{$reportlink}{outputUtil} %")
		);
		# loop control
		last if --$i == 0;
	}

# top10 table - Interfaces by Traffic
# inputBits, outputBits, totalBits

	print Tr(th({class=>'title',align=>'center',colspan=>'4'},'Interfaces by Traffic'));
	print Tr(
		td({class=>'header',align=>'center'},'Node'),
		td({class=>'header',align=>'center'},'Interface'),
		td({class=>'header',align=>'center'},'Receive'),
		td({class=>'header',align=>'center'},'Transmit')
	);

	$i=10;
	for my $reportlink ( sortall(\%linkTable,'totalBits','rev')) {
		last if $linkTable{$reportlink}{inputBits} and $linkTable{$reportlink}{outputBits} == 0;
		my $reportnode = $linkTable{$reportlink}{node} ;
		my $intf = $linkTable{$reportlink}{intf} ;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$reportnode"},$reportnode)),
			td({class=>'info Plain'},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&node=$reportnode&intf=$intf&refresh=$Q->{refresh}&widget=$widget"},$linkTable{$reportlink}{ifDescr})),
			td({class=>'info Plain',align=>'right'},getBits($linkTable{$reportlink}{inputBits})),
			td({class=>'info Plain',align=>'right'},getBits($linkTable{$reportlink}{outputBits}))
		);
		# loop control
		last if --$i == 0;
	}
	print end_table;
	print '<!-- Top10 report end -->';

	pageEnd() if ($widget eq "false");

}

# *****************************************************************************
# NMIS Copyright (C) 1999-2011 Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
