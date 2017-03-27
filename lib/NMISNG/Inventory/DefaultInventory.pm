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
package NMISNG::Inventory::DefaultInventory;
use parent 'NMISNG::Inventory';
use strict;

our $VERSION = "1.0.0";

# double check the arguments required were provided
# then get our parent to make us
sub new
{
	my ( $class, %args ) = @_;

	# validate data section
	my $data = $args{data};
	return if ( !$data );
	return if ( !$args{path_keys} );

	# TODY: more error checks for error

	my $self = $class->SUPER::new(%args);
	return $self;
}

# overload make path and generate it based on
# this path is not good, needs to make sense, a bunch of overlapping
#  concepts in it currently, maybe that's ok?
# partial tells us that a partial path is ok helpful for searching, maybe
sub make_path
{
	my (%args)  = @_;
	my $data    = $args{data};
	my $keys    = $args{path_keys};
	my $partial = $args{partial};
	my $path;

	return if ( ref($keys) ne 'ARRAY' );
	foreach my $key (@$keys)
	{
		return if ( !$partial && !defined( $data->{$key} ) );
		push @$path, $data->{$key};
	}

	return $path;
}

# override parents implementation because our make path requires more info
sub path
{
	my ($self) = @_;
	my $class = ref($self);
	my $path = $class->make_path( data => $self->data(), partial => 0, path_keys => $self->path_keys);
	$self->nmisng->log->error("Path must be an array") if ( ref($path) ne "ARRAY" );
	return $path;
}

sub path_keys
{
	my ($self) = @_;
	return $self->{path_keys};
}