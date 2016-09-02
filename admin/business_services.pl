#!/usr/bin/perl
#
## $Id: nodes_update_community.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;
use func;
use NMIS;

# Get some command line arguements.
my %arg = getArguements(@ARGV);

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Load the current Nodes Table.
my $LNT = loadLocalNodeTable();
my $NS = loadNodeSummary();
my $KPI = loadTable(dir=>'var',name=>"nmis-summary8h");

my $BS;

# Go through each of the nodes
foreach my $node (sort keys %{$LNT}) {
	# only work on nodes which are active and collect is true.
	if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
		# only update nodes that match a criteria
		my @businessServices = split(",",$LNT->{$node}{businessService});
		foreach my $businessService (@businessServices) {
			print "$businessService: $node $NS->{$node}{nodestatus}\n";
			push(@{$BS->{$businessService}},{node => $node, nodestatus => $NS->{$node}{nodestatus}});

		}	
	}
}

print Dumper $BS;

my @states = qw(reachable degraded unreachable);

foreach my $bs (keys %{$BS}) {
	#print Dumper $BS->{$bs};
	my $health = 0;
	my $SUM = {
		status => 0,
		reachable => 0,
		degraded => 0,
		unreachable => 0,
	};
	my $count = @{$BS->{$bs}};
	foreach my $node (@{$BS->{$bs}}) {
		my $nodehealth = $KPI->{$node->{node}}{health};
		++$SUM->{$node->{nodestatus}};
		if ( $nodehealth =~ /NaN/ ) {
			--$count;
		}
		else {
			$health = $health + $nodehealth;
		}
		print "$bs STATUS: $count $node->{node} $node->{nodestatus} $nodehealth $health\n";
	}

	getHandle();
	makeTables();

	#$SUM->{status} = sprintf("%.2f",($SUM->{reachable} / $count * 100) + ($SUM->{degraded} / $count * 100) / 2); 

	$SUM->{status} = sprintf("%.2f",($health / $count)); 

	foreach my $state (@states) {
		updateScore(
			service => $bs, 
			status => $state,
			value => sprintf("%.2f",($SUM->{$state} / $count * 100)) 
		);
	}
	
	#upsert
	updateService(
		service => $bs, 
		status => $SUM->{status},
		reachable => $SUM->{reachable},
		degraded => $SUM->{degraded},
		unreachable => $SUM->{unreachable},
	);

}

sub existService {
	my %arg = @_;
	my $res = 0;
	my $rec = queryService(service => $arg{service});
	if ( $rec->{service} ne "" ) {
		$res = 1;
	}
	return $res;
}

sub addService {
	my %arg = @_;
	
	if ( $arg{service} ne "" ) {
		if ( not defined $C->{_dbh} ) {
			getHandle();
		}
	
		# Create the statement.
	 	my $stmt =<<EO_SQL;
INSERT INTO service_status (`service`, `status`, `reachable`, `degraded`, `unreachable`) 
VALUES ('$arg{service}', '$arg{status}', '$arg{reachable}', '$arg{degraded}', '$arg{unreachable}');
EO_SQL

		print "DEBUG: Inserting: $arg{service}; SQL:\n$stmt\n" if $C->{debug};
		# Prepare and execute the SQL query
		my $sth = $C->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		#$C->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		
		return 1;
	}
	else {
		print STDERR "addService ERROR: Empty Arguments to create a service entry\n";
		return 0;		
	}
}

sub updateService {
	my %arg = @_;

	# Auto add nodes to the node object
	if ( not existService(service => $arg{service}) ) {
		return(addService(%arg));
	}
	else {
		if ( not defined $C->{_dbh} ) {
			getHandle();
		}

		# Create the statement.
	 	my $stmt =<<EO_SQL;
UPDATE service_status
SET 
  `service` = '$arg{service}', 
  `status` = '$arg{status}', 
  `reachable` = '$arg{reachable}',
  `degraded` = '$arg{degraded}',
  `unreachable` = '$arg{unreachable}'
WHERE service = '$arg{service}';
EO_SQL
	
		print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $C->{debug};
		# Prepare and execute the SQL query
		my $sth = $C->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		
		#$C->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
	}
}

sub queryService {
	my %arg = @_;
	my %rec;

	if ( not defined $C->{_dbh} ) {
		getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `service` 
		FROM service_status
		WHERE service = '$arg{service}';
EO_SQL

	my $sth = $C->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
    $rec{service} = $row->{service};		
    $rec{status} = $row->{status};		
    $rec{reachable} = $row->{reachable};		
    $rec{degraded} = $row->{degraded};		
    $rec{unreachable} = $row->{unreachable};		
  }
	
	# Clean up the record set
	$sth->finish();
	return(\%rec);
}

sub existScore {
	my %arg = @_;
	my $res = 0;
	my $rec = queryScore(service => $arg{service}, status => $arg{status});
	if ( $rec->{service} ne "" ) {
		$res = 1;
	}
	return $res;
}

sub addScore {
	my %arg = @_;
	
	if ( $arg{service} ne "" ) {
		if ( not defined $C->{_dbh} ) {
			getHandle();
		}
	
		# Create the statement.
	 	my $stmt =<<EO_SQL;
INSERT INTO service_score (`service`, `status`, `value`) 
VALUES ('$arg{service}', '$arg{status}', '$arg{value}');
EO_SQL

		print "DEBUG: Inserting: $arg{service}; SQL:\n$stmt\n" if $C->{debug};
		# Prepare and execute the SQL query
		my $sth = $C->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		#$C->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		
		return 1;
	}
	else {
		print STDERR "addService ERROR: Empty Arguments to create a service entry\n";
		return 0;		
	}
}

sub updateScore {
	my %arg = @_;

	# Auto add nodes to the node object
	if ( not existScore(service => $arg{service}, status => $arg{status}) ) {
		return(addScore(%arg));
	}
	else {
		if ( not defined $C->{_dbh} ) {
			getHandle();
		}

		# Create the statement.
	 	my $stmt =<<EO_SQL;
UPDATE service_score
SET 
  `service` = '$arg{service}', 
  `status` = '$arg{status}', 
  `value` = '$arg{value}'
WHERE service = '$arg{service}' and status = '$arg{status}';
EO_SQL
	
		print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $C->{debug};
		# Prepare and execute the SQL query
		my $sth = $C->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		
		#$C->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
	}
}

sub queryScore {
	my %arg = @_;
	my %rec;

	if ( not defined $C->{_dbh} ) {
		getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `service`
		FROM service_score
		WHERE service = '$arg{service}' and status = '$arg{status}';
EO_SQL

	my $sth = $C->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
    $rec{service} = $row->{service};		
    $rec{status} = $row->{status};		
    $rec{value} = $row->{value};		
  }
	
	# Clean up the record set
	$sth->finish();
	return(\%rec);
}

sub makeTables {
	my $handle = getHandle();

	my $stmt =<<EO_SQL;
CREATE TABLE if not exists service_status (
  `service` varchar(128),
  `status` float,
  `reachable` float,
  `degraded` float,
  `unreachable` float,
  PRIMARY KEY (`service`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Business Services Status';
EO_SQL
	

	my $sth  = $C->{_dbh}->do($stmt);

	my $stmt =<<EO_SQL;
CREATE TABLE if not exists service_score (
  `id` INT(3) not null auto_increment,
  `service` varchar(128),
  `status` varchar(32),
  `value` float,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Business Services Score';
EO_SQL
	
	my $sth  = $C->{_dbh}->do($stmt);

	#$C->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";	
	
}

sub getHandle {
	if ( not defined $C->{_dbh} ) {
		my $data_source = "DBI:mysql:database=$C->{nmisdb};host=$C->{db_server};port=$C->{db_port};";
		print STDERR "DBI->connect($data_source, db_user, db_password)\n" if $C->{debug};
		$C->{_dbh} = DBI->connect($data_source, $C->{db_user}, $C->{db_password}, { RaiseError => 1, AutoCommit => 1, mysql_auto_reconnect => 1, ShowErrorStatement => 1 }) || die returnDateStamp()." Connect failed: $DBI::errstr\n";
		$C->{_dbh}->{InactiveDestroy} = 1;
	}
}
