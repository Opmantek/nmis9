#!/usr/bin/perl
#
## $Id: models.pl,v 8.5 2012/01/06 07:09:37 keiths Exp $
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
use Fcntl qw(:DEFAULT :flock);
use Sys;
use Mib;

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

my $wantwidget = (!getbool($Q->{widget},"invert")); # default is thus 1=widgetted.
$Q->{widget} = $wantwidget? "true":"false"; # and set it back to prime urls and inputs

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

# $AU->CheckAccess, will send header and display message denying access if fails.
$AU->CheckAccess("table_models_view","header");

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================


# Model check
# this table defines the actions add,delete,edit based on hash keys
my %MT = (
	'view' => {
		'ablank' => [ # nothing todo
			'^database,db$',
			'^database,db,size,default$',
			'^event,event,default$',
			'^event,event,\w+,\w+$',
			'^(interface|storage),nocollect$',
			'^models,\w+,order$',
			'^system,ping$',
			'^system,power$',
			'^system,sys,standard$',
			'^threshold,name,\w+,select,default$',
			'^threshold,name,\w+,select,\w+,value$'
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
			'^common,class$'
		],
		'delete' => [
			'^database,db,size,\w+$',
			'^models,\w+,order,(\d+|\w+)$',
			'^summary,statstype,\w+$',
			'^summary,statstype,\w+,sumname,\w+$',
			'^threshold,name,\w+$',
			'^common,class,\w+$',
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
		]
	}

);

# what shall we do

if ($Q->{act} eq 'config_model_menu') {				displayModel();
} elsif ($Q->{act} eq 'config_model_add') {			addModel();
} elsif ($Q->{act} eq 'config_model_edit') {		editModel();
} elsif ($Q->{act} eq 'config_model_delete') {		deleteModel();
} elsif ($Q->{act} eq 'config_model_doadd') {		doAddModel(); displayModel();
} elsif ($Q->{act} eq 'config_model_doedit') {		doEditModel(); displayModel();
} elsif ($Q->{act} eq 'config_model_dodelete') {	doDeleteModel(); displayModel();
} else { notfound(); }

sub notfound {
	print header(-status => 400, %$headeropts);
	print "Models: ERROR, act=$Q->{act}, node=$Q->{node}, intf=$Q->{intf}\n";
	print "Request not found\n";
}

exit;

#==================================================================

#
# display the model
#
sub displayModel{
	my %args = @_;

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Modeling", refresh => 86400) if (!$wantwidget);

	my $S = Sys::->new; # create system object and load base Model or nodeModel
	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr(td({class=>'error', colspan=>'9'},"ERROR init, $S->{error}"));
		goto End_page;
	}

	# Base model selected
	if ($model eq 'baseModel') { $model = ''; }

	# load Model if defined
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
			goto End_page;
		}
	}

	my $B = Sys::->new; # create object with only base Model loaded
	$B->init(snmp=>'false');
	
	my $M = $S->mdl; # model info
	my $NI = $S->ndinfo; # node info
	my $NT = loadLocalNodeTable(); # node table
	my $C = loadConfTable(); # configuration table

	my @common = keys %{$S->{mdl}{'-common-'}{class}};

	# start of form
	# the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisModels", -href => url(-absolute => 1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_menu")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget});

	print start_table() ; # first table level

	# header info
	my $ext = getExtension(dir=>'models');
	my $hdmdl = $model ? "Model-$model.$ext" : 
						($node ne "") ? "Model-$NI->{system}{nodeModel}" : "base Model.$ext";

	print Tr(td({class=>'header',colspan=>'4'},"Model - $hdmdl loaded"));

	# row with node names to select
	if ($model ne $pmodel) { $node = $pnode = ""; }
	if ($node ne $pnode) { $model = ""; }
	my @nodes = (sort {lc($a) cmp lc($b)} keys %{$NT});
	@nodes = ('',grep { $AU->InGroup($NT->{$_}{group}) 
													and getbool($NT->{$_}{active}) } @nodes);
	print start_Tr;
	print td({class=>'header', colspan=>'1'},
			"Select node<br>".
				popup_menu(-name=>'node', -override=>'1',
					-values=>\@nodes,
					-default=>$node,
					-onChange => ($wantwidget? "get('nmisModels');" : "submit()" )));

	if ($node ne "" and $model eq "") { $model = $NI->{system}{nodeModel}; } # get nodeModel from node info

	# find all known models, but list each once only - main models listing can include a model 
	# many times under different criteria
	my (@models,%unique);
	foreach my $vndr (keys  %{$B->{mdl}{models}}) {
		foreach my $order (keys  %{$B->{mdl}{models}{$vndr}{order}}) {
			foreach my $mdl (keys %{$B->{mdl}{models}{$vndr}{order}{$order}}) 
			{
				next if ($unique{$mdl});
				push @models,$mdl;
				$unique{$mdl}=1;
			}
		}
	}
	@models = ('','baseModel',sort {uc($a) cmp uc($b)} @models);
	print td({class=>'header', colspan=>'1'},
			"or select node Model<br>".
				popup_menu(-name=>'model', -override=>'1',
					-values=>\@models,
					-default=>$model,
					-onChange => ($wantwidget? "get('nmisModels');" : "submit()" )));

	#if ($model ne $pmodel) { $section = ""; }
	my @sections = ('',sort keys %{$M});
	# and with section names to select
	print td({class=>'header', colspan=>'1'},
			"Select section of Model<br>".
				popup_menu(-name=>'section', -override=>'1',
					-values=>\@sections,
					-default=>$section,
					-onChange => ($wantwidget? "get('nmisModels');" : "submit()" )));

	print td({class=>"header", colspan=>'1'},'Check Model<br>',
			checkbox( -name=>"checkmodel",
					-checked=>"$Q->{checkmodel}",
					-label=>"$Q->{checkmodel}",
					-onChange => ($wantwidget? "get('nmisModels');" : "submit()" )));

	if ($model ne "" and $section ne "" and $Q->{checkmodel} eq 'on') {
		if ((my $err = checkModel(sys=>$S))) {
			print td({class=>'error'},"Error found in section $err<br>$S->{errorfound}");
		}
	}
	print end_Tr;
	print end_table;

	if ($section ne "") {
		print start_table();
		$S->{section} = $section;
		my @output;
		if ( grep(/$section/,@common)) {
			print Tr(td({class=>"header",align=>'center',style=>'background-color:black;',colspan=>'11'},
				'===== Common Model ====='));
		}
		print @{nextSect(sys=>$S,sect=>$M->{$section},index=>0,output=>\@output,hash=>$section)};
		print end_table;
	}

	print hidden(-name=>'pnode', -default=>"$node",-override=>'1');
	print hidden(-name=>'pmodel', -default=>$model,-override=>'1');
	print end_form;

End_page:
	print end_table();
	pageEnd() if (!$wantwidget);
}

# walk through the hash table
sub nextSect {
	my %args = @_;
	my $S = $args{sys};
	my $sect = $args{sect};
	my $id = $args{id};
	my $index = $args{index};
	my $output = $args{output};
	my $hash = $args{hash};

	if ($hash eq 'models') {
		push @$output, start_Tr;
		push @$output, td({class=>"header",colspan=>'1'},$S->{section});
		push @$output, td({class=>"info",colspan=>'9'});
		push @$output, afunc(sys=>$S,hash=>"$hash");
		push @$output, end_Tr;
	}

	foreach my $s (sort keys %{$sect}) {
		if (ref $sect->{$s} eq 'HASH') {
			my $txt = $s;
			my $class = 'header';
			my $errinf;
			if ($hash =~ /^\w+,rrd$/) { ($class,$errinf) = checkType(sys=>$S,type=>$s); }
			if ($hash =~ /^summary,statstype$/) { ($class,$errinf) = checkStatsType(sys=>$S,type=>$s); }
			if ($hash =~ /^\w+,\w+,\w+,snmp$/) { $txt = "Attribute=$s"; } # modify text
			if ($hash =~ /^\w+,rrd,\w+,snmp$/) { $txt = "DS=$s"; } # modify text
			if ($id eq 'sys') { $txt = "Section=$s"; }
			if ($id eq 'rrd') { $txt = "Section=$s"; }
			if ($s eq 'snmp' and $index != 0) { $txt = "Protocol=$s"; }
			push @$output, start_Tr;
			push @$output, td({class=>"header",colspan=>'1'},$S->{section});
			push @$output, td({class=>"header",colspan=>$index}) if $index != 0;
			push @$output, ($errinf eq '') ? td({class=>$class,colspan=>'1'},$txt) :
					td({class=>$class,colspan=>'1',
						onmouseover=>"Tooltip.show(\"$errinf\");",onmouseout=>"Tooltip.hide();"},$txt);
			push @$output, td({class=>"info",colspan=>(8-$index)});
			push @$output, afunc(sys=>$S,hash=>"$hash,$s");
			push @$output, end_Tr;
			nextSect(sys=>$S,sect=>$sect->{$s},id=>$s,index=>($index+1),output=>$output,hash=>"$hash,$s");
			#---
		} elsif (ref $sect->{$s} eq 'ARRAY') {
			push @$output, start_Tr;
			push @$output, td({class=>"header",colspan=>'1'},$S->{section});
			push @$output, td({class=>"header",colspan=>($index)}) if $index != 0;
			push @$output, td({class=>"header",colspan=>'1'},$s);
			push @$output, td({class=>"info",colspan=>(8-$index)});
			push @$output, afunc(sys=>$S,hash=>"$hash,$s");
			push @$output, end_Tr;
			my $cnt = 0;
			foreach my $txt (@{$sect->{$s}}) {
				my $errinf;
				my $class = 'info';
				if ($s eq 'stsname') { ($class,$errinf) = checkStsName(sys=>$S,hash=>$hash,name=>$txt); }
				push @$output, start_Tr;
				push @$output, td({class=>"header",colspan=>'1'},$S->{section});
				push @$output, td({class=>"header",colspan=>($index+1)}) if $index != 0;
				push @$output, ($errinf eq '') ? td({class=>$class,colspan=>(8-$index)},$txt) :
						td({class=>$class,colspan=>(8-$index),
							onmouseover=>"Tooltip.show(\"$errinf\");",onmouseout=>"Tooltip.hide();"},$txt);
				if ((my $func = checkHash(sys=>$S,hash=>"$hash,$s,$cnt"))) {
					push @$output, afunc(sys=>$S,func=>$func,hash=>"$hash,$s,$cnt");
				} else{
					push @$output, afunc(sys=>$S,hash=>"$hash,$s,$cnt");
				}
				push @$output, end_Tr;
				$cnt++;
			}
		} elsif (ref $sect->{$s} ne 'HASH') {
			my $errinf = '';
			my $class = 'info';
			my $result;
			if ($s eq 'control') { ($class,$errinf,$result) = checkControl(sys=>$S,hash=>$hash,value=>$sect->{$s}); } # check value
			if ($s eq 'indexed') { 
				if ( defined $sect->{index_oid} ) {
					($class,$errinf) = checkIndexed(sys=>$S,value=>$sect->{$s},index_oid=>$sect->{index_oid}); 
				}
				else {
					($class,$errinf) = checkIndexed(sys=>$S,value=>$sect->{$s}); 					
				}
			} # check value
			if ($s eq 'oid') { ($class,$errinf) = checkOID(sys=>$S,name=>$sect->{$s}); } # check value
			if ($s eq 'graphtype') { ($class,$errinf) = checkGraphType(sys=>$S,types=>$sect->{$s}); }
			if ($s eq 'healthgraph') { ($class,$errinf) = checkGraphType(sys=>$S,types=>$sect->{$s}); }
			if ($s eq 'threshold' and $index > 1) { ($class,$errinf) = checkThreshold(sys=>$S,hash=>$hash,threshold=>$sect->{$s}); }
			my $txt = my $ss = $s;
			$txt = $ss = "-blank-" if $s eq "";
			if ($s eq 'indexed') { $txt = "Section $s"; } # modify text
			if ($s eq 'option') { $txt = "RRD $s"; }
			if ($s eq 'oid') { $txt = "SNMP $s"; }
			if ($s eq 'control') { $txt = "$s (if true)"; }
			push @$output, start_Tr;
			push @$output, td({class=>"header",colspan=>'1'},$S->{section});
			push @$output, td({class=>"header",colspan=>($index)}) if $index != 0;
			push @$output, td({class=>"header",colspan=>'1',width=>"12%"},$txt);
			push @$output, ($errinf eq '') ? td({class=>$class,colspan=>(8-$index)},"$sect->{$s}${result}") :
						td({class=>$class,colspan=>(8-$index),
							onmouseover=>"Tooltip.show(\"$errinf\");",onmouseout=>"Tooltip.hide();"},"$sect->{$s}${result}");
			push @$output, afunc(sys=>$S,hash=>"$hash,$ss",name=>$sect->{$s});
			push @$output, end_Tr;
		}
	}
	return $output;
}

# which action? (add,edit,delete,snmp)
sub afunc {
	my %args = @_;
	my $S = $args{sys};
	my $hash = $args{hash};
	my $name = $args{name};

	my $func = checkHash($hash);
	my $opt = "&node=$Q->{node}&pnode=$Q->{pnode}&model=$Q->{model}&pmodel=$Q->{pmodel}&section=$Q->{section}&hash=$hash&checkmodel=$Q->{checkmodel}&widget=$Q->{widget}";
	
	if ($AU->CheckAccess("Table_Models_rw","check")) {
		if ($func eq 'ablank') {
			return td({class=>'info'});
		} else {
			my @func = split /,/ ,$func;
			my $line;
			foreach (@func) {
				$line .= a({style=>'text-decoration: underline;',href=>url(-absolute=>1)."?conf=$Q->{conf}&act=config_model_$_$opt"},"$_&nbsp;");
			}
			if ($hash =~ /oid/ and $Q->{node} ne '') {
				$line .= a({style=>'text-decoration: underline;',href=>"snmp.pl?conf=$Q->{conf}&act=snmp_var_menu&node=$Q->{node}&var=$name&go=true"},'snmp');
			}
			return td({class=>'info',nowrap=>undef},$line);
		}
	} else {
		return "";
	}
}

sub checkIndexed {
	my %args = @_;
	my $S = $args{sys};
	my $value = $args{value};
	my $index_oid = $args{index_oid};

	if (getbool($value)) {
		return 'info',''; 
	} 
	else {
		# If this is already an OID don't try to cross check it.
		# checking for 5 levels of numbers as all OID's start with at least 5
		if ( $value =~ /^\d+\.\d+\.\d+.\d+\.\d+/ ) {
			return 'info',''; 
		}
		elsif (name2oid($value)) {
			return 'info',''; 
		} 
		elsif (not name2oid($value) and $index_oid ) {
			return 'info',''; 
		} 
		else {
			$S->{errorfound} = "value $value must be true or var value not found in MIB";
			return 'error',$S->{errorfound};
		}
	}
}


sub checkHash {
	my $hash = shift;
	$hash =~ s/[-_ ]//g ; # only alphabet
	foreach my $func (sort keys %{$MT{view}}) {
		foreach (@{$MT{view}{$func}}) {
			return $func if ($hash =~ /$_/ ) ;
		}
	}
	return 'edit'; # default
}

sub checkOID {
	my %args = @_;
	my $S = $args{sys};
	my $name = $args{name};
	
	# If this is already an OID don't try to cross check it.
	# checking for 5 levels of numbers as all OID's start with at least 5
	if ( $name =~ /^\d+\.\d+\.\d+.\d+\.\d+/ ) {
		return 'info',''; 
	}
	elsif (name2oid($name)) {
		return 'info',''; 
	} else {
		$S->{errorfound} = "oid $name not found in Mib, check NMIS config section mibs";
		return 'error',$S->{errorfound};
	}
}

sub checkGraphType {
	my %args = @_;
	my $S = $args{sys};
	my $types = $args{types};

	my $ext = getExtension(dir=>'models');

	my @types = split /,/,$types;
	foreach my $graph (@types) {
		if ( ! loadTable(dir=>'models',name=>"Graph-$graph") ) {
			$S->{errorfound} = "file does not exists or has bad format or cannot read file models/Graph-$graph.$ext";
			return 'error',$S->{errorfound};
		}
	}
	return 'info','';
}

sub checkThreshold {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $threshold = $args{threshold};
	my $hash = $args{hash};

	my (undef,undef,$tp) = split/,/,$hash;
	if (not exists $M->{stats}{type}{$tp}) {
		$S->{errorfound} = 1;
		return 'error',"type=$tp not found in section stats of Model";
	}
	foreach my $nm (split /,/,$threshold) {
		if ($M->{threshold}{name}{$nm} eq "") {
			$S->{errorfound} = "threshold=$nm not found in section threshold of Model";
			return 'error',$S->{errorfound};
		}
		my $item;
		if (!($item = $M->{threshold}{name}{$nm}{item})) {
			$S->{errorfound} = "no value of item found in name=$nm of section threshold of Model";
			return 'error',$S->{errorfound};
		}
		my $found = 0;
		# look in section stats
		foreach my $ln (@{$M->{stats}{type}{$tp}}) { 
			if ($ln =~ /\:$item\=/) { $found = 1; last;}
		}
		if (!$found) {
			$S->{errorfound} = "no value of threshold=$nm found in type=$tp of section stats of Model";
			return 'error',$S->{errorfound};
		}
	}
	return 'info','';
}

sub checkType {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $type = $args{type};

	if (not exists $M->{database}{type}{$type}) {
		$S->{errorfound} = "type=$type not found in section database of Model";
		return 'error',$S->{errorfound};
	}
	return 'header','';

}

sub checkStsName {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $name = $args{name};
	my $hash = $args{hash};

	my ($sect,undef,$tp) = split/,/,$hash;

	if (not exists $M->{stats}{type}{$tp}) {
		$S->{errorfound} = "type=$tp not found in section stats of Model";
		return 'error',$S->{errorfound};
	}
	# look in section stats
	my $found = 0;
	foreach my $ln (@{$M->{stats}{type}{$tp}}) { 
		if ($ln =~ /\:$name\=/i) { $found = 1; last;}
	}
	if (!$found) {
		$S->{errorfound} = "stsname=$name not found in type=$tp of section stats of Model";
		return 'error',$S->{errorfound};
	}

	return 'info','';
}

sub checkStatsType {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $tp = $args{type};

	if (not exists $M->{stats}{type}{$tp}) {
		$S->{errorfound} = "type=$tp not found in section stats of Model";
		return 'error',$S->{errorfound};
	}
	return 'header','';
}

sub checkControl {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;
	my $string = $args{value};
	my $hash = $args{hash};

	my ($sect,$rrd,$tp) = split/,/,$hash;
	if ($S->{name} ne "" and $sect ne "" and $tp ne "") { 
		return ('info','cannot check because it is index dependent',' (result=unknown)') if ( getbool($M->{$sect}{$rrd}{$tp}{indexed}) and $string =~ /\$i/);
		my $result = $S->parseString(string=>"($string) ? 1:0",sys=>$S,type=>$tp);
		return ('info','',' (<b>result=true</b>)') if $result eq "1";
		return ('info','',' (<b>result=false</b>)') if $result eq "0";
		$S->{errorfound} = 1;
		return ('error',$result," (<b>result=error</b>)");
	}
	return '';
}

sub checkModel {
	my %args = @_;
	my $S = $args{sys};
	my $M = $S->mdl;

	$S->{errorfound} = '';

	foreach my $section (sort keys %{$M}) {
		my @output;
		nextSect(sys=>$S,sect=>$M->{$section},index=>0,output=>\@output); # walk through all  sections
		return $section if $S->{errorfound} ne '' ;
	}
	return "";
}

sub editModel{
	my %args = @_;

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Edit Model", refresh => 86400) if (!$wantwidget);

	$AU->CheckAccess("Table_Models_rw");

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
		goto End_editModel;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
			goto End_editModel;
		}
	}

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels",
									 -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_doedit")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-override => 1, -name => "cancel", -value => "", -id => "cancel");

	print start_table() ; # first table level

	# display edit field
	my $index = 0;
	my $ref = $S->{mdl};
	my $field;
	my @hash = split /,/,$Q->{hash};
	map { s/-blank-// } @hash; # remove this
	print Tr(td({class=>"header",colspan=>'8',align=>'center'},"Edit of Model $Q->{model}"));
	foreach my $h (@hash) {
		$field = $h;
		print start_Tr;
		print td({class=>"header",colspan=>$index}) if $index != 0;
		print td({class=>"header",colspan=>'1'},$h);
		print td({class=>"info",colspan=>(8-$index)});
		print end_Tr;
		$index++ ;
		$ref = $ref->{$h};
		last if ref $ref eq 'ARRAY';
	}
	my $value;
	if (ref $ref eq 'ARRAY') {
		$value = @$ref[$hash[$#hash]];
	} else {
		$value = $ref;
	}

	print Tr(td({colspan=>"$index"}),td({colspan=>(8-$index)},
			textfield(-name=>"value",align=>"left",override=>1,size=>((length $value) * 1.5),value=>"$value")));

	# for some unknown reason the cancel doesn't work if both get() sets a cancel parameter in the url
	# and if there is a cancel input field at the same time; fix for now: enforce the input field,
	# and not let get() make a mess.
	print Tr(td({colspan=>"$index"}), 
					 td(
							 submit(-name=>"button", 
											onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
											-value=>"Edit"),
							 submit(-name=>"button",
											onclick => '$("#cancel").val("true");' 
											.($wantwidget? 'get("nmisModels")' : 'submit()' ),
											-value=>'Cancel')));

	my $info = getHelp($field);
	print Tr(td({class=>'info',colspan=>'8'},$info)) if $info ne "";

	# background values
	print hidden(-name=>'node', -default=>$node,-override=>'1');
	print hidden(-name=>'pnode', -default=>$pnode,-override=>'1');
	print hidden(-name=>'model', -default=>$model,-override=>'1');
	print hidden(-name=>'pmodel', -default=>$pmodel,-override=>'1');
	print hidden(-name=>'section', -default=>$section,-override=>'1');
	print hidden(-name=>'hash', -default=>$Q->{hash},-override=>'1');
	print hidden(-name=>'checkmodel', -default=>$Q->{checkmodel},-override=>'1');


	print end_form;


End_editModel:
	print end_table();
	pageEnd() if (!$wantwidget);
}

sub doEditModel {
	my %args = @_;

	return if (getbool($Q->{cancel}));

	$AU->CheckAccess("Table_Models_rw",'header');

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};
	my $hash = $Q->{hash};
	my $value = $Q->{value};

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		logMsg($S->{error});
		return;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			logMsg($S->{error});
			return;
		}
	}

	my @hash = split /,/,$Q->{hash};
	map { s/-blank-// } @hash;
	my $ref = $S->{mdl};
	my $pref;
	foreach (@hash) {
		$pref = $ref;
		$ref = $ref->{$_};
		last if ref $ref eq 'ARRAY';
	}
	if (ref $ref eq 'ARRAY') {
		@$ref[$hash[$#hash]] = $value;
	} else {
		$pref->{$hash[$#hash]} = $value;
	}
	writeModel(sys=>$S,model=>$model,hash=>$hash);

}


sub deleteModel{
	my %args = @_;

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Delete Model", refresh => 86400) if (!$wantwidget);

	$AU->CheckAccess("Table_Models_rw");

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
		goto End_deleteModel;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
			goto End_deleteModel;
		}
	}

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels",
									 -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_dodelete")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-id => "cancel", -override => 1, -name => "cancel", -value => '');

	print start_table() ; # first table level

	print Tr(td({class=>"header",colspan=>'8',align=>'center'},"Delete part of Model $Q->{model}"));

	# display edit field
	my $index = 0;
	my @hash = split /,/,$Q->{hash};
	print Tr(td({class=>"info",colspan=>'8',align=>'center'},"&nbsp"));
	my $ref = $S->{mdl};
	my $hs;
	foreach my $h (@hash) {
		$hs = $h;
		last if ref $ref->{$h} ne 'HASH';
		last if $index == $#hash;
		$ref = $ref->{$h};
		print start_Tr;
		print td({class=>"header",colspan=>$index}) if $index != 0;
		print td({class=>"header",colspan=>'1'},$h);
		print td({class=>"info",colspan=>(8-$index)});
		print end_Tr;
		$index++;
	}
	print Tr(td({class=>"info",colspan=>$index,align=>'center'}),
				td({class=>"header",colspan=>(8-$index),align=>'center'},
					b("Delete this part of Model $Q->{model}")));

	my @output;
	if (ref $ref->{$hs} eq 'ARRAY') {
		print start_Tr;
		print td({class=>"info",colspan=>$index}) if $index != 0;
		print td({class=>"header",colspan=>'1'},"$hs");
		print td({class=>"info",colspan=>(7-$index)},$ref->{$hs}[$hash[$#hash]]);
		print end_Tr;
		$index++;
	} elsif (ref $ref->{$hs} ne 'HASH') {
		print start_Tr;
		print td({class=>"info",colspan=>($index)});
		print td({class=>"header",colspan=>'1'},$hs);
		print td({class=>'info',colspan=>(8-$index)},$ref->{$hs});
		print end_Tr;
		$index++;
	} else {
		print start_Tr;
		print td({class=>"info",colspan=>$index}) if $index != 0;
		print td({class=>"header",colspan=>'1'},$hs);
		print td({class=>"info",colspan=>(8-$index)});
		print end_Tr;
		$index++;
		print @{nextDelSect(sys=>$S,sect=>$ref->{$hs},index=>$index,output=>\@output)};
	}
	print Tr(td({colspan=>($index-1)}), 
					 td({colspan=>(9-$index),align=>'center',nowrap=>undef},
							submit(-name=>'button',
										 onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
										 -value=>'DELETE'),b('Are you sure ?'),
							submit(-name=>'button',
										 onclick => '$("#cancel").val("true");'
										 .($wantwidget? 'get("nmisModels")' : 'submit()' ),
										 -value=>'Cancel')));

	# background values
	print hidden(-name=>'node', -default=>$node,-override=>'1');
	print hidden(-name=>'pnode', -default=>$pnode,-override=>'1');
	print hidden(-name=>'model', -default=>$model,-override=>'1');
	print hidden(-name=>'pmodel', -default=>$pmodel,-override=>'1');
	print hidden(-name=>'section', -default=>$section,-override=>'1');
	print hidden(-name=>'hash', -default=>$Q->{hash},-override=>'1');
	print hidden(-name=>'checkmodel', -default=>$Q->{checkmodel},-override=>'1');
	print end_form;

End_deleteModel:
	print end_table();
	pageEnd() if (!$wantwidget)
}

sub nextDelSect {
	my %args = @_;
	my $S = $args{sys};
	my $sect = $args{sect};
	my $index = $args{index};
	my $output = $args{output};

	foreach my $s (sort keys %{$sect}) {
		if (ref $sect->{$s} eq 'ARRAY') {
			push @$output, start_Tr;
			push @$output, td({class=>"info",colspan=>($index)});
			push @$output, td({class=>"header",colspan=>'1'},$s);
			push @$output, td({class=>"info",colspan=>(7-$index)});
			push @$output, end_Tr;
			my $cnt = 0;
			foreach my $txt (@{$sect->{$s}}) {
				push @$output, start_Tr;
				push @$output, td({class=>"info",colspan=>($index+1)});
				push @$output, td({class=>"header",colspan=>'1'});
				push @$output, td({class=>"info",colspan=>(7-$index)},$txt);
				push @$output, end_Tr;
				$cnt++;
			}
		} elsif (ref $sect->{$s} ne 'HASH') {
			push @$output, start_Tr;
			push @$output, td({class=>"info",colspan=>($index)});
			push @$output, td({class=>"header",colspan=>'1',width=>"12%"},$s);
			push @$output, td({class=>'blank',colspan=>(8-$index)},$sect->{$s});
			push @$output, end_Tr;
		}
	}

	foreach my $s (sort keys %{$sect}) {
		if (ref $sect->{$s} eq 'HASH') {
			push @$output, start_Tr;
			push @$output, td({class=>"info",colspan=>$index}) ;
			push @$output, td({class=>"header",colspan=>'1'},$s);
			push @$output, td({class=>"info",colspan=>(8-$index)});
			push @$output, end_Tr;
			nextDelSect(sys=>$S,sect=>$sect->{$s},index=>($index+1),output=>$output);
		}
	}

	return $output;
}


sub doDeleteModel {
	my %args = @_;

	return if getbool($Q->{cancel});

	$AU->CheckAccess("Table_Models_rw",'header');

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};
	my $hash = $Q->{hash};
	my $value = $Q->{value};

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		logMsg($S->{error});
		return;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			logMsg($S->{error});
			return;
		}
	}

	my @hash = split /,/,$Q->{hash};
	map { s/-blank-// } @hash;
	my $ref = $S->{mdl};
	my $hs;
	my $index= 0 ;
	foreach my $h (@hash) {
		$hs = $h;
		last if ref $ref->{$h} ne 'HASH';
		last if $index == $#hash;
		$ref = $ref->{$h};
		$index++;
	}

	if (ref $ref->{$hs} eq 'ARRAY') {
		splice(@{$ref->{$hs}},$hash[$#hash],1);
		delete $ref->{$hs} if scalar @{$ref->{$hs}} eq 0;
	} else{
		delete $ref->{$hs};
	}

	writeModel(sys=>$S,model=>$model,hash=>$hash);

}

sub addModel{
	my %args = @_;

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};
	my $hash = $Q->{hash};


	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Add Model", refresh => 86400) if (!$wantwidget);

	$AU->CheckAccess("Table_Models_rw");

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
		goto End_addModel;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			print Tr(td({class=>'error', colspan=>'9'},$S->{error}));
			goto End_addModel;
		}
	}

	# start of form, explanation of href-vs-hiddens see previous start_form
	print start_form(-id=>"nmisModels", 
					-href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $C->{conf})
			. hidden(-override => 1, -name => "act", -value => "config_model_doadd")
			. hidden(-override => 1, -name => "widget", -value => $Q->{widget})
			. hidden(-override => 1, -name => "cancel", -value => "", -id => "cancel");

	print start_table() ; # first table level

	# display edit field
	my $index = 0;
	my @hash = split /,/,$hash;
	print Tr(td({class=>"info",colspan=>'8',align=>'center'},"&nbsp"));
	my $ref = $S->{mdl};
	foreach my $h (@hash) {
		last if ($h =~ /^\d+$/);
		$ref = $ref->{$h};
		print start_Tr;
		print td({class=>"header",colspan=>$index}) if $index != 0;
		print td({class=>"header",colspan=>'1'},$h);
		print td({class=>"info",colspan=>(8-$index)});
		print end_Tr;
		$index++;
	}
	print Tr(td({class=>"info",colspan=>$index,align=>'center'}),
				td({class=>"header",colspan=>(8-$index),align=>'center'},
					b("Add next part to Model $Q->{model}")));
	my @field;
	my @help;
	my $hsh = $hash;
	$hsh =~ s/[-_ ]//g;

	if ($hsh =~ /^\w+,rrd$/) { @field = qw(type graphtype ds oid); }
	elsif ($hsh =~ /^\w+,sys$/) { @field  = qw(type control attribute oid); }
	elsif ($hsh =~ /^\w+,rrd,\w+,snmp$/) { @field = qw(ds oid option calculate); }
	elsif ($hsh =~ /^\w+,sys,\w+,snmp$/) { @field = qw(attribute oid); }
	elsif ($hsh =~ /^\w+,rrd,\w+,snmp,\w+$/) { @field = qw(oid option replace calculate value); }
	elsif ($hsh =~ /^\w+,sys,\w+,snmp,\w+$/) { @field = qw(oid replace value title calculate format check); }
	elsif ($hsh =~ /^\w+,(rrd|sys),\w+,snmp,\w+,replace$/) { @field = qw(replace value); }
	elsif ($hsh =~ /^\w+,rrd,\w+$/) { @field = qw(graphtype control indexed threshold); }
	elsif ($hsh =~ /^interface,sys,standard$/) { @field = qw(indexed); }
	elsif ($hsh =~ /^\w+,sys,\w+$/) { @field = qw(control indexed); }
	elsif ($hsh =~ /^database,db,size$/) { @field = qw(type step_day step_week step_month step_year rows_day rows_week rows_month rows_year); }
	elsif ($hsh =~ /^database,type$/) { @field = qw(type filescript); }
	elsif ($hsh =~ /^event,event$/) { @field = qw(event role level logging); }
	elsif ($hsh =~ /^event,event,\w+$/) { @field = qw(role level logging); }
	elsif ($hsh =~ /^heading,graphtype$/) { @field = qw(graphtype headerscript); }
	elsif ($hsh =~ /^threshold,name,\w+,select$/ 
			or $hsh =~ /^alerts,\w+,\w+,threshold$/) { @field = qw(order fatal critical major minor warning); }
	elsif ($hsh =~ /^threshold,name,\w+,select,\w+$/) { @field = qw(control); }
	elsif ($hsh =~ /^threshold,name$/) { @field = qw(name eventdescr item order control fatal critical major minor warning); }
	elsif ($hsh =~ /^stats,type$/) { @field = qw(type rrdopt); }
	elsif ($hsh =~ /^stats,type,\w+$/) { @field = qw(rrdopt); }
	elsif ($hsh =~ /^stats,type,\w+,\d+$/) { @field = qw(rrdopt); }
	elsif ($hsh =~ /^summary,statstype$/) { @field = qw( statstype sumname stsname); }
	elsif ($hsh =~ /^summary,statstype,\w+,sumname$/) { @field = qw( sumname stsname); }
	elsif ($hsh =~ /^summary,statstype,\w+,sumname,\w+,stsname$/) { @field = qw(stsname); }
	elsif ($hsh =~ /^summary,statstype,\w+,sumname,\w+,stsname,\d+$/) { @field = qw(stsname); }
	elsif ($hsh =~ /^models$/) { @field = qw(vendor order nodetype string); }
	elsif ($hsh =~ /^models,\w+$/) { @field = qw(order nodetype string); }
	elsif ($hsh =~ /^common,class$/) { @field = qw(class common-model); }

	
	foreach my $f (@field) {
		print Tr(td({colspan=>"$index"}),td({class=>"header",colspan=>'1'},"$f"),
				td({class=>"info",colspan=>(7-$index)},textfield(-name=>"$f",align=>"left",override=>1,size=>'50')));
		push @help,$f;
	}

	print Tr(td({colspan=>"$index"}), 
					 td(submit(-name=>"button",
										 onclick => ($wantwidget? "get('nmisModels');" : "submit()" ),
										 -value=>"Add"),
							submit(-name=>"button",
										 onclick => '$("#cancel").val("true");' 
										 .($wantwidget? 'get("nmisModels")' : 'submit()' ),
										 -value=>"Cancel")));

	foreach (@help) {
		my $info = getHelp($_);
		print Tr(td({class=>'blank',colspan=>'8'},$info)) if $info ne "";
	}

	# background values
	print hidden(-name=>'node', -default=>$node,-override=>'1');
	print hidden(-name=>'pnode', -default=>$pnode,-override=>'1');
	print hidden(-name=>'model', -default=>$model,-override=>'1');
	print hidden(-name=>'pmodel', -default=>$pmodel,-override=>'1');
	print hidden(-name=>'section', -default=>$section,-override=>'1');
	print hidden(-name=>'hash', -default=>$Q->{hash},-override=>'1');
	print hidden(-name=>'checkmodel', -default=>$Q->{checkmodel},-override=>'1');
	print end_form;

End_addModel:
	print end_table();
	pageEnd() if (!$wantwidget)
}


sub doAddModel {
	my %args = @_;

	return if getbool($Q->{cancel});

	$AU->CheckAccess("Table_Models_rw",'header');

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $model = $Q->{model};
	my $pmodel = $Q->{pmodel};
	my $section = $Q->{section};
	my $hash = $Q->{hash};

	my $S = Sys::->new; # create system object
	if (!($S->init(name=>$node,snmp=>'false'))) {
		logMsg($S->{error});
		return;
	}
	if ($node eq "" and $model ne "") {
		if (!($S->loadModel(model=>"Model-$model"))) {
			logMsg($S->{error});
			return;
		}
	}

	my $hsh = $hash;
	my @hsh = split /,/,$hsh;
	map { s/-blank-// } @hsh;
	my $ref = $S->{mdl};
	my $pref;
	my $hs;
	my $index= 0 ;
	foreach my $h (@hsh) {
		$pref = $ref;
		last if ref $ref eq 'ARRAY';
		$ref = $ref->{$h};
		$index++;
	}

	$hsh =~ s/[-_ ]//g;
	if ($hsh =~ /^\w+,rrd$/) {
		if ($Q->{type} ne "" and $Q->{ds} ne "" and $Q->{oid} ne "") {
			$ref->{lc $Q->{type}}{graphtype} = $Q->{graphtype} if $Q->{graphtype} ne "";
			$ref->{lc $Q->{type}}{snmp}{$Q->{ds}}{oid} = $Q->{oid};
		}
	}
	if ($hsh =~ /^\w+,sys$/) {
		if ($Q->{type} ne "" and $Q->{attribute} ne "" and $Q->{oid} ne "") {
			$ref->{lc $Q->{type}}{snmp}{$Q->{attribute}}{oid} = $Q->{oid};
		}
	}
	if ($hsh =~ /^\w+,rrd,\w+,snmp$/) {
		if ($Q->{ds} ne "" and $Q->{oid} ne "") {
			$ref->{$Q->{ds}}{oid} = $Q->{oid};
		}
	}
	if ($hsh =~ /^\w+,sys,\w+,snmp$/) {
		if ($Q->{attribute} ne "" and $Q->{oid} ne "") {
			$ref->{$Q->{attribute}}{oid} = $Q->{oid};
		}
	}
	if ($hsh =~ /^\w+,(rrd|sys),\w+,snmp,\w+$/) {
		$ref->{oid} = $Q->{oid} if $Q->{oid} ne "";
		$Q->{title} =~ s/\x00//g if $Q->{title} ne ""; # I dont understand why
		$ref->{title} = $Q->{title} if $Q->{title} ne "";
		$ref->{option} = $Q->{option} if $Q->{option} ne "";
		$ref->{calculate} = $Q->{calculate} if $Q->{calculate} ne "";
		$ref->{check} = $Q->{check} if $Q->{check} ne "";
		$ref->{format} = $Q->{format} if $Q->{format} ne "";
		$ref->{replace}{$Q->{replace}} = $Q->{value} if $Q->{value} ne "";
	}
	if ($hsh =~ /^\w+,(rrd|sys),\w+$/) { 
		$ref->{control} = $Q->{control} if $Q->{control} ne "";
		$ref->{indexed} = lc $Q->{indexed} if $Q->{indexed} ne "";
		$ref->{graphtype} = lc $Q->{graphtype} if $Q->{graphtype} ne "";
		$ref->{threshold} = $Q->{threshold} if $Q->{threshold} ne "";
	}
	if ($hsh =~ /^\w+,(rrd|sys),\w+,snmp,\w+,replace$/) {
		$ref->{$Q->{replace}} = $Q->{value} if $Q->{value} ne "";
	}
	if ($hsh =~ /^database,db,size$/) {
		if ($Q->{type} ne "" and $Q->{type} ne "default") {
			$ref->{lc$Q->{type}}{lc $Q->{rows_day}} = $Q->{rows_day} || $ref->{default}{rows_day};
			$ref->{lc $Q->{type}}{lc $Q->{rows_week}} = $Q->{rows_week} || $ref->{default}{rows_week};
			$ref->{lc $Q->{type}}{lc $Q->{rows_month}} = $Q->{rows_month} || $ref->{default}{rows_month};
			$ref->{lc $Q->{type}}{lc $Q->{rows_year}} = $Q->{rows_year} || $ref->{default}{rows_year};
			$ref->{lc $Q->{type}}{lc $Q->{step_day}} = $Q->{step_day} || $ref->{default}{step_day};
			$ref->{lc $Q->{type}}{lc $Q->{step_week}} = $Q->{step_week} || $ref->{default}{step_week};
			$ref->{lc $Q->{type}}{lc $Q->{step_month}} = $Q->{step_month} || $ref->{default}{step_month};
			$ref->{lc $Q->{type}}{lc $Q->{step_year}} = $Q->{step_year} || $ref->{default}{step_year};
		}
	}
	if ($hsh =~ /^database,type$/) {
		if ($Q->{type} ne "") {
			$ref->{lc $Q->{type}} = $Q->{filescript};
		}
	}
	if ($hsh =~ /^event,event$/) { 
		if ($Q->{event} ne "" and $Q->{role} ne "") {
			$ref->{lc $Q->{event}}{lc $Q->{role}}{level} = $Q->{level};
			$ref->{lc $Q->{event}}{lc $Q->{role}}{logging} = $Q->{logging};
		}
	}
	if ($hsh =~ /^event,event,\w+$/) { 
		if ($Q->{role} ne "") {
			$ref->{lc $Q->{role}}{level} = $Q->{level};
			$ref->{lc $Q->{role}}{logging} = $Q->{logging};
		}
	}

	if ($hsh =~ /^heading,graphtype$/) {
		if ($Q->{graphtype} ne "") {
			$ref->{lc $Q->{graphtype}} = $Q->{headerscript};
		}
	}

	if ($hsh =~ /^threshold,name$/) {
		if ($Q->{name} ne "" and $Q->{item} ne "" and $Q->{order} ne "") {
			$ref->{$Q->{name}}{item} = $Q->{item};
			$ref->{$Q->{name}}{event} = $Q->{eventdescr};
			$ref->{$Q->{name}}{select}{$Q->{order}}{control} = $Q->{control} if $Q->{control} ne "";
			$ref->{$Q->{name}}{select}{$Q->{order}}{value}{fatal} = $Q->{fatal} || $ref->{default}{value}{fatal};
			$ref->{$Q->{name}}{select}{$Q->{order}}{value}{critical} = $Q->{critical} || $ref->{default}{value}{critical};
			$ref->{$Q->{name}}{select}{$Q->{order}}{value}{major} = $Q->{major} || $ref->{default}{value}{major};
			$ref->{$Q->{name}}{select}{$Q->{order}}{value}{minor} = $Q->{minor} || $ref->{default}{value}{minor};
			$ref->{$Q->{name}}{select}{$Q->{order}}{value}{warning} = $Q->{warning} || $ref->{default}{value}{warning};
		}
	}
	if ($hsh =~ /^threshold,name,\w+,select$/) {
		if ($Q->{order} ne "") {
			$ref->{$Q->{order}}{value}{fatal} = $Q->{fatal} || $ref->{default}{value}{fatal};
			$ref->{$Q->{order}}{value}{critical} = $Q->{critical} || $ref->{default}{value}{critical};
			$ref->{$Q->{order}}{value}{major} = $Q->{major} || $ref->{default}{value}{major};
			$ref->{$Q->{order}}{value}{minor} = $Q->{minor} || $ref->{default}{value}{minor};
			$ref->{$Q->{order}}{value}{warning} = $Q->{warning} || $ref->{default}{value}{warning};
		}
	}
	if ($hsh =~ /^threshold,name,\w+,select,\w+$/) {
		$ref->{control} = $Q->{control};
	}
	if ($hsh =~ /^stats,type$/) {
		if ($Q->{type} ne "") {
			$ref->{lc $Q->{type}} = [$Q->{rrdopt}];
		}
	}
	if ($hsh =~ /^stats,type,\w+$/) {
		push @$ref,$Q->{rrdopt};
	}
	if ($hsh =~ /^stats,type,\w+,\d+$/) {
		##my @d = (splice(@{$ref},0,$hash[$#hash],1);
		splice(@{$ref},$hsh[$#hsh],0,$Q->{rrdopt});
	}
	if ($hsh =~ /^summary,statstype$/) {
		if ($Q->{statstype} ne "" and $Q->{sumname} ne "") {
			$ref->{lc $Q->{statstype}}{name}{lc $Q->{sumname}}{stsname} = [$Q->{stsname}];
		}
	}
	if ($hsh =~ /^summary,statstype,\w+,sumname$/) {
		if ($Q->{sumname} ne "") {
			$ref->{lc $Q->{sumname}}{stsname} = [$Q->{stsname}];
		}
	}
	if ($hsh =~ /^summary,statstype,\w+,sumname,\w+,stsname$/) {
		push @$ref,$Q->{stsname};
	}
	if ($hsh =~ /^summary,statstype,\w+,sumname,\w+,stsname,\d+$/) {
		splice(@{$ref},$hsh[$#hsh],0,$Q->{stsname});
	}
	if ($hsh =~ /^models$/) {
		if ($Q->{vendor} ne "" and $Q->{order} ne "" and $Q->{nodetype} ne "") {
			$ref->{$Q->{vendor}}{order}{$Q->{order}}{$Q->{nodetype}} = $Q->{string};
		}
	}
	if ($hsh =~ /^models,\w+$/) {
		if ($Q->{order} ne "" and $Q->{nodetype} ne "") {
			$ref->{order}{$Q->{order}}{$Q->{nodetype}} = $Q->{string};
		}
	}

	if ($hsh =~ /^common,class$/) { 
		if ($Q->{class} ne "" and $Q->{'common-model'} ne "") {
			if ( existFile(dir=>'models',name=>"Common-$Q->{'common-model'}") ) {
				$ref->{lc $Q->{class}}{'common-model'} = $Q->{'common-model'};
			} else {
				my $ext = getExtension(dir=>'models');
				logMsg("ERROR common Model file models/Common-$Q->{'common-model'}.$ext does not exist");
			}
		}
	}

	writeModel(sys=>$S,model=>$model,hash=>$hash);

}

#
# write modified common Model and selected Model
#
sub writeModel {
	my %args = @_;
	my $S = $args{sys};
	my $model = $args{model};
	my $hash = $args{hash};
	if ($model eq '') {
		# baseModel, no common classes included
		writeHashtoModel(name=>'Model',data=>$S->{mdl});
	} else {
		my %mdl;
		# are we writing a common class of the Model
		my @hsh = split /,/,$hash;
		my $class = $hsh[0];
		my @common = keys %{$S->{mdl}{'-common-'}{class}};
		if ( grep(/$class/,@common)) {
			# write this updated common class to disk
			my $name = 'Common-'.${class};
			$mdl{$class} = $S->{mdl}{$class};
			writeTable(dir=>'models',name=>$name,data=>\%mdl);
		}
		# now the selected Model without the common parts
		%mdl = ();
		for my $k (keys %{$S->{mdl}}) {
			if (!grep(/$k/,@common)) {
				$mdl{$k} = $S->{mdl}{$k};
			}
		}
		writeTable(dir=>'models',name=>"Model-$model",data=>\%mdl);
	}
}

#=============================================================================

sub getHelp {
	my $help = shift;
	
	my $ext = getExtension(dir=>'models');

	my %help = (
		'type' => 			'Format: string<br>'.
								'The name must be unique in this section<br>'.
								'This name create a relation between configurations in the next sections:<br>'.
								'Starting in a section (node, interface, calls, cbqos_in or cbqos_out) for RRD declaration '.
								'is must also be declared in section database '.
								'to declare the script for generating the filename of the RRD database. If there '.
								'is also declared a threshold in this section then there must also declared rrd rules '.
								'in section stats.',
		'graphtype' =>		'Format: comma separated list<br>'.
								'List of graph names. There must be a description file exist in '.
								'models/Graph-\'graphtype\'.$ext for every graph.',
		'ds' =>				'Format: string, max. length is 18 characters<br>'.
								'The name of the RRD Data Source.',
		'attribute' => 		'Format: string<br>'.
								'The name of attribute.',
		'control' =>		'Format: expression<br>'.
								'An operator test will be executed on this rule. If the result is true then the oid\'s are executed.'.
								'<br>The next names of variable can be used, they are replaced at runtime:'.
									'<ul>'.
									'<li>$node</li>'.
									'<li>$nodeModel</li>'.
									'<li>$nodeType</li>'.
									'<li>$nodeVendor</li>'.
									'<li>$sysObjectName</li>'.
									'<li>$ifDescr</li>'.
									'<li>$ifType</li>'.
									'<li>$ifSpeed</li>'.
									'<li>$InstalledModems</li>'.
									'</ul>'.
								'At the Node page the value of $sysObjectName is presented under the name sysName.<br>'.
								'example: $sysObjectName =~ /7300|2620/',
		'indexed' =>		'Format: true or var value of MIB<br>'.
								'Defined this subsection as true if used by code with use of indexing.',
		'oid' =>			'Format: SNMP iod, must contain a name<br>'.
								'The oid name of the snmp var. This value must exist in the OID files and this file name declared in nmis.conf (full_mib).',
		'replace' =>		'Format: string or number<br>'.
								'Optional. The result of the snmp call can be replaced by a given value.<br>'.
								'If there is no replace defined then \'unknown\' is used.<br>'.
								'If \'unknown\' is not defined then the original value is left.',
		'value' =>			'Format: string or number<br>'.
								'Value which will replace the original snmp result.',
		'option' =>			'Format: string<br>Optional. For creation of the RRD Data Source the option value is used.<br>'.
								'If not defined the default will be used: \'GAUGE,U:U\' ',
		'filescript' =>		'Format: string<br>Script to define the RRD filename.<br>'.
								'The next names of variable can be used, they are replaced at runtime:<br>'.
									'<ul>'.
									'<li>$node</li>'.
									'<li>$nodeModel</li>'.
									'<li>$nodeType</li>'.
									'<li>$roleType</li>'.
									'<li>$nodeVendor</li>'.
									'<li>$ifDescr</li>'.
									'<li>$ifType</li>'.
									'<li>$item</li>'.
									'</ul>',
		'healthgraph' =>	'Format: comma separated list<br>'.
								'List of graph(type)s which are active in Node health page.<br>'.
								'There must be a description file exist in model/Graph-\'graphtype\'.$ext for every grpah.',
		'nodeType' =>		'Format: string<br>'.
								'Type of node: router, switch, server, firewall, generic.',
		'rrdopt' =>			'RRD option rule.<br>'.
								'Name \$database may be used for rrd file specification',
		'threshold' =>		'Format: comma separated list of names<br>'.
								'Optional. Threshold names must be declared in the rrdopt rules of the section stats.',
		'level' =>			'Format: Fatal, Critical, Major, Minor, Warning or Normal<br>'.
								'Value of level',
		'role' =>			'Format: core, access or distribution<br>'.
								'Name of role.',
		'logging' =>		'Format: true or false<br>'.
								'Logging of an event',
		'event' =>			'Format: string<br>'.
								'Name of event',
		'eventdescr' =>		'Format: string<br>'.
								'Description of Proactive event.',
		'poll' =>			'Format: number<br>'.
								'The value of 300 is NMIS dependent.',
		'hbeat' =>			'Format: number<br>'.
								'The value of 900 is NMIS dependent.',
		'order' =>			'Format: number<br>'.
								'Order of processing, starting at lowest number.',
		'item' =>			'Format: string<br>'.
								'This name must also be declared in stats.',
		'name' =>			'Format: string<br>'.
								'Name of this threshold.',
		'fatal' =>			'Format: number<br>'.
								'This number can be a normal value or percent, depending of the rules in stats. '.
								'If the value of warning is higher then fatal then thresholds for higher being good and lower being bad.',
		'statstype' =>		'Format: string<br>'.
								'Name of type in section stats.',
		'sumname' =>		'Format: string<br>'.
								'Name of parameter in summary file.',
		'stsname' =>		'Format: string<br>'.
								'Name of parameter (...:stsname=...) in rrd rules in section stats.',
		'nodetype' =>		'Format: router | switch | server | firewall | generic<br>'.
								'Type of node.',
		'calculate' =>		'Format: string<br>'.
								'Optional. Calculate string<br>'.
								'${r} contains input value',
		'check' =>			'Format: string<br>'.
								'Optional. Name of an existing method<br>'.
								'The method is called with the attribute name',
		'format' =>			'Format: string<br>'.
								'Optional. Printf format string<br>'.
								'without quotes',
		'title' =>			'Format: string<br>'.
								'Optional. Title is the header text of the Node and Interface pages.<br>'.
								'If title is declared then the value is displayed in the page.'
	);


	if (exists $help{$help}) {
		return ul(li($help),$help{$help});
	}
	return;

}

