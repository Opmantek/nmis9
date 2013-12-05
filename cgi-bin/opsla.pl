#!/usr/bin/perl
#
## $Id: opsla.pl,v 1.6 2012/12/06 02:30:25 keiths Exp $
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND
# LICENSED BY OPMANTEK.  
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE,
# THIS AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU
# AND OPMANTEK LTD. 
# Opmantek is a passionate, committed open source software company - we
# really are.  This particular piece of code was taken from a commercial
# module and thus we can't legally supply under GPL. It is supplied in good
# faith as source code so you can get more out of NMIS.  According to the
# license agreement you can not modify or distribute this code, but please
# let us know if you want to and we will certainly help -  in most cases
# just by emailing you a different agreement that better suits what you want
# to do but covers Opmantek legally too. 
# 
# contact Opmantek by emailing code@opmantek.com
# 
# 
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
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
use Sys;
use NMIS::IPSLA;
use func;
use rrdfunc;
use Fcntl qw(:DEFAULT :flock);

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *th *form *Select *div *hr);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span );

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = CGI->new; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash	

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# NMIS Authentication module
use Auth;
my $user;
my $privlevel = 5;
my $logoutButton;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS configuration

if ($AU->Require) {
	#2011-11-14 Integrating changes from Till Dierkesmann
	if($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") {
		$Q->{auth_username}=$ENV{'REMOTE_USER'};
		$AU->{username}=$ENV{'REMOTE_USER'};
		$logoutButton = qq|disabled="disabled"|;
	}
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
	$privlevel = $AU->{privlevel};
	$user = $AU->{user};
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
my $frequence = $q->param('freq');
my $lsrpath = $q->param('lsr');
my $owner = $q->param('owner');
my $reqdatasize = $q->param('dsize');
my $timeout = $q->param('tout');
my $tos = $q->param('tos');
my $verify = $q->param('verify');
my $key = $q->param('key');
my $interval = $q->param('intvl');
my $numpkts = $q->param('pkts');
my $deldb = $q->param('deldb');
my $tport = $q->param('tport');
my $tas = $q->param('tas');
my $codec = $q->param('codec');
my $factor = $q->param('factor');
my $vrf = $q->param('vrf');

my $dump_data = Dump;
$q->delete_all();
my $msg; # common message

my ($graphret, $xs, $ys, $ERROR);
my $width = $C->{graph_width};
my $height = $C->{graph_height};

my %operation = (
	'echo'=>{'responder'=>'router,server',
			'attr'=>'frequence,request-data-size,timeout,tos,verify-data,source-addr,vrf',
			'frequence'=>[5,10,30,60,120,300,600],
			'default'=>{ 'freq'=>30,'tout'=>'5','dsize'=>'28' }
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

my $IPSLA = NMIS::IPSLA->new(C => $C);

# get config database values if view graph is active
if ($view eq "true" and $key ne "") {
	my $probe = $IPSLA->getProbe(probe => $key);
	
	$pnode = $probe->{pnode};
	$optype = $probe->{optype};
	$saddr = $probe->{saddr};
	$rnode = $probe->{rnode};
	$raddr = $probe->{raddr};
	$dport = $probe->{dport};
	$timeout = $probe->{timeout};
	$history = $probe->{history};
	$frequence = $probe->{frequence};
	$lsrpath = $probe->{lsrpath};
	$reqdatasize = $probe->{reqdatasize};
	$tos = $probe->{tos};
	$interval = $probe->{interval};
	$numpkts = $probe->{numpkts};
	$tport = $probe->{tport};
	$codec = $probe->{codec};
	$factor = $probe->{factor};
	$vrf = $probe->{vrf};
	$url = $probe->{url};
}

$tos = 0 if not $tos;

# define hash key
my $tnode = ($rnode eq "other") ? $raddr : $rnode;
my $dest = ($optype =~ /http/ and $url =~ m:.*//(.*)(/|$).*: ) ? $1 : $tnode ;
$dest =~ s/\ /\-/g;
my $nno = "${pnode}_${dest}_${optype}_${tos}"; # key for hash table %RTTcfg

# store typed community
#if ($ppnode ne $pnode) { $pcom = $RTTcfg{$pnode}{community};}
#if ($prnode ne $rnode) { $rcom = $RTTcfg{$rnode}{community};}
if ($ppnode ne $pnode) { $pcom = $IPSLA->getCommunity(node => $pnode);}
if ($prnode ne $rnode) { $rcom = $IPSLA->getCommunity(node => $rnode);}

if ($pcom ne "*********" and $pcom ne "" and $pnode ne "") {
	$IPSLA->updateNode(node => $pnode, community => $pcom);
	$pcom = "*********";
}
if ($rcom ne "*********" and $rcom ne "" and $rnode ne "") {
	$IPSLA->updateNode(node => $rnode, community => $rcom);
	$rcom = "*********";
}

# what shall we do
my $NT = loadLocalNodeTable();

if ($func eq "graph") {
	&displayRTTgraph($key); exit; # ready
}

startIPSLApage();

if ($func eq "start") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		runRTTstart($nno);
	}	
} elsif ($func eq "stop") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		runRTTstop($key);
	}
} elsif ($func eq "remove") {
	if ( $AU->CheckAccess('ipsla_rw') ) {
		&runRTTremove($key);
	}
} 

if ( $AU->CheckAccess('ipsla_menu') ) {
	displayIPSLAmenu();
}

endIPSLApage();

exit;

sub startIPSLApage {
	my $header = "opSLA $NMIS::IPSLA::VERSION";
	my $nmisicon = "<a target=\"nmis\" href=\"$C->{'nmis'}?conf=$Q->{conf}\"><img class='logo' src=\"$C->{'nmis_icon'}\"/></a>";
	my $header2 = "$header <a href=\"$ENV{SCRIPT_NAME}\"><img src=\"$C->{'nmis_home'}\"/></a>";
	
	#ipsla.pl is NOT parsing this $Q properly!	
	my $portalCode = loadPortalCode(conf=>$Q->{conf});

	# Javascripts
	my $jscript = getJscript();

	print $q->header($headeropts);
	#print header({-type=>"text/html",-expires=>'now'});
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
	
	my $probe = $IPSLA->getProbe(probe => $nno);
		
	# get node info from /var, this file is produced by nmis.pl type=update
	my $RTTInfo = readFiletoHash(file => "$C->{'<nmis_var>'}/nmis-nodeinfo"); # global hash
	
	my (@pnode,@nodes);
	@pnode = @nodes = grep { $_ if $RTTInfo->{$_}{nodeModel} eq "CiscoRouter" and $AU->InGroup($NT->{$_}{group}) } sort keys %{$RTTInfo};
	@pnode = @nodes = sort keys %{$RTTInfo} if scalar @nodes == 0; # depends on nmis.pl code
	unshift @pnode, "";

	### 2012-10-02 keiths, Updates for AUTH Implementation.
	if ($pnode eq "") { $rnode = $optype = $pcom = $rcom = $pcom = $raddr = $view = $url = $key = $vrf = ""; }
	if ($optype =~ /http/ and $url eq "") { $url = "http://"; }

	if ($poptype ne $optype and $view ne "true"){ 
		$frequence = $lsrpath = $timeout = $tos = ""; $verify = 0; $attr = "on"  # defaults
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

		### 2012-10-02 keiths, Updates for AUTH Implementation.
		if ($pnode ne "" and $AU->InGroup($NT->{$pnode}{group})) {
	  	# all good, allowed to see device.
		}	# endif AU
		elsif ($pnode eq "") {
	  	# all good, allowed to see device.
		}
		else {
			print	start_table({class=>"dash", width => "100%"}),
			Tr(th({class=>"subtitle"},"You are not authorized for this request"));
			print	end_table;
			return;
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
				if ($probe->{status} =~ /running|error/i ) {
					my $s = ($probe->{history} > 1) ? "s" : "";
					return "History of values for $probe->{history} week$s" ;
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
				if ($view eq "true") {
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
					if ($probe->{status} eq "") {
						$button = "start" ;
					} elsif ($probe->{status} =~ /running/i ) {
						$button = "stop" ;
					} elsif ($probe->{status} =~ /error|stopped|start req/i) {
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
	
	my @probeList = $IPSLA->getProbes();
	foreach my $p ( sort { $a->{probe} cmp $b->{probe} } @probeList ) {
		my $key = $p->{probe};
		if ($p->{pnode} ne "") {
			### 2012-10-02 keiths, Updates for AUTH Implementation.
			if ($AU->InGroup($NT->{$p->{pnode}}{group})) {
		  	# all good, allowed to see device.		
				if ($p->{status} eq "error") {
					#$attr{$key}{class} = "error";
					$msg = "one of the probes is in error state";
				}
				push @probes,$key;
				$probes{$key} = "$p->{select} ($p->{status})";
			}	# endif AU
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
					if ($probe->{message} =~ /\w+/) {
						$class = "Error";
						$message = "&nbsp;$probe->{message}";
					} elsif ( $C->{daemon_ipsla_active} ne "true" ) {
						$class = "Error";
						$message = "&nbsp; parameter daemon_ipsla_active in nmis.conf is not set on true to start the daemon opslad.pl";
					} elsif ( 
							(not -r "$C->{'<nmis_var>'}/ipslad.pid") 
							#or ( -M "$C->{'<nmis_var>'}/ipslad.pid" > 0.0015)
					) { 
						$class = "Error";
						$message = "&nbsp;daemon opslad.pl is not running";
					} elsif ($msg ne "") { 
						$class = "Error";
						$message = $msg; # local msg
					} else {
						$message = "$probe->{starttime}";
					}
				} elsif ($msg ne "") { 
					$message = $msg; $class = "error"; # local msg
				}
				$message = scalar @probes." probes are active" if $message eq "" and scalar @probes > 1;
				$message = "1 probe is active" if $message eq "" and scalar @probes == 1;
				return td({class=>$class,colspan=>"2", nowrap=>"nowrap", width=>"50%"},"$message");
			}
		);
	}


	# display node charts ?
	if ($view eq "true" and $pnodechart eq "on") { displayRTTnode(); } # node charts

	# background values
	print hidden(-name=>'file', -default=>$Q->{conf},-override=>'1');
	print hidden(-name=>'ppnode', -default=>$pnode,-override=>'1');
	print hidden(-name=>'prnode', -default=>$rnode,-override=>'1');
	print hidden(-name=>'poptype', -default=>$optype,-override=>'1');
	print hidden(-name=>'deldb', -default=>'false',-override=>'1');
	print hidden(-name=>'view', -default=>$view,-override=>'1');
	print hidden(-name=>'key', -default=>$key,-override=>'1') if $view eq "true";

	print end_form;

	# start of second form
	print start_form( -method=>'get', -name=>"data", -action=>url() );

	# display data
	if ($view eq "true" and $probe->{status} eq "running") { displayRTTdata($nno); }

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
	my $probe = $IPSLA->getProbe(probe => $nno);

	# let the daemon unlink the database
	return if ($probe->{func} =~ /stop|remove/ and $probe->{deldb} eq "true");

	# run bin/opslad.pl for accept modified configuration
	# if this system failed then the detach process opslad.pl does it later.
	my $lines = `$C->{'<nmis_bin>'}/opslad.pl type=update`;
}

sub runRTTstart {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);
	
	### 2012-10-02 keiths, Updates for AUTH Implementation.
	if ($AU->InGroup($NT->{$pnode}{group})) {
		# already running ?
		if ($probe->{status} eq "running") {
			$pnode = $attr = "";
			return;
		}
	
		my $community = $IPSLA->getCommunity(node => $pnode);
		if ($community eq "") {
			
			$msg = "No community specified for probe node $pnode";
		#	$pnode = "";
			return;
		}
	
		if ($rnode eq "other" and $raddr eq "") {
			$msg = "No address specified for responder node";
			$pnode = "";
			return;
		}
	
		if ($pnode ne "" and $probe->{func} eq "" and $probe->{status} !~ /start|running|remove|error/) {
			my %sprobe;
			$sprobe{probe} = $nno;
			$sprobe{func} = "start";
			$sprobe{select} = "${pnode}::${dest}::${optype}::${tos}";
			$sprobe{pnode} = $pnode; # probe node
			$sprobe{optype} = $optype; # probe type
			$sprobe{saddr} = $saddr; # source address
			$sprobe{rnode} = $rnode; #
			$sprobe{raddr} = $raddr if $raddr ne ""; #
			$sprobe{tnode} = $tnode if $tnode ne ""; # responder node
			$sprobe{dport} = $dport if $dport ne ""; # destination port
			$sprobe{url} = $url if $url ne "";
			$sprobe{history} = $history;
			$sprobe{frequence} = $frequence;
			$sprobe{lsrpath} = $lsrpath if $lsrpath ne "";
			$sprobe{reqdatasize} = $reqdatasize if $reqdatasize ne "";
			$sprobe{timeout} = $timeout if $timeout ne "";
			$sprobe{tos} = $tos if $tos ne "";
			$sprobe{interval} = $interval if $interval ne "";
			$sprobe{numpkts} = $numpkts if $numpkts ne "";
			$sprobe{tport} = $tport if $tport ne "";
			$sprobe{tas} = $tas if $tas ne "";
			$sprobe{codec} = $codec if $codec ne "";
			$sprobe{factor} = $codec if $factor ne "";
			$sprobe{vrf} = $vrf if $vrf ne "";
			$sprobe{deldb} = $deldb; # delete database
			$sprobe{verify} = ($verify == 0) ? 2 : $verify;
			my $n = $nno; $n =~ s/[\._]/-/g ;
			$sprobe{database} = "$C->{database_root}/misc/ipsla-${n}.rrd";
	
			$sprobe{status} = "start requested";
			$sprobe{message} = "";
	
			$pnode = $pcom = $rnode = $rcom = $view = $attr = "";
			
			$IPSLA->updateProbe(%sprobe);
			runCfgUpdate();
		}
	}	# endif AU
	else {
		print	start_table({class=>"dash", width => "100%"}),
		Tr(th({class=>"subtitle"},"You are not authorized for this request"));
		print	end_table;
		return;
	}

}

sub runRTTstop {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);
	
	return if not $IPSLA->existProbe(probe => $nno);

	my $au_pnode = $probe->{pnode};
	if ( $au_pnode eq "" ) {
		$au_pnode = $pnode;
	}

	### 2012-10-02 keiths, Updates for AUTH Implementation.
	if ($AU->InGroup($NT->{$au_pnode}{group})) {		if ($probe->{func} eq "" and $probe->{status} =~ /start|running|error/) {
			my %sprobe;
			$sprobe{probe} = $nno;
			$sprobe{func} = "stop";
			$sprobe{status} = "stop requested";
			$sprobe{message} = "";
			$sprobe{deldb} = $deldb;
	
			$pnode = $pcom = $rnode = $rcom = $view = $attr = "";
	
			$IPSLA->updateProbe(%sprobe);
			runCfgUpdate();
		}
	}	# endif AU
	else {
		print	start_table({class=>"dash", width => "100%"}),
		Tr(th({class=>"subtitle"},"You are not authorized for this request"));
		print	end_table;
		return;
	}
}

sub runRTTremove {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);

	return if not $IPSLA->existProbe(probe => $nno);

	my $au_pnode = $probe->{pnode};
	if ( $au_pnode eq "" ) {
		$au_pnode = $pnode;
	}

	### 2012-10-02 keiths, Updates for AUTH Implementation.
	if ($AU->InGroup($NT->{$au_pnode}{group})) {
		if ($probe->{func} eq "" and $probe->{pnode} ne "" and $probe->{status} !~ /remove|running|start/) {
			my %sprobe;
			$sprobe{probe} = $nno;
			$sprobe{func} = "remove";
			$sprobe{status} = "remove requested";
			$sprobe{message} = "";
			$sprobe{deldb} = $deldb;
	
			$IPSLA->updateProbe(%sprobe);
	
			runCfgUpdate();
		} 
		else { 
			$IPSLA->deleteProbe(probe => $nno);
		}
		$pnode = $pcom = $rnode = $rcom = $view = $attr = $url = "";
	}	# endif AU
	else {
		print	start_table({class=>"dash", width => "100%"}),
		Tr(th({class=>"subtitle"},"You are not authorized for this request"));
		print	end_table;
		return;
	}
}


# display the attributes depending of probe type
sub displayRTTattr {
	my $nno = shift;
	my $field_cnt = 0;

	my $probe = $IPSLA->getProbe(probe => $nno);

	# it's the lazy way
	if ($optype ne "" ) {
		print start_Tr if $attr eq "on";

		if ($operation{$optype}{attr} =~ /frequence/) {
			$frequence = $operation{$optype}{default}{freq} if $frequence eq "";
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"}, 
					"interval&nbsp;".
						popup_menu(-name=>"freq", -override=>'1',
							-values=>$operation{$optype}{frequence},
							-default=>"$frequence")."&nbsp;sec.");
				$field_cnt++;
			} else {
				print hidden(-name=>'freq', -default=>$frequence, -override=>'1');
			}
		}
		if ($operation{$optype}{attr} =~ /lsr-path/) {
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"lsr path, ip addr.&nbsp;".
							textfield(-name=>'lsr',-override=>1,
							-value=>"$lsrpath"));
				$field_cnt++;
			} else {
				print hidden(-name=>'lsr', -default=>$lsrpath, -override=>'1');
			}
		}
		if ($operation{$optype}{attr} =~ /request-data-size/) {
			$reqdatasize = $operation{$optype}{default}{dsize} if $reqdatasize eq "";
			if ($attr eq "on") {
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"req data size".
						textfield(-name=>'dsize',-override=>'1',-size=>'2',-align=>'right',
							-title=>"optional, range 1 - 1500",
							-value=>"$reqdatasize"));
				$field_cnt++;
			} else {
				print hidden(-name=>'dsize', -default=>$reqdatasize, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /timeout/) {
			$timeout = $operation{$optype}{default}{tout} if $timeout eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", align=>"right", width=>"25%", nowrap=>"nowrap"},"timeout&nbsp;".
					popup_menu(-name=>"tout", -override=>'1',
						-values=>["",1,2,3,4,5,10,20,30],
						-default=>"$timeout"));
				$field_cnt++;
			} else {
				print hidden(-name=>'tout', -default=>$timeout, -override=>'1');
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
						popup_menu(-name=>"verify", -override=>'1',
							-values=>[2,1],
							-labels=>{'2' => 'no','1' => 'yes'},
							-default=>"$verify"));
				$field_cnt++;
			} else {
			print hidden(-name=>'verify', -default=>$verify, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /interval/) {
			$interval = $operation{$optype}{default}{intvl} if $interval eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"interval&nbsp;".
						textfield(-name=>'intvl',-override=>1,-size=>'2',-align=>'right',
							-title=>"time in msec. between packets",
							-value=>"$interval")." msec");
				$field_cnt++;
			} else {
			print hidden(-name=>'intvl', -default=>$interval, -override=>'1');
			}
		}
		if ($field_cnt > 3) { print end_Tr; $field_cnt = 0;}
		if ($operation{$optype}{attr} =~ /num-pkts/) {
			$numpkts = $operation{$optype}{default}{pkts} if $numpkts eq "";
			if ($attr eq "on") {
				if ($field_cnt == 0) { print start_Tr; }
				print td({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"# of packets&nbsp;".
						textfield(-name=>'pkts',-override=>1,-size=>'2',-align=>'right',
							-title=>"number of packets per probe operation, range 1 to 60000",
							-value=>"$numpkts"));
				$field_cnt++;
			} else {
			print hidden(-name=>'pkts', -default=>$numpkts, -override=>'1');
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
		if ($attr eq "on" and $probe->{entry} ne "") {
			print td({class=>"info Plain",align=>"center", width=>"25%", nowrap=>"nowrap"},"probe entry is $probe->{entry}");
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

	my $probe = $IPSLA->getProbe(probe => $nno);

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

	my @items = split ":", $probe->{items};				

	my $numrows = scalar( map { /^\d+L\d+.*/ } @items); # number of Lines in RRD graph

	if ($numrows == 0) { print Tr(td("Waiting for data")); return; }

	# date time and column name fields
	print Tr(th({class=>"info Plain",colspan=>"2",align=>"center", width=>"50%", nowrap=>"nowrap"},"Start&nbsp;",
				textfield(-name=>"date_start",-value=>"$date_start",-override=>1),
				"&nbsp;End&nbsp;",
				textfield(-name=>"date_end",-value=>"$date_end",-override=>1),
				submit(-name=>"date",-value=>"View")),
				th({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},$probe->{select}),
				eval {
					my $str = $probe->{optype} =~ /echo/i ? "Target / Responder": "Item";
					return th({class=>"info Plain", width=>"25%", nowrap=>"nowrap"},$str); 
				} # eval
			);

	# image
	$item = $probe->{items} if $item eq ""; 
	$numrows++; # correction
	print Tr(td({colspan=>"3",rowspan=>"$numrows",align=>"left",valign=>"top",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},
		image_button(-name=>"graph",-src=>url()."?conf=$Q->{conf}&func=graph&view=true&key=$nno&start=$start&end=$end&item=$item")));
	foreach my $nm (@items) {
		if ($nm =~ /^\d+L(\d+)_(.*)/) {
			$_ = $2;
			s/_/\./g;
			my $lookup = $IPSLA->getDns(lookup => $_);
			
			my $addr = "$_<br><small>$lookup->{result}</small>";
			print Tr(td({align=>"center",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},a({href=>url()."?conf=$Q->{conf}&view=true&key=$nno&start=$start&end=$end&item=$nm"},$addr)));
		}
	}
	print Tr(th({colspan=>"3",align=>"center",class=>"info Plain", width=>"25%", nowrap=>"nowrap"},"Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time"),
				th({class=>"info Plain noborder"},"&nbsp"));
}

# generate chart
sub displayRTTgraph {
	my $nno = shift;

	my $probe = $IPSLA->getProbe(probe => $nno);

	my $color;
	my @items = split(/\:/,$item);
	my $database = $probe->{database};
	
	print STDERR "DEBUG: displayRTTgraph database=$database\n";

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
			"--title", "$probe->{select} from $datestamp_start to $datestamp_end",
			"--vertical-label", $vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace");

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
			$ds =~ s/_/\./g ; # back to IP address format if needed
			if ($az eq "L") {
				push @options,"LINE1:avg$cnt#$color:${ds}";
				push @options,"GPRINT:avg$cnt:AVERAGE:Avg %0.1lf msec." if $gp == 1;
				push @options,"GPRINT:avg$cnt:AVERAGE:Avg %0.1lf" if $gp == 2;
			} elsif ($az eq "P") {
				push @p_options,"GPRINT:avg$cnt:AVERAGE:$ds Avg %0.1lf msec." if $gp == 1 ;
				push @p_options,"GPRINT:avg$cnt:AVERAGE:$ds Avg %0.1lf" if $gp == 2;
			} elsif ($az eq "M") {
				push @p_options,"GPRINT:max$cnt:MAX:$ds %0.1lf msec." if $gp == 1 ;
			}
		}
	}

	@options = (@options,@p_options);

	# buffer stdout to avoid Apache timing out on the header tag while waiting for the PNG image stream from RRDs
	select((select(STDOUT), $| = 1)[0]);
	print $q->header({-type=>'image/png',-expires=>'now'});
	#print $q->header($headeropts);

	my ($graphret,$xs,$ys) = RRDs::graph('-', @options);
	select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout

	if ($ERROR = RRDs::error) {
		logIpsla("IPSLA: RRDgraph, $database Graphing Error: $ERROR");
	}
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

