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

# semantic_diff($default, $custom): classify differences. See interface doc.
sub semantic_diff
{
	my ($default, $custom) = @_;
	my $result = { set => [], drop => [], typeconflict => [] };
	_diff_walk($default, $custom, [], $result);
	return $result;
}

sub _diff_walk
{
	my ($default, $custom, $path, $result) = @_;

	# both hashes: recurse over the union of keys
	if (ref($default) eq "HASH" && ref($custom) eq "HASH")
	{
		my %allkeys = map { $_ => 1 } (keys %$default, keys %$custom);
		for my $k (sort keys %allkeys)
		{
			my $subpath = [@$path, $k];
			my $in_def = exists $default->{$k};
			my $in_cus = exists $custom->{$k};

			if ($in_def && !$in_cus)
			{
				push @{$result->{drop}}, { path => $subpath };
			}
			elsif (!$in_def && $in_cus)
			{
				push @{$result->{set}}, { path => $subpath, value => $custom->{$k} };
			}
			else
			{
				_diff_walk($default->{$k}, $custom->{$k}, $subpath, $result);
			}
		}
		return;
	}

	# base is a hash but custom is not: merge would fail
	if (ref($default) eq "HASH" && ref($custom) ne "HASH")
	{
		push @{$result->{typeconflict}}, { path => $path };
		return;
	}

	# leaf, array, or custom-hash-over-base-non-hash: representable, set whole value
	if (!deep_equal($default, $custom))
	{
		push @{$result->{set}}, { path => $path, value => $custom };
	}
	return;
}

# classify($diff): identical | reducible | drift
sub classify
{
	my ($diff) = @_;
	return "drift" if (@{$diff->{drop}} || @{$diff->{typeconflict}});
	return "reducible" if (@{$diff->{set}});
	return "identical";
}

1;
