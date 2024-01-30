#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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

package NMISMojo::NodeData;

# BEGIN {
# 	our ($VERSION,$ABI,$MAGIC) = ("1.492.0","4.0.0","DEADCHICKEN");
# 	if( scalar(@ARGV) == 1 && $ARGV[0] eq "--module-version" ) {
# 		print __PACKAGE__." version=$VERSION\n".__PACKAGE__." abi=$ABI\n".__PACKAGE__." magic=$MAGIC\n";
# 		exit(0);
# 	}
# };

use strict;
use Data::Dumper;
use UUID::Tiny qw(:std);
use NMISNG::Util;
use NMISNG::Log;
use NMISNG::Graphs;
use NMISNG::Sys;
# use NMISx;
# use Clone;
# use Carp;

# combined constructor and loader - doesn't (pre)load resources as they're in mongo
#
# args: type and controller, needs config from controller
# returns: (undef,object) if ok, (errormessage,undef) otherwise
sub load_resources
{
	my ($class,%args) = @_;
   
	my $controller = $args{controller};
	my $current_route = $controller->current_route();

	my $self = bless({
        type  => $args{type},
		controller => $controller,
	}, $class);
	
	return (undef,$self);
}

sub get_nmisng_obj
{
    my ($self, %args) = @_;
    my $config = NMISNG::Util::loadConfTable();
    my $logfile = $config->{'<nmis_logs>'} . "/node_data.log";
    my $logger  = NMISNG::Log->new(
        path => $logfile,
    );

    my $nmisng = NMISNG->new(
	    config => $config,
        log => $logger,
    );
    
    return $nmisng;
}

sub find_resources
{
	my ($self, %args) = @_;

    my @node_names;
    my $nmisng = $self->get_nmisng_obj();

    my $noderec = $nmisng->get_nodes_model();
    if (!$noderec)
	{
		$nmisng->log->error("No matching nodes exist.");
		return undef;		
	}
   
    map { push @node_names, $_->{name}} (@{$noderec->data});
    # my $nodeobj = $nmisng->node(name => "clone_localhost_1");
    # my $uuid = $nodeobj->uuid;
    # $nmisng->log->info("UUID:$uuid!");
    # print Dumper @node_names;
    return \@node_names;
	
}

sub all_resources
{
	return shift->find_resources(@_);
}

# finds a SINGLE resource by its id_attr
#
# in type 'node' visual mode, return inventory plus other stuff
# in type 'nodeip' configuration mode, return just nmisx node config and other props
#
# args: name (=crudcontroller-scope)
# returns: undef if not found, resource ref otherwise
sub find_resource
{
	my ($self,%args) = @_;

    my $lookup = $args{name};
    #print Dumper "Lookup = $lookup";

	return undef if ($self->{type} !~ /^(node|nodeip)$/);

	#my $redact = getBool($self->{controller}->check_access( access_requirement => 'access_redacted_values'),1);

    my $nmisng = $self->get_nmisng_obj();
    $nmisng->log->info("Getting the data for node $lookup");

    if ($self->{type} eq "node")	# opcharts visual mode
	{
		# node data for node api
        my $nodeobj = $nmisng->node(uuid =>  $lookup);
        #return undef if (!$nodeobj);

        # if (!$nodeobj){
        #     $nmisng->log->error("Invalid node/uuid arguments, no matching node exists!");
        #     return undef;
        # }		

        if ($nodeobj){
            my ($inventory, $error) =  $nodeobj->inventory( concept => "catchall" );
            my $catchall = $inventory->data();
            my $graphs = $catchall->{nodegraph};
            my $node;

            if ($graphs){
                my $smallGraphHeight = 50;
                my $smallGraphWidth  = 400;

                my $graphsObj = NMISNG::Graphs->new( nmisng => $nmisng );
                $node = $nodeobj->name;
                my $Sys = NMISNG::Sys->new(nmisng => $nmisng);
                $Sys->init( name => $node, snmp => 'false' );
                my $GTT  = $Sys->loadGraphTypeTable();             # translate graphtype to type

                my $cnt    = 0;
		        my $gotAltCpu = 0;

                foreach my $graph (@$graphs)
                {
                    my @pr;
                    next unless $GTT->{$graph} ne '';
                    next if $graph eq 'response' and NMISNG::Util::getbool( $catchall->{ping}, "invert" );
                    $cnt++;
                    # process multi graphs
                    if ($graph eq 'hrsmpcpu' and not $gotAltCpu)
                    {
                        foreach my $index ( $Sys->getTypeInstances(graphtype =>"hrsmpcpu")) {
                            my $inventory = $Sys->inventory( concept => 'device', index => $index);
                            if ($inventory)
                            {
                                my $data = ($inventory) ? $inventory->data() : {};
                                push @pr, ["Server CPU $index ($data->{hrDeviceDescr})", "hrsmpcpu", "$index"];
                            }
                        }
                    }
                    else
                    {
                        push @pr, [ $Sys->graphHeading(graphtype => $graph), $graph] if $graph ne "hrsmpcpu";
                        if ( $graph =~ /(ss-cpu|WindowsProcessor)/ )
                        {
                            $gotAltCpu = 1;
                        }
                    }
                    
                    # now print it
                    for my $graphdata (@pr )
                    {
                        my $graphLink = $graphsObj->htmlGraph(
							graphtype => $graphdata->[1],
							node      => $node,
							intf      => $graphdata->[2],
							width     => $smallGraphWidth,
							height    => $smallGraphHeight
						);
                        if ($graphLink !~ /Error/ ) {
                            $catchall->{graphLink}->{$graphdata->[1]} = $graphLink;
                        }
                        else {
                            $nmisng->log->error("Error: Failed to the graph url for graphtype $graph for $node");
                        }
                    }
                }
            }else
            {
                $nmisng->log->error("Error: No graph(s) found for $node");
            }
            #print OFILEDUMP Dumper $catchall;
            return $catchall; 
        }          
        else {
            $nmisng->log->error("Error: Invalid node/uuid arguments, no matching node exists!");
		    return undef;
        }
	}

}

1;
