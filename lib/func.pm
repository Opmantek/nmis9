#
## $Id: func.pm,v 8.26 2012/09/21 05:05:10 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
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
package func;
our $VERSION = "1.2.5";

use strict;
use Fcntl qw(:DEFAULT :flock :mode);
use File::Path;
use File::stat;
use Time::ParseDate; # fixme: actually NOT used by func
use Time::Local;		 # fixme: actuall NOT used by func
use POSIX qw();			 # we want just strftime
use CGI::Pretty qw(:standard);
use version 0.77;

use JSON::XS;
use Proc::ProcessTable;

use Data::Dumper;
$Data::Dumper::Indent=1;
$Data::Dumper::Sortkeys=1;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(	
		getArguements
		getCGIForm
		setDebug
		convertIfName
		convertIfSpeed
		convertLineRate
		rmBadChars
		stripSpaces
		mediumInterface
		shortInterface
		returnDateStamp
		returnDate
		returnTime
		get_localtime
		convertMonth
		convertSecsHours
		convertTime
		convertTimeLength
		convertUpTime
		convUpTime
		eventNumberLevel
		colorTime
		colorStatus
		getBGColor
		eventColor
		eventLevelSet
		checkHostName
		getBits

		colorPercentLo
		colorPercentHi
		colorResponseTime
		
		sortall
		sortall2
		sorthash

		backupFile

		loadTable
		writeTable
		setFileProt
		setFileProtDirectory
		existFile
		mtimeFile
		getFileName
		getExtension
		writeHashtoFile
		readFiletoHash

		htmlElementValues
		logMsg
		logAuth2
		logAuth
		logIpsla
		logPolling
		logDebug
		dbg
		info
		getbool
		loadConfTable
		readConfData
		writeConfData
		getKernelName
		createDir
		checkDir
		checkFile
		checkDirectoryFiles

		checkPerlLib
    beautify_physaddress
	);


# cache table
my $C_cache = undef; # configuration table cache
my $C_modtime = undef;
my %Table_cache;
my $Config_cache = undef;
my $confdebug = 0;
my $nmis_var;
my $nmis_conf;
my $nmis_models;
my $nmis_logs;
my $nmis_log;
my $nmis_mibs;
my @htmlElements;

# preset kernel name
my $kernel = $^O; 

# synchronisation with the main signal handler, to terminate gracefully
my $_critical_section = 0;
my $_interrupt_pending = 0;

# returns ref to the interrupt pending counter
sub interrupt_pending
{
	return \$_interrupt_pending;
}

sub in_critical_section
{
	return $_critical_section;
}

sub enter_critical
{
	return ++$_critical_section;
}

# this handles pending interrupts if catch_zap has signalled any.
sub leave_critical
{
	--$_critical_section;
	if ($_interrupt_pending)
	{
		logMsg("INFO Process $$ ($0) received signal, shutting down\n");
		die "Process $$ ($0) received signal, shutting down\n";
	}
	return $_critical_section;
}

sub getArguements {
	my @argue = @_;
	my (%nvp, $name, $value, $line, $i);
	for ($i=0; $i <= $#argue; ++$i) {
	        if ($argue[$i] =~ /.+=/) {
	                ($name,$value) = split("=",$argue[$i]);
	                $nvp{$name} = $value;
	        } 
	        else { print "Invalid command argument: $argue[$i]\n"; }
	}
	return %nvp;
}

sub getCGIForm {
	my $buffer = shift;
	my (%FORM, $name, $value, $pair, @pairs);
	@pairs = split(/&/, $buffer);
	foreach $pair (@pairs) {
	    ($name, $value) = split(/=/, $pair);
	    $value =~ tr/+/ /;
	    $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
	    $FORM{$name} = $value;
	}
	return %FORM;	
}

sub convertIfName {
	my $ifName = shift;
	$ifName =~ s/\W+/-/g;
	$ifName =~ s/\-$//g;
	$ifName = lc($ifName);
	return $ifName
}

sub rmBadChars {
	my $intf = shift;
	$intf =~ s/\x00//g;
	$intf =~ s/'//g;		# 'PIX interface descr need these removed
	$intf =~ s/,//g;		# all descr need "," removed else .csv will parse incorrectly.
	return $intf;
}

sub stripSpaces{
	my $str = shift;
	$str =~ s/^\s+//;
	$str =~ s/\s+$//;
	return $str;
}

sub convertIfSpeed {
	my $ifSpeed = shift;

	if ( $ifSpeed eq "auto" ) { $ifSpeed = "auto" }
	elsif ( $ifSpeed == 1 ) { $ifSpeed = "auto" }
	elsif ( $ifSpeed eq "" ) { $ifSpeed = "N/A" }
	elsif ( $ifSpeed == 0 ) { $ifSpeed = "N/A" }
	elsif ( $ifSpeed < 2000000 ) { $ifSpeed = $ifSpeed / 1000 ." Kbps" }
	elsif ( $ifSpeed < 1000000000 ) { $ifSpeed = $ifSpeed / 1000000 ." Mbps" }
	elsif ( $ifSpeed >= 1000000000 ) { $ifSpeed = $ifSpeed / 1000000000 ." Gbps" }

	return $ifSpeed;
}

sub convertLineRate {
	my $bits = shift;

	if ( ! $bits ) { $bits = 0 }
	elsif ( $bits < 1000 ) { $bits = $bits ." bps" }
	elsif ( $bits < 2000000 ) { $bits = $bits / 1000 ." Kbps" }
	elsif ( $bits < 1000000000 ) { $bits = $bits / 1000000 ." Mbps" }
	elsif ( $bits >= 1000000000 ) { $bits = $bits / 1000000000 ." Gbps" }

	return $bits;
}

sub mediumInterface {
	my $shortint = shift;
	
	# Change the Names of interfaces to shortnames
	$shortint =~ s/PortChannel/pc/gi;
	$shortint =~ s/TokenRing/tr/gi;
	$shortint =~ s/Ethernet/eth/gi;
	$shortint =~ s/FastEth/fa/gi;
	$shortint =~ s/GigabitEthernet/gig/gi;
	$shortint =~ s/Serial/ser/gi;
	$shortint =~ s/Loopback/lo/gi;
	$shortint =~ s/VLAN/vlan/gi;
	$shortint =~ s/BRI/bri/gi;
	$shortint =~ s/fddi/fddi/gi;
	$shortint =~ s/Async/as/gi;
	$shortint =~ s/ATM/atm/gi;
	$shortint =~ s/Port-channel/pchan/gi;
	$shortint =~ s/channel/chan/gi;
	$shortint =~ s/dialer/dial/gi;
	
	return($shortint);
}

sub shortInterface {
	my $shortint = shift;
	
	# Change the Names of interfaces to shortnames
	$shortint =~ s/FastEthernet/f/gi;
	$shortint =~ s/GigabitEthernet/g/gi;
	$shortint =~ s/Ethernet/e/gi;
	$shortint =~ s/PortChannel/pc/gi;
	$shortint =~ s/TokenRing/t/gi;
	$shortint =~ s/Serial/s/gi;
	$shortint =~ s/Loopback/l/gi;
	$shortint =~ s/VLAN/v/gi;
	$shortint =~ s/BRI/b/gi;
	$shortint =~ s/fddi/fddi/gi;
	$shortint =~ s/Async/as/gi;
	$shortint =~ s/ATM/atm/gi;
	$shortint =~ s/Port-channel/pc/gi;
	$shortint =~ s/channel/chan/gi;
	$shortint =~ s/dialer/d/gi;
	$shortint =~ s/-aal5 layer//gi;
	$shortint =~ s/ /_/gi;
	$shortint =~ s/\//-/gi;
	$shortint = lc($shortint);
	
	return($shortint);
}

# Function which returns the time, formatted, NON-locale-capable
sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }

	my @timecomps = localtime($time);
	# want 24-Mar-2014 11:22:33, regardless of LC_*, so %b isn't good.
	my $mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$timecomps[4]];
	return POSIX::strftime("%d-$mon-%Y %H:%M:%S", localtime($time));
}

# return just the date component
sub returnDate
{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
        else { $year=$year+2000; }
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year";
}

# and just the time part
sub returnTime
{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	return POSIX::strftime("%H:%M:%S", localtime($time));
}

sub get_localtime {
	my $time;
	# pull the system timezone and then the local time
	if ($^O =~ /win32/i) { # could add timezone code here
		$time = scalar localtime;
	} else { 
		# assume UNIX box - look up the timezone as well.
		my $zone = uc((split " ", `date`)[4]);
		if ($zone =~ /CET|CEST/) {
			$time = returnDateStamp;
		} else {
			$time = (scalar localtime)." ".$zone;
		}
	}
	return $time;
}

sub convertMonth {
	my $number = shift;

	$number =~ s/01/January/;
	$number =~ s/02/February/;
	$number =~ s/03/March/;
	$number =~ s/04/April/;
	$number =~ s/05/May/;
	$number =~ s/06/June/;
	$number =~ s/07/July/;
	$number =~ s/08/August/;
	$number =~ s/09/September/;
	$number =~ s/10/October/;
	$number =~ s/11/November/;
	$number =~ s/12/December/;

	return $number;
}

# number of seconds into format: HH:MM:SS
sub convertSecsHours {
	my $seconds = shift;

	return sprintf("%02d:%02d:%02d",
								 int($seconds/3600),
								 int(($seconds % 3600) / 60),
								 int($seconds % 60));
}

# 3 Mar 02 - Integrating Trent O'Callaghan's changes for granular graphing.
sub convertTime {
	my $amount = shift;
	my $units = shift;
	my $timenow = time;
	my $newtime;

	if ( $units eq "" ) { $units = "days" }
	else { $units = $units }
	# convert length code into Graph start time
	if ( $units eq "minutes" ) { $newtime = $timenow - $amount * 60; }
	elsif ( $units eq "hours" ) { $newtime = $timenow - $amount * 60 * 60; }
	elsif ( $units eq "days" ) { $newtime = $timenow - $amount * 24 * 60 * 60; }
	elsif ( $units eq "weeks" ) { $newtime = $timenow - $amount * 7 * 24 * 60 * 60; }
	elsif ( $units eq "months" ) { $newtime = $timenow - $amount * 31 * 24 * 60 * 60; }
	elsif ( $units eq "years" ) { $newtime = $timenow - $amount * 365 * 24 * 60 * 60; }

	return $newtime;
}

# 3 Mar 02 - Integrating Trent O'Callaghan's changes for granular graphing.
sub convertTimeLength {
	my $amount = shift;
	my $units = shift;
	my $newtime;
	
	# convert length code into Graph start time
	if ( $units eq "minutes" ) { $newtime = $amount * 60; }
	elsif ( $units eq "hours" ) { $newtime = $amount * 60 * 60; }
	elsif ( $units eq "days" ) { $newtime = $amount * 24 * 60 * 60; }
	elsif ( $units eq "weeks" ) { $newtime = $amount * 7 * 24 * 60 * 60; }
	elsif ( $units eq "months" ) { $newtime = $amount * 31 * 24 * 60 * 60; }
	elsif ( $units eq "years" ) { $newtime = $amount * 365 * 24 * 60 * 60; }

	return $newtime;
}

sub convertUpTime {
	my $timeString = shift;
	my @x;
	my $days;
	my $hours;
	my $seconds;

	$timeString =~ s/  |, / /g;
	
	## KS 24/3/2001 minor problem when uptime is 1 day x hours.  Fixed now.
	if ( $timeString =~ /day/ ) {
		@x = split(/ days | day /,$timeString);
		$days = $x[0];
		$hours = $x[1];
	}
	else { $hours = $timeString; }
	# Now days are a number
	$seconds = $days * 24 * 60 * 60;
	
	# Work on Hours
	@x = split(":",$hours);
	$seconds = $seconds + ( $x[0] * 60 * 60 ) + ( $x[1] * 60 ) + $x[2];
	return $seconds;	
}

sub convUpTime {
    my ($uptime) = @_;
    my ($seconds,$minutes,$hours,$days,$result);

    $days = int ($uptime / (60 * 60 * 24));
    $uptime %= (60 * 60 * 24);

    $hours = int ($uptime / (60 * 60));
    $uptime %= (60 * 60);

    $minutes = int ($uptime / 60);
    $seconds = $uptime % 60;

    if ($days == 0){
	$result = sprintf ("%d:%02d:%02d", $hours, $minutes, $seconds);
    } elsif ($days == 1) {
	$result = sprintf ("%d day, %d:%02d:%02d", 
			   $days, $hours, $minutes, $seconds);
    } else {
	$result = sprintf ("%d days, %d:%02d:%02d", 
			   $days, $hours, $minutes, $seconds);
    }
    return $result;
}


sub eventNumberLevel {
	my $number = shift;
	my $level;

	if ( $number == 1 ) { $level = "Normal"; }
	elsif ( $number == 2 ) { $level = "Warning"; }
	elsif ( $number == 3 ) { $level = "Minor"; }
	elsif ( $number == 4 ) { $level = "Major"; }
	elsif ( $number == 5 ) { $level = "Critical"; }
	elsif ( $number >= 6 ) { $level = "Fatal"; }
	else { $level = "Error"; }

	return $level;
}

sub colorTime {
	my $time = shift;
	my $color = "";
	my ($hours,$minutes,$seconds) = split(":",$time);

	if ( $hours == 0 and $minutes <= 4 )  { $color = "#FFFFFF"; }
	elsif ( $hours == 0 and $minutes <= 5 )  { $color = "#FFFF00"; }
	elsif ( $hours == 0 and $minutes <= 15 ) { $color = "#FFDD00"; }
	elsif ( $hours == 0 and $minutes <= 30 ) { $color = "#FFCC00"; }
	elsif ( $hours == 0 and $minutes <= 45 ) { $color = "#FFBB00"; }
	elsif ( $hours == 0 and $minutes <= 60 ) { $color = "#FFAA00"; }
	elsif ( $hours == 1 ) { $color = "#FF9900"; }
	elsif ( $hours <= 2 ) { $color = "#FF8800"; }
	elsif ( $hours <= 6 ) { $color = "#FF7700"; }
	elsif ( $hours <= 12 ) { $color = "#FF6600"; }
	elsif ( $hours <= 24 ) { $color = "#FF5500"; }
	elsif ( $hours > 24 ) { $color = "#FF0000"; }

	return $color;
}

sub colorStatus {
	my $status = shift;
	my $color = "";

	if ( $status eq "up" ) { $color = colorPercentHi(100); } 		#$color = "#00FF00"; }
	elsif ( $status eq "down" ) { $color = colorPercentHi(0); }		 # "#FF0000"; }
	elsif ( $status eq "testing" ) { $color = '#AAAAAA'; }				 #"#FFFF00"; }
	elsif ( $status eq "null" ) { $color = '#AAAAAA'; } 						#"#FFFF00"; }
	else { $color = '#AAAAAA'; } 																		#"#FFFFF; }

	return $color;
}

# set color for background or border
sub getBGColor {
	return "background-color:$_[0];" ;
}

# updated EHG2004
# see http://www.htmlhelp.com/icon/hexchart.gif
# these are also listed in nmis.css - class 'fatal' etc.
#
sub eventColor {
	my $event_level = shift;
	my $color;

 	if ( $event_level =~ /fatal/i or $event_level =~ /^0$/ ) { $color = colorPercentLo(100) }
 	elsif ( $event_level =~ /critical/i or $event_level == 1 ) { $color = colorPercentLo((100/7)*1) }
 	elsif ( $event_level =~ /major|traceback/i or $event_level == 2 ) { $color = colorPercentLo((100/7)*2) }
 	elsif ( $event_level =~ /minor/i or $event_level == 3 ) { $color = colorPercentLo((100/7)*3) }
 	elsif ( $event_level =~ /warning/i or $event_level == 4 ) { $color = colorPercentLo((100/7)*4) }
 	elsif ( $event_level =~ /error/i or $event_level == 5 ) { $color = colorPercentLo((100/7)*5) }
 	#Was returning a dull green, want a nice lively green.
 	#elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $color = colorPercentLo((100/7)*6) }
 	elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $color = colorPercentLo(0) }
 	elsif ( $event_level =~ /up/i ) { $color = colorPercentHi(100) }
 	elsif ( $event_level =~ /down/i ) { $color = colorPercentHi(0) }
 	elsif ( $event_level =~ /unknown/i ) { $color = '#AAAAAA'  }
 	else { $color = '#AAAAAA'; }
	return $color;
} # end eventColor

sub eventLevelSet {
	my $event_level = shift;
	my $new_level;
	
 	if ( $event_level =~ /fatal/i or $event_level =~ /^0$/ ) { $new_level = "Fatal" }
 	elsif ( $event_level =~ /critical/i or $event_level == 1 ) { $new_level = "Critical" }
 	elsif ( $event_level =~ /major|traceback/i or $event_level == 2 ) { $new_level = "Major" }
 	elsif ( $event_level =~ /minor/i or $event_level == 3 ) { $new_level = "Minor" }
 	elsif ( $event_level =~ /warning/i or $event_level == 4 ) { $new_level = "Warning" }
 	elsif ( $event_level =~ /error/i or $event_level == 5 ) { $new_level = "Error" }
 	elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $new_level = "Normal" }
 	else { $new_level = "unknown" }

	return $new_level;
} # end eventLevel

sub checkHostName {
	my $node = shift;
	my @hostlookup = gethostbyname($node);
	if ( $hostlookup[0] =~ /$node/i or $hostlookup[1] =~ /$node/i ) { return "true"; }
	else { return "false"; }
}

sub getBits {
	$_ = shift;
	my $ps = shift; # 'ps'
	if ( $_ eq "NaN" ) { return "$_" ;}
	elsif ( $_ > 1000000000 ) { $_ /= 1000000000; /(\d+\.\d\d)/; return "$1 Gb${ps}"; }
	elsif ( $_ > 1000000 ) { $_ /= 1000000; /(\d+\.\d\d)/; return "$1 Mb${ps}"; }
	elsif ( $_ > 1000 ) { $_ /= 1000; /(\d+\.\d\d)/; return "$1 Kb${ps}"; }
	else { /(\d+\.\d\d)/; return"$1 b${ps}"; }
}

sub setDebug {
	my $string = shift;
	my $debug = 0;
	if ( $string eq "true" ) { $debug = 1; }	
	elsif (  $string eq "verbose" ) { $debug = 9; }	
	elsif ( $string =~ /\d+/ ) { $debug = $string; }	
	else { $debug = 0; }	
	return $debug;
}

##  performs a binary copy of a file, used for backup of files.
sub backupFile {
	my %arg = @_;
	my $buff;
	if ( -r $arg{file} ) {
		sysopen(IN, "$arg{file}", O_RDONLY) or warn ("ERROR: problem with file $arg{file}; $!");
		flock(IN, LOCK_SH) or warn "can't lock filename: $!";

		# change to secure sysopen with truncate after we got the lock
		sysopen(OUT, "$arg{backup}", O_WRONLY | O_CREAT) or warn ("ERROR: problem with file $arg{backup}; $!");
		flock(OUT, LOCK_EX) or warn "can't lock filename: $!";
		enter_critical;
		truncate(OUT, 0) or warn "can't truncate filename: $!";

		binmode(IN);
		binmode(OUT);		
		while (read(IN, $buff, 8 * 2**10)) {
		    print OUT $buff;
		}
		close(IN) or warn "can't close filename: $!";
		close(OUT) or warn "can't close filename: $!";
		leave_critical;
		return 1;
	} else {
		print STDERR "ERROR, backupFile file $arg{file} not readable.\n";
		return 0;
	}	
}

# funky sort, by Eric.
# call me like this:
# foreach $i ( sortall(\%hash, 'value', 'fwd') );
# or
# foreach $i ( sorthash(\%hash, [ 'value1', 'value2', 'value3' ], 'fwd') ); value2 and 3 are optional
# where 'value' is the hash value that you wish to sort on.
# 3rd arguement = forward|reverse
# example: foreach $reportnode ( sort { $reportTable{$b}{response} <=> $reportTable{$a}{response} } keys %reportTable )
# now:	foreach $reportnode ( sortall(\%reportTable, 'response' , 'fwd|rev') )
#
# sortall2 - takes two hash arguements
# foreach $i ( sortall2(\%hash, 'sort1', 'sort2', 'fwd|rev') );

sub sortall2 {
	sort { alpha( $_[3], $_[0]->{$a}{$_[1]}, $_[0]->{$b}{$_[1]}) || alpha( $_[3], $_[0]->{$a}{$_[2]}, $_[0]->{$b}{$_[2]}) } keys %{$_[0]};
}

sub sortall {
	sort { alpha( $_[2], $_[0]->{$a}{$_[1]}, $_[0]->{$b}{$_[1]}) }  keys %{$_[0]};
}

sub sorthash {
my $cnt =  scalar @{$_[1]} ;
	if (scalar @{$_[1]} == 0) { return sort { alpha( $_[2], $a, $b) }  keys %{$_[0]}; }
	if (scalar @{$_[1]} == 1) { return sort { alpha( $_[2], $_[0]->{$a}{$_[1]->[0]}, $_[0]->{$b}{$_[1]->[0]}) }  keys %{$_[0]}; }
	if (scalar @{$_[1]} == 2) { return sort { alpha( $_[2], $_[0]->{$a}{$_[1]->[0]}{$_[1]->[1]}, $_[0]->{$b}{$_[1]->[0]}{$_[1]->[1]}) }  keys %{$_[0]}; }
	if (scalar @{$_[1]} == 3) { return sort { alpha( $_[2], $_[0]->{$a}{$_[1]->[0]}{$_[1]->[1]}{$_[1]->[2]}, $_[0]->{$b}{$_[1]->[0]}{$_[1]->[1]}{$_[1]->[2]}) }  keys %{$_[0]}; }
}

sub alpha {
	# first arg is direction
	my ($f, $s);
	if ( shift eq 'fwd' ) {
		$f = shift;
		$s = shift;
		if ( $f	eq 'NaN' && $s ne 'NaN') { return 1 }
		if ( $f	eq 'NaN' && $s eq 'NaN') { return 0 }
		if ( $s	eq 'NaN' && $f ne 'NaN') { return -1 }

	} else {
		$s = shift;
		$f = shift;
		if ( $f	eq 'NaN' && $s ne 'NaN') { return -1 }
		if ( $f	eq 'NaN' && $s eq 'NaN') { return 0 }
		if ( $s	eq 'NaN' && $f ne 'NaN') { return 1 }
	}
#print "SORT a=$f, b=$s<br>";
	#print STDERR "f=$f s=$s sort2=$sort2\n";
	# Sort IP addresses numerically within each dotted quad
	if ($f =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
		my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
		if ($s =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
			return ($a1 <=> $b1) || ($a2 <=> $b2)
			|| ($a3 <=> $b3) || ($a4 <=> $b4);
		}
	}
	# Handle things like Serial0/1/2
	if ($f =~ /^(.*\D)(\d+).(\d+).(\d+)/) {
	    my($a1,$a2,$a3,$a4) = ($1,$2,$3,$4);
	    if ($s =~ /^(.*\D)(\d+).(\d+).(\d+)/) {
			my($b1,$b2,$b3,$b4) = ($1,$2,$3,$4);
			return (lc($a1) cmp lc($b1) ) || ($a2 <=> $b2) || ($a3 <=> $b3) || ($a4 <=> $b4) ;
	    }
	}
	# Sort numbers numerically
	elsif ( $f !~ /[^0-9\.]/ && $s !~ /[^0-9\.]/ ) {
		return $f <=> $s;
	}
	# Handle things like Level1, ..., Level10
	if ($f =~ /^(.*\D)(\d+)$/) {
	    my($a1,$a2) = ($1, $2);
	    if ($s =~ /^(.*\D)(\d+)$/) {
			my($b1, $b2) = ($1, $2);
			return $a2 <=> $b2 if $a1 eq $b1;
	    }
	}
	# Default is to sort alphabetically
	return lc($f) cmp lc($s);
}

#
# set file owner and permission, default nmis and 0775.
# change the default by conf/nmis.conf parameters "username" and "fileperm".
#
sub setFileProt {
	my $filename = shift;
	my $username = shift;
	my $permission = shift;
	my $login;
	my $pass;
	my $uid;
	my $gid;
	my $C = loadConfTable();

	if ( not -r $filename and ! -d $filename ) {	# adapted for directory: Till Dierkesmann
		logMsg("ERROR, file=$filename does not exist");
		return ;
	}

	my $currentstatus = stat($filename);
	
	# set the permissions. Skip if not running as root
	if ( $< == 0) { # root
		if ($username eq '') {
			if ( $C->{'os_username'} ne "" ) {
				$username = $C->{'os_username'} ;
			} 
			else {
				$username = "nmis"; # default
			}
		}
		if ($permission eq '') {
			if ( -d $filename and $C->{'os_execperm'} ne "" ) {
				$permission = $C->{'os_execperm'} ;
			}
			elsif ( -f $filename and $filename =~ /$C->{'nmis_executable'}/ and $C->{'os_execperm'} ne "" ) {
				$permission = $C->{'os_execperm'} ;
			}
			elsif ( -f $filename and $C->{'os_fileperm'} ne "" ) {
				$permission = $C->{'os_fileperm'} ;
			}
			elsif ( -d $filename ) {	# Directory permission added by Till Dierkesmann
				$permission = "0770"; # Default for dirs
			}
			else {
				$permission = "0660"; # default
			}
		}
		
		if (!(($login,$pass,$uid,$gid) = getpwnam($username))) {
			logMsg("ERROR, unknown username $username");
		} else {
			# ownership ok or in need of changing?
			if ($currentstatus->uid != $uid or $currentstatus->gid != $gid)
			{
				dbg("setting owner of $filename to $username",3);
				if (!chown($uid,$gid,$filename)) {
					logMsg("ERROR, could not change ownership $filename to $username, $!");
				}
			}
			# perms need changing?
			if (($currentstatus->mode & 07777) != oct($permission))
			{
				dbg("setting permissions of $filename to $permission",3);
				if (!chmod(oct($permission), $filename)) 
				{
					logMsg("ERROR, could not change $filename permissions to $permission, $!");
				}
			}
		}
	}
	else {
		# Get the current UID and GID of the file.
		my $myuid = $<;
				
		# only root can change files that are owned by others, 
		# you don't need to be root to set the group and perms IF you're the owner 
		# and if the target group is one you're a member of
		if ( $currentstatus->uid == $myuid ) {
			my $gid = getgrnam($C->{'nmis_group'});
	
			if ($currentstatus->gid != $gid)
			{
				dbg("setting group owner of $filename to $C->{nmis_group}",3);
				my $cnt = chown($myuid, $gid, $filename);
				if (not $cnt) {
					logMsg("ERROR, could not set the group of $filename to $C->{'nmis_group'}: $!");
				}
			}
			
			if ( -d $filename and $C->{'os_execperm'} ne "" ) {
				$permission = $C->{'os_execperm'} ;
			}
			elsif ( -f $filename and $filename =~ /$C->{'nmis_executable'}/ and $C->{'os_execperm'} ne "" ) {
				$permission = $C->{'os_execperm'} ;
			}
			elsif ( -f $filename and $C->{'os_fileperm'} ne "" ) {
				$permission = $C->{'os_fileperm'} ;
			}
			elsif ( -d $filename ) {	# Directory permission added by Till Dierkesmann
				$permission = "0770"; # Default for dirs
			}
			else {
				$permission = "0660"; # default
			}
			
			if (($currentstatus->mode & 07777) != oct($permission))
			{
				dbg("setting permissions of $filename to $permission",3);
				if (!chmod(oct($permission), $filename)) {
					logMsg("ERROR, could not change $filename permissions to $permission: $!");
				}
			}
		}
		else {
			dbg("INFO: $filename can not change unless root or you own it.",4);
		}
	}
}

### 2012-01-16 keiths, C_cache gets overwritten when using loadConfTable for multiple configs.
sub getDir {
	my %args = @_;
	my $dir = $args{dir};
	return $nmis_var if $dir eq 'var';
	return $nmis_models if $dir eq 'models';
	return $nmis_conf if $dir eq 'conf';
	return $nmis_logs if $dir eq 'logs';
	return $nmis_mibs if $dir eq 'mibs';
	#these will never fire!
	return $C_cache->{'<nmis_conf>'} if $dir eq 'conf';
	return $C_cache->{'<nmis_models>'} if $dir eq 'models';
	return $C_cache->{'<nmis_mibs>'} if $dir eq 'mibs';
	return $C_cache->{'<nmis_var>'} if $dir eq 'var';
	return $C_cache->{'<nmis_logs>'} if $dir eq 'logs';
}
	
sub existFile {
	my %args = @_;
	my $dir = $args{dir};
	my $name = $args{name};
	my $file;
	return if $dir eq '' or $name eq '';
	$file = getDir(dir=>$dir)."/$name";
	$file = getFileName(file => $file);
	return ( -r $file ) ;
}

# get modified time of file
### 2011-12-29 keiths, added test for file existing.
sub mtimeFile {
	my %args = @_;
	my $dir = $args{dir};
	my $name = $args{name};
	my $file;
	return if $dir eq '' or $name eq '';
	$file = getDir(dir=>$dir)."/$name";
	$file = getFileName(file => $file);
	if ( -r $file ) {
		return stat($file)->mtime;
	}
	else {
		return;
	}
}

### Cache system for hash tables/files reading from disk
#
#	loadTable(dir=>'xx',name=>'yy') returns pointer of table, if not in cache or file is updated then load from file
#	loadTable(dir=>'xx',name=>'yy',check=>'true') returns 1 if cache and file are valid else 0
#	loadTable(dir=>'xx',name=>'yy',mtime=>'true') returns pointer of table and mtime of file
#	loadTable(dir=>'xx',name=>'yy',lock=>'true') returns pointer of table and handle without caching
# extra argument: suppress_errors, if set loadTable will not log errors but just return
sub loadTable {
	my %args = @_;
	my $dir = lc $args{dir}; # name of directory
	my $name = $args{name};	# name of table or short file name
	my $check = getbool($args{check}); # if 'true' then check only if table is valid in cache
	my $mtime = getbool($args{mtime}); # if 'true' then mtime is also returned
	my $lock = getbool($args{lock}); # if lock is true then no caching

	my $C = loadConfTable();
	
	# return an empty structure if I can't do anything else.
	my $empty = { };
	
	if ($name ne '') {
		if ($dir =~ /conf|models|var/) {
			if (existFile(dir=>$dir,name=>$name)) {
				my $file = getDir(dir=>$dir)."/$name";
				$file = getFileName(file => $file);
				print STDERR "DEBUG loadTable: name=$name dir=$dir file=$file\n" if $confdebug;
				if ($lock) {
					return readFiletoHash(file=>$file,lock=>$lock);
				} else {
					# known dir
					my $index = lc "$dir$name";
					if (exists $Table_cache{$index}{data}) {
						# already in cache, check for update of file
						if (stat($file)->mtime eq $Table_cache{$index}{mtime}) {
							return 1 if ($check);
							# else
							return $Table_cache{$index}{data},$Table_cache{$index}{mtime} 
							if ($mtime); # oke
							# else
							return $Table_cache{$index}{data}; # oke
						}
					}
					return 0 if ($check); # cached data/table not valid
					# else
					# read from file
					$Table_cache{$index}{data} = readFiletoHash(file=>$file);
					$Table_cache{$index}{mtime} = stat($file)->mtime;
					return $Table_cache{$index}{data},$Table_cache{$index}{mtime} 
					if ($mtime); # oke
					# else
					return $Table_cache{$index}{data}; # oke
				}
			} else {
				### 2013-08-13 keiths, enhancement submitted by Mateusz Kwiatkowski <mateuszk870@gmail.com>
				logMsg("ERROR file does not exist or has bad permissions dir=$dir name=$name, nmis_var=$nmis_var nmis_conf=$nmis_conf") if (!$args{suppress_errors});
			}
		} else {
			logMsg("ERROR unknown dir=$dir specified with name=$name");
		}
	} else {
		logMsg("ERROR no name specified");
	}
	return $empty;
}

sub writeTable {
	my %args = @_;
	my $dir = lc $args{dir}; # name of directory
	my $name = $args{name};	# name of table or short file name

	my $C = loadConfTable();

	if ($name ne '') {
		if ($dir =~ /conf|models|var/) {
			my $file = getDir(dir=>$dir)."/$name";
			return writeHashtoFile(file=>$file,data=>$args{data},handle=>$args{handle});
		} else {
			logMsg("ERROR unknown dir=$dir specified with name=$name");
		}
	} else {
		logMsg("ERROR no name specified");
	}
	return;
}

# attention: this function name clashes with a function in rrdfunc.pm!
sub getFileName {
	my %args = @_;
	my $json = $args{json};
	my $file = $args{file};
	my $dir = $args{dir};

	my $check = $dir;
	$check = $file if $file ne "";
		
	if ( ( getbool($C_cache->{use_json}) or $json ) and ( $check =~ /\/var/ or $check eq "var" ))  {
		$file .= '.json' if $file !~ /\.json$/;
		$file =~ s/\.nmis//g;
	}
	else {
		$file .= ".nmis" if $file !~ /\.nmis/;
	}
	return $file;
}

sub getExtension {
	my %args = @_;
	my $json = $args{json};
	my $file = $args{file};
	my $dir = $args{dir};
	
	my $check = $dir;
	$check = $file if $file ne "";
	
	my $extension = "nmis";
	if ( (getbool($C_cache->{use_json}) or $json ) and ( $check eq "var" or $check =~ /\/var/ ) ) {
		$extension = "json";
	}
	return $extension;
}

### write hash to file using Data::Dumper
###
sub writeHashtoModel {
	my %args = @_;
	my $C = loadConfTable();
	return writeHashtoFile(file=>"$C->{'<nmis_models>'}/$args{name}",data=>$args{data},handle=>$args{handle});
}


sub writeHashtoFile {
	my %args = @_;
	my $file = $args{file};
	my $data = $args{data};
	my $handle = $args{handle}; # if handle specified then file is locked EX
	my $json = getbool($args{json});
	my $pretty = getbool($args{pretty});

	### 2013-11-29 keiths, adding support for JSON.
	my $useJson = ( (getbool($C_cache->{use_json}) or $json ) 
									and $file =~ /\/var/ ) ? 1 : 0;
	$file = getFileName(file => $file, json => $json);

	dbg("write data to $file");
	if ($handle eq "") {
		if (open($handle, "+<$file")) {
			flock($handle, LOCK_EX) or warn "ERROR writeHashtoFile, can't lock $file, $!\n";
			enter_critical;
			seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
			truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
		} else {
			open($handle, ">$file")  or warn "writeHashtoFile: ERROR cannot open $file: $!\n";
			flock($handle, LOCK_EX) or warn "writeHashtoFile: ERROR can't lock file $file, $!\n";
			leave_critical;
		}
	} else {
		enter_critical;
		seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
		truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
	}

	my $errormsg;
	# write out the data, but defer error logging until after the lock is released!
	if ( $useJson and ( getbool($C_cache->{use_json_pretty}) or $pretty) ) {
		if ( not print $handle JSON::XS->new->pretty(1)->encode($data) ) {
			$errormsg = "ERROR cannot write data object to file $file: $!";
		}
	}
	elsif ( $useJson ) {
		eval { print $handle encode_json($data) } ;
		if ( $@ ) {
			$errormsg = "ERROR cannot write data object to $file: $@";
		}
	}
	elsif ( not print $handle Data::Dumper->Dump([$data], [qw(*hash)]) ) {
		$errormsg = "ERROR cannot write to file $file: $!";
	}
	close $handle;
	leave_critical;

	# now it's safe to handle the error
	if ($errormsg)
	{
		logMsg($errormsg);
		info($errormsg);
	}

	setFileProt($file);

	# store updated filename in table with time stamp
	if (getbool($C_cache->{server_remote}) and $file !~ /nmis-files-modified/) {
		my ($F,$handle) = loadTable(dir=>'var',name=>'nmis-files-modified',lock=>'true');
		$F->{$file} = time();
		writeTable(dir=>'var',name=>'nmis-files-modified',data=>$F,handle=>$handle);
	}
}


### read file with lock containing data generated by Data::Dumper, option = lock
###
sub readFiletoHash {
	my %args = @_;
	my $file = $args{file};
	my $lock = getbool($args{lock}); # option
	my $json = getbool($args{json});
	my %hash;
	my $handle;
	my $line;
			
	### 2013-11-29 keiths, adding support for JSON.
	my $useJson = ( ( getbool($C_cache->{use_json}) or $json ) and $file =~ /\/var/ ) ? 1 : 0;
	$file = getFileName(file => $file, json => $json);
	
	if ( -r $file ) {
		my $filerw = $lock ? "+<$file" : "<$file";
		my $lck = $lock ? LOCK_EX : LOCK_SH;
		if (open($handle, "$filerw")) {
			flock($handle, $lck) or warn "ERROR readFiletoHash, can't lock $file, $!\n";     
			local $/ = undef;
			my $data = <$handle>;
			if ( $useJson ) {
				my $hashref; 
				eval { $hashref = decode_json($data); } ;
				if ( $@ ) {
					logMsg("ERROR convert $file to hash table, $@");
					info("ERROR convert $file to hash table, $@");
				}
				return ($hashref,$handle) if ($lock);
				# else
				close $handle;
				return $hashref;
			}
			else {
				# convert data to hash
				%hash = eval $data;
				if ($@) {
					logMsg("ERROR convert $file to hash table, $@");
					return;
				}
				return (\%hash,$handle) if ($lock);
				# else
				close $handle;
				return \%hash;
			}
		} else{
			logMsg("ERROR cannot open file=$file, $!");
		}
	} else {
		if ($lock) {
			# create new empty file
			open ($handle,">", "$file") or warn "ERROR readFiletoHash: can't create $file: $!\n";
			flock($handle, LOCK_EX) or warn "ERROR readFiletoHash: can't lock file $file, $!\n";
			return (\%hash,$handle)
		}
		logMsg("ERROR file=$file does not exist");
	}
	return;
}

# debug info with (class::)method names and line number
sub info {
	my $msg = shift;
	my $level = shift || 1;
	my $string;
	my $caller;

	if ($C_cache->{debug}) {
		my $upCall = (caller(1))[3];
		$upCall =~ s/main:://;
		dbg($msg,$level,$upCall);
	}
	else {
		if ($C_cache->{info} >= $level or $level == 0) {
			if ($level == 1) {
				($string = (caller(1))[3]) =~ s/\w+:://;
				$string .= ",";
			} else {
				if ((my $caller = (caller(1))[3]) =~ s/main:://) {
					my $ln = (caller(0))[2];
					print returnTime." $caller#$ln, $msg\n";
				} else {
					for my $i (1..10) {
						my ($caller) = (caller($i))[3];
						my ($ln) = (caller($i-1))[2];
						$string = "$caller#$ln->".$string;
						last if $string =~ s/main:://;
					}
					$string = "$string\n\t";
				}
			}
			print returnTime." $string $msg\n";
		}
	}
}

# debug info with (class::)method names and line number
sub dbg {
	my $msg = shift;
	my $level = shift || 1;
	my $upCall = shift || undef;
	my $string;
	my $caller;
	if ($C_cache->{debug} >= $level or $level == 0) {
		if ($level == 1) {
			if ( defined $upCall ) {
				$string = $upCall;
			}
			else {
				($string = (caller(1))[3]) =~ s/\w+:://;
			}
			$string .= ",";
		} else {
			if ((my $caller = (caller(1))[3]) =~ s/main:://) {
				my $ln = (caller(0))[2];
				print returnTime." $caller#$ln, $msg\n";
			} else {
				for my $i (1..10) {
					my ($caller) = (caller($i))[3];
					my ($ln) = (caller($i-1))[2];
					$string = "$caller#$ln->".$string;
					last if $string =~ s/main:://;
				}
				$string = "$string\n\t";
			}
		}
		print returnTime." $string $msg\n";
	}
}

# debug info with (class::)method names and line number
sub dbgPolling {
	my $msg = shift;
	my $level = shift || 1;
	my $string;
	my $caller;
	if ($C_cache->{debug_polling} >= $level or $level == 0) {
		if ($level == 1) {
			($string = (caller(1))[3]) =~ s/\w+:://;
			$string .= ",";
		} else {
			if ((my $caller = (caller(1))[3]) =~ s/main:://) {
				my $ln = (caller(0))[2];
				print returnTime." $caller#$ln, $msg\n";
			} else {
				for my $i (1..10) {
					my ($caller) = (caller($i))[3];
					my ($ln) = (caller($i-1))[2];
					$string = "$caller#$ln->".$string;
					last if $string =~ s/main:://;
				}
				$string = "$string\n\t";
			}
		}
		print returnTime." $string $msg\n";
	}
}

# do nothing..
sub htmlElementValues{};

#	my %args = @_;
#	my $element = $args{element};
#	my $value = $args{value};
#	my $script = $args{script};
#
#	if ($script ne '') {
#		push @htmlElements,$script;
#	} elsif ($element ne '') {
#		push @htmlElements,"document.getElementById(\"$element\").innerHTML=\"$value\"";
#	} else {
#		print "<script>\n";
#		print "setTime('".timegm(localtime())."');"; # get localtime and set clock in nmiscgi.pl
#		foreach (@htmlElements) {
#			print "$_ \n";
#		}
#		print "</script>";
#		@htmlElements = ();
#	}
#
#}


# message with (class::)method names and line number
sub logMsg {
	my $msg = shift;
	my $C = $C_cache; # local scalar
	my $handle;
	
	if ($C eq '') {
		# no config loaded
		die "FATAL logMsg, NO Config Loaded: $msg";
	}
	### 2012-01-25 keiths, updated so using better cache
	elsif ( not -f $nmis_log and not -d $nmis_logs ) {
		print "ERROR, logMsg can't do anything but NAG YOU\n";
		warn "ERROR logMsg: the message which killed me was: $msg\n";
		return undef;
	}

	if ($C->{debug} == 1) {
		my $string;
		($string = (caller(1))[3]) =~ s/\w+:://;
		print returnTime." $string, $msg\n";
	} else {
		dbg($msg); # 
	}

	my ($string,$caller,$ln,$fn);
	for my $i (1..10) {
		($caller) = (caller($i))[3];	# name sub
		($ln) = (caller($i-1))[2];	# linenumber
		$string = "$caller#$ln".$string;
		if ($caller =~ /main/ or $caller eq '') {
			($fn) = (caller($i-1))[1];	# filename
			$fn =~ s;.*/(.*\.\w+)$;$1; ; # strip directory
			$string =~ s/main|//;
			$string = "$fn".$string;
			last;
		}
	}

	$string .= "<br>$msg";
	$string =~ s/\n/ /g;      #remove all embedded newlines

	open($handle,">>$nmis_log") or warn returnTime." logMsg, Couldn't open log file $nmis_log. $!\n";
	flock($handle, LOCK_EX)  or warn "logMsg, can't lock filename: $!";
	print $handle returnDateStamp().",$string\n" or warn returnTime." logMsg, can't write file $nmis_log. $!\n";
	close $handle or warn "logMsg, can't close filename: $!";
	setFileProt($nmis_log);
}

my %loglevels = ( "EMERG"=>0,"ALERT"=>1,"CRITICAL"=>2,"ERROR"=>3,"WARNING"=>4,"NOTICE"=>5,"INFO"=>6,"DEBUG"=>7);
my $maxlevel = 7; # TODO: Put this in config file.

#-----------------------------------
# logAuth2(message,level)
# message: message text
# level: [0..7] or string in [EMERG,ALERT,CRITICAL,ERROR,WARNING,NOTICE,INFO,DEBUG]
# if level < 0, use 0;
# if level > 7 or any string not in the group, use 7
# case insensitive
# arbitrary strings can be used (only at debug level)
# Only messages below $maxlevel are printed

sub logAuth2($;$) {
	my $msg = shift;
	my $level = shift || 3; # default: ERROR

	$level = $loglevels{uc $level} if exists $loglevels{uc $level};

	my $levelmsg;
	if( $level !~ /^[0-7]$/ ) {
		$levelmsg = $level;
		$level = 7;
	} else {
		$level = 0 if $level < 0;
		$level = 7 if $level > 7;

		$levelmsg = (keys %loglevels)[$level];
	}

	#logAuth("$levelmsg: $msg") if $level <= $maxlevel;

	my $C = $C_cache;

	if ($C eq '') { die "FATAL logAuth, NO Config Loaded: $msg"; }
	elsif ( not -f $C->{auth_log} and not -d $C->{'<nmis_logs>'} ) {
		print "ERROR, logAuth can't do anything but NAG YOU\n";
		warn "ERROR logAuth: the message which killed me was: $msg\n";
		return undef;
	}

	dbg($msg);
	my ($string,$caller,$ln,$fn);
	for my $i (1..10) {
		($caller) = (caller($i))[3]; # name sub
		($ln) = (caller($i-1))[2];  # line number
		$string = "$caller#$ln".$string;
		if ($caller =~ /main/ or $caller eq '') {
			($fn) = (caller($i-1))[1]; # file name
			$fn =~ s|.*/(.*\.\w+)$|$1| ; # strip directory (basename???)
			$string =~ s/main|//;
			$string = "$fn".$string;
			last;
		}
	}
	$string .= "<br>$msg";
	$string =~ s/\n/ /g;      #remove all embedded newlines

	my $handle;
	open($handle,">>$C->{auth_log}") or warn returnTime." logAuth, Couldn't open log file $C->{auth_log}. $!\n";
	flock($handle, LOCK_EX)  or warn "logAuth, can't lock filename: $!";
	print $handle returnDateStamp().",$string\n" or warn returnTime." logAuth, can't write file $C->{auth_log}. $!\n";
	close $handle or warn "logAuth, can't close filename: $!";
	setFileProt($C->{auth_log});
}

# message with (class::)method names and line number
sub logAuth {
	my $msg = shift;
	my $C = $C_cache; # local scalar
	my $handle;

	if ($C eq '') {
		# no config loaded
		die "FATAL logAuth, NO Config Loaded: $msg";
	}
	elsif ( not -f $C->{auth_log} and not -d $C->{'<nmis_logs>'} ) {
		print "ERROR, logAuth can't do anything but NAG YOU\n";
		warn "ERROR logAuth: the message which killed me was: $msg\n";
		return undef;
	}

	if ($C->{debug} == 1) {
		my $string;
		($string = (caller(1))[3]) =~ s/\w+:://;
		print STDERR returnTime." $string, $msg\n";
	} else {
		dbg($msg); # 
	}

	my ($string,$caller,$ln,$fn);
	for my $i (1..10) {
		($caller) = (caller($i))[3];	# name sub
		($ln) = (caller($i-1))[2];	# linenumber
		$string = "$caller#$ln".$string;
		if ($caller =~ /main/ or $caller eq '') {
			($fn) = (caller($i-1))[1];	# filename
			$fn =~ s;.*/(.*\.\w+)$;$1; ; # strip directory
			$string =~ s/main|//;
			$string = "$fn".$string;
			last;
		}
	}

	$string .= "<br>$msg";
	$string =~ s/\n/ /g;      #remove all embedded newlines

	open($handle,">>$C->{auth_log}") or warn returnTime." logAuth, Couldn't open log file $C->{auth_log}. $!\n";
	flock($handle, LOCK_EX)  or warn "logAuth, can't lock filename: $!";
	print $handle returnDateStamp().",$string\n" or warn returnTime." logAuth, can't write file $C->{auth_log}. $!\n";
	close $handle or warn "logAuth, can't close filename: $!";
	setFileProt($C->{auth_log});
}

# message with (class::)method names and line number
sub logIpsla {
	my $msg = shift;
	my $C = $C_cache; # local scalar
	my $handle;

	if ($C eq '') {
		# no config loaded
		die "FATAL logIpsla, NO Config Loaded: $msg";
	}
	elsif ( not -f $C->{ipsla_log} and not -d $C->{'<nmis_logs>'} ) {
		print "ERROR, logIpsla can't do anything but NAG YOU\n";
		warn "ERROR logIpsla: the message which might have killed me was: $msg\n";
		return undef;
	}

	if ($C->{debug} == 1) {
		my $string;
		($string = (caller(1))[3]) =~ s/\w+:://;
		print returnTime." $string, $msg\n";
	} else {
		dbg($msg); # 
	}

	my $PID = $$;
	my $sep = "::";
	my ($string,$caller,$ln,$fn);
	for my $i (1..10) {
		($caller) = (caller($i))[3];	# name sub
		($ln) = (caller($i-1))[2];	# linenumber
		$string = "$sep$PID$sep$caller#$ln".$string;
		if ($caller =~ /main/ or $caller eq '') {
			($fn) = (caller($i-1))[1];	# filename
			$fn =~ s;.*/(.*\.\w+)$;$1; ; # strip directory
			$string =~ s/main|//;
			$string = "$fn".$string;
			last;
		}
	}

	$string .= "<br>$msg";
	$string =~ s/\n/ /g;      #remove all embedded newlines

	open($handle,">>$C->{ipsla_log}") or warn returnTime." logIpsla, Couldn't open log file $C->{ipsla_log}. $!\n";
	flock($handle, LOCK_EX)  or warn "logIpsla, can't lock filename: $!";
	print $handle returnDateStamp().",$string\n" or warn returnTime." logIpsla, can't write file $C->{ipsla_log}. $!\n";
	close $handle or warn "logIpsla, can't close filename: $!";
	setFileProt($C->{ipsla_log});
}

sub logPolling {
	my $msg = shift;
	my $C = $C_cache; # local scalar
	my $handle;
	
	#To enable polling log a file must be configured in Config.nmis and the file must exist.
	if ( $C->{polling_log} ne "" and -f $C->{polling_log} ) {
		if ($C eq '') {
			# no config loaded
			die "FATAL logPolling, NO Config Loaded: $msg";
		}
		elsif ( not -f $C->{polling_log} and not -d $C->{'<nmis_logs>'} ) {
			print "ERROR, logPolling can't do anything but NAG YOU\n";
			warn "ERROR logPolling: the message which killed me was: $msg\n";
		}
	
		open($handle,">>$C->{polling_log}") or warn returnTime." logPolling, Couldn't open log file $C->{polling_log}. $!\n";
		flock($handle, LOCK_EX)  or warn "logPolling, can't lock filename: $!";
		print $handle returnDateStamp().",$msg\n" or warn returnTime." logPolling, can't write file $C->{polling_log}. $!\n";
		close $handle or warn "logPolling, can't close filename: $!";
		setFileProt($C->{polling_log});
	}
}

### a utility for development, just log whatever I want to the file I want.
sub logDebug {
	my $file = shift;
	my $output = shift;
	my $C = $C_cache; # local scalar
	my $fileOK = 1;
	my $handle;
	
	if ( -f $file and not -w $file ) {
		logMsg "ERROR, logDebug can not write file $file\n";
		$fileOK = 0;
	}
	elsif ( -d $file ) {
		logMsg "ERROR, logDebug $file is a directory\n";
		$fileOK = 0;
	}

	if ( $fileOK ) {
		open($handle,">>$file") or warn returnTime." logDebug, Couldn't open log file $file. $!\n";
		flock($handle, LOCK_EX)  or warn "logDebug, can't lock filename: $!";
		print $handle returnDateStamp().",$output\n" or warn returnTime." logDebug, can't write file $file. $!\n";
		close $handle or warn "logDebug, can't close filename: $!";
		setFileProt($file);
	}
}

# normal op: compares first argument against true or 1 or yes
# opposite: compares first argument against false or 0 or no
#
# this opposite stuff is needed for handling "XX ne false", 
# which is 1 if XX is undef and thus not the same as !getbool(XX,0) 
#
# usage: eq true => getbool, ne true => !getbool,
# eq false => getbool(...,invert), ne false => !getbool(...,invert)
#
# returns: 0 if arg is undef or non-matching, 1 if matches thingy
sub getbool
{
	my ($val,$opposite) = @_;
	if (!$opposite)
	{
		return (defined $val and $val =~ /^[yt1]/i)? 1 : 0;
	}
	else
	{
		return (defined $val and $val =~ /^[nf0]/i)? 1 : 0;
	}
}

### 2011-12-07 keiths, adding support for specifying the directory.
sub getConfFileName {
	my %args = @_;
	my $conf = $args{conf};
	my $dir = $args{dir};

	# See if customised config file required.
	my $configfile = "$FindBin::Bin/../conf/$conf";
	
	my $altconf = getFileName(file => "/etc/nmis/$conf"); 
	
	if ( $dir ) {
		$configfile = "$dir/$conf"; 
	}
	
	$configfile = getFileName(file => $configfile);
	
	if (not -r $configfile ) {
		# the following should be conformant to Linux FHS
		if ( -e $altconf ) {
			$configfile = $altconf;
		} else { 
			if ( $ENV{SCRIPT_NAME} ne "" ) {
				print header();
				print start_html(
					-title => "NMIS Network Management Information System",
					-meta => { 'CacheControl' => "no-cache",
						'Pragma' => "no-cache",
						'Expires' => -1 
					});
			}
			
			print "Can't access neither NMIS configuration file=$configfile, nor $altconf \n";
			
			if ( $ENV{SCRIPT_NAME} ne "" ) {
				print end_html;
			}
			
			return;
		}
	}
	print STDERR "DEBUG getConfFileName: configfile=$configfile\n" if $confdebug;
	return $configfile;
}

sub readConfData {
	my %args = @_;
	my $conf = $args{conf} || 'Config';
	my $configfile;
	my $CC;

	if (($configfile=getConfFileName(conf=>$conf))) {
		$CC = readFiletoHash(file=>$configfile);
		return $CC,$configfile;
	}
	return;
}

### 2011-12-07 keiths, adding support for specifying the directory.
sub loadConfTable {
	my %args = @_;
	my $conf = $args{conf};
	my $dir = $args{dir};
	my $debug = $args{debug} || 0;
	my $info = $args{info} || 0;
	my $name;
	my $value;
	my $key;
	my $modtime;
	my $configfile;
	my $CC;

	#Ensure always using the same config from the first time we were called.
	if ( $conf ne "" and $Config_cache eq "" ) {
		$Config_cache = $conf;
	}
	elsif ( $conf eq "" and $Config_cache ne "") {
		$conf = $Config_cache;
	}
	elsif ( $conf eq "" ) {
		$conf = 'Config';
	}

	# on start of program parameters are defined
	return $C_cache if defined $C_cache and scalar @_ == 0;

	# add extension if missing
	$conf = $conf =~ /\./ ? $conf : "${conf}";
	
	if (($configfile=getConfFileName(conf=>$conf, dir=>$dir))) {

		# check if config file is updated, if not, use file cache
		if ($Table_cache{$conf}{mtime} ne '' and $Table_cache{$conf}{mtime} eq stat($configfile)->mtime) {
			$C_cache = $Table_cache{$conf};
			return $C_cache;
		}

		# read fresh config file
		if ($CC = readFiletoHash(file=>$configfile)) {
			# create new table
			delete $Table_cache{$conf};
			# convert to single level
			for my $k (keys %{$CC}) {
				for my $kk (keys %{$CC->{$k}}) {
					$Table_cache{$conf}{$kk} = $CC->{$k}{$kk};
				}
			}
	
			# check for config variables and process each config element again.
			foreach $key (keys %{$Table_cache{$conf}}) {
				if ( $key =~ /^<.*>$/ ) {
					dbg("Found a key to change $key",4);
					foreach $value (keys %{$Table_cache{$conf}}) {
						if ( $Table_cache{$conf}{$value} =~ /<.*>/ ) {
							dbg("about to change $value to $Table_cache{$conf}{$value}, $key, $Table_cache{$conf}{$key}",4);
							$Table_cache{$conf}{$value} =~ s/$key/$Table_cache{$conf}{$key}/;
						}
					}
				}
			}
			$Table_cache{$conf}{debug} = setDebug($debug); # include debug setting in conf table
			$Table_cache{$conf}{info} = setDebug($info); # include debug setting in conf table
			$Table_cache{$conf}{conf} = $conf;
			$Table_cache{$conf}{configfile} = $configfile;
			$Table_cache{$conf}{configfile_name} = substr($configfile, rindex($configfile, "/")+1);
			$Table_cache{$conf}{auth_require} = (getbool($Table_cache{$conf}{auth_require},"invert")) ? 0 : 1; # default true in Auth
			$Table_cache{$conf}{starttime} = time();

			$Table_cache{$conf}{mtime} = stat($configfile)->mtime; # remember modified time
	
			$Table_cache{$conf}{server} = $Table_cache{$conf}{server_name};
	
			$C_cache = $Table_cache{$conf};
			
			### 2012-04-16 keiths, only update if not null
			$nmis_conf = $Table_cache{$conf}{'<nmis_conf>'} if $Table_cache{$conf}{'<nmis_conf>'};
			$nmis_var = $Table_cache{$conf}{'<nmis_var>'} if $Table_cache{$conf}{'<nmis_var>'};
			$nmis_models = $Table_cache{$conf}{'<nmis_models>'} if $Table_cache{$conf}{'<nmis_models>'};
			$nmis_logs = $Table_cache{$conf}{'<nmis_logs>'} if $Table_cache{$conf}{'<nmis_logs>'};
			$nmis_log = $Table_cache{$conf}{'nmis_log'} if $Table_cache{$conf}{'nmis_log'};
			$nmis_mibs = $Table_cache{$conf}{'<nmis_mibs>'} if $Table_cache{$conf}{'<nmis_mibs>'};
	
			return $C_cache;
		}
	}
	return; # failed
}

sub writeConfData {
	my %args = @_;
	my $CC = $args{data};

	my $C = loadConfTable();
	my $configfile = $C->{configfile};

	if (-r "$configfile") {
		rename "$configfile","$configfile.bak"; # save old one
	}
	if (getbool($CC->{system}{xml_config})) {
		XMLout($CC,OutputFile=>$configfile,XMLDecl=>1);
		setFileProt($configfile);
	} else {
		writeHashtoFile(file=>$configfile,data=>$CC);
	}
}

sub getKernelName {

	my $C = loadConfTable();

	# Find the kernel name
	my $kernel;
	if (defined $C->{os_kernelname}) {
		$kernel = $C->{os_kernelname};
	} elsif ( $^O !~ /linux/i) {
		$kernel = $^O;
	} else {
		$kernel = `uname -s`;
	}
	chomp $kernel; $kernel = lc $kernel;
	return $kernel;
}

sub createDir {
	my $dir = shift;
	my $C = loadConfTable();
	if ( not -d $dir ) {
		my $permission = "0770"; # default
		if ( $C->{'os_execperm'} ne "" ) {
			$permission = $C->{'os_execperm'} ;
		} 

		my $umask = umask(0);
		mkpath($dir,{verbose => 0, mode => oct($permission)});
		umask($umask);
	}
}

sub checkDir {
	my $dir = shift;
	my $result = 1;
	my @messages;

	my $C = loadConfTable();
	
	# Does the directory exist
	if ( not -d $dir ) {
		$result = 0;
		push(@messages,"ERROR: directory $dir does not exist");
	}
	else {
    #2 mode     file mode  (type and permissions)
    #4 uid      numeric user ID of file's owner
  	#5 gid      numeric group ID of file's owner
		my $dstat = stat($dir);
		my $gid = $dstat->gid;
		my $uid = $dstat->uid;
		my $mode = $dstat->mode;
		
		my ($groupname,$passwd,$gid2,$members) = getgrgid $gid;
		my $username = getpwuid($uid);
		
		#print "DEBUG: dir=$dir username=$username groupname=$groupname uid=$uid gid=$gid mode=$mode\n";

		# Are the user and group permissions correct.
		my $user_rwx = ($mode & S_IRWXU) >> 6;
    my $group_rwx = ($mode & S_IRWXG) >> 3;

		if ( $user_rwx ) {
			push(@messages,"INFO: $dir has user read-write-execute permissions") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $dir does not have user read-write-execute permissions");			
		}

		if ( $group_rwx ) {
			push(@messages,"INFO: $dir has group read-write-execute permissions") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $dir does not have group read-write-execute permissions");			
		}
		
		if ( $C->{'nmis_user'} eq $username ) {
			push(@messages,"INFO: $dir has correct owner from config nmis_user=$username") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $dir DOES NOT have correct owner from config nmis_user=$C->{'nmis_user'} dir=$username");			
		}

		if ( $C->{'os_username'} eq $username ) {
			push(@messages,"INFO: $dir has correct owner from config os_username=$username") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $dir DOES NOT have correct owner from config os_username=$C->{'os_username'} dir=$username");			
		}

		if ( $C->{'nmis_group'} eq $groupname ) {
			push(@messages,"INFO: $dir has correct owner from config nmis_group=$groupname") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $dir DOES NOT have correct owner from config nmis_group=$C->{'nmis_group'} dir=$groupname");			
		}		
	}
		
	if (not $result) {
		my $message = join("\n",@messages);
		print "Problem with $dir:\n$message\n";
	}

	my $message = join(";;",@messages);
	return($result,$message);
}

sub checkFile {
	my $file = shift;
	my $result = 1;
	my @messages;

	my $C = loadConfTable();
	
	# Does the directory exist
	if ( not -f $file ) {
		$result = 0;
		push(@messages,"ERROR: file $file does not exist");
	}
	else {
    #2 mode     file mode  (type and permissions)
    #4 uid      numeric user ID of file's owner
  	#5 gid      numeric group ID of file's owner
		my $fstat = stat($file);
		my $gid = $fstat->gid;
		my $uid = $fstat->uid;
		my $mode = $fstat->mode;
		my ($groupname,$passwd,$gid2,$members) = getgrgid $gid;
		my $username = getpwuid($uid);
		
		if ( $fstat->size > $C->{'file_size_warning'} and $C->{'file_size_warning'} ne "" and $C->{'file_size_warning'} > 0 ) {
			$result = 0;
			my $size = $fstat->size;
			push(@messages,"WARN: $file is $size bytes, larger than $C->{'file_size_warning'} bytes");			
		}

		#S_IRWXU S_IRUSR S_IWUSR S_IXUSR
    #S_IRWXG S_IRGRP S_IWGRP S_IXGRP
    #S_IRWXO S_IROTH S_IWOTH S_IXOTH
		
		# Are the user and group permissions correct.    
    # are the files executable or non-executable    
    if (! defined $C->{'nmis_executable'}) { #Added by Till Dierkesmann
        $C->{'nmis_executable'} = '\.pl$|\.sh$';
        dbg("nmis_executable set to \"$C->{'nmis_executable'}\"",1);
    }
    
    if ( $file =~ /$C->{'nmis_executable'}/ ) {
			my $user_rwx = ($mode & S_IRWXU) >> 6;
	    my $group_rwx = ($mode & S_IRWXG) >> 3;
	    my $other_rwx = ($mode & S_IRWXO);
	    
			if ( $user_rwx ) {
				push(@messages,"INFO: $file has user read-write-execute permissions") if $C->{debug};			
			}
			else {
				$result = 0;
				push(@messages,"ERROR: $file does not have user read-write-execute permissions");			
			}
	
			if ( $group_rwx ) {
				push(@messages,"INFO: $file has group read-write-execute permissions") if $C->{debug};			
			}
			else {
				$result = 0;
				push(@messages,"ERROR: $file does not have group read-write-execute permissions");			
			}

			if ( $other_rwx ) {
				$result = 0;
				push(@messages,"WARN: $file has other read-write-execute permissions");			
			}
		}
		else {
			my $user_r  = ($mode & S_IRUSR) >> 6;
	    my $group_r = ($mode & S_IRGRP) >> 3;
	    my $other_r = ($mode & S_IROTH);
			my $user_w  = ($mode & S_IWUSR) >> 6;
	    my $group_w = ($mode & S_IWGRP) >> 3;
	    my $other_w = ($mode & S_IWOTH);

			if ( $user_r and $user_w ) {
				push(@messages,"INFO: $file has user read-write permissions") if $C->{debug};
			}
			else {
				$result = 0;
				push(@messages,"ERROR: $file does not have user read-write permissions");			
			}
	
			if ( $group_r and $group_w ) {
				push(@messages,"INFO: $file has group read-write permissions") if $C->{debug};			
			}
			else {
				$result = 0;
				push(@messages,"ERROR: $file does not have group read-write permissions");			
			}			

			if ( $other_r ) {
				$result = 0;
				push(@messages,"WARN: $file has other read permissions");			
			}
			if ( $other_w ) {
				$result = 0;
				push(@messages,"WARN: $file has other write permissions");			
			}
		}

		if ( $C->{'nmis_user'} eq $username ) {
			push(@messages,"INFO: $file has correct owner from config nmis_user=$username") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $file DOES NOT have correct owner from config nmis_user=$C->{'nmis_user'} dir=$username");			
		}

		if ( $C->{'os_username'} eq $username ) {
			push(@messages,"INFO: $file has correct owner from config os_username=$username") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $file DOES NOT have correct owner from config os_username=$C->{'os_username'} dir=$username");			
		}

		if ( $C->{'nmis_group'} eq $groupname ) {
			push(@messages,"INFO: $file has correct owner from config nmis_group=$groupname") if $C->{debug};			
		}
		else {
			$result = 0;
			push(@messages,"ERROR: $file DOES NOT have correct owner from config nmis_group=$C->{'nmis_group'} dir=$groupname");			
		}		
	}
		
	if (not $result) {
		my $message = join("\n",@messages);
		print "Problem with $file:\n$message\n";
	}

	my $message = join(";;",@messages);
	return($result,$message);
}

sub checkDirectoryFiles {
	my $dir = shift;
	opendir (DIR, "$dir");
	my @dirlist = readdir DIR;
	closedir DIR;
	
	foreach my $file (@dirlist) {
		if ( -f "$dir/$file" and $file !~ /^\./ ) {
			checkFile("$dir/$file");
		}
	}
}

# checks and adjusts the ownership and permissions on given dir X
# and all files directly within it. if recurse is given, then
# subdirs below X are also checked recursively.
sub setFileProtDirectory {
	my $dir = shift;
	my $recurse = shift;
	
	if ( $recurse eq "" ) {
		$recurse = 0;
	}
	else {
		$recurse = getbool($recurse);
	}
	
	dbg("setFileProtDirectory $dir, recurse=$recurse",1);

	setFileProt($dir);						# the dir itself must be checked and fixed, too!
	opendir (DIR, "$dir");
	my @dirlist = readdir DIR;
	closedir DIR;
	
	foreach my $file (@dirlist) {
		if ( -f "$dir/$file" and $file !~ /^\./ ) {
			setFileProt("$dir/$file");
		}
		elsif ( -d "$dir/$file" and $recurse and $file !~ /^\./ ) {
			setFileProt("$dir/$file");
			setFileProtDirectory("$dir/$file",$recurse);
		}
	}
}

# 100 = red, 0 = green
# red: rgb(255,0,0)
# green: rgb(0,255,0)
# blue: rgb(0,0,255)
# yellow: rgb(255,255,0)
# white: rgb(255,255,255)
#
# rgb(255,0,0) > rgb(255,255,0) > rgb(0,255,0)
#

sub hexval  {
	return sprintf("%2.2X", shift);
}

### 2012-09-21 keiths, fixing up so NAN is not black.	
sub colorPercentHi {
	use List::Util qw[min max];
	my $val = shift;
	if ( $val =~ /^(\d+|\d+\.\d+)$/ ) {
		$val = 100 - int($val);
		return '#' . hexval( int(min($val*2*2.55,255)) ) . hexval( int(min( (100-$val)*2*2.55,255)) ) .'00' ;
	}
	else {
		return '#AAAAAA';
	}
}

### 2012-09-21 keiths, fixing up so NAN is not black.	
sub colorPercentLo {
	use List::Util qw[min max];
	my $val = shift;
	if ( $val =~ /^(\d+|\d+\.\d+)$/ ) {
		$val = int($val);
		return '#' . hexval( int(min($val*2*2.55,255)) ) . hexval( int(min( (100-$val)*2*2.55,255)) ) .'00' ;
	}
	else {
		return '#AAAAAA';
	}
}

sub colorResponseTime {
	my $val = int(shift);
	my $thresh = shift;
	$thresh = 750 if not $thresh;
	my $ratio = 255/($thresh/255);
	
	return "#FF0000" if $val > $thresh;
	return "#AAAAAA" if $val !~ /[0-9]+/;
	return '#' . hexval( int((($val/255)*$ratio))) . hexval( int((($thresh-$val)/255)*$ratio )) .'00' ;
}

sub checkPerlLib {
	my $lib = shift;
	my $found = 0;
	
	my $path = $lib;
	$path =~ s/\:\:/\//g;
	
	if ( $path !~ /\.pm/ ) {
		$path .= ".pm";
	}
	
	#check the USE path for the file.
	foreach my $libdir (@INC) {
		if ( -f "$libdir/$path" ) {
			$found = 1;
			last;
		}	
	}
	
	return $found;
}


# a quick selftest function to verify that the runtime environment is ok
# function name not exported, on purpose
# args: an nmis config structure (needed for the paths),
# and delay_is_ok (= whether iostat and cpu computation are allowed to delay for a few seconds, default: no),
# optional dbdir_status (=ref to scalar, set to 1 if db dir space tests are ok, 0 otherwise)
# returns: (all_ok, arrayref of array of test_name => error message or undef if ok)
sub selftest
{
	my (%args) = @_;
	my ($allok, @details);
	
	my $config = $args{config};
	return (0,{ "Config missing" =>  "cannot perform selftest without configuration!"}) 
			if (ref($config) ne "HASH" or !keys %$config);
	my $candelay = getbool($args{delay_is_ok});

	my $dbdir_status = $args{report_database_status};
	$$dbdir_status = 1 if (ref($dbdir_status) eq "SCALAR"); # assume the database dir passes the test

	$allok=1;

	# check that we have a new enough RRDs module
	my $minversion=version->parse("1.4004");
	my $testname="RRDs Module";
	my $curversion;
	eval { 
		require RRDs;
		$curversion = version->parse($RRDs::VERSION);
	};
	if ($@)
	{
		push @details, [$testname, "RRDs Module not present!"];
		$allok=0;
	}
	elsif ($curversion < $minversion)
	{
		push @details, [$testname, "RRDs Version $curversion is below required min $minversion!"];
		$allok=0;
	}
	else
	{
		push @details, [$testname, undef];
	}
	
	# verify that nmis isn't disabled altogether
	$testname = "NMIS enabled";
	my $result = undef;
	my $lockoutfile = $config->{'<nmis_conf>'}."/NMIS_IS_LOCKED";
	if (-f $lockoutfile)
	{
		$result = "NMIS is disabled! Remove the file $lockoutfile to re-enable.";
	}
	elsif (getbool($config->{global_collect},"invert"))
	{
		$result = "NMIS is disabled! Set the configuration variable \"global_collect\" to \"true\" to re-enable.";
	}
	push @details, [$testname, $result];
	$allok = 0 if ($result);

	# check the main/involved directories AND /tmp and /var
	my $minfreepercent = $config->{selftest_min_diskfree_percent} || 10;
	my $minfreemegs = $config->{selftest_min_diskfree_mb} || 25;
	for my $dir ("/tmp","/var",
							 @{$config}{'<nmis_base>','<nmis_var>',
													'<nmis_logs>','database_root'})
	{
		next if (!-d $dir);
		my $testname = "Free space in $dir";

		my @df = `df -mP $dir 2>/dev/null`;
		if ($? >> 8)
		{
			push @details, [$testname, "Could not determine free space: $!"];
			$allok=0;
			$$dbdir_status = undef if (ref($dbdir_status) eq "SCALAR" and $dir eq $config->{"database_root"});
			next;
		}
		# Filesystem       1048576-blocks  Used Available Capacity Mounted on
		my (undef,undef,undef,$remaining,$usedpercent,undef) = split(/\s+/,$df[1]);
		$usedpercent =~ s/%$//;
		if (100-$usedpercent < $minfreepercent)
		{
			push @details, [$testname, "Only ".(100-$usedpercent)."% available!"];
			$$dbdir_status = 0 if (ref($dbdir_status) eq "SCALAR" and $dir eq $config->{"database_root"});
			$allok=0;
		}
		elsif ($remaining < $minfreemegs)
		{
			push @details, [$testname, "Only $remaining Megabytes available!"];
			$$dbdir_status = 0 if (ref($dbdir_status) eq "SCALAR" and $dir eq $config->{"database_root"});
			$allok=0;
		}
		else
		{
			push @details, [$testname, undef];
		}
	}

	# check the number of nmis processes, complain if above limit
	my $nr_procs = keys %{&find_nmis_processes(config => $config)}; # does not count this process
	my $max_nmis_processes = $config->{selftest_max_nmis_procs} || 50;
	my $status;
	if ($nr_procs > $max_nmis_processes)
	{
		$status = "Too many NMIS processes running: current count $nr_procs";
		$allok=0;
	}
	push @details, ["NMIS process count",$status];
	
	# check that there is some sort of cron running, ditto for fpingd (if enabled)
	my $cron_name = $config->{selftest_cron_name}? qr/$config->{selftest_cron_name}/ : qr!(^|/)crond?$!;
	my $ptable = Proc::ProcessTable->new(enable_ttys => 0);
	my ($cron_found, $fpingd_found, $cron_status, $fpingd_status);
	for my $pentry (@{$ptable->table})
	{
		if ($pentry->fname =~ $cron_name)
		{
			$cron_found=1;
			last if ($cron_found && $fpingd_found);
		}
		# fpingd is identifyable only by cmdline
		elsif (getbool($config->{daemon_fping_active}) 
					 && $pentry->cmndline =~ $config->{daemon_fping_filename})
		{
			$fpingd_found=1;
			last if ($cron_found && $fpingd_found);
		}
	}
	if (!$cron_found)
	{
		$cron_status = "No CRON daemon seems to be running!";
		$allok=0;
	}
	push @details, ["CRON daemon",$cron_status];

	if ($config->{daemon_fping_active} && !$fpingd_found)
	{
		$fpingd_status = "No ".$config->{daemon_fping_filename}." daemon seems to be running!";
		$allok=0;
	}
	push @details, ["FastPing daemon", $fpingd_status];
	
	# check iowait and general busyness of the system
	# however, do that ONLY if we are allowed to delay for a few seconds
	# (otherwise we get only the avg since boot!)
	if ($candelay)
	{
		my (@total, @busy, @iowait);
		for my $run (0,1)
		{
			open(F,"/proc/stat") or die "cannot read /proc/stat: $!\n";
			for my $line (<F>)
			{
				my ($name,@info) = split(/\s+/, $line);
				# cpu user nice system idle iowait irq softirq steal guest guestnice
				if ($name eq "cpu")
				{
					my $total = $info[0] + $info[1] + $info[2] + $info[3] + $info[4] 
							+ $info[5] + $info[6] + $info[7] + $info[8] + $info[9];
					# cpu util = sum of everything but idle, iowait is separate
					push @total, $total;
					push @busy, $total-$info[3];
					push @iowait, $info[4];
					last;
				}
			}
			close(F);
			sleep(5) if (!$run);			# get the cpu and io load over a few seconds
		}
		
		my $total_delta = $total[1] - $total[0];
		my $busy_delta = $busy[1] - $busy[0];
		my $iowait_delta = $iowait[1] - $iowait[0];

		my ($busy_ratio, $iowait_ratio, $busy_status, $iowait_status);
		$busy_ratio = $busy_delta / $total_delta;
		$iowait_ratio = $iowait_delta / $total_delta;

		my $max_cpu = $config->{selftest_max_system_cpu} || 50;
		my $max_iowait = $config->{selftest_max_system_iowait} || 10;
		if ($busy_ratio * 100 > $max_cpu)
		{
			$busy_status = sprintf("CPU load %.2f%% is above threshold %.2f%%", 
														 $busy_ratio*100, $max_cpu);
			$allok=0;
		}
		if ($iowait_ratio * 100 > $max_iowait)
		{
			$iowait_status = sprintf("I/O load %.2f%% is above threshold %.2f%%", 
															 $iowait_ratio*100, 
															 $max_iowait);
			$allok=0;
		}
		push @details, ["Server Load", $busy_status], ["Server I/O Load", $iowait_status];
	}

	# check the swap status, more than 50% is a bad sign
	my $max_swap = $config->{selftest_max_swap} || 50;
	open(F,"/proc/meminfo") or die "cannot read /proc/meminfo: $!\n";
	my ($swaptotal, $swapfree, $swapstatus);
	for my $line (<F>)
	{
		if ($line =~ /^Swap(Total|Free):\s*(\d+)\s+(\S+)\s*$/)
		{
			my ($name,$value,$unit) = ($1,$2,$3);
			$value *= 1024 if ($unit eq "kB");
			($name eq "Total"? $swaptotal : $swapfree ) = $value;
		}
	}
	close(F);
	my $swapused = $swaptotal - $swapfree;
	if ($swaptotal && 100*$swapused/$swaptotal > $max_swap)
	{
		$swapstatus = sprintf("Swap memory use %.2f%% is above threshold %.2f%%",
													$swapused/$swaptotal * 100, $max_swap);
		$allok=0;
	}
	push @details, ["Server Swap Memory", $swapstatus];

	# check the last successful operation completion, see if it was too long ago
	my $max_update_age = $config->{selftest_max_update_age} || 604800;
	my $max_collect_age = $config->{selftest_max_collect_age} || 900;
	# having this hardcoded twice isn't great...
	my $oplogdir = $config->{'<nmis_var>'}."/nmis_system/timestamps";
	if (-d $oplogdir)
	{
		opendir(D, $oplogdir) or die "cannot open dir $oplogdir: $!\n";
		# last _successful_ op
		my ($last_update_start,$last_update_end, $last_collect_start, $last_collect_end);
		for my $f (readdir(D))
		{
			if ($f =~ /^(update|collect)-(\d+)-(\d*)$/)
			{
				my ($op,$start,$end) = ($1,$2,$3);
				my ($target_start,$target_end) = ($op eq "update")? 
						(\$last_update_start, \$last_update_end) : 
						(\$last_collect_start, \$last_collect_end);

				if ($end && $start >= $$target_start && $end >= $$target_end)
				{
						$$target_start = $start;
						$$target_end = $end;
				}
			}
		}
		closedir(D);
		my ($updatestatus, $collectstatus);
    # for bootstrapping until first update with timestamping runs: treat no timestamps whatsoever 
		# as NO error (for metrics), but put error text in (for details page)
		if (!defined $last_update_end)
		{
			$updatestatus = "Could not determine last Update status";
		}
		elsif ($last_update_end < time - $max_update_age)
		{
			$updatestatus = "Last update completed too long ago, at ".returnDateStamp($last_update_end);
			$allok = 0;
		}
		# same bootstrapping logic as above
		if (!defined $last_collect_end)
		{
			$collectstatus = "Could not determine last Collect status";
		}
		elsif ($last_collect_end < time - $max_collect_age)
		{
			$collectstatus = "Last collect completed too long ago, at ".returnDateStamp($last_collect_end);
			$allok = 0;
		}
		# put these at the beginning
		unshift @details, ["Last Update", $updatestatus], [ "Last Collect", $collectstatus];
	}
	
	return ($allok, \@details);
}

# updates the operations start/stop timestamps
# args: type (=collect, update, threshold, summary etc),
# start (= time), stop (= time or undef to record the start)
# returns nothing
sub update_operations_stamp
{
	my (%args) = @_;
	my ($type,$start,$stop) = @args{"type","start","stop"};

	return if (!$type or !$start); # we associate start with stop
	
	my $C = loadConfTable;
	# having this hardcoded twice isn't great...
	my $oplogdir = $C->{'<nmis_var>'}."/nmis_system/timestamps";
	for my $maybedir ($C->{'<nmis_var>'}."/nmis_system/", $oplogdir)
	{
		if (!-d $maybedir)
		{
			mkdir($maybedir,0755) or die "cannot create $maybedir: $!\n";
			setFileProt($maybedir);
		}
	}

	# simple setup: update-123456- for start 
	# and update-1234567-1400000 for stop
	my $startstamp = "$oplogdir/$type-$start-";
	my $endstamp = "$oplogdir/$type-$start-$stop";
	
	if (!$stop)
	{
		open(F,">$startstamp") or die "cannot write to $startstamp: $!\n";
		close(F);
		setFileProt($startstamp);
	}
	else
	{
		# we actually should only have a start- stamp file to rename
		unlink($endstamp) if (-f $endstamp);
		if (-f $startstamp)
		{
			rename($startstamp,$endstamp) 
					or die "cannot rename $startstamp to $endstamp: $!\n";
			setFileProt($endstamp);
		}
		else
		{
			open(F,">$endstamp") or die "cannot write to $endstamp: $!\n";
			close(F);
			setFileProt($endstamp);
		}

		# now be a good camper and ensure that we don't leave too many 
		# of these files around
		opendir(D,$oplogdir) or die "cannot open dir $oplogdir: $!\n";
		# need these sorted by first timestamp
		my @files = sort { my ($first,$second) = ($a,$b); 
											 $first =~ s/^$type-(\d+).*$/$1/;
											 $second =~ s/^$type-(\d+).*$/$1/;
											 $second <=> $first; } grep(/^$type-/, readdir(D));
		my $maxfiles = 500;

		for my $idx ($maxfiles..$#files)
		{
			unlink("$oplogdir/$files[$idx]") 
					or die "cannot remove $oplogdir/$files[$idx]: $!\n";
		}
		close F;
	}
}

# small helper that returns hash of other nmis processes that are 
# running the given function
# args: type (=collect or update), config (config hash)
# with type given, collects the processes that run that cmd AND have the same config
# without type, collects ALL procs running perl and called nmis-something-... or nmis.pl,
# NOT just the ones with this config!
# returns: hashref of pid -> info about the process, namely $0/cmdline and starttime
sub find_nmis_processes
{
	my (%args) = @_;
	my $type = $args{type};
	my $config = $args{config};

	my %others;
	die "cannot run find_nmis_processes without configuration!\n"
		if (ref($config) ne "HASH" or !keys %$config);
	my $confname = $config->{conf};
	
	my $pst = Proc::ProcessTable->new(enable_ttys => 0);
	foreach my $procentry (@{$pst->table})
	{
		next if ($procentry->pid == $$);
		
		my $procname = $procentry->cmndline;
		my $starttime = $procentry->start;
		my $execname = $procentry->fname;

		if ($type && $procname =~ /^nmis-$confname-$type(-(.*))?$/)
		{
			my $trouble = $2;
			$others{$procentry->pid} = { name => $procname, 
																	 exe => $execname,
																	 node => $trouble,
																	 start => $starttime };
		}
		elsif (!$type && $execname =~ /(perl|nmis\.pl)/ && $procname =~ /(nmis\.pl|nmis-\S+-\S)/)
		{
			$others{$procentry->pid} = { name => $procname,
																	 exe => $execname,
																	 start => $starttime };
		}
	}
	return \%others;
}

# semi-internal accessor for the table cache structure
sub _table_cache
{
	return \%Table_cache;
}

# this small helper converts an ethernet or similar layer2 address
# from pure binary or 0xsomething into a string of the colon-separated bytes in the address
# the distinction raw binary vs. other formats depends on the 0x being present,
# and expects the raw binary to be 6 bytes or longer
# returns: string
sub beautify_physaddress
{
	my ($raw) = @_;

	return $raw if ($raw =~ /^([0-9a-f]{2}:)+[0-9a-f]{2}$/i); # nothing to do

	my @bytes;
	# nice 0xlonghex -> split into bytes 
	if ($raw =~ /^0x[0-9a-f]+$/i)
	{
		$raw =~ s/^0x//i;
		@bytes = unpack("C*", pack("H*", $raw));
	}
	elsif (length($raw) >= 6) # hmm looks like if it's raw binary, convert it on the go
	{
		@bytes = unpack("(C2)".length($raw), $raw);
	}

	if (@bytes)
	{
		my $template = join(":", ("%02x") x @bytes);
		return sprintf($template, @bytes);
	}

	return $raw;									# fallback to return the input unchanged if beautication doesn't work out
}

1;

