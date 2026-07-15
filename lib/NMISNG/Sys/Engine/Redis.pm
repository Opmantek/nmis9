package NMISNG::Sys::Engine::Redis;
# Redis polling engine — consumes data pushed into Redis by the nmisent Go
# daemon. Reads one JSON payload per (node, concept) at the contract key
#   nmisent:metrics:{node_uuid}:{concept}
# and presents the named fields to the shared %todos contract. Owns its
# inventory lifecycle (manages_own_inventory=1), so Node::collect runs the
# systemHealth reconcile for it. Sessionless: the connection is process-level,
# not per-collect, so the base-class has_session/open_session/close_session
# no-op defaults are correct.
#
# See docs/superpowers/specs/2026-06-05-nmis9-redis-polling-design.md and the
# shared contract for key shapes and payload semantics.

use strict;
use warnings;
use parent 'NMISNG::Sys::Engine';

use Redis;
use JSON::XS qw(decode_json);
use NMISNG::Util;

our $VERSION = "9.6.5";

sub protocol_name         { return "redis"; }
sub section_keys          { return ['redis']; }
sub manages_own_inventory { return 1; }
# Push engine: a successful fetch from redis does NOT prove the device is
# reachable (the payload can report OFFLINE). Reachability comes from the
# device status, mapped onto "Node Down" by apply_redis_reachability. See
# NMISNG::Sys::Engine::collection_probes_reachability.
sub collection_probes_reachability { return 0; }

sub new
{
	my ($class, %args) = @_;
	my $self = $class->SUPER::new(%args);
	# Decoded payloads cached per Sys lifecycle, concept => payload-or-undef.
	# undef is a real cached value meaning "key absent this cycle".
	$self->{_payload_cache}  = {};
	$self->{_last_error}     = undef;
	# Expected run_id, set by Sys::init from the completion entry on the prompt
	# path. undef on the fallback path (read whatever is present).
	$self->{expected_run_id} = $args{run_id};
	return $self;
}

# The engine is only instantiated when redis_enabled, so its presence means
# the node is push-polled. No per-node endpoint config to check (unlike HTTP).
sub is_active { return 1; }

# Open the Redis connection, lazily, reused for the engine's lifetime.
# Endpoint resolution (env > Config.nmis > localhost:6379) is shared with
# the scheduler via NMISNG::Util::redis_connect_args.
sub _redis
{
	my ($self) = @_;
	return $self->{_redis} if $self->{_redis};

	my ($newargs, $display) = NMISNG::Util::redis_connect_args($self->sys->nmisng->config);
	$self->{_redis} = eval { Redis->new(%$newargs) };
	if (!$self->{_redis})
	{
		$self->{_last_error} = "redis connect to $display failed: $@";
		$self->sys->nmisng->log->error("redis: ".$self->{_last_error});
	}
	return $self->{_redis};
}

# Fetch and decode the JSON payload for a concept, cached per Sys lifecycle.
# Returns ($payload_hashref_or_undef, $error_or_undef). The three outcomes:
#   (hashref, undef) — key present and valid.
#   (undef,   undef) — key ABSENT. Per contract, "no information this cycle";
#                      the caller must NOT touch existing inventory.
#   (undef,   error) — connection or decode failure.
sub _payload
{
	my ($self, $concept) = @_;
	return ($self->{_payload_cache}{$concept}, undef)
		if exists $self->{_payload_cache}{$concept};

	my $redis = $self->_redis;
	return (undef, $self->{_last_error}) if (!$redis);

	my $uuid = $self->sys->{uuid};
	my $key  = "nmisent:metrics:$uuid:$concept";
	my $raw  = eval { $redis->get($key) };
	if ($@)
	{
		$self->{_last_error} = "redis get $key failed: $@";
		return (undef, $self->{_last_error});
	}

	# Absent key: cache undef so repeated lookups this cycle are cheap.
	if (!defined $raw)
	{
		$self->{_payload_cache}{$concept} = undef;
		return (undef, undef);
	}

	my $payload = eval { decode_json($raw) };
	if ($@ || ref $payload ne 'HASH')
	{
		$self->{_last_error} = "redis payload for $key is not a valid JSON object";
		return (undef, $self->{_last_error});
	}
	$self->{_payload_cache}{$concept} = $payload;
	return ($payload, undef);
}

# Classify the last error for Node::collect_systemhealth_info's gate.
#   connect failure   -> no_session    (lifecycle calls handle_down, aborts)
#   missing key       -> not_present   (soft skip, inventory untouched)
#   anything else     -> transport_error
sub classify_error
{
	my ($self) = @_;
	my $err = $self->{_last_error};
	return undef unless defined $err;
	# anchored to _redis's actual failure message — a bare /connect/ would
	# also match concept names (e.g. 'vpn_connections') embedded in
	# missing-key errors and abort the whole systemHealth collect
	return { type => 'no_session',  message => $err } if $err =~ /redis connect to/i;
	return { type => 'not_present', message => $err } if $err =~ /no key|missing key|run_id mismatch|not usable/i;
	return { type => 'transport_error', message => $err };
}

# Decide whether a payload should be consumed this cycle.
# Returns 1 to consume, 0 to skip. Skips on run_id mismatch (prompt path only)
# and when the payload is older than freshness_s, raising/clearing the
# per-concept staleness event (see Task 5).
sub _payload_usable
{
	my ($self, $concept, $payload, $freshness_s) = @_;
	my $meta = (ref $payload->{_meta} eq 'HASH') ? $payload->{_meta} : {};

	if (defined $self->{expected_run_id}
		&& defined $meta->{run_id}
		&& $meta->{run_id} ne $self->{expected_run_id})
	{
		$self->sys->nmisng->log->debug(
			"redis: concept $concept run_id '$meta->{run_id}' != expected '$self->{expected_run_id}', skipping");
		$self->{_concept_fresh}{$concept} = 0;
		return 0;
	}

	my $collected = $meta->{collected_at_epoch};
	if (defined $freshness_s && defined $collected)
	{
		my $age = time() - $collected;
		if ($age > $freshness_s)
		{
			$self->_raise_stale_event($concept, $age, $freshness_s);
			$self->{_concept_fresh}{$concept} = 0;
			return 0;
		}
	}
	$self->_clear_stale_event($concept);
	$self->{_concept_fresh}{$concept} = 1;
	return 1;
}

# Per-concept freshness verdict recorded by _payload_usable.
# returns: 1 fresh, 0 stale-or-skipped, undef if the concept was not evaluated
# this cycle (e.g. the key was absent so the gate never ran).
sub concept_fresh { return $_[0]->{_concept_fresh}{ $_[1] }; }

# Per-concept staleness event, keyed by node + concept (element). Uses the
# standard NMIS event path (Compat::NMIS::notify / checkEvent) rather than the
# raw event system, matching how the rest of NMIS creates and clears events.
# notify/checkEvent take the LIVE sys and resolve the node themselves. Distinct
# from the node-level handle_down source-down path: one stale concept does not
# mark the whole node's Redis source down. Compat::NMIS is required lazily to
# avoid a load-order cycle with the engine.
my $STALE_EVENT = "Redis Data Stale";

sub _raise_stale_event
{
	my ($self, $concept, $age, $freshness_s) = @_;
	# Once per concept per engine lifetime (one collect): the gate runs per
	# index, and notify costs a MongoDB lookup per call. The payload (and
	# so the verdict) cannot change within one cycle — _payload_cache.
	return if $self->{_stale_raised}{$concept}++;
	require Compat::NMIS;
	Compat::NMIS::notify(
		sys     => $self->sys,
		event   => $STALE_EVENT,
		element => $concept,
		level   => "Warning",
		details => "Redis concept $concept is stale: ".int($age)."s old, freshness threshold ${freshness_s}s",
	);
}

sub _clear_stale_event
{
	my ($self, $concept) = @_;
	# Same once-per-cycle guard as _raise_stale_event, same reasoning.
	return if $self->{_stale_cleared}{$concept}++;
	require Compat::NMIS;
	# checkEvent closes the event if one is open for this (node, concept),
	# and is a no-op when none exists — safe to call every fresh cycle.
	Compat::NMIS::checkEvent(
		sys     => $self->sys,
		event   => $STALE_EVENT,
		element => $concept,
		level   => "Normal",
		details => "Redis concept $concept is fresh",
	);
}

# Close open stale events whose concept the model no longer declares.
# Without this, removing a concept from the model (or switching models)
# leaves its 'Redis Data Stale' event open forever: nothing queries the
# concept anymore, so the normal clear in _payload_usable never runs.
# Called once per collect from the own-inventory pass in Node::collect.
sub close_orphaned_stale_events
{
	my ($self) = @_;
	my $node = $self->sys->nmisng_node;
	return if (!ref $node);

	my %live = map { $_ => 1 } @{ $self->model_concepts };
	my $open = $node->get_events_model(
		filter => { event => $STALE_EVENT, historic => 0 } );
	return if (!$open or $open->error or !$open->count);

	for my $ev (@{$open->data})
	{
		my $element = $ev->{element};
		next if (!defined $element or $element eq '' or $live{$element});
		$self->_clear_stale_event($element);
	}
	return;
}

# All concepts this model sources from this engine's section blocks
# (system and systemHealth alike, sys and rrd parts).
sub model_concepts
{
	my ($self) = @_;
	my $mdl = $self->sys->mdl;
	my %concepts;
	return [] if (ref $mdl ne 'HASH');
	for my $class (values %$mdl)
	{
		next if (ref $class ne 'HASH');
		for my $kind (qw(sys rrd))
		{
			my $sections = $class->{$kind};
			next if (ref $sections ne 'HASH');
			for my $section (values %$sections)
			{
				next if (ref $section ne 'HASH');
				for my $sk (@{$self->section_keys})
				{
					my $block = $section->{$sk};
					next if (ref $block ne 'HASH');
					my $common = $block->{'-common-'};
					$concepts{$common->{concept}} = 1
						if (ref $common eq 'HASH' && defined $common->{concept});
				}
			}
		}
	}
	return [keys %concepts];
}

# Build %todos entries for one model section. Joins the model's `field` names
# against the payload `data` block. Because the payload is already in Redis,
# extraction happens here and todos are marked done; execute_queries is a
# no-op. Args match the engine contract (see Sys::getValues dispatch).
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_hash, $section_indexed, $index, $inventory, $todos)
		= @args{qw(section_name section_hash section_indexed index inventory todos)};

	my $sys = $self->sys;
	my %status;

	my $common = (ref $section_hash->{'-common-'} eq 'HASH') ? $section_hash->{'-common-'} : {};
	my $concept = $common->{concept};
	unless (defined $concept)
	{
		$status{error} = "($sys->{name}) redis: section $section_name has no concept in -common-";
		$sys->nmisng->log->error($status{error});
		return \%status;
	}

	my ($payload, $err) = $self->_payload($concept);
	if ($err)
	{
		$status{error} = $err;
		return \%status;
	}
	# Absent key: nothing to record this cycle. Leave todos untouched —
	# but close any open staleness alarm for the concept: absence is a
	# normal state (optional concept, reset store), and without this a
	# previously raised stale event would stay open until the key returned.
	if (!defined $payload)
	{
		$self->_clear_stale_event($concept);
		return \%status;
	}

	# run_id / freshness gate (freshness declared per-section in -common-).
	return \%status unless $self->_payload_usable($concept, $payload, $common->{freshness});

	# Resolve the data row: an indexed concept's data is an array; pick the
	# row whose index field(s) match $index. A scalar concept's data is the
	# object itself. Row maps are built once per concept per cycle, then
	# O(1) per index: getValues calls build_queries once per inventory row,
	# and the payload is fixed for the engine's lifetime (_payload_cache) —
	# a linear scan here made large sections O(rows^2) per collect.
	my $row;
	if (defined $section_indexed && defined $index)
	{
		my $data = $payload->{data};
		my @vars = (ref $section_indexed eq 'ARRAY') ? @$section_indexed : ($section_indexed);
		if (ref $data eq 'ARRAY' && @vars == 1)
		{
			my $index_field = $vars[0];
			my $rowmap = $self->{_row_index_cache}{$concept}{$index_field} //= do {
				my %m;
				for my $entry (@$data)
				{
					next if (ref $entry ne 'HASH' || !defined $entry->{$index_field});
					$m{$entry->{$index_field}} //= $entry;    # first match wins, as before
				}
				\%m;
			};
			$row = $rowmap->{$index};
		}
		elsif (ref $data eq 'ARRAY' && @vars > 1)
		{
			# Composite-indexed row: $index is the '__'-joined string the
			# engine synthesized in discover_indexes. Resolve the per-
			# component values losslessly (inventory row first, like
			# Engine::HTTP), then look the row up in a tuple-keyed map.
			# \x00 as the internal tuple separator cannot collide with
			# component values that contain '__' themselves.
			my @vals = $self->_composite_components($index, \@vars, $inventory);
			if (@vals == @vars)
			{
				my $sep = "\x00";
				my $rowmap = $self->{_row_tuple_cache}{$concept}{join($sep, @vars)} //= do {
					my %m;
					for my $entry (@$data)
					{
						next if (ref $entry ne 'HASH');
						my @evals = map { $entry->{$_} } @vars;
						next if (grep { !defined $_ } @evals);
						$m{join($sep, @evals)} //= $entry;    # first match wins
					}
					\%m;
				};
				$row = $rowmap->{join($sep, @vals)};
			}
		}
		# No matching row this cycle: nothing to record (the index will be
		# retired by the historic-mark pass in collect_systemhealth_info).
		return \%status if (ref $row ne 'HASH');
	}
	else
	{
		$row = (ref $payload->{data} eq 'HASH') ? $payload->{data} : {};
	}

	for my $itemname (keys %$section_hash)
	{
		next if $itemname eq '-common-';
		my $thisitem = $section_hash->{$itemname};
		next unless ref $thisitem eq 'HASH';

		# Index-self item: an indexed-section item that declares no `field`
		# records the row's own index value (same role ifDescr fills for SNMP).
		if (defined $section_indexed && defined $index && !defined $thisitem->{field})
		{
			$todos->{$itemname} = {
				section  => [$section_name],
				item     => $itemname,
				details  => [$thisitem],
				rawvalue => $index,
				done     => 1,
			};
			next;
		}

		my $field = $thisitem->{field};
		unless (defined $field)
		{
			$status{error} = "($sys->{name}) redis: section $section_name item $itemname has no field";
			$sys->nmisng->log->error($status{error});
			next;
		}

		# Contract: the daemon emits every declared field, using null for
		# unavailable values. A missing field name is writer schema drift —
		# log it but don't fail the collect.
		if (!exists $row->{$field})
		{
			$sys->nmisng->log->debug(
				"($sys->{name}) redis: concept $concept field '$field' (item $itemname) absent from payload row");
		}

		$todos->{$itemname} = {
			section  => [$section_name],
			item     => $itemname,
			details  => [$thisitem],
			rawvalue => $row->{$field},   # may be undef (null in the payload)
			done     => 1,
		};
	}

	return \%status;
}

# Decompose a synthesized composite index back into its per-component
# values, mirroring Engine::HTTP's three-tier resolution:
#   1. the inventory row — discover_indexes persisted each component as its
#      own data field, lossless across Sys lifetimes (collect-only cycles,
#      component values containing '__');
#   2. the in-memory map discover_indexes populated within this Sys
#      lifetime (the reconcile pass calls loadInfo before the inventory
#      object exists);
#   3. split on '__' — ambiguous when a component contains the separator,
#      so only a last resort; warns when the count comes out wrong.
# args: composite index string, arrayref of component names, optional inventory.
# returns: list of component values, or the empty list when unresolvable.
sub _composite_components
{
	my ($self, $index, $vars, $inventory) = @_;

	if ($inventory)
	{
		my $data = $inventory->data;
		my @from_inv = map { $data->{$_} } @$vars;
		return @from_inv if (@from_inv == @$vars && !grep { !defined $_ } @from_inv);
	}

	my $components = $self->{_index_components}{$index};
	return @$components if (ref $components eq 'ARRAY' && @$components == @$vars);

	my @vals = split(/__/, $index, scalar @$vars);
	return @vals if (@vals == @$vars);

	$self->sys->nmisng->log->warn(
		"(".$self->sys->{name}.") redis: composite index '$index' could not be "
		. "decomposed into ".(scalar @$vars)." components (".join(',', @$vars)."); "
		. "inventory had no matching fields, no component map, and split gave "
		. (scalar @vals) . ".");
	return ();
}

# Redis extraction happens in build_queries (the data is already local), so
# there is nothing to execute. Kept for engine-contract symmetry.
sub execute_queries
{
	my ($self, %args) = @_;
	return {};
}

# Discover active indexes for an indexed systemHealth concept. Encodes the
# contract's empty-data semantics:
#   absent key            -> ($error, undef, undef); classify_error => not_present
#                            => Node::collect_systemhealth_info soft-skips,
#                               existing inventory is untouched.
#   "data": []            -> (undef, [], {})
#                            => bulk_update_inventory_historic marks all rows
#                               for the concept historic.
#   "data": [rows]        -> (undef, \@indices, \%targets)
# index_var may be a string (single index) or arrayref (composite, joined "__").
sub discover_indexes
{
	my ($self, %args) = @_;
	my ($section_config, $index_var) = @args{qw(section_config index_var)};
	my $sys = $self->sys;

	my $section_hash = (ref $section_config->{redis} eq 'HASH') ? $section_config->{redis} : undef;
	if (!$section_hash)
	{
		$self->{_last_error} = "section has no redis subsection";
		return ($self->{_last_error}, undef, undef);
	}
	my $common = (ref $section_hash->{'-common-'} eq 'HASH') ? $section_hash->{'-common-'} : {};
	my $concept = $common->{concept};
	if (!defined $concept)
	{
		$self->{_last_error} = "redis section has no concept";
		return ($self->{_last_error}, undef, undef);
	}

	my ($payload, $err) = $self->_payload($concept);
	return ("redis discover for $concept failed: $err", undef, undef) if $err;

	# Absent key: no information this cycle. not_present -> soft skip.
	if (!defined $payload)
	{
		$self->{_last_error} = "no key for concept $concept";
		return ($self->{_last_error}, undef, undef);
	}

	# Same gate as the data path (run_id mismatch on the prompt path, and
	# freshness): skip discovery this cycle rather than creating/retiring
	# inventory against a half-written newer snapshot or a payload the data
	# path refuses as stale. A stale payload raises the per-concept stale
	# event here too (once per cycle, the raise is guarded), since a
	# soft-skipped section never reaches the data path's gate.
	if (!$self->_payload_usable($concept, $payload, $common->{freshness}))
	{
		$self->{_last_error} = "payload for concept $concept not usable (stale or run_id mismatch)";
		return ($self->{_last_error}, undef, undef);
	}
	$self->{_last_error} = undef;

	my $data = $payload->{data};
	# Present but empty array: affirmative "all indices gone".
	return (undef, [], {}) if (ref $data eq 'ARRAY' && @$data == 0);
	if (ref $data ne 'ARRAY')
	{
		$self->{_last_error} = "concept $concept payload data is not an array (not indexed?)";
		return ($self->{_last_error}, undef, undef);
	}

	my @index_vars = (ref $index_var eq 'ARRAY')
		? @$index_var
		: (defined $index_var && length $index_var ? ($index_var) : ());
	if (!@index_vars)
	{
		$self->{_last_error} = "concept $concept has no index var";
		return ($self->{_last_error}, undef, undef);
	}

	my @candidates;
	my %targets;
	my %seen;
	for my $entry (@$data)
	{
		next if (ref $entry ne 'HASH');
		my @vals = map { $entry->{$_} } @index_vars;
		next if (grep { !defined $_ } @vals);
		my $composite = (@index_vars > 1) ? join("__", @vals) : $vals[0];
		# first row wins on a composite collision ('a__b'+'c' and 'a'+'b__c'
		# both serialize to 'a__b__c') — same dedup as Engine::HTTP; the
		# inventory path is keyed by the composite string, so only one row
		# can exist for it.
		next if ($seen{$composite}++);
		push @candidates, $composite;
		# Stash per-row component values keyed by the synthesized identifier.
		# build_queries reads this (or the same values persisted on the
		# inventory row) instead of re-splitting $composite, which
		# round-trips correctly even when a component contains '__'.
		$self->{_index_components}{$composite} //= [@vals] if (@index_vars > 1);
		my %target = (index_var => $index_var, index_value => $composite);
		if (@index_vars > 1)
		{
			$target{$index_vars[$_]} = $vals[$_] for 0 .. $#index_vars;
		}
		$targets{$composite} = \%target;
	}

	return (undef, \@candidates, \%targets);
}

1;
