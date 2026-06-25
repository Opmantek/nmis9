#!/usr/bin/perl
# Plugin node-object parameter: save invariant, dispatcher wiring, plugin-source guard.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB; use NMISNG::Sys;
use Compat::NMIS;  # required: collect() calls Compat::NMIS::notify internally

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_plugnodeobj-$$";
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

# count nodes-collection finds
my @nf; my $orig = \&NMISNG::DB::find;
{ no warnings 'redefine';
  *NMISNG::DB::find = sub { my %a=@_;
    my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}";
    push @nf, 1 if $n =~ /(?:^|\.)nodes$/;
    return $orig->(@_); }; }

# a node + one interface inventory to save
my $uuid = "f00d0001-0000-0000-0000-000000000001";
my $node = $nmisng->node(uuid=>$uuid, create=>1);
$node->cluster_id($C->{cluster_id}); $node->name("plugnodeobj");
$node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1,model=>"Generic"}); $node->save();
my $p = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e0"}, path_keys=>["ifDescr"]);
my ($inv) = $node->inventory(concept=>"interface", path=>$p, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
$inv->data({index=>1, ifIndex=>1, ifDescr=>"e0"}); $inv->save(node=>$node);

# INVARIANT: saving WITH the object does no nodes find; saving with the NAME string does.
@nf = (); $inv->data({index=>1, ifIndex=>1, ifDescr=>"e0", note=>"a"}); $inv->save(node=>$node);
is(scalar(@nf), 0, "save(node => OBJECT) issues no nodes find");

@nf = (); $inv->data({index=>1, ifIndex=>1, ifDescr=>"e0", note=>"b"}); $inv->save(node=>$node->name);
ok(scalar(@nf) >= 1, "save(node => NAME STRING) re-resolves (>=1 nodes find), got ".scalar(@nf));

{ no warnings 'redefine'; *NMISNG::DB::find = $orig; }  # restore before the rest

# collect() calls update() internally; update() calls RRDs::info bare (Node.pm ~7444, ~9749).
# RRDs is loaded lazily by NMISNG::rrdfunc::require_RRDs; stub it out so collect() can reach
# the collect_plugin loop without crashing on missing RRD files.
NMISNG::rrdfunc::require_RRDs();   # ensure RRDs is loaded first, then stub
{ no warnings qw(redefine prototype); *RRDs::info = sub { return {}; }; }

# WIRING: a stub plugin injected into the loader must receive node_obj as an NMISNG::Node.
# Harness path taken: collect() fatals without a catchall inventory, so we create one explicitly
# and set nodedown/snmpdown => "false" to prevent early-return before the plugin loop.
# This is the brief's documented fallback (mark node up via catchall data_live, save, re-run).
{
  package NodeObjProbe;
  our %SEEN;
  sub collect_plugin { my (%a) = @_; %SEEN = %a; return (1); }
}
$nmisng->{_plugins} = ['NodeObjProbe'];   # short-circuits NMISNG::plugins() (it caches _plugins)

# collect() fetches its own catchall inventory from MongoDB (line ~9457 in Node.pm).
# Create it now so collect() doesn't fatal on an undefined catchall.
# Also set nodedown/snmpdown => "false" so collect() does not early-return before the
# plugin loop (brief fallback: mark node up via catchall data_live).
my $cp = $node->inventory_path(concept=>"catchall", data=>{}, path_keys=>[]);
my ($catchall_inv, $cerr) = $node->inventory(concept=>"catchall", model_class=>"system",
                                              path=>$cp, path_keys=>[], create=>1);
BAIL_OUT("setup failed: could not create catchall inventory: $cerr") if $cerr;
my $cdata = $catchall_inv->data_live();
$cdata->{nodedown}   = "false";
$cdata->{snmpdown}   = "false";
$cdata->{nodeModel}  = "Generic";
$cdata->{nodeType}   = "router";
# last_update must be set or collect() redirects to update() at ~line 9531
$cdata->{last_update} = time();
$catchall_inv->save(node=>$node);

my $S = NMISNG::Sys->new(nmisng=>$nmisng);
$S->init(node=>$node, snmp=>0, wmi=>0);
# drive collect far enough to reach the collect_plugin loop.
$node->collect(wantsnmp=>0, wantwmi=>0, force=>1);

ok(defined $NodeObjProbe::SEEN{node_obj}, "collect_plugin received a node_obj argument");
is(ref($NodeObjProbe::SEEN{node_obj}), "NMISNG::Node", "node_obj is an NMISNG::Node object");
is($NodeObjProbe::SEEN{node}, $node->name, "node argument is still the name string (back-compat)");
$nmisng->{_plugins} = undef;

# drop the temp db so repeated runs (Tasks 2-5) start clean (idiom from test/t_nmisng.pl)
$nmisng->get_db()->drop();

# STATIC GUARD: after the fixups, no in-tree plugin may pass the bare $node name string to save,
# nor re-resolve the current node with node(name => $node). \$node\b does not match \$node_obj.
{
  my $dir = "$FindBin::Bin/../conf-default/plugins";
  for my $file (sort glob("$dir/*.pm")) {
    open my $fh, "<", $file or next;
    local $/; my $src = <$fh>; close $fh;
    my $base = $file; $base =~ s{.*/}{};
    ok($src !~ /->\s*save\s*\(\s*node\s*=>\s*\$node\b/,
       "$base: no save(node => \$node) with the bare name string");
    ok($src !~ /->\s*node\s*\(\s*name\s*=>\s*\$node\b/,
       "$base: no \$NG->node(name => \$node) re-resolve of the current node");
  }
}

done_testing;
