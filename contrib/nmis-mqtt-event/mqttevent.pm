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

	confess("NMISNG argument required!") if (ref($nmisng) ne "NMISNG");
	my $C = $nmisng->config;

	# get mqtt config from config file.
	if (NMISNG::Util::existFile(dir=>'conf',name=>'mqttevent')) {
		# loadtable falls back to conf-default if conf doesn't have the file
		my $mqttConfig = NMISNG::Util::loadTable(dir=>'conf',name=>'mqttevent');
		$topic = $mqttConfig->{mqtt}{topic};
		$server = $mqttConfig->{mqtt}{server};
		$username = $mqttConfig->{mqtt}{username};
		$password = $mqttConfig->{mqtt}{password};
		$extraLogging = NMISNG::Util::getbool($mqttConfig->{mqtt}{extra_logging});
	}

	# get the ignorelist from conf/ or conf-default/
	# ignore list file in the form of regexes to match against the event 
	# field of the event. If the event matches any of the regexes, it will 
	# not be sent to mqtt.
	my ($errors,@ignoreList);
	my $ignoreListFile = "$C->{'<nmis_conf>'}/mqttIgnoreList.txt";
	my $ignoreListFileDefault = $C->{'<nmis_conf_default>'}."/mqttIgnoreList.txt";
	if ( -r $ignoreListFile or -r $ignoreListFileDefault ) {
		$ignoreListFile = $C->{'<nmis_conf_default>'}."/mqttIgnoreList.txt" if (!-r $ignoreListFile);
		($errors,@ignoreList) = loadIgnoreList($ignoreListFile);
		$nmisng->log->error($errors) if ($errors);
	}
	else {
		# no logging needed if people don't want to use the feature.
	}

	# is there a valid event coming in?
	if ( defined $event->{node_name} and $event->{node_name} )
	{
		my $node_name = $event->{node_name};

		# is the node in the ignore list?
		if (not grep { $event->{event} =~ /$_/ } @ignoreList)
		{
			$nmisng->log->info("Processing mqtt event for $node_name $event->{event}");

			my $info = 1;

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
						retain => 0,
						server => $server,
						username => $username,
						password => $password
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
			if ( defined $C->{mqtt_secondary} and defined $C->{mqtt_secondary}{server} and $C->{mqtt_secondary}{server} )
			{
				my $error = publishMqtt(
							topic => "$C->{mqtt_secondary}{topic}/$node_name", 
							message => $message, 
							retain => 0,
							server => $C->{mqtt_secondary}{server},
							username => $C->{mqtt_secondary}{username},
							password => $C->{mqtt_secondary}{password}
						);
				
				if ($error)
				{
					$nmisng->log->error("ERROR: failed to publishMqtt to $C->{mqtt_secondary}{server}: $error");
				}
				else
				{
					$nmisng->log->info("mqtt sent to $C->{mqtt_secondary}{server}: $event->{node_name} $event->{event} $event->{element} $details");
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

# args: path
# returns (undef,blacklist items) or (error message)
sub loadIgnoreList
{
	my $file = shift;
	my @lines;

	open(IN,$file) or return("cannot open ignore list file $file: $!");
	while (<IN>) {
		chomp();
		push(@lines,$_);
	}
	close(IN);
	return (undef,@lines);
}

# Object oriented (supports subscribing to topics)
sub publishMqtt {
	my %arg = @_;
	my $topic = $arg{topic};
	my $message = $arg{message};
	my $retain = $arg{retain};
	my $server = $arg{server};
	my $username = $arg{username};
	my $password = $arg{password};

	$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
 
	my $mqtt = Net::MQTT::Simple->new($server);
	$mqtt->login($username,$password);

	if ( $retain ) {
		$mqtt->retain($topic => $message);	
	}
	else {
		$mqtt->publish($topic => $message);
	}
}

1;
