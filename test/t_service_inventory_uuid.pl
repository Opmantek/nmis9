#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify it under the
#  terms of the GNU General Public License as published by the Free Software
#  Foundation, either version 3 of the License, or (at your option) any later
#  version. See <http://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# Behavioural test for NMISNG::Inventory::ServiceInventory uuid generation
# (OMK-12776 / defect BR-02).
#
# A service inventory carries its own recreatable V5 uuid, built from the
# cluster_id, the service name and the node's uuid, so that every service on
# every node has a distinct identity. ServiceInventory::data() computed it with
#
#     getComponentUUIDConf( components => ($self->cluster_id,
#                                          $newvalue->{service},
#                                          $self->node_uuid), ... )
#
# The parenthesised list flattened into the named-arg call, and
# getComponentUUIDConf did `my @components = $args{components}` (scalar
# context), so only cluster_id survived. Every service inventory in a cluster
# then hashed to the SAME uuid, conflating all services and nodes.
#
# This test drives the real ServiceInventory::data() path and asserts that
# service inventories differing by service or by node get different uuids. It
# is hermetic: the uuid is a pure function of its inputs, so it needs no
# MongoDB and no config file (an empty conf is passed in, which is
# deterministic and skips the namespace prefix).
#
# RED before the fix: the three uuids collide. GREEN after: they are distinct.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG::Inventory::ServiceInventory;

# ---------------------------------------------------------------------------
# A ServiceInventory needs an nmisng only for construction plumbing (logging,
# a couple of config reads). The uuid computation itself is pure, so a stub is
# enough and keeps the test free of MongoDB.
# ---------------------------------------------------------------------------
{
	package t::StubNmisng;
	sub new    { return bless {}, shift }
	sub log    { return t::StubLog->new }
	sub config { return {} }
	our $AUTOLOAD;
	sub AUTOLOAD { return }
	sub DESTROY  { return }
}
{
	package t::StubLog;
	sub new { return bless {}, shift }
	our $AUTOLOAD;
	sub AUTOLOAD { return }
	sub DESTROY  { return }
}

my $stub = t::StubNmisng->new;
my $conf = {};    # deterministic: no namespace prefix, no loadConfTable

# build a service inventory and return the uuid its data() computes
my $service_uuid = sub {
	my (%a) = @_;
	my $si = NMISNG::Inventory::ServiceInventory->new(
		nmisng      => $stub,
		concept     => 'service',
		cluster_id  => $a{cluster},
		node_uuid   => $a{node},
		description => 'test service inventory',
		data        => {},
	);
	die "ServiceInventory->new returned undef\n" if ( !$si );
	my $data = $si->data( { service => $a{service} }, $conf );
	return $data->{uuid};
};

# three service inventories on the SAME cluster, differing by service and/or node
my $dns_n1  = $service_uuid->( cluster => "clusterX", node => "node-1", service => "dns" );
my $http_n1 = $service_uuid->( cluster => "clusterX", node => "node-1", service => "http" );
my $dns_n2  = $service_uuid->( cluster => "clusterX", node => "node-2", service => "dns" );

ok( defined($dns_n1) && $dns_n1 =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
	"a service inventory uuid is generated" )
	or diag("got: " . (defined $dns_n1 ? $dns_n1 : "undef"));

isnt( $dns_n1, $http_n1, "different service on the same cluster+node gets a different uuid" );
isnt( $dns_n1, $dns_n2,  "same service on a different node gets a different uuid" );
isnt( $http_n1, $dns_n2, "the three service inventories all have distinct uuids" );

# the uuid must depend on cluster_id too
isnt( $dns_n1, $service_uuid->( cluster => "clusterY", node => "node-1", service => "dns" ),
	"a different cluster gets a different uuid" );

# V5 uuids are deterministic: identical inputs reproduce the same uuid
is( $dns_n1, $service_uuid->( cluster => "clusterX", node => "node-1", service => "dns" ),
	"identical cluster+node+service reproduces the same uuid" );

done_testing();
