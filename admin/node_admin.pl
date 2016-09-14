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
# a command-line node administration tool for NMIS
our $VERSION = "1.1.0";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;

use func;
use NMIS;
use NMIS::UUID;

my $bn = basename($0);
my $usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act=list
\t$bn act={create|export|update|delete} node=nodeX
\t$bn act=mktemplate [placeholder=1/0]
\t$bn act=rename old=nodeX new=nodeY

mktemplate: prints blank template for node creation,
 optionally with __REPLACE_XX__ placeholder
create: requires file=NewNodeDef.json
export: exports to file=someFile.json (or STDOUT if no file given)
update: updates existing node from file=someFile.json (or STDIN)
delete: only deletes if confirm=yes (in uppercase) is given

extras: deletedata=<true,false> which makes delete also
delete all RRD files for the node. default is false.

extras: conf=<configname> to use different configuration
extras: debug={1..9,verbose} sets debugging verbosity
extras: info=1 sets general verbosity
\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));
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

print STDERR "Reading Nodes table\n" if ($debuglevel or $infolevel);
my $nodeinfo = loadLocalNodeTable();

# now for the real work!
if ($args{act} eq "list")
{
	# just list the nodes in existence
	if (!%$nodeinfo)
	{
		print "No nodes exist.\n";
	}
	else
	{
		print "Node Names:\n===========\n",join("\n",sort keys %{$nodeinfo}),"\n";
	}
	exit 0;
}
elsif ($args{act} eq "export")
{
	my ($node,$file) = @args{"node","file"};

	die "Cannot export node without node argument!\n\n$usage\n" if (!$node);
	die "File \"$file\" already exists, NOT overwriting!\n" if (defined $file && $file ne "-" && -f $file);

	my $noderec = $nodeinfo->{$node};
	die "Node $node does not exist.\n" if (!$noderec);

	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDOUT;
	}
	else
	{
			 open($fh,">$file") or die "cannot write to $file: $!\n";
	}
	# ensure that the output is indeed valid json, utf-8 encoded
	print $fh JSON::XS->new->pretty(1)->canonical(1)->utf8->encode($noderec);
	close $fh if ($fh != \*STDOUT);

	print STDERR "Successfully exported $node configuration to file $file\n" if ($fh != \*STDOUT);
	exit 0;
}
elsif ($args{act} eq "delete")
{
	my ($node,$confirmation,$nukedata) = @args{"node","confirm","deletedata"};

	die "Cannot delete node without node argument!\n\n$usage\n" if (!$node);
	die "Node $node does not exist.\n" if (!$nodeinfo->{$node});

	die "NOT deleting node $node:\nplease rerun with the argument confirm='yes' in all uppercase\n\n"
			if (!$confirmation or $confirmation ne "YES");

	# first thing, get rid of any events
	cleanEvent($node,"node_admin");

	# if data is to be deleted, do that FIRST (need working sys object to find stuff)
	if (getbool($nukedata))
	{
		print STDERR "Priming Sys object for finding RRD files\n" if ($debuglevel or $infolevel);
		my $S = Sys->new; $S->init(name => $node, snmp => "false");

		my @todelete;
		my $oldinfo = $S->ndinfo;
		# find and nuke all rrds belonging to the deletable node
		for my $section (keys %{$oldinfo->{graphtype}})
		{
			next if ($section =~ /^(network|nmis|metrics)$/);
			if (ref($oldinfo->{graphtype}->{$section}) eq "HASH")
			{
				my $index = $section;
				for my $subsection (keys %{$oldinfo->{graphtype}->{$section}})
				{
					if ($subsection =~ /^cbqos-(in|out)$/)
					{
						my $dir = $1;
						# need to find the qos classes and hand them to getdbname as item
						for my $classid (keys %{$oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}})
						{
							my $item = $oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}->{$classid}->{Name};
							push @todelete, $S->getDBName(graphtype => $subsection,
																						index => $index, item => $item);
						}
					}
					else
					{
						push @todelete, $S->getDBName(graphtype => $subsection, index => $index);
					}
				}
			}
			else
			{
				push @todelete, $S->getDBName(graphtype => $section);
			}
		}

		# then take care of the var files
		my $vardir = $config->{'<nmis_var>'};
		opendir(D, $vardir) or die "cannot read dir $vardir: $!\n";
		for my $fn (readdir(D))
		{
			push @todelete, "$vardir/$fn" if ($fn =~ /^$node-(node|view)\.(\S+)$/i);
		}
		closedir D;

		# then deal with the unwanted stuff
		for my $fn (@todelete)
		{
			next if (!defined $fn);
			my $relfn = File::Spec->abs2rel($fn, $config->{'<nmis_base>'});
			print STDERR "Deleting file $relfn, no longer required\n" if ($debuglevel or $infolevel);
			unlink($fn);
		}
	}

	# finally remove the old node from the nodes file
	print STDERR "Deleting node $node from Nodes table\n" if ($debuglevel or $infolevel);
	delete $nodeinfo->{$node};
	# fixme lowprio: if db_nodes_sql is enabled we need to use a different write function
	writeTable(dir => 'conf', name => "Nodes", data => $nodeinfo);

	print STDERR "Successfully deleted $node\n";
	exit 0;
}
elsif ($args{act} eq "rename")
{
	my ($old, $new) = @args{"old","new"};

	my ($error, $msg) = NMIS::rename_node(old => $args{old}, new => $args{new},
																				originator => "node_admin",
																				info => $infolevel, debug => $debuglevel);
	die "$msg\n" if ($error);
	print STDERR "Successfully renamed node $args{old} to $args{new}.\n";
	exit 0;
}
elsif ($args{act} eq "mktemplate")
{
	# default: no placeholder
	my $wantblank = !$args{placeholder};

	my @nodecomments = ( "Please see https://community.opmantek.com/display/NMIS/Home for further descriptions of the properties!", undef,
											 "name is essential and sets the node's name",
											 "host sets the primary hostname for communication (can be short name,",
											 " fully qualified name or ip address)",
											 "group is for node categorization",
											 "the above properties are REQUIRED!",undef,

											 "community defines the SNMP read community",
											 "model defines what type of device this is",
											 "active defines whether the node is enabled or disabled",
											 "collect defines whether SNMP information should be collected",
											 "ping defines whether reachability statistics should be collected",
											 "version sets the SNMP protocol version (snmpv1, snmpv2c, snmpv3)",

											 "notes is for free-form notes or comments",
											 "location provides further categorization info" );

	my $dummynode = {
		name => $wantblank? '' : "__REPLACE_NAME__",
		host => $wantblank? '' : "__REPLACE_HOST__",
		notes => $wantblank? '' : "__REPLACE_NOTES__",
		model => $wantblank? 'automatic' : "__REPLACE_MODEL__",
		group => $wantblank? '' : "__REPLACE_GROUP__",
		netType =>  $wantblank? '' : "__REPLACE_NETTYPE__",
		roleType => $wantblank? '' : "__REPLACE_ROLETYPE__",
		location => $wantblank? '' : "__REPLACE_LOCATION__",

		active => $wantblank? 'true' : "__REPLACE_ACTIVE__",
		ping => $wantblank? 'true' : "__REPLACE_PING__",
		collect => $wantblank? 'true' : "__REPLACE_COLLECT__",
		community => $wantblank? '': "__REPLACE_COMMUNITY__",
		version => $wantblank? 'snmpv2c': "__REPLACE_VERSION__",
	};

	print "// ",join("\n// ",@nodecomments),"\n\n",
	JSON::XS->new->pretty(1)->canonical(1)->utf8->encode($dummynode);

	exit 0;
}
elsif ($args{act} =~ /^(create|update)$/)
{
	my ($node,$file) = @args{"node","file"};

	die "Cannot create or update node without node argument!\n\n$usage\n" if (!$node);
	die "File \"$file\" does not exist!\n" if (defined $file && $file ne "-" && ! -f $file);

	die "Invalid node name \"$node\"\n"
			if ($node =~ /[^a-zA-Z0-9_-]/);

	my $noderec = $nodeinfo->{$node};
	die "Node $node does not exist.\n" if (!$noderec && $args{act} eq "update");
	die "Node $node already exist.\n" if ($noderec && $args{act} eq "create");

	print STDERR "Reading node configuration data for $node\n" if ($debuglevel or $infolevel);
	# suck in the data
	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDIN;
	}
	else
	{
			 open($fh,"$file") or die "cannot read from $file: $!\n";
	}
	my $nodedata = join('', grep( !m!^\s*//\s+!, <$fh>));
	close $fh if ($fh != \*STDIN);

	# sanity check this first!
	die "Invalid node data, __REPLACE_... placeholders are still present!\n"
			if ($nodedata =~ /__REPLACE_\S+__/);

	print STDERR "Parsing JSON node configuration data\n" if ($debuglevel or $infolevel);
	my $mayberec;
	# check correct encoding (utf-8) first, fall back to latin-1
	$mayberec = eval { decode_json($nodedata); };
	$mayberec = eval { JSON::XS->new->latin1(1)->decode($nodedata); } if ($@);
	
	die "Invalid node data, JSON parsing failed: $@\n" if ($@);

	die "Invalid node data, name value \"$mayberec->{name}\" does not match argument \"$node\".
Use act=rename for renaming nodes.\n"
			if ($mayberec->{name} ne $node);


	die "Invalid node data, not a hash!\n" if (ref($mayberec) ne 'HASH');
	die "Invalid node data, does not have required attributes name, host and group\n"
			if (!$mayberec->{name} or !$mayberec->{host} or !$mayberec->{group});

	die "Invalid node data, netType \"$mayberec->{netType}\" is not known!\n"
			if (!grep($mayberec->{netType} eq $_, split(/\s*,\s*/, $config->{nettype_list})));
	die "Invalid node data, roleType \"$mayberec->{roleType}\" is not known!\n"
			if (!grep($mayberec->{roleType} eq $_, split(/\s*,\s*/, $config->{roletype_list})));

	# no uuid? then we add one
	if (!$mayberec->{uuid})
	{
		$mayberec->{uuid} = getUUID($node);
	}

	# ok, looks good enough. save the node info.
	print STDERR "Saving node $node in Nodes table\n" if ($debuglevel or $infolevel);
	$nodeinfo->{$node} = $mayberec;
	# fixme lowprio: if db_nodes_sql is enabled we need to use a different write function
	writeTable(dir => 'conf', name => "Nodes", data => $nodeinfo);

	# nix any pending events
	if ($args{act} eq "update")
	{
		print STDERR "Removing events for node $node\n" if ($debuglevel or $infolevel);
		cleanEvent($node,"node-admin");
	}

	# check the group
	my @knowngroups = split(/\s*,\s*/, $config->{group_list});
	if (!grep($_ eq $mayberec->{group}, @knowngroups))
	{
		print STDERR "\nWarning: your node info sets group \"$mayberec->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis.pl type=groupsync' to add all missing groups.\n\n";
	}

	print STDERR "Successfully $args{act}d node $node.
You should run '".$config->{'<nmis_bin>'}."/nmis.pl type=update node=$node' soon.\n";
	exit 0;
}
else
{
	# fallback: complain about the arguments
	die "Could not parse arguments!\n\n$usage\n";
}

exit 0;
