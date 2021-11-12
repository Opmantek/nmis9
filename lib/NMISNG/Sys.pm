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
package NMISNG::Sys;
our $VERSION = "3.2.0";

use strict;

use NMISNG::Util;          # common functions
use NMISNG::Snmp;
use NMISNG::rrdfunc;
use NMISNG::WMI;
use NMISNG::ModelData;					# gettypeinstances needs help

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Data::Dumper;
$Data::Dumper::Indent = 1;
use List::Util;
use Clone;
use Carp qw(longmess);
use Scalar::Util;

# the sys constructor does next to nothing, just roughly setup the structure
sub new
{
	my ( $class, %args ) = @_;

	my $self = bless(
		{
			name => undef,    # name of node
			node => undef,    # legacy copy of name (was lowercased but no longer)
			mdl  => undef,    # ref Model modified

			snmp => undef,    # snmp accessor object
			wmi  => undef,    # wmi accessor object

			cfg    => {},     # configuration of node
			reach  => {},     # tmp reach table
			alerts => [],     # getValues() saves stuff there, nmis.pl consumes

			graphtype2subconcept => {}, # cache of relationships, for lookups starting with graphtype

			error      => undef,    # last internal error
			wmi_error  => undef,    # last wmi accessor error
			snmp_error => undef,    # last snmp accessor error
			fallback => undef,      # snmp session established but to backup address?

			debug        => 0,
			update       => 0,      # flag for update vs collect operation - attention: read by others!
			cache_models => 1,      # json caching for model files default on

			_nmisng_node => undef,
			_nmisng => $args{nmisng},	# filled by sub init() if not passed in here
			_inventory_cache => {}, # inventories that need re-use are kept in here, managed by inventory function

			_initialised => undef,		# set and  queried by init()
		},
		$class
			);

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

#===================================================================
sub mdl       { my $self = shift; return $self->{mdl} };                   # my $M = $S->mdl
sub reach     { my $self = shift; return $self->{reach} };                 # my $R = $S->reach
sub alerts    { my $self = shift; return $self->{mdl}{alerts} };           # my $CA = $S->alerts

# attention: that thing has an extra static 'node' outer wrapper!
# it also contains ONLY the nmisng::node's configuration(), not uuid/cluster_id/name/activated()!
sub ndcfg     { my $self = shift; return $self->{cfg} };


# deprecated, deliberately noisy, provides RO access to interface list
# fixme: no error handling
sub ifinfo
{
	my ($self) = @_;

	Carp::cluck("sys::ifinfo function is deprecated!\n");
	return {} if (!$self->nmisng_node);

	my $result = $self->nmisng_node->get_inventory_model(concept => "interface",
																											 filter => { historic => 0 });
	if (my $error = $result->error)
	{
		$self->nmisng->log->error("get inventory model failed: $error");
		return {};
	}
	my %ifdata = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
	return \%ifdata;
}

# these don't create on access because re-running init is supposed to reset the object
sub nmisng         { my $self = shift; return $self->{_nmisng} };
sub nmisng_node    { my $self = shift; return $self->{_nmisng_node} };

# return an inventory object for the node
# if only index is required for the path a data section with a single entry 'index' will be created,
# if more is needed pass in data, this assumes that the path_keys needed to make the inventory are known
# by the specific inventory type, defaultinventory with more path_keys entries should be made another way
# if no index is necessary this will also work
# arguments:
#  concept - string
#  [index] - optional, for now all things that are indexed use the key 'index' to find them
#  [partial] - set to 1 if the path may have a partial match (generally it won't and you don't want this)
#   the case where you do is when the key has two pieces of unique data and either can be used to find it
#   eg, interfaces, ifIndex and ifDescr
#  [data] - pass in data required to make path if the path is more complex than empty or just index
#  [nolog] - set to 1 if it's ok that the inventory is not found and an error should not be logged
# NOTE: for now this caches the catchall/global inventory object because it's used all over the place
#  and needs to have a longer life
#
# fixme9: consider merging with nmisng::node::inventory as there's about 95% overlap
sub inventory
{
	my ($self,%args) = @_;
	my $node = $self->nmisng_node;
	my ($concept,$index,$partial,$data,$nolog) = @args{'concept','index','partial','data','nolog'};
	return if(!$node);
	return if(!$concept);

	# re-use cached object for catchall
	return $self->{_inventory_cache}{$concept}
		if( $concept eq 'catchall' && $self->{_inventory_cache}{$concept} );

	# for now map pkts into interface
	$concept = 'interface' if( $concept =~ /pkts/ );

	# if data was not passed in
	$data //= {};
	my $path_keys = [];

	# if we have an index put it into the data so a path can be made
	# path keys is assumed to be index, if inventory subtype is more specific it will
	# ignore this and use the keys from data that it wants
	if( $index )
	{
		$data->{index} = $index;
		$path_keys = ['index'];
	}
	my $path = $node->inventory_path(concept => $concept, data => $data, path_keys => $path_keys, partial => $partial);
	my ($inventory,$error_message);
	if( ref($path) eq 'ARRAY' )
	{
		($inventory,$error_message) = $node->inventory(concept => $concept, path => $path);
		if( !$inventory && $concept eq 'catchall' )
		{
			# catchall can/should be created if not found, it's better to create it here so whoever needs it can get it
			# instead of having one magic place that makes it and that has to be run first
			# does not pass in data, doing that on create is not the right way, setting the value after creation is more consistent
			($inventory,$error_message) = $node->inventory(concept => $concept, path => $path, path_keys => $path_keys, create => 1);
		}
		$self->nmisng->log->error("Failed to get inventory for node:".$node->name.", concept:$concept error_message:$error_message path:".join(',', @$path)) if(!$inventory && !$nolog);
	}
	else
	{
		$self->nmisng->log->error("Failed to get inventory path for node:".$node->name.", concept:$concept, index:$index path:$path") if (!$nolog);
	}

	$self->{_inventory_cache}{$concept} = $inventory
		if($concept eq 'catchall');

	return $inventory;
}

#===================================================================

# small accessor for sys' status and errors
# args: none
# returns: hash ref of state info: error, snmp_error, wmi_error, snmp_enabled, wmi_enabled
#
# error is sys' internal error status (undef if no problems),
# snmp_error is from snmp accessor, undef if no snmp configured or not (yet) active or ok
# wmi_error is from wmi, undef if no wmi configured or not (yet) active or ok
# wmi_enabled is 1 if the config was suitable for wmi and init() was called with wmi
# snmp_enabled is 1 if config was suitable for snmp and init() was called with snmp
# fallback is 1 iff all of: snmp is configured, host_backup property is given
#  and session to primary address failed
# skipped is 1 after data retrieval ops, if some data was skipped (due to control expression etc)
#
sub status
{
	my ($self) = @_;

	return {
		error        => $self->{error},
		snmp_enabled => $self->{snmp} ? 1 : 0,
		wmi_enabled  => $self->{wmi} ? 1 : 0,
		snmp_error   => $self->{snmp_error},
		wmi_error    => $self->{wmi_error},
		skipped      => $self->{skipped},
		fallback => $self->{fallback},
	};
}

# initialise the system object for a given node
# ATTENTION: re-initialisation is no longer supported.
# you need a new sys object every time you want to call init().
#
# node config is loaded if snmp or wmi args are true
# args: node (live node object),
#   or uuid (of the node) or (least desirable) name.
# snmp (defaults to 1), wmi (defaults to the value for snmp),
# update (defaults to 0), cache_models (see code comments for defaults), force (defaults to 0),
# policy (default unset)
# cluster_id can be provided, helpful when all you have is name
#
# update means ignore model loading errors, also disables cache_models
# force means ignore the old node file, only relevant if update is enabled as well.
# if policy is given (hashref of ping/wmi/snmp => numeric seconds) then the rrd db params are overridden
#
# fixme9: the 'global' non-node mode is severly crippled and doesn't allow most operations.
#
# returns: 1 if _everything_ was successful, 0 otherwise, also sets details for status()
sub init
{
	my ( $self, %args ) = @_;

	Carp::confess("Sys objects cannot be reinitialised!")
			if ($self->{_initialised}); # new doesn't set that
	$self->{_initialised} = 1;

	my $C;
	if (ref($args{node}) eq "NMISNG::Node")
	{
		my $nodeobj  = $args{node};

		$self->{_nmisng} //= $nodeobj->nmisng;
		$C = $self->{_nmisng}->config;
		$self->{_nmisng_node} = $nodeobj;
	}
	elsif ($args{uuid} or $args{name})
	{
		$self->{name} = $self->{node} = $args{name};
		$self->{uuid} = $args{uuid};

		$self->{_nmisng} //= Compat::NMIS::new_nmisng();

		# use all data we may have
		# If cluster_id was given use it
		$self->{_nmisng_node} = $self->{_nmisng}->node(
			name => $self->{name},
			uuid => $self->{uuid},
			filter => {cluster_id => $args{cluster_id}}
		);
		Carp::confess("Cannot instantiate sys object for $self->{name}!\n")
				if (!$self->{_nmisng_node});
	}

	# apply these uniformly (so a caller only providing uuid still gets them)
	if( $self->{_nmisng_node} )
	{
		$self->{uuid} = $self->{_nmisng_node}->uuid;
		$self->{name} = $self->{node} = $self->{_nmisng_node}->name;
	}

	$C ||= $self->{_nmisng}->config if ($self->{_nmisng});
	$C ||= NMISNG::Util::loadConfTable();           # needed to determine the correct dir; generally cached and a/v anyway
	$self->{config} = $C;
	
	if ( ref($C) ne "HASH" or !keys %$C )
	{
		Carp::confess("failed to load configuration table!");
	}
	$self->{_nmisng} ||= Compat::NMIS::new_nmisng();

	$self->{debug}  = $args{debug};
	$self->{update} = NMISNG::Util::getbool($args{update});
	my $policy = $args{policy};		# optional

	# flag for init snmp accessor, default is yes
	my $snmp = NMISNG::Util::getbool( exists $args{snmp} ? $args{snmp} : 1 );
	# ditto for wmi, but default from snmp
	my $wantwmi = NMISNG::Util::getbool( exists $args{wmi} ? $args{wmi} : $snmp );
	my $catchall_data = {};

	# sys uses end-to-end model-file-level caching, NOT per contributing common file!
	# caching can be chosen with argument cache_models here.
	# caching defaults to on if not an update op.
	# caching is always OFF if config cache_models is explicitely set to false.
	if ( defined( $args{cache_models} ) )
	{
		$self->{cache_models} = NMISNG::Util::getbool( $args{cache_models} );
	}
	else
	{
		$self->{cache_models} = !$self->{update};
	}
	$self->{cache_models} = 0 if ( NMISNG::Util::getbool( $C->{cache_models}, "invert" ) );

	# (re-)cleanup, set defaults
	$self->{snmp} = $self->{wmi} = undef;
	$self->{mdl} = undef;
	for my $nuke (qw(info rrd reach))
	{
		$self->{$nuke} = {};
	}
	$self->{cfg} = {node => {ping => 'true'}};

	# load info of node and interfaces into this object, if a node is given
	# otherwise load the 'generic' sys object
	if ( $self->{name} )
	{
		my $catchall = $self->inventory( concept => 'catchall' );
		# if force is off, load the existing node info
		# if on, ignore that information and start from scratch (to bypass optimisations)
		if ( $self->{update} && NMISNG::Util::getbool( $args{force} ) )
		{
			$catchall->data( {} );
			$catchall_data = $catchall->data_live();
			$self->nmisng->log->debug("Not loading info of node=$self->{name}, force means start from scratch");
		}
		else
		{
			$catchall_data = $catchall->data_live();
			if ( (keys %$catchall_data) > 0 )
			{
				if ( NMISNG::Util::getbool( $self->{debug} ) )
				{
					my $values = $self->nmisng_node->get_distinct_values(
						collection => $self->nmisng->inventory_collection,
						filter => { enabled => 1, historic => 0 },
						key => 'subconcepts'
					);
					# NOTE, this is an attempt at recreateing the output, it may not be what we want
					NMISNG::Util::TODO("Recreate this debug output, possibly need a way to ask a node for it's concepts/sections?");
					foreach my $value ( @$values )
					{
						$self->nmisng->log->debug3( "Node=$self->{name} info $value" );
					}
				}
			}
			# or bail out if this is not an update operation, all gigo if we continued w/o.
			elsif ( !$self->{update} )
			{
				$self->{error} = "Failed to load catchall data for $self->{node}!";
				return 0;
			}
		}
	}

	# load node configuration - attention: only done if snmp or wmi are true
	# and if there's a node
	if (!$self->{error}
			and ( $snmp or $wantwmi )
			and $self->{name} )
	{
		# fixme9: this is truly not good, duplicated, wasteful and mangled data.
		# sys::ndcfg and this should be eradicated altogether, and replaced by using the node object's
		# accessors!
		if (my $nodeobj = $self->nmisng_node)
		{
			# node configuration is separate from node name, uuid, activated, overrides, aliases and other things
			$self->{cfg}->{node} = $nodeobj->configuration();
			# ...but sys' customers expect all in one messy blob
			for my $flatearth (qw(name uuid cluster_id activated overrides aliases addresses))
			{
				$self->{cfg}->{node}->{$flatearth} = $nodeobj->$flatearth;
			}

			$self->nmisng->log->debug("cfg of node=$self->{name} loaded");
		}
		else
		{
			$self->{error} = "Failed to load cfg of node=$self->{name} - no node object!";
			return 0;    # cannot do anything further
		}
	}
	else
	{
		$self->nmisng->log->debug("no loading of cfg of node=$self->{name}");
	}

	# load Model of node or the base Model, or give up
	my $loadthis       = "Model";
	my $thisnodeconfig = {};

	if ($self->{name})
	{
		$thisnodeconfig = $self->{cfg}->{node};
		my $curmodel       = $catchall_data->{nodeModel};

		$self->nmisng->log->debug("node=$self->{name} collect=$thisnodeconfig->{collect} model=$thisnodeconfig->{model} nodeModel=$curmodel");

		# get the specific model
		if ( $curmodel and $curmodel ne "Model" and not $self->{update} )
		{
			$loadthis = "Model-$curmodel";
		}
		# specific model, update yes, ping yes, collect no -> set manual model
		elsif ( $thisnodeconfig->{model} ne "automatic" 
			and !NMISNG::Util::getbool( $thisnodeconfig->{collect} )
			and $self->{update} )
		{
			$loadthis = "Model-$thisnodeconfig->{model}";
		}
		# no specific model, update yes, ping yes, collect no -> pingonly
		elsif ( NMISNG::Util::getbool( $thisnodeconfig->{ping} )
						and !NMISNG::Util::getbool( $thisnodeconfig->{collect} )
						and $self->{update} )
		{
			$loadthis = "Model-PingOnly";
		}
		# no specific model, update yes, ping no, collect no -> serviceonly
		elsif (!NMISNG::Util::getbool($thisnodeconfig->{ping})
			and !NMISNG::Util::getbool($thisnodeconfig->{collect})
			and defined $thisnodeconfig->{services}
			and $thisnodeconfig->{services} ne "" )
		{
			$loadthis = "Model-ServiceOnly";
		}

		# default model otherwise
		$self->nmisng->log->debug("loading model $loadthis for node $self->{name}");
	}

	# model loading failures are terminal
	return 0 if ( !$self->loadModel( model => $loadthis ) );

	# if a policy is given, override the database timing part of the model data
	# traverse all the model sections, find out which sections are subject to which timing policy
	if ($self->{node} && ref($policy) eq "HASH")
	{
		# must get that before it's overwritten
		my $standardstep = $self->{mdl}->{database}->{db}->{timing}->{default}->{poll} // 300;
		my %resizeme;								# section name -> factor

		for my $topsect (keys %{$self->{mdl}})
		{
			next if (ref($self->{mdl}->{$topsect}->{rrd}) ne "HASH");
			for my $subsect (keys %{$self->{mdl}->{$topsect}->{rrd}})
			{
				my $interesting = $self->{mdl}->{$topsect}->{rrd}->{$subsect};
				my $haswmi = ref($interesting->{wmi}) eq "HASH";
				my $hassnmp = ref($interesting->{snmp}) eq "HASH";

				if ($hassnmp and $haswmi)
				{
					$self->nmisng->log->debug2("section $subsect subject to both snmp and wmi poll policy overrides: "
														. "poll snmp $policy->{snmp}, wmi $policy->{wmi}");
					# poll: smaller of the two, heartbeat: larger of the two
					my $poll = defined($policy->{snmp})?  $policy->{snmp} : 300;
					$poll = $policy->{wmi} if (defined($policy->{wmi}) && $policy->{wmi} < $poll);
					$poll ||= 300;

					my $heartbeat = defined($policy->{snmp})?  $policy->{snmp} : 300;
					$heartbeat = $policy->{wmi} if (defined($policy->{wmi}) && $policy->{wmi} > $heartbeat);
					$heartbeat ||= 300;
					$heartbeat *= 3;

					my $thistiming = $self->{mdl}->{database}->{db}->{timing}->{$subsect} ||= {};

					$thistiming->{poll} = $poll;
					$thistiming->{heartbeat} = $heartbeat;

					$self->nmisng->log->debug("overrode rrd timings for $subsect with step $poll, heartbeat $heartbeat");
					$resizeme{$subsect} = $standardstep / $poll;
				}
				elsif ($haswmi or $hassnmp)
				{
					my $which = $hassnmp? "snmp" : "wmi";
					if (defined $policy->{$which})
					{
						$self->nmisng->log->debug2("section \"$subsect\" subject to $which polling policy override: poll $policy->{$which}");

						my $thistiming = $self->{mdl}->{database}->{db}->{timing}->{$subsect} ||= {};
						$thistiming->{poll} = $policy->{$which} || 300;
						$thistiming->{heartbeat} = 3*( $policy->{$which} || 900);

						$resizeme{$subsect} = $standardstep / $thistiming->{poll};
					}
				}
			}
		}
		# AND set the default to the snmp timing, to cover unmodelled sections
		# (which are currently all snmp-based, e.g. hrsmpcpu)
		if ($policy->{snmp})				# not null
		{
			$self->{mdl}->{database}->{db}->{timing}->{default}->{poll} = $policy->{snmp};
			$self->{mdl}->{database}->{db}->{timing}->{default}->{heartbeat} = 3* $policy->{snmp};
			$resizeme{default} = $standardstep / $policy->{snmp};
		}

		# increase the rows_* sizes for these sections, if the step is shorter than the default
		# use 'default' or hardcoded default if missing
		my $standardsize = (ref($self->{mdl}->{database}->{db}->{size}) eq "HASH"
												&& ref($self->{mdl}->{database}->{db}->{size}->{default}) eq "HASH"?
												{ %{$self->{mdl}->{database}->{db}->{size}->{default} }} # shallow clone required, default is ALSO changed!
												: { step_day => 1, step_week => 6, step_month => 24, step_year => 288,
														rows_day => 2304, rows_week => 1536, rows_month => 2268, rows_year => 1890 });
		for my $maybe (sort keys %resizeme)
		{
			my $factor = $resizeme{$maybe};
			next if ($factor <= 1);

			my $sizesection = $self->{mdl}->{database}->{db}->{size} ||= {};
			$sizesection->{$maybe} ||= { %$standardsize }; # shallow clone
			for my $period (qw(day week month year))
			{
				$sizesection->{$maybe}->{"rows_$period"} =
						int($factor * $sizesection->{$maybe}->{"rows_$period"} + 0.5); # round up/down
			}
			$self->nmisng->log->debug2(
				sprintf("overrode rrd row counts for $maybe by factor %.2f",$factor));
		}
	}

	# init the snmp accessor if snmp wanted and possible, but do not connect (yet)
	if ( $self->{name} and $snmp and $thisnodeconfig->{collect} )
	{
		# remember name for error message, no relevance for comms
		$self->{snmp} = NMISNG::Snmp->new(
			nmisng => $self->nmisng,
			name  => $self->{name},
		);
	}

	# wmi: no connections supported AND we try this only if
	# suitable config args are present (ie. host and username, password is optional)
	if ( $self->{name} and $wantwmi and $thisnodeconfig->{host} and $thisnodeconfig->{wmiusername} )
	{
		my $maybe = NMISNG::WMI->new(
			host     => $thisnodeconfig->{host},
			domain   => $thisnodeconfig->{wmidomain},
			username => $thisnodeconfig->{wmiusername},
			password => $thisnodeconfig->{wmipassword},
			program  => $C->{"<nmis_bin>"} . "/wmic"
		);
		if ( ref($maybe) )
		{
			$self->{wmi} = $maybe;
		}
		else
		{
			$self->{error} = $maybe;    # not terminal
			$self->nmisng->log->error("failed to create wmi accessor for $self->{name}: $maybe");
		}
	}

	return $self->{error} ? 0 : 1;
}

# tiny accessor for figuring out if a node is configured for wmi
# returns: wmi accessor if configured, undef otherwise
#
# note: this does NOT imply that wmi WORKS, just that the node
# config is sufficient (e.g. node, username, password)
# note: must be called AFTER init() with wmi enabled!
sub wmi
{
	my ($self) = @_;

	return $self->{wmi};
}

# like above: accessor only works AFTER init() was run with snmp enabled,
# and doesn't imply snmp works, just that it's configured
sub snmp { my $self = shift; return $self->{snmp} }


# open snmp session based on host address, and test it end-to-end.
# if a host_backup is configured, attempt to fall back to that if
# the primary address doesn't work.
#
# for max message size we try in order: host-specific value if set for this host,
# what is given as argument or default 1472. argument is expected to reflect the
# global default.
#
# args: timeout, retries, oidpkt, max_repetitions, max_msg_size (all optional)
# returns: 1 if a working connection exists, 0 otherwise; fallback property in status() is also set.
#
# note: function MUST NOT skip connection opening based on collect t/f, because
# otherwise update ops can never bootstrap stuff.
sub open
{
	my ( $self, %args ) = @_;

	# prime config for snmp, based mostly on cfg->node - cloned to not leak any of the updated bits
	my $snmpcfg = Clone::clone( $self->{cfg}->{node} );
	my $catchall_data = $self->inventory( concept => 'catchall' )->data_live();

	# check if numeric ip address is available for speeding up, conversion done by type=update
	$snmpcfg->{host} = ( $catchall_data->{host_addr}
											 || $self->{cfg}{node}{host}
											 || $self->{name} );
	$snmpcfg->{timeout}         = $args{timeout}         || 5;
	$snmpcfg->{retries}         = $args{retries}         || 1;
	$snmpcfg->{oidpkt}          = $args{oidpkt}          || 10;
	$snmpcfg->{max_repetitions} = $args{max_repetitions} || undef;

	$snmpcfg->{max_msg_size} = $self->{cfg}->{node}->{max_msg_size} || $args{max_msg_size} || 1472;

	undef $self->{fallback};
	# first try to open the session and test it end to end;
	# if that doesn't work but a backup host address is a/v, try that as well
	# and flag the failover situation
	$self->nmisng->log->debug("Opening SNMP session for $self->{name} to $snmpcfg->{host}");
	my $isok = $self->{snmp}->open(config => $snmpcfg, debug => $self->{debug})
			&& $self->{snmp}->testsession;
	if (!$isok)
	{
		if ($self->{cfg}->{node}->{host_backup}) # present and non-empty
		{
			$snmpcfg->{host} = $self->{cfg}->{node}->{host_backup};
			$self->nmisng->log->debug("SNMP session using primary address for $self->{name} failed, trying backup address $snmpcfg->{host}");
			$isok = $self->{snmp}->open(config => $snmpcfg,
																	debug => $self->{debug})
					&& $self->{snmp}->testsession;
			$self->{fallback} = 1;
		}
		if (!$isok)
		{
			$self->{snmp_error} = $self->{snmp}->error;
			return 0;
		}
	}

	$catchall_data->{snmpVer} = $self->{snmp}->version;    # get back actual info
	return 1;
}

# close snmp session - if it's open
sub close
{
	my $self = shift;
	return $self->{snmp}->close if ( defined( $self->{snmp} ) );
}

# small helper to tell sys that snmp or wmi are considered dead
# and to stop using this mechanism until (re)init'd
# args: self, what (snmp or wmi)
# returns: nothing
sub disable_source
{
	my ( $self, $moriturus ) = @_;
	return if ( $moriturus !~ /^(wmi|snmp)$/ );

	$self->close() if ( $moriturus eq "snmp" );                      # bsts, avoid leakage
	$self->nmisng->log->debug("disabling source $moriturus") if ( $self->{$moriturus} );
	delete $self->{$moriturus};
}

# helper that returns interface info,
# but indexed by ifdescr instead of internal indexing by ifindex
#
# args: none
# returns: hashref
# note: does NOT return live data, the info is shallowly cloned on conversion!
# also note: inventory conversion could use model load to get the data a bit faster
sub ifDescrInfo
{
	my ($self) = @_;

	my %ifDescrInfo;
	my $catchall_data = $self->inventory( concept => 'catchall' )->data();

	# if we have many interfaces then fetch them on-by-one so we don't load a mountain of data at one time
	# a smart iterator here in the ModelData would make more sense as it could fetch as we work in lots that
	# we determine
	# this code is basically here as an example of why we might want an iterator
	if( $catchall_data->{intfCollect} < 100 )
	{
		my $ids = $self->nmisng_node->get_inventory_ids( concept => 'interface' );
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $self->nmisng_node->inventory( _id => $id, debug=>1 );
			my $thisentry = ($inventory) ? $inventory->data : {};
			if( !$inventory || $error_message)
			{
				print "no inventory for node:$self->{name}, id:$id, error_message:$error_message".Carp::longmess();
			}
			my $ifDescr   = $thisentry->{ifDescr};

			$ifDescrInfo{$ifDescr} = {%$thisentry};
		}
	}
	else
	{
		my $result = $self->nmisng_node->get_inventory_model( concept => 'interface' );
		if (my $error = $result->error)
		{
			$self->nmisng->log->error("get inventory model failed: $error");
			return {};
		}
		foreach my $model (@{$result->data})
		{
			my $thisentry = $model->{data};
			my $ifDescr   = $thisentry->{ifDescr};

			$ifDescrInfo{$ifDescr} = {%$thisentry};
		}
	}
	return \%ifDescrInfo;
}

#===================================================================

# copy config and model info into node info table
# args: type, if type==all then nodeModel and nodeType are only updated from mdl if missing
# if type==overwrite then nodeModel and nodeType are updated unconditionally
# returns: nothing
#
# attention: if sys wasn't initialized with snmp true, then cfg will be blank!
# if no type arg, then nodemodel and type aren't touched
sub copyModelCfgInfo
{
	my ( $self, %args ) = @_;
	my $type = $args{type};

	my $catchall_data = $self->inventory(concept => 'catchall')->data_live();

	# copy all node info, with the exception of auth-related fields
	my $dontcopy = qr/^(wmi(username|password)|community|(auth|priv)(key|password|protocol))$/;
	if ( ref( $self->{cfg}->{node} ) eq "HASH" )
	{
		for my $entry ( keys %{$self->{cfg}->{node}} )
		{
			next if ( $entry =~ $dontcopy );
			$catchall_data->{$entry} = $self->{cfg}->{node}->{$entry};
		}
	}

	if ( $type eq 'all' or $type eq 'overwrite' )
	{
		my $mustoverwrite = ( $type eq 'overwrite' );

		$self->nmisng->log->debug("nodeType=$catchall_data->{nodeType} nodeType(mdl)=$self->{mdl}{system}{nodeType} nodeModel=$catchall_data->{nodeModel} nodeModel(mdl)=$self->{mdl}{system}{nodeModel}"
		);

		# make the changes unconditionally if overwrite requested, otherwise only if not present
		$catchall_data->{nodeModel} = $self->{mdl}{system}{nodeModel}
			if ( !$catchall_data->{nodeModel} or $mustoverwrite );
		$catchall_data->{nodeType} = $self->{mdl}{system}{nodeType}
			if ( !$catchall_data->{nodeType} or $mustoverwrite );
	}
	my @graphs = split /,/,$self->{mdl}{system}{nodegraph};
	$catchall_data->{nodegraph} = \@graphs;
			# if ( !$catchall_data->{nodegraph} or $mustoverwrite );
}

# get info from node, using snmp and/or wmi
# Values are stored in given target, under class or given table arg
#
# args: class, section, index/port (more or less required),
# table (=name where data is parked, defaults to arg class),
# target (=hashref of where to store results, usually an inventory)
# debug (aka model; optional, just a debug flag!)
#
# returns 0 if retrieval was a _total_ failure, 1 if it worked (at least somewhat),
#  2 if it was skipped for some reason (like control)
#  if successful target will be filled in
# also sets details for status()
sub loadInfo
{
	my ( $self, %args ) = @_;

	my $class   = $args{class};
	my $section = $args{section};
	my $index   = $args{index};
	my $port    = $args{port};

	my $table     = $args{table} || $class;
	my $wantdebug = $args{debug};
	my $dmodel    = $args{model};             # if separate model printfs are wanted

	my $target = $args{target};
	if ( !$target )
	{
		$self->{error} = "loadInfo failed for $self->{name}: target not provided!";
		$self->nmisng->log->error("loadInfo failed for $self->{name}: target not provided!");
		return 0;
	}

	# pull from the class' sys section, NOT its rrd section (if any)
	my ( $result, $status ) = $self->getValues(
		class   => $self->{mdl}{$class}{sys},
		section => $section,
		index   => $index,
		port    => $port
	);
	$self->{wmi_error}  = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};
	$self->{error}      = $status->{error};

	# no data? okish iff marked as skipped
	if ( !keys %$result )
	{
		$self->{error} = "loadInfo failed for $self->{name}: $status->{error}";
		print "MODEL ERROR: ($self->{name}) on loadInfo, $status->{error}\n" if $dmodel;
		return 0;
	}
	elsif ( $result->{skipped} )    # nothing to report because model said skip these items, apparently all of them...
	{
		$self->nmisng->log->debug("no results, skipped because of control expression or index mismatch");
		return 2;
	}
	else                            # we have data, maybe errors too?
	{
		$self->nmisng->log->debug("got data, but errors as well: error=$self->{error} snmp=$self->{snmp_error} wmi=$self->{wmi_error}")
			if ( $self->{error} or $self->{snmp_error} or $self->{wmi_error} );

		$self->nmisng->log->debug3("MODEL loadInfo $self->{name} class=$class") if $wantdebug;

		# this takes each section returned and merges them together (all writes to output data do not mention the $section or $sect )
		foreach my $sect ( keys %{$result} )
		{
			print "MODEL loadInfo $self->{name} class=$class:\n" if $dmodel;
			if ( $index ne '' )
			{
			# NOTE: this code used to loop through all indices retured which does not make sense, so this check has been
			#   added to make sure no code expects that and the loop has been removed, this makes inventory easier as it
			#   can be passed in
				my @keys = keys %{$result->{$sect}};
				die "Expecting a single index back from getValues which corresponds to the data for the index requested"
					if ( @keys > 1 || $keys[0] ne $index );

				$self->nmisng->log->debug3("MODEL section=$sect") if $wantdebug;
				### 2013-07-26 keiths: need a default index for SNMP vars which don't have unique descriptions
				if ( $target->{index} eq '' )
				{
					$target->{index} = $index;
				}
				foreach my $ds ( keys %{$result->{$sect}->{$index}} )
				{
					my $thisval = $target->{$ds} = $result->{$sect}{$index}{$ds}->{value};
					my $modext = "";

					# complain about nosuchxyz
					if ( $wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/ )
					{
						$self->nmisng->log->debug3( ( $1 eq "SuchObject" ? "ERROR" : "WARNING" ) . ": name=$ds index=$index value=$thisval" );
						$modext = ( $1 eq "SuchObject" ? "ERROR" : "WARNING" );
					}
					print
						"  $modext:  oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds index=$index value=$result->{$sect}{$index}{$ds}{value}\n"
						if $dmodel;

					$self->nmisng->log->debug3( "store: class=$class, type=$sect, DS=$ds, index=$index, value=$thisval" );
				}

			}
			else
			{
				foreach my $ds ( keys %{$result->{$sect}} )
				{
					my $thisval = $target->{$ds} = $result->{$sect}{$ds}{value};
					my $modext = "";

					# complain about nosuchxyz
					if ( $wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/ )
					{
						my $level = $1 eq "SuchObject" ? "error" : "warn";
						$self->nmisng->log->$level("name=$ds  value=$thisval" );
						$modext = ( $1 eq "SuchObject" ? "ERROR" : "WARNING" );
					}
					$self->nmisng->log->debug3( "store: class=$class, type=$sect, DS=$ds, value=$thisval");
				}
			}
		}

		return 1;    # we're happy(ish) - snmp or wmi worked
	}
}

# get nodeinfo (subset) as defined by Model. Values are stored in catchall
# args: none
# returns: 1 if worked (at least somewhat), 0 otherwise - check status() for details
# NOTE: inventory keeping this around for now because whole node file not completely replaced yet
# NOTE: this is NOT for loading the <node>-info.json file!
sub loadNodeInfo
{
	my $self = shift;
	my %args = @_;

	my $C = NMISNG::Util::loadConfTable();
	my $catchall_data = $self->inventory( concept => 'catchall' )->data_live();

	my $exit = $self->loadInfo( class => 'system', target => $catchall_data );    # sets status

	# check if nbarpd is possible: wanted by model, snmp configured, no snmp problems in last load
	if ( NMISNG::Util::getbool( $self->{mdl}{system}{nbarpd_check} ) && $self->{snmp} && !$self->{snmp_error} )
	{
		# find a value for max-repetitions: this controls how many OID's will be in a single request.
		# note: no last-ditch default; if not set we let the snmp module do its thing
		my $max_repetitions = $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions};
		my %tmptable = $self->{snmp}->gettable( 'cnpdStatusTable', $max_repetitions );

		$catchall_data->{nbarpd} = keys %tmptable ? "true" : "false";
		$self->nmisng->log->debug("NBARPD is $catchall_data->{nbarpd} on this node");
	}
	return $exit;
}

# get data to store in rrd
# args: class, section, port, index (more or less required)
# ATTENTION: class is NOT a name, but a model substructure!
# if  no section is given, all sections will be handled.
# optional: debug (aka model), flag for debugging
# returns: data hashref or undef if error; also sets details for status()
sub getData
{
	my ( $self, %args ) = @_;

	my $index   = $args{index};
	my $port    = $args{port};
	my $class   = $args{class};
	my $section = $args{section};

	my $wantdebug = $args{debug};
	my $dmodel    = $args{model};
	$self->nmisng->log->debug("index=$index port=$port class=$class section=$section");

	if ( !$class )
	{
		$self->nmisng->log->error("($self->{name}) no class name given!");
		return;
	}
	if ( ref( $self->{mdl}->{$class} ) ne "HASH" or ref( $self->{mdl}->{$class}->{rrd} ) ne "HASH" )
	{
		$self->nmisng->log->error("($self->{name}) no rrd section for class $class!");
		return;
	}

	# this returns all collected goodies, disregarding nosave - must be handled upstream
	my ( $result, $status ) = $self->getValues(
		class   => $self->{mdl}{$class}{rrd},
		section => $section,
		index   => $index,
		port    => $port
	);
	$self->{error}      = $status->{error};
	$self->{wmi_error}  = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};
	$self->{skipped}    = $status->{skipped} // 0;

	# data? we're happy-ish
	if ( keys %$result )
	{
		$self->nmisng->log->debug3( "MODEL getData $self->{name} class=$class:" . Dumper($result) ) if ($wantdebug);
		if ($dmodel)
		{
			print "MODEL getData $self->{name} class=$class:\n";
			foreach my $sec ( keys %$result )
			{
				if ( $sec =~ /interface|pkts/ )
				{
					print "  section=$sec index=$index used to print ifDescr, pass it in as a param!!!\n";
				}
				else
				{
					print "  section=$sec index=$index port=$port\n";
				}
				if ( $index eq "" )
				{
					foreach my $nam ( keys %{$result->{$sec}} )
					{
						my $modext = "";
						$modext = "ERROR:"   if $result->{$sec}{$nam}{value} eq "noSuchObject";
						$modext = "WARNING:" if $result->{$sec}{$nam}{value} eq "noSuchInstance";
						print
							"  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam value=$result->{$sec}{$nam}{value}\n";
					}
				}
				else
				{
					foreach my $ind ( keys %{$result->{$sec}} )
					{
						foreach my $nam ( keys %{$result->{$sec}{$ind}} )
						{
							my $modext = "";
							$modext = "ERROR:"   if $result->{$sec}{$ind}{$nam}{value} eq "noSuchObject";
							$modext = "WARNING:" if $result->{$sec}{$ind}{$nam}{value} eq "noSuchInstance";
							print
								"  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam index=$ind value=$result->{$sec}{$ind}{$nam}{value}\n";
						}
					}
				}
			}
		}
	}
	elsif ( $status->{skipped} )
	{
		$self->nmisng->log->debug("getValues skipped collection, no results");
	}
	elsif ( $status->{error} )
	{
		$self->nmisng->log->error("Model: $status->{error}") if ($wantdebug);
	}
	return $result;
}

# get data from snmp and/or wmi, as requested by Model
#
# args: class, section, index, port (more or less required)
# ATTENTION: class is NOT name but MODEL SUBSTRUCTURE!
# NOTE: if section is not given, ALL existing sections are handled (including alerts!)
#
# returns: (data hash ref, status hash ref with keys 'error','skipped','nographs','wmi_error','snmp_error')
#
# skipped is set if a control expression disables collection OR not given index but section is indexed.
# (note that index given but unindexed session seen does NOT fall under skipped!)
#
# nographs is set if one or more sections have a no_graphs attribute set (not relevant for data, but for arg table)
#
# error is set to the last general error (e.g. dud model); similar for wmi_error and snmp_error, but these
# include more dynamic aspects (e.g. connection issues).
# error is completely independent of wmi_error and snmp_error; error does also NOT mean there's no data!
sub getValues
{
	my ( $self, %args ) = @_;

	my $class   = $args{class};
	my $section = $args{section};
	my $index   = $args{index};
	my $port    = $args{port};

	my ( %data, %status, %todos );

	# one or all sections?
	# attention: this does include 'alerts'!
	my @todosections
		= ( defined($section) && $section ne '' )
		? exists( $class->{$section} )
			? $section
			: ()
		: ( keys %{$class} );

	# check reasons for skipping first
	for my $sectionname (@todosections)
	{
		$self->nmisng->log->debug("wanted section=$section, now handling section=$sectionname");
		my $thissection = $class->{$sectionname};

		if ( defined($index) && $index ne '' && !$thissection->{indexed} )
		{
			$self->nmisng->log->debug("collect of type $sectionname skipped: NON-indexed section definition but index given");

			# we don't mark this as intentional skip, so the 'no oid' error may show up
			next;
		}
		elsif ( ( !defined($index) or $index eq '' ) and $thissection->{indexed} )
		{
			$self->nmisng->log->debug("collect of section $sectionname skipped: indexed section but no index given");
			$status{skipped} = "skipped $sectionname because indexed section but no index given";
			next;
		}

		# check control expression next
		if ( $thissection->{control} )
		{
			$self->nmisng->log->debug2( "control $thissection->{control} found for section=$sectionname");

			if (!$self->parseString(
						 string => "($thissection->{control}) ? 1:0",
						 index  => $index,
						 sect   => $sectionname,
						 type => defined $port? "interface": undef,
						 eval => 1,

				)
				)
			{
				$self->nmisng->log->debug2( "collect of section $sectionname with index=$index skipped: control $thissection->{control}");
				$status{skipped} = "skipped $sectionname because of control expression";
				next;
			}
		}

		# check if we should just skip any collect and leave this to a plugin to collect
		# we need to have an rrd section so we can define the graphtypes.
		if ($thissection->{skip_collect} and NMISNG::Util::getbool($thissection->{skip_collect}))
		{
			$self->nmisng->log->debug2("skip_collect $thissection->{skip_collect} found for section=$sectionname");
			$status{skipped} = "skipped $sectionname because skip_collect set to true";
			next;
		}

		NMISNG::Util::TODO("GRAPHTYPE: Does full removal of this code make sense?");
		# # should we add graphtype to given (info) table?
		# if ( ref($tbl) eq "HASH" )
		# {
		# 	if ( $thissection->{graphtype} )
		# 	{
		# 		# note: it's really index outer, then sectionname inner when an index is present.
		# 		my $target
		# 			= ( defined($index) && $index ne "" ) ? \$tbl->{$index}->{$sectionname} : \$tbl->{$sectionname};

		# 		my %seen;
		# 		for my $maybe ( split( ',', $$target ), split( ',', $thissection->{graphtype} ) )
		# 		{
		# 			++$seen{$maybe};
		# 		}
		# 		$$target = join( ",", keys %seen );
		# 	}

		# 	# no graphtype? complain if the model doesn't say deliberate omission - not terminal though
		# 	elsif ( NMISNG::Util::getbool( $thissection->{no_graphs} ) )
		# 	{
		# 		$status{nographs} = "deliberate omission of graph type for section $sectionname";
		# 	}
		# 	else
		# 	{
		# 		$status{error} = "$self->{name} is missing property 'graphtype' for section $sectionname";
		# 	}
		# }

		# prep the list of things to tackle, snmp first - iff snmp is ok for this node
		if ( ref( $thissection->{snmp} ) eq "HASH" && $self->{snmp} )
		{
			# expecting port OR index for interfaces, cbqos etc. note that port overrides index!
			my $suffix
				= ( defined($port) && $port ne '' ) ? ".$port"
				: ( defined($index) && $index ne '' ) ? ".$index"
				:                                       "";
			$self->nmisng->log->debug("class: index=$index port=$port suffix=$suffix");

			for my $itemname ( keys %{$thissection->{snmp}} )
			{
				my $thisitem = $thissection->{snmp}->{$itemname};
				next if ( !exists $thisitem->{oid} );

				$self->nmisng->log->debug3( "oid for section $sectionname, item $itemname primed for loading");

				# for snmp each oid belongs to one reportable thingy, and we want to get all oids in one go
				# HOWEVER, the same thing is often saved in multiple sections!
				if ( $todos{$itemname} )
				{
					if ( $todos{$itemname}->{oid} ne $thisitem->{oid} . $suffix )
					{
						$status{snmp_error}
							= "($self->{name}) model error, $itemname has multiple clashing oids!";
						$self->nmisng->log->error( $status{snmp_error} );
						next;
					}
					push @{$todos{$itemname}->{section}}, $sectionname;
					push @{$todos{$itemname}->{details}}, $thisitem;

					$self->nmisng->log->debug3("item $itemname present in multiple sections: " . join( ", ", @{$todos{$itemname}->{section}} ));
				}
				else
				{
					$todos{$itemname} = {
						oid     => $thisitem->{oid} . $suffix,
						section => [$sectionname],
						item    => $itemname,                    # fixme might not be required
						details => [$thisitem]
					};
				}
			}
		}

		# now look for wmi-sourced stuff - iff wmi is ok for this node
		if ( ref( $thissection->{wmi} ) eq "HASH" && $self->{wmi} )
		{
			for my $itemname ( keys %{$thissection->{wmi}} )
			{
				next if ( $itemname eq "-common-" );    # that's not a collectable item
				my $thisitem = $thissection->{wmi}->{$itemname};

				$self->nmisng->log->debug3( "wmi query for section $sectionname, item $itemname primed for loading");

				# check if there's a -common- section with a query for multiple items?
				my $query = (
					exists( $thisitem->{query} ) ? $thisitem->{query}
					: ( ref( $thissection->{wmi}->{"-common-"} ) eq "HASH"
							&& exists( $thissection->{wmi}->{"-common-"}->{query} ) )
					? $thissection->{wmi}->{"-common-"}->{query}
					: undef
				);

				# nothing to be done if we don't know what to query for, or if we don't know what field to get
				next if ( !$query or !$thisitem->{field} );

				# fixme: do wmi queries have to be rewritten/expanded with node properties?

				# for wmi we'd like to perform a query just ONCE for all involved items
				# but again the sme thing may need saving in more than one section
				if ( $todos{$itemname} )
				{
					if (   $todos{$itemname}->{query} ne $query
						or $todos{$itemname}->{details}->{field} ne $thisitem->{field}
						or $todos{$itemname}->{indexed} ne $thissection->{indexed} )
					{
						$status{wmi_error}
							= "($self->{name}) model error, $itemname has multiple clashing queries/fields!";
						$self->nmisng->log->error( $status{wmi_error} );
						next;
					}

					push @{$todos{$itemname}->{section}}, $sectionname;
					push @{$todos{$itemname}->{details}}, $thisitem;

					$self->nmisng->log->debug3("item $itemname present in multiple sections: " . join( ", ", @{$todos{$itemname}->{section}} ));
				}
				else
				{
					$todos{$itemname} = {
						query   => $query,
						section => [$sectionname],
						item    => $itemname,                # fixme might not be required
						details => [$thisitem],              # crucial: contains the field(name)
						indexed => $thissection->{indexed}
					};    # crucial for controlling  gettable
				}
			}
		}
	}

	# any snmp oids requested? if so, get all in one go and update
	# the involved todos entries with the raw data
	if ( my @haveoid = grep( exists( $todos{$_}->{oid} ), keys %todos ) )
	{
		my @rawsnmp = $self->{snmp}->getarray( map { $todos{$_}->{oid} } (@haveoid) );
		if ( my $error = $self->{snmp}->error )
		{
			$self->nmisng->log->error("($self->{name}) on get values by snmp: $error");
			$status{snmp_error} = $error;
		}
		else
		{
			for my $idx ( 0 .. $#haveoid )
			{
				$todos{$haveoid[$idx]}->{rawvalue} = $rawsnmp[$idx];
				$todos{$haveoid[$idx]}->{done}     = 1;
			}
		}
	}

	# any wmi queries requested? then perform the unique queries (once only!)
	# then update all involved fields
	if ( my @havequery = grep( exists( $todos{$_}->{query} ), keys %todos ) )
	{
		my %seen;
		for my $itemname (@havequery)
		{
			my $query = $todos{$itemname}->{query};

			if ( !$seen{$query} )
			{
				# fixme: do we need dynamically created lists of fields, ie. from the known-to-be wanted stuff?
				# or is a blanket retrieve-all-then-filter good enough? where are the costs, in wmic startup or the
				# extra data generation?
				my ( $error, $fields, $meta );

				# if this is an indexed query we must use gettable, get only returns the first result
				if ( defined($index) && defined( $todos{$itemname}->{indexed} ) )
				{
					# wmi gettable needs INDEX FIELD NAME, not index instance value!
					( $error, $fields, $meta ) = $self->{wmi}->gettable(
						wql   => $query,
						index => $todos{$itemname}->{indexed}
					);
				}
				else
				{
					( $error, $fields, $meta ) = $self->{wmi}->get( wql => $query );
				}
				if ($error)
				{
					$self->nmisng->log->error("($self->{name}) on get values by wmi: $error");
					$status{wmi_error} = $error;
				}
				else
				{
					# if indexed, gettable will have returned ALL known indices + values.
					$seen{$query} = $fields;
				}
			}

			# get the field name from the model entry
			# note: field name is enforced same across all target sections so we use the first one
			$todos{$itemname}->{rawvalue} = (
				defined $index
				? $seen{$query}->{$index}
				: $seen{$query}
			)->{$todos{$itemname}->{details}->[0]->{field}};
			$todos{$itemname}->{done} = 1;
		}
	}

	# now handle compute, format, replace, alerts etc.
	# prep the var replacement once
	my %knownvars = map { $_ => $todos{$_}->{rawvalue} } ( keys %todos );

	for my $thing ( values %todos )
	{
		next if ( !$thing->{done} );    # we should not end up with unresolved stuff but bsts

		my $value = $thing->{rawvalue};

		# where does it go? remember, multiple target sections possible - potentially with DIFFERENT calculate,
		# replace expressions etc!
		for my $sectionidx ( 0 .. $#{$thing->{section}} )
		{
			# (section and details are multiples, item, indexing, field(name) etc MUST be identical
			my ( $gothere, $sectiondetails ) = ( $thing->{section}->[$sectionidx], $thing->{details}->[$sectionidx] );

			# massaging: calculate and replace really should not be combined in a model,
			# but if you do nmis won't complain. calculate is done FIRST, however.
			# all calculate and CVAR expressions refer to the RAW variable value! (for now, as
			# multiple target sections can have different replace/calculate rules and
			# we can't easily say which one to pick)
			if ( exists( $sectiondetails->{calculate} ) && ( my $calc = $sectiondetails->{calculate} ) )
			{
				# setup known var value list so that eval_string can handle CVARx substitutions
				my ( $error, $result ) = $self->eval_string(
					string  => $calc,
					context => $value,

					# for now we don't support multiple or cooked, per-section values
					variables => [\%knownvars]
				);
				if ($error)
				{
					$status{error} = $error;
					$self->nmisng->log->error("($self->{name}) getValues failed: $error");
				}
				$value = $result;
			}

			# replace table: replace with known value, or 'unknown' fallback, or leave unchanged
			if ( ref( $sectiondetails->{replace} ) eq "HASH" )
			{

				my $reptable = $sectiondetails->{replace};
				$value = (
					  exists( $reptable->{$value} )  ? $reptable->{$value}
					: exists( $reptable->{unknown} ) ? $reptable->{unknown}
					:                                  $value
				);
			}

			# specific formatting requested?
			if ( exists( $sectiondetails->{format} ) && ( my $wantedformat = $sectiondetails->{format} ) )
			{
				$value = sprintf( $wantedformat, $value );
			}

			# don't trust snmp or wmi data; neuter any html.
			$value =~ s{&}{&amp;}gso;
			$value =~ s{<}{&lt;}gso;
			$value =~ s{>}{&gt;}gso;

			# then park the result in the data structure
			my $target = (
				defined $index
				? $data{$gothere}->{$index}->{$thing->{item}}
				: $data{$gothere}->{$thing->{item}}
			) ||= {};
			$target->{value} = $value;

			# rrd options come from the model
			$target->{option} = $sectiondetails->{option} if ( exists $sectiondetails->{option} );

			# as well as a title
			$target->{title} = $sectiondetails->{title} if ( exists $sectiondetails->{title} );

			# if this thing is marked nosave, ignore alerts
			if (   ( !exists( $target->{option} ) or $target->{option} ne "nosave" )
				&& exists( $sectiondetails->{alert} )
				&& $sectiondetails->{alert}->{test} )
			{
				my $test = $sectiondetails->{alert}->{test};
				$self->nmisng->log->debug3( "checking test $test for basic alert \"$target->{title}\"" );

				# setup known var value list so that eval_string can handle CVARx substitutions
				my ( $error, $result ) = $self->eval_string(
					string  => $test,
					context => $value,

					# for now we don't support multiple or cooked, per-section values
					variables => [\%knownvars]
				);
				if ($error)
				{
					$status{error} = "test=$test in Model for $thing->{item} for $gothere failed: $error";
					$self->nmisng->log->error("($self->{name}) test=$test in Model for $thing->{item} for $gothere failed: $error");
				}
				$self->nmisng->log->debug3( "test $test, result=$result");
				push @{$self->{alerts}}, {
					name    => $self->{name},
					type    => "test",
					event   => $sectiondetails->{alert}->{event},
					level   => $sectiondetails->{alert}->{level},
					ds      => $thing->{item},
					section => $gothere,                           # that's the section name
					source  => $thing->{query} ? "wmi" : "snmp",   # not sure we actually need that in the alert context
					value   => $value,
					test_result => $result,
				};
			}
		}
	}

	# nothing found but no reason why? not good.
	if ( !%data && !$status{skipped} )
	{
		my $sections = join(", ", @todosections);
		$status{error} = "ERROR ($self->{name}): ".(@todosections? "no values collected for section(s) $sections!" : "found no sections to collect!");
	}
	$self->nmisng->log->debug("loaded "
														. ( keys %todos || 0 )
														. " values, status: "
														. ( join( ", ", map {"$_='$status{$_}'"} ( keys %status ) ) || 'ok' ) );

	return ( \%data, \%status );
}

# next gen CVAR/$r evaluation function (will eventually become replacement for parsestring)
#
# args: string, context (=$r value), both required,
# optional variables (=array of one or more varname->val hash refs, checked in order)
# returns: (error message) or (undef, evaluation result)
#
# this understands: $r, CVAR, CVAR0-9; var values come from the first listed variables table
# that contains a match (exists, may be undef).
sub eval_string
{
	my ( $self, %args ) = @_;

	my ( $input, $context ) = @args{"string", "context"};
	return ("missing string to evaluate!")     if ( !defined $input );
	return ("missing context for evaluation!") if ( !defined $context );

	my $vars = $args{variables};

	my ( $rebuiltcalc, $consumeme, %cvar );
	$consumeme = $input;

	# rip apart calc, rebuild it with var substitutions
	while ( $consumeme =~ s/^(.*?)(CVAR(\d)?=(\w+);|\$CVAR(\d)?)// )
	{
		$rebuiltcalc .= $1;    # the unmatched, non-cvar stuff at the begin
		my ( $varnum, $decl, $varuse ) = ( $3, $4, $5 );    # $2 is the whole |-group

		$varnum = 0 if ( !defined $varnum );                # the CVAR case == CVAR0
		if ( defined $decl )                                # cvar declaration, decl holds item name
		{
			for my $source (@$vars)
			{
				next if ( ref($source) ne "HASH"
					or !exists( $source->{$decl} ) );
				$cvar{$varnum} = $source->{$decl};
				last;
			}

			return "Error: CVAR$varnum references unknown object \"$decl\" in expression \"$input\""
				if ( !exists $cvar{$varnum} );
		}
		else    # cvar use
		{
			return "Error: CVAR$varuse used but not defined in expression \"$input\""
				if ( !exists $cvar{$varuse} );

			$rebuiltcalc .= $cvar{$varuse};    # sub in the actual value
		}
	}
	$rebuiltcalc .= $consumeme;                # and the non-CVAR-containing remainder.

	my $r = $context;                          # backwards compat naming: allow $r inside expression
	$r = eval $rebuiltcalc;

	$self->nmisng->log->debug3("calc translated \"$input\" into \"$rebuiltcalc\", used variables: "
														 . join( ", ", "\$r=$context", map {"CVAR$_=$cvar{$_}"} ( sort keys %cvar ) )
														 . ", result \"$r\"");
	if ($@)
	{
		return "calculation=$rebuiltcalc failed: $@";
	}

	return ( undef, $r );
}

# look for node model in base Model, based on nodevendor (case-insensitive full match)
# and sysdescr (case-insensitive regex match) from nodeinfo
# args: none
# returns: model name or 'Default'
sub selectNodeModel
{
	my ( $self, %args ) = @_;
	my $catchall_data = $self->inventory( concept => 'catchall' )->data_live();
	my $vendor = $catchall_data->{nodeVendor};
	my $descr  = $catchall_data->{sysDescr};

	foreach my $vndr ( sort keys %{$self->{mdl}{models}} )
	{
		if ( $vndr =~ /^$vendor$/i )
		{
			# vendor found
			my $thisvendor = $self->{mdl}{models}{$vndr};
			foreach my $order ( sort { $a <=> $b } keys %{$thisvendor->{order}} )
			{
				my $listofmodels = $thisvendor->{order}->{$order};
				foreach my $mdl ( sort keys %{$listofmodels} )
				{
					if ( $descr =~ /$listofmodels->{$mdl}/i )
					{
						$self->nmisng->log->debug("INFO, Model \'$mdl\' found for Vendor $vendor and sysDescr $descr");
						return $mdl;
					}
				}
			}
		}
	}
	$self->nmisng->log->error("No model found for Vendor $vendor, returning Model=Default");
	return 'Default';
}

# load requested Model into this object,
# also updates the graph-subconcept relationship cache
#
# args: model, required
# fixme9: non-node mode is a dirty hack
#
# returns: 1 if ok, 0 if not; sets internal error status for status().
sub loadModel
{
	my ( $self, %args ) = @_;
	my $model = $args{model};
	my $exit  = 1;

	my ( $name, $mdl );
	# in non-node mode we don't have any catchall or other database a/v...
	my $catchall_data = $self->{name}? $self->inventory( concept => 'catchall' )->data_live() : {};
	my $C = $self->{config} // NMISNG::Util::loadConfTable();    # needed to determine the correct dir; generally cached and a/v anyway

	# load the policy document (if any)
	my $modelpol = NMISNG::Util::loadTable( dir => 'conf', name => 'Model-Policy', conf => $C );
	if ( ref($modelpol) ne "HASH" or !keys %$modelpol )
	{
		$self->nmisng->log->warn("ignoring invalid or empty model policy");
	}
	$modelpol ||= {};

	my $modelcachedir = $C->{'<nmis_var>'} . "/nmis_system/model_cache";
	if ( !-d $modelcachedir )
	{
		NMISNG::Util::createDir($modelcachedir);
		NMISNG::Util::setFileProtDiag(file =>$modelcachedir);
	}
	my $thiscf = "$modelcachedir/$model.json";
	my $mustloadfromsource = 1;

	if ( $self->{cache_models} && -f $thiscf )
	{
		# check if the cached data is stale: load the model, check all the mtimes of the common-xyz inputs and a few others
		$self->{mdl} = NMISNG::Util::readFiletoHash( file => $thiscf, json => 1, lock => 0, conf => $C );
		if ( ref( $self->{mdl} ) ne "HASH" or !keys %{$self->{mdl}} )
		{
			$self->{error} = "ERROR ($self->{name}) failed to load Model (from cache): $self->{mdl}";
			$exit = 0;
		}
		else
		{
			my $cfage = (stat($thiscf))[9];
			$self->nmisng->log->debug2("Verifying freshness of cached model \"$model\"");

			my $isstale;
			my @depstocheck = ( "Config", "Model", $model );
			map { push @depstocheck, "Common-".$self->{mdl}->{"-common-"}->{class}->{$_}->{"common-model"}; }
			(keys %{$self->{mdl}{'-common-'}{class}}) if (ref($self->{mdl}->{'-common-'}) eq "HASH"
																										&& ref($self->{mdl}->{'-common-'}->{class}) eq "HASH");

			for my $other (@depstocheck)
			{
				my $othermtime;
				if ($other eq "Config")	# all other others are models
				{
					$othermtime = NMISNG::Util::mtimeFile(dir => "conf", name => $other, conf => $C );
				}
				else
				{
					my $meta =  NMISNG::Util::getModelFile(model => $other, only_mtime => 1, conf => $C );
					$othermtime = $meta->{mtime} if ($meta->{success});
				}
				if ($othermtime > $cfage)
				{
					$self->nmisng->log->debug2("Cached model \"$model\" stale: mtime $cfage, older than \"$other\" ($othermtime).");
					$isstale = 1;
					last;
				}
				else
				{
					$self->nmisng->log->debug2("Cached model \"$model\" mtime $cfage compares ok to \"$other\" ($othermtime).");
				}
			}
			if ($isstale)
			{
				$mustloadfromsource = 1;
				$self->nmisng->log->debug("Cache for model $model stale, loading from source.");
			}
			else
			{
				$self->nmisng->log->debug("model $model loaded (from cache)");
				$mustloadfromsource = 0;
			}
		}
	}

	if ($mustloadfromsource)
	{
		# load the model file in question
		my $res = NMISNG::Util::getModelFile(model => $model, conf => $C );
		if (!$res->{success})
		{
			$self->{error} = "ERROR ($self->{name}) failed to load Model file for $model: $res->{error}!";
			$exit = 0;
		}
		else
		{
			# getModelFile returns live/shared/cached info, but we must not modify that shared original!
			$self->{mdl} = Clone::clone( $res->{data} );

			# prime the nodeModel property from the model's filename,
			# ignoring whatever may be in the deprecated nodeModel property
			# in the model file
			my $shortname = $model;
			$shortname =~ s/^Model-//;
			$self->{mdl}->{system}->{nodeModel} = $shortname;

			# continue with loading common Models
			foreach my $class ( keys %{$self->{mdl}{'-common-'}{class}} )
			{
				my $name = "Common-" . $self->{mdl}{'-common-'}{class}{$class}{'common-model'};
				my $commonres = NMISNG::Util::getModelFile(model => $name, conf => $C);
				if (!$commonres->{success})
				{
					$self->{error} = "ERROR ($self->{name}) failed to read Model file $name: $commonres->{error}!";
					$exit = 0;
				}
				else
				{
					# this mostly copies, so cloning not needed
					# however, an unmergeable model is terminal, mustn't be cached, useless.
					if ( !$self->_mergeHash( $self->{mdl}, $commonres->{data} ) )
					{
						$self->{error} = "ERROR ($self->{name}) model merging failed!";
						return 0;
					}
				}
			}
			$self->nmisng->log->debug("model $model loaded (from source)");

			# save to cache BEFORE the policy application, if caching is on OR if in update operation
			if ( -d $modelcachedir && ( $self->{cache_models} || $self->{update} ) )
			{
				NMISNG::Util::writeHashtoFile( file => $thiscf, data => $self->{mdl}, json => 1, pretty => 0, conf => $C );
			}
		}
	}

	# if the loading has succeeded (cache or from source), optionally amend with rules from the policy
	# and record what subconcepts are involved in providing what graphs - iff in node mode
	if ($exit && $self->{name})
	{
		# find the first matching policy rule
	NEXTRULE:
		for my $polnr ( sort { $a <=> $b } keys %$modelpol )
		{
			my $thisrule = $modelpol->{$polnr};
			$thisrule->{IF} ||= {};
			my $rulematches = 1;

			# all must match, order irrelevant
			for my $proppath ( keys %{$thisrule->{IF}} )
			{
				# input can be dotted path with node.X or config.Y; nonexistent path is interpreted
				# as blank test string!
				# special: node.nodeModel is the (dynamic/actual) model in question
				if ( $proppath =~ /^(node|config)\.(\S+)$/ )
				{
					my ( $sourcename, $propname ) = ( $1, $2 );

					my $value = (
						  $proppath eq "node.nodeModel"
						? $model
						: ( $sourcename eq "config" ? $C : $catchall_data )->{$propname}
					);
					$value = '' if ( !defined($value) );

					# choices can be: regex, or fixed string, or array of fixed strings
					my $critvalue = $thisrule->{IF}->{$proppath};

					# list of precise matches
					if ( ref($critvalue) eq "ARRAY" )
					{
						$rulematches = 0 if ( !List::Util::any { $value eq $_ } @$critvalue );
					}

					# or a regex-like string
					elsif ( $critvalue =~ m!^/(.*)/(i)?$! )
					{
						my ( $re, $options ) = ( $1, $2 );
						my $regex = ( $options ? qr{$re}i : qr{$re} );
						$rulematches = 0 if ( $value !~ $regex );
					}

					# or a single precise match
					else
					{
						$rulematches = 0 if ( $value ne $critvalue );
					}
				}
				else
				{
					db("ERROR, ignoring policy $polnr with invalid property path \"$proppath\"");
					$rulematches = 0;
				}
				next NEXTRULE if ( !$rulematches );    # all IF clauses must match
			}
			$self->nmisng->log->debug2("policy rule $polnr matched");

			# policy rule has matched, let's apply the settings
			# systemHealth is the only supported setting so far
			# note: _anything is reserved for internal purposes
			for my $sectionname (qw(systemHealth))
			{
				$thisrule->{$sectionname} ||= {};
				my @current = split( /\s*,\s*/,
					( ref( $self->{mdl}->{$sectionname} ) eq "HASH" ? $self->{mdl}->{$sectionname}->{sections} : "" ) );

				for my $conceptname ( keys %{$thisrule->{$sectionname}} )
				{
					# _anything is reserved for internal purposes, also on the inner level
					next if ( $conceptname =~ /^_/ );
					my $ispresent = List::Util::first { $conceptname eq $current[$_] } ( 0 .. $#current );

					if ( NMISNG::Util::getbool( $thisrule->{$sectionname}->{$conceptname} ) )
					{
						$self->nmisng->log->debug2("adding $conceptname to $sectionname" );
						push @current, $conceptname if ( !defined $ispresent );
					}
					else
					{
						$self->nmisng->log->debug2( "removing $conceptname from $sectionname");
						splice( @current, $ispresent, 1 ) if ( defined $ispresent );
					}
				}

				# save the new value if there is one; blank the whole systemhealth section
				# if there is no new value but there was a systemhealth section before; sections = undef is NOT enough.
				if (@current)
				{
					$self->{mdl}->{$sectionname}->{sections} = join( ",", @current );
				}
				elsif ( ref( $self->{mdl}->{$sectionname} ) eq "HASH" )
				{
					delete $self->{mdl}->{$sectionname};
				}
			}
			last NEXTRULE;    # the first match terminates
		}

		# populate the graphtype to subconcept relationship cache
		# this is needed to find instances that can serve graphtype X
		my $gt2sc = $self->{graphtype2subconcept} //= {};
		for my $toplevel (values %{$self->{mdl}})
		{
			# rrd section is where graphtypes may be, and that is always just under the toplevel
			next if (ref($toplevel->{rrd}) ne "HASH");

			my $section = $toplevel->{rrd};
			for my $concept (keys %{$section})
			{
				next if (!defined($section->{$concept}->{graphtype}));
				for my $onegt (split(/\s*,\s*/, $section->{$concept}->{graphtype}))
				{
					warn "invalid model $model: graphtype $onegt associated with two sections, $concept and $gt2sc->{$onegt}\n"
							if (defined $gt2sc->{$onegt} && $gt2sc->{$onegt} ne $concept);
					$gt2sc->{$onegt} = $concept;
				}
			}
		}

		# also handle the special case for service monitoring: graphtypes for services
		# are not modelled but determined dynamically. at least the graphtype to storage type is mostly static.
		my $fixedsubconcept = "service";
		if (ref($self->{mdl}->{database}) eq "HASH" && ref($self->{mdl}->{database}->{type}) eq "HASH")
		{
			for my $onegt (grep(/^service/, keys %{$self->{mdl}->{database}->{type}}))
			{
				warn "invalid model $model: graphtype $onegt associated with two sections, $fixedsubconcept and $gt2sc->{$onegt}\n"
							if (defined($gt2sc->{$onegt}) && $gt2sc->{$onegt} ne $fixedsubconcept);
				$gt2sc->{$onegt} = $fixedsubconcept;
			}
		}
		
		# and another special case: health section isn't modelled fully/properly
		$fixedsubconcept = "health";
		for my $onegt (qw(health kpi response numintf polltime))
		{
			warn "invalid model $model: graphtype $onegt associated with two sections, $fixedsubconcept and $gt2sc->{$onegt}\n"
					if (defined($gt2sc->{$onegt}) && $gt2sc->{$onegt} ne $fixedsubconcept);
			$gt2sc->{$onegt} = $fixedsubconcept;
		}
	}
			
	return $exit;
}

# small internal helper that merges two hashes
# args: self, destination hashref, source hashref, optional recursion level indicator
# stuff from source overwrites stuff in dest, including arrays.
#
# returns: destination hashref or undef, also sets details for status().
sub _mergeHash
{
	my ( $self, $dest, $source, $lvl ) = @_;

	$lvl ||= '';
	$lvl .= "=";

	while ( my ( $k, $v ) = each %{$source} )
	{
		$self->nmisng->log->debug4( "$lvl key=$k, val=$v" );

		if ( ref( $dest->{$k} ) eq "HASH" and ref($v) eq "HASH" )
		{
			$self->_mergeHash( $dest->{$k}, $source->{$k}, $lvl );
		}
		elsif ( ref( $dest->{$k} ) eq "HASH" and ref($v) ne "HASH" )
		{
			$self->{error} = "cannot merge inconsistent hash: key=$k, value=$v, value is " . ref($v);
			$self->nmisng->log->error( "($self->{name}) " . $self->{error} );
			return undef;
		}
		else
		{
			$dest->{$k} = $v;
			$self->nmisng->log->debug4( "$lvl > load key=$k, val=$v");
		}
	}
	return $dest;
}

# search in Model for Title based on attribute name
# attention: searches ONLY the sys areas, NOT rrd!
# args: self, attr (required), section (optional)
# returns: title string or undef
sub getTitle
{
	my ( $self, %args ) = @_;
	my $attr    = $args{attr};
	my $section = $args{section};

	for my $class ( keys %{$self->{mdl}} )
	{
		next if ( defined($section) and $class ne $section );
		my $thisclass = $self->{mdl}->{$class};
		for my $sectionname ( keys %{$thisclass->{sys}} )
		{
			my $thissection = $thisclass->{sys}->{$sectionname};

			# check both wmi and snmp sections
			for my $maybe (qw(snmp wmi))
			{
				return $thissection->{$maybe}->{$attr}->{title}
					if (ref( $thissection->{$maybe} ) eq "HASH"
					and ref( $thissection->{$maybe}->{$attr} ) eq "HASH"
					and exists( $thissection->{$maybe}->{$attr}->{title} ) );
			}
		}
	}
	return undef;
}

# add a whole bunch of variables to the extras hash that parseString added so are now
# required for backwards compat
#
# NOTE: if section is empty sometimes type has it ( getFileName from RRDfunc does this,
# interface comes through as, the type)
#
#.  and sometimes neither have anything useful! (Like cbqos telling us the class name, useless!!!!
#   Instead of blindly trying to load the interface everytime we will only do it when it makes sense,
#   except we can't do this yet! :(
#.  we need to be told us when that is!
# so for now if the section|type are interface|pkts, or the $str has interface in it
# (assuming we are making a filename) and we have a valid index then load interface info
#
# fixme9: operation in non-node mode is a dirty hack
sub prep_extras_with_catchalls
{
	my ($self, %args) = @_;
	my $extras = $args{extras};
	my $index = $args{index};
	my $item = $args{item};
	my $section = $args{section};
	my $str = $args{str};
	my $type = $args{type};
	my $inventory = $args{inventory};

	# so sadly this is not enough to make interface work right now
	$section ||= $type;

	# this can only work in node-mode. fixme9: is op w/o extras enough for even rudimentary non-nodemode?
	if ($self->{name})
	{
		# if new one is there use it
		my $data = $self->inventory(concept => "catchall")->data_live();
		$extras->{node} ||= $self->{node};

		foreach my $key (qw(name host group roleType nodeModel nodeType nodeVendor sysDescr sysObjectName location))
		{
			$extras->{$key} ||= $data->{$key};
		}
		# if I am wanting a storage thingy, then lets populate the variables I need.
		if ( $index ne ''
				 and $str =~ /(hrStorageDescr|hrStorageSize|hrStorageUnits|hrDiskSize|hrDiskUsed|hrStorageType)/ )
		{
			my $data;
			# get the storage's inventory if not passed in
			my $storage_inventory = $inventory
					|| $self->inventory(concept => 'storage', index => $index, nolog => 1);
			$data = $storage_inventory->data() if( $storage_inventory );

			foreach my $key (qw(hrStorageType hrStorageUnits hrStorageSize hrStorageUsed))
			{
				$extras->{$key} ||= $data->{$key};
			}
			$extras->{hrDiskSize} = $extras->{hrStorageSize} * $extras->{hrStorageUnits};
			$extras->{hrDiskUsed} = $extras->{hrStorageUsed} * $extras->{hrStorageUnits};
			$extras->{hrDiskFree} = $extras->{hrDiskSize} - $extras->{hrDiskUsed};
		}

		# pretty sure cbqos needs this too, or just if it's got a numbered index (unhappy!!!!)
		# fixme9: utterly and irredeemably borked
		if ( ($section =~ /interface|pkts|cbqos/ || $str =~ /interface/ || $str =~ /ifSpeed/ || $type eq "interface")
				 && $index =~ /\d+/ )
		{
			# inventory keyed by index and ifDescr so we need partial; using _the_ passed in
			# inventory is clearly safer - IFF it's of the right type		
			my $interface_inventory = ($inventory && ref($inventory) =~ /Inventory/ && $inventory->concept eq "interface"?
																 $inventory
																 : $self->inventory(concept => 'interface',
																										index => $index, nolog => 1, partial => 1));
			if( $interface_inventory )
			{
				# no fallback to info section as interface update is running
				$data = $interface_inventory->data();
				foreach my $key (qw(ifAlias Description ifType))
				{
					$extras->{$key} ||= $interface_inventory->$key();

				}

				$extras->{ifDescr} ||=  NMISNG::Util::convertIfName($interface_inventory->ifDescr());
				$extras->{ifMaxOctets} ||= $interface_inventory->max_octets();
				$extras->{maxBytes}    ||= $interface_inventory->max_bytes();
				$extras->{maxPackets}  ||= $interface_inventory->max_packets();
				$extras->{ifSpeedIn}   ||= $interface_inventory->ifSpeedIn();
				$extras->{ifSpeedOut}  ||= $interface_inventory->ifSpeedOut();
				$extras->{ifSpeed} ||= $interface_inventory->ifSpeed();
				$extras->{speed}       ||= $interface_inventory->speed();
			}
		}
		else
		{
			$extras->{ifDescr} ||= $extras->{ifType} ||= '';
			$extras->{ifSpeed} ||= $extras->{ifMaxOctets} ||= 'U'; # fixme9 not clear what purpose that served?
		}
		# Add inventory data
		my $concept = $section;
		if ( $item != $index ) {
			$concept = $item;
		}
	
		my $storage_inventory = $inventory
					|| $self->inventory(concept => $concept, index => $index, nolog => 1);

		if ($storage_inventory) {
			my $inv_data = $storage_inventory->data() if( ref($storage_inventory) =~ /Inventory/ );
			if ($inv_data) {
				foreach my $key (keys %$inv_data)
				{
					$extras->{$key} ||= $inv_data->{$key};
				}
			}
		}
		
	}

	$extras->{item} ||= $item;
	$extras->{index} ||= $index;

	return $extras;
}

#===================================================================
# parse string to replace scalars or evaluate string and return result
# args: self=sys, string (required),
# optional: sect, index, item, type. CVAR stuff works ONLY if sect is set!
# type and index are only used in substitutions, no logic attached.
# also optional: extras (hash of substitutable varname-values)
# also optional: inventory (passed through to the prep function if present)
#
# note: variables in BOTH rrd and sys sections should be found in this routine,
# regardless of whether our caller is looking at rrd or sys.
# returns: parsed string
# fixme: does only log errors, not report them
sub parseString
{
	my ( $self, %args ) = @_;

	my ( $str, $indx, $itm, $sect, $type, $extras, $eval, $inventory, $filter ) = @args{"string", "index", "item", "sect", "type", "extras", "eval","inventory", "filter"};

	$self->nmisng->log->debug3( "parseString:: sect:$sect, type:$type, string to parse '$str'");
	# if there is no eval and no variables for substitution are found, just return
	if( !$eval && $str !~ /\$/ )
	{
		return $str;
	}

	# find custom variables CVAR[n]=thing; in section, and substitute $extras->{CVAR[n]} with the value
	if ( $sect )
	{
		$inventory ||= $self->inventory( concept => $sect, index => $indx, nolog => 1 );
		my $data = ($inventory) ? $inventory->data : {};
		my $consumeme = $str;
		my $rebuilt;

		# nongreedy consumption up to the first CVAR assignment
		while ( $consumeme =~ s/^(.*?)CVAR(\d)?=(\w+);// )
		{
			my ( $number, $thing ) = ( $2, $3 );
			$rebuilt .= $1;
			$number = '' if ( !defined $number );    # let's support CVAR, CVAR0 .. CVAR9, all separate

			$self->nmisng->log->error("parseString cannot expand $thing: not a known property in section $sect!")
				if ( !exists $data->{$thing} );

			# let's set the global CVAR or CVARn to whatever value from the node info section
			$extras->{"CVAR$number"} = $data->{$thing};

			$self->nmisng->log->debug3( "found assignment for CVAR$number, $thing, value " . $extras->{"CVAR$number"});
		}
		$rebuilt .= $consumeme;    # what's left after looking for CVAR assignments

		$self->nmisng->log->debug3("var extraction transformed \"$str\" into \"$rebuilt\"\nvariables: "
															 . join( ", ", map { "CVAR$_=" . $extras->{"CVAR$_"}; } ( "", 0 .. 9 ) ));

		$str = $rebuilt;
	}

	$extras = Clone::clone( $extras // {}); # we want no changes to the caller's variables

	$self->prep_extras_with_catchalls( extras => $extras,
																		 index => $indx,
																		 item => $itm,
																		 section => $sect,
																		 str => $str,
																		 type => $type,
																		 inventory => $inventory);
	$self->nmisng->log->debug3( "extras:".Data::Dumper->new([$extras])->Terse(1)->Indent(0)->Pair(": ")->Dump);

	# massage the string and replace any available variables from extras,
	# but ONLY WHERE no compatibility hardcoded variable is present.
	#
	# if the extras substitution were to be done first, then the identically named
	# but OCCASIONALLY DIFFERENT hardcoded global values will clash and we get breakage all over the place.
	if ( ref($extras) eq "HASH" && keys %$extras)
	{
		# must be done longest-first or we'll wreck $ifSpeedIn by replacing it with <value of ifSpeed>In...
		for my $maybe ( sort { length($b) <=> length($a) } keys %$extras )
		{
			$extras->{$maybe} = '"'.$extras->{$maybe}.'"'	if ($eval && $extras->{$maybe} !~  /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );
			my $presubst = $str;

			# this substitutes $varname and ${varname},
			# the latter is safer b/c the former has trouble with varnames sharing a prefix.
			# no look-ahead assertion is possible, we don't know what the string is used for...
			if ( $str =~ s/(\$$maybe|\$\{$maybe\})/$extras->{$maybe}/g )
			{
				if ($filter) {
					$str = $presubst;
					my $str2 = NMISNG::Util::filterName($extras->{$maybe});
					$str =~ s/(\$$maybe|\$\{$maybe\})/$str2/g;
					$self->nmisng->log->debug3( "substituted '$maybe', str before '$presubst', after '$str'" );
				}
			
				$self->nmisng->log->debug3( "substituted '$maybe', str before '$presubst', after '$str'" );
				# print "substituted '$maybe', str before '$presubst', after '$str'\n";
			}
			
		}
	}
	# no luck and no evaluation possible/allowed? give up, and do it loudly!
	if( !$eval && $str =~ /\$/)
	{
		$self->nmisng->log->fatal("parseString failed to fully expand \"$str\"! extras were: ".Dumper($extras));
		Carp::confess("parseString failed to fully expand \"$str\"!");
	}

	my $product = ($eval) ? eval $str : $str;
	$self->nmisng->log->error("parseString failed for str:$str, error:$@") if($@);
	$self->nmisng->log->debug3( "parseString:: result is str=$product");
	return $product;
}


# fixme9: left for backwards-compatibility only!
# fixme9: this CANNOT work for non-node mode
#
# returns a r/o hash of graphtype -> subconcept (=rrd section) name for this node
# args: none
# returns: hashref
sub loadGraphTypeTable
{
	my ($self) = @_;
	return Clone::clone($self->{graphtype2subconcept});
}


# find instances of a particular (graph)type/
#
# fixme: this is for backwards-compat ONLY, needs to be be replaced by
# direct inventory searching
# (why? because this assumes that everything
# is sorta-indexed with a particular identifier, which isn't true with inventory)
#
# this function returns the indices of instances/things for a
# particular graphtype, eg. all the known disk indices when asked for graphtype=hrdisk,
# or all interface indices when asked for section=interface;
# OR all the inventory data (wrapped in modeldata obj) if want_modeldata is set.
#
# arguments: graphtype(=subconcept for inventory) or section (=concept);
# if both are given, then inventory instances that match either will be returned
# fixme: if both graphtype and section are given, but the graphtype doesn't
# belong to that section, then highly misleading data will be returned!
#
# fixme9: non-node mode is a dirty hack
#
# returns: list of matching indices - for indexed stuff the data.index property,
# for services the data.service name; or modeldata with all inventory data.
sub getTypeInstances
{
	my ( $self, %args ) = @_;
	my ($graphtype,$section,$want_modeldata,$want_active) = @args{qw(graphtype section want_modeldata want_active)};

	my (@instances,$modeldata);

	# query the inventory model for concept same as section (if section was given)...
	# fixme9: can only work in node mode
	if (defined $section && $self->{name})
	{
		my $fields_hash = ($want_modeldata) ? undef :  { "data.index" => 1, "data.service" => 1 };

		# in case of indexed, return the index; for service return the service name
		my $result = $self->nmisng->get_inventory_model(cluster_id => $self->nmisng_node->cluster_id,
																										node_uuid => $self->nmisng_node->uuid,
																										concept => $section,
																										fields_hash => $fields_hash );
		if (my $error = $result->error)
		{
			$self->nmisng->log->error("get inventory model failed: $error");
		}
		elsif ($result->count && !$want_modeldata)
		{
			for my $entry (@{$result->data})
			{
				push @instances, $entry->{data}->{index} // $entry->{data}->{service};
			}
		}
		else
		{
			$modeldata = $result;
		}
	}

	# if a graphtype is given, infer the concept from that via graphtype2subconcept,
	# subconcept == concept for anything but concept service (has more), and concept
	# interface (has subconcepts pkts, pkts_hc, interface).
	# then look for actual instances, via storage!
	if (defined $graphtype)
	{
		my $subconcept = $self->{graphtype2subconcept}->{$graphtype};
		my $concept;
		# this is to handle custom graph types, e.g. for services - these are not known to the model,
		# hence not hin graphtype2subconcept; there the subconcept == graphtype.
		if ($graphtype =~ /^service/)
		{
			$subconcept = $graphtype;
			$concept = "service"
		}
		else
		{
			#
			# other backwards compat mess: section names are historically ALSO fed in as graphtype,
			# never mind that there are no such graphs...
			$subconcept ||= $graphtype;
			$concept = $subconcept;
			# and here's  interfaces, multiple subconcepts for concept interface and other messes
			$concept = 'interface' if ($subconcept =~ /^(pkts|pkts_hc|interface)$/);
			$concept = 'device' if ($subconcept =~ /^(hrsmpcpu)$/);
			$concept = 'storage' if ($subconcept =~ /^(hrdisk|hrmem|hrswapmem|hrvmem|hrbufmem|hrcachemem)$/);
		}

		# fixme harsh, but better we see gotchas now...
		die "error: no subconcept known for graphtype $graphtype!"
				if (!$subconcept);
		die "error: no concept known for graphtype $graphtype!"
				if (!$concept);

		# graphtype ALSO given but same as (handled) section or points to that section,
		# and we have instances? then ignore the graphtype,  or we'll get duplicates
		if (($want_modeldata && $modeldata && $modeldata->count || @instances)
				&& defined($section)
				&& (($section eq $concept) || ($section eq $graphtype)))
		{
			$self->nmisng->log->debug2("covered section $section, not looking up graphtype $graphtype");
			# modeldata is just a container here, no object instantiation expected or possible
			return $want_modeldata? ($modeldata || NMISNG::ModelData->new(data => \@instances)) : @instances;
		}

		# fixme9: can only work in node mode
		if ($self->{name})
		{
			# and ask ONLY for the ones where a suitable storage element is present!
			# note: doesn't check deeper, ie. for rrd key. storage knowledge embedded here is not ideal,
			# but at least only the agreed-upon 'subconcept will have a key if available' is required
			my $fields_hash = ($want_modeldata) ? undef : { "data.index" => 1,"data.service" => 1 };
			my $filter = { "storage.$subconcept" => { '$exists' => 1 }};
			if( $want_active )
			{
				$filter->{enabled} = 1;
				$filter->{historic} = 0;
			}
			my $result =  $self->nmisng->get_inventory_model(cluster_id => $self->nmisng_node->cluster_id,
																											 node_uuid => $self->nmisng_node->uuid,
																											 concept => $concept,
																											 filter => $filter,
																											 fields_hash => $fields_hash );
			if (my $error = $result->error)
			{
				$self->nmisng->log->error("get inventory model failed: $error");
			}
			elsif ($result->count && !$want_modeldata)
			{
				for my $entry (@{$result->data})
				{
					push @instances, $entry->{data}->{index} // $entry->{data}->{service};
				}
			}
			else
			{
				$modeldata = $result;
			}
		}
	}
	
	# modeldata is just a container here, no object instantiation expected or possible
	return ($want_modeldata) ? ($modeldata || NMISNG::ModelData->new()) : @instances;
}

# compute the rrd file path for this graphtype+node+index/item
# which is based on graphtype -> subsection/rrd name,
# index and item; and certainly the information in the node's model and common-database.
#
# args: type or graphtype, index, item (mostly required), inventory (optional),
# extras (optional, hash),
# relative (optional, default false - if set, path is relative to database_root)
#
# if graphtype is given, a translation from that to rrd section name is performed (e.g. abits => interface)
# if that doesn't work, graphtype is tried as-is.
# if type is given, then it's assumed to hold the rrd type name directly (e.g. pkts remains pkts)
#
# returns: rrd file path (relative to database_root or absolute) or undef
sub makeRRDname
{
	my ( $self, %args ) = @_;

	my $type = $args{type};
	my $graphtype = $args{graphtype};

	my $index     = $args{index};
	my $item      = $args{item};

	my $extras = $args{extras};
	my $wantrelative = NMISNG::Util::getbool($args{relative});
	my $inventory = $args{inventory};
	my $C = $self->{conf} // $args{conf} // NMISNG::Util::loadConfTable if (!$wantrelative); # only needed for database_root

	# if necessary, find the subconcept that belongs to this graphtype  - this
	# is the same as the rrd section name, and thus the database type name
	my $sectionname = $type;
	if (!defined $type)
	{
		$sectionname = $self->{graphtype2subconcept}->{$graphtype};
		# this is a pretty ugly fallback for compatibility purposes...
		# everything called the predecessor getdbname with graphtype, whether it was a graphtype
		# or a sectionname...
		$sectionname = $graphtype if (!defined $sectionname);
	}

	if (!defined $sectionname)
	{
		$self->nmisng->log->error("makeRRDname failed: no rrd section known for graphtype=$graphtype, type=$type");
		return undef;
	}
	my $template = (ref($self->{mdl}->{database}) eq "HASH"
									&& ref($self->{mdl}->{database}->{type}) eq "HASH")?
									$self->{mdl}->{database}->{type}->{$sectionname} : undef;

	if (!defined $template)
	{
		$self->nmisng->log->error("($self->{name}) database name not found for graphtype=$graphtype, type=$type, index=$index, item=$item, sect=$sectionname");
		return undef;
	}


	# if we have no index but item: fall back to that, and vice versa
	if ( defined $item && $item ne '' && ( !defined $index || $index eq '' ) )
	{
		$self->nmisng->log->debug2( "synthetic index from item for type=$type, item=$item");
		$index = $item;
	}
	elsif ( defined $index && $index ne '' && ( !defined $item || $item eq '' ) )
	{
		$self->nmisng->log->debug2( "synthetic item from index for type=$type, index=$index" );
		$item = $index;
	}

	# expand the $xyz strings in the template
	# also, all optional inputs must be safeguarded, as indices (for example) can easily contain '/'
	# and at least these /s must be removed
	my $safetype = $graphtype // $type;
	$safetype =~ s!/!_!g;
	my $safeindex = $index; $safeindex =~ s!/!_!g;
	my $safeitem = $item; $safeitem =~ s!/!_!g;
	my %safeextras = ref($extras) eq "HASH"? %{$extras} :  ();
	map { $safeextras{$_} =~ s!/!_!g; } (keys %safeextras);

	my $dbpath = $self->parseString(string => $template,
																	type => $safetype,
																	index => $safeindex,
																	item => $safeitem,
																	extras => \%safeextras,
																	inventory => $inventory,
																	'eval' => 0, # only expand, no expression to evaluate
																	filter => 1); # Remove blanks and backslash
	if (!$dbpath)
	{
		$self->nmisng->log->error("makeRRDname: expansion of $template failed!");
		return undef;
	}
	$dbpath = $C->{database_root}."/".$dbpath if (!$wantrelative);
	$self->nmisng->log->debug("filename for graphtype=$graphtype, type=$type is $dbpath");
	return $dbpath;
}

# high-level wrapper for handling rrd updates
#
# this takes care of filenames, extra logic that's based on knowledge in sys,
# and then delegates the work to module rrdfunc.
# args: self, data, type/item/index - mostly required,
# inventory (optional, if given it's checked for known rrd file - note
# that it MUST be the matching object for this particular instance!),
# extras (optional hash of extra substitutables for naming)
# returns: the database file name or undef, logs errors
sub create_update_rrd
{
	my ($self, %args) = @_;
	my ($inventory,$type,$item,$index,$data,$extras) = @args{qw(inventory type item index data extras)};

	my $C = $self->{config} // NMISNG::Util::loadConfTable;
	my $dbname;

	# inventory? then check for a known name
	if (ref($inventory))
	{
		$dbname = $inventory->find_subconcept_type_storage(subconcept => $type, type => "rrd");
	}
	# no success, then generate the name the oldfashioned way from common-database
	$dbname ||= $self->makeRRDname(type => $type,
																 index => $index,
																 item => $item,
																 relative => 1);
	if (!$dbname)
	{
		$self->nmisng->log->error("create_update_rrd cannot find or determine rrd file for type=$type, index=$index, item=$item");
		return undef;
	}
	# update the inventory if we can
	if (ref($inventory))
	{
		$inventory->set_subconcept_type_storage(subconcept => $type, type => 'rrd',
																						data => $dbname);
	}
	&NMISNG::rrdfunc::require_RRDs;
	my $result = NMISNG::rrdfunc::updateRRD( database => $C->{database_root} . $dbname,
																	 data => $data,
																	 # rest is only needed if the rrd file must be created/ds-extended
																	 sys => $self,
																	 type => $type,
																	 item => $item,
																	 index => $index,
																	 extras => $extras );

	$self->nmisng->log->error("updateRRD for $dbname failed: ".NMISNG::rrdfunc::getRRDerror) if (!$result);
	return $result;
}

# get header based on graphtype, either from the graph file itself or
# from the model/common-heading.
# args: graphtype or type, index, item
# returns: header or undef, logs if there is a problem
sub graphHeading
{
	my ( $self, %args ) = @_;

	my $graphtype = $args{graphtype} || $args{type};
	my $index     = $args{index};
	my $item      = $args{item};

	my $rawheading;

	# first, try the graph file - key heading
	my $res = NMISNG::Util::getModelFile(model => "Graph-$graphtype");
	if ($res->{success})
	{
		my $graphdata = $res->{data};
		$rawheading = $graphdata->{heading} if (ref($graphdata) eq "HASH"
																						&& defined($graphdata->{heading})
																						&& $graphdata->{heading} ne "");
	}
	else
	{
		# if that is not available, use the model section 'heading' which is sourced off common-heading
		$rawheading = $self->{mdl}->{heading}->{graphtype}->{$graphtype}
		if ( ref($self->{mdl}) eq "HASH"
				 && ref($self->{mdl}->{heading}) eq "HASH"
				 && ref($self->{mdl}->{heading}->{graphtype}) eq "HASH"
				 && defined($self->{mdl}->{heading}->{graphtype}->{$graphtype}));
	}

	# if none of those work, use a boilerplate text
	if (!$rawheading)
	{
		$self->nmisng->log->warn("heading for graphtype=$graphtype not found in graph file or model=$self->{mdl}{system}{nodeModel}");
		return "Heading not defined";
	}

	# expand any variables - iff that fails, return undef
	my $parsed = $self->parseString( string => $rawheading,
																	 index => $index,
																	 item => $item,
																	 eval => 0 );
	return $parsed;
}

# this function translates threshold information into textual level
# and related category/bucket/level information
#
# args: self, thrname, stats, index, item; pretty much all required
# note: works only for per-node mode!
#
# returns hashref with keys:
# level (=textual level),
# level_value (= numeric value)
# level_threshold (=comparison value that caused this level to be chosen),
# level_select (=default or key of the threshold level set that was chosen),
# reset (=?),
# error (n/a if things work)
sub translate_threshold_level
{
	my ($self, %args) = @_;

	my $M  = $self->mdl;

	my $thrname = $args{thrname};
	my $stats = $args{stats}; # value of items
	my $index = $args{index};
	my $item = $args{item};

	my $catchall_data = $self->inventory( concept => 'catchall' )->data_live();

	my $val;											# hash of level cutoffs to compare against
	my $level;										# text
	my $thrvalue;									# numeric value
	my $level_select;

	$self->nmisng->log->debug("Start threshold=$thrname, index=$index item=$item");

	# look for applicable level selection set in model
	return {
		error => "no threshold=$thrname entry found in Model=$catchall_data->{nodeModel}"
	}
	if (ref($M->{threshold}{name}{$thrname}) ne "HASH"
			or ref($M->{threshold}{name}{$thrname}{select}) ne "HASH"
			or !keys %{$M->{threshold}{name}{$thrname}{select}}); # at least ONE level must be there

	# which level selector works for this thing? check in order of the level_select keys
	my $T = $M->{threshold}{name}{$thrname}{select};
	$item = $args{item} // $M->{threshold}{name}{$thrname}{element};
	
	foreach my $thr (sort {$a <=> $b} keys %{$T})
	{
		next if $thr eq 'default'; # skip now the default values
		if (($self->parseString(string=>"($T->{$thr}{control})?1:0",
														index=>$index,
														item=>$item,
														sect=>$item,
														eval => 1)))
		{
			$val = $T->{$thr}{value};
			$level_select = $thr;
			$self->nmisng->log->debug("found threshold=$thrname entry=$thr");
			last;
		}
	}
	# if nothing found and there are default values available, use these
	if (!defined($val) and $T->{default}{value} ne "")
	{
		$val = $T->{default}{value};
		$level_select = "default";
		$self->nmisng->log->debug("found threshold=$thrname entry=default");
	}
	# still no luck? error out
	if (!defined($val))
	{
		$self->nmisng->log->error("$thrname in Model=$catchall_data->{nodeModel} has no select!");
		return  { error => "$thrname in Model=$catchall_data->{nodeModel} has no select!" };
	}


	my $reset = 0;
	# item is the attribute name of summary stats of Model
	my $attribname = $M->{threshold}->{name}->{$thrname}->{item};
	my $value = $stats->{$attribname}; # note: stats is separate per index, ie. flat
	$self->nmisng->log->debug("threshold=$thrname, item=$attribname, value=$value");

	# check unknown/nonnumeric value, treat it as normal
	if ($value =~ /NaN/i) {
		$self->nmisng->log->debug("illegal value $value, skipped.");
		return { level => "Normal",
						 reset => $reset,
						 level_select => $level_select,
						 level_value => $value };
	}

	### all zeros policy to disable thresholding - match and return 'normal'
	if ( $val->{warning} == 0
			and $val->{minor} == 0
			and $val->{major} == 0
			and $val->{critical} == 0
			and $val->{fatal} == 0
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal}) {
		return { level => "Normal", level_value => $value,
						 level_select => $level_select,
						 reset => $reset };
	}

	# Thresholds for higher being good and lower bad
	if ( $val->{warning} > $val->{fatal}
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal} ) {
		if ( $value <= $val->{fatal} ) { $level = "Fatal"; $thrvalue = $val->{fatal};}
		elsif ( $value <= $val->{critical} and $value > $val->{fatal} )
		{ $level = "Critical"; $thrvalue = $val->{critical};}
		elsif ( $value <= $val->{major} and $value > $val->{critical} )
		{ $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value <= $val->{minor} and $value > $val->{major} )
		{ $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value <= $val->{warning} and $value > $val->{minor} )
		{ $level = "Warning"; $thrvalue = $val->{warning}; }
		elsif ( $value > $val->{warning} )
		{ $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
	}
	# Thresholds for lower being good and higher being bad
	elsif ( $val->{warning} < $val->{fatal}
			and defined $val->{warning}
			and defined $val->{minor}
			and defined $val->{major}
			and defined $val->{critical}
			and defined $val->{fatal} ) {
		if ( $value < $val->{warning} )
		{ $level = "Normal"; $reset = $val->{warning}; $thrvalue = $val->{warning}; }
		elsif ( $value >= $val->{warning} and $value < $val->{minor} )
		{ $level = "Warning"; $thrvalue = $val->{warning}; }
		elsif ( $value >= $val->{minor} and $value < $val->{major} )
		{ $level = "Minor"; $thrvalue = $val->{minor}; }
		elsif ( $value >= $val->{major} and $value < $val->{critical} )
		{ $level = "Major"; $thrvalue = $val->{major}; }
		elsif ( $value >= $val->{critical} and $value < $val->{fatal} )
		{ $level = "Critical"; $thrvalue = $val->{critical}; }
		elsif ( $value >= $val->{fatal} )
		{ $level = "Fatal"; $thrvalue = $val->{fatal}; }
	}

	# fixme: why is level normal returned if the threshold config is broken??
	if (!defined $level)
	{
		$self->nmisng->log->error("no policy found, threshold=$thrname, value=$value, node=$self->{name}, model=$catchall_data->{nodeModel} section threshold");

		return { error => "no policy found, threshold=$thrname, value=$value, node=$self->{name}, model=$catchall_data->{nodeModel} section threshold",
						 level => "Normal",
						 level_value => $value,
						 level_select => $level_select,
						 reset => $reset };
	}
	$self->nmisng->log->debug("result threshold=$thrname, level=$level, value=$value, thrvalue=$thrvalue, reset=$reset");

	return { level => $level,
					 level_value => $value,
					 level_threshold => $thrvalue,
					 reset => $reset,
					 level_select => $level_select };
}


1;
