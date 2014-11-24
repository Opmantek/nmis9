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

my $VERSION = "1.3.2";

my $usage = "Opmantek NMIS Support Tool Version $VERSION\n
Usage: ".basename($0)." action=collect [node=nodename,nodename...]\n
action=collect: collect general support info in an archive file
 if node argument given: also collect node-specific info 
 if nodename='*' then ALL nodes' info will be collected (MIGHT BE HUGE!)\n\n";
my %args = getArguements(@ARGV);

die $usage if (!$args{action});

my $configname = $args{config} || "Config.nmis";
my $maxzip = $args{maxzipsize} || 10*1024*1024; # 10meg
my $maxlogsize = $args{maxlogsize} || 4*1024*1024; # 4 meg for individual log files
my $tail = 4000;																# last 4000 lines

# first, load the global config
my $globalconf = loadConfTable(conf => $configname);
# make tempdir
my $td = File::Temp::tempdir("/tmp/support.XXXXXX", CLEANUP => 1);

if ($args{action} eq "collect")
{
		# collect evidence
		my $timelabel = POSIX::strftime("%Y-%m-%d-%H%M",localtime);
		my $targetdir = "$td/nmis-collect.$timelabel";
		mkdir($targetdir);
		print "collecting support evidence...\n";
		my $status = collect_evidence($targetdir, \%args);
		die "failed to collect evidence: $status\n" if ($status);

		my $omkzfn;
		# if omk and its support tool found, run that as well if allowed to!
		if (-d "/usr/local/omk" && -f "/usr/local/omk/bin/support.pl" && !$args{no_other_tools})
		{
			open(LF, ">$targetdir/omk-support.log");

			print "\nFound local OMK installation with OMK support tool.
Please wait while we collect OMK information as well.\n";
			open(F, "/usr/local/omk/bin/support.pl action=collect no_system_stats=1 no_other_tools=1 2>&1 |")
					or warn "cannot execute OMK support tool: $!\n";
			while (my $line = <F>)
			{
				print LF $line;
				if ($line =~ /information is in (\S+)/)
				{
					$omkzfn = $1;
				}
			}
			close F;
			close LF;
		}

		print "\nEvidence collection complete, zipping things up...\n";

		# do we have zip? or only tar+gz?
		my $canzip=0;
		$status = system("zip --version >/dev/null 2>&1");
		$canzip=1 if (POSIX::WIFEXITED($status) && !POSIX::WEXITSTATUS($status));
		
		my $zfn = "/tmp/nmis-support-$timelabel.".($canzip?"zip":"tgz");
		
		# zip mustn't become too large, hence we possibly tail/truncate some or all log files
		opendir(D,"$targetdir/logs") 
				or warn "can't read $targetdir/logs dir: $!\n";
		my @shrinkables = map { "$targetdir/logs/$_" } (grep($_ !~ /^\.{1,2}$/, readdir(D)));
		closedir(D);
		while (1)
		{
				# test zip, shrink logfiles, repeat until small enough or out of shrinkables
				my $curdir = getcwd;
				chdir($td);							# so that the zip file doesn't have to whole /tmp/this/n/that/ path in it
				if ($canzip)
				{
					$status = system("zip","-q","-r",$zfn, "nmis-collect.$timelabel");
				}
				else
				{
					$status = system("tar","-czf",$zfn,"nmis-collect.$timelabel");
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


		print "\nAll done.\n\nCollected system information is in $zfn\n";
		print "OMK information is in $omkzfn\n\n" if ($omkzfn);
		print "Please include ".($omkzfn? "these zip files": "this zip file"). " when you contact 
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
# the target dir must already exist
#
# args: node, no_system_stats
# if node given, then this node's var data is collected as well
# if no_system_stats is set then the time-consuming top, iostat etc are skipped

#
# returns nothing if ok, error message otherwise
sub collect_evidence
{
		my ($targetdir,$args) = @_;
		my $basedir = $globalconf->{'<nmis_base>'};

		my $thisnode = $args{node};

		mkdir("$targetdir/system_status");
		# dump a recursive file list, ls -haRH does NOT work as it won't follow links except given on the cmdline
		system("find -L $basedir -type d | xargs ls -laH > $targetdir/system_status/filelist.txt") == 0
				or warn "can't list nmis dir: $!\n";
		
		# get md5 sums of the relevant installation files
		print "please wait while we collect file status information...\n";
		system("find -L $basedir -type f |grep -v -e /.git/ -e /database/ -e /logs/|xargs md5sum -- >$targetdir/system_status/md5sum 2>&1");
		
		# verify the relevant users and groups, dump groups and passwd (not shadow)
		system("cp","/etc/group","/etc/passwd","$targetdir/system_status/");
		system("id nmis >$targetdir/system_status/nmis_userinfo 2>&1");
		system("id apache >$targetdir/system_status/web_userinfo 2>&1");
		system("id www-data >>$targetdir/system_status/web_userinfo 2>&1");
		# dump the process table
		system("ps ax >$targetdir/system_status/processlist.txt") == 0 
				or warn  "can't list processes: $!\n";
		# dump the memory info, free
		system("cp","/proc/meminfo","$targetdir/system_status/meminfo") == 0
				or warn "can't save memory information: $!\n";
		chmod(0644,"$targetdir/system_status/meminfo"); # /proc/meminfo isn't writable
		system("free >> $targetdir/system_status/meminfo");

		system("df >> $targetdir/system_status/disk_info");
		system("mount >> $targetdir/system_status/disk_info");

		system("uname -av > $targetdir/system_status/uname");
		mkdir("$targetdir/system_status/osrelease");
		system("cp -a /etc/*release /etc/*version $targetdir/system_status/osrelease/ 2>/dev/null");

		if (!$args->{no_system_stats})
		{
			print "please wait while we gather statistics for about 15 seconds...\n";
			# dump 5 seconds of vmstat, two runs of top, 5 seconds of iostat
			# these tools aren't necessarily installed, so we ignore errors
			system("vmstat 1 5 > $targetdir/system_status/vmstat");
			system("top -b -n 2 > $targetdir/system_status/top");	
			system("iostat -kx 1 5 > $targetdir/system_status/iostat");
		}

		# copy /etc/hosts, /etc/resolv.conf, interface and route status
		system("cp","/etc/hosts","/etc/resolv.conf","/etc/nsswitch.conf","$targetdir/system_status/") == 0
				or warn "can't save dns configuration files: $!\n";
		system("/sbin/ifconfig -a > $targetdir/system_status/ifconfig") == 0
				or warn "can't save interface status: $!\n";
		system("/sbin/route -n > $targetdir/system_status/route") == 0
				or warn "can't save routing table: $!\n";

		# copy the install log if there is one
		if (-f "$basedir/install.log")
		{
				system("cp","$basedir/install.log",$targetdir) == 0
						or warn "can't copy install.log: $!\n";
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

				# log files that are larger than maxlogsize are automatically tail'd
				if (-s $lfn > $maxlogsize)
				{
					warn "logfile $lfn is too big, truncating to $maxlogsize bytes.\n";
					my $targetfile=basename($lfn);
					system("tail -c $maxlogsize $lfn > $targetdir/logs/$targetfile") == 0
							or warn "couldn't truncate $lfn!\n";
				}
				else
				{
					system("cp","$lfn","$targetdir/logs") == 0
							or warn "ATTENTION: can't copy logfile $lfn to $targetdir!\n";
				}
		}
		mkdir("$targetdir/conf",0755);
		mkdir("$targetdir/conf/scripts",0755);

		# copy all of conf/ and models/ but NOT any stray stuff beneath
		system("cp","-r","$basedir/models",$targetdir) == 0
				or warn "can't copy models to $targetdir: $!\n";
		system("cp $basedir/conf/* $targetdir/conf 2>/dev/null");
		system("cp $basedir/conf/scripts/* $targetdir/conf/scripts") == 0
				or warn "can't copy conf to $targetdir/conf/scripts: $!\n";

		# copy generic var files (=var/nmis-*)
		mkdir("$targetdir/var");
		opendir(D,"$basedir/var") or warn "can't read var dir: $!\n";
		my @generics = grep(/^nmis-/, readdir(D));
		closedir(D);
		system("cp", (map { "$basedir/var/$_" } (@generics)), 
					 "$targetdir/var") == 0 or warn "can't copy var files: $!\n";

		# if node info requested copy those files as well
		# special case: want ALL nodes
		if ($thisnode eq "*")
		{
				system("cp $basedir/var/* $targetdir/var/") == 0 
						or warn "can't copy all nodes' files: $!\n";
		}
		elsif ($thisnode)
		{
				my $lnt = loadLocalNodeTable;
				for my $nextnode (split(/\s*,\s*/,$thisnode))
				{
						if ($lnt->{$nextnode})
						{
								my $fileprefix = "$basedir/var/".lc($nextnode);
								my @files_to_copy = (-r "$fileprefix-node.json")?
										("$fileprefix-node.json", "$fileprefix-view.json") :
										("$fileprefix-node.nmis", "$fileprefix-view.nmis");
										
								system("cp", @files_to_copy, "$targetdir/var/") == 0
										or warn "can't copy node ${nextnode}'s node files: $!\n";
						}
						else
						{
								warn("ATTENTION: the requested node \"$nextnode\" isn't known to NMIS!\n");
						}
				}
		}

		return undef;
}

