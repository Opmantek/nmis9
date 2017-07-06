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

use strict;
use UUID::Tiny qw(:std);

use Compat::NMIS;
use NMISNG::Util;
use Compat::UUID;

my %arg = getArguements(@ARGV); 
my $debug = 1;

my $namespace = "NMIS SERVER";
my $name1 = "routera";
my $name2 = "routerb";

my $uuid1 = create_uuid_as_string(UUID_V5, $name1);
print "UUID1 = $uuid1\n";

my $uuid2 = create_uuid_as_string(UUID_V5, UUID_NS_URL, $namespace, $name1);
print "UUID2 = $uuid2\n";

my $res   = equal_uuids($uuid1, $uuid2);
print "Result1  = $res\n";

my $uuid3 = create_uuid_as_string(UUID_V5, UUID_NS_URL, $namespace, $name2);
print "UUID3 = $uuid3\n";

my $res   = equal_uuids($uuid2, $uuid3);
print "Result2  = $res\n";

# this doesn't test much - note that namespaces must be typed!
my $uuid4 = create_uuid_as_string(UUID_V5, UUID_NS_URL, $namespace . $name1);
print "UUID4 = $uuid4\n";

my $res   = equal_uuids($uuid1, $uuid4);

print "Result = ". ($res? "equal" : "not equal")."\n";

my $C = loadConfTable(conf=>$arg{conf},debug=>"true");

# for Table-Nodes.opha.nmis, which doesn't have a node name at that time
print "another one ".Compat::UUID::getUUID."\ntwo ".Compat::UUID::getUUID."\n";

if ($arg{"createuuids"})
{
	Compat::UUID::createNodeUUID();
}
Compat::UUID::auditNodeUUID();
