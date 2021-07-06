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
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use Compat::NMIS;
use NMISNG::Auth;
use Data::Dumper;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars;

$Q = NMISNG::Util::filter_params($Q);
my $nmisng = Compat::NMIS::new_nmisng;
my $C = $nmisng->config;

&NMISNG::rrdfunc::require_RRDs;

# bypass auth iff called from command line
$C->{auth_require} = 0 if (@ARGV);

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request - fixme9: not supported at this time
exit 1 if (defined($Q->{cluster_id}) && $Q->{cluster_id} ne $C->{cluster_id});

#======================================================================

# select function
if ($Q->{act} eq 'draw_graph_view')
{
	rrdDraw();
}
else
{
	print header($headeropts), start_html, "ERROR: Command unknown act=$Q->{act}", end_html;
}
exit;

#============================================================================

sub error {
	print header($headeropts);
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}


# produce one graph
# args: pretty much all coming from a global $Q object
# returns: nothing
sub rrdDraw
{
	my %args = @_;

	# Break the query up for the names
	my $type = $Q->{obj};
	my $nodename = $Q->{node};
	my $debug = $Q->{debug};
	my $grp = $Q->{group};
	my $graphtype = $Q->{graphtype};
	my $graphstart = $Q->{graphstart};
	my $width = $Q->{width};
	my $height = $Q->{height};
	my $start = $Q->{start};
	my $end = $Q->{end};
	my $intf = $Q->{intf};
	my $item = $Q->{item};
	my $filename = $Q->{filename};
	my $when = $Q->{time};

	my $result = NMISNG::rrdfunc::draw(node => $nodename,
																		 group => $grp,
																		 graphtype => $graphtype,
																		 intf => $intf,
																		 item => $item,
																		 width => $width,
																		 height => $height,
																		 filename => $filename,
																		 start => $start,
																		 end => $end,
																		 debug => $debug,
																		 time => $when);
	if (!$result->{success})
	{
		error("rrddraw failed: $result->{error}");
		$nmisng->log->error("rrddraw failed: $result->{error}");
		return;
	}
	return $result->{graph};
}
