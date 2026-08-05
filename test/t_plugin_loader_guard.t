#!/usr/bin/perl
# Static and functional checks for OMK-12697 plugin loader permission guard.
# Verifies that NMISNG.pm rejects plugins that are group/world-writable or
# not owned by nmis_user/root, that the directory-level check is present, that
# fixperms tightens plugin directories, and that Config.nmis has nmis_user.
#
# Functional subtests call NMISNG::Util::plugin_file_safe() directly so that
# deleting or inverting the guard would cause them to fail (not mere tautologies).

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile tempdir);

my $root    = "$Bin/..";
my $nmisng  = "$root/lib/NMISNG.pm";
my $util_pm = "$root/lib/NMISNG/Util.pm";
my $nmiscli = "$root/bin/nmis-cli";
my $config  = "$root/conf-default/Config.nmis";

open(my $fh1, '<', $nmisng)  or die "Cannot open $nmisng: $!";
my @ng_lines = <$fh1>; close $fh1;

open(my $fhu, '<', $util_pm) or die "Cannot open $util_pm: $!";
my @util_lines = <$fhu>; close $fhu;

open(my $fh2, '<', $nmiscli) or die "Cannot open $nmiscli: $!";
my @cli_lines = <$fh2>; close $fh2;

open(my $fh3, '<', $config)  or die "Cannot open $config: $!";
my $cfg_text = join('', <$fh3>); close $fh3;

plan tests => 16;

# --- Util.pm: per-file guard implementation (static checks 1-3) ---
# plugin_file_safe() lives in NMISNG::Util; checks look there.

ok(scalar(grep { !m{^\s*#} && m{CORE::lstat\(\s*\$pluginfile\s*\)} } @util_lines) > 0,
    'Util.pm plugin_file_safe: CORE::lstat() used — symlink bypass + File::stat override prevented');

ok(scalar(grep { !m{^\s*#} && m{\$file_mode\s*&\s*022} } @util_lines) > 0,
    'Util.pm plugin_file_safe: group/world-writable mode check present');

ok(scalar(grep { !m{^\s*#} && m{\$file_uid\s*!=\s*0} } @util_lines) > 0,
    'Util.pm plugin_file_safe: root-ownership check present');

# --- NMISNG.pm: trust resolution and load ordering (static checks 4-5) ---

ok(scalar(grep { !m{^\s*#} && m{\bnmis_user\b} } @ng_lines) > 0,
    'NMISNG.pm: reads nmis_user from config for plugin trust resolution');

# Guard call must precede require (check-then-load ordering).
my ($guard_line)   = grep { $ng_lines[$_] =~ /plugin_file_safe/ } 0..$#ng_lines;
my ($require_line) = grep { $ng_lines[$_] =~ /require\s+"\$pluginfile"/ } 0..$#ng_lines;
ok(defined $guard_line && defined $require_line && $guard_line < $require_line,
    'NMISNG.pm: plugin_file_safe call appears before require line');

# --- NMISNG.pm: directory-level check (static check 6) ---

ok(scalar(grep { !m{^\s*#} && m{plugin_dir_safe} } @ng_lines) > 0,
    'NMISNG.pm: plugin_dir_safe called for directory-level check');

# --- nmis-cli fixperms tightening (static checks 7-8) ---

ok(scalar(grep { !m{^\s*#} && m{go-w} } @cli_lines) > 0,
    'nmis-cli fixperms: removes group/world write from plugin dirs (go-w)');

ok(scalar(grep { !m{^\s*#} && m{\$powner} && m{\$plugindir} } @cli_lines) > 0,
    'nmis-cli fixperms: chowns plugin dirs to nmis_user:nmis_group');

# --- Config.nmis (static check 9) ---

ok($cfg_text =~ /nmis_user/, 'Config.nmis: nmis_user key present (used for plugin trust resolution)');

# --- Functional: call plugin_file_safe directly (subtests 10-14) ---
# These call the real guard function. Deleting or inverting the guard in
# NMISNG::Util.pm would cause these subtests to fail.

{
    local @INC = ("$root/lib", @INC);
    eval { require NMISNG::Util; };
    if ($@) {
        BAIL_OUT("NMISNG::Util failed to load — functional subtests cannot run: $@");
    }
}

my (undef, $tmpfile) = tempfile(SUFFIX => '.pm', UNLINK => 1);
open(my $tfh, '>', $tmpfile) or die "Cannot write temp plugin: $!";
print $tfh "package TestPlugin;\n1;\n";
close $tfh;

# Subtest 10: group-writable file rejected by mode guard
chmod(0664, $tmpfile);
my ($ok10, $r10) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
ok(!$ok10 && $r10 =~ /writable/i,
    'functional: group-writable (0664) file rejected by plugin_file_safe');

# Subtest 11: world-writable file rejected by mode guard
chmod(0606, $tmpfile);
my ($ok11, $r11) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
ok(!$ok11 && $r11 =~ /writable/i,
    'functional: world-writable (0606) file rejected by plugin_file_safe');

# Subtests 12-14: UID guard (meaningful only when not running as root)
chmod(0644, $tmpfile);
my $my_uid = $>;  # effective uid of current process

if ($my_uid == 0)
{
    pass('functional: uid guard test skipped — running as root (file is root-owned, trivially passes)');
    pass('functional: trusted_uid acceptance test skipped — running as root');
    pass('functional: mode-before-uid ordering test skipped — running as root');
}
else
{
    # Subtest 12: non-root-owned 0644, no trusted_uid → rejected by uid guard
    my ($ok12, $r12) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
    ok(!$ok12 && $r12 =~ /UID/i,
        'functional: non-root-owned 0644 file rejected by uid guard (nmis_user not set)');

    # Subtest 13: same file, trusted_uid = owner's uid → accepted (nmis_user trust path)
    my ($ok13, $r13) = NMISNG::Util::plugin_file_safe($tmpfile, $my_uid);
    ok($ok13,
        'functional: non-root-owned file accepted when trusted_uid matches owner (nmis_user trust path)');

    # Subtest 14: mode guard fires before uid guard even when trusted_uid matches
    chmod(0664, $tmpfile);
    my ($ok14, $r14) = NMISNG::Util::plugin_file_safe($tmpfile, $my_uid);
    ok(!$ok14 && $r14 =~ /writable/i,
        'functional: mode guard fires first even when trusted_uid matches owner');
}

# Subtests 15-16: directory-level check via plugin_dir_safe
my $tmpdir = tempdir(CLEANUP => 1);

# Subtest 15: group-writable directory rejected
chmod(0775, $tmpdir);
my ($ok15, $r15) = NMISNG::Util::plugin_dir_safe($tmpdir, 0);
ok(!$ok15 && $r15 =~ /writable/i,
    'functional: group-writable (0775) directory rejected by plugin_dir_safe');

# Subtest 16: safe directory (0755) owned by current user accepted via trusted_uid
chmod(0755, $tmpdir);
my $tmpdir_uid = (CORE::lstat($tmpdir))[4];
my ($ok16, $r16) = NMISNG::Util::plugin_dir_safe($tmpdir, $tmpdir_uid);
ok($ok16, 'functional: 0755 directory accepted when owner matches trusted_uid');
