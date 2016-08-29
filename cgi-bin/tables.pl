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

#
use strict;
use NMIS;
use NMIS::UUID;
use Sys;
use func;
use csv;
use Net::hostent;
use Socket;
use Data::Dumper;
use URI::Escape;

use DBfunc;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

my $formid = $Q->{table} ? "nmis$Q->{table}" : "nmisTable";

# this cgi script defaults to widget mode ON
my $widget = getbool($Q->{widget},"invert")? "false" : "true";
my $wantwidget = $widget eq "true";


#======================================================================

# select function

if ($Q->{act} eq 'config_table_menu') { 			menuTable();
} elsif ($Q->{act} eq 'config_table_add') { 		editTable();
} elsif ($Q->{act} eq 'config_table_view') { 		viewTable();
} elsif ($Q->{act} eq 'config_table_show') { 		showTable();
} elsif ($Q->{act} eq 'config_table_edit') { 		editTable();
} elsif ($Q->{act} eq 'config_table_delete') { 		viewTable();
} elsif ($Q->{act} eq 'config_table_doadd') { 		if (doeditTable()) { menuTable(); }
} elsif ($Q->{act} eq 'config_table_doedit') { 		if (doeditTable()) { menuTable(); }
} elsif ($Q->{act} eq 'config_table_dodelete') { 	dodeleteTable(); menuTable();
} else { notfound(); }

sub notfound {
	print header($headeropts);
	print "Tables: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit;

#==================================================================
#

sub loadReqTable {
	my %args = @_;
	my $table = $args{table};
	my $msg = $args{msg};

	my $T;

	my $db = "db_".lc($table)."_sql";
	if (getbool($C->{$db})) {
		$T = DBfunc::->select(table=>$table); # full table
	} else {
		$T = loadTable(dir=>'conf',name=>$table);
	}

	if (!$T and !getbool($msg,"invert")) {
		print Tr(td({class=>'error'},"Error on loading table $table"));
		return;
	}
	return $T;
}

sub loadCfgTable {
	my %args = @_;
	my $table = $args{table};

	# Set the Environment VAR to tell the EVAL'd program who the user is.
	$ENV{'NMIS_USER'} = $AU->{user};

	my $tabCfg = loadGenericTable("Table-$table");
	my %Cfg = %{$tabCfg};

	if (!($Cfg{$table})) {
		print Tr(td({class=>'error'},"Configuration of table $table does not exists"));
		return;
	}

	return $Cfg{$table};
}

#
sub menuTable{

	my $table = $Q->{table};
	#start of page
	print header($headeropts);
	pageStartJscript(title => "View Table $table") if (getbool($widget,"invert"));

	$AU->CheckAccess("Table_${table}_view");

	my $LNT;
	if ( $table eq "Nodes" ) {
		$LNT = loadLocalNodeTable(); # load from file or db
	}

	print <<EOF;
<script>
clearInterval(null);
</script>
EOF

	my $bt;
	my $T;
	$T = loadReqTable(table=>$table); # load requested table

	my $CT;
	return if (!($CT = loadCfgTable(table=>$table))); # load configuration of table

	print start_table;

	my $url = url(-absolute=>1)."?conf=$Q->{conf}&table=$table";

	# print short info
	#print header
	print Tr( eval { my $line; my $colspan = 1;
			for my $ref ( @{$CT}) { # trick for order of header items
				for my $item (keys %{$ref}) {
					if ($ref->{$item}{display} =~ /header/ ) {
						$line .= td({class=>'header',align=>'center'},$ref->{$item}{header});
						$colspan++;
					}
				}
			}
			$line .= td({class=>'header',align=>'center'},'Action',
					eval {
						if ($AU->CheckAccess("Table_${table}_rw","check")) {
							return ' > '.a({href=>"$url&act=config_table_add&widget=$widget"},'add'),
						} else { return ''; }
					}
				);
			return Tr(th({class=>'title',colspan=>$colspan},"Table $table")).$line;
		});
	# print data
	for my $k (sort {lc($a) cmp lc($b)} keys %{$T}) {
		my $display = 1;
		if ( $table eq "Nodes" ) {
			$display = 0 unless $AU->InGroup($LNT->{$T->{$k}{name}}{group});
		}
		print start_Tr if $display;
		for my $ref ( @{$CT}) { # trick for order of header items
			for my $item (keys %{$ref}) {
				if ($ref->{$item}{display} =~ /header/ ) {
					print td({class=>'info Plain'}, escapeHTML($T->{$k}{$item})) if $display;
				}
			}
		}

		my $safekey = uri_escape($k);

		if ($AU->CheckAccess("Table_${table}_rw","check")) {
			$bt = '&nbsp;'
					.	a({href=>"$url&act=config_table_edit&key=$safekey&widget=$widget"},
							'edit')
					. '&nbsp;'
					. a({href=>"$url&act=config_table_delete&key=$safekey&widget=$widget"},
							'delete');
			# if looking at the users table AND lockout feature is enabled, offer a failure count reset
			if ($table eq "Users" && $C->{auth_lockout_after})
			{
				$bt .= '&nbsp;' . a({href => "$url&act=config_table_reset&key=$safekey&widget=$widget"},
														"reset login count");
			}
		} else {
			$bt = '';
		}

		if ($display)
		{
			print td({class=>'info Plain'},a({href=>"$url&act=config_table_view&key=$safekey&widget=$widget"},'view'),$bt);
			print end_Tr;
		}
	}

	print end_table;

	pageEnd() if (getbool($widget,"invert"));

}

# shows the table contents, optionally with a delete button
sub viewTable {

	my $table = $Q->{table};
	my $key = $Q->{key};

	#start of page
	print header($headeropts);
	pageStartJscript(title => "View Table $table") if (getbool($widget,"invert"));

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration
	# not delete -> we assume view
	my $action= $Q->{act} =~ /delete/? "config_table_dodelete": "config_table_menu";


  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"$formid", -href=>url(-absolute=>1)."?");
	print hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => $action)
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "table", -value => $table)
			. hidden(-override => 1, -name => "key", -value => $key)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput");

	print start_table;
	print Tr(td({class=>'header',colspan=>'2'},"Table $table"));

	# print items of table
	for my $ref ( @{$CT}) { # trick for order of header items
		for my $item (keys %{$ref}) {
			print Tr(td({class=>'header',align=>'center'},escapeHTML($ref->{$item}{header})),
				td({class=>'info Plain'},escapeHTML($T->{$key}{$item})));
		}
	}

	if ($Q->{act} =~ /delete/)
	{
			print Tr(td('&nbsp;'),
							 td(button(-name=>"button",onclick => ($wantwidget? "get('$formid');" : 'submit()'),
												 -value=>"Delete"),
									"Are you sure",
									# need to set the cancel parameter
									button(-name=>'button',
												 onclick=> '$("#cancelinput").val("true");'
												 . ($wantwidget? "get('$formid');" : 'submit();'),
												 -value=>"Cancel")));
	}
	else
	{
			# in mode view submitting the form straight is side-effect free and ok.
			print Tr(td('&nbsp;'),
							 td(
									 button(-name=>'button',
													onclick=> ($wantwidget? "get('$formid');" : 'submit()'),
													-value=>"Ok")));
	}

	print end_table;
	print end_form;
	pageEnd() if (getbool($widget,"invert"));
}

sub showTable {

	my $table = $Q->{table};
	my $key = $Q->{key};
	my $node = $Q->{node};
	my $found = 0;

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Show Table $table") if (getbool($widget,"invert"));

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');

	print createHrButtons(node=>$node, system=>$S, refresh=>$Q->{refresh}, widget=>$widget, conf => $Q->{conf}, AU => $AU);

	print start_table;
	print Tr(th({class=>'title',colspan=>'2'},"Table $table"));

	# try to find a match
	my $pos = length($key)+1;
	my $k = lc $key;
	$k =~ tr/+,./ /; # remove

	while ($pos > 0 && $found == 0) {
		my $s = substr($k,0,$pos);
		for my $t (keys %{$T}) {
			if ($s eq lc($t)) {
				$found = 1;
				# print items of table
				for my $ref ( @{$CT}) { # trick for order of header items
					for my $item (keys %{$ref}) {
						print Tr(td({class=>'header',align=>'center'},escapeHTML($ref->{$item}{header})),
							td({class=>'info Plain'},escapeHTML($T->{$t}{$item})));
					}
				}
				last;
			}
		}
		$pos = rindex($k," ",($pos - 1));
	}
	if (!$found) {
		print Tr(td({class=>'error'},"\'$key\' does not exist in table $table"));
	}

	print end_table;
	print end_form;
	pageEnd() if (getbool($widget,"invert"));
}

sub editTable
{
	my $table = $Q->{table};
	my $key = $Q->{key};

	my @hash; # items of key

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Edit Table $table") if (getbool($widget,"invert"));

	$AU->CheckAccess("Table_${table}_rw");

	my $T;
	return if (!($T = loadReqTable(table=>$table,msg=>'false')) and $Q->{act} =~ /edit/); # load requested table

	my $CT = loadCfgTable(table=>$table);

	my $func = ($Q->{act} eq 'config_table_add') ? 'doadd' : 'doedit';
	my $button = ($Q->{act} eq 'config_table_add') ? 'Add' : 'Edit';
	my $url = url(-absolute=>1)."?";

  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-name=>"$formid",-id=>"$formid",-href=>"$url")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf} )
			. hidden(-override => 1, -name => "act", -value => "config_table_$func")
			. hidden(-override => 1, -name => "table" , -value => $table )
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
 			. hidden(-override => 1, -name => "update", -value => '', -id=> "updateinput");


	my $anyMandatory = 0;
	print start_table;
	print Tr(th({class=>'title',colspan=>'2'},"Table $table"));

	for my $ref ( @{$CT})
	{
		for my $item (keys %{$ref})
		{
			my $thisitem = $ref->{$item}; # table config record for this item
			my $thiscontent = $T->{$key}->{$item}; # table CONTENT for this item

			my $mandatory = "";
			my $headerclass = "header";
			my $headspan = 1;
			if ( getbool($thisitem->{mandatory}) )
			{
				$mandatory = " <span style='color:#FF0000'>*</span>";
				$anyMandatory = 1;
			}

			if ( exists $thisitem->{special} and $thisitem->{special} eq "separator" )
			{
				$headerclass = "heading4";
				$headspan = 2;
				print Tr(td({class=>$headerclass,align=>'center',colspan=>$headspan},
										escapeHTML($thisitem->{header}).$mandatory));
			}
			# things tagged editonly are ONLY editable, NOT settable initially on add
			elsif ($func eq "doadd" and $thisitem->{display} =~ /editonly/)
			{
				# do nothing, skip this thing's row completely
			}
			else
			{
				print Tr(td({class=>$headerclass,align=>'center',colspan=>$headspan},
										escapeHTML($thisitem->{header}).$mandatory),
								 eval {
									 my $line;
									 if ($thisitem->{display} =~ /key/)
									 {
										 push @hash,$item;
									 }

									 # things tagged key are NOT editable, only settable initially on add.
									 # on edit the text is static
									 if ($func eq 'doedit' and $thisitem->{display} =~ /key/)
									 {
										 $line .= td({class=>'header'}, escapeHTML($thiscontent));
										 $line .= hidden("-name"=>$item, "-default"=>$thiscontent, "-override"=>'1');
									 }
									 elsif ($thisitem->{display} =~ /textbox/)
									 {
										 my $value = ($thiscontent or $func eq 'doedit') ? $thiscontent : $thisitem->{value}[0];
										 $line .= td(textarea(-name=> $item, -value=>$value,
																					-style=> 'width: 95%;',
																					-rows => 3,
																					-columns => ($wantwidget? 35 : 70)));
									 }
									 elsif ($thisitem->{display} =~ /text/) {
										 my $value = ($thiscontent or $func eq 'doedit') ? $thiscontent : $thisitem->{value}[0];
										 #print STDERR "DEBUG editTable: text -- item=$item, value=$value\n";
										 $line .= td(textfield(-name=>$item, -value=>$value,
																					 -style=> 'width: 95%;',
																					 -size=>  ($wantwidget? 35 : 70)));
									 }
									 elsif ($thisitem->{display} =~ /readonly/) {
										 my $value = ($thiscontent or $func eq 'doedit') ? $thiscontent : $thisitem->{value}[0];

										 $line .= td(escapeHTML($value));
										 $line .= hidden(-name=>$item, -default=>$value, -override=>'1');
									 }
									 elsif ($thisitem->{display} =~ /pop/) {
										 #print STDERR "DEBUG editTable: popup -- item=$item\n";
										 $line .= td(popup_menu(
																	 -name=> $item,

																	 -values=>$thisitem->{value},
																	 -style=>'width: 95%;',
																	 -default=>$thiscontent));
									 }
									 elsif ($thisitem->{display} =~ /scrol/) {
										 my @items = split(/,/,$T->{$key}{$item});
										 $line.= td(scrolling_list(-name=>"$item", -multiple=>'true',
																							 -style=>'width: 95%;',
																							 -size=>'6',
																							 -values=>$thisitem->{value},
																							 -default=>\@items));
									 }
									 return $line;
								 });
			}
		}
	}

	print hidden(-name=>'hash', -default=>join(',',@hash),-override=>'1');
	print Tr(td({class=>'',align=>'center',colspan=>'2'},"<span style='color:#FF0000'>*</span> mandatory fields."));
	print Tr(td('&nbsp;'),
					 td(
							 ($table eq 'Nodes' ?
								# set update to true, then submit
							 button(-name=>"button",
											onclick => '$("#updateinput").val("true");'
											. ($wantwidget? "javascript:get('$formid');" : 'submit();' ),
											-value=>"$button and Update Node") : "&nbsp;" ),
							 # the submit/add/edit button just submits the form as-is
							 button(-name=>"button", onclick => ( $wantwidget ? "get('$formid');" : 'submit();' ),
											-value=>$button),
							 # the cancel button needs to set the cancel input
							 button(-name=>'button', onclick=> '$("#cancelinput").val("true");'
											. ($wantwidget? "get('$formid');" : 'submit();'),
											-value=>"Cancel")));

	print end_table;
	print end_form;
	pageEnd() if (getbool($widget,"invert"));
}

sub doeditTable
{
	my $table = $Q->{table};
	my $hash = $Q->{hash};

	my $new_name;									# only needed for nodes table

	return 1 if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table,msg=>'false');

	my $CT = loadCfgTable(table=>$table);
	my $TAB = loadGenericTable('Tables');

	# combine key from values, values separated by underscrore
	my $key = join('_', map { $Q->{$_} } split /,/,$hash );
	$key = lc($key) if (getbool($TAB->{$table}{CaseSensitiveKey},"invert")); # let key of table Nodes equal to name

	# key and 'name' property values must match up, and be space-stripped, for both users and nodes
	if ($table eq "Nodes" or $table eq "Users")
	{
		$key = stripSpaces($key);
	}

	# test on existing key
	if ($Q->{act} =~ /doadd/)
	{
		if (exists $T->{$key}) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} , escapeHTML("Key $key already exists in table")));
			return 0;
		}
		if ($key eq '') {
			print header($headeropts);
			print Tr(td({class=>'error'} , escapeHTML("Field \'$hash\' must be filled in table $table")));
			return 0;
		}
	}

	# make room, make room! accessing a nonexistent $T->{$key} does NOT attach it to $T...
	my $thisentry  = $T->{$key} ||= {};

	my $V;
	# store new values in table structure
	for my $ref ( @{$CT})
	{
		for my $item (keys %{$ref})
		{
			my $thisitem = $ref->{$item}; # table config record for this item

			# do not save anything for separator entries, they're just for visual use
			if (defined($thisitem->{special}) && $thisitem->{special} eq "separator")
			{
				delete $thisentry->{$item};
				next;
			}
			# but handle multi-valued inputs correctly!
			# with Vars we get that as packed string of null-separated entries
			# if submission was under widget mode, then javascript:get() will have transformed
			# any such into comma-sep data - but for a standalone submission that does not happen.
			my $value = join(",", unpack("(Z*)*", stripSpaces($Q->{$item})));
			$thisentry->{$item} = $V->{$item} = $value;
		}
	}

	# some sanity checks BEFORE writing the data out
	if ($table eq 'Nodes')
	{
		# check host address
		if (!$thisentry->{host})
		{
			print header($headeropts);
			print Tr(td({class=>'error'} , "Field \'host\' must be filled in table $table"));
			return 0;
		}

		### test the DNS for DNS names, if no IP returned, error exit
		# fixme: ipv6 not supported yet
		if ( $thisentry->{host} !~ /\d+\.\d+\.\d+\.\d+/ )
		{
			my $address = resolveDNStoAddr($thisentry->{host});
			if ( $address !~ /\d+\.\d+\.\d+\.\d+/ or !$address ) {
				print header($headeropts);
				print Tr(td({class=>'error'} , escapeHTML("ERROR, cannot resolve IP address \'$thisentry->{host}\'")
										."<br>". "Please correct this item in table $table"));
				return 0;
			}
		}

		# ensure a uuid is present
		$thisentry->{uuid} ||= getUUID($key);
		$V->{uuid} ||= $thisentry->{uuid};

		# keep the new_name from being written to the config file
		$new_name = $thisentry->{new_name};
		delete $thisentry->{new_name};
	}

	my $db = "db_".lc($table)."_sql";
	if ( getbool($C->{$db}) ) {
		my $stat;
		$V->{index} = $key; # add this column
		if ($Q->{act} =~ /doadd/) {
			$stat = DBfunc::->insert(table=>$table,data=>$V);
		} else {
			$stat = DBfunc::->update(table=>$table,data=>$V,index=>$key);
		}
		if (!$stat) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} , escapeHTML(DBfunc::->error())));
			return 0;
		}
	} else {
		writeTable(dir=>'conf',name=>$table, data=>$T);
	}


	# further special handling for nodes: rename and general update
	if ($table eq 'Nodes')
	{
		# handle the renaming case
		if ($new_name && $new_name ne $thisentry->{name})
		{
			my ($error,$message) = NMIS::rename_node(old => $thisentry->{name}, new => $new_name,
																							 originator => "tables.pl.editNodeTable");
			if ($error)
			{
				print header($headeropts),
				Tr(td({class=>'error'}, escapeHTML("ERROR, renaming node \'$thisentry->{name}\' to \'$new_name\' failed: $message")));
				return 0;
			}
			$key = $new_name;
		}

		cleanEvent($key, "tables.pl.editNodeTable");

		if (getbool($Q->{update}))
		{
			doNodeUpdate(node=>$key);
			return 0;
		}
	}

	return 1;
}

sub dodeleteTable {
	my $table = $Q->{table};
	my $key = $Q->{key};

	return 1 if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table);
	my $db = "db_".lc($table)."_sql";
	if (getbool($C->{$db}) ) {
		if (!(DBfunc::->delete(table=>$table,index=>$key))) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,escapeHTML(DBfunc::->error())));
			return 0;
		}
	} else {
		# remote key
		my $TT;
		foreach (keys %{$T}) {
			if ($_ ne $key) { $TT->{$_} = $T->{$_}; }
		}

		writeTable(dir=>'conf',name=>$table,data=>$TT);
	}

	# make sure to remove events for deleted nodes
	if ($table eq "Nodes")
	{
		cleanEvent($key,"tables.pl.editNodeTable");
	}
}

sub doNodeUpdate {
	my %args = @_;
	my $node = $args{node};

	# note that this will force nmis.pl to skip the pingtest as we are a non-root user !!
	# for now - just pipe the output of a debug run, so the user can see what is going on !

	# now run the update and display
	print header($headeropts);
	pageStartJscript(title => "Run update on $node") if (getbool($widget,"invert"));

	print start_form(-id => "$formid",
									 -href => url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_table_menu")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "table", -value => $Q->{table});


#									 conf=$Q->{conf}&act=config_table_menu&table=$Q->{table}&widget=$widget",
#									 -action => url(-absolute=>1)."?conf=$Q->{conf}&act=config_table_menu&table=$Q->{table}&widget=$widget" );

	print table(Tr(td({class=>'header'}, escapeHTML("Completed web user initiated update of $node")),
				td(button(-name=>'button', -onclick=> ($wantwidget? "get('$formid')" : "submit();" ),
									-value=>'Ok'))));
	print "<pre>\n";
	print escapeHTML("Running update on node $node\n\n\n");

	my $pid = open(PIPE, "-|");
	if (!defined $pid)
	{
		print "Error: cannot fork: $!\n";
	}
	elsif (!$pid)
	{
		# child
		open(STDERR, ">&STDOUT"); # stderr to go to stdout, too.
		exec("$C->{'<nmis_bin>'}/nmis.pl","type=update", "node=$node", "info=true", "force=true");
		die "Failed to exec: $!\n";
	}
	select((select(PIPE), $| = 1)[0]);			# unbuffer pipe
	select((select(STDOUT), $| = 1)[0]);		# unbuffer stdout

	while ( <PIPE> ) {
		print escapeHTML($_);
	}
	close(PIPE);
	print "\n</pre>\n<pre>\n";
	print escapeHTML("Running collect on node $node\n\n\n");

	$pid = open(PIPE, "-|");
	if (!defined $pid)
	{
		print "Error: cannot fork: $!\n";
	}
	elsif (!$pid)
	{
		# child
		open(STDERR, ">&STDOUT"); # stderr to go to stdout, too.
		exec("$C->{'<nmis_bin>'}/nmis.pl","type=collect", "node=$node", "info=true");
		die "Failed to exec: $!\n";
	}
	select((select(PIPE), $| = 1)[0]);			# unbuffer pipe

	while ( <PIPE> ) {
		print escapeHTML($_);
	}
	close(PIPE);
	print "\n</pre>\n";

	print table(Tr(td({class=>'header'},escapeHTML("Completed web user initiated update of $node")),
				td(button(-name=>'button', -onclick=> ($wantwidget? "get('$formid')" : "submit();" ),
									-value=>'Ok'))));
	print end_form;
	pageEnd() if (getbool($widget,"invert"));
}
