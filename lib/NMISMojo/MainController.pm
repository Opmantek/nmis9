package NMISMojo::MainController;
use strict;
use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;
use Compat::NMIS;

#our index route
sub index {
  my $self = shift;
  $self->render(template => 'index');
}


sub login_view {
  my $self = shift;
  $self->render(template => 'login');
}


sub valid_user_check{
  my $self = shift;

    # Hardcoding users for now
    my %validUsers = ( "nmis" => "##########");

    # Get the user name and password from the page
    my $user = $self->param('username');
    my $password = $self->param('password');

    if($validUsers{$user}){
      if($validUsers{$user} eq $password){
        $self->session(is_auth => 1);
        $self->session(username => $user);
        &index($self);
      }
      else{
        $self->render(template => 'login', error =>'Invalid username or password' ); 
      }
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

sub node_view {
  my $self = shift;
  my $node_name   = $self->param('node_name');
  
  # send the default list of all nodes
  
  #$self->cgi("cgi-nmis9/network.pl?act=network_node_view&node=$node_name");
  #$self->render(template => 'node', node_name => $node_name);
  #   my @keys = keys %$NT;
  #   $self->stash ( 'keys' => \@keys );
  #   $self->render(template => 'node');
}

sub render_not_found {
  $self->render(template => 'not_found');
}
1;