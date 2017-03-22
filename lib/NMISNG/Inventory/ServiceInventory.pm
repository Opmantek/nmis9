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

	# validate data section
	my $data = $args{data};
	return if ( !$data->{description} );
	return if ( !$data->{name} );
	return if ( !$data->{server} );
	return if ( !$data->{service} );
	return if ( !$data->{uuid} );

	my $self = $class->SUPER::new(%args);
	return $self;
}

# overload make path and generate it based on
# this path is not good, needs to make sense, a bunch of overlapping
#  concepts in it currently, maybe that's ok?
sub make_path
{
	my (%args) = @_;
	my $data = $args{data};
	my $path;
	
	if ( $data->{service} && $data->{uuid} && $data->{server} )
	{
		$path = [$data->{service}, $data->{uuid}, $data->{server}];
	}
	elsif ( $args{partial} && ( $data->{service} || $data->{uuid} || $data->{server} ) )
	{
		# i don't htink this is right
		$path = [$data->{service}, $data->{uuid}, $data->{server}];
	}
	return $path;
}
