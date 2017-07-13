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

# Service Inventory Class
package NMISNG::Inventory::ServiceInventory;
use parent 'NMISNG::Inventory';
use strict;

our $VERSION = "1.0.0";

# double check the arguments required were provided
# then get our parent to make us
sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return if ( !$nmisng );    # check this so we can use it to log

	# validate data section
	# services must be named (in property service)
	# and must have a uuid.
	# anything else is optional
	my $data = $args{data};

	return if ( !$data->{service} );
	return if ( !$data->{uuid} );

	my $self = $class->SUPER::new(%args);
	$nmisng->log->error(__PACKAGE__." failed to get parent new!") && return
			if (!ref($self));

	bless($self, $class);
	return $self;
}

# make a path suitable for service-type inventory
# attention: MUST be a class function, NOT an instance method! no self!
# args: cluster_id, node_uuid, concept, data, (all required),
# path_keys (ignored if given, we set it here), partial (optional)
# returns; path ref or error message
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if ( !( $#_ % 2 ) );

	my (%args) = @_;

	my $path = NMISNG::Inventory::make_path_from_keys(
		cluster_id => $args{cluster_id},
		node_uuid => $args{node_uuid},
		concept => $args{concept},
		path_keys => ['service'],		# override
		data => $args{data},
		partial => $args{partial});

	return $path;
}
