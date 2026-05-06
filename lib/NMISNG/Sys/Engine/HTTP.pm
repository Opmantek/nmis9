package NMISNG::Sys::Engine::HTTP;
# HTTP polling engine - fetches and parses HTTP endpoints (Prometheus
# text-exposition or JSON) declared on a node as `http_endpoints`.
#
# Section keys this engine handles:
#   http_prom => { ... }   -> Prometheus text-exposition extraction
#   http_json => { ... }   -> JSON body extraction via JSONPath
#
# Endpoints are structural deltas from node defaults (scheme, host, port);
# `host` falls back to the node's `host` attribute. No URL string templating
# is involved. See lib/NMISNG/PromText.pm and lib/NMISNG/JSONPath.pm for the
# parsers; see Engine::HTTP::Auth for the auth subsystem.

use strict;
use warnings;
use parent 'NMISNG::Sys::Engine';

use Mojo::UserAgent;
use Mojo::URL;
use JSON::XS qw(decode_json);

use NMISNG::PromText;
use NMISNG::JSONPath;
use NMISNG::Sys::Engine::HTTP::Auth;

our $VERSION = "9.6.5";

sub protocol_name { return "http"; }

# This engine handles two model-section keys (one parser each); the rest of
# the system iterates section_keys instead of just protocol_name.
sub section_keys { return [qw(http_prom http_json)]; }

sub new
{
	my ($class, %args) = @_;
	my $self = $class->SUPER::new(%args);
	$self->{endpoints}      = {};      # name => endpoint config hashref
	$self->{response_cache} = {};      # absolute_url => { samples => ..., decoded => ..., format => ... }
	$self->{ua}             = undef;   # lazy-init Mojo::UserAgent
	$self->{_last_error}    = undef;   # last discover_indexes/fetch failure (for classify_error)
	return $self;
}

# Classify the last error this engine produced (used by
# Node::collect_systemhealth_info to decide if a discover_indexes failure
# is fatal or just "this section doesn't apply on this node").
sub classify_error
{
	my ($self) = @_;
	my $err = $self->{_last_error};
	return undef unless defined $err;
	# A section pointing at an endpoint the node doesn't configure is not
	# an error in any operational sense — it's a model/node mismatch the
	# operator can decide to address. Treat it as not_present so the
	# caller logs at debug rather than escalating.
	return { type => 'not_present', message => $err }
		if $err =~ /not configured on node/i
		|| $err =~ /no endpoint declared/i;
	return { type => 'transport_error', message => $err };
}

# Called by Sys::init() to register the node's endpoint list. Each endpoint
# is a hashref { name => 'foo', scheme?, host?, port?, auth? }.
sub set_endpoints
{
	my ($self, $endpoints) = @_;
	return unless ref $endpoints eq 'ARRAY';
	for my $ep (@$endpoints)
	{
		next unless ref $ep eq 'HASH' && defined $ep->{name};
		$self->{endpoints}{$ep->{name}} = $ep;
	}
}

sub endpoint
{
	my ($self, $name) = @_;
	return $self->{endpoints}{$name};
}

sub is_active
{
	my ($self) = @_;
	return scalar(keys %{$self->{endpoints}}) > 0 ? 1 : 0;
}

# Reset the per-Sys-lifecycle scrape-response cache. Called by execute_queries
# at the start of each batch so a long-lived Sys object does not serve stale
# bodies on its second collect cycle. Tests can call this directly.
sub reset_cache
{
	my ($self) = @_;
	$self->{response_cache} = {};
}

sub _ua
{
	my ($self) = @_;
	$self->{ua} //= Mojo::UserAgent->new->request_timeout(15);
	return $self->{ua};
}

# Build the absolute base URL for an endpoint. host falls back to the node's
# configured host; port defaults from scheme.
sub _endpoint_base
{
	my ($self, $endpoint) = @_;
	my $scheme = $endpoint->{scheme} // 'http';
	my $node_host = $self->sys->{cfg}{node}{host} // $self->sys->{cfg}{node}{name};
	my $host = $endpoint->{host} // $node_host;
	my $port = $endpoint->{port} // ($scheme eq 'https' ? 443 : 80);
	return "$scheme://$host:$port";
}

# Resolve a path against an endpoint base. If the path is absolute (begins
# with http:// or https://) it overrides the endpoint base entirely.
sub _resolve_url
{
	my ($self, $endpoint, $path) = @_;
	$path //= '';
	return $path if $path =~ m{^https?://}i;
	my $base = $self->_endpoint_base($endpoint);
	$path = "/$path" unless $path =~ m{^/};
	return $base . $path;
}

# Build %todos entries for one model section, dispatched per-section-key
# (http_prom or http_json) by Sys::getValues.
#
# args: section_name, section_key, section_hash, section_indexed,
#       index, port, inventory, todos
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_key, $section_hash, $section_indexed,
	    $index, $inventory, $todos)
		= @args{qw(section_name section_key section_hash section_indexed
		           index inventory todos)};

	my $sys = $self->sys;
	my %status;

	# Resolve the endpoint for this section: per-item endpoint > -common- > error.
	my $common = ref $section_hash->{'-common-'} eq 'HASH' ? $section_hash->{'-common-'} : {};
	my $default_endpoint_name = $common->{endpoint};

	for my $itemname (keys %{$section_hash})
	{
		next if $itemname eq '-common-';
		my $thisitem = $section_hash->{$itemname};
		next unless ref $thisitem eq 'HASH';

		# Index-self pattern: an item in an indexed section that declares no
		# metric/jsonpath/calculate_url is treated as "record this row's
		# index value" — same role SNMP fills via an OID query that returns
		# the row's name (e.g. ifDescr in the interface table). The framework
		# stores the result under the item's name, so a model item called
		# 'device' produces $target->{device} = 'ens18' for the row.
		if (defined $section_indexed && defined $index
		    && !defined $thisitem->{metric}
		    && !defined $thisitem->{jsonpath}
		    && !defined $thisitem->{calculate_url})
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

		my $endpoint_name = $thisitem->{endpoint} // $default_endpoint_name;
		unless (defined $endpoint_name)
		{
			$status{error} = "($sys->{name}) http: section $section_name has no endpoint declared";
			$sys->nmisng->log->error($status{error});
			next;
		}

		my $endpoint = $self->{endpoints}{$endpoint_name};
		unless ($endpoint)
		{
			# Soft skip: models commonly declare optional sections (e.g. an
			# app_status http_json section that not every node will have an
			# endpoint configured for). Log info-level so operators see it
			# during initial setup, but don't poison the polling cycle with
			# http_error status.
			$sys->nmisng->log->info(
				"($sys->{name}) http: section $section_name skipped — endpoint '$endpoint_name' not configured on node");
			next;
		}

		# Resolve fetch path: calculate_url > path > '-common-'.calculate_url > '-common-'.path > parser default.
		my $path;
		my $calc = $thisitem->{calculate_url} // $common->{calculate_url};
		if (defined $calc && $calc ne '')
		{
			my @vars = ($inventory ? $inventory->data : {});
			my ($err, $result) = $sys->eval_string(
				string    => $calc,
				context   => "",
				variables => \@vars,
			);
			if ($err)
			{
				$status{error} = "calculate_url failed: $err";
				$sys->nmisng->log->error("($sys->{name}) http: $status{error}");
				next;
			}
			$path = $result;
		}
		else
		{
			$path = $thisitem->{path} // $common->{path}
			      // ($section_key eq 'http_prom' ? '/metrics' : undef);
		}

		unless (defined $path && $path ne '')
		{
			$status{error} = "($sys->{name}) http: section $section_name item $itemname has no path";
			$sys->nmisng->log->error($status{error});
			next;
		}

		my $url = $self->_resolve_url($endpoint, $path);

		# Per-format extraction info.
		my $extract;
		if ($section_key eq 'http_prom')
		{
			my $metric = $thisitem->{metric};
			unless (defined $metric)
			{
				$status{error} = "($sys->{name}) http_prom item $itemname missing 'metric'";
				$sys->nmisng->log->error($status{error});
				next;
			}
			# label_match: for indexed sections, the section's `indexed` label
			# is fixed to the per-row index value; per-item extra labels can
			# narrow further.
			#
			# Composite index support: when section_indexed is an arrayref
			# (e.g. ['database','collection']) the row's $index is a synthesized
			# string the engine built in discover_indexes by joining per-label
			# values with `__`. Split it back here and seed match_labels with
			# every component, so per-row extraction is implicitly scoped to
			# its (label1=val1, label2=val2, ...) tuple.
			my %label_match;
			if (defined $section_indexed && defined $index)
			{
				if (ref $section_indexed eq 'ARRAY' && @$section_indexed > 1)
				{
					my @vars = @$section_indexed;
					my @vals = split(/__/, $index, scalar @vars);
					if (@vals == @vars)
					{
						@label_match{@vars} = @vals;
					}
					else
					{
						$sys->nmisng->log->warn(
							"($sys->{name}) http: composite index '$index' has "
							. (scalar @vals) . " components but section declares "
							. (scalar @vars) . " (" . join(',', @vars) . "); "
							. "label values containing '__' break round-trip.");
					}
				}
				else
				{
					my $var = ref $section_indexed eq 'ARRAY'
						? $section_indexed->[0]
						: $section_indexed;
					$label_match{$var} = $index;
				}
			}
			if (ref $thisitem->{match_labels} eq 'HASH')
			{
				%label_match = (%label_match, %{$thisitem->{match_labels}});
			}
			$extract = { format => 'prom', metric => $metric, labels => \%label_match };
			# extract_label: instead of returning the matched sample's
			# value, return the value of one of its OTHER labels. Useful
			# for surfacing a secondary label (e.g. 'database' on a
			# collection-indexed section) into inventory so it shows in
			# System Health columns.
			$extract->{label} = $thisitem->{extract_label}
				if defined $thisitem->{extract_label};
		}
		elsif ($section_key eq 'http_json')
		{
			my $jp = $thisitem->{jsonpath};
			unless (defined $jp)
			{
				$status{error} = "($sys->{name}) http_json item $itemname missing 'jsonpath'";
				$sys->nmisng->log->error($status{error});
				next;
			}
			$extract = { format => 'json', jsonpath => $jp };
		}
		else
		{
			$status{error} = "unknown section key $section_key";
			next;
		}

		# Dedup across multiple sections sharing the same item name.
		if ($todos->{$itemname})
		{
			push @{$todos->{$itemname}{section}}, $section_name;
			push @{$todos->{$itemname}{details}}, $thisitem;
		}
		else
		{
			$todos->{$itemname} = {
				url      => $url,
				endpoint => $endpoint_name,
				extract  => $extract,
				section  => [$section_name],
				item     => $itemname,
				details  => [$thisitem],
			};
		}
	}

	return \%status;
}

# Execute pending HTTP fetches: group todos by URL, fetch once per URL,
# extract per-todo. Sets {rawvalue} and {done} on each todo.
sub execute_queries
{
	my ($self, %args) = @_;
	my ($todos) = @args{qw(todos)};

	my $sys = $self->sys;
	my %status;

	# Find todos this engine owns (have an `extract` field).
	my @mine = grep { ref $todos->{$_}{extract} eq 'HASH' } keys %$todos;
	return {} unless @mine;

	# Group by (URL, endpoint, format) so two semantically-distinct fetches
	# at the same URL string don't share a cached body. Auth lives on the
	# endpoint, and the parser depends on the format, so keying on URL
	# alone would let a Bearer-authed JSON response collide with an
	# anonymous Prometheus scrape that happens to resolve to the same URL.
	# NUL ("\0") is the join separator since none of the components can
	# contain it.
	my %by_key;
	for my $itemname (@mine)
	{
		my $t = $todos->{$itemname};
		my $key = join "\0",
			($t->{url}             // ''),
			($t->{endpoint}        // ''),
			($t->{extract}{format} // '');
		push @{$by_key{$key}}, $itemname;
	}

	for my $key (keys %by_key)
	{
		my $first_item = $by_key{$key}[0];
		my $endpoint_name = $todos->{$first_item}{endpoint};
		my $endpoint = $self->{endpoints}{$endpoint_name};
		my $url = $todos->{$first_item}{url};

		my $cached = $self->{response_cache}{$key};
		if (!$cached)
		{
			my ($body, $content_type, $err) = $self->_fetch($endpoint, $url);
			if ($err)
			{
				$status{error} = $err;
				$sys->nmisng->log->error("($sys->{name}) http: fetch $url failed: $err");
				# Mark todos failed (leave {done} false so caller knows).
				next;
			}

			# Parse body once per (URL, endpoint, format) tuple.
			my $format = $todos->{$first_item}{extract}{format};
			$cached = $self->_parse($body, $format);
			$self->{response_cache}{$key} = $cached;
		}

		for my $itemname (@{$by_key{$key}})
		{
			my $t = $todos->{$itemname};
			my $value = $self->_extract_value($cached, $t->{extract});
			if (defined $value)
			{
				$t->{rawvalue} = $value;
				$t->{done}     = 1;
			}
			else
			{
				$sys->nmisng->log->debug3("($sys->{name}) http: no value for item $itemname at $url");
			}
		}
	}

	return \%status;
}

# Discover indexes for a systemHealth section. http_prom: scrape, gather
# distinct values of the indexed label across declared metrics, cap at
# max_rows. We deliberately do NOT filter rows here — every discovered
# label tuple becomes inventory, and the canonical NMIS `control`
# expression on the section's rrd block (evaluated by Sys::getValues)
# decides which rows are actively polled. That keeps inventory
# consistent with SNMP/WMI and lets operators see the full picture
# even for rows whose data we don't currently write to RRD.
# http_json without index_function is not supported (caller should use
# index_function on the section instead).
sub discover_indexes
{
	my ($self, %args) = @_;
	my ($section_config, $index_var) = @args{qw(section_config index_var)};
	my $sys = $self->sys;

	# Pick the section key that has data. If both are present we pick http_prom
	# (the only kind supported by engine-side discovery).
	my $section_hash;
	my $section_key;
	if (ref $section_config->{http_prom} eq 'HASH')
	{
		$section_hash = $section_config->{http_prom};
		$section_key = 'http_prom';
	}
	elsif (ref $section_config->{http_json} eq 'HASH')
	{
		return ("http_json indexed sections require index_function for discovery", undef, undef);
	}
	else
	{
		return ("no http_prom/http_json subsection in indexed section", undef, undef);
	}

	# Resolve endpoint and URL. _last_error is set on these soft-fail paths
	# so classify_error can flag them as not_present (non-fatal).
	my $common = ref $section_hash->{'-common-'} eq 'HASH' ? $section_hash->{'-common-'} : {};
	my $endpoint_name = $common->{endpoint};
	if (!defined $endpoint_name)
	{
		$self->{_last_error} = "section has no endpoint declared";
		return ($self->{_last_error}, undef, undef);
	}
	my $endpoint = $self->{endpoints}{$endpoint_name};
	if (!$endpoint)
	{
		$self->{_last_error} = "endpoint '$endpoint_name' not configured on node";
		return ($self->{_last_error}, undef, undef);
	}
	$self->{_last_error} = undef;

	my $path = $common->{path} // '/metrics';
	my $url = $self->_resolve_url($endpoint, $path);

	# Fetch + parse.
	my $cached = $self->{response_cache}{$url};
	if (!$cached)
	{
		my ($body, $content_type, $err) = $self->_fetch($endpoint, $url);
		return ("fetch failed: $err", undef, undef) if $err;
		$cached = $self->_parse($body, 'prom');
		$self->{response_cache}{$url} = $cached;
	}

	# Build per-item filter tuples: (metric_name, match_labels). A candidate
	# index value is accepted only if at least one item's tuple is satisfied
	# by some sample — i.e. there's a metric we'd actually be able to
	# extract for that index. Honoring match_labels at discovery time is
	# what keeps "ghost" inventory rows from appearing for index values
	# that exist in the metric stream but don't satisfy any item's label
	# filter.
	my @item_filters;
	for my $itemname (keys %$section_hash)
	{
		next if $itemname eq '-common-';
		my $thisitem = $section_hash->{$itemname};
		my $m = $thisitem->{metric};
		next unless defined $m;
		push @item_filters, {
			metric => $m,
			labels => (ref $thisitem->{match_labels} eq 'HASH'
				? $thisitem->{match_labels} : {}),
		};
	}

	# Composite-index support: $index_var may be an arrayref of label
	# names (e.g. ['database','collection']) for sections where a single
	# label can collide across rows. The engine joins per-row label
	# values with `__` to synthesize a unique identifier; build_queries
	# splits it back to per-component match constraints during extraction.
	# Single-label string form is kept as-is for backwards compat.
	my @index_vars = ref $index_var eq 'ARRAY'
		? @$index_var
		: (defined $index_var && length $index_var ? ($index_var) : ());
	if (!@index_vars)
	{
		$self->{_last_error} = "section has no indexed label";
		return ($self->{_last_error}, undef, undef);
	}

	my %seen;
	SAMPLE: for my $sample (@{$cached->{samples} // []})
	{
		# Pull every named label value; skip the sample if any is missing.
		my @vals = map { $sample->{labels}{$_} } @index_vars;
		next if grep { !defined $_ } @vals;
		my $composite = (@index_vars > 1) ? join("__", @vals) : $vals[0];

		# A candidate is reachable if any item's (metric, match_labels)
		# tuple is satisfied by this sample. Items without match_labels
		# require only the metric name to match.
		for my $f (@item_filters)
		{
			next unless $sample->{name} eq $f->{metric};
			my $match = 1;
			for my $k (keys %{$f->{labels}})
			{
				if (!exists $sample->{labels}{$k}
					|| $sample->{labels}{$k} ne $f->{labels}{$k})
				{
					$match = 0;
					last;
				}
			}
			if ($match)
			{
				$seen{$composite}++;
				next SAMPLE;
			}
		}
	}

	my @candidates = sort keys %seen;

	# Enforce max_rows cap with a single warning rather than per-row spam.
	my $cap = $section_config->{max_rows};
	if (defined $cap && @candidates > $cap)
	{
		$sys->nmisng->log->warn(
			"($sys->{name}) http: index $index_var produced "
			. scalar(@candidates) . " rows; capping at $cap (max_rows)");
		@candidates = @candidates[0 .. $cap - 1];
	}

	my %targets = map { $_ => { index_var => $index_var, index_value => $_ } } @candidates;
	return (undef, \@candidates, \%targets);
}

# --- internals -------------------------------------------------------------

# HTTP fetch with auth. Returns (body, content_type, error).
sub _fetch
{
	my ($self, $endpoint, $url) = @_;
	my $ua = $self->_ua;

	# Build request, apply auth headers (and any required pre-fetch like token_fetch).
	my %headers;
	my $auth_err = NMISNG::Sys::Engine::HTTP::Auth::apply_auth(
		engine   => $self,
		endpoint => $endpoint,
		headers  => \%headers,
	);
	return (undef, undef, $auth_err) if $auth_err;

	my $tx = $ua->build_tx(GET => $url => \%headers);
	$tx = $ua->start($tx);
	my $res = $tx->result;

	if ($res->is_error || $res->code == 401)
	{
		# Optional one-shot retry with re-login for token_fetch endpoints.
		if ($res->code == 401 && ref $endpoint->{auth} eq 'HASH'
		    && ($endpoint->{auth}{type} // '') eq 'token_fetch'
		    && ($endpoint->{auth}{retry_on_401} // 1))
		{
			NMISNG::Sys::Engine::HTTP::Auth::invalidate_token(
				engine => $self, endpoint => $endpoint,
			);
			%headers = ();
			$auth_err = NMISNG::Sys::Engine::HTTP::Auth::apply_auth(
				engine => $self, endpoint => $endpoint, headers => \%headers,
			);
			return (undef, undef, $auth_err) if $auth_err;
			$tx = $ua->start($ua->build_tx(GET => $url => \%headers));
			$res = $tx->result;
		}

		if ($res->is_error)
		{
			my $code = $res->code // 0;
			my $msg = $res->message // 'unknown';
			return (undef, undef, "HTTP $code $msg");
		}
	}

	my $ct = $res->headers->content_type // '';
	return ($res->body, $ct, undef);
}

sub _parse
{
	my ($self, $body, $format) = @_;
	my $out = { format => $format };
	if ($format eq 'prom')
	{
		my ($samples, $errors) = NMISNG::PromText::parse_metrics($body);
		$out->{samples} = $samples;
		$out->{errors}  = $errors;
	}
	elsif ($format eq 'json')
	{
		my $decoded = eval { decode_json($body) };
		if ($@) { $out->{error} = "JSON decode failed: $@"; }
		else    { $out->{decoded} = $decoded; }
	}
	return $out;
}

sub _extract_value
{
	my ($self, $cached, $extract) = @_;

	if ($extract->{format} eq 'prom')
	{
		my $metric = $extract->{metric};
		my $labels = $extract->{labels} // {};
		for my $s (@{$cached->{samples} // []})
		{
			next if $s->{name} ne $metric;
			my $match = 1;
			for my $k (keys %$labels)
			{
				if (!exists $s->{labels}{$k} || $s->{labels}{$k} ne $labels->{$k})
				{
					$match = 0;
					last;
				}
			}
			if ($match)
			{
				# extract_label: caller wants a label's value, not the
				# sample's metric value. Returns undef if the named
				# label isn't on this sample.
				return $extract->{label}
					? $s->{labels}{$extract->{label}}
					: $s->{value};
			}
		}
		return undef;
	}
	if ($extract->{format} eq 'json')
	{
		return undef unless defined $cached->{decoded};
		my ($results, $err) = NMISNG::JSONPath::extract($cached->{decoded}, $extract->{jsonpath});
		return undef if $err;
		# Scalar paths produce a one-element array; wildcard paths produce many.
		# Engine returns the first result, like SNMP's get rather than gettable.
		# Indexed sections call build_queries per-index, so each invocation
		# already targets one row.
		return $results->[0];
	}
	return undef;
}

1;
