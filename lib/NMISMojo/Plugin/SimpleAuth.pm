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
			$logger->info("SimpleAuth::context_switch_worker_uid, already in cache")
					if($plugin->{_cookie_debug});
		}
		# TODO: return hash here, do something smart!!!
		$logger->info("SimpleAuth::context_switch_worker_uid, end, cookie_domain:", $c->app->sessions->cookie_domain()//'') if($plugin->{_cookie_debug});
		return $uid;
	});

	
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
