#!/usr/bin/perl
#
## $Id: access.pl,v 8.4 2012/04/28 00:59:36 keiths Exp $
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

use Data::Dumper;
$Data::Dumper::Indent = 1;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# NMIS Authentication module
use Auth;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

if ($Q->{act} eq 'access_menu_load') {	loadAccess();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Access: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

exit 1;

#===================

sub loadAccess {

	print header($headeropts);

	my $start_page_id = ($Q->{start_page} ne '') ? $Q->{start_page} : 
		($C->{menu_start_page_id} ne '') ? $C->{menu_start_page_id} : '';

	print table(Tr(td(p(b("Welcome at the Network Management Information System"))))) if $start_page_id eq '';

	my $AT = loadAccessTable();
	if ($AT) {
		print "<script>\n";
		for my $nm (keys %{$AT}) {
			if ($AT->{$nm}{group} eq 'button' and ($AT->{$nm}{"level$AU->{privlevel}"} or not $AU->Require)) {
				print "menuHr.enableItem(\"$AT->{$nm}{name}\");\n";
			}
		}
		print "loadStartPage('".$start_page_id."');" if $start_page_id ne '';
		print "</script>";
	} else {
		print "ERROR, cannot load Access table";
	}

}

