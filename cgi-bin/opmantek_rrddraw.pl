#!/usr/bin/perl
#
## $Id: rrddraw.pl,v 8.10 2012/08/24 05:35:22 keiths Exp $
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

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";
#
#****** Shouldn't be anything else to customise below here *******************

require 5;

use strict;
use RRDs 1.4004;
use func;
#use rrdfunc;
use Sys;
use NMIS;
use Data::Dumper;
use LWP::Simple qw(!head);

use CGI qw(:standard *table *Tr *td *form *Select *div);

use vars qw($q $Q $C $AU);

$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars;

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };
$C->{auth_require} = 0; # bypass auth

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
if ($Q->{act} eq 'draw_graph_view') {	rrdDraw();
} else { notfound(); }

exit;

sub notfound {
	logMsg("rrddraw; Command unknown act=$Q->{act}");
}

#============================================================================

sub error {
	print header($headeropts);
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}

#============================================================================

sub rrdDraw {
	my %args = @_;

	# Break the query up for the names
	my $type = $Q->{obj};
	my $nodename = $Q->{node};
	my $debug = $Q->{debug};
	my $grp = $Q->{group};
	my $graphtype = $Q->{graphtype};
	my $graphlength = $Q->{graphlength};
	my $graphstart = $Q->{graphstart};
	my $width = $Q->{width};
	my $height = $Q->{height};
	my $start = $Q->{start};
	my $end = $Q->{end};
	my $intf = $Q->{intf};
	my $item = $Q->{item};
	my $filename = $Q->{filename};

	
	# print STDERR $q->query_string();

	my $content = get("http://localhost:3000/nmis/nmis_graph/chart?".$q->query_string);
	print "Content-type: application/json\n\n";
	print $content;
	return;
}
sub id { 
	my $x = 10 *shift;
	return '_'.sprintf("%02X", $x);	
}	
