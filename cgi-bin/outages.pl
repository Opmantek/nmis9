#!/usr/bin/perl
#
## $Id: outages.pl,v 8.5 2012/04/28 00:59:36 keiths Exp $
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

#
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

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = NMISNG::Util::loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# NMIS Authentication module
use NMISNG::Auth;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if Compat::NMIS::requestServer(headeropts=>$headeropts); }

# default is widgeted mode, only off if explicitely set to false
my $widget = NMISNG::Util::getbool($Q->{widget},"invert")? "false": "true";
# numeric option as $widget needs to remain t/f text
my $wantwidget = $widget eq 'true';

#======================================================================

# select function
if ($Q->{act} eq 'outage_table_view') {			viewOutage();
} elsif ($Q->{act} eq 'outage_table_doadd') {	doaddOutage(); viewOutage();
} elsif ($Q->{act} eq 'outage_table_dodelete') {	dodeleteOutage(); viewOutage();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Outage: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

exit;

#===================

sub viewOutage
{
	my @out;
	my $node = $Q->{node};

	my $title = $node? "Outages for $node" : "List of Outages";

	my $time = time();

	print header($headeropts);
	Compat::NMIS::pageStartJscript(title => $title, refresh => 86400) if (!$wantwidget);

	my $NT = Compat::NMIS::loadNodeTable();
	my $res = NMISNG::Outage::find_outages(); # attention: cannot filter by affected node
	if (!$res->{success})
	{
		$Q->{error} = "Cannot find outages: $res->{error}";
		return;
	}
	my @outages = @{$res->{outages}};


	my $S = NMISNG::Sys->new;
	$S->init(name=>$node,snmp=>'false');

	# start of form
	print start_form(-id=>"nmisOutages", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "outage_table_doadd")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	# doesn't make sense to run the bar creator if it can't create any output anyway...
	print Compat::NMIS::createHrButtons(node=>$node, system=>$S, refresh=>$Q->{refresh},
																			widget=>$widget, conf => $Q->{conf}, AU => $AU)
			if ($node);

	print start_table;

	if ($AU->CheckAccess("Table_Outages_rw",'check')) {

		my $start = $time+300;
		my $end = $time+3600;
		my $change = 'ticket #';
		if ($Q->{error} ne '') {
			$start = $Q->{start};
			$end = $Q->{end};
			$change = $Q->{change};
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

		if ($Q->{error} ne '') {
			print Tr(td({class=>'error',colspan=>'3'},$Q->{error}));
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
			td({class=>'info'},a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=outage_table_dodelete&id=$outage->{id}&widget=$widget"},'delete'))
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


sub doaddOutage {

	$AU->CheckAccess("Table_Outages_rw",'header');

	my $node = $Q->{node};
	my $start = parsedate($Q->{start}); # convert to number of seconds
	my $end = parsedate($Q->{end});
	my $change = $Q->{change};
	my $time = time();

	$Q->{start} = $start; # in case of error
	$Q->{end} = $end;

	if ($node eq '') {
		$Q->{error} = "Node not selected";
		return;
	}
	if ($start < $time) {
		$Q->{start} = $Q->{end} = '';
		$Q->{error} = "Cannot add Planned Outage with start time less than \"now\" ";
		return;
	}
	if ($end <= $start) {
		$Q->{end} = '';
		$Q->{error} = "Cannot add start time later then or equal to end time";
		return;
	}

	$Q->{node} = '';			# fixme: what is that for??
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
		$Q->{error} = "Failed to create outage: $res->{error}";
		return;
	}
}

# requires the outage id
sub dodeleteOutage
{
	$AU->CheckAccess("Table_Outages_rw",'header');

	$Q->{node} = '';                                                        # fixme what is that for?

	my $res = NMISNG::Outage::remove_outage(id => $Q->{id}, meta => { user => $AU->User } );
	if (!$res->{success})
	{
		$Q->{error} = "Failed to delete outage $Q->{id}: $res->{error}";
	}
}
