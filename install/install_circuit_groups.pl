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
This script will update your running NMIS system and add the configuration for CircuitGroups.

EO_TEXT

exit unless input_yn("OK to proceed adding CircuitGroups for GE QS941's to NMIS");

#######################################################
my $modelName = "Model";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'models'}{'Tyco Electronics Power Systems'} = {
      'order' => {
        '10' => {
          'GE-QS941' => 'QS941A'
        }
      }
    };

writeTable(dir=>'models',name=>$modelName,data=>$MODEL);

#######################################################
my $modelName = "Common-database";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'database'}{'type'}{'cps6000Alarm'} = '/health/$nodeType/$node-cps6000Alarm-$index.rrd';
$MODEL->{'database'}{'type'}{'cps6000Grp'} = '/health/$nodeType/$node-cps6000Grp-$index.rrd';
$MODEL->{'database'}{'type'}{'cps6000Cct'} = '/health/$nodeType/$node-cps6000Cct-$index.rrd';

writeTable(dir=>'models',name=>$modelName,data=>$MODEL);

#######################################################
my $modelName = "Common-heading";
my $modelFile = "$C->{'<nmis_models>'}/$modelName.nmis";
print "Adding new $modelName Definition to $modelFile\n";

backupFile(file => $modelFile, backup => "$modelFile.backup");

my $MODEL = loadTable(dir=>'models',name=>$modelName);

$MODEL->{'heading'}{'graphtype'}{'cps6000Alarm'} = 'CPS 6000 Alarm Status';
$MODEL->{'heading'}{'graphtype'}{'cps6000Grp'} = 'Group Power and Status';
$MODEL->{'heading'}{'graphtype'}{'cps6000Cct'} = 'Circuit Power and Status';

writeTable(dir=>'models',name=>$modelName,data=>$MODEL);

#######################################################
my $tableFile = "$C->{'<nmis_conf>'}/Tables.nmis";
print "Adding new Table Definition to $tableFile\n";

backupFile(file => $tableFile, backup => "$tableFile.backup");

my $TABLES = loadTable(dir=>'conf',name=>'Tables');

$TABLES->{'CircuitGroups'} = {
  'CaseSensitiveKey' => 'true',
  'Description' => 'The definition of Circuit Groups, use for GE QS941 Devices.',
  'DisplayName' => 'Circuit Groups',
  'Table' => 'CircuitGroups'
};

writeTable(dir=>'conf',name=>'Tables',data=>$TABLES);

#######################################################
my $accessFile = "$C->{'<nmis_conf>'}/Access.nmis";
print "Adding new Access Definition to $accessFile\n";

backupFile(file => $accessFile, backup => "$accessFile.backup");

my $ACCESS = loadTable(dir=>'conf',name=>'Access');

$ACCESS->{'table_circuitgroups_rw'} = {
    'descr' => 'Write access to table Circuit Groups',
    'group' => 'access',
    'level0' => '1',
    'level1' => '1',
    'level2' => '1',
    'level3' => '0',
    'level4' => '0',
    'level5' => '0',
    'name' => 'table_circuitgroups_rw'
};

$ACCESS->{'table_circuitgroups_view'} = {
    'descr' => 'View access to table Circuit Groups',
    'group' => 'access',
    'level0' => '1',
    'level1' => '1',
    'level2' => '1',
    'level3' => '0',
    'level4' => '1',
    'level5' => '0',
    'name' => 'table_circuitgroups_view'
};

writeTable(dir=>'conf',name=>'Access',data=>$ACCESS);

#######################################################
my $circuitFile = "$C->{'<nmis_conf>'}/CircuitGroups.nmis";
if ( not -f $circuitFile )  {
	print "Adding empty Definition to $circuitFile\n";
	my $CIRCUITS = {};
	writeTable(dir=>'conf',name=>'CircuitGroups',data=>$CIRCUITS);
}

print "Done installing support for CircuitGroups\n";



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
