#
## $Id: IPSLA.pm,v 1.7 2013/01/08 23:51:38 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (NMIS).
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

package NMIS::IPSLA;

require 5;

use strict;
use DBI qw(:sql_types);

use vars qw(@EXPORT_OK $VERSION);

use Exporter;

$VERSION = "2.4";

@EXPORT_OK = qw(	
			$version
		);


sub new {
	my ($class,%arg) = @_;

	my $C = undef;
	if ( defined $arg{C} ) { $C = $arg{C} }
	elsif ( not defined $C ) { 
		die returnDateStamp()." NMIS::IPSLA can not continue if not given a Configuration to use.\n"
	}

	my $db = undef;
	if ( defined $C->{nmisdb} ) { $db = $C->{nmisdb} }
	else { $db = "nmisdb" }

	my $server = undef;
	if ( defined $C->{db_server} ) { $server = $C->{db_server} }
	else { $server = "localhost" }

	my $port = undef;
	if ( defined $C->{db_port} ) { $port = $C->{db_port} }
	else { $port = 3306 }

	my $user = undef;
	if ( defined $C->{db_user} ) { $user = $C->{db_user} }
	else { $user = "nmis" }

	my $password = undef;
	if ( defined $C->{db_password} ) { $password = $C->{db_password} }
	else { $password = "nmis" }

	my $prefix = "";
	if ( defined $C->{db_prefix} ) { $prefix = $C->{db_prefix} }
	
	my $debug = undef;
	if ( defined $arg{debug} ) { $debug = $arg{debug} }
	elsif ( not defined $debug ) { $debug = 0 }

	my $self = {
	   	_db => $db,
	   	_server => $server,
	   	_port => $port,
	   	_user => $user,
	   	_password => $password,
	   	_prefix => $prefix,
	   	_probes => {},
	   	_nodes => {},
	   	_dnscache => {},
	   	_db => $db,
		  _dbh => undef,
		  _count => 0,
			_debug => $debug
	};

	bless($self,$class);
	
	$self->getHandle();

	return $self;
}

sub setDebug {
	my ($self,%arg) = @_;
	if ( $arg{debug} == 1 ) {
		$self->{_debug} = 1
	}
	else {
		$self->{_debug} = 0
	}

}

sub getHandle {
	my ($self) = @_;
	my $data_source = "DBI:mysql:$self->{_db}:$self->{_server}:$self->{_port}";
	print STDERR "DBI->connect($data_source, db_user, db_password)\n" if $self->{_debug};
	$self->{_dbh} = DBI->connect($data_source, $self->{_user}, $self->{_password}, { RaiseError => 1, AutoCommit => 1, mysql_auto_reconnect => 1, ShowErrorStatement => 1 }) || die returnDateStamp()." Connect failed: $DBI::errstr\n";
}

sub DESTROY {
	my ($self) = @_;
	if ( defined $self->{_dbh} ) {
		print STDERR "\nDEBUG: RUNNING disconnect on NWS::DB->{_dbh}\n\n" if $self->{_debug};
		$self->{_dbh}->disconnect();
	}
}

sub initialise {
	my ($self,%arg) = @_;
	$self->createProbeTable();
	$self->createNodeTable();
	$self->createDnsCacheTable();
}

sub deleteProbe {
	my ($self,%arg) = @_;

	#maintain the cache!
	if ( $self->{_probes}{$arg{probe}}{probe} ne "" ) {
		delete($self->{_probes}{$arg{probe}});
	}

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}

	# Create the statement.
 	my $stmt =<<EO_SQL;
DELETE FROM $self->{_prefix}probes
WHERE probe = '$arg{probe}';
EO_SQL

	print "DEBUG: Deleting: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
	# Prepare and execute the SQL query
	my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
	$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";

	# Clean up the record set
	$sth->finish();
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub deleteNode {
	my ($self,%arg) = @_;

	#maintain the cache!
	if ( $self->{_nodes}{$arg{node}}{node} ne "" ) {
		delete($self->{_nodes}{$arg{node}});
	}

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}

	# Create the statement.
 	my $stmt =<<EO_SQL;
DELETE FROM $self->{_prefix}ipsla_nodes
WHERE node = '$arg{node}';
EO_SQL

	print "DEBUG: Deleting: $arg{node}; SQL:\n$stmt\n" if $self->{_debug};
	# Prepare and execute the SQL query
	my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
	$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";

	# Clean up the record set
	$sth->finish();
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub deleteDnsCache {
	my ($self,%arg) = @_;

	#maintain the cache!
	if ( $self->{_dnscache}{$arg{lookup}}{lookup} ne "" ) {
		delete($self->{_dnscache}{$arg{lookup}});
	}

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}

	# Create the statement.
 	my $stmt =<<EO_SQL;
DELETE FROM $self->{_prefix}dnscache
WHERE lookup = '$arg{lookup}';
EO_SQL

	print "DEBUG: Deleting: $arg{lookup}; SQL:\n$stmt\n" if $self->{_debug};
	# Prepare and execute the SQL query
	my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
	$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";

	# Clean up the record set
	$sth->finish();
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub _queryProbes {
	my ($self,%arg) = @_;
	my %rec;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `probe`, `entry`, `pnode`, `status`, `func`, `optype`, `database`, `frequence`, `message`, `select`, `rnode`, `codec`, `raddr`, `timeout`, `numpkts`, `deldb`, `history`, `saddr`, `vrf`, `tnode`, `responder`, `starttime`, `interval`, `tos`, `verify`, `tport`, `url`, `dport`, `reqdatasize`, `factor`, `lsrpath`, `lastupdate`, `items`
		FROM $self->{_prefix}probes
		WHERE probe = '$arg{probe}';
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
  	$rec{probe} = $row->{probe};		
  	$rec{entry} = $row->{entry};		
  	$rec{pnode} = $row->{pnode};		
  	$rec{status} = $row->{status};		
  	$rec{func} = $row->{func};		
  	$rec{optype} = $row->{optype};		
  	$rec{database} = $row->{database};		
  	$rec{frequence} = $row->{frequence};		
  	$rec{message} = $row->{message};		
  	$rec{select} = $row->{select};		
  	$rec{rnode} = $row->{rnode};		
  	$rec{codec} = $row->{codec};		
  	$rec{raddr} = $row->{raddr};		
  	$rec{timeout} = $row->{timeout};		
  	$rec{numpkts} = $row->{numpkts};		
  	$rec{deldb} = $row->{deldb};		
  	$rec{history} = $row->{history};		
  	$rec{saddr} = $row->{saddr};		
  	$rec{vrf} = $row->{vrf};		
  	$rec{tnode} = $row->{tnode};		
  	$rec{responder} = $row->{responder};		
  	$rec{starttime} = $row->{starttime};		
  	$rec{interval} = $row->{interval};		
  	$rec{tos} = $row->{tos};		
  	$rec{verify} = $row->{verify};		
  	$rec{tport} = $row->{tport};		
  	$rec{url} = $row->{url};		
  	$rec{dport} = $row->{dport};		
  	$rec{reqdatasize} = $row->{reqdatasize};		
  	$rec{factor} = $row->{factor};		
  	$rec{lsrpath} = $row->{lsrpath};		
  	$rec{lastupdate} = $row->{lastupdate};		
  	$rec{items} = $row->{items};		
    
    #Load or refresh the cache anyway!
   	$self->{_probes}{$row->{probe}} = \%rec;
  }
	
	# Clean up the record set
	$sth->finish();
	return(\%rec);
}


sub _queryNodes {
	my ($self,%arg) = @_;
	my %rec;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `node`, `entry`, `community` 
		FROM $self->{_prefix}ipsla_nodes
		WHERE node = '$arg{node}';
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
    $rec{node} = $row->{node};		
    $rec{entry} = $row->{entry};		
    $rec{community} = $row->{community};		
    
    #Load or refresh the cache anyway!
   	$self->{_nodes}{$row->{node}} = \%rec;
  }
	
	# Clean up the record set
	$sth->finish();
	return(\%rec);
}

sub _queryDnsCache {
	my ($self,%arg) = @_;
	my %rec;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `lookup`, `result`, `age` 
		FROM $self->{_prefix}dnscache
		WHERE lookup = '$arg{lookup}';
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
    $rec{lookup} = $row->{lookup};		
    $rec{result} = $row->{result};		
    $rec{age} = $row->{age};		
    
    #Load or refresh the cache anyway!
   	$self->{_dnscache}{$row->{lookup}} = \%rec;
  }
	
	# Clean up the record set
	$sth->finish();
	return(\%rec);
}

sub loadProbeCache {
	my ($self,%arg) = @_;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `probe`, `entry`, `pnode`, `status`, `func`, `optype`, `database`, `frequence`, `message`, `select`, `rnode`, `codec`, `raddr`, `timeout`, `numpkts`, `deldb`, `history`, `saddr`, `vrf`, `tnode`, `responder`, `starttime`, `interval`, `tos`, `verify`, `tport`, `url`, `dport`, `reqdatasize`, `factor`, `lsrpath`, `lastupdate`, `items`
		FROM $self->{_prefix}probes
		WHERE 1;
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
  	$self->{_probes}{$row->{probe}}{probe} = $row->{probe};		
  	$self->{_probes}{$row->{probe}}{entry} = $row->{entry};		
  	$self->{_probes}{$row->{probe}}{pnode} = $row->{pnode};		
  	$self->{_probes}{$row->{probe}}{status} = $row->{status};		
  	$self->{_probes}{$row->{probe}}{func} = $row->{func};		
  	$self->{_probes}{$row->{probe}}{optype} = $row->{optype};		
  	$self->{_probes}{$row->{probe}}{database} = $row->{database};		
  	$self->{_probes}{$row->{probe}}{frequence} = $row->{frequence};		
  	$self->{_probes}{$row->{probe}}{message} = $row->{message};		
  	$self->{_probes}{$row->{probe}}{select} = $row->{select};		
  	$self->{_probes}{$row->{probe}}{rnode} = $row->{rnode};		
  	$self->{_probes}{$row->{probe}}{codec} = $row->{codec};		
  	$self->{_probes}{$row->{probe}}{raddr} = $row->{raddr};		
  	$self->{_probes}{$row->{probe}}{timeout} = $row->{timeout};		
  	$self->{_probes}{$row->{probe}}{numpkts} = $row->{numpkts};		
  	$self->{_probes}{$row->{probe}}{deldb} = $row->{deldb};		
  	$self->{_probes}{$row->{probe}}{history} = $row->{history};		
  	$self->{_probes}{$row->{probe}}{saddr} = $row->{saddr};		
  	$self->{_probes}{$row->{probe}}{vrf} = $row->{vrf};		
  	$self->{_probes}{$row->{probe}}{tnode} = $row->{tnode};		
  	$self->{_probes}{$row->{probe}}{responder} = $row->{responder};		
  	$self->{_probes}{$row->{probe}}{starttime} = $row->{starttime};		
  	$self->{_probes}{$row->{probe}}{interval} = $row->{interval};		
  	$self->{_probes}{$row->{probe}}{tos} = $row->{tos};		
  	$self->{_probes}{$row->{probe}}{verify} = $row->{verify};		
  	$self->{_probes}{$row->{probe}}{tport} = $row->{tport};		
  	$self->{_probes}{$row->{probe}}{url} = $row->{url};		
  	$self->{_probes}{$row->{probe}}{dport} = $row->{dport};		
  	$self->{_probes}{$row->{probe}}{reqdatasize} = $row->{reqdatasize};		
  	$self->{_probes}{$row->{probe}}{factor} = $row->{factor};		
  	$self->{_probes}{$row->{probe}}{lsrpath} = $row->{lsrpath};
  	$self->{_probes}{$row->{probe}}{lastupdate} = $row->{lastupdate};
  	$self->{_probes}{$row->{probe}}{items} = $row->{items};		
  }
	
	# Clean up the record set
	$sth->finish();
}

sub loadNodeCache {
	my ($self,%arg) = @_;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `node`, `entry`, `community`
		FROM $self->{_prefix}ipsla_nodes
		WHERE 1;
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
  	$self->{_nodes}{$row->{node}}{node} = $row->{node};		
    $self->{_nodes}{$row->{node}}{entry} = $row->{entry};		
    $self->{_nodes}{$row->{node}}{community} = $row->{community};		
  }
	
	# Clean up the record set
	$sth->finish();
}

sub loadDnsCache {
	my ($self,%arg) = @_;

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	
	# Create the statement.
 	my $query =<<EO_SQL;
		SELECT `lookup`, `result`, `age`
		FROM $self->{_prefix}dnscache
		WHERE 1;
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  # Read the matching records and print them out          
  while (my $row = $sth->fetchrow_hashref) {
  	$self->{_dnscache}{$row->{node}}{lookup} = $row->{lookup};		
    $self->{_dnscache}{$row->{node}}{result} = $row->{result};		
    $self->{_dnscache}{$row->{node}}{age} = $row->{age};		
  }
	
	# Clean up the record set
	$sth->finish();
}

sub cleanDnsCache {
	my ($self,%arg) = @_;
	my @old;
	if ( $arg{cacheage} eq "" ) {
		# make dns cache 1 hour old
		$arg{cacheage} = 60 * 60;
	}

	if ( not defined $self->{_dbh} ) {
		$self->getHandle();
	}
	my $time = time;
	
	# Create the statement.
 	my $query =<<EO_SQL;
		DELETE FROM $self->{_prefix}dnscache
		WHERE age + $arg{cacheage} < $time;
EO_SQL

	my $sth = $self->{_dbh}->prepare($query) || die returnDateStamp()." ERROR prepare:\n$query\n$DBI::errstr";
	$sth->execute || die returnDateStamp()." ERROR execute:\n$query\n$DBI::errstr";

  #if ( $row->{age} + $arg{cacheage} < $time  ) {

	# Clean up the record set
	$sth->finish();
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub existProbe {
	my ($self,%arg) = @_;
	my $res = 0;
	if ( defined $self->{_probes}{$arg{probe}} ) {
		$res = 1;
	}
	else {
		my $rec = $self->_queryProbes(probe => $arg{probe});
		if ( $rec->{probe} ne "" ) {
			$res = 1;
		}
	}
	return $res;
}

sub existNode {
	my ($self,%arg) = @_;
	my $res = 0;
	if ( defined $self->{_nodes}{$arg{node}} ) {
		$res = 1;
	}
	else {
		my $rec = $self->_queryNodes(node => $arg{node});
		if ( $rec->{node} ne "" ) {
			$res = 1;
		}
	}
	return $res;
}

sub existDnsCache  {
	my ($self,%arg) = @_;
	my $res = 0;
	if ( defined $self->{_dnscache}{$arg{lookup}} ) {
		$res = 1;
	}
	else {
		my $rec = $self->_queryDnsCache(lookup => $arg{lookup});
		if ( $rec->{lookup} ne "" ) {
			$res = 1;
		}
	}
	return $res;
}

sub addProbe {
	my ($self,%arg) = @_;
	
	if ( $arg{probe} ne "" ) {
		if ( not defined $self->{_dbh} ) {
			$self->getHandle();
		}
	
		# Create the statement.
	 	my $stmt =<<EO_SQL;
INSERT INTO $self->{_prefix}probes (`probe`, `entry`, `pnode`, `status`, `func`, `optype`, `database`, `frequence`, `message`, `select`, `rnode`, `codec`, `raddr`, `timeout`, `numpkts`, `deldb`, `history`, `saddr`, `vrf`, `tnode`, `responder`, `starttime`, `interval`, `tos`, `verify`, `tport`, `url`, `dport`, `reqdatasize`, `factor`, `lsrpath`, `lastupdate`, `items`)
VALUES ('$arg{probe}', '$arg{entry}', '$arg{pnode}', '$arg{status}', '$arg{func}', '$arg{optype}', '$arg{database}', '$arg{frequence}', '$arg{message}', '$arg{select}', '$arg{rnode}', '$arg{codec}', '$arg{raddr}', '$arg{timeout}', '$arg{numpkts}', '$arg{deldb}', '$arg{history}', '$arg{saddr}', '$arg{vrf}', '$arg{tnode}', '$arg{responder}', '$arg{starttime}', '$arg{interval}', '$arg{tos}', '$arg{verify}', '$arg{tport}', '$arg{url}', '$arg{dport}', '$arg{reqdatasize}', '$arg{factor}', '$arg{lsrpath}', '$arg{lastupdate}', '$arg{items}');
EO_SQL
	
		print "DEBUG: Inserting: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
		# Prepare and execute the SQL query
		my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
	
		return 1;
	}
	else {
		print STDERR "NMIS::IPSLA ERROR: Empty Arguments to create a probe entry\n";
		return 0;		
	}
}


sub addNode {
	my ($self,%arg) = @_;
	if ( $arg{entry} eq "" ) { $arg{entry} = 100 }
	
	if ( $arg{node} ne "" ) {
		if ( not defined $self->{_dbh} ) {
			$self->getHandle();
		}
	
		# Create the statement.
	 	my $stmt =<<EO_SQL;
INSERT INTO $self->{_prefix}ipsla_nodes (`node`, `entry`, `community`) 
VALUES ('$arg{node}', '$arg{entry}', '$arg{community}');
EO_SQL

		print "DEBUG: Inserting: $arg{node}; SQL:\n$stmt\n" if $self->{_debug};
		# Prepare and execute the SQL query
		my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		
		return 1;
	}
	else {
		print STDERR "NMIS::IPSLA ERROR: Empty Arguments to create a node entry\n";
		return 0;		
	}
}

sub addDnsCache {
	my ($self,%arg) = @_;
	if ( not $arg{age} ) { $arg{age} = time }
	
	if ( $arg{lookup} ne "" and $arg{result} ne "" ) {
		if ( not defined $self->{_dbh} ) {
			$self->getHandle();
		}

		# Create the statement.
	 	my $stmt =<<EO_SQL;
INSERT INTO $self->{_prefix}dnscache (`lookup`, `result`, `age`) 
VALUES ('$arg{lookup}', '$arg{result}', '$arg{age}');
EO_SQL
	
		print "DEBUG: Inserting: $arg{lookup}; SQL:\n$stmt\n" if $self->{_debug};
		# Prepare and execute the SQL query
		my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
		$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
	
		# Clean up the record set
		$sth->finish();
		#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		
		return 1;
	}
	else {
		print STDERR "NMIS::IPSLA ERROR: Empty Arguments to create a dns cache entry\n";
		return 0;		
	}
}

sub updateProbe {
	my ($self,%arg) = @_;
	my $change = 0;

	print "DEBUG updateProbe probe=$arg{probe} pnode=$arg{pnode} status=$arg{status} func=$arg{func} message=$arg{message}\n" if $self->{_debug};
 
	# Auto add probes to the probe object
	if ( not $self->existProbe(probe => $arg{probe}) ) {
		return($self->addProbe(%arg));
	}
	# Process the state normally
	else {
		my $rec = $self->_queryProbes(probe => $arg{probe});

		if ( $arg{probe} ne "" and $rec->{probe} ne $arg{probe} ) {
			$rec->{probe} = $arg{probe};
			$change = 1;
		}

		if ( $arg{pnode} ne "" and $rec->{pnode} ne $arg{pnode} ) {
			$rec->{pnode} = $arg{pnode};
			$change = 1;
		}

		if ( $arg{status} ne "" and $rec->{status} ne $arg{status} ) {
			$rec->{status} = $arg{status};
			$change = 1;
		}

		if ( $arg{func} ne "" and $rec->{func} ne $arg{func} ) {
			$rec->{func} = $arg{func};
			$change = 1;
		}

		if ( $arg{optype} ne "" and $rec->{optype} ne $arg{optype} ) {
			$rec->{optype} = $arg{optype};
			$change = 1;
		}

		if ( $arg{database} ne "" and $rec->{database} ne $arg{database} ) {
			$rec->{database} = $arg{database};
			$change = 1;
		}

		if ( $arg{message} ne "" and $rec->{message} ne $arg{message} ) {
			$rec->{message} = $arg{message};
			$change = 1;
		}

		if ( $arg{select} ne "" and $rec->{select} ne $arg{select} ) {
			$rec->{select} = $arg{select};
			$change = 1;
		}

		if ( $arg{rnode} ne "" and $rec->{rnode} ne $arg{rnode} ) {
			$rec->{rnode} = $arg{rnode};
			$change = 1;
		}

		if ( $arg{raddr} ne "" and $rec->{raddr} ne $arg{raddr} ) {
			$rec->{raddr} = $arg{raddr};
			$change = 1;
		}

		if ( $arg{deldb} ne "" and $rec->{deldb} ne $arg{deldb} ) {
			$rec->{deldb} = $arg{deldb};
			$change = 1;
		}

		if ( $arg{saddr} ne "" and $rec->{saddr} ne $arg{saddr} ) {
			$rec->{saddr} = $arg{saddr};
			$change = 1;
		}

		if ( $arg{vrf} ne "" and $rec->{vrf} ne $arg{vrf} ) {
			$rec->{vrf} = $arg{vrf};
			$change = 1;
		}

		if ( $arg{tnode} ne "" and $rec->{tnode} ne $arg{tnode} ) {
			$rec->{tnode} = $arg{tnode};
			$change = 1;
		}

		if ( $arg{responder} ne "" and $rec->{responder} ne $arg{responder} ) {
			$rec->{responder} = $arg{responder};
			$change = 1;
		}

		if ( $arg{starttime} ne "" and $rec->{starttime} ne $arg{starttime} ) {
			$rec->{starttime} = $arg{starttime};
			$change = 1;
		}

		if ( $arg{url} ne "" and $rec->{url} ne $arg{url} ) {
			$rec->{url} = $arg{url};
			$change = 1;
		}
		
		if ( $arg{lsrpath} ne "" and $rec->{lsrpath} ne $arg{lsrpath} ) {
			$rec->{lsrpath} = $arg{lsrpath};
			$change = 1;
		}

		if ( $arg{lastupdate} ne "" and $rec->{lastupdate} ne $arg{lastupdate} ) {
			$rec->{lastupdate} = $arg{lastupdate};
			$change = 1;
		}

		if ( $arg{items} ne "" and $rec->{items} ne $arg{items} ) {
			$rec->{items} = $arg{items};
			$change = 1;
		}

  	if ( $arg{entry} and $rec->{entry} != $arg{entry} ) {
			$rec->{entry} = $arg{entry};
			$change = 1;
		}

  	if ( $arg{frequence} and $rec->{frequence} != $arg{frequence} ) {
			$rec->{frequence} = $arg{frequence};
			$change = 1;
		}

  	if ( $arg{codec} and $rec->{codec} != $arg{codec} ) {
			$rec->{codec} = $arg{codec};
			$change = 1;
		}

  	if ( $arg{timeout} and $rec->{timeout} != $arg{timeout} ) {
			$rec->{timeout} = $arg{timeout};
			$change = 1;
		}

  	if ( $arg{numpkts} and $rec->{numpkts} != $arg{numpkts} ) {
			$rec->{numpkts} = $arg{numpkts};
			$change = 1;
		}

  	if ( $arg{history} and $rec->{history} != $arg{history} ) {
			$rec->{history} = $arg{history};
			$change = 1;
		}

  	if ( $arg{tos} and $rec->{tos} != $arg{tos} ) {
			$rec->{tos} = $arg{tos};
			$change = 1;
		}

  	if ( $arg{verify} and $rec->{verify} != $arg{verify} ) {
			$rec->{verify} = $arg{verify};
			$change = 1;
		}

  	if ( $arg{tport} and $rec->{tport} != $arg{tport} ) {
			$rec->{tport} = $arg{tport};
			$change = 1;
		}

  	if ( $arg{dport} and $rec->{dport} != $arg{dport} ) {
			$rec->{dport} = $arg{dport};
			$change = 1;
		}

  	if ( $arg{reqdatasize} and $rec->{reqdatasize} != $arg{reqdatasize} ) {
			$rec->{reqdatasize} = $arg{reqdatasize};
			$change = 1;
		}

  	if ( $arg{factor} and $rec->{factor} != $arg{factor} ) {
			$rec->{factor} = $arg{factor};
			$change = 1;
		}

		#Did the node details change?
		if ( $change ) {
			if ( not defined $self->{_dbh} ) {
				$self->getHandle();
			}
	
			### 2012-04-17 keiths, removing bad characters from message
			$rec->{message} =~ s/\"/\'/g;

			# Create the statement.			
		 	my $stmt =<<EO_SQL;
UPDATE $self->{_prefix}probes
SET 
  `probe` = '$rec->{probe}',
  `entry` = '$rec->{entry}',
  `pnode` = '$rec->{pnode}',
  `status` = '$rec->{status}',
  `func` = '$rec->{func}',
  `optype` = '$rec->{optype}',
  `database` = '$rec->{database}',
  `frequence` = '$rec->{frequence}',
  `message` = "$rec->{message}",
  `select` = '$rec->{select}',
  `rnode` = '$rec->{rnode}',
  `codec` = '$rec->{codec}',
  `raddr` = '$rec->{raddr}',
  `timeout` = '$rec->{timeout}',
  `numpkts` = '$rec->{numpkts}',
  `deldb` = '$rec->{deldb}',
  `history` = '$rec->{history}',
  `saddr` = '$rec->{saddr}',
  `vrf` = '$rec->{vrf}',
  `tnode` = '$rec->{tnode}',
  `responder` = '$rec->{responder}',
  `starttime` = '$rec->{starttime}',
  `interval` = '$rec->{interval}',
  `tos` = '$rec->{tos}',
  `verify` = '$rec->{verify}',
  `tport` = '$rec->{tport}',
  `url` = '$rec->{url}',
  `dport` = '$rec->{dport}',
  `reqdatasize` = '$rec->{reqdatasize}',
  `factor` = '$rec->{factor}',
  `lsrpath` = '$rec->{lsrpath}',
  `lastupdate` = '$rec->{lastupdate}',
  `items` = '$rec->{items}'
WHERE probe = '$arg{probe}';
EO_SQL
	
			print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
			# Prepare and execute the SQL query
			my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
			$sth->execute || warn "ERROR execute $arg{probe}:\n$stmt\n$DBI::errstr";
			# Clean up the record set
			$sth->finish();
			
			#update the cache!
			$self->{_probes}{$arg{probe}} = %$rec;		
	
			#$self->{_dbh}->commit or warn "ERROR commit:\n$DBI::errstr\n";
		}
	}
}

sub updateMessage {
	my ($self,%arg) = @_;
	my $change = 0;

	print "DEBUG updateProbe probe=$arg{probe} message=$arg{message}\n" if $self->{_debug};
 
	# Auto add probes to the probe object
	if ( $self->existProbe(probe => $arg{probe}) ) {
		my $rec = $self->_queryProbes(probe => $arg{probe});

		if ( $arg{message} eq "NULL" ) {
			$rec->{message} = "";
			$change = 1;
		}
		elsif ( $arg{message} ne "" and $rec->{message} ne $arg{message} ) {
			$rec->{message} = $arg{message};
			$change = 1;
		}

		#Did the node details change?
		if ( $change ) {
			if ( not defined $self->{_dbh} ) {
				$self->getHandle();
			}
	
			### 2012-04-17 keiths, removing bad characters from message
			$rec->{message} =~ s/\"/\'/g;

			# Create the statement.			
		 	my $stmt =<<EO_SQL;
UPDATE $self->{_prefix}probes
SET 
  `message` = "$rec->{message}"
WHERE probe = '$arg{probe}';
EO_SQL
	
			print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
			# Prepare and execute the SQL query
			my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
			$sth->execute || warn "ERROR execute $arg{probe}:\n$stmt\n$DBI::errstr";
			# Clean up the record set
			$sth->finish();
			
			#update the cache!
			$self->{_probes}{$arg{probe}} = %$rec;		
	
			#$self->{_dbh}->commit or warn "ERROR commit:\n$DBI::errstr\n";
		}
	}
}

sub updateFunc {
	my ($self,%arg) = @_;
	my $change = 0;

	print "DEBUG updateProbe probe=$arg{probe} func=$arg{func}\n" if $self->{_debug};
 
	# Auto add probes to the probe object
	if ( $self->existProbe(probe => $arg{probe}) ) {
		my $rec = $self->_queryProbes(probe => $arg{probe});

		if ( $arg{func} eq "NULL" ) {
			$rec->{func} = "";
			$change = 1;
		}
		elsif ( $arg{func} ne "" and $rec->{func} ne $arg{func} ) {
			$rec->{func} = $arg{func};
			$change = 1;
		}

		#Did the node details change?
		if ( $change ) {
			if ( not defined $self->{_dbh} ) {
				$self->getHandle();
			}
	
			$rec->{func} =~ s/\"/\'/g;

			# Create the statement.			
		 	my $stmt =<<EO_SQL;
UPDATE $self->{_prefix}probes
SET 
  `func` = "$rec->{func}"
WHERE probe = '$arg{probe}';
EO_SQL
	
			print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
			# Prepare and execute the SQL query
			my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
			$sth->execute || warn "ERROR execute $arg{probe}:\n$stmt\n$DBI::errstr";
			# Clean up the record set
			$sth->finish();
			
			#update the cache!
			$self->{_probes}{$arg{probe}} = %$rec;		
	
			#$self->{_dbh}->commit or warn "ERROR commit:\n$DBI::errstr\n";
		}
	}
}

sub updateNode {
	my ($self,%arg) = @_;
	my $change = 0;

	# Auto add nodes to the node object
	if ( not $self->existNode(node => $arg{node}) ) {
		return($self->addNode(%arg));
	}
	# Process the state normally
	else {
		my $rec = $self->_queryNodes(node => $arg{node});

		if ( $arg{node} ne "" and $rec->{node} ne $arg{node} ) {
			$rec->{node} = $arg{node};
			$change = 1;
		}

		if ( $arg{entry} and $rec->{entry} != $arg{entry} ) {
			$rec->{entry} = $arg{entry};
			$change = 1;
		}

		if ( $arg{community} ne ""  and $rec->{community} ne $arg{community} ) {
			$rec->{community} = $arg{community};
			$change = 1;
		}

		#Did the node details change?
		if ( $change ) {
			if ( not defined $self->{_dbh} ) {
				$self->getHandle();
			}
	
			# Create the statement.
		 	my $stmt =<<EO_SQL;
UPDATE $self->{_prefix}ipsla_nodes
SET 
  `node` = '$rec->{node}', 
  `entry` = '$rec->{entry}', 
  `community` = '$rec->{community}'
WHERE node = '$arg{node}';
EO_SQL
	
			print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
			# Prepare and execute the SQL query
			my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
			$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
		
			# Clean up the record set
			$sth->finish();
			
			#update the cache!
			$self->{_nodes}{$arg{node}} = %$rec;		
	
			#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		}
	}
}

sub updateDnsCache {
	my ($self,%arg) = @_;
	my $change = 0;

	# Auto add nodes to the node object
	if ( not $self->existDnsCache(lookup => $arg{lookup}) ) {
		return($self->addDnsCache(%arg));
	}
	# Process the state normally
	else {
		my $rec = $self->_queryDnsCache(lookup => $arg{lookup});

		if ( $arg{lookup} ne "" and $rec->{lookup} ne $arg{lookup} ) {
			$rec->{lookup} = $arg{lookup};
			$change = 1;
		}

		if ( $arg{result} and $rec->{result} != $arg{result} ) {
			$rec->{result} = $arg{result};
			$change = 1;
		}

		#Did the node details change?
		if ( $change ) {
			$rec->{age} = time;

			if ( not defined $self->{_dbh} ) {
				$self->getHandle();
			}
	
			# Create the statement.
		 	my $stmt =<<EO_SQL;
UPDATE $self->{_prefix}dnscache
SET 
  `lookup` = '$rec->{lookup}', 
  `result` = '$rec->{result}', 
  `age` = '$rec->{age}'
WHERE lookup = '$arg{lookup}';
EO_SQL
	
			print "DEBUG: Updating: $arg{probe}; SQL:\n$stmt\n" if $self->{_debug};
			# Prepare and execute the SQL query
			my $sth = $self->{_dbh}->prepare($stmt) || die returnDateStamp()." ERROR prepare:\n$stmt\n$DBI::errstr";
			$sth->execute || warn "ERROR execute:\n$stmt\n$DBI::errstr";
		
			# Clean up the record set
			$sth->finish();
			
			#update the cache!
			$self->{_dnscache}{$arg{lookup}} = %$rec;		
	
			#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
		}
	}
}

sub getProbes {
	my ($self) = @_;
	$self->loadProbeCache();
	return(values %{$self->{_probes}});
}

sub getNodes {
	my ($self) = @_;
	$self->loadNodeCache();
	return(values %{$self->{_nodes}});
}

sub getDnsCache {
	my ($self) = @_;
	$self->loadDnsCache();
	return(values %{$self->{_dnscache}});
}

sub getProbeKeys {
	my ($self) = @_;
	$self->loadProbeCache();
	return(keys %{$self->{_probes}});
}

sub getNodeKeys {
	my ($self) = @_;
	$self->loadNodeCache();
	return(keys %{$self->{_nodes}});
}

sub getDnsKeys {
	my ($self) = @_;
	$self->loadDnsCache();
	return(keys %{$self->{_dnscache}});
}

sub getProbe {
	my ($self,%arg) = @_;
	return($self->_queryProbes(%arg));
}

sub getNode {
	my ($self,%arg) = @_;
	return($self->_queryNodes(%arg));
}

sub getDns {
	my ($self,%arg) = @_;
	return($self->_queryDnsCache(%arg));
}

sub getCommunity {
	my ($self,%arg) = @_;
	my $rec;
	if ( $self->{_nodes}{$arg{probe}}{node} ne "" ) {
		$rec = $self->{_nodes}{$arg{node}};
	}
	else {
		$rec = $self->_queryNodes(node => $arg{node});
	}
	return($rec->{community});
}

sub getEntry {
	my ($self,%arg) = @_;
	my $rec;
	if ( $self->{_nodes}{$arg{probe}}{node} ne "" ) {
		$rec = $self->{_nodes}{$arg{node}};
	}
	else {
		$rec = $self->_queryNodes(node => $arg{node});
	}
	return($rec->{entry});
}

sub getProbeStatus {
	my ($self,%arg) = @_;
	my $rec;
	if ( $self->{_probes}{$arg{probe}}{probe} ne "" ) {
		$rec = $self->{_probes}{$arg{probe}};
	}
	else {
		$rec = $self->_queryProbes(probe => $arg{probe});
	}
	return($rec->{status});
}

sub save {
	my ($self,%arg) = @_;
	return(1);
}

sub createProbeTable {
	my ($self,%arg) = @_;

	my $stmt =<<EO_SQL;
CREATE TABLE if not exists $self->{_prefix}probes (
  `probe` varchar(160),
  `entry` integer,
  `pnode` varchar(128),
  `status` varchar(24),
  `func` varchar(36),
  `optype` varchar(26),
  `database` varchar(128),
  `frequence` integer,
  `message` blob,
  `select` varchar(160),
  `rnode` varchar(128),
  `codec` integer,
  `raddr` varchar(32),
  `timeout` integer,
  `numpkts` integer,
  `deldb` varchar(8),
  `history` integer,
  `saddr` varchar(32),
  `vrf` varchar(64),
  `tnode` varchar(128),
  `responder` varchar(9),
  `starttime` varchar(64),
  `interval` integer,
  `tos` integer,
  `verify` integer,
  `tport` integer,
  `url` varchar(128),
  `dport` integer,
  `reqdatasize` integer,
  `factor` integer,
  `lsrpath` varchar(255),
  `lastupdate` integer,
  `items` blob,
   PRIMARY KEY (`probe`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='IPSLA Probes';

EO_SQL
	
	my $sth = $self->{_dbh}->do($stmt);
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub alterProbeTable {
	my ($self,%arg) = @_;

	my $stmt =<<EO_SQL;
ALTER TABLE $self->{_prefix}probes
ADD `lastupdate` integer

EO_SQL
	
	my $sth = $self->{_dbh}->do($stmt);
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub createNodeTable {
	my ($self,%arg) = @_;

	my $stmt =<<EO_SQL;
CREATE TABLE if not exists $self->{_prefix}ipsla_nodes (
  `node` varchar(128),
  `entry` integer,
  `community` varchar(64),
  PRIMARY KEY (`node`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='IPSLA Nodes';
EO_SQL
	
	my $sth  = $self->{_dbh}->do($stmt);
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub createDnsCacheTable {
	my ($self,%arg) = @_;

	my $stmt =<<EO_SQL;
CREATE TABLE if not exists $self->{_prefix}dnscache  (
  `lookup` varchar(128),
  `result` varchar(128),
  `age` integer,
  PRIMARY KEY (`lookup`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='IPSLA DNS Cache';
EO_SQL
	
	my $sth  = $self->{_dbh}->do($stmt);
	#$self->{_dbh}->commit or die returnDateStamp()." ERROR commit:\n$DBI::errstr\n";
}

sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year $hour:$min:$sec";
}

1;
