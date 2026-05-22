#
#  Copyright (C) Keith Sinclair (https://github.com/kcsinclair/)
#  code by Keith, Claude wrote the comments.
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

# Notify::mqttevent - send NMIS events to MQTT topic
# This module can be used to send NMIS events to an MQTT topic. The MQTT topic 
# and server can be configured in the conf/mqttevent.conf file. The module also 
# supports an ignore list of events that should not be sent to MQTT, which can 
# be configured in the conf/mqttIgnoreList.txt file.
# The module is designed to be used as a notification plugin in NMIS, and can be # configured to include extra details in the MQTT message if desired. The MQTT 
# message is sent as a JSON object containing the event details.

# INSTALLATION:
# Check README.md for latest instructions, or https://github.com/kcsinclair/nmis-mqtt-event/blob/main/README.md

# optional extra logging for debugging, set to 1 to enable, 0 to disable.
my $extraLogging = 0;

# *****************************************************************************
package Notify::mqttevent;
our $VERSION="1.0.0";

use strict;

use NMISNG::Util;
use NMISNG::Notify;
use JSON::XS;
use Net::MQTT::Simple;
use Carp;

sub sendNotification
{
	my %arg = @_;
	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $nmisng = $arg{nmisng};

	my $topic;
	my $server;
	my $username;
	my $password;
	my $retain;
	my $retries;
	my $allow_insecure;

	confess("NMISNG argument required!") if (ref($nmisng) ne "NMISNG");
	my $C = $nmisng->config;
	my $mqttConfig = undef;

	# get mqtt config from config file.
	if (!NMISNG::Util::existFile(dir=>'conf',name=>'mqttevent'))
	{
		$nmisng->log->error("conf/mqttevent.nmis not found, mqtt event will not be sent.");
		return 0;
	}

	# loadtable falls back to conf-default if conf doesn't have the file
	$mqttConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'mqttevent');

	if (!$mqttConfig || ref($mqttConfig) ne 'HASH')
	{
		$nmisng->log->error("Failed to load mqttevent configuration, mqtt event will not be sent. Please check conf/mqttevent.nmis file.");
		return 0;
	}

	if ( defined $mqttConfig->{mqtt} and defined $mqttConfig->{mqtt}{server} and $mqttConfig->{mqtt}{server}
		and defined $mqttConfig->{mqtt}{username} and $mqttConfig->{mqtt}{username}
		and defined $mqttConfig->{mqtt}{password} and $mqttConfig->{mqtt}{password}
	)
	{
		$server = $mqttConfig->{mqtt}{server};
		$username = $mqttConfig->{mqtt}{username};
		$password = $mqttConfig->{mqtt}{password};
	}
	else
	{
		$nmisng->log->error("mqtt configuration missing required fields (server, username, password), mqtt event will not be sent. Please check conf/mqttevent.nmis file.");
		return 0;
	}

	if ( defined $mqttConfig->{mqtt}{topic} and $mqttConfig->{mqtt}{topic} )
	{
		$topic = $mqttConfig->{mqtt}{topic};
	}
	else {
		$topic = "nmis/event";
	}

	$extraLogging = NMISNG::Util::getbool($mqttConfig->{mqtt}{extra_logging});
	$retain = int($mqttConfig->{mqtt}{retain} // 1);
	$retries = int($mqttConfig->{mqtt}{retries} // 1);
	# Opt-in: must be set in config before we permit plaintext-MQTT auth
	# (i.e. set MQTT_SIMPLE_ALLOW_INSECURE_LOGIN in Net::MQTT::Simple).
	$allow_insecure = NMISNG::Util::getbool($mqttConfig->{mqtt}{allow_insecure});

	# get the ignorelist from conf/ or conf-default/
	# ignore list file in the form of regexes to match against the event 
	# field of the event. If the event matches any of the regexes, it will 
	# not be sent to mqtt.
	my ($errors,@ignoreList);
	my $ignoreListFile = "$C->{'<nmis_conf>'}/mqttIgnoreList.txt";
	my $ignoreListFileDefault = $C->{'<nmis_conf_default>'}."/mqttIgnoreList.txt";
	if ( -r $ignoreListFile or -r $ignoreListFileDefault ) {
		$ignoreListFile = $C->{'<nmis_conf_default>'}."/mqttIgnoreList.txt" if (!-r $ignoreListFile);
		($errors,@ignoreList) = loadIgnoreList($ignoreListFile, $nmisng);
		$nmisng->log->error($errors) if ($errors);
	}
	else {
		# no logging needed if people don't want to use the feature.
	}

	# is there a valid event coming in?
	if ( defined $event->{node_name} and $event->{node_name} )
	{
		my $node_name = $event->{node_name};

		# is the event in the ignore list? Patterns are pre-compiled qr//
		# refs from loadIgnoreList — invalid entries were dropped there.
		if (not grep { $event->{event} =~ $_ } @ignoreList)
		{
			$nmisng->log->info("Processing mqtt event for $node_name $event->{event}");

			# set this to 1 to include group in the message details, 0 to exclude.
			my $includeGroup = 0;

			### This extra details could be modified to include any other info you want.
			### this code could be removed if extra details not needed.
			# the seperator for the details field.
			my $detailSep = " -- ";

			$nmisng->log->debug(&NMISNG::Log::trace() . "Processing $node_name $event->{event}");
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node_name, snmp=>'false');

			my @detailBits;

			if ( $includeGroup )
			{
				my $catchall_data = $S->inventory( concept => 'catchall' )->data;
				push(@detailBits, $catchall_data->{group});
			}

			push(@detailBits,$event->{details});

			my $details = join($detailSep,@detailBits);

			#remove dodgy quotes
			$details =~ s/[\"|\']//g;

			$event->{details} = $details;

			# cram some extra info into the event
			$event->{node_name} = $node_name;
			$event->{nmis_host} = $C->{server_name};
			# add date string
			my ($sec,$min,$hour,$mday,$mon,$year) = localtime($event->{startdate});
			$year += 1900;
			$mon += 1;
			$event->{date_string} = sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year,$mon,$mday,$hour,$min,$sec);

			my $message = JSON::XS->new->pretty(1)->allow_blessed()->utf8(1)->encode( $event );

			# by default publishes message as topic from configuration with 
			# the node name appended, but this could be modified to use any 
			# topic structure you want.
			my $error = publishMqtt(
					topic => "$topic/$node_name",
					message => $message,
					retain => $retain,
					retries => $retries,
					server => $server,
					username => $username,
					password => $password,
					allow_insecure => $allow_insecure,
				);

			if ($error)
			{
				$nmisng->log->error("ERROR: failed to publishMqtt to $server: $error");
			}
			else
			{
				$nmisng->log->info("mqtt sent to $server: $event->{node_name} $event->{event} $event->{element} $details");
			}

			# is there a secondary MQTT server configured to send to? if so, send to that as well.
			if ( defined $mqttConfig->{mqtt_secondary} and defined $mqttConfig->{mqtt_secondary}{server} and $mqttConfig->{mqtt_secondary}{server} )
			{
				my $error = publishMqtt(
						topic => "$mqttConfig->{mqtt_secondary}{topic}/$node_name",
						message => $message,
						retain => $retain,
						retries => $retries,
						server => $mqttConfig->{mqtt_secondary}{server},
						username => $mqttConfig->{mqtt_secondary}{username},
						password => $mqttConfig->{mqtt_secondary}{password},
						allow_insecure => NMISNG::Util::getbool($mqttConfig->{mqtt_secondary}{allow_insecure}),
					);
				
				if ($error)
				{
					$nmisng->log->error("ERROR: failed to publishMqtt to $mqttConfig->{mqtt_secondary}{server}: $error");
				}
				else
				{
					$nmisng->log->info("mqtt sent to $mqttConfig->{mqtt_secondary}{server}: $event->{node_name} $event->{event} $event->{element} $details");
				}
			}
		}
		else
		{
			$nmisng->log->debug2("event not sent as event in ignore list $event->{node_name} $event->{event} $event->{element}.");
		}
	}
	else
	{
		$nmisng->log->error("no node defined in the event, cannot sendNotification!");
	}
}

# args: path, nmisng (optional, used to log invalid patterns)
# returns (undef, compiled-qr-list) or (error-message)
# Blank lines and lines beginning with '#' are skipped. Each surviving
# line is compiled under eval; entries that fail to compile are logged
# and skipped so a single bad pattern can't crash the notifier.
sub loadIgnoreList
{
	my ($file, $nmisng) = @_;
	my @patterns;

	open(my $fh, '<', $file) or return("cannot open ignore list file $file: $!");
	while (my $line = <$fh>) {
		chomp($line);
		$line =~ s/^\s+|\s+$//g;
		next if $line eq '' || $line =~ /^#/;
		my $compiled = eval { qr/$line/ };
		if ($@ || !defined $compiled) {
			$nmisng->log->warn("mqttIgnoreList: skipping invalid pattern '$line': $@") if $nmisng;
			next;
		}
		push(@patterns, $compiled);
	}
	close($fh);
	return (undef, @patterns);
}

# Object oriented (supports subscribing to topics)
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

	# Net::MQTT::Simple refuses plaintext-MQTT login() unless this env var
	# is set. Only opt in when the caller's config explicitly allows it.
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
			$mqtt->disconnect();
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
