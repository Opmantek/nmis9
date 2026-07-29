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

# Fail-without-fix regression for the unauthenticated modules.pl start_html
# -xbase sink (OMK-12731). CGI.pm does NOT auto-escape -xbase, so a config
# <url_base> containing a quote breaks out of <base href="...">. This test seeds
# a hostile <url_base> into the UNTRACKED conf/Config.nmis override (isolated -
# it never touches tracked conf-default, and every request here is modules.pl so
# the base is not corrupted for other pages), drives the real CGI through NMISx,
# and asserts the emitted <base href> is HTML-escaped. It fails against the old
# raw -xbase code. Needs the dev container; skips cleanly elsewhere.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Copy;

use NMISNG::Util;

my $XB   = 'xbaseXSS"onx';        # the " is an attribute break-out in <base href="...">
my $CFG  = "$FindBin::Bin/../conf/Config.nmis";
my $BAK;

# seed the override before the config is loaded, so the parent cache and the
# forked CGI both see it; always restored in END
if (-f $CFG) {
	$BAK = "$CFG.xbasebak";
	copy($CFG, $BAK);
	open(my $in, '<', $CFG); local $/; my $txt = <$in>; close $in;
	if ($txt =~ /'<url_base>'\s*=>/) {
		$txt =~ s{('<url_base>'\s*=>\s*)'[^']*'}{$1'/$XB'};
	} else {
		$txt =~ s{('system'\s*=>\s*\{)}{$1\n    '<url_base>' => '/$XB',};
	}
	open(my $out, '>', $CFG); print $out $txt; close $out;
}

END {
	if ($BAK && -f $BAK) { copy($BAK, $CFG); unlink $BAK; }
}

my $C = NMISNG::Util::loadConfTable();
plan skip_all => "no MongoDB configured" unless ($C && $C->{db_name});
plan skip_all => "conf/ override not available for seeding" unless ($BAK);
plan skip_all => "<url_base> seed did not take (got '" . ($C->{'<url_base>'} // '') . "')"
	unless (($C->{'<url_base>'} // '') =~ /\Q$XB\E/);

require Test::Mojo;
my $t = eval { Test::Mojo->new('NMISx') };
plan skip_all => "NMISx Mojo app not available (run in the dev container): $@" unless $t;

$t->post_ok('/cgi-nmis9/nmiscgi.pl' => form =>
	{ conf => 'Config', auth_username => 'nmis', auth_password => 'nm1888' });

$t->get_ok('/cgi-nmis9/modules.pl?conf=Config&widget=false', "modules.pl fetched");
my $body = $t->tx->res->body // '';
is($t->tx->res->code, 200, "modules.pl: HTTP 200");
unlike($body, qr/\Q$XB\E/,          "modules.pl -xbase: hostile value is not present raw (no attribute break-out)");
like($body,   qr/xbaseXSS&quot;onx/, "modules.pl -xbase: <base href> value is HTML-escaped");

done_testing();
