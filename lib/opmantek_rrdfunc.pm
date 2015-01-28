#
## $Id: rrdfunc.pm,v 8.6 2012/04/28 00:59:36 keiths Exp $
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

package opmantek_rrdfunc;

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

use RRDs 1.000.490; # from Tobias
use Statistics::Lite qw(min max range sum count mean median mode variance stddev statshash statsinfo);
use func;
use Sys;
use Data::Dumper;
#$Data::Dumper::Ident=1;
#$Data::Dumper::SortKeys=1;

$VERSION = 2.0;

@ISA = qw(Exporter);

@EXPORT = qw(		
		rrdFetchGraphPData
	);

sub error {
	print "Content-type: text/html\n\n";
	# print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	# print end_html;
}

sub rrdFetchGraphPData {
	my %args = @_;

	# print "rrdFetchGraphPData: \n".Dumper(\%args);
	# Break the query up for the names
	my $type = $args{obj};
	my $nodename = $args{node};
	my $debug = $args{debug};
	my $grp = $args{group};
	my $graphtype = $args{graphtype};
	my $graphstart = $args{graphstart};
	my $width = $args{width};
	my $height = $args{height};
	my $start = $args{start};
	my $end = $args{end};
	my $intf = $args{intf};
	my $item = $args{item};
	my $filename = $args{filename};

	my $C = $args{C};
	# if( !defined($C) ) {
	# 	if (!($C = loadConfTable(conf=>$args{conf},debug=>$debug))) { exit 1; };	
	# }
	
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
	
	my ($r_start,$r_end,$r_width,$types,$ds_names,$legend,$colours,$pdata,$chart_options);
	my ($hash_data,$hash_head);

	if ($graphtype eq 'metrics') {
		$item = $args{group};
		$intf = "";
	}


	if ($graphtype =~ /cbqos/) {
		@opt = graphCBQoS(sys=>$S,graphtype=>$graphtype,intf=>$intf,item=>$item,start=>$start,end=>$end,width=>$width,height=>$height);
	} elsif ($graphtype eq "calls") {
		@opt = graphCalls(sys=>$S,graphtype=>$graphtype,intf=>$intf,item=>$item,start=>$start,end=>$end,width=>$width,height=>$height);
	} else {

		my $getDBName =$S->getDBName(graphtype=>$graphtype,index=>$intf,item=>$item);
		# print "getDBName = ".Dumper($getDBName);
		if (!($db = $S->getDBName(graphtype=>$graphtype,index=>$intf,item=>$item)) ) { # get database name from node info
			error();
			return 0;
		}

		my $graph;
		if (!($graph = loadTable(dir=>'models',name=>"Graph-$graphtype"))) {
			logMsg("ERROR reading Graph-$graphtype");
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
		# ($begin,$step,$names,$data) = RRDs::graphfetch($tmpimg, @options);
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
		# print "Getting graphfetch, options=\n".Dumper(\@options);
		# ($begin,$step,$types,$name,$data) = RRDs::graphfetch('-', @options);		
		my $begin;
		my $end;
		($r_start,$r_end,$r_width,$types,$ds_names,$legend,$colours,$pdata,$chart_options) = RRDs::fetch_graph_pdata('-', @options);
		# print STDERR "Graphfetch returned start=$r_start,end=$r_end,width=$r_width\n";
		# print STDERR "Graphfetch returned begin=$begin, width=$width,\n name=".Dumper($name)."\n data=".Dumper($pdata)."\n";		

		if ($ERROR = RRDs::error) {
			logMsg("$db Graphing Error for $graphtype: $ERROR");
	
		} else {
			#return "GIF Size: ${xs}x${ys}\n";
			#print "Graph Return:\n",(join "\n", @$graphret),"\n\n";
		}
	}
	return ($r_start,$r_end,$r_width,$types,$ds_names,$legend,$colours,$pdata,$chart_options);
}

1;
