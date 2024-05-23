#
#  Copyright Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
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
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
# README!
# You will need to setup an API Token for Netatmo, you can find some details here:
# https://dev.netatmo.com/apidocumentation/oauth#using-a-token
# Login to dev.netatmo.com and create a new app and use the Token generator to make them.
# https://dev.netatmo.com/apps/
# Then you will need to copy /usr/local/nmis9/conf-default/Netatmo.json to /usr/local/nmis9/conf and fill in the details.
# If you have multiple stations you will need to set the station name of the station you require in station_name.
# if station_name is blank it will match one of them but may not be the one you prefer, most people only have one station.
# <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

package Netatmo;
our $VERSION = "1.0.0";

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Data::Dumper;
use JSON::XS;
use LWP::UserAgent;

use NMISNG;
use NMISNG::rrdfunc;

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	# load the catchall data, first get the catchall inventory object
	my ($inventory,$error) = $S->inventory(concept => 'catchall');
	return ( error => "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall_data = $inventory->data();
	# if this node isn't using the model type Netatmo, move along.
	return (1,undef) if $catchall_data->{nodeModel} ne "Netatmo";

	$NG->log->debug("Running Netatmo Collect plugin for node::$node");
	
	my $changesweremade = 0;

	# No run the API request to get the data.
	my $data = getNetatmoData(node => $node, NG => $NG, C => $C);

	if ( $data ) {
		$changesweremade = 1;
		$NG->log->debug("Got NetAtmo data: " . Dumper $data);

		#save to integers to RRD, multiply reals by 100, graphs will divide by 100
		my $rrddata = {
			'temperature' => { "option" => "gauge,0:U", "value" => $data->{outdoor}{Temperature} * 100 },
			'humidity' => { "option" => "gauge,0:U", "value" => $data->{outdoor}{Humidity} },
			'pressure' => { "option" => "gauge,0:U", "value" => $data->{indoor}{Pressure} * 100 }
		};

		# ensure the RRD file is using the inventory record so it will use the correct RRD file.

		# does inventory here need to be the catchall inventorty!
		#my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>$section, index=>$name, inventory=>$serv_inventory);
		my $updatedrrdfileref = $S->create_update_rrd(data=>$rrddata, type=>"weather", index => undef);

		# check for RRD update errors
		if (!$updatedrrdfileref) { $NG->log->info("Update RRD failed!") };
	}

	return ($changesweremade,undef); # report if we changed anything
}

# The logic here is specific to Netatmo, it will deal with the API, refresh tokens and get your weather data.
sub getNetatmoData {
	my %args           = @_;
	my $NG     = $args{NG};
	my $C     = $args{C};
	my $node    = $args{node};

	my $netatmoConfFile = "$C->{'<nmis_conf>'}/Netatmo.json";

	if ( not -r $netatmoConfFile ) {
		$NG->log->error("Can not read Netatmo Config file $netatmoConfFile for node::$node");
		return undef;
	}

	my $netatmoConf = loadJsonFile($netatmoConfFile);

	my $APP_ID = $netatmoConf->{client_id};
	my $APP_SECRET = $netatmoConf->{client_secret};
	my $ACCESS_TOKEN = $netatmoConf->{access_token};
	my $REFRESH_TOKEN = $netatmoConf->{refresh_token};
	my $EXPIRES_IN = $netatmoConf->{expires_in};
	my $STATION_NAME = $netatmoConf->{station_name};

	my $TOKEN_URL = 'https://api.netatmo.net/oauth2/token';
	my $DEVICELIST_URL = 'https://api.netatmo.net/api/devicelist';
	my $MEASURE_URL = 'https://api.netatmo.net/api/getmeasure';
	
	my $weather;
	
	my $ua = LWP::UserAgent->new;
	  
	# set custom HTTP request header fields
	my $req = HTTP::Request->new(POST => $TOKEN_URL);
	$req->header('content-type' => 'application/x-www-form-urlencoded');
	$req->header('Authorization' => "Bearer $ACCESS_TOKEN");
	
	$req->content(
	      "grant_type=refresh_token"
	      ."&refresh_token=$REFRESH_TOKEN"
	      ."&client_id=$APP_ID"
	      ."&client_secret=$APP_SECRET"
	);
	
	my $resp = $ua->request($req);
	my $message = undef;
	my $access_token = undef;
	my $refresh_token = undef;
	my $expires_in = undef;
	if ($resp->is_success) {
		$message = $resp->decoded_content;
		$NG->log->debug("Received reply: $message");
	}
	else {
		print "HTTP POST error code: ", $resp->code, "\n";
		print "HTTP POST error message: ", $resp->message, "\n";
		$NG->log->debug3(sub {Dumper $resp});
	}
	
	my $status = 0;

	if ( defined $message ) {
		my $na_message = decode_json $message;
		$NG->log->debug3(sub {"access_token=$na_message->{access_token}"});
		$access_token = $na_message->{access_token};
		$refresh_token = $na_message->{refresh_token};
		$expires_in = $na_message->{expires_in};

		if ( $ACCESS_TOKEN ne $access_token ) {
			$NG->log->debug("Updating: access tokens don't match, updating cache");
			$netatmoConf->{access_token} = $access_token;
		}
		
		if ( $REFRESH_TOKEN ne $refresh_token ) {
			$NG->log->debug("ERROR: refresh tokens don't match");
		}

		# update the expires data
		$netatmoConf->{expires_in} = $expires_in;

		my $indoor_id;
		my $outdoor_id;
		
		#### GET DEVICE LIST
		my $req = HTTP::Request->new(POST => $DEVICELIST_URL);
		$req->header('content-type' => 'application/x-www-form-urlencoded');
		
		$req->content(
					"access_token=$access_token"
		);
	
		my $resp = $ua->request($req);

		if ($resp->is_success) {
		    $message = $resp->decoded_content;
			my $netatmo = decode_json $message;
			foreach my $device (@{$netatmo->{body}{devices}}) {
				# we might get many devices, we only want one!
				if ( $device->{station_name} eq $STATION_NAME or $STATION_NAME eq "" ) {
					# save the device ID to find its matching outdoor module
					$indoor_id = $device->{_id};
					$NG->log->debug("Found Station $device->{station_name}, module_name: $device->{module_name} $indoor_id: Temperature=$device->{dashboard_data}{Temperature} Humidity=$device->{dashboard_data}{Humidity} Pressure=$device->{dashboard_data}{Pressure} Noise=$device->{dashboard_data}{Noise}");
					$NG->log->debug2(sub {Dumper $device});

					$weather->{indoor}{Temperature} = $device->{dashboard_data}{Temperature};
					$weather->{indoor}{Humidity} = $device->{dashboard_data}{Humidity};
					$weather->{indoor}{Pressure} = $device->{dashboard_data}{Pressure};
					$weather->{indoor}{Noise} = $device->{dashboard_data}{Noise};
					$weather->{indoor}{CO2} = $device->{dashboard_data}{CO2};
				}
			}
			foreach my $module (@{$netatmo->{body}{modules}}) {
				# we only want the outdoor module for the station name of interest.
				if ( $module->{main_device} eq $indoor_id ) {
					$outdoor_id = $module->{_id};
					$NG->log->debug("Station $indoor_id, module_name: $module->{module_name}, $outdoor_id: Temperature=$module->{dashboard_data}{Temperature} Humidity=$module->{dashboard_data}{Humidity}");
					$NG->log->debug2(sub {Dumper $module});

					$weather->{outdoor}{Temperature} = $module->{dashboard_data}{Temperature};
					$weather->{outdoor}{Humidity} = $module->{dashboard_data}{Humidity};
				}
			}
			$weather->{time} = time();
		}
		
		#save back the conf file to get the updated tokens and expire times.
		saveData($netatmoConfFile,$netatmoConf);

		# save a cache of the weather data for others to use.
		saveData($netatmoConf->{netatmo_cache},$weather);

		$NG->log->debug(Dumper $weather);	
	}
	else {
		print STDERR "ERROR: problem getting access token from NetAtmo.\n";
	}	
	
	# send back the results.
	return ($weather);
}

sub loadJsonFile {
	my $file = shift;
	my $data = undef;
	my $errMsg;

	open(FILE, $file) or $errMsg = "ERROR File '$file': $!";
	if ( not $errMsg ) {
		local $/ = undef;
		my $JSON = <FILE>;

		# fallback between utf8 (correct) or latin1 (incorrect but not totally uncommon)
		$data = eval { decode_json($JSON); };
		$data = eval { JSON::XS->new->latin1(1)->decode($JSON); } if ($@);
		if ( $@ ) {
			$errMsg = "ERROR Unable to convert '$file' to hash table (neither utf-8 nor latin-1), $@\n";
		}
		close(FILE);
	}

	return ($errMsg,$data);
}

sub saveData {
	my $file = shift;
	my $data = shift;
	
	open(OUT,">$file") or die "Problem with $file: $!\n";
	print OUT encode_json $data;
	close OUT;
	
	return 1;
}

1;
