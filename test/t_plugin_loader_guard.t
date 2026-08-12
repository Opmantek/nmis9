#!/usr/bin/perl
# Functional checks for OMK-12697 plugin loader permission guard.
# Verifies that NMISNG::Util rejects plugins that are group/world-writable or
# not owned by nmis_user/root, that the directory-level check is present, and
# that trusted_uid acceptance works correctly.
#
# Subtests call plugin_file_safe() and plugin_dir_safe() directly so that
# deleting or inverting the guard in NMISNG::Util would cause failures.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile tempdir);

my $root = "$Bin/..";

plan tests => 7;

# --- Functional: call plugin_file_safe directly (subtests 1-5) ---

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

# Subtest 1: group-writable file rejected by mode guard
chmod(0664, $tmpfile);
my ($ok1, $r1) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
ok(!$ok1 && $r1 =~ /writable/i,
    'functional: group-writable (0664) file rejected by plugin_file_safe');

# Subtest 2: world-writable file rejected by mode guard
chmod(0606, $tmpfile);
my ($ok2, $r2) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
ok(!$ok2 && $r2 =~ /writable/i,
    'functional: world-writable (0606) file rejected by plugin_file_safe');

# Subtests 3-5: UID guard (meaningful only when not running as root)
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
    # Subtest 3: non-root-owned 0644, no trusted_uid → rejected by uid guard
    my ($ok3, $r3) = NMISNG::Util::plugin_file_safe($tmpfile, 0);
    ok(!$ok3 && $r3 =~ /UID/i,
        'functional: non-root-owned 0644 file rejected by uid guard (nmis_user not set)');

    # Subtest 4: same file, trusted_uid = owner's uid → accepted (nmis_user trust path)
    my ($ok4, $r4) = NMISNG::Util::plugin_file_safe($tmpfile, $my_uid);
    ok($ok4,
        'functional: non-root-owned file accepted when trusted_uid matches owner (nmis_user trust path)');

    # Subtest 5: mode guard fires before uid guard even when trusted_uid matches
    chmod(0664, $tmpfile);
    my ($ok5, $r5) = NMISNG::Util::plugin_file_safe($tmpfile, $my_uid);
    ok(!$ok5 && $r5 =~ /writable/i,
        'functional: mode guard fires first even when trusted_uid matches owner');
}

# Subtests 6-7: directory-level check via plugin_dir_safe
my $tmpdir = tempdir(CLEANUP => 1);

# Subtest 6: group-writable directory rejected
chmod(0775, $tmpdir);
my ($ok6, $r6) = NMISNG::Util::plugin_dir_safe($tmpdir, 0);
ok(!$ok6 && $r6 =~ /writable/i,
    'functional: group-writable (0775) directory rejected by plugin_dir_safe');

# Subtest 7: safe directory (0755) owned by current user accepted via trusted_uid
chmod(0755, $tmpdir);
my $tmpdir_uid = (CORE::lstat($tmpdir))[4];
my ($ok7, $r7) = NMISNG::Util::plugin_dir_safe($tmpdir, $tmpdir_uid);
ok($ok7, 'functional: 0755 directory accepted when owner matches trusted_uid');
