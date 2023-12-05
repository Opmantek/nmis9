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
package NMISMojo::Plugin::Helpers;

use base 'Mojolicious::Plugin';
use strict;
use NMISNG::Util;
use Compat::Modules;
use Data::Dumper;


sub register {
	# print "Dvars are ".Dumper(\@_);
	my ($plugin, $app, $config) = @_;

	# ugly helper that loads conf/opModules.nmis into the stash
	$app->helper( module_code => sub {
		my $self = shift;
		
		my $config = NMISNG::Util::loadConfTable();
		# the modules dd in menubar needs to know what modules are available
		my $M = Compat::Modules->new(nmis_base => $config->{'<nmis_base>'},
																nmis_cgi_url_base => $config->{'<cgi_url_base>'});
		my $moduleCode = $M->getModuleCode();
		#my $moduleCode = $M->getModules();
		# print "moduleCode is ".Dumper($moduleCode);
		$self->app->{moduleCode} = $moduleCode;
		$self->stash( moduleCode => $moduleCode);
		$self->render("layouts/menu", moduleCode => $moduleCode);
	});

	# ugly helper that loads conf/opModules.nmis into the stash
	$app->helper( module_code_mojo => sub {
		my $self = shift;
		
		my $config = NMISNG::Util::loadConfTable();
		# the modules dd in menubar needs to know what modules are available
		my $M = Compat::Modules->new(nmis_base => $config->{'<nmis_base>'},
																nmis_cgi_url_base => $config->{'<cgi_url_base>'});
		my $moduleCode = $M->getModuleCodeMojo();
		#my $moduleCode = $M->getModules();
		#print "moduleCode is ".__LINE__."\n".Dumper($moduleCode);
		$self->app->{moduleCodeMojo} = $moduleCode;
		$self->stash( moduleCodeMojo => $moduleCode);
		$self->render("layouts/menu", moduleCodeMojo => $moduleCode);
	});
}



1;