package NMISNG::GrafanaDashboardImporter;

# Read a Grafana dashboard JSON, translate the Prometheus-datasource
# panels into NMIS Common-Linux-HTTP-*.nmis sections + Graph-*.nmis
# files. Hands the in-memory result to NMISNG::HTTPModelBuilder for
# the file write step (same Common/graph/README shape as the
# /metrics-endpoint scaffolder).
#
# v1 PromQL grammar (anything outside this is TODO-listed verbatim):
#   metric_name
#   metric_name{label="value"[, ...]}
#   rate(... [duration]) | irate(...) | increase(...)
#
# Aggregations (sum/max/avg by ...), histogram_quantile, and
# arithmetic are not translated -- the engine has no analog.

use strict;
use warnings;
use JSON::XS qw(decode_json);
use NMISNG::HTTPModelBuilder;

# Datasource type names that mean "Prometheus" in panel.datasource
# (Grafana 8+ uses { type => 'prometheus', uid => '...' }; pre-8 used
# the datasource name string, sometimes 'Prometheus' or 'prom').
my %PROM_TYPE = (
	prometheus => 1,
	prom       => 1,
);

# Panel types we can translate to a NMIS graph (time-series).
my %GRAPHABLE_PANEL = (
	graph        => 1,    # Grafana < 8
	timeseries   => 1,    # Grafana 8+
	stat         => 1,    # rendered as time-series anyway
	gauge        => 1,
	'singlestat' => 1,
);

# Panel types we silently skip (no time-series equivalent).
my %SKIP_PANEL = (
	text       => 1,
	alertlist  => 1,
	news       => 1,
	dashlist   => 1,
	row        => 1,    # row containers; we recurse into them anyway
);

sub new
{
	my ($class, %args) = @_;
	my $self = {
		model_name    => $args{name}     // 'App',
		endpoint_name => $args{endpoint} // _to_snake($args{name} // 'app') . '_exporter',
		todos         => [],
	};
	return bless $self, $class;
}

# Public: parse a JSON string and translate to the result-hash shape
# HTTPModelBuilder::emit_files consumes.
sub build
{
	my ($self, $json_text) = @_;

	my $doc = decode_json($json_text);
	my $panels = $self->_collect_panels($doc);

	# Translate each panel into 0+ sections.
	my @sections;
	for my $panel (@$panels)
	{
		my $sec = $self->_translate_panel($panel);
		push @sections, $sec if $sec;
	}

	return $self->_assemble(\@sections);
}

# Public-style: emit_files just delegates to HTTPModelBuilder so the
# caller can write `$importer->build(...)` and `$importer->emit_files(...)`
# symmetrically with HTTPModelBuilder.
sub emit_files
{
	my ($self, %args) = @_;
	my $hb = NMISNG::HTTPModelBuilder->new(
		name     => $self->{model_name},
		endpoint => $self->{endpoint_name},
	);
	return $hb->emit_files(%args);
}

# ------------------------------------------------------------------
# Panel walking: handle both modern (top-level panels[]) and legacy
# (dashboard.rows[].panels[]) shapes, and the v8+ collapsed-row
# pattern (a panel of type 'row' with its own nested panels[]).
# ------------------------------------------------------------------

sub _collect_panels
{
	my ($self, $doc) = @_;

	# Some exports wrap the dashboard in a `dashboard` key;
	# normalize to the inner object.
	my $dash = $doc->{dashboard} // $doc;

	my @out;
	# Modern (>=v6): top-level panels[].
	if (ref $dash->{panels} eq 'ARRAY')
	{
		for my $p (@{$dash->{panels}})
		{
			# Row containers may carry their own panels[] when collapsed.
			if (($p->{type} // '') eq 'row' && ref $p->{panels} eq 'ARRAY')
			{
				push @out, @{$p->{panels}};
			}
			else
			{
				push @out, $p;
			}
		}
	}
	# Legacy (<=v6): dashboard.rows[].panels[].
	if (ref $dash->{rows} eq 'ARRAY')
	{
		for my $row (@{$dash->{rows}})
		{
			push @out, @{$row->{panels}} if ref $row->{panels} eq 'ARRAY';
		}
	}
	return \@out;
}

# ------------------------------------------------------------------
# Per-panel translation.
# ------------------------------------------------------------------

sub _translate_panel
{
	my ($self, $panel) = @_;

	my $type  = $panel->{type}  // 'graph';
	my $title = $panel->{title} // '(untitled)';

	# Skip non-graphable panel types.
	return undef if $SKIP_PANEL{$type} && !$GRAPHABLE_PANEL{$type};
	if (!$GRAPHABLE_PANEL{$type})
	{
		push @{$self->{todos}},
			"Panel '$title' (type='$type'): unsupported panel type, skipped.";
		return undef;
	}

	# Datasource check. Grafana 8+ uses { type => 'prometheus', uid => ... }.
	# Pre-8 uses a string ("Prometheus", "$datasource") or omits it (in
	# which case we assume Prometheus -- consistent with the dashboard
	# being labelled as such).
	my $ds = $panel->{datasource};
	my $ds_type;
	if (ref $ds eq 'HASH')
	{
		$ds_type = lc($ds->{type} // '');
	}
	elsif (defined $ds && length $ds)
	{
		$ds_type = lc($ds);
	}
	if (defined $ds_type && length $ds_type && !$PROM_TYPE{$ds_type})
	{
		# Could also be a templated name like '$datasource'. Treat
		# anything that doesn't match a known Prom alias as non-Prom.
		if ($ds_type !~ /^\$/)
		{
			push @{$self->{todos}},
				"Panel '$title': non-Prometheus datasource '$ds_type', skipped.";
			return undef;
		}
	}

	my $targets = $panel->{targets};
	unless (ref $targets eq 'ARRAY' && @$targets)
	{
		push @{$self->{todos}},
			"Panel '$title': no targets, skipped.";
		return undef;
	}

	# Translate every target. Successful ones become DS items; failed
	# ones become TODOs.
	my %ds_seen;
	my @items;
	for my $t (@$targets)
	{
		my $expr = $t->{expr};
		next unless defined $expr && length $expr;
		my $parsed = $self->_parse_expr($expr);
		if (!$parsed)
		{
			push @{$self->{todos}},
				"Panel '$title': could not translate expression -- preserved verbatim:\n"
				. "    $expr";
			next;
		}
		my $legend = $t->{legendFormat} // '';
		my $ref_id = $t->{refId}        // '';
		my $ds_name = _ds_name_from_legend($legend, $ref_id, $parsed->{metric}, \%ds_seen);

		my %item = (
			metric => $parsed->{metric},
			option => $parsed->{is_rate} ? 'counter,0:U' : 'gauge,U:U',
		);
		$item{match_labels} = $parsed->{labels} if %{$parsed->{labels} || {}};
		$item{title}        = $legend           if length $legend && $legend !~ /\{\{/;
		# A legendFormat with `{{label}}` interpolation suggests an
		# indexed section; remember the labels referenced so we can
		# detect that.
		push @items, {
			ds            => $ds_name,
			item          => \%item,
			legend_labels => [_extract_legend_labels($legend)],
			labels        => $parsed->{labels} || {},
		};
	}

	return undef unless @items;

	# Indexed-section detection: if any target's legend interpolates a
	# label, propose that label as `indexed`. If multiple targets share
	# a metric and differ only on one label value, also indexed.
	my $indexed = $self->_detect_indexed(\@items);
	my $section_name = _camel_section_name($title);
	my $graphtype    = "$self->{model_name}-$section_name";

	if (defined $indexed)
	{
		push @{$self->{todos}},
			"Panel '$title': legend interpolates label '$indexed' -- "
			. "scaffolded as indexed section. Confirm whether you want a row "
			. "per distinct $indexed value, and consider composite indexing if "
			. "more than one label varies.";
		return $self->_build_indexed_section_from_panel(
			$panel, $section_name, $graphtype, $indexed, \@items);
	}
	return $self->_build_scalar_section_from_panel(
		$panel, $section_name, $graphtype, \@items);
}

sub _detect_indexed
{
	my ($self, $items) = @_;

	# (1) An items's legend that interpolates a label.
	for my $i (@$items)
	{
		for my $l (@{$i->{legend_labels}})
		{
			return $l;
		}
	}

	# (2) Multiple items share a metric and differ only on one label
	# value. Heuristic: if a single label is the only varying one
	# across same-metric items, that label is the index.
	my %by_metric;
	push @{$by_metric{$_->{item}{metric}}}, $_ for @$items;
	for my $metric (keys %by_metric)
	{
		my @group = @{$by_metric{$metric}};
		next unless @group >= 2;
		my %varying;
		my @labels = map { $_->{labels} } @group;
		my %all_keys;
		$all_keys{$_} = 1 for map { keys %$_ } @labels;
		for my $k (keys %all_keys)
		{
			my %vals;
			$vals{$_->{$k} // ''} = 1 for @labels;
			$varying{$k} = 1 if scalar(keys %vals) > 1;
		}
		my @vary_keys = keys %varying;
		return $vary_keys[0] if @vary_keys == 1;
	}
	return undef;
}

sub _build_scalar_section_from_panel
{
	my ($self, $panel, $section_name, $graphtype, $items) = @_;

	my $topic = _to_snake($section_name);
	my %http_prom = ('-common-' => { endpoint => $self->{endpoint_name} });
	for my $i (@$items)
	{
		$http_prom{$i->{ds}} = $i->{item};
	}

	my $rrd_path = "/nodes/\$node/health/${topic}.rrd";

	return {
		kind        => 'scalar',
		section     => $section_name,
		topic       => $topic,
		graphtype   => $graphtype,
		rrd_path    => $rrd_path,
		http_prom   => \%http_prom,
		items       => $items,
		title       => $panel->{title},
		section_def => {
			graphtype => $graphtype,
			http_prom => \%http_prom,
		},
	};
}

sub _build_indexed_section_from_panel
{
	my ($self, $panel, $section_name, $graphtype, $indexed, $items) = @_;

	my $rrd_path = "/nodes/\$node/health/" . _to_snake($section_name) . "-\$index.rrd";

	# Indexed extraction relies on the engine matching by section's
	# `indexed` label. So `match_labels` from the targets isn't
	# strictly needed for the index var, but we keep any other label
	# filters present in the original expression.
	my %sys_http_prom = ('-common-' => { endpoint => $self->{endpoint_name} });
	$sys_http_prom{$indexed} = { title => _humanize($indexed) };

	my %rrd_http_prom = ('-common-' => { endpoint => $self->{endpoint_name} });

	for my $i (@$items)
	{
		next if $i->{ds} eq $indexed;
		# In the rrd block: copy item but drop the indexed-var match
		# (the engine seeds it implicitly per row).
		my %rrd_item = %{$i->{item}};
		if (ref $rrd_item{match_labels} eq 'HASH'
			&& exists $rrd_item{match_labels}{$indexed})
		{
			my %ml = %{$rrd_item{match_labels}};
			delete $ml{$indexed};
			if (%ml) { $rrd_item{match_labels} = \%ml }
			else     { delete $rrd_item{match_labels} }
		}
		$rrd_http_prom{$i->{ds}} = \%rrd_item;
		# In the sys block: just metric + optional title (no option).
		my %sys_item = (metric => $i->{item}{metric});
		$sys_item{title} = $i->{item}{title} if defined $i->{item}{title};
		$sys_http_prom{$i->{ds}} = \%sys_item;
	}

	my @ds_names = ($indexed, map { $_->{ds} } grep { $_->{ds} ne $indexed } @$items);
	my $headers = join(',', @ds_names);

	return {
		kind      => 'indexed',
		section   => $section_name,
		graphtype => $graphtype,
		rrd_path  => $rrd_path,
		indexed   => $indexed,
		headers   => $headers,
		items     => $items,
		title     => $panel->{title},
		sys_def   => {
			indexed   => $indexed,
			index_oid => $indexed,
			headers   => $headers,
			max_rows  => 256,
			http_prom => \%sys_http_prom,
		},
		rrd_def => {
			graphtype => $graphtype,
			indexed   => $indexed,
			http_prom => \%rrd_http_prom,
		},
	};
}

# ------------------------------------------------------------------
# Assembly: glue per-panel sections into Common + per-section
# graphs. Mirrors HTTPModelBuilder::_assemble in shape so emit_files
# can consume the result unchanged.
# ------------------------------------------------------------------

sub _assemble
{
	my ($self, $sections) = @_;

	my %db_type;
	my %sys_rrd;
	my %sh_sys;
	my %sh_rrd;
	my @nodegraph;
	my %graphs;

	for my $sec (@$sections)
	{
		my $type_key
			= ($sec->{kind} eq 'indexed') ? $sec->{section} : $sec->{topic};
		$db_type{$type_key} = $sec->{rrd_path};
		if ($sec->{kind} eq 'indexed')
		{
			$sh_sys{$sec->{section}} = $sec->{sys_def};
			$sh_rrd{$sec->{section}} = $sec->{rrd_def};
		}
		else
		{
			$sys_rrd{$sec->{topic}} = $sec->{section_def};
		}
		push @nodegraph, $sec->{graphtype};
		$graphs{$sec->{graphtype}} = $self->_build_graph($sec);
	}

	my %common = (database => { type => \%db_type });
	$common{system} = {
		nodegraph => join(',', @nodegraph),
		rrd       => \%sys_rrd,
	} if %sys_rrd || @nodegraph;
	$common{systemHealth} = {
		(%sh_sys ? (sys => \%sh_sys) : ()),
		(%sh_rrd ? (rrd => \%sh_rrd) : ()),
	} if %sh_sys || %sh_rrd;

	my @notes;
	push @notes, "Imported " . scalar(@$sections) . " panel(s) from the "
		. "Grafana dashboard. " . scalar(@nodegraph)
		. " graphtype(s) registered on the model.";
	if (grep { $_->{kind} eq 'indexed' } @$sections)
	{
		push @notes, "Indexed sections still need their `sections` "
			. "string added to the model that includes this Common file -- "
			. "the Common file alone does not register them with "
			. "collect_systemhealth_info.";
	}

	return {
		common => \%common,
		graphs => \%graphs,
		todos  => $self->{todos},
		notes  => \@notes,
	};
}

# ------------------------------------------------------------------
# Graph file (kept small; reuses the same DEF/AREA/LINE pattern as
# HTTPModelBuilder).
# ------------------------------------------------------------------

my @PALETTE = qw(1E90FF 7CFC00 FFA500 FF6347 9370DB 20B2AA);
my $GRAPH_DS_CAP = 6;

sub _build_graph
{
	my ($self, $sec) = @_;

	my @ds_names = map { $_->{ds} } @{$sec->{items}};
	if ($sec->{kind} eq 'indexed')
	{
		@ds_names = grep { $_ ne $sec->{indexed} } @ds_names;
	}
	my @visible = @ds_names[0 .. ($GRAPH_DS_CAP - 1 < $#ds_names ? $GRAPH_DS_CAP - 1 : $#ds_names)];

	my $heading = $sec->{title} // ($self->{model_name} . ' ' . $sec->{section});

	my (@standard, @small);
	push @standard, '--lower-limit', '0';
	push @small,    '--lower-limit', '0';
	for my $ds (@visible)
	{
		push @standard, "DEF:$ds=\$database:$ds:AVERAGE";
		push @small,    "DEF:$ds=\$database:$ds:AVERAGE";
	}
	my $i = 0;
	for my $ds (@visible)
	{
		my $color = '#' . $PALETTE[$i % @PALETTE];
		my $shape = ($i == 0) ? 'AREA' : 'LINE1';
		my $label = ' ' . _humanize($ds);
		push @standard, "$shape:$ds$color:$label",
			"GPRINT:$ds:AVERAGE:Avg %8.2lf",
			"GPRINT:$ds:MAX:Max %8.2lf\\n";
		push @small,    "$shape:$ds$color:$label";
		$i++;
	}

	if (@ds_names > @visible)
	{
		push @{$self->{todos}},
			"Graph '$sec->{graphtype}' shows " . scalar(@visible)
			. " DS but the panel had " . scalar(@ds_names)
			. " targets. Remaining DS still record into the RRD; split into "
			. "multiple Graph files if you want them all plotted.";
	}

	return {
		heading => $heading,
		title   => {
			standard => "\$node $heading - \$length from \$datestamp_start to \$datestamp_end",
			short    => "\$node $heading - \$length",
		},
		vlabel => {
			standard => 'Value',
			small    => 'val',
		},
		option => {
			standard => \@standard,
			small    => \@small,
		},
	};
}

# ------------------------------------------------------------------
# v1 PromQL parser. Recognises:
#   metric_name
#   metric_name{ label OP "value" [, ...] }
#   rate(... [duration]) | irate(...) | increase(...)
# Returns:
#   { metric => '...', labels => { ... }, is_rate => 0|1 } on success
#   undef on failure (caller TODO-lists the original expr)
# ------------------------------------------------------------------

sub _parse_expr
{
	my ($self, $expr) = @_;
	$expr =~ s/^\s+|\s+$//g;
	return undef unless length $expr;

	# Reject anything containing top-level operators / aggregations.
	# Paranoid -- regex scans the whole expression for forbidden tokens
	# OUTSIDE quoted label values. Cheaper than a full tokenizer.
	my $stripped = _strip_label_values($expr);
	return undef if $stripped =~ /\b(sum|max|min|avg|count|topk|bottomk
		|stddev|stdvar|histogram_quantile|quantile|group|rate_vec
		|absent|absent_over_time|changes|delta|deriv|holt_winters
		|predict_linear|round|sgn|abs|ceil|floor|exp|ln|log2|log10|sqrt
		|clamp|day_of_month|days_in_month|hour|minute|month|year)\s*\(/x;
	return undef if $stripped =~ m![\+\-\*/]\s*[a-z\$\(]!i;
	return undef if $stripped =~ /\b(by|without|on|ignoring|group_left|group_right)\b/;

	# rate-wrap?
	my $is_rate = 0;
	if ($expr =~ /^\s*(?:rate|irate|increase)\s*\(\s*(.+?)\s*\)\s*$/)
	{
		$is_rate = 1;
		$expr = $1;
		# Strip the [range] selector if present.
		$expr =~ s/\s*\[\s*\d+[smhdwy]+\s*\]\s*$//;
	}

	# Bare metric or metric{labels}.
	my ($metric, $labels_str);
	if ($expr =~ /^\s*([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(\{.*\})?\s*$/)
	{
		$metric = $1;
		$labels_str = $2;
	}
	else
	{
		return undef;
	}

	my %labels;
	my @rejected;
	if (defined $labels_str)
	{
		# Strip outer braces.
		$labels_str =~ s/^\{//;
		$labels_str =~ s/\}$//;
		# Split label clauses on commas not inside quotes.
		my @clauses = _split_label_clauses($labels_str);
		for my $clause (@clauses)
		{
			next if $clause =~ /^\s*$/;
			# label OP "value"
			if ($clause =~ /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*(=~|!~|!=|=)\s*"((?:[^"\\]|\\.)*)"\s*$/)
			{
				my ($k, $op, $v) = ($1, $2, $3);
				if ($op eq '=')
				{
					# Substitute Grafana variables we treat as implicit.
					next if _is_grafana_var($v) && _is_implicit_node_var($k, $v);
					$labels{$k} = $v;
				}
				else
				{
					push @rejected, "label '$k$op\"$v\"' (engine supports = only)";
				}
			}
			else
			{
				push @rejected, "label clause '$clause' (unparseable)";
			}
		}
	}

	if (@rejected)
	{
		push @{$self->{todos}},
			"Expression '$_[1]': dropped " . scalar(@rejected)
			. " label clause(s) -- " . join(", ", @rejected)
			. ". The translated section will not include these constraints.";
	}

	return { metric => $metric, labels => \%labels, is_rate => $is_rate };
}

sub _strip_label_values
{
	my ($s) = @_;
	# Remove "..." sequences (with simple escape handling) so we don't
	# false-positive on operators that happen to appear inside label
	# values.
	$s =~ s/"(?:[^"\\]|\\.)*"/""/g;
	return $s;
}

sub _split_label_clauses
{
	my ($s) = @_;
	my @out;
	my $depth   = 0;
	my $in_q    = 0;
	my $current = '';
	for (my $i = 0; $i < length($s); $i++)
	{
		my $c = substr($s, $i, 1);
		if ($in_q)
		{
			$current .= $c;
			if ($c eq '\\' && $i + 1 < length($s))
			{
				$current .= substr($s, $i + 1, 1);
				$i++;
				next;
			}
			$in_q = 0 if $c eq '"';
		}
		elsif ($c eq '"')
		{
			$in_q = 1;
			$current .= $c;
		}
		elsif ($c eq ',' && !$in_q)
		{
			push @out, $current;
			$current = '';
		}
		else
		{
			$current .= $c;
		}
	}
	push @out, $current if length $current;
	return @out;
}

sub _is_grafana_var
{
	my ($v) = @_;
	return $v =~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/;
}

sub _is_implicit_node_var
{
	# instance="$node" or instance="$instance" -- NMIS scopes per node
	# already, so these are no-ops we drop silently.
	my ($k, $v) = @_;
	return 0 unless $k eq 'instance' || $k eq 'node' || $k eq 'host';
	return $v =~ /^\$\{?(?:node|instance|host)\}?$/i;
}

# ------------------------------------------------------------------
# Naming helpers (subset of HTTPModelBuilder's; kept private here so
# the importer stands alone).
# ------------------------------------------------------------------

sub _ds_name_from_legend
{
	my ($legend, $ref_id, $metric, $seen) = @_;
	# Best names: a clean legend, then refId (A/B/C), then derived from
	# metric. Always <= 19 chars and unique.
	my $candidate;
	if (length $legend && $legend !~ /\{\{/)
	{
		$candidate = _to_ds_token($legend);
	}
	if (!length($candidate // '') && length $ref_id)
	{
		$candidate = lc $ref_id;
	}
	if (!length($candidate // ''))
	{
		# Strip a common metric prefix; fall back to last segment.
		my @parts = split /_/, $metric;
		$candidate = lc(@parts > 1 ? join('_', @parts[1 .. $#parts]) : $parts[0]);
		$candidate = _to_ds_token($candidate);
	}
	$candidate = substr($candidate, 0, 19);
	if ($seen->{$candidate})
	{
		my $n = 2;
		while ($n < 100)
		{
			my $sfx = "_$n";
			my $c = substr($candidate, 0, 19 - length($sfx)) . $sfx;
			if (!$seen->{$c}) { $candidate = $c; last }
			$n++;
		}
	}
	$seen->{$candidate} = 1;
	return $candidate;
}

sub _to_ds_token
{
	my ($s) = @_;
	$s = lc $s;
	$s =~ s/[^a-z0-9]+/_/g;
	$s =~ s/_+/_/g;
	$s =~ s/^_|_$//g;
	$s = 'value' unless length $s;
	return $s;
}

sub _to_snake
{
	my ($s) = @_;
	return _to_ds_token($s);
}

sub _camel_section_name
{
	my ($s) = @_;
	my @parts = grep { length } split /[\W_]+/, $s;
	return join('', map { ucfirst lc $_ } @parts) || 'Panel';
}

sub _humanize
{
	my ($s) = @_;
	my @parts = grep { length } split /[_\W]+/, $s;
	return join(' ', map { ucfirst lc $_ } @parts);
}

sub _extract_legend_labels
{
	my ($legend) = @_;
	my @out;
	while ($legend =~ /\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/g)
	{
		push @out, $1;
	}
	return @out;
}

1;
