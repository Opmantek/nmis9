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

# Regression test for NMISNG::Util::filter_params (OMK-12723). $q->Vars is a
# TIED hash; filter_params must not write back through it, or multi-value
# params (hide_groups, event_id) collapse and config.pl/events.pl corrupt data.
# Pure function + CGI, no MongoDB. Host-runnable.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CGI;
use NMISNG::Util;

# a real tied CGI Vars: multi-value hide_groups (one value carrying markup) plus
# a single-value param carrying markup
$ENV{REQUEST_METHOD} = 'GET';
$ENV{QUERY_STRING}   = 'hide_groups=A&hide_groups=B%3Cx%3E&hide_groups=C&node=n1%3Cscript%3E&item=hide_groups';

my $q = CGI->new;
my $Q = $q->Vars;
ok(tied(%$Q), "sanity: \$q->Vars is a tied hash");

my $filtered = NMISNG::Util::filter_params($Q);

# 1) the tied CGI object must be left intact - the multi-value handlers in
#    config.pl (hide_groups) and events.pl (event_id/ack) read it via
#    $q->multi_param / $q->param AFTER filtering
my @hg = $q->multi_param('hide_groups');
is(scalar(@hg), 3, "filter_params leaves multi-value hide_groups intact (3 values)")
	or diag("got: [" . join("][", @hg) . "]");
is_deeply([@hg], ['A', 'B<x>', 'C'],
	"raw multi-value read by \$q handlers is unmodified");

# 2) single-value params in the returned hash are entity-encoded (the security intent)
like($filtered->{node}, qr/&lt;script&gt;/, "single-value param entity-encoded in returned hash");
unlike($filtered->{node}, qr/<script>/,     "no raw markup left in the filtered single value");

# 3) param names (keys) are preserved, not entity-encoded
ok(exists $filtered->{hide_groups}, "param name key is preserved");

done_testing();
