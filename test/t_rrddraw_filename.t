#!/usr/bin/perl
#
# Tests for OMK-12704: arbitrary file write via rrddraw.pl filename parameter
#
# Covers:
#   1. rrddraw.pl does not read $Q->{filename} and has no $filename variable.
#   2. draw() call in rrddraw.pl has no filename key.
#   3. Behavioural: rrdDraw_web_args() does not forward a caller-supplied
#      filename to draw(). Loads the shipped NMISNG::rrdfunc module and calls
#      the real function; bails out if the module cannot be loaded in this env.
#
# IDOR companion (OMK-12706): no CheckAccess before drawing — tracked separately.
# Filesystem-permission hardening: the web user's write access to config/RRD/script
# directories is granted by in-repo code (installer_hooks/20-postcopy-user adds
# httpd to the nmis group; installer_hooks/99-postcopy-fixperms runs
# bin/nmis-cli act=fixperms which chmod -R g+rw the tree).  The upstream
# architectural fix is OMK-12811 ("[High] H1b: Root-own config + privileged GUI
# write path"); OMK-12811's current scope covers conf/models/tables — extending
# that to RRD and script directories is outstanding work on that ticket.  This
# PR closes only the arbitrary-write injection vector (attacker-controlled
# filename reaching RRDs::graph).
#
# Subtest 3 covers the rrddraw.pl half: rrdDraw_web_args() excludes filename
# so draw() receives no filename arg from the web path.
# Subtest 4 covers the rrdfunc.pm dispatch block: verifies _rrd_graph_target()
# is called and both branches use the correct RRDs::graph first argument.
# Subtest 5 covers the full web path chain: rrdDraw_web_args() + _rrd_graph_target()
# together produce '-' (streaming) even when the CGI query has a filename.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

my $rrddraw = "$FindBin::Bin/../cgi-bin/rrddraw.pl";

# ---------------------------------------------------------------------------
# 1. rrddraw.pl does not read $Q->{filename} and has no $filename variable
# ---------------------------------------------------------------------------
subtest 'rrddraw.pl does not read or pass caller-supplied filename' => sub {
    ok(-f $rrddraw, 'rrddraw.pl exists') or return;
    open(my $fh, '<', $rrddraw) or die "cannot open $rrddraw: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content !~ /\$Q->\{filename\}/,
        'rrddraw.pl does not read $Q->{filename}');
    ok($content !~ /my\s+\$filename\s*=/,
        'rrddraw.pl has no $filename local variable');
};

# ---------------------------------------------------------------------------
# 2. draw() call in rrddraw.pl has no filename key
# ---------------------------------------------------------------------------
subtest 'draw call in rrddraw.pl has no filename key' => sub {
    ok(-f $rrddraw, 'rrddraw.pl exists') or return;
    open(my $fh, '<', $rrddraw) or die "cannot open $rrddraw: $!";
    my $content = join('', <$fh>);
    close $fh;

    ok($content !~ /\bfilename\s*=>/,
        'no filename key in rrddraw.pl (draw call or elsewhere)');
    ok($content =~ /NMISNG::rrdfunc::draw\s*\(\s*NMISNG::rrdfunc::rrdDraw_web_args/,
        'draw() called through rrdDraw_web_args in rrddraw.pl (not raw %$Q bypass)');
};

# ---------------------------------------------------------------------------
# 3. Behavioural: rrdDraw_web_args() does not forward a caller-supplied
#    filename to draw().
#
# Loads the shipped NMISNG::rrdfunc, calls rrdDraw_web_args() directly, and
# asserts the returned arg list has no filename key — even when a filename is
# present in the CGI query params.  This exercises the real production code
# that rrddraw.pl uses to construct draw()'s argument list.
#
# On the vulnerable base (pre-fix), rrdDraw_web_args does not exist, so the
# eval catches the undefined-sub error and the subtest fails.  On the fixed
# head it exists and returns args without filename.
# ---------------------------------------------------------------------------
subtest 'behavioural: rrdDraw_web_args does not forward filename to draw()' => sub {
    eval { require NMISNG::rrdfunc };
    if ($@) {
        BAIL_OUT("NMISNG::rrdfunc not loadable — cannot verify security test: $@");
    }

    my %draw_args;
    eval {
        %draw_args = NMISNG::rrdfunc::rrdDraw_web_args(
            node      => 'router01',
            graphtype => 'abits',
            filename  => '/tmp/evil.png',
            intf      => 'eth0',
            item      => '',
            width     => 600,
            height    => 200,
            start     => 0,
            end       => 0,
            debug     => 0,
            time      => 0,
        );
    };
    if ($@) {
        fail("rrdDraw_web_args not defined or raised exception: $@");
        return;
    }

    ok(!exists $draw_args{filename},
        'rrdDraw_web_args: caller-supplied filename is not in the draw() arg list');
    is($draw_args{node}, 'router01',
        'rrdDraw_web_args: legitimate args (node) are forwarded correctly');
    is($draw_args{graphtype}, 'abits',
        'rrdDraw_web_args: legitimate args (graphtype) are forwarded correctly');
};

# ---------------------------------------------------------------------------
# 4. draw() dispatch: uses _rrd_graph_target() to determine output target;
#    streaming target ('-') -> stdout, file target -> writes to $target.
#
# Locates the dispatch block inside draw() in rrdfunc.pm (not a whole-file
# grep) and verifies _rrd_graph_target is called and both branches use the
# correct argument to RRDs::graph.  This dispatch block exists on both the
# vulnerable base and fixed head; the security fix is in rrddraw.pl
# (removing filename from the web path), not in draw() itself.
# ---------------------------------------------------------------------------
subtest 'draw() dispatch: _rrd_graph_target determines target; streaming uses "-", file uses $target' => sub {
    my $rrdfunc = "$FindBin::Bin/../lib/NMISNG/rrdfunc.pm";
    ok(-f $rrdfunc, 'rrdfunc.pm exists') or return;
    open(my $fh, '<', $rrdfunc) or die "cannot open $rrdfunc: $!";
    my @lines = <$fh>;
    close $fh;

    # Find the start of sub draw()
    my $draw_start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub draw\b/) { $draw_start = $i; last }
    }
    ok(defined $draw_start, 'sub draw found in rrdfunc.pm') or return;

    # Extract just the draw() body (brace-balanced)
    my ($depth, $draw_end) = (0, $draw_start);
    for my $i ($draw_start .. $#lines) {
        $depth += () = $lines[$i] =~ /\{/g;
        $depth -= () = $lines[$i] =~ /\}/g;
        if ($depth == 0 && $i > $draw_start) { $draw_end = $i; last }
    }
    my $draw_body = join('', @lines[$draw_start .. $draw_end]);

    # dispatch uses _rrd_graph_target to determine the output target
    ok($draw_body =~ /_rrd_graph_target\s*\(/,
        'draw() calls _rrd_graph_target to determine the output target');

    # Streaming branch: if ($target eq '-') -> RRDs::graph('-', ...)
    ok($draw_body =~ /if\s*\(\s*\$target\s+eq\s+['"]-['"]\s*\).*?RRDs::graph\s*\(\s*['"]-['"]/s,
        "draw(): streaming target dispatches to RRDs::graph('-', ...) streaming branch");

    # File-write branch: else -> RRDs::graph($target, ...)
    ok($draw_body =~ /else.*?RRDs::graph\s*\(\s*\$target\s*,/s,
        "draw(): file target dispatches to RRDs::graph(\$target, ...) file branch");
};

# ---------------------------------------------------------------------------
# 5. Behavioural: _rrd_graph_target maps web args to streaming target.
#
# rrdDraw_web_args() excludes filename; _rrd_graph_target() converts that
# absence to '-' (stream to stdout).  Together they form the web path that
# prevents an attacker-supplied filename reaching RRDs::graph.
#
# Absent on pre-fix base (_rrd_graph_target not defined) -> subtest fails.
# ---------------------------------------------------------------------------
subtest 'behavioural: _rrd_graph_target maps web args to streaming target' => sub {
    eval { require NMISNG::rrdfunc };
    if ($@) {
        BAIL_OUT("NMISNG::rrdfunc not loadable — cannot verify security test: $@");
    }

    if (!NMISNG::rrdfunc->can('_rrd_graph_target')) {
        fail('_rrd_graph_target not defined in NMISNG::rrdfunc (absent on pre-fix base)');
        return;
    }

    # Web path: rrdDraw_web_args strips filename -> _rrd_graph_target gets undef -> '-'
    my %web_args = NMISNG::rrdfunc::rrdDraw_web_args(
        filename  => '/tmp/evil.png',
        node      => 'router01',
        graphtype => 'abits',
    );
    ok(!exists $web_args{filename},
        'rrdDraw_web_args excludes filename from web args');
    is(NMISNG::rrdfunc::_rrd_graph_target($web_args{filename}), '-',
        '_rrd_graph_target: web args (no filename) -> streaming target');

    # _rrd_graph_target returns file path for internal callers with explicit filename
    is(NMISNG::rrdfunc::_rrd_graph_target('/tmp/evil.png'), '/tmp/evil.png',
        '_rrd_graph_target: explicit filename -> file target (rrdDraw_web_args blocks this from web path)');
    is(NMISNG::rrdfunc::_rrd_graph_target('/var/cache/nmis9/graph.png'), '/var/cache/nmis9/graph.png',
        '_rrd_graph_target: legitimate internal filename -> file target');

    # Edge cases: no filename -> streaming
    is(NMISNG::rrdfunc::_rrd_graph_target(undef), '-', '_rrd_graph_target: undef -> streaming');
    is(NMISNG::rrdfunc::_rrd_graph_target(''),    '-', '_rrd_graph_target: empty string -> streaming');
    is(NMISNG::rrdfunc::_rrd_graph_target('0'),   '-', '_rrd_graph_target: "0" -> streaming');
};

done_testing;
