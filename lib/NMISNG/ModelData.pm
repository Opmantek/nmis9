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

# Generic class to hold modeldata, which is an array of hashes
package NMISNG::ModelData;
use strict;

our $VERSION = "1.0.0";

use Data::Dumper;

sub new
{
	my ( $class, %args ) = @_;

	die "Data must be array if defined" if ( $args{data} && ref( $args{data} ) ne "ARRAY" );
	my $self = bless(
		{   _model_name => $args{model_name} // undef,
			_data      => $args{data}      // undef
		},
		$class
	);
	return $self;
}

sub data
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) )
	{
		$self->{_data} = $newvalue;
	}
	return $self->{_data};
}

# readonly - returns number of entries in modeldata
sub count
{
	my ($self) = @_;
	my $count  = 0;
	my $data   = $self->data();

	if ( ref($data) eq 'ARRAY' )
	{
		$count = scalar(@$data);
	}
	return $count;
}

1;
