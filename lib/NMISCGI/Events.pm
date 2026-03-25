package NMISCGI::Events;
our $VERSION = "9.6.5";
use strict;
use Data::Dumper;
use URI::Escape;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use List::Util 1.33;
use Compat::NMIS;
use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::Auth;

$Data::Dumper::Indent = 1;

sub runcgi {
	my ($args) = @_;
	my ($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	my $headeropts = $args->{headeropts};
	my $nmisng = $args->{nmisng};

	$Q = NMISNG::Util::filter_params($Q) if ($Q->{act} ne 'event_table_update');

	# $AU->CheckAccess, will send header and display message denying access if fails.
	$AU->CheckAccess("tls_event_db","header");

	# this cgi script defaults to widget mode ON
	my $widget = NMISNG::Util::getbool($Q->{widget},"invert")? 'false' : 'true';
	my $wantwidget = $widget eq 'true';

	my %common = (q => $q, C => $C, AU => $AU, headeropts => $headeropts,
		nmisng => $nmisng, widget => $widget, wantwidget => $wantwidget);

	#======================================================================

	# select function
	if ($Q->{act} eq 'event_table_view')
	{
		viewEvent(%common, node => $Q->{node}, refresh => $Q->{refresh}, conf => $Q->{conf});
	} elsif ($Q->{act} eq 'event_table_list')
	{
		listEvent(%common, conf => $Q->{conf});
	}
	elsif ($Q->{act} eq 'event_table_update')
	{
		updateEvent(q => $q, nmisng => $nmisng, AU => $AU);
		listEvent(%common, conf => $Q->{conf});
	}
	else
	{
		print header($headeropts);
		print "Tables: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
		print "Requested data not found!\n";
	}

	return;
}

#==================================================================
#
#

# args: q, C, AU, headeropts, nmisng, widget, wantwidget, node, refresh, conf
sub viewEvent
{
	my (%args) = @_;
	my ($C, $AU, $nmisng) = @args{qw(C AU nmisng)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};
	my $node = $args{node};

	#start of page
	print header($args{headeropts});
	Compat::NMIS::pageStartJscript(title => "NMIS View Event $node",refresh => 86400)
			if (!$wantwidget);

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(name=>$node,snmp=>'false');

	print Compat::NMIS::createHrButtons(node=>$node, system => $S, refresh=>$args{refresh},widget=>$widget, conf => $args{conf}, AU => $AU);

	print start_table;

	print start_Tr,start_td,start_table({class=>'table'});
	#print header
	print Tr( eval { my $line; my $colspan = 0;
			for my $item ( 'Node','Outage','Start','Event','Level','Element','Details','Escalate','State') {
				$line .= td({class=>'header',align=>'center'},$item);
				$colspan++;
			}
			return Tr(td({class=>'header',colspan=>$colspan},"Events of node $node")).$line;
		});

	# print data
	# This call is going to get only the local nodes events
	my $eventsmodel = $S->nmisng_node->get_events_model(filter => {	historic => 0});
	my $nodeevents = $eventsmodel->data;
	for my $thisevent (sort { $a->{startdate} <=> $b->{startdate}} @$nodeevents)
	{
		my $state = !$thisevent->{ack} ? 'active' : 'inactive';
		print Tr( eval { my $line;
										 $line .= td({class=>'info Plain'},
																 a({href=>"network.pl?act=network_node_view&widget=$widget&node=".uri_escape($node)},$node));
										 my $outage = NMISNG::Util::convertSecsHours(time() - $thisevent->{startdate});
										 $line .= td({class=>'info Plain'},$outage);
										 $line .= td({class=>'info Plain'}, NMISNG::Util::returnDateStamp($thisevent->{startdate}));
										 $line .= td({class=>'info Plain'}, $thisevent->{event});
										 $line .= td({class=>'info Plain'}, $thisevent->{level});
										 $line .= td({class=>'info Plain'}, $thisevent->{element});
										 $line .= td({class=>'info Plain'}, $thisevent->{details});
										 $line .= td({class=>'info Plain',align=>'center'}, $thisevent->{escalate});
										 $line .= td({class=>'info Plain',align=>'center'}, $state);
										 return $line;
							});
	}

	if (!$eventsmodel->count )
	{
		print Tr(td({class=>'info Plain',colspan=>'4'},"No events current for Node $node"));
	}
	print end_table,end_td,end_Tr;
	print end_table;
	Compat::NMIS::pageEnd() if (!$wantwidget);
}

# args: q, C, AU, headeropts, nmisng, widget, wantwidget, conf
sub listEvent
{
	my (%args) = @_;
	my ($C, $AU, $nmisng) = @args{qw(C AU nmisng)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};

	print header($args{headeropts});
	Compat::NMIS::pageStartJscript(title => "NMIS List Events") if (!$wantwidget);

	# start of form
	print start_form(-id=>"src_events_form",-href=>url(-absolute=>1)."?")
			.	hidden(-override => 1, -name => "conf", -value => $args{conf})
			. hidden(-override => 1, -name => "act", -value => "event_table_update")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table;

	my $eventsmodel= $nmisng->events()->get_events_model(filter => {historic => 0, cluster_id => ""});
	displayEvents(C => $C, AU => $AU, widget => $widget, wantwidget => $wantwidget,
		eventdata => $eventsmodel->data, server => $C->{'server_name'});
	print end_table;
	print end_form;

	Compat::NMIS::pageEnd() if (!$wantwidget);

}

# args: C, AU, widget, wantwidget, eventdata, server
sub displayEvents
{
	my (%args) = @_;
	my ($C, $AU) = @args{qw(C AU)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};
	my $eventdata = $args{eventdata};
	my $server = $args{server};

	my $style;
	my $button;
	my $color;
	my $start;
	my $last;
	my $outage;
 	my $tempnode;
	my $nodehash;
	my $tempnodeack;
	my %eventackcount;
	my %eventnoackcount;
	my %eventcount;
	my $node_cnt;

	my $NT = Compat::NMIS::loadNodeTable();

	# header
	print Tr(th({class=>'title',colspan=>'10'},"$server Event List"));

	# only display the table if there are any events.
	if (@$eventdata < 1) {
		print Tr(td({class=>'info Plain'},"No Events Current"));
		return; # ready
	}

	# rip thru the table once and count all the events by node....helps heaps later.
	for my $thisevent ( @$eventdata )
	{
		if ( $thisevent->{ack} )
		{
			++$eventackcount{$thisevent->{node_name}};
		}
		else
		{
			++$eventnoackcount{$thisevent->{node_name}};
		}
		++$eventcount{$thisevent->{node_name}};
	}

	# always print the active event table header
	$tempnode='';
	$tempnodeack = '';
	my $display = '';
	my $tmpack = '';

	my $event_cnt = 0; # index for update routine Compat::NMIS::eventAck()

	for my $thisevent ( sort { $a->{ack} <=> $b->{ack}
													 or $a->{node_uuid} cmp $b->{node_uuid}
													 or $b->{startdate} cmp $a->{startdate}
													 or $a->{escalate} cmp $b->{escalate}
										} (@$eventdata)  )
	{
		next if (!$thisevent->{node_uuid}); # should not ever be hit

		# check that you're allowed to see this group AND the group isn't hidden

		next unless ($AU->InGroup($NT->{$thisevent->{node_name}}{group})
								 and List::Util::none { $_ eq $NT->{$thisevent->{node_name}}->{group} } (@{$C->{hide_groups}}));
		# print all events
		# print header if ack changed
		if ($tempnodeack ne $thisevent->{ack}) {
			$tempnodeack = $thisevent->{ack};
			typeHeader();
		}

		if (!NMISNG::Util::getbool($tmpack,"invert") and !$thisevent->{ack})
		{
			$tmpack = 'false';
			print Tr(td({class=>'heading3',colspan=>'10'},"Active Events. (Set All Events Inactive",
						checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'0$server')",-checked=>'',override=>'1'),
					")"));
			submitChangesButton(wantwidget => $wantwidget);
		}

		if (!NMISNG::Util::getbool($tmpack) and $thisevent->{ack})
		{
			$tmpack = 'true';
			$display ='none';
			$node_cnt = 0;
			print Tr(td({class=>'heading3',colspan=>'10'},"Inactive Events. (Set All Events Active ",
						checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'1$server')",-checked=>'',override=>'1'),
					")"));
			submitChangesButton(wantwidget => $wantwidget);
		}

		if ( $tempnode ne $thisevent->{node_name} ) {
			$tempnode = $thisevent->{node_name};
			$node_cnt = 0;

			active(C => $C, widget => $widget,
				server => $server, tempnode => $tempnode, tempnodeack => $tempnodeack,
				eventnoackcount => \%eventnoackcount)
					if (!$thisevent->{ack});
			inactive(C => $C, widget => $widget,
				server => $server, tempnode => $tempnode, tempnodeack => $tempnodeack,
				eventackcount => \%eventackcount)
					if ($thisevent->{ack});

		}

		# now write the events, hidden or not hidden
		if ( !$thisevent->{ack} ) {
			$color = NMISNG::Util::eventColor($thisevent->{level});
		}
		else {
			$color = "white";
		}
		$start = NMISNG::Util::returnDateStamp($thisevent->{startdate});
		$last = NMISNG::Util::returnDateStamp($thisevent->{lastchange});
		$outage = NMISNG::Util::convertSecsHours(time() - $thisevent->{startdate});

		# User logic, hmmmm how will users interpret this!
		if ( !$thisevent->{ack} ) {
			$button = "true";
		}
		else {
			$button = "false";
		}
		# print row , Tr with id for set hidden
		### 2012-10-02 keiths, changed color to be done by CSS
		my $ack_tf = ($thisevent->{ack}) ? 'true' : 'false';
		print Tr({id=>"$ack_tf$tempnode$node_cnt",style=>"display:$display;"},
			td({class=>"info $thisevent->{level}"},
				eval {
					return $AU->CheckAccess("src_events","check")
						? a({href=>"logs.pl?&act=log_file_view&logname=Event_Log&search=$thisevent->{node_name}&sort=descending&widget=$widget"},$thisevent->{node_name})
							: "$thisevent->{node_name}";
					}),
			td({class=>"info $thisevent->{level}"},$outage),
			td({class=>"info $thisevent->{level}"},$start),
			td({class=>"info $thisevent->{level}"},$thisevent->{event}),
			td({class=>"info $thisevent->{level}"},$thisevent->{level}),
			td({class=>"info $thisevent->{level}"},$thisevent->{element}),
			td({class=>"info $thisevent->{level}"},$thisevent->{details}),
			td({class=>"info $thisevent->{level}",align=>'center'},
				checkbox(-name=>"$thisevent->{ack}$server$tempnode",-value=>"$event_cnt",-label=>'',override=>'1')),
			td({class=>"info $thisevent->{level}",align=>'right'},$thisevent->{escalate}),
			td({class=>"info $thisevent->{level}"},$thisevent->{user})
			);

		print hidden(-name=>"event_id",-default=>"$thisevent->{_id}",override=>'1');
		print hidden(-name=>"ack",-default=>"$button",override=>'1');

		$event_cnt++;
		$node_cnt++;
	} # foreach $event_hash
	submitChangesButton(wantwidget => $wantwidget);
} # sub displayEvents

# args: C, widget, server, tempnode, tempnodeack, eventnoackcount
sub active {
	my (%args) = @_;
	my ($C, $widget) = @args{qw(C widget)};
	my ($server, $tempnode, $tempnodeack) = @args{qw(server tempnode tempnodeack)};
	my $eventnoackcount = $args{eventnoackcount};

	print Tr(td({class=>'header'},
							a({href=>"network.pl?act=network_node_view&node=".uri_escape($tempnode)."&widget=$widget",onClick=>"ExpandCollapse(\"false$tempnode\"); return false;"},$tempnode)),
					 td({class=>'info Plain',colspan=>'9'},
							img({src=>"$C->{'<menu_url_base>'}/img/sumup.gif",id=>"false${tempnode}img",border=>'0'}),
							"&nbsp;$eventnoackcount->{$tempnode} Event(s)",
							"&nbsp;(Set Events Inactive for $tempnode ",
							checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'$tempnodeack$server$tempnode')",-checked=>'',override=>'1'),
							")"));
} # sub active

# args: C, widget, server, tempnode, tempnodeack, eventackcount
sub inactive {
	my (%args) = @_;
	my ($C, $widget) = @args{qw(C widget)};
	my ($server, $tempnode, $tempnodeack) = @args{qw(server tempnode tempnodeack)};
	my $eventackcount = $args{eventackcount};

	print Tr(td({class=>'header'},
							a({href=>"network.pl?act=network_node_view&node=".uri_escape($tempnode)."&widget=$widget",onClick=>"ExpandCollapse(\"true$tempnode\"); return false;"},$tempnode)),
					 td({class=>'info Plain',colspan=>'9'},
							img({src=>"$C->{'<menu_url_base>'}/img/sumdown.gif",id=>"true${tempnode}img",border=>'0'}),
							"&nbsp;$eventackcount->{$tempnode} Event(s)",
							"&nbsp;(Set Events Active for $tempnode ",
							checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'$tempnodeack$server$tempnode')",-checked=>'',override=>'1'),
							")"));
} # sub inactive

sub typeHeader {
	print Tr(
		td({class=>'header',align=>'center'},'Name'),
		td({class=>'header',align=>'center'},'Outage'),
		td({class=>'header',align=>'center'},'Start'),
		td({class=>'header',align=>'center'},'Event'),
		td({class=>'header',align=>'center'},'Level'),
		td({class=>'header',align=>'center'},'Element'),
		td({class=>'header',align=>'center'},'Details'),
		td({class=>'header',align=>'center'},'Ack.'),
		td({class=>'header',align=>'center'},'Esc.'),
		td({class=>'header',align=>'center'},'User')
			);
}

# args: wantwidget
sub submitChangesButton{
	my (%args) = @_;
	my $wantwidget = $args{wantwidget};
	print Tr(
		td({class=>'info Plain',colspan=>'8',align=>'right'},
			button(-name=>'button',onclick=> ($wantwidget? "get('src_events_form');" : "submit()"),-value=>"Submit Changes")),
		td({class=>'info Plain',colspan=>'2'}, '&nbsp'));
}

# args: q, nmisng, AU
sub updateEvent
{
	my (%args) = @_;
	my ($q, $nmisng, $AU) = @args{qw(q nmisng AU)};

	my @par = $q->param(); # parameter names
	my @ids = $q->param('event_id'); # node names
	my @ack = $q->param('ack'); # event ack status
	# the value of the checkbox is equal to the index of arrays
	my $i = 0;
	# the value of the checkbox is equal to the index of arrays
	for my $par (@par)
	{
		if ($par =~ /^0|1/)
		{ 		# false|true is part of the checkbox name
			my @a = $q->param($par);		# get the values (numbers) of the checkboxes

			foreach my $i (@a)
			{
				# check for change of event
				if ($i ne "" and ((NMISNG::Util::getbool($ack[$i]) and $par =~ /^0/)
													or (NMISNG::Util::getbool($ack[$i],"invert") and $par =~ /^1/)))
				{
					my $event = $nmisng->events->event( _id => $ids[$i] );
					$event->acknowledge( ack => $ack[$i], user => $AU->User() );
				}
			}
		}
	}
}

1;
