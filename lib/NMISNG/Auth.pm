#
#    Auth.pm - Web authorization libraries and routines
#
#    Copyright (C) 2005 Robert W. Smith
#        <rwsmith (at) bislink.net> http://www.bislink.net
#
#    Portions Copyrighted by the following entities
#
#       Copyright (C) 2000,2001,2002 Steve Shipway
#
#       Copyright (C) 2000,2001 Sinclair InterNetworking Services Pty Ltd
#          <nmis@sins.com.au> http://www.sins.com.au
#
#	 Modified by Jan van Keulen for NMIS5.
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#    Enough of the legal stuff.
#
##############################################################################
#
#   Auth.pm
#   Auth.pm is a OO Perl module implementing a class module with methods
#   to enforce and perform user authentication and to a lesser degree, through
#   cooperation with another class module, provide some authorization.
#
#   I originally wrote this modules for a client that needed user-level
#   authentication and authorization with the NMIS package to segregate the
#   server groups from the router groups and then some.
#
#   The authentication routines originally came from Steve Shipway's very well
#   written and designed (and coded) Routers2.cgi program. I took ("lifted") several
#   of his routines, verify_id, user_verfity, file_verify, ldap_verify, and
#   generate_cookie, and provided a wrapper so that they would be more easily
#   incorporated in NMIS and more generally into other web programs needing
#   user authentication.
package NMISNG::Auth;
our $VERSION = "2.0.0";

use strict;

use NMISNG::Util;
use NMISNG::Notify;											# for auth lockout emails

use MIME::Base64;
use Digest::SHA;								# for cookie_flavour omk
use Data::Dumper;
use CGI qw(:standard);					# needed for current url lookup, http header, plus td/tr/bla_field helpery
use Time::ParseDate;
use File::Basename;
use Crypt::PasswdMD5;						# for the apache-specific md5 crypt flavour
use JSON::XS;

# You MUST set config's auth_web_key so that cookies are unique for your site. this fallback key is NOT safe for internet-facing sites!
my $CHOCOLATE_CHIP = '5nJv80DvEr3N/921tdKLk+fCjGzOS5F9IqMFhugxVHIguRC8PJKN4f2JJgcATkhv';

# record non-standard "conf" ONLY if confname is given as argument
# attention: arg conf is a LIVE config (confname is the name)
# args:
sub new
{
	my ($this, %arg) = @_;
	my $class = ref($this) || $this;

	my $config = ref($arg{conf}) eq "HASH"? $arg{conf}: NMISNG::Util::loadConfTable();

	my $self = bless({
		_require => (defined $config->{auth_require})? $config->{auth_require} : 1,
		dir => $arg{dir},
		user => undef,
		config => $config, # a live config, loaded or passed in by the caller
		confname => $arg{confname},	# optional
		banner => $arg{banner},
		priv => undef,
		privlevel => 0, # default all
		cookie_flavour => $config->{auth_cookie_flavour} || 'nmis',
		groups => undef,
		all_groups_allowed => undef,
		debug => NMISNG::Util::getbool($config->{auth_debug}),
									 }, $class);

	return $self;
}

# getter for the require flag
sub Require {
	my $self = shift;
	return $self->{_require};
}

# setter-getter for the debug flag
# new value must be defined, but 0 is obviously ok
sub debug {
	my ($self, $newvalue) = @_;

	$self->{debug} = getbool($newvalue)
			if defined ($newvalue);
}


#----------------------------------
#
#	Check Button identifier agains priv of user
#	$AU->CheckButton('identifier') where $AU is object of user
#
sub CheckButton {
	my $self = shift;
	my $identifier = lc shift; # key of Access table is lower case

	return 1 unless $self->{_require};

	my $AC = Compat::NMIS::loadGenericTable('Access'); # get pointer of Access table

	my $perm = $AC->{$identifier}{"level$self->{privlevel}"};

	NMISNG::Util::logAuth("CheckButton: $self->{user}, $identifier, $perm");

	return $perm;
}


#----------------------------------
#
#	$AU->CheckAccess('identifier','option') where identifier must be declared in Access table
#	option can be 'check' then only status is returned
#	option can be 'header' then header is printed
#
#	if result is false then message is displayed
#

sub CheckAccess {
	my $self = shift;
	my $cmd = shift;
	my $option = shift;

	my @cookies = ();

	# check if authentication is required
	return 1 if not $self->{config}->{auth_require}; # fixme why check both? that's really really silly
	return 1 unless $self->{_require};

	if ( ! $self->{user} ) {
		do_force_login("Authentication is required. Please login");
		exit 0;
	}

	if ( $self->CheckAccessCmd($cmd) ) {
		NMISNG::Util::logAuth("CheckAccessCmd: $self->{user}, $cmd, 1") if $option ne "check";
		return 1;
	}
	else {
		NMISNG::Util::logAuth("CheckAccessCmd: $self->{user}, $cmd, 0") if $option ne "check";
	}
	return 0 if $option eq "check"; # return the result of $self->CheckAccessCmd

	# Authorization failed--put access denied page and stop

	print CGI::header({type=>'text/html',expires=>'now'}) if $option eq 'header'; # add header

	print CGI::table(CGI::Tr(CGI::td({class=>'Error',align=>'center'},"Access denied")),
			CGI::Tr(CGI::td("Authorization required to access this function")),
			CGI::Tr(CGI::td("Requested access identifier is \'$cmd\'"))
		);

	exit 0;
}



##########################################################################
#
# The following routines in whole and in part are from Routers2.cgi and
# are copyrighted by Steve Shipway and included and used herein with
# permission.
#
# Copyright (C) 2000, 2001, 2002 Steve Shipway
#
# The following routines are covered by this copyright and the GNU GPL.
#    verify_id
#    user_verify
#    _file_verify
#    _ldap_verify
#    generate_cookie
#
# All Java code include herein is also courtesy of Steve Shipway.


# produces weak checksum from username,
# remote address (or debug/fake auth_debug_remote_addr) and configured key/secret
# used only for auth_cookie_flavour 'nmis'
#
# args: username
# returns: string
sub get_cookie_token
{
	my $self = shift;
	my($user_name) = @_;

	my $token;
	my $remote_addr = CGI::remote_addr();
	if( $self->{config}{auth_debug} ne '' && $self->{config}{auth_debug_remote_addr} ne '' ) {
		$remote_addr = $self->{config}{auth_debug_remote_addr};
	}

	my $web_key = $self->{config}->{'auth_web_key'} // $CHOCOLATE_CHIP;
	NMISNG::Util::logAuth("DEBUG: get_cookie_token: remote addr=$remote_addr, username=$user_name, web_key=$web_key")
			if ($self->{debug});

	# generate checksum
	my $checksum = unpack('%32C*', $user_name . $remote_addr . $web_key);
	NMISNG::Util::logAuth("DEBUG: get_cookie_token: generated token=$checksum")
			if ($self->{debug});

	return $checksum;
}

# returns the configured ssh domain (if any), or a blank string
sub get_cookie_domain
{
	my $self = shift;
	my $maybe = $self->{config}->{auth_sso_domain};

	return $maybe if (defined $maybe and $maybe ne ".domain.com"); # must skip old default value
	return '';
}

# produces nmis-style cookie name
# only used when auth_cookie_flavour is set to nmis
sub get_cookie_name
{
	my $self = shift;
	my $name = "nmis_auth".$self->get_cookie_domain;
	return $name;
}

# verify_id reads an existing cookie and verifies its authenticity
# returns: verified username or blank string if invalid/errors
sub verify_id
{
	my $self = shift;

	# retrieve the cookie
	my $cookie = CGI::cookie( ($self->{cookie_flavour} eq "nmis")?
														$self->get_cookie_name()
														: "mojolicious" );
	if(!defined($cookie) )
	{
		NMISNG::Util::logAuth("verify_id: cookie not defined");
		return ''; # not defined
	}

	if ($self->{cookie_flavour} eq "nmis")
	{
		# nmis-style cookies: username:numeric weak checksum
		if($cookie !~ /(^.+):(\d+)$/)
		{
			NMISNG::Util::logAuth("verify_id: cookie bad format");
			return ''; # bad format
		}
		my ($user_name, $token) = ($1,$2);
		my $checksum = $self->get_cookie_token($user_name);

		NMISNG::Util::logAuth("DEBUG: verify_id: $user_name, cookie $token vs. computed $checksum")
				if ($self->{debug});

		return ($token eq $checksum)? $user_name : '';
	}
	elsif ($self->{cookie_flavour} eq "omk")
	{
		# structure: base64 session info--cryptographic signature
		my $sessiondata = $cookie;
		# base64 doesn't use '-' BUT the mojo cookie setup replaces all = with -
		# so we can't just split on --
		my $signature = $1 if ($sessiondata =~ s/--([^\-]+)$//);

		if (!$sessiondata or !$signature)
		{
			NMISNG::Util::logAuth('Invalid OMK cookie');
			return '';
		}

		# signed with what key?
		my $web_key = $self->{config}->{'auth_web_key'} // $CHOCOLATE_CHIP;

		# first, compare the checksum from cookie with a new one generated from cookie value
		my $expected = Digest::SHA::hmac_sha1_hex($sessiondata, $web_key);
		if ($expected ne $signature)
		{
			NMISNG::Util::logAuth('OMK cookie did not validate correctly!'
							.($self->{debug}? " expected $expected but cookie had $signature" : ""));
			return '';
		}
		# only then decode and json-parse the structure
		$sessiondata =~ y/-/=/;
		my $sessioninfo = eval { decode_json(decode_base64($sessiondata)); };
		if ($@ or ref($sessioninfo) ne "HASH")
		{
			NMISNG::Util::logAuth("OMK cookie unparseable! $@");
			return '';
		}
		if (!exists $sessioninfo->{auth_data})
		{
			NMISNG::Util::logAuth("OMK cookie invalid: no auth_data field!");
			return '';
		}
		my $user_name = $sessioninfo->{auth_data};
		NMISNG::Util::logAuth("Accepted OMK cookie for user: $user_name, cookie data: "
						.decode_base64($sessiondata)) if $self->{debug};
		return $user_name;
	}
	# unrecognisable cookie_flavour
	else
	{
		return '';
	}
}


# generate_cookie creates a cookie string
# based on given username, sso domain, expiration, flavour settings
# args: user_name (required);
#  expires (optional), value (optional, only good for producing invalid/logged-out cookie)
# returns: cookie string, empty if problems encountered
sub generate_cookie
{
	my ($self, %args) = @_;

	my $authuser = $args{user_name};
	return "" if (!defined $authuser or $authuser eq '');

	my $expires = ($args{expires} // $self->{config}->{auth_expire}) || '+60min';
	my $cookiedomain = $self->get_cookie_domain;

	# cookie flavor determines the ingredients
	if ($self->{cookie_flavour} eq "nmis")
	{
		return CGI::cookie( -name => $self->get_cookie_name,
												-domain => $cookiedomain,
												-expires => $expires,
												-value => (exists($args{value}) ?
																	 $args{value}
																	 : ("$authuser:" . $self->get_cookie_token($authuser)) )); # weak checksum
	}
	elsif ($self->{cookie_flavour} eq "omk")
	{
		# omk flavour needs the expiration value as unix-seconds timestamp
		my $expires_ts;
		if ($expires eq "now")
		{
			$expires_ts = time();
		}
		elsif ($expires =~ /^([+-]?\d+)\s*({s|m|min|h|d|M|y})$/)
		{
			my ($offset, $unit) = ($1, $2);
			# the last two are clearly imprecise
			my %factors = ( s => 1, m => 60, 'min' => 60, h => 3600, d => 86400, M => 31*86400, y => 365 * 86400 );

			$expires_ts = time + ($offset * $factors{$unit});
		}
		else # assume it's something absolute and parsable
		{
			$expires_ts = func::parseDateTime($expires) || func::getUnixTime($expires);
		}

		# create session data structure, encode as base64 (but - instead of =), sign with key and combine
		my $sessiondata = encode_json( { auth_data => $authuser,
																		 omkd_sso_domain => $cookiedomain,
																		 expires => $expires_ts } );
		my $value = encode_base64($sessiondata, ''); # no end of line separator please
		$value =~ y/=/-/;
		my $web_key = $self->{config}->{auth_web_key} // $CHOCOLATE_CHIP;
		my $signature = Digest::SHA::hmac_sha1_hex($value, $web_key);

		logAuth("generated OMK cookie for $authuser: $value--$signature")
				if ($self->{debug});

		return  CGI::cookie( { -name => "mojolicious",
													 -domain => $cookiedomain,
													 -value => "$value--$signature",
													 -expires => $expires } );
	}
	else
	{
		logAuth("ERROR unrecognisable auth_cookie_flavour configuration!");
		return '';
	}
}


#----------------------------------

# call appropriate verification routine
sub user_verify {
	my $self = shift;
	my($rv) = 0; # default: refuse
	my($u,$p) = @_;
	my $UT = Compat::NMIS::loadGenericTable("Users");
	my $exit = 0;

	my $lc_u = lc $u;
	if ($lc_u eq lc $UT->{$lc_u}{user} && $UT->{$lc_u}{admission} eq 'bypass') {
		NMISNG::Util::logAuth("INFO login request for user $u bypass permitted");
		return 1;
	}

	# fixme why?
	$self->{config}->{auth_method_1} = "apache"  if 	(!$self->{config}->{auth_method_1});

	my $authCount = 0;
	for my $auth ( $self->{config}->{auth_method_1},
								 $self->{config}->{auth_method_2},
								 $self->{config}->{auth_method_3} )
	{
		next if $auth eq '';
		++$authCount;

		if( $auth eq "apache" ) {
			if($ENV{'REMOTE_USER'} ne "") { $exit=1; }
			else { $exit=0; }
		} elsif ( $auth eq "htpasswd" ) {
			$exit = $self->_file_verify($self->{config}->{auth_htpasswd_file},$u,$p,$self->{config}->{auth_htpasswd_encrypt});

		} elsif ( $auth eq "radius" ) {
			$exit = $self->_radius_verify($u,$p);

		} elsif ( $auth eq "tacacs" ) {
			$exit = $self->_tacacs_verify($u,$p);

		} elsif ( $auth eq "system" ) {
			$exit = $self->_system_verify($u,$p);

		} elsif ( $auth eq "ldaps" ) {
			$exit = $self->_ldap_verify($u,$p,1);

		} elsif ( $auth eq "ldap" ) {
			$exit = $self->_ldap_verify($u,$p,0);

		} elsif ( $auth eq "ms-ldap" ) {
			$exit = $self->_ms_ldap_verify($u,$p,0);

		} elsif ( $auth eq "ms-ldaps" ) {
		  ### 2013-05-27 keiths, Change from Mateusz Kwiatkowski
			$exit = $self->_ms_ldap_verify($u,$p,1);
		} elsif ( $auth eq "novell-ldap" ) {
			$exit = _novell_ldap_verify($u,$p,0);
		} elsif ( $auth eq "connectwise" ) {
			$exit = $self->_connectwise_verify($u,$p);
		}

		if ($exit) {
			#Redundant logging
			NMISNG::Util::logAuth("INFO login request of user=$u method=$auth accepted") if $authCount > 1;
			last; # done
		} else {
			NMISNG::Util::logAuth("INFO login request of user=$u method=$auth failed");
		}
	}

	return $exit;
}

#----------------------------------

# verify against a password file:   username:password
# both unix-std crypt and apache-specific md5 password hashing are tried.
# encmode == plaintext means plaintext passwords are also allowed
sub _file_verify {
	my $self = shift;
	my($pwfile,$u,$p,$encmode) = @_;

	NMISNG::Util::logAuth("DEBUG: _file_verify($pwfile,$u,$p,$encmode)") if $self->{debug};

	my $allowplaintext = ($encmode eq "plaintext");
	# the other encmode parameters are ignored.

	my $havematch=-1;
	if (!open(PW,"<$pwfile"))
	{
		NMISNG::Util::logAuth("ERROR: Cannot open password file $pwfile: $!");
		return 0;
	}

	while(<PW>)
	{
		chomp;
		my ($user,$crypted) = split(/:/,$_,2);
		next if ($user ne $u or $crypted eq '');

		# try all types in sequence: crypt first, apache-md5 second
		# plaintext if and only if explicitely enabled
		$havematch = (crypt($p,$crypted) eq $crypted
									or apache_md5_crypt($p,$crypted) eq $crypted
									or ($allowplaintext && $p eq $crypted));
		last;
	}
	close PW;
	if ($havematch == 1)					# matched, all good.
	{
		return 1
	}
	elsif ($havematch == -1)					# no user
	{
		NMISNG::Util::logAuth("User $u not found in $pwfile.") if $self->{debug};
		return 0;
	}
	elsif (!$havematch)
	{
		NMISNG::Util::logAuth("Password mismatch for user $u.") if $self->{debug};
		return 0;
	}
}

#----------------------------------

# LDAP verify a username
sub _ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);


	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			NMISNG::Util::logAuth("ERROR, no IO::Socket::SSL; Net::LDAPS installed");
			return 0;
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			NMISNG::Util::logAuth("ERROR, no Net::LDAP installed");
			return 0;
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($self->{config}->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($self->{config}->{'auth_ldap_server'});
	}
	if(!$ldap) {
		NMISNG::Util::logAuth("ERROR, no LDAP object created, maybe ldap server address missing in configuration of NMIS");
		return 0;
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $self->{config}->{'auth_ldap_attr'} )
		if( $self->{config}->{'auth_ldap_attr'} );

	foreach $context ( split ":", $self->{config}->{'auth_ldap_context'}  ) {
		foreach $attr ( @attrlist ) {
			$dn = "$attr=$u,".$context;
			$msg = $ldap->bind($dn, password=>$p) ;
			if(!$msg->is_error) {
				$ldap->unbind();
				return 1;
			}
		}
	}

	return 0; # not found
}

#----------------------------------
#
# Novell eDirectory LDAP verify a username
#

sub _novell_ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);


	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			NMISNG::Util::logAuth2("no IO::Socket::SSL; Net::LDAPS installed","ERROR");
			return 0;
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			NMISNG::Util::logAuth2("no Net::LDAP installed","ERROR");
			return 0;
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($self->{config}->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($self->{config}->{'auth_ldap_server'});
	}
	if(!$ldap) {
		NMISNG::Util::logAuth2("no LDAP object created, maybe ldap server address missing in configuration of NMIS","ERROR");
		return 0;
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $self->{config}->{'auth_ldap_attr'} )
		if( $self->{config}->{'auth_ldap_attr'} );

	# TODO: Implement non-anonymous bind

	$msg = $ldap->bind; # Anonymous bind
	if ($msg->is_error) {
		NMISNG::Util::logAuth2("cant search LDAP (anonymous bind), need binddn which is uninplemented","TODO");
		NMISNG::Util::logAuth2("LDAP anonymous bind failed","ERROR");
		return 0;
	}

	foreach $context ( split ":", $self->{config}->{'auth_ldap_context'}  ) {

		$dn = undef;
		# Search "attr=user" in each context
		foreach $attr ( @attrlist ) {

			$msg = $ldap->search(base=>$context,filter=>"$attr=$u",scope=>"sub",attrs=>["dn"]);

			if ( $msg->is_error ) { #|| ($msg->count != 1)) { # not Found, try next context
				next;
			}
			$dn = $msg->entry(0)->dn;
		}
		# if found, use DN to bind
		# not found => dn is undef

		return 0 unless defined($dn);

		$msg = $ldap->bind($dn, password=>$p) ;
		if(!$msg->is_error) {

			$ldap->unbind();
			return 1;
		}

		else {
			# A bind failure in one context is fatal.
			return 0;
		}
	}

	NMISNG::Util::logAuth2("LDAP user not found in any context","ERROR");
	return 0; # not found in any context
}

#----------------------------------
# Microsoft LDAP verify username/password
sub _ms_ldap_verify
{
	my $self = shift;
	my($u, $p, $sec) = @_;
	my $ldap;
	my $ldap2;
	my $status;
	my $status2;
	my $entry;
	my $dn;

	my $extra_ldap_debug  = NMISNG::Util::getbool($self->{config}->{auth_ms_ldap_debug});

	if($sec)
	{
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			NMISNG::Util::logAuth("ERROR no IO::Socket::SSL; Net::LDAPS installed");
			return 0;
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			NMISNG::Util::logAuth("ERROR no Net::LDAP installed from CPAN");
			return 0;
		} # no Net::LDAP installed
	}

	# Connect to LDAP by know (readonly) account
	if($sec) {
		$ldap = new Net::LDAPS($self->{config}->{'auth_ms_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($self->{config}->{'auth_ms_ldap_server'});
	}
	if(!$ldap) {
		NMISNG::Util::logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing in configuration of NMIS");
		return 0;
	}

	# bind LDAP for request DN of user
	$status = $ldap->bind( $self->{config}->{'auth_ms_ldap_dn_acc'},
												 password=> $self->{config}->{'auth_ms_ldap_dn_psw'});
	if ($status->code() ne 0) {

		NMISNG::Util::logAuth("ERROR LDAP validation of $self->{config}->{'auth_ms_ldap_dn_acc'}, error msg ".$status->error()." ");
		return 0;
	}

	NMISNG::Util::logAuth("DEBUG LDAP Base user=$self->{config}->{'auth_ms_ldap_dn_acc'} authorized") if $extra_ldap_debug;


	for my $attr ( split ',',$self->{config}->{'auth_ms_ldap_attr'}) {

		NMISNG::Util::logAuth("DEBUG LDAP search, base=$self->{config}->{'auth_ms_ldap_base'},".
													"filter=${attr}=$u, attr=distinguishedName") if $extra_ldap_debug;

		my $results = $ldap->search(scope=>'sub',base=>"$self->{config}->{'auth_ms_ldap_base'}",filter=>"($attr=$u)",attrs=>['distinguishedName']);

		# if full debugging dumps are requested, put it in a separate log file
		if ($extra_ldap_debug)
		{
			open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ms-ldap-debug.log");
			print F NMISNG::Util::returnDateStamp(). Dumper($results) ."\n";
			close(F);
		}

		if (($entry = $results->entry(0))) {
			$dn = $entry->get_value('distinguishedName');
		} else {
			NMISNG::Util::logAuth("DEBUG LDAP search failed") if $extra_ldap_debug;
		}
	}

	if ($dn eq '') {
		NMISNG::Util::logAuth("DEBUG user $u not found in Active Directory") if $extra_ldap_debug;
		$ldap->unbind();
		return 0;
	}

	my $d = $dn;
	$d =~ s/\\//g;
	NMISNG::Util::logAuth("DEBUG LDAP found distinguishedName=$d") if $extra_ldap_debug;

	# check user

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap2 = new Net::LDAPS($self->{config}->{'auth_ms_ldaps_server'});
	} else {
		$ldap2 = new Net::LDAP($self->{config}->{'auth_ms_ldap_server'});
	}
	if(!$ldap2) {
		NMISNG::Util::logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing");
		return 0;
	}

	$status2 = $ldap2->bind("$dn",password=>"$p");
	NMISNG::Util::logAuth("DEBUG LDAP bind dn $d password $p status ".$status->code()) if $extra_ldap_debug;
	if ($status2->code eq 0) {
		# permitted
		$ldap->unbind();
		$ldap2->unbind();
		return 1;
	}

	$ldap->unbind();
	$ldap2->unbind();

	return 0; # not found
}

#----------------------------------
# ConnectWise API  verify username/password
#
# VERSION 1.0.0 20160916 Mark Henry for Opmantek
# This section was inspired by a code sample
# provided by Robert Staats written using
# REST::Client
#
sub _connectwise_verify
{
	my $self = shift;
	my($u, $p) = @_;
	my $protocol = 'https'; #Connectwise API requires validate call to be HTTPS

	eval { require Mojo::UserAgent; };
	if ($@)
	{
		NMISNG::Util::logAuth("ERROR Connectwise authentication method requires Mojo::UserAgent but module not available: $@!");
		return 0;
	}

	NMISNG::Util::logAuth("DEBUG start sub _connectwise_verify") if $self->{debug};

	# The bulk of what we need comes from Config.nmis
	my $cw_server = $self->{config}->{auth_cw_server};
	my $company_id = $self->{config}->{auth_cw_company_id};
	my $public_key = $self->{config}->{auth_cw_public_key};
	my $private_key = $self->{config}->{auth_cw_private_key};

	if ($cw_server eq "" || $company_id eq "" || $public_key eq "" || $private_key eq "") {
		NMISNG::Util::logAuth("ERROR one or more required ConnectWise variables are missing from Config.nmis");
		return 0;
	}

	# Build API call to ConnectWise
	# This is static, builds Authorization per Connectwise API
	my $headers = {"Content-type" => 'application/json', Accept => 'application/json', Authorization => 'Basic ' . encode_base64($company_id . '+' . $public_key . ':' . $private_key,'')};

	NMISNG::Util::logAuth("DEBUG built headers") if $self->{debug};

	my $client = Mojo::UserAgent->new();
	NMISNG::Util::logAuth("DEBUG created Mojo::UserAgent") if $self->{debug};

	my $request_body = "{email: \"$u\",password: \"$p\"}";
	my $urlValidateCredentials = $protocol . "://" . $cw_server. "/v4_6_release/apis/3.0/company/contacts/validatePortalCredentials";
	my $responseContent = $client->post($urlValidateCredentials => $headers => $request_body);
	NMISNG::Util::logAuth("DEBUG created client->POST") if $self->{debug};

	my $response = $responseContent->success();
	NMISNG::Util::logAuth("DEBUG got responseContent->success") if $self->{debug};
	if ($response) {
		my $body = decode_json($response->body());
		NMISNG::Util::logAuth("DEBUG response->body converted from JSON") if $self->{debug};

		if ($body->{'success'}) {
			# permitted
			NMISNG::Util::logAuth("INFO Connectwise Login Successful for $u ContactId: ".$body->{'contactId'});
			return 1;
		} else {
			NMISNG::Util::logAuth("ERROR Connectwise Login Failed for $u Reply: ".$body->{'success'});
			return 0;
		}
	} else {
		NMISNG::Util::logAuth("ERROR Connectwise response failed");
		return 0;
	}

	# How did I get down here?
	return 0;
}


##########################################################################
#
# The following routines were inspired as part of Routers2.cgi but
# but where completely gutted to suit my purposes. As they are no
# longer recognizable by Steve I take full responsibility of these
# modules and the maintenance.
#
# Copyright (C) 2005 Robert W. Smith
#
# The following routines are covered by this copyright and the GNU GPL.
# do_login -- output HTML login form that submits to top level
#
sub do_login {
	my $self = shift;
	my %args = @_;

	# that's the NAME not the config data...
	my $config = $args{conf} || $self->{confname};
	my $msg = $args{msg};
	my $listmodules = $args{listmodules};

	# this is sent if auth = y and page = top (or blank),
	# or if page = login

	# we need to find out our url, but don't want any query params added to it...conf is kept as hidden field
	my $subcgi = CGI->new;
	my $url = $subcgi->url(-absolute => 1);


	if( CGI::http("X-Requested-With") eq "XMLHttpRequest" )
	{
		# forward url will have a function in it, we want to go back to regular nmis
		# my $url_no_forward = url(-base=>1) . $self->{config}->{'<cgi_url_base>'} . "/nmiscgi.pl?auth_type=login$configfile_name";
		my $ret = { name => "JSONRequestError", message => "Authentication Error" };
		my $json_data = encode_json( $ret ); #, { pretty => 1 } );

    print <<EOHTML;
Status: 405 Method Not Allowed
Content-type: application/json

EOHTML
    print $json_data;
    return;
	}
	my $cookie = $self->generate_cookie(user_name => "remove", expires => "now", value => "remove" );
	NMISNG::Util::logAuth("DEBUG: do_login: sending cookie to remove existing cookies=$cookie") if $self->{debug};
	print CGI::header(-target=>"_top", -type=>"text/html", -expires=>'now', -cookie=>[$cookie]);

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>$self->{config}->{auth_login_title}</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$self->{config}->{'nmis_favicon'}" />
    <link type="text/css" rel="stylesheet" href="$self->{config}->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$self->{config}->{'styles'}" />
    <script src="$self->{config}->{'jquery'}" type="text/javascript"></script>
    <script src="$self->{config}->{'jquery_ui'}" type="text/javascript"></script>
  </head>
  <body>
|;

	print qq|
    <div id="login_frame">
      <div id="login_dialog" class="ui-dialog ui-widget ui-widget-content ui-corner-all">
|;

	print $self->do_login_banner();

	print CGI::start_form({method=>"POST", action=> $url, target=>"_top"});

	print CGI::start_table({class=>""});

	if ( $self->{config}->{'company_logo'} ne "" ) {
		print CGI::Tr(CGI::td({class=>"info Plain",colspan=>'2'}, qq|<img class="logo" src="$self->{config}->{'company_logo'}"/>|));
	}

	my $motd = "Authentication required: Please log in with your appropriate username and password in order to gain access to this system";
	$motd = $self->{config}->{auth_login_motd} if $self->{config}->{auth_login_motd} ne "";

	print CGI::Tr(CGI::td({class=>'infolft Plain',colspan=>'2'},$motd));

	print CGI::Tr(CGI::td({class=>'info Plain'},"Username") . CGI::td({class=>'info Plain'},textfield({name=>'auth_username'})));
	print CGI::Tr(CGI::td({class=>'info Plain'},"Password") . CGI::td({class=>'info Plain'},password_field({name=>'auth_password'}) ));
	print CGI::Tr(CGI::td({class=>'info Plain'},"&nbsp;") . CGI::td({class=>'info Plain'},submit({name=>'login',value=>'Login'}) ));


	if ( $self->{config}->{'auth_sso_domain'} ne "" and $self->{config}->{'auth_sso_domain'} ne ".domain.com" ) {
		print CGI::Tr(CGI::td({class=>"info",colspan=>'2'}, "Single Sign On configured with \"$self->{config}->{'auth_sso_domain'}\""));
	}

	print CGI::Tr(CGI::td({colspan=>'2'},p({style=>"color: red"}, "&nbsp;$msg&nbsp;"))) if $msg ne "";

	print CGI::end_table;

	print hidden(-name=>'conf', -default=>$config, -override=>'1');

	# put query string parameters into the form so that they are picked up by Vars (because it only takes get or post not both)
	my @qs_params = param();
	foreach my $key (@qs_params) {
		# NMISNG::Util::logAuth("adding $key ".param($key)."\n";
		if( $key !~ /conf|auth_type|auth_username|auth_password/ ) {
			print hidden(-name=>$key, -default=>param($key),-override=>'1');
		}
	}

	print CGI::end_form();

	print "\n      </div>\n";

	if (ref($listmodules) eq "ARRAY" and @$listmodules)
	{
		print qq|
      <div>&nbsp;</div>
      <div id='login_dialog' class='ui-dialog ui-widget ui-widget-content ui-corner-all'>
        <div class='header'>Available NMIS Modules</div>
        <table>
|;
		for my $entry (@$listmodules)
		{
			my ($name, $link, $descr) = @$entry;
			print "          <tr><td class='lft Plain'><a href=\"$link\" target='_blank'>$name</a> - $descr</td></tr>\n";
		}
		print qq|        </table>
      </div>
|;
	}

		print qq|
    </div>
|;

	print CGI::end_html;
}

##############################################################################
#
# The java script herein is courtesy of the Steve Shipway and is copyrighted
# by him.
#
# do_force_login -- output HTML that sends top level to login page
#
sub do_force_login {
	my $self = shift;
	my %args = @_;

	# that's the NAME not the config data
	my $config = $args{conf} || $self->{confname};
	my($javascript);
	my($err) = shift;

	if( $config ne '' ){
		$config = "&conf=$config";
	}

	my $url = CGI::url(-base=>1) . $self->{config}->{'<cgi_url_base>'} . "/nmiscgi.pl?auth_type=login$config";

	# if this request is coming through an AJAX'Y method, respond in a different mannor that commonV8.js will understand
	# and redirect for us
	if( CGI::http("X-Requested-With") eq "XMLHttpRequest" )
	{
		my $url_no_forward = $url;
		my $ret = { name => "JSONRequestError", message => "Authentication Error", redirect_url => $url_no_forward };
		my $json_data = encode_json( $ret ); #, { pretty => 1 } );

    print <<EOHTML;
Status: 405 Method Not Allowed
Content-type: application/json

EOHTML
    print $json_data;
    return;
	}

	$javascript = "function redir() { ";
#	$javascript .= "alert('$err'); " if($err);
	$javascript .= " window.location = '" . $url . "'; }";

	$javascript = "function redir() {} " if($self->{config}->{'web-auth-debug'});

	print CGI::header({ target=>'_top', expires=>"now" })."\n";
	print CGI::start_html({ title =>"Login Required",
						expires => "now",  script => $javascript,
						onload => "redir()", bgcolor=>'#CFF' }),"\n";
	print CGI::h1("Authentication required")."\n";
	print "Please ".CGI::a({href=>$url},"login")	." before continuing.\n";

	print "<!-- $err -->\n";
	print CGI::end_html;
}

#----------------------------------

# do_logout -- set auth cookie to blank, expire now, and redirect to top
#
sub do_logout {
	my $self = shift;
	my %args = @_;

	# that's the NAME not the config data
	my $config = $args{conf} || $self->{confname};

	# Javascript that sets window.location to login URL
	### fixing the logout so it can be reverse proxied
	# ensure the  conf argument is kept
	param(conf=>$config) if ($config);
	CGI::delete('auth_type'); 		# but don't keep that one
	my $url = CGI::url(-full=>1, -query=>1);
	$url =~ s!^[^:]+://!//!;

	my $javascript = "function redir() { window.location = '" . $url ."'; }";
	my $cookie = $self->generate_cookie(user_name => $self->{user}, expires => "now", value => "" );

	NMISNG::Util::logAuth("INFO logout of user=$self->{user} conf=$config");

	print CGI::header({ -target=>'_top', -expires=>"5s", -cookie=>[$cookie] })."\n";
	#print start_html({
	#	-title =>"Logout complete",
	#	-expires => "5s",
	#	-script => $javascript,
	#	-onload => "redir()",
	#	-style=>{'src'=>"$self->{config}->{'<menu_url_base>'}/css/dash8.css"}
	#	}),"\n";

	print qq
|<!DOCTYPE html>
<html>
  <head>
    <title>Logout complete</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$self->{config}->{'nmis_favicon'}" />
    <link type="text/css" rel="stylesheet" href="$self->{config}->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$self->{config}->{'styles'}" />
    <script src="$self->{config}->{'jquery'}" type="text/javascript"></script>
    <script src="$self->{config}->{'jquery_ui'}" type="text/javascript"></script>
    <script type="text/javascript">//<![CDATA[
$javascript
//]]></script>
  </head>
  <body onload="redir()" expires="10s">
|;

	print qq|
  <div id="login_frame">
    <div id="login_dialog" class="ui-dialog ui-widget ui-widget-content ui-corner-top">
|;

	print $self->do_login_banner();

	print CGI::start_table();
	print CGI::Tr(CGI::td({class=>"info Plain"}, CGI::p(CGI::h2("Logged out of system") .
	CGI::p("Please " . CGI::a({href=>CGI::url(-full=>1) . ""},"go back to the login page") ." to continue."))));

	print CGI::end_table;

	print "    </div>\n";
	print "  </div>\n";

	print CGI::end_html;
}

#####################################################################
#
# The following routines are courtesy of Robert W. Smith, copyrighted
# and covered under the GNU GPL.
#
sub do_login_banner {
	my $self = shift;
	my @banner = ();
	my $banner_string = "NMIS $Compat::NMIS::VERSION";

	if ( defined $self->{banner}  ) {
		$banner_string = $self->{banner};
	}

	#print STDERR "DEBUG AUTH banner=$banner_string self->{banner}=$self->{banner}\n";

	my $logo = qq|<a href="http://www.opmantek.com"><img height="20px" width="20px" class="logo" src="$self->{config}->{'nmis_favicon'}"/></a>|;
	push @banner,CGI::div({class=>'ui-dialog-titlebar ui-dialog-header ui-corner-top ui-widget-header lrg pad'},$logo, $banner_string);
	push @banner,CGI::div({class=>'title2'},"Network Management Information System");

	return @banner;
}


#####################################################################
#
# The following routines are courtesy of the NMIS source and copyrighted
# by Sinclair Internetworking Ltd Pty and covered under the GNU GPL.
#

#####################################################################
#
# 5-10-06, Jan v. K.
#

sub _radius_verify {
	my $self = shift;
	my($user, $pswd) = @_;

	eval { require Authen::Simple::RADIUS; }; # installed from CPAN
	if($@) {
		NMISNG::Util::logAuth("ERROR, no Authen::Simple::RADIUS installed");
		return 0;
	} # no Authen::Simple::RADIUS installed

	my ($host,$port) = split(/:/,$self->{config}->{auth_radius_server});
	if ($host eq "") {
		NMISNG::Util::logAuth("ERROR, no radius server address specified in configuration of NMIS");
	} elsif ($self->{config}->{auth_radius_secret} eq "") {
		NMISNG::Util::logAuth("ERROR, no radius secret specified in configuration of NMIS");

	} else {
		$port = 1645 if $port eq "";
		my $radius = Authen::Simple::RADIUS->new(
			host   => $host,
			secret => $self->{config}->{auth_radius_secret},
			port => $port
		);
		if ( $radius->authenticate( $user, $pswd ) ) {
	        return 1;
		}
	}
	return 0;
}

#####################################################################
#

sub _tacacs_verify {
	my $self = shift;
	my($user, $pswd) = @_;


	eval { require Authen::TacacsPlus; }; # installed from CPAN
	if($@) {
		NMISNG::Util::logAuth("ERROR, no Authen::TacacsPlus installed");
		return 0;
	} # no Authen::TacacsPlus installed

	my ($host,$port) = split(/:/,$self->{config}->{auth_tacacs_server});
	if ($host eq "") {
		NMISNG::Util::logAuth("ERROR, no tacacs server address specified in configuration of NMIS");
	} elsif ($self->{config}->{auth_tacacs_secret} eq "") {
		NMISNG::Util::logAuth("ERROR, no tacacs secret specified in configuration of NMIS");
	} else {
		$port = 49 if $port eq "";
		my $tacacs = new Authen::TacacsPlus(
			Host => $host,
			Key => $self->{config}->{auth_tacacs_secret},
		);
		if ( $tacacs->authen($user,$pswd)) {
			$tacacs->close();
			return 1;
		}
		$tacacs->close();
	}
	return 0;
}

#####################################################################
#
# 5-03-07, Jan v. K.
#
# check login - logout - go

sub loginout {
	my $self = shift;
	my %args = @_;
	my $type = lc($args{type});
	my $username = $args{username};
	my $password = $args{password};

	# that's the NAME not the config data
	my $config = $args{conf} || $self->{confname};

	my $listmodules = $args{listmodules};

	my $headeropts = $args{headeropts};
	my @cookies = ();

	NMISNG::Util::logAuth("DEBUG: loginout type=$type username=$username config=$config")
			if $self->{debug};

	#2011-11-14 Integrating changes from Till Dierkesmann
	### 2013-01-22 markd, fixing Auth to use Cookies!
	if($ENV{'REMOTE_USER'} and ($self->{config}->{auth_method_1} eq "" or $self->{config}->{auth_method_1} eq "apache") ) {
		$username=$ENV{'REMOTE_USER'};
		if( $type eq 'login' ) {
			$type = ""; #apache takes care of showing the login screen
		}
  }

	if ( lc $type eq 'login' ) {
		$self->do_login(listmodules => $listmodules);
		return 0;
	}

	my $maxtries = $self->{config}->{auth_lockout_after};

	if (defined($username) && $username ne '')
	{
		# someone is trying to log in
		if ($maxtries)
		{
			my ($error, $failures) = $self->get_failure_counter(user => $username);
			if ($failures > $maxtries)
			{
				NMISNG::Util::logAuth("Account $username remains locked after $failures login failures.");
				$self->do_login(listmodules => $listmodules,
												msg => "Too many failed attempts, account disabled");
				return 0;
			}
		}
		NMISNG::Util::logAuth("DEBUG: verifying $username") if $self->{debug};
		if( $self->user_verify($username,$password))
		{
			#logAuth("DEBUG: user verified $username") if $self->{debug};
			#logAuth("self.privilevel=$self->{privilevel} self.config=$self->{config} config=$config") if $self->{debug};

			# login accepted, set privs
			$self->SetUser($username);
			# and reset the failure counter
			$self->update_failure_counter(user => $username, action => 'reset') if ($maxtries);

			# handle default privileges or not.
			if ( $self->{priv} eq "" and ( $self->{config}->{auth_default_privilege} eq ""
																		 or getbool($self->{config}->{auth_default_privilege},"invert")) ) {
				$self->do_login(msg=>"Privileges NOT defined, please contact your administrator",
												listmodules => $listmodules);
				return 0;
			}

			NMISNG::Util::logAuth("user=$self->{user} logged in with config=$config");
			NMISNG::Util::logAuth("DEBUG: loginout user=$self->{user} logged in with config=$config") if $self->{debug};
		}
		else
		{ # bad login: try again, up to N times
			if ($maxtries)
			{
				# update the failure counter
				my ($error, $newcount) = $self->update_failure_counter(user => $username, action => 'inc');
				NMISNG::Util::logAuth("Account $username failure count now $newcount");
				if (!$error && $newcount > $maxtries)
				{
					# notify of lockout when over the limit
					NMISNG::Util::logAuth("Account $username now locked after $newcount login failures.");
					# notify the server admin by email if setup
					if ($self->{config}->{server_admin})
					{
						my ($status,$code,$msg) = NMISNG::Notify::sendEmail(
							sender => $self->{config}->{mail_from},
							recipients => [split(/\s*,\s*/, $self->{config}->{server_admin})],

							mailserver => $self->{config}->{mail_server},
							serverport => $self->{config}->{mail_server_port},
							hello => $self->{config}->{mail_domain},
							usetls => $self->{config}->{mail_use_tls},
							ipproto => $self->{config}->{mail_server_ipproto},

							username => $self->{config}->{mail_user},
							password => $self->{config}->{mail_password},

							# and params for making the message on the go
							to => $self->{config}->{server_admin},
							from => $self->{config}->{mail_from},
							subject => "Account \"$username\" locked after $newcount failed logins",
							body => qq|The account \"$username\" on $self->{config}->{server_name} has exceeded the maximum number
of failed login attempts and was locked.

To re-enable this account visit $self->{config}->{nmis_host_protocol}://$self->{config}->{nmis_host}$self->{config}->{"<cgi_url_base>"}/tables.pl?act=config_table_menu&table=Users&widget=false and select the "reset login count" option. |,
							priority => "High"
								);

						if (!$status)
						{
							NMISNG::Util::logAuth("Error: Sending of lockout notification email to $self->{config}->{server_admin} failed: $code $msg");
						}
					}
					$self->do_login( msg => "Too many failed attempts, account disabled",
													 listmodules => $listmodules);
					return 0;
				}
			}

			# another go - if maxtries unset or if the update failed
			$self->do_login(msg=>"Invalid username/password combination",
											listmodules => $listmodules);
			return 0;
		}
	}
	else { # check cookie
		NMISNG::Util::logAuth("DEBUG: valid session? check cookie") if $self->{debug};

		$username = $self->verify_id();
		if( $username eq '' ) { # invalid cookie
			logAuth("DEBUG: invalid session ") if $self->{debug};

			#$self->do_login(msg=>"Session Expired or Invalid Session");
			$self->do_login(msg=>"", listmodules => $listmodules);
			return 0;
		}

		$self->SetUser( $username );
		NMISNG::Util::logAuth("DEBUG: cookie OK") if $self->{debug};
	}

	# logout has to be down here because we need the username loaded to generate the correct cookie
	if(lc $type eq 'logout') {
		$self->do_logout(); # bye
		return 0;
	}

	# user should be set at this point, if not then redirect
	unless ($self->{user}) {
		NMISNG::Util::logAuth("DEBUG: loginout forcing login, shouldn't have gotten this far") if $self->{debug};
		$self->do_login(listmodules => $listmodules);
		return 0;
	}

	# generate the cookie if $self->user is set
	if ($self->{user}) {
    push @cookies, $self->generate_cookie(user_name => $self->{user});
  	NMISNG::Util::logAuth("DEBUG: loginout made cookie $cookies[0]") if $self->{debug};
	}
	$headeropts->{-cookie} = [@cookies];
	return 1; # all oke
}

# increments or resets the login failure counter for a given user
# args: user, action (inc or reset), both required
# returns error message or (undef,new counter value)
sub update_failure_counter
{
	my ($self, %args) = @_;
	my ($user, $action) = @args{"user","action"};

	return "cannot update failure counter without valid user argument!" if (!$user);
	return "cannot update failure counter without valid action argument!" if (!$action or $action !~ /^(inc|reset)$/);

	my $statedir = $self->{config}->{'<nmis_var>'}."/nmis_system/auth_failures";
	NMISNG::Util::createDir($statedir) if (!-d $statedir);

	my $userdata = { count => 0 };
	my $userstatefile = "$statedir/$user.json";
	if (-f $userstatefile)
	{
		open(F, $userstatefile) or return "cannot read $userstatefile: $!";
		$userdata = eval { decode_json(join("", <F>)); };
		close F;
		if ($@ or ref($userdata) ne "HASH")
		{
			unlink($userstatefile);		# broken, get rid of it
		}
	}

	$userdata->{time} = time;
	if ($action eq "reset")
	{
		$userdata->{count} = 0;
	}
	else
	{
		++$userdata->{count};
	}

	open(F,">$userstatefile") or return "cannot write $userstatefile: $!";
	print F encode_json($userdata);
	close(F);
	NMISNG::Util::setFileProtDiag(file => $userstatefile, username => $self->{config}->{nmis_user},
																groupname => $self->{config}->{nmis_group},
																permission => $self->{config}->{os_fileperm}); # ignore problems with that

	return (undef, $userdata->{count});
}

# returns the current failure counter for the given user
# args: user, required.
# returns: (undef,counter) or error message
sub get_failure_counter
{
	my ($self, %args) = @_;
	my $user = $args{"user"};
	return "cannot get failure counter without valid user argument!" if (!$user);

	my $statedir = $self->{config}->{'<nmis_var>'}."/nmis_system/auth_failures";
	NMISNG::Util::createDir($statedir) if (!-d $statedir);

	my $userdata = { count => 0 };
	my $userstatefile = "$statedir/$user.json";
	if (-f $userstatefile)
	{
		open(F, $userstatefile) or return "cannot read $userstatefile: $!";
		$userdata = eval { decode_json(join("", <F>)); };
		close F;
		if ($@ or ref($userdata) ne "HASH")
		{
			unlink($userstatefile);		# broken, get rid of it
		}
	}
	return (undef, $userdata->{count});
}



# check if user logged in

sub User {
	my $self = shift;
	return $self->{user};
}

#----------------------------------

# Set the user and read in the user privilege and groups
#
sub SetUser {
	my $self = shift;
	$self->{_require} = 1;
	my $user = shift;
	if ( $user ) {
		$self->{user} = $user; # username
		# set default privileges to lowest level
		$self->{priv} = "anonymous";
		$self->{privlevel} = 5;
		delete $self->{all_groups_allowed}; # bsts, if the auth object gets reused
		$self->_GetPrivs($self->{user});		# this potentially sets all_groups_allowed
		return 1;
	}
	else {
		return 0;
	}
}

#----------------------------------

# check if the group is in the user's group list
#
sub InGroup {
	my $self = shift;
	my $group = shift;
	return 1 unless $self->{_require};
	# If user can see all groups, they immediately pass
	if ( $self->{all_groups_allowed} )
	{
		NMISNG::Util::logAuth("InGroup: $self->{user}, all group: ok for $group")
				if $self->{debug};
		return 1;
	}
	return 0 if (!$group); # fixme why after the all logic?

	foreach my $g (@{$self->{groups}})
	{
		if (lc($g) eq lc($group))
		{
			NMISNG::Util::logAuth("InGroup: $self->{user}, ok for $group") if $self->{debug};
			return 1;
		}
	}

	NMISNG::Util::logAuth("InGroup: $self->{user}, groups: "
					.join(",", @{$self->{groups}})
					.", NOT ok for $group")
			if $self->{debug};

	return 0;
}

#----------------------------------

#	Check Access identifier agains priv of user
sub CheckAccessCmd {
	my $self = shift;
	my $command = lc shift; # key of table is lower case

	return 1 unless $self->{_require};

	my $AC = Compat::NMIS::loadGenericTable('Access');

	my $perm = $AC->{$command}{"level$self->{privlevel}"};

	NMISNG::Util::logAuth("CheckAccessCmd: $self->{user}, $command, $perm") if $self->{debug};

	return $perm;
}

#----------------------------------

# Private routines go here
#
# _GetPrivs -- load and parse the conf/Users.xxxx file
# also loads conf/PrivMap.xxxx to map the privilege to a
# numeric privilege level.
#
sub _GetPrivs {
	my $self = shift;
	my $user = lc shift;

	my $GT = Compat::NMIS::loadGroupTable();
	my $UT = Compat::NMIS::loadGenericTable("Users");
	my $PMT = Compat::NMIS::loadGenericTable("PrivMap");

	if ( exists $UT->{$user}{privilege} and $UT->{$user}{privilege} ne ""  ) {
		$self->{priv} = $UT->{$user}{privilege};
	}
	else {
		if ( $self->{config}->{auth_default_privilege} ne ""
				 and !NMISNG::Util::getbool($self->{config}->{auth_default_privilege},"invert") ) {
			$self->{priv} = $self->{config}->{auth_default_privilege};
			$self->{privlevel} = 5;
			NMISNG::Util::logAuth("INFO User \"$user\" not found in Users table, assigned default privilege $self->{config}->{auth_default_privilege}");
		}
		else {
			$self->{priv} = "";
			$self->{privlevel} = 5;
			NMISNG::Util::logAuth("INFO User \"$user\" not found in Users table, no default privilege configured");
			return 0;
		}
	}

	if ( ! exists $PMT->{$self->{priv}} and $PMT->{$self->{priv}}{level} eq "" ) {
		NMISNG::Util::logAuth("Privilege $self->{priv} not found for user \"$user\" ");
		$self->{priv} = "";
		$self->{privlevel} = 5;
		return 0;
	}

	$self->{privlevel} = 5;
	if ( $PMT->{$self->{priv}}{level} ne "" ) {
		$self->{privlevel} = $PMT->{$self->{priv}}{level};
	}
	NMISNG::Util::logAuth("INFO User \"$user\" has priv=$self->{priv} and privlevel=$self->{privlevel}") if $self->{debug};

	# groups come from the user sertting or the auth_default_groups
	my $grouplistraw = $UT->{$user}{groups};
	if (!$grouplistraw && $self->{config}->{auth_default_groups})
	{
		$grouplistraw = $self->{config}->{auth_default_groups};
		NMISNG::Util::logAuth("INFO Groups not found for User \"$user\", using auth_default_groups from configuration");
	}

	# leading/trailing space is gone after stripspaces, rest after split
	my @groups = sort(split /\s*,\s*/, NMISNG::Util::stripSpaces($grouplistraw));
	# note: the main health status graphs uses the implied virtual group network,
	# this group must be explicitly stated if you want to see this graph
	push @groups, "network";

	# is the user authorised for all (known and unknown) groups? then record that
	if ( grep { $_ eq 'all' } @groups)
	{
		$self->{all_groups_allowed} = 1;
		$self->{groups} = \@groups;
	}
	elsif ($UT->{$user}{groups} eq "none"
				 or !$grouplistraw)
	{
		$self->{groups} = [];
		delete $self->{all_groups_allowed};
	}
	else
	{
		$self->{groups} = \@groups;
		delete $self->{all_groups_allowed};
	}
	return 1;
}


1;
