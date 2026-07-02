#!/usr/bin/perl
# Capture a live net-snmp host into the flat OID->value JSON that
# NMISNG::Snmp::Mock consumes. Usage: capture_host.pl <host> <port> <community> <outfile>
#
# Parser notes (found by inspecting real net-snmp -On -OQ -Ln output against
# a live Linux host, 172.20.0.1:1161, rather than assuming the format):
#  - -OQ ("quick print") never emits a TYPE: prefix, for any type seen in the
#    system/interfaces/ip/hostresources subtrees (INTEGER, Counter32/64,
#    Gauge32, STRING, Hex-STRING, OID, IpAddress, Timeticks all print bare).
#  - Timeticks values print as "D:HH:MM:SS.ss" (e.g. "30:10:49:05.61"), NOT
#    the "(NNNN) D:HH:MM:SS.ss" form the task brief assumed. There is no
#    parenthesised raw tick count to preserve with -OQ, so the duration
#    string is captured as-is.
#  - STRING values are double-quoted and may legitimately contain embedded
#    raw newlines (seen in hrSWRunParameters / hrSWRunPath process command
#    lines, and in hrSystemProcesses' extra output such as kernel boot
#    cmdline). A naive one-line-per-OID reader corrupts these. This parser
#    accumulates continuation lines until the quote closes.
#  - Hex-STRING values print as a quoted, space-separated hex-byte string
#    (e.g. "8A 0A 9B 47 DD 69 "), already unambiguous once unquoted.
#  - OID-valued OIDs (e.g. sysObjectID) print as a bare dotted OID with a
#    leading dot and no quotes, so they pass through untouched.
# Any line that cannot be classified is recorded via warn() and skipped
# (not silently dropped) so a re-run of the capture can be inspected.
use strict;
use warnings;
use JSON::XS;
use POSIX qw(strftime);

my ($host, $port, $comm, $out) = @ARGV;
die "usage: capture_host.pl host port community outfile\n" if (!$out);
die "refusing to overwrite existing capture $out\n" if (-e $out);    # frozen capture is stable

# Walk the subtrees the net-snmp model reads. -On = numeric OIDs, -OQ = quick
# print (no type prefixes), -Ln = no logging to stderr/syslog.
my @roots = qw(1.3.6.1.2.1.1 1.3.6.1.2.1.2 1.3.6.1.2.1.4 1.3.6.1.2.1.31 1.3.6.1.2.1.25);

my %walk;
my @unparsed;

for my $root (@roots)
{
	open(my $fh, "-|", "snmpwalk", "-v2c", "-c", $comm, "-On", "-OQ", "-Ln", "$host:$port", ".$root")
		or die "snmpwalk failed for $root: $!\n";

	# Numeric-OID lines look like: .1.3.6.1.2.1.1.1.0 = <value>
	# <value> may be a quoted string that spans multiple raw lines (embedded
	# newlines in STRING payloads), so buffer a pending OID/value pair and
	# only commit it once we see the next OID line (or EOF) confirm it's
	# complete.
	my ($pending_oid, $pending_val);

	my $commit = sub {
		return if (!defined $pending_oid);
		my $val = $pending_val;
		if ($val =~ /^"(.*)"$/s)
		{
			$val = $1;                # unquote STRING/Hex-STRING payloads
		}
		else
		{
			$val =~ s/^\s+|\s+$//g;    # trim bare numeric/OID/IpAddress values
		}
		$walk{$pending_oid} = $val;
		($pending_oid, $pending_val) = (undef, undef);
	};

	while (my $line = <$fh>)
	{
		chomp $line;
		if ($line =~ /^\.([\d.]+)\s+=\s+(.*)$/)
		{
			$commit->();               # flush the previous OID before starting a new one
			($pending_oid, $pending_val) = ($1, $2);
		}
		elsif (defined $pending_oid)
		{
			# Continuation of a multi-line quoted STRING value.
			$pending_val .= "\n" . $line;
		}
		else
		{
			push @unparsed, $line;
			warn "capture_host: unparsed snmpwalk line for $root: $line\n";
		}
	}
	$commit->();
	close($fh);
}

die "capture is empty — snmpwalk returned nothing\n" if (!keys %walk);

if (@unparsed)
{
	warn "capture_host: " . scalar(@unparsed) . " snmpwalk line(s) could not be parsed; see warnings above.\n";
}

# Embed provenance so the frozen reference is self-documenting. This is a
# non-OID key: the collect never queries it, and collect_bench.pl drops
# _-prefixed keys before loading, so it does not affect any measurement.
my $oidcount = scalar(keys %walk);
my $ifcount  = grep { /^1\.3\.6\.1\.2\.1\.2\.2\.1\.2\./ } keys %walk;
$walk{_capture} = {
	captured        => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()),
	source          => "$host:$port community $comm",
	sysDescr        => $walk{"1.3.6.1.2.1.1.1.0"},
	oid_count       => $oidcount,
	interface_count => $ifcount,
	tool            => "test/bench/capture_host.pl",
	note            => "Frozen reference for reproducible collect benchmarks; non-OID key, dropped on load.",
};

open(my $o, ">", $out) or die "cannot write $out: $!\n";
print $o JSON::XS->new->canonical->pretty->encode(\%walk);
close($o);

printf "captured %d OIDs (+_capture provenance) to %s\n", $oidcount, $out;
