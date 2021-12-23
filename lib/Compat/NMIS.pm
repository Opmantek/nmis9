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
package Compat::NMIS;
use strict;

our $VERSION = "9.3.0a";

use Time::ParseDate;
use Time::Local;
use Net::hostent;
use Socket;
use URI::Escape;
use JSON::XS 2.01;
use File::Basename;
use feature 'state';						# for new_nmisng
use Carp;
use CGI qw();												# very ugly but createhrbuttons needs it :(
use Digest::MD5;										# for htmlGraph, nothing stronger is needed

use Fcntl qw(:DEFAULT :flock);  # Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Data::Dumper;
use List::Util '1.33';

use Compat::IP;
use NMISNG::CSV;
use NMISNG;
use NMISNG::Sys;
use NMISNG::rrdfunc;
use NMISNG::Notify;
use NMISNG::Outage;

# this is a compatibility helper to quickly gain access
# to ONE persistent/shared nmisng object
#
# args: nocache (optional, if set creates new nmisng object),
#  config (optional, if present must be live config structure),
#  log (optional, if present must be nmisng::logger instance),
#  debug (optional, ignored if log argument given!
#   if debug is present, it overrules the configuration AND causes
#   logging to go to stderr, not the logfile)
#
# allow for instantiating a test collection in our $db for running tests
# in a hashkey named 'tests' passed as arg to Compat::NMIS::new_nmisng()
# by appending "_test_collection" to the subkey representing the NMISNG collection we want to test,
#   for example:
#	  my $nmisng_args->{tests}{events_test_collection} = "events_test";
#	  Compat::NMIS::new_nmisng(%$nmisng_args);
#
# returns: ref to one persistent nmisng object
sub new_nmisng
{
	my (%args) = @_;
	state ($_nmisng, $pending);

	# attention: some functions called here may indirectly call this function recursively, must guard against that!
	return undef if ($pending);

	if (ref($_nmisng) ne "NMISNG" or $args{nocache})
	{
		$pending = 1;

		# config: given or in need of loading?
		my $C = ref($args{config}) eq "HASH"? $args{config} : NMISNG::Util::loadConfTable();
		Carp::config("Config required but missing") if (ref($C) ne "HASH"  or !keys %$C);

		# logger given? then use that, otherwise prime one from config and debug args
		my $logger = $args{log};
		if (ref($logger) ne "NMISNG::Log")
		{
			# log level is controlled by debug (from commandline or config file),
			# output is stderr if debug came from command line, log file otherwise
			my $logfile = $C->{'<nmis_logs>'} . "/nmis.log";
			my $error = NMISNG::Util::setFileProtDiag(file => $logfile)
					if (-f $logfile);
			warn "failed to set $logfile permissions: $error\n" if ($error); # fixme bad output channel

			$logger = NMISNG::Log->new(
				level => ( NMISNG::Log::parse_debug_level( debug => $args{debug}) // $C->{log_level} ),
				path  =>  ($args{debug}? undef : $logfile ),
					);
		}
		# allow for instantiating a test collection in our $db for running tests
		# in a hashkey named 'tests' passed as arg to Compat::NMIS::new_nmisng()
		# by appending "_test_collection" to the subkey representing the NMISNG collection we want to test,
		#   for example:
		#	  my $nmisng_args->{tests}{events_test_collection} = "events_test";
		#	  Compat::NMIS::new_nmisng(%$nmisng_args);
		$_nmisng = NMISNG->new(config => $C, log => $logger, tests => $args{tests});

		undef $pending;
	}
	return $_nmisng;
}

# load local nodes (only!)
# args: none
# returns: hash of node name -> node record, FLATTENED!
# deprecated - cannot deal with name clashes, doesn't support cluster_id and discards structural information!
sub loadLocalNodeTable
{
	my $nmisng = new_nmisng();

	# ask the database for all of my nodes, ie. with my cluster id
	my $modelData = $nmisng->get_nodes_model( filter => { cluster_id => $nmisng->config->{cluster_id} } );
	my $data = $modelData->data();

	my %map = map { ($_->{name} => $_) } @$data;
	for my $flattenme (values %map)
	{
		for my $confprop (keys %{$flattenme->{configuration}})
		{
			$flattenme->{$confprop} = $flattenme->{configuration}->{$confprop};
		}
		delete $flattenme->{configuration};
		$flattenme->{active} = $flattenme->{activated}->{NMIS};
		delete $flattenme->{activated};

		# untranslate override keys
		for my $uglykey (keys %{$flattenme->{overrides}})
		{
			# must handle compat/legacy load before correct structure in db
			if ($uglykey =~ /^==([A-Za-z0-9+\/=]+)$/)
			{
				my $nicekey = Mojo::Util::b64_decode($1);
				$flattenme->{overrides}->{$nicekey} = $flattenme->{overrides}->{$uglykey};
				delete $flattenme->{overrides}->{$uglykey};
			}
		}
	}

	return \%map;
}

# load all nodes, local and foreign
# args: none
# returns: hash of node name -> node record, FLATTENED!
# deprecated - cannot deal with name clashes, doesn't support cluster_id and discards structural information!
sub loadNodeTable
{
	my $nmisng = new_nmisng();

	# ask the database for all noes, my cluster id and all others
	my $modelData = $nmisng->get_nodes_model();
	my $data = $modelData->data();

	my %map = map { $_->{name} => $_ } @$data;
	for my $flattenme (values %map)
	{
		for my $confprop (keys %{$flattenme->{configuration}})
		{
			$flattenme->{$confprop} = $flattenme->{configuration}->{$confprop};
		}
		delete $flattenme->{configuration};
		$flattenme->{active} = $flattenme->{activated}->{NMIS};
		delete $flattenme->{activated};

		# untranslate override keys
		for my $uglykey (keys %{$flattenme->{overrides}})
		{
			# must handle compat/legacy load before correct structure in db
			if ($uglykey =~ /^==([A-Za-z0-9+\/=]+)$/)
			{
				my $nicekey = Mojo::Util::b64_decode($1);
				$flattenme->{overrides}->{$nicekey} = $flattenme->{overrides}->{$uglykey};
				delete $flattenme->{overrides}->{$uglykey};
			}
		}
	}
	return \%map;
}

# check if a table-ish file exists in conf (or conf-default)
# args: file name, relative, may be short w/o extension
# returns: 1 if file exists, 0 otherwise
sub tableExists
{
	my $table = shift;
	my $C = shift;

	return (NMISNG::Util::existFile(dir=>"conf",
																	name=>$table, conf => $C)
					|| NMISNG::Util::existFile(dir=>"conf_default",
																		 name=>$table, conf => $C))? 1 : 0;
}

# load a table from conf (or conf-default)
# args: file name, relative, may be short w/o extension
# returns: hash ref of data
sub loadGenericTable
{
	my ($tablename) = shift;
	my $C = shift;
	
	return NMISNG::Util::loadTable(dir => "conf", name => $tablename, conf => $C );
}


sub loadWindowStateTable
{
	my $C = NMISNG::Util::loadConfTable();

	return {} if (not NMISNG::Util::existFile(dir => 'var',
																						name => "nmis-windowstate"));
	return NMISNG::Util::loadTable(dir=>'var',name=>'nmis-windowstate');
}


# this small helper takes an optional section and a require config item name,
# and returns the structure info for that item from loadCfgTable
# returns: hashref (keys display, value etc.) or undef if not found
sub findCfgEntry
{
	my (%args) = @_;
	my ($section,$item) = @args{qw(section item)};

	my $meta = loadCfgTable();
	for my $maybesection (defined $section? ($section) : keys %$meta)
	{
		for my $entry (@{$meta->{$maybesection}})
		{
			if ($entry->{$item})
			{
				return $entry->{$item};
			}
		}
	}
	return undef;
}

# this loads a Table-<sometable> config structure (for the gui)
# and returns the <sometable> substructure - outermost is always hash,
# substructure is usually an array (except for Table-Config, which is one level deeper)
#
# args: table name (e.g. Nodes), defaults to "Config",
# user (optional, if given will be set in %ENV for any dynamic tables that need it)
#
# returns: (array or hash)ref or error message
sub loadCfgTable
{
	my %args = @_;

	my $tablename = $args{table} || "Config";

	# some tables contain complex code, call auth methods  etc,
	# and need to know who the originator is
	my $oldcontext = $ENV{"NMIS_USER"};
	if (my $usercontext = $args{user})
	{
		$ENV{"NMIS_USER"} = $usercontext;
	}
	my $goodies = loadGenericTable("Table-$tablename");
	$ENV{"NMIS_USER"} = $oldcontext; # let's not leave a mess behind.

	if (ref($goodies) ne "HASH" or !keys %$goodies)
	{
		return "loadCfgTable failed to load Table-$tablename";
	}
	return $goodies->{$tablename};
}

# fixme9: cannot work that way anymore
sub loadServersTable
{
	#return {};
	return NMISNG::Util::loadTable(dir=>'conf',name=>'Servers');
}

# compat function that basically just parrots nodes' catchall information
# args: none
# returns: hashref (may be empty)
# fixme9: argument master is currently not supported - no master/remote mode in nmis9 yet.
sub loadNodeSummary
{
	my (%args) = @_;
	# fixme9 gone my $master = $args{master};

	my $nmisng = new_nmisng();
	my $lotsanodes = $nmisng->get_nodes_model()->objects;
	if (my $err = $lotsanodes->{error})
	{
		$nmisng->log->error("failed to retrieve nodes: $err");
		return {};
	}

	# hash of node name -> catchall data, until fixme9: OMK-5972 less stuff gets dumped into catchall
	# also fixme9: will fail utterly with multipolling, node names are not unique, should use node_uuid
	my %summary;
	for my $onenode (@{$lotsanodes->{objects}})
	{
		# detour via sys for possibly cached catchall inventory
		my $S = NMISNG::Sys->new;
		$S->init(node => $onenode, snmp => 'false', wmi => 'false');
		my $catchall_data = $S->inventory( concept => 'catchall' )->data();
		$summary{$onenode->name} = $catchall_data;
	}
	return \%summary;
}

sub loadLocalNodeSummary
{
	my (%args) = @_;
	# fixme9 gone my $master = $args{master};

	my $nmisng = new_nmisng();
	my $lotsanodes = $nmisng->get_nodes_model(filter => { cluster_id => $nmisng->config->{cluster_id} })->objects;
	if (my $err = $lotsanodes->{error})
	{
		$nmisng->log->error("failed to retrieve nodes: $err");
		return {};
	}

	# hash of node name -> catchall data, until fixme9: OMK-5972 less stuff gets dumped into catchall
	# also fixme9: will fail utterly with multipolling, node names are not unique, should use node_uuid
	my %summary;
	for my $onenode (@{$lotsanodes->{objects}})
	{
		# detour via sys for possibly cached catchall inventory
		my $S = NMISNG::Sys->new;
		$S->init(node => $onenode, snmp => 'false', wmi => 'false');
		my $catchall_data = $S->inventory( concept => 'catchall' )->data();
		$summary{$onenode->name} = $catchall_data;
	}
	return \%summary;
}

# returns undef or error message
sub logConfigEvent
{
	my %args = @_;
	my $dir = $args{dir};
	delete $args{dir};
	my $nmisng = $args{nmisng};
	delete $args{nmisng};

	$nmisng->log->debug2("logConfigEvent logging Json event for event $args{event}");
	my $event_hash = \%args;
	$event_hash->{startdate} = time;
	my $error = NMISNG::Notify::logJsonEvent(event => $event_hash, dir => $dir);

	return $error;								# or undef
}

# returns hashref or error message
sub getSummaryStats
{
	my %args = @_;
	my $type = $args{type};
	my $index = $args{index}; # optional
	my $item = $args{item};
	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $M  = $S->mdl;

	my $C = NMISNG::Util::loadConfTable();
	&NMISNG::rrdfunc::require_RRDs;

	my $db;
	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats;

	$S->nmisng->log->debug2(&NMISNG::Log::trace()."Start type=$type, index=$index, start=$start, end=$end");

	# check if type exist in nodeInfo
	# fixme this cannot work - must CHECK existence, not make path blindly
	if (!($db = $S->makeRRDname(graphtype=>$type, index=>$index, item=>$item)))
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		#$S->nmisng->log->warn("($S->{name}) no rrd name found for type $type, index $index, item $item");
		return {};
	}

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$type} eq "")
	{
		$S->nmisng->log->warn("($S->{name}) type=$type not found in section stats of model=$M->{system}->{nodeModel}");
		return {};
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the precise_status as workaround
		# to figure out if the right source is enabled
		my %status = $S->nmisng_node->precise_status;
		# fixme unclear how to find the model's rrd section for this thing?
		$S->nmisng->log->warn("($S->{name}) database=$db does not exist, snmp is "
													.($status{snmp_enabled}?"enabled":"disabled").", wmi is "
													.($status{wmi_enabled}?"enabled":"disabled") );
		return {};
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	#if( $index )
	{
		no strict;									# this is extremely bad stuff.
		$database = $db; # global
		#inventory keyed by index and ifDescr so we need partial
		my $intf_inventory = $S->inventory( concept => "interface", index => $index, partial => 1, nolog => 1);
		if( $intf_inventory )
		{
			my $data = $intf_inventory->data();
			$speed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeed} if $index ne "";
			$outSpeed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeedIn} if $index ne "" and $data->{ifSpeedIn};
			$outSpeed = $data->{ifSpeedOut} if $index ne "" and $data->{ifSpeedOut};
		}
		# read from Model and translate variable ($database etc.) rrd options
		# escape colons in ALL inputs, not just database, but only if not already escaped
		foreach my $str (@{$M->{stats}{type}{$type}}) {
			my $s = $str;
			$s =~ s{\$(\w+)}{if(defined${$1}){postcolonial(${$1});}else{"ERROR, no variable \$$1 ";}}egx;
			if ($s =~ /ERROR/)
			{
				return ("($S->{name}) failed to expand '$str' model=$M->{system}->{nodeModel} type=$type: $s");
			}
			push @option, $s;
		}
	}

	$S->nmisng->log->debug3("RRD Options: ".join(" ",@option));

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error()))
	{
		return ("getSummaryStats failed: ($S->{name}) RRD graph error database=$db: $ERROR");
	}

	if (!scalar(@$graphret) )
	{
		$S->nmisng->log->warn("($S->{name}) no info return from RRD for type=$type index=$index item=$item");
		return {};
	}

	# fixme9: this should NOT return nan, but undef - upstreams should check for undef, not string NaN;
	# fixme9: must also numify the values
	# fixme9:  see getsubconceptstats for implementation
	map { s/nan/NaN/g } @$graphret;			# make sure a NaN is returned !!
	foreach my $line ( @$graphret ) {
		my ($name,$value) = split "=", $line;
		if ($index ne "") {
			$summaryStats{$index}{$name} = $value; # use $index as primairy key
		} else {
			$summaryStats{$name} = $value;
		}
		$S->nmisng->log->debug2("getsummarystats name=$name, index=$index, value=$value");
	}
	return \%summaryStats;
}


# whatever it is that goes into rrdgraph arguments, colons are Not Good
sub postcolonial
{
	my ($unsafe) = @_;
	# but escaping already escaped colons isn't that much better
	$unsafe =~ s/(?<!\\):/\\:/g;
	return $unsafe;
}

# compute stats via rrd for a given subconcept,
# args: inventory,subconcept,start,end,sys, all required
#   subconcept is used to find the storage (db) and also the section in the stats
#   file.
#  stats_section - if provided this will be used to look up the location of the stats
#   instead of subconcept. this is required for concepts like cbqos where the subconcept
#   name is variable and based on class names which come from the device
#
# returns: hashref with numeric values (may be undef if infty or nan), or error message
# note: this does NOT return the string NaN, because json::xs utterly misencodes that
sub getSubconceptStats
{
	my %args = @_;
	my $inventory = $args{inventory};
	my $subconcept = $args{subconcept};
	my $stats_section = $args{stats_section} // $args{subconcept};

	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $M  = $S->mdl;

	my $C = $args{conf} // NMISNG::Util::loadConfTable();
	&NMISNG::rrdfunc::require_RRDs;

	my $db = $inventory->find_subconcept_type_storage( subconcept => $subconcept, type => 'rrd' );
	my $data = $inventory->data;
	my $index = $data->{index};

	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats; # return value

	$S->nmisng->log->debug2(&NMISNG::Log::trace()."Start subconcept=$subconcept, index=$index, start=$start, end=$end");

	# check if storage exists
	if (!$db)
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		$S->nmisng->log->warn("($S->{name}) no rrd name found for subconcept $subconcept, index $index");
		return {};
	}
	$db = $C->{database_root}.$db;

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$stats_section} eq "")
	{
		$S->nmisng->log->debug("($S->{name}) subconcept=$subconcept not found in section stats of model=$M->{system}->{nodeModel}, this may be expected");
		return {};
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the precise_status as workaround
		# to figure out if the right source is enabled
		my %status = $S->nmisng_node->precise_status;
		# fixme unclear how to find the model's rrd section for this thing?

		$S->nmisng->log->warn("($S->{name}) database=$db does not exist, snmp is "
												 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
												 .($status{wmi_enabled}?"enabled":"disabled") );
		return {};
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	# fixme9: is there any reason we don't use parse string or some other generic function here?
	{
		no strict;
		$database = $db; # global

		if( $inventory->concept eq 'interface' )
		{
			my $data = $inventory->data();
			$speed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeed} if $index ne "";
			$outSpeed = $data->{ifSpeed} if $index ne "";
			$inSpeed = $data->{ifSpeedIn} if $index ne "" and $data->{ifSpeedIn};
			$outSpeed = $data->{ifSpeedOut} if $index ne "" and $data->{ifSpeedOut};
		}
		# read from Model and translate variable ($database etc.) rrd options
		# escape colons in ALL inputs, not just database but only if not already escaped
		foreach my $str (@{$M->{stats}{type}{$stats_section}}) {
			my $s = $str;
			$s =~ s{\$(\w+)}{if(defined${$1}){postcolonial(${$1});}else{"ERROR, no variable \$$1 ";}}egx;
			if ($s =~ /ERROR/)
			{
				return ("($S->{name}) getSubconceptStats failed to expand '$str' in model=$M->{system}->{nodeModel} subconcept=$subconcept: $s");
			}
			push @option, $s;
		}
	}

	# now try to work around OMK-6232, common-stats being NOT common
	# but instead containing lots of unavailable things for most platforms
	my $wehavethese = $inventory->dataset_info(subconcept => $subconcept);
	my (@needs, @finalopts, %have);
	for my $i (0..$#option)
	{
		my $rrdarg = $option[$i];
		# DEF:avgBusy1=$database:avgBusy1:AVERAGE
		if ($rrdarg =~ /^DEF:([^=]+)=[^:]+:([a-zA-Z0-9_-]+):/)
		{
			my ($varname, $dsname) = ($1, $2);
			$needs[$i]->{ds} = $dsname;
			$needs[$i]->{defines} = $varname;
		}
		# CDEF:perPUsedMem=MemPUsed,totalPMem,/,100,*
		elsif ($rrdarg =~ /^CDEF:([^=]+)=(.+)$/)
		{
			my ($varname,$expressions) = ($1,$2);
			for my $rpnexp (split(/,/,$expressions))
			{
				next if ($rpnexp !~ /^[a-zA-Z_-][a-zA-Z0-9_-]*$/); # not variables and not pure numbers
				$needs[$i]->{var}->{$rpnexp} = 1;
				$needs[$i]->{defines} = $varname;
			}
		}
		# PRINT:hrDiskUsed:AVERAGE:hrDiskUsed
		elsif ($rrdarg =~ /^PRINT:([^:]+):/)
		{
			$needs[$i]->{var}->{$1} = 1;
		}
	}
	# find unsatisfiable DEFs from the list
	my %nocando;
	for my $i (0..$#needs)
	{
		my $needs_ds = $needs[$i];

		next if (!$needs_ds);
		if ($needs_ds->{ds} && !$wehavethese->{$needs_ds->{ds}})
		{
			$nocando{ $needs_ds->{defines}} = 1;
			$needs[$i]->{skip} = 1;
			$S->nmisng->log->debug2("skipping variable definition $needs_ds->{defines}: requires DS $needs_ds->{ds} but we
only have DS ".join(" ",keys(%$wehavethese)));

			# and find all variable definitions that involve this one; they're just as unsatisfiable
			for my $other (0..$#needs)
			{
				my $needs_var = $needs[$other];
				next if (!$needs_var or !$needs_var->{var} or $needs_var->{skip});
				if ($needs_var->{var}->{ $needs_ds->{defines} })
				{
					if ($needs_var->{defines})
					{
						$nocando{$needs_var->{defines}} = 1;
						$needs[$other]->{skip} = 1;
						$S->nmisng->log->debug2("skipping variable definition $needs_var->{defines}: requires variable $needs_ds->{defines} which is unsatisfiable");
					}
					else
					{
						$needs[$other]->{skip} = 1;
						$S->nmisng->log->debug2("skipping print of unsatisfiable variable $needs_ds->{defines}");
					}
				}
			}
		}
	}
	if (%nocando)
	{
		# now remove the CDEFs that depend on unsatisfiable CDEFs
		# note: this is NOT perfect, it only covers on level of indirectionl; repeated looping would be required to
		# fully catch any depth CDEF interdependencies
		for my $i (0..$#needs)
		{
			my $needs_var = $needs[$i];

			next if (!$needs_var || $needs_var->{skip});
			if ($needs_var->{var} && List::Util::any { $nocando{$_} } (keys %{$needs_var->{var}}))
			{
				$nocando{ $needs_var->{defines} } = 1;
				$needs[$i]->{skip} = 1;
				$S->nmisng->log->debug2("variable definition $needs_var->{defines} is unsatisfiable: requires variables ".join(" ", keys %{$needs_var->{var}}).", some of which are unsatisfiable.");
			}
		}
	}
	if (%nocando)
	{
		for my $line (0..$#option)
		{
			if (!$needs[$line] 		# references no vars or ds
					or !$needs[$line]->{skip}) # or only ones that we know to have
			{
				push @finalopts, $option[$line];
			}
			# directly or indirectly depends on DS that we DON'T have
			else
			{
				my $whatitneeds = ($needs[$line]->{ds}? "DS $needs[$line]->{ds}"
													 : $needs[$line]->{var}? ("Variables ".join(" ",keys %{$needs[$line]->{var}}))
													 : "unclear" );
				# tag it as warning but log it only if we're at debug 2 or higher
				$S->nmisng->log->warn("skipping unsatisfiable stats option \"$option[$line]\"")
						if $S->nmisng->log->is_level(2);
			}
		}
	}
	else
	{
		@finalopts = @option;
	}

	# no satisfiable rrd accesses left? log and bail out early
	if (!List::Util::any { $_ =~ /^DEF:/ } (@finalopts))
	{
		$S->nmisng->log->warn("No satisfiable stats options for $S->{name}, concept ".$inventory->concept.", subconcept $subconcept!");
		return {};
	}

	$S->nmisng->log->debug3("RRD options: ".join(" ",@finalopts));

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @finalopts);
	if (($ERROR = RRDs::error()))
	{
		return ("($S->{name}) getSubconceptStats: RRD graph error database=$db: $ERROR");
	}

	if (!scalar(@$graphret) )
	{
		$S->nmisng->log->warn("INFO ($S->{name}) no info return from RRD for subconcept=$subconcept index=$index");
		return {};
	}

	foreach my $line ( @$graphret )
	{
		my ($name,$value) = split "=", $line;

		# set value to undef if this is infty or NaN/nan...
		if ($value != $value) 	# standard nan test
		{
			$value = undef;
		}
		else
		{
			$value += 0.0;												# force to number
		}

		$summaryStats{$name} = $value;
	}
	return \%summaryStats;
}


sub getGroupSummary {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $start_time = $args{start};
	my $end_time = $args{end};
	my $include_nodes = $args{include_nodes} // 0;
	my $local_nodes = $args{local_nodes};

	my @tmpsplit;
	my @tmparray;

	my $SUM = undef;
	my $reportStats;
	my %nodecount = ();
	my $node;
	my $index;
	my $cache = 0;
	my $filename;

	my %summaryHash = ();
	my $nmisng = new_nmisng();
	$nmisng->log->debug2(&NMISNG::Log::trace()."Starting");

	# grouped_node_summary joins collections, node_config is the prefix for the nodes config
	my $group_by = ['node_config.configuration.group']; # which is deeply structured!
	$group_by = undef if( !$group );

	my ($entries,$count,$error);
	if ($local_nodes) {
		$nmisng->log->debug("getGroupSummary - Getting local nodes");
		($entries,$count,$error) = $nmisng->grouped_node_summary(
			filters => { 'node_config.configuration.group' => $group, cluster_id => $nmisng->config->{cluster_id}},
			group_by => $group_by,
			include_nodes => $include_nodes
		);
	}
	else {
		$nmisng->log->debug("getGroupSummary - Getting all nodes");
		($entries,$count,$error) = $nmisng->grouped_node_summary(
			filters => { 'node_config.configuration.group' => $group },
			group_by => $group_by,
			include_nodes => $include_nodes
		);
	}

	if( $error || @$entries != 1 )
	{
		my $group_by_str = ($group_by)?join(",",@$group_by):"";
		$error ||= "No data returned for group:$group,group_by:$group_by_str include_nodes:$include_nodes";
		$nmisng->log->error("Failed to get grouped_node_summary data, error:$error");
		return \%summaryHash;
	}
	my ($group_summary,$node_data);
	if( $include_nodes )
	{
		$group_summary = $entries->[0]{grouped_data}[0];
		$node_data = $entries->[0]{node_data}
	}
	else
	{
		$group_summary = $entries->[0];
	}

	my $C = NMISNG::Util::loadConfTable();

	my @loopdata = ({key =>"reachable", precision => "3f"},{key =>"available", precision => "3f"},{key =>"health", precision => "3f"},{key =>"response", precision => "3f"});
	foreach my $entry ( @loopdata )
	{
		my ($key,$precision) = @$entry{'key','precision'};
		$summaryHash{average}{$key} = sprintf("%.${precision}", $group_summary->{"08_${key}_avg"});
		$summaryHash{average}{"${key}_diff"} = $group_summary->{"16_${key}_avg"} - $group_summary->{"08_${key}_avg"};

		# Now the summaryHash is full, calc some colors and check for empty results.
		if ( $summaryHash{average}{$key} ne "" )
		{
			$summaryHash{average}{$key} = 100 if( $summaryHash{average}{$key} > 100  && $key ne 'response') ;
			$summaryHash{average}{"${key}_color"} = colorHighGood($summaryHash{average}{$key})
		}
		else
		{
			$summaryHash{average}{"${key}_color"} = "#aaaaaa";
			$summaryHash{average}{$key} = "N/A";
		}
	}

	if ( $summaryHash{average}{reachable} > 0 and $summaryHash{average}{available} > 0 and $summaryHash{average}{health} > 0 )
	{
		# new weighting for metric
		$summaryHash{average}{metric} = sprintf("%.3f",(
																							( $summaryHash{average}{reachable} * $C->{metric_reachability} ) +
																							( $summaryHash{average}{available} * $C->{metric_availability} ) +
																							( $summaryHash{average}{health} * $C->{metric_health} ))
				);
		$summaryHash{average}{"16_metric"} = sprintf("%.3f",(
																									 ( $group_summary->{"16_reachable_avg"} * $C->{metric_reachability} ) +
																									 ( $group_summary->{"16_available_avg"} * $C->{metric_availability} ) +
																									 ( $group_summary->{"16_health_avg"} * $C->{metric_health} ))
				);
		$summaryHash{average}{metric_diff} = $summaryHash{average}{"16_metric"} - $summaryHash{average}{metric};
	}

	$summaryHash{average}{counttotal} = $group_summary->{count} || 0;
	$summaryHash{average}{countdown} = $group_summary->{countdown} || 0;
	$summaryHash{average}{countdegraded} = $group_summary->{countdegraded} || 0;
	$summaryHash{average}{countup} = $group_summary->{count} - $group_summary->{countdegraded} - $group_summary->{countdown};

	### 2012-12-17 keiths, fixed divide by zero error when doing group status summaries
	if ( $summaryHash{average}{countdown} > 0 ) {
		$summaryHash{average}{countdowncolor} = ($summaryHash{average}{countdown}/$summaryHash{average}{counttotal})*100;
	}
	else {
		$summaryHash{average}{countdowncolor} = 0;
	}

	# if the node info is needed then add it.
	if( $include_nodes )
	{
		foreach my $entry (@$node_data)
		{
			my $node = $entry->{name};
			++$nodecount{counttotal};
			my $outage = '';
			$summaryHash{$node} = $entry;

			my $nodeobj = $nmisng->node(uuid => $entry->{uuid}); # much safer than by node name

			# check nodes
			# Carefull logic here, if nodedown is false then the node is up
			#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
			if (NMISNG::Util::getbool($summaryHash{$node}{nodedown})) {
				($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$entry->{roleType});
				++$nodecount{countdown};
				($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());
			}
			elsif (exists $C->{display_status_summary}
						 and NMISNG::Util::getbool($C->{display_status_summary})
						 and exists $summaryHash{$node}{nodestatus}
						 and $summaryHash{$node}{nodestatus} eq "degraded"
					) {
				$summaryHash{$node}{event_status} = "Error";
				$summaryHash{$node}{event_color} = "#ffff00";
				++$nodecount{countdegraded};
				($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());
			}
			else {
				($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Up",$entry->{roleType});
				++$nodecount{countup};
			}

			# dont if outage current with node down
			if ($outage ne 'current') {
				if ( $summaryHash{$node}{reachable} !~ /NaN/i	) {
					++$nodecount{reachable};
					$summaryHash{$node}{reachable_color} = colorHighGood($summaryHash{$node}{reachable});
				} else { $summaryHash{$node}{reachable} = "NaN" }

				if ( $summaryHash{$node}{available} !~ /NaN/i ) {
					++$nodecount{available};
					$summaryHash{$node}{available_color} = colorHighGood($summaryHash{$node}{available});
				} else { $summaryHash{$node}{available} = "NaN" }

				if ( $summaryHash{$node}{health} !~ /NaN/i ) {
					++$nodecount{health};
					$summaryHash{$node}{health_color} = colorHighGood($summaryHash{$node}{health});
				} else { $summaryHash{$node}{health} = "NaN" }

				if ( $summaryHash{$node}{response} !~ /NaN/i ) {
					++$nodecount{response};
					$summaryHash{$node}{response_color} = NMISNG::Util::colorResponseTime($summaryHash{$node}{response});
				} else { $summaryHash{$node}{response} = "NaN" }
			}
		}
	}

	$nmisng->log->debug2(&NMISNG::Log::trace()."Finished");
	return \%summaryHash;
} # end getGroupSummary

#=========================================================================================

# if you think this function and the next look very similar you are correct
sub getAdminColor {
	my %args = @_;
	my ($S,$index) = @args{'sys','index'};
	my ($ifAdminStatus,$ifOperStatus,$collect,$data) = @args{'ifAdminStatus','ifOperStatus','collect','data'};
	my $adminColor;

	if( defined($S) && defined($index) && !$data )
	{
		#inventory keyed by index and ifDescr so we need partial
		my $inventory = $S->inventory( concept => 'interface', index => $index, partial => 1 );
		# if data not found use args
		$data = ($inventory) ? $inventory->data : \%args;
	}

	if( $data )
	{
		$ifAdminStatus = $data->{ifAdminStatus};
		$collect = $data->{collect};
	}
	elsif ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !NMISNG::Util::getbool($collect)) {
		$adminColor="#ffffff";
	} else {
		$adminColor="#00ff00";
	}
	return $adminColor;
}

#=========================================================================================

# get color stuff, determined from collect/{admin|oper}Status
# args:
#   S,index - if provided interface status info will be looked up from it
#   if S not provided then status/collect must be provided in arguments
sub getOperColor {
	my (%args) = @_;
	my ($S,$index) = @args{'sys','index'};
	my ($ifAdminStatus,$ifOperStatus,$collect,$data) = @args{'ifAdminStatus','ifOperStatus','collect','data'};

	my $operColor;

	if( defined($S) && defined($index) && !$data )
	{
		my $inventory = $S->inventory( concept => 'interface', index => $index, partial => 1 );
		# if data not found use args
		$data = ($inventory) ? $inventory->data : \%args;
	}
	if( $data )
	{
		$ifAdminStatus = $data->{ifAdminStatus};
		$ifOperStatus = $data->{ifOperStatus};
		$collect = $data->{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !NMISNG::Util::getbool($collect)) {
		$operColor="#ffffff"; # white
	} else {
		if ($ifOperStatus eq 'down') {
			# red for down
			$operColor = "#ff0000";
		} elsif ($ifOperStatus eq 'dormant') {
			# yellow for dormant
			$operColor = "#ffff00";
		} else { $operColor = "#00ff00"; } # green
	}
	return $operColor;
}

sub colorHighGood {
	my ($threshold) = @_;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold eq "N/A" )  { $color = "#FFFFFF"; }
	elsif ( $threshold >= 100 ) { $color = "#00FF00"; }
	elsif ( $threshold >= 95 ) { $color = "#00EE00"; }
	elsif ( $threshold >= 90 ) { $color = "#00DD00"; }
	elsif ( $threshold >= 85 ) { $color = "#00CC00"; }
	elsif ( $threshold >= 80 ) { $color = "#00BB00"; }
	elsif ( $threshold >= 75 ) { $color = "#00AA00"; }
	elsif ( $threshold >= 70 ) { $color = "#009900"; }
	elsif ( $threshold >= 65 ) { $color = "#008800"; }
	elsif ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold >= 55 ) { $color = "#FFEE00"; }
	elsif ( $threshold >= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold >= 45 ) { $color = "#FFCC00"; }
	elsif ( $threshold >= 40 ) { $color = "#FFBB00"; }
	elsif ( $threshold >= 35 ) { $color = "#FFAA00"; }
	elsif ( $threshold >= 30 ) { $color = "#FF9900"; }
	elsif ( $threshold >= 25 ) { $color = "#FF8800"; }
	elsif ( $threshold >= 20 ) { $color = "#FF7700"; }
	elsif ( $threshold >= 15 ) { $color = "#FF6600"; }
	elsif ( $threshold >= 10 ) { $color = "#FF5500"; }
	elsif ( $threshold >= 5 )  { $color = "#FF3300"; }
	elsif ( $threshold > 0 )   { $color = "#FF1100"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }

	return $color;
}

sub colorPort {
	my $threshold = shift;
	my $color = "";

	if ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold < 60 ) { $color = "#00FF00"; }

	return $color;
}

sub colorLowGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold == 0 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 5 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 10 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 15 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 20 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 25 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 30 ) { $color = "#009900"; }
	elsif ( $threshold <= 35 ) { $color = "#008800"; }
	elsif ( $threshold <= 40 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 45 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 55 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 60 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 65 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 70 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 75 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 80 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 85 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 90 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 95 ) { $color = "#FF4400"; }
	elsif ( $threshold < 100 ) { $color = "#FF3300"; }
	elsif ( $threshold == 100 )  { $color = "#FF1100"; }
	elsif ( $threshold <= 110 )  { $color = "#FF0055"; }
	elsif ( $threshold <= 120 )  { $color = "#FF0066"; }
	elsif ( $threshold <= 130 )  { $color = "#FF0077"; }
	elsif ( $threshold <= 140 )  { $color = "#FF0088"; }
	elsif ( $threshold <= 150 )  { $color = "#FF0099"; }
	elsif ( $threshold <= 160 )  { $color = "#FF00AA"; }
	elsif ( $threshold <= 170 )  { $color = "#FF00BB"; }
	elsif ( $threshold <= 180 )  { $color = "#FF00CC"; }
	elsif ( $threshold <= 190 )  { $color = "#FF00DD"; }
	elsif ( $threshold <= 200 )  { $color = "#FF00EE"; }
	elsif ( $threshold > 200 )  { $color = "#FF00FF"; }

	return $color;
}

sub colorResponseTimeStatic {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold <= 1 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 20 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 50 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 100 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 200 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 250 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 300 ) { $color = "#009900"; }
	elsif ( $threshold <= 350 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 400 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 450 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 500 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 550 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 600 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 650 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 700 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 750 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 800 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 850 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 900 ) { $color = "#FF4400"; }
	elsif ( $threshold <= 950 )  { $color = "#FF3300"; }
	elsif ( $threshold < 1000 )   { $color = "#FF1100"; }
	elsif ( $threshold > 1000 )  { $color = "#FF0000"; }

	return $color;
}



# fixme9: az thinks this function should be reworked
# or ditched in favour of node->coarse_status) and node->precise_status
# as this one also doesn't understand wmidown (properly)
sub overallNodeStatus
{
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $netType = $args{netType};
	my $roleType = $args{roleType};

	if (scalar(@_) == 1) {
		$group = shift;
	}

	my $node_name;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $status;

	my %statusHash;

	my $nmisng = new_nmisng();
	my $C = NMISNG::Util::loadConfTable();
	my $NT = loadNodeTable();
	my $NS = loadNodeSummary();

	foreach $node_name (sort keys %{$NT} )
	{
		my $config = $NT->{$node_name};
		next if (!NMISNG::Util::getbool($config->{active}));

		if (
			( $group eq "" and $customer eq "" and $business eq "" and $netType eq "" and $roleType eq "" )
			or
			( $netType ne "" and $roleType ne ""
				and $config->{net} eq "$netType" && $config->{role} eq "$roleType" )
			or ($group ne "" and $config->{group} eq $group)
			or ($customer ne "" and $config->{customer} eq $customer)
			or ($business ne "" and $config->{businessService} =~ /$business/ ) )
		{
			my $nodedown = 0;
			my $outage = "";

			my $nodeobj = $nmisng->node(uuid => $config->{uuid});

			### 2013-08-20 keiths, check for SNMP Down if ping eq false.
			my $down_event = "Node Down";
			$down_event = "SNMP Down" if NMISNG::Util::getbool($config->{ping},"invert");
			$nodedown = $nodeobj->eventExist($down_event);

			($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());

			if ( $nodedown and $outage ne 'current' ) {
				($event_status) = eventLevel("Node Down",$config->{roleType});
			}
			else {
				($event_status) = eventLevel("Node Up",$config->{roleType});
			}

			++$statusHash{$event_status};
			++$statusHash{count};
		}
	}

	$status_number = 100 * $statusHash{Normal};
	$status_number = $status_number + ( 90 * $statusHash{Warning} );
	$status_number = $status_number + ( 75 * $statusHash{Minor} );
	$status_number = $status_number + ( 60 * $statusHash{Major} );
	$status_number = $status_number + ( 50 * $statusHash{Critical} );
	$status_number = $status_number + ( 40 * $statusHash{Fatal} );
	if ( $status_number != 0 and $statusHash{count} != 0 ) {
		$status_number = $status_number / $statusHash{count};
	}
	#print STDERR "New CALC: status_number=$status_number count=$statusHash{count}\n";

	### 2014-08-27 keiths, adding a more coarse any nodes down is red
	if ( defined $C->{overall_node_status_coarse}
			 and NMISNG::Util::getbool($C->{overall_node_status_coarse})) {
		$C->{overall_node_status_level} = "Critical" if not defined $C->{overall_node_status_level};
		if ( $status_number == 100 ) { $overall_status = "Normal"; }
		else { $overall_status = $C->{overall_node_status_level}; }
	}
	else {
		### AS 11/4/01 - Fixed up status for single node groups.
		# if the node count is one we do not require weighting.
		if ( $statusHash{count} == 1 ) {
			delete ($statusHash{count});
			foreach $status (keys %statusHash) {
				if ( $statusHash{$status} ne "" and $statusHash{$status} ne "count" ) {
					$overall_status = $status;
					#print STDERR returnDateStamp." overallNodeStatus netType=$netType status=$status hash=$statusHash{$status}\n";
				}
			}
		}
		elsif ( $status_number != 0  ) {
			if ( $status_number == 100 ) { $overall_status = "Normal"; }
			elsif ( $status_number >= 95 ) { $overall_status = "Warning"; }
			elsif ( $status_number >= 90 ) { $overall_status = "Minor"; }
			elsif ( $status_number >= 70 ) { $overall_status = "Major"; }
			elsif ( $status_number >= 50 ) { $overall_status = "Critical"; }
			elsif ( $status_number <= 40 ) { $overall_status = "Fatal"; }
			elsif ( $status_number >= 30 ) { $overall_status = "Disaster"; }
			elsif ( $status_number < 30 ) { $overall_status = "Catastrophic"; }
		}
		else {
			$overall_status = "Unknown";
		}
	}
	return $overall_status;
} # end overallNodeStatus



### AS 8 June 2002 - Converts status level to a number for metrics
sub statusNumber {
	my $status = shift;
	my $level;
	if ( $status eq "Normal" ) { $level = 100 }
	elsif ( $status eq "Warning" ) { $level = 95 }
	elsif ( $status eq "Minor" ) { $level = 90 }
	elsif ( $status eq "Major" ) { $level = 80 }
	elsif ( $status eq "Critical" ) { $level = 60 }
	elsif ( $status eq "Fatal" ) { $level = 40 }
	elsif ( $status eq "Disaster" ) { $level = 20 }
	elsif ( $status eq "Catastrophic" ) { $level = 0 }
	elsif ( $status eq "Unknown" ) { $level = "U" }
	return $level;
}


# load info of all interfaces - fixme9: this is likely dead slow
# and wasteful (as it combines EVERYTHING) - should be replaced by much more targetted lookups!
sub loadInterfaceInfo
{
	my $nmisng = new_nmisng();

	my $get_node_uuids = $nmisng->get_node_uuids(
		filter => { cluster_id => $nmisng->config->{cluster_id}, "activated.NMIS" => 1, "configuration.collect" => 1 } );

	my %interfaceInfo;
	foreach my $node_uuid ( @$get_node_uuids )
	{
		my $nmisng_node = $nmisng->node( uuid => $node_uuid );
		my $node_name = $nmisng_node->name();

		# ony grab active interfaces
		my $ids = $nmisng_node->get_inventory_ids(concept => 'interface', filter => { enabled => 1, historic => 0});
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $nmisng_node->inventory( _id => $id );
			$nmisng->log->error("Failed to get inventory, error_message:$error_message") && next
					if(!$inventory);

			my $data = $inventory->data();
			next if ($data->{ifDescr} eq "");

			my $tmpDesc = &NMISNG::Util::convertIfName( $data->{ifDescr} );
			my $dest = $interfaceInfo{"$node_name-$tmpDesc"} = {};

			$dest->{node} = $node_name;
			$dest->{uuid} = $nmisng_node->uuid;

			for my $copyme (
				qw(ifIndex ifDescr collect real ifType ifSpeed ifAdminStatus
						ifOperStatus ifLastChange Description display_name portModuleIndex portIndex portDuplex portIfIndex
						portSpantreeFastStart vlanPortVlan portAdminSpeed)
					)
			{
				$dest->{$copyme} = $data->{$copyme};
			}

			my $cnt = 1;
			while ( defined( $data->{"ipAdEntAddr$cnt"} ) )
			{
				for my $copymeprefix (qw(ipAdEntAddr ipAdEntNetMask ipSubnet ipSubnetBits))
				{
					my $copyme = $copymeprefix . $cnt;
					$dest->{$copyme} = $data->{$copyme};
				}
				$cnt++;
			}
		}
	}
	return \%interfaceInfo;
}

sub loadEnterpriseTable {
	return NMISNG::Util::loadTable(dir=>'conf',name=>'Enterprise');
}


# small translator from event level to priority: header for email
sub eventToSMTPPri {
	my $level = shift;
	# More granularity might be possible there are 5 numbers but
	# can only find word to number mappings for L, N, H
	if ( $level eq "Normal" ) { return "Normal" }
	elsif ( $level eq "Warning" ) { return "Normal" }
	elsif ( $level eq "Minor" ) { return "Normal" }
	elsif ( $level eq "Major" ) { return "High" }
	elsif ( $level eq "Critical" ) { return "High" }
	elsif ( $level eq "Fatal" ) { return "High" }
	elsif ( $level eq "Disaster" ) { return "High" }
	elsif ( $level eq "Catastrophic" ) { return "High" }
	elsif ( $level eq "Unknown" ) { return "Low" }
	else
	{
		return "Normal";
	}
}

# test the dutytime of the given contact.
# return true if OK to notify
# expect a reference to %contact_table, and a contact name to lookup
sub dutyTime
{
	my ($table , $contact) = @_;
	my $today;
	my $days;
	my $start_time;
	my $finish_time;

	if ( $$table{$contact}{DutyTime} ) {
		# dutytime has some values, so assume TZ offset to localtime has as well
		my @ltime = localtime( time() + ($$table{$contact}{TimeZone}*60*60));

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				return 1;
			}
			elsif ( $finish_time < $start_time ) {
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		return 1;
	}
	return 0;		# dutytime was valid, but no timezone match, return false.
}

# produce clickable graph and return html that can be pasted onto a page
# rrd graph is created by this function and cached on disk
#
# args: node/group OR sys, intf/item, cluster_id, graphtype, width, height (all required),
#  start, end (optional),
#  only_link (optional, default: 0, if set ONLY the href for the graph is returned),
# returns: html or link/href value
sub htmlGraph
{
	my %args = @_;

	my $C = NMISNG::Util::loadConfTable();

	my $graphtype = $args{graphtype};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $item  = $args{item};
	my $parent = $args{cluster_id} || $C->{cluster_id}; # default: ours
	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $inventory = $args{inventory};
	my $omit_fluff = NMISNG::Util::getbool($args{only_link}); # return wrapped <a> etc. or just the href?
	
	my $sys = $args{sys};
	if (ref($sys) eq "NMISNG::Sys" && ref($sys->nmisng_node))
	{
		$node = $sys->nmisng_node->name;
		if (!$inventory) {
			$sys->nmisng->log->debug($graphtype . " index " . $intf);
			$inventory = $sys->inventory(concept => $graphtype, index => $intf);
		}
	}
	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);
	my $urlsafeintf = uri_escape($intf);
	my $urlsafeitem = uri_escape($item);

	my $target = $node || $group; # only used for js/widget linkage
	my $clickurl = "$C->{'node'}?act=network_graph_view&graphtype=$graphtype&group=$urlsafegroup&intf=$urlsafeintf&item=$urlsafeitem&cluster_id=$parent&node=$urlsafenode";

	my $time = time();
	my $graphlength = ( $C->{graph_unit} eq "days" )?
			86400 * $C->{graph_amount} : 3600 * $C->{graph_amount};
	my $start = $args{start} || time-$graphlength;
	my $end = $args{end} || $time;

	# where to put the graph file? let's use htdocs/cache, that's web-accessible
	my $cachedir = $C->{'web_root'}."/cache";
	NMISNG::Util::createDir($cachedir) if (!-d $cachedir);

	# we need a time-invariant, short and safe file name component,
	# which also must incorporate a server-specific bit of secret sauce
	# that an external party does not have access to (to eliminate guessing)
	my $graphfile_prefix = Digest::MD5::md5_hex(
		join("__",
				 $C->{auth_web_key},
				 $group, $node, $intf, $item,
				 $graphtype,
				 $parent,
				 $width, $height));

	# do we want to reuse an existing, 'new enough' graph?
	opendir(D, $cachedir);
	my @recyclables = grep(/^$graphfile_prefix/, readdir(D));
	closedir(D);

	my $graphfilename;
	my $cachefilemaxage = $C->{graph_cache_maxage} // 60;

	for my $maybe (sort { $b cmp $a } @recyclables)
	{
		next if ($maybe !~ /^\S+_(\d+)_(\d+)\.png$/); # should be impossible
		my ($otherstart, $otherend) = ($1,$2);

		# let's accept anything newer than 60 seconds as good enough
		my $deltastart = $start - $otherstart;
		$deltastart *= -1 if ($deltastart < 0);
		my $deltaend = $end - $otherend;
		$deltaend *= -1 if ($deltaend < 0);

		if ($deltastart <= $cachefilemaxage && $deltaend <= $cachefilemaxage)
		{
			$graphfilename = $maybe;
			$sys->nmisng->log->debug2("reusing cached graph $maybe for $graphtype, node $node: requested period off by "
																.($start-$otherstart)." seconds")
					if ($sys);

			last;
		}
	}

	# nothing useful in the cache? then generate a new graph
	if (!$graphfilename)
	{
		$graphfilename = $graphfile_prefix."_${start}_${end}.png";
		$sys->nmisng->log->debug2("graphing args for new graph: node=$node, group=$group, graphtype=$graphtype, intf=$intf, item=$item, cluster_id=$parent, start=$start, end=$end, width=$width, height=$height, filename=$cachedir/$graphfilename")
				if ($sys);

		my $target = "$cachedir/$graphfilename";
		my $result = NMISNG::rrdfunc::draw(sys => $sys,
																			 node => $node,
																			 group => $group,
																			 graphtype => $graphtype,
																			 intf => $intf,
																			 item => $item,
																			 start => $start,
																			 end =>  $end,
																			 width => $width,
																			 height => $height,
																			 filename => $target,
																			 inventory => $inventory);
		return qq|<p>Error: $result->{error}</p>| if (!$result->{success});
		NMISNG::Util::setFileProtDiag($target);	# to make the selftest happy...
	}

	# return just the href? or html?
	return $omit_fluff? "$C->{'<url_base>'}/cache/$graphfilename"
			: qq|<a target="Graph-$target" onClick="viewwndw(\'$target\',\'$clickurl\',$C->{win_width},$C->{win_height})"><img alt='Network Info' src="$C->{'<url_base>'}/cache/$graphfilename"></img></a>|;
}

# args: user, node, system, refresh, widget, au (object),
# conf (=name of config for links)
# returns: html as array of lines
sub createHrButtons
{
	my %args = @_;
	my $user = $args{user};
	my $node = $args{node};
	my $S = $args{system};
	my $refresh = $args{refresh};
	my $widget = $args{widget};
	my $AU = $args{AU};

	return "" if (!$node);
	$refresh = "false" if (!NMISNG::Util::getbool($refresh));

	my @out;

	# note, not using live data beause this isn't used in collect/update
	my $catchall_data = $S->inventory( concept => 'catchall')->data();
	my $nmisng_node = $S->nmisng_node;
	my $parent = $nmisng_node->cluster_id; # cluster_id of the nmis polling this node

	my $C = NMISNG::Util::loadConfTable();
	return unless $AU->InGroup($catchall_data->{group});

	my $urlsafenode = uri_escape($node);


	push @out, "<table class='table'><tr>\n";

	# provide link back to the main dashboard if not in widget mode
	push @out, CGI::td({class=>"header litehead"}, CGI::a({class=>"wht", href=>$C->{'nmis'}."?"},
																												"NMIS $Compat::NMIS::VERSION"))
			if (!NMISNG::Util::getbool($widget));

	push @out, CGI::td({class=>'header litehead'},'Node ',
										 CGI::a({class=>'wht',href=>"network.pl?act=network_node_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},$node));

	if ($S->getTypeInstances(graphtype => 'service', section => 'service')) {
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?act=network_service_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"services"));
	}

	if (NMISNG::Util::getbool($catchall_data->{collect}))
	{
		my $status_md = $nmisng_node->get_status_model();
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?act=network_status_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"status"))
			if $status_md->count > 0 and defined $C->{display_status_summary} and NMISNG::Util::getbool($C->{display_status_summary});
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?act=network_interface_view_all&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"interfaces"))
				if (defined $S->{mdl}{interface});
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?act=network_interface_view_act&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"active intf"))
				if defined $S->{mdl}{interface};

		# this should potentially be querying for active/not-historic
		my $ids = $S->nmisng_node->get_inventory_ids( concept => 'interface' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?act=network_port_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"ports"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?act=network_storage_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"storage"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		# adding services list support, but hide the tab if the snmp service collection isn't working
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?act=network_service_list&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"service list"));
		}
		if ($S->getTypeInstances(graphtype => "hrsmpcpu")) {
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?act=network_cpu_list&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"cpu list"));
		}

		# let's show the possibly many systemhealth items in a dropdown menu
		if ( defined $S->{mdl}{systemHealth}{sys} )
		{
    	my @systemHealth = split(",",$S->{mdl}{systemHealth}{sections});
			push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>System Health &#x25BE<ul>";
			foreach my $sysHealth (@systemHealth)
			{
				my $ids = $nmisng_node->get_inventory_ids( concept => $sysHealth );
				# don't show spurious blank entries
				if ( @$ids > 0 )
				{
					push @out, CGI::li(CGI::a({ class=>'wht',  href=>"network.pl?act=network_system_health_view&section=$sysHealth&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"}, $sysHealth));
				}
			}
			push @out, "</ul></li></ul></td>";
		}
	}

	push @out, CGI::td({class=>'header litehead'},
										 CGI::a({class=>'wht',href=>"events.pl?act=event_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"events"));
	push @out, CGI::td({class=>'header litehead'},
										 CGI::a({class=>'wht',href=>"outages.pl?act=outage_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"outage"));


	# and let's combine these in a 'diagnostic' menu as well
	push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>Diagnostic &#x25BE<ul>";

	# drill-in for the node's collect/update time
	push @out, CGI::li(CGI::a({class=>"wht",
														 href=> "$C->{'<cgi_url_base>'}/node.pl?act=network_graph_view&widget=false&node=$urlsafenode&graphtype=polltime",
														 target=>"_blank"},
														"Collect/Update Runtime"));

	push @out, CGI::li(CGI::a({class=>'wht',href=>"telnet://$catchall_data->{host}",target=>'_blank'},"telnet"))
			if (NMISNG::Util::getbool($C->{view_telnet}));

	if (NMISNG::Util::getbool($C->{view_ssh})) {
		my $ssh_url = $C->{ssh_url} ? $C->{ssh_url} : "ssh://";
		my $ssh_port = $C->{ssh_port} ? ":$C->{ssh_port}" : "";
		push @out, CGI::li(CGI::a({class=>'wht',href=>"$ssh_url$catchall_data->{host}$ssh_port",
															 target=>'_blank'},"ssh"));
	}

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?act=tool_system_ping&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"ping"))
			if NMISNG::Util::getbool($C->{view_ping});
	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?act=tool_system_trace&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"trace"))
			if NMISNG::Util::getbool($C->{view_trace});
	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?act=tool_system_mtr&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"mtr"))
			if NMISNG::Util::getbool($C->{view_mtr});

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?act=tool_system_lft&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"lft"))
			if NMISNG::Util::getbool($C->{view_lft});

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"http://$catchall_data->{host}",target=>'_blank'},"http"))
			if NMISNG::Util::getbool($catchall_data->{webserver});
	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?act=tool_system_snmp&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"SNMP"))
			if NMISNG::Util::getbool($C->{view_snmp});
	# end of diagnostic menu
	push @out, "</ul></li></ul></td>";

	if ($parent eq $C->{cluster_id})
	{
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"tables.pl?act=config_table_show&table=Contacts&key=".uri_escape($catchall_data->{sysContact})."&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"contact"))
				if $catchall_data->{sysContact} ne '';
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"tables.pl?act=config_table_show&table=Locations&key=".uri_escape($catchall_data->{sysLocation})."&node=$urlsafenode&refresh=$refresh&widget=$widget&cluster_id=$parent"},"location"))
				if $catchall_data->{sysLocation} ne '';
	}

	push @out, "</tr></table>";

	return @out;
}

sub loadPortalCode {
	my %args = @_;
	my $C =	NMISNG::Util::loadConfTable();

	my $portalCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Portal") ) {
		# portal menu of nodes or clients to link to.
		my $P = NMISNG::Util::loadTable(dir=>'conf',name=>"Portal");

		my $portalOption;

		foreach my $p ( sort {$a <=> $b} keys %{$P} ) {
			# If the link is part of NMIS, append the config
			my $selected;

			if ( $P->{$p}{Link} =~ /cgi-nmis9/ ) {
				$P->{$p}{Link} .= "?";
			}

			if ( $ENV{SCRIPT_NAME} =~ /nmiscgi/ and $P->{$p}{Link} =~ /nmiscgi/ and $P->{$p}{Name} =~ /NMIS9/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /maps/ and $P->{$p}{Name} =~ /Map/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			$portalOption .= qq|<option value="$P->{$p}{Link}"$selected>$P->{$p}{Name}</option>\n|;
		}


		$portalCode = qq|
				<div class="left">
					<form id="viewpoint">
						<select name="viewselect" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$portalOption
						</select>
					</form>
				</div>|;

	}
	return $portalCode;
}

sub loadServerCode {
	my %args = @_;
	my $C = NMISNG::Util::loadConfTable();

	my $serverCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Servers") ) {
		# portal menu of nodes or clients to link to.
		my $ST = loadServersTable();

		my $serverOption;

		$serverOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Servers">NMIS Servers</option>\n|;

		foreach my $srv ( sort {$ST->{$a}{name} cmp $ST->{$b}{name}} keys %{$ST} ) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# If the link is part of NMIS, append the config
			$serverOption .= qq|<option value="$ST->{$srv}{portal_protocol}://$ST->{$srv}{portal_host}:$ST->{$srv}{portal_port}$ST->{$srv}{cgi_url_base}/nmiscgi.pl?">$ST->{$srv}{name}</option>\n|;
		}


		$serverCode = qq|
				<div class="left">
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$serverOption
						</select>
					</form>
				</div>|;

	}
	return $serverCode;
}

sub loadTenantCode {
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();

	my $tenantCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Tenants") ) {
		# portal menu of nodes or clients to link to.
		my $MT = NMISNG::Util::loadTable(dir=>'conf',name=>"Tenants");

		my $tenantOption;

		$tenantOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Tenants">NMIS Tenants</option>\n|;

		foreach my $t ( sort {$MT->{$a}{Name} cmp $MT->{$b}{Name}} keys %{$MT} ) {
			# If the link is part of NMIS, append the config

			$tenantOption .= qq|<option value="?">$MT->{$t}{Name}</option>\n|;
		}


		$tenantCode = qq|
				<div class="left">
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$tenantOption
						</select>
					</form>
				</div>|;

	}
	return $tenantCode;
}

sub startNmisPage {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = NMISNG::Util::loadConfTable();

	print qq
			|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
			<html>
			<head>
			<title>$title</title>
			<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
			<meta http-equiv="Pragma" content="no-cache" />
			<meta http-equiv="Cache-Control" content="no-cache, no-store" />
			<meta http-equiv="Expires" content="-1" />
			<meta http-equiv="Robots" content="none" />
			<meta http-equiv="Googlebot" content="noarchive" />
			<link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
			<script src="$C->{'jquery'}" type="text/javascript"></script>
			<script src="$C->{'jquery_ui'}" type="text/javascript"></script>
			<script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>
			<script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
			<script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
			<script src="$C->{'calendar'}" type="text/javascript"></script>
			<script src="$C->{'calendar_setup'}" type="text/javascript"></script>
			<script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>
			<script src="$C->{'nmis_common'}?v=$Compat::NMIS::VERSION" type="text/javascript"></script>
			</head>
			<body>
			|;
	return 1;
}

sub pageStart {
	my %args = @_;
	my $refresh = $args{refresh};
	my $title = $args{title};
	my $jscript = $args{jscript};
	$jscript = getJavaScript() if ($jscript eq "");
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 300 if ($refresh eq "");

	my $C = NMISNG::Util::loadConfTable();

	print qq
			|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
			<html>
			<head>
			<title>$title</title>|,

			(defined($refresh) && $refresh > 0 ?
			 qq|<meta http-equiv="refresh" content="$refresh" />\n| : ""),

			qq|<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
			<meta http-equiv="Pragma" content="no-cache" />
			<meta http-equiv="Cache-Control" content="no-cache, no-store" />
			<meta http-equiv="Expires" content="-1" />
			<meta http-equiv="Robots" content="none" />
			<meta http-equiv="Googlebot" content="noarchive" />
			<link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
			<script src="$C->{'jquery'}" type="text/javascript"></script>
			<script>
			$jscript
			</script>
			</head>
			<body>
			|;
}


sub pageStartJscript {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = NMISNG::Util::loadConfTable();

	print qq
			|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
			<html>
			<head>
			<title>$title</title>|,

			(defined($refresh) && $refresh > 0?
			 qq|<meta http-equiv="refresh" content="$refresh" />\n| : "" ),

			qq|<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
			<meta http-equiv="Pragma" content="no-cache" />
			<meta http-equiv="Cache-Control" content="no-cache, no-store" />
			<meta http-equiv="Expires" content="-1" />
			<meta http-equiv="Robots" content="none" />
			<meta http-equiv="Googlebot" content="noarchive" />
			<link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
			<link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
			<script src="$C->{'jquery'}" type="text/javascript"></script>
			<script src="$C->{'jquery_ui'}" type="text/javascript"></script>
			<script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>
			<script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
			<script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
			<script src="$C->{'calendar'}" type="text/javascript"></script>
			<script src="$C->{'calendar_setup'}" type="text/javascript"></script>
			<script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>
			<script src="$C->{'nmis_common'}" type="text/javascript"></script>
			</head>
			<body>
			|;
	return 1;
}

sub pageEnd {
	print "</body></html>";
}


sub getJavaScript {
	my $jscript = <<JS_END;
	function viewwndw(wndw,url,width,height)
	{
		var attrib = "scrollbars=yes,resizable=yes,width=" + width + ",height=" + height;
		ViewWindow = window.open(url,wndw,attrib);
		ViewWindow.focus();
	};
JS_END

			return $jscript;
}

# Load and organize the CBQoS meta-data
# inputs: a sys object, an index and a graphtype
# returns ref to sorted list of names, ref to hash of description/bandwidth/color/index/section
# this function is not exported on purpose, to reduce namespace clashes.
sub loadCBQoS
{
	my %args = @_;
	my $S = $args{sys};
	my $index = $args{index};
	my $graphtype = $args{graphtype};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	# this is still used by huaweiqos, nothing else should be using it
	# fixme9: this must be reworked to use inventory for huwaweiqos, too,
	# and the admin/huaweirouter-helper.pl needs to become a proper plugin.
	my $NI = {};

	my $M = $S->mdl;
	my $node = $catchall_data->{name};

	my ($PMName,  @CMNames, %CBQosValues , @CBQosNames);

	# define line/area colors of the graph
	my @colors = ("3300ff", "33cc33", "ff9900", "660099",
								"ff66ff", "ff3333", "660000", "0099CC",
								"0033cc", "4B0082","00FF00", "FF4500",
								"008080","BA55D3","1E90FF",  "cc00cc");

	my $direction = $graphtype eq "cbqos-in" ? "in" : "out" ;

	# in the cisco case we have the classmap as basis;
	# for huawei this info comes from the QualityOfServiceStat section
	# which is indexed (and collected+saved) per qos stat entry, NOT interface!
	if (exists $NI->{QualityOfServiceStat})
	{
		NMISNG::Util::TODO("Port huaweiqos in loadCBQos and in the plugin");
		my $huaweiqos = $NI->{QualityOfServiceStat};
		for my $k (keys %{$huaweiqos})
		{
			next if ($huaweiqos->{$k}->{ifIndex} != $index or $huaweiqos->{$k}->{Direction} !~ /^$direction/);
			my $CMName = $huaweiqos->{$k}->{ClassifierName};
			push @CMNames, $CMName;
			$PMName = $huaweiqos->{$k}->{Direction}; # there are no policy map names in huawei's qos

			# huawei devices don't expose descriptions or (easily accessible) bw limits
			$CBQosValues{$index.$CMName} = { CfgType => "Bandwidth", CfgRate => undef,
																			 CfgIndex => $k, CfgItem =>  undef,
																			 CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => "QualityOfServiceStat",
																			 # ds names: bytes for in, out, and drop (aka prepolicy postpolicy drop in cisco parlance),
																			 # then packets and nobufdroppkt (which huawei doesn't have)
																			 CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets),undef],
			};
		}
	}
	else													# the cisco case
	{
		my $inventory = $S->inventory( concept => "cbqos-$direction", index => $index );
		my $data = ($inventory) ? $inventory->data : {};
		$PMName = $data->{PolicyMap}{Name};

		foreach my $k (keys %{$data->{ClassMap}}) {
			my $CMName = $data->{ClassMap}{$k}{Name};
			push @CMNames , $CMName if $CMName ne "";

			$CBQosValues{$index.$CMName} = { CfgType => $data->{ClassMap}{$k}{'BW'}{'Descr'},
																			 CfgRate => $data->{ClassMap}{$k}{'BW'}{'Value'},
																			 CfgIndex => $index, CfgItem => undef,
																			 CfgUnique => $k,  # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => $graphtype,
																			 CfgDSNames => [qw(PrePolicyByte PostPolicyByte DropByte PrePolicyPkt),
																											undef,"DropPkt", "NoBufDropPkt"]};
		}
	}

	# order the buttons of the classmap names for the Web page
	@CMNames = sort {uc($a) cmp uc($b)} @CMNames;

	my @qNames;
	my @confNames = split(',', $M->{node}{cbqos}{order_CM_buttons});
	foreach my $Name (@confNames) {
		for (my $i=0; $i<=$#CMNames; $i++) {
			if ($Name eq $CMNames[$i] ) {
				push @qNames, $CMNames[$i] ; # move entry
				splice (@CMNames,$i,1);
				last;
			}
		}
	}

	@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
	if ($#CBQosNames) {
		# colors of the graph in the same order
		for my $i (1..$#CBQosNames) {
			if ($i < $#colors ) {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = $colors[$i-1];
			} else {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = "000000";
			}
		}
	}

	return \(@CBQosNames,%CBQosValues);
} # end loadCBQos


# all event handling routines follow below


# small helper that translates event data into a severity level
# args: event, role.
# returns: severity level, color
# fixme: only used for group status summary display! actual event priorities come from the model
sub eventLevel {
	my ($event, $role) = @_;

	my ($event_level, $event_color);

	my $C = NMISNG::Util::loadConfTable();			# cached, mostly nop

	# the config now has a structure for xlat between roletype and severities for node down/other events
	my $rt2sev = $C->{severity_by_roletype};
	$rt2sev = { default => [ "Major", "Minor" ] } if (ref($rt2sev) ne "HASH" or !keys %$rt2sev);

	if ( $event eq 'Node Down' )
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[0] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[0] : "Major";
	}
	elsif ( $event =~ /up/i )
	{
		$event_level = "Normal";
	}
	else
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[1] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[1] : "Major";
	}
	$event_level = "Major" if ($event_level !~ /^(fatal|critical|major|minor|warning|normal)$/i); 	# last-ditch fallback
	$event_color = NMISNG::Util::eventColor($event_level);

	return ($event_level,$event_color);
}

# loads one or more service statuses
#
# args: service, node, cluster_id, only_known (all optional), all_cluster
# if service or node are given, only matching services are returned.
# cluster_id defaults to the local one, and is IGNORED unless only_known is 0.
#
# only_known is 1 by default, which ensures that only locally known, active services
# listed in Services.nmis and attached to active nodes are returned.
#
# if only_known is set to zero, then all services, remote or local,
# active or not are returned.
#
# when all_cluster equals true, it is not going to filter by master cluster_id
# when no cluster_id is provided
# opCharts use this to show the MonitoredServices from the poller
#
# returns: hash of cluster_id -> service -> node -> data; empty if invalid args
sub loadServiceStatus
{
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();			# generally cached anyway

	my $wantnode = $args{node};
	my $wantservice = $args{service};
	my $wantcluster;
	if ($args{all_cluster} ne "true") {
		$wantcluster = $args{cluster_id} || $C->{cluster_id};
	}
	my $only_known = !(NMISNG::Util::getbool($args{only_known}, "invert")); # default is 1

	my $nmisng = new_nmisng();

	my %result;
	my @selectors = ( concept => "service", filter =>
										{ historic => 0,
											enabled => $only_known? 1 : undef, # don't care if not onlyknown
										} );
	if ($wantnode)
	{
		my $noderec = $nmisng->node(name => $wantnode);
		return %result if (!$noderec);

		push @selectors, ( "node_uuid" =>  $noderec->uuid,
											 "cluster_id" => $noderec->cluster_id,
		);
	}
	push @selectors, ("cluster_id" => $wantcluster) if ($wantcluster);
	push @selectors, ("data.service" => $wantservice ) if ($wantservice);


	# first find all inventory instances that match, as objects please,
	# then get the newest timed data for them
	my $result = $nmisng->get_inventory_model(@selectors,
																						class_name => NMISNG::Inventory::get_inventory_class("service"));
	if (my $error = $result->error)
	{
		$nmisng->log->error("failed to retrieve service inventory: $error");
		die "failed to retrieve service inventory: $error\n";
	}
	return %result if (!$result->count);

	my $objectresult = $result->objects; # we need objects
	if (!$objectresult->{success})
	{
		$nmisng->log->error("object access failed: $objectresult->{error}");
		die "object access failed: $objectresult->{error}\n";
	}

	my %nodeobjs;
	for my $maybe (@{$objectresult->{objects}})
	{
		# we need to check each node for being disabled if only_known is set
		# reason: historic isn't set on service inventories if the node is disabled
		if ($only_known)
		{
			my $thisnode = $nodeobjs{$maybe->node_uuid} || $nmisng->node(uuid => $maybe->node_uuid);
			next if (ref($thisnode) ne "NMISNG::Node"); # ignore unexpectedly orphaned service info
			$nodeobjs{$maybe->node_uuid} ||= $thisnode;

			next if (!NMISNG::Util::getbool($thisnode->configuration->{active}) # disabled node
							 or ( !$maybe->enabled ) ); # service disabled (both count with only_known)
		}

		my $semistaticdata = $maybe->data;
		my $timeddata = $maybe->get_newest_timed_data();
		next if (!$timeddata->{success} or !$timeddata->{time}); # no readings, not interesting

		my $thisserver = $maybe->cluster_id;

		# timed data is structured by/under subconcept, one subconcept 'service' used for services now
		my %goodies = ( (map { ($_ => $timeddata->{data}->{service}->{$_}) } (keys %{$timeddata->{data}->{service}})),
										(map { ($_ => $semistaticdata->{$_}) } (keys %{$semistaticdata})),
										node_uuid => $maybe->node_uuid
				);

		$result{ $maybe->cluster_id }->{ $semistaticdata->{service} }->{ $semistaticdata->{node} } = \%goodies;
		# figure out which graphs to offer as customgraphs:
		# every service has these so we don't regard them as customgraphs:
		# see NMISNG::collect_services() where the following '@servicegraphs' line of code is also used:
		my @servicegraphs = (qw(service service-response));

		my @customgraphs;
		if (ref($maybe->{_subconcepts}) eq "ARRAY")
		{
			# symmetric difference
			@customgraphs = NMISNG::Util::array_diff(@servicegraphs, @{ $maybe->{_subconcepts} });
		}
		else
		{
			@customgraphs = ();
		}
		$result{ $maybe->cluster_id }->{ $semistaticdata->{service} }->{ $semistaticdata->{node} }->{customgraphs} = \@customgraphs;
	}

	return %result;
}

# Check event is called after determining that something is back up!
# Check event checks if the given event exists - args are the DOWN event!
# if it exists it deletes it from the event state table/log
#
# and then calls notify with a new Up event including the time of the outage
# args: a LIVE sys object for the node, event(name), upevent (name, optional)
#  element, details and level are optional
sub checkEvent
{
	my (%args) = @_;
	my $S = $args{sys};
	my $nmisng = $S->nmisng;

	my $upevent = $args{upevent};   # that's the optional name of the up event to log

	$args{node_uuid} = $S->nmisng_node()->uuid;

	# create event with attributes we are looking for
	my $event = $nmisng->events->event( _id => $args{_id},
									   node_uuid => $args{node_uuid},
									   event => $args{event},
									   element => $args{element},
									   configuration => {group => $S->nmisng_node()->{'_configuration'}->{'group'}} );

	# only take the missing data from the db, that way our new details/level will
	# be used instead of what is in the db
	return $event->check( sys => $S,
												details => $args{details}, level => $args{level},
												upevent => $upevent );
};

# notify creates new events
# OR updates level changes for existing threshold/alert ones
# note that notify ignores any outage configuration.
#
# args: LIVE sys for this node, event(=name), element (optional),
# details, level (all optional), context (optional, deep structure)
# returns: nothing
sub notify
{
	my %args = @_;
	my $S = $args{sys};

	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $inventory_id = $args{inventory_id};
	my $conf = $args{conf};

	my $M = $S->mdl;
	my $node = $S->nmisng_node;
	my $nodename = $node->name;

	my $log;
	my $syslog;
	my $saveupdate = undef;

	my $C = $S->nmisng->config;
	$S->nmisng->log->debug2("Start of Notify");

	# events.nmis controls which events are active/logging/notifying
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events', conf => $conf);
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

	# create new event object with all properties, when load is called if it is found these will
	# be overwritten by the existing properties
	my $event_obj = $S->nmisng_node->event(event => $event, element => $element, configuration => {group => $S->nmisng_node()->{'_configuration'}->{'group'}});
	$event_obj->load();
	if ($event_obj->exists() && $event_obj->active )
	{
		# event exists, maybe a level change of proactive threshold?
		if ($event_obj->event =~ /Proactive|Alert\:/ )
		{
			if ($event_obj->level ne $level)
			{
				# change of level; must update the event record
				# note: 2014-08-27 keiths, update the details as well when changing the level
				$event_obj->level( $level );
				$event_obj->details( $details );
				$event_obj->context( $args{context} ) if( !$event_obj->context );

				(undef, $log, $syslog) = $event_obj->getLogLevel(sys=>$S);
				$details .= " Updated";

				$saveupdate = 1;
			}
		}
		else # not an proactive/alert event - no changes are supported
		{
			$S->nmisng->log->debug2("Event node=$nodename event=$event element=$element already exists");
		}
	}
	else
	{
		# event doesn't exist OR exists and is inactive (but not historic)
		 $event_obj->event( $event );
		 $event_obj->element( $element );
		 $event_obj->active( 1 );
		 $event_obj->level( $level );
		 $event_obj->details( $details );
		 $event_obj->context( $args{context} );

		# get level(if not defined) and log status from Model
		($level,$log,$syslog) = $event_obj->getLogLevel(sys=>$S);
		$event_obj->level($level);

		my $is_stateless = ($C->{non_stateful_events} !~ /$event/
												or NMISNG::Util::getbool($thisevent_control->{Stateful}))? 0: 1;
		$event_obj->stateless($is_stateless);

		my ($otg,$outageinfo) = NMISNG::Outage::outageCheck(node => $S->nmisng_node, time=>time());
		if ($otg eq 'current') {
			$details .= " outage_current=true change=$outageinfo->{change_id}";
			$event_obj->details( $details );
		}

		if (NMISNG::Util::getbool($C->{log_node_configuration_events})
				and $C->{node_configuration_events} =~ /$event/
				and NMISNG::Util::getbool($thisevent_control->{Log}))
		{
			my $error = logConfigEvent(dir => $C->{config_logs}, node=>$nodename, event=>$event, level=>$level,
																 element=>$element, details=>$details, host => $node->configuration->{host},
																 nmis_server => $C->{nmis_host}, nmisng => $S->nmisng );
			if ( $error )
			{
				$S->nmisng->log->error("log Config event failed: $error");
			}
		}
		# want a save, not update
		$saveupdate = 0;
	}

	# log events if allowed
	# and do it before save so we can log that this thing has been saved
	if ( NMISNG::Util::getbool($log) and NMISNG::Util::getbool($thisevent_control->{Log}))
	{
		# details get changed a bit for the log so pass them through
		$event_obj->log(details => $details);
	}

	# Create and store this new event; record whether stateful or not
	# a stateless event should escalate to a level and then be automatically deleted.
	# or update existing event (and skip add logic)
	my $error;
	$error = $event_obj->save( update => $saveupdate ) if( defined($saveupdate) );
	if ( $error )
	{
		$S->nmisng->log->error("notify failed: $error");
	}

	# Syslog must be explicitly enabled in the config and
	# is used only if escalation isn't
	if (NMISNG::Util::getbool($C->{syslog_events})
			and NMISNG::Util::getbool($syslog)
			and NMISNG::Util::getbool($thisevent_control->{Log})
			and !NMISNG::Util::getbool($C->{syslog_use_escalation}))
	{
		my $error = NMISNG::Notify::sendSyslog(
			server_string => $C->{syslog_server},
			facility => $C->{syslog_facility},
			nmis_host => $C->{server_name},
			time => time(),
			node => $nodename,
			event => $event,
			level => $level,
			element => $element,
			details => $details
				);

		$S->nmisng->log->error("sendSyslog failed: $error") if ($error);

	}
	return $event_obj;
	$S->nmisng->log->debug2("Notify Finished");
}


1;
