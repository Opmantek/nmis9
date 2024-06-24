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
#
# this is the first variant of a scheduling tool for opReports
# it runs out of cron, fairly often, and checks the conf/schedule directory
# for things that need doing.
use strict;
our $VERSION = "5.413.0";

my $application_version = "4.2";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

our $VERSION = "1.0.0";

our $VERSION = "1.0.0";

use FindBin;
use lib "/usr/local/nmis9/lib";

use strict;
use Data::Dumper;
use File::Path qw(make_path remove_tree);
use Net::SNMP qw(oid_lex_sort);
use Net::SFTP::Foreign;

use NMISNG;														# lnt
use NMISNG::Util;
use NMISNG::Sys;
use Compat::NMIS;



my $DOFTP;

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

my $filename = $arg->{filename};
my $outputdir = $arg->{outputdir};
my $completed_time = $arg->{completed_time};
my $dat_filename;

if ( $filename eq "" ) {
	usage();
	exit 1;
}

sub usage {
	print qq/$0 will export files or FTP them.
	
	usage: $0 filename=filename.pl outputdir=path_of_outputdir_of_report completed_time=time_at_which report_was_completed \n/;

}

# load configuration table
my $customconfdir = "/usr/local/nmis9/conf";
my $C = NMISNG::Util::loadConfTable(dir => $customconfdir, debug => $arg->{debug});
my $debug = $arg->{debug};

#print "$C\n";
#print Dumper (%$C);
my $opReportsFtpLog = $C->{'<nmis_logs>'} ."/ftpexport.log";

my $error = NMISNG::Util::setFileProtDiag(file => $opReportsFtpLog) if (-f $opReportsFtpLog);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
														     debug => $arg->{debug} ) // $C->{log_level},
															 path  => (defined $arg->{debug})? undef : $opReportsFtpLog);



my $nmisng;
$nmisng = defined($nmisng) ? $nmisng : Compat::NMIS::new_nmisng();
my $exportConfig;

if (NMISNG::Util::existFile(dir=>'conf', name=>'FtpExport'))
{
	$exportConfig = NMISNG::Util::loadTable(dir=>'conf', name=>'FtpExport');
}
else
{
	$nmisng->log->error("ERROR Configuration file for FtpExport missing.");
	print "ERROR Configuration file for FtpExport missing. \n" if ($debug);
	exit 1;
}

#print Dumper $exportConfig;

my ($errmsg, $ftp_user, $ftp_password, $ftp_server, $ftp_directory, $ftp_log_directory);

$ftp_user           = $exportConfig->{ftp_user};
$ftp_password       = $exportConfig->{ftp_password};
$ftp_server         = $exportConfig->{ftp_server};
$ftp_directory      = $exportConfig->{ftp_directory};
$ftp_log_directory  = $exportConfig->{ftp_log_directory};

if (!defined($ftp_user) || $ftp_user eq '' || !defined($ftp_password) || $ftp_password eq '') {
	$errmsg = "ERROR FTP Username or Password not supplied";
}
if (!defined($ftp_server) || $ftp_server eq '') {
	$errmsg = "ERROR FTP server not supplied";
}
if (!defined($ftp_directory) || $ftp_directory eq '') {
	$errmsg = "ERROR FTP directory not supplied";
}
if (!defined($ftp_log_directory) || $ftp_log_directory eq '') {
	$errmsg = "ERROR FTP log directory not supplied";
}

if ($errmsg)
{
	$logger->error($errmsg);
	exit 1;
}

# Log the output of the SFTP to assist in identifying files that could not be uploaded

# when sending ftp files WRITE log, we want to send log to ftp server
# when sending ftp LOG DONT WRITE log, we don't want to send log to ftp server
my $opReportsFtpLogFlag = 0;


open(F, ">$opReportsFtpLog") or $logger->error("Cannot save list data to $opReportsFtpLog: $!");
			
if (-e $filename) {
    
	print "Starting script for $outputdir/$filename completed at $completed_time\n";
	$logger->info("Starting script for $outputdir/$filename completed at $completed_time\n");
   
    #Get the number of records in the file.
    my $no_of_records = 0;
    my $record_string = "00000";
	my $file_contents;
   
    open (FH, $filename) or $logger->error("Can't open '$filename': $!");
    while (my $line = <FH>){
		$file_contents .= $line;
		$no_of_records++;
	}
    close FH;
    
    my $record_string_length = length($no_of_records);
    my $record_string_index = 5 - $record_string_length;
    substr($record_string, $record_string_index) = $no_of_records; 
    my $sequence_number = int(rand(999999));

	$dat_filename = $outputdir."/"."NMIS_".$record_string."_".$completed_time."_".$sequence_number.".dat";
	open (FH, ">$dat_filename") or $logger->error("Can't open '$dat_filename': $!");
	print FH $file_contents;
	close FH;

	if (-e $dat_filename) {
		print "Found $dat_filename preparing for FTP\n";
		#$logger->info("Found $dat_filename preparing for FTP\n");
		$DOFTP = 1;
	}
	else {
		print "Not found $dat_filename\n";
		#$logger->info("Found $dat_filename preparing for FTP\n");
	}
}
else { 
    $DOFTP = 0;
	print "Not found $filename\n Aborting FTP...";
	$logger->info("Not found $filename\n Aborting FTP...");
}


if ( $DOFTP ) {
		$opReportsFtpLogFlag = 1; #sending file we need logging of steps
		ftpExportFile(file => $dat_filename,
					  server => $ftp_server,
					  user => $ftp_user,
					  password => $ftp_password,
					  #more => [qw(-o PreferredAuthentications=publickey)],
					  directory => $ftp_directory,
					  nmisng => $logger);
}

sub ftpExportFile {
	my (%args) = @_;

	my $file = $args{file};
	my $server = $args{server};
	my $user = $args{user};
	my $password = $args{password};
	my $directory = $args{directory};
	my $nmisng = $args{nmisng};
		
	my $sftp = Net::SFTP::Foreign->new(
		$server, 
		user => $user,
		password => $password
	);
	
	print "Unable to establish SFTP connection: " . $sftp->error . "\n" if $sftp->error; 	#STDERR
	$nmisng->error("Unable to establish SFTP connection: " . $sftp->error) if $sftp->error;	#Error Log
	if ($opReportsFtpLogFlag == 1) {
		print F "Unable to establish SFTP connection: " . $sftp->error . "\n" if $sftp->error; #FTP Log
	}
		
	
	if ( $sftp ) {
		if (!$sftp->setcwd($directory)) {
			$nmisng->error("unable to change cwd: " . $sftp->error);
			print "unable to change cwd: " . $sftp->error . "\n";
			if ($opReportsFtpLogFlag == 1) {
				print F "unable to change cwd: " . $sftp->error . "\n";
			}
			exit 1;
		}
		if (!$sftp->put($file)) {
			$nmisng->error("put failed: " . $sftp->error);
			print "put failed: " . $sftp->error . "\n";
			if ($opReportsFtpLogFlag == 1) {
				print F "put failed: " . $sftp->error . "\n";
			}
			exit 1;
		}

		#$nmisng->info("Export file $file put to $server:$directory");
		print "Export file $file put to $server:$directory \n";
		if ($opReportsFtpLogFlag == 1) {
			print F "Export file $file put to $server:$directory \n";
		}
		
	}
	
}
# Prepare to send the log
# IF log present send the log
if (-e $opReportsFtpLog) {

	$opReportsFtpLogFlag = 0; #sending log we don't need logging of steps

	ftpExportFile(file => $opReportsFtpLog,
					  server => $ftp_server,
					  user => $ftp_user,
					  password => $ftp_password,
					  #more => [qw(-o PreferredAuthentications=publickey)],
					  directory => $ftp_log_directory, # Make sure you give correct log directory
					  nmisng => $logger);
}
close(F);

# Delete dat file once transfer is done
unlink ($dat_filename);
