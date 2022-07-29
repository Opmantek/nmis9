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
our $VERSION = "9.4.1";

use strict;
use URI::Escape;
use URI;
use URI::QueryParam;
use Net::SNMP qw(oid_lex_sort);
use Data::Dumper;
use Net::IP;
use HTML::Entities;

use CGI qw(:standard *table *Tr *td *form *Select *div);

use Compat::NMIS;
use NMISNG::Util;
use NMISNG::NetworkStatus;
use NMISNG::Graphs;
use Compat::Timing;
use NMISNG;
use NMISNG::Auth;

my $q = new CGI;     # This processes all parameters passed via GET and POST
my $Q = $q->Vars;    # values in hash

$Q = NMISNG::Util::filter_params($Q);
my $nmisng = Compat::NMIS::new_nmisng;
my $C = $nmisng->config;
my $interface_max_number = $C->{interface_max_number} || 5000;

# bypass auth iff called from command line
$C->{auth_require} = 0 if (@ARGV);


# variables used for the security mods
use vars qw($headeropts);
$headeropts = {};                                #{type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new( conf => $C );

if ( $AU->Require )
{
	exit 0
		unless $AU->loginout(
		type       => $Q->{auth_type},
		username   => $Q->{auth_username},
		password   => $Q->{auth_password},
		headeropts => $headeropts
		);
}

#======================================================================

my $widget = NMISNG::Util::getbool( $Q->{widget}, "invert" ) ? 'false' : 'true';
$Q->{expand} = "true" if ( $widget eq "true" );

### unless told otherwise, and this is not JQuery call, widget is false!
if ( not defined $Q->{widget} and not defined $ENV{HTTP_X_REQUESTED_WITH} )
{
	$widget = "false";
}

if ( not defined $ENV{HTTP_X_REQUESTED_WITH} )
{
	$widget = "false";
}

my $wantwidget = ( $widget eq "true" );

### 2013-11-23 keiths adding some timing debug
my $t      = Compat::Timing->new();
my $timing = 0;
$timing = 1 if NMISNG::Util::getbool( $Q->{timing} );

if ( $Q->{refresh} eq "" and $wantwidget )
{
	$Q->{refresh} = $C->{widget_refresh_time};
}
elsif ( $Q->{refresh} eq "" and !$wantwidget )
{
	$Q->{refresh} = $C->{page_refresh_time};
}

my $nodewrap = "nowrap";
$nodewrap = "wrap" if NMISNG::Util::getbool( $C->{'wrap_node_names'} );

my $smallGraphHeight = 50;
my $smallGraphWidth  = 400;

$smallGraphHeight = $C->{'small_graph_height'} if $C->{'small_graph_height'} ne "";
$smallGraphWidth  = $C->{'small_graph_width'}  if $C->{'small_graph_width'} ne "";

$nmisng->log->debug( "TIMING: " . $t->elapTime() . " Begin act=$Q->{act}" ) if $timing;

my $network_status = NMISNG::NetworkStatus->new( nmisng => $nmisng );
my $graphs = NMISNG::Graphs->new( nmisng => $nmisng );

# these need loading before the yucky if selection below, which is terminal for some acts
#my $NT = Compat::NMIS::loadNodeTable();

my @groups   = grep { $AU->InGroup($_) } sort $nmisng->get_group_names;
my $GT = { map { $_ => $_ } (@groups) }; # backwards compat; hash assumption sprinkled everywhere

# select function
my $select;

if ( $Q->{act} eq 'network_summary_health' )
{
	$select = 'health';
}
elsif ( $Q->{act} eq 'network_summary_view' )
{
	$select = 'view';
}
elsif ( $Q->{act} eq 'network_summary_small' )
{
	$select = 'small';
}
elsif ( $Q->{act} eq 'network_summary_large' )
{
	$select = 'large';
}
elsif ( $Q->{act} eq 'network_summary_allgroups' )
{
	$select = 'allgroups';
}
elsif ( $Q->{act} eq 'network_summary_group' )
{
	$select = 'group';
}
elsif ( $Q->{act} eq 'network_summary_customer' )
{
	$select = 'customer';
}
elsif ( $Q->{act} eq 'network_summary_business' )
{
	$select = 'business';
}
elsif ( $Q->{act} eq 'network_summary_metrics' )
{
	$select = 'metrics';
}
elsif ( $Q->{act} eq 'node_admin_summary' )
{
	nodeAdminSummary();
	exit;
}
elsif ( $Q->{act} eq 'network_metrics_graph' )
{
	viewMetrics();
	exit;
}
elsif ( $Q->{act} eq 'network_top10_view' )
{
	viewTop10();
	exit;
}
elsif ( $Q->{act} eq 'network_node_view' )
{
	viewNode();
	exit;
}
elsif ( $Q->{act} eq 'network_storage_view' )
{
	viewStorage();
	exit;
}
elsif ( $Q->{act} eq 'network_service_view' )
{
	viewService();
	exit;
}
elsif ( $Q->{act} eq 'network_service_list' )
{
	viewServiceList();
	exit;
}
elsif ( $Q->{act} eq 'network_cpu_list' )
{
	viewCpuList();
	exit;
}
elsif ( $Q->{act} eq 'network_status_view' )
{
	viewStatus();
	exit;
}
elsif ( $Q->{act} eq 'network_system_health_view' )
{
	viewSystemHealth( $Q->{section} );
	exit;
}
elsif ( $Q->{act} eq 'network_port_view' )
{
	viewActivePort();
	exit;
}
elsif ( $Q->{act} eq 'network_interface_view' )
{
	viewInterface();
	exit;
}
elsif ( $Q->{act} eq 'network_interface_view_all' )
{
	viewAllIntf();
	exit;
}
elsif ( $Q->{act} eq 'network_interface_view_act' )
{
	viewActiveIntf();
	exit;
}
elsif ( $Q->{act} eq 'network_interface_overview' )
{
	viewOverviewIntf();
	exit;
}
elsif ( $Q->{act} eq 'nmis_runtime_view' )
{
	viewRunTime();
	exit;
}
elsif ( $Q->{act} eq 'nmis_polling_summary' )
{
	viewPollingSummary();
	exit;
}
elsif ( $Q->{act} eq "nmis_selftest_view" )
{
	viewSelfTest();
	exit;
}
elsif ( $Q->{act} eq "nmis_selftest_reset" )
{
	clearSelfTest();
	exit;
}
else
{
	$select = 'health';

	#notfound(); exit
}

sub notfound
{
	print header($headeropts);
	print "Network: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf} <br>\n";
	print "Request not found\n";
}

$nmisng->log->debug( "TIMING: " . $t->elapTime() . " Select Subs" ) if $timing;

# option to generate html to file
if ( NMISNG::Util::getbool( $Q->{http} ) )
{
	print start_html(
		-title => 'NMIS Network Summary',
		-style => {'src' => "$C->{'styles'}"},
		-meta  => {'CacheControl' => "no-cache", 'Pragma' => "no-cache", 'Expires' => -1},
		-head  => [
			Link( {-rel => 'shortcut icon', -type => 'image/x-icon', -href => "$C->{'nmis_favicon'}"} ),
			Link( {-rel => 'stylesheet',    -type => 'text/css',     -href => "$C->{'jquery_jdmenu_css'}"} ),
			Link( {-rel => 'stylesheet',    -type => 'text/css',     -href => "$C->{'styles'}"} )
		]
	);
}
else
{
	print header($headeropts);
}

Compat::NMIS::pageStartJscript( title => "NMIS Network Status - $C->{server_name}", refresh => $Q->{refresh} )
	if ( !$wantwidget );


# graph request
my $ntwrk = ( $select eq 'large' ) ? 'network' : ( $Q->{group} eq '' ) ? 'network' : $Q->{group};

my $overallStatus;
my $overallColor;
my %icon;
my $group    = $Q->{group};
my $customer = $Q->{customer};
my $business = $Q->{business};

### 2014-08-28 keiths, configurable metric periods
#my $graphtype = ($Q->{graphtype} eq '') ? $C->{default_graphtype} : $Q->{graphtype};

my $metricsFirstPeriod
	= defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
my $metricsSecondPeriod
	= defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

# define global stats, and default stats period.
my $groupSummary;
my $start = $metricsSecondPeriod;
my $end   = $metricsFirstPeriod;

#===============================
# All global hash, metrics, icons, etc, are now populated
# Call each of the base  network display subs.
#======================================

$nmisng->log->debug( "TIMING: " . $t->elapTime() . " typeSummary" ) if $timing;

print "<!-- typeSummary select=$select start -->\n";

if    ( $select eq 'metrics' ) { selectMetrics(); }
elsif ( $select eq 'health' )  { selectNetworkHealth(); }
elsif ( $select eq 'view' )    { selectNetworkView(); }
elsif ( $select eq 'small' )   { selectSmall(); }
elsif ( $select eq 'large' )   { selectLarge(); }
elsif ( $select eq 'group' )   { selectLarge( group => $group ); }
elsif ( $select eq 'customer' and $customer eq "" ) { selectNetworkHealth( type => "customer" ); }
elsif ( $select eq 'customer' and $customer ne "" ) { selectLarge( customer => $customer ); }
elsif ( $select eq 'business' and $business eq "" ) { selectNetworkHealth( type => "business" ); }
elsif ( $select eq 'business' and $business ne "" ) { selectLarge( business => $business ); }

#elsif ( $select eq 'group' ) { selectGroup($group); }
elsif ( $select eq 'allgroups' ) { selectAllGroups(); }

print "<!-- typeSummary select=$select end-->\n";

Compat::NMIS::pageEnd() if ( !$wantwidget );

$nmisng->log->debug( "TIMING: " . $t->elapTime() . " END $Q->{act}" ) if $timing;

exit();

# end main()

sub getSummaryStatsbyGroup
{
	my %args     = @_;
	my $group    = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $include_nodes = $args{include_nodes};

	$nmisng->log->debug( "TIMING: " . $t->elapTime() . " getSummaryStatsbyGroup begin: $group$customer$business" ) if $timing;
	
	$groupSummary = $network_status->getGroupSummary(
		group    => $group,
		customer => $customer,
		business => $business,
		include_nodes => $include_nodes
	);
	$overallStatus = $network_status->overallNodeStatus( group => $group, customer => $customer, business => $business );
	$overallColor = NMISNG::Util::eventColor($overallStatus);

	# valid hash keys are metric reachable available health response

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h)
	{

		# defaults
		#$icon{${t}} = 'arrow_down_black';
		if ( $groupSummary->{average}{"${t}_dif"} + ( $C->{average_diff} )  >= 0 )
		{
			$icon{${t}} = ( $t eq "response" ) ? 'arrow_up_red' : 'arrow_up';
		}
		else
		{
			$icon{${t}} = ( $t eq "response" ) ? 'arrow_down_green' : 'arrow_down';
		}

	}

	# metric difference
	my $metric = sprintf( "%2.0u", $groupSummary->{average}{"metric_diff"});

	my $metric_color;
	if ( $metric <= -1 )
	{
		$metric_color = NMISNG::Util::colorPercentHi($metric);
		$icon{metric_icon} = 'arrow_down_big';
	}
	elsif ( $metric < 0 )
	{
		$metric_color = NMISNG::Util::colorPercentHi($metric);
		$icon{metric_icon} = 'arrow_down';
	}
	elsif ( $metric < 1 )
	{
		$metric_color = NMISNG::Util::colorPercentHi($metric);
		$icon{metric_icon} = 'arrow_up';
	}
	elsif ( $metric >= 1 ) { $metric_color = NMISNG::Util::colorPercentHi($metric); $icon{metric_icon} = 'arrow_up_big'; }

	## ehg 17 sep 02 add node down counter with colour
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$percentDown
			= sprintf( "%2.0u", $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100;
	}
	$groupSummary->{average}{countdowncolor} = NMISNG::Util::colorPercentLo($percentDown);

	my $percentDegraded = 0;
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$percentDegraded
			= sprintf( "%2.0u", $groupSummary->{average}{countdegraded} / $groupSummary->{average}{counttotal} ) * 100;
	}
	$groupSummary->{average}{countdowncolor} = NMISNG::Util::colorPercentLo($percentDown);

	#if ( $groupSummary->{average}{countdown} > 0) { $groupSummary->{average}{countdowncolor} = NMISNG::Util::colorPercentLo(0); }
	#else { $groupSummary->{average}{countdowncolor} = "$overallColor"; }

	$nmisng->log->debug( "TIMING: " . $t->elapTime() . " getSummaryStatsbyGroup end" ) if $timing;

}    # end sub get SummaryStatsby group

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
	if ( $AU->CheckAccess( "tls_nmis_runtime", "check" ) )
	{
		# allowed to, but do we have a problem to show?
		# this widget is overridden for selftest alerting, iff the last nmis selftest was unsuccessful
		my $cachefile = $C->{'<nmis_var>'} . "/nmis_system/selftest.json";
		if ( -f $cachefile )
		{
			# too old? then run a non-delaying limited selftest right now
			if (time - (stat($cachefile))[9] > 2 * $C->{schedule_selftest})
			{
				NMISNG::Util::selftest(nmisng => $nmisng, delay_is_ok => 0, perms => 0);
			}

			my $selfteststatus = NMISNG::Util::readFiletoHash( file => $cachefile, json => 'true' );
			if ( ref($selfteststatus) && !$selfteststatus->{status} )
			{
				$showmetrics = 0;

				print "<h3>NMIS Selftest failed!</h3>",
					"<small>(Click on the links below for details.)</small>",
					start_table( {width => "100%"} );
				for my $test ( @{$selfteststatus->{tests}} )
				{
					my ( $name, $message ) = @$test;
					next if ( !defined $message );    # skip the successful ones and only print the message here
					                                  # but not too much of the message...
					$message = ( substr( $message, 0, 64 ) . "&nbsp;&hellip;" ) if ( length($message) > 64 );
					print Tr(
						td( {class => "info Error"},
							a(  {   href  => url( -absolute => 1 ) . "?act=nmis_selftest_view",
									id    => "nmis_selftest",
									class => "black"
								},
								$message
							)
						)
					);
				}
				print Tr(
					td( {class => "info Major"},
						a(  {href => url( -absolute => 1 ) . "?act=nmis_selftest_reset&widget=$widget"},
							"Reset Selftest Status"
						)
					)
				);
				print end_table;
			}
		}
	}

	# no errors or not allowed to show them, so continue normally
	if ($showmetrics)
	{
		if ( $AU->InGroup("network") or $AU->InGroup($group) )
		{
			# get all the stats and stuff the hashs
			getSummaryStatsbyGroup( group => $group );

			my @h    = qw/Metric Reachablility InterfaceAvail Health ResponseTime/;
			my @k    = qw/metric reachable available health response/;
			my $time = time;
			my $cp;

			print start_table( {class => "noborder", width => "100%"} ),
				Tr( th( {class => "subtitle"}, "8Hr Summary" ) );

			foreach my $t ( 0 .. 4 )
			{
				$groupSummary->{average}{$k[$t]} = int( $groupSummary->{average}{$k[$t]} );
				$cp = NMISNG::Util::colorPercentHi( $groupSummary->{average}{$k[$t]} );
				$cp = NMISNG::Util::colorPercentLo( $groupSummary->{average}{$k[$t]} ) if $t == 4;
				my $img_width = $groupSummary->{average}{$k[$t]};
				$img_width = 100 - $groupSummary->{average}{$k[$t]} if $t == 4;
				$img_width = 15 if $img_width < 10;    # set min width so value always has bg image color
				$img_width .= '%';
				my $units = $t == 4 ? 'ms' : '%';
				print Tr(
					td( {class => 'metrics', style => "width:186px;"},
						span( {style => 'float:left;'}, img( {src => "$C->{$icon{$k[$t]}}"} ), $h[$t] ),
						span( {style => 'float:right;'}, "$groupSummary->{average}{$k[$t]}$units" ),
						br,
						span(
							{   style =>
									"display:inline-block;position:relative; width:100%; height:16px;border:1px solid;"
							},
							span(
								{   style =>
										"display:inline-block;position:relative;background-color:$cp; width:$img_width;height:16px;"
								},
								span(
									{class => "smallbold", style => "float:right; height:16px;"},
									"$groupSummary->{average}{$k[$t]}$units"
								)
							)
						)
					)
				);
			}    #foreach
			print end_table;
		}
		else     # not authed
		{
			print start_table( {class => "dash", width => "100%"} ),
				Tr( th( {class => "subtitle"}, "You are not authorized for this request" ) ), end_table;
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

sub selectNetworkHealth
{
	my %args     = @_;
	my $type     = $args{type};
	my $customer = $args{customer};
	my $business = $args{business};

	my @h           = qw(Group);
	my $healthTitle = "All Groups Status";
	my $healthType  = "group";

	if ( $type eq "customer" and Compat::NMIS::tableExists('Customers') )
	{
		@h           = qw(Customer);
		$healthTitle = "All Nodes Status";
		$healthType  = "customer";
	}
	elsif ( $type eq "business" and Compat::NMIS::tableExists('BusinessServices') )
	{
		@h           = qw(Business);
		$healthTitle = "All Nodes Status";
		$healthType  = "business";
	}
	elsif ( $C->{network_health_view} eq "Customer" and Compat::NMIS::tableExists('Customers') )
	{
		@h           = qw(Customer);
		$healthTitle = "All Nodes Status";
		$healthType  = "customer";
	}
	elsif ( $C->{network_health_view} eq "Business" and Compat::NMIS::tableExists('BusinessServices') )
	{
		@h           = qw(Business);
		$healthTitle = "All Nodes Status";
		$healthType  = "business";
	}

	if ( exists $C->{display_status_summary}
		and NMISNG::Util::getbool( $C->{display_status_summary} ) )
	{
		push( @h, qw(Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime) );
	}
	else
	{
		push( @h, qw(Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime) );
	}

	$nmisng->log->debug( "TIMING: " . $t->elapTime() . " selectNetworkHealth healthTitle=$healthTitle healthType=$healthType" )
		if $timing;

	print
		start_table( {class => "noborder"} ),

		#Tr(th({class=>"title",colspan=>'10'},"Current Network Status")),
		# Use a subtitle when using multiple servers
		#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
		Tr( th( {class => "header"}, \@h ) );

	if ( $AU->InGroup("network") and $group eq '' )
	{
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup( group => $group );

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$classDegraded = "Error";
		}

		print start_Tr,
			td(
			{class => 'infolft Plain'},
			a( {href => url( -absolute => 1 ) . "?act=network_summary_allgroups"}, $healthTitle ),
			),
			td( {class => "info $overallStatus"}, "$overallStatus" ),
			td( {class => 'info Plain'},          "$groupSummary->{average}{counttotal}" );
		print td( {class => 'info Plain'}, "$groupSummary->{average}{countup}" )
			if ( not NMISNG::Util::getbool( $C->{display_status_summary} ) );
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td( {class => "info $overallStatus"}, "$groupSummary->{average}{countdown}" );
		print td( {class => "info $classDegraded"}, "$groupSummary->{average}{countdegraded}" )
			if ( NMISNG::Util::getbool( $C->{display_status_summary} ) );

		my @h = qw/metric reachable available health response/;
		foreach my $t (@h)
		{
			my $units = $t eq 'response' ? 'ms' : '%';
			my $value
				= $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );
			if ( $value == 100 ) { $value = 100 }
			my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} );
			$bg = "background-color:" . NMISNG::Util::colorResponseTime( $groupSummary->{average}{$t}, $C->{response_time_threshold} )
				if $t eq 'response';
			print
				start_td( {class => 'info Plain', style => "$bg"} ),
				img( {src => $C->{$icon{${t}}}} ),
				$value,
				"$units",
				end_td;
		}
		print end_Tr;

	}

	if ( $healthType eq "customer" )
	{
		my $CT = Compat::NMIS::loadGenericTable('Customers');
		foreach my $customer ( sort keys %{$CT} )
		{
			getSummaryStatsbyGroup( customer => $customer );
			printHealth( customer => $customer );
		}    # end foreach
	}
	elsif ( $healthType eq "business" )
	{
		my $BS = Compat::NMIS::loadGenericTable('BusinessServices');
		foreach my $business ( sort keys %{$BS} )
		{
			getSummaryStatsbyGroup( business => $business );
			printHealth( business => $business );
		}    # end foreach
	}
	else
	{
		foreach $group ( sort keys %{$GT} )
		{
			next unless $AU->InGroup($group);

			# get all the stats and stuff the hashs
			getSummaryStatsbyGroup( group => $group );
			printGroup($group);
		}    # end foreach
	}
	print end_table;

}    # end sub selectNetworkHealth

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
sub selectSmall
{

	my @h = qw/Group Status NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	@h = qw(Group Status NodeDn NodeDeg Metric Reach IntfAvail Health RespTime)
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	print
		start_table( {class => "dash"} ),
		Tr( th( {class => "title", colspan => '10'}, "Current Network Status" ) ),

		# Use a subtitle when using multiple servers
		#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
		Tr( th( {class => "header"}, \@h ) );

	if ( $AU->InGroup("network") and $group eq '' )
	{
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup( group => $group );

		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$classDegraded = "Error";
		}

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		print start_Tr,
			th(
			{class => 'info Plain'},
			a(  {href => url( -absolute => 1 ) . "?act=network_summary_allgroups"}, "All Groups Status"
			),
			),
			td( {class => "info $overallStatus"}, "$overallStatus" );

		#td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
		print td( {class => 'info Plain'}, "$groupSummary->{average}{countup} of $groupSummary->{average}{counttotal}" )
			if ( exists $C->{display_status_summary} and not NMISNG::Util::getbool( $C->{display_status_summary} ) );
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td( {class => "info $overallStatus"},
			"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}" );
		print td( {class => "info $classDegraded"},
			"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}" )
			if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

		my @h = qw/metric reachable available health response/;
		foreach my $t (@h)
		{
			my $units = $t eq 'response' ? 'ms' : '%';
			my $value
				= $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );
			my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} );
			$bg = "background-color:" . NMISNG::Util::colorPercentLo( $groupSummary->{average}{$t} ) if $t eq 'response';
			print
				start_td( {class => 'info Plain', style => "$bg"} ),
				img( {src => $C->{$icon{${t}}}} ),
				$value,
				"$units",
				end_td;
		}
		print end_Tr, end_table;
	}
}    # end sub selectSmall

#============================
# Desc: network status by group, each group summarised to one line
# menu: All Groups
# url: network_summary_group -> select=allgroups
# Title: Network Status by Group
# subtitle: All Groups Status
#============================

sub selectAllGroups
{

	print
		start_table( {class => "dash"} ),
		Tr( th( {class => "title", colspan => '10'}, "All Group Status" ) );

	# Use a subtitle when using multiple servers
	#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),

	my @h = qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	@h = qw(Group Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime)
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	print Tr( th( {class => "header"}, \@h ) );

	foreach $group ( sort keys %{$GT} )
	{
		next unless $AU->InGroup($group);
		next if ($group eq "");
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup( group => $group );
		printGroup($group);
	}    # end foreach
	print end_table;

}    # end sub selectAllGroups

#====================================================
#
# network_summary_group & group=xxxxx
###
### No one seems to use this anymore.......
###
sub selectGroup
{

	my $group = shift;

	# should we write a msg that this user is not authorised to this group ?
	return unless $AU->InGroup($group);

	my @h = qw/Group Status NodeTotal NodeUp NodeDn Metric Reach IntfAvail Health RespTime/;

	@h = qw(Group Status NodeTotal NodeDn NodeDeg Metric Reach IntfAvail Health RespTime)
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	print
		start_table( {class => "dash"} ),
		Tr( th( {class => "title", colspan => '10'}, "$group Status" ) ),

		# Use a subtitle when using multiple servers
		#Tr(th({class=>"subtitle",colspan=>'10'},"Server nmisdev, as of xxxx")),
		Tr( th( {class => "header"}, \@h ) );

	# get all the stats and stuff the hashs
	getSummaryStatsbyGroup( group => $group );
	printGroup($group);
	print end_table;

}    # end sub selectGroup

#==============================================

sub printGroup
{

	my $group = shift;
	my $icon;
	my $not_allowed_chars_group = $C->{not_allowed_chars_group} // "[;=()<>%'\/]";
	
	print start_Tr,
		start_td( {class => 'infolft Plain'} );

	my $idsafegroup = $group;
	$idsafegroup =~ s/ /_/g;    # spaces aren't allowed in id attributes!

	my $encoded_group = encode_entities($idsafegroup);
	$idsafegroup =~ s/$not_allowed_chars_group/_/g;

	my $urlsafegroup = uri_escape($group);

	if ( $AU->InGroup($group) )
	{
		# force a new window if clicked
		print a(
			{   href => url( -absolute => 1 )
					. "?act=network_summary_group&refresh=$Q->{refresh}&widget=$widget&group=$urlsafegroup",
				id => "network_summary_$idsafegroup"
			},
			"$idsafegroup"
		);
	}
	else
	{
		print "$idsafegroup";
	}
	print end_td;

	# calc node down cell color as a % of node total
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
	}
	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$classDegraded = "Error";
	}

	print
		td( {class => "info $overallStatus"}, $overallStatus ),
		td( {class => 'info Plain'},          "$groupSummary->{average}{counttotal}" );
	print td( {class => 'info Plain'}, "$groupSummary->{average}{countup}" )
		if ( not NMISNG::Util::getbool( $C->{display_status_summary} ) );
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td( {class => "info $overallStatus"}, "$groupSummary->{average}{countdown}" );
	print td( {class => "info $classDegraded"}, "$groupSummary->{average}{countdegraded}" )
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h)
	{

		my $units = $t eq 'response' ? 'ms' : '%';
		my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );

		#my $value = sprintf("%.1f",$groupSummary->{average}{$t});
		if ( $value == 100 ) { $value = 100 }
		my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} ) . ';';
		$bg
			= "background-color:"
			. NMISNG::Util::colorResponseTime( $groupSummary->{average}{$t}, $C->{response_time_threshold} ) . ';'
			if $t eq 'response';

		$groupSummary->{average}{$t} = int( $groupSummary->{average}{$t} );
		print
			start_td( {class => 'info Plain', style => "$bg"} ),
			img( {src => $C->{$icon{${t}}}} ),
			$value,
			"$units" . end_td;
	}
	print end_Tr;
}    # end sub printGroup

#============================
# Desc: network status summarised to one line, with all groups summarised underneath
# Menu: Small Network Status and Health
# url: network_summary_view -> select=view
# Title: Current Network Status
# subtitle: All Groups Status
#============================
sub selectNetworkView
{
	my %args     = @_;
	my $type     = $args{type};
	my $customer = $args{customer};
	my $business = $args{business};

	my @h = (
		exists $C->{display_status_summary}
			and NMISNG::Util::getbool( $C->{display_status_summary} )
		? (qw(Group NodeDn NodeDeg Metric Reach Health))
		: (qw(Group NodeDn Metric Reach Health))
	);

	my $healthTitle = "All Groups Status";
	my $healthType  = "group";

	$nmisng->log->debug( "TIMING: " . $t->elapTime() . " selectNetworkView healthTitle=$healthTitle healthType=$healthType" )
		if $timing;

	my $graphGroup = $group || 'network';
	my $colspan = @h;

	print
		start_table( {class => "noborder"} ),

		Tr(
		td( {class => 'image', colspan => $colspan},
			Compat::NMIS::htmlGraph(
				graphtype => "metrics",
				group     => "$graphGroup",
				node      => "",
				intf      => "",
				width     => "600",
				height    => "75"
			)
		)
		),

		start_Tr;

	print th( {class => "header", title => "A group of nodes, and the status"},  "Group" );
	print th( {class => "header", title => "Number of nodes down in the group"}, "Nodes Down" );
	print th( {class => "header", title => "Number of nodes down in the group"}, "Nodes Degraded" )
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );
	print th( {class => "header", title => "A single metric for the group of nodes"},        "Metric" );
	print th( {class => "header", title => "Group reachability (pingability) of the nodes"}, "Reachability" );
	print th( {class => "header", title => "The health of the group"},                       "Health" );

	print end_Tr;

	# no group selected? then produce the overall statistics
	if ( $AU->InGroup("network") and $group eq '' )
	{
		getSummaryStatsbyGroup( group => undef );    # fixme can that be removed or simplified or something?

		my $percentDown = 0;
		if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
		}
		my $classDegraded = "Normal";
		if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
		{
			$classDegraded = "Error";
		}

		print start_Tr,
			td(
			{class => "infolft $overallStatus"},
			a( {href => url( -absolute => 1 ) . "?act=network_summary_allgroups"}, $healthTitle ),
			);
		### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
		print td( {class => "info $overallStatus"},
			"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}" );
		print td( {class => "info $classDegraded"},
			"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}" )
			if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

		my @h = qw/metric reachable health/;
		foreach my $t (@h)
		{
			my $units = $t eq 'response' ? 'ms' : '%';
			my $value
				= $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );
			if ( $value == 100 ) { $value = 100 }
			my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} );
			$bg = "background-color:" . NMISNG::Util::colorResponseTime( $groupSummary->{average}{$t}, $C->{response_time_threshold} )
				if $t eq 'response';

			print
				start_td( {class => 'info Plain', style => "$bg"} ),
				img( {src => $C->{$icon{${t}}}} ),
				$value,
				"$units",
				end_td;
		}
		print end_Tr;
	}

	# now compute and print the stats for as many groups as allowed
	my $cutoff
		= NMISNG::Util::getbool( $Q->{unlimited} )
		? undef
		: $C->{network_summary_maxgroups} || 30;
	my @allowed = sort( grep( $AU->InGroup($_), keys %{$GT} ) );

	my $havetoomany = ( $C->{network_summary_maxgroups} || 30 ) < @allowed;
	splice( @allowed, $cutoff ) if ( defined($cutoff) && $cutoff < @allowed );
	foreach $group (@allowed)
	{
		next if ($group eq "");
	
		# fixme: the walk should be done JUST ONCE, not N times for N groups!
		# get all the stats and stuff the hashs
		getSummaryStatsbyGroup( group => $group );
		printGroupView($group);
	}
	if ($havetoomany)
	{
		my ( $otherstate, $msg )
			= NMISNG::Util::getbool( $Q->{unlimited} ) ? ( "false", "to hide extra groups" ) : ( "true", "for a full view" );

		$q->param( -name => "unlimited", -value => $otherstate );

		# url with -query doesn't include newly set params :-(
		my %fullparams = $q->Vars;
		print "<tr><td class='info Minor' colspan='$colspan'>Too many groups! <a href='"
			. url( -absolute => 1 ) . "?"
			. join( "&", map { uri_escape($_) . "=" . uri_escape( $fullparams{$_} ) } ( keys %fullparams ) )
			. "'>Click here</a> $msg.</td></tr>";
	}
	print end_table;

}

sub printGroupView
{
	my $group = shift;
	my $icon;
	my $not_allowed_chars_group = $C->{not_allowed_chars_group} // "[;=()<>'%\/]";
	
	my $idsafegroup = $group;
	$idsafegroup =~ s/$not_allowed_chars_group/_/g;    # spaces aren't allowed in id attributes!
	my $encoded_group = encode_entities($idsafegroup);

	print start_Tr,
		start_td( {class => "infolft $overallStatus"} );

	if ( $AU->InGroup($group) )
	{
		# force a new window if clicked
		print a(
			{   href => url( -absolute => 1 )
					. "?act=network_summary_group&refresh=$Q->{refresh}&widget=$widget&group=$encoded_group",
				id => "network_summary_$idsafegroup"
			},
			"$idsafegroup"
		);
	}
	else
	{
		print "$idsafegroup";
	}
	print end_td;

	# calc node down cell color as a % of node total
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
	}
	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$classDegraded = "Error";
	}

	#td({class=>"info $overallStatus"},$overallStatus),
	#td({class=>'info Plain'},"$groupSummary->{average}{counttotal}"),
	#td({class=>'info Plain'},"$groupSummary->{average}{countup}"),
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td( {class => "info $overallStatus"},
		"$groupSummary->{average}{countdown} of $groupSummary->{average}{counttotal}" );
	print td( {class => "info $classDegraded"},
		"$groupSummary->{average}{countdegraded} of $groupSummary->{average}{counttotal}" )
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	#my @h = qw/metric reachable available health response/;
	my @h = qw/metric reachable health/;
	foreach my $t (@h)
	{
		my $units = $t eq 'response' ? 'ms' : '%';
		my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );

		#my $value = sprintf("%.1f",$groupSummary->{average}{$t});
		if ( $value == 100 ) { $value = 100 }
		my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} ) . ';';
		$bg
			= "background-color:"
			. NMISNG::Util::colorResponseTime( $groupSummary->{average}{$t}, $C->{response_time_threshold} ) . ';'
			if $t eq 'response';

		$groupSummary->{average}{$t} = int( $groupSummary->{average}{$t} );
		print
			start_td( {class => 'info Plain', style => "$bg"} ),
			img( {src => $C->{$icon{${t}}}} ),
			$value,
			"$units" . end_td;
	}
	print end_Tr;
}    # end sub printGroup

sub printHealth
{
	my %args     = @_;
	my $customer = $args{customer};
	my $business = $args{business};
	my $not_allowed_chars_customer = $C->{not_allowed_chars_customer} // "[;=()<>%'\/]";
	my $not_allowed_chars_business = $C->{not_allowed_chars_business} // "[;=()<>%'\/]";
	
	my $idsafecustomer = $customer;
	$idsafecustomer =~ s/$not_allowed_chars_customer/_/g;    # spaces aren't allowed in id attributes!
	
	my $idsafebusiness = $business;
	$idsafebusiness =~ s/$not_allowed_chars_business/_/g;    # spaces aren't allowed in id attributes!
	
	my $icon;

	print start_Tr,
		start_td( {class => 'infolft Plain'} );

	#if ($AU->InGroup($group)) {
	# force a new window if clicked
	if ( $customer ne "" )
	{
		print a(
			{   href => url( -absolute => 1 )
					. "?act=network_summary_customer&refresh=$Q->{refresh}&widget=$widget&customer=$idsafecustomer",
				id => "network_summary_$idsafecustomer"
			},
			"$idsafecustomer"
		);
	}
	elsif ( $business ne "" )
	{
		print a(
			{   href => url( -absolute => 1 )
					. "?act=network_summary_business&refresh=$Q->{refresh}&widget=$widget&business=$idsafebusiness",
				id => "network_summary_$idsafebusiness"
			},
			"$idsafebusiness"
		);
	}

	#}
	#else {
	#	print "$customer";
	#}

	print end_td;

	# calc node down cell color as a % of node total
	my $percentDown = 0;
	if ( $groupSummary->{average}{countdown} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$percentDown = int( ( $groupSummary->{average}{countdown} / $groupSummary->{average}{counttotal} ) * 100 );
	}

	my $classDegraded = "Normal";
	if ( $groupSummary->{average}{countdegraded} > 0 and $groupSummary->{average}{counttotal} > 0 )
	{
		$classDegraded = "Error";
	}

	print
		td( {class => "info $overallStatus"}, $overallStatus ),
		td( {class => 'info Plain'},          "$groupSummary->{average}{counttotal}" );
	print td( {class => 'info Plain'}, "$groupSummary->{average}{countup}" )
		if ( not NMISNG::Util::getbool( $C->{display_status_summary} ) );
	### using overall node status in place of percentage colouring now, because in larger networks, small percentage down was green.
	print td( {class => "info $overallStatus"}, "$groupSummary->{average}{countdown}" );
	print td( {class => "info $classDegraded"}, "$groupSummary->{average}{countdegraded}" )
		if ( exists $C->{display_status_summary} and NMISNG::Util::getbool( $C->{display_status_summary} ) );

	my @h = qw/metric reachable available health response/;
	foreach my $t (@h)
	{

		my $units = $t eq 'response' ? 'ms' : '%';
		my $value = $t eq 'response' ? $groupSummary->{average}{$t} : sprintf( "%.1f", $groupSummary->{average}{$t} );

		#my $value = sprintf("%.1f",$groupSummary->{average}{$t});
		if ( $value == 100 ) { $value = 100 }
		my $bg = "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{average}{$t} ) . ';';
		$bg
			= "background-color:"
			. NMISNG::Util::colorResponseTime( $groupSummary->{average}{$t}, $C->{response_time_threshold} ) . ';'
			if $t eq 'response';

		$groupSummary->{average}{$t} = int( $groupSummary->{average}{$t} );
		print
			start_td( {class => 'info Plain', style => "$bg"} ),
			img( {src => $C->{$icon{${t}}}} ),
			$value,
			"$units" . end_td;
	}
	print end_Tr;
}    # end sub printCustomer

#============================
# Desc: network status by node, nodes listed by group,
# Menu: Large Network Status and Health
# url: network_summary_large -> select=large
# Title: Large Network Status and Health
# subtitle: {Group} Node list and Status
#============================'

sub selectLarge
{
	my %args     = @_;
	my $group    = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};

	my $NT = $network_status->get_nt();

	getSummaryStatsbyGroup(include_nodes => 1);
	my @headers = (
		'Node',   'SNMP Location', 'Type',         'Net',        'Role',   'Status',
		'Health', 'Reach',    'Intf. Avail.', 'Resp. Time', 'Outage', 'Esc.',
		'Last Collect'
	);

	my $CT;
	if ( $C->{network_health_view} eq "Customer" or $customer ne "" )
	{
		$CT = Compat::NMIS::loadGenericTable('Customers');
	}

	my $groupcount = 0;

	#print start_table,start_Tr,start_td({class=>'table',colspan=>'2',width=>'100%'});
	#print br if $select eq "large";
	print start_table( {class => 'dash', width => '100%'} );

	print Tr( th( {class => 'toptitle', colspan => '15'}, "Customer $customer Groups" ) )         if $customer ne "";
	print Tr( th( {class => 'toptitle', colspan => '15'}, "Business Service $business Groups" ) ) if $business ne "";

	foreach my $group ( sort keys %{$GT} )
	{
		# test if caller wanted stats for a particular group
		if ( $select eq "customer" )
		{
			next if $CT->{$customer}{groups} !~ /$group/;
		}
		elsif ( $select eq "group" )
		{
			next if $group ne $Q->{group};
		}

		++$groupcount;

		my $urlsafegroup = uri_escape($group);

		my $printGroupHeader = 1;
		foreach my $node ( sort { uc($a) cmp uc($b) } keys %{$NT} )
		{
			next if ( not $AU->InGroup($group) );
			if ( $group ne "" and $customer eq "" and $business eq "" )
			{
				next unless $NT->{$node}{group} eq $group;
			}
			elsif ( $customer ne "" )
			{
				next unless $NT->{$node}{customer} eq $customer and $NT->{$node}{group} eq $group;
			}
			elsif ( $business ne "" )
			{
				next unless $NT->{$node}{businessService} =~ /$business/ and $NT->{$node}{group} eq $group;
			}
			next unless NMISNG::Util::getbool( $NT->{$node}{active} );    # optional skip

			if ($printGroupHeader)
			{
				$printGroupHeader = 0;
				print Tr(
					th( {class => 'title', colspan => '15'},
						"$group Node List and Status",
						a(  {   style => "color:white;",
								href  => url( -absolute => 1 )
									. "?act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=exceptions"
							},
							"Node Admin Exceptions"
							)

					)
				);
				print Tr(
					eval {
						my $line;
						foreach my $h (@headers)
						{
							$line .= td( {class => 'header', align => 'center'}, $h );
						}
						return $line;
					}
				);
			}
			my $color;
			if ( NMISNG::Util::getbool( $NT->{$node}{active} ) )
			{
				if (    !NMISNG::Util::getbool( $NT->{$node}{ping} )
					and !NMISNG::Util::getbool( $NT->{$node}{collect} ) )
				{
					$color                                  = "#C8C8C8";    # grey
					$groupSummary->{$node}{health_color}    = $color;
					$groupSummary->{$node}{reachable_color} = $color;
					$groupSummary->{$node}{available_color} = $color;
					$groupSummary->{$node}{event_color}     = $color;
					$groupSummary->{$node}{health}          = '';
					$groupSummary->{$node}{reachable}       = '';
					$groupSummary->{$node}{available}       = '';
				}
				else
				{
					##$color = "#ffffff"; # white color
					$color = $groupSummary->{$node}{event_color};
				}
			}
			else
			{
				$color = "#aaaaaa";
			}

			my $outage = td( {class => 'info Plain'}, "" );
			my $S;										# may be needed for the both outage and escalate computation

			my $outagestatus = $groupSummary->{$node}->{outage};
			# checking outages is expensive, as it needs full node object to evaluate the context
			# see OMK-6206 for a possible improvement
			if (!defined($outagestatus) or $outagestatus !~ /^(none|current|pending)$/)
			{
				if (!$S)
				{
					$S = NMISNG::Sys->new(nmisng => $nmisng);
					$S->init(name => $node, snmp => 'false');
				}
				($outagestatus, undef) = NMISNG::Outage::outageCheck(node => $S->nmisng_node,
																														 time => time());
			}
			if ($outagestatus eq "current" or $outagestatus eq "pending")
			{
				my $color = ( $outagestatus eq "current" ) ? "#00AA00" : "#FFFF00";

				$outage = td( { class => 'info Plain'},
											a(  {href => "outages.pl?act=outage_table_view&node=$groupSummary->{$node}{name}&widget=$widget"},
													$outagestatus ));
			}

			my $escalate = '&nbsp;';
			# escalate, in nmis8 the escalate value of the node's 'node down' event if one such exists
			# see OMK-6207 for the future of this value
			# again expensive to compute on the fly
			if (defined($groupSummary->{$node}->{escalate})
					&& $groupSummary->{$node}->{escalate} ne '')
			{
				$escalate = $groupSummary->{$node}->{escalate};
			}
			else
			{
				if (!$S)
				{
					$S = NMISNG::Sys->new(nmisng => $nmisng);
					$S->init(name => $node, snmp => 'false');
				}
				my $downs = $S->nmisng_node->get_events_model(filter => { event => "Node Down", active => 1});
				if (!$downs->error && $downs->count)
				{
					$escalate = $downs->data->[0]->{escalate};
				}
			}

			# check lastcollect
			my $lastCollect      = "";
			my $colorlast       = $color;
			my $lastCollectClass = "info Plain nowrap";
			if (defined(my $time = $groupSummary->{$node}->{last_poll}))
			{
				$lastCollect = NMISNG::Util::returnDateStamp($time);
				if ( $time < ( time - 86400 ) ) # more than 1 day ago?
				{
					$colorlast       = "#ffcc00";
					$lastCollectClass = "info Plain Error nowrap";
				}
			}
			
			#Figure out the icons for each nodes metrics.
			my @h = qw/metric reachable available health response/;
			foreach my $t (@h)
			{
				# defaults
				#$icon{${t}} = 'arrow_down_black';

				if ( $groupSummary->{$node}{"${t}_dif"} + ( $C->{average_diff} )  >= 0 )
				{
					$icon{${t}} = ( $t eq "response" ) ? 'arrow_up_red' : 'arrow_up';
				}
				else
				{
					$icon{${t}} = ( $t eq "response" ) ? 'arrow_down_green' : 'arrow_down';
				}

				if ( $t ne "response" )
				{
					#Get some consistent formatting of the variable to be printed.
					$groupSummary->{$node}{$t} = sprintf( "%.1f", $groupSummary->{$node}{$t} );

					#Drop the .0 from 100.0
					if ( $groupSummary->{$node}{$t} == 100 ) { $groupSummary->{$node}{$t} = 100; }
					$groupSummary->{$node}{"$t-bg"}
						= "background-color:" . NMISNG::Util::colorPercentHi( $groupSummary->{$node}{$t} );
				}
			}

			# response time
			my $responsetime;
			if ( NMISNG::Util::getbool( $groupSummary->{$node}{ping} ) )
			{
				my $ms
					= ( $groupSummary->{$node}{response} ne '' and $groupSummary->{$node}{response} ne 'NaN' )
					? 'ms'
					: '';
				my $bg = "background-color:"
					. NMISNG::Util::colorResponseTime( $groupSummary->{$node}{response}, $C->{response_time_threshold} );
				$responsetime = td(
					{class => 'info Plain', align => 'right', style => $bg},
					img( {src => $C->{$groupSummary->{$node}{'response-icon'}}} ),
					"" . sprintf( "%.1f", $groupSummary->{$node}{response} ) . "$ms"
				);
			}
			else
			{
				$responsetime
					= td( {class => 'info Plain', align => 'right', style => NMISNG::Util::getBGColor($color)}, "disabled" );
			}
			my $nodelink;
			# ours or remotely-managed-but-opHA-transferred node?
			if ($NT->{$node}->{cluster_id} eq $C->{cluster_id})
			{
				# attention: this construction must match up with what commonv8.js's nodeInfoPanel() uses as id attrib!
				my $idsafenode = $node;
				$idsafenode = ( split( /\./, $idsafenode ) )[0];
				$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;

				$nodelink = a(
					{   href => url( -absolute => 1 )
							. "?act=network_node_view&refresh=$Q->{refresh}&widget=$widget&node="
							. uri_escape($node),
						id => "node_view_$idsafenode"
					},
					$NT->{$node}{name}
				);
			}
			else
			{
				my $remotes = $nmisng->get_remote(filter => {cluster_id => $NT->{$node}->{cluster_id} });
				# We are getting only one
				my $remote = @$remotes[0];

				# Get node from remote collection
				my $url = $remote->{url_base}."/".$remote->{nmis_cgi_url_base}."/network.pl?act=network_node_view&refresh=$Q->{refresh}&widget=false&node="
					. uri_escape($node);
				$nodelink = a( {
					target => "Graph-$node",
					onclick => "viewwndw(\'$node\',\'$url\',$C->{win_width},$C->{win_height} * 1.5)"},
					$NT->{$node}{name},
					img( {src => "$C->{'nmis_slave'}", alt => "NMIS Server $remote->{server_name}"}) );
			}

			my $statusClass = $groupSummary->{$node}{event_status};
			my $statusValue = $groupSummary->{$node}{event_status};

			if (    exists $C->{display_status_summary}
				and NMISNG::Util::getbool( $C->{display_status_summary} )
				and exists $groupSummary->{$node}{nodestatus}
				and $groupSummary->{$node}{nodestatus} )
			{
				$statusValue = $groupSummary->{$node}{nodestatus};
				if ( $groupSummary->{$node}{nodestatus} eq "degraded" )
				{
					$statusClass = "Error";
				}
				if ( $groupSummary->{$node}{nodestatus} eq "unreachable" )
				{
					$statusClass = "Critical";
				}
			}

			print Tr(
				td( {class => "infolft Plain $nodewrap"}, $nodelink ),
				td( {class => 'info Plain'},              $groupSummary->{$node}{sysLocation} ),
				td( {class => 'info Plain'},              $groupSummary->{$node}{nodeType} ),
				td( {class => 'info Plain'},              $groupSummary->{$node}{netType} ),
				td( {class => 'info Plain'},              $groupSummary->{$node}{roleType} ),
				td( {class => "info $statusClass"},       $statusValue ),
				td( {class => 'info Plain', style => $groupSummary->{$node}{'health-bg'}},
					img( {src => $C->{$groupSummary->{$node}{'health-icon'}}} ),
					$groupSummary->{$node}{health}, "%"
				),
				td( {class => 'info Plain', style => $groupSummary->{$node}{'reachable-bg'}},
					img( {src => $C->{$groupSummary->{$node}{'reachable-icon'}}} ),
					$groupSummary->{$node}{reachable},
					"%"
				),
				td( {class => 'info Plain', style => $groupSummary->{$node}{'available-bg'}},
					img( {src => $C->{$groupSummary->{$node}{'available-icon'}}} ),
					$groupSummary->{$node}{available},
					"%"
				),
				$responsetime,
				$outage,
				td( {class => 'info Plain'},     $escalate ),
				td( {class => $lastCollectClass}, "$lastCollect" )
			);
		}    # end foreach node
	}    # end foreach group
	if ( not $groupcount )
	{
		print Tr( th( {class => 'Error', colspan => '15'}, "You are not authorised for any groups" ) );
	}
	print end_table;
}    # end sub selectLarge

sub viewRunTime
{

	# $AU->CheckAccess, will send header and display message denying access if fails.
	if ( $AU->CheckAccess( "tls_nmis_runtime", "header" ) )
	{
		print header($headeropts);
		Compat::NMIS::pageStartJscript( title => "NMIS Run Time - $C->{server_name}" ) if ( !$wantwidget );
		print start_table( {class => 'dash'} );
		print Tr( th( {class => 'title'}, "NMIS Runtime Graph" ) );
		print Tr(
			td( {class => 'image'},
				Compat::NMIS::htmlGraph( graphtype => "nmis", node => "", intf => "", width => "600", height => "150" )
			)
		);
		print end_table;
	}
}    # viewRunTime

sub viewPollingSummary
{
	if ( $AU->CheckAccess( "tls_nmis_runtime", "header" ) )
	{
		my $sum = {};
		my $LNT = Compat::NMIS::loadLocalNodeTable();

		foreach my $node ( keys %{$LNT} )
		{
			++$sum->{count}{node};
			next if (! NMISNG::Util::getbool( $LNT->{$node}{active} ) );

			my $S    = NMISNG::Sys->new(nmisng => $nmisng);
			$S->init( name => $node, snmp => 'false' );
			my $catchall_data = $S->inventory( concept => 'catchall' )->data();

			++$sum->{count}{active};

			# nodeModel and nodeType are dynamic from catchall, rest are configuration items
			for my $item (qw(nodeModel nodeType))
			{
				++$sum->{$item}->{ $catchall_data->{$item} };
			}
			for my $item (qw(group roleType netType))
			{
				++$sum->{$item}->{  $LNT->{$node}->{$item} };
			}

			my $result = $S->nmisng_node->get_inventory_model(
				concept => 'interface', filter => { historic => 0 });
			if (!$result->error)
			{
				for my $oneif (@{$result->data})
				{
					my $ifentry = $oneif->{data}; # oneif is an inventory datastructure (but not object)
					# data area contains old-style info

					++$sum->{count}{interface};
					++$sum->{ifType}->{ $ifentry->{ifType} };
					if ( NMISNG::Util::getbool( $ifentry->{collect} ) )
					{
						++$sum->{count}{interface_collect};
					}
				}
			}

			# cbqos inventory is independent of interface
			my @cbqosdb = qw(cbqos-in cbqos-out);
			foreach my $cbqos (@cbqosdb)
			{
				my $result = $S->nmisng_node->get_inventory_model(
					concept => $cbqos,
					filter => { historic => 0 });
				if (!$result->error && $result->count)
				{
					++$sum->{count}{$cbqos};

					foreach my $oneclass (@{$result->data})
					{
						++$sum->{$cbqos}->{interface};
						# we want the number  of classes == same as number of subconcepts

						$sum->{$cbqos}->{classes} += scalar(@{$oneclass->{subconcepts}});
					}
				}
			}

			if ( NMISNG::Util::getbool( $LNT->{$node}{collect} ) )
			{
				++$sum->{count}{collect};
			}
			if ( NMISNG::Util::getbool( $LNT->{$node}{ping} ) )
			{
				++$sum->{count}{ping};
			}
		}

		print header($headeropts);
		Compat::NMIS::pageStartJscript( title => "NMIS Polling Summary - $C->{server_name}" ) if ( !$wantwidget );
		print start_table( {class => 'dash'} );
		print Tr( th( {class => 'title', colspan => '2'}, "NMIS Polling Summary" ) );
		print Tr( td( {class => 'heading3'}, "Node Count" ),    td( {class => 'rht Plain'}, $sum->{count}{node} ) );
		print Tr( td( {class => 'heading3'}, "active Count" ),  td( {class => 'rht Plain'}, $sum->{count}{active} ) );
		print Tr( td( {class => 'heading3'}, "collect Count" ), td( {class => 'rht Plain'}, $sum->{count}{collect} ) );
		print Tr( td( {class => 'heading3'}, "ping Count" ),    td( {class => 'rht Plain'}, $sum->{count}{ping} ) );
		print Tr( td( {class => 'heading3'}, "interface Count" ),
			td( {class => 'rht Plain'}, $sum->{count}{interface} ) );
		print Tr(
			td( {class => 'heading3'},  "interface collect Count" ),
			td( {class => 'rht Plain'}, $sum->{count}{interface_collect} )
		);
		print Tr( td( {class => 'heading3'}, "cbqos-in Count" ),
			td( {class => 'rht Plain'}, $sum->{count}{'cbqos-in'} ) );
		print Tr(
			td( {class => 'heading3'},  "cbqos-out Count" ),
			td( {class => 'rht Plain'}, $sum->{count}{'cbqos-out'} )
		);

		my @sumhead = qw(group nodeType netType roleType nodeModel ifType);
		foreach my $sh (@sumhead)
		{
			print Tr( td( {class => 'heading', colspan => '2'}, "Summary of $sh" ) );
			foreach my $item ( keys %{$sum->{$sh}} )
			{
				print Tr( td( {class => 'heading3'}, "$item Count" ),
					td( {class => 'rht Plain'}, $sum->{$sh}{$item} ) );
			}
		}

		my @cbqosdb;
		push( @cbqosdb, "cbqos-in" )  if $sum->{count}{'cbqos-in'};
		push( @cbqosdb, "cbqos-out" ) if $sum->{count}{'cbqos-out'};
		foreach my $cbqos (@cbqosdb)
		{
			print Tr( td( {class => 'heading', colspan => '2'}, "QoS Summary for $cbqos" ) );
			print Tr(
				td( {class => 'heading3'},  "$cbqos Interface Count" ),
				td( {class => 'rht Plain'}, $sum->{$cbqos}->{interface} )
			);
			print Tr(
				td( {class => 'heading3'},  "$cbqos Class Count" ),
				td( {class => 'rht Plain'}, $sum->{$cbqos}->{classes} )
			);
		}
		print end_table;
	}

}    # viewPollingSummary

# remove the selftest cache file, then refresh the whole nmis gui
# without that refresh, the js code picks up the wrong uri for the widget and
# every automatic refresh silently reruns the clear selftest :-/
sub clearSelfTest
{
	unlink( $C->{'<nmis_var>'} . "/nmis_system/selftest.json" );

	if ($wantwidget)
	{
		print header($headeropts),
			qq|<script type="text/javascript">window.location='$C->{nmis}?';</script>|;
	}
	else
	{
		# in non-widgetted mode a redirect is good enough
		print $q->redirect( url( -absolute => 1 ) . "?act=network_summary_metrics" );
	}
}

# show the full nmis self test
sub viewSelfTest
{
	# $AU->CheckAccess, will send header and display message denying access if fails.
	# using the same auth type as the nmis runtime graph
	if ( $AU->CheckAccess( "tls_nmis_runtime", "header" ) )
	{
		my $cachefile = $C->{'<nmis_var>'} . "/nmis_system/selftest.json";
		if ( -f $cachefile )
		{
			my $selfteststatus = NMISNG::Util::readFiletoHash( file => $cachefile, json => 'true' );
			$selfteststatus = { tests => [] } if (!ref($selfteststatus));

			print header($headeropts);
			Compat::NMIS::pageStartJscript( title => "NMIS Selftest - $C->{server_name}" ) if ( !$wantwidget );
			print start_table( {class => 'dash'} ), Tr( th( {class => 'title', colspan => '2'}, "NMIS Selftest" ) ),
				Tr( td( {class => "heading3"}, "Last Selftest" ),
				td( {class => "rht Plain"}, NMISNG::Util::returnDateStamp( $selfteststatus->{lastupdate} ) ) );
			my $anytrouble;
			for my $test ( @{$selfteststatus->{tests}} )
			{
				my ( $name, $message ) = @$test;
				print Tr( td( {class => "heading3"}, $name ),
					td( {class => "rht " . ( $message ? "Critical" : "Normal" )}, $message || "OK" ) );
				$anytrouble = 1 if ($message);
			}
			if ($anytrouble)
			{
				print Tr(
					td( {class => "info Major", colspan => 2},
						a(  {href => url( -absolute => 1 ) . "?act=nmis_selftest_reset&widget=$widget"},
							"Reset Selftest Status"
						)
					)
				);
			}
			print end_table;
		}
	}
}

sub viewMetrics
{

	my $group = $Q->{group};
	if ( $group eq "" )
	{
		$group = "network";
	}

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$group - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup($group) )
	{
		print 'You are not authorized for this request';
		return;
	}

	my $groupCode;
	my $groupOption;

	if ( $AU->InGroup("network") )
	{
		my $selected;
		if ( $group eq "network" )
		{
			$selected = " selected=\"$group\"";
		}
		$groupOption .= qq|<option value="network"$selected>Network</option>\n|;
	}

	foreach my $g ( sort (@groups) )
	{
		my $selected;
		my $escaped_group = encode_entities($g);
		if ( $Q->{group} eq $g )
		{
			$selected = " selected=\"$escaped_group\"";
		}
		
		$groupOption .= qq|<option value="$g"$selected>$escaped_group</option>\n|;
	}

	my $startform = start_form(
		{   action => "javascript:get('ntw_graph_form');",
			-id    => 'ntw_graph_form',
			-href  => "$C->{'<cgi_url_base>'}/network.pl?"
		}
	);
	my $submit = submit(
		-name   => 'ntw_graph_form',
		-value  => 'Go',
		onClick => "javascript:get('ntw_graph_form'); return false;"
	);
	if ( !$wantwidget )
	{
		$startform
			= start_form( {method => "get", -id => 'ntw_graph_form', action => "$C->{'<cgi_url_base>'}/network.pl"} );
		$submit = submit( -name => 'ntw_graph_form', -value => 'Go' );
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
	print start_table( {class => 'dash'} );
	print Tr( td( {class => 'heading'}, $groupCode ) );

	my $escaped_group = encode_entities($group);	
	print Tr(
		td( {class => 'image'},
			Compat::NMIS::htmlGraph(
				graphtype => "metrics",
				group     => "$escaped_group",
				node      => "",
				intf      => "",
				width     => "600",
				height    => "150"
			)
		)
	);
	print end_table;
	print "</form>\n";
}    # viewMetrics

sub viewNode
{
	my $node = $Q->{node};

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init( name => $node, snmp => 'false' );    # load node data
	my $nmisng_node = $S->nmisng_node;
	# don't print the not authorized msg if somebody has renamed the node
	if ( !$nmisng_node )
	{
		print "The requested node does not exist.";
		return;
	}

	my $configuration = $nmisng_node->configuration();

	if ( !$AU->InGroup($configuration->{group}) )
	{
		print "You are not authorized for this request! (group=$configuration->{group})";
		return;
	}

	# who is responsible for this node?
	# if no servers known, ignore any other server indications that you might find.
	# fixme9: server mode is nonfunctional at this time
	my $responsible = $C->{cluster_id};

	if ( $nmisng_node->cluster_id ne $responsible)
	{
		my $remotes = $nmisng->get_remote(filter => {cluster_id => $nmisng_node->cluster_id});
		my $wd = 850;
		my $ht = 700;
		# We are getting only one
		my $remote = @$remotes[0];

		# Get node from remote collection
		my $url = $remote->{url_base}."/".$remote->{nmis_cgi_url_base}."/network.pl?act=network_node_view&refresh=$C->{page_refresh_time}&widget=false&node="
			. uri_escape($node);
		my $nodelink = a( {target => "NodeDetails-$node", onclick => "viewwndw(\'$node\',\'$url\',$wd,$ht)"},
			$node );
		if ( defined $remote->{nmis_cgi_url_base} && defined $remote->{nmis_cgi_url_base} )
		{
			print "$nodelink is managed by server $remote->{server_name}";
		} else {
			print "$node is managed by server $remote->{server_name} <br>";
			print "<b>$remote->{server_name} url property</b> should be updated in opHA";
		}

		print <<EO_HTML;
	<script>
		viewwndw('$node','$url',$wd,$ht,'server');
	</script>
EO_HTML
		return;
	}

	my $catchall_data = $S->inventory( concept => 'catchall' )->data(); # r/o cloned copy
	my %status = $nmisng_node->precise_status;

	my $M = $S->mdl;

	# most node information comes from inventories (primarily the catchall)
	# or the node's configuration but not everything is to be shown,
	# and some things are decided dynamically as well

	my @defaultitems = qw(nodestatus outage sysName host_addr host_addr_backup
ip_protocol group customer location businessService serviceStatus notes
nodeType nodeModel polling_policy sysUpTime sysLocation
sysContact sysDescr ifNumber
last_ping last_poll last_update
nodeVendor sysObjectName roleType netType );

	# default or custom list from config?
	my @shouldshow = ($C->{network_viewNode_field_list} ne ""?
										split( /\s*,\s*/, $C->{network_viewNode_field_list} )
										: @defaultitems);

	# for every item we need at least a title and a value;
	# some values need coloring and preprocessing (e.g. numeric x/lat, url links etc).

	# first, collect the dynamic items and add them to the end of the list
	# cisco pix? failover info
	if ($catchall_data->{nodeModel} eq "CiscoPIX"
			&& (my $primary = $catchall_data->{pixPrimary})
			&& (my $secondary = $catchall_data->{pixSecondary}))
	{
		push @shouldshow, {
			title => "Failover Status",
			value => ($primary =~ /Failover Off/i)? "Failover Off": "Pri: $primary Sec: $secondary",
			color => ($primary =~ /Failover Off|Active/i
								and $secondary =~ /Failover Off|Standby/i)?
								"#00BB00"                            #normal
								: "#FFDD00"                           #warning
		};
	}

	# configuration change status available?
	if (defined(my $changecount = $catchall_data->{configChangeCount}))
	{
		push @shouldshow, {
			title => "Configuration change count",
			value => $changecount };
	}
	# three possible config change timestamps; titles via model
	for my $propname (qw(configLastChanged configLastSaved bootConfigLastChanged))
	{
		my $propval = $catchall_data->{$propname};
		if (defined($propval) && $propval != 0)
		{
			push @shouldshow, { title => $S->getTitle( attr => $propname, section => 'system') || $propname,
													value => NMISNG::Util::convUpTime( $propval / 100 ) };
		}
	}
	# and a status marker
	if (defined(my $lastchange = $catchall_data->{configLastChanged})
			&& defined(my $bootchanged = $catchall_data->{bootConfigLastChanged}))
	{
		my ($value, $color) = ( "Config Saved in NVRAM", "#00BB00");

		### when the router reboots bootConfigLastChanged = 0 and configLastChanged
		# is about 2 seconds, which are the changes made by booting.
		if ( $lastchange > $bootchanged and $lastchange > 5000 )
		{
			$value = "Config Not Saved in NVRAM";
			$color =  "#FFDD00";
		}
		elsif ( $bootchanged == 0 and $lastchange <= 5000 )
		{
			$value = "Config Not Changed Since Boot";
			$color = "#00BB00";                         #normal
		}

		push @shouldshow, { title => 'Configuration State',
												value => $value,
												color => $color };
	}

	# Check model specific values if collected
	my $possibles = $S->{mdl}->{'system'}->{'sys'};
	foreach my $key (keys %{$possibles}) 
	{
		foreach my $key2 (keys %{$possibles->{$key}->{'snmp'}}) {
			if (defined($catchall_data->{$key2}) and defined($possibles->{$key}->{'snmp'}->{$key2}->{'title'})
				 and !(grep { $key2 eq $_ } @shouldshow) and ($key2 ne "configLastChanged" and $key2 ne "configLastSaved"
															  and $key2 ne "bootConfigLastChanged")) {
				push @shouldshow, {
					title => $possibles->{$key}->{'snmp'}->{$key2}->{'title'},
					value => $catchall_data->{$key2}
				};	
			}
		}
	} 
	# second, collect values for the normal items and massage the ones in need
	# for some items the model has no title; configuration items are untitled as well, so hardcoded here
	my %untitled = ( node_status => "Node Status",
									 sysObjectName => 'Object Name',
									 nodeVendor => 'Vendor',
									 group => 'Group',
									 customer => 'Customer',
									 outage => "Outage Status",
									 location => 'Location',
									 businessService => 'Business Service',
									 serviceStatus => 'Service Status',
									 notes => 'Notes',
									 "host_addr" => "IP Address",
									 "host_addr_backup" => "Backup IP Address",
									 "polling_policy" => "Polling Policy",
									 "ip_protocol" => "IP Protocol",
									 timezone  => 'Time Zone',
									 nodeModel => 'Model',
									 nodeType => 'Type',
									 roleType => 'Role',
									 netType => 'Net',
			);


	for my $i (0..$#shouldshow)
	{
		my $propname = $shouldshow[$i];

		next if (ref $propname); # the custom ones are hashes already

		my $sourceval = $catchall_data->{$propname}; # may not be present

		# for a title also try the model or fall back to the raw property name
		my $sourcetitle = $untitled{$propname} || $S->getTitle( attr => $propname, section => 'system') || $propname;

		my %details;

		# some properties are special wrt. formatting and/or source
		if ($propname eq "host_addr" or $propname eq "host_addr_backup")
		{
			# title is static, value is dynamically generated or amended, color is state-driven
			my %confprop = ( "host_addr" => "host", "host_addr_backup" => "host_backup" );

			my $original = $configuration->{$confprop{$propname}};

			if (Net::IP::ip_is_ipv6($original))
			{
				$original = lc(Net::IP::ip_compress_address($original, 6));
			}

			$sourceval .= " ($original)" if ($original
																			 && $sourceval
																			 && $original ne $sourceval);
			$sourceval ||= $original;

			%details = ( title => $sourcetitle, value => $sourceval);

			# skip if n/a, color if state is known
			if ($propname eq "host_addr_backup")
			{
				if (!defined $sourceval)
				{
					%details = ();					# skip if not present
				}
				elsif (defined $status{failover_ping_status})
				{
					$details{color} = $status{failover_ping_status}? "#00ff00" : "#ff0000";
				}
			}
			else  # main addrss: color up if state is known - and select primary state tag if multihomed
			{
				my $source = defined($status{failover_status})? 'primary_ping_status' : 'ping_status';
				$details{color} = ($status{$source}? "#00ff00" : "#ff0000")
						if (defined $status{$source});
			}
		}
		elsif ($propname eq "nodestatus") {

			my %status2colors = ( -1 => "#FF0", 0 => "#f00", 1 => "#0f0" );
			my %status2value = ( -1 => "degraded", 0 => "unreachable", 1 => "reachable" );

			%details = ( title => $sourcetitle,
									 value => $status2value{ $status{overall} },
									 color => $status2colors{ $status{overall} } );
		}
		elsif ($propname eq 'outage')
		{
			# all info comes from outageCheck
			my ($outagestatus, $nextoutage) = NMISNG::Outage::outageCheck(node => $nmisng_node,
																																		time => time());
			# slightly special: don't show this row unless current or pending
			if (!$outagestatus)
			{
				%details = () 					# skip
			}
			else
			{
				%details = ( title => $sourcetitle );

				if ($outagestatus eq "current")
				{
				$details{value} = "Outage \"".($nextoutage->{change_id}
																			 || $nextoutage->{description})."\" is Current";
				$details{color} = NMISNG::Util::eventColor("Warning");
				}
				else
				{
					$details{value} = "Planned Future Outage \"".($nextoutage->{change_id} || $nextoutage->{description}).'"';
					# it's not active yet, let's show it as good/green/whatever
					$details{color} = NMISNG::Util::eventColor("Normal");
				}
			}
		}
		# comes from the last timed data for concept 'ping'
		elsif ($propname eq "last_ping")
		{
			%details = ( title => "Last Ping",
									 value => "Unknown" );

			my ($pinginv,$error) = $nmisng_node->inventory(concept => "ping");
			if (!$error && $pinginv)
			{
				my $mostrecent = $pinginv->get_newest_timed_data();
				if ($mostrecent->{success})
				{
					$details{value} = NMISNG::Util::returnDateStamp($mostrecent->{time});
				}
			}
		}
		# last_X as in last time for type=X operation, NOT db record updated!
		elsif ($propname =~ /^last_(update|poll)$/)
		{
			my $jobtype = $1;

			# returndatestamp(undef) == now, which would be really wrong
			$sourceval = defined($sourceval)? NMISNG::Util::returnDateStamp( $sourceval ) : "N/A";

			# check if a job of this type is scheduled 'real soon' or already in progress
			my $due_or_active = $nmisng->get_queue_model(
				type => $jobtype,
				time => { '$lt' => time + 30 }, # arbitrary choice
				"args.uuid" => [ $nmisng_node->uuid ],
				count => 1, limit => 0); # need a count, no data

			%details = ( title => "Last ".($jobtype eq "update"? "Update" : "Collect"),
									 value => $sourceval );

			if (defined $due_or_active && !$due_or_active->error && $due_or_active->query_count)
			{
				$details{value} .= "\n($jobtype in progress/pending)";
				$details{color} = "#ffcc00";
			}
		}
		elsif ( $propname eq 'TimeSinceTopologyChange')
		{
			%details = ( title => $sourcetitle
									 || $S->getTitle( attr => $propname, section => 'system')
									 || $propname,
									 value => $sourceval );

			if ($sourceval =~ /^\d+$/)
			{
				# convert to uptime format, time since change
				$details{value} = NMISNG::Util::convUpTime( $sourceval / 100 );

				# did this reset in the last 1 h
				$details{color} = "#ffcc00"
						if ( $sourceval / 100 < 360000 );
			}
		}
		# plain unadorned properties
		else
		{
			%details = ( title => $sourcetitle,
									 value => $sourceval );
		}

		# skip these if unconfigured
		if ($propname =~ /^(customer|businessService|serviceStatus|location)$/)
		{
			my %prop2table = (customer => "Customers", businessService => "BusinessServices",
												serviceStatus => "ServiceStatus", location => "Locations");
			%details = () if (!Compat::NMIS::tableExists($prop2table{$propname}));
		}

		# update the list with what we want to show - or mark as skippable
		$shouldshow[$i] = %details? \%details : undef;
	}

	# third, add service status list (with header) if services are monitored
	if (ref($configuration->{services}) eq "ARRAY" && @{$configuration->{services}})
	{
		push @shouldshow, { title => "Monitored Services",
												attributes => { colspan => 2, class => "header" } };

		my %servicestatus = Compat::NMIS::loadServiceStatus( node => $node );
		# only this system's services of relevance
		%servicestatus = %{$servicestatus{$C->{cluster_id}}} if (ref($servicestatus{$C->{cluster_id}}) eq "HASH");

		foreach my $servicename (sort keys %servicestatus)
		{
			next if (ref($servicestatus{$servicename}->{$node}) ne "HASH");
			my $thisservice = $servicestatus{$servicename}->{$node}; # the actual data

			push @shouldshow, { 'title' => "Service $servicename",
													'color' => ( $thisservice->{status} == 100 ?
																			 NMISNG::Util::colorPercentHi(100)
																			 : $thisservice->{status} > 0 ?
																			 'orange' : NMISNG::Util::colorPercentHi(0) ),

												 'value' => ( $thisservice->{status} == 100 ? 'running'
																			: $thisservice->{status} > 0 ? "degraded" : 'down',
  											 'url' => "$C->{'<cgi_url_base>'}/services.pl?act=details&widget=$widget&node="
																			. uri_escape($node)
																			. "&service="
																			. uri_escape($servicename)), };
		}
	}

	# fourth, show events for this one node - also close one if asked to
	my $eventsmodel = $nmisng_node->get_events_model();

	if ( !$eventsmodel->error && $eventsmodel->count )
	{
		push @shouldshow, { 'title' => "Events",
												attributes => { class => 'header', colspan => '2'} };

		my $usermayclose = $AU->CheckAccess( "src_events", "check" );
		my $closemeurl
				= url( -absolute => 1 )
				. "?act=network_node_view"
				. "&amp;widget=$widget"
				. "&amp;node="
				. uri_escape($node);

		for my $thisevent ( sort {$a->{event} cmp $b->{event}} @{$eventsmodel->data} )
		{
			# closing an event creates a temporary up event...we don't want to see that.
			next if ( $usermayclose && $thisevent->{details} =~ /^closed from GUI/ );

			# is this the event to close? same node, same name, element the same
			# fixme9: doing this here is pretty ugly logic-wise
			if ( $usermayclose
					 && $Q->{closeevent} eq $thisevent->{event}
					 && $Q->{closeelement} eq $thisevent->{element} )
			{
				Compat::NMIS::checkEvent(
					sys     => $S,
					node    => $node,
					event   => $thisevent->{event},
					element => $thisevent->{element},
					details => "closed from GUI",
					inventory_id => $thisevent->{inventory_id}
				);
				next;    # event is gone, don't show it
			}

			# offer a button for closing this event if the user is sufficiently privileged
			# fixme9: does currently NOT offer confirmation!
			my %showthis = ( title => "Event" );

			my $state = NMISNG::Util::getbool( $thisevent->{ack}, "invert" ) ? 'active' : 'inactive';
			my $details = $thisevent->{details};
			$details = "$thisevent->{element} $details" if ( $thisevent->{event} =~ /^Proactive|^Alert/ );
			$details = $thisevent->{element}            if ( !$details );

			$showthis{value} = "$thisevent->{event} - $details, Escalate $thisevent->{escalate}, $state";

			if ($usermayclose)
			{
				my $closethisurl = $closemeurl . "&amp;closeevent=" . uri_escape($thisevent->{event})
						. "&amp;closeelement=" . uri_escape($thisevent->{element});

				$showthis{title_asis} = 1; # no escaping please
				$showthis{title} = "Event" .
						qq|<a href='$closethisurl' title="Close this Event"><img src="$C->{'<menu_url_base>'}/img/v8/icons/note_delete.gif"></a>|;
			}
			push @shouldshow, \%showthis;
		}
	}

	# fifth, prep html
	my @firstcoldata;							# misnomer
	foreach my $one (grep(defined $_, @shouldshow))
	{
		# title, (required) value, color, title_asis, url, attributes (optional)
		my ($title, $color, $value) = @{$one}{"title","color","value"};
		# fixme9: skip untitled gunk or not?
		my $output;

		# escape the input if there's anything in need of escaping
		$title = escapeHTML($title) if ($title =~  /[<>&]/ && !$one->{title_asis}); # leave it as it is?

		# header entries are value-less
		if ($one->{attributes})
		{
			my $attrs = join(" ", map { qq|$_="$one->{attributes}->{$_}"| } (keys %{$one->{attributes}}));
			$output = qq|<tr><td $attrs>$title</td></tr>|;
		}
		else
		{
			$color = NMISNG::Util::getBGColor($color // '#FFF');

			$value = escapeHTML($value) if ( $value =~ /[<>&]/ );
			$value =~ s/\n/<br>/g;			# embedded newlines are supported
			$value = qq|<a href="$one->{url}">$value</a>| if ($one->{url}); # and so are links

			$output = qq|<tr><td class='info Plain'>$title</td>
<td class="info Plain" style="$color">$value</td></tr>|;
		}
		push @firstcoldata, $output;
	}

	# finally, start the actual output
	print Compat::NMIS::createHrButtons(
		node        => $node,
		system      => $S,
		refresh     => $Q->{refresh},
		widget      => $widget,
		conf        => $Q->{conf},
		AU          => $AU ),
			start_table( {class => 'dash'} );

	my $nodeDetails = ("Node Details - $node");
	if ( $AU->CheckAccessCmd("Table_Nodes_rw") )
	{
		my $url
			= "$C->{'<cgi_url_base>'}/tables.pl?act=config_table_edit&table=Nodes&widget=$widget&key="
			. uri_escape($node);
		$nodeDetails .= qq| - <a href="$url" id="cfg_nodes" style="color:white;">Edit Node</a>|;
	}

	if ( $AU->CheckAccessCmd("table_nodeconf_view") )
	{
		my $url = "$C->{'<cgi_url_base>'}/nodeconf.pl?act=config_nodeconf_view&widget=$widget&node="
			. uri_escape($node);
		$nodeDetails .= qq| - <a href="$url" id="cfg_nodecGfg" style="color:white;">Node Configuration</a>|;
	}

	# this will handle the Name and URL for additional node information
	if ( defined $configuration->{node_context_name}
			 and $configuration->{node_context_name} ne ""
			 and $configuration->{node_context_url} )
	{
		my $url = $configuration->{node_context_url};
		# substitute any known parameters
		$url =~ s/\$host/$configuration->{host}/g;
		$url =~ s/\$(name|node_name)/$node/g;

		$nodeDetails .= qq| - <a href="$url" target="context_$node" style="color:white;">$configuration->{node_context_name}</a>|;
	}

	# this will handle the Name and URL for remote management connection
	if ( defined $configuration->{remote_connection_name}
			 and $configuration->{remote_connection_name} ne ""
			 and $configuration->{remote_connection_url} )
	{
		my $url = $configuration->{remote_connection_url};
		# substitute any known parameters
		$url =~ s/\$host/$configuration->{host}/g;
		$url =~ s/\$(name|node_name)/$node/g;

		$nodeDetails .= qq| - <a href="$url" target="remote_$node" style="color:white;">$configuration->{remote_connection_name}</a>|;
	}

	print Tr( th( {class => 'title', colspan => '2'}, $nodeDetails ) ), start_Tr;

	# that's the property-value subtable
	print td(
		{valign => 'top'},
		table(
			{class => 'dash'},
			@firstcoldata ));

	# and that's where the kpi and graphs go
	print start_td( {valign => 'top'} ), start_table;

	#Adding KPI Analysis
	my $metricsFirstPeriod
		= defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod
		= defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";
	my $validKpiData = 0;

	if ( my $stats
		= Compat::NMIS::getSummaryStats( sys => $S, type => "health", start => $metricsFirstPeriod, end => time(), index => $node ) )
	{

		if ( $stats->{$node}{reachabilityHealth} and $stats->{$node}{availabilityHealth} )
		{
			# now get previous period stats
			my $reachabilityMax = 100 * $C->{weight_reachability};
			my $availabilityMax = 100 * $C->{weight_availability};
			my $responseMax     = 100 * $C->{weight_response};
			my $cpuMax          = 100 * $C->{weight_cpu};
			my $memMax          = 100 * $C->{weight_mem};
			my $intMax          = 100 * $C->{weight_int};
			my $swapMax         = 0;
			my $diskMax         = 0;

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

			my $statsPrev = Compat::NMIS::getSummaryStats(
				sys   => $S,
				type  => "health",
				start => $metricsSecondPeriod,
				end   => $metricsFirstPeriod,
				index => $node
			);
			if ( $statsPrev->{$node}{reachabilityHealth} !~ /NaN/ and $statsPrev->{$node}{reachabilityHealth} > 0 )
			{
				$reachabilityIcon
					= $stats->{$node}{reachabilityHealth} >= $statsPrev->{$node}{reachabilityHealth}
					? 'arrow_up.gif'
					: 'arrow_down.gif';
				$availabilityIcon
					= $stats->{$node}{availabilityHealth} >= $statsPrev->{$node}{availabilityHealth}
					? 'arrow_up.gif'
					: 'arrow_down.gif';
				$responseIcon
					= $stats->{$node}{responseHealth} >= $statsPrev->{$node}{responseHealth}
					? 'arrow_up.gif'
					: 'arrow_down.gif';
				$cpuIcon
					= $stats->{$node}{cpuHealth} >= $statsPrev->{$node}{cpuHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$memIcon
					= $stats->{$node}{memHealth} >= $statsPrev->{$node}{memHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$intIcon
					= $stats->{$node}{intHealth} >= $statsPrev->{$node}{intHealth} ? 'arrow_up.gif' : 'arrow_down.gif';
				$diskIcon
					= $stats->{$node}{diskHealth} >= $statsPrev->{$node}{diskHealth}
					? 'arrow_up.gif'
					: 'arrow_down.gif';
				$swapIcon
					= $stats->{$node}{swapHealth} >= $statsPrev->{$node}{swapHealth}
					? 'arrow_up.gif'
					: 'arrow_down.gif';
			}

			if ( $stats->{$node}{diskHealth} > 0 )
			{
				$stats->{$node}{diskHealth} =~ s/\.00//g;
				$intMax   = 100 * $C->{weight_int} / 2;
				$diskMax  = 100 * $C->{weight_int} / 2;
				$diskCell = td(
					{   class => 'info',
						style => NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{diskHealth} / $diskMax * 100 ) ),
						title => "The Disk KPI measures how much disk space is in use."
					},
					"Disk ",
					img({src => "$C->{'<menu_url_base>'}/img/$diskIcon", border => '0', width => '11', height => '10'}
					),
					"$stats->{$node}{diskHealth}/$diskMax"
				);
			}

			if ( $stats->{$node}{swapHealth} > 0 )
			{
				$stats->{$node}{swapHealth} =~ s/\.00//g;
				$memMax   = 100 * $C->{weight_mem} / 2;
				$swapMax  = 100 * $C->{weight_mem} / 2;
				$swapCell = td(
					{   class => "info",
						style => NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{swapHealth} / $swapMax * 100 ) ),
						title => "The Swap KPI increases with the Swap space in use."
					},
					"SWAP ",
					img({src => "$C->{'<menu_url_base>'}/img/$swapIcon", border => '0', width => '11', height => '10'}
					),
					"$stats->{$node}{swapHealth}/$swapMax"
				);
			}

			# only print the table if there is a value over 0 for reachability.
			if ( $stats->{$node}{reachabilityHealth} and $stats->{$node}{reachabilityHealth} !~ /NaN/ )
			{
				$validKpiData = 1;
				print start_Tr(), start_td(), start_table();
				print Tr(
					td( {   class   => 'header',
							colspan => '4',
							title =>
								"The KPI Scores are weighted from the Health Metric for the node, compared to the previous periods KPI's, the cell color indicates overall score and the arrow indicates if the KPI is improving or not."
						},
						"KPI Scores"
					)
				);

				print Tr(
					td( {   class => 'info',
							style => NMISNG::Util::getBGColor(
								NMISNG::Util::colorPercentHi( $stats->{$node}{reachabilityHealth} / $reachabilityMax * 100 )
							),
							title => "The Reachability KPI measures how well the node can be reached with ping."
						},
						"Reachability ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$reachabilityIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{reachabilityHealth}/$reachabilityMax"
					),
					td( {   class => 'info',
							style => NMISNG::Util::getBGColor(
								NMISNG::Util::colorPercentHi( $stats->{$node}{availabilityHealth} / $availabilityMax * 100 )
							),
							title => "Availability measures how many of the node's interfaces are available."
						},
						"Availability ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$availabilityIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{availabilityHealth}/$availabilityMax"
					),
					td( {   class => 'info',
							style =>
								NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{responseHealth} / $responseMax * 100 ) ),
							title => "The Response KPI decreases when the node's response time increases."
						},
						"Response ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$responseIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{responseHealth}/$responseMax"
					),
					td( {   class => 'info',
							style => NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{cpuHealth} / $cpuMax * 100 ) ),
							title => "The CPU utilisation KPI decreases when CPU load increases."
						},
						"CPU ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$cpuIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{cpuHealth}/$cpuMax"
					),
				);

				print Tr(
					td( {   class => 'info',
							style => NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{memHealth} / $memMax * 100 ) ),
							title => "Main memory usage KPI, decreases as the memory utilisation increases."
						},
						"MEM ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$memIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{memHealth}/$memMax"
					),
					td( {   class => 'info',
							style => NMISNG::Util::getBGColor( NMISNG::Util::colorPercentHi( $stats->{$node}{intHealth} / $intMax * 100 ) ),
							title =>
								"The  Interface utilisation KPI reduces when the global interfaces utilisation increases."
						},
						"Interface ",
						img({   src    => "$C->{'<menu_url_base>'}/img/$intIcon",
								border => '0',
								width  => '11',
								height => '10'
							}
						),
						"$stats->{$node}{intHealth}/$intMax"
					),
					$diskCell,
					$swapCell,
				);
				print end_table(), end_td(), end_Tr();
			}
		}
	}




        # are their any node graphs to display?  this covers serviceonly nodes and API only nodes better
        my @graphs = split /,/, $M->{system}{nodegraph};
	if (   NMISNG::Util::getbool( $catchall_data->{collect} )
		or NMISNG::Util::getbool( $catchall_data->{ping} ) 
		or @graphs
	) {
		my $GTT    = $S->loadGraphTypeTable();             # translate graphtype to type
		my $cnt    = 0;

		### 2014-08-27 keiths, insert the kpi graphtype if missing.
		if ( not grep { "kpi" eq $_ } (@graphs) )
		{
			my @newgraphs;
			foreach my $graph (@graphs)
			{
				if ( $graph eq "health" and $validKpiData )
				{
					push( @newgraphs, "kpi" );
				}
				push( @newgraphs, $graph );
			}
			@graphs = @newgraphs;
		}

		my $gotAltCpu = 0;

		foreach my $graph (@graphs)
		{
			my @pr;

			# check if database rule exists
			next unless $GTT->{$graph} ne '';
			next
					if $graph eq 'response'
					# fixme9 wrong, use node configuration not catchall
				and NMISNG::Util::getbool( $catchall_data->{ping}, "invert" );    # no ping done
			                                                     # first two or all graphs

			## display more graphs by default
			if (    $cnt == 3
				and !NMISNG::Util::getbool( $Q->{expand} )
				and NMISNG::Util::getbool( $catchall_data->{collect} )
				and NMISNG::Util::getbool( $C->{auto_expand_more_graphs}, "invert" ) )
			{
				if ( $#graphs > 1 )
				{
					# signal there are more graphs
					print Tr(
						td( {class => 'info Plain'},
							a(  {         href => url( -absolute => 1 )
										. "?act=network_node_view&expand=true&node="
										. uri_escape($node)
								},
								"More graphs"
							)
						)
					);
				}
				last;
			}
			$cnt++;

			# proces multi graphs, only push the hrsmpcpu graphs if there is no alternate CPU graph.
			if ( $graph eq 'hrsmpcpu' and not $gotAltCpu )
			{
				foreach my $index ( $S->getTypeInstances( graphtype => "hrsmpcpu" ) )
				{
					my $inventory = $S->inventory( concept => 'device', index => $index);
					my $data = ($inventory) ? $inventory->data() : {};
					push @pr, ["Server CPU $index ($data->{hrDeviceDescr})", "hrsmpcpu", "$index"]
						if $inventory;
				}
			}
			else
			{
				push @pr, [ $S->graphHeading(graphtype => $graph), $graph] if $graph ne "hrsmpcpu";
				if ( $graph =~ /(ss-cpu|WindowsProcessor)/ )
				{
					$gotAltCpu = 1;
				}
			}
			#### now print it
			foreach (@pr)
			{
				my $graph = $graphs->htmlGraph(
							graphtype => $_->[1],
							node      => $node,
							intf      => $_->[2],
							width     => $smallGraphWidth,
							height    => $smallGraphHeight
						);
				if ($graph !~ /Error/ ) {
					print Tr( td( {class => 'header'}, $_->[0] ) ),
					Tr(
					td( {class => 'image'},
					   $graph
					)
					); 
				}
				
			}
		}    # end for
	}
	elsif ( ref($configuration->{services}) eq "ARRAY" && @{$configuration->{services}} )
	{
		print Tr( td( {class => 'header'}, 'Monitored Services' ) );
		my %servicestatus = Compat::NMIS::loadServiceStatus( node => $node );
		# only this system's services of relevance
		%servicestatus = %{$servicestatus{$C->{cluster_id}}} if (ref($servicestatus{$C->{cluster_id}}) eq "HASH");

		foreach my $servicename (sort keys %servicestatus)
		{
			next if (ref($servicestatus{$servicename}->{$node}) ne "HASH");
			my $thisservice = $servicestatus{$servicename}->{$node}; # the actual data

			my $thiswidth = int( 2 / 3 * $smallGraphWidth );

			my $serviceurl
				= "$C->{'<cgi_url_base>'}/services.pl?act=details&widget=$widget&node="
				. uri_escape($node)
				. "&service="
				. uri_escape($servicename);
			my $color = $thisservice->{status} == 100 ? 'Normal' : $thisservice->{status} > 0 ? 'Warning' : 'Fatal';

			my $statustext = "$servicename";
			$statustext .= " - " . $thisservice->{status_text} if $thisservice->{status_text} ne "";
			# Force this. For some reason Model default is loaded. 
			$S->{mdl}{system}{nodeModel} = "Model-ServiceOnly";
			$S->loadModel( model => $S->{mdl}{system}{nodeModel} );

			print Tr( td( {class => "info Plain"}, a( {class => "islink", href => $serviceurl}, "$statustext" ) ), );
			print Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => "service",
							node      => $node,
							intf      => $servicename,
							width     => $thiswidth,
							height    => $smallGraphHeight,
							sys		  => $S
						),
						Compat::NMIS::htmlGraph(
							graphtype => "service-response",
							node      => $node,
							intf      => $servicename,
							width     => $thiswidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);

		}
	}
	else
	{
		print Tr( td( {class => 'info Plain'}, 'no Graph info' ) );
	}
	print end_table, end_td;

	print end_Tr, end_table;

	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub viewInterface
{
	my $intf = $Q->{intf};
	my $node = $Q->{node};

	my $S    = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;

	if ( !$nmisng_node )
	{
		print "The requested node does not exist.";
		return;
	}

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	if ( !$AU->InGroup( $catchall_data->{group}) )
	{
		print 'You are not authorized for this request.';
		return;
	}

	my $result = _load_interfaces(sys => $S, node => $nmisng_node, index => $intf);
	if ($result->{error} or ref($result->{interfaces}) ne "HASH" or !$result->{interfaces}->{$intf})
	{
		print "The requested interface does not exist.";
		return;
	}

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
			), start_table;

	my %status = $nmisng_node->precise_status;
	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => '2'}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				 if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning', colspan => '2'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print start_Tr;
	my $thisintf = $result->{interfaces}->{$intf};

	# these properties are shown first, then some (guessed) others
	# see OMK-5964 for a more solid approach
	my @wantedproperties = (qw(ifAdminStatus ifOperStatus ifDescr ifType ifPhysAddress Description
operAvail totalUtil ifSpeed ipAdEntAddr ifLastChange collect nocollect display_name escalate event threshold ifIndex));

	my %titles = _interface_property_titles($S->nmisng);
	for my $mebbe (keys %$thisintf)
	{
		push @wantedproperties, $mebbe
				if (!ref($thisintf->{$mebbe}) # no deep stuff
						&& $mebbe !~ /^nc_/				# no nodeconf 'original value'
						&& ($titles{$mebbe} ||= $S->getTitle(attr => $mebbe, section => "interface")) # and a title is known
						&& !grep($_ eq $mebbe, @wantedproperties)); # and only if not present
	}

	# fill in titles from the model where necessary
	for my $wanted (@wantedproperties)
	{
		$titles{$wanted} ||= $S->getTitle(attr => $wanted, section => "interface") || $wanted;
	}


	# first column, misnomer; subtable
	print qq|<td valign='top' width='50%'><table><tr><th class='title' colspan='2' width='50%'>Interface Details - ${node}::$thisintf->{ifDescr}</th></tr>|;

	for my $k (@wantedproperties)
	{
		my $color;
		my $title = $titles{$k};
		my $content = $thisintf->{$k};

		# massage special cases
		if ($k =~ /^if(Admin|Oper)Status$/)
		{
			$color = Compat::NMIS::getAdminColor(data => $thisintf) if (!defined $color);
		}
		elsif ($k eq "operAvail")
		{
			$color = Compat::NMIS::colorHighGood( $thisintf->{$k} ) if (!defined $color);
		}
		elsif ($k eq "totalUtil")
		{
			$color = Compat::NMIS::colorLowGood( $thisintf->{$k} ) if (!defined $color);
		}
		elsif ( $k eq 'ifSpeed')
		{
			# either the one and only, or in and out separately
			if ($thisintf->{ifSpeedIn} ne "" and $thisintf->{ifSpeedOut} ne "" )
			{
				$content  = "IN: ".NMISNG::Util::convertIfSpeed($thisintf->{ifSpeedIn})
						."<br/>OUT: ". NMISNG::Util::convertIfSpeed($thisintf->{ifSpeedOut});
			}
			else
			{
				$content  = NMISNG::Util::convertIfSpeed($thisintf->{ifSpeed});
			}
		}
		#0x002a14fffeeb352e
		#0x00cfda005ebf
		elsif ( $k eq 'ifPhysAddress' and $thisintf->{ifPhysAddress} =~ /^0x[0-9a-f]+$/i )
		{
			$content = NMISNG::Util::beautify_physaddress( $thisintf->{ifPhysAddress} );
		}
		elsif ( $k eq "ifLastChange" )
		{
			$content = NMISNG::Util::convUpTime( $catchall_data->{sysUpTimeSec} - $thisintf->{ifLastChangeSec} );
		}
		elsif ($k eq "ipAdEntAddr")
		{
			$content = "";
			my $cnt = 1;
			while ( defined( $thisintf->{"ipAdEntAddr$cnt"} ) and defined( $thisintf->{"ipAdEntNetMask$cnt"} ) )
			{
				if ($thisintf->{"ipAdEntAddr$cnt"} ne "" and $thisintf->{"ipAdEntNetMask$cnt"} ne "")
				{
					$content += "<br/>" if ($content ne "");
					my $int = $thisintf->{"ipAdEntAddr$cnt"};
					my $mask = $thisintf->{"ipAdEntNetMask$cnt"};
					$content += "$int/$mask";
				}
				$cnt++;
			}
		}

		print qq|<tr><td class='info Plain'>$title</td><td class='info Plain' style="|
				.NMISNG::Util::getBGColor($color || "#fff").qq|">$content</td></tr>|;
	}
	print qq|</table></td>|;

	# second column, graphs
	print start_td( {valign => 'top', width => '500px'} ), start_table;

	# we show *all* interfaces where the standard autil/abits graphs exist,
	# regardless of current collection status.
	if (exists($thisintf->{collect})
			&& -f (my $dbname = $S->makeRRDname( graphtype => "autil", index => $intf, suppress_errors => 1 ) ))
	{
		print Tr( td( {class => 'header'}, "Utilization" ) ),
		Tr(
			td( {class => 'image'},
					Compat::NMIS::htmlGraph(
						graphtype => "autil",
						node      => $node,
						intf      => $intf,
						width     => $smallGraphWidth,
						height    => $smallGraphHeight,
						sys		  => $S
					)
			)
				),
			Tr( td( {class => 'header'}, "Bits per second" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => "abits",
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
			);
		if ( grep( $_ eq $intf, $S->getTypeInstances( graphtype => 'pkts2' ) ) )
		{
			print Tr( td( {class => 'header'}, "Packets per second" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'pkts2',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}
		elsif ( grep( $_ eq $intf, $S->getTypeInstances( graphtype => 'pkts_hc' ) ) )
		{
			print Tr( td( {class => 'header'}, "Packets per second" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'pkts_hc',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}
		### 2014-10-23 keiths, added this to display by default for interfaces.
		if ( grep( $_ eq $intf, $S->getTypeInstances( graphtype => 'errpkts2' ) ) )
		{
			print Tr( td( {class => 'header'}, "Errors and Discards" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'errpkts2',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}
		elsif ( grep( $_ eq $intf, $S->getTypeInstances( graphtype => 'errpkts_hc' ) ) )
		{
			print Tr( td( {class => 'header'}, "Errors and Discards" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'errpkts_hc',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}

		if ( grep( $_ eq $intf, $S->getTypeInstances( section => 'cbqos-in' ) ) )
		{
			print Tr( td( {class => 'header'}, "CBQoS in" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'cbqos-in',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}

		if ( grep( $_ eq $intf, $S->getTypeInstances( section => 'cbqos-out' ) ) )
		{
			print Tr( td( {class => 'header'}, "CBQoS out" ) ),
			Tr(
				td( {class => 'image'},
						Compat::NMIS::htmlGraph(
							graphtype => 'cbqos-out',
							node      => $node,
							intf      => $intf,
							width     => $smallGraphWidth,
							height    => $smallGraphHeight,
							sys		  => $S
						)
				)
					);
		}
	}
	else
	{
		print Tr( td( {class => 'info Plain'}, 'No graph info' ) );
	}
	print end_table, end_td, end_Tr, end_table;

	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

# small helper that preps a hash of interface data
# args: sys, node object, activeonly, index (if index present, then only that interface is loaded)
# returns: hashref with (error, interfaces, propertynames)
sub _load_interfaces
{
	my (%args) = @_;

	my ($S, $nmisng_node, $activeonly, $indexonly) = @args{"sys","node","activeonly","index"};

	# load all of this node's non-historic interfaces, maybe only enabled ones
	# or, if index is given, load only that one interface
	my $allintfs = $nmisng_node->get_inventory_model(concept => 'interface',
																									 filter => { enabled => $activeonly? 1:undef, historic => 0 },
																									 path => (defined($indexonly)?
																														$nmisng_node->inventory_path(concept => 'interface',
																																												 data => { index => $indexonly },
																																												 partial => 1 )
																														: undef) )->objects;
	return { error => "Failed to lookup or instantiate inventory: $allintfs->{error}" }
	if (!$allintfs->{success});

	my (%view, # index -> item = something
			%seenproperties);

	for my $ifinventory (@{$allintfs->{objects}})
	{
		my $thisdata = $ifinventory->data;
		my $ifindex = $thisdata->{ifIndex};

		# copy everything the inventory holds...
		for my $knownthing (keys %{$thisdata})
		{
			$seenproperties{$knownthing} ||= 1;

			# blank out unknown and nosuch values
			$view{$ifindex}->{$knownthing} = ($thisdata->{$knownthing} =~ /noSuch|unknown/i?
																				"" : $thisdata->{$knownthing});
		}

		# ...also get the escalation status
		if ( NMISNG::Util::getbool($thisdata->{event}))
		{
			$seenproperties{escalate} ||= 1;

			my ($error, $erec) = $nmisng_node->eventLoad(
				event => "Interface Down",
				element => $thisdata->{ifDescr},
				# don't pass this in yet because if we do it will try and filter and may not be set so worn't work
				# inventory_id => $inventory->id,
				active => 1
					);
			$view{$ifindex}->{escalate} = (!$error && ref($erec) eq "HASH" && defined($erec->{escalate}))?
					$erec->{escalate} : "none";
		}

		# ...and get the availability and utilisation
		my $period = $S->nmisng->config->{interface_util_period} || "-6 hours";    # bsts plus backwards compat
		if (ref(my $interface_util_stats = Compat::NMIS::getSubconceptStats(sys => $S,
																																				inventory => $ifinventory,
																																				subconcept => 'interface',
																																				start => $period,
																																				end => time))
				eq "HASH")
		{
			$seenproperties{operAvail} ||= 1;
			$seenproperties{totalUtil} ||= 1;

			$view{$ifindex}->{operAvail} = $interface_util_stats->{availability};
			$view{$ifindex}->{totalUtil} = $interface_util_stats->{totalUtil};
		}
	}

	return { interfaces => \%view, propertynames => \%seenproperties };
}

# some properties are titled via model, others are hardcoded here and only here
sub _interface_property_titles
{
	my ($nmisng) = @_;

	return ( ipAdEntAddr => 'IP address / mask',
					 display_name => "Display Name",
					 event => 'Event on',
					 threshold => 'Threshold on',
					 collect => 'Collect on',
					 nocollect => 'Reason',
					 ifIndex => 'ifIndex',
					 operAvail => 'Intf. Avail.',
					 escalate => 'Esc.',
					 totalUtil => ($nmisng->config->{interface_util_label} || 'Util. 6hrs'),
			);
}

sub viewAllIntf
{
	my %args   = @_;
	my $activeonly = NMISNG::Util::getbool($Q->{active});    # flag for only active interfaces to display

	my $node = $Q->{node};
	my $sort = $Q->{sort} || 'ifDescr';
	my $dir = !$Q->{dir}? 'fwd' : $Q->{dir} eq "rev"? "fwd": "rev";	# default fwd, othwerwise show inverse

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	my $S = NMISNG::Sys->new(nmisng => $nmisng);                                                 # get system object
	$S->init( name => $node, snmp => 'false' );                         # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;

	if ( !$nmisng_node )
	{
		print "The requested node does not exist.";
		return;
	}

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	if (!$AU->InGroup($catchall_data->{group}))
	{
		print 'You are not authorized for this request';
		return;
	}


	# selection and order of columns
	# note that columns are skipped if the property is n/a for all interfaces of a node
	my @wantedcols = (qw(ifDescr Description display_name
ifAdminStatus ifOperStatus operAvail totalUtil
ifSpeed ifPhysAddress ifLastChange collect ifIndex
portDuplex portSpantreeFastStart vlanPortVlan
escalate ));
	# ditch the active column for the 'active interface' view
	@wantedcols = grep($_ ne 'collect', @wantedcols) if ($activeonly);


	# fill in titles from the model where necessary
	my %titles = _interface_property_titles($S->nmisng);
	for my $wanted (@wantedcols)
	{
		$titles{$wanted} ||= $S->getTitle(attr => $wanted, section => "interface");
	}

	my $result = _load_interfaces(node => $nmisng_node, sys => $S, activeonly => $activeonly);
	if ($result->{error})
	{
		print $result->{error};
		return;
	}
	my $view = $result->{interfaces};

	# now remove columns where none of the interfaces has that property
	@wantedcols = grep($result->{propertynames}->{$_}, @wantedcols);

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	), start_table;

	my %status = $nmisng_node->precise_status;
		if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical'}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print Tr( th( {class => 'title', width => '100%'}, "Interface Table of node $node" ) ),
	start_Tr, start_td, start_table;

	# print header row
	print "<tr>";
	if (@wantedcols > 0)
	{
		for my $col (@wantedcols)
		{
			my $headertitle = $titles{$col};
			$headertitle =~ s/\s*\(.*//; 		# ditch any parenthesised title parts
			print qq|<td class="header" align="center"><a href="|
					. url(-absolute => 1)."?act=network_interface_view_all&refresh=$Q->{refresh}&widget=$widget&sort=$col&dir=$dir&active=$Q->{active}&node=". uri_escape($node).  qq|">$headertitle</a></td>|;
		}
    }
    elsif ($catchall_data->{ifNumber} > $interface_max_number)
    {
            print qq|<td class="header" align="center">Interface count ($catchall_data->{ifNumber}) exceeds configured 'interface_max_number' value, no interfaces will be discovered.</td>|;
    }
	print "</tr>";


	# print data, after massaging/filling in certain fields
	foreach my $intf ( NMISNG::Util::sorthash( $view, [$sort], $dir ) )
	{
		my $thisintf = $view->{$intf};
		print "<tr>";

		foreach my $k (@wantedcols)
		{
			# disabled interface gets grey background
			my $color;
			$color = "#cccccc" if (!NMISNG::Util::getbool($thisintf->{collect}));

			my $content = $thisintf->{$k};
			# massage these special cases
			if ( $k eq 'ifDescr' )
			{
				$content = qq|<a href="|. url( -absolute => 1 )
						. "?act=network_interface_view&refresh=$Q->{refresh}&widget=$widget&intf=$intf&node="
						. uri_escape($node) .qq|">$content</a>|;
			}
			elsif ($k =~ /^if(Admin|Oper)Status$/)
			{
				$color = Compat::NMIS::getAdminColor(data => $thisintf) if (!defined $color);
			}
			elsif ($k eq "operAvail")
			{
				$color = Compat::NMIS::colorHighGood( $thisintf->{$k} ) if (!defined $color);
			}
			elsif ($k eq "totalUtil")
			{
				$color = Compat::NMIS::colorLowGood( $thisintf->{$k} ) if (!defined $color);
			}
			elsif ( $k eq 'Description' )
			{
				$content = "$thisintf->{Description}";
				my $cnt = 1;
				while ( defined( $thisintf->{"ipAdEntAddr$cnt"} ) and defined( $thisintf->{"ipAdEntNetMask$cnt"} ) )
				{
				    my $addr = $thisintf->{"ipAdEntAddr$cnt"};
				    my $mask = $thisintf->{"ipAdEntNetMask$cnt"};
					if ($addr ne "" and $mask ne "")
					{
						$content .= "<br/>" if ($content ne "");
						$content .= "${addr}/${mask}";
					}
					$cnt++;
				}
			}
			elsif ( $k eq 'ifSpeed')
			{
				# either the one and only, or in and out separately
				if ($thisintf->{ifSpeedIn} ne "" and $thisintf->{ifSpeedOut} ne "" )
				{
					$content  = "IN: ".NMISNG::Util::convertIfSpeed($thisintf->{ifSpeedIn})
							."<br/>OUT: ". NMISNG::Util::convertIfSpeed($thisintf->{ifSpeedOut});
				}
				else
				{
					$content  = NMISNG::Util::convertIfSpeed($thisintf->{ifSpeed});
				}
			}
			#0x002a14fffeeb352e
			#0x00cfda005ebf
			elsif ( $k eq 'ifPhysAddress' and $thisintf->{ifPhysAddress} =~ /^0x[0-9a-f]+$/i )
			{
				$content = NMISNG::Util::beautify_physaddress( $thisintf->{ifPhysAddress} );
			}
			elsif ( $k eq "ifLastChange" )
			{
				$content = NMISNG::Util::convUpTime( $catchall_data->{sysUpTimeSec} - $thisintf->{ifLastChangeSec} );
			};

			print qq|<td class="info Plain" style="| . NMISNG::Util::getBGColor($color // "#fff")
					. qq|">$content</td>|;
		}
		print "</tr>";
	}
	print end_table, end_td, end_Tr, end_table;

	Compat::NMIS::pageEnd() if ( !$wantwidget );

}

sub viewActiveIntf
{
	$Q->{active} = 'true';
	viewAllIntf();
}

sub viewActivePort
{
	my $node = $Q->{node};
	my $sort = $Q->{sort} || 'ifDescr';
	my $dir = !$Q->{dir}? 'fwd' : $Q->{dir} eq "rev"? "fwd": "rev";	# default fwd, othwerwise show inverse

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	my $S = NMISNG::Sys->new(nmisng => $nmisng);                                                 # get system object
	$S->init( name => $node, snmp => 'false' );                         # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;

	if ( !$nmisng_node )
	{
		print "The requested node does not exist.";
		return;
	}

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	if (!$AU->InGroup($catchall_data->{group}))
	{
		print 'You are not authorized for this request';
		return;
	}


	my @wantedcols = (qw(ifDescr Description display_name ifAdminStatus ifOperStatus operAvail totalUtil));
	# fill in titles from the model where necessary
	my %titles = _interface_property_titles($S->nmisng);
	for my $wanted (@wantedcols)
	{
		$titles{$wanted} ||= $S->getTitle(attr => $wanted, section => "interface" );
	}

	my $result = _load_interfaces(node => $nmisng_node, sys => $S, activeonly => 1);
	if ($result->{error})
	{
		print $result->{error};
		return;
	}
	my $view = $result->{interfaces};
	# now remove columns where none of the interfaces has that property
	@wantedcols = grep($result->{propertynames}->{$_}, @wantedcols);



	my $graphtype = $Q->{graphtype} || $C->{default_graphtype};

	# the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form( -id => "nmis", -href => url( -absolute => 1 ) . "?" )
		. hidden( -override => 1, -name => "conf",   -value => $Q->{conf} )
		. hidden( -override => 1, -name => "act",    -value => "network_port_view" )
		. hidden( -override => 1, -name => "widget", -value => $widget )
		. hidden( -override => 1, -name => "node",   -value => $node );

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	), start_table;

	my %status = $nmisng_node->precise_status;
	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical'}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print Tr( th( {class => 'title', width => '100%'}, "Interface Table of node $catchall_data->{name}" ) );


	my $M = $S->mdl;
	# offer graph types from model...
	my @graphtypes = ('');
	foreach my $im ('interface', 'pkts_hc', 'pkts' )
	{
		if (ref($M->{interface}->{rrd}->{$im}) eq "HASH")
		{
			push @graphtypes, split(/\s*,\s*/, $M->{interface}->{rrd}->{$im}->{graphtype});
		}
	}
	# ...plus cbqos if a/v
	for my $section ("cbqos-in","cbqos-out")
	{
		push @graphtypes, $section if ($S->getTypeInstances(section => $section));
	}

	# print header row
	print "<tr><td><table><tr>";
	for my $col (@wantedcols)
	{
		my $headertitle = $titles{$col};
		$headertitle =~ s/\s*\(.*//; 		# ditch any parenthesised title parts
		print qq|<td class="header" align="center"><a href="|
				. url(-absolute => 1)."?act=network_port_view&refresh=$Q->{refresh}&widget=$widget&sort=$col&dir=$dir&graphtype=$graphtype&node=". uri_escape($node).  qq|">$headertitle</a></td>|;
	}

	print qq|<td class='header' align='center'>|,
	popup_menu(
		-name    => "graphtype",
		-values  => \@graphtypes,
		-default => $graphtype,
		onchange => $wantwidget ? "get('nmis');" : 'submit();'
			), qq|</td></tr>|;


	# print data, after massaging/filling in certain fields
	foreach my $intf ( NMISNG::Util::sorthash( $view, [$sort], $dir ) )
	{
		next if ($graphtype =~ /cbqos/
						 and !grep($intf eq $_, $S->getTypeInstances(section => $graphtype)));

		my $thisintf = $view->{$intf};
		print "<tr>";

		foreach my $k (@wantedcols)
		{
			# disabled interface gets grey background
			my $color;
			$color = "#cccccc" if (!NMISNG::Util::getbool($thisintf->{collect}));

			my $content = $thisintf->{$k};
			# massage these special cases
			if ( $k eq 'ifDescr' )
			{
				$content = qq|<a href="|. url( -absolute => 1 )
						. "?act=network_interface_view&refresh=$Q->{refresh}&widget=$widget&intf=$intf&node="
						. uri_escape($node) .qq|">$content</a>|;
			}
			elsif ($k =~ /^if(Admin|Oper)Status$/)
			{
				$color = Compat::NMIS::getAdminColor(data => $thisintf) if (!defined $color);
			}
			elsif ($k eq "operAvail")
			{
				$color = Compat::NMIS::colorHighGood( $thisintf->{$k} ) if (!defined $color);
			}
			elsif ($k eq "totalUtil")
			{
				$color = Compat::NMIS::colorLowGood( $thisintf->{$k} ) if (!defined $color);
			}
			elsif ($k eq 'Description')
			{
				$content = "$thisintf->{Description}";
				my $cnt = 1;
				while ( defined( $thisintf->{"ipAdEntAddr$cnt"} ) and defined( $thisintf->{"ipAdEntNetMask$cnt"} ) )
				{
				    my $addr = $thisintf->{"ipAdEntAddr$cnt"};
				    my $mask = $thisintf->{"ipAdEntNetMask$cnt"};
					if ($addr ne "" and $mask ne "")
					{
						$content .= "<br/>" if ($content ne "");
						$content .= "${addr}/${mask}";
					}
					$cnt++;
				}
			}

			print qq|<td class="info Plain" style="| . NMISNG::Util::getBGColor($color // "#fff")
					. qq|">$content</td>|;
		}

		if ($S->makeRRDname(
					graphtype       => $graphtype,
					index           => $intf,
					suppress_errors => 'true'
				)
				or $graphtype =~ /cbqos/)
		{
			print qq|<td class='image' colspan="2">|,
			Compat::NMIS::htmlGraph(
				graphtype => $graphtype,
				node      => $node,
				intf      => $intf,
				width     => $smallGraphWidth,
				height    => $smallGraphHeight,
				sys		  => $S
					), qq|</td>|;
		}
		else
		{
			print qq|<td class="info Plain" colspan="2">no data available</td>|;
		}
		print "</tr>";
	}
	print "</table></td></tr></table></form>";
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub viewStorage
{

	my $node = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();


	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $catchall_data->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}

	my %status = $nmisng_node->precise_status;

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	);

	print start_table( {class => 'table'} );

	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => '3'}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				 if (defined($status{failover_ping_status}) && !$status{failover_ping_status});


		print Tr(
			td( {class => 'Warning', colspan => '3'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print Tr( th( {class => 'title', colspan => '3'}, "Storage of node $catchall_data->{name}" ) );

	my $ids = $S->nmisng_node->get_inventory_ids( concept => 'storage',
																								filter => { historic => 0, enabled => 1 } );
	foreach my $id ( @$ids )
	{
		my ($inventory,$error_message) = $S->nmisng_node->inventory( _id => $id );
		my $D         = $inventory->data();
		my $graphtype = $D->{hrStorageGraph};
		my $index     = $D->{hrStorageIndex};

		my $total = $D->{hrStorageUnits} * $D->{hrStorageSize};
		my $used  = $D->{hrStorageUnits} * $D->{hrStorageUsed};

		my $util = sprintf( "%.1f%", $used / $total * 100 );

		my $rowSpan = 5;
		$rowSpan = 6 if defined $D->{hrFSRemoteMountPoint};
		print start_Tr;
		print Tr(
			td( {class => 'header'}, 'Type' ),
			td( {class => 'info header', width => '40%'}, $D->{hrStorageType} ),
			td( {class => 'header'}, $D->{hrStorageDescr} )
		);
		print Tr(
			td( {class => 'header'},     'Units' ),
			td( {class => 'info Plain'}, $D->{hrStorageUnits} ),
			td( {class => 'image', rowspan => $rowSpan},
				Compat::NMIS::htmlGraph(
					graphtype => $graphtype,
					node      => $node,
					intf      => $index,
					width     => $smallGraphWidth,
					height    => $smallGraphHeight
				)
			)
		);
		print Tr( td( {class => 'header'}, 'Size' ), td( {class => 'info Plain'}, $D->{hrStorageSize} ) );

		# disks use crazy multiples to display MB, GB, etc.
		print Tr( td( {class => 'header'}, 'Total' ), td( {class => 'info Plain'}, NMISNG::Util::getDiskBytes($total) ) );
		print Tr( td( {class => 'header'}, 'Used' ), td( {class => 'info Plain'}, NMISNG::Util::getDiskBytes($used), "($util)" ) );
		print Tr( td( {class => 'header'}, 'Description' ), td( {class => 'info Plain'}, $D->{hrStorageDescr} ) );
		print Tr( td( {class => 'header'}, 'Mount Point' ), td( {class => 'info Plain'}, $D->{hrFSRemoteMountPoint} ) )
			if defined $D->{hrFSRemoteMountPoint};

		print end_Tr;
	}
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

# show one node's monitored services, name, status and small graphs
# args: q's node
sub viewService
{
	my $node = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	# Force this. For some reason Model default is loaded. 
	$S->{mdl}{system}{nodeModel} = "Model-ServiceOnly";
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	my $configuration = $nmisng_node->configuration();

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $catchall_data->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}

	my %status = $nmisng_node->precise_status;

	# get the current service status for this node
	my %sstatus = Compat::NMIS::loadServiceStatus( node => $node );

	# structure is cluster_id -> service -> node -> data, we don't want the outer layer
	%sstatus = %{$sstatus{$C->{cluster_id}}} if ( ref( $sstatus{$C->{cluster_id}} ) eq "HASH" );

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	);
	print start_table( {class => 'table'} );

	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => '3'}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				 if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning', colspan => '3'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print Tr( th( {class => 'title', colspan => '3'}, "Monitored services on node $catchall_data->{name}" ) );

	# for the type determination
	my $ST = Compat::NMIS::loadGenericTable("Services");

	if ( my @servicelist = ref($configuration->{services}) eq "ARRAY"? @{$configuration->{services}} : () )
	{
		print Tr(
			td( {class => 'header'}, "Service" ),
			td( {class => 'header'}, "Status" ),
			td( {class => 'header'}, "History" )
		);

		# that's names
		foreach my $servicename ( sort @servicelist )
		{
			my $thisservice = $sstatus{$servicename}->{$node};

			my $color = $thisservice->{status} == 100 ? 'Normal' : $thisservice->{status} > 0 ? 'Warning' : 'Fatal';
			my $statustext
				= $thisservice->{status} == 100 ? 'running' : $thisservice->{status} > 0 ? 'degraded' : 'down';

			my $thiswidth = int( 2 / 3 * $smallGraphWidth );
			
			# we always the service status graph, and a response time graph iff a/v (ie. non-snmp services)
			my $serviceGraphs = Compat::NMIS::htmlGraph(
				graphtype => "service",
				node      => $node,
				intf      => $servicename,
				width     => $thiswidth,
				height    => $smallGraphHeight,
				sys		  => $S
			);
			
			if ( ref( $ST->{$servicename} ) eq "HASH" and $ST->{$servicename}->{"Service_Type"} ne "service" )
			{
				$serviceGraphs .= Compat::NMIS::htmlGraph(
					graphtype => "service-response",
					node      => $node,
					intf      => $servicename,
					width     => $thiswidth,
					height    => $smallGraphHeight,
					sys		  => $S
				);
			}

			my $serviceurl
				= "$C->{'<cgi_url_base>'}/services.pl?act=details&widget=$widget&node="
				. uri_escape($node)
				. "&service="
				. uri_escape($servicename);

			print Tr(
				td( {class => 'info Plain'}, a( {class => "islink", href => $serviceurl}, $servicename ) ),
				td( {class => "info Plain $color"}, $statustext ),
				td( {class => 'image'},             $serviceGraphs )
			);
		}
	}
	else
	{
		print Tr( th( {class => 'title', colspan => '3'}, "No Services defined for $catchall_data->{name}" ) );
	}
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

# show a node's snmp-sourced list of running processes.
# this is totally different from 'services' which means monitored things.
#
sub viewServiceList
{
	my $sort = $Q->{sort} ? $Q->{sort} : "Service";
	my $sortField = $sort eq "CPU"? "hrSWRunPerfCPU" :
			$sort eq "Memory"? "hrSWRunPerfMem" : "hrSWRunName";

	my $node = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists

	my $nmisng_node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $catchall_data->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}


	my %status = $nmisng_node->precise_status;

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	);

	print start_table( {class => 'table'} );

	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => '7'}, "Node unreachable" ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning', colspan => '7'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	my $processlist;
	# there should be at most one inventory item for this
	my ($processinventory, $error) = $S->nmisng_node->inventory( concept => 'snmp_services', create => 0 );
	if ($processinventory)
	{
		my $banner = "Running services on node $catchall_data->{name}";

		my $res = $processinventory->get_newest_timed_data();
		if ($res->{success} && ref($res->{data}) eq "HASH")
		{
			$processlist = $res->{data}->{snmp_services};
			$banner .= " (at ". NMISNG::Util::returnDateStamp($res->{time}).")";

			print Tr( th( {class => 'title', colspan => '7'}, $banner ) );

			my $url
					= url( -absolute => 1 )
					. "?act=network_service_list&refresh=$Q->{refresh}&widget=$widget&node="
					. uri_escape($node);

			print Tr(
				td( {class => 'header'}, a( {href => "$url&sort=Service", class => "wht"}, "Service" ) ),
				td( {class => 'header'}, "Parameters" ),
				td( {class => 'header'}, "Type" ),
				td( {class => 'header'}, "Status" ),
				td( {class => 'header'}, "PID" ),
				td( {class => 'header'}, a( {href => "$url&sort=CPU",     class => "wht"}, "Total CPU Time" ) ),
				td( {class => 'header'}, a( {href => "$url&sort=Memory",  class => "wht"}, "Allocated Memory" ) )
					);

			# produce sortable flat process list; old structure was keyed by "processname:pid",
			# timed_data is "processname" -> [ list of process instance hashes ]
			my @flatlist = map { @$_ } (values %$processlist);

			for my $thisservice (sort { sortServiceList($sortField, $a, $b) } @flatlist)
			{
				# ignore status 'invalid', these are generally zombies without useful information
				next if ($thisservice->{hrSWRunStatus} eq "invalid");

				my $color;
				$color = NMISNG::Util::colorPercentHi(100) if $thisservice->{hrSWRunStatus} =~ /running|runnable/;
				$color = NMISNG::Util::colorPercentHi(0)   if $color eq "red";

				print Tr(
					td( {class => 'info Plain'}, $thisservice->{hrSWRunName} ),
					td( {class => 'info Plain'}, "$thisservice->{hrSWRunPath} $thisservice->{hrSWRunParameters}"),
					td( {class => 'info Plain'}, $thisservice->{hrSWRunType} ),
					td( {class => 'info Plain', style => "background-color:" . $color},
							$thisservice->{hrSWRunStatus}
					),
					td( {class => 'info Plain'}, $thisservice->{pid} ),
					# cpu time is reported in centi-seconds, which results in hard-to-read big numbers
					td( {class => 'info Plain'}, sprintf( "%.3f s", $thisservice->{hrSWRunPerfCPU} / 100 ) ),
					td( {class => 'info Plain'}, $thisservice->{hrSWRunPerfMem} . " KBytes" )
						);
			}
		}
	}

	print Tr( th( {class => 'title', colspan => '6'}, "No Running services found for $catchall_data->{name}" ) )
			if (!$processlist);
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub sortServiceList
{
	my ($sortField, $a, $b ) = @_;

	if ( $sortField eq "hrSWRunName" )
	{
		return $a->{$sortField} cmp $b->{$sortField};
	}
	else
	{
		return $b->{$sortField} <=> $a->{$sortField};
	}
}

sub viewCpuList
{

	my $node = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists
	my $nmisng_node = $S->nmisng_node;

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $catchall_data->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}


	my %status = $nmisng_node->precise_status;

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	);

	print start_table( {class => 'table'} );

	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => '7'}, "Node unreachable" ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				 if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning', colspan => '7'},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	print Tr( th( {class => 'title', colspan => '7'}, "List of CPU's on node $catchall_data->{name}" ) );

	my $url
		= url( -absolute => 1 )
		. "?act=network_service_list&refresh=$Q->{refresh}&widget=$widget&node="
		. uri_escape($node);

	# instead of using this hammer we'll fall back to using getTypeInstances
	# something like getTypeInstances that returns _id's or even inventory objects would be nicer
	# fixme9: should use get_inventory_model and then objects() to instantiate

	# my $modeldata = $S->nmisng->get_inventory_model(cluster_id => $S->nmisng_node->cluster_id,
	# 																										 node_uuid => $S->nmisng_node->uuid,
	# 																										 concept => 'device',
	# 																										 filter => { "storage.hrsmpcpu" => { '$exists' => 1 }},
	# );
	my @indices = $S->getTypeInstances(graphtype => "hrsmpcpu");
	if ( @indices > 0 )
	{
		print Tr( td( {class => 'header'}, "CPU ID and Description" ), td( {class => 'header'}, "History" ), );

		foreach my $index (@indices)
		{
			my $data = $S->inventory( concept => 'device', index => $index )->data();

			print Tr(
				td( {class => 'lft Plain'}, "Server CPU $index ($data->{hrDeviceDescr})" ),
				td( {class => 'info Plain'},
					Compat::NMIS::htmlGraph(
						graphtype => "hrsmpcpu",
						node      => $node,
						intf      => $index,
						width     => $smallGraphWidth,
						height    => $smallGraphHeight
					)
				)
			);
		}
	}
	else
	{
		print Tr( th( {class => 'title', colspan => '6'}, "No Services found for $catchall_data->{name}" ) );
	}
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub viewStatus
{

	my $colspan = 7;

	my $sort = $Q->{sort} ? $Q->{sort} : "level";

	my $sortField = "status";
	$sortField = "value"    if $sort eq "value";
	$sortField = "status"   if $sort eq "status";
	$sortField = "element"  if $sort eq "element";
	$sortField = "property" if $sort eq "property";

	my $node = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists

	my $nmisng_node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $catchall_data->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}

	my %status = $nmisng_node->precise_status;

	print Compat::NMIS::createHrButtons(
		node    => $node,
		system  => $S,
		refresh => $Q->{refresh},
		widget  => $widget,
		conf    => $Q->{conf},
		AU      => $AU
	);
	print start_table( {class => 'table'} );

	if ( !$status{overall} )
	{
		print Tr( td( {class => 'Critical', colspan => $colspan}, 'Node unreachable' ) );
	}
	elsif ( $status{overall} == -1 )
	{
		my @causes;
		push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
		push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
		push @causes, "Node Polling Failover"
				if (defined($status{failover_status}) && !$status{failover_status});
		push @causes, "Backup Host Down"
				 if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

		print Tr(
			td( {class => 'Warning', colspan => $colspan},
				"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
			)
		);
	}

	my $color = NMISNG::Util::colorPercentHi( $catchall_data->{status_summary} ) if $catchall_data->{status_summary};

	#print Tr(td({class=>'info Plain',style=>"background-color:".$color,colspan=>$colspan},'Status Summary'));

	print Tr( th( {class => 'title', colspan => $colspan}, "Status Summary for node $catchall_data->{name}" ) );

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

	my $url
		= url( -absolute => 1 )
		. "?act=network_status_view&refresh=$Q->{refresh}&widget=$widget&node="
		. uri_escape($node);
	my $status_md = $nmisng_node->get_status_model();
	if ( $status_md->count > 0 )
	{
		print Tr(
			td( {class => 'header'}, a( {href => "$url&sort=method",   class => "wht"}, "Method" ) ),
			td( {class => 'header'}, a( {href => "$url&sort=element",  class => "wht"}, "Element" ) ),
			td( {class => 'header'}, a( {href => "$url&sort=property", class => "wht"}, "Event" ) ),
			td( {class => 'header'}, a( {href => "$url&sort=value",    class => "wht"}, "Value" ) ),
			td( {class => 'header'}, a( {href => "$url&sort=level",    class => "wht"}, "Level" ) ),
			td( {class => 'header'}, a( {href => "$url&sort=status",   class => "wht"}, "Status" ) ),
			td( {class => 'header'}, "Updated" ),
		);
		my $data = $status_md->data();
		foreach my $entry ( sort { sortStatus($sort, $sortField, $a, $b) } ( @$data ) )
		{
			if ( $entry->{lastupdate} > time - 3600 )
			{
				my $lastupdate     = NMISNG::Util::returnDateStamp( $entry->{lastupdate} );
				my $elementLink = $entry->{element};
				$elementLink = $node if not $elementLink;
				if ( $entry->{type} =~ "(interface|pkts)" )
				{
					$elementLink = a(
						{   href =>
								"network.pl?act=network_interface_view&intf=$entry->{index}&refresh=$Q->{refresh}&widget=$widget&node="
								. uri_escape($node)
						},
						$entry->{element}
					);
				}

				print Tr(
					td( {class => 'info Plain'},                               $entry->{method} ),
					td( {class => 'lft Plain'},                                $elementLink ),
					td( {class => 'info Plain'},                               $entry->{event} ),
					td( {class => 'rht Plain'},                                $entry->{value} ),
					td( {class => "info Plain $entry->{level}"},               $entry->{level} ),
					td( {class => 'info Plain'},                               $entry->{status} ),
					td( {class => 'info Plain'},                               $lastupdate )
				);
			}
		}
	}
	else
	{
		print Tr( th( {class => 'title', colspan => $colspan}, "No Status Summary found for $catchall_data->{name}" ) );
	}
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub sortStatus
{
	my ( $sort, $sortField, $a, $b ) = @_;

	if ( $sort =~ "(property|level|element|status|method)" )
	{
		return $a->{$sortField} cmp $b->{$sortField};
	}
	else
	{
		return $a->{$sortField} <=> $b->{$sortField};
	}
}


# display a systemhealth table for one node and its (indexed) instances of that particular section/kind
# args: section, also uses Q
sub viewSystemHealth
{
	my $section = shift;
	my $node    = $Q->{node};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
	$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists

	my $M  = $S->mdl;
	my $nmisng = $S->nmisng;
	my $nmisng_node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup( $nmisng_node->configuration()->{group} ) or !exists $GT->{$catchall_data->{group}} )
	{
		print 'You are not authorized for this request';
		return;
	}

	my %status = $nmisng_node->precise_status;

	print Compat::NMIS::createHrButtons(
		node        => $node,
		system      => $S,
		refresh     => $Q->{refresh},
		widget      => $widget,
		conf        => $Q->{conf},
		AU          => $AU
	);

	print start_table( {class => 'table'} );

	my $gotHeaders = 0;
	my $headerDone = 0;
	my $colspan    = 0;
	my @headers;
	if ( $M->{systemHealth}{sys}{$section}{headers} )
	{
		@headers = split( ",", $M->{systemHealth}{sys}{$section}{headers} );
		$gotHeaders = 1;
	}

	my $ids = $nmisng_node->get_inventory_ids( concept => $section,
																						 filter => { historic => 0 } );

	my $D = {};
	foreach my $id (@$ids)
	{
		my ( $inventory, $error ) = $nmisng_node->inventory( _id => $id );
		$nmisng->log->error("Failed to get inventory with id:$id, error:$error") && next
			if ( !$inventory );
		$D = $inventory->data();
		my $index = $D->{index};

		if (exists( $M->{systemHealth}{rrd}{$section}{control} )
			&& !$S->parseString(
				string => "($M->{systemHealth}{rrd}{$section}{control}) ? 1:0",
				index  => $index,
				sect   => $section,
				eval => 1,
				inventory => $inventory
			)
			)
		{
			next;
		}


		# get the header from the node informaiton first.
		if ( not $headerDone )
		{
			if ( not $gotHeaders )
			{
				foreach my $head ( keys %$D )
				{
					push( @headers, $head );
				}
			}
			my @cells;
			my $cell;
			foreach my $head (@headers)
			{
				if ( $M->{systemHealth}{sys}{$section}{snmp}{$head}{title} )
				{
					$cell = td( {class => 'header'}, $M->{systemHealth}{sys}{$section}{snmp}{$head}{title} );
				}
				else
				{
					$cell = td( {class => 'header'}, $head );
				}
				push( @cells, $cell );
				++$colspan;
			}
			my $storage = $inventory->find_subconcept_type_storage( type => 'rrd', subconcept => $section );
			push( @cells, td( {class => 'header'}, "History" ) ) if $storage;
			++$colspan;

			if ( !$status{overall} )
			{
				print Tr( td( {class => 'Critical', colspan => $colspan}, 'Node unreachable' ) );
			}
			elsif ( $status{overall} == -1 )    # degraded, but why?
			{
				my @causes;
				push @causes, "SNMP " . ( $status{snmp_status} ? "Up" : "Down" ) if ( $status{snmp_enabled} );
				push @causes, "WMI " .  ( $status{wmi_status}  ? "Up" : "Down" ) if ( $status{wmi_enabled} );
				push @causes, "Node Polling Failover"
						if (defined($status{failover_status}) && !$status{failover_status});
				push @causes, "Backup Host Down"
						if (defined($status{failover_ping_status}) && !$status{failover_ping_status});

				print Tr(
					td( {class => 'Warning', colspan => $colspan},
						"Node degraded, " . join( ", ", @causes ) . ", status=$catchall_data->{status_summary}"
					)
				);
			}

			print Tr( th( {class => 'title', colspan => $colspan}, "$section of node $catchall_data->{name}" ) );

			my $row = join( " ", @cells );
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
			if ( $D->{$head . "_url"} )
			{
				$url = URI->new( $D->{$head . "_url"} );
				$url->query_param( "widget" => $widget ) if ( !$D->{"${head}_target"} );
			}

			# internal mode, widgetted
			if ( $url and defined $D->{$head . "_id"} and not $D->{"${head}_target"} )
			{
				$cell = td( {class => 'info Plain'}, "<a href=\"$url\" id=\"$D->{$head.'_id'}\">$D->{$head}</a>" );
			}

			# non-widgetted or external mode
			elsif ($url)
			{
				$cell = td(
					{class => 'info Plain'},
					"<a href='$url'"
						. ( $D->{"${head}_target"} ? " target='" . $D->{"${head}_target"} . "'" : '' )
						. ">$D->{$head}</a>"
				);
			}
			else
			{
				$cell = td( {class => 'info Plain'}, $D->{$head} );
			}
			push( @cells, $cell );
		}

		if ($inventory)
		{
			# use 2/3 width so fits a little better.
			my $thiswidth = int( 2 / 3 * $smallGraphWidth );
			my @graphtypes = split /,/, $M->{systemHealth}{rrd}{$section}{graphtype};

			push( @cells, start_td );
			foreach my $GT (@graphtypes)
			{
				push(
					@cells,
					$graphs->htmlGraph(
						graphtype => $GT,
						node      => $node,
						intf      => $index,
						width     => $thiswidth,
						height    => $smallGraphHeight,
						inventory => $inventory
					)
				) if $GT;
			}
			push( @cells, end_td );
		}

# push(@cells,td({class=>'image',rowspan=>'1'},Compat::NMIS::htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight))) if $graphtype;
		my $row = join( " ", @cells );
		print Tr($row);

#print Tr(td({class=>'header'},'Description'),td({class=>'info Plain'},$D->{hhmsSensorHumDescr}),
#td({class=>'image',rowspan=>'1'},Compat::NMIS::htmlGraph(graphtype=>$graphtype,node=>$node,intf=>$index,width=>$smallGraphWidth,height=>$smallGraphHeight)));
	}
	print end_table;
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

# fixme9: needs to be rewritten to NOT use slow and inefficient loadInterfaceInfo!
sub viewOverviewIntf
{
	my $node;

	#	my @out;
	my $icon;
	my $cnt;
	my $text;

	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$node - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	my $II     = Compat::NMIS::loadInterfaceInfo(); # fixme9: slow and wasteful...
	my $ii_cnt = keys %{$II};

	my $NT = $network_status->get_nt();
	my $gr_menu = "";

	# start of form
	print start_form(
		-id   => "ntw_int_overview",
		-href => url( -absolute => 1 ) . "?act=network_interface_overview"
	);

	if ( $ii_cnt > 1000 )
	{
		$gr_menu = td(
			{class => 'header', colspan => '1'},
			"Select group "
				. popup_menu(
				-name     => 'group',
				-override => '1',
				-values   => [ "", @groups ],
				-default  => $Q->{group},
				-onChange => "javascript:get('ntw_int_overview');"
				)
		);
	}

	if ( $ii_cnt > 50000 )
	{
		print table( Tr( th( {class => 'title'}, 'Too many interfaces to run report.' ) ) );
		return;
	}

	print table(
		Tr( th( {class => 'title'}, 'Overview of status of Interfaces' ),
			td( {class => 'info Plain'},
				img({   src    => "$C->{'<menu_url_base>'}/img/arrow_up_green.png",
						border => '0',
						width  => '11',
						height => '10'
					}
				),
				'Up'
			),
			td( {class => 'info Plain'},
				img({   src    => "$C->{'<menu_url_base>'}/img/arrow_down_red.png",
						border => '0',
						width  => '11',
						height => '10'
					}
				),
				'Down'
			),
			td( {class => 'info Plain'},
				img({   src    => "$C->{'<menu_url_base>'}/img/arrow_up_yellow.png",
						border => '0',
						width  => '11',
						height => '10'
					}
				),
				'Dormant'
			),
			td( {class => 'info Plain'},
				img({   src    => "$C->{'<menu_url_base>'}/img/arrow_up_purple.png",
						border => '0',
						width  => '11',
						height => '10'
					}
				),
				'Up no collect'
			),
			td( {class => 'info Plain'},
				img({src => "$C->{'<menu_url_base>'}/img/block_grey.png", border => '0', width => '11', height => '10'}
				),
				'Admin down'
			),
			td( {class => 'info Plain'},
				img({   src    => "$C->{'<menu_url_base>'}/img/block_purple.png",
						border => '0',
						width  => '11',
						height => '10'
					}
				),
				'No collect'
			),
			$gr_menu
		)
	);

	print end_form;

	if ( $gr_menu ne '' and $Q->{group} eq '' ) { goto END_viewOverviewIntf; }

	print start_table;

	print Tr( td( {class => 'info Plain', colspan => '5'}, 'The information is updated daily' ) );

	foreach my $key ( NMISNG::Util::sortall2( $II, 'node', 'ifDescr', 'fwd' ) )
	{
		next if $Q->{group} ne '' and $NT->{$II->{$key}{node}}{group} ne $Q->{group};
		next if (!$AU->InGroup($NT->{$II->{$key}{node}}{group}) or !exists $GT->{$NT->{$II->{$key}{node}}{group}});
		if ( $II->{$key}{node} ne $node )
		{
			print end_Tr if $node ne '';
			$node = $II->{$key}{node};
			$cnt  = 0;
			print start_Tr,
				td(
				{class => 'info Plain'},
				a(  {         href => url( -absolute => 1 )
							. "?act=network_node_view&widget=$widget&node="
							. uri_escape($node)
					},
					$NT->{$node}{name}
				)
				);
		}
		if ( $II->{$key}{ifAdminStatus} ne 'up' )
		{
			$icon = 'block_grey.png';
		}
		elsif ( $II->{$key}{ifOperStatus} eq 'up' )
		{
			$icon = NMISNG::Util::getbool( $II->{$key}{collect} ) ? 'arrow_up_green.png' : 'arrow_up_purple.png';
		}
		elsif ( $II->{$key}{ifOperStatus} eq 'dormant' )
		{
			$icon = NMISNG::Util::getbool( $II->{$key}{collect} ) ? 'arrow_up_yellow.png' : 'arrow_up_purple.png';
		}
		else
		{
			$icon = NMISNG::Util::getbool( $II->{$key}{collect} ) ? 'arrow_down_red.png' : 'block_purple.png';
		}
		if ( $cnt++ >= 32 )
		{
			print end_Tr, start_Tr, td( {class => 'info Plain'}, '&nbsp;' );
			$cnt = 1;
		}
		$text
			= "name=$II->{$key}{ifDescr}<br>adminStatus=$II->{$key}{ifAdminStatus}<br>operStatus=$II->{$key}{ifOperStatus}<br>"
			. "description=$II->{$key}{Description}<br>collect=$II->{$key}{collect}";
		print td(
			{class => 'info Plain'},
			a(  {         href => url( -absolute => 1 )
						. "?act=network_interface_view&intf=$II->{$key}{ifIndex}&refresh=$Q->{refresh}&widget=$widget&node="
						. uri_escape($node),
				},
				img( {src => "$C->{'<menu_url_base>'}/img/$icon", border => '0', width => '11', height => '10'} )
			)
		);
	}
	print end_Tr if $node ne '';
	print end_table;

END_viewOverviewIntf:
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}

sub viewTop10
{
	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "Top 10 - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	print '<!-- Top10 report start -->';


	my $start           = time() - ( 15 * 60 );
	my $end             = time();
	my $datestamp_start = NMISNG::Util::returnDateStamp($start);
	my $datestamp_end   = NMISNG::Util::returnDateStamp($end);

	my $NT = $network_status->get_nt();

	my $header = "Network Top10 from $datestamp_start to $datestamp_end";

	# Get each of the nodes info in a HASH for playing with
	my %reportTable;
	my %cpuTable;
	my %linkTable;

	foreach my $reportnode ( keys %{$NT} )
	{
		next if (!$AU->InGroup( $NT->{$reportnode}{group}) or !exists $GT->{$NT->{$reportnode}{group}});
		if ( NMISNG::Util::getbool( $NT->{$reportnode}{active} ) )
		{
			my $S  = NMISNG::Sys->new(nmisng => $nmisng);
			eval {
				$S->init( name => $reportnode, snmp => 'false' );
				my $catchall =  $S->inventory( concept => 'catchall' );
				my $catchall_data = $catchall->data();
	
				# reachable, available, health, response
				%reportTable = (
					%reportTable,
					%{  Compat::NMIS::getSummaryStats( sys => $S, type => "health", start => $start, end => $end, index => $reportnode )
					}
				);
	
				# cpu only for routers, switch cpu and memory in practice not an indicator of performance.
				# avgBusy1min, avgBusy5min, ProcMemUsed, ProcMemFree, IOMemUsed, IOMemFree
				my $result = $S->nmisng_node->get_inventory_model(
					concept=> "catchall",
					filter => {
						historic => 0,
						subconcepts => "nodehealth",
						"dataset_info.datasets" => "avgBusy5" } );
				if (!$result->error
						&& $result->count
						&& NMISNG::Util::getbool( $catchall_data->{collect} ))
				{
					%cpuTable = (
						%cpuTable,
						%{  Compat::NMIS::getSummaryStats(
								sys   => $S,
								type  => "nodehealth",
								start => $start,
								end   => $end,
								index => $reportnode
										) // {}
						}
					);
				}
	
				my $intfresult = $S->nmisng_node->get_inventory_model( concept => 'interface',
																													 filter => { historic => 0 });
				if (!$intfresult->error)
				{
					foreach my $entry ( @{$intfresult->data})
					{
						my $thisintf = $entry->{data};
	
						if ( NMISNG::Util::getbool( $thisintf->{collect} ) )
						{
							# availability, inputUtil, outputUtil, totalUtil
							my $intf = $thisintf->{ifIndex}; # === index
	
							# Availability, inputBits, outputBits
							my $hash = Compat::NMIS::getSummaryStats( sys => $S, type => "interface", start => $start, end => $end,
																												index => $intf );
							foreach my $k ( keys %{$hash->{$intf}} )
							{
								$linkTable{$intf}{$k} = $hash->{$intf}{$k};
								$linkTable{$intf}{$k} =~ s/NaN/0/;
								$linkTable{$intf}{$k} ||= 0;
							}
							$linkTable{$intf}{node}        = $reportnode;
							$linkTable{$intf}{intf}        = $intf;
							$linkTable{$intf}{ifDescr}     = $thisintf->{ifDescr};
							$linkTable{$intf}{Description} = $thisintf->{Description};
	
							$linkTable{$intf}{totalBits} = ( $linkTable{$intf}{inputBits} + $linkTable{$intf}{outputBits} ) / 2;
						}
					}
				}
			};
			
		}
	}

	foreach my $k ( keys %cpuTable )
	{
		foreach my $l ( keys %{$cpuTable{$k}} )
		{
			$cpuTable{$k}{$l} =~ s/NaN/0/;
			$cpuTable{$k}{$l} ||= 0;
		}
	}

	my @out_resp;
	my @out_cpu;
	my $i;
	print start_table( {class => 'dash'} );

	#class=>'table'
	#print start_table({width=>'500px'});
	# header with time info
	print Tr( th( {class => 'header lrg', align => 'center', colspan => '4'}, $header ) );

	print Tr(
		th( {class => 'header lrg', align => 'center', colspan => '2', width => '50%'}, 'Average Response Time' ),
		th( {class => 'header lrg', align => 'center', colspan => '2', width => '50%'}, 'Nodes by CPU Load' )
	);

	# header and data summary
	print Tr(
		td( {class => 'header', align => 'center'}, 'Node' ),
		td( {class => 'header', align => 'center'}, 'Time (msec)' ),
		td( {class => 'header', align => 'center'}, 'Node' ),
		td( {class => 'header', align => 'center'}, 'Load' )
	);

	$i = 10;
	for my $reportnode ( NMISNG::Util::sortall( \%reportTable, 'response', 'rev' ) )
	{
		push @out_resp,
			td(
			{class => "info Plain $nodewrap"},
			a(  {href => "network.pl?act=network_node_view&node=" . uri_escape($reportnode)},
				$reportnode
			)
			) . td( {class => 'info Plain', align => 'center'}, $reportTable{$reportnode}{response} );

		# loop control
		last if --$i == 0;
	}
	$i = 10;
	for my $reportnode ( NMISNG::Util::sortall( \%cpuTable, 'avgBusy5min', 'rev' ) )
	{
		$cpuTable{$reportnode}{avgBusy5min} =~ /(^\d+)/;
		push @out_cpu,
			td(
			{class => "info Plain $nodewrap"},
			a(  {href => "network.pl?act=network_node_view&node=" . uri_escape($reportnode)},
				$reportnode
			)
			) . td( {class => 'info Plain', align => 'center'}, $cpuTable{$reportnode}{avgBusy5min} );

		# loop control
		last if --$i == 0;
	}

	$i = 10;
	my $empty = td( {class => 'info Plain'}, '&nbsp;' );
	while ($i)
	{
		if ( @out_resp or @out_cpu )
		{
			print start_Tr;
			if   (@out_resp) { print shift @out_resp; }
			else             { print $empty. $empty; }
			if   ( scalar @out_cpu ) { print shift @out_cpu; }
			else                     { print $empty. $empty; }
			print end_Tr;
			$i--;
		}
		else
		{
			$i = 0;    # ready
		}
	}

	print Tr( th( {class => 'title', align => 'center', colspan => '4'}, 'Interfaces by Percent Utilization' ) );
	print Tr(
		td( {class => 'header', align => 'center'}, 'Node' ),
		td( {class => 'header', align => 'center'}, 'Interface' ),
		td( {class => 'header', align => 'center'}, 'Receive' ),
		td( {class => 'header', align => 'center'}, 'Transmit' )
	);

	$i = 10;
	for my $reportlink ( NMISNG::Util::sortall( \%linkTable, 'totalUtil', 'rev' ) )
	{
		last if $linkTable{$reportlink}{inputUtil} and $linkTable{$reportlink}{outputUtil} == 0;
		my $reportnode = $linkTable{$reportlink}{node};
		my $intf       = $linkTable{$reportlink}{intf};
		$linkTable{$reportlink}{inputUtil} =~ /(^\d+)/;
		my $input = $1;
		$linkTable{$reportlink}{outputUtil} =~ /(^\d+)/;
		my $output = $1;
		print Tr(
			td( {class => "info Plain $nodewrap"},
				a(  {href => "network.pl?act=network_node_view&node=" . uri_escape($reportnode)},
					$reportnode
				)
			),
			td( {class => 'info Plain'},
				a(  {   href =>
							"network.pl?act=network_interface_view&intf=$intf&refresh=$Q->{refresh}&widget=$widget&node="
							. uri_escape($reportnode)
					},
					$linkTable{$reportlink}{ifDescr}
				)
			),
			td( {class => 'info Plain', align => 'right'}, "$linkTable{$reportlink}{inputUtil} %" ),
			td( {class => 'info Plain', align => 'right'}, "$linkTable{$reportlink}{outputUtil} %" )
		);

		# loop control
		last if --$i == 0;
	}

	# top10 table - Interfaces by Traffic
	# inputBits, outputBits, totalBits

	print Tr( th( {class => 'title', align => 'center', colspan => '4'}, 'Interfaces by Traffic' ) );
	print Tr(
		td( {class => 'header', align => 'center'}, 'Node' ),
		td( {class => 'header', align => 'center'}, 'Interface' ),
		td( {class => 'header', align => 'center'}, 'Receive' ),
		td( {class => 'header', align => 'center'}, 'Transmit' )
	);

	$i = 10;
	for my $reportlink ( NMISNG::Util::sortall( \%linkTable, 'totalBits', 'rev' ) )
	{
		last if $linkTable{$reportlink}{inputBits} and $linkTable{$reportlink}{outputBits} == 0;
		my $reportnode = $linkTable{$reportlink}{node};
		my $intf       = $linkTable{$reportlink}{intf};
		print Tr(
			td( {class => "info Plain $nodewrap"},
				a(  {href => "network.pl?act=network_node_view&node=" . uri_escape($reportnode)},
					$reportnode
				)
			),
			td( {class => 'info Plain'},
				a(  {   href =>
							"network.pl?act=network_interface_view&intf=$intf&refresh=$Q->{refresh}&widget=$widget&node="
							. uri_escape($reportnode)
					},
					$linkTable{$reportlink}{ifDescr}
				)
			),
			td( {class => 'info Plain', align => 'right'}, NMISNG::Util::getBits( $linkTable{$reportlink}{inputBits} ) ),
			td( {class => 'info Plain', align => 'right'}, NMISNG::Util::getBits( $linkTable{$reportlink}{outputBits} ) )
		);

		# loop control
		last if --$i == 0;
	}
	print end_table;
	print '<!-- Top10 report end -->';

	Compat::NMIS::pageEnd() if ( !$wantwidget );

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

	my $group  = $Q->{group};
	my $filter = $Q->{filter};
	if ( $filter eq "" )
	{
		$filter = 0;
	}
	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "$group - $C->{server_name}", refresh => $Q->{refresh} ) if ( !$wantwidget );

	if ( !$AU->InGroup('network') and !$AU->InGroup($group))
	{
		print 'You are not authorized for this request';
	}
	else
	{
		my $LNT          = Compat::NMIS::loadLocalNodeTable();
		my $noExceptions = 1;

#print qq|"name","group","version","active","collect","last updated","icmp working","snmp working","nodeModel","nodeVendor","nodeType","roleType","netType","sysObjectID","sysObjectName","sysDescr","intCount","intCollect"\n|;
		my @headers = (
			"name",               "group",            "summary",      "active",
			"last collect poll",  "last update poll", "ping (icmp)",  "icmp working",
			"collect (snmp/wmi)", "wmi working",      "snmp working", "community",
			"version",            "nodeVendor",       "nodeModel",    "nodeType",
			"sysObjectID",        "sysDescr",         "Int. Collect of Total",
		);

		my $extra = " for $group" if $group ne "";
		my $cols = @headers;
		my $nmisLink
			= a( {class => "wht", href => $C->{'nmis'} . "?"}, "NMIS $Compat::NMIS::VERSION" ) . "&nbsp;"
			if ( !NMISNG::Util::getbool($widget) );

		my $urlsafegroup = uri_escape($group);

		print start_table( {class => 'dash', width => '100%'} );
		print Tr(
			th( {class => 'title', colspan => $cols},
				$nmisLink,
				"Node Admin Summary$extra ",
				a(  {   style => "color:white;",
						href  => url( -absolute => 1 )
							. "?act=node_admin_summary&refresh=$C->{page_refresh_time}&widget=$widget"
					},
					"All Nodes"
				),
				a(  {   style => "color:white;",
						href  => url( -absolute => 1 )
							. "?act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget"
					},
					"All Information"
				),
				a(  {   style => "color:white;",
						href  => url( -absolute => 1 )
							. "?act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=exceptions"
					},
					"Only Exceptions"
				)
			)
		);
		print Tr(
			eval {
				my $line;

				foreach my $h (@headers)
				{
					$line .= td( {class => 'header', align => 'center'}, $h );
				}
				return $line;
			}
		);

		foreach my $node ( sort keys %{$LNT} )
		{
			if ( $AU->InGroup( $LNT->{$node}{group} )
					 and exists($GT->{ $LNT->{$node}{group} })
					 and ( $group eq "" or $group eq $LNT->{$node}{group} ) )
			{
				my $intCollect = 0;
				my $intCount   = 0;
				my $exception = 0;
				my @issueList;

				my $S          = NMISNG::Sys->new(nmisng => $nmisng);    # get system object
				$S->init( name => $node, snmp => 'false' );    # load node info and Model if name exists
				my $nmisng_node = $S->nmisng_node;

				if ($nmisng_node) {
					my $catchall_data = $S->inventory( concept => 'catchall' )->data();
					my $result = $nmisng_node->get_inventory_model( concept => 'interface',
																													filter => { historic => 0 });
					# Is the node active and are we doing stats on it.
					if ( NMISNG::Util::getbool( $LNT->{$node}{active} )
							 and NMISNG::Util::getbool( $LNT->{$node}{collect} ) )
					{
						if (!$result->error)
						{
							for my $entry (@{$result->data})
							{
								++$intCount;
								++$intCollect if (NMISNG::Util::getbool($entry->{data}->{collect}));
							}
						}
					}
	
					my $sysDescr = $catchall_data->{sysDescr};
					$sysDescr =~ s/[\x0A\x0D]/\\n/g;
					$sysDescr =~ s/,/;/g;
	
					my $community = "OK";
					my $commClass = "info Plain";
	
					my $lastpoll = defined $catchall_data->{last_poll}
					? NMISNG::Util::returnDateStamp( $catchall_data->{last_poll} )
							: "N/A";
					my $lastpollclass = "info Plain";
	
					my $lastupdate
							= defined $catchall_data->{last_update}
					? NMISNG::Util::returnDateStamp( $catchall_data->{last_update} )
							: "N/A";
	
					my $lastupdateclass = "info Plain";
	
					my $pingable  = "unknown";
					my $pingClass = "info Plain";
	
					my $snmpable  = "unknown";
					my $snmpClass = "info Plain";
	
					my $wmiworks = "unknown";
					my $wmiclass = "info Plain";
	
					my $moduleClass = "info Plain";
	
					my $actClass = "info Plain Minor";
					if ( $LNT->{$node}{active} eq "false" )
					{
						push( @issueList, "Node is not active" );
					}
					else
					{
						$actClass = "info Plain";
						if ( $LNT->{$node}{active} eq "false" )
						{
							$lastpoll = "N/A"; # fixme wrong logic - still should show last poll before inactivation!
						}
						elsif ( not defined $catchall_data->{last_poll} )
						{
							$lastpoll  = "unknown";
							$lastpollclass = "info Plain Minor";
							$exception        = 1;
							push( @issueList, "Last collect poll is unknown" );
						}
						elsif ( $catchall_data->{last_poll} < ( time - 60 * 15 ) )
						{
							$lastpollclass = "info Plain Major";
							$exception        = 1;
							push( @issueList, "Last collect poll was over 5 minutes ago" );
						}
	
						if ( $LNT->{$node}{active} eq "false" )
						{
							$lastupdate = "N/A"; # fixme wrong logic, should show last time  before deactivation
						}
						elsif ( not defined $catchall_data->{last_update} )
						{
							$lastupdate  = "unknown";
							$lastupdateclass = "info Plain Minor";
							$exception       = 1;
							push( @issueList, "Last update poll is unknown" );
						}
						elsif ( $catchall_data->{last_update} < ( time - 86400 ) )
						{
							$lastupdateclass = "info Plain Major";
							$exception       = 1;
							push( @issueList, "Last update poll was over 1 day ago" );
						}
	
						$pingable  = "true";
						$pingClass = "info Plain";
						if ( not defined $catchall_data->{nodedown} )
						{
							$pingable  = "unknown";
							$pingClass = "info Plain Minor";
							$exception = 1;
							push( @issueList, "Node state is unknown" );
						}
						elsif ( $catchall_data->{nodedown} eq "true" )
						{
							$pingable  = "false";
							$pingClass = "info Plain Major";
							$exception = 1;
							push( @issueList, "Node is currently unreachable" );
						}
	
						# figure out what sources are enabled and which of those work/are misconfig'd etc
						eval {
							my %status = $nmisng_node->precise_status;
		
							if ( !NMISNG::Util::getbool( $LNT->{$node}{collect} ) or !$status{wmi_enabled} )
							{
								$wmiworks = "N/A";
							}
							else
							{
								if ( !$status{wmi_status} )
								{
									$wmiworks  = "false";
									$wmiclass  = "Info Plain Major";
									$exception = 1;
									push @issueList, "WMI access is currently down";
								}
								else
								{
									$wmiworks = "true";
								}
							}
		
							if ( !NMISNG::Util::getbool( $LNT->{$node}{collect} ) or !$status{snmp_enabled} )
							{
								$community = $snmpable = "N/A";
							}
							else
							{
								$snmpable = 'true';
								if ( !$status{snmp_status} )
								{
									$snmpable  = 'false';
									$snmpClass = "info Plain Major";
									$exception = 1;
									push( @issueList, "SNMP access is currently down" );
								}
		
								if ( $LNT->{$node}{community} eq "" )
								{
									$community = "BLANK";
									$commClass = "info Plain Major";
									$exception = 1;
									push( @issueList, "SNMP Community is blank" );
								}
		
								if ( $LNT->{$node}{community} eq "public" )
								{
									$community = "DEFAULT";
									$commClass = "info Plain Minor";
									$exception = 1;
									push( @issueList, "SNMP Community is default (public)" );
								}
		
								if ( $LNT->{$node}{model} ne "automatic" )
								{
									$moduleClass = "info Plain Minor";
									$exception   = 1;
									push( @issueList, "Not using automatic model discovery" );
								}
							}
						}
					}
	
					my $wd = 850;
					my $ht = 700;
	
					my $idsafenode = $node;
					$idsafenode = ( split( /\./, $idsafenode ) )[0];
					$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;
	
					my $nodelink = a(
						{   href => url( -absolute => 1 )
										. "?act=network_node_view&refresh=$Q->{refresh}&widget=$widget&node="
										. uri_escape($node),
										id => "node_view_$idsafenode"
						},
						$LNT->{$node}{name}
							);
	
					#my $url = "network.pl?act=network_node_view&refresh=$C->{page_refresh_time}&widget=$widget&node=".uri_escape($node);
					#a({target=>"NodeDetails-$node", onclick=>"viewwndw(\'$node\',\'$url\',$wd,$ht)"},$LNT->{$node}{name});
					my $issues = join( "<br/>", @issueList );
	
					my $sysObject = "$catchall_data->{sysObjectName} $catchall_data->{sysObjectID}";
					my $intNums   = "$intCollect/$intCount";
	
					if ( length($sysDescr) > 40 )
					{
						my $shorter = substr( $sysDescr, 0, 40 );
						$sysDescr = "<span title=\"$sysDescr\">$shorter (more...)</span>";
					}
	
					if ( not $filter or ( $filter eq "exceptions" and $exception ) )
					{
						$noExceptions = 0;
	
						my $urlsafegroup = uri_escape( $LNT->{$node}->{group} );
						print Tr(
							td( {class => "info Plain"}, $nodelink ),
							td( {class => 'info Plain'},
									a(  {   href => url( -absolute => 1 )
															. "?act=node_admin_summary&group=$urlsafegroup&refresh=$C->{page_refresh_time}&widget=$widget&filter=$filter"
											},
											$LNT->{$node}{group}
									)
							),
							td( {class => 'infolft Plain'},   $issues ),
							td( {class => $actClass},         $LNT->{$node}{active} ),
							td( {class => $lastpollclass}, $lastpoll ),
							td( {class => $lastupdateclass},  $lastupdate ),
	
							td( {class => 'info Plain'}, $LNT->{$node}{ping} ),
							td( {class => $pingClass},   $pingable ),
	
							td( {class => 'info Plain'}, $LNT->{$node}{collect} ),
	
							td( {class => $wmiclass}, $wmiworks ),
	
							td( {class => $snmpClass},   $snmpable ),
							td( {class => $commClass},   $community ),
							td( {class => 'info Plain'}, $LNT->{$node}{version} ),
	
							td( {class => 'info Plain'}, $catchall_data->{nodeVendor} ),
							td( {class => $moduleClass}, "$catchall_data->{nodeModel} ($LNT->{$node}{model})" ),
							td( {class => 'info Plain'}, $catchall_data->{nodeType} ),
							td( {class => 'info Plain'}, $sysObject ),
							td( {class => 'info Plain'}, $sysDescr ),
							td( {class => 'info Plain'}, $intNums ),
								);
					}
			  }
			}
		} 
		if ( $filter eq "exceptions" and $noExceptions )
		{
			print Tr( td( {class => 'info Plain', colspan => $cols}, "No node admin exceptions were found" ) );
		}
		print end_table;
	}
	Compat::NMIS::pageEnd() if ( !$wantwidget );
}    # end sub nodeAdminSummary

# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
