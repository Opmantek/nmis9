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
# OTel rename maps and helpers are shared with the NMIS MCP server; see
# lib/NMISNG/OTel.pm. CONCEPT_RENAME is referenced fully-qualified below.
use NMISNG::OTel qw(apply_field_rename get_description filter_derived filter_derived_flat);

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

	# This plugin only ever talks plaintext MQTT (Net::MQTT::Simple, never the
	# TLS subclass), and login() croaks unless MQTT_SIMPLE_ALLOW_INSECURE_LOGIN
	# is set. allow_insecure defaults ON when the key is absent so existing
	# configs keep publishing; set it to 0 to explicitly forbid plaintext auth.
	my $allow_insecure = defined($mqtt_config->{allow_insecure})
		? NMISNG::Util::getbool($mqtt_config->{allow_insecure})
		: 1;
	my $allow_insecure_secondary = ($mqtt_secondary && defined($mqtt_secondary->{allow_insecure}))
		? NMISNG::Util::getbool($mqtt_secondary->{allow_insecure})
		: 1;

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
			my $description = get_description($concept, $inv_data);

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

					my $renamed_data    = apply_field_rename($subconcept, $sub_data);
					my $renamed_derived = apply_field_rename($subconcept,
						filter_derived($latest->{derived_data}{$subconcept}));

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
				my $topic_concept = $NMISNG::OTel::CONCEPT_RENAME{$concept} // $concept;

				# Flatten all subconcept data into one hash for this inventory instance
				my %raw_data;
				for my $sub (keys %{$latest->{data}})
				{
					my $sub_data = $latest->{data}{$sub};
					%raw_data = (%raw_data, %$sub_data) if ref($sub_data) eq 'HASH';
				}
				my $renamed_data    = apply_field_rename($concept, \%raw_data);
				my $renamed_derived = apply_field_rename($concept,
					filter_derived_flat($latest->{derived_data}));

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
					topic          => $msg->{topic},
					message        => $encoded,
					retain         => $retain,
					retries        => $retries,
					server         => $mqtt_config->{server},
					username       => $mqtt_config->{username},
					password       => $mqtt_config->{password},
					allow_insecure => $allow_insecure,
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
						topic          => $sec_topic,
						message        => $encoded,
						retain         => $retain,
						retries        => $retries,
						server         => $mqtt_secondary->{server},
						username       => $mqtt_secondary->{username},
						password       => $mqtt_secondary->{password},
						allow_insecure => $allow_insecure_secondary,
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

sub publishMqtt {
	my %arg = @_;
	my $topic = $arg{topic};
	my $message = $arg{message};
	my $retain = $arg{retain};
	my $retries = int($arg{retries} // 1);
	my $server = $arg{server};
	my $username = $arg{username};
	my $password = $arg{password};
	my $allow_insecure = $arg{allow_insecure};

	# Net::MQTT::Simple refuses plaintext-MQTT login() unless this env var is
	# set. Only opt in when the caller's config allows it, and localize the
	# change so we don't mutate the process environment for everything else.
	local $ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = $allow_insecure ? 1 : $ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN};

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
