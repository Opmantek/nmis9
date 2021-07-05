#!/usr/bin/perl
#
#  Copyright 1999-2018 Opmantek Limited (www.opmantek.com)
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
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Data::Dumper;
use CGI;
# fixme needed?use URI::Escape;

use NMISNG;
use NMISNG::Util;
use NMISNG::Sys;
use NMISNG::Auth;
use Compat::NMIS;

# prep ui-related stuff
my $q = CGI->new;
my $Q = $q->Vars;

$Q = NMISNG::Util::filter_params($Q);
# widgetted? only if explicitely requested by caller or implied by jquery header
my $callerwants = NMISNG::Util::getbool($Q->{widget});
my $wantwidget = ( $callerwants or defined($ENV{HTTP_X_REQUESTED_WITH}));


# prime the accessor object next
my $nmisng = Compat::NMIS::new_nmisng;
die "Cannot instantiate NMISNG object!\n" if (!$nmisng);

# decide on auth (none if called from command line)
my $cli_debugging = (@ARGV or !$q->request_uri);
my $config = $nmisng->config;
$config->{auth_require} = 0 if ($cli_debugging);

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new( conf => $config );
if ($AU->Require)
{
	exit 0 if (!$AU->loginout(
								type       => $Q->{auth_type},
								username   => $Q->{auth_username},
								password   => $Q->{auth_password},
								headeropts => $headeropts
						 ));
}
my $refresh = $Q->{refresh} // ($wantwidget? $config->{widget_refresh_time}
																: $config->{page_refresh_time});

# find opstatus entries matching the arguments, display resulting table

# supported params/args, for selection/filtering
#  start/end (time-ish thing), default: now - 30 minto now,
#  activity, type,
#  status (note: uses a fixed set of possibles),
#  details (note: not indexed, may be slow!)
#  uuid or node (for selecting by context.node_uuid, direct or indirectly)
#
#  values can be plain text, or regex:
# 
# sort: anything but context and stats; sort=COLNAME forward, sort=-COLNAME reverse
# default: sort=-time
#
# limit: numeric cut-off.

my $start = ($Q->{start}?  NMISNG::Util::parseDateTime($Q->{start})
						 || NMISNG::Util::getUnixTime($Q->{start})
						 : time - 900 );
my $end = ($Q->{end}?  NMISNG::Util::parseDateTime($Q->{end})
						 || NMISNG::Util::getUnixTime($Q->{end})
					 : time );


my $sort =  { time => -1};
if (defined($Q->{sort}) && $Q->{sort} =~ /^(-)?([a-z_-]+)$/)
{
	$sort = { $2 => (defined($1)? -1: 1) };
}

my $ops = $nmisng->get_opstatus_model(time => { '$gte' => $start,
																								'$lte' => $end },
																			activity => $Q->{activity},
																			type => $Q->{type},
																			status => $Q->{status},
																			details => $Q->{details}, # attention: not indexed, slow
																			sort => $sort,
																			limit => $Q->{limit},
		);
if (my $error = $ops->error)
{
	die "Failed to query opstatus: $error\n";
}

# let there be some output!
print $q->header($headeropts) if (!$cli_debugging);

Compat::NMIS::pageStart(title => "NMIS Operational Status Viewer",
												refresh => $refresh)
		if (!$wantwidget);

if (!$ops->count)
{
	print "<p>No matching records!</p>";
}
else
{
	print  "<table border='1'>","<tr><th>",
	join("</th><th>", qw(Time Activity Type Status Details Context Stats)),
	"</th></tr><tr>";

	for my $one (@{$ops->data})
	{
		# context: queue id, tag and worker process aren't too important here,
		# but node_uuid is, as it links to the nodes in question
		my $visualcontext = (ref($one->{context}) eq "HASH"
												 && defined($one->{context}->{node_name}))?
												 ref($one->{context}->{node_name}) eq "ARRAY"?
												 join("<br>", @{$one->{context}->{node_name}} )
												 : $q->escapeHTML($one->{context}->{node_name} )
												 : "";

		# stats: currently only time may be present
		my $visualstats = (ref($one->{stats}) eq "HASH"
											 && defined($one->{stats}->{time}))?
											 sprintf("Time: %.1fs", $one->{stats}->{time})
											 : "";

		# details: cut off at X chars and replace with a tooltip
		my $nomorethan = 128;
		my $visualdetails;
		if (length($one->{details}) <= $nomorethan)
		{
			$visualdetails = $q->escapeHTML($one->{details});
			$visualdetails =~ s/\n/<br>/g;
		}
		else
		{
			my $halfbaked = $q->escapeHTML(substr($one->{details},0,$nomorethan));
			$halfbaked =~ s/\n/<br>/g;
			$visualdetails = '<span title="'.$q->escapeHTML($one->{details}).'">'
					.$halfbaked."&hellip;"."</span>"
		}


		print "<tr><td>",
		join("</td><td>",
				 NMISNG::Util::returnDateStamp($one->{time}),
				 $q->escapeHTML($one->{activity}),
				 $q->escapeHTML($one->{type}),
				 $one->{status},				# fixed html-safe values
				 $visualdetails,
				 $visualcontext,
				 $visualstats ),
		"</td></tr>";
	}
	print "</table>";
}

Compat::NMIS::pageEnd() if (!$wantwidget);
exit 0;
