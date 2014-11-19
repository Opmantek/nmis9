#!/usr/bin/perl
#
## $Id: snmp.pl,v 8.4 2012/01/06 07:09:38 keiths Exp $
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
use Sys;
use Mib;
use snmp;
use Net::SNMP qw(oid_lex_sort);

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

if ($Q->{act} eq 'snmp_var_menu') {	menuSNMP();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "SNMP: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

exit 1;

#===================

sub menuSNMP{

	print header($headeropts);

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $var = $Q->{var};
	my $pvar = $Q->{pvar};
	my $oid = $Q->{oid};
	my $go = $Q->{go};

	my $xoid;
	my $NT = loadLocalNodeTable(); # node table

	my ($OIDS,$NAMES) = Mib::loadoid();

	print start_form(-id=>'nmisSnmp',action=>"javascript:get('nmisSnmp');", href=>"snmp.pl?conf=$Q->{conf}&act=snmp_var_menu");

	print start_table;

	if ($node eq 'other') {
		if ($Q->{community} ne '' and $Q->{community} ne '*****') {
			$Q->{pcommunity} = $Q->{community};
			$Q->{community} = '*****';
		}
		print td({class=>'header', colspan=>'1'},
				"IP address ",textfield(-name=>"host",-size=>'25',-override=>1,-value=>"$Q->{host}"));
		print td({class=>'header', colspan=>'1'},
				"version ",popup_menu(-name=>"version",-override=>1,
					-values=>['snmpv2c','snmpv1'],-default=>"$Q->{version}"));
		print td({class=>'header', colspan=>'1'},
				"community ",textfield(-name=>"community",-size=>'15',-override=>1,-value=>"$Q->{community}"));
		print hidden(-name=>'pcommunity', -default=>"$Q->{pcommunity}",-override=>'1');
		print hidden(-name=>'node', -default=>"other",-override=>'1');
	} else {
		my @nodes = (sort {lc($a) cmp lc($b)} keys %{$NT});
		@nodes = ('','other',grep { $AU->InGroup($NT->{$_}{group})} @nodes);
		print start_Tr;
		print td({class=>'header', colspan=>'1'},
				"Select node ".
					popup_menu(-name=>'node', -override=>'1',
						-values=>\@nodes,
						-default=>$node,
						-onChange=>"if(this.value=='other')get('nmisSnmp'); else return false;"));
	}

	# the calling Models program is using name+numbers
	if ($var ne '') {
		$var =~ /^(\w+)(.*)$/;
		$var = $1;
		$xoid = $2;
	}

	if ($var ne $pvar) { 
		$oid = $OIDS->{$var}.$xoid; 
	} else {
		if ($oid ne '' and $oid ne $OIDS->{$var}) { 
			$var = $NAMES->{$oid};
		} else { 
			$oid = $OIDS->{$var}; 
		}
	}
	my @vars = sort keys %{$OIDS};
	print td({class=>'header', colspan=>'1'},
			"Select name ".
				popup_menu(-name=>'var', -override=>'1',
					-values=>\@vars,
					-default=>$var,
					-onChange=>"get('nmisSnmp');"));

	

	print td({class=>'header', colspan=>'1'},
			"oid ",	textfield(-name=>"oid",-size=>'35',-override=>1,-value=>"$oid"));

	print td(button(-name=>'submit',onclick=>"get('nmisSnmp','go');",-value=>"Go"));

	print end_Tr;
	if ($node ne '' and $oid ne '' and getbool($go)) { viewSNMP(oid=>$oid); }

	print end_table;
	print hidden(-name=>'pnode', -default=>"$node",-override=>'1');
	print hidden(-name=>'pvar', -default=>"$var",-override=>'1');

	print end_form;

}

sub viewSNMP {
	my %args = @_;
	my $oid = $args{oid};

	my $node = $Q->{node};
	my ($OIDS,$NAMES) = Mib::loadoid();
	my $result;
	my $S;
	my $SNMP;

	my $community = $Q->{community} eq '*****' ? $Q->{pcommunity} : $Q->{community};

	print start_Tr,start_td({colspan=>'3'}),start_table;

	if ($node eq 'other') {
		my $version = $Q->{version} ne '' ? $Q->{version} : 'snmpv2c';
##		my $community = $Q->{community} eq '*****' ? $Q->{pcommunity} : $Q->{community};
		my $host = $Q->{host};
		my $port = 161;
		if ($host eq '') {
			print Tr(td({class=>'error'},"Error, no IP address specified"));
			return;
		}

		$SNMP = snmp::->new;
		$SNMP->init(debug=>$Q->{debug});
		if (!$SNMP->open( host => stripSpaces($host),
											version => stripSpaces($version),
											community => stripSpaces($community),
											port => $port,
											max_msg_size => $C->{snmp_max_msg_size},
											debug => $Q->{debug})) {
			print Tr(td({class=>'error'},$SNMP->error));
			return;
		}
	} else {
		$S = Sys::->new; # get system object
		if ($S->init(name=>$node)) { # open snmp
			$SNMP = $S->snmp;
			if (!$S->open()) {
				print Tr(td({class=>'error'},$SNMP->error));
				return;
			}
		} else {
			print Tr(td({class=>'error'},"Error on initialize node object $node"));
			return;
		}
	} 
	# get it
	if (($result = $SNMP->gettable($oid))) {
		my $msg = (scalar keys %{$result} > 99) ? ', max entries of 100 reached' : '';
		print Tr(td({class=>'header',colspan=>'3'},'result of query'.$msg));
		for my $k (oid_lex_sort(keys %{$result})) {
			print Tr(
				td({class=>'header'},oid2name($k)),
				td({class=>'header'},$k),td({class=>'info'},$result->{$k}));
		}
	} else {
		# table empty, try single entry
		if ((($result) = $SNMP->getarray($oid))) {
			print Tr(td({class=>'header',colspan=>'3'},'result of query'));
			print Tr(
				td({class=>'header'},oid2name($oid)),
				td({class=>'header'},$oid),td({class=>'info'},$result));
			} else {
			print Tr(td({class=>'error'},$SNMP->error));
		}
	}
	
	print end_table,end_td,end_Tr;
	$SNMP->close();
}

