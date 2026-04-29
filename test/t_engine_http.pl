#!/usr/bin/perl
# Tests for NMISNG::Sys::Engine::HTTP using a forked Mojolicious fixture.
# The fixture runs in a child process; tests run in the parent so that
# Mojo::UserAgent's IOLoop is not contending with the server's IOLoop
# (sharing one IOLoop deadlocks under some Mojolicious versions).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempfile);
use POSIX ":sys_wait_h";

eval { require Mojolicious; require Mojo::Server::Daemon; 1 }
	or plan skip_all => "Mojolicious not available: $@";

# --- fixture: spawn a child process running the server -------------------
my ($fh, $portfile) = tempfile(UNLINK => 1);
close $fh;

my $child_pid = fork();
defined($child_pid) or BAIL_OUT("fork failed: $!");

if ($child_pid == 0)
{
	# Child: build a Mojolicious app programmatically (no Lite import sugar
	# so this works cleanly under fork), bind, write port, run loop.
	require Mojolicious;
	require Mojo::Server::Daemon;

	my $app = Mojolicious->new;
	$app->log->level('warn');
	my $r = $app->routes;

	$r->get('/metrics' => sub {
		my $c = shift;
		$c->res->headers->content_type('text/plain; version=0.0.4');
		$c->render(text => <<'EOM');
# HELP node_load1 1m load average
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_memory_MemFree_bytes Free memory in bytes
# TYPE node_memory_MemFree_bytes gauge
node_memory_MemFree_bytes 1.234e9
# HELP app_queue_depth queue depth
# TYPE app_queue_depth gauge
app_queue_depth{queue="orders"} 3
app_queue_depth{queue="payments"} 1
app_queue_depth{queue="email"} 7
app_queue_depth{queue="ignore_me"} 99
EOM
	});

	$r->get('/status' => sub {
		my $c = shift;
		$c->render(json => { app => { uptime_seconds => 3600, state => 'running' } });
	});

	$r->get('/pool/:id/stats' => sub {
		my $c = shift;
		my $id = $c->stash('id');
		$c->render(json => { pool => $id, members => [
			{ name => "$id-a", value => 100 },
			{ name => "$id-b", value => 200 },
		]});
	});

	$r->get('/big_metrics' => sub {
		my $c = shift;
		$c->res->headers->content_type('text/plain; version=0.0.4');
		my @lines = ('# TYPE big_metric gauge');
		for my $i (1 .. 500)
		{
			push @lines, qq{big_metric{label_x="value_$i"} $i};
		}
		$c->render(text => join("\n", @lines) . "\n");
	});

	my $daemon = Mojo::Server::Daemon->new(
		app    => $app,
		listen => ['http://127.0.0.1:0'],
	);
	$daemon->silent(1);
	$daemon->start;
	my $port = $daemon->ports->[0];
	open my $pf, '>', $portfile or die "cannot write portfile: $!";
	print $pf $port;
	close $pf;
	$daemon->run;
	exit 0;
}

# Parent: wait for child to write the port
my $port;
for (1 .. 100)
{
	if (-s $portfile)
	{
		open my $pf, '<', $portfile or next;
		my $p = <$pf>;
		close $pf;
		chomp $p if defined $p;
		if (defined $p && $p =~ /^\d+$/)
		{
			$port = $p;
			last;
		}
	}
	select undef, undef, undef, 0.05;
}
END { kill 'TERM', $child_pid if $child_pid; waitpid $child_pid, 0 if $child_pid; }
$port or BAIL_OUT("fixture child did not write a port");
diag("fixture listening on port $port");

# --- now load the engine + the fake Sys (after fork to keep child slim) --
require NMISNG::Sys::Engine::HTTP;
NMISNG::Sys::Engine::HTTP->import;

package FakeLog;
sub new { return bless {}, shift; }
sub error { shift; my $m = shift; print STDERR "ERROR: $m\n" if $ENV{DEBUG}; }
sub warn  { shift; my $m = shift; print STDERR "WARN: $m\n"  if $ENV{DEBUG}; }
sub info  { shift; }
sub debug  { shift; } sub debug2 { shift; }
sub debug3 { shift; } sub debug4 { shift; }

package FakeNmisng;
sub new { return bless { config => {} }, shift; }
sub log { $_[0]{log} //= FakeLog->new(); return $_[0]{log}; }
sub config { return $_[0]{config}; }

package FakeSys;
sub new
{
	my ($class, %a) = @_;
	return bless {
		name   => $a{name} // 'testnode',
		cfg    => { node => $a{node_cfg} // {
			host => '127.0.0.1', uuid => 'test-uuid', name => 'testnode',
		}},
		nmisng => FakeNmisng->new(),
	}, $class;
}
sub nmisng { return $_[0]{nmisng}; }
sub eval_string
{
	my ($self, %args) = @_;
	my $input = $args{string};
	my $vars  = $args{variables} // [];
	my %cvar;
	my $consume = $input;
	my $rebuilt = '';
	while ($consume =~ s/^(.*?)(CVAR(\d)?=(\w+);|\$CVAR(\d)?)//)
	{
		$rebuilt .= $1;
		my ($n, $decl, $use) = ($3, $4, $5);
		$n = 0 unless defined $n;
		if (defined $decl)
		{
			for my $src (@$vars)
			{
				next unless ref $src eq 'HASH' && exists $src->{$decl};
				$cvar{$n} = $src->{$decl};
				last;
			}
			return ("CVAR$n: unknown name '$decl'") unless exists $cvar{$n};
		}
		else
		{
			return ("CVAR$use undefined") unless exists $cvar{$use};
			$rebuilt .= $cvar{$use};
		}
	}
	$rebuilt .= $consume;
	my $r = $args{context};
	$r = eval $rebuilt;
	return ("eval failed: $@") if $@;
	return (undef, $r);
}

package FakeInventory;
sub new { my ($c, $d) = @_; return bless { data => $d }, $c; }
sub data { return $_[0]{data}; }

package main;

# Helper: make engine + fake sys; caller must keep both alive (engine weak-refs sys).
sub make_engine
{
	my (%args) = @_;
	my $sys = FakeSys->new(node_cfg => $args{node_cfg});
	my $eng = NMISNG::Sys::Engine::HTTP->new(sys => $sys);
	$eng->set_endpoints($args{endpoints});
	return ($eng, $sys);
}

# --- scalar Prometheus extraction ----------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $sec = {
		'-common-' => { endpoint => 'fix' },
		load1      => { metric => 'node_load1' },
		memfree    => { metric => 'node_memory_MemFree_bytes' },
	};
	my $bs = $eng->build_queries(
		section_name => 'cpu',
		section_key  => 'http_prom',
		section_hash => $sec,
		todos        => \%todos,
	);
	is($bs->{error}, undef, "scalar prom: build no error");
	$eng->execute_queries(todos => \%todos);
	is($todos{load1}{rawvalue},   0.42,    "load1 value");
	is($todos{load1}{done},       1,       "load1 done");
	is($todos{memfree}{rawvalue}, 1.234e9, "memfree value");
}

# --- scalar JSON extraction -----------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'app',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'fix', path => '/status' },
			uptime     => { jsonpath => '$.app.uptime_seconds' },
			state      => { jsonpath => '$.app.state' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	is($todos{uptime}{rawvalue}, 3600,      "json: uptime");
	is($todos{state}{rawvalue},  'running', "json: state string");
}

# --- discover_indexes for label-as-index Prom section ---------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'queue',
			http_prom => {
				'-common-' => { endpoint => 'fix' },
				depth      => { metric => 'app_queue_depth' },
			},
		},
		index_var => 'queue',
	);
	is($err, undef, "discover_indexes: no error");
	is_deeply([sort @$idx], [sort qw(orders payments email ignore_me)],
		"discover_indexes: all four queue values");
}

# --- per-index extraction -------------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my $sec_hash = {
		'-common-' => { endpoint => 'fix' },
		depth      => { metric => 'app_queue_depth' },
	};
	my %values;
	for my $q (qw(orders payments email))
	{
		my %todos;
		$eng->build_queries(
			section_name    => 'AppQueues',
			section_key     => 'http_prom',
			section_hash    => $sec_hash,
			section_indexed => 'queue',
			index           => $q,
			todos           => \%todos,
		);
		$eng->execute_queries(todos => \%todos);
		$values{$q} = $todos{depth}{rawvalue};
	}
	is($values{orders},   3, "indexed: orders");
	is($values{payments}, 1, "indexed: payments");
	is($values{email},    7, "indexed: email");
}

# --- label_filter narrows results ----------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed      => 'queue',
			label_filter => { queue => '^(orders|payments)$' },
			http_prom    => {
				'-common-' => { endpoint => 'fix' },
				depth      => { metric => 'app_queue_depth' },
			},
		},
		index_var => 'queue',
	);
	is_deeply([sort @$idx], [qw(orders payments)],
		"label_filter excludes ignore_me and email");
}

# --- max_rows caps results -----------------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my ($err, $idx) = $eng->discover_indexes(
		section_config => {
			indexed   => 'label_x',
			max_rows  => 50,
			http_prom => {
				'-common-' => { endpoint => 'fix', path => '/big_metrics' },
				val        => { metric => 'big_metric' },
			},
		},
		index_var => 'label_x',
	);
	is($err, undef, "max_rows: no error");
	is(scalar @$idx, 50, "max_rows: capped at 50");
}

# --- calculate_url for per-index URLs (F5BigIPAPI pattern) --------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'F5_Members',
		section_key  => 'http_json',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			first_member_value => {
				calculate_url => 'CVAR1=statsPath; return "$CVAR1";',
				jsonpath      => '$.members[0].value',
			},
		},
		inventory => FakeInventory->new({ statsPath => "/pool/abc/stats" }),
		index     => 'abc',
		todos     => \%todos,
	);
	is($bs->{error}, undef, "calculate_url: build no error");
	$eng->execute_queries(todos => \%todos);
	is($todos{first_member_value}{rawvalue}, 100,
		"calculate_url: per-index URL fetched and extracted");
}

# --- response cache: one URL fetched once across multiple items ---------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	$eng->build_queries(
		section_name => 'cpu',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'fix' },
			a          => { metric => 'node_load1' },
			b          => { metric => 'node_memory_MemFree_bytes' },
		},
		todos => \%todos,
	);
	$eng->execute_queries(todos => \%todos);
	my @cached_urls = keys %{$eng->{response_cache}};
	is(scalar @cached_urls, 1, "response_cache: a single URL despite two items");
}

# --- error: section without endpoint -------------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'oops',
		section_key  => 'http_prom',
		section_hash => { foo => { metric => 'node_load1' } },
		todos        => \%todos,
	);
	ok(defined $bs->{error}, "missing endpoint reported");
	like($bs->{error}, qr/no endpoint declared/, "error mentions endpoint");
}

# --- error: endpoint not configured on node ------------------------------
{
	my ($eng, $sys) = make_engine(
		endpoints => [{ name => 'fix', port => $port }],
	);
	my %todos;
	my $bs = $eng->build_queries(
		section_name => 'oops',
		section_key  => 'http_prom',
		section_hash => {
			'-common-' => { endpoint => 'wrong_name' },
			x          => { metric => 'node_load1' },
		},
		todos => \%todos,
	);
	ok(defined $bs->{error}, "unknown endpoint reported");
	like($bs->{error}, qr/not configured/, "error mentions configuration");
}

done_testing();
