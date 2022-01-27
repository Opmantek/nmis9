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
#
# Utility package for various reusable general-purpose functions
package NMISNG::Util;
our $VERSION = "9.3.0";

use strict;
use feature 'state';						# loadconftable, uuid functions

use Crypt::CBC;
use Crypt::Cipher::AES;
use Fcntl qw(:DEFAULT :flock :mode);
use FindBin;										# bsts; normally loaded by the caller
use File::Path;
use File::Basename;
use File::stat;
use File::Spec;
use File::Copy;
use Sys::Syslog qw(:standard :macros);

use Time::ParseDate;
use Time::Local;
use Time::Moment;
use DateTime::TimeZone;
use HTML::Entities;

use POSIX qw();
use Cwd qw();
use version 0.77;
use Carp;
use UUID::Tiny qw(:std);				# for loadconftable, cluster_id, uuid functions
use IO::Handle;
use Socket 2.001;								# for getnameinfo() used by resolve_dns_name
use JSON::XS;
use Proc::ProcessTable 0.53;		# older versions are not totally reliable
use List::Util 1.33;

use Data::Dumper;
$Data::Dumper::Indent=1;				# fixme9: do we really need these globally on?
$Data::Dumper::Sortkeys=1;

use NMISNG::Log;								# for parse_debug_level

sub TODO
{
	my (@stuff) = @_;

	# TODO: find a better way to enable/disabling this, !?!
	my $show_todos = 0;
	print "TODO: " . $stuff[0] . "\n" if ($show_todos);
}

# like getargs, but arrayify multiple occurrences of a parameter
# args: list of key=values to parse,
# returns: hashref
sub get_args_multi
{
	my @argue = @_;
	my %hash;

	for my $item (@argue)
	{
		if ( $item !~ /^.+=/ )
		{
			print STDERR "Invalid command argument \"$item\"\n";
			next;
		}

		my ( $name, $value ) = split( /\s*=\s*/, $item, 2 );
		if ( ref( $hash{$name} ) eq "ARRAY" )
		{
			push @{$hash{$name}}, $value;
		}
		elsif ( exists $hash{$name} )
		{
			my @list = ( $hash{$name}, $value );
			$hash{$name} = \@list;
		}
		else
		{
			$hash{$name} = $value;
		}
	}
	return \%hash;
}

# this small helper forces anything that looks like a number
# into a number. json::xs needs that distinction, ditto mongodb.
# args: a single input, should be a string or a number.
#
# returns: original thing if not number or ref or other unwanted stuff,
# numberified thing otherwise.
sub numify
{
	my ($maybe) = @_;

	return $maybe if ref($maybe);

	# integer or full ieee floating point with optional exponent notation
	return ( $maybe =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ ) ? ( $maybe + 0 ) : $maybe;
}

# fixme9 move away
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

# Used by makeRRDname to remove blanks 
# and /
sub filterName {
	my $name = shift;
	$name =~ s/\//-/g;
	$name =~ s/\s+/-/g;

	return $name;
}

# remove undesirable characters from ifdescr strings
sub rmBadChars
{
	my $intf = shift;

	# \0 shouldn't be there anyway,
	# ' is produced by cisco PIX
	# , is removed because csv generation and parsing in nmis is not good
	$intf =~ s/[\x00',]//g;
	return $intf;
}

# strips both leading and trailing spaces
sub stripSpaces
{
	my $str = shift;
	return undef if (!defined $str);

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

# this function returns the given time (or now) ALMOST in ctime format,
# i.e. same start but the timezone name is appended.
# args: time, optional.
sub get_localtime
{
	my ($time) = @_;
	$time ||= time;

	return POSIX::strftime("%a %b %d %H:%M:%S %Y %Z", localtime($time));
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

# takes number N and unit string X, returns now minus N times (numeric value for X)
sub convertTime
{
	my $amount = shift;
	my $units = shift;
	my $timenow = time;
	my $newtime;

	$units ||= "days";

	# convert length code into Graph start time
	if ( $units eq "minutes" ) { $newtime = $timenow - $amount * 60; }
	elsif ( $units eq "hours" ) { $newtime = $timenow - $amount * 60 * 60; }
	elsif ( $units eq "days" ) { $newtime = $timenow - $amount * 24 * 60 * 60; }
	elsif ( $units eq "weeks" ) { $newtime = $timenow - $amount * 7 * 24 * 60 * 60; }
	elsif ( $units eq "months" ) { $newtime = $timenow - $amount * 31 * 24 * 60 * 60; }
	elsif ( $units eq "years" ) { $newtime = $timenow - $amount * 365 * 24 * 60 * 60; }

	return $newtime;
}

# translates period value into human-friendly string
# input: period value, optional onlysingleunit, optional fractions
# fractions is honored only when onlysingleunit is set
# returns things like 4d or 95m with onlysingleunit, or 1h20m otherwise
# or 1.34d (onlysingleunit 1 and fractions 2)
sub period_friendly
{
		my ($value,$onlysingleunit,$fractions) = @_;

		my ($string,$div);
		my %units = ("y" => 86400*365, "d" => 86400, "h" => 3600, "m" => 60, "s" => 1);

		# break it into the largest available unit, then the next and so on
		# OR use only ONE unit, the largest that allows division without remainder,
		# or the largest one smaller than the input if fractions are allowed.
		for my $unitname (sort { $units{$b} <=> $units{$a}} keys %units)
		{
			my $unitvalue = $units{$unitname};
			my $mod = $value % $unitvalue;
			my $div = $value / $unitvalue;

			next if ($onlysingleunit && !$fractions && $mod);

			if ($div >= 1)
			{
				my $layout = ($onlysingleunit && $fractions)? "%.${fractions}f%s" : "%d%s";
				$string .= sprintf($layout, $div, $unitname);
				$value = $mod;
				last if ($onlysingleunit && $fractions);
			}
		}
		return $string;
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
	# fixme unsupported - should be unknwon
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

	if ( $status eq "up" ) { $color = NMISNG::Util::colorPercentHi(100); } 		#$color = "#00FF00"; }
	elsif ( $status eq "down" ) { $color = NMISNG::Util::colorPercentHi(0); }		 # "#FF0000"; }
	elsif ( $status eq "testing" ) { $color = '#AAAAAA'; }				 #"#FFFF00"; }
	elsif ( $status eq "null" ) { $color = '#AAAAAA'; } 						#"#FFFF00"; }
	else { $color = '#AAAAAA'; } 																		#"#FFFFF; }

	return $color;
}

# set color for background or border
sub getBGColor {
	return "background-color:$_[0];" ;
}

# translates nmis severity levels to colors
# fixme: traceback and error are not-quite-standard and not supported everywhere,
# nor are up or down event levels.
sub eventColor
{
	my $event_level = shift;
	my $color;

 	if ( $event_level =~ /fatal/i or $event_level =~ /^0$/ ) { $color = NMISNG::Util::colorPercentLo(100) }
 	elsif ( $event_level =~ /critical/i or $event_level == 1 ) { $color = NMISNG::Util::colorPercentLo((100/7)*1) }
 	elsif ( $event_level =~ /major|traceback/i or $event_level == 2 ) { $color = NMISNG::Util::colorPercentLo((100/7)*2) }
 	elsif ( $event_level =~ /minor/i or $event_level == 3 ) { $color = NMISNG::Util::colorPercentLo((100/7)*3) }
 	elsif ( $event_level =~ /warning/i or $event_level == 4 ) { $color = NMISNG::Util::colorPercentLo((100/7)*4) }
 	elsif ( $event_level =~ /error/i or $event_level == 5 ) { $color = NMISNG::Util::colorPercentLo((100/7)*5) }
 	#Was returning a dull green, want a nice lively green.
 	#elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $color = NMISNG::Util::colorPercentLo((100/7)*6) }
 	elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $color = NMISNG::Util::colorPercentLo(0) }
 	elsif ( $event_level =~ /up/i ) { $color = NMISNG::Util::colorPercentHi(100) }
 	elsif ( $event_level =~ /down/i ) { $color = NMISNG::Util::colorPercentHi(0) }
 	elsif ( $event_level =~ /unknown/i ) { $color = '#AAAAAA'  }
 	else { $color = '#AAAAAA'; }
	return $color;
} # end eventColor

# sanitises/translates some sort of severity level into nmis levels
# fixme: except that levels error and traceback are not standard nor supported everwhere
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

sub getDiskBytes {
	$_ = shift;
	my $ps = shift; # 'ps'
	if ( $_ eq "NaN" ) { return "$_" ;}
	elsif ( $_ > 1073741824 ) { $_ /= 1073741824; /(\d+\.\d\d)/; return "$1 GB${ps}"; }
	elsif ( $_ > 1048576 ) { $_ /= 1048576; /(\d+\.\d\d)/; return "$1 MB${ps}"; }
	elsif ( $_ > 1024 ) { $_ /= 1024; /(\d+\.\d\d)/; return "$1 KB${ps}"; }
	else { /(\d+\.\d\d)/; return"$1 b${ps}"; }
}

# performs a binary copy of a file, used for backup of files.
# args: file (= source path), backup (= destination path)
# returns: undef if ok, error message otherwise
sub backupFile
{
	my (%arg) = @_;
	my ($source, $dest)  = @arg{"file","backup"};
	return "no source file argument!" if (!$source);
	return "no backup destination argument!" if (!$dest);
	return "invalid backup destination!" if ($dest eq $source);

	# -f covers symlinks by checking the target
	return "source file \"$source\" is not a file or doesn't exist!"
			if (!-f $source);

	return "failed to copy \"$source\" to \"$dest\": $!"
			if (!File::Copy::cp($source, $dest));
	return undef;
}

# funky sort, by Eric.
# call me like this:
# foreach $i ( NMISNG::Util::sortall(\%hash, 'value', 'fwd') );
# or
# foreach $i ( NMISNG::Util::sorthash(\%hash, [ 'value1', 'value2', 'value3' ], 'fwd') ); value2 and 3 are optional
# where 'value' is the hash value that you wish to sort on.
# 3rd arguement = forward|reverse
# example: foreach $reportnode ( sort { $reportTable{$b}{response} <=> $reportTable{$a}{response} } keys %reportTable )
# now:	foreach $reportnode ( NMISNG::Util::sortall(\%reportTable, 'response' , 'fwd|rev') )
#
# sortall2 - takes two hash arguements
# foreach $i ( NMISNG::Util::sortall2(\%hash, 'sort1', 'sort2', 'fwd|rev') );

sub sortall2 {
	sort { alpha( $_[3], $_[0]->{$a}{$_[1]}, $_[0]->{$b}{$_[1]}) || alpha( $_[3], $_[0]->{$a}{$_[2]}, $_[0]->{$b}{$_[2]}) } keys %{$_[0]};
}

sub sortall {
	sort { alpha( $_[2], $_[0]->{$a}{$_[1]}, $_[0]->{$b}{$_[1]}) }  keys %{$_[0]};
}

# args: data (must be hashref), sortcriteria (must be list ref, optional), direction (fwd, rev, optional)
# attention: sortcriteria are NESTING, NOT fallbacks,
# ie. hash MUST have deep structure Crit1->C2->C3, if you pass three sortcriteria
# returns sorted keys of the hash
sub sorthash
{
	my ($data, $sortcriteria, $direction) = @_;
	if (ref($sortcriteria) ne "ARRAY" or !@$sortcriteria)
	{
		return sort { alpha( $direction, $a, $b) }  keys %$data;
	}
	elsif  (@$sortcriteria == 1)
	{
		return sort { alpha( $direction,
												 $data->{$a}->{$sortcriteria->[0]},
												 $data->{$b}->{$sortcriteria->[0]}) }  keys %$data;
	}
	elsif (@$sortcriteria == 2)
	{
		return sort { alpha( $direction,
												 $data->{$a}->{$sortcriteria->[0]}->{$sortcriteria->[1]},
												 $data->{$b}->{$sortcriteria->[0]}->{$sortcriteria->[1]} ) } keys %$data;
	}
	elsif (@$sortcriteria == 3)
	{
		return sort { alpha( $direction,
												 $data->{$a}->{$sortcriteria->[0]}->{$sortcriteria->[1]}->{$sortcriteria->[2]},
												 $data->{$b}->{$sortcriteria->[0]}->{$sortcriteria->[1]}->{$sortcriteria->[2]}) } keys %$data;
	}
	else
	{
		die "Invalid arguments passed to sorthash!\n";
	}
}

# internal helper for contextual sorting
# args: direction (fwd, rev - default is rev), and two inputs
# returns: -1/0/1
sub alpha
{
	my ($direction, $f, $s) = @_;

	if (!defined($direction) or $direction ne 'fwd')
	{
		my $temp = $f; $f = $s; $s = $temp;
	}

	# sort nan input after anything else
	if ($f != $f)									# ie. f is NaN
	{
		return ($s != $s)? 0 : 1;
	}
	elsif ($s != $s)
	{
		return -1;
	}

	# Sort numbers numerically - integer, fractionals, full ieee format
	return ($f <=> $s) if ($f =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/
												 && $s =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/);

	# Handle things like Level1, ..., Level10
	if ($f =~ /^(.*\D)(\d+)$/)
	{
    my @first = ($1, $2);
		if ($s =~ /^(.*\D)(\d+)$/)
		{
			my @second = ($1, $2);

			return ($first[1] <=> $second[1])
					if ($first[0] eq $second[0]);
		}
	}

	# Sort IP addresses numerically within each dotted quad
	# fixme: doesn't handle ipv6
	if ($f =~ /^(\d+\.){3}\d+$/ && $s =~ /^(\d+\.){3}\d+$/)
	{
		my @splitfirst = split(/\./, $f);
		my @splitsecond = split(/\./, $s);
		return ( $splitfirst[0] <=> $splitsecond[0]
						 || $splitfirst[1] <=> $splitsecond[1]
						 || $splitfirst[2] <=> $splitsecond[2]
						 || $splitfirst[3] <=> $splitsecond[3] );
	}

	# Handle things like Serial0/1/2, 3 numeric components (normally at the end),
	# separated by a single nondigit char
	if ($f =~ /^(.*\D)(\d+)\D(\d+)\D(\d+)(.*)$/)
	{
		my @first = ($1,$2,$3,$4,$5);
		if ($s =~ /^(.*\D)(\d+)\D(\d+)\D(\d+)(.*)$/)
		{
			my @second = ($1,$2,$3,$4,$5);
			return (lc($first[0]) cmp lc($second[0]) # text component
							|| $first[1] <=> $second[1]			 # first digit
							|| $first[2] <=> $second[2]			 # second digit
							|| $first[3] <=> $second[3]			 # third digit
							|| lc($first[4]) cmp lc($second[4]) );		# whatever's left
		}
	}

	# Default is to sort alphabetically
	return lc($f) cmp lc($s);
}

# reads and returns the nmis config file data
# reads from the given directory or the default one; uses cached data if possible.
# ATTENTION: no dir argument on a subsequent call means that the PREVIOUS
# dir and file are checked!
#
# attention: this massages in certain values: info, debug  etc!
# this function must be self-contained, as most stuff in NMISNG::Util:: calls loadconftable
#
# args: dir, debug (all optional)
# returns: hash ref, dies (verbosely) on failure
sub loadConfTable
{
	my %args = @_;
	state ($config_cache);

	my $dir = $args{dir} || "$FindBin::RealBin/../conf";
	# abspath and friends don't work properly if the dirs in question don't exist;
	mkpath($dir, { verbose  => 0, mode => 0755} ) if (!-d $dir);

	my $fn = Cwd::abs_path("$dir/Config.nmis");			# the one and only...
	# ...but the caller may have given us a dir in a previous call and NONE now
	# in which case we assume they want the cached goodies, so we look at
	# the file of the previous call.
	$fn = $config_cache->{configfile} if (ref($config_cache) eq "HASH"
																				&& $config_cache->{configfile}
																				&& !defined $args{dir});
	my $fallbackfn;								# only set if falling back
	# Directory for the partial configuration files (From Master)
	my $partialconf_dir = Cwd::abs_path("$dir/conf.d");
	my $stat = stat($fn);
	# try conf-default if that doesn't work
	if (!$stat)
	{
		$fallbackfn = ($args{dir}?
									 "$args{dir}/../conf-default/"
									 : "$FindBin::RealBin/../conf-default/") ."Config.nmis";
		$stat = stat($fallbackfn);
	}
	if (!$stat)
	{
		# no config, no hope, no future
		warn_die("all configuration files ($fn, $fallbackfn) are unreadable: $!");
	}

	my $external_files = get_external_files(dir => $partialconf_dir);

	# read the file if not read yet, or different dir requested
	if ( !$config_cache
			 or $config_cache->{configfile} ne $fn
			 or $stat->mtime > $config_cache->{mtime} )
	{
		$config_cache = {};				# clear it
		# note: cannot use readfiletohash here: infinite recursion as
		# most helper functions (have to) call loadConfTable first!

		# lock the file or config writing (which truncates) could cause race conditions
		my $whichfile = $fallbackfn? $fallbackfn : $fn;
	
		$config_cache = read_load_cache(whichfile => $whichfile, cachefile => $config_cache, master => "true", fn => $fn );
		$stat = stat($fn);
						 
		# certain values get massaged in/to the config
		$config_cache->{conf} = "Config"; # fixme9: this is no longer very useful, only one config supported
		$config_cache->{auth_require} = 1; # auth_require false is no longer supported
		# ensure hide_groups is present (saves us checking the ref all over the place)
		$config_cache->{hide_groups} //= [];

		# fixme9: saving this back is likely a bad idea, config vs. command line
		# fixme: none of this is nmisng::log compatible, where info is only t/f,
		# and verbosity is from fatal..info..debug..1-9.
		my $verbosity = NMISNG::Log::parse_debug_level(debug => $args{debug});
		$config_cache->{debug} = $verbosity =~ /^(debug|\d)+/? $verbosity : 0;
		# info is only consulted if debug isn't
		if (!$config_cache->{debug})
		{
			$verbosity = NMISNG::Log::parse_debug_level(debug => $args{info});
			$config_cache->{info} = $verbosity =~ /^(debug|\d)+/? $verbosity : 0;
		}

		$config_cache->{configfile} = $fn; # fixperms also wants that
		$config_cache->{mtime} = $stat->mtime;
		# config is loaded, all plain <xyz> -> "static stuff" macros need to be resolved
		# walk all things in need of macro expansion and fix them up as much as possible each iteration
		
		$config_cache = replace_macros( config_cache => $config_cache );
		# a little safety net (for init/systemd and other stuff that needs to find pidfiles etc):
		# if the var directory configuration is non-standard,
		# then maintain a symlink to the configured directory
		# note: if var is reconfigured back to normal but symlink is correct, then no action is taken
		my $confdvar = $config_cache->{'<nmis_var>'};
		my @confdstat = (CORE::stat($confdvar))[0,1]; # device and inode
		my $normalvar = "$config_cache->{'<nmis_base>'}/var";
		my @normalstat = (CORE::stat($normalvar))[0,1]; # device and inode

		if (-d $confdvar and ($confdstat[0] != $normalstat[0]
													or $confdstat[1] != $normalstat[1]))
		{
			rename($normalvar, "$normalvar.deconfigured.$$") if (-e $normalvar);
			symlink($confdvar, $normalvar)
					or warn_die("cannot symlink $normalvar to configured $confdvar: $!");
		}
		
	} else {
		#warn("\n>>> Reading cache");
	}
	
	if (scalar @$external_files > 0)
	{
		# Now that we finish loading all the values, lets load overriding partial files
		# conf.d directory
		my $properties = properties_never_override();	
		foreach (@$external_files) {
			my $stat = stat($_);
			if ($stat->mtime > $config_cache->{@_}) {
				my $local_config_cache;
				push @{$config_cache->{configpeerfiles}}, $_;
				$local_config_cache = read_load_cache(whichfile => $_, cachefile => $local_config_cache, master => 0, fn => $_ );	
				# Merge with local cache
				while ( my ($k,$v) = each(%{$local_config_cache}) ) {
					# Never let the master change this value(s)
					next if ( grep( /^$k$/, @$properties ));
					$config_cache->{$k} = $v;
				}
				$config_cache = replace_macros( config_cache => $config_cache );
				$config_cache->{@_} = $stat->mtime; # remember
			}
		}
	}
	return $config_cache;
}

# Get external configuration files
sub get_external_files
{
	my %args = @_;
	my $dir = $args{dir};
	my @files = ();
	if (opendir(DIR, $dir)) {
		my $filename;
		while ($filename = readdir(DIR)) {
			# Only .nmis files
			next unless ($filename =~ m/\.nmis$/);
			my $path = $dir . "/" . $filename;
			push @files, $path; 
		}
		closedir(DIR);
	}
	return \@files;
}

# Read a configuration file, block and load cache
sub read_load_cache
{
	my %args = @_;
	my $whichfile = $args{whichfile};
	my $config_cache = $args{cachefile};
	my $is_master = $args{master};
	my $fn = $args{fn};

	open(X, $whichfile) or warn_die("cannot open configuration file $whichfile: $!") if $is_master;
	flock(X, LOCK_SH) or warn_die("cannot lock configuration file $whichfile: $!") if $is_master;

	my %deepdata = do ($whichfile);
	# should the file have unwanted gunk after the %hash = ();
	# it'll most likely be a '1;' and do returns the last statement result...
	if ($@)
	{
		my $nmisng = Compat::NMIS::new_nmisng();
		$nmisng->log->info(&NMISNG::Log::trace()." MAKERRDNAME") if ($nmisng);
		warn_die("configuration file $fn unparseable: $@ $is_master") if $is_master;
		warn(">> configuration file $fn unparseable: $@");
		close(X);	
	}
	elsif (keys %deepdata < 2 and $is_master)
	{
		my $nmisng = Compat::NMIS::new_nmisng();
		$nmisng->log->info(&NMISNG::Log::trace()." MAKERRDNAME");
		warn_die("configuration $whichfile does not have enough depth, only ". (scalar keys %deepdata). " entries!") if $is_master;
	} else {
		close(X);	
		# strip the outer of two levels, does not flatten any deeper structure
		for my $k (keys %deepdata)
		{
			for my $kk (keys %{$deepdata{$k}})
			{
				warn("Config section \"$k\" contains clashing config entry \"$kk\"!\n")
						if (defined($config_cache->{$kk})); # not terminal
				$config_cache->{$kk} = $deepdata{$k}->{$kk};
			}
		}
		
		# this one is vital for NMIS9 in particular: the cluster_id must be unique AND not change
		if (!$config_cache->{cluster_id} && $is_master)
		{
			$deepdata{id}->{cluster_id} = $config_cache->{cluster_id} = create_uuid_as_string(UUID_RANDOM);
			# and write back the updated config file - cannot use writehashtofile yet!
			open(F, (-e $fn? "+<": ">"), $fn) or warn_die("cannot write configuration file $fn: $!");
			seek(F,0,0);							# only relevant when opening existing file
			truncate(F,0);						# ditto
			flock(F, LOCK_EX) or warn_die("cannot lock configuration file $fn: $!");
			print F Data::Dumper->Dump([\%deepdata], [qw(*hash)]);
			close F;									# which unlocks
			# and restat to get the new mtime
		}
	}
	
	return $config_cache;
}

# small helper function that is going to replace macros
# args: error message
sub replace_macros
{
	my (%args) = @_;
	my $config_cache = $args{config_cache};
	
	my @todos = grep(!ref($config_cache->{$_})
										 && $config_cache->{$_} =~ /<\w+>/, keys %$config_cache);
	
	while (@todos)
		{
			my $atstart = @todos;
			my @stilltodo;

			while (my $needsmacro = shift @todos)
			{
				my $value = $config_cache->{$needsmacro};
				my $newvalue; my $isdone = 1;
				# variation one: explicitely defined '<something>' => whatever, used as '...<something>...'
				# variation two, fallback: if 'other' is defined, but used as '...<other>...'
				while ($value =~ s/^(.*?)(<[^>]+>)//)
				{
					my ($pre, $macroname) = ($1,$2);
					$newvalue .= $pre;
					my $fallbackname = $macroname; $fallbackname =~ s/^<(.*)>$/$1/;

					if (defined($config_cache->{$macroname}))
					{
						$newvalue .= $config_cache->{$macroname};
					}
					elsif (defined($config_cache->{$fallbackname}))
					{
						$newvalue .= $config_cache->{$fallbackname};
					}
					else
					{
						$newvalue .= $macroname; # leave unresolvables as they are AND reappend to todo
						$isdone = 0;
					}
				}
				$newvalue .= $value;		# unmatched remainder
				$config_cache->{$needsmacro} = $newvalue;
				push @stilltodo, $needsmacro if (!$isdone or $newvalue =~ /<\w+>/);
			}
			@todos = @stilltodo;
			my $atend = @todos;
			if ($atend == $atstart) # any remaining <xyz> occurrences are unresolvable or self-referential loops!
			{
				warn("unresolvable macros for config entries: ".join(", ",@todos)."\n");
				last;
			}
		}
		return $config_cache;
}

# small helper function that syslogs the exception message, then terminates
# args: error message
sub warn_die
{
	my ($msg) = @_;
	my $me = $0 =~ m!/!? basename($0): $0;
	openlog($me, "pid,ndelay,nofatal", LOG_DAEMON);
	syslog(LOG_ERR, $msg);
	die "$msg\n";
}

# sets file ownership and permissions, with diagnostic return values
# args: file (required, path to file or dir), username, groupname, permission
# if run as root, then ownership is changed to username and to config nmis_group
# if NOT root, then just the file group ownership is changed, to config nmis_group (if possible).
#
# returns undef if successful, error message otherwise
sub setFileProtDiag
{
	my (%args) = @_;
	my $C; # = $args{conf} // NMISNG::Util::loadConfTable();
	(ref($args{conf}) eq "HASH" ? $C = $args{conf}
                                : $C = NMISNG::Util::loadConfTable());

	my $filename = $args{file};
	my $username = $args{username} || $C->{nmis_user} || "nmis";
	my $groupname = $args{groupname} || $C->{nmis_group} || 'nmis';
	my $permission = $args{permission};

	return "file=$filename does not exist"
			if ( not -r $filename and ! -d $filename );

	my $currentstatus = stat($filename);

	if (!$permission)
	{
		# dirs
		if (S_ISDIR($currentstatus->mode))
		{
			$permission = $C->{'os_execperm'} || "0770";
		}
		# files
		elsif ($filename =~ /$C->{'nmis_executable'}/
					 && $C->{'os_execperm'} )
		{
			$permission = $C->{'os_execperm'};
		}
		elsif ($C->{'os_fileperm'})
		{
			$permission = $C->{'os_fileperm'};
		}
		else
		{
			$permission = "0660";
		}
	}

	my ($login,$pass,$uid,$primgid) = getpwnam($username);
	return "cannot change file owner to unknown user \"$username\"!"
			if (!$login);
	my $gid = getgrnam($groupname);

	# we can change file ownership iff running as root
	my $myuid = $<;
	if ( $myuid == 0)
	{
		# ownership ok or in need of changing?
		if ($currentstatus->uid != $uid or $currentstatus->gid != $gid)
		{
			return("Could not change ownership of $filename to $username:$groupname, $!")
					if (!chown($uid,$gid,$filename));
		}
	}
	elsif ($currentstatus->uid == $myuid )
	{
		# only root can change files that are owned by others,
		# but you don't need to be root to set the group and perms IF you're the owner
		# and if the target group is one you're a member of
		# in this case username is IGNORED and we aim for config nmis_group

		if (defined($gid) && $currentstatus->gid != $gid)
		{
			return ("could not set the group of $filename to $groupname: $!")
					if (!chown($myuid, $gid, $filename));
		}
	}
	else
	{
		# we complain about this situation only if a change would be required
		return "Cannot change ownership/permissions of $filename: neither root nor file owner!"
				if (!defined($gid) or $currentstatus->gid != $gid);
	}

	# perms need changing?
	if (($currentstatus->mode & 07777) != oct($permission))
	{
		return "could not change $filename permissions to $permission, $!"
				if (!chmod(oct($permission), $filename));
	}

	return undef;
}



# fix up the file permissions for given directory,
# and all its parents up to (but excluding) the given top (or nmis_base)
# args: directory in question, topdir
# returns: undef or error message
sub setFileProtParents
{
	my ($thisdir, $topdir) = @_;
	my $C = NMISNG::Util::loadConfTable();

	$topdir ||= $C->{'<nmis_base>'};
	$topdir = File::Spec->canonpath($topdir);
	$thisdir = File::Spec->canonpath($thisdir);

	my $relative = File::Spec->abs2rel($thisdir, $topdir);
	my $curdir = $topdir;

	# don't make a mess if thisdir is outside of the topdir!
	if ($thisdir !~ /$topdir/ or $relative =~ m!/\.\./!)
	{
		return "setFileProtParents called with bad args: thisdir=$thisdir top=$topdir relative=$relative";
	}

	for my $component (File::Spec->splitdir($relative))
	{
		next if !$component;
		$curdir.="/$component";
		if (my $error = NMISNG::Util::setFileProtDiag(file =>$curdir))
		{
			return $error;
		}
	}
	return undef;
}

# expand directory name if its one of the short names var, models, conf, conf_default, logs, mibs;
# args: dir
# returns expanded value or original input
sub getDir
{
	my (%args) = @_;
	my $dir = $args{dir};
	my $C = $args{conf} // NMISNG::Util::loadConfTable(); # cache, in general

	# known expansions
	for my $maybe (qw(var models default_models conf conf_default logs mibs))
	{
		return $C->{"<nmis_$maybe>"} if ($dir eq $maybe);
	}
	return $dir;
}

# takes dir and name, possibly shortnames, possibly w/o extension,
# mangles that and returns 0/1 if the file exists.
sub existFile
{
	my %args = @_;
	my $dir = $args{dir};
	my $name = $args{name};
	my $conf = $args{conf};
	return 0 if (!$dir or !$name);

	my $file;
	$file = getDir(dir=>$dir, conf => $conf)."/$name"; # expands dir args like 'conf' or 'logs'
	$file = NMISNG::Util::getFileName(file => $file, conf => $conf); # mangles that into path with extension
	return ( -e $file ) ;
}

# get modified time of file
### 2011-12-29 keiths, added test for file existing.
sub mtimeFile {
	my %args = @_;
	my $dir = $args{dir};
	my $name = $args{name};
	my $conf = $args{conf};
	
	my $file;
	return if $dir eq '' or $name eq '';
	$file = getDir(dir=>$dir, conf => $conf)."/$name";
	$file = NMISNG::Util::getFileName(file => $file, conf => $conf);
	if ( -r $file ) {
		return stat($file)->mtime;
	}
	else {
		return;
	}
}

# function for reading hash tables/files
#
# args: dir, name (both required, name may be w/o extension),
#  lock (optional, default 0, if 0 loadtable returns (data,locked handle), if 0 returns just data
#
# returns: (hashref-or-errormsg) or (hashref-or-errormsg,locked handle)
#
# ATTENTION: fixme dir logic is very convoluted! dir is generally NOT a garden-variety real dir path!
sub loadTable
{
	my %args = @_;
	my $dir =  $args{dir}; # name of directory
	my $name = $args{name};	# name of table or short file name
	my $nmisng = $args{nmisng};
	my $conf = $args{conf};

	my $lock = NMISNG::Util::getbool($args{lock}); # if lock is true then no caching and no fallbacks

	# full path -> { data => ..., mtime => ... }
	state %cache;

	return "loadTable is missing arguments: name=$name dir=$dir" if (!$name or !$dir);
	(my $without_extension = $name) =~ s/\.[^.]+$//;

	my $expandeddir = getDir(dir => $dir, conf => $conf); # expands dirs like 'conf' or 'logs' into full location
	my $file = "$expandeddir/$name";
	$file = NMISNG::Util::getFileName(file => $file, conf => $conf);		 # mangles file name into extension'd one

	# special case for files under conf: if lock is not set and conf/file is missing, fall back automatically conf-default/file
	if ($expandeddir eq getDir(dir => "conf", conf => $conf) && !$lock && !-e $file)
	{
		$file = NMISNG::Util::getFileName(file => getDir(dir => "conf_default", conf => $conf)."/$name", conf => $conf);
	}

	# no file? nothing to do but bail out
	return ("loadtable: $file does not exist or has bad permissions (dir=$dir name=$name)") if (!-e $file);

	my $externalDir = "$expandeddir/conf.d";
	if ($without_extension ne "Config") # Config is special, as it is saved in conf.d
	{
		$externalDir = "$externalDir/$without_extension";
	}
	my $externalFiles = NMISNG::Util::get_external_files(dir=>$externalDir);

	if ($lock) {
		my $table = NMISNG::Util::readFiletoHash(file=>$file, lock=>$lock, conf => $conf);

		foreach (@$externalFiles) {
			# Read and mix
			my $lock = NMISNG::Util::getbool($args{lock});
			my $extfile = NMISNG::Util::readFiletoHash(file=>$_, lock=>$lock, conf => $conf);
			$table = {%$table, %$extfile};
		}		
		return $table;
	}
	
	# look at the cache, does it have existing non-stale data?
	my $filetime = stat($file)->mtime;

	if (ref($cache{$file}) ne "HASH"
			|| $filetime != $cache{$file}->{mtime})
	{
		my $table = NMISNG::Util::readFiletoHash(file=>$file, conf => $conf);

		foreach (@$externalFiles) {
			# Read and mix
			my $extfile = NMISNG::Util::readFiletoHash(file=>$_, conf => $conf);
			$table = {%$table, %$extfile};
		}
		# nope, reread
		$cache{$file} = { "data" => $table,
											"mtime" => $filetime };
	}

	return $cache{$file}->{data};
}

# Returns data if it is 
# returns: undef or error message
sub has_external_files
{
	my %args = @_;
	my $dir = $args{dir};			# name of directory, semi-symbolic
	my $name = $args{name};	# name of table or short file name
	
	my $expandeddir = getDir(dir => $dir);
	my $externalDir = "$expandeddir/conf.d";
	if ($name ne "Config") # Config is special, as it is saved in conf.d
	{
		$externalDir = "$externalDir/$name";
	}
	my $externalFiles = NMISNG::Util::get_external_files(dir=>$externalDir);
	return scalar(@$externalFiles);
}

# writes data to file in question,
# returns: undef or error message
sub writeTable
{
	my %args = @_;
	my $dir = $args{dir};			# name of directory, semi-symbolic
	my $name = $args{name};	# name of table or short file name

	return "writeTable failed: no name specified"
			if (!defined($name) or $name eq "");

	return "writeTable failed: invalid dir=$dir specified with name=$name"
			if ($dir !~ /conf|models|var/);

	my $file = getDir(dir=>$dir)."/$name";

	if (my $error = NMISNG::Util::writeHashtoFile(file=>$file,
																								data=>$args{data},
																								handle=>$args{handle}))
	{
		return $error;
	}
	return undef;
}

# figures out the appropriate extension for a file, based
# on location, config and json arg
#
# args: file (relative) and dir, or file (full path), json (optional), only_extension (optional)
# variant with file+dir is used not commonly
#
# attention: this function name clashes with a function in rrdfunc.pm!
# ATTENTION: fixme dir logic is very very convoluted!
# fixme: passing json=false DOES NOT WORK if the config says use_json=true!
#
# returns absolute filename with extension
sub getFileName
{
	my %args = @_;
	my $json = NMISNG::Util::getbool($args{json});
	my $file = $args{file};
	my $dir = $args{dir};
	my $conf = $args{conf};

	my $C = $conf // loadConfTable();

	# are we in/under var? fixme unsafe and misleading
	my $fileundervar = ($dir and $dir =~ m!(^|/)var(/|$)!)
			|| ($file and $file =~ m!(^|/)var(/|$)!);

	my $conf_says_json = NMISNG::Util::getbool($C->{use_json});

	# all files: use json if the arg says so
	# var files: also use json if the config says so
	# defaults: no json
	if (($fileundervar and $conf_says_json) or $json )
	{
		return "json" if (NMISNG::Util::getbool($args{only_extension}));
		$file =~ s/\.nmis$//g;				# if somebody gave us a full but dud extension
		$file .= '.json' if $file !~ /\.json/;
	}
	else
	{
		return "nmis" if (NMISNG::Util::getbool($args{only_extension}));
		$file =~ s/\.json$//g;
		$file .= ".nmis" if $file !~ /\.nmis/;
	}
	$file = "$dir/$file" if ($dir);
	return $file;
}

# variant of the getFileName function, just returning the extension
# same arguments
# # fixme: passing json=false DOES NOT WORK if the config says use_json=true!
sub getExtension
{
	my (%args) = @_;
	my $C = $args{conf};
	
	return NMISNG::Util::getFileName(dir => $args{dir}, file => $args{file},
										 json => $args{json}, only_extension => 1, conf => $C);
}

# look up model file in models-custom, falling back to models-default,
# args: model (= model name, without extension),
#  only_mtime (optional, if set no data is returned)
#
# returns: hashref (success, error, data, is_custom, mtime)
# with success 1/0, error message, data structure, and is_custom is 1 if the model came from models-custom
# success is set IFF valid data came back.
# note: not exported.
sub getModelFile
{
	my (%args) = @_;
	return { error => "Invalid arguments: no model requested!" } if (!$args{model});

	my $C = $args{conf} // NMISNG::Util::loadConfTable();			# generally cached
	my ($iscustom, $modeldata);
	my $relfn = "$args{model}.nmis"; # the getFile logic is not safe.
	for my $choices ("models","default_models")
	{
		my $fn = getDir(dir => $choices, conf => $C)."/$relfn";
		if (-e $fn)
		{
			my $age = stat($fn)->mtime;

			return { success => 1, mtime => $age, is_custom => $iscustom } if ($args{only_mtime});

			# loadtable caches, therefore preferred over readfiletohash
			my $modeldata = NMISNG::Util::loadTable(dir => $choices, name => $relfn, conf => $C);
			return { error => "failed to read file $fn: $!" } if (ref($modeldata) ne "HASH"
																														or !keys %$modeldata);
			return { success => 1, data => $modeldata, is_custom => $iscustom, mtime => $age};
		}
	}
	return { error => "no model definition file available for model $args{model}!" };
}


# write hash data to file in suitable format
# returns: undef or error message
sub writeHashtoFile
{
	my %args = @_;
	my $file = $args{file};
	my $data = $args{data};
	my $handle = $args{handle}; # if handle specified then file is locked EX
	my $json = NMISNG::Util::getbool($args{json});

	my $C = $args{conf} // loadConfTable();

	# pretty printing: if arg given, that overrides config
	my $pretty = NMISNG::Util::getbool( (exists $args{pretty})? $args{pretty} : $C->{use_json_pretty} );

	my $conf_says_json = NMISNG::Util::getbool($C->{use_json});

	# handle _id getting into system - we save the stringified data,
	# not extended json.
	if( ref($data->{system}) eq "HASH"
			&& ref($data->{system}->{_id}) =~ /^(BSON|MongoDB)::OID$/)
	{
		# bson::oid has value() only for backwards compat,
		# offically supposed to use hex

		$data->{system}->{_id} = $data->{system}->{_id}->can("hex")?
				$data->{system}->{_id}->hex
				: $data->{system}->{_id}->value;
	}
	# all files: use json if the arg says so
	# var files: also use json if the config says so
	# defaults: no json
	my $useJson = ( ($file =~ m!(^|/)var(/|$)! and $conf_says_json)
									|| $json );
	$file = NMISNG::Util::getFileName(file => $file, json => $json, conf => $C);

	if ($handle eq "")
	{
		if (open($handle, "+<$file"))
		{
			flock($handle, LOCK_EX) or return("writeHashtoFile: can't lock $file: $!");

			seek($handle,0,0) or return("writeHashtoFile: can't seek in $file: $!");
			truncate($handle,0) or return("writeHashtoFileL can't truncate $file: $!");
		}
		else
		{
			open($handle, ">$file")  or return("writeHashtoFile: cannot write to $file: $!\n");
			flock($handle, LOCK_EX) or return("writeHashtoFile: can't lock file $file: $!\n");
		}
	}
	else
	{
		seek($handle,0,0) or return("writeHashtoFile: can't seek in $file: $!");
		truncate($handle,0) or return("writeHashtoFile: can't truncate $file: $!");
	}

	# write out the data, but defer error reporting until after the lock is released
	my $errormsg;
	if ( $useJson and $pretty )
	{
		# make sure that all json files contain valid utf8-encoded json, as required by rfc7159
		if ( not print $handle JSON::XS->new->utf8(1)->pretty(1)->encode($data) )
		{
			$errormsg = "cannot write data object to file $file: $!";
		}
	}
	elsif ( $useJson )
	{
		# encode_json already ensures utf8-encoded json
		eval { print $handle encode_json($data) } ;
		if ( $@ ) {
			$errormsg = "cannot write data object to $file: $@";
		}
	}
	elsif ( not print $handle Data::Dumper->Dump([$data], [qw(*hash)]) ) {
		$errormsg = "cannot write to file $file: $!";
	}
	close $handle;

	# now it's safe to handle the error
	return("writeHashtoFile: $errormsg")
			if ($errormsg);

	if (my $error = NMISNG::Util::setFileProtDiag(file =>$file, conf => $C))
	{
		return $error;
	}
	return undef;
}


### read file containing data generated by writeFileToHash
# file structure must be hash, format can be perl or json
#
# args: file, lock, json
#
# fixme: passing json=false DOES NOT WORK if the config says use_json=true
#
# returns: (hashref-or-errormsg, handle) if lock is given,
# returns: hashref-or-errormsg if lock wasn't given
#
# errors are signalled by returning the error message text,
# do check ref() on the result.
#
sub readFiletoHash
{
	my %args = @_;

	my $file = $args{file};
	my $lock = NMISNG::Util::getbool($args{lock}); # option
	my $json = NMISNG::Util::getbool($args{json}); # also optional
	my $conf = $args{conf};

	my (%hash, $handle, $line);

	# gefilename=getextension applies this heuristic:
	# all files: use json if args say so
	# files in and under var: also use json if config says so
	# default: no json
	$file = NMISNG::Util::getFileName(file => $file, json => $json, conf => $conf);
	my $useJson = NMISNG::Util::getExtension(file => $file, json => $json, conf => $conf) eq "json";

	return "No file argument given!" if (!$file); # no or dud args...

	if ( -r $file )
	{
		my $filerw = $lock ? "+<$file" : "<$file";
		my $lck = $lock ? LOCK_EX : LOCK_SH;
		if (open($handle, "$filerw"))
		{
			flock($handle, $lck) or return("readFiletoHash: can't lock $file: $!");
			local $/ = undef;
			my $data = <$handle>;

			if ( $useJson )
			{
				# be liberal in what we accept: latin1 isn't an allowed encoding for json,
				# but fall back to that before giving up
				my $hashref = eval { decode_json($data); };
				my $gotcha = $@;

				#  utf8 failed but latin1 works?
				if ($gotcha)
				{
					$hashref = eval { JSON::XS->new->latin1(1)->decode($data); };
				}
				return "readFiletoHash failed: cannot convert $file to hash table: $@" if ($@);

				# report invalid data
				if ((my $whatisit = ref($hashref)) ne "HASH")
				{
					return "readFiletoHash failed: resulting structure is a $whatisit";
				}
				return ($hashref,$handle) if ($lock);

				close $handle;
				return $hashref;
			}
			else											# perl
			{
				# convert data to hash. this is really very yucky.
				%hash = eval $data;
				if ($@)
				{
					return("readFiletoHash failed to convert $file to hash table: $@");
				}
				return (\%hash, $handle) if ($lock);

				close $handle;
				return \%hash;
			}
		}
		else
		{
			return("readFiletoHash: cannot open $file: $!");
		}
	}
	else # nx file
	{
		if ($lock)
		{
			# create new empty file, otherwise we can't return a lock
			open ($handle,">", "$file") or return("readFiletoHash: can't create $file: $!");
			flock($handle, LOCK_EX) or return("readFiletoHash: can't lock file $file: $!");
			return (\%hash,$handle);
		}

		return "readFiletoHash failed to access $file: $!";
	}
}


#-----------------------------------
# NMISNG::Util::logAuth2(message,level)
# message: message text
# level: [0..7] or string in [EMERG,ALERT,CRITICAL,ERROR,WARNING,NOTICE,INFO,DEBUG]
# if level < 0, use 0;
# if level > 7 or any string not in the group, use 7
# case insensitive
# arbitrary strings can be used (only at debug level)
# Only messages below $maxlevel are printed
# fixme9: this function doesn't do what it claims: the second argument, level, is utterly ignored
# therefore simplified to wrap logAuth()
sub logAuth2
{
	my ($msg,$level) = @_;
	return logAuth($msg);
}

# message with (class::)method names and line number
# returns: undef or error message
sub logAuth
{
	my $msg = shift;
	my $C = loadConfTable;

	my $handle;
	my $string = &NMISNG::Log::trace();

	$string .= "<br>$msg";
	$string =~ s/\n/ /g;      #remove all embedded newlines

	open($handle,">>$C->{auth_log}") or return " logAuth, Couldn't open log file $C->{auth_log}. $!";
	flock($handle, LOCK_EX)  or return "logAuth, can't lock filename: $!";
	print $handle NMISNG::Util::returnDateStamp().",$string\n" or return " logAuth, can't write file $C->{auth_log}. $!";
	close $handle;
	if (my $error = NMISNG::Util::setFileProtDiag(file =>$C->{auth_log}))
	{
		return $error;
	}
	return undef;
}

sub logPolling {
	my $msg = shift;
	my $conf = shift;
	my $C = $conf // loadConfTable;
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
		print $handle NMISNG::Util::returnDateStamp().",$msg\n" or warn returnTime." logPolling, can't write file $C->{polling_log}. $!\n";
		close $handle or warn "logPolling, can't close filename: $!";
		NMISNG::Util::setFileProtDiag(file =>$C->{polling_log});
	}
}

# normal op: compares first argument against true or 1 or yes
# opposite: compares first argument against false or 0 or no
#
# this opposite stuff is needed for handling "XX ne false",
# which is 1 if XX is undef and thus not the same as !NMISNG::Util::getbool(XX,0)
#
# usage: eq true => getbool, ne true => !getbool,
# eq false => NMISNG::Util::getbool(...,invert), ne false => !NMISNG::Util::getbool(...,invert)
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

#########################################################################
# Check boolean for CLI input.  It will not default an assumed value    #
#  when the user may have not intended the action.  This function       #
#  expects the key name, variable name, and default value.  It will die #
#  with an error message if the value is not a valid boolean value.     #
#                                                                       #
#  The function will accept the following and i not case sesitive:      #
#  true, yes, t, y, 1, false, no, f, or n                               #
#                                                                       #
#########################################################################
sub getbool_cli
{
	my ($key, $val, $default) = @_;
	$default = 0 if !defined($default);

	return ((defined($val)) ? (($val =~ /true|yes|t|y|1/i) ? 1 : (($val =~ /false|no|f|n|0/i) ? 0 : die "Invalid boolean value for '$key': '$val'\n" )) : $default);
}

# Send an array with the properties never overrided by the conf master files
# Hardcoded as we dont want them to be overrided
# Could be a mess
sub properties_never_override
{
	my @properties = ('cluster_id', 'server_name', 'nmis_host');
	return \@properties;
}

# trivial wrapper around readfiletohash
# difference to loadConfTable: loadconftable flattens and adds a few entries
# args: only_local eq 1 loads only local config (Not by default)
# returns: hashref-or-errormessage, file name
sub readConfData
{
	my %args = @_;

	my $C = loadConfTable;
	my $fn = $C->{configfile};
	
	my $rawdata = NMISNG::Util::readFiletoHash(file => $fn);

	my $fnp = $C->{configpeerfiles};
	my $nmisng = Compat::NMIS::new_nmisng();
	
	if ($args{only_local} ne 1)
	{
		$nmisng->log->info("Reading config properties from master. ");
		eval {
			foreach ( @{$fnp} ) {
			
				my $rawpartialdata = NMISNG::Util::readFiletoHash(file => $_);
		
				# strip the outer of two levels, does not flatten any deeper structure
				# merge
				for my $k (keys %{$rawpartialdata})
				{
					for my $kk (keys %{$rawpartialdata->{$k}})
					{
						if (ref($rawpartialdata->{$k}->{$kk}) ne "HASH" )
						{
							next if (grep( /^$kk$/, properties_never_override()));
							$rawdata->{$k}->{$kk} =$rawpartialdata->{$k}->{$kk};
						}
						else
						{
							# FIXME: Support nested config values
							$nmisng->log->warn($kk . " is a hash. Not being merged");
						}
					}
				}
			}
		}; if ($@) { $nmisng->log->warn("Error reading config peer files. Show local config " . $@); }
	}

	return ($rawdata, $fn);
}

# trivial wrapper around writeHashtoFile
# args: data, required
# returns: undef or error message
sub writeConfData
{
	my %args = @_;
	my $CC = $args{data};

	my $C = NMISNG::Util::loadConfTable();
	my $configfile = $C->{configfile};

	# save old one
	File::Copy::cp($configfile, "$configfile.bak") # this overwrites any existing backup file
			if (-r "$configfile");

	return NMISNG::Util::writeHashtoFile(file=>$configfile, data=>$CC);
}

# creates the dir in question, and all missing intermediate
# directories in the path; also sets ownership up to nmis_base.
sub createDir
{
	my ($dir) = @_;

	my $C = NMISNG::Util::loadConfTable(); # normally cached

	if ( not -d $dir )
	{
		my $permission = $C->{'os_execperm'} || "0770"; # fixme dirperm should be separate from execperm...

		my $umask = umask(0);
		mkpath($dir, {verbose => 0, mode => oct($permission)});
		umask($umask);
		setFileProtParents($dir);
	}
}

# checks the ownerships and permissions on one directory
# args: directory, options hash
# fixme: currently ignores options, should support non-strictperms)
#
# returns: (1, info msg list) or (0, error message list)
sub checkDir
{
	my ($dir, %opts) = @_;

	my $result = 1;
	my (@messages, @problems);

	my $C = NMISNG::Util::loadConfTable();

	# Does the directory exist
	return (0, "ERROR: directory $dir does not exist") if (!-d $dir);

	my $dstat = stat($dir);
	my $gid = $dstat->gid;
	my $uid = $dstat->uid;
	my $mode = $dstat->mode;

	my ($groupname,$passwd,$gid2,$members) = getgrgid $gid;
	my $username = getpwuid($uid);

	# Are the user and group permissions correct.
	my $user_rwx = ($mode & S_IRWXU) >> 6;
	my $group_rwx = ($mode & S_IRWXG) >> 3;

	if ( $user_rwx ) {
		push(@messages,"INFO: $dir has user read-write-execute permissions");
	}
	else {
		$result = 0;
		push(@problems,"ERROR: $dir does not have user read-write-execute permissions");
	}

	if ( $group_rwx ) {
		push(@messages,"INFO: $dir has group read-write-execute permissions");
	}
	else {
		$result = 0;
		push(@problems,"ERROR: $dir does not have group read-write-execute permissions");
	}

	if ( $C->{'nmis_user'} eq $username ) {
		push(@messages,"INFO: $dir has correct owner from config nmis_user=$username");
	}
	else {
		$result = 0;
		push(@problems,"ERROR: $dir DOES NOT have correct owner from config nmis_user=$C->{'nmis_user'} dir=$username");
	}

	if ( $C->{'nmis_user'} eq $username ) {
		push(@messages,"INFO: $dir has correct owner from config nmis_user=$username");
	}
	else {
		$result = 0;
		push(@problems,"ERROR: $dir DOES NOT have correct owner from config nmis_user=$C->{nmis_user} dir=$username");
	}

	if ( $C->{'nmis_group'} eq $groupname ) {
		push(@messages,"INFO: $dir has correct owner from config nmis_group=$groupname");
	}
	else {
		$result = 0;
		push(@problems,"ERROR: $dir DOES NOT have correct owner from config nmis_group=$C->{'nmis_group'} dir=$groupname");
	}

	return ($result, ($result? @messages : @problems));
}

# checks the characteristics of ONE file
# args: file (full path), options hash
# options: checksize (optional, default: yes)
# strictperms (optional, default: yes),
# if off, SUFFICIENT perms for user+group nmis are ok,
# if on, PRECISELY the standard perms and ownerships are accepted as ok
#
# returns: (1, list of messages) if ok or (0, list of problem messages)
sub checkFile
{
	my ($file, %opts) = @_;

	my $result = 1;
	my (@messages, @problems);

	my $C = NMISNG::Util::loadConfTable();
	my $prettyfile = File::Spec->abs2rel(Cwd::abs_path($file), $C->{'<nmis_base>'});

	# does it even exist?
	return (0, "ERROR: file $prettyfile ($file) does not exist") if ( not -f $file );

	my $fstat = stat($file);

	# size check - default is yes
	if ( !NMISNG::Util::getbool($opts{checksize}, "invert")
			 && $C->{file_size_warning}
			 && $fstat->size > $C->{'file_size_warning'})
	{
		$result = 0;
		push(@problems,"WARN: $prettyfile is ".$fstat->size." bytes, larger than $C->{'file_size_warning'} bytes");
	}

	my $groupname = getgrgid($fstat->gid);
	my $username = getpwuid($fstat->uid);
	my $mode = $fstat->mode & (S_IRWXU|S_IRWXG|S_IRWXO); # only want u/g/o perms, not type, not setX

	my $should_be_executable = $C->{nmis_executable}?
			qr/$C->{nmis_executable}/
			: qr!(/(bin|admin|install/scripts|conf/scripts)/[a-zA-Z0-9_\\.-]+|\\.pl|\\.sh)$!i;

	# permissions, strict or sufficient? default is strict
	if (!NMISNG::Util::getbool($opts{strictperms},"invert"))
	{
		# strict: owner and group must be exact matches
		if ( $C->{'nmis_user'} eq $username )
		{
			push(@messages,"INFO: $prettyfile has correct owner $username");
		}
		else
		{
			$result = 0;
			push(@problems,"ERROR: $prettyfile owned by user $username, not correct owner $C->{nmis_user}");
		}

		if ( $C->{'nmis_group'} eq $groupname ) {
			push(@messages,"INFO: $prettyfile has correct group $groupname");
		}
		else
		{
			$result = 0;
			push(@problems,"ERROR: $prettyfile owned by group $groupname, not correct group $C->{nmis_group}");
		}

		my ($text,$wanted) = ($file =~ $should_be_executable)?
				("exec", oct($C->{os_execperm})) : ("file", oct($C->{os_fileperm}));

		# exactly os_execperm/os_fileperm is accepted
		if ($mode != $wanted)
		{
			$result = 0;
			my @grants;
			push @grants, "FEWER" if ($wanted & $mode) != $wanted;
			push @grants, "MORE" if ($wanted | $mode) != $wanted;
			push @problems, sprintf("ERROR: $prettyfile has incorrect %s perms 0%o: grants %s rights than correct 0%o",
															$text, $mode, join(" and ", @grants), $wanted);
		}
		else
		{
			push @messages, sprintf("INFO: $prettyfile has correct %s perms 0%o", $text, $mode);
		}
	}
	else													# lenient/sufficient mode selected
	{
		# the nmis group must match; user isn't critical
		if ( $C->{'nmis_group'} eq $groupname )
		{
			push(@messages,"INFO: $prettyfile has correct group $groupname");
		}
		else
		{
			$result = 0;
			push(@problems,"ERROR: $prettyfile owned by group $groupname, not correct group $C->{nmis_group}");
		}

		# check that: the nmis group can rwx, or that the nmis group can rw
		my ($text,$wanted) = ($file =~ $should_be_executable)?
				("exec", oct($C->{os_execperm}))
				: ("file", oct($C->{os_fileperm}));
		my $reducedmode = $mode & S_IRWXG;

		# only check that not less rights than the sufficient ones are granted
		if (($reducedmode & $wanted & S_IRWXG) != ($wanted & S_IRWXG))
		{
			$result = 0;
			push @problems, sprintf("ERROR: $prettyfile has insufficient group %s perms 0%o: grants fewer rights than correct 0%o",
															$text, $mode, $wanted);
		}
		else
		{
			push @messages, sprintf("INFO: $prettyfile has sufficient group %s perms 0%o", $text, $mode);
		}
	}

	return ($result, ($result? @messages : @problems));
}

# checks the files and dirs under the given directory (optionally recurses)
# args: directory, options hash
# options: recursive (default: false),
# all options are passed through to checkFile and checkDir
#
# returns: (1, info msg list) or (0, error message list)
# note: skips all dotfiles and dotdirs
sub checkDirectoryFiles
{
	my ($dir, %opts) = @_;
	my $result = 1;
	my (@messages, @problems);

	return (0, "ERROR: $dir is not a directory!") if (!-d $dir);

	opendir (DIR, $dir) or die "Cannot open dir $dir: $!\n";
	my @dirlist = readdir DIR;
	closedir DIR;

	foreach my $thing (@dirlist)
	{
		next if ($thing =~ /^\./);
		my $func;

		if (-d "$dir/$thing")
		{
			if (NMISNG::Util::getbool($opts{recurse}))
			{
				$func=\&checkDirectoryFiles;
			}
			else
			{
				$func= \&checkDir;
			}
		}
		elsif (-l "$dir/$thing" || -f "$dir/$thing")
		{
			$func=\&checkFile;
		}
		else
		{
			next;										# ignore unexpected file types
		}

		my ($newstatus, @newmsgs) = &$func("$dir/$thing", %opts);
		if ($newstatus)
		{
			push @messages, @newmsgs;
		}
		else
		{
			push @problems, @newmsgs;
		}
		$result = 0 if (!$newstatus);
	}
	return ($result, ($result? @messages : @problems));
}

# checks and adjusts the ownership and permissions on given dir X
# and all files directly within it. if recurse is given, then
# subdirs below X are also checked recursively.
#
# returns: list of errors, may be empty
sub setFileProtDirectory
{
	my $dir = shift;
	my $recurse = shift;
	my $conf = shift;

	my @problems;

	if ( $recurse eq "" ) {
		$recurse = 0;
	}
	else {
		$recurse = NMISNG::Util::getbool($recurse);
	}

	# the dir itself must be checked and fixed, too!
	if (my $error = NMISNG::Util::setFileProtDiag(file =>$dir, conf => $conf))
	{
		push @problems, $error;
	}

	opendir (DIR, "$dir") or push @problems, "cannot open directory $dir: $!";
	my @dirlist = readdir DIR;
	closedir DIR;

	foreach my $file (@dirlist)
	{
		if ( -f "$dir/$file" and $file !~ /^\./ )
		{
			if (my $error = NMISNG::Util::setFileProtDiag(file =>"$dir/$file", conf => $conf))
			{
				push @problems, $error;
			}
		}
		elsif ( -d "$dir/$file" and $recurse and $file !~ /^\./ )
		{
			if (my $error = NMISNG::Util::setFileProtDiag(file =>"$dir/$file", conf => $conf))
			{
				push @problems, $error;
			}
			push @problems, NMISNG::Util::setFileProtDirectory("$dir/$file",$recurse, conf => $conf);
		}
	}
	return @problems;
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

sub colorPercentHi
{
	my $val = shift;
	if ( $val =~ /^(\d+|\d+\.\d+)$/ ) {
		$val = 100 - int($val);
		return sprintf("#%2.2X%2.2X00",
									 int(List::Util::min($val*2*2.55,255)),
									 int(List::Util::min( (100-$val)*2*2.55,255)));
	}
	else {
		return '#AAAAAA';
	}
}

sub colorPercentLo
{
	my $val = shift;
	if ( $val =~ /^(\d+|\d+\.\d+)$/ ) {
		$val = int($val);
		return sprintf("%2.2X%2.2X00", int(List::Util::min($val*2*2.55,255)),
									 int(List::Util::min( (100-$val)*2*2.55,255)));
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
	return sprintf("#%2.2X%2.2X00", int((($val/255)*$ratio)), int((($thresh-$val)/255)*$ratio));
}

sub checkPerlLib {
	my $lib = shift;

	my $path = $lib;
	$path =~ s/\:\:/\//g;

	if ( $path !~ /\.pm$/ ) {
		$path .= ".pm";
	}

	#check the USE path for the file.
	foreach my $libdir (@INC) {
		return 1 if (-f "$libdir/$path");
	}
	return 0;
}


# a quick selftest function to verify that the runtime environment is ok
# updates the selftest status cache file, also manages var/nmis_system/dbdir_full marker
#
# args: nmisng (live object),
#  delay_is_ok (= whether iostat and cpu computation are allowed to delay
#  for a few seconds, default: no),
#  optional perms (default: 0, if 1 CRITICAL permissions are checked)
#
# returns: (all_ok, arrayref of array of test_name => error message or undef if ok)
sub selftest
{
	my (%args) = @_;
	my @details;

	# bsts fallback is a bit ugly, also assumes caller has loaded compat::nmis
	my $nmisng = $args{nmisng} || Compat::NMIS::new_nmisng();
	my $config = $nmisng->config;

	return (0,{ "Config missing" =>  "cannot perform selftest without configuration!"})
			if (ref($config) ne "HASH" or !keys %$config);
	my $candelay = NMISNG::Util::getbool($args{delay_is_ok});
	my $wantpermsnow = NMISNG::Util::getbool($args{perms});

	# always verify and fix-up the most critical file permissions: config dir,
	# custom models dir, var dir
	NMISNG::Util::setFileProtDirectory($config->{'<nmis_conf>'},1, $config );    # do recurse
	NMISNG::Util::setFileProtDirectory($config->{'<nmis_var>'},0, $config );  # no recursion
	NMISNG::Util::setFileProtDirectory($config->{'<nmis_models>'},0, $config )
			if (-d $config->{'<nmis_models>'});														# dir isn't necessarily present

	my $varsysdir = "$config->{'<nmis_var>'}/nmis_system";
	if ( !-d $varsysdir )
	{
		NMISNG::Util::createDir($varsysdir);
		NMISNG::Util::setFileProtDiag(file =>$varsysdir, conf => $config);
	}
	my $statefile = "$varsysdir/selftest.json"; # name also embedded in nmisd and gui
	my $laststate = NMISNG::Util::readFiletoHash( file => $statefile, json => 1, conf => $config );
	if (ref($laststate) ne "HASH")
	{
		$nmisng->log->warn("failed to read selftest $statefile: $laststate");
		$laststate = { tests => [] };
	}
	my $dbdir_full = "$varsysdir/dbdir_full"; # marker file name also embedded in rrdfunc.pm
	unlink($dbdir_full);											# assume the database dir passes...until proven otherwise

	my $allok=1;

	# check that we have a new enough RRDs module
	my $minversion=version->parse("1.4004");
	my $testname="RRDs Module";
	my $curversion;
	eval {
		&NMISNG::rrdfunc::require_RRDs;
		$curversion = version->parse($RRDs::VERSION);
	};
	if ($@)
	{
		$nmisng->log->debug("RRDs module test failed: $@");
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
	push @details, [$testname, $result];
	$allok = 0 if ($result);

	# check the main/involved directories AND /tmp and /var
	my $minfreepercent = $config->{selftest_min_diskfree_percent} || 10;
	my $minfreemegs = $config->{selftest_min_diskfree_mb} || 25;
	# do tmp and var last as we skip already seen ones
	my %fs_ids;
	for my $dir (@{$config}{'<nmis_base>','<nmis_var>',
													'<nmis_logs>','database_root'}, "/tmp","/var")
	{
		my $statresult = stat($dir);
		# nonexistent dir or seen that filesystem? ignore
		next if (!$statresult or $fs_ids{$statresult->dev});
		$fs_ids{$statresult->dev} = 1;

		my $testname = "Free space in $dir";
		my @df = `df -mP $dir 2>/dev/null`;
		if ($? >> 8)
		{
			push @details, [$testname, "Could not determine free space: $!"];
			$allok=0;
			next;
		}
		# Filesystem       1048576-blocks  Used Available Capacity Mounted on
		my (undef,undef,undef,$remaining,$usedpercent,undef) = split(/\s+/,$df[1]);
		$usedpercent =~ s/%$//;
		if (100-$usedpercent < $minfreepercent)
		{
			push @details, [$testname, "Only ".(100-$usedpercent)."% free in $dir!"];
			if ($dir eq $config->{"database_root"})
			{
				open(F, ">$dbdir_full") && close(F);
			}
			$allok=0;
		}
		elsif ($remaining < $minfreemegs)
		{
			push @details, [$testname, "Only $remaining Megabytes free in $dir!"];
			unlink($dbdir_full) if ($dir eq $config->{"database_root"});
			$allok=0;
		}
		else
		{
			push @details, [$testname, undef];
		}
	}

	$testname = "Permissions";
	if ($wantpermsnow)
	{
		# check the permissions, but only the most critical aspects: don't bother with precise permissions
		# as long as the nmis user and group can work with the dirs and files
		# code is same as type=audit (checkConfig), but better error handling
		my @permproblems;

		# flat dirs first
		my %done;
		for my $location ($config->{'<nmis_data>'}, # commonly same as base
											$config->{'<nmis_base>'},
											$config->{'<nmis_admin>'}, $config->{'<nmis_bin>'}, $config->{'<nmis_cgi>'},
											$config->{'<nmis_models>'},
											$config->{'<nmis_logs>'},
											$config->{'log_root'}, # should be the same as nmis_logs
											$config->{'config_logs'},
											$config->{'json_logs'},
											$config->{'<menu_base>'},
											$config->{'report_root'},  )
		{
			my $where = Cwd::abs_path($location);
			next if ($done{$where});

			my ($status, @msgs) = NMISNG::Util::checkDirectoryFiles($location,
																								recurse => "false",
																								strictperms => "false",
																								checksize =>  "false" );
			if (!$status)
			{
				push @permproblems, @msgs;
			}
			$done{$where} = 1;
		}

		# deeper dirs with recursion
		%done = ();
		for my $location ($config->{'<nmis_base>'}."/lib",
											$config->{'<nmis_conf>'},
											$config->{'<nmis_var>'},
											$config->{'<nmis_menu>'},
											$config->{'mib_root'},
											$config->{'database_root'},
											 )
		{
			my $where = Cwd::abs_path($location);
			next if ($done{$where});

			my ($status, @msgs) = NMISNG::Util::checkDirectoryFiles($location,
																								recurse => "true",
																								strictperms => "false",
																								checksize =>  "false" );
			if (!$status)
			{
				push @permproblems, @msgs;
			}
			$done{$where} = 1;
		}

		if (@permproblems)
		{
			$allok=0;
			push @details, [$testname, join("\n", @permproblems)];
		}
		else
		{
			push @details, [$testname, undef];
		}
	}
	else
	{


		# keep the old permission test result as-is
		my $prev = List::Util::first { $_->[0] eq $testname } (@{$laststate->{tests}});
		push @details, $prev // [ $testname, undef ];
	}

	# check the number of nmis processes, complain if above limit
	my $ptable = Proc::ProcessTable->new(enable_ttys => 0);

	# all nmisd processes are calling themselves 'nmisd something'
	# opcharts 3's nmisd calls itself 'nmisd',
	# 'nmisd worker' or 'nmisd collector <something>' - exclude these
	my @ourprocs = grep($_->cmndline =~ /^nmisd.(fping|scheduler|worker.+)\s*$/,
											@{$ptable->table});
	if (NMISNG::Util::getbool($config->{nmisd_fping_worker}))
	{
		my $status = (List::Util::any { $_->cmndline =~ /^nmisd.fping\s*$/ } @ourprocs)?
				undef : "No fping worker seems to be running!";
		push @details, ["FastPing worker", $status];
		$allok = 0 if ($status);
	}

	my $nr_procs = @ourprocs;
	my $max_nmis_processes = 1 		# the scheduler
			+ (NMISNG::Util::getbool($config->{nmisd_fping_worker})? 1:0) # the fping worker
			+ $config->{nmisd_max_workers} * 1.1; # the configured workers and 10% extra for transitionals
	my $status;
	if ($nr_procs > $max_nmis_processes)
	{
		$status = "Too many NMIS processes running: current count $nr_procs";
		$allok=0;
	}
	elsif (!$nr_procs)
	{
		$status = "No NMIS workers running!";
		$allok=0;
	}
	push @details, ["NMIS process count",$status];

	# check that there is an nmis scheduler running
	my $schedstatus = (grep($_->cmndline =~ /^nmisd.scheduler\s*$/, @ourprocs))?
			undef : "No scheduler process running!";
	push @details, ["NMIS daemon", $schedstatus];

	# check that there is some sort of cron running
	my $cron_name = $config->{selftest_cron_name}?
			qr/$config->{selftest_cron_name}/ : qr!(^|/)crond?$!;

	my $cron_status = (grep($_->fname =~ $cron_name, @{$ptable->table})?
										 undef : "No CRON daemon seems to be running!");
	push @details, ["CRON daemon",$cron_status];
	$allok = 0 if ($cron_status);

	# check iowait and general busyness of the system
	# however, do that ONLY if we are allowed to delay for a few seconds
	# (otherwise we get only the avg since boot!)
	if ($candelay && -f '/proc/stat')
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
	if( -f '/proc/meminfo')
	{
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
	}

	# check the last operation completion for update and collect, see if it was too long ago
	for (['update', 'Update', $config->{selftest_max_update_age} || 604800 ], # 1 week
			 ['collect', 'Collect', $config->{selftest_max_collect_age} || 3600 ], ) # 1 hr
	{
		my ($op, $name, $maxage)  = @$_;

		my $mostrecent = $nmisng->get_opstatus_model(activity => $op,
																								 # failure is always an option...actually ok here
																								 status => { '$ne' => "inprogress" },
																								 sort => { 'time' => -1 },
																								 limit => 1);
		my $status = undef;
		my $last_time = $mostrecent->data->[0]->{time}

		if (!$mostrecent->error && $mostrecent->data);
		if ($mostrecent->error or !$mostrecent->count)
		{
			$status = "Could not determine last $name status";
			$allok = 0;
		}
		elsif ($last_time < time - $maxage)
		{
			$status = "Last $op completed too long ago, at "
					.NMISNG::Util::returnDateStamp($last_time);
			$allok = 0;
		}
		# put these two the beginning
		unshift @details, ["Last $name", $status];
	}

	# update the status
	NMISNG::Util::writeHashtoFile(
		file => $statefile,
		json => 1,
		data => {status => $allok,
						 lastupdate => time,
						 lastupdate_perms => ( $wantpermsnow? time : $laststate->{lastupdate_perms}),
						 tests => \@details }
			);

	return ($allok, \@details);
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

# takes binary encoded DateAndTime snmp value,
# translates into fractional seconds in gmt
# args: 0xhexstring or real binary string,
# returns: fractional seconds in gmt
# note: not exported.
sub parse_dateandtime
{
	my ($dateandtime) = @_;
	# see https://tools.ietf.org/html/rfc1443 for format

	if ($dateandtime =~ /^0x([a-f0-9]+)$/i)
	{
		$dateandtime = pack("H*", $1);
	}

	# raw binary? length 8 or length 11 (with timezone)
	if (length($dateandtime) == 8 or length($dateandtime) == 11)
	{
		my ($year,$month,$day,$hour,$min,$sec,$decisec,
				$sign,$offhour,$offminutes) = unpack("nC6a1C2",$dateandtime);

		my $seconds = Time::Local::timegm($sec,$min,$hour, $day, $month-1,$year)
				+ $decisec/10;
		if ($sign && defined($offminutes) && defined($offhour))
		{
			$seconds += ($sign eq "+"? -1 : 1) * ($offhour * 3600 + $offminutes * 60);
		}
		return $seconds;
	}
	else
	{
		return undef;
	}
}

# this function creates a new uuid
# if uuid namespaces are configured: either the optional node argument is used,
# or a random component is added to make the namespaced uuid work. not relevant
# for totally random uuids.
#
# args: node, optional
# returns: uuid string
sub getUUID
{
	my ($maybenode) = @_;
	my $C = NMISNG::Util::loadConfTable();

	# translate between data::uuid and uuid::tiny namespace constants for config-compat,
	# as the config file uses namespace_<X> (url,dns,oid,x500) in data::uuid,
	# corresponds to UUID_NS_<X> in uuid::tiny
	state $known_namespaces= { map { my $varname = "UUID_NS_$_";
																	 ("NameSpace_$_" => UUID::Tiny->$varname,
																		$varname => UUID::Tiny->$varname) } (qw(DNS OID URL X500)) };

	#'uuid_namespace_type' => 'NameSpace_URL' OR "UUID_NS_DNS"
	#'uuid_namespace_name' => 'www.domain.com' AND we need to add the nodename to make it unique,
	# because if namespaced, then name is the ONLY thing controlling the resulting uuid!
	my $uuid;

	if ( $known_namespaces->{$C->{'uuid_namespace_type'}}
			 and defined($C->{'uuid_namespace_name'})
			 and $C->{'uuid_namespace_name'}
			 and $C->{'uuid_namespace_name'} ne "www.domain.com" ) # the shipped example default...
	{
		# namespace prefix plus node name or random component
		my $nodecomponent = $maybenode || create_uuid(UUID_RANDOM);
		$uuid = create_uuid_as_string(UUID_V5, $known_namespaces->{$C->{uuid_namespace_type}},
																	$C->{uuid_namespace_name}.$nodecomponent);
	}
	else
	{
		$uuid = create_uuid_as_string(UUID_RANDOM);
	}

	return $uuid;
}

# create a new namespaced uuid from concat of all components that are passed in
# if there's a configured namespace prefix that is used; otherwise
# the UUID_NS_URL is used w/o prefix.
#
# args: list of components
# returns: uuid string
sub getComponentUUID
{
	my @components = @_;

	my $C = NMISNG::Util::loadConfTable();

	# translate between data::uuid and uuid::tiny namespace constants for config-compat,
	# as the config file uses namespace_<X> (url,dns,oid,x500) in data::uuid,
	# corresponds to UUID_NS_<X> in uuid::tiny
	state $known_namespaces = { map { my $varname = "UUID_NS_$_";
															("NameSpace_$_" => UUID::Tiny->$varname,
															 $varname => UUID::Tiny->$varname) } (qw(DNS OID URL X500)) };

	my $uuid_ns = $known_namespaces->{"NameSpace_URL"};
	my $prefix = '';
	$prefix = $C->{'uuid_namespace_name'} if ( $known_namespaces->{$C->{'uuid_namespace_type'}}
																						 and defined($C->{'uuid_namespace_name'})
																						 and $C->{'uuid_namespace_name'}
																						 and $C->{'uuid_namespace_name'} ne "www.domain.com" );

	return create_uuid_as_string(UUID_V5, $uuid_ns, join('', $prefix, @components));
}

sub getComponentUUIDConf
{
	my %args = @_;
	my @components = $args{components};
	my $conf = $args{conf};

	my $C = $conf // NMISNG::Util::loadConfTable();

	# translate between data::uuid and uuid::tiny namespace constants for config-compat,
	# as the config file uses namespace_<X> (url,dns,oid,x500) in data::uuid,
	# corresponds to UUID_NS_<X> in uuid::tiny
	state $known_namespaces = { map { my $varname = "UUID_NS_$_";
															("NameSpace_$_" => UUID::Tiny->$varname,
															 $varname => UUID::Tiny->$varname) } (qw(DNS OID URL X500)) };

	my $uuid_ns = $known_namespaces->{"NameSpace_URL"};
	my $prefix = '';
	$prefix = $C->{'uuid_namespace_name'} if ( $known_namespaces->{$C->{'uuid_namespace_type'}}
																						 and defined($C->{'uuid_namespace_name'})
																						 and $C->{'uuid_namespace_name'}
																						 and $C->{'uuid_namespace_name'} ne "www.domain.com" );

	return create_uuid_as_string(UUID_V5, $uuid_ns, join('', $prefix, @components));
}

# this function translates a toplevel hash with fields in dot-notation
# into a deep structure. this is primarily needed in deep data objects
# handled by the crudcontroller but not necessarily just there.
#
# notations supported: fieldname.number for array,
# fieldname.subfield for hash and nested combos thereof
#
# args: resource record ref to fix up, which will be changed inplace!
# returns: undef if ok, error message if problems were encountered
sub translate_dotfields
{
	my ($resource) = @_;
	return "toplevel structure must be hash, not ".ref($resource) if (ref($resource) ne "HASH");

	# we support hashkey1.hashkey2.hashkey3, and hashkey1.NN.hashkey2.MM
	for my $dotkey (grep(/\./, keys %{$resource}))
	{
		my $target = $resource;
		my @indir = split(/\./, $dotkey);
		for my $idx (0..$#indir) # span the intermediate structure
		{
			my $thisstep = $indir[$idx];
			# numeric? make array, textual? make hash
			if ($thisstep =~ /^\d+$/)
			{
				# check that structure is ok.
				return "data conflict with $dotkey at step $idx: need array but found ".(ref($target) || "leaf value")
						if (ref($target) ne "ARRAY");
				# last one? park value
				if ($idx == $#indir)
				{
					$target->[$thisstep] = $resource->{$dotkey};
				}
				else
				{
					# check what the next one is and prime the obj
					$target = $target->[$thisstep] ||= ($indir[$idx+1] =~ /^\d+$/? []:  {} );
				}
			}
			else											# hash
			{
				# check that structure is ok.
				return "data conflict with $dotkey at step $idx: need hash but found ". (ref($target) || "leaf value")
						if (ref($target) ne "HASH");
				# last one? park value
				if ($idx == $#indir)
				{
					$target->{$thisstep} = $resource->{$dotkey};
				}
				else
				{
					# check what the next one is and prime the obj
					$target = $target->{$thisstep} ||= ($indir[$idx+1] =~ /^\d+$/? []:  {} );
				}
			}
		}
		delete $resource->{$dotkey};
	}
	return undef;
}

# this function flattens a toplevel hash structure into a flat hash of dotted fields
# args: data (hashref or array ref), prefix (optional, if set each field name starts with "prefix.")
# if data is array ref then prefix is required or you'll get ugly ".0.bla", ".1.blu" etc.
#
# hashes, arrays, mongodb/bson::oid, mongodb::binary/bson::bytes, and (json::xs::)booleans are supported
# oids are stringified, binary data is returned as-is, and booleans are transformed into 1 or 0.
#
# returns: (undef, flattened hash) or (error message)
sub flatten_dotfields
{
	my ($deep, $prefix) = @_;
	my %flatearth;

	$prefix = (defined $prefix? "$prefix." : "");

	if (ref($deep) eq "HASH")
	{
		for my $k (keys %$deep)
		{
			if (ref($deep->{$k}))			# hash, array, oid or boolean
			{
				if (ref($deep->{$k}) eq "MongoDB::OID")
				{
					$flatearth{$prefix.$k} =  $deep->{$k}->value;
				}
				# bson::oid also has undocumented value just for backwards compat
				elsif (ref($deep->{$k}) eq "BSON::OID")
				{
					$flatearth{$prefix.$k} =  $deep->{$k}->hex;
				}
				elsif (ref($deep->{$k}) =~ /^(JSON::XS::B|b)oolean$/)
				{
					$flatearth{$prefix.$k} = ( $deep->{$k}? 1:0);
				}
				elsif (ref($deep->{$k}) =~ /^(MongoDB::BSON::Binary|BSON::Bytes)$/)
				{
					$flatearth{$prefix.$k} = $deep->{$k}->data;
				}
				elsif (ref($deep->{$k}) =~ /^Regexp$/)
				{
					$flatearth{$prefix.$k} = $deep->{$k};
				}
				else
				{
					my ($error, %subfields) = flatten_dotfields($deep->{$k}, $prefix.$k);
					return $error if ($error);
					%flatearth = (%flatearth, %subfields);
				}
			}
			else
			{
				$flatearth{$prefix.$k} = $deep->{$k};
			}
		}
	}
	elsif (ref($deep) eq "ARRAY")
	{
		for my $idx (0..$#$deep)
		{
			if (ref($deep->[$idx])) 			# hash, array, oid or boolean
			{
				if (ref($deep->[$idx]) eq "MongoDB::OID")
				{
					$flatearth{$prefix.$idx} =  $deep->[$idx]->value;
				}
				elsif (ref($deep->[$idx]) eq "BSON::OID")
				{
					$flatearth{$prefix.$idx} =  $deep->[$idx]->hex;
				}
				elsif (ref($deep->[$idx]) =~ /^(JSON::XS::B|b)oolean$/)
				{
					$flatearth{$prefix.$idx} = ($deep->[$idx]? 1:0);
				}
				elsif (ref($deep->[$idx]) =~ /^(MongoDB::BSON::Binary|BSON::Bytes)$/)
				{
					$flatearth{$prefix.$idx} = $deep->[$idx]->data;
				}
				elsif (ref($deep->[$idx]) =~ /^Regexp$/)
				{
					$flatearth{$prefix.$idx} = $deep->[$idx];
				}
				else
				{
					my ($error, %subfields) = flatten_dotfields($deep->[$idx], $prefix.$idx);
					return $error if ($error);
					%flatearth = (%flatearth, %subfields);
				}
			}
			else
			{
				$flatearth{$prefix.$idx} = $deep->[$idx];
			}
		}
	}
	else
	{
		return "invalid input to flatten_dotfields: ".ref($deep);
	}
	return (undef, %flatearth);
}

# small helper to handle X.Y.Z or X.N.M indirection into a deep structure
# takes anchor of structure, follows X.Y.Z or X.N.M or X.-N.M indirections
#
# args: structure (ref), path (string)
# returns: value (or undef), error: undef/0 for ok, 1 for nonexistent key/index,
# 2 for type mismatch (eg. hash expected but scalar or array observed)
sub follow_dotted_diag
{
	my ($anchor, $path) = @_;
	my ($error, $value);

	for my $indirection (split(/\./, $path))
	{
		if (ref($anchor) eq "ARRAY" and $indirection =~ /^-?\d+$/)
		{
			if (!exists $anchor->[$indirection])
			{
				return (undef, 1);
			}
			else
			{
				$anchor = $anchor->[$indirection];
			}
		}
		elsif (ref($anchor) eq "HASH")
		{
			if (!exists $anchor->{$indirection})
			{
				return (undef, 1);
			}
			else
			{
				$anchor = $anchor->{$indirection};
			}
		}
		else
		{
			return (undef, 2);			# type mismatch
		}
	}
	$value = $anchor;
	return ($value, 0);
}

# append activity audit information to the one textual audit.log
# expects that the configuration has been loaded with loadConfTable!
#
# args: when (=unix ts), who (=user),
# what (=operation), where (=context), how (=success/failure/warning,info), details
# all required except when and details; all freeform except when,
# which must be numeric (but may be fractional)
#
# returns undef if ok, error otherwise
sub audit_log
{
	my (%args) = @_;
	my $C = NMISNG::Util::loadConfTable();
	return "no config available, cannot determine log directory!" if (!$C);

	for my $musthave (qw(who what where how))
	{
		return "Missing argument \"$musthave\"!" if (!$args{$musthave});
	}
	$args{details} ||= 'N/A';

	my $auditlogfile = $C->{'<nmis_logs>'}."/audit.log";

	# format is tab-delimited, any tabs in input are removed
	# order: ts, who, what, where, how, details
	# time format same as NMISNG::Log/Mojo::Log
  my @output = ( '['. localtime($args{when}||time) .']',
								 map { s/\t+//g; $_ } (@args{qw(who what where how details)}) );

	open(F, ">>$auditlogfile") or return "cannot open $auditlogfile for writing: $!";
	flock(F, LOCK_EX) or  return "cannot lock $auditlogfile: $!";
	# add helpful header if file was empty
	print F "# when\t\t\twho\twhat\twhere\thow\tdetails\n" if (! -s $auditlogfile);

	print F join("\t", @output),"\n";
	close(F);

	# fixme should handle errors at some point...
	my $res = NMISNG::Util::setFileProtDiag(file => $auditlogfile);

	return undef;
}

# quick and dirty dns lookup for ip addresses
# args: address (ipv4 or ipv6)
# returns: list of hostnames (or empty array)
sub resolve_dns_address
{
	my ($lookup) = @_;

	my @results;
	# full ipv6 support works only with newer socket module
	my ($err,@possibles) = Socket::getaddrinfo($lookup,'',
																						 {
																							 # don't bother with any service
																							 socktype => SOCK_RAW,
																							 #  and only REVERSE lookups
																							 flags => Socket::AI_NUMERICHOST });
	return () if ($err);
	for my $address (@possibles)
	{
		my ($err,$hostname) = Socket::getnameinfo(
			$address->{addr},
			Socket::NIx_NOSERV());
		push @results,$hostname if (!$err and $hostname ne $lookup);
	}
	return @results;
}


# quick dns lookup for names
# args: name
# returns: list of addresses (or empty array)
sub resolve_dns_name
{
	my ($lookup) = @_;
	my @results;

	my $nmisng = Compat::NMIS::new_nmisng();

	$nmisng->log->debug2("resolve_dns_name($lookup)");

	# full ipv6 support works only with newer socket module
	my ($err,@possibles) = Socket::getaddrinfo($lookup, '', {socktype => SOCK_RAW});
	
	if ($err)
	{
		$nmisng->log->debug2("getaddrinfo error: $err");
		return ();
	}

	for my $address (@possibles)
	{
		my ($err,$ipaddr) = Socket::getnameinfo(
			$address->{addr},
			Socket::NI_NUMERICHOST(),
			Socket::NIx_NOSERV());
		push @results, $ipaddr if (!$err and $ipaddr ne $lookup); # suppress any nop results
		if ($err)
		{
			$nmisng->log->debug2("getnameinfo error: $err");
		}
		else
		{
			$nmisng->log->debug2("getnameinfo result: $ipaddr");
		}
	}
	return @results;
}

# wrapper around resolve_dns_name,
# returns the _first_ available ip _v4_ address or undef
sub resolveDNStoAddr
{
	my ($name) = @_;

	my @addrs = resolve_dns_name($name);
	my @v4 = grep(/^\d+.\d+.\d+\.\d+$/, @addrs);

	return $v4[0];
}

sub resolveDNStoAddrIPv6
{
	my ($name) = @_;

	my @addresses = resolve_dns_name($name);

	return if (!@addresses);

	my @addr_objs = map { Net::IP->new($_) } (@addresses);
	my $type = 6;
	my ($ipv6) = grep($_->version == $type, @addr_objs);

	return Net::IP::ip_compress_address($ipv6->{ip}, 6);
}

# takes anything that time::parsedate understands, plus an optional timezone argument
# and returns full seconds (ie. unix epoch seconds in utc)
#
# if no timezone is given, the local timezone is used.
# attention: parsedate by itself does NOT understand the iso8601 format with timezone Z or
# with negative offset; relative time specs also don't work well with timezones OR dst changes!
#
# az recommends using parseDateTime || getUnixTime for max compat.
sub getUnixTime
{
	my ($timestring, $tzdef) = @_;

	# to make the tz-dependent stuff work, we MUST give parsedate a tz spec...
	# - but we don't know the applicable offset until after we've parsed the
	# time (== catch 22 when dst is involved)
	# - and parsedate doesn't understand most timezone names, so we must compute a numeric offset...fpos.
	# (== catch 22^2)
	# - plus trying to fix in postprocessing with shift FAILS if the time was a relative one (e.g. now),
	# and parsedate doesn't tell us whether the time in question was relative or absolute. fpos^2.
	#
	# best effort: take the current time's offset, hope it's applicable to the actual time in question

	my $tz = DateTime::TimeZone->new(name => 'local');

	my $tmobj = Time::Moment->now_utc;							 # don't do any local timezone stuff
	my $tzoffset = $tz->offset_for_datetime($tmobj); # in seconds
	# want [+-]HHMM
	my $tzspec = sprintf("%s%02u%02u", ($tzoffset < 0? "-":"+"),
											 (($tzoffset < 0? -$tzoffset: $tzoffset)/3600),
											 ($tzoffset%3600)/60);

  my $epochseconds = parsedate($timestring, ZONE => $tzspec);
	return $epochseconds;
}

# convert an iso8601/rfc3339 time into (fractional!) unix epoch seconds
# returns undef if the input string is invalid
# note: timezone suffixes ARE parsed and taken into account!
# if no tz suffix is present, use the local timezone
sub parseDateTime
{
	my ($dtstring) = @_;
	# YYYY-MM-DDTHH:MM:SS.SSS, millis are optional
	# also allowed: timezone suffixes Z, +NN, -NN, +NNMM, -NNMM, +NN:MM, -NN:MM

	# meh: time::moment strictly REQUIRES tz - just constructing with from_string()
	# fails on implicit local zone (and is likely more expensive even with fixup work, as lenient is
	# required because the damn thing otherwise refuses +NNMM as that has no ":"...
	if ($dtstring =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(\.\d+)?(Z|([\+-])(\d{2})\:?(\d{2})?)?/)
	{
		my $eleven = $11 // "00"; # datetime wants offsets as +-HHMM, nost just +-HH
		my $tzn = (defined($8)? $8 eq "Z"? $8 : $9.$10.$eleven : undef);
		my $tz = DateTime::TimeZone->new(name => $tzn // "local");

		# oh the convolutions...make obj w/o tz, then figure out offset for THAT time,
		# then apply the offset. meh.
		my $when = Time::Moment->new(year => $1, month => $2, day => $3,
																 hour => $4,  minute => $5, second => $6,
																 nanosecond => (defined $7? $7 * 1e9: 0));
		my $tzoffset = $tz->offset_for_datetime($when) / 60;

		my $inthezone = $when->with_offset_same_local($tzoffset);
		return $inthezone->epoch + $inthezone->nanosecond / 1e9;
	}
	else
	{
		return undef;
	}
}

# small helper to handle X.Y.Z or X.N.M indirection into a deep structure
# takes anchor of structure, follows X.Y.Z or X.N.M or X.-N.M indirections
#
# args: structure (ref), path (string)
# returns: value (or undef), error: undef/0 for ok, 1 for nonexistent key/index,
# 2 for type mismatch (eg. hash expected but scalar or array observed)
sub follow_dotted
{
	my ($anchor, $path) = @_;
	my ($error, $value);

	for my $indirection (split(/\./, $path))
	{
		if (ref($anchor) eq "ARRAY" and $indirection =~ /^-?\d+$/)
		{
			if (!exists $anchor->[$indirection])
			{
				return (undef, 1);
			}
			else
			{
				$anchor = $anchor->[$indirection];
			}
		}
		elsif (ref($anchor) eq "HASH")
		{
			if (!exists $anchor->{$indirection})
			{
				return (undef, 1);
			}
			else
			{
				$anchor = $anchor->{$indirection};
			}
		}
		else
		{
			return (undef, 2);			# type mismatch
		}
	}
	$value = $anchor;
	return ($value, 0);
}

# this is a general-purpose reaper of zombies
# args: none, returns: hash of process ids -> statuses that were reaped
#
# you can use this to just periodically collect zombies,
# or as a signal handler, but:
#
# PLEASE NOTE: if you attach it to $SIG{CHLD}, then
# this CAN AND WILL interfere with getting exit codes from
# backticks, system, and open-with-pipe, because the child handler
# can run before the perl standard wait() for these ipc ops,
# hence $? becomes -1 because the wait() was preempted.
#
sub reaper
{
	my %exparrots;

	while ((my $pid = waitpid(-1, POSIX::WNOHANG)) > 0)
	{
		$exparrots{$pid} = $?;
	}
	return %exparrots;
}

# trivial type/which implementation, saves us file::which or forking off a shell
# args: program name
# returns: full path or undef
sub type_which
{
        my ($needle) = @_;
        for my $maybe (split(/:/, $ENV{PATH}))
        {
                return "$maybe/$needle" if (-x "$maybe/$needle");
        }
        return undef;
}

# package Array::Utils::array_diff() copied from https://metacpan.org/release/Array-Utils/source/Utils.pm
sub array_diff(\@\@) {
        my %e = map { $_ => undef } @{$_[1]};
        return @{[ ( grep { (exists $e{$_}) ? ( delete $e{$_} ) : ( 1 ) } @{ $_[0] } ), keys %e ] };
}


# Replace directory names
# Migrate nmis8 node lowercase names
# Recursive
# if the file exists, it wont be replaced ( mv -n )
# @returns the number of moved files
sub replace_files_recursive {
	my ($path, $new, $old, $extension, $force) = @_;
	my $nmisng = Compat::NMIS::new_nmisng();
	$nmisng->log->info("Replacing $new for $old in $path ");
	my $C = $nmisng->config();
	
	my $total = 0;
	my @toreview;
	
	my $replaced = $path;
	my $dh;
	
	$replaced =~ s/$old/$new/g;
		
	if (!opendir($dh, $path)) {
		print "Can't open $path: $! \n";
		return 0;
	}
			
	if ( !-d $replaced and $replaced ne "" ) {
		my $output = `mkdir $replaced`;
		system("chown","-R","$C->{nmis_user}:$C->{nmis_group}", $output);
		$nmisng->log->debug("Create dir $replaced");
	}

	while (readdir $dh) {
		my $fh = "$path/$_";
		$nmisng->log->debug("Listing $fh ");
		if ( -d "$fh" && $_ ne "." && $_ ne "..") {
			push @toreview, $fh;
		} else {
			next unless ($_ =~ m/\.$extension$/);				
			my $replaced = $fh;
			$replaced =~ s/$old/$new/g;
			$nmisng->log->debug("Replacing $fh = $replaced if not equals ");
			if ($fh ne $replaced) {
				$total++;
				my $output;
				
				if ($force) {
					$output = `mv $fh $replaced`;
				} else {
					$output = `mv -n $fh $replaced`;
				}
				system("chown","-R","$C->{nmis_user}:$C->{nmis_group}", $replaced);
				system("chmod","-R","g+rw", $replaced);
				$nmisng->log->info("mv $fh into $replaced  ");
			}
		}
	}
	closedir $dh;
	
	foreach (@toreview) {
		$total = $total + replace_files_recursive($_, $new, $old, $extension, $force);
	}
	return $total;
}

# Filter values
# Used by CGI
sub filter_params {
	my ($vars) = @_;
	
	foreach my $param (%$vars) {
		$param = encode_entities($param);
	}
	
	return $vars;
}

# Get policy for a node based on policy name
# args pollicy_name
sub get_policy {

	my ($policy_name, $C) = @_;	
	my $table_policies = NMISNG::Util::loadTable(dir => "conf", name => "Polling-Policy", conf => $C) // NMISNG::Util::loadTable(dir => "conf-default", name => "Polling-Policy", conf => $C);
	my $policy;
	my $intervals;
	$intervals->{default} = {ping => 60, snmp => 300, wmi => 300, update => 86400};
	
	for my $polname ( keys %$table_policies )
	{
		next if ( ref( $table_policies->{$polname} ) ne "HASH" );
		for my $subtype (qw(snmp wmi ping update))
		{
				my $interval = $table_policies->{$polname}->{$subtype};
				if ( $interval =~ /^\s*(\d+(\.\d+)?)([smhd])$/ )
				{
					my ( $rawvalue, $unit ) = ( $1, $3 );
					$interval = $rawvalue * (
						  $unit eq 'm' ? 60
						: $unit eq 'h' ? 3600
						: $unit eq 'd' ? 86400
						:                1
					);
				}
				else
				{
					#$self->nmisng->log->error("Polling policy \"$polname\" has invalid interval \"$interval\" for $subtype! Ignoring.");
					$interval = $intervals->{devault}->{$subtype};
				}
				$intervals->{$polname}->{$subtype} = $interval;    # now in seconds
		}
	}
	return $intervals->{$policy_name};
}

########################################################################
# decrypt - Decrypt the password.                                      #
########################################################################
sub decrypt {
	my ($password, $section, $keyword) = @_;
	my $nmisng  = Compat::NMIS::new_nmisng();
	my $config;
	my $logger;

	{
		if (defined($nmisng)) {
			$config  = $nmisng->config;
			$logger  = $nmisng->log;
		} else {
			$config = NMISNG::Util::loadConfTable();
			my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
			$logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);
		}
	}

	my $encryption_enabled = NMISNG::Util::getbool($config->{'global_enable_password_encryption'});
	my $seedfile           = '/usr/local/etc/opmantek/seed.txt';
	my $strLen             = "";
	my $fh;

	$logger->debug9("Seedfile name is '" . $seedfile . "'.");

	# Make sure we have a seed file.
	if (!-f "$seedfile") {
		_make_seed($seedfile, $logger);
	}

	# Passed nothing or an empty string.
	return "" if (!defined($password) || $password eq '');

	# If The password is not currently encrypted, then we just return what we have.
	if (substr($password, 0, 2) ne "!!") {
		# Encryption is enabled.
		if ($encryption_enabled) {
			# If we have an unencrypted password in the configuration file, then we encrypt it.
			# (If the 'section and 'keyword' arguments are passed, it means we are dealing with the configuration file)
			if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
				# Get the non-flattened raw hash
				my ($fullConfig,undef) = NMISNG::Util::readConfData(only_local => 1);
				$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
				my $encrypted_pw = encrypt($password);
				if ($fullConfig->{$section}{$keyword} ne $encrypted_pw) {
					$logger->debug3("Encrypting the password for Section: '$section' Field: '$keyword'");
					$fullConfig->{$section}{$keyword} = $encrypted_pw;
					$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
					NMISNG::Util::writeConfData(data=>$fullConfig);
				}
			}
		} else {
			$logger->debug9("Encryption is disabled.");
		}
		return $password;
	} else {
		$password = substr($password, 2);
	}
	if (open($fh, '<', $seedfile)) {
		my $seed = <$fh>;
		close $fh;
		my $cipherHandle = Crypt::CBC->new({key => $seed, pbkdf=>'pbkdf2', cipher => 'Cipher::AES'});
		$password        = eval { $cipherHandle->decrypt_hex($password); };
		if ($@) {
			$logger->error("Password decryption failure.");
			$password = "";
		} else {
			$strLen   = substr($password, 0, 3);
			$password = substr($password, 3, $strLen);
			# Encryption is disabled, unencrypt whatever we encounter.
			if (!$encryption_enabled) {
				# If we have an encrypted password in the configuration file, then we unencrypt it.
				# (If the 'section and 'keyword' arguments are passed, it means we are dealing with the configuration file)
				if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
					# Get the non-flattened raw hash
					my ($fullConfig,undef) = NMISNG::Util::readConfData(only_local => 1);
					$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
					if ($fullConfig->{$section}{$keyword} ne $password) {
						$logger->debug3("Decrypting the password for Section: '$section' Field: '$keyword'");
						$fullConfig->{$section}{$keyword} = $password;
						$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
						NMISNG::Util::writeConfData(data=>$fullConfig);
					}
				}
			}
		}
	} else {
		$logger->error("Password decryption failure.");
		$password = "";
	}

	return $password;
}

########################################################################
# encrypt - Encrypt the password.                                      #
########################################################################
sub encrypt {
	my ($password, $section, $keyword) = @_;
	my $config;
	my $logger;

	{
		my $nmisng  = Compat::NMIS::new_nmisng();
		if (defined($nmisng)) {
			$config  = $nmisng->config;
			$logger  = $nmisng->log;
		} else {
			$config = NMISNG::Util::loadConfTable();
			my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
			$logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);
		}
	}
	my $encryption_enabled = NMISNG::Util::getbool($config->{'global_enable_password_encryption'});
	my $seedfile           = '/usr/local/etc/opmantek/seed.txt';
	my $strLen             = 0;
	my $fh;

	$logger->debug9("Seedfile name is '" . $seedfile . "'.");

	if (!-f "$seedfile") {
		_make_seed($seedfile, $logger);
	}

	# Passed nothing or an empty string.
	return "" if (!defined($password) || $password eq '');

	# Passed already encrypted string.
	if (substr($password, 0, 2) eq "!!") {
		# Encryption is disabled, unencrypt whatever we encounter and return that.
		if (!$encryption_enabled) {
			my $decrypted_pw = decrypt($password);
			# If we have an encrypted password in the configuration file, then we unencrypt it.
			# (If the 'section and 'keyword' arguments are passed, it means we are dealing with the configuration file)
			if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
				# Get the non-flattened raw hash
				my ($fullConfig,undef) = NMISNG::Util::readConfData(only_local => 1);
				$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
				if ($fullConfig->{$section}{$keyword} ne $decrypted_pw) {
					$logger->debug3("Decrypting the password for Section: '$section' Field: '$keyword'");
					$fullConfig->{$section}{$keyword} = $decrypted_pw;
					$logger->debug9("Config '" .  Dumper($fullConfig) . "'.");
					NMISNG::Util::writeConfData(data=>$fullConfig);
				}
			}
			return $decrypted_pw;
		} else {
			$logger->debug9("Encryption is enabled.");
		}
		return $password;
	}

	if (open($fh, '<', $seedfile)) {
		my $seed = <$fh>;
		close $fh;
		$strLen	   = sprintf("%03d", length($password));
		$password  = $strLen.$password;

		my $cipherHandle = Crypt::CBC->new({key => $seed, pbkdf=>'pbkdf2', cipher => 'Cipher::AES'});
		$password        = eval { $cipherHandle->encrypt_hex($password); };
		$password        = "!!" . $password;
		if ($@) {
			$logger->error("Password encryption failure.");
			$password = "";
		}
	} else {
		$logger->error("Password encryption failure.");
		$password = "";
	}

	return $password;
}

########################################################################
# _make_seed - Create an encryption seed file.                         #
########################################################################
sub _make_seed {
	my $seedfile  = shift;
	my $logger    = shift;

	my $seeddir  = File::Spec->rel2abs(dirname(${seedfile}));
	my @charset  = (('A'..'Z'), ('a'..'z'), (0..9));
	my $range    = $#charset + 1;
	my $fh;
	my $seed;

	for (1..256) {
		$seed .= $charset[int(rand($range))];
	}
 	my $uid;
	if (-f "/etc/redhat-release") {
		$uid = getpwnam("apache");
	} else {
		$uid = getpwnam("www-data");
	}
	my $gid = getgrnam("nmis");
	if (!-f "$seeddir") {
		mkpath($seeddir, 0770);
	    chown($uid, $gid, $seeddir);
	}
	unless(open($fh, '>', $seedfile)) {
		$logger->error("Unable to create an encryption seed file.");
		return 2;
	}
	print $fh ("$seed");
	close $fh;
	chown($uid, $gid, $seedfile);
	chmod(0440, $seedfile);

	return 0;
}

1;
