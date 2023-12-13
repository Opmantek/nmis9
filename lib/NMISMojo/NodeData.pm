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

	#this should come from args but o well
   
	#my $redact = getBool($self->{controller}->check_access( access_requirement => 'access_redacted_values'),1);

    my $nmisng = $self->get_nmisng_obj();
    
    if ($self->{type} eq "node")	# opcharts visual mode
	{
		
        # node data for node api
        # my $node = $nmisng->get_nodes_model();
        # print Dumper "Node\n";
        # print Dumper %{$node};
        my $nodeobj = $nmisng->node(uuid =>  $lookup);
        if ($nodeobj){
            my ($inventory, $error) =  $nodeobj->inventory( concept => "catchall" );
            my $catchall = $inventory->data();
            return $catchall;
        }
        else {
            $nmisng->log->error("Error: $lookup not found!");
		    return undef;
        }
	}
}



1;
