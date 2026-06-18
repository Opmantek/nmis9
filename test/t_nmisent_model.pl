#!/usr/bin/perl
# Verifies the nmisent producer model parses and that the HTTP engine
# discovers one inventory row per {engine} label from a fixture /metrics body.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/lib";
use Test::More;
use NMISNG::Sys::Engine::HTTP;
use NMISNG::Test::Fakes;

# model parses
my %hash;
my $content = do { local $/; open my $fh, '<', "$FindBin::Bin/../models-default/Model-nmisent.nmis" or die $!; <$fh> };
eval $content; die "parse failed: $@" if $@;
is($hash{system}{nodeModel}, 'nmisent', 'nmisent model parses, nodeModel set');
my $sec = $hash{systemHealth}{sys}{nmisent_poll};
ok($sec && $sec->{indexed} eq 'engine', 'nmisent_poll indexed by engine label');
ok($sec->{http_prom}{last_success_epoch}{metric} eq 'nmisent_poll_last_success_epoch',
   'last_success_epoch sources the right prom metric');
ok($hash{database}{type}{nmisent_poll}, 'database.type.nmisent_poll present');

# A system.sys section is required, or loadInfo(class=>'system') aborts with
# "found no sections to collect" and update_node_info never settles the model
# (caught in live validation 2026-06-18, not by the parse/discovery checks).
ok(ref $hash{system}{sys} eq 'HASH' && keys %{$hash{system}{sys}},
   'system.sys section present (loadInfo(system) has something to collect)');
ok($hash{system}{sys}{standard}{http_prom}{nmisent_up}{metric} eq 'nmisent_up',
   'system.sys collects a node-level liveness metric (nmisent_up)');

# label discovery: one row per engine from a fixture body
my $body = join("\n",
  '# TYPE nmisent_poll_last_success_epoch gauge',
  'nmisent_poll_last_success_epoch{engine="meraki"} 1781000000',
  'nmisent_poll_last_success_epoch{engine="hpe_greenlake"} 1781000050',
  'nmisent_poll_interval_seconds{engine="meraki"} 60',
  'nmisent_poll_interval_seconds{engine="hpe_greenlake"} 120', '');
my $sys = NMISNG::Test::FakeSys->new;
my $eng = NMISNG::Sys::Engine::HTTP->new(sys => $sys);
$eng->set_endpoints([{ name => 'nmisent', port => 9464 }]);
no warnings 'redefine';
local *NMISNG::Sys::Engine::HTTP::_fetch = sub { return ($body, 'text/plain; version=0.0.4', undef); };
my ($err, $idx, $targets) = $eng->discover_indexes(
  section_config => { indexed => 'engine',
    http_prom => { '-common-' => { endpoint => 'nmisent' },
      last_success_epoch => { metric => 'nmisent_poll_last_success_epoch' } } },
  index_var => 'engine');
is($err, undef, 'discover_indexes: no error');
is_deeply([sort @$idx], ['hpe_greenlake','meraki'], 'one index per engine label');

done_testing();
