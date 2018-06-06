#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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
# this module contains functions for managing
# maintenance windows aka 'outages'
#
package NMISNG::Outage;
our $VERSION = "9.0.0b";

use strict;
use UUID::Tiny (qw(:std));
use DateTime;
use List::Util 1.33;

use NMISNG::Util;

# outage data/argument structure:
#
# id (unique key, automatically generated on create, must be used
#  for update and delete)
# frequency ('once', 'daily', 'weekly', 'monthly')
# start, end (a date/date+time/partial format that's suitable for
#  the given frequency),
# change_id (required but free-form text, used to tag events),
# description (optional, free-form descriptive text),
# options (hash substructure that selects optional behaviours for this outage)
#  nostats (default undef, if set to 1 only 'U' values are written
#  to rrds during the outage)
# selector (hash substructure that defines what devices this outage covers)
#  two category keys, 'node' and 'config'
#  under these there can be any number of key => value filter expressions
#  all filter expressions must match for the selector to match
#
#  selector key X needs to be a CONFIG! property of the node if under node,
#   (plus nodeModel from the node info), or a global nmis property
#   if under config.
#
#  value: either array, or string or regex-string ('/.../' or '/.../i')
#  array: set of acceptable values; one or more must meet strict equality
#   test for the selector succeed
#  single string: strict equality
#  regex-string: identified property must match


# create new or update existing outage
# note that updates are absolute, not relative to existing outage!
# you must pass all desired arguments, not only ones you want changed
#
# args: id IFF updating,
# frequency/start/end/description/change_id/options/selector,
# meta (hash, optional, for audit logging, keys user and details.
#  if missing, user will
#  be set from os user of the current process)
# returns: hashref, keys success/error, id
sub update_outage
{
	my (%args) = @_;

	# validate the args first
	# lock and load existing outages,
	# create new one or update existing one,
	# save and unlock

	my $meta = ref($args{meta}) eq "HASH"? $args{meta} : {};
	$meta->{user} ||= (getpwuid($<))[0];

	my (%newrec, $op_create);
	my $outid = $args{id};

	if (!defined($outid) or $outid eq "") # 0 is ok, empty is not
	{
		$outid = 	create_uuid_as_string(UUID_RANDOM);
		$op_create = 1;
	}
	$newrec{id} = $outid;

	# copy simple args
	for my $copyable (qw(description change_id))
	{
		$newrec{$copyable} = $args{$copyable};
	}
	$newrec{options} = ref($args{options}) eq "HASH"? $args{options} : {}; # make sure it's a hash

	# check freq and freq vs start/end
	my $freq = $args{frequency};
	return { error => "invalid frequency \"$freq\"!" }
	if (!defined $freq or $freq !~ /^(once|daily|weekly|monthly)$/);
	$newrec{frequency} = $args{frequency};

	my %parsedtimes;
	for my $check (qw(start end))
	{
		my $doesitparse = $freq eq "once"?
				( ($args{$check} =~ /^\d+(\.\d+)?$/)?
					$args{$check} : ( NMISNG::Util::parseDateTime($args{$check})
														|| NMISNG::Util::getUnixTime($args{$check}) ))
				: _abs_time(relative => $args{$check}, frequency => $freq);

		return { error => "invalid $check argument \"$args{$check}\" for frequency $freq!" }
		if (!$doesitparse);

		$parsedtimes{$check} = $doesitparse;
		# for one-offs let's store the parsed value
		# as it could have been a relative input like "now + 2 days"...
		if ($freq eq "once")
		{
			$newrec{$check} = $doesitparse;
		}
		else
		{
			$newrec{$check} = $args{$check};
		}
	}
	return { error => "invalid times, start is later than end!" }
	if ($freq eq "once" && $parsedtimes{start} >= $parsedtimes{end});

	# quick/rough sanity check of selectors
	$newrec{selector} = {};
	if (ref($args{selector}) eq "HASH")
	{
		for my $cat (qw(node config))
		{
			my $catsel = $args{selector}->{$cat};
			next if (ref($catsel) ne "HASH");

			for my $onesel (keys %$catsel)
			{
				# one string, or an array of strings
				return { error => "invalid selector content for \"$cat.$onesel\"!" }
				if (ref($catsel->{$onesel}) and ref($catsel->{$onesel}) ne "ARRAY");

				if (ref($catsel->{$onesel}) eq "ARRAY")
				{
					# fix up any holes if item N was deleted but N+1... exist
					$newrec{selector}->{$cat}->{$onesel} = [ grep( defined($_), @{$catsel->{$onesel}}) ];
				}
				elsif (defined $catsel->{$onesel})
				{
					$newrec{selector}->{$cat}->{$onesel} = $catsel->{$onesel};
				}
				else
				{
					delete $newrec{selector}->{$cat}->{$onesel};
				}
			}
		}
	}
	# inputs look good, lock and load!

	# except that loadtable doesn't allow file creation on the fly, only readfiletohash
	# which is much lowerlevel wrt arguments  :-/
	if (!NMISNG::Util::existFile(dir => "conf", name => "Outages"))
	{
		NMISNG::Util::writeTable(dir => "conf", name => "Outages", data => {});
	}
	my ($data, $fh) = NMISNG::Util::loadTable(dir => "conf", name => "Outages", lock => 1);

	return { error => "failed to lock Outages file: $!" } if (!$fh);
	$data //= {};									# empty file is ok

	if ($op_create && ref($data->{$outid}))
	{
		close($fh);									# unlock
		return { error => "cannot create outage with id $outid: already existing!" };
	}
	$data->{$outid} = \%newrec;
	NMISNG::Util::writeTable(dir => "conf", name => "Outages", handle => $fh, data => $data);

	NMISNG::Util::audit_log(who => $meta->{user},
													what => ($op_create? "create_outage" : "update_outage"),
													where => $outid, how => "ok", details => $meta->{details}, when => undef);

	return { success => 1, id => $outid};
}

# take a relative/incomplete time and day specification and make into absolute timestamp
# args: relative (date + time, frequency-specific!),
# frequency (daily, weekly, monthly),
# base (optional, absolute base time; if not given now is used)
#
# the times are absolutified relative to now, so can be in the past or the future!
# returns: unix time if parseable, undef if not
sub _abs_time
{
	my (%args) = @_;

	my ($rel,$frequency) = @args{qw(relative frequency)};
	return undef if ($frequency !~ /^(once|daily|weekly|monthly)$/);

	my %wdlist = ("mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7);
	my $timezone = "local";
	my $dt = $args{base}? DateTime->from_epoch(epoch => $args{base}, time_zone => $timezone)
			: DateTime->now(time_zone => $timezone);

	if ($frequency eq "weekly")
	{
		# format: weekday hh:mm(:ss)?, weekday is shortname!
		# pull off and mangle the weekday first
		if ($rel =~ s/^\s*(\S+)\s+//)
		{
			my $wd = lc(substr($1,0,3));
			return undef if !$wdlist{$wd};

			# truncate to week begin, then add X-1 days (monday is day 1!, but DT-weekstart is monday too...)
			$dt = $dt->truncate(to => "week")->add("days" => $wdlist{$wd}-1);
		}
	}
	elsif ($frequency eq "monthly")
	{
		# format: DayNum hh:mm(:ss)? DayNum==1 means first day of the month, DayNum==-1 means LAST day of the month etc.
		if ($rel =~ s/^(-?\d+)\s+//)
		{
			my $monthday = $1;
			$dt = $dt->truncate(to => "month");
			if ($monthday <= 0)
			{
				$dt->add(months => 1)->subtract(days => -$monthday);
			}
			else
			{
				eval { $dt->set(day => $monthday); };
				return undef if $@;
			}
		}
	}

	if ($frequency eq "daily")
	{
		$dt = $dt->truncate(to => "day");
	}
	else
	{
		return undef if !$dt;
	}

	# all inputs must have a time component
	# format: hh:mm(:ss)?, with 00:00 meaning day before and 24:00 day after

	if ($rel =~ /^\s*(\d+):(\d+)(:(\d+))?\s*$/)
	{
		my ($h,$m,$s) = ($1,$2,$4);
		$s ||= 0;

		return $dt->add(days => 1)->epoch
				if ($h == 24 and $m == 0 and $s == 0); # handle 24:00:00

		eval { $dt->set_hour($h)->set_minute($m)->set_second($s) };
		return $@? undef: $dt->epoch;
	}
	else
	{
		return undef; # hh:mm(:ss)? is required
	}
}

# advances (or reduces) timestamp by X intervals, based on the given frequency
# args: timestamp, frquency, count (default: +1)
# returns new timestamp
sub _prev_next_interval
{
	my (%args) = @_;
	my ($ts, $freq, $count) = @args{qw(timestamp frequency count)};

	my %freq2delta = ("daily" => { days => 1}, "weekly" => {weeks => 1},
										"monthly" => { months => 1 });
	return $ts if (!$freq or !$freq2delta{$freq} or (defined $count and !$count));
	$count ||= 1;

	my $timezone = 	"local";
	my $dt = 	DateTime->from_epoch(epoch => $ts, time_zone => $timezone);
	my %delta = %{$freq2delta{$freq}};

	if ($count < 0)
	{
		$delta{(keys %delta)[0]} = -$count; # only one key
		return $dt->subtract(%delta)->epoch;
	}
	else
	{
		$delta{(keys %delta)[0]} = $count;
		return $dt->add(%delta)->epoch;
	}
}

# remove existing outage
# args: id, optional meta (for audit logging, keys user, details)
# returns: hashrev, keys success/error
sub remove_outage
{
	my (%args) = @_;
	my $id = $args{id};

	return { error => "cannot remove outage without id argument!" }
	if (!$id);

	my $meta = ref($args{meta}) eq "HASH"? $args{meta} : {};
	$meta->{user} ||= (getpwuid($<))[0];

	# lock and load the outages,
	# delete the indicated one,
	# save and unlock
	my ($data, $fh) = NMISNG::Util::loadTable(dir => "conf", name => "Outages", lock => "true");
	return { error => "failed to lock Outage file: $!" } if (!$fh);
	$data //= {};

	delete $data->{$id};
	NMISNG::Util::writeTable(dir => "conf", name => "Outages", handle => $fh, data => $data);

	NMISNG::Util::audit_log(who => $meta->{user},
													what => "remove_outage",
													where => $id,
													how => "ok",
													details => $meta->{details},
													when => undef);

	return { success => 1};
}

# find outages, all or filtered
# args: filter (optional, hashref of outage properties => check values)
# note: filters are verbatim/passive/inert, ie. checked against the
# raw outage schedule - NOT evaluated with any nodes' nodeinfo/models etc!
#
# filter properties: id, description, change_id, frequency/start/end,
# options.nostats, selector.node.X, selector.config.Y - must be given in dotted form!
# filter check values can be: qr// or plain string/number.
# for array selectors one or more elems must match for the filter to match.
#
# returns: hashref of success/error, outages (=array of matching outages)
sub find_outages
{
	my (%args) = @_;
	my $filter = ref($args{filter}) eq "HASH"? $args{filter} : {};

	my $data = NMISNG::Util::loadTable(dir => "conf", name => "Outages")
			if (NMISNG::Util::existFile(dir => "conf", name => "Outages")); # or we get lots of log noise
	$data //= {};

	# unfiltered?
	return { success => 1, outages => [ values %$data ] }
	if (!keys %$filter);

	my @matches;
 SCRATCHMONKEY:
	for my $candidate (values %$data)
	{
		for my $filterprop (keys %$filter)
		{
			my ($have, $diag) = NMISNG::Util::follow_dotted($candidate, $filterprop);
			next SCRATCHMONKEY if ($diag); # requested thing not present or wrong structure
			# none of the array elems match? (or the one and only thing doesn't?
			my @maybes = (ref($have) eq "ARRAY")? @$have: ($have);

			my $expected = $filter->{$filterprop};
			next SCRATCHMONKEY if ( List::Util::none { ref($expected) eq "Regexp"?
																										 ($_ =~ $expected) :
																										 ($_ eq $expected) } (@maybes) );
		}
		push @matches, $candidate;	# survived!
	}

	return { success => 1, outages => \@matches };
}


# removes past none-recurring outages after a configurable time
# args: nmisng object (required), simulate (optional, default false)
# returns: hashref, keys success/error and info (array ref)
sub purge_outages
{
	my (%args) = @_;
	my $nmisng = $args{nmisng};
	my $simulate = NMISNG::Util::getbool( $args{simulate} );

	return { error => "cannot purge outages without nmisng argument!" }
	if (ref($nmisng) ne "NMISNG");
	my $maxage = $nmisng->config->{purge_outages_after} // 86400;

	return { success => 1, message => "Outage expiration is disabled." }
	if ($maxage <= 0); # 0 or negative? no purging

	my $data = NMISNG::Util::loadTable(dir => "conf", name => "Outages")
			if (NMISNG::Util::existFile(dir => "conf", name => "Outages")); # or we get lots of log noise
	return { success => 1, message => "No outages exist." } if !$data;

	my (@problems, @info);
	for my $outid (keys %$data)
	{
		my $thisoutage = $data->{$outid};
		next if ($thisoutage->{frequency} ne "once"
						 or $thisoutage->{end} >= time - $maxage);

		push @info, ( $simulate? "Would purge ":"Purging ")
				. "expired outage $outid, description \"$thisoutage->{description}\", ended at "
				. scalar(localtime($thisoutage->{end}));

		next if ($simulate);
		my $res = remove_outage(id => $outid, meta => {details => "purging expired past outage" });
		push @problems, "$outid: $res->{error}" if (!$res->{success}); # but let's continue
	}

	return {
		info => \@info,
		error => join("\n", @problems),
		success => @problems? 0 : 1 };
}

# find active/future/past outages for a given context,
# ie. one node and a time - or potential outages, if only
# given time.
#
# args: time (a unix timestamp, fractional is ok, required),
#  node (object) or nmisng (object), one of the two is required
#
# returns: hashref, with keys success/error, past, current, future: arrays (can be empty)
#
# current: outages that fully apply - these are amended with actual_start/actual_end unix TS,
#  and sorted by actual_start.
# past: past one-off (not recurring ones!) outages for this node
# future: future outages for this node, also with actual_start/actual_end (of the next instance),
#  sorted by actual_start.
sub check_outages
{
	my (%args) = @_;
	my ($when,$node,$nmisng) = @args{"time","node","nmisng"};

	return { error => "cannot check outages without valid time argument!" }
	if (!$when or $when !~ /^\d+(\.d+)?$/);

	return { error => "cannot check outages without valid node or nmisng argument!" }
	if (ref($node) ne "NMISNG::Node" && ref($nmisng) ne "NMISNG");

	my $outagedata = NMISNG::Util::loadTable(dir => "conf", name => "Outages")
			if (NMISNG::Util::existFile(dir => "conf", name => "Outages"));
	$outagedata //= {};
	# no outages, no problem
	return { success => 1, future => [], past => [], current => [] }
	if (!keys %$outagedata);

	# get the data for selectors: node object links to nmisng, has global config;
	# node object has own config, and catchall inventory has the nodeModel.
	my $globalconfig = $nmisng? $nmisng->config : $node->nmisng->config;
	my ($nodeconfig, $nodemodel);

	if ($node)
	{
		$nodeconfig = $node->configuration;
		my ($catchall,$error) = $node->inventory(concept => "catchall");
		$nodemodel = $catchall->data->{nodeModel} if (!$error
																									&& ref($catchall) =~ /^NMISNG::Inventory::/
																									&& ref($catchall->data) eq "HASH");
	}

	my (@future,@past,@current);
	for my $outid (keys %$outagedata)
	{
		my $maybeout = $outagedata->{$outid};

		# let's check all selectors for this node - if there is a context node
		if ($node)
		{
			my $rulematches = 1;
			for my $selcat (qw(config node))
			{
				next if (ref($maybeout->{selector}->{$selcat}) ne "HASH");

				for my $propname (keys %{$maybeout->{selector}->{$selcat}})
				{
					my $actual = ($selcat eq "config"?
												$globalconfig->{$propname} :
												$propname eq "nodeModel"? $nodemodel
												# uuid, cluster_id, name, activated.NMIS, overrides live OUTSIDE of configuration!
												: $propname =~ /^(uuid|cluster_id|name)$/?
												$node->$propname
												: $nodeconfig->{$propname});
					# choices can be: regex, or fixed string, or array of fixed strings
					my $expected = $maybeout->{selector}->{$selcat}->{$propname};

					# list of precise matches
					if (ref($expected) eq "ARRAY")
					{
						$rulematches = 0 if (! List::Util::any { $actual eq $_ } @$expected);
					}
					# or a regex-like string
					elsif ($expected =~ m!^/(.*)/(i)?$!)
					{
						my ($re,$options) = ($1,$2);
						my $regex = ($options? qr{$re}i : qr{$re});
						$rulematches = 0 if ($actual !~ $regex);
					}
					# or a single precise match
					else
					{
						$rulematches = 0 if ($actual ne $expected);
					}
					last if (!$rulematches);
				}
				last if (!$rulematches);
			}
			# didn't survive all selector rules? note that no selectors === match
			next if (!$rulematches);
		}

		# how about the time?
		my $intime;
		if ($maybeout->{frequency} eq "once")
		{
			if ($when < $maybeout->{start})
			{
				push @future, { %$maybeout,
												actual_start => $maybeout->{start},
												actual_end => $maybeout->{end} }; # convenience only
			}
			elsif ($when >= $maybeout->{start} && $when <= $maybeout->{end})
			{
				push @current, { %$maybeout,
												 actual_start => $maybeout->{start},
												 actual_end => $maybeout->{end} }; # convenience only
				$intime = 1;
			}
			else # ie. > $maybeout->{end}
			{
				push @past, $maybeout;
			}
		}
		elsif ($maybeout->{frequency} =~ /^(daily|weekly|monthly)$/)
		{
			# absolute time is going to be 'near' when, but that's not quite good enough
			my $start = _abs_time(relative => $maybeout->{start},
														frequency => $maybeout->{frequency},
														base => $when);
			return { error => "outage \"$outid\" has invalid start \"$maybeout->{start}\"!" }
			if (!defined $start);

			my $end = _abs_time(relative => $maybeout->{end},
													frequency => $maybeout->{frequency},
													base => $when);
			return { error => "outage \"$outid\" has invalid end \"$maybeout->{end}\"!" }
			if (!defined $end);

			# start after end? (e.g. daily, start 1400, end 0200) -> start must go back one interval
			# (or end would have to go forward one)
			$start = _prev_next_interval(timestamp => $start, frequency => $maybeout->{frequency},
																	 count => -1) if ($start > $end);

			# advance or retreat until closest to when
			if ($when < $start && $when < $end) # retreat
			{
				while ($when < $start && $when < $end)
				{
					$start = _prev_next_interval(timestamp => $start,
																			 frequency => $maybeout->{frequency}, count => -1);
					$end = _prev_next_interval(timestamp => $end,
																		 frequency => $maybeout->{frequency}, count => -1);
				}
			}
			elsif ($when > $start && $when > $end) # advance
			{
				while ($when > $start && $when > $end)
				{
					$start = _prev_next_interval(timestamp => $start,
																			 frequency => $maybeout->{frequency}, count => 1);
					$end = _prev_next_interval(timestamp => $end,
																		 frequency => $maybeout->{frequency}, count => 1);
				}
			}

			# before both start and end is obviously future
			if ($when < $start)
			{
				push @future, { %$maybeout, actual_start => $start, actual_end => $end };
			}
			# but *after* both start and end is also future, just plus one or more repeat intervals
			elsif ($when > $end)
			{
				push @future, { %$maybeout,
												actual_start => _prev_next_interval(timestamp => $start,
																														frequency => $maybeout->{frequency},
																														count => 1),
												actual_end => _prev_next_interval(timestamp => $end,
																													frequency => $maybeout->{frequency},
																													count => 1),
				};
			}
			# and current is inbetween
			elsif ($when >= $start && $when <= $end)
			{
				push @current, { %$maybeout, actual_start => $start, actual_end => $end };
				$intime = 1;
			}
		}
		else
		{
			return { error => "outage \"$outid\" has invalid frequency!" };
		}

		next if (!$intime);
	}

	# sort current and future list by the actual start time
	@current = sort { $a->{actual_start} <=> $b->{actual_start} } @current;
	@future = sort { $a->{actual_start} <=> $b->{actual_start} } @future;

	return { success => 1,  past => \@past, current => \@current, future => \@future };
}


# a compat wrapper around check_outages
# checks outage(s) for one node X and all nodes that X depends on
#
#
# fixme: why check dependency nodes at all? why only if those are down?
# and only if no direct future outages?
#
# args: node (node object!), time (unix ts), both required
# returns: nothing or ('current', FIRST current outage record)
# or ('pending', FIRST future outage)
#
sub outageCheck
{
	my %args = @_;

	my $node = $args{node};
	my $time = $args{time};

	if (ref($node) ne "NMISNG::Node")
	{
		NMISNG::Util::logMsg("ERROR invalid node argument!");
		return;
	}
	my $nmisng = $node->nmisng;
	my $nodename = $node->name;

	my $nodeoutages = check_outages(node => $node, time => $time);
	if (!$nodeoutages->{success})
	{
		$nmisng->log->error("failed to check $nodename outages: $nodeoutages->{error}");
		return;
	}

	if (@{$nodeoutages->{current}})
	{
		return ("current", $nodeoutages->{current}->[0]);
	}
	elsif (@{$nodeoutages->{future}})
	{
		return ("pending", $nodeoutages->{future}->[0]);
	}

	# if neither current nor future, check dependency nodes with
	# current outages and that are down
	foreach my $nd ( split(/,/,$node->configuration->{depend}) )
	{
		# ignore nonexistent stuff, defaults and circular self-dependencies
		next if ($nd =~ m!^(N/A|$nodename)?$!);
		my $depnode = $nmisng->node(name => $nd);
		my $depoutages = check_outages(node => $depnode, time => $time);
		if (!$depoutages->{success})
		{
			$nmisng->log->error("failed to check $nd outages: $depoutages->{error}");
			return;
		}
		if (@{$depoutages->{current}})
		{
			# check if this node is down
			my ($catchall_inv, $error) = $depnode->inventory(concept => "catchall");
			if ($error)
			{
				$nmisng->log->error("failed to load inventory for $nd: $error");
				return;
			}
			my $catchall_data = $catchall_inv? $catchall_inv->data : {};

			if (getbool($catchall_data->{nodedown}))
			{
				return ("current", $depoutages->{current}->[0]);
			}
		}
	}
	return;
}


1;
