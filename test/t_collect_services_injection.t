#!/usr/bin/perl
#
# Tests for OMK-12692: shell injection fix in collect_services (CWE-78)
#
# Verifies the fix properties without needing a live NMIS server or MongoDB.
# Does NOT invoke collect_services directly (requires MongoDB); instead:
#   1. Static checks: old injection-enabling patterns gone, new safe patterns present.
#   2. Unit test: metacharacter sanitisation regex.
#   3. Static check: script branch uses three-argument open with basename allowlist.
#   4. Mock binary tests: injection via Args/host does not create a sidecar file.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use POSIX qw();

use NMISNG::Util;

my $node_pm = "$FindBin::Bin/../lib/NMISNG/Node.pm";

# ---------------------------------------------------------------------------
# 1. Old string-interpolated piped opens must be gone
# ---------------------------------------------------------------------------
subtest 'old string-form nmap and program opens are gone' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>;
    close $fh;

    my @bad_nmap = grep { /open\s*\(\s*NMAP\s*,\s*"\s*\$nmap/ } @lines;
    is(scalar(@bad_nmap), 0, 'no old interpolating NMAP open');

    my @bad_prg  = grep { /open\s*\(\s*PRG\s*,\s*"\s*\$svc/ } @lines;
    is(scalar(@bad_prg), 0, 'no old interpolating PRG open');

    my @str_nmap = grep { /open\s*\(\s*NMAP\s*,\s*[^'-]/ && /\|"/ } @lines;
    is(scalar(@str_nmap), 0, 'no string-interpolated NMAP pipe');

    my @str_prg  = grep { /open\s*\(\s*PRG\s*,\s*[^'-]/ && /\|"/ } @lines;
    is(scalar(@str_prg), 0, 'no string-interpolated PRG pipe');
};

# ---------------------------------------------------------------------------
# 2. New safe patterns are present
# ---------------------------------------------------------------------------
subtest 'list-form fork+exec patterns are present' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /open\s*\(\s*NMAP\s*,\s*['"]-\|['"]/,
        "NMAP uses fork+pipe open(NMAP, '-|')");
    ok($content =~ /open\s*\(\s*PRG\s*,\s*['"]-\|['"]/,
        "PRG uses fork+pipe open(PRG, '-|')");
    ok($content =~ /exec\s*[\(\{]\s*['"]nmap['"]/,
        "nmap exec passes list (or block form) to exec");
};

# ---------------------------------------------------------------------------
# 3. Script branch uses three-argument open with basename allowlist
# ---------------------------------------------------------------------------
subtest 'script branch uses three-argument open and validates basename' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>;
    close $fh;

    # Old pattern: open(F, $scriptfn) — magic open, two-argument
    my @old = grep { /open\s*\(\s*F\s*,\s*\$scriptfn\s*\)/ } @lines;
    is(scalar(@old), 0, 'old two-argument script open(F, $scriptfn) is gone');

    # New pattern: three-argument open
    my @new = grep { /open\s*\(.*'<'.*\$scriptfn/ || /open\s*\(.*"<".*\$scriptfn/ } @lines;
    ok(scalar(@new) > 0, 'three-argument open(<, $scriptfn) is present');
};

subtest 'script branch delegates the basename check to the shared predicate' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my $content = join('', <$fh>);
    close $fh;

    # Structural, and labelled as such: it says who owns the rule, not that the
    # rule is correct. Correctness is subtest 6, which calls the predicate.
    ok($content =~ /NMISNG::Util::is_safe_script_basename/,
        'Node.pm calls NMISNG::Util::is_safe_script_basename');
};

# ---------------------------------------------------------------------------
# 4. Metacharacter sanitisation unit tests
# ---------------------------------------------------------------------------
subtest 'metacharacter sanitisation strips shell-dangerous chars' => sub {
    # Calls the shipped sanitiser. Never re-implement it here: a local copy
    # would keep passing after the real one changed, and report coverage of
    # logic that no longer exists.
    my @cases = (
        [ 'localhost',             'localhost',        'clean hostname unchanged' ],
        [ '192.168.1.1',          '192.168.1.1',      'IP address unchanged' ],
        [ 'host; touch /tmp/x',   'host touch /tmp/x','semicolon stripped' ],
        [ '`whoami`',             'whoami',            'backticks stripped' ],
        [ '$(id)',                 'id',               'dollar and parens both stripped' ],
        [ "host\nrm -rf /",       'hostrm -rf /',     'newline stripped (no space inserted)' ],
        [ "host\rrm -rf /",       'hostrm -rf /',     'CR stripped (no space inserted)' ],
        [ "host' --flag",          'host --flag',      'single quote stripped' ],
        [ 'host" --flag',          'host --flag',      'double quote stripped' ],
        [ 'host|cat /etc/passwd', 'hostcat /etc/passwd', 'pipe stripped' ],
        [ 'host&&id',             'hostid',            'ampersand stripped' ],
        [ 'host<input',           'hostinput',         'less-than stripped' ],
        [ 'host>output',          'hostoutput',        'greater-than stripped' ],
        [ 'host\\extra',          'hostextra',         'backslash stripped' ],
        [ undef,                  '',                  'undef treated as empty' ],
    );
    for my $tc (@cases) {
        my ($input, $expected, $desc) = @$tc;
        is(NMISNG::Util::strip_shell_metachars($input), $expected, $desc);
    }
};

# ---------------------------------------------------------------------------
# 5. Script basename allowlist unit tests
# ---------------------------------------------------------------------------
subtest 'script basename allowlist accepts safe names, rejects dangerous ones' => sub {
    # Calls the shipped predicate rather than a copy of its regex.

    my @accept = (
        'check_disk',
        'nagios_plugin',
        'my-script',
        'script.v2',
        'A1B2.pl',
    );
    for my $name (@accept) {
        ok(NMISNG::Util::is_safe_script_basename($name), "accepts safe name: '$name'");
    }

    my @reject = (
        '',
        '../etc/shadow',
        '/etc/passwd',
        'script|rm',
        "script\n",
        'script name',   # space
        'script;id',
        'script`',
        'script$HOME',
        '| cat /etc/passwd',
    );
    for my $name (@reject) {
        my $display = $name;
        $display =~ s/\n/\\n/g;
        ok(!NMISNG::Util::is_safe_script_basename($name),
            "rejects dangerous name: '$display'");
    }
};

# ---------------------------------------------------------------------------
# 6. Behavioural: _exec_service_program extracted from Node.pm.
#
# Block-form exec { $program } prevents shell interpretation of a
# metachar-containing binary name.  On the pre-fix base _exec_service_program
# does not exist, so extraction fails and this subtest goes red.  On the
# fixed head the sub is found, evaled, and called in a forked child with a
# binary name containing "; touch <sidecar>"; block-form exec treats the
# whole string as the binary path (not found → _exit(127)), so the sidecar
# is never created.
# ---------------------------------------------------------------------------
subtest 'program path: block-form exec in _exec_service_program prevents shell interpretation' => sub {
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>; close $fh;

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub _exec_service_program\b/) { $start = $i; last }
    }
    ok(defined $start, '_exec_service_program found in Node.pm (absent on pre-fix base)') or return;

    my ($depth, $end) = (0, $start);
    for my $i ($start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $start) { $end = $i; last }
    }
    my $sub_code = join('', @lines[$start .. $end]);
    eval "package _ESP; use POSIX; no warnings; $sub_code; 1" or do {
        fail("could not eval _exec_service_program: $@"); return;
    };

    my $tmpdir = tempdir(CLEANUP => 1);
    my $inject = "$tmpdir/INJECTED_$$";
    my $evil   = "/bin/true;touch $inject";    # empty @arglist triggers single-arg exec path

    my $pid = fork();
    if (!defined $pid) { fail("fork: $!"); return }
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null') or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null') or POSIX::_exit(1);
        _ESP::_exec_service_program($evil);    # real Node.pm code
        POSIX::_exit(1);
    }
    waitpid($pid, 0);
    ok(!-e $inject,
        'block-form exec: semicolon in binary name not shell-interpreted (real _exec_service_program called)');
};

# ---------------------------------------------------------------------------
# 7. Behavioural: _exec_nmap_child extracted from Node.pm.
#
# Host with shell metacharacters is passed as a single argv element, not
# shell-interpreted.  On the pre-fix base _exec_nmap_child does not exist,
# so extraction fails and this subtest goes red.  On the fixed head the sub
# is found, evaled, and called in a forked child with a mock 'nmap' on PATH;
# the mock records its argv.  The host "localhost; touch <sidecar>" must
# appear as one recorded argv element and the sidecar must not be created.
# ---------------------------------------------------------------------------
subtest 'nmap path: _exec_nmap_child passes host as single argv element' => sub {
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>; close $fh;

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub _exec_nmap_child\b/) { $start = $i; last }
    }
    ok(defined $start, '_exec_nmap_child found in Node.pm (absent on pre-fix base)') or return;

    my ($depth, $end) = (0, $start);
    for my $i ($start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $start) { $end = $i; last }
    }
    my $sub_code = join('', @lines[$start .. $end]);
    eval "package _ENC; use POSIX; no warnings; $sub_code; 1" or do {
        fail("could not eval _exec_nmap_child: $@"); return;
    };

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $inject   = "$tmpdir/INJECTED_NMAP_$$";
    my $argv_log = "$tmpdir/nmap_argv.txt";

    my $mock_nmap = "$tmpdir/nmap";
    open(my $mh, '>', $mock_nmap) or die "cannot write mock nmap: $!";
    print $mh "#!/bin/sh\nprintf '%s\n' \"\$@\" > '$argv_log'\nexit 0\n";
    close $mh;
    chmod 0755, $mock_nmap;

    local $ENV{PATH} = "$tmpdir:$ENV{PATH}";

    my $inject_host = "localhost; touch $inject";    # unsanitised — shell interpretation would create sidecar
    my @nmap_args   = ('-sT', '-p', '80', '-oG', '-', $inject_host);

    my $pid = open(my $pipe, '-|');
    if (!defined $pid) { fail("fork: $!"); return }
    if ($pid == 0) {
        _ENC::_exec_nmap_child(@nmap_args);    # real Node.pm code
        POSIX::_exit(1);
    }
    1 while <$pipe>;
    close $pipe;

    ok(!-e $inject,
        'nmap: semicolon in host not shell-interpreted (real _exec_nmap_child called)');
    if (-f $argv_log) {
        open(my $af, '<', $argv_log) or die "cannot read argv log: $!";
        my $recorded = join('', <$af>); close $af;
        like($recorded, qr/localhost; touch/,
            'host with semicolon passed intact as single nmap argv element');
    }
};

# ---------------------------------------------------------------------------
# 8. Structural: the sanitiser and the allowlist exist in exactly one place.
#    This is the guard against the anti-pattern this file used to contain: a
#    hand-typed copy of security logic, which keeps passing after the original
#    changes and so reports coverage that does not exist. It asserts where the
#    logic lives, never that it is correct; correctness is subtests 5 and 6,
#    which call the shipped functions.
# ---------------------------------------------------------------------------
subtest 'shell sanitiser and basename allowlist are defined exactly once' => sub {
    my $lib = "$FindBin::Bin/../lib";
    my $util = "$lib/NMISNG/Util.pm";
    ok(-f $util, 'Util.pm exists') or return;

    # The literal character class, and the allowlist, may appear only in Util.pm.
    my @offenders;
    my @files;
    my @dirs = ($lib, "$FindBin::Bin");
    while (my $d = shift @dirs) {
        opendir(my $dh, $d) or next;
        for my $e (grep { !/^\.\.?$/ } readdir $dh) {
            my $path = "$d/$e";
            if (-d $path) { push @dirs, $path }
            elsif ($path =~ /\.(pm|pl|t)$/) { push @files, $path }
        }
        closedir $dh;
    }
    for my $f (@files) {
        next if ($f eq $util);
        open(my $fh, '<', $f) or next;
        my $c = join('', <$fh>);
        close $fh;
        push @offenders, "$f (metachar class)"
            if ($c =~ /\Q[`\E\\?\$\|;&<>\(\)/);
        push @offenders, "$f (basename allowlist)"
            if ($c =~ /\QA-Za-z0-9_.\E\\?-\]\+\\z/);
    }
    is(scalar(@offenders), 0, 'no second copy of the sanitiser or the allowlist')
        or diag("copies found in:\n  " . join("\n  ", @offenders));

    open(my $uh, '<', $util) or die "cannot open $util: $!";
    my $uc = join('', <$uh>);
    close $uh;
    ok($uc =~ /sub strip_shell_metachars/,   'Util.pm defines strip_shell_metachars');
    ok($uc =~ /sub is_safe_script_basename/, 'Util.pm defines is_safe_script_basename');

    # Every site that used to hold its own copy must still call the shared one.
    # Centralising removed the only thing pinning the nmap host line: deleting
    # that call leaves every behavioural subtest green, because subtest 8
    # deliberately asserts the host reaches _exec_nmap_child intact and so
    # cannot see the strip go missing.
    open(my $nh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my $nc = join('', <$nh>);
    close $nh;

    my @calls = ($nc =~ /NMISNG::Util::strip_shell_metachars/g);
    is(scalar(@calls), 2,
        'Node.pm calls strip_shell_metachars at both sites (argv build, nmap host)');
    ok($nc =~ /strip_shell_metachars\(\s*\$catchall_data->\{host\}/,
        'nmap host is sanitised via the shared function');
};

# ---------------------------------------------------------------------------
# 9. Behavioural: _build_service_argv extracted from Node.pm.
#
# Drives the real node.* substitution + shellwords path without MongoDB.
# Extracts the sub from source, evals it, then:
#   a. asserts the returned argv for clean and metachar-containing inputs;
#   b. forks a mock binary via the real _exec_service_program to prove the
#      argv built by _build_service_argv reaches exec() intact.
# On the pre-fix base _build_service_argv does not exist, so extraction
# fails and this subtest goes red.  Mutating @arglist = () in production
# also breaks assertion (b) because the mock binary records no argv.
# ---------------------------------------------------------------------------
subtest 'arg-building: _build_service_argv substitutes node.* and passes argv to exec' => sub {
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>; close $fh;

    # Extract _build_service_argv
    my $bsa_start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub _build_service_argv\b/) { $bsa_start = $i; last }
    }
    ok(defined $bsa_start, '_build_service_argv found in Node.pm') or return;
    my ($depth, $end) = (0, $bsa_start);
    for my $i ($bsa_start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $bsa_start) { $end = $i; last }
    }
    my $bsa_code = join('', @lines[$bsa_start .. $end]);
    eval "package _BSA; use Text::ParseWords qw(shellwords); no warnings; $bsa_code; 1" or do {
        fail("could not eval _build_service_argv: $@"); return;
    };

    # (a) Unit assertions on the extracted helper
    my @argv1 = _BSA::_build_service_argv('--host node.host --name node.sysName',
        {host => '10.0.0.1', sysName => 'myrouter'});
    is_deeply(\@argv1, ['--host', '10.0.0.1', '--name', 'myrouter'],
        'clean node.* substitution produces correct argv');

    my @argv2 = _BSA::_build_service_argv('--host node.host',
        {host => '10.0.0.1; touch /tmp/x'});
    is(scalar(@argv2) > 0, 1, 'metachar-stripped input returns non-empty argv');
    unlike($argv2[1] // '', qr/;/, 'semicolon stripped from substituted host');

    my @argv3 = _BSA::_build_service_argv(undef, {});
    is_deeply(\@argv3, [], 'undef Args returns empty argv');

    # (b) End-to-end: argv from _build_service_argv reaches exec via _exec_service_program
    my $esp_start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub _exec_service_program\b/) { $esp_start = $i; last }
    }
    ok(defined $esp_start, '_exec_service_program found in Node.pm') or return;
    my ($d2, $e2) = (0, $esp_start);
    for my $i ($esp_start .. $#lines) {
        $d2 += () = $lines[$i] =~ /\{/g;
        $d2 -= () = $lines[$i] =~ /\}/g;
        if ($d2 == 0 && $i > $esp_start) { $e2 = $i; last }
    }
    my $esp_code = join('', @lines[$esp_start .. $e2]);
    eval "package _BSA; use POSIX; no warnings; $esp_code; 1" or do {
        fail("could not eval _exec_service_program: $@"); return;
    };

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";
    my $mock_bin = "$tmpdir/check_mock";
    open(my $mh, '>', $mock_bin) or die "cannot write mock: $!";
    print $mh "#!/bin/sh\nprintf '%s\n' \"\$@\" > '$argv_log'\nexit 0\n";
    close $mh; chmod 0755, $mock_bin;

    my @build_argv = _BSA::_build_service_argv('--host node.host', {host => '192.0.2.1'});
    my $pid = fork();
    if (!defined $pid) { fail("fork: $!"); return }
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null') or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null') or POSIX::_exit(1);
        _BSA::_exec_service_program($mock_bin, @build_argv);
        POSIX::_exit(1);
    }
    waitpid($pid, 0);
    if (-f $argv_log) {
        open(my $af, '<', $argv_log) or die;
        my $recorded = join('', <$af>); close $af;
        like($recorded, qr/--host/, 'argv flag from _build_service_argv reached exec');
        like($recorded, qr/192\.0\.2\.1/, 'node.host value from _build_service_argv reached exec');
    } else {
        fail('mock binary did not record argv — exec may not have been reached');
    }
};

# ---------------------------------------------------------------------------
# 10. Behavioural: _run_service_program wires _build_service_argv to exec.
#
# Drives the production runner that collect_services calls in the child.
# Mutating _build_service_argv inside _run_service_program (e.g. @arglist=())
# leaves the mock binary with no argv and this subtest goes red.
# Also verifies that whitespace in a device value does not inject an extra
# argv element (Important 1: tokenise-first approach).
# ---------------------------------------------------------------------------
subtest 'runner: _run_service_program wires arg-building to exec' => sub {
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>; close $fh;

    # Extract _exec_service_program, _build_service_argv, _run_service_program
    for my $name (qw(_exec_service_program _build_service_argv _run_service_program)) {
        my $start;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^sub \Q$name\E\b/) { $start = $i; last }
        }
        ok(defined $start, "$name found in Node.pm") or return;
        my ($depth, $end) = (0, $start);
        for my $i ($start .. $#lines) {
            $depth += () = $lines[$i] =~ /\{/g;
            $depth -= () = $lines[$i] =~ /\}/g;
            if ($depth == 0 && $i > $start) { $end = $i; last }
        }
        my $code = join('', @lines[$start .. $end]);
        eval "package _RSP; use Text::ParseWords qw(shellwords); use POSIX; no warnings; $code; 1"
            or do { fail("could not eval $name: $@"); return };
    }

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";
    my $mock_bin = "$tmpdir/check_rsp";
    open(my $mh, '>', $mock_bin) or die "cannot write mock: $!";
    print $mh "#!/bin/sh\nprintf '%s\\n' \"\$\@\" > '$argv_log'\nexit 0\n";
    close $mh; chmod 0755, $mock_bin;

    # (a) argv from _build_service_argv reaches exec via _run_service_program
    my $pid = fork();
    if (!defined $pid) { fail("fork: $!"); return }
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null') or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null') or POSIX::_exit(1);
        _RSP::_run_service_program($mock_bin, '--host node.host', {host => '192.0.2.1'});
        POSIX::_exit(1);
    }
    waitpid($pid, 0);
    if (-f $argv_log) {
        open(my $af, '<', $argv_log) or die;
        my $recorded = join('', <$af>); close $af;
        like($recorded, qr/--host/,      'argv flag reached exec via _run_service_program');
        like($recorded, qr/192\.0\.2\.1/,'node.host value reached exec via _run_service_program');
    } else {
        fail('mock binary did not record argv — _build_service_argv may have been bypassed');
    }

    # (b) Whitespace in device value does not inject an extra argv element
    unlink $argv_log;
    my $pid2 = fork();
    if (!defined $pid2) { fail("fork: $!"); return }
    if ($pid2 == 0) {
        open(STDIN,  '<', '/dev/null') or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null') or POSIX::_exit(1);
        _RSP::_run_service_program($mock_bin,
            '--file=node.sysDescr',
            {sysDescr => 'x --output=/tmp/injected'});
        POSIX::_exit(1);
    }
    waitpid($pid2, 0);
    if (-f $argv_log) {
        open(my $af2, '<', $argv_log) or die;
        my @args = <$af2>; close $af2;
        chomp @args;
        is(scalar(@args), 1, 'whitespace in device value does not inject extra argv element');
        ok(!grep { /^--output/ } @args, 'injected option not present as separate argv element');
    } else {
        fail('mock binary did not record argv for injection test');
    }
};

# ---------------------------------------------------------------------------
# 11. Static: both exec calls use block form exec { $prog } $prog, @args
#    (prevents single-element list exec falling back to /bin/sh for
#    metachar-named binaries)
# ---------------------------------------------------------------------------
subtest 'exec calls use block form to prevent shell fallback' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content =~ /exec\s*\{\s*['"]nmap['"]\s*\}\s*['"]nmap['"]/,
        "nmap exec uses block form exec { 'nmap' } 'nmap', ...");
    ok($content =~ /exec\s*\{\s*\$program\s*\}/,
        "program exec uses block form exec { \$program } ... (in _exec_service_program)");
};

# ---------------------------------------------------------------------------
# 12. Static: ext_ping uses fork+exec, not two-arg piped open
#
# The old open(PING, "$ping{$kernel} $redirect_stderr |") interpolated
# device-derived $host through /bin/sh (CWE-78).  The fix splits the
# per-OS command template into an argv list, forks, and execs directly.
# Also verifies that alarm($remaining) appears on BOTH the timeout return
# path and the normal close/return path so the caller's alarm is always
# restored.
# ---------------------------------------------------------------------------
subtest 'ext_ping: fork+exec replaces two-arg piped open, alarm restored on both paths' => sub {
    ok(-f $node_pm, 'Node.pm exists') or return;
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>;
    close $fh;

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub ext_ping\b/) { $start = $i; last }
    }
    ok(defined $start, 'ext_ping found in Node.pm') or return;

    my ($depth, $end) = (0, $start);
    for my $i ($start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $start) { $end = $i; last }
    }
    my @body = @lines[$start .. $end];
    my $body  = join('', @body);

    # Old two-arg piped open must be gone
    my @old_open = grep { /open\s*\(\s*PING\s*,/ } @body;
    is(scalar(@old_open), 0, 'old two-arg open(PING,...) not present in ext_ping');

    # New pattern: split command into argv, fork, exec
    ok($body =~ /split\s*\(.*\$ping\{\$kernel\}/, 'ext_ping splits ping{$kernel} into argv');
    ok($body =~ /\bfork\b/,                        'ext_ping calls fork()');
    ok($body =~ /\bexec\s*\{/,                     'ext_ping uses block-form exec');

    # alarm($remaining) must appear at least twice: once on the timeout
    # return path and once on the normal exit path
    my @alarm_restores = grep { /alarm\s*\(\s*\$remaining\s*\)/ } @body;
    ok(scalar(@alarm_restores) >= 2,
        'alarm($remaining) restored on both timeout and normal paths');
};

# ---------------------------------------------------------------------------
# 13. Arg-building: leading-dash node.* value does not inject an option flag
#
# Tokenise-first (round 4) prevents whitespace-split injection.  A standalone
# node.* placeholder can still substitute a value beginning with '-', turning
# the token into a bare option flag for the root-run program (CWE-88).
# The fix strips leading dashes from substituted values.
# ---------------------------------------------------------------------------
subtest 'arg-building: leading-dash node.* value does not inject a flag' => sub {
    open(my $fh, '<', $node_pm) or die "cannot open $node_pm: $!";
    my @lines = <$fh>; close $fh;

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub _build_service_argv\b/) { $start = $i; last }
    }
    ok(defined $start, '_build_service_argv found in Node.pm') or return;
    my ($depth, $end) = (0, $start);
    for my $i ($start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $start) { $end = $i; last }
    }
    my $code = join('', @lines[$start .. $end]);
    eval "package _LDBSA; use Text::ParseWords qw(shellwords); no warnings; $code; 1"
        or do { fail("could not eval _build_service_argv: $@"); return };

    # (a) standalone node.* placeholder: value starting with '-' must not
    #     produce a leading-dash argv element (the key CWE-88 vector)
    my @a = _LDBSA::_build_service_argv('node.host', {host => '-sV'});
    ok( !(grep { /^-/ } @a), 'standalone leading-dash value does not become option flag');

    # (b) embedded placeholder (--opt=node.host): leading-dash stripping must
    #     not produce a standalone element — value stays within the token
    my @b = _LDBSA::_build_service_argv('--host=node.host', {host => '--oX=/tmp/evil'});
    is(scalar(@b), 1, 'embedded leading-dash case still produces exactly one token');
    ok( !(grep { /^--oX/ } @b), 'embedded leading-dash value does not escape as standalone arg');

    # (c) verify the leading-dash strip is present in source
    ok($code =~ /s\s*\/\s*\^-/, 'leading-dash strip present in _build_service_argv source');
};

# --- Access.nmis: table_services_rw must be admin-only (OMK-12692 review) ---
subtest 'Access.nmis: table_services_rw level1 must be 0 (admin-only write)' => sub {
    my $access_file = "$FindBin::Bin/../conf-default/Access.nmis";
    open(my $fh, '<', $access_file) or do { skip "Cannot open $access_file: $!", 1; return };
    my $text = do { local $/; <$fh> };
    close $fh;

    my ($block) = ($text =~ /('table_services_rw'\s*=>\s*\{[^}]+\})/s);
    ok(defined $block, 'table_services_rw entry found in Access.nmis');
    like($block, qr/'level1'\s*=>\s*'0'/, "table_services_rw level1 => '0' (admin-only; services can execute scripts)");
};

done_testing;
