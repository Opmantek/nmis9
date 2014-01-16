#!/usr/bin/perl
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
use NMIS;
use func;
use Proc::ProcessTable;

# load configuration table
my $C = loadConfTable(conf=>"",debug=>0);
 

my $FORMAT = "%-6s %-10s %-8s %-24s %-8s %s\n";
my $t = new Proc::ProcessTable;
my $now = time();
printf($FORMAT, "PID", "TTY", "STAT", "START", "RUNTIME", "COMMAND"); 
foreach my $p ( @{$t->table} ){
	my $runtime = time - $p->start;
	if ( $p->cmndline =~ /nmis.pl.collect/ ) {
		printf($FORMAT, 
		$p->pid, 
		$p->ttydev, 
		$p->state, 
		scalar(localtime($p->start)), 
		$runtime,
		$p->cmndline);
		if ( $runtime > 300 ) {
			my $pid = $p->pid();
			my $cmndline = $p->cmndline();
			print "$pid $cmndline is more than 5 minutes old\n";
		}
	}

}



 # Dump all the information in the current process table
 #use Proc::ProcessTable;

 #$t = new Proc::ProcessTable;

 #foreach $p (@{$t->table}) {
 # print "--------------------------------\n";
 # foreach $f ($t->fields){
 #   print $f, ":  ", $p->{$f}, "\n";
 # }
 #}              
