#!/usr/bin/perl
#
## $Id: nmiscgi.pl,v 8.26 2012/09/18 01:40:59 keiths Exp $
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
#  All NMIS documentation can be found @
#  https://community.opmantek.com/
#
# *****************************************************************************

package main;

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use func;
use NMIS;
use NMIS::Modules;
use NMIS::License;
use JSON::XS;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
#use CGI::Debug;
use Data::Dumper;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = CGI->new; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# toss in a default conf=Config.nmis
$Q->{conf} = $Q->{conf} ? $Q->{conf} : 'Config.nmis';

$C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});

# For for Tenants
#if ( ($Q->{conf} eq "" or $Q->{conf} eq "Config" or $Q->{conf} eq "Config.nmis")
if ( ($Q->{conf} eq "" )
	and -f "$C->{'<nmis_conf>'}/Tenants.nmis" and -f "$C->{'<nmis_cgi>'}/tenants.pl" 
) {
	logMsg("TENANT Redirect, conf=$Q->{conf}, $C->{'<cgi_url_base>'}/tenants.pl"); 	
	print $q->header($q->redirect(
			-url=>"$C->{'<cgi_url_base>'}/tenants.pl",
			-nph=>1,
			-status=>303));
	exit;
}

# set some defaults
my $widget_refresh = $C->{widget_refresh_time} ? $C->{widget_refresh_time} : 180 ;

# NMIS Authentication module
use Auth;
my $logoutButton;
my $privlevel = 5;
my $user;

# the updated login screen code needs to know what modules are available
my $M = NMIS::Modules->new(module_base => $C->{'<opmantek_base>'}, 
													 nmis_base => $C->{'<nmis_base>'}, 
													 nmis_cgi_url_base => $C->{'<cgi_url_base>'});
my $moduleCode = $M->getModuleCode();
my $installedModules = $M->installedModules();

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
# pass in confname ONLY if its not the default
my $custom_confname = $Q->{conf}; undef $custom_confname if ($custom_confname eq "Config.nmis");
$AU = Auth->new(conf => $C, confname => $custom_confname);  # Auth::new will reap init values from NMIS configuration

if ($AU->Require) {
	#2011-11-14 Integrating changes from Till Dierkesmann
	if($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") {
		$Q->{auth_username}=$ENV{'REMOTE_USER'};
		$AU->{username}=$ENV{'REMOTE_USER'};
		$logoutButton = qq|disabled="disabled"|;
	}
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},
															username=>$Q->{auth_username},
															password=>$Q->{auth_password},
															headeropts=>$headeropts,
															listmodules => 
															(!getbool($C->{display_module_list}, 'invert')? 
															 $M->getModuleLinks : undef)) ;
	$privlevel = $AU->{privlevel};
	$user = $AU->{user};
} else {
	$user = 'Nobody';
	$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
	$logoutButton = qq|disabled="disabled"|;
}

#my $width = $C->{menu_vr_width} || 80; # min. width of vertical panels
#my $srv = $C->{server_name}; # server name of localhost

# main window layout - default page if nothing requested
# jquery components required
# http://jqueryui.com/download
# UI Core  - All
# Interactions	- Draggable, Resizable
# Widgets - Dialog
# Effects - None
# Theme - Smoothness - note parts of this Theme are overwritten by dash8.css, so dash8.css must be last css file loaded.
# Version	1.8.15 stable
#
# open index.html and copy the required files paths to the header of this file
#		<link type="text/css" href="css/smoothness/jquery-ui-1.8.15.custom.css" rel="stylesheet" />	
#		<script type="text/javascript" src="js/jquery-1.6.2.min.js"></script>
#		<script type="text/javascript" src="js/jquery-ui-1.8.15.custom.min.js"></script>
#
# other files required are JdMenu js/css, and support libaries  - positionBy, bgiframe.

# Check to see if NMIS has been Registered.  To be in licensing of commercial modules.
my $registered = "false";
my $L = NMIS::License->new();
my ($licenseValid,$licenseMessage) = $L->checkLicense();
$registered = "true" if $licenseValid;

### 2012-12-06 keiths, added a HTML5 compliant header.
print $q->header($headeropts);
startNmisPage(title => "NMIS by Opmantek - $C->{server_name}");

my $tenantCode = loadTenantCode(conf=>$Q->{conf});

my $serverCode = loadServerCode(conf=>$Q->{conf});

my $portalCode = loadPortalCode(conf=>$Q->{conf});
 
my $logoCode;
if ( $C->{company_logo} ) {
	$logoCode = qq|<span class="center">
			  <img src="$C->{'company_logo'}"/>
			</span>|;
} 
 
my $logout = qq|<form id="nmislogout" method="POST" class="inline" action="$C->{nmis}">
	<input type="hidden" name="conf" value="$Q->{conf}"/>
	<input class="inline" type="submit" id="logout" name="auth_type" value="Logout" $logoutButton />
</form>
|;
 
if ($C->{auth_method_1} eq "apache") {
	$logout = "";
}

# Get server time
## removing the display of the Portal Links for now.
my $ptime = &get_localtime();
my $confString = "";
if ( $Q->{conf} ne "Config" and $Q->{conf} ne "Config.nmis" ) {
	$confString = "Conf: $Q->{conf},";
}
#-----------------------------------------------
print qq|
<div id="body_wrapper">
	<div id="header">
		<div class="nav">
		  <a href="http://www.opmantek.com"><img height="30px" width="30px" class="logo" src="$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png"/></a>
			<span class="title">NMIS $NMIS::VERSION - $C->{server_name}</span>
			$tenantCode
			$serverCode
			$moduleCode
			$portalCode
			$logoCode
			<div class="right">
				<a id="menu_help" href="$C->{'nmis_docs_online'}"><img src="$C->{'nmis_help'}"/></a>$ptime&nbsp;&nbsp;$confString User: $user, Auth: Level$privlevel&nbsp;$logout
			</div>
		</div>
		<div id="menu_vh_site"></div>
	</div>
</div>
<div id="NMISV8">
<!-- store data objects here -->
</div>
</body>
</html>
|;

# get list of nodes for populating node search list
# must do this last !!!

# build a hash of pre-selected filters, each filter to be a list of headings with a sublist of nodes
# Nodenames go seperatly - simple array list

# defaults
my $logName = 'Event_Log';
if ( getbool($C->{server_master}) and $Q->{logname} eq "" ) {
	$logName = 'Slave_Event_Log';
}
elsif ($Q->{logname} ne "" ) {
	$logName = $Q->{logname};
}

# send the default list of all names
my $NT = loadNodeTable(); # load node table
my $NSum = loadNodeSummary();

#Only show authorised nodes in the list.
my $auth;

my @valNode;
for my $node ( sort keys %{$NT}) {
	$auth = 1;
	if ($AU->Require) {
		my $lnode = lc($NT->{$node}{name});
		if ( $NT->{$node}{group} ne "" ) {
			if ( not $AU->InGroup($NT->{$node}{group}) ) { 
				$auth = 0; 
			}
		}
		else {
			logMsg("WARNING ($node) not able to find correct group. Name=$NT->{$node}{name}.") 
		}
	}
	if ($auth) {
		if ( getbool($NT->{$node}{active}) ) {
			push @valNode, $NT->{$node}{name};
		}
	}
}
# my $jsNode = encode_json(\@valNode );
# print script("namesAll = ".$jsNode);

# upload list of nodenames that match predefined criteria
# @header is list of criteria - in display english and sentence case etc.
# @nk is the matching hash key
my @header=( 'Type', 'Vendor', 'Model', 'Role', 'Net', 'Group');
my @nk =( 'nodeType', 'nodeVendor', 'nodeModel', 'roleType', 'netType', 'group');
# init the hash
# my %NS = ();
# foreach ( @header ) {
# 	$NS{$_} = ();
# }

# read the hash - note al filenames are lowercase - loadTable should take care of this
# list of nodes is already authorised, just load the details.
my $nodeInfo = [];
foreach my $node (@valNode) {
	my $nodeValues = { name => $node };
	foreach my $i ( 0 .. $#header) {
		next unless defined $NSum->{$node}{$nk[$i]};
		# $nodeInfo->{$node}{$header[$i]} = $NSum->{$node}{$nk[$i]};
		$NSum->{$node}{$nk[$i]} =~ s/\s+/_/g;
		$nodeValues->{$header[$i]} = $NSum->{$node}{$nk[$i]};		
		# push @{ $NS{ $header[$i] }{ $NSum->{$node}{$nk[$i]} } }	, $NT->{$node}{name};
	}
	push( @{$nodeInfo}, $nodeValues );
}
# write to browser
print script( "nodeInfo = " . encode_json($nodeInfo) );

$C->{'display_community_rss_widget'} = "true" if $C->{'display_community_rss_widget'} eq "";
$C->{'display_opmaps_widget'} = "true" if $C->{'display_opmaps_widget'} eq "";
$C->{'display_opflow_widget'} = "true" if $C->{'display_opflow_widget'} eq "";
$C->{'display_network_view'} = "true" if $C->{'display_network_view'} eq "";
        
$C->{'rss_widget_width'} = 210 if $C->{'rss_widget_width'} eq "";
$C->{'rss_widget_height'} = 240 if $C->{'rss_widget_height'} eq ""; 

$C->{'opmaps_widget_width'} = 750 if $C->{'opmaps_widget_width'} eq "";
$C->{'opmaps_widget_height'} = 450 if $C->{'opmaps_widget_height'} eq ""; 
$C->{'opflow_widget_width'} = 750 if $C->{'opflow_widget_width'} eq "";
$C->{'opflow_widget_height'} = 460 if $C->{'opflow_widget_height'} eq "";

my $windowData = loadWindowStateTable();
my $savedWindowState = "false";
my $userWindowData = "false";
if( defined $windowData && defined($windowData->{$user}) && $windowData->{$user} ne '' )
{	
	$savedWindowState = "true";
	$userWindowData = encode_json($windowData->{$user});
}

# show the setup if not hidden and user sufficiently authorized
my $showsetup = (getbool($C->{'hide_setup_widget'}) 
		or !$AU->CheckAccess("table_config_rw","check") 
		or !$AU->CheckAccess("table_config_view","check"))? 'false' : 'true';

### 2012-02-22 keiths, added widget_refresh timer, and passing through to jQuery
print <<EOF;
<script>
var displaySetupWidget = $showsetup;
var displayCommunityWidget = $C->{'display_community_rss_widget'};
var displayopMapsWidget = $C->{'display_opmaps_widget'};
var displayopFlowWidget = $C->{'display_opflow_widget'};
var useNewNetworkView = $C->{'display_network_view'};

var rssWidgetWidth = $C->{'rss_widget_width'};
var rssWidgetHeight = $C->{'rss_widget_height'};
var opMapsWidgetWidth = $C->{'opmaps_widget_width'};
var opMapsWidgetHeight = $C->{'opmaps_widget_height'};
var opFlowWidgetWidth = $C->{'opflow_widget_width'};
var opFlowWidgetHeight = $C->{'opflow_widget_height'};

var logName = '$logName';

\$(document).ready(function() {
	commonv8Init("$widget_refresh","$Q->{conf}",$registered,"$installedModules ");
});
var savedWindowState = $savedWindowState;
var userWindowData = $userWindowData;
</script>
EOF


# script end
# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
