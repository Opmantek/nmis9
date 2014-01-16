#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
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

# 
use strict;
use func;
use NMIS;
use NMIS::Timing;
use NMIS::Connect;

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

print $t->markTime(). " loadEnterpriseTable\n";
my $enterpriseTable = loadEnterpriseTable();
print "  done in ".$t->deltaTime() ."\n";

my $htmlfile = "network-management-system-nmis-supported-vendors-snmp.html";

open(OUT,">$htmlfile") or die "Problem with $htmlfile: $!\n";

print OUT qq
^<!DOCTYPE html>
<html dir="ltr" lang="en-US">
<head>
<meta charset="UTF-8" />
<title>Network Management System NMIS Supported Vendors SNMP</title>
	
<link rel="shortcut icon" href="https://opmantek.com/wp-content/themes/opmantek-theme/favicon.png" type="image/x-icon" />
<link rel="icon" href="https://opmantek.com/wp-content/themes/opmantek-theme/favicon.png" type="image/x-icon" />
<link rel="stylesheet" type="text/css" media="all" href="https://opmantek.com/wp-content/themes/opmantek-theme/css/bootstrap.css" />
<link rel="stylesheet" type="text/css" media="all" href="https://opmantek.com/wp-content/themes/opmantek-theme/style.css" />

<!--[if IE 7]>
	<link rel="stylesheet" type="text/css" href="https://opmantek.com/wp-content/themes/opmantek-theme/css/ie.css">
<![endif]-->

<script type='text/javascript' src='https://ajax.googleapis.com/ajax/libs/jquery/1.7.2/jquery.min.js?ver=3.4.2'></script>
<script type='text/javascript' src='https://opmantek.com/wp-content/themes/opmantek-theme/js/bootstrap.min.js'></script>
<style TYPE="text/css">
h2 {
	color: #333333;
	font-size: 14px;
  font-weight: bold;

}
.links {
	width: 600px;
	background: rgba(255, 255, 255, 0.9);
	border: 0px solid #555555;
	-webkit-border-radius: 8px;
	-moz-border-radius: 8px;
	border-radius: 8px;
	-webkit-box-shadow: 3px 3px 0 #a1a1a1;
	-moz-box-shadow: 3px 3px 0 #a1a1a1;
	box-shadow: 3px 3px 0 #a1a1a1;
	margin: 5px;
	padding: 8px;
	color: #333333;
	font-size: 12px;
}
</style>

  </head>

  <body class="home blog logged-in">

    <div class="container" id="top">

      <div id="login_bar" class="row">
			  <div class="span12">
			  	<div class="pull-right">
            <a href="https://opmantek.com">Opmantek</a>|&nbsp;					
            <a href="https://support.opmantek.com">Support</a>|&nbsp;					
            <a href="https://community.opmantek.com">Community</a>
			  	</div>
			  </div>
      </div>


      <div id="header" class="row">
			  <div class="span12">
				  <a id="logo" href="https://opmantek.com"><img src="https://opmantek.com/assets/logo.png" /></a>
				  <div class="menu-header">
				    <ul id="menu-main-menu" class="menu">
				      <li class="menu-item menu-item-type-taxonomy menu-item-object-category"><a href="https://opmantek.com" >Opmantek.com</a></li>
				      <li class="menu-item menu-item-type-taxonomy menu-item-object-category"><a href="https://opmantek.com/contact-us/" >Contact Us</a></li>
				    </ul>
				  </div>
        </div>
		  </div>
	  </div>

    <div id="slider-wrapper">
      <div class="container">
        <div class="row">
          <div class="span12"> 
            <div>&nbsp;</div>
            <div class="links">
              <h1>Network Management System NMIS Supported Vendors SNMP</h1>
              <p>NMIS (<a href="https://opmantek.com/network-management-system-nmis/">Network Management Information System</a>) is a network management system which supports any device which has an SNMP agent, more details available at 
              <a href="https://community.opmantek.com/display/NMIS/NMIS8+Vendor+and+Device+Support">NMIS8 Vendor and Device Support</a>.
              </p>
              <p>
              This page provides a list of vendors which at a minimum will have "standard" support in NMIS8.
              </p>
            </div>
            <div class="links">
              <h2>NMIS SNMP Vendor List</h2>
              <ul>        
^;


my $count;
foreach my $oid (sort {$enterpriseTable->{$a}{Enterprise} cmp $enterpriseTable->{$b}{Enterprise} }  (keys %{$enterpriseTable})) {
	++$count;
	print OUT qq|              <li>$enterpriseTable->{$oid}{Enterprise} (SNMP Enterprise OID .1.3.6.1.4.1.$oid)</li>\n|;
}

print $t->elapTime(). " End\n";


			
print OUT qq
|
              </ul>
            </div>
          </div>
        </div>
      </div>             
    </div>
  </body>
</html>
|;

close(OUT);
