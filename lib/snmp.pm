#
## $Id: snmp.pm,v 8.8 2012/08/27 21:59:11 keiths Exp $
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

package snmp;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = "1.0.1";

@ISA = qw(Exporter);

@EXPORT = qw(keys2name);

use strict;
use lib "../../lib";

# Import external NMIS 
use Net::SNMP qw(oid_lex_sort);
use Net::DNS;
use Mib;
use func;

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	my $self = {
		host => undef,
		session => undef,
		version => undef,
		vars => undef,
		oidpkt => undef,
		name => '',
		error => "",
		logging => 1,
		log_regex => "",
		debug => 0
	};
	bless $self, $class;
	return $self;
}

sub init {
	my $self = shift;
	my %args = @_;
	$self->{debug} = $args{debug} || 0 ;
	$self->{logging} = $args{logging} || 1;

	return 1;
}

sub open {
	my $self = shift;
	my %args = @_;
	my $session;
	my $error;

	$self->{error} = "";

	my $host = $args{host} || $self->{host} || 'localhost';
	$self->{host} = $host;
	my $domain = $args{udp} || 'udp';
	my $version = $args{version} || 'snmpv2c';
	my $community = $args{community} || 'public';
	my $username = $args{username};
	my $authpassword = $args{authpassword};
	my $authkey = $args{authkey};
	my $authprotocol = $args{authprotocol} || 'md5';
	my $privpassword = $args{privpassword};
	my $privkey = $args{privkey};
	my $privprotocol = $args{privprotocol} || 'des';
	my $port = $args{port} || 161;
	my $timeout = $args{timeout} || 5;
	my $retries = $args{retries} || 1;
	my $max_msg_size = $args{max_msg_size} || 1472;
	$self->{oidpkt} = $args{oidpkt} || 10;

	my @authopts = ();
	if ($version eq 'snmpv1' or $version eq 'snmpv2c') {
		push(@authopts,
			-community	=> $community,
		);
	}
	elsif ($version eq 'snmpv3') {
		push(@authopts,
			-username	=> $username,
			-authprotocol	=> $authprotocol,
			-privprotocol	=> $privprotocol,
		);
		if (defined($authkey) and length($authkey)) {
			push(@authopts, -authkey => $authkey);
		}
		elsif (defined($authpassword) and length($authpassword)) {
			push(@authopts, -authpassword => $authpassword);
		}
		if (defined($privkey) and length($privkey)) {
			push(@authopts, -privkey => $privkey);
		}
		elsif (defined($privpassword) and length($privpassword)) {
			push(@authopts, -privpassword => $privpassword);
		}
	}

	# open SNMP channel
	dbg("version $version, domain $domain, host $host, community $community, port $port",3);
	($session, $error) = Net::SNMP->session(
			-domain		=> $domain,
			-version	=> $version,
			-hostname	=> $host,
			-timeout	=> $timeout,
			-retries	=> $retries,
			-translate   => [-timeticks => 0x0,		# Turn off so sysUpTime is numeric
			-unsigned => 0x1,		# unsigned integers
			-octet_string => 0x1],   # Lets octal string
			-port		=> $port,
			-maxmsgsize => $max_msg_size,
			@authopts,
		);

	if (!defined($session)) {
		$self->{error} = $error;
		my $msg = "ERROR $self->{host} ".$error;
		logMsg($msg) if $self->{logging};
		dbg($msg,3);
		return undef;
	}

	$self->{session} = $session;
	$self->{version} = $version;
	$self->{max_msg_size} = $session->max_msg_size; # get and remember the actual limit

	return 1;
}

sub get {
	my($self, @vars) = @_;
	my $var;
	my @oid;
	my $oid;

	$self->{vars} = \@vars;

	for my $var (@vars) {
		if ($var !~ /^(\.?\d+)+$/ ) {
			### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
			if ( not scalar(($oid) = $self->nameTOoid(1,$var)) ) {
				return undef; 
			}
			push @oid,$oid;
		} else {
			push @oid,$var;
		}
	}


	my $result = $self->{session}->get_request( -varbindlist => \@oid );
	### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
	if ( not $self->checkResult($result) ) {
		return undef; 
	}

	if ($self->{debug}) {
		for my $oid (oid_lex_sort(keys(%{$result}))) {
			my $name = oid2name($oid);
			dbg("result: $name($oid) = $result->{$oid}",3);
		}
	}

	return $result; # return pointer of hash
}

sub getscalar {
	my($self, @vars) = @_;
	my @result;
	@result = $self->getarray($vars[0]);
	return $result[0];
}

sub getarray {
	my($self, @vars) = @_;
	my($var, @retvals);
	my @oid;
	my $oid;
	@retvals = ();

	$self->{vars} = \@vars;

	for my $var (@vars) {
		if ($var !~ /^(\.?\d+)+$/ ) {
			### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
			if ( not scalar(($oid) = $self->nameTOoid(1,$var)) ) {
				return undef; 
			}
			push @oid,$oid;
		} else {
			push @oid,$var;
		}
	}
	
	# 2011-09-12: Mark D. Nagel update to split large SNMP requests over several packets 
	while (@oid) {
		my @oidchunk = splice(@oid, 0, $self->{oidpkt});
		my $result = $self->{session}->get_request( -varbindlist => \@oidchunk );
		if ( $self->checkResult($result) ) {
			foreach $oid (@oidchunk) {
				push @retvals, $result->{$oid};
				$var = oid2name($oid);
				dbg("result: var=$var, value=$result->{$oid}",4);
			}
		}
		### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
		else {
			return undef;
		}
	}
	
	return @retvals;
}

# argument max repetitions: if given and numeric, controls how many 
# ID/PDUs will be in a single request
sub gettable {
	my $self = shift;
	my @vars = shift;
	my $maxrepetitions = shift;		
	my $oid;
	my $msg;
	my $result;

	$self->{vars} = \@vars;
	

	#print ("DEBUG: maxrepetitions=$maxrepetitions\n");
	
	if ($vars[0] !~ /^(\.?\d+)+$/ ) {
		### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
		if ( not scalar(($oid) = $self->nameTOoid(0,@vars)) ) {
			return undef;
		}
	} else {
		$oid = $vars[0];
	}

	# get it
	if ( $maxrepetitions ) {
		$result = $self->{session}->get_table( -baseoid => $oid, -maxrepetitions => $maxrepetitions );
	}
	else {
		$result = $self->{session}->get_table( -baseoid => $oid );
	}
	### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
	if ( not $self->checkResult($result) ) {
		return undef; 
	}

	my $cnt = scalar keys %{$result};
	dbg("result: $cnt values for table @vars",3);
	return $result;
}

# get hash with key containing only indexes of oid
# returns undef in case of error
sub getindex {
	my $self = shift;
	my @vars = shift;
	my $maxrepetitions = shift;		

	my $oid;
	my $msg;
	my $result;
	my $result2;

	$self->{vars} = \@vars;

	return undef if (!defined $self->{session});
	
	### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
	if ( not scalar(($oid) = $self->nameTOoid(0,@vars)) ) {
		return undef; 
	}

	# get it
	if ( $maxrepetitions ) {
		$result = $self->{session}->get_table( -baseoid => $oid, -maxrepetitions => $maxrepetitions );
	}
	else {
		$result = $self->{session}->get_table( -baseoid => $oid );	
	}
	### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
	if ( not $self->checkResult($result) ) {
		return undef; 
	}

	my ($key,$value);
	while(($key,$value) = each(%{$result})) {
		$key =~ s/$oid.//i ;
		$result2->{$key} = $value;
	}
	my $cnt = scalar keys %{$result2};
	dbg("result: $cnt values for table @vars",3);
	return $result2;
}

sub set {
	my($self, @varlist) = @_;
    my $var;
	my @oidlist;
	my $result;

	$self->{vars} = \@varlist;

	for (my $i=0;$i<scalar(@varlist);$i+=3) {
		my $oid = name2oid($varlist[$i+0]);
		if (defined($oid)) {
			push @oidlist, $oid;
			push @oidlist, $varlist[$i+1];
			push @oidlist, $varlist[$i+2];
		} else {
			$self->{error} = "Mib name $var does not exists";
			my $msg = "ERROR $self->{host} $self->{error}";
			logMsg($msg) if $self->{logging};
			dbg($msg,3);
		}
	}
	if ( not scalar(@oidlist) ) {
		return undef;	
	}

	$result = $self->{session}->set_request( -varbindlist => \@oidlist );
	### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
	if ( not $self->checkResult($result) ) {
		return undef; 
	}
	return $result;
}

sub error {
	my $self = shift;
	return $self->{error};
}

sub keys2name {
	my $self = shift;
	my $hash = shift;
	my $name;
	my $result;
	for my $oid (keys %{$hash}) {
		if (defined($name = oid2name($oid))) { 
			$result->{$name} = $hash->{$oid};
		} else {
			$result->{$oid} = $hash->{$oid};
		}
	}
	if ($self->{debug}) {
		for my $k (keys %{$result}) {
			dbg("result: $k = $result->{$k}",3);
		}
	}
	return $result;
}

sub nameTOoid {
	my ($self, $zero, @vars) =  @_;
	my @oid;
	my $oid;

    foreach my $var (@vars) {
		$var =~ /^(\w+)(.*)$/;
		$oid = name2oid($1).$2;
		$oid = name2oid($var);

		if (defined($oid)) {
			if ($zero) { $oid .= ".0" if $var !~ /\./; }
			push @oid, $oid;
		} else {
			$self->{error} = "Mib name $var does not exists";
			my $msg = "ERROR ($self->{host}) $self->{error}";
			logMsg($msg) if $self->{logging};
			dbg($msg,3);
		}
	}
	if (!@oid) {
		$self->{error} = "No Mib value left or empty";
		my $msg = "ERROR ($self->{host}) $self->{error}";
		logMsg($msg) if $self->{logging};
		dbg($msg,3);
		return 0;
	}
	return @oid;
}

sub logFilterOut {
	my ($self, $filter) = @_;

	$self->{log_regex} = $filter;
}

sub checkResult {
	my ($self, $result) = @_;

	$self->{error} = $self->{session}->error;

	if (!defined($result)) {
		my $vars = "@{$self->{vars}}";
		$vars = (length($vars) > 40) ? substr($vars,0,40)."..." : $vars; # maxlength
		my $msg = "($self->{name}) ($vars) ".$self->{session}->error;

		# dont repeat timeout error msg
		if ($self->{log_regex} eq "" or $self->{session}->error !~ /$self->{log_regex}/i ) {
			logMsg("SNMP ERROR $msg") if ($self->{session}->error !~ /is empty/) and $self->{logging};
			#logMsg("SNMP ERROR $msg");
		}
		dbg($msg,3);

		return 0;
	}
	$self->{log_regex} = "";
	return 1;
}

sub close {
	my $self = shift;

	$self->{session}->close if $self->{session}; # close session

}

1;

