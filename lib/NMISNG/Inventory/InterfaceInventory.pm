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

# Interface Inventory. Currently just here to make the IP data look a bit nicer
# and to add accesors for things that should be defined
package NMISNG::Inventory::InterfaceInventory;
use parent 'NMISNG::Inventory::DefaultInventory';
use strict;

our $VERSION = "1.0.0";

# make a path suitable for interfaces, ifDescr has been added as it's handy to also key off if it
#  this means than many lookups for this path will need partial => 1 as the caller probably won't have 
#  both index and ifDescr
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
		path_keys => ['index','ifDescr'],		# override
		data => $args{data},
		partial => $args{partial});
	return $path;
}

# pull out ip info and put it into an array for easier searching
sub new
{
	my ( $class, %args ) = @_;
	
	# see make_path
	$args{path_keys} = ['index','ifDescr'];

	# modify data section, put IP into a format we can search/use (array of hashes with consistent keys)
	# for now leave the original attributes as well
	my $data = $args{data};
	my $cnt = 1;
	$data->{ip} = [];
	while ( defined( $data->{"ipAdEntAddr$cnt"} ) )
	{
		my $dest = {};
		for my $attr (qw(ipAdEntAddr ipAdEntNetMask ipSubnet ipSubnetBits))
		{
			$dest->{$attr} = $data->{$attr.$cnt};
		}
		push @{$data->{ip}}, $dest;
		$cnt++;
	}

	my $self = $class->SUPER::new(%args);
}

# quick get/setters for plain attributes
# having setters for these isn't really necessary
for my $name (qw(ifAdminStatus ifAlias ifDescr ifIndex ifOperStatus ifType Description))
{
		no strict 'refs';
		*$name = sub
		{
				my $self = shift;
				return (@_? $self->_generic_getset(name => $name, value => shift)
								: $self->_generic_getset(name => $name));
		}
}

sub ifSpeed
{
	my ($self) = @_;
	my $data = $self->data();
	return ($data->{ifSpeedIn} ne 'auto') ? $data->{ifSpeed} : 10000000;
}

sub ifSpeedIn
{
	my ($self) = @_;
	my $data = $self->data();
	return $data->{ifSpeedIn}  ? $data->{ifSpeedIn}  : $data->{ifSpeed};
}

sub ifSpeedOut
{
	my ($self) = @_;
	my $data = $self->data();
	return $data->{ifSpeedOut}  ? $data->{ifSpeedOut}  : $data->{ifSpeed};
}

sub speed
{
	my ($self) = @_;
	my $data = $self->data();
	my $speed = NMISNG::Util::convertIfSpeed( $data->{ifSpeed} );
	if( $data->{ifSpeedIn} and $data->{ifSpeedOut} )
	{
		$speed = "IN\\: ". NMISNG::Util::convertIfSpeed($data->{ifSpeedIn})
				." OUT\\: ". NMISNG::Util::convertIfSpeed($data->{ifSpeedOut});
	}
	return $speed;
}

sub max_octets
{
	my ($self) = @_;
	my $ifSpeed = $self->ifSpeed // 'U';
	return ( $ifSpeed ne 'U' ) ? int( $ifSpeed / 8 ) : 'U';
}

sub max_bytes
{
	my ($self) = @_;
	my $ifSpeed = $self->ifSpeed // 'U';
	return ( $ifSpeed ne 'U' ) ? int( $ifSpeed / 4 ) : 'U';
}

# apparently this is crap
sub max_packets
{
	my ($self) = @_;
	my $ifSpeed = $self->ifSpeed // 'U';
	return ( $ifSpeed ne 'U' ) ? int( $ifSpeed / 50 ) : 'U';
}

1;
