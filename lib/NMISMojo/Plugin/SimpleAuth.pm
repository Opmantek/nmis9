#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED
# BY OPMANTEK.
#
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
#
# This code is NOT Open Source
#
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND
# OPMANTEK LTD.
#
# Opmantek is a passionate, committed open source software company - we really
# are.  This particular piece of code was taken from a commercial module and
# thus we can't legally supply under GPL. It is supplied in good faith as
# source code so you can get more out of NMIS.  According to the license
# agreement you can not modify or distribute this code, but please let us know
# if you want to and we will certainly help -  in most cases just by emailing
# you a different agreement that better suits what you want to do but covers
# Opmantek legally too.
#
# contact opmantek by emailing code@opmantek.com
#
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
#
# *****************************************************************************
package NMISMojo::Plugin::SimpleAuth;

# BEGIN {
# 	our ($VERSION,$ABI,$MAGIC) = ("4.490.0","4.0.0","DEADCHICKEN");

# 	if( scalar(@ARGV) == 1 && $ARGV[0] eq "--module-version" ) {
# 		print __PACKAGE__." version=$VERSION\n".__PACKAGE__." abi=$ABI\n".__PACKAGE__." magic=$MAGIC\n";
# 		exit(0);
# 	}
# };

use base 'Mojolicious::Plugin';
use strict;
use List::Util qw(first);

use NMISNG::Auth;
use NMISNG::Util;
use NMISNG;
use NMISNG::Log;
use Data::Dumper;

sub register
{
	#print "Dvars are ".Dumper(\@_);
    my ($plugin, $app, $config) = @_;

	my $C     = NMISNG::Util::loadConfTable();
    my $logfile = $C->{'<nmis_logs>'} . "/nmis_mojo_auth.log";
	my $logger  = NMISNG::Log->new(
        path => $logfile,
    );
	my $this_function = (caller(0))[3];
	$logger->info("$this_function");
	open OFILEDUMP,">/tmp/SimpleAuth.txt";
	# print OFILEDUMP Dumper("plugin\n");
	# print OFILEDUMP Dumper($plugin);
	#print OFILEDUMP Dumper("app\n");
	#print OFILEDUMP Dumper($app);
	#print OFILEDUMP Dumper("config\n");
	#print OFILEDUMP Dumper($config);
	
	my $session_key = 'auth_data'; # for Mojolicious::Plugin::Authentication

	#$app->new_application_log("nmis_mojo_auth");

	$plugin->{_loaded_uid_and_domain} = undef; # fixme: not used anywhere?
	$plugin->{_loaded_user} = undef;
	$plugin->{_cookie_debug} = 1 if( $app->config->{cookie_debug} );
	my $cookiename = "omk";				# let's not use 'mojolicious' anymore...

	# sso: if configured, ONLY handle an sso-specific cookie
	# (ie. with the sso domain name embedded in the cookie name),
	# and do not interfere with the normal, non-sso cookie
	my $ssodomain = $plugin->_manage_sso_cookie_domain($app);
	if ($ssodomain)
	{
		$cookiename .= ".$ssodomain";
		$cookiename =~ s/\.+/./g;		# we want x.y.z, not x..y.z
	}
	$app->sessions->cookie_name($cookiename);

	my $user_extras = 'omkd_extras';
	$plugin->{AU} = NMISNG::Auth->new();
    
	#$plugin->{AU}->{log} = $logger;
    #$plugin->{AU} = NMISNG::Log->new(path => $logfile);
	# print OFILEDUMP Dumper("logger 100\n");
	# print OFILEDUMP Dumper($logger);
	# print OFILEDUMP Dumper("plugin 102\n");
	# print OFILEDUMP Dumper($plugin);
	$logger->info("SimpleAuth::register, cookie name was set to \"$cookiename\", cookie domain to \""
												.$app->sessions->cookie_domain().'"')
			if ($plugin->{_cookie_debug});


	$app->plugin('Mojolicious::Plugin::Authentication', {
		autoload_user=>1,
		session_key=>$session_key,

		load_user => sub {
			my ($c, $uid) = @_;
			my $user = $c->context_switch_worker_uid($uid);
			return $user;
		},

		# callback that returns uid or undef (if no good)
		validate_user => sub {
			my ($c, $username, $password, $extradata) = @_;

			# new authentication to worker means the cache should be cleared
			$logger->info("SimpleAuth::validate_user, clearing loaded cache.");
			$plugin->{_loaded_uid} = undef;
			$plugin->{_loaded_user} = undef;
  			
			my ($verified, $extras) = $plugin->{AU}->user_verify($username, $password);
			if ($verified)
			{
				$logger->info("SimpleAuth::validate_user, authentication success for username=$username");
				$c->session($user_extras => $extras) if($extras);
				my $uid = $username;
				# this is what we get back when load user is called
				return $uid;
			}
			else{
				$logger->info("SimpleAuth::validate_user, authentication failure for username=$username");
			}
			
			return;
		}
	});

	# my $expire_seconds = $app->config->{'auth_expire_seconds'} // 3600;
	# $app->sessions->default_expiration($expire_seconds);
	
	# #httponly, secure and same site:
    # my $samesite_cookie_value = ucfirst($app->config->{'auth_samesite_cookie'}) || "Strict";
    # my $secure_cookie = getBool($app->config->{'auth_secure_cookie'} || "false");
    # $app->sessions->samesite($samesite_cookie_value);
    # if ($samesite_cookie_value ne "Strict")
    # {
    #     #SameSite=None or Lax then the Secure attribute must also be set-OMK-9310
    #     $secure_cookie = 1;
    #     $logger->debug("SimpleAuth setting secure cookie to $secure_cookie as samesite value is not Strict");
    # }
    
    #$app->sessions->secure(1) if ($secure_cookie);


	# take the UID requested and load it into the auth system and this plugin instance
	# also ensure that the sso cookie domain is ok for the type of request, ie. tunnelled/localhost vs. fqdn
	$app->helper( context_switch_worker_uid => sub {
		my ($c, $uid) = @_;
		my ($user,$domain);

		$logger->info("SimpleAuth::context_switch_worker_uid, start, cookie_domain: "
													. $c->app->sessions->cookie_domain()//'')
				if($plugin->{_cookie_debug});

		# we must re-evaluate the cookie domain for every request (b/c setting is app- or worker-wide,
		# but does depend on the actual request - on validate_user is NOT enough, nor is on context change!
		# scenario: one worker A, first serves user X via http://fqdn -> cookie domain on,
		# then serves same user X but cron+localhost -> cookie domain must be OFF!
		#$plugin->_manage_sso_cookie_domain($c);

		# create a cache here as asking for the current user ends up calling this code
		if( !$plugin->{_loaded_uid} || $plugin->{_loaded_uid} ne $uid )
		{
			$logger->info("SimpleAuth::context_switch_worker_uid, putting user into cache, cookie_domain is:"
														.$c->app->sessions->cookie_domain()//'')
					if($plugin->{_cookie_debug});

			#$user = $c->set_user( uid => $uid );
			# if( $user )
			# {
			# 	$plugin->{_loaded_uid} = $uid;
			# 	# loaded_user currently is not really used, should be in the future
			# 	$plugin->{_loaded_user} = $user;
			# 	$logger->debug("SimpleAuth::context_switch_worker_uid, setting user:".$plugin->{_loaded_uid});
			# }
			# else
			# {
			# 	$logger->debug("SimpleAuth::context_switch_worker_uid, clearing cache, uid:".$uid);
			# 	$plugin->{_loaded_uid} = undef;
			# 	$plugin->{_loaded_user} = undef;
			# }
		}
		else
		{
			$user = $plugin->{_loaded_user};
			print OFILEDUMP Dumper("user 203\n");
			print OFILEDUMP Dumper($user);
			$logger->info("SimpleAuth::context_switch_worker_uid, already in cache")
					if($plugin->{_cookie_debug});
		}
		# TODO: return hash here, do something smart!!!
		$logger->info("SimpleAuth::context_switch_worker_uid, end, cookie_domain:", $c->app->sessions->cookie_domain()//'') if($plugin->{_cookie_debug});
		return $uid;
	});

	# $app->helper( current_user_object => sub {
	# 	return $plugin->{_loaded_user} // {};
	# });

	#Returns the current access priv, this is used by the front end to stop some actions being shown for msp users
	# $app->helper(user_display_notifications => sub {
	# 	my ($self) = @_;
	# 	#default to show notifcations
	# 	my $show_notif = 1;
		
	# 	if(exists $plugin->{_loaded_user})
	# 	{
	# 		my $user_priv = $plugin->{_loaded_user}->{priv} // undef;
	# 		my $show_notif_pref = getBool($self->config->{omk_gui_show_user_errors} || 'true');
	# 		$show_notif = 0 if($user_priv ne "administrator" and $show_notif_pref eq 0);
	# 	}
	# 	return $show_notif;
	# });


	# $app->helper( set_user => sub {
	# 	my ($c,%args) = @_;
	# 	# check both args as the name was changed but need backwards compat
	# 	my $uid = $args{uid} // $args{user};

	# 	$plugin->{AU}->SetUser(undef);
	# 	if( $plugin->{AU}->SetUser( $uid ) )
	# 	{
	# 		# found in old auth model
	# 		return $plugin->{AU}->GetUserInfo();
	# 	}
	# 	elsif( $app->{rbac_enabled} )
	# 	{
	# 		# search in new auth model
	# 		my ($error_text,$resobj) = Opmantek::RBACData->load_resources(type => "user", controller => $c);
	# 		die $error_text if($error_text);
	# 		my $user = $resobj->find_resource(type => "user", name => $uid);

	# 		# load the users privs, tell the system this is an rbac user
	# 		$user->{auth_mode_rbac} = 1;
	# 		$resobj->{rbac}->set_default_user(user => $uid);

	# 		# load the users groups, if they have any, which are held under a specific path
	# 		# NOTE: uses RBACData's rbac object so we don't have to create our own, not fully nice
	# 		my ($group_error,@paths) = $resobj->rbac_object->where_can_user_do(user => $uid, action => 'read', path => ['root','opcharts','group'], directonly=>1 );
	# 		my @groups = ();
	# 		for my $path (@paths)
	# 		{
	# 			push @groups, $path->[3] if( $path->[2] eq 'group' && @$path > 3 );
	# 		}

	# 		if( @groups > 0 )
	# 		{
	# 			$logger->debug("SimpleAuth::set_user, setting users groups:".join(',', @groups));
	# 			$plugin->{AU}->SetGroups( grouplist => \@groups );
	# 		}

	# 		return $user;
	# 	}
	# 	else
	# 	{
	# 		return;
	# 	}
	# });

	# returns info hash from auth module, has things like privs, groups, etc. mostly nmis specific info
	# $app->helper( get_current_user_info => sub {
	# 	my ($c,%args) = @_;
	# 	return $plugin->{AU}->GetUserInfo();
	# });	

	# set up all authentication-related routes for this particular application
	# requires args router, application key, name and version;
	# $app->helper( register_simple_auth_routes => sub {
	# 	my $self = shift;
	# 	my %args = @_;
	# 	my $r = $args{router};
	# 	my $application_key = $args{application_key};
	# 	my $application_name = $args{application_name};
	# 	my $application_version = $args{application_version};

	# 	# just render the login form - also sets up redirect_url for subsequent post
	# 	$r->get('/login')->to(cb => sub {
	# 		my $self = shift;
	# 		#$self->module_code();
	# 		my $redirect_url = $self->url_for("login_page");
	# 		$redirect_url = $self->req->param("redirect_url") if $self->req->param("redirect_url");

    #         $self->render(template => 'login');

	# 		# $self->render('login', title => $self->msp_title(),
	# 		# 							redirect_url => $redirect_url,
	# 		# 							login_action => $application_key."_login",
	# 		# 							application_key => $application_key,
	# 		# 							application_name => $application_name,
	# 		# 							application_version => $application_version);
	# 		# 																		 })->name($application_key."_login");
    #     });
	# 	# receives a posted login form, performs the username-password verification
	# 	# reacts to json/api request with json and 200 if auth ok, or 403 if not.
	# 	# for a browser request: if ok, redirects to the given redirect_url with 302;
	# 	# otherwise sends 403 and rerenders the login form (with extra error text)
	# 	$r->post('/login')->to(cb => sub {
	# 		my $self = shift;
    #         print Dumper ($self);
	# 		my $redirect_url = $self->url_for("login_page");
	# 		# $redirect_url = $self->req->param("redirect_url") if $self->req->param("redirect_url");
	# 		# # make sure the redirect_url is relative
	# 		# # first don't allow //
	# 		# if( $redirect_url =~ /\/\/(.*)$/)
	# 		# {
	# 		# 	$redirect_url = $1;
	# 		# }
	# 		# # then take everything after the first slash
	# 		# my ($before_slash,$after_slash) = split( /\//, $redirect_url, 2);
	# 		# $redirect_url = '/'.$after_slash;
	# 		# $redirect_url =~ s/^\/+//;
	# 		# $redirect_url = '/' . $redirect_url;

	# 		if( $self->authenticate($self->req->param('username'), $self->req->param('password')) )
	# 		{
	# 			#$self->respond_to( html => sub { $self->redirect_to($redirect_url); });
    #            $self->render(template => 'index');
	# 		}
	# 		else
	# 		{
	# 			$self->respond_to ( html => sub {
    #                                         # $self->module_code();

    #                                         my $errortext = $plugin->{AU}->can("error_text")? $plugin->{AU}->error_text : undef;
    #                                         $errortext ||= "There was an error authenticating, please try again.";

    #                                         $self->stash(error => $errortext);
    #                                         $self->render('login',
    #                                                                     status => 403,
    #                                                                     # title => $self->msp_title(),
    #                                                                     redirect_url => $redirect_url,
    #                                                                     # login_action => $application_key."_login",
    #                                                                     # application_key => $application_key,
    #                                                                     # application_name => $application_name,
    #                                                                     # application_version => $application_version
    #                                                                     );
    #                                     } );
    #         }
    #     });
    # });

	# 	# this endpoint is for delegated token auth verification - which uses get
	# 	# and token in url because no forms involved or desired
	# 	# if successful, redirects to the application home page
	# 	# (or redirect_url url param) if not successful, render the
	# 	# normal username-password authentication form
	# 	$r->get("$application_key/login/:token")->to(cb => sub {
	# 		my ($self) = @_;

	# 		my $redirect_url = $self->url_for("index_".$application_key);
	# 		$redirect_url = $self->req->param("redirect_url") if $self->req->param("redirect_url");

	# 		if ($self->authenticate(undef, undef, { token => $self->param("token") }))
	# 		{
	# 			$self->redirect_to($redirect_url);
	# 		}
	# 		else
	# 		{
	# 			$self->module_code();

	# 			my $errortext = $plugin->{AU}->can("error_text")? $plugin->{AU}->error_text : undef;
	# 			$errortext ||= "There was an error authenticating, please try again";

	# 			$self->stash(error => $errortext);
	# 			$self->render('authentication/login',
	# 										title => $self->msp_title(),
	# 										redirect_url => $redirect_url,
	# 										login_action => $application_key."_login",
	# 										application_key => $application_key,
	# 										application_name => $application_name,
	# 										application_version => $application_version);
	# 		}
	# 																							 });

	# 	# this endpoint logs the user out - a bit unclean as method get is used,
	# 	# which shouldn't have side effects
	# 	$r->get($application_key.'/logout')->to(cb => sub {
	# 		my $self = shift;
	# 		$self->logout();

	# 		# clear cache so next time this user accesses the system they are fully re-loaded
	# 		$plugin->{_loaded_uid} = undef;
	# 		$plugin->{_loaded_user} = undef;

	# 		$self->flash(success => "Successfully logged out");
	# 		$self->redirect_to( $application_key."_login" );
	# 																					})->name($application_key."_logout");

	# });
	close (OFILEDUMP);
}


# internal function re-evaluates the sso situation (for a request if possible),
# and applies/disables the cookie domain accordingly to the application object
#
# note: the app's auth_log must have been set up before this function is called
#
# args: self (the plugin) and a controller (if called for a request) OR app (when called early),
# returns: cookie domain if it was set on, undef otherwise,
sub _manage_sso_cookie_domain
{
	my ($self, $app_ctrl) = @_;

    my $C     = NMISNG::Util::loadConfTable();
    my $logfile = $C->{'<nmis_logs>'} . "/nmis_mojo_auth.log";
    my $logger  = NMISNG::Log->new(
        path => $logfile,
    );

	my ($app, $ctrl);
	if ($app_ctrl->isa("Mojolicious::Controller"))
	{
		$ctrl = $app_ctrl;
		$app = $ctrl->app;
	}
	else
	{
		$ctrl = undef;
		$app = $app_ctrl;
	}
	my $config = $app->config;

	#my $ssodomain = $config->{auth_sso_domain};
	my $ssodomain = ".opmantek.net"; # TODO Change it according to config
	my $candosso = ($ssodomain and scalar(split(/\./, $ssodomain)) >= 3); # two+ dots required for the cookie

	if (!$candosso)
	{
		# log this at info level, once when run during startup
		$logger->info("SimpleAuth::_manage_sso_cookie_domain, SSO ".($ssodomain? "not possible (less than two dots in auth_sso_domain config)"
																 : "not configured (no auth_sso_domain config)"))
				if (!$ctrl);
		$app->sessions->cookie_domain(undef);
		return undef;
	}
	else
	{
		# called early/during registration? then no further magic required
		if (!$ctrl)
		{
			# again log at info level, once during startup
			$logger->info("SimpleAuth::_manage_sso_cookie_domain, SSO configured (for domain $ssodomain), enabling SSO cookie domain");
			$app->sessions->cookie_domain($ssodomain);
		}
		# here's why this function is required in the first place
		# if you serve a cookie with domain=.x.y.z but the actual access
		# is via localhost then useragents will IGNORE that cookie altogether as 'not meant for them'
		# this breaks api accesses, e.g. via cron
		#
		# solution: for such connections serve the cookie without domain.
		# 'such connections' === request host doesn't contain the domain as suffix
		#
		# unfortunately the cookie domain setting is app-wide (or at least web-worker-wide), so we need to re-decide
		# this for every request, not just on authenticate... :-(
		else
		{
			my $host = $ctrl->tx->req->headers->header('x-forwarded-host') || $ctrl->tx->req->url->to_abs->host;

			(my $suffix = $ssodomain) =~ s/^\.//;			# re-affirmed by regex
			# domain .x.y -> a.x.y is ok, foobarx.y is not, nor is localhost, 127.0.0.1 or other.doma.in
			if ($host !~ /\.$suffix(:\d+)?$/i) # ignore :portnumber
			{
				$logger->debug("SimpleAuth::_manage_sso_cookie_domain, SSO configured (for domain $suffix) but non-matching access (via $host), disabling SSO cookie domain for this request")
						if ($self->{_cookie_debug});
				$app->sessions->cookie_domain(undef);
				return undef;
			}
			else
			{
				$logger->debug("SimpleAuth::_manage_sso_cookie_domain, SSO configured (for domain $suffix), access (via $host) matches, enabling SSO cookie domain")
						if ($self->{_cookie_debug});
				$app->sessions->cookie_domain($ssodomain);
			}
		}
	}
	return $ssodomain;
}


1;
