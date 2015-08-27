#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
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
# *****************************************************************************
#
# this helper is for creating custom graphs for service monitoring
#
# services that are monitored by external programs or nagios plugins
# can return extra numeric data to nmis.
#
# this helper guides you through the process of creating custom graphs
# for such services.
our $VERSION = "1.0.0";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use JSON::XS;
use Data::Dumper;
use UI::Dialog;

use func;
use NMIS;


my $bn = basename($0);
my $usage = "Usage: $bn [debug=true] {--version}\n\n";

die $usage if (@ARGV == 1 and $ARGV[0] =~ /^--?[h?]/);
my %args = getArguements(@ARGV);


my $debuglevel = setDebug($args{debug});
my $infolevel = setDebug($args{info});
my $confname = $args{conf} || "Config";

# get us a common config first
my $config = loadConfTable(conf=>$confname,
													 dir=>"$FindBin::RealBin/../conf",
													 debug => $debuglevel);
die "could not load configuration $confname!\n"
		if (!$config or !keys %$config);

my $dia = UI::Dialog->new('title' => "Service Graph Helper", 
													height => 20, 
													width =>  70,
													listheight => 15, order => [ 'cdialog', 'ascii']); # whiptail/newt doesn't behave well

$dia->msgbox("text" => "This helper will guide you through the creation
of a simple custom graph for an custom NMIS service. 

Clicking Cancel at any stage will abort the helper.
Use the arrow keys and tab to navigate, space to select from lists.");

die "User cancelled operation.\n" if ($dia->state ne "OK");

my %allsvc = loadServiceStatus;

my $servicesel = $dia->menu( text => "Please select the service you want to graph:",
														 list => [ map { ($_,'') } (sort keys %allsvc) ] );

die "User cancelled operation.\n" if ($dia->state ne "OK");

my $nodesel = $dia->menu( text => "Please select one node where this service is active:",
													list => [ map { ($_,'') } (sort keys %{$allsvc{$servicesel}}) ]);

die "User cancelled operation.\n" if ($dia->state ne "OK");


my $thissvc = $allsvc{$servicesel}->{$nodesel};

if (!$thissvc->{status})
{
	$dia->msgbox( text => "The service $servicesel seems to be down on node $nodesel. 
Please pick a different node!");
	exit 0;
}
								
# standard readings
my @readings = [service => 'service status'];
push @readings, [responsetime => "response time"] if (defined $thissvc->{responsetime});
push @readings, ["cpu" => "cpu use"] if (defined $thissvc->{cpu});
push @readings, ["memory" => "memory use"] if (defined $thissvc->{memory});

# extras
if (ref($thissvc->{extra}) eq "HASH")
{
	push @readings, map { [ $_ => "custom" ] } (sort keys %{$thissvc->{extra}})
}

$dia->msgbox(text => "This service collects the following measurements, which 
are available for graphing: ". join(", ", map { $_->[0] } (@readings)));
die "User cancelled operation.\n" if ($dia->state ne "OK");

my ($shortname, @whichds);
while (1)
{
	undef $shortname;
	@whichds = $dia->checklist(text => "Please select one ore more measurements to include on your graph:",
														 list => [ map { $_->[0] => [ $_->[1], 0 ] } (@readings) ] );
	die "User cancelled operation.\n" if ($dia->state ne "OK");
	
	if (@whichds == 1)
	{
		if ($whichds[0] =~ /^(service|responsetime)$/)
		{
			$dia->msgbox(text => "There is already a standard graph for \"$whichds[0]\". Please pick a different measurement.");
			next;
		}
		$shortname = $whichds[0];
		last;
	}
	elsif (!@whichds)
	{
		$dia->msgbox(text => "You have to pick at least one measurement.");
	}
	else
	{
		last;
	}
}

while (!$shortname)
{
  $shortname = $dia->inputbox(text => "Please enter a name for your new graph. 
The name should be short and must not contain any characters except a-z, 0-9, _, - or .",
															entry =>  "");
	die "User cancelled operation.\n" if ($dia->state ne "OK");
	
	$shortname = lc($shortname);
	$shortname =~ s/[^a-z0-9\._]//g;
}

my %graph = ( title => { standard => '$node - $length from $datestamp_start to $datestamp_end',
												 short => '$node - $length' },
							vlabel => { standard => '', small => '' },
							option => { standard => [ ], small => [ ] } );


# ask for: titles (with default)
my $newtitle = $dia->inputbox( text => "Please set the new graph title below. This is full-sized graphs.
NMIS-variables written as \"\$varname\" will be substituted.",
															 entry => escape($graph{title}->{standard}) );
die "User cancelled operation.\n" if ($dia->state ne "OK");
$graph{title}->{standard} = $newtitle if ($newtitle and $newtitle !~ /^\s*$/ 
																					and $newtitle ne $graph{title}->{standard});

$newtitle = $dia->inputbox( text => "Please set the new graph title below. This is for small graphs.
NMIS-variables written as \"\$varname\" will be substituted.",
															 entry => escape($graph{title}->{short}) );
die "User cancelled operation.\n" if ($dia->state ne "OK");
$graph{title}->{short} = $newtitle if ($newtitle and $newtitle !~ /^\s*$/ 
																			 and $newtitle ne $graph{title}->{short});


my $vlabel = $dia->inputbox ( text => "Please enter the new vertical axis label, or leave it empty for none. This is for full-sized graphs.",
															entry => $graph{vlabel}->{standard});
die "User cancelled operation.\n" if ($dia->state ne "OK");
$graph{vlabel}->{standard} = $vlabel if ($vlabel and $vlabel !~ /^\s*$/ 
																				 and $vlabel ne $graph{vlabel}->{standard});

$vlabel = $dia->inputbox ( text => "Please enter the new vertical axis label, or leave it empty for none. This is for small graphs.",
															entry => $graph{vlabel}->{small});
die "User cancelled operation.\n" if ($dia->state ne "OK");
$graph{vlabel}->{small} = $vlabel if ($vlabel and $vlabel !~ /^\s*$/ 
																			and $vlabel ne $graph{vlabel}->{small});

						
# for each choice: ask for line colour (menu of 16 named ones), label, include as gprint too and format (if so)
for my $idx (0..$#whichds)
{
	my $ds = $whichds[$idx];
	
	my @choices;
	while (!@choices)
	{
		@choices = $dia->checklist(text => "Please select how measurement \"$ds\" should be graphed:",
															 list => [ "line" => [ "as a line", 1 ],
																				 "avg" => [ "show average with legend", 1 ],
																				 "min" => [ "show min with legend (large graph only)", 0 ],
																				 "max" => [ "show max with legend (large graph only)", 0 ] ]);
		die "User cancelled operation.\n" if ($dia->state ne "OK");
	}

	my $label = $dia->inputbox( text => "Please enter the new label for measurement \"$ds\":",
															entry => $ds);
	die "User cancelled operation.\n" if ($dia->state ne "OK");
	
	push @{$graph{option}->{standard}}, "DEF:$ds=\$database:$ds:AVERAGE";
	push @{$graph{option}->{small}}, "DEF:$ds=\$database:$ds:AVERAGE";
	

	if (grep($_ eq "line", @choices))
	{
		my $color;
		
		while (!$color)
		{
			$color = $dia->radiolist(text => "Please select a line color for \"$ds\":",
															 list => [ "C0C0C0" => [ "Silver" , 0 ],
																				 "808080" => [ "Gray", 0 ],
																				 "000000" =>  ["Black", 0],
																				 "FF0000" => ["Red",0],
																				 "800000" => ["Maroon",0],
																				 "FFFF00" => ["Yellow",0],
																				 "808000" => ["Olive", 0],
																				 "00FF00" =>  ["Lime",0],
																				 "008000" => ["Green",0],
																				 "00FFFF" => ["Aqua",0],
																				 "008080" => ["Teal", 0],
																				 "0000FF" => ["Blue", 0],
																				 "000080" => ["Navy", 0],
																				 "FF00FF" => ["Fuchsia",0],
																				 "800080" => ["Purple", 0],
																				 "FFA500" => ["Orange",0],
																				 "random" => [ "random color", 0] ]);
			die "User cancelled operation.\n" if ($dia->state ne "OK");

			$color = sprintf("%02x%02x%02x", int(rand(256)), int(rand(256)), int(rand(256)))
					if ($color eq "random");

			my $linedef = "LINE1:$ds#$color:$label";
			push @{$graph{option}->{standard}}, $linedef;
			push @{$graph{option}->{small}}, $linedef;
		}
	}

	# now deal with the printing choices
	my ($formatchoice, $labeldone);
	for my $thisprint (@choices)
	{
		next if ($thisprint eq "line"); # already done
		
		my %rrdtype = ( "avg" => "AVERAGE", "min" => "MIN", "max" => "MAX" );
		my %labeltype = ( "avg" => "Avg", "min" => "Min", "max" => "Max" );
		my %formats = ( "percent" => '%9.3lf%%',
										"generic" => '%9.2lf%s',
										"nosuffix" => '%9.4lf');

		# include the measurement label/name only if this ds is not line-drawn
		if (!$labeldone)
		{
			$labeltype{$thisprint} = "$label $labeltype{$thisprint}" if (!grep($_ eq "line", @choices));
			$labeldone = 1;
		}
		
		if (!$formatchoice)
		{
			while (!$formatchoice)
			{
				$formatchoice = $dia->radiolist(text => "Please select the most appropriate format for measurement \"$ds\":",
																				list => [ "percent" => [ "NNN.MMM percent", 0 ],
																									"generic" => [ "A.BC floating point with SI-magnitude suffix" , 1 ],
																									"nosuffix" => [ "A.BCDE floating point without suffix", 0 ] ]);
				die "User cancelled operation.\n" if ($dia->state ne "OK");
			}
		}

		my $printdef = "GPRINT:$ds:$rrdtype{$thisprint}:$labeltype{$thisprint} $formats{$formatchoice}";
		push @{$graph{option}->{standard}}, $printdef;
		push @{$graph{option}->{small}}, $printdef if ($thisprint eq "avg"); # no min and max on the small graph
	}

		push @{$graph{option}->{standard}}, "COMMENT:\\n";
}

my $safeservice = lc($servicesel);
$safeservice =~ s/[^a-z0-9\._]//g;

my $graphname = "service-custom-$safeservice-$shortname";

my $modeldir = $config->{'<nmis_models>'};
my $savefilename = "$modeldir/Graph-$graphname.nmis";
my $tempfilewarning;

if (-f $savefilename)
{
	if ($dia->yesno(text => "Graph file \"$graphname\" already exists! Ok to overwrite it (after backing it up)?"))
	{
		my $backupname = "$savefilename.backup";
		unlink($backupname);
		
		my $isok = rename($savefilename, $backupname);
		die "Cannot rename $savefilename to $backupname: $!\n" if (!$isok);

		$dia->msgbox(text => "The existing graph definition file was renamed to \"$savefilename\".");
	}
	else
	{
		$savefilename = "/tmp/Graph-$graphname.nmis";
		$tempfilewarning = 1;
	}
}

# takes care of permissions, too.
writeHashtoFile(file => $savefilename, data => \%graph);

if ($tempfilewarning)
{
	$dia->msgbox( title => "Graph generation complete but NOT activated!",
								text => "The graph definition was saved in a temporary location as \"$savefilename\"
and will not become available until you copy it to your NMIS models directory.");
}
else
{
	$dia->msgbox( title => "Graph generation complete!", text => "The graph was saved as \"$savefilename\"
and should become available in NMIS as graph type \"$graphname\" after the next collect cycle.

For further graphing and modelling info, please check out https://community.opmantek.com/display/NMIS
(or http://oss.oetiker.ch/rrdtool/doc/rrdgraph.en.html for graphing options and details).");
}

exit 0;


#  ui::dialog doesn't escape current values :-(
sub escape
{
	my ($input) = @_;

	$input =~ s/\$/\\\$/g;
	return $input;
}
