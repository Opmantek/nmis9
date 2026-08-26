#!/usr/bin/perl
#
# Tests for OMK-12823: arbitrary file read via the log viewer's logFileName
# (cgi-bin/logs.pl).
#
# table_logs_rw is level1, so a manager can write the Logs table. Before the fix,
# logs.pl kept logFileName verbatim whenever it contained a '/', then read and
# displayed it, so an entry could name conf/Config.nmis and disclose auth_web_key.
# The log viewer is now confined to <nmis_logs>, with no exceptions.
#
# Covers:
#   1. Static: the raw <nmis_logs> concatenation is gone and the sink goes
#      through NMISNG::Util::confine_path_to_dir().
#   2. confine_path_to_dir() refuses traversal, absolute paths outside the log
#      dir, and basenames carrying shell metacharacters.
#   3. confine_path_to_dir() accepts bare names, not-yet-created logs and
#      subdirectories of the log dir.
#   4. loadLogFile filters the rotation glob, so a filename planted in the log
#      directory cannot reach the shell pipe that reads it.
#   5. conf-default/Logs.nmis ships nothing outside the log dir, so no shipped
#      entry is dead on arrival.
#
# Subtests 2-3 call NMISNG::Util directly. On the vulnerable base the functions
# are absent and the guard below fails the test rather than skipping it.
#
# Runs without a live NMIS server or MongoDB. Uses File::Temp for isolation.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd ();
use NMISNG::Util;

my $logs_pl   = "$FindBin::Bin/../cgi-bin/logs.pl";
my $logs_nmis = "$FindBin::Bin/../conf-default/Logs.nmis";

# The confinement lives in NMISNG::Util so it can be driven directly. Absent on
# the vulnerable base, where every behavioural subtest below must fail loudly.
my $have_fix = NMISNG::Util->can('confine_path_to_dir')
    && NMISNG::Util->can('path_inside_dir');

# a log tree with a sibling conf/ to escape into, mirroring the real layout
my $root = tempdir(CLEANUP => 1);
my $logdir = "$root/logs";
make_path("$logdir/json", "$root/conf");
for my $f ("$logdir/event.log", "$root/conf/Config.nmis", "$logdir/json/x.log") {
    open(my $fh, '>', $f) or die "cannot create $f: $!";
    print $fh "x\n";
    close $fh;
}

# symlinks planted inside the log dir, which anyone who can write it can do
my $can_symlink = eval {
    symlink("$root/conf/Config.nmis", "$logdir/leak.log")
        && symlink('/etc/passwd', "$logdir/passwd.log")
        && symlink("$logdir/event.log", "$logdir/intree.log");
};

# confine_path_to_dir warns on refusal, which would clutter the test output
sub confine {
    my ($fn, $dir) = @_;
    local $SIG{__WARN__} = sub { };
    return NMISNG::Util::confine_path_to_dir($fn, $dir, 'logs.pl');
}

# ---------------------------------------------------------------------------
# 1. Static: the vulnerable line is gone and the sink is guarded
# ---------------------------------------------------------------------------
subtest 'logs.pl no longer concatenates logFileName unchecked' => sub {
    ok(-f $logs_pl, 'logs.pl exists') or return;
    open(my $fh, '<', $logs_pl) or die "cannot open $logs_pl: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    my $vulnerable = q{{logFileName} = $C->{'<nmis_logs>'} .'/'.};
    ok(index($content, $vulnerable) == -1,
        'raw <nmis_logs> concatenation removed');
    ok($content =~ /\{logFileName\} = NMISNG::Util::confine_path_to_dir\(/,
        'logFileName assigned through NMISNG::Util::confine_path_to_dir');
    ok(NMISNG::Util->can('is_safe_script_basename'),
        'basename guard available, keeping metacharacters out of the tac pipe');
};

# ---------------------------------------------------------------------------
# 2. Behavioural: refusals
# ---------------------------------------------------------------------------
subtest 'confine_path_to_dir refuses paths outside the log directory' => sub {
    if (!$have_fix) {
        fail('NMISNG::Util::confine_path_to_dir missing (fix not applied)');
        return;
    }

    my @reject = (
        '../conf/Config.nmis',
        "$root/conf/Config.nmis",
        "$logdir/../conf/Config.nmis",
        "$logdir/json/../../conf/Config.nmis",
        '/etc/passwd',
        '/var/log/messages',
        '/var/log/httpd/access_log',
        'evil;id.log',                  # shell metacharacter in the basename
        '$(id).log',
        "event.log\nx",
        '..',
        '.',
        '',
    );
    if ($can_symlink) {
        # the finding asks for the file's realpath, not its parent's. A symlink
        # planted in the log dir would otherwise read anything the web user can.
        push @reject, "$logdir/leak.log", "$logdir/passwd.log", 'leak.log';
    }
    for my $bad (@reject) {
        my $shown = $bad eq '' ? '(empty)' : $bad;
        $shown =~ s/\n/\\n/g;
        is(confine($bad, $logdir), undef, "refused: $shown");
    }
    is(confine(undef, $logdir), undef, 'refused: undef');
};

# ---------------------------------------------------------------------------
# 3. Behavioural: legitimate log files still resolve
# ---------------------------------------------------------------------------
subtest 'confine_path_to_dir accepts logs inside the log directory' => sub {
    if (!$have_fix) {
        fail('NMISNG::Util::confine_path_to_dir missing (fix not applied)');
        return;
    }
    my $real = Cwd::abs_path($logdir);

    is(confine('event.log', $logdir), "$real/event.log",
        'bare name gets the log dir prepended');
    is(confine('nmis.log', $logdir), "$real/nmis.log",
        'log that does not exist yet still resolves, so it can list as UA');
    is(confine("$logdir/event.log", $logdir), "$real/event.log",
        'absolute path inside the log dir is kept');
    is(confine("$logdir/json/x.log", $logdir), "$real/json/x.log",
        'subdirectory of the log dir is allowed');
    is(confine('cisco.log.1.gz', $logdir), "$real/cisco.log.1.gz",
        'rotated and compressed names are allowed');

  SKIP: {
        skip 'symlinks not available here', 1 if !$can_symlink;
        is(confine('intree.log', $logdir), "$real/intree.log",
            'symlink whose target is inside the log dir is still allowed');
    }
};

# ---------------------------------------------------------------------------
# 4. The rotation glob is filtered before its results reach the shell pipe.
#
# loadLogFile globs "$file*" to pick up rotations, then interpolates each result
# into `open(DATA, "$cmd |")`. Confining $file does not cover what the glob
# finds next to it, and <nmis_logs> is group-writable by the web user, so a file
# named `event.log;cmd` would otherwise execute, and a symlinked rotation would
# read out of the tree. loadLogFile closes over too many globals to call
# directly, so this pairs a source check on the filter with a behavioural check
# of the guard it applies.
# ---------------------------------------------------------------------------
subtest 'rotation glob results are filtered before the shell pipe' => sub {
    ok(-f $logs_pl, 'logs.pl exists') or return;
    open(my $fh, '<', $logs_pl) or die "cannot open $logs_pl: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    my ($body) = $content =~ /\n(\tmy\t\@fileList\s*=.*?open \(DATA)/s;
    ok(defined $body, 'found the glob and the pipe open') or return;
    like($body, qr/\@fileList = grep \{ NMISNG::Util::path_inside_dir\(/,
        'glob results filtered by path_inside_dir before the open');

    # the basename half of that guard, on names the glob really produces
    for my $good (qw(event.log event.log.1 event.log.2.gz event.log-20160710.gz
                     nmis.log cisco.log)) {
        ok(NMISNG::Util::is_safe_script_basename($good), "rotation kept: $good");
    }
    for my $bad ('event.log;touch INJECTED', 'event.log|id', 'event.log`id`',
                 'event.log$(id)', 'event.log&id', 'event.log >out') {
        ok(!NMISNG::Util::is_safe_script_basename($bad), "planted name dropped: $bad");
    }
};

# ---------------------------------------------------------------------------
# 5. The shipped table ships nothing the confinement would refuse
# ---------------------------------------------------------------------------
subtest 'conf-default/Logs.nmis stays inside the log directory' => sub {
    ok(-f $logs_nmis, 'conf-default/Logs.nmis exists') or return;

    my $table = NMISNG::Util::readFiletoHash(file => $logs_nmis);
    if (ref($table) ne 'HASH') {
        fail("cannot read the shipped Logs table: $table");
        return;
    }
    ok(scalar(keys %{$table}), 'shipped table is not empty');

    for my $key (sort keys %{$table}) {
        my $fn = $table->{$key}{logFileName};
        ok(defined($fn) && $fn ne '' && $fn !~ m!/!,
            "entry $key ($table->{$key}{logName}) is a bare name: "
                . (defined $fn ? $fn : '(undef)'));
    }
};

done_testing();
