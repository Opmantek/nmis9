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
use Data::Dumper;

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
my $usage       = "Usage: $thisprogram [-version] [-h[elp]]

\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);


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
if ($Q->{act} =~ /^migrate_nodeconf/)
{
	my $result = migrate_nodeconf($Q);
	exit 0;
}

# Test connectwise
sub migrate_nodeconf
{
    my %args = @_;
    my $debug = $args{debug};
    my $dir = $args{dir} // "/usr/local/nmis8/conf/nodeconf";
    
    if (opendir(DIR, $dir)) {
		my $filename;
		while ($filename = readdir(DIR)) {
			# Only .nmis files
			next unless ($filename =~ m/\.json$/);
            print "Reading $filename \n";
			my $overrides = NMISNG::Util::readFiletoHash(file=>"$dir/$filename", json => 1);
            my $nodeobj = $nmisng->node(name => $overrides->{name});
            if ($nodeobj) {
                delete $overrides->{name};
                $nodeobj->overrides($overrides);
                my ($op, $error) = $nodeobj->save();
                print "Node ". $nodeobj->name . " updated \n";
            } else {
                print "Node ". $overrides->{name} . " doesnt exist \n";
            }
		}
		closedir(DIR);
	}

}
