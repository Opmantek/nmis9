package RS421;
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
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

    $NG->log->info("Running update_plugin RS420 for node $node");
    
	#my $S = NMISNG::Sys->new(nmisng => $NG);
	my $nodeobj = $NG->node(name => $node);
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

	return (1,undef) if ( $catchall_data->{nodeModel} ne "xxxTeldat-OSDX-RS420" or !NMISNG::Util::getbool($catchall_data->{collect}));
   
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
        
        # $NG->log->info("Dummy log for debugging");
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
				$inventory->save(node => $node);
				
			}
		}

		my $interfaces = $S->nmisng_node->get_inventory_ids(
            concept => "interface",
            filter => { historic => 0 });

		if (@{$interfaces}){            
			# load ifTable
			my $IFT = NMISNG::Util::loadTable(dir => "conf", name => "ifTypes", conf => $C);
			my @list_get_oids;
            my $oids_map;    
            # default oid map
            my $oids = {
                '1.3.6.1.4.1.2007.6.3.1.1.1.1.15'         => 161,  # ieee8023adLag
                '1.3.6.1.4.1.2007.6.3.1.4.1.1.15'         => 53,   # propVirtual
                '1.3.6.1.4.1.2007.6.3.1.4.5.1.1.15'       => 53,   # propVirtual
                '1.3.6.1.4.1.2007.6.3.1.4.5.2.1.1.15'     => 53,   # propVirtual
                '1.3.6.1.4.1.2007.6.3.1.6.1.1.16'         => 243,  # wwanPP
                '1.3.6.1.4.1.2007.6.3.1.6.5.1.1.16'       => 243,  # wwanPP
                '1.3.6.1.4.1.2007.6.3.1.7.1.1.15'         => 131,  # tunnel
                '1.3.6.1.4.1.2007.6.3.1.10.1.1.15'        => 6,    # ethernetCsmacd
                '1.3.6.1.4.1.2007.6.3.1.10.4.1.1.15'      => 6,    # ethernetCsmacd
                '1.3.6.1.4.1.2007.6.3.1.10.4.2.1.1.15'    => 6,    # ethernetCsmacd
                '1.3.6.1.4.1.2007.6.3.1.11.1.1.15'        => 24,   # softwareLoopback
                '1.3.6.1.4.1.2007.6.3.1.13.1.1.15'        => 131,  # tunnel
                '1.3.6.1.4.1.2007.6.3.1.14.1.1.15'        => 131,  # tunnel
                '1.3.6.1.4.1.2007.6.3.3.1.1.1'            => 71,   # ieee80211
            };
			# $NG->log->debug(sub {" Arihant ifDescr: ".Dumper $oidWalk});
			for my $id (@{$interfaces}) {
                # initialize final variable						
                            

				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				my $ifType = $data->{ifType};
				my $index;
                
				# grab the index for the ifType
				foreach my $idx (keys %{$IFT}) {
 				   if ($IFT->{$idx}->{ifType} eq $ifType) {
        				$index = $idx;
    				}
				}
                $NG->log->debug(sub {"index is $index, descr is ".$inventory->description() });
				my $ifDescr = $data->{ifDescr};
				# convert ifDescr to decimal			
				my $alias_oid = str_to_ascii_string($ifDescr);								
				# add index to alias oid
				$alias_oid = $index.".".$alias_oid;				

				foreach my $oid (keys %{$oids}){
					my $oid_type = $oids->{$oid};
                    if ($oid_type eq $index){
                        my $dummy_oid = $oid.".".$alias_oid;                        
                        push(@{$oids_map->{$ifDescr}},$dummy_oid);
                        push(@list_get_oids,$dummy_oid);
                    }                									                    
                }		                				
                
            }

            my $result = $snmp->get(@list_get_oids);
            $NG->log->debug(sub {"\$list_get_oids for : ".Dumper \@list_get_oids});
            $NG->log->debug(sub {"\$list_get_oids for : ".Dumper $oids_map});
            $NG->log->debug(sub {"\$result for : ".Dumper $result});
		}
	}

	return (1,undef);
}

sub str_to_ascii_string {
    my ($str) = @_;
    return join('.', map { ord($_) } split('', $str));
}

sub collect_plugin
{
	return (1,undef);
}