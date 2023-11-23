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
  $self->render(template => 'index');
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
  

  my $config     = NMISNG::Util::loadConfTable();
  my $logfile = $config->{'<nmis_logs>'} . "/nmis_mojo_auth.log";
  my $logger  = NMISNG::Log->new(
    path => $logfile,
  );
  my $this_function = (caller(0))[3];
  $logger->info("$this_function");

  my $auth_user = $self->authenticate($usrname, $psswd);
  #print "self are ".Dumper($auth_user);
  if ($auth_user){
    $self->render(template => 'index', user =>$usrname);
  }
  else{
    $self->render(template => 'login', error =>'Invalid username/password combination!' );
  } 


  #$self->render(template => 'login', error =>$auth_key );
  #&index($self);
  # my $auth = NMISNG::Auth->new();
  # my $auth_user = $auth->user_verify($usrname, $psswd);
  # if ($auth_user){
  #   &index($self);
  # }
  # else{
  #     $self->render(template => 'login', error =>'Invalid username/password combination' );
  # }
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
1;