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
use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Basename;
use Data::Dumper;

use func qw(loadConfTable loadTable readFiletoHash);
use NMISNG;
use NMISNG::Log;
use NMISNG::Util;

if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage       = "Usage: $thisprogram [option=value...] <act=command>

 act=import-nodes-from-nodes-file
 act=import-nodeconf-from-files
\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);

my $C      = func::loadConfTable();
my $logger = NMISNG::Log->new(
	debug => $Q->{debug},
	info  => $Q->{info},
	level => $C->{log_level},
	path  => $C->{'<nnis_logs>'} . "/nmisng-cli.log"
);

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);

if ( $Q->{act} eq "import-nodes-from-nodes-file" )
{
	my $node_table = func::loadTable( dir => 'conf', name => 'Nodes' );
	foreach my $node_name_key ( keys %$node_table )
	{
		my $node_configuration = $node_table->{$node_name_key};
		my $node = $nmisng->node( id => $node_configuration->{uuid}, create => 1 );

		# set the configuration
		if ( $node->is_new )
		{
			$node->configuration($node_configuration);
		}

		# save
		my ($op,$error) = $node->save();
		$logger->error("Error saving node:",$error) if($error);
		$logger->debug( "$node_name_key saved to database, op:", $op );
	}
}
if ( $Q->{act} eq "import-nodeconf-from-files" )
{
	$logger->info( "Starting " . $Q->{act} );

	# this is highly inpired by "get_nodeconf"
	# walk the dir
	my $C     = loadConfTable();                     # likely cached
	my $ncdir = $C->{'<nmis_conf>'} . "/nodeconf";
	opendir( D, $ncdir )
		or $logger->error("Cannot open nodeconf dir: $!");
	my @cands = grep( /^[a-z0-9_-]+\.json$/, readdir(D) );
	closedir(D);

	for my $maybe (@cands)
	{
		my $data = func::readFiletoHash( file => "$ncdir/$maybe", json => 1 );
		if ( ref($data) ne "HASH" or !keys %$data or !$data->{name} )
		{
			$logger->error("nodeconf $ncdir/$maybe had invalid data! Skipping.");
			next;
		}

		# get the node, don't create it, it must exist
		my $node_name = $data->{name};
		my $node = $nmisng->node( name => $node_name );
		if ( !$node )
		{
			$logger->error("trying to import nodeconf for $data->{name} when node is not in db! Skipping.");
			next;
		}

		# don't bother saving the name in it
		delete $data->{name};
		$node->overrides($data);
		my ($op,$error) = $node->save();
		$logger->error("Error saving node:",$error) if($error);
		$logger->debug( "$node_name overrides saved to database, op:" . $op );
	}
	$logger->info( "Done " . $Q->{act} );
}

1;
