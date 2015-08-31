#!/usr/bin/perl
#
## $Id: reports.pl,v 8.8 2012/01/06 07:09:38 keiths Exp $
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
#
# commmand line
# if no outfile file, defaults to stdout
# typically called from /nmis/bin/run-reports.pl - sets outfile names based on report type etc.
# can be tested from cmd line like this..
# reports.pl report=health start=time end=time outfile=file
#
# available report type:
# report=health 	
# report=avail		
# report=top10 		
# report=outage		level=node|interface
# report=port 		# current port count summaries
# report=counts 	# current port count with per device summaries
# report=response	
# report=nodedetails
#
# example cron jobs for all stored report types
# edit mypath to suit your installation
########################################
# Run the Reports Weekly Monthly Daily
#
# daily
# 0 0 * * * /mypath/run-reports.pl day health
# 0 0 * * * /mypath/run-reports.pl day top10
# 0 0 * * * /mypath/run-reports.pl day outage
# 0 0 * * * /mypath/run-reports.pl day response
# 0 0 * * * /mypath/run-reports.pl day avail
# 0 0 * * * /mypath/run-reports.pl day port
# weekly
# 0 0 * * 0 /mypath/run-reports.pl week health
# 0 0 * * 0 /mypath/run-reports.pl week top10
# 0 0 * * 0 /mypath/run-reports.pl week outage
# 0 0 * * 0 /mypath/run-reports.pl week response
# 0 0 * * 0 /mypath/run-reports.pl week avail
# monthly
# 0 0 1 * * /mypath/run-reports.pl month health
# 0 0 1 * * /mypath/run-reports.pl month top10
# 0 0 1 * * /mypath/run-reports.pl month outage
# 0 0 1 * * /mypath/run-reports.pl month response
# 0 0 1 * * /mypath/run-reports.pl month avail
###########################################
#
#*****************************************************************************
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 
# 
#****** Shouldn't be anything else to customise below here *******************

require 5;
use strict;
use Fcntl qw(:DEFAULT :flock);

use Time::ParseDate;
use csv;
use NMIS;
use func;
use Sys;

use Data::Dumper;
Data::Dumper->import();
$Data::Dumper::Indent = 1;

use URI::Escape;


# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug( report => 'everything', on => 'anything' );

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

#=======================

# select function
# if no options, assume called from web interface ....
if ( $#ARGV > 0 ) {
	my %nvp = getArguements(@ARGV);

	$Q->{act} = $nvp{report} ? "report_dynamic_$nvp{report}" : "report_dynamic_health";
	$Q->{period} = $nvp{length};
	$Q->{level} = $nvp{level} ? $nvp{level} : "node";		# for outage report
	$Q->{debug} = $nvp{debug};
	$Q->{csvfile} = $nvp{csvfile};
	$Q->{conf} = $nvp{conf};
	$Q->{time_start} = returnDateStamp($nvp{start}); # start time in epoch seconds
	$Q->{time_end} = returnDateStamp($nvp{end});
	if ( $nvp{outfile} ) {
		open (STDOUT,">$nvp{outfile}") or die "Cannot open the file $nvp{outfile}. $!";
	}
	$Q->{print} = 1;
}

#=======================

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# this cgi script defaults to widget mode ON
my $wantwidget = (!getbool($Q->{widget},"invert")); 
my $widget = $wantwidget ? "true" : "false";


# Before going any further, check to see if we must handle
# an authentication login or logout request

if ( $#ARGV > 0 ) { $C->{auth_require} = 0; }

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

my $nodewrap = "nowrap";
$nodewrap = "wrap" if (getbool($C->{'wrap_node_names'}));

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

if ($Q->{act} eq 'report_dynamic_health') {			healthReport();
} elsif ($Q->{act} eq 'report_dynamic_avail') {		availReport();
} elsif ($Q->{act} eq 'report_dynamic_response') {	responseReport();
} elsif ($Q->{act} eq 'report_dynamic_port') {		portReport();
} elsif ($Q->{act} eq 'report_dynamic_top10') {		top10Report();
} elsif ($Q->{act} eq 'report_dynamic_outage') {	outageReport();
} elsif ($Q->{act} eq 'report_stored_health') {		storedReport();
} elsif ($Q->{act} eq 'report_stored_avail') {		storedReport();
} elsif ($Q->{act} eq 'report_stored_response') {	storedReport();
} elsif ($Q->{act} eq 'report_stored_port') {		storedReport();
} elsif ($Q->{act} eq 'report_stored_top10') {		storedReport();
} elsif ($Q->{act} eq 'report_stored_outage') {		storedReport();
} elsif ($Q->{act} eq 'report_stored_file') {		fileReport();
} elsif ($Q->{act} eq 'report_csv_nodedetails') {	nodedetailsReport();
} else { notfound(); }

sub notfound {
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}

	print "Reports: ERROR, act=$Q->{act}\n";
	print "Request not found\n";
	print pageEnd if (not $Q->{print} and not $wantwidget);
}
	
exit;

#===============================================================================

sub healthReport {

	my $summaryhash;
	my %reportTable = {};
	my %summaryTable;

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}
	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	my $NT = loadLocalNodeTable();
	my $GT = loadGroupTable();
	my $S = Sys::->new;

	my ($time_elements,$start,$end) = getPeriod();
	if ($start eq '' or $end eq '') {
		print Tr(td({class=>'error'},'Illegal time values'));
		return;
	}

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);
		
	my $header = "Summary Health Metrics from $datestamp_start to $datestamp_end";

	# Get each of the nodes info in a HASH for playing with
	foreach my $reportnode (sort keys %{$NT}) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
			## AS 16 Mar 02, implementing David Gay's requirement for deactiving
		# a node, ie keep a node in nodes.csv but no collection done.
		if ( getbool($NT->{$reportnode}{active}) ) {
			$S->init(name=>$reportnode,snmp=>'false');
			my $NI = $S->ndinfo;
			# get reachable, available, health, response
			my $h;
			if (($h = getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode))) {
	   			%reportTable = (%reportTable,%{$h});
	
				$reportTable{$reportnode}{node} = $NT->{$reportnode}{name};
	
				$reportTable{$reportnode}{reachable} = 0 if $reportTable{$reportnode}{reachable} eq "NaN";
				$reportTable{$reportnode}{available} = 0 if $reportTable{$reportnode}{available} eq "NaN";
				$reportTable{$reportnode}{health} = 0 if $reportTable{$reportnode}{health} eq "NaN";
				$reportTable{$reportnode}{response} = 0 if $reportTable{$reportnode}{response} eq "NaN";
				$reportTable{$reportnode}{loss} = 0 if $reportTable{$reportnode}{loss} eq "NaN";
	
				$reportTable{$reportnode}{net} = $NT->{$reportnode}{netType};
				$reportTable{$reportnode}{role} = $NT->{$reportnode}{roleType};
				$reportTable{$reportnode}{devicetype} = $NI->{system}{nodeType};
				$reportTable{$reportnode}{group} = $NT->{$reportnode}{group};
	
				# Calculate the summaries!!!!
				$summaryhash = "-$reportTable{$reportnode}{net}-$reportTable{$reportnode}{role}";
				$summaryTable{$summaryhash}{net} = $reportTable{$reportnode}{net};
				$summaryTable{$summaryhash}{role} = $reportTable{$reportnode}{role};
				$summaryTable{$summaryhash}{reachable} = $summaryTable{$summaryhash}{reachable} + $reportTable{$reportnode}{reachable};
				$summaryTable{$summaryhash}{available} = $summaryTable{$summaryhash}{available} + $reportTable{$reportnode}{available};
				$summaryTable{$summaryhash}{health} = $summaryTable{$summaryhash}{health} + $reportTable{$reportnode}{health};
				$summaryTable{$summaryhash}{response} = $summaryTable{$summaryhash}{response} + $reportTable{$reportnode}{response};
				$summaryTable{$summaryhash}{loss} = $summaryTable{$summaryhash}{loss} + $reportTable{$reportnode}{loss};
				++$summaryTable{$summaryhash}{count};

				$summaryhash = $reportTable{$reportnode}{group};
				$summaryTable{$summaryhash}{net} = $reportTable{$reportnode}{group};
				$summaryTable{$summaryhash}{role} = "";
				$summaryTable{$summaryhash}{group} = $reportTable{$reportnode}{group};
				$summaryTable{$summaryhash}{reachable} = $summaryTable{$summaryhash}{reachable} + $reportTable{$reportnode}{reachable};
				$summaryTable{$summaryhash}{available} = $summaryTable{$summaryhash}{available} + $reportTable{$reportnode}{available};
				$summaryTable{$summaryhash}{health} = $summaryTable{$summaryhash}{health} + $reportTable{$reportnode}{health};
				$summaryTable{$summaryhash}{response} = $summaryTable{$summaryhash}{response} + $reportTable{$reportnode}{response};
				$summaryTable{$summaryhash}{loss} = $summaryTable{$summaryhash}{loss} + $reportTable{$reportnode}{loss};
				++$summaryTable{$summaryhash}{count};
			}
		}
	}

	# if debug, print all
	if ( getbool($Q->{debug}) ) {
		print Dumper(\%reportTable);
		print Dumper(\%summaryTable);
	}

	# number of decimals
	my $decimals = $C->{average_decimals} ne "" ? $C->{average_decimals} : 3;
	my $dec_format = "%.".$decimals."f";

	# start of form
	print start_form(-id=>"nmis", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "report_dynamic_health")
			. hidden(-override => 1, -name => "widget", -value => $widget) 
			if (not $Q->{print});
	print start_table;

	# header with time info
	print Tr(td({id=>'top',class=>'header',colspan=>'2'},$header));

	print $time_elements if not $Q->{print} ; # time set

	$Q->{sort} = 'node' if $Q->{sort} eq '';
	my $sortdir = ($Q->{sortdir} eq 'fwd') ? 'rev' : 'fwd';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=report_dynamic_health&sortdir=$sortdir&"
			."time_start=$datestamp_start&time_end=$datestamp_end&period=$Q->{period}&widget=$widget";

	# header and data summary
	print start_Tr,start_td({width=>'100%',colspan=>'2'}),start_table;
	print Tr( eval { my $line; my $cnt = 0;
			for (("Group","Reachability","Interface Avail.","&nbsp;Health&nbsp;","Response Time")) {
				$line .= td({class=>'header',align=>'center'},$_);
				$cnt++;
			}
			$line = td({class=>'header',align=>'center',colspan=>$cnt},"Average Health for Groups") . Tr($line);
			return $line;
		} );


	# print a group summary table for the health
	my $aline;
	for my $group (sort keys %summaryTable ) {
		if ( $group =~ /^-lan|^-wan/i ) {
			$summaryTable{$group}{net} = uc($summaryTable{$group}{net});
			$aline = "$summaryTable{$group}{net} $summaryTable{$group}{role}";
		} else {
			$aline = $wantwidget? "$summaryTable{$group}{net} $summaryTable{$group}{role}" :
								a({href=>"#$group"},"$summaryTable{$group}{net} $summaryTable{$group}{role}");
		}
		if ( $summaryTable{$group}{reachable} > 0 ) {
			$summaryTable{$group}{avgreachable} = sprintf($dec_format,$summaryTable{$group}{reachable} / $summaryTable{$group}{count});
		}
		if ( $summaryTable{$group}{available} > 0 ) {
			$summaryTable{$group}{avgavailable} = sprintf($dec_format,$summaryTable{$group}{available} / $summaryTable{$group}{count});
		}
		if ( $summaryTable{$group}{health} > 0 ) {
			$summaryTable{$group}{avghealth} = sprintf($dec_format,$summaryTable{$group}{health} / $summaryTable{$group}{count});
		}
		if ( $summaryTable{$group}{response} > 0 ) {
			$summaryTable{$group}{avgresponse} = sprintf($dec_format,$summaryTable{$group}{response} / $summaryTable{$group}{count});
		}

		print Tr(
			td({class=>'info Plain'},$aline),
			td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($summaryTable{$group}{avgreachable}))},$summaryTable{$group}{avgreachable}),
			td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($summaryTable{$group}{avgavailable}))},$summaryTable{$group}{avgavailable}),
			td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($summaryTable{$group}{avghealth}))},$summaryTable{$group}{avghealth}),
			td({class=>'info Plain',align=>'right',style=>getBGColor(colorResponseTime($summaryTable{$group}{avgresponse},$C->{response_time_threshold}))},$summaryTable{$group}{avgresponse}.' msec')
			);

	}

	print end_table,end_td,end_Tr;

	print start_Tr,start_td({colspan=>'2'}),start_table;
	foreach my $group ( sort keys %{$GT}) {
		print Tr(th({class=>'title',align=>'center',colspan=>'10'},'Group&nbsp;',
								($wantwidget? $group : a({name=>"$group", href=>"#top"},$group)))
				); 
		print Tr(
			td({class=>'header'},a({href=>"$url&sort=node"},'Node')),
			td({class=>'header'},'Device Type'),
			td({class=>'header'},'Role Type'),
			td({class=>'header'},'Net Type'),
			td({class=>'header'},a({href=>"$url&sort=reachable"},'Reachability')),
			td({class=>'header'},a({href=>"$url&sort=available"},'Interface Avail.')),
			td({class=>'header'},a({href=>"$url&sort=health"},'&nbsp;Health&nbsp;')),
			td({class=>'header'},a({href=>"$url&sort=response"},'Response Time'))
			);

		$Q->{sort} = 'node' if $Q->{sort} eq '';
		for my $reportnode (sortall(\%reportTable, $Q->{sort}, $sortdir)) {
			if ($reportTable{$reportnode}{group} eq $group) {
				print Tr(
					td({class=>'info Plain'},a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportTable{$reportnode}{node})),
					td({class=>'info Plain'},$reportTable{$reportnode}{devicetype}),
					td({class=>'info Plain'},$reportTable{$reportnode}{role}),
					td({class=>'info Plain'},$reportTable{$reportnode}{net}),
					td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($reportTable{$reportnode}{reachable}))},
							sprintf($dec_format,$reportTable{$reportnode}{reachable})),
					td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($reportTable{$reportnode}{available}))},
							sprintf($dec_format,$reportTable{$reportnode}{available})),
					td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($reportTable{$reportnode}{health}))},
							sprintf($dec_format,$reportTable{$reportnode}{health})),
					td({class=>'info Plain',align=>'right',style=>getBGColor(colorResponseTime($reportTable{$reportnode}{response},$C->{response_time_threshold}))},
							sprintf($dec_format,$reportTable{$reportnode}{response}).' msec')
				);
			}
		}
 	}
	print end_table,end_td,end_Tr;
	print end_table;
	print end_form if not $Q->{print};

	print pageEnd if (not $Q->{print} and not $wantwidget);
}

#===============

sub availReport {

	my $period = $Q->{period};
	my $summaryhash;
	my %reportTable;
	my %summaryTable;

	my $NT = loadLocalNodeTable();
	my $GT = loadGroupTable();
	my $S = Sys::->new;
	my $NI;

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}

	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	print start_form(-id=>"nmis", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "report_dynamic_avail")
			. hidden(-override => 1, -name => "widget", -value => $widget) 
			if (not $Q->{print});

	print start_table;

	my ($time_elements,$start,$end) = getPeriod(); 
	if ($start eq '' or $end eq '') {
		print Tr(td({class=>'error'},'Illegal time values'));
		return;
	}

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);
		
	my $header = "Availability Metric from $datestamp_start to $datestamp_end";

	# Get each of the nodes info in a HASH for playing with
	foreach my $reportnode (keys %{$NT}) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group})}; 
		if ( getbool($NT->{$reportnode}{active}) ) {
			$S->init(name=>$reportnode,snmp=>'false');
			$NI = $S->ndinfo;
			my $h;
			if (($h = getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode))) {
	   			%reportTable = (%reportTable,%{$h});
				$reportTable{$reportnode}{nodeType} = $NI->{system}{nodeType};
				$reportTable{$reportnode}{node} = $reportnode;
			}
		}
	}

	# if debug, print all
	if ( getbool($Q->{debug}) ) {
		print Dumper(\%reportTable);
	}

	# number of decimals
	my $decimals = $C->{average_decimals} ne "" ? $C->{average_decimals} : 3;
	my $dec_format = "%.".$decimals."f";

	# header with time slice
	print Tr(th({class=>'title',colspan=>'2'},$header));

	print $time_elements if not $Q->{print} ; # time set

	print start_Tr,start_td({colspan=>'2'}),start_table;

	$Q->{sort} = 'node' if $Q->{sort} eq '';
	my $sortdir = ($Q->{sortdir} eq 'fwd') ? 'rev' : 'fwd';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=report_dynamic_avail&sortdir=$sortdir"
			."&time_start=$datestamp_start&time_end=$datestamp_end&period=$Q->{period}&widget=$widget";

	print Tr(th({class=>'title',align=>'center',colspan=>'3'},"% Availability ( Reachability) for all Devices"));
	print Tr(
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=node"},'Node')),
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=nodeType"},'Node Type')),
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=reachable"},'% Availability'))
		);

	foreach my $reportnode (sortall(\%reportTable,$Q->{sort},$sortdir)) {
		if (defined $AU) {next unless $AU->InGroup($NT->{$reportnode}{group})}; 
		print Tr(
			td({class=>'info Plain'},a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain'},$reportTable{$reportnode}{nodeType}),
			td({class=>'info Plain',align=>'right',style=>getBGColor(colorPercentHi($reportTable{$reportnode}{reachable}))},
							sprintf($dec_format,$reportTable{$reportnode}{reachable}))
			);
	}
	print end_table,end_td,end_Tr;
	print end_table;
	print end_form if not $Q->{print};

	purge_files('avail') if $Q->{print};
	print pageEnd if (not $Q->{print} and not $wantwidget);

}

#===============

sub portReport{

	my $header;
	my %portCount;
	my $datestamp_end = returnDateStamp(time());
	my $percentage;
	my $color;
	my $print;
	my $intHash;

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}

	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	print start_table;

	my $II = loadInterfaceInfo();
	my $NT = loadNodeTable();

	my %interfaceInfo = %{$II}; # copy

	# Get each of the interface info in a HASH for playing with
	foreach my $intHash (keys %interfaceInfo) {
		if (defined $AU) {next unless $AU->InGroup($NT->{$interfaceInfo{$intHash}{node}}{group})}; 
		++$portCount{Total}{totalportcount};
		if ( getbool($interfaceInfo{$intHash}{real})  ) {
			++$portCount{Total}{realportcount};
			++$portCount{Total}{"admin-$interfaceInfo{$intHash}{ifAdminStatus}"};
			if ($interfaceInfo{$intHash}{ifOperStatus} eq 'up') {
				++$portCount{Total}{"oper-ok"};
			} else {
				++$portCount{Total}{"oper-other"};
			}
			if ($interfaceInfo{$intHash}{ifSpeed} < 10000000) {
				$interfaceInfo{$intHash}{ifSpeed} =  9999999;
				++$portCount{Total}{'speed-9999999'};
			} else {
				for my $step (1,10,100,1000,10000) {
					my $speed= 10000000*$step;
					if ($interfaceInfo{$intHash}{ifSpeed} >= $speed and $interfaceInfo{$intHash}{ifSpeed} < ($speed*10)) {
						++$portCount{Total}{'speed-'.$speed};
					}
				}
			}
				
#			++$portCount{Total}{"speed-$interfaceInfo{$intHash}{ifSpeed}"};
#			++$portCount{Total}{"duplex-$interfaceInfo{$intHash}{portDuplex}"};
			++$portCount{Total}{'collect'} 
			if (getbool($interfaceInfo{$intHash}{collect}));
		}
	}

	print Tr(th({class=>'title',align=>'center',colspan=>'3'},"$header Port Count Summary Report @ $datestamp_end"));
	print Tr(th({class=>'title',align=>'center',colspan=>'3'},'Summary Port Counts'));

	print Tr(td({class=>'info Plain',colspan=>'3'},"The port count summary is indicative.  Consideration should be given to weight the port counts<BR>according to day of week port types etc."));

	$intHash = "Total";

	print Tr(th({class=>'title',colspan=>'3'},"$intHash Port Totals"));

	print Tr(
		td({class=>'info Plain'},"Port Count Total"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{totalportcount}),
		td({class=>'info Plain'},'&nbsp;'));


	print Tr(
		td({class=>'info Plain'},"Port Count Real"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{realportcount}),
		td({class=>'info Plain'},'&nbsp;'));


	$percentage = sprintf("%.0f",$portCount{$intHash}{'admin-up'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"Admin Up Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'admin-up'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));


	$percentage = sprintf("%.0f",$portCount{$intHash}{'admin-down'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"Admin Down Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'admin-down'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'oper-ok'} / $portCount{$intHash}{realportcount} * 100);
	$color = colorPort($percentage);
	print Tr(
		td({class=>'info Plain'},"Oper Up Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'oper-ok'}),
		td({class=>'info Plain',style=>getBGColor($color),align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'oper-other'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"Oper Down Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'oper-other'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));


	$percentage = sprintf("%.0f",$portCount{$intHash}{'oper-minorFault'} / $portCount{$intHash}{realportcount} * 100);
	if ( $portCount{$intHash}{'oper-minorFault'} > 0 ) { $color = "#FFFF00"; } else { $color = "#00FF00"; }
	print Tr(
		td({class=>'info Plain'},"Oper Minor Fault Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'oper-minorFault'}),
		td({class=>'info Plain',style=>getBGColor($color),align=>'right'},"$percentage%"));

#	$percentage = sprintf("%.0f",$portCount{$intHash}{'duplex-full'} / $portCount{$intHash}{realportcount} * 100);
#	print Tr(
#		td({class=>'info Plain'},"Full Duplex Port Count"),
#		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'duplex-full'}),
#		td({class=>'info Plain',align=>'right'},"$percentage%"));

#	$percentage = sprintf("%.0f",$portCount{$intHash}{'duplex-half'} / $portCount{$intHash}{realportcount} * 100);
#	print Tr(
#		td({class=>'info Plain'},"Half Duplex Port Count"),
#		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'duplex-half'}),
#		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'speed-9999999'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"< 10 megabit Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'speed-9999999'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'speed-10000000'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"10 megabit Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'speed-10000000'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'speed-100000000'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"100 megabit Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'speed-100000000'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'speed-1000000000'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"1 gigabit Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'speed-1000000000'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'speed-10000000000'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"10 gigabit Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'speed-10000000000'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	$percentage = sprintf("%.0f",$portCount{$intHash}{'collect'} / $portCount{$intHash}{realportcount} * 100);
	print Tr(
		td({class=>'info Plain'},"Collect Port Count"),
		td({class=>'info Plain',align=>'right'},$portCount{$intHash}{'collect'}),
		td({class=>'info Plain',align=>'right'},"$percentage%"));

	print end_table;

	purge_files('port') if $Q->{print};
	print pageEnd if (not $Q->{print} and not $wantwidget);

}

#===============

sub responseReport {

	my %reportTable;

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}

	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	my $NT = loadNodeTable();
	my $GT = loadGroupTable();
	my $S = Sys::->new;
	my $NI;

	my ($time_elements,$start,$end) = getPeriod();
	if ($start eq '' or $end eq '') {
		print Tr(td({class=>'error'},'Illegal time values'));
		return;
	}

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	my $header = "Reponse Time Summary from $datestamp_start to $datestamp_end";
	# Get each of the nodes info in a HASH for playing with
	foreach my $reportnode (keys %{$NT}) {
		if (defined $AU) {next unless $AU->InGroup($NT->{$reportnode}{group})}; 
		if ( getbool($NT->{$reportnode}{active}) ) {
			$S->init(name=>$reportnode,snmp=>'false');
			$NI = $S->ndinfo;
			my $h;
			if (($h = getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode))) {
	   			%reportTable = (%reportTable,%{$h});
				$reportTable{$reportnode}{nodeType} = $NI->{system}{nodeType};
				$reportTable{$reportnode}{node} = $NT->{$reportnode}{name};
			}
		}
	}

	# if debug, print all
	if ( getbool($Q->{debug}) ) {
		print Dumper(\%reportTable);
	}

	# number of decimals
	my $decimals = $C->{average_decimals} ne "" ? $C->{average_decimals} : 3;
	my $dec_format = "%.".$decimals."f";

	# start of form
	print start_form(-id=>"nmis", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "report_dynamic_response")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			if (not $Q->{print});


	print start_table;

	# header with time info
	print Tr(th({class=>'title',colspan=>'2'},$header));

	print $time_elements if not $Q->{print} ; # time set

	# header and data summary
	print start_Tr,start_td({width=>'100%',colspan=>'2'}),start_table;

	$Q->{sort} = 'node' if $Q->{sort} eq '';
	my $sortdir = ($Q->{sortdir} eq 'fwd') ? 'rev' : 'fwd';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=report_dynamic_response&sortdir=$sortdir"
			."&time_start=$datestamp_start&time_end=$datestamp_end&period=$Q->{period}&widget=$widget";


	print Tr(th({class=>'title',align=>'center',colspan=>'3'},"Average Response Time for All Devices"));
	print Tr(
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=node"},'Node')),
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=nodeType"},'Node Type')),
			td({class=>'header',align=>'center'},
				a({href=>"$url&sort=response"},'Response Time')),
		);


	# drop the NaN's like this: @sorted = sort { $a <=> $b } grep { $_ == $_ } @unsorted 
	foreach my $reportnode ( sortall(\%reportTable,$Q->{sort},$sortdir)) {
		if (defined $AU) {next unless $AU->InGroup($NT->{$reportnode}{group})}; 
		my $color = colorResponseTime($reportTable{$reportnode}{response});
		print Tr(
			td({class=>'info Plain'},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportTable{$reportnode}{node})),
			td({class=>'info Plain'},$reportTable{$reportnode}{nodeType}),
			td({class=>'info Plain',align=>'right',style=>getBGColor($color)},
						sprintf($dec_format,$reportTable{$reportnode}{response}).' msec')
			);
	}
	print end_table,end_td,end_Tr;
 	print end_table;
	print end_form if not $Q->{print};

	purge_files('response') if $Q->{print};
	print pageEnd if (not $Q->{print} and not $wantwidget);

}

#===============

sub top10Report {

	my %reportTable;

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}


	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	my $NT = loadNodeTable();
	my $GT = loadGroupTable();
	my $II = loadInterfaceInfo();
	my $S = Sys::->new;
	my $NI;

	my ($time_elements,$start,$end) = getPeriod();
	if ($start eq '' or $end eq '') {
		print Tr(td({class=>'error'},'Illegal time values'));
		return;
	}

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	my $header = "Network Top10 from $datestamp_start to $datestamp_end";

	# Get each of the nodes info in a HASH for playing with
	my %cpuTable;
	foreach my $reportnode ( keys %{$NT} ) {
		if (defined $AU) {next unless $AU->InGroup($NT->{$reportnode}{group})}; 
		if ( getbool($NT->{$reportnode}{active}) ) {
			$S->init(name=>$reportnode,snmp=>'false');
			my $NI = $S->ndinfo;
			# reachable, available, health, response
			my $h;
			if (($h = getSummaryStats(sys=>$S,type=>"health",start=>$start,end=>$end,index=>$reportnode))) {
	   			%reportTable = (%reportTable,%{$h});
				# cpu only for routers, switch cpu and memory in practice not an indicator of performance.
				# avgBusy1min, avgBusy5min, ProcMemUsed, ProcMemFree, IOMemUsed, IOMemFree
				if ($NI->{system}{nodeType} eq 'router' 
						and getbool($NI->{system}{collect})) {
					if (($h = getSummaryStats(sys=>$S,type=>"nodehealth",start=>$start,end=>$end,index=>$reportnode))) {
		   				%cpuTable = (%cpuTable,%{$h});
						$reportTable{$reportnode}{nodeType} = $NI->{nodeType} ;
					}
				}
			}
		} # end $reportnode loop
	}
	foreach my $k (keys %cpuTable) {
		foreach my $l (keys %{$cpuTable{$k}}) {
			$cpuTable{$k}{$l} =~ s/NaN/0/ ;
			$cpuTable{$k}{$l} ||= 0 ;
		}
	}

	# now the link stats - by linkname

	my %linkTable;
	my %pktsTable;
	my %downTable;
	my %pvcTable;
	my $prev_node;
	my %interfaceInfo = %{$II}; # copy

	foreach my $int (sortall(\%interfaceInfo,'node','fwd') ) {
		if ( getbool($interfaceInfo{$int}{collect}) ) {
			if (defined $AU) { next unless $AU->InGroup($NT->{$interfaceInfo{$int}{node}}{group}) }; 
			# availability, inputUtil, outputUtil, totalUtil
			my $tmpifDescr = convertIfName($interfaceInfo{$int}{ifDescr});
			my $intf = $interfaceInfo{$int}{ifIndex};

			# save the interface state for the down report
			if ( getbool($interfaceInfo{$int}{collect})
				and $interfaceInfo{$int}{ifAdminStatus} eq "up"
				and $interfaceInfo{$int}{ifOperStatus} ne "up"
				and $interfaceInfo{$int}{ifOperStatus} ne "ok"			
				and $interfaceInfo{$int}{ifOperStatus} ne "dormant"
			) {
				$downTable{$int}{node} = $interfaceInfo{$int}{node} ;
				$downTable{$int}{ifDescr} = $interfaceInfo{$int}{ifDescr} ;
				$downTable{$int}{Description} = $interfaceInfo{$int}{Description} ;
				$downTable{$int}{ifLastChange} = $interfaceInfo{$int}{ifLastChange};
			}

			if ($interfaceInfo{$int}{node} ne $prev_node) {
				$S->init(name=>$interfaceInfo{$int}{node},snmp=>'false');
				$NI = $S->ndinfo;
				$prev_node = $interfaceInfo{$int}{node};
			}
	
			# Availability, inputBits, outputBits
			my $hash = getSummaryStats(sys=>$S,type=>"interface",start=>$start,end=>$end,index=>$intf);
			foreach my $k (keys %{$hash->{$intf}}) {
				$linkTable{$int}{$k} = $hash->{$intf}{$k};
				$linkTable{$int}{$k} =~ s/NaN/0/ ;
				$linkTable{$int}{$k} ||= 0 ;
			}
			$linkTable{$int}{node} = $interfaceInfo{$int}{node} ;
			$linkTable{$int}{ifDescr} = $interfaceInfo{$int}{ifDescr} ;
			$linkTable{$int}{Description} = $interfaceInfo{$int}{Description} ;
	
			$linkTable{$int}{totalBits} = ($linkTable{$int}{inputBits} + $linkTable{$int}{outputBits} ) / 2 ;
			# only report these if pkts rrd available to us.
			my $got_pkts = 0;
			# ifInUcastPkts, ifInNUcastPkts, ifInDiscards, ifInErrors, ifOutUcastPkts, ifOutNUcastPkts, ifOutDiscards, ifOutErrors

			# check if this node does have pkts or pkts_hc, based on graphtype
			my $hcdbname = $S->getDBName(graphtype => "pkts_hc", index => $intf);
			my $dbname = $S->getDBName(graphtype => "pkts", index => $intf);
			if ($hcdbname && -r $hcdbname)
			{
			  $hash = getSummaryStats(sys=>$S,type=>"pkts_hc",start=>$start,end=>$end,index=>$intf);
			  $got_pkts = "pkts_hc";
			}
			elsif ($dbname && -r $dbname)
			{
			  $hash = getSummaryStats(sys=>$S,type=>"pkts",start=>$start,end=>$end,index=>$intf);
			  $got_pkts = "pkts";
			}

			if ( $got_pkts ) {
				foreach my $k (keys %{$hash->{$intf}}) {
					$pktsTable{$int}{$k} = $hash->{$intf}{$k};
					$pktsTable{$int}{$k} =~ s/NaN/0/ ;
					$pktsTable{$int}{$k} ||= 0 ;
				}
	
				$pktsTable{$int}{node} = $interfaceInfo{$int}{node} ;
				$pktsTable{$int}{ifDescr} = $interfaceInfo{$int}{ifDescr} ;
				$pktsTable{$int}{Description} = $interfaceInfo{$int}{Description} ;
				$pktsTable{$int}{totalDiscardsErrors} = ($pktsTable{$int}{ifInDiscards} + $pktsTable{$int}{ifOutDiscards} 
					+ $pktsTable{$int}{ifInErrors} + $pktsTable{$int}{ifOutErrors} ) / 4 ;
			}
			# now for the PVC stats !
			# check if this interface is a frame
			if ( $interfaceInfo{$int}{ifType} =~ /frame-relay/ ) {
				if ( $NI->{pvc} ne "") {
					foreach my $p (keys %{$NI->{pvc}}) {
						my $hash = getSummaryStats(sys=>$S,type=>"pvc",start=>$start,end=>$end,index=>$intf);
							foreach my $k (keys %{$pvcTable{$intf}}) {
							$pvcTable{$int}{$k} = $hash->{$intf}{$k};
							$pvcTable{$int}{$k} =~ s/NaN/0/ ;
						}
						$pvcTable{$int}{totalECNS} = $pvcTable{$int}{ReceivedBECNs} + $pvcTable{$int}{ReceivedFECNs} ;
						$pvcTable{$int}{pvc} = $p ;
						$pvcTable{$int}{node} = $interfaceInfo{$int}{node} ;
					}
				}
			}
		}
	}

	# if debug, print all
	if ( getbool($Q->{debug}) ) {
		print "<pre>";
		print "reportTable\n";
		print Dumper(\%reportTable);
		print "cpuTable\n";
		print Dumper(\%cpuTable);
		print "linkTable\n";
		print Dumper(\%linkTable);
		print "pktsTable\n";
		print Dumper(\%pktsTable);
		print "pvcTable\n";
		print Dumper(\%pvcTable);
		print "</pre>";
	}

	# start of form
	print start_form(-id=>"nmis", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "report_dynamic_top10")
			. hidden(-override => 1, -name => "widget", -value => $widget) 
			if (not $Q->{print});


	print start_table({width=>'65%'});

	# header with time info
	print Tr(th({class=>'title',colspan=>'2'},$header));

	print $time_elements if not $Q->{print} ; # time set, 2 * td

	$Q->{sort} = 'node' if $Q->{sort} eq '';
	my $sortdir = ($Q->{sortdir} eq 'fwd') ? 'rev' : 'fwd';
	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=report_dynamic_response&sortdir=$sortdir"
			."&time_start=$datestamp_start&time_end=$datestamp_end&period=$Q->{period}&widget=$widget";

	print start_Tr,start_td({colspan=>'2'}),start_table;

	# top10 table - Average Response Time
	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Nodes by Average Response Time'));

	# header and data summary
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'7'},'Average Response Time (msec)'),
		);

	my $i=10;
	for my $reportnode ( sortall(\%reportTable,'response','rev')) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$reportTable{$reportnode}{response} =~ /(^\d+)/;
		my $bar = $1 / 2;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'rht Plain'},$reportTable{$reportnode}{response}),
			td({class=>'lft Plain',colspan=>'6'},img({height=>'12',width=>"$bar",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - Average Ping loss
	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Nodes by Average Ping loss'));

 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'2'},'Percent Ping Loss'),
			td({colspan=>'5'},'&nbsp;')
		);

	$i=10;
	for my $reportnode ( sortall(\%reportTable,'loss','rev')) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		last if $reportTable{$reportnode}{loss} == 0;	# early exit if rest are zero.
		$reportTable{$reportnode}{loss} =~ /(^\d+)/;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=$reportnode"},$reportnode)),
			td({class=>'rht Plain'},$reportTable{$reportnode}{loss}),
			td({class=>'lft Plain'},img({height=>'12',width=>"$1",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
			td({colspan=>'5'},'&nbsp;')
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - CPU Load
	# only for routers

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Nodes by CPU Load (Routers only)'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'2'},'CPU Load'),
			td({colspan=>'5'},'&nbsp;')
		);

	$i=10;
	for my $reportnode ( sortall(\%cpuTable,'avgBusy5min','rev')) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$cpuTable{$reportnode}{avgBusy5min} =~ /(^\d+)/;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'rht Plain'},$cpuTable{$reportnode}{avgBusy5min}),
			td({class=>'lft Plain'},img({height=>'12',width=>"$1",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
			td({colspan=>'5'},'&nbsp;')
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - ProcMemUsed
	# only for routers

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Nodes by % Processor Memory Used (Routers only)'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'2'},'Proc Mem Used'),
			td({colspan=>'5'},'&nbsp;')
		);

	$i=10;
	for my $reportnode ( sortall(\%cpuTable,'ProcMemUsed','rev')) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$cpuTable{$reportnode}{ProcMemUsed} =~ /(^\d+)/;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'rht Plain'},$cpuTable{$reportnode}{ProcMemUsed}),
			td({class=>'lft Plain'},img({height=>'12',width=>"$1",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
			td({colspan=>'5'},'&nbsp;')
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - IOMemUsed
	# only for routers

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Nodes by % IO Memory Used (Routers only)'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'2'},'Proc Mem Used'),
			td({colspan=>'5'},'&nbsp;')
		);

	$i=10;
	for my $reportnode ( sortall(\%cpuTable,'IOMemUsed','rev')) {
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$cpuTable{$reportnode}{IOMemUsed} =~ /(^\d+)/;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'rht Plain'},$cpuTable{$reportnode}{IOMemUsed}),
			td({class=>'lft Plain'},img({height=>'12',width=>"$1",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
			td({colspan=>'5'},'&nbsp;')
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - Interfaces by Percent Utilization
	# inputUtil, outputUtil, totalUtil

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Interfaces by Percent Utilization'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'3'},'Interface'),
			td({class=>'header',align=>'center',colspan=>'2'},'Receive'),
			td({class=>'header',align=>'center',colspan=>'2'},'Transmit')
		);

	$i=10;
	for my $reportlink ( sortall(\%linkTable,'totalUtil','rev')) {
		last if $linkTable{$reportlink}{inputUtil} and $linkTable{$reportlink}{outputUtil} == 0;
		if (defined $AU) { next unless $AU->InGroup($NT->{$linkTable{$reportlink}{node}}{group}) }; 
		my $reportnode = $linkTable{$reportlink}{node} ;
		$linkTable{$reportlink}{inputUtil} =~ /(^\d+)/;
		my $input = $1;
		$linkTable{$reportlink}{outputUtil} =~ /(^\d+)/;
		my $output = $1;
		$linkTable{$reportlink}{Description} = '' if $linkTable{$reportlink}{Description} =~ /nosuch/i ;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain',colspan=>'3'},"$linkTable{$reportlink}{ifDescr} $linkTable{$reportlink}{Description}"),
			td({class=>'rht Plain'},"$linkTable{$reportlink}{inputUtil} %"),
			td({class=>'lft Plain'},img({height=>'12',width=>"$input",src=>"$C->{'<menu_url_base>'}/img/bar.png"})),
			td({class=>'rht Plain'},"$linkTable{$reportlink}{outputUtil} %"),
			td({class=>'lft Plain'},img({height=>'12',width=>"$output",src=>"$C->{'<menu_url_base>'}/img/bar.png"}))
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - Interfaces by Traffic
	# inputBits, outputBits, totalBits

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Interfaces by Traffic'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'3'},'Interface'),
			td({class=>'header',align=>'center',colspan=>'2'},'Receive'),
			td({class=>'header',align=>'center',colspan=>'2'},'Transmit')
		);

	$i=10;
	for my $reportlink ( sortall(\%linkTable,'totalBits','rev')) {
		last if $linkTable{$reportlink}{inputBits} and $linkTable{$reportlink}{outputBits} == 0; 
		my $reportnode = $linkTable{$reportlink}{node} ;
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$linkTable{$reportlink}{Description} = '' if $linkTable{$reportlink}{Description} =~ /nosuch/i ;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain',colspan=>'3'},"$linkTable{$reportlink}{ifDescr} $linkTable{$reportlink}{Description}"),
			td({class=>'info Plain',colspan=>'2',align=>'right'},getBits($linkTable{$reportlink}{inputBits},'ps')),
			td({class=>'info Plain',colspan=>'2',align=>'right'},getBits($linkTable{$reportlink}{outputBits},'ps'))
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - PVC fecns and becns
	# ReceivedBECNs, ReceivedFECNs

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},"Top 10 PVC BECN's and FECN's"));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'3'},'PVC'),
			td({class=>'header',align=>'center',colspan=>'2'},'Receive BECNS'),
			td({class=>'header',align=>'center',colspan=>'2'},'Receive FECNS')
		);

	$i=10;
	for my $reportlink ( sortall(\%pvcTable,'totalECNS','rev')) {
		last if $pvcTable{$reportlink}{totalECNS} == 0;	# early exit if rest are zero.
		my $reportnode = $pvcTable{$reportlink}{node} ;
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$cpuTable{$reportnode}{IOMemUsed} =~ /(^\d+)/;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain',colspan=>'3'},$pvcTable{$reportlink}{pvc}),
			td({class=>'info Plain',colspan=>'2',align=>'right'},$pvcTable{$reportlink}{ReceivedBECNs}),
			td({class=>'info Plain',colspan=>'2',align=>'right'},$pvcTable{$reportlink}{ReceivedFECNs})
		);
		# loop control
		last if --$i == 0;
	}

	# top10 table - Errors and Discards
	# ifInUcastPkts, ifInNUcastPkts, ifInDiscards, ifInErrors, ifOutUcastPkts, ifOutNUcastPkts, ifOutDiscards, ifOutErrors

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Top 10 Errors and Discards'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'3'},'Interface'),
			td({class=>'header',align=>'center'},'Receive Errors'),
			td({class=>'header',align=>'center'},'Receive Discards'),
			td({class=>'header',align=>'center'},'Transmit Errors'),
			td({class=>'header',align=>'center'},'Transmit Discards')
		);

	$i=10;
	for my $reportlink ( sortall(\%pktsTable,'totalDiscardsErrors','rev')) {
		last if $pktsTable{$reportlink}{totalDiscardsErrors} == 0;	# early exit if rest are zero.
		my $reportnode = $pktsTable{$reportlink}{node} ;
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$pktsTable{$reportlink}{Description} = '' if $pktsTable{$reportlink}{Description} =~ /nosuch/i ;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain',colspan=>'3'},"$pktsTable{$reportlink}{ifDescr} $pktsTable{$reportlink}{Description}"),
			td({class=>'info Plain',align=>'right'},$pktsTable{$reportlink}{ifInErrors}),
			td({class=>'info Plain',align=>'right'},$pktsTable{$reportlink}{ifInDiscards}),
			td({class=>'info Plain',align=>'right'},$pktsTable{$reportlink}{ifOutErrors}),
			td({class=>'info Plain',align=>'right'},$pktsTable{$reportlink}{ifOutDiscards})
		);
		# loop control
		last if --$i == 0;
	}

	#  table - Down Interfaces - sorts by modified ifLastChange

	print Tr(th({class=>'title',align=>'center',colspan=>'8'},'Down Interfaces'));
 	print Tr(
			td({class=>'header',align=>'center'},'Node'),
			td({class=>'header',align=>'center',colspan=>'3'},'Interface'),
			td({class=>'header',align=>'center',colspan=>'4'},'Last Change')
		);

	$i=10;
	for my $reportlink ( sortall(\%downTable,'ifLastChange','rev')) {
		my $reportnode = $downTable{$reportlink}{node} ;
		if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group}) }; 
		$downTable{$reportlink}{Description} = '' if $downTable{$reportlink}{Description} =~ /nosuch/i ;
		print Tr(
			td({class=>"info Plain $nodewrap"},
				a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
			td({class=>'info Plain',colspan=>'3',width=>'50%'},"$downTable{$reportlink}{ifDescr} $downTable{$reportlink}{Description}"),
			td({class=>'info Plain',colspan=>'4',align=>'center'},$downTable{$reportlink}{ifLastChange})
		);
		# loop control
		last if --$i == 0;
	}
	print end_table,end_td,end_Tr;
	print end_table;
	print end_form if not $Q->{print};

	purge_files('top10') if $Q->{print};
	print pageEnd if (not $Q->{print} and not $wantwidget);

}

#===============

sub outageReport {

	#start of page
	if (not $Q->{print})
	{
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
	}

	return unless $Q->{print} or $AU->CheckAccess('rpt_dynamic'); # same as menu

	my ($time_elements,$start,$end) = getPeriod();
	if ($start eq '' or $end eq '') {
		print Tr(td({class=>'error'},'Illegal time values'));
		return;
	}

	my ($level_elements, $level) = getLevel(); # node or interface

	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	my $NT = loadNodeTable();
	my $OT = loadOutageTable();

	my $index;
	my %logreport;
	my @logline;
	my $logfile;
	my $i = 0;
	my $found_start = 'false';
	my $outime;

	# start of form
	print start_form(-id=>"nmis", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "report_dynamic_outage")
			. hidden(-override => 1, -name => "widget", -value => $widget) 
			if (not $Q->{print});


	print start_table();

	# header with time info
	print Tr(th({class=>'title',colspan=>'2'},'Outage Report'));

	print $time_elements if not $Q->{print} ; # time set, 2 * td

	print $level_elements if not $Q->{print} ;

	$Q->{sort} = 'time' if $Q->{sort} eq '';
	$Q->{sortdir} = ($Q->{sortdir} eq 'fwd') ? 'rev' : 'fwd'; # toggle
	
		
	# set the length if wanted...
	my $count;
		
	my %eventfile;
	my $dir = $C->{'<nmis_logs>'};
	# create a list of logfiles...
	opendir (DIR, "$dir");
	my @dirlist = readdir DIR;
	closedir DIR;
		
	if ($Q->{debug}) { print "Found $#dirlist entries\n"; }
		
	foreach my $dir (@dirlist) {
		# grab file names that match the desired report type.
		# add back directory
		$dir = $C->{'<nmis_logs>'} . '/' . $dir ;
		if ( $dir =~ /^$C->{event_log}/ ) {
			$eventfile{$dir} = $dir;
		}
	}
	foreach $logfile ( sort keys %eventfile ) {
		if ( $logfile =~ /\.gz$/ ) {
			$logfile = "gzip -dc $logfile |";
		}
		# Handling gzip files which are not files which need to be locked.
		open (DATA, $logfile) or warn returnTime." outageReport, Cannot open the file $logfile. $!\n";
		# find the line with the entry in and store in hash
		while (<DATA>) {
			chomp;
			my ( $time, $node, $event, $eventlevel, $element, $details ) = split /,/, $_;
			# event log time is already in epoch time
			if ($time > $start) {
				if ($time > $end ) { close DATA; last; } # done
				#
			  	if ($level eq 'node' and $event =~ /^Node Up/i) {
					$logreport{$i}{time} = $time;
					$logreport{$i}{node} = $node;
					$logreport{$i}{outype} = "Node Outage";
	
					# 'Time=00:00:34 change=512'
					if ($details =~ m/.*Time=(\d+:\d+:\d+)/i) {
						$logreport{$i}{outime} = $1;
					}

					if ($details =~ m/.*Change=(.*)/i) {
						$logreport{$i}{outage} = $1;
					}
					$i++;
				}
			  	elsif ($level eq 'interface' and $event =~ /^Interface Up/i) {
					$logreport{$i}{time} = $time;
					$logreport{$i}{node} = $node;
					$logreport{$i}{outype} = "Interface Outage";
	
					# 'Time=00:00:04 change=512'
					$logreport{$i}{element} = $element;
					if ($details =~ m/.*Time=(\d+:\d+:\d+)/i) {
						$logreport{$i}{outime} = $1;
					}

					if ($details =~ m/.*Change=(.*)/i) {
						$logreport{$i}{outage} = $1;
					}
					$i++;
				}
			} else {
				 $found_start = 'true';
			}
		}
		close DATA;
	} # end of file list
		
	# if debug, print all
	#if ( $Q->{debug} eq "true" ) {
	#	print Dumper(\%logreport);
	#}


	print start_Tr,start_td({colspan=>'2'}),start_table;

	print Tr(th({class=>'title',align=>'center',colspan=>'6'},
			"Outage Report, $datestamp_start to $datestamp_end"));

	my $url = url(-absolute=>1)."?conf=$Q->{conf}&act=report_dynamic_outage&level=$Q->{level}"
					."&time_start=$Q->{time_start}&time_end=$Q->{time_end}&widget=$widget"
					."&sortdir=$Q->{sortdir}&period=$Q->{period}";

	print Tr(
		td({class=>'header'},a({href=>"$url&sort=time"},'Time' )),
		td({class=>'header'},a({href=>"$url&sort=node"},'Node' )),
		td({class=>'header'},a({href=>"$url&sort=outype"},'Outage Type' )),
		td({class=>'header'},a({href=>"$url&sort=outime"},'Outage Time' )),
		td({class=>'header'},'Element'),
		td({class=>'header'},'Planned Outage')
		);

	if ($i > 0) {
		for my $index ( sortall(\%logreport,$Q->{sort},$Q->{sortdir})) {
			my $color = colorTime($logreport{$index}{outime});
			my $reportnode = $logreport{$index}{node} ;
			if (defined $AU) { next unless $AU->InGroup($NT->{$reportnode}{group})}; 
			print Tr(
				td({class=>'info Plain',style=>getBGColor($color)},returnDateStamp($logreport{$index}{time})),
				td({class=>'info Plain',style=>getBGColor($color)},
					a({href=>"network.pl?conf=$Q->{conf}&act=network_node_view&widget=$widget&node=".uri_escape($reportnode)},$reportnode)),
				td({class=>'info Plain',style=>getBGColor($color)},$logreport{$index}{outype}),
				td({class=>'info Plain',style=>getBGColor($color)},$logreport{$index}{outime}),
				eval { return $logreport{$index}{element} ? td({class=>'info Plain',style=>getBGColor($color)},$logreport{$index}{element}) : td({class=>'info Plain'},'&nbsp;');},
				eval { return $logreport{$index}{outage} ? td({class=>'info Plain',style=>getBGColor($color)},$logreport{$index}{outage}) : td({class=>'info Plain'},'&nbsp;');}
				);
		}
	} else {
		print Tr(td({class=>'info Plain'},'no entries found'));
	}

#	if ($found_start eq 'false'){
#		print Tr(td({class=>'error'},'start time before first row found'));
#	}

	print end_table,end_td,end_Tr;
	print end_table;
	print end_form if not $Q->{print};


	purge_files('outage') if $Q->{print};
	print pageEnd if (not $Q->{print} and not $wantwidget);

} # end of report = outage


#===============

sub nodedetailsReport {

	if (not $AU->CheckAccess('rpt_dynamic','check')) 
	{ 
		print header($headeropts);
		pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);
		$AU->CheckAccess('rpt_nodedetails');
		print pageEnd if (not $Q->{print} and not $wantwidget);
		return;
	}

	my $NT = loadNodeTable();
	my $GT = loadGroupTable();

	# this will launch Excel - as it is the default application handler for .csv files
	print "Content-type: application/octet-stream;\n";
	print "Content-disposition: inline; filename=nodedetails.csv\n";
	# seems to be needed for IE
	print "Cache-control: private\n";
    print "Pragma: no-cache\n";
    print "Expires: 0\n\n";

	my @line;
	println( 'Name','Type','Location','System Uptime','Node Vendor','NodeModel', 'SystemName','S/N','Chassis','ProcMem','Version');

	foreach my $group (sort keys %{$GT}) {
		if (defined $AU) { next unless $AU->InGroup($group) }; 
		foreach my $node (sort keys %{$NT}) {
			if ( $NT->{$node}{group} eq "$group" ) {

				my $NI = readFiletoHash(name=>"$node-node");

				undef @line;

				push( @line, $NI->{system}{name});
				push( @line, $NI->{system}{nodeType});
				push( @line, $NI->{system}{sysLocation});
				push( @line, $NI->{system}{sysUpTime});
				push( @line, $NI->{system}{nodeVendor});
				push( @line, $NI->{system}{nodeModel});
				push( @line, $NI->{system}{sysObjectName});
				push( @line, $NI->{system}{serialNum});
				push( @line, $NI->{system}{chassisVer});
				push( @line, $NI->{system}{processorRam});
				
				my $detailvar = $NI->{system}{sysDescr};
				$detailvar =~ s/^.*WS/WS/g;
				$detailvar =~ s/Cisco Catalyst Operating System Software/CatOS/g;
				$detailvar =~ s/Copyright.*$//g;
				$detailvar =~ s/TAC Support.*$//g;
				$detailvar =~ s/RELEASE.*$//g;
				$detailvar =~ s/Cisco.*tm\) //g;
				# drop any 'built by'
				$detailvar =~ s/built by.*$//;
				# maybe a windows box ?
				$detailvar =~ s/^.*Windows/Windows/;
				
				push( @line, $detailvar);
				println( @line );
			}
		}
	}
	sub println {
	    local $\ = "\n";			# print newline
	    local $, = ',';				# print seperator between arguments
		    # strip embedded commas
	    my @parms = @_;				# must copy or localise @_ for the 'for' loop to work.
	    for (@parms) { s/,/_/g }
	    print @parms;
	}
}	

#===============

sub storedReport {

	my %reportTable;
	my $header;
	my @daily;
	my @weekly;
	my @monthly;

	#start of page
	print header($headeropts);
	pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);

	return unless $AU->CheckAccess('rpt_stored'); # same as menu

	my $func = $Q->{act};
	$func =~ s/report_stored_//i;

	my ( $index, $type, $span );
	opendir (DIR, "$C->{report_root}");
	my @dirlist = readdir DIR;
	closedir DIR;

	foreach my $dir (@dirlist) {

		# grab file names that match the desired report type.
		# index by date to allow sorting
		if ( $dir =~ /^$func/ ) {

			if ( $dir =~ m/(\w+)-(\d\d)-(\d\d)-(\d\d\d\d)/ ) {	# capture the date xx-xx-xxxx
				$index = $4."-".$3."-".$2."-".$1;
			}
			elsif ( $dir =~ m/month-(\d\d)-(\d\d\d\d)/ ) {	# capture the date month-xx-xxxx
				$index = $2."-".$1."-01-month";
			}
			$reportTable{$index}{dir} = $dir;
					
			# formulate a tidy report name
			$dir =~ s/\.html//;
			if ( $dir =~ m/month-(\d\d)-(\d\d\d\d)/ ) {		# month-01-2006.html
				$reportTable{$index}{link} = 'monthly '.convertMonth($1) . " $2";
			}
			elsif ( $dir =~ m/(day|week|month)-(\d\d)-(\d\d)-(\d\d\d\d)-(\w+)/ ) {		# day|week-01-01-2006-Sun.html
				$reportTable{$index}{link} = "${1}ly ".$5 . " $2 " . convertMonth($3) . " $4";
				$reportTable{$index}{link} =~ s/dayly/daily/;
			}
			elsif ( $dir =~ m/(\w+)-(\w+)-(\d\d)-(\d\d)-(\d\d\d\d)-(\w+)/ ) { 	# <type>-day|week|month-01-01-2006-Mon.html
				$reportTable{$index}{link} = "${2}ly ".$6 . " $3 " . convertMonth($4) . " $5";

			}
			else {
				$reportTable{$index}{link} = 'error - filename not recogonised';
			}
		}
	}

	print start_table;

	$header = 'Availability' if $func eq 'avail';
	$header = 'Health' if $func eq 'health';
	$header = 'Response time' if $func eq 'response';
	$header = 'Top 10' if $func eq 'top10';
	$header = 'Outage' if $func eq 'outage';
	$header = 'Port Counts' if $func eq 'port';

	$header .= ' Stored Reports';
			
	print Tr(th({class=>'title',colspan=>'3'},$header));

	foreach $index (reverse sort keys %reportTable ) {
		if ($reportTable{$index}{link} =~ /^daily/) { push @daily,$index; }
		elsif ($reportTable{$index}{link} =~ /^weekly/) { push @weekly,$index; }
		elsif ($reportTable{$index}{link} =~ /^monthly/) { push @monthly,$index; }
	}

	while (@daily or @weekly or @monthly) {
		print start_Tr;
		if (@daily) { printa(shift @daily,\%reportTable); } else { printe(); }
		if (@weekly) { printa(shift @weekly,\%reportTable); } else { printe(); }
		if (@monthly) { printa(shift @monthly,\%reportTable); } else { printe(); }
		print end_Tr;
	}

	print end_table;
	print pageEnd if (not $Q->{print} and not $wantwidget);

	sub printa {
		my $index = shift;
		my $table = shift;
		print td({class=>'info Plain'},
			a({href=>"reports.pl?conf=$Q->{conf}&act=report_stored_file&file=$table->{$index}{dir}"},$table->{$index}{link}));
	}
	sub printe {
		print td({class=>'info Plain'},'&nbsp;');
	}
}

#===============

sub purge_files {
	my $func = shift;

	return if $C->{report_files_max} eq '' or $C->{report_files_max} < 10; # lower limit

	my $files_max = $C->{report_files_max};
	my %reportTable;

	my ( $index, $type);
	opendir (DIR, "$C->{report_root}");
	my @dirlist = readdir DIR;
	closedir DIR;

	foreach my $dir (@dirlist) {

		# grab file names that match the desired report type.
		# index by date to allow sorting
		if ( $dir =~ /^$func/ ) {

			if ( $dir =~ m/(\w+)-(\d\d)-(\d\d)-(\d\d\d\d)/ ) {	# capture the date xx-xx-xxxx
				$index = $4."-".$3."-".$2."-".$1;
			}
			elsif ( $dir =~ m/month-(\d\d)-(\d\d\d\d)/ ) {	# capture the date month-xx-xxxx
				$index = $2."-".$1."-01-month";
			}
			$reportTable{$index}{dir} = $dir;
					
			# formulate a tidy report name
			$dir =~ s/\.html//;
			if ( $dir =~ m/month-(\d\d)-(\d\d\d\d)/ ) {		# month-01-2006.html
				$reportTable{$index}{link} = 'monthly '.convertMonth($1) . " $2";
			}
			elsif ( $dir =~ m/(day|week|month)-(\d\d)-(\d\d)-(\d\d\d\d)-(\w+)/ ) {		# day|week-01-01-2006-Sun.html
				$reportTable{$index}{link} = "${1}ly ".$5 . " $2 " . convertMonth($3) . " $4";
				$reportTable{$index}{link} =~ s/dayly/daily/;
			}
			elsif ( $dir =~ m/(\w+)-(\w+)-(\d\d)-(\d\d)-(\d\d\d\d)-(\w+)/ ) { 	# <type>-day|week|month-01-01-2006-Mon.html
				$reportTable{$index}{link} = "${2}ly ".$6 . " $3 " . convertMonth($4) . " $5";

			}
			else {
				$reportTable{$index}{link} = 'error - filename not recogonised';
			}
		}
	}

	my $d_cnt=0; 
	my $w_cnt=0; 
	my $m_cnt=0;

	foreach $index (reverse sort keys %reportTable ) {
		if ($reportTable{$index}{link} =~ /^daily/) {
			if ($d_cnt++ >= $files_max) { unlink  "$C->{report_root}/$reportTable{$index}{dir}"; }
		}
		elsif ($reportTable{$index}{link} =~ /^weekly/) { 
			if ($w_cnt++ >= $files_max) { unlink  "$C->{report_root}/$reportTable{$index}{dir}"; }
		}
		elsif ($reportTable{$index}{link} =~ /^monthly/) { 
			if ($m_cnt++ >= $files_max) { unlink  "$C->{report_root}/$reportTable{$index}{dir}"; }
		}
	}
}

#===============

sub fileReport {

	print header($headeropts);
	pageStart(title => "NMIS Reports", refresh => $Q->{refresh}) 	if (!$wantwidget);

	return unless $AU->CheckAccess('rpt_stored'); # same as menu

	if (sysopen(HTML, "$C->{report_root}/$Q->{file}", O_RDONLY)) {
		while (<HTML>){
			my $line = $_;
			$line =~ s/<a.*>(.*)(<\/a>)/$1/; # remove anchors
			print $line;
		}
		print pageEnd if (not $Q->{print} and not $wantwidget);
		close HTML;
	} else {
		print Tr(td({class=>'error'},"Cannot read report file $C->{report_root}/$Q->{file}"));
		print pageEnd if (not $Q->{print} and not $wantwidget);
	}
}

#===============

sub getPeriod {

	my $elements;
	my $start;
	my $end;

	my $permin = '15min';

	$Q->{period} = 'day' if $Q->{time_start} eq '';

	if ($Q->{period} ne $Q->{prevperiod} and $Q->{period} ne '') {
		# length changed
		if ($Q->{period} =~ /(\d+)min/) {
			$start = convertTime($1,'minutes');
		} else {
			$start = convertTime("1","$Q->{period}s");
		}
		$end = time();
	} else {
		$start = parsedate($Q->{time_start});
		$end = parsedate($Q->{time_end});
		$Q->{period} = '';
	}
	my $datestamp_start = returnDateStamp($start);
	my $datestamp_end = returnDateStamp($end);

	$elements = hidden(-name=>'prevperiod', -default=>$Q->{period},override=>'1');

	$elements .= Tr(
			td({class=>'info Plain'},'Select Period',
				popup_menu(-name=>'period',
									 -onchange => ($wantwidget? "get('nmis');" : "submit()" ),
									 override=>'1',
								-values=>['',$permin,'day','week','month'],-default=>"$Q->{period}"),'&nbsp;&nbsp;or'),
				td({class=>'info Plain'},'&nbsp;Start&nbsp;',
				textfield(-name=>"time_start",size=>'23',value=>$datestamp_start,override=>'1'),
				'&nbsp;End&nbsp;',
				textfield(-name=>"time_end",size=>'23',value=>$datestamp_end,override=>'1'),
				'&nbsp;',
				button(-name=>"button", 
							 onclick => ($wantwidget? "get('nmis');" : "submit()" ),
							 -value=>"Go")));

	return $elements,$start,$end;	
}

sub getLevel {

	my $level;
	my $elements;

	$level = ($Q->{level} eq '') ? 'node' : $Q->{level};

	$elements = Tr(
			td({class=>'info Plain',colspan=>'2'},'Based on ',
				radio_group(-name=>'level',-values=>['node','interface'],-default=>$level,
										-onchange=> ($wantwidget? "get('nmis');" : "submit()" ))));

	return $elements,$level;
}
