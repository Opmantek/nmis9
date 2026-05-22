#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
# *****************************************************************************
#
# An NMIS collect plugin that publishes per-node latest_data observations
# to an MQTT broker as OTel-inspired flat JSON messages.
#
# Payload format: flat JSON with OTel attribute names on the envelope and
# OTel semantic convention names for well-known metrics. Unknown fields are
# passed through with a "nmis." prefix.
#
# Topic format:  {base_topic}/{node_name}/{concept}/{description}
#                {base_topic}/{node_name}/{subconcept}   (catchall/ping)
# Config file:   conf/mqttobservations.nmis
# Install to:    conf/plugins/mqttobservations.pm
#
# Requires: Net::MQTT::Simple (cpanm Net::MQTT::Simple)
#
package mqttobservations;
our $VERSION = "1.0.0";

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use JSON::XS;
use NMISNG;
use NMISNG::Util;


# Maps concept names to the inventory data fields that best describe an instance.
# The first defined, non-empty field found is used.
my %DESCRIPTION_FIELDS = (
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

# Fallback field names tried in order when concept is not in the map above.
my @FALLBACK_DESCRIPTION_FIELDS = qw(Description description Name name ifDescr);

# Rename concepts for clearer MQTT topic/payload naming.
my %CONCEPT_RENAME = (
	'device' => 'cpuLoad',
);

# Maps NMIS field names to OTel semantic convention names, keyed by concept/subconcept.
# Fields not listed here are passed through with a "nmis." prefix.
my %FIELD_RENAME = (

	# --- Interface (system.network.*) ---
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

	# --- CPU/memory (device concept, renamed to cpuLoad in topics) ---
	'device' => {
		'cpuLoad'           => 'system.cpu.utilization',
		'cpu1min'           => 'system.cpu.utilization.1m',
		'cpu5min'           => 'system.cpu.utilization.5m',
		'memUtil'           => 'system.memory.utilization',
		'memAvail'          => 'system.memory.usage.available',
	},

	# --- Host Storage ---
	'Host_Storage' => {
		'hrStorageUsed'            => 'system.filesystem.usage.used',
		'hrStorageSize'            => 'system.filesystem.usage.total',
		'hrStorageAllocationUnits' => 'system.filesystem.allocation_unit',
		'hrStorageType'            => 'system.filesystem.type',
	},

	# --- Disk IO ---
	'diskIOTable' => {
		'diskIOReads'       => 'system.disk.operations.read',
		'diskIOWrites'      => 'system.disk.operations.write',
		'diskIOReadBytes'   => 'system.disk.io.read',
		'diskIOWriteBytes'  => 'system.disk.io.write',
	},

	# --- Catchall: health ---
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

	# --- Catchall: Host_Health ---
	'Host_Health' => {
		'hrSystemProcesses' => 'system.process.count',
		'hrSystemNumUsers'  => 'system.users.count',
	},

	# --- Catchall: laload (load averages) ---
	'laload' => {
		'laLoad1'           => 'system.cpu.load_average.1m',
		'laLoad5'           => 'system.cpu.load_average.5m',
	},

	# --- Catchall: mib2ip (IP statistics) ---
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

	# --- Catchall: systemStats (UCD-SNMP-MIB) ---
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

	# --- Catchall: tcp (TCP-MIB) ---
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

	# --- Ping ---
	'ping' => {
		'avg_ping_time'     => 'network.peer.rtt.avg_ms',
		'max_ping_time'     => 'network.peer.rtt.max_ms',
		'min_ping_time'     => 'network.peer.rtt.min_ms',
		'ping_loss'         => 'network.peer.packet_loss',
	},
);

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# Skip if node or SNMP is down — no fresh data to publish
	my ($catchall_inventory, $error) = $S->inventory(concept => 'catchall');
	if ($error)
	{
		$NG->log->error("MqttObservations: Failed to get catchall inventory for $node: $error");
		return (2, "Failed to get catchall inventory: $error");
	}

	my $catchall_data = $catchall_inventory->data();

	if (NMISNG::Util::getbool($catchall_data->{nodedown}))
	{
		$NG->log->debug("MqttObservations: Skipping $node — Node Down");
		return (0, undef);
	}
	if (NMISNG::Util::getbool($catchall_data->{snmpdown}))
	{
		$NG->log->debug("MqttObservations: Skipping $node — SNMP Down");
		return (0, undef);
	}

	# Load plugin configuration
	my $plugin_config = NMISNG::Util::loadTable(dir => 'conf', name => 'mqttobservations', conf => $C);
	if (!$plugin_config || ref($plugin_config) ne 'HASH')
	{
		$NG->log->error("MqttObservations: Failed to load conf/mqttobservations.nmis");
		return (2, "Failed to load mqttobservations config");
	}

	my $mqtt_config    = $plugin_config->{mqtt};
	my $mqtt_secondary = $plugin_config->{mqtt_secondary};
	my $concept_list   = $plugin_config->{concepts};

	if (!$mqtt_config || !$mqtt_config->{server})
	{
		$NG->log->error("MqttObservations: No MQTT server configured in mqttobservations.nmis");
		return (2, "No MQTT server configured");
	}

	if (!$concept_list || !@$concept_list)
	{
		$NG->log->debug("MqttObservations: No concepts configured — skipping $node");
		return (0, undef);
	}

	my $extra_logging = NMISNG::Util::getbool($mqtt_config->{extra_logging});
	my $retain        = NMISNG::Util::getbool($mqtt_config->{retain});
	my $retries       = int($mqtt_config->{retries} // 1);
	my $base_topic    = $mqtt_config->{topic} // 'obs/nmis';

	# Build the OTel-inspired resource envelope included in every message
	my $node_uuid = $S->nmisng_node->uuid() // '';
	my %envelope = (
		'host.name'          => $node,
		'host.id'            => $node_uuid,
		'service.name'       => 'nmis',
		'otel.scope.name'    => 'nmis',
		'otel.scope.version' => $VERSION,
		'nmis.group'         => $catchall_data->{group}    // '',
		'nmis.node.type'     => $catchall_data->{nodeType} // '',
		'net.host.name'      => $catchall_data->{sysName}  // '',
		'host.ip'            => $catchall_data->{host}     // '',
	);

	my $json_encoder = JSON::XS->new->utf8->canonical;

	# Process each configured concept
	for my $concept (@$concept_list)
	{
		$NG->log->debug("MqttObservations: Processing concept '$concept' for $node")
			if $extra_logging;

		my $ids = $S->nmisng_node->get_inventory_ids(
			concept => $concept,
			filter  => {historic => 0},
		);

		if (!@$ids)
		{
			$NG->log->debug("MqttObservations: No inventory for '$concept' on $node")
				if $extra_logging;
			next;
		}

		for my $inv_id (@$ids)
		{
			my ($inventory, $error) = $S->nmisng_node->inventory(_id => $inv_id);
			if ($error)
			{
				$NG->log->warn("MqttObservations: Failed to get inventory $inv_id for '$concept' on $node: $error");
				next;
			}

			my $inv_data = $inventory->data();

			# Determine the index: use the inventory data's index field, fall back to '0'
			my $index = $inv_data->{index} // '0';

			# Sanitize index for use as an MQTT topic component
			my $topic_index = $index;
			$topic_index =~ s|/|_|g;
			$topic_index =~ s/\s+/_/g;

			# Determine the best human-readable description for this instance
			my $description = _get_description($concept, $inv_data);

			# Get latest data for this inventory instance (reads from latest_data collection)
			my $latest = $inventory->get_newest_timed_data();
			if (!$latest->{success} || !$latest->{data})
			{
				$NG->log->debug("MqttObservations: $node No latest data for '$concept', description '$description', index '$index'" . ($latest->{error} ? ": $latest->{error}" : ''))
					if $extra_logging;
				next;
			}

			# Build a list of messages to publish.
			# For catchall/ping, split into one message per subconcept (health, tcp, laload, etc.)
			# For other concepts, publish one message per inventory instance.
			my @messages;

			if ($concept eq 'catchall' || $concept eq 'ping')
			{
				for my $subconcept (sort keys %{$latest->{data}})
				{
					my $sub_data = $latest->{data}{$subconcept};
					next if (!$sub_data || ref($sub_data) ne 'HASH');

					my $renamed_data    = _apply_field_rename($subconcept, $sub_data);
					my $renamed_derived = _apply_field_rename($subconcept,
						_filter_derived($latest->{derived_data}{$subconcept}));

					push @messages, {
						topic   => "$base_topic/$node/$subconcept",
						payload => {
							%envelope,
							'nmis.concept'     => $subconcept,
							'nmis.index'       => $index,
							'nmis.description' => $description,
							'timestamp'        => $latest->{time} // time(),
							%$renamed_data,
							%$renamed_derived,
						},
					};
				}
			}
			else
			{
				my $topic_concept = $CONCEPT_RENAME{$concept} // $concept;

				# Flatten all subconcept data into one hash for this inventory instance
				my %raw_data;
				for my $sub (keys %{$latest->{data}})
				{
					my $sub_data = $latest->{data}{$sub};
					%raw_data = (%raw_data, %$sub_data) if ref($sub_data) eq 'HASH';
				}
				my $renamed_data    = _apply_field_rename($concept, \%raw_data);
				my $renamed_derived = _apply_field_rename($concept,
					_filter_derived_flat($latest->{derived_data}));

				push @messages, {
					topic   => "$base_topic/$node/$topic_concept/" . do {
						my $t = $description;
						$t =~ s|^/+||;
						$t =~ s|/|-|g;
						$t =~ s/:/-/g;
						$t =~ s/\s+/_/g;
						$t ne '' ? $t : $topic_index;
					},
					payload => {
						%envelope,
						'nmis.concept'     => $topic_concept,
						'nmis.index'       => $index,
						'nmis.description' => $description,
						'timestamp'        => $latest->{time} // time(),
						%$renamed_data,
						%$renamed_derived,
					},
				};
			}

			for my $msg (@messages)
			{
				$NG->log->debug("MqttObservations: Publishing to $msg->{topic}") if $extra_logging;

				my $encoded = $json_encoder->encode($msg->{payload});
				my $pub_error = publishMqtt(
					topic    => $msg->{topic},
					message  => $encoded,
					retain   => $retain,
					retries  => $retries,
					server   => $mqtt_config->{server},
					username => $mqtt_config->{username},
					password => $mqtt_config->{password},
				);
				if ($pub_error)
				{
					$NG->log->error("MqttObservations: Failed to publish to $msg->{topic}: $pub_error");
				}

				# Publish to secondary MQTT server if configured
				if ($mqtt_secondary && $mqtt_secondary->{server})
				{
					my $sec_base  = $mqtt_secondary->{topic} // $base_topic;
					my $sec_topic = $sec_base . substr($msg->{topic}, length($base_topic));

					$NG->log->debug("MqttObservations: Publishing to secondary $sec_topic") if $extra_logging;

					my $sec_error = publishMqtt(
						topic    => $sec_topic,
						message  => $encoded,
						retain   => $retain,
						retries  => $retries,
						server   => $mqtt_secondary->{server},
						username => $mqtt_secondary->{username},
						password => $mqtt_secondary->{password},
					);
					if ($sec_error)
					{
						$NG->log->error("MqttObservations: Failed to publish to secondary $sec_topic: $sec_error");
					}
				}
			}
		}
	}

	return (0, undef);    # We publish externally; no NMIS node data was modified
}

# Filter a single derived_data hash: exclude keys beginning with "08" or "16"
# args: hashref (may be undef)
# returns: hashref (possibly empty)
sub _filter_derived
{
	my ($src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my %filtered = map { $_ => $src->{$_} }
		grep { $_ !~ /^(?:08|16)/ } keys %$src;
	return \%filtered;
}

# Flatten a derived_data hash (keyed by subconcept) and filter 08/16 keys.
# args: hashref of subconcept => hashref (may be undef)
# returns: flat hashref (possibly empty)
sub _filter_derived_flat
{
	my ($derived) = @_;
	return {} if (!$derived || ref($derived) ne 'HASH');
	my %out;
	for my $sub (keys %$derived)
	{
		my $filtered = _filter_derived($derived->{$sub});
		%out = (%out, %$filtered);
	}
	return \%out;
}

# Apply OTel field renaming to a flat hashref.
# Known fields are renamed per %FIELD_RENAME; unknown fields get a "nmis." prefix.
sub _apply_field_rename
{
	my ($concept, $src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my $map = $FIELD_RENAME{$concept} // {};
	my %out;
	for my $k (keys %$src)
	{
		next if $k =~ /_raw$/i;    # exclude raw counter fields
		my $new_k = $map->{$k} // "nmis.$k";
		$out{$new_k} = $src->{$k};
	}
	return \%out;
}

# Return the best description string for an inventory instance.
# Tries concept-specific field names first, then generic fallbacks.
sub _get_description
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

sub publishMqtt {
	my %arg = @_;
	my $topic = $arg{topic};
	my $message = $arg{message};
	my $retain = $arg{retain};
	my $retries = int($arg{retries} // 1);
	my $server = $arg{server};
	my $username = $arg{username};
	my $password = $arg{password};

	$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;

	my $last_error;
	for my $attempt (0 .. $retries)
	{
		eval {
			my $mqtt = Net::MQTT::Simple->new($server);
			$mqtt->login($username,$password);

			if ( $retain ) {
				$mqtt->retain($topic => $message);
			}
			else {
				$mqtt->publish($topic => $message);
			}
		};
		if ($@) {
			$last_error = $@;
			next;
		}
		return undef;    # success
	}
	return $last_error;
}

1;
