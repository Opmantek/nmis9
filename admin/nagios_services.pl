#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
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
use strict;
our $VERSION = "1.0.0";


use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Copy;
use File::Basename;
use Getopt::Long;
use File::Spec;
use Data::Dumper;
use Term::ReadKey;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Outage;
use NMISNG::Auth;

use Compat::NMIS;
use NMISNG::CSV;

my $PROGNAME = basename($0);
my $PROGPATH = File::Spec->rel2abs(dirname(${0}));
my $debugsw = 0;
my $helpsw = 0;
my $simulatesw = 0;
my $verbosesw = 0;
my $versionsw = 0;

 die unless (GetOptions('debug:i'    => \$debugsw,
                        'help'       => \$helpsw,
                        'simulate'   => \$simulatesw,
                        'verbose'    => \$verbosesw,
                        'version'    => \$versionsw));

# For the Version mode, just print it and exit.
if (${versionsw}) {
	print "$PROGNAME version=$NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

my $usage       = "Usage: $PROGNAME [option=value...] <act=command>

 act=noderefresh
 
\n";

my $Q = NMISNG::Util::get_args_multi(@ARGV);

if (!@ARGV)
{
    help();
    exit(0);
}

my $debug    = $debugsw;
my $simulate = $simulatesw;
my $verbose = $verbosesw;
$debug      = $Q->{debug}                                              if (exists($Q->{debug}));   # Backwards compatibility
$simulate   = NMISNG::Util::getbool_cli("simulate", $Q->{simulate}, 0) if (exists($Q->{simulate}));   # Backwards compatibility
$verbose    = NMISNG::Util::getbool_cli("verbose", $Q->{verbose}, 0) if (exists($Q->{verbose})); # Backwards compatibility

my $customconfdir = $Q->{dir}? $Q->{dir}."/conf" : undef;
my $C      = NMISNG::Util::loadConfTable(dir => $customconfdir, debug => $debug);
die "no config available!\n" if (ref($C) ne "HASH" or !keys %$C);


# log to stderr if debug is given
my $logfile = $C->{'<nmis_logs>'} . "/nagios_services.log";
#print("Logging changes to file '$logfile'.\n");
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																 debug => $debug ) // $C->{log_level},
																 path  => ($debug > 0)? undef : $logfile);

# this opens a database connection
my $nmisng = NMISNG->new(
	config => $C,
    log    => $logger,
);

# for audit logging
my ($thislogin) = getpwuid($<); # only first field is of interest

my $node     = $Q->{node};
my $uuid     = $Q->{uuid};
my $csv      = $Q->{csv};
if ((!defined($node) || $node eq "")&& (!defined($uuid) || $uuid eq ""))
{
	print "\033[1mNode was not supplied\033[0m\n\n";
	help(3);
	exit(2);
}
if (!defined($csv) || $csv eq "")
{
	print "\033[1mCSV filename was not supplied\033[0m\n\n";
	help(3);
	exit(2);
}
if (!-f $csv)
{
	print "\033[1mCSV file does not exist\033[0m\n\n";
	help(3);
	exit(2);
}
my $servFile = "$C->{'<nmis_conf>'}/Services.nmis";
if (!-f "$servFile")
{
	my $defaultServFile = "$C->{'<nmis_conf_default>'}/Services.nmis";
	if (!-f "$defaultServFile")
	{
		print "\033[1mDefault Services file ($defaultServFile) does not exist\033[0m\n\n";
		help(3);
		exit(2);
	}
	copy("$defaultServFile", "$servFile");
	if (!-f "$servFile")
	{
		print "\033[1mServices file ($servFile) does not exist, and unable to create it.\033[0m\n\n";
		help(3);
		exit(2);
	}
}
my $services = NMISNG::Util::loadTable(dir=>'conf',name=>'Services');
if (ref($services) ne "HASH")
{
	print "\033[1mServices ERROR: $services\033[0m\n";
	exit(2);
}
print("Before:" . Dumper(\$services)) if ($debug >= 5);
my($csverror, %csvHash) = NMISNG::CSV::loadCSV($csv, 'name');
print(Dumper(\%csvHash)) if ($debug >= 5);
if (!%csvHash)
{
	print "\033[1mCSV ERROR: $csverror\033[0m\n";
	exit(2);
}
my $svcsAdded = 0;
foreach my $name (keys %csvHash)
{
	next if($name eq '');
	if (!exists($services->{$name}))
	{
		print("'$name' does not exist as a service.\n");
		$services->{$name} = {
						'Args' => "$csvHash{$name}->{'url'} $csvHash{$name}->{'http_code'}",
						'Collect_Output' => 'true',
						'Description' => '',
						'Max_Runtime' => '10',
						'Name' => "$name",
						'Poll_Interval' => '5m',
						'Port' => '',
						'Program' => "$csvHash{$name}->{'plugin_path'}",
						'Service_Name' => '',
						'Service_Parameters' => '',
						'Service_Type' => 'nagios-plugin'
					};
		if ($simulate)
		{
			print("'$name' would have been added as a new service.\n");
		}
		else
		{
			$nmisng->log->info("Adding new Service '$name'");
			$svcsAdded = 1;
		}
	}
}
print("After: " . Dumper(\$services)) if ($debug >= 5);
if ($svcsAdded)
{
	NMISNG::Util::writeTable(dir=>'conf',name=>'Services', data=>$services);
}
my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
if (!$nodeobj)
{
	my $nodeprint = $node//$uuid;
	print "\033[1mNODE ERROR: Node '$nodeprint' does not exist.\033[0m\n";
	exit(2);
}
$node ||= $nodeobj->name;           # if  looked up via uuid
my $curconfig = $nodeobj->configuration;
print("Configuration: " . Dumper(\$curconfig)) if ($debug >= 5);
my $nodeServices = $curconfig->{'services'};
print("Services: " . Dumper(\$nodeServices)) if ($debug >= 5);
$svcsAdded = 0;
my @serviceNames = ();
foreach my $name (keys %csvHash)
{
	next if($name eq '');
	my $found = 0;
	foreach my $nodeService (@$nodeServices)
	{
		if ($name eq $nodeService)
		{
			$found = 1;
		}
	}
	if (!$found)
	{
		print("'$name' service is not enabled on this device.\n");
		if ($simulate)
		{
			print("'$name' would have been added as a service to node '$node'.\n");
		}
		else
		{
			$nmisng->log->info("Adding Service '$name' to node '$node'");
			push(@$nodeServices, $name);
			push(@serviceNames, $name);
			$svcsAdded = 1;
		}
	}
}
print("Services: " . Dumper(\$nodeServices)) if ($debug >= 5);
if ($svcsAdded)
{
	$curconfig->{'services'} = $nodeServices;
	$nodeobj->configuration($curconfig);
	my $meta = {
				what => "Add Nagios Services",
				who => $thislogin,
				where => $node,
				how => $PROGNAME,
				details => "Add Services: '" . join("', '", @serviceNames) . "'"
	};
	my ($op,$error) = $nodeobj->save(meta => $meta);
	if($op <= 0)                                    # zero is no saving needed
	{
		$logger->error("Error saving node ".$node.": $error");
		warn("Error saving node ".$node.": $error\n");
		exit 255;
	}
	else
	{
		$logger->info( $node." saved to database, op: $op" );
	}
}

exit 0;


###########################################################################
#  Help Function
###########################################################################
sub help
{
   my(${currRow}) = @_;
   my @{lines};
   my ${workLine};
   my ${line};
   my ${key};
   my ${cols};
   my ${rows};
   my ${pixW};
   my ${pixH};
   my ${i};
   my $IN;
   my $OUT;

   if ((-t STDERR) && (-t STDOUT)) {
      if (${currRow} == "")
      {
         ${currRow} = 0;
      }
      if ($^O =~ /Win32/i)
      {
         sysopen($IN,'CONIN$',O_RDWR);
         sysopen($OUT,'CONOUT$',O_RDWR);
      } else
      {
         open($IN,"</dev/tty");
         open($OUT,">/dev/tty");
      }
      ($cols, $rows, $pixW, $pixH) = Term::ReadKey::GetTerminalSize $OUT;
   }
   STDOUT->autoflush(1);
   STDERR->autoflush(1);

   push(@lines, "\n\033[1mNAME\033[0m\n");
   push(@lines, "       $PROGNAME -  Nagios Service Manager Command Line Interface.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] node=<namename>|uuid=<uuid> csv=<filename>\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program provides a command line interface for the Nagios\n");
   push(@lines, "       service integration. The program will first verify the the service is\n");
   push(@lines, "       defined, and add it if it is not.  It will then add, or verify\n");
   push(@lines, "       that the service is configured on the specified node.\n");
   push(@lines, "       actions are logged in the file 'nagios_services.log'.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --debug[1-9]             - global option to print detailed messages\n");
   push(@lines, " --help                   - display command line usage\n");
   push(@lines, " --simulate               - print what actions would be taken, but don't do it\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     node=<namename>|uuid=<uuid> Either the node name, or UUID of the node to update.\n");
   push(@lines, "     csv=<filename> The name of a CSV file contining the services to add.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mEXIT STATUS\033[0m\n");
   push(@lines, "     The following exit values are returned:\n");
   push(@lines, "     0 Success\n");
   push(@lines, "     2 Missing or invalid arguments, files, or undefined node.\n");
   push(@lines, "     215 Failure. Update could not be saved\n\n");
   push(@lines, "\033[1mFILE\033[0m\n");
   push(@lines, "       The $PROGNAME program requires a comma separated value (csv) file of\n");
   push(@lines, "       a specific format.  The file must include four fields:\n");
   push(@lines, "       o name        - The name of the service to be added.\n");
   push(@lines, "       o url         - The URL of the service to test.\n");
   push(@lines, "       o http_code   - The expected return code for a successful connection.\n");
   push(@lines, "       o plugin_path - The full path to the program plugin to perform the test.\n");
   push(@lines, "\033[1mEXAMPLE\033[0m\n");
   push(@lines, "\"name\",\"url\",\"http_code\",\"plugin_path\"\n");
   push(@lines, "\"vcloud.macquarieview.com\",\"https://vcloud.macquarieview.com/api/versions\",\"200\",\"/usr/lib64/nagios/plugins/check_http_code\"\n");
   push(@lines, "\"vcloudph1.macquarieview.com\",\"https://vcloudph1.macquarieview.com/api/versions\",\"200\",\"/usr/lib64/nagios/plugins/check_http_code\"\n");
   push(@lines, "\n");
   push(@lines, "\n");
   print(STDERR "                       $PROGNAME - ${VERSION}\n");
   print(STDERR "\n");
   ${currRow} += 2;
   foreach (@lines)
   {
      if ((-t STDERR) && (-t STDOUT)) {
         ${i} = tr/\n//;  # Count the newlines in this string
         ${currRow} += ${i};
         if (${currRow} >= ${rows})
         {
            print(STDERR "Press any key to continue.");
            ReadMode 4, $IN;
            ${key} = ReadKey 0, $IN;
            ReadMode 0, $IN;
            print(STDERR "\r                          \r");
            if (${key} =~ /q/i)
            {
               print(STDERR "Exiting per user request. \n");
               return;
            }
            if ((${key} =~ /\r/) || (${key} =~ /\n/))
            {
               ${currRow}--;
            } else
            {
               ${currRow} = 1;
            }
         }
      }
      print(STDERR "$_");
   }
}
