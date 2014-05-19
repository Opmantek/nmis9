#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use Data::Dumper;
use Net::SNMP; 

# Variables for command line munging
my %arg = getArguements(@ARGV);

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will load nodeConf.nmis and remove bad Node entries.

usage: $0 run=(true|false) clean=(true|false)
eg: $0 run=true (will run in test mode)
or: $0 run=true clean=true (will run in clean mode)

EO_TEXT
	exit 1;
}


my $debug = setDebug($arg{debug});

my $t = NMIS::Timing->new();
print $t->elapTime(). " Begin\n" if $debug;

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ( $arg{run} eq "true" ) {
	cleanNodeConf();
}

print $t->elapTime(). " End\n" if $debug;


sub cleanNodeConf {
	my $LNT = loadLocalNodeTable();
	my $NCT = loadNodeConfTable();
	
	foreach my $node (keys %{$NCT}) {
		if ( not defined $LNT->{$node}{name} ) {
			print "NodeConf entry found for $node, but nothing in Local Node Table\n";
			if ( $arg{clean} eq "true" ) {
				delete $NCT->{$node};
			}
		}
		# check interface entries.
		else {
			foreach my $ifDescr (keys %{$NCT->{$node}}) {
				if ( ref($NCT->{$node}{$ifDescr}) eq "HASH" ) {
					my $noDescr = 1;
					my $noSpeedIn = 1;
					my $noSpeedOut = 1;
					my $noCollect = 1;
					my $noEvent = 1;
					if ( $NCT->{$node}{$ifDescr}{ifDescr} ne "" and $NCT->{$node}{$ifDescr}{Description} ne "" ) {
						$noDescr = 0;
					}
	
					if ( $NCT->{$node}{$ifDescr}{ifDescr} ne "" and $NCT->{$node}{$ifDescr}{collect} ne "" ) {
						$noCollect = 0;
					}
	
					if ( $NCT->{$node}{$ifDescr}{ifDescr} ne "" and $NCT->{$node}{$ifDescr}{event} ne "" ) {
						$noEvent = 0;
					}
	
					if ( $NCT->{$node}{$ifDescr}{ifDescr} ne "" and $NCT->{$node}{$ifDescr}{ifSpeedIn} ne "" ) {
						$noSpeedIn = 0;
					}
	
					if ( $NCT->{$node}{$ifDescr}{ifDescr} ne "" and $NCT->{$node}{$ifDescr}{ifSpeedOut} ne "" ) {
						$noSpeedOut = 0;
					}
	
					# if this interface has no other properties, then get rid of it.
					if ( $noDescr and $noCollect and $noEvent and $noSpeedIn and $noSpeedOut ) {
						print "Deleting redundant entry for $NCT->{$node}{$ifDescr}{ifDescr}\n";
						delete $NCT->{$node}->{$ifDescr};
					}
				}
			}
		}
	}

	my $nct_file = getFileName(file => "nodeConf");
	$nct_file = "$C->{'<nmis_conf>'}/$nct_file";
	my $nct_backup = $nct_file .".". getDateThingy();
	#print "NCT=$nct_file backup=$nct_backup\n";

	if ( $arg{clean} eq "true" ) {
		print "backing up $nct_file to $nct_backup\n";
		my $backup = backupFile(file => $nct_file, backup => $nct_backup);
		if ( $backup ) {
			writeTable(dir=>'conf',name=>'nodeConf',data=>$NCT);
		}
		else {
			print "ERROR: could not backup file, skipping save of new file\n";
		}
	}
	
}


sub backupFile {
	my %arg = @_;
	my $buff;
	if ( not -f $arg{backup} ) {			
		if ( -r $arg{file} ) {
			open(IN,$arg{file}) or warn ("ERROR: problem with file $arg{file}; $!");
			open(OUT,">$arg{backup}") or warn ("ERROR: problem with file $arg{backup}; $!");
			binmode(IN);
			binmode(OUT);
			while (read(IN, $buff, 8 * 2**10)) {
			    print OUT $buff;
			}
			close(IN);
			close(OUT);
			return 1;
		} else {
			print STDERR "ERROR: backupFile file $arg{file} not readable.\n";
			return 0;
		}
	}
	else {
		print STDERR "ERROR: backup target $arg{backup} already exists.\n";
		return 0;
	}
}

#Function which returns the time
sub getDateThingy {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	++$mon;
	if ($mon<10) {$mon = "0$mon";}
	if ($mday<10) {$mday = "0$mday";}
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	return "$year-$mon-$mday-$hour$min$sec";
}
