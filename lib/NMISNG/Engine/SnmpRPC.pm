#
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
package NMISNG::Engine::SnmpRPC;
our $VERSION = "2.0.0";

use strict;

use NMISNG::MIB;
use NMISNG::RPC;

use Data::Dumper;
use MIME::Base64;
use Net::SNMP qw(oid_lex_sort);


# creates new snmp object, does NOT open connection.
# args: nmisng (required),
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

			# internal linkage
			_nmisng => $arg{nmisng},
		},
		$class);

	Carp::confess("NMISNG object required to create Snmp object!")
			if (ref($self->{_nmisng}) ne "NMISNG");

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

# r/o accessor
sub nmisng
{
	return shift->{_nmisng};
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


# takes result of net::snmp op, xfer error state, debug-logs the result
# args: result, inputs (array ref)
# returns 1 if the result existed, 0 otherwise
sub checkResult
{
	my ($self, $result, $inputs) = @_;
	if (!$self->{session})
	{
		$self->{error} = "No session open, cannot check result!";
		$self->nmisng->log->error("No session open, cannot check result!");
		return undef;
	}

	return 1 if (defined $result);

	my $list = join(", ", @{$inputs});
	$list = (substr($list,0,40)."...") if (length($list) > 40);

	# tag as error but log if debug level 1 or above
	$self->nmisng->log->error("SNMP ERROR ($self->{name}) ($list) ".$self->{error})
			if ($self->nmisng->log->is_level(1));
	return undef;
}



# opens an actual session
# args: EITHER config (=hash with ALL the required args), OR individual arguments
# providing both does NOT work; config arg wins.
# returns: 1 if successful
sub open
{
	my ($self, %args) = @_;
	undef $self->{error};

	my $cobj = (ref($args{config}) eq "HASH"
							&& keys %{$args{config}})? $args{config} : {};


	my $ip_protocol = $cobj->{ip_protocol} || $args{ip_protocol} || 'IPv4';
	my $domain = $ip_protocol eq "IPv6" ? "udp6" : "udp";

	$self->{config} = {
		# host heuristics: (more-or-less undocumented) host_addr wins,
		#then host or name (all checked in confobj and args)
		host => ( $cobj->{host_addr} || $args{host_addr}
							|| $cobj->{host} || $args{host}
							|| $cobj->{name} || $args{name} || 'localhost'),
		domain => $domain,
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

	#We dont have a session open yet... basically this is just saying we have config
	$self->{session} = 1;

	return 1;
}

# closes an open session
# args: none
# returns: nothing
sub close
{
	my ($self) = @_;

	my $result = $self->make_rpc_request('Close',[]);
	undef $self->{session};
	undef $self->{errors};
	undef $self->{sessionid};
	undef $self->{client};

	return undef;
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
		$oid = NMISNG::MIB::name2oid($self->nmisng, $1).$2;
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
		$self->nmisng->log->error("($self->{name}) $self->{error}");
		return undef;
	}
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
		$self->nmisng->log->error("No session open, cannot perform get!");
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
				$self->nmisng->log->error("Incorrect syntax. Returning undef");
				return undef;						# error was set by name_to_oid
			}
		}
	}

	my $result = $self->make_rpc_request('Get',\@certainlyoids);
	return undef if (!$self->checkResult($result, \@vars));

	$self->nmisng->log->debug4(sub {&NMISNG::Log::trace()
														 . "result: "
														 . join(" ",
																		map { NMISNG::MIB::oid2name($self->nmisng, $_)
																							."($_) = $result->{$_} " } (oid_lex_sort(keys %{$result}))) });			
	return $result;
}

# tiny wrapper around get, tries to get a known standard oid
# args: none
# returns: 1 if successful, undef otherwise (and sets error)
sub testsession
{
	my ($self) = @_;

	my $oid = "1.3.6.1.2.1.1.2.0"; # SNMPv2-MIB::sysObjectID.0
	my $result = $self->get($oid);
	return (ref($result) eq "HASH" && $result->{$oid})? 1 : 0;
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
	my ($self, @vars) = @_;

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


		my $result = $self->make_rpc_request('Get',\@oidchunk);

		return undef if (!$self->checkResult($result, \@varchunk));

		for my $oid (@oidchunk)
		{
			push @retvals, $result->{$oid};

			# don't waste time translating if not debugging
			$self->nmisng->log->debug4(sub {&NMISNG::Log::trace()
																 . "result: var=" . NMISNG::MIB::oid2name($self->nmisng, $oid)
																 .", value=$result->{$oid}"});
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
		$self->nmisng->log->error("No session open, cannot perform gettable!");
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
			$self->nmisng->log->error("Incorrect syntax");
			$self->{error} = "Incorrect mib name, incorrect syntax, could not translate name:$name to oid";
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
		my @methodargs;
		push @methodargs, $name;
		my $result = $self->make_rpc_request('Walk',\@methodargs);

		return undef if (!$self->checkResult($result, [$name]));

		$self->nmisng->log->debug3(sub {&NMISNG::Log::trace()
															 . "result: ".scalar(keys %$result)." values for table $name"});

		if (NMISNG::Util::getbool($rewritekeys))
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
	$self->nmisng->log->error("SNMP undef. Ran out of tries");
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

	$self->{error} = "set not defined for SNMPRPC";
	return undef;

}

# perform a Get, Walk or Close the SNMP session over RPC
# The RPC Daemon will create a new session if the sessionid is not set
# SessionID will be returned in the response and used for subsequent requests
# The daemon will keep these sessions open for a period of time, usally 5 mins after the last request or close.
sub make_rpc_request 
{
    my ($self, $action, $oids) = @_;

    # Validate the action parameter
    if ($action !~ /^(Get|Walk|Close)$/) {
        my $error_msg = "make_rpc_request invalid action: $action";
        $self->nmisng->log->error($error_msg);
        $self->{error} = $error_msg;
        return undef;
    }

	#cache the client, this is ok as we dont use it for async.
	my $client;
	if($self->{client})
	{
		$client = $self->{client};
	}
	else
	{
		# Create a new RPC client
		$client = NMISNG::RPC->new;
		$self->{client} = $client;
	}


	#If we have a session id we can use it
	my $obj = { SessionID => $self->{sessionid}, OIDS => $oids};

	#only send the node details if we have no sessionid
	if(!defined($self->{sessionid}) or $self->{sessionid} eq "" and $action ne "Close") {
		$obj->{Node} = {
			Community => $self->{config}->{community},
			Host => $self->{config}->{host},
			Version => $self->{config}->{version},
			Transport => $self->{config}->{domain},
			Context => $self->{config}->{context},
			Username => $self->{config}->{username},
			Timeout => $self->{config}->{timeout},
			PrivKey => $self->{config}->{privkey},
			PrivPassword => $self->{config}->{privpassword},
			PrivProtocol => $self->{config}->{privprotocol},
			AuthKey => $self->{config}->{authkey},
			AuthPassword => $self->{config}->{authpassword},
			AuthProtocol => $self->{config}->{authprotocol},
			MaxRepetitions => $self->{config}->{max_repetitions},
    	};
	}

	#JSON-RPC parameters needs to be in an array
    my @params = ($obj);
	
	$self->nmisng->log->debug5(sub { "make_rpc_request oids: " . Dumper($obj) });

    # Execute the RPC call
	#Currently all snmp rpc calls are under the NMISService namespace
    my ($error,$res) = $client->call("NMISService.$action",@params);

    if($error)
    {
        $self->nmisng->log->error("make_rpc_request error: $error");
        $self->{error} = $error;
        return undef;
    }
    if ($res) 
	{
        return $self->process_response($res);
    }
}

#Take back the response from our rpc service and process it
sub process_response 
{
    my ($self, $resp) = @_;
    my $final = {};
	#grab the session id
	my $sessionid = $resp->{SessionID};
	if (defined($sessionid) and $sessionid ne "")
	{
		$self->{sessionid} = $sessionid;
	}

	my $oids = $resp->{OIDS};
    if ($oids and ref($oids) eq "ARRAY")
    {
        foreach my $pdu (@$oids) 
		{
            #Check for a valid oid
            if (defined($pdu->{oid}) and $pdu->{oid} =~ /^(\d+)(\.\d+)*$/) 
            {
                my $value = $pdu->{value};
                if ($pdu->{type} == 4 or $pdu->{type} == 3) 
				{
                    # Decode base64 values
                    $value = decode_base64($value);
                }
                # Check for duplicate OIDs
                if (!defined($final->{$pdu->{oid}})) 
                {
                    $final->{$pdu->{oid}} = $value;
                }
                else 
                {
                    $self->nmisng->log->debug("make_rpc_request duplicate oid: $pdu->{oid}");
                }
            }
        }
    }
    return $final;
}


1;
