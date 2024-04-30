#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

# split the nmis log file up into one file per collect/update per node, each of 
# those files is placed into a folder named by node
# also creates one file per node with all log entries from that node and is placed
# in AAA_node_logs folder
use strict;
our $VERSION = "9.4.4";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
    print "version=$VERSION\n";
    exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;
use Mojo::File;

# use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
# use Compat::NMIS;
use Compat::Timing;

# Get setup
my $bn = basename($0);
my $usage = "Usage: $bn log=/path/to/file output_path=/path/to/dir/to/make (defaults to /tmp/splitlogs\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $log = $cmdline->{log};
my $output_path = $cmdline->{output_path} // '/tmp/splitlogs';

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
                                                                                    debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH"
                                                                 or !keys %$config);

# log to stderr
my $logfile = undef; #$config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
# my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
# warn "failed to set permissions: $error\n" if ($error);

# use debug or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
                                                                 debug => $cmdline->{debug}) // $config->{log_level},
                                                             path  => (defined $cmdline->{debug})? undef : $logfile);

$logger->info("Starting split_nmis9_log log=$log, output_path:$output_path");

my $root_path =  Mojo::File::path($output_path)->make_path;
$logger->info("Placing files in $root_path");
my $result = splitit();

$logger->info("Finished, log=$log");

# worker actions
use constant {
  START_NODE_UPDATE  => "update",
  END_NODE_UPDATE    => "END_NODE_UPDATE",
  START_NODE_COLLECT => "collect",
  END_NODE_COLLECT   => "END_NODE_COLLECT",
  WORKER_START       => "WORKER_START",
  WORKER_END         => "WORKER_END",
  UNKOWN             => "UNKOWN"
};
my $jobstack = {};
my $nodemsgs = {};

sub splitit {
  open my $info, $log or die "Could not open $log: $!";
  while( my $line = <$info>)  { 
    my $res = parseline($line);
  }  
  close $info;

  $logger->info("Parsing and placing indivudual files done, working on log all lines");
  foreach my $node_name (keys %$nodemsgs) {
    my $node_log = $nodemsgs->{$node_name};
    # put them in a directory named node_logs
    my $path = $root_path->child('./AAA_node_logs')->make_path;    
    $path->child("$node_name-alllines.json")->spurt( JSON::XS->new->utf8(1)->pretty(1)->encode($node_log) );
  }
}

# [Sun Apr 21 23:00:17 2024] [info] worker[1641499]
sub parseline {
  my ($line) = @_;
  # basically match on the [] and capture and then everything after the end
  # this one has a worker pid, thsy all should
  if( $line =~ /\[(.*?)\]\s\[(.*?)\]\s(\w+)\[(.*?)\] (.*)/gm ) {
    my ($date,$level,$worker,$pid,$msg) = ($1,$2,$3,$4,$5);
    my $ret = handle_message($msg);

    my $jobres = handle_worker_action($date,$level,$worker,$pid,$msg,$ret);
    if( $jobres->{node_name} ne '' ) {
      
      my $jobfile = "$jobres->{action}-$jobres->{start_dt}.json";
      my $path = $root_path->child('./'.$jobres->{node_name})->make_path;
      $path->child($jobfile)->spurt( JSON::XS->new->utf8(1)->pretty(1)->encode($jobres) );
    } 
  }
}

# take an nmis log message and figure out if it's a start/end of a collect or update
# 
sub handle_message {
  my ($msg) = @_;
  # print "msg:$msg\n";
  my $uuid_qr = qr//;
  if( $msg =~ /Starting (\w+) for node ([0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12})\s\((.*?)\)/ ) {
    # Starting collect for node 074bd114-f0fa-45ee-bdeb-f385abae1867 (SEARS_PUEBLA_ANGELOPOLIS_CORE_PCS_SW01)
    my ($op,$node_uuid,$node_name) = ($1,$2,$3);
    return { workeraction => START_NODE_COLLECT, node_uuid => $node_uuid, node_name => $node_name } if(lc($op) eq 'collect');
    return { workeraction => START_NODE_UPDATE, node_uuid => $node_uuid, node_name => $node_name } if(lc($op) eq 'update');
  } elsif ($msg =~ /Completed job .{24}, (\w+), removing from queue/ ) {
    # Completed job 66259a7f721df0174d5952cf, collect, removing from queue
    my ($op) = ($1);
    return { workeraction => END_NODE_COLLECT } if(lc($op) eq 'collect');
    return { workeraction => END_NODE_UPDATE } if(lc($op) eq 'update');    
  } elsif( $msg =~ /started$/) {
    return { workeraction => WORKER_START };
  }
  return  { workeraction => UNKOWN };
}


# take the worker action and pid and other info and distill it into
# what happened per job, also keep logs for each node
sub handle_worker_action {
  my ($date,$level,$worker,$pid,$msg,$ret) = @_;
  my $jobres;
  if($ret->{workeraction} eq UNKOWN) {
    if( ref($jobstack->{$pid}) eq 'HASH' ) {
      my $node_name = $jobstack->{$pid}{node_name};
      my $addme = { level => $level, msg => $msg, at => $date };      
      push @{$nodemsgs->{$node_name}}, $addme;
      push @{$jobstack->{$pid}{lines}}, $addme;
    } else {
      $logger->debug("$pid has msg but no job, msg:$msg");
    }
  }  elsif($ret->{workeraction} eq START_NODE_COLLECT || $ret->{workeraction} eq START_NODE_UPDATE) {
    $jobstack->{$pid} = { node_name => $ret->{node_name}, node_uuid => $ret->{node_uuid}, lines => [], start_dt => $date, action => $ret->{workeraction} };
  } elsif($ret->{workeraction} eq END_NODE_COLLECT || $ret->{workeraction} eq END_NODE_UPDATE ) {
    $jobres = $jobstack->{$pid};
    $jobres->{end_dt} = $date;
    $jobstack->{$pid} = undef;
  }
  return $jobres;
}
