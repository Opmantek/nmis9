#!/usr/bin/perl
#
## $Id: node.pl,v 8.5 2012/04/28 00:59:36 keiths Exp $
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
use List::Util;
use Compat::NMIS;
use NMISNG::Util;
use NMISNG::Sys;
use NMISNG::rrdfunc;
use Time::ParseDate;
use URI::Escape;

use Data::Dumper;
$Data::Dumper::Indent = 1;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

if (!($C = NMISNG::Util::loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };
NMISNG::rrdfunc::require_RRDs(config=>$C);

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use NMISNG::Auth;
my $user;
my $privlevel;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);  

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if Compat::NMIS::requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

if ($Q->{act} eq 'network_graph_view') {		typeGraph();
} elsif ($Q->{act} eq 'network_export') {		typeExport();
} elsif ($Q->{act} eq 'network_stats') {		typeStats();
} else { notfound(); }

sub notfound {
	my ($message) = @_;
	print header($headeropts);
	print start_html();
	print "Network: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf} <br>\n";
	print $message || "Request not found\n";
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

	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);

	my $length;

	my $NT = Compat::NMIS::loadLocalNodeTable();
	my $GT = Compat::NMIS::loadGroupTable();

	my $S = NMISNG::Sys->new;

	# load node info and Model iff name exists
	# otherwise, use dodgy non-node mode - fixme9 is that sufficient for minimal operation?
	my $loadok = $S->init(name => $node);
	if ($node && !$loadok)
	{
		return notfound("Node $node not found");
	}
	# fixme9: catchall_data is not even used?!?
	my $catchall_data = $node? $S->inventory( concept => 'catchall' )->data_live() : {};
			
	my $M = $S->mdl;
	my $V = $S->view;

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

	# graphtypes for custom service graphs are fixed and not found in the model system
	# note: format known here, in services.pl and poll
	my $heading;
	if ($graphtype =~ /^service-custom-([a-z0-9\.-])+-([a-z0-9\._-]+)$/)
	{
		$heading = $2;
	}
	else
	{
		$heading = $S->graphHeading(graphtype=>$graphtype, index=>$index, item=>$group);
	}

	print header($headeropts);
	my $opcharts_scripts = "";
	if( $C->{display_opcharts} ) {
		$opcharts_scripts = "<script src=\"$C->{'jquery'}\" type=\"text/javascript\"></script>".
			"<script src=\"$C->{'highstock'}\" type=\"text/javascript\"></script>".
			"<script src=\"$C->{'chart'}\" type=\"text/javascript\"></script>";
	}
	print start_html(
		-title => "Graph Drill In for $heading @ ".NMISNG::Util::returnDateStamp." - $C->{server_name}",
		-meta => { 'CacheControl' => "no-cache",
			'Pragma' => "no-cache",
			'Expires' => -1
			},
		-head=>[
			Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'<url_base>'}/images/nmis_favicon.png"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'<menu_url_base>'}/css/dash8.css"}),
			$opcharts_scripts
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

	$date_start = NMISNG::Util::returnDateStamp($start);
	$date_end = NMISNG::Util::returnDateStamp($end);


	my $GTT = $S->loadGraphTypeTable(index=>$index);
	my $section;
	if ($Q->{graphtype} eq 'metrics') {
		$group = 'network' if $group eq "";
		$item = $group;
	}
	elsif ($Q->{graphtype} =~ /cbqos/) 
	{
		$section = $Q->{graphtype};
	} 
	elsif ($GTT->{$graphtype} eq 'interface') {
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
				NMISNG::Util::logMsg("WARNING ($node) not able to find correct group. Name=$NT->{$node}{name}.")
			}
		}
		if ($auth) {
			if ( NMISNG::Util::getbool($NT->{$node}{active}) ) {
				push(@nodelist, $NT->{$node}{name});
			}
		}
	}
	print comment("typeGraph begin");

	# section needed to find cbqos instances
	my $modeldata = $S->getTypeInstances(section => $section, 
																			 graphtype => $graphtype, 
																			 want_modeldata => 1, 
																			 want_active => 1 );
	# fixme9: non-node mode means no graphttypetable means no menu and nothing works...
	$GTT->{$graphtype} = $graphtype if (!$node && !$modeldata->count && !keys %$GTT);
			
	my $data = $modeldata->data;
	# we can assume that the concept is the same in all entries
	my $concept = ($modeldata->count > 0) ? $data->[0]{concept} : undef;	
	my $subconcept = $GTT->{$graphtype};
	my %index_map = map { $_->{data}{index} => $_ } @$data;
	my $index_model = ($index) ? $index_map{$index} : {};

	# different graphs get their label/name from different places, this normalises
	# that and allows grabbing the data from the inventory model
	# do this by subconcept, concept is too broad, things like storage break it
	my %title_struct = (
		akcp_temp => { name => 'Sensor', label_key => 'hhmsSensorTempDescr' },
		akcp_hum => { name => 'Sensor', label_key => 'hhmsSensorHumDescr' },
		csscontent => { name => 'Sensor', label_key => 'CSSContentDesc' },		
		cssgroup => { name => 'Group', label_key => 'CSSGroupDesc' },
		env_temp => { name => 'Sensor', label_key => 'tempDescr' },
		hrsmpcpu => { name => 'CPU' },
		hrdisk => { name => 'Disk', label_key =>'hrStorageDescr' },
		interface => { name => 'Interface', label_key => 'ifDescr' },
		pkts => { name => 'Interface', label_key => 'ifDescr' },
		pkts_hc => { name => 'Interface', label_key => 'ifDescr' },
		'cbqos-in' => { name => 'Interface', label_key => 'ifDescr' },
		'cbqos-out' => { name => 'Interface', label_key => 'ifDescr' },
		calls => { name => 'Interface', label_key => 'ifDescr' },
	);

	$S->nmisng->log->debug("concept:$concept,subconcept:$subconcept,graphtype:$graphtype index:$index");
	# get the dropdown info for system health, we need to figure out which of the 
	# inventory data entries should be used for the label_key and name
	if( $concept && defined($M->{systemHealth}{sys}{$concept}) )
	{		
		my $sys = $M->{systemHealth}{sys}{$concept};		
		my $systemHealthLabel;
		my $systemHealthTitle = "";

		# all model entries will have the same inventory concept so just use the first one
		if( @$data > 0 )
		{
			my $model = $data->[0];
			$S->nmisng->log->debug("model, index: $model->{data}{index}");
			if ( $sys->{headers} !~ /,/ ) {
				$systemHealthLabel = $sys->{headers};
			}
			else {
				my @tmpHeaders = split(",",$sys->{headers});
				$systemHealthLabel = $tmpHeaders[0];
			}

			if ( exists $sys->{snmp}{$systemHealthLabel}{title} and $sys->{snmp}{$systemHealthLabel}{title} ne "" ) {
				$systemHealthTitle = $sys->{snmp}{$systemHealthLabel}{title};
			}
			else {
				$systemHealthTitle = $systemHealthLabel;
			}			
			# indexes are already where they should be
		}
		$title_struct{$subconcept} = { name => $systemHealthTitle, label_key => $systemHealthLabel };
	}

	print start_form( -method=>'get', -name=>"dograph", -action=>url(-absolute=>1));

	print start_table();

	#print Tr(th({class=>'title',colspan=>'1'},"<div>$heading<span class='right'>User: $user, Auth: Level$privlevel</span></div>"));
	print Tr(th({class=>'title',colspan=>'1'},"$heading"));
	print Tr(td({colspan=>'1'},
			table({class=>'table',width=>'100%'},
				Tr(
				# Start date field
				td({class=>'header',align=>'center',colspan=>'1'},"Start",
					textfield(-name=>"date_start",-override=>1,-value=>"$date_start",size=>'23',tabindex=>"1")),
				# Node select menu
				td({class=>'header',align=>'center',colspan=>'1'},eval {
						return hidden(-name=>'node', -default=>$Q->{node},-override=>'1')
							if $graphtype eq 'metrics' or $graphtype  eq 'nmis';
						return "Node ",popup_menu(-name=>'node', -override=>'1', 
																			tabindex=>"3",
																			-values=>[@nodelist],
																			-default=>"$Q->{node}",
																			-onChange=>'JavaScript:this.form.submit()');
					}),
				# Graphtype select menu
				# NOTE: this list needs to be adjusted to only show things are actually collect/storing
				#   cbqos-in/out is one example that isn't working
				td({class=>'header',align=>'center',colspan=>'1'},"Type ",
					popup_menu(-name=>'graphtype', -override=>'1', tabindex=>"4",
						-values=>[sort keys %{$GTT}],
						-default=>"$graphtype",
						-onChange=>'JavaScript:this.form.submit()')),
				# Submit button
				td({class=>'header',align=>'center',colspan=>'1'},
					submit(-name=>"dograph",-value=>"Submit"))),
				# next row
				Tr(
				# End date field
				td({class=>'header',align=>'center',colspan=>'1'},"End&nbsp;",
					textfield(-name=>"date_end",-override=>1,-value=>"$date_end",size=>'23',tabindex=>"2")),

				# Group or Interface select menu
				td({class=>'header',align=>'center',colspan=>'1'}, eval {
						return hidden(-name=>'intf', -default=>$Q->{intf},-override=>'1') if $graphtype eq 'nmis';
						if( defined( $title_struct{ $subconcept } ) )
						{							
							my $def = $title_struct{ $subconcept };							
							my @sorted = sort { $a->{data}{index} <=> $b->{data}{index} } @$data;
							my @values = map { $_->{data}{index} } @sorted;
							my %labels = ( defined($def->{label_key}) ) ? map { $_->{data}{index} => $_->{data}{ $def->{label_key} } } @sorted : undef;
							unshift @sorted, '';
							return "$def->{name} ",popup_menu(-name=>'intf', -override=>'1',-size=>'1', tabindex=>"5",
										-values=>['', @values],
										-default=>"$index",
										-labels=> \%labels,
										-onChange=>'JavaScript:this.form.submit()');
						}
						elsif ( $graphtype eq "metrics") {
							return 	"Group ",popup_menu(-name=>'group', -override=>'1',-size=>'1', tabindex=>"5",
										-values=>[grep $AU->InGroup($_), 'network',sort keys %{$GT}],
										-default=>"$group",
										-onChange=>'JavaScript:this.form.submit()'),
										hidden(-name=>'intf', -default=>$Q->{intf},-override=>'1');
						}
					 	elsif ($graphtype =~ /service|service-cpumem|service-response/) {
							return 	"Service ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',tabindex=>"5",
										-values=>['',sort $S->getTypeInstances(section => "service")],
										-default=>"$index",
										-onChange=>'JavaScript:this.form.submit()');
						}
					}),
				# Fast select graphtype buttons
				td({class=>'header',align=>'center',colspan=>'2'}, div({class=>"header"}, eval {
						my @out;
						my $cg = "conf=$Q->{conf}&group=$urlsafegroup&start=$start&end=$end&intf=$index&item=$Q->{item}&node=$urlsafenode";
						foreach my $gtp (keys %graph_button_table) {
							foreach my $gt (keys %{$GTT}) {
								if ($gtp eq $gt) {
									push @out,a({class=>'button', tabindex=>"-1", 
															 href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=$gtp"},
															$graph_button_table{$gtp});
								}
							}
						}
						if (not($graphtype =~ /cbqos|calls/ and $Q->{item} eq '')) {
							push @out,a({class=>'button', tabindex=>"-1", href=>url(-absolute=>1)."?$cg&act=network_export&graphtype=$graphtype"},"Export");
							push @out,a({class=>'button', tabindex=>"-1", href=>url(-absolute=>1)."?$cg&act=network_stats&graphtype=$graphtype"},"Stats");
						}
						push @out,a({class=>'button', tabindex=>"-1", href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=nmis"},"NMIS");
						return @out;
					})) ))));


	# interface info
	if ( $subconcept =~ /interface|pkts|cbqos/i and $index ne "") {

		my $db;
		my $lastUpdate;
		my $intf_data = $index_model->{data};
		# cbqos shows interface data so load if if we are doing cbqos
		if( $subconcept =~ /cbqos/ && $index != '')
		{
			$intf_data = $S->inventory( concept => 'interface', index => $index, partial => 1 )->data();
		}
		# NOTE: this could use the inventory last update time
		if (($subconcept =~ /cbqos/i and $item ne "") or $subconcept =~ /interface|pkts/i ) 
		{
			$db = $S->makeRRDname(graphtype=>$graphtype,index=>$index,item=>$item);
			$time = RRDs::last($db);
			$lastUpdate = NMISNG::Util::returnDateStamp($time);
		}

		$S->readNodeView;
		my $V = $S->view;
		# instead of loading a new inventory object re-use the model loaded above
		my $speed = &NMISNG::Util::convertIfSpeed($intf_data->{ifSpeed});
		if ( $V->{interface}{"${index}_ifSpeedIn_value"} ne "" and $V->{interface}{"${index}_ifSpeedOut_value"} ne "" ) {
				$speed = qq|IN: $V->{interface}{"${index}_ifSpeedIn_value"} OUT: $V->{interface}{"${index}_ifSpeedOut_value"}|;
		}

		# info Type, Speed, Last Update, Description
		print Tr(td({colspan=>'1'},
			table({class=>'table',border=>'0',width=>'100%'},
				Tr(td({class=>'header',align=>'center',},'Type'),
					td({class=>'info Plain',},$intf_data->{ifType}),
					td({class=>'header',align=>'center',},'Speed'),
					td({class=>'info Plain'},$speed)),
				Tr(td({class=>'header',align=>'center',},'Last Updated'),
					td({class=>'info Plain'},$lastUpdate),
					td({class=>'header',align=>'center',},'Description'),
					td({class=>'info Plain'},$intf_data->{Description})) )));

	} elsif ( $subconcept =~ /hrdisk/i and $index ne "") {
		print Tr(td({colspan=>'1'},
			table({class=>'table',border=>'0',width=>'100%'},
				Tr(td({class=>'header',align=>'center',},'Type'),
					td({class=>'info Plain'},$index_model->{data}{hrStorageType}),
					td({class=>'header',align=>'center',},'Description'),
					td({class=>'info Plain'},$index_model->{data}{hrStorageDescr})) )));
	}

	my @output;
	# check if database selectable with this info
	if ( ($S->makeRRDname(graphtype=>$graphtype,index=>$index,item=>$item,
											suppress_errors=>'true'))
			 or $graphtype =~ /calls|cbqos/) {

		my %buttons;
		my $htitle;
		my $hvalue;
		my @buttons;
		my @intf;

		# figure out the available policy or classifier names and other cbqos details
		if ( $graphtype =~ /cbqos/ )
		{
			my ($CBQosNames,undef) = Compat::NMIS::loadCBQoS(sys=>$S,graphtype=>$graphtype,index=>$index);
			$htitle = 'Policy name';
			$hvalue = $CBQosNames->[0] || "N/A";

			for my $i (1..$#$CBQosNames) {
				$buttons{$i}{name} = $CBQosNames->[$i];
				$buttons{$i}{intf} = $index;
				$buttons{$i}{item} = $CBQosNames->[$i];
			}
		}

		# display Call buttons if there is more then one call port for this node
		if ( $graphtype eq "calls" ) {
			for my $i ($S->getTypeInstances(section => "calls")) {				
				$buttons{$i}{name} = $index_model->{data}{ifDescr};
				$buttons{$i}{intf} = $i;
				$buttons{$i}{item} = '';
			}
		}

		if (%buttons) {
			my $cg = "conf=$Q->{conf}&act=network_graph_view&graphtype=$graphtype&start=$start&end=$end&node=".uri_escape($Q->{node});
			push @output, start_Tr;
			if ($htitle ne "") {
				push @output, td({class=>'header',colspan=>'1'},$htitle),td({class=>'info Plain',colspan=>'1'},$hvalue);
			}
			push @output, td({class=>'header',colspan=>'1'},"Select ",
											 popup_menu(-name=>'item', -override=>'1',
																	-values=>['',map { $buttons{$_}{name} } keys %buttons],
																	-default=>"$item",
																	-onChange=>'JavaScript:this.form.submit()'));
			push @output, end_Tr;
		}

		my $graphLink="$C->{'rrddraw'}?conf=$Q->{conf}&amp;act=draw_graph_view".
				"&node=$urlsafenode&group=$urlsafegroup&graphtype=$graphtype&start=$start&end=$end&width=$width&height=$height&intf=$index&item=$item";
		my $chartDiv = "";
		
		if ( $graphtype ne "service-cpumem" or $index_model->{data}{service} =~ /service-cpumem/ ) {
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'}, image_button(-name=>'graphimg',-src=>"$graphLink",-align=>'MIDDLE',-tabindex=>"-1")));
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

	print "</table>";
	print hidden(-name=>'conf', -default=>$Q->{conf},-override=>'1');
	print hidden(-name=>'p_date_start', -default=>"$date_start",-override=>'1');
	print hidden(-name=>'p_date_end', -default=>"$date_end",-override=>'1');
	print hidden(-name=>'p_start', -default=>"$p_start",-override=>'1');
	print hidden(-name=>'p_end', -default=>"$p_end",-override=>'1');
	print hidden(-name=>'p_time', -default=>"$time",-override=>'1');
	print hidden(-name=>'act', -default=>"network_graph_view",-override=>'1');
	print hidden(-name=>'obj', -default=>"graph",-override=>'1');
	print hidden(-name=>'func', -default=>"view",-override=>'1');

	print "</form>", comment("typeGraph end");
	print end_html;

} # end typeGraph

# unreachable dead code as of 2016-08
sub typeExport {

	my $S = NMISNG::Sys->new; # get system object
	notfound("Node not found") && return if( !$S->init(name=>$Q->{node}) );
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $graphtype = $Q->{graphtype};

	my $NT = Compat::NMIS::loadLocalNodeTable();

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

	my $db = $S->makeRRDname(graphtype => $graphtype, index=>$Q->{intf},item=>$Q->{item});
	my ($statval,$head) = NMISNG::rrdfunc::getRRDasHash(database=>$db, sys=>$S,
																											graphtype=>$graphtype,mode=>"AVERAGE",
																											start=>$Q->{start},end=>$Q->{end},index=>$Q->{intf},item=>$Q->{item});
	my $filename = "$Q->{node}"."-"."$graphtype";
	if ( $Q->{node} eq "" ) { $filename = "$Q->{group}-$graphtype" }
	print "Content-type: text/csv;\n";
	print "Content-Disposition: attachment; filename=$filename.csv\n\n";

	# print header line first - expectation is that w/o ds list/header there's also no data.
	if (ref($head) eq "ARRAY" && @$head)
	{
		print join("\t", @$head)."\n";

		# print any row that has at least one reading with known ds/header name
		foreach my $rtime (sort keys %{$statval})
		{
			if ( List::Util::any { defined $statval->{$rtime}->{$_} } (@$head) )
			{
				print join("\t", map { $statval->{$rtime}->{$_} } (@$head))."\n";
			}
		}
	}
}

# unreachable dead code as of 2016-08
sub typeStats {

	my $S = NMISNG::Sys->new; # get system object
	notfound("Node not found") && return if( !$S->init(name=>$Q->{node}) );
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my $NT = Compat::NMIS::loadLocalNodeTable();
	my $C = NMISNG::Util::loadConfTable();

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

	my $db = $S->makeRRDname(graphtype => $Q->{graphtype}, index=>$Q->{intf},item=>$Q->{item});
	my $statval = (-f $db? NMISNG::rrdfunc::getRRDStats(sys=>$S,
																											database => $db, 
																											graphtype=>$Q->{graphtype},
																											mode=>"AVERAGE",
																											start=>$Q->{start},
																											end=>$Q->{end},
																											index=>$Q->{intf},item=>$Q->{item}) : {});
	my $f = 1;
	my $starttime = NMISNG::Util::returnDateStamp($Q->{start});
	my $endtime = NMISNG::Util::returnDateStamp($Q->{end});

	print start_table;

	print Tr(td({class=>'header',colspan=>'11'},"NMIS RRD Graph Stats $NI->{system}{name} $IF->{$Q->{intf}}{ifDescr} $Q->{item} $starttime to $endtime"));

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
