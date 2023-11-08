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
  if($self->session('is_auth')){
    &index($self);
  }
  else{
    $self->render(template => 'login');
  }
  
}

# authnticate user using nmis auth
sub user_login {
  my $self = shift;

  # Get the user name and password from the login page
  my $usrname = $self->param('username');
  my $psswd = $self->param('password');
  
  
  my $auth = NMISNG::Auth->new();
  my $auth_user = $auth->user_verify($usrname, $psswd);
  if ($auth_user){
    &index($self);
  }
  else{
       $self->render(template => 'login', error =>'User not found' );
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

# sub node_view {
#   my $self = shift;
#  my $node_uuid   = $self->param('node_uuid');
#   # send the default list of all nodes
  
#   $self->render(template => 'node', UUID => $node_uuid);
# #   my @keys = keys %$NT;
# #   $self->stash ( 'keys' => \@keys );
# #   $self->render(template => 'node');
# }

sub render_not_found {
  my $self = shift;
  $self->render(template => 'not_found');
}
1;