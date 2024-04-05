#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ( NMIS ).
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
use List::Util 1.33;						# older versions don't have a usable any()
use Time::ParseDate;
use URI::Escape;
use Data::Dumper;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use Text::CSV;

use Compat::NMIS;
use NMISNG::Util;
use NMISNG::Sys;
use NMISNG::rrdfunc;
use NMISNG::Auth;

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash

$Q = NMISNG::Util::filter_params($Q);
my $nmisng = Compat::NMIS::new_nmisng;
my $C = $nmisng->config;
&NMISNG::rrdfunc::require_RRDs;

# Before going any further, check to see if we must handle
# an authentication login or logout request

# if arguments present, then called from command line, no auth.
if ( @ARGV ) { $C->{auth_require} = 0; }

my $user;
my $privlevel;

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request - fixme9: not supported at this time
exit 1 if (defined($Q->{cluster_id}) && $Q->{cluster_id} ne $C->{cluster_id});

my $NT = Compat::NMIS::loadLocalNodeTable();
my @groups   = grep { $AU->InGroup($_) } sort $nmisng->get_group_names;
my $GT = { map { $_ => $_ } (@groups) }; # backwards compat; hash assumption sprinkled everywhere

# When called from the Node and changed to an interface type within the dialog, the action is lost.
if ($Q->{forceAct}) {
	$Q->{act} = $Q->{forceAct};
}

# cancel? go to graph view
if ($Q->{cancel} || $Q->{act} eq 'network_graph_view')
{
	typeGraph();
}
elsif ($Q->{act} eq 'network_export')
{
	typeExport();
}
elsif ($Q->{act} eq 'network_export_options')
{
	show_export_options();
}
elsif ($Q->{act} eq 'network_stats')
{
	typeStats();
}
else { bailout(message => "Unrecognised arguments! act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}<br>")};

exit 0;

# print minimal header, complaint message and exits
# args: code (optional, default: 400), message (required)
sub bailout
{
	my (%args) = @_;

	my $code = $args{code} // 400;
	my $message = $args{message} // "Failure";
	print header(-status => $code), start_html, $message, end_html;
	exit 0;
}

sub typeGraph
{
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
	my $urlsafeindex= uri_escape($index);
	my $urlsafeitem = uri_escape($item);

	my $length;

	my $S = NMISNG::Sys->new;

	# load node info and Model iff name exists
	# otherwise, use dodgy non-node mode - fixme9 is that sufficient for minimal operation?
	my $loadok = $S->init(name => $node, snmp => 'false');
	if ($node && !$loadok)
	{
		bailout(message => "Node $node not found");
	}

	# Special handleling for serviceonly nodes
	if ($graphtype =~ /service/) {
		$S->{mdl}{system}{nodeModel} = "Model-ServiceOnly";
		$S->loadModel( model => $S->{mdl}{system}{nodeModel} );
	}	
	
	my $M = $S->mdl;

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
	# note: format known here, in services.pl and NMISNG::Node
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
	print start_html(
		-title => "Graph Drill In for $heading @ ".NMISNG::Util::returnDateStamp." - $C->{server_name}",
		-meta => { 'CacheControl' => "no-cache",
			'Pragma' => "no-cache",
			'Expires' => -1
			},
		-head=>[
			 Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'<url_base>'}/images/nmis_favicon.png"}),
			 Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"}),
		],
		-script => {-src => $C->{'jquery'}, -type=>"text/javascript"},
		);

	# verify that user is authorized to view the node within the user's group list
	if ( $node )
	{
		if ( !$AU->InGroup($NT->{$node}{group}) or !exists $GT->{$NT->{$node}{group}} )
		{
			print "Not Authorized to view graphs on node '$node' in group $NT->{$node}{group}";
			return 0;
		}
	}
	elsif ( $group )
	{
		# group 'network' is used for metrics graphs and is special:
		# it exists automatically no matter what the group_list configuration or group table says.
		if ( ! $AU->InGroup($group) or (!exists $GT->{$group} and $group ne "network" ))
		{
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
	if ( $date_start eq "" )
	{
		if ( $start eq "" )
		{
			$start = $p_start = $time - ($graphlength*60*60);
		}
	}
	else
	{
		$start = parsedate($date_start);
	}

	# convert to seconds
	if ( $date_end eq "" )
	{
		if ( $end eq "" )
		{ $end = $p_end = $time ;
		}
	}
	else
	{
		$end = parsedate($date_end);
	}

	$length = $end - $start;

	# width by default is 800, height is variable but always greater then 250
	#left
	if ( $graphx != 0 and $graphx < 150 )
	{
		$end = $end - ($length/2);
		$start = $end - $length;
	}
	#right
	elsif ( $graphx != 0 and $graphx > $width + 94 - 150 )
	{
		$end = $end + ($length/2);
		$start = $end - $length;
	}
	#zoom in
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy <= $height / 2 ) )
	{
#		$start = $start + ($length/2);
		$end = $end - ($length/4);
		$length = $length/2;
		$start = $end - $length;
	}
	#zoom out
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy > $height / 2 ) )
	{
#		$start = $start - ($length);
		$end = $end + ($length/2);
		$length = $length*2;
		$start = $end - $length;
	#
	}
	elsif ($p_time ne ''
				 and $date_start eq $p_date_start
				 and $date_end eq $p_date_end)
	{
		# pushed button, move with clock
		$end = $end + ($time - $p_time);
		$start = $end - $length;
	}

	# minimal length of 10 minutes
	if ( $start > ($time - (60*10)) ) {
		$start = $time - (60*10);
	}
	# minimal 10 min.
	if ($start > ($end - (60*10)) ) {
		$start = $end - (60*10);
	}

	# to integer
	$start = int($start);
	$end = int($end);

	$p_start = $start;
	$p_end = $end;

	$date_start = NMISNG::Util::returnDateStamp($start);
	$date_end = NMISNG::Util::returnDateStamp($end);

	my @nodelist;
	for my $node ( sort keys %{$NT})
	{
		my $auth = 1;

		if ($AU->Require)
		{
			if ( $NT->{$node}{group} ne "" ) {
				if ( not $AU->InGroup($NT->{$node}{group}) ) {
					$auth = 0;
				}
			}
		}

		# to be included node must be ok to see, active and belonging to a configured group
		push @nodelist, $NT->{$node}{name} if ($auth
																					 && NMISNG::Util::getbool($NT->{$node}->{active})
																					 && $GT->{$NT->{$node}->{group}});
	}

	my $GTT = $S->loadGraphTypeTable(index=>$index);
	my $section;

	if ($Q->{graphtype} eq 'metrics')
	{
		$group = 'network' if $group eq "";
		$item = $group;
	}
	elsif ($Q->{graphtype} =~ /cbqos/)
	{
		$section = $Q->{graphtype};
	}
	elsif ($GTT->{$graphtype} eq 'interface')
	{
		$item = '';
	}

	my ($title_struct, $concept, $subconcept, $index_model, $data)
			= get_graphtype_titles(sys => $S, graphtype => $graphtype,
														 graphtypetable => $GTT,
														 section => $section,
														 index => $index);

	$S->nmisng->log->debug("concept:$concept,subconcept:$subconcept,graphtype:$graphtype index:$index section:$section");

	# primary form part - if we want the url to have the params then we need to use GET
	# and tell cgi explicitely to use the appropriate encoding type...

	print start_form(-method => 'GET', -enctype => "application/x-www-form-urlencoded",
									 -name=>"dograph", -action=>url(-absolute=>1)),
	start_table();

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
																									-onChange=>'this.form.submit()');
												 }),
											# Graphtype select menu
											# fixme9: this list needs to be adjusted to only show things are actually collect/storing
											#   cbqos-in/out is one example that isn't working
											td({class=>'header',align=>'center',colspan=>'1'},"Type ",
												 popup_menu(-name=>'graphtype', -override=>'1', tabindex=>"4",
																		-values=>[sort keys %{$GTT}],
																		-default=>"$graphtype",
																		-onChange=>'this.form.submit()')),
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
												if( defined( $title_struct->{ $subconcept } ) )
												{
													my $def = $title_struct->{ $subconcept };

													my @sorted = sort { $a->{data}{index} <=> $b->{data}{index} } @$data;
													my @values = map { $_->{data}{index} } @sorted;
													my %labels = ( defined($def->{label_key}) ) ? map { $_->{data}{index} => $_->{data}{ $def->{label_key} } } @sorted : undef;
													unshift @sorted, '';
													return "$def->{name} ",popup_menu(-name=>'intf', -override=>'1',-size=>'1', tabindex=>"5",
																														-values=>['', @values],
																														-default=>"$index",
																														-labels=> \%labels,
																														-onChange=>'this.form.submit()'),
																									hidden(-name=>'forceAct', -value=>'network_graph_view', -override=>1);
												}
												elsif ( $graphtype eq "metrics") {
													return 	"Group ",popup_menu(-name=>'group', -override=>'1',-size=>'1', tabindex=>"5",
																											-values=>[grep $AU->InGroup($_), 'network',sort keys %{$GT}],
																											-default=>"$group",
																											-onChange=>'this.form.submit()'),
													hidden(-name=>'intf', -default=>$Q->{intf},-override=>'1');
												}
												elsif ($graphtype =~ /service|service-cpumem|service-response/) {
													return 	"Service ",popup_menu(-name=>'intf', -override=>'1',-size=>'1',tabindex=>"5",
																												-values=>['',sort $S->getTypeInstances(section => "service")],
																												-default=>"$index",
																												-onChange=>'this.form.submit()');
												}
												 }),
											# Fast select graphtype buttons

											td({class=>'header',align=>'center',colspan=>'2'},
												 div({class=>"header"},
														 eval {
															 my @out;
															 my $cg = "group=$urlsafegroup&start=$start&end=$end&intf=$index&item=$Q->{item}&node=$urlsafenode";

															 push @out, a({class=>'button', tabindex=>"-1",
																						 href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=nmis"},
																						"NMIS");

															 foreach my $gtp (keys %graph_button_table) {
																 foreach my $gt (keys %{$GTT}) {
																	 if ($gtp eq $gt) {
																		 push @out,a({class=>'button', tabindex=>"-1", href=>url(-absolute=>1)."?$cg&act=network_graph_view&graphtype=$gtp"},$graph_button_table{$gtp});
																	 }
																 }
															 }

															 if (not($graphtype =~ /cbqos|calls/ and $Q->{item} eq ''))
															 {
																 push @out,a({class=>'button', tabindex=>"-1",
																							href=>url(-absolute=>1)."?$cg&act=network_stats&graphtype=$Q->{graphtype}"},
																						 "Stats");

																 # export: one link, direct export with default resolution,
																 # one link to a separate page with option form
																 push @out, (
																	 a({class=>'button', tabindex=>"-1",
																			href=>url(-absolute=>1)."?$cg&act=network_export&graphtype=$Q->{graphtype}"},
																		 "Export"),
																	 a({class=>"button", tabindex => -1,
																			href => url(-absolute=>1)."?$cg&act=network_export_options&graphtype=$Q->{graphtype}"},
																		 "Adv. Export"), );
															 }


															 return @out;
														 }))
										))));


	# interface info
	if ( $subconcept =~ /interface|pkts|cbqos/i and $index ne "")
	{
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
			$db = $S->makeRRDname(graphtype=>$graphtype,index=>$index,item=>$item,type=>$concept);
			$time = RRDs::last($db);
			$lastUpdate = NMISNG::Util::returnDateStamp($time);
		}

		# instead of loading a new inventory object re-use the model loaded above
		my $speed = &NMISNG::Util::convertIfSpeed($intf_data->{ifSpeed});
		if ($intf_data->{ifSpeedIn} and $intf_data->{ifSpeedOut})
		{
			$speed = "IN: ".&NMISNG::Util::convertIfSpeed($intf_data->{ifSpeedIn})
					." OUT: ".&NMISNG::Util::convertIfSpeed($intf_data->{ifSpeedOut});
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

	}
	elsif ( $subconcept =~ /hrdisk/i and $index ne "")
	{
		print Tr(td({colspan=>'1'},
								table({class=>'table',border=>'0',width=>'100%'},
											Tr(td({class=>'header',align=>'center',},'Type'),
												 td({class=>'info Plain'},$index_model->{data}{hrStorageType}),
												 td({class=>'header',align=>'center',},'Description'),
												 td({class=>'info Plain'},$index_model->{data}{hrStorageDescr})) )));
	}

	my @output;
	my $inventory = $S->inventory( concept => $concept, index => $index );
	# check if database selectable with this info
	if ( ($S->makeRRDname(graphtype=>$graphtype,index=>$index,item=>$item,
												suppress_errors=>'true', inventory=>$inventory))
			 or $graphtype =~ /cbqos/) {

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

		if (%buttons) {
			my $cg = "act=network_graph_view&graphtype=$graphtype&start=$start&end=$end&node=".uri_escape($Q->{node});
			push @output, start_Tr;
			if ($htitle ne "") {
				push @output, td({class=>'header',colspan=>'1'},$htitle),td({class=>'info Plain',colspan=>'1'},$hvalue);
			}
			push @output, td({class=>'header',colspan=>'1'},"Select ",
											 popup_menu(-name=>'item', -override=>'1',
																	-values=>['',map { $buttons{$_}{name} } keys %buttons],
																	-default=>"$item",
																	-onChange=>'this.form.submit()'));
			push @output, end_Tr;
		}

		my $graphLink = Compat::NMIS::htmlGraph(only_link => 1, # we need the unwrapped link!
																						sys => $S,
																						node => $node,
																						group => $group,
																						graphtype => $graphtype,
																						intf => $index,
																						item => $item,
																						start => $start,
																						end => $end,
																						width => $width,
																						height => $height,
																						inventory=>$inventory );

		if ( $graphtype ne "service-cpumem" or $index_model->{data}{service} =~ /service-cpumem/ )
		{
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},
													image_button(-name=>'graphimg',-src=>"$graphLink",-align=>'MIDDLE',-tabindex=>"-1")));
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},
													"Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time"));
		}
		else
		{
			push @output, Tr(td({class=>'info Plain',align=>'center',colspan=>'4'},
													"Graph type not applicable for this data set."));
		}
	}
	else
	{
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
	print hidden(-name=>'act', -default=>"network_graph_view", -override=>'1');

	print "</form>", comment("typeGraph end");
	print end_html;

} # end typeGraph

# shows a form with options for exporting, submission target is typeExport()
sub show_export_options
{
	my ($node,$item,$intf,$group,$graphtype) = @{$Q}{qw(node item intf group graphtype)};

	bailout(message => "Invalid arguments, missing node!") if (!$node);

	my $S = NMISNG::Sys->new;
	my $isok = $S->init(name => $node, snmp => 'false');
	bailout(message => "Invalid arguments, could not load data for nonexistent node!") if (!$isok);

	# verify that user is authorized to view the node within the user's group list
	my $nodegroup = $S->nmisng_node->configuration->{group} if ($S->nmisng_node);
	if ($node && (!$AU->InGroup($nodegroup || !exists $GT->{$nodegroup})))
	{
		bailout(code => 403,
						message => escapeHTML("Not Authorized to export rrd data for node '$node' in group '$nodegroup'."));
	}
	elsif ($group && (!$AU->InGroup($group) || !exists $GT->{$group}))
	{
		bailout(code => 403,
						message => escapeHTML("Not Authorized to export rrd data for nodes in group '$group'."));
	}

	# graphtypes for custom service graphs are fixed and not found in the model system
	# note: format known here, in services.pl and nmis.pl
	my $heading;
	if ($graphtype =~ /^service-custom-([a-z0-9\.-])+-([a-z0-9\._-]+)$/)
	{
		$heading = $2;
	}
	else
	{
		# fixme: really group in item???
		$heading = $S->graphHeading(graphtype=>$graphtype, index=>$intf, item=>$group);
	}
	$heading = escapeHTML($heading);

	# headers, html setup, form
	print header($headeropts),
	start_html(-title => "Export Options for Graph $heading - $C->{server_name}",
						 -head => [
								Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
								Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"}),
						 ],
						 -script => {-src => $C->{'jquery'}, -type=>"text/javascript"},),

								 # this form should post. we don't want anything in the url.
								start_form( -name => 'exportopts',
														-action => url(-absolute => 1)),
								 hidden(-name => 'act', -default => 'network_export', -override => 1),
								 # not selectable: node/group, graphtype, item/intf
								 hidden(-name => "node", -default => $node, -override => 1),
								 hidden(-name => "group", -default => $group, -override => 1),
								 hidden(-name => "graphtype", -default => $graphtype, -override => 1),
								 hidden(-name => "item", -default => $item, -override => 1),
								 hidden(-name => "intf", -default => $intf, -override => 1);


	# figure out how to label the selector/index/intf properties
	my $GTT = $S->loadGraphTypeTable(index=>$intf);
	my ($title_struct, $concept, $subconcept, $index_model, $data) = get_graphtype_titles(sys => $S, graphtype => $graphtype,
																																												graphtypetable => $GTT,
																																												section => ($graphtype =~ /cbqos/? $graphtype: undef),
																																												index => $intf);
	my %graphtype2itemname = ( metrics => 'Group',
														 hrsmpcpu => 'Cpu',
														 ( map { ($_ => "Service") } (qw(service service-cpumem service-response))),
														 hrdisk => 'Disk',
														 ( map { ($_ => 'Sensor') } (qw(env_temp akcp_temp akcp_hum csscontent))),
														 cssgroup => 'Group',
														 nmis => undef); # no item label is shown

	#/
	print qq|<table><tr><th class='title' colspan='2'>Export Options for Graph "$heading"</th></tr>|;

	my $label = $graphtype2itemname{$graphtype};
	$label //= $title_struct->{$subconcept}->{name} if ($title_struct->{$subconcept});

	my $property = ( $graphtype eq "nmis"? undef
									 : $graphtype eq "metrics"? $group : $intf );

	print qq|<tr><td class="header">Node</td><td>|.escapeHTML($node).qq|</td></tr>|
			if ($graphtype ne "nmis" && $graphtype ne "metrics");
	if (defined $label && defined $property)
	{
		print qq|<tr><td class="header">$label</td><td>|.escapeHTML($property).qq|</td></tr>|;
	}

	my $graphhours =$C->{graph_amount};
	$graphhours *= 24 if ($C->{graph_unit} eq "days");

	my $date_start = NMISNG::Util::returnDateStamp( time - $graphhours*3600);
	my $date_end = NMISNG::Util::returnDateStamp(time);

	print qq|<tr><td class='header'>Start</td><td>|
			. textfield(-name=>"date_start", -override=>1, -value=> $date_start, size=>'23', tabindex=>"1")
			. qq|</td></tr><tr><td class='header'>End</td><td>|
			. textfield(-name=>"date_end", -override=>1, -value=> $date_end, size=>'23', tabindex=>"2")
			. qq|</td></tr>|;


	# make a dropdown list for export summarisation options
	my @options = ref($C->{export_summarisation_periods}) eq "ARRAY"?
			@{$C->{export_summarisation_periods}}: ( 300, 900, 1800, 3600, 4*3600 );
	my %labels = ( '' => "best", map { ($_=> NMISNG::Util::period_friendly($_)) } (@options));

	print qq|<tr><td class='header'>Resolution</td><td>Select one of |
			. popup_menu(-name => "resolution",
									 -id => "exportres",
									 -values => [ '', @options ],
									 -override => 1,
									 -labels => \%labels, )
			# also add an input field for a one-off text input
			. qq| or enter |
			.textfield(-name => "custom_resolution",
								 -id => "exportrescustom",
								 -override => 1,
								 -placeholder => "NNN",
								 -size => 6	)
			. qq| seconds </td></tr>|
			. qq|<tr><td class='header'>Compute Min/Max for each period?</td><td>|
			.checkbox(-name=>'add_minmax',
								-checked => 0,
								-override => 1,
								-value=>1,
								-label=>'')
			. qq| (only for Resolutions other than 'best')</td></tr>|;

	print  qq|<tr><td class='header' colspan='2' align='center'>|
			. hidden(-name => 'cancel', -id => 'cancelinput', -default => '', -override => 1)
			. submit( -value=>'Export')
			.qq| or <input name="cancel" type='button' value="Cancel" onclick="\$('#cancelinput').val(1); this.form.submit()"></td></tr></table>|;
}


# exports the underlying data for a particular graph as csv,
# optionally further bucketised into fewer readings
# params: node (or group?), graphtype, intf/item, start/end (or date_start/date_end),
# resolution (optional; default or blank, zero: use best resolution),
# also custom_resolution (optional, if present overrides resolution)
sub typeExport
{
	my $S = NMISNG::Sys->new; # get system object
	$S->init(name => $Q->{node}, snmp => 'false');
	my $graphtype = $Q->{graphtype};

	my %interfaceTable;
	my $database;
	my $extName;

	# verify that user is authorized to view the node within the user's group list
	my $nodegroup = $S->nmisng_node->configuration->{group} if ($Q->{node});
	if ($Q->{node} && !$AU->InGroup($nodegroup))
	{
		bailout(code => 403, message => "Not Authorized to export rrd data for node '$Q->{node}' in group '$nodegroup'.");
	} elsif ( $Q->{group} && !$AU->InGroup($Q->{group}))
	{
		bailout(code => 403, message => "Not Authorized to export rrd data for nodes in group '$Q->{group}'.");
	}
	# check for overlays (which currently are only percentile)
	my $res = NMISNG::Util::getModelFile(model => "Graph-$graphtype");
	if (!$res->{success}) 
	{
		bailout(code => 400, message => "failed to read Graph-$graphtype!");
	}
	my $graph = $res->{data};

	# figure out start and end
	my ($start, $end) = @{$Q}{"start","end"};
	$start //= NMISNG::Util::parseDateTime($Q->{date_start})
			|| NMISNG::Util::getUnixTime($Q->{date_start}) if ($Q->{date_start});
	$end //= NMISNG::Util::parseDateTime($Q->{date_end})
			|| NMISNG::Util::getUnixTime($Q->{date_end}) if ($Q->{date_end});

	my $mayberesolution = ( defined($Q->{custom_resolution}) && $Q->{custom_resolution} =~ /^\d+$/?
													$Q->{custom_resolution}
													: defined($Q->{resolution})
													&& $Q->{resolution} =~ /^\d+$/
													&& $Q->{resolution} != 0?
													$Q->{resolution}: undef );

	my $db = $S->makeRRDname(graphtype => $graphtype, index=>$Q->{intf},item=>$Q->{item});
	my ($statval,$head,$meta) = NMISNG::rrdfunc::getRRDasHash(database => $db,
																														mode=>"AVERAGE",
																														start => $start,
																														end => $end,
																														resolution => $mayberesolution,
																														add_minmax => $Q->{add_minmax}?1:0);
	bailout(message => "Failed to retrieve RRD data: $meta->{error}\n") if ($meta->{error});

	# no data? complain, don't produce an empty csv
	bailout(message => "No exportable data found!") if (!keys %$statval or !$meta->{rows_with_data});

	# graphtypes for custom service graphs are fixed and not found in the model system
	# note: format known here, in services.pl and nmis.pl
	my $heading;
	if ($Q->{graphtype} =~ /^service-custom-([a-z0-9\.-])+-([a-z0-9\._-]+)$/)
	{
		$heading = $2;
	}
	else
	{
		# fixme: really group in item???
		$heading = $S->graphHeading(graphtype=>$Q->{graphtype}, index=>$Q->{intf}, item=>$Q->{group});
	}
	# some graphtypes have a heading that includes an identifier (eg. most interface graphs),
	# but most others don't (e.g. Services, disks...), so we must include the intf/item in the filename
	my $filename  = join("-", ($Q->{node} || $Q->{group}), $heading, $Q->{intf}//$Q->{item}).".csv";
	$filename =~ s![/: '"]+!_!g;	# no /, no colons or quotes or spaces please

	$headeropts->{type} = "text/csv";
	$headeropts->{"Content-Disposition"} = "attachment; filename=\"$filename\"";

	$S->nmisng->log->info("Exporting data for $Q->{node} $Q->{intf} $Q->{item} $start to $end, headers: @$head");

	#If we have the grapgh autil convert the in and out octets to util and then work out the 95% across the range
	if($Q->{graphtype} eq "autil")
	{

		#now we know we are looking at an interface grab its inventory class so we can then get the speed in and out
		my $pathdata = { index => $Q->{intf} };
		my $path = $S->nmisng_node->inventory_path( concept => 'interface', data => $pathdata, partial => 1 );
		my ($inventory, $error) = $S->nmisng_node->inventory( concept => 'interface', path => $path);
		if( $error )
		{
			$S->nmisng->log->error("Failed to load inventory for interface $Q->{intf} on node $Q->{node}: $error");
			bailout(message => "Failed to load inventory for interface $Q->{intf} on node $Q->{node}");
		}
		my $ifSpeedIn = $inventory->ifSpeedIn;
		my $ifSpeedOut = $inventory->ifSpeedOut;

		#got the speed time to work out util, we will have this as part of statval

		#first loop is to work out the util
		my (@ifUtilBucket, @ifUtilBucketOut);
		foreach my $rtime (sort keys %{$statval})
		{

			if(defined($statval->{$rtime}->{ifInOctets}))
			{
				my $val = $statval->{$rtime}->{ifInOctets};
				my $util = $val * 8 / $ifSpeedIn * 100;
				$statval->{$rtime}->{ifInUtil} = $util;
				push @ifUtilBucket, $util;
			}

			if(defined($statval->{$rtime}->{ifOutOctets}))
			{
				my $val = $statval->{$rtime}->{ifOutOctets};
				my $util = $val * 8 / $ifSpeedOut * 100;
				$statval->{$rtime}->{ifOutUtil} = $util;
				push	@ifUtilBucketOut, $util;
			}
		}
		#headers for csv
		push @$head, "ifInUtil";
		push @$head ,"ifOutUtil";
	}

	# look for overlays, if it's there look for percentile, find dataset values, calculate percentile, 
	# put that back into the stat values, one entry for each time
	if(defined ($graph->{option}{overlays}) and ref($graph->{option}{overlays}) eq "HASH")
	{
		my $overlays = $graph->{option}->{overlays};
		if(defined($overlays->{percentile}) and ref($overlays->{percentile}) eq "HASH")
		{
			my $po = $overlays->{percentile};
			#check if this is between 0 and 100
			my $calculate_percentile = 95;
			$calculate_percentile = $po->{calculate} if(defined($po->{calculate}) and $po->{calculate} >= 0 and $po->{calculate} <=	100);

			#we have a key which is our dataset name as input and value whic will be the label on the graph, if small we dont show the label
			if(defined($po->{datasets}) and ref($po->{datasets}) eq "HASH")
			{
				my $datasets = $po->{datasets};
				#sort the datasets
				my @sorted_datasets = sort keys %$datasets;
				foreach my $ds (@sorted_datasets)
				{
					my $newTitle = $datasets->{$ds};
					my $dsData;
					# get the data in the dataset
					foreach my $rtime (keys %{$statval}) {
						push @$dsData, $statval->{$rtime}{$ds} if( defined($statval->{$rtime}{$ds}) );
					}
					# calculate the  percentil
					my $percentile = NMISNG::Util::percentile($calculate_percentile, @$dsData);
					foreach my $rtime (keys %{$statval})
					{
						$statval->{$rtime}->{$newTitle} = $percentile;
					}
					push @$head, $newTitle;
				}
			}
		}
	}

	print header($headeropts);

	my $csv = Text::CSV->new;
	# header line, then the goodies
	if (ref($head) eq "ARRAY" && @$head)
	{
		$csv->combine(@$head);
		print $csv->string,"\n";
	}

	# print any row that has at least one reading with known ds/header name
	foreach my $rtime (sort keys %{$statval})
	{
		if ( List::Util::any { defined $statval->{$rtime}->{$_} } (@$head) )
		{
			$csv->combine(map { $statval->{$rtime}->{$_} } (@$head));
			print $csv->string,"\n";
		}
	}
	exit 0;
}

sub typeStats
{
	my $S = NMISNG::Sys->new; # get system object
	bailout(message => "Node not found") if( !$S->init(name=>$Q->{node}) );

	my $C = $nmisng->config;


	# verify that user is authorized to view the node within the user's group list
	my $nodegroup = $S->nmisng_node->configuration->{group} if ($Q->{node});
	if ( $Q->{node} && !$AU->InGroup($nodegroup) )
	{
		bailout(code => 403, message => "Not Authorized to export rrd data on node $Q->{node} in group $nodegroup");
	} elsif ( $Q->{group} && !$AU->InGroup($Q->{group}) )
	{
		bailout(code => 403, message => "Not Authorized to export rrd data on nodes in group $Q->{group}");
	}

	print header($headeropts), start_html(
		-title => "Statistics",
		-meta => { 'CacheControl' => "no-cache",
							 'Pragma' => "no-cache",
			'Expires' => -1
		},
		-head=>[
			 Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"}),
		],
		-script => {-src => $C->{'jquery'}, -type=>"text/javascript"},
			);

	$Q->{intf} = $Q->{group} if $Q->{group} ne '';

	my $db = $S->makeRRDname(graphtype => $Q->{graphtype}, index=>$Q->{intf},item=>$Q->{item});
	my $statval = (-f $db? NMISNG::rrdfunc::getRRDStats(database => $db,
																											graphtype=>$Q->{graphtype},
																											mode=>"AVERAGE",
																											start=>$Q->{start},
																											end=>$Q->{end},
																											index=>$Q->{intf},item=>$Q->{item}) : {});
	my $f = 1;
	my $starttime = NMISNG::Util::returnDateStamp($Q->{start});
	my $endtime = NMISNG::Util::returnDateStamp($Q->{end});

	print start_table;

	print Tr(td({class=>'header',colspan=>'11'},"NMIS RRD Graph Stats $Q->{node} $Q->{intf} $Q->{item} $starttime to $endtime"));

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

# determine if the given graphtype belongs to systemhealth-modelled section,
# and if so, look up the labels
# args: sys object, graphtype, graphtypetable, section, index (all required)
# returns: title_struct (hashref), concept, subconcept, index_model, data
#
# note: graphtypetable may be modified!
# fixme9: this is an utter mess
sub get_graphtype_titles
{
	my (%args) = @_;

	my ($S,$graphtype,$GTT,$section,$index) = @args{"sys","graphtype","graphtypetable","section","index"};
	my $M = $S->mdl;

	# fixme9: we have enough data to not need getTypeInstances anymore, should be able to
	# directly access inventory

	# section needed to find cbqos instances
	my $modeldata = $S->getTypeInstances(section => $section,
																			 graphtype => $graphtype,
																			 want_modeldata => 1,
																			 want_active => 1 );

	my $data = $modeldata->data;
	# we can assume that the concept is the same in all entries
	my $concept = ($modeldata->count > 0) ? $data->[0]{concept} : undef;
	my $subconcept = $GTT->{$graphtype};
	my %index_map = map { $_->{data}{index} => $_ } @$data; # fixme9: cannot work for concept=service and other non-indexed
	my $index_model = ($index) ? $index_map{$index} : {};

	# fixme9: non-node mode means no graphttypetable means no menu and nothing works...
	$GTT->{$graphtype} = $graphtype if (!$S->nmisng_node && !$modeldata->count && !keys %$GTT);

	# different graphs get their label/name from different places, this normalises
	# that and allows grabbing the data from the inventory model
	# do this by subconcept, concept is too broad, things like storage break it
	my %title_struct = (
		hrsmpcpu => { name => 'CPU' },
		hrdisk => { name => 'Disk', label_key =>'hrStorageDescr' },
		interface => { name => 'Interface', label_key => 'ifDescr' },
		pkts => { name => 'Interface', label_key => 'ifDescr' },
		pkts_hc => { name => 'Interface', label_key => 'ifDescr' },
		'cbqos-in' => { name => 'Interface', label_key => 'ifDescr' },
		'cbqos-out' => { name => 'Interface', label_key => 'ifDescr' },
			);

	# get the dropdown info for system health, we need to figure out which of the
	# inventory data entries should be used for the label_key and name
	if( $concept && defined($M->{systemHealth}{sys}{$concept}) )
	{
		my $thismdlsect = $M->{systemHealth}->{sys}->{$concept};

		# all model entries will have the same inventory concept so just use the first one
		if( @$data > 0 )
		{
			my $model = $data->[0];
			$S->nmisng->log->debug("model, index: $model->{data}{index}");

			my $label = $thismdlsect->{headers};
			$label =~ s/,.*$//;
			my $title = $label;

			if ( exists $thismdlsect->{snmp}->{$label}->{title}
					 and $thismdlsect->{snmp}->{$label}->{title} ne "" )
			{
				$title = $thismdlsect->{snmp}->{$label}->{title};
			}
			# indexes are already where they should be
			$title_struct{$subconcept} = { name => $title, label_key => $label };
		}
	}

	return (\%title_struct, $concept, $subconcept, $index_model, $data);
}
