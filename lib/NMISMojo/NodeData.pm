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
#

package NMISMojo::NodeData;

# BEGIN {
# 	our ($VERSION,$ABI,$MAGIC) = ("1.492.0","4.0.0","DEADCHICKEN");
# 	if( scalar(@ARGV) == 1 && $ARGV[0] eq "--module-version" ) {
# 		print __PACKAGE__." version=$VERSION\n".__PACKAGE__." abi=$ABI\n".__PACKAGE__." magic=$MAGIC\n";
# 		exit(0);
# 	}
# };

use strict;
use Data::Dumper;
use UUID::Tiny qw(:std);
use NMISNG::Util;
use NMISNG::Log;
# use NMISx;
# use Clone;
# use Carp;

# combined constructor and loader - doesn't (pre)load resources as they're in mongo
#
# args: type and controller, needs config from controller
# returns: (undef,object) if ok, (errormessage,undef) otherwise
sub load_resources
{
	my ($class,%args) = @_;
   
	my $controller = $args{controller};
	my $current_route = $controller->current_route();

	my $self = bless({
		controller => $controller,
	}, $class);
	
	return (undef,$self);
}

sub find_resources
{
	my ($self, %args) = @_;
    my $config = NMISNG::Util::loadConfTable();
    my $logfile = $config->{'<nmis_logs>'} . "/nmis_mojo_api.log";
    my $logger  = NMISNG::Log->new(
        path => $logfile,
    );
    my @node_names; 
    my $nmisng = NMISNG->new(
	    config => $config,
        log => $logger,
    );
    my $noderec = $nmisng->get_nodes_model();
    map { push @node_names, $_->{name}} (@{$noderec->data});

    # print Dumper @node_names;
    return \@node_names;
  
	# my $time = scalar(localtime);
    # return $time;
}

sub all_resources
{
	return shift->find_resources(@_);
}



1;
