#!/usr/bin/perl
#
# Tests for OMK-12706: NMISNG::Auth::graph_refusal and visible_groups.
#
# graph_refusal is the shared authorisation decision for graph requests, used
# by cgi-bin/rrddraw.pl and cgi-bin/node.pl. Before OMK-12706 rrddraw.pl had no
# check at all, and node.pl used if(node)/elsif(group), which skipped the group
# whenever a node was supplied.
#
# That skip mattered because rrdfunc::draw sets $item = $mygroup for
# graphtype=metrics (lib/NMISNG/rrdfunc.pm:995-998) and the rrd template is
# '/metrics/$item.rrd' (models-default/Common-database.nmis:163). A metrics
# graph therefore resolves by group alone, so a node the user may see could be
# paired with a group they may not, and the group's data was returned. The
# 'laundering' subtest below is that case.
#
# These are behavioural tests against the shipped module. NMISNG::Auth is
# constructed with a minimal config and the session fields InGroup reads
# (Auth.pm:1880-1908) are injected, so no config file, user account or
# database is needed.
#
# Structural wiring of the two call sites is covered by t_graph_authz.t.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

eval { require NMISNG::Auth };
BAIL_OUT("NMISNG::Auth not loadable - cannot verify security test: $@") if ($@);

# a group-restricted user; returns a fresh object so subtests cannot leak state
sub restricted_user
{
    my (@groups) = @_;
    my $au = NMISNG::Auth->new(conf => { auth_require => 1 });
    die "NMISNG::Auth->new returned nothing" if (!$au);
    $au->{user}               = 'dc_ops';
    $au->{groups}             = [@groups];
    $au->{all_groups_allowed} = 0;
    return $au;
}

# ---------------------------------------------------------------------------
# 1. visible_groups filters the supplied names through InGroup
# ---------------------------------------------------------------------------
subtest 'visible_groups keeps only groups the user may see' => sub {
    my $au = restricted_user('DataCentre', 'Campus');

    my $GT = $au->visible_groups(qw(DataCentre Campus Branches Cloud));
    is(ref($GT), 'HASH', 'returns a hashref');
    is_deeply([sort keys %$GT], ['Campus', 'DataCentre'],
        'only the user\'s groups survive');
    is($GT->{DataCentre}, 'DataCentre',
        'table is keyed by name with the name as value, as node.pl expects');

    is_deeply($au->visible_groups(), {}, 'no group names yields an empty table');

    # an all-groups account keeps everything
    $au->{all_groups_allowed} = 1;
    is_deeply([sort keys %{$au->visible_groups(qw(Branches Cloud))}],
        ['Branches', 'Cloud'], 'all-groups account sees every supplied group');
};

# ---------------------------------------------------------------------------
# 2. node identifiers
# ---------------------------------------------------------------------------
subtest 'graph_refusal: node identifiers' => sub {
    my $au = restricted_user('DataCentre');
    my $GT = { DataCentre => 'DataCentre', Branches => 'Branches' };
    my %base = (grouptable => $GT);

    is($au->graph_refusal(%base, node => 'mine', node_group => 'DataCentre'),
        undef, 'own-group node is allowed');
    is($au->graph_refusal(%base, node => 'theirs', node_group => 'Branches'),
        'node', 'out-of-group node is refused');
    is($au->graph_refusal(%base, node => 'mine', node_group => 'NoSuchGroup'),
        'node', 'node in a group absent from the group table is refused');

    # a node the caller could not resolve - unknown to the database, or a node
    # row carrying no group - arrives as an undef node_group either way
    is($au->graph_refusal(%base, node => 'nosuchnode', node_group => undef),
        'node', 'unresolved node group is refused (fails closed)');
    is($au->graph_refusal(%base, node => 'mine'), 'node',
        'omitted node_group refuses rather than allows');
    is($au->graph_refusal(%base, node => 'mine', node_group => {}), 'node',
        'a ref passed as node_group refuses rather than dying');
};

# ---------------------------------------------------------------------------
# 3. group identifiers, including the 'network' pseudo-group
# ---------------------------------------------------------------------------
subtest 'graph_refusal: group identifiers' => sub {
    my $au = restricted_user('DataCentre', 'network');
    my $GT = { DataCentre => 'DataCentre', Branches => 'Branches' };
    my %base = (grouptable => $GT);

    is($au->graph_refusal(%base, group => 'DataCentre'), undef,
        'own group is allowed');
    is($au->graph_refusal(%base, group => 'Branches'), 'group',
        'group the user does not hold is refused');
    is($au->graph_refusal(%base, group => 'NoSuchGroup'), 'group',
        'group absent from the group table is refused');

    # 'network' is the metrics pseudo-group: gated on InGroup, exempt from the
    # group table, matching the long-standing node.pl behaviour
    ok(!exists $GT->{network}, 'precondition: network is not in the group table');
    is($au->graph_refusal(%base, group => 'network'), undef,
        "'network' is allowed for a user who holds it");

    my $without = restricted_user('DataCentre');
    is($without->graph_refusal(%base, group => 'network'), 'group',
        "'network' is refused for a user who does not hold it");
};

# ---------------------------------------------------------------------------
# 4. hide_groups is enforced through the group table
#
# get_group_names strips hidden groups (lib/NMISNG.pm:2828), so a hidden group
# never reaches visible_groups and is therefore absent from the table. A user
# who still lists it must be refused.
# ---------------------------------------------------------------------------
subtest 'graph_refusal: hidden group is refused via the group table' => sub {
    my $au = restricted_user('DataCentre', 'Hidden');
    my $GT = $au->visible_groups(qw(DataCentre));   # 'Hidden' stripped upstream

    ok($au->InGroup('Hidden'),
        'precondition: InGroup alone would allow the hidden group');
    is($au->graph_refusal(grouptable => $GT, group => 'Hidden'), 'group',
        'hidden group is refused');
    is($au->graph_refusal(grouptable => $GT,
                          node => 'lurker', node_group => 'Hidden'), 'node',
        'node belonging to a hidden group is refused');
};

# ---------------------------------------------------------------------------
# 5. the laundering vector: every identifier present must be checked
#
# This is the case node.pl's if/elsif missed. A permitted node paired with a
# foreign group must be refused, because for graphtype=metrics the group is
# what selects the rrd file.
# ---------------------------------------------------------------------------
subtest 'graph_refusal: a permitted node cannot launder a foreign group' => sub {
    my $au = restricted_user('DataCentre');
    my $GT = { DataCentre => 'DataCentre', Branches => 'Branches' };
    my %base = (grouptable => $GT, node => 'mine', node_group => 'DataCentre');

    is($au->graph_refusal(%base), undef,
        'precondition: the node on its own is allowed');

    is($au->graph_refusal(%base, group => 'Branches'), 'group',
        'permitted node paired with a foreign group is refused');
    is($au->graph_refusal(%base, group => 'NoSuchGroup'), 'group',
        'permitted node paired with an unknown group is refused');
    is($au->graph_refusal(%base, group => 'DataCentre'), undef,
        'permitted node paired with its own group is allowed');

    # and the mirror image: a foreign node cannot ride in on a permitted group
    is($au->graph_refusal(grouptable => $GT, node => 'theirs',
                          node_group => 'Branches', group => 'DataCentre'),
        'node', 'foreign node paired with a permitted group is refused');
};

# ---------------------------------------------------------------------------
# 6. nothing to authorise against
# ---------------------------------------------------------------------------
subtest 'graph_refusal: a request naming neither node nor group is refused' => sub {
    my $au = restricted_user('DataCentre');
    my %base = (grouptable => { DataCentre => 'DataCentre' });

    is($au->graph_refusal(%base), 'none', 'no node and no group is refused');
    is($au->graph_refusal(%base, node => undef, group => undef), 'none',
        'explicit undefs are refused');
    is($au->graph_refusal(%base, node => '', group => ''), 'none',
        'empty strings are refused');
    is($au->graph_refusal(%base, node => '0'), 'node',
        "a node named '0' is treated as supplied, not as absent");
};

# ---------------------------------------------------------------------------
# 7. allow_global, for graphtypes whose rrd names no node and no group
# ---------------------------------------------------------------------------
# graphtype 'nmis' is the NMIS runtime graph. Its rrd is the fixed
# '/metrics/nmis-system.rrd' (models-default/Common-database.nmis:175), so it
# has no node or group to check and node.pl authorises it on the
# tls_nmis_runtime access right instead. Without the opt-in the 'none' refusal
# broke the drill-in link that network.pl's runtime page generates via
# Compat::NMIS::htmlGraph (node.pl?...&graphtype=nmis&group=&node=).
subtest 'graph_refusal: allow_global admits a caller-authorised global graph' => sub {
    my $au = restricted_user('DataCentre');
    my %base = (grouptable => { DataCentre => 'DataCentre' });
    my %foreign = (node => 'theirs', node_group => 'Branches');

    is($au->graph_refusal(%base, allow_global => 1), undef,
        'a global graph naming neither node nor group is allowed');
    is($au->graph_refusal(%base, node => '', group => '', allow_global => 1),
        undef, 'empty strings are treated the same as absent');

    # the opt-in suppresses only the 'none' case: anything actually named is
    # still checked, so a global graphtype cannot be used to smuggle a foreign
    # node or group past the gate
    is($au->graph_refusal(%base, %foreign, allow_global => 1), 'node',
        'allow_global does not waive a supplied foreign node');
    is($au->graph_refusal(%base, group => 'Branches', allow_global => 1), 'group',
        'allow_global does not waive a supplied foreign group');
    is($au->graph_refusal(%base, %foreign, group => 'DataCentre',
                          allow_global => 1), 'node',
        'allow_global does not reinstate the laundering path');

    # and it is opt-in, not the default
    is($au->graph_refusal(%base), 'none',
        'omitting allow_global still refuses');
    is($au->graph_refusal(%base, allow_global => 0), 'none',
        'a false allow_global still refuses');
};

# ---------------------------------------------------------------------------
# 8. an all-groups administrator is not locked out
# ---------------------------------------------------------------------------
subtest 'graph_refusal: all-groups account is unaffected' => sub {
    my $au = restricted_user('DataCentre');
    $au->{all_groups_allowed} = 1;

    my $GT = $au->visible_groups(qw(DataCentre Branches));
    my %base = (grouptable => $GT);
    my %theirs = (node => 'theirs', node_group => 'Branches');

    is($au->graph_refusal(%base, %theirs), undef,
        'admin may view a node in any group');
    is($au->graph_refusal(%base, %theirs, group => 'Branches'), undef,
        'admin may pair node and group freely');

    # still fails closed on things that do not exist at all
    is($au->graph_refusal(%base, node => 'nosuchnode'), 'node',
        'admin is still refused an unknown node');
    is($au->graph_refusal(%base, group => 'NoSuchGroup'), 'group',
        'admin is still refused an unknown group');
};

done_testing;
