package NMISNG::ModelReduce;
#
#  Reduce full custom model copies to Override-*.nmis files when the compiled
#  model is provably unchanged. Pure logic plus a loader-based verifier.
#
use strict;
use warnings;

our $VERSION = "9.6.5";

# deep_equal($a, $b): true if two Perl structures are deeply equal.
sub deep_equal
{
	my ($a, $b) = @_;

	return 1 if (!defined $a && !defined $b);
	return 0 if (!defined $a || !defined $b);

	my $ta = ref($a);
	my $tb = ref($b);
	return 0 if ($ta ne $tb);

	if ($ta eq "")
	{
		return ($a eq $b) ? 1 : 0;
	}
	elsif ($ta eq "ARRAY")
	{
		return 0 if (scalar(@$a) != scalar(@$b));
		for my $i (0 .. $#$a)
		{
			return 0 if (!deep_equal($a->[$i], $b->[$i]));
		}
		return 1;
	}
	elsif ($ta eq "HASH")
	{
		return 0 if (scalar(keys %$a) != scalar(keys %$b));
		for my $k (keys %$a)
		{
			return 0 if (!exists $b->{$k});
			return 0 if (!deep_equal($a->{$k}, $b->{$k}));
		}
		return 1;
	}
	# any other ref type (Regexp, code, etc): compare stringified
	return ("$a" eq "$b") ? 1 : 0;
}

1;
