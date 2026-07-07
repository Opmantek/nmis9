#!/usr/bin/perl
#
#  reduce_model.pl - replace full custom model copies with Override-*.nmis files
#  when the compiled model is provably unchanged. Dry run by default.
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#  NMIS is free software: licensed under the GNU General Public License v3+.
#
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;
use Data::Dumper;
use File::Path qw(make_path);
use File::Copy qw(copy);

use NMISNG::Util;
use NMISNG::ModelReduce;

my $arg = NMISNG::Util::get_args_multi(@ARGV);

if (NMISNG::Util::getbool($arg->{help}) || (defined $arg->{help}))
{
	usage();
	exit 0;
}

my $C = NMISNG::Util::loadConfTable();
die "cannot load NMIS config\n" if (ref($C) ne "HASH" || !%$C);

my $custom_dir  = $arg->{dir}         // NMISNG::Util::getDir(dir => "models",        conf => $C);
my $default_dir = $arg->{default_dir} // NMISNG::Util::getDir(dir => "default_models", conf => $C);
my $apply       = NMISNG::Util::getbool($arg->{apply});
my $verbose     = NMISNG::Util::getbool($arg->{verbose});
my $scratch     = $arg->{scratch} // (($ENV{TMPDIR} || "/tmp") . "/model-reduce-$$");

die "custom dir not found: $custom_dir\n"  if (!-d $custom_dir);
die "default dir not found: $default_dir\n" if (!-d $default_dir);
make_path($scratch) if (!-d $scratch);

print "Custom  dir: $custom_dir\n";
print "Default dir: $default_dir\n";
print "Scratch dir: $scratch\n";
print "Mode       : " . ($apply ? "APPLY" : "dry run (no changes)") . "\n\n";

my $results = NMISNG::ModelReduce::analyse(
	custom_dir => $custom_dir, default_dir => $default_dir,
	config => $C, only => $arg->{model});

report($results);

# write proposed + manual-start overrides into scratch for inspection
for my $r (@$results)
{
	next if (!defined $r->{override});
	my $tag = ($r->{category} eq "drift") ? "manual-start" : "proposed";
	my $out = "$scratch/Override-$r->{basename}.$tag.nmis";
	local $Data::Dumper::Sortkeys = 1;
	NMISNG::Util::writeHashtoFile(file => $out, data => $r->{override}, json => 0, conf => $C);
}
print "\nProposed override files written under $scratch\n";

if ($apply)
{
	apply_changes($results, $custom_dir, $C);
}
else
{
	my @todo = grep { $_->{verified} && ($_->{category} eq "identical" || $_->{category} eq "reducible") } @$results;
	print "\n" . scalar(@todo) . " file(s) would be changed. Re-run with apply=1 to apply.\n";
}

sub report
{
	my ($results) = @_;
	printf("%-34s %-16s %s\n", "FILE", "OUTCOME", "DETAIL");
	printf("%-34s %-16s %s\n", "----", "-------", "------");
	for my $r (sort { $a->{basename} cmp $b->{basename} } @$results)
	{
		my $detail = "";
		if ($r->{category} eq "reducible") { $detail = "override + remove copy (verified)"; }
		elsif ($r->{category} eq "identical") { $detail = "remove copy, no override (verified)"; }
		elsif ($r->{category} eq "drift")
		{
			$detail = "kept; default adds: " . join(", ", @{$r->{drops} // []});
		}
		elsif ($r->{category} eq "error") { $detail = $r->{error} // "error"; }
		printf("%-34s %-16s %s\n", $r->{basename}, $r->{category}, $detail);
	}
}

sub usage
{
	print <<EOF;
Usage: $0 [dir=<models-custom>] [default_dir=<models-default>] [model=<Name>]
          [scratch=<dir>] [apply=1] [verbose=1]

Dry run by default. Replaces full custom model copies with Override-*.nmis
files when the compiled model is provably unchanged. Removes copies that are
already identical to the default. Reports copies that drifted from a newer
default without changing them.
EOF
	return;
}
