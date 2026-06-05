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

# Returns an arrayref of model-section keys this engine handles. Default is
# [protocol_name]. Engines that handle multiple section keys (e.g. Engine::HTTP
# with http_prom and http_json) override this to return all of theirs.
sub section_keys
{
	my ($self) = @_;
	return [ $self->protocol_name ];
}

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

# Discover which indexes are currently present for a systemHealth section.
# Called by Node::collect_systemhealth_info() to get the list of active indexes.
#
# args: section_config (hashref - the model's systemHealth sys section),
#       index_var (string - the indexed field name),
#       index_snmp (string - OID or name for SNMP index table),
#       index_regex (string - regex to extract index from OID)
# returns: ($error, \@active_indices, \%targets)
#   $error: undef on success, error string on failure
#   @active_indices: list of index values found
#   %targets: index => { index_var => $name, index_value => $value } (optional per-index data)
sub discover_indexes { confess("abstract: discover_indexes must be overridden"); }

# Classify the last error from this engine's transport.
# Returns: undef if no error, or hashref:
#   { type => 'not_present'|'model_error'|'no_session'|'transport_error', message => $string }
# Default: no classification (subclasses override for protocol-specific error patterns).
sub classify_error { return undef; }

# Returns true if this engine manages a persistent session that requires
# open/close lifecycle (e.g. SNMP). Used to gate session-result handling
# (failover notifications, up events) — engines without real sessions
# should not trigger those.
# Default: 0 (no session, e.g. WMI).
sub has_session { return 0; }

# Open this engine's transport session. Called by Node before data collection.
# Returns: 1 on success, 0 on failure.
# Default: 1 (no explicit session needed, e.g. WMI).
sub open_session { return 1; }

# Close this engine's transport session.
# Default: no-op (no persistent session, e.g. WMI).
sub close_session { return undef; }

# Returns true for engines whose data is gathered by an external daemon and
# pushed to NMIS (Redis today, future streaming telemetry). Such engines own
# their inventory lifecycle and must run the systemHealth reconcile during
# collect, because no update pass will run it for them. SNMP/WMI/HTTP inherit
# 0 and keep reconciling inventory in update().
# Default: 0.
sub manages_own_inventory { return 0; }

1;
