package NMISNG::WMI::Mock;
# Mock WMI class for testing - implements the NMISNG::WMI interface
# but returns data from an in-memory hash instead of real WMI queries.

use strict;
use warnings;

# Constructor
# args: wmi_data => { "WQL query" => [ { field => value, ... }, ... ], ... }
sub new
{
	my ($class, %arg) = @_;

	# wmi_data is mock-specific and must be present for the mock to function.
	# host/username/password are accepted for interface parity with NMISNG::WMI->new
	# but are not validated here (tests don't exercise the underlying WMI transport).
	return "NMISNG::WMI::Mock requires wmi_data argument" if (!$arg{wmi_data});

	my $self = bless({
		wmi_data => $arg{wmi_data} || {},
		host     => $arg{host} || 'mock',
		error    => undef,
	}, $class);

	return $self;
}

# Get single row result
# args: wql => query, fields => [field list] (optional)
# returns: (undef, {field => value}, {classname => "Mock"}) on success
#      or: ("error message") on failure
sub get
{
	my ($self, %args) = @_;
	my $query = $args{wql};
	my $fields = $args{fields};

	if (!$query)
	{
		return "No WQL query provided";
	}

	# Look up exact query match first, then try case-insensitive
	my $rows = $self->{wmi_data}{$query};
	if (!$rows)
	{
		for my $key (keys %{$self->{wmi_data}})
		{
			if (lc($key) eq lc($query))
			{
				$rows = $self->{wmi_data}{$key};
				last;
			}
		}
	}

	if (!$rows || !@$rows)
	{
		return "No mock data found for query: $query";
	}

	my $row = $rows->[0];

	# Filter fields if requested
	if ($fields && @$fields)
	{
		my %filtered;
		for my $f (@$fields)
		{
			$filtered{$f} = $row->{$f} if exists $row->{$f};
		}
		$row = \%filtered;
	}

	return (undef, $row, { classname => "MockClass" });
}

# Get table (multiple rows) indexed by a field
# args: wql => query, index => field_name, fields => [field list] (optional)
# returns: (undef, { index_value => {field => value} }, {classname => "Mock", index => field}) on success
#      or: ("error message") on failure
sub gettable
{
	my ($self, %args) = @_;
	my $query      = $args{wql};
	my $index_field = $args{index};
	my $fields     = $args{fields};

	if (!$query)
	{
		return "No WQL query provided";
	}

	# Look up query
	my $rows = $self->{wmi_data}{$query};
	if (!$rows)
	{
		for my $key (keys %{$self->{wmi_data}})
		{
			if (lc($key) eq lc($query))
			{
				$rows = $self->{wmi_data}{$key};
				last;
			}
		}
	}

	if (!$rows || !@$rows)
	{
		return "No mock data found for query: $query";
	}

	# Match real NMISNG::WMI->gettable semantics: before iterating, verify the
	# requested index field exists AND is unique across all rows. If any row
	# is missing the field or any value is duplicated, undef the indexfield
	# entirely and key every row by its row number (with meta->{index} = undef).
	my $used_index = $index_field;
	if ($used_index)
	{
		my %seen;
		for my $row (@$rows)
		{
			if (!defined($row->{$used_index}) || $seen{$row->{$used_index}}++)
			{
				$used_index = undef;
				last;
			}
		}
	}

	my %result;
	for my $i (0 .. $#{$rows})
	{
		my $row = $rows->[$i];
		my $idx = $used_index ? $row->{$used_index} : $i;

		my $data = $row;
		if ($fields && @$fields)
		{
			my %filtered;
			for my $f (@$fields)
			{
				$filtered{$f} = $row->{$f} if exists $row->{$f};
			}
			$data = \%filtered;
		}

		$result{$idx} = $data;
	}

	return (undef, \%result, { classname => "MockClass", index => $used_index });
}

1;
