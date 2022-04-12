package MA5600;
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

#use snmp 1.1.0;
use Net::SNMP qw(oid_lex_sort);


sub update_plugin
{
	my $changesweremade = 0;
	my (%args) = @_;
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

    $NG->log->info("Running update_plugin MA5600 for node $node");
    
	#my $S = NMISNG::Sys->new(nmisng => $NG);
	my $nodeobj = $NG->node(name => $node);
	#$S->init(node => $nodeobj, snmp => 0); # load node info and Model if name exists
	my $catchall_data = $S->inventory( concept => 'catchall' )->{_data};

	my $IF = $nodeobj->ifinfo;	
	my $MDL = $S->mdl;
            
	my $NC = $nodeobj->configuration;

	$NG->log->debug9("\$node: ".Dumper \$nodeobj);
	$NG->log->debug9("\$S: ".Dumper \$S);
	$NG->log->debug9("\$C: ".Dumper \$C);
	$NG->log->debug9("\$NG: ".Dumper \$NG);

	my $max_repetitions = $NC->{max_repetitions} || $C->{snmp_max_repetitions};
	my %nodeconfig = %{$NC};

	return (1,undef) if ( $catchall_data->{nodeModel} ne "Huawei-MA5600" or !NMISNG::Util::getbool($catchall_data->{collect}));
   
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

		my $ifTableData = $S->nmisng_node->get_inventory_ids(
            concept => "ifTable",
            filter => { historic => 0 });
		 
		my $ifName_data;
		if (@$ifTableData)
        {
			for my $ifTableId (@$ifTableData) {
				my ($gpon_traffic, $error) = $S->nmisng_node->inventory(_id => $ifTableId);
				if ($error)
				{
					$NG->log->error("Failed to get inventory $ifTableId: $error");
					next;
				}
				my $data = $gpon_traffic->data();
				
				$ifName_data->{$data->{index}} = $data->{ifName};
			}
			
		}

		my $ONTDescr_data = $snmp->getindex("1.3.6.1.4.1.2011.6.128.1.1.2.43.1.9",$max_repetitions);
		# already collected in GPON_Device
		#		  'hwGponDeviceOntSn' => {
		#			'oid' => '1.3.6.1.4.1.2011.6.128.1.1.2.43.1.3',
		#			'title' => 'ONTSerialNumber',
		#			'title_export' => 'ONTSerialNumber',
		#		  },
        my $ONT_SerialNumber = $snmp->getindex("1.3.6.1.4.1.2011.6.128.1.1.2.43.1.3",$max_repetitions);

		my $interfaces = {};

		foreach my $keys (sort keys %$ifName_data) {
			if($ifName_data->{$keys} =~ /GPON/){
				my @i = split(/\ /,$ifName_data->{$keys});
				my @j = split(/\//,@i[1]);
				$interfaces->{@j[1]}{@j[2]} = $keys;
			}
		}

		my $GponUserTrafficIds = $S->nmisng_node->get_inventory_ids(
            concept => "GponUserTraffic",
            filter => { historic => 0 });
			
        if (@$GponUserTrafficIds)
        {
            for my $GponUserTrafficId (@$GponUserTrafficIds)
            {
                my ($gpon_traffic, $error) = $S->nmisng_node->inventory(_id => $GponUserTrafficId);
                if ($error)
                {
                    $NG->log->error("Failed to get inventory $GponUserTrafficId: $error");
                    next;
                }
                my $data = $gpon_traffic->data();
                if($data->{MultiSerUserPara} == 100 || $data->{MultiSerUserPara} == 400) {
                    $NG->log->debug("Updating inventory id ".$gpon_traffic->id);
                    my $card = $data->{hwExtSrvFlowPara2}; 
                    my $port = $data->{hwExtSrvFlowPara3};
                    my $ONT_ID = $data->{hwExtSrvFlowPara4};
                    my $if_index = $interfaces->{$card}{$port};
                    my $ind = "$interfaces->{$card}{$port}.$ONT_ID";
                    $data->{ONTBASE} = "Service_Port $card\/$port\/$ONT_ID";
    
                    $data->{element} = $ind;
    
                    if ($ONTDescr_data->{$ind} ne undef) {
                        $data->{ONTDescription} = $ONTDescr_data->{$ind};
                    }
                    else {
                        $data->{ONTDescription} = "Not Found";
                    }
                    if ($ONT_SerialNumber->{$ind} ne undef) {
                        my $serial_number = $ONT_SerialNumber->{$ind};
                        if ( $serial_number !~ /^0x/ ) {
                            # pack the hex into text
                            $serial_number = "0x". unpack('H*', $serial_number);
                        }
                        $data->{ONTSerialNumber} = $serial_number;
                    }
                    else {
                        $data->{ONTSerialNumber} = "Not Found";
                    }
                    
                    $gpon_traffic->data($data); # set changed info
                    (undef,$error) = $gpon_traffic->save; # and save to the db
                    $NG->log->error("Failed to save inventory for ".$gpon_traffic->id. " : $error")
                            if ($error);
                } 
                else {
                    my ($ok, $error) = $gpon_traffic->delete(keep_rrd => 0);
                    $NG->log->debug("Removing inventory id ".$gpon_traffic->id);
                    return (0, "Failed to delete inventory ".$gpon_traffic->id.": $error")
                            if (!$ok);
                }
                
            }
        }
		
		# Fix hwGponDeviceOntPassword
		my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => {'$in' => ["GPON_Device"]});
		
		if (@$sectionIds)
		{	
			my %gponDeviceIndex;
					
			for my $sectionId (@$sectionIds)
			{
				my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
				if ($error)
				{
					$NG->log->error("Failed to get inventory $sectionId: $error");
					next;
				}
				my $data = $section->data();
				if ( $data->{hwGponDeviceOntPassword} ) {
					my $d = $data->{hwGponDeviceOntPassword};
					$d =~ s/[^\d]//g;
					# Save if we have made changes
					if ($d ne $data->{hwGponDeviceOntPassword})
					{
						$data->{hwGponDeviceOntPassword} = $d;
						$section->data($data); # set changed info
						(undef,$error) = $section->save; # and save to the db
						$NG->log->error("Failed to save inventory for ".$section->id. " : $error")
								if ($error);
					}
				}
			}
		}
				
	}
	return (1,undef); 
}


sub collect_plugin
{
	return (1,undef);
}