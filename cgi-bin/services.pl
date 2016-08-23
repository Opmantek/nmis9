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
use URI::Escape;

use func;
use NMIS;
use Auth;
use CGI;
use Data::Dumper;

my $q = new CGI; # processes all parameters passed via GET and POST
my $Q = $q->Vars; # param values in hash

my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug})
		or die "Cannot read Conf table, conf=$Q->{conf}\n";

# widget mode: default false if not told otherwise, and true if jquery-called
my $wantwidget = exists $Q->{widget}? getbool($Q->{widget}) : defined($ENV{"HTTP_X_REQUESTED_WITH"});
my $widget = $wantwidget ? "true" : "false";

# Before going any further, check to see if we must handle
# an authentication login or logout request

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);

if ($AU->Require)
{
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},
															username=>$Q->{auth_username},
															password=>$Q->{auth_password},
															headeropts=>$headeropts);
}

# actions: display the overview, or display the per-service-and-node details
if (!$Q->{act} or $Q->{act} eq 'overview')
{
	display_overview();
}
elsif ($Q->{act} eq 'details' && $Q->{node} && $Q->{service} )
{
	display_details(service => $Q->{service}, node => $Q->{node});
}
else
{
	print $q->header($headeropts);
	pageStart(title => "NMIS Services", refresh => $Q->{refresh}) if (!$wantwidget);

	print "ERROR: Services module doesn't know how to handle act=".escape($Q->{act});
	pageEnd if (!$wantwidget);

	exit 1;
}

# lists a specific service+node combo as a table,
# including all the optional bits that we might have captured
# args: service, node (both required); uses globals
sub display_details
{
	my (%args) = @_;
	my $wantnode = $args{node};
	my $wantservice = $args{service};

	print $q->header($headeropts);
	pageStart(title => "NMIS Services", refresh => $Q->{refresh})
			if (!$wantwidget);

	my $LNT = loadLocalNodeTable;
	if (!$wantnode or !$LNT->{$wantnode} or !$AU->InGroup($LNT->{$wantnode}->{group}))
	{
		print "You are not Authorized to view services on node '$wantnode'!";
		pageEnd if (!$wantwidget);
		return;
	}

	my $ST = loadServicesTable;
	my %sstatus = loadServiceStatus(node => $wantnode, service => $wantservice);
	# only interested in this server's services!
	%sstatus = %{$sstatus{$C->{server_name}}} if (ref($sstatus{$C->{server_name}}) eq "HASH");

	if (!keys %sstatus or !$sstatus{$wantservice} or !$sstatus{$wantservice}->{$wantnode})
	{
		print "No such service or node!";
		pageEnd if (!$wantwidget);
		return;
	}

	my $homelink = $wantwidget? ''
			: $q->a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;";

	print $q->start_table({class=>"table"}),
	"<tr>", $q->th({-class=>"title", -colspan => 2}, $homelink, "Service $wantservice on ",
								 qq|<a class="wht" title="View node $wantnode" href="$C->{network}?conf=$Q->{conf}&act=network_node_view&refresh=$C->{widget_refresh_time}&widget=$widget&node=$wantnode">$wantnode</a> &nbsp; |,
								 qq|<a title="View all services on $wantnode" href="$C->{network}?conf=$Q->{conf}&act=network_service_view&refresh=$C->{widget_refresh_time}&widget=$widget&node=$wantnode"><img src="$C->{'<menu_url_base>'}/img/v8/icons/page_up.gif"></img><a>|,

), "</tr>",
	"<tr>", $q->td({-class=>"header", -colspan => 2}, "Configuration"), "</tr>";

	my $thisservice = $sstatus{$wantservice}->{$wantnode};
#	print Dumper($thisservice);

	# service config info: name (likely different from service id/key), description, type.
	for my $row (["Service Name", $thisservice->{name}],
							 ["Type", $ST->{$wantservice}->{Service_Type}],
							 ["Description", $thisservice->{description}])
	{
		my ($label,$value) = @$row;
		$value = "N/A" if (!defined $value);

		print "<tr>",
		$q->td({ -class=>"info Plain" }, $label),
		$q->td({ -class=>"info Plain" }, $value), "</tr>";
	}

	my $serviceinterval = $ST->{$wantservice}->{Poll_Interval} || 300; # assumption
	if ($serviceinterval =~ /^\s*(\d+(\.\d+)?)([mhd])$/)
	{
		my ($rawvalue, $unit) = ($1, $3);
		$serviceinterval = $rawvalue * ($unit eq 'm'? 60 : $unit eq 'h'? 3600 : 86400);
	}
	# color the time column for excessive last check time
	my $delta = time - $thisservice->{last_run};
	my $lastClass = ($delta >= $serviceinterval*2)? "Fatal"
			: ($delta >= $serviceinterval*1.5)? "Warning" : "";

	# status: when last run, status (translated and numeric), textual status
	print "<tr>", $q->td({-class=>"header", -colspan => 2}, "Status Details"), "</tr>",
	"<tr>", $q->td({ -class=>"info Plain" }, "Last Tested"),
		$q->td({ -class=>"info Plain $lastClass" }, returnDateStamp($thisservice->{last_run})), "</tr>";

	my ($nicestatus, $statuscolor);
	if ($thisservice->{status} == 100)
	{
		$statuscolor = "Normal";
		$nicestatus = "running (100)";
	}
	elsif ($thisservice->{status} > 0)
	{
		$statuscolor = "Warning";
		$nicestatus = "degraded ($thisservice->{status})";
	}
	else
	{
		$statuscolor = 'Fatal';
		$nicestatus = "down (0)";
	}

	# must add graphtype (service, service-cpu, service-mem, service-response)
	my $graphlinkbase = "$C->{'<cgi_url_base>'}/node.pl?conf=$Q->{conf}&act=network_graph_view"
			."&node=".uri_escape($wantnode)
			."&intf=".uri_escape($wantservice);

	my $statuslink = $graphlinkbase."&graphtype=service";

	# we certainly want the small graph for the widget;
	my ($width, $height) = $wantwidget? (266, 33) : (600, 75);

	print "<tr>",
	$q->td({ -class=>"info Plain" },
				 $q->a( { class=>"islink", target => "Graph-$wantnode",
									onclick => "viewwndw(\'$wantnode\',\'$statuslink\',$C->{win_width},$C->{win_height} * 1.5)"},
								"Last Status")),
	$q->td({ -class=>"info $statuscolor" }, $nicestatus ), "</tr>";

	print "<tr>",
	$q->td({ -class=>"info Plain" }, "Last Status Text"),
	$q->td({ -class=>"info Plain" },
				 ($thisservice->{status_text}? escape($thisservice->{status_text}) : "N/A")), "</tr>";

	# responsetime reading, cpu and mem are at the top level, others are under extras
	my @extras;
	my $responselink = $graphlinkbase."&graphtype=service-response";
	push @extras , [
		$q->a( { target => "Graph-$wantnode",
						 class=>"islink",
						 onclick => "viewwndw(\'$wantnode\',\'$responselink\',$C->{win_width},$C->{win_height} * 1.5)"},
					 "Last Response Time" ), escape($thisservice->{responsetime})." s" ]
					 if (defined $thisservice->{responsetime});
	if (defined $thisservice->{cpu})
	{
		my $link = $graphlinkbase."&graphtype=service-cpu";
		push @extras , [
			$q->a( { target => "Graph-$wantnode",
							 class=>"islink",
							 onclick => "viewwndw(\'$wantnode\',\'$link\',$C->{win_width},$C->{win_height} * 1.5)"},
						 "Last CPU Utilisation" ), sprintf("%.5f", ($thisservice->{cpu}/100))." CPU-seconds" ];
	}
	if (defined $thisservice->{memory})
	{
		my $link = $graphlinkbase."&graphtype=service-mem";
		push @extras , [
			$q->a( { target => "Graph-$wantnode",
							 class=>"islink",
							 onclick => "viewwndw(\'$wantnode\',\'$link\',$C->{win_width},$C->{win_height} * 1.5)"},
						 "Last Memory Utilisation" ), $thisservice->{memory}." KBytes" ];
	}

	# any extra custom readings? for nagios we can have units; if present they're under units
	my @customgraphs;
	if (ref($thisservice->{extra}) eq "HASH")
	{
		# custom graphs: if there are any that are called service-custom-<safeservice>-<reading>,
		# then we link the reading title itself
		@customgraphs = ref($thisservice->{customgraphs}) eq "ARRAY"?
				@{$thisservice->{customgraphs}}: ();

		push @extras, undef;						# dummy row for printing the section header
		for my $extrareading (sort keys %{$thisservice->{extra}})
		{
			my $label = "Last ".escape($extrareading);
			my $value = escape($thisservice->{extra}->{$extrareading});
			my $unit = $thisservice->{units}->{$extrareading} if (ref($thisservice->{units}) eq "HASH"
																														&&  $thisservice->{units}->{$extrareading});
			$value .= " $unit" if ($unit and $unit ne "c"); # "counter"


			# note: naming schema is known here, in node.pl and nmis.pl
			my $safeservice = lc($wantservice); $safeservice =~ s/[^a-z0-9\._]//g;
			my $safereading = lc($extrareading); $safereading =~ s/[^a-z0-9\._-]//g;
			my $thisgraphname = "service-custom-$safeservice-$safereading";

			if (grep($_ eq $thisgraphname, @customgraphs))
			{
				my $customlink = $graphlinkbase."&graphtype=$thisgraphname";
				$label = $q->a( { target => "Graph-$wantnode",
																 class=>"islink",
																 onclick => "viewwndw(\'$wantnode\',\'$customlink\',$C->{win_width},$C->{win_height} * 1.5)" }, $label );
			}

			push @extras, [ $label, $value ];
		}
	}

	if (@extras)
	{
		for my $row (@extras)
		{
			if (ref($row) ne "ARRAY")
			{
				print "<tr>", $q->td({-class=>"header", -colspan => 2},
														 "Custom Measurements"), "</tr>";
				next;
			}

			my ($label,$value) = @$row;
			$value = "N/A" if (!defined $value);


			print "<tr>",
			$q->td({ -class=>"info Plain" }, $label),
			$q->td({ -class=>"info Plain" }, $value), "</tr>";
		}
	}

	# now the custom graphs as one row
	if (@customgraphs)
	{
		print "<tr><td class='info Plain'>Custom Graphs</td><td class='info Plain'>";
		for my $graphname (sort @customgraphs)
		{
			my $customlink = $graphlinkbase."&graphtype=$graphname";
			my $label = $graphname;
			$label =~ s/^service-custom-[a-z0-9\._]+-//;

			print $q->a( { target => "Graph-$wantnode",
										 class=>"islink",
										 onclick => "viewwndw(\'$wantnode\',\'$customlink\',$C->{win_width},$C->{win_height} * 1.5)" }, $label ), " &nbsp; ";
		}
		print "</td></tr>";
	}

	print "<tr>", $q->td({-class=>"header", -colspan => 2}, "Status History"), "</tr>",
	"<tr>", $q->td({colspan => 2},
											 htmlGraph( graphtype => "service",
																	node => $wantnode,
																	intf => $wantservice, width => $width, height => $height) ), "</tr>";

	print $q->end_table();
	pageEnd if (!$wantwidget);
}

# lists all active+visible services as a table
# active: attached to a node, visible: node is within the current user's allowed groups
# optionally, skip up or down services (url arg only_show, choices undef=all, "ok", "notok")
# args: none, uses globals (C, widget stuff etc)
sub display_overview
{
	my (%args) = @_;

	my $sortcrit = $Q->{sort}=~/^(service|node|status|last_run|status_text)$/? $Q->{sort} : 'service';

	print $q->header($headeropts);
	pageStart(title => "NMIS Services", refresh => $Q->{refresh})
			if (!$wantwidget);

	# should we show only perfectly ok or only problematic (ie. degraded or dead) services?
	my $filter = (defined($Q->{only_show}) &&  $Q->{only_show} =~ /^(ok|notok)$/ ? $Q->{only_show} : undef);

	# url for sorting, ownurl w/o filter, service url for showing the details page
	my $url = my $ownurl = $q->url(-absolute=>1)."?conf=$Q->{conf}&act=$Q->{act}&widget=$widget";
	$url .= "&only_show=$filter" if ($filter);
	my $serviceurl = $q->url(-absolute=>1)."?conf=$Q->{conf}&act=details&widget=$widget"; # append node and service query params

	my $homelink = $wantwidget? ''
			: $q->a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;";
	# just append the nodename to complete
	my $nodelink = "$C->{'<cgi_url_base>'}/network.pl?conf=$Q->{conf}&act=network_service_view&refresh=$Q->{refresh}&widget=$widget&server=$Q->{server}&node=";


	print $q->start_table({class=>"table"}),
	"<tr>", $q->th({-class=>"title", -colspan => 5}, $homelink, "Monitored Services Overview",
								 qq| <a title="Show only running services" href="$ownurl&only_show=ok"><img src="$C->{'<menu_url_base>'}/img/v8/icons/page_tick.gif"></img></a> <a title="Show only services with problems" href="$ownurl&only_show=notok"><img src="$C->{'<menu_url_base>'}/img/v8/icons/page_alert.gif"></img></a> <a title="Show all services" href="$ownurl"><img src="$C->{'<menu_url_base>'}/img/v8/icons/page.gif"></img></a>|),
	"</tr>",

	"<tr>",
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=service"}, "Service")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=node"}, "Node")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=status"}, "Status")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=last_run"}, "Last Tested")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=status_text"}, "Last Status Text")),
	"</tr>";

	my $LNT = loadLocalNodeTable;

	# get all known service statuses, all nodes, all services.
	# service -> node -> data
	my %sstatus = loadServiceStatus;
	# also need the service table for interval config
	my $ST = loadServicesTable;

	# only interested in this server's services!
	%sstatus = %{$sstatus{$C->{server_name}}} if (ref($sstatus{$C->{server_name}}) eq "HASH");

	my @statuslist;

	for my $sname (keys %sstatus)
	{
		for my $nname (keys %{$sstatus{$sname}})
		{
			# skip if we're not allowed to see this node
			next if (!$AU->InGroup($LNT->{$nname}->{group}));
			next if ($filter and
							 (( $filter eq "ok" and $sstatus{$sname}->{$nname}->{status} != 100)
								or ($filter eq "notok" and $sstatus{$sname}->{$nname}->{status} == 100)));
			push @statuslist, $sstatus{$sname}->{$nname};
		}
	}
	my @sortedlist = sort { $sortcrit =~ /^(last_run|status)$/?
															($a->{$sortcrit} || 0) <=> ($b->{$sortcrit} || 0)
															: ($a->{$sortcrit} || '') cmp ($b->{$sortcrit} || '') } @statuslist;
	for my $one (@sortedlist)
	{
		my $detailurl = $serviceurl . "&node=".uri_escape($one->{node})
				."&service=".uri_escape($one->{service});

		# need separate view id per node+service to show more than one widget at at time, 
		# but spaces and () badly confuse the js widget code...
		my $viewid = "service_view_$one->{node}_$one->{service}";
		$viewid =~ s/[^a-zA-Z0-9_-]+//g;

		print "<tr>", $q->td({-class=>'info Plain'},
												 $q->a({ -href => $detailurl,
																 id => $viewid },
															 $one->{service})),
		$q->td({-class=>'info Plain'},
					 $q->a({-href=>$nodelink.uri_escape($one->{node}), id=>"node_view_".uri_escape($one->{node}) }, $one->{node}));

		my $statuscolor = $one->{status} == 100? 'Normal': $one->{status} > 0? 'Warning' : 'Fatal';
		my $statustext = $one->{status} == 100? 'running': $one->{status} > 0? 'degraded' : 'down';

		my $serviceinterval = $ST->{$one->{name}}->{Poll_Interval} || 300; # assumption
		if ($serviceinterval =~ /^\s*(\d+(\.\d+)?)([mhd])$/)
		{
			my ($rawvalue, $unit) = ($1, $3);
			$serviceinterval = $rawvalue * ($unit eq 'm'? 60 : $unit eq 'h'? 3600 : 86400);
		}
		# color the time column for excessive last check time
		my $delta = time - $one->{last_run};
		my $lastClass = ($delta >= $serviceinterval*2)? "Fatal"
				: ($delta >= $serviceinterval*1.5)? "Warning" : "";

		print $q->td({-class => "info $statuscolor"}, $statustext);

		print $q->td({-class=>"info Plain $lastClass"}, returnDateStamp($one->{last_run})),
		$q->td({-class=>'info Plain'}, $one->{status_text}? escape($one->{status_text}) : "N/A");

		print "</tr>";
	}

	print $q->end_table();
	pageEnd if (!$wantwidget);
}

# some small helpers
# fixme needed?
# neuter html, args: one string
sub escape {
	my $k = shift;
	$k =~ s/&/&amp;/g; $k =~ s/</&lt;/g; $k =~ s/>/&gt;/g;
	return $k;
}
