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
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use NMIS;
use func;
use csv;
use Fcntl qw(:DEFAULT :flock);
use Sys;
use Mib;
use Auth;
use Data::Dumper;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI;
my $Q = $q->Vars;

my $wantwidget = (!getbool($Q->{widget},"invert")); # default is thus 1=widgetted.
$Q->{widget} = $wantwidget? "true":"false"; # and set it back to prime urls and inputs
my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});

if (!$C)
{
	print header(-status => 500);
	pageStart(title => "NMIS Modeling") if (!$wantwidget);
	print "<div>Error: Failed to load config file!</div>";
	pageEnd if (!$wantwidget);
	exit 1;
}

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require)
{
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
															password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_models_view","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

# this table defines the actions add,delete,edit based on location paths
# this needs to be rewritten to use dotnotation, or arrays are not supportable except at the leaf end
my %MT = (
	# fixme need to update list of hidables
	'ablank' => [ # nothing allowed, don't even show them
	],
	'add' => [
		'^\w+$',
		'^calls,rrd,\w+$',
		'^calls,rrd,\w+,snmp$',
		'^cbqosin,rrd,cbqos$',
		'^cbqosout,rrd,cbqos$',
		'^cbqosin,rrd,cbqos,snmp$',
		'^cbqosout,rrd,cbqos,snmp$',
		'^database,type$',
		'^database,db,size$',
		'^event,event$',
		'^heading,graphtype$',
		'^interface,rrd$',
		'^\w+,(rrd|sys)$',
		'^\w+,sys,standard$',
		'^\w+,(rrd|sys),\w+,snmp$',
		'^interface,rrd,interface$',
		'^models$',
		'^system,power,\w+,snmp$',
		'^stats,type$',
		'^summary,statstype$',
		'^summary,statstype,\w+,sumname$',
		'^summary,statstype,\w+,sumname,\w+,stsname$',
		'^threshold,name$',
		'^threshold,name,\w+,select$',
		'^-common-,class$'
	],
	'delete' => [
		'^database,db,size,\w+$',
		'^models,\w+,order,(\d+|\w+)$',
		'^summary,statstype,\w+$',
		'^summary,statstype,\w+,sumname,\w+$',
		'^threshold,name,\w+$',
		'^threshold,name,\w+,select,\w+,value$',
		'^-common-,class,\w+$',
		'^alerts,\w+$',
		'^alerts,\w+,\w+$',
	],
	'add,delete' => [
		'^calls,rrd,\w+,snmp,\w+$',
		'^event,event,\w+$',
		'^\w+,(rrd|sys|power),\w+$',
		'^\w+,(rrd|sys|power),\w+,snmp,\w+$',
		'^\w+,(rrd|sys|power),\w+,snmp,\w+,replace$',
		'^threshold,name,\w+,select,\w+$',
		'^stats,type,\w+$',
		'^models,\w+$'
	],
	'edit,delete' => [
		'database,type,\w+$',
		'^\w+,(rrd|sys),\w+,(indexed|threshold|control)$',
		'^\w+,(rrd|sys),\w+,snmp,\w+,(option|title|check|format|calculate)$',
		'^heading,graphtype,\w+$',
		'^\w+,(rrd|sys|power),\w+,snmp,\w+,replace,\w+$'
	],
	'edit,add,delete' => [
		'^stats,type,\w+,\d+$',
		'^summary,statstype,\w+,sumname,\w+,stsname,\d+$'
	],
		);

# fixme: as-is the helptext system is NOT context-sensitive, so highly misleading
# because item 'type' has different meanings in different places.
my %helptexts = (
	'type' => 	qq|Format: string<br>
The name must be unique in this section<br>
This name creates a relation between configurations in the next sections:<br>
Starting in a section (node, interface, calls, cbqos_in or cbqos_out) for RRD declaration,
it must also be declared in section database for generating the RRD database filename. If there
is a threshold in this section then there must also be rrd rules in section stats.|,

	'graphtype' => qq|Format: comma separated list<br>
List of graph names. For each graph type there must be a graph definition file
models/Graph-&lt;graphtype&gt;.nmis.|,

	'control' =>		qq|Format: expression<br>The control expression will be evaluated
when the respective section is consulted.|,

	'indexed' =>	'Format: SNMP/WMI variable name (or true)<br>Declares that this subsection
is indexed by the value of the given variable.',

	'oid' => 'Format: SNMP oid, must contain a known name or a numeric OID.<br>',

	'replace' =>	'Format: lookup table of known values and their replacement<br>
Optional. The result of the collection can be replaced by a given value from this lookup table.<br>
If the value is not known, "unknown" is tried. If no replacement can be found, then the original value is left.',

	'value' =>			'Format: expression<br>
	The result of evaluated  expression replaces the originally collected value.',

	'option' =>	'Format: string<br>Declares the data type for this RRD Data Source,
or prevents the variable from being saved if set to "nosave"<br>If not defined, the default is \'GAUGE,U:U\'.',

	'threshold' =>		'Format: comma separated list of names<br>
	Optional. Threshold names must be declared in the stats section.',

	'level' =>	'Severity level<br>Format: Fatal, Critical, Major, Minor, Warning or Normal (in descending order)',

	'logging' =>		'Format: true or false<br>Whether an event should be logged or not.',

	'event' =>			'Format: string<br>Name of event',

	'order' =>			'Format: number<br>Order of processing, which always proceeds from lowest to highest number.',

	'statstype' =>		'Format: string<br>Name for this type in the stats section.',

	'sumname' =>		'Format: string<br>Name of parameter in summary file.',

	'stsname' =>		'Format: string<br>Name of parameter (...:stsname=...) in rrd rules in stats section.',

	'calculate' =>		'Format: expression<br>Optional. The result of the evaluated expression replaces
the originally collected value.',

	'format' =>			'Format: string<br>Optional. Printf format string for rewriting the collected value.',

	'title' =>			'Format: string<br>Used as label for displaying this variable.',
		);

# showing stuff in the gui
if (!$Q->{act} or $Q->{act} eq 'config_model_menu') {	displayModel(); }
elsif ($Q->{act} eq 'config_model_add') {	addModel(); }
elsif ($Q->{act} eq 'config_model_edit') {	editModel(); }
elsif ($Q->{act} eq 'config_model_delete') {	deleteModel(); }
# performing actual changes
elsif ($Q->{act} eq 'config_model_doadd') {	doAddModel(); displayModel(); }
elsif ($Q->{act} eq 'config_model_doedit') { doEditModel(); displayModel(); }
elsif ($Q->{act} eq 'config_model_dodelete') { doDeleteModel(); displayModel(); }
else
{
	print header(-status => 400, %$headeropts);
	print "Invalid Arguments!";
}
exit 0;

# small die-like helper, works only AFTER headers were sent
sub bailout
{
	my (@msgs) = @_;
	print "<p>".join("<br/>", @msgs)."</p>";
	pageEnd if ($wantwidget);
	exit 0;
}

# displays the currently selected model's status,
# plus a dropdown list for selection/navigation
# args: none, but uses q for model and section
sub displayModel
{
	my $wantedmodel = $Q->{model};
	my $wantedsection = $Q->{section};

	print header($headeropts);
	pageStart(title => "NMIS Model Editor", refresh => 86400) if (!$wantwidget);

	# a modelish thing requested? then try to load it
	my $modelstruct;
	if ($wantedmodel)
	{
		my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
		$modelstruct = readFiletoHash(file => $modelfn);
		bailout "cannot read model $modelfn: $!"
				if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);
	}

	# find out what model-ish things exist - do NOT use sys, because that resolves inclusions irreversibly!
	opendir(D, $C->{'<nmis_models>'}) or bailout("cannot read model dir: $!\n");
	my @modelish = sort { lc($a) cmp lc($b) } map { s/\.nmis$//i; $_; } (grep(/^(Common|Model)(-.+)?\.nmis$/i, readdir(D)));
	closedir(D);


	# the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisModels", -href => url(-absolute => 1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_menu")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget}),
			# the menu-ish table part
			start_table(),
			"<tr>", td({class=>'header'},
								 "Select Model<br>".
								 popup_menu(-name=>'model', -override=>'1',
														-values=>\@modelish,
														-default => $wantedmodel,
														-onChange => ($wantwidget? "get('nmisModels');" : "submit()" )));

	my @sections = ('');
	push @sections, sort keys %{$modelstruct} if ($modelstruct);

	print td( {class=>'header'},
						"Select Section<br>".
						popup_menu(-name=>'section', -override=>'1',
											 -values=>\@sections,
											 default => $wantedsection,
											 -onChange => ($wantwidget? "get('nmisModels');" : "submit()")),
			);

	print "</tr>", Tr(td({class=>'header',colspan=>'3'},"Displaying Model $wantedmodel"
											 .($wantedsection? ", Section $wantedsection":""))),
			"</table>";

	if ($wantedsection)
	{
		my @output;

		print start_table();

		nextSect(id => $wantedsection,
						 sect => $modelstruct->{$wantedsection},
						 index=>0,
						 output=>\@output,
						 hash=>$wantedsection);

		print @output, end_table;
	}

	print "</form></table>";
	pageEnd() if (!$wantwidget);
}

# produce html output for one section in a modelish hash structure
# args: sect (=the structure), id (text for labelling),
# output (arrayref where output is accumulated),
# hash: commasep location steps for allowed command determination,
# index: misnamed, should be 'depth' - nesting level for the table column offset
# returns: the output argument (unnecessarily as it is updated on the go)
sub nextSect
{
	my %args = @_;

	my $sect = $args{sect};
	my $id = $args{id};

	my $index = $args{index};
	my $output = $args{output};
	my $hash = $args{hash};

	# s section subname
	foreach my $s (sort keys %{$sect})
	{
		if (ref $sect->{$s} eq 'HASH')
		{
			my $txt = $s;							# the label for this thing, slightly location dependent

			if ($hash =~ /^\w+,\w+,\w+,(wmi|snmp)$/) { $txt = "Attribute=$s"; }
			elsif ($hash =~ /^\w+,rrd,\w+,(wmi|snmp)$/) { $txt = "DS=$s"; }
			elsif ($s =~ /^(snmp|wmi)$/ and $index != 0) { $txt = "Protocol=$s"; }
			elsif ($id =~ /^(sys|rrd)$/) { $txt = "Section=$s"; }

			push @$output, ( "<tr>",
											 td({class=>"header",colspan=>'1'}, $id) );
			# offset/shim
			push @$output, td({class=>"header",colspan=>$index}) if ($index != 0);

			push @$output, ( td({class=>"header",colspan=>'1'},$txt),
											 # more shim
											 td({class=>"info",colspan=>(8-$index)}),
											 afunc(hash=>"$hash,$s", ref => $sect->{$s}),
											 "</tr>" );

			nextSect(sect=>$sect->{$s}, id=>$s, index=>($index+1), output=>$output, hash=>"$hash,$s");
		}
		elsif (ref $sect->{$s} eq 'ARRAY') # only allowed just before leaf
		{
			push @$output, ( "<tr>",
											 td({class=>"header",colspan=>'1'}, $id) );
			push @$output, td({class=>"header",colspan=>($index)}) if $index != 0;

			push @$output, ( td({class=>"header",colspan=>'1'}, $s),
											 # more shim
											 td({class=>"info",colspan=>(8-$index)}),
											 afunc(hash=>"$hash,$s", ref => $sect->{$s}),
											 "</tr>" );

			for my $cnt (0..$#{$sect->{$s}})
			{
				my $txt  = $sect->{$s}->[$cnt];

				push @$output, ( "<tr>",
												 td({class=>"header",colspan=>'1'},$id) );
				push @$output, td({class=>"header",colspan=>($index+1)}) if $index != 0;

				push @$output, ( td({class=>'info',colspan=>(8-$index)},$txt),
												 afunc(hash=>"$hash,$s,$cnt"),
												 "</tr>" );
			}
		}
		else												# leaf
		{
			my $txt = $s;

			if ($s eq 'indexed') { $txt = "Section Indexed By"; } # modify label
			elsif ($s eq 'option') { $txt = "RRD $s"; }
			elsif ($s eq 'oid') { $txt = "SNMP $s"; }
			elsif ($s eq 'field') { $txt = "WMI $s"; }
			elsif ($s =~ /^common-/) { $txt = "Include Common-"; }


			push @$output, ( "<tr>",
											 td({class=>"header",colspan=>'1'},$id) );
			# shim
			push @$output, td({class=>"header",colspan=>($index)}) if $index != 0;


			push @$output, ( td({class=>"header",colspan=>'1',width=>"12%"}, $txt),
											 td({class=>"info", colspan=>(8-$index)},
													(!defined $sect->{$s} or $sect->{$s} eq ''? "<em>blank</em>": $sect->{$s} )),
											 afunc(hash=>"$hash,$s"),
											 "</tr>" );
		}
	}
	return $output;
}

# produces html for the supported actions
# which action? (add,edit,delete,snmp)
# args: hash (=commasep list of location steps, used for $MT),
# ref (optional, references the actual thing in question)
# returns: html
sub afunc
{
	my %args = @_;
	my $hash = $args{hash};
	my $ref = $args{ref};

	my $allowedhere = checkHash($hash);
	# deep structure? edit is NOT possible, but add+delete (generally!) are
	# note that this heuristic isn't perfect; spots that don't offer add should be explicitely listed in %MT
	$allowedhere = "add,delete" if (exists $args{ref} && ref($ref) && $allowedhere =~ /edit/);

	my $baseurl = url(-absolute=>1) . "?conf=$Q->{conf}&model=$Q->{model}&section=$Q->{section}&hash=$hash&widget=$Q->{widget}";

	return td({class=>'info'}) if (!$AU->CheckAccess("Table_Models_rw","check")
																 or $allowedhere eq "ablank");

	my $line;
	for my $action (split /,/, $allowedhere)
	{
		$line .= a({style=>'text-decoration: underline;',
								href=> $baseurl . "&act=config_model_$action"},"$action&nbsp;");
	}
	return td({class=>'info', nowrap=>undef}, $line);
}

# look up function names of allowed ops
# (ablank/edit/add/add,delete/edit,delete/edit,add,delete)
# based on the location steps 'hash'
# args: hash (commasep steps),
# returns: actionname
sub checkHash
{
	my $hash = shift;

	foreach my $func (sort keys %MT)
	{
		for my $allowedinloc (@{$MT{$func}})
		{
			return $func if ($hash =~ /$allowedinloc/ );
		}
	}
	return 'edit'; # default allowed action is edit
}


# show the appropriate model editing form for a given model+section+locationsteps
# none, but uses q's model, section, hash
sub editModel
{
	my %args = @_;

	my $wantedmodel = $Q->{model};
	my $wantedsection = $Q->{section};
	my $locsteps = $Q->{hash};

	print header($headeropts);
	pageStart(title => "NMIS Edit Model", refresh => 86400) if (!$wantwidget);
	$AU->CheckAccess("Table_Models_rw");

	bailout("Missing model argument!") if (!$wantedmodel);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels",
									 -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_doedit")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-override => 1, -name => "cancel", -value => "", -id => "cancel")
			. hidden(-name=>'model', -default=>$wantedmodel, -override=>'1')
			. hidden(-name=>'section', -default=>$wantedsection, -override=>'1')
			. hidden(-name=>'hash', -default=>$locsteps, -override=>'1');

	print "<table>", Tr(td({class=>"header",colspan=>'8',align=>'center'},
												 "Editing Model $wantedmodel"));

	my $field = $modelstruct;
	my @locationsteps = split(/,/, $locsteps);
	# print header, and traverse the structure
	for my $level (0..$#locationsteps)
	{
		print "<tr>";
		# shim
		print td({class=>"header",colspan=>$level}) if $level != 0;
		print td({class=>"header",colspan=>'1'}, $locationsteps[$level]),
		td({class=>"info",colspan=>(8-$level)}), "</tr>";

		$field = $field->{$locationsteps[$level]};
		last if (ref($field) eq 'ARRAY'); # fixme: no support for array anywhere EXCEPT at the leaf end!
	}
	my $value = (ref($field) eq 'ARRAY')? $field->[$locationsteps[-1]] : $field;

	my $offset = @locationsteps;
	print Tr(td({colspan => $offset}),
					 td({colspan=>(8-$offset)},
							textfield(-name=>"value",align=>"left",override=>1,size=>((length $value) * 1.5),value=>$value)));

	# for some unknown reason the cancel doesn't work if both get() sets a cancel parameter in the url
	# and if there is a cancel input field at the same time; fix for now: enforce the input field,
	# and not let get() make a mess.
	print Tr(td({colspan=> $offset}),
					 td(
						 submit(-name=>"button",
										onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
										-value=>"Edit"),
						 submit(-name=>"button",
										onclick => '$("#cancel").val("true");'
										.($wantwidget? 'get("nmisModels")' : 'submit()' ),
										-value=>'Cancel')));
	if (my $info = getHelp($locationsteps[-1]))
	{
		print Tr(td({class=>'Plain',colspan=>'8'},$info));
	}
	print "</table></form>";
	pageEnd() if (!$wantwidget);
}

# show form for deletion of stuff
# args: none, but uses q's model, section, hash
sub deleteModel
{
	my ($wantedmodel, $wantedsection, $locsteps) = @{$Q}{"model","section","hash"};

	print header($headeropts);
	pageStart(title => "NMIS Delete Model", refresh => 86400) if (!$wantwidget);
	$AU->CheckAccess("Table_Models_rw");

	bailout("Missing arguments!") if (!$wantedmodel or !$wantedsection);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels",
									 -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_dodelete")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-override => 1, -name => "cancel", -value => "", -id => "cancel")
			. hidden(-name=>'model', -default=>$wantedmodel, -override=>'1')
			. hidden(-name=>'section', -default=>$wantedsection, -override=>'1')
			. hidden(-name=>'hash', -default=>$locsteps, -override=>'1');

	print start_table(),
	Tr(td({class=>"header",colspan=>'8',align=>'center'},"Delete part of Model $wantedmodel")),
	print Tr(td({class=>"info",colspan=>'8',align=>'center'},"&nbsp"));

	my $field = $modelstruct;
	my @locationsteps = split(/,/, $locsteps);
	# print header, and traverse the structure
	for my $level (0..$#locationsteps)
	{
		print "<tr>";
		# shim
		print td({colspan=>$level}) if $level != 0;
		print td({class=> ($level == $#locationsteps? "Major":"header"), colspan=>'1'},
						 # fixme: might want to show the element if numeric choice, not the index?
						 $locationsteps[$level]),
		"</tr>";

		$field = (ref($field) eq "ARRAY")? $field->[$locationsteps[$level]] : $field->{$locationsteps[$level]};
	}
	my $offset = @locationsteps;
	print "<tr><td colspan='9'>&nbsp;</td></tr>",
			Tr(td({class=>"Major",colspan=>9,align=>'center'},
							b("Delete this part of Model $wantedmodel?")));

	print Tr(td({colspan=>9,align=>'center',nowrap=>undef},
							submit(-name=>'button',
										 onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
										 -value=>'DELETE'),b('Are you sure ?'),
							submit(-name=>'button',
										 onclick => '$("#cancel").val("true");'
										 .($wantwidget? 'get("nmisModels")' : 'submit()' ),
										 -value=>'Cancel')));

	print "</form></table>";
	pageEnd() if (!$wantwidget);
}

# show the appropriate form for adding stuff for a given model+section+locationsteps
# none, but uses q's model, section, hash
sub addModel
{
	my %args = @_;

	my ($wantedmodel,$wantedsection,$locsteps) = @{$Q}{"model","section","hash"};

	print header($headeropts);
	pageStart(title => "NMIS Add Model", refresh => 86400) if (!$wantwidget);
	$AU->CheckAccess("Table_Models_rw");

	bailout("Missing arguments!") if (!$wantedmodel or !$wantedsection or !$locsteps);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	# what subfields do we want to allow here?
	my @field;
		if ($locsteps =~ /^\w+,rrd$/) { @field = qw(type graphtype ds oid); }
	elsif ($locsteps =~ /^\w+,sys$/) { @field  = qw(type control attribute oid); }
	elsif ($locsteps =~ /^\w+,rrd,\w+,snmp$/) { @field = qw(ds oid option calculate); }
	elsif ($locsteps =~ /^\w+,sys,\w+,snmp$/) { @field = qw(attribute oid); }
	elsif ($locsteps =~ /^\w+,rrd,\w+,snmp,\w+$/) { @field = qw(oid option replace calculate value); }
	elsif ($locsteps =~ /^\w+,sys,\w+,snmp,\w+$/) { @field = qw(oid replace value title calculate format check); }
	elsif ($locsteps =~ /^\w+,(rrd|sys),\w+,snmp,\w+,replace$/) { @field = qw(replace value); }
	elsif ($locsteps =~ /^\w+,rrd,\w+$/) { @field = qw(graphtype control indexed threshold); }
	elsif ($locsteps =~ /^interface,sys,standard$/) { @field = qw(indexed); }
	elsif ($locsteps =~ /^\w+,sys,\w+$/) { @field = qw(control indexed); }
	elsif ($locsteps =~ /^database,db,size$/) { @field = qw(type step_day step_week step_month step_year rows_day rows_week rows_month rows_year); }
	elsif ($locsteps =~ /^database,type$/) { @field = qw(type filescript); }
	elsif ($locsteps =~ /^event,event$/) { @field = qw(event role level logging); }
	elsif ($locsteps =~ /^event,event,\w+$/) { @field = qw(role level logging); }
	elsif ($locsteps =~ /^heading,graphtype$/) { @field = qw(graphtype headerscript); }
	elsif ($locsteps =~ /^threshold,name,\w+,select$/
			or $locsteps =~ /^alerts,\w+,\w+,threshold$/) { @field = qw(order fatal critical major minor warning); }
	elsif ($locsteps =~ /^threshold,name,\w+,select,\w+$/) { @field = qw(control); }
	elsif ($locsteps =~ /^threshold,name$/) { @field = qw(name eventdescr item order control fatal critical major minor warning); }
	elsif ($locsteps =~ /^stats,type$/) { @field = qw(type rrdopt); }
	elsif ($locsteps =~ /^stats,type,\w+$/) { @field = qw(rrdopt); }
	elsif ($locsteps =~ /^stats,type,\w+,\d+$/) { @field = qw(rrdopt); }
	elsif ($locsteps =~ /^summary,statstype$/) { @field = qw( statstype sumname stsname); }
	elsif ($locsteps =~ /^summary,statstype,\w+,sumname$/) { @field = qw( sumname stsname); }
	elsif ($locsteps =~ /^summary,statstype,\w+,sumname,\w+,stsname$/) { @field = qw(stsname); }
	elsif ($locsteps =~ /^summary,statstype,\w+,sumname,\w+,stsname,\d+$/) { @field = qw(stsname); }
	elsif ($locsteps =~ /^models$/) { @field = qw(vendor order nodetype string); }
	elsif ($locsteps =~ /^models,\w+$/) { @field = qw(order nodetype string); }
	elsif ($locsteps =~ /^-common-,class$/) { @field = qw(class common-model); }

	bailout("ERROR: no add operation details available for area $locsteps!") if (!@field);

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels",
									 -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_doadd")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-override => 1, -name => "cancel", -value => "", -id => "cancel")
			. hidden(-name=>'model', -default=>$wantedmodel, -override=>'1')
			. hidden(-name=>'section', -default=>$wantedsection, -override=>'1')
			. hidden(-name=>'hash', -default=>$locsteps, -override=>'1');

	print "<table>",  Tr(td({class=>"info",colspan=>'8',align=>'center'},"&nbsp"));

	# traverse location steps, print header
	my $field = $modelstruct;
	my @locationsteps = split(/,/, $locsteps);
	# print header, and traverse the structure
	for my $level (0..$#locationsteps)
	{
		print "<tr>";
		# shim
		print td({class=>"header",colspan=>$level}) if $level != 0;
		print td({class=>"header",colspan=>'1'}, $locationsteps[$level]),
		td({class=>"info",colspan=>(8-$level)}), "</tr>";

		$field = $field->{$locationsteps[$level]};
		last if (ref($field) eq 'ARRAY'); # fixme: no support for array anywhere EXCEPT at the leaf end!
	}
	my $offset = @locationsteps;
	print Tr(td({class=>"info",colspan=>$offset}),
					 td({class=>"header",colspan=>(8-$offset),align=>'center'},
							b("Add next part to Model $wantedmodel")));

	foreach my $f (@field)
	{
		print Tr(td({colspan=>$offset}),td({class=>"header",colspan=>'1'},$f),
						 td({class=>"info",colspan=>(7-$offset)},
								textfield(-name=>"_field_$f",align=>"left",override=>1,size=>'50')));
	}

	print Tr(td({colspan=>$offset}),
					 td(submit(-name=>"button",
										 onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
										 -value=>"Add"),
							submit(-name=>"button",
										 onclick => '$("#cancel").val("true");'
										 .($wantwidget? 'get("nmisModels")' : 'submit()' ),
										 -value=>"Cancel")));

	for my $helpwanted (@field)
	{
		if (my $info = getHelp($helpwanted))
		{
			print Tr(td({class=>'blank',colspan=>'8'},$info));
		}
	}

	print "</form></table>";
	pageEnd() if (!$wantwidget);
}

# endpoint for post, for making in-place edits to leaf things
# args: none but uses q's mode, section, hash and value, also cancel
# returns: nothing;
sub doEditModel
{
	return if (getbool($Q->{cancel}));
	$AU->CheckAccess("Table_Models_rw",'header');

	my ($wantedmodel,$wantedsection,$locsteps,$value) =
			@{$Q}{"model","section","hash","value"};

	bailout("Missing arguments!") if (!$wantedmodel or !$wantedsection
																		or !$locsteps or !defined $value);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	my @locationsteps = split(/,/, $locsteps);
	my $target = $modelstruct;
	for my $nextstep (@locationsteps[0..$#locationsteps-1])
	{
		$target = $target->{$nextstep};
		last if (!ref($target));		# stop BEFORE the final step
	}
	if (ref($target) eq 'ARRAY')
	{
		$target->[$locationsteps[-1]] = $value;
	}
	else
	{
		$target->{$locationsteps[-1]} = $value;
	}
	writeHashtoFile(file => $modelfn, data => $modelstruct);
}

# endpoint for post, for deleting leaves or whole subtrees
# args: none but uses q's model, section, hash,  also cancel
# returns: nothing;
sub doDeleteModel
{
	return if (getbool($Q->{cancel}));
	$AU->CheckAccess("Table_Models_rw",'header');

	my ($wantedmodel,$wantedsection,$locsteps) =  @{$Q}{"model","section","hash"};

	bailout("Missing arguments!") if (!$wantedmodel or !$wantedsection
																		or !$locsteps);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	my @locationsteps = split(/,/, $locsteps);
	my $target = $modelstruct;
	for my $nextstep (@locationsteps[0..$#locationsteps-1])
	{
		$target = $target->{$nextstep};
		last if (ref($target) eq "ARRAY"); # fixme not supported anywhere BUT around a leaf
	}

	if (ref($target) eq "ARRAY")
	{
		splice(@$target, $locationsteps[-1], 1);
	}
	elsif (ref($target) eq "HASH")
	{
		delete $target->{$locationsteps[-1]};
	}
	else
	{
		bailout("invalid arguments: ".Dumper(\@locationsteps, $target));
	}
	writeHashtoFile(file => $modelfn, data => $modelstruct);
}

#  endpoint for post, for adding X fields to the area indicated by the locsteps
# args: none, q's model, section, hash, cancel and all _field_X inputs
sub doAddModel
{
	return if getbool($Q->{cancel});
	$AU->CheckAccess("Table_Models_rw",'header');

	my ($wantedmodel,$wantedsection,$locsteps) =
			@{$Q}{"model","section","hash"};

	bailout("Missing arguments!") if (!$wantedmodel or !$wantedsection
																		or !$locsteps);

	my $modelfn = $C->{'<nmis_models>'}."/$wantedmodel.nmis";
	my $modelstruct = readFiletoHash(file => $modelfn);
	bailout "cannot read model $modelfn: $!"
			if (ref($modelstruct) ne "HASH" or !keys %$modelstruct);

	my %fields = map { my $oldkey = $_; s/^_field_//; ($_ => $Q->{$oldkey}); } (grep(/^_field_/, keys %$Q));
	bailout("No data to add!") if (!%fields);

	# where in the structure are we making changes?
	# location steps for adding address the area we are adding something IN,
	# i.e. threshold,name means add an X as threshold,name,X
	my @locationsteps = split(/,/, $locsteps);
	my $target = $modelstruct;
	for my $idx (0..$#locationsteps)
	{
		my $nextstep = $locationsteps[$idx];
		# fixme: arrays supported only around a leaf!
		last if (ref($target) eq "ARRAY"); # we want to stay OUTSIDE of the array element
		$target = $target->{$nextstep};
	}

	# now copy over the stuff from _field_X, depending
	# on where we are logically
	if ($locsteps =~ /^-common-,class$/)
	{
		$target->{ lc($fields{class}) } = { "common-model" => lc($fields{"common-model"}) };
	}

	if ($locsteps =~ /^\w+,rrd$/)
	{
		$target->{ lc($fields{type}) }->{graphtype} = $fields{graphtype} if ($fields{graphtype});
		$target->{ lc($fields{type}) }->{snmp}->{ $fields{ds} }->{oid} = $fields{oid}; # fixme no support for wmi!
	}
	if ($locsteps =~ /^\w+,sys$/)
	{
		$target->{ lc($fields{type}) }->{snmp}->{ $fields{attribute} }->{oid} = $fields{oid};
	}
	if ($locsteps =~ /^\w+,rrd,\w+,snmp$/)
	{
		$target->{ $fields{ds} }->{oid} = $fields{oid};
	}
	if ($locsteps =~ /^\w+,sys,\w+,snmp$/) # fixme no support for wmi
	{
		$target->{ $fields{attribute} }->{oid} = $fields{oid};
	}
	# "adds to"/replaces a previously defined collectable variable X
	if ($locsteps =~ /^\w+,(rrd|sys),\w+,snmp,\w+$/) # fixme no support for wmi
	{
		$target->{oid} = $fields{oid} if $fields{oid} ne "";

		$target->{title} = $fields{title} if $fields{title} ne "";
		$target->{option} = $fields{option} if $fields{option} ne "";
		$target->{calculate} = $fields{calculate} if $fields{calculate} ne "";
		$target->{check} = $fields{check} if $fields{check} ne "";
		$target->{format} = $fields{format} if $fields{format} ne "";
		$target->{replace}{$fields{replace}} = $fields{value} if $fields{value} ne "";
	}
	# "adds to"/replaces a previously defined section under rrd or sys
	if ($locsteps =~ /^\w+,(rrd|sys),\w+$/)
	{
		$target->{control} = $fields{control} if $fields{control} ne "";
		$target->{indexed} =  $fields{indexed} if $fields{indexed} ne "";
		$target->{graphtype} = lc($fields{graphtype}) if $fields{graphtype} ne "";
		$target->{threshold} = $fields{threshold} if $fields{threshold} ne "";
	}
	if ($locsteps =~ /^\w+,(rrd|sys),\w+,snmp,\w+,replace$/)
	{
		$target->{ $fields{replace} } = $fields{value} if $fields{value} ne "";
	}
	if ($locsteps =~ /^database,db,size$/)
	{
		$target->{ lc($fields{type}) } = {
			map { lc($fields{$_}) => $fields{$_} } (qw(rows_day rows_week rows_year step_day step_week step_month step_year))
		};
	}
	if ($locsteps =~ /^database,type$/)
	{
		$target->{ lc($fields{type}) } = $fields{filescript};
	}

	if ($locsteps =~ /^event,event$/)
	{
		$target->{ lc($fields{event}) }->{ lc($fields{role}) }  = {
			level => $fields{level},
			logging => $fields{logging} };
	}
	if ($locsteps =~ /^event,event,\w+$/)
	{
		$target->{ lc($fields{role}) } = { level => $fields{level},
																			 logging => $fields{logging} };
	}

	if ($locsteps =~ /^heading,graphtype$/)
	{
		$target->{ lc($fields{graphtype}) } = $fields{headerscript};
	}

	if ($locsteps =~ /^threshold,name$/)
	{
		$target->{ $fields{name} } =
		{ item => $fields{item},
			event => $fields{eventdescr},
			select => {
				$fields{order} => {
					value =>
					{
						fatal => $fields{fatal},
						critical => $fields{critical},
						major => $fields{major},
						minor => $fields{minor},
						warning => $fields{warning},
					}
				}
			}
		};
		$target->{ $fields{name} }->{select}->{ $fields{order} }->{control} = $fields{control} if $fields{control} ne "";
	}

	if ($locsteps =~ /^threshold,name,\w+,select$/)
	{
		if ($fields{order} ne "")
		{
			$target->{ $fields{order} }->{value} =
			{
				map { $_ => ($fields{$_} || $target->{default}->{value}->{$_}) } (qw(fatal critical major minor warning))
			};
		}
	}
	if ($locsteps =~ /^threshold,name,\w+,select,\w+$/)
	{
		$target->{control} = $fields{control};

}
	if ($locsteps =~ /^stats,type$/)
	{
		if ($fields{type} ne "")
		{
			$target->{ lc($fields{type}) } = [ $fields{rrdopt} ];
		}
	}

	# stats is one of the few spots with arrays
	if ($locsteps =~ /^stats,type,\w+$/)
	{
		push @$target, $fields{rrdopt};
	}
	# "add" to leaf makes no inherent sense, so implemented as 'insert before'
	if ($locsteps =~ /^stats,type,\w+,\d+$/)
	{
		splice(@$target, $locationsteps[-1], 0, $fields{rrdopt});
	}

	if ($locsteps =~ /^summary,statstype$/)
	{
		if ($fields{statstype} ne "" and $fields{sumname} ne "")
		{
			$target->{ lc($fields{statstype}) }->{name}->{ lc($fields{sumname}) }->{stsname} = [ $fields{stsname} ];
		}
	}
	if ($locsteps =~ /^summary,statstype,\w+,sumname$/)
	{
		if ($fields{sumname} ne "")
		{
			$target->{ lc($fields{sumname})}->{stsname} = [ $fields{stsname} ];
		}
	}
	# another array case
	if ($locsteps =~ /^summary,statstype,\w+,sumname,\w+,stsname$/)
	{
		push @$target, $fields{stsname};
	}
	if ($locsteps =~ /^summary,statstype,\w+,sumname,\w+,stsname,\d+$/)
	{
		# "add" to leaf makes no inherent sense, so implemented as 'insert before'
		splice(@$target, $locationsteps[-1], 0, $fields{stsname});
	}
	if ($locsteps =~ /^models$/)
	{
		if ($fields{vendor} ne "" and $fields{order} ne "" and $fields{nodetype} ne "")
		{
			$target->{ $fields{vendor} }->{order}->{ $fields{order} }->{ $fields{nodetype} } = $fields{string};
		}
	}
	if ($locsteps =~ /^models,\w+$/)
	{
		if ($fields{order} ne "" and $fields{nodetype} ne "")
		{
			$target->{order}->{ $fields{order} }->{ $fields{nodetype} } = $fields{string};
		}
	}

	writeHashtoFile(file => $modelfn, data => $modelstruct);
}

# returns help test for given field name
# fixme: NOT location dependent, so cannot handle contextual field names
# args: field name
# returns: html or empty string
sub getHelp
{
	my ($fieldname) = @_;
	if (my $text = $helptexts{$fieldname})
	{
		return ul(li($fieldname), $text);
	}
	return "";
}
