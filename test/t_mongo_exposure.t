#!/usr/bin/perl
# Static checks for MongoDB network exposure (OMK-12708 / H12).
#
# Two separate things are asserted, because they fail independently:
#
#   1. No compose file publishes the Mongo port on every interface. Docker
#      writes its NAT rules ahead of the host firewall, so a port published on
#      0.0.0.0 is reachable even when iptables or ufw denies it. The host
#      address must default to loopback and be overridable from the env file.
#   2. mongod itself does not listen on every interface inside the container,
#      but DOES still listen on the compose network, because the nmis container
#      reaches it at mongo:27017. A loopback-only mongod is a broken deployment,
#      so this is asserted in both directions.
#
# Deliberately dependency-free static parsing, matching t_http_security_headers.t.
# YAML::XS is used elsewhere in the tree but is not needed here and would add a
# module requirement to a test that only has to read a handful of lines.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $root = "$Bin/..";

# every compose file that runs a mongo service
my %composes = (
    'compose.yaml'                  => "$root/compose.yaml",
    'conf-default/docker/compose.yaml' => "$root/conf-default/docker/compose.yaml",
    'docker-dev/compose-dev.yaml'   => "$root/docker-dev/compose-dev.yaml",
);

# every env file those composes read
my %envs = (
    '.env'                     => "$root/.env",
    'conf-default/docker/.env' => "$root/conf-default/docker/.env",
    'docker-dev/.env-dev'      => "$root/docker-dev/.env-dev",
);

my $mongod_conf = "$root/conf-default/docker/mongo/mongod.conf";

sub slurp
{
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

# Return the mongo service's published port entries as a listref, each still in
# its original spelling (quotes and all), or undef if the service or its ports
# key cannot be found. undef is reported by the caller as a failure, so a
# restructured compose file fails loudly rather than passing vacuously.
#
# Deliberately hand-parsed. YAML::XS is used elsewhere in the tree but is not a
# dependency of any other test, and this reads four short files with stable
# two-space indentation. If the compose files ever grow anchors, merge keys or
# flow-style sequences, replace this with a real parser rather than extending it.
sub mongo_ports
{
    my ($content) = @_;
    my @lines = grep { !/^\s*#/ } split(/\n/, $content);
    my ($in_mongo, $in_ports, $saw_ports_key, @ports) = (0, 0, 0);

    for my $line (@lines)
    {
        next if ($line =~ /^\s*$/);

        # a service key at two-space indent starts (or ends) the mongo block
        if ($line =~ /^  (\S[^:]*):\s*$/)
        {
            $in_mongo = ($1 eq 'mongo') ? 1 : 0;
            $in_ports = 0;
            next;
        }
        next if (!$in_mongo);

        if ($line =~ /^    ports:\s*$/) { $in_ports = 1; $saw_ports_key = 1; next }
        next if (!$in_ports);

        if ($line =~ /^\s*-\s*(.+?)\s*$/) { push(@ports, $1); next }
        $in_ports = 0;    # any non-list line ends the ports block
    }

    # No ports key under a mongo service means the file is not shaped the way
    # this test assumes, which must fail rather than silently report "no
    # exposure". A ports key with an empty list is a legitimate zero.
    return $saw_ports_key ? \@ports : undef;
}

# ---------------------------------------------------------------- compose files

for my $name (sort keys %composes)
{
    my $content = slurp($composes{$name});
    ok(defined($content), "$name: readable") or next;

    # strip comment-only lines, so a mapping quoted inside an explanatory
    # comment cannot satisfy or break these assertions
    my $code = join("\n", grep { !/^\s*#/ } split(/\n/, $content));

    # Inspect the mongo service's actual ports list rather than pattern-matching
    # the file. Matching a quoted "27017:27017" anywhere was not enough: an
    # unquoted `- 27017:27017`, a single-quoted one, the short form `- "27017"`
    # (all interfaces, random host port), or a second mapping added beside the
    # parameterised one all left the port exposed while every assertion passed.
    # Verified before this was rewritten. Asserting on the parsed list closes all
    # of those at once, because anything extra or differently spelled shows up.
    my $ports = mongo_ports($content);
    ok(defined($ports), "$name: the mongo service's ports list could be parsed") or next;

    is(scalar(@$ports), 1,
       "$name: the mongo service publishes exactly one port mapping")
        or diag("  published mappings found: " . join(", ", @$ports));

    # Every entry, however it is written, must take its host address from the
    # variable. This is what fails if someone adds a hardcoded mapping alongside
    # the parameterised one rather than replacing it.
    for my $p (@$ports)
    {
        like($p, qr/\$\{MONGODB_BIND_ADDR:-127\.0\.0\.1\}/,
             "$name: mapping [$p] takes its host address from MONGODB_BIND_ADDR, defaulting to loopback");
        like($p, qr/\$\{MONGODB_HOST_PORT:-27017\}/,
             "$name: mapping [$p] takes its host port from MONGODB_HOST_PORT");
    }

    is($ports->[0], '"${MONGODB_BIND_ADDR:-127.0.0.1}:${MONGODB_HOST_PORT:-27017}:27017"',
       "$name: the published mapping is exactly the parameterised loopback-default form");

    # the healthcheck is what turns a loopback-only mongod into an unhealthy
    # container rather than a silent outage, so it must keep using the service
    # name and not be "fixed" to localhost
    like($code, qr/mongosh\s+mongo:27017/,
         "$name: mongo healthcheck still probes the network listener, not loopback");
}

# ------------------------------------------------------------------ mongod.conf

{
    my $content = slurp($mongod_conf);
    ok(defined($content), "mongod.conf: readable");

    if (defined($content))
    {
        my ($bindip) = $content =~ /^\s*bindIp:\s*(\S+)\s*$/m;
        ok(defined($bindip), "mongod.conf: has a bindIp setting");

        if (defined($bindip))
        {
            unlike($bindip, qr/0\.0\.0\.0/,
                   "mongod.conf: bindIp does not listen on every interface");
            like($bindip, qr/\blocalhost\b/,
                 "mongod.conf: bindIp still includes localhost");

            # the other direction: it must remain reachable across the compose
            # network, or the nmis container cannot connect at all
            like($bindip, qr/\bmongo\b/,
                 "mongod.conf: bindIp includes the compose service name, so the app can still reach it");
            isnt($bindip, 'localhost',
                 "mongod.conf: bindIp is not loopback-only, which would break the app container");
        }

        # bindIpAll would silently defeat the whole change
        unlike($content, qr/^\s*bindIpAll:\s*true/mi,
               "mongod.conf: bindIpAll is not enabled");
    }
}

# -------------------------------------------------------------------- env files

for my $name (sort keys %envs)
{
    my $content = slurp($envs{$name});
    ok(defined($content), "$name: readable") or next;

    like($content, qr/^MONGODB_BIND_ADDR=127\.0\.0\.1\s*$/m,
         "$name: ships MONGODB_BIND_ADDR defaulting to loopback");
    like($content, qr/^MONGODB_HOST_PORT=27017\s*$/m,
         "$name: ships MONGODB_HOST_PORT");
    unlike($content, qr/^MONGODB_BIND_ADDR=0\.0\.0\.0\s*$/m,
           "$name: does not ship MONGODB_BIND_ADDR on every interface");
}

done_testing();
