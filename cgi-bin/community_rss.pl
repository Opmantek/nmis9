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

use strict;
use NMIS;
use func;
use NMIS::License;

use Data::Dumper;
$Data::Dumper::Indent = 1;

my $headeropts = {type=>'text/html',expires=>'now'};

use CGI qw(:standard *table *Tr *td *form *Select *div);
my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

if ($Q->{act} eq '' ) {	
	&printFeed();
} 

sub printFeed {
	
	my $feedurl = $C->{community_rss_url} || "https://community.opmantek.com/rss/NMIS.xml";

	print header($headeropts);
	pageStartJscript(title => "NMIS Community News") if (!getbool($Q->{widget}));

	print qq|
<script>
		var FEED_URL = "$feedurl";
|.q|
		$.ajax(FEED_URL, { ifModified: true, cache: true}).done(function (data) {
				$(data).find("entry").each(function () { 
						var el = $(this);

						var td = $("<td>").addClass("infolft Plain");
						var entrydate = el.children("published").text();
						// iso8601 time but we don't want the full timestamp, 
						// just the date part
						entrydate = entrydate.substring(0, entrydate.indexOf("T"));
						
						var a = $("<a>").attr("href",el.children("link").attr("href"));
						a.append(el.children("title").text());
						td.append(a,", ",el.children("author").children("name").text(),															 ", ", entrydate);

						var tr = $("<tr>").append(td);
						$("#feedtable").append(tr);
				});
				$("#feedtable").append('<tr><td class="infolft Plain"><a href="https://community.opmantek.com/">More News</a></td></tr>');
		});
</script>
|.  start_table({width => "100%", id => "feedtable"});

	print end_table;

	pageEnd if (!getbool($Q->{widget}));

}
