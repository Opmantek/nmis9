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
# a command-line node administration tool for NMIS 9
use strict;
our $VERSION = "9.0.0b";

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
my $usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act={list|list_uuid}
\t$bn act=show node=nodeX
\t$bn act={create|update} file=someFile.json
\t$bn act=export [format=nodes] [file=path] {node=nodeX|group=groupY}
\t$bn act=import_bulk {nodes=filepath|nodeconf=dirpath}
\t$bn act=delete {node=nodeX|group=groupY}

\t$bn act=set node=nodeX entry.X=Y...
\t$bn act=mktemplate [placeholder=1/0]
\t$bn act=rename old=nodeX new=nodeY [entry.A=B...]

mktemplate: prints blank template for node creation,
 optionally with __REPLACE_XX__ placeholder
create: requires file=NewNodeDef.json
export: exports to file=someFile (or STDOUT if no file given),
 either json or as Nodes.nmis if format=nodes is given

update: updates existing node from file=someFile.json
delete: only deletes if confirm=yes (in uppercase) is given

show: prints a node's properties in the same format as set
 with option quoted=true, show adds double-quotes where needed
set: adjust one or more node properties

extras: deletedata=<true,false> which makes delete also
delete inventory data and RRD files for a node. default is true.

extras: debug={1..9,verbose} sets debugging verbosity
extras: info=1 sets general verbosity
\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
																					debug => $cmdline->{debug},
																					info => $cmdline->{info});
die "no config available!\n" if (ref($config) ne "HASH"
																 or !keys %$config);

# log to stderr if debug or info are given
my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																 debug => $cmdline->{debug},
																 info => $cmdline->{info}) // $config->{log_level},
															 path  => (defined($cmdline->{debug})
																				 || defined($cmdline->{info})? undef : $logfile));

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);


# import from nodes file, overwriting existing data in the db
if ($cmdline->{act} =~ /^import[_-]bulk$/
		&& (my $nodesfile = $cmdline->{nodes}))
{
	die "invalid nodes file $nodesfile argument!\n" if (!-f $nodesfile);

	$logger->info("Starting bulk import of nodes");

	# old-style nodes file: hash. export w/o format=nodes: plain array,
	# readfiletohash doesn't understand arrays.
	my $node_table = NMISNG::Util::readFiletoHash(file => $nodesfile,
																								json => ($nodesfile =~ /\.json$/i))
			// decode_json(Mojo::File->new($nodesfile)->slurp);

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

		# not all attribs go under configuration!
		for my $copyable (grep($_ !~ /^(_id|uuid|cluster_id|name|activated|lastupdate|overrides|configuration|aliases|addresses)$/,
													 keys %$onenode))
		{
			$curconfig->{$copyable} = $onenode->{$copyable} if (exists $onenode->{$copyable});
		}
		$node->configuration($curconfig);

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
		}
		else
		{
			$logger->debug( $node->name." saved to database, op: $op" );
		}
	}
	$logger->info("Bulk import complete, newly created $stats{created}, updated $stats{updated} nodes");
	exit 0;
}
elsif ($cmdline->{act} =~ /^import[_-]bulk$/
			 && (my $nodeconfdir = $cmdline->{nodeconf}))
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

		my ($op,$error) = $node->save();
		$logger->error("Error saving node: ",$error) if ($op <= 0); # zero is no saving needed

		$logger->debug( "imported nodeconf for $node_name, overrides saved to database, op: $op" );
	}

	$logger->info("Bulk import complete, updated overrides for $counter nodes");
	exit 0;
}
if ($cmdline->{act} =~ /^list([_-]uuid)?$/)
{
	# just list the nodes in existence - possibly with uuids
	my $wantuuid = $1;

	# returns a modeldata object
	my $nodelist = $nmisng->get_nodes_model(fields_hash => { name => 1, uuid => 1});
	if (!$nodelist or !$nodelist->count)
	{
		print STDERR "No nodes exist.\n" # but not an error, so let's not die
				if (!$cmdline->{quiet});
	}
	else
	{
		print($wantuuid? "Node UUID\tNode Name\n=========================\n" : "Node Names:\n===========\n")
				if (-t \*STDOUT); # if to terminal, not pipe etc.

		print join("\n", map { ($wantuuid? ($_->{uuid}."\t".$_->{name}) : $_->{name}) }
							 (sort { $a->{name} cmp $b->{name} } (@{$nodelist->data})) ),"\n";
	}
	exit 0;
}
elsif ($cmdline->{act} eq "export")
{
	my ($node,$group,$file,$wantformat) = @{$cmdline}{"node","group","file","format"};

	# no node, no group => export all of them
	die "File \"$file\" already exists, NOT overwriting!\n" if (defined $file && $file ne "-" && -f $file);

	my $nodemodel = $nmisng->get_nodes_model(name => $node, group => $group);
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
elsif ($cmdline->{act} eq "show")
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safer
	my $wantquoted = NMISNG::Util::getbool($cmdline->{quoted});

	die "Cannot show node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if  looked up via uuid

	# we want the config AND any overrides AND most other top-level things, but flattened
	my $dumpables = $nodeobj->configuration;
	for my $alsodump (qw(overrides name cluster_id uuid activated))
	{
		$dumpables->{$alsodump} = $nodeobj->$alsodump;
	}
	# if unknown extras exist, dump them too
	# ditto for addresses and aliases
	for my $otherstuff (qw(unknown addresses aliases))
	{
		$dumpables->{$otherstuff} = $nodeobj->$otherstuff();
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
	exit 0;
}
elsif ($cmdline->{act} eq "set")
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safer

	die "Cannot set node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
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
		else
		{
			$curconfig->{$name} = $value;
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

	# check the group - only warn about
	my @knowngroups = split(/\s*,\s*/, $config->{group_list});
	if (!grep($_ eq $curconfig->{group}, @knowngroups))
	{
		print STDERR "\nWarning: your node info sets group \"$curconfig->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis-cli act=groupsync' to add all missing groups.\n\n";
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

	exit 0;
}
elsif ($cmdline->{act} eq "delete")
{
	my ($node,$group,$confirmation,$nukedata) = @{$cmdline}{"node","group","confirm","deletedata"};

	die "Cannot delete without node or group argument!\n\n$usage\n" if (!$node and !$group);
	die "NOT deleting anything:\nplease rerun with the argument confirm='yes' in all uppercase\n\n"
			if (!$confirmation or $confirmation ne "YES");

	my $nodemodel = $nmisng->get_nodes_model(name => $node, group => $group);
	die "No matching nodes exist\n" if (!$nodemodel->count);

	my $gimmeobj = $nodemodel->objects; # instantiate, please!
	die "Failed to instantiate node objects: $gimmeobj->{error}\n"
			if (!$gimmeobj->{success});

	for my $mustdie (@{$gimmeobj->{objects}})
	{
		my ($ok, $error) = $mustdie->delete(
			keep_rrd => NMISNG::Util::getbool($nukedata, "invert")); # === eq false
		die $mustdie->name.": $error\n" if (!$ok);
	}
	exit 0;
}
elsif ($cmdline->{act} eq "rename")
{
	my ($old, $new, $uuid) = @{$cmdline}{"old","new","uuid"}; # uuid is safest for lookup

	die "Cannot rename node without old and new arguments!\n\n$usage\n"
			if ((!$old && !$uuid) || !$new);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $old);
	die "Node $old does not exist.\n" if (!$nodeobj);
	$old ||= $nodeobj->name;			# if looked up via uuid

	my ($ok, $msg) = $nodeobj->rename(new_name => $new,
																								 originator => "node_admin");
	die "$msg\n" if (!$ok);

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

		# check the group - only warn about
		my @knowngroups = split(/\s*,\s*/, $config->{group_list});
		if (!grep($_ eq $curconfig->{group}, @knowngroups))
		{
			print STDERR "\nWarning: your node info sets group \"$curconfig->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis-cli act=groupsync' to add all missing groups.\n\n";
		}

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
# template is deeply structured, just like output of act=export (EXCEPT for act=export format=nodes)
elsif ($cmdline->{act} eq "mktemplate")
{
	my $file = $cmdline->{file};
	die "File \"$file\" already exists, NOT overwriting!\n"
			if (defined $file && $file ne "-" && -f $file);

	my $withplaceholder = NMISNG::Util::getbool($cmdline->{placeholder});

	my %mininode = ( map { my $key = $_; $key => ($withplaceholder?
																								"__REPLACE_".uc($key)."__" : "") }
									 (qw(name cluster_id uuid configuration.host configuration.group configuration.notes
configuration.community configuration.roleType configuration.netType configuration.location configuration.model activated.NMIS configuration.ping configuration.collect configuration.version configuration.port configuration.username configuration.authpassword configuration.authkey configuration.authprotocol configuration.privpassword configuration.privkey configuration.privprotocol ))  );

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
elsif ($cmdline->{act} =~ /^(create|update)$/)
{
	my $file = $cmdline->{file};

	open(F, $file) or die "Cannot read $file: $!\n";
	my $nodedata = join('', grep( !m!^\s*//\s+!, <F>));
	close(F);

	# sanity check this first!
	die "Invalid node data, __REPLACE_... placeholders are still present!\n"
			if ($nodedata =~ /__REPLACE_\S+__/);

	my $mayberec;
	# check correct encoding (utf-8) first, fall back to latin-1
	$mayberec = eval { decode_json($nodedata); };
	$mayberec = eval { JSON::XS->new->latin1(1)->decode($nodedata); } if ($@);
	die "Invalid node data, JSON parsing failed: $@\n" if ($@);

	my $name = $mayberec->{name};
	die "Invalid node name \"$name\"\n"
			if ($name =~ /[^a-zA-Z0-9_-]/);

	die "Invalid node data, not a hash!\n" if (ref($mayberec) ne 'HASH');
	for my $mustbedeep (qw(configuration overrides activated))
	{
		die "Invalid node data, invalid structure for $mustbedeep!\n"
				if (exists($mayberec->{$mustbedeep}) && ref($mayberec->{$mustbedeep}) ne "HASH");
	}

	die "Invalid node data, does not have required attributes name, host and group\n"
			if (!$mayberec->{name} or !$mayberec->{configuration}->{host} or !$mayberec->{configuration}->{group});

	die "Invalid node data, netType \"$mayberec->{configuration}->{netType}\" is not known!\n"
			if (!grep($mayberec->{configuration}->{netType} eq $_,
								split(/\s*,\s*/, $config->{nettype_list})));
	die "Invalid node data, roleType \"$mayberec->{configuration}->{roleType}\" is not known!\n"
			if (!grep($mayberec->{configuration}->{roleType} eq $_,
								split(/\s*,\s*/, $config->{roletype_list})));

	# check the group
	my @knowngroups = split(/\s*,\s*/, $config->{group_list});
	if (!grep($_ eq $mayberec->{group}, @knowngroups))
	{
		print STDERR "\nWarning: your node info sets group \"$mayberec->{configuration}->{group}\", which does not exist!\n";
	}

	# look up the node - ideally by uuid, fall back to name only if necessary
	my %query = $mayberec->{uuid}? (uuid => $mayberec->{uuid}) : (name => $mayberec->{name});
	my $nodeobj = $nmisng->node(%query);
	die "Node $name does not exist.\n" if (!$nodeobj && $cmdline->{act} eq "update");
	die "Node $name already exist.\n" if ($nodeobj && $cmdline->{act} eq "create");

	die "Please use act=rename for node renaming.\nUUID "
			.$nodeobj->uuid." is already associated with name \"".$nodeobj->name."\".\n"
			if ($nodeobj and $nodeobj->name and $nodeobj->name ne $mayberec->{name});

	# no uuid and creating a node? then we add one
	$mayberec->{uuid} ||= Compat::UUID::getUUID($name) if ($cmdline->{act} eq "create");
	$nodeobj ||= $nmisng->node(uuid => $mayberec->{uuid}, create => 1);
	die "Failed to instantiate node object!\n" if (ref($nodeobj) ne "NMISNG::Node");

	my $isnew = $nodeobj->is_new;
	# must set overrides, activated, name/cluster_id, addresses/aliases, configuration; 
	for my $mustset (qw(cluster_id name activated overrides configuration addresses aliases))
	{
		$nodeobj->$mustset($mayberec->{$mustset}) if (exists($mayberec->{$mustset}));
		delete $mayberec->{$mustset};
	}
	# if creating, add missing cluster_id for local operation
	$nodeobj->cluster_id($config->{cluster_id}) if ($cmdline->{act} eq "create"
																									&& !$nodeobj->cluster_id);
	# there should be nothing left at this point, anything that is goes into unknown()
	my %unknown = map { ($_ => $mayberec->{$_}) } (grep(!/^(configuration|lastupdate|uuid)$/,
																											keys %$mayberec));
	$nodeobj->unknown(\%unknown);

	my ($status,$msg) = $nodeobj->save;
	# zero is no saving needed, which is not good here
	die "failed to ".($isnew? "create":"update")." node $mayberec->{uuid}: $msg\n" if ($status <= 0);

	$name = $nodeobj->name;
	print STDERR "Successfully updated node ".$nodeobj->uuid." ($name)\n\n"
			if (-t \*STDERR);								# if terminal
}
else
{
	# fallback: complain about the arguments
	die "Could not parse arguments!\n\n$usage\n";
}

exit 0;
