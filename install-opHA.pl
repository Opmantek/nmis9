#!/usr/bin/perl
#
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED 
# BY OPMANTEK.  
# 
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# 
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER 
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE 
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE 
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3) 
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT 
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR 
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS 
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND 
# OPMANTEK LTD. 
# 
# Opmantek is a passionate, committed open source software company - we really 
# are.  This particular piece of code was taken from a commercial module and 
# thus we can't legally supply under GPL. It is supplied in good faith as 
# source code so you can get more out of NMIS.  According to the license 
# agreement you can not modify or distribute this code, but please let us know 
# if you want to and we will certainly help -  in most cases just by emailing 
# you a different agreement that better suits what you want to do but covers 
# Opmantek legally too. 
# 
# contact opmantek by emailing code@opmantek.com
# 
# All licenses for all software obtained from Opmantek (GPL and commercial) 
# are viewable at http://opmantek.com/licensing
#   
#*****************************************************************************

# TODO:
# * Unattended install e.g. install.pl site=/usr/local/nmis8 fping=/usr/local/sbin/fping cpan=true

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/lib";
use func;

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

## Setting Default Install Options.
my $defaultSite = "/usr/local/nmis8";
my $installLog = undef;

if ( $ARGV[0] =~ /\-\?|\-h|--help/ ) {
	printHelp();
	exit 0;
}

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $site = $arg{site} ? $arg{site} : $defaultSite;

my $debug = 0;
$debug = 1 if $arg{debug};

print qx|clear|;

###************************************************************************###
printBanner("opHA Installation Version 1");

###************************************************************************###
printBanner("Getting installation source location...");

my $src = cwd() . $ARGV[0];
$src = input_str("Full path to distribution folder:", $src);

$installLog = "$src/install.log";
logInstall("Source is $src");


###************************************************************************###
printBanner("Checking Perl version...");

my $ver = ref($^V) eq 'version' ? $^V->normal : ( $^V ? join('.', unpack 'C*', $^V) : $] );
my $perl_ver_check = '';
if ($] < 5.010001) {  # our minimal requirement for support
	print qq|The version of Perl installed on your server is lower than the minimum supported version 5.10.1. Please upgrade to at least Perl 5.10.1|;
}
else {
	my $message = "The version of Perl installed on your server $ver is OK";
	print qq|\n$message\n\n|;
	logInstall($message);
}

###************************************************************************###
printBanner("Configuring installation path...");
my $site = input_str("Folder to install opService in", $defaultSite);


###************************************************************************###
if ( -d $site ) {
	printBanner("Make a backup of an existing install...");

	exit unless input_yn("OK to make a backup of your current Opmantek?:");
	my $backupFile = getBackupFileName();
	execPrint("cd $site;tar cvf ~/$backupFile ./bin ./cgi-bin ./conf ./htdocs ./install ./lib");
	print "Backup of Opmantek install in $backupFile\n";
}


###************************************************************************###
printBanner("Copying opService system files...");

exit unless input_yn("OK to copy opService distribution files from $src to $site:");
print "Copying source files from $src to $site...\n";

if ( not -d $site ) {
	execPrint("mkdir $site");
}
execPrint("cp -r $src/* $site");


###************************************************************************###
printBanner("Update the config files with new options...");

exit unless input_yn("OK to update the config files?:");
# merge changes for new opService Config options. 
execPrint("$site/bin/opupdateconfig.pl $site/install/opCommon.nmis $site/conf/opCommon.nmis");


###************************************************************************###
printBanner("Fixing file permissions...");
execPrint("$site/bin/opfixperms.pl");


###************************************************************************###
printBanner("opService Should be Ready to Roll!");


exit 0;

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

sub getBackupFileName {
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
	return "opmantek-backup-$year-$mon-$mday-$hour$min.tar";
}

sub printBanner {
	my $string = shift;

	print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
$string
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

	logInstall("\n\n###+++\n$string\n###+++\n");
}

sub execPrint {
	my $exec = shift;	
	my $out = `$exec 2>&1`;
	print $out;
	logInstall("\n\n###+++\nEXEC: $exec\n");
	logInstall($out);
	logInstall("###+++\n\n");
}

sub logInstall {
	my $string = shift;
	if ( $installLog ) {
		open(OUT,">>$installLog") or die "ERROR: Problem with file $installLog: $!\n";
		print OUT "$string\n";
		close(OUT);
	}
}

sub printHelp {
	print qq/
opService Install Script version 1

Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;

usage: $0 [site=$defaultSite]

Options:  
  site	Target site for installation, default is $defaultSite 

eg: $0 site=$defaultSite

/;	
}
