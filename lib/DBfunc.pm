#
## $Id: DBfunc.pm,v 8.2 2011/08/28 15:11:05 nmisdev Exp $
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
#
package DBfunc;

use strict;
use DBI;
use func;

use vars qw($errstr);

#==============================================================================

# create object
#
# db, host, user, password, logging and debug als settable by NMIS config.
#
sub new {
	my $this = shift;
	my $class = ref($this) || $this;

	my $C = loadConfTable();

	my $self = {
		dbh => undef,		# db handle
		db => $C->{db_name} ne "" ? $C->{db_name} : 'nmis',			# name of db
		host => $C->{db_host} ne "" ? $C->{db_host} : 'localhost',	# host
		user => $C->{db_user} ne "" ? $C->{db_user} : 'nmis',		# user
		password => $C->{db_password} ne "" ? $C->{db_password} : 'nmis',
		logging => $C->{db_logging} ne "" ? $C->{db_logging} : 1,
		debug => $C->{db_debug} ne "" ? $C->{db_debug} : 0,
		error => ""
	};

	bless $self, $class;

	return $self;
}

#=========================================

# connect to database
#
# db, host, user, password and debug are settable by arguments
#
# status of connect returned.
#
sub connect {
	my $self = shift;
	my %args = @_;
	$self->{db} = $args{db} if $args{db};		# all predefined
	$self->{host} = $args{host} if $args{host};
	$self->{user} = $args{user} if $args{user};
	$self->{password} = $args{password} if $args{password};
	$self->{debug} = $args{debug} if $args{debug};

	if (!($self->{dbh} = DBI->connect("DBI:mysql:database=$self->{db};host=$self->{host}", 
			"$self->{user}", "$self->{password}", { PrintError => 0, RaiseError => 0, AutoCommit => 1}))) {
		$self->check();
		return undef;
	}
	return 1;
}

#=========================================

# disconnect DB - expect handle
sub disconnect{
	my $self = shift;

	if ( ! $self->{dbh} ) {
		$self->check("ERROR no valid DB handle" );
	} else {
		$self->{dbh}->disconnect;
	}
}

#=========================================
#
# select from table
#
# return of hash table of selected rows
# if no argument where clause is specified then whole table is returned.
# if no argument key is specified then column index for hash key is used.
# if argument index is specified then column index is used in where clause.
#
sub select{
	my $self = shift;

	# check for object, if not create one
	if ( $self !~ /HASH/ ) {
		my $db = DBfunc::->new();
		$db->connect();
		return undef if not $db->check();
		my $hsh = $db->select(@_);
		$db->disconnect();
		return $hsh;
	}

	my %args = @_;
	my $fields = $args{fields} ne "" ? $args{fields} : "*";
	my $table = $args{table};
	my $where = $args{where} ne "" ? "where $args{where}" : "";
	$where = $args{index} ne "" ? "where \`index\`=\'$args{index}\'" : $where;
	my $key = $args{key} ne "" ? $args{key} : "index"; 	# column values is key of returned hash
	my $href;				# hash result

	if ($table eq "" ) {
		return $self->check("ERROR missing name of table");
	}

	my $stmt = "Select $fields from $table $where";

	if ($self->{debug}) {
		logMsg("INFO $stmt");
	}

	$href = $self->{dbh}->selectall_hashref("$stmt","$key");
	if ( $self->check()) {
		# ok
		return $href;
	}

	return undef; # failed
}

#=========================================

# insert hash row into table
#
sub insert{
	my $self = shift;

	# check for object, if not create
	if ( $self !~ /HASH/ ) {
		my $db = DBfunc::->new();
		$db->connect();
		return undef if not $db->check();
		my $hsh = $db->insert(@_);
		$db->disconnect();
		return $hsh;
	}

	my %args = @_;
	my $data = $args{data}; # hash ref
	my $table = $args{table}; # table name

	if ($table eq "" ) {
		return $self->check("ERROR missing name of table");
	}

	my $ph = join(',',("?") x scalar(keys %{$data}));

	my $columns = join(',',map{ "\`$_\`" } (keys %{$data}));

	my $stmt = sprintf("insert into $table ($columns) values ($ph)");

	if ($self->{debug}) {
		logMsg("INFO $stmt");
	}

	$self->{dbh}->do($stmt,undef, values %{$data});

	return $self->check();

}
#=========================================
#
# delete row of table
#
# delete row(s) based on argument where OR argument index
# if argument index is specified then column index is used.
#
#
sub delete{
	my $self = shift;

	# check for object, if not create one
	if ( $self !~ /HASH/ ) {
		my $db = DBfunc::->new();
		$db->connect();
		return undef if not $db->check();
		my $hsh = $db->delete(@_);
		$db->disconnect();
		return $hsh;
	}

	my %args = @_;
	my $table = $args{table}; # table name
	my $where = $args{where}; # where clause
	# OR index for column index
	$where = $args{index} ne "" ? "\`index\`=\'$args{index}\'" : $where ;

	if ($table eq "" ) {
		return $self->check("ERROR missing name of table");
	}

	my $stmt;
	if ($where eq '*') {
		$stmt = sprintf("delete from $table");
	} else {
		if ($where eq "") {
			return $self->check("ERROR missing argument where or index");
		}
		$stmt = sprintf("delete from $table where $where");
	}

	if ($self->{debug}) {
		logMsg("INFO $stmt");
	}

	$self->{dbh}->do($stmt);

	return $self->check();

}
#=========================================

# update row of table
#
# update row(s) based on argument where OR argument index
# if argument index is specified then column index is used.
# row is specified in hash
#
sub update{
	my $self = shift;

	# check for object, if not create one
	if ( $self !~ /HASH/ ) {
		my $db = DBfunc::->new();
		$db->connect();
		return undef if not $db->check();
		my $hsh = $db->update(@_);
		$db->disconnect();
		return $hsh;
	}

	my %args = @_;
	my $data = $args{data}; # hash ref
	my $table = $args{table}; # table name
	my $where = $args{where}; # where clause
	# OR index for column index
	$where = $args{index} ne "" ? "\`index\`=\'$args{index}\'" : $where ;

	if ($table eq "" ) {
		return $self->check("ERROR missing name of table");
	}

	if ($where eq "") {
		return $self->check("ERROR missing argument where or index");
	}

	my $values = join(',', map { "\`${_}\`=?" } keys %{$data});

	my $stmt = sprintf("update $table set $values where $where");

	if ($self->{debug}) {
		logMsg("INFO $stmt");
	}

	$self->{dbh}->do($stmt,undef, values %{$data});

	return $self->check();

}
#=========================================

sub check{
	my $self = shift;
	my $msg = shift;

	# error message included
	if ($msg ne "") {
		logMsg($msg) if $self->{logging};
		$errstr = $self->{error} = $msg;
		return undef;
	}

	# check DBI for error
	if ($DBI::err) {
		logMsg("ERROR on DB ".$DBI::err.", ".$DBI::errstr) if $self->{logging};
		$errstr = $self->{error} = $DBI::errstr;
		return undef;
	} else {
		$errstr = $self->{error} = "";
	}
	return 1;
}

#=========================================
#
# call DBfunc::->error() for error info
#
sub error {

	return $errstr;
}
#=========================================

1;

__END__

