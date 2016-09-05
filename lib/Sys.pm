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
our $VERSION = "1.2.0";

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

	my $self = {
		name => undef,		# name of node
		mdl => undef,		# ref Model modified
		snmp => undef, 		# ref snmp object
		wmi => undef,			# wmi accessor object
		info => {},		  # node info table
		ifinfo => {},		# interface info table
		view => {},			# view info table
		cfg => {},			# configuration of node
		rrd => {},			# RRD table for loading
		reach => {},		# tmp reach table
		error => "",
		alerts => [],
		logging => 1,
		debug => 0,
		cache_models => 1,					# json caching for model files default on
	};

	bless $self, $class;
	return $self;
}

# initialise the system object for a given node
# node config is loaded if snmp or wmi args are true
# args: node (required, or name), snmp (defaults to 1), wmi (defaults to the value for snmp),
# update (defaults to 0), cache_models (see code comments for defaults), force (defaults to 0)
#
# update means ignore model loading errors, also disables cache_models
# force means ignore the old node file, only relevant if update is enabled as well.
#
# returns: 1 if successful, 0 otherwise
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

	my $exit = 1;
	my $cfg;
	my $info;

	# cleanup
	$self->{mdl} = undef;
	$self->{info} = {};
	$self->{reach} = {};
	$self->{rrd} = {};
	$self->{view} = {};
	$self->{snmp} = $self->{wmi} = undef;
	$self->{cfg} = {node => { ping => 'true'}};

	my $ext = getExtension(dir=>'var');

	# load info of node  and interfaces in tables of this object, if a node is given
	if ($self->{name} ne "")
	{
		# if force is off, load the existing node info
		# if on, ignore that information and start from scratch (to bypass optimisations)
		if ($self->{update} && getbool($args{force}))
		{
			dbg("Not loading info of node=$self->{name}, force means start from scratch");
		}
		# load in table {info}
		elsif (($self->{info} = loadTable(dir=>'var',name=>"$self->{node}-node")))
		{
			if (getbool($self->{debug}))
			{
				foreach my $k (keys %{$self->{info}}) {
					dbg("Node=$self->{name} info $k=$self->{info}{$k}", 3);
				}
			}
			dbg("info of node=$self->{name} loaded");
		}
		else
		{
			$self->{error} = "ERROR loading var/$self->{node}-node.$ext";
			dbg("ignore error message") if $self->{update};
			$exit = 0;
		}
	}

	$exit = 1 if $self->{update}; # ignore previous errors if update

	## This is overriding the devices with nodedown=true!
	if (($info = loadTable(dir=>'var',name=>"nmis-system")))
	{
		if ( defined $info->{system} and ref($info->{system}) eq "HASH" ) {
			delete $info->{system};
		}
		$self->mergeHash($self->{info},$info);
		dbg("info of nmis-system loaded");
	} else {
		logMsg("ERROR cannot load var/nmis-system.$ext");
	}

	# load node configuration - attention: only done if snmp or wmi are true!
	if ($exit
			and ($snmp or $wantwmi)
			and $self->{name} ne "")
	{
		if ($self->{cfg}{node} = getNodeCfg($self->{name})) {
			dbg("cfg of node=$self->{name} loaded");
		} else {
			dbg("loading of cfg of node=$self->{name} failed");
			$exit = 0;
		}
	} else {
		dbg("no loading of cfg of node=$self->{name}");
	}
	my $thisnodeconfig = $self->{cfg}->{node};

	# load Model of node or base Model
	my $tmpmodel = $self->{info}{system}{nodeModel};
	my $condition = "none";

	if ($self->{info}{system}{nodeModel} ne "" and $exit and not $self->{update}) {
		$condition = "not update";
		$exit = $self->loadModel(model=>"Model-$self->{info}{system}{nodeModel}") ;
	}
	elsif (getbool($thisnodeconfig->{ping})
				 and !getbool($thisnodeconfig->{collect})
				 and $self->{update})
	{
		$condition = "PingOnly";
		$exit = $self->loadModel(model=>"Model-PingOnly");
		$snmp = 0;
	}
	else {
		$condition = "default";
		dbg("loading the default model");
		$exit = $self->loadModel(model=>"Model");
	}

	# init the snmp accessor, but do not connect (yet)
	if ($self->{name} ne "" and $snmp)
	{
		$exit = 0 if !($self->initsnmp());
	}
	# wmi: no connections supported AND we try this only if
	# suitable config args are present (ie. host and username, password is optional)
	if ($self->{name} and  $wantwmi and $thisnodeconfig->{host} and $thisnodeconfig->{wmiusername})
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
			$exit = 0;
			dbg("failed to create wmi accessor: $maybe");
		}
	}

	dbg("node=$self->{name} condition=$condition nodedown=$self->{info}{system}{nodedown} snmpdown=$self->{info}{system}{snmpdown} nodeType=$self->{info}{system}{nodeType} group=$self->{info}{system}{group}");
	dbg("returning from Sys->init with exit of $exit");
	return $exit;
	}


# create communication object, does NOT open the connection!
# attention: REQUIRES that sys::init was run with snmp enabled, or no conf will be loaded
sub initsnmp
{
	my $self = shift;

	# remember name for error message, no relevance for comms
	$self->{snmp} = snmp->new(debug => $self->{debug},
														name => $self->{cfg}->{node}->{name});
	dbg("snmp for node=$self->{name} initialized");
	return 1;
}

sub getSnmpError {
	my $self = shift;

	if ( defined $self->{snmp}{error} and $self->{snmp}{error} ne "" ) {
		return $self->{snmp}{error};
	}
	else {
		return undef;
	}
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


#===================================================================

# for easy coding of tables in object sys

sub mdl 	{ my $self = shift; return $self->{mdl} };				# my $M = $S->mdl
sub ndinfo 	{ my $self = shift; return $self->{info} };				# my $NI = $S->ndinfo
sub view 	{ my $self = shift; return $self->{view} };				# my $V = $S->view
sub ifinfo 	{ my $self = shift; return $self->{info}{interface} };	# my $IF = $S->ifinfo
sub cbinfo 	{ my $self = shift; return $self->{info}{cbqos} };		# my $CB = $S->cbinfo
sub pvcinfo 	{ my $self = shift; return $self->{info}{pvc} };	# my $PVC = $S->pvcinfo
sub callsinfo 	{ my $self = shift; return $self->{info}{calls} };	# my $CALL = $S->callsinfo

# like above: accessor only works AFTER init() was run with snmp enabled,
# and doesn't imply snmp works, just that it's configured
sub snmp 	{ my $self = shift; return $self->{snmp} };

sub reach 	{ my $self = shift; return $self->{reach} };			# my $R = $S->reach
sub ndcfg	{ my $self = shift; return $self->{cfg} };				# my $NC = $S->ndcfg
sub envinfo	{ my $self = shift; return $self->{info}{environment} };# my $ENV = $S->envinfo
sub syshealth	{ my $self = shift; return $self->{info}{systemHealth} };# my $SH = $S->syshealth
sub alerts	{ my $self = shift; return $self->{mdl}{alerts} };# my $CA = $S->alerts

#===================================================================


# open snmp session based on host address
#
# for max message size we try in order: host-specific value if set for this host,
# what is given as argument or default 1472. argument is expected to reflect the
# global default.
# returns: 1 if ok (or nothing to do b/c node nocollect), 0 otherwise
sub open
{
	my ($self, %args) = @_;

	return 1 if (!getbool($self->{cfg}{node}{collect}));

	# prime config for snmp, based mostly on cfg->node - cloned to not leak any of the updated bits
	my $snmpcfg = Clone::clone($self->{cfg}->{node});

	# check if numeric ip address is available for speeding up, conversion done by type=update
	$snmpcfg->{host} = $self->{info}{system}{host_addr} || $self->{cfg}{node}{host} || $self->{cfg}{node}{name};
	$snmpcfg->{timeout} = $args{timeout} || 5;
	$snmpcfg->{retries} = $args{retries} || 1;
	$snmpcfg->{oidpkt} = $args{oidpkt} || 10;
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


#===================================================================

# returns interface info, but indexed by ifdescr instead of internal indexing by ifindex
# args: none
# returns: hashref
# note: this is NOT live data, the info is shallowly clones on conversion!
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
#
# attention: if sys wasn't initialized with snmp true, then cfg will be blank!
# if no type arg, then nodemodel and type aren't touched
sub copyModelCfgInfo
{
		my $self = shift;
		my %args = @_;
		my $type = $args{type};

		# copy all node info, with the exception of auth-related fields
		my $dontcopy = qr/^(wmi(username|password)|community|(auth|priv)(key|password|protocol))$/;

		for my $fn (keys %{$self->{cfg}->{node}})
		{
				next if ($fn =~ $dontcopy);
				$self->{info}->{system}->{$fn} = $self->{cfg}->{node}->{$fn};
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

#===================================================================

# get info from node, using snmp and/or wmi
# Values are stored in {info}, under class or given table arg
#
# args: class, section, index/port (more or less required),
# table (=name where data is parked, defaults to arg class),
# debug (aka model; optional, just a debug flag!)
#
# returns 0 if retrieval was a total failure, 1 if it worked (at least somewhat)
sub loadInfo
{
	my ($self,%args) = @_;

	my $class = $args{class};
	my $section = $args{section};
	my $index = $args{index};
	my $port = $args{port};

	my $table = $args{table} || $class;
	my $wantdebug = $args{debug} || $args{model};

	# pull from the class' sys section, NOT its rrd section (if any)
	my ($result, $status) = $self->getValues( class=>$self->{mdl}{$class}{sys},
																						section=>$section,
																						index=>$index,
																						port=>$port);
	if (!$status->{error})
	{
		dbg("MODEL loadInfo $self->{name} class=$class:") if $wantdebug;
		my $target = $self->{info}->{$table} ||= {};

		foreach my $sect (keys %{$result})
		{
			if ($index ne '')
			{
				foreach my $indx (keys %{$result->{$sect}})
				{
					dbg("MODEL section=$sect") if $wantdebug;

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

						# complain about nosuchxyz
						if ($wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/)
						{
							dbg( ($1 eq "SuchObject"? "ERROR":"WARNING").": name=$ds index=$indx value=$thisval");
						}
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

					# complain about nosuchxyz
					if ($wantdebug && $thisval =~ /^no(SuchObject|SuchInstance)$/)
					{
						dbg( ($1 eq "SuchObject"? "ERROR":"WARNING").": name=$ds  value=$thisval");
					}
					dbg("store: class=$class, type=$sect, DS=$ds, value=$thisval",3);
				}
			}
		}
	}
	elsif ($result->{skipped})	# nothing to report because model said skip these items
	{
		dbg("no results, skipped because of control expression or index mismatch");
	}
	else
	{
		dbg("ERROR ($self->{info}{system}{name}) on loadInfo, $result->{error}");
		return 0;
	}

	return 1;										# we're happy(ish) - snmp or wmi worked
}

#===================================================================

# get node info by snmp, oid's are defined in Model. Values are stored in table {info}
# argument config is the gobal config hash, for finding the snmp_max_repetitions default
sub loadNodeInfo {
	my $self = shift;
	my %args = @_;
	my $C = $args{config};

	# find a value for max-repetitions: this controls how many OID's will be in a single request.
	# note: no last-ditch default; if not set we let the snmp module do its thing
	my $max_repetitions = $self->{info}{system}{max_repetitions} || $C->{snmp_max_repetitions};

	my $exit = $self->loadInfo(class=>'system');

	# check if nbarpd is possible
	if (getbool($self->{mdl}{system}{nbarpd_check}) and $args{section} eq "") {
		my %tmptable = $self->{snmp}->gettable('cnpdStatusTable',$max_repetitions);
		#2011-11-14 Integrating changes from Till Dierkesmann
		$self->{info}{system}{nbarpd} = (defined $self->{snmp}->gettable('cnpdStatusTable',$max_repetitions)) ? "true" : "false" ;
		dbg("NBARPD is $self->{info}{system}{nbarpd} on this node");
	}
	return $exit;
}

#===================================================================

# get data to store in rrd
# args: class, section, port, index (more or less required)
# ATTENTION: class is NOT a name, but a model substructure!
# if  no section is given, all sections will be handled.
# optional: debug (aka model), flag for debugging
# returns: data hashref or undef if error
sub getData
{
	my ($self, %args) = @_;

	my $index = $args{index};
	my $port = $args{port};
	my $class = $args{class};
	my $section = $args{section};

	my $wantdebug = $args{debug} || $args{model};

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
	my ($result,$status) = $self->getValues(class=>$self->{mdl}{$class}{rrd},
																					section=>$section,
																					index=>$index,
																					port=>$port,
																					table=>$self->{info}{graphtype});
	# data good,
	if ( !$status->{error})
	{
		dbg("MODEL getData $self->{name} class=$class:" .Dumper($result)) if ($wantdebug);
	}
	elsif ($status->{skipped})
	{
		dbg("getValues skipped collection, no results",3);
	}
	elsif ($status->{error})
	{
		dbg("MODEL ERROR: $status->{error}") if ($wantdebug);
	}
	return $result;
}

#===================================================================

# get data from snmp and/or wmi, as requested by Model
#
# args: class, section, index, port (more or less required)
# ATTENTION: class is NOT name but MODEL SUBSTRUCTURE!
# NOTE: if section is not given, ALL existing sections are handled
#
# table (optional, if given must be hashref and getvalues adds graphtype list to it),
#
# note: supports calculate, with $r and CVAR[0-9], and replace;
# but fixme: the CVARn handling should be integrated into parseString (must supply input of known subst values, as
# $result->{$sect}{$index}{$ds} isn't built up by the time the substitutions take place
#
# returns: (data hash ref, status hash ref with keys 'error','skipped', 'nographs')
#
# skipped is set if a control expression disables collection OR not given index but section is indexed.
# (note that index given but unindexed session seen does NOT fall under skipped!)
# nographs is set if one or more sections have a no_graphs attribute set (not relevant for data, but for arg table)
# error is set to (last) error message if anything goes wrong with snmp or wmi, or if there are no results
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
			# no graphtype? complain if the model doesn't say deliberate omission
			elsif (getbool($thissection->{no_graphs}))
			{
				$status{nographs} = "deliberate omission of graph type for section $sectionname";
			}
			else
			{
				# fixme why not in response?
				$self->{error} = "ERROR ($self->{info}{system}{name}) missing property 'graphtype' for section $sectionname";
				logMsg($self->{error});
			}
		}

		# prep the list of things to tackle, snmp first - iff snmp is ok for this node
		if (ref($thissection->{snmp}) eq "HASH" && $self->{snmp})
		{
			# expecting index or port for interfaces
			my $suffix = (defined($index) && $index ne '')? ".$index"
					: (defined($port) && $port ne '')? ".$port" : '';
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
					  $status{error} = "ERROR ($self->{name}) model error, $itemname has multiple clashing oids!";
						logMsg($status{error});
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
					  $status{error} = "ERROR ($self->{name}) model error, $itemname has multiple clashing queries/fields!";
						logMsg($status{error});
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
		if (my $error = $self->getSnmpError)
		{
			dbg("ERROR ($self->{info}{system}{name}) on get values by snmp: $error");
			$status{error} = $error;
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
					$status{error} = $error;
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

	# now handle compute, format, replace etc.
	for my $thing (values %todos)
	{
		next if (!$thing->{done});	# we should not end up with unresolved stuff but bsts

		my $value = $thing->{rawvalue};

		# where does it go? remember, multiple sections possible - potentially with DIFFERENT calculate, replace etc...
		for my $sectionidx (0..$#{$thing->{section}})
		{
			# (section and details are multiples, item, indexing, field(name) etc MUST be identical
			my ($gothere,$sectiondetails) = ($thing->{section}->[$sectionidx],
																			 $thing->{details}->[$sectionidx]);

			# massaging: calculate and replace really should not be combined in a model,
			# but if you do nmis won't complain. calculate is done FIRST, however.
			if (exists($sectiondetails->{calculate}) && (my $calc = $sectiondetails->{calculate}))
			{
				# calculate understands as placeholders: $r for the current oid/thing,
				# and "CVAR[n]=oidname;" stanzas, with n in 0..9
				# all CVARn initialisations need to come before use,
			# and the RAW ds/oid values are substituted, not post-calc/replace/whatever!

				my (@CVAR, $rebuiltcalc, $consumeme);
				$consumeme=$calc;
				# rip apart calc, rebuild it with var substitutions
				while ($consumeme =~ s/^(.*?)(CVAR(\d)=(\w+);|\$CVAR(\d))//)
				{
					$rebuiltcalc.=$1;											 # the unmatched, non-cvar stuff at the begin
					my ($varnum,$decl,$varuse)=($3,$4,$5); # $2 is the whole |-group

					if (defined $varnum) # cvar declaration
					{
						# decl holds item name
						logMsg("ERROR: CVAR$varnum references unknown object \"$decl\" in calc \"$calc\"")
								if (!exists $todos{$decl});
						$CVAR[$varnum] = $todos{$decl}->{rawvalue};
					}
					elsif (defined $varuse) # cvar use
					{
						logMsg("ERROR: CVAR$varuse used but not defined in calc \"$calc\"")
								if (!exists $CVAR[$varuse]);

						$rebuiltcalc .= $CVAR[$varuse]; # sub in the actual value
					}
					else 						# shouldn't be reached, ever
					{
						logMsg("ERROR: CVAR parsing failure for \"$calc\"");
						$rebuiltcalc=$consumeme='';
						last;
					}
				}
				$rebuiltcalc.=$consumeme; # and the non-CVAR-containing remainder.
				dbg("calc translated \"$calc\" into \"$rebuiltcalc\"",3);
				$calc = $rebuiltcalc;

				my $r = $value;						# ensure backwards compat naming
				$r = eval $calc;
				logMsg("ERROR ($self->{name}) calculation=$calc in Model, $@") if $@;

				$value = $r;
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

			# result ready, park it in the data structure IFF desired
			# if the thing has option 'nosave', then it's only collected and usable by calculate and NOT passed on!
			# nosave also implies no alerts for this thing.
			if (exists($sectiondetails->{option}) && $sectiondetails->{option} eq "nosave")
			{
				dbg("item $thing->{item} is marked as nosave, not saving in $gothere", 3);
			}
			else
			{
				my $target = (defined $index? $data{ $gothere }->{$index}->{ $thing->{item} }
											: $data{ $gothere }->{ $thing->{item} } ) ||= {};
				$target->{value} = $value;
				# rrd options from the model
				$target->{option} = $sectiondetails->{option} if (exists $sectiondetails->{option});
				# as well as a title
				$target->{title} = $sectiondetails->{title} if (exists $sectiondetails->{title});

				if ( exists($sectiondetails->{alert}) && $sectiondetails->{alert}->{test} )
				{
					my $test = $sectiondetails->{alert}->{test};

					my $r = $value;						# backwards-compat
					my $test_result = eval $test;
					logMsg("ERROR ($self->{name}) test=$test in Model for $thing->{item} for $gothere, $@") if $@;

					push @{$self->{alerts}}, 	{ name => $self->{name},
																			type => "test",
																			ds => $thing->{item},
																			value => $value,
																			test_result => $test_result, };
				}
			}
		}
	}

	# nothing found but no reason why? not good.
	if (!%data && !$status{skipped} )
	{
		my $sections = join(", ",$section, @todosections);
		$status{error} = "ERROR ($self->{info}{system}{name}): no values collected for $sections!";
	}

	return (\%data, \%status);
}

#===================================================================

# look for node model in base Model
sub selectNodeModel {
	my $self = shift;
	my %args = @_;
	my $vendor = $self->{info}{system}{nodeVendor};
	my $descr = $self->{info}{system}{sysDescr};

	foreach my $vndr (sort keys %{$self->{mdl}{models}}) {
		if ($vndr =~ /^$vendor$/i ) {
			# vendor found
			foreach my $order (sort {$a <=> $b} keys %{$self->{mdl}{models}{$vndr}{order}}) {
				foreach my $mdl (sort keys %{$self->{mdl}{models}{$vndr}{order}{$order}}) {
					if ($descr =~ /$self->{mdl}{models}{$vndr}{order}{$order}{$mdl}/i) {
						dbg("INFO, Model \'$mdl\' found for Vendor $vendor");
						return $mdl;
					}
				}
			}
		}
	}
	dbg("ERROR, Model not found for Vendor $vendor, Model=Default");
	return 'Default';
}

#===================================================================

# load requested Model into this object
# args: model, required
#
# returns: 1 if ok, 0 if not
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
		dbg("INFO, model $model loaded (from cache)");
		$exit = (ref($self->{mdl}) eq "HASH" && keys %{$self->{mdl}})? 1 : 0;
	}
	else
	{
		my $ext = getExtension(dir=>'models');
		# loadtable returns live/shared/cached info, but we must not modify that shared original!
		$self->{mdl} = Clone::clone(loadTable(dir=>'models',name=>$model));
		if (!$self->{mdl})
		{
			$self->{error} = "ERROR ($self->{name}) reading Model file models/$model.$ext";
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
					$self->{error} = "ERROR ($self->{name}) reading Model file models/${name}.$ext";
					$exit = 0;
				}
				else
				{
					# this mostly copies, so cloning not needed
					$self->mergeHash($self->{mdl},$mdl); # add or overwrite
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

#===================================================================

sub getNodeCfg {
	my $name = shift;
	my %cfg;
	my $n;
	my $nm;

	if (($n = NMIS::loadLocalNodeTable())) {
		if (($nm = NMIS::checkNodeName($name))) {
			%cfg = %{$n->{$nm}};
			dbg("cfg of node=$nm found");
			return \%cfg;
		}
	}
	return 0;
}

#===================================================================

# merge two hashes
sub mergeHash {
	my $self = shift;
	my $href1 = shift; # primary
	my $href2 = shift;
	my $lvl = shift;

	$lvl .= "=";

	my ($k,$v);

	while (($k,$v) = each %{$href2}) {
		dbg("$lvl key=$k, val=$v",3);
		if (exists $href1->{$k} and ref $href1->{$k} eq "HASH" and ref $v eq "HASH") {
			$self->mergeHash($href1->{$k},$href2->{$k},$lvl);
		} else {
			if (exists $href1->{$k} and ref $href1->{$k} eq "HASH" and ref $v ne "HASH") {
				$self->{error} = "ERROR ($self->{name}) inconsistent hash, key=$k, value=$v";
				logMsg($self->{error});
				return undef;
			}
			$href1->{$k} = $v;
			dbg("$lvl > load key=$k, val=$v",4);
		}
	}
	return $href1; # return prim. ref
}

#===================================================================

# search in Model for Title based on attribute name
sub getTitle {
	my $self = shift;
	my %args = @_;
	my $attr = $args{attr};
	my $class = $args{section}; # optional

	for my $cls (keys %{$self->{mdl}}) {
		next if $class ne "" and $class ne $cls;
		for my $sect (keys %{$self->{mdl}{$cls}{sys}}) {
			for my $at (keys %{$self->{mdl}{$cls}{sys}{$sect}{snmp}}) {
				if ($attr eq $at and $self->{mdl}{$cls}{sys}{$sect}{snmp}{$at}{title} ne "") {
					return $self->{mdl}{$cls}{sys}{$sect}{snmp}{$at}{title};
				}
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
#
# note: variables in BOTH rrd and sys sections should be found in this routine,
# regardless of whether our caller is looking at rrd or sys.
sub parseString
{
	my ($self, %args) = @_;
	my $str = $args{string};
	my $indx = $args{index};
	my $itm = $args{item};
	my $sect = $args{sect};
	my $type = $args{type};

	dbg("parseString:: string to parse $str",3);

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

		if ($str =~ /\?/) {
			# format of $str is ($scalar =~ /regex/) ? "1" : "0"
			my $check = $str;
			$check =~ s{\$(\w+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			# $check =~ s{$\$(\w+|[\$\{\}\-\>\w]+)}{if(defined${$1}){${$1};}else{"ERROR, no variable \$$1 ";}}egx;
			if ($check =~ /ERROR/) {
				dbg($check);
				$str = "ERROR ($self->{info}{system}{name}) syntax error or undefined variable at $str";
				logMsg($str);
			} else {
				$str =~ s{(.+)}{eval $1}eg; # execute expression
			}
			dbg("result of eval is $str",3);
		} else {
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


#===================================================================

# returns a hash of graphtype -> rrd section name for this node
# this hash is inverted compared to the raw grapthype data in the node info,
# and it doesn't report indices.
# keys are clearly unique, values are not: often multiple graphs are sourced
# from one rrd section.
#
# fixme: the index argument is ignored, all graphs are listed.
sub loadGraphTypeTable {
	my $self = shift;
	my %args = @_;
	my $index = $args{index};

	my %result;

	foreach my $i (keys %{$self->{info}{graphtype}}) {
		if (ref $self->{info}{graphtype}{$i} eq 'HASH') { # index
			foreach my $tp (keys %{$self->{info}{graphtype}{$i}}) {
				foreach (split(/,/,$self->{info}{graphtype}{$i}{$tp})) {
					#next if $index ne "" and $index != $i;
					$result{$_} = $tp if $_ ne "";
				}
			}
		} else {
			foreach (split(/,/,$self->{info}{graphtype}{$i})) {
				$result{$_} = $i if $_ ne "";
			}
		}
	}
	# returned table format is graphtype => type
	my $cnt = scalar keys %result;
	dbg("loaded $cnt keys",3);
#	writeTable(dir=>'var',name=>"nmis-debug-graphtable",data=>\%result);

	return \%result;
}

#===================================================================

# get type name based on graphtype name or type name (checked)
# it's either nodefile -> graphtype ->WANTTHIS -> INPUT,INPUT...
# or nodefile -> graphtype -> WANTTHIS (if the INPUT is not present but the model has
# an rrd section named WANTTHIS)
# optional check = true means suppress error messages (default no suppression)
# fixme: index argument is ignored by loadGraphTypeTable and unnecessary here as well
sub getTypeName {
	my $self = shift;
	my %args = @_;
	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $check = $args{check};

	my $h = $self->loadGraphTypeTable(index=>$index);
	return $h->{$graphtype} if ($h->{$graphtype} ne "");

	# fall back to rrd section named the same as the graphtype
	return $graphtype if ($self->{mdl}{database}{type}{$graphtype});

	logMsg("ERROR ($self->{info}{system}{name}) type=$graphtype index=$index not found in graphtype table") if (!getbool($check));
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


#===================================================================

# ask rrdfunc to compute the rrd file's path, which is based on graphtype -> db type,
# index and item; and the information in the node's model and common-database.
# this does NO LONGER use the node info cache!
# optional argument suppress_errors makes getdbname not print error messages
sub getDBName {
	my $self = shift;
	my %args = @_;
	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $item = $args{item};
	my $suppress = getbool($args{suppress_errors});
	my ($sect, $db);

	# if we have no index but item: fall back to that, and vice versa
	if (defined $item && (!defined $index || $index eq ''))
	{
			dbg("synthetic index from item for graphtype=$graphtype, item=$item",2);
			$index=$item;
	}
	elsif (defined $index && (!defined $item || $item eq ''))
	{
			dbg("synthetic item from index for graphtype=$graphtype, index=$index",2);
			$item=$index;
	}

	# first do the 'reverse lookup' from graph name to rrd section name
	if (defined ($sect = $self->getTypeName(graphtype=>$graphtype, index=>$index)))
	{

			$db = rrdfunc::getFileName(sys => $self, type => $sect,
																 index => $index, item => $item);
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
sub graphHeading {
	my $self = shift;
	my %args = @_;
	my $graphtype = $args{graphtype} || $args{type};
	my $index = $args{index};
	my $item = $args{item};

	my $header;
	$header = $self->{mdl}{heading}{graphtype}{$graphtype};
	if ($header ne "") {
		$header = $self->parseString(string=>$header,index=>$index,item=>$item);
	} else {
		$header = "heading not defined in Model";
		logMsg("heading for graphtype=$graphtype not found in model=$self->{mdl}{system}{nodeModel}");
	}
	return $header;
}

#===================================================================

sub writeNodeInfo {
	my $self = shift;

	# remove old info
	delete $self->{info}{view_system};
	delete $self->{info}{view_interface};
	my $ext = getExtension(dir=>'var');

	my $name = ($self->{node} ne "") ? "$self->{node}-node" : 'nmis-system';
	### 2013-08-27 keiths, the system object should not exist for nmis-system
	if ( $name eq "nmis-system" ) {
		if ( defined $self->{info}{system} and ref($self->{info}{system}) eq "HASH" ) {
			dbg("INFO var/nmis-system.$ext file is corrupted, deleting \$info->{system}",2);
			delete $self->{info}{system};
		}
		if ( defined $self->{info}{graphtype}{health} and $self->{info}{graphtype}{health} ne "" ) {
			dbg("INFO var/nmis-system.$ext file is corrupted, deleting \$info->{graphtype}{health}",2);
			delete $self->{info}{graphtype}{health};
		}
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

sub readNodeView {
	my $self = shift;
	my $name = "$self->{node}-view";
	if ( existFile(dir=>'var',name=>$name) ) {
		$self->{view} = loadTable(dir=>'var',name=>$name);
	} else {
		$self->{view} = {};
	}
}

#===================================================================


1;
