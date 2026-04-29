package NMISNG::Snmp::Mock;
# Mock SNMP class for testing - implements the NMISNG::Snmp interface
# but returns data from an in-memory hash instead of real SNMP queries.

use strict;
use warnings;
use Scalar::Util;
use NMISNG::MIB;

sub new
{
	my ($class, %arg) = @_;

	my $self = bless({
		name      => $arg{name} || 'mock',
		walk_data => $arg{walk_data} || {},
		_nmisng   => $arg{nmisng},
		error     => undef,
		session   => 0,
		config    => {},
		actual_version      => 'snmpv2c',
		actual_max_msg_size => 1472,
	}, $class);

	Scalar::Util::weaken $self->{_nmisng}
		if ($self->{_nmisng} && !Scalar::Util::isweak($self->{_nmisng}));

	return $self;
}

sub nmisng { return shift->{_nmisng}; }

sub name
{
	my ($self, $newname) = @_;
	$self->{name} = $newname if defined $newname;
	return $self->{name};
}

sub error
{
	my ($self) = @_;
	return $self->{_forced_error} if defined $self->{_forced_error};
	return $self->{error};
}

sub version
{
	my ($self) = @_;
	return $self->{session} ? $self->{actual_version} : undef;
}

sub max_msg_size
{
	my ($self) = @_;
	return $self->{session} ? $self->{actual_max_msg_size} : undef;
}

sub isopen
{
	my ($self) = @_;
	return $self->{session} ? 1 : 0;
}

# Delegate to real MIB resolution
sub name_to_oid
{
	my ($self, $zero, $name) = @_;
	my $oid;

	if ($name =~ /^(\w+)(.*)$/)
	{
		$oid = NMISNG::MIB::name2oid($self->nmisng, $1) . $2;
	}
	else
	{
		$oid = NMISNG::MIB::name2oid($self->nmisng, $name);
	}

	if (defined($oid))
	{
		$oid .= ".0" if ($zero && $name !~ /\./);
		return $oid;
	}
	else
	{
		$self->{error} = "Mib name $name does not exist!";
		return undef;
	}
}

# Translate OID keys to names
sub keys2name
{
	my ($self, $hash) = @_;
	my %rewritten;
	for my $oid (keys %{$hash})
	{
		my $name = NMISNG::MIB::oid2name($self->nmisng, $oid) || $oid;
		$rewritten{$name} = $hash->{$oid};
	}
	return \%rewritten;
}

# Force an error state for testing error handling paths.
# When set, getarray() returns undef and error() returns the forced string.
# Call with undef to clear.
sub force_error
{
	my ($self, $error_string) = @_;
	$self->{_forced_error} = $error_string;
}

# Open: just store config and mark session as open
sub open
{
	my ($self, %args) = @_;

	if (ref($args{config}) eq "HASH")
	{
		$self->{config} = $args{config};
	}
	else
	{
		$self->{config} = \%args;
	}
	$self->{config}{oidpkt} ||= 10;
	$self->{session} = 1;
	$self->{error} = undef;
	return 1;
}

sub close
{
	my ($self) = @_;
	$self->{session} = 0;
	return undef;
}

# Test session by checking if sysObjectID.0 exists in walk data
sub testsession
{
	my ($self) = @_;
	my $oid = "1.3.6.1.2.1.1.2.0";
	my $result = $self->get($oid);
	return (ref($result) eq "HASH" && $result->{$oid}) ? 1 : 0;
}

# Get: look up each OID in walk_data, return hashref
sub get
{
	my ($self, @vars) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform get!";
		return undef;
	}

	my @certainlyoids;
	for my $var (@vars)
	{
		if ($var =~ /^(\.?\d+)+$/)
		{
			push @certainlyoids, $var;
		}
		else
		{
			if (my $oid = $self->name_to_oid(1, $var))
			{
				push @certainlyoids, $oid;
			}
			else
			{
				return undef;
			}
		}
	}

	my %result;
	for my $oid (@certainlyoids)
	{
		if (exists $self->{walk_data}{$oid})
		{
			$result{$oid} = $self->{walk_data}{$oid};
		}
		else
		{
			# SNMP returns noSuchInstance for missing OIDs but doesn't fail the whole request.
			# Case matters: NMISNG::Sys and rrdfunc compare against the literal "noSuchInstance".
			$result{$oid} = "noSuchInstance";
		}
	}

	$self->{error} = undef;
	return \%result;
}

# Getarray: return values in input order
sub getarray
{
	my ($self, @vars) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform getarray!";
		return undef;
	}

	# If a forced error is set, simulate transport failure
	return undef if defined $self->{_forced_error};

	my @certainlyoids;
	for my $var (@vars)
	{
		if ($var =~ /^(\.?\d+)+$/)
		{
			push @certainlyoids, $var;
		}
		else
		{
			if (my $oid = $self->name_to_oid(1, $var))
			{
				push @certainlyoids, $oid;
			}
			else
			{
				return undef;
			}
		}
	}

	my @retvals;
	for my $oid (@certainlyoids)
	{
		if (exists $self->{walk_data}{$oid})
		{
			push @retvals, $self->{walk_data}{$oid};
		}
		else
		{
			push @retvals, "noSuchInstance";
		}
	}

	$self->{error} = undef;
	return @retvals;
}

# Gettable: return all OIDs in walk_data with matching prefix
sub gettable
{
	my ($self, $name, $maxrepetitions, $rewritekeys) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform gettable!";
		return undef;
	}

	# Translate name to numeric OID if needed
	if ($name !~ /^(\.?\d+)+$/)
	{
		if (my $oid = $self->name_to_oid(0, $name))
		{
			$name = $oid;
		}
		else
		{
			$self->{error} = "Incorrect mib name, could not translate name:$name to oid";
			return undef;
		}
	}

	my %result;
	for my $oid (keys %{$self->{walk_data}})
	{
		# Match OIDs that start with the base OID followed by a dot
		if ($oid =~ /^\Q$name\E\./)
		{
			$result{$oid} = $self->{walk_data}{$oid};
		}
	}

	if (!%result)
	{
		$self->{error} = "Requested table $name is empty or does not exist";
		return undef;
	}

	if ($rewritekeys)
	{
		for my $fullkey (keys %result)
		{
			my $newkey = $fullkey;
			$newkey =~ s/^\Q$name\E\.//;
			$result{$newkey} = $result{$fullkey};
			delete $result{$fullkey};
		}
	}

	$self->{error} = undef;
	return \%result;
}

# Getindex: gettable with rewritekeys=1
sub getindex
{
	my ($self, $name, $maxrepetitions) = @_;
	return $self->gettable($name, $maxrepetitions, 1);
}

1;
