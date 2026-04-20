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

	# Match real WMI.pm: return error string on missing required args
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

	my %result;
	my $used_index = $index_field;
	my $row_num = 0;

	for my $row (@$rows)
	{
		my $idx;
		if ($index_field && exists $row->{$index_field})
		{
			$idx = $row->{$index_field};
		}
		else
		{
			# Fall back to row number
			$idx = $row_num;
			$used_index = undef;
		}

		# Filter fields if requested
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
		$row_num++;
	}

	return (undef, \%result, { classname => "MockClass", index => $used_index });
}

1;
