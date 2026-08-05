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

# ---------------------------------------------------------------- compose files

for my $name (sort keys %composes)
{
    my $content = slurp($composes{$name});
    ok(defined($content), "$name: readable") or next;

    # strip comment-only lines, so a mapping quoted inside an explanatory
    # comment cannot satisfy or break these assertions
    my $code = join("\n", grep { !/^\s*#/ } split(/\n/, $content));

    # the bare mapping publishes on all interfaces: this is the actual defect
    unlike($code, qr/-\s*"27017:27017"/,
           "$name: does not publish 27017 on every interface");
    unlike($code, qr/-\s*"0\.0\.0\.0:\d+:27017"/,
           "$name: does not publish 27017 on an explicit 0.0.0.0");

    # and what it should be instead: host address parameterised, loopback default
    like($code, qr/\$\{MONGODB_BIND_ADDR:-127\.0\.0\.1\}/,
         "$name: host address comes from MONGODB_BIND_ADDR, defaulting to loopback");
    like($code, qr/\$\{MONGODB_HOST_PORT:-27017\}/,
         "$name: host port comes from MONGODB_HOST_PORT, defaulting to 27017");
    like($code, qr/-\s*"\$\{MONGODB_BIND_ADDR:-127\.0\.0\.1\}:\$\{MONGODB_HOST_PORT:-27017\}:27017"/,
         "$name: the published mapping is well formed");

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
