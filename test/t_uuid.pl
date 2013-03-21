#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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
use Data::UUID;

use NMIS;
use func;
use NMIS::UUID;

my %arg;
my $debug = 1;


use Data::UUID;

my $namespace = "NMIS SERVER";
my $name = "routera";

my $ug    = new Data::UUID;

my $uuid1 = $ug->create_str();
print "UUID1 = $uuid1\n";

my $uuid2 = $ug->create_from_name_str($namespace, $name);
print "UUID2 = $uuid2\n";

my $res   = $ug->compare($uuid1, $uuid2);

print "Result = $res\n";

my $C = loadConfTable(conf=>$arg{conf},debug=>"true");

auditUUID();
createUUID();
