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

exit unless input_yn("OK to proceed updating NMIS with new Model Files for CiscoRouter Model");


#######################################################
my $modelName = "Common-database";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'database'}{'type'}{'tempStatus'} = '/health/$nodeType/$node-tempstatus-$index.rrd';
$MODEL->{'database'}{'type'}{'fanStatus'} = '/health/$nodeType/$node-fanStatus-$index.rrd';
$MODEL->{'database'}{'type'}{'bgpPeer'} = '/health/$nodeType/$node-bgpPeer-$index.rrd';
$MODEL->{'database'}{'type'}{'rttMonLatestRtt'} = '/health/$nodeType/$node-rttMonLatestRtt-$index.rrd';

writeTable(dir=>'models',name=>$modelName,data=>$MODEL);

#######################################################
my $modelName = "Common-heading";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'heading'}{'graphtype'}{'rttMonLatestRtt'} = 'RTT Monitor Stats';
$MODEL->{'heading'}{'graphtype'}{'bgpPeer'} = 'BGP Peer Status';
$MODEL->{'heading'}{'graphtype'}{'bgpPeerStats'} = 'BGP Peer Stats';
$MODEL->{'heading'}{'graphtype'}{'fan-status'} = 'Fan Status';
$MODEL->{'heading'}{'graphtype'}{'temp-status'} = 'Temp Status';

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
