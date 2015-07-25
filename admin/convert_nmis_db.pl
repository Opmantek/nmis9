#!/usr/bin/perl
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
# *****************************************************************************

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;
use NMIS;

my $debug = 0;

# load configuration table
my $C = loadConfTable(conf=>undef,debug=>$debug);

my $pass = 0;
my $dirpass = 1;
my $dirlevel = 0;
my $maxrecurse = 200;
my $maxlevel = 10;

my $bad_file = qr/nmis-ldap-debug/; # incorrectly located file
my $bad_dir;
my $file_count;
my $extension = "nmis";

my $indent = 0;
my @path;
my $rrdlen = 19;

print "This script will convert the NMIS database to use JSON.\n";
print "Using configured var directory $C->{'<nmis_var>'}\n";

# Process
# 1. Stop NMIS Polling
# 2. Convert NMIS files to JSON files
# 3. Change config to use JSON
# 4. Start NMIS polling.

&updateNmisConfigBefore();
&processDir(dir => $C->{'<nmis_var>'});
&updateNmisConfigAfter();

print "Done.  Processed $file_count NMIS files.\n";

sub indent {
	for (1..$indent) {
		print " ";
	}
}

sub processDir {
	my %args = @_;
	# Starting point
	my $dir = $args{dir};
	my @dirlist;
	my $index;
	++$dirlevel;
	my @filename;
	my $key;

	if ( -d $dir ) {
		print "\nProcessing Directory $dir pass=$dirpass level=$dirlevel\n";
	}
	else {
		print "\n$dir is not a directory\n";
		exit -1;
	}

	#sleep 1;
	if ( $dirpass >= 1 and $dirpass < $maxrecurse and $dirlevel <= $maxlevel ) {
		++$dirpass;
		opendir (DIR, "$dir");
		@dirlist = readdir DIR;
		closedir DIR;
		my $pretty = 1;
		if( $dir eq $C->{'<nmis_var>'} ) { $pretty = 0; }
		if ($debug > 1) { print "\tFound $#dirlist entries\n"; }

		for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$dirlist[$index]");
			if ( -f "$dir/$dirlist[$index]"
				and $extension =~ /$filename[$#filename]/i
				and $dirlist[$index] !~ $bad_file
			) {
				if ($debug>1) { print "\t\t$index file $dir/$dirlist[$index]\n"; }
				&processNmisFile(file => "$dir/$dirlist[$index]", pretty => $pretty)
			}
			elsif ( -d "$dir/$dirlist[$index]"
				and $dirlist[$index] !~ /^\.|CVS/
				and $bad_dir !~ /$dirlist[$index]/i
			) {
				#if (!$debug) { print "."; }
				&processDir(dir => "$dir/$dirlist[$index]");
				--$dirlevel;
			}
		}
	}
} # processDir

sub processNmisFile {
	my %args = @_;
	my $file = $args{file};
	my $pretty = $args{pretty};
	$indent = 2;
	++$file_count;

	my ($jsonfile,undef) = getFileName(file => $file, json => 1);
	
	if ( $jsonfile =~ /json/ ) {
		if ( not -f $jsonfile ) {
			print &indent . "Converting $file to $jsonfile\n";
			my $data = readFiletoHash(file=>$file);
			writeHashtoFile(data=>$data,file=>$file, json => 1, pretty => $pretty);	
		}
		else {
			print &indent . "SKIPPING: JSON file $jsonfile already exists for $file, remove json file to recreate\n";
		}
	}
}

sub updateNmisConfigBefore {
	my $configFile = "$C->{'<nmis_conf>'}/Config.nmis";
	my $conf;
	
	if ( -f $configFile ) {
		$conf = readFiletoHash(file=>$configFile);
	}
	else {
		print "ERROR: something wrong with config file 1: $configFile\n";
		exit 1;
	}
	$conf->{'system'}{'global_collect'} = "false";

	writeHashtoFile(file=>$configFile,data=>$conf);
}

sub updateNmisConfigAfter {
	my $configFile = "$C->{'<nmis_conf>'}/Config.nmis";
	my $conf;
		
	if ( -f $configFile ) {
		$conf = readFiletoHash(file=>$configFile);
	}
	else {
		print "ERROR: something wrong with config file 1: $configFile\n";
		exit 1;
	}
	
	# reconfigure nmis to use json 
	$conf->{'system'}{'use_json'} = "true";
	# but set json_pretty only if not present already
	if ( not exists $conf->{'system'}{'use_json_pretty'} ) 
	{ 
		$conf->{'system'}{'use_json_pretty'} = "true";
	}
	$conf->{'system'}{'global_collect'} = "true";

	writeHashtoFile(file=>$configFile,data=>$conf);
}
