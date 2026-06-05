package NMISNG::JSONPath;
# Minimal JSONPath subset for NMISNG::Sys::Engine::HTTP.
#
# Supported syntax:
#   $                  - root
#   $.name             - hash key (alphanumeric + underscore)
#   $["dotted.key"]    - bracketed hash key (allows dots, slashes, etc.)
#   $['single-quoted'] - bracketed hash key with single quotes
#   $.list[0]          - array index (non-negative integer)
#   $.list[*]          - array or hash wildcard (descend each element/value)
#   $.list.*           - same wildcard, dot form
#   These can chain: $.devices[*].dashboard_data.Temperature
#
# Deliberately NOT supported (use calculate_jsonpath as escape hatch):
#   - filter expressions [?(...)]
#   - slice notation [1:3]
#   - recursive descent ..
#   - negative indices
#   - script expressions
#
# extract($data, $path) -> (\@results, $error)
#   Returns arrayref of matched values; possibly empty if path matches nothing.
#   Wildcard paths return multiple values; non-wildcard paths return 0 or 1.
#   Caller is expected to know whether their path is single- or multi-valued
#   (typically `$results->[0]` for scalar paths).

use strict;
use warnings;

our $VERSION = "9.6.5";

sub extract
{
	my ($data, $path) = @_;
	return ([], "path is undef") unless defined $path;

	my ($tokens, $err) = _tokenize($path);
	return ([], $err) if $err;

	my @current = ($data);
	for my $tok (@$tokens)
	{
		my @next;
		if ($tok->{type} eq 'key')
		{
			for my $node (@current)
			{
				push @next, $node->{$tok->{key}}
					if ref $node eq 'HASH' && exists $node->{$tok->{key}};
			}
		}
		elsif ($tok->{type} eq 'index')
		{
			for my $node (@current)
			{
				push @next, $node->[$tok->{index}]
					if ref $node eq 'ARRAY' && $tok->{index} < scalar @$node;
			}
		}
		elsif ($tok->{type} eq 'wildcard')
		{
			for my $node (@current)
			{
				if (ref $node eq 'ARRAY')
				{
					push @next, @$node;
				}
				elsif (ref $node eq 'HASH')
				{
					# Sort by key for deterministic output (matches the
					# convention in Engine::WMI::discover_indexes).
					push @next, map { $node->{$_} } sort keys %$node;
				}
			}
		}
		@current = @next;
	}

	return (\@current, undef);
}

sub _tokenize
{
	my ($path) = @_;
	my @tokens;
	my $len = length($path);

	return (undef, "path must start with \$")
		unless $len > 0 && substr($path, 0, 1) eq '$';
	my $i = 1;

	while ($i < $len)
	{
		my $c = substr($path, $i, 1);
		if ($c eq '.')
		{
			$i++;
			return (undef, "unexpected end after '.'") if $i >= $len;
			my $next = substr($path, $i, 1);
			if ($next eq '*')
			{
				push @tokens, { type => 'wildcard' };
				$i++;
			}
			elsif (substr($path, $i) =~ /^([a-zA-Z_][a-zA-Z0-9_]*)/)
			{
				push @tokens, { type => 'key', key => $1 };
				$i += length($1);
			}
			else
			{
				return (undef, "expected key or '*' after '.' at position " . ($i - 1));
			}
		}
		elsif ($c eq '[')
		{
			my ($tok, $consumed, $err) = _parse_bracket(substr($path, $i));
			return (undef, "$err at position $i") if $err;
			push @tokens, $tok;
			$i += $consumed;
		}
		else
		{
			return (undef, "unexpected char '$c' at position $i");
		}
	}

	return (\@tokens, undef);
}

# Parse a [...] segment starting at position 0 of $s. Returns
# ($token_hashref, $chars_consumed, $error).
sub _parse_bracket
{
	my ($s) = @_;
	my $len = length($s);
	return (undef, 0, "expected '['") unless $len > 0 && substr($s, 0, 1) eq '[';
	my $i = 1;
	return (undef, 0, "unexpected end after '['") if $i >= $len;
	my $c = substr($s, $i, 1);

	if ($c eq '*')
	{
		$i++;
		return (undef, 0, "expected ']' after '[*'")
			if $i >= $len || substr($s, $i, 1) ne ']';
		return ({ type => 'wildcard' }, $i + 1, undef);
	}
	if ($c eq '"' || $c eq "'")
	{
		my $quote = $c;
		$i++;
		my $key = '';
		while ($i < $len && substr($s, $i, 1) ne $quote)
		{
			if (substr($s, $i, 1) eq '\\' && $i + 1 < $len)
			{
				$key .= substr($s, $i + 1, 1);
				$i += 2;
			}
			else
			{
				$key .= substr($s, $i, 1);
				$i++;
			}
		}
		return (undef, 0, "unterminated quoted key in '[]'") if $i >= $len;
		$i++;    # skip closing quote
		return (undef, 0, "expected ']' after quoted key")
			if $i >= $len || substr($s, $i, 1) ne ']';
		return ({ type => 'key', key => $key }, $i + 1, undef);
	}
	if ($c eq ':' || substr($s, $i) =~ /^\d+:/)
	{
		return (undef, 0,
			"slice expressions '[a:b]' are not supported in this subset");
	}
	if ($c =~ /\d/)
	{
		if (substr($s, $i) =~ /^(\d+)/)
		{
			my $idx = $1 + 0;
			$i += length($1);
			return (undef, 0, "expected ']' after index")
				if $i >= $len || substr($s, $i, 1) ne ']';
			return ({ type => 'index', index => $idx }, $i + 1, undef);
		}
	}
	if ($c eq '?')
	{
		return (undef, 0,
			"filter expressions '[?(...)]' are not supported in this subset; use calculate_jsonpath instead");
	}
	if ($c eq '-')
	{
		return (undef, 0, "negative array indices are not supported in this subset");
	}
	return (undef, 0, "unexpected '$c' inside '[]'");
}

1;
