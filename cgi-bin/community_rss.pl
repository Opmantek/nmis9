#!/usr/bin/perl
#
## $Id: registration.pl,v 8.4 2012/09/18 01:40:59 keiths Exp $
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

#use CGI::Debug( report=> [ 'errors', 'empty_body', 'time', 'params', 'cookies', 'environment'], header => 'control' );

use strict;
use NMIS;
use func;
use NMIS::License;

use Data::Dumper;
$Data::Dumper::Indent = 1;

use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *th *form *Select *div *hr);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span );

use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

if ($Q->{act} eq '' ) {	
	&printFeed();
} 

sub printFeed {
	print header($headeropts);

  my $tfs = 30;
#	print qq|
#<script>
#var FEED_URL = "https://community.opmantek.com/createrssfeed.action?types=page&types=blogpost&spaces=NMIS&title=Recent+Contributors&labelString%3D&excludedSpaceKeys%3D&sort=modified&maxResults=3&timeSpan=365&showContent=false&confirm=Create+RSS+Feed";
#$.get(FEED_URL, function (data) {
#    $(data).find("entry").each(function () { 
#    	// or "item" or whatever suits your feed
#        var el = $(this);
#        console.log("------------------------");
#        console.log("title      : " + el.find("title").text());
#        console.log("author     : " + el.find("author").text());
#        console.log("description: " + el.find("description").text());
#    });
#});
#</script>
#|;
	
	print start_table({width=>"100%"});
	print Tr(td({class=>'infolft Plain'},a({href=>"https://community.opmantek.com/display/NMIS/Device+Modelling+Checklist"},"Device Modelling Checklist, Keith Sinclair, 26 May 2014")));
	print Tr(td({class=>'infolft Plain'},a({href=>"https://community.opmantek.com/display/NMIS/Amount+of+Performance+Data+Storage+NMIS8+Stores"},"Amount of Performance Data Storage NMIS8 Stores, Keith Sinclair, 13 May 2014")));
	print Tr(td({class=>'infolft Plain'},a({href=>"https://community.opmantek.com/display/NMIS/Logs%2C+debugs+and+files+which+are+useful+when+troubleshooting+and+resolving+issues+in+NMIS"},"Logs, debugs and files which are useful when troubleshooting and resolving issues in NMIS, Alex Zangerl, 5 May 2014")));
	print end_table;

}
