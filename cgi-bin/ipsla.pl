#!/usr/bin/perl
#
## $Id: ipsla.pl,v 8.9 2012/04/28 00:59:36 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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
#*****************************************************************************
# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

#
use Time::ParseDate;
use RRDs;
use NMIS;
use func;
use csv;
use rrdfunc;
use Fcntl qw(:DEFAULT :flock);

use Data::Dumper;
$Data::Dumper::Indent = 1;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = CGI->new; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# NMIS Authentication module
use Auth;
my $user;
my $privlevel = 5;
my $logoutButton;

# variables used for the security mods
my $headeropts = {}; #{type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS config

if ($AU->Require) {
	#2011-11-14 Integrating changes from Till Dierkesmann
	if($AU->{auth_method_1} eq "" or $AU->{auth_method_1} eq "apache") {
		 $Q->{auth_username}=$ENV{'REMOTE_USER'};
		 $AU->{username}=$ENV{'REMOTE_USER'};
		 $user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
		 $logoutButton = qq|disabled="disabled"|;
	}

	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
	$privlevel = $AU->{privlevel};
} else {
	$user = 'Nobody';
	$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
	$logoutButton = qq|disabled="disabled"|;
}


#A global var for handling running in a widget or not.
my $widget = 0;

# ehg mar 2009 - added to facilitate master/slave communications, preserving host/port
###########
my $urlcgi = $q->url(-relative => 1);	# Use relative url for all our script href - in effect our scriptname
my $urlbase = $q->url(-base=>1) . $C->{'<url_base>'};	#  full url for static pages, img, gifs etc.
my $urlcgibase = $q->url(-base=>1) . $C->{'<cgi_url_base>'};	# full url cgi script base - rarely used for explicit host/script
my $urlhost = $q->url(-base=>1);	# same for script base directory, use for handover to other scripts in same directory, appended by nmis::config var
###########

# Break the queary up for the names
my $func = lc $q->param('func');
my $pnode = $q->param('pnode');
my $ppnode = $q->param('ppnode');
my $pcom = $q->param('pcom');
my $rnode = $q->param('rnode');
my $prnode = $q->param('prnode');
my $rcom = $q->param('rcom');
my $saddr = $q->param('saddr');
my $raddr = $q->param('raddr');
my $url = $q->param('url');
my $dport = $q->param('dport');
my $history = $q->param('history');
my $pnodechart = $q->param('pnodechart');
my $type = $q->param('type');
my $graph = $q->param('graph');
my $debug = $q->param('debug');
my $start = $q->param('start') ;
my $end = $q->param('end');
my $date_start = $q->param('date_start');
my $date_end = $q->param('date_end');
my $graphx = $q->param('graph.x');
my $graphy = $q->param('graph.y');
my $item = $q->param('item');
my $view = $q->param('view');
my $entry = $q->param('entry');
my $optype = $q->param('optype');
my $poptype = $q->param('poptype');
my $attr = $q->param('attr');
my $freq = $q->param('freq');
my $lsr = $q->param('lsr');
my $owner = $q->param('owner');
my $dsize = $q->param('dsize');
my $tout = $q->param('tout');
my $tos = $q->param('tos');
my $vrfy = $q->param('vrfy');
my $key = $q->param('key');
my $intvl = $q->param('intvl');
my $pkts = $q->param('pkts');
my $deldb = $q->param('deldb');
my $tport = $q->param('tport');
my $tas = $q->param('tas');
my $codec = $q->param('codec');
my $factor = $q->param('facor');
my $vrf = $q->param('vrf');

my $dump_data = Dump;
$q->delete_all();
my $msg; # common message

my ($graphret, $xs, $ys, $ERROR);
my $width = 600; # of rtt chart
my $height = 250; # of rtt chart

my $nmis_url = a({href=>"$urlhost$C->{nmis}?file=$Q->{conf}"},img({alt=>"NMIS Dash", src=>"$C->{nmis_icon}", border=>"0"}));
my $back_url = a({href=>referer()},img({alt=>"Back", src=>"$C->{back_icon}", border=>"0"}));
my $help_url = a({href=>"$urlbase/ipsla.pod.html"},img({alt=>"Help", src=>"$C->{help_icon}", border=>"0"}));

my %operation = (
	'echo'=>{'responder'=>'router,server',
			'attr'=>'frequence,request-data-size,timeout,tos,verify-data,source-addr,vrf',
			'frequence'=>[5,10,30,60,120,300,600],
			'default'=>{ 'freq'=>30,'tout'=>'2','dsize'=>'28' }
			 },
	'pathEcho'=>{'responder'=>'router,server',
			'attr'=>'frequence,timeout,tos,source-addr,vrf',
			'frequence'=>[60,120,300,600],
			'default'=>{'freq'=>300,'tout'=>'5','dsize'=>'28' }
			 },
	'tcpConnect'=>{'responder'=>'router,server,dport,community,vrf',
			'attr'=>'frequence,timeout,tos',
			'frequence'=>[60,120,300,600],
			'default'=>{'freq'=>30,'tout'=>'5' }
			 },
	'udpEcho'=>{'responder'=>'router,server,dport,community',
			'attr'=>'frequence,request-data-size,timeout,tos,source-addr,vrf',
			'frequence'=>[5,10,30,60],
			'default'=>{'freq'=>30,'tout'=>'5','dsize'=>'16','dport'=>'100'}
			},
	'jitter'=>{'responder'=>'router,snmp,community',
			'attr'=>'frequence,request-data-size,timeout,tos,interval,num-pkts,tport,source-addr,vrf',
			'frequence'=>[5,10,30,60],
			'default'=>{'freq'=>'30','tport'=>'16384','tout'=>'5','dsize'=>'32','pkts'=>'100','intvl'=>'20'}
			},
	'jitter-voip'=>{'responder'=>'router,snmp,community',
			'attr'=>'frequence,request-data-size,timeout,tos,interval,num-pkts,tport,codec,factor,source-addr,vrf',
			'frequence'=>[5,10,30,60],
			'default'=>{'freq'=>'30','tport'=>'16384','tout'=>'5','dsize'=>'32','pkts'=>'100','intvl'=>'20',
				'codec'=>'1','factor'=>'0'}
			},
	'http'=>{'responder'=>'server',
			'attr'=>'frequence,timeout,tos',
			'frequence'=>[5,10,30,60],
			'default'=>{'freq'=>30,'tout'=>'5'}
			},
	'dns'=>{'responder'=>'server',
			'attr'=>'frequence,timeout,tas',
			'frequence'=>[5,10,30,60],
			'default'=>{'freq'=>30,'tout'=>'5','tas'=>'www.cisco.com'}
			},
	'dhcp'=>{'responder'=>'server',
			'attr'=>'frequence,timeout',
			'frequence'=>[10,30,60],
			'default'=>{'freq'=>30,'tout'=>'5'}
			}
	);
$operation{'echo-stats'} = $operation{'echo'};
$operation{'dhcp-stats'} = $operation{'dhcp'};
$operation{'dns-stats'} = $operation{'dns'};
$operation{'jitter-stats'} = $operation{'jitter'};
$operation{'jitter-voip-stats'} = $operation{'jitter-voip'};
$operation{'http-stats'} = $operation{'http'};
$operation{'pathEcho-stats'} = $operation{'pathEcho'};
$operation{'udpEcho-stats'} = $operation{'udpEcho'};
$operation{'tcpConnect-stats'} = $operation{'tcpConnect'};


# get RTTcfg from /var
my %RTTcfg = readVartoHash("ipslacfg");

# get config database values if view graph is active
if ( getbool($view) and $key ne "") {
	$pnode = $RTTcfg{$key}{pnode};
	$optype = $RTTcfg{$key}{optype};
	$saddr = $RTTcfg{$key}{saddr};
	$rnode = $RTTcfg{$key}{rnode};
	$raddr = $RTTcfg{$key}{raddr};
	$dport = $RTTcfg{$key}{dport};
	$tout = $RTTcfg{$key}{timeout};
	$history = $RTTcfg{$key}{history};
	$freq = $RTTcfg{$key}{frequence};
	$lsr = $RTTcfg{$key}{lsrpath};
	$dsize = $RTTcfg{$key}{reqdatasize};
	$tos = $RTTcfg{$key}{tos};
	$intvl = $RTTcfg{$key}{interval};
	$pkts = $RTTcfg{$key}{numpkts};
	$tport = $RTTcfg{$key}{tport};
	$codec = $RTTcfg{$key}{codec};
	$factor = $RTTcfg{$key}{factor};
	$vrf = $RTTcfg{$key}{vrf};
	$url = $RTTcfg{$key}{url};
}

$tos = 0 if not $tos;

# define hash key
my $tnode = ($rnode eq "other") ? $raddr : $rnode;
my $dest = ($optype =~ /http/ and $url =~ m:.*//(.*)(/|$).*: ) ? $1 : $tnode ;
my $nno = "${pnode}_${dest}_${optype}_${tos}"; # key for hash table %RTTcfg

# store typed community
if ($ppnode ne $pnode) { $pcom = $RTTcfg{$pnode}{community};}
if ($prnode ne $rnode) { $rcom = $RTTcfg{$rnode}{community};}
if ($pcom ne "*********" and $pcom ne "" and $pnode ne "") {
	$RTTcfg{$pnode}{community} = $pcom;
	$pcom = "*********";
	writeHashtoVar("ipslacfg",\%RTTcfg) if (!getbool($view)); # store com config on disk
}
if ($rcom ne "*********" and $rcom ne "" and $rnode ne "") {
	$RTTcfg{$rnode}{community} = $rcom;
	$rcom = "*********";
	writeHashtoVar("ipslacfg",\%RTTcfg) if (!getbool($view)); # store com config on disk
}

# what shall we do

if ($func eq "graph") {
	&displayRTTgraph($key); exit; # ready
}

startIPSLApage();

if ($func eq "start") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		runRTTstart();
	}
} elsif ($func eq "stop") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		runRTTstop();
	}
} elsif ($func eq "remove") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		&runRTTremove();
	}
}

if ( $AU->CheckAccess('ipsla_menu') ) {
	displayIPSLAmenu();
}

endIPSLApage();

exit;

sub startIPSLApage {
	my $header = "NMIS IPSLA Monitor";
	#my $header2 = "$back_url$nmis_url$help_url $header";
	my $nmisicon = "<a target=\"nmis\" href=\"$C->{'nmis'}?conf=$Q->{conf}\"><img class='logo' src=\"$C->{'nmis_icon'}\"/></a>";
	my $header2 = "$header <a href=\"$ENV{SCRIPT_NAME}\"><img src=\"$C->{'nmis_home'}\"/></a>";

	#ipsla.pl is NOT parsing this $Q properly!
	my $portalCode = loadPortalCode(conf=>$Q->{conf});

	# Javascripts
	my $jscript = getJscript();

	print header({-type=>"text/html",-expires=>'now'});
	if ( not $widget ) {
		#Don't print the start_html, but we do need to get the javascript in there.
		print start_html(-title=>$header,
			-xbase=>&url(-base=>1)."$C->{'<url_base>'}",
			-meta=>{'keywords'=>'network management NMIS'},
			-head=>[
					meta({-http_equiv=>'refresh', -content=>"$C->{'page_refresh_time'}"}),
					Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"})
				],
			-script=>$jscript
			);
		#print &do_dash_banner($auth->Require, $user->user) ;
	}
	else {
		print script($jscript);
	}

	$portalCode = $nmisicon if not $portalCode;

	print start_table({class=>"noborder"}) ;
	print Tr(td({class=>"nav", colspan=>"4", width=>"100%"},
		"<a href='http://www.opmantek.com'><img height='30px' width='30px' class='logo' src=\"$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png\"/></a>",
		"<span class=\"title\">$header2</span>",
		$portalCode,
		"<span class=\"right\"><a id=\"menu_help\" href=\"$C->{'nmis_docs_online'}\"><img src=\"$C->{'nmis_help'}\"/></a> User: $user Auth: Level$privlevel</span>",
	));

}

sub endIPSLApage {
	print end_table, end_html;
}


sub displayIPSLAmenu {

	my @output;
	my $fields;
	my %interfaceTable;
	my @saddr = ("");

	# get node info from /var, this file is produced by nmis.pl type=update
	my %RTTInfo = readVartoHash("nmis-nodeinfo"); # node info table generated by bin/nmis.pl
	my (@pnode,@nodes);
	@pnode = @nodes = grep { $_ if $RTTInfo{$_}{nodeModel} eq "CiscoRouter" } sort keys %RTTInfo;
	@pnode = @nodes = sort keys %RTTInfo if scalar @nodes == 0; # depends on nmis.pl code
	unshift @pnode, "";

	if ($pnode eq "") { $rnode = $optype = $pcom = $rcom = $pcom = $raddr = $view = $url = $key = $vrf = ""; }
	if ($optype =~ /http/ and $url eq "") { $url = "http://"; }

	if ($poptype ne $optype and !getbool($view)){
		$freq = $lsr = $tout = $tos = ""; $vrfy = 0; $attr = "on"  # defaults
	}

	# create source address list of probe node
	if ( $pnode ) {
		my $S = Sys::->new; # get system object
		$S->init(name=>$pnode,snmp=>'false'); # load node info and Model if name exists
		my $II = $S->ifinfo;
		foreach my $k (sort keys %{$II} ) {
			if (ref($II->{$k}) eq "HASH" and $II->{$k}{ifAdminStatus} eq "up" and $II->{$k}{ipAdEntAddr1} ne "" ) {
				push (@saddr,$II->{$k}{ipAdEntAddr1});
			}
		}
	}

	# start of form
	print start_form( -method=>'get', -name=>"rtt", -action=>url(), -onSubmit=>"return check(this,event)");

	# row with Probe Node, Type, Source address and Community
	push @output, start_Tr;
	push @output, th({class=>"title", width=>"25%"},
			"Probe node ".
				popup_menu(-name=>"pnode", -override=>'1',
					-values=>\@pnode,
					-default=>"$pnode",
					-title=>"node to run probe",
					-onChange=>"return noview(this);"));

	my @optypes = ($pnode ne "") ? ('',sort keys %operation) : ('');
	push @output, th({class=>"title", width=>"25%", nowrap=>"nowrap"},"Operation type ".
			popup_menu(-name=>"optype", -override=>'1',
				-values=>\@optypes,
				-default=>"$optype",
				-title=>"type of probe",
				-onChange=>"return noview(this);"));

	if ($operation{$optype}{attr} =~ /source-addr/ ) {
		push @output, th({class=>"title", width=>"25%", nowrap=>"nowrap"}, "Source address ".
				popup_menu(-name=>"saddr", -override=>'1',
					-values=>\@saddr,
					-default=>"$saddr",
					-title=>"optional",
					-onChange=>"return noview(this);"));
	} else {
		push @output, th({class=>'title', width=>"25%", nowrap=>"nowrap"}, "&nbsp;");
	}

	# dont use CGI password field
	push @output, th({class=>"title", width=>"25%", nowrap=>"nowrap"}, eval {
				if ($pnode ne "") { return "SNMP&nbsp;community&nbsp;R/W ".
					textfield(-name=>"pcom",-override=>1,
						-title=>"community string of probe node to send snmp commands",
						-value=>"$pcom");
				} else { return "&nbsp;" }});
	push @output, end_Tr;
	print @output;

	@output = ();
	if ($optype ne "") {
		push @output, start_Tr;
		# row with Responder Nodeor URL and optional IP address and Community
		if ($optype =~ /http/) {
			push @output, td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"}, "Url ".
					textfield(-name=>'url',-override=>1,
						-title=>"specify an URL to get a page",
						-value=>"$url"));
		} else {
			my @choices = ($operation{$optype}{responder} =~ /server/) ? ("","other") : ("") ;
			@choices = (@choices,@nodes) if ($operation{$optype}{responder} =~ /router/);
			push @output, td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"}, "Responder node ".
					popup_menu(-name=>"rnode", -override=>'1',
						-values=>\@choices,
						-default=>"$rnode",
					-onChange=>"return noview(this);"));
		}
		$fields = 1;

		if ($rnode eq "other") {
			push @output, td({class=>"info Plain"}, "Name or IP address ".
				textfield(-name=>"raddr",-override=>1,
					-value=>"$raddr"));
			$fields++;
		}

		if ($operation{$optype}{responder} =~ /dport/) {
			$dport = $operation{$optype}{default}{dport} if $dport eq "";
			push @output, td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"}, "Destination port ".
				textfield(-name=>"dport",-align=>"right",-size=>'3',-override=>1,
					-value=>"$dport"));
			$fields++;
		}

		if ($operation{$optype}{responder} =~ /community/ and $rnode ne "other") {
			# dont use CGI password field
			push @output,td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"}, "SNMP&nbsp;community&nbsp;R/W ".
					textfield(-name=>'rcom',-override=>1,
						-title=>"community string of responder node to send snmp commands",
						-value=>"$rcom"));
			$fields++;
		}
		foreach ($fields..3){ push @output, td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},'&nbsp;'); }
		push @output, end_Tr;

		print @output;

		# display attributes
		displayRTTattr($nno);

		# row with History, Nodecharts and Submit button
		print Tr(
			td({class=>"info Plain"}, eval {
				if ($RTTcfg{$nno}{status} =~ /running|error/i ) {
					my $s = ($RTTcfg{$nno}{history} > 1) ? "s" : "";
					return "History of values for $RTTcfg{$nno}{history} week$s" ;
				} elsif ($optype =~ /stats/i) {
					return "History of values&nbsp;".
						popup_menu(-name=>"history",
						-values=>[qw/1 2 4 8 16 32 64 128/],
						-default=>"$history",
						-title=>"size of RRD database depends",
						-labels=>{'1'=>'1 week','2'=>'2 weeks','4'=>'4 weeks','8'=>'8 weeks',
								'16'=>'16 weeks','32'=>'32 weeks','64'=>'64 weeks','128'=>'128 weeks'});
				} else {
					return "History of values&nbsp;".
						popup_menu(-name=>"history",
						-values=>[qw/1 2 4 8/],
						-default=>"$history",
						-title=>"size of RRD database depends",
						-labels=>{'1'=>'1 week','2'=>'2 weeks','4'=>'4 weeks','8'=>'8 weeks'});
				}}),
			td({class=>"info Plain"},
				"View attributes&nbsp;".
					checkbox( -name=>"attr",
						-checked=>"$attr",
						-label=>'',
						-onChange=>'JavaScript:this.form.submit()')),
			td({class=>"info Plain"}, eval {
				if (getbool($view)) {
						return "View node charts&nbsp;".
							checkbox( -name=>"pnodechart",
								-checked=>"$pnodechart",
								-label=>'',
								-onChange=>'JavaScript:this.form.submit()');
				} else {return "&nbsp;"} }),
			td({class=>"info Plain"}, eval {
				# button for command the daemon to start,stop and remove
				my $button;
				if ($pnode ne "" and $optype ne "" and ($rnode ne "" or $optype =~ /http/)) {
					if ($RTTcfg{$nno}{status} eq "") {
						$button = "start" ;
					} elsif ($RTTcfg{$nno}{status} =~ /running/i ) {
						$button = "stop" ;
					} elsif ($RTTcfg{$nno}{status} =~ /error|stopped|start requested/i) {
						$button = "remove" ;
					}
				}
				return 	"Collect&nbsp;".submit(-name=>"func",
					-value=>uc $button)})
			);
	}

	# probes and status to display ?
	my @probes = ();
	my %probes = {};
	my %attr = {};
	my $url = url()."?conf=$Q->{conf}&view=true&key=";
	foreach my $key ( sort keys %RTTcfg ) {
		if ($RTTcfg{$key}{pnode} ne "") {
			if ($RTTcfg{$key}{status} eq "error") {
				$attr{$key}{class} = "error";
				$msg = "one of the probes is in error state";
			}
			push @probes,$key;
			$probes{$key} = "$RTTcfg{$key}{select} ($RTTcfg{$key}{status})";
		}
	}

	if (@probes or $msg ne ""){
		# probe select and status/error info
		print Tr(
			td({class=>"header",colspan=>"2",width=>"50%"}, "Select probe for graph&nbsp;".
				popup_menu(-name=>"probes", -override=>'1',
					-values=>["",@probes],
					-default=>$key,
					-labels=>\%probes,
					-attributes=>\%attr,
					-onChange=>"return gotoURL(\"$url\");")), eval {
				# display status msg
				my $message;
				my $class = "header";
				if ($pnode ne "") {
					if ($RTTcfg{$nno}{message} ne "") {
						$class = "Error";
						$message = "&nbsp;$RTTcfg{$nno}{message}";
					} elsif ( !getbool($C->{daemon_ipsla_active}) ) {
						$class = "Error";
						$message = "&nbsp; parameter daemon_ipsla_active in nmis.conf is not set on true to start the daemon ipslad.pl";
					} elsif (
							(not -r "$C->{'<nmis_var>'}/ipslad.pid")
							#or ( -M "$C->{'<nmis_var>'}/ipslad.pid" > 0.0015)
					) {
						$class = "Error";
						$message = "&nbsp;daemon ipslad.pl is not running";
					} elsif ($msg ne "") {
						$class = "Error";
						$message = $msg; # local msg
					} else {
						$message = "$RTTcfg{$nno}{starttime}";
					}
				} elsif ($msg ne "") {
					$message = $msg; $class = "error"; # local msg
				}
				$message = scalar @probes." probes are active" if $message eq "" and scalar @probes > 1;
				$message = "1 probe is active" if $message eq "" and scalar @probes == 1;
				return td({class=>$class,colspan=>"2", width=>"50%"},"$message");
			}
		);
	}


	# display node charts ?
	if (getbool($view) and $pnodechart eq "on") { displayRTTnode(); } # node charts

	# background values
	print hidden(-name=>'file', -default=>$Q->{conf},-override=>'1');
	print hidden(-name=>'ppnode', -default=>$pnode,-override=>'1');
	print hidden(-name=>'prnode', -default=>$rnode,-override=>'1');
	print hidden(-name=>'poptype', -default=>$optype,-override=>'1');
	print hidden(-name=>'deldb', -default=>'false',-override=>'1');
	print hidden(-name=>'view', -default=>$view,-override=>'1');
	print hidden(-name=>'key', -default=>$key,-override=>'1') if (getbool($view));

	print end_form;

	# start of second form
	print start_form( -method=>'get', -name=>"data", -action=>url() );

	# display data
	if (getbool($view) and $RTTcfg{$nno}{status} eq "running") { displayRTTdata($nno); }

	# background values
	print hidden(-name=>'file', -default=>$Q->{conf},-override=>'1');
	print hidden(-name=>'start',-default=>"$start",-override=>'1');
	print hidden(-name=>'end', -default=>$end,-override=>'1');
	print hidden(-name=>'view', -default=>'true',-override=>'1');
	print hidden(-name=>'key', -default=>$key,-override=>'1');
	print hidden(-name=>'item', -default=>$item,-override=>'1');

	print end_form;

}

sub runCfgUpdate {

	writeHashtoVar("ipslacfg",\%RTTcfg); # store config on disk

	# let the daemon unlink the database
	return if ($RTTcfg{$nno}{func} =~ /stop|remove/
						 and getbool($RTTcfg{$nno}{deldb}));

	# run bin/ipslad.pl for accept modified configuration
	# if this system failed then the detach process ipslad.pl does it later.
	my $lines = `$C->{'<nmis_bin>'}/ipslad.pl type=update`;

	# get new values of daemon
	%RTTcfg = readVartoHash("ipslacfg");
}

sub runRTTstart {

	# already running ?
	if ($RTTcfg{$nno}{status} eq "running") {
		$pnode = $attr = "";
		return;
	}

	if ($RTTcfg{$pnode}{community} eq "") {
		$msg = "No community specified for probe node $pnode";
	#	$pnode = "";
		return;
	}

	if ($rnode eq "other" and $raddr eq "") {
		$msg = "No address specified for responder node";
		$pnode = "";
		return;
	}

	if ($pnode ne "" and $RTTcfg{$nno}{func} eq "" and $RTTcfg{$nno}{status} !~ /start|running|remove|error/) {
		$RTTcfg{$nno}{func} = "start";
		$RTTcfg{$nno}{select} = "${pnode}::${dest}::${optype}::${tos}";
		$RTTcfg{$nno}{pnode} = $pnode; # probe node
		$RTTcfg{$nno}{optype} = $optype; # probe type
		$RTTcfg{$nno}{saddr} = $saddr; # source address
		$RTTcfg{$nno}{rnode} = $rnode; #
		$RTTcfg{$nno}{raddr} = $raddr if $raddr ne ""; #
		$RTTcfg{$nno}{tnode} = $tnode if $tnode ne ""; # responder node
		$RTTcfg{$nno}{dport} = $dport if $dport ne ""; # destination port
		$RTTcfg{$nno}{url} = $url if $url ne "";
		$RTTcfg{$nno}{history} = $history;
		$RTTcfg{$nno}{frequence} = $freq;
		$RTTcfg{$nno}{lsrpath} = $lsr if $lsr ne "";
		$RTTcfg{$nno}{reqdatasize} = $dsize if $dsize ne "";
		$RTTcfg{$nno}{timeout} = $tout if $tout ne "";
		$RTTcfg{$nno}{tos} = $tos if $tos ne "";
		$RTTcfg{$nno}{interval} = $intvl if $intvl ne "";
		$RTTcfg{$nno}{numpkts} = $pkts if $pkts ne "";
		$RTTcfg{$nno}{tport} = $tport if $tport ne "";
		$RTTcfg{$nno}{tas} = $tas if $tas ne "";
		$RTTcfg{$nno}{codec} = $codec if $codec ne "";
		$RTTcfg{$nno}{factor} = $codec if $factor ne "";
		$RTTcfg{$nno}{vrf} = $vrf if $vrf ne "";
		$RTTcfg{$nno}{deldb} = $deldb; # delete database
		$RTTcfg{$nno}{verify} = ($vrfy == 0) ? 2 : $vrfy;
		my $n = $nno; $n =~ s/[\._]/-/g ;
		$RTTcfg{$nno}{database} = "$C->{database_root}/misc/ipsla-${n}.rrd";

		$RTTcfg{$nno}{status} = "start requested";
		$RTTcfg{$nno}{message} = "";

		$pnode = $pcom = $rnode = $rcom = $view = $attr = "";
		runCfgUpdate();
	}
}

sub runRTTstop {

	if ($RTTcfg{$nno}{func} eq "" and $RTTcfg{$nno}{status} =~ /start|running|error/) {

		$RTTcfg{$nno}{func} = "stop";
		$RTTcfg{$nno}{status} = "stop requested";
		$RTTcfg{$nno}{message} = "";
		$RTTcfg{$nno}{deldb} = $deldb;

		$pnode = $pcom = $rnode = $rcom = $view = $attr = "";
		runCfgUpdate();
	}
}

sub runRTTremove {

	return if not exists $RTTcfg{$nno}{pnode};
	if ($RTTcfg{$nno}{func} eq "" and $RTTcfg{$nno}{pnode} ne "" and
			$RTTcfg{$nno}{status} !~ /remove|running|start/) {

		$RTTcfg{$nno}{func} = "remove";
		$RTTcfg{$nno}{status} = "remove requested";
		$RTTcfg{$nno}{message} = "";
		$RTTcfg{$nno}{deldb} = $deldb;
		runCfgUpdate();
	} else {
		delete $RTTcfg{$nno} ;
		writeHashtoVar("ipslacfg",\%RTTcfg);
	}
	$pnode = $pcom = $rnode = $rcom = $view = $attr = $url = "";
}


# display the attributes depending of probe type
sub displayRTTattr {

	my $nno = shift;
	my $field_cnt = 0;

	# it's the lazy way
	if ($optype ne "" ) {
		print start_Tr if $attr eq "on";

		if ($operation{$optype}{attr} =~ /frequence/) {
			$freq = $operation{$optype}{default}{freq} if $freq eq "";
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},
					"interval&nbsp;".
						popup_menu(-name=>"freq", -override=>'1',
							-values=>$operation{$optype}{frequence},
							-default=>"$freq")."&nbsp;sec.");
				$field_cnt++;
			} else {
				print hidden(-name=>'freq', -default=>$freq, -override=>'1');
			}
		}
		if ($operation{$optype}{attr} =~ /lsr-path/) {
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"lsr path, ip addr.&nbsp;".
							textfield(-name=>'lsr',-override=>1,
							-value=>"$lsr"));
				$field_cnt++;
			} else {
				print hidden(-name=>'lsr', -default=>$lsr, -override=>'1');
			}
		}
		if ($operation{$optype}{attr} =~ /request_data_size/) {
			$dsize = $operation{$optype}{default}{dsize} if $dsize eq "";
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"req data size".
						textfield(-name=>'dsize',-override=>'1',-size=>'2',-align=>'right',
							-title=>"optional, range 1 - 1500",
							-value=>"$dsize"));
				$field_cnt++;
			} else {
				print hidden(-name=>'dsize', -default=>$dsize, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /timeout/) {
			$tout = $operation{$optype}{default}{tout} if $tout eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", align=>"right", width=>"25%", nowrap=>"nowrap"},"timeout&nbsp;".
					popup_menu(-name=>"tout", -override=>'1',
						-values=>["",1,2,3,4,5,10,20,30],
						-default=>"$tout"));
				$field_cnt++;
			} else {
				print hidden(-name=>'tout', -default=>$tout, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /tport/) {
			$tport = $operation{$optype}{default}{tport} if $tport eq "";
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"port&nbsp;".
						textfield(-name=>'tport',-override=>'1',-size=>'2',-align=>'right',
							-title=>"even number in range 16384 - 32766 or 49152 - 65534",
							-value=>"$tport"));
				$field_cnt++;
			} else {
				print hidden(-name=>'tport', -default=>$tport, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /tos/) {
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", align=>"right", width=>"25%", nowrap=>"nowrap"},"tos&nbsp;".
					popup_menu(-name=>"tos", -override=>'1',
						-values=>["",(0..255)],
						-title=>"optional, defines the IP ToS byte",
						-default=>"$tos"));
				$field_cnt++;
			} else {
				print hidden(-name=>'tos', -default=>$tos, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /codec/) {
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"codec&nbsp;".
					popup_menu(-name=>"codec", -override=>'1',
						-values=>[qw/1 2 3/],
						-labels=>{'1'=>'g711ulaw','2'=>'g711alaw','3'=>'g729a'},
						-default=>"$codec"));
				$field_cnt++;
			} else {
				print hidden(-name=>'codec', -default=>$codec, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /factor/) {
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"ICPIF factor&nbsp;".
					popup_menu(-name=>"factor", -override=>'1',
						-values=>[qw/0 5 10 20/],
						-default=>"$factor"));
				$field_cnt++;
			} else {
				print hidden(-name=>'factor', -default=>$factor, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /verify-data/) {
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},
					"verify data&nbsp;".
						popup_menu(-name=>"vrfy", -override=>'1',
							-values=>[2,1],
							-labels=>{'2' => 'no','1' => 'yes'},
							-default=>"$vrfy"));
				$field_cnt++;
			} else {
			print hidden(-name=>'vrfy', -default=>$vrfy, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /interval/) {
			$intvl = $operation{$optype}{default}{intvl} if $intvl eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"interval&nbsp;".
						textfield(-name=>'intvl',-override=>1,-size=>'2',-align=>'right',
							-title=>"time in msec. between packets",
							-value=>"$intvl")." msec");
				$field_cnt++;
			} else {
			print hidden(-name=>'intvl', -default=>$intvl, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /num-pkts/) {
			$pkts = $operation{$optype}{default}{pkts} if $pkts eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"# of packets&nbsp;".
						textfield(-name=>'pkts',-override=>1,-size=>'2',-align=>'right',
							-title=>"number of packets per probe operation, range 1 to 60000",
							-value=>"$pkts"));
				$field_cnt++;
			} else {
			print hidden(-name=>'pkts', -default=>$pkts, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /tas/) {
			$tas = $operation{$optype}{default}{tas} if $tas eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"dns addr. of request&nbsp;".
						textfield(-name=>'tas',-override=>1,
							-title=>"can be in IP address format or a hostname",
							-value=>"$tas"));
				$field_cnt++;
			} else {
			print hidden(-name=>'tas', -default=>$tas, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /vrf/) {
			$vrf = $operation{$optype}{default}{vrf} if $vrf eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"vrf name&nbsp;".
						textfield(-name=>'vrf',-override=>1,
							-title=>"optional vrf name, max 30 char",
							-value=>"$vrf"));
				$field_cnt++;
			} else {
			print hidden(-name=>'vrf', -default=>$vrf, -override=>'1');
			}
		}
		if ($attr eq "on" and $RTTcfg{$nno}{entry} ne "") {
			print td({class=>"info Plain",align=>"center", width=>"25%", nowrap=>"nowrap"},"probe entry is $RTTcfg{$nno}{entry}");
			$field_cnt++;
		}
		if ($attr eq "on") {
			foreach ($field_cnt..3) {print td({class=>"header"},"&nbsp;"); $field_cnt++;}
			print end_Tr if $field_cnt > 0;
		}
	}

}

sub displayRTTnode {

	if ($pnode ne "") {
		print Tr( hprint(["CPU","CPU Utilisation","cpu"]),hprint(["Mem","Router Memory","mem-router"]));
	}


#==
	sub hprint {
		my $aref = shift;
		my $glamount = $C->{graph_amount};
		my $glunits = $C->{graph_unit};
		my $win_width = $C->{graph_width} + 100;
		my $win_height = $C->{graph_height} + 320;
		my $nmiscgi_script = "$C->{rrddraw}";
		my $tmpurl=url()."?conf=$Q->{conf}&type=graph&graphtype=$aref->[2]&glamount=&glunits=&node=$pnode";

		return td({align=>"center", colspan=>"2", bgcolor=>"white"},
			a({href=>$tmpurl, target=>"ViewWindow", onMouseOver=>"window.status='Drill into $aref->[1].';return true",
					 onClick=>"viewdoc('$tmpurl',$win_width,$win_height)"},
				img({border=>"0", alt=>"$aref->[1]",
					src=>"$C->{rrddraw}?conf=$Q->{conf}&act=draw_graph_view&node=$pnode&graphtype=$aref->[2]&start=0&end=0&width=350&height=50&title=small"})));
	}

	#src="/cgi-nmis8/rrddraw.pl?conf=Config.xxxx&amp;act=draw_graph_view&node=wanedge1&group=&graphtype=cpu&start=1318428782&end=1318601582&width=700&height=250&intf=&item=" align="MIDDLE" /></td>
}

sub displayRTTdata {
	my $nno = shift;

	my $time = time;

	if ( $start eq "" ) { $start = $time - (24*3600); } # 24 hour window
	if ( $end eq "" ) { $end = $time; }

	my $window = $end - $start;

	my $sec_start = ($date_start eq "") ? $start : parsedate($date_start) ; # convert string to number seconds
	my $sec_end = ($date_end eq "") ? $end : parsedate($date_end) ;

	# check if date boxes are changed by user
	if ( $start != $sec_start or $end != $sec_end ) {
		$start = $sec_start;
		$end = $sec_end;
	}
	# calculate moving graph window on click
	#left, if clicked on graph
	elsif ( $graphx != 0 and $graphx < 150 ) {
		$start -= ($window / $C->{graph_factor});
		$end = $start + $window;
	}
	#right
	elsif ( $graphx != 0 and $graphx > $width + 94 - 150 ) {
		my $move = $time - ($end + ($window / $C->{graph_factor}));
		$move = 0 if $move > 0 ;
		$end += ($window / $C->{graph_factor}) + $move;
		$start = $end - $window;
	}
	#zoom in
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy <= $height / 2 ) ) {
		$start += ($window / $C->{graph_factor});
	}
	#zoom out
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy > $height / 2 ) ) {
		$start -= $window;
	}

	# Stop from drilling into the future!
	$end = $time if $end > $time;
	$start = $time if $start > $time;

	$start = int $start;
	$end = int $end;

	$date_start = returnDateStamp($start); # for display date/time fields
	$date_end = returnDateStamp($end);

	my @items = split ":", $RTTcfg{$nno}{items};

	my $numrows = scalar( map { /^\d+L\d+.*/ } @items); # number of Lines in RRD graph

	if ($numrows == 0) { print Tr(td("Waiting for data")); return; }

	# date time and column name fields
	print Tr(th({class=>"info Plain",colspan=>"2",align=>"center", width=>"50%", nowrap=>"nowrap"},"Start&nbsp;",
				textfield(-name=>"date_start",-value=>"$date_start",-override=>1),
				"&nbsp;End&nbsp;",
				textfield(-name=>"date_end",-value=>"$date_end",-override=>1),
				submit(-name=>"date",-value=>"View")),
				th({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},$RTTcfg{$nno}{select}),
				eval {
					my $str = $RTTcfg{$nno}{optype} =~ /echo/i ? "Target / Responder": "Item";
					return th({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},$str);
				} # eval
			);

	# image
	$item = $RTTcfg{$nno}{items} if $item eq "";
	$numrows++; # correction
	print Tr(td({colspan=>"3",rowspan=>"$numrows",align=>"left",valign=>"top",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},
		image_button(-name=>"graph",-src=>url()."?conf=$Q->{conf}&func=graph&view=true&key=$nno&start=$start&end=$end&item=$item")));
	foreach my $nm (@items) {
		if ($nm =~ /^\d+L(\d+)_(.*)/) {
			$_ = $2;
			s/_/\./g;
			my $addr = "$_<br><small>$RTTcfg{$nno}{$_}</small>";
			print Tr(td({align=>"center",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},a({href=>url()."?conf=$Q->{conf}&view=true&key=$nno&start=$start&end=$end&item=$nm"},$addr)));
		}
	}
	print Tr(th({colspan=>"3",align=>"center",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time"),
				th({class=>"info Plain noborder"},"&nbsp"));
}

# generate chart
sub displayRTTgraph {
	my $nno = shift;

	my $color;
	my @items = split(/\:/,$item);
	my $database = $RTTcfg{$nno}{database};

	my @colors = ("880088","00CC00","0000CC","CC00CC","FFCC00","00CCCC",
			"000044","BBBB00","BB00BB","00BBBB");

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	# select the vertical label, first digit of first item
	my $vlabel = "RTT Avg msec.";
	if ($items[0] =~ /^(\d+)[A-Z]\d+_.*/) {
		$vlabel = "Impairment/Calculated Imp. Planning Factor" if $1 == 2;
		$vlabel = "Mean opinion scores" if $1 == 3;
		$vlabel = "Jitter Avg msec." if $1 == 4;
		$vlabel = "Number of packets" if $1 == 5;
		$vlabel = "Hourly RTT Avg msec." if $1 == 6;
		$vlabel = "Hourly Jitter Avg msec." if $1 == 7;
		$vlabel = "Hourly Impairment/Calculated Imp. Planning Factor" if $1 == 8;
		$vlabel = "Hourly Mean opinion scores" if $1 == 9;
	}

	my @options = (
			"--title", "$RTTcfg{$nno}{select} from $datestamp_start to $datestamp_end",
			"--vertical-label", $vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlaced");

	my $cnt = 0;
	my @p_options = ();
	foreach (@items) {
		if ( /^\d+([A-Z])(\d+)_(.*)/ ) {
			my $az = $1;
			my $gp = $2;
			my $ds = $3;
			$color = shift @colors if $cnt++ < 10;
			push @options,"DEF:avg$cnt=$database:${ds}:AVERAGE" if $az =~ /[LP]/ ;
			push @options,"DEF:max$cnt=$database:${ds}:MAX" if $az =~ /M/ ;

			my $field = "avg$cnt";
			if ( $ds =~ "mos" ) {
				$field = "mos";
				push @options,"CDEF:$field=avg$cnt,100,/" ;
			}
			$ds =~ s/_/\./g ; # back to IP address format if needed
			if ( $RTTcfg{$nno}{optype} eq "dns" ) {
				$ds = $RTTcfg{$nno}{tas};
			}
			if ($az eq "L") {
				push @options,"LINE1:$field#$color:${ds}";
				push @options,"GPRINT:$field:AVERAGE:Avg %0.1lf msec." if $gp == 1;
				push @options,"GPRINT:$field:AVERAGE:Avg %0.1lf" if $gp == 2;
			} elsif ($az eq "P") {
				push @p_options,"GPRINT:$field:AVERAGE:$ds Avg %0.1lf msec." if $gp == 1 ;
				push @p_options,"GPRINT:$field:AVERAGE:$ds Avg %0.1lf" if $gp == 2;
			} elsif ($az eq "M") {
				push @p_options,"GPRINT:max$cnt:MAX:$ds %0.1lf msec." if $gp == 1 ;
			}
		}
	}

	@options = (@options,@p_options);

	# buffer stdout to avoid Apache timing out on the header tag while waiting for the PNG image stream from RRDs
	select((select(STDOUT), $| = 1)[0]);
	print header({-type=>'image/png',-expires=>'now'});

	my ($graphret,$xs,$ys) = RRDs::graph('-', @options);
	select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout

	if ($ERROR = RRDs::error) {
		logIpsla("IPSLA: RRDgraph, $database Graphing Error: $ERROR");
	}
}

sub writeHashtoVar {
	my $file = shift; # filename
	my $data = shift; # address of hash
	my $handle;

	my $datafile = getFileName(file => "$C->{'<nmis_var>'}/$file");


	open DB, ">$datafile" or warn returnTime." writeHashtoVar: cannot open $datafile: $!\n";
	flock(DB, LOCK_EX) or warn returnTime." writeHashtoVar: can't lock file $datafile, $!\n";
	print DB Data::Dumper->Dump([$data], [qw(*hash)]);
	close DB;

	setFileProt($datafile);
	print returnTime." writeHashtoVar: wrote @{[ scalar keys %{$data} ]} records to $datafile\n" if $debug > 1;

}

sub readVartoHash {
	my $file = shift; # primairy part of filename to read
	my %hash;
	my $handle;
	my $line;

	my $datafile = getFileName(file => "$C->{'<nmis_var>'}/$file");

	if ( -r $datafile ) {
		sysopen($handle, $datafile, O_RDONLY )
			or warn returnTime." readVartoHash: cannot open $datafile, $!\n";
		flock($handle, LOCK_SH) or warn returnTime." readVartoHash: can't lock file $datafile, $!\n";
		while (<$handle>) { $line .= $_; }
		close $handle;

		# convert data to hash
		%hash = eval $line;
	} else {
		print returnTime." readVartoHash: file $datafile does not exist\n" if $debug;
	}
	print returnTime."  readVartoHash: read @{[ scalar keys %hash ]} records from $datafile\n" if $debug > 1;

	return %hash;
}

sub getJscript {
	my $jscript = <<JSEND;
	<!--
	function viewdoc(url,width,height)
	{
		var attrib = "scrollbars=yes,resizable=yes,width=" + width + ",height=" + height;
		ViewWindow = window.open(url,"ViewWindow",attrib);
		ViewWindow.focus();
	}
	function check(frm,e)
	{
		var msg1 = "Are you sure to stop this probe ?";
		var msg2 = "Do you want to delete the database of this probe ?";
		if (frm.func.value == "STOP") {
			if (confirm(msg1 )) {
				if (confirm(msg2)) {
					frm.deldb.value = 'true';
				}
	  			return true;
			} else {
				return false;
			}
		}
		if (frm.func.value == "REMOVE") {
			if (confirm(msg2)) {
				frm.deldb.value = 'true';
			}
		}
		return true;
	}
	function noview(loc) {
		document.rtt.view.value = 'false';
		loc.form.submit();
		return true;
	}
	function gotoURL(url)
	{
	    var Current = document.rtt.probes.selectedIndex;
	    window.location.href = url + document.rtt.probes.options[Current].value;
	    return false;
	}
	//-->
JSEND

	return $jscript;
}
