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
#
# a small helper for managing NMIS configuration backups
our $VERSION = "1.0.0";
use strict;
use File::Basename;
use FindBin;
use POSIX;
use Cwd qw();
use File::Spec;
use File::Temp qw();

my $usage = "Usage: ".basename($0)." <backupdir> [nr_of_backups]\n

backupdir: directory to store NMIS config backups in
nr_of_backups: how many backups should be kept. leave empty if you want to keep
all backups.\n\n";

die $usage if (!@ARGV or (@ARGV==1 && $ARGV[0] =~ /^--?[h\?]/));
my ($backupdir,$keep) = @ARGV;

die "This program needs to be stored within your NMIS installation, 
i.e. in the admin/ subdirectory. This doesn't seem to be the case here.\n"
		if (!-d "$FindBin::RealBin/../conf");

die $usage if (!$backupdir);

# make sure the backup dir is NOT under models or conf...
my $abs_bdir = (-d $backupdir)? Cwd::abs_path($backupdir) : 
		File::Spec->canonpath(File::Spec->rel2abs($backupdir));
my $abs_conf = Cwd::abs_path("$FindBin::RealBin/../conf");
my $abs_model = Cwd::abs_path("$FindBin::RealBin/../models");

if ($abs_bdir =~ /^($abs_conf|$abs_model)/)
{
	die "Backup dir $backupdir cannot be beneath conf or models\n";
}

if (!-d $backupdir)
{
	mkdir($backupdir,0700) or die "Cannot create $backupdir: $!\n";
}

die "Cannot write to directory $backupdir, check permissions!\n"
		if (!-w $backupdir);
die "Cannot read directory $backupdir, check permissions!\n"
		if (!-r $backupdir or !-x $backupdir);

# now let's take a new backup...
my $backupprefix = "nmis-config-backup-";
my $backupfilename = "$backupdir/$backupprefix".POSIX::strftime("%Y-%m-%d-%H%M",localtime).".tar";

# ...of our models and conf first.
my $status = system("tar","-cf",$backupfilename,"-C","$FindBin::RealBin/..", "models","conf");
if ($status == -1)
{
	die "Failed to execute tar!\n";
}
elsif ($status & 127)
{
	die "Backup failed, tar killed with signal ".($status & 127)."\n";
}
elsif ($status >> 8)
{
	die "Backup failed, tar exited with exit code ".($status >> 8)."\n";
}

# then add the various cron files to the archive and compress it
my $td = File::Temp::tempdir(CLEANUP => 1);
chdir $td or die "cannot chdir to $td: $!\n";
mkdir("$td/cron",0755) or die "Cannot create $td/cron: $!\n"; 
system("cp -a /etc/cron* cron/ 2>/dev/null");
system("crontab -l -u root >cron/root_crontab 2>/dev/null");
system("crontab -l -u nmis >cron/nmis_crontab 2>/dev/null");

$status = system("tar","-rf",$backupfilename,"cron");
if ($status == -1)
{
	die "Failed to execute tar!\n";
}
elsif ($status & 127)
{
	die "Backup failed, tar killed with signal ".($status & 127)."\n";
}
elsif ($status >> 8)
{
	die "Backup failed, tar exited with exit code ".($status >> 8)."\n";
}
$status = system("gzip",$backupfilename);
if ($status == -1)
{
	warn "Failed to execute gzip!\n";
}
elsif ($status & 127)
{
	warn "Backup compression failed, gzip killed with signal ".($status & 127)."\n";
}
elsif ($status >> 8)
{
	warn "Backup compression failed, gzip exited with exit code ".($status >> 8)."\n";
}
chdir("/");											# so that the tempdir can be cleaned up

if (defined $keep && $keep > 0)
{
	# ...then look at expiring older backups if there are too many
	opendir(D,$backupdir) or die "Cannot open directory $backupdir: $!\n";
	my @candidates = sort { my $first = $a; 
				$first =~ s/[a-zA-Z\.-]//g; 
				my $second = $b; 
				$second =~ s/[a-zA-Z\.-]//g;
				return $second <=> $first  } grep(/^$backupprefix.*(tgz|tar.gz)$/i, readdir(D));
	closedir(D);
	
	for my $rip (@candidates[$keep..$#candidates])
	{
		unlink("$backupdir/$rip") or warn "cannot remove old backup file $rip: $!\n";
	}
}

exit $status >> 8;









