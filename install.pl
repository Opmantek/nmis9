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
use 5.10.1;

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

# relax an overly strict umask but for the duration of the installation only
# otherwise dirs and files that are created end up inaccessible for the nmis user...
umask(0022);


my $nmisModules;			# local modules used in our scripts

if ( $ARGV[0] =~ /\-\?|\-h|--help/ ) {
	printHelp();
	exit 0;
}

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $site = $arg{site} ? $arg{site} : "/usr/local/nmis8";
my $listdeps = $arg{listdeps} =~ /1|true|yes/i;

my $debug = $arg{debug}? 1 : 0;
my %options;										# for future unattended mode

die "This installer must be run with root privileges, terminating now!\n"
		if ($> != 0);

system("clear");
my ($installLog, $mustmovelog);
if ( -d $site )
{
	$installLog = "$site/install.log";
}
else
{
	$installLog = "/tmp/install.log";
	$mustmovelog = 1;
}


###************************************************************************###
printBanner("NMIS Installation Script");
my $hostname = `hostname -f`; chomp $hostname;

# figure out where we install from; current dir, check the dirname of this command's invocation, or give up
my $src = cwd();
$src = Cwd::abs_path(dirname($0)) if (!-f "$src/LICENSE");
die "Cannot determine installation source directory!\n" if (!-f "$src/LICENSE");

die "The installer cannot be run out of the live target directory!
Please unpack the NMIS sources in a different directory (e.g. /tmp)
and restart the installer there!\n\n" if ($src eq $site);

my $nmisversion;
open(G, "./lib/NMIS.pm");
for  my $line (<G>)
{
	if ($line =~ /^\$VERSION\s*=\s*"(.+)";\s*$/)
	{
		$nmisversion = $1;
		last;
	}
}
close G;
logInstall("Installation of NMIS $nmisversion on host '$hostname' started at ".scalar localtime(time));


# there are some slight but annoying differences
my $osflavour;
if (-f "/etc/redhat-release")
{
	$osflavour="redhat";
	logInstall("detected OS flavour RedHat/CentOS");
}
elsif (-f "/etc/os-release")
{
	open(F,"/etc/os-release");
	my @osinfo = <F>;
	close(F);
	if (grep(/ID=debian/, @osinfo))
	{
		$osflavour="debian";
		logInstall("detected OS flavour Debian");
	}
	elsif (grep(/ID=ubuntu/, @osinfo))
	{
		$osflavour="ubuntu";
		logInstall("detected OS flavour Ubuntu");
	}
}
if (!$osflavour)
{
	echolog("Attention: The installer was unable to determine the type of your OS
and won't be able to make certain installation adjustments!

We recommend that you check the NMIS Installation guide at 
https://community.opmantek.com/display/NMIS/NMIS+8+Installation+Guide
for further info.\n\n");
	print "Hit <Enter> to continue:\n";
	my $x = <STDIN>;
}



logInstall("Installation source is $src");

###************************************************************************###
printBanner("Checking Perl version...");

if ($^V < version->parse("5.10.1")) 
{  
	echolog("The version of Perl installed on your server is lower than the minimum 
supported version 5.10.1. Please upgrade to at least Perl 5.10.1");
	exit 1;
}
else {
	echolog("The version of Perl installed on your server is $^V and OK");
}

printBanner("Checking SELinux Status");
my $rawstatus = system("selinuxenabled");
if (WIFEXITED($rawstatus))
{
	if (WEXITSTATUS($rawstatus) == 0)
	{
		my $flavour = `getenforce 2>/dev/null`;
		chomp ($flavour);

		if ($flavour =~ /permissive/i)
		{
			echolog("SELinux is enabled but in permissive mode.");
		}
		else
		{
			echolog("SELinux is enabled!");
			print "\n
The installer has detected that SELinux is enabled on your system
and that it is set to enforce its policy.\n
SELinux needs extensive configuration to work properly.\n
In its default configuration it is known to interfere with NMIS,
and we do therefore recommend that you disable SELinux for NMIS.

See \"man 8 selinux\" for details.\n\nHit <Enter> to continue:\n";
			my $x = <STDIN>;
		}
	}
	else
	{
		echolog("SELinux is not enabled.");
	}
}
else
{
	echolog("Could not determine SELinux status, exit code was $rawstatus");
}

###************************************************************************###
my $can_use_web;
if ($osflavour)
{
	my @debpackages = (qw(autoconf automake gcc make libcairo2 libcairo2-dev libglib2.0-dev
libpango1.0-dev libxml2 libxml2-dev libgd-gd2-perl libnet-ssleay-perl
libcrypt-ssleay-perl apache2 fping snmp snmpd libnet-snmp-perl
libcrypt-passwdmd5-perl libjson-xs-perl libnet-dns-perl
libio-socket-ssl-perl libwww-perl libnet-smtp-ssl-perl libnet-smtps-perl
libcrypt-unixcrypt-perl libcrypt-rijndael-perl libuuid-tiny-perl libproc-processtable-perl
libnet-ldap-perl libnet-snpp-perl libdbi-perl libtime-modules-perl
libsoap-lite-perl libauthen-simple-radius-perl libauthen-tacacsplus-perl
libauthen-sasl-perl rrdtool librrds-perl libsys-syslog-perl libtest-deep-perl dialog libui-dialog-perl));

	my @rhpackages = (qw(autoconf automake gcc cvs cairo cairo-devel
pango pango-devel glib glib-devel libxml2 libxml2-devel gd gd-devel
libXpm-devel libXpm openssl openssl-devel net-snmp net-snmp-libs
net-snmp-utils net-snmp-perl perl-Net-SSLeay perl-JSON-XS httpd fping
make groff perl-CPAN crontabs dejavu* perl-libwww-perl perl-Net-DNS
perl-DBI perl-Net-SMTPS perl-Net-SMTP-SSL perl-Time-modules
perl-CGI net-snmp-perl perl-Proc-ProcessTable perl-Authen-SASL
perl-Crypt-PasswdMD5 perl-Crypt-Rijndael perl-Net-SNPP perl-Net-SNMP perl-GD rrdtool
perl-rrdtool perl-Test-Deep dialog perl-UI-Dialog));

	# cgi was removed from core in 5.20
	if (version->parse($^V) >= version->parse("5.19.7"))
	{
		push @debpackages, "libcgi-pm-perl";
		push @rhpackages, "perl-CGI";
	}

	my $pkgmgr = $osflavour eq "redhat"? "YUM": ($osflavour eq "debian" or $osflavour eq "ubuntu")? "APT": undef;
	my $pkglist = $osflavour eq "redhat"? \@rhpackages : ($osflavour eq "debian" or $osflavour eq "ubuntu")? \@debpackages: undef;

	# first check if internet/web access is available
	printBanner("Checking Web access...");
	
	# curl is present in most basic redhat install
	# wget is present on debian/ubuntu via priority:important
	my $testres = system("curl -s -m 10 -o /dev/null https://opmantek.com/robots.txt 2>/dev/null") >> 8;
	$testres = system("wget -q -T 10 -O /dev/null https://opmantek.com/robots.txt 2>/dev/null") >> 8 
			if ($testres);
	$can_use_web = !$testres;

	if ($can_use_web)
	{
		echolog("Web access is ok.");
	}
	else
	{
		echolog("No Web access available!");
		print "Your system cannot access the web, therefore $pkgmgr will not
be able to download any missing software packages. If any 
such missing packages are detected and you don't have
a local source of packages (e.g. an installation DVD) then the
installation won't complete successfully.

We recommend that you check our Wiki article on working around
package installation without Internet access in that case:

https://community.opmantek.com/x/boSG\n\n";
		
		print "Hit <Enter> to continue:\n";
		my $x = <STDIN>;
	}

	if ($osflavour eq "debian" or $osflavour eq "ubuntu")
	{
		my @unresolved;

		# one or two packages are not a/v in wheezy
		my $osversion = `lsb_release -r`; $osversion =~ s/^.*:\s*//;
		
		printBanner("Updating package status, please wait...");
		execPrint("apt-get update -qq");

		printBanner("Checking Dependencies...");
		
		for my $pkg (@debpackages)
		{
			next if ($pkg eq "libnet-smtps-perl" # not packaged in wheezy
							 and $osflavour eq "debian" 
							 and version->parse($osversion) < version->parse("8.0")); 
			
			if (`dpkg -l $pkg 2>/dev/null` =~ /^ii\s*$pkg\s*/m)
			{
				echolog("Required package $pkg is already installed.");
			}
			else
			{
				echolog("Required package $pkg is NOT installed!");
				push @unresolved, $pkg;
			}
		}

		if (@unresolved)
		{
			my $packages = join(" ",@unresolved);
			echolog("\n\nSome required packages are missing:
$packages\n
The installer can use $pkgmgr to download and install these packages.\n");
							
			if (input_yn("Do you want to install these packages with $pkgmgr now?"))
			{
				$ENV{"DEBIAN_FRONTEND"}="noninteractive";

				for my $missing (@unresolved)
				{
					echolog("\nInstalling $missing with apt-get");
					execPrint("apt-get -yq install $missing");
				}
				print "\n\n";			# apt is a bit noisy
			}
			else
			{
				echolog("Required packages not present but installer instructed to NOT install them.");
				print "\nNMIS will not run correctly without the following packages installed:\n
$packages\n
You will have to resolve these 
dependencies manually before NMIS can operate properly.\n\nHit <Enter> to continue:\n";
					my $x = <STDIN>;
			}
		}
	}
	elsif ($osflavour eq "redhat")
	{
		my %unresolved;
		
		if ($can_use_web)
		{
			printBanner("Updating YUM metadata cache...");
			system("yum makecache");
		}

		printBanner("Checking Dependencies...");
		
		# a few packages are only available via the EPEL repo and others need repoforge/rpmfore, too
		open(F,"/etc/redhat-release");
		my $rhver =	<F>; 
		chomp $rhver;
		close F;
		my $iscentos = ($rhver =~ /CentOS/);
		$rhver =~ s/^[^0-9]+(\d)\.\d.*$/$1/;

		# check the enabled extra repos
		my %enabled_repos;
		open(F, "yum -C -v repolist enabled|") or die "cannot get repository list from yum: $!\n";
		for my $line (<F>)
		{
			if ($line =~ /^Repo-id\s*:\s*(\S+)/)
			{
				$enabled_repos{$1} = 1;
			}
		}
		close(F);

		for my $pkg (@rhpackages)
		{
			my $installcmd = "yum -y install $pkg";
			my ($ispresent, $present_version, $repo, $reponame, $repourl);

			if (my $rpmstatus = `rpm -qa $pkg 2>/dev/null`)
			{
				$present_version = version->parse($1) if ($rpmstatus =~ /^\S+-(\d+\.\d+(\.\d+)?)/m);
				$ispresent = 1;
		
				# rrdtool and perl-rrdtool are doubly special - we need a recent enough version
				$ispresent = 0
						if (($pkg eq "rrdtool" or $pkg eq "rrdtool-perl") 
								and $present_version < version->parse("1.4.4"));
			}

			if ($ispresent)
			{
				echolog("Required package $pkg is already installed"
								. ($present_version? " (version $present_version)." : "."));
				next;
			}

			# special handling for rpmforge packages
			if ($pkg eq "fping" or $pkg eq "rrdtool" or $pkg eq "rrdtool-perl")
			{
				$installcmd = "yum -y --enablerepo=rpmforge-extras install $pkg";
				$repo="rpmforge";
				$reponame="RPMforge";
				$repourl = "http://repoforge.org/";
			}
			# ditto for epel
			elsif ($pkg eq "perl-Net-SNMP" or $pkg eq "glib" or $pkg eq "glib-devel"
						 or $pkg eq "perl-Crypt-Rijndael" or $pkg eq "perl-JSON-XS" 
						 or $pkg eq "perl-Net-SMTPS" or $pkg eq "perl-Net-SNPP" 
						 or $pkg eq "perl-Proc-ProcessTable")
			{
					$installcmd = "yum -y --enablerepo=epel install $pkg";
					$repo="epel";
					$reponame="EPEL";
					$repourl = "https://fedoraproject.org/wiki/EPEL/";
			}

			echolog("Required package $pkg is NOT installed!");
			$unresolved{$pkg} = { installcmd => $installcmd, 
														repo => $repo, 
														reponame => $reponame, 
														repourl => $repourl };
		}
		
		if (keys %unresolved)
		{
			my $packages = join(" ",sort keys %unresolved);
			echolog("\n\nSome required packages are missing:
$packages\n
The installer can use $pkgmgr to download and install these packages.\n");
							
			if (input_yn("Do you want to install these packages with $pkgmgr now?"))
			{
				for my $missing (keys %unresolved)
				{
					my ($installcmd, $repo, $reponame, $repourl ) = @{$unresolved{$missing}}{qw(installcmd repo reponame repourl)};
					
					if ($repo and !$enabled_repos{$repo})
					{
						if (!$can_use_web)
						{
							printBanner("Cannot enable repository $reponame!");
							print "\nThe $reponame repository is required for installing $missing, but 
your system does not have web access and thus cannot 
download anything from that repository. 

You will have to install $missing manually (downloadable 
from $repourl).\n\nHit <Enter> to continue:\n";
							my $x = <STDIN>;
							next;
						}
						else
						{
							enable_custom_repo($repo, $iscentos, $rhver);
							$enabled_repos{$repo} = 1;
						}
					}

					echolog("\nInstalling $missing with yum".($repo? " from repository $reponame": ""));
					execPrint($installcmd);
						
					if ($missing eq "httpd")
					{
						# silly redhat doesn't start services on installation
						execPrint("chkconfig --add $missing"); 
						execPrint("chkconfig $missing on"); 
					}
					print "\n\n";			# yum is pretty noisy
				}
			}
			else
			{
				echolog("Required packages not present but installer instructed to NOT install them.");
				print "\nNMIS will not run correctly without the following packages installed:\n
$packages\n
You will have to resolve these
dependencies manually before NMIS can operate properly.\n\n";
			
				for my $missing (sort keys %unresolved)
				{
					print "The Package $missing can be downloaded from "
							.($unresolved{$missing}->{repourl})."\n" 
							if ($unresolved{$missing}->{repourl});
				}
					
				print "Hit <Enter> to continue:\n";
				my $x = <STDIN>;
			}
		}
	}
}

printBanner("Checking Perl Module Dependencies...");

my ($isok,@missingones) = &checkCpan;
if (!$isok)
{
	print "The installer can use CPAN to install the missing Perl packages
that NMIS depends on, if your system has Internet access.\n\n";

	if (!$can_use_web or !input_yn("OK to use CPAN to install missing modules?"))
	{
		echolog("Cannot install missing CPAN modules.");
		print "NMIS will not work properly until the following Perl modules are installed (from CPAN):\n\n".join(" ",@missingones)
				."\n\nWe recommend that you stop the installer now, resolve the dependencies, 
and then restart the installer.\n\n";
		
		if (input_yn("Stop the installer?"))
		{
			die "\nAborting the installation. Please install the missing Perl packages\nwith cpan, then restart the installer.\n";
		}
	}
	else
	{
		echolog("Installing modules with CPAN");
		system("cpan ".join(" ",@missingones));  # can't use execprint as cpan is interactive
	}
}
	 
if ($listdeps)
{
	echolog("Dependency checks completed, NOT proceeding with installation as requested.\n");
	exit 0;
}

# check that rrdtool is indeed new enough
printBanner("Checking RRDTool Version");
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
			print "Please hit <Enter> to continue:\n";
			my $x = <STDIN>;
		}
	}
}

###************************************************************************###
printBanner("Checking Installation Target");
print "The standard NMIS installation target is \"$site\".
To install NMIS into a different directory please answer the question below
with \"no\" and restart the installer with the argument site=<custom_dir>,
e.g. ./install.pl site=/opt/nmis8\n\n";

if (!input_yn("OK to start installation/upgrade to $site?"))
{
	echolog("Exiting installation as directed.\n");
	exit  0;
}

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

my $isnewinstall;
if ( not -d $site ) 
{
	$isnewinstall=1;
	mkdir($site,0755) or die "cannot mkdir $site: $!\n";
}

# now switch to the install.log in the final location
if ($mustmovelog)
{
	my $newlog = "$site/install.log";
	system("mv $installLog $newlog");
	$installLog = $newlog;
}

# before copying anything, lock nmis...
open(F,">$site/conf/NMIS_IS_LOCKED");
print F "$0 is operating, started at ".(scalar localtime)."\n";
close F;

# ...and kill any currently running fpingd 
execPrint("$site/bin/fpingd.pl kill=true");

printBanner("Copying NMIS files...");
echolog("Copying source files from $src to $site...\n");

# fixme: this fails benignly but noisyly if there are 
# (convenience) symlinks in the nmis dir, e.g. var or database
execPrint("cp -r $src/* $site");

# catch missing nmis user, regardless of upgrade/new install
if (!getpwnam("nmis"))
{
	if (input_yn("OK to create NMIS user?"))
	{
		# redhat/centos' adduser is non-interactive, debian/ubuntu's wants interaction
		if ($osflavour eq "redhat")
		{
			execPrint("adduser nmis");
		}
		elsif ($osflavour eq "debian" or $osflavour eq "ubuntu")
		{
			execPrint("useradd nmis");
		}
	}
	else
	{
		echolog("Continuing without nmis user.\n");
	}
}

if ($isnewinstall)
{
		printBanner("Installing default config files...");
		execPrint("cp -a $site/install/* $site/conf/");
		execPrint("cp -a $site/models-install/* $site/models/");
		# this test plugin shouldn't be activated automatically
		unlink("$site/conf/plugins/TestPlugin.pm") if (-f "$site/conf/plugins/TestPlugin.pm");
}
else
{
	# copy over missing plugins if allowed
	opendir(D,"$site/install/plugins") or warn "cannot open directory install/plugins: $!\n";
	my @candidates = grep(/\.pm$/, readdir(D));
	closedir(D);

	if (@candidates)
	{
		if (!-d "$site/conf/plugins") {
			mkdir("$site/conf/plugins",0755) or die "cannot mkdir $site/conf/plugins: $!\n";
		}
		printBanner("Updating plugins");

		for my $maybe (@candidates)
		{
			next if ($maybe eq "TestPlugin.pm"); # this example plugin shouldn't be auto-activated
			my $docopy;
			if (-f "$site/conf/plugins/$maybe")
			{
				my $havechange = system("diff -q $site/install/plugins/$maybe $site/conf/plugins/$maybe >/dev/null 2>&1") >> 8;
				if ($havechange and input_yn("OK to replace changed plugin $maybe?"))
				{
					$docopy=1;
				}
			}
			else
			{
				$docopy =1;
			}
			execPrint("cp $site/install/plugins/$maybe $site/conf/plugins/$maybe")
					if ($docopy);
		}
	}

	printBanner("Copying new and updated NMIS config files");
	for my $cff ("BusinessServices.nmis","ServiceStatus.nmis",
							 "Customers.nmis", "Events.nmis")
	{
		if (-f "$site/install/$cff" && !-f "$site/conf/$cff")
		{
			execPrint("cp -a $site/install/$cff $site/conf/$cff");
		}
	}
	execPrint("cp -fa $site/install/Tables.nmis $site/install/Table-*.nmis $site/conf/");
	
	###************************************************************************###
	printBanner("Updating the config files with any new options...");

	if (input_yn("OK to update the config files?"))
	{
			# merge changes for new NMIS Config options. 
			execPrint("$site/admin/updateconfig.pl $site/install/Config.nmis $site/conf/Config.nmis");
			execPrint("$site/admin/updateconfig.pl $site/install/Access.nmis $site/conf/Access.nmis");
		
			# update default config options that have been changed:
			execPrint("$site/install/update_config_defaults.pl $site/conf/Config.nmis");

			execPrint("$site/admin/updateconfig.pl $site/install/Modules.nmis $site/conf/Modules.nmis");

			# patch config changes that affect existing entries, which update_config_defaults 
			# doesn't handle
 			# which includes enabling uuid
			execPrint("$site/admin/patch_config.pl -b $site/conf/Config.nmis /system/non_stateful_events='Node Configuration Change, Node Reset, NMIS runtime exceeded' /globals/uuid_add_with_node=true /system/node_summary_field_list,=uuid /system/json_node_fields,=uuid");
			echolog("\n");

			if (input_yn("OK to remove syslog and JSON logging from default event escalation?"))
			{
				execPrint("$site/admin/patch_config.pl -b $site/conf/Escalations.nmis /default_default_default_default__/Level0=''");
				echolog("\n");
			}
			
			if (input_yn("OK to set the FastPing/Ping timeouts to the new default of 5000ms?"))
			{
				execPrint("$site/admin/patch_config.pl -b -n $site/conf/Config.nmis /system/fastping_timeout=5000 /system/ping_timeout=5000");
			}
			
			# move config/cache files to new locations where necessary
			if (-f "$site/conf/WindowState.nmis")
			{
				printBanner("Moving old WindowState file to new location");
				execPrint("mv $site/conf/WindowState.nmis $site/var/nmis-windowstate.nmis");
			}

			# disable the uuid plugin, which this version doesn't need
			my $obsolete = "$site/conf/plugins/UUIDPlugin.pm";
			if (-f $obsolete)
			{
				echolog("Disabling obsolete UUID Plugin");
				rename($obsolete, "$obsolete.disabled");
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
			print "\n\nPlease hit <Enter> to continue: ";
			my $x = <STDIN>;
	}

	printBanner("Comparing Models");
	
	if (input_yn("OK to run a comparison of old and new models?"))
	{
		# let's not run this with execPrint as that might take quite a bit of time
		my $res = system("$site/admin/compare_models.pl $site/models $site/models-install");
		if ($res >> 8)
		{
			print "\n\nPlease hit <Enter> to continue:";
			my $x = <STDIN>;
		}
	}
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
			echolog("Running RRD migration script in test mode first...");
			my $error = execPrint("$site/admin/migrate_rrd_locations.pl newlayout=$site/models-install/Common-database.nmis simulate=true");
			if ($error)
			{
				echolog("Error: RRD migration script detected problems!
The RRD migration script could not complete its test run successfully.
The RRD migration will therefore NOT be performed. 

Please check the installation log and diagnostic output for details.\nHit <Enter> to continue:\n");
				my $x = <STDIN>;
			}
			else
			{
				echolog("Performing the actual RRD migration operation...\n");
				my $error = execPrint("$site/admin/migrate_rrd_locations.pl newlayout=$site/models-install/Common-database.nmis");
				
				if ($error)
				{
					echolog("Error: RRD migration failed! Please use the rollback script
listed above to revert to the original status!\nHit <Enter> to continue:\n");
					my $x = <STDIN>;
				}
				else
				{
					echolog("RRD migration completed successfully.");
				}
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
			print "Please hit <Enter> to continue:\n";
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

# daemon restarting should only be done after nmis is unlocked
printBanner("Restart the fping daemon...");
execPrint("$site/bin/fpingd.pl restart=true");

if ( -x "$site/bin/opslad.pl" ) {
	printBanner("Restarting the opSLA Daemon...");
	execPrint("$site/bin/opslad.pl"); # starts a new one and kills any existing ones
}


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

Please hit <Enter> to continue:\n";
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
				($osflavour eq "debian" or $osflavour eq "ubuntu")? "/etc/apache2/sites-available/$apacheconf" : undef;

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
			elsif ($osflavour eq "debian" or $osflavour eq "ubuntu")
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

Please hit <Enter> to continue:\n";
			my $x = <STDIN>;
		}
	}
}

# logrotate 3.8.X wants different rotation config options...
printBanner("NMIS Log Rotation Setup");
my $lrver = `logrotate -v 2>&1`;
if ($lrver =~ /^logrotate (\d+\.\d+\.\d+)/m)
{
	my $version = version->parse("$1");
	echolog("Found logrotate version $version");
	my $lrfile =  "$site/install/" . ($version >= version->parse("3.8.0")? "logrotate.380.conf" : "logrotate.conf");
	my $lrtarget = "/etc/logrotate.d/nmis";

	my $havechange = system("diff -q $lrfile $lrtarget >/dev/null 2>&1") >> 8;
	if (!-f $lrtarget or $havechange)
	{
		if (input_yn("OK to install updated log rotation configuration file\n\t$lrfile in /etc/logrotate.d?"))
		{
			execPrint("cp $lrfile $lrtarget");
		}
		else
		{
			echolog("Not installing updated $lrfile as requested.");
		}
	}
	else 
	{
		echolog("Log rotation file $lrtarget present and same as default");
	}
}
else
{
	print "Cannot determine logrotate's version!\n
The installer could not determine the version of your \"logrotate\" tool,
and you will have to configure log rotation manually. There are two default
log rotation configuration files in $site/install 
that you should use as the basis for your setup.\n\nPlease hit <Enter> to continue:\n";
	my $x = <STDIN>;
}

printBanner("NMIS Cron Setup");
print "NMIS relies on Cron to schedule its periodic execution,
and provides an example/default Cron schedule.

The installer can install this default schedule in /etc/cron.d/nmis,
which immediately activates it.

If you already have NMIS entries in your root crontab, 
then the installer will comment out all NMIS entries in
that crontab.\n\n";

my $crongood = (-f "/etc/cron.d/nmis");
if (input_yn("Do you want the default NMIS Cron schedule\nto be installed in /etc/cron.d/nmis?"))
{
	echolog("Creating default Cron schedule with nmis.pl type=crontab");
	my $res = system("$site/bin/nmis.pl type=crontab system=true >/tmp/new-nmis-cron");
	
	if (0 == $res>>8)
	{
		echolog("Cleaning up old per-user crontab");

		my $oldcronfixedup;
		# now clean up the old per-user cron, if there is one!
		my $res = system("crontab -l > $site/conf/crontab.root");
		if (0 == $res>>8)
		{
			echolog("Old crontab was saved in $site/conf/crontab.root");

			open (F, "$site/conf/crontab.root") or die "cannot read crontab.root: $!\n";
			my @crondata = <F>;
			close F;
			for my $line (@crondata)
			{
				$line = "# NMIS8 Cron Config is now in /etc/cron.d/nmis\n" if ($line =~ /^#\s*NMIS8 Config/);
				$line = "#disabled! ".$line if ($line =~ m!(nmis8?/bin|nmis8?/conf|nmis8?/admin)!);
			}
			open (G, "|crontab -") or die "cannot fork to update crontab: $!\n";
			print G @crondata;
			close G;
			echolog("Cleaned-up crontab was installed.");
			$oldcronfixedup = 1;
		}

		execPrint("mv /tmp/new-nmis-cron /etc/cron.d/nmis");
		
		print "\nA new default cron was created in /etc/cron.d/nmis, 
but feel free to adjust it.\n\n";

		if ($oldcronfixedup)
		{
			print "Any NMIS entries in root's existing crontab were commented out,
and a backup of the crontab was saved in $site/cronf/crontab.root.\n\n";
		}
		
		print "Please hit <Enter> to continue:\n";
		my $x = <STDIN>;
		$crongood = 1;
		logInstall("New system crontab was installed in /etc/cron.d/nmis");
	}
	else
	{
		echolog("Default Cron schedule generation failed!");
		$crongood = 0;
	}
}

if (!$crongood)
{
	print "\n\nTo see what the suggested default Cron schedule is like,
simply run \"$site/bin/nmis.pl type=crontab system=true >/tmp/somefile\", then
view /tmp/somefile. NMIS will require some scheduling setup
to work correctly.\n\nPlease hit <Enter> to continue:\n";
	my $x = <STDIN>;
}

###************************************************************************###
printBanner("NMIS State ".($isnewinstall? "Initialisation":"Update"));

# now offer to run an (initial) update to get nmis' state initialised
# and/or updated
if ( input_yn("NMIS Update: This may take up to 30 seconds\n(or a very long time with MANY nodes)...\n
Ok to run an NMIS type=update action?"))
{
	execPrint("$site/bin/nmis.pl type=update");
}
else
{
	print "Ok, continuing without the update run as directed.\n\n
It's highly recommended to run nmis.pl type=update once initially
and after every NMIS upgrade - you should do this manually.\n
Please hit <Enter> to continue: ";

	logInstall("continuing without the update run.\nIt's highly recommended to run nmis.pl type=update once initially and after every NMIS upgrade - you should do this manually.");
	
	my $x = <STDIN>;
}



###************************************************************************###
printBanner("Installation Complete. NMIS Should be Ready to Poll!");
print "You should now be able to access NMIS at http://<yourserver name or ip>/nmis8/\n
Based on your hostname config, this would be\n\thttp://$hostname/nmis8/\n\n";
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
			$line =~ m/^(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)(\s+([0-9\.]+))?/ 
			or $line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+)(\s+([0-9\.]+))?/ 
			or $line =~ m/(use|require)\s+(\w+)(\s+([0-9\.]+))?;/ 
		) 
		{
			my ($mod, $minversion) = ($2,$4);
			
			if ( defined $mod and $mod ne '' and $mod !~ /^\d+/ ) 
			{
				$nmisModules->{$mod}{file} = 'MODULE NOT FOUND';					# set all as 'MODULE NOT FOUND' here, will check installation status of '$mod' next
				$nmisModules->{$mod}{type} = $1;
				$nmisModules->{$mod}{minversion} = $minversion if (defined $minversion);

				if (not grep {$_ eq $f} @{$nmisModules->{$mod}{by}}) 
				{
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


# returns (1) if no critical modules missing, (0,critical modules) otherwise
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
			$nmisModules->{$mod}{file} = "$libPath/$mFile";
			$nmisModules->{$mod}{version} = &moduleVersion("$libPath/$mFile");
		}
		else {
			# Now look in @INC for module path and name
			# and record the newest one
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" ) 
				{
					my $thisversion = moduleVersion("$path/$mFile");
					if (!$nmisModules->{$mod}{version}
							or !$thisversion
							or version->parse($thisversion) >= version->parse($nmisModules->{$mod}{version}))
					{
						$nmisModules->{$mod}{file} = "$path/$mFile";
						$nmisModules->{$mod}{version} = $thisversion;
					}
				}
			}
		}

	}
	# returns status, list of critical missing
	my ($status, @missing) = &listModules;
	return ($status, @missing);
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
				return "$1";
			}
		}
	}
	close FH;
	return '';
}

# returns (1) if no critical modules missing, (0,critical) otherwise
sub listModules 
{
  my (@missing, @critmissing);
  my %noncritical = ("Net::LDAP"=>1, "Net::LDAPS"=>1, "IO::Socket::SSL"=>1, 
										 "Crypt::UnixCrypt"=>1, "Authen::TacacsPlus"=>1, "Authen::Simple::RADIUS"=>1, 
										 "SNMP_util"=>1, "SNMP_Session"=>1, "SOAP::Lite" => 1, "UI::Dialog" => 1);

	
  logInstall("Module status follows:\nName - Path - Current Version - Minimum Version\n");
	foreach my $k (sort {$nmisModules->{$a}{file} cmp $nmisModules->{$b}{file} } keys %$nmisModules) 
	{
    logInstall(join("\t", $k, $nmisModules->{$k}->{file},
										$nmisModules->{$k}->{version}||"N/A", $nmisModules->{$k}->{minversion}||"N/A"));
		# report as missing: if not present, or version below required minimum
    push @missing, $k if 	($nmisModules->{$k}->{file} eq "MODULE NOT FOUND"
													 or (defined $nmisModules->{$k}->{minversion}
															 and version->parse($nmisModules->{$k}->{version}) < version->parse($nmisModules->{$k}->{minversion})));
	}

	if (@missing)
	{
		@critmissing = grep( !$noncritical{$_}, @missing);
		my @optionals = grep ($noncritical{$_}, @missing);

		if (@optionals)
		{
			printBanner("Some Optional Perl Modules are missing (or too old)");
			print qq|The following optional modules are missing or too old:\n| .join(" ", @optionals)
					.qq|\n\nNote: The modules Net::LDAP, Net::LDAPS, IO::Socket::SSL, Crypt::UnixCrypt, 
Authen::TacacsPlus, Authen::Simple::RADIUS are optional components for the 
NMIS AAA system.

The modules SNMP_util and SNMP_Session are also optional (needed only for 
the ipsla subsystem) and can be installed either with 
'yum install perl-SNMP_Session' or from the provided tar file in 
install/SNMP_Session-1.12.tar.gz.\n\n|;
		}

		if (@critmissing)
		{
			printBanner("Some Critical Perl Modules are missing (or too old)!");
			print qq|The following essential Perl modules are missing or too old and need 
to be installed (or upgraded) before NMIS will work correctly:\n\n| . join(" ", @critmissing)."\n\n";
		}
		
		print qq|These modules can be installed with CPAN:

  perl -MCPAN -e shell
    install [module name]

  or more conveniently by running
   cpan [module name] [module name...]\n\n|;
	}

	my $resultcode = @critmissing? 0 : 1;
	return ($resultcode, @critmissing);
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

usage: $0 [site=$site] [listdeps=(true|false)]

Options:  
  listdeps Only show (missing) dependencies, do not install NMIS
  site	Target site for installation, default is $site 

eg: $0 site=$site cpan=true

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

sub enable_custom_repo
{
	my ($reponame, $iscentos, $majorlevel) = @_;

	# epel: comfy for centos, not so for rh
	# repoforge: uncomfy everywhere
	if ($reponame eq "epel" )
	{
		echolog("\nEnabling EPEL repository\n");
		if ($iscentos)
		{
			execPrint("yum -y install epel-release");
		}
		else
		{
			execPrint("yum -y install 'https://dl.fedoraproject.org/pub/epel/epel-release-latest-$majorlevel.noarch.rpm'");
		}
	}
	elsif ($reponame =~ /^(repo|rpm)forge$/i)
	{
		echolog("\nEnabling RepoForge repository\n");
		execPrint("yum -y install 'http://pkgs.repoforge.org/rpmforge-release/rpmforge-release-0.5.3-1.el$majorlevel.rf.x86_64.rpm'");
	}
	else
	{
		die "Cannot enable unknown custom repository \"reponame\"!\n";
	}
}

