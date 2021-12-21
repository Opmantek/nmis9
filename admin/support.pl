#!/usr/bin/perl
#
#  Copyright 1999-2018 Opmantek Limited (www.opmantek.com)
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
our $VERSION = "2.0.0b";
use strict;
use Data::Dumper;
use File::Basename;
use File::Temp;
use File::Copy qw(cp);
use File::Path;
use POSIX qw();
use Cwd;
use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Util;

print "Opmantek NMIS Support Tool Version $VERSION\n";

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

die "The Support Tool must be run with root privileges, terminating now.\n"
		if ($> != 0 and $cmdline->{gui} != 1);

my $usage = "Usage: ".basename($0)." action=collect [public=t/f] [node=nodeA] [node=nodeB...] [bot=1] [report_dir=...]\n
action=collect: collect general support info in an archive file
 if node argument given: also collect node-specific info
 if node='*' then ALL nodes' info will be collected (DATA MIGHT BE HUGE!)
 args:
  maxzipsize
  maxlogsize
  maxopstatus
  maxoperrors
action=run-bot [support_file=] [report_dir=...]
 run bot needs a suuport_file in zip format or a directory
  with uncompressed support zip.
  report_dir is optional, by default will be /tmp/support_report.html
public: if set to false, then credentials, community, passwords
 and other sensitive data is removed and not included in the archive.
bot: Will run the bot the generate a nice report
report_dir: Move the report outside support support zip 
\n\n";

die $usage if (@ARGV == 1 && $ARGV[0] =~ /^-(h|help|\?)/i);

#die $usage if ($cmdline->{action} ne "collect" or $cmdline->{action} ne "run-bot");

my $maxzip = $cmdline->{maxzipsize} || 10*1024*1024; # 10meg
my $maxlogsize = $cmdline->{maxlogsize} || 4*1024*1024; # 4 meg for individual log files
my $tail = 1000;		# last 1000 lines
my $maxopstatus = $cmdline->{maxopstatus} || 500;	# last 500 operational statuses
my $maxoperrors = $cmdline->{maxoperrors} || 100;
my $bot = $cmdline->{bot} || 1; # Run by default
my $report_dir = $cmdline->{report_dir};

my %options;										# dummy-ish, for input_yn and friends

# let's try to live without NMIS modules
my $globalconf = &NMISNG::Util::loadConfTable()
		// { '<nmis_base>' => Cwd::abs_path("$FindBin::RealBin/../"), };
# make tempdir for collecting the goods
my $td = File::Temp::tempdir("/tmp/nmis-support.XXXXXX", CLEANUP => 1);
my $timelabel = POSIX::strftime("%Y-%m-%d-%H%M",localtime);
my $reldir = "nmis-collect.$timelabel";
my $targetdir = "$td/$reldir";
mkdir($targetdir);
my $bot_data;
my ($error, $zfn);

# can we instantiate an nmisng object?
my $nmisng = eval { require NMISNG; require Compat::NMIS; Compat::NMIS::new_nmisng() };
if ($@ or ref($nmisng) ne "NMISNG")
{
	warn "Attention: The NMIS modules could not be loaded or no NMISNG object could be instantiated: '$@'\nThe support tool will not be able to run an NMIS selftest, or dump node-specific information.\n";
	print STDERR "\n\nHit enter to continue:\n";
	my $x = <STDIN>;
	undef $nmisng;
}
	
if ($cmdline->{action} eq "collect") {
	
	# selftest is possible
	if (ref($nmisng) eq "NMISNG"  && NMISNG::Util->can("selftest") &&  !$cmdline->{no_selftest})
	{
		# run the selftest in interactive mode
		print "Performing Selftest, please wait...\n";
		my ($testok, $testdetails) = NMISNG::Util::selftest(nmisng => $nmisng,
																												delay_is_ok => 'true');
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
	
			print STDERR "\n\nHit enter to continue:\n";
			my $x = <STDIN>;
		}
		else
		{
			print "Selftest completed successfully.\n";
		}
	}
	
	# collect evidence
	print "collecting support evidence...\n";
	
	my $status = collect_evidence($targetdir, $cmdline);
	die "failed to collect evidence: $status\n" if ($status);
	
	print "\nEvidence collection complete, zipping things up...\n";
	
	if ($bot) {
		# Collect data from unziped zip
		collect_bot_data(dir => $targetdir);
		run_bot(zip => 1);
	}
	
	($error, $zfn) = makearchive("/tmp/nmis-support-$timelabel",
																	$td, $reldir);
	die "Failed to create archive file: $error\n" if ($error);
	
	# zip mustn't become too large, hence we possibly tail/truncate some or all log files
	opendir(D,"$targetdir/logs")
			or warn "can't read $targetdir/logs dir: $!\n";
	my @shrinkables = map { "$targetdir/logs/$_" } (grep(/\.log$/, readdir(D)));
	closedir(D);
	
	# test zip, shrink logfiles, repeat until small enough or out of shrinkables
	while (-s $zfn > $maxzip)
	{
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
	
		my ($error, $zfn) = makearchive("/tmp/nmis-support-$timelabel",
																		$td, $reldir);
		die "Failed to create archive file: $error\n" if ($error);
	}
	
	print "\nAll done.\n\nCollected system information is in $zfn
	Please include this zip file when you contact
	the NMIS Community or the Opmantek Team.\n\n";
	
	# remove tempdir (done automatically on exit)
	exit 0;
} elsif ($cmdline->{action} eq "run-bot") {
	
	if ($cmdline->{support_file}) {
		my $dir = $cmdline->{support_file};
		
		# Collect data from unziped zip
		collect_bot_data(dir => $dir);
		
		# Write data into /tmp/report.html
		run_bot(dir => $cmdline->{report_dir});
	} else {
		die $usage;
	}
	exit 0;
} else {
	die $usage;
}

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
# args: node, no_system_stats, public
# if no_system_stats is set then the time-consuming top, iostat etc are skipped

#
# returns nothing if ok, error message otherwise
sub collect_evidence
{
	my ($targetdir,$args) = @_;

	# default is public=true, include config as-is
	my $nosensitive = defined($args->{public}) && $args->{public} =~ /^(false|f|0|off)$/i;

	my $basedir = $globalconf->{'<nmis_base>'};
	# these three are relevant and often outside of basedir, occasionally without symlink...
	my $vardir = $globalconf->{'<nmis_var>'};
	my $dbdir = $globalconf->{'database_root'};
	my $logdir = $globalconf->{'<nmis_logs>'};

	# report the NMIS version and the support tool version, too.
	open(F, ">$targetdir/nmis_version") or die "cannot write to $targetdir/nmis_version: $!\n";
	open(G, "$basedir/lib/NMISNG.pm");
	for my $line (<G>)
	{
		if ($line =~ /^\s*our\s+\$VERSION\s*=\s*"(.+)";\s*$/)
		{
			print F "NMIS Version $1\n";
			# bot
			$bot_data->{nmis_version} = $1;
			last;
		}
	}
	close G;
	print  F "Support Tool Version $VERSION\n";
	close F;
	
	# dirs to check in terms of md5sum: the basedir, PLUS the database_root PLUS the nmis_var
	my $dirstocheck=$basedir;
	$dirstocheck .= " $vardir" if ($vardir !~ /^$basedir/);
	$dirstocheck .= " $dbdir" if ($dbdir !~ /^$basedir/);
	$dirstocheck .= " $logdir" if ($logdir !~ /^$basedir/);

	File::Path::make_path(
		"$targetdir/system_status/osrelease",
		"$targetdir/system_status/cron",
		"$targetdir/system_status/init",
		"$targetdir/system_status/apache",
		"$targetdir/logs",
		"$targetdir/conf/scripts", "$targetdir/conf/plugins", "$targetdir/conf/conf.d",
		"$targetdir/models-custom",
		"$targetdir/models-default",
		"$targetdir/var/nmis_system/model_cache",
		"$targetdir/var/system_performance",
		"$targetdir/node_dumps",
		"$targetdir/db_dumps",
		"$targetdir/system_status/cpanm",
		"$targetdir/img", 
		{ chmod => 0755 });

	# Get polling summary
	system("$basedir/admin/polling_summary9.pl >> $targetdir/system_status/polling_summary.txt");

	# dump a recursive file list, ls -haRH does NOT work as it won't follow links except given on the cmdline
	# this needs to cover dbdir and vardir if outside
	system("find -L $dirstocheck -type d -print0| xargs -0 ls -laH > $targetdir/system_status/filelist.txt") == 0
			or warn "can't list nmis dir: $!\n";
	# let's also get the cumulative directory sizes for an easier overview
	system("find -L $dirstocheck -type d -print0| xargs -0 -n 1 du -sk > $targetdir/system_status/dir_info") == 0
			or warn "can't collect nmis dir sizes: $!\n";

	# get md5 sums of the relevant installation files
	# no need to checksum dbdir or vardir
	print "please wait while we collect file status information...\n";
	system("find -L $basedir \\( \\( -path '$basedir/.git' -o -path '$basedir/database' -o -path '$basedir/logs' -o -path '$basedir/var' \\) -prune \\) -o \\( -type f -print0 \\) |xargs -0 md5sum -- >$targetdir/system_status/md5sum 2>&1");

	# verify the relevant users and groups, dump groups and passwd (not shadow)
	cp("/etc/group","$targetdir/system_status/");
	cp("/etc/passwd","$targetdir/system_status/");
	system("id nmis >$targetdir/system_status/nmis_userinfo 2>&1");
	system("id apache >$targetdir/system_status/web_userinfo 2>&1");
	system("id www-data >>$targetdir/system_status/web_userinfo 2>&1");
	# dump the process table,
	system("ps ax >$targetdir/system_status/processlist.txt") == 0
			or warn  "can't list processes: $!\n";
	system("$basedir/bin/nmis-cli act=status > $targetdir/system_status/nmis_processes.txt 2>&1");
	# the lock status
	cp("/proc/locks","$targetdir/system_status/");
	# the cpuinfo
	cp("/proc/cpuinfo","$targetdir/system_status/");

	# dump the memory info, free
	cp("/proc/meminfo","$targetdir/system_status/meminfo");
	chmod(0644,"$targetdir/system_status/meminfo"); # /proc/meminfo isn't writable
	system("free >> $targetdir/system_status/meminfo");

	system("df >> $targetdir/system_status/disk_info");
	system("mount >> $targetdir/system_status/disk_info");
		
	system("uname -av > $targetdir/system_status/uname");

	for my $x (glob('/etc/*release'),glob('/etc/*version'))
	{
		cp($x, "$targetdir/system_status/osrelease/");
	}

	if (!$args->{no_system_stats})
	{
		print "please wait while we gather statistics for about 15 seconds...\n";
		# dump 5 seconds of vmstat, two runs of top, 5 seconds of iostat
		# these tools aren't necessarily installed, so we ignore errors
		system("vmstat 1 5 > $targetdir/system_status/vmstat");
		system("top -b -n 2 > $targetdir/system_status/top");
		system("iostat -kx 1 5 > $targetdir/system_status/iostat");
	}

	system("date > $targetdir/system_status/date");

	# copy /etc/hosts, /etc/resolv.conf, interface and route status
	map { cp($_,"$targetdir/system_status/"); }("/etc/hosts","/etc/resolv.conf","/etc/nsswitch.conf");
	system("/sbin/ifconfig -a > $targetdir/system_status/ifconfig") == 0
			or warn "can't save interface status: $!\n";
	system("/sbin/route -n > $targetdir/system_status/route") == 0
			or warn "can't save routing table: $!\n";

	# capture the cron files, root's and nmis's tabs
	system("cp -a /etc/cron* $targetdir/system_status/cron") == 0 # subdirs
			or warn "can't save cron files: $!\n";

	system("crontab -u root -l > $targetdir/system_status/cron/crontab.root 2>/dev/null");
	system("crontab -u nmis -l > $targetdir/system_status/cron/crontab.nmis 2>/dev/null");

	# capture the nmisd init script info
	cp("/etc/init.d/nmis9d", "$targetdir/system_status/init");
	system("find -L /etc/rc* -name \"*nmis9d\" -ls > $targetdir/system_status/init/nmisd_init_links");
	# capture the nmisd service info
	if (-f "/etc/systemd/system/nmis9d.service")
	{
		cp("/etc/systemd/system/nmis9d.service", "$targetdir/system_status/init");
	}

	# capture the cpanm build logs
	if (-d "/root/.cpanm/work/")
	{
		for my $x (glob('/root/.cpanm/work/*/build.log'))
		{
			my $y = $x;
			$y =~ s![\\/]!_!g;
			cp($x, "$targetdir/system_status/cpanm/$y");
		}
	}

	# capture the apache configs
	my $apachehome = -d "/etc/apache2"? "/etc/apache2": -d "/etc/httpd"? "/etc/httpd" : undef;
	if ($apachehome)
	{
		my $apachetarget="$targetdir/system_status/apache/";
		# on centos/RH there are symlinks pointing to all the apache module binaries, we don't
		# want these (so  -a or --dereference is essential)
		system("cp -a $apachehome/* $apachetarget"); # subdirs
		# and save a filelist for good measure
		system("ls -laHR $apachehome > $apachetarget/filelist");
	}

	# copy the install log if there is one
	cp("$basedir/install.log",$targetdir) if (-f "$basedir/install.log");
	# collect all log files in nmis
	my @logfiles = glob("$logdir/*.log");
	for my $aperrlog ("/var/log/httpd/error_log", "/var/log/apache/error.log", "/var/log/apache2/error.log")
	{
		push @logfiles, $aperrlog if (-f $aperrlog);
	}
	push @logfiles, "/var/log/mongodb/mongod.log" if (-f "/var/log/mongodb/mongod.log");
	for my $lfn (@logfiles)
	{
		next if (!-f $lfn);

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
			cp("$lfn","$targetdir/logs");
		}
	}

	# copy all of conf/ and models-custom/ but NOT any stray stuff beneath
	for my $x (glob("$basedir/models-custom/*"))
	{
		cp($x, "$targetdir/models-custom/");
	}
	for my $x (glob("$basedir/models-default/*"))
	{
		cp($x, "$targetdir/models-default/");
	}
	for my $x (glob("$basedir/conf/*"))
	{
		# skip copying Nodes.nmis
		next if($x =~ m/\/conf\/Nodes.nmis/);
		cp($x, "$targetdir/conf/");
	}

	for my $x (glob("$basedir/var/system_performance/*"))
	{
		cp($x, "$targetdir/var/system_performance/");
	}
	
	for my $oksubdir (qw(scripts plugins))
	{
		next if (! -d "$basedir/conf/$oksubdir"); # those dirs may or may not exist
		map { cp($_, "$targetdir/conf/$oksubdir/"); } (glob("$basedir/conf/$oksubdir/*"));
	}
	# External configuration files
	system("cp -r $basedir/conf/conf.d/* $targetdir/conf/conf.d 2>/dev/null"); 

	# copy generic var files (=var/nmis-*, should be mostly nmis-fping.
	map { cp($_, "$targetdir/var/"); } (glob("$vardir/nmis[_-]*.*"));
	# also copy all of nmis_system
	system("cp","-a", "$vardir/nmis_system", "$targetdir/var/");

	# capture relevant mongo status data, if the mongo shell client is a/v,
	# and if a mongodb is configured and reachable
	# what's the mongo access configuration?
	my @mongoargs = ("--quiet", 	# no heading, just json output please!
									 "--username", $globalconf->{db_username},
									 "--password", $globalconf->{db_password},
									 "--host", $globalconf->{db_server},
									 "--port", $globalconf->{db_port});
	my $status = system("type mongo >/dev/null 2>&1");
	if (POSIX::WIFEXITED($status) && !POSIX::WEXITSTATUS($status))
	{
		# get the general mongo status
		open("F", "|mongo ".join(" ",@mongoargs)
				 ." admin >$targetdir/system_status/mongo_status 2>&1")
				or warn "can't run mongo: $!\n";
		F->autoflush(1);

		# fire the most essential commands blindly, don't want the complexity of ipc::run here
		for my $cmd ("show databases", "db.hostInfo()", "db.serverStatus()",
								 "show users", "show roles")
		{
			print F "print('--- $cmd ---')\n$cmd\n";
		}
		my $dbname= $globalconf->{db_name};
		print F "print('--- changing to db $dbname ---')\nuse $dbname\n";
		for my $cmd ("db.stats()", "db.printCollectionStats()",
							 "db.getCollectionInfos()", "show users", "show roles")
		{
			print F "print('--- $cmd on $dbname ---')\n$cmd\n";
		}
		# finding and showing index details is a bit more work

		print F 'var known = db.getCollectionNames(); for(var i=0, len=known.length; i < len; i++) { print("--- examining collection "+known[i]+" ---"); var r = db.getCollection(known[i]).stats(); print(tojson(r)); }'."\n";

		print F "exit\n";
		close(F);

		# and export: queue, nodes, their catchall inventories,
		# opstatus most recent N entries and most recent M errors
		# .toArray() would be nice BUT eats memory and cpu like crazy...
		for (
			[ 'db.getCollection("queue").find().forEach(printjson)', 'queue.json'],
			[ 'db.getCollection("nodes").find().forEach(printjson)','nodes.json'],
			[ 'db.getCollection("inventory").find({concept:"catchall"}).forEach(printjson)', 'catchall.json'],
			[ qq|db.getCollection("opstatus").find().sort({time:-1}).limit($maxopstatus).forEach(printjson)|,
				'opstatus_recent.json'],
			[
			 qq|db.getCollection("opstatus").find({status:{\$ne:"ok"}}).sort({time:-1}).limit($maxoperrors).toArray()|,
			 'opstatus_recent_errors.json'],
				)
		{
			my ($query, $outputfile) = @$_;
			
			open(F,"-|", "mongo",
					 @mongoargs, $dbname, "--eval", $query);
			my @exportdata = <F>;
			close(F);
			# printjson does NOT produce arrays...
			# ... so we'll have to help
			push @exportdata, ']'; unshift @exportdata, '[';
			for my $ln (0..$#exportdata)
			{
				$exportdata[$ln] .= ","
						if ($exportdata[$ln] eq "}\n" && $exportdata[$ln+1] eq "{\n");
			}
			
			translate_extended_json(\@exportdata);

			open(F, ">$targetdir/db_dumps/$outputfile");
			print F @exportdata;
			close(F);
		}
	}
	else
	{
		warn("No \"mongo\" client available!
The support tool won't be able to collect database status information!\n");
		print STDERR "\n\nHit enter to continue:\n";
		my $x = <STDIN>;
		$bot_data->{count} = "No \"mongo\" client available!";
		# can't export directly, so try the admin tool
		system("$basedir/admin/node_admin.pl","act=export","file=$targetdir/db_dumps/nodes.json");
	}

	# if node(s) requested, get a dump of each nodes' data if possible
	if (ref($nmisng) eq "NMISNG")
	{
		# special case: want ALL nodes
		my %dumpthese;
		if (defined $args->{node}  && $args->{node} eq '*')
		{
			%dumpthese = ( uuid => $nmisng->get_node_uuids );
		}
		elsif (ref($args->{node}) eq "ARRAY")
		{
			%dumpthese = ( name => $args->{node} );
		}
		elsif ($args->{node})
		{
			%dumpthese = (name => $args->{node});
		}

		while (my ($selector, $values) = each %dumpthese)
		{
			my $md = $nmisng->get_nodes_model($selector => $values);
			if ($md->error or !$md->count)
			{
				warn("Cannot collect data for node $selector=$values: ".($md->error || "does not exist"));
				next;
			}
			for my $found (@{$md->data})
			{
				print STDERR "dumping node data for node $found->{name} ($found->{uuid})...\n";
				my $uuid = $found->{uuid};
				my $nodedumpf = "$targetdir/node_dumps/$uuid.zip";
				my $res = $nmisng->dump_node(uuid => $uuid, target => $nodedumpf,
																		 options => { historic_events => 0,
																									opstatus_limit => $maxopstatus});

				warn "Failed to dump node data for $uuid: $res->{error}\n" if (!$res->{success});
				# Now, perform an update and a collect
				my $logfn = "$targetdir/node_dumps/update.log";
				my $thisjoblog = NMISNG::Log->new(level => NMISNG::Log::parse_debug_level(debug => 7),
																						path => $logfn);
				$nmisng->log($thisjoblog);
				my $nodeobj = $nmisng->node(uuid => $found->{uuid});
				$nodeobj->update();
				
				my $logfn = "$targetdir/node_dumps/collect.log";
				my $thisjoblog = NMISNG::Log->new(level => NMISNG::Log::parse_debug_level(debug => 7),
																						path => $logfn);
				$nmisng->log($thisjoblog);
				my $nodeobj = $nmisng->node(uuid => $found->{uuid});
				$nodeobj->collect();
			}
		}
	}

	# for conf, clean out sensitive bits if requested
	# same for general node export - NOT available for the full dumps!
	if ($nosensitive)
	{
	    print STDERR "removing sensitive data from ";
		open(F, "$targetdir/conf/Config.nmis") or die "can't read config file: $!\n";
		my @lines = <F>;
		close (F);
		for my $tbc (@lines)
		{
			$tbc =~ s/(auth_radius_secret|auth_web_key|default_(?:auth|priv)(?:password|key)|(?:mail|db)_password|db_rootpassword|auth_ms_ldap_dn_psw|auth_tacacs_secret|(?:server|slave)_community)\b(['"]\s*=>)(.*)$/$1$2'_removed_',/g;
		}
		open(F, ">$targetdir/conf/Config.nmis") or die "can't write config file: $!\n";
		print F @lines;
		print STDERR "Config.nmis - complete ";
		close F;

		if (open(F, "$targetdir/db_dumps/nodes.json"))
		{
			@lines = <F>;
			for my $tbc (@lines)
			{
				$tbc =~ s/((?:auth|priv|wmi)(?:password|key)|community|wmiusername|username)\b(['"]\s*:\s*)(.*)/$1$2'_removed_',/g;
			}
			open(F, ">$targetdir/node_dumps/nodes.json") or die "can't write node export file: $!\n";
			print F @lines;
			close F;
			#delete $targetdir/db_dumps/nodes.json
			unlink("$targetdir/db_dumps/nodes.json") or die "can't delete the file:$!\n";
			print STDERR "nodes.json - complete\n";
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

# create zip or tarball
# args: targetfile (w/o extension), start dir, source dir (relative to startdir)
# returns: (undef, final full file path) or (errormessage)
sub makearchive
{
	my ($targetfile, $startdir, $sourcedir) = @_;

	my $whattool = "tar";
	my $status = system("zip --version >/dev/null 2>&1");
	if (POSIX::WIFEXITED($status) && !POSIX::WEXITSTATUS($status))
	{
		$whattool="zip";
	}

	my $archivefn = $targetfile.($whattool eq "tar"? ".tgz":".zip");

	my $origdir = getcwd;
	chdir($startdir) or return "failed to chdir to $startdir: $!";

	my @cmd = (($whattool eq "zip")? ("zip","-q","-r") : ("tar","-czf"), $archivefn, $sourcedir);
	$status = system(@cmd);
	chdir($origdir);

	return "failed to create support zip file $zfn: $!\n" if (POSIX::WEXITSTATUS($status));

	return (undef, $archivefn);
}

# mongo 'shell mode' extended json, which isn't digestible to json_xs etc.
# this small helper takes an array of lines, and replaces the shell-mode data
# with the strict equivalents - as far as we're using those constructs!
# args: array ref,
# return: nothing, but modifies the lines
sub translate_extended_json
{
	my ($lines) = @_;

	for my $line (@$lines)
	{
		$line =~  s/BinData\s*\(\s*(.+?)\s*,\s*([^\)]+)\s*\)/{"\$type":$1, "\$binary":"$2"}/g;
		$line =~ s/(?:new\s*Date|ISODate)\s*\(\s*"?([^")]+)"?\s*\)/{"\$date":"$1"}/g;
		$line =~ s/ObjectId\s*\(\s*"([a-fA-F0-9]+)\s*"\s*\)/{"\$oid":"$1"}/g;
		$line =~ s/NumberLong\s*\(\s*"(\d+)\s*"\s*\)/{"\$numberLong":"$1"}/g;
	}
}

# This bot will collect all the information needed
# into bot_data hash
sub collect_bot_data
{
	my %args = @_;
	my $dir = $args{dir};
	my $sourcedir;
	
	# Open zip
	if ($dir =~ /\.zip/) {
			# Try to uncompress
			$sourcedir = "/tmp/tmp-nmis-support-$timelabel";
			my @cmd = ("unzip", $dir, "-d", $sourcedir);
			my $status = system(@cmd);
			
			opendir ( DIR, $sourcedir ) || die "Error in opening dir $sourcedir\n";
			while( my $filename = readdir(DIR)) {
			   if ($filename =~ /nmis-collect/) {
				$dir = $sourcedir . "/$filename";
				last;
			   }
			}
			closedir(DIR);
	}
	
	my $basedir = $globalconf->{'<nmis_base>'};
		
	# NMIS Version
	open(G, "$basedir/lib/NMISNG.pm");
	for my $line (<G>)
	{
		if ($line =~ /^\s*our\s+\$VERSION\s*=\s*"(.+)";\s*$/)
		{
			# bot
			$bot_data->{nmis_version} = $1;
			last;
		}
	}
	close G;
	
	# Polling summary
	open(my $fh, "<", "$dir/system_status/polling_summary.txt")
		or print "Can't open < $dir/system_status/polling_summary.txt: $! \n";
	
	while (my $line = <$fh>) {
		if ($line =~ /totalNodes/) {
			$bot_data->{summary} = $bot_data->{summary} . "\n" . $line;
		} elsif ($line =~ /pingDown/) {
			$bot_data->{summary} = $bot_data->{summary} . "\n" . $line;
		}
	}
	
	# Disk 
	open(my $fh, "<", "$dir/system_status/disk_info")
		or print "Can't open < system_status: $! \n";
	
	while (my $line = <$fh>) {
		# udev                     3045820         0   3045820   0% /dev
		if ( $line =~ /([^\s]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%)\s+(.+\/*)/ ) {
			$bot_data->{disk}->{$1}->{used} = $3;
			$bot_data->{disk}->{$1}->{available} = $4;
			$bot_data->{disk}->{$1}->{use} = $5;
		}
	}
	
	# OS 
	for my $x (glob("$dir/system_status/osrelease/*"))
	{
		open(my $fh, "<", "$x")
				or die "Can't open < osrelease: $!";

		while (my $line = <$fh>) {
			if ($line =~ /PRETTY_NAME/) {
				$line =~ s/PRETTY_NAME=//g;
				$bot_data->{os_release} = $line;
				last;
			}
		}
	}
	
	# top
	open(my $fh, "<", "$dir/system_status/top")
			or die "Can't open < top data: $!";

	while (my $line = <$fh>) {
		if ( $line =~ /%Cpu\(s\):\s+(\d+\.\d+) us,\s+(\d+\.\d+) sy,\s+(\d+\.\d+) ni,\s*(\d+\.\d+) id,\s+(\d+\.\d+) wa,\s+(\d+\.\d+) hi,\s+(\d+\.\d+) si,\s+(\d+\.\d+) st/ ) {
			$bot_data->{stats}->{cpuUser} = $1;
			$bot_data->{stats}->{cpuSys} = $2;
			$bot_data->{stats}->{cpuNice} = $3;
			$bot_data->{stats}->{cpuIdle} = $4;
			$bot_data->{stats}->{cpuWaitIO} = $5;
			$bot_data->{stats}->{cpuHi} = $6;
			$bot_data->{stats}->{cpuSi} = $7;
			$bot_data->{stats}->{cpuSt} = $8;
		}
		elsif ( $line =~ /[MK]iB Mem :\s+(\d+\.?\d*) total,\s+(\d+\.?\d*) free,\s+(\d+\.?\d*) used,\s+(\d+\.?\d*) buff\/cache/ ) {
			$bot_data->{stats}->{memTotal} = $1;
			$bot_data->{stats}->{memFree} = $2;
			$bot_data->{stats}->{memUsed} = $3;
			$bot_data->{stats}->{membuff} = $4;
		}
		elsif ( $line =~ /[MK]iB Swap:\s+(\d+\.?\d*) total,\s+(\d+\.?\d*) free,\s+(\d+\.?\d*) used.\s+(\d+\.?\d*) avail Mem/ ) {
			$bot_data->{stats}->{swaptotal} = $1;
			$bot_data->{stats}->{swapfree} = $2;
			$bot_data->{stats}->{swapused} = $3;
			$bot_data->{stats}->{memAvail} = $4;
		}
	}
	# Custom models
	my $custommodels = 0;
	for my $x (glob("$basedir/models-custom/*"))
	{
		$custommodels++;
	}
	$bot_data->{custom_models} = $custommodels;
	
	# Configuration
	my $C = NMISNG::Util::loadConfTable();
	my $configs = [qw(cluster_id server_name nmisd_scheduler_cycle nmisd_max_workers nmisd_worker_cycle nmisd_worker_max_cycles node_name_rule)];
	foreach my $c (@$configs)
	{
		$bot_data->{config}->{$c} = "$C->{$c}";
	}
	
	my $dbname= $globalconf->{db_name};
	# Data count
	print "\n Trying to get data from mongo... \n";
	for (
			[ 'db.queue.find().count()', 'queue'],
			[ 'db.nodes.find().count()','nodes'],
			[ 'db.inventory.find().count()', 'inventory'],
			[ 'db.opstatus.find().count()', 'opstatus'],
			[ 'db.events.find().count()', 'events'],
				)
	{
		my ($query, $data) = @$_;
		my @mongoargs = ("--quiet", 	# no heading, just json output please!
								 "--username", $globalconf->{db_username},
								 "--password", $globalconf->{db_password},
								 "--host", $globalconf->{db_server},
								 "--port", $globalconf->{db_port});
		my $run = "mongo @mongoargs $dbname --eval \"$query\"";

		$bot_data->{count}->{$data} = `$run`;
	}
	
	# Selftest
	my $selftest = NMISNG::Util::readFiletoHash(file=>$globalconf->{'<nmis_base>'}."/var/nmis_system/selftest.json", json =>1);
	$bot_data->{selftest} = $selftest;
	
	# Grep errors `command`
	my $log = $globalconf->{'<nmis_base>'}."/logs/nmis.log";
	my $output = `egrep error $log | tail -20`;
	$bot_data->{nmis_log} = $output;
	
	# Remove temp folder
	if ($sourcedir) {
		my @cmd = ("rm", "-r", $sourcedir);
		my $status = system(@cmd);
	}
	
	# runtimegrpah
	my $res = get_graph(type => "nmis");
	if ($res->{success}) {
		$bot_data->{runtime_graph} = "img/nmis.png";
	}
	
	# Try to find local monitoring node
	my $nodesmodel = $nmisng->get_nodes_model(filter => {"configuration.host" => "127.0.0.1",
														 "cluster_id" => $C->{cluster_id},
														 "activated.NMIS" => 1,
														 "configuration.collect" => 1});
	my $allnodes = $nodesmodel->data;
	if (scalar @$allnodes == 0) {
		$nodesmodel = $nmisng->get_nodes_model(filter => {"configuration.host" => "localhost",
														  "cluster_id" => $C->{cluster_id},
														  "activated.NMIS" => 1,
														 "configuration.collect" => 1});
		$allnodes = $nodesmodel->data;
	}
	if (scalar @$allnodes > 0) {
		my $justone = @$allnodes[0];
		# Now get graphs for this node
		my $res = get_graph(type => "ss-cpu", node => $justone->{name});
		if ($res->{success}) {
			$bot_data->{cpu_graph} = "img/ss-cpu.png";
		}
	}
	
	# Duplicate noes
	print "\n Trying to get duplicate nodes... \n";
	$bot_data->{duplicates} = check_duplicates();
	return 1;
}

# This bot will write all the information collected
# into different files: bot_report.json and bot_report.html (Formatted)
sub run_bot
{
	my %args = @_;
	my $zip = $args{zip};
	
	print "\n Running support bot... \n";
	print "\n ======================================= \n";
	print "\n ================  ERRORS ============== \n";
	print "\n ======================================= \n";
	
	my $outputfile;
	my $basedir = $globalconf->{'<nmis_base>'};
	my $report_name = "support_report";
	
	if ($zip) {
		if ( open(F, ">/$targetdir/$report_name.json"))
		{
			NMISNG::Util::writeHashtoFile(file => "/$targetdir/$report_name.json", data => $bot_data, json => 1);
			close F;
		}
		use File::Slurp;
		my $template = read_file($basedir.'/admin/support_template.html');
		my $content = "";
		$content = create_index(content => $bot_data) . show_content(content => $bot_data, where => $content, show_key => 1);
	
		$template =~ s/CONTENT/$content/;
		write_file("/$targetdir/$report_name.html", $template);
		if ($report_dir) {
			print "Creating report into $report_dir/$report_name.html \n";
			system("cp", "/$targetdir/$report_name.html", $report_dir );
		}
	} else {
		my $report_dir = $args{dir} // "/tmp";
		print "Creating report into $report_dir/$report_name.html \n";
		use File::Slurp;
		my $template = read_file($basedir.'/admin/support_template.html');
		my $content = "";
		$content = create_index(content => $bot_data) . show_content(content => $bot_data, where => $content, show_key => 1);
	
		$template =~ s/CONTENT/$content/;
		write_file("$report_dir/$report_name.html", $template);
	}
	print "\n ================= DONE ================ \n";

}

# Print formatted output in html report
sub show_content
{
	my %args = @_;
	my $content = $args{content};
	my $title = $args{title};
	my $where = $args{where};
	my $show_key = $args{show_key};
	
	$where = $where. "<h2>$title</h2><hr>" if ($title);
	if (ref($content) eq "HASH") {
		foreach my $key (keys %$content) {
			if ($key eq "count" or $key eq "stats") {
				$where = $where . "<h2 id='$key'>$key</h2><hr>".print_table(content => $content->{$key});
			} elsif ($key eq "disk") {
				$where = $where . "<h2 id='$key'>$key</h2><hr>".print_disk(content => $content->{$key});
			} elsif ($key eq "config") {
				$where = $where . "<h2 id='$key'>$key</h2><hr>".print_config(content => $content->{$key});
			} elsif ($key eq "nmis_log") {
				$where = $where . "<h2 id='$key'>$key</h2><hr>".print_collapse(key => $key, content => $content->{$key});
			}elsif ($key =~ /graph/) {
				$where = $where . "<h2 id='$key'>$key</h2><hr><img id='$key' src='".$content->{$key}."' alt=''>";
			}elsif (ref($content->{$key}) eq "HASH") {
				if ($show_key) {
					$where = $where . "<h2 id='$key'>$key</h2><hr>".show_content(content => $content->{$key}, where => "");
				} else {
					$where = $where . show_content(content => $content->{$key}, where => "");
				}
			} elsif (ref($content->{$key}) eq "ARRAY") {
				foreach my $element (@{$content->{$key}}) {
					if (ref($element) eq "HASH") {
						$where = $where . show_content(content => $element, where => "");
					} if (ref($element) eq "ARRAY") {
						if (length(@$element[1]) > 20) {
							my $content = substr @$element[1], 0, 20;
							$where = $where . "<b>" . @$element[0] . "</b><br>".print_collapse(content => @$element[1]);
						} else {
							$where = $where . "<b>" . @$element[0] . "</b> " . @$element[1] . "<br>";
						}
						
					} else {
						$where = $where . $element;
					}
				}
				if ($show_key) {
					$where = $where . "<h2 id='$key'>$key</h2><hr>".show_content(content => $content->{$key}, where => "");
				} else {
					$where = $where . show_content(content => $content->{$key}, where => "");
				}
			} else {
				if ($show_key) {
					$where = $where . "<h2 id='$key'>$key</h2><hr><p> ".$content->{$key}."</p>";
				} else {
					$where = $where . "<b>$key</b><p> ".$content->{$key}."</p>";
				}
			}
		}

	} else {
		$where = $where . "<p>".$content."</p>";
	}
	
	return $where;
}

# Create index for bot report
sub create_index
{
	my %args = @_;
	my $content = $args{content};
	
	my $toRet = "<ul>";
	
	foreach my $key (keys %$content) {
		$toRet = $toRet . "<li><a href='#$key'>". $key . "</a></li>";
	}
	my $toRet = $toRet."</ul>";
	
	return $toRet;
}

# Print disk information for html report
sub print_disk
{
	my %args = @_;
	my $content = $args{content};
	my $toRet = "<table class='table'><thead><tr>";
	my $headers = [qw(Filesystem Available Used Use)];
	foreach my $c (@$headers)
	{
		$toRet = $toRet . "<td>$c</td>";
	}
	$toRet = $toRet . "</tr></thead>";
	
	foreach my $key (keys %$content) {
		my $use = $content->{$key}->{use};
		$use =~ s/%//;
		my $show_use = "<span class='text-success'>".$content->{$key}->{use}."</span>";
		if ($use > 80) {
			print "** High use of disk $key: ". $content->{$key}->{use}." \n";
			$show_use = "<span class='text-danger'>".$content->{$key}->{use}."</span>";
		}
		$toRet = $toRet . "<tr><td>".$key."</td><td>".$content->{$key}->{available}."</td><td>".$content->{$key}->{used}."</td><td>$show_use</td></tr>";
	}
	$toRet = $toRet."</table>";
	return $toRet;
}

# Print table for html report
sub print_table
{
	my %args = @_;
	my $content = $args{content};
	my $toRet = "<table class='table'><thead><tr>";
	
	foreach my $key (keys %$content) {
		$toRet = $toRet . "<td>$key</td>";
	}
	$toRet = $toRet."</tr></thead><tr>";
	
	foreach my $key (keys %$content) {
		$toRet = $toRet . "<td>".$content->{$key}."</td>";
	}
	
	$toRet = $toRet."</tr></table>";
	return $toRet;
}

# Collapse
sub print_collapse
{
	my %args = @_;
	my $content = $args{content};
	my $extract = substr $content, 0, 20;
	my $random_number = int rand(200);
	my $name = "text$random_number";
	my $where = "<a type='button' class='btn btn-info' data-toggle='collapse' href='$name' data-target='#$name'>" . $extract . " ...</a><br>";
	$where = $where . "<div id='$name' class='collapse out'>" . $content . "</div><br> ";
	
	return $where;
}

# Print config for html report
sub print_config
{
	my %args = @_;
	my $content = $args{content};
	my $toRet = "";

	foreach my $key (keys %$content) {
		if (!defined($content->{$key}) or $content->{$key} eq "" or ($key eq "server_name" and $content->{$key} = "localhost")) {
			$toRet = $toRet . "<p><span class='glyphicon glyphicon-remove' style='color:red'></span><b> $key</b> ". $content->{$key}."</p>";
			print "** Error in config detected for $key: ". $content->{$key}." \n";
		} else {
			$toRet = $toRet . "<p><span class='glyphicon glyphicon-ok' style='color:green'></span><b> $key</b> ". $content->{$key}."</p>";
		}
		
	}
	
	return $toRet;
}

# Copy graph
sub get_graph
{
	my %args = @_;
	
	my $C = NMISNG::Util::loadConfTable();

	my $graphtype = $args{type};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $item  = $args{item};
	my $parent = $args{cluster_id} || $C->{cluster_id}; # default: ours
	my $width = $args{width} // "600"; # graph size
	my $height = $args{height} // "150";
	my $start = $args{start} // time - 604800; # By default, 7 days ago
	my $end = $args{end};
	my $inventory = $args{inventory};
	my $omit_fluff = NMISNG::Util::getbool($args{only_link}); # return wrapped <a> etc. or just the href?
	
	my $result = NMISNG::rrdfunc::draw(
							node => $node,
							group => $group,
							graphtype => $graphtype,
							intf => $intf,
							item => $item,
							start => $start,
							#end =>  $end,
							width => $width,
							height => $height,
							filename => "$targetdir/img/$graphtype.png",
							inventory => $inventory);
	return $result;
	
}

# Duplicate nodes
sub check_duplicates
{
	my %args = @_;
	
	my $nodes_list = $nmisng->get_node_uuids();
	my %names;
	my $duplicates = 0;
	my $res;
	my $duplicates_list;
	
	foreach my $node (@$nodes_list) {
		#print "Node $node \n";
		my $nodeobj = $nmisng->node(uuid => $node);
		#print $nodeobj->name . "\n" if ($nodeobj);
		if ($names{$nodeobj->name}) {
			print "[ ".$nodeobj->name." ] duplicated. $node and ". $names{$nodeobj->name} . "\n";
			$duplicates_list->{$node} = $nodeobj->name;
			$duplicates++;
		} else
		{
			$names{$nodeobj->name} = $node;
		}
	}
	$res->{total} = "Total nodes: ". scalar(@$nodes_list) . " and duplicates $duplicates \n";
	$res->{list} = $duplicates_list if ($duplicates_list);
	
	return $res;
}