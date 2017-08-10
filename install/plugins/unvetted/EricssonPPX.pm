# a small update plugin for discovering interfaces on FutureSoftware devices
# which requires custom snmp accesses
package EricssonPPX;
our $VERSION = "1.0.1";

use strict;

use Compat::NMIS;												# lnt
use NMISNG::Util;												# for the conf table extras
use NMISNG::rrdfunc;										# for updateRRD
# Customer not running latest code, can not use this
#use snmp 1.1.0;									# for snmp-related access
use Net::SNMP qw(oid_lex_sort);
use Data::Dumper;

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C) = @args{qw(node sys config)};

	my $NC = $S->ndcfg;
	my $NI = $S->ndinfo;
	
	# this plugin deals only with things containing the right data ppxCardMEM
	if ( not defined $NI->{ppxCardMEM} ) {
		info("Prerequisite ppxCardMEM not found in $node");
		return (0,undef) 
	}

	info("Working on $node ppxCardMEM");

	# Get the SNMP Session going.
	#my $snmp = NMISNG::Snmp->new(name => $node);

	my ($session, $error) = Net::SNMP->session(
                           -hostname      => $NC->{node}{host},
                           -port          => $NC->{node}{port},
                           -version       => $NC->{node}{version},
                           -community     => $NC->{node}{community},   # v1/v2c
                        );	
	
	#return (2,"Could not open SNMP session to node $node: ".$snmp->error)
	#		if (!$snmp->open(config => $NC->{node}, host_addr => $NI->{system}->{host_addr}));
	#return (2, "Could not retrieve SNMP vars from node $node: ".$snmp->error)
	#		if (!$snmp->testsession);
	
	my $changesweremade = 0;

	if ( $session ) {
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.fastRam = Gauge32: 0
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.normalRam = Gauge32: 65536
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryCapacityValue.present.0.sharedRam = Gauge32: 2048
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.fastRam = Gauge32: 0
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.normalRam = Gauge32: 37316
		#Nortel-MsCarrier-MscPassport-BaseShelfMIB::mscShelfCardMemoryUsageValue.present.0.sharedRam = Gauge32: 2048    
		
		#"mscShelfCardMemoryCapacityValue"			"1.3.6.1.4.1.562.36.2.1.13.2.244.1.2"
		#"mscShelfCardMemoryUsageValue"			"1.3.6.1.4.1.562.36.2.1.13.2.245.1.2"
	
		my $memCapacityOid = ".1.3.6.1.4.1.562.36.2.1.13.2.244.1.2";
		my $memUsageOid = ".1.3.6.1.4.1.562.36.2.1.13.2.245.1.2";
	
		my $fastRam = "0";
		my $normalRam = "1";
		my $sharedRam = "2";
			
		# based on each of the cards we know about from CPU, we are going to look for each of the memory value.
		foreach my $card (sort keys %{$NI->{ppxCardMEM}}) {
			info("ppxCardMEM card $card");
			
			my $snmpdata = $session->get_request(
				-varbindlist => [
					"$memCapacityOid.$card.$fastRam",
					"$memCapacityOid.$card.$normalRam",
					"$memCapacityOid.$card.$sharedRam",
					"$memUsageOid.$card.$fastRam",
					"$memUsageOid.$card.$normalRam",
					"$memUsageOid.$card.$sharedRam",
				],
			);
	                       
			if ( $snmpdata ) {
				#print Dumper $snmpdata;
				my $data = { 
					'memCapFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memCapacityOid.$card.$fastRam"} },
					'memCapNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memCapacityOid.$card.$normalRam"} },					
					'memCapSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memCapacityOid.$card.$sharedRam"} },
	
					'memUsageFastRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memUsageOid.$card.$fastRam"} },
					'memUsageNormalRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memUsageOid.$card.$normalRam"} },					
					'memUsageSharedRam' => { "option" => "GAUGE,0:U", "value" => $snmpdata->{"$memUsageOid.$card.$sharedRam"} },
				};
				
				# save the results to the node file.
				$NI->{ppxCardMEM}{$card}{'memCapFastRam'} = $snmpdata->{"$memCapacityOid.$card.$fastRam"};
				$NI->{ppxCardMEM}{$card}{'memCapNormalRam'} = $snmpdata->{"$memCapacityOid.$card.$normalRam"};
				$NI->{ppxCardMEM}{$card}{'memCapSharedRam'} = $snmpdata->{"$memCapacityOid.$card.$sharedRam"};
	
				my $filename = NMISNG::rrdfunc::updateRRD(data=>$data, sys=>$S, type=>"ppxCardMEM", index => $card);
				if (!$filename)
				{
					return (2, "UpdateRRD failed!");
				}		
			}
			else {
				info ("Problem with SNMP session to $node: ".$session->error());
	
			}
		}

		$changesweremade = 1;
		return ($changesweremade,undef); # report if we changed anything

	}
	else {
		info ("Could not open SNMP session to node $node: ".$error);
		return (2, "Could not open SNMP session to node $node: ".$error)
	}

}
