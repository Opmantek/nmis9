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

use func qw(loadConfTable loadTable);
use NMISNG;
use NMISNG::Log;
use NMISNG::Util;

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage = "Usage: $thisprogram [option=value...] <act=command>

 act=import-nodes-from-nodes-file
\n";

die $usage if (!@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/);
my $C = func::loadConfTable();
my $logger = NMISNG::Log->new(level => "debug", path => $C->{'<nnis_logs>'}."/nmisng-cli.log");

my $Q = NMISNG::Util::get_args_multi(@ARGV);
my $nmisng = NMISNG->new(
	config => $C,
	log => $logger,
);

if ( $Q->{act} eq "import-nodes-from-nodes-file" ) 
{
	my $node_table = func::loadTable(dir=>'conf',name=>'Nodes');
	foreach my $node_name_key (keys %$node_table)
	{
		my $node_configuration = $node_table->{$node_name_key};
		my $node = $nmisng->node( uuid => $node_configuration->{uuid}, create => 1 );
		# set the configuration
		if( $node->is_new )
		{
			print "node is new, adding configuration\n";
			$node->configuration($node_configuration);
		}
		# save		
		$node->save();
		# print "node configuration:".Dumper($node->configuration);
	}
}

1;