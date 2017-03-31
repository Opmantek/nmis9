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
#   keys from data used to make the path, this does not include things that are automatically added
#    this isn't necessarily needed if make_path is overridden
use Data::Dumper;

sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return if ( !$nmisng );    # check this so we can use it to log

	# validate data section
	my $data = $args{data};
	$nmisng->log->error("DefaultInventory cannot be created without data") && return if ( !$data );
	$nmisng->log->error("DefaultInventory cannot be created without path_keys") && return
		if ( !$args{path_keys} && !$args{_id} );

	my $self = $class->SUPER::new(%args);
	$nmisng->log->error("DefaultInventory failed to get parent new") && return if ( !$self );

	$self->path_keys( $args{path_keys} ) if ( $args{path_keys} );

	return $self;
}

sub make_path
{
	return NMISNG::Inventory::make_path(@_);
}

# making a path can be done even on !new objects, in that case we may not have
# path keys so allow passing them in, overriding what is there if you want
sub path
{
	my ( $self, %args ) = @_;

	$args{path_keys} = $self->path_keys if ( !defined( $args{_path_keys} ) );
	$self->SUPER::path(%args);
}

sub path_keys
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) )
	{
		$self->{_path_keys} = $newvalue;
	}
	return $self->{_path_keys};
}

# sub validate
# {
# 	my ($self) = @_;
# 	my ($valid,$reason) = $self->SUPER::validate();
# 	return ($valid,$reason) if(!$valid);

	
# }

1;
