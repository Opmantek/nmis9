#!/usr/bin/perl
# Create the two benchmark nodes via node_admin (proven path). Idempotent.
#
# Node-def shape (confirmed against source, not assumed): node_admin.pl's
# create/update handler (admin/node_admin.pl, act=~/^(create|update)$/ branch)
# requires the DEEPLY NESTED structure that "act=mktemplate" emits, i.e.
# top-level name/uuid/cluster_id/activated, with host/community/ping/etc
# under a "configuration" hash -- NOT flat top-level keys. validate_node_data()
# (admin/node_admin.pl) enforces name/configuration.host/configuration.group
# are present and configuration.netType/roleType are in the configured
# nettype_list/roletype_list (checked in this container's conf/Config.nmis:
# nettype_list includes "lan", roletype_list includes "access"). Confirmed
# against a working reference file from the event-prefetch spike this brief
# points to (/tmp/realnode188.json on the host), which uses exactly this
# nested shape.
#
# Both nodes need community set (snmp_enabled requires the node to have
# community/username configured -- see collect_bench.pl's header notes and
# Sys::init) and ping=false. ping=false does NOT skip the SNMP branch: in
# Node::pingable() (lib/NMISNG/Node.pm), when configuration.ping is false,
# the function takes the "not configured for pinging" branch and returns
# pingresult=100 (i.e. pingable() reports true), rather than attempting a
# real ICMP ping the benchmark host can't answer. Node::collect() then gates
# the SNMP branch on "if ($pingable && $self->configuration->{collect})" --
# since ping=false forces pingable() true, this always passes.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/../../lib";
use JSON::XS; use NMISNG; use NMISNG::Util; use NMISNG::Log;
# loadConfTable()'s default dir is $FindBin::RealBin/../conf; since this script
# lives in test/bench/, that default resolves to test/conf (does not exist,
# not the real config) rather than the top-level conf/ that node_admin.pl,
# dev-tools.pl etc use. Pass the real path explicitly (confirmed present and
# readable at /usr/local/nmis9/conf/Config.nmis in this container).
my $C = NMISNG::Util::loadConfTable(dir => "$FindBin::Bin/../../conf");
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));
my $node_admin = "$FindBin::Bin/../../admin/node_admin.pl";
for my $name (qw(realnode188 mocknode)) {
  if ($nmisng->node(name=>$name)) { print "$name exists\n"; next; }
  my $def = {
    name => $name,
    cluster_id => "",
    activated => { NMIS => 1 },
    configuration => {
      host => "172.20.0.1",
      port => 1161,
      community => "nmisGig8",
      group => "NMIS9",
      version => "snmpv2c",
      model => "automatic",
      netType => "lan",
      roleType => "access",
      ping => "false",
      collect => "true",
      threshold => "true",
    },
  };
  my $file = "/tmp/$name.json";
  open(my $fh, ">", $file) or die "cannot write $file: $!\n";
  print $fh JSON::XS->new->encode($def); close($fh);
  my $rc = system("perl", $node_admin, "act=create", "file=$file");
  die "node_admin create failed for $name (rc=$rc)\n" if ($rc != 0);
  print "created $name\n";
}
