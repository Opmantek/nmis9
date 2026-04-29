package NMISNG::Sys::Engine::HTTP::Auth;
# Auth subsystem for Engine::HTTP. Dispatches on auth.type:
#   none         -> nothing added
#   header       -> static header(s) injected from auth.headers
#   bearer       -> Authorization: Bearer <auth.token>
#   basic        -> Authorization: Basic <base64(user:pass)>
#                   user/pass come from node config api_user/api_pass by
#                   default, override with auth.user / auth.pass
#   token_fetch  -> POST credentials to login_url, extract token via
#                   token_jsonpath, inject as inject_header on subsequent
#                   requests. Tokens are cached on disk per (node, endpoint)
#                   for ttl_seconds; 401 invalidates the cache so the next
#                   fetch re-logins.
#
# All entry points take (engine => $http_engine, endpoint => $endpoint, ...).
# The engine carries the Sys handle (for eval_string + node config + log).

use strict;
use warnings;

use MIME::Base64 qw(encode_base64);
use JSON::XS qw(encode_json decode_json);
use File::Path qw(make_path);
use Fcntl qw(:flock);

use NMISNG::JSONPath;

our $VERSION = "9.6.5";

# Apply auth to an outgoing request by mutating $headers. For token_fetch
# this may trigger a login fetch as a side effect.
# Returns: undef on success, or an error string.
sub apply_auth
{
	my (%args) = @_;
	my ($engine, $endpoint, $headers) = @args{qw(engine endpoint headers)};

	my $auth = $endpoint->{auth};
	return undef unless ref $auth eq 'HASH';

	my $type = $auth->{type} // 'none';

	if ($type eq 'none') { return undef; }

	if ($type eq 'header')
	{
		# Static headers, hashref { 'X-Foo' => 'bar', ... }
		if (ref $auth->{headers} eq 'HASH')
		{
			$headers->{$_} = $auth->{headers}{$_} for keys %{$auth->{headers}};
		}
		return undef;
	}

	if ($type eq 'bearer')
	{
		my $token = _resolve_string($engine, $endpoint, $auth->{token}, 'bearer.token');
		return "bearer auth: token is empty" unless defined $token && $token ne '';
		$headers->{Authorization} = "Bearer $token";
		return undef;
	}

	if ($type eq 'basic')
	{
		my $node_cfg = $engine->sys->{cfg}{node} // {};
		my $user = $auth->{user} // $node_cfg->{api_user};
		my $pass = $auth->{pass} // $node_cfg->{api_pass};
		return "basic auth: missing user or pass" unless defined $user && defined $pass;
		my $encoded = encode_base64("$user:$pass", '');
		$headers->{Authorization} = "Basic $encoded";
		return undef;
	}

	if ($type eq 'token_fetch')
	{
		my ($header_name, $header_value, $err) = _get_or_fetch_token($engine, $endpoint);
		return $err if $err;
		$headers->{$header_name} = $header_value;
		return undef;
	}

	return "unknown auth type '$type'";
}

# Erase cached token for an endpoint (e.g. after a 401). Returns undef.
sub invalidate_token
{
	my (%args) = @_;
	my ($engine, $endpoint) = @args{qw(engine endpoint)};
	my $path = _token_cache_path($engine, $endpoint);
	unlink $path if defined $path && -e $path;
	return undef;
}

# --- internals -------------------------------------------------------------

sub _resolve_string
{
	my ($engine, $endpoint, $value, $what) = @_;
	return $value;    # straight string for now; could later support node.X if needed
}

sub _token_cache_dir
{
	my ($engine) = @_;
	my $C = $engine->sys->nmisng->config;
	my $base = $C->{'<nmis_var>'} // '/usr/local/nmis9/var';
	return "$base/http_tokens";
}

sub _token_cache_path
{
	my ($engine, $endpoint) = @_;
	my $node_cfg = $engine->sys->{cfg}{node} // {};
	# Prefer node UUID; fall back to name. Both are stable across runs.
	my $node_id = $node_cfg->{uuid} // $node_cfg->{name} // 'unknown';
	my $ep_name = $endpoint->{name} // 'unnamed';
	# Sanitize for filenames.
	$node_id =~ s/[^A-Za-z0-9_.-]/_/g;
	$ep_name =~ s/[^A-Za-z0-9_.-]/_/g;
	return _token_cache_dir($engine) . "/${node_id}.${ep_name}.json";
}

sub _read_cached_token
{
	my ($path) = @_;
	return undef unless -r $path;
	open my $fh, '<', $path or return undef;
	flock($fh, LOCK_SH);
	local $/;
	my $content = <$fh>;
	close $fh;
	my $cached = eval { decode_json($content) };
	return undef if $@ || ref $cached ne 'HASH';
	return $cached;
}

sub _write_cached_token
{
	my ($path, $cached) = @_;
	my $dir = $path;
	$dir =~ s{/[^/]*$}{};
	-d $dir || make_path($dir, { mode => 0700 });
	open my $fh, '>', $path or return "cannot write token cache $path: $!";
	flock($fh, LOCK_EX);
	chmod 0600, $path;
	print $fh encode_json($cached);
	close $fh;
	return undef;
}

# Returns ($header_name, $header_value, $error). Reads cache or runs login.
sub _get_or_fetch_token
{
	my ($engine, $endpoint) = @_;
	my $auth = $endpoint->{auth};
	my $header_name = $auth->{inject_header}
		or return (undef, undef, "token_fetch: inject_header is required");

	my $path = _token_cache_path($engine, $endpoint);
	my $cached = _read_cached_token($path);

	my $now = time();
	if ($cached && defined $cached->{token}
	    && defined $cached->{expires_at} && $cached->{expires_at} > $now)
	{
		return ($header_name, $cached->{token}, undef);
	}

	# Run login.
	my ($token, $err) = _do_login($engine, $endpoint);
	return (undef, undef, $err) if $err;

	my $ttl = $auth->{ttl_seconds} // 300;
	my $write_err = _write_cached_token($path, {
		token      => $token,
		expires_at => $now + $ttl,
	});
	$engine->sys->nmisng->log->warn(
		"($engine->{_sys}{name}) http: $write_err"
	) if $write_err;

	return ($header_name, $token, undef);
}

sub _do_login
{
	my ($engine, $endpoint) = @_;
	my $auth = $endpoint->{auth};
	my $sys = $engine->sys;

	my $login_url = $auth->{login_url};
	return (undef, "token_fetch: login_url is required") unless defined $login_url;

	my $url = $engine->_resolve_url($endpoint, $login_url);
	my $method = uc($auth->{method} // 'POST');

	# Build body via calculate_body Perl expression (CVARs read from node config).
	my $body = '';
	if (defined $auth->{calculate_body} && $auth->{calculate_body} ne '')
	{
		my $node_cfg = $sys->{cfg}{node} // {};
		my ($eerr, $result) = $sys->eval_string(
			string    => $auth->{calculate_body},
			context   => "",
			variables => [$node_cfg],
		);
		return (undef, "token_fetch: calculate_body failed: $eerr") if $eerr;
		$body = defined $result ? $result : '';
	}
	elsif (defined $auth->{body})
	{
		$body = $auth->{body};
	}

	my %req_headers;
	$req_headers{'Content-Type'} = $auth->{content_type} if $auth->{content_type};

	my $ua = $engine->_ua;
	my $tx = $ua->build_tx($method => $url => \%req_headers => $body);
	$tx = $ua->start($tx);
	my $res = $tx->result;

	if ($res->is_error)
	{
		my $code = $res->code // 0;
		my $msg  = $res->message // 'unknown';
		return (undef, "token_fetch: login HTTP $code $msg");
	}

	my $resp_body = $res->body;
	my $decoded = eval { decode_json($resp_body) };
	if ($@)
	{
		return (undef, "token_fetch: login response is not JSON: $@");
	}

	my $jp = $auth->{token_jsonpath};
	return (undef, "token_fetch: token_jsonpath is required") unless defined $jp;

	my ($results, $err) = NMISNG::JSONPath::extract($decoded, $jp);
	return (undef, "token_fetch: token_jsonpath extract: $err") if $err;
	my $token = $results->[0];
	return (undef, "token_fetch: token_jsonpath '$jp' did not match")
		unless defined $token && $token ne '';

	return ($token, undef);
}

1;
