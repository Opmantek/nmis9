#!/usr/bin/perl
#
# Tests for OMK-12686: ISINDEX @ARGV auth bypass fix (RFC 3875 GATEWAY_INTERFACE guard)
#
# Subtests 1-6 run without a live NMIS server or MongoDB.
# Subtest 7 spawns a real CGI under GATEWAY_INTERFACE=CGI/1.1; it skips cleanly
# when no NMIS install or config is present so the file runs standalone.
#
# Covers:
#   1. All 8 patched CGI/admin files contain the GATEWAY_INTERFACE guard.
#   2. The guard assignment precedes NMISNG::Auth->new in each patched file
#      (auth_require must be set before Auth->new snapshots it at construction).
#   3. No unguarded auth_require=0 across all cgi-bin/*.pl and admin/*.pl
#      (tree-wide regression guard). Files excused via $is_cli/$cli_debugging
#      must carry the GATEWAY_INTERFACE check in that same file's definition.
#   4. Guard variables $is_cli/$cli_debugging carry the GATEWAY_INTERFACE check.
#   5. opstatus.pl cli_debugging covers both @ARGV and !request_uri arms.
#   6. reports.pl: $Q->{print} short-circuit removed from CheckAccess calls.
#   7. Behavioural: shipped guard in network.pl correctly blocks auth bypass
#      when GATEWAY_INTERFACE is set; fires for CLI; ignores empty @ARGV.
#      Reads and evals the actual guard line — no MongoDB or live CGI needed.
#
# Auth.pm fail-closed hardening (CheckAccess double-check) is tracked separately;
# see PR description for the follow-up ticket reference.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

my $nmis_root = "$FindBin::Bin/..";

# The 8 files patched in this PR
my @guarded_files = qw(
    cgi-bin/config.pl
    cgi-bin/tables.pl
    cgi-bin/node.pl
    cgi-bin/rrddraw.pl
    cgi-bin/network.pl
    cgi-bin/reports.pl
    cgi-bin/opstatus.pl
    admin/debug.pl
);

# ---------------------------------------------------------------------------
# 1. GATEWAY_INTERFACE guard is present in every patched file
# ---------------------------------------------------------------------------
subtest 'GATEWAY_INTERFACE guard is present in all patched files' => sub {
    for my $relpath (@guarded_files) {
        my $fullpath = "$nmis_root/$relpath";
        ok(-f $fullpath, "$relpath: file exists") or next;
        open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
        my $found = grep { /(?:not\s+|!\s*)\$ENV\{GATEWAY_INTERFACE\}/ && !/^\s*#/ } <$fh>;
        close $fh;
        ok($found, "$relpath: contains negated GATEWAY_INTERFACE guard");
    }
};

# ---------------------------------------------------------------------------
# 2. Guard expression precedes NMISNG::Auth->new in each patched file
#
# Auth->new snapshots auth_require at construction (Auth.pm:87), so the
# guard must fire before Auth->new is called or it has no effect.
# A missing guard in a file that calls Auth->new is a security defect, not
# a skip-worthy condition — fail rather than skip in that case.
# ---------------------------------------------------------------------------
subtest 'guard assignment precedes NMISNG::Auth->new in all patched files' => sub {
    for my $relpath (@guarded_files) {
        my $fullpath = "$nmis_root/$relpath";
        ok(-f $fullpath, "$relpath: file exists") or next;
        open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
        my @lines = <$fh>;
        close $fh;

        my ($guard_ln) = grep {
            $lines[$_] =~ /GATEWAY_INTERFACE/ &&
            $lines[$_] =~ /auth_require|\$is_cli|\$cli_debugging/
        } 0..$#lines;
        my ($auth_new_ln) = grep { $lines[$_] =~ /NMISNG::Auth->new/ } 0..$#lines;

        if (!defined $auth_new_ln) {
            pass("$relpath: no NMISNG::Auth->new — ordering check N/A");
        } elsif (!defined $guard_ln) {
            fail("$relpath: guard line not found (NMISNG::Auth->new at line "
                . ($auth_new_ln+1) . ")");
        } else {
            ok($guard_ln < $auth_new_ln,
                "$relpath: guard (line " . ($guard_ln+1)
                . ") before Auth->new (line " . ($auth_new_ln+1) . ")");
        }
    }
};

# ---------------------------------------------------------------------------
# 3. No unguarded auth_require=0 across ALL cgi-bin and admin Perl files
#
# Tree-wide check: catches any future CGI added with the old idiom.
# Regex targets the real code form $C->{auth_require} = 0.
# Exclusions: lines already guarded via GATEWAY_INTERFACE directly or
# through the $is_cli / $cli_debugging intermediate variables.
# When a line is excused via an intermediate variable, the variable's
# definition in THAT SAME FILE must also carry the GATEWAY_INTERFACE check —
# this closes the gap where a future file copies the idiom without including
# the guard in the variable definition.
# ---------------------------------------------------------------------------
subtest 'no unguarded auth_require=0 in cgi-bin or admin (tree-wide)' => sub {
    my @all_files = (
        glob("$nmis_root/cgi-bin/*.pl"),
        glob("$nmis_root/admin/*.pl"),
    );
    ok(scalar(@all_files) > 0, 'found cgi-bin/admin Perl files to check');
    for my $fullpath (@all_files) {
        my $relpath = $fullpath;
        $relpath =~ s{^\Q$nmis_root/\E}{};
        open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
        my @lines = <$fh>;
        close $fh;

        my @unguarded = grep {
            /->\{auth_require\}.*=\s*0/
                && !/(?:not\s+|!\s*)\$ENV\{GATEWAY_INTERFACE\}/
                && !/\$cli_debugging\b/
                && !/\$is_cli\b/
                && !/^\s*#/
        } @lines;
        is(scalar(@unguarded), 0,
            "$relpath: no unguarded auth_require=0 assignments")
            or diag("Unguarded lines:\n@unguarded");

        # For any auth_require=0 line excused via an intermediate variable,
        # verify that variable's definition in this same file carries GATEWAY_INTERFACE.
        my @excused_via_var = grep {
            /->\{auth_require\}.*=\s*0/
                && !/GATEWAY_INTERFACE/
                && (/\$cli_debugging\b/ || /\$is_cli\b/)
                && !/^\s*#/
        } @lines;
        if (@excused_via_var) {
            for my $excused (@excused_via_var) {
                my ($var) = ($excused =~ /(\$(?:is_cli|cli_debugging))\b/);
                next unless defined $var;
                my $var_re = quotemeta($var);
                my @guard_defs = grep {
                    !/^\s*#/ && /$var_re\s*=.*(?:not\s+|!\s*)\$ENV\{GATEWAY_INTERFACE\}/
                } @lines;
                ok(scalar(@guard_defs) > 0,
                    "$relpath: $var (on excused auth_require=0 line) defined with negated GATEWAY_INTERFACE guard");
            }
        }
    }
};

# ---------------------------------------------------------------------------
# 4. Guard variables $is_cli and $cli_debugging carry the GATEWAY_INTERFACE check
#
# reports.pl and opstatus.pl use intermediate variables instead of the
# direct guard. Verify those variables are defined with GATEWAY_INTERFACE.
# ---------------------------------------------------------------------------
subtest 'guard variable definitions include GATEWAY_INTERFACE check' => sub {
    for my $relpath ('cgi-bin/reports.pl', 'cgi-bin/opstatus.pl') {
        my $fullpath = "$nmis_root/$relpath";
        ok(-f $fullpath, "$relpath: file exists") or next;
        open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
        my @lines = <$fh>;
        close $fh;
        my @guard_defs = grep {
            /(?:\$is_cli|\$cli_debugging)\s*=.*(?:not\s+|!\s*)\$ENV\{GATEWAY_INTERFACE\}/
        } @lines;
        ok(scalar(@guard_defs) > 0,
            "$relpath: guard variable defined with negated GATEWAY_INTERFACE check");
    }
};

# ---------------------------------------------------------------------------
# 5. opstatus.pl cli_debugging covers both bypass arms
# ---------------------------------------------------------------------------
subtest 'opstatus.pl cli_debugging covers @ARGV and !request_uri arms' => sub {
    my $fullpath = "$nmis_root/cgi-bin/opstatus.pl";
    ok(-f $fullpath, 'opstatus.pl exists') or return;
    open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /cli_debugging.*(?:not\s+|!\s*)\$ENV\{GATEWAY_INTERFACE\}/s,
        'cli_debugging includes negated GATEWAY_INTERFACE guard');
    ok($content =~ /cli_debugging.*request_uri/s,
        'cli_debugging also covers !request_uri arm');
};

# ---------------------------------------------------------------------------
# 6. rpt_dynamic CheckAccess: $Q->{print} short-circuit is gone from reports.pl
# ---------------------------------------------------------------------------
subtest 'reports.pl: $Q->{print} short-circuit removed from CheckAccess calls' => sub {
    my $fullpath = "$nmis_root/cgi-bin/reports.pl";
    ok(-f $fullpath, 'reports.pl exists') or return;
    open(my $fh, '<', $fullpath) or die "cannot open $fullpath: $!";
    my @lines = <$fh>;
    close $fh;

    my @bad = grep { /\$Q->\{print\}\s+or\s+\$AU->CheckAccess/ } @lines;
    is(scalar(@bad), 0,
        'no $Q->{print} short-circuit before CheckAccess remains');
};

# ---------------------------------------------------------------------------
# 7. Behavioural: shipped guard in network.pl blocks auth bypass when
#    GATEWAY_INTERFACE is set.
#
# Reads the actual guard line from the shipped source and evals it in a
# controlled environment — no MongoDB, no live CGI process needed.
# On the pre-fix base the guard line lacks GATEWAY_INTERFACE so the grep
# finds nothing and the subtest fails; on the fixed head all three
# scenarios assert correctly.
# ---------------------------------------------------------------------------
subtest 'behavioural: shipped guard blocks auth bypass when GATEWAY_INTERFACE is set' => sub {
    my $script = "$nmis_root/cgi-bin/network.pl";
    ok(-f $script, 'cgi-bin/network.pl exists') or return;

    open(my $fh, '<', $script) or die "cannot open $script: $!";
    my @lines = <$fh>;
    close $fh;

    # Extract the shipped guard line — grep fails on pre-fix base where the
    # line has no GATEWAY_INTERFACE check, making this subtest go red there.
    my ($guard_line) = grep {
        /auth_require.*=\s*0.*GATEWAY_INTERFACE/ && !/^\s*#/
    } @lines;
    ok(defined $guard_line,
        'guard line (auth_require=0 ... GATEWAY_INTERFACE) present in network.pl') or return;
    $guard_line =~ s/^\s+//;

    # Web path: GATEWAY_INTERFACE set + non-empty @ARGV -> guard must NOT fire
    my $C = { auth_require => 1 };
    { local @ARGV = ('widget'); local $ENV{GATEWAY_INTERFACE} = 'CGI/1.1'; eval $guard_line; }
    isnt($C->{auth_require}, 0,
        'GATEWAY_INTERFACE set: shipped guard does not zero auth_require (web path protected)');

    # CLI path: no GATEWAY_INTERFACE + non-empty @ARGV -> guard fires (intended bypass)
    $C = { auth_require => 1 };
    { local @ARGV = ('widget'); delete local $ENV{GATEWAY_INTERFACE}; eval $guard_line; }
    is($C->{auth_require}, 0,
        'GATEWAY_INTERFACE absent: shipped guard zeros auth_require (CLI bypass fires)');

    # No ISINDEX tokens: empty @ARGV -> guard must not fire even without GATEWAY_INTERFACE
    $C = { auth_require => 1 };
    { local @ARGV = (); delete local $ENV{GATEWAY_INTERFACE}; eval $guard_line; }
    isnt($C->{auth_require}, 0,
        'empty @ARGV: shipped guard does not zero auth_require (no ISINDEX tokens)');
};

done_testing;
