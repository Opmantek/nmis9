#!/usr/bin/perl
#
#  Copyright 1999-2018 Opmantek Limited (www.opmantek.com)
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
# a command-line node administration tool for NMIS 9
use strict;
our $VERSION = "9.4.2.1";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use Getopt::Long;
use File::Spec;
use Data::Dumper;
use JSON::XS;
use Mojo::File;
use Term::ReadKey;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Outage;
use NMISNG::Auth;
use Compat::NMIS;

my $PROGNAME = basename($0);
my $debugsw = 0;
my $helpsw = 0;
my $quietsw = 0;
my $usagesw = 0;
my $versionsw = 0;

 die unless (GetOptions('debug:i'    => \$debugsw,
                        'help'       => \$helpsw,
                        'quiet'      => \$quietsw,
                        'usage'      => \$usagesw,
                        'version'    => \$versionsw));

# For the Version mode, just print it and exit.
if (${versionsw}) {
	print "$PROGNAME version=$VERSION; NMIS Version=$NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir, debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH" or !keys %$config);
my $server_role = $config->{'server_role'};
my $usage;
if ($server_role eq "POLLER") {
	
	$usage = "Usage: $PROGNAME act=<action to take> [options...]

\t$PROGNAME act=dump {node=<node_name>|uuid=<nodeUUID>} file=<path> [everything=<[0|t]/[1|f]>]
\t$PROGNAME act={list|list_uuid} {node=<node_name>|uuid=<nodeUUID>|group=<group_name>} [wantpoller=<[0|t]/[1|f]>]
\t$PROGNAME act=restore file=<path> [localise_ids=<[0|t]/[1|f]>]
\t$PROGNAME act=show {node=<node_name>|uuid=<nodeUUID>} 

restore: restores a previously dumped node's data. if 
 localise_ids=true (default: false), then the cluster id is rewritten
 to match the local nmis installation.
 
This server is a $server_role. This is why the number of actions is restricted.

OPTIONS:
debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9> sets debugging verbosity.
quiet=<true|false|yes|no> avoids printing unnecessary data.

Run $PROGNAME -h for detailed help.
\n\n";
} else {
	$usage = "Usage: $PROGNAME act=<action to take> [options...]

\t$PROGNAME act=clean-node-events {node=<node_name>|uuid=<nodeUUID>} 
\t$PROGNAME act=create file=<someFile.json> [server={<server_name>|<cluster_id>}]
\t$PROGNAME act=delete {node=<node_name>|uuid=<nodeUUID>|group=<group_name>} [server={<server_name>|<cluster_id>}] [deletedata=<[0|t]/[1|f]>] confirm=YES
\t$PROGNAME act=dump {node=<node_name>|uuid=<nodeUUID>} file=<path> [everything=<[0|t]/[1|f]>]
\t$PROGNAME act=export [format=<nodes>] [file=<path>] {node=<node_name>|uuid=<nodeUUID>|group=<group_name>} [keep_ids=<[0|t]/[1|f]>]
\t$PROGNAME act=import file=<somefile.json>
\t$PROGNAME act=import_bulk {nodes=<filepath>|nodeconf=<dirpath>} [nmis9_format=<[0|t]/[1|f]>]
\t$PROGNAME act={list|list_uuid} {node=<node_name>|uuid=<nodeUUID>|group=<group_name>} [file=<someFile.json>] [format=json]
\t$PROGNAME act=mktemplate [placeholder=<[0|t]/[1|f]>]
\t$PROGNAME act=move-nmis8-rrd-files {node=<node_name>|ALL|uuid=<nodeUUID>} [remove_old=<[0|t]/[1|f]>] [force=<[0|t]/[1|f]>]
\t$PROGNAME act=remove-duplicate-events [dryrun=<[0|t]/[1|f]>]
\t$PROGNAME act=rename {old=<node_name>|uuid=<nodeUUID>} new=<new_name> [entry.<key>=<value>...]
\t$PROGNAME act=restore file=<path> [localise_ids=<[0|t]/[1|f]>]
\t$PROGNAME act=set {node=<node_name>|uuid=<nodeUUID>} entry.<key>=<value>... [server={<server_name>|<cluster_id>}]
\t$PROGNAME act=show {node=<node_name>|uuid=<nodeUUID>} 
\t$PROGNAME act=update file=<someFile.json> [server={<server_name>|<cluster_id>}]
\t$PROGNAME act=validate-node-inventory [concept=<concept_name>] [dryrun=<[0|t]/[1|f]>] [make_historic=<[0|t]/[1|f]>]

mktemplate: prints blank template for node creation,
 optionally with __REPLACE_XX__ placeholder

create: requires file=NewNodeDef.json
update: updates existing node from file=someFile.json
 If no uuid is present, a new node will be created.
 If a property is not set, it will be removed.
 Use set to replace only one property.

export: exports to file=someFile (or STDOUT if no file given),
 nmis9 format by default or legacy format (nmis8) if format=nodes is given
 perl hash if format=nodes and file=*.nmis (nmis extension), otherwise json
 uuid and cluster_id are NOT exported unless keep_ids is true.

import-bulk: By default, will import nmis8 format nodes
  
delete: only deletes if confirm=yes (in uppercase) is given,
 if deletedata=true (default) then RRD files for a node are
 also deleted.

show: prints a node's properties in the same format as set
 with option quoted=true, show adds double-quotes where needed
 with option interfaces=true show interface basic information
 with option inventory=true dumps all the inventory data
 with option catchall=true dumps just the inventory catchall data
 
set: adjust one or more node properties

restore: restores a previously dumped node's data. if 
 localise_ids=true (default: false), then the cluster id is rewritten
 to match the local nmis installation.

OPTIONS:
debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9> sets debugging verbosity.
quiet=<true|false|yes|no> avoids printing unnecessary data.

server: Will update the node in the remote pollers.
  It is important to use this argument for remotes.

Run $PROGNAME -h for detailed help.

\n\n";
}

if ($usagesw) {
   print($usage);
   exit(0);
}

if (!@ARGV || !$cmdline->{act})
{
    help();
    exit(0);
}

my $debug   = $debugsw;
my $quiet   = $quietsw;
$debug      = $cmdline->{debug}                                            if (exists($cmdline->{debug}));   # Backwards compatibility
$quiet      = NMISNG::Util::getbool_cli("quiet", $cmdline->{quiet}, 0)     if (exists($cmdline->{quiet}));   # Backwards compatibility

# For audit 
my $me = getpwuid($<);

# log to stderr if debug is given
my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
							 debug => $cmdline->{debug}) // $config->{log_level},
							 path  => (defined $cmdline->{debug})? undef : $logfile);

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);


# import from nmis8 nodes file, overwriting existing data in the db
if ($cmdline->{act} =~ /^import[_-]bulk$/
		&& (my $nodesfile = $cmdline->{nodes}) && $server_role ne "POLLER")
{
	die "invalid nodes file $nodesfile argument!\n" if (!-f $nodesfile);

	$logger->info("Starting bulk import of nodes");
	my $nmis9_format = NMISNG::Util::getbool_cli("nmis9_format", $cmdline->{nmis9_format}, 0);
	my $delay = $cmdline->{delay} // 300;
	my $bulk_number = $cmdline->{bulk_number};
	my $total_bulk = 0;
	
	# old-style nodes file: hash. export w/o format=nodes: plain array,
	# readfiletohash doesn't understand arrays.
	my $node_table = NMISNG::Util::readFiletoHash(file => $nodesfile,
																								json => ($nodesfile =~ /\.json$/i));
	$node_table = decode_json(Mojo::File->new($nodesfile)->slurp) if (ref($node_table) ne "HASH");

	my %stats = (created => 0, updated => 0);

	foreach my $onenode ( ref($node_table) eq "HASH"? values %$node_table : @$node_table )
	{
		$total_bulk++;
		# note that this looks up the node by uuid, exclusively. if the nodes file has dud uuids,
		# then existing nodes will NOT be found.
		my $node = $nmisng->node( uuid => $onenode->{uuid} || NMISNG::Util::getUUID($onenode->{name}),
															create => 1 );
		++$stats{ $node->is_new? "created":"updated" };
		$logger->debug(($node->is_new? "creating": "updating")." node $onenode->{name}");

		# any node on this system must have this system's cluster_id.
		$onenode->{cluster_id} = $config->{cluster_id};

		# and OVERWRITE the configuration
		my $curconfig = $node->configuration; # almost entirely empty when new

		if ($nmis9_format) {
			for my $copyable (grep($_ !~ /^(_id|uuid|cluster_id|name|activated|lastupdate|overrides|configuration|aliases|addresses)$/,
													 keys %{$onenode->{configuration}}))
			{
				$curconfig->{$copyable} = $onenode->{configuration}->{$copyable} if (exists $onenode->{configuration}->{$copyable});
			}
		} else {
			# not all attribs go under configuration!
			for my $copyable (grep($_ !~ /^(_id|uuid|cluster_id|name|activated|lastupdate|overrides|configuration|aliases|addresses)$/,
													 keys %$onenode))
			{
				$curconfig->{$copyable} = $onenode->{$copyable} if (exists $onenode->{$copyable});
			}
		}
		
		$node->configuration($curconfig);
		# Validate node data
		#validate_node_data(node => $onenode);
		# Validate name
		if (!$onenode->{uuid}) {
			my $nodeobj = $nmisng->node(name => $onenode->{name});
			if ($nodeobj) {
				$logger->info("Node ". $onenode->{name} . " already exist." );
				--$stats{ $node->is_new? "created":"updated" };
				next;
			}
		}
		# the first two top-level keepers are set on new, but nothing else is
		for my $mustset (qw(cluster_id name))
		{
			$node->$mustset($onenode->{$mustset}) if (exists($onenode->{$mustset}));
		}
		# these two must be hashes
		for my $mustset (qw(overrides activated))
		{
			$node->$mustset($onenode->{$mustset}) if (ref($onenode->{$mustset}) eq "HASH");
		}

		my $meta = {
				what => "Import bulk",
				who => $me,
				where => $node->name,
				how => "node_admin",
				details => "Import node " . $node->name
		};
		# and save
		my ($op,$error) = $node->save();
		if($op <= 0)									# zero is no saving needed
		{
			$logger->error("Error saving node ".$node->name.": $error");
			warn("Error saving node ".$node->name.": $error\n");
		}
		else
		{
			$logger->debug( $node->name." saved to database, op: $op" );
		}
		if ($bulk_number) {
			if ($bulk_number == $total_bulk) {
				$total_bulk = 0;
				print "$bulk_number reached. Sleeping $delay seconds. \n";
				sleep($delay);
			}
		}
	}
	$logger->info("Bulk import complete, newly created $stats{created}, updated $stats{updated} nodes");
	exit 0;
}
# import nmis9 node configuration export
elsif ($cmdline->{act} eq "import"
			&& (my $infile = $cmdline->{file}) && $server_role ne "POLLER")
{
	die "invalid file \"$infile\" argument!\n" if (!-f $infile);
	$logger->info("Starting import of nodes");

	# file can contain: one node hash, or array of X node hashes
	my $lotsanodes = decode_json(Mojo::File->new($infile)->slurp);
	die "invalid structure\n" if (ref($lotsanodes) !~ /^(HASH|ARRAY)$/);

	my %stats = (created => 0, updated => 0);

	foreach my $onenode ( ref($lotsanodes) eq "HASH"? ($lotsanodes) : @$lotsanodes )
	{
		my $nodeobj = $nmisng->node(name => $onenode->{name});
		die "Node ". $onenode->{name}." already exist.\n" if ($nodeobj && !$onenode->{uuid});
	
		my $node = $nmisng->node( uuid => $onenode->{uuid}
															|| NMISNG::Util::getUUID($onenode->{name}),
															create => 1 );
		++$stats{ $node->is_new? "created":"updated" };
		$logger->debug(($node->is_new? "creating": "updating")." node $onenode->{name}");
	
		# any node on this system must have this system's cluster_id.
		$onenode->{cluster_id} = $config->{cluster_id};
	
		for my $setme (qw(cluster_id name activated configuration overrides aliases addresses))
		{
			next if (!exists $onenode->{$setme});
			$node->$setme($onenode->{$setme});
		}
	
		my $meta = {
				what => "Import",
				who => $me,
				where => $node->name,
				how => "node_admin",
				details => "Import node " . $node->name
		};
		my ($op,$error) = $node->save(meta => $meta);
		
		# and save
		my ($op,$error) = $node->save();
		if($op <= 0)									# zero is no saving needed
		{
			$logger->error("Error saving node ".$node->name.": $error");
			warn("Error saving node ".$node->name.": $error\n");
		}
		else
		{
			$logger->debug( $node->name."(".$node->uuid.") saved to database, op: $op" );
		}
	}
	$logger->info("Import complete, newly created $stats{created}, updated $stats{updated} nodes");
	print "Import complete, newly created $stats{created}, updated $stats{updated} nodes \n";
	exit 0;
}
# import nmis8 nodeconf overrides
elsif ($cmdline->{act} =~ /^import[_-]bulk$/
			 && (my $nodeconfdir = $cmdline->{nodeconf}) && $server_role ne "POLLER" )
{
	die "invalid nodeconf directory $nodeconfdir!\n" if (!-d $nodeconfdir);

	$logger->info( "Starting bulk import of node-conf overrides");

	opendir( D, $nodeconfdir ) or die "Cannot open nodeconf dir $nodeconfdir: $!\n";
	my @cands = grep( /^[a-z0-9_-]+\.json$/, readdir(D) );
	closedir(D);

	die "No nodeconfig data in $nodeconfdir!\n" if (!@cands);

	my $counter = 0;
	for my $maybe (@cands)
	{
		my $data = NMISNG::Util::readFiletoHash( file => "$nodeconfdir/$maybe", json => 1 );
		if ( ref($data) ne "HASH" or !keys %$data or !$data->{name} )
		{
			$logger->error("nodeconf $nodeconfdir/$maybe had invalid data! Skipping.");
			next;
		}

		# get the node, don't create it, it must exist already
		my $node_name = $data->{name};
		my $node = $nmisng->node( name => $node_name );
		if ( !$node )
		{
			$logger->error("cannot import nodeconf for $data->{name} because node does not exist! Skipping.");
			next;
		}

		++$counter;
		
		# don't bother saving the name in it
		delete $data->{name};
		$node->overrides($data);

		my $meta = {
				what => "Import bulk",
				who => $me,
				where => $node_name,
				how => "node_admin",
				details => "Import node " . $node_name
		};
		my ($op,$error) = $node->save(meta => $meta);
		$logger->error("Error saving node: ",$error) if ($op <= 0); # zero is no saving needed

		$logger->debug( "imported nodeconf for $node_name, overrides saved to database, op: $op" );
	}

	$logger->info("Bulk import complete, updated overrides for $counter nodes");
	exit 0;
}
if ($cmdline->{act} =~ /^list([_-]uuid)?$/)
{
	# list the nodes in existence - possibly with uuids.
	# iff a node or group arg is given, then only matching nodes are included
	my $wantuuid   = $1 // $cmdline->{wantuuid} // 0;;
	my $wantpoller = $cmdline->{wantpoller} // 0;
	my $quiet      = $cmdline->{quiet};
	my $format      = $cmdline->{format};
	my $file      = $cmdline->{file};

	# no node, no group => export all of them
	die "File \"$file\" already exists, NOT overwriting!\n" if (defined $file && $file ne "-" && -f $file);

	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDOUT;
	}
	else
	{
		open($fh,">$file") or die "cannot write to $file: $!\n";
	}

	# returns a modeldata object
	my $nodelist = $nmisng->get_nodes_model(name => $cmdline->{node}, uuid => $cmdline->{uuid}, group => $cmdline->{group}, fields_hash => { name => 1, uuid => 1, cluster_id => 1});
	if (!$nodelist or !$nodelist->count)
	{
		print STDERR "No matching nodes exist.\n" # but not an error, so let's not die
				if (!$quiet);
		exit 1;
	}
	else
	{
		if ( !$quiet && -t \*STDOUT && !$format) {
			if ($wantuuid && $wantpoller)
			{
				print $fh("Node UUID                               Node Name                                      Poller\n===================================================================================================================\n");
			}
			elsif ($wantuuid && !$wantpoller)
			{
				print $fh("Node UUID                               Node Name\n=================================================================\n");
			}
			elsif (!$wantuuid && $wantpoller)
			{
				print $fh("Node Name                                      Poller\n===================================================================================================================\n");
			}
			else
			{
				print $fh("Node Names:\n===================================================\n");
			}
		}		
		my %remotes;

		if ($wantpoller) {
			my $remotelist = $nmisng->get_remote();
			%remotes = map {$_->{'cluster_id'} => $_->{'server_name'}} @$remotelist;
			$remotes{$config->{cluster_id}} = "local";
			print("Remotes: " . Dumper(%remotes) . "\n") if ($cmdline->{debug} >1);;
		}

		my @nodeDataList = sort { $a->{name} cmp $b->{name} } (@{$nodelist->data});
		print("Node Data: " .  Dumper(@nodeDataList) . "\n") if ($cmdline->{debug} >1);
		if($format eq "json")
		{
			my $output = ();
			foreach my $nodeData (@nodeDataList)
			{
				my $node = {
					name =>  $nodeData->{name}
				};
				$node->{uuid} = $nodeData->{uuid} if($wantuuid);
				$node->{cluster_id} = $nodeData->{cluster_id} if($wantpoller);
				push @$output, $node;
			}
			print $fh JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode( $output);
		}
		else 
		{
			foreach my $nodeData (@nodeDataList)
			{
				print("Node: " . Dumper($nodeData) . "\n") if ($cmdline->{debug} >1);;
				if ($wantuuid && $wantpoller)
				{
					printf $fh ("%s    %s  %s\n", $nodeData->{uuid}, substr("$nodeData->{name}                                             ", 0, 45), $remotes{$nodeData->{cluster_id}});
				}
				elsif ($wantuuid && !$wantpoller)
				{
					printf $fh ("%s    %s\n", $nodeData->{uuid}, $nodeData->{name});
				}
				elsif (!$wantuuid && $wantpoller)
				{
					printf $fh ("%s  %s\n", substr("$nodeData->{name}                                             ", 0, 45), $remotes{$nodeData->{cluster_id}});
				}
				else
				{
					printf $fh ("%s\n", $nodeData->{name});
				}
			}
		}
	}
	exit 0;
}
elsif ($cmdline->{act} eq "export")
{
	my ($node,$uuid, $group,$file,$wantformat,$keep_ids) = @{$cmdline}{"node","uuid","group","file","format","keep_ids"};

	# no node, no group => export all of them
	die "File \"$file\" already exists, NOT overwriting!\n" if (defined $file && $file ne "-" && -f $file);

	my $nodemodel = $nmisng->get_nodes_model(name => $node, group => $group, uuid => $uuid);
	die "No matching nodes exist\n" if (!$nodemodel->count);

	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDOUT;
	}
	else
	{
		open($fh,">$file") or die "cannot write to $file: $!\n";
	}
	# array of hashes, 1 or more
	my $allofthem = $nodemodel->data;
	# ...except that the _id doesn't do us any good on export
	map { delete $_->{_id}; } (@$allofthem);
	# by default remove cluster_id and uuid because multi-polling is not yet supported, this helps
	# prevent users from creating a scenario that is not-yet-supported
	if(!NMISNG::Util::getbool_cli("keep_ids", $keep_ids, 0))
	{
		map { delete $_->{cluster_id}; delete $_->{uuid} } (@$allofthem);
	}

	# ensure that overrides are untranslated from db-safe format
	for my $entry (@$allofthem)
	{
		for my $uglykey (keys %{$entry->{overrides}})
		{
			# must handle compat/legacy load before correct structure in db
			if ($uglykey =~ /^==([A-Za-z0-9+\/=]+)$/)
			{
				my $nicekey = Mojo::Util::b64_decode($1);
				$entry->{overrides}->{$nicekey} = $entry->{overrides}->{$uglykey};
				delete $entry->{overrides}->{$uglykey};
			}
		}
	}


	# ...and if format=nodes is requested, ditch the nodeconf overrides and dummy addresses as well
	# nodes.nmis is a hash of nodename => FLAT record
	if (defined($wantformat) && $wantformat eq "nodes")
	{
		map { delete $_->{overrides}; delete $_->{addresses}; } (@$allofthem);
		my %compathash = map { ($_->{name} => $_) } (@$allofthem);
		for my $flattenme (values %compathash)
		{
			for my $confprop (keys %{$flattenme->{configuration}})
			{
				$flattenme->{$confprop} = $flattenme->{configuration}->{$confprop};
			}
			delete $flattenme->{configuration};
			$flattenme->{active} = $flattenme->{activated}->{NMIS};
			delete $flattenme->{activated};
		}

		# export in nodes layout, but in nmis/perl format or json?
		# stdout: perl default, also for anything.nmis
		print $fh (($file && $file =~ /^(-|.+\.nmis)$/i)?
							 Data::Dumper->new([\%compathash],[qw(*hash)])->Sortkeys(1)->Dump
							 : JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode(\%compathash));
	}
	else
	{
		# if just one node was wanted then we write a hash; in all other cases
		# we write the array
		my $which = ($node && !ref($node) && @$allofthem == 1)? $allofthem->[0] : $allofthem;

		# ensure that the output is indeed valid json, utf-8 encoded
		print $fh JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode( $which);
	}
	close $fh if ($fh != \*STDOUT);

	print STDERR "Successfully exported node configuration to file $file\n" if ($fh != \*STDOUT);
	exit 0;
}
elsif  ($cmdline->{act} eq "dump")
{
	my ($nodename, $uuid, $file) = @{$cmdline}{"node","uuid","file"}; # uuid is safer than node name
	die "Cannot dump node data without node/uuid and file arguments!\n" if (!$file || (!$nodename && !$uuid));
	my %options = (NMISNG::Util::getbool_cli("everything", $cmdline->{everything}, 0)
								? (historic_events => 1, opstatus_limit => undef, rrd => 1 )
								: ( historic_events => 0, opstatus_limit => 1000, rrd => 0));
	my $res = $nmisng->dump_node(name => $nodename,
															 uuid => $uuid,
															 target => $file,
															 options => \%options);
	die "Failed to dump node data: $res->{error}\n" if (!$res->{success});

	print STDERR "Successfully dumped node data to file $file\n" if (!$quiet);
	exit 0;
}
elsif  ($cmdline->{act} eq "restore")
{
	my $file = $cmdline->{"file"};
	my $localiseme = NMISNG::Util::getbool_cli("localise_ids", $cmdline->{localise_ids}, 0);
	
	my $meta = {
			what => "Restore node",
			who => $me,
			how => "node_admin",
			details => "Restore node "
	};
	
	my $res = $nmisng->undump_node(source  => $file, localise_ids => $localiseme );
	die "Failed to restore node data: $res->{error}\n" if (!$res->{success});

	print STDERR "Successfully restored node $res->{node}->{name} ($res->{node}->{uuid})\n"
			if (!$quiet);
	
	NMISNG::Util::audit_log(who => $me,
						what => "restored node",
						where => "restored node $res->{node}->{name}",
						how => "node_admin",
						details => "Restore node ". $res->{node}->{name},
						when => time)
	if ($res->{success});
	
	exit 0;
}
elsif ($cmdline->{act} eq "show")
{
	my ($node, $uuid, $server) = @{$cmdline}{"node","uuid","server"}; # uuid is safer
	my $wantquoted = NMISNG::Util::getbool_cli("quoted", $cmdline->{quoted}, 0);
	my $wantinterfaces = NMISNG::Util::getbool_cli("interfaces", $cmdline->{interfaces}, 0);
	my $wantinventory = NMISNG::Util::getbool_cli("inventory", $cmdline->{inventory}, 0);
	my $wantcatchall = NMISNG::Util::getbool_cli("catchall", $cmdline->{catchall}, 0);

	die "Cannot show node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if  looked up via uuid

	# we want the true structure, unflattened
	my $dumpables = { };
	for my $alsodump (qw(configuration overrides name cluster_id uuid activated unknown aliases addresses enterprise_service_tags))
	{
		$dumpables->{$alsodump} = $nodeobj->$alsodump;
	}

	my ($error, %flatearth) = NMISNG::Util::flatten_dotfields($dumpables,"entry");
	die "failed to transform output: $error\n" if ($error);
	for my $k (sort keys %flatearth)
	{
		my $val = $flatearth{$k};
		# any special-ish characters to quote?
		print "$k=". ($wantquoted && $flatearth{$k} =~ /['"\$\s\(\)\{\}\[\]]/?
									"\"$flatearth{$k}\"": $flatearth{$k})."\n";
	}
	if ($wantinventory) {
		my $md = $nmisng->get_inventory_model(node_uuid => $nodeobj->uuid);
		if (my $error = $md->error)
		{
			print "failed to lookup inventory records: $error \n";
		}
	
		for my $oneinv (@{$md->data})
		{
			print $oneinv->{'concept'}.".description: " . $oneinv->{'description'} . "\n";
			foreach my $key (%{$oneinv->{'data'}}) {
				if (ref($oneinv->{'data'}->{$key}) ne "ARRAY" and ref($oneinv->{'data'}->{$key}) ne "HASH"
					and ref($key) ne "ARRAY" and ref($key) ne "HASH" and defined($oneinv->{'data'}->{$key})) {
						if ($oneinv->{'data'}->{index}) {
							print $oneinv->{'concept'}.".$key.".$oneinv->{'data'}->{index}.": ".$oneinv->{'data'}->{$key}. "\n";
						} else {
							print $oneinv->{'concept'}.".$key: ".$oneinv->{'data'}->{$key}. "\n";
						}
						
				}
			}
		}
	}
	elsif ($wantcatchall) {
		my $md = $nmisng->get_inventory_model(node_uuid => $nodeobj->uuid, concept => 'catchall');
		if (my $error = $md->error)
		{
			print "failed to lookup inventory records: $error \n";
		}
		for my $oneinv (@{$md->data})
		{
			print "catchall.description: " . $oneinv->{'description'} . "\n";
			foreach my $key (%{$oneinv->{'data'}}) {
				if (ref($oneinv->{'data'}->{$key}) ne "ARRAY" and ref($oneinv->{'data'}->{$key}) ne "HASH"
					and ref($key) ne "ARRAY" and ref($key) ne "HASH" and defined($oneinv->{'data'}->{$key})) {
						print "catchall.$key: ".$oneinv->{'data'}->{$key}. "\n";
				}
			}
		}
	}
	elsif ($wantinterfaces)
	{
		my $md = $nmisng->get_inventory_model(node_uuid => $nodeobj->uuid, concept => 'interface');
		if (my $error = $md->error)
		{
			print "failed to lookup inventory records: $error \n";
		}
		for my $oneinv (@{$md->data})
		{
			print "Interface=\"".$oneinv->{'data'}->{'Description'}. "\" ifDescr=\"" . $oneinv->{'data'}->{'ifDescr'} ."\" ifIndex=" . $oneinv->{'data'}->{'ifIndex'} . "\n";
		}
	}
	exit 0;
}
elsif ($cmdline->{act} eq "set" && $server_role ne "POLLER")
{
	my ($node, $uuid, $server) = @{$cmdline}{"node","uuid","server"}; # uuid is safer

	die "Cannot set node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);
			
	my $schedule = $cmdline->{schedule} // 0; # Schedule by default? Yes
	my $time = $cmdline->{time} // time;
	my $priority = $cmdline->{priority} // $config->{priority_node_create}; # Default for this job?
	my $verbosity = $cmdline->{verbosity} // $config->{log_level};
	my $what = "set_nodes";
	my %jobargs;
		
	my @data = split(",", $node) if ($node);
	@data = split(",", $uuid) if ($uuid);
	
	my $nodes = join( '-', @data);
	my $meta = {
			what => "Set node",
			who => $me,
			where => $nodes,
			how => "node_admin",
			details => "Set node(s) " . $nodes
	};
	
	if ($schedule) {
		$jobargs{uuid} = \@data;
		$jobargs{data} = $cmdline;
		$jobargs{meta} = $meta;
		
		my ($error,$jobid) = $nmisng->update_queue(
				jobdata => {
					type => $what,
					time => $time,
					priority => $priority,
					verbosity => $verbosity,
					in_progress => 0,					# somebody else is to work on this
					args => \%jobargs });
		
		die "Failed to instantiate job! $error\n" if $error;
		print STDERR "Job $jobid created for type $what and ".@data." nodes.\n"
				if (-t \*STDERR);	
		
	} else {
	
		my $filter;
		if ($server) {
			my ($error, $server_data) = get_server( server => $server );
				die "Invalid server!\n" if ($error);
		}
		my $nodeobj = $nmisng->node(name => $node, uuid=> $uuid);
		if ($server and $nodeobj) {
			my $props = $nodeobj->unknown();
			$props->{status} = "update";
			$nodeobj->unknown($props);
		}
		die "Node $node does not exist.\n" if (!$nodeobj);
		$node ||= $nodeobj->name;			# if looked up via uuid
	
		die "Please use act=rename for node renaming!\n"
				if (exists($cmdline->{"entry.name"}));
	
		my $curconfig           = $nodeobj->configuration;
		my $curoverrides        = $nodeobj->overrides;
		my $curactivated        = $nodeobj->activated;
		my $curextras           = $nodeobj->unknown;
		my $curarraythings      = { aliases => $nodeobj->aliases, addresses => $nodeobj->addresses };
		my $updateOverrides     = 0;
		my $updateConfiguration = 0;
		my $updateActivated     = 0;
		my $updateAddresses     = 0;
		my $updateArrayThings   = 0;
		my $updateUnknown       = 0;
		my $anythingtodo;
	
		for my $name (keys %$cmdline)
		{
			next if ($name !~ /^entry\./); # we want only entry.thingy, so that act= and debug= don't interfere
			++$anythingtodo;
	
			my $value = $cmdline->{$name};
			undef $value if ($value eq "undef");
			$name =~ s/^entry\.//;
	
			# translate the backwards-compatibility configuration.active, which shadows activated.NMIS
			$name = "activated.NMIS" if ($name eq "configuration.active");
	
			# where does it go? overrides.X is obvious...
			if ($name =~ /^overrides\.(.+)$/)
			{
				$curoverrides->{$1} = $value;
				$updateOverrides    = 1;
			}
			# ...name, cluster_id a bit less...
			elsif ($name =~ /^(name|cluster_id)$/)
			{
				$nodeobj->$1($value);
			}
			# ...and activated.X not at all
			elsif ($name =~ /^activated\.(.+)$/)
			{
				$curactivated->{$1} = $value;
				$updateActivated    = 1;
			}
			# ...and then there's the unknown unknowns
			elsif ($name =~ /^unknown\.(.+)$/)
			{
				$curextras->{$1} = $value;
				$updateUnknown   = 1;
			}
			# and aliases and addresses, but these are ARRAYS
			elsif ($name =~ /^((aliases|addresses|enterprise_service_tags)\.(.+))$/)
			{
				$curarraythings->{$1} = $value;
				$updateArrayThings    = 1;
			}
			# configuration.X
			elsif ($name =~ /^configuration\.(.+)$/)
			{
				my $prop = $1;
				if ($name =~ /connect_options/) {
					my @value = split(',', $value);
					$curconfig->{$prop} = \@value;
				} else {
					$curconfig->{$prop} = $value;
				}
				$updateConfiguration = 1;
			}
			else
			{
				die "Unknown property \"$name\"!\n";
			}
		}
		die "No changes for node \"$node\"!\n" if (!$anythingtodo);
	
		for ([$curconfig, "configuration"],
				 [$curoverrides, "override"],
				 [$curactivated, "activated"],
				 [$curarraythings, "addresses/aliases/enterprise_service_tags" ],
				 [$curextras, "unknown/extras" ])
		{
			my ($checkwhat, $name) = @$_;
	
			# Don't waste overhead if nothing was changed.
			next if ($name eq "configuration"     && !$updateConfiguration);
			next if ($name eq "override"          && !$updateOverrides);
			next if ($name eq "activated"         && !$updateActivated);
			next if ($name eq "addresses/aliases" && !$updateArrayThings);
			next if ($name eq "unknown/extras"    && !$updateUnknown);

			#######################################
			# Ethernet Interfce with a Subinterface
			#######################################
			# If we have an Ethernet Interfce with a Subinterface, it will look like
			# 'GigabitEthernet2/1/13.1416', so we have to escape the key, but only
			# the first dot because if there are sub-properties being set, we want
			# those to be interpreted properly.
			### FIXME Do all Interfaces with dot delemited subinterfaces contain
			### FIXME the string 'Ethernet'? if not, the comparison in the loop
			### FIXME below will need to be expanded as we encounter them!

			my $new_hash = {};
			for my $key (keys %$checkwhat)
			{
				# substitution in key
				my $new_key = $key;
				if ($key =~ /.*Ethernet.*\.\d+.*/)
				{
					$new_key =~ s/\Q.\E/\Q\.\E/;
				}
				$new_hash->{$new_key} = $checkwhat->{$key};
			}
			print("new_hash: ". Dumper($new_hash) . "\n") if ($cmdline->{debug} >1);
			$checkwhat = $new_hash;

			#######################################
			# Ethernet Interfce with a Subinterface
			#######################################

			my $error = NMISNG::Util::translate_dotfields($checkwhat);
			die "translation of $name arguments failed: $error\n" if ($error);
		}
	
		$nodeobj->overrides($curoverrides) if ($updateOverrides);
		$nodeobj->configuration($curconfig) if ($updateConfiguration);
		$nodeobj->activated($curactivated) if ($updateActivated);
		$nodeobj->addresses($curarraythings->{addresses}) if ($updateArrayThings);
		$nodeobj->aliases($curarraythings->{aliases}) if ($updateArrayThings);
		$nodeobj->enterprise_service_tags($curarraythings->{enterprise_service_tags}) if ($updateArrayThings);
		$nodeobj->unknown($curextras) if ($updateUnknown);
		
		(my $op, $error) = $nodeobj->save(meta => $meta);
		die "Failed to save $node: $error\n" if ($op <= 0); # zero is no saving needed	
		
		print STDERR "Successfully updated node $node.\n"
			if (-t \*STDERR);								# if terminal
	}

	exit 0;
}
elsif ($cmdline->{act} eq "delete" && $server_role ne "POLLER")
{
	my ($node,$uuid,$group,$confirmation,$nukedata,$server) = @{$cmdline}{"node","uuid","group","confirm","deletedata", "server"};

	die "Cannot delete without node, uuid or group argument!\n\n$usage\n" if (!$node and !$group and !$uuid);
	die "NOT deleting anything:\nplease rerun with the argument confirm='YES' in all uppercase\n\n"
			if (!$confirmation or $confirmation ne "YES");

	my $file = $cmdline->{file};
	my $schedule = $cmdline->{schedule} // 0; # Schedule by default? Yes	
	
	my @nodes = split(",", $node);
	my @uuid = split(",", $uuid);
	my $nodes = (scalar(@nodes) > 0) ? join( '-', @nodes) : join( '-', @uuid);
	my $meta = {
			what => "Remove node",
			who => $me,
			where => $node . " " . $uuid,
			how => "node_admin",
			details => "Removed node(s) " . $node . " " . $uuid
	};
		
	if ($schedule) {
		
		die "No nodes to be removed" if (scalar(@nodes) == 0 and scalar(@uuid) == 0);
		
		# Support for node dump
		my $time = $cmdline->{time} // time;
		my $priority = $cmdline->{priority} // $config->{priority_node_create}; # Default for this job?
		my $verbosity = $cmdline->{verbosity} // $config->{log_level};
		my $keeprrds = $cmdline->{keeprrds} // $config->{keeprrds_on_delete_node} // 0;
		my $what = "delete_nodes";
		my %jobargs;
		
		$jobargs{node} = \@nodes if (scalar(@nodes) > 0);
		$jobargs{uuid} = \@uuid if (scalar(@uuid) > 0);
		
		$jobargs{keeprrds} = $keeprrds;
		$jobargs{meta} = $meta;
		
		my ($error,$jobid) = $nmisng->update_queue(
				jobdata => {
					type => $what,
					time => $time,
					priority => $priority,
					verbosity => $verbosity,
					in_progress => 0,					# somebody else is to work on this
					args => \%jobargs });
		
		die "Failed to instantiate job! $error\n" if $error;
		print STDERR "Job $jobid created for type $what and ".@nodes." nodes.\n"
				if (-t \*STDERR);	
		
	} else {
		my $server_data;
		if ($server) {
			(my $error, $server_data) = get_server(server => $server);
			die $error if ($error);
		}
		my $nodemodel = $nmisng->get_nodes_model(name => $node, uuid => $uuid, group => $group);
		die "No matching nodes exist\n" if (!$nodemodel->count);
		
		my $gimmeobj = $nodemodel->objects; # instantiate, please!
		die "Failed to instantiate node objects: $gimmeobj->{error}\n"
				if (!$gimmeobj->{success});
	
		for my $mustdie (@{$gimmeobj->{objects}})
		{
			# NODE FROM CATALOG
			if ($server and $mustdie) {
				# Update the node status
				my $props = $mustdie->unknown();
				$props->{status} = "delete";
				$mustdie->unknown($props);
				(my $op, $error) = $mustdie->save;
				die "Failed to mark for delete node: $error $op\n" if ($op <= 0); # zero is no saving needed

				print STDERR "Successfully marked for delete node ($op).\n"
						if (-t \*STDERR);			
			# NODE
			} else {
				# First, backup
				my $backup = $config->{'backup_node_on_delete'} // 1;
				my $backup_folder = $config->{'node_dumps_dir'} // $config->{'<nmis_var>'}."/node_dumps";
				if ( !-d $backup_folder )
				{
					mkdir( $backup_folder, 0700 ) or return die "Cannot create $backup_folder: $!";
				}
				my $res;
				
				if ($backup) {
					$res = $nmisng->dump_node(name => $mustdie->name,
										 uuid => $mustdie->uuid,
										 target => $backup_folder . "/".$mustdie->name.".zip",
										 override => 1);
										 #options => \%options);
				}
				if (!$backup || $res->{success}) {
					
					my ($ok, $error) = $mustdie->delete(keep_rrd => NMISNG::Util::getbool($nukedata, "invert"), meta => $meta); # === eq false
					die $mustdie->name.": $error\n" if (!$ok);
					print STDERR "Successfully deleted node $node $uuid.\n"
					if (-t \*STDERR);
				} else {
					die "Failed to backup node: ". $mustdie->name . " ". $res->{error};
				}
			}
		}
	}
	
	exit 0;
}
elsif ( $cmdline->{act} =~ /remove[-_]duplicate[-_]events/ ) {

    my $dryrun = NMISNG::Util::getbool_cli("dryrun", $cmdline->{dryrun}, 0 );
    my ($entries, undef, $error) = NMISNG::DB::aggregate(
                collection => $nmisng->events_collection,
                pre_count_pipeline => [
                        { '$group' => { '_id' => { 'node_uuid' => '$node_uuid', 'event' => '$event',
									'element' => '$element', 'active' => '$active' },
								'full_events' => { '$push' => '$$ROOT' }, 'count' => { '$sum' => 1 }}},
                        { '$match' => { 'count' => {'$gt' =>1 }, 'full_events.historic' => 0 }},
                        { '$sort' =>  { 'full_events.startdate' => -1 }}]);
    die "Cannot aggregate on event collection: $error" if ($error);

    my $totalCount   = scalar( @{$entries} );
    my $foundCount   = 0;
    my $updatedCount = 0;
    if ( $totalCount > 0 ) {
        foreach my $record ( @{$entries} ) {
            my $count   = $record->{count};
            my @events  = @{$record->{full_events}};
            for (my $i=1; $i<$count; $i++) {
			    my $eachEvent = $events[$i];
                my $historic = $eachEvent->{historic};
			    next if ($historic);
			    if ($cmdline->{debug} >1) {
			        if ($dryrun) {
			            print("Record would have been archived: " . Dumper($eachEvent) . "\n");
                        $foundCount++;
					} else {
			            print("Archiving Record: " . Dumper($eachEvent) . "\n");
				    }
				}
			    next if ($dryrun);
                my $id = $eachEvent->{_id};
                my $record = { historic => 1, enabled => 0, _made_historic_by => "node_admin" };
                my $result = NMISNG::DB::update(
                    collection => $nmisng->events_collection,
                    query      => NMISNG::DB::get_query(
                        and_part => { _id => $id },
                        no_regex => 1
                    ),
                    record   => $record,
                    freeform => 1
                );
                if ($result->{success}) {
                    print("Duplicate event '$id' was archived successfully.\n") if ($cmdline->{debug} >1);
                    $updatedCount++;
			    } else {
                    print("Error updating duplicate event record '$id', error type: $result->{error_type}, $result->{error} \n") if ($result->{error} );
                }
		    }
        }
        if ($dryrun) {
            print("'$foundCount' duplicate events would have been archived.\n");
        } else {
            print("'$updatedCount' duplicate events were archived successfully.\n");
        }
    }
    else {
        print("No duplicate events were found.\n");
    }
}
elsif ($cmdline->{act} eq "rename" && $server_role ne "POLLER")
{
	my ($old, $new, $uuid, $server) = @{$cmdline}{"old","new","uuid", "server"}; # uuid is safest for lookup

	die "Cannot rename node without old and new arguments!\n\n$usage\n"
			if ((!$old && !$uuid) || !$new);

	my $server_data;
	if ($server) {
			(my $error, $server_data) = get_server( server => $server );
				die "Invalid server!\n" if ($error);
	}
	my $nodeobj = $nmisng->node(uuid => $uuid, name => $old);

	# TODO: Mark for update with status
	die "Node $old does not exist.\n" if (!$nodeobj);
	$old ||= $nodeobj->name;			# if looked up via uuid

	my $meta = {
			what => "Rename node",
			who => $me,
			where => $uuid,
			how => "node_admin",
			details => "Rename node $uuid "
	};
	
	my ($ok, $msg) = $nodeobj->rename(new_name => $new, originator => "node_admin", server => $server_data->{id});
	die "$msg\n" if (!$ok);

	my $server = $cmdline->{server};
	if ($server) {
		my $props = $nodeobj->unknown();
		$props->{status} = "update";
		$nodeobj->unknown($props);
	}
	print STDERR "Successfully renamed node $cmdline->{old} to $cmdline->{new}.\n"
			if (-t \*STDERR);

	# any further property setting operations requested?
	if (my @todo =  grep(/^entry\..+/, keys %$cmdline))
	{
		my $curconfig = $nodeobj->configuration;
		my $curoverrides = $nodeobj->overrides;
		my $curactivated = $nodeobj->activated;

		for my $name (@todo)
		{
			my $value = $cmdline->{$name};
			$name =~ s/^entry\.//;

			if ($name =~ /^overrides\.(.+)$/)
			{
				$curoverrides->{$1} = $value;
			}
			elsif ($name =~ /^(name|cluster_id)$/)
			{
				$nodeobj->$1($value);
			}
			elsif ($name =~ /^activated\.(.+)$/)
			{
				$curactivated->{$1} = $value;
			}
			else
			{
				$curconfig->{$name} = $value;
			}
		}
		my $error = NMISNG::Util::translate_dotfields($curconfig);
		die "translation of config arguments failed: $error\n" if ($error);
		$error = NMISNG::Util::translate_dotfields($curoverrides);
		die "translation of override arguments failed: $error\n" if ($error);
		$error = NMISNG::Util::translate_dotfields($curactivated);
		die "translation of activated arguments failed: $error\n" if ($error);

		$nodeobj->overrides($curoverrides);
		$nodeobj->configuration($curconfig);
		$nodeobj->activated($curactivated);

		(my $op, $error) = $nodeobj->save(meta => $meta);
		die "Failed to save $new: $error\n" if ($op <= 0); # zero is no saving needed

		print STDERR "Successfully updated node $new.\n"
				if (-t \*STDERR);								# if terminal

	}
	exit 0;
}
elsif ($cmdline->{act} =~ /move[-_]nmis8[-_]rrd[-_]files/ && $server_role ne "POLLER")
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safest for lookup

	die "Cannot move files without node argument!\n\n$usage\n"
			if (!$node && !$uuid);
	
	my @nodestocheck;
	my $remove_old = $cmdline->{remove_old};
	my $force = $cmdline->{force};
	
	if ( $node eq "ALL" ) {
		
		my $filter->{"cluster_id"} = $config->{cluster_id};
		my $nodelist = $nmisng->get_nodes_model( filter => $filter, fields_hash => { name => 1, uuid => 1});
		if (!$nodelist or !$nodelist->count)
		{
			print STDERR "No matching nodes exist.\n" # but not an error, so let's not die
					if (!$quiet);
			exit 1;
		}
		else
		{
			my $allofthem = $nodelist->data;
			foreach my $n (@{$allofthem}) {
				if ($n->{name} =~ /[A-Z]/) {
					push @nodestocheck, $n->{name};
				}
			}
		}
	} else
	{
		push @nodestocheck, $node;
	}
	
	foreach my $n (@nodestocheck) {
		my $nodeobj = $nmisng->node(uuid => $uuid, name => $n);
		if (!$nodeobj) {
			print "Node $n does not exist.\n";
			last;
		}
		$node ||= $nodeobj->name;			# if looked up via uuid
	
		my $old = lc($n); 
		my $dir = $config->{database_root}. "/nodes/$old";
		my $newdir = $config->{database_root}. "/nodes/$n";
		
		my $total = NMISNG::Util::replace_files_recursive($dir, $n, $old, "rrd", $force);
		if ($remove_old and $total > 0)
		{
			my $output = `rm -r $dir`;
			print "Removed $dir: $output \n";
		}
		
		print STDERR "Successfully moved $total node rrd files $nodeobj->{name}.\n"
				if (-t \*STDERR and $total != 0);
	}
	

	exit 0;
}
elsif ($cmdline->{act} =~ /clean[-_]node[-_]events/)
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safest for lookup

	die "Cannot move files without node argument!\n\n$usage\n"
			if (!$node && !$uuid);
	
	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	if (!$nodeobj) {
		die "Node $node does not exist.\n";
	}
	$node ||= $nodeobj->name;			# if looked up via uuid
	
	my ($res) = $nodeobj->eventsClean();
	print "$node clean events returned error: $res \n" if ($res);
	print "$node events cleaned \n" if (!$res);
	exit 0;
}
# template is deeply structured, just like output of act=export (EXCEPT for act=export format=nodes)
elsif ($cmdline->{act} eq "mktemplate" && $server_role ne "POLLER")
{
	my $file = $cmdline->{file};
	die "File \"$file\" already exists, NOT overwriting!\n"
			if (defined $file && $file ne "-" && -f $file);

	my $withplaceholder = NMISNG::Util::getbool_cli("placeholder", $cmdline->{placeholder}, 0);

	my %mininode = ( map { my $key = $_; $key => ($withplaceholder?
																								"__REPLACE_".uc($key)."__" : "") }
									 (qw(name cluster_id uuid configuration.host configuration.group configuration.notes
configuration.community configuration.roleType configuration.netType configuration.location configuration.model activated.NMIS configuration.ping configuration.collect configuration.version configuration.port configuration.username configuration.authpassword configuration.authkey configuration.authprotocol configuration.privpassword configuration.privkey configuration.privprotocol configuration.threshold ))  );

	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDOUT;
	}
	else
	{
		open($fh,">$file") or die "cannot write to $file: $!\n";
	}
	my $error = NMISNG::Util::translate_dotfields(\%mininode);
	die "Failed to create node template: $error\n" if ($error);

	# ensure that the output is indeed valid json, utf-8 encoded
	print $fh JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode(\%mininode);
	close $fh if ($fh != \*STDOUT);

	print STDERR "Created minimal template ".($file and $file ne "-"? "in file $file.":".")
			."\nPlease see https://community.opmantek.com/display/opCommon/Common+Node+Properties for detailed descriptions of the properties.\n";

	exit 0;
}
# both create and update expect deeply structured inputs
elsif ($cmdline->{act} =~ /^(create|update)$/ && $server_role ne "POLLER")
{
	my $file = $cmdline->{file};
	my $schedule = $cmdline->{schedule} // 0; # Schedule by default? No
	my $server = $cmdline->{server}; # Server for remote nodes

	open(F, $file) or die "Cannot read $file: $!\n";
	my $nodedata = join('', grep( !m!^\s*//\s+!, <F>));
	close(F);

	# sanity check this first!
	die "Invalid node data, __REPLACE_... placeholders are still present!\n"
			if ($nodedata =~ /__REPLACE_\S+__/);

	# sanity check for server
	my $server_data;
	if ($server) {
		(my $error, $server_data) = get_server( server => $server );
		die "Invalid server!\n" if ($error);
	}
	
	my $mayberec;
	# check correct encoding (utf-8) first, fall back to latin-1
	$mayberec = eval { decode_json($nodedata); };
	$mayberec = eval { JSON::XS->new->latin1(1)->decode($nodedata); } if ($@);
	die "Invalid node data, JSON parsing failed: $@\n" if ($@);
	
	if ($server_data) {
		if ($mayberec->{cluster_id} && $server_data->{id} ne $mayberec->{cluster_id}) {
			die "Cluster and server mismatch!\n"
		} 
	}
	
	my $number = 0;

	my @node_names;	
	if (ref($mayberec) eq "ARRAY") {
		foreach my $node (@$mayberec) {
			validate_node_data(node => $node);
			# no uuid and creating a node? then we add one
			$node->{uuid} ||= NMISNG::Util::getUUID($node->{name}) if ($cmdline->{act} eq "create");
			push(@node_names,$node->{name});
			$number++;
		} 
	} else {
		validate_node_data(node => $mayberec);
		# no uuid and creating a node? then we add one
		$mayberec->{uuid} ||= NMISNG::Util::getUUID($mayberec->{name}) if ($cmdline->{act} eq "create");
		push(@node_names,$mayberec->{name});
		$number++;
	}

	my %jobargs;
	my $op = $cmdline->{act} eq "create" ? "create nodes" : "update nodes";
	my $names = join(",",@node_names);
	my $meta = {
			what => $op,
			who => $me,
			where => $names,
			how => "node_admin",
			details => "$op node ". $names
	};
	
	# Send job to the queue
	if ($schedule) {
		my $time = $cmdline->{time} // time;
		my $priority = $cmdline->{priority} // $config->{priority_node_create}; # Default for this job?
		my $verbosity = $cmdline->{verbosity} // $config->{log_level};
		my $what = $cmdline->{act} eq "create" ? "create_nodes" : "update_nodes";
		$jobargs{data} = $mayberec;
		$jobargs{server} = $server_data if ($server);
		$jobargs{meta} = $meta;
		
		my ($error,$jobid) = $nmisng->update_queue(
				jobdata => {
					type => $what,
					time => $time,
					priority => $priority,
					verbosity => $verbosity,
					in_progress => 0,					# somebody else is to work on this
					args => \%jobargs });
		
		die "Failed to instantiate job! $error\n" if $error;
		print STDERR "Job $jobid created for type $what and ".$number." nodes.\n"
				if (-t \*STDERR);	
		
	} else {
		my %query = $mayberec->{uuid}? (uuid => $mayberec->{uuid}) : (name => $mayberec->{name});
		my $nodeobj = $nmisng->node(%query);
		
		$nodeobj ||= $nmisng->node(uuid => $mayberec->{uuid}, create => 1, cluster_id => $server_data->{id});
		die "Failed to instantiate node object!\n" if (ref($nodeobj) ne "NMISNG::Node");
		
		my $isnew = $nodeobj->is_new;

		# must set overrides, activated, name/cluster_id, addresses/aliases, configuration;
		for my $mustset (qw(cluster_id name activated overrides configuration addresses aliases))
		{
			$nodeobj->$mustset($mayberec->{$mustset}) if (exists($mayberec->{$mustset}));
			delete $mayberec->{$mustset};
		}
		# if creating, add missing cluster_id for local operation
		$nodeobj->cluster_id($config->{cluster_id}) if ($cmdline->{act} eq "create" && !$nodeobj->cluster_id);
		
		# there should be nothing left at this point, anything that is goes into unknown()
		my %unknown = map { ($_ => $mayberec->{$_}) } (grep(!/^(configuration|lastupdate|uuid)$/,
																												keys %$mayberec));
		if ($server) {
			$unknown{status} =  $cmdline->{act} eq "create" ? "new" : "update";
			$nodeobj->cluster_id($server_data->{id}) if ($cmdline->{act} eq "create");
		}
		$nodeobj->unknown(\%unknown);
	
		my ($status,$msg) = $nodeobj->save(meta => $meta);
	
		# zero is no saving needed, which is not good here
		die "failed to ".($isnew? "create":"update")." node $mayberec->{uuid}: $msg\n" if ($status <= 0);
	
		my $name = $nodeobj->name;
		if (!$isnew) {
			$nmisng->events->cleanNodeEvents($nodeobj, "node_admin");
		}
		print STDERR "Successfully ".($isnew? "created":"updated")
				." node ".$nodeobj->uuid." ($name)\n\n"
				if (-t \*STDERR);								# if terminal
	}
}
elsif ( $cmdline->{act} =~ /validate[-_]node[-_]inventory/ ) {

    my $concept       = $cmdline->{concept} // "catchall";
    my $make_historic = NMISNG::Util::getbool_cli("make_historic", $cmdline->{make_historic}, 0);
    my $dryrun        = NMISNG::Util::getbool_cli("dryrun", $cmdline->{dryrun}, 0);
    die "concept not defined or not yet supported"
      if ( $concept !~ /^(catchall)$/ );
    my ( $entries, undef, $error ) = NMISNG::DB::aggregate(
        collection         => $nmisng->inventory_collection,
        count              => 0,
        pre_count_pipeline => [
            { '$match' => { "concept" => "catchall", "enabled" => 1} },
            {
                '$group' => {
                    '_id'    => '$node_uuid',
                    'count'  => { '$sum'      => 1 },
                    'broken' => { '$addToSet' => '$_id' }
                }
            },
            { '$sort'  => { 'lastupdate' => -1 } },
            { '$match' => { "count"      => { '$gt' => 1 } } },
        ]
    );

    die "Cannot aggregate on inventory collection: $error" if ($error);

    my $count = scalar( @{$entries} );
    if ( $count > 0 ) {
        if ( $make_historic == 1 ) {
            print("Making $count nodes $concept documents historic\n")
              if ( !$dryrun );
            print("Dryrun of making $count nodes $concept documents historic\n")
              if ($dryrun);
            foreach my $record ( @{$entries} ) {
                print("Working on $record->{_id}\n");
                my $broken = $record->{broken};
                #keep the first value
                shift(@{$broken});
                my $record = { historic => 1, enabled => 0, _made_historic_by => "node_admin" };
                $record = {} if ($dryrun);
                my $result = NMISNG::DB::update(
                    collection => $nmisng->inventory_collection,
                    query      => NMISNG::DB::get_query(
                        and_part => { _id => $broken },
                        no_regex => 1
                    ),
                    record   => { '$set' => $record },
                    freeform => 1,
                    multiple => 1
                );
                print(
"Success Matched: $result->{matched_records}, Updated: $result->{updated_records} \n"
                ) if ( $result->{success} );
                print(
"Error updating extra catchall records, error type: $result->{error_type}, $result->{error} \n"
                ) if ( $result->{error} );
            }
        }
        else {
            print(
"You have $count nodes with more than one catchall document, pass make_historic=true to fix\n"
            );
            foreach my $record ( @{$entries} ) {
                print("UUID: $record->{_id} Count: $record->{count}\n");
            }
        }

    }
    else {
        print("$concept looks normal\n");
    }
}


else
{
	# fallback: complain about the arguments
	die "Could not parse arguments!\n\n$usage\n";
}

sub validate_node_data
{
	my %args = @_;
	my $node = $args{node};
	my $name = $node->{name};
	
	die "Invalid node name \"$name\"\n"
			if ($name =~ /[^a-zA-Z0-9_\-\.]/);

	die "Invalid node data, not a hash!\n" if (ref($node) ne 'HASH');
	for my $mustbedeep (qw(configuration overrides activated))
	{
		die "Invalid node data, invalid structure for $mustbedeep!\n"
				if (exists($node->{$mustbedeep}) && ref($node->{$mustbedeep}) ne "HASH");
	}

	die "Invalid node data, does not have required attributes name, host and group\n"
			if (!$node->{name} or !$node->{configuration}->{host} or !$node->{configuration}->{group});

	die "Invalid node data, netType \"$node->{configuration}->{netType}\" is not known!\n"
			if (!grep($node->{configuration}->{netType} eq $_,
								split(/\s*,\s*/, $config->{nettype_list})));
	die "Invalid node data, roleType \"$node->{configuration}->{roleType}\" is not known!\n"
			if (!grep($node->{configuration}->{roleType} eq $_,
								split(/\s*,\s*/, $config->{roletype_list})));
	if ($node->{cluster_id}) {
		my $server_data = get_server(server => $node->{cluster_id});
		if (!$server_data) {
			die "Invalid cluster_id, this server does not exist!\n";
		}
	}
	
	# look up the node - ideally by uuid, fall back to name only if necessary
	my %query = $node->{uuid}? (uuid => $node->{uuid}) : (name => $node->{name});
	
	my $nodeobj = $nmisng->node(%query);
	die "Node $name does not exist.\n" if (!$nodeobj && $cmdline->{act} eq "update");
	die "Node $name already exist.\n" if ($nodeobj && $cmdline->{act} eq "create");

	die "Please use act=rename for node renaming.\nUUID "
			.$nodeobj->uuid." is already associated with name \"".$nodeobj->name."\".\n"
			if ($nodeobj and $nodeobj->name and $nodeobj->name ne $node->{name});
}

# Return the server data
# So the user can set up
sub get_server
{
	my %args = @_;
	my $server = $args{server};
	my $server_data->{id} = $nmisng->get_cluster_id(server_name => $server);
	if (!$server_data->{id}) {
		$server_data->{name} = $nmisng->get_server_name(cluster_id => $server);
		if (!$server_data->{name}) {
			return ("Invalid server!", undef);
		} else {
			$server_data->{id} = $server;
		}
	} else {
		$server_data->{name} = $server;
	}
	return (undef, $server_data);
}


###########################################################################
#  Help Function
###########################################################################
sub help
{
   my(${currRow}) = @_;
   my @{lines};
   my ${workLine};
   my ${line};
   my ${key};
   my ${cols};
   my ${rows};
   my ${pixW};
   my ${pixH};
   my ${i};
   my $IN;
   my $OUT;

   if ((-t STDERR) && (-t STDOUT)) {
      if (${currRow} == "")
      {
         ${currRow} = 0;
      }
      if ($^O =~ /Win32/i)
      {
         sysopen($IN,'CONIN$',O_RDWR);
         sysopen($OUT,'CONOUT$',O_RDWR);
      } else
      {
         open($IN,"</dev/tty");
         open($OUT,">/dev/tty");
      }
      ($cols, $rows, $pixW, $pixH) = Term::ReadKey::GetTerminalSize $OUT;
   }
   STDOUT->autoflush(1);
   STDERR->autoflush(1);

   push(@lines, "\n\033[1mNAME\033[0m\n");
   push(@lines, "       $PROGNAME -  Node Administration Command Line Interface.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] act=<command> <command-parameters>...\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program provides a command line interface for the NMIS\n");
   push(@lines, "       application. The program always expects an 'action' parameter specifying\n");
   push(@lines, "       what action is requested. Each action requires unique parameters\n");
   push(@lines, "       depending on the requirements of the action. There are also global\n");
   push(@lines, "       options accepted by all actions.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --debug[1-9]             - global option to print detailed messages\n");
   push(@lines, " --help                   - display command line usage\n");
   push(@lines, " --quiet                  - display no output\n");
   push(@lines, " --usage                  - display a brief overview of command syntax\n");
   push(@lines, " --version                - print a version message and exit\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     act=<command>        - The action command to invoke.  Each is described below.\n");
   push(@lines, "     <command-parameters> - One of more command parameters depending on the command.\n");
   push(@lines, "     [debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9>]\n");
   push(@lines, "     [quiet=<true|false|yes|no|1|0>]\n");
   push(@lines, "\n");
   push(@lines, "\033[1mEXIT STATUS\033[0m\n");
   push(@lines, "     The following exit values are returned:\n");
   push(@lines, "     0 Success\n");
   push(@lines, "     215 Failure\n\n");
   push(@lines, "\033[1mACTIONS\033[0m\n");
   push(@lines, "     act=clean-node-events node=<name>|uuid=<node_uuid>\n");
   push(@lines, "                     This action clears all events associated with\n");
   push(@lines, "                     the specified node.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=create file=<someFile.json>\n");
   push(@lines, "                             [server={<server_name>|<cluster_id>}]\n");
   push(@lines, "                     This action creates an NMIS Node from an NMIS\n");
   push(@lines, "                     template file.  Use 'mktemplate' to create a\n");
   push(@lines, "                     blank template.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=delete node=<name>|uuid=<node_uuid>|group=<group_name>\n");
   push(@lines, "                             [server={<server_name>|<cluster_id>}]\n");
   push(@lines, "                             [deletedata=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             confirm=YES\n");
   push(@lines, "                     This action deletes an existing NMIS node.\n");
   push(@lines, "                     It only deletes if confirm=YES (in uppercase)\n");
   push(@lines, "                     is given. if deletedata=true (default) then RRD\n");
   push(@lines, "                     files for a node are also deleted.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=dump node=<name>|uuid=<node_uuid> file=<path>\n");
   push(@lines, "                             [everything=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action dumps To a specified file but does\n");
   push(@lines, "                     not delete the node from the system.\n");
   push(@lines, "     act=export node=<name>|uuid=<node_uuid>|group=<group_name>\n");
   push(@lines, "                             [file=<path>]\n");
   push(@lines, "                             [format=<nodes|json>]\n");
   push(@lines, "                             [keep_ids=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action exports a node into the specified\n");
   push(@lines, "                     file (or STDOUT if no file given). It will\n");
   push(@lines, "                     export to nmis9 (json) format by default or\n");
   push(@lines, "                     legacy (nmis8 perl hash with an '.nmis'\n");
   push(@lines, "                     extension) if format='nodes' is specified The\n");
   push(@lines, "                     uuid and cluster_id are NOT exported unless\n");
   push(@lines, "                     'keep_ids' is true. Unlike 'dump', the node\n");
   push(@lines, "                     will be deleted from the system.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=import file=<somefile.json>\n");
   push(@lines, "                     This imports a file into the NMIS system.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=import_bulk {nodes=<filepath>|nodeconf=<dirpath>}\n");
   push(@lines, "                             [nmis9_format=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [delay=<n>] [bulk_number=<n>]\n");
   push(@lines, "                     This imports a file into the NMIS system. By\n");
   push(@lines, "                     By default, will import nmis8 format nodes\n");
   push(@lines, "                     unless 'nmis9_format' is true. If 'bulk_number'\n");
   push(@lines, "                     is set to an integer, then the import will sleep\n");
   push(@lines, "                     'delay' seconds (default 300) before continuing\n");
   push(@lines, "                     the import. This option is to avoid excessive\n");
   push(@lines, "                     overhead on the system.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=list (or list_uuid) [node=<name>|uuid=<node_uuid>|group=<group_name>]\n");
   push(@lines, "                             [wantpoller=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [wantuuid=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [file=<someFile.json>] [format=json]\n");
   push(@lines, "                     This action lists the nodes in the system. If called\n");
   push(@lines, "                     with 'list', only the node names will be listed. If\n");
   push(@lines, "                     'wantpoller' is true the poller is listed as well. If\n");
   push(@lines, "                     'wantuuid' is true the UUID is listed as well. If the\n");
   push(@lines, "                     'node', 'uuid', or 'group' argument is passed, the list\n");
   push(@lines, "                     will be limited to the matching nodes. If called as\n");
   push(@lines, "                     'list_uuid' the uuid flag is automatically set.\n");
   push(@lines, "                     If 'file' is specified, the output will be sent\n");
   push(@lines, "                     to a file. If 'format=json' is specified, the output\n");
   push(@lines, "                     will be formatted as a json document.\n");
   push(@lines, "     act=mktemplate file=<someFile.json> [placeholder=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This prints blank template for node creation,\n");
   push(@lines, "                     optionally with '__REPLACE_XX__' placeholder.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=move-nmis8-rrd-files {node=<node_name>|ALL|uuid=<nodeUUID>}\n");
   push(@lines, "                             [remove_old=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [force=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This moves old NMIS8 RRD files out of the active\n");
   push(@lines, "                     RRD Database directory.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=remove-duplicate-events [dryrun=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action finds and removes duplicate events.\n");
   push(@lines, "                     This is something that should not occur, but running\n");
   push(@lines, "                     multiple occurrances of the NMIS daemon has been known\n");
   push(@lines, "                     to create the condition. 'dryrun' reviews the events and\n");
   push(@lines, "                     simply reports what was found, but does not make any\n");
   push(@lines, "                     changes.\n");
   push(@lines, "     act=rename {old=<node_name>|uuid=<nodeUUID>} new=<new_name>\n");
   push(@lines, "                             [server={<server_name>|<cluster_id>}]\n");
   push(@lines, "                             [entry.<key>=<value>...]\n");
   push(@lines, "                     This action renames a node. The 'server' argument\n");
   push(@lines, "                     performs the action on the specified server.\n");
   push(@lines, "                     The optional 'entry' keywords perform 'set'\n");
   push(@lines, "                     functions.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=restore file=<path> [localise_ids=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action restores a previously 'dump'ed node\n");
   push(@lines, "                     from the specified file. If localise_ids=true\n");
   push(@lines, "                     (default: false), then the cluster id is\n");
   push(@lines, "                     rewritten to match the local nmis installation.\n");
   push(@lines, "     act=set {node=<node_name>|uuid=<nodeUUID>\n");
   push(@lines, "                             [server={<server_name>|<cluster_id>}]\n");
   push(@lines, "                             [entry.<key>=<value>...]\n");
   push(@lines, "                     This action sets parameters within the specified\n");
   push(@lines, "                     nodes. The 'server' argument performs the action\n");
   push(@lines, "                     on the specified server.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=show {node=<node_name>|uuid=<nodeUUID>}\n");
   push(@lines, "                             [catchall=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [interfaces=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [inventory=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [quoted=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action displays the attributes of the\n");
   push(@lines, "                     specified node.\n");
   push(@lines, "                     'catchall' dumps just the inventory catchall data.\n");
   push(@lines, "                     'interfaces' show interface basic information.\n");
   push(@lines, "                     'inventory' dumps all the inventory data.\n");
   push(@lines, "                     'quoted' adds double-quotes where needed.\n");
   push(@lines, "     act=update file=<someFile.json> [server={<server_name>|<cluster_id>}]\n");
   push(@lines, "                     This action updates an existing NMIS Node from an NMIS\n");
   push(@lines, "                     template file. If no uuid is present, a new node will\n");
   push(@lines, "                     be created. If a property is not set, it will be removed.\n");
   push(@lines, "                     Use 'set' to set or replace only one property.\n");
   push(@lines, "                     file.  Use 'mktemplate' to create a blank template.\n");
   push(@lines, "                     NOTE: This action cannot be run in a poller!\n");
   push(@lines, "     act=validate-node-inventory [concept=<concept_name>]\n");
   push(@lines, "                             [dryrun=<true|false|yes|no|1|0>]\n");
   push(@lines, "                             [make_historic=<true|false|yes|no|1|0>]\n");
   push(@lines, "                     This action validates a node's inventory for errors.\n");
   push(@lines, "                     If not specified, 'concept' defaults to 'catchall', which\n");
   push(@lines, "                     is currenty the only supported concept. 'dryrun' does the\n");
   push(@lines, "                     validation and simply reports what was found, but does\n");
   push(@lines, "                     not make any changes. 'make_historic' will move all.\n");
   push(@lines, "                     broken records to a historic status.\n");
   push(@lines, "     \n");
   push(@lines, "\033[1mEXAMPLES\033[0m\n");
   push(@lines, "   node_admin.pl act=list wantuuid=true wantpoller=yes\n");
   push(@lines, "   node_admin.pl act=list_uuid node=router1\n");
   push(@lines, "   node_admin.pl act=set node=router1 entry.configuration.collect=1 \n");
   push(@lines, "\n");
   push(@lines, "\n");
   print(STDERR "                       $PROGNAME - ${VERSION}\n");
   print(STDERR "\n");
   ${currRow} += 2;
   foreach (@lines)
   {
      if ((-t STDERR) && (-t STDOUT)) {
         ${i} = tr/\n//;  # Count the newlines in this string
         ${currRow} += ${i};
         if (${currRow} >= ${rows})
         {
            print(STDERR "Press any key to continue.");
            ReadMode 4, $IN;
            ${key} = ReadKey 0, $IN;
            ReadMode 0, $IN;
            print(STDERR "\r                          \r");
            if (${key} =~ /q/i)
            {
               print(STDERR "Exiting per user request. \n");
               return;
            }
            if ((${key} =~ /\r/) || (${key} =~ /\n/))
            {
               ${currRow}--;
            } else
            {
               ${currRow} = 1;
            }
         }
      }
      print(STDERR "$_");
   }
}


exit 0;

