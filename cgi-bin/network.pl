#!/usr/bin/perl
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use NMIS;
use func;
use NMIS::Timing;
use URI::Escape;
use URI;
use URI::QueryParam;

use Data::Dumper;
$Data::Dumper::Indent = 1;

use CGI qw(:standard *table *Tr *td *form *Select *div);

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

my $widget = getbool($Q->{widget},"invert") ? 'false' : 'true';
$Q->{expand} = "true" if ($widget eq "true");

### unless told otherwise, and this is not JQuery call, widget is false!
if ( not defined $Q->{widget} and not defined $ENV{HTTP_X_REQUESTED_WITH} ) {
	$widget = "false";
}

if ( not defined $ENV{HTTP_X_REQUESTED_WITH} ) {
	$widget = "false";
}

my $wantwidget = ($widget eq "true");

### 2013-11-23 keiths adding some timing debug
my $t = NMIS::Timing->new();
my $timing = 0;
$timing = 1 if getbool($Q->{timing});

if ( $Q->{refresh} eq "" and $wantwidget ) {
	$Q->{refresh} = $C->{widget_refresh_time};
}
elsif ( $Q->{refresh} eq "" and !$wantwidget ) {
	$Q->{refresh} = $C->{page_refresh_time};
}

my $nodewrap = "nowrap";
$nodewrap = "wrap" if getbool($C->{'wrap_node_names'});

my $smallGraphHeight = 50;
my $smallGraphWidth = 400;

$smallGraphHeight = $C->{'small_graph_height'} if $C->{'small_graph_height'} ne "";
$smallGraphWidth = $C->{'small_graph_width'} if $C->{'small_graph_width'} ne "";

logMsg("TIMING: ".$t->elapTime()." Begin act=$Q->{act}") if $timing;

# select function
my $select;

if ($Q->{act} eq 'network_summary_health') {	$select = 'health';
} elsif ($Q->{act} eq 'network_summary_view') {	$select = 'view';
} elsif ($Q->{act} eq 'network_summary_small') {	$select = 'small';
} elsif ($Q->{act} eq 'network_summary_large') {	$select = 'large';
} elsif ($Q->{act} eq 'network_summary_allgroups') {	$select = 'allgroups';
} elsif ($Q->{act} eq 'network_summary_group') {	$select = 'group';
} elsif ($Q->{act} eq 'network_summary_customer') {	$select = 'customer';
} elsif ($Q->{act} eq 'network_summary_business') {	$select = 'business';
} elsif ($Q->{act} eq 'network_summary_metrics') {	$select = 'metrics';
} elsif ($Q->{act} eq 'node_admin_summary') {	nodeAdminSummary(); exit;
} elsif ($Q->{act} eq 'network_metrics_graph') {	viewMetrics(); exit;
} elsif ($Q->{act} eq 'network_top10_view') {	viewTop10(); exit;
} elsif ($Q->{act} eq 'network_node_view') {	viewNode(); exit;
} elsif ($Q->{act} eq 'network_storage_view') {	viewStorage(); exit;
} elsif ($Q->{act} eq 'network_service_view') {	viewService(); exit;
} elsif ($Q->{act} eq 'network_service_list') {	viewServiceList(); exit;
} elsif ($Q->{act} eq 'network_cpu_list') {	viewCpuList(); exit;
} elsif ($Q->{act} eq 'network_status_view') {	viewStatus(); exit;
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
} elsif ($Q->{act} eq "nmis_selftest_view") { viewSelfTest(); exit;
} elsif ($Q->{act} eq "nmis_selftest_reset") { clearSelfTest(); exit;
} else {
	$select = 'health';
	#notfound(); exit
}

sub notfound {
	print header($headeropts);
	print "Network: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf} <br>\n";
	print "Request not found\n";
}

logMsg("TIMING: ".$t->elapTime()." Select Subs") if $timing;

# option to generate html to file
if (getbool($Q->{http})) {
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

pageStartJscript(title => "NMIS Network Status - $C->{server_name}", refresh => $Q->{refresh})
		if (!$wantwidget);

logMsg("TIMING: ".$t->elapTime()." Load Nodes and Groups") if $timing;

my $NT = loadNodeTable();
my $GT = loadGroupTable();

# graph request
my $ntwrk = ($select eq 'large') ? 'network' : ($Q->{group} eq '') ? 'network' : $Q->{group} ;

my $overallStatus;
my $overallColor;
my %icon;
my $group = $Q->{group};
my $customer = $Q->{customer};
my $business = $Q->{business};
my @groups = grep { $AU->InGroup($_) } sort keys %{$GT};

### 2014-08-28 keiths, configurable metric periods
	#my $graphtype = ($Q->{graphtype} eq '') ? $C->{default_graphtype} : $Q->{graphtype};

my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

# define global stats, and default stats period.
my $groupSummary;
my $oldGroupSummary;
my $start = $metricsSecondPeriod;
my $end = $metricsFirstPeriod;

#===============================
# All global hash, metrics, icons, etc, are now populated
# Call each of the base  network display subs.
#======================================

logMsg("TIMING: ".$t->elapTime()." typeSummary") if $timing;

print "<!-- typeSummary select=$select start -->\n";

if ( $select eq 'metrics' ) { selectMetrics(); }
elsif ( $select eq 'health' ) { selectNetworkHealth(); }
elsif ( $select eq 'view' ) { selectNetworkView(); }
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

pageEnd() if (!$wantwidget);

logMsg("TIMING: ".$t->elapTime()." END $Q->{act}") if $timing;

exit();
 # end main()

sub getSummaryStatsbyGroup {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};

	logMsg("TIMING: ".$t->elapTime()." getSummaryStatsbyGroup begin: $group$customer$business") if $timing;

	my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

	$groupSummary = getGroupSummary(group => $group, customer => $customer, business => $business, start => $metricsFirstPeriod, end => "now");
	$oldGroupSummary = getGroupSummary(group => $group, customer => $customer, business => $business, start => $metricsSecondPeriod, end => $metricsFirstPeriod);

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

	my $percentDegraded = 0;
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$percentDegraded = sprintf("%2.0u",$groupSummary->{average}{countdegraded}/$groupSummary->{average}{counttotal}) * 100;
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

sub selectMetrics
{
	my $showmetrics = 1;

	# first check if we can/should show the selftest result
	if ($AU->CheckAccess("tls_nmis_runtime","check"))
	{
		# allowed to, but do we have a problem to show?
		# this widget is overridden for selftest alerting, iff the last nmis selftest was unsuccessful
		my $cachefile = func::getFileName(file => $C->{'<nmis_var>'}."/nmis_system/selftest",
																			json => 'true');
		if (-f $cachefile)
		{
			my $selfteststatus = readFiletoHash(file => $cachefile, json => 'true');
			if (!$selfteststatus->{status})
			{
				$showmetrics=0;

				print "<h3>NMIS Selftest failed!</h3>",
				"<small>(Click on the links below for details.)</small>",
				start_table({width => "100%"});
				for my $test (@{$selfteststatus->{tests}})
				{
					my ($name,$message) = @$test;
					next if (!defined $message); # skip the successful ones and only print the message here
					# but not too much of the message...
					$message = (substr($message,0,64)."&nbsp;&hellip;") if (length($message) > 64);
					print Tr(td({class => "info Error"},
											a({ href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=nmis_selftest_view",
													id => "nmis_selftest",
													class => "black" },
												$message)));
				}
				print Tr(td({class => "info Major"},
										a({ href => url(-absolute=>1)."?conf=$Q->{conf}&act=nmis_selftest_reset&widget=$widget"  },
											"Reset Selftest Status")));
				print end_table;
			}
		}
	}

	# no errors or not allowed to show them, so continue normally
	if ($showmetrics)
	{
		if ($AU->InGroup("network") or $AU->InGroup($group))
		{
			# get all the stats and stuff the hashs
			getSummaryStatsbyGroup(group => $group);

			my @h = qw/Metric Reachablility InterfaceAvail Health ResponseTime/;
			my @k = qw/metric reachable available health response/;
			my @item = qw/status reachability intfAvail health responsetime/;
			my $time = time;
			my $cp;

			print start_table({class=>"noborder", width => "100%"}),
			Tr(th({class=>"subtitle"},"8Hr Summary"));

			foreach my $t (0..4)
			{
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
													 )))));
			}	#foreach
			print	end_table;
		}
		else 												# not authed
		{
			print start_table({class=>"dash", width => "100%"}),
					Tr(th({class=>"subtitle"},"You are not authorized for this request")), end_table;
		}
	}
}


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

	my @h=qw(Group);
	my $healthTitle = "All Groups Status";
	my $healthType = "group";

	if ( $type eq "customer" and tableExists('Customers') ) {
		@h=qw(Customer);
		$healthTitle = "All Nodes Status";
		$healthType = "customer";
	}
	elsif ( $type eq "business" and tableExists('BusinessServices') ) {
		@h=qw(Business);
		$healthTitle = "All Nodes Status";
		$healthType = "business";
	}
	elsif ( $C->{network_health_view} eq "Customer" and tableExists('Customers') ) {
		@h=qw(Customer);
		$healthTitle = "All Nodes Status";
		$healthType = "customer";
	}
	elsif ( $C->{network_health_view} eq "Business" and tableExists('BusinessServices') ) {
		@h=qw(Business);
		$healthTitle = "All Nodes Status";
		$healthType = "business";
	}

	if ( exists $C->{display_status_summary}
			and getbool($C->{display_status_summary})
	) {
		push(@h,qw(Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime));
	}
	else {
		push(@h,qw(Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime));
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
		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
			$classDegraded = "Error";
		}

		print
		start_Tr,
		td(
			{class=>'infolft Plain'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_allgroups"},$healthTitle),
		),
		td({class=>"info $overallStatus"},"$overallStatus"),
		td({class=>'info Plain'},"$groupSummary->{average}{counttotal}");
		print td({class=>'info Plain'},"$groupSummary->{average}{countup}") if ( not getbool($C->{display_status_summary}));
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown}");
		print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded}") if ( getbool($C->{display_status_summary}));

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

###
### No one seems to use this anymore.......
###
sub selectSmall {

	my @h=qw/Group Status NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	@h=qw(Group Status NodeDn NodeDeg Metric Reach IntfAvail Health RespTime) if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

	print
	start_table( {class=>"dash" }),
	Tr(th({class=>"title",colspan=>'10'},"Current Network Status")),
	# Use a subtitle when using multiple servers
	#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
	Tr(th({class=>"header"},\@h));

	if ($AU->InGroup("network") and $group eq ''){
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);

		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
			$classDegraded = "Error";
		}

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
		td({class=>"info $overallStatus"},"$overallStatus");
		#td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
		print td({class=>'info Plain'},"$groupSummary->{average}{countup} of $groupSummary->{average}{counttotal}") if ( exists $C->{display_status_summary} and not getbool($C->{display_status_summary}));
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}");
		print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}") if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

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

	@h=qw(Group Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime) if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

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
###
### No one seems to use this anymore.......
###
sub selectGroup {

	my $group = shift;

	# should we write a msg that this user is not authorised to this group ?
	return unless $AU->InGroup($group);

	my @h=qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	@h=qw(Group Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime) if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

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

	my $idsafegroup = $group;
	$idsafegroup =~ s/ /_/g;		# spaces aren't allowed in id attributes!

	my $urlsafegroup = uri_escape($group);

	if ($AU->InGroup($group)) {
	# force a new window if clicked
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_group&refresh=$Q->{refresh}&widget=$widget&group=$urlsafegroup", id=>"network_summary_$idsafegroup"},"$group");
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
	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$classDegraded = "Error";
	}

	print
	td({class=>"info $overallStatus"},$overallStatus),
	td({class=>'info Plain'},"$groupSummary->{average}{counttotal}");
	print td({class=>'info Plain'},"$groupSummary->{average}{countup}") if ( not getbool($C->{display_status_summary}));
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown}");
	print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded}") if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

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

#============================
# Desc: network status summarised to one line, with all groups summarised underneath
# Menu: Small Network Status and Health
# url: network_summary_view -> select=view
# Title: Current Network Status
# subtitle: All Groups Status
#============================
sub selectNetworkView {
	my %args = @_;
	my $type = $args{type};
	my $customer = $args{customer};
	my $business = $args{business};

	my @h = (exists $C->{display_status_summary} and getbool($C->{display_status_summary})?
					 (qw(Group NodeDn NodeDeg Metric Reach Health))
					 : (qw(Group NodeDn Metric Reach Health)));

	my $healthTitle = "All Groups Status";
	my $healthType = "group";

	logMsg("TIMING: ".$t->elapTime()." selectNetworkView healthTitle=$healthTitle healthType=$healthType") if $timing;

	my $graphGroup = $group || 'network';
	my $colspan = @h;

	print
			start_table( {class=>"noborder" }),

			Tr(td({class=>'image',colspan=>$colspan},htmlGraph(graphtype=>"metrics", group=>"$graphGroup", node=>"", intf=>"", width=>"600", height=>"75") )),

			start_Tr;

	print th({class=>"header",title=>"A group of nodes, and the status"},"Group");
	print th({class=>"header",title=>"Number of nodes down in the group"},"Nodes Down");
	print th({class=>"header",title=>"Number of nodes down in the group"},"Nodes Degraded")
			if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));
	print th({class=>"header",title=>"A single metric for the group of nodes"},"Metric");
	print th({class=>"header",title=>"Group reachability (pingability) of the nodes"},"Reachability");
	print th({class=>"header",title=>"The health of the group"},"Health");

	print end_Tr;

	# no group selected? then produce the overall statistics
	if ($AU->InGroup("network") and $group eq '')
	{
		getSummaryStatsbyGroup(group => undef); # fixme can that be removed or simplified or something?

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$percentDown = int( ($groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
			$classDegraded = "Error";
		}

		print
				start_Tr,
				td(
					{class=>"infolft $overallStatus"},
					a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_allgroups"},$healthTitle),
				);
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}");
		print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}") if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

		my @h = qw/metric reachable health/;
		foreach my $t (@h)
		{
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

	# now compute and print the stats for as many groups as allowed
	my $cutoff = getbool($Q->{unlimited})? undef
			: $C->{network_summary_maxgroups} || 30;
	my @allowed = sort(grep($AU->InGroup($_), keys %{$GT}));

	my $havetoomany = ($C->{network_summary_maxgroups} || 30) < @allowed;
	splice(@allowed, $cutoff) if (defined($cutoff) && $cutoff < @allowed);
	foreach $group (@allowed)
	{
		# fixme: the walk should be done JUST ONCE, not N times for N groups!
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup(group => $group);
		printGroupView($group);
	}
	if ($havetoomany)
	{
		my ($otherstate,$msg) = getbool($Q->{unlimited})? ("false","to hide extra groups"):("true","for a full view");

		$q->param(-name => "unlimited", -value => $otherstate);
		# url with -query doesn't include newly set params :-(
		my %fullparams = $q->Vars;
		print "<tr><td class='info Minor' colspan='$colspan'>Too many groups! <a href='"
				. url(-absolute=>1)."?".join("&",map { uri_escape($_)."=".uri_escape($fullparams{$_}) }(keys %fullparams))
				. "'>Click here</a> $msg.</td></tr>";
	}
	print end_table;

}

sub printGroupView
{
	my $group = shift;
	my $icon;

	my $idsafegroup = $group;
	$idsafegroup =~ s/ /_/g;		# spaces aren't allowed in id attributes!

	my $urlsafegroup = uri_escape($group);

	print
	start_Tr,
	start_td({class=>"infolft $overallStatus"});

	if ($AU->InGroup($group)) {
	# force a new window if clicked
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_group&refresh=$Q->{refresh}&widget=$widget&group=$urlsafegroup", id=>"network_summary_$idsafegroup"},"$group");
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
	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$classDegraded = "Error";
	}

	#td({class=>"info $overallStatus"},$overallStatus),
	#td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
	#td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}");
	print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}")  if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

	#my @h = qw/metric reachable available health response/;
	my @h = qw/metric reachable health/;
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

	my $idsafecustomer = $customer;
	$idsafecustomer =~ s/ /_/g;		# spaces aren't allowed in id attributes!
	my $idsafebusiness = $business;
	$idsafebusiness =~ s/ /_/g;		# spaces aren't allowed in id attributes!

	my $icon;

	print
	start_Tr,
	start_td({class=>'infolft Plain'});



	#if ($AU->InGroup($group)) {
	# force a new window if clicked
	if ( $customer ne "" ) {
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_customer&refresh=$Q->{refresh}&widget=$widget&customer=$customer", id=>"network_summary_$idsafecustomer"},"$customer");
	}
	elsif ( $business ne "" ) {
		print a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_summary_business&refresh=$Q->{refresh}&widget=$widget&business=$business", id=>"network_summary_$idsafebusiness"},"$business");
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

	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 ) {
		$classDegraded = "Error";
	}

	print
	td({class=>"info $overallStatus"},$overallStatus),
	td({class=>'info Plain'},"$groupSummary->{average}{counttotal}");
	print td({class=>'info Plain'},"$groupSummary->{average}{countup}") if ( not getbool($C->{display_status_summary}));
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td({class=>"info $overallStatus"},"$groupSummary->{average}{countdown}");
	print td({class=>"info $classDegraded"},"$groupSummary->{average}{countdegraded}") if ( exists $C->{display_status_summary} and getbool($C->{display_status_summary}));

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
	if (getbool($C->{server_master})) {
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

	foreach my $group (sort keys %{$GT} )
	{
		# test if caller wanted stats for a particular group
		if ( $select eq "customer" ) {
			next if $CT->{$customer}{groups} !~ /$group/;
		}
		elsif ( $select eq "group" ) {
			next if $group ne $Q->{group};
		}

		++$groupcount;

		my $urlsafegroup = uri_escape($group);

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
			next unless getbool($NT->{$node}{active}); # optional skip

			if ( $printGroupHeader ) {
				$printGroupHeader = 0;
				print Tr(th({class=>'title',colspan=>'15'},
					"$group Node List and Status",
					a({style=>"color:white;",href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=exceptions"},"Node Admin Exceptions")

					));
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
			if ( getbool($NT->{$node}{active}) ) {
				if ( !getbool($NT->{$node}{ping})
						 and !getbool($NT->{$node}{collect}) ) {
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
			my $lastUpdateClass = "info Plain nowrap";
			my $time = $groupSummary->{$node}{lastUpdateSec};
			if ( $time ne "") {
				$lastUpdate = returnDateStamp($time);
				if ($time < (time - 60*15)) {
					$colorlast = "#ffcc00"; # to late
					$lastUpdateClass = "info Plain Error nowrap";
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
			if ( getbool($groupSummary->{$node}{ping}) ) {
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
				# attention: this construction must match up with what commonv8.js's nodeInfoPanel() uses as id attrib!
				my $idsafenode = $node;
				$idsafenode = (split(/\./,$idsafenode))[0];
				$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;

				$nodelink = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node), id=>"node_view_$idsafenode"},$NT->{$node}{name});
			}
			else {
				my $server = $NT->{$node}{server};
				my $url = "$ST->{$server}{portal_protocol}://$ST->{$server}{portal_host}:$ST->{$server}{portal_port}$ST->{$server}{cgi_url_base}/network.pl?conf=$Q->{conf}&act=network_node_view&refresh=$Q->{refresh}&widget=false&node=".
						uri_escape($node);
				$nodelink = a({target=>"Graph-$node", onclick=>"viewwndw(\'$node\',\'$url\',$C->{win_width},$C->{win_height} * 1.5)"},$NT->{$node}{name},img({src=>"$C->{'nmis_slave'}",alt=>"NMIS Server $server"})) ;
			}

			my $statusClass = $groupSummary->{$node}{event_status};
			my $statusValue = $groupSummary->{$node}{event_status};
			if ( exists $C->{display_status_summary}
					and getbool($C->{display_status_summary})
					and exists $groupSummary->{$node}{nodestatus}
					and $groupSummary->{$node}{nodestatus}
			) {
				$statusValue = $groupSummary->{$node}{nodestatus};
				if ( $groupSummary->{$node}{nodestatus} eq "degraded" ) {
					$statusClass = "Error";
				}
			}

			print Tr(
				td({class=>"infolft Plain $nodewrap"},$nodelink),
				td({class=>'info Plain'},$groupSummary->{$node}{sysLocation}),
				td({class=>'info Plain'},$groupSummary->{$node}{nodeType}),
				td({class=>'info Plain'},$groupSummary->{$node}{netType}),
				td({class=>'info Plain'},$groupSummary->{$node}{roleType}),
				td({class=>"info $statusClass"},$statusValue),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'health-bg'}},img({src=>$C->{$groupSummary->{$node}{'health-icon'}}}),$groupSummary->{$node}{health},"%"),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'reachable-bg'}},img({src=>$C->{$groupSummary->{$node}{'reachable-icon'}}}),$groupSummary->{$node}{reachable},"%"),
				td({class=>'info Plain',style=>$groupSummary->{$node}{'available-bg'}},img({src=>$C->{$groupSummary->{$node}{'available-icon'}}}),$groupSummary->{$node}{available},"%"),
				$responsetime,
				$outage,
				td({class=>'info Plain'},$escalate),
				td({class=>$lastUpdateClass},"$lastUpdate")
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
	if ($AU->CheckAccess("tls_nmis_runtime","header"))
	{
		print header($headeropts);
		pageStartJscript(title => "NMIS Run Time - $C->{server_name}") if (!$wantwidget);
		print start_table({class=>'dash'});
		print Tr(th({class=>'title'},"NMIS Runtime Graph"));
		print Tr(td({class=>'image'},htmlGraph(graphtype=>"nmis", node=>"", intf=>"", width=>"600", height=>"150") ));
		print end_table;
	}
} # viewRunTime

### 2012-01-11 keiths, adding some polling information
sub viewPollingSummary {

	# $AU->CheckAccess, will send header and display message denying access if fails.
	# using the same auth type as the nmis runtime graph
	if ($AU->CheckAccess("tls_nmis_runtime","header"))
	{
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

				my @cbqosdb = qw(cbqos-in cbqos-out);
				foreach my $cbqos (@cbqosdb)
				{
					my @instances = $S->getTypeInstances(graphtype => $cbqos);
					if (@instances)
					{
						++$sum->{count}{$cbqos};
						foreach my $idx (@instances)
						{
							++$qossum->{$cbqos}{interface};
							# node info has cbqos -> {<ifindex>} -> {"in" or "out"}->{"ClassMap"}-> ... class details,
							# and we want to count those classes
							my $direction = ($cbqos eq "cbqos-in"? 'in' : 'out');
							my $count;

							$count = scalar keys %{$NI->{cbqos}->{$idx}->{$direction}->{ClassMap}}
							if (exists $NI->{cbqos}->{$idx}->{$direction}
									&& ref($NI->{cbqos}->{$idx}->{$direction}->{ClassMap}) eq "HASH");

							$qossum->{$cbqos}{classes} += $count;
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
		pageStartJscript(title => "NMIS Polling Summary - $C->{server_name}") if (!$wantwidget);
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
	}

} # viewPollingSummary


# remove the selftest cache file, then refresh the whole nmis gui
# without that refresh, the js code picks up the wrong uri for the widget and
# every automatic refresh silently reruns the clear selftest :-/
sub clearSelfTest
{
	unlink($C->{'<nmis_var>'}."/nmis_system/selftest.json");

	if ($wantwidget)
	{
		print header($headeropts),
		qq|<script type="text/javascript">window.location='$C->{nmis}?conf=$Q->{conf}';</script>|;
	}
	else
	{
		# in non-widgetted mode a redirect is good enough
		print $q->redirect(url(-absolute => 1)."?conf=$Q->{conf}&act=network_summary_metrics");
	}
}

# show the full nmis self test
sub viewSelfTest
{
	# $AU->CheckAccess, will send header and display message denying access if fails.
	# using the same auth type as the nmis runtime graph
	if ($AU->CheckAccess("tls_nmis_runtime","header"))
	{
		my $cachefile = func::getFileName(file => $C->{'<nmis_var>'}."/nmis_system/selftest",
																			json => 'true');
		if (-f $cachefile)
		{
			my $selfteststatus = readFiletoHash(file => $cachefile, json => 'true');

			print header($headeropts);
			pageStartJscript(title => "NMIS Selftest - $C->{server_name}") if (!$wantwidget);
			print start_table({class=>'dash'}),
			Tr(th({class=>'title',colspan=>'2'},"NMIS Selftest")),
			Tr(td({class=>"heading3"}, "Last Selftest"), td({class=>"rht Plain"},
																										returnDateStamp($selfteststatus->{lastupdate})));
			my $anytrouble;
			for my $test (@{$selfteststatus->{tests}})
			{
				my ($name,$message) = @$test;
				print Tr(td({class => "heading3"}, $name),
								 td({class => "rht ".($message? "Critical":"Normal")}, $message || "OK"));
				$anytrouble = 1 if ($message);
			}
			if ($anytrouble)
			{
				print Tr(td({class => "info Major", colspan => 2},
										a({ href => url(-absolute=>1)."?conf=$Q->{conf}&act=nmis_selftest_reset&widget=$widget"  },
											"Reset Selftest Status")));
			}
			print end_table;
		}
	}
}

sub viewMetrics {

	my $group = $Q->{group};
	if ($group eq "") {
		$group = "network";
	}

	print header($headeropts);
	pageStartJscript(title => "$group - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

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
	if ( !$wantwidget ) {
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

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists

	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $time = time;

	# don't print the not authorized msg if somebody has renamed the node
	if (!$NT->{$node})
	{
		print "The requested node does not exist.";
		return;
	}
	if (!$AU->InGroup($NT->{$node}{group})) {
		print "You are not authorized for this request! (group=$NT->{$node}{group})";
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	$S->readNodeView();
	my $V = $S->view;

	### 2012-01-05 keiths, check if node is managed by slave server
	if ( $NT->{$node}{server} ne $C->{server_name} ) {
		my $ST = loadServersTable();
		my $wd = 850;
		my $ht = 700;

		my $server = $NT->{$node}{server};
		my $url = "$ST->{$server}{portal_protocol}://$ST->{$server}{portal_host}:$ST->{$server}{portal_port}$ST->{$server}{cgi_url_base}/network.pl?conf=$ST->{$server}{config}&act=network_node_view&refresh=$C->{page_refresh_time}&widget=false&node=".uri_escape($node);
		my $nodelink = a({target=>"NodeDetails-$node", onclick=>"viewwndw(\'$node\',\'$url\',$wd,$ht)"},$NT->{$node}{name});
		print "$nodelink is managed by server $NT->{$node}{server}";
		print <<EO_HTML;
	<script>
		viewwndw('$node','$url',$wd,$ht);
	</script>
EO_HTML
  	return;
	}

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
		# ok, an update hasn't run, so its not in the view, just push it in!
		if ( not grep { $_ eq $i } @items ) {
			push @items,$i;
		}
	}
	@items = (@items,@keys);

	# print STDERR "order=@order items=@items\n";

	### 2013-03-13 Keiths, adding an edit node button.
	my $editnode;
	if ( $AU->CheckAccessCmd("Table_Nodes_rw") ) {
		my $url = "$C->{'<cgi_url_base>'}/tables.pl?conf=$Q->{conf}&act=config_table_edit&table=Nodes&widget=$widget&key=".uri_escape($node);
		$editnode = qq| <a href="$url" id="cfg_nodes" style="color:white;">Edit Node</a>|;
	}

	my $editconf;
	if ( $AU->CheckAccessCmd("table_nodeconf_view") ) {
		my $url = "$C->{'<cgi_url_base>'}/nodeconf.pl?conf=$Q->{conf}&act=config_nodeconf_view&widget=$widget&node=".
				uri_escape($node);
		$editconf = qq| <a href="$url" id="cfg_nodecfg" style="color:white;">Node Configuration</a>|;
	}
	#http://nmisdev64.dev.opmantek.com/cgi-nmis8/nodeconf.pl?conf=Config.xxxx&act=

	my $remote;
	if ( defined $NT->{$node}{remote_connection_name} and $NT->{$node}{remote_connection_name} ne "" ) {
		my $url = $NT->{$node}{remote_connection_url} if $NT->{$node}{remote_connection_url};
		# substitute any known parameters
		$url =~ s/\$host/$NT->{$node}{host}/g;
		$url =~ s/\$name/$NT->{$node}{name}/g;
		$url =~ s/\$node/$NT->{$node}{name}/g;

		$remote = qq| <a href="$url" target="remote_$node" style="color:white;">$NT->{$node}{remote_connection_name}</a>|;
	}

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table({class=>'dash'});

	my $nodeDetails = ("Node Details - $node");
	$nodeDetails .= " - $editnode" if $editnode;
	$nodeDetails .= " - $editconf" if $editconf;
	$nodeDetails .= " - $remote" if $remote;

	print Tr(th({class=>'title', colspan=>'2'},$nodeDetails));
	print start_Tr;
	# first column
	print td({valign=>'top'},table({class=>'dash'},
	# list of values
		eval {
			my @out;
			foreach my $k (@items){
				# the default title is the key name.
				# but can I get a better title?
				my $title = ( defined($V->{system}->{"${k}_title"}) ?
											$V->{system}{"${k}_title"}
											: $S->getTitle(attr=>$k,section=>'system')) ||  $k;

				# print STDERR "DEBUG: k=$k, title=$title\n";

				if ($title ne '') {
					my $color = $V->{system}{"${k}_color"} || '#FFF';
					my $gurl = $V->{system}{"${k}_gurl"}; # create new window

					# existing window, possibly widgeted or not
					# but that's unknown when nmis.pl creates the view entry!
					my $url;
					if ($V->{system}{"${k}_url"})
					{
						my $u = URI->new($V->{system}{"${k}_url"});
						$u->query_param("widget" => ($wantwidget? "true": "false"));
						$url = $u->as_string;
					}

					my $value;
					# get the value from the view if it one of the special ones, or only present there
					if (
						$k =~ /^(host_addr|lastUpdate|configurationState|configLastChanged|configLastSaved|bootConfigLastChanged)$/
						or not exists($NI->{system}{$k})
					) {
						$value = $V->{system}{"${k}_value"};
					}
					else {
						$value = $NI->{system}{$k};
					}

					# escape the input if there's anything in need of escaping;
					# we don't want doubly-escaped uglies.
					$value = escapeHTML($value) if ($value =~ /[<>]/);

					$color = colorPercentHi(100) if $V->{system}{"${k}_value"} eq "running";
					$color = colorPercentHi(0) if $color eq "red";

					if ($k eq 'status')
					{
						if ( !$status{overall} )
						{
							$value = "unreachable";
							$color = "#F00";
						}
						elsif ( $status{overall} == -1 )
						{
							$value = "degraded";
							$color = "#FF0";
						}
						else {
							$value = "reachable";
							$color = "#0F0";
						}
					}

					if ($k eq 'lastUpdate') {
						# check lastupdate
						my $time = $NI->{system}{lastUpdateSec};
						if ( $time ne "" ) {
							if ($time < (time - 60*15)) {
								$color = "#ffcc00"; # to late
							}
						}
					}

					if ($k eq 'TimeSinceTopologyChange' and $NI->{system}{TimeSinceTopologyChange} =~ /\d+/ ) {
						if ( $value ne "N/A" ) {
							# convert to uptime format, time since change
							$value = convUpTime($NI->{system}{TimeSinceTopologyChange}/100);
							# did this reset in the last 1 h
							if ( $NI->{system}{TimeSinceTopologyChange} / 100 < 360000 ) {
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
					$printData = 0 if $k eq "serviceStatus" and not tableExists('ServiceStatus');
					$printData = 0 if $k eq "location" and not tableExists('Locations');

					if ( $printData ) {
						push @out,Tr(td({class=>'info Plain'}, escapeHTML($title)),
						td({class=>'info Plain',style=>getBGColor($color)},$content));
					}
				}
			}
			# display events for this one node - also close one if asked to
			if (my %nodeevents = loadAllEvents(node => $node))
			{
				push @out,Tr(td({class=>'header',colspan=>'2'},'Events'));
				my $usermayclose = $AU->CheckAccess("src_events","check");

				my $closemeurl = url(-absolute=>1)."?conf=$Q->{conf}&amp;act=network_node_view"
						."&amp;widget=$widget"
						."&amp;node=".uri_escape($node);

				for my $eventkey (sort keys %nodeevents)
				{
					my $thisevent = $nodeevents{$eventkey};
					# closing an event creates a temporary up event...we don't want to see that.
					next if ($usermayclose && $thisevent->{details} =~ /^closed from GUI/);

					# is this the event to close? same node, same name, element the same
					if ($usermayclose && $Q->{closeevent} eq $thisevent->{event}
							&& $Q->{closeelement} eq $thisevent->{element})
					{
						checkEvent(sys => $S, node => $node,
											 event => $thisevent->{event},
											 element => $thisevent->{element},
											 details => "closed from GUI");
						next;								# event is gone, don't show it
					}

					# offer a button for closing this event if the user is sufficiently privileged
					# fixme: does currently NOT offer confirmation!
					my @ecolumn = "Event";
					if ($usermayclose)
					{
						my $closethisurl = $closemeurl
								. "&amp;closeevent=".uri_escape($thisevent->{event})
								. "&amp;closeelement=".uri_escape($thisevent->{element});

						push @ecolumn, qq|<a href='$closethisurl' title="Close this Event"><img src="$C->{'<menu_url_base>'}/img/v8/icons/note_delete.gif"></a>|;
					}

					my $state = getbool($thisevent->{ack},"invert") ? 'active' : 'inactive';
					my $details = $thisevent->{details};
					$details = "$thisevent->{element} $details" if ($thisevent->{event} =~ /^Proactive|^Alert/) ;
					$details = $thisevent->{element} if (!$details);
					push @out,Tr(td({class=>'info Plain'}, join("",@ecolumn)),
											 td({class=>'info Plain'},
													"$thisevent->{event} - $details, Escalate $thisevent->{escalate}, $state"));
				}
			}

			return @out;
		},
	));

	# second column
	print start_td({valign=>'top'}),start_table;

	#Adding KPI Analysis
	my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";
	my $validKpiData = 0;

	if (my $stats = getSummaryStats(sys=>$S,type=>"health",start=>$metricsFirstPeriod,end=>time(),index=>$node)) {

		if ( $stats->{$node}{reachabilityHealth} and $stats->{$node}{availabilityHealth} ) {
			# now get previous period stats
			my $reachabilityMax = 100 * $C->{weight_reachability};
			my $availabilityMax = 100 * $C->{weight_availability};
			my $responseMax = 100 * $C->{weight_response};
			my $cpuMax = 100 * $C->{weight_cpu};
			my $memMax = 100 * $C->{weight_mem};
			my $intMax = 100 * $C->{weight_int};
			my $swapMax = 0;
			my $diskMax = 0;

			$stats->{$node}{reachabilityHealth} =~ s/\.00//g;
			$stats->{$node}{availabilityHealth} =~ s/\.00//g;
			$stats->{$node}{responseHealth} =~ s/\.00//g;
			$stats->{$node}{cpuHealth} =~ s/\.00//g;
			$stats->{$node}{memHealth} =~ s/\.00//g;
			$stats->{$node}{intHealth} =~ s/\.00//g;

			my $swapCell = "";
			my $diskCell = "";

			# get some arrows for the metrics
			my $reachabilityIcon;
			my $availabilityIcon;
			my $responseIcon;
			my $cpuIcon;
			my $memIcon;
			my $intIcon;
			my $diskIcon;
			my $swapIcon;

			my $statsPrev = getSummaryStats(sys=>$S,type=>"health",start=>$metricsSecondPeriod,end=>$metricsFirstPeriod,index=>$node);
			if ( $statsPrev->{$node}{reachabilityHealth} !~ /NaN/ and $statsPrev->{$node}{reachabilityHealth} > 0) {
				$reachabilityIcon = $stats->{$node}{reachabilityHealth} >= $statsPrev->{$node}{reachabilityHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$availabilityIcon = $stats->{$node}{availabilityHealth} >= $statsPrev->{$node}{availabilityHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$responseIcon = $stats->{$node}{responseHealth} >= $statsPrev->{$node}{responseHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$cpuIcon = $stats->{$node}{cpuHealth} >= $statsPrev->{$node}{cpuHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$memIcon = $stats->{$node}{memHealth} >= $statsPrev->{$node}{memHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$intIcon = $stats->{$node}{intHealth} >= $statsPrev->{$node}{intHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$diskIcon = $stats->{$node}{diskHealth} >= $statsPrev->{$node}{diskHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$swapIcon = $stats->{$node}{swapHealth} >= $statsPrev->{$node}{swapHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
			}

			if ( $stats->{$node}{diskHealth} > 0 ) {
				$stats->{$node}{diskHealth} =~ s/\.00//g;
				$intMax = 100 * $C->{weight_int} / 2;
				$diskMax = 100 * $C->{weight_int} / 2;
				$diskCell = td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{diskHealth}/$diskMax * 100)),title=>"The Disk KPI measures how much disk space is in use."},"Disk ",img({src=>"$C->{'<menu_url_base>'}/img/$diskIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{diskHealth}/$diskMax");
			}

			if ( $stats->{$node}{swapHealth} > 0 ) {
				$stats->{$node}{swapHealth} =~ s/\.00//g;
				$memMax = 100 * $C->{weight_mem} / 2;
				$swapMax = 100 * $C->{weight_mem} / 2;
				$swapCell = td({class=>"info",style=>getBGColor(colorPercentHi($stats->{$node}{swapHealth}/$swapMax * 100)),title=>"The Swap KPI increases with the Swap space in use."},"SWAP ",img({src=>"$C->{'<menu_url_base>'}/img/$swapIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{swapHealth}/$swapMax");
			}

			# only print the table if there is a value over 0 for reachability.
			if ( $stats->{$node}{reachabilityHealth} and $stats->{$node}{reachabilityHealth} !~ /NaN/ ) {
				$validKpiData = 1;
				print start_Tr(),start_td(),start_table();
				print Tr(td({class=>'header',colspan=>'4',title=>"The KPI Scores are weighted from the Health Metric for the node, compared to the previous periods KPI's, the cell color indicates overall score and the arrow indicates if the KPI is improving or not."},"KPI Scores"));

				print Tr(
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{reachabilityHealth}/$reachabilityMax * 100)),title=>"The Reachability KPI measures how well the node can be reached with ping."},"Reachability ",img({src=>"$C->{'<menu_url_base>'}/img/$reachabilityIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{reachabilityHealth}/$reachabilityMax"),
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{availabilityHealth}/$availabilityMax * 100)),title=>"Availability measures how many of the node's interfaces are available."},"Availability ",img({src=>"$C->{'<menu_url_base>'}/img/$availabilityIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{availabilityHealth}/$availabilityMax"),
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{responseHealth}/$responseMax * 100)),title=>"The Response KPI decreases when the node's response time increases."},"Response ",img({src=>"$C->{'<menu_url_base>'}/img/$responseIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{responseHealth}/$responseMax"),
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{cpuHealth}/$cpuMax * 100)),title=>"The CPU utilisation KPI decreases when CPU load increases."},"CPU ",img({src=>"$C->{'<menu_url_base>'}/img/$cpuIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{cpuHealth}/$cpuMax"),
				);

				print Tr(
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{memHealth}/$memMax * 100)),title=>"Main memory usage KPI, decreases as the memory utilisation increases."},"MEM ",img({src=>"$C->{'<menu_url_base>'}/img/$memIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{memHealth}/$memMax"),
					td({class=>'info',style=>getBGColor(colorPercentHi($stats->{$node}{intHealth}/$intMax * 100)),title=>"The  Interface utilisation KPI reduces when the global interfaces utilisation increases."},"Interface ",img({src=>"$C->{'<menu_url_base>'}/img/$intIcon",border=>'0', width=>'11', height=>'10'}),"$stats->{$node}{intHealth}/$intMax"),
					$diskCell,
					$swapCell,
				);
				print end_table(),end_td(),end_Tr();
			}
		}
	}


	if ( getbool($NI->{system}{collect})
			 or getbool($NI->{system}{ping}) ) {
		my $GTT = $S->loadGraphTypeTable(); # translate graphtype to type
		my $cnt = 0;
		my @graphs = split /,/,$M->{system}{nodegraph};

		### 2014-08-27 keiths, insert the kpi graphtype if missing.
		if ( not grep { "kpi" eq $_ } (@graphs) ) {
			my @newgraphs;
			foreach my $graph (@graphs) {
				if ( $graph eq "health" and $validKpiData ) {
					push(@newgraphs,"kpi");
				}
				push(@newgraphs,$graph);
			}
			@graphs = @newgraphs;
		}

		my $gotAltCpu = 0;

		foreach my $graph (@graphs) {
			my @pr;
			# check if database rule exists
			next unless $GTT->{$graph} ne '';
			next if $graph eq 'response'
					and getbool($NI->{system}{ping},"invert"); # no ping done
			# first two or all graphs

			## display more graphs by default
			if ($cnt == 3
					and !getbool($Q->{expand})
					and getbool($NI->{system}{collect})
					and getbool($C->{auto_expand_more_graphs},"invert")) {
				if ($#graphs > 1) {
					# signal there are more graphs
					print Tr(td({class=>'info Plain'},a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&expand=true&node=".uri_escape($node)},"More graphs")));
				}
				last;
			}
			$cnt++;
			# proces multi graphs, only push the hrsmpcpu graphs if there is no alternate CPU graph.
			if ($graph eq 'hrsmpcpu' and not $gotAltCpu) {
				foreach my $index ( $S->getTypeInstances(graphtype => "hrsmpcpu")) {
					push @pr, [ "Server CPU $index ($NI->{device}{$index}{hrDeviceDescr})", "hrsmpcpu", "$index" ] if exists $NI->{device}{$index};
				}
			}
			else {
				push @pr, [ $M->{heading}{graphtype}{$graph}, $graph ] if $graph ne "hrsmpcpu";
				if ( $graph =~ /(ss-cpu|WindowsProcessor)/ ) {
					$gotAltCpu = 1;
				}
			}
			#### now print it
			foreach ( @pr ) {
				print Tr(td({class=>'header'},$_->[0])),
				Tr(td({class=>'image'},htmlGraph(graphtype=>$_->[1],node=>$node,intf=>$_->[2], width=>$smallGraphWidth,height=>$smallGraphHeight) ));
			}
		} # end for
	}
	elsif ( defined $NI->{system}{services} and $NI->{system}{services} ne "" ) {
		print Tr(td({class=>'header'},'Monitored Services'));
		my $serviceStatus = $NI->{service_status};
		foreach my $servicename (keys %{$serviceStatus}) {

			my $thisservice = $serviceStatus->{$servicename};

			my $thiswidth = int(2/3*$smallGraphWidth);

			my $serviceurl = "$C->{'<cgi_url_base>'}/services.pl?conf=$Q->{conf}&act=details&widget=$widget&node="
					.uri_escape($node)."&service=".uri_escape($servicename);
			my $color = $thisservice->{status} == 100? 'Normal': $thisservice->{status} > 0? 'Warning' : 'Fatal';

			my $statustext = "$servicename";
			$statustext .= " - " .$thisservice->{status_text} if $thisservice->{status_text} ne "";

			print Tr(
				td({class=>"info Plain"},a({class => "islink", href=> $serviceurl}, "$statustext")),
					);
			print Tr(
				td({class=>'image'},
					htmlGraph(graphtype => "service", node=>$node, intf=>$servicename, width=>$thiswidth, height=>$smallGraphHeight),
					htmlGraph(graphtype => "service-response", node=>$node, intf=>$servicename, width=>$thiswidth, height=>$smallGraphHeight)
				));

		}

	}
	else {
		print Tr(td({class=>'info Plain'},'no Graph info'));
	}
	print end_table,end_td;

	print end_Tr,end_table;

	pageEnd() if (!$wantwidget);
}


sub viewInterface
{
	my $intf = $Q->{intf};

	my $node = $Q->{node};
	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();
	my %status = PreciseNodeStatus(system => $S);

	# order of items
	my @order = ('ifAdminStatus','ifOperStatus','ifDescr','ifType','ifPhysAddress','Description','operAvail','totalUtil',
	'ifSpeed','ipAdEntAddr','ipSubnet','ifLastChange','collect','nocollect');

	# format key is ${index}_item_value
	my @keys = grep { $_ =~ /^(\d+).*_value$/ and $1 == $intf} sort keys %{$V->{interface}};

	map { $_ =~ s/^\d+_// } @keys;
	map { $_ =~ s/_value$// } @keys; # get only item

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table;

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical', colspan=>'2'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning', colspan=>'2'},"Node degraded, "
								. join(", ",@causes)
								. ", status=$NI->{system}{status_summary}"));
	}

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
					elsif ( $k eq "ifPhysAddress" and $value =~ /^0x[0-9a-f]+$/i ) {
						$value = beautify_physaddress($value);
					}
					elsif ( $k eq "ifLastChange" ) {
						$value = convUpTime($NI->{system}{sysUpTimeSec} - $IF->{$intf}{ifLastChangeSec});
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

	# we show *all* interfaces where the standard autil/abits graphs exist,
	# regardless of current collection status.
	my $dbname;
	if (exists $V->{interface}{"${intf}_collect_value"}
			&& -f ($dbname = $S->getDBName(graphtype => "autil", index => $intf, suppress_errors => 1)))
	{
		print	Tr(td({class=>'header'},"Utilization")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>"autil",node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) )),
		Tr(td({class=>'header'},"Bits per second")),
		Tr(td({class=>'image'},htmlGraph(graphtype=>"abits",node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
		;
		if (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'pkts2'))) {
			print Tr(td({class=>'header'},"Packets per second")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'pkts2',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}
		elsif (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'pkts_hc'))) {
			print Tr(td({class=>'header'},"Packets per second")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'pkts_hc',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}
		### 2014-10-23 keiths, added this to display by default for interfaces.
		if (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'errpkts2'))) {
			print Tr(td({class=>'header'},"Errors and Discards")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'errpkts2',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}
		elsif (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'errpkts_hc'))) {
			print Tr(td({class=>'header'},"Errors and Discards")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'errpkts_hc',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}
		if (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'cbqos-in'))) {
			print Tr(td({class=>'header'},"CBQoS in")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'cbqos-in',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}
		if (grep($_ eq $intf, $S->getTypeInstances(graphtype => 'cbqos-out'))) {
			print Tr(td({class=>'header'},"CBQoS out")),
			Tr(td({class=>'image'},htmlGraph(graphtype=>'cbqos-out',node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight) ))
			;
		}

	} else {
		print Tr(td({class=>'info Plain'},'No graph info'));
	}
	print end_table,end_td;

	print end_Tr,end_table;

	pageEnd() if (!$wantwidget);

}

sub viewAllIntf {
	my %args = @_;
	my $active = $Q->{active}; # flag for only active interfaces to display

	my $node = $Q->{node};
	my $sort = $Q->{sort} || 'ifDescr';
	my $dir;
	if ($Q->{dir} eq '' or $Q->{dir} eq 'rev'){$dir='fwd';}else{$dir='rev';} # direction of sort

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();
	my %status = PreciseNodeStatus(system => $S);

	# order of header
	my @header = ('ifDescr','Description','ipAdEntAddr1','display_name',
								'ifAdminStatus','ifOperStatus','operAvail','totalUtil',
								'ifSpeed','ifSpeedIn','ifSpeedOut','ifPhysAddress','ifLastChange',
								'collect','ifIndex','portDuplex','portSpantreeFastStart','vlanPortVlan','escalate');

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
		next if (getbool($active) and $_ eq 'collect'); # not interesting for active interfaces
		if ($items{$_} and $titles{$_} ne '' ) { push @hd,$_; } # available item
	}

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table;

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',width=>'100%'},"Interface Table of node $node"));

	print start_Tr,start_td,start_table;
	# print header
	print Tr(
	eval { my @out;
		foreach my $k (@hd){
			my @hdr = split(/\(/,$titles{$k}); # strip added info
			push @out,td({class=>'header',align=>'center'},
			a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view_all&refresh=$Q->{refresh}&widget=$widget&sort=$k&dir=$dir&active=$Q->{active}&node=".uri_escape($node)},
			$hdr[0]));
		}
		return @out;
	});

	# print data
	foreach my $intf ( sorthash(\%view,[$sort,"value"], $dir)) {
		next if (getbool($active) and !getbool($view{$intf}{collect}{value}));
		print Tr(
			eval {
				my @out;

				foreach my $k (@hd)
				{
					my $color = getbool($view{$intf}{collect}{value})?
							($view{$intf}{$k}{color} ne "") ? $view{$intf}{$k}{color} : '#FFF' : "#cccccc";				# no collect gets grey background
				push @out,td({class=>'info Plain',style=>getBGColor($color)},
				eval { my $line;
					$view{$intf}{$k}{value} = ($view{$intf}{$k}{value} =~ /noSuch|unknow/i) ? '' : $view{$intf}{$k}{value};
					if ($k eq 'ifDescr') {
						$line = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&refresh=$Q->{refresh}&widget=$widget&intf=$intf&node=".uri_escape($node)},$view{$intf}{$k}{value});
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
					#0x002a14fffeeb352e
					#0x00cfda005ebf
					elsif ( $k eq 'ifPhysAddress' and $view{$intf}{ifPhysAddress}{value} =~ /^0x[0-9a-f]+$/i ) {
						$line = beautify_physaddress($view{$intf}{ifPhysAddress}{value});
					}
					elsif ( $k eq "ifLastChange" ) {
						$line = convUpTime($NI->{system}{sysUpTimeSec} - $IF->{$intf}{ifLastChangeSec});
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

	pageEnd() if (!$wantwidget);

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

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();

	my %status = PreciseNodeStatus(system => $S);

	# order of header
	my @header = ('ifDescr','Description', 'display_name', 'ifAdminStatus','ifOperStatus','operAvail','totalUtil');

	# create hash from view table
	my %view;
	my %titles;
	my %items;
	for my $k (keys %{$V->{interface}})
	{
		if ( $k =~ /^(\d+)_(.+)_(.+)$/ )
		{
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

	# fixme gone
	my $url = "network.pl?conf=$Q->{conf}&act=network_port_view&node=".uri_escape($node);

	my $graphtype = ($Q->{graphtype} eq '') ? $C->{default_graphtype} : $Q->{graphtype};

	# the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmis", -href => url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "network_port_view")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "node", -value => $node);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh},
												widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table;

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',width=>'100%'},"Interface Table of node $NI->{system}{name}"));



	### 2013-12-17 keiths, added dynamic building of the graph types
	my @graphtypes = ('');
	my @interfaceModels = ('interface','pkts_hc','pkts');
	foreach my $im (@interfaceModels) {
		if ( exists $M->{interface}{rrd}{$im} ) {
			foreach my $gt (split(/,/,$M->{interface}{rrd}{$im}{graphtype})) {
				push(@graphtypes,$gt);
			}
		}
	}

	my $colspan=2;

	print start_Tr,start_td,start_table;
	# print header
	print Tr(
	eval {
		my @out;
		foreach my $k (@hd){
			my @hdr = split(/\(/,$titles{$k}); # strip added info
			push @out,td({class=>'header',align=>'center'},
									 a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_port_view&sort=$k&dir=$dir&graphtype=$graphtype&node="
													.uri_escape($node)},
										 $hdr[0]));
		}
		push @out,td({class=>'header',align=>'center'},'Graph');
		if ($S->getTypeInstances(graphtype => 'cbqos-in', section => 'cbqos-in')) {
			push @out,td({class=>'header',align=>'center'},
									 a({href=>"network.pl?conf=$Q->{conf}&act=network_port_view&graphtype=cbqos-in&node=".uri_escape($node)},'CBQoS in'));
			$colspan++;
		}
		if ($S->getTypeInstances(graphtype => 'cbqos-in', section => 'cbqos-out')) {
			push @out,td({class=>'header',align=>'center'},
									 a({href=>"network.pl?conf=$Q->{conf}&act=network_port_view&graphtype=cbqos-out&node=".uri_escape($node)},'CBQoS out'));
			$colspan++;
		}
		push @out, td({class=>'header',align=>'center'}),
		popup_menu(-name=>"graphtype",
							 -values=>\@graphtypes,-default=>$graphtype,
							 onchange => $wantwidget? "get('nmis');" : 'submit();');
		return @out;
		});

	# print data
	foreach my $intf ( sorthash(\%view,[$sort,"value"], $dir)) {
		next if (getbool($active) and !getbool($view{$intf}{collect}{value}));
		next if ($graphtype =~ /cbqos/ and !grep($intf eq $_, $S->getTypeInstances(graphtype => $graphtype)));

		print Tr(
		eval { my @out;
			foreach my $k (@hd){
				my $if = $view{$intf}{$k};
				my $color = ($if->{color} ne "") ? $if->{color} : '#FFF';
				push @out,td({class=>'info Plain',style=>getBGColor($color)},
				eval { my $line;
					$if->{value} = ($if->{value} =~ /noSuch|unknow/i) ? '' : $if->{value};
					if ($k eq 'ifDescr') {
						$line = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&refresh=$Q->{refresh}&widget=$widget&intf=$intf&node=".uri_escape($node)},$if->{value});
					} else {
						$line = $if->{value};
					}
					return $line;
				});
			}
			if ( ($S->getDBName(graphtype=>$graphtype,index=>$intf,
													suppress_errors=>'true') or $graphtype =~ /cbqos/)) {
				push @out,td({class=>'image',colspan=>$colspan},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$intf,width=>$smallGraphWidth,height=>$smallGraphHeight));
			} else {
				push @out,'no data available';
			}
		return @out; },
		);
	}
	print end_table,end_td,end_Tr;

	print end_table,end_form;

	pageEnd() if (!$wantwidget);
}

sub viewStorage {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table({class=>'table'});

	if ( !$status{overall} ) {
		print Tr(td({class=>'Critical',colspan=>'3'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'3'},"Node degraded, "
								. join(", ",@causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',colspan=>'3'},"Storage of node $NI->{system}{name}"));

	foreach my $st (sort keys %{$NI->{storage}} ) {
		my $D = $NI->{storage}{$st};
		my $graphtype = $D->{hrStorageGraph};
		my $index = $D->{hrStorageIndex};

		my $total = $D->{hrStorageUnits} * $D->{hrStorageSize};
		my $used = $D->{hrStorageUnits} * $D->{hrStorageUsed};

		my $util = sprintf("%.1f%", $used / $total * 100);

		my $rowSpan = 5;
		$rowSpan = 6 if defined $D->{hrFSRemoteMountPoint};
		print start_Tr;
		print Tr(td({class=>'header'},'Type'),td({class=>'info header',width=>'40%'},$D->{hrStorageType}),
		td({class=>'header'},$D->{hrStorageDescr}));
		print Tr(td({class=>'header'},'Units'),td({class=>'info Plain'},$D->{hrStorageUnits}),
		td({class=>'image',rowspan=>$rowSpan},htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
		print Tr(td({class=>'header'},'Size'),td({class=>'info Plain'},$D->{hrStorageSize}));
		# disks use crazy multiples to display MB, GB, etc.
		print Tr(td({class=>'header'},'Total'),td({class=>'info Plain'},getDiskBytes($total)));
		print Tr(td({class=>'header'},'Used'),td({class=>'info Plain'},getDiskBytes($used),"($util)"));
		print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hrStorageDescr}));
		print Tr(td({class=>'header'},'Mount Point'),td({class=>'info Plain'},$D->{hrFSRemoteMountPoint})) if defined $D->{hrFSRemoteMountPoint};

		print end_Tr;
	}
	print end_table;
	pageEnd() if (!$wantwidget);
}

# show one node's monitored services, name, status and small graphs
# args: q's node
sub viewService
{
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	# get the current service status for this node
	my %sstatus = loadServiceStatus(node => $node);
	# structure is server -> service -> node -> data, we don't want the outer layer
	%sstatus = %{$sstatus{$C->{server_name}}} if (ref($sstatus{$C->{server_name}}) eq "HASH");

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh},
												widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>'3'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'3'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',colspan=>'3'},"Monitored services on node $NI->{system}{name}"));

	# for the type determination
	my $ST = loadServicesTable;

	if (my @servicelist = split(",",$NI->{system}->{services}))
	{
		print Tr(
			td({class=>'header'},"Service"),
			td({class=>'header'},"Status"),
			td({class=>'header'},"History")
				);

		# that's names
		foreach my $servicename (sort @servicelist )
		{
			my $thisservice = $sstatus{$servicename}->{$node};

			my $color = $thisservice->{status} == 100? 'Normal': $thisservice->{status} > 0? 'Warning' : 'Fatal';
			my $statustext = $thisservice->{status} == 100? 'running': $thisservice->{status} > 0? 'degraded' : 'down';

			my $thiswidth = int(2/3*$smallGraphWidth);

			# we always the service status graph, and a response time graph iff a/v (ie. non-snmp services)
			my $serviceGraphs = htmlGraph(graphtype => "service", node=>$node, intf=>$servicename,
																		width=>$thiswidth, height=>$smallGraphHeight);

			if (ref($ST->{$servicename}) eq "HASH" and $ST->{$servicename}->{"Service_Type"} ne "service")
			{
				$serviceGraphs .= htmlGraph(graphtype => "service-response", node => $node,
																		intf => $servicename, width=>$thiswidth, height=>$smallGraphHeight);
			}

			my $serviceurl = "$C->{'<cgi_url_base>'}/services.pl?conf=$Q->{conf}&act=details&widget=$widget&node="
					.uri_escape($node)."&service=".uri_escape($servicename);

			print Tr(
				td({class=>'info Plain'},a({class => "islink", href=> $serviceurl}, $servicename)),
				td({class=>"info Plain $color"},$statustext),
				td({class=>'image'}, $serviceGraphs)
					);
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>'3'},"No Services defined for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if (!$wantwidget);
}

sub viewServiceList {

	my $sort = $Q->{sort} ? $Q->{sort} : "Service";

	my $sortField = "hrSWRunName";
	$sortField = "hrSWRunPerfCPU" if $sort eq "CPU";
	$sortField = "hrSWRunPerfMem" if $sort eq "Memory";

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>'7'},"Node unreachable"));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'7'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',colspan=>'7'},"List of Services on node $NI->{system}{name}"));

    #'AppleMobileDeviceService.exe:1756' => {
    #  'hrSWRunStatus' => 'running',
    #  'hrSWRunPerfMem' => 2584,
    #  'hrSWRunType' => '',
    #  'hrSWRunPerfCPU' => 7301,
    #  'hrSWRunName' => 'AppleMobileDeviceService.exe:1756'
    #},
  my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=network_service_list&refresh=$Q->{refresh}&widget=$widget&node=".
uri_escape($node);
	if (defined $NI->{services}) {
		print Tr(
			td({class=>'header'},a({href=>"$url&sort=Service",class=>"wht"},"Service")),
			td({class=>'header'},"Parameters"),
			td({class=>'header'},"Type"),
			td({class=>'header'},"Status"),
			td({class=>'header'},"PID"),
			td({class=>'header'},a({href=>"$url&sort=CPU",class=>"wht"},"Total CPU Time")),
			td({class=>'header'},a({href=>"$url&sort=Memory",class=>"wht"},"Allocated Memory"))
		);
		foreach my $service (sort { sortServiceList($sort, $sortField, $NI, $a,$b) } keys %{$NI->{services}} ) {
			my $color;
			$color = colorPercentHi(100) if $NI->{services}{$service}{hrSWRunStatus} =~ /running|runnable/;
			$color = colorPercentHi(0) if $color eq "red";
			my ($prog,$pid) = split(":",$NI->{services}{$service}{hrSWRunName});

			# cpu time is reported in centi-seconds, which results in hard-to-read big numbers
			my $cpusecs = $NI->{services}{$service}{hrSWRunPerfCPU} / 100;
			my $parameters = $NI->{services}{$service}{hrSWRunPath} . " " . $NI->{services}{$service}{hrSWRunParameters};

			print Tr(
				td({class=>'info Plain'},$prog),
				td({class=>'info Plain'},$parameters),
				td({class=>'info Plain'},$NI->{services}{$service}{hrSWRunType}),
				td({class=>'info Plain',style=>"background-color:".$color},$NI->{services}{$service}{hrSWRunStatus}),
				td({class=>'info Plain'},$pid),
				td({class=>'info Plain'}, sprintf("%.3f s", $cpusecs)),
				td({class=>'info Plain'},$NI->{services}{$service}{hrSWRunPerfMem} . " KBytes")
			);
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>'6'},"No Services found for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if (!$wantwidget);
}

sub sortServiceList
{
	my ($sort, $sortField, $NI, $a, $b) = @_;

		if ( $sort eq "Service" ) {
			return $NI->{services}{$a}{$sortField} cmp $NI->{services}{$b}{$sortField};
		}
		else {
			return $NI->{services}{$b}{$sortField} <=> $NI->{services}{$a}{$sortField};
		}
}

sub viewCpuList {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>'7'},"Node unreachable"));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'7'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	print Tr(th({class=>'title',colspan=>'7'},"List of CPU's on node $NI->{system}{name}"));

  my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=network_service_list&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node);

	if (defined $NI->{services}) {
		print Tr(
			td({class=>'header'},"CPU ID and Description"),
			td({class=>'header'},"History"),
		);
		foreach my $index ( $S->getTypeInstances(graphtype => "hrsmpcpu")) {

			print Tr(
				td({class=>'lft Plain'},"Server CPU $index ($NI->{device}{$index}{hrDeviceDescr})"),
				td({class=>'info Plain'},htmlGraph(graphtype=>"hrsmpcpu",node=>$node,intf=>$index, width=>$smallGraphWidth,height=>$smallGraphHeight) )
			);
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>'6'},"No Services found for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if (!$wantwidget);
}


sub viewStatus {

	my $colspan = 7;

	my $sort = $Q->{sort} ? $Q->{sort} : "level";

	my $sortField = "status";
	$sortField = "value" if $sort eq "value";
	$sortField = "status" if $sort eq "status";
	$sortField = "element" if $sort eq "element";
	$sortField = "property" if $sort eq "property";

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	$S->readNodeView();
	my $V = $S->view();

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>$colspan},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>$colspan},"Node degraded, "
								.join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

	my $color = colorPercentHi($NI->{system}{status_summary}) if $NI->{system}{status_summary};

	#print Tr(td({class=>'info Plain',style=>"background-color:".$color,colspan=>$colspan},'Status Summary'));

	print Tr(th({class=>'title',colspan=>$colspan},"Status Summary for node $NI->{system}{name}"));

    #  "ssCpuRawWait--0" : {
    #     "status" : "Threshold",
    #     "value" : "0.00",
    #     "status" : "ok",
    #     "event" : "Proactive CPU IO Wait",
    #     "element" : "",
    #     "index" : null,
    #     "level" : "Normal",
    #     "updated" : 1413880177,
    #     "type" : "systemStats",
    #     "property" : "ssCpuRawWait"
    #  },

  my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=network_status_view&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node);
	if (defined $NI->{status}) {
		print Tr(
			td({class=>'header'},a({href=>"$url&sort=method",class=>"wht"},"Method")),
			td({class=>'header'},a({href=>"$url&sort=element",class=>"wht"},"Element")),
			td({class=>'header'},a({href=>"$url&sort=property",class=>"wht"},"Event")),
			td({class=>'header'},a({href=>"$url&sort=value",class=>"wht"},"Value")),
			td({class=>'header'},a({href=>"$url&sort=level",class=>"wht"},"Level")),
			td({class=>'header'},a({href=>"$url&sort=status",class=>"wht"},"Status")),
			td({class=>'header'},"Updated"),
		);
		foreach my $status (sort { sortStatus($sort, $sortField, $NI, $a, $b) } keys %{$NI->{status}} ) {
			if ( exists $NI->{status}{$status}{updated} and $NI->{status}{$status}{updated} > time - 3600) {
				my $updated = returnDateStamp($NI->{status}{$status}{updated});
				my $elementLink = $NI->{status}{$status}{element};
				$elementLink = $node if not $elementLink;
				if ( $NI->{status}{$status}{type} =~ "(interface|pkts)" ) {
					$elementLink = a({href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&intf=$NI->{status}{$status}{index}&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node)},$NI->{status}{$status}{element});
				}

				print Tr(
					td({class=>'info Plain'},$NI->{status}{$status}{method}),
					td({class=>'lft Plain'},$elementLink),
					td({class=>'info Plain'},$NI->{status}{$status}{event}),
					td({class=>'rht Plain'},$NI->{status}{$status}{value}),
					td({class=>"info Plain $NI->{status}{$status}{level}"},$NI->{status}{$status}{level}),
					td({class=>'info Plain'},$NI->{status}{$status}{status}),
					td({class=>'info Plain'},$updated)
				);
			}
		}
	}
	else {
		print Tr(th({class=>'title',colspan=>$colspan},"No Status Summary found for $NI->{system}{name}"));
	}
	print end_table;
	pageEnd() if (!$wantwidget);
}

sub sortStatus {
	my ($sort , $sortField, $NI, $a, $b) = @_;

	if ( $sort =~ "(property|level|element|status|method)" ) {
		return $NI->{status}{$a}{$sortField} cmp $NI->{status}{$b}{$sortField};
	}
	else {
		return $NI->{status}{$b}{$sortField} <=> $NI->{status}{$a}{$sortField};
	}
}

sub viewEnvironment {

	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>'3'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'3'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

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
	pageEnd() if (!$wantwidget);
}

# display a systemhealth table for one node and its (indexed) instances of that particular section/kind
# args: section, also uses Q
sub viewSystemHealth
{
	my $section = shift;
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

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
				!$S->parseString(string=>"($M->{systemHealth}{rrd}{$section}{control}) ? 1:0", index=>$index, sect=>$section)) {
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

			if (!$status{overall})
			{
				print Tr(td({class=>'Critical',colspan=>$colspan},'Node unreachable'));
			}
			elsif ( $status{overall} == -1 ) # degraded, but why?
			{
				my @causes;
				push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
				push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

				print Tr(td({class=>'Warning',colspan=>$colspan},"Node degraded, "
										. join(", ",@causes)
										. ", status=$NI->{system}{status_summary}"));
			}

			print Tr(th({class=>'title',colspan=>$colspan},"$section of node $NI->{system}{name}"));

			my $row = join(" ",@cells);
			print Tr($row);
			$headerDone = 1;
		}

		# now make each cell!
		my @cells;
		my $cell;
		foreach my $head (@headers)
		{
			# links to all kinds of targets, using the <header>_url, <header>_target
			# and <header>_id properties in the node info structure
			# _url needs to understand query param widget if its an internal page.
			# _id needed to make widgetted mode work and is passed as id attrib.
			# _target is passed through as target attrib.
			# if _target is present, then we DON'T set widget=X and DON'T set the id attrib at all.

			my $url;
			if ($D->{$head."_url"})
			{
				$url = URI->new($D->{$head."_url"});
				$url->query_param("widget" => $widget) if (!$D->{"${head}_target"});
			}

			# internal mode, widgetted
			if ( $url and defined $D->{$head."_id"} and not $D->{"${head}_target"} )
			{
				$cell = td({class=>'info Plain'},"<a href=\"$url\" id=\"$D->{$head.'_id'}\">$D->{$head}</a>");
			}
			# non-widgetted or external mode
			elsif ( $url )
			{
				$cell = td({class=>'info Plain'},"<a href='$url'"
									 .($D->{"${head}_target"}? " target='".$D->{"${head}_target"}."'":'')
									 .">$D->{$head}</a>");
			}
			else {
				$cell = td({class=>'info Plain'},$D->{$head});
			}
			push(@cells,$cell);
		}

		if ( $graphtype ) {
			# use 2/3 width so fits a little better.
			my $thiswidth = int(2/3*$smallGraphWidth);

			# fixme: this code does nothing: split /,/, $M->{system}{nodegraph};
			my @graphtypes = split /,/, $graphtype;

			push(@cells, start_td);
			foreach my $GT (@graphtypes) {
				push(@cells,htmlGraph(graphtype=>$GT,node=>$node,intf=>$index,width=>$thiswidth,height=>$smallGraphHeight)) if $GT;
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
	pageEnd() if (!$wantwidget);
}

sub viewCSSGroup
{
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table({class=>'table'});

	my %status = PreciseNodeStatus(system =>  $S);

	if ( !$status{overall})
	{
		print Tr(td({class=>'Critical',colspan=>'3'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'3'},"Node degraded, "
								. join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

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
	pageEnd() if (!$wantwidget);
}

sub viewCSSContent
{
	my $node = $Q->{node};

	my $S = Sys::->new; # get system object
	$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
	my $NI = $S->ndinfo;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if (!$AU->InGroup($NI->{system}{group})) {
		print 'You are not authorized for this request';
		return;
	}

	my %status = PreciseNodeStatus(system => $S);

	print createHrButtons(node=>$node, system => $S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);
	print start_table({class=>'table'});

	if ( !$status{overall} )
	{
		print Tr(td({class=>'Critical',colspan=>'3'},'Node unreachable'));
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP ".($status{snmp_status}? "Up":"Down") if ($status{snmp_enabled});
		push @causes, "WMI ".($status{wmi_status}? "Up":"Down") if ($status{wmi_enabled});

		print Tr(td({class=>'Warning',colspan=>'3'},"Node degraded, "
								.join(", ", @causes)
								. ", status=$NI->{system}{status_summary}"));
	}

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
	pageEnd() if (!$wantwidget);
}

sub viewOverviewIntf {

	my $node;
	#	my @out;
	my $icon;
	my $cnt;
	my $text;

	print header($headeropts);
	pageStartJscript(title => "$node - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

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
		a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($node)},$NT->{$node}{name}));
	}
	if ($II->{$key}{ifAdminStatus} ne 'up') {
		$icon = 'block_grey.png';
	} elsif ($II->{$key}{ifOperStatus} eq 'up') {
		$icon = getbool($II->{$key}{collect}) ? 'arrow_up_green.png' : 'arrow_up_purple.png';
	} elsif ($II->{$key}{ifOperStatus} eq 'dormant') {
		$icon = getbool($II->{$key}{collect}) ? 'arrow_up_yellow.png' : 'arrow_up_purple.png';
	} else {
		$icon = getbool($II->{$key}{collect}) ? 'arrow_down_red.png' : 'block_purple.png';
	}
	if ($cnt++ >= 32) {
		print end_Tr,start_Tr,td({class=>'info Plain'},'&nbsp;');
		$cnt = 1;
	}
	$text = "name=$II->{$key}{ifDescr}<br>adminStatus=$II->{$key}{ifAdminStatus}<br>operStatus=$II->{$key}{ifOperStatus}<br>".
	"description=$II->{$key}{Description}<br>collect=$II->{$key}{collect}";
	print td({class=>'info Plain'},
	a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_interface_view&intf=$II->{$key}{ifIndex}&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node),
	},
	img({src=>"$C->{'<menu_url_base>'}/img/$icon",border=>'0', width=>'11', height=>'10'})));
	}
	print end_Tr if $node ne '';
	print end_table;

	END_viewOverviewIntf:
	pageEnd() if (!$wantwidget);
}


sub viewTop10 {

	print header($headeropts);
	pageStartJscript(title => "Top 10 - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

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
		if ( getbool($NT->{$reportnode}{active}) ) {
			$S->init(name=>$reportnode,snmp=>'false');
			my $NI = $S->ndinfo;
			my $IF = $S->ifinfo;
			# reachable, available, health, response
			%reportTable = (%reportTable,%{getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode)});
			# cpu only for routers, switch cpu and memory in practice not an indicator of performance.
			# avgBusy1min, avgBusy5min, ProcMemUsed, ProcMemFree, IOMemUsed, IOMemFree
			if ($NI->{graphtype}{nodehealth} =~ /cpu/
					and getbool($NI->{system}{collect})) {
				%cpuTable = (%cpuTable,%{getSummaryStats(sys=>$S,type=>"nodehealth",start=>$start,end=>$end,index=>$reportnode)});
				print STDERR "Result: ". Dumper \%cpuTable;
			}

			foreach my $int (keys %{$IF} ) {
				if ( getbool($IF->{$int}{collect}) ) {
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
		a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($reportnode)},$reportnode)).
		td({class=>'info Plain',align=>'center'},$reportTable{$reportnode}{response});
		# loop control
		last if --$i == 0;
	}
	$i=10;
	for my $reportnode ( sortall(\%cpuTable,'avgBusy5min','rev')) {
		$cpuTable{$reportnode}{avgBusy5min} =~ /(^\d+)/;
		push @out_cpu,
		td({class=>"info Plain $nodewrap"},
		a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($reportnode)},$reportnode)).
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
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain'},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&intf=$intf&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($reportnode)},$linkTable{$reportlink}{ifDescr})),
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
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain'},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&intf=$intf&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($reportnode)},$linkTable{$reportlink}{ifDescr})),
			td({class=>'info Plain',align=>'right'},getBits($linkTable{$reportlink}{inputBits})),
			td({class=>'info Plain',align=>'right'},getBits($linkTable{$reportlink}{outputBits}))
		);
		# loop control
		last if --$i == 0;
	}
	print end_table;
	print '<!-- Top10 report end -->';

	pageEnd() if (!$wantwidget);

}

#============================
# Desc: displays a summary of nodes, by default only nodes with issues, e.g. unreachable nodes.
# Menu: Node Admin Summary
# url: node_admin_summary
# Title: Node Admin Summary
#============================'
sub nodeAdminSummary
{
	my %args = @_;

	my $group = $Q->{group};
	my $filter = $Q->{filter};
	if ($filter eq "") {
		$filter = 0;
	}
	print header($headeropts);
	pageStartJscript(title => "$group - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	if ($group ne "" and !$AU->InGroup($group)) {
		print 'You are not authorized for this request';
	}
	else {
		my $LNT = loadLocalNodeTable();
		my $noExceptions = 1;

		#print qq|"name","group","version","active","collect","last updated","icmp working","snmp working","nodeModel","nodeVendor","nodeType","roleType","netType","sysObjectID","sysObjectName","sysDescr","intCount","intCollect"\n|;
		my @headers = (
			"name",
			"group",
			"summary",
			"active",
			"last collect poll",
			"last update poll",
			"ping (icmp)",
			"icmp working",
			"collect (snmp/wmi)",
			"wmi working",
			"snmp working",
			"community",
			"version",
			"nodeVendor",
			"nodeModel",
			"nodeType",
			"sysObjectID",
			"sysDescr",
			"Int. Collect of Total",
				);

		my $extra = " for $group" if $group ne "";
		my $cols = @headers;
		my $nmisLink = a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;" if (!getbool($widget));

		my $urlsafegroup = uri_escape($group);

		print start_table({class=>'dash', width=>'100%'});
		print Tr(th({class=>'title',colspan=>$cols},
				$nmisLink,
				"Node Admin Summary$extra ",
				a({style=>"color:white;",href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=node_admin_summary&refresh=$C->{page_refresh_time}&widget=$widget"},"All Nodes"),
				a({style=>"color:white;",href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget"},"All Information"),
				a({style=>"color:white;",href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=exceptions"},"Only Exceptions")
			));
		print Tr( eval {
			my $line;
			foreach my $h (@headers) {
				$line .= td({class=>'header',align=>'center'},$h);
			} return $line;
		} );

		foreach my $node (sort keys %{$LNT})
		{
			#if ( $LNT->{$node}{active} eq "true" ) {
			if ( 1 ) {
				if ( $AU->InGroup($LNT->{$node}{group}) and ($group eq "" or $group eq $LNT->{$node}{group}) ) {
					my $intCollect = 0;
					my $intCount = 0;
					my $S = Sys::->new; # get system object
					$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
					my $NI = $S->ndinfo;
					my $IF = $S->ifinfo;
					my $exception = 0;
					my @issueList;

					# Is the node active and are we doing stats on it.
					if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
						for my $ifIndex (keys %{$IF}) {
							++$intCount;
							if ( $IF->{$ifIndex}{collect} eq "true") {
								++$intCollect;
								#print "$IF->{$ifIndex}{ifIndex}\t$IF->{$ifIndex}{ifDescr}\t$IF->{$ifIndex}{collect}\t$IF->{$ifIndex}{Description}\n";
							}
						}
					}
					my $sysDescr = $NI->{system}{sysDescr};
					$sysDescr =~ s/[\x0A\x0D]/\\n/g;
					$sysDescr =~ s/,/;/g;

					my $community = "OK";
					my $commClass = "info Plain";

					my $lastCollectPoll = defined $NI->{system}{lastCollectPoll} ? returnDateStamp($NI->{system}{lastCollectPoll}) : "N/A";
					my $lastCollectClass = "info Plain";

					my $lastUpdatePoll = defined $NI->{system}{lastUpdatePoll} ? returnDateStamp($NI->{system}{lastUpdatePoll}) : "N/A";
					my $lastUpdateClass = "info Plain";

					my $pingable = "unknown";
					my $pingClass = "info Plain";

					my $snmpable = "unknown";
					my $snmpClass = "info Plain";

					my $wmiworks = "unknown";
					my $wmiclass = "info Plain";

					my $moduleClass = "info Plain";

					my $actClass = "info Plain Minor";
					if ( $LNT->{$node}{active} eq "false" ) {
						push(@issueList,"Node is not active");
					}
					else {
						$actClass = "info Plain";
						if ( $LNT->{$node}{active} eq "false" ) {
							$lastCollectPoll = "N/A";
						}
						elsif ( not defined $NI->{system}{lastCollectPoll} ) {
							$lastCollectPoll = "unknown";
							$lastCollectClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"Last collect poll is unknown");
						}
						elsif ( $NI->{system}{lastCollectPoll} < (time - 60*15) ) {
							$lastCollectClass = "info Plain Major";
							$exception = 1;
							push(@issueList,"Last collect poll was over 5 minutes ago");
						}

						if ( $LNT->{$node}{active} eq "false" ) {
							$lastUpdatePoll = "N/A";
						}
						elsif ( not defined $NI->{system}{lastUpdatePoll} ) {
							$lastUpdatePoll = "unknown";
							$lastUpdateClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"Last update poll is unknown");
						}
						elsif ( $NI->{system}{lastUpdatePoll} < (time - 86400) ) {
							$lastUpdateClass = "info Plain Major";
							$exception = 1;
							push(@issueList,"Last update poll was over 1 day ago");
						}

						$pingable = "true";
						$pingClass = "info Plain";
						if ( not defined $NI->{system}{nodedown} ) {
							$pingable = "unknown";
							$pingClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"Node state is unknown");
						}
						elsif ( $NI->{system}{nodedown} eq "true" ) {
							$pingable = "false";
							$pingClass = "info Plain Major";
							$exception = 1;
							push(@issueList,"Node is currently unreachable");
						}

						# figure out what sources are enabled and which of those work/are misconfig'd etc
						my %status = PreciseNodeStatus(system => $S);

						if ( !getbool($LNT->{$node}{collect}) or !$status{wmi_enabled} )
						{
							$wmiworks = "N/A";
						}
						else
						{
							if (!$status{wmi_status})
							{
								$wmiworks = "false";
								$wmiclass = "Info Plain Major";
								$exception = 1;
								push @issueList, "WMI access is currently down";
							}
							else
							{
								$wmiworks = "true";
							}
						}

						if ( !getbool($LNT->{$node}{collect}) or !$status{snmp_enabled} )
						{
							$community = $snmpable = "N/A";
						}
						else
						{
							$snmpable = 'true';
							if ( !$status{snmp_status} )
							{
								$snmpable = 'false';
								$snmpClass = "info Plain Major";
								$exception = 1;
								push(@issueList,"SNMP access is currently down");
							}

							if ( $LNT->{$node}{community} eq "" ) {
								$community = "BLANK";
								$commClass = "info Plain Major";
								$exception = 1;
								push(@issueList,"SNMP Community is blank");
							}

							if ( $LNT->{$node}{community} eq "public" ) {
								$community = "DEFAULT";
								$commClass = "info Plain Minor";
								$exception = 1;
								push(@issueList,"SNMP Community is default (public)");
							}

							if ( $LNT->{$node}{model} ne "automatic"  ) {
								$moduleClass = "info Plain Minor";
								$exception = 1;
								push(@issueList,"Not using automatic model discovery");
							}
						}
					}

					my $wd = 850;
					my $ht = 700;

					my $idsafenode = $node;
					$idsafenode = (split(/\./,$idsafenode))[0];
					$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;

					my $nodelink = a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=network_node_view&refresh=$Q->{refresh}&widget=$widget&node=".uri_escape($node), id=>"node_view_$idsafenode"},$LNT->{$node}{name});
					#my $url = "network.pl?conf=$Q->{conf}&act=network_node_view&refresh=$C->{page_refresh_time}&widget=$widget&node=".uri_escape($node);
					#a({target=>"NodeDetails-$node", onclick=>"viewwndw(\'$node\',\'$url\',$wd,$ht)"},$LNT->{$node}{name});
					my $issues = join("<br/>",@issueList);

					my $sysObject = "$NI->{system}{sysObjectName} $NI->{system}{sysObjectID}";
					my $intNums = "$intCollect/$intCount";

					if ( length($sysDescr) > 40 ) {
						my $shorter = substr($sysDescr,0,40);
						$sysDescr = "<span title=\"$sysDescr\">$shorter (more...)</span>";
					}

					if ( not $filter or ( $filter eq "exceptions" and $exception ) )
					{
						$noExceptions = 0;

						my $urlsafegroup = uri_escape($LNT->{$node}->{group});
						print Tr(
							td({class => "info Plain"},$nodelink),
							td({class => 'info Plain'},
								a({href => url(-absolute=>1)."?conf=$Q->{conf}&amp;act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=$filter"},$LNT->{$node}{group})
							),
							td({class => 'infolft Plain'},$issues),
							td({class => $actClass},$LNT->{$node}{active}),
							td({class => $lastCollectClass},$lastCollectPoll),
							td({class => $lastUpdateClass},$lastUpdatePoll),

							td({class => 'info Plain'},$LNT->{$node}{ping}),
							td({class => $pingClass},$pingable),

							td({class => 'info Plain'},$LNT->{$node}{collect}),

							td({class => $wmiclass},$wmiworks),


							td({class => $snmpClass},$snmpable),
							td({class => $commClass},$community),
							td({class => 'info Plain'},$LNT->{$node}{version}),


							td({class => 'info Plain'},$NI->{system}{nodeVendor}),
							td({class => $moduleClass},"$NI->{system}{nodeModel} ($LNT->{$node}{model})"),
							td({class => 'info Plain'},$NI->{system}{nodeType}),
							td({class => 'info Plain'},$sysObject),
							td({class => 'info Plain'},$sysDescr),
							td({class => 'info Plain'},$intNums),
						);
					}
				}
			}
		}
		if ( $filter eq "exceptions" and $noExceptions ) {
			print Tr(td({class=>'info Plain',colspan=>$cols},"No node admin exceptions were found"));
		}
		print end_table;
	}
	pageEnd() if (!$wantwidget);
}  # end sub nodeAdminSummary


# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
