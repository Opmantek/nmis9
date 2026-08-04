#
#  Copyright (C) Keith Sinclair (https://github.com/kcsinclair/)
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# NMISNG::OTel - OpenTelemetry-inspired field naming for NMIS inventory data.
#
# Maps NMIS-native metric/field names onto OpenTelemetry-style semantic
# convention names, and provides helpers to rename, filter and describe
# inventory data. Shared by the MQTT observations plugin and the MCP server
# so the rename maps live in one place instead of being copied per consumer.
#
# *****************************************************************************

package NMISNG::OTel;
our $VERSION = "1.1.0";

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	apply_field_rename
	filter_derived
	filter_derived_flat
	get_description
	unweight_health
	%DESCRIPTION_FIELDS
	@FALLBACK_DESCRIPTION_FIELDS
	%CONCEPT_RENAME
	%FIELD_RENAME
	%HEALTH_WEIGHT
);

# ---------------------------------------------------------------------------
# Description fields: per concept, the inventory fields to try (in order) when
# building a human-readable description for an instance.
# ---------------------------------------------------------------------------

our %DESCRIPTION_FIELDS = (
	'interface'        => [qw(ifDescr Description)],
	'catchall'         => [qw(sysDescr sysName nodeType)],
	'Host_Storage'     => [qw(hrStorageDescr)],
	'Host_File_System' => [qw(hrFSMountPoint hrFSType)],
	'Host_Partition'   => [qw(hrPartitionLabel hrPartitionID)],
	'entityMib'        => [qw(entPhysicalName entPhysicalDescr)],
	'cdp'              => [qw(cdpCacheDeviceId cdpCacheDevicePort)],
	'lldp'             => [qw(lldpRemSysName lldpRemPortDesc)],
	'bgp'              => [qw(bgpPeerIdentifier)],
	'vlan'             => [qw(vlanName vtpVlanName)],
	'mpls'             => [qw(mplsVpnVrfName)],
	'cbqos'            => [qw(CbQosPolicyMapName)],
	'addressTable'     => [qw(dot1dTpFdbAddress)],
	'diskIOTable'      => [qw(diskIODevice)],
	'env-temp'         => [qw(lmTempSensorsDevice)],
	'storage'          => [qw(hrStorageDescr)],
	'service'          => [qw(service)],
	'ping'             => [qw(host)],
	'device'           => [qw(index)],
);

our @FALLBACK_DESCRIPTION_FIELDS = qw(Description description Name name ifDescr);

# This concept renaming is done because of the reverse compatibility, the list of CPU names is available here.
our %CONCEPT_RENAME = (
	'device' => 'cpuLoad',
);

our %FIELD_RENAME = (
	'interface' => {
		'ifInOctets'        => 'system.network.io.receive',
		'ifOutOctets'       => 'system.network.io.transmit',
		'ifInUcastPkts'     => 'system.network.packets.receive',
		'ifOutUcastPkts'    => 'system.network.packets.transmit',
		'ifInErrors'        => 'system.network.errors.receive',
		'ifOutErrors'       => 'system.network.errors.transmit',
		'ifInDiscards'      => 'system.network.dropped.receive',
		'ifOutDiscards'     => 'system.network.dropped.transmit',
		'ifSpeed'           => 'system.network.speed',
		'ifOperStatus'      => 'system.network.status',
	},
	'device' => {
		'cpuLoad'           => 'system.cpu.utilization',
		'cpu1min'           => 'system.cpu.utilization.1m',
		'cpu5min'           => 'system.cpu.utilization.5m',
		'memUtil'           => 'system.memory.utilization',
		'memAvail'          => 'system.memory.usage.available',
	},
	'Host_Storage' => {
		'hrStorageUsed'            => 'system.filesystem.usage.used',
		'hrStorageSize'            => 'system.filesystem.usage.total',
		'hrStorageAllocationUnits' => 'system.filesystem.allocation_unit',
		'hrStorageType'            => 'system.filesystem.type',
	},
	'diskIOTable' => {
		'diskIOReads'       => 'system.disk.operations.read',
		'diskIOWrites'      => 'system.disk.operations.write',
		'diskIOReadBytes'   => 'system.disk.io.read',
		'diskIOWriteBytes'  => 'system.disk.io.write',
	},
	'health' => {
		'reachability'       => 'nmis.node.reachability',
		'availability'       => 'nmis.node.availability',
		'health'             => 'nmis.node.health',
		'responsetime'       => 'nmis.node.response_time_ms',
		'loss'               => 'nmis.node.packet_loss',
		'intfCollect'        => 'nmis.node.intf_collect',
		'intfColUp'          => 'nmis.node.intf_collect_up',
		'reachabilityHealth' => 'nmis.node.reachability_health',
		'availabilityHealth' => 'nmis.node.availability_health',
		'responseHealth'     => 'nmis.node.response_health',
		'cpuHealth'          => 'nmis.node.cpu_health',
		'memHealth'          => 'nmis.node.mem_health',
		'intHealth'          => 'nmis.node.int_health',
		'diskHealth'         => 'nmis.node.disk_health',
		'swapHealth'         => 'nmis.node.swap_health',
	},
	'Host_Health' => {
		'hrSystemProcesses' => 'system.process.count',
		'hrSystemNumUsers'  => 'system.users.count',
	},
	'laload' => {
		'laLoad1'           => 'system.cpu.load_average.1m',
		'laLoad5'           => 'system.cpu.load_average.5m',
	},
	'mib2ip' => {
		'ipInReceives'      => 'system.network.ip.in_receives',
		'ipInHdrErrors'     => 'system.network.ip.in_header_errors',
		'ipInAddrErrors'    => 'system.network.ip.in_address_errors',
		'ipForwDatagrams'   => 'system.network.ip.forwarded',
		'ipInUnknownProtos' => 'system.network.ip.in_unknown_protos',
		'ipInDiscards'      => 'system.network.ip.in_discards',
		'ipInDelivers'      => 'system.network.ip.in_delivers',
		'ipOutRequests'     => 'system.network.ip.out_requests',
		'ipOutDiscards'     => 'system.network.ip.out_discards',
		'ipReasmReqds'      => 'system.network.ip.reassembly_required',
		'ipReasmOKs'        => 'system.network.ip.reassembly_ok',
		'ipReasmFails'      => 'system.network.ip.reassembly_failed',
		'ipFragOKs'         => 'system.network.ip.fragmentation_ok',
		'ipFragCreates'     => 'system.network.ip.fragments_created',
		'ipFragFails'       => 'system.network.ip.fragmentation_failed',
	},
	'systemStats' => {
		'ssCpuRawUser'      => 'system.cpu.time.user',
		'ssCpuRawNice'      => 'system.cpu.time.nice',
		'ssCpuRawSystem'    => 'system.cpu.time.system',
		'ssCpuRawIdle'      => 'system.cpu.time.idle',
		'ssCpuRawWait'      => 'system.cpu.time.wait',
		'ssCpuRawKernel'    => 'system.cpu.time.kernel',
		'ssCpuRawInterrupt' => 'system.cpu.time.interrupt',
		'ssCpuRawSoftIRQ'   => 'system.cpu.time.soft_irq',
		'ssIORawSent'       => 'system.disk.io.sent',
		'ssIORawReceived'   => 'system.disk.io.received',
		'ssRawInterrupts'   => 'system.cpu.interrupts',
		'ssRawContexts'     => 'system.cpu.context_switches',
		'ssRawSwapIn'       => 'system.memory.swap.in',
		'ssRawSwapOut'      => 'system.memory.swap.out',
	},
	'tcp' => {
		'tcpActiveOpens'    => 'system.network.tcp.connections.opened.active',
		'tcpPassiveOpens'   => 'system.network.tcp.connections.opened.passive',
		'tcpAttemptFails'   => 'system.network.tcp.connections.failed',
		'tcpEstabResets'    => 'system.network.tcp.connections.reset',
		'tcpCurrEstab'      => 'system.network.tcp.connections.established',
		'tcpInSegs'         => 'system.network.tcp.segments.received',
		'tcpOutSegs'        => 'system.network.tcp.segments.sent',
		'tcpRetransSegs'    => 'system.network.tcp.segments.retransmitted',
		'tcpInErrs'         => 'system.network.tcp.errors.received',
		'tcpOutRsts'        => 'system.network.tcp.resets.sent',
	},
	'ping' => {
		'avg_ping_time'     => 'network.peer.rtt.avg_ms',
		'max_ping_time'     => 'network.peer.rtt.max_ms',
		'min_ping_time'     => 'network.peer.rtt.min_ms',
		'ping_loss'         => 'network.peer.packet_loss',
	},
);

# ---------------------------------------------------------------------------
# Health "*Health" fields (reachabilityHealth, cpuHealth, memHealth, ...) are
# NOT percentages. compute_reachability() in NMISNG::Node stores each one as
# that metric's *contribution* to the overall node health: percentage * config
# weight. With the default weight_cpu=0.2 a CPU sitting at 85% is stored as 17,
# which reads as an alarming "17" when published on its own even though the CPU
# is healthy.
#
# unweight_health divides each *Health field by its weight, recovering the
# 0-100 percentage the operator expects to see (17 -> 85). The map below ties
# each field to the Config.nmis weight key that produced it.
#
# weight_mem is shared between mem+swap and weight_int between int+disk. When
# the swap (resp. disk) partner is active, compute_reachability halves both
# shares (weight/2); we detect that from a non-zero swapHealth/diskHealth value
# in the same record and use the halved weight so the percentage still recovers
# correctly.
# ---------------------------------------------------------------------------
our %HEALTH_WEIGHT = (
	'reachabilityHealth' => 'weight_reachability',
	'availabilityHealth' => 'weight_availability',
	'responseHealth'     => 'weight_response',
	'cpuHealth'          => 'weight_cpu',
	'memHealth'          => 'weight_mem',
	'swapHealth'         => 'weight_mem',
	'intHealth'          => 'weight_int',
	'diskHealth'         => 'weight_int',
);

sub unweight_health
{
	my ($src, $config) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	$config ||= {};

	# mem+swap share weight_mem, int+disk share weight_int; the share is halved
	# only when the partner metric is actually present (its *Health value > 0).
	my $mem_split = (($src->{swapHealth} // 0) > 0) ? 2 : 1;
	my $int_split = (($src->{diskHealth} // 0) > 0) ? 2 : 1;

	my %out = %$src;
	for my $field (keys %HEALTH_WEIGHT)
	{
		next if !defined $out{$field};
		next if $out{$field} !~ /^-?\d+(?:\.\d+)?$/;    # leave "U"/blank as-is
		my $weight = $config->{$HEALTH_WEIGHT{$field}};
		next if !$weight;                               # no weight -> can't rescale

		my $split = 1;
		$split = $mem_split if ($field eq 'memHealth' || $field eq 'swapHealth');
		$split = $int_split if ($field eq 'intHealth' || $field eq 'diskHealth');

		# stored = percentage * (weight/split)  ->  percentage = stored / (weight/split)
		$out{$field} = sprintf('%.2f', $out{$field} / ($weight / $split)) + 0;
	}
	return \%out;
}

# ---------------------------------------------------------------------------
# Rename the fields of $src (a hashref) for the given $concept. Known fields
# get their mapped OTel name; unknown fields are prefixed with "nmis.". Fields
# ending in _raw (any case) are dropped. Returns a new hashref.
# ---------------------------------------------------------------------------
sub apply_field_rename
{
	my ($concept, $src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my $map = $FIELD_RENAME{$concept} // {};
	my %out;
	for my $k (keys %$src)
	{
		next if $k =~ /_raw$/i;
		my $new_k = $map->{$k} // "nmis.$k";
		$out{$new_k} = $src->{$k};
	}
	return \%out;
}

# Drop derived-data keys whose names start with an RRD consolidation-window
# prefix (08_, 16_); those are internal rollups, not point-in-time metrics.
sub filter_derived
{
	my ($src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my %filtered = map { $_ => $src->{$_} }
		grep { $_ !~ /^(?:08|16)/ } keys %$src;
	return \%filtered;
}

# Flatten a per-subconcept derived-data hash into one hash, applying
# filter_derived to each subconcept.
sub filter_derived_flat
{
	my ($derived) = @_;
	return {} if (!$derived || ref($derived) ne 'HASH');
	my %out;
	for my $sub (keys %$derived)
	{
		my $filtered = filter_derived($derived->{$sub});
		%out = (%out, %$filtered);
	}
	return \%out;
}

# Pick a human-readable description for an inventory instance: the first
# non-empty concept-specific field, then a generic fallback. Returns '' if none.
sub get_description
{
	my ($concept, $data) = @_;
	my @fields = @{$DESCRIPTION_FIELDS{$concept} // []};
	push @fields, @FALLBACK_DESCRIPTION_FIELDS;
	for my $field (@fields)
	{
		return $data->{$field}
			if defined $data->{$field} && $data->{$field} ne '';
	}
	return '';
}

1;
