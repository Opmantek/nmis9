#!/usr/bin/perl
#
## $Id: rrddraw.pl,v 8.10 2012/08/24 05:35:22 keiths Exp $
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

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";
#
#****** Shouldn't be anything else to customise below here *******************

require 5;

use strict;
use RRDs 1.4004;
use func;
use Sys;
use NMIS;
use Data::Dumper;

use CGI qw(:standard);

use vars qw($q $Q $C $AU);

$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars;

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };
$C->{auth_require} = 0; # bypass auth

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

#======================================================================

# select function
if ($Q->{act} eq 'draw_graph_view') {	rrdDraw();
} else { notfound(); }

exit;

sub notfound {
	logMsg("rrddraw; Command unknown act=$Q->{act}");
}

#============================================================================

sub error {
	print header($headeropts);
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}

#============================================================================

sub rrdDraw {
	my %args = @_;

	# Break the query up for the names
	my $type = $Q->{obj};
	my $nodename = $Q->{node};
	my $debug = $Q->{debug};
	my $grp = $Q->{group};
	my $graphtype = $Q->{graphtype};
	my $graphstart = $Q->{graphstart};
	my $width = $Q->{width};
	my $height = $Q->{height};
	my $start = $Q->{start};
	my $end = $Q->{end};
	my $intf = $Q->{intf};
	my $item = $Q->{item};
	my $filename = $Q->{filename};

	my $S = Sys::->new; # get system object
	$S->init(name=>$nodename,snmp=>'false');
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;

	### 2012-02-06 keiths, handling default graph length
	# default is hours!
	my $graphlength = $C->{graph_amount};
	if ( $C->{graph_unit} eq "days" ) {
		$graphlength = $C->{graph_amount} * 24;
	}

	if ( $start eq "" or $start == 0) {
		$start = time() - ($graphlength*3600);
	}
	if ( $end eq "" or $end == 0) {
		$end = time();
	}

	my $ERROR;
	my $graphret;
	my $xs;
	my $ys;
	my @options;
	my @opt;
	my $db;

	if ($graphtype eq 'metrics') {
		$item = $Q->{group};
		$intf = "";
	}

	# special graphtypes: cbqos is dynamic (multiple inputs create one graph), ditto calls
	if ($graphtype =~ /cbqos/) {
		@opt = graphCBQoS(sys=>$S,
											graphtype=>$graphtype,
											intf=>$intf,
											item=>$item,
											start=>$start,end=>$end,width=>$width,height=>$height);
	} elsif ($graphtype eq "calls") {
		@opt = graphCalls(sys=>$S,graphtype=>$graphtype,intf=>$intf,item=>$item,start=>$start,end=>$end,width=>$width,height=>$height);
	} else {

		if (!($db = $S->getDBName(graphtype=>$graphtype,index=>$intf,item=>$item)) ) { # get database name from node info
			error();
			return 0;
		}

		my $graph;
		if (!($graph = loadTable(dir=>'models',name=>"Graph-$graphtype")) 
				or !keys %$graph ) {
			logMsg("ERROR failed to read Graph-$graphtype!");
			error();
			return 0;
		}

		my $title = 'standard';
		my $vlabel = 'standard';
		my $size = 'standard';
		my $ttl;
		my $lbl;

		$title = 'short' if $width <= 400 and $graph->{title}{short} ne "";

		$vlabel = 'short' if $width <= 400 and $graph->{vlabel}{short} ne "";

		$vlabel = 'split' if getbool($C->{graph_split}) and $graph->{vlabel}{split} ne "";

		$size = 'small' if $width <= 400 and $graph->{option}{small} ne "";


		if (($ttl = $graph->{title}{$title}) eq "") {
			logMsg("no title->$title found in Graph-$graphtype");
		}
		if (($lbl = $graph->{vlabel}{$vlabel}) eq "") {
			logMsg("no vlabel->$vlabel found in Graph-$graphtype");
		}

		@opt = (
				"--title", $ttl,
				"--vertical-label", $lbl,
				"--start", $start,
				"--end", $end,
				"--width", $width,
				"--height", $height,
				"--imgformat", "PNG",
				"--interlace",
				"--disable-rrdtool-tag",
				"--color", 'BACK#ffffff',      # Background Color
				"--color", 'SHADEA#ffffff',    # Left and Top Border Color
				"--color", 'SHADEB#ffffff',    # was CFCFCF
				"--color", 'CANVAS#FFFFFF',    # Canvas (Grid Background)
				"--color", 'GRID#E2E2E2',      # Grid Line ColorGRID#808020'
				"--color", 'MGRID#EBBBBB',     # Major Grid Line ColorMGRID#80c080
				"--color", 'FONT#222222',      # Font Color
				"--color", 'ARROW#924040',     # Arrow Color for X/Y Axis
				"--color", 'FRAME#808080'      # Canvas Frame Color
		);

		if ($width > 400) {
			push(@opt,"--font", $C->{graph_default_font_standard}) if $C->{graph_default_font_standard};
		}
		else {
			push(@opt,"--font", $C->{graph_default_font_small}) if $C->{graph_default_font_small};
		}

		# add option rules
		foreach my $str (@{$graph->{option}{$size}}) {
			push @opt, $str;
		}

		# for type=service, add in any extra DS as a gprint (for now)
		if ($graphtype eq 'service')
		{
			my $rrdinfo = RRDs::info($db);
			for my $dslist (grep(/^ds.+\.index$/,keys %$rrdinfo))
			{
				my $dsname = $dslist; $dsname =~ s/^ds\[(.+)\]\.index/$1/;
				# ignore the already covered standard DSs
				next if ($dsname eq "responsetime" or $dsname eq "service" 
								 # or the ones that the cpu and mem graphs show
								 or $dsname eq "cpu" or $dsname eq "memory");
				
				push @opt,"DEF:$dsname=\$database:$dsname:AVERAGE",
				"COMMENT:\\n",
				"GPRINT:$dsname:AVERAGE:Avg $dsname %.2lf%s",
				"GPRINT:$dsname:MIN:Min $dsname %.2lf%s",
				"GPRINT:$dsname:MAX:Max $dsname %.2lf%s\\n";
			}
		}
	}

	# define length of graph
	my $l;
	if (($end - $start) < 3600) {
		$l = int(($end - $start) / 60) . " minutes";
	} elsif (($end - $start) < (3600*48)) {
		$l = int(($end - $start) / (3600)) . " hours";
	} else {
		$l = int(($end - $start) / (3600*24)) . " days";
	}

	{
		# scalars must be global
		no strict;
		if ($intf ne "") {
			$indx = $intf;
			$ifDescr = $IF->{$intf}{ifDescr};
			$ifSpeed = $IF->{$intf}{ifSpeed};
			$ifSpeedIn = $IF->{$intf}{ifSpeed};
			$ifSpeedOut = $IF->{$intf}{ifSpeed};			
			$ifSpeedIn = $IF->{$intf}{ifSpeedIn} if $IF->{$intf}{ifSpeedIn};
			$ifSpeedOut = $IF->{$intf}{ifSpeedOut} if $IF->{$intf}{ifSpeedOut};
			if ($ifSpeed eq "auto" ) {
				$ifSpeed = 10000000;
			}
			
			if ( $IF->{$intf}{ifSpeedIn} and $IF->{$intf}{ifSpeedOut} ) {
				$speed = "IN\\: ". convertIfSpeed($ifSpeedIn) ." OUT\\: ". convertIfSpeed($ifSpeedOut);
			}
			else {
				$speed = convertIfSpeed($ifSpeed);	
			}
		}
		$node = $NI->{system}{name};
		$datestamp_start = returnDateStamp($start);
		$datestamp_end = returnDateStamp($end);
		$datestamp = returnDateStamp(time);
		$database = $db;
		$group = $grp;
		$itm = $item;
		$length = $l;
		$split = getbool($C->{graph_split}) ? -1 : 1 ;
		$GLINE = getbool($C->{graph_split}) ? "AREA" : "LINE1" ;
		$weight = 0.983;
	
		foreach my $str (@opt) {
			$str =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \'\$$1\' ";}}egx;
			if ($str =~ /ERROR/) {
				logMsg("ERROR in expanding variables, $str");
				return;
			}
			push @options,$str;
		}
	}

	# Do the graph!
	### 2012-01-30 keiths, deprecating the need for Win32 support and Image::Resize.  But leaving there for PersistentPerl (to be sure).
	# This works around a bug in RRDTool which doesn't like writing to STDOUT on Win32!
	# Also PersistentPerl needs this workaround
	if ( $^O eq "MSWin32" ) { # or (eval {require PersistentPerl} && PersistentPerl->i_am_perperl) ) {
		my $buff;
		my $random = int(rand(1000)) + 25;
		my $tmpimg = "$C->{'<nmis_var>'}/rrdDraw-$random.png";
	
		print "Content-type: image/png\n\n";
		($graphret,$xs,$ys) = RRDs::graph($tmpimg, @options);
		if ( -f $tmpimg ) {
	
			open(IMG,"$tmpimg") or logMsg("$NI->{system}{name}, ERROR: problem with $tmpimg; $!");
			binmode(IMG);
			binmode(STDOUT);
			while (read(IMG, $buff, 8 * 2**10)) {
				print STDOUT $buff;
			}
			close(IMG);
			unlink($tmpimg) or logMsg("$NI->{system}{name}, Can't delete $tmpimg: $!");
		}
	} else {
		# buffer stdout to avoid Apache timing out on the header tag while waiting for the PNG image stream from RRDs
		select((select(STDOUT), $| = 1)[0]);
		print "Content-type: image/png\n\n";
		if( $filename eq "" ) {
			($graphret,$xs,$ys) = RRDs::graph('-', @options);
		}
		else {
			($graphret,$xs,$ys) = RRDs::graph($filename, @options);
		}
		select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout


		if ($ERROR = RRDs::error) {
			logMsg("$db Graphing Error for $graphtype: $ERROR");
	
		} else {
			#return "GIF Size: ${xs}x${ys}\n";
			#print "Graph Return:\n",(join "\n", @$graphret),"\n\n";
		}
	}

	# Cologne and Stephane CBQoS Support
	# this handles both cisco and huawei flavour cbqos
	sub graphCBQoS 
	{
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $graphtype = $args{graphtype};
		my $intf = $args{intf};
		my $item = $args{item};
		my $start = $args{start};
		my $end = $args{end};
		my $width = $args{width};
		my $height = $args{height};
		my $debug = $Q->{debug};

		my $database;
		my @opt;
		my $title;

		# order the names, find colors and bandwidth limits, index and section names
		my ($CBQosNames,$CBQosValues) = NMIS::loadCBQoS(sys=>$S, graphtype=>$graphtype, index=>$intf);

		if ( $item eq "" ) {
			# display all class-maps in one graph
			my $i;
			my $avgppr;
			my $maxppr;
			my $avgdbr;
			my $maxdbr;
			my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;
			my $ifDescr = shortInterface($IF->{$intf}{ifDescr});
			my $vlabel = "Avg Bits per Second";
			if ( $width <= 400 ) { 
				$title = "$NI->{name} $ifDescr $direction";
				$title .= " - $CBQosNames->[0]" if ($CBQosNames->[0] && $CBQosNames->[0] !~ /^(in|out)bound$/i);
				$title .= ' - $length';
				$vlabel = "Avg bps";
			} else { 
				$title = "$NI->{name} $ifDescr $direction - CBQoS from ".'$datestamp_start to $datestamp_end';
			}

			@opt = (
				"--title", $title,
				"--vertical-label",$vlabel,
				"--start", "$start",
				"--end", "$end",
				"--width", "$width",
				"--height", "$height",
				"--imgformat", "PNG",
				"--interlace",
				"--disable-rrdtool-tag",
				"--color", 'BACK#ffffff',      # Background Color
				"--color", 'SHADEA#ffffff',    # Left and Top Border Color
				"--color", 'SHADEB#ffffff',    #
				"--color", 'CANVAS#FFFFFF',    # Canvas (Grid Background)
				"--color", 'GRID#E2E2E2',      # Grid Line ColorGRID#808020'
				"--color", 'MGRID#EBBBBB',     # Major Grid Line ColorMGRID#80c080
				"--color", 'FONT#222222',      # Font Color
				"--color", 'ARROW#924040',     # Arrow Color for X/Y Axis
				"--color", 'FRAME#808080'      # Canvas Frame Color
			);

			if ($width > 400) {
				push(@opt,"--font", $C->{graph_default_font_standard}) if $C->{graph_default_font_standard};
			}
			else {
				push(@opt,"--font", $C->{graph_default_font_small}) if $C->{graph_default_font_small};
			}
						
			# calculate the sum (avg and max) of all Classmaps for PrePolicy and Drop
			# note that these CANNOT be graphed by themselves, as 0 isn't a valid RPN expression in rrdtool 
			$avgppr = "CDEF:avgPrePolicyBitrate=0";
			$maxppr = "CDEF:maxPrePolicyBitrate=0";
			$avgdbr = "CDEF:avgDropBitrate=0";
			$maxdbr = "CDEF:maxDropBitrate=0";
			
			# is this hierarchical or flat?
			my $HQOS = 0;
			foreach my $i (1..$#$CBQosNames) {
				if ( $CBQosNames->[$i] =~ /^([\w\-]+)\-\-\w+\-\-/ ) {
					$HQOS = 1;
				}
			}
			
			my $gtype = "AREA";
			my $gcount = 0;
			my $parent_name = "";
			foreach my $i (1..$#$CBQosNames)
			{
				my $thisinfo = $CBQosValues->{$intf.$CBQosNames->[$i]};

				$database = $S->getDBName(graphtype => $thisinfo->{CfgSection},
																	index => $thisinfo->{CfgIndex},
																	item => $CBQosNames->[$i]	);
				my $parent = 0;
				if ( $CBQosNames->[$i] !~ /\w+\-\-\w+/ and $HQOS ) {
					$parent = 1;
					$gtype = "LINE1";
				}

				if ( $CBQosNames->[$i] =~ /^([\w\-]+)\-\-\w+\-\-/ ) {
					$parent_name = $1;
					print STDERR "DEBUG parent_name=$parent_name\n" if ($debug);
				}

				if ( not $parent and not $gcount) {
					$gtype = "AREA";
					++$gcount;
				}
				elsif ( not $parent and $gcount) {
					$gtype = "STACK";
					++$gcount;
				}
				my $alias = $CBQosNames->[$i];
				$alias =~ s/$parent_name\-\-//g;
				$alias =~ s/\-\-/\//g;

				# rough alignment for the columns, necessarily imperfect 
				# as X-char strings aren't equally wide...
				my $tab = "\\t";
				if ( length($alias) <= 5 ) {
					$tab = $tab x 4;
				}
				elsif ( length($alias) <= 14 ) { 
					$tab = $tab x 3;
				}
				elsif ( length($alias) <= 19 ) { 
					$tab = $tab x 2;
				}

				my $color = $CBQosValues->{$intf.$CBQosNames->[$i]}{'Color'};

				push(@opt,"DEF:avgPPB$i=$database:".$thisinfo->{CfgDSNames}->[0].":AVERAGE");
				push(@opt,"DEF:maxPPB$i=$database:".$thisinfo->{CfgDSNames}->[0].":MAX");
				push(@opt,"DEF:avgDB$i=$database:".$thisinfo->{CfgDSNames}->[2].":AVERAGE");
				push(@opt,"DEF:maxDB$i=$database:".$thisinfo->{CfgDSNames}->[2].":MAX");

				push(@opt,"CDEF:avgPPR$i=avgPPB$i,8,*");
				push(@opt,"CDEF:maxPPR$i=maxPPB$i,8,*");
				push(@opt,"CDEF:avgDBR$i=avgDB$i,8,*");
				push(@opt,"CDEF:maxDBR$i=maxDB$i,8,*");

				if ($width > 400) {
					push @opt,"$gtype:avgPPR$i#$color:$alias$tab";
					push(@opt,"GPRINT:avgPPR$i:AVERAGE:Avg %8.2lf%s\\t");
					push(@opt,"GPRINT:maxPPR$i:MAX:Max %8.2lf%s\\t");
					push(@opt,"GPRINT:avgDBR$i:AVERAGE:Avg Drops %6.2lf%s\\t");
					push(@opt,"GPRINT:maxDBR$i:MAX:Max Drops %6.2lf%s\\l");
				}
				else {
					push(@opt,"$gtype:avgPPR$i#$color:$alias");
				}
				
				#push(@opt,"LINE1:avgPPR$i#$color:$CBQosNames->[$i]");
				$avgppr = $avgppr.",avgPPR$i,+";
				$maxppr = $maxppr.",maxPPR$i,+";
				$avgdbr = $avgdbr.",avgDBR$i,+";
				$maxdbr = $maxdbr.",maxDBR$i,+";
			}
			push(@opt,$avgppr);
			push(@opt,$maxppr);
			push(@opt,$avgdbr);
			push(@opt,$maxdbr);

			if ($width > 400) {
				push(@opt,"COMMENT:\\l");
				push(@opt,"GPRINT:avgPrePolicyBitrate:AVERAGE:PrePolicyBitrate\\t\\t\\tAvg %8.2lf%s\\t");
				push(@opt,"GPRINT:maxPrePolicyBitrate:MAX:Max\\t%8.2lf%s\\l");
				push(@opt,"GPRINT:avgDropBitrate:AVERAGE:DropBitrate\\t\\t\\tAvg %8.2lf%s\\t");
				push(@opt,"GPRINT:maxDropBitrate:MAX:Max\\t%8.2lf%s\\l");
			}

		} else {
			# display ONLY the selected class-map
			my $thisinfo = $CBQosValues->{$intf.$item};

			my $speed = defined $thisinfo->{CfgRate}? &convertIfSpeed($thisinfo->{'CfgRate'}) : undef;
			my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;

			$database = $S->getDBName(graphtype => $thisinfo->{CfgSection},
																index => $thisinfo->{CfgIndex},
																item => $item	);

			# in this case we always use the FIRST color, not the one for this item
			my $color = $CBQosValues->{$intf.$CBQosNames->[1]}->{'Color'};

			my $ifDescr = shortInterface($IF->{$intf}{ifDescr});
			$title = "$ifDescr $direction - $item from ".'$datestamp_start to $datestamp_end';
			
			@opt = (
				"--title", "$title",
				"--vertical-label", 'Avg Bits per Second',
				"--start", "$start",
				"--end", "$end",
				"--width", "$width",
				"--height", "$height",
				"--imgformat", "PNG",
				"--interlace",
				"--disable-rrdtool-tag",
				"--color", 'BACK#ffffff',      # Background Color
				"--color", 'SHADEA#ffffff',    # Left and Top Border Color
				"--color", 'SHADEB#ffffff',    #
				"--color", 'CANVAS#FFFFFF',    # Canvas (Grid Background)
				"--color", 'GRID#E2E2E2',      # Grid Line ColorGRID#808020'
				"--color", 'MGRID#EBBBBB',     # Major Grid Line ColorMGRID#80c080
				"--color", 'FONT#222222',      # Font Color
				"--color", 'ARROW#924040',     # Arrow Color for X/Y Axis
				"--color", 'FRAME#808080',      # Canvas Frame Color
					);

			if ($width > 400) {
				push(@opt,"--font", $C->{graph_default_font_standard}) if $C->{graph_default_font_standard};
			}
			else {
				push(@opt,"--font", $C->{graph_default_font_small}) if $C->{graph_default_font_small};
			}

			# needs to work for both types of qos, hence uses the CfgDSNames
			push @opt, (
				"DEF:PrePolicyByte=$database:".$thisinfo->{CfgDSNames}->[0].":AVERAGE", 
				"DEF:maxPrePolicyByte=$database:".$thisinfo->{CfgDSNames}->[0].":MAX", 
				"DEF:DropByte=$database:".$thisinfo->{CfgDSNames}->[2].":AVERAGE", 
				"DEF:maxDropByte=$database:".$thisinfo->{CfgDSNames}->[2].":MAX", 
				"DEF:PrePolicyPkt=$database:".$thisinfo->{CfgDSNames}->[3].":AVERAGE", 
				"DEF:DropPkt=$database:".$thisinfo->{CfgDSNames}->[5].":AVERAGE");
			
			# huawei doesn't have NoBufDropPkt
			push @opt, "DEF:NoBufDropPkt=$database:".$thisinfo->{CfgDSNames}->[6].":AVERAGE"
					if (defined $thisinfo->{CfgDSNames}->[6]);

			push @opt, (
				"CDEF:PrePolicyBitrate=PrePolicyByte,8,*",
				"CDEF:maxPrePolicyBitrate=maxPrePolicyByte,8,*",
				"CDEF:DropBitrate=DropByte,8,*",
				"TEXTALIGN:left",
				"AREA:PrePolicyBitrate#$color:PrePolicyBitrate",
			);
			
			# detailed legends are only shown on the 'big' graphs
			if ($width > 400) {
				push(@opt,"GPRINT:PrePolicyBitrate:AVERAGE:\\tAvg %8.2lf %sbps\\t");
				push(@opt,"GPRINT:maxPrePolicyBitrate:MAX:Max %8.2lf %sbps");
			}
			# move back to previous line, then right-align
			push @opt, "COMMENT:\\u", "AREA:DropBitrate#ff0000:DropBitrate\\r:STACK";
			
			if ($width > 400)
			{
				push(@opt,"GPRINT:PrePolicyByte:AVERAGE:Bytes transferred\\t\\tAvg %8.2lf %sB/s\\n");

				push(@opt,"GPRINT:DropByte:AVERAGE:Bytes dropped\\t\\t\\tAvg %8.2lf %sB/s\\t");
				push(@opt,"GPRINT:maxDropByte:MAX:Max %8.2lf %sB/s\\n");

				push(@opt,"GPRINT:PrePolicyPkt:AVERAGE:Packets transferred\\t\\tAvg %8.2lf\\l");
				push(@opt,"GPRINT:DropPkt:AVERAGE:Packets dropped\\t\\t\\tAvg %8.2lf");
				
				# huawei doesn't have that
				push(@opt,"COMMENT:\\l","GPRINT:NoBufDropPkt:AVERAGE:Packets No buffer dropped\\tAvg %8.2lf\\l")
						if (defined $thisinfo->{CfgDSNames}->[6]);
			
				# not all qos setups have a graphable bandwidth limit
				push @opt, "COMMENT:\\u", "COMMENT:".$thisinfo->{CfgType}." $speed\\r" if (defined $speed);
			}
		}

		return @opt;
	}

	### Mike McHenry 2005
	sub graphCalls {
		my %args = @_;
		my $S = $args{sys};
		my $NI = $S->ndinfo;
		my $IF = $S->ifinfo;
		my $graphtype = $args{graphtype};
		my $intf = $args{intf};
		my $start = $args{start};
		my $end = $args{end};
		my $width = $args{width};
		my $height = $args{height};

		my $database;
		my @opt;
		my $title;

		my $device = ($intf eq "") ? "total" : $IF->{$intf}{ifDescr};
		if ( $width <= 400 ) { $title = "$NI->{name} Calls ".'$length'; }
		else { $title = "$NI->{name} - $device - ".'$length from $datestamp_start to $datestamp_end'; }

		# display Calls summarized or only one port
		@opt = (
			"--title", $title,
			"--vertical-label","Call Stats",
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"--disable-rrdtool-tag"
		);

		my $CallCount = "CDEF:CallCount=0";
		my $AvailableCallCount = "CDEF:AvailableCallCount=0";
		my $totalIdle = "CDEF:totalIdle=0";
		my $totalUnknown = "CDEF:totalUnknown=0";
		my $totalAnalog = "CDEF:totalAnalog=0";
		my $totalDigital = "CDEF:totalDigital=0";
		my $totalV110 = "CDEF:totalV110=0";
		my $totalV120 = "CDEF:totalV120=0";
		my $totalVoice = "CDEF:totalVoice=0";


		foreach my $i ($S->getTypeInstances(section => 'calls')) {
			next unless $intf eq "" or $intf eq $i;
			$database = $S->getDBName(graphtype => 'calls', 
																index => $i);
			next if (!$database);

			push(@opt,"DEF:CallCount$i=$database:CallCount:MAX");
			push(@opt,"DEF:AvailableCallCount$i=$database:AvailableCallCount:MAX");
			push(@opt,"DEF:totalIdle$i=$database:totalIdle:MAX");
			push(@opt,"DEF:totalUnknown$i=$database:totalUnknown:MAX");
			push(@opt,"DEF:totalAnalog$i=$database:totalAnalog:MAX");
			push(@opt,"DEF:totalDigital$i=$database:totalDigital:MAX");
			push(@opt,"DEF:totalV110$i=$database:totalV110:MAX");
			push(@opt,"DEF:totalV120$i=$database:totalV120:MAX");
			push(@opt,"DEF:totalVoice$i=$database:totalVoice:MAX");

			$CallCount .= ",CallCount$i,+";
			$AvailableCallCount .= ",AvailableCallCount$i,+";
			$totalIdle .= ",totalIdle$i,+";
			$totalUnknown .= ",totalUnknown$i,+";
			$totalAnalog .= ",totalAnalog$i,+";
			$totalDigital .= ",totalDigital$i,+";
			$totalV110 .= ",totalV110$i,+";
			$totalV120 .= ",totalV120$i,+";
			$totalVoice .= ",totalVoice$i,+";
			if ($intf ne "") { last; }
		}

		push(@opt,$CallCount);
		push(@opt,$AvailableCallCount);
		push(@opt,$totalIdle);
		push(@opt,$totalUnknown);
		push(@opt,$totalAnalog);
		push(@opt,$totalDigital);
		push(@opt,$totalV110);
		push(@opt,$totalV120);
		push(@opt,$totalVoice);

		push(@opt,"LINE1:AvailableCallCount#FFFF00:AvailableCallCount");
		push(@opt,"LINE2:totalIdle#000000:totalIdle");
		push(@opt,"LINE2:totalUnknown#FF0000:totalUnknown");
		push(@opt,"LINE2:totalAnalog#00FFFF:totalAnalog");
		push(@opt,"LINE2:totalDigital#0000FF:totalDigital");
		push(@opt,"LINE2:totalV110#FF0080:totalV110");
		push(@opt,"LINE2:totalV120#800080:totalV120");
		push(@opt,"LINE2:totalVoice#00FF00:totalVoice");
		push(@opt,"COMMENT:\\l");
		push(@opt,"GPRINT:AvailableCallCount:MAX:Available Call Count %1.2lf");
		push(@opt,"GPRINT:CallCount:MAX:Total Call Count %1.0lf");

		return @opt;
	}

} # end graph


sub id { 
	my $x = 10 *shift;
	return '_'.sprintf("%02X", $x);	
}	
