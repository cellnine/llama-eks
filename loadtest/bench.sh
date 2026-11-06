#!/usr/bin/env bash
# Benchmark sweep: fixed prompt and output length from 1 to 16 concurrent
# virtual users. Writes a TSV plus a summary table.
#
# Env:
#   GW_BASE       gateway base URL (default http://localhost:8080)
#   API_KEY       raw API key
#   PER_TEST_SEC  45
#   MAX_TOKENS    64
#   LEVELS        optional override, e.g. "1 2 4 8 16"
set -uo pipefail

cd "$(dirname "$0")"
mkdir -p results

GW_BASE="${GW_BASE:-http://localhost:8080}"
API_KEY="${API_KEY:?API_KEY required}"
PER_TEST_SEC="${PER_TEST_SEC:-45}"
MAX_TOKENS="${MAX_TOKENS:-64}"
LEVELS="${LEVELS:-1 2 4 8 16}"

TSV="results/bench.tsv"
echo -e "concurrency\trequests\tp50_ms\tp95_ms\trps\tnominal_tok_per_sec\t200\t429\tother" > "$TSV"

for c in $LEVELS; do
  echo "== concurrency $c =="
  OUT="results/run_c${c}.txt"
  CONCURRENCY=$c GW_BASE="$GW_BASE" API_KEY="$API_KEY" \
    PER_TEST_SEC="$PER_TEST_SEC" MAX_TOKENS="$MAX_TOKENS" \
    k6 run load.js > "$OUT" 2>&1 || echo "(k6 exited nonzero)"

  dur_line=$(grep -a 'http_req_duration' "$OUT" | head -1)
  reqs_line=$(grep -a 'http_reqs\.\.' "$OUT" | head -1)
  c200=$(grep -a -E 'responses_200' "$OUT" | head -1 | grep -a -oE ': [0-9]+' | head -1 | tr -d ': ')
  c429=$(grep -a -E 'responses_429' "$OUT" | head -1 | grep -a -oE ': [0-9]+' | head -1 | tr -d ': ')
  coth=$(grep -a -E 'responses_other' "$OUT" | head -1 | grep -a -oE ': [0-9]+' | head -1 | tr -d ': ')

  # k6 prints med and p(95) in seconds: "med=4.93s ... p(95)=5.42s"
  med=$(echo "$dur_line" | grep -a -oE 'med=[0-9.]+[ms]' | head -1 | grep -a -oE '[0-9.]+')
  p95=$(echo "$dur_line" | grep -a -oE 'p\(95\)=[0-9.]+[ms]' | head -1 | grep -a -oE '[0-9.]+')
  # normalise seconds -> ms
  case "$dur_line" in *med=${med}s*) med=$(echo "$med" | awk '{printf "%.0f", $1*1000}');; esac
  case "$dur_line" in *p\(95\)=${p95}s*) p95=$(echo "$p95" | awk '{printf "%.0f", $1*1000}');; esac

  rps=$(echo "$reqs_line" | grep -a -oE '[0-9.]+/s' | head -1 | tr -d 's/')

  c200="${c200:-0}"; c429="${c429:-0}"; coth="${coth:-0}"
  total_req=$((c200 + c429 + coth))
  tps=$(awk -v c="$c" -v tok="$MAX_TOKENS" -v dur="$PER_TEST_SEC" 'BEGIN {print c * tok / dur}')
  printf "%s\t%s\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s\n" "$c" "$total_req" "$med" "$p95" "$rps" "$tps" "$c429" "$c200" "$coth" >> "$TSV"
done

echo
echo "== summary (loadtest/$TSV) =="
column -t -s$'\t' "$TSV"
echo "nominal tok/sec = concurrency x MAX_TOKENS / PER_TEST_SEC (throughput ceiling if every request succeeded)."
