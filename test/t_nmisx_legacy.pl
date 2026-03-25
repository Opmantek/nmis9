#!/usr/bin/perl
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('NMISx');
my $auth = "auth_username=nmis&auth_password=nm1888";

# All routes grouped by their configuration variant
my @tests = (
	# No-auth routes
	{ name => "no-auth: modules.pl",        url => "/cgi-nmis9/modules.pl" },
	{ name => "no-auth: community_rss.pl",   url => "/cgi-nmis9/community_rss.pl" },

	# Auth routes (no nmisng)
	{ name => "auth: access.pl",        url => "/cgi-nmis9/access.pl?$auth&act=access_menu_load" },
	{ name => "auth: find.pl",          url => "/cgi-nmis9/find.pl?$auth" },
	{ name => "auth: ip.pl",            url => "/cgi-nmis9/ip.pl?$auth" },
	{ name => "auth: menu.pl",          url => "/cgi-nmis9/menu.pl?$auth" },
	{ name => "auth: model_policy.pl",  url => "/cgi-nmis9/model_policy.pl?$auth" },
	{ name => "auth: models.pl",        url => "/cgi-nmis9/models.pl?$auth" },
	{ name => "auth: setup.pl",         url => "/cgi-nmis9/setup.pl?$auth" },

	# Auth + nmisng routes
	{ name => "auth+nmisng: events.pl",     url => "/cgi-nmis9/events.pl?$auth&act=event_table_list" },
	{ name => "auth+nmisng: logs.pl",       url => "/cgi-nmis9/logs.pl?$auth" },
	{ name => "auth+nmisng: nmiscgi.pl",    url => "/cgi-nmis9/nmiscgi.pl?$auth" },
	{ name => "auth+nmisng: nodeconf.pl",   url => "/cgi-nmis9/nodeconf.pl?$auth" },
	{ name => "auth+nmisng: outages.pl",    url => "/cgi-nmis9/outages.pl?$auth" },
	{ name => "auth+nmisng: services.pl",   url => "/cgi-nmis9/services.pl?$auth" },
	{ name => "auth+nmisng: snmp.pl",       url => "/cgi-nmis9/snmp.pl?$auth" },
	{ name => "auth+nmisng: tools.pl",      url => "/cgi-nmis9/tools.pl?$auth" },
	{ name => "auth+nmisng: view-event.pl", url => "/cgi-nmis9/view-event.pl?$auth" },

	# Auth + allow_cli + nmisng routes
	{ name => "auth+cli+nmisng: network.pl",   url => "/cgi-nmis9/network.pl?$auth" },
	{ name => "auth+cli+nmisng: node.pl",      url => "/cgi-nmis9/node.pl?$auth&act=network_node_view", status => 400 },
	{ name => "auth+cli+nmisng: opstatus.pl",  url => "/cgi-nmis9/opstatus.pl?$auth" },
	{ name => "auth+cli+nmisng: reports.pl",   url => "/cgi-nmis9/reports.pl?$auth" },
	{ name => "auth+cli+nmisng: rrddraw.pl",  url => "/cgi-nmis9/rrddraw.pl?$auth" },

	# Auth + allow_cli + set_user routes
	{ name => "auth+cli+setuser: config.pl", url => "/cgi-nmis9/config.pl?$auth&act=config_nmis" },
	{ name => "auth+cli+setuser+nmisng: tables.pl", url => "/cgi-nmis9/tables.pl?$auth&act=config_table_list" },
);

for my $test (@tests) {
	subtest $test->{name} => sub {
		my $expected_status = $test->{status} // 200;
		$t->get_ok($test->{url})
			->status_is($expected_status);
		$t->content_type_like(qr{text/html|image/}, "valid content type");
		my $body = $t->tx->res->body;
		ok(length($body) > 0, "non-empty response body");
		unlike($body, qr/Can't locate|Undefined subroutine|compilation error|syntax error/i,
			"no perl errors in response");
	};
}

# Unknown script returns 404
subtest "unknown script returns 404" => sub {
	$t->get_ok("/cgi-nmis9/nonexistent.pl")
		->status_is(404);
};

# Auth failure does not crash the worker (no 500)
subtest "auth failure does not crash" => sub {
	$t->get_ok("/cgi-nmis9/events.pl?auth_username=bad&auth_password=bad")
		->status_isnt(500);
};

done_testing();
