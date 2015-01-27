#!/usr/bin/perl
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

# TODO:
# * support for completely unattended install (silencing confirmations)
# e.g. install.pl site=/usr/local/nmis8 fping=/usr/local/sbin/fping cpan=true

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/lib";

use strict;
use DirHandle;
use Data::Dumper;
#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use File::Find;
use File::Basename;
use Cwd;
use POSIX qw(:sys_wait_h);
use version 0.77;


## Setting Default Install Options.
my $defaultSite = "/usr/local/nmis8";
my $defaultFping = "/usr/local/sbin/fping";

my $defaultCpan = 1;
my $installLog = undef;
my $nmisModules;			# local modules used in our scripts

# there are some slight but annoying differences
my $osflavour = -f "/etc/redhat-release" ? "redhat" : -f "/etc/debian_version"? "debian" : undef;

if ( $ARGV[0] =~ /\-\?|\-h|--help/ ) {
	printHelp();
	exit 0;
}

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $site = $arg{site} ? $arg{site} : $defaultSite;
my $fping = $arg{fping} ? $arg{fping} : $defaultFping;
my $cpan = 0 ? $arg{cpan} =~ /0|false|no/ : $defaultCpan;
my $listdeps = $arg{listdeps} =~ /1|true|yes/i;

my $debug = 0;
$debug = 1 if $arg{debug};

my %options;										# for futher unattended mode

system("clear");

###************************************************************************###
printBanner("NMIS Installation Script");

###************************************************************************###
printBanner("Getting installation source location...");

# try the current dir first, otherwise check the dirname of 
# this command's invocation
my $src = cwd();
$src = Cwd::abs_path(dirname($0)) if (!-f "$src/LICENSE");
$src = input_str("Full path to distribution folder:", $src);

$installLog = "$src/install.log";
logInstall("Installation started at ".scalar localtime);
logInstall("Installation source is $src");


###************************************************************************###
printBanner("Checking Perl version...");

if ($^V < version->parse("5.10.1")) 
{  
	echolog("The version of Perl installed on your server is lower than the minimum supported version 5.10.1. Please upgrade to at least Perl 5.10.1");
	exit 1;
}
else {
	echolog("The version of Perl installed on your server is $^V and OK");
}


###************************************************************************###
if ( $cpan || $listdeps) {
	if (!checkCpan())
	{
		print "Some critically required Perl modules were missing. 
NMIS will not work properly until these are installed! 

We recommend that you stop the installer now, resolve the dependencies, 
and then restart the installer.\n\n";
		if (input_yn("Stop the installer?"))
		{
			die "\nAborting the installation. Please install the missing modules, then restart the installer. installer.\n";
		}
		else
		{
			echolog("\n\nContinuing the installation as requested. NMIS won't work correctly until you install the missing dependencies!

We recommend that you check the NMIS Installation guide at 
https://community.opmantek.com/display/NMIS/NMIS+8+Installation+Guide
for further info.\n\n");

			print "Please hit enter to continue:\n";
			my $x = <STDIN>;

		}
	}
	 
	if ($listdeps)
	{
			echolog("NOT proceeding with installation, as requested.\n");
			exit 0;
	}
}

# check dependencies
printBanner("Checking Dependencies");
# rrdtool/rrds new enough?
{
	my $rrdisok=0;

	use NMIS::uselib;
	use lib "$NMIS::uselib::rrdtool_lib";

	eval { require RRDs; };
	if (!$@)
	{
		# the rrds version is given in a weird form, eg. 1.4007 meaning 1.4.7.
		# the  version module doesn't quite understand this flavour, expects 1.004007 to mean 1.4.7
		my $foundversion = version->parse("$RRDs::VERSION"); 
		my $minversion = version->parse("1.4004");
		if ($foundversion >= $minversion)
		{
			echolog("rrdtool/RRDs version $foundversion is sufficient for NMIS.");
			$rrdisok=1;
		}
		else 
		{
			echolog("rrdtool/RRDs version $foundversion is NOT sufficient for NMIS, need at least $minversion");
		}
	}
	else
	{
		echolog("No RRDs module found!");
	}
	
	if (!$rrdisok)
	{
		print "\nNMIS will not work properly without a sufficiently modern rrdtool/RRDs.

We HIGHLY recommend that you stop the installer now, install rrdtool
and the RRDs perl module, and then restart the installer.

You should check the NMIS Installation guide at 
https://community.opmantek.com/display/NMIS/NMIS+8+Installation+Guide
for further info.\n\n";

		if (input_yn("Stop the installer?"))
		{
			die "\nAborting the installation. Please install rrdtool and the RRDs perl module, then restart the installer.\n";
		}
		else
		{
			echolog("\n\nContinuing the installation as requested. NMIS won't work correctly until you install rrdtool and RRDs!\n\n");
			print "Please hit enter to continue:\n";
			my $x = <STDIN>;
		}
	}
}

###************************************************************************###
printBanner("Configuring installation path...");
$site = input_str("Folder to install NMIS in", $defaultSite, 1);
logInstall("Installation destination is $site");


###************************************************************************###
if ( -d $site ) {
	printBanner("Make a backup of an existing install...");

	if (input_yn("OK to make a backup of your current NMIS?"))
	{
		my $backupFile = getBackupFileName();
		execPrint("cd $site; tar czvf $backupFile ./admin ./bin ./cgi-bin ./conf ./install ./lib ./menu ./mibs ./models");
		echolog("Backup of NMIS install was created in $site/$backupFile\n");
	}
	else
	{
		echolog("Continuing without backup as instructed.\n");
	}
}

###************************************************************************###
printBanner("Copying NMIS system files...");

if (!input_yn("Ready to start installation/upgrade to $site?"))
{
	echolog("Exiting installation as directed.\n");
	exit  0;
}

echolog("Copying source files from $src to $site...\n");

# lock nmis first
open(F,">$site/conf/NMIS_IS_LOCKED");
print F "$0 is operating, started at ".localtime."\n";
close F;

my $isnewinstall;
if ( not -d $site ) 
{
	$isnewinstall=1;
	mkdir($site,0755) or die "cannot mkdir $site: $!\n";
}
# fixme: this fails benignly but noisyly if there are 
# (convenience) symlinks in the nmis dir, e.g. var or database
execPrint("cp -r $src/* $site");

if ($isnewinstall)
{
		printBanner("Installing default config files...");
		execPrint("cp -a $site/install/* $site/conf/");
		execPrint("cp -a $site/models-install/* $site/models/");

		if (!getpwnam("nmis"))
		{
			if (input_yn("OK to create NMIS user?"))
			{
				execPrint("adduser nmis");
			}
			else
			{
				echolog("Continuing without nmis user.\n");
			}
		}
}
else
{
		###************************************************************************###
		printBanner("Updating the config files with any new options...");

		if (input_yn("OK to update the config files?"))
		{
			# merge changes for new NMIS Config options. 
			execPrint("$site/admin/updateconfig.pl $site/install/Config.nmis $site/conf/Config.nmis");
			execPrint("$site/admin/updateconfig.pl $site/install/Access.nmis $site/conf/Access.nmis");
		
			# update default config options that have been changed:
			execPrint("$site/install/update_config_defaults.pl $site/conf/Config.nmis");

			# patch config changes that affect existing entries, which update_config_defaults doesn't handle
			execPrint("$site/admin/patch_config -b $site/conf/Config.nmis /system/non_stateful_events='Node Configuration Change, Node Reset, NMIS runtime exceeded'");

			# move config/cache files to new locations where necessary
			if (-f "$site/conf/WindowState.nmis")
			{
				printBanner("Moving old WindowState file to new location");
				execPrint("mv $site/conf/WindowState.nmis $site/var/nmis-windowstate.nmis");
			}

			printBanner("Performing Model Updates");
			# that plugin normally does its own confirmation prompting, which cannot work with execPrint
			execPrint("$site/install/install_stats_update.pl nike=true");

			printBanner("Updating RRD Variables");
			# Updating the mib2ip RRD Type
			execPrint("$site/admin/rrd_tune_mib2ip.pl run=true change=true");

			# Updating the TopChanges RRD Type
			execPrint("$site/admin/rrd_tune_topo.pl run=true change=true");

			# Updating the TopChanges RRD Type
			execPrint("$site/admin/rrd_tune_responsetime.pl run=true change=true");
		}
		else
		{
			echolog("Continuing without configuration updates as directed.
Please note that you will likely have to perform various configuration updates manually 
to ensure NMIS performs correctly.");
			print "\n\nPlease hit enter to continue: ";
			my $x = <STDIN>;
		}
}

###************************************************************************###
if ( -f $fping ) {
	printBanner("Restart the fping daemon...");
	execPrint("$site/bin/fpingd.pl restart=true");
}

if ( -x "$site/bin/opslad.pl" ) {
	printBanner("Restarting the opSLA Daemon...");
	execPrint("$site/bin/opslad.pl"); # starts a new one and kills any existing ones
}

	
###************************************************************************###
printBanner("Cache some fonts...");
execPrint("fc-cache -f -v");

# check if the common-databases differ, and if so offer to run migrate_rrd_locations.pl
if (!$isnewinstall)
{
	echolog("Checking Common-database files for updates");
	logInstall("running $site/admin/diffconfigs.pl -q $site/models/Common-database.nmis $site/models-install/Common-database.nmis 2>/dev/null | grep -qF /database/type");
	my $res = system("$site/admin/diffconfigs.pl -q $site/models/Common-database.nmis $site/models-install/Common-database.nmis 2>/dev/null | grep -qF /database/type");
	if ($res >> 8 == 0)						# relevant diffs were found
	{
		printBanner("RRD Database Migration");
		echolog("The installer has detected differences between your current Common-database 
and the shipped one. These changes can be merged using the rrd migration 
script that comes with NMIS.

If you choose Y below, the installer will use admin/migrate_rrd_locations.pl
to move all existing RRD files into the appropriate new locations and merge
the Common-database entries.  This is highly recommended! 

If you choose N, then NMIS will continue using the RRD locations specified
in your current Common-database configuration file.\n\n");
		
		if (input_yn("OK to run rrd migration script?"))
		{
			echolog("Performing RRD migration operation...\n");
			my $error = execPrint("$site/admin/migrate_rrd_locations.pl newlayout=$site/models-install/Common-database.nmis");

			if ($error)
			{
				echolog("Error: RRD migration failed! Please use the rollback script
listed above to revert to the original status!\nHit enter to continue:\n");
				my $x = <STDIN>;
			}
			else
			{
				echolog("RRD migration completed successfully.");
			}
		}
		else
		{
			echolog("Continuing without RRD migration as directed.
You can perform this step manually later, by 
running $site/admin/migrate_rrd_locations.pl. This script also has a 
simulation mode where it only shows what it WOULD do without making any
changes.

It is highly recommended that you perform the RRD migration.");
			print "Please hit enter to continue:\n";
			my $x = <STDIN>;
		}
	}
	else
	{
		echolog("No relevant differences between current and new Common-database.nmis,
no RRD migration required.");
	}
}

# all files are there; let nmis run
unlink("$site/conf/NMIS_IS_LOCKED");

###************************************************************************###
printBanner("Checking configuration and fixing file permissions (takes a few minutes) ...");
execPrint("$site/bin/nmis.pl type=config info=true");

if ($isnewinstall)
{
	printBanner("Integration with Apache");

	# determine apache version
	my $prog = $osflavour eq "redhat"? "httpd" : "apache2";
	my $versioninfo = `$prog -v 2>/dev/null`;
	$versioninfo =~ s/^.*Apache\/(\d+\.\d+\.\d+).*$/$1/s;
	my $istwofour = ($versioninfo =~ /^2\.4\./);

	if (!$versioninfo)
	{
		echolog("No Apache found!");
		print "
It seems that you don't have Apache 2.x installed, so the installer
can't configure Apache for NMIS.

The NMIS GUI consists of a number of CGI scripts, which need to be 
run by a web server. You will need to integrate NMIS with your particular
web server manually. 

Please use the output of 'nmis.pl type=apache' and check the 
NMIS Installation guide at 
https://community.opmantek.com/display/NMIS/NMIS+8+Installation+Guide
for further info.

Please hit enter to continue:\n";
		my $x = <STDIN>;
	}
	else
	{
		echolog("Found Apache version $versioninfo");

		my $apacheconf = "nmis.conf";
		my $res = system("$site/bin/nmis.pl type="
										 .($istwofour?"apache24":"apache")." > /tmp/$apacheconf");
		my $finaltarget = $osflavour eq "redhat"? 
				"/etc/httpd/conf.d/$apacheconf" : 
				$osflavour eq "debian" ? "/etc/apache2/sites-available/$apacheconf" : undef;

		if ($finaltarget 
				&& input_yn("Ok to install Apache config file to $finaltarget?"))
		{
			execPrint("mv /tmp/$apacheconf $finaltarget");
			execPrint("ln -s $finaltarget /etc/apache2/sites-enabled/")
					if (-d "/etc/apache2/sites-enabled");

			if ($istwofour)
			{
				execPrint("a2enmod cgi");
			}
				
			if ($osflavour eq "redhat")
			{
				execPrint("usermod -G nmis apache");
				execPrint("service httpd restart");
			}
			elsif ($osflavour eq "debian")
			{
				execPrint("adduser www-data nmis");
				execPrint("service apache2 restart");
			}
		}
		else
		{
			echolog("Continuing without Apache configuration.");
			print "You will need to integrate NMIS with your 
web server manually. 

Please use the output of 'nmis.pl type=apache' (or type=apache24) and 
check the NMIS Installation guide at 
https://community.opmantek.com/display/NMIS/NMIS+8+Installation+Guide
for further info.

Please hit enter to continue:\n";
			my $x = <STDIN>;
		}
	}
}

###************************************************************************###
printBanner("NMIS State ".($isnewinstall? "Initialisation":"Update"));

# now offer to run an (initial) update to get nmis' state initialised
# and/or updated
if ( input_yn("NMIS Update: This may take up to 30 seconds (or a very long time with MANY nodes)...
Ok to run an NMIS type=update action?"))
{
	execPrint("$site/bin/nmis.pl type=update");
}
else
{
	print "Ok, continuing without the update run as directed.\n\n
It's highly recommended to run nmis.pl type=update once initially
and after every NMIS upgrade - you should do this manually.\n
Please hit enter to continue: ";

	logInstall("continuing without the update run.\nIt's highly recommended to run nmis.pl type=update once initially and after every NMIS upgrade - you should do this manually.");
	
	my $x = <STDIN>;
}
###************************************************************************###
printBanner("Installation Complete. NMIS Should be Ready to Poll!");
logInstall("Installation finished at ".scalar localtime);

exit 0;

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
				$nmisModules->{$mod}{file} = 'MODULE NOT FOUND';					# set all as 'MODULE NOT FOUND' here, will check installation status of '$mod' next
				$nmisModules->{$mod}{type} = $1;
				if (not grep {$_ eq $f} @{$nmisModules->{$mod}{by}}) {
					push(@{$nmisModules->{$mod}{by}},$f);
				}
			}
		}
		elsif ($line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ ) {
			print "PARSE $f: $line\n" if $debug;
		}

	}	#next line of script
	close $fh;
}


# returns 1 if no critical modules missing, 0 otherwise
sub checkCpan {
	printBanner("Checking for required Perl modules");
	print <<EOF;
This will check for installed Perl modules, first by parsing the 
source code to build a list of used modules. Then by checking that 
the module exists in the src code or is found in the perl standard 
\@INC directory list: @INC

EOF
	
	my $libPath = "$src/lib";
	
	my $mod;
	
	# Check that all the local libaries required by NMIS8, are available to us.
	# when a module is found, parse it for its own reqired modules, so we build a complete install list
	# the nmis base is assumed to be one dir above us, as we should be run from <nmisbasedir>/install folder
	
	# loop over the check and install script

	find(\&getModules, "$src");

	# now determine if installed or not.
	foreach my $mod ( keys %$nmisModules ) {

		my $mFile = $mod . '.pm';
		# check modules that are multivalued, such as 'xx::yyy'	and replace :: with directory '/'
		$mFile =~ s/::/\//g;
		# test for local include first
		if ( -e "$libPath/$mFile" ) {
			$nmisModules->{$mod}{file} = "$libPath/$mFile" . "\t\t" . &moduleVersion("$libPath/$mFile");
		}
		else {
			# Now look in @INC for module path and name
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" ) {
					$nmisModules->{$mod}{file} = "$path/$mFile" . "\t\t" . &moduleVersion("$path/$mFile");
				}
			}
		}

	}

	return listModules();
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

# returns 1 if no critical modules missing, 0 otherwise
sub listModules {
	# list modules found/MODULE NOT FOUND
	my $f1;
	my $f2;
	my $f3;

	format =
  @<<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @>>>>>>>>>
  $f1,                     $f2,                                      $f3
.

  my @missing;
  logInstall("Module status follows:\n");
	foreach my $k (sort {$nmisModules->{$a}{file} cmp $nmisModules->{$b}{file} } keys %$nmisModules) {
		$f1 = $k;
    logInstall("$k\t$nmisModules->{$k}->{file}");
    push @missing, $k if ($nmisModules->{$k}->{file} eq "MODULE NOT FOUND");
		( $f2 , $f3) = split /\s+/, $nmisModules->{$k}{file}, 2;
		$f3 = ' ' if !$f3;
		write();
	}
	
	print qq|
You will need to investigate and possibly install modules indicated with MODULE NOT FOUND.
Missing modules can be installed with CPAN:

  perl -MCPAN -e shell
    install [module name]

  or more conveniently by running
   cpan [module name] [module name...]

Note: The modules Net::LDAP, Net::LDAPS, IO::Socket::SSL, Crypt::UnixCrypt, 
Authen::TacacsPlus, Authen::Simple::RADIUS are optional components for the 
NMIS AAA system.

The modules SNMP_util and SNMP_Session are also optional (needed only for 
the ipsla subsystem) and can be installed either with 
'yum install perl-SNMP_Session' or from the provided tar file in 
install/SNMP_Session-1.12.tar.gz.

The missing modules are: |. join(" ",@missing)."\n\n";

  logInstall("Missing modules: ".join(" ",@missing)."\n");
	logInstall("Module status details: ".Dumper($nmisModules)) if ($debug);


  # return 0 if any critical modules are missing
  my %noncritical = ("Net::LDAP"=>1, "Net::LDAPS"=>1, "IO::Socket::SSL"=>1, "Crypt::UnixCrypt"=>1, "Authen::TacacsPlus"=>1, "Authen::Simple::RADIUS"=>1, "SNMP_util"=>1, "SNMP_Session"=>1, "SOAP::Lite" => 1);
  
  for my $nx (@missing) 
  { 
    return 0 if !$noncritical{$nx};
  }
  return 1;
}


# print question, return true if y (or in unattended mode). default is yes.
sub input_yn 
{
	my ($query) = @_;

	print "$query";
	if ($options{y})
	{
		print " (auto-default YES)\n\n";
		return 1;
	}
	else
	{
		print "\nType 'y' or hit <Enter> to accept, any other key for 'no': ";
		my $input = <STDIN>;
		chomp $input;
		logInstall("User input for \"$query\": \"$input\"");
		
		return ($input =~ /^\s*(y|yes)?\s*$/i)? 1:0;
	}
}

# question, default answer, whether we want confirmation or not
# returns string in question
sub input_str 
{
	my ($query, $default, $wantconfirmation) = @_;

	print "$query [default: $default]: ";
	if ($options{y})
	{
		print " (auto-default)\n\n";
		return $default;
	}
	else
	{
		while (1)
		{
			my $result = $default;

			print "\nEnter new value or hit <Enter> to accept default: ";
			my $input = <STDIN>;
			chomp $input;
			logInstall("User input for \"$query\": \"$input\"");
			$result = $input if ($input ne '');
		
			if ($wantconfirmation)
			{
				print "You entered '$input' -  Is this correct ? <Enter> to accept, or any other key to go back: ";
				$input = <STDIN>;
				chomp $input;
				return $result if ($input eq '');
			}
			else
			{
				return $result;
			}
		}
	}
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
	return "nmis8-backup-$year-$mon-$mday-$hour$min.tgz";
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


# run external program/command via a shell
# external command cannot not prompt or read stdin!
# returns the command's exit code or -1 for signal/didn't start/non-standard termination
sub execPrint {
	my $exec = shift;	
	my $out = `$exec </dev/null 2>&1`;
	my $rawstatus = $?;
	my $res = WIFEXITED($rawstatus)? WEXITSTATUS($rawstatus): -1;
	print $out;
	logInstall("\n\n###+++\nEXEC: $exec\n");
	logInstall($out);
	logInstall("###". ($res? " Exit Code: $res ":''). "+++\n\n");
	return $res;
}


# prints args to stdout, logs to install log.
# args should not have a trailing newline.
sub echolog {
	my (@stuff) = @_;
	print join("\n",@stuff)."\n";
	logInstall(join("\n",@stuff));
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
NMIS Install Script

NMIS Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;

usage: $0 [site=$defaultSite] [fping=$defaultFping] [cpan=(true|false)] [listdeps=(true|false)]

Options:  
  listdeps Only show Perl module dependencies, do not install NMIS
  site	Target site for installation, default is $defaultSite 
  fping	Location of the fping program, default is $defaultFping 
  cpan	Check Perl dependancies or not, default is true

eg: $0 site=$defaultSite fping=$defaultFping cpan=true

/;	
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
