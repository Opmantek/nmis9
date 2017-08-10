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

use strict;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use Compat::NMIS;
use Data::Dumper;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars;

my $C;
if (!($C = NMISNG::Util::loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };
NMISNG::rrdfunc::require_RRDs(config=>$C);

# bypass auth iff called from command line
$C->{auth_require} = 0 if (@ARGV);

# NMIS Authentication module
use NMISNG::Auth;

# variables used for the security mods
my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = NMISNG::Auth->new(conf => $C);

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if Compat::NMIS::requestServer(headeropts=>$headeropts); }

#======================================================================

# select function
if ($Q->{act} eq 'draw_graph_view') {	rrdDraw();
} else { notfound(); }

exit;

sub notfound {
	NMISNG::Util::logMsg("rrddraw; Command unknown act=$Q->{act}");
}

#============================================================================

sub error {
	print header($headeropts);
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}


# produce one graph
# args: pretty much all coming from a global $Q object
# returns: rrds::graph result array
sub rrdDraw
{
	my %args = @_;

	NMISNG::rrdfunc::require_RRDs();

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

	my $S = NMISNG::Sys->new; # get system object

	$S->init(name=>$nodename, snmp=>'false');
	# fixme9: non-node mode is a dirty hack.
	# fixme9: catchall_data is not used?!
	if ($nodename)
	{
		my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	}

	my $subconcept = $S->loadGraphTypeTable->{$graphtype};

	### 2012-02-06 keiths, handling default graph length
	# default is hours!
	my $graphlength = $C->{graph_amount};
	if ( $C->{graph_unit} eq "days" )
	{
		$graphlength = $C->{graph_amount} * 24;
	}

	if ( $start eq "" or $start == 0)
	{
		$start = time() - ($graphlength*3600);
	}
	if ( $end eq "" or $end == 0) {
		$end = time();
	}

	my $ERROR;
	my $graphret;
	my $xs;
	my $ys;
	my (@opt,											# rrd options, pre-expansion
		@finalopts, 							# rrd optiosn, expanded
		$db												# or the no-strict stuff fails...
		);

	if ($graphtype eq 'metrics')
	{
		$item = $Q->{group};
		$intf = "";
	}

	# special graphtypes: cbqos is dynamic (multiple inputs create one graph)
	if ($graphtype =~ /cbqos/)
	{
		@opt = graphCBQoS(sys=>$S,
											graphtype=>$graphtype,
											intf=>$intf,
											item=>$item,
											start=>$start,end=>$end,width=>$width,height=>$height);
	}
	else
	{

		if (!($db = $S->makeRRDname(graphtype=>$graphtype,index=>$intf,item=>$item)) ) { # get database name from node info
			error();
			return 0;
		}

		my $res = NMISNG::Util::getModelFile(model => "Graph-$graphtype");
		if (!$res->{success})
		{
			NMISNG::Util::logMsg("ERROR failed to read Graph-$graphtype: $res->{error}");
			error();
			return 0;
		}
		my $graph = $res->{data};

		my $title = 'standard';
		my $vlabel = 'standard';
		my $size = 'standard';
		my $ttl;
		my $lbl;

		$title = 'short' if $width <= 400 and $graph->{title}{short} ne "";
		$vlabel = 'short' if $width <= 400 and $graph->{vlabel}{short} ne "";
		$vlabel = 'split' if NMISNG::Util::getbool($C->{graph_split}) and $graph->{vlabel}{split} ne "";
		$size = 'small' if $width <= 400 and $graph->{option}{small} ne "";


		if (($ttl = $graph->{title}{$title}) eq "")
		{
			NMISNG::Util::logMsg("no title->$title found in Graph-$graphtype");
		}
		if (($lbl = $graph->{vlabel}{$vlabel}) eq "")
		{
			NMISNG::Util::logMsg("no vlabel->$vlabel found in Graph-$graphtype");
		}

		@opt = (
				"--title", $ttl,
				"--vertical-label", $lbl,
				"--start", $start,
				"--end", $end,
				"--width", $width,
				"--height", $height,
				"--imgformat", "PNG",
				"--interlaced",
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
	}

	# define length of graph
	my $length;
	if (($end - $start) < 3600) {
		$length = int(($end - $start) / 60) . " minutes";
	} elsif (($end - $start) < (3600*48)) {
		$length = int(($end - $start) / (3600)) . " hours";
	} else {
		$length = int(($end - $start) / (3600*24)) . " days";
	}
	my $extras = {
		node => $nodename,
		datestamp_start => NMISNG::Util::returnDateStamp($start),
		datestamp_end => NMISNG::Util::returnDateStamp($end),
		datestamp => NMISNG::Util::returnDateStamp(time),
		database => $db,
		length => $length,
		group => $grp,
		itm => $item,
		split => NMISNG::Util::getbool($C->{graph_split}) ? -1 : 1 ,
		GLINE => NMISNG::Util::getbool($C->{graph_split}) ? "AREA" : "LINE1",
		weight => 0.983,
	};
	# escape any : chars which might be in the database name e.g handling C: in the RPN
	$extras->{database} =~ s/:/\\:/g;

	foreach my $str (@opt)
	{
	# each call to this funciton modifies the extras, not sure if that matters but
		# give a copy for now to make sure
		# should add a way of telling the function it doesn't need to do any extra figuring
		my $extras_copy = { %$extras };
		my $parsed = $S->parseString( string => $str, index => $intf, item => $item, sect => $subconcept, extras => $extras_copy, eval => 0 );
		push @finalopts,$parsed;
	}

	# Do the graph!
	if (!$filename)
	{
		# buffer stdout to avoid Apache timing out on the header tag while waiting for the PNG image stream from RRDs
		select((select(STDOUT), $| = 1)[0]);
		print "Content-type: image/png\n\n";
		($graphret,$xs,$ys) = RRDs::graph('-', @finalopts);
		select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout
	}
	else {
		($graphret,$xs,$ys) = RRDs::graph($filename, @finalopts);
	}

	if ($ERROR = RRDs::error())
	{
		NMISNG::Util::logMsg("$db Graphing Error for $graphtype: $ERROR");
	}
	return $graphret;
}

#  CBQoS Support
# this handles both cisco and huawei flavour cbqos
sub graphCBQoS
{
	my %args = @_;
	my $S = $args{sys};

	my $graphtype = $args{graphtype};
	my $intf = $args{intf};
	my $item = $args{item};
	my $start = $args{start};
	my $end = $args{end};
	my $width = $args{width};
	my $height = $args{height};
	my $debug = $Q->{debug};

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	my $database;
	my @opt;
	my $title;

	# order the names, find colors and bandwidth limits, index and section names
	my ($CBQosNames,$CBQosValues) = Compat::NMIS::loadCBQoS(sys=>$S, graphtype=>$graphtype, index=>$intf);

	# because cbqos we should find interface
	my $inventory = $S->inventory( concept => 'interface', index => $intf, nolog => 0, partial => 1 );
	my $if_data = ($inventory) ? $inventory->data : {};

	if ( $item eq "" ) {
		# display all class-maps in one graph
		my $i;
		my $avgppr;
		my $maxppr;
		my $avgdbr;
		my $maxdbr;
		my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;

		my $ifDescr = NMISNG::Util::shortInterface($if_data->{ifDescr});
		my $vlabel = "Avg Bits per Second";
		if ( $width <= 400 ) {
			$title = "$catchall_data->{name} $ifDescr $direction";
			$title .= " - $CBQosNames->[0]" if ($CBQosNames->[0] && $CBQosNames->[0] !~ /^(in|out)bound$/i);
			$title .= ' - $length';
			$vlabel = "Avg bps";
		} else {
			$title = "$catchall_data->{name} $ifDescr $direction - CBQoS from ".'$datestamp_start to $datestamp_end';
		}

		@opt = (
			"--title", $title,
			"--vertical-label",$vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlaced",
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

			$database = $S->makeRRDname(graphtype => $thisinfo->{CfgSection},
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

		my $speed = defined $thisinfo->{CfgRate}? &NMISNG::Util::convertIfSpeed($thisinfo->{'CfgRate'}) : undef;
		my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;

		$database = $S->makeRRDname(graphtype => $thisinfo->{CfgSection},
															index => $thisinfo->{CfgIndex},
															item => $item	);

		# in this case we always use the FIRST color, not the one for this item
		my $color = $CBQosValues->{$intf.$CBQosNames->[1]}->{'Color'};

		my $ifDescr = NMISNG::Util::shortInterface($if_data->{ifDescr});
		$title = "$ifDescr $direction - $item from ".'$datestamp_start to $datestamp_end';

		@opt = (
			"--title", "$title",
			"--vertical-label", 'Avg Bits per Second',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlaced",
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
