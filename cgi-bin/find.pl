#!/usr/bin/perl
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
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

#
use strict;
use NMIS;
use func;
use NMIS::Connect;

use Data::Dumper;
$Data::Dumper::Indent = 1;


use CGI qw(:standard *table *Tr *td *form *Select *div);
use URI::Escape;

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
my  $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# widget defaults to true
my $wantwidget = !getbool($Q->{widget},"invert");
my $widgetstate = $wantwidget?"true":"false";

# check for remote request
if ($Q->{server} ne "") { exit 1 if requestServer(headeropts=>$headeropts); }

# prime the output
print header($headeropts);
if (!$wantwidget)
{
		pageStart(title => "NMIS Find");
}

#======================================================================

# select function

if ($Q->{act} eq 'find_interface_menu') {		menuFind('interface');
} elsif ($Q->{act} eq 'find_interface_view') {	viewInterfaceFind();
} elsif ($Q->{act} eq 'find_node_menu') {		menuFind('node');
} elsif ($Q->{act} eq 'find_node_view') {		viewNodeFind();
}
else
{
	print "Network: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

pageEnd() if (!$wantwidget);
exit 0;

#===================

sub menuFind 
{
	my $obj = shift;

	if ($obj eq 'interface' && getbool($C->{disable_interfaces_summary}))
	{
		print("Error: finding interfaces requires config option disable_interfaces_summary=false!");
	}
	else
	{
		my $thisurl = url(-absolute=>1)."?";
		# the get() code doesn't work without a query param, nor does it work with all params present
		# conversely the non-widget mode needs post inputs as query params are ignored
		print start_form(-id=>'find_the_monkey', -href => $thisurl);
		print hidden(-override => 1, -name => "conf", -value => $Q->{conf})
				. hidden(-override => 1, -name => "act", -value => "find_${obj}_view")
				. hidden(-override => 1, -name => "widget", -value => $widgetstate);
		
		print table(
			Tr(td({class=>'header',align=>'center',colspan=>'4'},
						eval { return ($obj eq 'node') ? 'Find a Node' : 'Find an Interface';} )),
			Tr(td({class=>'header'},'Find String '),td(textfield(-name=>"find",size=>'35',value=>'')),
				 # making the button type=submit activates it as the enter key handler, which Is A Good Thing(tm).
				 # however, making the click handler not return false Is A Bad Thing(tm)...
				 td(submit(-name=>'submit',onclick=>
									 ($wantwidget? "javascript:get('find_the_monkey');" : "submit();")."return false;",
									 -value=>"Go"))));
		print end_form;
	}
}


sub viewInterfaceFind 
{
	my $find = $Q->{find};

	# verify access to this command
	$AU->CheckAccess("find_interface"); # same as menu

	# Remove nasty bad characters from $find
	$find =~ s/\(.*\)|\(|\)|#|\*//g;

	if ($find eq '') {
		print Tr(td({class=>'error'},'Empty search string'));
		return;
	}

	if (getbool($C->{disable_interfaces_summary}))
	{
		print Tr(td({class=>'error'},'ERROR: Finding interfaces requires config option disable_interfaces_summary=false!'));
		return;
	}


	# nmisdev 2011-09-13: fixed case insensitve search with a compiled regex.
	my $qrfind = qr/$find/i;

	my $II = loadInterfaceInfo();
	my $NT = loadNodeTable();

	my $counter = 0;
	my @out;
	# Get each of the nodes info in a HASH for playing with
	foreach my $intHash (sortall2($II,'node','ifDescr','fwd'))
	{
		my $thisintf = $II->{$intHash};

		if ( 	$thisintf->{node} =~ /$qrfind/ or
					$thisintf->{Description} =~ /$qrfind/ or
					$thisintf->{display_name} =~ /$qrfind/ or
					$thisintf->{ifDescr} =~ /$qrfind/ or
					$thisintf->{ifType} =~ /$qrfind/ or
					# fixme: search only for first ip address for now
					$thisintf->{ipAdEntAddr1} =~ /$qrfind/ or
					$thisintf->{ipSubnet1} =~ /$qrfind/ or
					$thisintf->{ipSubnet} =~ /$qrfind/ or
					$thisintf->{vlanPortVlan} =~ /$qrfind/
				)
		{
			if ($AU->InGroup($NT->{$thisintf->{node}}{group})) {
				++$counter;

				$thisintf->{ifSpeed} = convertIfSpeed($thisintf->{ifSpeed});

				push @out,Tr(
					td({class=>'info Plain',nowrap=>undef},
						 a({
							 id => "node_view_".uri_escape($thisintf->{node}),
							 href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($thisintf->{node})."&widget=$widgetstate"},$thisintf->{node})),
					eval {
						if ( getbool($thisintf->{collect}) ) {
							return td({class=>'info Plain'},a({
								id => "node_view_".uri_escape($thisintf->{node}),
								href=>"network.pl?conf=$Q->{conf}&act=network_interface_view&node=".uri_escape($thisintf->{node})."&intf=$thisintf->{ifIndex}&widget=$widgetstate"},$thisintf->{ifDescr}));
						} else {
							return td({class=>'info Plain'},$thisintf->{ifDescr});
						}
					},
					td({class=>'info Plain'},$thisintf->{ipAdEntAddr1}),
					td({class=>'info Plain'},a({href=>url(-absolute=>1)."?act=find_interface_view&find=$thisintf->{ipSubnet1}&widget=$widgetstate"},$thisintf->{ipSubnet1})),
					td({class=>'info Plain'},a({href=>url(-absolute=>1)."?act=find_interface_view&find=$thisintf->{Description}&widget=$widgetstate"},$thisintf->{Description})),
					td({class=>'info Plain'},$thisintf->{display_name}),
					td({class=>'info Plain'},$thisintf->{ifType}),
					td({class=>'info Plain',align=>'right'},$thisintf->{ifSpeed}),
					td({class=>'info Plain'},$thisintf->{ifAdminStatus}),
					td({class=>'info Plain'},$thisintf->{ifOperStatus})
				);
			}
		}
	}

	print start_table;
	print Tr(td({class=>'header',align=>'center',colspan=>'9'},"Result of Search Interfaces with \'$Q->{find}\'"));

	if (!scalar @out) {
		print Tr(td({class=>'error'},'No matches found in interface list'));
		print end_table;
		return;
	}

	print Tr( eval { my $line;
			for (('Node','Interface Name','IP Address','Subnet','Description', "Display Name",
						'Type','Bandwidth','Admin','Oper')) {
				$line .= td({class=>'header',align=>'center'},$_);
			}
			return $line;
			} );

	print @out;
	print end_table;

} # typeFind

sub viewNodeFind {

	my $find = $Q->{find};

	# verify access to this command
	$AU->CheckAccess("find_node"); # same as menu

	# Remove nasty bad characters from $find
	$find =~ s/\(.*\)|\(|\)|#|\*//g;

	if ($find eq '') {
		print Tr(td({class=>'error'},'Empty search string'));
		return;
	}

	# nmisdev 2011-09-13: fixed case insensitve search with a compiled regex.
	my $qrfind = qr/$find/i;

	my $NT = loadNodeTable();

	my $counter = 0;
	my @out;
	# Get each of the nodes info in a HASH for playing with
	foreach my $node (sort keys %{$NT})
	{
		my $thisnode = $NT->{$node};

		if ( 	$thisnode->{name} =~ /$qrfind/ or
				$thisnode->{host} =~ /$qrfind/ or
				$thisnode->{group} =~ /$qrfind/ or
				$thisnode->{services} =~ /$qrfind/ or
				$thisnode->{description} =~ /$qrfind/ or
				$thisnode->{depend} =~ /$qrfind/
		) {
			if ($AU->InGroup($thisnode->{group})) {
				++$counter;

				push @out,Tr(
					td({class=>'info',nowrap=>undef},
						 a({
							 id => "node_view_".uri_escape($thisnode->{name}),
							 href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=".uri_escape($node)."&widget=$widgetstate"},
							 $thisnode->{name})),
					td({class=>'info'},$thisnode->{host}),
					td({class=>'info'},$thisnode->{group}),
					td({class=>'info'},$thisnode->{active}),
					td({class=>'info'},$thisnode->{ping}),
					td({class=>'info'},$thisnode->{services}),
					td({class=>'info'},$thisnode->{depend}),
				);
			}
		}
	}

	print start_table;
	print Tr(td({class=>'header',align=>'center',colspan=>'9'},"Result of Search Nodes with \'$Q->{find}\'"));

	if (!scalar @out) {
		print Tr(td({class=>'error'},'No matches found in Nodes list'));
		print end_table;
		return;
	}

	print Tr( eval { my $line;
			for (('Node','Host','Group','Active','Ping','Services','Depend')) {
				$line .= td({class=>'header',align=>'center'},$_);
			}
			return $line;
			} );

	print @out;
	print end_table;

} # typeNodeFind
