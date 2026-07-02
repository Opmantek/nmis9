#!/bin/bash
# Run both nodes for one layer and append rows to results.md. Usage: run_layer.sh <layer-label>
set -euo pipefail
LABEL="${1:?usage: run_layer.sh <layer-label>}"
WT=/home/md/work/nmis9-perf-bench
SHA="$(git -C "$WT" rev-parse --short HEAD)"
RESULTS="$WT/test/bench/results.md"

# collect_bench prints ONE JSON line on stdout (logs go to stderr). Reduce it to a table row.
REDUCER='
  my ($label,$sha)=@ARGV;
  my $j=JSON::XS->new->decode(do{local $/;<STDIN>});
  my ($finds,$tot)=(0,0);
  for my $c (values %{$j->{db_ops}}){ for my $op (keys %$c){ $tot+=$c->{$op}; $finds+=$c->{$op} if $op eq "find" } }
  printf "| %s | %s | %s | %s | %d | %d | %d | %d | %d | q=%d u=%d i=%d d=%d |\n",
    $label,$sha,$j->{node},$j->{mode},$finds,$tot,
    $j->{wallclock_ms}{median},$j->{rss_kb}{peak},$j->{rss_kb}{delta},
    @{$j->{opcounters_delta}}{qw(query update insert delete)};'

emit_row() { # mode node  -> one markdown row on stdout
  local mode="$1" node="$2" json
  json="$(docker exec perfbench-nmis bash -lc "cd /usr/local/nmis9 && perl test/bench/collect_bench.pl --node $node --mode $mode --runs 5" | tail -1)"
  printf '%s' "$json" | docker exec -i perfbench-nmis perl -MJSON::XS -e "$REDUCER" "$LABEL" "$SHA"
}

# Append rows after the table's LAST existing row (header, separator, or prior
# data row), not at end-of-file: results.md has a "## Findings" narrative
# section below the table, so a blind ">>" append would land new rows under
# that heading instead of in the table (confirmed by the first smoke run).
# Rows must accumulate chronologically -- baseline (L0) first, each later
# layer appended below -- so this inserts after the LAST "|"-prefixed line,
# not right after the header separator (which would put newest layers first).
NEWROWS="$(emit_row live realnode188; emit_row mock mocknode)"
AWK_ESCAPED_ROWS="${NEWROWS//\\/\\\\}"
awk -v rows="$AWK_ESCAPED_ROWS" '
  { lines[NR]=$0; if ($0 ~ /^\|/) last=NR }
  END {
    for (i=1; i<=NR; i++) {
      print lines[i]
      if (i==last) print rows
    }
  }
' "$RESULTS" > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"
echo "appended rows for $LABEL"
