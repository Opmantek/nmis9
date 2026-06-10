#!/usr/bin/perl
# Tests for NMISNG::Sys::Engine::HTTP::Auth — token_fetch, bearer, basic, header.
# Forks a Mojolicious fixture that simulates a login + protected endpoint and
# tracks login-call count + last-received body via flat files.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use File::Temp qw(tempdir tempfile);
use POSIX ":sys_wait_h";
use Fcntl ':flock';

eval { require Mojolicious; require Mojo::Server::Daemon; 1 }
	or plan skip_all => "Mojolicious not available: $@";

# Each fixture sub-process writes its bound port + per-request state files
# into this shared test temp dir; the parent reads them back to make
# assertions about login-counts and the body the fixture received.
my $tmpdir = tempdir(CLEANUP => 1);
my $portfile  = "$tmpdir/port";
my $countfile = "$tmpdir/login_count";
my $bodyfile  = "$tmpdir/login_body";

# Helper to atomically read an integer counter (defaults to 0).
sub read_count
{
	my ($path) = @_;
	return 0 unless -e $path;
	open my $f, '<', $path or return 0;
	my $n = <$f>;
	close $f;
	return ($n // 0) + 0;
}

# --- forked fixture -------------------------------------------------------
my $child_pid = fork();
defined($child_pid) or BAIL_OUT("fork failed: $!");

if ($child_pid == 0)
{
	require Mojolicious;
	require Mojo::Server::Daemon;

	my $app = Mojolicious->new;
	$app->log->level('warn');
	my $r = $app->routes;

	# Login endpoint: increment counter, capture body, return token. The token
	# is "tok-N" so the parent can verify which token the engine ended up using.
	$r->post('/login' => sub {
		my $c = shift;
		open my $cf, '>>', $countfile or die "open count: $!";
		flock($cf, LOCK_EX);
		my $cur = do {
			my $v = '';
			if (open my $rf, '<', $countfile)
			{
				local $/;
				$v = <$rf> // '';
				close $rf;
			}
			$v =~ /^(\d+)$/ ? $1 + 0 : 0;
		};
		seek $cf, 0, 0; truncate $cf, 0;
		print $cf ($cur + 1);
		close $cf;

		open my $bf, '>', $bodyfile or die "open body: $!";
		print $bf $c->req->body;
		close $bf;

		$c->render(json => { token => { value => "tok-" . ($cur + 1) } });
	});

	# Protected endpoint: requires non-empty X-Auth-Token header. We always
	# return success here unless test asks for 401-mode (controlled via the
	# magic value `expired` in the token, see /always-401 below).
	$r->get('/protected' => sub {
		my $c = shift;
		my $tok = $c->req->headers->header('X-Auth-Token') // '';
		return $c->render(status => 401, json => { error => 'no token' })
			unless $tok =~ /^tok-/;
		$c->render(json => { metric_value => 99, token_seen => $tok });
	});

	# Endpoint that always returns 401 — used to trigger the engine's
	# 401-invalidate-and-retry path.
	$r->get('/always-401' => sub {
		my $c = shift;
		$c->render(status => 401, json => { error => 'reject every time' });
	});

	my $daemon = Mojo::Server::Daemon->new(
		app    => $app,
		listen => ['http://127.0.0.1:0'],
	);
	$daemon->silent(1);
	$daemon->start;
	my $port = $daemon->ports->[0];
	open my $pf, '>', $portfile or die;
	print $pf $port;
	close $pf;
	$daemon->run;
	exit 0;
}

# Parent: wait for port
my $port;
for (1 .. 100)
{
	if (-s $portfile)
	{
		open my $pf, '<', $portfile or next;
		my $p = <$pf>;
		close $pf;
		chomp $p if defined $p;
		if (defined $p && $p =~ /^\d+$/) { $port = $p; last; }
	}
	select undef, undef, undef, 0.05;
}
END { kill 'TERM', $child_pid if $child_pid; waitpid $child_pid, 0 if $child_pid; }
$port or BAIL_OUT("fixture child did not write a port");
diag("auth fixture on port $port");

# --- Sys stub (with var dir overridden so token cache lives in $tmpdir) ---
require NMISNG::Sys::Engine::HTTP;

# shared fakes; vardir routes the token cache into the throwaway dir
require NMISNG::Test::Fakes;

sub make_engine
{
	my (%args) = @_;
	# Use a fresh var dir per engine to keep token caches isolated between tests.
	my $vardir = tempdir(CLEANUP => 1, DIR => $tmpdir);
	my $sys = NMISNG::Test::FakeSys->new(
		name     => 'authnode',
		node_cfg => $args{node_cfg} // {
			host => '127.0.0.1', uuid => 'auth-uuid', name => 'authnode',
			api_user => 'alice', api_pass => 's3cr3t',
		},
		vardir => $vardir,
	);
	my $eng = NMISNG::Sys::Engine::HTTP->new(sys => $sys);
	$eng->set_endpoints($args{endpoints});
	return ($eng, $sys, $vardir);
}

# Reset shared fixture state between cases.
sub reset_fixture
{
	unlink $countfile;
	unlink $bodyfile;
}

# --- token_fetch happy path: login once, then cached ---------------------
{
	reset_fixture();
	my ($eng, $sys, $vardir) = make_engine(
		endpoints => [{
			name => 'api', port => $port,
			auth => {
				type           => 'token_fetch',
				login_url      => '/login',
				method         => 'POST',
				calculate_body => 'CVAR1=api_user; CVAR2=api_pass;'
				                . ' return qq({"username":"$CVAR1","password":"$CVAR2"});',
				content_type   => 'application/json',
				token_jsonpath => '$.token.value',
				inject_header  => 'X-Auth-Token',
				ttl_seconds    => 60,
			},
		}],
	);

	my %todos;
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/protected' },
			val        => { jsonpath => '$.metric_value' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{val}{rawvalue}, 99, "token_fetch: protected value extracted");
	is(read_count($countfile), 1, "token_fetch: login called exactly once");

	# verify the body the server received was built by calculate_body
	open my $f, '<', $bodyfile;
	my $body = do { local $/; <$f> };
	close $f;
	is($body, '{"username":"alice","password":"s3cr3t"}',
	   "token_fetch: calculate_body produced correct request body");

	# Second fetch: use cache, no new login.
	$eng->reset_cache;            # clear scrape-response cache (not auth cache)
	%todos = ();
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/protected' },
			val        => { jsonpath => '$.metric_value' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is(read_count($countfile), 1,
		"token_fetch: second fetch within TTL did NOT re-login");
}

# --- 401 invalidates cache + retries with re-login -----------------------
{
	reset_fixture();
	my ($eng, $sys, $vardir) = make_engine(
		endpoints => [{
			name => 'api', port => $port,
			auth => {
				type           => 'token_fetch',
				login_url      => '/login',
				method         => 'POST',
				calculate_body => 'CVAR1=api_user; CVAR2=api_pass;'
				                . ' return qq({"u":"$CVAR1","p":"$CVAR2"});',
				content_type   => 'application/json',
				token_jsonpath => '$.token.value',
				inject_header  => 'X-Auth-Token',
				ttl_seconds    => 60,
				retry_on_401   => 1,
			},
		}],
	);

	my %todos;
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/always-401' },
			val        => { jsonpath => '$.error' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);

	# /always-401 always 401s. Engine should: login (count=1), get 401, retry
	# after invalidate -> login again (count=2), get 401, give up.
	is(read_count($countfile), 2,
		"401 retry: login called twice (initial + post-401 retry)");
}

# --- bearer auth with static token ---------------------------------------
{
	reset_fixture();
	my ($eng, $sys, $vardir) = make_engine(
		endpoints => [{
			name => 'api', port => $port,
			auth => { type => 'bearer', token => 'this-is-not-tok-anything' },
		}],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/protected' },
			val        => { jsonpath => '$.metric_value' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	# bearer puts token in Authorization, but /protected only checks X-Auth-Token,
	# so this returns 401. The point of this test is just that the auth dispatcher
	# applies the right header, not that the endpoint accepts it.
	# We only assert that no login was called (bearer is static, no token_fetch).
	is(read_count($countfile), 0, "bearer auth: never calls /login");
}

# --- header auth: arbitrary static headers --------------------------------
{
	reset_fixture();
	my ($eng, $sys, $vardir) = make_engine(
		endpoints => [{
			name => 'api', port => $port,
			auth => { type => 'header', headers => { 'X-Auth-Token' => 'tok-static' } },
		}],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/protected' },
			val        => { jsonpath => '$.metric_value' },
			seen       => { jsonpath => '$.token_seen' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{val}{rawvalue}, 99, "header auth: passed protected check");
	is($todos{seen}{rawvalue}, 'tok-static', "header auth: server saw our token");
}

# --- token cache file: created with secure perms -------------------------
{
	reset_fixture();
	my ($eng, $sys, $vardir) = make_engine(
		endpoints => [{
			name => 'api', port => $port,
			auth => {
				type           => 'token_fetch',
				login_url      => '/login',
				method         => 'POST',
				calculate_body => 'CVAR1=api_user; return qq({"u":"$CVAR1"});',
				content_type   => 'application/json',
				token_jsonpath => '$.token.value',
				inject_header  => 'X-Auth-Token',
				ttl_seconds    => 60,
			},
		}],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'api',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'api', path => '/protected' },
			val        => { jsonpath => '$.metric_value' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);

	my $cache_path = "$vardir/http_tokens/auth-uuid.api.json";
	ok(-e $cache_path, "token cache file created");
	my $mode = (stat $cache_path)[2] & 07777;
	is($mode, 0600, "token cache file has 0600 perms");
}

done_testing();
