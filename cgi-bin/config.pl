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
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
 
# 
use strict;
use NMIS;
use func;
use csv;
use DBfunc;
use URI::Escape;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

my $wantwidget = exists $Q->{widget}? 
		!getbool($Q->{widget}, "invert") : 1;
my $widget = $wantwidget ? "true" : "false";

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_config_view","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

# select function

# what shall we do

if ($Q->{act} eq 'config_nmis_menu') {			displayConfig();
} elsif ($Q->{act} eq 'config_nmis_add') {		addConfig();
} elsif ($Q->{act} eq 'config_nmis_edit') {		editConfig();
} elsif ($Q->{act} eq 'config_nmis_delete') {	deleteConfig();
} elsif ($Q->{act} eq 'config_nmis_doadd') {	doAddConfig(); displayConfig();
																							
# edit submission action: if it returns 0, we do nothing (assuming it prints complains)
# if it returns 0 AND sets error_message in Q, then we show the toplevel config AND the error message in a bar
# if it returns 1 we shod the topplevel config
} elsif ($Q->{act} eq 'config_nmis_doedit') {	if (doEditConfig() or $Q->{error_message}) { displayConfig(); }
} elsif ($Q->{act} eq 'config_nmis_dodelete') { doDeleteConfig(); displayConfig();
} elsif ($Q->{act} eq 'config_nmis_dostore') { 	doStoreTable(); displayConfig();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	print "Config: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
	pageEnd if (!$wantwidget);
}

exit 1;


#
# display the Config of NMIS
#
sub displayConfig{
	my %args = @_;

	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) if (!$wantwidget);

	my $CT = loadCfgTable(); # load configuration of table

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	# start of form
  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nmis_menu")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table({width=>"400px"}) ; # first table level

	if (defined $Q->{error_message} && $Q->{error_message} ne "" )
	{
		print Tr(td({class=>'Fatal',align=>'center'}, "Error: $Q->{error_message}"));
	}

	print Tr(td({class=>'header',align=>'center'},"NMIS Configuration - $C->{conf} loaded"));

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
	pageEnd if (!$wantwidget);

}

sub escape {
	my $k = shift;
	$k =~ s/</&lt;/g; $k =~ s/>/&gt;/g;
	return $k;
}

sub typeSect {
	my %args= @_;
	my $section = $args{section};
	my $CC = $args{data};
	my @out;

	my $CT = loadCfgTable(); # load configuration of table

	my $ref = url(-absolute=>1)."?conf=$Q->{conf}";

	# create items list, contains of presets and adds
	my @items = map { keys %{$_} } @{$CT->{$section}};
	my @items_all = @items;
	my @items_cfg = sort keys %{$CC->{$section}};
	for my $i (@items_cfg) { push @items_all,$i unless grep { $_ eq $i } @items; }

	push @out,Tr(td({class=>"header"},$section),td({class=>'info Plain',colspan=>'2'},"&nbsp;"),td({class=>'info Plain'},
			eval {
				if ($AU->CheckAccess("Table_Config_rw","check")) {
					return a({ href=>"$ref&act=config_nmis_add&section=$section&widget=$widget"},'add&nbsp;');
				} else { return ""; }
			}
		));
	for my $k (@items_all) 
	{ 
		my $value = $CC->{$section}{$k};
		if ($section eq "system" and $k eq "group_list")
		{
			$value =  join(" ", sort split(/\s*,\s*/, $value));
		}
		
		push @out,Tr(td({class=>"header"},"&nbsp;"),
				td({class=>"header"},escape($k)),td({class=>'info Plain'},
																						escape($value)),
				eval {
					if ($AU->CheckAccess("Table_Config_rw","check")) {
						return td({class=>'info Plain'},
							a({ href=>"$ref&act=config_nmis_edit&section=$section&item=$k&widget=$widget"},'edit&nbsp;'),
							eval { 
								my $line;
								$line = a({ href=>"$ref&act=config_nmis_delete&section=$section&item=$k&widget=$widget"},
														'delete&nbsp;') unless (grep { $_ eq $k } @items);
								return $line;
							});
					} else { return ""; }
				}
			);
	}

	return @out;
}


sub editConfig{
	my %args = @_;

	my $section = $Q->{section};
	my $item = $Q->{item};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);
	
	$AU->CheckAccess("Table_Config_rw");

	my $CT = loadCfgTable(); # load configuration of table

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	# start of form, see comment for first start_form
	# except that this one also needs the cancel case covered
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nmis_doedit")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
			. hidden(-override => 1, -name => "edittype", -value => '', -id=> "edittype")
			
			. hidden(-name=>'section', -value => $section, -override=>'1')
			. hidden(-name=>'item', -value => $item, -override=>'1');

	print start_table() ; # first table level


	# the more comfy group editing interface  has only two columns and
	# the shared button should be named delete
	my $numberofcols = 3;
	my $submitbuttonvalue = "Edit";
	
	if ($section eq "system" and $item eq "group_list")
	{
		$numberofcols = 2;
		$submitbuttonvalue = "Delete";
		print Tr(td({class=>"header",colspan=>'2'},"Edit of NMIS Config - $Q->{conf}"));
		
		# an entry for adding a group
		print Tr(td({class => "header", colspan => 2 }, "Add New Group")),
		Tr(td({class=>'info Plain', colspan => 2}, 
					textfield(-name=>"newgroup", -style=>'font-size:14px;', -title => "Group names cannot contain spaces or commas.")
					.button(-name=>"addbutton",
									onclick=> ('$("#edittype").val("Add"); '. ($wantwidget? "get('nmisconfig');" : "submit()" )), 
									-value=>"Add"))),
							Tr(td({class => "header", colspan => 2}, "Existing Groups"));

		# figure out the number of members per group and warn the user if there are any members
		my $LNT = loadLocalNodeTable();
		my %membercounts; 
		for my $node (values %$LNT)
		{
			$membercounts{$node->{group}}++ if ($node->{group});
		}

		# print the group rows, one per line plus delete button at the end
		my @actualgroups = sort split(/\s*,\s*/, $CC->{$section}->{$item});
		for my $group (@actualgroups)
		{
			my $escapedgroup = uri_escape($group);
			print Tr(td( $membercounts{$group}? qq|<span title="If you remove this group, then its members will no longer be shown in NMIS.">$group ($membercounts{$group} members)</span>| : $group),
							 td(checkbox(-name => "delete_group_$escapedgroup", -label => "Delete Group", -value => "nuke"))
					);
		}
	}
	else
	{
		# the generic editing interface		
		print Tr(td({class=>"header",colspan=>'3'},"Edit of NMIS Config - $Q->{conf}"));

		print Tr(td({class=>"header"},$section));
		# look for item ref
		my $ref;
		for my $rf (@{$CT->{$section}}) {
			for my $itm (keys %{$rf}) {
				if ($item eq $itm) {
					$ref = $rf->{$item};
				}
			}
		}

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
	pageEnd if (!$wantwidget);
}

sub doEditConfig {
	my %args = @_;

	return 1 if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my $section = $Q->{section};
	my $item = $Q->{item};
	my $value = $Q->{value};

	# check if DB <=> file change
	if ($section eq 'database' and $item =~ /^db.*sql$/ 
			and $C->{$item} ne $value and ($C->{$item} ne '' 
																		 or getbool($value)) ) {
		storeTable(section=>$section,item=>$item,value=>$value);
		return 0;
	} 
	else 
	{
		my ($CC,undef) = readConfData(conf=>$C->{conf});

		# handle the comfy group_list editing and translate the separate values
		if ($section eq "system" and $item eq "group_list")
		{
			my @existinggroups = split(/\s*,\s*/, $CC->{$section}->{$item});
			my $newgroup = $Q->{newgroup};
			# add actions ONLY if the add button was used to submit
			if ($Q->{edittype} eq "Add" and defined $newgroup and $newgroup ne '')
			{
				if ($newgroup =~ /[, ]/)
				{
					$Q->{error_message} = "Group name \"$newgroup\" contains invalid characters. Spaces and commas are prohibited.";
					return 0;
				}

				push @existinggroups, $newgroup
						if (!grep($_ eq $newgroup, @existinggroups));
			}
			
			# delete actions ONLY if the delete button was used to submit
			if ($Q->{edittype} eq "Delete")
			{
				for my $deletable (grep(/^delete_group_/, keys %$Q))
				{
					next if $Q->{$deletable} ne "nuke";
					my $groupname = $deletable;
					$groupname =~ s/^delete_group_//; 
					my $unesc = uri_unescape($groupname);
					
					@existinggroups = grep($_ ne $unesc, @existinggroups);
				}
			}

			$value = join(",", sort @existinggroups);
		}

		$CC->{$section}{$item} = $value;
		writeConfData(data=>$CC);
		return 1;
	}
}


sub deleteConfig {
	my %args = @_;

	my $section = $Q->{section};
	my $item = $Q->{item};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	$AU->CheckAccess("Table_Config_rw");

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	my $value = $CC->{$section}{$item};

	# start of form, see comment for first two start_forms
	print start_form( -name=>"nmisconfig", -id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nmis_dodelete")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput");

	# background values
	print hidden(-name=>'section', -default => $section,-override=>'1');
	print hidden(-name=>'item', -default => $item,-override=>'1');


	print start_table() ; # first table level

	# display edit field
	my @hash = split /,/,$Q->{hash};
	print Tr(td({class=>"header",colspan=>'3'},b("Delete this item of NMIS Config - $Q->{conf}")));
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

	print end_form;

End_deleteConfig:
	print end_table;
	pageEnd if (!$wantwidget);
}


sub doDeleteConfig {
	my %args = @_;

	return if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my $section = $Q->{section};
	my $item = $Q->{item};

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	delete $CC->{$section}{$item};

	writeConfData(data=>$CC);
}

sub addConfig{
	my %args = @_;

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) if (!$wantwidget);

	$AU->CheckAccess("Table_Config_rw");

	# start of form, see comment for first two start_forms
	print start_form(-id=>"nmisconfig", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
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
	pageEnd if (!$wantwidget);

}


sub doAddConfig {
	my %args = @_;

	return if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Config_rw");

	my ($CC,undef) = readConfData(conf=>$C->{conf});

	my $section = $Q->{section};

	if ($Q->{id} ne '') {
		$CC->{$section}{$Q->{id}} = $Q->{value};
	}

	writeConfData(data=>$CC);
}

# store full table in DB
sub storeTable {
	my %args = @_;

	my $section = $args{section};
	my $item = $args{item};
	my $value = $args{value};

	my $table;

	my %tables = (
		'db_events_sql'=> 'Events',
		'db_nodes_sql' => 'Nodes',
		'db_users_sql' => 'Users',
		'db_locations_sql' => 'Locations',
		'db_contacts_sql' => 'Contacts',
		'db_privmap_sql' => 'PrivMap',
		'db_escalations_sql' => 'Escalations',
		'db_services_sql' => 'Services',
		'db_iftypes_sql' => 'ifTypes',
		'db_access_sql' => 'Access',
		'db_logs_sql' => 'Logs',
		'db_links_sql' => 'Links'
		) ;

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) 	if (!$wantwidget);

	if (!($table = $tables{$item})) {
		print Tr(td({class=>'error'},"ERROR, table does not exist"));
		return;
	}

	# check if DB exists
	my $dbh = DBfunc::->new();
	if ( !$dbh->connect()) {
		print Tr(td({class=>'error'},"ERROR, no mySQL server active"));
		return;
	}

	# start of form, see comment for first two start_forms
	print start_form(-name=>"nmisconfig",-id=>"nmisconfig",-href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_nmis_dostore")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "table", -value => $table)
			. hidden(-override => 1, -name => "section", -value => $section)
			. hidden(-override => 1, -name => "item", -value => $item)
			. hidden(-override => 1, -name => "value", -value => $value)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
			. hidden(-override => 1, -name => "file", -value => '', -id=> "fileinput")
			. hidden(-override => 1, -name => "db", -value => '', -id=> "dbinput");

	print start_table;

	if ( getbool($C->{$item}) ) {
		print Tr(td({class=>'info Plain'}," mySQL Database is active now"));
	} else {
		my $ext = getExtension(dir=>'conf');
		print Tr(td({class=>'info Plain'}," conf/$table.$ext is active now"));
	} 
	
	print Tr(td('Make your choice'));

	print Tr(td(
				eval {
					if (getbool($value)) {
						return button(-name=>"button",
													onclick=> '$("#dbinput").val("true");' . ($wantwidget? "get('nmisconfig');" : 'submit();'),
													-value=>'Transfer from file to DB');
					} else {
						return button(-name=>"button",
													onclick=> '$("#fileinput").val("true");' . ($wantwidget? "get('nmisconfig');" : 'submit();'),
													-value=>'Transfer from DB to file');
					}
				},
				button(-name=>'button',
							 onclick=> '$("#cancelinput").val("true");' . ($wantwidget? "get('nmisconfig');" : 'submit();'),
							 -value=>"Cancel")));

	print end_table;
	print end_form;
	pageEnd if (!$wantwidget);

}

sub doStoreTable {
	my $section = $Q->{section};
	my $item = $Q->{item};
	my $value = $Q->{value};
	my $table = $Q->{table};

	my $T;

	return 1 if (getbool($Q->{cancel}));

	if (getbool($Q->{db})) {
		# from file to DB
		if (($T = loadTable(dir=>'conf',name=>$table)) ) { # load requested table
			if (DBfunc::->delete(table=>$table,where=>'*')) { # delete all rows
				logMsg("INFO all rows of table=$table removed");
				my $cnt = 0;
				for my $k (keys %{$T}) {
					$T->{$k}{index} = $k; # 
					if ( ! DBfunc::->insert(table=>$table,data=>$T->{$k})) {
						print header($headeropts);
						pageStart(title => "NMIS Configuration", refresh => $Q->{refresh}) if (!$wantwidget);
						
						print "\n</pre>\n";
						print DBfunc->error."<br>\n";
						pageEnd if (!$wantwidget);
						last;
					}
				}
				logMsg("INFO file transfer table=$table to DB done");
			} else {
				logMsg("ERROR delete all rows of table$table");
				return;
			}
		} else {
			return;
		}
	} else {
		# from DB to file
		if (($T = DBfunc::->select(table=>$table)) ) {
			writeTable(dir=>'conf',name=>$table,data=>$T);
			my $ext = getExtension(dir=>'conf');
			logMsg("INFO table=$table transfer from DB to file=conf/$table.$ext done");
		} else {
			return;
		}
	}

	# update config
	my ($CC,undef) = readConfData(conf=>$C->{conf});
	$CC->{$section}{$item} = $value;
	writeConfData(data=>$CC);

}

#============================================================================

sub getHelp {
	my $help = shift;

	my %help = (
		'id' => 			'Format: string<br>this name must be unique over all sections.',
# authorization
		'auth_require' => 	'Format: true | false<br>set this to require authentication (default=false)',
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
		'kernelname' => 	'Format: string<br>set kernel name if NMIS can\'t detect the real name',
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
		'cache_summary_tables' => 	'Format: true | false<br>set if you wish to cache nmis summary stats in nmis.pl, to save recalc time',
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
# database
		'db_events_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_nodes_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_users_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_locations_sql'	=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_contacts_sql'	=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_privmap_sql'	=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_escalations_sql'=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_services_sql'	=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_iftypes_sql'	=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_access_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_logs_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file',
		'db_links_sql'		=>	'Format: true | false<br>set if you wish to use sql database, else use file'

	);

	if (exists $help{$help}) {
		return ul(li($help),$help{$help});
	}
	return;
}

