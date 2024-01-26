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
 * act=model - Show model 
 * act=escalations - Run escalations
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
elsif ($Q->{act} =~ /^model/)
{
	my $node = $Q->{node};
								
    die "Need a node to run " if (!$node);
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
		my $mdl = $S->mdl();
		print Dumper($mdl);
	} else {
		 print " Error init for $node\n";
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
		$nodeobj->collect( wantsnmp => $wantsnmp, wantwmi => $wantwmi );
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
		for my $plugin ($nmisng->plugins)
		{
			if ($which_plugin =~ /ALL/ or $which_plugin =~ /$plugin/) {
				print "Plugin: $plugin \n";
				my $funcname = $plugin->can($op);
				next if ( !$funcname );
				eval { ( $status, @errors ) = &$funcname( node => $node,
										sys => $S,
										config => $C,
										nmisng => $nmisng, ); };
				print "Status $status \n";
				print "Errors ".Dumper(@errors)." \n";
			}
			
		}
		
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
