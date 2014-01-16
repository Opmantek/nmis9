#!/usr/bin/perl
#
## $Id: tenants.pl,v 8.2 2012/09/18 01:40:59 keiths Exp $
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

$C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});

tenantMenu();
exit;

sub tenantMenu {
	my $header = "NMIS8 Tenants";
	
	my $user = "";
	$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};

	print $q->header(),
		start_html(
		-title => 'NMIS by Opmantek',
		-head => [
					meta({-http_equiv => "Pragma", content => "no-cache"}),
					meta({-http_equiv => "Cache-Control", content => "no-cache, no-store" }),
					meta({-http_equiv => "Expires", content => "-1"}),
					meta({-http_equiv => "Robots", content => "none"}),
					meta({-http_equiv => "Googlebot", content => "noarchive"}),
					Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'jquery_ui_css'}"}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'jquery_jdmenu_css'}"}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"})
			]
		);

	print start_table({class=>"noborder"}) ;
	print Tr(td({class=>"nav", colspan=>"4", width=>"100%"},
		"<a href='http://www.opmantek.com'><img height='30px' width='30px' class='logo' src=\"$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png\"/></a>",
		"<span class=\"title\">$header</span>",
		"<span class=\"right\">User: $user</span>",
	));
 	my $T = loadTable(dir=>'conf',name=>"Tenants");
 	
	foreach my $t ( sort keys %{$T} ) {
 		print Tr(td({class=>"lft Plain"},a({href=>"$C->{'nmis'}?conf=$T->{$t}{Config}"},$T->{$t}{Name})));
 	}	
 	print end_table;
 	print end_html;
}

# script end
# *****************************************************************************
# Copyright (C) Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
