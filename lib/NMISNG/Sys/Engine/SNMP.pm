package NMISNG::Sys::Engine::SNMP;
# SNMP polling engine - handles OID building and batch SNMP fetching.
# Extracted from NMISNG::Sys::getValues() lines 1249-1336 (build) and 1398-1414 (execute).

use strict;
use warnings;
use parent 'NMISNG::Sys::Engine';
use Net::SNMP;

our $VERSION = "9.6.5";

sub protocol_name { return "snmp"; }
sub has_session   { return 1; }

sub is_active
{
	my ($self) = @_;
	return defined($self->sys->{snmp}) ? 1 : 0;
}

# Build SNMP OID entries in the shared %todos hash.
# Handles calculate_index, calculate_oid, suffix computation, and multi-section dedup.
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_hash, $index, $port, $inventory, $todos)
		= @args{qw(section_name section_hash index port inventory todos)};

	my $sys = $self->sys;
	my %status;

	my $default_suffix
		= (defined($port) && $port ne '') ? ".$port"
		: (defined($index) && $index ne '') ? ".$index"
		: "";
	$sys->nmisng->log->debug("class: index=" . ($index // '') . " port=" . ($port // '') . " suffix=$default_suffix");

	for my $itemname (keys %{$section_hash})
	{
		my $suffix = $default_suffix;
		my $thisitem = $section_hash->{$itemname};

		# calculate_index: dynamic suffix computation
		if (exists($thisitem->{calculate_index}) && (my $calc = $thisitem->{calculate_index}))
		{
			if ($calc ne "")
			{
				my ($error, $result) = $sys->eval_string(
					string    => $calc,
					context   => "",
					variables => [$inventory ? $inventory->data() : {}]
				);
				if ($error)
				{
					$status{error} = $error;
					$sys->nmisng->log->error("($sys->{name}) getValues calculate_index failed: $error");
					next;
				}
				if ($result)
				{
					$suffix = "." . $result;
				}
				else
				{
					$suffix = "";
				}
				$sys->nmisng->log->debug4(sub { "calculated suffix is: " . $suffix });
			}
		}

		# calculate_oid: dynamic OID computation
		if (exists($thisitem->{calculate_oid}) && (my $calc = $thisitem->{calculate_oid}))
		{
			$sys->nmisng->log->debug4("Calculating oid : $calc \n");
			my ($error, $result) = $sys->eval_string(
				string    => $calc,
				context   => "",
				variables => [$inventory ? $inventory->data() : {}]
			);
			if ($error)
			{
				$status{error} = $error;
				$sys->nmisng->log->error("($sys->{name}) getValues calculate_oid failed: $error");
				next;
			}
			if ($result)
			{
				$thisitem->{oid} = $result;
				$sys->nmisng->log->debug4(sub { "calculated oid is: " . $result });
			}
			else
			{
				next;
			}
		}

		next if (!exists $thisitem->{oid});

		$sys->nmisng->log->debug3(sub { "oid $thisitem->{oid} for section $section_name, item $itemname primed for loading" });

		# Dedup: same item may appear in multiple sections
		if ($todos->{$itemname})
		{
			if ($todos->{$itemname}->{oid} ne $thisitem->{oid} . $suffix)
			{
				$status{error} = "($sys->{name}) model error, $itemname has multiple clashing oids!";
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
				oid     => $thisitem->{oid} . $suffix,
				section => [$section_name],
				item    => $itemname,
				details => [$thisitem]
			};
		}
	}

	return \%status;
}

# Execute all pending SNMP queries in one batch getarray call.
sub execute_queries
{
	my ($self, %args) = @_;
	my ($todos, $index) = @args{qw(todos index)};

	my $sys = $self->sys;
	my $transport = $sys->{snmp};
	return {} unless $transport;

	my %status;

	my @haveoid = grep { exists($todos->{$_}->{oid}) } keys %$todos;
	return {} unless @haveoid;

	my @rawsnmp = $transport->getarray(map { $todos->{$_}->{oid} } @haveoid);
	if (my $error = $transport->error)
	{
		$sys->nmisng->log->error("($sys->{name}) on get values by snmp: $error");
		$status{error} = $error;
	}
	else
	{
		for my $idx (0 .. $#haveoid)
		{
			$todos->{$haveoid[$idx]}->{rawvalue} = $rawsnmp[$idx];
			$todos->{$haveoid[$idx]}->{done}     = 1;
		}
	}

	return \%status;
}

# Discover SNMP indexes for a systemHealth section via gettable on the index OID.
# Returns ($error, \@active_indices, \%targets)
sub discover_indexes
{
	my ($self, %args) = @_;
	my ($section_config, $index_var, $index_snmp, $index_regex)
		= @args{qw(section_config index_var index_snmp index_regex)};

	my $sys = $self->sys;
	my $transport = $sys->{snmp};
	return ("SNMP not configured", undef, undef) unless $transport;

	if (!$index_snmp)
	{
		return ("no index_snmp value for SNMP index discovery", undef, undef);
	}

	my $healthIndexTable = $transport->gettable($index_snmp);
	if (!$healthIndexTable)
	{
		my $error = $transport->error // "unknown error";
		return ($error, undef, undef);
	}

	my %targets;
	for my $oid (Net::SNMP::oid_lex_sort(keys %{$healthIndexTable}))
	{
		my $index = $oid;
		if ($oid =~ /$index_regex/)
		{
			$index = $1;
		}
		$targets{$index} = { index_var => $index_var, index_value => $index };
	}

	my @active_indices = sort keys %targets;
	return (undef, \@active_indices, \%targets);
}

# Check for NBARPD support via SNMP table lookup.
# Called from Sys::loadNodeInfo().
sub check_nbarpd
{
	my ($self, %args) = @_;
	my $catchall_data = $args{catchall_data};
	my $config = $args{config};

	my $sys = $self->sys;
	my $transport = $sys->{snmp};
	return "false" unless $transport;

	my $max_repetitions = $catchall_data->{max_repetitions} || $config->{snmp_max_repetitions};
	my $result = $transport->gettable('cnpdStatusTable', $max_repetitions);

	if ($result && ref($result) eq "HASH" && keys %$result)
	{
		$sys->nmisng->log->debug("NBARPD is true on this node");
		return "true";
	}
	$sys->nmisng->log->debug("NBARPD is false on this node");
	return "false";
}

# Classify the last SNMP transport error into a structured type.
sub classify_error
{
	my ($self) = @_;
	my $transport = $self->sys->{snmp};
	return undef unless $transport;
	my $error = $transport->error;
	return undef unless $error;

	if ($error =~ /is empty or does not exist/)
	{
		return { type => 'not_present', message => $error };
	}
	elsif ($error =~ /incorrect syntax/ || $error =~ /Received noSuchName/)
	{
		return { type => 'model_error', message => $error };
	}
	elsif ($error =~ /No session open/)
	{
		return { type => 'no_session', message => $error };
	}
	return { type => 'transport_error', message => $error };
}

# Open the SNMP session with config-driven parameters.
sub open_session
{
	my ($self, %args) = @_;
	my $config = $args{config};
	my $catchall_data = $args{catchall_data};

	return $self->sys->open(
		timeout         => $config->{snmp_timeout},
		retries         => $config->{snmp_retries},
		max_msg_size    => $config->{snmp_max_msg_size},
		max_repetitions => $catchall_data->{max_repetitions} || $config->{snmp_max_repetitions} || undef,
		oidpkt          => $catchall_data->{max_repetitions} || $config->{snmp_max_repetitions} || 10,
	);
}

# Close the SNMP transport session.
sub close_session
{
	my ($self) = @_;
	my $transport = $self->sys->{snmp};
	return $transport->close if defined $transport;
	return undef;
}

1;
