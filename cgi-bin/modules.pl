#!/usr/bin/perl
#
## $Id: modules.pl,v 8.1 2011/12/28 01:17:08 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use NMIS;
use func;

use Data::Dumper;
$Data::Dumper::Indent = 1;

my $headeropts = {type=>'text/html',expires=>'now'};

use CGI qw(:standard *table *Tr *td *form *Select *div);
my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash

# load NMIS configuration table
my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});

# this cgi script defaults to widget mode ON
my $widget = getbool($Q->{widget},"invert")? "false" : "true";
my $wantwidget = $widget eq "true";

moduleMenu();

exit;

sub moduleMenu {
	my $title = "NMIS Modules by Opmantek";
	my $header = $title;

	my $nmisicon = "<a target=\"nmis\" href=\"$C->{'nmis'}?conf=$Q->{conf}\"><img class='logo' src=\"$C->{'nmis_icon'}\"/></a>";
	my $header2 = "$header <a href=\"$ENV{SCRIPT_NAME}\"><img src=\"$C->{'nmis_home'}\"/></a>";
	
	my $portalCode = loadPortalCode(conf=>$Q->{conf});

	print header({-type=>"text/html",-expires=>'now'});
	
	if ( !$wantwidget ) {
		#Don't print the start_html, but we do need to get the javascript in there.
		print start_html(-title=>$title,
			-xbase=>&url(-base=>1)."$C->{'<url_base>'}",
			-meta=>{'keywords'=>'network management NMIS'},
			-head=>[
					Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>$C->{'nmis_favicon'}}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"}),
				]
			); 
	}

	print start_table({class=>"noborder"}) ;
	if ( !$wantwidget ) {
		print Tr(td({class=>"nav", colspan=>"3", width=>"100%"},
			"<a href='http://www.opmantek.com'><img height='30px' width='30px' class='logo' src=\"$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png\"/></a>",
			"<span class=\"title\">$header2</span>",
			$portalCode,
			"<span class=\"right\"><a id=\"menu_help\" href=\"$C->{'nmis_docs_online'}\"><img src=\"$C->{'nmis_help'}\"/></a></span>",
		));
	}
	
	my $MOD = loadTable(dir=>'conf',name=>"Modules");
	if ( $Q->{module} and $MOD->{$Q->{module}}{description} ) {
		print Tr(th({class=>"title",colspan=>"3"}, "NMIS $Q->{module} Module"));
		print Tr(td({class=>"lft",width=>"33%"}, "The $Q->{module} module is not currently installed."),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
		print Tr(td({class=>"lft",width=>"33%"}, "$MOD->{$Q->{module}}{description}"),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
		print Tr(td({class=>"lft",width=>"33%"}, "More information and contact information available at ",a({href=>"http://opmantek.com/Modules"},"Opmantek Modules")),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
	}
	else {
		
	}

	print end_table, end_html;	

}

