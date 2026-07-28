#!/usr/bin/perl
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

# Regression tests for the H7b stored-XSS fixes (OMK-12703): the Modules table
# name/link/description rendered on the unauthenticated login page and in the
# GUI module menu must be escaped on output. Pure functions, no MongoDB.

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use_ok("NMISNG::Auth") or BAIL_OUT("cannot load NMISNG::Auth");
use_ok("Compat::Modules") or BAIL_OUT("cannot load Compat::Modules");
can_ok("NMISNG::Auth", "login_modules_html")
	or BAIL_OUT("NMISNG::Auth::login_modules_html is missing");

# ---- NMISNG::Auth::login_modules_html (login page module list) ---------------

is(NMISNG::Auth::login_modules_html(undef), "",
	"login_modules_html returns empty for undef");
is(NMISNG::Auth::login_modules_html([]), "",
	"login_modules_html returns empty for an empty list");

# a benign entry still renders its name and a valid link
my $ok = NMISNG::Auth::login_modules_html([["opCharts", "http://good.example/charts", "Charting"]]);
like($ok, qr/opCharts/, "login_modules_html renders a benign module name");
like($ok, qr{http://good\.example/charts}, "login_modules_html renders a valid http link");

# hostile entry: script name, javascript link, attribute-breakout description
my $bad = NMISNG::Auth::login_modules_html(
	[['<script>alert(1)</script>', 'javascript:alert(1)', '" onmouseover="alert(1)']]);
unlike($bad, qr/<script>alert/, "login_modules_html escapes a <script> module name");
unlike($bad, qr/javascript:alert/, "login_modules_html strips a javascript: link");
# the only quotes left must be the template's own attribute quotes, never the
# payload's: there must be no un-escaped onmouseover from the description
unlike($bad, qr/onmouseover="alert/, "login_modules_html escapes an attribute-breakout description");

# ---- Compat::Modules::getModuleCode (GUI module menu) ------------------------

my $mods = Compat::Modules->new();
$mods->{loaded}  = 1;
$mods->{modules} = {
	good => { order => 1, name => "opConfig", link => "http://good.example/cfg",
						base => "", file => "" },
	evil => { order => 2, name => "<img src=x onerror=alert(1)>",
						link => "javascript:alert(1)", base => "", file => "" },
};

my $menu = $mods->getModuleCode();
like($menu, qr/opConfig/, "getModuleCode renders a benign module name");
like($menu, qr{http://good\.example/cfg}, "getModuleCode renders a valid http link");
unlike($menu, qr/<img src=x/, "getModuleCode escapes an <img> module name");
unlike($menu, qr/javascript:alert/, "getModuleCode strips a javascript: link");

# ---- NMISNG::Auth::do_login_banner (login + logout page banner) --------------
# The favicon (config) and banner text render on the unauthenticated login and
# logout pages via do_login_banner; both must be escaped (OMK-12703, review C2).
require Compat::NMIS;
my $auth = bless({
	config => { nmis_favicon => 'x" onerror=xFAV' },
	banner => '<img src=x onerror=xBAN>',
}, 'NMISNG::Auth');
my $banner = join("", $auth->do_login_banner());
unlike($banner, qr/x" onerror=xFAV/,          "do_login_banner escapes the config favicon (no attribute break-out)");
like($banner,   qr/x&quot; onerror=xFAV/,      "do_login_banner favicon present, escaped");
unlike($banner, qr/<img src=x onerror=xBAN>/,  "do_login_banner escapes the banner text");
like($banner,   qr/&lt;img src=x onerror=xBAN&gt;/, "do_login_banner banner text present, escaped");

done_testing();
