package NMISMojo::MainController;
use strict;
use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;
use Compat::NMIS;
use base 'Mojolicious::Plugin';
use NMISNG::Auth;
use NMISNG::Util;
use NMISNG;
use NMISNG::Log;


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
    $self->render(template => 'login', error =>'Invalid username/password combination' );
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
  $self->session(expires => 1);
  $self->redirect_to('/');
};
1;