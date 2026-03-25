package NMISCGI::Tools;
our $VERSION = "9.6.5";

use strict;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::Sys;

use CGI qw(:standard *table *Tr *td *form *Select *div);

sub runcgi {
	my $args = shift;
	my $q = $args->{q};
	my $Q = $args->{Q};
	my $C = $args->{C};
	my $AU = $args->{AU};
	my $headeropts = $args->{headeropts};
	my $nmisng = $args->{nmisng};

	# on unless explicitely set to false
	my $widget = NMISNG::Util::getbool($Q->{widget},"invert")? 'false' : "true";
	my $wantwidget = $widget eq "true";

	my %common = (q => $q, C => $C, AU => $AU, headeropts => $headeropts,
		nmisng => $nmisng, widget => $widget, wantwidget => $wantwidget);

	#======================================================================

	# select function

	if ($Q->{act} =~ /tool_system/) {
		typeTool(%common, act => $Q->{act}, node => $Q->{node},
			conf => $Q->{conf}, dns => $Q->{dns});
	}
	else {
		notfound(headeropts => $headeropts, act => $Q->{act}, node => $Q->{node});
	}

	return;
}

# args: headeropts, act, node
sub notfound {
	my (%args) = @_;
	print header($args{headeropts}), escapeHTML("Tools: ERROR, act=$args{act}, node=$args{node}")."<br>Request not found\n";
}

#===================


# args: q, C, AU, headeropts, nmisng, widget, wantwidget, act, node, conf, dns
sub typeTool
{
	my (%args) = @_;
	my ($q, $C, $AU, $nmisng) = @args{qw(q C AU nmisng)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};

	my $tool = $args{act};
	$tool =~ s/tool_system_//i;
	my $node = $args{node};

	my $NT = Compat::NMIS::loadNodeTable();
	my $host = $NT->{$node}{host};

	# input sanitising - ideally we'd like to accept just [a-zA-Z0-9_-]
	# but people regularly go beyond that set. so, for now, we just ditch
	# the definitely problematic ones.
	if ($node =~ /[&`'"<>]/)
	{
		print header($args{headeropts}), "Tools: ERROR, Rejecting Unsafe node argument '".escapeHTML($node)."'<br>\n";
		exit;
	}
	if ($host =~ /[&`'"<>]/)
	{
		print header($args{headeropts}), "Tools: ERROR, Rejecting Unsafe host argument '".escapeHTML($host)."'<br>\n";
		exit;
	}

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	$S->init(name=>$node,snmp=>'false');

	my $title = escapeHTML("Command $tool for node $NT->{$node}{name} ($host)");
	$title = escapeHTML("Command $tool") if $node eq '';

	if ( $tool =~ /^(ping|trace|nslookup|finger|man|mank|mtr|lft|snmp)$/
			 and (!$node or !$host))	# node must be given AND known for these cmds
	{
		selectNode(q => $q, C => $C, headeropts => $args{headeropts},
			wantwidget => $wantwidget, widget => $widget,
			conf => $args{conf}, act => $args{act}, node => $node);
		exit;
	}

	print header($args{headeropts});
	Compat::NMIS::pageStartJscript(title => $title) if (!$wantwidget);

	return unless $AU->CheckAccess("tls_$tool");
	my $wid = "580px";

	print Compat::NMIS::createHrButtons(node=>$node, system=>$S, widget=>$widget, conf => $args{conf}, AU => $AU);

	#certain outputs will have their own layout
	if ($tool eq "hostinfo") {
		hostInfo();
	}
	else
	{
		# no shell -> meta chars are not a problem
		# cmd -> list of args for system()/piped open, or sub ref
		my %knowntools = ( ping => [qw(ping -c 3),$host],
											 trace => [qw(traceroute -n -m 15), $host],
											 nslookup => ['nslookup',$host],
											 finger => ['finger',"\@$node"],
											 who => ['who'],
											 man => ['man', $host],
											 mank => [qw(man -k),$host],
											 ps => [qw(ps -ef)],
											 iostat =>  [qw(iostat 1 10)],
											 vmstat => [qw(vmstat 1 10)],
											 date => ['date'],
											 df => [qw(df -k)],
											 dns => sub { viewDNS(AU => $AU, nmisng => $nmisng, dns => $args{dns}) },
											 lft => [$C->{lft},"-NASE", $host],
											 mtr => [$C->{mtr},qw(--report --report-cycles=10),$host],
											 snmp => [$C->{'<nmis_admin>'}."/tests.pl", "act=snmp", "node=$node"],
											 collect => [$C->{'<nmis_admin>'}."/support.pl", "action=collect", "gui=1"]
			);

		if (!$knowntools{$tool})
		{
			print "Tools: ERROR, Rejecting unknown tool argument '".escapeHTML($tool)."'<br>\n";
			exit 0;
		}

		print start_table({width=>"$wid"});
		print start_Tr,start_td,start_table;
		print Tr(td({class=>'header',width=>"$wid"},$title));

		if (ref($knowntools{$tool}) eq "CODE")
		{
			&{$knowntools{$tool}};
		}
		else
		{
			my $pid = open(TOOL,"-|");
			if (!defined $pid)
			{
				print Td(td(escapeHTML("Tools: ERROR, cannot run tool '$tool': $!")."<br>"));
				exit 0;
			}
			elsif (!$pid)
			{
				open(STDERR, ">&STDOUT"); # stderr to go to stdout, too.
				exec(@{$knowntools{$tool}});
				die "Failed to exec: $!\n";
			}

			my $tooloutput = join("", <TOOL>);
			if (!close(TOOL))
			{
				my $exitcode = $? >> 8;
				print Tr(td(escapeHTML("Tools: ERROR, tool '$tool' failed with exit code $exitcode.")."<br>"));
			}
			print Tr(td({width=>"$wid"},pre(escapeHTML($tooloutput))));
		}

		print end_table,end_td,end_Tr;
		print end_table;
	}
	Compat::NMIS::pageEnd() if (!$wantwidget);
}

# args: q, C, headeropts, wantwidget, widget, conf, act, node
sub selectNode {
	my (%args) = @_;
	my ($q, $C) = @args{qw(q C)};
	my $wantwidget = $args{wantwidget};
	my $widget = $args{widget};

	print header($args{headeropts});

	print start_html(
		-title=>'NMIS Network Tools',-style=>{'src'=>"$C->{'styles'}"},
		-meta=>{ 'CacheControl' => "no-cache",'Pragma' => "no-cache",'Expires' => -1 },
		-head => [
			Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'jquery_jdmenu_css'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"})
		]
	);

	# start of form
  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisTools", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $args{conf})
			. hidden(-override => 1, -name => "act", -value => $args{act})
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table({width=>'500px'});

	print Tr(td({class=>'header'},"Node"),td({class=>'info Plain'},textfield(-name=>"node",size=>'25',value=>"$args{node}")));
	print Tr(
		td({class=>'info'},button(-name=>'cancelbutton',
															onclick=> '$("#cancelinput").val("true");' .
															($wantwidget? "get('nmisTools','cancel');" : 'submit();'),
															-value=>"Cancel")),
		td({class=>'info'},button(-name=>"submitbutton",
															onclick=>($wantwidget? "get('nmisTools');" : 'submit();'),
															-value=>"GO"))
	);

	print end_table,end_form,end_html;

}

sub hostInfo {
	my $wid = "580px";
	my $output = `ifconfig -a`;
	print start_table({width=>"$wid"});
	print Tr(td({class=>'header',width=>"$wid"},"Host Info"));
	print Tr(
		td({class=>'lft Plain'},pre($output))
	);
	print end_table;
}

# args: AU, nmisng, dns
sub viewDNS {
	my (%args) = @_;
	my ($AU, $nmisng) = @args{qw(AU nmisng)};

	if ($args{dns} eq 'host') { viewHostDNS(AU => $AU); }
	elsif ($args{dns} eq 'dns') { viewDnsDNS(AU => $AU); }
	elsif ($args{dns} eq 'arpa') { viewArpaDNS(AU => $AU); }
	elsif ($args{dns} eq 'loc') { viewLocDNS(AU => $AU, nmisng => $nmisng); }
}

# args: AU
sub getInterfaceTable
{
	my (%args) = @_;
	my $AU = $args{AU};

	my $NT = Compat::NMIS::loadNodeTable();
	# fixme9: needs to be rewritten to NOT use slow and inefficient loadInterfaceInfo!
	my $II = Compat::NMIS::loadInterfaceInfo();
	my $ii;

	# build new table with unique key based on ip addr
	foreach my $intHash (keys %{$II}) {
		next unless $AU->InGroup($NT->{$II->{$intHash}{node}}{group});

		my $cnt = 1;
		while ($II->{$intHash}{"ipAdEntAddr$cnt"} ne '') {
			my $ip = $II->{$intHash}{"ipAdEntAddr$cnt"};
	       	if ( 	$ip ne "" and
	       			$ip ne "0.0.0.0" and
	       			$ip !~ /^127/
			) {

				$II->{$intHash}{ifSpeed} = NMISNG::Util::convertIfSpeed($II->{$intHash}{ifSpeed});
				my $shortInt = NMISNG::Util::shortInterface($II->{$intHash}{ifDescr});
				if ( $II->{$intHash}{node} =~ /\d+\.\d+\.\d+\.\d+/
					and $II->{$intHash}{sysName} ne ""
				) {
					$II->{$intHash}{node} = $II->{$intHash}{sysName};
				}
				elsif ( $II->{$intHash}{sysName} ne "" ) {
					$II->{$intHash}{node} = $II->{$intHash}{sysName};
				}
				$ii->{$ip}{ipAdEntAddr} = $II->{$intHash}{"ipAdEntAddr$cnt"};
				$ii->{$ip}{node} = $II->{$intHash}{node};
				$ii->{$ip}{Description} = $II->{$intHash}{Description};
				$ii->{$ip}{ifDescr} = $II->{$intHash}{ifDescr};
				$ii->{$ip}{ipSubnet} = $II->{$intHash}{ipSubnet};
				$ii->{$ip}{ipAdEntNetMask} = $II->{$intHash}{"ipAdEntNetMask$cnt"};
				$ii->{$ip}{ifSpeed} = $II->{$intHash}{ifSpeed};
				$ii->{$ip}{ifType} = $II->{$intHash}{ifType};
			}
			$cnt++;
		} # while
	} # for
	return $ii;
}


# args: AU
sub viewHostDNS {
	my (%args) = @_;

	#Load the Interface Information table
	my $ii = getInterfaceTable(AU => $args{AU});

	# Host Records
	print Tr(td({class=>'header'},"Host Records"));

	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'IP Addr'),
		td({class=>'header'},'Node'),
		td({class=>'header'},'Description'),
		td({class=>'header'},'Interface'),
		td({class=>'header'},'Subnet'),
		td({class=>'header'},'Mask'),
		td({class=>'header'},'Speed'),
		td({class=>'header'},'Type'));

	foreach my $ip (NMISNG::Util::sortall($ii,'ipAdEntAddr','fwd')) {
		print Tr(
			td({class=>'info'},$ii->{$ip}{ipAdEntAddr}),
			td({class=>'info'},$ii->{$ip}{node}),
			td({class=>'info'},$ii->{$ip}{Description}),
			td({class=>'info'},$ii->{$ip}{ifDescr}),
			td({class=>'info'},$ii->{$ip}{ipSubnet}),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}),
			td({class=>'info'},$ii->{$ip}{ifSpeed}),
			td({class=>'info'},$ii->{$ip}{ifType}));
	} # FOR
	print end_table,end_td,end_Tr;
}

# args: AU
sub viewDnsDNS {
	my (%args) = @_;

	#Load the Interface Information table
	my $ii = getInterfaceTable(AU => $args{AU});

	# DNS Records
	print Tr(td({class=>'header'},"DNS Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Node'),
		td({class=>'header'},''),
		td({class=>'header'},'IP Addr'),
		td({class=>'header'},''),
		td({class=>'header'},'Description'),
		td({class=>'header'},'Interface'),
		td({class=>'header'},'Subnet'),
		td({class=>'header'},'Mask'),
		td({class=>'header'},'Speed'),
		td({class=>'header'},'Type'));

	foreach my $ip (NMISNG::Util::sortall2($ii,'node','ipAdEntAddr','fwd')) {
		print Tr(
			td({class=>'info'},$ii->{$ip}{node}),
			td({class=>'info',nowrap=>undef},'IN A'),
			td({class=>'info'},$ii->{$ip}{ipAdEntAddr}),
			td({class=>'info'},'#'),
			td({class=>'info'},$ii->{$ip}{Description}),
			td({class=>'info'},$ii->{$ip}{ifDescr}),
			td({class=>'info'},$ii->{$ip}{ipSubnet}),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}),
			td({class=>'info'},$ii->{$ip}{ifSpeed}),
			td({class=>'info'},$ii->{$ip}{ifType}));

	} # FOR
	print end_table,end_td,end_Tr;
}

# args: AU
sub viewArpaDNS {
	my (%args) = @_;

	#Load the Interface Information table
	my $ii = getInterfaceTable(AU => $args{AU});

	# in-addr.arpa. Records
	print Tr(td({class=>'header'},"in-addr.arpa. DNS Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Arpa'),
		td({class=>'header'},''),
		td({class=>'header'},'Name'),
		td({class=>'header'},''),
		td({class=>'header'},'Mask'));

	foreach my $ip (keys %{$ii}) {
		my @in_addr_arpa = split (/\./,$ii->{$ip}{ipAdEntAddr});
		$ii->{$ip}{ipAdEntAddr_arpa} = "$in_addr_arpa[3].$in_addr_arpa[2].$in_addr_arpa[1].$in_addr_arpa[0]";
	}
	foreach my $ip (NMISNG::Util::sortall($ii,'ipAdEntAddr_arpa','fwd')) {
		print Tr(
			td({class=>'info'},"$ii->{$ip}{ipAdEntAddr_arpa}.in-addr.arpa."),
			td({class=>'info'},"IN PTR"),
			td({class=>'info'},"$ii->{$ip}{node}"),
			td({class=>'info'},'#'),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}));
	} # FOR
	print end_table,end_td,end_Tr;
}

# args: AU, nmisng
sub viewLocDNS
{
	my (%args) = @_;
	my ($AU, $nmisng) = @args{qw(AU nmisng)};

	my $node;
	my $location;
	my %location_data;

	#Load the Interface Information table
	my $ii = getInterfaceTable(AU => $AU);
	#Load the location data.
	my $LT = Compat::NMIS::loadGenericTable("Locations");

	# DNS LOC Records

	print Tr(td({class=>'header'},"DNS LOC Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Node'),
		td({class=>'header'},''),
		td({class=>'header'},'Latitude'),
		td({class=>'header'},'Longitude'),
		td({class=>'header'},'Altitude'),
		td({class=>'header'},'Setting'));

	foreach my $ip (NMISNG::Util::sortall($ii,'node','fwd')) {
		if ( $ii->{$ip}{ipAdEntAddr} ne "" ) {
			if ( $node ne $ii->{$ip}{node} )
			{
				$node = $ii->{$ip}{node};

				my $S    = NMISNG::Sys->new(nmisng => $nmisng);
				$S->init( name => $node, snmp => 'false' );
				my $catchall_data = $S->inventory( concept => 'catchall' )->data();

				my $location = lc($catchall_data->{sysLocation}); # fixme why lowercase?
				if ( $LT->{$location}{Latitude} ne "" and
					$LT->{$location}{Longitude} ne "" and
					$LT->{$location}{Altitude} ne ""
					) {
					print Tr(
						td({class=>'info'},$ii->{$ip}{node}),
						td({class=>'info'},'IN LOC'),
						td({class=>'info'},$LT->{$location}{Latitude}),
						td({class=>'info'},$LT->{$location}{Longitude}),
						td({class=>'info'},$LT->{$location}{Altitude}),
						td({class=>'info'},"1.00m 10000m 100m"));

				}
			}
			if ( $LT->{$location}{Latitude} ne "" and
				$LT->{$location}{Longitude} ne "" and
				$LT->{$location}{Altitude} ne ""
				) {
				print Tr(
					td({class=>'info'},$ii->{$ip}{node}),
					td({class=>'info'},'IN LOC'),
					td({class=>'info'},$LT->{$location}{Latitude}),
					td({class=>'info'},$LT->{$location}{Longitude}),
					td({class=>'info'},$LT->{$location}{Altitude}),
					td({class=>'info'},"1.00m 10000m 100m"));
			}
		}
	} # FOR
	print end_table,end_td,end_Tr;

} #viewLocDNS

1;
