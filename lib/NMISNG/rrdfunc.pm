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
our $VERSION = "2.4.0";

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
		my $config = $args{config};
		die "no config!" if (!$config);

		$RRD_included = 1;
		if ($config->{rrd_lib} ne '')
		{
			my $loc=$config->{rrd_lib};
			unshift @INC, $loc;

			# the "use lib" method works only at compile time,
			# and does a bit more: arch-specific dirs and version+arch specific
			# ones are added dynamically, too!
			if (-d "$loc/$Config{archname}/auto")
			{
					unshift @INC, "$loc/$Config{archname}";
			}
			for my $extras ("$loc/$Config{version}",
											"$loc/$Config{version}/$Config{archname}")
			{
					unshift @INC, $extras if (-d $extras);
			}
		}
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
# args: database (both required), optional: hours_from and hours_to (default: no restriction)
# this uses the Sys object to translate between graphtype and rrd section (Sys::getTypeName)
# returns: hash of time->dsname=value, list(ref) of dsnames (plus 'time', 'date'), and meta data hash
# metadata hash: actual begin and end as per rrd, and step
#
sub getRRDasHash
{
	my %args = @_;
	my $db = $args{database};
	die "getRRDasHash requires database argument!\n" if (!$db);
	require_RRDs(config => $args{config});

	my $minhr = (defined $args{hour_from}? $args{hour_from} : 0);
	my $maxhr = (defined $args{hour_to}? $args{hour_to} :  24) ;
	my $mustcheckhours = ($minhr != 0  and $maxhr != 24);
	my $invertperiod = $minhr > $maxhr;

	my ($begin,$step,$name,$data) = RRDs::fetch($db, $args{mode},"--start",$args{start},"--end",$args{end});
	my %s;
	my @h;
	my $date;
	my $d;
	my $time = $begin;
	# loop over the readings over time
	for(my $a = 0; $a <= $#{$data}; ++$a) {
		$d = 0;
		# loop over the datasets per individual reading
		for(my $b = 0; $b <= $#{$data->[$a]}; ++$b)
		{
			push(@h, $name->[$b]) if ($a == 0); # populate ds header names on first reading
			$s{$time}{$name->[$b]} = $data->[$a][$b];

			if ( defined $data->[$a][$b] ) { $d = 1; }
		}
		# compute date and time only if at least on ds col has defined data
		if ($d)
		{
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
				$s{$time}{time} = $time;
				# we DON'T want to rerun localtime() again, so no NMISNG::Util::returnDateStamp()
				# want 24-Mar-2014 11:22:33, regardless of LC_*, so %b isn't good.
				my $mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$timecomponents[4]];
				$s{$time}{date} = POSIX::strftime("%d-$mon-%Y %H:%M:%S", @timecomponents);
			}
			else
			{
				delete $s{$time};				# out of specified hours
			}
		}
		$time = $time + $step;
	}

	# two artificial ds header cols
	push(@h,"time","date");

	# actual data, the ds cols, and the meta data
	return (\%s, \@h, { step => $step, start => $begin, end => $time });
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
# arsg: sys, database, data (absolutely required), type/index/item (more or less required), extras (optional),
#
# the sys object is for the catch-22 issue of optionsRRD requiring knowledge from the model(s),
# plus there's the fixme: node-reset and nodeinfo reliance!
# fixme: the logic for node-reset and so on needs rework and likely needs doing elsewhere
#
# returns: the database file name or undef; sets the internal error indicator
sub updateRRD
{
	my %args = @_;
	require_RRDs(config => $args{config});

	my ($S,$data,$type,$index,$item,$database,$extras) =
			@args{"sys","data","type","index","item","database","extras"};

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

	my (@options, @ds);
	my @values = ("N");							# that's 'reading is for Now'

	# ro clone is good enough. fixme9: non-node mode is an ugly hack
	my $catchall = $S->{name}? $S->inventory( concept => 'catchall' )->data : {};
	NMISNG::Util::dbg("node was reset, inserting U values") if ($catchall->{node_was_reset});
	foreach my $var (keys %{$data})
	{
		# handle the nosave option
		if (exists($data->{$var}->{option}) && $data->{$var}->{option} eq "nosave")
		{
			NMISNG::Util::dbg("DS $var is marked as nosave, not saving to RRD", 3);
			next;
		}

		push @ds, $var;
		# if the node has gone through a reset, then insert a U to avoid spikes - but log once only
		if ($catchall->{node_was_reset})
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
	push @options,("-t", $theds, $thevalue);

	my $points = scalar @ds;
	# for bytes consider a 64 bit word, 8 bytes for each thing.
	#64-bits (8 bytes),
	my $bytes = $points * 8;

	$stats{datapoints} += $points;
	$stats{databytes} += $bytes;

	NMISNG::Util::dbg("DS $theds, $points");
	NMISNG::Util::dbg("value $thevalue, $bytes bytes");

	NMISNG::Util::logPolling("$type,$S->{name},$index,$item,$theds,$thevalue");

	if ( @options)
	{
		# update RRD
		RRDs::update($database,@options);
		++$stats{rrdcount};

		if (my $ERROR = RRDs::error())
		{
			if ($ERROR !~ /contains more DS|unknown DS name/)
			{
				$stats{error} = "($S->{name}) database=$database: $ERROR: options = @options";
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

### createRRD now checks if RRD exists and only creates if doesn't exist.
### also add node directory create for node directories, if rrd is not found
### note that the function does NOT create an rrd file if $main::selftest_dbdir_status is 0 (not undef)
# args: sys, data, database, type,  index - all required
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

	my $exit = 1;

	NMISNG::Util::dbg("Starting");
	NMISNG::Util::dbg("check and/or create RRD database $database");

	# Does the database exist already?
	if ( -f $database and -r $database and -w $database ) {
		# nothing to do!
		NMISNG::Util::dbg("Database $database exists and is R/W");
	}
	# Check if the RRD Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	elsif ( -f $database and not -w $database )
	{
		$stats{error} = "($S->{name}) database $database Exists but is readonly";
		NMISNG::Util::dbg("ERROR ($S->{name}) database $database Exists but is readonly");
		$exit = 0;
	}
	# are we allowed to create new files, or is the filesystem with the database dir (almost) full already?
	elsif (defined $main::selftest_dbdir_status && !$main::selftest_dbdir_status)
	{
		$stats{error} = "Not creating $database, as database filesystem is (almost) full!";
		NMISNG::Util::logMsg("ERROR: Not creating $database, as database filesystem is (almost) full!");
		return 0;
	}
	# create new rrd file, maybe dir structure too
	else
	{
		my $dir = dirname($database);
		NMISNG::Util::createDir($dir) if (!-d $dir);

		my @options = optionsRRD(data=>$data,sys=>$S,type=>$type,index=>$index);

		if ( @options ) {
			NMISNG::Util::logMsg("Creating new RRD database $database");

			NMISNG::Util::dbg("options to create database $database");
			foreach my $t (@options) {
				NMISNG::Util::dbg($t);
			}
			RRDs::create("$database",@options);
			my $ERROR = RRDs::error();
			if ($ERROR)
			{
				$stats{error} = "($S->{name}) unable to create $database: $ERROR";
				NMISNG::Util::logMsg("ERROR ($S->{name}) unable to create $database: $ERROR");
				$exit = 0;
			}
			# set file owner and permission, default: nmis, 0775.
			NMISNG::Util::setFileProtDiag(file =>$database);
			# Double check created OK for this user
			if ( -f $database and -r $database and -w $database )
			{
				NMISNG::Util::logMsg("INFO ($S->{name}) created RRD $database");
			}
			else
			{
				$stats{error} = "($S->{name}) could not create RRD $database - check directory permissions";
				NMISNG::Util::logMsg("ERROR ($S->{name}) could not create RRD $database - check directory permissions");
				$exit = 0;
			}
		}
		else
		{
			$stats{error} = "($S->{name}) unknown type=$type";
			NMISNG::Util::logMsg("ERROR ($S->{name}) unknown type=$type");
			$exit = 0;
		}
	}
	NMISNG::Util::dbg("Finished");
	return $exit;
} # end createRRD

1;
