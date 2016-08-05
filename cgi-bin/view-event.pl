#!/usr/bin/perl
#
## $Id: view-event.pl,v 8.5 2012/10/02 05:45:49 keiths Exp $
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
use Fcntl qw(:DEFAULT :flock);
use Sys;

use vars qw($CT); # Contact table

use CGI qw(:standard *table *Tr *td *form *Select *div);
my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash

# this cgi script defaults to widget mode ON
my $wantwidget = exists $Q->{widget}? !getbool($Q->{widget}, "invert") : 1;
my $widget = $wantwidget ? "true" : "false";

my $C;
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# NMIS Authentication module
use Auth;

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("tls_event_flow","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

my $colspan = 6;

# select function

if ($Q->{act} eq 'event_database_list') {			displayEventList();
} elsif ($Q->{act} eq 'event_database_view') {		displayEvent();
} elsif ($Q->{act} eq 'event_database_delete') {	displayEvent();
} elsif ($Q->{act} eq 'event_database_dodelete') 
{	
	# deletion requires node, event, element arguments
	if (my $err = eventDelete( event => { node => $Q->{node},
																				event => $Q->{event},
																				element => $Q->{element} } ))
	{
		logMsg("ERROR: event deletion failed: $err");
	}

	displayEventList();
} elsif ($Q->{act} eq 'event_flow_view') {			displayFlow();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	pageStart(title => "View Events - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);
	print "View Event: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
	pageEnd if (!$wantwidget);
}

exit 0;

#===================

#
# display the event flow request fields and the event database entries
#
sub displayFlow{

	print header($headeropts);
	pageStart(title => "View Event Flow - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	my %events = ( 
		event => ["Generic Down", "Generic Up", "Interface Down", "Interface Up",
					"Node Down", "Node Reset", "Node Up", "Node Failover", "Proactive", "Proactive Closed",
					"RPS Fail", "SNMP Down", "SNMP Up"],
		node => [ sort keys %{loadLocalNodeTable()} ]
	);

	# the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"tls_event_flow_form", -href => url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "event_flow_view")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table;

	# show a link home if not in widget mode
	my $homelink = $wantwidget? "" : (a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;");

	# first print header and boxes for event flow analyzing
	print Tr(td({class=>'header',colspan=>'4'},"${homelink}View Event Flow"));

	my @headers = ("Event", "Node", "Element","view");
	print Tr( 
		eval { my $line;
			for (@headers) {
				$line .= td({class=>'header',align=>'center',width=>'120px'},$_);
			}
			return $line;
		} );

	print Tr( 
		eval { my $line;
			for (@headers) {
				my $field = lc $_;
				if ($field eq "view" ) {
					$line .= td({class=>'info',align=>'center'},button(-name=>'button',
																														 onclick => ($wantwidget? 
																																				 "get('tls_event_flow_form');"
																																				 : "submit()" ),
																														 -value=>'Go'));
				} else {
					if ($events{$field} ne '' ) {
						$line .= td({class=>'info'},
								popup_menu(-name=>"$field",-values=>$events{$field},-default=>$Q->{$field},-style=>'width:100%'));
					} else {
						my $value = $Q->{$field} eq '' ? '.' : $Q->{$field};
						$line .= td({class=>'info'},
							textfield(-name=>"$field",-style=>'width:100%',-value=>$value));
					}
				}
			}
			return $line;
		} );
	print end_table;
	print end_form;

	if ($Q->{event} ne '') { displayEventFlow(); }
	pageEnd if (!$wantwidget);
}

sub displayEventList
{
	print header($headeropts);
	pageStart(title => "View Event Database - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	# load all events, for all nodes
	my %allevents = loadAllEvents;

	# second print a list of event database entries
	print start_table;
	# show a link home if not in widget mode
	my $homelink = $wantwidget? "" : (a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;");

	print Tr(td({class=>'header',colspan=>'3'},"${homelink}View Event Database"));
	my $flag = 0;
	foreach my $eventkey (sort keys %allevents)  
	{
		my $thisevent = $allevents{$eventkey};
		next if (!getbool($thisevent->{current}));

		my $start = $thisevent->{startdate};
		my $date = returnDate($thisevent->{startdate});
		my $time = returnTime($thisevent->{startdate});
		my $node = $thisevent->{node};
		my $event = $thisevent->{event};
		my $element = $thisevent->{element};
		my $details = $thisevent->{details};
		my $line = "$date $time $node - $event - $element";
		$flag++;
		print Tr(td({class=>'info'},
								a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_view&node=$node&event=$event&element=$element&widget=$widget"},$line)),
						 td({class=>'info'},a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$node&widget=$widget"},'View Node')),
						 td({class=>'info'},a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_delete&node=$node&event=$event&element=$element&widget=$widget"},'Delete Event'))
				);
	}
	print Tr(td({class=>'info'},"no event current")) if !$flag;
	print end_table;
	pageEnd if (!$wantwidget);
}

#
# display one entry of the event database
#
sub	displayEvent {

	print header($headeropts);
	pageStart(title => "View Event Database - $Q->{node} - $C->{server_name}", refresh => $Q->{refresh}) if (!$wantwidget);

	print start_table;

	# show a link home if not in widget mode
	my $homelink = $wantwidget? "" : (a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;");
	
	print Tr(td({class=>'header',colspan=>'6'},"${homelink}View Event Database - $Q->{node}"));
	
	displayEventItems();

	print end_table;
	pageEnd if (!$wantwidget);
}

#
# display the event flow using the event policy table and the event escalation table
#
sub displayEventFlow {
	my $node = $Q->{node};
	my $event = $Q->{event};
	my $element = $Q->{element};
	my $pol_event;
	my $level;

	print start_table;

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	my $role = lc $NI->{system}{roleType};
	my $type = $NI->{system}{nodeType};

	print Tr(td({class=>'header',colspan=>'6'},"Event Policy"));

	if ($NI->{system}{nodeModel} eq '') {
		print Tr(td({class=>'error'},"this node does not have a node Model"));
		return;
	}

	# Get the event policy and the rest is easy.
	if ( 	$event =~ /Proactive.*Closed/ ) { $pol_event = "Proactive Closed"; }
	elsif ( $event =~ /Proactive/ ) 	{ $pol_event = "Proactive"; }
	elsif ( $event =~ /down/i and $event !~ /SNMP|Node|Interface/ ) { 
		$pol_event = "Generic Down";
	}
	elsif ( $event =~ /up/i and $event !~ /SNMP|Node|Interface/ ) { 
		$pol_event = "Generic Up";
	}
	else 	{ $pol_event = $event; }

	# get the level from the model
	if (!($level = $M->{event}{event}{lc $pol_event}{$role}{level})) {
		$pol_event = 'default';
		if (!($level = $M->{event}{event}{lc $pol_event}{$role}{level})) {
			# not found
			$level = "Normal";
			printRow(1,"level","event=$pol_event, role=$role not found in section event of model=$M->{node}{nodeModel}");
			return;
		}
	}

	printRow(1,"info","event $event not found in Model, replaced by default") if $pol_event eq 'default';
	printRow(1,"event",$pol_event);
	printRow(1,"role",$role);
	printRow(1,"type",$type);
	printRow(1,"level",$level);

	$Q->{event} = $pol_event;
	$Q->{level} = $level;
	$Q->{role} = $role;
	$Q->{type} = $type;

	if ($event !~ /Proactive.*Closed/ ) {	
		print Tr(td({class=>'header',colspan=>'6'},'Event Escalation'));
		displayEventItems(flag=>"true");
	}

	print end_table;;
}

#
# display the items of a event using the escalation table
#
sub displayEventItems {
	my %args = @_;
	my $flag = $args{flag};

	my $node = $Q->{node};
	my $event = $Q->{event};
	my $element = $Q->{element};
	my $details = $Q->{details};
	my $level = $Q->{level};

	my $time;
	my $date;
	my $line;
	my %keyhash;
	my $esc_key;
	my $field;
	my $target;
	my @x;
	my $contact;

	# load Contact table
	$CT = loadContactsTable();
	# load the escalation policy table
	my $EST = loadEscalationsTable();
	# load Node table
	my $NT = loadLocalNodeTable();

	# suck in this one event
	my $thisevent = eventLoad(node => $node, event => $event, element => $element);
	if (!$thisevent)
	{
		print Tr(td({class=>'info'},"No such event!"));
		return;
	}

	if ( getbool($flag) ) 
	{
		# generate entry for display event Flow
		$thisevent->{current} = "true";
		$thisevent->{startdate} = time;
		$thisevent->{lastchange} = time;
		$thisevent->{node} = $node;
		$thisevent->{event} = $event;
		$thisevent->{level} = $level;
		$thisevent->{element} = $element;
		$thisevent->{details} = $details;
		$thisevent->{ack} = "true";
		$thisevent->{escalate} = -1;
		$thisevent->{notify} = "false";
		$thisevent->{user} = "";
	}

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->ndinfo;

	my $group = lc $NT->{$thisevent->{node}}{group}; # group of node
	my $role = lc $NI->{system}{roleType}; # role of node
	my $type = lc $NI->{system}{nodeType}; # type of node
	my $escalate = $thisevent->{escalate};	# save this as a flag

	# set the current event time
	my $outage_time = time - $thisevent->{startdate};

	$date = returnDate($thisevent->{startdate});
	$time = returnTime($thisevent->{startdate});
	printRow(1,"start time","$date $time");

	printRow(1,"node",$thisevent->{node});

	# info
	my $ack_str = getbool($thisevent->{ack}) ?  ", event waiting for activating" : ", event active"; 
	my $esc_str = ($thisevent->{escalate} eq -1) ? ", no level set" : "";
	my $ntf_str = ($thisevent->{notify} ne '') ? $thisevent->{notify} : "no UP notify sending";

	printRow(1,"event",$thisevent->{event});
	printRow(1,"event level",$thisevent->{level});
	printRow(1,"element",$thisevent->{element});
	printRow(1,"details",$thisevent->{details});
	printRow(1,"acknowledge",$thisevent->{ack}.$ack_str);
	printRow(1,"current",$thisevent->{current});
	printRow(1,"escalate","level $thisevent->{escalate} $esc_str");
	printRow(1,"user",$thisevent->{user});
	printRow(1,"notify up",$ntf_str);

	my ($outage,undef) = outageCheck($thisevent->{node},time());
	if ( $outage eq "current" 
			 and getbool($thisevent->{ack},"invert") ) {
		# check outage
		printRow(1,"status","node at Outage, no escalation");
	}

	if ( exists $NT->{$thisevent->{node}}{depend} ) {
		# we have list of nodes that this node depends on in $NT->{$runnode}{depend}
		# if any of those have a current Node Down alarm, then lets just move on with a debug message
		# should we log that we have done this - maybe not....

		foreach my $node_depend ( split /,/ , lc($NT->{$thisevent->{node}}{depend}) ) {
			next if $node_depend eq "N/A" ;		# default setting
			next if $node_depend eq $thisevent->{node};	# remove the catch22 of self dependancy.
			if ( eventExist($node_depend, "Node Down", "" ) ) {
				printRow(1,"status","dependant $node_depend is reported as down");
				return;
			}
		}
	}

	# checking that we have a valid node -the node may have been deleted.
	if ( !exists $NT->{$thisevent->{node}}{name} ) {
		printRow(1,"status","node deleted");
		goto DELETE;
	}

	$event = lc($event);
	# Escalation_Key=Group:Role:Type:Event
	my @keylist = (
						$group."_".$role."_".$type."_".$event ,
						$group."_".$role."_".$type."_"."default",
						$group."_".$role."_"."default"."_".$event ,
						$group."_".$role."_"."default"."_"."default",
						$group."_"."default"."_".$type."_".$event ,
						$group."_"."default"."_".$type."_"."default",
						$group."_"."default"."_"."default"."_".$event ,
						$group."_"."default"."_"."default"."_"."default",
						"default"."_".$role."_".$type."_".$event ,
						"default"."_".$role."_".$type."_"."default",
						"default"."_".$role."_"."default"."_".$event ,
						"default"."_".$role."_"."default"."_"."default",
						"default"."_"."default"."_".$type."_".$event ,
						"default"."_"."default"."_".$type."_"."default",
						"default"."_"."default"."_"."default"."_".$event ,
						"default"."_"."default"."_"."default"."_"."default"
		);

	# lets allow all possible keys to match !
	# so one event could match two or more escalation rules
	# can have specific notifies to one group, and a 'catch all' to manager for example.
	foreach my $klst( @keylist ) {
		foreach my $esc (keys %{$EST}) {
			my $esc_short = lc "$EST->{$esc}{Group}_$EST->{$esc}{Role}_$EST->{$esc}{Type}_$EST->{$esc}{Event}";
			$EST->{$esc}{Event_Node} = ($EST->{$esc}{Event_Node} eq '') ? '.*' : $EST->{$esc}{Event_Node};
			$EST->{$esc}{Event_Element} = ($EST->{$esc}{Event_Element} eq '') ? '.*' : $EST->{$esc}{Event_Element};
			$EST->{$esc}{Event_Node} =~ s;/;;g;
			$EST->{$esc}{Event_Element} =~ s;/;;g;
			if ($klst eq $esc_short and
					$thisevent->{node} =~ /$EST->{$esc}{Event_Node}/i and 
					$thisevent->{element} =~ /$EST->{$esc}{Event_Element}/i ) {
				$keyhash{$esc} = $klst;
				dbg("match found for escalation key=$esc");
			}
		}

	}
	foreach $esc_key ( keys %keyhash ) {
		# have a matching escalation record for the hash key, and an index into the array.
		# display the escalation entry
		print Tr(td({class=>'header',colspan=>'8'},'&nbsp;'));
		my @field = split /_/, $esc_key;
		printRow(2,"group",$field[0]);
		printRow(2,"role",$field[1]);
		printRow(2,"type",$field[2]);
		printRow(2,"event",$field[3]);
		printRow(2,"message","Escalation $thisevent->{node} $thisevent->{event_level} $thisevent->{event}\n $thisevent->{element} $thisevent->{details}");
		my $not_str = getbool($EST->{$esc_key}{UpNotify}) ? ", an UP event notification will be sent to the list of Contacts who received a \'down\' event notification" : "";
		printRow(2,"upnotify","$EST->{$esc_key}{UpNotify} $not_str");


		for my $lvl (0..10) {
			# get the string of type email:contact1:contact2,netsend:contact1:contact2,pager:contact1:contact2,email:sysContact
			$level = lc ($EST->{$esc_key}{'Level'.$lvl});
			my $escalate = "escalate".$lvl;
			if ( $level ne "" ) {
				printRow(2,"level$lvl",$level);
				$date = returnDate($thisevent->{startdate}+$C->{$escalate});
				$time = returnTime($thisevent->{startdate}+$C->{$escalate});
				printRow(3,"time","$date $time");
				# Now we have a string, check for multiple notify types
				foreach $field ( split "," , $level ) {
					$target = "";
					@x = split /:/ , $field;
					$type = shift @x;			# netsend, email, or pager ?
					if ( $type eq "email" ) {
						my $contact_cnt = 0;
						foreach $contact (@x) {
							# if sysContact, use device syscontact as key into the contacts table hash
							if ( $contact eq "syscontact" ) {
								my $contact_p = $contact;
								$contact = $NI->{system}{sysContact};
								printRow(3,"contact","$contact_p replaced by $contact");
							}
							if ( exists $CT->{$contact} ) {
								$contact_cnt++;
								printRow(3,"contact",$contact);
								printRowDutyTime(4,$contact);
								printRowTimeZone(5,$contact);
								printRowEmail(4,$contact);
								### cologne, pass on
								&printPassOn($contact,1);
								###
							} else {
								printRow(3,"contact","$contact not found in Contacts","error");
							}
						}

						if ( $contact_cnt eq 0 ) { 
							$target = $CT->{default}{Email};
							$contact = "default";
						}
						if ($target) {
							printRow(3,"contact",$contact);
							printRowDutyTime(4,$contact);
							printRowTimeZone(5,$contact);
							printRowEmail(4,$contact);
						}
					} # email
					if ( $type eq "ccopy" ) {
						my $contact_cnt = 0;
						foreach $contact (@x) {
							# if sysContact, use device syscontact as key into the contacts table hash
							if ( $contact eq "syscontact" ) {
								my $contact_p = $contact;
								$contact = $NI->{system}{sysContact};
								printRow(3,"contact","$contact_p replaced by $contact");
							}
							if ( exists $CT->{$contact} ) {
								$contact_cnt++;
								printRow(3,"contact",$contact);
								printRowDutyTime(4,$contact);
								printRowTimeZone(5,$contact);
								printRowEmail(4,$contact,"email cc");
								### cologne, pass on
								&printPassOn($contact,1);
								###
							} else {
								printRow(3,"contact","$contact not found in Contacts","error");
							}
						}

						if ( $contact_cnt eq 0 ) { 
							$target = $CT->{default}{Email};
							$contact = "default";
						}
						if ($target) {
							printRow(3,"contact",$contact);
							printRowDutyTime(4,$contact);
							printRowTimeZone(5,$contact);
							printRowEmail(4,$contact,"email cc");
						}
					} # ccopy
					if ( $type eq "netsend" ) {
						foreach $contact ( @x ) {
							printRow(3,"contact",$contact);
							printRow(4,"netsend","message");
						} #foreach
					} # end netsend
					if ( $type =~ /page./i ) {
						my $contact_cnt = 0;
						foreach $contact (@x) {
							# if sysContact, use device syscontact as key into the contacts table hash
							if ( $contact eq "syscontact" ) {
								my $contact_p = $contact;
								$contact = $NI->{system}{sysContact};
								printRow(3,"contact","$contact_p replaced by $contact");
							}
							if ( exists $CT->{$contact} ) {
								$contact_cnt++;
								printRow(3,"contact",$contact);			
								printRowDutyTime(4,$contact);
								printRowTimeZone(5,$contact);
								printRowPager(4,$contact);
								### cologne, pass on
								&printPassOn($contact,1);
								###
							} else {
								printRow(3,"contact","$contact not found in Contacts","error");
							}
						}
						if ( $contact_cnt eq 0 ) { 
							$target = $CT->{default}{Pager};
							$contact = "default";
						}
						if ($target) {
							printRow(3,"contact",$contact);
							printRowDutyTime(4,$contact);
							printRowTimeZone(5,$contact);
							printRowPager(4,$contact);
						}
					} # end pager
				} # end foreach
			} # end if
		} # end for
	} # end foreach
DELETE:
	if ($Q->{act} =~ /delete$/) {
		# $event has been mangled for the escalation lookup...
		print Tr(td({class=>'header'},b('Delete this Event ? ')),
			td(a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_dodelete&node=$node&event="
								.$thisevent->{event}."&element=$element&widget=$widget"},'DELETE')));
	}
	#=====================================================
}

# in column PassOn may be defined Contacts. With dutytime specified there are special possibilities.

sub printPassOn 
{
	my $contact = shift;
	my $passon_lvl = shift;
	
	if ( exists $CT->{$contact}{PassOn} and $CT->{$contact}{PassOn} ne ""){
		if ($passon_lvl < 10) {
			my @passon =  split /:/, lc $CT->{$contact}{PassOn}; # pass on an other contact
			foreach my $contact (@passon) {
				$contact = lc $contact;
				if ( exists $CT->{$contact} ) {
					printRow(4,"pass on - $passon_lvl",$contact);
					printRowDutyTime(5,$contact);
					printRowTimeZone(5,$contact);
					printRowEmail(5,$contact);
				} else {
					printRow(4,"contact","$contact not found in Contacts","error");
				}
				printPassOn($contact,$passon_lvl+1); # walk
			}
		} else {
			printRow(4,"pass on","loop detect","error");
		}
	}
}

#=====================================================

# print a table row

sub printRow 
{
		my $colhead = shift; # position in the row
		my $headtxt = shift; # text of head
		my $datatxt = shift; # text of info
		my $error = shift;   # optional error sign

		my $colfront = $colhead - 1;
		my $colback = $colspan - $colhead;

		my $class = ($error ne "") ? $error : "info" ;

		print Tr( eval { return ($colhead gt 1) ? td({class=>'header',colspan=>"$colfront"},'&nbsp;') : "" ; },
			td({class=>'header'},$headtxt),
			td({class=>"$class",colspan=>"$colback"},$datatxt)
			);
}

#=====================================================

sub printRowEmail 
{
		my $head = shift;
		my $contact = shift;
		my $mail = shift;
		$mail = ($mail ne "") ? $mail : "email";

		printRow($head,$mail,($CT->{$contact}{Email} ne "") ? $CT->{$contact}{Email} : "no address");

}
#=====================================================

sub printRowDutyTime
{
		my $head = shift;
		my $contact = shift;

		if ( $CT->{$contact}{DutyTime} ne "" ) {
			if (checkDutyTime($CT->{$contact}{DutyTime})) {
				printRow($head,"dutytime",$CT->{$contact}{DutyTime});
			} else {
				printRow($head,"dutytime",$CT->{$contact}{DutyTime},"error");
			}
		} else {
			printRow($head,"dutytime","full time");
		}

}
#=====================================================

sub printRowTimeZone
{
	my $head = shift;
	my $contact = shift;
	
	if ($CT->{$contact}{TimeZone} ne 0) { printRow($head,"timezone","$CT->{$contact}{TimeZone} hour");}
	
}
#=====================================================

sub printRowPager
{
		my $head = shift;
		my $contact = shift;

		printRow($head,"pager",($CT->{$contact}{Pager} ne "") ? $CT->{$contact}{Pager} : "no number");

}
#=====================================================

# test the dutytime on syntax
# return true if OK 
sub checkDutyTime 
{
		my $dutytime = shift;
		my $today;
		my $days;
		my $start_time;
		my $finish_time;

		if ($dutytime) {
			( $start_time, $finish_time, $days) = split /:/, $dutytime, 3;
			my $num = length($days)/3 ;
			my $cnt =  $days =~ s/Sun|Mon|Tue|Wed|Thu|Fri|Sat//ig ;
			if ( $cnt eq $num and ($start_time =~ /(\d+)/) and ($finish_time =~ /(\d+)/) ) {
				return 1;
			} else {
				return 0;
			}
		}
}


