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
use Data::Dumper;
use File::Basename;
use File::Temp;
use POSIX qw();
use Cwd;
use FindBin;
use lib "$FindBin::Bin/../lib";
use func;
use NMIS;

my $VERSION = "1.2.1";

my $usage = "Opmantek Support Tool Version $VERSION\n
Usage: ".basename($0)." action=collect [node=nodename,nodename...]\n
action=collect: collect general support info in an archive file
 if node argument given: also collect node-specific info 
 if nodename='*' then ALL nodes' info will be collected (MIGHT BE HUGE!)\n\n";
my %args = getArguements(@ARGV);

die $usage if (!$args{action});

my $configname = $args{config} || "Config.nmis";
my $maxzip = $args{maxzipsize} || 10*1024*1024; # 10meg
my $tail = 5000;																# last 5000 lines

# first, load the global config
my $globalconf = loadConfTable(conf => $configname);
# make tempdir
my $td = File::Temp::tempdir("/tmp/support.XXXXXX", CLEANUP => 1);

if ($args{action} eq "collect")
{
		# collect evidence
		my $timelabel = POSIX::strftime("%Y-%m-%d-%H%M",localtime);
		my $targetdir = "$td/collect.$timelabel";
		mkdir($targetdir);
		print "collecting support evidence...\n";
		my $status = collect_evidence($targetdir, $args{node});
		die "failed to collect evidence: $status\n" if ($status);
		print "\nevidence collection complete, zipping things up...\n";

		# do we have zip? or only tar+gz?
		my $canzip=0;
		$status = system("zip --version >/dev/null 2>&1");
		$canzip=1 if (POSIX::WIFEXITED($status) && !POSIX::WEXITSTATUS($status));
		
		my $zfn = "/tmp/support-$timelabel.".($canzip?"zip":"tgz");
		
		# zip mustn't become too large, hence we possibly tail/truncate some or all log files
		opendir(D,"$targetdir/logs") or return "can't read $targetdir/logs dir: $!";
		my @shrinkables = map { "$targetdir/logs/$_" } (grep($_ !~ /^\.{1,2}$/, readdir(D)));
		closedir(D);
		while (1)
		{
				# test zip, shrink logfiles, repeat until small enough or out of shrinkables
				my $curdir = getcwd;
				chdir($td);							# so that the zip file doesn't have to whole /tmp/this/n/that/ path in it
				if ($canzip)
				{
					$status = system("zip","-q","-r",$zfn, "collect.$timelabel");
				}
				else
				{
					$status = system("tar","-czf",$zfn,"collect.$timelabel");
				}
				chdir($curdir);

				die "cannot create support zip file $zfn: $!\n"
						if (POSIX::WEXITSTATUS($status));
				last if (-s $zfn < $maxzip);

				# hmm, too big: shrink the log files one by one until the size works out
				unlink($zfn);
				print "zipfile too big, trying to shrink some logfiles...\n";
				if (my $nextfile = pop @shrinkables)
				{
						$status = shrinkfile($nextfile,$tail);
						die "shrinking of $nextfile failed: $status\n" if ($status);
				}
				else
				{
						# nothing left to try :-(
						die "\nPROBLEM: cannot reduce zip file size any further!\nPlease rerun $0 with maxzipsize=N higher than $maxzip.\n";
				}
		}
		print "\nall done.\n",
		"Collected system information is in $zfn\nPlease include this zip file when you contact 
the NMIS Community or the Opmantek Team.\n\n";
}

# remove tempdir (done automatically on exit)
exit 0;


# shrinks given file to the last maxlines lines
# returns undef if ok, error message otherwise
sub shrinkfile
{
		my ($fn,$maxlines)=@_;

		my $tfn = File::Temp->new(DIR => $td, UNLINK => 1);
		system("tail -$maxlines $fn > $tfn") == 0 or return "can't tail $fn: $!";
		rename($tfn,"$fn.truncated") or return "couldn't rename $tfn to $fn.truncated: $!";
		unlink($fn) or return "couldn't remove $fn: $!\n";
		
		return undef;
}

# collects logfiles, config, generic information from var
# and parks all of that in/beneath target dir
# if thisnode is given, then this node's var data is collected as well
# the target dir must already exist
#
# returns nothing if ok, error message otherwise
sub collect_evidence
{
		my ($targetdir,$thisnode) = @_;
		my $basedir = $globalconf->{'<nmis_base>'};

		mkdir("$targetdir/system_status");
		# dump an ls -laRH, H for follow symlinks
		system("ls -laRH $basedir > $targetdir/system_status/filelist.txt") == 0
				or return "can't list nmis dir: $!";
		
		# get md5 sums of the relevant installation files
		print "please wait while we collect file status information...\n";
		system("find -L $basedir -type f|grep -v -e /database/ -e /logs/|xargs md5sum -- >$targetdir/system_status/md5sum 2>&1");
		
		# verify the relevant users and groups, dump groups and passwd (not shadow)
		system("cp","/etc/group","/etc/passwd","$targetdir/system_status/");
		system("id nmis >$targetdir/system_status/nmis_userinfo 2>&1");
		system("id apache >$targetdir/system_status/web_userinfo 2>&1");
		system("id www-data >>$targetdir/system_status/web_userinfo 2>&1");
		# dump the process table
		system("ps ax >$targetdir/system_status/processlist.txt") == 0 
				or return  "can't list processes: $!";
		# dump the memory info, free
		system("cp","/proc/meminfo","$targetdir/system_status/meminfo") == 0
				or return "can't save memory information: $!";
		chmod(0644,"$targetdir/system_status/meminfo"); # /proc/meminfo isn't writable
		system("free >> $targetdir/system_status/meminfo");

		print "please wait while we gather statistics for about 15 seconds...\n";
		# dump 5 seconds of vmstat, two runs of top, 5 seconds of iostat
		# these tools aren't necessarily installed, so we ignore errors
		system("vmstat 1 5 > $targetdir/system_status/vmstat");
		system("top -b -n 2 > $targetdir/system_status/top");	
		system("iostat -kx 1 5 > $targetdir/system_status/iostat");

		# copy /etc/hosts, /etc/resolv.conf, interface and route status
		system("cp","/etc/hosts","/etc/resolv.conf","/etc/nsswitch.conf","$targetdir/system_status/") == 0
				or return "can't save dns configuration files: $!";
		system("/sbin/ifconfig -a > $targetdir/system_status/ifconfig") == 0
				or return "can't save interface status: $!";
		system("/sbin/route -n > $targetdir/system_status/route") == 0
				or return "can't save routing table: $!";

		# copy the install log if there is one
		if (-f "$basedir/install.log")
		{
				system("cp","$basedir/install.log",$targetdir) == 0
						or return "can't copy install.log: $!";
		}

		# collect all defined log files
		mkdir("$targetdir/logs");
		my @logfiles = (map { $globalconf->{$_} } (grep(/_log$/, keys %$globalconf)));
		for my $aperrlog ("/var/log/httpd/error_log", "/var/log/apache/error.log", "/var/log/apache2/error.log")
		{
				push @logfiles, $aperrlog if (-f $aperrlog);
		}
		for my $lfn (@logfiles)
		{
				if (!-f $lfn)
				{
						# two special cases: fpingd and polling.log aren't necessarily present.
						warn "ATTENTION: logfile $lfn configured but does not exist!\n"
								if (basename($lfn) !~ /^(fpingd|polling).log$/);
						next;
				}

				system("cp","$lfn","$targetdir/logs") == 0
						or warn "ATTENTION: can't copy logfile $lfn: $!\n";
		}
		
		# copy all of conf/ and models/
		system("cp","-r","$basedir/models","$basedir/conf",$targetdir) == 0
				or return "can't copy models and conf to $targetdir: $!";

		# copy generic var files (=var/nmis-*)
		mkdir("$targetdir/var");
		opendir(D,"$basedir/var") or return "can't read var dir: $!";
		my @generics = grep(/^nmis-/, readdir(D));
		closedir(D);
		system("cp", (map { "$basedir/var/$_" } (@generics)), 
					 "$targetdir/var") == 0 or return "can't copy var files: $!";

		# if node info requested copy those files as well
		# special case: want ALL nodes
		if ($thisnode eq "*")
		{
				system("cp $basedir/var/* $targetdir/var/") == 0 
						or return "can't copy all nodes' files: $!\n";
		}
		elsif ($thisnode)
		{
				my $lnt = loadLocalNodeTable;
				for my $nextnode (split(/\s*,\s*/,$thisnode))
				{
						if ($lnt->{$nextnode})
						{
								my $fileprefix = "$basedir/var/".lc($nextnode);
								system("cp","$fileprefix-node.nmis","$fileprefix-view.nmis","$targetdir/var/") == 0
										or return "can't copy node ${nextnode}'s node files: $!";
						}
						else
						{
								warn("ATTENTION: the requested node \"$nextnode\" isn't known to NMIS!\n");
						}
				}
		}

		return undef;
}

