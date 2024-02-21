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
#
# a small update plugin for manipulating QualityOfServiceStat

package Aviat;
our $VERSION = "1.0.0";

use strict;
use warnings;
###use diagnostics;
use lib "$FindBin::Bin/../../lib";
use NMISNG::rrdfunc;

use Data::Dumper;

sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	my $sub = 'update';
	my $plugin = 'Aviat.pm';
	my $concept = 'ifTable';
	my $inventory_data_key = 'index';

    my $nodeobj = $NG->node(name => $node);
    my $inv = $S->inventory( concept => 'catchall' );
	my $catchall_data = $inv->data;

	my $IF = $nodeobj->ifinfo;	
	my $MDL = $S->mdl;
            
	my $NC = $nodeobj->configuration;

	my $max_repetitions = $NC->{max_repetitions} || $C->{snmp_max_repetitions};
	my %nodeconfig = %{$NC};

	return (0,undef) if ( $catchall_data->{nodeModel} ne "NL-Aviat" or !NMISNG::Util::getbool($catchall_data->{collect}));

	$NG->log->info("$plugin:$sub: Running for node $node");

	$NG->log->debug9(sub {"\$node: ".Dumper \$nodeobj});
	$NG->log->debug9(sub {"\$S: ".Dumper \$S});
	$NG->log->debug9(sub {"\$C: ".Dumper \$C});
	$NG->log->debug9(sub {"\$NG: ".Dumper \$NG});

	my $changesweremade = 0;

	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => $concept,
		filter => { historic => 0 });

	if (@$ids)
	{
		$NG->log->debug9(sub {"$plugin:$sub: \$ids: ".Dumper $ids});
		$NG->log->debug9(sub {"$plugin:$sub: \$S->{mdl}{systemHealth}{sys}{$concept}: ".Dumper \%{$S->{mdl}{systemHealth}{sys}{$concept}}});

        my $active = 0;
        
        for my $ifTableId (@$ids)
        {
                my ($ifTable, $error) = $S->nmisng_node->inventory(_id => $ifTableId);
                if ($error)
                {
                    $NG->log->error("Failed to get inventory $ifTableId: $error");
                    next;
                }
                my $data = $ifTable->data();
          
                my $interface_data;
                foreach my $w (qw(index Description ifAdminStatus ifDescr ifHighSpeed ifLastChange ifOperStatus ifSpeed ifType)) {
                    $interface_data->{$w} = $data->{$w};
                }
				# to keep path keys similar to other interfaces
                $interface_data->{index} = $data->{index};
                $interface_data->{ifIndex} = $data->{index};
                $interface_data->{collect} = "true";
                $interface_data->{interface} = $data->{ifDescr};
                $interface_data->{Description} = $data->{ifDescr};
								
                if ($data->{ifAdminStatus} eq "up") {
                   $active++;
                }
				# must use path keys
                my $path_keys = ['index'];
                my $path = $nodeobj->inventory_path( concept => 'interface', path_keys => $path_keys, data => $interface_data );

                my ($inventory,$error_message) = $nodeobj->inventory(
                    concept => 'interface',
                    path => $path,
                    path_keys => $path_keys,
                    create => 1
                );
                $NG->log->error("Failed to get inventory for device_global, error_message:$error_message")
                        if(!$inventory);
                # create is set so we should have an inventory here
                if($inventory)
                {
                    # not sure why supplying the data above does not work, needs a test!
                    $inventory->data( $interface_data );
                    $inventory->historic(0);
                    $inventory->enabled(1);
                    # disable for now
                    $inventory->data_info( subconcept => 'interface', enabled => 0 );
                    my ($op,$error) = $inventory->save( node => $node );
                    $NG->log->debug2(sub { "saved ".join(',', @$path)." op: $op"});
                    $NG->log->info( "saved ".join(',', @$path)." op: $op");
                } else {
                    $NG->log->error("No inventory");
                }
                $NG->nmisng->log->error("Failed to save inventory, error_message:$error") if($error);
        }
        $changesweremade = 1;
        $catchall_data->{ifNumber} = $ids;
        $catchall_data->{active} = $active;
        $inv->data($catchall_data);
        my ($op,$error) = $inv->save( node => $node );
        $NG->log->info( "saved catchall op: $op");
        
	}
	else
	{
		$NG->log->debug("$plugin:$sub: 'if(\@\$ids)' returned false");
	}

	return ($changesweremade,undef); # report if we changed anything
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};
	
	my @knownindices;
	my $changesweremade = 0;
	return (0,undef) if ($S->{mdl}->{system}->{nodeModel} ne "NL-Aviat");

	my $IFitems = $S->nmisng_node->get_inventory_ids(
		concept => "interface");
	
				
	if (@$IFitems)
	{
		for my $ifTableId (@$IFitems)
		{
			my ($ifTable, $ierror) = $S->nmisng_node->inventory(_id => $ifTableId);
			if ($ierror)
			{
				$NG->log->error("Failed to get inventory $ifTableId: $ierror");
				next;
			}
			my $data = $ifTable->data();
			$ifTable->historic(0);
			$ifTable->data($data);
			my ($op, $serror) = $ifTable->save( node => $node );
			$NG->log->debug2(sub {"Inventory update: $op "});
			if ($serror)
			{
				$NG->log->error("Failed to save inventory $ifTableId: $serror");
				next;
			}
		}
	}
	$changesweremade = 1;
	return ($changesweremade,undef);
}


1;
