#!/usr/bin/perl
#
#  Copyright 1999-2015 Opmantek Limited (www.opmantek.com)
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
# this tool migrates all nodes' rrd files from the locations
# set in the current Common-database.nmis to the new locations (from a 
# separate Common-database.nmis file, e.g. provided by an NMIS upgrade)
# and updates the Common-database.nmis with the new locations.
# 
# nmis collection is disabled while this operation is performed, and a record
# of operations is kept for rolling back in case of problems.
our $VERSION = "1.1.0";

use strict;
use File::Copy;
use File::Basename;
use Cwd;
use Data::Dumper;
use File::Path;
use IO::Handle;

use FindBin;
use lib "$FindBin::Bin/../lib";
use NMIS;
use func 1.2.1;

my $usage = "Usage: ".basename($0)." newlayout=/path/to/new/Common-database.nmis [simulate=true] [info=true]\n
newlayout: Common-database.nmis file to use for new locations, merged into current one.
simulate: only show what would be done, don't make any changes
info: produce more informational output\n\n";

my %args=getArguements(@ARGV);
my $simulate = getbool($args{simulate});

my $base = Cwd::abs_path("$FindBin::RealBin/..");

die "Cannot find NMIS configuration!\n\n$usage" if (!-d "$base/conf");

my $newdbf  = $args{newlayout};
die "No newlayout given or nonexistent file\n\n$usage" if (!-f $newdbf);

my $rollbackf = "/tmp/migration_rollback.sh";
my @rollback;

my $C = loadConfTable(debug => $args{debug}, info => $args{info}||$simulate);

my $newlayout = readFiletoHash(file => $newdbf);
die "Structure of newlayout not recognizable as Common-database.nmis!\n"
		if (ref($newlayout) ne "HASH" or ref($newlayout->{database}) ne "HASH");

$SIG{__DIE__} = sub {
	die @_ if $^S;								# within eval 

	&saverollback;
	print STDERR "\nA fatal error occurred:\n\n",@_,"\nYou can roll back the changes using the script saved in $rollbackf\n\n";
	exit 1;
};

# first, disable nmis completely
my $lockoutfile = "$base/conf/NMIS_IS_LOCKED";
if (!$simulate)
{
	push @rollback, "rm -f $lockoutfile";

	open F,">$lockoutfile" or die "cannot lock out nmis: $!\n";
	print F "$0 is operating, started at ".(scalar localtime)."\n";
	close F;
}


STDERR->autoflush(1);
STDOUT->autoflush(1);
print STDERR "Version $VERSION of ".basename($0)." starting\nReading local node table\n";
my $LNT = loadLocalNodeTable();
my (%rrdfiles,$countfiles);


# verify that the current common-database doesn't have anything custom that
# the new shipped version does not have
my $curlayout = readFiletoHash(file => $C->{'<nmis_models>'}."/Common-database.nmis");
if (ref($curlayout) ne "HASH" or ref($curlayout->{database}) ne "HASH")
{
	print STDERR "Cannot fine a current database layout file (Common-database.nmis), cannot proceed with migration!\n";
	exit 1;
}

print STDERR "Checking compatibility of current and new database layout files...\n";
for my $oldtypekey (sort keys %{$curlayout->{database}->{type}})
{
	if (!$newlayout->{database}->{type}->{$oldtypekey})
	{
		print STDERR "\n\nError: Your current database layout file contains custom entries!\n
There is an entry for the RRD type \"$oldtypekey\", which is not present
in the new database layout. This is likely caused by local custom models. 
This script cannot perform any database migration until all custom types
are merged into $newdbf, and will abort now.\n\n";
		exit 1;
	}
}
	



print STDERR "Identifying RRD files to rename\n";
# find all rrd files for all nodes with sys() objects based on 
# the current config, and remember the locations, the types, index, element - everything :-/
for my $node (sort keys %{$LNT})
{
	my $S = Sys->new;
	$S->init(name=>$node,snmp=>'false');
	my $NI = $S->ndinfo;
		
	# walk graphtype keys, if hash value: key is index, go one level deeper;
	# otherwise key of graphtype is all getDBName needs
	for my $section (keys %{$NI->{graphtype}})
	{
		# the generic ones remain where they were - in /metrics/.
		next if ($section =~ /^(network|nmis|metrics)$/);

		if (ref($NI->{graphtype}->{$section}) eq "HASH")
		{
			my $index = $section;
			for my $subsection (keys %{$NI->{graphtype}->{$section}})
			{
				if ($subsection =~ /^cbqos-(in|out)$/)
				{
					my $dir = $1;
					# need to find the qos classes and hand them to getdbname as item
					for my $classid (keys %{$NI->{cbqos}->{$index}->{$dir}->{ClassMap}})
					{
						my $item = $NI->{cbqos}->{$index}->{$dir}->{ClassMap}->{$classid}->{Name};
						record_rrd(sys => $S, node => $node, graphtype => $subsection,
											 index => $index, item => $item);
					}
				}
				else
				{
					record_rrd(sys => $S, node => $node, graphtype => $subsection, index => $index);
				}
			}
		}
		else
		{
			record_rrd(sys => $S, node => $node, graphtype => $section);
		}
	}
}
print STDERR "$countfiles existing RRD files for ".scalar(keys %rrdfiles)." nodes were found.\n";

# now merge the common-database material into the existing common-database.nmis, 
# but only TEMPORARILY and via func's table cache.
# we update the file only if we're not simulating, and if everything works out, ie. at the very end.
my $cacheobj = &func::_table_cache;
my $cachekey = "modelscommon-database";
die "Error: func.pm's table cache corrupt or nonexistent!\n" 
		if (ref($cacheobj) ne "HASH" or ref($cacheobj->{$cachekey}) ne "HASH" 
				or ref($cacheobj->{$cachekey}->{data}) ne "HASH"
				or ref($cacheobj->{$cachekey}->{data}->{database}) ne "HASH"
				or ref($cacheobj->{$cachekey}->{data}->{database}->{type}) ne "HASH");

$cacheobj->{$cachekey}->{data}->{database}->{type} = $newlayout->{database}->{type};

# oldfile -> newfile
my %todos;
print STDERR "Determining new RRD file locations.\n";
for my $node (keys %rrdfiles)
{
	# instantiate a new sys obj, with the new, in cache/in-memory common-database values
	my $S = Sys->new;
	$S->init(name=>$node, snmp=>'false');

	for my $oldname (keys %{$rrdfiles{$node}})
	{
		my $meta = $rrdfiles{$node}->{$oldname};

		my $newname = $S->getDBName(graphtype => $meta->{graphtype},
																index => $meta->{index},
																item => $meta->{item});
		if (!$newname)
		{
			die "Cannot determine new name for $oldname (graphtype=".$meta->{graphtype}
			.", index=".$meta->{index}.", item=".$meta->{item}.")\n";
		}
		if ($oldname ne $newname)
		{
			my $friendlyold = $oldname; $friendlyold =~ s/^$C->{database_root}//;
			my $friendlynew = $newname; $friendlynew =~ s/^$C->{database_root}//;
			
			info("Old RRD file $friendlyold, new $friendlynew");
			$todos{$oldname} = $newname;
		}
		else
		{
			info("oldname $oldname and new name identical, no change.");
		}
	}
}

my %olddirs;
print STDERR "Found ".int(scalar(keys %todos)). " RRD files to move.\n";

if (keys %todos and !$simulate)
{
	for my $oldfile (sort keys %todos)
	{
		my $newfile = $todos{$oldfile};
		my $newdir = dirname($newfile);
		$olddirs{dirname($oldfile)}=1;
				
		# create the required directories
		if (!-d $newdir)
		{
			push @rollback,"rmdir $newdir";
			my $error;
			my $desiredperms = oct($C->{os_execperm} || "0755");
			File::Path::make_path($newdir, { error => \$error, 
																			 owner => $C->{nmis_user}||"nmis",
																			 group => $C->{nmis_group} || "nmis",
																			 mode =>  $desiredperms } ); # umask is applied afterwards :-(
			if (ref($error) eq "ARRAY" and @$error)
			{
				my @errs;
				for my $issue (@$error) 
				{
					push @errs, join(": ", each %$issue);
				}
				die "Could not create directory: ".join(", ",@errs)."\n";
			}
			# make_path doesn't disable umask, so it's mode isn't much good...
			chmod($desiredperms,$newdir);
		}
		# move the file (remember what you did)
		push @rollback, "mv $newfile $oldfile";
		if (!rename($oldfile,$newfile))
		{
			die "Could not rename $oldfile to $newfile: $!\n";
		}
	}
	print STDERR "Moved all relevant RRD files.\n";
	
	print STDERR "Cleaning up leftover dirs.\n";
	# now clean up any left over directories
	for my $dir (reverse sort keys %olddirs)
	{
		next if (!-d $dir);
		push @rollback, "mkdir -p $dir";

		# now do a rmdir -p
		my @candidates;
		my $reldir = $dir; $reldir =~ s/^$C->{database_root}//;
		my @comps = split(m!/!,$reldir);
		for my $idx (0..$#comps-1)
		{
			my $part = $C->{database_root}.join("/",@comps[0..$#comps-$idx]);
			unlink($part) if (-d $part);
		}
	}

	print STDERR "Merging current Common-database with new data\n";
	# finally merge old common-database and the new one's type areas,
	# save the old common-database.nmis away and replace it with the new one
	my $curlayoutfile = $C->{'<nmis_models>'}."/Common-database.nmis";
	my $curlayout = readFiletoHash(file => $curlayoutfile);
	push @rollback, "mv $curlayoutfile.pre-migrate $curlayoutfile";
	rename($curlayoutfile,"$curlayoutfile.pre-migrate") or die "Could not rename $curlayoutfile: $!\n";
	
	$curlayout->{database}->{type} = $newlayout->{database}->{type};
	writeHashtoFile(file => $curlayoutfile, data => $curlayout);

	# save the rollback file anyway
	&saverollback;
	print STDERR "Saving rollback information in $rollbackf\n";
}

# finally unlock nmis (unconditionally)
unlink($lockoutfile) if (!$simulate);

if ($simulate)
{
	print STDERR "In simulation mode, not moving any files!\n";
}
else
{
	print STDERR "Migration complete.\n";
}
exit 0;

sub record_rrd
{
	my (%args) = @_;

	my $S = $args{sys};
	delete $args{sys};

	my $fn = $S->getDBName(graphtype => $args{graphtype},
												 index => $args{index},
												 item => $args{item});
	if (!$fn) 
	{
		dbg("node=$args{node}, graphtype=$args{graphtype}, index=$args{index}, item=$args{item}: NO db known!",2);
		return;
	}
	elsif (!-r $fn)
	{
		dbg("node=$args{node}, graphtype=$args{graphtype}, index=$args{index}, item=$args{item}:\n\tfile $fn does not exist.",2);
		return;
	}
	
	if (exists $rrdfiles{$args{node}}->{$fn})
	{
		die "error: $fn already known! node=$args{node}, graphtype=$args{graphtype}, index=$args{index}, item=$args{item}\n";
	}

	$rrdfiles{$args{node}}->{$fn} = {%args};
	++$countfiles;
}


# a small helper that dumps the rollback info into a file in /tmp
# args: none. uses: $rollbackf, @rollback, dumped in reverse order
sub saverollback
{
	open(F,">$rollbackf") or die "cannot write rollback file $rollbackf: $!\n";
	print F "#!/bin/sh\n# this script reverts a (partially) completed rrd location migration\n\n";
	print F join("\n", reverse @rollback)."\n";
	close F;
}
	
