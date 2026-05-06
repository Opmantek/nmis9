#!/usr/bin/perl
#
# import_grafana_dashboard.pl -- generate a starter Common-Linux-HTTP-<App>.nmis
# plus matching Graph-*.nmis files from a Grafana dashboard JSON file.
#
# Usage:
#   admin/import_grafana_dashboard.pl file=dashboard.json name=MyApp \
#       [out=<dir>] [endpoint=<name>]
#
# Translates simple PromQL targets (bare metric, with label filter,
# and rate/irate/increase wraps) directly. Anything else (sum,
# histogram_quantile, arithmetic, non-Prometheus datasources) is
# preserved verbatim in the output README's TODO list for manual
# conversion.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use POSIX qw(strftime);
use NMISNG::Util;
use NMISNG::GrafanaDashboardImporter;

my $args = NMISNG::Util::get_args_multi(@ARGV);

unless ($args->{file} && $args->{name})
{
	die "Usage: $0 file=<dashboard.json> name=<App> [out=<dir>] "
		. "[endpoint=<name>]\n"
		. "  file  path to the Grafana dashboard JSON\n"
		. "  name  short name for the application (used in filenames\n"
		. "        and graphtype prefixes)\n";
}

unless (-e $args->{file})
{
	die "input file not found: $args->{file}\n";
}

open(my $fh, '<', $args->{file}) or die "cannot read $args->{file}: $!\n";
local $/;
my $body = <$fh>;
close $fh;

my $endpoint_name = $args->{endpoint} // _to_snake($args->{name}) . '_exporter';

my $imp = NMISNG::GrafanaDashboardImporter->new(
	name     => $args->{name},
	endpoint => $endpoint_name,
);
my $result = $imp->build($body);

my $out = $args->{out} // do {
	my $ts = strftime('%Y%m%d-%H%M%S', localtime);
	"$FindBin::Bin/../tmp/grafana-$args->{name}-$ts";
};

my $written = $imp->emit_files(out_dir => $out, result => $result);

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
