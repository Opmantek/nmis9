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

# Replaced with real event raise/clear in Task 5.
sub _raise_stale_event { return; }
sub _clear_stale_event { return; }

1;
