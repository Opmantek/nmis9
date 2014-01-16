#!/usr/bin/perl
#
## $Id: opsla_fix_error_timeout.pl,v 1.2 2012/05/16 05:23:45 keiths Exp $
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

# Include for reference
#use lib "/usr/local/nmis8/lib";

# 
use strict;
use Fcntl qw(:DEFAULT :flock);
use func;
use NMIS;
use NMIS::IPSLA;
use NMIS::Timing;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($nvp{debug});
#$debug = $debug;

# load configuration table
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

my $log = "$C->{'<nmis_base>'}/admin/ipsla+_fix_error_probes.log";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 will change probes in error to running because you want them to go now.
usage: $0 run=(true|false)
eg: $0 run=true

EO_TEXT
	exit 1;
}

if ( $nvp{run} ne "true" ) {
	print "$0 you don't want me to run!\n";
	exit 1;
}

print $t->markTime(). " Creating IPSLA Object\n";
my $IPSLA = NMIS::IPSLA->new(C => $C);
print "DEBUG: nmisdb=$C->{nmisdb} db_server=$C->{db_server} db_prefix=$C->{db_prefix}\n";
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " Getting list of Probes\n";
my @probeList = $IPSLA->getProbes();

my $count;
foreach my $p ( sort { $a->{probe} cmp $b->{probe} } @probeList ) {
	if ($p->{status} eq "error") {
		#if ( $p->{probe} =~ /CI0000212/ and $p->{message} =~ /Error snmpset attributes for probe echo/ ) {
		if ( $p->{message} =~ /Error snmpset attributes for probe echo/ ) {
			++$count;
			print $t->elapTime(). " PROBE UPD $count: $p->{probe}, message=$p->{message}\n";
			$IPSLA->updateProbe(
				probe => $p->{probe}, 
				func => "start",
				timeout => 5
			);
			$IPSLA->updateMessage(
				probe => $p->{probe}, 
				message => "NULL"
			);
		}
		elsif ( $p->{optype} eq "echo" and $p->{message} eq "" ) {
			++$count;
			print $t->elapTime(). " PROBE UPD $count: $p->{probe}, message=NULL\n";
			$IPSLA->updateProbe(
				probe => $p->{probe}, 
				func => "start",
				timeout => 5
			);
		}
		elsif ( $p->{probe} =~ /DO NOT RUN THIS/ ) {
			print "Probe $p->{probe} has status $p->{status} and message $p->{message}\n";
			#print $t->elapTime(). " PROBE UPD: $probe, status=running\n";
			#$IPSLA->updateProbe(
			#	probe => $p->{probe}, 
			#	status => "running", 
			#	message => " ", 
			#);
			
			my %sprobe;
			$sprobe{probe} = $p->{probe};
			$sprobe{func} = "start";
			$sprobe{select} = $p->{select};
			$sprobe{pnode} = $p->{pnode}; # probe node
			$sprobe{optype} = $p->{optype}; # probe type
			$sprobe{saddr} = $p->{saddr}; # source address
			$sprobe{rnode} = $p->{rnode}; #
			$sprobe{raddr} = $p->{raddr};
			$sprobe{tnode} = $p->{tnode};
			$sprobe{dport} = $p->{dport};
			$sprobe{url} = $p->{url};
			$sprobe{history} = $p->{history};
			$sprobe{frequence} = $p->{frequence};
			$sprobe{lsrpath} = $p->{lsrpath};
			$sprobe{reqdatasize} = $p->{reqdatasize};
			$sprobe{timeout} = $p->{timeout};
			$sprobe{tos} = $p->{tos};
			$sprobe{interval} = $p->{interval};
			$sprobe{numpkts} = $p->{numpkts};
			$sprobe{tport} = $p->{tport};
			$sprobe{tas} = $p->{tas};
			$sprobe{codec} = $p->{codec};
			$sprobe{factor} = $p->{factor};
			$sprobe{vrf} = $p->{vrf};
			$sprobe{deldb} = $p->{deldb};
			$sprobe{verify} = $p->{verify};
			my $n = $p->{probe}; $n =~ s/[\._]/-/g ;
			$sprobe{database} = "$C->{database_root}/misc/ipsla-${n}.rrd";
			
			if ( -f $p->{database} ) {
				$sprobe{database} = $p->{database};		
			}
	
			$sprobe{status} = "start requested";
			$sprobe{message} = " ";
			
			logit("Deleting Probe: $p->{probe}, status: $p->{status}, message: $p->{message}");
			$IPSLA->deleteProbe(probe => $p->{probe});
	
			logit("Update Node: $p->{pnode}, entry: 320");
			$IPSLA->updateNode(node => $p->{pnode}, entry => 320);
	
			logit("Add Probe: $sprobe{probe}, status: $sprobe{status}, optype: $sprobe{optype}, tos: $sprobe{tos}");
			$IPSLA->addProbe(%sprobe);	
		}
	}
}

# message with (class::)method names and line number
sub logit {
	my $msg = shift;
	my $handle;
	open($handle,">>$log") or warn returnTime." log, Couldn't open log file $log. $!\n";
	flock($handle, LOCK_EX)  or warn "log, can't lock filename: $!";
	print $handle returnDateStamp().",$msg\n" or warn returnTime." log, can't write file $log. $!\n";
	close $handle or warn "log, can't close filename: $!";
}
