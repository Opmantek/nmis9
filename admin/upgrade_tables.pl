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
# this helper upgrades table files where safe to do so
our $VERSION="9.0.0a";

use strict;
use Digest::MD5;								# good enough
use JSON::XS;
use Getopt::Std;
use File::Basename;
use File::Copy;

my $me = basename($0);
my $usage = "$me version $VERSION\n\nUsage: $me [-u] [-o|-p] [-n regex] <install dir> <config dir>
-u: do perform the upgrade instead of just reporting table file states
-o: report only upgradeable files
-p: report only problematic files
-n: NEVER upgrade the matching files

exit code: 0 or 255 (with -u)
without -u: 0 if no upgradables and no problem files were found,
2 upgradables and no problems,
1 no upgradables but problems,
3 both upgradables and problems.
\n\n";

my %opts;
die $usage if (!getopts("uopn:",\%opts)
							 or ($opts{p} && $opts{o})); # o and p are mutually exclusive
my ($newdir, $livedir) = @ARGV;
die $usage if (!-d $newdir or !-d $livedir or $livedir eq $newdir);

print "$me version $VERSION\n\n";

# load the embedded known signatures for the last few releases
my (%knownsigs, %newsig, $exitcode);
for (<DATA>)
{
	my ($file,@sigs) = split(/\s+/);
	$knownsigs{$file} = \@sigs;
	
	# complain if a known install file is missing completely - not terminal in general
	warn "warning: $newdir/$file is missing!\n" if (!-f "$newdir/$file");
	
	# and bail out if the purportedly known good new file doesn't match any of the known signatures
	$newsig{$file} = compute_signature("$newdir/$file");
	die "error: signature state ($newsig{$file}) for $newdir/$file not part of a known release!\n"
			if (!grep($_ eq $newsig{$file}, @sigs) and 
					(!$opts{n} or $file !~ qr{$opts{n}}));
}

# compute current signatures of the live stuff
my (%cursigs, @cando);
opendir(D, $livedir) or die "cannot open directory $livedir: $!\n";
for my $relfn (readdir(D))
{
	next if ($relfn !~ /^Table.+\.nmis$/);
	$cursigs{$relfn} = compute_signature("$livedir/$relfn");
}
closedir(D);

my $seecandidates = $opts{o};
my $wanttrouble = $opts{p};

# compare current files against known sigs; if known we can upgrade safely
for my $fn (sort keys %cursigs)
{
	my $sig = $cursigs{$fn};
	if ($opts{n} && $fn =~ qr{$opts{n}})
	{
		print "$fn is ignored because of option -n.\n";
	}
	elsif ($newsig{$fn} eq $sig)
	{
		print "$fn is uptodate.\n" if (!$seecandidates && !$wanttrouble);
	}
	elsif (!$knownsigs{$fn})
	{
		print "$fn is NOT UPGRADEABLE: locally created custom file.\n"
				if ($wanttrouble or !$seecandidates);
		$exitcode |= 1;
	}
	elsif (grep($_ eq $sig, @{$knownsigs{$fn}}))
	{
		print "$fn is upgradeable: not modified since installation.\n"
				if ($seecandidates or !$wanttrouble);
		push @cando, $fn;
		$exitcode |= 2;
	}
	else
	{
		print "$fn is NOT UPGRADEABLE: has been modified since installation.\n"
				if ($wanttrouble or !$seecandidates);
		$exitcode |= 1;
	}
}
# and handle totally new files
for my $newfn (sort keys %knownsigs)
{
	next if ($cursigs{$newfn});
	print "$newfn is upgradeable: new file.\n"
			if ($seecandidates or !$wanttrouble);
	push @cando, $newfn;
	$exitcode |= 2;
}

# perform the actual overwriting if desired
if ($opts{u} && @cando)
{
	print "Upgrading all upgradeable table files...\n";
	for my $todo (@cando)
	{
		my $res = File::Copy::cp("$newdir/$todo", "$livedir/$todo");
		die "copying of $todo to $livedir failed: $!\n" if (!$res);
	}
	print "Completed.\n";
}

exit ($opts{u}? 0 : $exitcode);


# computes a short signature for a Table-blah.nmis file,
# args: filename/path, optional sauce
# returns: signature or undef + warns on error
sub compute_signature
{
	my ($fn, $sauce) = @_;

	open(F, $fn) or die "cannot open file $fn: $!\n";
	my @lines = <F>;
	close F;

	my @filedata;
	for my $line (@lines)
	{
		next if ($line =~ /^\s*#/);						# comment lines
		$line =~ s/^\s*//; $line =~ s/\s*$//; # leading and trailing ws
		$line =~ s/\s+/ /g;					# collapse whitespace++ into single space
		$line =~ s/;\s*#.*$/;/;			# inline comments IFF at the end of a real statement
		next if ($line =~ /^\s*$/);

		push @filedata, $line;
	}
	$sauce ||= '';

	my $fullsig = Digest::MD5::md5_hex($sauce.join(" ",@filedata));
	return substr($fullsig,0,16);
}


# table file signatures for the last few releases are stored here
__DATA__
