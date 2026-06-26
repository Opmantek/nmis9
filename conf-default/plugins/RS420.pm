package RS420;
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

sub getTeldatInventory {

	my (%args) = @_;
	my ($node,$S,$C,$NG,$section,$thissection,$node_obj) = @args{qw(node sys config nmisng section thissection node_obj)};
	$NG->log->info("Running getTeldatInventory RS420 for node $node");

	my $nodeobj = $node_obj;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $IF = $nodeobj->ifinfo;	
	my %ifDescr_to_index = map {
    	$IF->{$_}{ifDescr} => $_
	} keys %{$IF};
	my $MDL = $S->mdl;
            
	my $NC = $nodeobj->configuration;

	my $max_repetitions = $NC->{max_repetitions} || $C->{snmp_max_repetitions};
	my %nodeconfig = %{$NC};


	# initialize SNMP
	my $snmpTable;
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
		# grab the 6.3 table for TELDAT
		$snmpTable = $snmp->gettable("1.3.6.1.4.1.2007.6.3");	
		return (undef,"Unable to get SNMP table data") if (! $snmpTable);
		my %patterns = (								
				out	=> 	{
						class   			 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.1\.2\.1\.1\.1\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedPackets  	 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.1\.2\.1\.1\.2\.(?:\d+)\.(.+)\.(\d+)$/,						
						MatchedBytes  		 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.1\.2\.1\.1\.3\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedDropsPackets  => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.1\.2\.1\.1\.4\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedOverLimits  	 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.1\.2\.1\.1\.5\.(?:\d+)\.(.+)\.(\d+)$/
						},
				in	=> {
						class   			 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.2\.2\.1\.1\.1\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedPackets  	 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.2\.2\.1\.1\.2\.(?:\d+)\.(.+)\.(\d+)$/,						
						MatchedBytes  		 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.2\.2\.1\.1\.3\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedDropsPackets  => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.2\.2\.1\.1\.4\.(?:\d+)\.(.+)\.(\d+)$/,
						MatchedOverLimits  	 => qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.((?:\d+\.)*\d+)(?=\.6)\.6\.2\.2\.1\.1\.5\.(?:\d+)\.(.+)\.(\d+)$/
						}
					);

		my %rows;   # temporary aggregator, keyed by [direction][description][class]		
		foreach my $dir (keys %patterns) {
			
			if($section =~ /.*(in|out)$/) {
 				my $section_direction = $1;
				next if ($dir ne $section_direction);
			}
			
    		foreach my $metric (keys %{ $patterns{$dir} }) {
        		my $regex = $patterns{$dir}{$metric};
        		foreach my $oid (keys %{$snmpTable}) {
            	if ($oid =~ $regex) {
                		my ($interfaceMapping, $descr, $class) 	= ($1, $2, $3);	
						my $interfaceMappingBit = ($interfaceMapping =~ /^\d+$/) ? 6 : 4;						
						my $ascii_descr  = ascii_to_str_string($descr);				
						$rows{"$dir|$descr|$class"}{index}    			= $descr.".".$class;
						$rows{"$dir|$descr|$class"}{description} 		= $ascii_descr;
						$rows{"$dir|$descr|$class"}{ifIndex} 			= $ifDescr_to_index{$ascii_descr};
                		$rows{"$dir|$descr|$class"}{class}    			= $class;
                		$rows{"$dir|$descr|$class"}{direction}     		= $dir;
						$rows{"$dir|$descr|$class"}{interfaceMapping} 	= $interfaceMapping;
						$rows{"$dir|$descr|$class"}{interfaceMappingBit} = $interfaceMappingBit;						
                		$rows{"$dir|$descr|$class"}{$metric} 			= $snmpTable->{$oid};
					}
				}
			}
		}

		# initialize the target to be put into inventory
		my $targets = {};
		
		# traverse rows to create a final index and put that in target.
		foreach my $item (keys %rows){
			
			my $direction_oid;			
			if ($rows{$item}{direction} eq 'in'){
				$direction_oid = '6.2.2.1.1.2.6';				
			}
			elsif($rows{$item}->{direction} eq 'out'){
				$direction_oid = '6.1.2.1.1.2.6';				
			}
	
			my $index = $rows{$item}{index};
			$rows{$item}{index} = $index;
			
			$targets->{$index} = $rows{$item};							
		}
		
		return $targets;		
	}
}
sub update_plugin
{	
	my $changesweremade = 0;
	my (%args) = @_;
	my ($node,$S,$C,$NG,$node_obj) = @args{qw(node sys config nmisng node_obj)};

    $NG->log->info("Running update_plugin RS420 for node $node");

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

	return (1,undef) if ( $catchall_data->{nodeModel} ne "Teldat-OSDX-RS420" or !NMISNG::Util::getbool($catchall_data->{collect}));
   
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
        my $name = $snmp->getindex("1.3.6.1.4.1.2007.6.3.4.2.1.1.1.1",$max_repetitions);
        my $oidWalk = $snmp->gettable("1.3.6.1.4.1.2007.6.3",$max_repetitions);
        my $IFT = NMISNG::Util::loadTable(dir => "conf", name => "ifTypes", conf => $C);		
							
		my $servicePortData = $S->nmisng_node->get_inventory_ids(
            concept => "teldatNQA",
            filter => { historic => 0 });		

		if (@{$servicePortData}){
			for my $id (@{$servicePortData}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				
                my $index = $data->{index};
                $index =~ s/\.\d+$//;
                #adding in the operation entry
                $data->{"telOSDxMonDBServiceNsmOperationEntry"} = $name->{$index};

				$inventory->data($data);
				$inventory->save(node => $nodeobj, update => 1);
				
			}
		}

		my $interfaces = $S->nmisng_node->get_inventory_ids(
            concept => "interface",
            filter => { historic => 0 });

		if (@{$interfaces}){
			# grab  all the data table for oid 1.3.6.1.4.1.2007.6.3 
			
			# load ifTable
			my @description_oids = (
				'1.3.6.1.4.1.2007.6.3.1.1.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.4.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.4.5.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.4.5.2.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.6.1.1.16',
				'1.3.6.1.4.1.2007.6.3.1.6.5.1.1.16',
				'1.3.6.1.4.1.2007.6.3.1.7.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.10.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.10.4.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.10.4.2.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.11.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.13.1.1.15',
				'1.3.6.1.4.1.2007.6.3.1.14.1.1.15',
				'1.3.6.1.4.1.2007.6.3.3.1.1.1'								
			);					

			my @list_index_oids = (
						'1.3.6.1.4.1.2007.6.3.1.1.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.1.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.1.4.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.3.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.3.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.3.4.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.4.5.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.4.5.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.5.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.6.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.6.5.1.1.15',
						'1.3.6.1.4.1.2007.6.3.1.7.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.8.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.8.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.8.4.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.9.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.10.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.10.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.10.4.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.11.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.12.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.13.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.13.4.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.13.4.2.1.1.14',
						'1.3.6.1.4.1.2007.6.3.1.14.1.1.14',
					);
			
			my %index_oid_table;		

			for my $oid (@list_index_oids) {				
				for my $key (keys %{$oidWalk}) {
					if (index($key, $oid) != -1) {  # substring match 
						my $index = $oidWalk->{$key};           			

						# grab the substring of $key after $oid
						if ($key =~ /^(\Q$oid\E)\.(.*)$/) {
							my $prefix          = $1;   # same as $oid
							my $rest            = $2;   # part after $oid
							my ($interfaceMapping, $logicalMapping);

							if ($oid =~ /^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.(\d+)\.(.*)$/) {
								$interfaceMapping = $1;
								$logicalMapping   = $2;
							}

							# Example condition on rest
							if ($logicalMapping eq "1.1.14") {
								$index_oid_table{$index}{"is_logical"} = 0;
							}
							else {
								$index_oid_table{$index}{"is_logical"} = 1;
							}

							$index_oid_table{$index}{"interfaceMapping"} = $interfaceMapping;	
							$index_oid_table{$index}{"oid"}              = $key;
							$index_oid_table{$index}{"alias"}            = $rest;
						}
					}
				}
			}		
			$NG->log->debug2(sub {"index_oid_table is ".Dumper(\%index_oid_table)."\n"});
			for my $id (@{$interfaces}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				# add empty items which are to be used in calculate_oid/index
				$data->{"interfaceMapping"} = "";
				$data->{"indexAlias"} = "";
				$data->{"is_logical"} = "";
				my $ifIndex = $data->{ifIndex};
				
				if (defined ($index_oid_table{$ifIndex})){
					$data->{"is_logical"}  = $index_oid_table{$ifIndex}{"is_logical"};
					$data->{"interfaceMapping"}  = $index_oid_table{$ifIndex}{"interfaceMapping"};
					$data->{"indexAlias"}  = $index_oid_table{$ifIndex}{"alias"};
					$NG->log->debug3(sub{"found data for ifIndex=$ifIndex, is_logical=$data->{is_logical} interfaceMapping=$data->{interfaceMapping} indexAlias=$data->{indexAlias}"});
				} else {
					$NG->log->info("NO found data for ifIndex=$ifIndex");
				}

 				# now looking for Alias description by joining oids and its alias.
				foreach my $desc_oid (@description_oids){
					my $match;
					# if its logical add in the oid part to match logical oid.
					if ($data->{"is_logical"} ){
						$match = $desc_oid.'.4.'.$data->{"indexAlias"};	
					}
					else{
						$match = $desc_oid.'.'.$data->{"indexAlias"};
					}					
					if (exists $oidWalk->{$match}){
						$data->{"Description"} = $oidWalk->{$match};	
					}
				}

				my $in_speed_pattern  = qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.(\d+)(\.\d+)?\.6\.2\.1\.1\.8\.\Q$data->{"indexAlias"}\E$/;
				my $out_speed_pattern = qr/^1\.3\.6\.1\.4\.1\.2007\.6\.3\.1\.(\d+)(\.\d+)?\.6\.1\.1\.1\.8\.\Q$data->{"indexAlias"}\E$/;				
				
				foreach my $oid (keys %{$oidWalk}) {
					if ($oid =~ $in_speed_pattern) {
						my $interfaceMapping = $1;  # captures the (\d+)

						$data->{"ifSpeedIn"} = $oidWalk->{$oid};							
						$NG->log->debug1("IN Matched OID=$oid with index=$interfaceMapping, value=$oidWalk->{$oid}\n");
						}
						if ($oid =~ $out_speed_pattern) {
						
						my $interfaceMapping = $1;  # captures the (\d+)
						$data->{"ifSpeedOut"} = $oidWalk->{$oid};							
						$NG->log->debug1("OUT Matched OID=$oid with index=$interfaceMapping, value=$oidWalk->{$oid}\n");
					}
				}

				$inventory->data($data);
				my ( $op, $error ) = $inventory->save(node => $nodeobj, update => 1);
				$NG->log->error("Failed to save inventory, error during save: $error") if ($error);
			}
		}
	}

	return (1,undef);
}

sub str_to_ascii_string {
    my ($str) = @_;
    return join('.', map { ord($_) } split('', $str));
}

sub ascii_to_str_string {
    my ($ascii_str) = @_;
    my @codes = split(/\./, $ascii_str);
    return join('', map { $_ < 10 ? '.' : chr($_) } @codes);
}


sub collect_plugin
{
	return (1,undef);
}