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
use NMISNG::DB;
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
$C->{auth_require} = 0 if (@ARGV and not $ENV{GATEWAY_INTERFACE}); # bypass auth for CLI only

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
	return if (!graph_authorised());

	my $result = NMISNG::rrdfunc::draw(NMISNG::rrdfunc::rrdDraw_web_args(%$Q));
	if (!$result->{success})
	{
		error("rrddraw failed: $result->{error}");
		$nmisng->log->error("rrddraw failed: $result->{error}");
		return;
	}
	return $result->{graph};
}

# authorisation gate for rrdDraw. the decision itself lives in
# NMISNG::Auth::graph_refusal, shared with cgi-bin/node.pl.
# returns: 1 if the caller may draw, 0 otherwise (denial already sent)
sub graph_authorised
{
	my ($node, $group) = ($Q->{node}, $Q->{group});

	my $GT = $AU->visible_groups($nmisng->get_group_names);
	# only this node's group is needed, so don't load the whole node table
	my $have_node = (defined($node) and $node ne "");

	# no allow_global here on purpose: global graphtypes such as 'nmis' are drilled
	# into through node.pl, which authorises them on tls_nmis_runtime first. a
	# request naming neither node nor group is refused outright.
	my $refused = $AU->graph_refusal(node_group => $have_node? node_group($node) : undef,
																	 grouptable => $GT,
																	 node => $node, group => $group);
	return 1 if (!defined $refused);

	# the response is deliberately identical to a draw failure, so an
	# unauthorised caller cannot tell the two apart
	error();
	$nmisng->log->warn("rrddraw: user '".NMISNG::Util::sanitise_log_line($AU->{user})
										 ."' not authorised, refused on $refused"
										 .", node='".NMISNG::Util::sanitise_log_line($node)."', group='".NMISNG::Util::sanitise_log_line($group)."'");
	return 0;
}

# look up one local node's group, without loading every node and its config
# args: node name
# returns: group name, or undef if the node is not known locally
sub node_group
{
	my ($node) = @_;

	# '$eq' stops a crafted 'regex:...' name becoming a Mongo pattern
	# (DB.pm get_query_part), which would resolve a different node here than the
	# draw path does. make_string keeps the numeric-name handling that
	# get_nodes_model applies only to plain scalar filters (NMISNG.pm:2494).
	my $md = $nmisng->get_nodes_model(filter => { name => { '$eq' => NMISNG::DB::make_string($node) },
																								cluster_id => $C->{cluster_id} },
																		fields_hash => { 'configuration.group' => 1 },
																		limit => 1);
	return undef if ($md->error);
	return $md->data->[0]->{configuration}->{group};
}
