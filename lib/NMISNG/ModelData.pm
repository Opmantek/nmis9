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

our $VERSION = "9.5.1";

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
		_cursor => $args{cursor},
		_cursor_count => 0,
		_cursor_data_fetched => 0,
		_error => $args{error},
		_error_checked => 0,
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
	$self->{_error_checked} = 1;
	return $self->{_error};
}

# a setter-getter for the data array
# returns the live data
# if modeldata is using cursor it will fetch all data 
# from cursor once and store it, this is not optimal use for 
# 
#
# args: new data array ref
# returns: data array ref (post update!) or dies on error
sub data
{
	my ( $self, $newvalue ) = @_;
	
	if ( ref($newvalue) eq "ARRAY" )
	{
		# can't set data while iterating, if all data has been fetched then setting it is ok
		die "ModelData::data setting data when cursor is provided is not allowed, trace".NMISNG::Log::trace() if($self->{_cursor} && $self->{_cursor_data_fetched} == 0);
		$self->{_data} = $newvalue;
	}
	elsif (defined $newvalue)
	{
		die "Data must be array!\n, trace".NMISNG::Log::trace();
	}
	if( !$self->{_error_checked} ) {
		$self->{_nmisng}->log->debug(sub {"ModelData::data is being accessed without checking for errors! trace:".NMISNG::Log::trace()}) 
			if(ref($self->{_nmisng}) eq "NMISNG");
		$self->{_error_checked} = 1; # stop this message from happening again for this object
	}
	# if we have a cursor and data is called, error out if the cursor has started iterating
	if( $self->{_cursor} && $self->{_cursor_count} > 0 ) {		
		# NOTE: this involves resetting and screwing up the cursor / iteration so just say no
		die 'ModelDaata::data cannot get all data after next iterator is used, _cursor_count: '.$self->{_cursor_count}.' trace:'.NMISNG::Log::trace();
	} 
	# if we have a cursor, data is called get iterating has not started, get all data
	elsif( $self->{_cursor} && $self->{_cursor_data_fetched} == 0 ) {
		my @all = $self->{_cursor}->all();
		$self->{_data} = \@all;
		$self->{_cursor_data_fetched} = 1;
		# print "called data with cursor!!!\n\n".$self->{_nmisng}->log->trace() if( $self->{_count_calling} != 1);
	}
	return $self->{_data};
}

# readonly - returns number of entries in data or zero if no data
#   if using a cursor it tries to be smart and re-use the query/filter
#   if iterating try not to use this, still not cheap
# returns count of dataset, 0 if nothing is found
sub count
{
	my ($self) = @_;
	my $count = 0;
	 
	my $cursor = $self->{_cursor};
	# not using this for now because there's places that end up calling count 
	# a bunch of times and re-running the query isn't actually more efficient
	if( $cursor && 0) {
		# this digs a little deeper into the cursor than we should be 
		my $client = $cursor->client();		
		my $query = $cursor->_query();
		my $filter = $query->filter();
		my $db_name = $query->{db_name};
		my $coll_name = $query->{coll_name};
		my $db = $client->get_database($db_name);
		my $collection = $db->get_collection($coll_name);		
		# print "filter,options".Dumper($filter,$options);
		my $options = {};
		$count = $collection->count_documents($filter,$options);
	} else {
		my $data = $self->data();
		$count = (ref($data) eq 'ARRAY')? scalar(@$data) : 0;
	}
	return $count;
}

# returns 1 if iterator has next entry, 0 if not
sub has_next 
{
	my ($self) = @_;
	my $cursor_count = $self->{_cursor_count};
	
	return ( $self->{_cursor}->has_next ) ? 1 : 0 if( $self->{_cursor} && !$self->{_cursor_data_fetched} );	
	return ( ($cursor_count + 1) < @{$self->{_data}} ) ? 1 : 0;
}

# iterator, return next value, retuns undef if there is nothing
# if using mongo cursor batching is automatic
# if not using cursor just gets next thing in data array
# no support for resetting count/location
sub next_value 
{
	my ($self) = @_;
	my $cursor_count = $self->{_cursor_count};
	$self->{_cursor_count}++;
	return $self->{_cursor}->next if( $self->{_cursor} && !$self->{_cursor_data_fetched} );	
	return $self->{_data}->[$cursor_count];
}

# returns object of next record
# returns undef if we're past the end
# if using mongo cursor batching is automatic
sub next_object
{
	my ($self) = @_;
	my $cursor_count = $self->{_cursor_count};
	$self->{_cursor_count}++;	
	my $raw_record;
	
	if( $self->{_cursor} )
	{
		$raw_record = $self->{_cursor}->next;
		return if( !$raw_record );
	}
	else
	{
		return if( !exists $self->{_data}->[$cursor_count] );
	}
	# raw record will be undef if not using a cursor so object will access ->data
	return $self->object($cursor_count,$raw_record);
}

# returns a list of instantiated objects for the current data
# args: none
# returns: hashref, contains success, error, objects (list ref, may be empty)
sub objects
{
	my ($self) = @_;

	# parrot error if the caller didn't care, e.g. ->get_xyz_model(...)->objects
	my $error = $self->error();
	return { error => $error } if ($error);
	
	# otherwise, nothing to do is NOT an error
	my $data = $self->data();
	return { success => 1, objects => [] }
	if (ref($data) ne "ARRAY" or !@$data);
	# but not knowing what objects to make is
	return { error => "Missing class_name or nmisng, cannot instantiate objects!" }
	if ((!$self->{_class_name} and !$self->{_attribute_name})
			or ref($self->{_nmisng}) ne "NMISNG");

	# how do we find out the class name? either static or via resolver function
	Module::Load::load($self->{_class_name}) 	if ($self->{_class_name});

	my @objects;
	for my $raw (@$data)
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
# 		raw_record - for internal use, will generate object using this data if supplied
# returns: (undef, object ref) or (error message)
sub object
{
	my ($self, $nth, $raw_record) = @_;

	return "Missing nth argument!" if (!defined $nth);
	return "Missing class_name or nmisng, cannot instantiate objects!"
			if ((!$self->{_class_name} and !$self->{_resolver})
					or ref($self->{_nmisng}) ne "NMISNG");	
	
	my $error = $self->error();
	return $error if ($error);
	
	my $raw;
	if( $raw_record ) {
		$raw = $raw_record;
	}
	else
	{
		my $data = $self->data();
		return "nth argument  outside of limits! ($nth)"
			if (ref($data) ne "ARRAY"
					or !exists $data->[$nth]);
		$raw = $data->[$nth];
	}
	 
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
