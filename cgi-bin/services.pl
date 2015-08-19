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
use URI::Escape;

use func;
use NMIS;
use Auth;
use CGI;

my $q = new CGI; # processes all parameters passed via GET and POST
my $Q = $q->Vars; # param values in hash

my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug})
		or die "Cannot read Conf table, conf=$Q->{conf}\n";

my $wantwidget = exists $Q->{widget}? !getbool($Q->{widget}, "invert") : 1;
my $widget = $wantwidget ? "true" : "false";

# Before going any further, check to see if we must handle
# an authentication login or logout request

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);

if ($AU->Require)
{
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},
															username=>$Q->{auth_username},
															password=>$Q->{auth_password},
															headeropts=>$headeropts);
}

# this is readonly, and we base ourselves on the services table first, then node group!
$AU->CheckAccess("table_services_view","header");

# fixme no idea if this is relevant?
# check for remote request, fixme - this never exits!
# if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

# actions: display the overview, or display the per-service-and-node details
if (!$Q->{act} or $Q->{act} eq 'overview')
{
	display_overview();
} 
elsif ($Q->{act} eq 'details' && $Q->{node} && $Q->{service} )
{	
	display_details(service => $Q->{service}, node => $Q->{node});
}
else 
{ 
	print $q->header($headeropts);
	pageStart(title => "NMIS Services", refresh => $Q->{refresh}) if (!$wantwidget);

	print "ERROR: Services module doesn't know how to handle act=".escape($Q->{act});
	pageEnd if (!$wantwidget);
	
	exit 1;
}


# lists all active+visible services as a table
# active: attached to a node, visible: node is within the current user's allowed groups
# args: none, uses globals (C, widget stuff etc)
sub display_overview
{
	my (%args) = @_;

	my $sortcrit = $Q->{sort}=~/^(service|node|status|last_run|status_text)$/? $Q->{sort} : 'service';

	print $q->header($headeropts);
	pageStart(title => "NMIS Services", refresh => $Q->{refresh})
			if (!$wantwidget);

	my $url = $q->url(-absolute=>1)."?conf=$Q->{conf}&act=$Q->{act}&widget=$widget";
	my $homelink = $wantwidget? '' 
			: $q->a({class=>"wht", href=>$C->{'nmis'}."?conf=".$Q->{conf}}, "NMIS $NMIS::VERSION") . "&nbsp;";
	# just append the nodename to complete
	my $nodelink = "$C->{'<cgi_url_base>'}/network.pl?conf=$Q->{conf}&act=network_service_view&refresh=$Q->{refresh}&widget=$widget&server=$Q->{server}&node=";

	print $q->start_table({class=>"table"}),
	"<tr>", $q->th({-class=>"title", -colspan => 5}, $homelink, "Monitored Services Overview"), "</tr>",
								
	"<tr>",
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=service"}, "Service")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=node"}, "Node")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=status"}, "Status")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=last_run"}, "Last Tested")),
	$q->td({-class=>"header"}, $q->a({-class=>"wht", -href=>$url."&sort=status_text"}, "Last Status Text")), 
	"</tr>";
			
	my $LNT = loadLocalNodeTable;
	
	# get all known service statuses, all nodes, all services.
	# service -> node -> data
	my %sstatus = loadServiceStatus;
	my @statuslist;

	for my $sname (keys %sstatus)
	{
		for my $nname (keys %{$sstatus{$sname}})
		{
			# skip if we're not allowed to see this node
			next if (!$AU->InGroup($LNT->{$nname}->{group}));
			push @statuslist, $sstatus{$sname}->{$nname};
		}
	}
	my @sortedlist = sort { $sortcrit =~ /^(last_run|status)$/? 
															($a->{$sortcrit} || 0) <=> ($b->{$sortcrit} || 0)
															: ($a->{$sortcrit} || '') cmp ($b->{$sortcrit} || '') } @statuslist;
	for my $one (@sortedlist)
	{
		
		print "<tr>", $q->td({-class=>'info Plain'}, $one->{service}), 
			$q->td({-class=>'info Plain'}, 
						 $q->a({-href=>$nodelink.$one->{node}, id=>"node_view_".$one->{node} }, $one->{node}));
			
			my $statuscolor = $one->{status} == 100? 'Normal': $one->{status} > 0? 'Warning' : 'Fatal';
			my $statustext = $one->{status} == 100? 'running': $one->{status} > 0? 'degraded' : 'down';
			print $q->td({-class => "info $statuscolor"}, $statustext);

			print $q->td({-class=>'info Plain'}, returnDateStamp($one->{last_run})),
			$q->td({-class=>'info Plain'}, $one->{status_text}? escape($one->{status_text}) : "N/A");
			
			print "</tr>";
	}

	print $q->end_table();
	pageEnd if (!$wantwidget);
}

# some small helpers
# fixme needed?
# neuter html, args: one string
sub escape {
	my $k = shift;
	$k =~ s/&/&amp;/g; $k =~ s/</&lt;/g; $k =~ s/>/&gt;/g;
	return $k;
}

