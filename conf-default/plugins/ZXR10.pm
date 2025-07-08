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
	my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};

    $NG->log->info("Running update_plugin ZXR10 for node $node");
    
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

		my $servicePortData = $S->nmisng_node->get_inventory_ids(
            concept => "Service_Port",
            filter => { historic => 0 });

		if (@{$servicePortData}){
			for my $id (@{$servicePortData}) {
				my ($inventory, $error) = $S->nmisng_node->inventory(_id => $id);
				if ($error){
					$NG->log->error("Failed to get inventory $id: $error");
					next;
				}
				my $data = $inventory->data();	
				my ($index) = split(/\./, $data->{index}); 
				
				$data->{zxAnSrvPortResType}		= ($index & 0xF0000000) >> 28;
				$data->{zxAnSrvPortResRack}		= ($index & 0x0F000000) >> 24;
				$data->{zxAnSrvPortResShelf}	= ($index & 0x00FF0000) >> 16;
				$data->{zxAnSrvPortResSlot}		= ($index & 0x0000FF00) >> 8;
				$data->{zxAnSrvPortResPort}		= ($index & 0x000000FF);
				
				$NG->log->debug9("data with all the details in Service_Port: ".Dumper($data)."\n");
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