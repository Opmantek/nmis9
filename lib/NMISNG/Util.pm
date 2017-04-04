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

# Utility package
package NMISNG::Util;
use strict;
our $VERSION = "1.0.0";

sub TODO
{
	# TODO: find a better way to enable/disabling this, !?!
	my $show_todos = 0;
	print "TODO: " . shift . "\n" if ($show_todos);
}

# like getargs, but arrayify multiple occurrences of a parameter
# args: list of key=values to parse,
# returns: hashref
sub get_args_multi
{
	my @argue = @_;
	my %hash;

	for my $item (@argue)
	{
		if ( $item !~ /^.+=/ )
		{
			print STDERR "Invalid command argument \"$item\"\n";
			next;
		}

		my ( $name, $value ) = split( /\s*=\s*/, $item, 2 );
		if ( ref( $hash{$name} ) eq "ARRAY" )
		{
			push @{$hash{$name}}, $value;
		}
		elsif ( exists $hash{$name} )
		{
			my @list = ( $hash{$name}, $value );
			$hash{$name} = \@list;
		}
		else
		{
			$hash{$name} = $value;
		}
	}
	return \%hash;
}

# this small helper forces anything that looks like a number
# into a number. json::xs needs that distinction, ditto mongodb.
# args: a single input, should be a string or a number.
#
# returns: original thing if not number or ref or other unwanted stuff,
# numberified thing otherwise.
sub numify
{
	my ($maybe) = @_;

	return $maybe if ref($maybe);

	# integer or full ieee floating point with optional exponent notation
	return ( $maybe =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ ) ? ( $maybe + 0 ) : $maybe;
}


1;
