#
# NMISNG::Sys::Engine::Redis::Status - raw vendor status to canonical status.
# Pure, no NMIS state, no I/O. The raw vendor string is stored elsewhere for
# display; this only derives the value the reachability logic acts on.
# 'unknown' is returned for anything unrecognised and must never be treated
# as reachable by callers. Aruba APs use the hpe_greenlake engine with a
# different vocabulary than GreenLake switches, so hpe_greenlake is the union
# of both; the canonical values do not collide.
#
package NMISNG::Sys::Engine::Redis::Status;
use strict;
use warnings;
our $VERSION = "1.0.0";

my %MAP = (
	'meraki' => {
		'online'   => 'up',
		'offline'  => 'down',
		'alerting' => 'degraded',
		'dormant'  => 'degraded',
	},
	'hpe_greenlake' => {
		'online'  => 'up',
		'up'      => 'up',
		'offline' => 'down',
	},
);

# args: engine, raw status. returns: up|down|degraded|unknown
sub canonical
{
	my ($engine, $raw) = @_;
	return 'unknown' if (!defined $engine || !defined $raw);
	my $emap = $MAP{ lc $engine };
	return 'unknown' if (!$emap);
	return $emap->{ lc $raw } // 'unknown';
}

1;
