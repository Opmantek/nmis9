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
our $VERSION = "5.0.0";

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
use CGI::Session;

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
		all_groups_allowed => undef,
		auth => undef,
		banner => $arg{banner},
		config => $config, # a live config, loaded or passed in by the caller
		confname => $arg{confname},	# optional
		cookie_flavour => $config->{auth_cookie_flavour} || 'nmis',
		debug => NMISNG::Util::getbool($config->{auth_debug}),
		dir => $arg{dir},
		dn => undef,
		groups => undef,
		priv => undef,
		privlevel => 0, # default all
		user => undef,
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

# produces cookie name, with sso domain factored in
# used for both omk and nmis flavoured cookies
sub get_cookie_name
{
	my $self = shift;

	my $nameprefix =  ($self->{cookie_flavour} eq "nmis"?
										 "nmis_auth" : "omk");

	my $name = "$nameprefix.".$self->get_cookie_domain;
	$name =~ s/\.+/./g;						# we want a.x.y.com, not a..x.y.com...
	$name =~ s/\.$//;							# ...not 'nmis_auth.' and not 'omk.'
	return $name;
}

# verify_id reads an existing cookie and verifies its authenticity
# returns: verified username or blank string if invalid/errors
sub verify_id
{
	my $self = shift;

	# retrieve the right cookie
	my $cookie = CGI::cookie($self->get_cookie_name());
	if(!defined($cookie) )
	{
		NMISNG::Util::logAuth("verify_id: cookie not defined") if ($self->{debug});
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
		
		# Validate expiration 
		if ( $sessioninfo->{expires} < time)
		{
			NMISNG::Util::logAuth("OMK cookie invalid: Session expired! ". $sessioninfo->{expires});
			return '';
		}
		
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
	my $name = (exists ($args{name}) ? $args{name} : $self->get_cookie_name);
	my $value = $args{value};

	my $expires = ($args{expires} // $self->{config}->{auth_expire}) || '+60min';
	my $cookiedomain = $self->get_cookie_domain;

	# cookie flavor determines the ingredients
	if ($self->{cookie_flavour} eq "nmis")
	{
		return CGI::cookie( {-name => $name,
							-domain => $cookiedomain,
							-expires => $expires,
							-httponly => 1,
							-value => (exists($args{value}) ?
										$args{value}
										: ("$authuser:" . $self->get_cookie_token($authuser)) )}); # weak checksum
	}
	elsif ($self->{cookie_flavour} eq "omk")
	{
		# omk flavour needs the expiration value as unix-seconds timestamp
		my $expires_ts;
		if ($expires eq "now")
		{
			$expires_ts = time();
		}
		elsif ($expires =~ /^([+-]?\d+)\s*(s|m|min|h|d|M|y)$/)
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
																		 expires => $expires_ts } );
		my $value = encode_base64($sessiondata, ''); # no end of line separator please
		$value =~ y/=/-/;
		my $web_key = $self->{config}->{auth_web_key} // $CHOCOLATE_CHIP;
		my $signature = Digest::SHA::hmac_sha1_hex($value, $web_key);

		NMISNG::Util::logAuth("generated OMK cookie for $authuser: $value--$signature")
				if ($self->{debug});

		return  CGI::cookie( { -name => $name,
 							 -domain => $cookiedomain,
							 -httponly => 1,
							 -value => (exists($args{value}) ?
																	 $args{value}
																	 :"$value--$signature"),
							 -expires => $expires } );

	}
	else
	{
		NMISNG::Util::logAuth("ERROR unrecognisable auth_cookie_flavour configuration!");
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

		$self->{auth} = $auth;	
		if( $auth eq "apache" ) {
			if($ENV{'REMOTE_USER'} ne "") { $exit=1; }
			else { $exit=0; }
		} elsif ( $auth eq "htpasswd" ) {
			$exit = $self->_file_verify($self->{config}->{auth_htpasswd_file},$u,$p,$self->{config}->{auth_htpasswd_encrypt});
		} elsif ( $auth eq "radius" ) {
			$exit = $self->_radius_verify($u,$p,$auth);
		} elsif ( $auth eq "tacacs" ) {
			$exit = $self->_tacacs_verify($u,$p,$auth);
		} elsif ( $auth eq "crowd" ) {
			$exit = $self->_crowd_verify($u,$p,$auth);
		} elsif ( $auth eq "system" ) {
			$exit = $self->_system_verify($u,$p,$auth);
		} elsif ( $auth eq "ldaps" ) {
			$exit = $self->_ldap_verify($u,$p,$auth);
		} elsif ( $auth eq "ldap" ) {
			$exit = $self->_ldap_verify($u,$p,$auth);
		} elsif ( $auth eq "ms-ldap" ) {
			$exit = $self->_ldap_verify($u,$p,$auth);
		} elsif ( $auth eq "ms-ldaps" ) {
			$exit = $self->_ldap_verify($u,$p,$auth);
		} elsif ( $auth eq "novell-ldap" ) {
			$exit = $self->_novell_ldap_verify($u,$p,$auth);
		} elsif ( $auth eq "connectwise" ) {
			$exit = $self->_connectwise_verify($u,$p,$auth);
		} elsif ( $auth eq "pam" ) {
			$exit = $self->_pam_verify($u,$p,$auth);
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

	NMISNG::Util::logAuth("DEBUG: _file_verify($pwfile,$u,$encmode)") if $self->{debug};

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
sub _ldap_verify
{
	my $self = shift;
	my($u, $p, $auth) = @_;
	my $ldap;
	my $status;
	my $entry;
	my $dn;
	my $sec = 0;
	$sec = 1 if ( $auth eq "ldaps" or $auth eq "ms-ldaps");

	my $ldap_config = $self->configure_ldap($self);
	

	if($sec)
	{
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: No IO::Socket::SSL; Net::LDAPS installe.");
			return 0;
		} # no Net::LDAPS installed
		unless ($ldap_config->{auth_ldaps_server}) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: LDAP secure server address ('auth_ldaps_server' key) missing in configuration of NMIS");
			return 0;
		} # Configuration Error.
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: No Net::LDAP installed.");
			return 0;
		} # no Net::LDAP installed
		unless ($ldap_config->{auth_ldap_server}) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: LDAP server address ('auth_ldap_server' key) missing in configuration of NMIS");
			return 0;
		} # Configuration Error.
	}
	unless ($ldap_config->{auth_ldap_base}) {
		NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: LDAP base or context address ('auth_ldap_base' key) missing in configuration of NMIS");
		return 0;
	} # Configuration Error.

	# Connect to LDAP (readonly) account
	if($sec) {
		$ldap = Net::LDAPS->new($ldap_config->{auth_ldaps_server},
			verify =>  $ldap_config->{auth_ldaps_verify},
			capath =>  $ldap_config->{auth_ldaps_capath}
		);

	} else {
		$ldap = Net::LDAP->new($ldap_config->{auth_ldap_server});
	}
	if($@ || !$ldap) {
		NMISNG::Util::logAuth("Auth::_ldap_verify, Could not create LDAP session; ERROR: $@");
		return 0;
	}

	my @attrlist = ( 'uid','cn','sAMAccountName' );
	@attrlist = split( "[ ,]", $ldap_config->{auth_ldap_attr} ) if( $ldap_config->{auth_ldap_attr} );

	# Old OpenLDAP implementation with no authorization.
	unless ($ldap_config->{auth_ldap_acc}) {
		NMISNG::Util::logAuth("Auth::_ldap_verify, INFO: Verifying LDAP credentials without access credentials.") if ($self->{debug});
		foreach my $context ( split ":", $ldap_config->{auth_ldap_base}  ) {
			foreach my $attr ( @attrlist ) {
				my $dn = "$attr=$u,".$context;
				$self->{dn} = $dn;
				my $results = $ldap->bind($dn, password=>$p) ;
				# if full debugging dumps are requested, put it in a separate log file
				if ($ldap_config->{auth_ldap_debug})
				{
					open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
					print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->bind($dn, password=>**************)\n";
					print F NMISNG::Util::returnDateStamp() . ": " . Dumper($results) ."\n";
					close(F);
				}
				if(!$results->is_error) {
					$ldap->unbind();
					return 1;
				}
			}
		}
		return 0; # not found
	}
	else {   # New LDAP implementation for both ActiveDirectory and OpenLDAP with authorization.
		unless ($ldap_config->{auth_ldap_psw}) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: LDAP Admin Access password ('auth_ldap_psw' key) missing in configuration of NMIS");
			return 0;
		} # Configuration Error.
		NMISNG::Util::logAuth("Auth::_ldap_verify, INFO Verifying LDAP: credentials using access credentials.") if ($self->{debug});
		# bind LDAP for request DN of user
		$status = $ldap->bind( $ldap_config->{auth_ldap_acc}, password => $ldap_config->{auth_ldap_psw});
		# if full debugging dumps are requested, put it in a separate log file
		if ($ldap_config->{auth_ldap_debug})
		{
			open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
			print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->bind($ldap_config->{auth_ldap_acc}, password=>**************, version => 3)\n";
			print F NMISNG::Util::returnDateStamp() . ": " . Dumper($status) ."\n";
			close(F);
		}
		if (defined $status->code() && $status->code() != 0) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: LDAP validation of $ldap_config->{auth_ldap_acc}, error msg ".$status->error()." ");
			return 0;
		}
		NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: LDAP Base user '$ldap_config->{auth_ldap_acc}' is authorized") if ($self->{debug});
	
		foreach my $attr ( @attrlist ) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: LDAP search, base=$ldap_config->{auth_ldap_base},".  "filter=${attr}=$u, attr=distinguishedName") if ($self->{debug});
			my $results = $ldap->search(scope=>'sub',base=>"$ldap_config->{auth_ldap_base}",filter=>"($attr=$u)",attrs=>['distinguishedName']);
			# if full debugging dumps are requested, put it in a separate log file
			if ($ldap_config->{auth_ldap_debug})
			{
				open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
				print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->search(scope=>'sub',base=>'$ldap_config->{auth_ldap_base}',filter=>'($attr=$u)',attrs=>['distinguishedName'])\n";
				print F NMISNG::Util::returnDateStamp() . ": " . Dumper($results) ."\n";
				close(F);
			}
	
			if (($entry = $results->entry(0))) {
				$dn = $entry->dn();
				$self->{dn} = $dn;
				last;
			} else {
				NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: LDAP search failed") if ($self->{debug});
			}
		}
	
		if ($dn eq '') {
			NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: user '$u' not found in Active Directory") if ($self->{debug});
			$ldap->unbind();
			return 0;
		}
	
		my $d = $dn;
		$d =~ s/\\//g;
		NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: LDAP found distinguishedName='$d'.") if ($self->{debug});
	
		#Now we unbind and now try to login with the current user
		$ldap->unbind;

		if($sec) {
			$ldap = Net::LDAPS->new($ldap_config->{auth_ldaps_server},
				verify =>  $ldap_config->{auth_ldaps_verify},
				capath =>  $ldap_config->{auth_ldaps_capath}
			);

		} else {
			$ldap = Net::LDAP->new($ldap_config->{auth_ldap_server});
		}
		if($@ || !$ldap) {
			NMISNG::Util::logAuth("Auth::_ldap_verify, ERROR: Could not create LDAP session; ERROR: $@");
			return 0;
		}

		# check user
	
		$status = $ldap->bind("$dn",password=>"$p");
		NMISNG::Util::logAuth("Auth::_ldap_verify, DEBUG: LDAP bind dn '$d' status ".$status->code()) if ($self->{debug});
		if (defined $status->code && $status->code == 0) {
			# permitted
			$ldap->unbind();
			return 1;
		}
	
		$ldap->unbind();
	}

	return 0; # not found
}

#----------------------------------
#
# Novell eDirectory LDAP verify a username
#

sub _novell_ldap_verify {
	my $self = shift;
	my($u, $p, $auth) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);
	my $auth_ldap_debug      = NMISNG::Util::getbool($self->{config}->{'auth_ldap_debug'});
	my $sec = 0;
	$sec = 1 if ( $auth eq "novell-ldaps" );


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
		NMISNG::Util::logAuth2("can't search LDAP (anonymous bind), need binddn which is uninplemented","TODO");
		NMISNG::Util::logAuth2("LDAP anonymous bind failed","ERROR");
		return 0;
	}

	foreach $context ( split ":", $self->{config}->{'auth_ldap_base'}  ) {

		$dn = undef;
		$self->{dn} = $dn;
		# Search "attr=user" in each context
		foreach $attr ( @attrlist ) {

			$msg = $ldap->search(base=>$context,filter=>"$attr=$u",scope=>"sub",attrs=>["dn"]);
			# if full debugging dumps are requested, put it in a separate log file
			if ($auth_ldap_debug)
			{
				open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
				print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->search(base=>$context,filter=>'$attr=$u',scope=>'sub',attrs=>['dn'])\n";
				print F NMISNG::Util::returnDateStamp() . ": " . Dumper($msg) ."\n";
				close(F);
			}

			if ( $msg->is_error ) { #|| ($msg->count != 1)) { # not Found, try next context
				next;
			}
			$dn = $msg->entry(0)->dn;
			$self->{dn} = $dn;
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
		my $parameter = param($key) if param($key); 
		if( $key !~ /conf|auth_type|auth_username|auth_password/ ) {
			print hidden(-name=>$key, -default=>$parameter,-override=>'1');
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
	my $max_sessions_enabled = NMISNG::Util::getbool($self->{config}->{max_sessions_enabled});
	
	# Javascript that sets window.location to login URL
	### fixing the logout so it can be reverse proxied
	CGI::delete('auth_type'); 		# but don't keep that one
	my $url = CGI::url(-full=>1, -query=>1);
	$url =~ s!^[^:]+://!//!;

	if ($max_sessions_enabled)
	{
		# Remove session
		my $cgi = new CGI;  
		my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";
		my $sid = $cgi->cookie($self->get_session_cookie_name()) || $cgi->param($self->get_session_cookie_name()) || undef;
		my $session = load CGI::Session(undef, $sid, {Directory=>$session_dir});
		if ($session) {
			$session->delete();
			$session->flush();
		}
	}
	
	my $javascript = "function redir() { window.location = '" . $url ."'; }";
	my $cookie = $self->generate_cookie(user_name => $self->{user}, expires => "now", value => "" );

	NMISNG::Util::logAuth("INFO logout of user=$self->{user}");

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

sub _pam_verify 
{
	my ($self, $user, $password) = @_;

	eval { require Authen::PAM; };
	if ($@) 
	{
		NMISNG::Util::logAuth("ERROR, failed to load Authen::PAM module: $@");
		return 0;
	}

	# let's authenticate with the rules for our own service, 'nmis'; 
	# pam falls back to the rules for service 'other' if n/a

	# NOTE that if pam_unix is involved, then /etc/shadow must be readable by the
	# calling user, ie. the webserver
	my $pamhandle = Authen::PAM->new("nmis", 
																	 $user,				# can also be passed via conversation function
																	 # use closure to control visilibity of the password
																	 sub { 
																		 my @messages = @_; # see man pam_conv
																		 my @responses;
																		 while (@messages)
																		 {
																			 my ($code, $msg) = (shift @messages, shift @messages);
																			 if ($msg =~ /login/i 
																					 && $code == Authen::PAM::PAM_PROMPT_ECHO_ON())
																			 {
																				 push @responses, Authen::PAM::PAM_SUCCESS(), $user;
																			 }
																			 elsif ($msg =~ /password/i 
																							&& $code == Authen::PAM::PAM_PROMPT_ECHO_OFF())
																			 {
																				 push @responses, Authen::PAM::PAM_SUCCESS(), $password;
																			 }
																		 }
																		 push @responses, Authen::PAM::PAM_SUCCESS();
																		 return @responses; 
																	 });
	if (ref($pamhandle) ne "Authen::PAM")
	{
		NMISNG::Util::logAuth("ERROR, failed to instantiate PAM object: "
													.Authen::PAM::pam_strerror($pamhandle));
		return 0;
	}

	# failure of these two isn't vital for auth
	$pamhandle->pam_set_item(Authen::PAM::PAM_RUSER(), $user);
	$pamhandle->pam_set_item(Authen::PAM::PAM_RHOST(), CGI::remote_addr());

	# time to go!
	my $res = $pamhandle->pam_authenticate();
	return 1 if ($res == Authen::PAM::PAM_SUCCESS());

	NMISNG::Util::logAuth("ERROR, PAM authentication failed: "
			. $pamhandle->pam_strerror($res));
	return 0;
}

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

sub _crowd_verify {
	my $self = shift;
	my($user, $pswd) = @_;

	eval { require Mojo::UserAgent; require Mojo::URL; };
	if ($@)
	{
		NMISNG::Util::logAuth("ERROR Crowd authentication method requires Mojo::UserAgent and Mojo::URL but modules not available: $@!");
		return 0;
	}

	if (!$self->{config}->{auth_crowd_server})
	{
		NMISNG::Util::logAuth("ERROR, no crowd server URL specified in configuration!");
		return 0;
	}
	elsif (!$self->{config}->{auth_crowd_user} || !$self->{config}->{auth_crowd_password})
	{
		NMISNG::Util::logAuth("ERROR, no crowd user/password specified in configuration");
		return 0;
	}

	# plain url with method and possibly port, but without crowd auth info
	my $url = Mojo::URL->new($self->{config}->{auth_crowd_server}
													 ."/crowd/rest/usermanagement/1/authentication");

	# add crowd user info to the url
	my $auth_crowd_user = $self->{config}->{auth_crowd_user};
	my $auth_crowd_password = $self->{config}->{auth_crowd_password};
	$url->userinfo("$auth_crowd_user:$auth_crowd_password");

	# add the username query
	$url->query(username => $user);

	my $ua = Mojo::UserAgent->new;
	NMISNG::Util::logAuth("DEBUG created Mojo::UserAgent") if $self->{debug};
	my $tx = $ua->post(
		$url => {'Content-Type' => 'application/json',
		'Accept' => 'application/json'} => json => {value => $pswd}
	);
	NMISNG::Util::logAuth("Mojo::UserAgent Transaction Response:\n".Dumper($tx->res)) if $self->{debug};

	# 200 is good and contains user info, 400 is not good, that's all it really tells us
	# https://developer.atlassian.com/display/CROWDDEV/JSON+Requests+and+Responses
	if(my $tx_err = $tx->error) {
		NMISNG::Util::logAuth("_crowd_verify Load Error");
		NMISNG::Util::logAuth("$tx_err->{code} CROWD response: $tx_err->{message}");
		return 0
	}
	my $reply = $tx->res->json;

	if( defined($reply->{name}) && $reply->{name} eq "$user" )
	{
		return 1;
	}

}

# check login - logout - go
# args: type, username, password, headeropts, listmodules
sub loginout {
	my ($self, %args) = @_;
	my $type = lc($args{type});
	my $username = $args{username};
	my $password = $args{password};
	my $listmodules = $args{listmodules};
	my $headeropts = $args{headeropts};
	my @cookies = ();
	my $session;
	my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";
	my $last_login_dir = $self->{config}->{'last_login_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system";
		
	NMISNG::Util::logAuth("DEBUG: loginout, Type=$type Username=$username")
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
	my $max_sessions_enabled = NMISNG::Util::getbool($self->{config}->{max_sessions_enabled});
	my $expire_users = NMISNG::Util::getbool($self->{config}->{expire_users});
	
	if (defined($username) && $username ne '')
	{
		NMISNG::Util::logAuth("Account '$username' is trying to log in.");
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
		
		my $max_sessions = $self->get_max_sessions(user => $username);
		NMISNG::Util::logAuth("Max sessions is $max_sessions.");
		if ($max_sessions_enabled)
		{
			my $max_sessions = $self->get_max_sessions(user => $username);
			NMISNG::Util::logAuth("Max sessions is $max_sessions.");
			my ($error, $sessions) = $self->get_live_session_counter(user => $username);
			if (($max_sessions != 0) && ($sessions >= $max_sessions))
			{
				NMISNG::Util::logAuth("Account '$username' max sessions ($max_sessions) reached.");
				$self->do_login(listmodules => $listmodules,
												msg => "Too many open sessions ($sessions), login not allowed");
				return 0;
			}
		}
		
		if ($expire_users) {
			my $expire_after = $self->get_expire_at(user => $username);
			my $last_login = $self->get_last_login(user => $username);
			if ($expire_after != 0 and defined($last_login)) {
				my $t = time - $last_login;
				NMISNG::Util::logAuth("DEBUG: verifying expire after $expire_after < last login $last_login");
				if ($t > $expire_after) {
					NMISNG::Util::logAuth("DEBUG: $t < $expire_after. User is locked.");
					$self->do_login(listmodules => $listmodules,
													msg => "User expired, login not allowed");
					return 0;
				} 
			}	
		}
		
		NMISNG::Util::logAuth("DEBUG: verifying $username") if $self->{debug};
		if( $self->user_verify($username,$password))
		{
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

			NMISNG::Util::logAuth("user=$self->{user} logged in");
			NMISNG::Util::logAuth("DEBUG: loginout, User=$self->{user} logged in") if $self->{debug};
			
			# Create session
#			if ($max_sessions_enabled or $expire_users) {
				if ($max_sessions_enabled) {
					my $max_sessions = $self->get_max_sessions(user => $username);
					if ($max_sessions != 0) {
						$session = $self->generate_session(user_name => $self->{user});
					}
				} else {
					$session = $self->generate_session(user_name => $self->{user});
				}	
				if ($session) {
					NMISNG::Util::logAuth("DEBUG: loginout, Created a new session.") if $self->{debug};
					$session->param('auth',                $self->{auth});
					$session->param('username',            $self->{user});
					$session->param('dn',                  $self->{dn});
					$session->param('priv',                $self->{priv});
					$session->param('privlevel',           $self->{privlevel});
					$session->param('groups',              $self->{groups});
					$session->param('rawgroups',           $self->{rawgroups});
				} else {
					NMISNG::Util::logAuth("DEBUG: loginout, Unable to create a new session.") if $self->{debug};
				}
#			}
			
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
							password => NMISNG::Util::decrypt($self->{config}->{mail_password}, 'email', 'mail_password'),

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
			NMISNG::Util::logAuth("DEBUG: invalid session ") if $self->{debug};

			#$self->do_login(msg=>"Session Expired or Invalid Session");
			$self->do_login(msg=>"", listmodules => $listmodules);
			return 0;
		}
		else { # session is good.
			$self->SetUser( $username );
			NMISNG::Util::logAuth("DEBUG: cookie OK") if $self->{debug};
		}
	}

	# logout has to be down here because we need the username loaded to generate the correct cookie
	if(lc $type eq 'logout') {
		$self->do_logout(); # bye
		return 0;
	}

	
	# generate the cookie if $self->user is set
	if ($self->{user}) {
#		if ($max_sessions_enabled)
#		{
			# Load session
			if (!$session) {
				$session = CGI::Session->load(undef, undef, {Directory=>$session_dir});
			}
			
			# This is the session cookie
			if ($session) {
				NMISNG::Util::logAuth("DEBUG: loginout, Found an existing session.") if $self->{debug};
				$session->param('auth',                $self->{auth});
				$session->param('username',            $self->{user});
				$session->param('dn',                  $self->{dn});
				$session->param('priv',                $self->{priv});
				$session->param('privlevel',           $self->{privlevel});
				$session->param('groups',              $self->{groups});
				$session->param('rawgroups',           $self->{rawgroups});
				my $cookie = $self->generate_cookie(user_name => $self->{user}, name => $session->name, value => $session->id);
				push @cookies, $cookie;
				NMISNG::Util::logAuth("DEBUG: loginout made Session cookie $cookies[0]") if $self->{debug};
			} else {
				NMISNG::Util::logAuth("DEBUG: loginout, Unable to locate an existing session.") if $self->{debug};
			}
#		}
		
		# Update last login
		$self->update_last_login(user => $self->{user});
		
		push @cookies, $self->generate_cookie(user_name => $self->{user});
		NMISNG::Util::logAuth("DEBUG: loginout made User cookie $cookies[0]") if $self->{debug};
	}
	# user should be set at this point, if not then redirect
	unless ($self->{user}) {
		NMISNG::Util::logAuth("DEBUG: loginout, Forcing login, shouldn't have gotten this far") if $self->{debug};
		$self->do_login( msg => "Login failed, internal error", listmodules => $listmodules);
		return 0;
	}
	$headeropts->{-cookie} = [@cookies];
	return 1; # all ok
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
	my ($self,$user) = @_;
	$self->{_require} = 1;
	# set default privileges to lowest level
	$self->{priv} = "anonymous";
	$self->{privlevel} = 5;
	$self->SetGroups();

	if ( $user )
	{
		# Determine if we are already logged in.
		NMISNG::Util::logAuth("DEBUG Auth::SetUser, verifying user '$user'.") if $self->{debug};
		my $testCookie = $self->verify_id();
		if( $testCookie ne '' ) { # Found valid cookie
			NMISNG::Util::logAuth("DEBUG Auth::SetUser, user '$user' verified.") if $self->{debug};
			my $cgi = new CGI;
			my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";
			my $sid = $cgi->cookie($self->get_session_cookie_name()) || $cgi->param($self->get_session_cookie_name()) || undef;
			my $session = load CGI::Session(undef, $sid, {Directory=>$session_dir});
			if ($session && $session->param('priv')) {
				NMISNG::Util::logAuth("DEBUG Auth::SetUser, User '$user' found cached priveleges.") if $self->{debug};
				$self->{user}      = $user;
				$self->{auth}      = $session->param('auth');
				$self->{dn}        = $session->param('dn');
				$self->{priv}      = $session->param('priv');
				$self->{privlevel} = $session->param('privlevel');
				$self->{rawgroups} = $session->param('rawgroups');
				$self->SetGroups( rawgroups => $self->{rawgroups} );
				return 1;
			}
		}
		$self->{user} = $user; # username
		return $self->_GetPrivs($self->{user});
	}
	else
	{
		NMISNG::Util::logAuth("DEBUG Auth::SetUser, no user.") if $self->{debug};
		$self->{user} = undef;
		$self->_GetPrivs(undef);
		return 0;
	}
}

#----------------------------------

# Set the groups for the current user
# param - rawgroups
sub SetGroups
{
	my ($self,%args) = @_;

	$self->{rawgroups} = undef;
	$self->{groups} = [];
	if( $args{rawgroups} )
	{
		my $rawgroups = $self->{rawgroups} = $args{rawgroups};
		my @groups = sort(split /\s*,\s*/, NMISNG::Util::stripSpaces($rawgroups));
		if ( not @groups and $self->{config}->{auth_default_groups} ne "" )
		{
			@groups = split /,/, $self->{config}->{auth_default_groups};
			NMISNG::Util::logAuth("INFO Auth::SetGroups, Groups not found for User \"$self->{user}\" using groups configured in Config.nmis->auth_default_groups");
		}
		push @{$self->{groups}}, "network";

		# is the user authorised for all (known and unknown) groups? then record that
		if ( grep { $_ eq 'all' } @groups)
		{
			$self->{all_groups_allowed} = 1;
			$self->{groups} = \@groups;
		}
		elsif ( $rawgroups eq "none" or $rawgroups eq "" )
		{
			$self->{groups} = [];
			delete $self->{all_groups_allowed};
		}
		else
		{
			$self->{groups} = \@groups;
			delete $self->{all_groups_allowed};
		}
	}
	elsif( $args{grouplist} )
	{
		# default group stuff does not apply if the list is specific
		$self->{groups}    = $args{grouplist};
		$self->{rawgroups} = $args{grouplist};
	}
	else
	{
		$self->{groups} = [];
		delete $self->{all_groups_allowed};
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
		if (lc($g) eq lc($group))		# fixme9 dangerous
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

# Generate a session to track user login state in the server side
sub generate_session {
	
	my ($self, %args) = @_;
	
	my $token;
	my $user = $args{user_name};
	my $name = $self->get_cookie_name;
	my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";
	my $expires = ($args{expires} // $self->{config}->{auth_expire}) || '+60min';
	my $cookiedomain = $self->get_cookie_domain;
	
	if ($self->{cookie_flavour} eq "nmis")
	{
		$token = $self->get_cookie_token($user);
	}
	elsif ($self->{cookie_flavour} eq "omk")
	{
		my $expires_ts;
		if ($expires eq "now")
		{
			$expires_ts = time();
		}
		elsif ($expires =~ /^([+-]?\d+)\s*(\{s|m|min|h|d|M|y})$/)
		{
			my ($offset, $unit) = ($1, $2);
			# the last two are clearly imprecise
			my %factors = ( s => 1, m => 60, 'min' => 60, h => 3600, d => 86400, M => 31*86400, y => 365 * 86400 );
	
			$expires_ts = time + ($offset * $factors{$unit});
		}
		else # assume it's something absolute and parsable
		{
			$expires_ts = NMISNG::Util::parseDateTime($expires) || NMISNG::Util::getUnixTime($expires);
		}
	
		# create session data structure, encode as base64 (but - instead of =), sign with key and combine
		my $sessiondata = encode_json( { auth_data => $user,
																		 expires => $expires_ts } );
		my $value = encode_base64($sessiondata, ''); # no end of line separator please
		$value =~ y/=/-/;
		my $web_key = $self->{config}->{auth_web_key} // $CHOCOLATE_CHIP;
		my $signature = Digest::SHA::hmac_sha1_hex($value, $web_key);
		
		$token = $self->get_cookie_token($signature);
	}
	# Generate sesssion
	my $session = CGI::Session->new(undef, $token, {Directory=>$session_dir});
	NMISNG::Util::logAuth("INFO Generating session $name for user $user") if ($self->{debug});
	
	$session->param('username', $user);
	$expires =~ s/min/m/g; 
	$session->expire($expires);
	return $session;
}

# returns the current session counter for the given user
# args: user, required.
# returns: (undef,counter) or error message
sub get_live_session_counter
{
	my ($self, %args) = @_;
	my $user = $args{"user"};
	my $remove_all = $args{"remove_all"};
	
	return "cannot get failure counter without valid user argument!" if (!$user);

	my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";
	my $count = 0;

	# CGI:: Session does not have a max concurrent sessions
	# Or get session by user
	# So we will get all the session files, filter by user and calculate if they are expired
	opendir(DIR, $session_dir) or NMISNG::Util::logAuth("Could not open $session_dir\n");
	
	while (my $filename = readdir(DIR)) {
		open(FH, '<', "$session_dir/$filename") or NMISNG::Util::logAuth($!);
		while(<FH>) {
		   #$_ =~ /(\$D = (.*);;\$D)/;
		   #my $s = $2;
		   my $s = $_;
		   $s =~ s/\$D = //;
		   $s  =~ s/;;\$D//;
		   my $hash = eval $s;
		   if ($@) {
					NMISNG::Util::logAuth("ERROR $@");
			}

		   if (($hash->{username} eq $user) or ($user eq "ALL")) {
			 if ($remove_all) {
				# Remove all files for the given user
				unlink "$session_dir/$filename";
			 } else {
				# Remove expired sessions
				if ($self->not_expired(time_exp => $hash->{_SESSION_ATIME}) == 1) {
					$count++;
					logAuth("Increment counter $count for user $user") if ($self->{debug});
				 } else {
					# Clean up
					unlink "$session_dir/$filename";
				 }
			 } 
		   }
		}	
		close(FH);
	}
	NMISNG::Util::logAuth("** $count sessions open for user $user") if ($self->{debug});
	
	return (undef, $count);
}

# returns the current session counter for the given user
# args: user, required.
# returns: (undef,counter) or error message
sub get_all_live_session_counter
{
	my ($self, %args) = @_;
	my $all;

	my $session_dir = $self->{config}->{'session_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system/user_session";

	# CGI:: Session does not have a max concurrent sessions
	# Or get session by user
	# So we will get all the session files, filter by user and calculate if they are expired
	opendir(DIR, $session_dir) or NMISNG::Util::logAuth("Could not open $session_dir\n");
	
	# Get users, init counter
	while (my $filename = readdir(DIR)) {
		open(FH, '<', "$session_dir/$filename") or NMISNG::Util::logAuth($!);
		while(<FH>) {
		   my $s = $_;
		   $s =~ s/\$D = //;
		   $s  =~ s/;;\$D//;
		   my $hash = eval $s;
		   if ($@) {
					logAuth("ERROR $@");
			}
		   my $user = $hash->{username};
		   
		   if ($self->not_expired(time_exp => $hash->{_SESSION_ATIME}) == 1) {
			  if (defined ($all->{$user}->{sessions})) {
				 $all->{$user}->{sessions} = $all->{$user}->{sessions} + 1;
			   } else {
				$all->{$user}->{sessions} = 1;
			   }
			} else {
					# Clean up
					unlink "$session_dir/$filename";
			}
		   
		  
		}	
		close(FH);
	}

	return $all;
}

# check if session is expired
sub not_expired {
	my ($self, %args) = @_;
	my $time_exp = $args{time_exp};
	
	my $expires = ($args{expires} // $self->{config}->{auth_expire}) || '+60min';
	my $expires_ts = $expires;
	if ($expires =~ /^([+-]?\d+)\s*(\{s|m|min|h|d|M|y})$/)
		{
			my ($offset, $unit) = ($1, $2);
			# the last two are clearly imprecise
			my %factors = ( s => 1, m => 60, 'min' => 60, h => 3600, d => 86400, M => 31*86400, y => 365 * 86400 );

			$expires_ts = ($offset * $factors{$unit});
		}
		NMISNG::Util::logAuth("Expires: ".(time - $time_exp)." and expire at $expires_ts") if ($self->{debug});
	if ((time - $time_exp) < $expires_ts) {
		return 1;
	}
	
 	return 0;
}

#----------------------------------

# check if the group is in the user's group list
#
sub get_max_sessions {
	my ($self, %args) = @_;
	my $user = $args{user};
	my $max_sessions = $self->{config}->{max_sessions};

	 my $UT = NMISNG::Util::loadTable(dir=>'conf',name=>"Users");
	if ( exists $UT->{$user}{max_sessions} ) {
		return $UT->{$user}{max_sessions};
	}
	return $max_sessions;
}

# Get the session cookie name 
sub get_session_cookie_name
{
	my ($self) = @_;
	# This is the CGI::Session default name
	return 'CGISESSID';
}

# Get the session cookie name 
sub get_expire_at
{
	my ($self, %args) = @_;
	my $user = $args{user};
	my $expire_at = $self->{config}->{expire_users_after};

	my $UT = NMISNG::Util::loadTable(dir=>'conf',name=>"Users");

	if ( exists $UT->{$user}{expire_after} ) {
		return $UT->{$user}{expire_after};
	}
	return $expire_at;
}

# Get the session cookie name 
sub get_last_login
{
	my ($self, %args) = @_;
	my $user = $args{user};
	my $last_login_dir = $self->{config}->{'last_login_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system";
	my $last_login_file = $last_login_dir . "/users_login.json";
	my $userdata;

	return (0, "User is required") if (!$user);
	# CGI:: Session does not have a max concurrent sessions
	# Or get session by user
	# So we will get all the session files, filter by user and calculate if they are expired
	opendir(DIR, $last_login_dir) or NMISNG::Util::logAuth("Could not open $last_login_dir\n");
	
	if (-f $last_login_file)
	{
		open(F, $last_login_file) or return "cannot read $last_login_file: $!";
		$userdata = eval { decode_json(join("", <F>)); };
		close F;
		if ($@ or ref($userdata) ne "HASH")
		{
			NMISNG::Util::logAuth("Could not open $last_login_dir\n");		# broken, get rid of it
			return (0, "Could not open $last_login_dir\n");
		}
	}

	return $userdata->{$user};
}

# Update last login for user
sub update_last_login
{
	my ($self, %args) = @_;
	my $user = $args{user};
	my $lastlogin = $args{lastlogin};
	my $remove = $args{remove};
	
	my $last_login_dir = $self->{config}->{'last_login_dir'} // $self->{config}->{'<nmis_var>'}."/nmis_system";
	my $last_login_file = $last_login_dir . "/users_login.json";
	my $userdata;

	return (0, "User is required") if (!$user);
	# CGI:: Session does not have a max concurrent sessions
	# Or get session by user
	# So we will get all the session files, filter by user and calculate if they are expired
	opendir(DIR, $last_login_dir) or NMISNG::Util::logAuth("Could not open $last_login_dir\n");
	
	if (!-d $last_login_dir)
	{
		createDir($last_login_dir) 
	}

	if (!-e $last_login_file) {
		open(F, ">$last_login_file") or return (0, "cannot read $last_login_file: $!");
		close F;
		if (-f $last_login_file) {
			eval {
				system("/usr/local/nmis9/bin/nmis-cli", "act=fixperms");
			};
		}
	}
	elsif (-f $last_login_file) {
		open(F, $last_login_file) or return (0, "cannot read $last_login_file: $!");
		$userdata = eval { decode_json(join("", <F>)); };
		close F;
		if ($@ or ref($userdata) ne "HASH")
		{
			NMISNG::Util::logAuth("Could not open $last_login_dir\n");		# broken, get rid of it
			return (0, "Could not open $last_login_dir\n");
		}
	}

	if ($remove) {
		delete $userdata->{$user};
	} elsif ( $user eq "ALL" )  {
		foreach my $u (keys %{$userdata}) {
			$userdata->{$u} = $lastlogin // time;
		}
	} else {
		$userdata->{$user} = $lastlogin // time;
	}
	
	open(F,">$last_login_file") or return (0, "cannot write $last_login_file: $!");
	print F encode_json($userdata);
	close(F);
	
	if ($@){NMISNG::Util::logAuth("Could not chmod g+rw $last_login_file: $@\n");}

	return 1;
}

#----------------------------------
# Private routines go here
#----------------------------------

# _GetPrivs -- load and parse the conf/Users.nmis file
# also loads conf/PrivMap.nmis to map the privilege to a
# numeric privilege level.
# unloads if user is undef
#
# user record contains parsed and expanded groups list
# AND rawgroups (=original group value from the source) so that groups=all can be matched
# with non-nmis groups and things that are groupless


sub _GetPrivs
{
	my $self = shift;
	my $user = lc shift;
	my $groupList;
	my $auth_ldap_acc          = $self->{config}->{'auth_ldap_acc'};
	my $auth_ldap_privs        = $self->{config}->{'auth_ldap_privs'};
	my $auth_default_groups    = $self->{config}->{'auth_default_groups'};
	my $auth_default_privilege = $self->{config}->{'auth_default_privilege'};
	if ( $self->{auth} eq "ms-ldap" or $self->{auth} eq "ms-ldaps") {
		NMISNG::Util::logAuth("INFO Honoring legacy ActiveDirectory settings.") if ($self->{debug});
		$auth_ldap_acc     = $self->{config}->{'auth_ms_ldap_acc'}                           if ($self->{config}->{'auth_ms_ldap_acc'});
		$auth_ldap_privs   = $self->{config}->{'auth_ms_ldap_privs'}                         if ($self->{config}->{'auth_ms_ldap_privs'});
	}

	# unset because some things exit early
	$self->SetGroups();

	# if no user exit early (used as a way to unset everything)
	if( !$user )
	{
		$self->{priv} = "";
		$self->{privlevel} = 5;
		return 0;
	}

	my $UT  = Compat::NMIS::loadGenericTable("Users");
	my $PMT = Compat::NMIS::loadGenericTable("PrivMap");
	my $user_local = 0;

	if ( exists $UT->{$user}{privilege} and $UT->{$user}{privilege} ne ""  ) {
		NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' using local for privs") if $self->{debug};
		$self->{priv} = $UT->{$user}{privilege};
		$user_local = 1;
		NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' use priv: $self->{priv}") if $self->{debug};
    } elsif ( $auth_ldap_privs && $auth_ldap_acc ) { # If 'auth_ldap_acc' is unset, then we are authenticating without authorization, so we have to assign default priveleges unless we are defined locally.
		NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' using _get_ldap_privs for privs") if $self->{debug};
		($self->{priv}, $groupList) = $self->_get_ldap_privs(user => $user);
		NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' use priv: $self->{priv}") if $self->{debug};
		NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' use mapping for groups: $groupList") if $self->{debug};
	}
	else {
		if ( $auth_default_privilege ne "" and !NMISNG::Util::getbool($auth_default_privilege,"invert") ) {
			$self->{priv} = $auth_default_privilege;
			$self->{privlevel} = 5;
			NMISNG::Util::logAuth("WARN Auth::_GetPrivs, User '$user' not found in Users table, assigned default privilege '$auth_default_privilege.'");
			$user_local = 1;
		} else {
			$self->{priv} = "";
			$self->{privlevel} = 5;
			NMISNG::Util::logAuth("ERROR Auth::_GetPrivs, User '$user' not found in Users table, no default privilege configured");
			return 0;
		}
		# We dont have a user in NMIS but we want the user to be able to login and take default groups
		if ( $auth_default_groups and $auth_default_groups ne "" ) {
			$UT->{$user}{groups} = $auth_default_groups;
		}
	}

	if ( ! exists $PMT->{$self->{priv}} and $PMT->{$self->{priv}}{level} eq "" ) {
		NMISNG::Util::logAuth("WARN Auth::_GetPrivs, Privilege '$self->{priv}' not found for user '$user'.");
		$self->{priv} = "";
		$self->{privlevel} = 5;
		return 0;
	}

	$self->{privlevel} = 5;
	if ( $PMT->{$self->{priv}}{level} ne "" ) {
		$self->{privlevel} = $PMT->{$self->{priv}}{level};
	}
	NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' has priv='$self->{priv}' and privlevel='$self->{privlevel}'.") if $self->{debug};

	if ($auth_ldap_privs and $user_local == 0) {
		$self->SetGroups( rawgroups => $groupList );
	} else {
		$self->SetGroups( rawgroups => $UT->{$user}{groups} );
	}
   	NMISNG::Util::logAuth("DEBUG Auth::_GetPrivs, User '$user' has groups '" . join(", ", @{$self->{groups}}) . "'.") if ($self->{debug});
	
	return 1;
}

# Mapping with ldap
# Get groups for the logged in user from ldap
# And map the groups with a local privilege from nmis
# Returns privilege, and group
sub _get_ldap_privs
{
	my ($self, %args) = @_;
	my $user = $args{"user"};
	my $ldap;
    my $sec = 0;

	my $ldap_config = $self->configure_ldap($self);
	
     if ((!$ldap_config->{auth_ldaps_server}) and (!$ldap_config->{auth_ldap_server})) {
        NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, called but not configured");
		return 0;
    }

    if ( !$ldap_config->{auth_ldaps_server} eq "") {
        $sec = 1;
    }

	NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, User: ". Dumper($user) . "\n") if ($self->{debug});


	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, no IO::Socket::SSL; Net::LDAPS installed");
			return 0;
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, no Net::LDAP installed,".$@);
			return 0;
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		my $ldapServer = $ldap_config->{auth_ldaps_server};
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Attempting to create a secure connection for 'auth_ldaps_server' ($ldapServer)") if ($self->{debug});
		$ldap = new Net::LDAPS($ldapServer);
	} else {
		my $ldapServer = $ldap_config->{auth_ldap_server};
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Attempting to create a connection for 'auth_ldap_server' ($ldapServer')") if ($self->{debug});
		$ldap = new Net::LDAP($ldapServer);
	}
	if(!$ldap) {
		NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, no LDAP object created, maybe ldap server address missing in NMIS configuration");
		return 0;
	}

	# LDAP authentication
    my $mesg;
    my $success = 0;
	$mesg = $ldap->bind ($ldap_config->{auth_ldap_acc}, password => $ldap_config->{auth_ldap_psw});
	# if full debugging dumps are requested, put it in a separate log file
	if ($ldap_config->{auth_ldap_debug})
	{
		open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
		print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->bind($ldap_config->{auth_ldap_acc}, password=>**************)\n";
		print F NMISNG::Util::returnDateStamp() . ": " . Dumper($mesg) ."\n";
		close(F);
	}
	if ($mesg->{resultCode} != 0) {
		NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, Error binding to ldap.");
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, " . Dumper($mesg)) if ($self->{debug});
		return 0;
	}
	
	# Active Directory should work here, but OpenLDAP may not.
	my @list_member;
	my $count = 0;
	my $attrs = $ldap_config->{auth_ldap_group} ?  [$ldap_config->{auth_ldap_group}] : ['memberOf'];
	my @filterlist = split( "[ ,]", ($ldap_config->{auth_ldap_attr} ?  $ldap_config->{auth_ldap_attr} : 'samaccountname') );
	foreach my $filter ( @filterlist ) {
		NMISNG::Util::logAuth("DEBUG LDAP Search base: '$ldap_config->{auth_ldap_base}', attr: '" . join(", ", @{$attrs}) . "', Searchstring: ($filter=$user)") if ($self->{debug});
		my $result = $ldap->search (base => $ldap_config->{auth_ldap_base}, scope => "sub", filter  => "($filter=$user)", attrs => $attrs);
		# if full debugging dumps are requested, put it in a separate log file
		if ($ldap_config->{auth_ldap_debug})
		{
			open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
			print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->search (base => $ldap_config->{auth_ldap_base}, scope => 'sub', filter  => '($filter=$user)', attrs => " . join(", ", @{$attrs}) . ")\n";
			print F NMISNG::Util::returnDateStamp() . ": " . Dumper($result) ."\n";
			close(F);
		}
	
		#NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, LDAP Search RESULT:" . Dumper($result)) if ($self->{debug});
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, LDAP Search ERROR: " . $result->error ) if ($self->{debug});
		if (!$result or !$result->{entries}) {
			if ($success) {
				$count = 0;
			}
			else {
				NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, No groups for '$user'. ". $result->{errorMessage});
				return 0;
			}
		}
		else {
			$count = $result->count;
		}
		# Result processing
		# We always get entries, but sometimes it's empty.
		# How many entries were returned from the search
		if ($count > 0) {
			NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Found $count groups using the 'attrs' filter.") if ($self->{debug});
			for (my $index = 0 ; $index < $count ; $index++)
			{
				my $entry = $result->entry($index);
				my @attrs = $entry->attributes; # Obtain attributes for this entry.
				foreach my $var (@attrs)
				{
					NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Entry $count Var is '$var'.") if ($self->{debug});
					#get a list of values for a given attribute
					my $attr = $entry->get_value( $var, asref => 1 );
					NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Entry $count Attr is '" . join(", ", @{$attr}) . "'.") if ($self->{debug});
					if ( defined($attr) )
					{
						foreach my $value ( @$attr )
						{
							NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: $var: $value") if ($self->{debug});
							if ($value =~ /CN/i) {
								my @ignore   = split("[,=]", $value);
								my $groupCN = $ignore[1];;
								NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Adding Group: '$groupCN'") if ($self->{debug});
								push @list_member, $groupCN;
							}
							$success = 1;
						}
					}			
				}
			}
		}
	}

	if (!$success) {
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Found no groups using the 'attrs' filter.") if ($self->{debug});
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Searching all groups with a user filter.") if ($self->{debug});
		foreach my $filter ( @filterlist ) {
			# OpenLDAP will probably succeed here.
			my $attrs = [ "cn" ];
			NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, LDAP Search base: " . $ldap_config->{auth_ldap_base} . ", attr: '" . join(", ", @{$attrs}) . "', Searchstring: '(&(member=$self->{dn})(|(objectClass=groupOfNames)(objectClass=groupOfUniqueNames)(objectClass=group)))'.") if ($self->{debug});
			my $result = $ldap->search (base => $ldap_config->{auth_ldap_base}, filter  => "(&(member=$self->{dn})(|(objectClass=groupOfNames)(objectClass=groupOfUniqueNames)(objectClass=group)))", attrs => $attrs);
			# if full debugging dumps are requested, put it in a separate log file
			if ($ldap_config->{auth_ldap_debug})
			{
				open(F, ">>", $self->{config}->{'<nmis_logs>'}."/auth-ldap-debug.log");
				print F NMISNG::Util::returnDateStamp() . ": " . "\$ldap->search (base => $ldap_config->{auth_ldap_base}, scope => 'sub', filter  => '($filter=$user)', attrs => " . join(", ", @{$attrs}) . ")\n";
				print F NMISNG::Util::returnDateStamp() . ": " . Dumper($result) ."\n";
				close(F);
			}
			#NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, LDAP Search RESULT:\n" . Dumper($result) . "\n") if ($self->{debug});
			NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, LDAP Search ERROR:\n" . $result->error . "\n") if ($self->{debug});
			if (!$result or !$result->{entries}) {
				NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, No groups for $user. ". $result->{errorMessage});
				return 0;
			}
			# Result processing, second try.
			# How many entries were returned from the search
			my $count = $result->count;
			if ($count > 0) {
				for (my $index = 0 ; $index < $count ; $index++)
				{
					my $entry = $result->entry($index);
					my @attrs = $entry->attributes; # Obtain attributes for this entry.
					foreach my $var (@attrs)
					{
						#get a list of values for a given attribute
						my $attr = $entry->get_value( $var, asref => 1 );
						if ( defined($attr) )
						{
							foreach my $value ( @$attr )
							{
								NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: $var: $value") if ($self->{debug});
								if ($value =~ /CN/i) {
									NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Adding Group: '$value'") if ($self->{debug});
									push @list_member, $value;
								}
								$success = 1;
							}
						}			
					}
				}
			}
			else {
				NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs: Found no groups searching all groups for the distinctiveName.") if ($self->{debug});
			}
		}
	}
	
    NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Groups for '$user' are: " . join(", ", @{list_member})) if ($self->{debug});

	
	# Read mapping file
	# Mapping using NMIS table system instead of  auth_ldap_privs file
	# NMIS will try conf then conf-default
	my $ldap_mapping_file = $ldap_config->{auth_ldap_privs_file};
	my $usergroups =  NMISNG::Util::loadTable(dir=>'conf',name=> $ldap_mapping_file);
	if( $usergroups && ref($usergroups) eq 'HASH' ) {		
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, ldap_mapping_file AuthLdapPrivs found and read.") if ($self->{debug});
		NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Mapped User groups Dump: " . Dumper($usergroups)) if ($self->{debug});
		eval { NMISNG::Util::logAuth("DEBUG Auth::_get_ldap_privs, Mapped User Groups are: " . join(", ", @{keys %{$usergroups}})) if ($self->{debug}); };
	} else {
		NMISNG::Util::logAuth("ERROR Auth::_get_ldap_privs, cannot read Table AuthLdapPrivs: $usergroups");
		return 0;
	}

	my $usergroups_lc;
	foreach my $key (keys %{$usergroups})
	{
		$usergroups_lc->{lc($key)} = $usergroups->{$key};
	}

	my %matches;
	my $numMatch = 0;
	my $chosen;
	# Match mapping groups with an LDAP group
	NMISNG::Util::logAuth("Auth::get_ldap_privs, Checking users: '$user' groups, list_members: " . join(", ", @list_member)) if ($self->{debug});
	foreach my $group (@list_member) 
	{
		$group = lc($group);
		NMISNG::Util::logAuth("Auth::get_ldap_privs, Checking group '$group' for '$user'") if ($self->{debug});
		if (exists $usergroups_lc->{$group})
		{
			NMISNG::Util::logAuth("Auth::get_ldap_privs, Privilege '".$usergroups_lc->{$group}->{privilege}."' for '$group' found") if ($self->{debug});
			$matches{$group}->{privilege} = $usergroups_lc->{$group}->{privilege};
			# just in case they come in as an array, this system likes comma seperated
			if( ref($usergroups_lc->{$group}->{groups}) eq 'ARRAY') {
				$usergroups_lc->{$group}->{groups} = join(",", @{$usergroups_lc->{$group}->{groups}});
			}
			$matches{$group}->{groups} = $usergroups_lc->{$group}->{groups};
			$matches{$group}->{priority} = $usergroups_lc->{$group}->{priority};
			$numMatch++;
			$chosen = $matches{$group};

		} 
		else
		{
			NMISNG::Util::logAuth("Auth::get_ldap_privs, Group '$group' was not found in the list of OMK groups.");
		}
	}

	 if ($numMatch == 1){
        return ($chosen->{privilege}, $chosen->{groups});
    } elsif ($numMatch > 1) {
        foreach my $match (keys %matches) {
            if ($matches{$match}->{priority} < $chosen->{priority}) {
                $chosen = $matches{$match};
            }
        }
        return ($chosen->{privilege}, $chosen->{groups});
    } else {
        NMISNG::Util::logAuth("Auth::get_ldap_privs, No matching groups found for '$user'!");
        return 0;
    }
	return 0;
}

sub configure_ldap {
  	my ($self, %args) = @_;
	
    my $auth_ldap_base = $self->{config}->{'auth_ldap_base'} // $self->{config}->{'auth_ldap_context'};
	my $auth_ldap_acc     = $self->{config}->{'auth_ldap_acc'};
	my $auth_ldap_attr    = $self->{config}->{'auth_ldap_attr'};
	my $auth_ldap_debug   = NMISNG::Util::getbool($self->{config}->{'auth_ldap_debug'});
	my $auth_ldap_psw     = $self->{config}->{auth_ldap_psw};
	my $auth_ldap_server  = $self->{config}->{'auth_ldap_server'};
	my $auth_ldaps_capath = $self->{config}->{'auth_ldaps_capath'};
	my $auth_ldaps_server = $self->{config}->{'auth_ldaps_server'};
	my $auth_ldaps_verify = $self->{config}->{'auth_ldaps_verify'} // "optional";
	my $auth_ldap_group   = $self->{config}->{'auth_ldap_group'};
	my $auth_ldap_privs   = $self->{config}->{'auth_ldap_privs'};
    my $auth_ldap_privs_file = $self->{config}->{'auth_ldap_privs_file'} // "AuthLdapPrivs";

	if ( $self->{auth} eq "ms-ldap" or $self->{auth} eq "ms-ldaps") {
		NMISNG::Util::logAuth("Auth::_ldap_verify, INFO: Honoring legacy ActiveDirectory settings.") if ($self->{debug});
		$auth_ldap_acc     = $self->{config}->{'auth_ms_ldap_acc'} if ($self->{config}->{'auth_ms_ldap_acc'});
		$auth_ldap_attr    = $self->{config}->{'auth_ms_ldap_attr'} if ($self->{config}->{'auth_ms_ldap_attr'});
		# Retrieve the LDAP base configuration
		# Prioritize 'auth_ms_ldap_base' over 'auth_ms_ldap_context' if both are defined
		# Use 'auth_ms_ldap_base' if available, otherwise fallback to 'auth_ms_ldap_context'. Remember 'auth_ldap_context' is retired value.
		if (defined ($self->{config}->{'auth_ms_ldap_base'}) || defined ($self->{config}->{'auth_ms_ldap_context'})){
			$auth_ldap_base = $self->{config}->{'auth_ms_ldap_base'} // $self->{config}->{'auth_ms_ldap_context'};
		}
		if (defined ($self->{config}->{'auth_ms_ldap_psw'}) || defined ($self->{config}->{'auth_ms_ldap_dn_psw'})){
			$auth_ldap_psw = $self->{config}->{'auth_ms_ldap_psw'} // $self->{config}->{'auth_ms_ldap_dn_psw'};
		}
		$auth_ldap_debug   = NMISNG::Util::getbool($self->{config}->{'auth_ms_ldap_debug'}) if ($self->{config}->{'auth_ms_ldap_debug'});
		$auth_ldap_server  = $self->{config}->{'auth_ms_ldap_server'} if ($self->{config}->{'auth_ms_ldap_server'});
		$auth_ldaps_capath = $self->{config}->{'auth_ms_ldaps_capath'} if ($self->{config}->{'auth_ms_ldap_capath'});
		$auth_ldaps_server = $self->{config}->{'auth_ms_ldaps_server'} if ($self->{config}->{'auth_ms_ldaps_server'});
		$auth_ldaps_verify = $self->{config}->{'auth_ms_ldaps_verify'} if ($self->{config}->{'auth_ms_ldap_verify'});
		$auth_ldap_acc     = $self->{config}->{'auth_ms_ldap_dn_acc'} if ($self->{config}->{'auth_ms_ldap_dn_acc'});  # retired value
		
	}

    return {
        auth_ldap_base       => $auth_ldap_base,
        auth_ldap_acc        => $auth_ldap_acc,
        auth_ldap_attr       => $auth_ldap_attr,
        auth_ldap_debug      => $auth_ldap_debug,
        auth_ldap_group      => $auth_ldap_group,
        auth_ldap_privs      => $auth_ldap_privs,
        auth_ldap_privs_file => $auth_ldap_privs_file,
        auth_ldap_psw        => $auth_ldap_psw,
        auth_ldap_server     => $auth_ldap_server,
        auth_ldaps_server    => $auth_ldaps_server,
    };
}

1;
