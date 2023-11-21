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

package NMISMojo::CRUDController;

# abi and version reporting first
# BEGIN {
# 	our ($VERSION,$ABI,$MAGIC)=("5.491.0","4.0.0","DEADCHICKEN");

# 	if( scalar(@ARGV) == 1 && $ARGV[0] eq "--module-version" )
# 	{
# 		print __PACKAGE__." version=$VERSION\n".__PACKAGE__." abi=$ABI\n".__PACKAGE__." magic=$MAGIC\n";
# 		exit(0);
# 	}
# };

use Mojo::Base 'Mojolicious::Controller';
use strict;
# external
use URI::Escape;
use JSON::XS;
use Data::Dumper;

# for UTF-8 decoding
# https://stackoverflow.com/q/49343593
use Encode qw/encode_utf8 decode_utf8/;

sub index_resource
{
	my ($self) = @_;
	
	my $type = $self->param("type");
	my $dataclass = $self->param("data_class");

	eval "require $dataclass" if ($dataclass);
	$self->app->log->error("Error loading $dataclass: $@") if $@;
	$self->app->log->debug("Getting resource from dataclass $dataclass");
	my ($error_text, $resobj) = ($dataclass||$self)->load_resources(controller => $self);
    
	if ($error_text)
	{
		# fixme: do we need to return html, and if so, what?
		$self->render(json => $error_text);
		return;
	}

	my $callargs = {};
	my ($crud_data) = $resobj->all_resources(%$callargs);
    $self->render( json => $crud_data );
}

1;
