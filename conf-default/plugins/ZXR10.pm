package ZXR10;
our $VERSION = "1.0.0";

use lib "$FindBin::Bin/../../lib";
use strict;
use Data::Dumper;
use NMISNG;														# lnt
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use NMISNG::Snmp;
use NMISNG::DB;

#use snmp 1.1.0;
use Net::SNMP qw(oid_lex_sort);


sub update_plugin
{	
	my $changesweremade = 0;
	my (%args) = @_;
	my ($node,$S,$C,$NG,$node_obj) = @args{qw(node sys config nmisng node_obj)};

    $NG->log->info("Running update_plugin ZXR10 for node $node");
    
	#my $S = NMISNG::Sys->new(nmisng => $NG);
	my $nodeobj = $node_obj;
	#$S->init(node => $nodeobj, snmp => 0); # load node info and Model if name exists
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $IF = $nodeobj->ifinfo;
	my $MDL = $S->mdl;
            
	my $NC = $nodeobj->configuration;

	$NG->log->debug9(sub {"\$node: ".Dumper \$nodeobj});
	$NG->log->debug9(sub {"\$S: ".Dumper \$S});
	$NG->log->debug9(sub {"\$C: ".Dumper \$C});
	$NG->log->debug9(sub {"\$NG: ".Dumper \$NG});

	my $max_repetitions = $NC->{max_repetitions} || $C->{snmp_max_repetitions};
	my %nodeconfig = %{$NC};

	return (1,undef) if ( $catchall_data->{nodeModel} ne "ZTE-ZXR10" or !NMISNG::Util::getbool($catchall_data->{collect}));
   
	# open snmp session
	my $snmp = NMISNG::Snmp->new(
			nmisng => $NG,
			name  => $node,
		);

	if (!$snmp->open(config => \%nodeconfig ))
	{
		$NG->log->error("Could not open SNMP session to node $node: ".$snmp->error);
	}
	else
	{ 
		my $ONTTxPower = $snmp->getindex("1.3.6.1.4.1.3902.1082.500.20.2.2.2.1.14",$max_repetitions);
		my $ONTRxPower = $snmp->getindex("1.3.6.1.4.1.3902.1082.500.20.2.2.2.1.10",$max_repetitions);
		my $ONTVoltage = $snmp->getindex("1.3.6.1.4.1.3902.1082.500.20.2.2.2.1.17",$max_repetitions);

		my $CPULoad = $snmp->getindex("1.3.6.1.4.1.3902.3.6002.2.1.1.9",$max_repetitions);
		my $MemUsage = $snmp->getindex("1.3.6.1.4.1.3902.3.6002.2.1.1.34",$max_repetitions);		
		my $servicePortData = $S->nmisng_node->get_inventory_ids(
            concept => "Service_Port_ZTE",
            filter => { historic => 0 });

		if (@{$servicePortData}){
			for my $id (@{$servicePortData}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				my ($index,$sub_index) = split(/\./, $data->{index}); 
				
				$data->{zxAnSrvPortResType}		= ($index & 0xF0000000) >> 28;
				$data->{zxAnSrvPortResRack}		= ($index & 0x0F000000) >> 24;
				$data->{zxAnSrvPortResShelf}	= ($index & 0x00FF0000) >> 16;
				$data->{zxAnSrvPortResSlot}		= ($index & 0x0000FF00) >> 8;
				$data->{zxAnSrvPortResPort}		= ($index & 0x000000FF);
								
				$data->{zxAnSubIfIndex} =  ($sub_index >> 16) & 0x7FF;

				$inventory->data($data);
				$inventory->save(node => $node_obj);
			}
		}
		
		my $systemMemCard = $S->nmisng_node->get_inventory_ids(
            concept => "zxr10SystemCard",
            filter => { historic => 0 });

		if (@{$systemMemCard}){
			for my $id (@{$systemMemCard}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				my $index = $data->{index};

				# grab the required index for CPU Load and Mem Usage
				$index = $index.".0";				
				$data->{'zxAnCardMemUsage'} =  $MemUsage->{$index};
				$data->{'zxAnCardCpuLoad'} = $CPULoad->{$index};				
				$inventory->data($data);
				$inventory->save(node => $node_obj);
			}
		}

		my $gponTrfcData =  $S->nmisng_node->get_inventory_ids(
            concept => "zxr10GponTrfc",
            filter => { historic => 0 });
		if (@{$gponTrfcData}){
			for my $id (@{$gponTrfcData}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				my ($index,$sub_index) = split(/\./, $data->{index}); 

				$data->{zxAnSrvPortResRack}		= ($index & 0x0F000000) >> 24;
				$data->{zxAnSrvPortResShelf}	= ($index & 0x00FF0000) >> 16;
				$data->{zxAnSrvPortResSlot}		= ($index & 0x0000FF00) >> 8;
				$data->{zxAnSrvPortResPort}		= ($index & 0x000000FF);									
				$data->{zxAnSubIfIndex} =  (( 0 + $sub_index) >> 16) & 0x7FF;
								
				$inventory->data($data);
				$inventory->save(node => $node_obj);
			}
		}


		my $gponDeviceData =  $S->nmisng_node->get_inventory_ids(
            concept => "zxr10GponDevice",
            filter => { historic => 0 });

		if ($gponDeviceData){
			for my $id (@{$gponDeviceData}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();					
				
				my $index = $data->{index}; 
				$index = $index.".1";
				
				# $NG->log->debug(sub {"index is ".Dumper($index)});
				# $NG->log->debug(sub {"Power is ".Dumper($ONTTxPower)});
				$data->{zxAnGponRmAniTxOptLevel} = $ONTTxPower->{$index} * 0.001;
				$data->{zxAnGponRmAniRxOptLevel} = $ONTRxPower->{$index} * 0.001;
				$data->{zxAnGponRmAniPowerFeedVoltage} = $ONTVoltage->{$index};

				if ($data->{zxAnGponRmOnuSerialNum}){
					$data->{zxAnGponRmOnuSerialNum} = decode_onu_serial($NG,$data->{zxAnGponRmOnuSerialNum});
					$NG->log->debug(sub {"zxAnGponRmOnuSerialNum after is ".Dumper($data->{zxAnGponRmOnuSerialNum})});
				}
				if ($data->{zxAnGponSrvOnuLastOnlineTime}){
					$data->{zxAnGponSrvOnuLastOnlineTime} = snmp_hex_to_datetime($NG,$data->{zxAnGponSrvOnuLastOnlineTime});
					$data->{zxAnGponSrvOnuLastOfflineTime} = snmp_hex_to_datetime($NG,$data->{zxAnGponSrvOnuLastOfflineTime});								
				}
					$inventory->data($data);
					$inventory->save(node => $node_obj);
			}
		}

	}

	return (1,undef);
}


# sub to decode onu serial number
# input hex serial number
# output undef or vendorid-decimal serial number
sub decode_onu_serial {
     my ($NG,$hex) = @_;
    $hex =~ s/^0x//i;
    my @bytes = unpack("C*", pack("H*", $hex));

    my $vendor_id = join('', map { chr($_) } @bytes[0..3]);
    my $serial_hex = sprintf("%02x%02x%02x%02x", @bytes[4..7]);
    my $serial_dec = unpack("N", pack("H*", $serial_hex));  # unsigned 32-bit
	
	if ($serial_dec == 0){
		return undef;		
	}
	else{
		return 	$vendor_id.uc($serial_hex)
	}
		
}

# convert hex time to date and time
# input hex
# output time in a date-time format.
sub snmp_hex_to_datetime {
    my ($NG,$hex) = @_;
    $hex =~ s/^0x//i;  # remove leading 0x if present
    my @bytes = unpack("C*", pack("H*", $hex));
	
	# Check minimum length
    $NG->log->debug( "Invalid SNMP DateAndTime hex string") if @bytes < 7;

    my ($year, $month, $day, $hour, $minute, $second) = (
        ($bytes[0] << 8) + $bytes[1],
        $bytes[2],
        $bytes[3],
        $bytes[4],
        $bytes[5],
        $bytes[6]
    );

	return undef if ($year == 0);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                   $year, $month, $day, $hour, $minute, $second);
}

sub collect_plugin
{
	return (1,undef);
}