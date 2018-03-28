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

our $VERSION = "9.0.0A";

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

use Fcntl qw(:DEFAULT :flock);  # Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Data::Dumper;

$Data::Dumper::Indent = 1;			# fixme9: costs, should not be enabled

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
# returns: ref to one persistent nmisng object
sub new_nmisng
{
	my (%args) = @_;
	state ($_nmisng);

	if (ref($_nmisng) ne "NMISNG" or $args{nocache})
	{
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
				level => ( NMISNG::Log::parse_debug_level( debug => $args{debug},
																									 info => undef # fixme9, deprecated
									 ) // $C->{log_level} ),
				path  =>  ($args{debug}? undef : $logfile ),
					);
		}

		$_nmisng = NMISNG->new(config => $C, log => $logger);
	}
	return $_nmisng;
}

# load local nodes (only!)
# args: none
# returns: hash of node name -> node record
sub loadLocalNodeTable
{
	my $nmisng = new_nmisng();

	# ask the database for all of my nodes, ie. with my cluster id
	my $modelData = $nmisng->get_nodes_model( filter => { cluster_id => $nmisng->config->{cluster_id} } );
	my $data = $modelData->data();
	my %map = map { $_->{name} => $_ } @$data;
	return \%map;
}

# load all nodes, local and foreign
# args: none
# returns: hash of node name -> node record
sub loadNodeTable
{
	my $nmisng = new_nmisng();

	# ask the database for all noes, my cluster id and all others
	my $modelData = $nmisng->get_nodes_model();
	my $data = $modelData->data();

	my %map = map { $_->{name} => $_ } @$data;
	return \%map;
}

# returns hash (ref) of group name -> group name, for all active nodes
# fixme9: this should be an array
sub loadGroupTable
{
	my $allnodes = loadNodeTable;
	my %group2group = map { $_->{group} => $_->{group} } (grep(NMISNG::Util::getbool($_->{active}), values %$allnodes));
	return \%group2group;
}

# check if a table-ish file exists in conf (or conf-default)
# args: file name, relative, may be short w/o extension
# returns: 1 if file exists, 0 otherwise
sub tableExists
{
	my $table = shift;

	return (NMISNG::Util::existFile(dir=>"conf",
																	name=>$table)
					|| NMISNG::Util::existFile(dir=>"conf_default",
																		 name=>$table))? 1 : 0;
}

# load a table from conf (or conf-default)
# args: file name, relative, may be short w/o extension
# returns: hash ref of data
sub loadGenericTable
{
	my ($tablename) = @_;
	return NMISNG::Util::loadTable(dir => "conf", name => $tablename );
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
# returns: (array or hash)ref or undef on error
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
		NMISNG::Util::logMsg("ERROR, failed to load Table-$tablename");
		return undef;
	}
	return $goodies->{$tablename};
}


# fixme9: cannot work that way anymore
sub loadServersTable
{
	return {};
#	return NMISNG::Util::loadTable(dir=>'conf',name=>'Servers');
}

# fixme9: cannot work that way anymore
### 2011-01-06 keiths, loading node summary from cached files!
sub loadNodeSummary {
	my %args = @_;
	my $group = $args{group};
	my $master = $args{master};

	my $C = NMISNG::Util::loadConfTable();
	my $SUM;

	my $nodesum = "nmis-nodesum";
	# I should now have an up to date file, if I don't log a message
	if (NMISNG::Util::existFile(dir=>'var',name=>$nodesum) ) {
		NMISNG::Util::dbg("Loading $nodesum");
		my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			if ( $group eq "" or $group eq $NS->{$node}{group} ) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}

	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	# fixme9: config server_master is gone!
	if ( # NMISNG::Util::getbool($C->{server_master}) or
			 NMISNG::Util::getbool($master)) {
		NMISNG::Util::dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $slavenodesum = "nmis-$srv-nodesum";
			NMISNG::Util::dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (NMISNG::Util::existFile(dir=>'var',name=>$slavenodesum) ) {
				my $NS = NMISNG::Util::loadTable(dir=>'var',name=>$slavenodesum);
				for my $node (keys %{$NS}) {
					if ( $group eq "" or $group eq $NS->{$node}{group} ) {
						for (keys %{$NS->{$node}}) {
							$SUM->{$node}{$_} = $NS->{$node}{$_};
						}
					}
				}
			}
		}
	}
	return $SUM;
}




# this is the most official reporter of node status, and should be
# used instead of just looking at local system info nodedown
#
# reason for looking for events (instead of wmidown/snmpdown markers):
# underlying events state can change asynchronously (eg. fping), and the per-node status from the node
# file cannot be guaranteed to be up to date if that happens.
sub nodeStatus {
	my %args = @_;
	my ($catchall_data,$node) = @args{'catchall_data','node'};
	# die "nodeStatus requires catchall_data" if (!$catchall_data);
	die "nodestatus requries node" if (!$node);
	if( !$catchall_data )
	{
		my $inventory =  $node->inventory( concept => "catchall" );
		$catchall_data = $inventory->data();
	}
	my $C = NMISNG::Util::loadConfTable();


	# 1 for reachable
	# 0 for unreachable
	# -1 for degraded
	my $status = 1;

	my $node_down = "Node Down";
	my $snmp_down = "SNMP Down";
	my $wmi_down_event = "WMI Down";

	# ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if ( NMISNG::Util::getbool($catchall_data->{ping},"invert")
			and ( $node->eventExist($snmp_down) or $node->eventExist( $wmi_down_event)) )
	{
		$status = 0;
	}
	# ping enabled, but unpingable -> down
	elsif ( $node->eventExist($node_down) ) {
		$status = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( NMISNG::Util::getbool($catchall_data->{collect}) and
					( $node->eventExist($snmp_down)	or $node->eventExist($wmi_down_event)) )
	{
		$status = -1;
	}
	# let NMIS use the status summary calculations
	elsif (
		defined $C->{node_status_uses_status_summary}
		and NMISNG::Util::getbool($C->{node_status_uses_status_summary})
		and defined $catchall_data->{status_summary}
		and defined $catchall_data->{status_updated}
		and $catchall_data->{status_summary} <= 99
		and $catchall_data->{status_updated} > time - 500
			) {
		$status = -1;
	}
	else {
		$status = 1;
	}

	return $status;
}

# this is a variation of nodeStatus, which doesn't say why a node is degraded
# args: system object (doesn't have to be init'd with snmp/wmi)
# returns: hash of error (if dud args), overall (-1,0,1), snmp_enabled (0,1), snmp_status (0,1,undef if unknown),
# ping_enabled and ping_status, wmi_enabled and wmi_status
sub PreciseNodeStatus
{
	my (%args) = @_;
	my $S = $args{system};
	return ( error => "Invalid arguments, no Sys object!" ) if (ref($S) ne "NMISNG::Sys");

	my $node = $S->nmisng_node;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $C = NMISNG::Util::loadConfTable();

	my $nodename = $node->name;

	# reason for looking for events (instead of wmidown/snmpdown markers):
	# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
	# file cannot be guaranteed to be up to date if that happens.

	# HOWEVER the markers snmpdown and wmidown are present iff the source was enabled at the last collect,
	# and if collect was true as well.
	my %precise = ( overall => 1, # 1 reachable, 0 unreachable, -1 degraded
									snmp_enabled =>  defined($catchall_data->{snmpdown})||0,
									wmi_enabled => defined($catchall_data->{wmidown})||0,
									ping_enabled => NMISNG::Util::getbool($catchall_data->{ping}),
									snmp_status => undef,
									wmi_status => undef,
									ping_status => undef );

	$precise{ping_status} = ($node->eventExist("Node Down")?0:1) if ($precise{ping_enabled}); # otherwise we don't care
	$precise{wmi_status} = ($node->eventExist("WMI Down")?0:1) if ($precise{wmi_enabled});
	$precise{snmp_status} = ($node->eventExist("SNMP Down")?0:1) if ($precise{snmp_enabled});

	# overall status: ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (!$precise{ping_enabled}
			and ( ($precise{wmi_enabled} and !$precise{wmi_status})
						or ($precise{snmp_enabled} and !$precise{snmp_status}) ))
	{
		$precise{overall} = 0;
	}
	# ping enabled, but unpingable -> unreachable
	elsif ($precise{ping_enabled} && !$precise{ping_status} )
	{
		$precise{overall} = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( ($precise{wmi_enabled} and !$precise{wmi_status})
					or ($precise{snmp_enabled} and !$precise{snmp_status}) )
	{
		$precise{overall} = -1;
	}
	# let NMIS use the status summary calculations, if recently updated
	elsif ( defined $C->{node_status_uses_status_summary}
					and NMISNG::Util::getbool($C->{node_status_uses_status_summary})
					and defined $catchall_data->{status_summary}
					and defined $catchall_data->{status_updated}
					and $catchall_data->{status_summary} <= 99
					and $catchall_data->{status_updated} > time - 500 )
	{
		$precise{overall} = -1;
	}
	else
	{
		$precise{overall} = 1;
	}
	return %precise;
}

sub logConfigEvent {
	my %args = @_;
	my $dir = $args{dir};
	delete $args{dir};

	NMISNG::Util::dbg("logConfigEvent logging Json event for event $args{event}");
	my $event_hash = \%args;
	$event_hash->{startdate} = time;
	logJsonEvent(event => $event_hash, dir => $dir);
}

# sub getLevelLogEvent {
# }

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
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = NMISNG::Util::loadConfTable();
	NMISNG::rrdfunc::require_RRDs(config=>$C);

	# fixme9: server_master is gone, logic here is broken - must use cluster_id, not server name property!
	if ( # NMISNG::Util::getbool($C->{server_master}) and
			 $catchall_data->{server}
			 and lc($catchall_data->{server}) ne lc($C->{server_name}))
	{
		# send request to remote server
		NMISNG::Util::dbg("serverConnect to $catchall_data->{server} for node=$S->{node}");
		# fixme9: does not exist
		# return serverConnect(server=>$catchall_data->{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index,item=>$item);
	}

	my $db;
	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats;

	NMISNG::Util::dbg("Start type=$type, index=$index, start=$start, end=$end");

	# check if type exist in nodeInfo
	# fixme this cannot work - must CHECK existence, not make path blindly
	if (!($db = $S->makeRRDname(graphtype=>$type, index=>$index, item=>$item)))
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		#NMISNG::Util::logMsg("ERROR ($S->{name}) no rrd name found for type $type, index $index, item $item");
		return;
	}

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$type} eq "") {
		NMISNG::Util::logMsg("ERROR ($S->{name}) type=$type not found in section stats of model=$catchall_data->{nodeModel}");
		return;
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the PreciseNodeStatus workaround
		# to figure out if the right source is enabled
		my %status = PreciseNodeStatus(system => $S);
		# fixme unclear how to find the model's rrd section for this thing?

		my $severity = "INFO";
		NMISNG::Util::logMsg("$severity ($S->{name}) database=$db does not exist, snmp is "
												 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
												 .($status{wmi_enabled}?"enabled":"disabled") );
		return;
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	if( $index )
	{
		no strict;
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
			if ($s =~ /ERROR/) {
				NMISNG::Util::logMsg("ERROR ($S->{name}) model=$catchall_data->{nodeModel} type=$type ($str) in expanding variables, $s");
				return; # error
			}
			push @option, $s;
		}
	}
	if (NMISNG::Util::getbool($C->{debug})) {
		foreach (@option) {
			NMISNG::Util::dbg("option=$_",2);
		}
	}

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error())) {
		NMISNG::Util::logMsg("ERROR ($S->{name}) RRD graph error database=$db: $ERROR");
	} else {
		##NMISNG::Util::logMsg("INFO result type=$type, node=$catchall_data->{name}, $catchall_data->{nodeType}, $catchall_data->{nodeModel}, @$graphret");
		if ( scalar(@$graphret) ) {
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
				NMISNG::Util::dbg("name=$name, index=$index, value=$value",2);
				##NMISNG::Util::logMsg("INFO name=$name, index=$index, value=$value");
			}
			return \%summaryStats;
		} else {
			NMISNG::Util::logMsg("INFO ($S->{name}) no info return from RRD for type=$type index=$index item=$item");
		}
	}
	return;
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
# returns: hashref with numeric values - or undef if infty or nan
# args: inventory,subconcept,start,end,sys, all required
#   subconcept is used to find the storage (db) and also the section in the stats
#   file.
#  stats_section - if provided this will be used to look up the location of the stats
#   instead of subconcept. this is required for concepts like cbqos where the subconcept
#   name is variable and based on class names which come from the device
#
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
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $C = NMISNG::Util::loadConfTable();
	NMISNG::rrdfunc::require_RRDs(config=>$C);

	# fixme9: server_master is gone, logic here is broken - must use cluster_id, not server name property!
	if (# NMISNG::Util::getbool($C->{server_master}) and
			$catchall_data->{server}
			and lc($catchall_data->{server}) ne lc($C->{server_name}))
	{
		# send request to remote server
		NMISNG::Util::dbg("serverConnect to $catchall_data->{server} for node=$S->{node}");
		# fixme9: does not exist
		# return serverConnect(server=>$catchall_data->{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index);
	}

	my $db = $inventory->find_subconcept_type_storage( subconcept => $subconcept, type => 'rrd' );
	my $data = $inventory->data;
	my $index = $data->{index};

	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats; # return value

	NMISNG::Util::dbg("Start subconcept=$subconcept, index=$index, start=$start, end=$end");

	# check if storage exists
	if (!$db)
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		NMISNG::Util::logMsg("ERROR ($S->{name}) no rrd name found for subconcept $subconcept, index $index");
		return;
	}
	$db = $C->{database_root}.$db;

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$stats_section} eq "") {
		NMISNG::Util::dbg("($S->{name}) subconcept=$subconcept not found in section stats of model=$catchall_data->{nodeModel}, this may be expected");
		return;
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -f $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the PreciseNodeStatus workaround
		# to figure out if the right source is enabled
		my %status = PreciseNodeStatus(system => $S);
		# fixme unclear how to find the model's rrd section for this thing?

		my $severity = "INFO";
		NMISNG::Util::logMsg("$severity ($S->{name}) database=$db does not exist, snmp is "
												 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
												 .($status{wmi_enabled}?"enabled":"disabled") );
		return;
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	# NOTE: is there any reason we don't use parse string or some other generic function here?
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
			if ($s =~ /ERROR/) {
				NMISNG::Util::logMsg("ERROR ($S->{name}) model=$catchall_data->{nodeModel} subconcept=$subconcept ($str) in expanding variables, $s");
				return; # error
			}
			push @option, $s;
		}
	}

	if (NMISNG::Util::getbool($C->{debug})) {
		foreach (@option) {
			NMISNG::Util::dbg("option=$_",2);
		}
	}

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error()))
	{
		NMISNG::Util::logMsg("ERROR ($S->{name}) RRD graph error database=$db: $ERROR");
	}
	else
	{
		##NMISNG::Util::logMsg("INFO result subconcept=$subconcept, node=$catchall_data->{name}, $catchall_data->{nodeType}, $catchall_data->{nodeModel}, @$graphret");
		if ( scalar(@$graphret) )
		{
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

				NMISNG::Util::dbg("name=$name, index=$index, value=$value",2);
			}
			return \%summaryStats;
		}
		else
		{
			NMISNG::Util::logMsg("INFO ($S->{name}) no info return from RRD for subconcept=$subconcept index=$index");
		}
	}
	return;
}


### AS 9/4/01 added getGroupSummary for doing the metric stuff centrally!
### AS 24/5/01 fixed so that colors show for things which aren't complete
### also reweighted the metric to be reachability = %40, availability = %20
### and health = %40
### AS 16 Mar 02, implementing David Gay's requirement for deactiving
### a node, ie keep a node in nodes.csv but no collection done.
### AS 16 Mar 02, implemented configurable reachability, availability, health
### AS 3 Jun 02, fixed up blank dash, insert N/A for nasty things
### ehg 17 sep 02 add nan to the trap for nasty things
### ehg 17 sep 02 counted actual nodes down for summary display
sub getGroupSummary {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $start_time = $args{start};
	my $end_time = $args{end};
	my $include_nodes = $args{include_nodes} // 0;

	my @tmpsplit;
	my @tmparray;

	my $SUM = undef;
	my $reportStats;
	my %nodecount = ();
	my $node;
	my $index;
	my $cache = 0;
	my $filename;

	NMISNG::Util::dbg("Starting");
	my %summaryHash = ();
	my $nmisng = new_nmisng();
	my $group_by = ['node_config.group'];
	$group_by = undef if( !$group );

	my ($entries,$count,$error) = $nmisng->grouped_node_summary(
		filters => { 'node_config.group' => $group },
		group_by => $group_by,
		include_nodes => $include_nodes
	);

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

			my $nodeobj = $nmisng->node(name => $node);

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

	NMISNG::Util::dbg("Finished");
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



# fixme: az looks like this function should be reworked with
# or ditched in favour of nodeStatus() and PreciseNodeStatus()
# fixme: this also doesn't understand wmidown (properly)
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

			if ( $config->{server} eq $C->{server_name} ) {
				### 2013-08-20 keiths, check for SNMP Down if ping eq false.
				my $down_event = "Node Down";
				$down_event = "SNMP Down" if NMISNG::Util::getbool($config->{ping},"invert");
				$nodedown = $nodeobj->eventExist($down_event);

				($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());
			}
			else
			{
				$outage = $NS->{$node_name}{outage};
				if ( NMISNG::Util::getbool($NS->{$node_name}{nodedown}))
				{
					$nodedown = 1;
				}
			}

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

# fixme9: this  cannot work with nmis9. code is also unreachable.
# convert configuration files in dir conf to from 4  to NMIS8
sub convertConfFiles {

	my $C = NMISNG::Util::loadConfTable();

	my $ext = NMISNG::Util::getExtension(dir=>'conf');
	#==== check Nodes ====

	if (!NMISNG::Util::existFile(dir=>'conf',name=>'Nodes')) {
		my (%nodeTable, $NT, $error);
		# Load the old CSV first for upgrading to NMIS8 format
		if ( -r $C->{Nodes_Table} )
		{
			($error, %nodeTable) = NMISNG::CSV::loadCSV($C->{Nodes_Table},
																									$C->{Nodes_Key});
			if (!$error) {
				NMISNG::Util::dbg("Loaded $C->{Nodes_Table}");
				rename "$C->{Nodes_Table}","$C->{Nodes_Table}.old";
				# copy what we need
				foreach my $i (sort keys %nodeTable) {
					NMISNG::Util::dbg("update node=$nodeTable{$i}{node} to NMIS8 format");
					# new field 'name' and 'host' in NMIS8, update this field
					if ($nodeTable{$i}{node} =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
						$nodeTable{$i}{name} = sprintf("IP-%03d-%03d-%03d-%03d",${1},${2},${3},${4}); # default
						# it's an IP address, get the DNS name
						my $iaddr = inet_aton($nodeTable{$i}{node});
						if ((my $name  = gethostbyaddr($iaddr, AF_INET))) {
							$nodeTable{$i}{name} = $name; # oke
							NMISNG::Util::dbg("node=$nodeTable{$i}{node} converted to name=$name");
						} else {
							# look for sysName of nmis4
							if ( -f "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat" ) {
								my (%info,$name,$value);
								sysopen(DATAFILE, "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat", O_RDONLY);
								while (<DATAFILE>) {
									chomp;
									if ( $_ !~ /^#/ ) {
										($name,$value) = split "=", $_;
										$info{$name} = $value;
									}
								}
								close(DATAFILE);
								if ($info{sysName} ne "") {
									$nodeTable{$i}{name} = $info{sysName};
									NMISNG::Util::dbg("name=$name=$info{sysName} from sysName for node=$nodeTable{$i}{node}");
								}
							}
						}
					} else {
						$nodeTable{$i}{name} = $nodeTable{$i}{node}; # simple copy of DNS name
					}
					NMISNG::Util::dbg("result 1 update name=$nodeTable{$i}{name}");
					# only first part of (fqdn) name
					($nodeTable{$i}{name}) = split /\./,$nodeTable{$i}{name} ;
					NMISNG::Util::dbg("result update name=$nodeTable{$i}{name}");

					my $node = $nodeTable{$i}{name};
					$NT->{$node}{name} = $nodeTable{$i}{name};
					$NT->{$node}{host} = $nodeTable{$i}{host} || $nodeTable{$i}{node};
					$NT->{$node}{active} = $nodeTable{$i}{active};
					$NT->{$node}{collect} = $nodeTable{$i}{collect};
					$NT->{$node}{group} = $nodeTable{$i}{group};
					$NT->{$node}{netType} = $nodeTable{$i}{net} || $nodeTable{$i}{netType};
					$NT->{$node}{roleType} = $nodeTable{$i}{role} || $nodeTable{$i}{roleType};
					$NT->{$node}{depend} = $nodeTable{$i}{depend};
					$NT->{$node}{threshold} = $nodeTable{$i}{threshold} || 'false';
					$NT->{$node}{ping} = $nodeTable{$i}{ping} || 'true';
					$NT->{$node}{community} = $nodeTable{$i}{community};
					$NT->{$node}{port} = $nodeTable{$i}{port} || '161';
					$NT->{$node}{cbqos} = $nodeTable{$i}{cbqos} || 'none';

					$NT->{$node}{rancid} = $nodeTable{$i}{rancid} || 'false';
					$NT->{$node}{services} = $nodeTable{$i}{services} ;
					#	$NT->{$node}{runupdate} = $nodeTable{$i}{runupdate} ;
					$NT->{$node}{webserver} = 'false' ;
					$NT->{$node}{model} = $nodeTable{$i}{model} || 'automatic';
					$NT->{$node}{version} = $nodeTable{$i}{version} || 'snmpv2c';
					$NT->{$node}{timezone} = 0 ;
				}
				NMISNG::Util::writeTable(dir=>'conf',name=>'Nodes',data=>$NT);
				print " csv file $C->{Nodes_Table} converted to conf/Nodes.$ext\n";
			} else {
				NMISNG::Util::dbg("ERROR, could not find or read $C->{Nodes_Table} or empty node file");
			}
		} else {
			NMISNG::Util::dbg("ERROR, could not find or read $C->{Nodes_Table}");
		}
	}


	#====================

	if (!NMISNG::Util::existFile(dir=>'conf',name=>'Escalations')) {
		if ( -r "$C->{'Escalation_Table'}")
		{
			my ($error, %table_data)  = NMISNG::CSV::loadCSV($C->{'Escalation_Table'},
																											 $C->{'Escalation_Key'});
			foreach my $k (keys %table_data) {
				if (not exists $table_data{$k}{Event_Element}) {
					$table_data{$k}{Event_Element} = $table_data{$k}{Event_Details} ;
					delete $table_data{$k}{Event_Details};
				}
			}
			NMISNG::Util::writeTable(dir=>'conf',name=>'Escalations',data=>\%table_data);
			print " csv file $C->{Escalation_Table} converted to conf/Escalation.$ext\n";
			rename "$C->{'Escalation_Table'}","$C->{'Escalation_Table'}.old";
		} else {
			NMISNG::Util::dbg("ERROR, could not find or read $C->{'Escalation_Table'}");
		}
	}
	#====================

	convertFile('Contacts');

	convertFile('Locations');

	convertFile('Services');

	convertFile('Users');

	#====================

	sub convertFile {
		my $name = shift;
		my $C = NMISNG::Util::loadConfTable();
		if (!NMISNG::Util::existFile(dir=>'conf',name=>$name)) {
			if ( -r "$C->{\"${name}_Table\"}") {
				my ($error, %table_data) = NMISNG::CSV::loadCSV($C->{"${name}_Table"},
																												$C->{"${name}_Key"});

				NMISNG::Util::writeTable(dir=>'conf',name=>$name,data=>\%table_data);

				my $ext = NMISNG::Util::getExtension(dir=>'conf');
				print " csv file $C->{\"${name}_Table\"} converted to conf/${name}.$ext\n";
				rename "$C->{\"${name}_Table\"}","$C->{\"${name}_Table\"}.old";
			} else {
				NMISNG::Util::dbg("ERROR, could not find or read $C->{\"${name}_Table\"}");
			}
		}
	}
}


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


# load the info of a node
# if optional arg suppress_errors is given, then no errors are logged
sub loadNodeInfoTable
{
	my $node = lc shift;
	my %args = @_;

	return NMISNG::Util::loadTable(dir=>'var', name=>"$node-node",  suppress_errors => $args{suppress_errors});
}

# load info of all interfaces - fixme9: this is likely dead slow
# and wasteful (as it combines EVERYTHING) - should be replaced by much more targetted lookups!
sub loadInterfaceInfo
{
	my $nmisng = new_nmisng();

	my $get_node_uuids = $nmisng->get_node_uuids(
		filter => { cluster_id => $nmisng->config->{cluster_id}, active => 1, collect => 1 } );

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
sub dutyTime {
	my ($table , $contact) = @_;
	my $today;
	my $days;
	my $start_time;
	my $finish_time;

	if ( $$table{$contact}{DutyTime} ) {
		# dutytime has some values, so assume TZ offset to localtime has as well
		my @ltime = localtime( time() + ($$table{$contact}{TimeZone}*60*60));
		my $out = sprintf("Using corrected time %s for Contact:$contact, localtime:%s, offset:$$table{$contact}{TimeZone}", scalar localtime(time()+($$table{$contact}{TimeZone}*60*60)), scalar localtime());
		NMISNG::Util::dbg($out);

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				NMISNG::Util::dbg("returning success on dutytime test for $contact");
				return 1;
			}
			elsif ( $finish_time < $start_time ) {
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					NMISNG::Util::dbg("returning success on dutytime test for $contact");
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		NMISNG::Util::dbg("No dutytime defined - returning success assuming $contact is 24x7");
		return 1;
	}
	NMISNG::Util::dbg("returning fail on dutytime test for $contact");
	return 0;		# dutytime was valid, but no timezone match, return false.
}



# create http for a clickable graph
sub htmlGraph {
	my %args = @_;
	my $graphtype = $args{graphtype};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $server = $args{server};

	my $target = $node;
	if ($node eq "" and $group ne "") {
		$target = $group;
	}

	my $id = uri_escape("$target-$intf-$graphtype"); # both node and intf are unsafe
	my $C = NMISNG::Util::loadConfTable();

	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $win_width = $C->{win_width}; # window size
	my $win_height = $C->{win_height};

	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);
	my $urlsafeintf = uri_escape($intf);

	my $time = time();
	my $clickurl = "$C->{'node'}?act=network_graph_view&graphtype=$graphtype&group=$urlsafegroup&intf=$urlsafeintf&server=$server&node=$urlsafenode";


	if( NMISNG::Util::getbool($C->{display_opcharts}) ) {
		my $graphLink = "$C->{'rrddraw'}?act=draw_graph_view&group=$urlsafegroup&graphtype=$graphtype&node=$urlsafenode&intf=$urlsafeintf&server=$server".
				"&start=&end=&width=$width&height=$height&time=$time";
		my $retval = qq|<div class="chartDiv" id="${id}DivId" data-chart-url="$graphLink" data-title-onclick='viewwndw("$target","$clickurl",$win_width,$win_height)' data-chart-height="$height" data-chart-width="$width"><div class="chartSpan" id="${id}SpanId"></div></div>|;
	}
	else {
		my $src = "$C->{'rrddraw'}?act=draw_graph_view&group=$urlsafegroup&graphtype=$graphtype&node=$urlsafenode&intf=$urlsafeintf&server=$server".
				"&start=&end=&width=$width&height=$height&time=$time";
		### 2012-03-28 keiths, changed graphs to come up in their own Window with the target of node, handy for comparing graphs.
		return 	qq|<a target="Graph-$target" onClick="viewwndw(\'$target\',\'$clickurl\',$win_width,$win_height)">
<img alt='Network Info' src="$src"></img></a>|;
	}
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
	my $confname = $args{conf};

	return "" if (!$node);
	$refresh = "false" if (!NMISNG::Util::getbool($refresh));

	my @out;

	# fixme9: still need this for status, which hasn't been switched to inventory just yet
	my $NI = loadNodeInfoTable($node);
	# note, not using live data beause this isn't used in collect/update
	my $catchall_data = $S->inventory( concept => 'catchall')->data();
	my $nmisng_node = $S->nmisng_node;

	my $C = NMISNG::Util::loadConfTable();

	return unless $AU->InGroup($catchall_data->{group});

	# fixme9: logic wrong, must check cluster_id, not server name property
	my $server =  $catchall_data->{server}; # fixme9: gone NMISNG::Util::getbool($C->{server_master}) ? '' : $catchall_data->{server};
	my $urlsafenode = uri_escape($node);

	push @out, "<table class='table'><tr>\n";

	# provide link back to the main dashboard if not in widget mode
	push @out, CGI::td({class=>"header litehead"}, CGI::a({class=>"wht", href=>$C->{'nmis'}."?conf=$confname"},
																												"NMIS $Compat::NMIS::VERSION"))
			if (!NMISNG::Util::getbool($widget));

	push @out, CGI::td({class=>'header litehead'},'Node ',
										 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_node_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},$node));

	if ($S->getTypeInstances(graphtype => 'service', section => 'service')) {
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"services"));
	}

	if (NMISNG::Util::getbool($catchall_data->{collect})) {
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_status_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"status"))
				if defined $NI->{status} and defined $C->{display_status_summary}
		and NMISNG::Util::getbool($C->{display_status_summary});
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_all&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"interfaces"))
				if (defined $S->{mdl}{interface});
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_act&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"active intf"))
				if defined $S->{mdl}{interface};

		# this should potentially be querying for active/not-historic
		my $ids = $S->nmisng_node->get_inventory_ids( concept => 'interface' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_port_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ports"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_storage_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"storage"));
		}
		# this should potentially be querying for active/not-historic
		$ids = $S->nmisng_node->get_inventory_ids( concept => 'storage' );
		# adding services list support, but hide the tab if the snmp service collection isn't working
		if ( @$ids > 0 )
		{
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"service list"));
		}
		if ($S->getTypeInstances(graphtype => "hrsmpcpu")) {
			push @out, CGI::td({class=>'header litehead'},
												 CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_cpu_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"cpu list"));
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
					push @out, CGI::li(CGI::a({ class=>'wht',  href=>"network.pl?conf=$confname&act=network_system_health_view&section=$sysHealth&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"}, $sysHealth));
				}
			}
			push @out, "</ul></li></ul></td>";
		}
	}

	push @out, CGI::td({class=>'header litehead'},
										 CGI::a({class=>'wht',href=>"events.pl?conf=$confname&act=event_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"events"));
	push @out, CGI::td({class=>'header litehead'},
										 CGI::a({class=>'wht',href=>"outages.pl?conf=$confname&act=outage_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"outage"));


	# and let's combine these in a 'diagnostic' menu as well
	push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>Diagnostic &#x25BE<ul>";

	# drill-in for the node's collect/update time
	push @out, CGI::li(CGI::a({class=>"wht",
														 href=> "$C->{'<cgi_url_base>'}/node.pl?conf=$confname&act=network_graph_view&widget=false&node=$urlsafenode&graphtype=polltime",
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
														 href=>"tools.pl?conf=$confname&act=tool_system_ping&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ping"))
			if NMISNG::Util::getbool($C->{view_ping});
	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?conf=$confname&act=tool_system_trace&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"trace"))
			if NMISNG::Util::getbool($C->{view_trace});
	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?conf=$confname&act=tool_system_mtr&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"mtr"))
			if NMISNG::Util::getbool($C->{view_mtr});

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"tools.pl?conf=$confname&act=tool_system_lft&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"lft"))
			if NMISNG::Util::getbool($C->{view_lft});

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"http://$catchall_data->{host}",target=>'_blank'},"http"))
			if NMISNG::Util::getbool($catchall_data->{webserver});
	# end of diagnostic menu
	push @out, "</ul></li></ul></td>";

	if ($catchall_data->{server} eq $C->{server_name}) {
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Contacts&key=".uri_escape($catchall_data->{sysContact})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"contact"))
				if $catchall_data->{sysContact} ne '';
		push @out, CGI::td({class=>'header litehead'},
											 CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Locations&key=".uri_escape($catchall_data->{sysLocation})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"location"))
				if $catchall_data->{sysLocation} ne '';
	}

	push @out, "</tr></table>";

	return @out;
}

sub loadPortalCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C =	NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $portalCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Portal") ) {
		# portal menu of nodes or clients to link to.
		my $P = NMISNG::Util::loadTable(dir=>'conf',name=>"Portal");

		my $portalOption;

		foreach my $p ( sort {$a <=> $b} keys %{$P} ) {
			# If the link is part of NMIS, append the config
			my $selected;

			if ( $P->{$p}{Link} =~ /cgi-nmis9/ ) {
				$P->{$p}{Link} .= "?conf=$conf";
			}

			if ( $ENV{SCRIPT_NAME} =~ /nmiscgi/ and $P->{$p}{Link} =~ /nmiscgi/ and $P->{$p}{Name} =~ /NMIS9/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /maps/ and $P->{$p}{Name} =~ /Map/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /ipsla/ and $P->{$p}{Name} eq "IPSLA" ) {
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
	my $conf = $args{conf};
	my $C = NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

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
			$serverOption .= qq|<option value="$ST->{$srv}{portal_protocol}://$ST->{$srv}{portal_host}:$ST->{$srv}{portal_port}$ST->{$srv}{cgi_url_base}/nmiscgi.pl?conf=$ST->{$srv}{config}">$ST->{$srv}{name}</option>\n|;
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
	my $conf = $args{conf};
	my $C = NMISNG::Util::loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $tenantCode;
	if  ( -f NMISNG::Util::getFileName(file => "$C->{'<nmis_conf>'}/Tenants") ) {
		# portal menu of nodes or clients to link to.
		my $MT = NMISNG::Util::loadTable(dir=>'conf',name=>"Tenants");

		my $tenantOption;

		$tenantOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Tenants">NMIS Tenants</option>\n|;

		foreach my $t ( sort {$MT->{$a}{Name} cmp $MT->{$b}{Name}} keys %{$MT} ) {
			# If the link is part of NMIS, append the config

			$tenantOption .= qq|<option value="?conf=$MT->{$t}{Config}">$MT->{$t}{Name}</option>\n|;
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
			<script src="$C->{'nmis_common'}" type="text/javascript"></script>
			<script src="$C->{'highstock'}" type="text/javascript"></script>
			<script src="$C->{'chart'}" type="text/javascript"></script>
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
			<script src="$C->{'highstock'}" type="text/javascript"></script>
			<script src="$C->{'chart'}" type="text/javascript"></script>
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
			<script src="$C->{'highstock'}" type="text/javascript"></script>
			<script src="$C->{'chart'}" type="text/javascript"></script>
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

### 2012-03-09 keiths, summary sub to avoid changing much other code
sub requestServer {
	return 0;
}

# Load and organize the CBQoS meta-data, used by both rrddraw.pl and node.pl
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
	# fixme9: this needs to  be reworked to use inventory for huwawei, too...
	my $NI = $S->compat_nodeinfo;

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
# args: service, node, cluster_id, only_known (all optional)
# if service or node are given, only matching services are returned.
# cluster_id defaults to the local one, and is IGNORED unless only_known is 0.
#
# only_known is 1 by default, which ensures that only locally known, active services
# listed in Services.nmis and attached to active nodes are returned.
#
# if only_known is set to zero, then all services, remote or local,
# active or not are returned.
#
# returns: hash of cluster_id -> service -> node -> data; empty if invalid args
sub loadServiceStatus
{
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();			# generally cached anyway

	my $wantnode = $args{node};
	my $wantservice = $args{service};
	my $wantcluster = $args{cluster_id} || $C->{cluster_id};
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
	if (!$result->{success})
	{
		$nmisng->log->error("failed to retrieve service inventory: $result->{error}");
		die "failed to retrieve service inventory: $result->{error}\n";
	}
	return %result if (!$result->{model_data}->count);

	my $objectresult = $result->{model_data}->objects; # we need objects
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
	}

	return %result;
}

# Check event is called after determining that something is back up!
# Check event checks if the given event exists - args are the DOWN event!
# if it exists it deletes it from the event state table/log
#
# and then calls notify with a new Up event including the time of the outage
# args: a LIVE sys object for the node, event(name);
#  element, details and level are optional
sub checkEvent
{
	my (%args) = @_;
	my $S = $args{sys};
	my $nmisng = $S->nmisng;

	$args{node_uuid} = $S->nmisng_node()->uuid;
	# create event with attributes we are looking for
	my $event = $nmisng->events->event( _id => $args{_id}, node_uuid => $args{node_uuid}, event => $args{event}, element => $args{element} );
	# only take the missing data from the db, that way our new details/level will
	# be used instead of what is in the db
	return $event->check( sys => $S, details => $args{details}, level => $args{level} );
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
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $M = $S->mdl;
	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};
	my $node = $S->{name};
	my $inventory_id = $args{inventory_id};
	my $log;
	my $syslog;
	my $saveupdate = undef;

	my $C = NMISNG::Util::loadConfTable();
	NMISNG::Util::dbg("Start of Notify");

	# events.nmis controls which events are active/logging/notifying
	my $events_config = NMISNG::Util::loadTable(dir => 'conf', name => 'Events');
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

	# create new event object with all properties, when load is called if it is found these will
	# be overwritten by the existing properties
	my $event_obj = $S->nmisng_node->event(event => $event, element => $element);
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
			NMISNG::Util::dbg("Event node=$node event=$event element=$element already exists");
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
			logConfigEvent(dir => $C->{config_logs}, node=>$node, event=>$event, level=>$level,
										 element=>$element, details=>$details, host => $catchall_data->{host},
										 nmis_server => $C->{nmis_host} );
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
		NMISNG::Util::logMsg("ERROR $error");
	}

	# Syslog must be explicitly enabled in the config and
	# is used only if escalation isn't
	if (NMISNG::Util::getbool($C->{syslog_events})
			and NMISNG::Util::getbool($syslog)
			and NMISNG::Util::getbool($thisevent_control->{Log})
			and !NMISNG::Util::getbool($C->{syslog_use_escalation}))
	{
		NMISNG::Notify::sendSyslog(
			server_string => $C->{syslog_server},
			facility => $C->{syslog_facility},
			nmis_host => $C->{server_name},
			time => time(),
			node => $node,
			event => $event,
			level => $level,
			element => $element,
			details => $details
				);
	}
	return $event_obj;
	NMISNG::Util::dbg("Finished");
}

# saves a given nodeconf data structure in the per-node nodeconf file
# args: node, data (required)
# data can be undef; in this case the nodeconf for this node is removed.
#
# returns: undef if ok, error message otherwise
sub update_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $data = $args{data};

	my $C = NMISNG::Util::loadConfTable();			# likely cached

	return "Cannot save nodeconf without nodename argument!"
			if (!$nodename);					# note: we don't check (yet) if the node is known

	return "Cannot save nodeconf for $nodename, data is missing!"
			if (!exists($args{data}));				# present but explicitely undef is ok

	my $nmisng = new_nmisng;

	my $node = $nmisng->node( name => $nodename );
	return if(!$node);

	# the deletion case
	if (!defined($data))
	{
		$node->overrides( {} );
		my $op = $node->save();
		return "Could not remove nodeconf for $nodename"
				if ($op < 1);
	}
	# we overwrite whatever may have been there
	else
	{
		delete $data->{name};
		$node->overrides( $data );
		my $op = $node->save();
		return "Error saving nodeconf for $nodename"
				if ($op < 1);
	}
	return;
}

# small helper that checks if a nodeconf record
# exists for the given node.
#
# args: node (required)
# returns: 1 if it has nodeconf, 0 if not, undef if the args are dud
sub has_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	return if (!$nodename);

	my $nmisng = new_nmisng;

	my $node = $nmisng->node( name => $nodename );
	return if(!$node);

	# overrides will always be a hashref
	my $overrides = $node->overrides();

	my @confkeys = keys %$overrides;
	return (@confkeys > 0) ? 1 : 0;
}

# returns the nodeconf record for one or all nodes
# args: node (optional)
# returns: (undef, hashref) or (errmsg, undef)
# if asked for a single node, then hashref is JUST the node's settings
# if asked for all nodes, then hashref is nodename => per-node-settings
sub get_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $nmisng = new_nmisng;

	if (exists($args{node}))
	{
		return "Cannot get nodeconf for unnamed node!" if (!$nodename);

		my $node = $nmisng->node( name => $nodename );
		my $overrides = $node->overrides();
		my @confkeys = keys %$overrides;
		return "No nodeconf exists for node $nodename!" if (@confkeys == 0);

		my $data = $overrides;
		return "Failed to read nodeconf for $nodename!"
				if (ref($data) ne "HASH");

		return (undef, $data );
	}
	else
	{
		my %allofthem;

		my $cands = $nmisng->get_node_uuids();
		for my $uuid (@$cands)
		{
			my $node = $nmisng->node( uuid => $uuid );
			my $overrides = $node->overrides();

			if (ref($overrides) ne "HASH" or !keys %$overrides )
			{
				NMISNG::Util::logMsg("ERROR nodeconf $uuid had invalid data! Skipping.");
				next;
			}

			# structure is real_nodename => data for this node
			$allofthem{$node->configuration()->{name}} = $overrides;
		}
		return (undef, \%allofthem);
	}
}


# this is now a backwards-compatibilty wrapper around get_nodeconf()
sub loadNodeConfTable
{
	my ($error, $data) = get_nodeconf;
	if ($error)
	{
		NMISNG::Util::logMsg("ERROR get_nodeconf failed: $error");
		return {};
	}
	return $data;
}

1;
