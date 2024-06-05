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
our $VERSION = "2.1.1";
# NodeValidation::validate_node
# NodeValidation::validate_IP_addr
# NodeValidation::validate_host
# what this validates:
#  ci - should be unique and present on each node
#  host/host_backup - cannot match with any other host,hostbackup,host_addr,host_addr_backup
#  host_addr/host_addr_backup - cannot match with any other host,hostbackup,host_addr,host_addr_backup

# FOR TESTING - set these to make the host/host_backup resolve
# to these IP's
our ($test_ip, $test_backup_ip) = ("","");
sub set_test_ips {
    my ($set_ip,$set_backup_ip) = @_;    
    $test_ip = $set_ip;
    $test_backup_ip = $set_backup_ip;
}

# validate_node, sub called by Node.pm to validate nodes, using plugins.
# Parameters:
# Node   - the Node object containing the new values to be validated
# Config - the system configuration object
# NMISNG - the NMISNG object to use
#returns 1 or 0 - node is valid or not and  list of errors
sub validate_node
{
    my (%args) = @_;
    my ($node, $C ,$NG) = @args{qw(node config nmisng)};
 
    my @errors = ();
    
    
    ## check if the ci already exists or not ?
    my $node_configuration = $node->configuration;
    my $current_ci =  $node_configuration->{ci};
    my $current_host = $node_configuration->{host};
    my $current_host_bkp = $node_configuration->{host_backup};
        ## check if its a host name or ip or not.
    my ($ip, $backup_ip) = resolve_host_to_IP( $host, $host_backup, $node_configuration->{ip_protocol} );
    
    # used for faking dns lookups for tsting
    if( $test_ip ) {
        $ip = $test_ip;
        $backup_ip = $test_backup_ip;
    }    
    if ( my $error = validate_ci(ci_field => $current_ci, node => $node, config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }
    elsif ( my $error = validate_host(current_host => $current_host, current_host_bkp => $current_host_bkp, ip => $ip, backup_ip => $backup_ip,
        node => $node, config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }
    elsif ( my $error = validate_IP_addr(host => $current_host, host_backup => $current_host_bkp, ip => $ip, backup_ip => $backup_ip,
        node => $node,config => $C, nmisng=>$NG))
    {
        push @errors, $error;
    }
    return (scalar(@errors), @errors);
}

sub resolve_host_to_IP
{
    my ($host, $host_backup,$ip_protocol) = @_;
    my ($ip, $bkp_ip);
    if ($host =~ /^\d+.\d+.\d+\.\d+$/ || $host_backup =~ /^\d+.\d+.\d+\.\d+$/ ){
        $ip = $host;
        $bkp_ip = $host_backup;
    }
    else{
        ## convert the host and backup host, to ip and backup ip address. 
        if ($ip_protocol eq 'IPv6')
        {
            $ip = NMISNG::Util::resolveDNStoAddrIPv6($host);
            $bkp_ip = NMISNG::Util::resolveDNStoAddrIPv6($host_backup);
        }
        else
        {
            $ip = NMISNG::Util::resolveDNStoAddr($host);
            $bkp_ip = NMISNG::Util::resolveDNStoAddr($host_backup);
        }
    }
    return ($ip,$bkp_ip);
}
# find any nodes with (ips) host_addr and host_addr_backup that match
# the host and host_backup (resolved to ip's if they are names)
# return error if ip/backup_ip exists in db , 
# return 0 if ip/backup_ip  does not exists in db.
sub validate_IP_addr
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host,$host_backup,$ip,$backup_ip) = @args{qw(node config nmisng host host_backup ip backup_ip)};
    
    $NG->log->debug2(sub {"Validating IP address :- Checking if Primary and backup monitoring addresses are already associated or not ?"});
    
    # we must check the 
    ## query part for and, manually add or
    my $query = NMISNG::DB::get_query(
        and_part => {  concept => "catchall",
            node_uuid => { '$ne' => $node->uuid } },
    );    
    my $host_list = [$host];
    push @$host_list, $host_backup if($host_backup);
    push @$host_list, $ip if($ip);    
    push @$host_list, $backup_ip if($backup_ip);
    $query->{'$or'} = [
        { 'data.host_addr' => { '$in' => $host_list }}, 
        { 'data.host_addr_backup' => { '$in' => $host_list }},
    ];

    ## required fields. 
    my $fields_hash = {        
                        'node_name'  => 1,
                        'node_uuid' => 1,
                        'concept'  => 1,
                        'data.host_addr' => 1,
                        'data.host_addr_backup' => 1
                    };

    ## db query to find data in inventory.
    my $cursor = NMISNG::DB::find(
                    collection  => $NG->inventory_collection,
                    query       => $query,
                    fields_hash => $fields_hash                                  
                    );
    
    if ( !defined $cursor ) {
        return ("validate_IP_addr Error running query: ".NMISNG::DB::get_error_string);
    } 
    # if entries exist they are clashing, 
    my @all = $cursor->all;    
    if (@all){
        foreach my $entry(@all) {
            my $linked_data;            
            return "Another node is already using host_addr:$ip host_addr_backup:$bkp_ip named: $entry->{node_name} ($entry->{data}{host_addr},$entry->{data}{host_addr_backup})";
        }
    }
    
    return 0;
}   

# search for any nodes already using the host/host_backup values the
# node wants to use, there should be no overlap, case insensitive
# return error if host exists in db as host or host_backup , 
# return 0 if host  does not exists in db.
sub validate_host
{
    my (%args) = @_;
    my ($node, $C ,$NG,$host,$host_backup,$ip,$backup_ip) = @args{qw(node config nmisng current_host current_host_bkp ip backup_ip)};
    
    $NG->log->debug2(sub {"Validating Host :- Checking if Hostname is already registered or not"});
    # the search needs to be case insensetive. host must be set, host_backup does not
    my $host_list = [qr/^$host$/i];
    push @$host_list, qr/^$host_backup$/i if($host_backup);
    push @$host_list, $ip if($ip);
    push @$host_list, $backup_ip if($backup_ip);
    my $q = { '$or' => [ 
                { 'configuration.host' => { '$in' => $host_list }}, 
                { 'configuration.host_backup' => { '$in' => $host_list }},
    ]};
    # print Dumper($q);
    my $cursor = NMISNG::DB::find(
			collection  => $NG->nodes_collection,
			query       => $q,
			fields_hash => { 'name' => 1, 'uuid' => 1, 'configuration.ci' => 1, 'configuration.host' => 1, 'configuration.host_backup' => 1 }			
    );
    
    if ( !defined $cursor ) {
        return ("validate_host Error running query: ".NMISNG::DB::get_error_string);
    } 
    my $nodes;
    @$nodes = $cursor->all();
    my $status = ( @$nodes == 0 ) ? 1 : 0;

    # look to see if any nodes exist with same ci value    
    if( $status == 0 ) {
        foreach $found_node (@$nodes) {
            # if there is a node and it has a different uuid then we have a conflict
            if( $found_node->{uuid} ne $node->uuid) {
                return ("Another node is already using host:$host, host_backup:$host_backup named:$found_node->{name} ($found_node->{configuration}{host},$found_node->{configuration}{host_backup})");
            }
        }
    }    
    return 0;
}

## db check for host.
## this sub check if host exists in db or not ?
sub db_check
{
    my (%args) = @_;
    my ($NG,$filter_value,$filter_key) = @args{nmisng,filter_value,filter_key};

     ## check if the host is present in db for any node 
    my $model_data = $NG->get_nodes_model( filter => { $filter_key => $filter_value },
                                                fields_hash => {  
                                                                  'name' => 1, 
                                                                  'uuid' => 1,
                                                                  'configuration.ci' => 1
                                                        } );
    if (my $error = $model_data->error)
    {
        $NG->log->error("Failed to get nodes model: $error");
        return ("Failed to get nodes model, Error validating CI field.",0);
    }
    
    my $data = $model_data->data();
    my @nodes = ();
    if (@{$data}) {
        foreach my $entry(@{$data}){
            push @nodes,$entry;
        }
        return(\@nodes,0);
    }
    else{
        ## all good it does not exist anywhere else.
        return (\@nodes,1);
    }
}


# return error if custom field exists in db , 
# return 0 if custom field does not exists in db.
sub validate_ci
{
    my (%args) = @_;
    my ($node, $C ,$NG,$CIF) = @args{qw(node config nmisng ci_field)};
    
     $NG->log->debug2(sub {"Validating CI field :- Checking if CI already exists or not ?"});
    if( $CIF eq '' )
    {
        return "ci_field cannot be empty";
    }
    # look to see if any nodes exist with same ci value
    my ($nodes,$status) = db_check(nmisng=> $NG,filter_value => qr/^$CIF$/i, filter_key => "configuration.ci" );
    if( $status == 0 ) {
        foreach $found_node (@$nodes) {
            # if there is a node and it has a different uuid then we have a conflict
            if( $found_node->{uuid} ne $node->uuid) {
                return ("Another node is already using ci:$CIF, named:$found_node->{name}");
            }
        }
    }
    return 0;
}
 
## dummy sub , which can be called by Node.pm for some other functionality .
sub create_valid
{
    my (%args) = @_;
    my ($node, $C ,$NG) = @args{qw(node config nmisng)};
    return (1, undef);
}
1;