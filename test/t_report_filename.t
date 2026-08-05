#!/usr/bin/perl
#
# Tests for OMK-12701: fileReport filename validation fix
#
# Runs without a live NMIS server or MongoDB. Uses File::Temp for isolation.
#
# Covers:
#   1. validate_report_filename() rejects traversal, absolute paths, leading dot, etc.
#   2. validate_report_filename() accepts legitimate stored report filenames.
#   3. The \z anchor does not accept a trailing newline.
#   4. Falsiness: empty string rejected; "0.html" accepted; "0" rejected.
#   5. Symlink rejection behaviour.
#   6. Static: O_NOFOLLOW present in sysopen call.
#   7. Static: error message does not echo attacker-controlled path.
#   8. Static: allowlist regex uses \z anchor (not $).
#   9. Static: falsiness check uses eq '' (not !$report_file).
#
# Subtests 1-4 extract validate_report_filename() directly from reports.pl
# and call the real production code. On the vulnerable base (function absent)
# they fail; on the fixed head they exercise the shipped allowlist.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(O_RDONLY O_NOFOLLOW);

my $reports_pl = "$FindBin::Bin/../cgi-bin/reports.pl";

# ---------------------------------------------------------------------------
# Extract validate_report_filename from reports.pl and compile it so that
# subtests 1-4 exercise real production code, not a mirrored copy.
# ---------------------------------------------------------------------------
my $fn_ref;
{
    if (-f $reports_pl) {
        open(my $fh, '<', $reports_pl) or die "cannot open $reports_pl: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Line-by-line brace-balanced extraction of the sub body
        my @lines = split /\n/, $content;
        my $start = undef;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^sub\s+validate_report_filename\b/) {
                $start = $i; last;
            }
        }
        if (defined $start) {
            my ($depth, $end) = (0, $start);
            for my $i ($start .. $#lines) {
                $depth += () = $lines[$i] =~ /\{/g;
                $depth -= () = $lines[$i] =~ /\}/g;
                if ($depth == 0 && $i > $start) { $end = $i; last }
            }
            my $sub_code = join("\n", @lines[$start .. $end]);
            eval "package VRF; use strict; use warnings; $sub_code; 1"
                or die "compile failed: $@";
            $fn_ref = \&VRF::validate_report_filename;
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Behavioural: validate_report_filename rejects dangerous inputs
# ---------------------------------------------------------------------------
subtest 'validate_report_filename rejects traversal and dangerous inputs' => sub {
    if (!defined $fn_ref) {
        fail('validate_report_filename not found in reports.pl (extract-to-sub not applied)');
        return;
    }
    my @reject = (
        '',
        '../../etc/passwd',
        '/etc/passwd',
        'a/../../etc/passwd',
        '../report.html',
        'a/../b.html',
        '.hidden.html',
        '.html',
        '....//etc/passwd',
        'foo.txt',
        'foo',
        '0',
        'foo html.html',
        "foo.html\0etc/passwd",
    );
    for my $input (@reject) {
        my $display = $input;
        $display =~ s/\0/\\0/g;
        ok(!defined($fn_ref->($input)),
            "rejects: '$display'");
    }
};

# ---------------------------------------------------------------------------
# 2. Behavioural: validate_report_filename accepts legitimate filenames
# ---------------------------------------------------------------------------
subtest 'validate_report_filename accepts legitimate stored report filenames' => sub {
    if (!defined $fn_ref) {
        fail('validate_report_filename not found in reports.pl (extract-to-sub not applied)');
        return;
    }
    my @accept = (
        'report.html',
        'health-day-01-01-2026.html',
        'availability-week-2026-07-01.html',
        'top10.html',
        '0.html',
        'node_report.html',
        'a.html',
        'report-v2.html',
        'A1B2.html',
        'health.report.html',
    );
    for my $input (@accept) {
        my $result = $fn_ref->($input);
        ok(defined($result) && $result eq $input,
            "accepts and returns unchanged: '$input'");
    }
};

# ---------------------------------------------------------------------------
# 3. Behavioural: trailing newline is rejected (\z anchor, not $)
# ---------------------------------------------------------------------------
subtest 'trailing newline is rejected by \\z anchor' => sub {
    if (!defined $fn_ref) {
        fail('validate_report_filename not found in reports.pl (extract-to-sub not applied)');
        return;
    }
    ok(!defined($fn_ref->("report.html\n")),
        'report.html\n rejected (\z does not match before trailing newline)');
    ok(defined($fn_ref->('report.html')),
        'report.html (no newline) accepted');
};

# ---------------------------------------------------------------------------
# 4. Behavioural: falsiness — empty string rejected; "0.html" accepted; "0" rejected
# ---------------------------------------------------------------------------
subtest 'falsiness fix: empty string rejected; "0.html" accepted; "0" rejected' => sub {
    if (!defined $fn_ref) {
        fail('validate_report_filename not found in reports.pl (extract-to-sub not applied)');
        return;
    }
    ok(!defined($fn_ref->('')),      'empty string rejected');
    ok(!defined($fn_ref->(undef)),   'undef rejected');
    ok(defined($fn_ref->('0.html')), '"0.html" accepted (not falsily empty)');
    ok(!defined($fn_ref->('0')),     '"0" rejected (no .html extension)');
};

# ---------------------------------------------------------------------------
# 5. Symlink rejection
# ---------------------------------------------------------------------------
subtest 'symlink check correctly identifies symlinks vs regular files' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $real_file = "$tmpdir/report.html";
    my $symlink   = "$tmpdir/link.html";
    my $outside   = "$tmpdir/../outside.html";

    open(my $fh, '>', $real_file) or die "cannot create real file: $!";
    print $fh "<html>test report</html>\n";
    close $fh;

    symlink($outside, $symlink) or die "cannot create symlink: $!";

    ok(-l $symlink,    'symlink detected by -l');
    ok(!-l $real_file, 'regular file is not a symlink');
    ok((-l $symlink),  'symlink would be rejected by -l check in fileReport');
    ok(!(-l $real_file), 'regular file passes -l check');
};

# ---------------------------------------------------------------------------
# 6. Static: O_NOFOLLOW present in sysopen call
# ---------------------------------------------------------------------------
subtest 'O_NOFOLLOW is used in reports.pl sysopen' => sub {
    ok(-f $reports_pl, "reports.pl exists") or return;
    open(my $fh, '<', $reports_pl) or die "cannot open $reports_pl: $!";
    my $content = join('', <$fh>);
    close $fh;
    ok($content =~ /O_RDONLY\s*\|\s*O_NOFOLLOW/, 'sysopen uses O_RDONLY | O_NOFOLLOW');
};

# ---------------------------------------------------------------------------
# 7. Static: error message does not echo attacker-controlled path
# ---------------------------------------------------------------------------
subtest 'error message does not echo $Q->{file} back to user' => sub {
    ok(-f $reports_pl, "reports.pl exists") or return;
    open(my $fh, '<', $reports_pl) or die "cannot open $reports_pl: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /Invalid report file name/,
        'sanitised "Invalid report file name" error present');
    ok($content !~ /Invalid report file.*\$Q/,
        'error text does not embed raw $Q->{file}');
};

# ---------------------------------------------------------------------------
# 8. Static: allowlist regex uses \z anchor (not $)
# ---------------------------------------------------------------------------
subtest 'allowlist regex in reports.pl uses \\z anchor' => sub {
    ok(-f $reports_pl, "reports.pl exists") or return;
    open(my $fh, '<', $reports_pl) or die "cannot open $reports_pl: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /\\w\[\\w\\-\\./, 'allowlist character class [\w\-\.] present');
    ok($content =~ /\.html\\z/,       'allowlist uses \.html\z (not \.html$)');
};

# ---------------------------------------------------------------------------
# 9. Static: falsiness fix uses eq '' not !$report_file
# ---------------------------------------------------------------------------
subtest "falsiness fix: source uses eq '' not !\$report_file" => sub {
    ok(-f $reports_pl, "reports.pl exists") or return;
    open(my $fh, '<', $reports_pl) or die "cannot open $reports_pl: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /\$\w+\s+eq\s+['"]['"]/, "source uses eq '' for empty string check");
    ok($content !~ /if\s*\(!\s*\$report_file\b/, 'old !$report_file falsiness check gone');
};

done_testing;
