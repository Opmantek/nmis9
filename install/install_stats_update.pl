#!/usr/bin/perl
#
## $Id: updateconfig.pl,v 1.6 2012/08/27 21:59:11 keiths Exp $
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

my %arg = getArguements(@ARGV);

my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

print <<EO_TEXT;
This script will update your running NMIS system and add the configuration for a new CiscoRouter Model.

EO_TEXT

if ( $arg{nike} ne "true" ) {

	exit unless input_yn("OK to proceed updating NMIS with new Model Files for CiscoRouter Model");

}

#######################################################
my $modelName = "Common-stats";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'stats'}{'type'}{'health'} = [
        'DEF:reach=$database:reachability:AVERAGE',
        'DEF:avail=$database:availability:AVERAGE',
        'DEF:health=$database:health:AVERAGE',
        'DEF:response=$database:responsetime:AVERAGE',
        'DEF:loss=$database:loss:AVERAGE',
        'DEF:intfCollect=$database:intfCollect:AVERAGE',
        'DEF:intfColUp=$database:intfColUp:AVERAGE',

        'DEF:reachabilityHealth=$database:reachabilityHealth:AVERAGE',
        'DEF:availabilityHealth=$database:availabilityHealth:AVERAGE',
        'DEF:responseHealth=$database:responseHealth:AVERAGE',
        'DEF:cpuHealth=$database:cpuHealth:AVERAGE',
        'DEF:memHealth=$database:memHealth:AVERAGE',
        'DEF:intHealth=$database:intHealth:AVERAGE',
        'DEF:diskHealth=$database:diskHealth:AVERAGE',
        'DEF:swapHealth=$database:swapHealth:AVERAGE',

        'PRINT:intfCollect:AVERAGE:intfCollect=%1.3lf',
        'PRINT:intfColUp:AVERAGE:intfColUp=%1.3lf',
        'PRINT:reach:AVERAGE:reachable=%1.3lf',
        'PRINT:avail:AVERAGE:available=%1.3lf',
        'PRINT:health:AVERAGE:health=%1.3lf',
        'PRINT:response:AVERAGE:response=%1.2lf',
        'PRINT:loss:AVERAGE:loss=%1.2lf',

        'PRINT:reachabilityHealth:AVERAGE:reachabilityHealth=%1.2lf',
        'PRINT:availabilityHealth:AVERAGE:availabilityHealth=%1.2lf',
        'PRINT:responseHealth:AVERAGE:responseHealth=%1.2lf',
        'PRINT:cpuHealth:AVERAGE:cpuHealth=%1.2lf',
        'PRINT:memHealth:AVERAGE:memHealth=%1.2lf',
        'PRINT:intHealth:AVERAGE:intHealth=%1.2lf',
        'PRINT:diskHealth:AVERAGE:diskHealth=%1.2lf',
        'PRINT:swapHealth:AVERAGE:swapHealth=%1.2lf',
];


writeTable(dir=>'models',name=>$modelName,data=>$MODEL);


print "Done updating the files\n";

#######################################################
#######################################################
# question , return true if y, else 0 if no, default is yes.
sub input_yn {

	print STDOUT qq|$_[0] ? <Enter> to accept, any other key for 'no'|;
	my $input = <STDIN>;
	chomp $input;
	return 1 if $input eq '';
	return 0;
}
