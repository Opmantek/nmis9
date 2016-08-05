#!/usr/bin/perl
#
## $Id: registration.pl,v 8.4 2012/09/18 01:40:59 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use NMIS;
use func;
use NMIS::License;

use Data::Dumper;
$Data::Dumper::Indent = 1;

my $headeropts = {type=>'text/html',expires=>'now'};

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # This processes all parameters passed via GET and POST
my $Q = $q->Vars; # values in hash
my $C;

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# select function
my $select;
my $wz = "420px";
#my $wa = "175px";
#my $wb = "225px";
my $wa = "50%";
my $wb = "50%";

if ($Q->{act} eq '' ) {	
	&printMenu();
} 
elsif ($Q->{act} eq 'register' and ( $Q->{email} eq "" or $Q->{country} eq "" ) ) {	
	&printMenu();
} 
elsif ($Q->{act} eq 'register') { 
	&processRegistration();
}

sub printMenu {
	my $url = "registration.pl?conf=$Q->{conf}&act=register";
	print header($headeropts);

	my $L = NMIS::License->new();
	my ($licenseValid,$licenseMessage) = $L->checkLicense();
	#$registered = "true" if $licenseValid;
  $Q->{name} = $L->{details}{name} if (not $Q->{name} and $L->{details}{name});
  $Q->{email} = $L->{details}{email} if (not $Q->{email} and $L->{details}{email});
  $Q->{company} = $L->{details}{company} if (not $Q->{company} and $L->{details}{company});
  $Q->{country} = $L->{details}{country} if (not $Q->{country} and $L->{details}{country});
  $Q->{node_count} = $L->{details}{node_count} if (not $Q->{node_count} and $L->{details}{node_count});

  my $tfs = 30;

	#if ( $licenseValid ) {
	#	print Tr(td({class=>'info Plain',colspan=>"2"},"You Should Never See This."));
	#}
	#else {
	#	print Tr(td({class=>'info Plain',colspan=>"2"},"There seems to be problem with the Registration: $licenseMessage."));
	#}
	my $message;
	if ( $licenseValid ) {
		$message = "NMIS Community Registration Information";
	}
	else {
		$message = qq|NMIS is open source software, <strong>licensed under <a href="http://www.gnu.org/licenses/gpl-3.0.html">GNU GPL v3</a></strong>.  You must accept the terms of the GPL to run NMIS.
<br/>
<br/>
Open source software is not public domain and derivatives of NMIS must also be published as open source projects (<a href="http://www.gnu.org/licenses/gpl-3.0.html">GPL v3</a>).<br/>
<br/>
Opmantek is hugely committed to and passionate about open source software.<br/>
<br/>
Please participate in the NMIS Community at <a href="https://community.opmantek.com">community.opmantek.com</a> 
and send changes to <a href"mailto:code\@opmantek.com">code\@opmantek.com</a>|;
	}
	
	my $mandatory = "<span style='color:#FF0000'>*</span>";
	
	print start_form(-id=>"nmisRego",-href=>"$url");
	print start_table({width=>"$wz"});
	print Tr(td({class=>'lft Plain',width=>"$wz",colspan=>"2"},$message));
	if ($Q->{act} eq 'register' and ( $Q->{email} eq "" or $Q->{country} eq "" ) 	) {	
		print Tr(td({class=>'Error',width=>"$wz",colspan=>"2"},"Email and Country are mandatory fields."));
	}
	print Tr(td({class=>'header',width=>"$wa"},"Name"),td({class=>'info Plain',width=>"$wb"},textfield(-name=>"name",size=>"$tfs",value=>"$Q->{name}")));
	print Tr(td({class=>'header',width=>"$wa"},"Email $mandatory "),td({class=>'info Plain'},textfield(-name=>"email",size=>"$tfs",value=>"$Q->{email}")));
	print Tr(td({class=>'header',width=>"$wa"},"Country $mandatory"),td({class=>'info Plain'},textfield(-name=>"country",size=>"$tfs",value=>"$Q->{country}")));
	print Tr(td({class=>'header',width=>"$wa"},"Company"),td({class=>'info Plain'},textfield(-name=>"company",size=>"$tfs",value=>"$Q->{company}")));
	#print Tr(td({class=>'header',width=>"$wa"},"Approx. Number of Devices","<br/><span style='font-style:italic'>(Please include - it helps us further NMIS for your organisation size)</span>"),td({class=>'info Plain'},textfield(-name=>"node_count",size=>"$tfs",value=>"$Q->{node_count}")));
	print Tr(
		td({colspan=>'2',class=>'info',width=>"$wb"},button(-name=>"submit",onclick=>"get('nmisRego');",-value=>" Submit / Accept "))		
	);
	print Tr(td({class=>'info Plain',width=>"$wz",colspan=>"2"},"$mandatory mandatory fields."));

	print end_table;
	print hidden(-name=>'action', -value=>"register", -override=>'1');
	print hidden(-name=>'node_count', -value=>"0", -override=>'1');
	print end_form;

}

sub processRegistration {
	print header($headeropts);

	my $L = NMIS::License->new();
	$L->{details}{name} = "$Q->{name}";
	$L->{details}{email} = "$Q->{email}";
	$L->{details}{company} = "$Q->{company}";
	$L->{details}{country} = "$Q->{country}";
	$L->{details}{node_count} = "$Q->{node_count}";
	$L->updateLicense();
	
	print start_table({width=>'$wz'});
	print Tr(td({class=>'info Plain',colspan=>"2"},"Thankyou - we hope you enjoy NMIS and welcome all feedback.<br/>Visit opmantek.com for enhancements to NMIS"));
	if ( $Q->{error} ) {
		print Tr(td({class=>'Error',colspan=>"2"},"The Registration Widget failed to send to Opmantek, error:  $Q->{error}"));
	}
	print end_table;
}
