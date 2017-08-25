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

# this module provides a generic object for
# configuration, handling and finding of nodes: names, properties,
# ip addresses and so on. it's meant to be used by all products eventually
# (opconfig and opevents for now)
#
# fixme/maybe: nodeipdata.pm's functions should be moved/merged into this class for consistency
# and nodeipdata.pm should be removed
#
package NMISNG::Nodes;
use strict;
our $VERSION = "9.0.0a";

use Data::Dumper;
use Test::Deep::NoTest;
use Mojo::Log;

use NMISNG::DB;

# generic constructor
# required args: EITHER dir (=config dir) and conf (=name)
# OR db (= handle to nmis database) and config (=parsed live config object)
# optional: log (logger object handle), logprefix, debug
# optional: drop_unwanted_indices (default 0) - if set, unwanted old db indices are dropped
sub new
{
	my ($class,%arg) = @_;

	my $self = bless(
		{
			debug => $arg{debug},
			log => $arg{log},
			logprefix => $arg{logprefix},
			db => $arg{db},
			config => $arg{config},
		}, $class);

	my $db = $self->{db};

	# if we're not given primed material, bootstrap ourselves or die if no args
	if (!$db || !$self->{config})
	{
		for my $setting (qw(conf dir))
		{
			die "cannot create Nodes object without $setting!\n"
					if (!defined $arg{$setting});
			$self->{$setting} = $arg{$setting};
		}

		# read the config
		$self->{config} = loadOmkConfTable(conf => $self->{conf},
																			 dir => $self->{dir},
																			 debug=>$self->{debug});

		# get the db setup ready, indices and all
		# nodes uses the SHARED COMMON database, NOT a module-specific one!
		my $conn = OMK::DB::getDbConnection(conf => $self->{config});
		if (!$conn)
		{
			my $errmsg = OMK::DB::getErrorString;
			$self->log("fatal", "cannot connect to MongoDB: $errmsg");
			die "cannot connect to MongoDB: $errmsg\n";
		}
		$db = $conn->get_database($self->{config}->{db_name});
	}

	my $nodecoll = OMK::DB::getCollection(db => $db, name => "nodes");
	$self->log("fatal", "Could not get collection nodes: ".OMK::DB::getErrorString) if (!$nodecoll);
	my $ipcoll = OMK::DB::getCollection(db => $db, name => "ip");
	$self->log("fatal", "Could not get collection ip: ".OMK::DB::getErrorString) if (!$ipcoll);

	# nodes collection: searchable by primary _id (= node name), by host, group and activation status
	my $err = OMK::DB::ensureIndex( collection => $nodecoll,
																	 drop_unwanted => $arg{drop_unwanted_indices},
																	 indices => [
																		 [ { "host"=>1} ],
																		 [ {"group"=>1} ],
																		 [ { "activated" => 1 } ],
																	 ]);
	$self->log("fatal", "ensureIndex on nodes failed: $err") if ($err);

	# ip collection needs the automatic _id index, and searching by node attrib
	$err = OMK::DB::ensureIndex( collection => $ipcoll,
																drop_unwanted => $arg{drop_unwanted_indices},
																indices => [ [ { "node"=>1} ] ] );
	$self->log("fatal", "ensureIndex on ip failed: $err") if ($err);

	# now park the db handles in the object
	$self->{db}=$db;
	$self->{db_nodes}=$nodecoll;
	$self->{db_ip}=$ipcoll;

 	return $self;
}

# getter/setter for the logprefix argument
# args: newprefix, if given replaces the current one.
# returns: current prefix (after possible replacement)
sub logprefix
{
	my ($self, $newprefix) = @_;

	$self->{logprefix} = $newprefix if (defined $newprefix);
	return  $self->{logprefix};
}

# logs given message either via logcommon, or passes it to a mojo log object if one is set.
# if logprefix is available, prefix each message with _exactly_ that
# args: severity (debug, info, warn, error, fatal)
# for logcommon it'll suppress debug output if not $self->{debug}
sub log
{
	my ($self,$severity,$msg)=@_;
	$msg = $self->{logprefix}.$msg if (defined $self->{logprefix});

	if (defined $self->{log} && $severity =~ /^(debug|info|warn|error|fatal)$/)
	{
		return $self->{log}->$severity($msg);
	}
	else
	{
		return logCommon("$msg")
				if ($severity ne "debug" || $self->{debug});
	}
}

# small accessor that returns all known node names (or subset thereof)
# args: none required, only_active is optional.
# only_active_for (= appkey to check) returns only licensed/activated nodes for this app
# all other given args will be made into a db query
#
# note: having group set to list of allowed groups DOES NOT cover nodes
# without any group whatsoever, which is possible and ok outside of NMIS!
# to catch these as well, an undef entry needs to be in the group set.
#
# returns: array of names, sorted
sub getNodeNames
{
	my ($self,%args) = @_;

	my $appkey = $args{only_active_for};
	delete $args{only_active_for};

	my $query = OMK::DB::GetQuery(and_part => \%args);
	if ($appkey)
	{
		# OMK-887, can't do this with getquery
		$query->{'$or'} = [ { "activated.$appkey" => { '$exists' => 0 } }, # not present is sufficiently ok,
												# mongo is picky, 1 is not "1" and i don't even want to ask about 1.0 :-(
												{ "activated.$appkey" => 1 },
												{ "activated.$appkey" => "1" } ]; # or really enabled is also sufficient
	}

	my $cursor = OMK::DB::Find(collection => $self->{db_nodes},
														 query => $query,
														 sort => { _id => 1 },
														 fields_hash => { _id => 1}); # don't need anything except the ids=names
	my @response;
	while (my $this = $cursor->next)
	{
		push @response, $this->{_id};
	}

	return @response;
}

# small accessor that returns count of all nodes
# args: none required, only_active is optional.
# only_active_for (= appkey to check) returns only licensed/activated nodes for this app
#
# returns: integer
sub getNodeCount
{
	my ($self,%args) = @_;

	my $query = {};
	if (my $appkey = $args{only_active_for})
	{
		$query = { "activated.$appkey" => { '$ne' => 0 } };
	}

	my $count = OMK::DB::Count(collection => $self->{db_nodes}, query => $query);
	return $count;
}

# tiny accessor that returns all known group names, regardless of whether they have
# active members or not
# args: none
#
# returns: array of group names
sub getGroupNames
{
	my ($self) = @_;

	# want to see the non-blank, non-undef group names only
	my $listref = OMK::DB::Distinct(db => $self->{db},
																	collection => $self->{db_nodes}->name,
																	key => "group",
																	query => {  'group' => { '$nin' => [ undef, '' ] } });
	if (ref($listref) eq "ARRAY")
	{
		push @$listref, "No Group"; # dummy group name for nodes without group
		return @$listref;
	}
	return ();
}

# a method for helping typeahead.js search nodes
# args: q (the thing to search for, optional), OR group_id (in which case only that group is looked up)
# if no q is present, then all nodes are returned.
# returns the node information in format for typeahead (markd's flavour)
sub searchNodes
{
	my ($self, %args) = @_;
	my @nodeset;

	# if q or group_id are present we offload as much as we can to mongo:
	# $regexp across the known token-contributors, followed by filtering THOSE instead of
	# just sucking in everything via getNodesModel()
	my $allnodes = [];
	my ($q, $query);
	if ((defined($args{q}) and $args{q} ne "") or (defined($args{group_id}) and $args{group_id} ne ""))
	{
		if (defined($args{q}) and $args{q} ne "")
		{
			$q = "".$args{q};				# mongo does NOT like regex parameters to be numeric...
			# and any regex-special chars need escaping
			$q =~ s/([{}?+*\(\)\[\]])/\\$1/g;

			# search for regex over node name, host, group in nodes collection,
			# then regex over the addressse in the ip collection
			$query = { '$or' => [ { "_id" => { '$regex' => $q } },
															 { "host" => { '$regex' => $q } },
															 { "group" => { '$regex' => $q } } ] };
		}
		else												# group_id case
		{
			if ($args{group_id} eq "No Group") # special dummy for nodes without group
			{
				$query = { 'group' => { '$in' => [ undef, '' ] } };
			}
			else
			{
				$query = { 'group' => $args{group_id} };
			}
		}

		my $cursor = OMK::DB::Find(collection => $self->{db_nodes},
															 query => $query);
		my %candidates;
		while (my $entry = $cursor->next)
		{
			$self->_mergeaddresses($entry);
			push @$allnodes, $entry;
			$candidates{$entry->{name}} = 1;
		}

		# now for searching ip addresses (and parts thereof), not in the group_id case
		if ($q)
		{
			$cursor = OMK::DB::Find(collection => $self->{db_ip},
															query => { "_id" => { '$regex' => $q } },
															fields_hash => { "node" => 1 });
			while (my $entry = $cursor->next)
			{
				next if ($candidates{$entry->{node}}); # duplicate, ignore
				my $noderec = $self->getNode(node => $entry->{node});
				push @$allnodes, $noderec if ($noderec);
			}
		}
	}
	else
	{
		# pull all nodes which takes a bit of time
		$allnodes = $self->getNodesModel;
	}

	# now massage the data into suitable form, ie. tokenise
	# if q present, weed out any non-matching ones

	for my $noderec (@$allnodes)
	{
		# tokens we want for finding this node: full node name, host (if different), group (if present),
		# addresses (if present)
		# then the tokenized name, host and address bits - and no duplicates.
		my %tokens = ( $noderec->{name} => 1 );
		# note that in opevents, oae, and opconfig groups are NOT mandatory (as they are in nmis)
		# the typeahead stuff requires that a group_id exists, so we fake in "No Group" in that case
		$noderec->{group} = "No Group" if (!defined $noderec->{group} or $noderec->{group} eq "");
		$tokens{$noderec->{group}} = 1;

		my @splits = split(/[_:\.-]+/, $noderec->{name});
		map { $tokens{$_} = 1; } (@splits) if (@splits > 1);

		if (defined $noderec->{host} and $noderec->{name} ne $noderec->{host})
		{
			$tokens{$noderec->{host}} = 1;
			@splits = split(/[_:\.-]+/, $noderec->{host});
			map { $tokens{$_} = 1; } (@splits) if (@splits > 1);
		}

		# fixme: should 127.0.0.0/8 and/or ::1 be excluded?
		if (ref($noderec->{addresses}) eq "ARRAY" and @{$noderec->{addresses}})
		{
			for my $addy (@{$noderec->{addresses}})
			{
				$tokens{$addy} = 1;
				@splits = split(/[:\.]+/, $addy);
				map { $tokens{$_} = 1; } (@splits);
			}
		}

		# return only the matching results, if given a query; the priming regex search
		# may very well have returned unwanted nodes
		if (defined $q)
		{
			next if (!grep(/$q/, keys %tokens));
		}

		push @nodeset, 	{ value => $noderec->{name}, name => $noderec->{name},
											tokens => [keys %tokens],
											group_id => $noderec->{group} };
	}
	return \@nodeset;
}


# checks the ip collection for a matching node entry, and creates a temporary one on the fly if needed
# falls back to dns if possible, and updates collection if successful
# args: lookup (= ip address or hostname or node name, matched against _id),
# optional: only_active_for (=appkey to check, ignores nodes not activated for that app)
# returns: the node name attribute (called 'node' in the ip db), or the lookup if nothing works
sub getNodeName
{
	my ($self,%arg) = @_;
	my $now=time;

	# node will be set to same as lookup if no results.
	my $lookup = $arg{lookup};
	my $node = $lookup;

	# if we want only active ones, fetch those first, as candidate set - we have no join
	my $qargs = {'_id' => $lookup};
	if ($arg{only_active_for})
	{
		$qargs->{node} = [ $self->getNodeNames(only_active_for => $arg{only_active_for}) ];
	}

	# query the DB
	my $query = OMK::DB::GetQuery(and_part => $qargs, no_auto_oid => 1);

	my $results = OMK::DB::Find(collection => $self->{db_ip},
															query => $query);
	my $count=$results->count;
	my $answer=$results->next;		# might or might not exist

	# no success and dns prohibited? return the query
	if (!$count && getBool($self->{config}->{dns_disabled}))
	{
		$self->log("debug","found no nodename for \"$lookup\", but DNS is disabled.")
				if ($self->{debug} > 1);
		return $lookup;
	}
	# no success, then try a dns detour if allowed to: does that resolve to something we know?
	# records that are marked as expired are also discarded and retried
	# note that records without expires property are not updated!
	elsif (!$count || (defined $answer->{expires} && $answer->{expires} < $now))
	{
		$node = $answer->{node} if (defined $answer); # better the expired data than nothing

		my (@possibles,$err);
		if ($lookup=~/^(\d{1,3}\.){3}\d{1,3}$/ or $lookup =~ /:/) # ipv4 or ipv6 address?
		{
			push @possibles, resolve_dns_address($lookup);
		}
		else	# hostname or fqdn
		{
			push @possibles, resolve_dns_name($lookup);
		}

		if (@possibles)
		{
			for my $intermediate (@possibles)
			{
				# must continue to only consider activated nodes
				$qargs->{'_id'} = $intermediate;
				$results = OMK::DB::Find(collection => $self->{db_ip},
																 query => OMK::DB::GetQuery(and_part => $qargs,
																														no_auto_oid => 1));
				if ($results->count)
				{
					# insert new record pointing to the known one
					my $alreadyknown = $results->next; # there can be only one

					my $cachetime = $self->{config}->{dns_cache} || 604800;
					my %newrec=(type => "dns",
											node => $alreadyknown->{node},
											lastupdate => $now,
											intermediate => $intermediate,
											expires => $now + $cachetime
							);
					my $status = OMK::DB::Update(collection => $self->{db_ip},
																			 query => { _id => $lookup },
																			 record => \%newrec,
																			 upsert => 1);
					if (!$status->{success})
					{
						$self->log("error","Failed to update IP collection for $lookup: $status->{error}");
					}
					return $alreadyknown->{node};
				}
			}
		}

		# no success in the dns: insert/update a dummy record with a short expiration time
		my $cachetime = $self->{config}->{dns_retry} || 7200;
		my %newrec=(type => "dns",
								node => $node,
								lastupdate => $now,
								expires => $now + $cachetime
				);
		my $status = OMK::DB::Update(collection => $self->{db_ip},
																 query =>  { _id => $lookup },
																 upsert => 1,
																 record => \%newrec );
		if (!$status->{success})
		{
			$self->log("error","Failed to update IP collection for $lookup: $status->{error}");
		}
	}
	else
	{
		$node = $answer->{node};
	}

	if (ref($node))
	{
		$self->log("error","ip database contains unexpected deep structure for \"$lookup\"!");
		$node = $lookup;					# fall back to a workable sane structure
	}

	$self->log("debug","getNodeName for $lookup = $node") if ($self->{debug} > 1);
	return($node);
}

# a small helper that retrieves a named node property from the database
#
# this support the mongodb dot-notation, ie. you can retrieve "outer.2.inner.4",
# note that _id is NOT returned with the result.
#
# args: node and property are required
# returns: the property, may be any mongo-compatible structure
sub getNodeProperty
{
	my ($self,%arg) = @_;
	my $node = $arg{node};
	my $property = $arg{property};

	die "cannot run getNodeProperty without node\n" if (!$node);
	die "cannot run getNodeProperty without property\n" if (!$property);

	my $result = OMK::DB::Find(collection => $self->{db_nodes},
														 query => {'_id' => $node},
														 fields_hash => { $property => 1, "_id" => 0 });

	my $datastructure = $result->next;
	for my $indir (split(/\./,$property))
	{
		if ($indir =~ /^\d+$/ && ref($datastructure) eq "ARRAY")
		{
			$datastructure = $datastructure->[$indir];
		}
		elsif (ref($datastructure) eq "HASH")
		{
			$datastructure = $datastructure->{$indir};
		}
		else
		{
			$self->log("debug","Node $node, property access $property failed, structure not deep enough");
			return undef;
		}
	}
	return $datastructure;
}

# returns selection of nodes, as array of hashes
# args: id, name, host, group for selection;
#
# returns: array of hashes, with the stuff under key "addresses" synthesized from the ip cache collection
#
# arg sort: mongo sort criteria
# arg limit: return only N records at the most
# arg skip: skip N records at the beginning. index N in the result set is at 0 in the response
# arg paginate: sets the pagination mode, in which case the result array is fudged up sparsely to
# return 'complete' result elements without limit! - a dummy element is inserted at the 'complete' end,
# but only 0..limit are populated
sub getNodesModel
{
	my ($self,%arg) = @_;

	# no_auto_oid needed as nodes collection uses straight node name as _id
	my $q = OMK::DB::GetQuery( no_auto_oid => "true",
														 and_part => { '_id' => $arg{id}, 'name' => $arg{name},
																					 'host' => $arg{host}, 'group' => $arg{group} });
	my $modelData = [];
	if ($arg{paginate})
	{
		# fudge up a dummy result to make it reflect the total number
		my $count = OMK::DB::Count( collection => $self->{db_nodes}, query => $q);
		$modelData->[$count-1] = {} if ($count);
	}

	my $entries = OMK::DB::Find( collection => $self->{db_nodes}, query => $q, sort => $arg{sort},
															 limit => $arg{limit}, skip => $arg{skip} );
	my $index = 0;
	while (my $entry = $entries->next)
	{
		$self->_mergeaddresses($entry);
		$modelData->[$index++] = $entry;
	}
	return $modelData;
}

# find a full node record for a given node or ip address
# args: EITHER node or ip (=address)
# returns: node record or undef
# note: "addresses" are merged in
sub getNode
{
	my ($self, %arg) = @_;
	my $node = $arg{node};
	my $ip = $arg{ip};

	die "getNode requires either node or ip argument!\n" if (!($node ^ $ip)); # xor is lovely

	# find a node name from ip if required
	if ($ip)
	{
		my $ipcursor = OMK::DB::Find(collection => $self->{db_ip},
																 query => { "_id" => $ip} );
		my $iprecord = $ipcursor->next;
		$node = $iprecord? $iprecord->{node} : undef;
	}

	if ($node)
	{
		my $cursor = OMK::DB::Find(collection => $self->{db_nodes},
															 query => { "_id" => $node });
		my $noderecord = $cursor->next;
		return $self->_mergeaddresses($noderecord) if ($noderecord);
	}
	return undef;
}

# this is a small (internal) helper that fetches and merges a node's
# secondary address records into a give node record
#
# args: noderecord (ref)
# returns: amended noderecord (still the same ref)
sub _mergeaddresses
{
	my ($self, $noderecord) = @_;

	if ($noderecord)
	{
		$noderecord->{"addresses"} ||= [];
		# find this node's ip addresses (if any)
		my $ipcursor = OMK::DB::Find(collection => $self->{db_ip},
																 query => { "node" => $noderecord->{_id} },
																 fields_hash => { "_id" => 1 });
		while (my $ipentry = $ipcursor->next)
		{
			my $address = $ipentry->{"_id"};
			# at this point we're only interested in ip address entries, not temporary dns intermediaries or fqdn entries
			push @{$noderecord->{addresses}}, $address if ($address =~ /^[a-fA-F0-9:.]+$/);
		}
	}
	return $noderecord;
}


# returns the raw ip addresses hash for a given node,
# NOT massaged into the synthetic 'addresses' list
# this is for feeding updated info back into UpdateNode, without losing
# expiration information or the like.
# this does NOT include the normal node's host record, only the secondary address associations
#
# args: node
# returns: hash ref of address records (may be empty)
sub getNodeAddresses
{
	my ($self, %args) = @_;
	my $nodename = $args{node};

	die "getNodeAddresses requires node argument!\n" if (!$nodename);

	# find this node's ip addresses (if any)
	my %addresses;
	my $ipcursor = OMK::DB::Find(collection => $self->{db_ip},
															 query => { "node" => $nodename });
	while (my $ipentry = $ipcursor->next)
	{
		my $address = $ipentry->{"_id"};
		delete $ipentry->{_id};			# can't leave that for subsequent updates
		# at this point we're only interested in ip address entries, not temporary dns intermediaries or fqdn entries
		$addresses{$address}= $ipentry if ($address =~ /^[a-fA-F0-9:.]+$/);
	}
	return \%addresses;
}

# helper that checks if given node is licensed/activated for a given application
# args: appkey, and  nodeNMISNG::Util::info (= record) or node (=name)
# returns 1 if licensed/active, undef otherwise
sub node_is_active
{
	my ($self, %args) = @_;

	my $appkey = $args{appkey};
	my $nodeinfo = $args{nodeinfo};
	my $node = $args{node};

	die "cannot determine node activation without application!\n" if (!$appkey);
	die "cannot determine node activation without either node or nodeinfo!\n" if (!$node && !$nodeinfo);

	$nodeinfo = $self->getNode(node => $node) if (!$nodeinfo);

	# disabled means activated.thisprod explicitely set to 0. not set is fine.
	return undef if (defined $nodeinfo->{activated}
									 && exists $nodeinfo->{activated}->{$appkey}
									 && !$nodeinfo->{activated}->{$appkey});
	# default is active
	return 1;
}


# adds new information about a node, possibly inserting new db records
# args: node (=name, required), NMISNG::Util::info (= hash of *direct* goodies, optional),
# ip_addresses (= hash of ip address records, by ip address, optional),
# optional meta (= user and time, only expected run from gui or admin tools),
#
# note that the synthetic 'addresses' entry in info is removed and NOT updated,
# to update ip addresses you have to give the more detailed info in ip_addresses!
#
# note that this function COMPLETELY REMOVES sensitive/credential information
# from the record. sensitives are listed in config nmis_sensitive_property,
# falling back to hardcoded list.
#
# returns: undef if ok, error msg otherwise
sub UpdateNode
{
	my ($self, %arg) = @_;
	my ($node,$info,$ips) = @arg{"node","info","ip_addresses"};

	die "cannot run UpdateNode without node argument!\n" if (!$node);
	die "UpdateNode requires an info record or ip_addresses but has neither!\n" if (!$info && !$ips);

	my (@errmsgs, %updateop);

	if ($info)
	{
		delete $info->{addresses};		# that's only for easier access, NOT for updates
		delete $info->{_id}; # and that one can't be present in an update

		# remove all sensitive information that may have crept in
		# from nmis, ie. credentials and the like.
		# the property names here are the ones from nmis
		my @sensitive = (ref($self->{nmis_sensitive_property}) eq "ARRAY"?
										 @{$self->{nmis_sensitive_property}} :
										 (qw(community privkey privpassword authkey authpassword
wmiusername wmipassword username)));

		for my $mustgoaway (@sensitive)
		{
			delete $info->{$mustgoaway};
			$updateop{'$unset'}->{$mustgoaway}=1;
		}

		# ensure that the activated stuff is all numbers, NOT strings! or other garbage input gunk...
		if (ref($info->{activated}) eq "HASH")
		{
			for my $appname (keys %{$info->{activated}})
			{
				# undef is unwanted, we want either "not present" or 1 for enabled,
				# or 0 for disabled.
				if (!defined $info->{activated}->{$appname})
				{
					delete $info->{activated}->{$appname};
				}
				else
				{
					# invalid args (arrays, hashes, whatever) are stringified, then forced into 0/1.
					$info->{activated}->{$appname} = 0 + ($info->{activated}->{$appname}? 1 : 0);
				}
			}
		}

		# we want to perform two ops in one go, a $set on the good stuff
		# and an $unset on the bad. this means we need freeform mode and constrain the goodies
		# ourselves
		$updateop{'$set'} = OMK::DB::ConstrainRecord(record => $info);

		# first update the main node details
		my $result = OMK::DB::Update(
			collection => $self->{db_nodes},
			query => {'_id' => $node},
			constraints => 0,
			freeform => 1,
			record => \%updateop,
			upsert => 1);

		if (!$result->{success})
		{
			my $text = "Update of node record for $node failed: $result->{error}";
			push @errmsgs, $text;
			$self->log("error",$text);
		}
		else
		{
			$self->log("debug","Updated system details for $node"
								 .($self->{debug} > 1? (": ".Dumper($info)):''));
		}

		# if we have an info record, we also check any aliases and park them in the ip cache
		# there are three possible scenarios to cover: host attribute is fqdn,
		# ip address, or unqualified shortname
		my @aliases = $self->expandNodeName($info->{host});
		# now insert all those names for this box
		for my $hostid (@aliases)
		{
			# leave entry unchanged iff present and identical
			my $cursor = OMK::DB::Find(collection => $self->{db_ip},
																 query => {'_id' => $hostid});
			my $ispresent = $cursor->next;
			if ($ispresent && $ispresent->{node} eq $node)
			{
				$self->log("debug","Ip entry $hostid already associated with node $node, no update.");
			}
			else
			{
				my $ipinfo = { "type" => "alias",
											 "node" => $node,
											 "intermediate" => $hostid, # to spell out 'node X had this node.host Y, which is or expanded to Z'
											 "lastupdate" => time() };

				# note: do not add an expires attribute here, this knowledge
				# is only a/v in nmis
				my $result = OMK::DB::Update(collection => $self->{db_ip},
																		 query => {'_id' => $hostid },
																		 record => $ipinfo,
																		 upsert => 1);
				if (!$result->{success})
				{
					my $text = "Update for $node/$hostid failed: $result->{error}";
					push @errmsgs, $text;
					$self->log("error",$text);
				}
				else
				{
					$self->log("debug","Added/updated association $hostid for node $node");
				}
			}
		}
	}

	# ips are meant to be hash of address => record to park
	# hash still needs to be present (but reduced/empty) if addresses are to be deleted
	if (defined $ips && ref($ips) eq "HASH")
	{
		# first get the current entries
		my $presentones = $self->getNodeAddresses(node => "$node");

		# now deal with new/expiration-updated ones
		for my $thisaddress (keys %$ips)
		{
			if ($thisaddress !~ /^[a-fA-F0-9:.]+$/)
			{
				my $text = "Address entry \"$thisaddress\" is not recognized as IP address!";
				push @errmsgs, $text;
				$self->log("error", $text);
				delete $presentones->{$thisaddress};
				next;
			}

			# we don't want to collect spurious 127.0.0.1 aliases
			# all over the place. it's ok for the primary node address (see host below)
			# to resolve to localhost, but not the interface addy's that we're dealing with here
			if ($thisaddress =~ /^127\./ or $thisaddress eq "::1" or
					# check if already present, and with the same keys and values
					eq_deeply($presentones->{$thisaddress}, $ips->{$thisaddress}))
			{
				delete $presentones->{$thisaddress};
				$self->log("debug","Ip entry $thisaddress not relevant or already associated with node $node, no update.");
				next;
			}

			$ips->{$thisaddress}->{node} ||= $node; # make sure the essential records are populated
			$ips->{$thisaddress}->{type} ||= "ip";

			# ip address records are slightly special: expiration set to -1 means expiration should be removed from record
			my $remove_expiration= ($ips->{$thisaddress}->{expires} && $ips->{$thisaddress}->{expires} == -1);

			my $result = OMK::DB::Update(collection => $self->{db_ip},
																	 query => {'_id' => $thisaddress },
																	 record => $ips->{$thisaddress},
																	 upsert => 1);
			if (!$result->{success})
			{
				my $text = "Update for $node/$thisaddress failed: $result->{error}";
				push @errmsgs, $text;
				$self->log("error", $text);
			}
			else
			{
				$self->log("debug","Updated/added ip association $thisaddress for node $node");
			}

			# get rid of expiration if and only if requested!
			if ($remove_expiration)
			{
				$result = OMK::DB::Update(collection => $self->{db_ip},
																	query => {'_id' => $thisaddress },
																	freeform => 1,
																	record => { '$unset' => { 'expires' => '' } } );
				if (!$result->{success})
				{
					my $text = "Expiration removal for $node/$thisaddress failed: $result->{error}";
					push @errmsgs, $text;
					$self->log("error",$text);
				}
			}
			delete $presentones->{$thisaddress};
		}

		# if the primary host entry is an ip address, then it'll show up in the presentones list
		# but we certainly DO want to keep it!
		delete $presentones->{$info->{host}} if ($info->{host} =~  /^[a-fA-F0-9:.]+$/);

		# now remove all unwanted remaining addresses
		for my $unwanted (keys %$presentones)
		{
			my $result = 	OMK::DB::Remove(collection =>  $self->{db_ip},
																		query => { "_id" => $unwanted });
			if (!$result->{success})
			{
				my $text = "Removal of unwanted address $unwanted for $node failed: $result->{error}";
				push @errmsgs, $text;
				$self->log("error",$text);
			}
			else
			{
				$self->log("debug","removed unwanted ip $unwanted for $node");
			}
		}
	}

	if (ref($arg{meta}) eq "HASH" && $arg{meta}->{user})
	{
		OMK::Common::audit_log(who => $arg{meta}->{user}, what => $arg{meta}->{what} || "edit node",
													 where => $node,
													 how => (@errmsgs? "failure!" : "ok") );
	}

	return @errmsgs? join("\n",@errmsgs): undef;
}

# removes the records for a given node from the nodes and ip collection
# args: node, required; optional meta (=user and time, only expected when run from gui or admin tool)
# returns undef if ok, error message otherwise
sub RemoveNode
{
	my ($self, %args) = @_;
	my $node = $args{node};

	die "cannot run RemoveNode without node argument!\n" if (!$node);

	my $result = OMK::DB::Remove(collection => $self->{db_nodes},
															 query => { "_id" => $node });
	if (!$result->{success})
	{
		return "Removal of node record for \"$node\" failed: $result->{error}";
	}

	$result = OMK::DB::Remove(collection =>  $self->{db_ip},
														query => { "node" => $node });

	if (ref($args{meta}) eq "HASH" && $args{meta}->{user})
	{
		OMK::Common::audit_log(who => $args{meta}->{user}, what => "delete node",
													 where => $node,
													 how => ($result->{success}? "ok" : "failure") );
	}

	if (!$result->{success})
	{
		return "Removal of ip record for \"$node\" failed: $result->{error}";
	}
	return undef;
}

# removes unwanted old records from the ip collection
# currently this removes expired dns-and-audit-sourced records,
# but fixme: should look for orphaned stuff too
#
# args: none
# returns: undef if ok, error message otherwise (and logs)
sub purge
{
	my ($self) = @_;

	# find all expired records of the relevant dynamic types
	# fixme: OMK::DB::GetQuery cannot create that query
	# (because of the two clauses for expires)
	my $query = { type => { '$in' => [ "dns", "audit", "alias" ] },
								'$and' => [
									{ expires => { '$exists' => 1 } },
									{ expires => { '$lt' => time() } },
										] };
	my $res = OMK::DB::Remove(collection => $self->{db_ip},
														query => $query);
	if (!$res->{success})
	{
		$self->log("error","Failed to remove expired ip records: $res->{error}");
		return "Failed to remove expired records: $res->{error}";
	}
	$self->log("debug", "IP collection purging removed $res->{count} expired records.")
			if ($res->{count});

	return undef;
}

# small helper routine that returns all dns aliases for a shortname node name
# used for managing the ip cache collection
# returns list of aliases (including the node name)
sub expandNodeName
{
	my ($self,$hostid) = @_;

	my @aliases = ($hostid);					# what do we want to associate with this host?

	# if the host property is a shortname then attempt to qualify it
	if ($hostid !~ /[:.]/) # has no dots and no colons, must be shortname
	{
		if (my @nameinfo = gethostbyname( $hostid ))
		{
			push @aliases, $nameinfo[0] if ($nameinfo[0] ne $hostid); # the official hostname
			for my $othername (split(/\s+/, $nameinfo[1]))
			{
				push @aliases, $othername if ($othername ne $hostid
																			and $othername ne $nameinfo[0]); # aliases
			}
		}
	}
	return @aliases;
}

# utility function that handles the consequences of nodes being renamed
#
# fixme: right now this just mangles the database, but in the future it may actually have to instantiate
# opconfig, opevents, ... objects to make more precise adjustments - dependencies will become ugly
#
# args: oldnode, newnode (=names, both required)
# returns undef if all ok, error message otherwise
sub ResolveRename
{
	my ($self, %args) = @_;
	my ($oldnode,$newnode) = @args{"oldnode","newnode"};

	die "cannot perform ResolveRename operation without both old and new node arguments!\n"
			if (!$oldnode or !$newnode);

	return undef if ($oldnode eq $newnode); # duh.

	# opconfig-related:
	# do collections command_outputs, command_output_log, config_states (these have node), compliance_states (has context_node)
	# opevents-related: events, eventqueue, (state is special)

	for my $collname (qw(config_states command_outputs command_output_log compliance_states events eventqueue))
	{
		$self->log("debug", "Performing node rename \"$oldnode\" to \"$newnode\" in collection $collname");
		my $coll = $self->{db}->get_collection($collname);
		my ($query, $update);
		if ($collname eq "compliance_states")
		{
			$query = { "context_node" => $oldnode };
			$update = { "context_node" => $newnode };
		}
		else
		{
			$query = { "node" => $oldnode };
			$update = { "node" => $newnode };
		}

		# can't do an atomic bulk rename because there /will/ be clashes, in which case we leave the records
		# for the NEWER name and delete the records for the OLD name
		my $cursor = OMK::DB::Find(collection =>  $coll, query => $query, fields => { "node" => 1, "context_node" => 1 });
		my ($successes, $failures) = (0) x 2;
		while (my $record = $cursor->next)
		{
			my $result = OMK::DB::Update(collection => $coll, query => { "_id" => $record->{_id} },
																	 record => $update );
			if (!$result->{success})
			{
				if ($result->{error} =~ /E11000/) # duplicate key
				{
					$self->log("warn", "Update of db $collname failed due do key clash. Removing old record. Details were: $result->{error}");
					OMK::DB::Remove(collection => $coll, query => { "_id" => $record->{_id} });
					$failures++
				}
				else
				{
					$self->log("error", "Update of db $collname failed: $result->{error}");
					return "Update of db $collname failed: $result->{error}";
				}
			}
			++$successes;
		}
		$self->log("debug","Rename in collection $collname done, modified $successes entries, removed $failures clashing entries");
	}

	# handle opevents' state collection, which has "<node>--" in the _id
	my $collname = "state";
	$self->log("debug", "Performing node rename \"$oldnode\" to \"$newnode\" in collection $collname");
	my $coll = $self->{db}->get_collection($collname);

	my $query = { "_id" => { '$regex' => "^$oldnode(--|\$)" } };
	# need to create new massaged records as in mongodb the _id is immutable, and remove the old ones
	my $cursor = OMK::DB::Find(collection =>  $coll, query => $query);
	my ($successes, $failures) = (0) x 2;
	while (my $record = $cursor->next)
	{
		my $oldid = $record->{_id};
		my $newid = $oldid; $newid =~ s/^$oldnode/$newnode/;
		delete $record->{_id};
		$record->{node} = $newnode;

		if (OMK::DB::Count(collection => $coll, query => { "_id" => $newid }))
		{
			$self->log("warn","Clashing entry for $newid already exists in $collname. Removing old record.");
			++$failures;
		}
		else
		{
			my $result = OMK::DB::Update(collection => $coll, query => { "_id" => $newid },
																	 record => $record, upsert => 1);
			if (!$result->{success})
			{
				$self->log("error", "Update of db $collname failed: $result->{error}");
				return "Update of db $collname failed: $result->{error}";
			}
			++$successes;
		}
		my $result = OMK::DB::Remove(collection => $coll, query => {"_id" => $oldid });
		if (!$result->{success})
		{
			$self->log("error", "Removal of $oldid in db $collname failed: $result->{error}");
			return "Removal of $oldid in db $collname failed: $result->{error}";
		}
	}
	$self->log("debug","Rename in collection $collname done, updated $successes entries, removed $failures clashing entries");

	return undef;
}

# checks if a given node is a member of a given list of groups
# args: node (either a node name or nodeinfo record), group_list (list of groups to check)
# note: no group for node is ok but only outside of NMIS!
# returns 1 if member, 0 if not.
sub nodeInGroup
{
	my ($self, %args) = @_;

	return 1 if (ref($args{group_list}) ne "ARRAY"
							 or !@{$args{group_list}}); # everybody member of the empty group
	my $record = ref($args{node} eq "HASH")? $args{node} :
			$self->getNode(node => $args{node});

	return 0 if (!defined $record->{group}
							 or $record->{group} eq ''); # no groups known for this node

	for my $gname (@{$args{group_list}})
	{
		return 1 if ($record->{group} eq $gname);
	}
	return 0;
}

1;
