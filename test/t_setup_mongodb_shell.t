#!/usr/bin/perl
#
# Tests for OMK-12642: shell removal and systemLog.path validation in
# admin/setup_mongodb.pl
#
# Runs without a live NMIS server, MongoDB, logrotate or root privileges.
#
# Covers:
#   1. The shipped systemLog.path guard rejects logrotate config injection.
#   2. The guard accepts the real-world mongod log paths.
#   3. The \z anchor does not accept a trailing newline.
#   4. Static: no backticks or qx// remain in the script.
#   5. Static: the logrotate config is written through a Perl filehandle,
#      not a shell "cat > file <<EOF" heredoc.
#   6. Static: the postrotate line still carries a literal $(pidof mongod).
#   7. Static: logrotate and the other commands are invoked in list form.
#   8. Static: stat is guarded, and chmod/utime on the backups are checked.
#   9. Static: LoadFile and DumpFile die on failure at both sites.
#  10. Static: the '|| "null"' default that made a '! defined' test dead is gone.
#
# Subtests 1-3 extract the guard regex from the script and run payloads through
# the real shipped pattern, not a mirrored copy. On the vulnerable base the
# pattern is absent and they fail, which is what makes this a regression pin.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

my $script = "$FindBin::Bin/../admin/setup_mongodb.pl";

my $content = '';
if (-f $script) {
    open(my $fh, '<', $script) or die "cannot open $script: $!";
    $content = do { local $/; <$fh> };
    close $fh;
}

# source with comments removed, for assertions that must not trip over a
# comment which merely mentions the construct being banned
my $code_only = join("\n", grep { !/^\s*#/ } split(/\n/, $content));

# ---------------------------------------------------------------------------
# Extract the shipped systemLog.path guard so subtests 1-3 exercise the real
# pattern rather than a copy of it.
# ---------------------------------------------------------------------------
my $guard_re;
if ($content =~ /\$mongod_systemlog_path\s*!~\s*m\{(.+?)\}\s*\)/) {
    my $src = $1;
    $guard_re = eval { qr/$src/ };
}

# ---------------------------------------------------------------------------
# 1. Behavioural: the guard rejects logrotate config injection
# ---------------------------------------------------------------------------
subtest 'systemLog.path guard rejects logrotate config injection' => sub {
    if (!defined $guard_re) {
        fail('systemLog.path guard not found in setup_mongodb.pl (validation not applied)');
        return;
    }

    # the ticket's vector. systemLog.path is read from /etc/mongod.conf and
    # becomes the stanza header of /etc/logrotate.d/mongod.conf, which the
    # script then runs with "logrotate -vf". logrotate runs postrotate as root.
    my @reject = (
        ["/var/log/mongodb/mongod.log\n}\n/tmp/p {\n  postrotate\n    id\n  endscript\n}",
            'newline plus brace closing our stanza and opening another'],
        ["/var/log/x\n",            'trailing newline'],
        ["/var/log/x\r\n}",         'CR LF plus brace'],
        ["/var/log/x\0/y",          'embedded NUL'],
        ['/var/log/x }',            'space plus brace'],
        ['/var/log/x{y}',           'inline braces'],
        ['/var/log/x #comment',     'logrotate comment character'],
        ['/var/log/*.log',          'glob metacharacter'],
        ['/var/log/"x".log',        'double quote'],
        ['$(pidof mongod)',         'the original shell command substitution payload'],
        ['`id`',                    'shell backtick payload'],
        ['var/log/x.log',           'relative path'],
        ['/',                       'bare slash with empty remainder'],
        ['',                        'empty string'],
    );

    for my $case (@reject) {
        my ($input, $desc) = @$case;
        my $display = $input;
        $display =~ s/\n/\\n/g;
        $display =~ s/\r/\\r/g;
        $display =~ s/\0/\\0/g;
        ok($input !~ $guard_re, "rejects $desc: '$display'");
    }
};

# ---------------------------------------------------------------------------
# 2. Behavioural: the guard accepts the paths real installs actually use
# ---------------------------------------------------------------------------
subtest 'systemLog.path guard accepts legitimate mongod log paths' => sub {
    if (!defined $guard_re) {
        fail('systemLog.path guard not found in setup_mongodb.pl (validation not applied)');
        return;
    }

    my @accept = (
        '/var/log/mongodb/mongod.log',      # debian, ubuntu
        '/var/log/mongo/mongod.log',        # rhel, centos
        '/var/log/mongodb/mongod-01.log',
        '/data/db/log/mongod.log',
        '/var/log/mongodb/mongod_1.log',
        '/var/log/mongodb/mongod-a.b.c.log',
    );

    for my $input (@accept) {
        ok($input =~ $guard_re, "accepts: '$input'");
    }
};

# ---------------------------------------------------------------------------
# 3. Behavioural: \z and not $, which would permit a trailing newline
# ---------------------------------------------------------------------------
subtest 'guard is anchored with \\z, not $' => sub {
    if (!defined $guard_re) {
        fail('systemLog.path guard not found in setup_mongodb.pl (validation not applied)');
        return;
    }

    ok("/var/log/mongodb/mongod.log\n" !~ $guard_re,
        'trailing newline rejected ($ would have matched before it)');
    ok('/var/log/mongodb/mongod.log' =~ $guard_re,
        'same path without the newline accepted');
    like($content, qr/\\z\}\)/,
        'source anchors the guard with \z');
};

# ---------------------------------------------------------------------------
# 4. Static: no shell-reaching constructs remain
# ---------------------------------------------------------------------------
subtest 'no backticks or qx// remain in setup_mongodb.pl' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    unlike($code_only, qr/`/,            'no backticks in code');
    unlike($code_only, qr/\bqx[({\[\/|#]/, 'no qx// in code');
    unlike($code_only, qr/\bexec\s*\(/,  'no exec() in code');
    # \bopen so this does not match sysopen(...), whose bitwise-OR flag list
    # (O_WRONLY | O_CREAT | ...) is not a shell pipe.
    unlike($code_only, qr/\bopen\s*\([^)]*\|/, 'no piped open in code');
};

# ---------------------------------------------------------------------------
# 5. Static: the logrotate config goes through a Perl filehandle
# ---------------------------------------------------------------------------
subtest 'logrotate config is written by Perl, not a shell heredoc' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    unlike($content, qr/cat\s*>\s*"?\$mongod_logrotate_conf/,
        'no shell "cat > file" redirect writing the logrotate config');
    like($content, qr/open\s*\(\s*my\s+\$logrotate_fh\s*,\s*'>'\s*,\s*\$mongod_logrotate_conf\s*\)/,
        'logrotate config opened as a Perl filehandle');
    like($content, qr/print\s+\$logrotate_fh\s+<<"EOF";/,
        'content printed to that filehandle from a Perl heredoc');
    like($content, qr/close\s*\(\s*\$logrotate_fh\s*\)\s*\n?\s*or\s+die/,
        'close is checked, so a failed write is not silently ignored');
};

# ---------------------------------------------------------------------------
# 6. Static: postrotate still carries a literal $(pidof mongod)
# ---------------------------------------------------------------------------
subtest 'postrotate line keeps a literal $(pidof mongod)' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    # in a Perl interpolating heredoc, \$ yields a literal $ in the written
    # file, which is what logrotate must see. an unescaped $( would be a Perl
    # syntax error, and \\\$ was what the old shell-in-backticks form needed.
    like($content, qr/kill -SIGUSR1 \\\$\(pidof mongod\)/,
        'heredoc has \$(pidof mongod), giving a literal $(pidof mongod) on disk');
    unlike($content, qr/kill -SIGUSR1 \\\\\\\$\(pidof mongod\)/,
        'not the old triple-escaped shell heredoc form');
};

# ---------------------------------------------------------------------------
# 7. Static: commands are invoked in list form
# ---------------------------------------------------------------------------
subtest 'logrotate and service commands use list-form system()' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    like($content, qr/system\s*\(\s*"logrotate"\s*,\s*"-vf"\s*,\s*\$mongod_logrotate_conf\s*\)/,
        'logrotate invoked in list form, so its argument never reaches a shell');

    # the one remaining string-form system() is a constant with no
    # interpolation, reviewed and deliberately left as a follow-up
    my @string_form = ($code_only =~ /system\s*\(\s*"([^"]*)"\s*\)/g);
    is(scalar(@string_form), 1, 'exactly one string-form system() remains');
    is($string_form[0], 'pidof mongod >/dev/null',
        'and it is the constant pidof check, with nothing interpolated');
};

# ---------------------------------------------------------------------------
# 8. Static: backup metadata calls are guarded
# ---------------------------------------------------------------------------
subtest 'backup stat, chmod and utime are checked' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    my @stat_calls = ($content =~ /my \@mongod_conf_stat = stat\(\$mongod_conf\);/g);
    is(scalar(@stat_calls), 2, 'both backup sites stat the source');

    my @stat_guards = ($content =~ /\@mongod_conf_stat\s*\n?\s*or\s+die/g);
    is(scalar(@stat_guards), 2,
        'both stat calls are guarded, so an empty stat cannot chmod the backup to 0000');

    # the unguarded statement-terminated forms must be gone
    unlike($content, qr/chmod\(\(\$mongod_conf_stat\[2\] & 07777\), \$mongod_conf_backup\);/,
        'no unchecked chmod on the backup');
    unlike($content, qr/utime\(\$mongod_conf_stat\[8\], \$mongod_conf_stat\[9\], \$mongod_conf_backup\);/,
        'no unchecked utime on the backup');
};

# ---------------------------------------------------------------------------
# 9. Static: every LoadFile and DumpFile call dies on failure
# ---------------------------------------------------------------------------
# Expected call counts: the two historic logrotate/auth sites (OMK-12642), plus,
# for LoadFile, the bindIp-capture read in reset_admin_password (OMK-12826). The
# guarantee that matters is that NONE are unchecked; the counts are a sanity pin.
subtest 'LoadFile and DumpFile are checked at every site' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    my %expected = (LoadFile => 3, DumpFile => 2);
    for my $fn (qw(LoadFile DumpFile)) {
        my @calls = grep { /\b$fn\s*\(/ && !/^\s*use\s+YAML/ }
            split(/\n/, $code_only);
        is(scalar(@calls), $expected{$fn}, "$fn is called at $expected{$fn} sites");
        my @unchecked = grep { !/\bdie\b/ } @calls;
        is(scalar(@unchecked), 0, "every $fn call dies on failure");
        diag("unchecked $fn call: $_") for @unchecked;
    }
};

# ---------------------------------------------------------------------------
# 10. Static: the sentinel that made the '! defined' test dead is gone
# ---------------------------------------------------------------------------
subtest 'no "null" default hiding undef from the defined test' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    unlike($content, qr/\{systemLog\}\{path\}\s*\|\|\s*["']null["']/,
        'systemLog.path is read without a "null" default');
    like($content, qr/my \$mongod_systemlog_path = \$yaml->\{systemLog\}\{path\};/,
        'the value is read directly, so the defined test below it can fire');
};

# ---------------------------------------------------------------------------
# 11. Static: an undecryptable db_password (still '!!'-prefixed after
# decrypt) stops the script before it can set the MongoDB user's password
# to the literal ciphertext (OMK-12827 Slice B).
#
# Static, not behavioural, because the check lives in the script's main
# body, after the `return 1 if (caller())` modulino guard, so a `require`d
# test (as t_setup_mongodb_provisioning.t does for the other subs) never
# reaches it; exercising it live would mean running the whole provisioning
# flow end to end, which is out of scope for this cheap regression pin.
# ---------------------------------------------------------------------------
subtest 'undecryptable db_password (still !!) is a fatal stop, not a stray password' => sub {
    ok(-f $script, 'setup_mongodb.pl exists') or return;

    like($content, qr/die\(\s*"FATAL:.*cannot be decrypted/s,
        'a die names the undecryptable db_password as fatal');
    like($content, qr/if\s*\(\s*substr\(\$curpw,\s*0,\s*2\)\s*eq\s*'!!'\s*\)/,
        'the guard checks for the surviving !! ciphertext prefix');
    like($content, qr/master_key_file/,
        'the fatal message points the operator at master_key_file');

    # ordering: the guard must run before $is_default is computed, otherwise
    # a stuck '!!' value would be treated as a real (non-default) password
    # and provisioning would proceed to set it on the MongoDB user.
    my $guard_index    = index($content, "substr(\$curpw, 0, 2) eq '!!'");
    my $isdefault_index = index($content, 'my $is_default');
    cmp_ok($guard_index, '>', -1, 'guard found in source');
    cmp_ok($isdefault_index, '>', -1, '$is_default computation found in source');
    ok($guard_index < $isdefault_index,
        'the !! guard runs before $is_default is computed');
};

done_testing;
