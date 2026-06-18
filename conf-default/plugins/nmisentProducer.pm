#
# nmisentProducer.pm - collect plugin for the nmisent producer node.
# After the HTTP collect populates the nmisent_poll rows, evaluate each
# engine's poll age and raise/clear the per-engine "nmisent Producer Stale"
# event. Age is computed here, at collect time, where "now" is available.
#
package nmisentProducer;
use strict;
use warnings;
use NMISNG::Util;

# pure: is this engine's poll stale? age = now - last_success_epoch, vs 2x interval.
# missing inputs are NOT stale here (indeterminate is handled by producer_state).
sub is_stale
{
	my ($last_success_epoch, $interval, $now) = @_;
	return 0 if (!defined $last_success_epoch || !defined $interval || $interval <= 0);
	return (($now - $last_success_epoch) > (2 * $interval)) ? 1 : 0;
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $nmisng) = @args{qw(node sys config nmisng)};
	my $nobj = $nmisng->node(name => $node);
	return (0, undef) if (!$nobj);
	return (0, undef) if (($nobj->configuration->{model} // '') ne 'nmisent');

	my $now = time;
	my $ids = $nobj->get_inventory_ids(concept => 'nmisent_poll');
	for my $id (@$ids)
	{
		my ($inv) = $nobj->inventory(_id => $id);
		next if (!$inv);
		my $d = $inv->data;
		my $engine = $d->{index};
		next if (!defined $engine);
		my $stale = is_stale($d->{last_success_epoch}, $d->{interval}, $now);
		if ($stale)
		{
			Compat::NMIS::notify(
				sys     => $S,
				event   => "nmisent Producer Stale",
				element => $engine,
				level   => "Major",
				details => "nmisent has not completed a poll for engine $engine within 2x its interval",
				context => { type => "node" },
				inventory_id => $inv->id,
			);
		}
		else
		{
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "nmisent Producer Stale",
				element => $engine,
				level   => "Normal",
				details => "nmisent poll for engine $engine is fresh",
				inventory_id => $inv->id,
			);
		}
	}
	return (0, undef);
}

1;
