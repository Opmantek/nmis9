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
use Data::Dumper;

my $q = new CGI; # processes all parameters passed via GET and POST
my $Q = $q->Vars; # param values in hash

my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug})
		or die "Cannot read Conf table, conf=$Q->{conf}\n";

# widget mode: default false if not told otherwise, and true if jquery-called
my $wantwidget = exists $Q->{widget}? getbool($Q->{widget}) : defined($ENV{"HTTP_X_REQUESTED_WITH"});
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


# actions: display the current policy state, or update
if (!$Q->{act} or $Q->{act} eq 'status')
{
	display_policy();
} 
elsif ($Q->{act} eq 'update')
{
	update_policy() && display_policy();
}
else 
{ 
	print $q->header($headeropts);
	pageStart(title => "NMIS Model Policy", refresh => $Q->{refresh}) if (!$wantwidget);

	print "ERROR: Model Policy module doesn't know how to handle act=".escape($Q->{act});
	pageEnd if (!$wantwidget);
	
	exit 1;
}

# lists the contents of the default model policy 
# (i.e. highest numbered policy without filters)
sub display_policy
{
	my (%args) = @_;

	print $q->header($headeropts);
	pageStart(title => "NMIS Model Policy", refresh => $Q->{refresh})
			if (!$wantwidget);

	my $modelpol = loadTable(dir => 'conf', name => 'Model-Policy');

	# find the default policy, ie. highest numbered that doesn't have a filter section
	my ($defaultnr) = sort { $b <=> $a } grep(ref($modelpol->{$_}->{IF}) ne "HASH" || !%{$modelpol->{$_}->{IF}}, keys %$modelpol) if (ref($modelpol) eq "HASH");

	if (ref($modelpol) ne "HASH" or !defined($defaultnr))
	{
		print "Failed to read the model policy!";
		pageEnd if (!$wantwidget);
		return;
	}
	
	my $thedefault = $modelpol->{$defaultnr};

	print qq|<div class="heading">Model Policy Defaults</div>|;
	print qq|<div class="Plain">Select which advanced inventory and performance collections you would like NMIS to collect by default.</div>|;
	print qq|<div class="Fatal">$Q->{error_message}</div>|
			if ($Q->{error_message});
	print qq|<div class="Normal">$Q->{message}</div>|
			if ($Q->{message});

	print 
	$q->start_form(-id => "modelpolicy_form", -href => $q->url(-absolute=>1)."?")
			. $q->hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. $q->hidden(-override => 1, -name => "act", -value => "update")
			. $q->hidden(-override => 1, -name => "widget", -value => $widget)
			. $q->hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
			. qq|<table><tr><th class="header">Option</th><th class="header">Status</th><th class="header">Description</th></tr>|;

	my %display = ref($thedefault->{_display}) eq "HASH"? %{$thedefault->{_display}}:  ();
	
	# sort the stuff: by shared grouping property under _display, within that by name;
	# stuff w/o display key goes last
	my @sortedkeys = sort { my $x = defined($display{$a})? $display{$a}->[0] : 1<<31 ;
													my $y = defined($display{$b})? $display{$b}->[0] : 1<<31 ;
													$x <=> $y or $a cmp $b} (keys %{$thedefault->{systemHealth}});

	for my $selectable (@sortedkeys)
	{
		my $isenabled = getbool($thedefault->{systemHealth}->{$selectable});
		print qq|<tr><td class="infolft Plain">$selectable</td><td class="infolft Plain">|
				.$q->popup_menu(-name => "option_$selectable",
												-values => [qw(true false)],
												-labels => { 'true' => "enabled", 'false' => "disabled" },
												-default => ($isenabled?"true":"false"),
												-override => 1 )
				. qq|</td><td class="infolft Plain">|.($thedefault->{_display} 
																							 && $thedefault->{_display}->{$selectable}? 
																							 $thedefault->{_display}->{$selectable}->[1] : "")
				. qq|</td></tr>|;
	}

	my @submitargs = (-name=>"submitbutton",
										onclick=> ( $wantwidget? "get('modelpolicy_form');" : "submit()" ), 
										-value=> "Save Settings" );
	if (!$AU->CheckAccess("table_models_rw","check"))
	{
		push @submitargs, -class=> "forbidden", -disabled => '', -title => "You are not authorised to update the model policy!";
	}
	else
	{
		push @submitargs, -onclick=> ( $wantwidget? "get('modelpolicy_form');" : "submit()" );
	}

	print qq|</table>|,
	$q->button(@submitargs),
	"&nbsp;",
	# yuck!
	$q->button(-name=>"cancelbutton",
						 onclick => ( $wantwidget? "var id = \$(this).parents('.ui-dialog').attr('id'); \$('div#NMISV8').data('NMISV8'+id).widgetHandle.dialog('close');" : "document.location = '$C->{nmis}?conf=$Q->{conf}';" ),
						 -value=>"Cancel"),
	$q->end_form;
	pageEnd if (!$wantwidget);
}
	
# changes the default model policy
# (i.e. highest numbered policy without filters)
# returns 1 if ok (and sets message), 0 if not (and sets error_message param in that case)
sub update_policy
{
	my (%args) = @_;

	return 1 if (getbool($Q->{cancel})); # shouldn't get here in the cancel case but BSTS
	$AU->CheckAccess("table_models_rw");

	my $modelpol = loadTable(dir => 'conf', name => 'Model-Policy');
	# find the default policy, ie. highest numbered that doesn't have a filter section
	my ($defaultnr) = sort { $b <=> $a } grep(ref($modelpol->{$_}->{IF}) ne "HASH" 
																						|| !%{$modelpol->{$_}->{IF}}, 
																						keys %$modelpol) if (ref($modelpol) eq "HASH");

	if (ref($modelpol) ne "HASH" or !defined($defaultnr))
	{
		$Q->{error_message} = "Failed to read the model policy!";
		return 0;
	}
	my $thedefault = $modelpol->{$defaultnr};
	my $changes;

	# parse all the inputs, only option_X is relevant
	for my $update (keys %$Q)
	{
		next if ($update !~ /^option_(\S+)$/);
		my $propname = $1;
		next if ($Q->{$update} !~ /^(true|false)$/);

		if ($thedefault->{systemHealth}->{$propname} ne $Q->{$update})
		{
			++$changes;
			$thedefault->{systemHealth}->{$propname} = $Q->{$update};
		}
	}
	if ($changes)
	{
		writeTable(dir => 'conf', name => 'Model-Policy', data => $modelpol);
		$Q->{message} = "Successfully saved model policy.";
	}
	else
	{
		$Q->{message} = "Model policy unchanged.";
	}
	return 1;
}
