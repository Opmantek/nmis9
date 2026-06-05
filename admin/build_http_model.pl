#!/usr/bin/perl
#
# build_http_model.pl -- generate a starter Common-Linux-HTTP-<App>.nmis
# plus matching Graph-*.nmis files from a Prometheus /metrics endpoint.
#
# Usage:
#   admin/build_http_model.pl url=http://host:port/metrics name=MyApp \
#       [auth_bearer=<token>] [out=<dir>] [endpoint=<name>] [prefix_depth=2]
#
# Output goes to <out> (default: tmp/scaffold-<name>-<ts>/), containing:
#   - Common-Linux-HTTP-<name>.nmis     -- the model file
#   - Graph-<name>-<Section>.nmis       -- per-section graph files
#   - README.md                          -- TODOs the operator must address
#
# The output is a starting point: review the README's TODO list, edit
# the files, then copy into models-default/ (if shipping) or
# models-custom/ (if site-specific).

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use Mojo::UserAgent;
use POSIX qw(strftime);
use NMISNG::Util;
use NMISNG::HTTPModelBuilder;

my $args = NMISNG::Util::get_args_multi(@ARGV);

unless ($args->{url} && $args->{name})
{
	die "Usage: $0 url=<URL> name=<App> [auth_bearer=<token>] [out=<dir>] "
		. "[endpoint=<name>] [prefix_depth=2]\n"
		. "  url   absolute URL of the Prometheus /metrics endpoint\n"
		. "  name  short name for the application (e.g. MongoDB, Redis)\n";
}

my $endpoint_name = $args->{endpoint} // _to_snake($args->{name}) . '_exporter';

# Fetch.
my $ua = Mojo::UserAgent->new;
$ua->connect_timeout(15);
$ua->request_timeout(15);

my $tx = $ua->build_tx(GET => $args->{url});
$tx->req->headers->header('Authorization' => "Bearer $args->{auth_bearer}")
	if $args->{auth_bearer};
$tx = $ua->start($tx);

if (my $err = $tx->error)
{
	die "fetch failed: $err->{message}"
		. (defined $err->{code} ? " (HTTP $err->{code})" : "") . "\n";
}
my $body = $tx->res->body;
die "fetch returned empty body\n" unless defined $body && length $body;

# Build.
my $builder = NMISNG::HTTPModelBuilder->new(
	name         => $args->{name},
	endpoint     => $endpoint_name,
	prefix_depth => $args->{prefix_depth} // 2,
);
my $result = $builder->build($body);

# Write.
my $out = $args->{out} // do {
	my $ts = strftime('%Y%m%d-%H%M%S', localtime);
	"$FindBin::Bin/../tmp/scaffold-$args->{name}-$ts";
};
my $written = $builder->emit_files(out_dir => $out, result => $result);

print "Wrote $written->{common}\n";
print "Wrote $written->{readme}\n";
print "Output dir: $out\n";
my $todo_count = scalar @{$result->{todos} || []};
print "TODOs: $todo_count -- see README.md\n";

exit 0;

sub _to_snake
{
	my ($s) = @_;
	$s = lc $s;
	$s =~ s/[^a-z0-9]+/_/g;
	$s =~ s/_+/_/g;
	$s =~ s/^_|_$//g;
	return $s;
}
