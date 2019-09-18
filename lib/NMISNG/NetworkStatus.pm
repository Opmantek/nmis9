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
our $VERSION = "9.0.6c";

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

# Return nmisng
sub nmisng
{
	my ( $self, %args ) = @_;
	return $self->{_nmisng};
}

# Return log
sub log
{
	my ( $self, %args ) = @_;
	return $self->{_log};
}

# Return nmis conf
sub nmis_conf
{
	my ( $self, %args ) = @_;
	unless (defined($self->{_nmis_conf})) {
		$self->{_nmis_conf} = NMISNG::Util::loadConfTable();
	}
	return $self->{_nmis_conf};
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
				($event_status) = $self->eventLevel("Node Down",$config->{roleType});
			}
			else {
				($event_status) = $self->eventLevel("Node Up",$config->{roleType});
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

# Get group Summary
# Replace getGroupSummary in NMIS.pm
# to cache all the possible information
sub getGroupSummary {
	my ( $self, %args ) = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $start_time = $args{start};
	my $end_time = $args{end};
	my $include_nodes = $args{include_nodes} // 0;
	my $local_nodes = $args{local_nodes};

	my @tmpsplit;
	my @tmparray;

	my $SUM = undef;
	my $reportStats;
	my %nodecount = ();
	my $node;
	my $index;
	my $cache = 0;
	my $filename;

	my %summaryHash = ();

	#$self->log->debug2(&NMISNG::Log::trace()."Starting");

	# grouped_node_summary joins collections, node_config is the prefix for the nodes config
	my $group_by = ['node_config.configuration.group']; # which is deeply structured!
	$group_by = undef if( !$group );

	my ($entries,$count,$error);
	if ($local_nodes) {
		#$self->log->debug("getGroupSummary - Getting local nodes");
		($entries,$count,$error) = $self->nmisng->grouped_node_summary(
			filters => { 'node_config.configuration.group' => $group, cluster_id => $$self->nmisng->config->{cluster_id}},
			group_by => $group_by,
			include_nodes => $include_nodes
		);
	}
	else {
		#$self->log->debug("getGroupSummary - Getting all nodes");
		($entries,$count,$error) = $self->nmisng->grouped_node_summary(
			filters => { 'node_config.configuration.group' => $group },
			group_by => $group_by,
			include_nodes => $include_nodes
		);
	}

	if( $error || @$entries != 1 )
	{
		my $group_by_str = ($group_by)?join(",",@$group_by):"";
		$error ||= "No data returned for group:$group,group_by:$group_by_str include_nodes:$include_nodes";
		#$self->log->error("Failed to get grouped_node_summary data, error:$error");
		return \%summaryHash;
	}
	my ($group_summary,$node_data);
	if( $include_nodes )
	{
		$group_summary = $entries->[0]{grouped_data}[0];
		$node_data = $entries->[0]{node_data}
	}
	else
	{
		$group_summary = $entries->[0];
	}

	my $C = $self->nmis_conf();

	my @loopdata = ({key =>"reachable", precision => "3f"},{key =>"available", precision => "3f"},{key =>"health", precision => "3f"},{key =>"response", precision => "3f"});
	foreach my $entry ( @loopdata )
	{
		my ($key,$precision) = @$entry{'key','precision'};
		$summaryHash{average}{$key} = sprintf("%.${precision}", $group_summary->{"08_${key}_avg"});
		$summaryHash{average}{"${key}_diff"} = $group_summary->{"16_${key}_avg"} - $group_summary->{"08_${key}_avg"};

		# Now the summaryHash is full, calc some colors and check for empty results.
		if ( $summaryHash{average}{$key} ne "" )
		{
			$summaryHash{average}{$key} = 100 if( $summaryHash{average}{$key} > 100  && $key ne 'response') ;
			$summaryHash{average}{"${key}_color"} = $self->colorHighGood($summaryHash{average}{$key})
		}
		else
		{
			$summaryHash{average}{"${key}_color"} = "#aaaaaa";
			$summaryHash{average}{$key} = "N/A";
		}
	}

	if ( $summaryHash{average}{reachable} > 0 and $summaryHash{average}{available} > 0 and $summaryHash{average}{health} > 0 )
	{
		# new weighting for metric
		$summaryHash{average}{metric} = sprintf("%.3f",(
																							( $summaryHash{average}{reachable} * $C->{metric_reachability} ) +
																							( $summaryHash{average}{available} * $C->{metric_availability} ) +
																							( $summaryHash{average}{health} * $C->{metric_health} ))
				);
		$summaryHash{average}{"16_metric"} = sprintf("%.3f",(
																									 ( $group_summary->{"16_reachable_avg"} * $C->{metric_reachability} ) +
																									 ( $group_summary->{"16_available_avg"} * $C->{metric_availability} ) +
																									 ( $group_summary->{"16_health_avg"} * $C->{metric_health} ))
				);
		$summaryHash{average}{metric_diff} = $summaryHash{average}{"16_metric"} - $summaryHash{average}{metric};
	}

	$summaryHash{average}{counttotal} = $group_summary->{count} || 0;
	$summaryHash{average}{countdown} = $group_summary->{countdown} || 0;
	$summaryHash{average}{countdegraded} = $group_summary->{countdegraded} || 0;
	$summaryHash{average}{countup} = $group_summary->{count} - $group_summary->{countdegraded} - $group_summary->{countdown};

	### 2012-12-17 keiths, fixed divide by zero error when doing group status summaries
	if ( $summaryHash{average}{countdown} > 0 ) {
		$summaryHash{average}{countdowncolor} = ($summaryHash{average}{countdown}/$summaryHash{average}{counttotal})*100;
	}
	else {
		$summaryHash{average}{countdowncolor} = 0;
	}

	# if the node info is needed then add it.
	if( $include_nodes )
	{
		foreach my $entry (@$node_data)
		{
			my $node = $entry->{name};
			++$nodecount{counttotal};
			my $outage = '';
			$summaryHash{$node} = $entry;

			my $nodeobj = $self->nmisng->node(uuid => $entry->{uuid}); # much safer than by node name

			# check nodes
			# Carefull logic here, if nodedown is false then the node is up
			#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
			if (NMISNG::Util::getbool($summaryHash{$node}{nodedown})) {
				($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = $self->eventLevel("Node Down",$entry->{roleType});
				++$nodecount{countdown};
				($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());
			}
			elsif (exists $C->{display_status_summary}
						 and NMISNG::Util::getbool($C->{display_status_summary})
						 and exists $summaryHash{$node}{nodestatus}
						 and $summaryHash{$node}{nodestatus} eq "degraded"
					) {
				$summaryHash{$node}{event_status} = "Error";
				$summaryHash{$node}{event_color} = "#ffff00";
				++$nodecount{countdegraded};
				($outage,undef) = NMISNG::Outage::outageCheck(node=>$nodeobj,time=>time());
			}
			else {
				($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = $self->eventLevel("Node Up",$entry->{roleType});
				++$nodecount{countup};
			}

			# dont if outage current with node down
			if ($outage ne 'current') {
				if ( $summaryHash{$node}{reachable} !~ /NaN/i	) {
					++$nodecount{reachable};
					$summaryHash{$node}{reachable_color} = $self->colorHighGood($summaryHash{$node}{reachable});
				} else { $summaryHash{$node}{reachable} = "NaN" }

				if ( $summaryHash{$node}{available} !~ /NaN/i ) {
					++$nodecount{available};
					$summaryHash{$node}{available_color} = $self->colorHighGood($summaryHash{$node}{available});
				} else { $summaryHash{$node}{available} = "NaN" }

				if ( $summaryHash{$node}{health} !~ /NaN/i ) {
					++$nodecount{health};
					$summaryHash{$node}{health_color} = $self->colorHighGood($summaryHash{$node}{health});
				} else { $summaryHash{$node}{health} = "NaN" }

				if ( $summaryHash{$node}{response} !~ /NaN/i ) {
					++$nodecount{response};
					$summaryHash{$node}{response_color} = NMISNG::Util::colorResponseTime($summaryHash{$node}{response});
				} else { $summaryHash{$node}{response} = "NaN" }
			}
		}
	}

	#$self->log->debug2(&NMISNG::Log::trace()."Finished");
	return \%summaryHash;
} # end getGroupSummary

# small helper that translates event data into a severity level
# args: event, role.
# returns: severity level, color
# fixme: only used for group status summary display! actual event priorities come from the model
sub eventLevel {
	my ($self, $event, $role) = @_;

	my ($event_level, $event_color);

	my $C = $self->nmis_conf();			# cached, mostly nop

	# the config now has a structure for xlat between roletype and severities for node down/other events
	my $rt2sev = $C->{severity_by_roletype};
	$rt2sev = { default => [ "Major", "Minor" ] } if (ref($rt2sev) ne "HASH" or !keys %$rt2sev);

	if ( $event eq 'Node Down' )
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[0] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[0] : "Major";
	}
	elsif ( $event =~ /up/i )
	{
		$event_level = "Normal";
	}
	else
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[1] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[1] : "Major";
	}
	$event_level = "Major" if ($event_level !~ /^(fatal|critical|major|minor|warning|normal)$/i); 	# last-ditch fallback
	$event_color = NMISNG::Util::eventColor($event_level);

	return ($event_level,$event_color);
}

sub colorHighGood {
	my ($self, $threshold) = @_;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold eq "N/A" )  { $color = "#FFFFFF"; }
	elsif ( $threshold >= 100 ) { $color = "#00FF00"; }
	elsif ( $threshold >= 95 ) { $color = "#00EE00"; }
	elsif ( $threshold >= 90 ) { $color = "#00DD00"; }
	elsif ( $threshold >= 85 ) { $color = "#00CC00"; }
	elsif ( $threshold >= 80 ) { $color = "#00BB00"; }
	elsif ( $threshold >= 75 ) { $color = "#00AA00"; }
	elsif ( $threshold >= 70 ) { $color = "#009900"; }
	elsif ( $threshold >= 65 ) { $color = "#008800"; }
	elsif ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold >= 55 ) { $color = "#FFEE00"; }
	elsif ( $threshold >= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold >= 45 ) { $color = "#FFCC00"; }
	elsif ( $threshold >= 40 ) { $color = "#FFBB00"; }
	elsif ( $threshold >= 35 ) { $color = "#FFAA00"; }
	elsif ( $threshold >= 30 ) { $color = "#FF9900"; }
	elsif ( $threshold >= 25 ) { $color = "#FF8800"; }
	elsif ( $threshold >= 20 ) { $color = "#FF7700"; }
	elsif ( $threshold >= 15 ) { $color = "#FF6600"; }
	elsif ( $threshold >= 10 ) { $color = "#FF5500"; }
	elsif ( $threshold >= 5 )  { $color = "#FF3300"; }
	elsif ( $threshold > 0 )   { $color = "#FF1100"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }

	return $color;
}


1;
