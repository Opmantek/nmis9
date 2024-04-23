# ****************************************************************************
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
    my $current_host_bkp = $node->configuration->{host_backup};
    if ( my $error = validate_ci('ci_field' => $current_device_ci,node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }
    if ( my $error = validate_host('current_host' => $current_host,node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }
    if ( $error = validate_IP_addr('host' => $current_host,'host_backup' => $current_host_bkp, node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }

    # if ( validate_IP_addr('host' => $current_host,'host_backup' => $current_host_bkp, node => $node,config => $C, nmisng=>$NG))
    # {
    #     push @errors, "The primary or backup monitoring IP address is already associated with another device.";
    # }
 
    return (scalar(@errors), @errors);
}

# return 1 if host exists in db , 
# return 0 if host does not exists in db.
sub validate_IP_addr
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host,$host_backup) = @args{qw(node config nmisng host host_backup)};
    
    $NG->log->info("Validating IP address :- Checking if Primary and backup monitoring addresses are already associated or not ?");


   
    ## check if its an update or insert ?
    my $model_data = $NG->get_nodes_model(      filter => {uuid => $node->uuid },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'configuration.host' => 1,
                                                                  'configuration.host_backup' => 1
                                                        } );   
    
    if (my $error = $model_data->error)
	{
		$NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating IP field.");
	}
    
    my $data = $model_data->data();
    if (@{$data}){
        ## UPDATE
        ## if no changes in host on update
        if ($data->[0]->{configuration}->{host} eq $host && $data->[0]->{configuration}->{host_backup} eq $host_backup){
            $NG->log->info("No changes in host and backup host for the ".$node->name.", validation complete."); 
            return 0;            
        }
        else{
            ## check if ip and backup if are part of some other db or not ?
            my ($error,$status) = db_ip_check(node=> $node,nmisng=> $NG,host => $host,host_backup => $host_backup);
            if ($status){
                ## all good host does not exist anywhere
                return 0;
            }
            else{
                $message = "IP and Backup IP monitoring address is already present in nodes:- ".$error;
                return ($message);
            }
        }
    }
    else{
        ## INSERT
        ## check if ip and backup if are part of some other db or not ?
            my ($error,$status) = db_ip_check(node=> $node,nmisng=> $NG,host => $host,host_backup => $host_backup);
            if ($status){
                ## all good host does not exist anywhere
                return 0;
            }
            else{
                $message = "IP and Backup IP monitoring address is already present in nodes:- ".$error;
                return ($message);
            }
    }
}   



## db check for ip.
sub db_ip_check
{
    my (%args) = @_;
    my ($node,$NG,$host,$host_backup) = @args{node,nmisng,host,host_backup};

    $NG->log->info("db_ip_check ");
    my $node_configuration = $node->configuration;
    
    my ($ip, $bkp_ip);
    if ($node_configuration->{ip_protocol} eq 'IPv6')
	{
		$ip = NMISNG::Util::resolveDNStoAddrIPv6($host);
        $bkp_ip = NMISNG::Util::resolveDNStoAddrIPv6($host_backup);
	}
	else
	{
		$ip = NMISNG::Util::resolveDNStoAddr($host);
        $bkp_ip = NMISNG::Util::resolveDNStoAddr($host_backup);
	}

    my $query = NMISNG::DB::get_query(
                                        and_part => {  concept => "catchall",
                                                        node_uuid => { '$ne' => $node->uuid } },
										
                                        or_part => {
                                            'data.host_addr' => $ip ,
                                            'data.host_addr_backup' => $bkp_ip 
                                        }
                                    );

    my $fields_hash = {        
                        'node_name'  => 1,
                        'node_uuid' => 1,
                        'concept'  => 1,
                        'data.host_addr' => 1,
                        'data.host_addr_backup' => 1
                    };


    my $entries = NMISNG::DB::find(
		            collection  => $NG->inventory_collection,
		            query       => $query,
                    fields_hash => $fields_hash                                  
                    );

    my @all;
	while ( my $entry = $entries->next )
	{
		push @all, $entry;
	}
    $NG->log->info("entries are ".Dumper(\@all));
    if (@all){
        foreach my $entry(@all){
            push @names,$entry->{node_name};
            

        }
        return(@names,0);
    }
    else{
         ## all good it does not exist anywhere else.
        return (undef,1);
    }

}




# return 1 if host exists in db , 
# return 0 if host does not exists in db.
sub validate_host
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host) = @args{qw(node config nmisng current_host)};
    
    $NG->log->info("Validating Host :- Checking if Hostname is already registered or not ?");

      ## check if its an update or insert ?
    my $model_data = $NG->get_nodes_model(      filter => {uuid => $node->uuid },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'configuration.host' => 1
                                                        } );   
    
    if (my $error = $model_data->error)
	{
		$NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating CI field.");
	}
    
    my $data = $model_data->data();
    if (@{$data}){
        ## UPDATE
        $NG->log->info("CALLING UPDATE");
        if ($host eq $data->[0]->{configuration}->{host}){
            $NG->log->info("No changes in CI field, validation complete."); 
            return 0;
        }
        else{

            ## given host does not match with the one present in db.
            ## check if the host exists in db for any other node or not ?

            my ($error,$status) = db_host_check(nmisng=> $NG,host => $host);
            if ($status){
                ## all good host does not exist anywhere
                return 0;
            }
            else{
                $message = "HOST is already present in nodes:- ".$error;
                return ($message);
            }

        }
    }
    else{
        ## INSERT
        $NG->log->info("CALLING INSERT");
        my ($error,$status) = db_host_check(nmisng=> $NG,host => $host);
        if ($status){
            ## all good CI does not exist anywhere
            return 0;
        }
        else{
            $message = "HOST is already present in nodes:- ".$error;
            return ($message);
        }
    }

}
## db check for host.
sub db_host_check
{
    my (%args) = @_;
    my ($NG,$host) = @args{nmisng,host};

     ## check if the host is present in db for any node 
    my $model_data = $NG->get_nodes_model( filter => {'configuration.host' => $host },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'configuration.device_ci' => 1
                                                        } );   
    if (my $error = $model_data->error)
	{
		$NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating CI field.",0);
	}
    
    my $data = $model_data->data();
    if (@{$data}){
        my @names;
        foreach my $entry(@{$data}){
            push @names,$entry->{name};
        }
        return(@names,0);
    }
    else{
        ## all good it does not exist anywhere else.
        return (undef,1);
    }
    

}


# return 1 if device ci exists in db , 
# return 0 if device ci does not exists in db.
sub validate_ci
{
    my (%args) = @_;
    my ($node, $C ,$NG,$CIF) = @args{qw(node config nmisng ci_field)};
    
    $NG->log->info("Validating CI field :- Checking if CI already exists or not ?");


    ## check if its an update or insert ?
    my $model_data = $NG->get_nodes_model(      filter => {uuid => $node->uuid },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'configuration.device_ci' => 1
                                                        } );   
    
    if (my $error = $model_data->error)
	{
		$NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating CI field.");
	}
    
    my $data = $model_data->data();
    if (@{$data}){
        ## UPDATE
        $NG->log->info("CALLING UPDATE");
        if ($CIF eq $data->[0]->{configuration}->{device_ci}){
            $NG->log->info("No changes in CI field, validation complete."); 
            return 0;
        }
        else{
            ## given ci field does not match with the one present in db.
            ## check if the field exists in db for any other node or not ?

            my ($error,$status) = db_ci_check(nmisng=> $NG,custom_field => $CIF);
            if ($status){
                ## all good CI does not exist anywhere
                return 0;
            }
            else{
                $message = "CI field already present in nodes:- ".$error;
                return ($message);
            }
        }

    }
    else{
        $NG->log->info("CALLING INSERT");
           ## check if the field exists in db for any other node or not ?

            my ($error,$status) = db_ci_check(nmisng=> $NG,custom_field => $CIF);
            if ($status){
                ## all good CI does not exist anywhere
                return 0;
            }
            else{
                $message = "CI field already present in nodes:- ".$error;
                return ($message);
            }
        }
}
 

## db check for ci field.
sub db_ci_check
{
    my (%args) = @_;
    my ($NG,$custom_field) = @args{nmisng,custom_field};

     ## check if the ci field is present in db for any node 
    my $model_data = $NG->get_nodes_model( filter => {'configuration.device_ci' => $custom_field },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'configuration.device_ci' => 1
                                                        } );   
    if (my $error = $model_data->error)
	{
		$NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating CI field.",0);
	}
    
    my $data = $model_data->data();
    if (@{$data}){
        my @names;
        foreach my $entry(@{$data}){
            push @names,$entry->{name};
        }
        return(@names,0);
    }
    else{
        ## all good it does not exist anywhere else.
        return (undef,1);
    }
    

}



sub create_valid
{
    my (%args) = @_;
    my ($node, $C ,$NG) = @args{qw(node config nmisng)};
    return (1, undef);
}
1;