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
use NMIS;
use Sys;
use func;

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

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

# default is widgeted mode, only off if explicitely set to false
my $widget = getbool($Q->{widget},"invert")? "false": "true";
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

sub viewOutage {

	my @out;
	my $node = $Q->{node};
	
	my $title = $node? "Outages for $node" : "List of Outages";

	my $time = time();

	print header($headeropts);
	pageStartJscript(title => $title, refresh => 86400) if (!$wantwidget);
	
	my $OT = loadOutageTable();
	my $NT = loadNodeTable();

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');

	# start of form
	print start_form(-id=>"nmisOutages", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "outage_table_doadd")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print createHrButtons(node=>$node, system=>$S, refresh=>$Q->{refresh},widget=>$widget);

	print start_table;

	if ($AU->CheckAccess("Table_Outages_rw",'check')) {

		print Tr(td({class=>'header',colspan=>'6'},'Add Outage'));
	
		print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center'},'Start'),
			td({class=>'header',align=>'center'},'End'),
			td({class=>'header',align=>'center'},'Change'),
			td({class=>'header',align=>'center',colspan=>'2'},'Action')
			);
	
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
		print Tr(
			td({class=>'info'},
				scrolling_list(-name=>'node',-multiple=>'true',-size=>'12',override=>'1',-values=>\@nodes,-default=>\@nd) ),
			td({class=>'info'},
				textfield(-name=>'start',-id=>'id_start',-style=>'background-color:yellow;width:100%;',override=>'1',
					-value=>returnDateStamp($start)),div({-id=>'calendar-start'}) ),
			td({class=>'info'},
				textfield(-name=>'end',-id=>'id_end',-style=>'background-color:yellow;width:100%;',override=>'1',
					-value=>returnDateStamp($end)),div({-id=>'calendar-end'}) ),
			td({class=>'info'},
				textfield(-name=>'change',-style=>'background-color:yellow;width:200px;',override=>'1',-value=>$change)),
			td({class=>'info',colspan=>'2',align=>'center'},
				button(-name=>'button',-onclick=> ($wantwidget? "get('nmisOutages');" : "submit()"),
							 -value=>"Add"))
			);
		if ($Q->{error} ne '') {
			print Tr(td({class=>'error',colspan=>'6'},$Q->{error}));
		}
	}

	#====

	my $hd = ($node ne "") ? "Outage Table of Node $node" : "Outage Table";
	print Tr(td({class=>'header',colspan=>'6'},$hd));

	push @out, Tr(
		td({class=>'header',align=>'center'},'Node'),
		td({class=>'header',align=>'center'},'Start'),
		td({class=>'header',align=>'center'},'End'),
		td({class=>'header',align=>'center'},'Change'),
		td({class=>'header',align=>'center'},'Status'),
		td({class=>'header',align=>'center'},'Action')
		);
	foreach my $ot (sortall($OT,'start','rev')) {
		next unless $AU->InGroup($NT->{$OT->{$ot}{node}}{group});
		next if $Q->{node} ne '' and $node !~ /$OT->{$ot}{node}/;

		my $outage = 'closed';
		my $color = "#FFFFFF";
		if ($OT->{$ot}{start} <= $time and $OT->{$ot}{end} >= $time) {
			$outage = 'current';
			$color = "#00FF00";
		} elsif ($OT->{$ot}{start} >= $time) {
			$outage = 'pending';
			$color = "#FFFF00";
		}

		push @out, Tr(
			td({class=>'info',style=>getBGColor($color)},$NT->{$OT->{$ot}{node}}{name}),
			td({class=>'info',style=>getBGColor($color)},returnDateStamp($OT->{$ot}{start})),
			td({class=>'info',style=>getBGColor($color)},returnDateStamp($OT->{$ot}{end})),
			td({class=>'info',style=>getBGColor($color)},$OT->{$ot}{change}),
			td({class=>'info',style=>getBGColor($color)},$outage),
			td({class=>'info'},a({href=>url(-absolute=>1)."?conf=$Q->{conf}&act=outage_table_dodelete&hash=$ot&widget=$widget"},'delete'))
			);
	}
	if ($#out > 0) {
		print @out;
	} else {
		print Tr(td({class=>'info',colspan=>'5'},'No outage current',eval { return " of Node $node" if $node ne '';}));
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

	pageEnd() if (!$wantwidget);
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

	$change =~ s/,//g; # remove comma

	my ($OT,$handle) = loadTable(dir=>'conf',name=>'Outage',lock=>'true');

	# process multiple node select
	foreach my $nd ( split(/,/,$node) ) {
		my $outageHash = "$nd-$start-$end"; # key
		$OT->{$outageHash}{node} = $nd;
		$OT->{$outageHash}{start} = $start;
		$OT->{$outageHash}{end} = $end;
		$OT->{$outageHash}{change} = $change;
		$OT->{$outageHash}{user} = $AU->User();
	}

	writeTable(dir=>'conf',name=>'Outage',data=>$OT,handle=>$handle);

	$Q->{node} = '';
}

sub dodeleteOutage {

	$AU->CheckAccess("Table_Outages_rw",'header');

	outageRemove(key=>$Q->{hash});


	$Q->{node} = '';
}

