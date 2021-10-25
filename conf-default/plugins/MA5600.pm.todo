package MA5600;
our $VERSION = "1.1.0";

use strict;
use Data::Dumper;
use func;									
use rrdfunc;
use NMIS;				
use snmp 1.1.0;						


sub collect_plugin
{
	my $changesweremade = 0;
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $LNT = loadLocalNodeTable();
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $NC = $S->ndcfg;

	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};
	my %nodeconfig = %{$NC->{node}};

	return (1,undef) if ( $NI->{system}{nodeModel} ne "Huawei-MA5600" or !getbool($NI->{system}->{collect}));
   
	# open snmp session
	my $snmp = snmp->new(name => $node);

	if (!$snmp->open(config => \%nodeconfig ))
	{
		logMsg("Could not open SNMP session to node $node: ".$snmp->error);
	}
	else
	{ 

		my $ifName_data = $snmp->getindex("1.3.6.1.2.1.31.1.1.1.1",$max_repetitions);
		my $ONTDescr_data = $snmp->getindex("1.3.6.1.4.1.2011.6.128.1.1.2.43.1.9",$max_repetitions);
    my $ONT_SerialNumber = $snmp->getindex("1.3.6.1.4.1.2011.6.128.1.1.2.43.1.3",$max_repetitions);

		my $interfaces = {};

		foreach my $keys (sort keys %$ifName_data) {
			if($ifName_data->{$keys} =~ /GPON/){
				my @i = split(/\ /,$ifName_data->{$keys});
				my @j = split(/\//,@i[1]);
				$interfaces->{@j[1]}{@j[2]} = $keys;
			}
		}

		my $GponUserTraffic = $S->{info}{GponUserTraffic};

		foreach my $keys (sort keys %$GponUserTraffic) {
			if($S->{info}{GponUserTraffic}{$keys}{MultiSerUserPara} == 100 || $S->{info}{GponUserTraffic}{$keys}{MultiSerUserPara} == 400){
				my $card = $S->{info}{GponUserTraffic}{$keys}{hwExtSrvFlowPara2}; 
				my $port = $S->{info}{GponUserTraffic}{$keys}{hwExtSrvFlowPara3};
				my $ONT_ID = $S->{info}{GponUserTraffic}{$keys}{hwExtSrvFlowPara4};
				my $if_index = $interfaces->{$card}{$port};
				my $ind = "$interfaces->{$card}{$port}.$ONT_ID";
				$S->{info}{GponUserTraffic}{$keys}{ONTBASE} = "Service_Port $card\/$port\/$ONT_ID";

				$S->{info}{GponUserTraffic}{$keys}{element} = $ind;

				if ($ONTDescr_data->{$ind} ne undef) {
					$S->{info}{GponUserTraffic}{$keys}{ONTDescription} = $ONTDescr_data->{$ind};
				}
				else {
					$S->{info}{GponUserTraffic}{$keys}{ONTDescription} = "Not Found";
				}
				if ($ONT_SerialNumber->{$ind} ne undef) {
					my $serial_number = $ONT_SerialNumber->{$ind};
					if ( $serial_number !~ /^0x/ ) {
						# pack the hex into text
						$serial_number = "0x". unpack('H*', $serial_number);
					}
					$S->{info}{GponUserTraffic}{$keys}{ONTSerialNumber} = $serial_number;
				}
				else {
					$S->{info}{GponUserTraffic}{$keys}{ONTSerialNumber} = "Not Found";
				}
			} 
			else {
				delete($S->{info}{GponUserTraffic}{$keys});
				delete($S->{info}{graphtype}{$keys});
			}
		}
	}
	return (1,undef); 
}


sub update_plugin
{
	return (1,undef);
}
