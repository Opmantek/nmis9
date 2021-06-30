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
# Service Inventory Class
# differs from defaultinventory in that it requies (data) properties uuid and service
# doesn't have index.

package NMISNG::Inventory::ServiceInventory;
our $VERSION = "1.0.1";

use strict;
use parent 'NMISNG::Inventory';
use NMISNG::Util;

#  returns (positive, nothing) if the inventory is valid,
# (negative or zero, error message) if it's no good
sub validate
{
	my ($self) = @_;

	# validate data section
	# services must be named (in property service), and must have a uuid.
	# anything else is optional
	my $data = $self->data;
	return (-1, "ServiceInventory requires data section")
			if (!defined($data) or ref($data) ne "HASH"
					or !keys %$data);
	for my $musthave (qw(service uuid))
	{
		return (-1, "ServiceInventory requires data property $musthave")
				if (!$data->{$musthave} );
	}
	# all good so far
	return 	$self->SUPER::validate;
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

# service inventories contain an independent uuid for compatibility reasons,
# which is tedious to maintain so the data method takes care of that
# for us, on both GET and SET
#
# args: optional data (hashref),
# returns: clone of data, logs on error
sub data
{
	my ($self, $newvalue, $conf) = @_;

	# we want a recreatable V5 uuid from config'd namespace+cluster_id+service+node's uuid
	if (defined($newvalue))
	{
		$newvalue->{uuid} //= NMISNG::Util::getComponentUUIDConf( components => ($self->cluster_id,
																				$newvalue->{service},
																				$self->node_uuid),
																conf => $conf );
		return $self->SUPER::data($newvalue);
	}
	else
	{
		my $clone = $self->SUPER::data();
		# making that uuid won't work until service property is set
		$clone->{uuid} //= NMISNG::Util::getComponentUUIDConf( components => ($self->cluster_id,
																			 $clone->{service},
																			 $self->node_uuid),
																conf => $conf )
				if ($clone->{service});
		return $clone;
	}
}
