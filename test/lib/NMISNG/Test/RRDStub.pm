#
# NMISNG::Test::RRDStub — shared RRD/stats monkey-patches for polling tests.
#
# install() replaces the three I/O points that otherwise need a linked RRD
# library and real history:
#   - NMISNG::Sys::create_update_rrd: records every call in @CALLS (type,
#     index, ds=>value map) and performs the set_subconcept_type_storage
#     side effect the storage tests assert on, writing no file.
#   - RRDs::info: returns {} (compute_reachability reads prior polltime).
#   - Compat::NMIS::getSubconceptStats: serves copies from %STATS (set
#     entries per stats_section/subconcept in your test), {} otherwise.
#
# Used by t_polling_redis.pl and t_polling_http.pl; t_polling.pl keeps its
# own older copy (clone()-based stats) deliberately.
#
package NMISNG::Test::RRDStub;
use strict;
use warnings;
our $VERSION = "1.0.0";

our @CALLS;
our %STATS;

sub install
{
	require NMISNG::Sys;
	require Compat::NMIS;
	# pre-load the real RRDs (if present) so a later `require RRDs` inside
	# the code under test cannot replace the info stub below
	require RRDs if (!defined &RRDs::info);

	no warnings 'redefine';
	*NMISNG::Sys::create_update_rrd = sub {
		my ($self, %args) = @_;
		push @CALLS, {
			type  => $args{type},
			index => $args{index},
			data  => { map { $_ => $args{data}{$_}{value} } keys %{ $args{data} // {} } },
		};
		if (ref($args{inventory}))
		{
			my $type = $args{type} || 'unknown';
			$args{inventory}->set_subconcept_type_storage(
				subconcept => $type, type => 'rrd',
				data => "/nodes/$self->{name}/mock-$type.rrd"
			);
		}
		return 1;
	};
	*RRDs::info = sub { return {}; };
	*Compat::NMIS::getSubconceptStats = sub {
		my %args = @_;
		my $key = $args{stats_section} // $args{subconcept};
		return (defined $key && exists $STATS{$key}) ? { %{$STATS{$key}} } : {};
	};
	return 1;
}

1;
