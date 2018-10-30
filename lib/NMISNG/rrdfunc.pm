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
package NMISNG::rrdfunc;
our $VERSION = "9.0.0d";

use strict;
use feature 'state';
use Config;

use File::Basename;
use Statistics::Lite;
use POSIX qw();									# for strftime

use NMISNG::Util;

# This function should be called if using any RRDS:: functionality directly
# Functions in this file will also call it for you (but you have to give them a config)
# it can also be called on it's own before using rrdfunc::'s, doing this means calls to
# rrdfunc's functions to do not need the config as a parameter
sub require_RRDs
{
	my (%args) = @_;
	state $RRD_included = 0;

	if( !$RRD_included )
	{
		$RRD_included = 1;
		require RRDs;
		RRDs->import;
	}
}

# rough stats of what the module has done,
# including last error - fixme: this is module-level, not instance-level!
my %stats;
sub getRRDerror
{
	return $stats{error};
}

sub getUpdateStats
{
	my %pruned;
	# don't include the nodes, just their number
	map { $pruned{$_} = $stats{$_}; } (grep($_ ne "nodes", keys %stats));
	$pruned{nodecount} = keys %{$stats{nodes}};
	return \%pruned;
}

# returns the rrd data for a given rrd type as a hash
# args: database (required),
#  mode (required, AVERAGE,MIN,MAX or LAST)
# optional: hours_from and hours_to (default: no restriction)
# optional: resolution (default: highest resolution that rrd can provide)
# optional: config (live config structure)
# optional: add_minmax (default: unset, if set AND if resolution is set,
#  then <ds>_min and <ds>_max are added for each bucket)
#
# returns: hash of time->dsname=value, list(ref) of dsnames (plus 'time', 'date'), and meta data hash
# metadata hash: actual begin, end, step as per rrd, error if necessary, rows (=count), rows_with_data
sub getRRDasHash
{
	my %args = @_;
	my $db = $args{database};

	return ({},[], { error => "getRRDasHash requires database argument!"}) if (!$db or !-f $db);
	require_RRDs(config => $args{config});

	my $minhr = (defined $args{hour_from}? $args{hour_from} : 0);
	my $maxhr = (defined $args{hour_to}? $args{hour_to} :  24) ;
	my $mustcheckhours = ($minhr != 0  and $maxhr != 24);
	my $invertperiod = $minhr > $maxhr;
	my $wantedresolution = $args{resolution};

	my @rrdargs = ($db, $args{mode});
	my ($bucketsize, $resolution);
	if (defined($wantedresolution) && $wantedresolution > 0)
	{
		# rrdfetch selects resolutions only from existing RRAs (no multiples),
		# so we need to determine what native resolutions are available,
		# look for equality or fall back to the smallest/best/step,
		# post-process into buckets of the desired size...
		my ($error, @available) = getRRDResolutions($db, $args{mode});
		return ({},[], { error => $error }) if ($error);

		# this can work if the desired resolution is directly equal to an RRA period,
		# or if the step divides the desired resolution cleanly
		# HOWEVER, if add_minmax is requested the we must do our own bucketising as rrd likely won't have MIN and MAX rras!
		if (grep($_ == $wantedresolution, @available) && !$args{add_minmax})
		{
			$resolution = $wantedresolution;
		}
		elsif ( $wantedresolution % $available[0] == 0)
		{
			# we must bucketise ourselves
			$bucketsize = $wantedresolution / $available[0];
			$resolution = $available[0];
		}
		else
		{
			return ({},[], { error => "Summarisation with resolution $wantedresolution not possible, available RRD resolutions: "
													 .join(", ",@available) });
		}

		push @rrdargs, ("--resolution",$resolution);
		$args{start} = $args{start} - $args{start} % $resolution;
		$args{end} = $args{end} - $args{end} % $resolution;
	}
	push @rrdargs, ("--start",$args{start},"--end",$args{end});
	my ($begin,$step,$name,$data) = RRDs::fetch(@rrdargs);

	my @dsnames = @$name if (defined $name);
	my %s;
	my $time = $begin;
	my $rowswithdata;

	# loop over the readings over time
	for(my $row = 0; $row <= $#{$data}; ++$row, $time += $step)
	{
		my $thisrow = $data->[$row];
		my $datapresent;
		# loop over the datasets per individual reading
		for(my $dsidx = 0; $dsidx <= $#{$thisrow}; ++$dsidx)
		{
			$s{$time}->{ $dsnames[$dsidx] } = $thisrow->[$dsidx];
			$datapresent ||= 1 if (defined $thisrow->[$dsidx]);
		}

		# compute date only if at least on ds col has defined data
		if ($datapresent)
		{
			++$rowswithdata;
			my @timecomponents = localtime($time);
			my $hour = $timecomponents[2];
			if (!$mustcheckhours or
					(
					 # between from (incl) and to (excl) hour if not inverted
					 ( !$invertperiod and $hour >= $minhr and $hour < $maxhr )
					 or
					 # before to (excl) or after from (incl) hour if inverted,
					 ( $invertperiod and ($hour < $maxhr or $hour >= $minhr )) ))
			{
				$s{$time}->{time} = $time;
				# we DON'T want to rerun localtime() again, so no func::returnDateStamp()
				# want 24-Mar-2014 11:22:33, regardless of LC_*, so %b isn't good.
				my $mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$timecomponents[4]];
				$s{$time}->{date} = POSIX::strftime("%d-$mon-%Y %H:%M:%S", @timecomponents);
			}
			else
			{
				delete $s{$time};				# out of specified hours
			}
		}
	}

	my %meta = ( step => $step, start => $begin, end => $time,
							 rows => scalar @$data, rows_with_data => $rowswithdata );
	# bucket post-processing needed?
	if ($bucketsize)
	{
		my $bucketstart = $meta{start} = $args{start}; # $begin can be one step interval later
		$meta{step} = $bucketsize * $step;

		my $nrdatapoints = @$data;
		my $nrbuckets = int($nrdatapoints/$bucketsize + 0.5); # last bucket may end up partially filled
		$meta{rows} = $meta{rows_with_data} = $nrbuckets;

		for my $bucket (1..$nrbuckets)
		{
			my $targettime = $bucketstart + $bucket * $wantedresolution;
			$meta{end} = $targettime;	# so that last bucket is included in meta

			my %acc;
			for my $slot (0..$bucketsize-1) # backwards
			{
				my $contribtime = $targettime - $slot*$step;
				next if (!exists $s{$contribtime}); # holes in the data are possible

				for my $ds (@dsnames)
				{
					$acc{$ds} ||= [];
					push @{$acc{$ds}}, $s{$contribtime}->{$ds};
				}
				delete $s{$contribtime} if ($slot); # last timeslot receives all the readings for the whole bucket
			}

			if (!keys %acc)	# all gone?
			{
				delete $s{$targettime};
				--$meta{rows_with_data};
			}
			else
			{
				for my $ds (@dsnames)
				{
					$s{$targettime}->{$ds} = Statistics::Lite::mean(@{$acc{$ds}});
					if ($args{add_minmax})
					{
						$s{$targettime}->{"${ds}_min"} = Statistics::Lite::min(@{$acc{$ds}});
						$s{$targettime}->{"${ds}_max"} = Statistics::Lite::max(@{$acc{$ds}});
					}
				}

				# last bucket may be partial and lack time or date
				if (!exists $s{$targettime}->{time})
				{
					$s{$targettime}->{time} = $targettime;
					my @timecomponents = localtime($targettime);
					# we DON'T want to rerun localtime() again, so no func::returnDateStamp()
					# want 24-Mar-2014 11:22:33, regardless of LC_*, so %b isn't good.
					my $mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$timecomponents[4]];
					$s{$targettime}->{date} = POSIX::strftime("%d-$mon-%Y %H:%M:%S", @timecomponents);
				}
			}
		}

		# ditch trailing stuff
		map { delete $s{$_}; } (grep($_ > $meta{end}, keys %s));
		# reorganise the ds names to list ds, min, max,... in that order
		if ($args{add_minmax})
		{
			@dsnames = map { ($_, "${_}_min","${_}_max") } (@dsnames);
		}
	}

	# two artificial ds header cols - let's put them first
	unshift(@dsnames,"time","date");

	# actual data, the dsname list, and the meta data
	return (\%s, \@dsnames, \%meta);
}

# args: rrdfile (full path), mode (one of AVERAGE, MIN or MAX - LAST makes no sense here)
# returns: (undef, array of resolutions, seconds, ascending) or (error)
sub getRRDResolutions
{
	my ($rrdfile,$mode) = @_;
	my $info = RRDs::info($rrdfile);

	return "failed to retrieve RRD info: ".&RRDs::error
			if (ref($info) ne "HASH");

	my $basicstep = $info->{step};
	my (@others, $rrasection);
	for my $k (sort keys %$info)
	{
		if ($k =~ /^rra\[(\d+)\]\.cf$/)
		{
			next if ($info->{$k} ne $mode);
			$rrasection = $1;
		}
		elsif (defined($rrasection) && $k =~ /^rra\[$rrasection\]\.pdp_per_row$/)
		{
			push @others, $info->{$k};
			undef $rrasection;
		}
	}

	# return ascending
	return (undef, map { $basicstep * $_ } (sort { $a <=> $b } @others));
}

# retrieves rrd data and computes a number of descriptive stats
# args: database, required; hour_from hour_to define the daily period [from,to].
# if from > to then the meaning is inverted and data OUTSIDE the [to,from] interval is returned
# for midnight use either 0 or 24, depending on whether you want the inside or outside interval
#
# optional argument: truncate (defaults to 3), if >0 then results are reformatted as %.NNNf
# if -1 then untruncated values are returned.
#
# stats also include the ds's values, as an ordered list under the 'values' key,
# but NOT the original timestamps (relevant if filtered with hour_from/to)!
#
# returns: hashref of the stats
sub getRRDStats
{
	my %args = @_;
	my $db = $args{database};
	die "getRRDStats requires database argument!\n" if (!$db);
	require_RRDs(config => $args{config});

	my $graphtype = $args{graphtype};
	my $index = $args{index};
	my $item = $args{item};
	my $wanttruncate = (defined $args{truncate})? $args{truncate}: 3;

	my $minhr = (defined $args{hour_from}? $args{hour_from} : 0);
	my $maxhr = (defined $args{hour_to}? $args{hour_to} :  24) ;

	my $invertperiod = $minhr > $maxhr;


	if ( ! defined $args{mode} ) { $args{mode} = "AVERAGE"; }
	if ( -r $db ) {
		my ($begin,$step,$name,$data) = RRDs::fetch($db,$args{mode},"--start",$args{start},"--end",$args{end});
		my %s;
		my $time = $begin;
		for(my $a = 0; $a <= $#{$data}; ++$a) {
			my @timecomponents = localtime($time);
			my $hour = $timecomponents[2];
			for(my $b = 0; $b <= $#{$data->[$a]}; ++$b)
			{
				if ( defined $data->[$a][$b]
						 and
						 (
							# between from (incl) and to (excl) hour if not inverted
							( !$invertperiod and $hour >= $minhr and $hour < $maxhr )
							or
							# before to (excl) or after from (incl) hour if inverted,
							( $invertperiod and ($hour < $maxhr or $hour >= $minhr )) ))
				{
					push(@{$s{$name->[$b]}{values}},$data->[$a][$b]);
				}
			}
			$time = $time + $step;
		}

		foreach my $m (sort keys %s)
		{
			my %statsinfo = Statistics::Lite::statshash(@{$s{$m}{values}});
			$s{$m}{count} = $statsinfo{count}; # count of records, NOT all data - see hours from/to filtering
			$s{$m}{step} = $step;
			for my $key (qw(mean min max median range sum variance stddev))
			{
				$s{$m}{$key} = $wanttruncate>=0 ? sprintf("%.${wanttruncate}f", $statsinfo{$key}) : $statsinfo{$key};
			}
		}
		return \%s;
	}
	else
	{
		$stats{error} = "RRD is not readable rrd=$db";
		NMISNG::Util::logMsg("ERROR RRD is not readable rrd=$db");
		return undef;
	}
}

#
# add a DataSource to an existing RRD
# Cologne, dec 2004
# $rrd = filename of RRD, @ds = list of DS:name:type:hearthbeat:min:max
#
sub addDStoRRD
{
	my ($rrd, @ds,$config) = @_ ;
	die "addDStoRRD requires rrd argument!\n" if (!$rrd);
	require_RRDs(config=>$config);

	NMISNG::Util::dbg("update $rrd with @ds");

	my $rrdtool = "rrdtool";
	if ($^O =~ /win32/i) {
		$rrdtool = "rrdtool.exe";
	}
	my $info = `$rrdtool`;
	if ($info eq "")
	{
		# $rrdtool = "/opt/local/bin/rrdtool"; # maybe this
		$rrdtool = "/usr/local/rrdtool/bin/rrdtool"; # maybe this
		$info = `$rrdtool`;
		if ($info eq "")
		{
			NMISNG::Util::logMsg("ERROR, rrdtool not found");
			$stats{error} = "rrdtool not found";
			return;
		}
	}

	# version of rrdtool
	my $version = "10";
	if ($info =~ /.*RRDtool\s+(\d+)\.(\d+)\.(\d+).*/) {
		NMISNG::Util::dbg("RRDtool version is $1.$2.$3");
		$version = "$1$2";
	}

	my $DSname;
	my $DSvalue;
	my $DSprep;

	# Get XML Output
	### Adding Mark Nagel's fix for quoting strings.
	my $qrrd = quotemeta($rrd);
	my $xml = `$rrdtool dump $qrrd`;

	#prepare inserts
	foreach my $ds (@ds) {
		if ( $ds =~ /^DS:([a-zA-Z0-9_]{1,19}):(\w+):(\d+):([\dU]+):([\dU]+)/) {
			# Variables
			my $dsName      = $1;
			my $dsType      = $2;
			my $dsHeartBeat = $3;
			my $dsMin       = $4 eq 'U' ? 'NaN' : $4;
			my $dsMax       = $5 eq 'U' ? 'NaN' : $5;

			if ( $dsType !~ /^(GAUGE|COUNTER|DERIVE|ABSOLUTE)$/ )
			{
				NMISNG::Util::logMsg("ERROR, unknown DS type in $ds");
				$stats{error} = "unknown DS type in $ds";
				return undef;
			}
			if ($xml =~ /<name> $dsName </)
			{
				NMISNG::Util::logMsg("DS $ds already in database $ds");
			}
			else
			{
				$DSname .= "	<ds>
<name> $dsName </name>
<type> $dsType </type>
<minimal_heartbeat> $dsHeartBeat </minimal_heartbeat>
<min> $dsMin </min>
<max> $dsMax </max>

<!-- PDP Status -->
<last_ds> UNKN </last_ds>
<value> 0.0000000000e+00 </value>
<unknown_sec> 0 </unknown_sec>
</ds>\n";

				$DSvalue = $DSvalue eq "" ? "<v> NaN " : "$DSvalue </v><v> NaN ";

				if ($version > 11) {
					$DSprep .= "
<ds>
<primary_value> 0.0000000000e+00 </primary_value>
<secondary_value> 0.0000000000e+00 </secondary_value>
<value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				} else {
					$DSprep .= "<ds><value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				}
			}
		}
	}

	if ($DSname ne "" )
	{
		if ( $xml =~ /Round Robin Archives/ )
		{
			# check priv.
			if ( -w $rrd )
			{
				# Move the old source
				if (rename($rrd,$rrd.".bak"))
				{
					NMISNG::Util::dbg("$rrd moved to $rrd.bak");
					if ( -e "$rrd.xml" ) {
						# from previous action
						unlink $rrd.".xml";
						NMISNG::Util::dbg("$rrd.xml deleted (previous action)");
					}
					# update xml and rite output
					if (open(OUTF, ">$rrd.xml")) {
						foreach my $line (split(/\n/,$xml)) {
							if ( $line=~ /Round Robin Archives/ ) {
								print OUTF $DSname.$line;
							} elsif ($line =~ /^(.+?<row>)(.+?)(<\/row>.*)$/) {
								my @datasources_in_entry = split(/<\/v>/, $2);
								splice(@datasources_in_entry, 999, 0, "$DSvalue");
								my $new_line = join("</v>", @datasources_in_entry);
								print OUTF "$1$new_line</v>$3\n";
							} elsif ($line =~ /<\/cdp_prep>/) {
								print OUTF $DSprep.$line ;
							} else {
								print OUTF $line;
							}
						}
						close (OUTF);
						NMISNG::Util::dbg("xml written to $rrd.xml");
						# Re-import
						RRDs::restore($rrd.".xml",$rrd);
						if (my $ERROR = RRDs::error() )
						{
							NMISNG::Util::logMsg("update ERROR database=$rrd: $ERROR");
							$stats{error} = "update database=$rrd: $ERROR";
						}
						else
						{
							NMISNG::Util::dbg("$rrd created");
							NMISNG::Util::setFileProtDiag(file =>$rrd); # set file owner/permission, default: nmis, 0775
							unlink $rrd.".xml";
							NMISNG::Util::dbg("$rrd.xml deleted");
							unlink $rrd.".bak";
							NMISNG::Util::dbg("$rrd.bak deleted");
							NMISNG::Util::logMsg("INFO DataSource @ds added to $rrd");
							return 1;
						}
					}
					else
					{
						NMISNG::Util::logMsg("ERROR, could not open $rrd.xml for writing: $!");
						$stats{error} = "could not open $rrd.xml for writing: $!";
						rename($rrd.".bak",$rrd); # backup
					}
				}
				else
				{
					NMISNG::Util::logMsg("ERROR, cannot rename $rrd: $!");
					$stats{error} = "cannot rename $rrd: $!";
				}
			}
			else
			{
				NMISNG::Util::logMsg("ERROR, no write permission for $rrd: $!") ;
				$stats{error} = "no write permission for $rrd: $!";
			}
		}
		else
		{
			NMISNG::Util::logMsg("ERROR, could not dump $rrd (maybe rrdtool missing)");
			$stats{error} = "could not dump $rrd (maybe rrdtool missing)";
		}
	}
}

# this function takes in a set of data items and updates the relevant rrd file
# arsg: sys, database, data (absolutely required), type/index/item (more or less required), 
# extras (optional), time (optional, unix seconds; if given then that is passed to rrds as the reading's timestamp)
#
# the sys object is for the catch-22 issue of optionsRRD requiring knowledge from the model(s),
# plus there's the node-reset logic that requires catchall
#
# if node has admin marker node_was_reset or outage_nostats, then inbound
# data is IGNORED and 'U' is written instead
# (except for type "health", DS "outage", "polltime" and "updatetime", which are always let through)
#
# returns: the database file name or undef; sets the internal error indicator
sub updateRRD
{
	my %args = @_;
	require_RRDs(config => $args{config});

	my ($S,$data,$type,$index,$item,$database,$extras,$time) =
			@args{"sys","data","type","index","item","database","extras","time"};

	++ $stats{nodes}->{$S->{name}};
	NMISNG::Util::dbg("Starting RRD Update Process, db=$database, type=$type, index=$index, item=$item");

	if (!$database)
	{
		$stats{error} = "No RRD file given!";
		NMISNG::Util::logMsg("ERROR, $stats{error}");
		return;
	}

	# Does the database exist ?
	if ( -f $database and -r $database and -w $database )
	{
		NMISNG::Util::dbg("database $database exists and is R/W");
	}
	# Check if the RRD Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	elsif ( -f $database and not -w $database )
	{
		$stats{error} = "($S->{name}) database $database exists but is readonly!";
		NMISNG::Util::logMsg("ERROR, $stats{error}");
		return;
	}
	else 												# no db file exists
	{
		# nope, create new file
		if (! createRRD(data=>$data, sys=>$S, type=>$type, database=>$database,
										index=>$index))
		{
			$stats{error} = "Failed to create RRD file $database!";
			return; # error
		}
	}

	my (@updateargs, @ds, %blankme);
	# N means 'reading is for Now' - from RRDs' perspective, so maybe not ideal
	my @values = defined($time) && $time > 0? int($time) : "N";

	# ro clone is good enough. fixme9: non-node mode is an ugly hack
	my $catchall = $S->{name}? $S->inventory( concept => 'catchall' )->data : {};

	# if the node has gone through a reset, then insert a U to avoid spikes - but log once only
	NMISNG::Util::dbg("node was reset, inserting U values") if ($catchall->{admin}->{node_was_reset});


	# if the node has gone through a reset, then insert a U to avoid spikes for all COUNTER-ish DS
	if ($catchall->{admin}->{node_was_reset})
	{
		NMISNG::Util::dbg("node was reset, inserting U values");

		# get the DS definitions, extract the DS types and mark the counter-ish ones as blankable
		for (grep(/^DS:/, optionsRRD(data=>$data, sys=>$S, type=>$type, index=>$index)))
		{
			my (undef, $dsid, $dstype) = split(/:/, $_);
			if ($dstype ne "GAUGE")         # basically anything non-gauge is counter-ish
			{
				NMISNG::Util::dbg("marking DS $dsid in $type as blankable, DS type $dstype");
				$blankme{$dsid} = 1;
			}
		}
	}
	# similar to the node reset case, but this also blanks GAUGE DS
	NMISNG::Util::dbg("node has current outage with nostats option, inserting U values")
			if ($catchall->{admin}->{outage_nostats});

	for my $var (keys %{$data})
	{
		# handle the nosave option
		if (exists($data->{$var}->{option}) && $data->{$var}->{option} eq "nosave")
		{
			NMISNG::Util::dbg("DS $var is marked as nosave, not saving to RRD", 3);
			next;
		}
		push @ds, $var;

		# in outage with nostats option active?
		# then all rrds INCL health but EXCEPT health's outage/polltime/updatetime DS are overwritten
		# or was the node reset? then all known-blankable DS are overwritten
		# type health, ds outage, polltime, updatetime: are never overridden
		if ( ($catchall->{admin}->{node_was_reset} and $blankme{$var})
				 or ($catchall->{admin}->{outage_nostats}
						 and ($type ne "health" or  $var !~ /^(outage|polltime|updatetime)$/)))
		{
			push @values, 'U';
		}
		else
		{
			# cleanup invalid values:
			# nonexistent or blank object we treat as 0
			$data->{$var}{value} = 0 if ($data->{$var}{value} eq "noSuchObject"
																	 or $data->{$var}{value} eq "noSuchInstance"
																	 or $data->{$var}{value} eq "");

			# then get rid of unwanted leading or trailing white space
			$data->{$var}{value} =~ s/^\s*//;
			$data->{$var}{value} =~ s/\s*$//;

			# other non-numeric input becomes rrdtool's 'undefined' value
			# all standard integer/float notations (incl 1.345E+7) should be accepted
			$data->{$var}{value} = "U" if ($data->{$var}{value} !~
																		 /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/);

			push @values,  $data->{$var}{value};
		}
	}
	my $thevalue =  join(":",@values);
	my $theds = join(":",@ds);
	push @updateargs,("-t", $theds, $thevalue);

	my $points = scalar @ds;
	# for bytes consider a 64 bit word, 8 bytes for each thing.
	#64-bits (8 bytes),
	my $bytes = $points * 8;

	$stats{datapoints} += $points;
	$stats{databytes} += $bytes;

	NMISNG::Util::dbg("DS $theds, $points");
	NMISNG::Util::dbg("value $thevalue, $bytes bytes");

	NMISNG::Util::logPolling("$type,$S->{name},$index,$item,$theds,$thevalue");

	if (@updateargs)
	{
		# update RRD
		RRDs::update($database, @updateargs);
		++$stats{rrdcount};

		if (my $ERROR = RRDs::error())
		{
			if ($ERROR !~ /contains more DS|unknown DS name/)
			{
				$stats{error} = "($S->{name}) database=$database: $ERROR: options = @updateargs";
				NMISNG::Util::logMsg("ERROR $stats{error}");
			}
			else
			{
				NMISNG::Util::dbg("missing DataSource in $database, try to update");
				# find the DS names in the existing database (format ds[name].* )
				my $info = RRDs::info($database);
				my $names = ":";
				foreach my $key (keys %$info) {
					if ( $key =~ /^ds\[([a-zA-Z0-9_]{1,19})\].+/) { $names .= "$1:";}
				}
				# find the missing DS name (format DS:name:type:hearthbeat:min:max)
				my @options_db = optionsRRD(data=>$data,sys=>$S,type=>$type,index=>$index);
				foreach my $ds (@options_db)
				{
					my @opt = split /:/, $ds;
					if ( $opt[0] eq "DS" and $names !~ /:$opt[1]:/ )
					{
						&addDStoRRD($database,$ds); # sub in rrdfunc
					}
				}
			}
		}
	}
	else
	{
		$stats{error} = "($S->{name}) type=$type, no data to create/update database";
		NMISNG::Util::logMsg("ERROR $stats{error}");
	}
	return $database;
	NMISNG::Util::dbg("Finished");
} # end updateRRD

# the optionsRRD function creates the configuration options
# for creating an rrd file.
# args: sys, data, type (all pretty much required),
# index (optional, for string expansion)
# returns: array of rrdcreate parameters; updates global %stats
sub optionsRRD
{
	my %args = @_;
	my $S = my $M = $args{sys};
	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index}; # optional

	die "optionsRRD cannot work without Sys argument!\n" if (!$S);
	NMISNG::Util::dbg("type $type, index $index");

	my $mdlinfo = $S->mdl;
	# find out rrd step and heartbeat values, possibly use type-specific values (which the polling policy would supply)
	my $timinginfo = (ref($mdlinfo->{database}) eq "HASH"
										&& ref($mdlinfo->{database}->{db}) eq "HASH"
										&& ref($mdlinfo->{database}->{db}->{timing}) eq "HASH")?
										$mdlinfo->{database}->{db}->{timing}->{$type} // $mdlinfo->{database}->{db}->{timing}->{"default"}
	:  undef;
	$timinginfo //= { heartbeat => 900, poll => 300 };
	# note: heartbeat is overridable per DS by passing in 'heartbeat' in data!
	NMISNG::Util::dbg("timing options for this file of type $type: step $timinginfo->{poll}, heartbeat $timinginfo->{heartbeat}");


	# align the start time with the step interval, but reduce by one interval so that we can send data immediately
	my $starttime = time - (time % $timinginfo->{poll}) - $timinginfo->{poll};
	my @options = ("-b", $starttime, "-s", $timinginfo->{poll});

	# $data{ds_name}{value} contains the values
	# $data{ds_name}{option} contains the info for creating the dds, format is "source,low:high,heartbeat"
	# where source can be GAUGE,COUNTER etc. low:high are the limits of values to store, heartbeat
	# is for overriding the rrdfile-level heartbeat. range and heartbeat are optional, the ',' are clearly needed
	# even if you skip range but provide heartbeat.
	#
	# default is GAUGE,"U:U", and the standard heartbeat
	foreach my $id (sort keys %{$data})
	{
		if (length($id) > 19)
		{
			$stats{error} = "DS name=$id greater then 19 characters";
			NMISNG::Util::logMsg("ERROR, DS name=$id greater then 19 characters") ;
			next;
		}

		my ($source,$range,$heartbeat);
		if ($data->{$id}{option})
		{
			if ($data->{$id}->{option} eq "nosave")
			{
				NMISNG::Util::dbg("DS $id marked as nosave, ignoring.", 3);
				next;
			}

			($source,$range,$heartbeat) = split (/\,/,$data->{$id}{option});

			# no CVARs possible as no section given
			# not a full expression so no eval
			$range = $S->parseString(string=>$range, type=>$type, index=>$index, eval => 0);
			$source = uc $source;
		}
		$source ||= "GAUGE";
		$range ||= "U:U";
		$heartbeat ||= $timinginfo->{heartbeat};

		NMISNG::Util::dbg("ID of data is $id, source $source, range $range, heartbeat $heartbeat",2);
		push @options,"DS:$id:$source:$heartbeat:$range";
	}

	# now figure out the consolidation parameters, again possibly type-specific plus fallback
	my $sizeinfo = (ref($mdlinfo->{database}) eq "HASH"
									&& ref($mdlinfo->{database}->{db}) eq "HASH"
									&& ref($mdlinfo->{database}->{db}->{size}) eq "HASH")?
									$mdlinfo->{database}->{db}->{size}->{$type} // $mdlinfo->{database}->{db}->{size}->{"default"} :  undef;
	$sizeinfo //= { step_day => 1, step_week => 6, step_month => 24, step_year => 288,
									rows_day => 2304, rows_week => 1536, rows_month => 2268, rows_year => 1890 };

	for my $period (qw(day week month year))
	{
		for my $rra (qw(AVERAGE MIN MAX))
		{
			push @options,  join(":", "RRA", $rra, 0.5, $sizeinfo->{"step_$period"}, $sizeinfo->{"rows_$period"});
		}
	}
	return @options;
}

# createRRD: checks if RRD exists, creates one if necessary
# (as well as dir hierarchy)
# note: does NOT create anything if the file var/nmis_system/dbdir_full exists
# (which is created by selftest)
#
# args: sys, data, database, type,  index - all required
# returns: 1 if ok, 0 otherwise.
sub createRRD
{
	my %args = @_;

	my $S = $args{sys};
	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index};
	my $database = $args{database};

	require_RRDs(config => $args{config});
	my $C = NMISNG::Util::loadConfTable();

	$S->nmisng->log->debug("check and/or create RRD database $database");

	# are we allowed to create new files, or is the filesystem with the database dir (almost) full already?
	# marker file name also embedded in util.pm
	if (-f "$C->{'<nmis_var>'}/nmis_system/dbdir_full")
	{
		$stats{error} = "Not creating $database, as database filesystem is (almost) full!";
		$S->nmisng->log->error("Not creating $database, as database filesystem is (almost) full!");
		return 0;
	}

	# Does the database exist already?
	if (-f $database)
	{
		# nothing to do!
		$S->nmisng->log->debug("Database $database already exists");
		return 1;
	}

	# create new rrd file, maybe dir structure too
	my $dir = dirname($database);
	NMISNG::Util::createDir($dir) if (!-d $dir);

	my @options = optionsRRD(data=>$data,sys=>$S,type=>$type,index=>$index);
	if (!@options)
	{
		$stats{error} = "($S->{name}) unknown type=$type";
		$S->nmisng->log->error("($S->{name}) unknown type=$type");
		return 0;
	}

	$S->nmisng->log->info("Creating new RRD database $database");
	$S->nmisng->log->debug("Options for creating $database: ".
												 Data::Dumper->new([\@options])->Terse(1)->Indent(0)->Pair(": ")->Dump);
	RRDs::create("$database",@options);
	my $ERROR = RRDs::error();
	if ($ERROR)
	{
		$stats{error} = "($S->{name}) unable to create $database: $ERROR";
		$S->nmisng->log->error("($S->{name}) unable to create $database: $ERROR");
		return 0;
	}
	# set file owner and permission, default: nmis, 0775.
	NMISNG::Util::setFileProtDiag(file =>$database);

	# Double check created OK for this user
	return 1 if ( -f $database and -r $database and -w $database );

	$stats{error} = "($S->{name}) could not create RRD $database - check directory permissions";
	$S->nmisng->log->error("($S->{name}) could not create RRD $database - check directory permissions");
	return 0;
}

# produce one graph
# args: node/uuid/group OR live sys object, graphtype, intf/item, width, height (all required),
#  start, end, filename (optional)
#
# if filename is given then the graph is saved there.
# if no filename is given, then the graph is printed to stdout with minimal content-type header.
#
# returns: hashref (keys success/error, x,y, graph (=rrds::graph result array))
sub draw
{
	my %args = @_;

	my ($S,$nodename,$nodeuuid,$mygroup,$graphtype,$intf,$item,
			$width,$height,$filename,$start,$end,$time,$debug)
			= @args{qw(sys node uuid group graphtype intf item width height filename start end time debug)};

	my $C = NMISNG::Util::loadConfTable();
	require_RRDs(config => $C);

	if (ref($S) ne "NMISNG::Sys")
	{
		$S = NMISNG::Sys->new;
		$S->init(name => $nodename, uuid => $nodeuuid, snmp=>'false');
	}
	else
	{
		$nodename = $S->nmisng_node->name;
	}

	# fixme9: non-node mode is a dirty hack.
	# fixme9: catchall_data is not used?!
	if ($nodename)
	{
		my $catchall_data = $S->inventory( concept => 'catchall' )->data();
	}
	my $subconcept = $S->loadGraphTypeTable->{$graphtype};

	# default unit is hours!
	my $graphlength = ( $C->{graph_unit} eq "days" )?
			86400 * $C->{graph_amount} : 3600 * $C->{graph_amount}; # want seconds

	my $when = $time // time;
	$start = $when-$graphlength if (!$start);
	$end = $when if (!$end);

	# prep human-friendly (imprecise!) length of graph period
	my $mylength;									# cannot be called length
	if (($end - $start) < 3600)
	{
		$mylength = int(($end - $start) / 60) . " minutes";
	}
	elsif (($end - $start) < (3600*48))
	{
		$mylength = int(($end - $start) / (3600)) . " hours";
	}
	else
	{
		$mylength = int(($end - $start) / (3600*24)) . " days";
	}

	my (@rrdargs, 								# final rrd graph args
			$mydatabase);								# path to the rrd file

	# special graphtypes: global metrics
	if ($graphtype eq 'metrics')
	{
		$item = $mygroup;
		undef $intf;
	}

	# special graphtypes: cbqos is dynamic (multiple inputs create one graph), ditto calls
	if ($graphtype =~ /cbqos/)
	{
		@rrdargs = graphCBQoS(sys=>$S,
													graphtype=>$graphtype,
													intf=>$intf,
													item=>$item,
													start=>$start, end=>$end,
													width=>$width, height=>$height);
	}
	else
	{
		$mydatabase = $S->makeRRDname(graphtype=>$graphtype, index=>$intf, item=>$item);
		return { error => "failed to find database for graphtype $graphtype!" } if (!$mydatabase);

		my $res = NMISNG::Util::getModelFile(model => "Graph-$graphtype");
		return { return => "failed to read Graph-$graphtype!" } if (!$res->{success});
		my $graph = $res->{data};


		my $titlekey =  ($width <= 400 and $graph->{title}{short})? 'short' : 'standard';
		my $vlabelkey = (NMISNG::Util::getbool($C->{graph_split}) and $graph->{vlabel}{split})? 'split'
				: ($width <= 400 and $graph->{vlabel}{short})? 'short' : 'standard';
		my $size =  ($width <= 400 and $graph->{option}{small})? 'small' : 'standard';

		my $title = $graph->{title}{$titlekey};
		my $label = $graph->{vlabel}{$vlabelkey};

		#  fixme replace with log+debug
		NMISNG::Util::logMsg("no title->$titlekey found in Graph-$graphtype") if (!$title);
		NMISNG::Util::logMsg("no vlabel->$vlabelkey found in Graph-$graphtype") if (!$label);

		@rrdargs = (
			"--title", $title,
			"--vertical-label", $label,
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
			push(@rrdargs, "--font", $C->{graph_default_font_standard}) if $C->{graph_default_font_standard};
		}
		else
		{
			push(@rrdargs, "--font", $C->{graph_default_font_small}) if $C->{graph_default_font_small};
		}
		push @rrdargs, @{$graph->{option}{$size}};
	}

	my $extras = {
		node => $nodename,
		datestamp_start => NMISNG::Util::returnDateStamp($start),
		datestamp_end => NMISNG::Util::returnDateStamp($end),
		datestamp => NMISNG::Util::returnDateStamp(time),
		database => $mydatabase,
		length => $mylength,
		group => $mygroup,
		itm => $item,
		split => NMISNG::Util::getbool($C->{graph_split}) ? -1 : 1 ,
		GLINE => NMISNG::Util::getbool($C->{graph_split}) ? "AREA" : "LINE1",
		weight => 0.983,
	};

	for my $idx (0..$#rrdargs)
	{
		my $str = $rrdargs[$idx];

		my %parseargs = ( string => $str,
											index => $intf,
											item => $item,
											sect => $subconcept,
											extras => { %$extras } ); # extras is modified by every call, so pass in a copy

		# escape any ':' chars which might be in the database name (e.g C:\\) or the other
		# inputs (e.g. indx == service name). this must be done for ALL substitutables,
		# but no thanks to no strict we don't exactly know who they are, nor can we safely change
		# their values without side-effects...so we do it on the go, and only where not already pre-escaped.

		# EXCEPT in --title, where we can't have colon escaping. grrrrrr!
		if  ($idx <= 0 || $rrdargs[$idx-1] ne "--title")
		{
			$parseargs{index} = Compat::NMIS::postcolonial($parseargs{index});
			$parseargs{item} = Compat::NMIS::postcolonial($parseargs{item});
			$parseargs{extras} = { map { $_ => Compat::NMIS::postcolonial($extras->{$_}) } (keys %$extras) };
		}
		my $parsed = $S->parseString( %parseargs, eval => 0 );
		$rrdargs[$idx] = $parsed;
	}

	my ($graphret, $xs, $ys);
	# finally, generate the graph - as an indep http response to stdout
	# (bit uggly, no etag, expiration, content-length...)...
	if (!$filename)
	{
		# if this isn't done, then the graph output overtakes the header output,
		# and apache considers the cgi script broken and returns 500
		STDOUT->autoflush(1);
		print "Content-type: image/png\n\n";
		($graphret,$xs,$ys) = RRDs::graph('-', @rrdargs);
	}
	# ...or as a file.
	else
	{
		($graphret,undef,undef) = RRDs::graph($filename, @rrdargs);
	}
	if (my $error = RRDs::error())
	{
		return { error => "Graphing Error for graphtype $graphtype, database $mydatabase: $error" };
	}
	return { success => 1, x => $xs, y => $ys, graph => $graphret };
}

# special graph helper for CBQoS
# this handles both cisco and huawei flavour cbqos
# args: sys, graphtype, intf/item, start, end, width, height (all required)
# returns: array of rrd args
sub graphCBQoS
{
	my %args = @_;

	my $C = NMISNG::Util::loadConfTable;
	my ($S,$graphtype,$intf,$item,$start,$end,$width,$height,$debug)
			= @args{qw(sys graphtype intf item start end width height debug)};

	my $catchall_data = $S->inventory( concept => 'catchall' )->data();

	# order the names, find colors and bandwidth limits, index and section names
	my ($CBQosNames, $CBQosValues) = Compat::NMIS::loadCBQoS(sys=>$S, graphtype=>$graphtype, index=>$intf);

	# because cbqos we should find interface
	my $inventory = $S->inventory( concept => 'interface', index => $intf, nolog => 0, partial => 1 );
	my $if_data = ($inventory) ? $inventory->data : {};

	# display all class-maps in one graph...
	if ($item eq "")
	{
		my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;
		my $ifDescr = NMISNG::Util::shortInterface($if_data->{ifDescr});
		my $vlabel = "Avg Bits per Second";
		my $title;

		if ( $width <= 400 ) {
			$title = "$catchall_data->{name} $ifDescr $direction";
			$title .= " - $CBQosNames->[0]" if ($CBQosNames->[0] && $CBQosNames->[0] !~ /^(in|out)bound$/i);
			$title .= ' - $length';
			$vlabel = "Avg bps";
		}
		else
		{
			$title = "$catchall_data->{name} $ifDescr $direction - CBQoS from ".'$datestamp_start to $datestamp_end'; # fixme: why replace later??
		}

		my @opt = (
			"--title", $title,
			"--vertical-label", $vlabel,
			"--start", $start,
			"--end", $end,
			"--width", $width,
			"--height", $height,
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
		my $avgppr = "CDEF:avgPrePolicyBitrate=0";
		my $maxppr = "CDEF:maxPrePolicyBitrate=0";
		my $avgdbr = "CDEF:avgDropBitrate=0";
		my $maxdbr = "CDEF:maxDropBitrate=0";

		# is this hierarchical or flat?
		my $HQOS = 0;
		foreach my $i (1..$#$CBQosNames)
		{
			if ( $CBQosNames->[$i] =~ /^([\w\-]+)\-\-\w+\-\-/ )
			{
				$HQOS = 1;
				last;
			}
		}

		my $gtype = "AREA";
		my $gcount = 0;
		my $parent_name = "";
		foreach my $i (1..$#$CBQosNames)
		{
			my $thisinfo = $CBQosValues->{$intf.$CBQosNames->[$i]};

			my $database = $S->makeRRDname(graphtype => $thisinfo->{CfgSection},
																index => $thisinfo->{CfgIndex},
																item => $CBQosNames->[$i]	);
			my $parent = 0;
			if ( $CBQosNames->[$i] !~ /\w+\-\-\w+/ and $HQOS )
			{
				$parent = 1;
				$gtype = "LINE1";
			}

			if ( $CBQosNames->[$i] =~ /^([\w\-]+)\-\-\w+\-\-/ )
			{
				$parent_name = $1;
				NMISNG::Util::dbg("parent_name=$parent_name\n") if ($debug);
			}

			if ( not $parent and not $gcount)
			{
				$gtype = "AREA";
				++$gcount;
			}
			elsif ( not $parent and $gcount)
			{
				$gtype = "STACK";
				++$gcount;
			}
			my $alias = $CBQosNames->[$i];
			$alias =~ s/$parent_name\-\-//g;
			$alias =~ s/\-\-/\//g;

			# rough alignment for the columns, necessarily imperfect
			# as X-char strings aren't equally wide...
			my $tab = "\\t";
			if ( length($alias) <= 5 )
			{
				$tab = $tab x 4;
			}
			elsif ( length($alias) <= 14 )
			{
				$tab = $tab x 3;
			}
			elsif ( length($alias) <= 19 )
			{
				$tab = $tab x 2;
			}

			my $color = $CBQosValues->{$intf.$CBQosNames->[$i]}{'Color'};

			push @opt, ("DEF:avgPPB$i=$database:".$thisinfo->{CfgDSNames}->[0].":AVERAGE",
									"DEF:maxPPB$i=$database:".$thisinfo->{CfgDSNames}->[0].":MAX",
									"DEF:avgDB$i=$database:".$thisinfo->{CfgDSNames}->[2].":AVERAGE",
									"DEF:maxDB$i=$database:".$thisinfo->{CfgDSNames}->[2].":MAX",
									"CDEF:avgPPR$i=avgPPB$i,8,*",
									"CDEF:maxPPR$i=maxPPB$i,8,*",
									"CDEF:avgDBR$i=avgDB$i,8,*",
									"CDEF:maxDBR$i=maxDB$i,8,*",);

			if ($width > 400)
			{
				push @opt, ("$gtype:avgPPR$i#$color:$alias$tab",
										"GPRINT:avgPPR$i:AVERAGE:Avg %8.2lf%s\\t",
										"GPRINT:maxPPR$i:MAX:Max %8.2lf%s\\t",
										"GPRINT:avgDBR$i:AVERAGE:Avg Drops %6.2lf%s\\t",
										"GPRINT:maxDBR$i:MAX:Max Drops %6.2lf%s\\l");
			}
			else
			{
				push(@opt,"$gtype:avgPPR$i#$color:$alias");
			}

			#push(@opt,"LINE1:avgPPR$i#$color:$CBQosNames->[$i]");
			$avgppr .= ",avgPPR$i,+";
			$maxppr .= ",maxPPR$i,+";
			$avgdbr .= ",avgDBR$i,+";
			$maxdbr .= ",maxDBR$i,+";
		}

		push @opt,$avgppr,$maxppr,$avgdbr, $maxdbr;

		if ($width > 400)
		{
			push(@opt,"COMMENT:\\l",
					 "GPRINT:avgPrePolicyBitrate:AVERAGE:PrePolicyBitrate\\t\\t\\tAvg %8.2lf%s\\t",
					 "GPRINT:maxPrePolicyBitrate:MAX:Max\\t%8.2lf%s\\l",
					 "GPRINT:avgDropBitrate:AVERAGE:DropBitrate\\t\\t\\tAvg %8.2lf%s\\t",
					 "GPRINT:maxDropBitrate:MAX:Max\\t%8.2lf%s\\l");
		}
		return @opt;
	}

	# ...or display ONLY the selected class-map

	my $thisinfo = $CBQosValues->{$intf.$item};
	my $speed = defined $thisinfo->{CfgRate}? &NMISNG::Util::convertIfSpeed($thisinfo->{'CfgRate'}) : undef;
	my $direction = ($graphtype eq "cbqos-in") ? "input" : "output" ;

	my $database =  $S->makeRRDname(graphtype => $thisinfo->{CfgSection},
															index => $thisinfo->{CfgIndex},
															item => $item	);

	# in this case we always use the FIRST color, not the one for this item
	my $color = $CBQosValues->{$intf.$CBQosNames->[1]}->{'Color'};

	my $ifDescr = NMISNG::Util::shortInterface($if_data->{ifDescr});
	my $title = "$ifDescr $direction - $item from ".'$datestamp_start to $datestamp_end'; # fixme: why replace later??

	my @opt = (
		"--title", $title,
		"--vertical-label", 'Avg Bits per Second',
		"--start", $start,
		"--end", $end,
		"--width", $width,
		"--height", $height,
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

		if ($width > 400)
		{
			push(@opt,"--font", $C->{graph_default_font_standard}) if $C->{graph_default_font_standard};
		}
		else
		{
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
			push @opt, ( "GPRINT:PrePolicyByte:AVERAGE:Bytes transferred\\t\\tAvg %8.2lf %sB/s\\n",
									 "GPRINT:DropByte:AVERAGE:Bytes dropped\\t\\t\\tAvg %8.2lf %sB/s\\t",
									 "GPRINT:maxDropByte:MAX:Max %8.2lf %sB/s\\n",
									 "GPRINT:PrePolicyPkt:AVERAGE:Packets transferred\\t\\tAvg %8.2lf\\l",
									 "GPRINT:DropPkt:AVERAGE:Packets dropped\\t\\t\\tAvg %8.2lf");

			# huawei doesn't have that
			push(@opt,"COMMENT:\\l","GPRINT:NoBufDropPkt:AVERAGE:Packets No buffer dropped\\tAvg %8.2lf\\l")
					if (defined $thisinfo->{CfgDSNames}->[6]);

			# not all qos setups have a graphable bandwidth limit
			push @opt, "COMMENT:\\u", "COMMENT:".$thisinfo->{CfgType}." $speed\\r" if (defined $speed);
		}
	return @opt;
}


1;
