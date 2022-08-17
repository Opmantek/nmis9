#!/usr/bin/env perl
#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# a test stub to use the CiscoMerakiCloud plugin as a library for testing.

use FindBin;
use lib "/usr/local/nmis8/conf/plugins";
use lib "$FindBin::Bin/../lib"; 

use strict;
use CiscoMerakiCloud;
use Data::Dumper;

my @deviceList = qw(
	GID_22520_CABLEVISION
	GID_30596_TELUM
	GID_25867_TELUM
	GID_164876_IMSS_MEGACABLE_71349
	GID_67011_TELECABLE
	MX_WALTER_BONA
);

my $debug = 1;

foreach my $deviceName (@deviceList) {
	my $merakiData = getMerakiData(name => $deviceName);
	if ( defined $merakiData->{error} ) {
		print "ERROR with $deviceName: $merakiData->{error}\n";
	}
	print "$deviceName: status=$merakiData->{status} perfScore=$merakiData->{perfScore} avgLatency=$merakiData->{avgLatency} avgLossPercent=$merakiData->{avgLossPercent} maxLossPercent=$merakiData->{maxLossPercent}\n" if $debug;
	print Dumper $merakiData if $debug;
}

