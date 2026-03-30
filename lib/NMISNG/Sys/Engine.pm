package NMISNG::Sys::Engine;
# Base class for protocol-specific polling engines.
# Subclasses implement build_queries() and execute_queries()
# to handle protocol-specific data fetching (SNMP, WMI, etc.)
# while Sys.pm handles shared value processing.

use strict;
use warnings;
use Scalar::Util;
use Carp;

our $VERSION = "9.6.5";

sub new
{
	my ($class, %args) = @_;
	confess("sys argument required") unless $args{sys};

	my $self = bless({
		_sys => $args{sys},
	}, $class);

	# Weak ref to avoid circular reference (Sys -> engines -> Sys)
	Scalar::Util::weaken($self->{_sys});

	return $self;
}

sub sys { return $_[0]->{_sys}; }

# Returns the protocol name used as the key in model sections
# and for status error keys (e.g., "snmp_error", "wmi_error").
# Must be overridden by subclasses.
sub protocol_name { confess("abstract: protocol_name must be overridden"); }

# Returns true if this engine's transport is available on the Sys object.
# Must be overridden by subclasses.
sub is_active { confess("abstract: is_active must be overridden"); }

# Build protocol-specific query entries in the shared %todos hash.
# Called once per model section that has items for this protocol.
#
# args: section_name, section_hash, index, port, inventory, todos (hashref)
# returns: hashref with optional 'error' key
sub build_queries { confess("abstract: build_queries must be overridden"); }

# Execute all pending queries that this engine built.
# Reads from %todos entries that have protocol-specific keys (e.g., 'oid' or 'query'),
# performs the actual data fetch, and sets {rawvalue} and {done} on each entry.
#
# args: todos (hashref), index
# returns: hashref with optional 'error' key
sub execute_queries { confess("abstract: execute_queries must be overridden"); }

# Classify the last error from this engine's transport.
# Returns: undef if no error, or hashref:
#   { type => 'not_present'|'model_error'|'no_session'|'transport_error', message => $string }
# Default: no classification (subclasses override for protocol-specific error patterns).
sub classify_error { return undef; }

# Open this engine's transport session. Called by Node before data collection.
# Returns: 1 on success, 0 on failure.
# Default: 1 (no explicit session needed, e.g. WMI).
sub open_session { return 1; }

1;
