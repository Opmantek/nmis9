#
## $Id: Sys.pm,v 8.17 2012/12/03 07:47:26 keiths Exp $
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

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = "1.0.0";

@ISA = qw(Exporter);

@EXPORT = qw();

use strict;
use lib "../../lib";

#
use func; # common functions
use rrdfunc; # for getFileName
use snmp;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
#
use Data::Dumper; 
Data::Dumper->import();
$Data::Dumper::Indent = 1;

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	my $self = {
		name => undef,		# name of node
		mdl => undef,		# ref Model modified
		snmp => undef, 		# ref snmp object
		ndinfo => {},		# node info table
		ifinfo => {},		# interface info table
		view => {},			# view info table
		cfg => {},			# configuration of node
		rrd => {},			# RRD table for loading
		reach => {},		# tmp reach table
		error => "",
		alerts => [],
		logging => 1,
		debug => 0
	};

	bless $self, $class;
	return $self;
}

# initialise the system object for a given node
# args: node (required, or name), snmp (defaults to 1)
sub init {
	my $self = shift;
	my %args = @_;
	$self->{name} = $args{name};
	$self->{node} = lc $args{name}; # always lower case
	$self->{debug} = $args{debug};
	$self->{update} = getbool($args{update});
	my $snmp = $args{snmp} || 1;
	$snmp = getbool($snmp); # flag for init snmp object

	my $exit = 1;
	my $cfg;
	my $info;

	# cleanup
	$self->{mdl} = undef;
	$self->{info} = {};
	$self->{reach} = {};
	$self->{rrd} = {};
	$self->{view} = {};
	$self->{snmp} = undef;
	$self->{cfg} = {node => { ping => 'true'}};
	
	my $ext = getExtension(dir=>'var');

	# load info of node and interfaces in tables of this object
	if ($self->{name} ne "") { 
		if (($self->{info} = loadTable(dir=>'var',name=>"$self->{node}-node"))) { # load in table {info}
			$self->{info}{system}{host_addr} = ''; # clear ip address
			if (getbool($self->{debug})) {
				foreach my $k (keys %{$self->{info}}) {
					dbg("Node=$self->{name} info $k=$self->{info}{$k}",3);
				}					
			}
			dbg("info of node=$self->{name} loaded");
		} else {
			$self->{error} = "ERROR loading var/$self->{node}-node.$ext";
			dbg("ignore error message") if $self->{update};
			$exit = 0;
		}
	}

	$exit = 1 if $self->{update}; # ignore errors before with update

	## This is overriding the devices with the nodedown=true!
	if (($info = loadTable(dir=>'var',name=>"nmis-system"))) { # add nmis system database filenames and attribs
		### 2012-12-15 keiths, this should never exist in the nmis-system file.
		#if ( exists $info->{system}{nodedown} and $info->{system}{nodedown} ne "" ) {
		#	delete $info->{system}{nodedown};
		#}
		### 2013-08-09 keiths, the system object should not be complete for nmis-system
		if ( defined $info->{system} and ref($info->{system}) eq "HASH" ) {
			delete $info->{system};
		}
		$self->mergeHash($self->{info},$info);
		dbg("info of nmis-system loaded");
	} else {
		logMsg("ERROR cannot load var/nmis-system.$ext");
	}

	# load node configuration
	if ($exit and $snmp and $self->{name} ne "") {
		if ($self->{cfg}{node} = getNodeCfg($self->{name})) {
			dbg("cfg of node=$self->{name} loaded");
		} else {
			dbg("loading of cfg of node=$self->{name} failed");
			$exit = 0;
		}
	} else {
		dbg("no loading of cfg of node=$self->{name}");
	}

	# load Model of node or base Model
	my $tmpmodel = $self->{info}{system}{nodeModel};
	my $condition = "none";

	if ($self->{info}{system}{nodeModel} ne "" and $exit and not $self->{update}) {
		$condition = "not update";
		$exit = $self->loadModel(model=>"Model-$self->{info}{system}{nodeModel}") ;
	}
	elsif (getbool($self->{cfg}{node}{ping}) and !getbool($self->{cfg}{node}{collect}) and $self->{update}) {
		$condition = "PingOnly";
		$exit = $self->loadModel(model=>"Model-PingOnly");
		$snmp = 0;
	} 
	else {
		$condition = "default";
		dbg("loading the default model");
		$exit = $self->loadModel(model=>"Model");
	}

	if ($exit and $self->{name} ne "" and $snmp) {
		$exit = $self->initsnmp();
	}

	dbg("node=$self->{name} condition=$condition nodedown=$self->{info}{system}{nodedown} snmpdown=$self->{info}{system}{snmpdown} nodeType=$self->{info}{system}{nodeType} group=$self->{info}{system}{group}");
	dbg("returning from Sys->init with exit of $exit");
	return $exit;
}

sub initsnmp {
	my $self = shift;

	$self->{snmp} = snmp->new; 			# create communication object
	if ($self->{snmp}->init(debug=>$self->{debug})) {
		$self->{snmp}->{name} = $self->{cfg}{node}{name}; # remember name for error message
		dbg("snmp for node=$self->{name} initialized");
	} else {
		return 0;
	}
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

#===================================================================

# for easy coding of tables in object sys

sub mdl 	{ my $self = shift; return $self->{mdl} };				# my $M = $S->mdl
sub ndinfo 	{ my $self = shift; return $self->{info} };				# my $NI = $S->ndinfo
sub view 	{ my $self = shift; return $self->{view} };				# my $V = $S->view
sub ifinfo 	{ my $self = shift; return $self->{info}{interface} };	# my $IF = $S->ifinfo
sub cbinfo 	{ my $self = shift; return $self->{info}{cbqos} };		# my $CB = $S->cbinfo
sub pvcinfo 	{ my $self = shift; return $self->{info}{pvc} };	# my $PVC = $S->pvcinfo
sub callsinfo 	{ my $self = shift; return $self->{info}{calls} };	# my $CALL = $S->callsinfo
sub snmp 	{ my $self = shift; return $self->{snmp} };				# my $SNMP = $S->snmp
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
sub open {
	my $self = shift;
	my %args = @_;
	#if ( 1 ) {	
	if ( getbool($self->{cfg}{node}{collect}) ) {
		# check if numeric ip address is available for speeding up, conversion done by type=update
		my $host = ($self->{info}{system}{host_addr} ne "") ? $self->{info}{system}{host_addr} : 
						($self->{cfg}{node}{host} ne "") ? $self->{cfg}{node}{host} : $self->{cfg}{node}{name};
	
		my $timeout = $args{timeout} || 5;
		my $retries = $args{retries} || 1;
		my $oidpkt = $args{oidpkt} || 10;
		my $max_msg_size = $self->{cfg}->{node}->{max_msg_size} || $args{max_msg_size} || 1472;
	
		if ($self->{snmp}->open(
					host => stripSpaces($host),
					version => $self->{cfg}{node}{version},
					community => stripSpaces($self->{cfg}{node}{community}),
					username => stripSpaces($self->{cfg}{node}{username}),
					privpassword => stripSpaces($self->{cfg}{node}{privpassword}),
					privkey => stripSpaces($self->{cfg}{node}{privkey}),
					privprotocol => stripSpaces($self->{cfg}{node}{privprotocol}),
					authpassword => stripSpaces($self->{cfg}{node}{authpassword}),
					authkey => stripSpaces($self->{cfg}{node}{authkey}),
					authprotocol => stripSpaces($self->{cfg}{node}{authprotocol}),
					port => stripSpaces($self->{cfg}{node}{port}),
					timeout => $timeout,
					retries => $retries,
					max_msg_size => $max_msg_size,
					oidpkt => $oidpkt,
					debug => $self->{debug})) {
			$self->{info}{system}{snmpVer} = $self->{snmp}{version}; # back info
			return 1;
		}
		return 0;
	}
	else {
		return 1;		
	}
}

# close snmp session - if it's open
sub close {
	my $self = shift;
	return $self->{snmp}->close if (defined($self->{snmp}));
}


#===================================================================

### 2013-08-07 keiths, new method for interface summaries.
sub ifDescrInfo {
	my $self = shift; 
	
	my %ifDescrInfo;
	
	foreach my $indx (keys %{$self->{info}{interface}}) {
		my $ifDescr = $self->{info}{interface}{$indx}{ifDescr};
		$ifDescrInfo{$ifDescr}{ifDescr} = $self->{info}{interface}{$indx}{ifDescr};
		$ifDescrInfo{$ifDescr}{collect} = $self->{info}{interface}{$indx}{collect};
		$ifDescrInfo{$ifDescr}{threshold} = $self->{info}{interface}{$indx}{threshold};
		$ifDescrInfo{$ifDescr}{Description} = $self->{info}{interface}{$indx}{Description};
		$ifDescrInfo{$ifDescr}{ifSpeed} = $self->{info}{interface}{$indx}{ifSpeed};
		$ifDescrInfo{$ifDescr}{ifHighSpeed} = $self->{info}{interface}{$indx}{ifHighSpeed};
		$ifDescrInfo{$ifDescr}{ifIndex} = $self->{info}{interface}{$indx}{ifIndex};
		$ifDescrInfo{$ifDescr}{ifType} = $self->{info}{interface}{$indx}{ifType};
		$ifDescrInfo{$ifDescr}{ipAdEntAddr1} = $self->{info}{interface}{$indx}{ipAdEntAddr1};
		$ifDescrInfo{$ifDescr}{ipAdEntNetMask1} = $self->{info}{interface}{$indx}{ipAdEntNetMask1};
	}
	
	return \%ifDescrInfo;
}

#===================================================================

# copy config and model info into node info table
# args: type, if type==all then nodeModel and nodeType are only updated from mdl if missing
# if type==overwrite then nodeModel and nodeType are updated unconditionally
# if no type arg, then nodemodel and type aren't touched
sub copyModelCfgInfo 
{
		my $self = shift;
		my %args = @_;
		my $type = $args{type};
		
		# copy all node info, with the exception of auth-related fields
		my $dontcopy = qr/^(community|(auth|priv)(key|password|protocol))$/;
		
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

# get info by snmp, oid's are defined in Model. Values are then stored in table {info}
# returns 0 if snmp retrieval was a total failure, 1 if it worked (at least somewhat)
sub loadInfo {
	my $self = shift;
	my %args = @_;
	my $class = $args{class};
	my $section = $args{section};
	my $index = $args{index};
	my $port = $args{port};
	my $table = $args{table} || $class;
	my $dmodel = $args{model};
	my (@val,@ans,@oid);
	my $result;
	
	
	if (($result = $self->getValues(class=>$self->{mdl}{$class}{sys},section=>$section,index=>$index,port=>$port))) 
	{
		if ( $result->{error} eq "" ) 
		{
			### 2012-12-03 keiths, adding some model testing and debugging options.
			print "MODEL loadInfo $self->{name} class=$class:\n" if $dmodel;

			foreach my $sect (keys %{$result}) {
				if ($index ne '') {
					foreach my $indx (keys %{$result->{$sect}}) {
						print "  MODEL section=$sect\n" if $dmodel;
						### 2013-07-26 keiths: need a default index for SNMP vars which don't have unique descriptions
						if ( $self->{info}{$table}{$indx}{index} eq "" ) {
							$self->{info}{$table}{$indx}{index} = $indx;
						}
						foreach my $ds (keys %{$result->{$sect}{$indx}}) {
							$self->{info}{$table}{$indx}{$ds} = $result->{$sect}{$indx}{$ds}{value}; # store in {info}
							# check model for title, if exists store this info/value in view table
							if ($self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{title} ne '') {
								$self->{view}{"${table}"}{"${indx}_${ds}_value"} = rmBadChars($result->{$sect}{$indx}{$ds}{value});
								$self->{view}{"${table}"}{"${indx}_${ds}_title"} = rmBadChars($self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{title});
							}
							my $modext = "";
							$modext = "ERROR:" if $result->{$sect}{$indx}{$ds}{value} eq "noSuchObject";
							$modext = "WARNING:" if $result->{$sect}{$indx}{$ds}{value} eq "noSuchInstance";
							print "  $modext  oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds index=$indx value=$result->{$sect}{$indx}{$ds}{value}\n" if $dmodel;
							dbg("store: class=$class, type=$sect, DS=$ds, index=$indx, value=$result->{$sect}{$indx}{$ds}{value}",3);
						}
					}
				} else {
					foreach my $ds (keys %{$result->{$sect}}) {
						$self->{info}{$class}{$ds} = $result->{$sect}{$ds}{value}; # store in {info}
						# check model for title, if exists store this info in view table
						if ($self->{mdl}{$table}{sys}{$sect}{snmp}{$ds}{title} ne '') {
							$self->{view}{"${table}"}{"${ds}_value"} = rmBadChars($result->{$sect}{$ds}{value});
							$self->{view}{"${table}"}{"${ds}_title"} = rmBadChars($self->{mdl}{$table}{sys}{$sect}{snmp}{$ds}{title});
						}
						my $modext = "";
						$modext = "ERROR:" if $result->{$sect}{$ds}{value} eq "noSuchObject";
						$modext = "WARNING:" if $result->{$sect}{$ds}{value} eq "noSuchInstance";						
						print "  $modext  oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds value=$result->{$sect}{$ds}{value}\n" if $dmodel;
						dbg("store: class=$class, type=$sect, DS=$ds, value=$result->{$sect}{$ds}{value}",3);
					}
				}
			}
		}
		elsif ($result->{skipped})	# nothing to report because model said skip these items
		{
				dbg("no results, skipped because of control expression");
		}
		else 												
		{
			### 2012-03-29 keiths, SNMP is OK, some other error happened.
			dbg("ERROR ($self->{info}{system}{name}) on loadInfo, $result->{error}");
			print "MODEL ERROR: ($self->{info}{system}{name}) on loadInfo, $result->{error}\n" if $dmodel;
			# fixme shouldn't this return 0?
		}

		return 1;										# we're happy(ish) - snmp get worked
	} 
	else 													# no result from getvalues
	{
		return 0;
	}
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

# get data to store in rrd by main routine
sub getData {
	my $self = shift;
	my %args = @_;
	my $index = $args{index};
	my $port = $args{port};
	my $class = $args{class};
	my $section = $args{section};
	my $dmodel = $args{model};

	dbg("index=$index port=$port class=$class section=$section");

	if ($class eq "") {
		dbg("ERROR ($self->{name}) no class name defined");
		return 0;
	}

	my $result;
	$self->{info}{graphtype} = {} if not exists $self->{info}{graphtype};
	$result = $self->getValues(class=>$self->{mdl}{$class}{rrd},section=>$section,index=>$index,port=>$port,table=>$self->{info}{graphtype});

	### 2012-12-03 keiths, adding some model testing and debugging options.
	if ( $dmodel and $result->{error} eq "") {
		print "MODEL getData $self->{name} class=$class:\n";
		foreach my $sec (keys %$result) {
			if ( $sec =~ /interface|pkts/ ) {
				print "  section=$sec index=$index $self->{info}{interface}{$index}{ifDescr}\n";
			}
			else {
				print "  section=$sec index=$index port=$port\n";
			}
			if ( $index eq "" ) {
				foreach my $nam (keys %{$result->{$sec}}) {
					my $modext = "";
					$modext = "ERROR:" if $result->{$sec}{$nam}{value} eq "noSuchObject";
					$modext = "WARNING:" if $result->{$sec}{$nam}{value} eq "noSuchInstance";
					print "  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam value=$result->{$sec}{$nam}{value}\n";
				}
			}
			else {
				foreach my $ind (keys %{$result->{$sec}}) {
					foreach my $nam (keys %{$result->{$sec}{$ind}}) {
						#print "    oid=$self->{mdl}{$class}{sys}{$sect}{snmp}{$ds}{oid} name=$ds index=$indx value=$result->{$sect}{$indx}{$ds}{value}\n" if $dmodel;
						my $modext = "";
						$modext = "ERROR:" if $result->{$sec}{$ind}{$nam}{value} eq "noSuchObject";
						$modext = "WARNING:" if $result->{$sec}{$ind}{$nam}{value} eq "noSuchInstance";
						print "  $modext  oid=$self->{mdl}{$class}{rrd}{$sec}{snmp}{$nam}{oid} name=$nam index=$ind value=$result->{$sec}{$ind}{$nam}{value}\n";
						#print Dumper($self->{mdl}{$class}{rrd}{$sec}) ."\n" if ( $dmodel ) ;
					}
				}
			}
		}
	}
	elsif ($result->{skipped})
	{
			dbg("getValues skipped collection, no results",3);
	}
	elsif ( $dmodel and $result->{error} ne "") {
		print "MODEL ERROR: $result->{error}\n";
	}

	#if ( $class eq "system" ) {
	#	logPolling("Sys::getData,$self->{info}{system}{name},,,avgBusy5:avgBusy1,$result->{nodehealth}{avgBusy5}{value}:$result->{nodehealth}{avgBusy1}{value}");
	#}
	return $result;
}

#===================================================================

# get data by snmp defined in Model
# supports: calculate, with $r and CVAR[0-9], and replace 
#
# fixme: the CVARn handling should be integrated into parseString (must supply input of known subst values, as 
# $result->{$sect}{$index}{$ds} isn't built up by the time the substitutions must take place
sub getValues {
	my $self = shift;
	my %args = @_;
	my $class = $args{class};
	my $section = $args{section};
	my $index = $args{index};
	my $port = $args{port} || '';
	my $tbl = $args{table};

	my $SNMP = $self->{snmp};
	my (@res,@ds,@oid,@rpc,@sect,@cth,@opt,@calc,@form,@alert);
	my $log_regex = '';
	my $exit = 1;
	
	### 2013-03-06 keiths, check for valid graphtype before complaining about no OID's!
	my $gotGraphType = 0;
	my $noGraphs = 0;
	my $skipped;					# did control expression or some other normal reason cause us to skip?
	
	my $result;
	# index or port for interfaces
	my $indx = $index ne "" ? ".$index" : "";
	$indx = ".$port" if $port ne "";

	dbg("class: index=$index indx=$indx port=$port");

	# create lists
	foreach my $sect (keys %{$class}) {
		dbg("section=$section sect=$sect");
		next if $section ne ''  and $section ne $sect;
		if ($index ne '' and $class->{$sect}{indexed} eq '') {
			dbg("collect of type $sect skipped by NON indexed section, check this Model");
			# we don't mark this as intentional skip, so the no oid error shows up
			next;
		}
		if ($index eq '' and $class->{$sect}{indexed} ne '') {
			dbg("collect of section $sect skipped by indexed section");
			$skipped = 1;
			next;
		}
		# check control string for (no) collecting
		if ($class->{$sect}{control} ne "") {
			dbg("control $class->{$sect}{control} found for section=$sect",2);
			if ($self->parseString(string=>"($class->{$sect}{control}) ? 1:0",sys=>$self,index=>$index,type=>$sect,sect=>$sect) ne "1") {
				dbg("collect of section $sect with index=$index skipped by control $class->{$sect}{control}",2);
				$skipped = 1;
				next;
			}
		}
		if ($tbl) {						# add graphtype to info table
			if ($class->{$sect}{graphtype} ne "") {
				$gotGraphType = 1;
				my $gt = ($index ne "") ? $tbl->{$index}{$sect} : $tbl->{$sect};
				my @t = (split(',',$gt),split(',',$class->{$sect}{graphtype}));
				my %seen;
				foreach (@t) { $seen{$_}++;}
				$tbl->{$index}{$sect} = join(',',keys %seen) if $index ne "";
				$tbl->{$sect} = join(',',keys %seen) if $index eq "";
			} else {
				### 2013-03-06 keiths, check for valid graphtype before complaining about no OID's!
				if ( !getbool($class->{$sect}{no_graphs}) ) {
					$self->{error} = "ERROR ($self->{info}{system}{name}) missing property 'graphtype' for section $sect";
					logMsg($self->{error});
				}
				# fixme logic, if not needed here
				elsif ( getbool($class->{$sect}{no_graphs}) ) {
					$noGraphs = 1;
				}
			}
		}

		# build up arrays for calling snmp and for creating of result hash
		foreach my $ds (keys %{$class->{$sect}{snmp}}) {
			if (exists $class->{$sect}{snmp}{$ds}{oid}) {
				dbg("oid for section $sect, ds $ds loaded",3);
				push @sect,$sect;
				push @ds,$ds;
				push @oid,"$class->{$sect}{snmp}{$ds}{oid}$indx";
				push @rpc,$class->{$sect}{snmp}{$ds}{replace};
				push @cth,$class->{$sect}{snmp}{$ds}{catch};
				push @opt,$class->{$sect}{snmp}{$ds}{option};
				push @calc,$class->{$sect}{snmp}{$ds}{calculate};
				push @form,$class->{$sect}{snmp}{$ds}{format};
				push @alert,$class->{$sect}{snmp}{$ds}{alert};
			}
		}
	}
	# get values by snmp
	if (@oid ) { 
		@res = $SNMP->getarray(@oid);
		if (not defined $self->getSnmpError()) 
		{
			my %oidname2value;				# cache the raw oid to value relationships for CVARn
			for my $idx (0..$#res)
			{
					$oidname2value{$ds[$idx]}=$res[$idx];
			}
							
			foreach my $rs (@res) 
			{
				my $r = $rs;
				my $sect = shift @sect;
				my $ds = shift @ds;
				my $rpc = shift @rpc;
				my $cth = shift @cth;
				my $opt = shift @opt;
				my $calc = shift @calc;
				my $form = shift @form;
				my $alert = shift @alert;
				
				if (ref $rpc eq 'HASH') { # replace table exist
					# replace result
					if ($rpc->{$r} ne "") { 
						$r = $rpc->{$r};	# replace value
					} else {				# not in replace table
						$r = $rpc->{unknown} if $rpc->{unknown} ne "";
					}
				}
				if ($calc ne '') 
				{
						# calculate understands as placeholders: $r for the current oid,
						# and "CVAR[n]=oidname;" stanzas, with n in 0..9
						# all CVARn initialisations need to come before use, 
						# and the RAW ds/oid values are substituted, not post-calc/replace/whatever

						my (@CVAR, $rebuiltcalc, $consumeme);
						$consumeme=$calc;
						# rip apart calc, rebuild it with var substitutions
						while ($consumeme =~ s/^(.*?)(CVAR(\d)=(\w+);|\$CVAR(\d))//)
						{
								$rebuiltcalc.=$1;											 # the unmatched, non-cvar stuff at the begin
								my ($varnum,$decl,$varuse)=($3,$4,$5); # $2 is the whole |-group

								if (defined $varnum) # cvar declaration
								{
										# decl holds oid, which is known in @res but likely not in $result yet
										$CVAR[$varnum] = $oidname2value{$decl};
										logMsg("ERROR: CVAR$varnum references unknown object \"$decl\" in calc \"$calc\"")
												if (!exists $oidname2value{$decl});
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

						$r = eval { eval $calc; };
						logMsg("ERROR ($self->{name}) calculation=$calc in Model, $@") if $@;
				}
				if ($form ne '') {
					if (!($r = sprintf("${form}",$r)) ) {
						logMsg("ERROR ($self->{name}) format=$form in Model, $!");
					}
				}

				if ($index ne "") { # insert index in result table
					$result->{$sect}{$index}{$ds}{value} = $r;
					$result->{$sect}{$index}{$ds}{option} = $opt if $opt ne "";
				} else {
					$result->{$sect}{$ds}{value} = $r;
					$result->{$sect}{$ds}{option} = $opt if $opt ne "";
				}

				# save catched values if defined in model
				if ($cth ne "") {
					if ($cth->{table} ne "" and $cth->{index} ne "") { 
						$self->{$cth->{table}}{$cth->{index}} = $r;
						dbg("catched, table $cth->{table}, index $cth->{index}, result $r",3);
					}
				}

				if( defined($alert) && defined($alert->{test}) && $alert->{test} ne '' ) {
					my $test = $alert->{test};
					my $test_result = eval { eval $test; };
					$alert->{test_result} = $test_result;
					$alert->{name} = $self->{name};
					$alert->{value} = $r;
					$alert->{ds} = $ds;
					$alert->{type} = "test";
					push( @{$self->{alerts}}, $alert );
				}
			}
		} 
		else {
			dbg("ERROR ($self->{info}{system}{name}) on get values by snmp");
			$self->{info}{system}{host_addr} = ''; # clear cache
			### 2012-03-29 keiths, return needs to be null/undef so that exception handling works at other end.
			return undef;
		}
	}
	elsif ( $noGraphs ) {
		dbg("no graphs intentionally defined for section=$section sect=@sect");		
	}
	# if a section is skipped b/c of control or other rule saying no it's not an error
	elsif ($skipped)
	{
			$result->{skipped} = 1;
			$result->{error} = "skipped because of control expression";
	}
	else {
		my @sect = keys %{$class};
		dbg("no oid loaded for section=@sect");
		$result->{error} = "no oid loaded for section=@sect";
	}
	return $result;
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

# load requested Model in this object
sub loadModel {
	my $self = shift;
	my %args = @_;
	my $model = $args{model};
	my $exit = 1;
	my $name;
	my $mdl;
	
	my $ext = getExtension(dir=>'models');

	$self->{mdl} = loadTable(dir=>'models',name=>$model); # caching included
	if (!$self->{mdl}) {
		$self->{error} = "ERROR ($self->{name}) reading Model file models/$model.$ext";
		$exit = 0;
	} else {
		# continue with loading common Models
		foreach my $class (keys %{$self->{mdl}{'-common-'}{class}}) {
			$name = "Common-".$self->{mdl}{'-common-'}{class}{$class}{'common-model'};
			$mdl = loadTable(dir=>'models',name=>$name);
			if (!$mdl) {
				$self->{error} = "ERROR ($self->{name}) reading Model file models/${name}.$ext";
				$exit = 0;
			} else {
				$self->mergeHash($self->{mdl},$mdl); # add or overwrite
			}
		}
		dbg("INFO, model $model loaded");
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
### 2012-09-20 keiths, added some additional evaluation properties.
sub parseString {
	my $self = shift;
	my %args = @_;
	my $str = $args{string};
	my $indx = $args{index};
	my $itm = $args{item};
	my $sect = $args{sect};
	my $type = $args{type};


	dbg("parseString:: string to parse $str",3);

	{
		no strict;
		if ($self->{info}) {
			
			# find custom variable VAR=oid;$CVAR=~/something/
			if ( $sect ne "" && $str =~ /\(CVAR=(\w+);(.*)/ ) {
				if ( defined $self->{info}{$sect}{$indx}{$1} and $self->{info}{$sect}{$indx}{$1} ne "" ) {
					$CVAR = $self->{info}{$sect}{$indx}{$1};
					# put the brackets back in so we have "(check) ? 1:0" again
					$str = "(".$2;
					dbg("1=$1, CVAR=$CVAR;str=$str, sect=$sect indx=$indx");
				}
				else {
					return undef;
				}
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

	dbg("returning database name=$db for $sect=$sect, index=$index, item=$item");
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

sub writeNodeView {
	my $self = shift;
	my $name = "$self->{node}-view";
	#2011-11-14 Integrating changes from Till Dierkesmann
	writeTable(dir=>'var',name=>$name,data=>$self->{view}); # write view info
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

