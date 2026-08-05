#!/usr/bin/perl
#
# Tests for OMK-12640: shell injection fix in admin/tests.pl act=snmp (CWE-78)
#
# Verifies the fix properties without needing an SNMP agent, a live NMIS server
# or MongoDB.  admin/tests.pl cannot be loaded (it runs work at load time and
# pulls in NMISNG), so the helpers are extracted from source and evaled:
#   1. Static checks: backtick/system/qx execution gone, list-form open present.
#   2. Behavioural: run_without_shell passes metacharacters as data, via a mock
#      binary on PATH that records its argv.
#   3. Behavioural: run_without_shell error and exit-status reporting.
#   4. Behavioural: snmp_target rejects hosts snmpget would read as options.
#   5. End-to-end: the v2c argv shape, with an apostrophe in the community,
#      reaches a mock snmpget intact.
#
# On the pre-fix base neither helper exists, so extraction fails and subtests
# 2-5 go red; the static checks in subtest 1 also fail on the backticks.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);

my $tests_pl = "$FindBin::Bin/../admin/tests.pl";

# ---------------------------------------------------------------------------
# Extracts a named sub from a script by brace counting, so the script itself
# is never loaded.  Returns the source text or undef.
# ---------------------------------------------------------------------------
sub extract_sub
{
    my ($path, $name) = @_;

    open(my $fh, '<', $path) or die "cannot open $path: $!";
    my @lines = <$fh>;
    close $fh;

    my $start;
    for my $i (0 .. $#lines)
    {
        if ($lines[$i] =~ /^sub \Q$name\E\b/) { $start = $i; last }
    }
    return undef if (!defined $start);

    my ($depth, $end) = (0, $start);
    for my $i ($start .. $#lines)
    {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $start) { $end = $i; last }
    }
    return join('', @lines[$start .. $end]);
}

sub slurp
{
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot open $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# writes an executable shell script that records its argv one-per-line
sub write_mock
{
    my ($path, $argv_log, $exit_code) = @_;
    $exit_code = 0 if (!defined $exit_code);

    open(my $mh, '>', $path) or die "cannot write mock $path: $!";
    print $mh "#!/bin/sh\nprintf '%s\\n' \"\$@\" > '$argv_log'\nexit $exit_code\n";
    close $mh;
    chmod 0755, $path;
    return $path;
}

# ---------------------------------------------------------------------------
# 1. Static checks on admin/tests.pl
# ---------------------------------------------------------------------------
subtest 'no shell execution remains in admin/tests.pl' => sub {
    ok(-f $tests_pl, 'admin/tests.pl exists') or return;
    my $text = slurp($tests_pl);

    unlike($text, qr/`\s*\$exe\s*`/, 'no backtick execution of $exe');
    unlike($text, qr/`[^`\n]*\$(?:exe|nodeconfig|target)/,
        'no backtick execution interpolating node-derived values');

    my @lines = split(/\n/, $text);
    my @qx     = grep { /(?<!\w)qx[\(\{\|\/]/ } @lines;
    is(scalar(@qx), 0, 'no qx// execution');

    my @system = grep { /(?<!\w)system\s*\(/ } @lines;
    is(scalar(@system), 0, 'no system() call');

    # any remaining backticks at all in the file
    my @backticks = grep { /`/ } @lines;
    is(scalar(@backticks), 0, 'no backticks anywhere in the script');
};

subtest 'list-form exec helper is present' => sub {
    ok(-f $tests_pl, 'admin/tests.pl exists') or return;
    my $text = slurp($tests_pl);

    ok($text =~ /^sub run_without_shell\b/m, 'run_without_shell is defined');
    ok($text =~ /open\s*\(\s*\$fh\s*,\s*"-\|"\s*,\s*\@cmd\s*\)/,
        'uses list-form open($fh, "-|", @cmd)');
    ok($text =~ /run_without_shell\s*\(\s*\@exe\s*\)/,
        'snmpget is run through run_without_shell(@exe)');
    ok($text =~ /^sub snmp_target\b/m, 'snmp_target is defined');
    ok($text =~ /snmp_target\s*\(\s*\$nodeconfig->\{host\}/,
        'testsnmp builds its target through snmp_target');
};

# ---------------------------------------------------------------------------
# Extract and eval both helpers once, into their own package
# ---------------------------------------------------------------------------
my $rws_code = extract_sub($tests_pl, 'run_without_shell');
my $tgt_code = extract_sub($tests_pl, 'snmp_target');

ok(defined $rws_code, 'run_without_shell extracted from source (absent on pre-fix base)');
ok(defined $tgt_code, 'snmp_target extracted from source (absent on pre-fix base)');

my $helpers_ok = 0;
if (defined $rws_code and defined $tgt_code)
{
    $helpers_ok = eval "package _T640; no warnings; $rws_code $tgt_code; 1" ? 1 : 0;
    ok($helpers_ok, "helpers eval cleanly: $@");
}

# ---------------------------------------------------------------------------
# 2. Behavioural: metacharacters in arguments are data, not shell syntax
# ---------------------------------------------------------------------------
subtest 'run_without_shell passes metacharacters through as data' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";
    my $mock     = write_mock("$tmpdir/snmpget", $argv_log);

    # each payload must arrive as one argv element and must not run a sidecar
    my @payloads = (
        [ 'semicolon',       'localhost; touch %s'            ],
        [ 'command substitution', 'localhost$(touch %s)'      ],
        [ 'backticks',       'localhost`touch %s`'            ],
        [ 'pipe',            'localhost | touch %s'           ],
        [ 'ampersand',       'localhost && touch %s'          ],
        [ 'newline',         "localhost\ntouch %s"            ],
    );

    my $n = 0;
    for my $case (@payloads)
    {
        my ($desc, $template) = @$case;
        my $sidecar = "$tmpdir/INJECTED_".($n++);
        my $payload = sprintf($template, $sidecar);

        unlink $argv_log;
        _T640::run_without_shell($mock, $payload, "1.3.6.1.2.1.1.1.0");

        ok(!-e $sidecar, "$desc: no sidecar command ran");

        my $recorded = -f $argv_log ? slurp($argv_log) : '';
        ok(index($recorded, $payload) >= 0,
            "$desc: payload reached argv intact as one element");
    }
};

subtest 'run_without_shell keeps apostrophes in secrets intact' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";
    my $mock     = write_mock("$tmpdir/snmpget", $argv_log);

    # the old code wrapped community and v3 passphrases in single quotes, so an
    # apostrophe broke out of them
    my $community = "pub'lic; touch $tmpdir/INJECTED_QUOTE";
    _T640::run_without_shell($mock, "-v", "2c", "-c", $community,
        "localhost:161", "1.3.6.1.2.1.1.1.0");

    ok(!-e "$tmpdir/INJECTED_QUOTE", 'apostrophe in community did not break out');

    my @args = split(/\n/, (-f $argv_log ? slurp($argv_log) : ''));
    ok(scalar(grep { $_ eq $community } @args),
        'community with apostrophe arrived as exactly one argv element');
};

# ---------------------------------------------------------------------------
# 3. Behavioural: error reporting and the single-element guard
# ---------------------------------------------------------------------------
subtest 'run_without_shell reports failures and refuses single-element lists' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";

    # missing binary: must name the binary and include $! (diagnostics kept)
    my $missing = _T640::run_without_shell("$tmpdir/does_not_exist", "arg");
    like($missing, qr/^ERROR: cannot run \Q$tmpdir\E\/does_not_exist: \S/,
        'missing binary reports the path and the errno string');

    # non-zero exit: status must be the exit code, not the raw wait status
    my $failing = write_mock("$tmpdir/failing", $argv_log, 3);
    my $exited  = _T640::run_without_shell($failing, "arg");
    like($exited, qr/exited with status 3\b/,
        'non-zero exit reports exit code 3, not raw wait status 768');
    unlike($exited, qr/status 768/, 'raw wait status is not reported');

    # single-element list would fall back to /bin/sh, so it must be refused
    my $sidecar = "$tmpdir/INJECTED_SINGLE";
    my $single  = _T640::run_without_shell("/bin/echo hi; touch $sidecar");
    like($single, qr/^ERROR: refusing to run single-element command/,
        'single-element command is refused with a visible error');
    ok(!-e $sidecar, 'single-element command did not reach the shell');
};

# ---------------------------------------------------------------------------
# 4. Behavioural: snmp_target rejects option-looking hosts (CWE-88)
#
# $target is a positional argument to snmpget.  A host beginning with "-" is
# read as an option instead of a target, and net-snmp options such as
# "-Lf <path>" write to an attacker-chosen path as the calling user (root).
# ---------------------------------------------------------------------------
subtest 'snmp_target accepts real targets' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my @accept = (
        [ 'localhost',           161,   'localhost:161'           ],
        [ '192.0.2.1',           161,   '192.0.2.1:161'           ],
        [ 'router-1.example.com', 1161, 'router-1.example.com:1161' ],
        [ '[2001:db8::1]',       161,   '[2001:db8::1]:161'       ],
        [ 'host_under',          161,   'host_under:161'          ],
    );
    for my $tc (@accept)
    {
        my ($host, $port, $expected) = @$tc;
        is(_T640::snmp_target($host, $port), $expected, "accepts $host:$port");
    }
};

subtest 'snmp_target rejects option-looking and malformed targets' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my @reject = (
        [ '-Lf/tmp/evil',      161,     'leading-dash host that writes a log file' ],
        [ '--help',            161,     'long option as host'                      ],
        [ '-c',                161,     'short option as host'                     ],
        [ 'localhost; id',     161,     'host with a semicolon'                    ],
        [ 'localhost id',      161,     'host with a space'                        ],
        [ 'local`host`',       161,     'host with backticks'                      ],
        [ "local\nhost",       161,     'host with a newline'                      ],
        [ "host'",             161,     'host with an apostrophe'                  ],
        [ 'host$(id)',         161,     'host with command substitution'           ],
        [ '',                  161,     'empty host'                               ],
        [ undef,               161,     'undef host'                               ],
        [ 'localhost',         '',      'empty port'                               ],
        [ 'localhost',         undef,   'undef port'                               ],
        [ 'localhost',         '161; id', 'port with a semicolon'                  ],
        [ 'localhost',         '-1',    'negative port'                            ],
        [ 'localhost',         'abc',   'non-numeric port'                         ],
    );
    for my $tc (@reject)
    {
        my ($host, $port, $desc) = @$tc;
        is(_T640::snmp_target($host, $port), undef, "rejects $desc");
    }
};

# ---------------------------------------------------------------------------
# 5. End-to-end: the v2c argv shape reaches a mock snmpget intact
# ---------------------------------------------------------------------------
subtest 'v2c argv built the way testsnmp builds it reaches snmpget as data' => sub {
    if (!$helpers_ok) { fail('helpers unavailable, cannot exercise behaviour'); return }

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $argv_log = "$tmpdir/argv.txt";
    my $mock     = write_mock("$tmpdir/snmpget", $argv_log);

    my $sidecar   = "$tmpdir/INJECTED_E2E";
    my $community = "pub'lic\$(touch $sidecar)";
    my $testoid   = "1.3.6.1.2.1.1.1.0";

    my $target = _T640::snmp_target('192.0.2.1', 161);
    ok(defined $target, 'clean host and port produce a target') or return;

    # same list shape as the snmpv2c branch of testsnmp
    my @exe = ($mock, "-v", "2c", "-c", $community, $target, $testoid);
    _T640::run_without_shell(@exe);

    ok(!-e $sidecar, 'no sidecar command ran from the community string');

    my @args = split(/\n/, (-f $argv_log ? slurp($argv_log) : ''));
    is(scalar(@args), 6, 'snmpget received exactly six arguments');
    is($args[0], '-v',        'argv[0] is -v');
    is($args[1], '2c',        'argv[1] is 2c');
    is($args[2], '-c',        'argv[2] is -c');
    is($args[3], $community,  'community passed as one argv element, unmodified');
    is($args[4], $target,     'target passed as one argv element');
    is($args[5], $testoid,    'test OID passed last');
};

done_testing;
