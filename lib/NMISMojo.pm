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
package NMISMojo;
use Mojo::Base 'Mojolicious';

use Data::Dumper;
use NMISNG::Util;

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

  ## Load plugins that are needed for app

  $self->plugin("NMISMojo::Plugin::SimpleAuth");
  $self->plugin("NMISMojo::Plugin::Helpers");
  
  ## create cookie for nmis
  my $config = NMISNG::Util::loadConfTable();
  if(my $secrets = [$config->{'auth_web_key'}]) {
    $self->secrets($secrets);
  }
  # load modules, this won't make it into stash so values are stored in app, this could be a bad thing to do...
	$self->module_code();
  #$self->module_code_mojo();
  # print Dumper $module_code;

  $self->hook(
    before_dispatch => sub {
      my $c = shift;
      my $user = $c->is_user_authenticated ? $c->current_user : undef;
      $c->stash(user => $user);
      $c->stash( moduleCode => $self->{moduleCode} );
      #$c->stash( moduleCodeMojo => $self->{moduleCodeMojo} );
      return $c;
    }
  );

	$r->route('/')->to( controller => "MainController", action => "login_view" )->name("login_page");
	
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


	# node selector endpoint
		# $charts_bridge->get('/node_selector')->over(authenticated_with_login_redirect => 1)->to(
		# 	controller => "ChartsController", action => "show_node_selector",sort_by => 'nodes.name',order => 'asc'
		# )->name("show_opCharts_node_selector");
  # migrated routes
  # This route is public
  $r->get('/')->to(controller => 'MainController', action => 'login_view');
  $r->get('/login')->to(controller => 'MainController', action => 'login_view');
  $r->post('/login')->to(controller => 'MainController', action => 'authenticate_user');
  
  # # $r->get('/nodes/:node_uuid')->to(controller => 'MainController', action => 'node_view');

# this sub does the auth-stuff
# to check user/pw and return true if all okay

  my $logged_in = $r->under (sub {
    my $c = shift;
    # Check if the user is authenticated
    if ($c->is_user_authenticated) {
        # Continue to the routes
        $c->render(template => 'index');
        return 1;
    } else {
        # Redirect to the login page if not authenticated
        #$c->stash('error' => 'Please login.');
        $c->redirect_to('/login');
        #$c->render(template => 'login', error =>'Please login.' );
        return 0;
    }
  });

  $r->get('/index')->to(controller => 'MainController', action => 'index');
  $logged_in->get('/nodes')->to(controller => 'MainController', action => 'nodes_view');
 
  #$r->get('/nodes')->to(controller => 'MainController', action => 'nodes_view');
  $r->any('/logout')->to(controller => 'MainController', action => 'logout');

  # Public REST API V1
	#my $api_v1_bridge = $api_bridge->under("/api/v1");
  my $api_bridge = $logged_in->under('/api/v1');
  $api_bridge->get('/welcome' => sub {
    my $c = shift;
    # API logic here
    my $data = { api => 'Hello Welcome to version 1 API!' };
    # Render a JSON response
    $c->render(json => $data);
  });

  $api_bridge->get('/nodes')->to(
			controller => "CRUDController",
			data_class => "NMISMojo::NodeData",
			action     => "index_resource"
	)->name("api_node_data");
}



1;
