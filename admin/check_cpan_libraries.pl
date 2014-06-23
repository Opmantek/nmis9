#!/usr/bin/perl
#
## $Id: check_cpan_libraries.pl,v 8.2 2012/05/24 13:24:37 keiths Exp $
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

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use NMIS::Timing;

my $t = NMIS::Timing->new();

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $log = 0;
$log = 1 if $arg{log};


my $debug = 0;
$debug = 1 if $arg{debug};

# Load the NMIS Config
my $C = loadConfTable(conf=>$arg{conf},debug=>$debug);

print $t->elapTime(). " Processing NMIS Code Base and Verifying all the Code and Configuration Files\n" if $log;

use strict;
#use warnings;
use DirHandle;
use Data::Dumper;
#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
#use File::Copy;
use File::Find;
#use File::Path;
use Cwd;

my $site;

my $install = 0;
my $debug = 0;
my $GML = 1;
my $CSV = 1;


print qx|clear|;
print <<EOF;
This script will check for CPAN libraries and determine what is missing.
EOF
#
print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Checking Perl version...
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

my $ver = ref($^V) eq 'version' ? $^V->normal : ( $^V ? join('.', unpack 'C*', $^V) : $] );
my $perl_ver_check = '';
if ($] < 5.006001) {  # our minimal requirement for support
	print qq|The version of Perl installed on your server is lower than the minimum supported version 5.6.1. Please upgrade to at least Perl 5.6.1|;
}
else {
	print qq|The version of Perl installed on your server $ver is OK\n|;
}

print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Checking for required Perl modules
++++++++++++++++++++++++++++++++++++++++++++++++++++++

This script checks for installed modules,
first by parsing the src code to build a list of used modules.
Then by checking that the module exists in the src code
or is found in the perl standard @INC directory list.

If the check reports that a required module is missing, which can be installed with CPAN

 		perl -MCPAN -e shell
		 install [module name]

EOF
#

my $src = cwd() . $ARGV[0];
$src = input_str("Full path to distribution folder:", $src);
my $libPath = "$src/lib";


my %nmisModules;			# local modules used in our scripts
my $mod;

# Check that all the local libaries required by NMIS8, are available to us.
# when a module is found, parse it for its own reqired modules, so we build a complete install list
# the nmis base is assumed to be one dir above us, as we should be run from <nmisbasedir>/install folder

# nowlist the missing 1 by 1, and install if user says OK.
if ( input_yn("Check for NMIS required modules:") ) {
	# loop over the check and install script

	find(\&getModules, "$src");

	# now determine if installed or not.
	foreach my $mod ( keys %nmisModules ) {

		my $mFile = $mod . '.pm';
		# check modules that are multivalued, such as 'xx::yyy'	and replace :: with directory '/'
		$mFile =~ s/::/\//g;
		# test for local include first
		if ( -e "$libPath/$mFile" ) {
			$nmisModules{$mod}{file} = "$libPath/$mFile" . "\t\t" . &moduleVersion("$libPath/$mFile");
		}
		else {
			# Now look in @INC for module path and name
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" ) {
					$nmisModules{$mod}{file} = "$path/$mFile" . "\t\t" . &moduleVersion("$path/$mFile");
				}
			}
		}

	}

	listModules();
	
	saveDependancyCSV() if $CSV;
	saveDependancyGml() if $GML;
}


# this is called for every file found
sub getModules {

	my $file = $File::Find::name;		# full path here

	return if ! -r $file;
	return unless $file =~ /\.pl|\.pm$/;
	parsefile( $file );
}

# this could be used again to find all module dependancies - TBD
sub parsefile {
	my $f = shift;

	open my $fh, '<', $f or print "couldn't open $f\n" && return;

	while (my $line = <$fh>) {
		chomp $line;
		next unless $line;
		
		# test for module use 'xxx' or 'xxx::yyy' or 'xxx::yyy::zzz'
		if ( $line =~ m/^#/ ) {
			next;
		}
		elsif ( 
			$line =~ m/^(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ 
			or $line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+)/ 
			or $line =~ m/(use|require)\s+(\w+);/ 
		) {
			my $mod = $2;
			if ( defined $mod and $mod ne '' and $mod !~ /^\d+/ ) {
				$nmisModules{$mod}{file} = 'NFF';					# set all as 'NFF' here, will check installation status of '$mod' next
				$nmisModules{$mod}{type} = $1;
				if (not grep {$_ eq $f} @{$nmisModules{$mod}{by}}) {
					push(@{$nmisModules{$mod}{by}},$f);
				}
			}
		}
		elsif ($line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ ) {
			print "PARSE $f: $line\n" if $debug;
		}

	}	#next line of script
	close $fh;
}



# get the module version
# this is non-optimal, but gets the task done with no includes or 'use modulexxx'
# whhich would kill this script :-)
sub moduleVersion {
	my $mFile = shift;
	open FH,"<$mFile" or return 'FileNotFound';
	while (<FH>) {
		if ( /(?:our\s+\$VERSION|my\s+\$VERSION|\$VERSION|\s+version|::VERSION)/i ) {
			/(\d+\.\d+(?:\.\d+)?)/;
			if ( defined $1 and $1 ne '' ) {
				return " $1";
			}
		}
	}
	close FH;
	return ' ';
}

sub listModules {

	# list modules found/NFF
	my $f1;
	my $f2;
	my $f3;

	format =
  @<<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @>>>>>>>>>
  $f1,                     $f2,                                      $f3
.

	foreach my $k (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file} } keys %nmisModules) {
		$f1 = $k;
		( $f2 , $f3) = split /\s+/, $nmisModules{$k}{file}, 2;
		$f3 = ' ' if !$f3;
		write();
	}
	
	print qq|
You will need to investigate and possibly install modules indicated with NFF

The modules Net::LDAP, Net::LDAPS, IO::Socket::SSL, Crypt::UnixCrypt, Authen::TacacsPlus, Authen::Simple::RADIUS are optionally required by the NMIS AAA system.

|;
	
	print Dumper \%nmisModules if $debug;
}


# question , return true if y, else 0 if no, default is yes.
sub input_yn {

	print STDOUT qq|$_[0] ? <Enter> to accept, any other key for 'no'|;
	my $input = <STDIN>;
	chomp $input;
	return 1 if $input eq '';
	return 0;
}

# question, default answer
sub input_str {

		my $str = $_[1];
		
	while (1) {{
		print STDOUT qq|$_[0]: [$str]: type new value or <Enter> to accept default: |;
		my $input = <STDIN>;
		chomp $input;
		$str = $input if $input ne '';
		print qq|You entered [$str] -  Is this correct ? <Enter> to accept, or any other key to go back: |;
		$input = <STDIN>;
		chomp $input;
		return $str if !$input;			# accept default
		
	}}
}

sub saveDependancyCSV {	
	my $csv;

	my $f1;
	my $f2;
	my $f3;
		
	my $nmisBase = "/usr/local/nmis8";

	$csv .= "Module\tFile\tVersion\n";

	foreach my $k (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file} } keys %nmisModules) {
		$f1 = $k;
		( $f2 , $f3) = split /\s+/, $nmisModules{$k}{file}, 2;
		$f3 = ' ' if !$f3;
		$csv .= "$f1\t$f2\t$f3\n";
	}

	my $file = "NMIS-Dependancies.csv";
	open(CSV,">$file") or die "Problem with $file: $!\n";
	print CSV $csv;
	close(CSV);
	print "NMIS Depenancy Graph saved to $file\n";
	
}

sub saveDependancyGml {	
	my $gml;
	my $x;
	my $y;
	my $nodeid;
	my %nodeIdx;
	
	my $nmisBase = "/usr/local/nmis8";
	
	my %usedBy;
	foreach my $mod (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file}} keys %nmisModules) {
		foreach my $src (@{$nmisModules{$mod}{by}}) {
			# convert Package files to Package names.
			my $filename = $src;
			$filename =~ s/$nmisBase/\./g;
			my $name = $filename;

			if ( $src =~ /$nmisBase\/lib/ ) {
				#this is a module!
				$name =~ s/\.\/lib\///g;
				$name =~ s/\.pm//g;
				$name =~ s/\//::/g;
				print "DEBUG: $filename = $name \n" if $debug;
			}
			
			$usedBy{$filename}{name} = $name;
			$usedBy{$filename}{file} = $filename;
			if (not grep {$_ eq $mod} @{$usedBy{$filename}{modules}}) {
				push(@{$usedBy{$filename}{modules}},$mod);
			}
		}
	}
	
	# Transform the current HASH;
	
	$gml .= "Creator \"NMIS Opmantek\"\n";
	$gml .= "directed 1\n";
	$gml .= "graph [\n";

	foreach my $file (sort {$usedBy{$a}{name} cmp $usedBy{$b}{name}} keys %usedBy) {
		++$nodeid;
		my $name = $usedBy{$file}{name};
		if ( $nodeIdx{$name} eq "" ) {
			++$y;
			++$x;
			$nodeIdx{$name} = $nodeid;
			my $label = $name;
			my $fill = getFill("nmis");
			if ( $usedBy{$file}{file} ne $usedBy{$file}{name} ) {
				$label = "$name\n$file";
				$fill = getFill("nmis-lib");
			}
			$gml .= getNodeGml($nodeid,$label,$fill,$x,$y);
		}
	}


	foreach my $file (sort {$usedBy{$a}{name} cmp $usedBy{$b}{name}} keys %usedBy) {
		++$nodeid;
		my $name = $usedBy{$file}{name};
		
		foreach my $mod (@{$usedBy{$file}{modules}}) {
			++$nodeid;
			if ( $nodeIdx{$mod} eq "" ) {
				++$y;
				++$x;
				$nodeIdx{$mod} = $nodeid;
				my $fill = getFill("cpan");
				$gml .= getNodeGml($nodeid,$mod,$fill,$x,$y);
			}
			$gml .= getEdgeGml($nodeIdx{$name},$nodeIdx{$mod},"");
			print "DEBUG: $name -> $mod\n" if $debug;
		}
	}


	$gml .= "]\n";

	my $file = "NMIS-Dependancies.gml";
	open(GML,">$file") or die "Problem with $file: $!\n";
	print GML $gml;
	close(GML);
	print "NMIS Depenancy Graph saved to $file\n";
	
}

sub getFill {
	my $type = shift;
	
	my $fill = "#0099FF";
	
	$fill = "#00FF99" if $type eq "nmis";
	$fill = "#9900FF" if $type eq "nmis-lib";
	
	return $fill;	
}

sub getNodeGml {
	my $nodeid = shift;
	my $label = shift;
	my $fill = shift;
	my $x = shift;
	my $y = shift;
	return qq|
	node [
		id $nodeid
		label "$label"
		graphics [
			x $x.000000
			y $y.0000000
			w 95.00000000
			h 56.00000000
			fill	"$fill"
			outline	"#000000"
		]
		LabelGraphics [
			alignment	"center"
			autoSizePolicy	"node_width"
			anchor	"c"
		]
	]
|;

}

sub getEdgeGml {
	my $source = shift;
	my $target = shift;
	my $label = shift;
	
	my $width = 3;
	my $color = "#000000";
	my $linestyle = "arrow";
	
	return qq|
	edge [
		source $source
		target $target
		label	"$label"
		graphics
		[
			width	$width
			style	"$linestyle"
			fill "$color"
			arrow "last"
		]
	]
|;

}