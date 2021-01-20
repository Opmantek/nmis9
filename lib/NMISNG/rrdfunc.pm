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
our $VERSION = "9.1.2a";

use strict;
use feature 'state';
use Config;

use File::Basename;
use Statistics::Lite;
use Carp;
use POSIX qw();									# for strftime

use NMISNG::Util;

# This function should be called if using any RRDS:: functionality directly
# Functions in this file will also call it for you
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
my $_last_error;
sub getRRDerror
{
	return $_last_error;
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
	&require_RRDs;

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

		# compute date only if at least one ds col has defined data
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
		# OMK-6567
		my $bucketstart;
		my @times = (sort keys %s);
		if (scalar @times > 0)
		{
			$bucketstart = $meta{start} = List::Util::max($args{start}, $times[0]); # $begin can be one step interval later
		}
		else
		{
			$bucketstart = $meta{start} = $args{start}; # $begin can be one step interval later
		}
		#my $last_time = $times[-1]; # for debugging
		undef @times;

		$meta{step} = $bucketsize * $step;

		# OMK-6567: '$nrbuckets = int($nrdatapoints/$bucketsize + 0.5)' calc is not valid
		#			as $wantedresolution, used in calculating the step times $targettime is not taken into account
		#			this causes incorrect number buckets being calculated in certain circumstances
		my $nrbuckets = int(($meta{end}-$meta{start})/$wantedresolution + 0.5); # last bucket may end up partially filled
		###my $nrdatapoints = @$data;
		###my $nrbuckets = int($nrdatapoints/$bucketsize + 0.5); # last bucket may end up partially filled
		$meta{rows} = $meta{rows_with_data} = $nrbuckets;

		# OMK-6567
		my ($targettime,$prev_targettime);
		for my $bucket (1..$nrbuckets)
		{
			# OMK-6567: bucket targettime's are increasing;
			#			keep previous bucket's targettime to ensure we don't delete an earlier bucket's targettime
			#				further below when 'if($slot)'
			#			on first bucket, $targettime is undef at this point,
			#				so we set a large negative number (-1 could probably have sufficed, but lets be sure):
			$prev_targettime = $targettime // -($bucketstart + $bucket * $wantedresolution);
			$targettime = $bucketstart + $bucket * $wantedresolution;
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
				if ($slot) # last timeslot receives all the readings for the whole bucket
				{
					# OMK-6567: ensure we don't delete an earlier bucket's targettime
					#			this issue is fixed by improved calc for $nrbuckets above, but kept to be safe:
					if ($contribtime > $prev_targettime)
					{
						delete $s{$contribtime}
					}
				}
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
# returns: hashref of the stats, or undef (check getRRDerror in that case!)
sub getRRDStats
{
	my %args = @_;
	my $db = $args{database};

	confess("getRRDStats requires database argument!") if (!$db);
	undef $_last_error;

	if (! -r $db)
	{
		$_last_error = "RRD file $db is not readable!";
		return undef;
	}

	&require_RRDs;

	my $graphtype = $args{graphtype};
	my $index = $args{index};
	my $item = $args{item};
	my $wanttruncate = (defined $args{truncate})? $args{truncate}: 3;

	my $minhr = (defined $args{hour_from}? $args{hour_from} : 0);
	my $maxhr = (defined $args{hour_to}? $args{hour_to} :  24) ;

	my $invertperiod = $minhr > $maxhr;

	if (! defined $args{mode}) { $args{mode} = "AVERAGE"; }

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

# add a DataSource to an existing RRD
# args: nmisng object, rrd file path, list of ds elements
# returns: error message or undef
sub addDStoRRD
{
	my ($nmisng, $rrd, @ds, ) = @_ ;
	confess("addDStoRRD requires rrd argument!") if (!$rrd);
	&require_RRDs;

	my $rrdtool = ($^O =~ /win32/i)? "rrdtool.exe" : "rrdtool";
	my $info = `$rrdtool`;
	if ($info eq "")
	{
		$rrdtool = "/usr/local/rrdtool/bin/rrdtool"; # maybe this
		$info = `$rrdtool`;
		return "rrdtool executable not found!"
				if ($info eq "");
	}

	# version of rrdtool
	my $version = "10";
	if ($info =~ /.*RRDtool\s+(\d+)\.(\d+)\.(\d+).*/)
	{
		$version = "$1$2";
	}

	my ($DSname, $DSvalue, $DSprep);

	$nmisng->log->debug("Preparing to update RRD file $rrd with DS @ds");
	# Get XML Output
	my $qrrd = quotemeta($rrd);
	my $xml = `$rrdtool dump $qrrd`;

	return "could not dump $rrd!" if ($xml !~ /Round Robin Archives/);

	# prepare inserts
	my $addme;
	foreach my $ds (@ds)
	{
		if ( $ds =~ /^DS:([a-zA-Z0-9_]{1,19}):(\w+):(\d+):([\dU]+):([\dU]+)/)
		{
			# Variables
			my $dsName      = $1;
			my $dsType      = $2;
			my $dsHeartBeat = $3;
			my $dsMin       = $4 eq 'U' ? 'NaN' : $4;
			my $dsMax       = $5 eq 'U' ? 'NaN' : $5;

			if ( $dsType !~ /^(GAUGE|COUNTER|DERIVE|ABSOLUTE)$/ )
			{
				return "unknown DS type in $ds";
			}
			if ($xml =~ /<name> $dsName </)
			{
				$nmisng->log->debug("DS $ds already present in database $rrd");
			}
			else
			{
				++$addme;
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

				if ($version > 11)
				{
					$DSprep .= "
<ds>
<primary_value> 0.0000000000e+00 </primary_value>
<secondary_value> 0.0000000000e+00 </secondary_value>
<value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				}
				else {
					$DSprep .= "<ds><value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				}
			}
		}
	}

	# nothing to do?
	if (!defined $DSname)
	{
		$nmisng->log->debug("All requested DS already present in RRD file $rrd.");
		return undef;
	}

	return "no write permission for $rrd" if (!-w $rrd);

	# Move the old rrdfile
	unlink("$rrd.bak") if (-e "$rrd.bak");
	return "cannot rename $rrd to $rrd.ak: $!" if (!rename($rrd, "$rrd.bak"));

	# write output to new xml file
	if (!open(OUTF, ">$rrd.xml"))
	{
		rename("$rrd.bak", $rrd);		# restore backup
		return "could not write to $rrd.xml: $!";
	}

	foreach my $line (split(/\n/,$xml))
	{
		if ( $line =~ /Round Robin Archives/ )
		{
			print OUTF $DSname.$line;
		}
		elsif ($line =~ /^(.+?<row>)(.+?)(<\/row>.*)$/)
		{
			my @datasources_in_entry = split(/<\/v>/, $2);
			splice(@datasources_in_entry, 999, 0, "$DSvalue"); # fixme dangerous assumption
			my $new_line = join("</v>", @datasources_in_entry);

			print OUTF "$1$new_line</v>$3\n";
		}
		elsif ($line =~ /<\/cdp_prep>/)
		{
			print OUTF $DSprep.$line ;
		}
		else
		{
			print OUTF $line;
		}
	}
	close (OUTF);
	$nmisng->log->debug("xml written to $rrd.xml");
	# Re-import
	RRDs::restore($rrd.".xml", $rrd);
	if (my $ERROR = RRDs::error() )
	{
		rename("$rrd.bak", $rrd);		# restore backup
		return "import of updated RRD database $rrd failed: $ERROR";
	}

	NMISNG::Util::setFileProtDiag(file => $rrd);
	unlink("$rrd.xml","$rrd.bak");
	$nmisng->log->debug("$addme DS successfullly added to $rrd");
	return undef;
}

# this function takes in a set of data items and updates the relevant rrd file
# args: sys, database, data (absolutely required), type/index/item (more or less required),
# extras (optional), time (optional, unix seconds; if given then that is passed to rrds as the reading's timestamp)
#
# the sys object is for the catch-22 issue of optionsRRD requiring knowledge from the model(s),
# plus there's the node-reset logic that requires catchall
#
# if node has admin marker node_was_reset or outage_nostats, then inbound
# data is IGNORED and 'U' is written instead
# (except for type "health", DS "outage", "polltime" and "updatetime", which are always let through)
#
# returns: the database file name or undef; sets the error indicator, does NOT log (left to caller)
sub updateRRD
{
	my %args = @_;
	&require_RRDs;

	my ($S,$data,$type,$index,$item,$database,$extras,$time) =
			@args{"sys","data","type","index","item","database","extras","time"};

	undef $_last_error;
	$S->nmisng->log->debug3(&NMISNG::Log::trace()
													. "Starting RRD Update Process, db=$database, type=$type, index=$index, item=$item");

	if (!$database)
	{
		$_last_error = "No RRD file given!";
		return undef;
	}

	# Check if the RRD Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	if ( -f $database and not -w $database )
	{
		$_last_error = "($S->{name}) database $database exists but is readonly!";
		return undef;
	}
	elsif (!-f $database) 												# no db file exists
	{
		# nope, create new file
		if (my $error = createRRD(data=>$data, sys=>$S, type=>$type, database=>$database,
																 index=>$index))
		{
			$_last_error = "Failed to create RRD file $database: $error";
			return undef;
		}
	}

	my (@updateargs, @ds, %blankme);
	# N means 'reading is for Now' - from RRDs' perspective, so maybe not ideal
	my @values = defined($time) && $time > 0? int($time) : "N";

	# ro clone is good enough. fixme9: non-node mode is an ugly hack
	my $catchall = $S->{name}? $S->inventory( concept => 'catchall' )->data : {};

	# if the node has gone through a reset, then insert a U to avoid spikes - but log once only
	$S->nmisng->log->debug3(&NMISNG::Log::trace()
													. "node was reset, inserting U values") if ($catchall->{admin}->{node_was_reset});


	# if the node has gone through a reset, then insert a U to avoid spikes for all COUNTER-ish DS
	if ($catchall->{admin}->{node_was_reset})
	{
		$S->nmisng->log->debug3(&NMISNG::Log::trace()
														. "node was reset, inserting U values");

		# get the DS definitions, extract the DS types and mark the counter-ish ones as blankable
		for (grep(/^DS:/, optionsRRD(data=>$data, sys=>$S, type=>$type, index=>$index)))
		{
			my (undef, $dsid, $dstype) = split(/:/, $_);
			if ($dstype ne "GAUGE")         # basically anything non-gauge is counter-ish
			{
				$S->nmisng->log->debug3(&NMISNG::Log::trace()
																. "marking DS $dsid in $type as blankable, DS type $dstype");
				$blankme{$dsid} = 1;
			}
		}
	}
	# similar to the node reset case, but this also blanks GAUGE DS
	$S->nmisng->log->debug3(&NMISNG::Log::trace()
													. "node has current outage with nostats option, inserting U values")
			if ($catchall->{admin}->{outage_nostats});

	for my $var (keys %{$data})
	{
		# handle the nosave option
		if (exists($data->{$var}->{option}) && $data->{$var}->{option} eq "nosave")
		{
			$S->nmisng->log->debug3(&NMISNG::Log::trace()
															. "DS $var is marked as nosave, not saving to RRD");
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

	$S->nmisng->log->debug2("DS $theds, $points");
	$S->nmisng->log->debug2("value $thevalue, $bytes bytes");

	NMISNG::Util::logPolling("$type,$S->{name},$index,$item,$theds,$thevalue");

	if (!@updateargs)
	{
		$_last_error = "($S->{name}) type=$type, no data to create/update database";
		return undef;
	}

	# update RRD
	RRDs::update($database, @updateargs);
	if (my $ERROR = RRDs::error())
	{
		if ($ERROR !~ /contains more DS|unknown DS name/)
		{
			$_last_error = "($S->{name}) database=$database: $ERROR: options = @updateargs";
			return undef;
		}

		$S->nmisng->log->debug3(&NMISNG::Log::trace()
														."missing DataSource in $database, try to update");
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
				if (my $error = &addDStoRRD($S->nmisng, $database, $ds))
				{
					$_last_error = $error;
					return undef;
				}
			}
		}
	}
	return $database;
}

# the optionsRRD function creates the configuration options
# for creating an rrd file.
# args: sys, data, type (all pretty much required),
# index (optional, for string expansion)
# returns: array of rrdcreate parameters
sub optionsRRD
{
	my %args = @_;
	my $S = my $M = $args{sys};
	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index}; # optional

	confess("optionsRRD requires Sys argument!") if (ref($S) ne "NMISNG::Sys");

	$S->nmisng->log->debug2("type $type, index $index");

	my $mdlinfo = $S->mdl;
	# find out rrd step and heartbeat values, possibly use type-specific values (which the polling policy would supply)
	my $timinginfo = (ref($mdlinfo->{database}) eq "HASH"
										&& ref($mdlinfo->{database}->{db}) eq "HASH"
										&& ref($mdlinfo->{database}->{db}->{timing}) eq "HASH")?
										$mdlinfo->{database}->{db}->{timing}->{$type} // $mdlinfo->{database}->{db}->{timing}->{"default"}
	:  undef;
	$timinginfo //= { heartbeat => 900, poll => 300 };
	# note: heartbeat is overridable per DS by passing in 'heartbeat' in data!
	$S->nmisng->log->debug2("timing options for this file of type $type: step $timinginfo->{poll}, heartbeat $timinginfo->{heartbeat}");


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
			$S->nmisng->log->warn("Ignoring RRD DS name=$id: too long, more than 19 characters!") ;
			next;
		}

		my ($source,$range,$heartbeat);
		if ($data->{$id}{option})
		{
			if ($data->{$id}->{option} eq "nosave")
			{
				$S->nmisng->log->debug3("DS $id marked as nosave, ignoring.");
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

		$S->nmisng->log->debug2("ID of data is $id, source $source, range $range, heartbeat $heartbeat");
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
# returns: undef or error message
sub createRRD
{
	my %args = @_;

	my $S = $args{sys};
	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index};
	my $database = $args{database};

	&require_RRDs;
	my $C = $S->nmisng->config;

	$S->nmisng->log->debug("check and/or create RRD database $database");

	# are we allowed to create new files, or is the filesystem with the database dir (almost) full already?
	# marker file name also embedded in util.pm
	return "Not creating $database, as database filesystem is (almost) full!"
			if (-f "$C->{'<nmis_var>'}/nmis_system/dbdir_full");

	# Does the database exist already?
	if (-f $database)
	{
		# nothing to do!
		$S->nmisng->log->debug3("Database $database already exists");
		return undef;
	}

	# create new rrd file, maybe dir structure too
	my $dir = dirname($database);
	NMISNG::Util::createDir($dir) if (!-d $dir);

	my @options = optionsRRD(data=>$data, sys=>$S, type=>$type, index=>$index);
	if (!@options)
	{
		return "($S->{name}) unknown type=$type";
	}

	$S->nmisng->log->info("Creating new RRD database $database");
	$S->nmisng->log->debug("Options for creating $database: ".
												 Data::Dumper->new([\@options])->Terse(1)->Indent(0)->Pair(": ")->Dump);
	RRDs::create("$database",@options);
	my $ERROR = RRDs::error();
	if ($ERROR)
	{
		return "($S->{name}) failed to create $database: $ERROR";
	}
	# set file owner and permissions
	NMISNG::Util::setFileProtDiag(file =>$database);

	# Double check created OK for this user
	return undef if ( -f $database and -r $database and -w $database );

	return "($S->{name}) could not create RRD $database - check directory permissions?";
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

	my ($S, $nodename, $nodeuuid, $mygroup, $graphtype, $intf, $item,
			$width, $height, $filename, $start, $end, $time, $debug)
			= @args{qw(sys node uuid group graphtype intf item width height filename start end time debug)};

	&require_RRDs;
	if (ref($S) ne "NMISNG::Sys")
	{
		$S = NMISNG::Sys->new;
		$S->init(name => $nodename, uuid => $nodeuuid, snmp=>'false');
	}
	else
	{
		# non-node mode is a dirty hack
		$nodename = $S->nmisng_node->name if (ref($S->nmisng_node));
	}

	my $C = $S->nmisng->config;
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

		$S->nmisng->log->warn("no title->$titlekey found in Graph-$graphtype") if (!$title);
		$S->nmisng->log->warn("no vlabel->$vlabelkey found in Graph-$graphtype") if (!$label);

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

	my $nodename = $S->{name};

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
			$title = "$nodename $ifDescr $direction";
			$title .= " - $CBQosNames->[0]" if ($CBQosNames->[0] && $CBQosNames->[0] !~ /^(in|out)bound$/i);
			$title .= ' - $length';
			$vlabel = "Avg bps";
		}
		else
		{
			$title = "$nodename $ifDescr $direction - CBQoS from ".'$datestamp_start to $datestamp_end'; # fixme: why replace later??
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
				$S->nmisng->log->debug2("parent_name=$parent_name\n");
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
