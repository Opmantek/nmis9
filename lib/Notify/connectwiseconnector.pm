#  NMIS - ConnectWise Connector v.2.0.0 - 12 June 2020 Oscar Berlanga
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
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

package Notify::connectwiseconnector;

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use NMISNG;
use Exporter;
use JSON::XS;
use File::Path;
use Data::Dumper;
use HTTP::Tiny;
use MIME::Base64;
use POSIX qw(strftime);
#use func;

eval { require Mojo::UserAgent; };
if ($@) {
    print "ERROR Connectwise authentication method requires Mojo::UserAgent but module not available: $@!";
    return 0;
}

$VERSION = 1.4;

@ISA = qw(Exporter);

@EXPORT = qw(
		sendNotification
	);

@EXPORT_OK = qw(	);

sub sendNotification {
	my %arg = @_;

	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
    my $config = $arg{C};
    my $debug = $arg{debug};

    # TODO: Reuse
	my $nmisng = $arg{nmisng};
    my $logfile = $config->{'<nmis_logs>'} . "/connectwiseConnector.log"; 
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
                                                                debug => $debug),
                                                                path  => $logfile);
    #my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
	# Globals
	my $protocol = 'https'; #Connectwise API requires validate call to be HTTPS
	my $data;
	my @event_array;
	my $isNew;

	#my $config = $nmisng->config();

	my $filename = $config->{connector_file_storage};
	
	# Get auth items for ConnectWise from the config
	my $cw_server = $config->{auth_cw_server};
	my $company_id = $config->{auth_cw_company_id};
	my $public_key = $config->{auth_cw_public_key};
	my $private_key = $config->{auth_cw_private_key};
	my $cw_clientId = $config->{auth_cw_clientId};
	my $ticket_companyId = $config->{cw_ticket_companyId};

	if ($cw_server eq "" || $company_id eq "" || $public_key eq "" || $private_key eq "" || $cw_clientId eq "" || $ticket_companyId eq "") {
	    $nmisng->log->error("ERROR one or more required ConnectWise variables are missing from Config.nmis");
	    exit 0;
	}

	my $contact = $arg{contact};
	my $event = $arg{event};
	my $message = $arg{message};
	my $priority = $arg{priority};
    my $node = $event->{node_name};
    $nmisng->log->debug("Runnning connectwise Connector plugin"); 

    my $nmisnode = $nmisng->node(name => $node);
    if (!$nmisnode) {
        $nmisng->log->error("Event node \"$node\" should be a valid node.");
        return 1;
    }
    my $node_config = $nmisnode->configuration;
	my $eventName = $event->{event};
	my %eventContext = %{$event->{context}};
	my $kw =$eventName;
	
	if($eventName =~ /closed/i){
		$kw	=~ s/ Closed//i;
	}elsif ($eventName =~ /Up/){
		$kw	=~ s/ Up//i;
		$kw .= " Down";
	}elsif ($eventName eq "Service Up"){
		$kw = "Service Degraded";
	}

	# ONLY WORKS ON STATEFUL EVENTS
	if($event->{stateless} != 0) {
		$nmisng->log->error("Connectwise connector. Not a stateful event. Event not reported. ");
		return 1;
	}

	# context and element should match and startdate

	if (-e $filename) {
	   	open my $fh, '<', $filename or die "Can't open file $!";
		read $fh, my $file_content, -s $fh;
		$data = JSON::XS::decode_json($file_content);
		$isNew = 0;
	} else {
		$data = JSON::XS::decode_json("{}");
		$isNew = 1;
	}

	if($message =~ /closed|normal/i){
		if($isNew){
			$nmisng->log->info("No previous records, I can't close an event that I haven't created");
		}else{
			if($data->{$node}->{events}){
				@event_array = @{JSON::XS::decode_json(JSON::XS::encode_json($data->{$node}->{events}))};
				my $index = 0;
				my $ticketID;
				foreach (@event_array){
					my $e = $_;
					my %file_eventContext = %{$e->{context}};
					if($e->{EventName} eq $kw && compare_hashes(\%eventContext, \%file_eventContext) && $e->{startdate} == $event->{startdate} && $e->{element} eq $event->{element}){
						$ticketID = $e->{CWID};
						splice @event_array, $index, 1;
						last;
					}
					$index++
				}

				if(not defined $ticketID){
					$nmisng->log->error("No MATCH found for this event");

				}else{
					my $result = close_ticket($ticketID);
					if($result){
						$data->{$node}->{events} = \@event_array;

						my $toSave = encode_json($data);

						writeToFile($toSave);
						$nmisng->log->info("Event removed from File");
					}
				}
			}else{
				$nmisng->log->info("NO Previous records, I can't close an event that I haven't created");
			}		
		}
	}else{
		if ($data->{$node}->{events}) {
			@event_array = @{decode_json(encode_json($data->{$node}->{events}))};

			my $exist = 0;
			foreach (@event_array){
				my $e = $_;
				my %file_eventContext = %{$e->{context}};
				if($e->{EventName} eq $kw && compare_hashes(\%eventContext, \%file_eventContext) && $e->{startdate} == $event->{startdate} && $e->{element} eq $event->{element}){
					$exist = 1;
					last;
				}
			}

			if($exist){
				$nmisng->log->info("Event $eventName already exist, I can't add it again");
				return;
			}

		}

		my $CWID = create_ticket();

		#BUILD DATA 
		my $EventObj = decode_json("{}");

		$EventObj->{EventName} = $eventName;
		$EventObj->{CWID} = $CWID;
		$EventObj->{date} = time();
		$EventObj->{context} = $event->{context};
		$EventObj->{element} = $event->{element};
		$EventObj->{startdate} = $event->{startdate};

		push(@event_array, $EventObj);

		$data->{$node}->{events} = \@event_array;

		my $toSave = encode_json($data);

		writeToFile($toSave);
	}

	sub getDefaultTicket{
		#We are limited to use this fields, this is a ConnectWise limitation.
		my $ticket = '{
		  "summary": "",
		  "recordType": "ServiceTicket",
		  "status": {
		    "name": ""
		  },
		  "contact": {
		    "name": ""
		  },
		  "company": {
		    "identifier": ""
		  },
		  "contactName": "",
		  "contactPhoneNumber": "",
		  "contactEmailAddress": "",
		  "priority": {
		    "name": ""
		  },
		  "severity": "Low",
		  "impact": "Low",
		  "allowAllClientsPortalView": true,
		  "initialDescription": "",
		  "processNotifications": true,
		  "skipCallback": true,
		  "predecessorType": "Ticket"
		}';
		return decode_json($ticket);
	}

	sub getSeverityFromLevel {
	   my $level = shift;
	   my $severity = "Low";
	   $severity = "Low" if $level =~ 'Warning';
	   $severity = "Medium" if $level =~ 'Minor';
	   $severity = "Medium" if $level =~ 'Major';
	   $severity = "High" if $level =~ 'Critical';
	   $severity = "High" if $level =~ 'Fatal';
	   return $severity;
	}

	sub dateString {
		my $time = shift;
		my $format = "%d-%b-%Y %X %Z"; # output:12-May-2020 04:44:42 AM UTC -- See POSIX::strftime for a list of all formats 
		my $dateString = strftime($format, gmtime($time));
		return $dateString;
	}

	sub sendRequest{
		my ($type,$url,$request_body) = @_;
		# ARGS: $request_body, url
		my $res;
		my $headers = {"Content-type" => 'application/json', Accept => 'application/json', Authorization => 'Basic ' . encode_base64($company_id . '+' . $public_key . ':' . $private_key,''), clientId => $cw_clientId};
		my $client = Mojo::UserAgent->new();
		if ($type eq "post"){
			$res = $client->post($url => $headers => $request_body)->result;
		}elsif ($type eq "get"){
			$res = $client->get($url => $headers)->result;
		}elsif ($type eq "put"){
			$res = $client->put($url => $headers => $request_body)->result;
		}
		return $res;
	}

	sub writeToFile{
		# ARGS: $dataToWrite
		my $dataToWrite = shift;
		# SAVE THE DATA TO THE FILE
		open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";
		print $fh $dataToWrite;
		close $fh;
		$nmisng->log->debug("File Saved: $filename\n");
	}

	sub create_ticket{
		my $contact = $arg{contact};
		my $event = $arg{event};
		my $message = $arg{message};
		my $priority = $arg{priority};
	    my $node = $event->{node_name};
		my $nmisnode = $nmisng->node(name => $node);
        my $node_config = $nmisnode->configuration;
		my $eventElement;

		if(defined $event->{element}){
			$eventElement = $event->{element};
		}else{
			$eventElement = "";
		}

		#Call to generate ticket from data
		my $ticket = getDefaultTicket();
		my $eventDate = dateString($event->{startdate});
		my $summary ="Node: $node at $node_config->{host} Event: $event->{event} $event->{element}";

		my $description = "Node: $node at $node_config->{host}
Event: $event->{event} $eventElement
Details: $event->{details}
Level: $event->{level}
Date: $eventDate
Group: $node_config->{group}
Location: $node_config->{location}
NMIS Sever: $nmisnode->cluster_id";

		# Populate Ticket;
		$ticket->{summary} = $summary;
		$ticket->{company}->{identifier} = $ticket_companyId;
		$ticket->{contact}->{name} = $contact->{Contact};
		$ticket->{contactName} = $contact->{Contact};
		$ticket->{contactPhoneNumber} = $contact->{Mobile};
		$ticket->{contactEmailAddress} = $contact->{Email};
		$ticket->{priority}->{name} = $priority;
		$ticket->{severity} = getSeverityFromLevel($event->{level});
		$ticket->{impact} = getSeverityFromLevel($event->{level});
		$ticket->{initialDescription} = $description;
		$ticket->{location}->{name} = $node_config->{location};

		my $request_body = encode_json($ticket);

		my $url_endpoint = $protocol . "://" . $cw_server. "/v4_6_release/apis/3.0/service/tickets"; 

		my $res = sendRequest("post",$url_endpoint, $request_body);

		my $TID = decode_json($res->body);

	    if ($res->is_success) {
	    	$nmisng->log->info("INFO ConnectWise, Ticket $TID->{id} successfully created!");
	    	return $TID->{id};
	    }
	    elsif ($res->is_error) {
            $nmisng->log->error("ERROR ConnectWise responded with: ". Dumper($TID));
	    	return;
	    }
	    else {
		    $nmisng->log->error("ERROR ConnectWise response failed");
		    return;
	    }
	}

	sub close_ticket{
		my $ticketID = shift;
		my $url_endpoint = $protocol . "://" . $cw_server. "/v4_6_release/apis/3.0/service/tickets/".$ticketID; 
		my $res = sendRequest("get",$url_endpoint,"");
		if ($res->is_success) {
			$nmisng->log->info("INFO ConnectWise, Got Ticket details\n");
			my $update_body = populateUpdateTicket($res);

			# Send the Updated body back to ConnectWise.
			my $update_res = sendRequest("put",$url_endpoint,$update_body);

			if ($update_res->is_success) {
				$nmisng->log->info("INFO ConnectWise, Ticket ". $ticketID ." successfully closed.\n");
				return 1;
			}
			elsif ($update_res->is_error) {
				$nmisng->log->error("ERROR ConnectWise responded with: ". $res->message ."\n");
				return 0;	
			}
			else {
			    $nmisng->log->error("ERROR ConnectWise response failed\n");
			    return 0;
			}
			
		}
		elsif ($res->is_error) {
			$nmisng->log->error("ERROR ConnectWise responded with: ". $res->message ."\n");	
			return 0;	
		}
		else {
		    $nmisng->log->error("ERROR ConnectWise response failed\n");
		    return 0;	
		}
	}

	sub populateUpdateTicket {
		my $response = shift;
		my $content = decode_json($response->body);

		my $new_body = {};
		$new_body->{summary} = $content->{summary};
		$new_body->{status}->{name} = "Closed";
		$new_body->{company}->{id} = $content->{company}->{id};
		$new_body->{team}->{id} = $content->{team}->{id};
		$new_body->{board}->{id} = $content->{board}->{id};
		$new_body->{priority}->{id} = $content->{priority}->{id};
		$new_body->{severity} = $content->{severity};
		$new_body->{impact} = $content->{impact};

		return encode_json($new_body);
	}

	sub compare_hashes {
		my ($first, $second) = @_;
		foreach my $k (keys %{ $first }) {
			if (not exists $second->{$k}) {
				return 0;
			} elsif (not defined $first->{$k} and not defined $second->{$k}) {
				next;
			} elsif (defined $first->{$k} and not defined $second->{$k}) {
				return 0;
			} elsif (not defined $first->{$k} and defined $second->{$k}) {
				return 0;
			} elsif ($first->{$k} ne $second->{$k}) {
				return 0;
			}
		}
		return 1;
	}

}

1;