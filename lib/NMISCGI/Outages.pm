package NMISCGI::Outages;
our $VERSION = "9.6.5";
use strict;
use Time::ParseDate;
use JSON::XS;
use Compat::NMIS;
use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::Outage;
use Data::Dumper;
$Data::Dumper::Indent = 1;
use CGI qw(:standard *table *Tr *td *form *Select *div);

sub runcgi {
	my ($args) = @_;
	my ($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	my $headeropts = $args->{headeropts};
	my $nmisng = $args->{nmisng};

	# default is widgeted mode, only off if explicitely set to false
	my $widget = NMISNG::Util::getbool($Q->{widget},"invert")? "false": "true";
	# numeric option as $widget needs to remain t/f text
	my $wantwidget = $widget eq 'true';

	my %common = (q => $q, C => $C, AU => $AU, headeropts => $headeropts,
		nmisng => $nmisng, widget => $widget, wantwidget => $wantwidget);

	#======================================================================

	# select function
	if ($Q->{act} eq 'outage_table_view') {
		viewOutage(%common, node => $Q->{node}, conf => $Q->{conf},
			refresh => $Q->{refresh}, start => $Q->{start}, end => $Q->{end},
			change => $Q->{change}, error => $Q->{error});
	} elsif ($Q->{act} eq 'outage_table_doadd') {
		my $result = doaddOutage(AU => $AU, wantwidget => $wantwidget,
			node => $Q->{node}, start => $Q->{start}, end => $Q->{end}, change => $Q->{change});
		viewOutage(%common, node => $result->{node}, conf => $Q->{conf},
			refresh => $Q->{refresh}, start => $result->{start}, end => $result->{end},
			change => $result->{change}, error => $result->{error});
	} elsif ($Q->{act} eq 'outage_table_dodelete') {
		my $result = dodeleteOutage(AU => $AU, id => $Q->{id});
		viewOutage(%common, node => '', conf => $Q->{conf},
			refresh => $Q->{refresh}, error => $result->{error});
	} else {
		notfound(headeropts => $headeropts, act => $Q->{act});
	}

	return;
}

# args: headeropts, act
sub notfound {
	my (%args) = @_;
	print header($args{headeropts});
	print "Outage: ERROR, act=$args{act}<br>\n";
	print "Request not found\n";
}

#===================

# args: q, C, AU, headeropts, nmisng, widget, wantwidget,
#       node, conf, refresh, start, end, change, error
sub viewOutage
{
	my (%args) = @_;
	my ($q, $C, $AU, $nmisng) = @args{qw(q C AU nmisng)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};
	my $node = $args{node};

	my @out;

	my $title = $node? "Outages for $node" : "List of Outages";

	my $time = time();

	print header($args{headeropts});
	Compat::NMIS::pageStartJscript(title => $title, refresh => 86400) if (!$wantwidget);

	my $NT = Compat::NMIS::loadNodeTable();
	my $res = NMISNG::Outage::find_outages(); # attention: cannot filter by affected node
	if (!$res->{success})
	{
		print "Cannot find outages: $res->{error}";
		return;
	}
	my @outages = @{$res->{outages}};


	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(name=>$node,snmp=>'false');

	# start of form
	print start_form(-id=>"nmisOutages", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $args{conf})
			. hidden(-override => 1, -name => "act", -value => "outage_table_doadd")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	# doesn't make sense to run the bar creator if it can't create any output anyway...
	print Compat::NMIS::createHrButtons(node=>$node, system=>$S, refresh=>$args{refresh},
																			widget=>$widget, conf => $args{conf}, AU => $AU)
			if ($node);

	print start_table;

	if ($AU->CheckAccess("Table_Outages_rw",'check')) {

		my $start = $time+300;
		my $end = $time+3600;
		my $change = 'ticket #';
		if ($args{error} ne '') {
			$start = $args{start};
			$end = $args{end};
			$change = $args{change};
		}

		my @nodes = grep { $AU->InGroup($NT->{$_}{group}) } sort {lc $a cmp lc $b} keys %{$NT};
		my @nd = split(/,/,$node);

		print Tr(td({class=>'header',colspan=>'3'},'Add Planned Outage'));
		print Tr(
			td({class=>'header',align=>'left'},'Planned Outage Start'),
			td({class=>'info',colspan=>'2'},
				textfield(-name=>'start',-id=>'id_start',-style=>'background-color:yellow;width:100%;',override=>'1',
					-value=>NMISNG::Util::returnDateStamp($start)),div({-id=>'calendar-start'}) )
			);

		print Tr(
			td({class=>'header',align=>'left'},'Planned Outage End'),
			td({class=>'info',colspan=>'2'},
				textfield(-name=>'end',-id=>'id_end',-style=>'background-color:yellow;width:100%;',override=>'1',
					-value=>NMISNG::Util::returnDateStamp($end)),div({-id=>'calendar-end'}) )
			);

		print Tr(
			td({class=>'header',align=>'left'},'Related Change Details'),
			td({class=>'info',colspan=>'2'},
				textfield(-name=>'change',-style=>'background-color:yellow;width:200px;',override=>'1',-value=>$change))
			);

		print Tr(
			td({class=>'header',align=>'left'},'Select Node or Nodes'),
			td({class=>'info',colspan=>'2'},
				scrolling_list(-name=>'node',-multiple=>'true',-size=>'12',override=>'1',-values=>\@nodes,-default=>\@nd) )
			);

		print Tr(
			td({class=>'header',align=>'left'},'Action'),
			td({class=>'info',align=>'center',colspan=>'2'},
				button(-name=>'button',-onclick=> ($wantwidget? "get('nmisOutages');" : "submit()"),
							 -value=>"Add"))
			);

		if ($args{error} ne '') {
			print Tr(td({class=>'error',colspan=>'3'},$args{error}));
		}
	}

	print Tr(td({class=>'info',colspan=>'2'},'&nbsp;'));

	#====

	my $hd = ($node ne "") ? "Outage Table of Node $node" : "Outage Table";
	print Tr(td({class=>'header',colspan=>'6'},$hd));

	push @out, Tr(
		td({class=>'header',align=>'center'},'Node Selector'),
		td({class=>'header',align=>'center'},'Start'),
		td({class=>'header',align=>'center'},'End'),
		td({class=>'header',align=>'center'},'Change'),
		td({class=>'header',align=>'center'},'Status'),
		td({class=>'header',align=>'center'},'Action')
		);


	for my $outage (@outages)
	{

		# no coloring/status for anything but non-recurring+current ones
		my ($status,$color) = ($outage->{frequency},"white");

		if ($outage->{frequency} eq "once")
		{
			if ($time >= $outage->{end})
			{
				$status =  'closed';
				$color = "#FFFFFF";
			}
			elsif ($time < $outage->{start})
			{
				$status = "pending";
			}
			else
			{
				$status = 'current';
				$color = "#00FF00";
			}
		}

		# very rough stringification of the of the selector
		my $visual = JSON::XS->new->encode($outage->{selector});

		push @out, Tr(
			td({class=>'info',style=>NMISNG::Util::getBGColor($color)},
				 $visual),
			td({class=>'info',style=>NMISNG::Util::getBGColor($color)},
				 $outage->{start} =~ /^\d+(\.\d+)?$/?
				 POSIX::strftime("%Y-%m-%dT%H:%M:%S", localtime($outage->{start})) : $outage->{start}),

			td({class=>'info',style=>NMISNG::Util::getBGColor($color)},
				 $outage->{end} =~ /^\d+(\.\d+)?$/?
				 POSIX::strftime("%Y-%m-%dT%H:%M:%S", localtime($outage->{end})) : $outage->{end}),


			td({class=>'info',style=>NMISNG::Util::getBGColor($color)}, $outage->{change_id}),
			td({class=>'info',style=>NMISNG::Util::getBGColor($color)}, $status),
			td({class=>'info'},a({href=>url(-absolute=>1)."?act=outage_table_dodelete&id=$outage->{id}&widget=$widget"},'delete'))
			);
	}

	if (@out)
	{
		print @out;
	}
	else
	{
		print Tr(td({class=>'info',colspan=>'6'}, 'No outage current' . ($node ne ''? " of Node $node": "")));
	}

	print end_table;
	print end_form;

	my $script = <<ENDS;

	function dateChanged(cal) {
        var date = cal.date;
        var time = date.getTime();
		time += Date.HOUR;	// add one hour
        var date2 = new Date(time);

		var field = document.getElementById("id_end");
		field.value = date2.print("%d-%b-%Y %H:%M");

	};

  Calendar.setup(
    {
		inputField	:	'id_start',
        ifFormat	:	"%d-%b-%Y %H:%M",
		showsTime	:	true,
		onUpdate	:	dateChanged

	});
  Calendar.setup(
    {
		inputField	:	'id_end',
        ifFormat	:	"%d-%b-%Y %H:%M",
		showsTime	:	true
//		onUpdate	:	dateChanged

	});
ENDS

	Compat::NMIS::pageEnd() if (!$wantwidget);
}


# args: AU, wantwidget, node, start, end, change
# returns hashref with node, start, end, change, error
sub doaddOutage {
	my (%args) = @_;
	my $AU = $args{AU};
	my $wantwidget = $args{wantwidget};

	$AU->CheckAccess("Table_Outages_rw",'header');

	my $node = $args{node};
	my $start = parsedate($args{start}); # convert to number of seconds
	my $end = parsedate($args{end});
	my $change = $args{change};
	my $time = time();

	if ($node eq '') {
		return { node => $node, start => $start, end => $end, change => $change,
			error => "Node not selected" };
	}
	if ($start < $time) {
		return { node => $node, start => '', end => '', change => $change,
			error => "Cannot add Planned Outage with start time less than \"now\" " };
	}
	if ($end <= $start) {
		return { node => $node, start => $start, end => '', change => $change,
			error => "Cannot add start time later then or equal to end time" };
	}

	$change =~ s/,//g; # remove comma to appease brittle event log system

	# process multiple node selection - which arrives \0-packed if POSTed, ie. nonwidget,
	# or comma separated in widget mode
	my $sep = $wantwidget? qr/\s*,\s*/ : qr/\0/;
	my @nodes = split( $sep, $node);

	my $res = NMISNG::Outage::update_outage(frequency => "once",
																					change_id => $change,
																					start => $start,
																					end => $end,
																					meta => { user => $AU->User },
																					selector => { node =>
																												{ name =>
																															(@nodes > 1? \@nodes : $nodes[0]) } }); # array only if more than one

	if (!$res->{success})
	{
		return { node => '', start => $start, end => $end, change => $change,
			error => "Failed to create outage: $res->{error}" };
	}
	return { node => '', error => '' };
}

# args: AU, id
# returns hashref with error
sub dodeleteOutage
{
	my (%args) = @_;
	my $AU = $args{AU};

	$AU->CheckAccess("Table_Outages_rw",'header');

	my $res = NMISNG::Outage::remove_outage(id => $args{id}, meta => { user => $AU->User } );
	if (!$res->{success})
	{
		return { error => "Failed to delete outage $args{id}: $res->{error}" };
	}
	return { error => '' };
}

1;
