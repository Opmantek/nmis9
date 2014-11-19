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

# Main variables to change to do things with.
my $title = "Dual Interface Utilisation";
my $label = "utilisation";

my $node = "meatball";
my $ifIndex1 = 2;
my $ifIndex2 = 5;
my $graphtype = "interface";

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
#use rrdfunc;
use Sys;
use NMIS;
use Data::Dumper;

use CGI qw(:standard);

use vars qw($q $Q $C $AU $ERROR);

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

my $split = getbool($C->{graph_split}) ? -1 : 1 ;
my $GLINE = getbool($C->{graph_split}) ? "AREA" : "LINE1" ;

my $S = Sys::->new; # get system object
$S->init(name=>$node,snmp=>'false');
my $NI = $S->ndinfo;
my $IF = $S->ifinfo;

my $width = 800;
my $height = 600;

my $end = time();
my $start = $end - 86400;

my $db1 = $S->getDBName(graphtype=>$graphtype,index=>$ifIndex1,item=>undef);
my $db2 = $S->getDBName(graphtype=>$graphtype,index=>$ifIndex2,item=>undef);

my $ifSpeed1 = $IF->{$ifIndex1}{ifSpeed};
my $ifSpeed2 = $IF->{$ifIndex2}{ifSpeed};
my $ifSpeedTotal = $ifSpeed2 + $ifSpeed1;

my @options = (
	"--title", $title,
	"--vertical-label", $label,
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
	"--color", 'FRAME#808080',      # Canvas Frame Color
	"--font", 'DEFAULT:8:Sans-Serif',

	"DEF:input=$db1:ifInOctets:AVERAGE",
	"DEF:output=$db1:ifOutOctets:AVERAGE",

	"DEF:input2=$db2:ifInOctets:AVERAGE",
	"DEF:output2=$db2:ifOutOctets:AVERAGE",

	"CDEF:inputBits=input,8,*",
	"CDEF:inputSplitBits=input,8,*,$split,*",
	"CDEF:outputBits=output,8,*",

	"CDEF:inputBits2=input2,8,*",
	"CDEF:inputSplitBits2=input2,8,*,$split,*",
	"CDEF:outputBits2=output2,8,*",

	"CDEF:totalInputBits=inputSplitBits,inputSplitBits2,+",
	"CDEF:totalOutputBits=outputBits,outputBits2,+",
	
	"AREA:inputSplitBits#0000ff:In",
	"STACK:inputSplitBits2#0000aa:In",
	"LINE1:totalInputBits#000088:In",
	"GPRINT:inputBits:AVERAGE:Avg %1.0lf bits/sec",
	"GPRINT:inputBits:MAX:Max %1.0lf bits/sec\\n",

	"AREA:outputBits#00ff00:Out",
	"STACK:outputBits2#00aa00:Out",
	"LINE1:totalOutputBits#008800:Out",
	"GPRINT:outputBits:AVERAGE:Avg Out %1.0lf bits/sec",
	"GPRINT:outputBits:MAX:Max Out %1.0lf bits/sec\\n",
	
	"COMMENT:Interface Speed $ifSpeedTotal\\n"
); 

select((select(STDOUT), $| = 1)[0]);
print "Content-type: image/png\n\n";
my ($graphret,$xs,$ys) = RRDs::graph('-', @options);
select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout

print STDERR "DEBUG: @options\n";
print STDERR Dumper $IF->{$ifIndex1};

if ($ERROR = RRDs::error) {
	logMsg("$db1 Graphing Error for $graphtype: $ERROR");

} else {
	return "GIF Size: ${xs}x${ys}\n";
	print "Graph Return:\n",(join "\n", @$graphret),"\n\n";
}
		
exit 0;
