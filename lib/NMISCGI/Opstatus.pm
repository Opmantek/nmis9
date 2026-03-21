package NMISCGI::Opstatus;
our $VERSION = "9.6.5";
use strict;
use Data::Dumper;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use NMISNG;
use NMISNG::Util;
use NMISNG::Sys;
use Compat::NMIS;

sub runcgi {
	my ($args) = @_;
	my $q = $args->{q};
	my $Q = $args->{Q};
	my $C = $args->{C};
	my $AU = $args->{AU};
	my $headeropts = $args->{headeropts};
	my $nmisng = $args->{nmisng};

	die "Cannot instantiate NMISNG object!\n" if (!$nmisng);

	# decide on auth (none if called from command line)
	my $cli_debugging = (@ARGV or !$q->request_uri);
	my $config = $nmisng->config;
	$config->{auth_require} = 0 if ($cli_debugging);
	my $opstatus_save_logs = NMISNG::Util::getbool($config->{'opstatus_save_logs'} // 0);

	# widgetted? only if explicitely requested by caller or implied by jquery header
	my $callerwants = NMISNG::Util::getbool($Q->{widget});
	my $wantwidget = ( $callerwants or defined($ENV{HTTP_X_REQUESTED_WITH}));

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
	my $id = $Q->{id};

	my $sort =  { time => -1};
	if (defined($Q->{sort}) && $Q->{sort} =~ /^(-)?([a-z_-]+)$/)
	{
		$sort = { $2 => (defined($1)? -1: 1) };
	}

	my $ops;
	if( $id ) {
		$ops = $nmisng->get_opstatus_model(id => $id);
	}
	else
	{
		$ops = $nmisng->get_opstatus_model(time => { '$gte' => $start,
																								'$lte' => $end },
																			activity => $Q->{activity},
																			type => $Q->{type},
																			status => $Q->{status},
																			details => $Q->{details}, # attention: not indexed, slow
																			sort => $sort,
																			limit => $Q->{limit}
			);
	}
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
	elsif( $id )
	{
		my $one = $ops->data()->[0];
		if( $one->{logs} ne "" ) {
			print "<pre style='text-align: left;'><code>";
			print $one->{logs};
			print "</code></pre>";
		}
		else
		{
			print "<p>Logs not collected, check config item opstatus_save_logs, and Mojolicious version logs can capture</p>";
		}
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

			# turn time into a url if it's collect or update (that is all we are keeping logs of for now)
			my $widget = ($wantwidget) ? 'true' : 'false';
			my $time = NMISNG::Util::returnDateStamp($one->{time});
			$time = a(  {href => url( -absolute => 1 ) . "?id=$one->{_id}&widget=$widget"},$time)
				if( $one->{activity} eq 'collect' || $one->{activity} eq 'update' && $opstatus_save_logs );
			print "<tr><td>",
			join("</td><td>",
					 $time,
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
	return;
}

1;
