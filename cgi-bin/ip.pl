#!/usr/bin/perl
#
## $Id: ip.pl,v 8.4 2012/01/06 07:09:37 keiths Exp $
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
#****** Shouldn't be anything else to customise below here *******************

use strict;
use func;
use NMIS;
use ip;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

## Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

# this cgi script defaults to widget mode ON
my $wantwidget = !getbool($Q->{widget},"invert");

print header($headeropts);
pageStart(title => "NMIS IP Calc") if (!$wantwidget);

#======================================================================

# select function

if ($Q->{act} =~ /tool_ip_menu/) {	menuIP();
} else { notfound(); }

sub notfound {
	print "IP: ERROR, act=$Q->{act}, node=$Q->{node}<br>\n";
	print "Request not found\n";
}


pageEnd if (!$wantwidget);
exit;

#===================

sub menuIP {

		print start_form(-id=>"nmis", -href=> url(-absolute => 1)."?")
				.hidden(-override => 1, -name => "conf", -value => $Q->{conf})
				. hidden(-override => 1, -name => "act", -value => "tool_ip_menu")
				. hidden(-override => 1, -name => "widget", -value => ($wantwidget?"true":"false"));

	print start_table;
	print Tr(td({class=>'header',colspan=>'3'},"IP Subnet Calculator"));

	print Tr(td({class=>'header'},'IP Address'),
			td(textfield(-name=>"address",size=>'35',value=>$Q->{address})),
			td({class=>'header'},'IP address to base scheme on'));
	print Tr(td({class=>'header'},'Mask'),
			td(textfield(-name=>"mask1",size=>'35',value=>$Q->{mask1})),
			td({class=>'header'},'Basic IP Subnet Mask for scheme'));
	print Tr(td({class=>'header'},'Mask'),
			td(textfield(-name=>"mask2",size=>'35',value=>$Q->{mask2})),
			td({class=>'header'},'Extended subnet mask for full network'));

	print Tr(td('&nbsp;'),
				td(submit(-name=>"button",-onclick => 
									($wantwidget? "javascript:get('nmis');" : "submit()"),
									-value=>'GO')));

	ipDesc() if $Q->{address} eq '';

	ipCalc() if $Q->{address} ne '';

	ipSubnets() if $Q->{mask2} ne '' and $Q->{address} ne '';

}

sub ipDesc {
	
	print Tr(td({class=>'info',colspan=>'3'},<<EOHTML));
This is the IP Tool, you enter an IP address and a subnet mask and voilà you will be<br>
provided with the IP Subnet Information like IP Subnet Address, Broadcast Address, <br>
Mask Bits for classless routing, Wildcard mask for access lists and OSPF routing <br>
configuration.
<p>
If you want to bigger subnet masking you can put a second mask in which will then<br>
produce a second table and a list of the subnets from the first mask which fit into<br>
the second mask.  This is handy when you are doing VLSM work, and handy for subnet<br>
breakpoints.
EOHTML
}

sub ipCalc {

	my $address = $Q->{address};
	my $mask = $Q->{mask1};
	my $mask2 = $Q->{mask2};

	my $subnet;
	my $bits;
	my $assume;
	my $broadcast;
	my $wildcard;
	my $hosts;

	if ( $mask eq "" ) { 
		$mask = "255.255.255.0"; 
		$assume = "true";
	}
	elsif ( $mask !~ /\d+\.\d+\.\d+\.\d+/ ) { 
		# Its a number bits mask
		$mask = ipBitsToMask(bits => $mask);
	}
	
	($subnet,$bits) = ipSubnet(address => $address, mask => $mask);
	$broadcast = ipBroadcast(subnet => $subnet, mask => $mask);
	$wildcard = ipWildcard(mask => $mask);
	$hosts = ipHosts(mask => $mask);
	if ( getbool($assume) ) {
		$mask = "No mask assuming 255.255.255.0"; 
	} 
	
    print Tr(td({class=>'header',colspan=>'2'},"IP Subnet for IP address $address $mask"));
    print Tr(td({class=>'header',colspan=>'2'},"First Subnet Mask"));

	print Tr(td({class=>'header'},'IP Address'),td({class=>'info'},$address));
	print Tr(td({class=>'header'},'IP Subnet Mask'),td({class=>'info'},$mask));
	print Tr(td({class=>'header'},'Subnet Address'),td({class=>'info'},$subnet));
	print Tr(td({class=>'header'},'Broadcast Address'),td({class=>'info'},$broadcast));
	print Tr(td({class=>'header'},'Mask Bits'),td({class=>'info'},$bits));
	print Tr(td({class=>'header'},'Wildcard Mask'),td({class=>'info'},$wildcard));
	print Tr(td({class=>'header'},'Number Hosts'),td({class=>'info'},$hosts));

}

sub ipSubnets {

	my $address = $Q->{address};
	my $mask = $Q->{mask1};
	my $submask = $Q->{mask2};

	my $numsmallsubnets;
	my $numbigsubnets;
	my $bits;
	my $wildcard;
	my $broadcast;
	my $hosts;
	
	my $subnet;
	my $subbits;
	my $subbroadcast;
	my $subwildcard;
	my $subhosts;
	my $numsubnets;

	my $i;

	if ( $mask eq "" ) { 
		$mask = "255.255.255.0"; 
	}
	elsif ( $mask !~ /\d+\.\d+\.\d+\.\d+/ ) { 
		# Its a number bits mask
		$mask = ipBitsToMask(bits => $mask);
	}

	if ( $submask !~ /\d+\.\d+\.\d+\.\d+/ ) { 
		# Its a number bits mask
		$submask = ipBitsToMask(bits => $submask);
	}

	$wildcard = ipWildcard(mask => $mask);
	$numsmallsubnets = ipNumSubnets(wildcard => $wildcard);

	# get the mask for the second subnet mask!
	($subnet,$subbits) = ipSubnet(address => $address, mask => $submask);
	$subbroadcast = ipBroadcast(subnet => $subnet, mask => $submask);
	$subwildcard = ipWildcard(mask => $submask);
	$subhosts = ipHosts(mask => $submask);
	$hosts = ipHosts(mask => $mask);
	$numbigsubnets = ipNumSubnets(wildcard => $subwildcard);

	$numsubnets = ( $numbigsubnets + 1 ) / ( $numsmallsubnets + 1 );
	$numsubnets = ( $subhosts + 2 ) / ( $hosts + 2 ) ;
	
    print Tr(td({class=>'header',colspan=>'2'},"Second Subnet Mask"));
	
	print Tr(td({class=>'header'},'IP Subnet Mask'),td({class=>'info'},$submask));
	print Tr(td({class=>'header'},'Subnet Address'),td({class=>'info'},$subnet));
	print Tr(td({class=>'header'},'Broadcast Address'),td({class=>'info'},$subbroadcast));
	print Tr(td({class=>'header'},'Mask Bits'),td({class=>'info'},$subbits));
	print Tr(td({class=>'header'},'Wildcard Mask'),td({class=>'info'},$subwildcard));
	print Tr(td({class=>'header'},'Number Hosts'),td({class=>'info'},$subhosts));
	print Tr(td({class=>'header'},"Number Subnets for $mask"),td({class=>'info'},$numsubnets));

    print Tr(td({class=>'header',colspan=>'2'},"Subnet Table for $mask into $submask"));
    print Tr(td({class=>'header'},"Starting Subnet"),td({class=>'info'},$subnet));
    print Tr(td({class=>'header'},"Last Address"),td({class=>'info'},$subbroadcast));
    print Tr(td({class=>'header'},"Mask"),td({class=>'info'},$mask));
	
	print Tr(td({class=>'header'},"Subnet"),td({class=>'header'},"Broadcast"));

	my $cnt = 0;
	for ( $i = 1; $i <= $numsubnets; ++$i ) {
		($subnet,$subbits) = ipSubnet(address => $subnet, mask => $mask);
		$subbroadcast = ipBroadcast(subnet => $subnet, mask => $mask);
		print Tr(td({class=>'info'},$subnet),td({class=>'info'},$subbroadcast));
		$subnet = ipNextSubnet(subnet => $subnet, mask => $mask);
		last if $cnt++ > 1024;
	}

    print Tr(td({class=>'header',colspan=>'2'},"Etcetera...")) if $cnt > 1024;

}
