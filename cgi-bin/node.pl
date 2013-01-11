#!/usr/bin/perl
#
## $Id: node.pl,v 8.5 2012/04/28 00:59:36 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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
use Sys;
use rrdfunc;
use Time::ParseDate;

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

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;
my $user;
my $privlevel;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new;  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

if ($Q->{act} eq 'network_graph_view') {		typeGraph();
} elsif ($Q->{act} eq 'network_export') {		typeExport();
} elsif ($Q->{act} eq 'network_stats') {		typeStats();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print start_html();
	print "Network: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf} <br>\n";
	print "Request not found\n";
	print end_html;
}

exit;

#============================================================

sub typeGraph {
	my %args = @_;

	my $node = $Q->{node};
	my $index = $Q->{intf};
	my $item = $Q->{item};
	my $group = $Q->{group};
	my $start = $Q->{start}; # seconds
	my $end = $Q->{end};
	my $p_start = $Q->{p_start}; # seconds
	my $p_end = $Q->{p_end};
	my $p_time = $Q->{p_time};
	my $date_start = $Q->{date_start}; # string
	my $date_end = $Q->{date_end};
	my $p_date_start = $Q->{p_date_start}; # seconds
	my $p_date_end = $Q->{p_date_end};
	my $graphx = $Q->{'graphimg.x'}; # points
	my $graphy = $Q->{'graphimg.y'};
	my $graphtype = $Q->{graphtype};

	my $length;

	my $NT = loadLocalNodeTable();
	my $GT = loadGroupTable();

	my $S = Sys::->new; # get system object
	$S->init(name=>$node); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my %graph_button_table = (
		# graphtype		==	display #
		'health' 		=> 'Health' ,
		'response' 		=> 'Response' ,
		'cpu' 			=> 'CPU' ,
		'ccpu' 			=> 'CPU' ,
		'acpu' 			=> 'CPU' ,
		'ip' 			=> 'IP' ,
		'traffic'		=> 'Traffic' ,
		'mem-proc'		=> 'Memory' ,
		'pic-conn'		=> 'Connections' ,
		'a3bandwidth'	=> 'Bandwidth' ,
		'a3traffic'		=> 'Traffic' ,
		'a3errors'		=> 'Errors'	);

	my $heading = $S->graphHeading(graphtype=>$graphtype,index=>$index,item=>$group);

	print header($headeropts);
	print start_html(
		-title => "Graph Drill In for $heading @ ".returnDateStamp,
		-meta => { 'CacheControl' => "no-cache",
			'Pragma' => "no-cache",
			'Expires' => -1 
			},
		-head=>[
			Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'<url_base>'}/images/nmis_favicon.png"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'<menu_url_base>'}/css/dash8.css"})
			]
		);

	# verify that user is authorized to view the node within the user's group list

	if ( $node ) {
		if ( ! $AU->InGroup($NT->{$node}{group}) ) {
			print "Not Authorized to view graphs on node '$node' in group $NT->{$node}{group}";
			return 0;
		}
	} elsif ( $group ) {
		if ( ! $AU->InGroup($group) ) {
			print "Not Authorized to view graphs on nodes in group $group";
			return 0;
		}
	}


	my $time = time();

	my $width = $C->{graph_width};
	my $height = $C->{graph_height};
	
	### 2012-02-06 keiths, handling default graph length
	# default is hours!
	my $graphlength = $C->{graph_amount};
	if ( $C->{graph_unit} eq "days" ) {
		$graphlength = $C->{graph_amount} * 24;
	}

	# convert start time/date field to seconds
	### 
	if ( $date_start eq "" ) {
		if ( $start eq "" ) { $start = $p_start = $time - ($graphlength*60*60); }
	} else {
		$start = parsedate($date_start);
	}

	# convert to seconds
	if ( $date_end eq "" ) {
		if ( $end eq "" ) { $end = $p_end = $time ; }
	} else {
		$end = parsedate($date_end);
	}

	$length = $end - $start;

	# width by default is 800, height is variable but always greater then 250
	#left
	if ( $graphx != 0 and $graphx < 150 ) {
		$end = $end - ($length/2);
		$start = $end - $length;
	}
	#right
	elsif ( $graphx != 0 and $graphx > $width + 94 - 150 ) {
		$end = $end + ($length/2);
		$start = $end - $length;
	}
	#zoom in
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy <= $height / 2 ) ) {
#		$start = $start + ($length/2);
		$end = $end - ($length/4);
		$length = $length/2;
		$start = $end - $length;
	}
	#zoom out
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy > $height / 2 ) ) {
#		$start = $start - ($length);
		$end = $end + ($length/2);
		$length = $length*2;
		$start = $end - $length;
	#
	} elsif ($p_time ne '' and $date_start eq $p_date_start and $date_end eq $p_date_end) {
		# pushed button, move with clock
		$end = $end + ($time - $p_time);
		$start = $end - $length;
	}

	# minimal length of 30 minutes
	if ( $start > ($time - (60*30)) ) {
		$start = $time - (60*30);
	}
	# minimal 30 min.
	if ($start > ($end - (60*30)) ) {
		$start = $end - (60*30);
	}

	# to integer
	$start = int($start);
	$end = int($end);

	$p_start = $start;
	$p_end = $end;

	$date_start = returnDateStamp($start);
	$date_end = returnDateStamp($end);

	#==== calculation done

	my $GTT = $S->loadGraphTypeTable(index=>$index);
	
	#print STDERR "DEBUG: ", %$GTT, "\n";

	my $itm;
	if ($Q->{graphtype} eq 'metrics') {
		$group = 'network' if $group eq "";
		$item = $group;
	} elsif ($Q->{graphtype} =~ /cbqos/) {
##		$item = 'class-default' if $item eq '';;
	} elsif ($GTT->{$graphtype} eq 'interface') {
		$item = '';
	}

	### 2012-04-12 keiths, fix for node list with unauthorised nodes.
	my @nodelist;
	for my $node ( sort keys %{$NT}) {
		my $auth = 1;
		if ($AU->Require) {
			my $lnode = lc($NT->{$node}{name});
			if ( $NT->{$node}{group} ne "" ) {
				if ( not $AU->InGroup($NT->{$node}{group}) ) { 
					$auth = 0; 
				}
			}
			else {
				logMsg("WARNING ($node) not able to find correct group. Name=$NT->{$node}{name}.") 
			}
		}
		if ($auth) {
			if ( $NT->{$node}{active} eq 'true' ) {
				push(@nodelist, $NT->{$node}{name});
			}
		}
	}

	print comment("typeGraph begin");

	print start_form( -method=>'get', -name=>"dograph", -action=>url(-absolute=>1));

	print start_table();

	#print Tr(th({class=>'title',colspan=>'1'},"<div>$heading<span class='right'>User: $user, Auth: Level$privlevel</span></div>"));
	print Tr(th({class=>'title',colspan=>'1'},"$heading"));
	print Tr(td({colspan=>'1'},
			table({class=>'table',width=>'100%'},
				Tr(
				# Start date field
				td({class=>'header',align=>'center',colspan=>'1'},"Start",
					textfield(-name=>"date_start",-override=>1,-value=>"$date_start",size=>'23')),
				# Node select menu
				td({class=>'header',align=>'center',colspan=>'1'},eval {
						return hidden(-name=>'node', -default=>$Q->{node},-override=>'1') 
							if $Q->{graphtype} eq 'metrics' or $Q->{graphtype}  eq 'nmis';
						return "Node ",popup_menu(-name=>'node', -override=>'1',
							-values=>[@nodelist],
							-default=>"$Q->{node}",
							-onChange=>'JavaScript:this.form.submit()');
					}),
				# Graphtype select menu
				td({class=>'header',align=>'center',colspan=>'1'},"Type ",
					popup_menu(-name=>'graphtype', -override=>'1',
						-values=>[sort keys %{$GTT}],
						-default=>"$Q->{graphtype}",
						-onChange=>'JavaScript:this.form.submit()')),
				# Submit button
				td({class=>'header',align=>'center',colspan=>'1'},
					submit(-name=>"dograph",-value=>"Submit"))),
				# next row
				Tr(
				# End date field
				td({class=>'header',align=>'center',colspan=>'1'},"End&nbsp;",
					textfield(-name=>"date_end",-override=>1,-value=>"$date_end",size=>'23')),
				# Group or Interface select menu
				td({class=>'header',align=>'center',colspan=>'1'}, eval {
						return hidden(-name=>'intf', -default=>$Q->{intf},-override=>'1') if $Q->{graphtype} eq 'nmis';
						if ( $Q->{graphtype} eq "metrics") {
							return 	"Group ",popup_menu(-name=>'group', -override=>'1',-size=>'1', 
										-values=>[grep $AU->InGroup($_), 'network',sort keys %{$GT}],
										-default=>"$group",
										-onChange=>'JavaScript:this.form.submit()'),
										hidden(-name=>'intf', -default=>$Q->{intf},-override=>'1');
						} elsif ($Q->{graphtype} eq "hrsmpcpu") {
							return 	"CPU ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{hrsmpcpu}}],
										-default=>"$index",
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($Q->{graphtype} =~ /service|service-cpumem/) {
							return 	"Service ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{service}}],
										-default=>"$index",
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($Q->{graphtype} eq "hrdisk") {
							return 	"Disk ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{hrdisk}}],
										-default=>"$index",
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($GTT->{$graphtype} eq "env_temp") {
							return 	"Sensor ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{env_temp}}],
										-default=>"$index",
										-labels=>{ map{($_ => $NI->{env_temp}{$_}{tempDescr})} sort keys %{$NI->{database}{env_temp}} },
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($GTT->{$graphtype} eq "akcp_temp") {
							return 	"Sensor ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{akcp_temp}}],
										-default=>"$index",
										-labels=>{ map{($_ => $NI->{akcp_temp}{$_}{hhmsSensorTempDescr})} sort keys %{$NI->{database}{akcp_temp}} },
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($GTT->{$graphtype} eq "akcp_hum") {
							return 	"Sensor ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{akcp_hum}}],
										-default=>"$index",
										-labels=>{ map{($_ => $NI->{akcp_hum}{$_}{hhmsSensorHumDescr})} sort keys %{$NI->{database}{akcp_hum}} },
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($GTT->{$graphtype} eq "cssgroup") {
							#2011-11-11 Integrating changes from Kai-Uwe Poenisch				
							return 	"Group ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{cssgroup}}],
										-default=>"$index",
										-labels=>{ map{($_ => $NI->{cssgroup}{$_}{CSSGroupDesc})} sort keys %{$NI->{database}{cssgroup}} },
										-onChange=>'JavaScript:this.form.submit()');
						} elsif ($GTT->{$graphtype} eq "csscontent") {
							#2011-11-11 Integrating changes from Kai-Uwe Poenisch				
							return 	"Sensor ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',sort keys %{$NI->{database}{csscontent}}],
										-default=>"$index",
										-labels=>{ map{($_ => $NI->{csscontent}{$_}{CSSContentDesc})} sort keys %{$NI->{database}{csscontent}} },
										-onChange=>'JavaScript:this.form.submit()');
						} else {
							return 	"Interface ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',
										-values=>['',grep $IF->{$_}{collect} eq 'true', sort { $IF->{$a}{ifDescr} cmp $IF->{$b}{ifDescr} } keys %{$IF}],
										-default=>"$index",
										-labels=>{ map{($_ => $IF->{$_}{ifDescr})} grep $IF->{$_}{collect} eq 'true',keys %{$IF} },
										-onChange=>'JavaScript:this.form.submit()');
						}
					}),
				# Fast select graphtype buttons
				td({class=>'header',align=>'center',colspan=>'2'}, div({class=>"header"}, eval {
						my @out;
						my $cg = "conf=$Q->{conf}&node=$node&group=$group&start=$start&end=$end&intf=$index&item=$Q->{item}";
						foreach my $gtp (keys %graph_button_table) {
							foreach my $gt (keys %{$GTT}) { 
								if ($gtp eq $gt) {
									push @out,a({class=>'button',href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=$gtp"},$graph_button_table{$gtp});
								}
							}
						}
						if (not($graphtype =~ /cbqos|calls/ and $Q->{item} eq '')) { 
							push @out,a({class=>'button',href=>url(-absolute=>1)."?$cg&act=network_export&graphtype=$Q->{graphtype}"},"Export");
							push @out,a({class=>'button',href=>url(-absolute=>1)."?$cg&act=network_stats&graphtype=$Q->{graphtype}"},"Stats");
						}
						push @out,a({class=>'button',href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=nmis"},"NMIS");
						return @out;
					})) ))));


	# interface info
	if ( $GTT->{$graphtype} =~ /interface|pkts|cbqos/i and $index ne "") {

		my $db;
		my $lastUpdate;
		if (($GTT->{$graphtype} =~ /cbqos/i and $item ne "") or $GTT->{$graphtype} =~ /interface|pkts/i ) {
			$db = $S->getDBName(graphtype=>$graphtype,index=>$index,item=>$item);
			$time = RRDs::last $db;
			$lastUpdate = returnDateStamp($time);
		}
		my $speed = &convertIfSpeed($IF->{$index}{ifSpeed});

		# info Type, Speed, Last Update, Description
		print Tr(td({colspan=>'1'},
			table({class=>'table',border=>'0',width=>'100%'},
				Tr(td({class=>'header',align=>'center',},'Type'),
					td({class=>'info Plain',},$IF->{$index}{ifType}),
					td({class=>'header',align=>'center',},'Speed'),
					td({class=>'info Plain'},$speed)),
				Tr(td({class=>'header',align=>'center',},'Last Updated'),
					td({class=>'info Plain'},$lastUpdate),
					td({class=>'header',align=>'center',},'Description'),
					td({class=>'info Plain'},$IF->{$index}{Description})) )));

	} elsif ( $GTT->{$graphtype} =~ /hrdisk/i and $index ne "") {
		print Tr(td({colspan=>'1'},
			table({class=>'table',border=>'0',width=>'100%'},
				Tr(td({class=>'header',align=>'center',},'Type'),
					td({class=>'info Plain'},$NI->{storage}{$index}{hrStorageType}),
					td({class=>'header',align=>'center',},'Description'),
					td({class=>'info Plain'},$NI->{storage}{$index}{hrStorageDescr})) )));
	}

	my @output;
	# check if database selectable with this info
	if ( ($S->getDBName(graphtype=>$graphtype,index=>$index,item=>$item,check=>'true')) or $Q->{graphtype} =~ /calls|cbqos/) {

		my %buttons;
		my $htitle;
		my $hvalue;
		my @buttons;
		my @intf;
	
		#Redundant Header!
		#push @output, Tr(td({class=>'header',align=>'center',colspan=>'1'},$heading));
	
		if ( $Q->{graphtype} =~ /cbqos/ ) {
			my ($CBQosNames,undef) = loadCBQoS(sys=>$S,graphtype=>$graphtype,index=>$index);
			$htitle = 'Policy name';
			$hvalue = $CBQosNames->[0];
			for my $i (1..$#$CBQosNames) {
				$buttons{$i}{name} = @$CBQosNames[$i];
				$buttons{$i}{intf} = $index;
				$buttons{$i}{item} = @$CBQosNames[$i];
			}
		}
	
		# display Call buttons if there is more then one call port for this node
		if ( $Q->{graphtype} eq "calls" and (scalar keys %{$NI->{database}{calls}}) > 1) {
			for my $i (keys %{$NI->{database}{calls}} ) {
				$buttons{$i}{name} = $IF->{$i}{ifDescr};
				$buttons{$i}{intf} = $i;
				$buttons{$i}{item} = '';
			}
		}



		if (%buttons) {
			my $cg = "conf=$Q->{conf}&act=network_graph_view&graphtype=$Q->{graphtype}&node=$Q->{node}&start=$start&end=$end";
			push @output, start_Tr;
			if ($htitle ne "") {
				push @output, td({class=>'header',colspan=>'1'},$htitle),td({class=>'info Plain',colspan=>'1'},$hvalue);
			}
			if (scalar keys %buttons < 6) {
				push @output, td({class=>'header',colspan=>'1'}, div( eval {
					my @out;
					foreach my $i (keys %buttons) {
						push @out, a({class=>'button',href=>url(-absolute=>1)."?$cg&intf=$buttons{$i}{intf}&item=$buttons{$i}{item}"},"$buttons{$i}{name}");
					}
					return @out;
				}));
			} else {
				push @output, td({class=>'header',colspan=>'1'},"Select ",
						popup_menu(-name=>'item', -override=>'1',
							-values=>['',map { $buttons{$_}{name} } keys %buttons],
							-default=>"$item",
							-onChange=>'JavaScript:this.form.submit()'));
			}
			push @output, end_Tr;
		}
	
		my $graphLink="$C->{'<cgi_url_base>'}/rrddraw.pl?conf=$Q->{conf}&amp;act=draw_graph_view".
				"&node=$node&group=$group&graphtype=$graphtype&start=$start&end=$end&width=$width&height=$height&intf=$index&item=$item";
	
		if ( $graphtype ne "service-cpumem" or $NI->{graphtype}{$index}{service} =~ /service-cpumem/ ) {
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},image_button(-name=>'graphimg',-src=>"$graphLink",-align=>'MIDDLE')));
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},"Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time"));
		} 
		else {
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},"Graph type not applicable for this data set."));
		}
	} else {
		push @output, Tr(td({colspan=>'4',align=>'center'},"waiting for selection or no data available"));
		push @output, hidden(-name=>'item', -default=>"$item",-override=>'1');
	}
	# push on page
	print Tr(td({colspan=>'1'},
			table({class=>'plain',width=>'100%'},@output)));


	print hidden(-name=>'conf', -default=>$Q->{conf},-override=>'1');
	print hidden(-name=>'p_date_start', -default=>"$date_start",-override=>'1');
	print hidden(-name=>'p_date_end', -default=>"$date_end",-override=>'1');
	print hidden(-name=>'p_start', -default=>"$p_start",-override=>'1');
	print hidden(-name=>'p_end', -default=>"$p_end",-override=>'1');
	print hidden(-name=>'p_time', -default=>"$time",-override=>'1');
	print hidden(-name=>'act', -default=>"network_graph_view",-override=>'1');
	print hidden(-name=>'obj', -default=>"graph",-override=>'1');
	print hidden(-name=>'func', -default=>"view",-override=>'1');

	print end_table, end_form, comment("typeGraph end"), end_html;
} # end typeGraph

sub typeExport {

	my $S = Sys::->new; # get system object
	$S->init(name=>$Q->{node}); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my $NT = loadLocalNodeTable();

	my $f = 1;
	my @line;
	my $row;
	my $content;

	my %interfaceTable;
	my $database;
	my $extName;

 	# verify access to this command/tool bar/button
	#
	if ( $AU->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $AU->CheckAccess("") or die "Attempted unauthorized access";
		if ( ! $AU->User ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	# verify that user is authorized to view the node within the user's group list
	#
	if ( $Q->{node} ) {
		if ( ! $AU->InGroup($NT->{$Q->{node}}{group}) ) {
			print "Not Authorized to export rrd data on node '$Q->{node}' in group '$NT->{$Q->{node}}{group}'.","grey";
			return 0;
		}
	} elsif ( $Q->{group} ) {
		if ( ! $AU->InGroup($Q->{group}) ) {
			print "Not Authorized to export rrd data on nodes in group '$Q->{group}'.","grey";
			return 0;
		}
	}

	my ($statval,$head) = getRRDasHash(sys=>$S,graphtype=>$Q->{graphtype},mode=>"AVERAGE",start=>$Q->{start},end=>$Q->{end},index=>$Q->{intf},item=>$Q->{item});
	my $filename = "$Q->{node}"."-"."$Q->{graphtype}";
	if ( $Q->{node} eq "" ) { $filename = "$Q->{group}-$Q->{graphtype}" }
	print "Content-type: text/plain;\n";
	print "Content-Disposition: attachment; filename=$filename.csv\n\n";

	foreach my $m (sort keys %{$statval}) {
		if ($f) {
			$f = 0;
			foreach my $h (@$head) {
				push(@line,$h);
				#print STDERR "@line\n";
			}
			#print STDERR "@line\n";
			$row = join("\t",@line);
			print "$row\n";
			@line = ();
		}
		$content = 0;
		foreach my $h (@$head) {
			if ( defined $statval->{$m}{$h}) {
				$content = 1;
			}
			push(@line,$statval->{$m}{$h});
		}
		if ( $content ) {
			$row = join("\t",@line);
			print "$row\n";
		}
		@line = ();
	}
}


sub typeStats {

	my $S = Sys::->new; # get system object
	$S->init(name=>$Q->{node}); # load node info and Model if name exists
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my $NT = loadLocalNodeTable();
	my $C = loadConfTable();

	print header($headeropts);

	print start_html(
		-title => "Statistics",
		-meta => { 'CacheControl' => "no-cache",
			'Pragma' => "no-cache",
			'Expires' => -1 
			},
		-head=>[
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'<menu_url_base>'}/css/dash8.css"})
			]
		);

	# verify access to this command/tool bar/button
	#
	if ( $AU->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $AU->CheckAccess( "") or die "Attempted unauthorized access";
		if ( ! $AU->User ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}


	# verify that user is authorized to view the node within the user's group list
	#
	if ( $Q->{node} ) {
		if ( ! $AU->InGroup($NT->{$Q->{node}}{group}) ) {
			print "Not Authorized to export rrd data on node $Q->{node} in group $NT->{$Q->{node}}{group}";
			return 0;
		}
	} elsif ( $Q->{group} ) {
		if ( ! $AU->InGroup($Q->{group}) ) {
			print "Not Authorized to export rrd data on nodes in group $Q->{group}";
			return 0;
		}
	}


	$Q->{intf} = $Q->{group} if $Q->{group} ne '';

	my $statval = getRRDStats(sys=>$S,graphtype=>$Q->{graphtype},mode=>"AVERAGE",start=>$Q->{start},end=>$Q->{end},index=>$Q->{intf},item=>$Q->{item});
	my $f = 1;
	my $starttime = returnDateStamp($Q->{start});
	my $endtime = returnDateStamp($Q->{end});

	print start_table;

	print Tr(td({class=>'header',colspan=>'10'},"NMIS RRD Graph Stats $NI->{system}{name} $IF->{$Q->{intf}}{ifDescr} $Q->{item} $starttime to $endtime"));

	foreach my $m (sort keys %{$statval}) {
		if ($f) {
			$f = 0;
			print Tr(td({class=>'header',align=>'center'},'metric'),
				eval { my $line;
					foreach my $s (sort keys %{$statval->{$m}}) {
						if ( $s ne "values" ) {
							$line .= td({class=>'header',align=>'center'},$s);
						}
					}
				return $line;
				}
			);
		}
		print Tr(td({class=>'info',align=>'right'},$m),
			eval { my $line;
				foreach my $s (sort keys %{$statval->{$m}}) {
					if ( $s ne "values" ) {
						$line .= td({class=>'info',align=>'right'},$statval->{$m}{$s});
					}
				}
				return $line;
			}
		);
	}

	print end_table,end_html;

}

###
### Load the CBQoS values in array
###
sub loadCBQoS {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $CB = $S->cbinfo;
	my $M = $S->mdl;
	my $node = $NI->{name};
	my $index = $args{index};
	my $graphtype = $args{graphtype};

	my $PMName;
	my @CMNames;
	my %CBQosValues;
	my @CBQosNames;

	# define line color of the graph
	my @colors = ("888888","00CC00","0000CC","CC00CC","FFCC00","00CCCC",
				"444444","440000","004400","000044","BBBB00","BB00BB","00BBBB",
				"888800","880088","008888","444400","440044","004444");

	my $direction = $graphtype eq "cbqos-in" ? "in" : "out" ;

	$PMName = $CB->{$index}{$direction}{PolicyMap}{Name};

	foreach my $k (keys %{$CB->{$index}{$direction}{ClassMap}}) {
		my $CMName = $CB->{$index}{$direction}{ClassMap}{$k}{Name};
		push @CMNames , $CMName if $CMName ne "";

		$CBQosValues{$index.$CMName}{'CfgType'} = $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Descr'};
		$CBQosValues{$index.$CMName}{'CfgRate'} = $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Value'};
	}

	# order the buttons of the classmap names for the Web page
	@CMNames = sort {uc($a) cmp uc($b)} @CMNames;

	my @qNames;
	my @confNames = split(',', $M->{node}{cbqos}{order_CM_buttons});
	foreach my $Name (@confNames) {
		for (my $i=0; $i<=$#CMNames; $i++) {
			if ($Name eq $CMNames[$i] ) {
				push @qNames, $CMNames[$i] ; # move entry
				splice (@CMNames,$i,1);
				last;
			}
		}
	}

	@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
	if ($#CBQosNames) { 
		# colors of the graph in the same order
		for my $i (1..$#CBQosNames) {
			if ($i < $#colors ) {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = $colors[$i-1];
			} else {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = "000000";
			}
		}
	}
	return \(@CBQosNames,%CBQosValues);
} # end loadCBQos

