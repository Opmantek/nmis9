package NMISx::Controller::Legacy;
use Mojo::Base 'Mojolicious::Controller';

use FindBin;
use Cwd;
use Capture::Tiny qw(capture);
use CGI;
use NMISCGI;
use Compat::NMIS;

# loadConfTable uses $FindBin::RealBin/../conf to find config.
# Ensure we point to a subdirectory of the NMIS base so that ../conf resolves correctly.
my $NMIS_BIN = (-d "$FindBin::RealBin/conf")
	? "$FindBin::RealBin/bin"          # running from nmis9 root
	: $FindBin::RealBin;               # running from a subdirectory already

BEGIN { *CORE::GLOBAL::exit = sub { CORE::exit($_[0] // 0) } }

our %ROUTE_CONFIG = (
	'access.pl'        => { module => 'NMISCGI::Access',       needs_auth => 1 },
	'community_rss.pl' => { module => 'NMISCGI::CommunityRss', needs_auth => 0 },
	'config.pl'        => { module => 'NMISCGI::Config',       needs_auth => 1, skip_filter => 1 },
	'events.pl'        => { module => 'NMISCGI::Events',       needs_auth => 1, skip_filter => 1 },
	'find.pl'          => { module => 'NMISCGI::Find',         needs_auth => 1 },
	'ip.pl'            => { module => 'NMISCGI::Ip',           needs_auth => 1 },
	'logs.pl'          => { module => 'NMISCGI::Logs',         needs_auth => 1 },
	'menu.pl'          => { module => 'NMISCGI::Menu',         needs_auth => 1 },
	'model_policy.pl'  => { module => 'NMISCGI::ModelPolicy',  needs_auth => 1 },
	'models.pl'        => { module => 'NMISCGI::Models',       needs_auth => 1 },
	'modules.pl'       => { module => 'NMISCGI::Modules',      needs_auth => 0 },
	'network.pl'       => { module => 'NMISCGI::Network',      needs_auth => 1 },
	'nmiscgi.pl'       => { module => 'NMISCGI::Nmiscgi',      needs_auth => 1 },
	'node.pl'          => { module => 'NMISCGI::Node',         needs_auth => 1 },
	'nodeconf.pl'      => { module => 'NMISCGI::Nodeconf',     needs_auth => 1 },
	'opstatus.pl'      => { module => 'NMISCGI::Opstatus',     needs_auth => 1 },
	'outages.pl'       => { module => 'NMISCGI::Outages',      needs_auth => 1 },
	'reports.pl'       => { module => 'NMISCGI::Reports',      needs_auth => 1 },
	'rrddraw.pl'       => { module => 'NMISCGI::Rrddraw',      needs_auth => 1 },
	'services.pl'      => { module => 'NMISCGI::Services',     needs_auth => 1 },
	'setup.pl'         => { module => 'NMISCGI::Setup',        needs_auth => 1 },
	'snmp.pl'          => { module => 'NMISCGI::Snmp',         needs_auth => 1 },
	'tables.pl'        => { module => 'NMISCGI::Tables',       needs_auth => 1 },
	'tools.pl'         => { module => 'NMISCGI::Tools',        needs_auth => 1 },
	'view-event.pl'    => { module => 'NMISCGI::ViewEvent',    needs_auth => 1 },
);

# Pre-load all NMISCGI modules
for my $cfg (values %ROUTE_CONFIG) {
	my $module = $cfg->{module};
	(my $file = $module) =~ s{::}{/}g;
	require "$file.pm";
}

sub dispatch {
	my ($c) = @_;

	my ($script) = $c->req->url->path =~ m{/([^/]+\.pl)$};
	my $cfg = $ROUTE_CONFIG{$script};
	return $c->reply->not_found unless $cfg;

	# Build CGI environment from the Mojo request
	my %cgi_env = _build_cgi_env($c);

	# POST body for STDIN
	my $body = $c->req->body // '';

	my ($stdout, $stderr, $exit_code) = capture {
		# Ensure FindBin points to a subdirectory so ../conf resolves to nmis9/conf
		local $FindBin::RealBin = $NMIS_BIN;
		local $FindBin::Bin = $NMIS_BIN;

		# Set up CGI environment with local scope
		local @ENV{keys %cgi_env} = values %cgi_env;

		# Provide POST body on STDIN
		open(my $stdin_fh, '<', \$body) or die "Cannot open scalar ref as STDIN: $!";
		local *STDIN = $stdin_fh;

		# Reset CGI.pm cached state from previous requests
		CGI::initialize_globals();

		# Override exit to throw instead of terminating the worker
		local *CORE::GLOBAL::exit = sub { die bless ['EXIT', $_[0] // 0], 'NMISx::Exit' };

		eval {
			_run_legacy_cgi($c,$cfg);
		};
		if ($@) {
			die $@ unless ref($@) eq 'NMISx::Exit';
		}
	};

	_send_cgi_response($c, $stdout);
}

sub _build_cgi_env {
	my ($c) = @_;

	my $req = $c->req;
	my $url = $req->url;
	my $headers = $req->headers;

	my %env = (
		REQUEST_METHOD  => $req->method,
		QUERY_STRING    => $url->query->to_string,
		CONTENT_TYPE    => $headers->content_type // '',
		CONTENT_LENGTH  => $headers->content_length // 0,
		REQUEST_URI     => $url->to_string,
		SCRIPT_NAME     => $url->path->to_string,
		PATH_INFO       => '',
		SERVER_NAME     => $url->to_abs->host // 'localhost',
		SERVER_PORT     => $url->to_abs->port // 80,
		SERVER_PROTOCOL => 'HTTP/' . ($req->version // '1.1'),
		REMOTE_ADDR     => $c->tx->remote_address // '127.0.0.1',
		HTTP_HOST       => $headers->host // 'localhost',
		GATEWAY_INTERFACE => 'CGI/1.1',
	);

	$env{HTTPS} = 'ON' if $req->is_secure;

	# Copy HTTP headers as HTTP_* env vars
	for my $name (@{$headers->names}) {
		my $env_name = 'HTTP_' . uc($name);
		$env_name =~ s/-/_/g;
		$env{$env_name} = $headers->header($name);
	}

	return %env;
}

sub _run_legacy_cgi {
	my ($c,$cfg) = @_;

	my %init_opts;
	$init_opts{skip_filter} = 1 if $cfg->{skip_filter};

	my $args = NMISCGI::initialise(%init_opts);
	$args->{logger} = $c->app->log; # pass logger to nmisng
	return unless $args;

	if ($cfg->{needs_auth}) {
		NMISCGI::authenticate($args,
			auth_type     => $args->{Q}{auth_type},
			auth_username => $args->{Q}{auth_username},
			auth_password => $args->{Q}{auth_password},
			cluster_id    => $args->{Q}{cluster_id},			
		) or return;
	}

	# comments say this will be persistent
	$args->{nmisng} = NMISCGI::nmisng($args);

	my $runcgi = $cfg->{module} . '::runcgi';
	no strict 'refs';
	$runcgi->($args);
}

sub _send_cgi_response {
	my ($c, $raw_output) = @_;

	$raw_output //= '';

	my ($header_block, $body);
	if ($raw_output =~ m/\A(.*?)\r?\n\r?\n(.*)\z/s) {
		($header_block, $body) = ($1, $2);
	} else {
		$header_block = '';
		$body = $raw_output;
	}

	my $status = 200;
	my $content_type = 'text/html';

	for my $line (split /\r?\n/, $header_block) {
		if ($line =~ /^Status:\s*(\d+)/i) {
			$status = $1;
		} elsif ($line =~ /^Content-Type:\s*(.+)/i) {
			$content_type = $1;
		} elsif ($line =~ /^Set-Cookie:\s*(.+)/i) {
			$c->res->headers->append('Set-Cookie' => $1);
		} elsif ($line =~ /^Location:\s*(.+)/i) {
			$c->res->headers->location($1);
			$status = 302 if $status == 200;
		} elsif ($line =~ /^([^:]+):\s*(.+)/) {
			$c->res->headers->header($1 => $2);
		}
	}

	$c->res->code($status);
	$c->res->headers->content_type($content_type);
	$c->res->body($body);
	$c->rendered;
}

1;
