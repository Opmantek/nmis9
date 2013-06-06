#
## $Id: func.pm,v 8.26 2012/09/21 05:05:10 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

require 5;

use strict;
use Fcntl qw(:DEFAULT :flock :mode);
use File::Path;
use File::stat;
use Time::ParseDate;
use Time::Local;
use CGI::Pretty qw(:standard);

use Data::Dumper;
$Data::Dumper::Indent=1;
$Data::Dumper::Sortkeys=1;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = 1.00;

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
		writeHashtoFile
		readFiletoHash

		htmlElementValues
		logMsg
		logAuth2
		logAuth
		logIpsla
		logPolling
		dbg
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

#Function which returns the time
sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year $hour:$min:$sec";
}

sub returnDate{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
        else { $year=$year+2000; }
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year";
}

sub returnTime{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	return "$hour:$min:$sec";
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

sub convertSecsHours {
	my $seconds = shift ;
	my $timestamp;
	my $hours;
	my $minutes;
	my $minutes2;
	my $seconds2;

	if ($seconds == 0) {
		$timestamp = "00:00:00";
	}# Print Seconds
	elsif ($seconds < 60) {
		$seconds =~ s/(^[0-9]$)/0$1/g;
		$timestamp = "00:00:$seconds";
	}# Print Seconds
	elsif ($seconds < 3600) {
		$seconds2 = $seconds % 60;
		$minutes = ($seconds - $seconds2) / 60;
		$seconds2 =~ s/(^[0-9]$)/0$1/g;
		$minutes =~ s/(^[0-9]$)/0$1/g;
		$timestamp = "00:$minutes:$seconds2";
	}# Calculate and print minutes.
	else { 
		$seconds2 = $seconds % 60;
		$minutes = ($seconds - $seconds2) / 60;
		$minutes2 = $minutes % 60;
		$hours = ($minutes - $minutes2) / 60;
		$seconds2 =~ s/(^[0-9]$)/0$1/g;
		$minutes2 =~ s/(^[0-9]$)/0$1/g;
		if ( $hours < 10 ) { $hours = "0$hours"; }
		$timestamp = "$hours:$minutes2:$seconds2";
	}# Calculate and print hours.

	return $timestamp;

} # end convertSecsHours

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
		truncate(OUT, 0) or warn "can't truncate filename: $!";

		binmode(IN);
		binmode(OUT);		
		while (read(IN, $buff, 8 * 2**10)) {
		    print OUT $buff;
		}
		close(IN) or warn "can't close filename: $!";
		close(OUT) or warn "can't close filename: $!";
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

	if ( not -r $filename ) {
		logMsg("ERROR, file=$filename does not exist");
		return ;
	}
	
	# set the permissions. Skip if not running as root
	if ( $< == 0) { # root
		if ($username eq '') {
			if ( $C->{'os_username'} ne "" ) {
				$username = $C->{'os_username'} ;
			} else {
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
			else {
				$permission = "0660"; # default
			}
		}
		dbg("set file owner/permission of $filename to $username, $permission",3);
		
		if (!(($login,$pass,$uid,$gid) = getpwnam($username))) {
			logMsg("ERROR, unknown username $username");
		} else {
			if (!chown($uid,$gid,$filename)) {
				logMsg("ERROR, could not change ownership $filename to $username, $!");
			}
			if (!chmod(oct($permission), $filename)) {
				logMsg("ERROR, could not change $filename permissions to $permission, $!");
			}
		}
	}
	# you don't need to be root to set the group!
	else {
		# Get the current UID and GID of the file.
		my $fstat = stat($filename);
		my $fuid = $fstat->uid;
		my $myuid = $<;
				
		# unless your root you can't change files you don't own.
		if ( $fuid == $myuid ) {
			my $gid = getgrnam($C->{'nmis_group'});
	
			my $cnt = chown($myuid, $gid, $filename);
			if (not $cnt) {
				logMsg("ERROR, could not set the group of $filename $C->{'nmis_group'}.");
			}
			
			if ( -f $filename and $filename =~ /$C->{'nmis_executable'}/ and $C->{'os_execperm'} ne "" ) {
				$permission = $C->{'os_execperm'} ;
			} 
			elsif ( -f $filename and $C->{'os_fileperm'} ne "" ) {
				$permission = $C->{'os_fileperm'} ;
			} 
			else {
				$permission = "0660"; # default
			}
			
			if (!chmod(oct($permission), $filename)) {
				logMsg("ERROR, could not change $filename permissions to $permission, $!");
			}
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
	$name = ($name =~ /\./) ? $name : "$name.nmis"; # check for extention
	$file = getDir(dir=>$dir)."/$name";
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
	$name = ($name =~ /\./) ? $name : "$name.nmis"; # check for extention
	$file = getDir(dir=>$dir)."/$name";
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

sub loadTable {
	my %args = @_;
	my $dir = lc $args{dir}; # name of directory
	my $name = $args{name};	# name of table or short file name
	my $check = $args{check}; # if 'true' then check only if table is valid in cache
	my $mtime = $args{mtime}; # if 'true' then mtime is also returned
	my $lock = $args{lock}; # if lock is true then no caching

	my $C = loadConfTable();
	
	# return an empty structure if I can't do anything else.
	my $empty = { };

	if ($name ne '') {
		my $fname = ($name =~ /\./) ? $name : "$name.nmis"; # check for extention, default 'nmis'
		if ($dir =~ /conf|models|var/) {
			if (existFile(dir=>$dir,name=>$name)) {
				my $file = getDir(dir=>$dir)."/$fname";
				print STDERR "DEBUG loadTable: name=$name dir=$dir file=$file\n" if $confdebug;
				if ($lock eq 'true') {
					return readFiletoHash(file=>$file,lock=>$lock);
				} else {
					# known dir
					my $index = lc "$dir$name";
					if (exists $Table_cache{$index}{data}) {
						# already in cache, check for update of file
						if (stat($file)->mtime eq $Table_cache{$index}{mtime}) {
							return 1 if $check eq 'true';
							# else
							return $Table_cache{$index}{data},$Table_cache{$index}{mtime} if $mtime eq 'true'; # oke
							# else
							return $Table_cache{$index}{data}; # oke
						}
					}
					return 0  if $check eq 'true'; # cached data/table not valid
					# else
					# read from file
					$Table_cache{$index}{data} = readFiletoHash(file=>$file);
					$Table_cache{$index}{mtime} = stat($file)->mtime;
					return $Table_cache{$index}{data},$Table_cache{$index}{mtime} if $mtime eq 'true'; # oke
					# else
					return $Table_cache{$index}{data}; # oke
				}
			} else {
				logMsg("ERROR file does not exist dir=$dir name=$name, nmis_var=$nmis_var nmis_conf=$nmis_conf");
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
		my $fname = ($name =~ /\./) ? $name : "$name.nmis"; # check for extention, default 'nmis'
		if ($dir =~ /conf|models|var/) {
			my $file = getDir(dir=>$dir)."/$fname";
			return writeHashtoFile(file=>$file,data=>$args{data},handle=>$args{handle});
		} else {
			logMsg("ERROR unknown dir=$dir specified with name=$name");
		}
	} else {
		logMsg("ERROR no name specified");
	}
	return;
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

	$file .= '.nmis' if $file !~ /\./;

	dbg("write data to $file");
	if ($handle eq "") {
		if (open($handle, "+<$file")) {
			flock($handle, LOCK_EX) or warn "ERROR writeHashtoFile, can't lock $file, $!\n";
			seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
			truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
		} else {
			open($handle, ">$file")  or warn "writeHashtoFile: ERROR cannot open $file: $!\n";
			flock($handle, LOCK_EX) or warn "writeHashtoFile: ERROR can't lock file $file, $!\n";
		}
	} else {
		seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
		truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
	}
	if ( not print $handle Data::Dumper->Dump([$data], [qw(*hash)]) ) {
		logMsg("ERROR cannot write file $file: $!");
	}
	close $handle;

	setFileProt($file);

	# store updated filename in table with time stamp
	if ($C_cache->{server_remote} eq 'true' and $file !~ /nmis-files-modified/) {
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
	my $lock = $args{lock}; # option
	my %hash;
	my $handle;
	my $line;

	$file .= ".nmis" if $file !~ /\./;

	if ( -r $file ) {
		my $filerw = ($lock eq 'true') ? "+<$file" : "<$file";
		my $lck = ($lock eq 'true') ? LOCK_EX : LOCK_SH;
		if (open($handle, "$filerw")) {
			flock($handle, $lck) or warn "ERROR readFiletoHash, can't lock $file, $!\n";
			while (<$handle>) { $line .= $_; }
			# convert data to hash
			%hash = eval $line;
			if ($@) {
				logMsg("ERROR convert $file to hash table, $@");
				close $handle;
				return;
			}
			return (\%hash,$handle) if ($lock eq 'true');
			# else
			close $handle;
			return \%hash;
		} else{
			logMsg("ERROR cannot open file=$file, $!");
		}
	} else {
		if ($lock eq 'true') {
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
sub dbg {
	my $msg = shift;
	my $level = shift || 1;
	my $string;
	my $caller;
	if ($C_cache->{debug} >= $level or $level == 0) {
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

sub getbool {
	my $val = shift;
	return 1 if $val =~ /^[yt1]/i;
	return 0; # otherwise
} # end getbool


### 2011-12-07 keiths, adding support for specifying the directory.
sub getConfFileName {
	my %args = @_;
	my $conf = $args{conf};
	my $dir = $args{dir};

	# See if customised config file required.
	my $configfile = "$FindBin::Bin/../conf/$conf"; 
	
	if ( $dir ) {
		$configfile = "$dir/$conf"; 
	}
	
	if (not -r $configfile ) {
		# the following should be conformant to Linux FHS
		if ( -e "/etc/nmis/$conf") {
			$configfile = "/etc/nmis/$conf";
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
			
			print "Can't access neither NMIS configuration file=$configfile, nor /etc/nmis/$conf \n";
			
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
	my $conf = $args{conf} || 'Config.nmis';
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
		$conf = 'Config.nmis';
	}

	# on start of program parameters are defined
	return $C_cache if defined $C_cache and scalar @_ == 0;

	# add extension if missing
	$conf = $conf =~ /\./ ? $conf : "${conf}.nmis";
	
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
			$Table_cache{$conf}{conf} = $conf;
			$Table_cache{$conf}{configfile} = $configfile;
			$Table_cache{$conf}{configfile_name} = substr($configfile, rindex($configfile, "/")+1);
			$Table_cache{$conf}{auth_require} = ($Table_cache{$conf}{auth_require} eq 'false') ? 0 : 1; # default true in Auth
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
	if ($CC->{system}{xml_config} eq 'true') {
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
		mkpath($dir,{mode=>$C->{'os_username'}});
	}
	setFileProt($dir);
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
		
		if ( $fstat->size > $C->{'file_size_warning'} ) {
			$result = 0;
			my $size = $fstat->size;
			push(@messages,"WARN: $file is $size bytes, larger than $C->{'file_size_warning'} bytes");			
		}

		#S_IRWXU S_IRUSR S_IWUSR S_IXUSR
    #S_IRWXG S_IRGRP S_IWGRP S_IXGRP
    #S_IRWXO S_IROTH S_IWOTH S_IXOTH
		
		# Are the user and group permissions correct.    
    # are the files executable or non-executable
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


1;

