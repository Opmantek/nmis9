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

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

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

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("tls_event_flow","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

if ($Q->{act} eq 'event_database_list') {			displayEventList();
} elsif ($Q->{act} eq 'event_database_view') {		displayEvent();
} elsif ($Q->{act} eq 'event_database_delete') {	displayEvent();
} elsif ($Q->{act} eq 'event_database_dodelete') {	deleteEvent(); displayEventList();
} elsif ($Q->{act} eq 'event_flow_view') {			displayFlow();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "View Event: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

exit;

#===================

#
# display the event flow request fields and the event database entries
#
sub displayFlow{

	print header($headeropts);

	my %events = ( 
		event => ["Generic Down", "Generic Up", "Interface Down", "Interface Up",
					"Node Down", "Node Reset", "Node Up", "Node Failover", "Proactive", "Proactive Closed",
					"RPS Fail", "SNMP Down", "SNMP Up"],
		node => [ sort keys %{loadLocalNodeTable()} ]
	);

	print start_form(-id=>"tls_event_flow_form",-action=>"javascript:get('tls_event_flow_form');",
				-href=>"view-event.pl?conf=$Q->{conf}&act=event_flow_view");

	print start_table;

	# first print header and boxes for event flow analyzing
	print Tr(td({class=>'header',colspan=>'4'},'View Event Flow'));

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
					$line .= td({class=>'info',align=>'center'},button(-name=>'button',onclick=>"get('tls_event_flow_form');",-value=>'Go'));
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
}

sub displayEventList{

	print header($headeropts);

	# Load the event table into the hash
	my $ET = loadEventStateNoLock();

	# second print a list of event database entries
	print start_table;
	print Tr(td({class=>'header',colspan=>'3'},'View Event Database'));
	my $flag = 0;
	foreach my $event_hash ( sort keys %{$ET})  {
		next unless exists $ET->{$event_hash}{current};
		my $start = $ET->{$event_hash}{startdate};
		my $date = returnDate($ET->{$event_hash}{startdate});
		my $time = returnTime($ET->{$event_hash}{startdate});
		my $node = $ET->{$event_hash}{node};
		my $event = $ET->{$event_hash}{event};
		my $element = $ET->{$event_hash}{element};
		my $details = $ET->{$event_hash}{details};
		my $line = "$date $time $node - $event - $element";
		$flag++;
		print Tr(td({class=>'info'},a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_view&node=$node&event=$event&element=$element"},$line)),
			td({class=>'info'},a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&node=$node"},'see node')),
			td({class=>'info'},a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_delete&node=$node&event=$event&element=$element"},'delete'))
			);
	}
	print Tr(td({class=>'info'},"no event current")) if !$flag;
	print end_table;

}

#
# display one entry of the event database
#
sub	displayEvent {

	print header($headeropts);

	print start_table;

	print Tr(td({class=>'header',colspan=>'6'},"View Event database - $Q->{node}"));
	
	displayEventItems();

	print end_table;
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

	my $event_hash;
	my $time;
	my $date;
	my $line;
	my %keyhash;
	my $esc_key;
	my $field;
	my $target;
	my @x;
	my $contact;

	my $colspan = 6;

	# load Contact table
	$CT = loadContactsTable();
	# load the escalation policy table
	my $EST = loadEscalationsTable();
	# load Node table
	my $NT = loadLocalNodeTable();
	# Load the event table
	my $ET = loadEventStateNoLock;

	# Lets try node_event_element!!
	$event_hash = eventHash($node, $event, $element);

	if ( getbool($flag) ) {
		# generate entry for display event Flow
		$ET->{$event_hash}{current} = "true";
		$ET->{$event_hash}{startdate} = time;
		$ET->{$event_hash}{lastchange} = time;
		$ET->{$event_hash}{node} = $node;
		$ET->{$event_hash}{event} = $event;
		$ET->{$event_hash}{level} = $level;
		$ET->{$event_hash}{element} = $element;
		$ET->{$event_hash}{details} = $details;
		$ET->{$event_hash}{ack} = "true";
		$ET->{$event_hash}{escalate} = -1;
		$ET->{$event_hash}{notify} = "false";
		$ET->{$event_hash}{user} = "";
	}

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->ndinfo;

	my $group = lc $NT->{$ET->{$event_hash}{node}}{group}; # group of node
	my $role = lc $NI->{system}{roleType}; # role of node
	my $type = lc $NI->{system}{nodeType}; # type of node
	my $escalate = $ET->{$event_hash}{escalate};	# save this as a flag

	# set the current event time
	my $outage_time = time - $ET->{$event_hash}{startdate};

	$date = returnDate($ET->{$event_hash}{startdate});
	$time = returnTime($ET->{$event_hash}{startdate});
	printRow(1,"start time","$date $time");

	printRow(1,"node",$ET->{$event_hash}{node});

	# info
	my $ack_str = getbool($ET->{$event_hash}{ack}) ?  ", event waiting for activating" : ", event active"; 
	my $esc_str = ($ET->{$event_hash}{escalate} eq -1) ? ", no level set" : "";
	my $ntf_str = ($ET->{$event_hash}{notify} ne '') ? $ET->{$event_hash}{notify} : "no UP notify sending";

	printRow(1,"event",$ET->{$event_hash}{event});
	printRow(1,"event level",$ET->{$event_hash}{level});
	printRow(1,"element",$ET->{$event_hash}{element});
	printRow(1,"details",$ET->{$event_hash}{details});
	printRow(1,"acknowledge",$ET->{$event_hash}{ack}.$ack_str);
	printRow(1,"current",$ET->{$event_hash}{current});
	printRow(1,"escalate","level $ET->{$event_hash}{escalate} $esc_str");
	printRow(1,"user",$ET->{$event_hash}{user});
	printRow(1,"notify up",$ntf_str);

	my ($outage,undef) = outageCheck($ET->{$event_hash}{node},time());
	if ( $outage eq "current" 
			 and getbool($ET->{$event_hash}{ack},"invert") ) {
		# check outage
		printRow(1,"status","node at Outage, no escalation");
	}

	if ( exists $NT->{$ET->{$event_hash}{node}}{depend} ) {
		# we have list of nodes that this node depends on in $NT->{$runnode}{depend}
		# if any of those have a current Node Down alarm, then lets just move on with a debug message
		# should we log that we have done this - maybe not....

		foreach my $node_depend ( split /,/ , lc($NT->{$ET->{$event_hash}{node}}{depend}) ) {
			next if $node_depend eq "N/A" ;		# default setting
			next if $node_depend eq $ET->{$event_hash}{node};	# remove the catch22 of self dependancy.
			if ( getbool(&eventExist($node_depend, "Node Down", "" )) ) {
				printRow(1,"status","dependant $node_depend is reported as down");
				return;
			}
		}
	}

	# checking that we have a valid node -the node may have been deleted.
	if ( !exists $NT->{$ET->{$event_hash}{node}}{name} ) {
		printRow(1,"status","node deleted");
		goto DELETE;
	}


	# trim the (proactive) event down to the first 4 keywords or less.
	$event = "";
	my $i = 0;
	foreach my $index ( split /( )/ , lc($ET->{$event_hash}{event}) ) {		# the () will pull the spaces as well into the list, handy !
		$event .= $index;
		last if $i++ == 6;				# max of 4 splits, with no trailing space.
	}

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
					$ET->{$event_hash}{node} =~ /$EST->{$esc}{Event_Node}/i and 
					$ET->{$event_hash}{element} =~ /$EST->{$esc}{Event_Element}/i ) {
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
		printRow(2,"message","Escalation $ET->{$event_hash}{node} $ET->{$event_hash}{event_level} $ET->{$event_hash}{event}\n $ET->{$event_hash}{element} $ET->{$event_hash}{details}");
		my $not_str = getbool($EST->{$esc_key}{UpNotify}) ? ", an UP event notification will be sent to the list of Contacts who received a \'down\' event notification" : "";
		printRow(2,"upnotify","$EST->{$esc_key}{UpNotify} $not_str");


		for my $lvl (0..10) {
			# get the string of type email:contact1:contact2,netsend:contact1:contact2,pager:contact1:contact2,email:sysContact
			$level = lc ($EST->{$esc_key}{'Level'.$lvl});
			my $escalate = "escalate".$lvl;
			if ( $level ne "" ) {
				printRow(2,"level$lvl",$level);
				$date = returnDate($ET->{$event_hash}{startdate}+$C->{$escalate});
				$time = returnTime($ET->{$event_hash}{startdate}+$C->{$escalate});
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
		print Tr(td({class=>'header'},b('Delete this Event ? ')),
			td(a({href=>"view-event.pl?conf=$Q->{conf}&act=event_database_dodelete&hash=$event_hash"},'DELETE')));
	}
	#=====================================================

	# in column PassOn may be defined Contacts. With dutytime specified there are special possibilities.

	sub printPassOn {
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

	sub printRow {
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

	sub printRowEmail {
		my $head = shift;
		my $contact = shift;
		my $mail = shift;
		$mail = ($mail ne "") ? $mail : "email";

		printRow($head,$mail,($CT->{$contact}{Email} ne "") ? $CT->{$contact}{Email} : "no address");

	}
	#=====================================================

	sub printRowDutyTime{
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

	sub printRowTimeZone{
		my $head = shift;
		my $contact = shift;

		if ($CT->{$contact}{TimeZone} ne 0) { printRow($head,"timezone","$CT->{$contact}{TimeZone} hour");}

	}
	#=====================================================

	sub printRowPager{
		my $head = shift;
		my $contact = shift;

		printRow($head,"pager",($CT->{$contact}{Pager} ne "") ? $CT->{$contact}{Pager} : "no number");

	}
	#=====================================================

	# test the dutytime on syntax
	# return true if OK 
	sub checkDutyTime {
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
}

sub deleteEvent {

	my $event_hash = $Q->{hash};

	if ( getbool($C->{db_events_sql}) ) {
		DBfunc::->delete(table=>'Events',index=>$event_hash);
	} else {
		# Load the event table
		my ($ET,$handle) = loadEventStateLock();
	
		delete $ET->{$event_hash} if exists $ET->{$event_hash};
	
		writeEventStateLock(table=>$ET,handle=>$handle);
	}
}
