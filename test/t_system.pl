#!/usr/bin/perl
#
## $Id: t_system.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
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
use Sys;
use NMIS::Timing;
use NMIS::Connect;

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $node = "wanedge1";

print $t->markTime(). " Create System $node\n";
my $S = Sys::->new; # create system object
$S->init(name=>$node,snmp=>'false');
print "  done in ".$t->deltaTime() ."\n";	

print $t->markTime(). " Load Some Data\n";
my $NI = $S->{info};

foreach my $inf (sort keys %{$NI}) {
	print "NI $inf=$NI->{inf}\n";	
	if ($inf eq "system") {
		foreach my $sys (sort keys %{$NI->{$inf}}) {
			print "  $sys = $NI->{$inf}{$sys}\n";
		}
	}
}
print "  done in ".$t->deltaTime() ."\n";	

print $t->markTime(). " Mark Node SNMP Down $node snmpdown=$NI->{system}{snmpdown}\n";
my $exit = snmpNodeDown(sys=>$S);
my $info = $S->ndinfo;
print "exit=$exit snmpdown1=$info->{system}{snmpdown} snmpdown2=$NI->{system}{snmpdown}\n";


print "  done in ".$t->deltaTime() ."\n";	

my $result;
if ( ($result) = testReturn(1) ) {
	print "success=$result\n";
}
else {
	print "failed=$result\n";
}

my @result;
if ( @result = testReturn(0) ) {
	print "success=@result\n";
}
else {
	print "failed=@result\n";
}

print $t->elapTime(). " End\n";

my $string = '"Hello" Monkey';
print "string=$string\n";
$string =~ s/\"/\'/g;
print "string=$string\n";

sub testReturn {
	my $value = shift;
	if ( $value ) {
		return (1,2,3);	
	}
	else {
		return;
	}
}

sub snmpNodeDown {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;	# node info
	$NI->{system}{snmpdown} = 'true';
	return 0;
}

