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
our $VERSION = "9.1.1";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;
use Mojo::File;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS; 								# for nmisng::util::dbg, fixme9

my $bn = basename($0);

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
																					debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH"
																 or !keys %$config);
my $server_role = $config->{'server_role'};
my $usage;
if ($server_role eq "POLLER") {
	
	$usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act={list|list_uuid} {node=nodeX|uuid=nodeUUID} {wantpoller=0/1} [group=Y]
\t$bn act=show {node=nodeX|uuid=nodeUUID} 
\t$bn act=dump {node=nodeX|uuid=nodeUUID} file=path [everything=0/1]
\t$bn act=restore file=path [localise_ids=0/1]

restore: restores a previously dumped node's data. if 
 localise_ids=true (default: false), then the cluster id is rewritten
 to match the local nmis installation.
 
This server is a $server_role. This is why the number of actions is restricted.
\n\n";
} else {
	$usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act={list|list_uuid} {node=nodeX|uuid=nodeUUID} [group=Y]
\t$bn act=show {node=nodeX|uuid=nodeUUID} 
\t$bn act={create|update} file=someFile.json [server={server_name|cluster_id}]
\t$bn act=export [format=nodes] [file=path] {node=nodeX|uuid=nodeUUID|group=groupY} [keep_ids=0/1]
\t$bn act=import file=somefile.json
\t$bn act=import_bulk {nodes=filepath|nodeconf=dirpath} [nmis9_format=1]
\t$bn act=delete {node=nodeX|group=groupY|uuid=nodeUUID} [server={server_name|cluster_id}]
\t$bn act=dump {node=nodeX|uuid=nodeUUID} file=path [everything=0/1]
\t$bn act=restore file=path [localise_ids=0/1]

\t$bn act=set {node=nodeX|uuid=nodeUUID} entry.X=Y... [server={server_name|cluster_id}]
\t$bn act=mktemplate [placeholder=1/0]
\t$bn act=rename {old=nodeX|uuid=nodeUUID} new=nodeY [entry.A=B...]
\t$bn act=move-nmis8-rrd-files {node=nodeX|uuid=nodeUUID}

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
 uuid and cluster_id are NOT exported unless keep_ids is 1.

import-bulk: By default, will import nmis8 format nodes
  
delete: only deletes if confirm=yes (in uppercase) is given,
 if deletedata=true (default) then RRD files for a node are
 also deleted.

show: prints a node's properties in the same format as set
 with option quoted=true, show adds double-quotes where needed
 with option interfaces=true show interface basic information
set: adjust one or more node properties

restore: restores a previously dumped node's data. if 
 localise_ids=true (default: false), then the cluster id is rewritten
 to match the local nmis installation.

extras: debug={1..9,verbose} sets debugging verbosity
extras: info=1 sets general verbosity

server: Will update the node in the remote pollers.
  It is important to use this argument for remotes.

\n\n";
}
die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));


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
	my $nmis9_format = $cmdline->{nmis9_format};
	
	# old-style nodes file: hash. export w/o format=nodes: plain array,
	# readfiletohash doesn't understand arrays.
	my $node_table = NMISNG::Util::readFiletoHash(file => $nodesfile,
																								json => ($nodesfile =~ /\.json$/i));
	$node_table = decode_json(Mojo::File->new($nodesfile)->slurp) if (ref($node_table) ne "HASH");

	my %stats = (created => 0, updated => 0);

	foreach my $onenode ( ref($node_table) eq "HASH"? values %$node_table : @$node_table )
	{
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

		validate_node_data(node => $node);
		
		# don't bother saving the name in it
		delete $data->{name};
		$node->overrides($data);

		my ($op,$error) = $node->save();
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
	my $wantuuid = $1;
	my $wantpoller = $cmdline->{wantpoller} // 0;

	# returns a modeldata object
	my $nodelist = $nmisng->get_nodes_model(name => $cmdline->{node}, uuid => $cmdline->{uuid}, group => $cmdline->{group}, fields_hash => { name => 1, uuid => 1, cluster_id => 1});
	if (!$nodelist or !$nodelist->count)
	{
		print STDERR "No matching nodes exist.\n" # but not an error, so let's not die
				if (!$cmdline->{quiet});
		exit 1;
	}
	else
	{
		print($wantuuid? "Node UUID\tNode Name\n=========================\n" : $wantpoller? "Node UUID\tNode Name\tPoller\n=========================\n":"Node Names:\n===========\n")
				if (-t \*STDOUT); # if to terminal, not pipe etc.
				
		my %remotes;
		
		if ($wantpoller) {
			my $remotelist = $nmisng->get_remote();		
			%remotes = map {$_->{'cluster_id'} => $_->{'server_name'}} @$remotelist;
			$remotes{$config->{cluster_id}} = "local";
			print Dumper(%remotes);
		}
		print join("\n", map { ($wantuuid? ($_->{uuid}."\t".$_->{name}) : $wantpoller ? ($_->{uuid}."\t".$_->{name}."\t".$remotes{$_->{cluster_id}}) : $_->{name}) }
							 (sort { $a->{name} cmp $b->{name} } (@{$nodelist->data})) ),"\n";
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
	if( !$keep_ids )
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
	my %options = ($cmdline->{everything}? (historic_events => 1, opstatus_limit => undef, rrd => 1 )
								 : ( historic_events => 0, opstatus_limit => 1000, rrd => 0));
	my $res = $nmisng->dump_node(name => $nodename,
															 uuid => $uuid,
															 target => $file,
															 options => \%options);
	die "Failed to dump node data: $res->{error}\n" if (!$res->{success});

	print STDERR "Successfully dumped node data to file $file\n" if (!$cmdline->{quiet});
	exit 0;
}
elsif  ($cmdline->{act} eq "restore")
{
	my $file = $cmdline->{"file"};
	my $localiseme = NMISNG::Util::getbool($cmdline->{localise_ids});
	
	my $res = $nmisng->undump_node(source  => $file, localise_ids => $localiseme );
	die "Failed to restore node data: $res->{error}\n" if (!$res->{success});

	print STDERR "Successfully restored node $res->{node}->{name} ($res->{node}->{uuid})\n"
			if (!$cmdline->{quiet});
	exit 0;
}
elsif ($cmdline->{act} eq "show")
{
	my ($node, $uuid, $server) = @{$cmdline}{"node","uuid","server"}; # uuid is safer
	my $wantquoted = NMISNG::Util::getbool($cmdline->{quoted});
	my $wantinterfaces = NMISNG::Util::getbool($cmdline->{interfaces});

	die "Cannot show node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if  looked up via uuid

	# we want the true structure, unflattened
	my $dumpables = { };
	for my $alsodump (qw(configuration overrides name cluster_id uuid activated unknown aliases addresses))
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
	if ($wantinterfaces)
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
	
	if ($schedule) {
		$jobargs{uuid} = \@data;
		$jobargs{data} = $cmdline;

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
	
		my $curconfig = $nodeobj->configuration;
		my $curoverrides = $nodeobj->overrides;
		my $curactivated = $nodeobj->activated;
		my $curextras = $nodeobj->unknown;
		my $curarraythings = { aliases => $nodeobj->aliases,
													 addresses => $nodeobj->addresses };
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
			}
			# ...and then there's the unknown unknowns
			elsif ($name =~ /^unknown\.(.+)$/)
			{
				$curextras->{$1} = $value;
			}
			# and aliases and addresses, but these are ARRAYS
			elsif ($name =~ /^((aliases|addresses)\.(.+))$/)
			{
				$curarraythings->{$1} = $value;
			}
			# configuration.X
			elsif ($name =~ /^configuration\.(.+)$/)
			{
				$curconfig->{$1} = $value;
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
				 [$curarraythings, "addresses/aliases" ],
				 [$curextras, "unknown/extras" ])
		{
			my ($checkwhat, $name) = @$_;
	
			my $error = NMISNG::Util::translate_dotfields($checkwhat);
			die "translation of $name arguments failed: $error\n" if ($error);
		}
	
		$nodeobj->overrides($curoverrides);
		$nodeobj->configuration($curconfig);
		$nodeobj->activated($curactivated);
		$nodeobj->addresses($curarraythings->{addresses});
		$nodeobj->aliases($curarraythings->{aliases});
		$nodeobj->unknown($curextras);
	
		(my $op, $error) = $nodeobj->save;
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
	die "NOT deleting anything:\nplease rerun with the argument confirm='yes' in all uppercase\n\n"
			if (!$confirmation or $confirmation ne "YES");

	my $file = $cmdline->{file};
	my $schedule = $cmdline->{schedule} // 0; # Schedule by default? Yes	
	
	if ($schedule) {
		my @nodes = split(",", $node);
		my @uuid = split(",", $uuid);
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
					
					my ($ok, $error) = $mustdie->delete(keep_rrd => NMISNG::Util::getbool($nukedata, "invert")); # === eq false
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

		(my $op, $error) = $nodeobj->save;
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
			
	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);

	# TODO: Mark for update with status
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if looked up via uuid

	my $old = lc($node); 
	my $dir = $config->{database_root}. "/nodes/$old";
	my $newdir = $config->{database_root}. "/nodes/$node";
	
	if ( !-d $newdir ) {
		my $output = `mkdir $newdir`;
	}
	
	NMISNG::Util::replace_files_recursive($dir, $node, $old, "rrd");
	
	print STDERR "Successfully moved node rrd files $cmdline->{name}.\n"
			if (-t \*STDERR);

	exit 0;
}
# template is deeply structured, just like output of act=export (EXCEPT for act=export format=nodes)
elsif ($cmdline->{act} eq "mktemplate" && $server_role ne "POLLER")
{
	my $file = $cmdline->{file};
	die "File \"$file\" already exists, NOT overwriting!\n"
			if (defined $file && $file ne "-" && -f $file);

	my $withplaceholder = NMISNG::Util::getbool($cmdline->{placeholder});

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
		if ($server_data->{id} ne $mayberec->{cluster_id}) {
			die "Cluster and server mismatch!\n"
		}
		
	}
	
	my $number = 0;
	
	if (ref($mayberec) eq "ARRAY") {
		foreach my $node (@$mayberec) {
			validate_node_data(node => $node);
			# no uuid and creating a node? then we add one
			$node->{uuid} ||= NMISNG::Util::getUUID($node->{name}) if ($cmdline->{act} eq "create");
			$number++;
		} 
	} else {
		validate_node_data(node => $mayberec);
		# no uuid and creating a node? then we add one
		$mayberec->{uuid} ||= NMISNG::Util::getUUID($mayberec->{name}) if ($cmdline->{act} eq "create");
		$number++;
	}

	my %jobargs;
	
	# Send job to the queue
	if ($schedule) {
		my $time = $cmdline->{time} // time;
		my $priority = $cmdline->{priority} // $config->{priority_node_create}; # Default for this job?
		my $verbosity = $cmdline->{verbosity} // $config->{log_level};
		my $what = $cmdline->{act} eq "create" ? "create_nodes" : "update_nodes";
		$jobargs{data} = $mayberec;
		$jobargs{server} = $server_data if ($server);
		
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
	
		my ($status,$msg) = $nodeobj->save;

		# zero is no saving needed, which is not good here
		die "failed to ".($isnew? "create":"update")." node $mayberec->{uuid}: $msg\n" if ($status <= 0);
	
		my $name = $nodeobj->name;
		print STDERR "Successfully ".($isnew? "created":"updated")
				." node ".$nodeobj->uuid." ($name)\n\n"
				if (-t \*STDERR);								# if terminal
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

exit 0;