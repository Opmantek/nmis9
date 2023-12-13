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
package NMISMojo::MainController;
use strict;
use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;
use Compat::NMIS;
use base 'Mojolicious::Plugin';
use NMISNG::Auth;
  
#our index route
sub index {
  my $self = shift;
  
  if ($self->is_user_authenticated) {
    $self->render(template => 'index');
  }
  else{
    $self->render(template => 'login', error =>'Please login!' );
  }
}


sub login_view {
  my $self = shift;
  $self->render(template => 'login');
}

# authenticate user using nmis auth
sub authenticate_user {
  my $self = shift;
  #print "self are ".Dumper($self);
  # Get the user name and password from the login page
  my $usrname = $self->param('username');
  my $psswd = $self->param('password');
  

  # my $config     = NMISNG::Util::loadConfTable();
  # my $logfile = $config->{'<nmis_logs>'} . "/main_controller.log";
  # my $logger  = NMISNG::Log->new(
  #   path => $logfile,
  # );

  my $nmisng = $self->get_nmisng_obj();
  my $this_function = (caller(0))[3];
  $nmisng->log->info("$this_function");

  my $auth_user = $self->authenticate($usrname, $psswd);
  #print "self are ".Dumper($auth_user);
  if ($auth_user){
     $self->redirect_to('index');
    #$self->render(template => 'index', user =>$usrname);
  }
  else{
    $self->render(template => 'login', error =>'Invalid username/password combination!' );
  } 
}

sub nodes_view {
  my $self = shift;

  # send the default list of all nodes
  my $NT = Compat::NMIS::loadNodeTable(); # load node table 
  my @keys = keys %$NT;
  $self->stash ( 'keys' => \@keys );
  $self->render(template => 'nodes');
}

sub render_not_found {
  my $self = shift;
  $self->render(template => 'not_found');
}


sub logout {
  my $self = shift;
  $self->session(expires => 1); #kill the session
  $self->redirect_to('/');
};

sub get_nmisng_obj
{
  my $self = shift;
  my $config = NMISNG::Util::loadConfTable();
  my $logfile = $config->{'<nmis_logs>'} . "/main_controller.log";
  my $logger  = NMISNG::Log->new(
      path => $logfile,
  );

  my $nmisng = NMISNG->new(
    config => $config,
      log => $logger,
  );
  
  return $nmisng;
}

sub node_search {
  my $self = shift;
	# the query param
	my $q = $self->param("q");
  # print Dumper "q = $q";
  if ($self->is_user_authenticated) {

    # node_quick_search
    my $nmisng = $self->get_nmisng_obj();

    #Get model data for nodes
    my $md = $nmisng->get_nodes_model();
    
    if (my $error = $md->error)
    {
      $nmisng->log->error("Failed to lookup nodes: $error");
      $self->render(json => { error => "Failed to lookup nodes: $error" });
      return;
    }

    my $data = $md->data();
    
    # get uuid and name for nodes
    my %nodes_data = map {($_->{name} => $_->{uuid}) } @$data;
    # regex partial hash key match
    my @matching_keys = grep { /$q/ } keys %nodes_data;
    
    if (scalar(@matching_keys) == 0 ) {
      $self->render(json => { error =>"No node data found for node $q"});
      return;
    }
    else
    {
      #filter data based on query parameter
      delete $nodes_data{$_} for grep !/$q/, keys %nodes_data;

      # get the format which frontend requires
      my @filtered_nodes;
      while(my($name, $uuid) = each %nodes_data) { 
        my $rec = {};
        $rec->{name} = $name;
        $rec->{uuid} = $uuid;
        push @filtered_nodes, $rec;
      }
      #$nmisng->log->info("filtered_nodes".Dumper(@filtered_nodes));
      #print Dumper \@filtered_nodes;
      $self->render(json => \@filtered_nodes);
    }

    
  }
  else{
    $self->render(template => 'login', error =>'Please login!' );
  }
  
}
1;