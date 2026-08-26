#!/usr/bin/perl
# Static checks for the scoped MongoDB app account in the shipped compose stacks
# (OMK-12826 / OMK-12709 / H13).
#
# Two properties, which fail independently:
#
#   1. Every shipped compose runs NMIS as the scoped app user, not the Mongo root
#      identity: NMIS_DB_USERNAME is the literal nmis9RW, NMIS_DB_AUTH_SOURCE is
#      nmisng, and the admin/bootstrap identity is supplied separately via
#      NMIS_DB_ADMIN_USERNAME/PASSWORD. This covers the root compose.yaml too,
#      which was originally left running as root (1a).
#   2. The scoped app user does NOT share the root password: NMIS_DB_PASSWORD is
#      wired to a DIFFERENT variable than the Mongo root/admin password, so an
#      attacker who reads the app config or env does not thereby hold root (1b).
#
# Dependency-free static parsing, matching t_mongo_exposure.t: these files have
# stable two-space indentation and each key appears once.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $root = "$Bin/..";

my %composes = (
    'compose.yaml'                     => "$root/compose.yaml",
    'conf-default/docker/compose.yaml' => "$root/conf-default/docker/compose.yaml",
    'docker-dev/compose-dev.yaml'      => "$root/docker-dev/compose-dev.yaml",
);

my %envs = (
    '.env'                     => "$root/.env",
    'conf-default/docker/.env' => "$root/conf-default/docker/.env",
    'docker-dev/.env-dev'      => "$root/docker-dev/.env-dev",
);

sub slurp
{
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

# value of a `KEY: value` mapping in comment-stripped compose text (each key
# appears once across our files)
sub cval
{
    my ($code, $key) = @_;
    return ($code =~ /^\s*\Q$key\E:\s*(\S+)\s*$/m) ? $1 : undef;
}

# value of a `KEY=value` line in an env file (value may be empty)
sub eval_env
{
    my ($content, $key) = @_;
    return ($content =~ /^\Q$key\E=(.*)$/m) ? $1 : undef;
}

# the deny set shared with installer_hooks/common_dbpassword.sh
sub is_default_pw
{
    my ($v) = @_;
    return 1 if (!defined($v) || $v eq '');
    return 1 if ($v eq 'example' || $v eq 'password' || $v eq 'op42flow42');
    return 1 if ($v =~ /^CHANGE_ME/);
    return 0;
}

# ---------------------------------------------------------------- compose files
for my $name (sort keys %composes)
{
    my $content = slurp($composes{$name});
    ok(defined($content), "$name: readable") or next;
    my $code = join("\n", grep { !/^\s*#/ } split(/\n/, $content));

    # 1. scoped app identity
    is(cval($code, 'NMIS_DB_USERNAME'), 'nmis9RW',
        "$name: app runs as the scoped nmis9RW, not the root identity");
    is(cval($code, 'NMIS_DB_AUTH_SOURCE'), 'nmisng',
        "$name: NMIS_DB_AUTH_SOURCE is nmisng");
    is(cval($code, 'NMIS_DB_ADMIN_USERNAME'), '${MONGODB_USERNAME}',
        "$name: the admin/bootstrap user comes from MONGODB_USERNAME");

    # 2. distinct app password (1b)
    my $app_pw   = cval($code, 'NMIS_DB_PASSWORD');
    my $admin_pw = cval($code, 'NMIS_DB_ADMIN_PASSWORD');
    my $root_pw  = cval($code, 'MONGO_INITDB_ROOT_PASSWORD');

    ok(defined($app_pw) && defined($admin_pw) && defined($root_pw),
        "$name: app, admin and root passwords are all set")
        or next;

    is($admin_pw, $root_pw,
        "$name: the admin/bootstrap password IS the Mongo root password");
    isnt($app_pw, $root_pw,
        "$name: the app password is NOT the Mongo root password (1b)");
    isnt($app_pw, $admin_pw,
        "$name: the app password is NOT the admin password (1b)");
    like($app_pw, qr/\$\{MONGODB_APP_PASSWORD\}/,
        "$name: the app password comes from MONGODB_APP_PASSWORD");
}

# -------------------------------------------------------------------- env files
for my $name (sort keys %envs)
{
    my $content = slurp($envs{$name});
    ok(defined($content), "$name: readable") or next;

    my $root_pw = eval_env($content, 'MONGODB_PASSWORD');
    my $app_pw  = eval_env($content, 'MONGODB_APP_PASSWORD');

    ok(defined($root_pw), "$name: ships MONGODB_PASSWORD (root/admin secret)");
    ok(defined($app_pw),  "$name: ships MONGODB_APP_PASSWORD (scoped app secret)");

    if ($name eq 'docker-dev/.env-dev')
    {
        # dev ships fixed, working values; they must differ and be off the deny set
        isnt($app_pw, $root_pw, "$name: dev app and root passwords differ");
        ok(!is_default_pw($app_pw), "$name: dev app password is off the deny set");
        ok(!is_default_pw($root_pw), "$name: dev root password is off the deny set");
    }
    elsif ($name eq 'conf-default/docker/.env')
    {
        # prod ships placeholders; make prod-setup generates distinct real values
        ok(is_default_pw($root_pw), "$name: prod ships a placeholder root password");
        ok(is_default_pw($app_pw),  "$name: prod ships a placeholder app password");
    }
}

done_testing();
