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

# Package giving access to functions in Compact but saving the status
# Allows reuse DB connection and nmisng
# Not the same purpose as nmisng
package NMISNG::NetworkStatus;
our $VERSION = "9.0.5";

use strict;
use Data::Dumper;

use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::Outage;
use Compat::Timing;

# params:
#  log - NMISNG::Log object to log to, required.
#  nmisng - nmisng object, required.
sub new
{
	my ( $class, %args ) = @_;

	#die "Log required" if ( !$args{log} );
    #die "Nmisng object required" if ( $args{nmisng} ne "NMISNG" );

	my $self = bless(
		{
			_log     => $args{log},
			_nmisng  => $args{nmisng},           # sub plugins populates that on the go
		},
		$class
			);

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

# this function computes overall metrics for all nodes/groups
# args: self, group, customer, business
# returns: hashref, keys success/error - fixme9 error handling incomplete
sub overallNodeStatus
{

	my ( $self, %args ) = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $netType = $args{netType};
	my $roleType = $args{roleType};

	if (scalar(@_) == 1) {
		$group = shift;
	}

	my $node_name;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $status;

	my %statusHash;

	my $t      = Compat::Timing->new();
	my $C = $self->{_nmisng}->config;
	# We only want the master nodes, so use cluster_id
	my $NT = $self->get_nt();

	foreach $node_name (sort keys %{$NT} )
	{
		my $config = $NT->{$node_name};
		next if (!NMISNG::Util::getbool($config->{active}));

		if (
			( $group eq "" and $customer eq "" and $business eq "" and $netType eq "" and $roleType eq "" )
			or
			( $netType ne "" and $roleType ne ""
				and $config->{net} eq "$netType" && $config->{role} eq "$roleType" )
			or ($group ne "" and $config->{group} eq $group)
			or ($customer ne "" and $config->{customer} eq $customer)
			or ($business ne "" and $config->{businessService} =~ /$business/ ) )
		{
			my $nodedown = 0;
			my $outage = "";

            # FIXME: Improve call - We really need all this data?
			my $nodeobj = $self->{_nmisng}->node(uuid => $config->{uuid});

            ### 2013-08-20 keiths, check for SNMP Down if ping eq false.
            my $down_event = "Node Down";
            $down_event = "SNMP Down" if NMISNG::Util::getbool($config->{ping},"invert");
            $nodedown = $nodeobj->eventExist($down_event);

			($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());

			if ( $nodedown and $outage ne 'current' ) {
				($event_status) = Compat::NMIS::eventLevel("Node Down",$config->{roleType});
			}
			else {
				($event_status) = Compat::NMIS::eventLevel("Node Up",$config->{roleType});
			}

			++$statusHash{$event_status};
			++$statusHash{count};
		}
	}

	$status_number = 100 * $statusHash{Normal};
	$status_number = $status_number + ( 90 * $statusHash{Warning} );
	$status_number = $status_number + ( 75 * $statusHash{Minor} );
	$status_number = $status_number + ( 60 * $statusHash{Major} );
	$status_number = $status_number + ( 50 * $statusHash{Critical} );
	$status_number = $status_number + ( 40 * $statusHash{Fatal} );
	if ( $status_number != 0 and $statusHash{count} != 0 ) {
		$status_number = $status_number / $statusHash{count};
	}
	#print STDERR "New CALC: status_number=$status_number count=$statusHash{count}\n";

	### 2014-08-27 keiths, adding a more coarse any nodes down is red
	if ( defined $C->{overall_node_status_coarse}
			 and NMISNG::Util::getbool($C->{overall_node_status_coarse})) {
		$C->{overall_node_status_level} = "Critical" if not defined $C->{overall_node_status_level};
		if ( $status_number == 100 ) { $overall_status = "Normal"; }
		else { $overall_status = $C->{overall_node_status_level}; }
	}
	else {
		### AS 11/4/01 - Fixed up status for single node groups.
		# if the node count is one we do not require weighting.
		if ( $statusHash{count} == 1 ) {
			delete ($statusHash{count});
			foreach $status (keys %statusHash) {
				if ( $statusHash{$status} ne "" and $statusHash{$status} ne "count" ) {
					$overall_status = $status;
					#print STDERR returnDateStamp." overallNodeStatus netType=$netType status=$status hash=$statusHash{$status}\n";
				}
			}
		}
		elsif ( $status_number != 0  ) {
			if ( $status_number == 100 ) { $overall_status = "Normal"; }
			elsif ( $status_number >= 95 ) { $overall_status = "Warning"; }
			elsif ( $status_number >= 90 ) { $overall_status = "Minor"; }
			elsif ( $status_number >= 70 ) { $overall_status = "Major"; }
			elsif ( $status_number >= 50 ) { $overall_status = "Critical"; }
			elsif ( $status_number <= 40 ) { $overall_status = "Fatal"; }
			elsif ( $status_number >= 30 ) { $overall_status = "Disaster"; }
			elsif ( $status_number < 30 ) { $overall_status = "Catastrophic"; }
		}
		else {
			$overall_status = "Unknown";
		}
	}
	return $overall_status;
} # end overallNodeStatus

# Get nodes table
# Saving this value is used like a cached value
sub get_nt {

    my ( $self, %args ) = @_;

    unless (defined($self->{_nt})) {
		$self->{_nt} = $self->get_load_node_table();
	}
	return $self->{_nt};
}

# Get local nodes table
# Only locals - Not pollers nodes
# Saving this value is used like a cached value
sub get_local_nt {

    my ( $self, %args ) = @_;

    unless (defined($self->{_local_nt})) {
		$self->{_local_nt} = $self->get_load_node_table(local => "true");
	}
	return $self->{_local_nt};
}

# Get nodes summary
# Saving this value is used like a cached value
sub get_ns {

    my ( $self, %args ) = @_;

    unless (defined($self->{_ns})) {
		$self->{_ns} = $self->get_load_node_summary();
	}
	return $self->{_ns};
}

# Get local nodes summary
# Only locals, so filter by cluster_id
# Saving this value is used like a cached value
sub get_local_ns {

    my ( $self, %args ) = @_;

    unless (defined($self->{_local_ns})) {
		$self->{_local_ns} = $self->get_load_node_summary(local => "true");
	}
	return $self->{_local_ns};
}

# Get nodes model
# get all the nodes using nmisng method
# This call can be cached, avoid doing twice
sub get_nodes_model {

    my ( $self, %args ) = @_;

    unless (defined($self->{_nodes_model})) {
		# This call it is not really overloading, but it is adding time if it is called many times
		$self->{_nodes_model} = $self->{_nmisng}->get_nodes_model();

	}
	return $self->{_nodes_model};
}

# Get local nodes model
# So filter by cluster id
# get all the nodes using nmisng method
# This call can be cached, avoid doing twice
sub get_local_nodes_model {

    my ( $self, %args ) = @_;

    unless (defined($self->{_local_nodes_model})) {
		# This call it is not really overloading, but it is adding time if it is called many times
		$self->{_local_nodes_model} = $self->{_nmisng}->get_nodes_model(
									filter => { cluster_id => $self->{_nmisng}->config->{cluster_id} } );

	}
	return $self->{_local_nodes_model};
}

# Get load node table
# Replace loadNodeTable in NMIS.pm
# to cache the get_nodes_model call if possible
# and nmisng object
sub get_load_node_table
{
	my ( $self, %args ) = @_;
	my $modelData;

	# With local, get only nodes from the master
	if ($args{local}) {
		$modelData = $self->get_local_nodes_model();
	} else {
		# ask the database for all noes, my cluster id and all others
		$modelData = $self->get_nodes_model();
	}

	my $data = $modelData->data();

	my %map = map { $_->{name} => $_ } @$data;
	for my $flattenme (values %map)
	{
		for my $confprop (keys %{$flattenme->{configuration}})
		{
			$flattenme->{$confprop} = $flattenme->{configuration}->{$confprop};
		}
		delete $flattenme->{configuration};
		$flattenme->{active} = $flattenme->{activated}->{NMIS};
		delete $flattenme->{activated};

		# untranslate override keys
		for my $uglykey (keys %{$flattenme->{overrides}})
		{
			# must handle compat/legacy load before correct structure in db
			if ($uglykey =~ /^==([A-Za-z0-9+\/=]+)$/)
			{
				my $nicekey = Mojo::Util::b64_decode($1);
				$flattenme->{overrides}->{$nicekey} = $flattenme->{overrides}->{$uglykey};
				delete $flattenme->{overrides}->{$uglykey};
			}
		}
	}
	return \%map;
}

# Get load node summary
# Replace loadNodeSummary in NMIS.pm
# to cache get_nodes_model call if possible
# and nmisng object
sub get_load_node_summary
{
	my ( $self, %args ) = @_;

	my $t      = Compat::Timing->new();
	my $lotsanodes;

	# With local, only get local nodes (from the master) Filter by cluster_id
	if ($args{local}) {
		$lotsanodes = $self->get_local_nodes_model()->objects;
	} else {
		# ask the database for all noes, my cluster id and all others
		$lotsanodes = $self->get_nodes_model()->objects;
	}

	if (my $err = $lotsanodes->{error})
	{
		$self->log->error("failed to retrieve nodes: $err");
		return {};
	}

	# hash of node name -> catchall data, until fixme9: OMK-5972 less stuff gets dumped into catchall
	# also fixme9: will fail utterly with multipolling, node names are not unique, should use node_uuid
	my %summary;
	for my $onenode (@{$lotsanodes->{objects}})
	{
		# detour via sys for possibly cached catchall inventory
		my $S = NMISNG::Sys->new(nmisng => $self->{_nmisng});
		$S->init(node => $onenode, snmp => 'false', wmi => 'false');
		my $catchall_data = $S->inventory( concept => 'catchall' )->data();
		$summary{$onenode->name} = $catchall_data;
	}
	return \%summary;
}

1;
