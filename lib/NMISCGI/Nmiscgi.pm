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
package NMISCGI::Nmiscgi;
our $VERSION = "9.6.5";

use strict;
use JSON::XS;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use Data::Dumper;

use NMISNG::Util;
use Compat::NMIS;
use Compat::Modules;

sub runcgi {
	my ($args) = @_;

	my $q = $args->{q};
	my $Q = $args->{Q};
	my $C = $args->{C};
	my $AU = $args->{AU};
	my $nmisng = $args->{nmisng};

	# Tenant redirect check
	if (-f "$C->{'<nmis_conf>'}/Tenants.nmis"
		and -f "$C->{'<nmis_cgi>'}/tenants.pl" )
	{
		print $q->header($q->redirect(
										 -url=>"$C->{'<cgi_url_base>'}/tenants.pl",
										 -nph=>1,
										 -status=>303));
		return;
	}

	# set some defaults
	my $widget_refresh = $C->{widget_refresh_time} ? $C->{widget_refresh_time} : 180 ;

	# Handle Apache auth specifics
	my $logoutButton;
	my $privlevel = 5;
	my $user;

	if ($AU->Require) {
		#2011-11-14 Integrating changes from Till Dierkesmann
		if($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") {
			$logoutButton = qq|disabled="disabled"|;
		}
		$privlevel = $AU->{privlevel};
		$user = $AU->{user};
	} else {
		$user = 'Nobody';
		$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
		$logoutButton = qq|disabled="disabled"|;
	}

	# the updated login screen code needs to know what modules are available
	my $M = Compat::Modules->new(nmis_base => $C->{'<nmis_base>'},
														 nmis_cgi_url_base => $C->{'<cgi_url_base>'});
	my $moduleCode = $M->getModuleCode();
	my $installedModules = $M->installedModules();

	# variables used for the security mods
	my $headeropts = {type=>'text/html',expires=>'now'};

	### 2012-12-06 keiths, added a HTML5 compliant header.
	print $q->header($headeropts);
	Compat::NMIS::startNmisPage(title => "NMIS by FirstWave - $C->{server_name}");

	my $tenantCode = Compat::NMIS::loadTenantCode();

	my $serverCode = Compat::NMIS::loadServerCode();

	my $portalCode = Compat::NMIS::loadPortalCode();

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
	my $ptime = &NMISNG::Util::get_localtime();
	#-----------------------------------------------
	print qq|
<div id="body_wrapper">
	<div id="header">
		<div class="nav">
		  <a href="http://www.opmantek.com"><img height="30px" width="30px" class="logo" src="$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png"/></a>
			<span class="title">
NMIS $Compat::NMIS::VERSION - $C->{server_name}</span>
			$tenantCode
			$serverCode
			$moduleCode
			$portalCode
			$logoCode
			<div class="right">
				<a id="menu_help" href="$C->{'nmis_docs_online'}"><img src="$C->{'nmis_help'}"/></a>$ptime&nbsp;&nbsp;User: $user, Auth: Level$privlevel&nbsp;$logout
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
	my $logName = $Q->{logname} || 'Event_Log';

	# send the default list of all names
	my $NT = Compat::NMIS::loadNodeTable(); # load node table
	my $NSum = Compat::NMIS::loadNodeSummary();

	# Only show authorised nodes in the list - and only if members of configured groups!

	my @valNode;
	my @groups  = grep { $AU->InGroup($_) } sort $nmisng->get_group_names;
	my %configuredgroups = map { $_ => $_ } (@groups);

	for my $node ( sort keys %{$NT})
	{
		my $auth = 1;

		if ($AU->Require)
		{
			if ( $NT->{$node}{group} ne "" )
			{
				if ( not $AU->InGroup($NT->{$node}{group}) ) {
					$auth = 0;
				}
			}
		}

		# to be included node must be ok to see, active and belonging to a configured group
		push @valNode, $NT->{$node}{name} if ($auth
																					&& NMISNG::Util::getbool($NT->{$node}->{active})
																					&& $configuredgroups{$NT->{$node}->{group}});
	}

	# upload list of nodenames that match predefined criteria
	# @header is list of criteria - in display english and sentence case etc.
	# @nk is the matching hash key
	my @header=( 'Type', 'Vendor', 'Model', 'Role', 'Net', 'Group');
	my @nk =( 'nodeType', 'nodeVendor', 'nodeModel', 'roleType', 'netType', 'group');

	# read the hash - note al filenames are lowercase - loadTable should take care of this
	# list of nodes is already authorised, just load the details.
	my $nodeInfo = [];
	foreach my $node (@valNode) {
		my $nodeValues = { name => $node };
		foreach my $i ( 0 .. $#header) {
			next unless defined $NSum->{$node}{$nk[$i]};
			# $nodeInfo->{$node}{$header[$i]} = $NSum->{$node}{$nk[$i]};
			$NSum->{$node}{$nk[$i]} =~ s/\s+/_/g;
			$NSum->{$node}{$nk[$i]} =~ s/[<>]/_/g;
			$nodeValues->{$header[$i]} = $NSum->{$node}{$nk[$i]};
			# push @{ $NS{ $header[$i] }{ $NSum->{$node}{$nk[$i]} } }	, $NT->{$node}{name};
		}
		push( @{$nodeInfo}, $nodeValues );
	}
	# write to browser
	print script( "nodeInfo = " . encode_json($nodeInfo) );

	$C->{'display_community_rss_widget'} = "true" if $C->{'display_community_rss_widget'} eq "";
	$C->{'display_network_view'} = "true" if $C->{'display_network_view'} eq "";

	$C->{'rss_widget_width'} = 210 if $C->{'rss_widget_width'} eq "";
	$C->{'rss_widget_height'} = 240 if $C->{'rss_widget_height'} eq "";

	my $windowData = Compat::NMIS::loadWindowStateTable();
	my $savedWindowState = "false";
	my $userWindowData = "false";
	if( defined $windowData && defined($windowData->{$user}) && $windowData->{$user} ne '' )
	{
		$savedWindowState = "true";
		$userWindowData = encode_json($windowData->{$user});
	}

	# show the setup if not hidden and user sufficiently authorized
	my $showsetup = (NMISNG::Util::getbool($C->{'hide_setup_widget'})
			or !$AU->CheckAccess("table_config_rw","check")
			or !$AU->CheckAccess("table_config_view","check"))? 'false' : 'true';

	### 2012-02-22 keiths, added widget_refresh timer, and passing through to jQuery
	print <<EOF;
<script>
var displaySetupWidget = $showsetup;
var displayCommunityWidget = $C->{'display_community_rss_widget'};
var useNewNetworkView = $C->{'display_network_view'};

var rssWidgetWidth = $C->{'rss_widget_width'};
var rssWidgetHeight = $C->{'rss_widget_height'};

var logName = '$logName';

\$(document).ready(function() {
	commonv8Init("$widget_refresh","Config","$installedModules ");
});
var savedWindowState = $savedWindowState;
var userWindowData = $userWindowData;
</script>
EOF

	return;
}

1;
