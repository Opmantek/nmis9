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
our $VERSION = "1.1.0";

use strict;
use lib "../../lib";

use Net::SNMP qw(oid_lex_sort);
# ATTENTION: to support snmp v3 we must have Crypt::DES, Digest::MD5, Digest::HMAC
# for now the installer tries to ensure their presence,
# but we don't strictly enforce that via a use here.

use Mib;
use func;												# for dbg, logMsg, getbool

# creates new snmp object, does NOT open connection.
# args: logging (optional, default 1), debug (optional, default 0),
# log_regex (optional, should be qr//, default unset, ignored if logging is off),
# name (optional, for reporting)
sub new
{
	my ($class, %arg) = @_;

	my $self = bless(
		{
			# state vars
			session => undef,
			error => undef,
			name => $arg{name},
			actual_version => undef,
			actual_max_msg_size => undef,

			# config vars, set and used by open
			config => {},

			# optionals
			debug => defined($arg{debug})? getbool($arg{debug}) : 0,
			logging => defined($arg{logging})? getbool($arg{logging}): 1,
			log_regex => undef,
		}, $class);

	return $self;
}

# sets/gets the current log_regex filter
# args: filter (should be qr or undef)
# returns: previous filter
sub logFilterOut
{
	my ($self, $filter) = @_;

	my $oldfilter = $self->{log_regex};
	$self->{log_regex} = $filter;
	return $oldfilter;
}

# sets/gets the current host name
# args: new host name (only for reporting, does NOT affect actual session!)
# returns: (new) host name
sub name
{
	my ($self, $newname) = @_;

	$self->{name} = $newname if (defined $newname);

	return $self->{name};
}

# returns last error, or undef if none
sub error
{
	my $self = shift;
	return $self->{error};
}

# returns actual snmp versions chosen for an open connection,
# or undef if none open/unsuccessful etc.
sub version
{
	my ($self) = @_;
	return $self->{session}? $self->{actual_version} : undef;
}

# returns actual chosen max message size for an open connection
# or undef if none open
sub max_msg_size
{
	my ($self) = @_;
	return $self->{session}? $self->{actual_max_msg_size} : undef;
}

# just returns the state of the session
# args: none
# returns: 1 if session is open, 0 otherwise
sub isopen
{
	my ($self) = @_;

	return ($self->{session}? 1 : 0);
}

# helper to translate from name (plus numeric tail) to numeric oid
# args: amend-with-zero (only active if name has no numeric tail), one name
# returns: undef if failed to translate (also sets error), numeric oid otherwise
sub name_to_oid
{
	my ($self, $zero, $name) =  @_;
	my $oid;

	if ($name =~ /^(\w+)(.*)$/)
	{
		$oid = name2oid($1).$2;			# from mib.pm
	}
	else
	{
		$oid = name2oid($name);
	}

	if (defined($oid))
	{
		$oid .= ".0" if ($zero && $name !~ /\./);
		return $oid;
	}
	else
	{
		$self->{error} = "Mib name $name does not exist!";
		my $msg = "ERROR ($self->{name}) $self->{error}";
		logMsg($msg) if $self->{logging};
		dbg($msg,3);
		return undef;
	}
}


# translate keys in hashref from oid to name (where possible)
# args: hash(ref)
# returns: new hash(ref)
# note: self is only required for debug output...
sub keys2name
{
	my ($self, $hash) = @_;

	my %rewritten;
	for my $oid (keys %{$hash})
	{
		my $name = oid2name($oid) || $oid;
		$rewritten{$name} = $hash->{$oid};
	}

	if ($self->{debug})
	{
		for my $k (keys %rewritten)
		{
			dbg("result: $k = $rewritten{$k}", 3);
		}
	}
	return \%rewritten;
}


# takes result of net::snmp op, xfer error state, debug-logs the result
# args: result, inputs (array ref)
# returns 1 if the result existed, 0 otherwise
sub checkResult
{
	my ($self, $result, $inputs) = @_;
	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot check result!";
		return undef;
	}

	$self->{error} = $self->{session}->error;
	return 1 if (defined $result);

	my $list = join(", ", @{$inputs});
	$list = (substr($list,0,40)."...") if (length($list) > 40);

	my $msg = "($self->{name}) ($list) ".$self->{error};

	# dont repeat timeout error msg
	if ($self->{logging} and $self->{error} !~ /is empty/
			and (!$self->{log_regex} or $self->{error} !~ $self->{log_regex}))
	{
		logMsg("SNMP ERROR $msg")
	}
	dbg($msg,3);

	return undef;
}



# opens an actual session
# args: EITHER config (=hash with ALL the required args), OR individual arguments
# returns: 1 if successful
sub open
{
	my ($self, %args) = @_;
	undef $self->{error};
	$self->{session}->close if ($self->{session});

	my $cobj = (ref($args{config}) eq "HASH" && keys %{$args{config}})? $args{config} : {};

	$self->{config} = {
		# host heuristics: (more-or-less undocumented) host_addr wins,
		#then host or name (all checked in confobj and args)
		host => ( $cobj->{host_addr} || $args{host_addr}
							|| $cobj->{host} || $args{host}
							|| $cobj->{name} || $args{name} || 'localhost'),
		domain => $cobj->{udp} || $args{udp} || 'udp',
		port => $cobj->{port} || $args{port} || 161,
		timeout => $cobj->{timeout} || $args{timeout} || 5,
		retries => $cobj->{retries} || $args{retries} || 1,

		max_msg_size => $cobj->{max_msg_size} || $args{max_msg_size} || 1472,
		oidpkt => $cobj->{oidpkt} || $args{oidpkt} || 10, # for gettable
		max_repetitions => $cobj->{max_repetitions} || $args{max_repetitions} || undef, # for the bulk functions

		version => $cobj->{version} || $args{version} || 'snmpv2c',
		community => $cobj->{community} || $args{community} || 'public',
		context => $cobj->{context} || $args{context},
		username => $cobj->{username} || $args{username},
		authpassword => $cobj->{authpassword} || $args{authpassword},
		authkey => $cobj->{authkey} || $args{authkey},
		authprotocol => $cobj->{authprotocol} || $args{authprotocol} || 'md5',
		privpassword => $cobj->{privpassword} || $args{privpassword},
		privkey => $cobj->{privkey} || $args{privkey},
		privprotocol => $cobj->{privprotocol} || $args{privprotocol} || 'des',
	};

	my @authopts = ();
	if ($self->{config}->{version} =~ /^snmpv(1|2c)$/)
	{
		push(@authopts, "-community"	=> $self->{config}->{community}, );
	}
	elsif ($self->{config}->{version} eq 'snmpv3')
	{
		push(@authopts,
				 "-username"	=> $self->{config}->{username},
				 "-authprotocol"	=> $self->{config}->{authprotocol},
				 "-privprotocol"	=> $self->{config}->{privprotocol}, );

		if ($self->{config}->{authkey})
		{
			push(@authopts, "-authkey" => $self->{config}->{authkey} );
		}
		elsif ($self->{config}->{authpassword})
		{
				push(@authopts, "-authpassword" => $self->{config}->{authpassword});
		}

		if ($self->{config}->{privkey})
		{
			push(@authopts, "-privkey" => $self->{config}->{privkey});
		}
		elsif ($self->{config}->{privpassword})
		{
			push(@authopts, "-privpassword" => $self->{config}->{privpassword});
		}
	}

	# now actually open the SNMP session
	dbg("opening session - version $self->{config}->{version}, domain $self->{config}->{domain}, host $self->{config}->{host}, port $self->{config}->{port}, community $self->{config}->{community}, context $self->{config}->{context}", 3);

	($self->{session}, $self->{error}) =
			Net::SNMP->session(
				-domain		=> $self->{config}->{domain},
				-version	=> $self->{config}->{version},
				-hostname	=> $self->{config}->{host},
				-timeout	=> $self->{config}->{timeout},
				-retries	=> $self->{config}->{retries},
				-translate   => [-timeticks => 0x0,		# Turn off so sysUpTime is numeric
												 -unsigned => 0x1,		# unsigned integers
												 -octet_string => 0x1],   # Lets octal string
				-port		=> $self->{config}->{port},
				-maxmsgsize => $self->{config}->{max_msg_size},
				@authopts,
			);

	if (!$self->{session})
	{
		my $msg = "ERROR $self->{name} $self->{error}";
		logMsg($msg) if $self->{logging};
		dbg($msg, 3);

		return undef;
	}

	$self->{actual_version} = $self->{session}->version;
	$self->{actual_max_msg_size} = $self->{session}->max_msg_size;

	return 1;
}

# closes an open session
# args: none
# returns: nothing
sub close
{
	my ($self) = @_;

	$self->{session}->close if $self->{session};
	undef $self->{session};
	undef $self->{errors};

	return undef;
}

# retrieves X variables with a get request, returns hashref
# requires session to be open
# args: array of oids to retrieve (name or numeric),
# returns: undef if error (sets internal error text), or hashref of (dotted oid => value)
sub get
{
	my($self, @vars) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform get!";
		return undef;
	}

	# verify syntax, numeric or known name
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
				return undef;						# error was set by name_to_oid
			}
		}
	}

	my @methodargs = ( "-varbindlist" => \@certainlyoids );
	push @methodargs, ("-contextname" => $self->{config}->{context})
			if ($self->{config}->{context});

			my $result = $self->{session}->get_request(@methodargs);
	return undef if (!$self->checkResult($result, \@vars));

	if ($self->{debug})
	{
		for my $oid (oid_lex_sort(keys(%{$result})))
		{
			my $name = oid2name($oid);
			dbg("result: $name($oid) = $result->{$oid}", 3);
		}
	}
	return $result;
}

# tiny wrapper around get, tries to get a known standard oid
# args: none
# returns: 1 if successful, undef otherwise (and sets error)
sub testsession
{
	my ($self) = @_;

	my $oid = "1.3.6.1.2.1.1.2.0";
	my $result = $self->get($oid);
	return ref($result) eq "HASH" && $result->{$oid};
}

# retrieves X variables with one or more get requests, returns array
# requires session to be open.
# requests are chunked in oidpkt oids per request
#
# args: array of oids to retrieve (name or numeric),
#
# returns: undef if error (sets internal error text),
# or array of return values (same order as inputs)
sub getarray
{
	my($self, @vars) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform getarray!";
		return undef;
	}

	# verify syntax, numeric or known name
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
				return undef;						# error was set by name_to_oid
			}
		}
	}

	my @retvals;
	while (@certainlyoids)
	{
		my @oidchunk = splice(@certainlyoids, 0, $self->{config}->{oidpkt});
		my @varchunk = splice(@vars, 0, $self->{config}->{oidpkt}); # for error reporting

		my @methodargs = ( "-varbindlist" => \@oidchunk );
		push @methodargs, ("-contextname" => $self->{config}->{context})
				if ($self->{config}->{context});

		my $result = $self->{session}->get_request(@methodargs);
		return undef if (!$self->checkResult($result, \@varchunk));

		for my $oid (@oidchunk)
		{
			push @retvals, $result->{$oid};

			if ($self->{debug} && &func::getDebug >= 4)	# don't waste time translating if not debugging
			{
				my $var = oid2name($oid);
				dbg("result: var=$var, value=$result->{$oid}",4);
			}
		}
	}
	return @retvals;
}


# retrieves one table with a get_table request, returns hashref
# requires session to be open.
#
# args: oid to retrieve (name or numeric), maxrepetitions (optional, overrides config
# if given. if numeric, controls how many ID/PDUs will be in a single request),
# rewritekeys (optional, default no; if given only the index part of the oid is kept)
#
# returns: undef if error (sets internal error text),
# or hashref of results (oid => value).
sub gettable
{
	my ($self, $name, $maxrepetitions, $rewritekeys) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform gettable!";
		return undef;
	}

	# translate to numeric oid
	if ($name !~ /^(\.?\d+)+$/ )
	{
		if (my $oid = $self->name_to_oid(0, $name))
		{
			$name = $oid;
		}
		else
		{
			return undef;
		}
	}

	# fall back to config'd value
	$maxrepetitions = $self->{config}->{max_repetitions}
	if (!defined $maxrepetitions);

	# repeat the op, but try backing off and smaller maxrepetitions
	# if we run into message size exceeded issues
	my $triesleft = 5;
	while ($triesleft)
	{
		my @methodargs = ( "-baseoid" => $name );
		push @methodargs, ("-contextname" => $self->{config}->{context})
				if ($self->{config}->{context});
		push @methodargs, ("-maxrepetitions" => $maxrepetitions)
				if ($maxrepetitions);

		my $result = $self->{session}->get_table(@methodargs);
		my $errormsg = $self->{session}->error;
		--$triesleft;
		if ($triesleft && $errormsg && $errormsg =~ /message size exceeded/i)
		{
			# if the net::snmp guesswork with maxrepetitions 0 didn't pan out, try 20;
			# if we had a value, reduce it by 25%.
			$maxrepetitions = $maxrepetitions? int($maxrepetitions * 0.75) : 20;

			# and make sure this persists across the session lifetime
			$self->{config}->{max_repetitions} = $maxrepetitions;
			dbg("get_table failed with message size exceeded, retrying with maxrepetitions reduced to $maxrepetitions");
			logMsg("WARNING ($self->{name}) SNMP message size exceeded, retrying with maxrepetitions reduced to $maxrepetitions");
			next;
		}
		return undef if (!$self->checkResult($result, [$name]));

		my $cnt = scalar keys %{$result};
		dbg("result: $cnt values for table $name",3);

		if (getbool($rewritekeys))
		{
			my @todo = keys %{$result};
			for my $fullkey (@todo)
			{
				my $newkey = $fullkey;
				$newkey =~ s/^$name.//;

				$result->{$newkey} = $result->{$fullkey};
				delete $result->{$fullkey};
			}
		}

		return $result;
	}
	return undef;									# ran out of tries
}

# get array, but rewrite keys so that they contain only index part below table oid
# simple wrapper around gettable
# returns undef in case of error, hashref if ok
sub getindex
{
	my ($self, $name, $maxrepetitions) = @_;
	return $self->gettable($name,$maxrepetitions,1);
}



# perform set operation with X variables
# args: hash ref of oids to set, each key is numeric or name of oid, each
# value must be array ref of (object type, new value)
# returns: undef if error, result hash (ref) otherwise
sub set
{
	my($self, $setthese) = @_;

	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot perform set!";
		return undef;
	}

	if (ref($setthese) ne "HASH" or !keys %$setthese)
	{
		$self->{error} = "Invalid input, nothing to set.";
		return undef;
	}

	my @uglylist;
	for my $k (keys %$setthese)
	{
		if (ref($setthese->{$k} ne "ARRAY" or @{$setthese->{$k}} != 2))
		{
			$self->{error} = "Invalid input, cannot set \"$k\"";
			return undef;
		}

		my $oid = ($k =~ /^(\.?\d+)+$/)? $k : $self->name_to_oid(0, $k);
		return undef if (!$oid);

		push @uglylist, $oid, @{$setthese->{$k}};

	}

	my @methodargs = ( "-varbindlist" => \@uglylist );
	push @methodargs, ("-contextname" => $self->{config}->{context})
			if ($self->{config}->{context});

	my $result = $self->{session}->set_request( @uglylist );

	return undef if (!$self->checkResult($result, [keys %$setthese]));
	return $result;
}

1;
