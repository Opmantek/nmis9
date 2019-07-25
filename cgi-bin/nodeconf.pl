#!/usr/bin/perl
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

use strict;
use Compat::NMIS;
use NMISNG::Util;
use NMISNG::Auth;

use Data::Dumper;
$Data::Dumper::Indent = 1;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash


my $nmisng = Compat::NMIS::new_nmisng;
my $C = $nmisng->config;

my $widget = NMISNG::Util::getbool($Q->{widget},"invert") ? 'false' : 'true';
$Q->{expand} = "true" if ($widget eq "true");

### unless told otherwise, and this is not JQuery call, widget is false!
if ( not defined $Q->{widget} and not defined $ENV{HTTP_X_REQUESTED_WITH} ) {
	$widget = "false";
}

if ( not defined $ENV{HTTP_X_REQUESTED_WITH} ) {
	$widget = "false";
}

my $wantwidget = ($widget eq "true");

my $formid = 'nodeconf';

# Before going any further, check to see if we must handle
# an authentication login or logout request


# variables used for the security mods
my $headeropts = {type => 'text/html', expires => 'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_nodeconf_view","header");

# check for remote request - fixme9: not supported at this time
exit 1 if (defined($Q->{cluster_id}) && $Q->{cluster_id} ne $C->{cluster_id});

#======================================================================

# select function
if ($Q->{act} eq 'config_nodeconf_view') {
	displayNodemenu();
}
elsif ($Q->{act} eq 'config_nodeconf_update') {
	if (updateNodeConf()){ displayNodemenu(); }
}
else {
	displayNodemenu();
	#notfound();
}

sub notfound {
	print header(-status=>400, %$headeropts);
	print "nodeConf: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit;

#==================================================================
#
# display
#
sub displayNodemenu
{
	my $NT = Compat::NMIS::loadLocalNodeTable();

	print header($headeropts);
	if (!$wantwidget)
	{
			Compat::NMIS::pageStart(title => $Q->{node}." Node Configuration");
	}
	my $menuformid = "${formid}_menu";

	print start_table,start_Tr,start_td;

	# start of form
	my $thisurl = url(-absolute => 1)."?";
  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id => $menuformid, -href => $thisurl);
	print hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nodeconf_view")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table() ; # first table level

	# row with Node selection
	my @nodes = ("",grep { $AU->InGroup($NT->{$_}{group})
														 and NMISNG::Util::getbool($NT->{$_}{active}) } sort keys %{$NT});
	print start_Tr;
	print td({class=>"header"}, a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $Compat::NMIS::VERSION"))
			if (!NMISNG::Util::getbool($Q->{widget}));

	print td({class=>"header",width=>'25%'},
			"Select node<br>".
				popup_menu(-name=>"node", -override=>'1',
					-values=>\@nodes,
					-default=>"$Q->{node}",
					-title=>"node to modify",
					-onChange=> ($wantwidget? "get('$menuformid');" : "submit()" )));

	print td({class=>"header",align=>'center'},'Optional Node and Interface Configuration');
	print end_Tr;
	print end_table();

	print end_form;

	# background values

	displayNodeConf(node=>$Q->{node}) if $Q->{node} ne "";

	print end_td,end_Tr,end_table;

	Compat::NMIS::pageEnd if (!$wantwidget);

}


# show the config form for a single given node
sub displayNodeConf
{
	my %args = @_;
	my $node = $args{node};


	my $thisurl = url(-absolute => 1)."?";
	print start_form(-id => $formid, -href => $thisurl);
	print hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nodeconf_update")
			. hidden(-override => 1, -name => "node", -value => $node)
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-id => "doupdate", -override => 1, -name => "update", -value => '');

	print start_table({width=>'100%'}) ; # first table level

	my $S = NMISNG::Sys->new(nmisng => $nmisng);

	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr,td({class=>'error',colspan=>'3'},"Error on getting info of node $node");
		return;
	}

	my $nodeobj = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	my $result = $nodeobj->get_inventory_model(
		concept => 'interface', filter => { historic => 0 });

	# get any existing nodeconf overrides for this node
	my $override = $nodeobj->overrides;

	print Tr(td({class=>"header",width=>'20%'}),td({class=>"header",width=>'20%'}),
			td({class=>"header",width=>'20%'},'<b>Original value</b>'),
			eval {
				if ($AU->CheckAccess("Table_nodeConf_rw","check")) {
					return td({class=>"header"},'<b>Replaced by</b><br>(active after update of node)') ;
				} else {
					return td({class=>"header"},'<b>Replaced by') ;
				}
			});

	print Tr(td({class=>'header'},'<b>Node</b>'),td({class=>'header'},"&nbsp;"),
			td({class=>'header'},"&nbsp;"),td({-align=>'center'},
				eval {
					if ($AU->CheckAccess("Table_nodeConf_rw","check"))
					{
							# in case of store config non-widgetted we only need to
							# submit the form
							# (and ensure the doupdate hidden field is off, if we're
							# coming back to this page!)
							return button(-name=>'submitbutton',
														onclick => ($wantwidget? "get('$formid');"
																				: '$("#doupdate").val(""); submit()'),
														-value=>'Store'),

							# but to emulate the update=true get() call, we need to set
							# the appropriate hidden field before submitting and convince
							# get not to mess with the url, or we'll have duplicate but
							# different update fields...
							button(-name=>'updatebutton',
										 onclick => '$("#doupdate").val("true"); '
										 .($wantwidget? "get('$formid');" : 'submit();'),
										 -value=>'Store and Update Node');
					} else { return ""; }
				}));

	my $NCT_sysContact = $catchall_data->{sysContact};
	print Tr,td({class=>"header"}),td({class=>"header"},"Contact"),
			td({class=>'header3'}, $NCT_sysContact),
	td({class=>"Plain"},textfield(-name=>"contact",-override=>1,
																-style => 'width: 95%',
																-value => $override->{sysContact}||''));

	my $NCT_sysLocation = $catchall_data->{sysLocation};
	print Tr,td({class=>"header"}),td({class=>"header"},"SNMP Location"),
			td({class=>'header3'}, $NCT_sysLocation),
	td({class=>"Plain"},textfield(-name=>"location",-override=>1,
																-style => 'width: 95%',
																-value => $override->{sysLocation}||''));

	if ( !NMISNG::Util::getbool($catchall_data->{collect}) ) {
		print Tr(td({class=>"header"}),td({class=>"header"},"Collect"),
				td({class=>'header'},'disabled'));
	}

	my $NCT_nodetype = $catchall_data->{nodeType};
	print Tr,td({class=>"header"}),td({class=>"header"},"Node Type"),
	td({class=>'header3'}, $NCT_nodetype),
	td({class=>"Plain"},
		 popup_menu(-name=>"nodetype", -override=>'1',
								-values=>["", split(/\s*,\s*/, $C->{nodetype_list})],
								-labels => { "" => "<from model>", map { $_ => $_ } (split(/\s*,\s*/, $C->{nodetype_list})) },
								-default=> "",
								-style => 'width: 95%',
								-title=>"new Node Type" ));

	# label for the 'desired state' column
	my %rglabels = ('unchanged' => 'unchanged', 'false' => 'false', 'true' => 'true');

	# result is from interface inventory lookup
	if ( NMISNG::Util::getbool($catchall_data->{collect})
			 && !$result->error && $result->count )
	{
		print Tr,td({class=>'header'},'<b>Interfaces</b>');

		my %ifinfo = map { ($_->{data}->{index} => $_->{data} )} (@{$result->data});

		foreach my $intf (NMISNG::Util::sorthash( \%ifinfo, ['ifDescr'], 'fwd'))
		{
			my $intfstatus = $ifinfo{$intf};

			next if (ref($intfstatus) ne "HASH" or !keys %$intfstatus
							 or !defined($intfstatus->{ifDescr})
							 or $intfstatus->{ifDescr} eq ''); # exists but empty text should no longer happen

			my ($description, $displayname, $speed, $speedIn, $speedOut,
					$collect, $event, $threshold,$size, $setlimits);

			my $ifDescr = $intfstatus->{ifDescr};
			my $thisintfover = ref($override->{$ifDescr}) eq "HASH"? $override->{$ifDescr} : {};

			# check if interfaces are changed - fixme what does that mean?
			if ($thisintfover->{ifDescr}
					and $ifDescr ne $thisintfover->{ifDescr})
			{
				# fixme undef better?
				$collect = $event = $threshold = $description = $displayname = $speed = undef;
			}
			else
			{
				if ( !$thisintfover->{ifSpeedIn} and $thisintfover->{ifSpeed} )
				{
					$thisintfover->{ifSpeedIn} = $thisintfover->{ifSpeed};
				}
				if (!$thisintfover->{ifSpeedOut} and $thisintfover->{ifSpeed})
				{
					$thisintfover->{ifSpeedOut} = $thisintfover->{ifSpeed};
				}

				$description = $thisintfover->{Description};
				$displayname = $thisintfover->{display_name};
				$speed = $thisintfover->{ifSpeed};
				$speedIn = $thisintfover->{ifSpeedIn};
				$speedOut = $thisintfover->{ifSpeedOut};
				$collect = $thisintfover->{collect};
				$event = $thisintfover->{event};
				$threshold = $thisintfover->{threshold};
				$setlimits = $thisintfover->{setlimits};
			}
			$setlimits = "normal" if (!$setlimits or $setlimits !~ /^(normal|strict|off)$/);

			my $NCT_Description = exists $intfstatus->{nc_Description} ?
					$intfstatus->{nc_Description} : $intfstatus->{Description};

			print Tr,
			td({class=>'header'}, $intfstatus->{ifDescr}),
			td({class=>'header'},"Description"),td({class=>'header3'},$NCT_Description),
			td({class=>"Plain"},textfield(-name=>"descr_${intf}",
																		-style => 'width: 95%',
																		-override=>1,
																		-value=>$description));

			print Tr, td({class=>'header'}),
			td({class=>'header'},"Display Name"),td({class=>'header3'}, $displayname),
			td({class=>"Plain"},textfield(-name=>"displayname_${intf}",
																		-style => 'width: 95%',
																		-override=>1,
																		-value => $displayname));

			my $NCT_ifSpeed = $intfstatus->{nc_ifSpeed} || $intfstatus->{ifSpeed};
			#print Tr,td({class=>'header'}),
			#	td({class=>'header'},"Speed"),td({class=>'header3'},$NCT_ifSpeed),
			#	td({class=>"Plain"},textfield(-name=>"speed_${intf}",-override=>1,-value=>$speed));

			my $NCT_ifSpeedIn = $intfstatus->{nc_ifSpeedIn} || $intfstatus->{ifSpeedIn};
			$NCT_ifSpeedIn = $NCT_ifSpeed if not $NCT_ifSpeedIn;
			print Tr,td({class=>'header'}),
			td({class=>'header'},"Speed In"),td({class=>'header3'},$NCT_ifSpeedIn),
			td({class=>"Plain"},textfield(-name=>"speedIn_${intf}",-override=>1,-value=>$speedIn));

			my $NCT_ifSpeedOut = $intfstatus->{nc_ifSpeedOut} || $intfstatus->{ifSpeedOut};
			$NCT_ifSpeedOut = $NCT_ifSpeed if not $NCT_ifSpeedOut;
			print Tr,td({class=>'header'}),
			td({class=>'header'},"Speed Out"),td({class=>'header3'},$NCT_ifSpeedOut),
			td({class=>"Plain"},textfield(-name=>"speedOut_${intf}",-override=>1,-value=>$speedOut));


			print Tr,td({class=>'header'}),
			td({class=>'header'},"Speed Limit"), td({class=>'header3'}, $setlimits),
			td({class=>"Plain"}, radio_group(-name=>"setlimits_${intf}",
																			 -values=>['normal',
																								 'strict',
																								 'off'],
																			 -default=>$setlimits, ));

			my $NCT_collect = $intfstatus->{nc_collect} || $intfstatus->{collect};
			print Tr,td({class=>'header'}),
			td({class=>'header'},"Collect"),td({class=>'header3'},$NCT_collect),
			td({class=>"Plain"},radio_group(-name=>"collect_${intf}",
																			-values=>['unchanged',
																								'true',
																								'false'],
																			-default=>$collect,-labels=>\%rglabels));



			if ( NMISNG::Util::getbool($collect) or (!NMISNG::Util::getbool($collect,"invert")
																 and NMISNG::Util::getbool($NCT_collect)) )
			{
				my $NCT_event = $intfstatus->{nc_event} || $intfstatus->{event};
				print Tr,td({class=>'header'}),
				td({class=>'header'},"Events"),td({class=>'header3'},$NCT_event),
				td({class=>"Plain"},radio_group(-name=>"event_${intf}",
																				-values=>['unchanged',
																									'true',
																									'false'],
																				-default=>$event,-labels=>\%rglabels));
			} else {
				print hidden(-name=>"event_${intf}", -default=>'unchanged',-override=>'1');
			}

			if (NMISNG::Util::getbool($catchall_data->{threshold})
					and (NMISNG::Util::getbool($collect) or (!NMISNG::Util::getbool($collect,"invert")
																		 and NMISNG::Util::getbool($NCT_collect)) )) {
				my $NCT_threshold = $intfstatus->{nc_threshold} || $intfstatus->{threshold};
				print Tr,td({class=>'header'}),
				td({class=>'header'},"Thresholds"),td({class=>'header3'},$NCT_threshold),
				td({class=>"Plain"},
					 radio_group(-name=>"threshold_${intf}",
											 -values=>['unchanged',
																 'true',
																 'false'],
											 -default=>$threshold,-labels=>\%rglabels));
			} else {
				print hidden(-name=>"threshold_${intf}", -default=>'unchanged',-override=>'1');
			}


		}
	}
	else
	{
		print Tr(td({class=>'info',colspan=>'4'},"No collection of Interfaces"));
	}
	print end_table();
	print end_form;
}

# combine the form data submitted by the user with the current nodeconf (if any)
# and save the result.
sub updateNodeConf {
	my %args = @_;

	my $node = $Q->{node};

	my $S = NMISNG::Sys->new;

	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr,td({class=>'error',colspan=>'4'},"Error on getting info of node $node");
		return;
	}

	my $nodeobj = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	my %ifinfo;
	my $result = $nodeobj->get_inventory_model(
		concept => 'interface',
		filter => { historic => 0 });
	if (!$result->error)
	{
		%ifinfo = map { ($_->{data}->{index} => $_->{data} )} (@{$result->data});
	}

	# get the current nodeconf overrides
	my $override = $nodeobj->overrides;

	if  ($Q->{contact} eq "") {
		delete $override->{sysContact};
	} else {
		$override->{sysContact} = $Q->{contact};
	}
	if  ($Q->{location} eq "") {
		delete $override->{sysLocation};
	} else {
		$override->{sysLocation} = $Q->{location};
	}
	if ($Q->{nodetype} eq "") {
		delete $override->{nodeType};
	} else {
		$override->{nodeType} = $Q->{nodetype};
	}

	# $intf is the ifIndex
	foreach my $intf (keys %ifinfo)
	{
		my $ifDescr = $ifinfo{$intf}->{ifDescr};
		my $thisintfover = $override->{$ifDescr} ||= {};

		$thisintfover->{ifDescr} = $ifinfo{$intf}->{ifDescr}; # for linking the if state to the nodeconf

		my %tranferrables = ("descr_$intf" => "Description",
												 "displayname_$intf" => "display_name",
												 "speed_$intf" => "ifSpeed",
												 "speedIn_$intf" => "ifSpeedIn",
												 "speedOut_$intf" => "ifSpeedOut",
												 "collect_$intf" => "collect",
												 "event_$intf" => "event",
												 "threshold_$intf" => "threshold",
												 "setlimits_$intf" => "setlimits",
				);

		while (my ($source, $target) = each %tranferrables)
		{
			# event, collect and threshold are special:
			# value "unchanged" means remove the override
			if (($source =~ /^(collect|event|threshold)_/ and $Q->{$source} eq "unchanged")
					or !$Q->{$source})	# others: no value given means remove
			{
				delete $thisintfover->{$target};
			}
			else
			{
				$thisintfover->{$target} = $Q->{$source};
			}
		}

		# don't keep this override if there are no entries except the automatic 'ifDescr'
		delete $override->{$ifDescr} if (scalar keys %{$thisintfover} == 1);
	}

  # this makes the resulting subsequent node menu into a blank one,
	# longterm fixme: instead this should report an 'update done' and show the same node again
	delete $Q->{node};

	if (keys %$override)
	{
		$nodeobj->overrides($override);
		my ($success, $errmsg) = $nodeobj->save;
		$nmisng->log->error("nodeconf: $errmsg") if ($success < 0);
	}

	# signal from button - schedule update job with high priority
	if ( NMISNG::Util::getbool($Q->{update}) )
	{
		my ($error,$jobid) = $nmisng->update_queue(
			jobdata => {
				type => "update",
				time => time,
				priority => 1,
				in_progress => 0,
				args => { uuid => $S->nmisng_node->uuid }});

		print header($headeropts);
		if (!$wantwidget)
		{
			Compat::NMIS::pageStart(title => "$node update");
		}

		my $thisurl = url(-absolute => 1)."?";
		print start_form(-id=>$formid, -href => $thisurl);
		print hidden(-override => 1, -name => "conf", -value => $Q->{conf})
				. hidden(-override => 1, -name => "act", -value => "config_nodeconf_view")
				. hidden(-override => 1, -name => "widget", -value => $widget);

		print table(Tr(td({class=>'header'},escapeHTML("User-initiated update of $node")))),

		$error? "<strong>Failed to schedule update: $error</strong>" :
				"An update operation was scheduled for this node (job id $jobid),
which should start processing within a minute.<p>Please reload the node's dashboard page
once that update operation has completed.<p>";

		print end_form;

		return 0;
	}
	return 1;
}
