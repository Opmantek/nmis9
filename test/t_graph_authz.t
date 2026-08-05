#!/usr/bin/perl
#
# Behavioural authorisation tests for OMK-12706, driving the two graph call
# sites through the real CGI. This replaces the earlier structural form of this
# test, which read cgi-bin/rrddraw.pl and cgi-bin/node.pl as text and asserted
# that the right call names appeared in the right order. That checked the shape
# of the source, not what the code does. This drives both scripts in-process
# through the NMISx Mojolicious app (Mojolicious::Plugin::CGI) as a real,
# logged-in, group-restricted user, and asserts the behaviour: a node or group
# the user may not see is refused, one the user may see is not.
#
# The pattern and the rules it follows are documented in docs/CGI_TESTING.md.
# The decision logic itself (graph_refusal, visible_groups) is unit-tested in
# t_auth_graph_refusal.t. This file covers the wiring end-to-end, which the unit
# test cannot see.
#
# The two endpoints refuse differently, and the assertions match that:
#   node.pl typeGraph prints a visible "Not Authorized ..." message, read
#     straight from the response body.
#   rrddraw.pl routes a refusal through the same generic error() as a draw
#     failure. The body is identical either way ("Network: ERROR on getting
#     graph" / "Request not found"), on purpose, so a caller cannot tell refusal
#     from a missing graph. The only in-band signal is the log: a refusal logs
#     "not authorised, refused on <what>"; a request that clears the gate and
#     then fails to draw logs "rrddraw failed:". So rrddraw is checked by reading
#     the nmis log around each request. An authorised request logging no refusal
#     is the positive control that proves the gate discriminates by
#     authorisation rather than refusing everything.
#
# Needs a reachable MongoDB and the NMISx app, i.e. the dev container; it skips
# cleanly elsewhere. Seeds two nodes (one in a group the test user may see, one
# in a group it may not) and a group-restricted user, all isolated in the
# untracked conf/ overrides and removed on exit.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Mojo;
use File::Copy;
use Crypt::PasswdMD5;    # apache_md5_crypt, a flavour Auth::_file_verify accepts
use Mojo::Util qw(url_escape);

use NMISNG;
use NMISNG::Log;
use NMISNG::Node;
use NMISNG::Util;

# --- identifiers ------------------------------------------------------------
my $GRP_OK    = 'GraphAuthzSeen';           # the test user is a member
my $GRP_DENY  = 'GraphAuthzUnseen';         # the test user is NOT a member
my $NODE_OK   = 'graphauthz_node_seen';     # lives in $GRP_OK
my $NODE_DENY = 'graphauthz_node_unseen';   # lives in $GRP_DENY
my $USER      = 'graphauthz_ro';
my $PASS      = 'graphauthz_pw';
# a second, lower-privilege account for the global-graph gate. 'operator' is
# PrivMap level 3 and Access.nmis grants tls_nmis_runtime at level3, 'guest' is
# level 4 and is denied, so the pair straddles that one right.
my $GUEST     = 'graphauthz_guest';
my $GUESTPASS = 'graphauthz_gpw';

# --- prerequisites ----------------------------------------------------------
my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});

my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = eval { NMISNG->new(config => $C, log => $logger) };
plan skip_all => "NMISNG object required: $@" if ($@ || !$nmisng);
# a configured db_name does not mean the server answers. probe once, and skip
# rather than die when it does not (a bare host with no reachable MongoDB).
eval { $nmisng->get_group_names; 1 }
	or plan skip_all => "MongoDB not reachable: $@";

# files the forked CGI will read. these are the untracked conf/ overrides, never
# the tracked conf-default templates.
my $confdir  = $C->{'<nmis_conf>'} || "$FindBin::Bin/../conf";
my $USERSTAB = "$confdir/Users.nmis";
my $HTPASSWD = $C->{auth_htpasswd_file} || "$confdir/users.dat";
my $LOGFILE  = ($C->{'<nmis_logs>'} || "$FindBin::Bin/../logs") . "/nmis.log";

plan skip_all => "conf dir not writable for user seeding ($confdir)" unless (-w $confdir);

# --- cleanup registered up front, so a mid-setup skip still tears down -------
my (@restore, @remove, @seeded);
END {
	for my $n (@seeded) {
		next unless $n;
		eval { $n->delete(keep_rrd => 1); 1 } or diag("WARNING: could not remove seed node");
	}
	# restore backed-up files, then remove files we created from a template
	copy($_->[0], $_->[1]) && unlink($_->[0]) for (@restore);
	unlink($_) for (@remove);
}

# seed a file we must edit: back it up if it exists, otherwise create it from a
# template. records the undo action for END. returns 1 on success, 0 if neither
# the file nor a template is present.
sub seed_file {
	my ($path, $editor, $template) = @_;
	if (-f $path) {
		my $bak = "$path.graphauthzbak";
		copy($path, $bak) or die "backup $path: $!";
		push @restore, [$bak, $path];
	} elsif ($template && -f $template) {
		copy($template, $path) or die "seed $path from $template: $!";
		push @remove, $path;
	} else {
		return 0;
	}
	$editor->($path);
	return 1;
}

# --- seed the group-restricted user -----------------------------------------
# users.dat is htpasswd (user:crypted). _file_verify tries crypt then
# apache_md5_crypt, so this hash is accepted regardless of auth_htpasswd_encrypt.
my $hash  = apache_md5_crypt($PASS, 'gzsalt');
my $ghash = apache_md5_crypt($GUESTPASS, 'gzsalt');
my $htok = seed_file($HTPASSWD, sub {
	my ($p) = @_;
	open(my $fh, '>>', $p) or die "append $p: $!";
	print $fh "$USER:$hash\n";
	print $fh "$GUEST:$ghash\n";
	close $fh;
});

# Users.nmis carries groups + privilege. a single group (not 'all') keeps
# Auth::SetGroups from setting all_groups_allowed, so the boundary is real.
my $utok = seed_file($USERSTAB, sub {
	my ($p) = @_;
	open(my $in, '<', $p) or die "read $p: $!";
	local $/; my $txt = <$in>; close $in;
	my $rec = "  '$USER' => { 'user' => '$USER', 'groups' => '$GRP_OK', 'privilege' => 'operator' },\n"
			. "  '$GUEST' => { 'user' => '$GUEST', 'groups' => '$GRP_OK', 'privilege' => 'guest' },\n";
	($txt =~ s/(%hash\s*=\s*\(\s*\n)/$1$rec/)
		or ($txt =~ s/(%hash\s*=\s*\()/$1\n$rec/)
		or die "could not find %hash in $p";
	open(my $out, '>', $p) or die "write $p: $!";
	print $out $txt; close $out;
}, "$FindBin::Bin/../conf-default/Users.nmis");

plan skip_all => "could not seed conf/Users.nmis + conf/users.dat"
	unless ($htok && $utok);

# --- seed the two nodes -----------------------------------------------------
sub seed_node {
	my ($name, $group) = @_;
	my $old = $nmisng->node(name => $name);
	$old->delete(keep_rrd => 1) if ($old);

	my $n = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$n->cluster_id($C->{cluster_id});
	$n->name($name);
	$n->configuration({
		host => '127.0.0.1', group => $group, netType => 'default',
		roleType => 'default', model => 'automatic',
		active => 'true', collect => 'false', ping => 'false',
	});
	$n->activated({ NMIS => 1 });   # get_group_names filters on activated.NMIS=1
	my ($op, $err) = $n->save();
	BAIL_OUT("could not seed node $name: $err") if ($err);
	return $n;
}
# register each node the moment it is created, so a failure seeding the second
# still leaves the first on the cleanup list
push @seeded, seed_node($NODE_OK, $GRP_OK);
push @seeded, seed_node($NODE_DENY, $GRP_DENY);

# --- boot the app and authenticate as the restricted user -------------------
my $t = eval { Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

# log in without emitting a test point, so we can still skip if the auth backend
# is not htpasswd (a seeded user cannot log in then, and that is an environment
# mismatch, not a failure of the code under test)
$t->ua->post('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $USER, auth_password => $PASS });
my $logged_in = grep { $_->name =~ /CGISESSID|nmis|omk/ } @{$t->ua->cookie_jar->all};
plan skip_all => "could not authenticate seeded user '$USER' (auth backend not htpasswd?)"
	unless $logged_in;

# whether the log-based rrddraw checks can run at all
my $log_readable = (-r $LOGFILE);

# read the nmis log appended since byte offset $from
sub log_since {
	my ($from) = @_;
	return '' unless (-r $LOGFILE);
	open(my $fh, '<', $LOGFILE) or return '';
	seek($fh, $from, 0);
	local $/; my $chunk = <$fh>; close $fh;
	return $chunk // '';
}
sub log_size { return (-e $LOGFILE) ? -s _ : 0; }

pass("authenticated as group-restricted user '$USER'");

# ---------------------------------------------------------------------------
# node.pl typeGraph: refusal is visible in the body
# ---------------------------------------------------------------------------
subtest 'node.pl refuses a node in a group the user may not see' => sub {
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=$NODE_DENY&graphtype=health&widget=false");
	is($t->tx->res->code, 200, 'node.pl responded');
	like($t->tx->res->body // '', qr/Not Authorized/,
		'refused: node in an unseen group');
};

subtest 'node.pl allows a node in a group the user may see (positive control)' => sub {
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=$NODE_OK&graphtype=health&widget=false");
	is($t->tx->res->code, 200, 'node.pl responded');
	unlike($t->tx->res->body // '', qr/Not Authorized/,
		'allowed: node in a seen group clears the gate');
};

subtest 'node.pl refuses a seen node laundering an unseen group (metrics)' => sub {
	# graphtype=metrics resolves by group, so a node the user may see must not be
	# usable to reach a group the user may not. graph_refusal checks both.
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=$NODE_OK&group=$GRP_DENY&graphtype=metrics&widget=false");
	like($t->tx->res->body // '', qr/Not Authorized/,
		'refused on the unseen group even though the node is seen');
};

subtest 'node.pl refuses metrics with an empty group, which promotes to network' => sub {
	# hole #3: an empty group on a metrics graph is promoted to the 'network'
	# pseudo-group, whose rrd is the global rollup. the promotion must happen
	# before the decision, so the seeded operator (not a member of 'network')
	# is refused rather than reaching every group's data.
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=&group=&graphtype=metrics&widget=false");
	like($t->tx->res->body // '', qr/Not Authorized/,
		'refused: empty group on metrics does not reach the network rollup');
	like($t->tx->res->body // '', qr/group 'network'/,
		'refused on the promoted group, so promotion precedes the decision');
};

subtest 'node.pl refuses a regex-shaped node name (parity with rrddraw)' => sub {
	# node.pl resolves the group by literal lookup in $NT, so a pattern matches
	# no entry. asserted so the two gates cannot drift apart again.
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=" . url_escape("regex:^$NODE_OK\$")
		. "&graphtype=health&widget=false");
	like($t->tx->res->body // '', qr/Not Authorized/,
		'a regex-shaped name is not resolved to a node');
};

# ---------------------------------------------------------------------------
# rrddraw.pl: refusal is byte-identical to a draw failure, so read the log
# ---------------------------------------------------------------------------
SKIP: {
	skip "nmis log not readable ($LOGFILE), cannot verify rrddraw in-band", 6
		unless $log_readable;

	subtest 'rrddraw.pl denial log cannot be forged with CR/LF in a node name' => sub {
		# filter_params entity-encodes but leaves CR and LF, so the refusal log
		# runs the identifiers through NMISNG::Util::sanitise_log_line, which
		# collapses a run of control characters to one space (OMK-12731)
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=" . url_escape("crlf\r\nFORGEDLINE")
			. "&graphtype=health&width=400&height=150");
		my $log = log_since($off);
		like($log, qr/node='crlf FORGEDLINE'/,
			'the CR/LF run is flattened to one space, not emitted raw');
		unlike($log, qr/^FORGEDLINE/m,
			'the payload cannot start a log line of its own');
	};

	subtest 'rrddraw.pl refuses metrics with an empty group' => sub {
		# rrddraw deliberately does not promote an empty group, so the request
		# names nothing and is refused on 'none'. tighter than node.pl, and
		# asserted so the divergence stays deliberate.
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=&group=&graphtype=metrics&width=400&height=150");
		my $log = log_since($off);
		like($log, qr/not authorised, refused on none/,
			'a request naming neither node nor group is refused outright');
	};

	subtest 'rrddraw.pl refuses a node in a group the user may not see' => sub {
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=$NODE_DENY&graphtype=health&width=400&height=150");
		my $log = log_since($off);
		like($log, qr/not authorised, refused on/, 'rrddraw logged a refusal');
		like($log, qr/node='\Q$NODE_DENY\E'/, 'refusal names the unseen node');
		unlike($t->tx->res->headers->content_type // '', qr{image/},
			'no graph image returned to an unauthorised caller');
	};

	subtest 'rrddraw.pl lets a seen node through the gate (positive control)' => sub {
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=$NODE_OK&graphtype=health&width=400&height=150");
		my $log = log_since($off);
		unlike($log, qr/not authorised, refused on[^\n]*node='\Q$NODE_OK\E'/,
			'no refusal logged for a seen node: the gate passed it through');
	};

	subtest 'rrddraw.pl refuses a seen node laundering an unseen group (metrics)' => sub {
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=$NODE_OK&group=$GRP_DENY&graphtype=metrics&width=400&height=150");
		my $log = log_since($off);
		like($log, qr/not authorised, refused on group/,
			'refused on the unseen group even though the node is seen');
	};

	subtest 'rrddraw.pl refuses a regex-shaped node name instead of resolving it' => sub {
		# a name is an exact identifier, not a pattern: get_query_part turns a
		# leading 'regex:' into a Mongo $regex (DB.pm:1265). anchored on $NODE_OK
		# deliberately, so an unfixed gate resolves a node the user MAY see and
		# allows the draw, making this fail without the '$eq' in node_group().
		my $off = log_size();
		$t->get_ok("/cgi-nmis9/rrddraw.pl?conf=Config&act=draw_graph_view"
			. "&node=" . url_escape("regex:^$NODE_OK\$")
			. "&graphtype=health&width=400&height=150");
		my $log = log_since($off);
		like($log, qr/not authorised, refused on node/,
			'a regex-shaped name resolves to no node and is refused');
		unlike($t->tx->res->headers->content_type // '', qr{image/},
			'no graph image returned for a pattern-shaped node name');
	};
}

# ---------------------------------------------------------------------------
# the global-graph gate. graphtype=nmis names no node and no group, so it is
# authorised on tls_nmis_runtime alone via allow_global. the round-1 regression
# was a blanket refusal that broke network.pl's runtime drill-in link.
# ---------------------------------------------------------------------------
subtest 'node.pl allows graphtype=nmis for a user holding tls_nmis_runtime' => sub {
	$t->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
		. "&node=&group=&graphtype=nmis&widget=false");
	unlike($t->tx->res->body // '', qr/Not Authorized/,
		'the runtime drill-in is not refused for an operator');
};

SKIP: {
	my $g = eval { Test::Mojo->new('NMISx') };
	skip "second Mojo app instance unavailable", 1 unless $g;
	$g->ua->post('/cgi-nmis9/nmiscgi.pl' => form =>
		{ conf => 'Config', auth_username => $GUEST, auth_password => $GUESTPASS });
	skip "could not authenticate seeded guest '$GUEST'", 1
		unless (grep { $_->name =~ /CGISESSID|nmis|omk/ } @{$g->ua->cookie_jar->all});

	subtest 'node.pl refuses graphtype=nmis without tls_nmis_runtime' => sub {
		$g->get_ok("/cgi-nmis9/node.pl?conf=Config&act=network_graph_view"
			. "&node=&group=&graphtype=nmis&widget=false");
		like($g->tx->res->body // '', qr/Not Authorized to view the NMIS runtime graph/,
			'guest is refused on the access right, before the group gate');
	};
}

# ---------------------------------------------------------------------------
# narrow anti-drift check on node.pl's wiring. the endpoint tests above cover
# the behaviour; these pin the two parts a refactor could silently invert
# without failing anything. docs/CGI_TESTING.md sanctions a check this narrow.
# ---------------------------------------------------------------------------
subtest 'node.pl wiring: allow_global stays conditional, promotion precedes the gate' => sub {
	my $src = "$FindBin::Bin/../cgi-bin/node.pl";
	open(my $fh, '<', $src) or do { plan skip_all => "cannot read $src"; return };
	local $/; my $txt = <$fh>; close $fh;

	# both halves: the argument is still passed, and passed conditionally.
	# dropping it altogether is caught behaviourally by the graphtype=nmis pair
	like($txt, qr/allow_global\s*=>\s*\$wantglobal\b/,
		'allow_global is passed, wired to $wantglobal');
	unlike($txt, qr/allow_global\s*=>\s*1\b/,
		'allow_global is never passed as a literal 1');

	my $promote = index($txt, "\$wantgroup = 'network'");
	my $gate    = index($txt, 'graph_refusal');
	cmp_ok($promote, '>', -1, 'found the metrics group promotion');
	cmp_ok($gate,    '>', -1, 'found the graph_refusal call');
	cmp_ok($promote, '<', $gate,
		'promotion happens before the authorisation decision');
};

done_testing();
