#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Stored-XSS output-escaping regression test for the NMIS9 CGI GUI (OMK-12702
# group). Seeds a node whose collected/config fields carry XSS markers, drives
# the real CGI scripts in-process through the NMISx Mojolicious app (which serves
# cgi-bin via Mojolicious::Plugin::CGI) using a real authenticated session, and
# asserts every marker is rendered HTML-escaped, never as live markup.
#
# Covered sinks (all via the real CGI, real session):
#   find.pl node search      - group, host, services            (OMK-12702)
#   find.pl interface search - ifDescr                          (OMK-12702)
#   network.pl node summary  - group, sysDescr, nodeVendor,
#                              sysObjectName                     (OMK-12702)
#   network.pl interface view- ifDescr, Description             (OMK-12702)
# The Modules-table / login-page sinks (OMK-12703) have their own unit coverage
# in t_xss_modules_render.pl.
#
# Requires a reachable MongoDB (uses the configured database, same as the CGIs)
# and the NMISx Mojo app - i.e. the dev container; it skips cleanly elsewhere.
# Seeds and removes one node; temporarily patches community_rss_url in the
# untracked conf/ override (always restored on exit). Authenticates as a throwaway
# administrator it seeds in the untracked conf/ (OMK-12688 removed the shipped
# nmis/nm1888 default credential) rather than disabling auth. The modules.pl
# start_html(-xbase) sink has its own fail-without-fix regression in
# t_cgi_modules_xbase.t.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Mojo;
use File::Copy;
use Crypt::PasswdMD5 qw(apache_md5_crypt);

use NMISNG;
use NMISNG::Log;
use NMISNG::Node;
use NMISNG::Util;

my $NODENAME = "xss_test_node";

# Each marker renders as <img src=x onerror=xTOKEN> so a hit is traceable to the
# field it came from. Escaped form is &lt;img src=x onerror=xTOKEN&gt;.
sub payload  { my $tok = shift; return "<img src=x onerror=$tok>"; }
sub esc_form { my $tok = shift; return "&lt;img src=x onerror=$tok&gt;"; }

# community_rss.pl interpolates community_rss_url into a JS string inside <script>.
# Seed a hostile value before the config is loaded (so the parent cache and the
# forked CGI both see it), restored in END. Seed the UNTRACKED conf/Config.nmis
# override, never the tracked conf-default: a hard kill can then only leave an
# untracked file behind, and the override wins over the shipped default anyway.
# The seed is skipped entirely when conf/ is absent (bare host), so it never runs
# ahead of the skip_all guards below on a machine that cannot run this test.
my $CFGFILE = "$FindBin::Bin/../conf/Config.nmis";
my $CFGBAK;
my $RSS_RAW = 'https://evil/"</script>';    # breaks a JS string and <script> if raw
my $RSS_ESC = 'https://evil/\"<\/script>';  # correct JS-string-escaped form
if (-f $CFGFILE) {
	$CFGBAK = "$CFGFILE.xssbak";
	copy($CFGFILE, $CFGBAK);
	open(my $in, '<', $CFGFILE); local $/; my $txt = <$in>; close $in;
	if ($txt =~ /'community_rss_url'\s*=>/) {
		$txt =~ s{('community_rss_url'\s*=>\s*)'[^']*'}{$1'$RSS_RAW'};
	} else {
		$txt =~ s{('system'\s*=>\s*\{)}{$1\n    'community_rss_url' => '$RSS_RAW',};
	}
	open(my $out, '>', $CFGFILE); print $out $txt; close $out;
}

END {
	if ($CFGBAK && -f $CFGBAK) { copy($CFGBAK, $CFGFILE); unlink $CFGBAK; }
}

# ---- seed a throwaway administrator ----------------------------------------
# OMK-12688 removed the shipped nmis/nm1888 default credential (users.dat now
# ships '*NMIS-UNSEEDED*'), so this test can no longer log in as it. Seed our
# own admin into the UNTRACKED conf/Users.nmis and conf/users.dat, exactly as
# t_csrf_cgi.t does, and authenticate as that. Backed up and restored in END.
# Skipped when conf/ is absent, so it never runs ahead of the skip_all guards.
my $TESTUSER = 'xss_test_admin';
my $TESTPASS = 'xss-test-' . $$;
my $USERSCFG = "$FindBin::Bin/../conf/Users.nmis";
my $USERSDAT = "$FindBin::Bin/../conf/users.dat";
my ($UCFGBAK, $UDATBAK);
if (-f $USERSCFG && -f $USERSDAT) {
	$UCFGBAK = "$USERSCFG.xssbak";
	$UDATBAK = "$USERSDAT.xssbak";
	copy($USERSCFG, $UCFGBAK);
	copy($USERSDAT, $UDATBAK);

	open(my $uin, '<', $USERSCFG) or die "cannot read $USERSCFG: $!";
	my $utxt = do { local $/; <$uin> }; close $uin;
	# a seeding miss must say so, or the account never appears and the run dies at
	# the login assertion, which reads as a product failure, not a fixture one.
	my $seeded = ($utxt =~ s{(\%hash\s*=\s*\()}{$1
  '$TESTUSER' => {
    '_id' => '$TESTUSER',
    'groups' => 'all',
    'privilege' => 'administrator',
    'user' => '$TESTUSER'
  },});
	die "cannot seed $TESTUSER into $USERSCFG: no '%hash = (' found, the file format changed\n"
		if (!$seeded);
	open(my $uout, '>', $USERSCFG) or die "cannot write $USERSCFG: $!";
	print $uout $utxt; close $uout;

	open(my $upw, '>>', $USERSDAT) or die "cannot append to $USERSDAT: $!";
	print $upw $TESTUSER . ":" . apache_md5_crypt($TESTPASS) . "\n"; close $upw;
}

END {
	if ($UCFGBAK && -f $UCFGBAK) { copy($UCFGBAK, $USERSCFG); unlink $UCFGBAK; }
	if ($UDATBAK && -f $UDATBAK) { copy($UDATBAK, $USERSDAT); unlink $UDATBAK; }
}

my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});
plan skip_all => "could not seed the test admin under conf/" unless $UDATBAK;

my $logger = NMISNG::Log->new(level => 'error');
my $nmisng = NMISNG->new(config => $C, log => $logger);
plan skip_all => "NMISNG object required" unless $nmisng;

# ---- seed a node with markers in config + catchall -------------------------

{
	my $old = $nmisng->node(name => $NODENAME);
	$old->delete(keep_rrd => 1) if ($old);
}

my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$node->cluster_id($C->{cluster_id});
$node->name($NODENAME);
$node->configuration({
	host     => payload("xHOST"),
	group    => payload("xGRP"),
	netType  => "default",
	roleType => "default",
	model    => "automatic",
	active   => "true",
	collect  => "true",
	ping     => "false",
	services => [ payload("xSVC") ],
	depend   => [],    # validated as node-name refs; kept empty to avoid a find.pl undef-deref
});
my ($op, $err) = $node->save();
BAIL_OUT("could not save seed node: $err") if ($err);

my ($catchall, $cerr) = $node->inventory(concept => "catchall", model_class => "system", create => 1);
BAIL_OUT("could not create catchall: $cerr") if ($cerr);
my $cd = $catchall->data_live();
$cd->{name}          = $NODENAME;
$cd->{host}          = payload("xHOST");
$cd->{group}         = payload("xGRP");
$cd->{sysDescr}      = payload("xDESC");
$cd->{nodeVendor}    = payload("xVEND");
$cd->{sysObjectName} = payload("xOBJ");
$cd->{sysObjectID}   = "1.2.3.4";
$cd->{sysLocation}   = payload("xLOC");
$cd->{nodeModel}     = payload("xMODEL");
$cd->{nodeType}      = payload("xTYPE");
$catchall->save(node => $node);

# seed one interface (index 1) with markers in ifDescr + Description
my $IFINDEX = 1;
my ($intf, $ierr) = $node->inventory(concept => "interface", path_keys => [$IFINDEX], create => 1);
BAIL_OUT("could not create interface inventory: $ierr") if ($ierr);
$intf->data({
	index         => $IFINDEX,
	ifIndex       => $IFINDEX,
	ifDescr       => payload("xIFD"),
	Description    => payload("xIFDESC"),
	ifType        => payload("xIFT"),
	ifSpeed       => 1000000000,
	ifAdminStatus => "up",
	ifOperStatus  => "up",
	collect       => "true",
});
$intf->enabled(1);
$intf->historic(0);
my ($iop, $ierr2) = $intf->save(node => $node);
BAIL_OUT("could not save interface inventory: $ierr2") if ($ierr2);

diag("seeded node '$NODENAME' with one interface");

# ---- authenticate through the real app -------------------------------------

my $t = eval { Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => $TESTUSER, auth_password => $TESTPASS });
# a real login-success assertion, not just "a session cookie exists" (which is
# true even for a failed login): a failed login re-renders the form with
# "Invalid username/password", and every escaped-marker check below would then
# fail with no obvious cause. Fail loudly here - this is exactly what the old
# cookie-jar check silently missed when OMK-12688 dropped the nmis/nm1888 default.
unlike($t->tx->res->body // '', qr{Invalid username/password},
	"the seeded admin authenticates");

# ---- helper: fetch a page and assert markers are escaped, not raw ----------
sub assert_escaped {
	my ($desc, $url, @tokens) = @_;
	$t->get_ok($url, "$desc: fetched");
	my $code = $t->tx->res->code // 0;
	my $body = $t->tx->res->body // '';
	is($code, 200, "$desc: HTTP 200");
	# adversarial sweep: no seeded marker may survive as live markup anywhere in
	# the response, regardless of which field it came from (catches sibling sinks)
	unlike($body, qr/<img src=x onerror=x/, "$desc: no raw XSS marker survives anywhere");
	for my $tok (@tokens) {
		my $raw = payload($tok);
		my $esc = esc_form($tok);
		ok(index($body, $raw) == -1, "$desc: $tok not present as raw markup");
		ok(index($body, $esc) >= 0,  "$desc: $tok present and HTML-escaped");
	}
}

# ---- the checks ------------------------------------------------------------

# find.pl node search - the node row renders host + group (search matches group)
assert_escaped(
	"find.pl node search",
	'/cgi-nmis9/find.pl?conf=Config&act=find_node_view&find=xGRP&widget=false',
	qw(xGRP xHOST xSVC));

# network.pl node-admin summary - renders group, sysDescr, nodeVendor, sysObjectName
assert_escaped(
	"network.pl node_admin_summary",
	'/cgi-nmis9/network.pl?conf=Config&act=node_admin_summary&widget=false',
	qw(xGRP xDESC xVEND xOBJ xTYPE));

# network.pl interface detail - heading + property table render ifDescr,
# Description and ifType. (ifType is also a node.pl typeGraph sink, but that view
# needs a full model/graph/RRD context to render, beyond this node seed, so it is
# not driven end-to-end; the escaping there is the same escapeHTML pattern.)
assert_escaped(
	"network.pl interface detail",
	"/cgi-nmis9/network.pl?conf=Config&act=network_interface_view&node=$NODENAME&intf=$IFINDEX&widget=false",
	qw(xIFD xIFDESC xIFT));

# find.pl interface search - matches + renders ifDescr
assert_escaped(
	"find.pl interface search",
	'/cgi-nmis9/find.pl?conf=Config&act=find_interface_view&find=xIFD&widget=false',
	qw(xIFD));

# community_rss.pl - config community_rss_url rendered into a JS string in <script>
$t->get_ok('/cgi-nmis9/community_rss.pl?conf=Config&widget=false', "community_rss.pl: fetched");
{
	my $body = $t->tx->res->body // '';
	ok(index($body, $RSS_RAW) == -1, "community_rss.pl: no raw JS-string/script break-out");
	ok(index($body, $RSS_ESC) >= 0,  "community_rss.pl: config URL JS-string-escaped");
}

# modules.pl start_html(-xbase): the fail-without-fix regression for that
# unauthenticated sink lives in t_cgi_modules_xbase.t, which needs a hostile
# <url_base> (global config) and so isolates it in its own process. Not repeated
# here, where a shared <url_base> would corrupt the base URL for every other page.

# do_logout redirect JS (I1): a hostile query string with a literal single quote
# must NOT reach the inline window.location assignment. Run LAST - it clears the
# session. Fails against the old code, which reflected -query=>1 into the JS.
$t->get_ok("/cgi-nmis9/nmiscgi.pl?conf=Config&auth_type=logout&xssq='-alertXSS-'",
	"do_logout: fetched");
{
	my $body = $t->tx->res->body // '';
	unlike($body, qr/'-alertXSS-'/, "do_logout: query not reflected into the redirect JS");
}

# ---- cleanup ---------------------------------------------------------------

END {
	if ($node) {
		my $ok = eval { $node->delete(keep_rrd => 1); 1 };
		diag($ok ? "removed seed node" : "WARNING: could not remove seed node '$NODENAME'");
	}
}

done_testing();
