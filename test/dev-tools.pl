#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
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
use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Spec;
use Data::Dumper;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;
use Notify::connectwiseconnector;
use Data::Dumper;
use RRDs;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Outage;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use NMISNG::Notify;

use Compat::NMIS;

if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$NMISNG::VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage       = "Usage: $thisprogram [option=value...] <act=command>

 * act=graphs - Will show loadGraphTypeTable
 * act=inventory - Will show node inventory
 * act=collect - Collect node
 * act=update - Update node
 * act=plugin - Run plugin ( node= op= plugin=) 
 * act=model - Show model 
 * act=escalations - Run escalations
 * act=thresholds - Run thresholds for a node (node= force=)
 * act=services - Run services for a node (node= force=) 
 * act=gettable - Get data from a node (node= oid= query=) 
 * act=get_tagged_datasets - The function returns different results based on the objective variable: If tagged is passed, it returns the datasets of a given subconcept that are tagged. If rrd_path is passed, it returns the RRD paths for the given subconcept.
\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);

my $wantverbose = (NMISNG::Util::getbool($Q->{verbose}));
my $wantquiet  = NMISNG::Util::getbool($Q->{quiet});

my $customconfdir = $Q->{dir}? $Q->{dir}."/conf" : undef;
my $C      = NMISNG::Util::loadConfTable(dir => $customconfdir,
										 debug => $Q->{debug});
die "no config available!\n" if (ref($C) ne "HASH" or !keys %$C);

# log to stderr if debug is given
my $logfile = $C->{'<nmis_logs>'} . "/cli.log";
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
										 debug => $Q->{debug} ) // $C->{log_level},
										 path  => (defined $Q->{debug})? undef : $logfile);

# this opens a database connection
my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
		);

# for audit logging
my ($thislogin) = getpwuid($<); # only first field is of interest

# show the daemon status
if ($Q->{act} =~ /^graph/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $result = testgraph(node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^inventory/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $result = testinventory(node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^get_tagged_datasets/)
{
	my $node = $Q->{node};
	my $datasets_tags = $Q->{datasets_tags};
	my $objective = $Q->{objective};
    die "Need a node to run " if (!$node);
	my $result = get_tagged_datasets(node => $node, datasets_tags => $datasets_tags, objective => $objective);
	exit 0;
}

elsif ($Q->{act} =~ /^model/)
{
	my $node = $Q->{node};
	die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node); 
	if ($nodeobj) {
		my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object		

		if( !$S->init(name=>$node) )
		{
		   print " Error init for $node\n, status:".Dumper($S->status);
       die;
		}
		my $mdl = $S->mdl();
		print Dumper($mdl);
	} else {
		 print " Could not find node $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^collect/)
{
	my $node = $Q->{node};
								
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		my $pollTimer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 0;
		$nodeobj->collect( wantsnmp => $wantsnmp, wantwmi => $wantwmi, force => $Q->{force} );
		my $polltime = $pollTimer->elapTime();
		print "Collect finished in $polltime \n";
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^update/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		$nodeobj->update(force=> 1);
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^escalations/)
{
	$nmisng->process_escalations;
	exit 0;
}
elsif ($Q->{act} =~ /^thresholds/) 
{
	my $node = $Q->{node};
	die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {	
		my $S = NMISNG::Sys->new(nmisng => $nmisng);
		if ( $S->init( node => $nodeobj, snmp => 0 ) )
		{
			$nmisng->compute_thresholds( sys => $S, running_independently => 1, force => $Q->{force} );
		} else {
			print "failed to instantiate Sys: " . $S->status->{error}."\n";
		}
	} else {
		print "no node object found for $node\n";
	}
}
elsif ($Q->{act} =~ /^plugin/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $op = $Q->{op} ? $Q->{op} . "_plugin" : "collect_plugin"; # collect or update
	my $which_plugin = $Q->{plugin} ? $Q->{plugin} : "ALL";
	
	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {
		my $S = NMISNG::Sys->new(nmisng => $nmisng);
		$S->init(name=>$node);
		my ($status, @errors);
		my $ran_something = 0;
		for my $plugin ($nmisng->plugins)
		{
			if ($which_plugin =~ /ALL/ or $which_plugin =~ /$plugin/) {
				print "Plugin: $plugin \n";
				my $funcname = $plugin->can($op);
				next if ( !$funcname );
				$ran_something = 1;
				eval { ( $status, @errors ) = &$funcname( node => $node,
										node_obj => $nodeobj,
										sys => $S,
										config => $C,
										nmisng => $nmisng, ); };
				if ( $@ ) {
					print "Plugin eval failed: ".Dumper($@);
				}										
				print "Status $status \n";
				print "Errors ".Dumper(@errors)." \n";
			}
			
		}
		print "probably can't find plugin (or maybe it had errors), didn't run anything (turn on debug to see more info)\n" if(!$ran_something);
		
	} else {
		print "no node object\n";
	}
	exit 0;
}
# This is for reproduce OMK-8682		
elsif ($Q->{act} =~ /^dump-node/)
{
	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);
	#use Cube;
	#my $cube = Cube->new("1", "2");
	if ($nodeobj) {
		my @a = (1..9);
		my $test = "'test";
		for (@a) {
			print Dumper($nodeobj);
			#print $_;
			#$nmisng->log->info(Dumper($cube));
		}

	} else {
		 print " Error init for $node\n";
	}
	exit 0;
}
elsif ($Q->{act} =~ /^services/)
{
	my $node = $Q->{node};
								
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);

	if ($nodeobj) {

		my $timer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 1;

		my $S = NMISNG::Sys->new(nmisng => $nodeobj->nmisng);
		if( !$S->init( node => $nodeobj,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $nodeobj->configuration->{polling_policy},
		)) {
			die "failed to init S\n";
		}
		my $catchall_inventory = $S->inventory( concept => 'catchall' );
		my $catchall_data = $catchall_inventory->data_live();

		# snmp needs it's session opened
		if ($nodeobj->configuration->{collect} && $S->status->{snmp_enabled} )
		{
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request for getarray, or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10, );
		}
		
		$nodeobj->collect_services( sys => $S,
														 snmp => NMISNG::Util::getbool( $catchall_data->{snmpdown} ) ? 'false' : 'true',
													 wmi => NMISNG::Util::getbool( $catchall_data->{wmidown} ) ? 'false' : 'true',
													 force => $Q->{force} // 0,
													 catchall_inventory => $catchall_inventory );		
		my $totaltime = $timer->elapTime();
		print "services finished in $totaltime \n";
	} else {
		 print " Error init for $node\n";
	}
	exit 0;
	
}
elsif ($Q->{act} =~ /^gettable/)
{

	my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $nodeobj = $nmisng->node(name => $node);

	my $oid = $Q->{oid};
	my $query = $Q->{query};
	my $index = $Q->{index};

	if ($nodeobj) {

		my $timer = Compat::Timing->new;
		my $wantsnmp = $Q->{wantsnmp} // 1;
		my $wantwmi = $Q->{wantwmi} // 1;

		my $S = NMISNG::Sys->new(nmisng => $nodeobj->nmisng);
		if( !$S->init( node => $nodeobj,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $nodeobj->configuration->{polling_policy},
		)) {
			die "failed to init S\n";
		}
		my $catchall_inventory = $S->inventory( concept => 'catchall' );
		my $catchall_data = $catchall_inventory->data_live();

		# snmp needs it's session opened
		if( $wantsnmp && $S->status->{snmp_enabled} && $oid )
		{
			my $SNMP = $S->snmp;
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request for getarray, or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10, );
			if ( my $table = $SNMP->getindex($oid) ) 
			{
				print Dumper($table);
			}
			else
			{
				if (my $error = $SNMP->error ) {
					print "SNMP Error: $error\n";				
				}
			}
		}elsif( $wantsnmp && $oid ) {
			print "wmi not enabled: ".Dumper($S->status);
		}
		if( $wantwmi && $S->status->{wmi_enabled} && $query ) {
			my ( $error, $data, $meta ) = $S->{wmi}->gettable(
				wql   => $query,
				index => $index
			);
			if( $error ) {
				print "WMI Error: $error\n";
				} else {
					print "meta:".Dumper($meta);
					print "data:".Dumper($data);
				}
		} elsif( $wantwmi && $query ) {
			print "wmi not enabled: ".Dumper($S->status);
		}
	} else {
		print "Can't find node $node\n";
	}

}
# Test snmp
sub testgraph
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test graph      ==========\n";
    print "==============================================\n";
 
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $args{node} ) {
        my $node = $args{node};
        my $nodeobj = $nmisng->node(name => $node);
         if ($nodeobj) {
			 my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			 eval {
                    $S->init(name=>$node);
            }; if ($@) # load node info and Model if name exists
			 {
                    print " Error init for $node\n";
                    die;
                }
			my $graphs = $S->loadGraphTypeTable();
			print Dumper($graphs);
		 }
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
}

sub testinventory
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test Inventory  ==========\n";
    print "==============================================\n";
 
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $args{node} ) {
        my $node = $args{node};
        my $nodeobj = $nmisng->node(name => $node);
         if ($nodeobj) {
			 my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
			 eval {
                    $S->init(name=>$node);
            }; if ($@) # load node info and Model if name exists
			 {
                    print " Error init for $node\n";
                    die;
                }
			
			
			my $result = $nmisng->get_inventory_model(cluster_id => $nodeobj->cluster_id,
										node_uuid => $nodeobj->uuid );
			if (my $error = $result->error)
			{
				$nmisng->log->error("get inventory model failed: $error");
			}
			else 
			{
				for my $entry (@{$result->data})
				{
					print $entry->{concept} . " - " . $entry->{description} . "\n";
                    print $entry->{data}->{index} . "\n";
					print Dumper($entry->{subconcepts}) . "\n";
					#print Dumper($entry) . "\n";
				}
			}
		
		 }
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
}

sub get_tagged_datasets
{
	my %args = @_;
	my $node = $args{node};
	my $datasets_tags = $args{datasets_tags};
	my $debug = $args{debug};
	my $objective = $args{objective};

	# Parse datasets_tags array
	my @datasets_tags = split /,/, $args{datasets_tags};
	
	die "No datasets_tags provided\n"  unless @datasets_tags;
	print "==============   get_tagged_datasets ==========\n";
	##usuage ./dev-tools.pl act="get_tagged_datasets" node=Switch-2  datasets_tags="mem-free"  objective="tagged" debug=3
	my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $node ) {
		my $nodeobj = $nmisng->node(name => $node);
		my $node_uuid = $nodeobj->uuid;
		print "====================\$node =$node --- \@datasets_tags =".Dumper(@datasets_tags)."==========================\n";
		
		if (defined $node){
			my $result = $nodeobj->tagged_datasets_for_subconcept( datasets_tags => \@datasets_tags, objective => $objective);
			print "result=".Dumper($result);
		}
		
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
	
}

