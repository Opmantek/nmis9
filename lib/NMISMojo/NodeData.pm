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
    my $logfile = $config->{'<nmis_logs>'} . "/nmis_mojo_api.log";
    my $logger  = NMISNG::Log->new(
        path => $logfile,
    );

    my @node_names; 
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

	return undef if ($self->{type} !~ /^(node|nodeip)$/);

	#this should come from args but o well
   
	#my $redact = getBool($self->{controller}->check_access( access_requirement => 'access_redacted_values'),1);

    my $nmisng = $self->get_nmisng_obj();
    
    if ($self->{type} eq "node")	# opcharts visual mode
	{
		my ($data,$count,$error) = $nmisng->get_inventory_detail_model( $self->id_attr() => $lookup, want_config => 1);
		my $this = ($data && @$data == 1 ) ? $data->[0] : undef;
        return (!$this or !$this->{_id})? undef: $this;
	}
	else		# configuration mode
	{
		if (my $nodeobj = $nmisng->node(name => $lookup)) # function takes node uuid preferrably, and node name as fallback
	    {
			# do necessary processing
            #$nmisng->log->info("UUID: $lookup found!");
            # we want the true structure, unflattened
            my $dumpables = { };
            for my $alsodump (qw(configuration overrides name cluster_id uuid activated comments unknown aliases addresses enterprise_service_tags))
            {
                $dumpables->{$alsodump} = $nodeobj->$alsodump;
            }

            my ($error, %flatearth) = NMISNG::Util::flatten_dotfields($dumpables,"entry");
            if ($error) {
                $nmisng->log->error("Error: failed to transform output: $error") if ($error);
                return undef;
            }
            
            #my $nodedata = $nodeobj->export(flat => 0);
            # print "flatearth\n";
            # print Dumper \%flatearth;
            # $self->_massage_add_compat($nodedata); # and add in helpful compat bits
    
            return \%flatearth;
		}
		else
		{
			return "Error: $lookup not found!";
		}
	}
}

# return the attribute name that is used for the id of this type
# defaults to "name" if not found  - fixed to 'uuid' for this type of object
# fixme az: unclear what that is supposed to be good for?
sub id_attr
{
	my ($self) = @_;
	return 'uuid';
}

sub name_of
{
	my ($self,%args) = @_;

	my $thisres = $args{thisresource};

	return undef if (!$thisres or !defined $thisres->{ $self->id_attr });
	return $thisres->{ $self->id_attr };
}

1;
