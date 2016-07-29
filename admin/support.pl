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
our $VERSION = "1.4.6";
use strict;
use Data::Dumper;
use File::Basename;
use File::Temp;
use POSIX qw();
use Cwd;
use FindBin;
use lib "$FindBin::Bin/../lib";


print "Opmantek NMIS Support Tool Version $VERSION\n"; 

my $usage = "Usage: ".basename($0)." action=collect [node=nodename,nodename...]\n
action=collect: collect general support info in an archive file
 if node argument given: also collect node-specific info 
 if nodename='*' then ALL nodes' info will be collected (DATA MIGHT BE HUGE!)\n\n";

die $usage if (@ARGV == 1 && $ARGV[0] =~ /^-[h\?]/);

my %args = getArguements(@ARGV);

my $configname = $args{config} || "Config.nmis";
my $maxzip = $args{maxzipsize} || 10*1024*1024; # 10meg
my $maxlogsize = $args{maxlogsize} || 4*1024*1024; # 4 meg for individual log files
my $tail = 4000;																# last 4000 lines

my %options;										# dummy-ish, for input_yn and friends

# let's try to live without NMIS and func, for the truly desperate situations
my $globalconf = { '<nmis_base>' => Cwd::abs_path("$FindBin::RealBin/../"), 
}; # fixme log files

eval { require NMIS; NMIS->import(); require func; func->import(); };
if ($@)
{
	warn "Attention: The NMIS modules could not be loaded: '$@'\n
The support tool will fall back to assuming that your NMIS
installation is in $globalconf->{'<nmis_base>'}.\n\n";
	print STDERR "\n\nHit enter to contine:\n";
	my $x = <STDIN>;

	$args{node} = '*' if ($args{node}); # no loadLocalNodeTable(), so we can only collect them all
}
else
{
	# load the global config
	$globalconf = &loadConfTable(conf => $configname);
}

# make tempdir
my $td = File::Temp::tempdir("/tmp/nmis-support.XXXXXX", CLEANUP => 1);

if (!$@ && func->can("selftest"))
{
	# run the selftest in interactive mode - if our nmis is new enough
	print "Performing Selftest, please wait...\n";
	my ($testok, $testdetails) = func::selftest(config => $globalconf, delay_is_ok => 'true');
	if (!$testok)
	{
		print STDERR "\n\nAttention: NMIS Selftest Failed!
================================\n\nThe following tests failed:\n\n";
 
		for my $test (@$testdetails)
		{
			my ($name, $details) = @$test;
			next if !defined $details; #  the successful ones
			print STDERR "$name: $details\n";
		}
		
		print STDERR "\n\nHit enter to contine:\n";
		my $x = <STDIN>;
	}
	else
	{
		print "Selftest completed\n";
	}
}

# now ask nmis to do a dir/perms audit, and offer to fix things
my @auditresults = `$globalconf->{'<nmis_base>'}/bin/nmis.pl type=audit`;
if (@auditresults)
{
	print STDERR "\n\nAttention: NMIS File Check detected problems!
=============================================\n\nThe following issues were reported:\n\n",
			@auditresults,"\n\n";
	
	if (input_yn("OK to perform the automated repair operation now?"))
	{
		system("$globalconf->{'<nmis_base>'}/bin/nmis.pl type=config info=true");
	}
	else
	{
		print "\n\nYou can run the file and directory repair operation later,
by running \"$globalconf->{'<nmis_base>'}/bin/nmis.pl type=config info=true\" as root.
Alternatively, to fix permissions only you could\nuse \"$globalconf->{'<nmis_base>'}/admin/fixperms.pl\".\n\nPlease hit <Enter> to continue:\n";
		my $x = <STDIN>;
	}
}

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
else
{
	die "$usage\n";
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
		# these three are relevant and often outside of basedir, occasionally without symlink...
		my $vardir = $globalconf->{'<nmis_var>'};
		my $dbdir = $globalconf->{'database_root'};		
		my $logdir = $globalconf->{'<nmis_logs>'};

		my $thisnode = $args{node};

		# report the NMIS version and the support tool version, too.
		open(F, ">$targetdir/nmis_version") or die "cannot write to $targetdir/nmis_version: $!\n";
		my $nmisversion = `$basedir/bin/nmis.pl 2>/dev/null`;
		if ($nmisversion =~ /^NMIS version (\S+)$/m)
		{
			print F "NMIS Version $1\n";
		}
		else
		{
			open(G, "$basedir/lib/NMIS.pm");
			for  my $line (<G>)
			{
				if ($line =~ /^\$VERSION\s*=\s*"(.+)";\s*$/)
				{
					print F "NMIS Version $1\n";
					last;
				}
			}
			close G;
		}
		print  F "Support Tool Version $VERSION\n";
		close F;

		# dirs to check: the basedir, PLUS the database_root PLUS the nmis_var
		my $dirstocheck=$basedir;
		$dirstocheck .= " $vardir" if ($vardir !~ /^$basedir/);
		$dirstocheck .= " $dbdir" if ($dbdir !~ /^$basedir/);
		$dirstocheck .= " $logdir" if ($logdir !~ /^$basedir/);

		mkdir("$targetdir/system_status");
		# dump a recursive file list, ls -haRH does NOT work as it won't follow links except given on the cmdline
		# this needs to cover dbdir and vardir if outside
		system("find -L $dirstocheck -type d -print0| xargs -0 ls -laH > $targetdir/system_status/filelist.txt") == 0
				or warn "can't list nmis dir: $!\n";
		
		# get md5 sums of the relevant installation files
		# no need to checksum dbdir or vardir
		print "please wait while we collect file status information...\n";
		system("find -L $basedir \\( \\( -path '$basedir/.git' -o -path '$basedir/database' -o -path '$basedir/logs' -o -path '$basedir/var' \\) -prune \\) -o \\( -type f -print0 \\) |xargs -0 md5sum -- >$targetdir/system_status/md5sum 2>&1");
		
		# verify the relevant users and groups, dump groups and passwd (not shadow)
		system("cp","/etc/group","/etc/passwd","$targetdir/system_status/");
		system("id nmis >$targetdir/system_status/nmis_userinfo 2>&1");
		system("id apache >$targetdir/system_status/web_userinfo 2>&1");
		system("id www-data >>$targetdir/system_status/web_userinfo 2>&1");
		# dump the process table,
		system("ps ax >$targetdir/system_status/processlist.txt") == 0 
				or warn  "can't list processes: $!\n";
		# the lock status
		system("cp","/proc/locks","$targetdir/system_status/");

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

		# capture the cron files, root's and nmis's tabs
		mkdir("$targetdir/system_status/cron");
		system("cp -a /etc/cron* $targetdir/system_status/cron") == 0 
				or warn "can't save cron files: $!\n";
		
		system("crontab -u root -l > $targetdir/system_status/cron/crontab.root 2>/dev/null");
		system("crontab -u nmis -l > $targetdir/system_status/cron/crontab.nmis 2>/dev/null");

		# capture the apache configs
		my $apachehome = -d "/etc/apache2"? "/etc/apache2": -d "/etc/httpd"? "/etc/httpd" : undef;
		if ($apachehome)
		{
			my $apachetarget = "$targetdir/system_status/apache";
			mkdir ($apachetarget) if (!-d $apachetarget);
			# on centos/RH there are symlinks pointing to all the apache module binaries, we don't 
			# want these (so  -a or --dereference is essential)
			system("cp -a $apachehome/* $apachetarget");
			# and save a filelist for good measure
			system("ls -laHR $apachehome > $apachetarget/filelist");
		}
		
		# copy the install log if there is one
		if (-f "$basedir/install.log")
		{
				system("cp","$basedir/install.log",$targetdir) == 0
						or warn "can't copy install.log: $!\n";
		}

		# collect all defined log files
		mkdir("$targetdir/logs");
		my @logfiles = (map { $globalconf->{$_} } (grep(/_log$/, keys %$globalconf)));
		if (!@logfiles)							# if the nmis load failed, fall back to the most essential standard logs
		{
			@logfiles = map { "$globalconf->{'<nmis_logs>'}/$_" } 
			(qw(nmis.log auth.log fpingd.log event.log slave_event.log trap.log"));
		}
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
		mkdir("$targetdir/conf/nodeconf",0755);

		# copy all of conf/ and models/ but NOT any stray stuff beneath
		system("cp","-r","$basedir/models",$targetdir) == 0
				or warn "can't copy models to $targetdir: $!\n";
		system("cp $basedir/conf/* $targetdir/conf 2>/dev/null");
		for my $oksubdir (qw(scripts nodeconf))
		{
			system("cp $basedir/conf/$oksubdir/* $targetdir/conf/$oksubdir") == 0
					or warn "can't copy conf to $targetdir/conf/$oksubdir: $!\n";
		}
		
		# copy generic var files (=var/nmis-*)
		mkdir("$targetdir/var");
		opendir(D,"$vardir") or warn "can't read var dir $vardir: $!\n";
		my @generics = grep(/^nmis[-_]/, readdir(D));
		closedir(D);
		system("cp", "-r", (map { "$vardir/$_" } (@generics)), 
					 "$targetdir/var") == 0 or warn "can't copy var files: $!\n";

		# if node info requested copy those files as well
		# special case: want ALL nodes
		if ($thisnode eq "*")
		{
				system("cp $vardir/* $targetdir/var/") == 0 
						or warn "can't copy all nodes' files: $!\n";
		}
		elsif ($thisnode)
		{
			my $lnt = &loadLocalNodeTable;
			for my $nextnode (split(/\s*,\s*/,$thisnode))
			{
				if ($lnt->{$nextnode})
				{
					my $fileprefix = "$vardir/".lc($nextnode);
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

		return ($input =~ /^\s*(y|yes)?\s*$/i)? 1:0;
	}
}

# so that we don't need to "use func"
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
