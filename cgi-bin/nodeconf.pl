#!/usr/bin/perl
#
## $Id: nodeconf.pl,v 8.8 2012/10/08 08:17:50 keiths Exp $
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

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new;  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_nodeconf_view","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

if ($Q->{act} eq 'config_nodeconf_view') {			displayNodemenu();
} elsif ($Q->{act} eq 'config_nodeconf_update') {	if (updateNodeConf()){ displayNodemenu(); }
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "nodeConf: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit;

#==================================================================
#
# display 
#
sub displayNodemenu{

	my $NT = loadLocalNodeTable();

	#start of page
	print header($headeropts);

	print start_table,start_Tr,start_td;

	# start of form
	print start_form(-id=>"nmis1",-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_nodeconf_view");

	print start_table() ; # first table level

	# row with Node selection
	my @nodes = ("",grep { $AU->InGroup($NT->{$_}{group}) and $NT->{$_}{active} eq 'true' } sort keys %{$NT});
	print start_Tr;
	print td({class=>"header",width=>'25%'},
			"Select node<br>".
				popup_menu(-name=>"node", -override=>'1',
					-values=>\@nodes,
					-default=>"$Q->{node}",
					-title=>"node to modify",
					-onChange=>"get('nmis1');"));

	print td({class=>"header",align=>'center'},'Optional Node and Interface Configuration');
	print end_Tr;
	print end_table();
	print end_form;

	# background values

	displayNodeConf(node=>$Q->{node}) if $Q->{node} ne "";

	print end_td,end_Tr,end_table;

	htmlElementValues();

}

sub displayNodeConf {
	my %args = @_;
	my $node = $args{node};

	# start of form
	print start_form(-id=>"nmis",-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_nodeconf_update&node=$node");

	print start_table({width=>'100%'}) ; # first table level

	my $S = Sys::->new;

	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr,td({class=>'error',colspan=>'3'},"Error on getting info of node $node");
		return;
	}
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my $NCT = loadNodeConfTable();

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
					if ($AU->CheckAccess("Table_nodeConf_rw","check")) {
						return button(-name=>'button',onClick=>"javascript:get('nmis');" ,-value=>'Store'),
						button(-name=>'button',onClick=>"javascript:get('nmis','update');" ,-value=>'Store and Update Node');
					} else { return ""; }
				}));

	my $NCT_sysContact = $NI->{nodeconf}{sysContact} || $NI->{system}{sysContact};
	print Tr,td({class=>"header"}),td({class=>"header"},"Contact"),
			td({class=>'header3'}, $NCT_sysContact),
			td({class=>"Plain"},textfield(-name=>"contact",-override=>1,-value=>$NCT->{$node}{sysContact}));

	my $NCT_sysLocation = $NI->{nodeconf}{sysLocation} || $NI->{system}{sysLocation};
	print Tr,td({class=>"header"}),td({class=>"header"},"Location"),
			td({class=>'header3'}, $NCT_sysLocation),
			td({class=>"Plain"},textfield(-name=>"location",-override=>1,-value=>$NCT->{$node}{sysLocation}));

	if ($NI->{system}{collect} ne 'true') {
		print Tr(td({class=>"header"}),td({class=>"header"},"Collect"),
				td({class=>'header'},'disabled'));
	}


	### 2012-10-08 keiths, updates to index node conf table by ifDescr instead of ifIndex.
	# interfaces
	if ($NI->{system}{collect} eq 'true') {
		print Tr,td({class=>'header'},'<b>Interfaces</b>');
		foreach my $intf (sorthash( $IF, ['ifDescr'], 'fwd') ) {
			my ($description,$speed,$collect,$event,$threshold,$size);
			
			# keep the ifDescr to work on.
			my $ifDescr = $IF->{$intf}{ifDescr};

			# check if interfaces are changed
			if ($NCT->{$node}{$ifDescr}{ifDescr} ne "" and $IF->{$intf}{ifDescr} ne $NCT->{$node}{$ifDescr}{ifDescr}) {
				$collect = $event = $threshold = $description = $speed = "";
			} else {
				$description = $NCT->{$node}{$ifDescr}{Description};
				$speed = $NCT->{$node}{$ifDescr}{ifSpeed};
				$collect = $NCT->{$node}{$ifDescr}{collect} || 'not';
				$event = $NCT->{$node}{$ifDescr}{event} || 'not';
				$threshold = $NCT->{$node}{$ifDescr}{threshold} || 'not';
			}

			my $NCT_Description = exists $IF->{$intf}{nc_Description} ? $IF->{$intf}{nc_Description} : $IF->{$intf}{Description};
			print Tr,
				td({class=>'header'}, $IF->{$intf}{ifDescr}),
				td({class=>'header'},"Description"),td({class=>'header3'},$NCT_Description),
				td({class=>"Plain"},textfield(-name=>"descr_${intf}",-override=>1,-value=>$description));

			my $NCT_ifSpeed = $IF->{$intf}{nc_ifSpeed} || $IF->{$intf}{ifSpeed};
			print Tr,td({class=>'header'}),
				td({class=>'header'},"Speed"),td({class=>'header3'},$NCT_ifSpeed),
				td({class=>"Plain"},textfield(-name=>"speed_${intf}",-override=>1,-value=>$speed));

			my $NCT_collect = $IF->{$intf}{nc_collect} || $IF->{$intf}{collect};
			print Tr,td({class=>'header'}),
				td({class=>'header'},"Collect"),td({class=>'header3'},$NCT_collect),
				td({class=>"Plain"},radio_group(-name=>"collect_${intf}",-values=>['not',$NCT_collect eq 'true' ? 'false':'true'],-default=>$collect));

			if ($collect eq 'true' or ($collect ne 'false' and $NCT_collect eq 'true') ) {
				my $NCT_event = $IF->{$intf}{nc_event} || $IF->{$intf}{event};
				print Tr,td({class=>'header'}),
					td({class=>'header'},"Events"),td({class=>'header3'},$NCT_event),
					td({class=>"Plain"},radio_group(-name=>"event_${intf}",-values=>['not',$NCT_event eq 'true' ? 'false':'true'],-default=>$event));
			} else {
				print hidden(-name=>"event_${intf}", -default=>'not',-override=>'1');
			}
			if ($NI->{system}{threshold} eq 'true' and ($collect eq 'true' or ($collect ne 'false' and $NCT_collect eq 'true')) ) {
				my $NCT_threshold = $IF->{$intf}{nc_threshold} || $IF->{$intf}{threshold};
				print Tr,td({class=>'header'}),
					td({class=>'header'},"Thresholds"),td({class=>'header3'},$NCT_threshold),
					td({class=>"Plain"},radio_group(-name=>"threshold_${intf}",-values=>['not',$NCT_threshold eq 'true' ? 'false':'true'],-default=>$threshold));
			} else {
				print hidden(-name=>"threshold_${intf}", -default=>'not',-override=>'1');
			}				
		}
	} else {
		print Tr(td({class=>'info',colspan=>'4'},"No collect of Interfaces"));
	}
	print end_table();
	print end_form;
}

sub updateNodeConf {
	my %args = @_;

	my $node = $Q->{node};

	my $S = Sys::->new;

	if (!($S->init(name=>$node,snmp=>'false'))) {
##		print Tr,td({class=>'error',colspan=>'4'},"Error on getting info of node $node");
		return;
	}
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	my $NCT = loadNodeConfTable();

	if  ($Q->{contact} eq "") {
		delete $NCT->{$node}{sysContact} if exists $NCT->{$node}{sysContact};
	} else {
		$NCT->{$node}{sysContact} = $Q->{contact};
	}
	if  ($Q->{location} eq "") {
		delete $NCT->{$node}{sysLocation} if exists $NCT->{$node}{sysLocation};
	} else {
		$NCT->{$node}{sysLocation} = $Q->{location};
	}

	### 2012-10-08 keiths, updates to index node conf table by ifDescr instead of ifIndex.
	### $intf if the ifIndex, and ifDescr is the ifDescr, and this needs to be done to handle the cross indexing.
	foreach my $intf (keys %{$IF}) {
		my $ifDescr = $IF->{$intf}{ifDescr};
		$NCT->{$node}{$ifDescr}{ifDescr} = $IF->{$intf}{ifDescr};
		if  ($Q->{"descr_${intf}"} eq "") {
			delete $NCT->{$node}{$ifDescr}{Description} if exists $NCT->{$node}{$ifDescr}{Description};
		} else {
			$NCT->{$node}{$ifDescr}{Description} = $Q->{"descr_${intf}"};
		}
		if  ($Q->{"speed_${intf}"} eq "") {
			delete $NCT->{$node}{$ifDescr}{ifSpeed} if exists $NCT->{$node}{$ifDescr}{ifSpeed};
		} else {
			$NCT->{$node}{$ifDescr}{ifSpeed} = $Q->{"speed_${intf}"};
		}
		if  ($Q->{"collect_${intf}"} eq 'not' or $Q->{"collect_${intf}"} eq "") {
			delete $NCT->{$node}{$ifDescr}{collect} if exists $NCT->{$node}{$ifDescr}{collect};
		} else {
			$NCT->{$node}{$ifDescr}{collect} = $Q->{"collect_${intf}"};
		}
		if  ($Q->{"event_${intf}"} eq 'not' or $Q->{"event_${intf}"} eq "") {
			delete $NCT->{$node}{$ifDescr}{event} if exists $NCT->{$node}{$ifDescr}{event};
		} else {
			$NCT->{$node}{$ifDescr}{event} = $Q->{"event_${intf}"};
		}
		if  ($Q->{"threshold_${intf}"} eq 'not' or $Q->{"threshold_${intf}"} eq "") {
			delete $NCT->{$node}{$ifDescr}{threshold} if exists $NCT->{$node}{$ifDescr}{threshold};
		} else {
			$NCT->{$node}{$ifDescr}{threshold} = $Q->{"threshold_${intf}"};
		}
		delete $NCT->{$node}{$ifDescr} if scalar keys %{$NCT->{$node}{$ifDescr}} == 1;
	}

	delete $NCT->{$node} if scalar keys %{$NCT->{$node}} == 0;

	$Q->{node} = ''; # done

	# store result config
	writeTable(dir=>'conf',name=>'nodeConf',data=>$NCT);

	# signal from button
	if ($Q->{update} eq 'true') {
		doNodeUpdate(node=>$node);
		return 0;
	}
	return 1;
}

sub doNodeUpdate {
	my %args = @_;
	my $node = $args{node};

	# note that this will force nmis.pl to skip the pingtest as we are a non-root user !!
	# for now - just pipe the output of a debug run, so the user can see what is going on !
	
	# now run the update and display 
	print header($headeropts);
	
	print "<pre>\n";
	print "Running update on node $node - Please wait.....\n\n\n";
	
	open(PIPE, "$C->{'<nmis_bin>'}/nmis.pl type=update node=$node debug=1 2>&1 |"); 
	select((select(PIPE), $| = 1)[0]);			# unbuffer pipe
	select((select(STDOUT), $| = 1)[0]);			# unbuffer pipe

	while ( <PIPE> ) {
		print ;
	}
	close(PIPE);
	print "\n</pre>\n";

	print start_form(-id=>"nmis",
					-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_nodeconf_view");

	print table(Tr(td({class=>'header'},"Completed web user initiated update of $node"),
				td(button(-name=>'button',-onclick=>"get('nmis')",-value=>'Ok'))));
	print end_form;

}
