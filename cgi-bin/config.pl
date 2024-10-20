#!/usr/bin/perl
#
## $Id: config.pl,v 8.11 2012/01/06 07:09:37 keiths Exp $
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
use strict;
our $VERSION = "9.5.1";

use FindBin;
use lib "$FindBin::Bin/../lib";

use URI::Escape;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use Net::IP;

use Compat::NMIS;
use NMISNG::Util;
use NMISNG::Auth;
use HTML::Entities;

use Data::Dumper;

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash

$Q = NMISNG::Util::filter_params($Q) if ($Q->{item} ne "hide_groups");

my $C = NMISNG::Util::loadConfTable(debug=>$Q->{debug});
die "failed to load configuration!\n" if (!$C or ref($C) ne "HASH" or !keys %$C);

# if arguments present, then called from command line
if ( @ARGV ) { $C->{auth_require} = 0; } # bypass auth

# this cgi script defaults to widget mode ON
my $wantwidget = exists $Q->{widget}?
		!NMISNG::Util::getbool($Q->{widget}, "invert") : 1;
my $widget = $wantwidget ? "true" : "false";

# Before going any further, check to see if we must handle
# an authentication login or logout request



my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}
else
{
	# that's the command line/debugger scenario, where we assume a full admin
	$AU->SetUser("nmis");
}


# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_config_view","header");

# check for remote request - fixme9: not supported at this time
exit 1 if (defined($Q->{cluster_id}) && $Q->{cluster_id} ne $C->{cluster_id});

#======================================================================

# select function

# what shall we do

if ($Q->{act} eq 'config_nmis_menu') {			displayConfig();
} elsif ($Q->{act} eq 'config_nmis_add') {		addConfig();
} elsif ($Q->{act} eq 'config_nmis_edit') {		editConfig();
} elsif ($Q->{act} eq 'config_nmis_delete') {	deleteConfig();
} elsif ($Q->{act} eq 'config_nmis_doadd') {	doAddConfig(); displayConfig();

# edit submission action: if it returns 0, we do nothing (assuming it prints complaints)
# if it returns 0 AND sets error_message in Q, then we show the toplevel config AND the error message in a bar
# if it returns 1 we show the toplevel config
} elsif ($Q->{act} eq 'config_nmis_doedit') {
	displayConfig()  if (doEditConfig() or $Q->{error_message});
} elsif ($Q->{act} eq 'config_nmis_dodelete') { doDeleteConfig(); displayConfig();
} else { notfound(); }

exit 1;

sub notfound {
	print header($headeropts);
	$Q = NMISNG::Util::filter_params($Q);
	Compat::NMIS::pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	print "Config: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
	Compat::NMIS::pageEnd if (!$wantwidget);
}

#
# display the Config of NMIS
#
sub displayConfig{
	my %args = @_;

	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) if (!$wantwidget);

	my $CT = Compat::NMIS::loadCfgTable(); # load configuration of table

	my ($CC,undef) = NMISNG::Util::readConfData();

	# start of form
    # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "act", -value => "config_nmis_menu")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table({width=>"400px"}) ; # first table level

	if ($C->{configpeerfiles})
	{
		print Tr(td({class=>'Warning',align=>'center'}, "There are files from the master overriding the configuration"));
	}
	
	if (defined $Q->{error_message} && $Q->{error_message} ne "" )
	{
		print Tr(td({class=>'Fatal',align=>'center'}, "Error: $Q->{error_message}"));
	}

	print Tr(td({class=>'header',align=>'center'},"NMIS Configuration"));

	my @sections = ('',sort keys %{$CC});
	print start_Tr;
	print td({class=>'header', colspan=>'1'},
			"Select section ".
				popup_menu(-name=>'section', -override=>'1',
					-values=>\@sections,
					-default=>$section,
					-onChange=> ($wantwidget? "get('nmisconfig');" : "submit()" )));
	print end_Tr;
	print end_table;

	if ($section ne "") {

		print start_table();
		print typeSect(section=>$section,data=>$CC);
		print end_table;
	}

	print end_form;

End_page:
	print end_table();
	Compat::NMIS::pageEnd if (!$wantwidget);

}

# very minimal escape of inputs that will break the html structure
sub escape {
	my $k = shift;
	$k =~ s/&/&amp;/g;
	$k =~ s/</&lt;/g;
	$k =~ s/>/&gt;/g;

	return $k;
}

sub typeSect {
	my %args= @_;
	my $section = $args{section};
	my $CC = $args{data};
	my @out;

	my $CT = Compat::NMIS::loadCfgTable(); # load configuration of table
	my $ref = url(-absolute=>1);

	# create items list, contains of presets and adds
	my @items = map { keys %{$_} } @{$CT->{$section}};
	my @items_all = @items;
	my @items_cfg = sort keys %{$CC->{$section}};
	for my $i (@items_cfg) { push @items_all,$i unless grep { $_ eq $i } @items; }

	push @out,Tr(td({class=>"header"},$section),td({class=>'info Plain',colspan=>'2'},"&nbsp;"),td({class=>'info Plain'},
			eval {
				if ($AU->CheckAccess("Table_Config_rw","check") and !$C->{configpeerfiles}) {
					return a({ href=>"$ref?act=config_nmis_add&section=$section&widget=$widget"},'add&nbsp;');
				} else { return ""; }
			}
		));
	for my $k (@items_all)
	{
		my $value = $CC->{$section}{$k};
		my $eachRef;
		for my $rf (@{$CT->{$section}}) {
			for my $itm (keys %{$rf}) {
				if ($k eq $itm) {
					$eachRef = $rf->{$k};
				}
			}
		}
		# show arrays as space-sep list
		if (ref($value) eq "ARRAY")
		{
			$value = join(" ", @$value);
		}
		# show commasep as space-sep list
		if ($section eq "system" and $k =~ /^(roletype|nettype|nodetype)_list$/)
		{
			$value =  join(" ", sort split(/\s*,\s*/, $value));
		}
		next if ($section eq "authentication" && $k eq "auth_require"); # fixed true
		next if ($section eq "system" and $k eq "severity_by_roletype"); # not gui-modifyable
		my $showOut = $value;
		$showOut = '**************' if ($eachRef->{display} =~ /password/);

		push @out,Tr(td({class=>"header"},"&nbsp;"),
				td({class=>"header"},escape($k)),td({class=>'info Plain'}, escape($showOut)),
				eval {
					if ($AU->CheckAccess("Table_Config_rw","check") and !$C->{configpeerfiles}) {
						return td({class=>'info Plain'},
							a({ href=>"$ref?act=config_nmis_edit&section=$section&item=$k&widget=$widget"},'edit&nbsp;'),
							eval {
								my $line;
								$line = a({ href=>"$ref?act=config_nmis_delete&section=$section&item=$k&widget=$widget"},
														'delete&nbsp;') unless (grep { $_ eq $k } @items);
								return $line;
							});
					} else { return ""; }
				}
			);
	}

	return @out;
}


sub editConfig {
	my %args = @_;

	my $section = $Q->{section};
	my $item = decode_entities($Q->{item});

	#start of page
	print header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	$AU->CheckAccess("Table_Config_rw");

	my $CT = Compat::NMIS::loadCfgTable(); # load configuration of table

	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);

	my $ref;
	for my $rf (@{$CT->{$section}}) {
		for my $itm (keys %{$rf}) {
			if ($item eq $itm) {
				$ref = $rf->{$item};
			}
		}
	}

	# start of form, see comment for first start_form
	# except that this one also needs the cancel case covered
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "act", -value => "config_nmis_doedit")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
			. hidden(-override => 1, -name => "edittype", -value => '', -id=> "edittype")

			. hidden(-name=>'section', -value => $section, -override=>'1')
			. hidden(-name=>'item', -value => $item, -override=>'1');

	print start_table() ; # first table level

	my $numberofcols = 3;
	my $submitbuttonvalue = "Edit";

	# hiding groups: is array of groups to be hidden in the config, let's show checkboxes
	if ($section eq "system" and $item eq "hide_groups")
	{
		$numberofcols = 2;
		$submitbuttonvalue = "Update";
		print Tr(td({class=>"header",colspan=>'2'},"Edit of NMIS Config")),
		Tr(td({class => "header", colspan => 2 }, "Hide Groups"));

		# figure out the number of members per group for info purposes
		my $LNT = Compat::NMIS::loadLocalNodeTable();
		my %membercounts;
		for my $node (values %$LNT)
		{
			$membercounts{$node->{group}}++;
		}
		for my $group (sort keys %membercounts)
		{
			my $ishidden = List::Util::any { $_ eq $group } @{$CC->{$section}->{$item}};

			print Tr(td({colspan=>"2"},
									checkbox(-name => "hide_groups",
													 -value => $group,
													 -checked => $ishidden,
													 -label => "Hide $group ($membercounts{$group} members)")));
		}
	}
	# edit roleTypes, netType, nodeType: prohibit commas and spaces
	elsif ($section eq "system" and $item =~ /^(roletype|nettype|nodetype)_list$/)
	{
		my $shortname = $1;
		my $friendly = ($shortname eq "roletype"? "Role Type": $shortname eq "nettype"? "Network Type": "Node Type");

		$numberofcols = 2;
		$submitbuttonvalue = "Delete";
		print Tr(td({class=>"header",colspan=>'2'},"Edit of NMIS Config"));

		# an entry for adding a new roletype
		print Tr(td({class => "header", colspan => 2 }, "Add New $friendly")),
		Tr(td({class=>'info Plain', colspan => 2},
					textfield(-name=>"new$shortname", -style=>'font-size:14px;', -title => "${friendly}s cannot contain spaces or commas.")
					.button(-name=>"addbutton",
									onclick=> ('$("#edittype").val("Add"); '. ($wantwidget? "get('nmisconfig');" : "submit()" )),
									-value=>"Add"))),
							Tr(td({class => "header", colspan => 2}, "Existing ${friendly}s"));

		# print the role type rows, one per line plus delete button at the end
		my @actualtypes = sort split(/\s*,\s*/, $CC->{$section}->{$item});
		for my $rtype (@actualtypes)
		{
			my $escapedtype = uri_escape($rtype);
			print Tr(td($rtype),
							 td(checkbox(-name => "delete_${shortname}_$escapedtype", -label => "Delete $friendly", -value => "nuke")) );
		}
	}
	# edit passwords
	elsif ($ref->{display} =~ /password/)
	{
		# the password editing interface
		print Tr(td({class=>"header",colspan=>'3'},"Edit of NMIS Config"));

		print Tr(td({class=>"header"},$section));

		# display edit field; if text, then show it UNescaped;
		my $rawvalue = $CC->{$section}{$item};
		my $value = escape($rawvalue);
		$item = escape($item);

			print Tr(td({class=>'header'},'&nbsp;'),td({class=>'header'},$item),td({class=>'info Plain'},
				password_field(-name=>'value',
                             -value=>$value,
                             -size=>50,
                             -maxlength=>80)));
			print Tr(td({class=>'header'},'&nbsp;'),td({class=>'header'},"Confirm"),td({class=>'info Plain'},
				password_field(-name=>'confirm',
                             -value=>$value,
                             -size=>50,
                             -maxlength=>80)));
	}
	else
	{
		# the generic editing interface
		print Tr(td({class=>"header",colspan=>'3'},"Edit of NMIS Config"));

		print Tr(td({class=>"header"},$section));

		# display edit field; if text, then show it UNescaped;
		my $rawvalue = $CC->{$section}{$item};
		my $value = escape($rawvalue);
		$item = escape($item);

		if ($ref->{display} =~ /popup/) {
			print Tr(td({class=>'header'},'&nbsp;'),td({class=>'header'},$item),td({class=>'info Plain'},
				popup_menu(-name=>"value", -style=>'width:100%;font-size:12px;',
						-values=>$ref->{value},
						-default=>$value)));
		}
		else {
			print Tr(td({class=>'header'},'&nbsp;'),td({class=>'header'},$item),td({class=>'info Plain'},
				textfield(-name=>"value",-size=>((length $rawvalue) * 1.3), -value=>$rawvalue, -style=>'font-size:14px;')));
		}
	}


	print Tr( ($numberofcols == 3? td({colspan=>'2'},'&nbsp;') : ''),
						td(button(-name=>"submitbutton",
											onclick=> ( '$("#edittype").val("'.$submitbuttonvalue.'"); ' . ($wantwidget? "get('nmisconfig');" : "submit()" )),
										 -value=> $submitbuttonvalue)
							 . button(-name=>"cancelbutton",
										 onclick => '$("#cancelinput").val("true");' . ($wantwidget? "get('nmisconfig');" : 'submit();'),
											 -value=>"Cancel")));

		my $info = getHelp($Q->{item});
		print Tr(td({class=>'info Plain',colspan=>$numberofcols},$info)) if $info ne "";


	print end_table();
	print end_form;
	Compat::NMIS::pageEnd if (!$wantwidget);
}

# endpoint for edit operation,
# consumes one section+item = value argument;
# validates where possible and updates
# the configuration if ok
#
# returns 1 if ok, 0 otherwise
sub doEditConfig
{
	my %args = @_;

	return 1 if (NMISNG::Util::getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my $section = $Q->{section};
	my $item = decode_entities($Q->{item});
	my $value = $Q->{value};
	my $confirm = $Q->{confirm};

	# that's the  non-flattened raw hash
	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);
	# that's the set of display and validation rules
	my $configrules = Compat::NMIS::loadCfgTable(table => "Config", user => $AU->{user});

	# Validate section
	if (!$CC->{$section}) {
		return validation_abort($section,
								"non valid '$section'.")
	}
	# Validate item
	if (!$CC->{$section}->{$item}) {
		return validation_abort($item,
								"non valid '$item' in '$section'.")
	}
	
	
	# handle the roletype, nettype and nodetype lists and translate the separate values
	if ($section eq "system" and ( $item =~ /^(roletype|nettype|nodetype)_list$/))
	{
		my $concept = $1;
		my $conceptname = $concept eq "roletype"?
				"Role Type" : $concept eq "nettype"? "Network Type" : "Node Type"; # uggly
		my @existing = split(/\s*,\s*/, $CC->{$section}->{$item});

		my $newthing = $Q->{"new$concept"};
		# add actions ONLY if the add button was used to submit
		if ($Q->{edittype} eq "Add" and defined $newthing and $newthing ne '')
		{
			# Validate
			my $not_allowed_chars_props = $C->{not_allowed_chars_props} // "[;=()<>%'\/]";
		
			return validation_abort($conceptname, "'$newthing' contains invalid characters. Spaces and commas are prohibited.")
					if ($newthing =~ /$not_allowed_chars_props/);

			push @existing, $newthing
					if (!grep($_ eq $newthing, @existing));
		}

		# delete actions ONLY if the delete button was used to submit
		if ($Q->{edittype} eq "Delete")
		{
			for my $deletable (grep(/^delete_${concept}_/, keys %$Q))
			{
				next if $Q->{$deletable} ne "nuke";
				my $deletablename = $deletable;
				$deletablename =~ s/^delete_${concept}_//;
				my $unesc = uri_unescape($deletablename);

				@existing = grep($_ ne $unesc, @existing);
			}
		}
		$value = join(",", sort @existing);
	}
	# hide_groups: is an array, multiple checkboxes convey desired state
	if ($section eq "system" and $item eq "hide_groups")
	{
		# ...but deselected ones produce empty strings
		$value = [ grep(!/^\s*$/, $q->multi_param($item)) ];
	}
	# regex: Checking this particular value
	return validation_abort($item, "'$value' should not use qr/ /!")
						if ($value =~ /qr\/.*\//);

	my $thisrule = Compat::NMIS::findCfgEntry(section => $section, item => $item, table => $configrules);

	if (ref($thisrule) eq "HASH" && ref($thisrule->{validate}) eq "HASH")
	{
		# supported validation mechanisms:
		# "int" => [ min, max ], undef can be used for no min/max - rejects X < min or > max
		# "float" => [ min, max, above, below ] - rejects X < min or X <= above, X > max or X >= below
		#   that's required to express 'positive float' === strictly above zero: [0 or undef,dontcare,0,dontcare]
		# "resolvable" => [ 4 or 6 or 4, 6] - accepts ip of that type or hostname that resolves to that ip type
		# "int-or-empty", "float-or-empty", "resolvable-or-empty" work like their namesakes,
		# but accept nothing/blank/undef as well.
		# "regex" => qr//,
		# "ip" => [ 4 or 6 or 4, 6],
		# "onefromlist" => [ list of accepted values ] or undef - if undef, 'value' list is used
		#   accepts exactly one value
		# "multifromlist" => [ list of accepted values ] or undef, like fromlist but more than one
		#   accepts any number of values from the list, including none whatsoever!
		# more than one rule possible but likely not very useful
		for my $valtype (sort keys %{$thisrule->{validate}})
		{
			my $valprops = $thisrule->{validate}->{$valtype};

			if ($valtype =~ /^(int|float)(-or-empty)?$/)
			{
				my ($actualtype, $emptyisok) = ($1,$2);

				# checks required if not both emptyisok and blank input
				if (!$emptyisok or (defined($value) and $value ne ""))
				{
					return validation_abort($item, "'$value' is not an integer!")
							if ($actualtype eq "int" and int($value) ne $value);

					return validation_abort($item, "'$value' is not a floating point number!")
							# integer or full ieee floating point with optional exponent notation
							if ($actualtype eq "float"
									and $value !~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/);

					my ($min,$max,$above,$below) = (ref($valprops) eq "ARRAY"? @{$valprops}
																					: (undef,undef,undef,undef));
					return validation_abort($item, "$value below minimum $min!")
							if (defined($min) and $value < $min);
					return validation_abort($item,"$value above maximum $max!")
							if (defined($max) and $value > $max);

					# integers don't subdivide infinitely precisely so above and below not needed
					if ($actualtype eq "float")
					{
						return validation_abort($item, "$value is not above $above!")
								if (defined($above) and $value <= $above);

						return validation_abort($item, "$value is not below $below!")
								if (defined($below) and $value >= $below);
					}
				}
			}
			elsif ($valtype eq "regex")
			{
				my $expected = ref($valprops) eq "Regexp"? $valprops : qr//; # fallback will match anything
				return validation_abort($item, "'$value' didn't match regular expression \"$expected\"!")
						if ($value !~ $expected);
			}
			elsif ($valtype eq "ip")
			{
				my @ipversions = ref($valprops) eq "ARRAY"? @$valprops : (4,6);

				my $ipobj = Net::IP->new($value);
				return validation_abort($item, "'$value' is not a valid IP address!")
						if (!$ipobj);

				return validation_abort($item, "'$value' is IP address of the wrong type!")
						if (($ipobj->version == 6 and !grep($_ == 6, @ipversions))
								or $ipobj->version == 4 and !grep($_ == 4, @ipversions));
			}
			elsif ($valtype =~ /^resolvable(-or-empty)?$/)
			{
				my $emptyisok = $1;

				if (!$emptyisok or (defined($value) and $value ne ""))
				{
					return validation_abort($item, "'$value' is not a resolvable name or IP address!")
							if (!$value);

					my @ipversions = ref($valprops) eq "ARRAY"? @$valprops : (4,6);

					my $alreadyip = Net::IP->new($value);
					if ($alreadyip)
					{
						return validation_abort($item, "'$value' is IP address of the wrong type!")
								if (!grep($_ == $alreadyip->version, @ipversions));
						# otherwise, we're happy...
					}
					else
					{
						my @addresses = NMISNG::Util::resolve_dns_name($value);
						return validation_abort($item, "DNS failed to resolve '$value'!")
								if (!@addresses);

						my @addr_objs = map { Net::IP->new($_) } (@addresses);
						my $goodones;
						for my $type (4,6)
						{
							$goodones += grep($_->version == $type, @addr_objs) if (grep($_ == $type, @ipversions));
						}
						return validation_abort($item,
																		"'$value' does not resolve to an IP address of the right type!")
								if (!$goodones);
					}
				}
			}
			elsif ($valtype eq "onefromlist" or $valtype eq "multifromlist")
			{
				# either explicit list of acceptables, or the 'value' config item
				my @acceptable = ref($valprops) eq "ARRAY"? @$valprops :
						ref($thisrule->{value}) eq "ARRAY"? @{$thisrule->{value}}: ();
				return validation_abort($item, "no validation choices configured!")
						if (!@acceptable);

				# for multifromlist assume that value is now comma-separated. *sigh*
				# for onefromlist values with colon are utterly unspecial *double sigh*
				my @mustcheckthese = ($valtype eq "multifromlist")? split(/,/, $value) : $value;
				for my $oneofmany (@mustcheckthese)
				{
					return validation_abort($item, "'$oneofmany' is not in list of acceptable values!")
							if (!List::Util::any { $oneofmany eq $_ } (@acceptable));
				}
			}
			else
			{
				return validation_abort($item, "unknown validation type \"$valtype\"");
			}
		}
	}
	if (($section eq "database" and $item eq "db_password") or ($section eq "email" and $item eq "mail_password")) {
		return validation_abort($item, "passwords don't match") if ($value ne $confirm);
		$value = NMISNG::Util::encrypt($value) if ((defined($value)) && ($value ne "") &&  (substr($value, 0, 2) ne "!!"));
		return validation_abort($item, "passwords update failure") if ($value eq '');
	}
	# no validation or success, so let's update the config
	$CC->{$section}{$item} = ref($value) eq "ARRAY" ? $value : decode_entities($value);
	NMISNG::Util::writeConfData(data=>$CC);
	return 1;
}

# setup (negative) response in $Q's error attribute
# args: item, message
# returns: undef
sub validation_abort
{
	my ($item, $message) = @_;

	$Q->{error_message} = "'$item' failed to validate: $message";
	return undef;
}



# shows the deletion yes/no dialog
sub deleteConfig {
	my %args = @_;

	my $section = $Q->{section};
	my $item = decode_entities($Q->{item});

	#start of page
	print header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	$AU->CheckAccess("Table_Config_rw");

	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);

	my $value = $CC->{$section}{$item};

	# start of form, see comment for first two start_forms
	print start_form( -name=>"nmisconfig", -id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "act", -value => "config_nmis_dodelete")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput");

	# background values
	print hidden(-name=>'section', -default => $section,-override=>'1');
	print hidden(-name=>'item', -default => $item,-override=>'1');


	print start_table() ; # first table level

	# display edit field
	my @hash = split /,/,$Q->{hash};
	print Tr(td({class=>"header",colspan=>'3'},b("Delete this item of NMIS Config")));
	print Tr(td({class=>"header"},$section));

	print Tr(td({class=>'header'},'&nbsp;'),td({class=>'header'},escape($item)),
			td({class=>'info Plain'},escape($value)));

	print Tr(td({colspan=>'2'}), td(
						 button(-name=>'button',
										onclick=> ($wantwidget? "get('nmisconfig');" : "submit()" ),
										-value=>'DELETE'),b('Are you sure ?'),
						button(-name=>'button',
									 onclick=> '$("#cancelinput").val("true");' . ($wantwidget? "get('nmisconfig');" : 'submit();'),
									 -value=>'Cancel')));

	print end_form, end_table;
	Compat::NMIS::pageEnd if (!$wantwidget);
}

# deletes one config entry (identified by section and item),
# if allowed to: rejects deletion of items that are subject to validation rules
# returns: 1 if ok, undef if not; sets Q's error attribute in that case
sub doDeleteConfig {
	my %args = @_;

	return if (NMISNG::Util::getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my $section = $Q->{section};
	my $item = decode_entities($Q->{item});

	# that's the  non-flattened raw hash
	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);
	# that's the set of display and validation rules
	my $configrules = Compat::NMIS::loadCfgTable(table => "Config", user => $AU->{user});

	# check if that thing is under validation; if so, reject deletion
	# possible future improvement: check if validation rule allows empty value
	my $thisrule = Compat::NMIS::findCfgEntry(section => $section, item => $item, table => $configrules);
	if (ref($thisrule) eq "HASH" && ref($thisrule->{validate}) eq "HASH")
	{
		$Q->{error_message} = "'$item' cannot be deleted: required by validation rule!";
		return undef;
	}

	delete $CC->{$section}{$item};
	NMISNG::Util::writeConfData(data=>$CC);
	return 1;
}

sub addConfig{
	my %args = @_;

	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);

	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) if (!$wantwidget);

	$AU->CheckAccess("Table_Config_rw");

	# start of form, see comment for first two start_forms
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "act", -value => "config_nmis_doadd")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput");

	print start_table() ; # first table level

	# display edit field
	print Tr(td({class=>"header"},$section));
	print Tr(td({class=>"header"},"&nbsp;"),td({class=>"header"},'id'),
				td({class=>'info Plain'},textfield(-name=>"id",size=>'50')));
	print Tr(td({class=>"header"},"&nbsp;"),td({class=>"header"},'value'),
				td({class=>'info Plain'},textfield(-name=>"value",size=>'50')));

	print Tr(td({colspan=>"2"}), td(button(-name=>"button",
																				 onclick=> ($wantwidget? "get('nmisconfig');" : "submit()" ),
																				 -value=>"Add"),
																	button(-name=>"button",
																				 onclick=> '$("#cancelinput").val("true");'
																				 . ($wantwidget? "get('nmisconfig');" : 'submit();'),
																				 -value=>"Cancel")));

	my $info = getHelp('id');
	print Tr(td({class=>'info Plain',colspan=>'3'},$info)) if $info ne "";

	# background values
	print hidden(-name=>'section', -default=>$section,-override=>'1');
	print end_form;

	print end_table();
	Compat::NMIS::pageEnd if (!$wantwidget);

}


sub doAddConfig {
	my %args = @_;

	return if (NMISNG::Util::getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my ($CC,undef) = NMISNG::Util::readConfData(only_local => 1);

	my $section = $Q->{section};
	
	# Validate section
	if (!$CC->{$section}) {
		return validation_abort($section,
								"non valid '$section'.")
	}
	
	if ($Q->{id} ne '') {
		$CC->{$section}{decode_entities($Q->{id})} = decode_entities($Q->{value});
	}

	NMISNG::Util::writeConfData(data=>$CC);
}



#============================================================================

sub getHelp {
	my $help = shift;

	my %help = (
		'id' => 			'Format: string<br>this name must be unique over all sections.',
# authorization
		'auth_method' => 	'Format: string<br>set this to choose authentication method<br>'.
								'htpasswd for apache password file<br>radius for radius server validation<br>'.
								'tacacs for tacacs server validation',
		'auth_encrypt' => 	'Format: string<br>htpasswd encryption method: either crypt or md5 (default= nothing)',
		'auth_keyfile' => 	'Format: string<br>this is where the shared secret file is stored',
		'auth_radius_server' => 'Format: string<br>radius server address:port in either hostname:port or ipaddress:port<br>'.
								'port is optional, default is 1645<br>'.
								'library Authen::Simple::RADIUS must be installed from CPAN',
		'auth_radius_secret' => 'Format: string<br>radius secret',
		'auth_tacacs_server' => 'Format: string<br>tacacs server address:port in either hostname:port or ipaddress:port<br>'.
								'port is optional, default is 49<br>'.
								'library Authen::TacacsPlus must be installed from CPAN',
		'auth_tacacs_secret' => 'Format: string<br>radius secret',
		'auth_user_file' => 	'Format: string<br>Apache Authentication User File, for htpasswd authentication',
		'auth_expire' => 	'Format: string<br>authorization cookie lifespan<br>in the form {number-of-units time-unit} (e.g. "+6min")<br>'.
								'there is default of +10min',
		'auth_bind' => 		'Format: string<br>LDAP & PAM autentication bind parameters<br>port is optional, default is none',
# directories
		'<cgi_url_base>' => 'Format: string<br>these are relevant to the DocumentRoot in Apache or should <br>'.
								'match the Alias and ScriptAlias you setup for NMIS',
		'<url_base>' => 	'Format: string<br>these are relevant to the DocumentRoot in Apache or should<br>'.
								'match the Alias and ScriptAlias you setup for NMIS',
# email
		'mail_server' =>	'Format: string<br>address of email server to send email',
		'mail_from' => 		'Format: string<br>source address of email',
		'mail_combine' => 	'Format: true|false<br>combine messages for the same target in a single email',
# graph
		'graph_amount' =>	'Format: number<br>default period of graph in graph_unit',
		'graph_unit' =>		'Format: years | months | days | hours | minutes<br>unit of period',
		'graph_factor' =>	'Format: number<br>factor is how much to zoom in and out and left and right',
		'graph_width' =>	'Format: number<br>width of graph in px',
		'graph_height' =>	'Format: number<br>heigth of graph in px',
		'graph_split' =>	'Format: true | false<br>graph split in and out utilisation/bits around y axis<br>'.
								'input bits (-) on bottom, output (+) on top',
		'win_width' =>		'Format: number<br>width of popup window in px',
		'win_height' =>		'Format: number<br>height of popup window in px',
# mibs
		'full_mib' =>		'Format: string<br>comma separated names of loaded OID files',
# system
		'nmis_host' => 		'Format: string<br>Host Pointer for emails sent out, port number is optional.',
		'username' => 		'Format: string<br>set this to your nmis user id - we will create files to this userid and groupid<br>'.
								'and some file permissions as well (default: nmis, 0775)',
		'fileperm' => 		'Format: string<br>set this to your nmis user id - we will create files to this userid and groupid<br>'.
								'and some file permissions as well (default: nmis, 0775)',
		'os_kernelname' => 	'Format: string<br>set kernel name if NMIS can\'t detect the real name',
# fixme: does the new list still need help text?
#		'group_list' => 	'Format: string<br>Comma separated list of groups, without spaces',
		'view_mtr' => 		'Format: true | false<br>set if your system supports them and you wish to use them',
		'view_lft' => 		'Format: true | false<br>set if your system supports them and you wish to use them',
		'page_refresh_time'=>'Format: number, range 30 - 300<br>'.
								'interval time of page refresh',
		'posix' => 			'Format: true | false<br> set this true if RedHat9 and multithread<br>'.
								'enables POSIX compliant signal handling for reaping child processes',
		'cmd_read_file_reverse' => 'Format string<br>system command for reading file reverse, default is tac',
		'report_files_max'	=>	'Format: number, up from 10<br>max report files per type of report',
		'cache_var_tables' => 	'Format: true | false<br>set if you wish to cache tables in directory /var to save loading time',
		'cache_summary_tables' => 	'Format: true | false<br>set if you wish to cache nmis summary stats to save recalc time',
# menu
		'menu_types_active' => 	'Format: true | false<br>set if you wish to load this type of Menu',
		'menu_types_full' => 	'Format: true | false | defer<br>if you wish to load the full Menu at once (true)<br>'.
									'or if you select a field with red arrow (false) or loaded in background (defer)',
		'menu_types_foldout' =>	'Format: true | false<br>set if you wish to foldout the Menu at startup',
		'menu_groups_active' =>	'Format: true | false<br>set if you wish to load this type of Menu',
		'menu_groups_full' => 	'Format: true | false | defer<br>if you wish to load the full Menu at once (true)<br>'.
									'or if you select a field with red arrow (false) or loaded in background (defer)',
		'menu_groups_foldout' =>'Format: true | false<br>set if you wish to foldout the Menu at startup',
		'menu_vendors_active' =>'Format: true | false<br>set if you wish to load this type of Menu',
		'menu_vendors_full' => 	'Format: true | false | defer<br>if you wish to load the full Menu at once (true)<br>'.
									'or if you select a field with red arrow (false) or loaded in background (defer)',
		'menu_vendors_foldout'=>'Format: true | false<br>set if you wish to foldout the Menu at startup',
		'menu_maxitems' =>		'Format: number<br>max. number of items to scroll',
		'menu_suspend_link' =>	'Format: true | false<br>set if you wish to suspend the link info on the statusbar',
		'menu_title' =>			'Format: string<br>will be displayed in the horizontal Menu bar',
		'menu_start_page_id'=>	'Format: string<br>id of start page<br>id is defined in menu.pl',

	);

	if (exists $help{$help}) {
		return ul(li($help),$help{$help});
	}
	return;
}
