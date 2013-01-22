#
## $Id: Auth.pm,v 8.10 2012/11/27 00:23:20 keiths Exp $
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
#
#   This module is used in the following manner to enforce authentication:
#
#   use Auth;
#
#   my $AU = Auth->new();
#
#	if ($AU->Require) {
#		exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
#					password=>$Q->{auth_password},headeropts=>$headeropts) ;
#


package Auth;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION );

use Exporter;

$VERSION = "1.0.0";

@ISA = qw(Exporter);

@EXPORT = qw(
	Require
	loginout
	do_force_login
	User
	SetUser
	InGroup
	CheckAccess
	CheckButton
	CheckAccessCmd
);

	#loadAccessTable
	#loadUsersTable

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;

my $C;

# import external symbols from NMIS module
use NMIS;
use func;

use Data::Dumper; 
Data::Dumper->import();
$Data::Dumper::Indent = 1;

# import additional modules
use Time::ParseDate;
use File::Basename;

# I prefer the use of the library when debugging the resulting HTML script
# either one will work
use CGI::Pretty qw(:standard form *table *Tr *td center b h1 h2);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";

# You should change this to be unique for your site
#
my $CHOCOLATE_CHIP = '8fhmgBC4YSVcZMnBsWtY32KQvTE9JBeuIp1y';

my $debug = 0;

#----------------------------------

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	
	my %arg = @_;	
	$C = $arg{conf},
	
	my $self = {
		_require => 1,
		dir => $arg{dir},
		user => undef,
		config => $C,
		priv => undef,
		privlevel => 0, # default all
		cookie => undef,
		groups => undef
	};
	bless $self, $class;
	$self->_auth_init;
	return $self;
}

#----------------------------------

sub Require {
	my $self = shift;
	return $self->{_require};
}


#----------------------------------

sub _loadConf {
	my $self = shift;
	if ( not defined $C->{'<nmis_base>'} || $C->{'<nmis_base>'} eq "" ) {
		$C = loadConfTable();
	}	
	$debug |= ( $C->{auth_debug} eq 'true' );
}

#----------------------------------

sub _auth_init {
	my $self = shift;
	$self->_loadConf;
	$self->{_require} = $C->{auth_require} if defined $C->{auth_require};
}

#----------------------------------

sub debug {
	my $self = shift;
	$debug = shift;
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

	my $AC = loadAccessTable(); # get pointer of Access table

	return $AC->{$identifier}{"level$self->{privlevel}"};
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
	
	my $C = loadConfTable(); # get pointer of NMIS config table
	
	my @cookies = ();

	# check if authentication is required
	return 1 if not $C->{auth_require};
	return 1 unless $self->{_require};

	if ( ! $self->{user} ) { 
		do_force_login("Authentication is required. Please login");
		exit 0;
	}

	return 1 if $self->CheckAccessCmd($cmd);
	return 0 if $option eq "check"; # return the result of $self->CheckAccessCmd

	# Authorization failed--put access denied page and stop

	print header({type=>'text/html',expires=>'now'}) if $option eq 'header'; # add header

	print table(Tr(td({class=>'Error',align=>'center'},"Access denied")),
			Tr(td("Authorization required to access this function")),
			Tr(td("Requested access identifier is \'$cmd\'"))
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
#
###########################################################################
# for security - create login page, verify username/password/cookie
# routers.conf:
#
# verify_id -- reads cookies and params, returns verified username
sub verify_id {
	my $self = shift;
	my($uname,$cookie,$checksum, $token);

	$self->_loadConf;

	# now taste cookie 
	$cookie = cookie('nmis_auth');
	if(!$cookie) {
		logAuth("verify_id: cookie not defined");
		return ''; # not defined
	}
	if($cookie !~ /^([\w\-]+):(.+)$/) {
		logAuth("verify_id: cookie bad format");
		return ''; # bad format
	}
	($uname, $checksum) = ($1,$2);
	$token = $uname . ($main::Q->{x_remote_addr} || remote_addr());
	$token .= (defined $C->{'auth_web_key'}) ? $C->{'auth_web_key'} : $CHOCOLATE_CHIP;
	$token = unpack('%32C*',$token); # generate checksum
	return $uname if( $token eq $checksum ); # yummy
	
	# bleah, nasty taste
	return '';
}

#----------------------------------

# call appropriate verification routine
sub user_verify {
	my $self = shift;
	my($rv) = 0; # default: refuse
	my($u,$p) = @_;
	$self->_loadConf;
	my $UT = loadUsersTable();
	my $exit = 0;

	my $lc_u = lc $u;
	if ($lc_u eq lc $UT->{$lc_u}{user} && $UT->{$lc_u}{admission} eq 'bypass') {
		logAuth("INFO login request for user $u bypass permitted");
		return 1;
	}

	#2011-11-14 Integrating changes from Till Dierkesmann
	if ( ! defined($C->{auth_method_1}) ) { 
		$C->{auth_method_1} = "apache"; 
	}
	elsif ($C->{auth_method_1} eq "") { 
		$C->{auth_method_1} = "apache";     
	}

	#print STDERR "DEBUG: auth_method_1=$C->{auth_method_1},$C->{auth_method_2},$C->{auth_method_3}\n" if $debug;
	for my $auth ( $C->{auth_method_1},$C->{auth_method_2},$C->{auth_method_3} ) {
		next if $auth eq '';

		if( $auth eq "apache" ) {               
			if($ENV{'REMOTE_USER'} ne "") { $exit=1; }  
			else { $exit=0; }             
		} elsif ( $auth eq "htpasswd" ) {
			$exit = $self->_file_verify($C->{auth_htpasswd_file},$u,$p,$C->{auth_htpasswd_encrypt});

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
		
		} elsif ( $auth eq "novell-ldap" ) {
			$exit = _novell_ldap_verify($u,$p,0);
	#	} elsif ( defined( $C->{'web-htpasswd-file'} ) ) {
	#		$rv = _file_verify($C->{'web-htpasswd-file'},$u,$p,1);
	#		return $rv if($rv);
	#	} elsif ( defined( $C->{'web-md5-password-file'} ) ) {
	#		$rv = _file_verify($C->{'web-md5-password-file'},$u,$p,2);
	#		return $rv if($rv);
	#	} elsif ( defined( $C->{'web-unix-password-file'} ) ) {
	#		$rv = file_verify($C->{'web-unix-password-file'},$u,$p,3);
	#		return $rv if($rv);
		}

		if ($exit) {
			#Redundant logging
			#logAuth("INFO login request of user=$u method=$auth accepted");
			last; # done
		} else {
			logAuth("INFO login request of user=$u method=$auth failed");
		}
	}

	return $exit;
}

#----------------------------------

# verify against a password file:   username:password
sub _file_verify {
	my $self = shift;
	my($pwfile,$u,$p,$encmode) = @_;
	my($fp,$salt,$cp);

	my $crypthack;

	$self->_loadConf;

	my $debugmessage = "DEBUG: _file_verify($pwfile,$u,$p,$encmode)\n";
	print STDERR "$debugmessage\n" if $debug;

	$encmode = 0 if $encmode eq "plaintext";
	$encmode = 1 if $encmode eq "crypt";
	$encmode = 2 if $encmode eq "md5";

	open PW, "<$pwfile" or return 0;
	while( <PW> ) {
		if( /([^\s:]+):([^:]+)/ ) {
			if($1 eq $u) {
				$fp = $2;
				chomp $fp;
				#close PW; # we are returning whatever
				if($encmode == 0) { # unencrypted. eek!
					return 1 if($p eq $fp); 
				} elsif ($encmode == 1) { # htpasswd (unix crypt)
					if($crypthack) {
					 require Crypt::UnixCrypt;
					 $Crypt::UnixCrypt::OVERRIDE_BUILTIN = 1;
					}
					$salt = substr($fp,0,2);
					$cp = crypt($p,$salt); 
					return 1 if($fp eq $cp); 
				} elsif ($encmode == 2) { # md5 digest
					require Digest::MD5;
					return 1 if($fp eq Digest::MD5::md5($p));
				} elsif ($encmode == 3) { # unix crypt
					if($crypthack) {
					 require Crypt::UnixCrypt;
					 $Crypt::UnixCrypt::OVERRIDE_BUILTIN = 1;
					}
					$salt = substr($fp,0,2);
					$cp = crypt($p,$salt); 
					return 1 if($fp eq $cp); 
				} # add new ones here...
				if( $C->{'auth_debug'} ) {
					$debugmessage .= "Mismatch password [$u][$p]:[$fp]!=[$cp]\n";
				}
				return 0;
			} elsif( $C->{'auth_debug'} ) {
				$debugmessage .= "Mismatch user [$1][$u]\n";
			}
		} elsif( $C->{'auth_debug'} ) {
			$debugmessage .= "Bad format line $_";
		}
	}
	close PW;
	
	print STDERR "$debugmessage\n" if $debug;

	return 0; # not found
}

#----------------------------------

# LDAP verify a username
sub _ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);

	$self->_loadConf;

	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth("ERROR, no IO::Socket::SSL; Net::LDAPS installed");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth("ERROR, no Net::LDAP installed");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ldap_server'});
	}
	if(!$ldap) {
		logAuth("ERROR, no LDAP object created, maybe ldap server address missing in configuration of NMIS");
		return 0; 
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $C->{'auth_ldap_attr'} )
		if( $C->{'auth_ldap_attr'} );
	
	# foreach $context ( split ":", $C->{'auth_ldap_context'}  ) {
	# 	foreach $attr ( @attrlist ) {
	# 		$dn = "$attr=$u,".$context;
	# 		$msg = $ldap->bind($dn, password=>$p) ;
	# 		if(!$msg->is_error) {
	# 			$ldap->unbind();
	# 			return 1;
	# 		}
	# 	}
	# }

	#if($debug) {
	#	print STDERR "DEBUG: _ldap_verify: auth_ldap_attr=(";
	#	print STDERR join(',',@attrlist);
	#	print STDERR ")\n";
	#}

	foreach $context ( split ":", $C->{'auth_ldap_context'}  ) {

		#print STDERR "DEBUG: _ldap_verify: context=$context\n" if $debug;

		foreach $attr ( @attrlist ) {
			$dn = "$attr=$u,".$context;

			#print STDERR "DEBUG: _ldap_verify: $dn\n" if $debug;

			$msg = $ldap->bind($dn, password=>$p) ;
			if(!$msg->is_error) {

				#print STDERR "DEBUG: _ldap_verify: bind success\n" if $debug;

				$ldap->unbind();
				return 1;
			}

			#elsif ($debug) {
			#	my $__reason = $msg->error;
			#	print STDERR "DEBUG: _ldap_verify: bind failed with $__reason\n";
			#}	
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

	$self->_loadConf;

	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth2("no IO::Socket::SSL; Net::LDAPS installed","ERROR");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth2("no Net::LDAP installed","ERROR");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ldap_server'});
	}
	if(!$ldap) {
		logAuth2("no LDAP object created, maybe ldap server address missing in configuration of NMIS","ERROR");
		return 0; 
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $C->{'auth_ldap_attr'} )
		if( $C->{'auth_ldap_attr'} );
	
	#if($debug) {
	#	print STDERR "DEBUG: _novell_ldap_verify: auth_ldap_attr=(";
	#	print STDERR join(',',@attrlist);
	#	print STDERR ")\n";
	#}

	# TODO: Implement non-anonymous bind

	$msg = $ldap->bind; # Anonymous bind
	if ($msg->is_error) {
		logAuth2("cant search LDAP (anonymous bind), need binddn which is uninplemented","TODO");
		logAuth2("LDAP anonymous bind failed","ERROR");
		return 0;
	}

	foreach $context ( split ":", $C->{'auth_ldap_context'}  ) {

		#print STDERR "DEBUG: _novell_ldap_verify: context=$context\n" if $debug;

		$dn = undef;
		# Search "attr=user" in each context
		foreach $attr ( @attrlist ) {

			#print STDERR "DEBUG: _novell_ldap_verify: search ($attr=$u)\n" if $debug;

			$msg = $ldap->search(base=>$context,filter=>"$attr=$u",scope=>"sub",attrs=>["dn"]);

			#print STDERR "DEBUG: _novell_ldap_verify: search result: code=" . $msg->code . ", count=" . $msg->count . "\n" if $debug;

			if ( $msg->is_error ) { #|| ($msg->count != 1)) { # not Found, try next context
				next;
			}
			$dn = $msg->entry(0)->dn;
		}
		# if found, use DN to bind
		# not found => dn is undef

		return 0 unless defined($dn);

		#print STDERR "DEBUG: _novell_ldap_verify: found, trying to bind as $dn\n" if $debug;

		$msg = $ldap->bind($dn, password=>$p) ;
		if(!$msg->is_error) {

			#print STDERR "DEBUG: _novell_ldap_verify: bind success\n" if $debug;

			$ldap->unbind();
			return 1;
		}

		else {
			#print STDERR "DEBUG: _novell_ldap_verify: bind failed with ". $msg->error . "\n" if $debug;

			# A bind failure in one context is fatal.
			return 0;
		}
	}

	logAuth2("LDAP user not found in any context","ERROR");
	return 0; # not found in any context
}

#----------------------------------
# Microsoft LDAP verify username/password
#
# 18-4-10 Jan v. K.
#
sub _ms_ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my $ldap;
	my $ldap2;
	my $status;
	my $status2;
	my $entry;
	my $dn;

	$self->_loadConf;

	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth("ERROR no IO::Socket::SSL; Net::LDAPS installed");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth("ERROR no Net::LDAP installed from CPAN");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP by know (readonly) account
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ms_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ms_ldap_server'});
	}
	if(!$ldap) {
		logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing in configuration of NMIS");
		return 0; 
	}

	# bind LDAP for request DN of user
	$status = $ldap->bind("$C->{'auth_ms_ldap_dn_acc'}",password=>"$C->{'auth_ms_ldap_dn_psw'}");
	if ($status->code() ne 0) {
		logAuth("ERROR LDAP validation of $C->{'auth_ms_ldap_dn_acc'}, error msg ".$status->error()." ");
		return 0;
	}

	logAuth("DEBUG LDAP Base user=$C->{'auth_ms_ldap_dn_acc'} authorized") if $C->{auth_ms_ldap_debug};

	for my $attr ( split ',',$C->{'auth_ms_ldap_attr'}) {

		logAuth("DEBUG LDAP search, base=$C->{'auth_ms_ldap_base'},".
						"filter=${attr}=$u, attr=distinguishedName") if $C->{auth_ms_ldap_debug};

		my $results = $ldap->search(scope=>'sub',base=>"$C->{'auth_ms_ldap_base'}",filter=>"($attr=$u)",attrs=>['distinguishedName']);

		##
		writeTable(dir=>'var',name=>"nmis-ldap-debug",data=>$results) if $C->{auth_ms_ldap_debug};
		##

		if (($entry = $results->entry(0))) {
			$dn = $entry->get_value('distinguishedName');
		} else {
			logAuth("DEBUG LDAP search failed") if $C->{auth_ms_ldap_debug};
		}
	}

	if ($dn eq '') {
		logAuth("DEBUG user $u not found in Active Directory") if $C->{auth_ms_ldap_debug};
		$ldap->unbind();
		return 0;
	}

	my $d = $dn;
	$d =~ s/\\//g;
	logAuth("DEBUG LDAP found distinguishedName=$d") if $C->{auth_ms_ldap_debug};

	# check user

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap2 = new Net::LDAPS($C->{'auth_ms_ldaps_server'});
	} else {
		$ldap2 = new Net::LDAP($C->{'auth_ms_ldap_server'});
	}
	if(!$ldap2) {
		logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing");
		return 0; 
	}

	$status2 = $ldap2->bind("$dn",password=>"$p");
	logAuth("DEBUG LDAP bind dn $d password $p status ".$status->code()) if $C->{auth_ms_ldap_debug};
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

# generate_cookie -- returns a cookie with current username, expiry
sub generate_cookie {
	my $self = shift;
	my $authuser = shift;
	my($cookie);
	my($exp) = "+1min"; # note this stops wk/mon/yrly autoupdate from working
	my($token);

	$self->_loadConf;

	return "" if ( ! $authuser );

	$exp = $C->{auth_expire} if ( $C->{auth_expire} ne "" );
	$exp = "+60min" if ($exp eq ""); # some checking for format

	$token = $authuser . remote_host(); # should really have time here also
	
	$token .= (defined $C->{'auth_web_key'}) ? $C->{'auth_web_key'} : $CHOCOLATE_CHIP;
	$token = $authuser . ':' . unpack('%32C*',$token); # checksum
	

	#$cookie = cookie({name=>'nmis_auth', value=>$token, path=>$C->{'<cgi_url_base>'}, expires=>$exp} ) ;
	if ( $C->{'auth_sso_domain'} ne "" and $C->{'auth_sso_domain'} ne ".domain.com") {
		$cookie = cookie({name=>'nmis_auth', domain=>$C->{'auth_sso_domain'}, value=>$token, expires=>$exp} ) ;
	}
	else {		
		$cookie = cookie({name=>'nmis_auth', value=>$token, expires=>$exp} ) ;
	}

	return $cookie;
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
	my $config= $args{config};
	my $msg = $args{msg};

	$self->_loadConf;

	# this is sent if auth = y and page = top (or blank),
	# or if page = login
	# print STDERR " Q is : ".Dumper($Q);
	my $url = self_url();
	if( $config ne '' ) {
		if( index($url, '?') == -1 ) {
			$url .= "?conf=$config";
		} else {
			$url .= "&conf=$config";
		}
	}
	
	print header(-target=>"_top", -type=>"text/html", -expires=>'now') . "\n";
	print start_html(
			-title=>$C->{auth_login_title},
			-base=>'false',
			-xbase=>&url(-base=>1)."$C->{'<url_base>'}",
			-target=>'_blank',
			-meta=>{'keywords'=>'network management NMIS'},
			-style=>{'src'=>"$C->{'<menu_url_base>'}/css/dash8.css"}
    );

	print start_table({class=>"notwide"});

	print do_login_banner();

	print start_Tr, start_td({style=>"border: 0; margin: 0; padding: 0"}),
		start_table({width=>"640px", align=>"center", class=>"noborder"}),
		start_Tr,
		start_td,
		start_table();
	print Tr(td({class=>'header'},"Authentication required"));

	print Tr(td({class=>'info Plain'},
		p("Please log in with your appropriate username and password in order to gain access to this system")));
	
	print start_Tr,start_td;
	print start_form({method=>"POST", action=>$url, target=>"_top"}),
		table({align=>"center", width=>"50%", class=>"noborder"},
		  Tr(td({class=>'info Plain'},"Username") . td({class=>'info Plain'},textfield({name=>'auth_username'}) )) .
		  Tr(td({class=>'info Plain'},"Password") . td({class=>'info Plain'},password_field({name=>'auth_password'}) )) .
		  Tr(td({class=>'info Plain'},"&nbsp;") . td({class=>'info Plain'},submit({name=>'login',value=>'Login'}) ))
		),
		hidden(-name=>'conf', -default=>$config,-override=>'1'),
		end_form;
	
	print end_td,end_Tr;

	print Tr(td(p({style=>"color: red"}, "&nbsp;$msg&nbsp;")));

	print end_table,end_td,end_Tr,end_table,end_td,end_Tr;

	print end_table;

	print end_html;
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
	my $config = $args{config} ne '' ? "&conf=$args{config}" : "" ;
	my($javascript);
	my($err) = shift;

	$self->_loadConf;

	# Javascript that sets window.location to login URL
	# This is created if auth = y and page != login and !authuser
	my $forward_url = self_url();

	my $url = url(-base=>1) . $C->{'<cgi_url_base>'} . "/nmiscgi.pl?auth_type=login$config&forward_url=$forward_url";

	$javascript = "function redir() { ";
#	$javascript .= "alert('$err'); " if($err);
	$javascript .= " window.location = '" . $url . "'; }";

	$javascript = "function redir() {} " if($C->{'web-auth-debug'});

	print header({ target=>'_top', expires=>"now" })."\n";
	print start_html({ title =>"Login Required",
						expires => "now",  script => $javascript,
						onload => "redir()", bgcolor=>'#CFF' }),"\n";
	print h1("Authentication required")."\n";
	print "Please ".a({href=>$url},"login")	." before continuing.\n";

	print "<!-- $err -->\n";
	print end_html;
}

#----------------------------------

# do_logout -- set auth cookie to blank, expire now, and redirect to top
#
sub do_logout {
	my $self = shift;
	my %args = @_;
	my $config= $args{config};
	my($cookie,$javascript);

	$self->_loadConf;

	# Javascript that sets window.location to login URL
	$javascript = "function redir() { window.location = '" . url(-full=>1) . "?auth_type=login&conf=$config'; }";
	$cookie = cookie({ -name=>'nmis_auth', -value=>'', -expires=>"now"} ) ;

	logAuth("INFO logout of user=$self->{user}");

	print header({ -target=>'_top', -expires=>"5s", -cookie=>[$cookie] })."\n";
	print start_html({ 
		-title =>"Logout complete",
		-expires => "5s",  
		-script => $javascript, 
		-onload => "redir()",
		-cookie => $cookie,
		-style=>{'src'=>"$C->{'<menu_url_base>'}/css/dash8.css"}
		}),"\n";

	print start_table({width=>"100%"}),
		start_Tr, start_td;
	print &do_login_banner;
	print end_td, end_Tr;
	print Tr(td({class=>"white"}, p(h1("Logged out of system") .
	p("Please " . a({href=>url(-full=>1) . "?auth_type=login"},"go back to the login page") ." to continue."))));

	print start_Tr, start_td,
		end_td, end_Tr;

	print end_table, end_html;
}

#####################################################################
#
# The following routines are courtesy of Robert W. Smith, copyrighted
# and covered under the GNU GPL.
#
sub do_login_banner {
	my $self = shift;
	my @banner = ();

	push @banner, Tr(
		th({class=>'title',align=>'center'},font({size=>'+2'},
				b("NMIS Network Management Information System") ))
		);

	return @banner;
}


#####################################################################
#
# The following routines are courtesy of the NMIS source and copyrighted
# by Sinclair Internetworking Ltd Pty and covered under the GNU GPL.
#
sub get_time {
        # pull the system timezone and then the local time
        if ($^O =~ /win32/i) { # could add timezone code here
                return scalar localtime;
        }
        else { # assume UNIX box - look up the timezone as well.
		my $lt = scalar localtime;
		$lt =~ s/  / /;
                return uc((split " ", `date`)[4]) . " " . $lt;
        }
}


#####################################################################
#
# 5-10-06, Jan v. K.
#

sub _radius_verify {
	my $self = shift;
	my($user, $pswd) = @_;
	$self->_loadConf;

	eval { require Authen::Simple::RADIUS; }; # installed from CPAN
	if($@) {
		logAuth("ERROR, no Authen::Simple::RADIUS installed");
		return 0; 
	} # no Authen::Simple::RADIUS installed

	my ($host,$port) = split(/:/,$C->{auth_radius_server});
	if ($host eq "") {
		logAuth("ERROR, no radius server address specified in configuration of NMIS");
	} elsif ($C->{auth_radius_secret} eq "") {
		logAuth("ERROR, no radius secret specified in configuration of NMIS");
	} else {
		$port = 1645 if $port eq "";
		my $radius = Authen::Simple::RADIUS->new(
			host   => $host,
			secret => $C->{auth_radius_secret},
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

	$self->_loadConf;

	eval { require Authen::TacacsPlus; }; # installed from CPAN
	if($@) {
		logAuth("ERROR, no Authen::TacacsPlus installed");
		return 0; 
	} # no Authen::TacacsPlus installed

	my ($host,$port) = split(/:/,$C->{auth_tacacs_server});
	if ($host eq "") {
		logAuth("ERROR, no tacacs server address specified in configuration of NMIS");
	} elsif ($C->{auth_tacacs_secret} eq "") {
		logAuth("ERROR, no tacacs secret specified in configuration of NMIS");
	} else {
		$port = 49 if $port eq "";
		my $tacacs = new Authen::TacacsPlus(
			Host => $host,
			Key => $C->{auth_tacacs_secret},
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
	my $config = $args{conf};
	my $headeropts = $args{headeropts};
	my @cookies = ();
	
	$self->_loadConf;
		
	print STDERR "DEBUG: loginout type=$type username=$username\n" if $debug;
	
	#2011-11-14 Integrating changes from Till Dierkesmann
	### 2012-11-19 keiths, fixing Auth to use Cookies!
	# if ( not $self->SetUser($self->verify_id()) ) {
	if($ENV{'REMOTE_USER'} and ($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") ) {             
		$username=$ENV{'REMOTE_USER'};
		if( $type eq 'login' ) {
			$type = ""; #apache takes care of showing the login screen	
		}		
  }
	# elsif ( $type eq "" and $self->{user} eq "" ) {
	# 	$type = "login";	
	# }
	# }

	print STDERR "DEBUG: loginout type=$type\n" if $debug;
	
	if(lc $type eq 'logout') {
		$self->do_logout(config=>$config); # bye
		return 0;
	}

	if ( lc $type eq 'login' ) {
		$self->do_login(config=>$config);
		return 0;
	} 


	if (defined($username) && $username ne '') { # someone is trying to log in
		print STDERR "DEBUG: verifying $username\n" if $debug;
		if( $self->user_verify($username,$password)) {
			#print STDERR "DEBUG: user verified $username\n" if $debug;
			#print STDERR "self.privilevel=$self->{privilevel} self.config=$self->{config} config=$config\n" if $debug;

			# login accepted, set privs
			$self->SetUser($username);

			# check the name of the NMIS config file specified on url
			# only bypass for administrator
			if ($self->{privlevel} gt 1 and $self->{config} ne '' and $config ne $self->{config}) {
				$self->do_login(msg=>"Invalid config file specified on url");
				return 0;
			}

			logAuth2("user=$self->{user} logged in with config=$config","INFO");

		} else { # bad login: force it again
			$self->do_login(config=>$config,msg=>"Invalid username/password combination");
			return 0;
		}
	} 
	else { # check cookie
		print STDERR "DEBUG: valid session? check cookie\n" if $debug;

		$username = $self->verify_id();
		if( $username eq '' ) { # invalid cookie
			$self->do_force_login(config=>$config,msg=>"Invalid Session");
			return 0;
		}

		$self->SetUser( $username );
		print STDERR "DEBUG: cookie OK\n" if $debug;
	}

	# user should be set at this point, if not then redirect
	unless ($self->{user}) {
		$self->do_force_login(config=>$config);
		return 0;
	}
	
	# generate the cookie if $self->user is set
	if ($self->{user}) {		
    push @cookies, $self->generate_cookie($self->{user});
	}
	$self->{cookie} = @cookies;
	$headeropts->{-cookie} = [@cookies];
	return 1; # all oke
}

#----------------------------------

#sub loadAccessTable {
#	return loadTable(dir=>'conf',name=>'Access'); # tables cashed by func.pm
#}

#----------------------------------

#sub loadUsersTable {
#	return loadTable(dir=>'conf',name=>'Users');
#}

#----------------------------------

#sub loadPrivMapTable {
#
#	return loadTable(dir=>'conf',name=>'PrivMap');
#}

#----------------------------------

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
		$self->_GetPrivs($self->{user});
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
	return 1 if $self->{groups} eq "all";
	return 0 unless defined $group or $group;
	foreach my $g (@{$self->{groups}}) {
		print STDERR "  DEBUG AUTH: @{$self->{groups}} g=$g group=$group" if $debug;
		return 1 if ( lc($g) eq lc($group) );
	}
	return 0;
}

#----------------------------------

#	Check Access identifier agains priv of user
#
sub CheckAccessCmd {
	my $self = shift;
	my $command = lc shift; # key of table is lower case

	return 1 unless $self->{_require};

	my $AC = loadAccessTable();

	return $AC->{$command}{"level$self->{privlevel}"};
}

#----------------------------------

# Private routines go here
#
# _GetPrivs -- load and parse the conf/Users.nmis file
# also loads conf/PrivMap.nmis to map the privilege to a
# numeric privilege level.
#
sub _GetPrivs {
	my $self = shift;
	my $user = lc shift;

	$self->_loadConf;
	my $GT = loadGroupTable();
	my $UT = loadUsersTable();
	my $PMT = loadPrivMapTable();
	
	if ( ! exists $UT->{$user} ) {
		$self->{privlevel} = 5;
		logAuth("User \"$user\" not found in table Users");
		return 0;
	}
	
	if ( ! exists $PMT->{$UT->{$user}{privilege}} ) {
		$self->{privlevel} = 5;
		logAuth("Privilege $UT->{$user}{privilege} not found for user \"$user\" ");
		return 0;
	}

	$self->{privlevel} = ($PMT->{$UT->{$user}{privilege}}{level} ne '') ? $PMT->{$UT->{$user}{privilege}}{level} : '5';

	$self->{config} = $UT->{$user}{config}; # nmis config file specification (optional)
	$self->{config} = 'Config.nmis' if $self->{config} eq '';

	my @groups = split /,/, $UT->{$user}{groups};

	if ( grep { $_ eq 'all' } @groups) {
		@{$self->{groups}} = sort split(',',$C->{group_list});
		# put the virtual network group on the list
		push @{$self->{groups}}, "network"; 
	} elsif ( $UT->{$user}{groups} eq "none" or $UT->{$user}{groups} eq "" ) {
		@{$self->{groups}} = [];
	} else {
		# note: the main health status graphs uses the implied virtual group network,
  	# this group must be explicitly stated if you want to see this graph
		@{$self->{groups}} = @groups;
	}
	map { stripSpaces($_) } @{$self->{groups}};

	return 1;
}

#----------------------------------

#sub AUTOLOAD {
#	my $self = shift;
#	my $type = ref($self) || croak "$self is not an object\n";
#	my $name = our $AUTOLOAD;
#	$name =~ s/.*://;
#	unless (exists $self->{$name} ) {
#		croak "cant access $name field in object $type\n";
#	}
#	if (@_) {
#		return $self->{$name} = shift;
#	} else {
#		return $self->{$name};
#	}
#}

1;
