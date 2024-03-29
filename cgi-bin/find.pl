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

use strict;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use URI::Escape;
use List::Util 1.33;

use Compat::NMIS;
use NMISNG::Util;

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;
$Q = NMISNG::Util::filter_params($Q);

# load NMIS configuration table
if (!($C = NMISNG::Util::loadConfTable(debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use NMISNG::Auth;

# variables used for the security mods
my  $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# widget defaults to true
my $wantwidget = !NMISNG::Util::getbool($Q->{widget},"invert");
my $widgetstate = $wantwidget?"true":"false";

# check for remote request - fixme9: not supported at this time
exit 1 if (defined($Q->{cluster_id}) && $Q->{cluster_id} ne $C->{cluster_id});

# prime the output
print header($headeropts);
if (!$wantwidget)
{
		Compat::NMIS::pageStart(title => "NMIS Find");
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

Compat::NMIS::pageEnd() if (!$wantwidget);
exit 0;

#===================

sub menuFind
{
	my $obj = shift;

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


# fixme9: needs to be rewritten to NOT use slow
# and inefficient loadInterfaceInfo()!
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

	my $qrfind = qr/$find/i;

	my $II = Compat::NMIS::loadInterfaceInfo();
	my $NT = Compat::NMIS::loadNodeTable();

	my $counter = 0;
	my @out;
	# Get each of the nodes info in a HASH for playing with
	foreach my $intHash (NMISNG::Util::sortall2($II,'node','ifDescr','fwd'))
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
			# if you're allowed to see this group AND the group isn't hidden
			if ($AU->InGroup($NT->{$thisintf->{node}}->{group})
					&& List::Util::none { $_ eq $NT->{$thisintf->{node}}->{group} } (@{$C->{hide_groups}}))
			{
				++$counter;

				$thisintf->{ifSpeed} = NMISNG::Util::convertIfSpeed($thisintf->{ifSpeed});

				push @out,Tr(
					td({class=>'info Plain',nowrap=>undef},
						 a({
							 id => "node_view_".uri_escape($thisintf->{node}),
							 href=>"network.pl?act=network_node_view&node=".uri_escape($thisintf->{node})."&widget=$widgetstate"},$thisintf->{node})),
					eval {
						if ( NMISNG::Util::getbool($thisintf->{collect}) ) {
							return td({class=>'info Plain'},a({
								id => "node_view_".uri_escape($thisintf->{node}),
								href=>"network.pl?act=network_interface_view&node=".uri_escape($thisintf->{node})."&intf=$thisintf->{ifIndex}&widget=$widgetstate"},$thisintf->{ifDescr}));
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

	my $NT = Compat::NMIS::loadNodeTable();

	my $counter = 0;
	my @out;

	foreach my $node (sort keys %{$NT})
	{
		my $thisnode = $NT->{$node};

		# match definition: name, group, host, services, description or a match on the nodes this one depends on
		if ( 	$thisnode->{name} =~ /$qrfind/
					or $thisnode->{host} =~ /$qrfind/
					or $thisnode->{group} =~ /$qrfind/
					or ( ref($thisnode->{services}) eq "ARRAY" and List::Util::any { /$qrfind/ } (@{$thisnode->{services}}) )
					or $thisnode->{description} =~ /$qrfind/
					or ( ref($thisnode->{depend}) eq "ARRAY" and List::Util::any { /$qrfind/ } (@{$thisnode->{depend}}) )
				)
		{
			# if you're allowed to see this group AND the group isn't hidden
			if ($AU->InGroup($thisnode->{group})
					&& List::Util::none { $_ eq $thisnode->{group} } (@{$C->{hide_groups}}))
			{
				++$counter;

				push @out,Tr(
					td({class=>'info',nowrap=>undef},
						 a({
							 id => "node_view_".uri_escape($thisnode->{name}),
							 href=>"network.pl?act=network_node_view&node=".uri_escape($node)."&widget=$widgetstate"},
							 $thisnode->{name})),
					td({class=>'info'},$thisnode->{host}),
					td({class=>'info'},$thisnode->{group}),
					td({class=>'info'},$thisnode->{active}),
					td({class=>'info'},$thisnode->{ping}),
					td({class=>'info'},join(" ", @{$thisnode->{services}})),
					td({class=>'info'},join(" ", @{$thisnode->{depend}})),
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
