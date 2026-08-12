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
our $VERSION = "9.6.5";

use strict;
use feature 'state';						# loadconftable, uuid functions

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
use UUID::Tiny qw(:std);			# for loadconftable, cluster_id, uuid functions
use IO::Handle;
use Socket 2.001;					# for getnameinfo() used by resolve_dns_name
use JSON::XS;
use Proc::ProcessTable 0.53;		# older versions are not totally reliable
use List::Util 1.33;
#use Math::Random::Secure qw(rand);  # Replace rand().
#use Crypt::CBC;						# for token / externally delegated auth
#use Crypt::Cipher::AES;
#use Syntax::Keyword::Try;
use Try::Tiny;
use Mojo::File;

use Data::Dumper;
$Data::Dumper::Indent=1;			# fixme9: do we really need these globally on?
$Data::Dumper::Sortkeys=1;

use NMISNG::Log;					# for parse_debug_level

# Package-level storage for config source tracking (populated by loadConfTable)
our $_config_sources_ref = {};
# Set to 1 to force loadConfTable to reload on next call
our $_config_cache_invalid = 0;
# Epoch when config was last loaded (not cache hit) — used by configChanged()
our $_config_load_time = 0;
# Raw two-level hashes per layer, stored during loadConfTable
# layer => { section => { key => value } }
our %_raw_layers;

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

# like getargs, but arrayify multiple occurrences of a parameter
#
# Unlike 'get_args_multi', this subroutine does not print the 
# 'Invalid command argument' to STDERR, but returns a Hashmap
# Key named '__parse_error__' containing an array of errors.
# It is the responsibility of the caller to handle the errors,
# or ignore them.
#
# args: list of key=values to parse,
# returns: hashref
sub get_args_multi_quiet
{
	my @argue = @_;
	my %hash;

	for my $item (@argue)
	{
		if ( $item !~ /^.+=/ )
		{
			push @{$hash{'__parse_error__'}}, "Invalid command argument '$item'\n";
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
	elsif ( $_ >= 1000000000 ) { $_ /= 1000000000; /(\d+\.?\d{0,2})/; return "$1 Gb${ps}"; }
	elsif ( $_ >= 1000000 ) { $_ /= 1000000; /(\d+\.?\d{0,2})/; return "$1 Mb${ps}"; }
	elsif ( $_ >= 1000 ) { $_ /= 1000; /(\d+\.?\d{0,2})/; return "$1 Kb${ps}"; }
	else { /(\d+\.?\d{0,2})/; return"$1 b${ps}"; }
}

sub getDiskBytes {
	$_ = shift;
	my $ps = shift; # 'ps'
	if ( $_ eq "NaN" ) { return "$_" ;}
	elsif ( $_ >= 1073741824 ) { $_ /= 1073741824; /(\d+\.?\d{0,2})/; return "$1 GB${ps}"; }
	elsif ( $_ >= 1048576 ) { $_ /= 1048576; /(\d+\.?\d{0,2})/; return "$1 MB${ps}"; }
	elsif ( $_ >= 1024 ) { $_ /= 1024;/(\d+\.?\d{0,2})/; return "$1 KB${ps}"; }
	else { /(\d+\.?\d{0,2})/; return"$1 b${ps}"; }
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

# reads/loads config and returns the server role
# input config data or null
# output server_role or Standalone
sub getServerRole {
	my %args = @_;
	
	my $config = $args{config} // loadConfTable();
	# empty "" is also reported as Standalone
	return $config->{server_role} || "Standalone";
}

# Layered configuration loading with source tracking.
# Loading order: conf-default/Config.nmis -> conf/Config.nmis -> conf/conf.d/*.nmis -> NMIS_* env vars
# Config is immutable for process lifetime (load-once, no mtime checks).
# Process restart required to pick up config changes.
#
# args: dir, debug (all optional)
# returns: hash ref, dies (verbosely) on failure
sub loadConfTable
{
	my %args = @_;
	state ($config_cache, $cached_configfile_fn);

	my $dir = $args{dir} || "$FindBin::RealBin/../conf";
	mkpath($dir, { verbose  => 0, mode => 0755} ) if (!-d $dir);

	my $fn = Cwd::abs_path("$dir/Config.nmis") // "$dir/Config.nmis";
	# if caller gave us a dir previously but not now, use the cached path
	$fn = $cached_configfile_fn if ($cached_configfile_fn && !defined $args{dir});

	# return cached config if already loaded for this path (unless invalidated)
	if ($config_cache && $cached_configfile_fn && $cached_configfile_fn eq $fn
		&& !$NMISNG::Util::_config_cache_invalid)
	{
		return $config_cache;
	}
	warn("Config cache invalidated, reloading from disk\n") if $NMISNG::Util::_config_cache_invalid;
	$NMISNG::Util::_config_cache_invalid = 0;

	# --- Layer 1: conf-default/Config.nmis (defaults) ---
	my $default_dir = $args{dir} ? "$args{dir}/../conf-default" : "$FindBin::RealBin/../conf-default";
	my $default_fn = Cwd::abs_path("$default_dir/Config.nmis") // "$default_dir/Config.nmis";

	$config_cache = {};
	my $config_sources = {};
	%NMISNG::Util::_raw_layers = ();

	# Properties that may only be defined in one non-default config file
	my @exclusive_keys = ('cluster_id', 'server_name', 'nmis_host');
	my %exclusive_source;

	if (-r $default_fn)
	{
		my ($flat, $smap, $raw) = _load_and_flatten($default_fn);
		warn_die("configuration file $default_fn unparseable or empty") if (!$flat || !keys %$flat);
		$config_cache = $flat;
		$_raw_layers{1} = $raw;
		for my $k (keys %$flat)
		{
			$config_sources->{$k} = { source => $default_fn, layer => 1, section => $smap->{$k} };
		}
	}

	# --- Layer 2: conf/Config.nmis (local config) ---
	if (-r $fn && $fn ne $default_fn)
	{
		my ($flat, $smap, $raw) = _load_and_flatten($fn);
		if ($flat && keys %$flat)
		{
			_merge_config($config_cache, $flat, 0);
			$_raw_layers{2} = $raw;
			for my $k (keys %$flat)
			{
				$config_sources->{$k} = { source => $fn, layer => 2, section => $smap->{$k} };
			}
			# Track exclusive keys claimed by local config
			for my $ek (@exclusive_keys)
			{
				$exclusive_source{$ek} = $fn if (exists $flat->{$ek});
			}
		}
	}
	elsif (!-r $fn && !keys %$config_cache)
	{
		warn_die("all configuration files ($fn, $default_fn) are unreadable: $!");
	}

	# --- Layer 3: conf/conf.d/*.nmis (fragments, override-only) ---
	my $partialconf_dir = "$dir/conf.d";
	my $external_files = [];
	if (-d $partialconf_dir) {
		$partialconf_dir = Cwd::abs_path($partialconf_dir) || $partialconf_dir;
		$external_files = get_external_files(dir => $partialconf_dir);
	}
	$_raw_layers{3} = {};
	for my $extfile (@$external_files)
	{
		my ($flat, $smap, $raw) = _load_and_flatten($extfile);
		next if (!$flat || !keys %$flat);

		# Enforce exclusive keys: skip if already defined by an earlier non-default file
		for my $ek (@exclusive_keys)
		{
			if (exists $flat->{$ek})
			{
				if (exists $exclusive_source{$ek})
				{
					warn("Exclusive property '$ek' in $extfile ignored — already defined in $exclusive_source{$ek}\n");
					delete $flat->{$ek};
					# Also remove from raw so it doesn't leak into layer 3 storage
					for my $s (keys %$raw) {
						delete $raw->{$s}{$ek} if ref($raw->{$s}) eq 'HASH';
					}
				}
				else
				{
					$exclusive_source{$ek} = $extfile;
				}
			}
		}

		my $changed = _merge_config($config_cache, $flat, 1);
		for my $k (@$changed)
		{
			$config_sources->{$k} = { source => $extfile, layer => 3, section => $smap->{$k} };
		}
		# Merge raw into layer 3 storage (only keys that were actually merged)
		for my $s (keys %$raw)
		{
			next unless ref($raw->{$s}) eq 'HASH';
			for my $k (keys %{$raw->{$s}})
			{
				$_raw_layers{3}{$s}{$k} = $raw->{$s}{$k} if grep { $_ eq $k } @$changed;
			}
		}
	}

	# --- Layer 4: Environment variables (NMIS_*) ---
	_apply_env_overrides($config_cache, $config_sources, \@exclusive_keys, \%exclusive_source);

	# --- Post-merge processing ---
	# Hardcoded values
	$config_cache->{conf} = "Config";
	$config_sources->{conf} = { source => "hardcoded", layer => 0, section => undef };
	$config_cache->{auth_require} = 1;
	$config_sources->{auth_require} = { source => "hardcoded", layer => 0, section => undef };
	$config_cache->{hide_groups} //= [];

	# Parse debug/info from args
	my $verbosity = NMISNG::Log::parse_debug_level(debug => $args{debug});
	$config_cache->{debug} = $verbosity =~ /^(debug|\d)+/? $verbosity : 0;
	if (!$config_cache->{debug})
	{
		$verbosity = NMISNG::Log::parse_debug_level(debug => $args{info});
		$config_cache->{info} = $verbosity =~ /^(debug|\d)+/? $verbosity : 0;
	}

	# Set configfile key — always points to conf/Config.nmis (the write target),
	# even if it doesn't exist yet (writeConfData will create it)
	$config_cache->{configfile} = $fn;
	$cached_configfile_fn = $fn;

	# Replace macros once across entire config
	$config_cache = replace_macros( config_cache => $config_cache );

	# Var directory symlink management
	my $confdvar = $config_cache->{'<nmis_var>'};
	my @confdstat = (CORE::stat($confdvar))[0,1];
	my $normalvar = "$config_cache->{'<nmis_base>'}/var";
	my @normalstat = (CORE::stat($normalvar))[0,1];

	if (-d $confdvar and ($confdstat[0] != $normalstat[0]
												or $confdstat[1] != $normalstat[1]))
	{
		rename($normalvar, "$normalvar.deconfigured.$$") if (-e $normalvar);
		symlink($confdvar, $normalvar)
				or warn_die("cannot symlink $normalvar to configured $confdvar: $!");
	}

	# Store sources in package variable for getConfigSources access
	# (must happen before cluster_id block so writeConfData/getConfDeep can work)
	$NMISNG::Util::_config_sources_ref = $config_sources;
	$NMISNG::Util::_config_load_time = time();

	# Cluster ID: if missing, generate UUID and write to conf/Config.nmis
	if (!$config_cache->{cluster_id})
	{
		$config_cache->{cluster_id} = create_uuid_as_string(UUID_RANDOM);
		$config_sources->{cluster_id} = { source => $config_cache->{configfile}, layer => 2, section => "id" };
		# Add to raw layer 2 so getConfDeep includes it
		$_raw_layers{2} //= {};
		$_raw_layers{2}{id}{cluster_id} = $config_cache->{cluster_id};
		# Write through the standard config pipeline
		my ($deep, undef) = getConfDeep();
		my $error = writeConfData(data => $deep);
		warn("cannot persist cluster_id: $error") if $error;
		# writeConfData invalidates cache, but we're still building it — clear the flag
		$NMISNG::Util::_config_cache_invalid = 0;
	}

	return $config_cache;
}

# Returns source tracking info for config keys.
# args: optional key => "keyname" to get info for a single key
# returns: hashref of { key => { source, layer, section } } or single key's info
sub getConfigSources
{
	my %args = @_;
	my $sources = $NMISNG::Util::_config_sources_ref // {};
	if (defined $args{key})
	{
		return $sources->{$args{key}};
	}
	return $sources;
}

# Returns the default config values (layer 1) as a two-level hash.
# returns: hashref { section => { key => value } }
sub getConfigDefaults
{
	loadConfTable(); # ensure loaded
	return $_raw_layers{1} // {};
}

# Load a .nmis config file and flatten its two-level hash to a single level.
# Uses shared lock to avoid reading partially-written files.
# Returns: ($flattened_hashref, $section_map_hashref, $raw_two_level_hashref)
sub _load_and_flatten
{
	my ($filepath) = @_;

	# Read under shared lock to protect against concurrent writes
	open(my $fh, "<", $filepath) or do {
		warn("cannot open configuration file $filepath: $!");
		return (undef, undef, undef);
	};
	flock($fh, LOCK_SH) or do {
		warn("cannot lock configuration file $filepath: $!");
		close($fh);
		return (undef, undef, undef);
	};
	local $/;
	my $content = <$fh>;
	close($fh);

	# no strict 'vars' needed because .nmis files use %hash = (...) without declaring it
	my %deepdata = do { no strict 'vars'; eval $content };
	if ($@)
	{
		warn("configuration file $filepath unparseable: $@");
		return (undef, undef, undef);
	}
	if (!%deepdata)
	{
		warn("configuration file $filepath returned no data");
		return (undef, undef, undef);
	}

	my %flat;
	my %section_map;
	for my $section (keys %deepdata)
	{
		if (ref($deepdata{$section}) eq 'HASH')
		{
			for my $k (keys %{$deepdata{$section}})
			{
				$flat{$k} = $deepdata{$section}{$k};
				$section_map{$k} = $section;
			}
		}
	}
	return (\%flat, \%section_map, \%deepdata);
}

# Merge overlay keys into base.
# If override_only is true, only replaces keys that already exist in base.
# Returns: arrayref of keys that were actually set.
sub _merge_config
{
	my ($base, $overlay, $override_only) = @_;
	my @changed;
	for my $k (keys %$overlay)
	{
		next if ($override_only && !exists $base->{$k});
		$base->{$k} = $overlay->{$k};
		push @changed, $k;
	}
	return \@changed;
}

# Scan %ENV for NMIS_* variables and apply to config (can override or add new keys)
# Exclusive keys are enforced if exclusive_keys/exclusive_source are provided.
sub _apply_env_overrides
{
	my ($config, $sources, $exclusive_keys, $exclusive_source) = @_;

	for my $envkey (keys %ENV)
	{
		next unless $envkey =~ /^NMIS_(.+)$/;
		my $suffix = lc($1);
		# Resolution: plain key if exists, then <angle_bracket> if exists, otherwise plain key (new)
		my $config_key = exists $config->{$suffix} ? $suffix
			: exists $config->{"<$suffix>"} ? "<$suffix>"
			: $suffix;

		# Enforce exclusive keys
		if ($exclusive_keys && grep { $_ eq $config_key } @$exclusive_keys)
		{
			if ($exclusive_source && exists $exclusive_source->{$config_key})
			{
				warn("Exclusive property '$config_key' from ENV:$envkey ignored — already defined in $exclusive_source->{$config_key}\n");
				next;
			}
			$exclusive_source->{$config_key} = "ENV:$envkey" if $exclusive_source;
		}

		warn("ENV $envkey overriding config key '$config_key' from source '$sources->{$config_key}{source}'\n")
			if (exists $config->{$config_key} && $sources->{$config_key} && $sources->{$config_key}{layer} > 1);
		my $prev_section = $sources->{$config_key} ? $sources->{$config_key}{section} : undef;
		$config->{$config_key} = $ENV{$envkey};
		$sources->{$config_key} = { source => "ENV:$envkey", layer => 4, section => $prev_section };
	}
}


# Get external configuration files (sorted for deterministic merge order)
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
	@files = sort @files;
	return \@files;
}

# read_load_cache has been replaced by _load_and_flatten

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
	# Should only happen in a container environment
	if (defined($ENV{CONTAINER}) && $ENV{CONTAINER} eq "1") {
		return undef;
    }

	my (%args) = @_;
	# note: the ?: form is a precedence trap here (parses as
	# (cond ? $C=.. : $C) = loadConfTable()), so loadConfTable always ran and
	# the passed conf was ignored. use an explicit if/else.
	my $C = (ref($args{conf}) eq "HASH") ? $args{conf} : NMISNG::Util::loadConfTable();

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
	my $utf8 = NMISNG::Util::getbool($args{utf8}); # pass through to readFiletoHash for model files

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
		my $table = NMISNG::Util::readFiletoHash(file=>$file, lock=>$lock, utf8=>$utf8, conf => $conf);

		foreach (@$externalFiles) {
			# Read and mix
			my $lock = NMISNG::Util::getbool($args{lock});
			my $extfile = NMISNG::Util::readFiletoHash(file=>$_, lock=>$lock, utf8=>$utf8, conf => $conf);
			$table = {%$table, %$extfile};
		}
		return $table;
	}

	# look at the cache, does it have existing non-stale data?
	my $filetime = stat($file)->mtime;

	if (ref($cache{$file}) ne "HASH"
			|| $filetime != $cache{$file}->{mtime})
	{
		my $table = NMISNG::Util::readFiletoHash(file=>$file, utf8=>$utf8, conf => $conf);

		foreach (@$externalFiles) {
			# Read and mix
			my $extfile = NMISNG::Util::readFiletoHash(file=>$_, utf8=>$utf8, conf => $conf);
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
			my $modeldata = NMISNG::Util::loadTable(dir => $choices, name => $relfn, utf8 => 1, conf => $C);
			# modeldata has the error in it if there was one
			return { error => "failed to read file $fn: $! $modeldata" } if (ref($modeldata) ne "HASH"
																														or !keys %$modeldata);
			return { success => 1, data => $modeldata, is_custom => $iscustom, mtime => $age};
		}
	}
	return { error => "no model definition file available for model $args{model}!" };
}


# Write formatted data to an open file handle.
# Returns undef on success, error message on failure.
sub _write_data_to_handle
{
	my ($fh, $data, $filename, $useJson, $pretty) = @_;
	if ($useJson && $pretty)
	{
		# make sure that all json files contain valid utf8-encoded json, as required by rfc7159
		return "cannot write data object to file $filename: $!"
			unless print $fh JSON::XS->new->utf8(1)->pretty(1)->encode($data);
	}
	elsif ($useJson)
	{
		# encode_json already ensures utf8-encoded json
		eval { print $fh encode_json($data) };
		return "cannot write data object to $filename: $@" if $@;
	}
	else
	{
		return "cannot write to file $filename: $!"
			unless print $fh Data::Dumper->Dump([$data], [qw(*hash)]);
	}
	return undef;
}

# Serializer used by writeHashtoFile, held in a package variable so tests can
# override it (e.g. to simulate an error-free write that produces no bytes).
our $_data_writer = \&_write_data_to_handle;

# write hash data to file in suitable format
# Uses atomic write (temp file + rename) to prevent 0-length files on disk-full or crash.
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
		# --- Atomic write path: write to temp file, then rename over target ---
		my $tmpfile = "$file.tmp.$$";

		# Lock target file for mutual exclusion (don't truncate it)
		my $lockhandle;
		if (-e $file)
		{
			open($lockhandle, "+<", $file)
				or return("writeHashtoFile: cannot open $file for locking: $!");
		}
		else
		{
			open($lockhandle, ">", $file)
				or return("writeHashtoFile: cannot create $file for locking: $!");
		}
		flock($lockhandle, LOCK_EX)
			or return("writeHashtoFile: can't lock $file: $!");

		# Write to temp file in same directory (ensures same filesystem for atomic rename)
		open(my $tmphandle, ">", $tmpfile)
			or do { close($lockhandle);
					return("writeHashtoFile: cannot create temp file $tmpfile: $!"); };

		my $errormsg = $_data_writer->($tmphandle, $data, $file, $useJson, $pretty);

		# Force buffered data all the way to disk before the rename. flush()
		# pushes perlio buffers down to the OS. sync() (fsync) then forces the
		# OS to write them to the physical medium. Without this, a crash or
		# power loss between the write and the rename could leave the renamed
		# file pointing at data that never reached disk.
		if (!$errormsg && !$tmphandle->flush)
		{
			$errormsg = "cannot flush temp file $tmpfile: $!";
		}
		if (!$errormsg && $^O !~ /Win32/ && !$tmphandle->sync)
		{
			$errormsg = "cannot sync temp file $tmpfile: $!";
		}

		# close flushes buffers — check for write errors (e.g. disk full)
		if (!close($tmphandle) && !$errormsg)
		{
			$errormsg = "cannot close temp file $tmpfile: $!";
		}

		# Refuse to rename an empty temp file over the target. A 0-byte temp
		# file after an error-free write means something went wrong upstream,
		# and overwriting a good config with it would lose data.
		if (!$errormsg && !-s $tmpfile)
		{
			$errormsg = "temp file $tmpfile is empty, refusing to overwrite $file";
		}

		if ($errormsg)
		{
			unlink($tmpfile);
			close($lockhandle);
			return("writeHashtoFile: $errormsg");
		}

		# Atomic replace: rename is atomic on POSIX within same filesystem
		rename($tmpfile, $file)
			or do { unlink($tmpfile); close($lockhandle);
					return("writeHashtoFile: cannot rename $tmpfile to $file: $!"); };

		close($lockhandle);
	}
	else
	{
		# --- Legacy handle path: caller manages locking ---
		seek($handle, 0, 0) or return("writeHashtoFile: can't seek in $file: $!");
		truncate($handle, 0) or return("writeHashtoFile: can't truncate $file: $!");

		my $errormsg = $_data_writer->($handle, $data, $file, $useJson, $pretty);
		close $handle;
		return("writeHashtoFile: $errormsg") if ($errormsg);
	}

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
	my $utf8 = NMISNG::Util::getbool($args{utf8}); # decode Perl-format file as UTF-8
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
				# Caller passes utf8=>1 for model files (which must be UTF-8) to
				# ensure multi-byte literals like '°C' survive the eval as proper
				# Perl Unicode strings and are not re-encoded by JSON::XS later.
				# Try strict UTF-8 first (FB_CROAK), but fall back to latin1 if the
				# file isn't valid UTF-8 -- a model with stray bytes still loads
				# instead of dying mid-load, matching the JSON branch above. The
				# encoding problem is surfaced as a warning rather than silenced.
				# Do NOT apply to config/state files whose encoding is uncontrolled.
				if ($utf8) {
					require Encode;
					my $decoded = eval { Encode::decode('UTF-8', $data, Encode::FB_CROAK) };
					if ($@) {
						warn("readFiletoHash: $file is not valid UTF-8, falling back to latin1: $@");
						$decoded = Encode::decode('iso-8859-1', $data);
					}
					$data = $decoded;
				}
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
#  The function will accept the following and is not case sesitive:     #
#  true, yes, t, y, 1, false, no, f, n, or 0                            #
#                                                                       #
#########################################################################
sub getbool_cli
{
	my ($key, $val, $default) = @_;
	$default = 0 if !defined($default);

	return ((defined($val)) ? (($val =~ /(^true$)|(^yes$)|(^t$)|(^y$)|(^1$)/i) ? 1 : (($val =~ /(^false$)|(^no$)|(^f$)|(^n$)|(^0$)/i) ? 0 : die "Invalid boolean value for '$key': '$val'\n" )) : $default);
}

#########################################################################
# Check debug argument for CLI input.  It will not default an assumed   #
#  value when the user may have not intended the action.  This function #
#  expects the current debug value.  It will convert 'true' to 1, false #
#  to 0, and 'verbose' to 9. It will die with an error message if the   #
#  value is not understood.                                             #
#                                                                       #
#  The function will accept the following and is not case sesitive:     #
#  true, yes, t, y, false, no, f, n, verbose, or 0-9.                   #
#                                                                       #
#########################################################################
sub getdebug_cli
{
	my ($val) = shift;

	return ((defined($val)) ? (($val =~ /(^true$)|(^yes$)|(^t$)|(^y$)|(^1$)/i) ? 1 : (($val =~ /(^false$)|(^no$)|(^f$)|(^n$)|(^0$)/i) ? 0 : (($val =~ /^verbose$/i) ? 9 : (($val =~ /^[0-9]$/) ? $val : die "Invalid debug value: '$val'\n" )))) : 0);
}

# trivial wrapper around readfiletohash
# difference to loadConfTable: loadconftable flattens and adds a few entries
# args: only_local eq 1 loads only local config (Not by default)
# returns: hashref-or-errormessage, file name
# Reconstruct two-level config hash from stored raw layer data.
# No file I/O — uses layer data cached during loadConfTable.
# args: only_local => 1 (only layer 2 / local config keys)
# returns: ($deep_hashref, $configfile_path)
sub getConfDeep
{
	my %args = @_;
	my $C = loadConfTable(); # ensure loaded
	my %deep;

	# Merge raw layers in order: defaults(1), site(2), conf.d(3)
	for my $layer (1, 2, 3)
	{
		next unless ref($_raw_layers{$layer}) eq 'HASH';
		next if ($args{only_local} && $layer != 2);
		for my $section (keys %{$_raw_layers{$layer}})
		{
			next unless ref($_raw_layers{$layer}{$section}) eq 'HASH';
			for my $key (keys %{$_raw_layers{$layer}{$section}})
			{
				$deep{$section}{$key} = $_raw_layers{$layer}{$section}{$key};
			}
		}
	}

	# Apply ENV overrides (layer 4) so values round-trip correctly through writeConfData
	if (!$args{only_local})
	{
		my $sources = getConfigSources();
		for my $k (keys %$sources)
		{
			next unless $sources->{$k}{layer} == 4;
			my $section = $sources->{$k}{section};
			next unless defined $section;
			$deep{$section}{$k} = $C->{$k};
		}
	}

	return (\%deep, $C->{configfile});
}

# Writes config data to conf/Config.nmis, filtering keys by their source:
# - ENV-sourced keys (layer 4): error if changed, skipped if unchanged
# - conf.d-sourced keys (layer 3): error if changed, skipped if unchanged
# - Keys matching defaults (layer 1): skipped (no need to persist)
# - All other keys: written to conf/Config.nmis
# If resulting data is empty, backs up and removes the config file.
# args: data (two-level hashref), required
# returns: undef on success, or error message string
sub writeConfData
{
	my %args = @_;
	my $CC = $args{data};

	my $C = NMISNG::Util::loadConfTable();
	my $configfile = $C->{configfile};
	my $sources = NMISNG::Util::getConfigSources();
	my $defaults = $_raw_layers{1} // {};
	my $confd = $_raw_layers{3} // {};

	# Filter data: skip defaults, error on managed keys, keep only site overrides
	my %filtered;
	for my $section (keys %$CC)
	{
		next unless ref($CC->{$section}) eq 'HASH';
		for my $key (keys %{$CC->{$section}})
		{
			my $src = $sources->{$key};

			# conf.d-sourced: error if value changed, skip if unchanged
			if ($src && $src->{layer} == 3)
			{
				my $raw_val = ref($confd->{$src->{section}}) eq 'HASH'
					? $confd->{$src->{section}}{$key} : undef;
				if (!_config_values_equal($CC->{$section}{$key}, $raw_val))
				{
					return "Cannot modify property '$key' — it is managed by $src->{source}";
				}
				next;
			}

			# ENV-sourced: error if value changed, skip if unchanged
			if ($src && $src->{layer} == 4)
			{
				# ENV values are literal strings, compare against current effective value
				if (!_config_values_equal($CC->{$section}{$key}, $C->{$key}))
				{
					return "Cannot modify property '$key' — it is managed by $src->{source}";
				}
				next;
			}

			# Skip keys whose value matches the default — no need to persist
			next if (ref($defaults->{$section}) eq 'HASH'
				&& exists $defaults->{$section}{$key}
				&& _config_values_equal($CC->{$section}{$key}, $defaults->{$section}{$key}));

			$filtered{$section}{$key} = $CC->{$section}{$key};
		}
	}

	# Backup
	File::Copy::cp($configfile, "$configfile.bak") if (-r "$configfile");

	# If no keys remain, remove the config file
	my $has_keys = grep { ref($filtered{$_}) eq 'HASH' && keys %{$filtered{$_}} } keys %filtered;
	if (!$has_keys)
	{
		unlink($configfile) if (-e $configfile);
		$NMISNG::Util::_config_cache_invalid = 1;
		_notify_config_changed($C->{'<nmis_var>'});
		return undef;
	}

	my $error = NMISNG::Util::writeHashtoFile(file => $configfile, data => \%filtered);
	if (!$error)
	{
		$NMISNG::Util::_config_cache_invalid = 1;
		_notify_config_changed($C->{'<nmis_var>'});
	}
	return $error;
}

# Write a marker file so other processes can detect config has changed on disk.
# args: var_dir (the resolved <nmis_var> path)
sub _notify_config_changed
{
	my ($var_dir) = @_;
	my $dir = "$var_dir/nmis_system";
	mkpath($dir, { verbose => 0, mode => 0755 }) if (!-d $dir);
	my $marker = "$dir/config_changed";
	open(my $fh, ">", $marker) or do {
		warn("cannot write config change marker $marker: $!");
		return;
	};
	print $fh time() . "\n";
	close $fh;
}

# Returns true if config on disk has changed since this process loaded it.
# Processes can poll this to decide whether to restart or reload.
# args: conf (required, loadConfTable result)
sub configChanged
{
	my (%args) = @_;
	my $C = $args{conf} or return 0;
	my $marker = $C->{'<nmis_var>'} . "/nmis_system/config_changed";
	my $mtime = (CORE::stat($marker))[9];
	return 0 if (!defined $mtime);
	return ($mtime > $NMISNG::Util::_config_load_time) ? 1 : 0;
}

# Compare local config (layer 2) against defaults (layer 1) and return
# a stripped version containing only keys that differ from or don't exist in defaults.
# Uses stored raw layer data — no file I/O.
# returns: ($stripped_data, $removals)
#   $stripped_data: deep two-level hashref ready for writeConfData
#   $removals: arrayref of { section => $s, key => $k, value => $v }
sub stripDefaults
{
	loadConfTable(); # ensure loaded
	my $defaults = $_raw_layers{1} // {};
	my $site = $_raw_layers{2} // {};

	my %stripped;
	my @removals;

	for my $section (keys %$site)
	{
		next unless ref($site->{$section}) eq 'HASH';
		for my $key (keys %{$site->{$section}})
		{
			if (ref($defaults->{$section}) eq 'HASH'
				&& exists $defaults->{$section}{$key}
				&& _config_values_equal($site->{$section}{$key}, $defaults->{$section}{$key}))
			{
				push @removals, { section => $section, key => $key, value => $site->{$section}{$key} };
			}
			else
			{
				$stripped{$section}{$key} = $site->{$section}{$key};
			}
		}
	}

	return (\%stripped, \@removals);
}

# Deep equality check for config values (scalars, arrayrefs, hashrefs, regexps, undef)
sub _config_values_equal
{
	my ($a, $b) = @_;
	return 1 if (!defined $a && !defined $b);
	return 0 if (!defined $a || !defined $b);
	my ($ra, $rb) = (ref $a, ref $b);
	return 0 if $ra ne $rb;
	if ($ra eq 'Regexp') { return "$a" eq "$b"; }
	if ($ra eq 'ARRAY')
	{
		return 0 if @$a != @$b;
		for my $i (0..$#$a)
		{
			return 0 if !_config_values_equal($a->[$i], $b->[$i]);
		}
		return 1;
	}
	if ($ra eq 'HASH')
	{
		my @ka = sort keys %$a;
		my @kb = sort keys %$b;
		return 0 if @ka != @kb;
		for my $i (0..$#ka)
		{
			return 0 if $ka[$i] ne $kb[$i];
			return 0 if !_config_values_equal($a->{$ka[$i]}, $b->{$kb[$i]});
		}
		return 1;
	}
	return $a eq $b;
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
			# conf is the third positional arg, not a named pair, so pass it as-is
			push @problems, NMISNG::Util::setFileProtDirectory("$dir/$file", $recurse, $conf);
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
		my $df_out = '';
		if (open(my $pipe, '-|', 'df', '-mP', $dir))
		{
			local $/;
			$df_out = <$pipe> // '';
			close $pipe;
		}
		my @df = split( /\n/, $df_out );
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

		# report what this run force-fixes vs only audits, so it's clear which
		# files and directories are affected (force-fix already ran above)
		$nmisng->log->info("permission_test: force-fixed ownership and perms on "
											 ."$config->{'<nmis_conf>'} (recursive), "
											 ."$config->{'<nmis_var>'} (top level only), "
											 ."$config->{'<nmis_models>'} (top level only)");

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
			$nmisng->log->info("permission_test: auditing ".($where // $location)." (read-only, non-recursive)");

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
			$nmisng->log->info("permission_test: auditing ".($where // $location)." (read-only, recursive)");

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

	# check that there is one and only one nmis scheduler running
	my $schedstatus = (grep($_->cmndline =~ /^nmisd.scheduler\s*$/, @ourprocs));
	if ($schedstatus == 0)
	{
		push @details, ["NMIS daemon", "No scheduler process running!"];
		$allok=0;
	}
	elsif ($schedstatus > 1)
	{
		push @details, ["NMIS daemon", "Multiple scheduler processes are running!"];
		$allok=0;
	}

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

	# Get number of queue jobs
	# check that there is some sort of cron running
	for my $op (qw(collect update))
	{
		$status = undef;
		$allok = 1;
		
		my $max_jobs;
		if ($op =~ /collect/) {
			$max_jobs = $config->{selftest_max_collect_jobs}? $config->{selftest_max_collect_jobs} : 200;
		}
		else {
			$max_jobs = $config->{selftest_max_update_jobs}? $config->{selftest_max_update_jobs} : 400;
		}

		my $queued = $nmisng->get_queue_model(type => $op);
		if (my $fault = $queued->error)
		{
			$status = "Failed to get the queue: $fault";
			$allok = 0;
		}
	
		my $queuedjobs = $queued->data;

		if (@$queuedjobs > $max_jobs)
		{
			$status = "Number of $op jobs ".@$queuedjobs." exceeded. Max allowed $max_jobs";
			$allok = 0;
		}
		
		push @details, ["QUEUE $op", $status];
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

# This function translates a toplevel hash with fields in dot-notation
# into a deep structure.
#
# This is primarily needed in deep data objects handled by the
# crudcontroller but not necessarily just there.
#
# Notations supported:
#    fieldname.number for array,
#    fieldname.subfield for hash and nested combos thereof
#
# args:
#    resource record ref to fix up, which will be changed inplace!
# returns:
#    undef if ok, error message if problems were encountered
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
			else # hash
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

# This function translates a toplevel hash with fields in dot-notation
# into a deep structure and deletes the referenced key.
#
# This is primarily needed in deep data objects handled by the
# crudcontroller but not necessarily just there.
#
# Notations supported:
#    fieldname.number for array,
#    fieldname.subfield for hash and nested combos thereof
#
# args:
#    resource record ref to fix up, which will be changed inplace!
# returns:
#    undef if ok, error message if problems were encountered
sub translate_dotfields_delete
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
					undef($target->[$thisstep])  if (ref(\$target->[$thisstep]) eq "ARRAY");
					delete($target->[$thisstep]) if (ref(\$target->[$thisstep]) eq "SCALAR");
				}
				else
				{
					# check what the next one is and prime the obj
					$target = $target->[$thisstep] ||= ($indir[$idx+1] =~ /^\d+$/? []:  {} );
				}
			}
			else # hash
			{
				# check that structure is ok.
				return "data conflict with $dotkey at step $idx: need hash but found ". (ref($target) || "leaf value")
						if (ref($target) ne "HASH");
				# last one? park value
				if ($idx == $#indir)
				{
					undef($target->{$thisstep})  if (ref(\$target->{$thisstep}) eq "ARRAY");
					delete($target->{$thisstep}) if (ref(\$target->{$thisstep}) eq "SCALAR");
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

	$nmisng->log->debug2(sub {"resolve_dns_name($lookup)"});

	# full ipv6 support works only with newer socket module
	my ($err,@possibles) = Socket::getaddrinfo($lookup, '', {socktype => SOCK_RAW});
	
	if ($err)
	{
		$nmisng->log->debug2(sub {"getaddrinfo error: $err"});
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
			$nmisng->log->debug2(sub {"getnameinfo error: $err"});
		}
		else
		{
			$nmisng->log->debug2(sub {"getnameinfo result: $ipaddr"});
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
		mkpath($replaced, { verbose => 0, mode => 0755 });
		system("chown", "-R", "$C->{nmis_user}:$C->{nmis_group}", $replaced);
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
				system('mv', ($force ? () : '-n'), $fh, $replaced);
				$nmisng->log->error("move $fh -> $replaced failed") if $?;
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
# getTmpDir - Get the proper temporary directory.                      #
########################################################################
sub getTmpDir {
	my $C = loadConfTable();
	return $C->{"<nmis_tmp>"} || $C->{"<nmis_var>"} . "/tmp" || "/tmp";
}

########################################################################
# getProcessOwner - Get Process owner for a given Process ID           #
#                   Returns the UID of the process owner, or           #
#                   -1 if the process is not found.                    #
########################################################################
sub getProcessOwner {
	my $processID    = shift;
	my $processOwner = -1;
	chomp($processID);

	if (int($processID) && -f "/proc/$processID/status")
	{
		my $processInfo = Mojo::File->new("/proc/$processID/status")->slurp();
		$_ = $processInfo =~ /.*Uid:\t*([0-9]*)\t*.*/;
		$processOwner = $1;
	}

	return $processOwner;
}

########################################################################
# shutdownAllDaemons - This function stops ALL FirstWave daemons       #
#                      for both NMIS and OMK.  This is primarily       #
#                      used by EOS to enable or disable it.            #
#                                                                      #
# Returns:                                                             #
#    1 - If the deamons were successfully stopped.                     #
#    0 - If the deamons were not able to be stopped.                   #
########################################################################
sub shutdownAllDaemons {
	if ($< != 0)
	{
		return(0);
	}
	print("Stopping all FirstWave Processes.\n");
	try {
		if (-d "/etc/systemd")
		{
	    	system('systemctl', 'stop', 'nmis9d.service');
			system('systemctl', 'stop', 'omkd.service')      if (-f "/etc/systemd/system/omkd.service");
			system('systemctl', 'stop', 'opchartsd.service') if (-f "/etc/systemd/system/opchartsd.service");
			system('systemctl', 'stop', 'opconfigd.service') if (-f "/etc/systemd/system/opconfigd.service");
			system('systemctl', 'stop', 'opeventsd.service') if (-f "/etc/systemd/system/opeventsd.service");
			system('systemctl', 'stop', 'optrend.service')   if (-f "/etc/systemd/system/optrend.service");
			system('systemctl', 'stop', 'opflowd.service')   if (-f "/etc/systemd/system/opflowd.service");
		}
		else
		{
	    	system('service', 'nmis9d', 'stop');
			system('service', 'omkd',      'stop') if (-f "/etc/init.d/system/omkd");
			system('service', 'opchartsd', 'stop') if (-f "/etc/init.d/system/opchartsd");
			system('service', 'opconfigd', 'stop') if (-f "/etc/init.d/system/opconfigd");
			system('service', 'opeventsd', 'stop') if (-f "/etc/init.d/system/opeventsd");
			system('service', 'optrend',   'stop') if (-f "/etc/init.d/system/optrend");
			system('service', 'opflowd',   'stop') if (-f "/etc/init.d/system/opflowd");
		}
	}
	catch
	{
		return(0);
	}

	return(1);
}

########################################################################
# startAllDaemons - This function starts ALL FirstWave daemons         #
#                      for both NMIS and OMK.  This is primarily       #
#                      used by EOS to enable or disable it.            #
#                                                                      #
# Returns:                                                             #
#    1 - If the deamons were successfully startped.                    #
#    0 - If the deamons were not able to be startped.                  #
########################################################################
sub startAllDaemons {
	if ($< != 0)
	{
		return(0);
	}
	print("Starting all FirstWave Processes.\n");
	try {
		if (-d "/etc/systemd")
		{
	    	system('systemctl', 'start', 'nmis9d.service');
			system('systemctl', 'start', 'omkd.service')      if (-f "/etc/systemd/system/omkd.service");
			system('systemctl', 'start', 'opchartsd.service') if (-f "/etc/systemd/system/opchartsd.service");
			system('systemctl', 'start', 'opconfigd.service') if (-f "/etc/systemd/system/opconfigd.service");
			system('systemctl', 'start', 'opeventsd.service') if (-f "/etc/systemd/system/opeventsd.service");
			system('systemctl', 'start', 'optrend.service')   if (-f "/etc/systemd/system/optrend.service");
			system('systemctl', 'start', 'opflowd.service')   if (-f "/etc/systemd/system/opflowd.service");
		}
		else
		{
	    	system('service', 'nmis9d', 'start');
			system('service', 'omkd',      'start') if (-f "/etc/init.d/system/omkd");
			system('service', 'opchartsd', 'start') if (-f "/etc/init.d/system/opchartsd");
			system('service', 'opconfigd', 'start') if (-f "/etc/init.d/system/opconfigd");
			system('service', 'opeventsd', 'start') if (-f "/etc/init.d/system/opeventsd");
			system('service', 'optrend',   'start') if (-f "/etc/init.d/system/optrend");
			system('service', 'opflowd',   'start') if (-f "/etc/init.d/system/opflowd");
		}
	}
	catch
	{
		return(0);
	}

	return(1);
}

########################################################################
# askYesNo - Ask a yes/no question to the terminal.                   #
########################################################################
sub askYesNo
{
	my ($prompt, $default) = @_;
	my $answer             = "";
	my $quit               = 0;

	until ($quit)
	{
		print("$prompt ");
		chomp(my $input = <STDIN>);
		if ($input =~ /(^true$)|(^yes$)|(^t$)|(^y$)|(^1$)/i)
		{
			$answer = 1;
			$quit = 1;
		}
		elsif ($input =~ /(^false$)|(^no$)|(^f$)|(^n$)|(^0$)/i)
		{
			$answer = 0;
			$quit = 1;
		}
		elsif ($input eq "" && defined($default))
		{
			if ($default =~ /(^true$)|(^yes$)|(^t$)|(^y$)|(^1$)/i)
			{
				$answer = 1;
				$quit = 1;
			}
			elsif ($default =~ /(^false$)|(^no$)|(^f$)|(^n$)|(^0$)/i)
			{
				$answer = 0;
				$quit = 1;
			}
		}
		if (!$quit)
		{
			print("Invalid Response: '$input'!\n");
		}
	}

	return($answer);
}

########################################################################
# isEOSAvailable - Test whether EOS can be enabled                     #
#                                                                      #
# Returns:                                                             #
#    1 - If Encryption of secrets can be enabled.                      #
#    0 - If Encryption of secrets is missing required libraries.       #
########################################################################
sub isEOSAvailable
{
	my $ok                 = 1;
	my $config             = loadConfTable();
	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	my %eosCurrentVers;
	my %eosEOSVersion;
	my %eosMinVersions     = (
								'opCharts'   => "4.7.0",
								'opEvents'   => "4.4.0",
								'opAddress'  => "3.0.0",
								'opHA'       => "4.0.0",
								'opConfig'   => "4.6.0",
								'opReports'  => "4.6.0",
								'Open-AudIT' => "4.4.0",
								'NMIS'       => "9.5.0"
							);

	print ("Checking ...\n");
	eval {require Crypt::CBC;};
	if($@)
	{
		$ok = 0;
		print ("Module: 'Crypt::CBC' is missing.\n");
	}
	eval {require Crypt::Cipher::AES;};
	if($@)
	{
		$ok = 0;
		print ("Module: 'Crypt::Cipher::AES' is missing.\n");
	}
	eval {require Math::Random::Secure;};
	if($@)
	{
		$ok = 0;
		print ("Module: 'Math::Random::Secure' is missing.\n");
	}
    if ($ok)
	{
		my $output;
		my $omkDir;
		my $omkSystemState;
		$output = sprintf("   Product          Current Version    Required Version      EOS supported?\n");
		$output = sprintf("${output}================================================================================\n");
		my $nmis_cli = $config->{'<nmis_bin>'} . '/nmis-cli';
		my $ver_raw = '';
		if (open(my $pipe, '-|', $nmis_cli, '--version'))
		{
			local $/;
			$ver_raw = <$pipe> // '';
			close $pipe;
		}
		my $nmisVersion = (split(/=/, $ver_raw, 2))[1] // '';
		chomp($nmisVersion);
		$eosCurrentVers{"NMIS"} = $nmisVersion;

		my $nmisMinVersion = version->parse($eosMinVersions{NMIS});
		my $nmisCurVersion = version->parse($nmisVersion);

		my $answer = ($nmisCurVersion >= $nmisMinVersion) ? "YES" : "NO";
		$ok = 0 if ($answer eq 'NO');
		$eosEOSVersion{NMIS} = $answer;
		$output = sprintf("${output}   %10s%20s%20s%10s\n", "NMIS", $eosCurrentVers{NMIS}, $eosMinVersions{NMIS},$eosEOSVersion{NMIS});
		if ( -f "/etc/systemd/system/omkd.service" )
		{
			my $unit_src = '';
			if (open(my $pipe, '-|', 'grep', 'ExecStart=', '/etc/systemd/system/omkd.service'))
			{
				local $/;
				$unit_src = <$pipe> // '';
				close $pipe;
			}
			my $unit_exec = (split(' ', (split(/=/, $unit_src, 2))[1] // '', 2))[0] // '';
			$unit_exec =~ s{^["']|["']$}{}g;
			($omkDir = $unit_exec) =~ s{/script/opmantek\.pl}{};
		}
		elsif ( -f "/etc/init.d/omkd" )
		{
			my $init_src = '';
			if (open(my $pipe, '-|', 'grep', 'DAEMON=', '/etc/init.d/omkd'))
			{
				local $/;
				$init_src = <$pipe> // '';
				close $pipe;
			}
			my $init_exec = (split(' ', (split(/=/, $init_src, 2))[1] // '', 2))[0] // '';
			$init_exec =~ s{^["']|["']$}{}g;
			($omkDir = $init_exec) =~ s{/script/opmantek\.pl}{};
		}
		chomp($omkDir);
		if ( "$omkDir" eq "" && -f "/usr/local/omk" )
		{
			$omkDir  = '/usr/local/omk';
		}
		if ( "$omkDir" eq "" )
		{
			print ("Unable to find OMK installation; cannot determine if OMK supports EOS.\n");
		}
		else
		{
			if (-e "$omkDir/manifest")
			{
				$omkSystemState = do "$omkDir/manifest" or print ("Unable to determine if OMK supports EOS.\n");
			}
			foreach my $eachProduct (keys  (%{ $omkSystemState->{products} }))
			{
				#our current version from the manifest
				my $versionOutput = $omkSystemState->{products}{$eachProduct}{version};
				chomp($versionOutput);
				$eosCurrentVers{"$eachProduct"} = $versionOutput;
				my $omkMinVersion = version->parse($eosMinVersions{$eachProduct});
				my $omkCurVersion = version->parse($versionOutput);
				$answer = ($omkCurVersion >= $omkMinVersion) ? "YES" : "NO";
				$ok = 0 if ($answer eq 'NO');
				$eosEOSVersion{"$eachProduct"} = $answer;
				$output = sprintf("${output}   %10s%20s%20s%10s\n", $eachProduct, $eosCurrentVers{$eachProduct}, $eosMinVersions{$eachProduct},$eosEOSVersion{$eachProduct});
			}
		}
		print("\r$output");
	}
    if ($ok)
	{
		if (!testEncryption())
		{
			print ("Encryption key seem to be corrupt.\n");
			return(0);
		}
		else
		{
			if ($encryption_enabled)
			{
				print ("Encryption of Secrets can be enabled, and already is.\n");
			}
			else
			{
				print ("Encryption of Secrets can be enabled.\n");
			}
			return(1);
		}
    }
    else
    {
		if ($encryption_enabled)
		{
			print ("Encryption of Secrets should not be enabled, but already is.\n");
		}
		else
		{
			print ("Encryption of Secrets can not be enabled.\n");
		}
        return(0);
    }
}

########################################################################
# testEncryption - Test that encryption works.                         #
#                                                                      #
# Returns:                                                             #
#    1 - If round trip encription succeeds.                            #
#    0 - If round trip encription fails.                               #
########################################################################
sub testEncryption {
	eval {require Crypt::CBC; require Crypt::Cipher::AES; require Math::Random::Secure;};
	if($@)
	{
		return(0);
	}
    my $secretWord    = "ThisIsASecretWord";
    my $encryptedPass = encrypt($secretWord, '', '', 1);
#	print STDERR "Encrypted Password is '$encryptedPass'\n";
	return 0 if (substr($encryptedPass, 0, 2) ne "!!");
    my $password      = decrypt($encryptedPass);
    if ($password eq $secretWord)
    {
        return(1);
    }
    else
    {
        return(0);
    }
}

########################################################################
# checkEOS - Check if EOS is enabled or not.                           #
#                                                                      #
# Returns:                                                             #
#    1 - If Encryption of Secrets is enabled.                          #
#    0 - If Encryption of Secrets is disabled.                         #
########################################################################
sub checkEOS {
	my $config             = loadConfTable();
	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	if ($encryption_enabled)
	{
		return 1;
	}
	else
	{
		return 0;
	}
}

########################################################################
# disableEOS - Disable Encryption of Secrets.                          #
#              NOTE:  THIS WILL STOP ALL DEAMONS TO PERFORM THIS       #
#                     FUNCTION!                                        #
#                                                                      #
# Returns:                                                             #
#    1 - If the request was successful. (encryption is disabled)       #
#    0 - If the request failed.                                        #
########################################################################
sub disableEOS {
	my $config  = loadConfTable();
	my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
	my $logger  = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);

	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	if (!$encryption_enabled)
	{
		print("Encryption of secrets is already disabled.\n");
		return(1);
	}
	if ($< != 0)
	{
		print("Disabling encryption of secrets requires root permission!\n");
		return(0);
	}
	my $rc = shutdownAllDaemons();
	if ($rc)
	{
		$logger->info("Disabling Encryption of secrets.");
		print("Disabling Encryption of secrets.\n");
		my ($fullConfig,undef) = getConfDeep(only_local => 1);
		$fullConfig->{globals}{global_enable_password_encryption} = "false";
		writeConfData(data=>$fullConfig);
		# We changed encryption, so the test below is backwards.
		# If it indicates changes, then we failed!
		my $success = verifyNMISEncryption(log => $logger);
		my $startMsg;
		if (!$success)
		{
			$startMsg = "Encryption was successfully disabled.";
			$logger->info("$startMsg");
			print("$startMsg\n");
		}
		else
		{
			$startMsg = "Encryption could not be disabled.";
			$logger->error("ERROR: $startMsg");
			print("$startMsg\n");
		}
		$rc = startAllDaemons();
		if (!$rc)
		{
			$logger->warn("WARN: $startMsg, but restarting the processes did not succeed.");
			print("$startMsg, but restarting the processes did not succeed.\n");
		}
		return(!$success);
	}
	else
	{
		$logger->error("ERROR: Encryption could not be disabled (daemons could not be stopped).");
		print("Encryption could not be disabled (daemons could not be stopped).\n");
		return(0);
	}
}

########################################################################
# enableEOS - Enable Encryption of Secrets.                            #
#              NOTE:  THIS WILL STOP ALL DEAMONS TO PERFORM THIS       #
#                     FUNCTION!                                        #
#                                                                      #
# Returns:                                                             #
#    1 - If the request was successful. (encryption is enabled)        #
#    0 - If the request failed.                                        #
########################################################################
sub enableEOS {
	my $config  = loadConfTable();
	my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
	my $logger  = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);
	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	if ($encryption_enabled)
	{
		print("Encryption of secrets is already enabled.\n");
		return(1);
	}
	if ($< != 0)
	{
		print("Enabling encryption of secrets requires root permission!\n");
		return(0);
	}
	if (testEncryption())
	{
		my $rc = shutdownAllDaemons();
		if ($rc)
		{
			$logger->info("Enabling encryption of secrets.");
			print("Enabling encryption of secrets.\n");
			my ($fullConfig,undef) = getConfDeep(only_local => 1);
			$fullConfig->{globals}{global_enable_password_encryption} = "true";
			writeConfData(data=>$fullConfig);
			# We changed encryption, so the test below is backwards.
			# If it indicates changes, then we failed!
			my $success = verifyNMISEncryption(log => $logger);
			my $startMsg;
			if (!$success)
			{
				$startMsg = "Encryption was successfully enabled.";
				$logger->info("$startMsg");
				print("$startMsg\n");
			}
			else
			{
				$startMsg = "Encryption could not be enabled.";
				$logger->error("ERROR: $startMsg");
				print("$startMsg\n");
			}
			$rc = startAllDaemons();
			if (!$rc)
			{
				$logger->warn("WARN: $startMsg, but restarting the processes did not succeed.");
				print("$startMsg, but restarting the processes did not succeed.\n");
			}
			return(!$success);
		}
		else
		{
			$logger->error("ERROR: Encryption could not be disabled (daemons could not be stopped).");
			print("Encryption could not be disabled (daemons could not be stopped).\n");
			return(0);
		}
	}
	else
	{
		$logger->error("ERROR: Encryption of secrets encryption test failed, EOS cannpt be enabled!");
		print("Encryption of secrets encryption test failed, EOS cannpt be enabled!");
		return(0);
	}
}

########################################################################
# verifyNMISEncryption - Verify Password encrypred strings.            #
#                                                                      #
# Returns:                                                             #
#    0 - If nothing was changed.                                       #
#    1 - If Encryption of secrets was reversed.                        #
########################################################################
sub verifyNMISEncryption {
	my (%args)   = @_;
	my $logger   = $args{log};
	# We create seed file in ./installer_hooks/20-postcopy-user as installer always runs with root permissions:
	my $seeddir  = '/usr/local/etc/firstwave/';
	my $seedfile = '/usr/local/etc/firstwave/master.key';
	my $epochNow = time;
	my $timeNow  = localtime;
	my %protected;
	my $config;
	my $fh;
	my $changed = 0;

	$config = loadConfTable();

	my $nmis_encryption_enabled = getbool($config->{'global_enable_password_encryption'});

	my ($fullConfig,undef) = getConfDeep(only_local => 1);
	eval {require Crypt::CBC; require Crypt::Cipher::AES; require Math::Random::Secure; };
	if($@)
	{
		$logger->error("ERROR: 'Crypt::CBC' and 'Crypt::Cipher::AES', and 'Math::Random::Secure' must be installed in order to enable password encryption!");
		$logger->error("ERROR: Password encryption cannot be enabled!");
		$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
		if ($nmis_encryption_enabled)
		{
			$logger->error("ERROR: The configuration option 'global_enable_password_encryption' is set to 'true'!");
			$logger->error("Disabling Encryption of secrets.");
			$fullConfig->{globals}{global_enable_password_encryption} = "false";
			$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
			writeConfData(data=>$fullConfig);
			return(1);
		}
		else
		{
			return(0);
		}
	}
	if ($nmis_encryption_enabled)
	{
		if (!testEncryption())
		{
			$logger->error("ERROR: Encryption is not working!");
			$logger->error("ERROR: Password encryption will be disabled!");
			$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
			$fullConfig->{globals}{global_enable_password_encryption} = "false";
			writeConfData(data=>$fullConfig);
			return(1);
		}
		# Make sure we have a seed file.
		if (!-f "$seedfile") {
			_make_seed($seedfile, $logger);
		}
		my $installDir = $config->{'<nmis_base>'} . "/conf-default";
		if (open($fh, '<', $installDir . '/PasswordFields.nmis'))
		{
			my @passwordFieldRows = <$fh>;
			close $fh;
			foreach my $eachRow (@passwordFieldRows)
			{
				chomp($eachRow);
				next if ($eachRow eq '');
				my @fieldsArray = split(/:/, $eachRow);
				my $count       = scalar @fieldsArray;
				if ($count == 2)
				{
					if (ref($fullConfig->{$fieldsArray[0]}) eq "HASH")
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) ne "!!")
						{
							$protected{$eachRow} = $password;
							my $encrypted_pw = encrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]} = $encrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 3)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) ne "!!")
						{
							$protected{$eachRow} = $password;
							my $encrypted_pw = encrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]} = $encrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 4)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) ne "!!")
						{
							$protected{$eachRow} = $password;
							my $encrypted_pw = encrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]} = $encrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 5)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}->{$fieldsArray[4]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) ne "!!")
						{
							$protected{$eachRow} = $password;
							my $encrypted_pw = encrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}->{$fieldsArray[4]} = $encrypted_pw;
							$changed = 1;
						}
					}
				}
				else
				{
					$logger->error("Unable to parse entry in '$eachRow' 'PasswordFields.nmis'.");
				}
			}
		}
		else
		{
			$logger->error("File '$installDir/PasswordFields.nmis' was not found, unable to synchronize encyption settings between NMIS and OMK.");
		}
		if ($changed)
		{
			writeConfData(data=>$fullConfig);
			my $protectedFile = "$seeddir/NMIS-$epochNow";
			unless(open($fh, '>', $protectedFile)) {
				$logger->error("Unable to backup Passwords.");
			}
			else
			{
				print $fh ("Created on $timeNow.\n");
				foreach my $eachRow (keys %protected)
				{
					print $fh ("$eachRow = $protected{$eachRow}\n");
				}
				close $fh;
				chown(0, 0, $protectedFile);
				chmod(0400, $protectedFile);
			}
		}
		return(0);
	}
	else
	{
		my ($fullConfig,undef) = getConfDeep(only_local => 1);
		my $installDir = $config->{'<nmis_base>'} . "/conf-default";
		if (open($fh, '<', $installDir . '/PasswordFields.nmis'))
	   	{
			my @passwordFieldRows = <$fh>;
			close $fh;
			foreach my $eachRow (@passwordFieldRows)
			{
				chomp($eachRow);
				next if ($eachRow eq '');
				my @fieldsArray = split(/:/, $eachRow);
				my $count       = scalar @fieldsArray;
				if ($count == 2)
				{
					if (ref($fullConfig->{$fieldsArray[0]}) eq "HASH")
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) eq "!!")
						{
							my $decrypted_pw = decrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]} = $decrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 3)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) eq "!!")
						{
							my $decrypted_pw = decrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]} = $decrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 4)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) eq "!!")
						{
							my $decrypted_pw = decrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]} = $decrypted_pw;
							$changed = 1;
						}
					}
				}
				elsif ($count == 5)
				{
					if ((ref($fullConfig->{$fieldsArray[0]}) eq "HASH") && (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}) eq "HASH") &&
					   (ref($fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}) eq "HASH"))
					{
						my $password     = $fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}->{$fieldsArray[4]};
						if (defined($password) && $password ne '' && substr($password, 0, 2) eq "!!")
						{
							my $decrypted_pw = decrypt($password);
							$fullConfig->{$fieldsArray[0]}->{$fieldsArray[1]}->{$fieldsArray[2]}->{$fieldsArray[3]}->{$fieldsArray[4]} = $decrypted_pw;
							$changed = 1;
						}
					}
				}
				else
				{
					$logger->error("Unable to parse entry in '$eachRow' 'PasswordFields.nmis'.");
				}
			}
		}
		else
		{
			$logger->error("File '$installDir/PasswordFields.nmis' was not found, unable to synchronize encyption settings between NMIS and OMK.");
		}
		if ($changed)
		{
			writeConfData(data=>$fullConfig);
		}
		return(0);
	}
}

########################################################################
# decrypt - Decrypt the password.                                      #
########################################################################
sub decrypt {
	my ($password, $section, $keyword) = @_;
	my $config;
	my $logger;

	# Passed nothing or an empty string.
	return "" if (!defined($password) || $password eq '');

	$config = loadConfTable();

	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	# the password does not look encrypted and encryption is disabled so don't try
	if ((substr($password, 0, 2) ne "!!") && (!$encryption_enabled))
	{
		return $password;
	}
	
	my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
	$logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);
	
	eval {require Crypt::CBC; require Crypt::Cipher::AES; require Math::Random::Secure;};
	if($@)
	{
		$logger->error("ERROR: 'Crypt::CBC' and 'Crypt::Cipher::AES', and 'Math::Random::Secure' must be installed in order to enable password encryption!");
		$logger->error("ERROR: Password encryption cannot be enabled!");
		if ($encryption_enabled)
		{
			$logger->error("ERROR: The configuration option 'global_enable_password_encryption' is set to 'true'!");
			$logger->error("Disabling Encryption of secrets.");
			my ($fullConfig,undef) = getConfDeep(only_local => 1);
			$fullConfig->{globals}{global_enable_password_encryption} = "false";
			writeConfData(data=>$fullConfig);
			return $password;
		}
	}

	$logger->debug("Encryption is '" . $encryption_enabled . "'.");
	
	# We create seed file in ./installer_hooks/20-postcopy-user as installer always runs with root permissions:
	my $seedfile           = '/usr/local/etc/firstwave/master.key';
	my $strLen             = "";
	my $fh;

	$logger->debug9(sub {"Seedfile name is '" . $seedfile . "'."});

	# Make sure we have a seed file.
	if (!-f "$seedfile") {
		_make_seed($seedfile, $logger);
	}

	# If the password is not currently encrypted, then we just return what we have.
	if (substr($password, 0, 2) ne "!!") {
		# Encryption is enabled.
		if ($encryption_enabled) {
			# If the 'section and 'keyword' arguments are passed, it means we are
			# dealing with the configuration file, so we we encrypt it in the file.
			if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
				# Get the non-flattened raw hash
				my ($fullConfig,undef) = getConfDeep(only_local => 1);
				$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
				my $encrypted_pw = encrypt($password);
				if ($fullConfig->{$section}{$keyword} ne $encrypted_pw) {
					$logger->debug3(sub {"Encrypting the password for Section: '$section' Field: '$keyword'"});
					$fullConfig->{$section}{$keyword} = $encrypted_pw;
					$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
					writeConfData(data=>$fullConfig);
				}
			}
		} else {
			$logger->debug9(sub {"Encryption is disabled."});
		}
		return $password;
	} else {
		$password = substr($password, 2);
	}
	if (open($fh, '<', $seedfile)) {
		my $seed = <$fh>;
		close $fh;
		chomp($seed);
		my $cipherHandle = Crypt::CBC->new( -key    => "$seed",
											-cipher => 'Cipher::AES',
											-pbkdf  => 'pbkdf2'
											);
		my $error = 0;
		try {
		   $password = $cipherHandle->decrypt_hex($password);
#			print STDERR  ("Password '$password.\n");
		}
   		catch {
			$error = $_ || 'Unknown failure!';
		};
		if ($error || $password eq "") {
#			print STDERR  ("Password decryption failure, Error: $error\n");
			$logger->error("Password decryption failure, Error: $error");
			$password = "";
		} else {
			$strLen   = substr($password, 0, 3);
			if ($strLen !~ /^\d+$/)
			{
#				print STDERR  ("Password decryption failure, Error: Received corrupted String, possible seed file modification.\n");
				$password = "";
			} else {
#				print STDERR  ("Password Length '$strLen'.\n");
				$password = substr($password, 3, $strLen);
#				print STDERR  ("Password '$password.\n");
				# Encryption is disabled, unencrypt whatever we encounter.
				if (!$encryption_enabled) {
					# If we have an encrypted password in the configuration file, then we unencrypt it.
					# (If the 'section and 'keyword' arguments are passed, it means we are dealing with the configuration file)
					if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
						# Get the non-flattened raw hash
						my ($fullConfig,undef) = getConfDeep(only_local => 1);
						$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
						if ($fullConfig->{$section}{$keyword} ne $password) {
							$logger->debug3(sub {"Decrypting the password for Section: '$section' Field: '$keyword'"});
							$fullConfig->{$section}{$keyword} = $password;
							$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
							writeConfData(data=>$fullConfig);
						}
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
	my ($password, $section, $keyword, $force) = @_;
	my $config;
	my $logger;

	# Passed nothing or an empty string.
	return "" if (!defined($password) || $password eq '');

	$config = loadConfTable();
	
	my $encryption_enabled = getbool($config->{'global_enable_password_encryption'});
	# the password does not look encrypted and encryption is disabled so don't try
	if ((substr($password, 0, 2) ne "!!") && (!$encryption_enabled && !$force))
	{
		return $password;
	}

	my $logfile = "$config->{'<nmis_logs>'}/nmis.log";
	$logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $config->{log_level}), path  => $logfile);
	
	eval {require Crypt::CBC; require Crypt::Cipher::AES; require Math::Random::Secure;};
	if($@)
	{
		$logger->error("ERROR: 'Crypt::CBC' and 'Crypt::Cipher::AES', and 'Math::Random::Secure' must be installed in order to enable password encryption!");
		$logger->error("ERROR: Password encryption cannot be enabled!");
		if ($encryption_enabled && !$force)
		{
			$logger->error("ERROR: The configuration option 'global_enable_password_encryption' is set to 'true'!");
			$logger->error("Disabling Encryption of secrets.");
			my ($fullConfig,undef) = getConfDeep(only_local => 1);
			$fullConfig->{globals}{global_enable_password_encryption} = "false";
			writeConfData(data=>$fullConfig);
		}
		return $password;
	}

	$logger->debug("Encryption is '" . $encryption_enabled . "'.");

	# We create seed file in ./installer_hooks/20-postcopy-user as installer always runs with root permissions:
	my $seedfile           = '/usr/local/etc/firstwave/master.key';
	my $strLen             = 0;
	my $fh;

	$logger->debug9(sub {"Seedfile name is '" . $seedfile . "'."});

	if (!-f "$seedfile") {
		_make_seed($seedfile, $logger);
	}

	# Passed already encrypted string.
	if (substr($password, 0, 2) eq "!!") {
		# Encryption is disabled, decrypt whatever we encounter and return that.
		if (!$encryption_enabled && !$force) {
			# If we have an encrypted password in the configuration file, then we decrypt it.
			my $decrypted_pw = decrypt($password);
			# If the 'section and 'keyword' arguments are passed, it means we are
			# dealing with the configuration file, so we we decrypt it in the file.
			if (defined($section) && defined($keyword) && $section ne '' && $keyword ne '') {
				# Get the non-flattened raw hash
				my ($fullConfig,undef) = getConfDeep(only_local => 1);
				$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
				if ($fullConfig->{$section}{$keyword} ne $decrypted_pw) {
					$logger->debug3(sub {"Decrypting the password for Section: '$section' Field: '$keyword'"});
					$fullConfig->{$section}{$keyword} = $decrypted_pw;
					$logger->debug9(sub {"Config '" .  Dumper($fullConfig) . "'."});
					writeConfData(data=>$fullConfig);
				}
			}
			return $decrypted_pw;
		} else {
			$logger->debug9(sub {"Encryption is enabled."});
		}
		return $password;
	}

	if ($encryption_enabled || $force) {
		if (open($fh, '<', $seedfile)) {
			my $seed = <$fh>;
			close $fh;
			chomp($seed);
			$strLen	   = sprintf("%03d", length($password));
			$password  = $strLen.$password;
	
			my $cipherHandle = Crypt::CBC->new( -key    => "$seed",
												-cipher => 'Cipher::AES',
												-pbkdf  => 'pbkdf2'
												);
			my $error = 0;
			try {
				$password = $cipherHandle->encrypt_hex($password);
			}
			catch {
				$error = $_ || 'Unknown failure!';
			};
			if ($error) {
				$logger->error("Password encryption failure.; Error $error");
				$password = "";
			} else {
				$password = "!!" . $password;
			}
		} else {
			$logger->error("Password encryption failure.");
			$password = "";
		}
	}

	return $password;
}

########################################################################
# _make_seed - Create an encryption seed file.                         #
########################################################################
sub _make_seed {
	my $seedfile  = shift;
	my $logger    = shift;

	# We create seed file in ./installer_hooks/20-postcopy-user as installer always runs with root permissions:
	my $seeddir  = File::Spec->rel2abs(dirname(${seedfile}));
	my @charset  = (('A'..'Z'), ('a'..'z'), (0..9));
	my $range    = $#charset + 1;
	my $fh;
	my $seed;

	if ($< != 0)
	{
		die "Security is not configured.  Security configuration requires root permission!\n";
	}
	$logger->info("Creating Encryption seed file.");

	for (1..256) {
		$seed .= $charset[int(Math::Random::Secure::rand($range))];
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
	$logger->info("Encryption seed file created.");

	return 0;
}
# take pregen'd sequence of fractions, returns percentile
# input: percentile, sequence
# output: the value
#
# from https://metacpan.org/dist/Math-Utils/source/lib/Math/Utils.pm our $VERSION = '1.14';
sub _ceil
{
		return wantarray? map(($_ > 0 and int($_) != $_)? int($_ + 1): int($_), @_):
				($_[0] > 0 and int($_[0]) != $_[0])? int($_[0] + 1): int($_[0]);
}
sub percentile
{
		my ($percentile,@sequence) = @_;
		my $sequence_ref = \@sequence;

		die "percentile must be 0 > percentile <= 100\n"
				if ( (!defined $percentile) or ($percentile > 100) or ($percentile <= 0) );

		# PERL RETURNS AN ARRAY OF 1 ELEMENT EQUAL undef
		# WHEN PASSING UNDEFINED ARRAYS AND NOT ARRAY REFERENCES TO A FUNCTION:
		my $array_length = ( (@$sequence_ref) and (defined @$sequence_ref[0]) )? scalar @$sequence_ref: 0;

		# OMK-8362: We have historically returned 0.0 (zero) for $array_length == 0.0
		#			We are continuing to return 0.0 (zero) and not 'N/A',
		#			so we back off of this strict implementation and rather return 0.0
		#			as there is only risk in failing here when the outcome is the same: no data = 0.0, not 'N/A':
		return 0.0 if ($array_length == 0);
		###die "array must have length > 0" if ($array_length == 0);

		$percentile /= 100;

		return (sort { $a <=> $b } @$sequence_ref)[ _ceil($percentile * $array_length)-1 ];
}

#Wrapper around Mojo::File to handle spew/spurt from mojo 9.34
sub spew_file
{
	my ($file, $data) = @_;
	if (Mojo::File->can('spew'))
	{
        Mojo::File->new($file)->spew($data);
    } 
	else
	{
        Mojo::File->new($file)->spurt($data);
    }
}


1;
