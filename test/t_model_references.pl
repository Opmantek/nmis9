#!/usr/bin/perl
#
# t_model_references.pl - shipped-model consistency (OMK-12755).
#
# Every Model-*.nmis in models-default must parse, and every common-model
# reference in its -common- class block must resolve to an existing
# Common-<feature>.nmis in models-default. A dangling reference makes
# NMISNG::Sys::loadModel() return 0 for every node using that model, which
# raises "Model File Invalid" on every update.
#
# Static check: no MongoDB, no config, no side effects.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use NMISNG::Util;

my $models_dir = "$FindBin::Bin/../models-default";
ok(-d $models_dir, "models-default directory exists") or BAIL_OUT("no $models_dir");

opendir(my $dh, $models_dir) or BAIL_OUT("cannot read $models_dir: $!");
my @model_files = sort grep { /^Model-.+\.nmis$/ } readdir($dh);
closedir($dh);

cmp_ok(scalar(@model_files), '>', 100, "found a plausible number of model files");

for my $file (@model_files)
{
	my $mdl = NMISNG::Util::readFiletoHash(file => "$models_dir/$file");
	if (ref($mdl) ne "HASH" or !keys %$mdl)
	{
		fail("$file: parses as a non-empty hash");
		diag("$file: $mdl") if (!ref($mdl));    # readFiletoHash returns error string
		next;
	}
	pass("$file: parses as a non-empty hash");

	my @missing;
	if (ref($mdl->{'-common-'}) eq "HASH" and ref($mdl->{'-common-'}{class}) eq "HASH")
	{
		for my $class (sort keys %{$mdl->{'-common-'}{class}})
		{
			my $feature = $mdl->{'-common-'}{class}{$class}{'common-model'};
			if (!defined $feature or $feature eq "")
			{
				push @missing, "class $class has no common-model value";
				next;
			}
			push @missing, "Common-$feature.nmis (class $class)"
				if (!-f "$models_dir/Common-$feature.nmis");
		}
	}
	ok(!@missing, "$file: all common-model references resolve")
		or diag("$file is missing: " . join(", ", @missing));
}

done_testing();
