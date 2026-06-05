package NMISNG::PromText;
# Parser for Prometheus text-exposition format (text/plain; version=0.0.4).
# Spec: https://prometheus.io/docs/instrumenting/exposition_formats/
#
# Returns parsed samples as plain hashrefs; caller (Engine::HTTP) is responsible
# for label-based indexing, filtering, and storage. Special float values
# (NaN, +Inf, -Inf) are returned as strings so callers can decide how to handle them
# rather than fighting Perl's unstable NaN/Inf semantics.

use strict;
use warnings;

our $VERSION = "9.6.5";

# parse_metrics($body) -> (\@samples, \@errors)
#   Each sample: { name, labels => {}, value, type?, help?, timestamp? }
#   Errors are per-line parse errors as strings. Non-fatal: parser continues
#   past bad lines so a single mangled metric does not lose the whole scrape.
sub parse_metrics
{
	my ($body) = @_;
	return ([], ["body is undef"]) unless defined $body;

	my (@samples, @errors);
	my %meta;    # metric_name => { type => ..., help => ... }

	my $line_num = 0;
	for my $line (split /\n/, $body)
	{
		$line_num++;
		$line =~ s/\r$//;
		next if $line =~ /^\s*$/;

		if ($line =~ /^\s*#/)
		{
			if ($line =~ /^\s*#\s+HELP\s+(\S+)(?:\s+(.*))?$/)
			{
				my ($name, $help) = ($1, $2 // "");
				$meta{$name}{help} = _unescape_help($help);
			}
			elsif ($line =~ /^\s*#\s+TYPE\s+(\S+)\s+(\S+)\s*$/)
			{
				$meta{$1}{type} = $2;
			}
			# any other # comment is ignored
			next;
		}

		my ($sample, $err) = _parse_sample_line($line);
		if ($err)
		{
			push @errors, "line $line_num: $err";
			next;
		}
		next unless $sample;

		$sample->{type} = $meta{$sample->{name}}{type} if exists $meta{$sample->{name}}{type};
		$sample->{help} = $meta{$sample->{name}}{help} if exists $meta{$sample->{name}}{help};
		push @samples, $sample;
	}

	return (\@samples, \@errors);
}

# Unescape sequences valid in HELP text: \\ -> \, \n -> newline.
# Order matters: handle \\ first by tokenising so a literal backslash followed
# by 'n' is not misread as a newline escape.
sub _unescape_help
{
	my ($s) = @_;
	my $out = '';
	my $i = 0;
	while ($i < length($s))
	{
		my $c = substr($s, $i, 1);
		if ($c eq '\\' && $i + 1 < length($s))
		{
			my $n = substr($s, $i + 1, 1);
			if    ($n eq '\\') { $out .= '\\'; $i += 2; }
			elsif ($n eq 'n')  { $out .= "\n"; $i += 2; }
			else               { $out .= $c;   $i++; }
		}
		else
		{
			$out .= $c;
			$i++;
		}
	}
	return $out;
}

# Parse a single sample line: metric_name[{labels}] value [timestamp]
sub _parse_sample_line
{
	my ($line) = @_;

	$line =~ s/^\s+//;
	return (undef, undef) if $line eq '';

	if ($line !~ /^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/)
	{
		return (undef, "no metric name found");
	}
	my $name = $1;
	my $rest = $2;
	$rest =~ s/^\s+//;

	my %labels;
	if ($rest =~ /^\{/)
	{
		my ($labels_str, $remaining, $err) = _split_labels($rest);
		return (undef, $err) if $err;
		my ($lh, $lerr) = _parse_labels($labels_str);
		return (undef, $lerr) if $lerr;
		%labels = %$lh;
		$rest = $remaining;
		$rest =~ s/^\s+//;
	}

	$rest =~ s/\s+$//;
	return (undef, "missing value") if $rest eq '';

	my @parts = split /\s+/, $rest;
	return (undef, "too many fields after labels") if @parts > 2;

	my $value = _parse_value($parts[0]);
	return (undef, "invalid value: $parts[0]") unless defined $value;

	my $sample = {
		name   => $name,
		labels => \%labels,
		value  => $value,
	};

	if (@parts == 2)
	{
		return (undef, "invalid timestamp: $parts[1]")
			unless $parts[1] =~ /^-?\d+$/;
		$sample->{timestamp} = $parts[1] + 0;
	}

	return ($sample, undef);
}

# Find the matching } for a label set, accounting for quoted strings and escapes.
# Returns (labels_inside, remainder_after_brace, error).
sub _split_labels
{
	my ($s) = @_;
	return (undef, undef, "expected {") unless $s =~ /^\{/;

	my $i = 1;
	my $in_string = 0;
	my $escape = 0;
	while ($i < length($s))
	{
		my $c = substr($s, $i, 1);
		if ($escape)              { $escape = 0; }
		elsif ($in_string && $c eq '\\') { $escape = 1; }
		elsif ($c eq '"')         { $in_string = !$in_string; }
		elsif ($c eq '}' && !$in_string)
		{
			return (substr($s, 1, $i - 1), substr($s, $i + 1), undef);
		}
		$i++;
	}
	return (undef, undef, "unterminated label set");
}

# Parse 'name1="val1",name2="val2"' into a hashref of {name=>value}.
sub _parse_labels
{
	my ($s) = @_;
	my %labels;
	my $len = length($s);
	my $i = 0;

	while ($i < $len)
	{
		# leading whitespace
		while ($i < $len && substr($s, $i, 1) =~ /\s/) { $i++; }
		last if $i >= $len;

		# label name
		unless (substr($s, $i) =~ /^([a-zA-Z_][a-zA-Z0-9_]*)/)
		{
			return (undef, "invalid label name at position $i");
		}
		my $name = $1;
		$i += length($name);

		# = sign
		while ($i < $len && substr($s, $i, 1) =~ /\s/) { $i++; }
		return (undef, "expected = after label name '$name'")
			if $i >= $len || substr($s, $i, 1) ne '=';
		$i++;

		# opening quote
		while ($i < $len && substr($s, $i, 1) =~ /\s/) { $i++; }
		return (undef, "expected \" after = for label '$name'")
			if $i >= $len || substr($s, $i, 1) ne '"';
		$i++;

		# value with escapes (\\ \" \n)
		my $value = '';
		while ($i < $len)
		{
			my $c = substr($s, $i, 1);
			if ($c eq '\\' && $i + 1 < $len)
			{
				my $n = substr($s, $i + 1, 1);
				if    ($n eq 'n')  { $value .= "\n"; $i += 2; }
				elsif ($n eq '\\') { $value .= '\\'; $i += 2; }
				elsif ($n eq '"')  { $value .= '"';  $i += 2; }
				else               { $value .= $c . $n; $i += 2; }    # tolerate unknown
			}
			elsif ($c eq '"')
			{
				last;
			}
			else
			{
				$value .= $c;
				$i++;
			}
		}
		return (undef, "unterminated label value for '$name'") if $i >= $len;
		$i++;    # skip closing "

		$labels{$name} = $value;

		# separator: , or end
		while ($i < $len && substr($s, $i, 1) =~ /\s/) { $i++; }
		last if $i >= $len;
		if (substr($s, $i, 1) eq ',') { $i++; next; }
		return (undef, "expected , or } at position $i");
	}

	return (\%labels, undef);
}

# Parse a Prometheus value token. Returns:
#   - a Perl number for normal floats/ints
#   - the strings 'NaN', '+Inf', or '-Inf' for special values
#   - undef for invalid input
# Special-value strings let callers detect non-finite values without relying
# on Perl's platform-dependent NaN/Inf handling.
sub _parse_value
{
	my ($s) = @_;
	return 'NaN' if $s eq 'NaN' || $s eq 'nan';
	return '+Inf' if $s eq '+Inf' || $s eq 'Inf' || $s eq 'inf';
	return '-Inf' if $s eq '-Inf';
	if ($s =~ /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/)
	{
		return $s + 0;
	}
	return undef;
}

1;
