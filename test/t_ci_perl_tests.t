#!/usr/bin/perl
#
# Tests for OMK-12829: ci/scripts/perl_tests.sh must run every entry in
# working_tests even when one fails, then exit non-zero naming the failures.
#
# Before the fix the loop ran under "set -e", so the first failing prove
# aborted the script and every later entry silently never ran. A test late in
# the list was therefore only conditionally executed, and for the security
# regression guards added by the OMK-12644 epic a test that did not run looks
# identical to a test that passed.
#
# Runs without a live NMIS server, MongoDB or root privileges.
#
# Covers:
#   1. A green run executes every entry and exits 0.
#   2. A failure in the FIRST entry still runs every later entry.
#   3. The exit status is non-zero when any entry fails.
#   4. The summary names every failing entry, and only those.
#   5. A missing test file (the merge=union stale-filename hazard described in
#      .gitattributes) is reported as a failure rather than passing silently.
#   6. Static: prove's failure is collected rather than aborting the loop.
#   7. Static: the script ends with "exit $status", not an unconditional exit 0.
#   8. Static: the NMIS_HOME / PROVE / YES overrides still default to the CI
#      container's real paths, so adding the test hooks did not change what CI
#      actually executes.
#
# Subtests 1-5 drive the real shipped ci/scripts/perl_tests.sh through its
# NMIS_HOME / PROVE / YES overrides with a stub prove, so they exercise the
# file CI runs rather than a reimplementation of its loop.
#
# Note on recursion: this test appears in working_tests, so the inner run
# iterates over its own filename too. That is harmless. The stub prove never
# executes anything, it only records the path it was handed and returns a
# chosen status, so the inner run cannot re-enter this test.

use strict;
use warnings;

use FindBin;
use File::Temp qw(tempdir);
use Test::More;

my $script = "$FindBin::Bin/../ci/scripts/perl_tests.sh";

if (!-f $script) {
    plan skip_all => "$script not found";
}

my $content = do {
    open(my $fh, '<', $script) or die "cannot open $script: $!";
    local $/;
    <$fh>;
};

# source with comments removed, so assertions do not trip over a comment that
# merely mentions the construct being checked
my $code_only = join("\n", grep { !/^\s*#/ } split(/\n/, $content));

# ---------------------------------------------------------------------------
# Read working_tests out of the real script, so this test stays correct as
# entries are appended (which merge=union guarantees will keep happening).
# ---------------------------------------------------------------------------
my @entries;
if ($content =~ /^working_tests=\(\s*\n(.*?)^\)/ms) {
    for my $line (split(/\n/, $1)) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next if !length $line;
        next if $line =~ /^#/;
        push @entries, $line;
    }
}

if (!@entries) {
    plan skip_all => 'could not parse working_tests out of perl_tests.sh';
}

my $tmpdir = tempdir(CLEANUP => 1);
my $bindir = "$tmpdir/bin";
mkdir $bindir or die "mkdir $bindir: $!";

# ---------------------------------------------------------------------------
# Stub prove. Records the path it was given, then mimics just enough of real
# prove: a nonexistent file is an error, a file named in FAIL_TESTS fails, and
# anything else passes. It never runs the file.
# ---------------------------------------------------------------------------
write_exec("$bindir/prove", <<'STUB');
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$RUNLOG"
[ -f "$1" ] || exit 2
base="${1##*/}"
for f in $FAIL_TESTS; do
    if [ "$f" = "$base" ]; then
        exit 1
    fi
done
exit 0
STUB

write_exec("$bindir/yes", <<'STUB');
#!/usr/bin/env bash
exit 0
STUB

# ---------------------------------------------------------------------------
# 1. A green run executes every entry and exits 0
# ---------------------------------------------------------------------------
subtest 'green run executes every entry and exits 0' => sub {
    my $home = build_home(tag => 'green');
    my $r    = run_script(tag => 'green', home => $home);

    is($r->{rc}, 0, 'exit status is 0 when every entry passes');
    is(scalar @{ $r->{ran} }, scalar @entries,
        'prove was invoked once per working_tests entry');
    is_deeply($r->{ran}, \@entries, 'every entry ran, in list order');
    unlike($r->{out}, qr/FAILED/, 'no failure summary on a green run');
};

# ---------------------------------------------------------------------------
# 2 + 3. A failure in the FIRST entry must not hide the rest
#
# This is the regression pin. On the pre-fix script the run stopped after the
# first entry, so @ran had one element and the exit status came from prove.
# ---------------------------------------------------------------------------
subtest 'failure in the first entry still runs every later entry' => sub {
    my $first = $entries[0];
    my $home  = build_home(tag => 'first');
    my $r     = run_script(tag => 'first', home => $home, fail => [$first]);

    is(scalar @{ $r->{ran} }, scalar @entries,
        "every entry still ran after '$first' failed");
    is_deeply($r->{ran}, \@entries, 'no entry was skipped');
    isnt($r->{rc}, 0, 'exit status is non-zero when an entry fails');
    like($r->{out}, qr/\Q$first\E/, "summary names the failing entry '$first'");
};

# ---------------------------------------------------------------------------
# 4. The summary names every failing entry, and only those
# ---------------------------------------------------------------------------
subtest 'summary names every failing entry and only those' => sub {
    plan skip_all => 'needs at least 3 entries to be meaningful'
        if @entries < 3;

    my @fail = ($entries[0], $entries[-1]);
    my $pass = $entries[1];
    my $home = build_home(tag => 'multi');
    my $r    = run_script(tag => 'multi', home => $home, fail => \@fail);

    isnt($r->{rc}, 0, 'exit status is non-zero');
    is(scalar @{ $r->{ran} }, scalar @entries, 'every entry ran');

    for my $f (@fail) {
        like($r->{out}, qr/\Q$f\E/, "summary names failing entry '$f'");
    }
    unlike($r->{out}, qr/\Q$pass\E/,
        "summary does not name the passing entry '$pass'");
};

# ---------------------------------------------------------------------------
# 5. A missing test file fails the build rather than passing silently
#
# .gitattributes marks this script merge=union, which can leave a stale
# filename in the array after a rename lands on two branches. That is only
# acceptable because a stale filename fails loudly. Pin that.
# ---------------------------------------------------------------------------
subtest 'a stale filename in working_tests fails the build' => sub {
    my $stale = $entries[0];
    my $home  = build_home(tag => 'stale', omit => [$stale]);

    ok(!-f "$home/test/$stale", "test file '$stale' is absent, as intended");

    my $r = run_script(tag => 'stale', home => $home);

    isnt($r->{rc}, 0, 'a missing test file makes the run fail');
    like($r->{out}, qr/\Q$stale\E/, 'summary names the missing entry');
    is(scalar @{ $r->{ran} }, scalar @entries,
        'the missing entry does not stop the later ones');
};

# ---------------------------------------------------------------------------
# 6 + 7. Static: the collect-and-exit shape
# ---------------------------------------------------------------------------
subtest 'static: prove failure is collected, and the status is returned' => sub {
    like($code_only, qr/\bif\s*!/,
        'prove runs under "if !", so its failure does not abort the loop');
    like($code_only, qr/failed\+=\(/, 'failing entries are recorded');
    like($code_only, qr/^\s*exit\s+"?\$\{?status\}?"?\s*$/m,
        'script exits with the collected status');
    unlike($code_only, qr/^\s*exit\s+0\s*$/m,
        'no unconditional "exit 0" that would green a failing run');
};

# ---------------------------------------------------------------------------
# 8. Static: the overrides did not change what CI runs
# ---------------------------------------------------------------------------
subtest 'static: test hooks default to the real CI paths' => sub {
    like($content, qr/NMIS_HOME:-\/usr\/local\/nmis9/,
        'NMIS_HOME defaults to /usr/local/nmis9');
    like($content, qr/PROVE:-\/usr\/bin\/prove/,
        'PROVE defaults to /usr/bin/prove');
    like($content, qr/YES:-\/usr\/bin\/yes/,
        'YES defaults to /usr/bin/yes');
};

done_testing();

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

sub write_exec {
    my ($path, $body) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print $fh $body;
    close $fh;
    chmod 0755, $path or die "cannot chmod $path: $!";
    return;
}

# Build a throwaway NMIS_HOME containing a stub test file for each entry in
# working_tests. Anything in omit is deliberately left absent.
sub build_home {
    my (%opt) = @_;
    my %omit = map { $_ => 1 } @{ $opt{omit} || [] };

    my $home = "$tmpdir/home.$opt{tag}";
    mkdir $home         or die "mkdir $home: $!";
    mkdir "$home/test"  or die "mkdir $home/test: $!";

    for my $entry (@entries) {
        next if $omit{$entry};
        open(my $fh, '>', "$home/test/$entry")
            or die "cannot write $home/test/$entry: $!";
        print $fh "1..1\nok 1\n";
        close $fh;
    }
    return $home;
}

# Run the real perl_tests.sh with the stubs in place. Returns the exit status,
# the ordered list of test basenames prove was handed, and the merged output.
sub run_script {
    my (%opt) = @_;
    my $tag    = $opt{tag};
    my $runlog = "$tmpdir/runlog.$tag";
    my $outf   = "$tmpdir/out.$tag";

    open(my $t, '>', $runlog) or die "cannot create $runlog: $!";
    close $t;

    my $pid = fork();
    die "fork failed: $!" if !defined $pid;

    if (!$pid) {
        $ENV{NMIS_HOME}  = $opt{home};
        $ENV{PROVE}      = "$bindir/prove";
        $ENV{YES}        = "$bindir/yes";
        $ENV{RUNLOG}     = $runlog;
        $ENV{FAIL_TESTS} = join(' ', @{ $opt{fail} || [] });
        open(STDOUT, '>',  $outf)     or exit 127;
        open(STDERR, '>&', \*STDOUT)  or exit 127;
        exec('bash', $script);
        exit 127;
    }

    waitpid($pid, 0);
    my $rc = $? >> 8;

    my @ran;
    if (open(my $fh, '<', $runlog)) {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s{.*/}{};
            push @ran, $line if length $line;
        }
        close $fh;
    }

    my $out = '';
    if (open(my $fh, '<', $outf)) {
        local $/;
        $out = <$fh>;
        close $fh;
    }

    return { rc => $rc, ran => \@ran, out => defined $out ? $out : '' };
}
