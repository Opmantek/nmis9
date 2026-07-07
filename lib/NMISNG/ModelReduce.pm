package NMISNG::ModelReduce;
#
#  Reduce full custom model copies to Override-*.nmis files when the compiled
#  model is provably unchanged. Pure logic plus a loader-based verifier.
#
use strict;
use warnings;
use Clone;
use NMISNG::Sys;
use NMISNG::Log;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);

our $VERSION = "9.6.5";

# Minimal nmisng-like object: loadModel only needs ->log and ->config.
{
	package NMISNG::ModelReduce::FakeNmisng;
	sub new { my ($c, %a) = @_; bless { %a }, $c; }
	sub log { $_[0]->{log} }
	sub config { $_[0]->{config} }
}

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

# build_override($diff): rebuild a hashref from the diff's set entries only.
sub build_override
{
	my ($diff) = @_;
	my $override = {};
	for my $entry (@{$diff->{set}})
	{
		_set_path($override, $entry->{path}, Clone::clone($entry->{value}));
	}
	return $override;
}

# _set_path($hash, \@path, $value): set a nested value, creating intermediate hashes.
sub _set_path
{
	my ($hash, $path, $value) = @_;
	my $node = $hash;
	for my $i (0 .. $#$path - 1)
	{
		my $k = $path->[$i];
		$node->{$k} = {} if (ref($node->{$k}) ne "HASH");
		$node = $node->{$k};
	}
	$node->{$path->[-1]} = $value;
	return;
}

# compile_model(%args): drive the real loader against isolated dirs.
sub compile_model
{
	my (%args) = @_;

	my $C = Clone::clone($args{config});
	$C->{'<nmis_default_models>'} = $args{default_dir};
	$C->{'<nmis_models>'}         = $args{custom_dir};
	$C->{'<nmis_var>'}            = $args{var_dir};
	delete $C->{global_model_overrides};

	my $logger = NMISNG::Log->new(level => 'fatal');
	my $fake = NMISNG::ModelReduce::FakeNmisng->new(config => $C, log => $logger);

	my $sys = NMISNG::Sys->new();
	$sys->{config}       = $C;
	$sys->{_nmisng}      = $fake;
	$sys->{cache_models} = 0;

	my $ok = $sys->loadModel(model => $args{model});
	return undef if (!$ok);
	return $sys->{mdl};
}

# models_referencing_common($feature, @dirs): model names that pull in Common-$feature.
sub models_referencing_common
{
	my ($feature, @dirs) = @_;
	my %seen_file;
	my %matches;
	for my $dir (@dirs)
	{
		next if (!defined $dir || !-d $dir);
		opendir(my $dh, $dir) or next;
		my @files = grep { /^Model-.+\.nmis$/ } readdir($dh);
		closedir($dh);
		for my $f (sort @files)
		{
			next if ($seen_file{$f}++);    # first dir wins (custom before default)
			my $data = NMISNG::Util::readFiletoHash(file => "$dir/$f");
			next if (ref($data) ne "HASH");
			my $class = $data->{'-common-'}{class};
			next if (ref($class) ne "HASH");
			for my $c (keys %$class)
			{
				if (($class->{$c}{'common-model'} // '') eq $feature)
				{
					my $name = $f; $name =~ s/\.nmis$//;
					$matches{$name} = 1;
					last;
				}
			}
		}
	}
	return sort keys %matches;
}

# _copy_dir_files($src, $dst): copy every *.nmis file from src into dst (flat).
sub _copy_dir_files
{
	my ($src, $dst) = @_;
	make_path($dst) if (!-d $dst);
	return if (!-d $src);
	opendir(my $dh, $src) or return;
	for my $f (grep { /\.nmis$/ } readdir($dh))
	{
		File::Copy::copy("$src/$f", "$dst/$f");
	}
	closedir($dh);
	return;
}

# verify_reduction(%args): compile affected models before/after and compare.
sub verify_reduction
{
	my (%args) = @_;
	my $basename    = $args{basename};
	my $custom_dir  = $args{custom_dir};
	my $default_dir = $args{default_dir};
	my $config      = $args{config};
	my $override    = $args{override};

	my $tmp = tempdir("model-reduce-verify-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $before_cus = "$tmp/before-custom";
	my $after_cus  = "$tmp/after-custom";
	my $var_before = "$tmp/var-before";
	my $var_after  = "$tmp/var-after";
	make_path("$var_before/nmis_system/model_cache", "$var_after/nmis_system/model_cache");

	# before: exact copy of the real custom dir
	_copy_dir_files($custom_dir, $before_cus);
	# after: same, minus the target file, plus the override when given
	_copy_dir_files($custom_dir, $after_cus);
	unlink("$after_cus/$basename.nmis");
	if (defined $override)
	{
		NMISNG::Util::writeHashtoFile(
			file => "$after_cus/Override-$basename.nmis",
			data => $override, json => 0, conf => $config);
	}

	# which models to compile
	my @models;
	if ($basename =~ /^Model-/)
	{
		push @models, $basename;
	}
	else # Common-<feature>
	{
		my $feature = $basename; $feature =~ s/^Common-//;
		# scan the after custom dir plus the default dir for referencing models
		@models = models_referencing_common($feature, $after_cus, $default_dir);
	}

	return { ok => 0, models => [], mismatch => undef, reason => "no-referencers",
		error => "no models to compile" }
		if (!@models);

	my @skipped;
	my $matched = 0;
	for my $m (@models)
	{
		my $before = compile_model(model => $m, config => $config,
			default_dir => $default_dir, custom_dir => $before_cus, var_dir => $var_before);
		my $after  = compile_model(model => $m, config => $config,
			default_dir => $default_dir, custom_dir => $after_cus, var_dir => $var_after);
		my $bdef = defined $before;
		my $adef = defined $after;

		# both fail to compile the same way: the reduction cannot affect a model
		# that does not load, so this model gives no evidence either way. Skip it.
		if (!$bdef && !$adef)
		{
			push @skipped, $m;
			next;
		}
		# compile status changed (one loads, the other does not): the reduction
		# changed whether the model compiles. That is a real, unsafe difference.
		if ($bdef != $adef)
		{
			return { ok => 0, models => \@models, mismatch => $m,
				reason => "compile-status-changed", skipped => \@skipped };
		}
		# both compiled: they must be identical.
		if (!deep_equal($before, $after))
		{
			return { ok => 0, models => \@models, mismatch => $m,
				reason => "differs", skipped => \@skipped };
		}
		$matched++;
	}
	# no model actually compiled, so nothing was proven.
	if ($matched == 0)
	{
		return { ok => 0, models => \@models, mismatch => undef,
			reason => "unverifiable", skipped => \@skipped };
	}
	return { ok => 1, models => \@models, mismatch => undef,
		compiled => $matched, skipped => \@skipped };
}

# analyse(%args): full per-file classification with verification.
sub analyse
{
	my (%args) = @_;
	my $custom_dir  = $args{custom_dir};
	my $default_dir = $args{default_dir};
	my $config      = $args{config};
	my $only        = $args{only};

	my @results;
	opendir(my $dh, $custom_dir) or die "cannot read $custom_dir: $!\n";
	my @files = sort grep { /\.nmis$/ } readdir($dh);
	closedir($dh);

	for my $f (@files)
	{
		my $basename = $f; $basename =~ s/\.nmis$//;
		next if (defined $only && $basename ne $only);

		if ($basename =~ /^Override-/)
		{
			push @results, { basename=>$basename, category=>"skip-override" };
			next;
		}
		if ($basename =~ /^Graph-/)
		{
			push @results, { basename=>$basename, category=>"skip-graph" };
			next;
		}
		if ($basename !~ /^(Model|Common)-/)
		{
			push @results, { basename=>$basename, category=>"skip-override" };
			next;
		}
		if (!-e "$default_dir/$f")
		{
			push @results, { basename=>$basename, category=>"skip-no-default" };
			next;
		}

		my $custom  = NMISNG::Util::readFiletoHash(file => "$custom_dir/$f");
		my $default = NMISNG::Util::readFiletoHash(file => "$default_dir/$f");
		if (ref($custom) ne "HASH" || ref($default) ne "HASH")
		{
			push @results, { basename=>$basename, category=>"error",
				error => "unparseable: " . (ref($custom) ne "HASH" ? $custom : $default) };
			next;
		}

		my $diff = semantic_diff($default, $custom);
		my $cat  = classify($diff);

		if ($cat eq "identical" || $cat eq "reducible")
		{
			my $override = ($cat eq "reducible") ? build_override($diff) : undef;
			my $v = verify_reduction(basename=>$basename, custom_dir=>$custom_dir,
				default_dir=>$default_dir, config=>$config, override=>$override);
			if ($v->{ok})
			{
				push @results, { basename=>$basename, category=>$cat,
					verified=>1, override=>$override };
			}
			else
			{
				# verification failed: cannot trust this reduction, keep the copy.
				my $r = $v->{reason} // "";
				my $why =
					  $r eq "differs" ? "compiled model differs on $v->{mismatch}"
					: $r eq "compile-status-changed" ? "reduction changes whether $v->{mismatch} compiles"
					: $r eq "no-referencers" ? "no models to compile"
					: $r eq "unverifiable" ? "no referencing model could be compiled (skipped: "
						. join(", ", @{$v->{skipped} // []}) . ")"
					: ($v->{error} // "verification failed");
				push @results, { basename=>$basename, category=>"error",
					verified=>0, override=>undef, error=>$why };
			}
		}
		else # drift
		{
			my @drops = map { join("/", @{$_->{path}}) } @{$diff->{drop}};
			push @drops, map { join("/", @{$_->{path}})." (type conflict)" } @{$diff->{typeconflict}};
			push @results, {
				basename => $basename,
				category => "drift",
				verified => 0,
				override => build_override($diff),   # manual-start (adds/changes only)
				drops    => \@drops,
			};
		}
	}
	return \@results;
}

1;
