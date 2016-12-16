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
package Sys;
our $VERSION = "2.0.0";

use strict;
use lib "../../lib";

use func; # common functions
use rrdfunc; # for getFileName
use snmp 1.1.0;									# ensure the new infrastructure is in place
use WMI;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Data::Dumper;
$Data::Dumper::Indent = 1;
use List::Util;
use Clone;

# the sys constructor does next to nothing, just roughly setup the structure
sub new
{
	my ($class, %args) = @_;

	my $self = bless(
		{
			name => undef,		# name of node
			node => undef,		# node name is lc of name
			mdl => undef,		  # ref Model modified

			snmp => undef, 		# snmp accessor object
			wmi => undef,			# wmi accessor object

			info => {},		  # node info table
			view => {},			# view info table
			cfg => {},			# configuration of node
			rrd => {},			# RRD table for loading - fixme unused
			reach => {},		# tmp reach table
			alerts => [],		# getValues() saves stuff there, nmis.pl consumes

			error => undef,						# last internal error
			wmi_error => undef,				# last wmi accessor error
			snmp_error => undef,			# last snmp accessor error

			debug => 0,
			update => 0,						 # flag for update vs collect operation - attention: read by others!
			cache_models => 1,			 # json caching for model files default on
		}, $class);

	return $self;
}


#===================================================================
sub mdl 	{ my $self = shift; return $self->{mdl} };				# my $M = $S->mdl
sub ndinfo 	{ my $self = shift; return $self->{info} };				# my $NI = $S->ndinfo
sub view 	{ my $self = shift; return $self->{view} };				# my $V = $S->view
sub ifinfo 	{ my $self = shift; return $self->{info}{interface} };	# my $IF = $S->ifinfo
sub cbinfo 	{ my $self = shift; return $self->{info}{cbqos} };		# my $CB = $S->cbinfo
sub pvcinfo 	{ my $self = shift; return $self->{info}{pvc} };	# my $PVC = $S->pvcinfo
sub callsinfo 	{ my $self = shift; return $self->{info}{calls} };	# my $CALL = $S->callsinfo
sub reach 	{ my $self = shift; return $self->{reach} };			# my $R = $S->reach
sub ndcfg	{ my $self = shift; return $self->{cfg} };				# my $NC = $S->ndcfg
sub envinfo	{ my $self = shift; return $self->{info}{environment} };# my $ENV = $S->envinfo
sub syshealth	{ my $self = shift; return $self->{info}{systemHealth} };# my $SH = $S->syshealth
sub alerts	{ my $self = shift; return $self->{mdl}{alerts} };# my $CA = $S->alerts
#===================================================================


# small accessor for sys' status and errors
# args: none
# returns: hash ref of state info: error, snmp_error, wmi_error, snmp_enabled, wmi_enabled
#
# error is sys' internal error status (undef if no problems),
# snmp_error is from snmp accessor, undef if no snmp configured or not (yet) active or ok
# wmi_error is from wmi, undef if no wmi configured or not (yet) active or ok
# wmi_enabled is 1 if the config was suitable for wmi and init() was called with wmi
# snmp_enabled is 1 if config was suitable for snmp and init() was called with snmp
#
# note: all info exept error is valid only AFTER init() was run
sub status
{
	my ($self) = @_;

	return { error => $self->{error},
					 snmp_enabled => $self->{snmp}? 1 : 0,
					 wmi_enabled => $self->{wmi}? 1 : 0,
					 snmp_error => $self->{snmp_error},
					 wmi_error => $self->{wmi_error} };
}

# initialise the system object for a given node
# attention: while it's possible to reuse a sys object for different nodes,
# it is NOT RECOMMENDED!
#
# node config is loaded if snmp or wmi args are true
# args: node (mostly required, or name), snmp (defaults to 1), wmi (defaults to the value for snmp),
# update (defaults to 0), cache_models (see code comments for defaults), force (defaults to 0)
#
# update means ignore model loading errors, also disables cache_models
# force means ignore the old node file, only relevant if update is enabled as well.
#
# returns: 1 if _everything_ was successful, 0 otherwise, also sets details for status()
sub init
{
	my ($self, %args) = @_;

	$self->{name} = $args{name};
	$self->{node} = lc $args{name}; # always lower case

	$self->{debug} = $args{debug};
	$self->{update} = getbool($args{update});

	# flag for init snmp accessor, default is yes
	my $snmp = getbool(exists $args{snmp}? $args{snmp}: 1);
	# ditto for wmi, but default from snmp
	my $wantwmi = getbool(exists $args{wmi}? $args{wmi} : $snmp);

	my $C = loadConfTable();			# needed to determine the correct dir; generally cached and a/v anyway
	if (ref($C) ne "HASH" or !keys %$C)
	{
		$self->{error} = "failed to load configuration table!";
		return 0;
	}

	# sys uses end-to-end model-file-level caching, NOT per contributing common file!
	# caching can be chosen with argument cache_models here.
	# caching defaults to on if not an update op.
	# caching is always OFF if config cache_models is explicitely set to false.
	if (defined($args{cache_models}))
	{
		$self->{cache_models} = getbool($args{cache_models});
	}
	else
	{
		$self->{cache_models} = !$self->{update};
	}
	$self->{cache_models} = 0 if (getbool($C->{cache_models},"invert"));

	# (re-)cleanup, set defaults
	$self->{snmp} = $self->{wmi} = undef;
	$self->{mdl} = undef;
	for my $nuke (qw(info view rrd reach))
	{
		$self->{$nuke} = {};
	}
	$self->{cfg} = {node => { ping => 'true'}};

	# load info of node and interfaces in tables of this object, if a node is given
	# otherwise load the 'generic' sys object
	if ($self->{name})
	{
		# if force is off, load the existing node info
		# if on, ignore that information and start from scratch (to bypass optimisations)
		if ($self->{update} && getbool($args{force}))
		{
			dbg("Not loading info of node=$self->{name}, force means start from scratch");
		}
		# load the saved node info data
		elsif ( ref($self->{info} = loadTable(dir=>'var', name=>"$self->{node}-node")) eq "HASH" && keys %{$self->{info}} )
		{
			if (getbool($self->{debug}))
			{
				foreach my $k (keys %{$self->{info}}) {
					dbg("Node=$self->{name} info $k=$self->{info}{$k}", 3);
				}
			}
			dbg("info of node=$self->{name} loaded");
		}
		# or bail out if this is not an update operation, all gigo if we continued w/o.
		elsif (!$self->{update})
		{
			$self->{error} = "Failed to load node info file for $self->{node}!";
			return 0;
		}
	}

	# This is overriding the devices with nodedown=true!
	if ((my $info = loadTable(dir=>'var',name=>"nmis-system")))
	{
		# unwanted legacy gunk?
		delete $info->{system} if ( ref($info) eq "HASH" and ref($info->{system}) eq "HASH" );

		$self->_mergeHash($self->{info}, $info); # let's consider this nonterminal
	}
	else
	{
		# not terminal
		$self->{error} = "Failed to load nmis-system info!";
	}

	# load node configuration - attention: only done if snmp or wmi are true!
	if (!$self->{error}
			and ($snmp or $wantwmi)
			and $self->{name} ne "")
	{
		# fixme: this uses NMIS module code. very unclean separation.
		my $lnt = NMIS::loadLocalNodeTable();
		my $safename = NMIS::checkNodeName($self->{name});
		$self->{cfg}->{node} = Clone::clone($lnt->{ $safename })
				if (ref($lnt) eq "HASH" && $safename);

		if ($self->{cfg}->{node})
		{
			dbg("cfg of node=$self->{name} loaded");
		}
		else
		{
			$self->{error} = "Failed to load cfg of node=$self->{name}!";
			return 0;									# cannot do anything further
		}
	}
	else
	{
		dbg("no loading of cfg of node=$self->{name}");
	}


	# load Model of node or the base Model, or give up
	my $thisnodeconfig = $self->{cfg}->{node};
	my $curmodel = $self->{info}{system}{nodeModel};
	my $loadthis = "Model";

	# get the specific model
	if ($curmodel and not $self->{update})
	{
		$loadthis = "Model-$curmodel";
	}
	# no specific model, update yes, ping yes, collect no -> pingonly
	elsif (getbool($thisnodeconfig->{ping})
				 and !getbool($thisnodeconfig->{collect})
				 and $self->{update})
	{
		$loadthis = "Model-PingOnly";
	}
	# default model otherwise
	dbg("loading model $loadthis for node $self->{name}");
	# model loading failures are terminal
	return 0 if (!$self->loadModel(model => $loadthis));

	# init the snmp accessor if snmp wanted and possible, but do not connect (yet)
	if ($self->{name} and $snmp and $thisnodeconfig->{collect})
	{
		# remember name for error message, no relevance for comms
		$self->{snmp} = snmp->new(debug => $self->{debug},
															name => $self->{cfg}->{node}->{name}); # fixme why not self->{name}?
	}
	# wmi: no connections supported AND we try this only if
	# suitable config args are present (ie. host and username, password is optional)
	if ($self->{name} and $wantwmi and $thisnodeconfig->{host} and $thisnodeconfig->{wmiusername})
	{
		my $maybe = WMI->new(host => $thisnodeconfig->{host},
												 username => $thisnodeconfig->{wmiusername},
												 password => $thisnodeconfig->{wmipassword},
												 program => $C->{"<nmis_bin>"}."/wmic" );
		if (ref($maybe))
		{
			$self->{wmi} = $maybe;
		}
		else
		{
			$self->{error} = $maybe;	# not terminal
			logMsg("failed to create wmi accessor for $self->{name}: $maybe");
		}
	}

	return $self->{error}? 0 : 1;
}

# tiny accessor for figuring out if a node is configured for wmi
# returns: wmi accessor if configured, undef otherwise
#
# note: this does NOT imply that wmi WORKS, just that the node
# config is sufficient (e.g. node, username, password)
# note: must be called AFTER init() with wmi enabled!
sub wmi
{
	my ($self) = @_;

	return $self->{wmi};
}

# like above: accessor only works AFTER init() was run with snmp enabled,
# and doesn't imply snmp works, just that it's configured
sub snmp 	{ my $self = shift; return $self->{snmp} };

# open snmp session based on host address
#
# for max message size we try in order: host-specific value if set for this host,
# what is given as argument or default 1472. argument is expected to reflect the
# global default.
# returns: 1 if ok, 0 otherwise
#
# note: function MUST NOT skip connection opening based on collect t/f, because
# otherwise update ops can never bootstrap stuff.
sub open
{
	my ($self, %args) = @_;

	# prime config for snmp, based mostly on cfg->node - cloned to not leak any of the updated bits
	my $snmpcfg = Clone::clone($self->{cfg}->{node});

	# check if numeric ip address is available for speeding up, conversion done by type=update
	$snmpcfg->{host} = ( $self->{info}{system}{host_addr}
											 || $self->{cfg}{node}{host} || $self->{cfg}{node}{name} );
	$snmpcfg->{timeout} = $args{timeout} || 5;
	$snmpcfg->{retries} = $args{retries} || 1;
	$snmpcfg->{oidpkt} = $args{oidpkt} || 10;
	$snmpcfg->{max_repetitions} = $args{max_repetitions} || undef;

	$snmpcfg->{max_msg_size} = $self->{cfg}->{node}->{max_msg_size} || $args{max_msg_size} || 1472;

	return 0 if (!$self->{snmp}->open(config => $snmpcfg,
																		debug => $self->{debug}));

	$self->{info}{system}{snmpVer} = $self->{snmp}->version; # get back actual info
	return 1;
}

# close snmp session - if it's open
sub close {
	my $self = shift;
	return $self->{snmp}->close if (defined($self->{snmp}));
}

# small helper to tell sys that snmp or wmi are considered dead
# and to stop using this mechanism until (re)init'd
# args: self, what (snmp or wmi)
# returns: nothing
sub disable_source
{
	my ($self,$moriturus) = @_;
	return if ($moriturus !~ /^(wmi|snmp)$/);

	$self->close() if ($moriturus eq "snmp"); # bsts, avoid leakage
	dbg("disabling source $moriturus") if ($self->{$moriturus});
	delete $self->{$moriturus};
}

# helper that returns interface info,
# but indexed by ifdescr instead of internal indexing by ifindex
#
# args: none
# returns: hashref
# note: does NOT return live data, the info is shallowly cloned on conversion!
sub ifDescrInfo
{
	my $self = shift;

	my %ifDescrInfo;

	foreach my $indx (keys %{$self->{info}{interface}})
	{
		my $thisentry = $self->{info}->{interface}->{$indx};
		my $ifDescr = $thisentry->{ifDescr};

		$ifDescrInfo{$ifDescr} = {%$thisentry};
	}
	return \%ifDescrInfo;
}

#===================================================================

# copy config and model info into node info table
# args: type, if type==all then nodeModel and nodeType are only updated from mdl if missing
# if type==overwrite then nodeModel and nodeType are updated unconditionally
# returns: nothing
#
# attention: if sys wasn't initialized with snmp true, then cfg will be blank!
# if no type arg, then nodemodel and type aren't touched
sub copyModelCfgInfo
{
	my ($self, %args) = @_;
	my $type = $args{type};

	# copy all node info, with the exception of auth-related fields
	my $dontcopy = qr/^(wmi(username|password)|community|(auth|priv)(key|password|protocol))$/;
	if (ref($self->{cfg}->{node}) eq "HASH")
	{
		for my $fn (keys %{$self->{cfg}->{node}})
		{
			next if ($fn =~ $dontcopy);
			$self->{info}->{system}->{$fn} = $self->{cfg}->{node}->{$fn};
		}
	}

	if ( $type eq 'all' or $type eq 'overwrite' )
	{
		my $mustoverwrite = ($type eq 'overwrite');

		dbg("DEBUG: nodeType=$self->{info}{system}{nodeType} nodeType(mdl)=$self->{mdl}{system}{nodeType} nodeModel=$self->{info}{system}{nodeModel} nodeModel(mdl)=$self->{mdl}{system}{nodeModel}");

		# make the changes unconditionally if overwrite requested, otherwise only if not present
		$self->{info}{system}{nodeModel} = $self->{mdl}{system}{nodeModel}
		if (!$self->{info}{system}{nodeModel} or $mustoverwrite);
		$self->{info}{system}{nodeType} = $self->{mdl}{system}{nodeType}
		if (!$self->{info}{system}{nodeType} or $mustoverwrite);
	}
}

# get info from node, using snmp and/or wmi
# Values are stored in {info}, under class or given table arg
#
# args: class, section, index/port (more or less required),
# table (=name where data is parked, defaults to arg class),
# debug (aka model; optional, just a debug flag!)
#
# returns 0 if retrieval was a _total_ failure, 1 if it worked (at least somewhat),
# also sets details for status()
sub loadInfo
{
	my ($self,%args) = @_;

	my $class = $args{class};
	my $section = $args{section};
	my $index = $args{index};
	my $port = $args{port};

	my $table = $args{table} || $class;
	my $wantdebug = $args{debug};
	my $dmodel = $args{model};		# if separate model printfs are wanted

	# pull from the class' sys section, NOT its rrd section (if any)
	my ($result, $status) = $self->getValues( class=>$self->{mdl}{$class}{sys},
																						section=>$section,
																						index=>$index,
																						port=>$port);
	$self->{wmi_error} = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};
	$self->{error} = $status->{error};

	# no data? okish iff marked as skipped
	if (!keys %$result)
	{
		$self->{error} = "loadInfo failed for $self->{name}: $result->{error}";
    print "MODEL ERROR: ($self->{info}{system}{name}) on loadInfo, $result->{error}\n" if $dmodel;
		return 0;
	}
	elsif ($result->{skipped})	# nothing to report because model said skip these items, apparently all of them...
	{
		dbg("no results, skipped because of control expression or index mismatch");
		return 1;
	}
	else													# we have data, maybe errors too?
	{
		dbg("got data, but errors as well: error=$self->{error} snmp=$self->{snmp_error} wmi=$self->{wmi_error}")
				if ($self->{error} or $self->{snmp_error} or $self->{wmi_error});

		dbg("MODEL loadInfo $self->{name} class=$class") if $wantdebug;

		my $target = $self->{info}->{$table} ||= {};
		foreach my $sect (keys %{$result})
		{
			print "MODEL loadInfo $self->{name} class=$class:\n" if $dmodel;
			if ($index ne '')
			{
				foreach my $indx (keys %{$result->{$sect}})
				{
					dbg("MODEL section=$sect") if $wantdebug;
					print "  MODEL section=$sect\n" if $dmodel;

					### 2013-07-26 keiths: need a default index for SNMP vars which don't have unique descriptions
					if ( $target->{$indx}{index} eq "" )
					{
						$target->{$indx}{index} = $indx;
					}
					foreach my $ds (keys %{$result->{$sect}{$indx}})
					{
						my $thisval = $target->{$indx}{$ds} = $result->{$sect}{$indx}{$ds}{value}; # store in {info}
						# if getvalues provided a title for this thing, store that in view
						if (exists($result->{$sect}->{$indx}->{$ds}->{title}))
						{
							$self->{view}->{$table}{"${indx}_${ds}_value"} = rmBadChars($result->{$sect}->{$indx}->{$ds}->{value});
							$self->{view}{$table}{"${indx}_${ds}_title"} = rmBadChars($result->{$sect}->{$indx}->{$ds}->{title});
						}

						my $modext = "";
						# complain about nosuchxyz
						if ($wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/)
						{
							dbg( ($1 eq "SuchObject"? "ERROR":"WARNING").": name=$ds index=$indx value=$thisval");
							$modext = ($1 eq "SuchObject"? "ERROR":"WARNING");
						}
						print "  $modext:  oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds index=$indx value=$result->{$sect}{$indx}{$ds}{value}\n" if $dmodel;

						dbg("store: class=$class, type=$sect, DS=$ds, index=$indx, value=$thisval",3);
					}
				}
			}
			else
			{
				foreach my $ds (keys %{$result->{$sect}})
				{
					my $thisval = $self->{info}{$class}{$ds} = $result->{$sect}{$ds}{value}; # store in {info}
					# if getvalues provided a title for this thing, store that in view
					if (exists($result->{$sect}->{$ds}->{title}))
					{
						$self->{view}->{$table}{"${ds}_value"} = rmBadChars($result->{$sect}->{$ds}->{value});
							$self->{view}{$table}{"${ds}_title"} = rmBadChars($result->{$sect}->{$ds}->{title});
					}

					my $modext = "";
					# complain about nosuchxyz
					if ($wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/)
					{
						dbg( ($1 eq "SuchObject"? "ERROR":"WARNING").": name=$ds  value=$thisval");
						$modext = ($1 eq "SuchObject"? "ERROR":"WARNING");
					}
					dbg("store: class=$class, type=$sect, DS=$ds, value=$thisval",3);
					print "  $modext:  oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds value=$result->{$sect}{$ds}{value}\n" if $dmodel;

				}
			}
		}
		return 1;										# we're happy(ish) - snmp or wmi worked
	}
}

# get node info (subset) as defined by Model. Values are stored in table {info}
# args: none
# returns: 1 if worked (at least somewhat), 0 otherwise - check status() for details
sub loadNodeInfo
{
	my $self = shift;
	my %args = @_;

	my $C = loadConfTable();
	my $exit = $self->loadInfo(class=>'system'); # sets status

	# check if nbarpd is possible: wanted by model, snmp configured, no snmp problems in last load
	if (getbool($self->{mdl}{system}{nbarpd_check}) && $self->{snmp} && !$self->{snmp_error})
	{
		# find a value for max-repetitions: this controls how many OID's will be in a single request.
		# note: no last-ditch default; if not set we let the snmp module do its thing
		my $max_repetitions = $self->{info}{system}{max_repetitions} || $C->{snmp_max_repetitions};
		my %tmptable = $self->{snmp}->gettable('cnpdStatusTable',$max_repetitions);

		$self->{info}{system}{nbarpd} = keys %tmptable? "true" : "false" ;
		dbg("NBARPD is $self->{info}{system}{nbarpd} on this node");
	}
	return $exit;
}

# get data to store in rrd
# args: class, section, port, index (more or less required)
# ATTENTION: class is NOT a name, but a model substructure!
# if  no section is given, all sections will be handled.
# optional: debug (aka model), flag for debugging
# returns: data hashref or undef if error; also sets details for status()
sub getData
{
	my ($self, %args) = @_;

	my $index = $args{index};
	my $port = $args{port};
	my $class = $args{class};
	my $section = $args{section};

	my $wantdebug = $args{debug};
	my $dmodel = $args{model};
	dbg("index=$index port=$port class=$class section=$section");

	if (!$class) {
		dbg("ERROR ($self->{name}) no class name given!");
		return undef;
	}
	if (ref($self->{mdl}->{$class}) ne "HASH" or ref($self->{mdl}->{$class}->{rrd}) ne "HASH")
	{
		dbg("ERROR ($self->{name}) no rrd section for class $class!");
		return undef;
	}

	$self->{info}{graphtype} ||= {};
	# this returns all collected goodies, disregarding nosave - must be handled upstream
	my ($result,$status) = $self->getValues(class=>$self->{mdl}{$class}{rrd},
																					section=>$section,
																					index=>$index,
																					port=>$port,
																					table=>$self->{info}{graphtype});
	$self->{error} = $status->{error};
	$self->{wmi_error} = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};

	# data? we're happy-ish
	if (keys %$result)
	{
		dbg("MODEL getData $self->{name} class=$class:" .Dumper($result)) if ($wantdebug);
		if ($dmodel)
		{
			print "MODEL getData $self->{name} class=$class:\n";
			foreach my $sec (keys %$result) {
				if ( $sec =~ /interface|pkts/ )
				{
					print "  section=$sec index=$index $self->{info}{interface}{$index}{ifDescr}\n";
				}
				else {
					print "  section=$sec index=$index port=$port\n";
				}
				if ( $index eq "" )
				{
					foreach my $nam (keys %{$result->{$sec}}) {
						my $modext = "";
						$modext = "ERROR:" if $result->{$sec}{$nam}{value} eq "noSuchObject";
						$modext = "WARNING:" if $result->{$sec}{$nam}{value} eq "noSuchInstance";
						print "  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam value=$result->{$sec}{$nam}{value}\n";
					}
				}
				else
				{
					foreach my $ind (keys %{$result->{$sec}}) {
						foreach my $nam (keys %{$result->{$sec}{$ind}}) {
							my $modext = "";
							$modext = "ERROR:" if $result->{$sec}{$ind}{$nam}{value} eq "noSuchObject";
							$modext = "WARNING:" if $result->{$sec}{$ind}{$nam}{value} eq "noSuchInstance";
							print "  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam index=$ind value=$result->{$sec}{$ind}{$nam}{value}\n";
						}
					}
				}
			}
		}
	}
	elsif ($status->{skipped})
	{
		dbg("getValues skipped collection, no results");
	}
	elsif ($status->{error})
	{
		dbg("MODEL ERROR: $status->{error}") if ($wantdebug);
		print "MODEL ERROR: $status->{error}\n" if ($dmodel);
	}
	return $result;
}

# get data from snmp and/or wmi, as requested by Model
#
# args: class, section, index, port (more or less required)
# ATTENTION: class is NOT name but MODEL SUBSTRUCTURE!
# NOTE: if section is not given, ALL existing sections are handled (including alerts!)
# table (optional, if given must be hashref and getvalues adds graphtype list to it),
#
# returns: (data hash ref, status hash ref with keys 'error','skipped','nographs','wmi_error','snmp_error')
#
# skipped is set if a control expression disables collection OR not given index but section is indexed.
# (note that index given but unindexed session seen does NOT fall under skipped!)
#
# nographs is set if one or more sections have a no_graphs attribute set (not relevant for data, but for arg table)
#
# error is set to the last general error (e.g. dud model); similar for wmi_error and snmp_error, but these
# include more dynamic aspects (e.g. connection issues).
# error is completely independent of wmi_error and snmp_error; error does also NOT mean there's no data!
sub getValues
{
	my ($self, %args) = @_;

	my $class = $args{class};
	my $section = $args{section};
	my $index = $args{index};
	my $port = $args{port};

	my $tbl = $args{table};
	my (%data,%status, %todos);

	# one or all sections?
	# attention: this does include 'alerts'!
	my @todosections = (defined($section) && $section ne '')?
			exists($class->{$section}) ? $section : ()
			: (keys %{$class});

	# check reasons for skipping first
	for my $sectionname (@todosections)
	{
		dbg("wanted section=$section, now handling section=$sectionname");
		my $thissection = $class->{$sectionname};

		if (defined($index) && $index ne '' && !$thissection->{indexed})
		{
			dbg("collect of type $sectionname skipped: NON-indexed section definition but index given");
			# we don't mark this as intentional skip, so the 'no oid' error may show up
			next;
		}
		elsif ((!defined($index) or $index eq '') and $thissection->{indexed})
		{
			dbg("collect of section $sectionname skipped: indexed section but no index given");
			$status{skipped} = "skipped $sectionname because indexed section but no index given";
			next;
		}

		# check control expression next
		if ($thissection->{control})
		{
			dbg("control $thissection->{control} found for section=$sectionname",2);

			if (! $self->parseString(string=>"($thissection->{control}) ? 1:0",
															 index=>$index, sect=>$sectionname))
			{
				dbg("collect of section $sectionname with index=$index skipped: control $thissection->{control}",2);
				$status{skipped} = "skipped $sectionname because of control expression";
				next;
			}
		}

		# should we add graphtype to given (info) table?
		if (ref($tbl) eq "HASH")
		{
			if ($thissection->{graphtype})
			{
				# note: it's really index outer, then sectionname inner when an index is present.
				my $target = (defined($index) && $index ne "")? \$tbl->{$index}->{$sectionname} : \$tbl->{$sectionname};

				my %seen;
				for my $maybe (split(',',$$target), split(',',$thissection->{graphtype}))
				{
					++$seen{$maybe};
				}
				$$target = join(",", keys %seen);
			}
			# no graphtype? complain if the model doesn't say deliberate omission - not terminal though
			elsif (getbool($thissection->{no_graphs}))
			{
				$status{nographs} = "deliberate omission of graph type for section $sectionname";
			}
			else
			{
				$status{error} = "$self->{name} is missing property 'graphtype' for section $sectionname";
			}
		}

		# prep the list of things to tackle, snmp first - iff snmp is ok for this node
		if (ref($thissection->{snmp}) eq "HASH" && $self->{snmp})
		{
			# expecting port OR index for interfaces, cbqos etc. note that port overrides index!
			my $suffix = (defined($port) && $port ne '')? ".$port"
					: (defined($index) && $index ne '')? ".$index" : "";
			dbg("class: index=$index port=$port suffix=$suffix");

			for my $itemname (keys %{$thissection->{snmp}})
			{
				my $thisitem = $thissection->{snmp}->{$itemname};
				next if (!exists $thisitem->{oid});

				dbg("oid for section $sectionname, item $itemname primed for loading", 3);

				# for snmp each oid belongs to one reportable thingy, and we want to get all oids in one go
				# HOWEVER, the same thing is often saved in multiple sections!
				if ($todos{$itemname})
				{
					if ($todos{$itemname}->{oid} ne  $thisitem->{oid}.$suffix)
					{
					  $status{snmp_error} = "ERROR ($self->{name}) model error, $itemname has multiple clashing oids!";
						logMsg($status{snmp_error});
						next;
					}
					push @{$todos{$itemname}->{section}}, $sectionname;
					push @{$todos{$itemname}->{details}}, $thisitem;

					dbg("item $itemname present in multiple sections: ".join(", ", @{$todos{$itemname}->{section}}),3);
				}
				else
				{
					$todos{$itemname} = { oid => $thisitem->{oid} . $suffix,
																section => [$sectionname],
																item => $itemname, # fixme might not be required
																details => [$thisitem] };
				}
			}
		}
		# now look for wmi-sourced stuff - iff wmi is ok for this node
		if (ref($thissection->{wmi}) eq "HASH" && $self->{wmi})
		{
			for my $itemname (keys %{$thissection->{wmi}})
			{
				next if ($itemname eq "-common-"); # that's not a collectable item
				my $thisitem = $thissection->{wmi}->{$itemname};

				dbg("wmi query for section $sectionname, item $itemname primed for loading", 3);

				# check if there's a -common- section with a query for multiple items?
				my $query = (exists($thisitem->{query})? $thisitem->{query}
										 : (ref($thissection->{wmi}->{"-common-"}) eq "HASH"
												&& exists($thissection->{wmi}->{"-common-"}->{query}))?
										 $thissection->{wmi}->{"-common-"}->{query} : undef);
				# nothing to be done if we don't know what to query for, or if we don't know what field to get
				next if (!$query or !$thisitem->{field});
				# fixme: do wmi queries have to be rewritten/expanded with node properties?

				# for wmi we'd like to perform a query just ONCE for all involved items
				# but again the sme thing may need saving in more than one section
				if ($todos{$itemname})
				{
					if ($todos{$itemname}->{query} ne $query
							or $todos{$itemname}->{details}->{field} ne $thisitem->{field}
							or $todos{$itemname}->{indexed} ne $thissection->{indexed})
					{
					  $status{wmi_error} = "ERROR ($self->{name}) model error, $itemname has multiple clashing queries/fields!";
						logMsg($status{wmi_error});
						next;
					}

					push @{$todos{$itemname}->{section}}, $sectionname;
					push @{$todos{$itemname}->{details}}, $thisitem;

					dbg("item $itemname present in multiple sections: ".join(", ", @{$todos{$itemname}->{section}}),3);
				}
				else
				{
					$todos{$itemname} = { query =>  $query,
																section => [$sectionname],
																item => $itemname, # fixme might not be required
																details => [$thisitem], # crucial: contains the field(name)
																indexed => $thissection->{indexed} }; # crucial for controlling  gettable
				}
			}
		}
	}

	# any snmp oids requested? if so, get all in one go and update
	# the involved todos entries with the raw data
	if (my @haveoid = grep(exists($todos{$_}->{oid}), keys %todos))
	{
		my @rawsnmp = $self->{snmp}->getarray( map { $todos{$_}->{oid} } (@haveoid));
		if (my $error = $self->{snmp}->error)
		{
			dbg("ERROR ($self->{info}{system}{name}) on get values by snmp: $error");
			$status{snmp_error} = $error;
		}
		else
		{
			for my $idx (0..$#haveoid)
			{
				$todos{ $haveoid[$idx] }->{rawvalue} = $rawsnmp[$idx];
				$todos{ $haveoid[$idx] }->{done} = 1;
			}
		}
	}
	# any wmi queries requested? then perform the unique queries (once only!)
	# then update all involved fields
	if (my @havequery = grep(exists($todos{$_}->{query}), keys %todos))
	{
		my %seen;
		for my $itemname (@havequery)
		{
			my $query = $todos{$itemname}->{query};

			if (!$seen{$query})
			{
				# fixme: do we need dynamically created lists of fields, ie. from the known-to-be wanted stuff?
				# or is a blanket retrieve-all-then-filter good enough? where are the costs, in wmic startup or the
				# extra data generation?
				my ($error, $fields, $meta);

				# if this is an indexed query we must use gettable, get only returns the first result
				if (defined($index) && defined($todos{$itemname}->{indexed}))
				{
					# wmi gettable needs INDEX FIELD NAME, not index instance value!
					($error, $fields, $meta) = $self->{wmi}->gettable(wql => $query,
																														index => $todos{$itemname}->{indexed});
				}
				else
				{
					($error, $fields, $meta) = $self->{wmi}->get(wql => $query);
				}
				if ($error)
				{
					dbg("ERROR ($self->{info}{system}{name}) on get values by wmi: $error");
					$status{wmi_error} = $error;
				}
				else
				{
					# if indexed, gettable will have returned ALL known indices + values.
					$seen{$query} = $fields;
				}
			}
			# get the field name from the model entry
			# note: field name is enforced same across all target sections so we use the first one
			$todos{$itemname}->{rawvalue} = (defined $index?
																			 $seen{$query}->{$index}
																			 : $seen{$query})->{ $todos{$itemname}->{details}->[0]->{field} };
			$todos{$itemname}->{done} = 1;
		}
	}

	# now handle compute, format, replace, alerts etc.
	# prep the var replacement once
	my %knownvars = map { $_ => $todos{$_}->{rawvalue} } (keys %todos);

	for my $thing (values %todos)
	{
		next if (!$thing->{done});	# we should not end up with unresolved stuff but bsts

		my $value = $thing->{rawvalue};

		# where does it go? remember, multiple target sections possible - potentially with DIFFERENT calculate,
		# replace expressions etc!
		for my $sectionidx (0..$#{$thing->{section}})
		{
			# (section and details are multiples, item, indexing, field(name) etc MUST be identical
			my ($gothere,$sectiondetails) = ($thing->{section}->[$sectionidx],
																			 $thing->{details}->[$sectionidx]);

			# massaging: calculate and replace really should not be combined in a model,
			# but if you do nmis won't complain. calculate is done FIRST, however.
			# all calculate and CVAR expressions refer to the RAW variable value! (for now, as
			# multiple target sections can have different replace/calculate rules and
			# we can't easily say which one to pick)
			if (exists($sectiondetails->{calculate}) && (my $calc = $sectiondetails->{calculate}))
			{
				# setup known var value list so that eval_string can handle CVARx substitutions
				my ($error, $result) = $self->eval_string(string => $calc,
																									context => $value,
																									# for now we don't support multiple or cooked, per-section values
																									variables => [ \%knownvars ]);
				if ($error)
				{
					$status{error} = $error;
					logMsg("ERROR ($self->{name}) $error");
				}
				$value = $result;
			}
			# replace table: replace with known value, or 'unknown' fallback, or leave unchanged
			if (ref($sectiondetails->{replace}) eq "HASH")
			{
				my $reptable = $sectiondetails->{replace};

				$value = (exists($reptable->{$value})? $reptable->{$value}
									: exists($reptable->{unknown})? $reptable->{unknown} : $value);
			}

			# specific formatting requested?
			if (exists($sectiondetails->{format}) && (my $wantedformat = $sectiondetails->{format}))
			{
				$value = sprintf($wantedformat, $value);
			}

			# don't trust snmp or wmi data; neuter any html.
			$value =~ s{&}{&amp;}gso;
			$value =~ s{<}{&lt;}gso;
			$value =~ s{>}{&gt;}gso;

			# then park the result in the data structure
			my $target = (defined $index? $data{ $gothere }->{$index}->{ $thing->{item} }
										: $data{ $gothere }->{ $thing->{item} } ) ||= {};
			$target->{value} = $value;

			# rrd options come from the model
			$target->{option} = $sectiondetails->{option} if (exists $sectiondetails->{option});
			# as well as a title
			$target->{title} = $sectiondetails->{title} if (exists $sectiondetails->{title});

			# if this thing is marked nosave, ignore alerts
			if ( (!exists($target->{option}) or $target->{option} ne "nosave")
					 && exists($sectiondetails->{alert}) && $sectiondetails->{alert}->{test} )
			{
				my $test = $sectiondetails->{alert}->{test};
				dbg("checking test $test for basic alert \"$target->{title}\"",3);

				# setup known var value list so that eval_string can handle CVARx substitutions
				my ($error, $result) = $self->eval_string(string => $test,
																									context => $value,
																									# for now we don't support multiple or cooked, per-section values
																									variables => [ \%knownvars ] );
				if ($error)
				{
					$status{error} = "test=$test in Model for $thing->{item} for $gothere failed: $error";
					logMsg("ERROR ($self->{name}) test=$test in Model for $thing->{item} for $gothere failed: $error");
				}
				dbg("test $test, result=$result",3);

				push @{$self->{alerts}}, 	{ name => $self->{name},
																		type => "test",
																		event => $sectiondetails->{alert}->{event},
																		level => $sectiondetails->{alert}->{level},
																		ds => $thing->{item},
																		section => $gothere, # that's the section name
																		source => $thing->{query}? "wmi": "snmp", # not sure we actually need that in the alert context
																		value => $value,
																		test_result => $result, };
			}
		}
	}

	# nothing found but no reason why? not good.
	if (!%data && !$status{skipped} )
	{
		my $sections = join(", ",$section, @todosections);
		$status{error} = "ERROR ($self->{info}{system}{name}): no values collected for $sections!";
	}
	dbg("loaded ".(keys%todos || 0)." values, status: "
			. (join(", ", map { "$_='$status{$_}'" } (keys %status)) || 'ok'));

	return (\%data, \%status);
}

# next gen CVAR/$r evaluation function (will eventually become replacement for parsestring)
#
# args: string, context (=$r value), both required,
# optional variables (=array of one or more varname->val hash refs, checked in order)
# returns: (error message) or (undef, evaluation result)
#
# this understands: $r, CVAR, CVAR0-9; var values come from the first listed variables table
# that contains a match (exists, may be undef).
sub eval_string
{
	my ($self, %args) = @_;

	my ($input, $context) = @args{"string","context"};
	return ("missing string to evaluate!") if (!defined $input);
	return ("missing context for evaluation!") if (!defined $context);

	my $vars = $args{variables};

	my ($rebuiltcalc, $consumeme,%cvar);
	$consumeme=$input;
	# rip apart calc, rebuild it with var substitutions
	while ($consumeme =~ s/^(.*?)(CVAR(\d)?=(\w+);|\$CVAR(\d)?)//)
	{
		$rebuiltcalc.=$1;											 # the unmatched, non-cvar stuff at the begin
		my ($varnum,$decl,$varuse)=($3,$4,$5); # $2 is the whole |-group

		$varnum = 0 if (!defined $varnum); # the CVAR case == CVAR0
		if (defined $decl) # cvar declaration, decl holds item name
		{
			for my $source (@$vars)
			{
				next if (ref($source) ne "HASH"
								 or !exists($source->{$decl}));
				$cvar{$varnum} = $source->{$decl};
				last;
			}

			return "Error: CVAR$varnum references unknown object \"$decl\" in expression \"$input\""
					if (!exists $cvar{$varnum});
		}
		else # cvar use
		{
			return "Error: CVAR$varuse used but not defined in expression \"$input\""
					if (!exists $cvar{$varuse});

			$rebuiltcalc .= $cvar{$varuse}; # sub in the actual value
		}
	}
	$rebuiltcalc.=$consumeme; # and the non-CVAR-containing remainder.

	my $r = $context;						# backwards compat naming: allow $r inside expression
	$r = eval $rebuiltcalc;

	dbg("calc translated \"$input\" into \"$rebuiltcalc\", used variables: "
			. join(", ", "\$r=$context", map { "CVAR$_=$cvar{$_}" } (sort keys %cvar))
			. ", result \"$r\"", 3);
	if ($@)
	{
		return "calculation=$rebuiltcalc failed: $@";
	}

	return (undef, $r);
}

# look for node model in base Model, based on nodevendor (case-insensitive full match)
# and sysdescr (case-insensitive regex match) from nodeinfo
# args: none
# returns: model name or 'Default'
sub selectNodeModel
{
	my ($self, %args) = @_;
	my $vendor = $self->{info}{system}{nodeVendor};
	my $descr = $self->{info}{system}{sysDescr};

	foreach my $vndr (sort keys %{$self->{mdl}{models}})
	{
		if ($vndr =~ /^$vendor$/i )
		{
			# vendor found
			my $thisvendor = $self->{mdl}{models}{$vndr};
			foreach my $order (sort {$a <=> $b} keys %{$thisvendor->{order}})
			{
				my $listofmodels = $thisvendor->{order}->{$order};
				foreach my $mdl (sort keys %{$listofmodels})
				{
					if ($descr =~ /$listofmodels->{$mdl}/i)
					{
						dbg("INFO, Model \'$mdl\' found for Vendor $vendor and sysDescr $descr");
						return $mdl;
					}
				}
			}
		}
	}
	dbg("ERROR, No model found for Vendor $vendor, returning Model=Default");
	return 'Default';
}

# load requested Model into this object
# args: model, required
#
# returns: 1 if ok, 0 if not; sets internal error status for status().
sub loadModel
{
	my ($self, %args) = @_;
	my $model = $args{model};
	my $exit = 1;
	my ($name, $mdl);

	my $C = loadConfTable();			# needed to determine the correct dir; generally cached and a/v anyway

	# load the policy document (if any)
	my $modelpol = loadTable(dir => 'conf', name => 'Model-Policy');
	if (ref($modelpol) ne "HASH" or !keys %$modelpol)
	{
		dbg("WARN, ignoring invalid or empty model policy");
	}
	$modelpol ||= {};

	my $modelcachedir = $C->{'<nmis_var>'}."/nmis_system/model_cache";
	if (!-d $modelcachedir)
	{
		createDir($modelcachedir);
		setFileProt($modelcachedir);
	}
	my $thiscf = "$modelcachedir/$model.json";

	if ($self->{cache_models} && -f $thiscf)
	{
		$self->{mdl} = readFiletoHash(file => $thiscf, json => 1, lock => 0);
		if (ref($self->{mdl}) ne "HASH" or !keys %{$self->{mdl}})
		{
			$self->{error} = "ERROR ($self->{name}) failed to load Model (from cache)!";
			$exit = 0;
		}
		dbg("INFO, model $model loaded (from cache)");
	}
	else
	{
		my $ext = getExtension(dir=>'models');
		# loadtable returns live/shared/cached info, but we must not modify that shared original!
		$self->{mdl} = Clone::clone(loadTable(dir=>'models',name=>$model));
		if (ref($self->{mdl}) ne "HASH" or !keys %{$self->{mdl}})
		{
			$self->{error} = "ERROR ($self->{name}) failed to load Model file from models/$model.$ext!";
			$exit = 0;
		}
		else
		{
			# continue with loading common Models
			foreach my $class (keys %{$self->{mdl}{'-common-'}{class}})
			{
				$name = "Common-".$self->{mdl}{'-common-'}{class}{$class}{'common-model'};
				$mdl = loadTable(dir=>'models',name=>$name);
				if (!$mdl)
				{
					$self->{error} = "ERROR ($self->{name}) failed to read Model file from models/${name}.$ext!";
					$exit = 0;
				}
				else
				{
					# this mostly copies, so cloning not needed
					# however, an unmergeable model is terminal, mustn't be cached, useless.
					if (!$self->_mergeHash($self->{mdl}, $mdl))
					{
						return 0;
					}
				}
			}
			dbg("INFO, model $model loaded (from source)");

			# save to cache BEFORE the policy application, if caching is on OR if in update operation
			if (-d $modelcachedir && ($self->{cache_models} || $self->{update}))
			{
				writeHashtoFile(file => $thiscf, data => $self->{mdl}, json => 1, pretty => 0);
			}
		}
	}

	# if the loading has succeeded (cache or from source), optionally amend with rules from the policy
	if ($exit)
	{
		# find the first matching policy rule
	NEXTRULE:
		for my $polnr (sort { $a <=> $b } keys %$modelpol)
		{
			my $thisrule = $modelpol->{$polnr};
			$thisrule->{IF} ||= {};
			my $rulematches = 1;

			# all must match, order irrelevant
			for my $proppath (keys %{$thisrule->{IF}})
			{
				# input can be dotted path with node.X or config.Y; nonexistent path is interpreted
				# as blank test string!
				# special: node.nodeModel is the (dynamic/actual) model in question
				if ($proppath =~ /^(node|config)\.(\S+)$/)
				{
					my ($sourcename,$propname) = ($1,$2);

					my $value = ($proppath eq "node.nodeModel"?
											 $model : ($sourcename eq "config"? $C : $self->{info}->{system} )->{$propname});
					$value = '' if (!defined($value));

					# choices can be: regex, or fixed string, or array of fixed strings
					my $critvalue = $thisrule->{IF}->{$proppath};

					# list of precise matches
					if (ref($critvalue) eq "ARRAY")
					{
						$rulematches = 0 if (! List::Util::any { $value eq $_ } @$critvalue);
					}
					# or a regex-like string
					elsif ($critvalue =~ m!^/(.*)/(i)?$!)
					{
						my ($re,$options) = ($1,$2);
						my $regex = ($options? qr{$re}i : qr{$re});
						$rulematches = 0 if ($value !~ $regex);
					}
					# or a single precise match
					else
					{
						$rulematches = 0 if ($value ne $critvalue);
					}
				}
				else
				{
					db("ERROR, ignoring policy $polnr with invalid property path \"$proppath\"");
					$rulematches = 0;
				}
				next NEXTRULE if (!$rulematches); # all IF clauses must match
			}

			dbg("policy rule $polnr matched",2);
			# policy rule has matched, let's apply the settings
			# systemHealth is the only supported setting so far
			# note: _anything is reserved for internal purposes
			for my $sectionname (qw(systemHealth))
			{
				$thisrule->{$sectionname} ||= {};
				my @current = split(/\s*,\s*/,
														(ref($self->{mdl}->{$sectionname}) eq "HASH"?
														 $self->{mdl}->{$sectionname}->{sections} : ""));

				for my $conceptname (keys %{$thisrule->{$sectionname}})
				{
					# _anything is reserved for internal purposes, also on the inner level
					next if ($conceptname =~ /^_/);
					my $ispresent = List::Util::first { $conceptname eq $current[$_] } (0..$#current);

					if (getbool($thisrule->{$sectionname}->{$conceptname}))
					{
						dbg("adding $conceptname to $sectionname",2);
						push @current, $conceptname if (!defined $ispresent);
					}
					else
					{
						dbg("removing $conceptname from $sectionname",2);
						splice(@current,$ispresent,1) if (defined $ispresent);
					}
				}
				# save the new value if there is one; blank the whole systemhealth section
				# if there is no new value but there was a systemhealth section before; sections = undef is NOT enough.
				if (@current)
				{
					$self->{mdl}->{$sectionname}->{sections} = join(",", @current);
				}
				elsif (ref($self->{mdl}->{$sectionname}) eq "HASH")
				{
					delete $self->{mdl}->{$sectionname};
				}
			}
			last NEXTRULE;						# the first match terminates
		}
	}
	return $exit;
}

# small internal helper that merges two hashes
# args: self, destination hashref, source hashref, optional recursion level indicator
# stuff from source overwrites stuff in dest, including arrays.
#
# returns: destination hashref or undef, also sets details for status().
sub _mergeHash
{
	my ($self, $dest, $source, $lvl) = @_;

	$lvl ||= '';
	$lvl .= "=";

	while (my ($k,$v) = each %{$source})
	{
		dbg("$lvl key=$k, val=$v",4);

		if ( ref($dest->{$k}) eq "HASH" and ref($v) eq "HASH")
		{
			$self->_mergeHash($dest->{$k}, $source->{$k}, $lvl);
		}
		elsif( ref($dest->{$k}) eq "HASH" and ref($v) ne "HASH")
		{
			$self->{error} = "cannot merge inconsistent hash: key=$k, value=$v, value is ". ref($v);
			logMsg("ERROR ($self->{name}) ".$self->{error});
			return undef;
		}
		else
		{
			$dest->{$k} = $v;
			dbg("$lvl > load key=$k, val=$v", 4);
		}
	}
	return $dest;
}

# search in Model for Title based on attribute name
# attention: searches ONLY the sys areas, NOT rrd!
# args: self, attr (required), section (optional)
# returns: title string or undef
sub getTitle
{
	my ($self, %args) = @_;
	my $attr = $args{attr};
	my $section = $args{section};

	for my $class (keys %{$self->{mdl}})
	{
		next if (defined($section) and $class ne $section);
		my $thisclass = $self->{mdl}->{$class};
		for my $sectionname (keys %{$thisclass->{sys}})
		{
			my $thissection = $thisclass->{sys}->{$sectionname};
			# check both wmi and snmp sections
			for my $maybe (qw(snmp wmi))
			{
				return $thissection->{$maybe}->{$attr}->{title}
				if (ref($thissection->{$maybe}) eq "HASH"
						and ref($thissection->{$maybe}->{$attr}) eq "HASH"
						and exists($thissection->{$maybe}->{$attr}->{title}));
			}
		}
	}
	return undef;
}

#===================================================================
# parse string to replace scalars or evaluate string and return result
# args: self=sys, string (required),
# optional: sect, index, item, type. CVAR stuff works ONLY if sect is set!
# type and index are only used in substitutions, no logic attached.
# also optional: extras (hash of substitutable varname-values)
#
# note: variables in BOTH rrd and sys sections should be found in this routine,
# regardless of whether our caller is looking at rrd or sys.
# returns: parsed string
# fixme: does only log errors, not report them
sub parseString
{
	my ($self, %args) = @_;

	my ($str,$indx,$itm,$sect,$type,$extras) =
			@args{"string","index","item","sect","type","extras"};

	dbg("parseString:: string to parse '$str'",3);

	{
		no strict;									# *shudder*
		map { undef ${"CVAR$_"} } ('',0..9); # *twitch* but better than reusing old cvar values...

		if ($self->{info})
		{
			# find custom variables CVAR[n]=thing; in section, and substitute $CVAR[n] with the value
			if ( $sect
					 &&  ref($self->{info}->{$sect}) eq "HASH"
					 &&  ref($self->{info}->{$sect}->{$indx}) eq "HASH" )
			{
				my $consumeme = $str;
				my $rebuilt;

				# nongreedy consumption up to the first CVAR assignment
				while ($consumeme =~ s/^(.*?)CVAR(\d)?=(\w+);//)
				{
					my ($number, $thing)=($2,$3);
					$rebuilt .= $1;
					$number = '' if (!defined $number); # let's support CVAR, CVAR0 .. CVAR9, all separate

					if (!defined($indx) or $indx eq '')
					{
						logMsg("ERROR: $thing not a known property in section $sect!")
								if (!exists $self->{info}->{$sect}->{$thing});
						# let's set the global CVAR or CVARn to whatever value from the node info section
						${"CVAR$number"} = $self->{info}->{$sect}->{$thing};
					}
					else
					{
						logMsg("ERROR: $thing not a known property in section $sect, index $indx!")
								if (!exists $self->{info}->{$sect}->{$indx}->{$thing});
						# let's set the global CVAR or CVARn to whatever value from the node info section
						${"CVAR$number"} = $self->{info}->{$sect}->{$indx}->{$thing};
					}
					dbg("found assignment for CVAR$number, $thing, value ".${"CVAR$number"}, 3);
				}
				$rebuilt .= $consumeme;	# what's left after looking for CVAR assignments

				dbg("var extraction transformed \"$str\" into \"$rebuilt\"\nvariables: "
						.join(", ", map { "CVAR$_=".${"CVAR$_"}; } ("",0..9)), 3);

				$str = $rebuilt;
			}

			$name = $self->{info}{system}{name};
			$node = $self->{node};
			$host = $self->{info}{system}{host};
			$group = $self->{info}{system}{group};
			$roleType = $self->{info}{system}{roleType};
			$nodeModel = $self->{info}{system}{nodeModel};
			$nodeType = $self->{info}{system}{nodeType};
			$nodeVendor = $self->{info}{system}{nodeVendor};
			$sysDescr = $self->{info}{system}{sysDescr};
			$sysObjectName = $self->{info}{system}{sysObjectName};
			$location = $self->{info}{system}{location};

			# if I am wanting a storage thingy, then lets populate the variables I need.
			if ( $indx ne '' and $str =~ /(hrStorageDescr|hrStorageSize|hrStorageUnits|hrDiskSize|hrDiskUsed|hrStorageType)/ ) {
				$hrStorageDescr = $self->{info}{storage}{$indx}{hrStorageDescr};
				$hrStorageType = $self->{info}{storage}{$indx}{hrStorageType};
				$hrStorageUnits = $self->{info}{storage}{$indx}{hrStorageUnits};
				$hrStorageSize = $self->{info}{storage}{$indx}{hrStorageSize};
				$hrStorageUsed = $self->{info}{storage}{$indx}{hrStorageUsed};
				$hrDiskSize = $hrStorageSize * $hrStorageUnits;
				$hrDiskUsed = $hrStorageUsed * $hrStorageUnits;
				$hrDiskFree = $hrDiskSize - $hrDiskUsed;
			}

			# fixing auto-vivification bug!
			if ($indx ne '' and exists $self->{info}{interface}{$indx}) {
				### 2013-06-11 keiths, submission by Mateusz Kwiatkowski for thresholding
				$ifAlias = $self->{info}{interface}{$indx}{Description};
				$Description = $self->{info}{interface}{$indx}{Description};
				###
				$ifDescr = convertIfName($self->{info}{interface}{$indx}{ifDescr});
				$ifType = $self->{info}{interface}{$indx}{ifType};
				$ifSpeed = $self->{info}{interface}{$indx}{ifSpeed};
				$ifMaxOctets = ($ifSpeed ne 'U') ? int($ifSpeed / 8) : 'U';
				$maxBytes = ($ifSpeed ne 'U') ? int($ifSpeed / 4) : 'U';
				$maxPackets = ($ifSpeed ne 'U') ? int($ifSpeed / 50) : 'U';
				if ( defined $self->{info}{entPhysicalDescr} and $self->{info}{entPhysicalDescr}{$indx}{entPhysicalDescr} ne "" ) {
					$entPhysicalDescr = $self->{info}{entPhysicalDescr}{$indx}{entPhysicalDescr};
				}
			} else {
				$ifDescr = $ifType = '';
				$ifSpeed = $ifMaxOctets = 'U';
			}
			$InstalledModems = $self->{info}{system}{InstalledModems} || 0;
			$item = '';
			$item = $itm;
			$index = $indx;
		}

		dbg("node=$node, nodeModel=$nodeModel, nodeType=$nodeType, nodeVendor=$nodeVendor, sysObjectName=$sysObjectName\n".
				"\t ifDescr=$ifDescr, ifType=$ifType, ifSpeed=$ifSpeed, ifMaxOctets=$ifMaxOctets, index=$index, item=$item",3);

		# massage the string and replace any available variables from extras,
		# but ONLY WHERE no compatibility hardcoded variable is present.
		#
		# if the extras substitution were to be done first, then the identically named
		# but OCCASIONALLY DIFFERENT hardcoded global values will clash and we get breakage all over the place.
		if (ref($extras) eq "HASH")
		{
			for my $maybe (sort keys %$extras)
			{
				# note: the $$maybe works ONLY because this is under no strict
				if (defined($$maybe) && $$maybe ne $extras->{$maybe})
				{
					dbg("ignoring '$maybe' from extras: '$extras->{$maybe}' clashes with legacy '$$maybe'", 3);
					next;
				}
				my $presubst = $str;
				# this substitutes $varname and ${varname},
				# the latter is safer b/c the former has trouble with varnames sharing a prefix.
				# no look-ahead assertion is possible, we don't know what the string is used for...
				if ($str =~ s/(\$$maybe|\$\{$maybe\})/$extras->{$maybe}/g)
				{
					dbg("substituted '$maybe', str before '$presubst', after '$str'", 3);
				}
			}
		}


		if ($str =~ /\?/)
		{
			# format of $str is ($scalar =~ /regex/) ? "1" : "0"
			my $check = $str;
			$check =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			# $check =~ s{$\$(\w+|[\$\{\}\-\>\w]+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			if ($check =~ /ERROR/)
			{
				dbg($check);
				$str = "ERROR ($self->{info}{system}{name}) syntax error or undefined variable at $str, $check";
				logMsg($str);
			}
			else
			{
				# fixme: this is a substantial security risk, because backtics are also evaluated!
				$str =~ s{(.+)}{eval $1}eg; # execute expression
			}
			dbg("result of eval is $str",3);
		}
		else
		{
			my $s = $str; # copy
			$str =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			# $str =~ s{$\$(\w+|[\$\{\}\-\>\w]+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			if ($str =~ /ERROR/) {
				logMsg("ERROR ($self->{info}{system}{name}) ($s) in expanding variables, $str");
				$str = undef;
			}
		}
		dbg("parseString:: result is str=$str",3);
		return $str;
	}
}

# returns a hash of graphtype -> rrd section name for this node
# this hash is inverted compared to the raw grapthype data in the node info,
# and it doesn't report indices.
#
# keys are clearly unique, values are not: often multiple graphs are sourced
# from one rrd section.
#
# fixme: the index argument is ignored, all graphs are listed.
sub loadGraphTypeTable
{
	my ($self, %args) = @_;
	my $index = $args{index};

	# graphtype => type/rrd/section name
	my %result;

	foreach my $i (keys %{$self->{info}{graphtype}})
	{
		my $thissection = $self->{info}->{graphtype}->{$i};

		if (ref($thissection) eq 'HASH')
		{
			foreach my $tp (keys %{$thissection})
			{
				foreach (split(/,/, $thissection->{$tp}))
				{
					#next if $index ne "" and $index != $i;
					$result{$_} = $tp if $_ ne "";
				}
			}
		}
		else
		{
			foreach (split(/,/, $thissection))
			{
				$result{$_} = $i if $_ ne "";
			}
		}
	}
	dbg("found ".(scalar keys %result)." graphtypes",3);
	return \%result;
}

# get type name based on graphtype name or type name (checked)
# it's either nodefile -> graphtype ->WANTTHIS -> INPUT,INPUT...
# or nodefile -> graphtype -> WANTTHIS (if the INPUT is not present but the model has
# an rrd section named WANTTHIS)
# optional check = true means suppress error messages (default no suppression)
# fixme: index argument is ignored by loadGraphTypeTable and unnecessary here as well
sub getTypeName
{
	my ($self, %args) = @_;
	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $check = $args{check};

	my $h = $self->loadGraphTypeTable(index=>$index);
	return $h->{$graphtype} if (defined($h->{$graphtype}));

	# fall back to rrd section named the same as the graphtype
	return $graphtype if (exists($self->{mdl}->{database}->{type}->{$graphtype}));

	logMsg("ERROR ($self->{info}{system}{name}) type=$graphtype index=$index not found in graphtype table")
			if (!getbool($check));
	return undef; # not found
}

# find instances of a particular graphtype
# this function returns the indices (and thus the list) of instances/things for a
# particular graphtype, eg. all the known disk indices when asked for graphtype=hrdisk,
# or all interface indices when asked for section=interface.
#
# arguments: graphtype or section; if both are given then either matching section or
# matching graphtype will cause an instance to match.
#
# a plain section will NOT match without the section argument.
#
# returns: list of matching indices
sub getTypeInstances
{
	my ($self,%args) = @_;
	my $graphtype = $args{graphtype};
	my $section = $args{section};
	my @instances;

	my $gtt = $self->{info}{graphtype};
	for my $maybe (keys %{$gtt})
	{
		# graphtype element can be flat, ie. health => health,response,numintf
		# in which case we ignore it - there are no instances
		next if (ref($gtt->{$maybe}) ne "HASH");

		# otherwise it's expected to be dbtype => sometype,othertype; one or more of these
		# first see if we have a section match, e.g. interface
		if (defined $section && $section ne '' && defined $gtt->{$maybe}->{$section})
		{
			push @instances, $maybe;
			next;
		}

		# otherwise collect all the sometype,othertype,anothertype  values and look
		# for a match. this is for finding the parent of
		# interface => 'autil,util,abits,bits,maxbits via maxbits for example.
		if (defined $graphtype && $graphtype ne '')
		{
			for my $subsection ( keys %{$gtt->{$maybe}} )
			{
				if (grep($graphtype eq $_, split(/,/, $gtt->{$maybe}->{$subsection})))
				{
					push @instances, $maybe;
					last;				# done with this index
				}
			}
		}
	}
	return @instances;
}

# ask rrdfunc to compute the rrd file's path, which is based on graphtype -> db type,
# index and item, possibly also node info; and certainly the information
# in the node's model and common-database.
# args: graphtype or type (required), index, item (mostly required),
# optional argument suppress_errors makes getdbname not print error messages
# returns: rrd file name or undef
sub getDBName
{
	my ($self,%args) = @_;

	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $item = $args{item};
	my $suppress = getbool($args{suppress_errors});
	my ($sect, $db);

	# if we have no index but item: fall back to that, and vice versa
	if (defined $item && $item ne '' && (!defined $index || $index eq ''))
	{
		dbg("synthetic index from item for graphtype=$graphtype, item=$item",2);
		$index=$item;
	}
	elsif (defined $index && $index ne '' && (!defined $item || $item eq ''))
	{
		dbg("synthetic item from index for graphtype=$graphtype, index=$index",2);
		$item=$index;
	}

	# first do the 'reverse lookup' from graph name to rrd section name
	if (defined ($sect = $self->getTypeName(graphtype=>$graphtype, index=>$index)))
	{
		my $NI = $self->ndinfo;
		# indexed and section exists? pass that for extra variable expansions
		# unindexed? pass nothing
		my $extras = ( defined($index) && $index ne ''?
									 $NI->{$sect}->{$index} : undef );

		$db = rrdfunc::getFileName( sys => $self, type => $sect,
															  index => $index, item => $item,
															  extras => $extras );
	}

	if (!defined $db)
	{
		logMsg("ERROR ($self->{info}{system}{name}) database name not found for graphtype=$graphtype, index=$index, item=$item, sect=$sect") if (!$suppress);
		return undef;
	}

	dbg("returning database name=$db for sect=$sect, index=$index, item=$item");

	return $db;
}

#===================================================================

# get header based on graphtype
# args graphtype, type, index, item
# returns header or undef
sub graphHeading
{
	my ($self,%args) = @_;

	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $item = $args{item};

	my $header = $self->{mdl}->{heading}->{graphtype}->{$graphtype}
	if (defined $self->{mdl}->{heading}->{graphtype}->{$graphtype});

	if ($header)
	{
		$header = $self->parseString(string=>$header,index=>$index,item=>$item);
	}
	else
	{
		$header = "Heading not defined in Model";
		logMsg("heading for graphtype=$graphtype not found in model=$self->{mdl}{system}{nodeModel}");
	}
	return $header;
}

sub writeNodeInfo
{
	my $self = shift;

	# remove ancient unwanted legacy info
	delete $self->{info}{view_system};
	delete $self->{info}{view_interface};

	my $ext = getExtension(dir=>'var');

	my $name = ($self->{node} ne "") ? "$self->{node}-node" : 'nmis-system';

	if ( $name eq "nmis-system" )
	{
		### 2013-08-27 keiths, the system object should not exist for nmis-system
		delete $self->{info}->{system};
		delete $self->{info}->{graphtype}->{health} if (ref($self->{info}->{graphtype}) eq "HASH");
	}

	writeTable(dir=>'var',name=>$name,data=>$self->{info}); # write node info
}

# write out the node view information IFF the object has any, or if arg force is given
# args: force, default 0
# returns: nothing
sub writeNodeView
{
	my ($self, %args) = @_;

	if ((ref($self->{view}) eq "HASH" and keys %{$self->{view}})
			or getbool($args{force}))
	{
		writeTable(dir=>'var',
							 name=> "$self->{node}-view",
							 data=>$self->{view}); # write view info
	}
	else
	{
		dbg("not overwriting view file for $self->{node}: no view data present!");
	}
}

sub readNodeView
{
	my $self = shift;
	my $name = "$self->{node}-view";
	if ( existFile(dir=>'var',name=>$name) )
	{
		$self->{view} = loadTable(dir=>'var',name=>$name);
	}
	else {
		$self->{view} = {};
	}
}


1;
