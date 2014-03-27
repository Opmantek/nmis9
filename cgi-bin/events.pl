#!/usr/bin/perl
#
## $Id: events.pl,v 8.9 2012/10/02 03:38:06 keiths Exp $
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
use NMIS;
use func;

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("tls_event_db","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

my $widget = "true";
if ($Q->{widget} eq 'false' ) {	
	$widget = "false"; 
}
#======================================================================

# select function

if ($Q->{act} eq 'event_table_view') {			viewEvent();
} elsif ($Q->{act} eq 'event_table_list') {		listEvent();
} elsif ($Q->{act} eq 'event_table_update') {	updateEvent(); listEvent();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Tables: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit 1;

#==================================================================
#
#

sub viewEvent {

	my $node = $Q->{node};

	#start of page
	print header($headeropts);
	pageStartJscript(title => "NMIS View Event $node",refresh => 86400) if ($widget eq "false");

	my $ET = loadEventStateNoLock();

	print createHrButtons(node=>$node,refresh=>$Q->{refresh},widget=>$widget);

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
	my $cnt = 0;
	for my $event_hash (sorthash($ET,['startdate'],'fwd')) {
		if ($ET->{$event_hash}{node} eq $node) {
			$cnt++;
			my $state = $ET->{$event_hash}{ack} eq 'false' ? 'active' : 'inactive';
			print Tr( eval { my $line;
				$line .= td({class=>'info Plain'},a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$node"},$node));
				my $outage = convertSecsHours(time() - $ET->{$event_hash}{startdate});
				$line .= td({class=>'info Plain'},$outage);
				$line .= td({class=>'info Plain'},returnDateStamp($ET->{$event_hash}{startdate}));
				$line .= td({class=>'info Plain'},$ET->{$event_hash}{event});
				$line .= td({class=>'info Plain'},$ET->{$event_hash}{level});
				$line .= td({class=>'info Plain'},$ET->{$event_hash}{element});
				$line .= td({class=>'info Plain'},$ET->{$event_hash}{details});
				$line .= td({class=>'info Plain',align=>'center'},$ET->{$event_hash}{escalate});
				$line .= td({class=>'info Plain',align=>'center'},$state);
				return $line;
			});
		}
	}

	if ($cnt == 0) {
		print Tr(td({class=>'info Plain',colspan=>'4'},"No events current of Node $node"));
	}
	print end_table,end_td,end_Tr;
	print end_table;
	pageEnd() if ($widget eq "false");
}


###
sub listEvent {

	print header($headeropts);
	pageStart(title => "NMIS List Events") if ($widget eq "false");

	my $ET = loadEventStateNoLock();

	# verify access to this command/tool bar/button
	#
#	if ( $AU->Require ) {
#		# CheckAccess will throw up a web page and stop if access is not allowed
#		$AU>CheckAccess("eventcur") or die "Attempted unauthorized access";
#	}

	# start of form
	print start_form(-id=>"src_events_form",-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=event_table_update");

	print start_table;

	displayEvents($ET,"Localhost"); #single server

	print end_table;
	print end_form;

	pageEnd() if ($widget eq "false");

}

sub displayEvents {
	my $ET = shift; # eventTable
	my $server = shift; # name of server

	my $event_hash;
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
	my $cleanedSysLocation;
	my $node_cnt;

	my $node = $Q->{node};

	my $C = loadConfTable();
	my $NT = loadNodeTable();
	my $GT = loadGroupTable();

	# only display the table if there are any events.
	if (not scalar keys %{$ET}) {
		print Tr(td({class=>'info Plain'},"No Events Current"));
		return; # ready
	}

	# rip thru the table once and count all the events by node....helps heaps later.
	foreach $event_hash ( keys %{$ET})  {
		if ( $ET->{$event_hash}{ack} eq 'true' ) {
			$eventackcount{$ET->{$event_hash}{node}} +=1;
		}
		else {
			$eventnoackcount{$ET->{$event_hash}{node}} +=1;
		}
		$eventcount{$ET->{$event_hash}{node}} +=1;
	}

	# always print the active event table header
	$tempnode='';
	$tempnodeack = '';
	my $display = '';
	my $tmpack = '';
	my $match = 'false';

	my $event_cnt = 0; # index for update routine eventAck()

	# header
	print Tr(th({class=>'title',colspan=>'10'},"$server Event List"));

	foreach $event_hash ( sort {
			$ET->{$a}{ack} cmp  $ET->{$b}{ack} or
			$ET->{$a}{node} cmp $ET->{$b}{node} or
			$ET->{$b}{startdate} cmp $ET->{$a}{startdate} or
			$ET->{$a}{escalate} cmp $ET->{$b}{escalate}
		} keys %{$ET})  {

		next if $ET->{$event_hash}{node} eq '';
		# check auth
		next unless $AU->InGroup($NT->{$ET->{$event_hash}{node}}{group});

		# print all events

		# print header if ack changed
		if ($tempnodeack ne $ET->{$event_hash}{ack}) {
			$tempnodeack = $ET->{$event_hash}{ack};
			typeHeader();
		}

		if ($tmpack ne 'false' and $ET->{$event_hash}{ack} eq 'false') {
			$tmpack = 'false';
			print Tr(td({class=>'heading3',colspan=>'10'},"Active Events. (Set All Events Inactive",
						checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'false$server')",-checked=>'',override=>'1'),
					")"));
		}

		if ($tmpack ne 'true' and $ET->{$event_hash}{ack} eq 'true') {
			$tmpack = 'true';
			$display ='none';
			$node_cnt = 0;
			print Tr(td({class=>'heading3',colspan=>'10'},"Inactive Events. (Set All Events Active ",
						checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'true$server')",-checked=>'',override=>'1'),
					")"));
		}

		if ( $tempnode ne $ET->{$event_hash}{node} ) {
			$tempnode = $ET->{$event_hash}{node};
			$node_cnt = 0;

			active($server,$tempnode,$tempnodeack,\%eventnoackcount) if $ET->{$event_hash}{ack} eq 'false';
			inactive($server,$tempnode,$tempnodeack,\%eventackcount) if $ET->{$event_hash}{ack} eq 'true';

		}

		# now write the events, hidden or not hidden
		if ( $ET->{$event_hash}{ack} eq "false" ) {
			$color = eventColor($ET->{$event_hash}{level});
		}
		else {
			$color = "white";
		}
		$start = returnDateStamp($ET->{$event_hash}{startdate});
		$last = returnDateStamp($ET->{$event_hash}{lastchange});
		$outage = convertSecsHours(time() - $ET->{$event_hash}{startdate});
		# User logic, hmmmm how will users interpret this!
		if ( $ET->{$event_hash}{ack} eq "false" ) {
			$button = "true";
		}
		else {
			$button = "false";	
		}
		# print row , Tr with id for set hidden
		### 2012-10-02 keiths, changed color to be done by CSS
		print Tr({id=>"$ET->{$event_hash}{ack}$tempnode$node_cnt",style=>"display:$display;"},
			td({class=>"info $ET->{$event_hash}{level}"},
				eval {
					return $AU->CheckAccess("src_events","check")
						? a({href=>"logs.pl?&conf=$Q->{conf}&act=log_file_view&logname=Event_Log&search=$ET->{$event_hash}{node}&sort=descending"},$ET->{$event_hash}{node})
							: "$ET->{$event_hash}{node}";
					}),
			td({class=>"info $ET->{$event_hash}{level}"},$outage),
			td({class=>"info $ET->{$event_hash}{level}"},$start),
			td({class=>"info $ET->{$event_hash}{level}"},$ET->{$event_hash}{event}),
			td({class=>"info $ET->{$event_hash}{level}"},$ET->{$event_hash}{level}),
			td({class=>"info $ET->{$event_hash}{level}"},$ET->{$event_hash}{element}),
			td({class=>"info $ET->{$event_hash}{level}"},$ET->{$event_hash}{details}),
			td({class=>"info $ET->{$event_hash}{level}",align=>'center'},
				checkbox(-name=>"$ET->{$event_hash}{ack}$server$tempnode",-value=>"$event_cnt",-label=>'',override=>'1')),
			td({class=>"info $ET->{$event_hash}{level}",align=>'right'},$ET->{$event_hash}{escalate}),
			td({class=>"info $ET->{$event_hash}{level}"},$ET->{$event_hash}{user})
			);

		print hidden(-name=>"node",-default=>"$ET->{$event_hash}{node}",override=>'1');
		print hidden(-name=>"event",-default=>"$ET->{$event_hash}{event}",override=>'1');
		print hidden(-name=>"element",-default=>"$ET->{$event_hash}{element}",override=>'1');
		print hidden(-name=>"ack",-default=>"$button",override=>'1');

		$event_cnt++;
		$node_cnt++;
	} # foreach $event_hash

	print Tr(td({class=>'info Plain',colspan=>'8',align=>'right'},
				button(-name=>'button',onclick=>"get('src_events_form');",-value=>"Submit Changes")),
					td({class=>'info Plain',colspan=>'2'}, '&nbsp'));

	# java - ack=false event=active
	sub active {
		my $server =shift;
		my $tempnode = shift;
		my $tempnodeack = shift;
		my $eventnoackcount = shift;
		print Tr(td({class=>'header'},
			a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$tempnode",onClick=>"ExpandCollapse(\"false$tempnode\")"},$tempnode)),
				td({class=>'info Plain',colspan=>'9'},
				img({src=>"$C->{'<menu_url_base>'}/img/sumup.gif",id=>"false${tempnode}img",border=>'0'}),
				"&nbsp;$eventnoackcount->{$tempnode} Event(s)",
				"&nbsp;(Set Events Inactive for $tempnode ",
				checkbox(-name=>'checkbox_name',-label=>'',-onClick=>"checkBoxes(this,'$tempnodeack$server$tempnode')",-checked=>'',override=>'1'),
				")"));
	} # sub active

	# java - ack=true event=inactive
	sub inactive {
		my $server =shift;
		my $tempnode = shift;
		my $tempnodeack = shift;
		my $eventackcount = shift;
		print Tr(td({class=>'header'},
			a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$tempnode",onClick=>"ExpandCollapse(\"true$tempnode\")"},$tempnode)),
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

} # sub displayEvents

# change ack from Event
sub updateEvent {

#	my $C = loadConfTable();
#	my $NT = loadNodeTable();

	my @par = $q->param(); # parameter names
	my @nm = $q->param('node'); # node names
	my @elmnt = $q->param('element'); # event details
	my @ack = $q->param('ack'); # event ack status
	my @evnt = $q->param('event'); # event type

	#print STDERR "DEBUG: par=@par\n";
	#print STDERR "DEBUG: nm=@nm\n";
	#print STDERR "DEBUG: elmnt=@elmnt\n";
	#print STDERR "DEBUG: ack=@ack\n";
	#print STDERR "DEBUG: evnt=@evnt\n";
	#print STDERR "DEBUG: $ENV{REQUEST_URI}\n";
	

	# the value of the checkbox is equal to the index of arrays
	my $i = 0;
	# the value of the checkbox is equal to the index of arrays
	for my $par (@par) {
		if ($par =~ /false|true/) { 		# false|true is part of the checkbox name
			my @a = $q->param($par);		# get the values (numbers) of the checkboxes
			foreach my $i (@a) {
				# check for change of event
				if ($i ne "" and (($ack[$i] eq "true" and $par =~ /false/) or ($ack[$i] eq "false" and $par =~ /true/))) {
					# event changes
					eventAck(ack=>$ack[$i],node=>$nm[$i],event=>$evnt[$i],element=>$elmnt[$i],user=>$AU->User());
					#print STDERR "DEBUG: eventAck(ack=>$ack[$i],node=>$nm[$i],event=>$evnt[$i],element=>$elmnt[$i],user=>$AU->User())\n";
					
				}
			}
		}
	}
}
