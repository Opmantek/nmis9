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

our $VERSION = "9.6.5";

sub protocol_name         { return "redis"; }
sub section_keys          { return ['redis']; }
sub manages_own_inventory { return 1; }

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

# Resolve the shared Redis connection. Env first (the deploy exports these),
# then an optional Config.nmis override block, then localhost:6379. One
# process-level connection, opened lazily, reused for the engine's lifetime.
sub _redis
{
	my ($self) = @_;
	return $self->{_redis} if $self->{_redis};

	my $cfg = $self->sys->nmisng->config;
	my $server = $ENV{NMIS_REDIS_SERVER} // $cfg->{redis_server} // 'localhost';
	my $port   = $ENV{NMIS_REDIS_PORT}   // $cfg->{redis_port}   // 6379;
	my $pass   = $ENV{NMIS_REDIS_PASSWORD};
	$pass = $cfg->{redis_password} if (!defined $pass || $pass eq '');

	my %newargs = (server => "$server:$port", reconnect => 2, every => 100, cnx_timeout => 5);
	$newargs{password} = $pass if (defined $pass && $pass ne '');

	$self->{_redis} = eval { Redis->new(%newargs) };
	if (!$self->{_redis})
	{
		$self->{_last_error} = "redis connect to $server:$port failed: $@";
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
	return { type => 'no_session',  message => $err } if $err =~ /connect/i;
	return { type => 'not_present', message => $err } if $err =~ /no key|missing key|run_id mismatch/i;
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
		return 0;
	}

	my $collected = $meta->{collected_at_epoch};
	if (defined $freshness_s && defined $collected)
	{
		my $age = time() - $collected;
		if ($age > $freshness_s)
		{
			$self->_raise_stale_event($concept, $age, $freshness_s);
			return 0;
		}
	}
	$self->_clear_stale_event($concept);
	return 1;
}

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

# Build %todos entries for one model section. Joins the model's `field` names
# against the payload `data` block. Because the payload is already in Redis,
# extraction happens here and todos are marked done; execute_queries is a
# no-op. Args match the engine contract (see Sys::getValues dispatch).
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_hash, $section_indexed, $index, $todos)
		= @args{qw(section_name section_hash section_indexed index todos)};

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
	# Absent key: nothing to record this cycle. Leave todos untouched.
	return \%status if (!defined $payload);

	# run_id / freshness gate (freshness declared per-section in -common-).
	return \%status unless $self->_payload_usable($concept, $payload, $common->{freshness});

	# Resolve the data row: an indexed concept's data is an array; pick the
	# row whose index field equals $index. A scalar concept's data is the
	# object itself.
	my $row;
	if (defined $section_indexed && defined $index)
	{
		my $index_field = (ref $section_indexed eq 'ARRAY') ? undef : $section_indexed;
		my $data = $payload->{data};
		if (ref $data eq 'ARRAY' && defined $index_field)
		{
			for my $entry (@$data)
			{
				next unless ref $entry eq 'HASH';
				if (defined $entry->{$index_field} && $entry->{$index_field} eq $index)
				{
					$row = $entry;
					last;
				}
			}
		}
		# No matching row this cycle: nothing to record (the index will be
		# retired by the historic-mark pass in collect_systemhealth_info).
		return \%status unless ref $row eq 'HASH';
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

	# run_id mismatch on the prompt path: skip discovery this cycle rather
	# than retiring inventory against a half-written newer snapshot.
	my $meta = (ref $payload->{_meta} eq 'HASH') ? $payload->{_meta} : {};
	if (defined $self->{expected_run_id}
		&& defined $meta->{run_id}
		&& $meta->{run_id} ne $self->{expected_run_id})
	{
		$self->{_last_error} = "run_id mismatch for concept $concept";
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
	for my $entry (@$data)
	{
		next unless ref $entry eq 'HASH';
		my @vals = map { $entry->{$_} } @index_vars;
		next if grep { !defined $_ } @vals;
		my $composite = (@index_vars > 1) ? join("__", @vals) : $vals[0];
		push @candidates, $composite;
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
