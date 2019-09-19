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

# Generic class to hold modeldata (which is an array of hashes),
# but with optional object instantiation and access
package NMISNG::ModelData;
use strict;

our $VERSION = "9.0.6d";

use Scalar::Util;       # for weaken
use Data::Dumper;
use Module::Load;       # for getting subclasses in instantiate

# args: data, error, class_name, nmisng (all optional)
#  data must be array ref if given
#  only one of error and data should be given (but not enforced)
#   note: error can only be set here!
#  class_name and nmisng are required if you want to use object(s) accessors
#   class_name can be either a string (for homogenous modeldata) or
#   a hashref of (attribute name => function ref)
#   which will be called with the given attribute value as sole argument
sub new
{
	my ($class, %args) = @_;

	die "Data must be array\n"
			if (exists($args{data}) && ref($args{data}) ne "ARRAY" );

	my $self = bless({
		_class_name => undef,
		_resolver => undef,
		_attribute_name => undef,
		_nmisng => $args{nmisng},
		_data => $args{data} // [],
		_error => $args{error},
		_query_count => $args{query_count},
		_sort => $args{sort},
		_limit => $args{limit},
		_skip => $args{skip}
	}, $class );

	my $maybestatic = $args{class_name};
	if (ref($maybestatic) eq "HASH")
	{
		($self->{_attribute_name},$self->{_resolver}) = each(%$maybestatic);
		die "Invalid class_name argument, resolver not a function\n"
				if (ref($self->{_resolver}) ne "CODE");
	}
	elsif (!ref($maybestatic))
	{
		$self->{_class_name} = $maybestatic;
	}
	else
	{
		die "Invalid class_name argument, neither static nor attribute/resolver!\n";
	}

	# keeping a copy of nmisng which could go away means it needs weakening
	Scalar::Util::weaken $self->{_nmisng} if (ref($self->{_nmisng})
																						&& !Scalar::Util::isweak($self->{_nmisng}));
	return $self;
}

# r/o accessor for error indicator
# args: none
# returns: the current value of the error indicator
sub error
{
	my ($self) = @_;
	return $self->{_error};
}

# a setter-getter for the data array
# returns the live data
#
# args: new data array ref
# returns: data array ref (post update!) or dies on error
sub data
{
	my ( $self, $newvalue ) = @_;
	if ( ref($newvalue) eq "ARRAY" )
	{
		$self->{_data} = $newvalue;
	}
	elsif (defined $newvalue)
	{
		die "Data must be array!\n";
	}
	return $self->{_data};
}

# readonly - returns number of entries in data or zero if no data
sub count
{
	my ($self) = @_;

	return (ref($self->{_data}) eq 'ARRAY')? scalar(@{$self->{_data}}) : 0;
}

# returns a list of instantiated objects for the current data
# args: none
# returns: hashref, contains success, error, objects (list ref, may be empty)
sub objects
{
	my ($self) = @_;

	# parrot error if the caller didn't care, e.g. ->get_xyz_model(...)->objects
	return { error => $self->{_error} } if ($self->{_error});
	
	# otherwise, nothing to do is NOT an error
	return { success => 1, objects => [] }
	if (ref($self->{_data}) ne "ARRAY" or !@{$self->{_data}});
	# but not knowing what objects to make is
	return { error => "Missing class_name or nmisng, cannot instantiate objects!" }
	if ((!$self->{_class_name} and !$self->{_attribute_name})
			or ref($self->{_nmisng}) ne "NMISNG");

	# how do we find out the class name? either static or via resolver function
	Module::Load::load($self->{_class_name}) 	if ($self->{_class_name});

	my @objects;
	for my $raw (@{$self->{_data}})
	{
		my $classname = $self->{_class_name};
		# the dynamic case with resolver function
		if (!$classname)
		{
			my $function = $self->{_resolver};
			$classname = &$function($raw->{$self->{_attribute_name}});
			if (!$classname)
			{
				$self->{_nmisng}->log->error("modeldata instantiate failed: no classname, data ".
																		 Data::Dumper->new([$raw])->Terse(1)->Indent(0)->Pair(": ")->Dump);
				return  { error => "modeldata instantiate failed: no classname!" };
			}
			Module::Load::load($classname);
		}

		my $thing = $classname->new(nmisng => $self->{_nmisng}, %$raw);
		if ( !$thing )
		{
			$self->{_nmisng}->log->error("modeldata instantiate failed, type $self->{_class_name}, data ".
																	 Data::Dumper->new([$raw])->Terse(1)->Indent(0)->Pair(": ")->Dump);
			return { error => "failed to instantiate object of type $self->{_class_name}!"  };
		}
		push @objects, $thing;
	}

	return { success => 1, objects => \@objects };
}

# returns the Nth data entry instantiated as an object
# args: n
# returns: (undef, object ref) or (error message)
sub object
{
	my ($self, $nth) = @_;

	return "Missing nth argument!" if (!defined $nth);
	return "Missing class_name or nmisng, cannot instantiate objects!"
			if ((!$self->{_class_name} and !$self->{_resolver})
					or ref($self->{_nmisng}) ne "NMISNG");

	return "nth argument outside of limits!"
			if (ref($self->{_data}) ne "ARRAY"
					or !exists $self->{_data}->[$nth]);

	my $raw = $self->{_data}->[$nth];

	# how do we find out the class name? either static or via resolver function
	my $classname = $self->{_class_name};
	if (!$classname)
	{
		my $function = $self->{_resolver};
		$classname = &$function($raw->{$self->{_attribute_name}});
		if (!$classname)
		{
			$self->{_nmisng}->log->error("modeldata instantiate failed: no classname, data ".
																	 Data::Dumper->new([$raw])->Terse(1)->Indent(0)->Pair(": ")->Dump);
			return "modeldata instantiate failed: no classname!";
		}
	}
	Module::Load::load($classname);
	my $thing = $classname->new(nmisng => $self->{_nmisng}, %{$raw});
	if (!$thing)
	{
		$self->{_nmisng}->log->error("modeldata instantiate failed, type $self->{_class_name}, data ".
																	 Data::Dumper->new([$raw])->Terse(1)->Indent(0)->Pair(": ")->Dump);
		return "Failed to instantiate object of type $self->{_class_name}!";
	}

	return (undef, $thing);
}

# readonly - returns the number of entries the database reported,
# if if reported any. returns undef otherwise. does NOT count the actual data.
sub query_count
{
	my ($self) = @_;
	return $self->{_query_count};
}

1;
