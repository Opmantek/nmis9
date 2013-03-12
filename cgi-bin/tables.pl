#!/usr/bin/perl
#
## $Id: tables.pl,v 8.12 2012/09/18 01:40:59 keiths Exp $
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
use csv;
use Net::hostent;
use Socket;
use Data::Dumper;

use DBfunc;

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

# Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

my $formid = $Q->{table} ? "nmis$Q->{table}" : "nmisTable";

my $widget = "true";
if ($Q->{widget} eq 'false' ) {	
	$widget = "false"; 
}

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
	if ($C->{$db} eq 'true' ) {
		$T = DBfunc::->select(table=>$table); # full table
	} else { 
		$T = loadTable(dir=>'conf',name=>$table);
	}
			
	if (!$T and $msg ne 'false') {
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
	pageStartJscript(title => "View Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");
	
	my $LNT;
	if ( $table eq "Nodes" ) {
		$LNT = loadLocalNodeTable(); # load from file or db
	}

	print <<EOF;
<script>
clearInterval();
</script>
EOF

	my $bt;
	my $T;
	$T = loadReqTable(table=>$table); # load requested table

	my $CT;
	return if (!($CT = loadCfgTable(table=>$table))); # load configuration of table

	print start_table;

	my $url = url(-absolute=>1)."?%conf=$Q->{conf}&table=$table";

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
					print td({class=>'info Plain'},$T->{$k}{$item}) if $display;
				}
			}
		}
		
		if ($AU->CheckAccess("Table_${table}_rw","check")) {
			$bt = a({href=>"$url&act=config_table_edit&key=$k&widget=$widget"},'&nbsp;edit').
					a({href=>"$url&act=config_table_delete&key=$k&widget=$widget"},'&nbsp;delete');
		} else {
			$bt = '';
		}
		print td({class=>'info Plain'},a({href=>"$url&act=config_table_view&key=$k&widget=$widget"},'view'),$bt) if $display;
		print end_Tr if $display;
	}

	print end_table;

	pageEnd() if ($widget eq "false");

}

sub viewTable {

	my $table = $Q->{table};
	my $key = $Q->{key};

	#start of page
	print header($headeropts);
	pageStartJscript(title => "View Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration

	if ($Q->{act} =~ /delete/) {
		 print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$C->{conf}&act=config_table_dodelete&table=$table&key=$key&widget=$widget");
		}
	if ($Q->{act} =~ /view/) {
			 print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$C->{conf}&act=config_table_menu&table=$table&key=$key&widget=$widget");
	}
		
	print start_table;
	print Tr(td({class=>'header',colspan=>'2'},"Table $table"));

	# print items of table
	for my $ref ( @{$CT}) { # trick for order of header items
		for my $item (keys %{$ref}) {
			print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
				td({class=>'info Plain'},$T->{$key}{$item}));
		}
	}

	if ($Q->{act} =~ /delete/) {
		print Tr(td('&nbsp;'),td(	
				button(-name=>"button",onclick=>"get('".$formid."');",-value=>"Delete"),"Are you sure",
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Cancel")));
	}
	if ($Q->{act} =~ /view/) {
		print Tr(td('&nbsp;'),td(	
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Ok"))); # bypass
	}

	print end_table;
	print end_form;
	pageEnd() if ($widget eq "false");
}

sub showTable {

	my $table = $Q->{table};
	my $key = $Q->{key};
	my $node = $Q->{node};
	my $found = 0;

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Show Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_view");

	my $T;
	return if (!($T = loadReqTable(table=>$table))); # load requested table

	my $CT = loadCfgTable(table=>$table); # load table configuration

	print createHrButtons(node=>$node, refresh=>$Q->{refresh}, widget=>$widget);

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
						print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
							td({class=>'info Plain'},$T->{$t}{$item}));
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
	pageEnd() if ($widget eq "false");
}

sub editTable {

	my $table = $Q->{table};
	my $key = $Q->{key};

	my @hash; # items of key

	#start of page
	print header($headeropts);
	pageStartJscript(title => "Edit Table $table") if ($widget eq "false");

	$AU->CheckAccess("Table_${table}_rw");

	my $T;
	return if (!($T = loadReqTable(table=>$table,msg=>'false')) and $Q->{act} =~ /edit/); # load requested table

	my $CT = loadCfgTable(table=>$table);

	my $func = ($Q->{act} eq 'config_table_add') ? 'doadd' : 'doedit';
	my $button = ($Q->{act} eq 'config_table_add') ? 'Add' : 'Edit';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=config_table_${func}&table=${table}&widget=$widget";

	# start of form
	print start_form(-name=>"$formid",-id=>"$formid",-href=>"$url");

	print start_table;
	print Tr(th({class=>'title',colspan=>'2'},"Table $table"));

	for my $ref ( @{$CT}) { # trick for order of header items
		for my $item (keys %{$ref}) {
			print Tr(td({class=>'header',align=>'center'},$ref->{$item}{header}),
				eval { my $line;
					if ($ref->{$item}{display} =~ /key/) {
						push @hash,$item;
					}
					if ($func eq 'doedit' and $ref->{$item}{display} =~ /key/) {
						$line .= td({class=>'header'},$T->{$key}{$item});
						$line .= hidden(-name=>$item, -default=>$T->{$key}{$item},-override=>'1'); 
					} elsif ($ref->{$item}{display} =~ /text/) {
						my $value = ($T->{$key}{$item} or $func eq 'doedit') ? $T->{$key}{$item} : $ref->{$item}{value}[0];
						$line .= td(textfield(-name=>"$item",size=>'35',value=>$value));
					} elsif ($ref->{$item}{display} =~ /pop/) {
						$line .= td(popup_menu(-name=>"$item", -style=>'width:100%;',
								-values=>$ref->{$item}{value},
								-default=>$T->{$key}{$item}));
					} elsif ($ref->{$item}{display} =~ /scrol/) {
						my @items = split(/,/,$T->{$key}{$item});
						$line.= td(scrolling_list(-name=>"$item", -multiple=>'true',
								-style=>'width:100%;',
								-size=>'6',
								-values=>$ref->{$item}{value},
								-default=>\@items));
					} 
					return $line;
				});
		}
	}

	print hidden(-name=>'hash', -default=>join(',',@hash),-override=>'1');
	print Tr(td('&nbsp;'),
				td( eval {
					if ($table eq 'Nodes') {
						return button(-name=>"button",onclick=>"javascript:get('".$formid."','update');", -value=>"$button and Update Node");
					} else { return "&nbsp;"; }
				},
				button(-name=>"button",onclick=>"get('".$formid."');", -value=>$button),
				button(-name=>'button',onclick=>"get('".$formid."','cancel');",-value=>"Cancel")));

	print end_table;
	print end_form;
	pageEnd() if ($widget eq "false");
}

sub doeditTable {
	my $table = $Q->{table};
	my $hash = $Q->{hash};

	return 1 if $Q->{cancel} eq 'true';

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table,msg=>'false');

	my $CT = loadCfgTable(table=>$table);

	# combine key from values, values separated by underscrore
	my $key = join('_', map { $Q->{$_} } split /,/,$hash );
	$key = lc($key) if $table !~ /$C->{tables_case_sensitive_keys}/; # let key of table Nodes equal to name

	# test on existing key
	if ($Q->{act} =~ /doadd/) {
		if (exists $T->{$key}) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,"Key $key already exists in table"));
			return 0;
		}
		if ($key eq '') {
			print header($headeropts);
			print Tr(td({class=>'error'} ,"Field \'$hash\' must be filled in table $table"));
			return 0;
		}
	}

	my $V;
	# store new values in table
	for my $ref ( @{$CT}) {
		for my $item (keys %{$ref}) {
			$T->{$key}{$item} = stripSpaces($Q->{$item});
			$V->{$item} = stripSpaces($Q->{$item});
		}
	}

	my $db = "db_".lc($table)."_sql";
	if ($C->{$db} eq 'true' ) {
		my $stat;
		$V->{index} = $key; # add this column
		if ($Q->{act} =~ /doadd/) {
			$stat = DBfunc::->insert(table=>$table,data=>$V);
		} else {
			$stat = DBfunc::->update(table=>$table,data=>$V,index=>$key);
		}
		if (!$stat) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,DBfunc::->error()));
			return 0;
		}
	} else {
		writeTable(dir=>'conf',name=>$table,data=>$T);
	}

	# do update node with new values
	if ($table eq 'Nodes') {
		# check host address
		if ($T->{$key}{host} eq '') {
			print header($headeropts);
			print Tr(td({class=>'error'} ,"Field \'host\' must be filled in table $table"));
			return 0;
		}
		### test the DNS for DNS names, if no IP returned, error exit
		if ( $T->{$key}{host} !~ /\d+\.\d+\.\d+\.\d+/ ) {
			my $address = resolveDNStoAddr($T->{$key}{host});
			if ( $address !~ /\d+\.\d+\.\d+\.\d+/ or !$address ) {
				print header($headeropts);
				print Tr(td({class=>'error'} ,"ERROR, cannot resolve IP address \'$T->{$key}{host}\'<br>".
									"Please correct this item in table $table"));
				return 0;
			}
		}
		print STDERR "DEBUG: doeditTable->cleanEvent key=$key\n";
		cleanEvent($key,"tables.pl.editNodeTable");
		if ($Q->{update} eq 'true') {
			doNodeUpdate(node=>$key);
			return 0;
		}
	}

	return 1;
}

sub dodeleteTable {
	my $table = $Q->{table};
	my $key = $Q->{key};

	return 1 if $Q->{cancel} eq 'true';

	$AU->CheckAccess("Table_${table}_rw",'header');

	my $T = loadReqTable(table=>$table);
	my $db = "db_".lc($table)."_sql";
	if ($C->{$db} eq 'true' ) {
		if (!(DBfunc::->delete(table=>$table,index=>$key))) {
			print header({-type=>"text/html",-expires=>'now'});
			print Tr(td({class=>'error'} ,DBfunc::->error()));
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
}

sub doNodeUpdate {
	my %args = @_;
	my $node = $args{node};

	# note that this will force nmis.pl to skip the pingtest as we are a non-root user !!
	# for now - just pipe the output of a debug run, so the user can see what is going on !
	
	# now run the update and display 
	print header($headeropts);
	pageStartJscript(title => "Run update on $node") if ($widget eq "false");
	
	print "<pre>\n";
	print "Running update on node $node\n\n\n";
	
	open(PIPE, "$C->{'<nmis_bin>'}/nmis.pl type=update node=$node debug=1 2>&1 |"); 
	select((select(PIPE), $| = 1)[0]);			# unbuffer pipe
	select((select(STDOUT), $| = 1)[0]);			# unbuffer pipe

	while ( <PIPE> ) {
		print ;
	}
	close(PIPE);
	print "\n</pre>\n";

	print start_form(-id=>"$formid",
					-href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_table_menu&table=$Q->{table}&widget=$widget");

	print table(Tr(td({class=>'header'},"Completed web user initiated update of $node"),
				td(button(-name=>'button',-onclick=>"get('".$formid."')",-value=>'Ok'))));
	print end_form;
	pageEnd() if ($widget eq "false");
}

