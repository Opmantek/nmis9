package NMISCGI::ModelPolicy;
our $VERSION = "9.6.5";
use strict;
use URI::Escape;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::Auth;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use Data::Dumper;

our ($q, $Q, $C, $AU, $headeropts, $wantwidget, $widget);

sub runcgi {
	my ($args) = @_;
	($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	$headeropts = $args->{headeropts};

	# widget mode: default false if not told otherwise, and true if jquery-called
	$wantwidget = exists $Q->{widget}? NMISNG::Util::getbool($Q->{widget}) : defined($ENV{"HTTP_X_REQUESTED_WITH"});
	$widget = $wantwidget ? "true" : "false";

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
		Compat::NMIS::pageStart(title => "NMIS Model Policy", refresh => $Q->{refresh}) if (!$wantwidget);

		print "ERROR: Model Policy module doesn't know how to handle act=".escape($Q->{act});
		Compat::NMIS::pageEnd if (!$wantwidget);

		exit 1;
	}

	return;
}

# lists the contents of the default model policy
# (i.e. highest numbered policy without filters)
sub display_policy
{
	my (%args) = @_;

	print $q->header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS Model Policy", refresh => $Q->{refresh})
			if (!$wantwidget);

	my $modelpol = NMISNG::Util::loadTable(dir => 'conf', name => 'Model-Policy');

	# find the default policy, ie. highest numbered that doesn't have a filter section
	my ($defaultnr) = sort { $b <=> $a } grep(ref($modelpol->{$_}->{IF}) ne "HASH" || !%{$modelpol->{$_}->{IF}}, keys %$modelpol) if (ref($modelpol) eq "HASH");

	if (ref($modelpol) ne "HASH" or !defined($defaultnr))
	{
		print "Failed to read the model policy!";
		Compat::NMIS::pageEnd if (!$wantwidget);
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
		my $isenabled = NMISNG::Util::getbool($thedefault->{systemHealth}->{$selectable});
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
						 onclick => ( $wantwidget? "var id = \$(this).parents('.ui-dialog').attr('id'); \$('div#NMISV8').data('NMISV8'+id).widgetHandle.dialog('close');" : "document.location = '$C->{nmis}?';" ),
						 -value=>"Cancel"),
	$q->end_form;
	Compat::NMIS::pageEnd if (!$wantwidget);
}

# changes the default model policy
# (i.e. highest numbered policy without filters)
# returns 1 if ok (and sets message), 0 if not (and sets error_message param in that case)
sub update_policy
{
	my (%args) = @_;

	return 1 if (NMISNG::Util::getbool($Q->{cancel})); # shouldn't get here in the cancel case but BSTS
	$AU->CheckAccess("table_models_rw");

	my $modelpol = NMISNG::Util::loadTable(dir => 'conf', name => 'Model-Policy');
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
		NMISNG::Util::writeTable(dir => 'conf', name => 'Model-Policy', data => $modelpol);
		$Q->{message} = "Successfully saved model policy.";
	}
	else
	{
		$Q->{message} = "Model policy unchanged.";
	}
	return 1;
}

1;
