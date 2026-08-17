#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# OMK-12699: behavioural coverage for the anti-CSRF guard, driven through the
# real CGIs in-process via the NMISx Mojolicious app against a real
# authenticated session. t_csrf.t covers the Auth.pm layer in isolation and
# scans the registry for drift; this file covers what only a live request can
# show, per docs/CGI_TESTING.md:
#
#   - a read act still works by GET, with no token          (positive control)
#   - a write act by GET is refused                         (the img-tag attack)
#   - a write act by POST with no token is refused          (the cross-site form)
#   - a write act by POST with a valid token passes the guard
#   - a write act by GET WITH a valid token is still refused (POST-only control,
#     which the unit tests cannot separate from the token check)
#   - an act-less read URL, as the menu links it, is not classified as a write
#   - a converted mutation form is not nested inside another form
#
# Requires a reachable MongoDB and the NMISx app, i.e. the dev container; it
# skips cleanly elsewhere. Seeds its own throwaway administrator in the
# UNTRACKED conf/Users.nmis and conf/users.dat rather than depending on any
# installed account's password, and seeds one outage. All three are backed up
# and restored, or removed, in END.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Copy;
use Crypt::PasswdMD5 qw(apache_md5_crypt);

my $TESTUSER = 'csrf_test_admin';
my $TESTPASS = 'csrf-test-' . $$;

my $CONFDIR  = "$FindBin::Bin/../conf";
my $USERSCFG = "$CONFDIR/Users.nmis";
my $USERSDAT = "$CONFDIR/users.dat";

# ---- seed the throwaway account --------------------------------------------
# Done before the config is loaded and before the app boots, so the parent and
# the forked CGI both see it. Skipped entirely when conf/ is absent, so it never
# runs ahead of the skip_all guards below on a bare host.

my ($CFGBAK, $DATBAK);
if (-f $USERSCFG && -f $USERSDAT)
{
	$CFGBAK = "$USERSCFG.csrfbak";
	$DATBAK = "$USERSDAT.csrfbak";
	copy($USERSCFG, $CFGBAK);
	copy($USERSDAT, $DATBAK);

	open(my $in, '<', $USERSCFG) or die "cannot read $USERSCFG: $!";
	my $txt = do { local $/; <$in> };
	close $in;
	# a seeding miss must say so. Without this the account never appears and the run
	# dies at the login assertion, which reads as a product failure, not a fixture one.
	my $seeded = ($txt =~ s{(\%hash\s*=\s*\()}{$1
  '$TESTUSER' => {
    '_id' => '$TESTUSER',
    'groups' => 'all',
    'privilege' => 'administrator',
    'user' => '$TESTUSER'
  },});
	die "cannot seed $TESTUSER into $USERSCFG: no '%hash = (' found, the file format changed\n"
		if (!$seeded);

	open(my $out, '>', $USERSCFG) or die "cannot write $USERSCFG: $!";
	print $out $txt;
	close $out;

	open(my $pw, '>>', $USERSDAT) or die "cannot append to $USERSDAT: $!";
	print $pw $TESTUSER . ":" . apache_md5_crypt($TESTPASS) . "\n";
	close $pw;
}

END {
	if ($CFGBAK && -f $CFGBAK) { copy($CFGBAK, $USERSCFG); unlink $CFGBAK; }
	if ($DATBAK && -f $DATBAK) { copy($DATBAK, $USERSDAT); unlink $DATBAK; }
}

require NMISNG::Util;
require NMISNG::Outage;

my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});
plan skip_all => "could not seed the test account under conf/" unless $CFGBAK;

my $t = eval { require Test::Mojo; Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

# ---- seed one outage, so the outages listing renders a delete form ---------

my $OUTAGE_ID;
{
	my $res = NMISNG::Outage::update_outage(frequency => 'once',
											start     => time + 3600,
											end       => time + 7200,
											change_id => 'CSRF-TEST',
											description => 'OMK-12699 test outage',
											selector  => {});
	$OUTAGE_ID = $res->{id} if ($res->{success});
	diag("could not seed an outage: $res->{error}") if (!$OUTAGE_ID);
}

# ---- seed one node, so the tools.pl node lookup has something to resolve ----
# tools.pl reads name and configuration.host through a projected exact-match
# query. Without a node in the collection neither the resolution nor the
# exact-match property below can be driven at all. The host is from the
# documentation range, so asserting on it cannot collide with anything the page
# emits from the config, and no case here sends traffic to it.

my $TESTNODE = 'csrf_tools_test';
my $TESTHOST = '192.0.2.77';
my $NODE_SEEDED;
my $NODE_CREATED;
{
	require Compat::NMIS;
	require NMISNG::Node;

	my $ng  = Compat::NMIS::new_nmisng();
	my $old = $ng->node(name => $TESTNODE);
	if ($old)
	{
		my ($ok, $derr) = $old->delete(keep_rrd => 1);
		diag("leftover $TESTNODE not removed, this run may collide: "
			 . ($derr // 'unknown error')) if (!$ok);
	}

	my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
	$node->cluster_id($C->{cluster_id});
	$node->name($TESTNODE);
	$node->configuration({ host => $TESTHOST, group => 'CSRFTest', netType => 'default',
						   roleType => 'default', model => 'automatic', active => 'true',
						   collect => 'false', ping => 'false', services => [], depend => [] });
	my (undef, $err) = $node->save();
	if ($err)
	{
		diag("could not seed node $TESTNODE: $err");
	}
	else
	{
		# the node is in the collection from here, so END must remove it even if
		# the catchall below fails.
		$NODE_CREATED = 1;

		my ($catchall, $cerr) = $node->inventory(concept => 'catchall',
												 model_class => 'system', create => 1);
		if ($cerr)
		{
			diag("could not create catchall for $TESTNODE: $cerr");
		}
		else
		{
			my $cd = $catchall->data_live();
			@{$cd}{qw(name host group)} = ($TESTNODE, $TESTHOST, 'CSRFTest');
			# save returns ($op, $error), op is 0 or negative on failure
			my ($op, $serr) = $catchall->save(node => $node);
			if (!defined($op) or $op <= 0)
			{
				diag("could not save catchall for $TESTNODE: " . ($serr // 'unknown error'));
			}
			else
			{
				$NODE_SEEDED = 1;
			}
		}
	}
}

END {
	NMISNG::Outage::remove_outage(id => $OUTAGE_ID) if ($OUTAGE_ID);

	if ($NODE_CREATED)
	{
		my $gone = Compat::NMIS::new_nmisng()->node(name => $TESTNODE);
		if ($gone)
		{
			my ($ok, $derr) = $gone->delete(keep_rrd => 1);
			diag("could not remove $TESTNODE, residue left behind: "
				 . ($derr // 'unknown error')) if (!$ok);
		}
	}

	# the window-state case below writes the test user's own key; drop it again
	my $wsfile = ($C && $C->{'<nmis_var>'}) ? $C->{'<nmis_var>'} . '/nmis-windowstate.json' : undef;
	if ($wsfile && -f $wsfile)
	{
		my ($all, $fh) = NMISNG::Util::readFiletoHash(file => $wsfile, json => 'true', lock => 'true');
		if ($fh)
		{
			delete $all->{$TESTUSER};
			NMISNG::Util::writeTable(dir => 'var', name => "nmis-windowstate",
									 data => $all, handle => $fh);
		}
	}
}

# ---- authenticate as the seeded account ------------------------------------

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $TESTUSER, auth_password => $TESTPASS });
unlike($t->tx->res->body // '', qr/Invalid username\/password/,
	   'the seeded test account authenticates');

# the guard's refusal is a bare text/plain body, distinct from every other
# failure the CGIs can produce, so it is the disambiguator for every case below
my $REFUSAL = qr/failed its CSRF check/;

sub fetch
{
	my ($method, $url, $form) = @_;

	if ($method eq 'POST') { $t->post_ok($url => form => ($form // {})); }
	else                   { $t->get_ok($url); }
	return ($t->tx->res->code // 0, $t->tx->res->body // '');
}

# ---- positive control: a read act still works by GET, no token -------------

my $TOKEN;
{
	my ($code, $body) = fetch(GET =>
		'/cgi-nmis9/tables.pl?conf=Config&act=config_table_view&table=Contacts&widget=false');
	is($code, 200, 'a read act by GET returns 200');
	unlike($body, $REFUSAL, 'a read act by GET is not refused');
	unlike($body, qr/Invalid username\/password/, 'and the session is live, not the login page');

	# every converted form carries the token, so scrape one to drive the cases below
	($TOKEN) = $body =~ /name="csrf_token"\s+value="([^"]+)"/;
	ok($TOKEN, 'the read page renders a CSRF token to submit with');
}

# ---- the three refusals ----------------------------------------------------

{
	my ($code, $body) = fetch(GET =>
		'/cgi-nmis9/tables.pl?conf=Config&act=config_table_dodelete&table=Contacts&key=nosuchkey&widget=false');
	is($code, 403, 'a write act by GET is refused with 403');
	like($body, $REFUSAL, 'and refused by the CSRF guard, not by something else');
}

{
	my ($code, $body) = fetch(POST => '/cgi-nmis9/tables.pl',
		{ conf => 'Config', act => 'config_table_dodelete',
		  table => 'Contacts', key => 'nosuchkey', widget => 'false' });
	is($code, 403, 'a write act by POST with no token is refused with 403');
	like($body, $REFUSAL, 'and refused by the CSRF guard');
}

# the POST-only control on its own. Every other refusal above also lacks a
# token, so only this case fails if the method check is removed.
SKIP: {
	skip "no token scraped", 2 if (!$TOKEN);

	my ($code, $body) = fetch(GET =>
		'/cgi-nmis9/tables.pl?conf=Config&act=config_table_dodelete'
		. '&table=Contacts&key=nosuchkey&widget=false&csrf_token=' . $TOKEN);
	is($code, 403, 'a write act by GET is refused even with a valid token');
	like($body, $REFUSAL, 'and refused by the CSRF guard');
}

# ---- the positive case: POST plus a valid token passes the guard -----------
# The act targets a key that does not exist, so the guard is what is under test,
# not the handler behind it. Passing the guard is proven by the absence of the
# refusal body, which no other failure produces.
SKIP: {
	skip "no token scraped", 1 if (!$TOKEN);

	my (undef, $body) = fetch(POST => '/cgi-nmis9/tables.pl',
		{ conf => 'Config', act => 'config_table_dodelete', table => 'Contacts',
		  key => 'nosuchkey_omk12699', widget => 'false', csrf_token => $TOKEN });
	unlike($body, $REFUSAL, 'a write act by POST with a valid token passes the guard');
}

# ---- act-less read URLs, exactly as the menu links them --------------------
# menu.pl links these with no act at all and both scripts treat a missing act as
# their read view, so the guard must not classify them as writes.

for my $script (qw(model_policy.pl models.pl))
{
	my ($code, $body) = fetch(GET => "/cgi-nmis9/$script?conf=Config&widget=false");
	unlike($body, $REFUSAL, "$script with no act is not refused as a write");
	is($code, 200, "$script with no act returns 200");
}

# ---- converted mutation forms must not be nested ---------------------------
# outages.pl renders a delete form per row. Those rows used to be printed inside
# the still-open add form, which browsers repair unpredictably: the delete form
# never reaches the DOM and its hidden act/csrf_token associate with the add
# form instead, so both actions break whenever an outage exists.

sub max_form_depth
{
	my $html = shift;
	my ($depth, $max) = (0, 0);
	while ($html =~ m{<(/?)form\b}gi)
	{
		if ($1) { $depth-- if ($depth > 0); }
		else    { $depth++; $max = $depth if ($depth > $max); }
	}
	return $max;
}

# ---- the window-state write, which has no form behind it -------------------
# menu.pl used to dispatch this on a raw JSON body existing, invisible to an
# act-based registry. It is now an ordinary guarded act, with the token carried
# in the menu markup for the JS to pick up.

{
	my ($code, $body) = fetch(GET => '/cgi-nmis9/menu.pl?act=menu_bar_site');
	is($code, 200, 'the menu bar renders');
	like($body, qr/id="nmis_csrf_token" value="\d+--[0-9a-f]+"/,
		 'and carries a token for the window-state POST to use');
}

{
	my ($code, $body) = fetch(GET =>
		'/cgi-nmis9/menu.pl?act=menu_window_state&windowdata=%7B%22windowData%22%3A%22%22%7D');
	is($code, 403, 'the window-state write by GET is refused');
	like($body, $REFUSAL, 'and refused by the CSRF guard');
}

{
	my (undef, $body) = fetch(POST => '/cgi-nmis9/menu.pl',
		{ act => 'menu_window_state', windowdata => '{"windowData":""}' });
	like($body, $REFUSAL, 'the window-state write by POST with no token is refused');
}

SKIP: {
	skip "no token scraped", 1 if (!$TOKEN);

	my (undef, $body) = fetch(POST => '/cgi-nmis9/menu.pl',
		{ act => 'menu_window_state', csrf_token => $TOKEN,
		  windowdata => '{"windowData":""}' });
	like($body, qr/Success/, 'the window-state write by POST with a valid token succeeds');
}

# ---- the support-archive tool ----------------------------------------------
# collect execs admin/support.pl server-side. The menu still links it by GET,
# which now lands on a confirmation; docollect is the guarded write. The write
# itself is not driven here, because running it would build a real archive.

{
	my ($code, $body) = fetch(GET => '/cgi-nmis9/tools.pl?conf=Config&act=tool_system_docollect&widget=false');
	is($code, 403, 'the support-archive write by GET is refused');
	like($body, $REFUSAL, 'and refused by the CSRF guard');
}

{
	my ($code, $body) = fetch(GET => '/cgi-nmis9/tools.pl?conf=Config&act=tool_system_collect&widget=false');
	is($code, 200, 'the collect confirmation still renders by GET');
	unlike($body, $REFUSAL, 'and is not classified as a write');
	like($body, qr/name="act"\s+value="tool_system_docollect"/,
		 'and offers the write as a POST form');
}

# ---- the tools.pl node lookup ----------------------------------------------
# typeTool resolves name and configuration.host with a projected query. The
# '$eq' in that filter is load-bearing: NMISNG::DB::get_query_part turns a plain
# "regex:..." value into a Mongo pattern, so without it a crafted name resolves
# a different node than the caller asked for. That is the class PR 35 reopened
# once already, so both halves are pinned here.
# "date" is used for the resolving case because it needs no network, and the
# refused case never reaches an exec at all.

SKIP: {
	skip "no node seeded", 6 if (!$NODE_SEEDED);

	{
		my ($code, $body) = fetch(GET => '/cgi-nmis9/tools.pl?conf=Config'
			. "&act=tool_system_date&node=$TESTNODE&widget=false");
		is($code, 200, 'a tool page renders for a known node');
		# the title is the only output the projected query produces. A bare body
		# match passes off the telnet/ssh links createHrButtons renders from the
		# catchall this test seeds, so it survives a broken lookup.
		like($body, qr/for node \Q$TESTNODE\E \(\Q$TESTHOST\E\)/,
			 'and the projected query resolved that node\'s name and host');
		unlike($body, $REFUSAL, 'and a read tool is not classified as a write');
	}

	{
		# a plain name => $node filter would turn this into a Mongo pattern, match
		# the seeded node and hand back its host. The exact-match filter must find
		# nothing, so typeTool falls through to the node-selection form.
		my ($code, $body) = fetch(GET => '/cgi-nmis9/tools.pl?conf=Config'
			. '&act=tool_system_ping&node=regex%3A%5Ecsrf_tools_&widget=false');
		is($code, 200, 'a regex-prefixed node name is answered, not resolved');
		like($body, qr/id="nmisTools"/,
			 'the node-selection form is offered because nothing matched');
		unlike($body, qr/\Q$TESTHOST\E/,
			   'and the crafted name resolved no host at all');
	}
}

SKIP: {
	skip "no outage seeded", 3 if (!$OUTAGE_ID);

	my ($code, $body) = fetch(GET =>
		'/cgi-nmis9/outages.pl?conf=Config&act=outage_table_view&widget=false');
	is($code, 200, 'the outages page renders');
	like($body, qr/outagedel_\Q$OUTAGE_ID\E/, 'and lists a delete form for the seeded outage');
	is(max_form_depth($body), 1, 'no mutation form is nested inside another form');
}

done_testing();
