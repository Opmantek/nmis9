#!/usr/bin/perl
#
## $Id: find.pl,v 8.5 2012/09/21 04:56:33 keiths Exp $
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
use NMIS::Connect;

use Data::Dumper;
$Data::Dumper::Indent = 1;

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

# load NMIS configuration table
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

#======================================================================

# select function

if ($Q->{act} eq 'find_interface_menu') {		menuFind('interface');
} elsif ($Q->{act} eq 'find_interface_view') {	viewInterfaceFind();
} elsif ($Q->{act} eq 'find_node_menu') {		menuFind('node');
} elsif ($Q->{act} eq 'find_node_view') {		viewNodeFind();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Network: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

exit 1;

#===================

sub menuFind {
	my $obj = shift;

	print header($headeropts);

	print start_form(-id=>'nmis',action=>"javascript:get('nmis');", href=>url(-absolute=>1)."?conf=$Q->{conf}&act=find_${obj}_view");

	print table(
			Tr(td({class=>'header',align=>'center',colspan=>'4'},
				eval { return ($obj eq 'node') ? 'Find a Node' : 'Find an Interface';} )),
			Tr(td({class=>'header'},'Find String '),td(textfield(-name=>"find",size=>'35',value=>'')),
			td(button(-name=>'submit',onclick=>"javascript:get('nmis');",-value=>"Go"))));
	print end_form;

}


sub viewInterfaceFind {

	my $find = $Q->{find};

	print header($headeropts);

	# verify access to this command
	$AU->CheckAccess("find_interface"); # same as menu

	# Remove nasty bad characters from $find
	$find =~ s/\(.*\)|\(|\)|#|\*//g;

	if ($find eq '') {
		print Tr(td({class=>'error'},'Empty search string'));
		return;
	}

	# nmisdev 2011-09-13: fixed case insensitve search with a compiled regex.
	my $qrfind = qr/$find/i;

	my $II = loadInterfaceInfo();
	my $NT = loadNodeTable();

	my $counter = 0;
	my @out;
	# Get each of the nodes info in a HASH for playing with
	foreach my $intHash (sortall2($II,'node','ifDescr','fwd')) {

		if ( 	$II->{$intHash}{node} =~ /$qrfind/ or
				$II->{$intHash}{Description} =~ /$qrfind/ or
				$II->{$intHash}{ifDescr} =~ /$qrfind/ or
				$II->{$intHash}{ifType} =~ /$qrfind/ or
				$II->{$intHash}{ipAdEntAddr} =~ /$qrfind/ or
				$II->{$intHash}{ipAdEntNetMask} =~ /$qrfind/ or
				$II->{$intHash}{ipSubnet} =~ /$qrfind/ or
				$II->{$intHash}{vlanPortVlan} =~ /$qrfind/
		) {
			if ($AU->InGroup($NT->{$II->{$intHash}{node}}{group})) {
				++$counter;
	
				$II->{$intHash}{ifSpeed} = convertIfSpeed($II->{$intHash}{ifSpeed});
	
				push @out,Tr(
					td({class=>'info',nowrap=>undef},a({href=>"network.pl?%conf=$Q->{conf}&act=network_node_view&node=$II->{$intHash}{node}"},$II->{$intHash}{node})),
					eval {
						if ($II->{$intHash}{collect} eq 'true') {
							return td({class=>'info'},a({href=>"network.pl?%conf=$Q->{conf}&act=network_interface_view&node=$II->{$intHash}{node}&intf=$II->{$intHash}{ifIndex}"},$II->{$intHash}{ifDescr}));
						} else {
							return td({class=>'info'},$II->{$intHash}{ifDescr});
						} 
					},
					td({class=>'info'},$II->{$intHash}{ipAdEntAddr}),
				#	td({class=>'info'},$II->{$intHash}{ipAdEntNetMask}),
					td({class=>'info'},a({href=>url(-absolute=>1)."?%act=find_interface_view&find=$II->{$intHash}{ipSubnet}"},$II->{$intHash}{ipSubnet})),
					td({class=>'info'},a({href=>url(-absolute=>1)."?%act=find_interface_view&find=$II->{$intHash}{Description}"},$II->{$intHash}{Description})),
					td({class=>'info'},$II->{$intHash}{ifType}),
					td({class=>'info',align=>'right'},$II->{$intHash}{ifSpeed}),
					td({class=>'info'},$II->{$intHash}{ifAdminStatus}),
					td({class=>'info'},$II->{$intHash}{ifOperStatus})
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
			for (('Node','Interface Name','IP Address','Subnet','Description','Type','Bandwidth','Admin','Oper')) {
				$line .= td({class=>'header',align=>'center'},$_);
			}
			return $line;
			} );

	print @out;
	print end_table;

} # typeFind

sub viewNodeFind {

	my $find = $Q->{find};

	print header($headeropts);

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
	foreach my $node (sort keys %{$NT}) {

		if ( 	$NT->{$node}{name} =~ /$qrfind/ or
				$NT->{$node}{host} =~ /$qrfind/ or
				$NT->{$node}{group} =~ /$qrfind/ or
				$NT->{$node}{services} =~ /$qrfind/ or
				$NT->{$node}{description} =~ /$qrfind/ or
				$NT->{$node}{depend} =~ /$qrfind/
		) {
			if ($AU->InGroup($NT->{$node}{group})) {
				++$counter;
	
				push @out,Tr(
					td({class=>'info',nowrap=>undef},a({href=>"network.pl?%conf=$Q->{conf}&act=network_node_view&node=$node"},$NT->{$node}{name})),
					td({class=>'info'},$NT->{$node}{host}),
					td({class=>'info'},$NT->{$node}{group}),
					td({class=>'info'},$NT->{$node}{active}),
					td({class=>'info'},$NT->{$node}{ping}),
					td({class=>'info'},$NT->{$node}{services}),
					td({class=>'info'},$NT->{$node}{depend}),
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

