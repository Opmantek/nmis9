package NMISMojo;
use Mojo::Base 'Mojolicious';
use Data::Dumper;

# This method will run once at server start
sub startup {
  my $self = shift;
  # Router
  my $r = $self->routes;

  my $url_base = "/cgi-nmis9";
  #Overide the config 
  $ENV{NMIS_URL_BASE} = $url_base;

  $self->plugin(CGI => [ "$url_base/nmiscgi.pl" => "/usr/local/nmis9/cgi-bin/nmiscgi.pl" ]);

  $self->plugin(CGI => [ "$url_base/access.pl" => "/usr/local/nmis9/cgi-bin/access.pl" ]);
  $self->plugin(CGI => [ "$url_base/community_rss.pl" => "/usr/local/nmis9/cgi-bin/community_rss.pl" ]);
  $self->plugin(CGI => [ "$url_base/config.pl" => "/usr/local/nmis9/cgi-bin/config.pl" ]);
  $self->plugin(CGI => [ "$url_base/events.pl" => "/usr/local/nmis9/cgi-bin/events.pl" ]);
  $self->plugin(CGI => [ "$url_base/find.pl" => "/usr/local/nmis9/cgi-bin/find.pl" ]);
  $self->plugin(CGI => [ "$url_base/ip.pl" => "/usr/local/nmis9/cgi-bin/ip.pl" ]);
  $self->plugin(CGI => [ "$url_base/logs.pl" => "/usr/local/nmis9/cgi-bin/logs.pl" ]);
  $self->plugin(CGI => [ "$url_base/menu.pl" => "/usr/local/nmis9/cgi-bin/menu.pl" ]);
  $self->plugin(CGI => [ "$url_base/model_policy.pl" => "/usr/local/nmis9/cgi-bin/model_policy.pl" ]);
  $self->plugin(CGI => [ "$url_base/models.pl" => "/usr/local/nmis9/cgi-bin/models.pl" ]);
  $self->plugin(CGI => [ "$url_base/modules.pl" => "/usr/local/nmis9/cgi-bin/modules.pl" ]);
  $self->plugin(CGI => [ "$url_base/network.pl" => "/usr/local/nmis9/cgi-bin/network.pl" ]);
  $self->plugin(CGI => [ "$url_base/nodeconf.pl" => "/usr/local/nmis9/cgi-bin/nodeconf.pl" ]);
  $self->plugin(CGI => [ "$url_base/node.pl" => "/usr/local/nmis9/cgi-bin/node.pl" ]);
  $self->plugin(CGI => [ "$url_base/opstatus.pl" => "/usr/local/nmis9/cgi-bin/opstatus.pl" ]);
  $self->plugin(CGI => [ "$url_base/outages.pl" => "/usr/local/nmis9/cgi-bin/outages.pl" ]);
  $self->plugin(CGI => [ "$url_base/rrddraw.pl" => "/usr/local/nmis9/cgi-bin/rrddraw.pl" ]);
  $self->plugin(CGI => [ "$url_base/services.pl" => "/usr/local/nmis9/cgi-bin/services.pl" ]);
  $self->plugin(CGI => [ "$url_base/setup.pl" => "/usr/local/nmis9/cgi-bin/setup.pl" ]);
  $self->plugin(CGI => [ "$url_base/snmp.pl" => "/usr/local/nmis9/cgi-bin/snmp.pl" ]);
  $self->plugin(CGI => [ "$url_base/tables.pl" => "/usr/local/nmis9/cgi-bin/tables.pl" ]);
  $self->plugin(CGI => [ "$url_base/tools.pl" => "/usr/local/nmis9/cgi-bin/tools.pl" ]);
  $self->plugin(CGI => [ "$url_base/view-event.pl" => "/usr/local/nmis9/cgi-bin/view-event.pl" ]);

  #serve cgi nmis9 assets
  $r->any('/menu9/:type/*whatever' => sub {
    my $c = shift;
    my $whatever = $c->param('whatever');
    my $type = $c->param('type');
    my $file = $c->app->home->child('menu',$type, $whatever );

    # Serve file if it exists, otherwise render a 404 not found
    #TODO use mojo static and not full paths!
    if (-f $file && -r _) {
      $c->reply->file($file);
    } else {
      $c->reply->not_found;
    }
  });

  #serve our cached images
  #Should have Auth
  $r->any('/nmis9/cache/#image' => sub {
    my $c = shift;
    my $image = $c->param('image');
    my $file = $c->app->home->child('htdocs','cache', $image );
    if (-f $file && -r _) {
      $c->reply->file($file);
    } else {
      $c->reply->not_found;
    }
  });

  #serve our reports
  #TODO needs AUTH
  $r->any('/nmis9/reports/#report' => sub {
    my $c = shift;
    my $report = $c->param('report');
    my $file = $c->app->home->child('htdocs','reports', $report );
    if (-f $file && -r _) {
      $c->reply->file($file);
    } else {
      $c->reply->not_found;
    }
  });

  # migrated routes
  $r->get('/')->to(controller => 'MainController', action => 'index');
  $r->get('/login')->to(controller => 'MainController', action => 'login_view');

}
1;
