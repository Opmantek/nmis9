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

package NodeValidation;
our $VERSION = "2.0.1";


use Data::Dumper;
#node is the current node which is about to be update
#returns 1 or 0 if the node is valid or not and a list of errors
sub update_valid
{
    my (%args) = @_;
    my ($node, $C ,$NG) = @args{qw(node config nmisng)};
 
    my @errors = ();
    
    
    ## check if the device_ci already exists or not ?
    my $current_device_ci =  $node->configuration->{device_ci};
    my $current_host = $node->configuration->{host};
    if ( validate_ci('ci_field' => $current_device_ci,node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, "The CI field alredy exists in the database";
    }
    if ( validate_host('current_host' => $current_host,node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, "The Hostname alredy registered to another device in the database";
    }

    if ( validate_IP_addr('current_host' => $current_host,node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, "The primary or backup monitoring IP address is already associated with another device.";
    }
 
    return (scalar(@errors), @errors);
}

# return 1 if host exists in db , 
# return 0 if host does not exists in db.
sub validate_IP_addr
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host,$host_backup) = @args{qw(node config nmisng host host_backup)};
    
    $NG->log->info("Validating IP address :- Checking if Primary and backup monitoring addresses are already associated or not ?");

    my $node_configuration = $node->configuration;
    
    my ($ip, $bkp_ip);
    if ($node_configuration>{ip_protocol} eq 'IPv6')
	{
		$ip = NMISNG::Util::resolveDNStoAddrIPv6($host);
        $bkp_ip = NMISNG::Util::resolveDNStoAddrIPv6($host_backup);
	}
	else
	{
		$ip = NMISNG::Util::resolveDNStoAddr($host);
        $bkp_ip = NMISNG::Util::resolveDNStoAddrIPv6($host_backup);
	}

    my $md = $NG->get_inventory_model(concept => "catchall");
    if (my $error = $md->error)
	{
		$self->log->error("Failed to get inventory model: $error");
        return 1;
	}
    foreach my $entry ( @{$md->data}){
        # will the primary and backup montoting ip address will be checked simultaneously for a single node !!
        if ($entry->{data}->{host_addr} eq $ip || $entry->{data}->{host_addr_backup} eq $bkp_ip ){
            return 1;
        }
    }

    return 0;
}


# return 1 if host exists in db , 
# return 0 if host does not exists in db.
sub validate_host
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host) = @args{qw(node config nmisng current_host)};
    
    $NG->log->info("Validating Host :- Checking if Hostname is already registered or not ?");
    
    my $model_data = $NG->get_nodes_model(fields_hash => {  name => 1, 
                                                            'configuration.host' => 1
                                                        } );   
    
    if (my $error = $model_data->error)
	{
		$self->log->error("Failed to get nodes model: $error");
        return 1;
	}
    
    my $data = $model_data->data();
    ## check if the given device ci exists in db
    
    foreach my $entry(@{$data}){
        if ($entry->{configuration}->{host} eq $host){            
            return 1;
        }        
    }

	return 0;
}




# return 1 if device ci exists in db , 
# return 0 if device ci does not exists in db.
sub validate_ci
{
    my (%args) = @_;
    my ($node, $C ,$NG,$CIF) = @args{qw(node config nmisng ci_field)};
    
    $NG->log->info("Validating CI field :- Checking if CI already exists or not ?");
    
    my $model_data = $NG->get_nodes_model(fields_hash => {  name => 1, 
                                                            'configuration.device_ci' => 1
                                                        } );   
    
    if (my $error = $model_data->error)
	{
		$self->log->error("Failed to get nodes model: $error");
        return 1;
	}
    
    my $data = $model_data->data();
    ## check if the given device ci exists in db
    
    foreach my $entry(@{$data}){
        if ($entry->{configuration}->{device_ci} eq $CIF){            
            return 1;
        }        
    }

	return 0;
}
 
sub create_valid
{
    my (%args) = @_;
    my ($node, $C ,$NG) = @args{qw(node config nmisng)};
    return (1, undef);
}
1;