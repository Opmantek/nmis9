#!/usr/bin/perl
# Static checks for HTTP security headers (OMK-12711).
# Verifies that all Apache config files ship the required security headers,
# that CSP is report-only (not enforcing), that HSTS is absent (gated on
# OMK-12710), and that the installer enables mod_headers.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $root = "$Bin/..";

my %files = (
    apache24   => "$root/conf-default/apache/nmis_apache24.conf",
    apache22   => "$root/conf-default/apache/nmis_apache.conf",
    docker_sec => "$root/conf-default/docker/apache2/conf-enabled/security.conf",
    installer  => "$root/installer_hooks/25-postcopy-apache",
);

my (%text, %lines);
for my $k (keys %files)
{
    open(my $fh, '<', $files{$k}) or die "Cannot open $files{$k}: $!";
    my @l = <$fh>;
    close $fh;
    $lines{$k} = \@l;
    $text{$k}  = join('', @l);
}

# Helper: count active (non-comment) lines matching a pattern.
sub active_count
{
    my ($key, $pat) = @_;
    return scalar grep { !m{^\s*#} && m{$pat}i } @{$lines{$key}};
}

plan tests => 29;

# --- nmis_apache24.conf ---

ok($text{apache24} =~ /IfModule\s+mod_headers\.c/i,
    'apache24: has IfModule mod_headers.c guard');

ok(active_count('apache24', qr/Header\s+always\s+set\s+X-Frame-Options\s+"SAMEORIGIN"/) > 0,
    'apache24: X-Frame-Options SAMEORIGIN (active, not commented)');

ok(active_count('apache24', qr/Header\s+always\s+set\s+X-Content-Type-Options\s+"nosniff"/) > 0,
    'apache24: X-Content-Type-Options nosniff (active, not commented)');

ok(active_count('apache24', qr/Header\s+always\s+set\s+Referrer-Policy/) > 0,
    'apache24: Referrer-Policy present (active, not commented)');

ok(active_count('apache24', qr/Header\s+always\s+set\s+Permissions-Policy/) > 0,
    'apache24: Permissions-Policy present (active, not commented)');

ok(active_count('apache24', qr/Header\s+always\s+set\s+Content-Security-Policy-Report-Only/) > 0,
    'apache24: CSP in report-only mode (active, not commented)');

# Enforcing CSP must NOT appear (would break legacy inline scripts/styles).
# ^\s*Header won't match a #-prefixed comment line.
ok($text{apache24} !~ /^\s*Header\s+always\s+set\s+Content-Security-Policy\s+/mi,
    'apache24: enforcing CSP absent');

# HSTS gated on OMK-12710.
ok($text{apache24} !~ /^\s*Header\s+always\s+set\s+Strict-Transport-Security/mi,
    'apache24: HSTS absent (gated on OMK-12710)');

# --- nmis_apache.conf (Apache 2.2) ---

ok($text{apache22} =~ /IfModule\s+mod_headers\.c/i,
    'apache22: has IfModule mod_headers.c guard');

ok(active_count('apache22', qr/Header\s+always\s+set\s+X-Frame-Options\s+"SAMEORIGIN"/) > 0,
    'apache22: X-Frame-Options SAMEORIGIN (active, not commented)');

ok(active_count('apache22', qr/Header\s+always\s+set\s+X-Content-Type-Options\s+"nosniff"/) > 0,
    'apache22: X-Content-Type-Options nosniff (active, not commented)');

ok(active_count('apache22', qr/Header\s+always\s+set\s+Referrer-Policy/) > 0,
    'apache22: Referrer-Policy present (active, not commented)');

ok(active_count('apache22', qr/Header\s+always\s+set\s+Permissions-Policy/) > 0,
    'apache22: Permissions-Policy present (active, not commented)');

ok(active_count('apache22', qr/Header\s+always\s+set\s+Content-Security-Policy-Report-Only/) > 0,
    'apache22: CSP in report-only mode (active, not commented)');

ok($text{apache22} !~ /^\s*Header\s+always\s+set\s+Content-Security-Policy\s+/mi,
    'apache22: enforcing CSP absent');

ok($text{apache22} !~ /^\s*Header\s+always\s+set\s+Strict-Transport-Security/mi,
    'apache22: HSTS absent (gated on OMK-12710)');

# --- Docker security.conf ---

ok(active_count('docker_sec', qr/Header\s+always\s+set\s+X-Frame-Options\s+"SAMEORIGIN"/) > 0,
    'docker security.conf: X-Frame-Options active (not commented)');

ok(active_count('docker_sec', qr/Header\s+always\s+set\s+X-Content-Type-Options\s+"nosniff"/) > 0,
    'docker security.conf: X-Content-Type-Options active (not commented)');

ok(active_count('docker_sec', qr/Header\s+always\s+set\s+Referrer-Policy/) > 0,
    'docker security.conf: Referrer-Policy active (not commented)');

ok(active_count('docker_sec', qr/Header\s+always\s+set\s+Permissions-Policy/) > 0,
    'docker security.conf: Permissions-Policy active (not commented)');

ok(active_count('docker_sec', qr/Header\s+always\s+set\s+Content-Security-Policy-Report-Only/) > 0,
    'docker security.conf: CSP in report-only mode (active, not commented)');

# Broken colon syntax must be gone.
ok($text{docker_sec} !~ /Header\s+\w+\s+X-Frame-Options\s*:/i,
    'docker security.conf: no broken colon in X-Frame-Options directive');

ok($text{docker_sec} !~ /Header\s+\w+\s+X-Content-Type-Options\s*:/i,
    'docker security.conf: no broken colon in X-Content-Type-Options directive');

ok($text{docker_sec} !~ /^\s*Header\s+always\s+set\s+Content-Security-Policy\s+/mi,
    'docker security.conf: enforcing CSP absent');

ok($text{docker_sec} !~ /^\s*Header\s+always\s+set\s+Strict-Transport-Security/mi,
    'docker security.conf: HSTS absent (gated on OMK-12710)');

# --- Installer ---

# Per-line check excludes commented-out invocations.
ok(active_count('installer', qr/a2enmod\s+headers/) > 0,
    'installer 25-postcopy-apache enables mod_headers (active, not commented)');

# mod_headers must be enabled BEFORE the service apache2 restart line so
# that Apache loads the module on first install (OMK-12711 Critical fix).
my ($enmod_line)   = grep { $lines{installer}[$_] !~ m{^\s*#} && $lines{installer}[$_] =~ m{a2enmod\s+headers} } 0..$#{$lines{installer}};
my ($restart_line) = grep { $lines{installer}[$_] !~ m{^\s*#} && $lines{installer}[$_] =~ m{service\s+apache2\s+restart} } 0..$#{$lines{installer}};
ok(defined $enmod_line && defined $restart_line && $enmod_line < $restart_line,
    'installer: a2enmod headers appears before service apache2 restart');

# Unchanged-config branch regression (OMK-12711 upgrade path).
# On existing Debian/Ubuntu installs the outer diff -q finds no change so Apache
# never restarts; the else branch must enable mod_headers and reload instead.
# Deleting the a2query guard or the reload would leave the 27 tests above
# passing while breaking every upgrade silently.
my ($a2query_line) = grep { $lines{installer}[$_] !~ m{^\s*#}
                             && $lines{installer}[$_] =~ m{a2query\s+-m\s+headers} }
                          0..$#{$lines{installer}};
ok(defined $a2query_line,
    'installer: unchanged-config branch contains a2query -m headers guard');

my ($enmod_after_query) = defined $a2query_line
    ? (grep { $lines{installer}[$_] !~ m{^\s*#}
              && $lines{installer}[$_] =~ m{a2enmod\s+headers} }
           $a2query_line..$#{$lines{installer}})[0]
    : undef;
my ($reload_after_enmod) = defined $enmod_after_query
    ? (grep { $lines{installer}[$_] !~ m{^\s*#}
              && $lines{installer}[$_] =~ m{service\s+apache2\s+reload} }
           $enmod_after_query..$#{$lines{installer}})[0]
    : undef;
ok(defined $a2query_line && defined $enmod_after_query && defined $reload_after_enmod
   && $a2query_line < $enmod_after_query && $enmod_after_query < $reload_after_enmod,
    'installer: unchanged-config branch has a2enmod headers before service apache2 reload');
