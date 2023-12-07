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

# this renders the show template to display a single resource
# if json requested, renders a json dump
# requires: parameter type,
# optional param data_class (if no subclass or if it doesn't glue up load_resources)
# parameter thisresource (ref of given resource)
# or parameter name (handed to find_resource)
# optional param $type, used for auto-generated charts/maps so they can be shown full-screen,
#    is the resource definition, which is used instead of loading
sub show_resource
{
	my ($self) = @_;
	my $type = $self->param("type");
	my $dataclass = $self->param("data_class");
	my $show_resource = $self->param($type) if ($type);
	my $api_type = $self->param("api_type");
	eval "require $dataclass" if ($dataclass);
	$self->app->log->error("Error loading $dataclass: $@") if $@;
	my ($error_text,$resobj) = ($dataclass||$self)->load_resources(type => $type, controller => $self);

	if ($error_text)
	{
		# fixme: do we need to return html, and if so, what?
		$self->render ( json => { error => $error_text },
										status => 418 );
		return;
	}

	my $lookup = $self->param("name");
	my $thisres = $self->param("thisresource");
	if( defined($show_resource) ) {
		# expects show_resource to be valid unicode, which at this point it is.
		$thisres = JSON::XS->new->decode($show_resource);
		$thisres->{name} = $lookup;
	}
	elsif (!$thisres)
	{

		my $result = $resobj->find_resource(name => $lookup);
		if (defined($api_type)) {
			if(!$result)
			{
				$self->render ( json => { error => "No matching resources found" },
										status => 404 );
				return;
			}
			else
			{
				$thisres = $result;
			}
			#remove unneeded props and make the id not mongo style
			if (exists ($thisres->{_id}))
			{
				$thisres->{id} = $thisres->{_id};
				delete $thisres->{_id};
			}
			# foreach my $key (qw(current_user_privileges rbac_path))
			# {
			# 	delete $thisres->{$key} if(exists $thisres->{$key});
			# }
		}
		else
		{
			$thisres = $result;
		}
	}
	else
	{
		$lookup = $resobj->name_of(thisresource => $thisres);
	}

	# NOTE: backwards compat break here, 3.0.0 -> 3.0.4 will not work with this !!!! !#@!#!@!@#$
	#$self->stash( context_list =>  $self->calculate_context_list() );

	$self->respond_to(
		json => sub {
			$self->render( json => $thisres ),
		},
		# html => sub {
		# 	$self->render("resources/$type/show",
		# 								crud_data => $thisres,
		# 								name => $lookup);
		# }
		);
}

1;
