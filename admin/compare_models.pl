#!/usr/bin/perl
# a small helper to conveniently compare models directories, models-custom vs models-default
# fixme9: currently flags files that don't exist in custom as a difference,
# which makes no sense in nmis9: there we should have next to ZERO files in models-custom!
use strict;
use File::Basename;
use POSIX;
use NMISNG::Util;

my $script = basename($0);

my $usage = "Usage: $script <models dir A> <new models dir B>
e.g. $script /usr/local/nmis9/models-custom /usr/local/nmis9/models-default

Exit code: 0 if no differences, 1 if differences were found,
255 on internal errors.\n\n";

my ($olddir,$newdir) = @ARGV;
die $usage if (!$olddir or !-d $olddir or !$newdir or !-d $newdir);

# Get temporary directory
my $tmp = NMISNG::Util::getTmpDir();

print("Performing model difference check, please wait...\n");

my $difflogfile = strftime("$tmp/model-diffs-%Y-%m-%d", localtime);
unlink($difflogfile) if (-f $difflogfile);

# try for the difftool in the same admin dir as this wrapper
# fall back to default location
my $difftool = dirname($0)."/diffconfigs.pl";
$difftool = "/usr/local/nmis9/admin/diffconfigs.pl" if (!-x $difftool);

die "Error: cannot find diffconfigs.pl\n" if (!-x $difftool);

open(F,">>$difflogfile") or die "cannot open logfile $difflogfile: $!\n";
print F "Comparison tool: $difftool\n";

my %candidates;
opendir(D, $olddir) or die "cannot open dir $olddir: $!\n";
map { $candidates{$_}=1; } (grep(/\.nmis$/i, readdir(D)));
closedir(D);

opendir(D, $newdir) or die "cannot open dir $newdir: $!\n";
map { $candidates{$_}+=2; } (grep(/\.nmis$/i, readdir(D)));
closedir(D);

my $counter=0;
for my $fn (keys %candidates)
{
	if ($counter++ >= 75)
	{
		print "\n.";
		$counter = 1;
	}
	else
	{
		print ".";
	}

	my @header = ("++++++++++++++++++++++++++++++++++++++++++++++++++++++\n",
								$fn, 
								"\n++++++++++++++++++++++++++++++++++++++++++++++++++++++\n");
	
	if ($candidates{$fn} < 3)	# old or new only
	{
		print F @header, 
		"The model file $fn only exists in the ".
				($candidates{$fn} == 1? "old":"new")." directory!\n\n";
	}
	else
	{
		my @output = `$difftool $olddir/$fn $newdir/$fn`;
		my $exitcode = $? >> 8;
		
		if (!$exitcode)						# exit 0 == no changes 
		{
			delete $candidates{$fn};
		}
		else
		{
			print F @header, @output, "\n";
		}
	}
}
print "\n\n";

if (keys %candidates)
{
	my @shinylist = sort keys %candidates;
	map { $shinylist[$_] .= ($_ % 3 == 2)?"\n":" "; } (0..$#shinylist);
	
	print qq|The comparison tool has detected some differences
between the old models (in $olddir) and 
the new models (in $newdir). 

The affected files are:\n\n|, @shinylist, 
qq|\n\nA detailed listing of these differences has been 
saved in $difflogfile.

You should review those differences (using less or an editor like 
nano, vi or emacs) and merge the model files where applicable.\n\n|;
	exit 1;
}
else
{
	print "The comparison tool has detected no differences 
between the old models (in $olddir) and 
the new models (in $newdir).\n\n";
	unlink($difflogfile);
	exit 0;
}

