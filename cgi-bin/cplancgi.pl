#!/usr/bin/perl
#
## $Id: cplancgi.pl,v 8.2 2011/08/28 15:10:52 nmisdev Exp $
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
# egreenwood@users.sourceforge.net
# updated 11 Mar 2009 added switch interface collect as defaultoption
#
# displays capacity planning graphs
#
# set this to select device types to collect and draw graphs for
# in both cgi/cplancgi.pl and bin/cplan.pl
my $qr_collect = qr/router|switch/i;
#
# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
#use web;
use func;
use csv;
use NMIS;

# NMIS Authentication module
use Auth;

use CGI qw(:standard *table *Tr *td *form *Select *div);
use GD::Graph::area;
#use GD::Graph::colour qw(:colours :lists :files :convert); 

# declare holder for CGI objects
use vars qw($q);
$q = new CGI; # This processes all parameters passed via GET and POST

# variables used for the security mods
use vars qw(@cookies); @cookies = ();
use vars qw(%headeropts); %headeropts = ();

my %FORM = getCGIForm($ENV{'QUERY_STRING'});
my $node = $FORM{node};
my $group = $FORM{group};
my $percent = $FORM{percent};
my $threshold = $FORM{threshold};
my $type = $FORM{type};

$percent ||= "95";
if ( $threshold eq "" ) { $threshold = "60"; }

# Allow program to use other configuration files
my $conf;
if ( $FORM{file} ne "" ) { $conf = $FORM{file}; }
else { $conf = "nmis.conf"; }
my $configfile = "$FindBin::Bin/../conf/$conf";
if ( -f $configfile ) { loadConfiguration($configfile); }
else { die "Can't access configuration file $configfile.\n"; }


# Before going any further, check to see if we must handle
# an authentication login or logout request
$NMIS::config{auth_require} = 0 if ( ! defined $NMIS::config{auth_require} );
$NMIS::config{auth_require} =~ s/^[fn0].*/0/i;
$NMIS::config{auth_require} =~ s/^[ty1].*/1/i;

my $auth = ();
my $user = ();
my $tb = ();

# set minimal test for security and authorization used throughout
# code. Otherwise, if nauth.pm module is available then
# create nauth object for security and authorization methods
#
#eval {
#       require NMIS::Auth or die "NO_NAUTH module";
#       require NMIS::Users or die "NO_USERS module";
#};
if ( $@ =~ /NO/ ) {
      $auth = \{ Require => 0 };
} else {
      $auth = NMIS::Auth->new;  # NMIS::Auth::new will reap init values from $NMIS::config
      $user = NMIS::Users->new;   # NMIS::Users is dependent upon NMIS::Auth
}

# NMIS::Auth::new () and NMIS::Auth::Initialize () will eventually do all this
#
if ( $auth->Require ) {
      # check for username from other sources
      # either set by the web server or via a set cookie
      $user->SetUser( $auth->verify_id );

      # $user should be set at this point, if not then redirect
      unless ( $user->user ) {
              $auth->do_force_login("Authentication is required. Please login.");
              exit 0;
      }
	# verify access to this command/tool bar/button
	#
   	# CheckAccess will throw up a web page and stop if access is not allowed
	$auth->CheckAccess($user, "capplan") or die "Attempted unauthorized access";

	# logout ?
	if ( $type eq 'logout' ) {
       	$auth->do_logout;
		exit 0;
	}

	# generate the cookie if $auth->user is set
	#
	if ( $auth->Require and $user->user ) {
		push @cookies, $auth->generate_cookie($user->user);
		$headeropts{-cookie} = [@cookies];
	}
}


my $nmis_url = "<a href=\"$NMIS::config{nmis}?file=$conf\"><img alt=\"NMIS Dash\" src=\"$NMIS::config{nmis_icon}\" border=\"0\"></a>";
my $back_url = "<a href=\"$ENV{HTTP_REFERER}\"><img alt=\"Back\" src=\"$NMIS::config{back_icon}\" border=\"0\"></a>";

my $span;
my $title;
my $gflag = 0;

if ( $FORM{type} eq "drawgraph" ) {
	drawgraph( $node, $FORM{extname}, $FORM{label});
	exit 0;
}

loadNodeDetails;		# populate nodeTable and groupTable

if ( $node or $group ) {
	# options
	$span = 1;
	$title = "Capacity Planning Graphs";
	pageStart($title,"false", \%headeropts);
	&cssTableStart("white");
	&cplanMenuSmall;
	&headerBar("Capacity Planning Graphs",1);
	graph( $node, $group);
	&tableEnd;
	&pageEnd;
}
else {
	# no options
	$span = 1;
	$title = "Capacity Planning Graphs";
	pageStart($title,"false", \%headeropts);
	&cssTableStart("white");
	&cplanMenuSmall;
	&headerBar("Capacity Planning Graphs",1);
	&tableEnd;
	&pageEnd;
}

exit(0);

sub cplanMenuSmall {

	my $time;


	# pull the system timezone and then the local time
	if ( $^O =~ /win32/i ) {
	# could add timezone code here
		$time = scalar localtime;
	}
	else {
	# assume UNIX box - look up the timezone as well.
		$time=uc((split " ", `date`)[4]) . " " . (scalar localtime);
	}

	# formulate a list of router only nodes and groups, effect is to only display groups that have qr/collect/ members.
	my @nodelist;
	my @grouplist;
	my %seen;

	foreach ( keys %NMIS::nodeTable ) {
		next unless $user->InGroup($NMIS::nodeTable{$_}{group});
		if ($NMIS::nodeTable{$_}{devicetype} =~ /$qr_collect/ ) {
			push @nodelist , $_ ;
			if ( !exists $seen{$NMIS::nodeTable{$_}{group}} ) {
				push @grouplist , $NMIS::nodeTable{$_}{group};
				$seen{$NMIS::nodeTable{$_}{group}} = 1;
			}
		}
	}

	print <<EOF;
<tr>
<td class="grey" colspan="$span">
<table class="menu1" align="left" >
<tr>
<FORM ACTION="$ENV{SCRIPT_NAME}">
	<td class="grey">$time</td>
	<th class="menugrey">$back_url$nmis_url</th>
	<th class="menugrey"><INPUT TYPE=submit value="GO"></th>
	<td class="menugrey">
		Node Name 
		<select NAME=node SIZE=1>
EOF
		printf "<option %s value=\"$_\">$_</option>\n", $_ =~ /^$node/i ? "selected " : "" foreach ( (sort @nodelist), "ALL");

		print <<EOF;
		</select>
	</td>
	<td class="menugrey">
		Group
		<select NAME=group SIZE=1>
EOF
		printf "<option %s value=\"$_\">$_</option>\n", $_ =~ /^$group/i ? "selected " : "" foreach ( (sort @grouplist), "ALL");
		print <<EOF;
		</select>
	</td>
	<td class="menugrey">
		Display Threshold
		<select NAME=threshold SIZE=1>
EOF
		printf "<option %s value=\"$_\">$_%</option>\n", $_ =~ /^$threshold/i ? "selected " : "" foreach qw( 0 10 20 30 40 50 60 70 80 90 );
		print <<EOF;
		</select>
	</td>
	<td class="menugrey">
		Percentile
		<select NAME=percent SIZE=1>
EOF
		printf "<option %s value=\"$_\">$_%</option>\n", $_ =~ /^$percent/i ? "selected " : "" foreach qw( 85 90 95 );
		print <<EOF;
		</select>
	</td>
</form> 
</tr>
</table>
</td>
</tr>

EOF
}

sub headerBar {
  	my $string = shift;
  	my $colspan = shift;

	if ( $colspan eq "" ) { $colspan = "COLSPAN=1"; }
	else { $colspan = "COLSPAN=$colspan"; }

	print "<tr>\n";
	print "<td class=\"grey\" $colspan>$string</td>\n";
	print "</tr>\n";
}

# print the selected graphs, based on node/group options
sub graph {

	my $node = shift;
	my $group = shift;
	my %data;

	# if group = all, print all nodes
	# if nodes = all, print all nodes for that group
	# else just that one node

	if ( $node ne "ALL" ) {
		draw( $node );
	}
	elsif ( $group ne "ALL" ) {
		foreach ( sort keys %NMIS::nodeTable ) {
			next unless $user->InGroup($NMIS::nodeTable{$_}{group});
			if ( $NMIS::nodeTable{$_}{group} eq $group 
				and $NMIS::nodeTable{$_}{devicetype} =~ /$qr_collect/ ) {
				draw($_);
			}
		}
	}
	else {
		foreach ( sort keys %NMIS::nodeTable ) {
			next unless $user->InGroup($NMIS::nodeTable{$_}{group});
			if ($NMIS::nodeTable{$_}{devicetype} =~ /$qr_collect/ ) {
				draw( $_ );
			}
		}
	}
	if ( !$gflag ) {
		print "<tr>\n";
		print "<td class=\"grey\" colspan=\"1\">No graphs met display criteria</td>\n";
		print "</tr>\n";
	}
}

# draw the graphs for a node
sub draw {
	my $node = shift;
	my $int;
	my $val1;
	my $val2;
	my $pflag;
	my %data;

	if ( -r "$NMIS::config{'nmis_var'}/$node-interface.dat" ) {

		loadInterfaceFile( $node );
		loadSystemFile($node);
		foreach $int ( keys %NMIS::interfaceTable) {

			$pflag = 0;
			undef %data;
			if ( getbool($NMIS::interfaceTable{$int}{collect}) ) {

				# clean the ifDescr
				my $extName = &convertIfName($NMIS::interfaceTable{$int}{ifDescr});
				my $speed = convertIfSpeed($NMIS::interfaceTable{$int}{ifSpeed});
				my $label = "$NMIS::interfaceTable{$int}{Description} (Bandwidth $speed)";
				$label =~ tr/\-\.\/a-zA-Z0-9 ()/_/cs; # change non-(ASCII)alphas/numerics to single underbar

				# read the data and check if meets the threshold.
				# we need three consecutive values for a print 
				# Means that file read again if printed - should be cached by O/S so no great problem
				my $database = "$NMIS::config{database_root}/cplan/$NMIS::systemTable{nodeType}/$node/$node-$extName.csv";
				if ( -r $database ) {

					# read in the data
					%data = &loadCSV("$database","dbtime","\t");
					my @queuein = ( 0,0,0 );
					my @queueout = ( 0,0,0 );

					QUEUE: foreach ( sort keys %data ) {
						# push the values down to make a three element shift register

						push @queuein, ( $data{$_}{"val".$percent."in"} );
						push @queueout, ( $data{$_}{"val".$percent."out"} );
						shift @queuein;
						shift @queueout;

						if ( $queuein[0] >= $threshold and $queuein[1] >= $threshold and $queuein[2] >= $threshold ) {
							$pflag=1;
							last QUEUE; 
						}
						elsif ( $queueout[0] >= $threshold and $queueout[1] >= $threshold and $queueout[2] >= $threshold ) {
							$pflag=1;
							last QUEUE; 
						}
					}
					if ( $pflag) {
						print <<EOF;
						<tr>
							<td align="center" rowspan="1">
								<a href="$NMIS::config{nmis}?file=$conf&amp;node=$node&amp;type=summary" target="_blank">
								<img border="0" height="300" width="1000" alt="Click for link summary" src="$ENV{SCRIPT_NAME}?file=$conf&amp;type=drawgraph&amp;node=$node&amp;percent=$percent&amp;extname=$extName&amp;label=$label">
						    	</a>
							</td>
						</tr>
EOF
						print "\n\n";
						$gflag=1;
					}
				}
			}
		}
	}
}

# print a graph, given a nodename and ifDescr
sub drawgraph {

	my $node = shift;
	my $extName= shift;
	my $label = shift;
	my $int;
	my @datalabel;
	my @datavalue1;
	my @datavalue2;
	my @data;

	loadSystemFile($node);
	# fixme pretty dud location!
	my $database = "$NMIS::config{database_root}/cplan/$NMIS::systemTable{nodeType}/$node/$node-$extName.csv";

	if ( -r $database ) {

		# read in the data
		my %data = &loadCSV("$database","dbtime","\t");

		foreach ( sort keys %data ) {
			push @datalabel, ( returnDate( $data{$_}{dbtime} ));
			push @datavalue1, ( $data{$_}{"val".$percent."out"} );
			push @datavalue2, ( -$data{$_}{"val".$percent."in"} ); # make these negative so they are on bottom of graph

		}

		@data = ( [ @datalabel ], [ @datavalue1 ] , [ @datavalue2 ] );	# first series is output, second is intput
	
		my $mygraph = GD::Graph::area->new(1000, 300);
		$mygraph->set(
			transparent => 0,
			bgclr	=> "white",
		    x_label     => '',
		    y_label     => '% Utilisation',
		    title       => "$node-$extName $label",
			dclrs => [	'#669900', '#3366FF' ],		# (+)green for output, (-)blue for input, 
			y_max_value       => 100,
			y_min_value		=> -100,
			y_tick_number     => 10,
			y_label_skip      => 10,
			line_width		=> 2,
			show_values => 1,
			valuesclr => "dred",
			zero_axis => 1,
			x_labels_vertical => 1
		) or warn $mygraph->error;

		$mygraph->set_legend_font(GD::gdMediumBoldFont);
		$mygraph->set_legend("$percent% Out ", "$percent% In");
		my $myimage = $mygraph->plot(\@data) or die $mygraph->error;

		print "Content-type: image/png\n\n";
		print $myimage->png;
	}
}
