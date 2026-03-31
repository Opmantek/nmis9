package NMISNG::Sys::Engine::WMI;
# WMI polling engine - handles WQL query building and cached execution.
# Extracted from NMISNG::Sys::getValues() lines 1340-1393 (build) and 1418-1476 (execute).

use strict;
use warnings;
use parent 'NMISNG::Sys::Engine';

our $VERSION = "9.6.5";

sub protocol_name { return "wmi"; }

sub is_active
{
	my ($self) = @_;
	return defined($self->sys->{wmi}) ? 1 : 0;
}

# Build WMI query entries in the shared %todos hash.
# Handles -common- query resolution, field extraction, and multi-section dedup.
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_hash, $index, $port, $inventory, $todos)
		= @args{qw(section_name section_hash index port inventory todos)};

	my $sys = $self->sys;
	my %status;

	# The section-level 'indexed' value is needed for gettable vs get decision during execute
	my $section_indexed = $args{section_indexed};

	for my $itemname (keys %{$section_hash})
	{
		next if ($itemname eq "-common-");

		my $thisitem = $section_hash->{$itemname};

		$sys->nmisng->log->debug3(sub { "wmi query for section $section_name, item $itemname primed for loading" });

		# Query can come from the item itself or from a -common- section
		my $query = (
			exists($thisitem->{query}) ? $thisitem->{query}
			: (ref($section_hash->{"-common-"}) eq "HASH"
				&& exists($section_hash->{"-common-"}->{query}))
			? $section_hash->{"-common-"}->{query}
			: undef
		);

		next if (!$query or !$thisitem->{field});

		# Dedup: same item may appear in multiple sections
		if ($todos->{$itemname})
		{
			if (   $todos->{$itemname}->{query} ne $query
				or $todos->{$itemname}->{details}->[0]->{field} ne $thisitem->{field}
				or ($todos->{$itemname}->{indexed} // '') ne ($section_indexed // ''))
			{
				$status{error} = "($sys->{name}) model error, $itemname has multiple clashing queries/fields!";
				$sys->nmisng->log->error($status{error});
				next;
			}

			push @{$todos->{$itemname}->{section}}, $section_name;
			push @{$todos->{$itemname}->{details}}, $thisitem;

			$sys->nmisng->log->debug3(sub { "item $itemname present in multiple sections: " . join(", ", @{$todos->{$itemname}->{section}}) });
		}
		else
		{
			$todos->{$itemname} = {
				query   => $query,
				section => [$section_name],
				item    => $itemname,
				details => [$thisitem],
				indexed => $section_indexed,
			};
		}
	}

	return \%status;
}

# Execute all pending WMI queries with caching to avoid duplicate WQL calls.
sub execute_queries
{
	my ($self, %args) = @_;
	my ($todos, $index) = @args{qw(todos index)};

	my $sys = $self->sys;
	my $transport = $sys->{wmi};
	return {} unless $transport;

	my %status;
	my %seen;    # query cache

	my @havequery = grep { exists($todos->{$_}->{query}) } keys %$todos;
	return {} unless @havequery;

	for my $itemname (@havequery)
	{
		my $query = $todos->{$itemname}->{query};

		if (!$seen{$query})
		{
			my ($error, $fields, $meta);

			# Indexed queries use gettable, non-indexed use get
			if (defined($index) && defined($todos->{$itemname}->{indexed}))
			{
				($error, $fields, $meta) = $transport->gettable(
					wql   => $query,
					index => $todos->{$itemname}->{indexed}
				);
			}
			else
			{
				($error, $fields, $meta) = $transport->get(wql => $query);
			}

			if ($error)
			{
				$sys->nmisng->log->error("($sys->{name}) on get values by wmi: $error");
				$status{error} = $error;
				next;
			}
			else
			{
				$seen{$query} = $fields;
			}
		}

		if (!$seen{$query})
		{
			$sys->nmisng->log->error("($sys->{name}) on get values by wmi: no data returned for query $query");
			$status{error} = "no data returned for query $query";
			next;
		}

		# Extract the specific field value for this item
		my $row = defined($index) ? $seen{$query}->{$index} : $seen{$query};
		if (ref($row) eq "HASH")
		{
			$todos->{$itemname}->{rawvalue} = $row->{$todos->{$itemname}->{details}->[0]->{field}};
			$todos->{$itemname}->{done} = 1;
		}
		else
		{
			$sys->nmisng->log->warn("($sys->{name}) WMI query $query returned no data for index " . ($index // 'undef'));
		}
	}

	return \%status;
}

# Discover WMI indexes for a systemHealth section via WQL gettable query.
# Returns ($error, \@active_indices, \%targets)
sub discover_indexes
{
	my ($self, %args) = @_;
	my ($section_config, $index_var)
		= @args{qw(section_config index_var)};

	my $sys = $self->sys;
	my $transport = $sys->{wmi};
	return ("WMI not configured", undef, undef) unless $transport;

	my $wmisection = $section_config->{wmi};

	# model broken if it says 'indexed by X' but doesn't have a query section for 'X'
	if (!exists($wmisection->{$index_var}))
	{
		return ("missing declaration for index_var $index_var", undef, undef);
	}

	my $indexsection = $wmisection->{$index_var};

	# query can come from -common- or from the index var's own section
	my $query = (
		exists($indexsection->{query}) ? $indexsection->{query}
		: (ref($wmisection->{"-common-"}) eq "HASH"
			&& exists($wmisection->{"-common-"}->{query})) ? $wmisection->{"-common-"}->{query}
		: undef
	);

	if (!$query or !$indexsection->{field})
	{
		return ("missing query or field for WMI variable $index_var", undef, undef);
	}

	my ($error, $fields, $meta) = $transport->gettable(
		wql    => $query,
		index  => $index_var,
		fields => [$index_var]
	);

	if ($error)
	{
		return ($error, undef, undef);
	}

	# Validate that gettable successfully indexed by the requested field;
	# if meta->{index} is undef, the field was missing or not unique and
	# keys %$fields are row numbers, not real index values.
	if (!defined($meta->{index}))
	{
		return ("WMI indexing by $index_var failed (field missing or not unique)", undef, undef);
	}

	my @active_indices = keys %$fields;
	my %targets;
	for my $indexvalue (@active_indices)
	{
		$targets{$indexvalue} = { index_var => $index_var, index_value => $indexvalue };
	}

	return (undef, \@active_indices, \%targets);
}

1;
