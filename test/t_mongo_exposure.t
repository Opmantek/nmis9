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

# every env file those composes read, paired with the compose file that reads
# it. The pairing matters: what an env file must ship is derived from what its
# own compose actually interpolates, rather than assumed identical across all
# three. conf-default/docker/compose.yaml sets no container_name and publishes
# no SNMP port, so requiring those variables there would ship dead settings an
# operator could change with no effect.
my %envs = (
    '.env'                     => { path    => "$root/.env",
                                    compose => "$root/compose.yaml" },
    'conf-default/docker/.env' => { path    => "$root/conf-default/docker/.env",
                                    compose => "$root/conf-default/docker/compose.yaml" },
    'docker-dev/.env-dev'      => { path    => "$root/docker-dev/.env-dev",
                                    compose => "$root/docker-dev/compose-dev.yaml" },
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

    is($ports->[0], '"${MONGODB_BIND_ADDR:-127.0.0.1}:${MONGODB_HOST_PORT:-27017}:${MONGODB_PORT:-27017}"',
       "$name: the published mapping is exactly the parameterised loopback-default form");

    # the healthcheck is what turns a loopback-only mongod into an unhealthy
    # container rather than a silent outage, so it must keep using the service
    # name and not be "fixed" to localhost
    like($code, qr/mongosh\s+mongo:\$\{MONGODB_PORT:-27017\}/,
         "$name: mongo healthcheck still probes the network listener, not loopback");

    # MONGODB_PORT is the single source of truth for the container-side port, so
    # mongod must actually be told to use it. Without the --port flag mongod
    # would take 27017 from mongod.conf while the mapping and NMIS_DB_PORT
    # followed MONGODB_PORT, and changing it would break the stack silently.
    like($code, qr/"--port",\s*"\$\{MONGODB_PORT:-27017\}"/,
         "$name: mongod is started with --port from MONGODB_PORT");

    # The app learns where Mongo is from NMIS_<KEY> environment overrides
    # (Util.pm:1140). Both must be present and must come from the variables,
    # not be hardcoded, or a changed port leaves the app dialling the old one.
    like($code, qr/NMIS_DB_SERVER:\s*\$\{MONGODB_SERVER:-mongo\}/,
         "$name: app gets NMIS_DB_SERVER from MONGODB_SERVER");
    like($code, qr/NMIS_DB_PORT:\s*\$\{MONGODB_PORT:-27017\}/,
         "$name: app gets NMIS_DB_PORT from MONGODB_PORT");

    # The trap this wiring exists to avoid: MONGODB_HOST_PORT is the host side of
    # the published mapping. If the app were pointed at it, a non-default host
    # port would make NMIS dial a port mongod is not listening on inside the
    # compose network.
    unlike($code, qr/NMIS_DB_PORT:\s*\$\{MONGODB_HOST_PORT/,
           "$name: NMIS_DB_PORT is NOT wired to the host-side MONGODB_HOST_PORT");
    unlike($code, qr/NMIS_DB_SERVER:\s*\$\{MONGODB_BIND_ADDR/,
           "$name: NMIS_DB_SERVER is NOT wired to the host-side MONGODB_BIND_ADDR");

    # ---- multi-stack: nothing host-visible may be a bare literal (OMK-12708)
    #
    # A fixed container_name or a fixed published port stops a second stack
    # starting on the same host, which was the documented reason the dev stack
    # could not be brought up alongside an existing one. Volumes and the network
    # need no assertion: compose already prefixes them with the project name.

    # container_name is optional (conf-default/docker/compose.yaml sets none),
    # but any that IS set must come from a variable.
    for my $cn ($code =~ /^\s+container_name:\s*(\S+)\s*$/mg)
    {
        like($cn, qr/^\$\{[A-Z_]+:-\S+\}$/,
             "$name: container_name [$cn] is parameterised, not a fixed literal");
    }

    # the app's own published ports, which clash exactly like Mongo's did
    unlike($code, qr/-\s*["']?8080:8080["']?\s*$/m,
           "$name: does not publish 8080 as a fixed mapping");
    unlike($code, qr/-\s*["']?10001:161\/udp["']?\s*$/m,
           "$name: does not publish the SNMP port as a fixed mapping");
    like($code, qr/\$\{NMIS_HTTP_PORT:-8080\}/,
         "$name: the web port comes from NMIS_HTTP_PORT");
    like($code, qr/\$\{NMIS_BIND_ADDR:-0\.0\.0\.0\}/,
         "$name: the app's publish address comes from NMIS_BIND_ADDR");

    # Positive check for the SNMP publish where it exists, so a hardcoded
    # mapping on some other port cannot pass on the negative assertion alone.
    # conf-default/docker/compose.yaml publishes no SNMP port at all.
    if ($code =~ m{161/udp})
    {
        like($code, qr/\$\{NMIS_SNMP_PORT:-10001\}/,
             "$name: the SNMP port comes from NMIS_SNMP_PORT");
    }

    # images too, so two versions can run side by side
    for my $img ($code =~ /^\s+image:\s*(\S+)\s*$/mg)
    {
        like($img, qr/^\$\{[A-Z_]+:-\S+\}$/,
             "$name: image [$img] is parameterised");
    }
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
    my $content = slurp($envs{$name}->{path});
    ok(defined($content), "$name: readable") or next;

    my $compose = slurp($envs{$name}->{compose}) // '';

    like($content, qr/^MONGODB_BIND_ADDR=127\.0\.0\.1\s*$/m,
         "$name: ships MONGODB_BIND_ADDR defaulting to loopback");
    like($content, qr/^MONGODB_HOST_PORT=27017\s*$/m,
         "$name: ships MONGODB_HOST_PORT");

    # the container-side pair, fed to the app as NMIS_DB_SERVER / NMIS_DB_PORT.
    # All three env files must carry them: before this, only .env defined a port
    # variable at all, so the other two stacks silently used the config default.
    like($content, qr/^MONGODB_SERVER=mongo\s*$/m,
         "$name: ships MONGODB_SERVER for the app's db_server");
    like($content, qr/^MONGODB_PORT=27017\s*$/m,
         "$name: ships MONGODB_PORT for the app's db_port and mongod's own port");

    # the superseded variable: only compose.yaml ever read it, and it is now a
    # second source of truth for the same value
    unlike($content, qr/^NMIS_DB_PORT=/m,
           "$name: no leftover NMIS_DB_PORT competing with MONGODB_PORT");

    # Multi-stack knobs. Each must ship with today's value as the default, or
    # the change is not backwards compatible. But only where its own compose
    # actually reads it: shipping a variable a stack ignores tells an operator
    # they can change something they cannot.
    if ($compose =~ /container_name:/)
    {
        like($content, qr/^NMIS_CONTAINER_NAME=nmis\s*$/m,
             "$name: ships NMIS_CONTAINER_NAME, since its compose pins container names");
        like($content, qr/^MONGO_CONTAINER_NAME=mongo\s*$/m,
             "$name: ships MONGO_CONTAINER_NAME, since its compose pins container names");
    }
    else
    {
        unlike($content, qr/^NMIS_CONTAINER_NAME=/m,
               "$name: does not ship NMIS_CONTAINER_NAME, which its compose would ignore");
        unlike($content, qr/^MONGO_CONTAINER_NAME=/m,
               "$name: does not ship MONGO_CONTAINER_NAME, which its compose would ignore");
    }

    like($content, qr/^NMIS_BIND_ADDR=0\.0\.0\.0\s*$/m,
         "$name: ships NMIS_BIND_ADDR preserving today's all-interfaces web publish");
    like($content, qr/^NMIS_HTTP_PORT=8080\s*$/m,
         "$name: ships NMIS_HTTP_PORT defaulting to 8080");

    # same rule for the SNMP listener, which conf-default's compose never
    # publishes
    if ($compose =~ /161\/udp/)
    {
        like($content, qr/^NMIS_SNMP_PORT=10001\s*$/m,
             "$name: ships NMIS_SNMP_PORT, since its compose publishes the SNMP port");
    }
    else
    {
        unlike($content, qr/^NMIS_SNMP_PORT=/m,
               "$name: does not ship NMIS_SNMP_PORT, which its compose would ignore");
    }

    # the operator has to be told about COMPOSE_PROJECT_NAME: without it, two
    # stacks started from one directory share volumes and corrupt each other
    like($content, qr/COMPOSE_PROJECT_NAME/,
         "$name: documents COMPOSE_PROJECT_NAME for volume and network isolation");
    unlike($content, qr/^MONGODB_BIND_ADDR=0\.0\.0\.0\s*$/m,
           "$name: does not ship MONGODB_BIND_ADDR on every interface");
}

done_testing();
