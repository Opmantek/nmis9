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

# Default Inventory Class, convers everything that does not have a specific type
# works by using path_keys to define it's path. the keys must be in the data section
# The parent does these by default, this class is almost not needed.
package NMISNG::Inventory::DefaultInventory;
use parent 'NMISNG::Inventory';
use strict;

our $VERSION = "1.0.0";

# double check the arguments required were provided
# then get our parent to make us
# path_keys is required unless the object is not new (has _id), if it is not
#   specified then the path cannot be re-calculated
#   keys from data are used to make the path, this does not include things that are automatically added
#    this isn't necessarily needed if make_path is overridden
use Data::Dumper;

sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return if ( !$nmisng );    # check this so we can use it to log

	$nmisng->log->error("DefaultInventory cannot be created without path_keys") && return
		if ( !$args{path_keys} && !$args{_id} );

	my $self = $class->SUPER::new(%args);
	$nmisng->log->error(__PACKAGE__." failed to get parent new!") && return
			if (!ref($self));
	
	bless($self, $class);
	return $self;
}

# creates path from data and path key selection
# attention: must be a class function, NOT instance method! no self.
# args: cluster_id, node_uuid, concept, path_keys, data (all required), partial (optional)
# returns: path arrayref or error message
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if ( !( $#_ % 2 ) );
	
	my (%args) = @_;
	return NMISNG::Inventory::make_path_from_keys(cluster_id => $args{cluster_id},
																								node_uuid => $args{node_uuid},
																								concept => $args{concept},
																								data => $args{data},
																								path_keys => $args{path_keys},
																								
																								partial => $args{partial});
}


1;
