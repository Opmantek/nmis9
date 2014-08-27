#!/usr/bin/perl
#
## $Id: import_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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
use NMIS::Timing;

use Fcntl qw(:DEFAULT :flock);

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});


# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $overwrite = setDebug($arg{overwrite});

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 will import nodes to NMIS.
ERROR: need some files to work with
usage: $0 <NODES_1> <NODES_2>
eg: $0 csv=/usr/local/nmis8/admin/import_nodes_sample.csv nodes=/usr/local/nmis8/conf/Nodes.nmis.new


The sample CSV looks like this:
--sample--
name,host,group,role,community
import_test1,127.0.0.1,Branches,core,nmisGig8
import_test2,127.0.0.1,Sales,core,nmisGig8
import_test3,127.0.0.1,DataCenter,core,nmisGig8
--sample--

EO_TEXT
	exit 1;
}

if ( -r $arg{csv} ) {
		loadNodes($arg{csv},$arg{nodes});
}
else {
	print "ERROR: $arg{csv} is an invalid file\n";
}

exit 1;

sub loadNodes {
	my $csvfile = shift;
	my $nmisnodes = shift;
	
	print $t->markTime(). " Loading the Local Node List\n";
	my $LNT = loadLocalNodeTable();
	print "  done in ".$t->deltaTime() ."\n";
	
	print $t->markTime(). " Loading the Import Nodes from $csvfile\n";
	my %newNodes = &myLoadCSV($csvfile,"name",",");
	print "  done in ".$t->deltaTime() ."\n";
	
	print "\n";
	my $sum = initSummary();
	foreach my $node (keys %newNodes) {

		if ( $newNodes{$node}{name} ne "" 
			and $newNodes{$node}{host} ne "" 
			and $newNodes{$node}{role} ne "" 
			and $newNodes{$node}{community} ne "" 
		) {

			my $nodekey = $newNodes{$node}{name};
			++$sum->{total};

			if ( $LNT->{$nodekey}{name} ne "" ) {
				print "UPDATE: node=$newNodes{$node}{name} host=$newNodes{$node}{host} group=$newNodes{$node}{group}\n";
				++$sum->{update};
			}
			else {
				print "ADDING: node=$newNodes{$node}{name} host=$newNodes{$node}{host} group=$newNodes{$node}{group}\n";
				++$sum->{add};
			}
			
			my $roleType = $newNodes{$node}{role} || "access";
			$roleType = $newNodes{$node}{roleType} if $newNodes{$node}{roleType};

			my $netType = $newNodes{$node}{net} || "lan";
			$netType = $newNodes{$node}{netType} if $newNodes{$node}{netType};

			$LNT->{$nodekey}{name} = $newNodes{$node}{name};
			$LNT->{$nodekey}{host} = $newNodes{$node}{host} || $newNodes{$node}{name};
			$LNT->{$nodekey}{group} = $newNodes{$node}{group} || "NMIS8";
			$LNT->{$nodekey}{roleType} = $newNodes{$node}{role} || "access";
			$LNT->{$nodekey}{community} = $newNodes{$node}{community} || "public";
	
			$LNT->{$nodekey}{businessService} = $newNodes{$node}{businessService} || "";
			$LNT->{$nodekey}{serviceStatus} = $newNodes{$node}{serviceStatus} || "Production";
			$LNT->{$nodekey}{location} = $newNodes{$node}{location} || "default";

			$LNT->{$nodekey}{active} = $newNodes{$node}{active} || "true";
			$LNT->{$nodekey}{collect} =  $newNodes{$node}{collect} || "true";
			$LNT->{$nodekey}{netType} = $newNodes{$node}{net} || "lan";
			$LNT->{$nodekey}{depend} = $newNodes{$node}{depend} || "N/A";
			$LNT->{$nodekey}{threshold} = $newNodes{$node}{threshold} || 'true';
			$LNT->{$nodekey}{ping} = $newNodes{$node}{ping} || 'true';
			$LNT->{$nodekey}{port} = $newNodes{$node}{port} || '161';
			$LNT->{$nodekey}{cbqos} = $newNodes{$node}{cbqos} || 'none';
			$LNT->{$nodekey}{calls} = $newNodes{$node}{calls} || 'false';
			$LNT->{$nodekey}{rancid} = $newNodes{$node}{rancid} || 'false';
			$LNT->{$nodekey}{services} = $newNodes{$node}{services} || undef;
			$LNT->{$nodekey}{webserver} = $newNodes{$node}{webserver} || 'false' ;
			$LNT->{$nodekey}{model} = $newNodes{$node}{model} || 'automatic';
			$LNT->{$nodekey}{version} = $newNodes{$node}{version} || 'snmpv2c';
			$LNT->{$nodekey}{timezone} = $newNodes{$node}{timezone} ||0 ;
		}
		else {
			print "ERROR: we really need to know at least node, host, community, role and group\n";
		}
	}

	print qq|
$sum->{total} nodes processed
$sum->{add} nodes added
$sum->{update} nodes updated
|;

	if ( $nmisnodes ne "" ) {
		if ( not -f $nmisnodes ) {
			writeHashtoFile(file => $nmisnodes, data => $LNT);
			print "New nodes imported into $nmisnodes, check the file and copy over existing NMIS Nodes file\n";
			print "cp $nmisnodes /usr/local/nmis8/conf/Nodes.nmis\n";
		}
		elsif ( -r $nmisnodes and $overwrite ) {
			backupFile(file => $nmisnodes, backup => "$nmisnodes.backup");
			writeHashtoFile(file => $nmisnodes, data => $LNT);
			print "New nodes imported into $nmisnodes, check the file and copy over existing NMIS Nodes file\n";
			print "cp $nmisnodes /usr/local/nmis8/conf/Nodes.nmis\n";
		}
		else {
			print "ERROR: file $nmisnodes already exists\n";
		}
	}
	else {
		print "ERROR: no file to save to provided\n";
	}
	
}

sub initSummary {
	my $sum;

	$sum->{add} = 0;
	$sum->{update} = 0;
	$sum->{total} = 0;

	return $sum;
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

sub myLoadCSV {
	my $file = shift;
	my $key = shift;
	my $seperator = shift;
	my $reckey;
	my $line = 1;
	
	if ( $seperator eq "" ) { $seperator = "\t"; }

	my $passCounter = 0;

	my $i;
	my @rowElements;
	my @headers;
	my %headersHash;
	my @keylist;
	my $row;
	my $head;
	
	my %data;
	
	#open (DATAFILE, "$file")
	if (sysopen(DATAFILE, "$file", O_RDONLY)) {
		flock(DATAFILE, LOCK_SH) or warn "can't lock filename: $!";
	
		while (<DATAFILE>) {
			s/[\r\n]*$//g;
			#$_ =~ s/\n$//g;
			# If it is the first pass load the column headers into an array and a hash.
			if ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter == 0 ) {
				++$passCounter;
				$_ =~ s/\"//g;
				@headers = split(/$seperator|\n/, $_);
				for ( $i = 0; $i <= $#headers; ++$i ) {
					$headersHash{$headers[$i]} = $i;
				}
			}
			elsif ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter > 0 ) {
				$_ =~ s/\"//g;
				@rowElements = split(/$seperator|\n/, $_);
				if ( $key =~ /:/ ) {
					$reckey = "";
					@keylist = split(":",$key);
					for ($i = 0; $i <= $#keylist; ++$i) {
						$reckey = $reckey.lc("$rowElements[$headersHash{$keylist[$i]}]");
						if ( $i < $#keylist )  { $reckey = $reckey."_" }
					}
				}
				else {
					$reckey = lc("$rowElements[$headersHash{$key}]");
				}
				if ( $#headers > 0 and $#headers != $#rowElements ) {
					$head = $#headers + 1;
					$row = $#rowElements + 1;
					print STDERR "ERROR: $0 in csv.pm: Invalid CSV data file $file; line $line; record \"$reckey\"; $head elements in header; $row elements in data.\n";
				}
				#What if $reckey is blank could form an alternate key?
				if ( $reckey eq "" or $key eq "" ) {
					$reckey = join("-", @rowElements);
				}
				
				for ($i = 0; $i <= $#rowElements; ++$i) {
					if ( $rowElements[$i] eq "null" ) { $rowElements[$i] = ""; }
					$data{$reckey}{$headers[$i]} = $rowElements[$i];
				}
			}
			++$line;
		}
		close (DATAFILE) or warn "can't close filename: $!";
	} else {
		logMsg("cannot open file $file, $!");
	}
	
	return (%data);
}
