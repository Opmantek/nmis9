package NMISx;
use Mojo::Base 'Mojolicious';

use NMISx::Controller::Legacy;

sub startup {
  my $self = shift;
  my $r = $self->routes;

  my $url_base = "/cgi-nmis9";
  $ENV{NMIS_URL_BASE} = $url_base;

  $r->namespaces(['NMISx::Controller']);

  for my $script (keys %NMISx::Controller::Legacy::ROUTE_CONFIG) {
    $r->any("$url_base/$script")->to('Legacy#dispatch');
  }

  push @{$self->static->paths},  "/usr/local/nmis9/assets";
  push @{$self->static->paths},  "/usr/local/nmis9/htdocs";
}
1;
