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
				$inventory->save;
				
			}
		}
	}

	return (1,undef);
}


sub collect_plugin
{
	return (1,undef);
}